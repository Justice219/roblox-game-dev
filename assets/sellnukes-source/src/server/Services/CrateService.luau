--!strict
--[[
	CrateService — the server half of SUPPLY CRATES and TRAILS (design spec §8; rules in
	Server/Pets/CrateLogic, numbers in Shared/Config/CrateConfig; docs/pets.md).

	Remotes (every argument untrusted):
		OpenCrate(crateId, requestId) → CrateResult(requestId, payload)
		    request id 1..2^31 (malformed → dropped); token bucket; a repeated id gets the SAME reply
		    (RequestMemory: never charged or rolled twice); one open in flight per player; refused
		    while the profile cannot save. A HELD crate (Robux receipt / admin) opens first (no
		    gems); otherwise the crate costs gems. EVERY open is a PAID RANDOM ITEM (held crates
		    are only sold for Robux, gems are Robux-reachable — CrateConfig.PaidRandomPay), so the
		    PolicyService answer is awaited on every request (PlayerDataService.
		    resolvePaidRandomAsync, cached, FAILS CLOSED) and the session re-checked after that
		    yield; restricted → "Restricted" (held crates are kept), not answered yet →
		    "PolicyUnknown" (try again). Then, with NO yield: CrateLogic.planOpen →
		    PlayerDataService.trySpendGems (analytics sink) → CrateLogic.commitOpen (all or
		    nothing; gems refunded on error) → PlayerDataService.grantGems for gem rewards / dup
		    refunds (analytics source) → markChanged(saveSoon).
		EquipTrail(trailId) — "" unequips; only OWNED trails; the trail is shown by TrailRenderer.
	Robux: MonetizationService product kind "Crate" (CrateSupply / CrateMega / CrateGolden,
	paidRandom). MonetizationService already refuses the PROMPT for a restricted / unknown policy;
	the receipt handler (no yield) follows CrateLogic.receiptDecision: defers while the policy is
	unknown, pays the crate's gem price instead for a KNOWN restricted buyer, else adds HELD
	crates (CrateLogic.applyReceipt). The
	client opens the CrateOpen screen from PurchaseGranted and opens the held crate with OpenCrate.

	Rewards side effects: a boost → the tycoon modifiers are invalidated; a pet → auto-equipped
	into a free slot (PetService.refresh); a trail → TrailRenderer. Trails are re-applied on every
	CharacterAdded.

	Analytics (guarded lazy): crateOpened (open / openPay / reward / rarity), crates
	"boost:<key>" + "boostSec:<key>", "refused:<gems|policy|rate|busy|other>". Admin (B14):
	GiveCrate, GiveTrail.

	Connects to: Server/Pets/{CrateLogic, PetLogic, PetState, RequestMemory, TrailRenderer,
	PetSeams}, Services/{PlayerDataService, MonetizationService, PetService},
	UI/Screens/{CrateShop, CrateOpen}.

	Example (tests):
		local payload = CrateService.handleOpen(player, "supply_crate", 3)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CrateConfig = require(ReplicatedStorage.Shared.Config.CrateConfig)
local CrateLogic = require(script.Parent.Parent.Pets.CrateLogic)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local MonetizationService = require(script.Parent.MonetizationService)
local PetLogic = require(script.Parent.Parent.Pets.PetLogic)
local PetSeams = require(script.Parent.Parent.Pets.PetSeams)
local ProgressEvents = require(script.Parent.Parent.Progression.ProgressEvents)
local PetService = require(script.Parent.PetService)
local PetState = require(script.Parent.Parent.Pets.PetState)
local PlayerDataService = require(script.Parent.PlayerDataService)
local ProfileLogic = require(script.Parent.Parent.Economy.ProfileLogic)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local RequestMemory = require(script.Parent.Parent.Pets.RequestMemory)
local TrailRenderer = require(script.Parent.Parent.Pets.TrailRenderer)
local Validate = require(ReplicatedStorage.Shared.Net.Validate)

-- The CrateResult payload.
export type CratePayload = {
	ok: boolean,
	code: string,
	crate: string, -- crate id ("" for unknown)
	pay: string, -- "held" | "gems"
	price: number, -- gems charged (0 for held / refusals)
	rewardKey: string?, -- CrateConfig reward key (client looks up label / kind / rarity)
	kind: string?, -- reward kind (boost / gems / egg / pet / trail)
	rarity: string?,
	dup: boolean, -- paid as dupGems instead (owned trail / full inventory)
	gems: number, -- gems granted by the reward (gem reward or dup refund)
	uid: string?, -- pet reward uid
	isNew: boolean,
	pityForced: boolean,
	pityLeft: number?,
	held: number, -- held crates of this id left
	message: string?,
}

local CrateService = {}

local Tunables = CrateConfig.Server
local openLimiter = RateLimiter.new(Tunables.OpenBurst, Tunables.OpenPerSecond)
local trailLimiter = RateLimiter.new(6, 3)
-- (Generic instantiation by cast: the new solver does not infer T from the annotation.)
local memory: RequestMemory.RequestMemory<CratePayload> = RequestMemory.new(Tunables.RecentRequests) :: any
local rng: PetLogic.RandomLike = Random.new()

-- Open refusal code → analytics reason (crates "refused:<reason>"; AnalyticsConfig documents the
-- allowed reasons — anything else is "other").
local REFUSAL_REASON: { [string]: string } = {
	NotEnough = "gems",
	Restricted = "policy", -- paid random items restricted in the player's region
	PolicyUnknown = "policy", -- PolicyService not answered yet (fail closed)
	RateLimited = "rate",
	Busy = "busy",
}

-- Analytics for a refused open (never errors / yields: PetSeams is guarded).
local function trackRefusal(player: Player, code: string)
	PetSeams.analytics("crates", player, `refused:{REFUSAL_REASON[code] or "other"}`)
end

local MESSAGES: { [string]: string } = {
	RateLimited = "Slow down - one crate at a time!",
	Busy = "Your last crate is still opening!",
	NotLoaded = "Your crates are still loading. Try again in a moment.",
	SaveOffline = "Crates are paused while your save is offline. Please rejoin!",
	Error = "Something went wrong - nothing was charged.",
}

-- A refusal payload (nothing charged).
local function failure(code: string, crate: CrateConfig.CrateDef?, profile: any?): CratePayload
	local held = 0
	if crate ~= nil and profile ~= nil then
		held = PetState.crates(profile).held[crate.id] or 0
	end
	return {
		ok = false,
		code = code,
		crate = if crate ~= nil then crate.id else "",
		pay = "gems",
		price = 0,
		rewardKey = nil,
		kind = nil,
		rarity = nil,
		dup = false,
		gems = 0,
		uid = nil,
		isNew = false,
		pityForced = false,
		pityLeft = nil,
		held = held,
		message = MESSAGES[code] or CrateLogic.refusalMessage(code, crate),
	}
end

local function send(player: Player, requestId: number, payload: CratePayload)
	if player.Parent == Players then
		Remotes.fireClient("CrateResult", player, requestId, payload)
	end
end

-- Shows the player's equipped trail on their character.
local function applyTrail(player: Player)
	local profile = PlayerDataService.getProfile(player)
	TrailRenderer.apply(player, if profile ~= nil then PetState.trails(profile).equipped else "")
end

--------------------------------------------------------------------------------------------------
-- Opening
--------------------------------------------------------------------------------------------------

--[[
	The OpenCrate handler (also the Studio test entry point). See the header for every check.
	@return the payload sent (nil when the request id was malformed)
]]
function CrateService.handleOpen(player: Player, rawCrate: unknown, rawRequestId: unknown): CratePayload?
	local requestId = Validate.integer(rawRequestId, 1, Tunables.MaxRequestId)
	if requestId == nil then
		return nil
	end
	if not openLimiter:Allow(player.UserId) then
		local payload = failure("RateLimited", nil)
		send(player, requestId, payload)
		trackRefusal(player, payload.code)
		return payload
	end
	local previous = memory:get(player, requestId)
	if previous ~= nil then
		send(player, requestId, previous)
		return previous
	end
	local crate = CrateConfig.get(Validate.key(rawCrate, 32))
	if not memory:tryBegin(player) then
		local payload = failure("Busy", crate)
		send(player, requestId, payload)
		trackRefusal(player, payload.code)
		return payload
	end

	-- Filled by the success path for the side effects after the reply.
	local appliedPlan: CrateLogic.OpenPlan? = nil
	local ok, outcome = pcall(function(): CratePayload
		local session = PlayerDataService.getSession(player)
		if session == nil then
			return failure("NotLoaded", crate)
		end
		if not PlayerDataService.canMutate(player) then
			return failure("SaveOffline", crate)
		end
		local profile = session.profile
		-- Fail closed: only a resolved PolicyService answer can lower it.
		local restricted = true
		local pay = if crate ~= nil and (PetState.crates(profile).held[crate.id] or 0) >= 1 then "held" else "gems"
		if crate ~= nil and CrateConfig.needsPolicy(pay) then
			-- A paid random item (held = bought with Robux, gems = Robux-reachable): wait for
			-- PolicyService on EVERY open (fail closed), then re-check the session after the yield.
			restricted = PlayerDataService.resolvePaidRandomAsync(player)
			if PlayerDataService.getSession(player) ~= session or player.Parent ~= Players then
				return failure("NotLoaded", crate)
			end
			if not PlayerDataService.canMutate(player) then
				return failure("SaveOffline", crate)
			end
		end

		-- From here: NO yields (plan → charge → commit → grant gems).
		local now = os.time()
		local plan, code = CrateLogic.planOpen(profile, if crate ~= nil then crate.id else nil, {
			random = rng,
			now = now,
			restricted = restricted,
		})
		if plan == nil then
			-- A refusal only because PolicyService has not answered yet: say so (a retry may work).
			if code == "Restricted" and not PlayerDataService.isPolicyKnown(player) then
				return failure("PolicyUnknown", crate, profile)
			end
			return failure(code, crate, profile)
		end
		if plan.pay == "gems" and not PlayerDataService.trySpendGems(player, plan.price, "crate") then
			return failure("NotEnough", plan.crate, profile)
		end
		local committed, applied = pcall(CrateLogic.commitOpen, profile, plan, now)
		if not committed then
			if plan.pay == "gems" then
				-- A refund is not income: straight back to the balance (no analytics source).
				ProfileLogic.addGems(profile, plan.price)
				PlayerDataService.markChanged(player, true, { "gems" })
			end
			error(applied, 0)
		end
		if applied.gems > 0 then
			PlayerDataService.grantGems(player, applied.gems, "crate")
		end
		-- A crate pet joins the team when a slot is free.
		if applied.uid ~= nil then
			PetLogic.setEquipped(profile, applied.uid, true, PetService.slotsFor(player, profile))
		end
		PlayerDataService.markChanged(player, true, { "crates", "pets", "trails", "boosts" })
		appliedPlan = plan
		return {
			ok = true,
			code = "Ok",
			crate = plan.crate.id,
			pay = plan.pay,
			price = plan.price,
			rewardKey = plan.reward.key,
			kind = plan.reward.kind,
			rarity = plan.reward.rarity,
			dup = applied.dup,
			gems = applied.gems,
			uid = applied.uid,
			isNew = applied.isNew,
			pityForced = plan.pityForced,
			pityLeft = CrateLogic.pityLeft(plan.crate, plan.pityAfter),
			held = PetState.crates(profile).held[plan.crate.id] or 0,
			message = nil,
		}
	end)
	memory:finish(player)

	local payload: CratePayload
	if ok then
		payload = outcome
	else
		warn(`[CrateService] open errored: {outcome}`)
		payload = failure("Error", crate)
	end
	if player.Parent == Players then
		memory:remember(player, requestId, payload)
	end
	send(player, requestId, payload)

	-- Side effects outside the pcall (never turn a paid open into "Error").
	local plan = appliedPlan
	if payload.ok and plan ~= nil then
		local reward = plan.reward
		if not payload.dup then
			if reward.kind == "boost" then
				PetSeams.invalidateModifiers(player)
				PetSeams.analytics("crates", player, `boost:{reward.id}`)
				PetSeams.analytics("crates", player, `boostSec:{reward.id}`, reward.seconds)
			elseif reward.kind == "pet" then
				PetService.refresh(player)
			elseif reward.kind == "trail" then
				applyTrail(player)
			end
		end
		PetSeams.crateOpened(
			player,
			plan.crate.id,
			if plan.pay == "held" then "robux" else "gems",
			{ { kind = if payload.dup then "gems" else reward.kind, rarity = reward.rarity } }
		)
		ProgressEvents.progress(player, "crate") -- R78 Quests / Pass: a crate opened
	elseif not payload.ok then
		trackRefusal(player, payload.code)
	end
	return payload
end

--[[ EquipTrail(trailId) — "" unequips. @return the CrateLogic code or nil (rejected input) ]]
function CrateService.handleEquipTrail(player: Player, rawTrail: unknown): string?
	local trailId = if rawTrail == "" then "" else Validate.key(rawTrail, 32)
	if trailId == nil or not trailLimiter:Allow(player.UserId) or not PlayerDataService.canMutate(player) then
		return nil
	end
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return nil
	end
	local code = CrateLogic.equipTrail(profile, trailId)
	if code == "Ok" then
		PlayerDataService.markChanged(player, false, { "trails" })
		applyTrail(player)
	end
	return code
end

--------------------------------------------------------------------------------------------------
-- Robux receipts (MonetizationConfig kind "Crate")
--------------------------------------------------------------------------------------------------

--[[
	The "Crate" receipt handler (no yield; MonetizationService contract). Defers (false) while the
	buyer's policy is unknown; a KNOWN restricted buyer gets the gem price instead of a crate.
	@return true when granted (MonetizationService records the receipt + saves)
]]
function CrateService.handleReceipt(
	player: Player,
	profile: any,
	product: MonetizationConfig.ProductDef,
	_receipt: any
): boolean
	local crateId = CrateConfig.ByProduct[product.key]
	if crateId == nil then
		warn(`[CrateService] product {product.key} has no crate`)
		return false
	end
	local decision = CrateLogic.receiptDecision(
		PlayerDataService.isPolicyKnown(player),
		PlayerDataService.isPaidRandomRestricted(player)
	)
	if decision == "defer" then
		return false -- Roblox re-delivers the receipt; the policy will be known then
	end
	local ok, gemsInstead = CrateLogic.applyReceipt(profile, crateId, product.crates or 1, decision == "gems")
	if ok then
		print(
			`[CrateService] {player.UserId} receipt {product.key}: {if gemsInstead > 0
				then `{gemsInstead} gems (restricted)`
				else `+{product.crates or 1} held {crateId}`}`
		)
	end
	return ok
end

-- Prompt-time refusal (no yield): a full stack of held crates.
local function promptRefusal(player: Player, product: MonetizationConfig.ProductDef): string?
	local crateId = CrateConfig.ByProduct[product.key]
	local profile = PlayerDataService.getProfile(player)
	if crateId ~= nil and profile ~= nil and (PetState.crates(profile).held[crateId] or 0) >= Tunables.MaxHeld then
		return "Open some of your crates first!"
	end
	return nil
end

--[[ Studio tests: swap the server RNG (returns a restore function). ]]
function CrateService.useRandomForTests(random: PetLogic.RandomLike?): () -> ()
	local previous = rng
	rng = random or Random.new()
	return function()
		rng = previous
	end
end

--------------------------------------------------------------------------------------------------
-- Admin (B14)
--------------------------------------------------------------------------------------------------

local function registerAdmin()
	local crateLabels: { string } = {}
	for _, id in CrateConfig.Order do
		table.insert(crateLabels, CrateConfig.Crates[id].name)
	end
	local trailLabels: { string } = {}
	for _, id in CrateConfig.TrailOrder do
		table.insert(trailLabels, CrateConfig.Trails[id].name)
	end
	PetSeams.registerAdminCommands({
		{
			def = {
				name = "GiveCrate",
				tab = "Players",
				label = "Give Crate",
				description = "Adds held Supply Crates (opened for free from the crate menu).",
				target = "Player",
				args = {
					crate = { kind = "enum", values = CrateConfig.Order, labels = crateLabels, label = "Crate" },
					count = {
						kind = "integer",
						min = 1,
						max = 50,
						label = "Count",
						presets = { 1, 5, 10 },
						format = "count",
						default = 1,
					},
				},
				argOrder = { "crate", "count" },
				cooldown = 1,
				audited = true,
				confirm = false,
				color = "yellow",
				order = 63,
			},
			handler = function(ctx: any): (boolean, string)
				local target = ctx.target.player
				local profile = if target ~= nil then PlayerDataService.getProfile(target) else nil
				if target == nil or profile == nil or not PlayerDataService.canMutate(target) then
					return false, "Player not loaded"
				end
				if not CrateLogic.grantHeld(profile, ctx.args.crate, ctx.args.count) then
					return false, "Could not give crates"
				end
				PlayerDataService.markChanged(target, true, { "crates" })
				PlayerDataService.notify(
					target,
					`+{ctx.args.count} {CrateConfig.Crates[ctx.args.crate].name}! Open it at the crate stall.`,
					"reward",
					"Gift"
				)
				return true, `Gave {ctx.args.count}x {ctx.args.crate}`
			end,
		},
		{
			def = {
				name = "GiveTrail",
				tab = "Players",
				label = "Give Trail",
				description = "Unlocks a cosmetic trail.",
				target = "Player",
				args = {
					trail = { kind = "enum", values = CrateConfig.TrailOrder, labels = trailLabels, label = "Trail" },
				},
				argOrder = { "trail" },
				cooldown = 1,
				audited = true,
				confirm = false,
				color = "yellow",
				order = 64,
			},
			handler = function(ctx: any): (boolean, string)
				local target = ctx.target.player
				local profile = if target ~= nil then PlayerDataService.getProfile(target) else nil
				if target == nil or profile == nil or not PlayerDataService.canMutate(target) then
					return false, "Player not loaded"
				end
				local granted = CrateLogic.grantTrail(profile, ctx.args.trail)
				PlayerDataService.markChanged(target, true, { "trails" })
				return true, if granted then `Gave {ctx.args.trail}` else "Already owned"
			end,
		},
	}, 6, 5)
end

--------------------------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------------------------

-- Re-applies the trail whenever the player's character spawns.
local function watchCharacter(player: Player)
	player.CharacterAdded:Connect(function(character: Model)
		-- The root part may replicate a frame later than the model.
		character:WaitForChild("HumanoidRootPart", 10)
		applyTrail(player)
	end)
	if player.Character ~= nil then
		task.spawn(applyTrail, player)
	end
end

function CrateService.Init()
	Remotes.onServerEvent("OpenCrate", function(player: Player, rawCrate: unknown, rawRequestId: unknown)
		CrateService.handleOpen(player, rawCrate, rawRequestId)
	end)
	Remotes.onServerEvent("EquipTrail", function(player: Player, rawTrail: unknown)
		CrateService.handleEquipTrail(player, rawTrail)
	end)
	MonetizationService.registerProductHandler("Crate", CrateService.handleReceipt)
	MonetizationService.registerPromptRefusal("Crate", promptRefusal)
end

function CrateService.Start()
	PetSeams.registerIds("crateId", function(id: string): boolean
		return CrateConfig.get(id) ~= nil
	end)
	PlayerDataService.ProfileLoaded:Connect(function(player: Player)
		applyTrail(player)
	end)
	Players.PlayerAdded:Connect(watchCharacter)
	for _, player in Players:GetPlayers() do
		watchCharacter(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		memory:forget(player)
		openLimiter:Forget(player.UserId)
		trailLimiter:Forget(player.UserId)
	end)
	task.defer(registerAdmin)
end

return CrateService
