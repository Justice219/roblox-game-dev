--!strict
--[[
	TycoonService — the authoritative tycoon: pads, producers, the payout loop, upgrades, the
	tutorial, teleports, leaderstats, and the SkipPad / Cash / world products.

	Responsibilities (spec §2, §3, §6; build plan "B5")
		Runtime   on PlotService.PlotAssigned: restore the plot (PlotBuilder, no build-in), cache
		          modifiers + producer stats, publish attributes, show the next pads, send the tutorial.
		Pads      bought by stepping on them (Touched, owner only, server reach check) or the PadBuy
		          remote (same checks); free pads skip the spend; the build appears with BuildIn.
		Producers manual cycles start on ProducerClick (owner, in reach, idle only) and pay clickPayout
		          when they finish, then the producer goes idle (owner R64: a new player's Workbench
		          is MANUAL until Uncle Atom; TycoonRules.manualStep); automated producers (Manager
		          pad owned) loop forever. ONE Heartbeat-driven loop pays
		          every player every TickSeconds: whole cycles are counted (TycoonRules.catchUp) and
		          paid in one grant per player per world per tick.
		Flavours  owner R89: both pay paths add FlavorService.batch(...) — every finished batch rolls
		          a flavour on the server (x1.5 .. x100; aggregate + bounded per tick) and the bonus
		          joins that producer's payout (Server/Tycoon/FlavorService, docs/flavors.md).
		Knockdown a knocked-down area (owner R50, Server/Tycoon/Knockdown) pauses its producer: the
		          tick skips it (no payout / auto-clicker / manager work), clicks are refused, the
		          anchor shows PausedAt, and on rebuild the cycle resumes where it stopped
		          (syncKnockdown). Upgrades + pad purchases stay allowed; nothing is removed.
		          Nuke Town only (WorldDef.features.knockdown).
		Upgrades  ProducerUpgrade(producerId, "1" | "10" | "max").
		          Owner R86: ProducerGemUpgrade(producerId) buys exactly ONE level for the flat gem
		          price (Server/Tycoon/GemUpgradeSettings, admin-adjustable; rules in
		          Shared/Tycoon/GemUpgradeRules): built, below MaxLevel, switch on, atomic
		          trySpendGems("GemUpgrade"); analytics upgradeMode "gem".
		Stats     TycoonLogic.producerStats cached per producer, recomputed only when something changes
		          (purchase, level, modifiers, a provider's validUntil) — never per tick.
		Attributes (client contract, docs/tycoon-server.md):
		          producer Anchor: ProducerId, OwnerUserId, Area, Name, Level, PerCycle, CycleTime,
		            CycleStart, Automated, Badge, BadgeNextAt, NextCost (-1 = none), PerSecond
		          Player: IncomePerSecond, TycoonArea, FeatureStandRename / FeatureAATower /
		            FeatureAttackConsole / FeatureRebirth (PlotIndex is PlotService's)
		          Player, per NON-main world w: IncomePerSecond_<w>, TycoonArea_<w>, Feature<Key>_<w>
		            (Dino Valley: FeatureRebirth_dino)
		Other     IncomePop (unreliable, owner only, throttled), leaderstats.Cash (StringValue "$1.25M")
		          + Player.CashSort (NumberValue, hidden, for custom boards), TutorialState,
		          TeleportArea (unlocked areas only), AutoClicker pass (manual cycles restart by
		          themselves while its Settings toggle `autoClicker` is ON — TycoonRules.autoClickerOn;
		          the toggle re-evaluates through SettingsService.Changed), product handlers SkipPad +
		          Cash + WorldCash + WorldStarter.

	Worlds (owner R57, plan §3.3)
		One Runtime per (player, worldId). Nuke Town's runtime is built exactly as before (on
		PlotAssigned, restoring Workspace.Plots.PlotN; leaderstats, tutorial, stand name and
		knockdown are gated by WorldDef.features, which only Nuke Town turns on). Another world's
		runtime (Dino Valley) runs its ECONOMY from join while the world is unlocked (Bones accrue
		anywhere, even without a built plot): started after the main runtime is ready and on
		ensureWorld(player, w, false). Its plot (Workspace.Worlds.<w>.Plots.PlotN, index = the main
		plot index) is restored lazily by ensureWorld(player, w, true) — idempotent, one build in
		flight per (player, world) — and kept until the player leaves.
		Pad / producer ids are globally unique (prefixed), so every handler resolves the world from
		the id (WorldsConfig.worldOfPad / worldOfProducer) and spends from THAT world's wallet only
		(PlayerDataService.trySpendCurrency with the world's currency key). Reach is measured against
		that world's plot geometry (worlds sit 6000 studs apart).
		IncomePop and the per-cycle CycleStart writes are only sent while the player is IN the
		runtime's world (server-set Player attribute CurrentWorld, WorldService); entering a world
		republishes every anchor of it.

	Security: every remote validates types (Validate), ids against config, rate limits per player,
	ownership (the plot is theirs), reach (character near the pad / producer) and state (pad
	available, producer built, idle). Clients only send intents.

	API (other services)
		TycoonService.PadBought: Signal(player, padId, skipped)   fired (deferred) after a Nuke Town purchase
		TycoonService.AreaReached: Signal(player, area)            Nuke Town area opened
		TycoonService.WorldPadBought: Signal(player, worldId, padId, skipped)   non-main worlds only
		TycoonService.WorldAreaReached: Signal(player, worldId, area)           non-main worlds only
		TycoonService.incomePerSecond(player, worldId?): number   idle income/s with cached modifiers
		TycoonService.areaIncome(player, area): number             one Nuke Town area's automated $/s (Knockdown)
		TycoonService.getModifiers(player, worldId?): Modifiers?
		TycoonService.isReady(player): boolean                     Nuke Town runtime + plot ready
		TycoonService.nextPad(player, worldId?): PadConfig?
		TycoonService.purchasePad(player, padId, opts?) -> (ok, reason?)   never yields; world from padId
		TycoonService.resetRun(player, animate?, worldId?)        rebuild runtime + plot from the profile
		TycoonService.hasFeature(player, key, worldId?): boolean
		TycoonService.ensureWorld(player, worldId, buildPlot): boolean      yields while restoring
		TycoonService.isWorldBuilt(player, worldId): boolean
		TycoonService.releaseWorld(player, worldId)                drop a non-main runtime + its plot (relock)
		TycoonService.markDirty(player, worldId?)                  nil = every world of the player
		(nil worldId = "main" everywhere: every existing caller is unchanged)

	Usage: boot list (after PlayerDataService, MonetizationService, PlotService).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

-- Owner R89 Surprise Batches: rolls each finished batch's flavour; the pay paths add its bonus.
local FlavorService = require(script.Parent.FlavorService)
local GemUpgradeRules = require(ReplicatedStorage.Shared.Tycoon.GemUpgradeRules)
local GemUpgradeSettings = require(script.Parent.GemUpgradeSettings)
local Knockdown = require(script.Parent.Knockdown)
local KnockdownConfig = require(ReplicatedStorage.Shared.Config.KnockdownConfig)
local KnockdownLogic = require(ReplicatedStorage.Shared.Tycoon.KnockdownLogic)
local ModifierSources = require(script.Parent.ModifierSources)
local MonetizationService = require(script.Parent.Parent.Services.MonetizationService)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local PetGrants = require(script.Parent.Parent.Pets.PetGrants)
local PlayerDataService = require(script.Parent.Parent.Services.PlayerDataService)
local PlotBuilder = require(script.Parent.Parent.World.PlotBuilder)
local PlotService = require(script.Parent.PlotService)
local ProgressEvents = require(script.Parent.Parent.Progression.ProgressEvents)
local QuestConfig = require(ReplicatedStorage.Shared.Config.QuestConfig)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local SettingsService = require(script.Parent.Parent.Services.SettingsService)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local TutorialLogic = require(script.Parent.TutorialLogic)
local TycoonAnalytics = require(script.Parent.TycoonAnalytics)
local TycoonConfig = require(ReplicatedStorage.Shared.Config.TycoonConfig)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)
local TycoonRules = require(script.Parent.TycoonRules)
local TycoonTypes = require(ReplicatedStorage.Shared.Tycoon.TycoonTypes)
local Validate = require(ReplicatedStorage.Shared.Net.Validate)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

type Modifiers = TycoonTypes.Modifiers
type ProducerStats = TycoonTypes.ProducerStats
type PadConfig = TycoonTypes.PadConfig
type TycoonState = TycoonTypes.TycoonState
type Logic = TycoonLogic.Logic
type WorldDef = WorldsConfig.WorldDef

local MAIN = WorldsConfig.MAIN

local TycoonService = {}

TycoonService.PadBought = Signal.new() :: Signal.Signal<Player, string, boolean>
-- Fired (deferred) when an Unlock pad opens area `area` (badges, quests, analytics listeners).
TycoonService.AreaReached = Signal.new() :: Signal.Signal<Player, number>
-- R57: the same two events for every NON-main world (PadBought / AreaReached stay Nuke Town only,
-- so every existing listener keeps its meaning).
TycoonService.WorldPadBought = Signal.new() :: Signal.Signal<Player, string, string, boolean>
TycoonService.WorldAreaReached = Signal.new() :: Signal.Signal<Player, string, number>

-- Tunables (server behaviour, not economy: the economy lives in TycoonConfig).
TycoonService.TickSeconds = 0.2 -- payout loop period
TycoonService.MaxCatchUpCycles = 5000 -- cycles paid per producer per tick at most (hitch guard)
TycoonService.MaxManualChain = 20 -- auto-clicked manual cycles paid per producer per tick at most
TycoonService.PadReach = 12 -- horizontal studs from the pad centre (touch + PadBuy)
-- Vertical allowance of the pad reach (touch + PadBuy). Owner R70: Moon Base has low gravity
-- (Client/Worlds/WorldGravity, x0.4), where a jump peaks ~19.3 studs by v²/2g and 21.8 measured
-- in Studio (the Humanoid's take-off adds a little; air time 1.47 s), so a player bouncing on a
-- pad and tapping its price mid-air must still be in reach: apex + the root height above the pad
-- + margin (tests/world-gravity.luau keeps this >= every world's apex x 1.15 + 3). The
-- horizontal 12-stud reach is what keeps it to the pad you are on.
TycoonService.PadReachVertical = 28
TycoonService.ClickReach = 60 -- horizontal studs from the producer anchor
TycoonService.ClickReachVertical = 40
TycoonService.PopSeconds = 0.5 -- min gap between IncomePop sends per producer
TycoonService.LeaderstatsSeconds = 1 -- leaderstats refresh period
TycoonService.NoticeSeconds = 2 -- min gap between "not enough cash" toasts per player
-- Lead rule (2026-10-30): teleporting to your OWN unlocked areas and to the hub is free; the
-- Teleporter pass adds teleporting to other players' plots (PlotService TeleportPlot). Kept as a
-- switch in case the rule changes.
TycoonService.TeleportNeedsPass = false
-- R57: Player attribute (server-set by WorldService) naming the world the character is in.
TycoonService.CurrentWorldAttr = "CurrentWorld"

-- Rate limiters (burst, refill per second). Shared by every world: a player is in one place.
local clickLimiter = RateLimiter.new(20, 12)
local upgradeLimiter = RateLimiter.new(15, 8)
local padLimiter = RateLimiter.new(6, 3)
local teleportLimiter = RateLimiter.new(3, 0.5)
-- Owner R86 gem upgrades: one level per intent, a confirmed press at most every few hundred ms.
local gemUpgradeLimiter = RateLimiter.new(6, 3)

-- Empty field list for markChanged: the change is saved but no snapshot field moved (world clicks).
local NO_FIELDS: { string } = table.freeze({}) :: any
-- Snapshot fields of a non-main world's tycoon / stats change (worlds.<w> structure).
local WORLD_FIELDS: { string } = table.freeze({ "worlds" }) :: any
-- Nuke Town's player-level feature attributes (legacy names, no world suffix).
local MAIN_FEATURES = table.freeze({ "StandRename", "AATower", "AttackConsole", "Rebirth" })

-- pausedAt: server time a knockdown paused this producer (owner R50), nil while it runs.
type CycleState = { start: number, running: boolean, pausedAt: number? }
type Pop = { amount: number, at: number }
type Runtime = {
	player: Player,
	profile: any,
	-- R57 world binding (Nuke Town: the module-level TycoonConfig / TycoonLogic tables).
	worldId: string,
	def: WorldDef,
	isMain: boolean,
	logic: Logic,
	economy: TycoonTypes.EconomyIndex,
	builder: PlotBuilder.WorldPlotBuilder,
	currency: string, -- wallet key ("cash" / "bones")
	attrIncome: string, -- Player attribute names ("IncomePerSecond" / "IncomePerSecond_dino")
	attrArea: string,
	plotIndex: number,
	ready: boolean, -- economy runs (stats cached); Nuke Town: also the plot is restored
	built: boolean, -- the plot of this world is restored (anchors + pads exist)
	building: boolean, -- a plot restore is in flight (ensureWorld)
	builtSignal: Signal.Signal<boolean>?, -- waiters of an in-flight restore
	present: boolean, -- the player is in this world (IncomePop / CycleStart gating)
	dirty: boolean,
	mods: Modifiers,
	modsUntil: number?,
	autoClicker: boolean,
	stats: { [string]: ProducerStats },
	cycles: { [string]: CycleState },
	income: number,
	pops: { [string]: Pop },
	tutorialStep: number,
	lastCash: number,
	noticeAt: number,
	anyPaused: boolean, -- some producer is paused by a knockdown (fast path in syncKnockdown)
	-- Owner R83: fractional "click" quest credit for auto-clicked cycles + when it was last
	-- accrued (server clock; nil = not accruing). See TycoonRules.autoClickCredit.
	autoClickBank: number,
	autoClickAt: number?,
}

-- runtimes[player][worldId]
local runtimes: { [Player]: { [string]: Runtime } } = {}

--------------------------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------------------------

local function now(): number
	return Workspace:GetServerTimeNow()
end

-- The character root of a player (nil when dead / not spawned).
local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	return if root ~= nil and root:IsA("BasePart") then root else nil
end

-- The world a player is standing in (server-set attribute; unknown / missing = Nuke Town).
local function currentWorldOf(player: Player): string
	local raw = player:GetAttribute(TycoonService.CurrentWorldAttr)
	local def = WorldsConfig.get(raw)
	return if def ~= nil then def.id else MAIN
end

-- A non-main world's saved state on a profile (nil when absent).
local function worldStateOf(profile: any, worldId: string): any
	local worlds = if type(profile) == "table" then profile.worlds else nil
	return if type(worlds) == "table" then worlds[worldId] else nil
end

-- The tycoon state a runtime plays on (read through the profile every time: a rebirth replaces it).
local function tycoonOf(rt: Runtime): TycoonState
	if rt.isMain then
		return rt.profile.tycoon
	end
	return worldStateOf(rt.profile, rt.worldId).tycoon
end

-- The wallet balance a runtime spends from (Cash / that world's currency).
local function walletOf(rt: Runtime): number
	if rt.isMain then
		return rt.profile.cash
	end
	return worldStateOf(rt.profile, rt.worldId).cash
end

-- The per-world stats a runtime counts clicks / pads into (profile.stats / worlds.<w>.stats).
local function statsOf(rt: Runtime): any
	if rt.isMain then
		return rt.profile.stats
	end
	return worldStateOf(rt.profile, rt.worldId).stats
end

-- A throttled toast (so stepping on an unaffordable pad does not spam).
local function notice(rt: Runtime, text: string)
	local t = os.clock()
	if t - rt.noticeAt >= TycoonService.NoticeSeconds then
		rt.noticeAt = t
		PlayerDataService.notify(rt.player, text, "error")
	end
end

-- The runtime of a player in a world (any state), or nil.
local function runtimeOf(player: Player, worldId: string): Runtime?
	local byWorld = runtimes[player]
	return if byWorld ~= nil then byWorld[worldId] else nil
end

-- The ready runtime of a player in a world (nil when not loaded / swapped profile / stale).
local function readyRuntime(player: Player, worldId: string?): Runtime?
	local world = worldId or MAIN
	local rt = runtimeOf(player, world)
	if rt == nil or not rt.ready or runtimeOf(player, world) ~= rt then
		return nil
	end
	if PlayerDataService.getProfile(player) ~= rt.profile then
		return nil -- profile swapped / released
	end
	return rt
end

-- The anchor of a producer on a runtime's plot (nil when the plot is not built there).
local function anchorOf(rt: Runtime, producerId: string): BasePart?
	if not rt.built then
		return nil
	end
	return rt.builder.getProducerAnchor(rt.plotIndex, producerId)
end

--------------------------------------------------------------------------------------------------
-- Stats + attributes
--------------------------------------------------------------------------------------------------

-- Publishes one producer's attributes on its anchor (unchanged values do not replicate).
local function publishProducer(rt: Runtime, producerId: string)
	local stats = rt.stats[producerId]
	local anchor = anchorOf(rt, producerId)
	if stats == nil or anchor == nil or not stats.built then
		return
	end
	local cycle = rt.cycles[producerId]
	anchor:SetAttribute("Level", stats.level)
	anchor:SetAttribute("PerCycle", if stats.automated then stats.output else stats.clickPayout)
	anchor:SetAttribute("CycleTime", stats.cycle)
	local start = 0
	if cycle ~= nil and (stats.automated or cycle.running) then
		start = cycle.start
	end
	anchor:SetAttribute("CycleStart", start)
	anchor:SetAttribute("Automated", stats.automated)
	anchor:SetAttribute("Badge", stats.badge.text)
	anchor:SetAttribute("BadgeNextAt", stats.badge.nextAt or 0)
	anchor:SetAttribute("NextCost", if stats.nextCost < math.huge then stats.nextCost else -1)
	anchor:SetAttribute("PerSecond", stats.perSecond)
	anchor:SetAttribute("OwnerUserId", rt.player.UserId)
end

-- Player-level attributes (income, area, features). Nuke Town keeps its legacy names; another
-- world suffixes them with "_<worldId>" (IncomePerSecond_dino, TycoonArea_dino, FeatureRebirth_dino).
local function publishPlayer(rt: Runtime)
	local player = rt.player
	local tycoon = tycoonOf(rt)
	player:SetAttribute(rt.attrIncome, rt.income)
	player:SetAttribute(rt.attrArea, tycoon.area)
	if rt.isMain then
		for _, feature in MAIN_FEATURES do
			player:SetAttribute("Feature" .. feature, rt.logic.hasFeature(tycoon, feature))
		end
	else
		for feature in rt.economy.FeaturePadOf do
			player:SetAttribute(`Feature{feature}_{rt.worldId}`, rt.logic.hasFeature(tycoon, feature))
		end
	end
end

--[[
	Recomputes the runtime's modifiers and every producer's stats, keeps cycles consistent (an
	automated producer whose cycle time changed keeps its bar progress; a producer that just got
	its Manager starts looping), publishes attributes. Never yields (runs inside product grants).
]]
local function refresh(rt: Runtime)
	local profile = rt.profile
	local tycoon = tycoonOf(rt)
	local logic = rt.logic
	local mods, validUntil = ModifierSources.build(rt.player, profile, nil, rt.worldId)
	rt.mods = mods
	rt.modsUntil = validUntil
	-- Owner R64: the pass clicks only while its Settings toggle is ON ("Toggle it any time");
	-- SettingsService.Changed marks the runtimes dirty when the player flips it.
	local settings: any = profile.settings
	rt.autoClicker = TycoonRules.autoClickerOn(
		MonetizationService.ownsPass(rt.player, "AutoClicker"),
		if type(settings) == "table" then settings.autoClicker else nil
	)
	rt.dirty = false
	local t = now()
	for _, cfg in rt.economy.Producers do
		local previous = rt.stats[cfg.id]
		local stats = logic.producerStats(tycoon, cfg.id, mods) :: ProducerStats
		rt.stats[cfg.id] = stats
		if not stats.built then
			rt.cycles[cfg.id] = nil
			continue
		end
		local cycle = rt.cycles[cfg.id]
		if cycle == nil then
			local fresh: CycleState = { start = t, running = false, pausedAt = nil }
			cycle = fresh
			rt.cycles[cfg.id] = fresh
		end
		if stats.automated then
			if previous == nil or not previous.automated then
				-- Just automated (or first refresh): continue a running manual cycle, else start now.
				if not cycle.running then
					cycle.start = t
				end
				cycle.running = true
			elseif previous.cycle ~= stats.cycle then
				cycle.start = TycoonRules.preservePhase(cycle.start, previous.cycle, stats.cycle, t)
			end
		end
		publishProducer(rt, cfg.id)
	end
	rt.income = logic.incomePerSecond(tycoon, mods)
	publishPlayer(rt)
end

--------------------------------------------------------------------------------------------------
-- Tutorial (Nuke Town only: WorldDef.features.tutorial)
--------------------------------------------------------------------------------------------------

-- Re-evaluates the tutorial; stores and reports a step change; sends the payload when `send`.
-- With the AutoClicker pass the producer runs by itself (clicks are no-ops while it runs), so the
-- "click your Workbench" step counts as done.
local function updateTutorial(rt: Runtime, send: boolean)
	if not rt.def.features.tutorial then
		return
	end
	local profile = rt.profile
	local clicks = profile.stats.clicks + (if rt.autoClicker then 1 else 0)
	local step = TutorialLogic.evaluate(profile.tycoon, clicks, profile.tycoon.tutorialStep)
	local changed = step ~= profile.tycoon.tutorialStep
	if changed then
		profile.tycoon.tutorialStep = step
		PlayerDataService.markChanged(rt.player, false, { "tycoon" })
		TycoonAnalytics.call("tutorialStep", rt.player, step, step == TutorialLogic.DoneStep)
	end
	if changed or send then
		Remotes.fireClient("TutorialState", rt.player, TutorialLogic.payload(step, profile.tycoon))
	end
	rt.tutorialStep = step
end

--------------------------------------------------------------------------------------------------
-- Pads
--------------------------------------------------------------------------------------------------

export type PurchaseOptions = { free: boolean?, skipped: boolean? }

--[[
	Buys a pad for a player: availability, cash (unless free), apply, save, world (press + build-in
	+ next pads), stats, tutorial, analytics, PadBought. NEVER yields (also used by the SkipPad
	receipt handler). Reach checks are the caller's job (touch / remote handlers).
	R57: the world is resolved from the pad id; the price is paid from THAT world's wallet. In a
	non-main world whose plot is not built yet (e.g. a SkipPad bought from Nuke Town) the state is
	applied and the plot shows it when it is next built.
	@param player Player
	@param padId string
	@param opts PurchaseOptions? — free = no cash spent (SkipPad, admin); skipped = analytics flag
	@return boolean, string? — ok, reason on failure ("notReady" | "unavailable" | "cash")
]]
function TycoonService.purchasePad(player: Player, padId: string, opts: PurchaseOptions?): (boolean, string?)
	local worldId = WorldsConfig.worldOfPad(padId)
	if worldId == nil then
		return false, "unavailable"
	end
	local rt = readyRuntime(player, worldId)
	if rt == nil then
		return false, "notReady"
	end
	local tycoon = tycoonOf(rt)
	local logic = rt.logic
	local pad = rt.economy.PadsById[padId]
	if pad == nil or not logic.padAvailable(tycoon, padId) then
		return false, "unavailable"
	end
	local free = opts ~= nil and opts.free == true
	if not free and pad.cost > 0 and not PlayerDataService.trySpendCurrency(player, rt.currency, pad.cost, "pad") then
		return false, "cash"
	end
	local applied = logic.applyPad(tycoon, padId)
	assert(applied, "padAvailable said yes but applyPad refused") -- cannot happen; fail loudly
	statsOf(rt).padsBought += 1
	PlayerDataService.markChanged(player, true, if rt.isMain then { "tycoon", "stats" } else WORLD_FIELDS)

	if rt.built then
		rt.builder.pressPad(rt.plotIndex, padId)
		rt.builder.buildPurchase(rt.plotIndex, padId, player)
	end
	refresh(rt)
	if rt.built then
		rt.builder.syncPads(rt.plotIndex, logic.nextPads(tycoon))
		rt.builder.syncLocked(rt.plotIndex, tycoon)
	end
	updateTutorial(rt, true)

	local skipped = opts ~= nil and opts.skipped == true
	-- Analytics routes another world's pad ids to its world recorders (Recorders.padBought).
	TycoonAnalytics.call("padBought", player, padId, skipped)
	ProgressEvents.progress(player, "pad") -- R78 Quests / Pass: a pad bought (any world)
	if pad.kind == "Manager" then
		ProgressEvents.progress(player, "manager")
	end
	if pad.unlocks ~= nil then
		PlayerDataService.notify(player, `{rt.economy.Areas[pad.unlocks].name} is open!`, "success")
	elseif pad.feature == "Rebirth" then
		if rt.isMain then
			PlayerDataService.notify(player, "You built the Mega Nuclear Facility! Rebirth is unlocked!", "reward")
		else
			PlayerDataService.notify(player, `You built the {pad.name}! {rt.def.name} Rebirth is unlocked!`, "reward")
		end
	end
	-- Deferred: listeners (attack mode, badges, ...) may yield; this function must not.
	local opened = pad.unlocks
	local isMain = rt.isMain
	task.defer(function()
		if isMain then
			TycoonService.PadBought:Fire(player, padId, skipped)
			if opened ~= nil then
				TycoonService.AreaReached:Fire(player, opened)
				ProgressEvents.progress(player, "area") -- R78 Quests / Pass: a new area
			end
		else
			TycoonService.WorldPadBought:Fire(player, worldId, padId, skipped)
			if opened ~= nil then
				TycoonAnalytics.call("worldAreaReached", player, worldId, opened)
				ProgressEvents.progress(player, "area") -- R78 Quests / Pass: a new area (any world)
				TycoonService.WorldAreaReached:Fire(player, worldId, opened)
			end
		end
	end)
	return true, nil
end

-- A pad purchase attempt by a player standing at it (touch or remote): ownership + reach + cash.
local function tryBuyPad(player: Player, plotIndex: number, padId: string)
	local worldId = WorldsConfig.worldOfPad(padId)
	local rt = if worldId ~= nil then readyRuntime(player, worldId) else nil
	if rt == nil or not rt.built or rt.plotIndex ~= plotIndex or not padLimiter:Allow(player) then
		return
	end
	local pad = rt.economy.PadsById[padId]
	if pad == nil or not rt.logic.padAvailable(tycoonOf(rt), padId) then
		return
	end
	local model = rt.builder.getPad(plotIndex, padId)
	if model == nil or model:GetAttribute("PressedAt") ~= nil then
		return
	end
	local root = rootOf(player)
	local position = rt.builder.padPosition(plotIndex, padId)
	if
		not TycoonRules.withinReach(
			if root ~= nil then root.Position else nil,
			position,
			TycoonService.PadReach,
			TycoonService.PadReachVertical
		)
	then
		return
	end
	local wallet = walletOf(rt)
	if pad.cost > wallet then
		local short = pad.cost - wallet
		local shown = if rt.isMain
			then NumberFormat.money(short)
			else `{NumberFormat.short(short)} {rt.def.currency.name}`
		notice(rt, `Need {shown} more for {pad.name}!`)
		return
	end
	TycoonService.purchasePad(player, padId, nil)
end

-- PlotBuilder → a pad's trigger was touched.
local function onPadTouched(plotIndex: number, padId: string, hit: BasePart)
	local character = hit:FindFirstAncestorOfClass("Model")
	local player = if character ~= nil then Players:GetPlayerFromCharacter(character) else nil
	if player == nil or PlotService.getPlotIndex(player) ~= plotIndex then
		return -- only the owner's own character buys
	end
	tryBuyPad(player, plotIndex, padId)
end

-- PadBuy(padId): touch / gamepad fallback, same checks as stepping on the pad.
local function onPadBuy(player: Player, rawId: unknown)
	local padId = Validate.key(rawId, 48)
	local plotIndex = PlotService.getPlotIndex(player)
	if padId == nil or plotIndex == nil or WorldsConfig.worldOfPad(padId) == nil then
		return
	end
	tryBuyPad(player, plotIndex, padId)
end

--------------------------------------------------------------------------------------------------
-- Producers
--------------------------------------------------------------------------------------------------

-- Starts a manual cycle from a ProducerClick (the auto clicker starts its cycles inside
-- TycoonRules.manualStep on the tick). Caller checked it is idle + not automated.
local function startManualCycle(rt: Runtime, producerId: string, t: number)
	local cycle = rt.cycles[producerId]
	if cycle == nil then
		return
	end
	cycle.start = t
	cycle.running = true
	local anchor = if rt.present then anchorOf(rt, producerId) else nil
	if anchor ~= nil then
		anchor:SetAttribute("CycleStart", t)
	end
end

-- ProducerClick(producerId): run one manual cycle of an un-managed, idle producer in reach.
local function onProducerClick(player: Player, rawId: unknown)
	if not clickLimiter:Allow(player) then
		return
	end
	local producerId = Validate.key(rawId, 32)
	local worldId = WorldsConfig.worldOfProducer(producerId)
	local rt = if worldId ~= nil then readyRuntime(player, worldId) else nil
	if producerId == nil or rt == nil or not rt.built then
		return
	end
	local stats = rt.stats[producerId]
	local cycle = rt.cycles[producerId]
	if stats == nil or not stats.built or stats.automated or cycle == nil or cycle.running then
		return
	end
	-- A knocked-down area (owner R50) does not produce until it is rebuilt (Nuke Town only).
	if rt.def.features.knockdown then
		local producerCfg = rt.economy.ProducersById[producerId]
		if cycle.pausedAt ~= nil or (producerCfg ~= nil and Knockdown.isDown(player, producerCfg.area)) then
			notice(rt, "This area got knocked down! Tap REBUILD to fix it faster!")
			return
		end
	end
	local anchor = anchorOf(rt, producerId)
	local root = rootOf(player)
	if
		anchor == nil
		or not TycoonRules.withinReach(
			if root ~= nil then root.Position else nil,
			anchor.Position,
			TycoonService.ClickReach,
			TycoonService.ClickReachVertical
		)
	then
		return
	end
	startManualCycle(rt, producerId, now())
	statsOf(rt).clicks += 1
	PlayerDataService.markChanged(player, false, if rt.isMain then { "stats" } else NO_FIELDS)
	TycoonAnalytics.call("producerClick", player, producerId)
	ProgressEvents.progress(player, "click") -- R78 Quests / Pass: one manual cycle
	if rt.tutorialStep <= 2 then
		updateTutorial(rt, false)
	end
end

-- ProducerUpgrade(producerId, mode): buy levels (paid from the producer's world wallet).
local function onProducerUpgrade(player: Player, rawId: unknown, rawMode: unknown)
	if not upgradeLimiter:Allow(player) then
		return
	end
	local producerId = Validate.key(rawId, 32)
	local mode = Validate.oneOf(rawMode, TycoonRules.UpgradeModes)
	local worldId = WorldsConfig.worldOfProducer(producerId)
	local rt = if worldId ~= nil then readyRuntime(player, worldId) else nil
	local cfg = if producerId ~= nil and rt ~= nil then rt.economy.ProducersById[producerId] else nil
	if cfg == nil or mode == nil or rt == nil then
		return
	end
	local tycoon = tycoonOf(rt)
	local level = rt.logic.levelOf(tycoon, cfg.id)
	if level < 1 then
		return
	end
	local count, cost = TycoonRules.upgradeCount(mode, cfg, level, walletOf(rt), rt.logic)
	if count <= 0 then
		if level < rt.economy.MaxLevel then
			notice(
				rt,
				if rt.isMain
					then "Not enough cash for that upgrade!"
					else `Not enough {rt.def.currency.name} for that upgrade!`
			)
		end
		return
	end
	if not PlayerDataService.trySpendCurrency(player, rt.currency, cost, "upgrade") then
		return
	end
	local newLevel = rt.logic.applyLevels(tycoon, cfg.id, count)
	PlayerDataService.markChanged(player, false, if rt.isMain then { "tycoon" } else WORLD_FIELDS)
	refresh(rt)
	TycoonAnalytics.call("producerUpgraded", player, cfg.id, level, newLevel, mode)
	ProgressEvents.progress(player, "upgrade", newLevel - level) -- R78 Quests / Pass: levels bought
	if rt.tutorialStep <= 3 then
		updateTutorial(rt, false)
	end
end

--[[
	ProducerGemUpgrade(producerId): owner R86 "just buy the next upgrade with gems ... it stays at
	the same price for everything". Buys exactly ONE level of an own producer for the flat gem price
	(GemUpgradeSettings.price(), admin-adjustable; never a client value), in any world. Same reach
	rules as the cash upgrade (built, level >= 1; no distance rule: the billboard is pressable
	wherever it is drawn), plus: below MaxLevel and the admin switch on (GemUpgradeRules.check).
	The gem spend is atomic (PlayerDataService.trySpendGems checks and deducts in one step); a level
	that could not be applied after the spend is refunded the same frame.
]]
local function onProducerGemUpgrade(player: Player, rawId: unknown)
	if not gemUpgradeLimiter:Allow(player) then
		return
	end
	local producerId = Validate.key(rawId, 32)
	local worldId = WorldsConfig.worldOfProducer(producerId)
	local rt = if worldId ~= nil then readyRuntime(player, worldId) else nil
	local cfg = if producerId ~= nil and rt ~= nil then rt.economy.ProducersById[producerId] else nil
	if cfg == nil or rt == nil then
		return
	end
	local tycoon = tycoonOf(rt)
	local level = rt.logic.levelOf(tycoon, cfg.id)
	local price = GemUpgradeSettings.price()
	local ok, reason = GemUpgradeRules.check({
		enabled = GemUpgradeSettings.enabled(),
		level = level,
		maxLevel = rt.economy.MaxLevel,
		gems = PlayerDataService.balance(rt.profile, "gems"),
		price = price,
	})
	if not ok then
		if reason == "gems" then
			notice(rt, `You need {price} gems for a gem upgrade!`)
		end
		return
	end
	if not PlayerDataService.trySpendGems(player, price, TycoonConfig.GemUpgrade.Reason) then
		notice(rt, `You need {price} gems for a gem upgrade!`)
		return
	end
	local newLevel = rt.logic.applyLevels(tycoon, cfg.id, 1)
	if newLevel <= level then
		-- Nothing applied (cannot happen after the checks above): give the gems straight back.
		PlayerDataService.grantGems(player, price, "GemUpgradeRefund")
		return
	end
	PlayerDataService.markChanged(player, false, if rt.isMain then { "tycoon" } else WORLD_FIELDS)
	refresh(rt)
	TycoonAnalytics.call("producerUpgraded", player, cfg.id, level, newLevel, "gem")
	ProgressEvents.progress(player, "upgrade", newLevel - level) -- R78 Quests / Pass: a level bought
	if rt.tutorialStep <= 3 then
		updateTutorial(rt, false)
	end
end

--------------------------------------------------------------------------------------------------
-- Payout loop
--------------------------------------------------------------------------------------------------

-- Adds a payout to a producer's IncomePop accumulator and sends it when due (only while the
-- player is in this runtime's world: a pop from another world would float over nothing).
local function pop(rt: Runtime, producerId: string, amount: number, t: number)
	if not rt.present then
		return
	end
	local entry = rt.pops[producerId]
	if entry == nil then
		entry = { amount = 0, at = 0 }
		rt.pops[producerId] = entry
	end
	entry.amount += amount
	if t - entry.at >= TycoonService.PopSeconds then
		Remotes.fireUnreliableClient("IncomePop", rt.player, { producerId = producerId, amount = entry.amount })
		entry.amount = 0
		entry.at = t
	end
end

--[[
	Pauses / resumes producers around knockdowns (owner R50, Server/Tycoon/Knockdown). A producer
	whose area is down stops completely — no payout, no auto-clicker chain, no manager work — and
	its anchor shows `PausedAt` (billboards freeze the bar). When the area is back up the cycle
	origin moves forward by the paused time (KnockdownLogic.resumeStart), so the bar continues
	where it stopped and nothing done during the pause is paid. Nothing is ever taken away.
	Cost: one table lookup per tick unless a knockdown is active or something is still paused.
	Nuke Town only (WorldDef.features.knockdown; the caller checks).
]]
local function syncKnockdown(rt: Runtime, t: number)
	local areas = Knockdown.activeAreas(rt.player)
	if areas == nil and not rt.anyPaused then
		return
	end
	local anyPaused = false
	for producerId, cycle in rt.cycles do
		local cfg = rt.economy.ProducersById[producerId]
		local entry = if areas ~= nil and cfg ~= nil then areas[cfg.area] else nil
		local down = entry ~= nil and entry.untilTime > t
		local pausedAt = cycle.pausedAt
		if down and pausedAt == nil then
			cycle.pausedAt = t
			local anchor = anchorOf(rt, producerId)
			if anchor ~= nil then
				anchor:SetAttribute(KnockdownConfig.Attr.PausedAt, t)
			end
		elseif not down and pausedAt ~= nil then
			local stats = rt.stats[producerId]
			if stats ~= nil and stats.built and (stats.automated or cycle.running) then
				cycle.start = KnockdownLogic.resumeStart(cycle.start, stats.cycle, pausedAt, t)
			end
			cycle.pausedAt = nil
			local anchor = anchorOf(rt, producerId)
			if anchor ~= nil then
				anchor:SetAttribute(KnockdownConfig.Attr.PausedAt, nil)
			end
			publishProducer(rt, producerId) -- republishes the shifted CycleStart
		end
		anyPaused = anyPaused or cycle.pausedAt ~= nil
	end
	rt.anyPaused = anyPaused
end

-- One tick for one runtime (a player in one world): pays every finished cycle in a single grant
-- of that world's currency.
local function tickRuntime(rt: Runtime, t: number, wall: number)
	if rt.dirty or (rt.modsUntil ~= nil and wall >= rt.modsUntil) then
		refresh(rt)
		if rt.tutorialStep == 2 then
			updateTutorial(rt, false) -- e.g. the AutoClicker pass was just bought
		end
	end
	if rt.def.features.knockdown then
		syncKnockdown(rt, t)
	end
	local total = 0
	local autoClicked = 0 -- R83: cycles the AutoClicker pass finished this tick (quest credit)
	for producerId, cycle in rt.cycles do
		local stats = rt.stats[producerId]
		if stats == nil or not stats.built or cycle.pausedAt ~= nil then
			continue -- unbuilt, or its area is knocked down (paused: nothing runs or pays)
		end
		if stats.automated then
			local cycles, newStart = TycoonRules.catchUp(cycle.start, stats.cycle, t, TycoonService.MaxCatchUpCycles)
			if cycles > 0 then
				local amount = cycles * stats.output
				-- Owner R89: each batch rolls a flavour (aggregate, bounded); add its bonus.
				amount += FlavorService.batch(rt.player, rt.worldId, producerId, cycles, stats.output, rt.present)
				local expected = cycle.start + cycles * stats.cycle
				cycle.start = newStart
				total += amount
				pop(rt, producerId, amount, t)
				TycoonAnalytics.income(rt.player, producerId, amount, true)
				if newStart ~= expected and rt.present then
					publishProducer(rt, producerId) -- a hitch restarted the phase
				end
			end
		else
			-- Clicked cycles (owner R64: un-managed producers only run when clicked): pay each
			-- finished one once, then go idle until the next click — unless the AutoClicker pass is
			-- on (rt.autoClicker), which chains the next cycle (TycoonRules.manualStep).
			local wasRunning, wasStart = cycle.running, cycle.start
			local paid, running, start = TycoonRules.manualStep(
				wasRunning,
				wasStart,
				stats.cycle,
				t,
				rt.autoClicker,
				TycoonService.MaxManualChain
			)
			cycle.running, cycle.start = running, start
			if paid > 0 then
				local amount = paid * stats.clickPayout
				-- Owner R89: clicked batches roll flavours too (same server rolls as automated ones).
				amount += FlavorService.batch(rt.player, rt.worldId, producerId, paid, stats.clickPayout, rt.present)
				total += amount
				pop(rt, producerId, amount, t)
				TycoonAnalytics.income(rt.player, producerId, amount, false)
				if rt.autoClicker then
					autoClicked += paid
				end
			end
			if running ~= wasRunning or start ~= wasStart then
				local anchor = if rt.present then anchorOf(rt, producerId) else nil
				if anchor ~= nil then
					anchor:SetAttribute("CycleStart", if running then start else 0)
				end
			end
		end
	end
	if total > 0 then
		PlayerDataService.grantCurrency(rt.player, rt.currency, total, "producer")
	end
	-- Owner R83: the AutoClicker pass makes manual clicks no-ops, so its cycles count as "click"
	-- quest progress instead — only in the world the player is in (like a real click), at a
	-- human-like rate (QuestConfig.AutoClickCreditPerSecond). stats.clicks (manual clicks, the
	-- tutorial counter) is untouched.
	if rt.autoClicker and rt.present then
		local last = rt.autoClickAt
		local credit, bank = TycoonRules.autoClickCredit(
			rt.autoClickBank,
			if last ~= nil then t - last else 0,
			QuestConfig.AutoClickCreditPerSecond,
			autoClicked
		)
		rt.autoClickBank, rt.autoClickAt = bank, t
		if credit > 0 then
			ProgressEvents.progress(rt.player, "click", credit)
		end
	else
		rt.autoClickBank, rt.autoClickAt = 0, nil
	end
end

-- Leaderstats: formatted Cash for the player list + hidden numeric CashSort.
local function ensureLeaderstats(player: Player)
	if player:FindFirstChild("leaderstats") ~= nil then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"
	local cash = Instance.new("StringValue")
	cash.Name = "Cash"
	cash.Value = "$0"
	cash.Parent = folder
	folder.Parent = player
	local sort = Instance.new("NumberValue")
	sort.Name = "CashSort"
	sort.Parent = player
end

-- Refreshes leaderstats from a runtime whose world shows in them (Nuke Town's Cash).
local function updateLeaderstats(rt: Runtime)
	if not rt.def.features.leaderstats then
		return
	end
	local cash = walletOf(rt)
	if cash == rt.lastCash then
		return
	end
	rt.lastCash = cash
	local folder = rt.player:FindFirstChild("leaderstats")
	local value = if folder ~= nil then folder:FindFirstChild("Cash") else nil
	if value ~= nil and value:IsA("StringValue") then
		value.Value = NumberFormat.money(cash)
	end
	local sort = rt.player:FindFirstChild("CashSort")
	if sort ~= nil and sort:IsA("NumberValue") then
		sort.Value = cash
	end
end

--------------------------------------------------------------------------------------------------
-- Runtime lifecycle
--------------------------------------------------------------------------------------------------

-- A fresh (not ready) runtime of a player in a world.
local function newRuntime(player: Player, profile: any, def: WorldDef, plotIndex: number): Runtime
	local isMain = def.id == MAIN
	local rt: Runtime = {
		player = player,
		profile = profile,
		worldId = def.id,
		def = def,
		isMain = isMain,
		-- Nuke Town keeps the exact module tables every other system reads.
		logic = if isMain then TycoonLogic :: any else TycoonLogic.forWorld(def.id),
		economy = if isMain then TycoonConfig :: any else def.economy,
		builder = PlotBuilder.world(def.id),
		currency = def.currency.key,
		attrIncome = if isMain then "IncomePerSecond" else `IncomePerSecond_{def.id}`,
		attrArea = if isMain then "TycoonArea" else `TycoonArea_{def.id}`,
		plotIndex = plotIndex,
		ready = false,
		built = false,
		building = false,
		builtSignal = nil,
		present = currentWorldOf(player) == def.id,
		dirty = true,
		mods = {},
		modsUntil = nil,
		autoClicker = false,
		stats = {},
		cycles = {},
		income = 0,
		pops = {},
		tutorialStep = 0,
		lastCash = -1,
		noticeAt = 0,
		anyPaused = false,
		autoClickBank = 0,
		autoClickAt = nil,
	}
	return rt
end

-- Stores a runtime under (player, world).
local function storeRuntime(rt: Runtime)
	local byWorld = runtimes[rt.player]
	if byWorld == nil then
		byWorld = {}
		runtimes[rt.player] = byWorld
	end
	byWorld[rt.worldId] = rt
end

-- Producer anchors restore did not create (state with a level but no area): ensure them.
local function ensureAnchors(rt: Runtime)
	local tycoon = tycoonOf(rt)
	for _, cfg in rt.economy.Producers do
		if rt.logic.levelOf(tycoon, cfg.id) >= 1 then
			rt.builder.ensureProducer(rt.plotIndex, cfg.id)
		end
	end
end

-- Forward declaration: starts the economy runtimes of every unlocked non-main world (no plot).
local startUnlockedWorlds: (player: Player) -> ()

--[[
	Builds a player's Nuke Town runtime on their plot: restores the world (yields while meshes
	load), then caches stats, publishes attributes, shows the next pads and the tutorial. Stale
	setups (the player left / was reset meanwhile) stop silently.
]]
local function setup(player: Player, plotIndex: number, skipRestore: boolean?)
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return
	end
	local rt = newRuntime(player, profile, WorldsConfig.Worlds[MAIN], plotIndex)
	storeRuntime(rt)
	if not skipRestore and not PlotBuilder.restore(plotIndex, profile.tycoon) then
		return
	end
	if runtimeOf(player, MAIN) ~= rt then
		return
	end
	if PlayerDataService.getProfile(player) ~= profile then
		return
	end
	ensureAnchors(rt)
	rt.built = true
	rt.ready = true
	refresh(rt)
	PlotBuilder.syncPads(plotIndex, TycoonLogic.nextPads(profile.tycoon))
	PlotService.applyStandName(player)
	updateTutorial(rt, true)
	updateLeaderstats(rt)
	-- R57: unlocked worlds earn from join (Bones accrue while the player plays Nuke Town).
	startUnlockedWorlds(player)
end

-- Drops one runtime of a player (its plot is the caller's business).
local function dropRuntime(player: Player, worldId: string)
	local byWorld = runtimes[player]
	local rt = if byWorld ~= nil then byWorld[worldId] else nil
	if byWorld == nil or rt == nil then
		return
	end
	byWorld[worldId] = nil
	-- Wake anyone waiting on an in-flight restore of this runtime (they re-check and see it gone).
	local waiting = rt.builtSignal
	if waiting ~= nil then
		rt.builtSignal = nil
		waiting:Fire(false)
	end
end

-- Drops a player's Nuke Town runtime (resetRun / rebuild: other worlds keep running).
local function teardown(player: Player)
	dropRuntime(player, MAIN)
end

-- Drops every runtime of a player (leave / plot released); clears their non-main plots.
local function teardownAll(player: Player)
	local byWorld = runtimes[player]
	if byWorld == nil then
		return
	end
	local worldIds: { string } = {}
	for worldId in byWorld do
		table.insert(worldIds, worldId)
	end
	for _, worldId in worldIds do
		local rt = byWorld[worldId]
		dropRuntime(player, worldId)
		if rt ~= nil and not rt.isMain and (rt.built or rt.building) then
			rt.builder.clear(rt.plotIndex)
		end
	end
	runtimes[player] = nil
	TycoonAnalytics.forget(player)
end

--[[
	Starts (or returns) a player's runtime in a NON-main world, without a plot. Never yields.
	Requires a loaded profile, a main plot (the world plot index) and an unlocked world.
	@return Runtime?
]]
local function startWorld(player: Player, def: WorldDef): Runtime?
	local existing = runtimeOf(player, def.id)
	if existing ~= nil then
		return existing
	end
	local profile = PlayerDataService.getProfile(player)
	local plotIndex = PlotService.getPlotIndex(player)
	local state = worldStateOf(profile, def.id)
	if profile == nil or plotIndex == nil or state == nil or state.unlocked ~= true then
		return nil
	end
	local rt = newRuntime(player, profile, def, plotIndex)
	rt.ready = true
	storeRuntime(rt)
	refresh(rt)
	return rt
end

startUnlockedWorlds = function(player: Player)
	for _, def in WorldsConfig.extra() do
		startWorld(player, def)
	end
end

--[[
	Restores a non-main runtime's plot (yields while meshes load). One restore in flight per
	runtime; concurrent callers wait for it. Stale builds (runtime dropped / profile swapped) stop.
	@return boolean — the plot is built
]]
local function buildWorldPlot(rt: Runtime): boolean
	if rt.built then
		return true
	end
	if rt.building then
		local waiting = rt.builtSignal
		if waiting ~= nil then
			waiting:Wait()
		end
		return rt.built and runtimeOf(rt.player, rt.worldId) == rt
	end
	rt.building = true
	local signal = Signal.new() :: Signal.Signal<boolean>
	rt.builtSignal = signal
	local player = rt.player
	local ok = rt.builder.restore(rt.plotIndex, tycoonOf(rt))
	local current = runtimeOf(player, rt.worldId) == rt and PlayerDataService.getProfile(player) == rt.profile
	if ok and current then
		ensureAnchors(rt)
		rt.built = true
		refresh(rt) -- publishes every anchor
		rt.builder.syncPads(rt.plotIndex, rt.logic.nextPads(tycoonOf(rt)))
	end
	rt.building = false
	if rt.builtSignal == signal then
		rt.builtSignal = nil
	end
	signal:Fire(rt.built)
	return rt.built and current
end

--[[
	Rebuilds a player's runtime and plot from their current profile (rebirth, admin reset /
	rebuild). `animate` = true replays the build-in for every build (admin "replay build-in").
	Yields while the plot rebuilds.
	R57: `worldId` (nil = Nuke Town, unchanged) rebuilds that world only; a non-main world whose
	plot was not built only restarts its economy runtime (its plot stays lazy).
	@param player Player
	@param animate boolean?
	@param worldId string?
]]
function TycoonService.resetRun(player: Player, animate: boolean?, worldId: string?)
	local plotIndex = PlotService.getPlotIndex(player)
	if plotIndex == nil then
		return
	end
	local def = WorldsConfig.get(worldId or MAIN)
	if def == nil then
		return
	end
	if def.id ~= MAIN then
		local previous = runtimeOf(player, def.id)
		local wasBuilt = previous ~= nil and (previous.built or previous.building)
		dropRuntime(player, def.id)
		local builder = PlotBuilder.world(def.id)
		if wasBuilt then
			builder.clear(plotIndex)
		end
		local rt = startWorld(player, def)
		if rt == nil or not wasBuilt then
			return
		end
		if animate then
			-- Replay: an empty plot, then every owned pad's build with BuildIn, in buy order.
			local tycoon = tycoonOf(rt)
			local owned = table.clone(tycoon.pads)
			local empty = rt.logic.newState()
			empty.producers = tycoon.producers
			rt.building = true
			builder.restore(plotIndex, empty)
			for _, pad in rt.economy.PadOrder do
				if owned[pad.id] and runtimeOf(player, def.id) == rt then
					builder.buildPurchase(plotIndex, pad.id, player)
					task.wait(0.15)
				end
			end
			rt.building = false
			if runtimeOf(player, def.id) ~= rt then
				return
			end
			ensureAnchors(rt)
			rt.built = true
			refresh(rt)
			builder.syncPads(plotIndex, rt.logic.nextPads(tycoonOf(rt)))
			builder.syncLocked(plotIndex, tycoonOf(rt))
			return
		end
		buildWorldPlot(rt)
		return
	end
	-- Knockdowns never survive a rebuild / rebirth (owner R50: temporary, never saved).
	Knockdown.reset(player)
	teardown(player)
	PlotBuilder.clear(plotIndex)
	if animate then
		local profile = PlayerDataService.getProfile(player)
		if profile == nil then
			return
		end
		-- Replay: restore an empty plot, then "buy" every owned pad's build with BuildIn, in order.
		local owned = table.clone(profile.tycoon.pads)
		local empty = TycoonLogic.newState()
		empty.producers = profile.tycoon.producers
		PlotBuilder.restore(plotIndex, empty)
		for _, pad in TycoonConfig.PadOrder do
			if owned[pad.id] then
				PlotBuilder.buildPurchase(plotIndex, pad.id, player)
				task.wait(0.15)
			end
		end
		setup(player, plotIndex, true)
		return
	end
	setup(player, plotIndex)
end

--[[
	Admin / tooling: gives a player pads for free, in chain order, WITHOUT analytics (they are not
	real purchases). `animate` = every new build plays its build-in (staggered); otherwise the
	plot is rebuilt instantly. Pads that are not reachable in order are skipped.
	R57: the world comes from the pad ids (the first known id decides; ids of other worlds are
	ignored). A non-main world without a built plot only updates its state + economy.
	Areas opened by the grant (TycoonRules.reachedAreas: each applied Unlock pad's area above the
	area before, once) fire AreaReached (Nuke Town) / worldAreaReached + WorldAreaReached (other
	worlds) deferred, in order, exactly like natural purchases, so world unlocks (WorldService),
	badges and the world funnel follow an admin jump. PadBought is NOT fired: grants are not
	purchases (pad / quest / attack listeners count real buys).
	@param player Player
	@param padIds {string} — pads to own (any order; applied in chain order)
	@param animate boolean
	@return number — pads newly owned
]]
function TycoonService.grantPads(player: Player, padIds: { string }, animate: boolean): number
	local worldId: string? = nil
	for _, padId in padIds do
		worldId = WorldsConfig.worldOfPad(padId)
		if worldId ~= nil then
			break
		end
	end
	local rt = readyRuntime(player, worldId or MAIN)
	if rt == nil then
		return 0
	end
	local wanted: { [string]: boolean } = {}
	for _, padId in padIds do
		wanted[padId] = true
	end
	local tycoon = tycoonOf(rt)
	local areaBefore = tycoon.area
	local applied: { string } = {}
	for _, pad in rt.economy.PadOrder do
		if wanted[pad.id] and rt.logic.applyPad(tycoon, pad.id) then
			table.insert(applied, pad.id)
		end
	end
	if #applied == 0 then
		return 0
	end
	PlayerDataService.markChanged(player, true, if rt.isMain then { "tycoon" } else WORLD_FIELDS)
	-- Announce every newly opened area like a purchase does (deferred: listeners may yield; one
	-- thread keeps them in order).
	local opened = TycoonRules.reachedAreas(rt.economy.PadsById, applied, areaBefore)
	if #opened > 0 then
		local isMain, world = rt.isMain, rt.worldId
		task.defer(function()
			for _, area in opened do
				if isMain then
					TycoonService.AreaReached:Fire(player, area)
				else
					TycoonAnalytics.call("worldAreaReached", player, world, area)
					TycoonService.WorldAreaReached:Fire(player, world, area)
				end
			end
		end)
	end
	if not rt.built then
		refresh(rt) -- a non-main world without a plot: the economy picks the pads up at once
		return #applied
	end
	if not animate then
		task.spawn(TycoonService.resetRun, player, false, rt.worldId)
		return #applied
	end
	for order, padId in applied do
		rt.builder.pressPad(rt.plotIndex, padId)
		task.delay((order - 1) * 0.12, function()
			if runtimeOf(player, rt.worldId) == rt then
				rt.builder.buildPurchase(rt.plotIndex, padId, player)
			end
		end)
	end
	-- Producer anchors are needed now so attributes can be published.
	ensureAnchors(rt)
	refresh(rt)
	rt.builder.syncPads(rt.plotIndex, rt.logic.nextPads(tycoon))
	rt.builder.syncLocked(rt.plotIndex, tycoon)
	updateTutorial(rt, true)
	return #applied
end

--------------------------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------------------------

--[[
	Idle income/s with the player's cached modifiers (0 when not loaded).
	@param player Player
	@param worldId string? — R57: nil = Nuke Town ($/s); "dino" = Bones/s
]]
function TycoonService.incomePerSecond(player: Player, worldId: string?): number
	local world = worldId or MAIN
	local rt = runtimeOf(player, world)
	if rt ~= nil and rt.ready then
		return rt.income
	end
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return 0
	end
	if world == MAIN then
		return TycoonLogic.incomePerSecond(profile.tycoon, (ModifierSources.build(player, profile)))
	end
	local def = WorldsConfig.get(world)
	local state = worldStateOf(profile, world)
	if def == nil or state == nil then
		return 0
	end
	return TycoonLogic.forWorld(def.id)
		.incomePerSecond(state.tycoon, (ModifierSources.build(player, profile, nil, def.id)))
end

--[[
	Idle $/s of one area's producer with the cached modifiers: its automated perSecond (0 when it
	is manual, unbuilt, or the player is not loaded). Same basis as IncomePerSecond, so Knockdown /
	attack rewards scale with what the knocked area really earns. Nuke Town only.
	Example: TycoonService.areaIncome(player, 3) --> 1250
]]
function TycoonService.areaIncome(player: Player, area: number): number
	local rt = readyRuntime(player, MAIN)
	local areaCfg = if type(area) == "number" then TycoonConfig.Areas[area] else nil
	if rt == nil or areaCfg == nil then
		return 0
	end
	local stats = rt.stats[areaCfg.producer.id]
	return if stats ~= nil and stats.built and stats.automated then stats.perSecond else 0
end

--[[ The player's cached Modifiers of a world (nil when not ready). nil worldId = Nuke Town. ]]
function TycoonService.getModifiers(player: Player, worldId: string?): Modifiers?
	local rt = readyRuntime(player, worldId)
	return if rt ~= nil then rt.mods else nil
end

--[[ True once the player's Nuke Town plot is restored and the runtime runs. ]]
function TycoonService.isReady(player: Player): boolean
	return readyRuntime(player, MAIN) ~= nil
end

--[[ The next pad of the player's chain in a world, or nil (all owned / not loaded / no such world). ]]
function TycoonService.nextPad(player: Player, worldId: string?): PadConfig?
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return nil
	end
	local world = worldId or MAIN
	if world == MAIN then
		return TycoonLogic.nextPads(profile.tycoon)[1]
	end
	local def = WorldsConfig.get(world)
	local state = worldStateOf(profile, world)
	if def == nil or state == nil then
		return nil
	end
	return TycoonLogic.forWorld(def.id).nextPads(state.tycoon)[1]
end

--[[
	True when the player bought the pad that unlocks a feature ("StandRename", "AATower", ...;
	Dino Valley: "Rebirth"). nil worldId = Nuke Town.
]]
function TycoonService.hasFeature(player: Player, feature: string, worldId: string?): boolean
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return false
	end
	local world = worldId or MAIN
	if world == MAIN then
		return TycoonLogic.hasFeature(profile.tycoon, feature)
	end
	local def = WorldsConfig.get(world)
	local state = worldStateOf(profile, world)
	return def ~= nil and state ~= nil and TycoonLogic.forWorld(def.id).hasFeature(state.tycoon, feature)
end

--[[
	Marks a player's stats for recompute on the next tick (e.g. after an admin profile edit).
	@param worldId string? — that world only; nil = every world of the player
]]
function TycoonService.markDirty(player: Player, worldId: string?)
	local byWorld = runtimes[player]
	if byWorld == nil then
		return
	end
	if worldId ~= nil then
		local rt = byWorld[worldId]
		if rt ~= nil then
			rt.dirty = true
		end
		return
	end
	for _, rt in byWorld do
		rt.dirty = true
	end
end

--[[
	R57: makes sure a player has a runtime in a world, and (buildPlot) that their plot there is
	restored. Idempotent; one restore in flight per (player, world) (concurrent callers wait).
	Yields while the plot restores. Nuke Town's runtime is PlotAssigned's: for "main" this only
	reports readiness.
	@param player Player — the plot OWNER (a visit to someone's plot builds theirs)
	@param worldId string
	@param buildPlot boolean
	@return boolean — false when the world is unknown / locked, the player has no main plot or
	        profile, or the build went stale (they left / were reset meanwhile)
	Example: if TycoonService.ensureWorld(player, "dino", true) then -- pivot into the Valley
]]
function TycoonService.ensureWorld(player: Player, worldId: string, buildPlot: boolean): boolean
	local def = WorldsConfig.get(worldId)
	if def == nil then
		return false
	end
	if def.id == MAIN then
		return TycoonService.isReady(player)
	end
	local rt = startWorld(player, def)
	if rt == nil then
		return false
	end
	if not buildPlot then
		return true
	end
	return buildWorldPlot(rt)
end

--[[ R57: true once the player's plot in `worldId` is restored (Nuke Town: isReady). ]]
function TycoonService.isWorldBuilt(player: Player, worldId: string): boolean
	if worldId == MAIN then
		return TycoonService.isReady(player)
	end
	local rt = readyRuntime(player, worldId)
	return rt ~= nil and rt.built
end

--[[
	R57: drops a player's NON-main world runtime and clears its plot (admin relock / wipe). Data
	is untouched. Nuke Town is never released this way.
]]
function TycoonService.releaseWorld(player: Player, worldId: string)
	if worldId == MAIN then
		return
	end
	local rt = runtimeOf(player, worldId)
	if rt == nil then
		return
	end
	dropRuntime(player, worldId)
	if rt.built or rt.building then
		rt.builder.clear(rt.plotIndex)
	end
end

--------------------------------------------------------------------------------------------------
-- Products (handlers must not yield; they apply the change as the last step)
--------------------------------------------------------------------------------------------------

-- "Cash": incomeSeconds of the buyer's idle income, at least the floor.
local function grantCashPack(player: Player, _profile: any, product: any, _receipt: any): boolean
	local amount = TycoonRules.cashPackAmount(
		product.incomeSeconds or 0,
		product.cashFloor or 0,
		TycoonService.incomePerSecond(player)
	)
	if amount <= 0 then
		return false
	end
	PlayerDataService.grantCash(player, amount, "cashPack")
	return true
end

-- The world a SkipPad applies to: the one the buyer stands in (when it runs for them), else Nuke Town.
local function skipWorldOf(player: Player): string
	local world = currentWorldOf(player)
	if world ~= MAIN and readyRuntime(player, world) == nil then
		return MAIN
	end
	return world
end

-- "SkipPad": the next pad of the world you stand in, free, with build-in. Every pad owned → the
-- fallback grant (in that world's currency).
local function grantSkipPad(player: Player, profile: any, _product: any, _receipt: any): boolean
	local world = skipWorldOf(player)
	if world == MAIN then
		local nextPad = TycoonLogic.nextPads(profile.tycoon)[1]
		if nextPad == nil then
			local amount = TycoonRules.fallbackGrant(TycoonService.incomePerSecond(player))
			PlayerDataService.grantCash(player, amount, "skipPadFallback")
			return true
		end
		local ok = TycoonService.purchasePad(player, nextPad.id, { free = true, skipped = true })
		return ok -- false (plot still loading) → the receipt is retried later
	end
	local rt = readyRuntime(player, world) :: Runtime
	local nextPad = rt.logic.nextPads(tycoonOf(rt))[1]
	if nextPad == nil then
		local amount = TycoonRules.fallbackGrant(rt.income)
		PlayerDataService.grantCurrency(player, rt.currency, amount, "skipPadFallback")
		return true
	end
	return (TycoonService.purchasePad(player, nextPad.id, { free = true, skipped = true }))
end

-- The non-main world a world product targets (nil = misconfigured product).
local function productWorld(product: any): WorldDef?
	local def = WorldsConfig.get(product.world)
	return if def ~= nil and def.id ~= MAIN then def else nil
end

--[[
	"WorldCash" (Bones packs): incomeSeconds of the buyer's idle income IN that world, at least the
	floor, paid in that world's currency. Granted even while the world is locked (the prompt is
	refused then; a receipt that still arrives must never take Robux for nothing).
]]
local function grantWorldCash(player: Player, _profile: any, product: any, _receipt: any): boolean
	local def = productWorld(product)
	if def == nil then
		warn(`[TycoonService] WorldCash product {tostring(product.key)} has no valid world`)
		return false
	end
	local amount = TycoonRules.cashPackAmount(
		product.incomeSeconds or 0,
		product.cashFloor or 0,
		TycoonService.incomePerSecond(player, def.id)
	)
	if amount <= 0 then
		return false
	end
	PlayerDataService.grantCurrency(player, def.currency.key, amount, "worldCashPack")
	return true
end

-- BoostService, resolved lazily (it is a Services module booted after the tycoon; no cycle).
local boostService: any = nil
local function boosts(): any
	if boostService == nil then
		local server = ServerScriptService:FindFirstChild("Server")
		local services = if server ~= nil then server:FindFirstChild("Services") else nil
		local module = if services ~= nil then services:FindFirstChild("BoostService") else nil
		if module ~= nil and module:IsA("ModuleScript") then
			local ok, loaded = pcall(require, module)
			boostService = if ok and type(loaded) == "table" then loaded else false
		else
			boostService = false
		end
	end
	return if boostService == false then nil else boostService
end

--[[
	"WorldStarter" (Time Traveler Pack, one-time): the FIXED pet first (the only step that can
	refuse: then nothing changed and the receipt is retried), then the optional boost, the world
	currency (incomeSeconds of that world's income, at least the floor) and the bought flag
	worlds.<w>.starter.bought. A second receipt (bought on another server meanwhile) still pays the
	currency part so Robux are never taken for nothing, without a second pet / boost.
]]
local function grantWorldStarter(player: Player, profile: any, product: any, _receipt: any): boolean
	local def = productWorld(product)
	local state: any = if def ~= nil then worldStateOf(profile, def.id) else nil
	if def == nil or type(state) ~= "table" or type(state.starter) ~= "table" then
		warn(`[TycoonService] WorldStarter product {tostring(product.key)} has no valid world`)
		return false
	end
	local first = state.starter.bought ~= true
	if first and type(product.pet) == "string" then
		local ok = PetGrants.grantFixed(player, product.pet, "worldStarter")
		if not ok then
			return false -- nothing changed: Roblox retries the receipt
		end
	end
	if first and type(product.boostKey) == "string" and type(product.boostSeconds) == "number" then
		local service = boosts()
		if service ~= nil then
			service.grant(player, product.boostKey, product.boostSeconds)
		else
			warn("[TycoonService] WorldStarter: BoostService unavailable; boost skipped")
		end
	end
	local amount = TycoonRules.cashPackAmount(
		product.incomeSeconds or 0,
		product.cashFloor or 0,
		TycoonService.incomePerSecond(player, def.id)
	)
	if amount > 0 then
		PlayerDataService.grantCurrency(player, def.currency.key, amount, "worldStarter")
	end
	state.starter.bought = true
	PlayerDataService.markChanged(player, true, WORLD_FIELDS)
	return true
end

--------------------------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------------------------

function TycoonService.Init()
	-- Knockdown (owner R50) asks us for area income + readiness (it cannot require this module).
	Knockdown.bindTycoon({
		areaIncome = TycoonService.areaIncome,
		isReady = TycoonService.isReady,
	})
	ModifierSources.installPasses(MonetizationService)
	MonetizationService.registerProductHandler("Cash", grantCashPack)
	MonetizationService.registerProductHandler("SkipPad", grantSkipPad)
	MonetizationService.registerProductHandler("WorldCash", grantWorldCash)
	MonetizationService.registerProductHandler("WorldStarter", grantWorldStarter)
	MonetizationService.registerPromptRefusal("SkipPad", function(player: Player, _product: any): string?
		local world = skipWorldOf(player)
		if world == MAIN and not TycoonService.isReady(player) then
			return "Your plot is still loading - try again in a moment!"
		end
		if TycoonService.nextPad(player, world) == nil then
			return "You own every pad!"
		end
		return nil
	end)
	PlotBuilder.setHandlers({
		padTouched = onPadTouched,
		-- ClickDetector on a producer's ClickBox: only the plot's owner, then the same checks as
		-- the ProducerClick remote (idle, not automated, in reach, rate limit).
		producerClicked = function(plotIndex: number, producerId: string, player: Player)
			if PlotService.getPlotIndex(player) == plotIndex then
				onProducerClick(player, producerId)
			end
		end,
	})
	-- R57: every non-main world's 8 empty plot frames exist before any plot is claimed (Init runs
	-- before every Start, so PlotService can set owner signs on them at once).
	for _, def in WorldsConfig.extra() do
		PlotBuilder.createWorldPlots(def.id)
	end
end

function TycoonService.Start()
	PlotService.PlotAssigned:Connect(function(player: Player, plotIndex: number)
		task.spawn(setup, player, plotIndex, false)
	end)
	PlotService.PlotReleased:Connect(function(player: Player)
		teardownAll(player)
	end)
	-- Owner R64: flipping the AutoClicker toggle (Settings) re-evaluates rt.autoClicker on the next
	-- tick in every world of the player (refresh reads profile.settings.autoClicker) — live, no
	-- rejoin — and is counted in analytics (tycoon "autoClicker:<on|off>").
	SettingsService.Changed:Connect(function(player: Player, key: string, value: boolean)
		if key == "autoClicker" then
			TycoonService.markDirty(player, nil)
			TycoonAnalytics.call("tycoon", player, if value then "autoClicker:on" else "autoClicker:off")
		end
	end)
	ModifierSources.Changed:Connect(function(player: Player?)
		-- Every world of the player: global modifiers apply everywhere, and a rebirth changes the
		-- OTHER world's cross-world link (linkCash).
		if player ~= nil then
			TycoonService.markDirty(player, nil)
		else
			for _, byWorld in runtimes do
				for _, rt in byWorld do
					rt.dirty = true
				end
			end
		end
	end)

	local function onPlayer(player: Player)
		ensureLeaderstats(player)
		-- R57: entering a world republishes its anchors (CycleStart writes are gated by presence).
		player:GetAttributeChangedSignal(TycoonService.CurrentWorldAttr):Connect(function()
			local current = currentWorldOf(player)
			for _, rt in runtimes[player] or {} do
				local present = rt.worldId == current
				if present ~= rt.present then
					rt.present = present
					rt.dirty = true
				end
			end
		end)
		local plotIndex = PlotService.getPlotIndex(player)
		if plotIndex ~= nil and runtimeOf(player, MAIN) == nil then
			task.spawn(setup, player, plotIndex, false) -- plot claimed before this service started
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		teardownAll(player)
		clickLimiter:Forget(player)
		upgradeLimiter:Forget(player)
		padLimiter:Forget(player)
		teleportLimiter:Forget(player)
		gemUpgradeLimiter:Forget(player)
	end)

	Remotes.onServerEvent("ProducerClick", onProducerClick)
	Remotes.onServerEvent("ProducerUpgrade", onProducerUpgrade)
	-- Owner R86: the flat-price gem upgrade (+ its live price / switch and admin command).
	GemUpgradeSettings.start()
	Remotes.onServerEvent("ProducerGemUpgrade", onProducerGemUpgrade)
	Remotes.onServerEvent("PadBuy", onPadBuy)
	Remotes.onServerEvent("TeleportArea", function(player: Player, rawArea: unknown)
		if not teleportLimiter:Allow(player) then
			return
		end
		local area = Validate.integer(rawArea, 1, #TycoonConfig.Areas)
		local rt = readyRuntime(player, MAIN)
		if area == nil or rt == nil or not TycoonLogic.areaUnlocked(rt.profile.tycoon, area) then
			return
		end
		-- R57: from another world this is a real trip (warp, lighting, CurrentWorld): WorldService
		-- handles it through PlotService.routeTravel (false while already in Nuke Town, so the
		-- plain teleport below stays today's path).
		if PlotService.routeTravel(player, MAIN, "area", area) then
			return
		end
		if TycoonService.TeleportNeedsPass and not MonetizationService.ownsPass(player, "Teleporter") then
			notice(rt, "Get the Teleporter pass to teleport between areas!")
			return
		end
		if PlotService.teleport(player, PlotBuilder.areaSpawn(rt.plotIndex, area)) then
			TycoonAnalytics.call("tycoon", player, `teleport:{area}`)
		end
	end)

	-- The one payout loop: every TickSeconds pay every ready runtime of every player (every
	-- world); leaderstats and analytics on slower periods. Accumulated on Heartbeat so a slow
	-- frame never skips a tick's payout.
	local accumulator, leaderAt, flushAt = 0, 0, 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator < TycoonService.TickSeconds then
			return
		end
		accumulator = 0
		local t = now()
		local wall = os.time()
		local started = os.clock()
		for player, byWorld in runtimes do
			local profile = PlayerDataService.getProfile(player)
			for _, rt in byWorld do
				if rt.ready and profile == rt.profile then
					tickRuntime(rt, t, wall)
				end
			end
		end
		local clock = os.clock()
		if clock - leaderAt >= TycoonService.LeaderstatsSeconds then
			leaderAt = clock
			for _, byWorld in runtimes do
				local rt = byWorld[MAIN]
				if rt ~= nil and rt.ready then
					updateLeaderstats(rt)
				end
			end
		end
		if clock - flushAt >= TycoonAnalytics.FlushSeconds then
			flushAt = clock
			TycoonAnalytics.flush()
		end
		TycoonAnalytics.call("systemTime", "Producers", os.clock() - started)
	end)
end

return TycoonService
