--!strict
--[[
	Tycoon server pure logic (src/server/Tycoon/{TycoonRules, TutorialLogic, ModifierSources}).

	Checks the decisions the server makes without Instances: upgrade modes, batched cycle
	catch-up and hitch caps, phase-preserving cycle changes, cash pack / fallback amounts, reach
	checks, modifier merging, the tutorial's step machine and payloads, and ModifierSources
	(registration, merge, offline filter, validUntil, a yielding / throwing provider counts as
	neutral). Hostile inputs (NaN, inf, wrong types) must give the safe answer.

	Run: lune run tests/tycoon-server-logic.luau
]]

local roblox = require("@lune/roblox")

local Loader = require("./fixtures/RobloxLoader")

local Vector3 = roblox.Vector3

local loader = Loader.new()
local TycoonConfig = loader.load("src/shared/Config/TycoonConfig")
local TycoonLogic = loader.load("src/shared/Tycoon/TycoonLogic")
local TycoonRules = loader.load("src/server/Tycoon/TycoonRules")
local TutorialLogic = loader.load("src/server/Tycoon/TutorialLogic")
local ModifierSources = loader.load("src/server/Tycoon/ModifierSources")

local checks = 0
local function check(ok: boolean, message: string)
	assert(ok, message)
	checks += 1
end
local function near(a: number, b: number): boolean
	return math.abs(a - b) <= 1e-9 * math.max(1, math.abs(a), math.abs(b))
end

local NAN = 0 / 0
local INF = math.huge
local WORKBENCH = TycoonConfig.ProducersById.p1_workbench

--------------------------------------------------------------------------------------------------
-- upgradeCount
--------------------------------------------------------------------------------------------------
do
	local count, cost = TycoonRules.upgradeCount("1", WORKBENCH, 1, 1e9)
	check(count == 1 and cost == WORKBENCH.baseCost, "x1 upgrade")
	count, cost = TycoonRules.upgradeCount("10", WORKBENCH, 5, 1e12)
	check(count == 10 and cost == TycoonLogic.upgradeCost(WORKBENCH, 5, 10), "x10 upgrade")
	count = TycoonRules.upgradeCount("10", WORKBENCH, 5, TycoonLogic.upgradeCost(WORKBENCH, 5, 10) - 1)
	check(count == 0, "x10 is all or nothing")
	count, cost = TycoonRules.upgradeCount("max", WORKBENCH, 1, 100)
	local maxCount, maxCost = TycoonLogic.maxAffordable(WORKBENCH, 1, 100)
	check(count == maxCount and cost == maxCost and count > 0, "max = maxAffordable")
	count = TycoonRules.upgradeCount("10", WORKBENCH, TycoonConfig.MaxLevel - 3, 1e300)
	check(count == 3, "x10 near the cap buys what fits")
	check(TycoonRules.upgradeCount("1", WORKBENCH, TycoonConfig.MaxLevel, 1e300) == 0, "capped buys nothing")
	check(TycoonRules.upgradeCount("1", WORKBENCH, 0, 1e300) == 0, "unbuilt buys nothing")
	for _, bad in { "2", "MAX", 10, nil, {} } do
		check(TycoonRules.upgradeCount(bad, WORKBENCH, 3, 1e300) == 0, `mode {tostring(bad)} refused`)
	end
	for _, bad in { NAN, INF, -5, 0 } do
		check(TycoonRules.upgradeCount("max", WORKBENCH, 3, bad) == 0, `cash {tostring(bad)} buys nothing`)
	end
end

--------------------------------------------------------------------------------------------------
-- catchUp / preservePhase
--------------------------------------------------------------------------------------------------
do
	local cycles, start = TycoonRules.catchUp(10, 0.5, 11.2, 100)
	check(cycles == 2 and near(start, 11), "two cycles completed")
	cycles, start = TycoonRules.catchUp(10, 0.5, 10.4, 100)
	check(cycles == 0 and start == 10, "unfinished cycle pays nothing")
	cycles, start = TycoonRules.catchUp(0, 0.1, 1000.05, 50)
	check(cycles == 50 and near(start, 1000.05 - (1000.05 % 0.1)), "hitch capped and phase restarted")
	for _, bad in { NAN, INF, 0, -1 } do
		cycles = TycoonRules.catchUp(0, bad, 10, 100)
		check(cycles == 0, `cycle {tostring(bad)} pays nothing`)
	end
	check(TycoonRules.catchUp(NAN, 1, 10, 100) == 0, "NaN start pays nothing")
	-- Phase: 40 % through a 10 s cycle stays 40 % through a 5 s cycle.
	local newStart = TycoonRules.preservePhase(100, 10, 5, 104)
	check(near((104 - newStart) / 5, 0.4), "phase preserved")
	check(TycoonRules.preservePhase(NAN, 10, 5, 104) == 104, "bad input restarts the bar")
	check(near(TycoonRules.preservePhase(0, 1, 1, 50), 49), "overdue phase clamps to a full bar")
end

--------------------------------------------------------------------------------------------------
-- Cash packs / fallback / reach
--------------------------------------------------------------------------------------------------
do
	check(TycoonRules.cashPackAmount(600, 1000, 50) == 30000, "scaled cash pack")
	check(TycoonRules.cashPackAmount(600, 1000, 0) == 1000, "floor for new players")
	check(TycoonRules.cashPackAmount(600, 1000, NAN) == 1000, "NaN income -> floor")
	check(TycoonRules.cashPackAmount(600, 1000, INF) <= 1e300, "inf income clamped")
	check(TycoonRules.cashPackAmount(NAN, NAN, 5) == 0, "nonsense config -> 0")
	check(TycoonRules.fallbackGrant(0) == TycoonRules.FallbackFloor, "fallback floor")
	check(TycoonRules.fallbackGrant(100) == 100 * TycoonRules.FallbackSeconds, "fallback scales")
	check(TycoonRules.withinReach(Vector3.new(0, 0, 0), Vector3.new(6, 2, 8), 12, 10), "in reach")
	check(not TycoonRules.withinReach(Vector3.new(0, 0, 0), Vector3.new(9, 0, 9), 12, 10), "out of reach (horizontal)")
	check(not TycoonRules.withinReach(Vector3.new(0, 0, 0), Vector3.new(0, 30, 0), 12, 10), "out of reach (vertical)")
	check(not TycoonRules.withinReach(nil, Vector3.new(0, 0, 0), 12, 10), "no character -> no reach")
	check(not TycoonRules.withinReach(Vector3.new(NAN, 0, 0), Vector3.new(0, 0, 0), 12, 10), "NaN -> no reach")
end

--------------------------------------------------------------------------------------------------
-- mergeModifiers
--------------------------------------------------------------------------------------------------
do
	local merged = TycoonRules.mergeModifiers({
		{ petCash = 0.25, cashPass = true },
		{ petCash = 0.1, boostCash = 2, vip = false },
		{ boostCash = 2, serverCash = 2, eventCash = 1.5, boostSpeed = 2 },
		nil :: any,
		"junk",
		{ petCash = NAN, boostCash = -3, serverCash = INF, vip = "yes" },
	}, 2, { clickPower = 3 })
	check(near(merged.petCash, 0.35), "pet bonuses add")
	check(merged.cashPass == true and merged.vip == false, "booleans OR (strict true only)")
	check(merged.boostCash == 4 and merged.serverCash == 2 and merged.eventCash == 1.5, "multipliers multiply")
	check(merged.boostSpeed == 2, "speed multiplies")
	check(merged.rebirths == 2 and merged.rebirthShop.clickPower == 3, "rebirth data from the profile")
	local empty = TycoonRules.mergeModifiers({}, 0, {})
	check(empty.petCash == 0 and empty.boostCash == 1 and not empty.cashPass, "no sources = neutral")
end

--------------------------------------------------------------------------------------------------
-- TutorialLogic
--------------------------------------------------------------------------------------------------
do
	local state = TycoonLogic.newState()
	local DONE = TutorialLogic.DoneStep
	check(TutorialLogic.evaluate(state, 0, 0) == 1, "starts at step 1")
	local payload = TutorialLogic.payload(1, state)
	check(payload.step == 1 and payload.kind == "pad" and payload.target == "a1_workbench", "step 1 payload")
	TycoonLogic.applyPad(state, "a1_workbench")
	check(TutorialLogic.evaluate(state, 0, 1) == 2, "workbench built -> click")
	check(TutorialLogic.payload(2, state).target == "p1_workbench", "click target")
	check(TutorialLogic.evaluate(state, 1, 2) == 3, "clicked -> upgrade")
	TycoonLogic.applyLevels(state, "p1_workbench", 1)
	check(TutorialLogic.evaluate(state, 1, 3) == 4, "upgraded -> tool wall")
	TycoonLogic.applyPad(state, "a1_tool_wall")
	TycoonLogic.applyPad(state, "a1_glow_lamp")
	-- R122: Uncle Atom is pad 4, so step 6 points straight at him (no chain).
	check(TutorialLogic.evaluate(state, 1, 4) == 6, "glow lamp -> hire the manager")
	local hire = TutorialLogic.payload(6, state)
	check(
		hire.kind == "pad" and hire.target == "a1_uncle_atom" and hire.padId == "a1_uncle_atom",
		"step 6 = Uncle Atom"
	)
	check(TutorialLogic.Steps[6].chain ~= true, "step 6 is a direct pad step")
	check(string.find(hire.text or "", "Uncle Atom", 1, true) ~= nil, "step 6 names Uncle Atom")
	check(TycoonLogic.nextPads(state)[1].id == "a1_uncle_atom", "Uncle Atom is the pad on offer")
	TycoonLogic.applyPad(state, "a1_uncle_atom")
	check(TutorialLogic.evaluate(state, 1, 6) == 7, "manager hired -> open the stand")
	check(TutorialLogic.payload(7, state).target == "a1_garage_door", "chain target = next pad (garage door)")
	for _, id in { "a1_garage_door", "a1_mini_reactor", "a1_paint_station" } do
		TycoonLogic.applyPad(state, id)
	end
	check(TutorialLogic.evaluate(state, 1, 7) == 7, "still saving for the stand")
	check(TutorialLogic.payload(7, state).target == "a1_driveway", "chain target = driveway")
	TycoonLogic.applyPad(state, "a1_driveway")
	TycoonLogic.applyPad(state, "a1_open_stand")
	check(TutorialLogic.evaluate(state, 1, 7) == DONE, "stand open -> done")
	local done = TutorialLogic.payload(DONE, state)
	check(done.step == 0 and done.done == true, "done payload")
	-- Monotonic: a rebirth (fresh state) never restarts a finished tutorial.
	check(TutorialLogic.evaluate(TycoonLogic.newState(), 0, DONE) == DONE, "done stays done")
	check(TutorialLogic.evaluate(TycoonLogic.newState(), 0, NAN) == 1, "NaN stored step -> evaluate")
	-- Any later progress implies the click step.
	local skipped = TycoonLogic.newState()
	TycoonLogic.applyPad(skipped, "a1_workbench")
	TycoonLogic.applyLevels(skipped, "p1_workbench", 4)
	check(TutorialLogic.evaluate(skipped, 0, 0) == 4, "level >= 2 implies clicked")
	-- R122 migration: a save from the OLD order (Uncle Atom was pad 7) that owns Garage Door ..
	-- Mini Reactor but never hired him stays on step 6 with the arrow on Uncle Atom (not on the
	-- Paint Station that is also on offer), and a finished-old-step-6 save never goes back.
	local old = TycoonLogic.newState()
	for _, id in { "a1_workbench", "a1_tool_wall", "a1_glow_lamp", "a1_garage_door", "a1_mini_reactor" } do
		old.pads[id] = true
	end
	old.producers.p1_workbench = 25
	check(TutorialLogic.evaluate(old, 50, 6) == 6, "old-order save without the manager: step 6")
	check(TutorialLogic.payload(6, old).target == "a1_uncle_atom", "old-order save: arrow on Uncle Atom")
	check(TutorialLogic.evaluate(old, 50, 0) == 6, "old-order save, no stored step: step 6")
	old.pads.a1_uncle_atom = true
	check(TutorialLogic.evaluate(old, 50, 6) == 7, "old-order save hires him -> step 7")
	check(TutorialLogic.payload(7, old).target == "a1_paint_station", "old-order save: chain resumes at its next pad")
	check(TutorialLogic.Steps[#TutorialLogic.Steps].pad == "a1_open_stand", "last step still opens the stand")
	check(#TutorialLogic.Steps == 7 and DONE == 8, "still 7 steps (tut:<n> keys and DoneStep keep their meaning)")
	for index, step in TutorialLogic.Steps do
		check(#step.text > 0 and #step.text <= 60, `step {index} text fits the chip`)
		if step.pad ~= nil then
			check(TycoonConfig.PadsById[step.pad] ~= nil, `step {index} pad exists`)
		end
		if step.producer ~= nil then
			check(TycoonConfig.ProducersById[step.producer] ~= nil, `step {index} producer exists`)
		end
	end
end

--------------------------------------------------------------------------------------------------
-- ModifierSources
--------------------------------------------------------------------------------------------------
do
	local player = {} :: any
	local profile = { rebirths = 1, rebirthShop = { clickPower = 2 } }
	local changed = 0
	ModifierSources.Changed:Connect(function()
		changed += 1
	end)
	ModifierSources.register("pets", function(_player, _profile)
		return { petCash = 0.5 }
	end)
	ModifierSources.register("boost", function(_player, _profile)
		return { boostCash = 2 }, 1_900_000_000
	end, { offline = false })
	ModifierSources.register("event", function(_player, _profile)
		return { eventCash = 1.5 }, 1_800_000_000
	end)
	local warnsBefore = #loader.warnings
	ModifierSources.register("broken", function()
		error("boom")
	end)
	ModifierSources.register("yielding", function()
		coroutine.yield()
		return { boostCash = 1000 }
	end)
	check(changed >= 5, "register fires Changed")

	local mods, validUntil = ModifierSources.build(player, profile)
	check(mods.petCash == 0.5 and mods.boostCash == 2 and mods.eventCash == 1.5, "providers merged")
	check(mods.rebirths == 1 and mods.rebirthShop.clickPower == 2, "rebirth data from the profile")
	check(validUntil == 1_800_000_000, "earliest validUntil")
	check(#loader.warnings >= warnsBefore + 2, "broken / yielding providers warned")
	local offline = ModifierSources.build(player, profile, true)
	check(offline.boostCash == 1 and offline.petCash == 0.5, "offline excludes offline=false sources")
	ModifierSources.build(player, profile)
	check(#loader.warnings == warnsBefore + 2, "each failing provider warns once")

	ModifierSources.register("pets", function()
		return { petCash = 0.1 }
	end)
	check(ModifierSources.build(player, profile).petCash == 0.1, "re-register replaces")
	ModifierSources.unregister("pets")
	check(ModifierSources.build(player, profile).petCash == 0, "unregister removes")
	local before = changed
	ModifierSources.invalidate(player)
	ModifierSources.invalidateAll()
	check(changed == before + 2, "invalidate fires Changed")
	check(not pcall(ModifierSources.register, "", function() end), "empty name rejected")
	local garbage = ModifierSources.build(player, "not a profile")
	check(garbage.rebirths == 0, "garbage profile -> no rebirths")
end

--------------------------------------------------------------------------------------------------
-- R57 worlds: per-world rebirth track + cross-world link (ModifierSources), world upgrade maths
--------------------------------------------------------------------------------------------------
do
	local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")
	local Modifiers = loader.load("src/shared/Tycoon/Modifiers")
	local player = {} :: any
	local profile = {
		rebirths = 5,
		rebirthShop = { clickPower = 2 },
		worlds = { dino = { rebirths = 3, rebirthShop = { managerSpeed = 1 } } },
	}
	-- Nuke Town: its own track, +10 % per Dino rebirth (3 -> x1.3).
	local main = ModifierSources.build(player, profile)
	check(main.rebirths == 5 and main.rebirthShop.clickPower == 2, "main track from the profile root")
	check(
		near(main.linkCash :: number, WorldsConfig.linkCash("main", { dino = 3 })),
		"main linkCash from Dino rebirths"
	)
	check(near(main.linkCash :: number, 1.3), "3 Dino rebirths = x1.3 Nuke Town cash")
	-- Dino: its own track, +5 % per Nuke Town rebirth (5 -> x1.25).
	local dino = ModifierSources.build(player, profile, nil, "dino")
	check(dino.rebirths == 3 and dino.rebirthShop.managerSpeed == 1, "dino track from profile.worlds.dino")
	check(dino.rebirthShop.clickPower == nil, "dino never sees the Nuke Town shop")
	check(near(dino.linkCash :: number, 1.25), "5 Nuke Town rebirths = x1.25 Bones")
	-- Caps (20 Dino rebirths -> x3, 10 Nuke Town rebirths -> x1.5), garbage counts as 0.
	local capped = { rebirths = 999, worlds = { dino = { rebirths = 999 } } }
	check(near(ModifierSources.build(player, capped).linkCash :: number, 3), "main link capped at x3")
	check(near(ModifierSources.build(player, capped, nil, "dino").linkCash :: number, 1.5), "dino link capped at x1.5")
	local garbage = { rebirths = NAN, worlds = { dino = { rebirths = -INF, rebirthShop = "junk" } } }
	local g1 = ModifierSources.build(player, garbage)
	local g2 = ModifierSources.build(player, garbage, nil, "dino")
	check(g1.linkCash == 1 and g2.linkCash == 1 and next(g2.rebirthShop) == nil, "garbage -> neutral link + empty shop")
	check(ModifierSources.build(player, { rebirths = 1 }, nil, "dino").rebirths == 0, "missing world -> no rebirths")
	local counts = ModifierSources.rebirthsByWorld(profile)
	check(counts.main == 5 and counts.dino == 3, "rebirthsByWorld")
	-- linkCash is applied by Modifiers.resolve (cash x link), monotonic.
	local plain = Modifiers.resolve({ rebirths = 0 })
	local linked = Modifiers.resolve({ rebirths = 0, linkCash = 1.3 })
	check(near(linked.cash, plain.cash * 1.3), "resolve multiplies cash by linkCash")
	check(TycoonRules.mergeModifiers({}, 0, {}, 0.5).linkCash == nil, "linkCash < 1 dropped")
	check(TycoonRules.mergeModifiers({}, 0, {}, NAN).linkCash == nil, "NaN linkCash dropped")
	check(TycoonRules.mergeModifiers({}, 0, {}, 2).linkCash == 2, "linkCash kept")
	check(TycoonRules.mergeModifiers({}, 0, {}).linkCash == nil, "no linkCash argument = none")

	-- upgradeCount with a world's logic: same maths as that world's Logic, from its wallet.
	local Dino = TycoonLogic.forWorld("dino")
	local bench = Dino.index.Areas[1].producer
	local count1, cost1 = TycoonRules.upgradeCount("1", bench, 1, 1e12, Dino)
	check(count1 == 1 and near(cost1, Dino.upgradeCost(bench, 1, 1)), "dino upgrade x1 priced by the dino logic")
	local countMax, costMax = TycoonRules.upgradeCount("max", bench, 1, 1e6, Dino)
	local wantCount, wantCost = Dino.maxAffordable(bench, 1, 1e6)
	check(countMax == wantCount and near(costMax, wantCost), "dino upgrade max = Dino.maxAffordable")
	check(select(1, TycoonRules.upgradeCount("10", bench, 1, 0, Dino)) == 0, "no Bones = nothing")
	check(
		select(1, TycoonRules.upgradeCount("1", bench, Dino.index.MaxLevel, 1e300, Dino)) == 0,
		"dino max level capped"
	)
end

--------------------------------------------------------------------------------------------------
-- Owner R64 (2026-10-31): an un-managed producer only runs when clicked. The AutoClicker pass is
-- the one exception, and only while its Settings toggle is ON (the creator's account owns every
-- pass, which is why the owner saw a fresh Workbench run by itself).
--------------------------------------------------------------------------------------------------
do
	-- autoClickerOn: only an owned pass clicks, and an explicit OFF wins.
	check(not TycoonRules.autoClickerOn(false, nil), "R64: no pass, no auto clicking")
	check(not TycoonRules.autoClickerOn(false, true), "R64: the toggle never grants the pass")
	check(TycoonRules.autoClickerOn(true, nil), "R64: pass + no stored toggle (old profile) = on")
	check(TycoonRules.autoClickerOn(true, true), "R64: pass + toggle ON = on")
	check(not TycoonRules.autoClickerOn(true, false), "R64: pass + toggle OFF = off")
	for _, bad in { 1, "true", {}, NAN } do
		check(not TycoonRules.autoClickerOn(bad, true), `R64: hostile ownership {tostring(bad)} = off`)
	end

	-- Owner R83: auto-clicked cycles credit "click" quest progress at a human-like rate.
	local credit, bank = TycoonRules.autoClickCredit(0, 0.2, 4, 10)
	check(credit == 0 and near(bank, 0.8), "R83: under one whole click credits nothing yet")
	credit, bank = TycoonRules.autoClickCredit(0.8, 0.2, 4, 10)
	check(credit == 1 and near(bank, 0.6), "R83: a whole click credits one")
	credit, bank = TycoonRules.autoClickCredit(0.8, 0.2, 4, 0)
	check(credit == 0 and near(bank, 1.6), "R83: the bank waits for a real auto cycle")
	credit, bank = TycoonRules.autoClickCredit(3.5, 60, 4, 1000)
	check(credit == 4 and near(bank, 0), "R83: idle time banks at most one second (no burst)")
	credit = TycoonRules.autoClickCredit(4, 0.2, 4, 2)
	check(credit == 2, "R83: never more credit than cycles the pass really finished")
	local total, b = 0, 0
	for _ = 1, 50 do -- 10 s of 0.2 s ticks with a fast chain
		local c
		c, b = TycoonRules.autoClickCredit(b, 0.2, 4, 20)
		total += c
	end
	check(total >= 38 and total <= 41, `R83: ~4 clicks per second over 10 s (got {total})`)
	for _, bad in { NAN, math.huge, -math.huge } do
		credit, bank = TycoonRules.autoClickCredit(bad, 0.2, 4, 10)
		check(credit == 0 and bank == 0, `R83: hostile bank {tostring(bad)} credits nothing`)
		credit, bank = TycoonRules.autoClickCredit(0, bad, 4, 10)
		check(credit == 0 and bank == 0, `R83: hostile elapsed {tostring(bad)} credits nothing`)
	end
	check(TycoonRules.autoClickCredit(0, 1, 0, 10) == 0, "R83: a zero rate credits nothing")
	check(TycoonRules.autoClickCredit(0, -5, 4, 10) == 0, "R83: negative elapsed accrues nothing")

	local CHAIN = 20
	-- Without the auto clicker: an idle producer stays idle forever (no time / level / purchase
	-- starts it), a clicked cycle pays exactly once when it finishes, then the producer is idle.
	local paid, running, start = TycoonRules.manualStep(false, 0, 1, 1e6, false, CHAIN)
	check(paid == 0 and not running and start == 0, "R64: an idle manual producer never starts itself")
	paid, running, start = TycoonRules.manualStep(true, 10, 1, 10.5, false, CHAIN)
	check(paid == 0 and running and start == 10, "R64: a clicked cycle in progress keeps running")
	paid, running, start = TycoonRules.manualStep(true, 10, 1, 11.2, false, CHAIN)
	check(paid == 1 and not running and start == 10, "R64: a finished click pays once, then idles")
	paid, running = TycoonRules.manualStep(running, start, 1, 500, false, CHAIN)
	check(paid == 0 and not running, "R64: after the payout it waits for the next click")
	paid, running = TycoonRules.manualStep(true, 0, 1, 1e6, false, CHAIN)
	check(paid == 1 and not running, "R64: a click long ago (offline / hitch) still pays only once")

	-- With the auto clicker: it starts an idle producer and chains whole cycles (bounded).
	paid, running, start = TycoonRules.manualStep(false, 0, 1, 50, true, CHAIN)
	check(paid == 0 and running and start == 50, "auto clicker starts an idle producer now")
	paid, running, start = TycoonRules.manualStep(true, 50, 1, 52.5, true, CHAIN)
	check(paid == 2 and running and start == 52, "auto clicker chains finished cycles")
	paid, running, start = TycoonRules.manualStep(true, 0, 0.1, 1000, true, CHAIN)
	check(paid == CHAIN and running and start == 1000, "auto clicker chain is capped; a hitch restarts from now")
	-- Turning the toggle OFF mid-chain: the running cycle still pays, then the producer idles.
	paid, running = TycoonRules.manualStep(true, 50, 1, 51.1, false, CHAIN)
	check(paid == 1 and not running, "toggle OFF: the current cycle pays, nothing chains")

	-- Hostile numbers never pay, never loop past the cap, never start a producer by themselves.
	for _, bad in { NAN, INF, -INF, 0, -1 } do
		paid, running = TycoonRules.manualStep(true, 0, bad, 100, false, CHAIN)
		check(paid == 0 and running, `hostile cycle {tostring(bad)} pays nothing`)
		paid, running = TycoonRules.manualStep(false, 0, bad, 100, false, CHAIN)
		check(paid == 0 and not running, `hostile cycle {tostring(bad)} never starts a producer`)
	end
	paid, running, start = TycoonRules.manualStep(true, 5, 1, NAN, true, CHAIN)
	check(paid == 0 and running and start == 5, "NaN clock changes nothing")
	paid, running = TycoonRules.manualStep(false, 5, 1, NAN, false, CHAIN)
	check(paid == 0 and not running, "NaN clock never starts a producer")
end

--------------------------------------------------------------------------------------------------
-- reachedAreas: admin grants (TycoonService.grantPads) announce opened areas like purchases
--------------------------------------------------------------------------------------------------
do
	local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")
	for _, worldId in WorldsConfig.Order do
		local def = WorldsConfig.get(worldId)
		local economy = def.economy
		local logic = TycoonLogic.forWorld(worldId)
		local areaCount = #economy.Areas
		-- Admin UnlockAll from a fresh state: every area 2..N exactly once, ascending, and it
		-- matches what one-by-one purchases would announce (each Unlock pad's `unlocks`).
		local state = logic.newState()
		local before = state.area
		local applied: { string } = {}
		local natural: { number } = {}
		for _, pad in economy.PadOrder do
			if logic.applyPad(state, pad.id) then
				table.insert(applied, pad.id)
				if pad.unlocks ~= nil then
					table.insert(natural, pad.unlocks)
				end
			end
		end
		local reached = TycoonRules.reachedAreas(economy.PadsById, applied, before)
		check(#reached == areaCount - 1, `{worldId}: unlock-all reaches every area once ({#reached})`)
		for index, area in reached do
			check(area == index + 1, `{worldId}: areas announced in order ({index} -> {area})`)
			check(natural[index] == area, `{worldId}: same areas as natural purchases`)
		end
		check(state.area == areaCount, `{worldId}: state ends in the last area`)
		-- SetArea 3 from a fresh state: areas 2 and 3 only.
		local partial = logic.newState()
		local partialBefore = partial.area
		local partialApplied: { string } = {}
		for _, pad in economy.PadOrder do
			if pad.area < 3 and logic.applyPad(partial, pad.id) then
				table.insert(partialApplied, pad.id)
			end
		end
		local partialReached = TycoonRules.reachedAreas(economy.PadsById, partialApplied, partialBefore)
		check(
			#partialReached == 2 and partialReached[1] == 2 and partialReached[2] == 3,
			`{worldId}: setArea 3 -> 2, 3`
		)
		-- A second jump never re-announces areas already reached: SetArea 3 then UnlockAll.
		local rest: { string } = {}
		local restBefore = partial.area
		for _, pad in economy.PadOrder do
			if logic.applyPad(partial, pad.id) then
				table.insert(rest, pad.id)
			end
		end
		local restReached = TycoonRules.reachedAreas(economy.PadsById, rest, restBefore)
		check(#restReached == areaCount - 3 and restReached[1] == 4, `{worldId}: later jump starts at area 4`)
		-- Areas at or below the area before are filtered even if their Unlock pad is in the batch.
		check(
			#TycoonRules.reachedAreas(economy.PadsById, applied, areaCount) == 0,
			`{worldId}: nothing above the last area`
		)
	end
	-- Hostile input: unknown ids, duplicates, garbage areaBefore.
	check(
		#TycoonRules.reachedAreas(TycoonConfig.PadsById, { "nope", "a1_workbench" }, 1) == 0,
		"no Unlock pads -> none"
	)
	local dup = TycoonRules.reachedAreas(TycoonConfig.PadsById, { "a1_open_stand", "a1_open_stand" }, 1)
	check(#dup == 1 and dup[1] == 2, "duplicate ids announce once")
	local nan = TycoonRules.reachedAreas(TycoonConfig.PadsById, { "a1_open_stand" }, NAN)
	check(#nan == 1 and nan[1] == 2, "NaN areaBefore counts as area 1")
end

print(`tycoon-server-logic: {checks} checks passed`)
