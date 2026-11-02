--!strict
--[[
	LuckySpinService — the Lucky Wheel (design spec §7): free spin every 20 min (stack 3), bonus
	spins from free rewards, paid spins from the x2 / x5 / x10 products and the packs,
	server-rolled weighted slices.

	SpinWheel (C→S, requestId): token bucket → request id (Validate.requestId) → a request id seen
	recently gets its remembered answer again (never a second spin) → profile + canMutate →
	WheelLogic.peek (free → bonus → paid). PAID RANDOM ITEMS: when the next spin is a PAID
	(Robux-sourced) one, the player's PolicyService answer is awaited on EVERY such request
	(PlayerDataService.resolvePaidRandomAsync, cached, FAILS CLOSED) and the profile / session
	re-checked after that yield; a restricted answer refuses with code "restricted" (or
	"policyUnknown" while PolicyService has not answered) and changes nothing. Then, with no
	yield: WheelLogic.consume → WheelLogic.roll on a SERVER Random → the slice's reward through
	RewardGrant in the same step → SpinResult to the client:
		{ requestId, ok, code?, index, sliceId, source = "free" | "bonus" | "paid", text,
		  reward = { cash, gems, spins, boost?, pet?, egg? }, free, bonus, paid, nextFreeIn }
	The client animates the wheel onto `index`; the reward is already in the profile.

	Product handler "Spins" (MonetizationConfig Spins2 / Spins5 / Spins10, paidRandom): the prompt
	is refused for a restricted / unknown policy (MonetizationService; a KNOWN restricted refusal
	is counted here first). The receipt (no yield, WheelLogic.receipt) defers while the policy is
	unknown, pays LuckySpinConfig.GemsPerSpin gems per spin to a KNOWN restricted buyer, else adds
	paid spins.

	On profile load the free-spin timer starts (WheelLogic.refill: no back-fill for new players).
	Analytics: retention "wheel:spin:<free|bonus|paid>", "wheel:slice:<sliceId>",
	"wheel:refused:<policy|empty>", "wheel:receipt:<spins|gems>".
	Admin seam: grantSpins(player, count) (free bonus spins), setFree(player, count).

	Example: LuckySpinService.spin(player, 17) --> SpinResult payload (tests)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local LuckySpinConfig = require(ReplicatedStorage.Shared.Config.LuckySpinConfig)
local MonetizationService = require(script.Parent.MonetizationService)
local PlayerDataService = require(script.Parent.PlayerDataService)
local ProfileLogic = require(ServerScriptService.Server.Economy.ProfileLogic)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local RewardGrant = require(ServerScriptService.Server.Retention.RewardGrant)
local ProgressEvents = require(ServerScriptService.Server.Progression.ProgressEvents)
local RewardLogic = require(ServerScriptService.Server.Retention.RewardLogic)
local Validate = require(ReplicatedStorage.Shared.Net.Validate)
local WheelLogic = require(ServerScriptService.Server.Retention.WheelLogic)

export type SpinPayload = { [string]: any }

local LuckySpinService = {}

local limiter = RateLimiter.new(LuckySpinConfig.SpinLimit.Burst, LuckySpinConfig.SpinLimit.PerSecond)
local random = Random.new()
-- Recently answered request ids per player (bounded ring), so a retried request never spins twice.
local answered: { [Player]: { order: { number }, byId: { [number]: SpinPayload } } } = {}

-- Remembers a payload under its request id (oldest forgotten past RememberResults).
local function remember(player: Player, requestId: number, payload: SpinPayload)
	local memory = answered[player]
	if memory == nil then
		memory = { order = {}, byId = {} }
		answered[player] = memory
	end
	table.insert(memory.order, requestId)
	memory.byId[requestId] = payload
	while #memory.order > LuckySpinConfig.RememberResults do
		local oldest = table.remove(memory.order, 1)
		if oldest ~= nil then
			memory.byId[oldest] = nil
		end
	end
end

-- The spin counters every answer carries (so the screen never computes them from stale data).
local function counters(profile: ProfileLogic.Profile, now: number): LuckySpinConfig.Status
	local status = LuckySpinConfig.status(profile.spin, now)
	return { free = status.free, bonus = status.bonus, paid = status.paid, nextFreeIn = status.nextFreeIn }
end

-- A refusal payload carrying the current counters.
local function refusal(
	requestId: number,
	code: string,
	text: string,
	profile: ProfileLogic.Profile,
	now: number
): SpinPayload
	local status = counters(profile, now)
	return {
		requestId = requestId,
		ok = false,
		code = code,
		text = text,
		free = status.free,
		bonus = status.bonus,
		paid = status.paid,
		nextFreeIn = status.nextFreeIn,
	}
end

--[[
	Spins the wheel for `player` (the SpinWheel handler; tests call it).
	@return the SpinResult payload that was sent
]]
function LuckySpinService.spin(player: Player, rawRequestId: unknown): SpinPayload?
	local requestId = Validate.requestId(rawRequestId)
	if requestId == nil then
		return nil
	end
	local memory = answered[player]
	local previous = if memory ~= nil then memory.byId[requestId] else nil
	if previous ~= nil then
		Remotes.fireClient("SpinResult", player, previous)
		return previous
	end
	local profile = PlayerDataService.getProfile(player)
	local now = os.time()
	local payload: SpinPayload
	-- Fail closed: only a resolved PolicyService answer may allow a PAID spin.
	local allowPaid = false
	if profile ~= nil and PlayerDataService.canMutate(player) and WheelLogic.peek(profile.spin, now) == "paid" then
		-- A Robux-sourced spin is a paid random item: await the policy (may yield), then re-check.
		local restricted = PlayerDataService.resolvePaidRandomAsync(player)
		local current = PlayerDataService.getProfile(player)
		if current ~= profile or player.Parent ~= Players then
			profile = nil -- left / reloaded during the lookup: answered as not ready below
		end
		allowPaid = not restricted
		now = os.time()
		-- A retry of the same request id may have been answered while this one waited.
		local again = answered[player]
		local answeredMeanwhile = if again ~= nil then again.byId[requestId] else nil
		if answeredMeanwhile ~= nil then
			Remotes.fireClient("SpinResult", player, answeredMeanwhile)
			return answeredMeanwhile
		end
	end
	if profile == nil or not PlayerDataService.canMutate(player) then
		payload = { requestId = requestId, ok = false, code = "notReady", text = "Your save is still loading!" }
	else
		local source, why = WheelLogic.consume(profile.spin, now, allowPaid)
		if source == nil and why == "restricted" then
			local known = PlayerDataService.isPolicyKnown(player)
			payload = refusal(
				requestId,
				if known then "restricted" else "policyUnknown",
				if known
					then LuckySpinConfig.PolicyText.RefusedRestricted
					else LuckySpinConfig.PolicyText.RefusedUnknown,
				profile,
				now
			)
			PlayerDataService.refresh(player, { "spin" })
			RewardGrant.track(player, "wheel:refused:policy")
		elseif source == nil then
			payload =
				refusal(requestId, "noSpins", "No spins left! Get more spins or wait for a free one.", profile, now)
			PlayerDataService.refresh(player, { "spin" })
			RewardGrant.track(player, "wheel:refused:empty")
		else
			local index = WheelLogic.roll(random:NextNumber())
			local slice = LuckySpinConfig.Slices[index]
			local summary = RewardGrant.grant(player, slice.reward, "wheel", { extraFields = { "spin" } })
			local status = counters(profile, now)
			payload = {
				requestId = requestId,
				ok = true,
				index = index,
				sliceId = slice.id,
				source = source,
				text = if summary ~= nil then RewardLogic.describe(summary) else "",
				reward = if summary ~= nil
					then {
						cash = summary.cash,
						gems = summary.gems,
						spins = summary.spins,
						boost = summary.boost,
						pet = summary.pet,
						egg = summary.egg,
					}
					else nil,
				free = status.free,
				bonus = status.bonus,
				paid = status.paid,
				nextFreeIn = status.nextFreeIn,
			}
			RewardGrant.track(player, `wheel:spin:{source}`)
			ProgressEvents.progress(player, "spin") -- R78 Quests / Pass: one wheel spin
			RewardGrant.track(player, `wheel:slice:{slice.id}`)
		end
	end
	-- A player who left during the policy wait gets no memory entry (PlayerRemoving already
	-- cleared `answered`; re-creating it would leak).
	if player.Parent == Players then
		remember(player, requestId, payload)
		Remotes.fireClient("SpinResult", player, payload)
	end
	return payload
end

--[[ Admin / rewards: adds FREE bonus spins (never Robux-sourced). @return spins actually added ]]
function LuckySpinService.grantSpins(player: Player, count: number): number
	local profile = PlayerDataService.getProfile(player)
	if profile == nil or count ~= count or count < 1 then
		return 0
	end
	local summary = RewardLogic.apply(profile, { spins = math.floor(count) }, os.time())
	PlayerDataService.markChanged(player, true, { "spin" })
	return summary.spins
end

--[[ Admin / tests: sets the banked free spins (0..MaxFree) and restarts the timer. ]]
function LuckySpinService.setFree(player: Player, count: number): boolean
	local profile = PlayerDataService.getProfile(player)
	if profile == nil or count ~= count then
		return false
	end
	profile.spin.free = math.clamp(math.floor(count), 0, LuckySpinConfig.MaxFree)
	profile.spin.lastFreeAt = os.time()
	PlayerDataService.markChanged(player, false, { "spin" })
	return true
end

function LuckySpinService.Init()
	-- Paid spins (x2 / x5 / x10): a paid random item (WheelLogic.receipt). Must not yield; changes
	-- nothing when deferred (policy unknown) or when the product is malformed.
	MonetizationService.registerProductHandler("Spins", function(player, profile, product, _receipt): boolean
		local outcome, amount = WheelLogic.receipt(
			profile,
			product.spins,
			PlayerDataService.isPolicyKnown(player),
			PlayerDataService.isPaidRandomRestricted(player)
		)
		if outcome == "defer" then
			return false -- Roblox re-delivers the receipt; the policy will be known then
		end
		if outcome == "gems" then
			-- A KNOWN restricted buyer (bought before the answer changed): a fixed gem equivalent.
			RewardGrant.applyInReceipt(player, profile, { gems = amount } :: any, "spins_gems")
		end
		RewardGrant.track(player, `wheel:receipt:{outcome}`)
		return true
	end)
	-- Count KNOWN restricted refusals (no yield); MonetizationService then refuses every paid
	-- random prompt for a restricted / unknown policy itself (fail closed).
	MonetizationService.registerPromptRefusal("Spins", function(player: Player, _product: any): string?
		if PlayerDataService.isPolicyKnown(player) and PlayerDataService.isPaidRandomRestricted(player) then
			RewardGrant.track(player, "wheel:refused:policy")
			return LuckySpinConfig.PolicyText.RefusedRestricted
		end
		return nil
	end)
	RewardGrant.registerIds("sliceId", function(id: string): boolean
		return LuckySpinConfig.indexOf(id) ~= nil
	end)
end

function LuckySpinService.Start()
	Remotes.onServerEvent("SpinWheel", function(player: Player, rawRequestId: unknown)
		if limiter:Allow(player) then
			LuckySpinService.spin(player, rawRequestId)
		end
	end)
	-- Start the free-spin timer on load (and bank anything earned while away).
	PlayerDataService.ProfileLoaded:Connect(function(player: Player, profile, _isNew: boolean)
		local before = profile.spin.free
		local beforeAt = profile.spin.lastFreeAt
		WheelLogic.refill(profile.spin, os.time())
		if profile.spin.free ~= before or profile.spin.lastFreeAt ~= beforeAt then
			PlayerDataService.markChanged(player, false, { "spin" })
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		limiter:Forget(player)
		answered[player] = nil
	end)
end

return LuckySpinService
