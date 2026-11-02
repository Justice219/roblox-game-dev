--!strict
--[[
	MegaLever — the server rules of owner R90's Mega Lever (spec docs/superpowers/specs/2026-10-31-
	r90-hands-on-design.md §2; docs/kinetic.md): a giant candy-striped lever on the player's plot
	(every world). Holding its prompt sends KineticAction "pull"; a valid pull is a MEGA PULL (owner
	R112 wording: the player-facing word is never "batch").

	Pull rules (all server-side; maths in Shared/Tycoon/KineticLogic, numbers in KineticConfig.Lever)
		1. lever switch on (ReplicatedStorage attribute, admin KineticSwitch)
		2. the lever of the world the player stands in is placed (unlocked + plot built)
		3. the character is within Reach / ReachVertical of the lever (server position)
		4. the run is ready (TycoonService.getModifiers) and the world's cooldown passed
		   (profile.kinetic.worlds[w].readyAt <= os.time(); saved, so a rejoin never resets it)
		5. KineticLogic.leverPlan over every BUILT producer of that world (Nuke Town: skipping any
		   area knocked down by an attack — its production is paused) pays > 0
		Then: readyAt = now + CooldownSeconds is committed FIRST (a repeated intent fails rule 4 —
		idempotent), every bonus cycle rolls a Surprise Batch flavour through FlavorService.batch
		(cycles = 1, perCycle = that producer's scaled bonus; the returned bonus is added — the R89
		public API, nothing else of FlavorService is touched), ONE grant of the world's currency
		(PlayerDataService.grantCurrency, "megaLever"), save soon, PulledAt / ReadyAt attributes
		(every client swings the arm + runs the countdown), the owner's "pull" wire (chute ride,
		confetti, CurrencyFly), the Quests "lever" stat, analytics. A grant that pays nothing (a
		wallet at its cap) refunds the cooldown.

	Security: the intent carries no data; reach, ownership (the lever is looked up from the
	player's own props), unlock, cooldown and amounts are the server's. Performance: one pull costs
	one producerStats per producer of one world (<= 10), every few minutes at most.

	API
		MegaLever.pull(player) -> (ok, reason?)   reason: off | locked | reach | notReady | cooldown |
		                                          noProducers
		MegaLever.publish(player, worldId)         ReadyAt attribute from the saved cooldown
		MegaLever.adminReset(player) -> (ok, message)
		MegaLever.stats() -> { pulls, paid }
		MegaLever.forget(player)

	Connects to: Shared/Config/{KineticConfig, Worlds/WorldsConfig}, Shared/Tycoon/{KineticLogic,
	TycoonLogic}, Shared/Net/Remotes, Server/Kinetic/{KineticWorld, KineticAnalytics},
	Server/Services/PlayerDataService, Server/Tycoon/{TycoonService, WorldService, Knockdown,
	FlavorService}, Server/Economy/ProfileLogic (peekWorld), Server/Progression/ProgressEvents.

	Example: local ok, reason = MegaLever.pull(player) --> true / false, "cooldown"
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local FlavorService = require(script.Parent.Parent.Tycoon.FlavorService)
local KineticAnalytics = require(script.Parent.KineticAnalytics)
local KineticConfig = require(ReplicatedStorage.Shared.Config.KineticConfig)
local KineticLogic = require(ReplicatedStorage.Shared.Tycoon.KineticLogic)
local KineticWorld = require(script.Parent.KineticWorld)
local Knockdown = require(script.Parent.Parent.Tycoon.Knockdown)
local PlayerDataService = require(script.Parent.Parent.Services.PlayerDataService)
local ProfileLogic = require(script.Parent.Parent.Economy.ProfileLogic)
local ProgressEvents = require(script.Parent.Parent.Progression.ProgressEvents)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)
local TycoonService = require(script.Parent.Parent.Tycoon.TycoonService)
local WorldService = require(script.Parent.Parent.Tycoon.WorldService)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local ATTR = KineticConfig.Attr
local LEVER = KineticConfig.Lever
local COPY = KineticConfig.Copy
local MAIN = WorldsConfig.MAIN
local NO_FIELDS: { string } = table.freeze({}) :: any

local MegaLever = {}

-- os.clock() of the last refusal toast per player (throttled to KineticConfig.NoticeSeconds).
local noticeAt: { [Player]: number } = {}
local counters = { pulls = 0, paid = 0 }

-- The lever switch (missing = on).
local function enabled(): boolean
	return ReplicatedStorage:GetAttribute(ATTR.LeverOn) ~= false
end

-- The character root (nil when dead / not spawned).
local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	return if root ~= nil and root:IsA("BasePart") then root else nil
end

-- A throttled toast for a refused pull.
local function notice(player: Player, text: string)
	local t = os.clock()
	if t - (noticeAt[player] or -math.huge) >= KineticConfig.NoticeSeconds then
		noticeAt[player] = t
		PlayerDataService.notify(player, text, "info")
	end
end

-- Records the refusal and tells the player why when it helps.
local function refuse(player: Player, reason: string, text: string?): (boolean, string?)
	KineticAnalytics.record(player, `pullRefused:{reason}`)
	if text ~= nil then
		notice(player, text)
	end
	return false, reason
end

-- The tycoon state of a world on a profile (Nuke Town: profile.tycoon), or nil.
local function tycoonOf(profile: any, worldId: string): any
	if worldId == MAIN then
		return profile.tycoon
	end
	local world = ProfileLogic.peekWorld(profile, worldId)
	return if world ~= nil then world.tycoon else nil
end

--[[
	One bonus cycle per BUILT producer of a world (Nuke Town skips knocked-down areas): what a
	cycle of it pays right now (automated: output; still manual: the click payout) and its cycle
	time, with the run's cached modifiers.
]]
local function collectCycles(player: Player, profile: any, worldId: string, mods: any): { KineticLogic.Cycle }
	local state = tycoonOf(profile, worldId)
	local cycles: { KineticLogic.Cycle } = {}
	if state == nil then
		return cycles
	end
	local logic = TycoonLogic.forWorld(worldId)
	for _, producer in logic.index.Producers do
		local stats = logic.producerStats(state, producer.id, mods)
		if stats ~= nil and stats.built then
			if worldId == MAIN and (Knockdown.isDown(player, producer.area)) then
				continue -- owner R50: a knocked-down area's production is paused
			end
			table.insert(cycles, {
				id = producer.id,
				perCycle = if stats.automated then stats.output else stats.clickPayout,
				cycle = stats.cycle,
			})
		end
	end
	return cycles
end

--[[ Refreshes a world lever's ReadyAt attribute from the saved cooldown (writes only on change). ]]
function MegaLever.publish(player: Player, worldId: string)
	local lever = KineticWorld.lever(player, worldId)
	local profile = PlayerDataService.getProfile(player)
	if lever == nil or profile == nil then
		return
	end
	local entry = KineticLogic.peek((profile :: any).kinetic, worldId)
	KineticWorld.setAttr(lever, ATTR.ReadyAt, if entry ~= nil then entry.readyAt else 0)
end

--[[
	Pulls the owner's lever in the world they stand in (see the module header).
	@return (ok, reason?)
]]
function MegaLever.pull(player: Player): (boolean, string?)
	if not enabled() then
		return refuse(player, "off", COPY.LeverOff)
	end
	local worldId = WorldService.currentWorld(player)
	local lever = KineticWorld.lever(player, worldId)
	local def = WorldsConfig.get(worldId)
	if lever == nil or def == nil then
		return refuse(player, "locked", nil)
	end
	local root = rootOf(player)
	if
		root == nil
		or not KineticLogic.withinReach(root.Position, lever:GetPivot().Position, LEVER.Reach, LEVER.ReachVertical)
	then
		return refuse(player, "reach", COPY.LeverTooFar)
	end
	local profile = PlayerDataService.getProfile(player)
	local mods = TycoonService.getModifiers(player, worldId)
	if profile == nil or mods == nil then
		return refuse(player, "notReady", nil)
	end
	local entry = KineticLogic.entry((profile :: any).kinetic, worldId)
	if entry == nil then
		return refuse(player, "notReady", nil)
	end
	local now = os.time()
	if not KineticLogic.isReady(entry.readyAt, now) then
		local left = KineticLogic.cooldownLeft(entry.readyAt, now)
		return refuse(player, "cooldown", string.format(COPY.LeverCooldown, KineticLogic.formatCountdown(left)))
	end
	local cycles = collectCycles(player, profile, worldId, mods)
	local plan = KineticLogic.leverPlan(cycles)
	if plan.total <= 0 then
		return refuse(player, "noProducers", COPY.LeverNoProducers)
	end
	-- Commit the cooldown first: a duplicate intent now fails the ready check.
	local previousReadyAt = entry.readyAt
	entry.readyAt = KineticLogic.nextReadyAt(now)
	-- Every bonus cycle rolls a flavour (FlavorService's public API; it returns the extra bonus).
	local total, paidCycles = 0, 0
	local wireCycles: { KineticLogic.WireCycle } = {}
	for index, cycle in cycles do
		local bonus = plan.bonuses[index]
		if bonus ~= nil and bonus > 0 then
			local extra = FlavorService.batch(player, worldId, cycle.id, 1, bonus, true)
			if not KineticLogic.isFinite(extra) or extra < 0 then
				extra = 0
			end
			local flavor = KineticLogic.flavorOf(extra, bonus)
			total += bonus + extra
			paidCycles += 1
			if extra > 0 then
				KineticAnalytics.record(player, `pullFlavor:{flavor}`)
			end
			if #wireCycles < LEVER.MaxWireCycles then
				table.insert(wireCycles, { id = cycle.id, amount = bonus + extra, flavor = flavor })
			end
		end
	end
	local currency = def.currency.key
	local granted = PlayerDataService.grantCurrency(player, currency, total, KineticConfig.Reasons.Lever)
	if granted <= 0 then
		entry.readyAt = previousReadyAt -- nothing was paid: give the pull back
		return refuse(player, "notReady", nil)
	end
	PlayerDataService.markChanged(player, true, NO_FIELDS)
	KineticWorld.setAttr(lever, ATTR.ReadyAt, entry.readyAt)
	lever:SetAttribute(ATTR.PulledAt, Workspace:GetServerTimeNow())
	Remotes.fireClient("Kinetic", player, {
		kind = "pull",
		world = worldId,
		total = granted,
		currency = currency,
		readyAt = entry.readyAt,
		cycles = wireCycles,
	})
	ProgressEvents.progress(player, "lever")
	counters.pulls += 1
	counters.paid += granted
	KineticAnalytics.record(player, `pull:{worldId}`)
	KineticAnalytics.record(player, `pullPaid:{worldId}`, granted)
	KineticAnalytics.record(player, `pullCycles:{worldId}`, paidCycles)
	return true, nil
end

--[[
	Admin (KineticLeverReset): the lever of the world the player stands in is ready again.
	@return (ok, message)
]]
function MegaLever.adminReset(player: Player): (boolean, string)
	local worldId = WorldService.currentWorld(player)
	local profile = PlayerDataService.getProfile(player)
	local entry = if profile ~= nil then KineticLogic.entry((profile :: any).kinetic, worldId) else nil
	if entry == nil then
		return false, "Profile not loaded"
	end
	entry.readyAt = 0
	PlayerDataService.markChanged(player, true, NO_FIELDS)
	MegaLever.publish(player, worldId)
	return true, `{player.Name}'s Mega Lever in {worldId} is ready`
end

--[[ Server totals since boot (admin KineticStatus / QA). ]]
function MegaLever.stats(): { pulls: number, paid: number }
	return table.clone(counters)
end

--[[ Drops a leaving player's toast throttle. ]]
function MegaLever.forget(player: Player)
	noticeAt[player] = nil
end

return MegaLever
