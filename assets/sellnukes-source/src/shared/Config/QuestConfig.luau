--!strict
--[[
	QuestConfig — every Quests number and every READ-ONLY Quests rule (owner R78, spec
	docs/superpowers/specs/2026-10-31-r78-retention-pack-design.md §1). Shared: the server
	(Server/Quests/QuestLogic + Server/Services/QuestService) mutates with these rules and the client
	(Client/Quests/* + UI/Screens/Quests) previews with the SAME rules, so both always agree.

	Three kinds of quests:
		GOALS     a fixed chain of 12 starter goals (QuestConfig.Goals). Goals are STATE checks on the
		          profile where possible (pads owned, producer levels, managers, area, hatched eggs,
		          a daily claim ever made), so veterans see them complete at once and just claim; the
		          one pure counter goal ("Spin the Lucky Wheel") counts from the moment the chain
		          started (`starter.base`). `starter.step` = goals completed IN ORDER, sticky (a
		          rebirth that resets the tycoon never un-completes a goal); any completed goal may be
		          claimed once (`starter.claimed[i]`).
		DAILY     three missions per UTC day from QuestConfig.Missions, seeded on the server, with a
		          target picked by progress tier (tier 1 = Nuke Town area <= 3, tier 2 = area <= 6,
		          tier 3 = beyond or any rebirth). 15 gems + 100 XP each; all three finished unlock the
		          Daily Chest (25 gems + 1 bonus spin + 150 XP); one free reroll per day.
		TROPHIES  lifetime tiered counters (QuestConfig.Trophies). Counter trophies read
		          `life[stat]` (counted from 0.6.0) and, where the profile already kept a lifetime
		          counter (stats.clicks / padsBought / hatched / playSeconds), the larger of the two,
		          so a veteran's history counts (design decision, docs/quests.md). State trophies read
		          the profile (Pet Index, worlds unlocked, rebirths in every world).

	State (profile.quests; newState / reconcileState / snapshot below, ProfileLogic delegates):
		starter  { step = 0..12, base = {[stat] = n}, claimed = { boolean x 12 } }
		         (`claimed` is a DENSE boolean array — DataStore / remote safe, read like {[i]=true})
		daily    { day = UTC day (-1 = never), picks = { {stat, target, progress, claimed} x <= 3 },
		           chest = claimed?, rerolled = used today's free reroll? }
		life     { [stat] = lifetime count since 0.6.0 } (LifeStats only)
		trophies { [trophyId] = tiers claimed (0..#tiers) }

	Facts: QuestConfig.facts(profile) reads ONE profile (the server's, or the client's snapshot — the
	same field names) into the numbers every rule needs; it never errors on a malformed snapshot.

	Connects to: Server/Quests/QuestLogic (mutations), Server/Services/QuestService (remotes, events,
	rewards), Server/Economy/ProfileLogic (newState / reconcileState / snapshot), Client/Quests/*
	(badge, objective chip), UI/Screens/Quests (the screen), Shared/Config/{RetentionConfig (Reward
	shape), TycoonConfig (Nuke Town pads / producers), PetConfig (Pet Index), Worlds/WorldGeometry},
	tests/quest-logic.luau.

	Example:
		local facts = QuestConfig.facts(profile)
		local count = QuestConfig.claimableCount(profile.quests, facts, QuestConfig.utcDay(now))
		for _, view in QuestConfig.starterViews(profile.quests, facts) do
			print(view.goal.index, view.goal.text, view.state, view.value, view.goal.target)
		end
]]

-- Owner R89: the "flavor" daily mission only exists while Surprise Batches ship on.
local FlavorConfig = require(script.Parent.FlavorConfig)
local PetConfig = require(script.Parent.PetConfig)
local RetentionConfig = require(script.Parent.RetentionConfig)
local TycoonConfig = require(script.Parent.TycoonConfig)

export type Reward = RetentionConfig.Reward

-- Every stat a server success path may fire (mirrors Server/Progression/ProgressEvents.STATS;
-- tests/quest-logic.luau checks the two lists are identical).
export type Stat =
	"click"
	| "pad"
	| "upgrade"
	| "manager"
	| "area"
	| "hatch"
	| "crate"
	| "spin"
	| "daily"
	| "gift"
	| "rebirth"
	| "lucky"
	| "turkey"
	| "playMinute"
	| "world"
	| "flavor" -- owner R89: special-flavour batches (Server/Tycoon/FlavorService, rate-capped)
	| "lever" -- owner R90: a Mega Lever pull (Server/Kinetic/MegaLever; one per cooldown)
	| "tipjar" -- owner R90: a Tip Jar payout (Server/Kinetic/TipJar)

-- How a starter goal measures progress (QuestConfig.goalProgress).
export type GoalKind =
	"pads" -- Nuke Town pads owned
	| "level" -- one producer's level (`producer`)
	| "managers" -- Nuke Town Manager pads owned
	| "counter" -- `stat` counted since the chain started (life - base)
	| "area" -- Nuke Town area reached
	| "maxLevel" -- the best Nuke Town producer level
	| "hatched" -- eggs hatched (lifetime)
	| "daily" -- a daily reward claimed (ever)

-- What the objective chip's world arrow points at for a goal (Client/Quests/QuestObjective).
export type Guide = "pad" | "manager" | "producer" | "bestProducer"

export type Goal = {
	index: number, -- 1..12 (analytics "quest:goalDone:<index>")
	text: string, -- GOALS row + objective chip text
	icon: string, -- IconAssets key
	kind: GoalKind,
	target: number,
	stat: Stat?, -- "counter": the counted stat
	producer: string?, -- "level": the producer id
	guide: Guide?, -- the chip's world arrow (nil = no world target)
	screen: string?, -- the screen the row's GO button / the chip opens (nil = none)
	reward: Reward,
	xp: number, -- Nuke Pass XP on claim
}

export type Mission = {
	stat: Stat,
	icon: string,
	one: string, -- text when the target is 1
	many: string, -- text with "%d" for the target
	targets: { number }, -- by progress tier (1..3)
	event: boolean?, -- only while the Harvest Feast is live
	screen: string?, -- the DAILY row's GO button opens this screen
}

export type TrophySource = "counter" | "index" | "worlds" | "rebirths"
export type Trophy = {
	id: string,
	name: string,
	icon: string,
	source: TrophySource,
	stat: Stat?, -- "counter": life[stat]
	backfill: ("clicks" | "padsBought" | "hatched" | "playMinutes")?, -- a profile lifetime stat it may not drop below
	tiers: { number }, -- strictly increasing targets
	unit: string, -- "clicks", "pads", ... (row text)
}

export type Pick = { stat: string, target: number, progress: number, claimed: boolean }
export type State = {
	starter: { step: number, base: { [string]: number }, claimed: { boolean } },
	daily: { day: number, picks: { Pick }, chest: boolean, rerolled: boolean },
	life: { [string]: number },
	trophies: { [string]: number },
}

export type Facts = {
	pads: number, -- Nuke Town pads owned this run
	managers: number, -- Nuke Town Manager pads owned this run
	area: number, -- Nuke Town area reached this run (1..10)
	levels: { [string]: number }, -- Nuke Town producer levels
	maxLevel: number, -- best Nuke Town producer level
	bestProducer: string?, -- that producer's id
	rebirths: number, -- Nuke Town rebirths
	rebirthsAll: number, -- rebirths in every world
	worlds: number, -- worlds unlocked (Nuke Town counts)
	hatched: number, -- profile.stats.hatched
	dailyEver: boolean, -- a daily reward was ever claimed
	indexCount: number, -- Pet Index entries (known pets)
	clicks: number, -- profile.stats.clicks
	padsBought: number, -- profile.stats.padsBought
	playMinutes: number, -- profile.stats.playSeconds // 60
	tutorialDone: boolean, -- the Nuke Town tutorial finished (the objective chip is ours)
}

export type GoalState = "claimed" | "ready" | "active" | "locked"
export type GoalView = { goal: Goal, value: number, state: GoalState }
export type MissionState = "claimed" | "ready" | "active"
export type MissionView = {
	slot: number,
	stat: string,
	mission: Mission?,
	text: string,
	icon: string,
	target: number,
	progress: number,
	state: MissionState,
}
export type ChestState = "claimed" | "ready" | "locked"
export type TrophyState = "ready" | "active" | "maxed"
export type TrophyView = {
	trophy: Trophy,
	value: number,
	claimed: number, -- tiers claimed
	nextTarget: number?, -- the next tier's target (nil when every tier is claimed)
	state: TrophyState,
}

local QuestConfig = {}

local SECONDS_PER_DAY = 86_400

-- Stored value of profile.tycoon.tutorialStep once the Nuke Town tutorial is finished
-- (Server/Tycoon/TutorialLogic.DoneStep; tests/quest-logic.luau checks they match).
QuestConfig.TutorialDoneStep = 8

-- Missions per UTC day, reroll allowance, rewards (spec §1.3).
QuestConfig.MissionsPerDay = 3
QuestConfig.FreeRerolls = 1
QuestConfig.MissionReward = table.freeze({ gems = 15 }) :: Reward
QuestConfig.MissionXp = 100
QuestConfig.ChestReward = table.freeze({ gems = 25, spins = 1 }) :: Reward
QuestConfig.ChestXp = 150
-- Trophy tier rewards by tier number (spec §1.4) + XP per tier.
QuestConfig.TrophyGems = table.freeze({ 10, 25, 50, 100, 200 }) :: { number }
QuestConfig.TrophyXp = 75

-- Server cadence (QuestService): one loop every LoopSeconds checks each player's play minute
-- (PlayMinuteSeconds apart, so `playMinute` fires once per online minute, never per second) and
-- the UTC day rollover. Progress-only changes push the `quests` field at most every PushSeconds
-- (a completion / claim pushes at once) so clicking never floods the profile sync.
QuestConfig.LoopSeconds = 5
QuestConfig.PlayMinuteSeconds = 60
QuestConfig.PushSeconds = 2

--[[ Owner R83: while the AutoClicker pass clicks for a player, manual clicks are no-ops (the cycle
     is always running), so the cycles the pass starts count as "click" progress instead — at most
     this many per second (a quick human clicker), so the pass helps with click missions and the
     Clicker trophies without maxing them in seconds. Only the world the player is in counts
     (TycoonService), like a real click. ]]
QuestConfig.AutoClickCreditPerSecond = 4

-- Remote rate limits (token buckets: burst, refill per second).
QuestConfig.Limits = table.freeze({
	-- Claim burst 12: a veteran can claim the whole 12-goal chain in one go.
	Claim = table.freeze({ Burst = 12, PerSecond = 2 }),
	Reroll = table.freeze({ Burst = 2, PerSecond = 0.2 }),
})

-- Reconcile caps (a corrupt / hostile save can never grow the record).
QuestConfig.MaxCounter = 1e12 -- life counters / base values
QuestConfig.MaxTarget = 1e6 -- a mission target
QuestConfig.MaxKeyLength = 24 -- life / trophy / base keys
QuestConfig.MaxMapKeys = 32 -- life / trophies / base entries kept

-- Every stat id (ProgressEvents.STATS).
QuestConfig.Stats = table.freeze({
	"click",
	"pad",
	"upgrade",
	"manager",
	"area",
	"hatch",
	"crate",
	"spin",
	"daily",
	"gift",
	"rebirth",
	"lucky",
	"turkey",
	"playMinute",
	"world",
	"flavor", -- owner R89 Surprise Batches
	"lever", -- owner R90 Mega Lever
	"tipjar", -- owner R90 Tip Jar
}) :: { Stat }
local STAT_SET: { [string]: boolean } = {}
for _, stat in QuestConfig.Stats do
	STAT_SET[stat] = true
end

--------------------------------------------------------------------------------------------------
-- Starter goals (spec §1.2)
--------------------------------------------------------------------------------------------------

-- Nuke Town's first producer (the Workbench) and every Manager pad, read from TycoonConfig so a
-- rename there never silently breaks a goal.
local WORKBENCH = TycoonConfig.Areas[1].producer.id
local MANAGER_PADS: { [string]: boolean } = {}
for _, pad in TycoonConfig.PadOrder do
	if pad.kind == "Manager" then
		MANAGER_PADS[pad.id] = true
	end
end

local GOALS: { Goal } = {
	{
		index = 1,
		text = "Own 5 pads in Nuke Town",
		icon = "Reactor",
		kind = "pads",
		target = 5,
		guide = "pad",
		reward = { gems = 10, cashSeconds = 60, cashFloor = 200 },
		xp = 50,
	},
	{
		index = 2,
		text = "Get your Workbench to level 10",
		icon = "Upgrade",
		kind = "level",
		target = 10,
		producer = WORKBENCH,
		guide = "producer",
		reward = { spins = 1 },
		xp = 50,
	},
	{
		index = 3,
		text = "Hire your first manager",
		icon = "Manager",
		kind = "managers",
		target = 1,
		guide = "manager",
		reward = { boost = { key = "cash2x", seconds = 300 } },
		xp = 50,
	},
	{
		index = 4,
		text = "Own 12 pads",
		icon = "Reactor",
		kind = "pads",
		target = 12,
		guide = "pad",
		reward = { gems = 15 },
		xp = 50,
	},
	{
		index = 5,
		text = "Spin the Lucky Wheel",
		icon = "LuckyWheel",
		kind = "counter",
		target = 1,
		stat = "spin",
		screen = "LuckyWheel",
		reward = { gems = 10 },
		xp = 50,
	},
	{
		index = 6,
		text = "Reach Area 2",
		icon = "Area02",
		kind = "area",
		target = 2,
		guide = "pad",
		reward = { gems = 25, boost = { key = "speed2x", seconds = 300 } },
		xp = 50,
	},
	{
		index = 7,
		text = "Get any machine to level 25",
		icon = "Upgrade",
		kind = "maxLevel",
		target = 25,
		guide = "bestProducer",
		reward = { spins = 1 },
		xp = 50,
	},
	{
		index = 8,
		text = "Hatch an egg",
		icon = "Egg",
		kind = "hatched",
		target = 1,
		screen = "Pets",
		reward = { gems = 20 },
		xp = 50,
	},
	{
		index = 9,
		text = "Claim a daily reward",
		icon = "Daily",
		kind = "daily",
		target = 1,
		screen = "DailyRewards",
		reward = { gems = 10 },
		xp = 50,
	},
	{
		index = 10,
		text = "Reach Area 3",
		icon = "Area03",
		kind = "area",
		target = 3,
		guide = "pad",
		reward = { gems = 30, boost = { key = "cash2x", seconds = 600 } },
		xp = 50,
	},
	{
		index = 11,
		text = "Hire 3 managers",
		icon = "Manager",
		kind = "managers",
		target = 3,
		guide = "manager",
		reward = { gems = 20, spins = 1 },
		xp = 50,
	},
	{
		index = 12,
		text = "Reach Area 4",
		icon = "Area04",
		kind = "area",
		target = 4,
		guide = "pad",
		reward = { gems = 50, spins = 2 },
		xp = 100,
	},
}
-- Run-state goals a Nuke Town rebirth proves were reached (the tycoon resets on rebirth, the
-- finale needs every area, every manager and high levels).
local IMPLIED_BY_REBIRTH: { [GoalKind]: boolean } = {
	pads = true,
	level = true,
	managers = true,
	area = true,
	maxLevel = true,
}
for _, goal in GOALS do
	table.freeze(goal.reward)
	if goal.reward.boost ~= nil then
		table.freeze(goal.reward.boost)
	end
	table.freeze(goal)
end
QuestConfig.Goals = table.freeze(GOALS)
QuestConfig.GoalCount = #GOALS

--------------------------------------------------------------------------------------------------
-- Daily missions (spec §1.3)
--------------------------------------------------------------------------------------------------

local MISSIONS: { Mission } = {
	{
		stat = "click",
		icon = "Nuke",
		one = "Click a machine once",
		many = "Click your machines %d times",
		targets = { 120, 250, 400 },
	},
	{ stat = "pad", icon = "Reactor", one = "Buy a pad", many = "Buy %d pads", targets = { 6, 10, 15 } },
	{
		stat = "upgrade",
		icon = "Upgrade",
		one = "Buy an upgrade level",
		many = "Buy %d upgrade levels",
		targets = { 25, 60, 120 },
	},
	{
		stat = "hatch",
		icon = "Egg",
		one = "Hatch an egg",
		many = "Hatch %d eggs",
		targets = { 2, 4, 8 },
		screen = "Pets",
	},
	{
		stat = "spin",
		icon = "LuckyWheel",
		one = "Spin the Lucky Wheel",
		many = "Spin the Lucky Wheel %d times",
		targets = { 2, 3, 3 },
		screen = "LuckyWheel",
	},
	{
		stat = "gift",
		icon = "Time",
		one = "Open a time gift",
		many = "Open %d time gifts",
		targets = { 2, 3, 4 },
		screen = "TimeRewards",
	},
	{
		stat = "playMinute",
		icon = "Clock",
		one = "Play for a minute",
		many = "Play for %d minutes",
		targets = { 15, 20, 30 },
	},
	{
		stat = "lucky",
		icon = "LuckyButton",
		one = "Claim a Lucky Button",
		many = "Claim %d Lucky Buttons",
		targets = { 1, 2, 3 },
	},
	-- Owner R89 Surprise Batches: special-flavour batches in the world you are in (FlavorService
	-- credits them at most FlavorConfig.QuestCredit.PerMinute, so fast producers can't skip it).
	{
		stat = "flavor",
		icon = "Nuke",
		one = FlavorConfig.Text.MissionOne, -- owner R112: "Make a Lucky Nuke" (never "batch")
		many = FlavorConfig.Text.MissionMany,
		targets = { 15, 30, 50 },
	},
	-- Owner R90 hands-on props (Server/Kinetic): the Mega Lever (one pull per KineticConfig.Lever
	-- .CooldownSeconds, so 3 pulls = 20+ minutes of play) and the Tip Jar (a payout needs a little
	-- fill first). Both appear at KineticConfig.UnlockArea (~8 min into a first run).
	{
		stat = "lever",
		icon = "Reactor",
		one = "Pull the Mega Lever",
		many = "Pull the Mega Lever %d times",
		targets = { 1, 2, 3 },
	},
	{
		stat = "tipjar",
		icon = "Cash",
		one = "Empty your Tip Jar",
		many = "Empty your Tip Jar %d times",
		targets = { 1, 2, 3 },
	},
	{
		stat = "turkey",
		icon = "Turkey",
		one = "Catch a Golden Turkey",
		many = "Catch %d Golden Turkeys",
		targets = { 4, 8, 12 },
		event = true,
	},
}
-- Owner R89 ship switch: with Surprise Batches off (FlavorConfig.DefaultEnabled) no player is ever
-- handed the "flavor" mission (it could never progress).
if not FlavorConfig.DefaultEnabled then
	for index = #MISSIONS, 1, -1 do
		if MISSIONS[index].stat == "flavor" then
			table.remove(MISSIONS, index)
		end
	end
end
local MISSION_BY_STAT: { [string]: Mission } = {}
for _, mission in MISSIONS do
	MISSION_BY_STAT[mission.stat] = mission
	table.freeze(mission.targets)
	table.freeze(mission)
end
QuestConfig.Missions = table.freeze(MISSIONS)
QuestConfig.MissionByStat = table.freeze(MISSION_BY_STAT)
-- Mission stat ids in pool order (analytics choice lists, admin enums).
local MISSION_STATS: { string } = {}
for _, mission in MISSIONS do
	table.insert(MISSION_STATS, mission.stat)
end
QuestConfig.MissionStats = table.freeze(MISSION_STATS)

--------------------------------------------------------------------------------------------------
-- Trophies (spec §1.4)
--------------------------------------------------------------------------------------------------

-- A pet that is NOT obtainable from a normal source (e.g. the Nuke Pass's Golden Nukey). Read
-- defensively: the pets builder may mark exclusives with a PetDef `exclusive` flag, a
-- PetConfig.isExclusive(id) rule or a "pass" / "exclusive" source.
local function isExclusivePet(def: PetConfig.PetDef): boolean
	local raw: any = def
	if raw.exclusive == true then
		return true
	end
	local rule = (PetConfig :: any).isExclusive
	if type(rule) == "function" then
		local ok, result = pcall(rule, def.id)
		if ok and result == true then
			return true
		end
	end
	local source: any = def.source
	return source == "pass" or source == "exclusive"
end

-- "Collect them all" = every non-exclusive pet (exclusives count toward it only when owned, the
-- same rule as the Pet Index bar, spec §5).
local COLLECTOR_ALL = 0
for _, id in PetConfig.Order do
	local def = PetConfig.get(id)
	if def ~= nil and not isExclusivePet(def) then
		COLLECTOR_ALL += 1
	end
end
QuestConfig.CollectorAll = COLLECTOR_ALL

local TROPHIES: { Trophy } = {
	{
		id = "clicker",
		name = "Clicker",
		icon = "Nuke",
		source = "counter",
		stat = "click",
		backfill = "clicks",
		tiers = { 100, 1_000, 10_000, 50_000, 250_000 },
		unit = "clicks",
	},
	{
		id = "builder",
		name = "Builder",
		icon = "Reactor",
		source = "counter",
		stat = "pad",
		backfill = "padsBought",
		tiers = { 25, 100, 300, 750, 2_000 },
		unit = "pads bought",
	},
	{
		id = "upgrader",
		name = "Upgrader",
		icon = "Upgrade",
		source = "counter",
		stat = "upgrade",
		tiers = { 100, 1_000, 5_000, 20_000, 100_000 },
		unit = "levels bought",
	},
	{
		id = "hatcher",
		name = "Hatcher",
		icon = "Egg",
		source = "counter",
		stat = "hatch",
		backfill = "hatched",
		tiers = { 5, 25, 100, 500, 2_000 },
		unit = "eggs hatched",
	},
	{
		id = "collector",
		name = "Collector",
		icon = "Pets",
		source = "index",
		-- 5 / 15 / 30 / 50 / all (kept above 50 so the tiers always climb).
		tiers = { 5, 15, 30, 50, math.max(51, COLLECTOR_ALL) },
		unit = "pets in the Index",
	},
	{
		id = "explorer",
		name = "Explorer",
		icon = "TimeMachine",
		source = "worlds",
		tiers = { 2, 3 },
		unit = "worlds unlocked",
	},
	{
		id = "reborn",
		name = "Reborn",
		icon = "Rebirth",
		source = "rebirths",
		tiers = { 1, 3, 10, 25, 50 },
		unit = "rebirths",
	},
	{
		id = "loyal",
		name = "Loyal",
		icon = "Daily",
		source = "counter",
		stat = "daily",
		tiers = { 3, 7, 14, 30, 60 },
		unit = "daily rewards",
	},
	{
		id = "traveller",
		name = "Time Traveller",
		icon = "Clock",
		source = "counter",
		stat = "playMinute",
		backfill = "playMinutes",
		tiers = { 60, 300, 1_200, 3_000, 6_000 },
		unit = "minutes played",
	},
}
local TROPHY_BY_ID: { [string]: Trophy } = {}
local TROPHY_IDS: { string } = {}
for _, trophy in TROPHIES do
	TROPHY_BY_ID[trophy.id] = trophy
	table.insert(TROPHY_IDS, trophy.id)
	table.freeze(trophy.tiers)
	table.freeze(trophy)
end
QuestConfig.Trophies = table.freeze(TROPHIES)
QuestConfig.TrophyById = table.freeze(TROPHY_BY_ID)
QuestConfig.TrophyIds = table.freeze(TROPHY_IDS)
-- Roman numerals for tier names ("Clicker III").
QuestConfig.TierNames = table.freeze({ "I", "II", "III", "IV", "V" }) :: { string }

--------------------------------------------------------------------------------------------------
-- Lifetime counters
--------------------------------------------------------------------------------------------------

-- Stats counted into profile.quests.life: every counter trophy's stat + every counter goal's stat
-- (nothing else is stored, keeping the record and its sync small).
local LIFE_SET: { [string]: boolean } = {}
for _, trophy in TROPHIES do
	if trophy.stat ~= nil then
		LIFE_SET[trophy.stat] = true
	end
end
for _, goal in GOALS do
	if goal.stat ~= nil then
		LIFE_SET[goal.stat] = true
	end
end
local LIFE_STATS: { string } = {}
for _, stat in QuestConfig.Stats do
	if LIFE_SET[stat] then
		table.insert(LIFE_STATS, stat)
	end
end
QuestConfig.LifeStats = table.freeze(LIFE_STATS)
-- Stats a counter GOAL measures (starter.base records their life value when the chain starts).
local BASE_STATS: { string } = {}
for _, goal in GOALS do
	if goal.stat ~= nil and table.find(BASE_STATS, goal.stat) == nil then
		table.insert(BASE_STATS, goal.stat)
	end
end
QuestConfig.BaseStats = table.freeze(BASE_STATS)

--------------------------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------------------------

-- A finite number, else nil (NaN / inf / non-number).
local function finite(value: unknown): number?
	if type(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return value
	end
	return nil
end

-- A whole number in [lo, hi] (floored, clamped); `default` for anything unreadable.
local function whole(value: unknown, lo: number, hi: number, default: number): number
	local n = finite(value)
	if n == nil then
		return default
	end
	return math.clamp(math.floor(n), lo, hi)
end

-- A well-formed map key ("click", "clicker", a newer server's id): identifier-shaped, short.
local function validKey(key: unknown): boolean
	return type(key) == "string"
		and #key >= 1
		and #key <= QuestConfig.MaxKeyLength
		and string.find(key, "^[%a][%w_]*$") ~= nil
end

-- Counts the keys of a table (0 for a non-table).
local function countKeys(map: unknown, accept: ((key: any) -> boolean)?): number
	if type(map) ~= "table" then
		return 0
	end
	local count = 0
	for key, value in map :: { [any]: any } do
		if value ~= nil and value ~= false and (accept == nil or accept(key)) then
			count += 1
		end
	end
	return count
end

--[[ True when `value` is a known stat id. ]]
function QuestConfig.isStat(value: unknown): boolean
	return type(value) == "string" and STAT_SET[value] == true
end

--[[ True when `stat` is counted into profile.quests.life. ]]
function QuestConfig.isLifeStat(stat: unknown): boolean
	return type(stat) == "string" and LIFE_SET[stat] == true
end

--[[ The UTC day number of a unix time (the same clock as Daily Rewards). ]]
function QuestConfig.utcDay(unixTime: number): number
	return RetentionConfig.utcDay(unixTime)
end

--[[ Seconds until the next UTC midnight (1..86400): the DAILY tab's reset countdown. ]]
function QuestConfig.secondsToReset(unixTime: number): number
	return SECONDS_PER_DAY - (math.floor(unixTime) % SECONDS_PER_DAY)
end

--[[
	The text of a daily mission with its target.
	Example: QuestConfig.missionText("pad", 6) --> "Buy 6 pads"; missionText("lucky", 1) --> "Claim a Lucky Button"
]]
function QuestConfig.missionText(stat: string, target: number): string
	local mission = MISSION_BY_STAT[stat]
	if mission == nil then
		return "Mission"
	end
	if target == 1 then
		return mission.one
	end
	return string.format(mission.many, target)
end

--[[ The display name of a trophy tier ("Clicker III"). ]]
function QuestConfig.tierName(trophy: Trophy, tier: number): string
	return `{trophy.name} {QuestConfig.TierNames[tier] or tostring(tier)}`
end

--[[ The reward of trophy tier `tier` (1-based). ]]
function QuestConfig.trophyReward(tier: number): Reward
	return { gems = QuestConfig.TrophyGems[math.clamp(tier, 1, #QuestConfig.TrophyGems)] }
end

--------------------------------------------------------------------------------------------------
-- State shape (profile.quests): newState / reconcileState / snapshot
--------------------------------------------------------------------------------------------------

--[[ A fresh quests record (new profile, or a save from before 0.6.0). ]]
function QuestConfig.newState(): State
	return {
		starter = { step = 0, base = {}, claimed = table.create(#GOALS, false) },
		daily = { day = -1, picks = {}, chest = false, rerolled = false },
		life = {},
		trophies = {},
	}
end

-- A bounded { [key] = whole number } map: well-formed keys only, values clamped to [0, max], at
-- most MaxMapKeys entries (keys sorted so the cut is deterministic). Zeros are dropped (a missing
-- counter reads as 0) unless `keepZero`: starter.base keeps them, because a recorded base of 0 is
-- data ("the chain started when this counter was 0"), not an empty counter (review fix, R78).
local function reconcileCounts(raw: unknown, max: number, keepZero: boolean?): { [string]: number }
	local out: { [string]: number } = {}
	if type(raw) ~= "table" then
		return out
	end
	local keys: { string } = {}
	for key, value in raw :: { [any]: any } do
		local number = finite(value)
		if validKey(key) and number ~= nil and (number > 0 or (keepZero == true and number >= 0)) then
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	for i = 1, math.min(#keys, QuestConfig.MaxMapKeys) do
		local key = keys[i]
		out[key] = whole((raw :: any)[key], 0, max, 0)
	end
	return out
end

--[[
	Daily-mission stats that no longer exist (owner R128 "bro honestly just remove the orders system
	entirely" removed the Order Window and its "order" mission). A save that still holds one gets it
	swapped on load (reconcileState) for a live mission: never a crash, the free reroll is NOT used,
	the other picks keep their progress, and a finished / claimed retired mission stays finished /
	claimed (no lost Daily Chest, no second reward). Life counters (`life.order`) are kept like any
	unknown counter; no trophy ever read them.
]]
QuestConfig.RetiredStats = table.freeze({ order = true }) :: { [string]: boolean }

--[[
	The live mission that replaces a retired pick: the first non-event mission (list order) whose
	stat is not `taken` (today's other picks + earlier replacements); nil when none is free. Its
	easiest target (targets[1]) is used — the reconcile does not know the player's tier, and an easy
	mission is the kind way to make up for the swap.
]]
local function retiredReplacement(taken: { [string]: boolean }): Mission?
	for _, mission in MISSIONS do
		if mission.event ~= true and not taken[mission.stat] then
			return mission
		end
	end
	return nil
end

--[[
	Repairs any stored value into a valid State (profile load; ProfileLogic.reconcile calls it).
	Missing → fresh; junk types → defaults; numbers floored + clamped; mission picks keep only
	known mission stats (a RETIRED stat is swapped for a live mission, see RetiredStats), no
	duplicates, at most MissionsPerDay; claimed flags padded to the goal
	count; a newer server's unknown trophy / life keys are kept (well-formed, capped) so a rollback
	never loses them.
	Example: QuestConfig.reconcileState(nil).starter.step --> 0
]]
function QuestConfig.reconcileState(raw: unknown): State
	local state = QuestConfig.newState()
	if type(raw) ~= "table" then
		return state
	end
	local data = raw :: { [string]: any }

	local starter: any = if type(data.starter) == "table" then data.starter else {}
	state.starter.step = whole(starter.step, 0, #GOALS, 0)
	state.starter.base = reconcileCounts(starter.base, QuestConfig.MaxCounter, true)
	if type(starter.claimed) == "table" then
		for i = 1, #GOALS do
			-- A goal can only have been claimed once it was completed (i <= step).
			state.starter.claimed[i] = starter.claimed[i] == true and i <= state.starter.step
		end
	end

	local daily: any = if type(data.daily) == "table" then data.daily else {}
	state.daily.day = whole(daily.day, -1, 1e9, -1)
	state.daily.chest = daily.chest == true
	state.daily.rerolled = daily.rerolled == true
	if type(daily.picks) == "table" then
		-- Every stat the stored picks name: a retired pick's replacement must not repeat one of
		-- them (not even a later slot's).
		local taken: { [string]: boolean } = {}
		for i = 1, QuestConfig.MissionsPerDay do
			local pick = (daily.picks :: any)[i]
			if type(pick) == "table" and type(pick.stat) == "string" then
				taken[pick.stat] = true
			end
		end
		local seen: { [string]: boolean } = {}
		for i = 1, QuestConfig.MissionsPerDay do
			local pick = (daily.picks :: any)[i]
			if type(pick) ~= "table" then
				break
			end
			local stat = pick.stat
			-- Owner R128: a retired mission is silently swapped for a live one (see RetiredStats).
			if type(stat) == "string" and QuestConfig.RetiredStats[stat] == true then
				local replacement = retiredReplacement(taken)
				if replacement == nil then
					break
				end
				taken[replacement.stat] = true
				seen[replacement.stat] = true
				local oldTarget = whole(pick.target, 1, QuestConfig.MaxTarget, 1)
				local finished = pick.claimed == true or whole(pick.progress, 0, oldTarget, 0) >= oldTarget
				local target = replacement.targets[1]
				table.insert(state.daily.picks, {
					stat = replacement.stat,
					target = target,
					progress = if finished then target else 0,
					claimed = pick.claimed == true,
				})
				continue
			end
			if type(stat) ~= "string" or MISSION_BY_STAT[stat] == nil or seen[stat] then
				break -- picks are a dense array: stop at the first bad entry
			end
			seen[stat] = true
			local target = whole(pick.target, 1, QuestConfig.MaxTarget, 1)
			table.insert(state.daily.picks, {
				stat = stat,
				target = target,
				progress = whole(pick.progress, 0, target, 0),
				claimed = pick.claimed == true,
			})
		end
	end
	-- The chest needs every mission finished (a broken save can not keep a lone chest flag).
	if state.daily.chest then
		local all = #state.daily.picks == QuestConfig.MissionsPerDay
		for _, pick in state.daily.picks do
			all = all and pick.progress >= pick.target
		end
		state.daily.chest = all
	end

	state.life = reconcileCounts(data.life, QuestConfig.MaxCounter)
	local trophies = reconcileCounts(data.trophies, 100)
	for id, tier in trophies do
		local trophy = TROPHY_BY_ID[id]
		trophies[id] = if trophy ~= nil then math.min(tier, #trophy.tiers) else tier
	end
	state.trophies = trophies
	return state
end

--[[
	The owner's `quests` snapshot field (ProfileLogic BUILDERS.quests): a plain copy — every value
	is already remote-safe (dense arrays, string-keyed maps, numbers, booleans).
]]
function QuestConfig.snapshot(state: State): { [string]: any }
	local picks = {}
	for i, pick in state.daily.picks do
		picks[i] = { stat = pick.stat, target = pick.target, progress = pick.progress, claimed = pick.claimed }
	end
	return {
		starter = {
			step = state.starter.step,
			base = table.clone(state.starter.base),
			claimed = table.clone(state.starter.claimed),
		},
		daily = { day = state.daily.day, picks = picks, chest = state.daily.chest, rerolled = state.daily.rerolled },
		life = table.clone(state.life),
		trophies = table.clone(state.trophies),
	}
end

--[[
	Reads a quests record from an untrusted client snapshot (or nil): the same repair as the
	server's reconcile, so a malformed push can never error a screen (the record is a few hundred
	bytes, so the copy is cheap; callers read it once per `quests` push).
	Example: local state = QuestConfig.read(ClientState.profile and ClientState.profile.quests)
]]
function QuestConfig.read(raw: unknown): State
	return QuestConfig.reconcileState(raw)
end

--------------------------------------------------------------------------------------------------
-- Facts (one profile → the numbers every rule reads)
--------------------------------------------------------------------------------------------------

--[[
	Reads the facts of a profile (server profile or client snapshot; never errors).
	@param profile any — profile.tycoon / stats / rebirths / worlds / daily / pets
	@return Facts
	Example: QuestConfig.facts(profile).pads --> 7
]]
function QuestConfig.facts(profile: any): Facts
	local data: any = if type(profile) == "table" then profile else {}
	local tycoon: any = if type(data.tycoon) == "table" then data.tycoon else {}
	local stats: any = if type(data.stats) == "table" then data.stats else {}
	local pads = 0
	local managers = 0
	if type(tycoon.pads) == "table" then
		for padId, owned in tycoon.pads :: { [any]: any } do
			if owned == true and type(padId) == "string" and TycoonConfig.PadsById[padId] ~= nil then
				pads += 1
				if MANAGER_PADS[padId] then
					managers += 1
				end
			end
		end
	end
	local levels: { [string]: number } = {}
	local maxLevel = 0
	local bestProducer: string? = nil
	if type(tycoon.producers) == "table" then
		-- Fixed producer order so ties pick the same producer every time.
		for _, producer in TycoonConfig.Producers do
			local level = whole((tycoon.producers :: any)[producer.id], 0, 1e6, 0)
			if level > 0 then
				levels[producer.id] = level
				if level > maxLevel then
					maxLevel = level
					bestProducer = producer.id
				end
			end
		end
	end
	local rebirths = whole(data.rebirths, 0, 1e9, 0)
	local rebirthsAll = rebirths
	local worlds = 1 -- Nuke Town is always unlocked
	if type(data.worlds) == "table" then
		for worldId, world in data.worlds :: { [any]: any } do
			if type(worldId) == "string" and worldId ~= "main" and type(world) == "table" then
				rebirthsAll += whole(world.rebirths, 0, 1e9, 0)
				if world.unlocked == true then
					worlds += 1
				end
			end
		end
	end
	local daily: any = if type(data.daily) == "table" then data.daily else {}
	local pets: any = if type(data.pets) == "table" then data.pets else {}
	local area = whole(tycoon.area, 1, 1e3, 1)
	return {
		pads = pads,
		managers = managers,
		area = area,
		levels = levels,
		maxLevel = maxLevel,
		bestProducer = bestProducer,
		rebirths = rebirths,
		rebirthsAll = rebirthsAll,
		worlds = worlds,
		hatched = whole(stats.hatched, 0, QuestConfig.MaxCounter, 0),
		dailyEver = whole(daily.lastDay, -1, 1e9, -1) >= 0 or whole(daily.streak, 0, 1e9, 0) > 0,
		indexCount = countKeys(pets.index, function(id: any): boolean
			return PetConfig.get(id) ~= nil
		end),
		clicks = whole(stats.clicks, 0, QuestConfig.MaxCounter, 0),
		padsBought = whole(stats.padsBought, 0, QuestConfig.MaxCounter, 0),
		playMinutes = whole(stats.playSeconds, 0, QuestConfig.MaxCounter * 60, 0) // 60,
		tutorialDone = whole(tycoon.tutorialStep, 0, 1e3, 0) >= QuestConfig.TutorialDoneStep
			or area >= 2
			or rebirths > 0,
	}
end

--[[
	Progress tier for daily mission targets (spec §1.3): 1 = Nuke Town area <= 3, 2 = area <= 6,
	3 = beyond or any rebirth in any world.
]]
function QuestConfig.tierOf(facts: Facts): number
	if facts.rebirthsAll > 0 or facts.area > 6 then
		return 3
	elseif facts.area > 3 then
		return 2
	end
	return 1
end

--------------------------------------------------------------------------------------------------
-- Status rules (read-only; server + client)
--------------------------------------------------------------------------------------------------

--[[
	A starter goal's progress value, clamped to [0, target].
	@param goal  QuestConfig.Goals[i]
	@param facts QuestConfig.facts(profile)
	@param state profile.quests (life / base for counter goals)
]]
function QuestConfig.goalProgress(goal: Goal, facts: Facts, state: State): number
	if IMPLIED_BY_REBIRTH[goal.kind] and facts.rebirths > 0 then
		return goal.target
	end
	local value = 0
	local kind = goal.kind
	if kind == "pads" then
		value = facts.pads
	elseif kind == "level" then
		value = if goal.producer ~= nil then facts.levels[goal.producer] or 0 else 0
	elseif kind == "managers" then
		value = facts.managers
	elseif kind == "area" then
		value = facts.area
	elseif kind == "maxLevel" then
		value = facts.maxLevel
	elseif kind == "hatched" then
		value = math.max(facts.hatched, state.life.hatch or 0)
	elseif kind == "daily" then
		value = if facts.dailyEver then goal.target else state.life.daily or 0
	elseif kind == "counter" then
		local stat = goal.stat
		if stat ~= nil then
			value = (state.life[stat] or 0) - (state.starter.base[stat] or 0)
		end
	end
	return math.clamp(value, 0, goal.target)
end

--[[
	Every starter goal with its state: "claimed" / "ready" (completed, not claimed) for i <= step,
	"active" for the next goal (its live progress), "locked" after it.
]]
function QuestConfig.starterViews(state: State, facts: Facts): { GoalView }
	local views: { GoalView } = {}
	local step = state.starter.step
	for i, goal in GOALS do
		local view: GoalView
		if i <= step then
			view = {
				goal = goal,
				value = goal.target,
				state = if state.starter.claimed[i] == true then "claimed" else "ready",
			}
		elseif i == step + 1 then
			view = { goal = goal, value = QuestConfig.goalProgress(goal, facts, state), state = "active" }
		else
			view = { goal = goal, value = 0, state = "locked" }
		end
		views[i] = view
	end
	return views
end

--[[
	Today's missions as views. When the stored day is not `today` (the server re-seeds at UTC
	midnight within a few seconds) the list is empty and `stale` is true.
	@return views, the Daily Chest state, stale
]]
function QuestConfig.dailyViews(state: State, today: number): ({ MissionView }, ChestState, boolean)
	local views: { MissionView } = {}
	local daily = state.daily
	if daily.day ~= today then
		return views, "locked", true
	end
	local allDone = #daily.picks == QuestConfig.MissionsPerDay
	for slot, pick in daily.picks do
		local done = pick.progress >= pick.target
		allDone = allDone and done
		local mission: Mission? = MISSION_BY_STAT[pick.stat]
		local missionState: MissionState = if pick.claimed then "claimed" elseif done then "ready" else "active"
		local view: MissionView = {
			slot = slot,
			stat = pick.stat,
			mission = mission,
			text = QuestConfig.missionText(pick.stat, pick.target),
			icon = if mission ~= nil then mission.icon else "Star",
			target = pick.target,
			progress = math.min(pick.progress, pick.target),
			state = missionState,
		}
		table.insert(views, view)
	end
	local chest: ChestState = if daily.chest then "claimed" elseif allDone then "ready" else "locked"
	return views, chest, false
end

--[[ A trophy's current value (counter with backfill, or the profile state it reads). ]]
function QuestConfig.trophyValue(trophy: Trophy, facts: Facts, state: State): number
	local source = trophy.source
	if source == "index" then
		return facts.indexCount
	elseif source == "worlds" then
		return facts.worlds
	elseif source == "rebirths" then
		return facts.rebirthsAll
	end
	local value = if trophy.stat ~= nil then state.life[trophy.stat] or 0 else 0
	local backfill = trophy.backfill
	if backfill ~= nil then
		value = math.max(value, (facts :: any)[backfill] or 0)
	end
	return value
end

--[[ Every trophy with its value, claimed tiers, next target and state. ]]
function QuestConfig.trophyViews(state: State, facts: Facts): { TrophyView }
	local views: { TrophyView } = {}
	for _, trophy in TROPHIES do
		local claimed = math.clamp(state.trophies[trophy.id] or 0, 0, #trophy.tiers)
		local nextTarget = trophy.tiers[claimed + 1]
		local value = QuestConfig.trophyValue(trophy, facts, state)
		local trophyState: TrophyState = if nextTarget == nil
			then "maxed"
			elseif value >= nextTarget then "ready"
			else "active"
		table.insert(
			views,
			{ trophy = trophy, value = value, claimed = claimed, nextTarget = nextTarget, state = trophyState }
		)
	end
	return views
end

--[[
	How many CLAIM buttons are lit (the HUD Quests badge = this + the Nuke Pass's claimables):
	ready goals + ready missions + a ready chest + trophies with a reached next tier (one each).
]]
function QuestConfig.claimableCount(state: State, facts: Facts, today: number): number
	local count = 0
	for i = 1, math.min(state.starter.step, #GOALS) do
		if state.starter.claimed[i] ~= true then
			count += 1
		end
	end
	local missions, chest = QuestConfig.dailyViews(state, today)
	for _, view in missions do
		if view.state == "ready" then
			count += 1
		end
	end
	if chest == "ready" then
		count += 1
	end
	for _, view in QuestConfig.trophyViews(state, facts) do
		if view.state == "ready" then
			count += 1
		end
	end
	return count
end

--[[
	The objective chip's starter goal: the first goal that is not completed yet (index = step + 1),
	or nil once all 12 are completed.
]]
function QuestConfig.currentGoal(state: State): Goal?
	return GOALS[state.starter.step + 1]
end

--------------------------------------------------------------------------------------------------
-- Analytics keys (retention family, AnalyticsConfig.Metrics "quest:*")
--------------------------------------------------------------------------------------------------

QuestConfig.Keys = table.freeze({
	goalDone = function(index: number): string
		return `quest:goalDone:{index}`
	end,
	goalClaim = function(index: number): string
		return `quest:goalClaim:{index}`
	end,
	dailyPick = function(stat: string): string
		return `quest:dailyPick:{stat}`
	end,
	dailyDone = function(stat: string): string
		return `quest:dailyDone:{stat}`
	end,
	dailyClaim = function(stat: string): string
		return `quest:dailyClaim:{stat}`
	end,
	chest = function(): string
		return "quest:chest"
	end,
	reroll = function(stat: string): string
		return `quest:reroll:{stat}`
	end,
	trophy = function(id: string, tier: number): string
		return `quest:trophy:{id}:{tier}`
	end,
})

return table.freeze(QuestConfig)
