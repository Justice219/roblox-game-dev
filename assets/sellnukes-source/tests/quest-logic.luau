--!strict
--[[
	Quests regressions (owner R78, spec docs/superpowers/specs/2026-10-31-r78-retention-pack-design.md
	§1). Run:
		lune run tests/quest-logic
	Proves on the shipped modules (Shared/Config/QuestConfig, Server/Quests/QuestLogic,
	Server/Economy/ProfileLogic, Server/Progression/ProgressEvents, Server/Analytics/KeySpec):
	  1. Config vs spec: 12 goals (text, targets, rewards, XP), 9 missions with tier targets, the
	     event-only turkey, 9 trophies with strictly rising tiers, valid rewards / boosts / icons,
	     QuestConfig.Stats == ProgressEvents' stats, TutorialDoneStep == TutorialLogic.DoneStep.
	  2. State shape: newState, reconcileState on garbage / NaN / huge / duplicates / a lone chest
	     flag / claims past the step, newer servers' keys kept but bounded; ProfileLogic default,
	     reconcile, snapshot (`quests` field) and toSave (DataStore-safe dense arrays).
	  3. Daily seeding: deterministic per (user, day), three distinct stats, turkey only during the
	     event, every stat reachable, tier targets, the UTC rollover, a clock running backwards.
	  4. Progress: life counters, missions capped at the target, "just finished" reported once,
	     other days / unknown stats / NaN / non-positive amounts ignored.
	  5. Starter chain: state checks from real Nuke Town pads / producers, counter goal from the
	     chain start, veterans complete everything at once, sticky after a rebirth reset, forceStep.
	  6. Claims: idempotent (a second claim refused), locked / stale / unknown codes, the chest needs
	     all three, trophies claim tier by tier with backfill from profile lifetime stats.
	  7. Rerolls: once a day, never a finished / claimed mission, never a stat already shown,
	     deterministic, target by tier.
	  8. Hostile remote arguments: readClaim / readSlot never throw and never pass junk.
	  9. Views + badge: starterViews / dailyViews / trophyViews / claimableCount agree with claims.
	 10. Analytics: every key QuestConfig.Keys builds is accepted by the real KeySpec.
	 11. Open rule (Client/Quests/QuestOpenRules): a chip tap opens Quests only when the chip shows a
	     quest objective, no window is open (no stacking / click-through over NukePass etc.), the
	     join flow is not guiding the first minute and the tutorial is done; unknown = refused.
]]

local Loader = require("./fixtures/RobloxLoader")
local loader = Loader.new()

local QuestConfig = loader.load("src/shared/Config/QuestConfig")
local FlavorConfig = loader.load("src/shared/Config/FlavorConfig") -- R89 ship switch (flavor mission)
local QuestLogic = loader.load("src/server/Quests/QuestLogic")
local ProfileLogic = loader.load("src/server/Economy/ProfileLogic")
local ProgressEvents = loader.load("src/server/Progression/ProgressEvents")
local TutorialLogic = loader.load("src/server/Tycoon/TutorialLogic")
local RetentionConfig = loader.load("src/shared/Config/RetentionConfig")
local BoostConfig = loader.load("src/shared/Config/BoostConfig")
local IconAssets = loader.load("src/shared/Config/IconAssets")
local TycoonConfig = loader.load("src/shared/Config/TycoonConfig")
local PetConfig = loader.load("src/shared/Config/PetConfig")
local KeySpec = loader.load("src/server/Analytics/KeySpec")
local QuestOpenRules = loader.load("src/client/Quests/QuestOpenRules")
local fs = require("@lune/fs")
local Vector3 = require("@lune/roblox").Vector3

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

-- Deep equality of plain tables (used for determinism / snapshot checks).
local function deepEqual(a: any, b: any): boolean
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	for key, value in a do
		if not deepEqual(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

local DAY = 20_757 -- 2026-10-31 UTC

-- A profile-like table for QuestConfig.facts (only the fields facts reads).
local function profileWith(options: { [string]: any }?): { [string]: any }
	local o = options or {}
	return {
		tycoon = {
			pads = o.pads or {},
			producers = o.producers or {},
			area = o.area or 1,
			tutorialStep = o.tutorialStep or 0,
		},
		stats = {
			clicks = o.clicks or 0,
			padsBought = o.padsBought or 0,
			hatched = o.hatched or 0,
			playSeconds = o.playSeconds or 0,
		},
		rebirths = o.rebirths or 0,
		worlds = o.worlds or {},
		daily = o.daily or { streak = 0, lastDay = -1 },
		pets = { index = o.index or {} },
	}
end

-- The first `count` Nuke Town pads in buy order, as a pad set.
local function firstPads(count: number): { [string]: boolean }
	local set = {}
	for i = 1, count do
		set[TycoonConfig.PadOrder[i].id] = true
	end
	return set
end

-- 1. Config vs spec -----------------------------------------------------------------------------------
local SPEC_GOALS = {
	{ target = 5, xp = 50, gems = 10 },
	{ target = 10, xp = 50, spins = 1 },
	{ target = 1, xp = 50, boost = "cash2x" },
	{ target = 12, xp = 50, gems = 15 },
	{ target = 1, xp = 50, gems = 10 },
	{ target = 2, xp = 50, gems = 25, boost = "speed2x" },
	{ target = 25, xp = 50, spins = 1 },
	{ target = 1, xp = 50, gems = 20 },
	{ target = 1, xp = 50, gems = 10 },
	{ target = 3, xp = 50, gems = 30, boost = "cash2x" },
	{ target = 3, xp = 50, gems = 20, spins = 1 },
	{ target = 4, xp = 100, gems = 50, spins = 2 },
}
check(QuestConfig.GoalCount == 12 and #QuestConfig.Goals == 12, "12 starter goals")
local screensDir = "src/client/UI/Screens/"
for i, goal in QuestConfig.Goals do
	local spec = SPEC_GOALS[i]
	check(goal.index == i, `goal {i}: index`)
	check(goal.target == spec.target and goal.xp == spec.xp, `goal {i}: target / xp from the spec`)
	check((goal.reward.gems or nil) == spec.gems, `goal {i}: gems`)
	check((goal.reward.spins or nil) == spec.spins, `goal {i}: spins`)
	check((if goal.reward.boost ~= nil then goal.reward.boost.key else nil) == spec.boost, `goal {i}: boost`)
	check(RetentionConfig.isRewardValid(goal.reward), `goal {i}: valid reward`)
	if goal.reward.boost ~= nil then
		check(BoostConfig.get(goal.reward.boost.key) ~= nil, `goal {i}: boost key exists`)
		check(goal.reward.boost.seconds == 300 or goal.reward.boost.seconds == 600, `goal {i}: 5 / 10 min boost`)
	end
	check(IconAssets.resolve(goal.icon) ~= nil, `goal {i}: icon {goal.icon} exists`)
	if goal.kind == "counter" then
		check(goal.stat ~= nil and QuestConfig.isLifeStat(goal.stat), `goal {i}: counter stat is counted`)
	end
	if goal.kind == "level" then
		check(TycoonConfig.ProducersById[goal.producer] ~= nil, `goal {i}: producer exists`)
	end
	if goal.screen ~= nil then
		check(
			fs.isDir(screensDir .. goal.screen) or fs.isFile(screensDir .. goal.screen .. ".luau"),
			`goal {i}: screen {goal.screen} exists`
		)
	end
end
check(QuestConfig.Goals[1].reward.cashSeconds == 60, "goal 1 pays 60 s of income")
check(QuestConfig.Goals[2].producer == TycoonConfig.Areas[1].producer.id, "goal 2 = the Workbench")

local SPEC_TARGETS = {
	click = { 120, 250, 400 },
	pad = { 6, 10, 15 },
	upgrade = { 25, 60, 120 },
	hatch = { 2, 4, 8 },
	spin = { 2, 3, 3 },
	gift = { 2, 3, 4 },
	playMinute = { 15, 20, 30 },
	lucky = { 1, 2, 3 },
	turkey = { 4, 8, 12 },
	flavor = { 15, 30, 50 }, -- owner R89 Surprise Batches
	lever = { 1, 2, 3 }, -- owner R90 Mega Lever
	tipjar = { 1, 2, 3 }, -- owner R90 Tip Jar
}
check(
	#QuestConfig.Missions == 11 + (if FlavorConfig.DefaultEnabled then 1 else 0),
	"nine mission stats + R90 lever / tipjar (+ R89 flavor while it ships on)"
)
-- Owner R128 removed the Order Window: no "order" mission or stat is left.
check(QuestConfig.MissionByStat.order == nil, "R128: no order mission")
check(not QuestConfig.isStat("order"), "R128: order is not a stat")
check(not ProgressEvents.isStat("order"), "R128: ProgressEvents drops order")
check(QuestConfig.RetiredStats.order == true, "R128: order is a retired mission stat")
for _, mission in QuestConfig.Missions do
	check(deepEqual(mission.targets, SPEC_TARGETS[mission.stat]), `mission {mission.stat}: spec targets`)
	check((mission.event == true) == (mission.stat == "turkey"), `mission {mission.stat}: event flag`)
	check(QuestConfig.isStat(mission.stat), `mission {mission.stat}: a ProgressEvents stat`)
	check(IconAssets.resolve(mission.icon) ~= nil, `mission {mission.stat}: icon exists`)
	check(QuestConfig.missionText(mission.stat, 1) == mission.one, `mission {mission.stat}: singular text`)
	check(
		string.find(QuestConfig.missionText(mission.stat, 7), "7", 1, true) ~= nil,
		`mission {mission.stat}: plural text`
	)
end
check(QuestConfig.MissionReward.gems == 15 and QuestConfig.MissionXp == 100, "missions: 15 gems + 100 XP")
check(QuestConfig.ChestReward.gems == 25 and QuestConfig.ChestReward.spins == 1, "chest: 25 gems + 1 spin")
check(QuestConfig.ChestXp == 150 and QuestConfig.TrophyXp == 75, "chest 150 XP, trophy tier 75 XP")
check(deepEqual(QuestConfig.TrophyGems, { 10, 25, 50, 100, 200 }), "trophy tier gems")

local SPEC_TROPHIES = {
	clicker = { 100, 1_000, 10_000, 50_000, 250_000 },
	builder = { 25, 100, 300, 750, 2_000 },
	upgrader = { 100, 1_000, 5_000, 20_000, 100_000 },
	hatcher = { 5, 25, 100, 500, 2_000 },
	explorer = { 2, 3 },
	reborn = { 1, 3, 10, 25, 50 },
	loyal = { 3, 7, 14, 30, 60 },
	traveller = { 60, 300, 1_200, 3_000, 6_000 },
}
check(#QuestConfig.Trophies == 9, "nine trophies")
for _, trophy in QuestConfig.Trophies do
	local spec = SPEC_TROPHIES[trophy.id]
	if spec ~= nil then
		check(deepEqual(trophy.tiers, spec), `trophy {trophy.id}: spec tiers`)
	end
	for t = 2, #trophy.tiers do
		check(trophy.tiers[t] > trophy.tiers[t - 1], `trophy {trophy.id}: tiers rise`)
	end
	check(#trophy.tiers <= #QuestConfig.TrophyGems, `trophy {trophy.id}: a reward per tier`)
	check(IconAssets.resolve(trophy.icon) ~= nil, `trophy {trophy.id}: icon exists`)
	if trophy.source == "counter" then
		check(trophy.stat ~= nil and QuestConfig.isLifeStat(trophy.stat), `trophy {trophy.id}: counted stat`)
	end
end
local collector = QuestConfig.TrophyById.collector
check(deepEqual({ table.unpack(collector.tiers, 1, 4) }, { 5, 15, 30, 50 }), "collector 5 / 15 / 30 / 50")
check(
	QuestConfig.CollectorAll > 50 and QuestConfig.CollectorAll <= PetConfig.Count,
	"collector 'all' = non-exclusive pets"
)
check(collector.tiers[5] == QuestConfig.CollectorAll, "collector last tier = all")

local eventStats = {}
for _, stat in QuestConfig.Stats do
	eventStats[stat] = true
	check(ProgressEvents.isStat(stat), `{stat} is a ProgressEvents stat`)
end
for _, stat in
	{
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
		"flavor", -- owner R89
		"lever", -- owner R90 Mega Lever
		"tipjar", -- owner R90 Tip Jar
	}
do
	check(eventStats[stat] == true, `QuestConfig.Stats lists {stat}`)
end
check(#QuestConfig.Stats == 18, "exactly the 15 spec stats + R89 flavor + R90 lever / tipjar")
check(QuestConfig.TutorialDoneStep == TutorialLogic.DoneStep, "TutorialDoneStep matches the server tutorial")
check(deepEqual(QuestConfig.BaseStats, { "spin" }), "the only counter goal counts wheel spins")
for _, stat in { "click", "pad", "upgrade", "hatch", "daily", "playMinute", "spin" } do
	check(QuestConfig.isLifeStat(stat), `life counts {stat}`)
end
check(not QuestConfig.isLifeStat("crate") and not QuestConfig.isLifeStat("world"), "life keeps only used stats")

-- 2. State shape ----------------------------------------------------------------------------------------
local fresh = QuestConfig.newState()
check(fresh.starter.step == 0 and #fresh.starter.claimed == 12, "fresh: step 0, 12 claim slots")
check(fresh.daily.day == -1 and #fresh.daily.picks == 0, "fresh: no missions yet")
check(deepEqual(QuestConfig.reconcileState(nil), fresh), "nil → fresh")
check(deepEqual(QuestConfig.reconcileState("junk"), fresh), "string → fresh")
check(deepEqual(QuestConfig.reconcileState({ starter = 5, daily = true }), fresh), "junk fields → fresh")

local repaired = QuestConfig.reconcileState({
	starter = { step = 0 / 0, base = { spin = -5, ["bad key"] = 3, ok = math.huge }, claimed = { true, true } },
	daily = {
		day = 1e99,
		chest = true,
		rerolled = "yes",
		picks = {
			{ stat = "pad", target = 1e12, progress = 1e13, claimed = true },
			{ stat = "pad", target = 5, progress = 1, claimed = false }, -- duplicate stat: dropped
			{ stat = "click", target = 5, progress = 1 },
		},
	},
	life = { click = 12.7, pad = -3, ["%%"] = 4, zero = 0 },
	trophies = { clicker = 99, futureTrophy = 2, [""] = 1 },
})
check(repaired.starter.step == 0, "NaN step → 0")
check(repaired.starter.claimed[1] == false, "claims past the step are dropped")
check(repaired.starter.base.spin == nil and repaired.starter.base["bad key"] == nil, "bad base entries dropped")
check(repaired.daily.day == 1e9, "huge day clamped")
check(
	#repaired.daily.picks == 1 and repaired.daily.picks[1].target == QuestConfig.MaxTarget,
	"picks stop at a duplicate; target clamped"
)
check(repaired.daily.picks[1].progress == repaired.daily.picks[1].target, "progress clamped to the target")
check(repaired.daily.chest == false, "a lone chest flag without three finished missions is dropped")
check(repaired.daily.rerolled == false, "non-boolean rerolled → false")
check(
	repaired.life.click == 12 and repaired.life.pad == nil and repaired.life.zero == nil,
	"life floored, junk dropped"
)
check(repaired.trophies.clicker == 5, "known trophy tier clamped to its tier count")
check(repaired.trophies.futureTrophy == 2, "a newer server's trophy key is kept")
local manyKeys = {}
for i = 1, 100 do
	manyKeys[`k{i}`] = i
end
check(next(QuestConfig.reconcileState({ life = manyKeys }).life) ~= nil, "a big map is kept partly")
local kept = 0
for _ in QuestConfig.reconcileState({ life = manyKeys }).life do
	kept += 1
end
check(kept == QuestConfig.MaxMapKeys, "maps are bounded")

-- Owner R128: a save holding today's retired "order" mission is repaired on load — the pick is
-- swapped for a live mission no other slot shows, the free reroll is untouched, the other picks
-- keep their progress, and a finished / claimed order pick stays finished / claimed.
do
	local function stored(orderPick: { [string]: any }, rerolled: boolean): { [string]: any }
		return {
			daily = {
				day = 900,
				chest = false,
				rerolled = rerolled,
				picks = {
					{ stat = "click", target = 120, progress = 40, claimed = false },
					orderPick,
					{ stat = "pad", target = 6, progress = 6, claimed = true },
				},
			},
			life = { order = 7, click = 40 },
		}
	end
	local fresh0 =
		QuestConfig.reconcileState(stored({ stat = "order", target = 5, progress = 2, claimed = false }, false))
	local picks = fresh0.daily.picks
	check(#picks == 3, "R128: all three missions survive the swap")
	check(picks[1].stat == "click" and picks[1].progress == 40, "R128: slot 1 untouched")
	check(picks[3].stat == "pad" and picks[3].claimed, "R128: slot 3 untouched (a later slot)")
	local swapped = picks[2]
	check(
		swapped.stat ~= "order" and QuestConfig.MissionByStat[swapped.stat] ~= nil,
		"R128: swapped for a live mission"
	)
	check(swapped.stat ~= "click" and swapped.stat ~= "pad", "R128: never a stat another slot shows")
	check(QuestConfig.MissionByStat[swapped.stat].event ~= true, "R128: never an event-only mission")
	check(swapped.target == QuestConfig.MissionByStat[swapped.stat].targets[1], "R128: the easiest target")
	check(swapped.progress == 0 and not swapped.claimed, "R128: an unfinished order pick starts fresh")
	check(not fresh0.daily.rerolled, "R128: the free reroll is not used up")
	check(fresh0.life.order == 7, "R128: old life counters are kept like any unknown counter")
	local views, chest, stale = QuestConfig.dailyViews(fresh0, 900)
	check(#views == 3 and not stale and chest == "locked", "R128: the repaired day renders")
	-- A rerolled day keeps its rerolled flag (the swap is not a reroll).
	check(
		QuestConfig.reconcileState(stored({ stat = "order", target = 5, progress = 0 }, true)).daily.rerolled,
		"R128: rerolled kept"
	)
	-- A finished (unclaimed) order pick: the replacement is finished and claimable.
	local done =
		QuestConfig.reconcileState(stored({ stat = "order", target = 3, progress = 3, claimed = false }, false))
	check(
		done.daily.picks[2].progress == done.daily.picks[2].target and not done.daily.picks[2].claimed,
		"R128: finished stays claimable"
	)
	-- A claimed order pick: the replacement is claimed (no second reward), the chest can still open.
	local claimed = QuestConfig.reconcileState({
		daily = {
			day = 900,
			chest = false,
			rerolled = false,
			picks = {
				{ stat = "click", target = 120, progress = 120, claimed = true },
				{ stat = "order", target = 3, progress = 3, claimed = true },
				{ stat = "pad", target = 6, progress = 6, claimed = true },
			},
		},
	})
	check(
		claimed.daily.picks[2].claimed and claimed.daily.picks[2].progress == claimed.daily.picks[2].target,
		"R128: claimed stays claimed"
	)
	local _, chestState = QuestConfig.dailyViews(claimed, 900)
	check(chestState == "ready", "R128: the Daily Chest still opens after the swap")
	-- A chest already claimed with an order pick survives (every mission still counts as done).
	local chestDone = QuestConfig.reconcileState({
		daily = {
			day = 900,
			chest = true,
			rerolled = false,
			picks = {
				{ stat = "click", target = 120, progress = 120, claimed = true },
				{ stat = "order", target = 3, progress = 3, claimed = true },
				{ stat = "pad", target = 6, progress = 6, claimed = true },
			},
		},
	})
	check(chestDone.daily.chest, "R128: a claimed chest is not lost")
	-- An order pick in slot 1: the later slots still load; junk stays junk.
	local first = QuestConfig.reconcileState({
		daily = {
			day = 900,
			picks = { { stat = "order", target = "x", progress = 0 / 0 }, { stat = "hatch", target = 2, progress = 1 } },
		},
	})
	check(#first.daily.picks == 2 and first.daily.picks[2].stat == "hatch", "R128: later picks still load")
	check(
		first.daily.picks[1].stat ~= "hatch" and first.daily.picks[1].progress == 0,
		"R128: junk order pick → fresh live mission"
	)
	-- Through the real profile load.
	local profileLoaded =
		ProfileLogic.reconcile({ quests = stored({ stat = "order", target = 5, progress = 1 }, false) })
	for _, pick in profileLoaded.quests.daily.picks do
		check(pick.stat ~= "order", "R128: ProfileLogic.reconcile never keeps an order mission")
	end
end

-- ProfileLogic integration.
local default = ProfileLogic.defaultProfile()
check(deepEqual(default.quests, fresh), "ProfileLogic default quests = QuestConfig.newState()")
local reconciled = ProfileLogic.reconcile({})
check(deepEqual(reconciled.quests, fresh), "a pre-0.6.0 save gets a fresh record")
local loaded = ProfileLogic.reconcile({ quests = { starter = { step = 3, claimed = { true, false, true } } } })
check(loaded.quests.starter.step == 3 and loaded.quests.starter.claimed[3] == true, "stored quests survive reconcile")
local snap = ProfileLogic.snapshot(
	loaded,
	{ saveStatus = "ok", paidRandomRestricted = false, policyKnown = true },
	{ "quests" }
)
check(type(snap.quests) == "table" and snap.quests.starter.step == 3, "the snapshot carries `quests`")
check(snap.quests.starter.claimed ~= loaded.quests.starter.claimed, "the snapshot is a copy")
check(table.find(ProfileLogic.SnapshotFields, "quests") ~= nil, "`quests` is a snapshot field")
local saved = ProfileLogic.toSave(loaded)
check(#saved.quests.starter.claimed == 12, "saved claim flags are a dense array (DataStore safe)")
for i = 1, 12 do
	check(type(saved.quests.starter.claimed[i]) == "boolean", `saved claim flag {i} is a boolean`)
end

-- 3. Daily seeding -------------------------------------------------------------------------------------
local function seeded(userId: number, day: number, tier: number, eventLive: boolean)
	local state = QuestConfig.newState()
	local ok, stats = QuestLogic.rollDay(state, day, userId, tier, eventLive)
	return state, ok, stats
end
local a, okA, statsA = seeded(1586034782, DAY, 1, false)
local b = seeded(1586034782, DAY, 1, false)
check(okA and #statsA == 3 and #a.daily.picks == 3, "three missions seeded")
check(deepEqual(a.daily.picks, b.daily.picks), "same user + day → same missions")
check(QuestLogic.seed(1586034782, DAY, 1) == QuestLogic.seed(1586034782, DAY, 1), "seed is deterministic")
check(QuestLogic.seed(1, DAY, 1) ~= QuestLogic.seed(1, DAY + 1, 1), "seed changes with the day")
check(QuestLogic.seed(-1, DAY, 1) > 0, "negative (Studio) user ids hash")
local differentDays = 0
for d = 1, 30 do
	local s = seeded(1586034782, DAY + d, 1, false)
	local x = {}
	for _, pick in s.daily.picks do
		table.insert(x, pick.stat)
	end
	local y = {}
	for _, pick in a.daily.picks do
		table.insert(y, pick.stat)
	end
	if table.concat(x, ",") ~= table.concat(y, ",") then
		differentDays += 1
	end
end
check(differentDays >= 25, "missions vary day to day")

local seenStat: { [string]: number } = {}
for user = 1, 3000 do
	local s = seeded(user * 7919, DAY, 2, user % 2 == 0)
	local distinct: { [string]: boolean } = {}
	for _, pick in s.daily.picks do
		check(not distinct[pick.stat], "no two missions share a stat")
		distinct[pick.stat] = true
		check(pick.target == SPEC_TARGETS[pick.stat][2], "tier 2 targets")
		check(pick.progress == 0 and pick.claimed == false, "fresh missions")
		if user % 2 == 1 then
			check(pick.stat ~= "turkey", "no turkey missions outside the event")
		end
		seenStat[pick.stat] = (seenStat[pick.stat] or 0) + 1
	end
end
for _, mission in QuestConfig.Missions do
	check((seenStat[mission.stat] or 0) > 200, `{mission.stat} missions are handed out`)
end
for tier = 1, 3 do
	local s = seeded(42, DAY, tier, true)
	for _, pick in s.daily.picks do
		check(pick.target == SPEC_TARGETS[pick.stat][tier], `tier {tier} target for {pick.stat}`)
	end
end
-- Tiers from facts.
check(QuestConfig.tierOf(QuestConfig.facts(profileWith({ area = 3 }))) == 1, "area 3 → tier 1")
check(QuestConfig.tierOf(QuestConfig.facts(profileWith({ area = 4 }))) == 2, "area 4 → tier 2")
check(QuestConfig.tierOf(QuestConfig.facts(profileWith({ area = 6 }))) == 2, "area 6 → tier 2")
check(QuestConfig.tierOf(QuestConfig.facts(profileWith({ area = 7 }))) == 3, "area 7 → tier 3")
check(QuestConfig.tierOf(QuestConfig.facts(profileWith({ area = 1, rebirths = 1 }))) == 3, "a rebirth → tier 3")
check(
	QuestConfig.tierOf(
		QuestConfig.facts(profileWith({ area = 1, worlds = { dino = { rebirths = 2, unlocked = true } } }))
	) == 3,
	"a world rebirth → tier 3"
)
-- UTC rollover + backwards clock.
local rolling = seeded(7, DAY, 1, false)
rolling.daily.picks[1].progress = rolling.daily.picks[1].target
rolling.daily.chest = false
rolling.daily.rerolled = true
check(not QuestLogic.rollDay(rolling, DAY, 7, 1, false), "same day: nothing re-seeds")
check(not QuestLogic.rollDay(rolling, DAY - 1, 7, 1, false), "clock behind: nothing opens")
check(rolling.daily.day == DAY and rolling.daily.rerolled, "clock behind keeps the record")
check(QuestLogic.rollDay(rolling, DAY + 1, 7, 1, false), "next UTC day re-seeds")
check(
	rolling.daily.day == DAY + 1 and not rolling.daily.rerolled and not rolling.daily.chest,
	"new day: reroll + chest reset"
)
for _, pick in rolling.daily.picks do
	check(pick.progress == 0, "new day: progress 0")
end
check(QuestConfig.secondsToReset(DAY * 86400) == 86400, "reset countdown at midnight = 24 h")
check(QuestConfig.secondsToReset(DAY * 86400 + 86399) == 1, "reset countdown 1 s before midnight")

-- 4. Progress -----------------------------------------------------------------------------------------
local state = QuestConfig.newState()
state.daily = {
	day = DAY,
	picks = {
		{ stat = "click", target = 3, progress = 0, claimed = false },
		{ stat = "pad", target = 2, progress = 0, claimed = false },
		{ stat = "hatch", target = 4, progress = 0, claimed = false },
	},
	chest = false,
	rerolled = false,
}
local done, changed = QuestLogic.applyProgress(state, "click", 2, DAY)
check(#done == 0 and changed and state.daily.picks[1].progress == 2, "progress counts")
check(state.life.click == 2, "life counts clicks")
done = QuestLogic.applyProgress(state, "click", 50, DAY)
check(#done == 1 and done[1] == 1 and state.daily.picks[1].progress == 3, "capped at the target, finished once")
done = QuestLogic.applyProgress(state, "click", 1, DAY)
check(#done == 0 and state.life.click == 53, "a finished mission does not report again; life keeps counting")
done, changed = QuestLogic.applyProgress(state, "crate", 1, DAY)
check(#done == 0 and not changed, "an uncounted stat changes nothing")
done, changed = QuestLogic.applyProgress(state, "pad", 1, DAY + 1)
check(#done == 0 and state.daily.picks[2].progress == 0 and state.life.pad == 1, "another day: life only")
for _, bad in { 0 / 0, math.huge, -1, 0, "1" :: any, nil :: any } do
	local _, didChange = QuestLogic.applyProgress(state, "pad", bad, DAY)
	check(not didChange, `junk amount {tostring(bad)} ignored`)
end
_, changed = QuestLogic.applyProgress(state, "nope", 1, DAY)
check(not changed, "unknown stat ignored")
QuestLogic.applyProgress(state, "hatch", 3, DAY)
QuestLogic.applyProgress(state, "pad", 2, DAY)

-- 5. Starter chain -----------------------------------------------------------------------------------
local chain = QuestConfig.newState()
QuestLogic.startChain(chain)
check(chain.starter.base.spin == 0, "chain start records the spin base")
check(not QuestLogic.startChain(chain), "chain start is once")
local newbie = QuestConfig.facts(profileWith({ pads = firstPads(2) }))
check(#QuestLogic.advanceStarter(chain, newbie) == 0, "2 pads: goal 1 not done")
check(QuestConfig.goalProgress(QuestConfig.Goals[1], newbie, chain) == 2, "goal 1 progress = pads owned")
local fivePads =
	QuestConfig.facts(profileWith({ pads = firstPads(5), producers = { [QuestConfig.Goals[2].producer] = 9 } }))
local completed = QuestLogic.advanceStarter(chain, fivePads)
check(#completed == 1 and completed[1] == 1 and chain.starter.step == 1, "5 pads: goal 1 done")
check(QuestConfig.goalProgress(QuestConfig.Goals[2], fivePads, chain) == 9, "goal 2 progress = Workbench level")
-- Managers: own the first Manager pad.
local managerPads = firstPads(5)
for _, pad in TycoonConfig.PadOrder do
	if pad.kind == "Manager" then
		managerPads[pad.id] = true
		break
	end
end
local withManager =
	QuestConfig.facts(profileWith({ pads = managerPads, producers = { [QuestConfig.Goals[2].producer] = 10 } }))
check(withManager.managers == 1, "facts count Manager pads")
completed = QuestLogic.advanceStarter(chain, withManager)
check(#completed == 2 and chain.starter.step == 3, "goals 2 + 3 complete in order")
-- Goal 4 needs 12 pads; goal 5 is the spin counter.
local twelve = QuestConfig.facts(
	profileWith({ pads = firstPads(12), area = 2, producers = { [QuestConfig.Goals[2].producer] = 10 } })
)
completed = QuestLogic.advanceStarter(chain, twelve)
check(chain.starter.step == 4, "12 pads: goal 4, then the spin goal blocks")
QuestLogic.applyProgress(chain, "spin", 1, DAY)
completed = QuestLogic.advanceStarter(chain, twelve)
check(chain.starter.step == 6 and completed[1] == 5 and completed[2] == 6, "a spin completes 5, area 2 completes 6")
-- Sticky: a rebirth-style reset of the run (facts drop) never takes goals back.
local reset = QuestConfig.facts(profileWith({}))
check(#QuestLogic.advanceStarter(chain, reset) == 0 and chain.starter.step == 6, "goals are sticky")
-- Veteran: rebirths imply every run goal; hatched + daily from the profile; the spin counter is
-- still needed (counted since the chain started).
local veteranState = QuestConfig.newState()
QuestLogic.startChain(veteranState)
local veteran =
	QuestConfig.facts(profileWith({ rebirths = 2, hatched = 40, daily = { streak = 3, lastDay = DAY - 1 } }))
completed = QuestLogic.advanceStarter(veteranState, veteran)
check(veteranState.starter.step == 4, "veteran: goals 1-4 at once, then the spin goal")
QuestLogic.applyProgress(veteranState, "spin", 1, DAY)
completed = QuestLogic.advanceStarter(veteranState, veteran)
check(veteranState.starter.step == 12 and #completed == 8, "veteran: everything else at once")
-- Counter goals measure life - base; a RECORDED base is honoured (a chain started later than the
-- counters would not count the earlier spins).
local late = QuestConfig.newState()
late.life.spin = 4
late.starter.base.spin = 4
check(not QuestLogic.startChain(late), "a recorded base is kept")
check(QuestConfig.goalProgress(QuestConfig.Goals[5], newbie, late) == 0, "spins before a recorded base do not count")
late.life.spin = 5
check(QuestConfig.goalProgress(QuestConfig.Goals[5], newbie, late) == 1, "a spin after the base counts")

-- R78 review regression: a base of 0 must survive save → load, and startChain must never re-base.
-- Repro: fresh profile → startChain → one spin → toSave → reconcile → startChain. Before the fix
-- reconcile dropped base 0, startChain re-based spin to the lifetime count (1) and goal 5 went
-- from 1/1 back to 0/1 on every rejoin (blocking goals 6-12).
do
	local profile = ProfileLogic.defaultProfile()
	QuestLogic.startChain(profile.quests)
	check(profile.quests.starter.base.spin == 0, "round trip: the chain starts at spin base 0")
	QuestLogic.applyProgress(profile.quests, "spin", 1, DAY)
	local facts = QuestConfig.facts(profile)
	check(QuestConfig.goalProgress(QuestConfig.Goals[5], facts, profile.quests) == 1, "round trip: one spin = 1/1")
	local saved = ProfileLogic.toSave(profile)
	check(saved.quests.starter.base.spin == 0, "round trip: the saved record keeps base 0")
	local loaded = ProfileLogic.reconcile(saved)
	check(loaded.quests.starter.base.spin == 0, "round trip: reconcile keeps base 0")
	check(not QuestLogic.startChain(loaded.quests), "round trip: startChain does not re-base on load")
	check(loaded.quests.life.spin == 1 and loaded.quests.starter.base.spin == 0, "round trip: life 1, base 0")
	check(
		QuestConfig.goalProgress(QuestConfig.Goals[5], QuestConfig.facts(loaded), loaded.quests) == 1,
		"round trip: goal 5 stays 1/1 after rejoin"
	)
	-- Twice more (every rejoin): still 1/1.
	for _ = 1, 2 do
		loaded = ProfileLogic.reconcile(ProfileLogic.toSave(loaded))
		QuestLogic.startChain(loaded.quests)
	end
	check(
		QuestConfig.goalProgress(QuestConfig.Goals[5], QuestConfig.facts(loaded), loaded.quests) == 1,
		"round trip: goal 5 stays done across repeated rejoins"
	)
	-- The chain then advances past goal 5 on the loaded record (goals 1-4 by a rebirth).
	loaded.rebirths = 1
	QuestLogic.advanceStarter(loaded.quests, QuestConfig.facts(loaded))
	check(loaded.quests.starter.step >= 5, "round trip: goal 5 completes after rejoin")
end
-- Migration: a save written while the bug existed (base dropped, spins counted) counts every spin
-- since 0.6.0 instead of re-basing.
do
	local legacy = ProfileLogic.reconcile({ quests = { starter = { step = 4, base = {} }, life = { spin = 3 } } })
	QuestLogic.startChain(legacy.quests)
	check(legacy.quests.starter.base.spin == 0, "migration: a missing base becomes 0, never the lifetime count")
	check(
		QuestConfig.goalProgress(QuestConfig.Goals[5], QuestConfig.facts(legacy), legacy.quests) == 1,
		"migration: the spins already made count for goal 5"
	)
	local zeroKept = QuestConfig.reconcileState({ starter = { base = { spin = 0, bad = -1, nan = 0 / 0 } } })
	check(zeroKept.starter.base.spin == 0, "reconcile keeps a base of 0")
	check(zeroKept.starter.base.bad == nil and zeroKept.starter.base.nan == nil, "reconcile still drops junk bases")
	check(QuestConfig.reconcileState({ life = { spin = 0 } }).life.spin == nil, "life zeros are still dropped")
end
-- forceStep (admin).
local forced = QuestConfig.newState()
check(QuestLogic.forceStep(forced) == 1 and forced.starter.step == 1, "forceStep completes the current goal")
forced.starter.step = 12
check(QuestLogic.forceStep(forced) == nil, "forceStep past the end refuses")
-- Facts: tutorial.
check(not QuestConfig.facts(profileWith({ tutorialStep = 5 })).tutorialDone, "tutorial step 5: not done")
check(QuestConfig.facts(profileWith({ tutorialStep = TutorialLogic.DoneStep })).tutorialDone, "tutorial done step")
check(QuestConfig.facts(profileWith({ area = 2 })).tutorialDone, "area 2 implies the tutorial is done")
check(QuestConfig.facts(nil).pads == 0 and QuestConfig.facts("junk").area == 1, "facts never error")
local junkFacts = QuestConfig.facts({
	tycoon = { pads = { nope = true, [5] = true }, producers = { p = 0 / 0 }, area = 0 / 0 },
	stats = { clicks = math.huge },
	pets = { index = { GlowSlime = true, notAPet = true } },
})
check(junkFacts.pads == 0 and junkFacts.maxLevel == 0 and junkFacts.area == 1, "junk tycoon facts read as 0")
check(junkFacts.clicks == 0, "inf stats read as 0")

-- 6. Claims ----------------------------------------------------------------------------------------------
local ok, code, reward, xp = QuestLogic.claimStarter(chain, 1)
check(ok and code == "ok" and reward == QuestConfig.Goals[1].reward and xp == 50, "claim goal 1")
ok, code = QuestLogic.claimStarter(chain, 1)
check(not ok and code == "claimed", "a second claim is refused (idempotent)")
ok, code = QuestLogic.claimStarter(chain, 7)
check(not ok and code == "locked", "an unfinished goal can not be claimed")
ok, code = QuestLogic.claimStarter(chain, 13)
check(not ok and code == "unknown", "unknown goal")
ok, code = QuestLogic.claimStarter(chain, 6)
check(ok, "completed goals claim in any order")

-- Daily claims (state from §4: click finished, pad finished, hatch 3/4).
local dailyCode
ok, dailyCode = QuestLogic.claimDaily(state, 3, DAY)
check(not ok and dailyCode == "locked", "an unfinished mission can not be claimed")
local stat
ok, dailyCode, reward, xp, stat = QuestLogic.claimDaily(state, 1, DAY)
check(ok and reward == QuestConfig.MissionReward and xp == 100 and stat == "click", "claim a finished mission")
ok, dailyCode = QuestLogic.claimDaily(state, 1, DAY)
check(not ok and dailyCode == "claimed", "a mission claims once")
ok, dailyCode = QuestLogic.claimDaily(state, 2, DAY + 1)
check(not ok and dailyCode == "stale", "yesterday's record is stale")
ok, dailyCode = QuestLogic.claimDaily(state, 4, DAY)
check(not ok and dailyCode == "unknown", "slot 4 unknown")
ok, dailyCode = QuestLogic.claimChest(state, DAY)
check(not ok and dailyCode == "locked", "chest needs all three finished")
QuestLogic.applyProgress(state, "hatch", 1, DAY)
ok, dailyCode, reward, xp = QuestLogic.claimChest(state, DAY)
check(ok and reward == QuestConfig.ChestReward and xp == 150, "chest opens once all three are finished")
ok, dailyCode = QuestLogic.claimChest(state, DAY)
check(not ok and dailyCode == "claimed", "chest claims once")
ok = QuestLogic.claimDaily(state, 2, DAY)
check(ok, "a mission can still be claimed after the chest")

-- Trophies.
local trophyState = QuestConfig.newState()
local noFacts = QuestConfig.facts(profileWith({}))
ok, code = QuestLogic.claimTrophy(trophyState, "clicker", noFacts)
check(not ok and code == "locked", "clicker locked at 0")
trophyState.life.click = 1_500
local tier
ok, code, reward, xp, tier = QuestLogic.claimTrophy(trophyState, "clicker", noFacts)
check(ok and tier == 1 and reward.gems == 10 and xp == 75, "clicker I")
ok, code, reward, xp, tier = QuestLogic.claimTrophy(trophyState, "clicker", noFacts)
check(ok and tier == 2 and reward.gems == 25, "clicker II (tiers claim one at a time)")
ok, code = QuestLogic.claimTrophy(trophyState, "clicker", noFacts)
check(not ok and code == "locked", "clicker III locked at 1.5K")
ok, code = QuestLogic.claimTrophy(trophyState, "nope", noFacts)
check(not ok and code == "unknown", "unknown trophy")
-- Backfill from profile lifetime stats.
local backfill = QuestConfig.facts(profileWith({ padsBought = 120, hatched = 30, playSeconds = 65 * 60, clicks = 10 }))
check(
	QuestConfig.trophyValue(QuestConfig.TrophyById.builder, backfill, trophyState) == 120,
	"builder backfills padsBought"
)
check(QuestConfig.trophyValue(QuestConfig.TrophyById.hatcher, backfill, trophyState) == 30, "hatcher backfills hatched")
check(
	QuestConfig.trophyValue(QuestConfig.TrophyById.traveller, backfill, trophyState) == 65,
	"traveller backfills minutes"
)
check(
	QuestConfig.trophyValue(QuestConfig.TrophyById.clicker, backfill, trophyState) == 1_500,
	"the larger of life / profile"
)
check(QuestConfig.trophyValue(QuestConfig.TrophyById.upgrader, backfill, trophyState) == 0, "upgrader has no backfill")
-- State trophies.
local index = {}
for i = 1, 16 do
	index[PetConfig.Order[i]] = true
end
local stateFacts = QuestConfig.facts(profileWith({
	index = index,
	rebirths = 2,
	worlds = { dino = { unlocked = true, rebirths = 1 }, moon = { unlocked = false, rebirths = 0 } },
}))
check(stateFacts.indexCount == 16 and stateFacts.worlds == 2 and stateFacts.rebirthsAll == 3, "state facts")
ok, code, reward, xp, tier = QuestLogic.claimTrophy(trophyState, "collector", stateFacts)
check(ok and tier == 1, "collector I at 16 pets")
ok, code, reward, xp, tier = QuestLogic.claimTrophy(trophyState, "collector", stateFacts)
check(ok and tier == 2, "collector II at 16 pets")
ok = QuestLogic.claimTrophy(trophyState, "explorer", stateFacts)
check(ok, "explorer I at 2 worlds")
ok, code = QuestLogic.claimTrophy(trophyState, "explorer", stateFacts)
check(not ok and code == "locked", "explorer II needs 3 worlds")
ok, code, reward, xp, tier = QuestLogic.claimTrophy(trophyState, "reborn", stateFacts)
check(ok and tier == 1, "reborn I")
ok, code, reward, xp, tier = QuestLogic.claimTrophy(trophyState, "reborn", stateFacts)
check(ok and tier == 2, "reborn II at 3 rebirths (all worlds)")
trophyState.trophies.explorer = 2
ok, code = QuestLogic.claimTrophy(trophyState, "explorer", stateFacts)
check(not ok and code == "claimed", "a maxed trophy refuses")
-- Admin counter.
check(QuestLogic.setCounter(trophyState, "upgrader", 1_000), "set a counter trophy")
check(trophyState.life.upgrade == 1_000, "counter written")
check(not QuestLogic.setCounter(trophyState, "collector", 5), "state trophies refuse")
check(not QuestLogic.setCounter(trophyState, "upgrader", 0 / 0), "NaN refused")
check(not QuestLogic.setCounter(trophyState, "upgrader", -1), "negative refused")

-- 7. Rerolls -------------------------------------------------------------------------------------------
local rr = seeded(99, DAY, 1, false)
local shownBefore: { [string]: boolean } = {}
for _, pick in rr.daily.picks do
	shownBefore[pick.stat] = true
end
local rerollOk, rerollCode, old, new = QuestLogic.reroll(rr, 2, DAY, 99, 1, false)
check(rerollOk and rerollCode == "ok" and old ~= nil and new ~= nil, "reroll an unfinished mission")
check(
	not shownBefore[new :: string] and new ~= "turkey",
	"the new stat was not shown (and no turkey outside the event)"
)
check(rr.daily.picks[2].stat == new and rr.daily.picks[2].progress == 0, "new mission starts at 0")
check(rr.daily.picks[2].target == SPEC_TARGETS[new :: string][1], "new mission target by tier")
rerollOk, rerollCode = QuestLogic.reroll(rr, 1, DAY, 99, 1, false)
check(not rerollOk and rerollCode == "used", "one free reroll per day")
local rr2 = seeded(99, DAY, 1, false)
local _, _, _, again = QuestLogic.reroll(rr2, 2, DAY, 99, 1, false)
check(again == new, "rerolls are deterministic for the user + day")
local rr3 = seeded(5, DAY, 1, false)
rr3.daily.picks[1].progress = rr3.daily.picks[1].target
rerollOk, rerollCode = QuestLogic.reroll(rr3, 1, DAY, 5, 1, false)
check(not rerollOk and rerollCode == "done", "a finished mission can not be rerolled")
rerollOk, rerollCode = QuestLogic.reroll(rr3, 2, DAY + 1, 5, 1, false)
check(not rerollOk and rerollCode == "stale", "yesterday's missions can not be rerolled")
rerollOk, rerollCode = QuestLogic.reroll(rr3, 9, DAY, 5, 1, false)
check(not rerollOk and rerollCode == "unknown", "unknown slot")
for user = 1, 500 do
	local s = seeded(user, DAY, 3, true)
	local slot = (user % 3) + 1
	local before: { [string]: boolean } = {}
	for _, pick in s.daily.picks do
		before[pick.stat] = true
	end
	local good, _, _, swapped = QuestLogic.reroll(s, slot, DAY, user, 3, true)
	check(good and not before[swapped :: string], "rerolled stat is never one already shown")
	local distinct: { [string]: boolean } = {}
	for _, pick in s.daily.picks do
		check(not distinct[pick.stat], "no duplicate stats after a reroll")
		distinct[pick.stat] = true
	end
end
-- Reset (admin).
local resetStats = QuestLogic.resetDay(rr, DAY, 99, 1, false)
check(#resetStats == 3 and not rr.daily.rerolled and rr.daily.day == DAY, "admin reset re-seeds today")

-- 8. Hostile remote arguments --------------------------------------------------------------------------
local cyclic: any = {}
cyclic.self = cyclic
local HOSTILE: { any } = {
	nil,
	0 / 0,
	math.huge,
	-math.huge,
	-1,
	0,
	1.5,
	13,
	4,
	1e300,
	"",
	"1",
	"starter",
	string.rep("a", 5000),
	"\0\1\2",
	"clicker\0",
	true,
	false,
	{},
	cyclic,
	setmetatable({}, {
		__index = function()
			return true
		end,
	}),
	Vector3.new(1, 2, 3),
}
for _, kind in { "starter", "daily", "chest", "trophy", "STARTER", "", 5, nil, {} :: any } do
	for _, id in HOSTILE do
		local okCall, request = pcall(QuestLogic.readClaim, kind, id)
		check(okCall, "readClaim never throws")
		if request ~= nil then
			check(
				kind == "chest" or (kind == "starter" and id == 4) or (kind == "daily" and false),
				`only valid claims pass ({tostring(kind)}, {tostring(id)})`
			)
		end
	end
end
check(QuestLogic.readClaim("starter", 12).index == 12, "starter 12 valid")
check(QuestLogic.readClaim("starter", 0) == nil, "starter 0 refused")
check(QuestLogic.readClaim("daily", 3).index == 3, "daily 3 valid")
check(QuestLogic.readClaim("daily", 4) == nil, "daily 4 refused")
check(QuestLogic.readClaim("trophy", "traveller").trophy == "traveller", "trophy id valid")
check(QuestLogic.readClaim("trophy", "Traveller") == nil, "trophy ids are exact")
check(QuestLogic.readClaim("trophy", "__index") == nil, "metamethod names refused")
check(QuestLogic.readClaim("chest", nil).kind == "chest", "chest needs no id")
for _, slot in HOSTILE do
	local okCall, value = pcall(QuestLogic.readSlot, slot)
	check(okCall, "readSlot never throws")
	check(value == nil or (slot == 0 and false) or value == slot, "readSlot passes only 1..3")
	if value ~= nil then
		check(value >= 1 and value <= 3 and value % 1 == 0, "readSlot range")
	end
end

-- 9. Views + badge ---------------------------------------------------------------------------------------
local viewState = QuestConfig.newState()
QuestLogic.startChain(viewState)
local viewFacts = QuestConfig.facts(profileWith({ pads = firstPads(5) }))
QuestLogic.advanceStarter(viewState, viewFacts)
QuestLogic.rollDay(viewState, DAY, 11, 1, false)
local views = QuestConfig.starterViews(viewState, viewFacts)
check(views[1].state == "ready" and views[2].state == "active" and views[3].state == "locked", "goal views")
check(QuestConfig.currentGoal(viewState) == QuestConfig.Goals[2], "current goal = step + 1")
check(QuestConfig.claimableCount(viewState, viewFacts, DAY) == 1, "badge: one ready goal")
viewState.daily.picks[1].progress = viewState.daily.picks[1].target
check(QuestConfig.claimableCount(viewState, viewFacts, DAY) == 2, "badge: + a finished mission")
local missions, chest, stale = QuestConfig.dailyViews(viewState, DAY)
check(#missions == 3 and chest == "locked" and not stale, "daily views")
check(missions[1].state == "ready" and missions[2].state == "active", "mission states")
local _, _, staleNext = QuestConfig.dailyViews(viewState, DAY + 1)
check(staleNext, "another day reads stale (the server re-seeds)")
check(QuestConfig.claimableCount(viewState, viewFacts, DAY + 1) == 1, "stale missions never badge")
for _, pick in viewState.daily.picks do
	pick.progress = pick.target
end
local _, chestReady = QuestConfig.dailyViews(viewState, DAY)
check(chestReady == "ready", "chest ready when all three are finished")
check(QuestConfig.claimableCount(viewState, viewFacts, DAY) == 5, "badge: goal + 3 missions + chest")
viewState.life.click = 100
local trophyViews = QuestConfig.trophyViews(viewState, viewFacts)
check(trophyViews[1].trophy.id == "clicker" and trophyViews[1].state == "ready", "trophy view ready")
check(QuestConfig.claimableCount(viewState, viewFacts, DAY) == 6, "badge: + a ready trophy")
QuestLogic.claimStarter(viewState, 1)
check(QuestConfig.claimableCount(viewState, viewFacts, DAY) == 5, "a claim lowers the badge")
check(QuestConfig.tierName(QuestConfig.TrophyById.clicker, 3) == "Clicker III", "tier names")

-- 10. Analytics keys --------------------------------------------------------------------------------------
local keys: { string } = { QuestConfig.Keys.chest() }
for i = 1, QuestConfig.GoalCount do
	table.insert(keys, QuestConfig.Keys.goalDone(i))
	table.insert(keys, QuestConfig.Keys.goalClaim(i))
end
for _, missionStat in QuestConfig.MissionStats do
	table.insert(keys, QuestConfig.Keys.dailyPick(missionStat))
	table.insert(keys, QuestConfig.Keys.dailyDone(missionStat))
	table.insert(keys, QuestConfig.Keys.dailyClaim(missionStat))
	table.insert(keys, QuestConfig.Keys.reroll(missionStat))
end
for _, trophy in QuestConfig.Trophies do
	for t = 1, #trophy.tiers do
		table.insert(keys, QuestConfig.Keys.trophy(trophy.id, t))
	end
end
for _, key in keys do
	check(KeySpec.check("retention", key) == key, `KeySpec accepts {key}`)
end
check(KeySpec.check("retention", "quest:goalDone:13") == nil, "goal 13 is not a key")
check(KeySpec.check("retention", "quest:trophy:clicker:6") == nil, "tier 6 is not a key")

-- 11. Open rule ---------------------------------------------------------------------------------------
local function chip(anyModalOpen: any, guiding: any, tutorialDone: any, shown: any)
	return QuestOpenRules.chip({
		anyModalOpen = anyModalOpen,
		guiding = guiding,
		tutorialDone = tutorialDone,
		shown = shown,
	} :: any)
end
local allowed, reason = chip(false, false, true, true)
check(allowed and reason == "ok", "a calm screen with a quest chip opens Quests")
allowed, reason = chip(true, false, true, true)
check(not allowed and reason == "modal", "never over another open window (NukePass QA)")
allowed, reason = chip(false, true, true, true)
check(not allowed and reason == "guiding", "never during the guided first minute (JoinFlow)")
allowed, reason = chip(false, false, false, true)
check(not allowed and reason == "tutorial", "never before the tutorial is done")
allowed, reason = chip(false, false, true, false)
check(not allowed and reason == "hidden", "never from a hidden chip")
check(not chip(nil, false, true, true) and not chip(false, nil, true, true), "unknown modal / guiding state refuses")
check(not chip(false, false, nil, true) and not chip(false, false, true, nil), "unknown tutorial / chip state refuses")
for _, a in { true, false, nil :: any, "x" } do
	for _, g in { true, false, nil :: any } do
		for _, t in { true, false, nil :: any } do
			for _, v in { true, false, nil :: any } do
				local ok = chip(a, g, t, v)
				check(
					ok == (a == false and g == false and t == true and v == true),
					"fail closed on every unknown input"
				)
			end
		end
	end
end

print(`[quest-logic] {checks} checks passed`)
