--!strict
--[[
	TycoonConfig — every tunable of the SellNukes tycoon economy plus the ten area definitions.

	Purpose
		The single source of truth for producers, pads, milestones, the cycle floor, level cap,
		offline-earnings limits, pass multipliers and the pacing targets the economy simulator
		enforces. TycoonLogic holds the formulas; this module holds the numbers.

	Worlds framework (World 2 plan §3.1): this is Nuke Town (world "main"). The lookup tables are
	built by `Shared/Tycoon/EconomyIndex.build` — the same builder every other world uses — and
	re-exported here unchanged (tests/economy-index.luau proves bit-identical parity with the
	tables that shipped before the framework). `TycoonConfig.Index` is the whole EconomyIndex;
	`TycoonConfig.Tunables` are the tunables every world shares.

	What it builds at load (read-only lookups, so hot paths never scan lists):
		Areas            {AreaConfig}                 areas 1..10 in order
		PadOrder         {PadConfig}                  every pad of the game in its one linear chain
		PadsById         {[padId]: PadConfig}
		PadIndex         {[padId]: number}            position in PadOrder (1-based)
		Producers        {ProducerConfig}             one per area, in area order
		ProducersById    {[producerId]: ProducerConfig}
		PadsByTarget     {[producerId]: {PadConfig}}  Build / Multiplier / Speed / Manager pads per producer
		ManagerPadOf     {[producerId]: padId}        the pad that automates each producer
		ProducerBuiltBy  {[padId]: producerId}        the pad that builds (level 1) each producer
		AreaPads         {[area]: {PadConfig}}
		FeaturePadOf     {[FeatureKey]: padId}        which pad unlocks StandRename / AATower / ...
		FinalePadId      string                       the pad whose feature is "Rebirth"

	Load-time validation (EconomyIndex; errors loudly in Studio and in the lune tests, never
	silently): unique pad / producer / build-key ids, the `requires` chain is exactly the linear
	order, every producer has exactly one builder pad and one Manager pad in its own area, numeric
	fields are finite and positive, kinds carry the fields they need, id formats a<N>_ / p<N>_ /
	A<N>_ (an Unlock pad builds the next area's A<N+1>_EntryArch).

	Friendly prices: every pad cost and producer baseCost is rounded at load to 2 significant
	digits (`TycoonConfig.friendlyPrice`), so billboards read "$73M", not "$72,913,402".

	Connections
		* Area data: `Shared/Config/TycoonAreas/Area01..Area10`.
		* Builder: `Shared/Tycoon/EconomyIndex`; registry of every world: `Shared/Config/Worlds/WorldsConfig`.
		* Formulas: `Shared/Tycoon/TycoonLogic`, `Shared/Tycoon/Modifiers`.
		* Rebirth tunables: `Shared/Config/RebirthConfig`.
		* Consumers: B5 TycoonService / PlotBuilder (server), B6 billboards / pads / teleport (client),
		  `tests/economy-sim.luau` (pacing), `tests/tycoon-logic.luau` (unit tests).

	Usage
		local TycoonConfig = require(ReplicatedStorage.Shared.Config.TycoonConfig)
		local pad = TycoonConfig.PadsById["a1_tool_wall"]
		print(pad.cost, pad.blurb)
]]

local EconomyIndex = require(script.Parent.Parent.Tycoon.EconomyIndex)
local TycoonTypes = require(script.Parent.Parent.Tycoon.TycoonTypes)

type AreaConfig = TycoonTypes.AreaConfig
type PadConfig = TycoonTypes.PadConfig
type ProducerConfig = TycoonTypes.ProducerConfig

local TycoonConfig = {}

-- Producer milestones: every MilestoneEvery levels the producer gets x MilestoneFactor, alternating
-- cash (odd milestones: 25, 75, 125 ...) and speed (even milestones: 50, 100, 150 ...).
TycoonConfig.MilestoneEvery = 25
TycoonConfig.MilestoneFactor = 2

-- Shortest allowed cycle in seconds. Speed that would push a cycle below this converts into cash
-- (cash x floor / raw cycle), so income per second is never lost and a cycle never gets longer.
TycoonConfig.CycleFloor = 0.1

-- Highest producer level. Bounds every geometric cost / milestone power far inside double range.
TycoonConfig.MaxLevel = 1000

-- Largest bulk upgrade count the server accepts per request ("max" is clamped to this too).
TycoonConfig.MaxBulkLevels = 1000

--[[
	Owner R86 gem upgrade: the billboard's gem button buys exactly ONE producer level for a FLAT gem
	price ("it stays at the same price for everything"): every producer, every level, every world.
	The owner floated ~1,000 gems; the lead proposed 25. Decision 75 (T-tutorial, 2026-10-31),
	measured with the real pacing simulator (levels bought with gems the moment an area's producer
	is built; docs/economy.md "Gem upgrade"):
		levels       10   15   25   30   40   60   120
		area 1 min  6.9  6.4   -   3.9  2.9  1.4  0.6    (target 8.0)
		area 9 min   -  74.2 57.6 51.0 39.7 15.3  2.8    (target 80)
	At 25 a few thousand gems skipped Garage Lab outright (3,000 gems = 120 levels: 0.6 min) and
	could erase a whole 80-minute late area: the lead's "visibly breaks pacing" bar. At 75, 3,000
	gems buy 40 levels (Garage Lab 8 -> 2.9 min, Space Port 80 -> 40 min: halved, never skipped), a
	1,000-gem pack buys 13 (about -15 %), and free play (~70-100 gems a day) earns about one gem
	level a day. Admin-adjustable per server (Server/Tycoon/GemUpgradeSettings, Economy tab).
]]
TycoonConfig.GemUpgradePrice = 75
TycoonConfig.GemUpgrade = table.freeze({
	MinPrice = 1, -- admin override range (gems)
	MaxPrice = 10000,
	-- Replicated live settings (ReplicatedStorage attributes written by the server only).
	PriceAttribute = "GemUpgradePrice",
	EnabledAttribute = "GemUpgradeEnabled",
	-- Kid-friendly confirm (Tycoon/GemConfirmLogic): the first press arms ("SURE?"), a second press
	-- within ConfirmSeconds buys; presses within RepeatSeconds of the last gem buy go straight
	-- through (no confirm every time).
	ConfirmSeconds = 3,
	RepeatSeconds = 6,
	Reason = "GemUpgrade", -- PlayerDataService spend reason (economy analytics source id)
})

-- Offline earnings (spec §7): pays Rate x idle $/s x min(elapsed, Cap). Rebirth shop
-- (RebirthConfig.Shop.offlineHours / offlineRate) and the Offline Max pass raise both.
TycoonConfig.Offline = {
	BaseCapSeconds = 3 * 3600, -- 3 h
	BaseRate = 0.5, -- 50 %
	MaxCapSeconds = 24 * 3600, -- hard ceiling, also what the Offline Max pass grants
	MaxRate = 1, -- 100 %
	PassCapSeconds = 24 * 3600,
	PassRate = 1,
	MinSeconds = 60, -- absences shorter than this pay nothing (no popup for a quick rejoin)
}
table.freeze(TycoonConfig.Offline)

-- Global income modifier tunables (Shared/Tycoon/Modifiers). Monetization config should reference
-- these values rather than duplicating them.
TycoonConfig.Modifiers = {
	CashPassMultiplier = 2, -- "2x Cash" game pass
	VipMultiplier = 1.5, -- VIP pass: +50 % cash
	MaxPetCash = 1000, -- pet bonus fraction cap (+100,000 %) — corrupted-data guard
	MaxMultiplier = 1e6, -- cap for any single multiplicative modifier field
}
table.freeze(TycoonConfig.Modifiers)

-- Pacing targets (spec §2 table) — minutes a greedy no-Robux player spends in each area on the
-- first run. tests/economy-sim.luau fails if any area drifts more than Tolerance (+/-20 %).
TycoonConfig.Pacing = {
	TargetMinutes = { 8, 15, 25, 35, 45, 50, 60, 70, 80, 90 },
	Tolerance = 0.2,
}

--[[
	The tunables every world's economy shares, as ONE frozen table (the same Offline / Modifiers
	table refs as above). Passed to `EconomyIndex.build` by Nuke Town and by every other world
	(`Worlds/<Name>/<Name>World`), so a Dino producer obeys the same cycle floor, level cap and
	milestone rhythm as a Nuke Town one.
]]
TycoonConfig.Tunables = table.freeze({
	MilestoneEvery = TycoonConfig.MilestoneEvery,
	MilestoneFactor = TycoonConfig.MilestoneFactor,
	CycleFloor = TycoonConfig.CycleFloor,
	MaxLevel = TycoonConfig.MaxLevel,
	MaxBulkLevels = TycoonConfig.MaxBulkLevels,
	Offline = TycoonConfig.Offline,
	Modifiers = TycoonConfig.Modifiers,
}) :: TycoonTypes.EconomyTunables

--[[
	Rounds a price to 2 significant digits (rounding half up), keeping 0 at 0.
	Re-export of `EconomyIndex.friendlyPrice` (the implementation moved there with the worlds
	framework; every existing caller keeps using this name).
	@param x number — raw price (>= 0)
	@return number — the friendly price
	Example: TycoonConfig.friendlyPrice(72913402) --> 73000000; friendlyPrice(4) --> 4
]]
TycoonConfig.friendlyPrice = EconomyIndex.friendlyPrice

local AREA_MODULES = script.Parent.TycoonAreas

--[[
	Nuke Town's economy (world "main", legacy ids a<N>_ / p<N>_ / A<N>_), built, validated and
	frozen by EconomyIndex. Every lookup field below is a reference into this index, so
	`TycoonConfig.PadsById[id]` and `TycoonConfig.Index.PadsById[id]` are the same record.
]]
local INDEX = EconomyIndex.build({
	worldId = "main",
	idPrefix = "",
	areas = {
		require(AREA_MODULES.Area01),
		require(AREA_MODULES.Area02),
		require(AREA_MODULES.Area03),
		require(AREA_MODULES.Area04),
		require(AREA_MODULES.Area05),
		require(AREA_MODULES.Area06),
		require(AREA_MODULES.Area07),
		require(AREA_MODULES.Area08),
		require(AREA_MODULES.Area09),
		require(AREA_MODULES.Area10),
	} :: { AreaConfig },
	pacing = TycoonConfig.Pacing,
	-- Nuke Town owns every feature: the Stand rename, the attack mode pads and Rebirth.
	allowedFeatures = { StandRename = true, AATower = true, AttackConsole = true, Rebirth = true },
	tunables = TycoonConfig.Tunables,
})

-- The whole index (TycoonLogic binds the main Logic to it; WorldsConfig's MainWorld.economy).
TycoonConfig.Index = INDEX
TycoonConfig.WorldId = INDEX.WorldId

TycoonConfig.Areas = INDEX.Areas :: { AreaConfig }
TycoonConfig.PadOrder = INDEX.PadOrder :: { PadConfig }
TycoonConfig.PadsById = INDEX.PadsById :: { [string]: PadConfig }
TycoonConfig.PadIndex = INDEX.PadIndex :: { [string]: number }
TycoonConfig.Producers = INDEX.Producers :: { ProducerConfig }
TycoonConfig.ProducersById = INDEX.ProducersById :: { [string]: ProducerConfig }
TycoonConfig.PadsByTarget = INDEX.PadsByTarget :: { [string]: { PadConfig } }
TycoonConfig.ManagerPadOf = INDEX.ManagerPadOf :: { [string]: string }
TycoonConfig.ProducerBuiltBy = INDEX.ProducerBuiltBy :: { [string]: string }
TycoonConfig.AreaPads = INDEX.AreaPads :: { [number]: { PadConfig } }
TycoonConfig.FeaturePadOf = INDEX.FeaturePadOf :: { [string]: string }
TycoonConfig.FinalePadId = INDEX.FinalePadId

return TycoonConfig
