--!strict
--[[
	Unit tests for the pure tycoon economy: Shared/Tycoon/{TycoonLogic, Modifiers, SafeMath},
	Shared/Config/{TycoonConfig, RebirthConfig, TycoonAreas/*}.

	Covers every public TycoonLogic function with normal and hostile input (level 0 / negative /
	huge / NaN / inf / wrong types, unknown ids, cash NaN, max-affordable boundaries, offline cap,
	cycle floor conversion), the Modifiers maths, the config contracts world builders and the
	server rely on (spec pad lists, id chain, build keys, friendly prices, frozen config), and the
	kid-friendly INVARIANT: no pad, level or Rebirth-shop purchase ever lowers a producer's shown cash
	per cycle, its speed, or idle $/s (with and without rebirths, maxed shop and floor-hitting speed).

	Worlds (World 2 plan §4 W1.2): the last section runs the world-generic suite once per world in
	WorldsConfig.Order through TycoonLogic.forWorld(id) — config contracts, hostile input, the
	chain walk, rebirth maths on that world's own track, Modifiers per RebirthDef, and the
	monotonicity invariant incl. `linkCash` and that world's rebirth variants.

	Run: lune run tests/tycoon-logic.luau            (from the repo root)
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

--------------------------------------------------------------------------------------------------
-- Loader: real sources, a fake `script` so `script.Parent.X` requires resolve.
--------------------------------------------------------------------------------------------------

local function node(path: string): any
	return setmetatable({ path = path }, {
		__index = function(_, key)
			if key == "Parent" then
				return node(string.match(path, "^(.*)/[^/]+$") :: string)
			end
			return node(path .. "/" .. key)
		end,
	})
end

local cache: { [string]: any } = {}
local function load(path: string): any
	if cache[path] ~= nil then
		return cache[path]
	end
	local env = {
		script = node(path),
		require = function(ref: any)
			return load(ref.path)
		end,
		-- Roblox datatypes the world registry uses at load (currency colours, world origins).
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		Vector3 = roblox.Vector3,
	}
	local value = luau.load(fs.readFile(path .. ".luau"), { debugName = path, environment = env })()
	cache[path] = value
	return value
end

local TycoonConfig = load("src/shared/Config/TycoonConfig")
local RebirthConfig = load("src/shared/Config/RebirthConfig")
local TycoonLogic = load("src/shared/Tycoon/TycoonLogic")
local Modifiers = load("src/shared/Tycoon/Modifiers")
local SafeMath = load("src/shared/Tycoon/SafeMath")

local checks = 0
local function check(ok: boolean, message: string)
	assert(ok, message)
	checks += 1
end
local function near(a: number, b: number, relative: number?): boolean
	local tolerance = (relative or 1e-9) * math.max(1, math.abs(a), math.abs(b))
	return math.abs(a - b) <= tolerance
end
local function finite(x: number): boolean
	return x == x and x > -math.huge and x < math.huge
end

local NAN = 0 / 0
local INF = math.huge
local HOSTILE: { any } = { NAN, INF, -INF, -5, "12", true, {}, 1e308 }

local WORKBENCH = TycoonConfig.ProducersById.p1_workbench
local MAX_LEVEL = TycoonConfig.MaxLevel

-- A state owning exactly the given pads (and producers at the given levels).
local function stateWith(pads: { string }, producers: { [string]: number }?): any
	local state = TycoonLogic.newState()
	for _, id in pads do
		state.pads[id] = true
	end
	for id, level in producers or {} do
		state.producers[id] = level
	end
	return state
end

--------------------------------------------------------------------------------------------------
-- SafeMath
--------------------------------------------------------------------------------------------------
do
	check(SafeMath.isFinite(5) and not SafeMath.isFinite(NAN) and not SafeMath.isFinite(INF), "isFinite")
	check(not SafeMath.isFinite("5") and not SafeMath.isFinite(nil), "isFinite rejects non-numbers")
	check(SafeMath.num(NAN, 3) == 3 and SafeMath.num(-INF, 3) == 3 and SafeMath.num(2, 3) == 2, "num")
	check(SafeMath.clamp(-5, 0, 10, 0) == 0 and SafeMath.clamp(50, 0, 10, 0) == 10, "clamp bounds")
	check(SafeMath.clamp(NAN, 0, 10, 3) == 3, "clamp NaN -> default")
	check(SafeMath.int(7.9, 0, 5) == 5 and SafeMath.int(3.7, 0, 5) == 3, "int floors and clamps")
	check(SafeMath.int(INF, 0, 5) == 0 and SafeMath.int(NAN, 1, 5) == 1, "int non-finite -> lo")
	check(SafeMath.bonus(-3, 1e6) == 1 and SafeMath.bonus(0.5, 1e6) == 1, "bonus never below 1")
	check(SafeMath.bonus(1e9, 1e6) == 1e6 and SafeMath.bonus(2, 1e6) == 2, "bonus capped")
end

--------------------------------------------------------------------------------------------------
-- Config contracts (spec §3 pad lists, ids, chain, build keys, prices, freezing)
--------------------------------------------------------------------------------------------------
do
	check(#TycoonConfig.Areas == 10, "ten areas")
	local expectedNames = {
		"Garage Lab",
		"Nuke Stand",
		"BoomDash Delivery",
		"Glow Rock Mine",
		"Enrichment Lab",
		"Rocket Factory",
		"Launch Silos",
		"Nuke Megastore",
		"Space Port",
		"Mega Nuclear Facility",
	}
	local buildKeys: { [string]: boolean } = {}
	local previousUnlock: string? = nil
	for index, area in TycoonConfig.Areas do
		check(area.name == expectedNames[index], `area {index} name {area.name}`)
		check(#area.pads >= 8 and #area.pads <= 11, `area {index} has 8-11 pads ({#area.pads})`)
		check(area.producer.clickable == true, `area {index} producer is clickable`)
		check(area.pads[1].requires == previousUnlock, `area {index} first pad requires the previous Unlock`)
		check(area.producer.builtBy == area.pads[1].id, `area {index} producer built by its first pad`)
		local last = area.pads[#area.pads]
		check(last.kind == "Unlock", `area {index} ends with an Unlock pad`)
		previousUnlock = last.id
		local previousCost = -1
		for position, pad in area.pads do
			check(string.match(pad.id, "^a" .. index .. "_[a-z0-9_]+$") ~= nil, `pad id format {pad.id}`)
			check(string.match(pad.build, "^A%d+_%u%w*$") ~= nil, `build key format {pad.build}`)
			check(buildKeys[pad.build] == nil, `build key unique {pad.build}`)
			buildKeys[pad.build] = true
			check(#pad.blurb > 0 and #pad.blurb <= 40, `blurb fits a billboard: {pad.blurb}`)
			check(pad.cost >= previousCost, `prices rise along area {index}'s chain at {pad.id}`)
			previousCost = pad.cost
			-- Friendly price: at most 2 significant digits.
			if pad.cost >= 100 then
				local digits = pad.cost / 10 ^ (math.floor(math.log10(pad.cost)) - 1)
				check(near(digits, math.floor(digits + 0.5), 1e-9), `friendly price {pad.id} = {pad.cost}`)
			end
			if position > 1 then
				check(pad.requires == area.pads[position - 1].id, `chain {pad.id}`)
			end
		end
	end
	check(TycoonConfig.PadsById.a1_workbench.cost == 0, "Workbench is free (tutorial step 1)")
	check(TycoonConfig.PadsById.a1_workbench.requires == nil, "Workbench has no prerequisite")
	check(#TycoonConfig.PadOrder == 93, `93 pads in the chain ({#TycoonConfig.PadOrder})`)

	-- Spot-check spec §3 kinds and values.
	local function pad(id: string): any
		return assert(TycoonConfig.PadsById[id], "missing pad " .. id)
	end
	check(pad("a1_glow_lamp").kind == "Multiplier" and pad("a1_glow_lamp").value == 2, "Glow Lamp x2")
	check(pad("a1_mini_reactor").kind == "Speed" and pad("a1_mini_reactor").value == 2, "Mini Reactor x2 speed")
	check(pad("a1_paint_station").value == 3, "Paint Station x3")
	check(pad("a1_uncle_atom").kind == "Manager", "Uncle Atom is the Manager")
	check(pad("a1_open_stand").unlocks == 2, "Open the Nuke Stand unlocks area 2")
	check(pad("a2_neon_sign").value == 3 and pad("a2_neon_sign").feature == "StandRename", "Neon Sign x3 + rename")
	check(pad("a3_mobile_app").value == 4, "Mobile App x4")
	check(pad("a4_glow_vein").value == 4, "Glow Vein x4")
	check(pad("a7_aa_tower").kind == "Feature" and pad("a7_aa_tower").feature == "AATower", "AA Tower feature")
	check(pad("a7_attack_console").feature == "AttackConsole", "Attack Console feature")
	check(pad("a9_space_elevator").value == 4, "Space Elevator x4")
	check(pad("a10_fusion_core").value == 5, "Fusion Core x5")
	check(pad("a10_golden_atom").feature == "Rebirth" and TycoonConfig.FinalePadId == "a10_golden_atom", "finale")
	for _, producer in TycoonConfig.Producers do
		check(TycoonConfig.ManagerPadOf[producer.id] ~= nil, `{producer.id} has a Manager`)
	end

	-- friendlyPrice
	check(TycoonConfig.friendlyPrice(72913402) == 73000000, "friendlyPrice 2 digits")
	check(TycoonConfig.friendlyPrice(4) == 4 and TycoonConfig.friendlyPrice(0) == 0, "friendlyPrice small")
	check(TycoonConfig.friendlyPrice(13.59) == 14, "friendlyPrice rounds half up")

	-- Frozen config: no runtime mutation.
	check(not pcall(function()
		TycoonConfig.PadsById.a1_tool_wall.cost = 1
	end), "pad records are frozen")
	check(not pcall(function()
		TycoonConfig.PadsById.hack = {}
	end), "lookup tables are frozen")
	check(not pcall(function()
		RebirthConfig.Shop.clickPower.perLevel = 100
	end), "rebirth shop is frozen")
end

--------------------------------------------------------------------------------------------------
-- Milestones
--------------------------------------------------------------------------------------------------
do
	local function ms(level: any): (number, number)
		return TycoonLogic.milestoneMultipliers(level)
	end
	local c, s = ms(0)
	check(c == 1 and s == 1, "level 0: no milestones")
	c, s = ms(24)
	check(c == 1 and s == 1, "level 24: no milestones")
	c, s = ms(25)
	check(c == 2 and s == 1, "level 25: x2 cash")
	c, s = ms(50)
	check(c == 2 and s == 2, "level 50: x2 speed")
	c, s = ms(75)
	check(c == 4 and s == 2, "level 75: x4 cash")
	c, s = ms(100)
	check(c == 4 and s == 4, "level 100: x4 speed")
	c, s = ms(MAX_LEVEL)
	check(c == 2 ^ 20 and s == 2 ^ 20, "MaxLevel: 40 milestones")
	c, s = ms(1e12)
	check(c == 2 ^ 20 and s == 2 ^ 20, "huge level clamps to MaxLevel")

	local badge = TycoonLogic.milestoneBadge(77)
	check(badge.cash == 4 and badge.speed == 2 and badge.milestones == 3, "badge(77) multipliers")
	check(badge.nextAt == 100 and badge.nextKind == "Speed" and badge.text == "x4", "badge(77) next + text")
	local zero = TycoonLogic.milestoneBadge(0)
	check(zero.nextAt == 25 and zero.nextKind == "Cash" and zero.text == "x1", "badge(0)")
	local top = TycoonLogic.milestoneBadge(MAX_LEVEL)
	check(top.nextAt == nil and top.nextKind == nil, "badge at MaxLevel has no next milestone")
	for _, bad in HOSTILE do
		local b = TycoonLogic.milestoneBadge(bad)
		check(finite(b.cash) and b.cash >= 1, `badge hostile level {tostring(bad)}`)
	end
end

--------------------------------------------------------------------------------------------------
-- Output, cycle, click
--------------------------------------------------------------------------------------------------
do
	local base = WORKBENCH.baseRevenue
	check(TycoonLogic.producerOutput(WORKBENCH, 1, nil, nil) == base, "level 1 output = baseRevenue")
	check(TycoonLogic.producerOutput(WORKBENCH, 10, nil, nil) == 10 * base, "output linear in level")
	check(TycoonLogic.producerOutput(WORKBENCH, 25, nil, nil) == 50 * base, "level 25 x2 cash")
	check(TycoonLogic.producerOutput(WORKBENCH, 0, nil, nil) == 0, "level 0 -> 0")
	check(TycoonLogic.producerOutput(WORKBENCH, -3, nil, nil) == 0, "negative level -> 0")
	check(TycoonLogic.producerOutput(nil :: any, 5, nil, nil) == 0, "nil cfg -> 0")
	check(TycoonLogic.producerOutput({} :: any, 5, nil, nil) == 0, "garbage cfg -> 0")
	for _, bad in HOSTILE do
		local out = TycoonLogic.producerOutput(WORKBENCH, bad, nil, nil)
		check(finite(out) and out >= 0, `output hostile level {tostring(bad)}`)
	end

	-- Pads: Glow Lamp (x2) + Tool Wall (+10 %) -> x2.2; Mini Reactor halves the cycle.
	local padded = stateWith({ "a1_workbench", "a1_tool_wall", "a1_glow_lamp" }, { p1_workbench = 1 })
	check(near(TycoonLogic.producerOutput(WORKBENCH, 1, nil, padded), 2.2 * base), "pad cash x2.2")
	local padCash, padSpeed = TycoonLogic.padMultipliers(padded, "p1_workbench")
	check(near(padCash, 2.2) and padSpeed == 1, "padMultipliers")
	local fast = stateWith({ "a1_mini_reactor" })
	check(near(TycoonLogic.cycleTime(WORKBENCH, 1, nil, fast), WORKBENCH.baseCycle / 2), "Speed pad halves cycle")

	-- Cycle: milestones, floor conversion keeps $/s exact.
	check(TycoonLogic.cycleTime(WORKBENCH, 1, nil, nil) == WORKBENCH.baseCycle, "level 1 cycle = baseCycle")
	check(near(TycoonLogic.cycleTime(WORKBENCH, 50, nil, nil), WORKBENCH.baseCycle / 2), "level 50 halves cycle")
	check(TycoonLogic.cycleTime(WORKBENCH, 0, nil, nil) == WORKBENCH.baseCycle, "unbuilt cycle = level 1 cycle")
	local floor = TycoonConfig.CycleFloor
	-- baseCycle 1, x16 speed -> raw 0.0625 < 0.1 -> cycle clamps to 0.1, cash x (0.1 / 0.0625) = x1.6.
	local cycle16 = TycoonLogic.cycleTime(WORKBENCH, 1, { boostSpeed = 16 }, nil)
	local out16 = TycoonLogic.producerOutput(WORKBENCH, 1, { boostSpeed = 16 }, nil)
	check(cycle16 == floor and near(out16, 1.6 * base), "x16 speed clamps to the floor and pays x1.6")
	-- Once at the floor, every further x2 speed is exactly x2 cash.
	check(near(TycoonLogic.producerOutput(WORKBENCH, 1, { boostSpeed = 32 }, nil), 3.2 * base), "x32 -> x3.2")
	-- Exactly on the floor: no conversion.
	check(near(TycoonLogic.cycleTime(WORKBENCH, 1, { boostSpeed = 10 }, nil), floor), "exactly at floor")
	check(TycoonLogic.producerOutput(WORKBENCH, 1, { boostSpeed = 10 }, nil) == 1, "no conversion at floor")
	-- Top level: 2^20 speed -> cycle in [floor, 2 floor) and output/cycle equals the raw rate.
	local top = TycoonLogic.cycleTime(WORKBENCH, MAX_LEVEL, nil, nil)
	local topOut = TycoonLogic.producerOutput(WORKBENCH, MAX_LEVEL, nil, nil)
	local rawRate = base * MAX_LEVEL * 2 ^ 20 * 2 ^ 20 / WORKBENCH.baseCycle
	check(top == floor, `floored cycle {top}`)
	check(near(topOut / top, rawRate, 1e-9), "floor conversion preserves $/s exactly")
	for _, bad in HOSTILE do
		local cycle = TycoonLogic.cycleTime(WORKBENCH, bad, { boostSpeed = bad }, nil)
		check(finite(cycle) and cycle >= floor, `cycle hostile {tostring(bad)}`)
	end

	-- Manager speed applies to automated producers only; clicks never get it.
	local shopMods = { rebirthShop = { managerSpeed = 5, clickPower = 4 } }
	local managed = stateWith({ "a1_workbench", "a1_uncle_atom" }, { p1_workbench = 1 })
	local manual = stateWith({ "a1_workbench" }, { p1_workbench = 1 })
	check(near(TycoonLogic.cycleTime(WORKBENCH, 1, shopMods, managed), WORKBENCH.baseCycle / 1.5), "manager +50 %")
	check(TycoonLogic.cycleTime(WORKBENCH, 1, shopMods, manual) == WORKBENCH.baseCycle, "manual: no manager speed")
	check(
		TycoonLogic.clickCycleTime(WORKBENCH, 1, shopMods, managed) == WORKBENCH.baseCycle,
		"clicks: no manager speed"
	)
	local power4 = 1 + 4 * RebirthConfig.Shop.clickPower.perLevel
	check(near(TycoonLogic.clickValue(WORKBENCH, 1, shopMods, manual), base * power4), "Power Production x4 on clicks")
	check(TycoonLogic.clickValue(WORKBENCH, 1, nil, nil) == base, "click without shop = output")
	check(TycoonLogic.clickValue(WORKBENCH, 0, shopMods, manual) == 0, "unbuilt click -> 0")
	check(TycoonLogic.clickValue(nil :: any, 1, nil, nil) == 0, "nil cfg click -> 0")
end

--------------------------------------------------------------------------------------------------
-- Modifiers
--------------------------------------------------------------------------------------------------
do
	check(Modifiers.resolve(nil) == Modifiers.NEUTRAL and Modifiers.resolve("x").cash == 1, "neutral")
	local r = Modifiers.resolve({
		vip = true,
		cashPass = true,
		petCash = 0.35,
		boostCash = 2,
		serverCash = 2,
		eventCash = 1.5,
		rebirths = 1,
	})
	check(near(r.cash, 1.5 * 2 * 1.35 * 2 * 2 * 1.5 * 1.5), `cash product {r.cash}`)
	check(r.speed == 1 and r.managerSpeed == 1 and r.production == 1 and r.rebirth == 1.5, "other fields neutral")
	local powered = Modifiers.resolve({ rebirthShop = { clickPower = 4 } })
	local power4 = 1 + 4 * RebirthConfig.Shop.clickPower.perLevel
	check(near(powered.production, power4) and near(powered.cash, power4), "Power Production is part of cash")
	local hostile = Modifiers.resolve({
		vip = "yes",
		cashPass = 1,
		petCash = -5,
		boostCash = NAN,
		boostSpeed = -2,
		serverCash = INF,
		eventCash = 0,
		rebirths = -3,
		rebirthShop = { clickPower = INF, managerSpeed = -1 },
	})
	check(hostile.cash == 1 and hostile.speed == 1, "hostile modifiers -> neutral")
	check(hostile.production == 1 and hostile.managerSpeed == 1, "hostile shop -> neutral")
	local maxed = Modifiers.resolve({
		petCash = 1e300,
		boostCash = 1e300,
		serverCash = 1e300,
		eventCash = 1e300,
		boostSpeed = 1e300,
		rebirths = 1e300,
		cashPass = true,
		vip = true,
	})
	check(finite(maxed.cash) and finite(maxed.speed), "maxed modifiers stay finite")
	check(maxed.speed == TycoonConfig.Modifiers.MaxMultiplier, "speed capped")

	check(Modifiers.rebirthMultiplier(0, nil) == 1, "0 rebirths x1")
	check(Modifiers.rebirthMultiplier(1, nil) == 1.5, "1 rebirth x1.5")
	check(Modifiers.rebirthMultiplier(2, nil) == 2, "2 rebirths x2 (additive)")
	check(near(Modifiers.rebirthMultiplier(1, { rebirthPower = 2 }), 1.6), "rebirth power")
	check(Modifiers.rebirthMultiplier(NAN, nil) == 1 and Modifiers.rebirthMultiplier(-4, nil) == 1, "hostile rebirths")
	check(
		Modifiers.rebirthMultiplier(1e12, nil) == 1 + RebirthConfig.BonusPerRebirth * RebirthConfig.MaxRebirths,
		"rebirth count clamped"
	)
	check(TycoonLogic.rebirthMultiplier(1, nil) == 1.5, "TycoonLogic re-export")
	check(Modifiers.shopLevel({ clickPower = 99 }, "clickPower") == 10, "shop level clamped to max")
	check(Modifiers.shopLevel({ clickPower = 3 }, "nope") == 0 and Modifiers.shopLevel("x", "clickPower") == 0, "shop")
end

--------------------------------------------------------------------------------------------------
-- Upgrade costs and max-affordable
--------------------------------------------------------------------------------------------------
do
	local g = WORKBENCH.costGrowth
	check(TycoonLogic.upgradeCost(WORKBENCH, 1, 1) == WORKBENCH.baseCost, "level 1 -> 2 costs baseCost")
	check(TycoonLogic.upgradeCost(WORKBENCH, 5, 0) == 0, "count 0 costs 0")
	check(TycoonLogic.upgradeCost(WORKBENCH, 0, 1) == INF, "unbuilt cannot upgrade")
	check(TycoonLogic.upgradeCost(WORKBENCH, MAX_LEVEL, 1) == INF, "MaxLevel cannot upgrade")
	check(TycoonLogic.upgradeCost(WORKBENCH, MAX_LEVEL - 1, 1) < INF, "MaxLevel - 1 can")
	check(TycoonLogic.upgradeCost(WORKBENCH, MAX_LEVEL - 10, 20) == INF, "bulk past MaxLevel -> inf")
	check(TycoonLogic.upgradeCost(WORKBENCH, 1, 1e9) == INF, "absurd count -> inf (clamped then past cap)")
	check(
		TycoonLogic.upgradeCost(WORKBENCH, 3, NAN) == 0 and TycoonLogic.upgradeCost(WORKBENCH, 3, -4) == 0,
		"hostile n"
	)
	check(TycoonLogic.upgradeCost(nil :: any, 3, 1) == INF, "nil cfg -> inf")
	-- Closed form matches the iterative sum of single-level prices.
	for _, level in { 1, 7, 33, 120, 500 } do
		local sum = 0
		for i = 0, 9 do
			sum += WORKBENCH.baseCost * g ^ (level - 1 + i)
		end
		local bulk = TycoonLogic.upgradeCost(WORKBENCH, level, 10)
		check(bulk >= sum * (1 - 1e-9) and bulk <= math.ceil(sum) + 1, `closed form at level {level}`)
	end

	-- maxAffordable boundaries: exactly enough buys n; one less buys n - 1.
	for _, level in { 1, 12, 60, 300 } do
		for _, n in { 1, 5, 17 } do
			local cost = TycoonLogic.upgradeCost(WORKBENCH, level, n)
			local count, spent = TycoonLogic.maxAffordable(WORKBENCH, level, cost)
			check(count == n and spent == cost, `maxAffordable exact (L{level}, n{n}) -> {count}`)
			-- "One short" must be relative: above 2^53, cost - 1 == cost in doubles.
			local fewer = TycoonLogic.maxAffordable(WORKBENCH, level, cost - math.max(1, cost * 1e-9))
			check(fewer == n - 1, `maxAffordable one short (L{level}, n{n}) -> {fewer}`)
		end
	end
	-- Property sweep: n is the largest affordable count.
	local seed = 12345
	local function rand(): number
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	for _ = 1, 300 do
		local level = 1 + math.floor(rand() * 900)
		local cash = 10 ^ (rand() * 120)
		local n, spent = TycoonLogic.maxAffordable(WORKBENCH, level, cash)
		check(spent <= cash and finite(spent), "never spends more than it has")
		local room = math.min(MAX_LEVEL - level, TycoonConfig.MaxBulkLevels)
		check(n == room or TycoonLogic.upgradeCost(WORKBENCH, level, n + 1) > cash, "n is maximal")
	end
	check(select(1, TycoonLogic.maxAffordable(WORKBENCH, MAX_LEVEL - 1, 1e300)) == 1, "near MaxLevel buys 1")
	check(select(1, TycoonLogic.maxAffordable(WORKBENCH, MAX_LEVEL, 1e300)) == 0, "at MaxLevel buys 0")
	check(select(1, TycoonLogic.maxAffordable(WORKBENCH, 0, 1e300)) == 0, "unbuilt buys 0")
	for _, bad in HOSTILE do
		local n, spent = TycoonLogic.maxAffordable(WORKBENCH, 10, bad)
		if bad == 1e308 then
			check(n > 0 and finite(spent), "1e308 cash buys finitely")
		else
			check(n == 0 and spent == 0 or type(bad) ~= "number", `hostile cash {tostring(bad)}`)
		end
	end
	check(select(1, TycoonLogic.maxAffordable(WORKBENCH, 10, "1e9")) == 0, "string cash -> 0")
	check(select(1, TycoonLogic.maxAffordable(nil :: any, 10, 1e9)) == 0, "nil cfg -> 0")
end

--------------------------------------------------------------------------------------------------
-- Income, stats, offline
--------------------------------------------------------------------------------------------------
do
	check(TycoonLogic.incomePerSecond(TycoonLogic.newState(), nil) == 0, "new state earns nothing idle")
	local manual = stateWith({ "a1_workbench" }, { p1_workbench = 10 })
	check(TycoonLogic.incomePerSecond(manual, nil) == 0, "manual producers are not idle income")
	local auto = stateWith({ "a1_workbench", "a1_uncle_atom" }, { p1_workbench = 10 })
	local expected = TycoonLogic.producerOutput(WORKBENCH, 10, nil, auto)
		/ TycoonLogic.cycleTime(WORKBENCH, 10, nil, auto)
	check(near(TycoonLogic.incomePerSecond(auto, nil), expected), "automated income = output / cycle")
	check(near(TycoonLogic.incomePerSecond(auto, { vip = true }), expected * 1.5), "income uses mods")
	for _, bad in { nil, "x", 5, { pads = "x" }, { pads = {}, producers = "y" } } do
		check(TycoonLogic.incomePerSecond(bad :: any, nil) == 0, "garbage state -> 0")
	end
	for _, bad in HOSTILE do
		local s = stateWith({ "a1_workbench", "a1_uncle_atom" }, { p1_workbench = bad :: any })
		local income = TycoonLogic.incomePerSecond(s, nil)
		check(finite(income) and income >= 0, `hostile level income {tostring(bad)}`)
	end
	local weird = stateWith({ "a1_workbench", "a1_uncle_atom" })
	weird.pads.a1_glow_lamp = "yes" :: any -- only `true` counts as owned
	weird.producers.p1_workbench = 1
	check(
		near(TycoonLogic.incomePerSecond(weird, nil), WORKBENCH.baseRevenue / WORKBENCH.baseCycle),
		"pads[id]=true only"
	)

	-- producerStats
	check(TycoonLogic.producerStats(auto, "nope", nil) == nil, "producerStats unknown id -> nil")
	check(TycoonLogic.producerStats(auto, 5, nil) == nil, "producerStats non-string id -> nil")
	local stats = assert(TycoonLogic.producerStats(auto, "p1_workbench", nil))
	check(stats.built and stats.automated and stats.level == 10, "stats flags")
	check(near(stats.perSecond, expected) and stats.nextCost == TycoonLogic.upgradeCost(WORKBENCH, 10, 1), "stats")
	local manualStats = assert(TycoonLogic.producerStats(manual, "p1_workbench", { rebirthShop = { clickPower = 2 } }))
	check(manualStats.perSecond == 0 and manualStats.clickPayout == manualStats.output, "manual stats")
	local power2 = 1 + 2 * RebirthConfig.Shop.clickPower.perLevel
	check(near(manualStats.output, 10 * WORKBENCH.baseRevenue * power2), "Power Production on clicked cycles")
	local poweredAuto = assert(TycoonLogic.producerStats(auto, "p1_workbench", { rebirthShop = { clickPower = 2 } }))
	check(near(poweredAuto.output, manualStats.output), "Power Production on automated cycles too")
	local unbuilt = assert(TycoonLogic.producerStats(TycoonLogic.newState(), "p2_nuke_stand", nil))
	check(not unbuilt.built and unbuilt.output == 0 and unbuilt.nextCost == INF, "unbuilt stats")

	-- offlineLimits
	local cap, rate = TycoonLogic.offlineLimits({}, false)
	check(cap == 3 * 3600 and rate == 0.5, "base offline 3 h at 50 %")
	cap, rate = TycoonLogic.offlineLimits(nil, true)
	check(cap == 24 * 3600 and rate == 1, "Offline Max pass 24 h at 100 %")
	cap, rate = TycoonLogic.offlineLimits({ offlineHours = 14, offlineRate = 10 }, false)
	check(cap == 24 * 3600 and near(rate, 1), "maxed shop 24 h at 100 %")
	cap, rate = TycoonLogic.offlineLimits({ offlineHours = 5, offlineRate = 2 }, false)
	check(cap == 10.5 * 3600 and near(rate, 0.6), "partial shop")
	cap = TycoonLogic.offlineLimits({ offlineHours = 1e9 }, false)
	check(cap == 24 * 3600, "shop level clamped")

	-- offlineEarnings
	local perSecond = TycoonLogic.incomePerSecond(auto, nil)
	local amount, seconds = TycoonLogic.offlineEarnings(auto, nil, 7200, 10800, 0.5)
	check(near(amount, perSecond * 3600) and seconds == 7200, "2 h at 50 %")
	amount, seconds = TycoonLogic.offlineEarnings(auto, nil, 1e9, 10800, 0.5)
	check(seconds == 10800 and near(amount, perSecond * 5400), "capped at 3 h")
	amount, seconds = TycoonLogic.offlineEarnings(auto, nil, 30, 10800, 0.5)
	check(amount == 0 and seconds == 0, "under MinSeconds pays nothing")
	amount = TycoonLogic.offlineEarnings(auto, nil, 1e9, 1e12, 1)
	check(near(amount, perSecond * 24 * 3600), "cap clamped to MaxCapSeconds")
	amount = TycoonLogic.offlineEarnings(auto, nil, 7200, 10800, 5)
	check(near(amount, perSecond * 7200), "rate clamped to 100 %")
	for _, bad in HOSTILE do
		local a, s = TycoonLogic.offlineEarnings(auto, nil, bad, bad, bad)
		check(finite(a) and a >= 0 and finite(s) and s >= 0, `hostile offline {tostring(bad)}`)
	end
	check(select(1, TycoonLogic.offlineEarnings(manual, nil, 7200, 10800, 1)) == 0, "no managers, no offline")
end

--------------------------------------------------------------------------------------------------
-- Pads, areas, applying purchases
--------------------------------------------------------------------------------------------------
do
	local state = TycoonLogic.newState()
	local upcoming = TycoonLogic.nextPads(state)
	check(#upcoming == 1 and upcoming[1].id == "a1_workbench", "first pad is the Workbench")
	check(TycoonLogic.padAvailable(state, "a1_workbench") == true, "Workbench available")
	local ok, reason = TycoonLogic.padAvailable(state, "a1_tool_wall")
	check(not ok and reason == "locked", "Tool Wall locked")
	ok, reason = TycoonLogic.padAvailable(state, "a99_nope")
	check(not ok and reason == "unknown", "unknown pad")
	ok, reason = TycoonLogic.padAvailable(state, 42)
	check(not ok and reason == "unknown", "non-string pad id")
	check(not TycoonLogic.applyPad(state, "a1_tool_wall") and next(state.pads) == nil, "locked apply is a no-op")
	for _, bad in { nil, "x", { pads = "x", producers = {} }, { pads = {}, producers = 5 } } do
		check(not TycoonLogic.applyPad(bad :: any, "a1_workbench"), "malformed state is never written")
	end
	check(TycoonLogic.applyLevels({ pads = {}, producers = "x" } :: any, "p1_workbench", 3) == 0, "bad producers")

	check(TycoonLogic.applyPad(state, "a1_workbench"), "buy Workbench")
	check(state.producers.p1_workbench == 1, "Workbench builds the producer at level 1")
	ok, reason = TycoonLogic.padAvailable(state, "a1_workbench")
	check(not ok and reason == "owned", "owned pad")
	check(TycoonLogic.nextPads(state)[1].id == "a1_tool_wall", "next is Tool Wall")
	check(TycoonLogic.applyLevels(state, "p1_workbench", 9) == 10, "applyLevels adds")
	check(TycoonLogic.applyLevels(state, "p1_workbench", 1e9) == MAX_LEVEL, "applyLevels clamps to MaxLevel")
	check(TycoonLogic.applyLevels(state, "p1_workbench", NAN) == MAX_LEVEL, "applyLevels NaN adds 0")
	check(TycoonLogic.applyLevels(state, "p2_nuke_stand", 5) == 0, "unbuilt producer cannot level")
	check(TycoonLogic.applyLevels(state, "nope", 5) == 0, "unknown producer")
	state.producers.p1_workbench = 1

	check(TycoonLogic.areaUnlocked(state, 1) and not TycoonLogic.areaUnlocked(state, 2), "area 2 locked")
	check(not TycoonLogic.areaUnlocked(state, 0) and not TycoonLogic.areaUnlocked(state, 1.5), "bad area index")
	local bought, total = TycoonLogic.areaProgress(state, 1)
	check(bought == 1 and total == 9, "area 1 progress 1 / 9")
	for _, bad in { 0, 11, 1.5, "1", NAN } do
		local b, t = TycoonLogic.areaProgress(state, bad)
		check(b == 0 and t == 0, `areaProgress bad index {tostring(bad)}`)
	end
	check(not TycoonLogic.canRebirth(state) and TycoonLogic.rebirthReward(state, 0) == 0, "no rebirth yet")

	-- Walk the whole chain: every pad becomes available exactly once, in order.
	local steps = 1
	while true do
		local pads = TycoonLogic.nextPads(state)
		if #pads == 0 then
			break
		end
		check(#pads == 1, "the chain is linear")
		check(TycoonLogic.applyPad(state, pads[1].id), "apply " .. pads[1].id)
		steps += 1
		if pads[1].id == "a2_neon_sign" then
			check(TycoonLogic.hasFeature(state, "StandRename"), "Neon Sign unlocks renaming")
		end
	end
	check(steps == #TycoonConfig.PadOrder, "walked every pad")
	check(state.area == 10, "all areas unlocked")
	check(TycoonLogic.areaUnlocked(state, 10), "area 10 open")
	for _, producer in TycoonConfig.Producers do
		check(TycoonLogic.levelOf(state, producer.id) == 1, `{producer.id} built`)
		check(TycoonLogic.isAutomated(state, producer.id), `{producer.id} automated`)
	end
	check(TycoonLogic.hasFeature(state, "AATower") and TycoonLogic.hasFeature(state, "AttackConsole"), "features")
	check(not TycoonLogic.hasFeature(state, "Nope") and not TycoonLogic.hasFeature(state, 5), "unknown feature")
	bought, total = TycoonLogic.areaProgress(state, 7)
	check(bought == total and total == 10, "area 7 complete")

	-- Rebirth
	check(TycoonLogic.canRebirth(state), "finale unlocks rebirth")
	local tokens = RebirthConfig.Tokens
	check(TycoonLogic.totalLevels(state) == 10, "10 producers at level 1")
	check(TycoonLogic.rebirthReward(state, 0) == math.floor(tokens.Base + 10 / tokens.LevelsPerToken), "tokens")
	for _, producer in TycoonConfig.Producers do
		state.producers[producer.id] = 50
	end
	local base = tokens.Base + 500 / tokens.LevelsPerToken
	check(TycoonLogic.rebirthReward(state, 0) == math.floor(base), "tokens grow with levels")
	check(TycoonLogic.rebirthReward(state, 2) == math.floor(base * (1 + 2 * tokens.GrowthPerRebirth)), "later rebirths")
	check(TycoonLogic.rebirthReward(state, NAN) == math.floor(base), "hostile rebirth count")
end

--------------------------------------------------------------------------------------------------
-- The opening (owner R64 + R65, 2026-10-31): a brand-new player's Workbench is MANUAL until Uncle
-- Atom is hired, and its first upgrade costs exactly $10 (ten $1 clicks).
-- R64 regression: nothing in the economy automates a producer except its own Manager pad (the
-- AutoClicker pass is a server-side, per-player opt-in: TycoonRules.autoClickerOn, tested in
-- tests/tycoon-server-logic.luau).
--------------------------------------------------------------------------------------------------
do
	-- A fresh profile owns nothing; buying the free Workbench builds it at level 1, manual.
	local fresh = TycoonLogic.newState()
	check(next(fresh.pads) == nil and next(fresh.producers) == nil, "R64: a new state owns no pads / producers")
	check(not TycoonLogic.isAutomated(fresh, "p1_workbench"), "R64: nothing is automated before any purchase")
	check(TycoonLogic.applyPad(fresh, "a1_workbench"), "R64: buy the free Workbench")
	check(not TycoonLogic.isAutomated(fresh, "p1_workbench"), "R64: the Workbench starts MANUAL")
	local stats = assert(TycoonLogic.producerStats(fresh, "p1_workbench", nil))
	check(stats.built and not stats.automated, "R64: Workbench stats are manual")
	check(stats.perSecond == 0, "R64: a manual Workbench earns nothing per second by itself")
	check(TycoonLogic.incomePerSecond(fresh, nil) == 0, "R64: no idle income before Uncle Atom")
	local offline = TycoonLogic.offlineEarnings(fresh, nil, 3600, 3 * 3600, 1)
	check(offline == 0, "R64: no offline income before Uncle Atom")
	-- Every modifier a fresh player could have (passes, boosts, rebirths) still leaves it manual.
	local rich = {
		vip = true,
		cashPass = true,
		boostSpeed = 4,
		rebirths = 3,
		rebirthShop = { managerSpeed = 10, clickPower = 10 },
	}
	local richStats = assert(TycoonLogic.producerStats(fresh, "p1_workbench", rich :: any))
	check(not richStats.automated and richStats.perSecond == 0, "R64: modifiers never automate a producer")

	-- R65: the first upgrade costs exactly $10 = ten level-1 clicks; the curve keeps rising from there.
	check(WORKBENCH.baseCost == 10, "R65: Workbench baseCost is $10")
	check(TycoonLogic.upgradeCost(WORKBENCH, 1, 1) == 10, "R65: level 1 -> 2 costs exactly $10")
	check(stats.nextCost == 10, "R65: the billboard's UPGRADE pill shows $10")
	check(stats.clickPayout == 1 and stats.cycle == 1, "R65: a level-1 click pays $1 in a 1 s cycle")
	check(math.ceil(10 / stats.clickPayout) == 10, "R65: ten clicks buy the first upgrade")
	local opening = { 10, 12, 15, 18, 21 } -- the comment in Area01 promises exactly these
	for level, cost in opening do
		check(TycoonLogic.upgradeCost(WORKBENCH, level, 1) == cost, `R65: level {level} -> {level + 1} costs ${cost}`)
	end
	check(
		TycoonLogic.upgradeCost(WORKBENCH, 1, 2) == 22 and TycoonLogic.maxAffordable(WORKBENCH, 1, 22) == 2,
		"R65: x2 from level 1 costs $22"
	)
	local toolWall = TycoonConfig.PadsById.a1_tool_wall
	check(toolWall.cost > TycoonLogic.upgradeCost(WORKBENCH, 1, 1), "R65: the first pad costs more than an upgrade")

	-- Walk the whole Nuke Town chain: a producer becomes automated exactly when ITS Manager pad is
	-- bought, never by any other pad (no pad pre-grants a manager).
	local state = TycoonLogic.newState()
	for _, pad in TycoonConfig.PadOrder do
		local before: { [string]: boolean } = {}
		for _, producer in TycoonConfig.Producers do
			before[producer.id] = TycoonLogic.isAutomated(state, producer.id)
		end
		check(TycoonLogic.applyPad(state, pad.id), `R64 chain: apply {pad.id}`)
		for _, producer in TycoonConfig.Producers do
			local now = TycoonLogic.isAutomated(state, producer.id)
			if now ~= before[producer.id] then
				check(
					pad.kind == "Manager"
						and pad.target == producer.id
						and TycoonConfig.ManagerPadOf[producer.id] == pad.id,
					`R64 chain: only {producer.id}'s Manager automates it (not {pad.id})`
				)
			end
			if TycoonConfig.ProducerBuiltBy[pad.id] == producer.id then
				check(not now, `R64 chain: {producer.id} is manual when built`)
			end
		end
	end
end

--------------------------------------------------------------------------------------------------
-- Rebirth shop
--------------------------------------------------------------------------------------------------
do
	check(TycoonLogic.rebirthShopCost("clickPower", 0) == RebirthConfig.Shop.clickPower.baseCost, "first level cost")
	local clickPower = RebirthConfig.Shop.clickPower
	check(
		TycoonLogic.rebirthShopCost("clickPower", 3) == math.ceil(clickPower.baseCost * clickPower.costGrowth ^ 3),
		"cost growth"
	)
	check(TycoonLogic.rebirthShopCost("clickPower", clickPower.maxLevel) == INF, "max level -> inf")
	check(TycoonLogic.rebirthShopCost("nope", 0) == INF and TycoonLogic.rebirthShopCost(nil, 0) == INF, "unknown key")
	check(TycoonLogic.rebirthShopCost("clickPower", NAN) == clickPower.baseCost, "hostile level -> 0")
	check(TycoonLogic.rebirthShopEffect("petSlots", 2) == 2, "two extra pet slots")
	check(TycoonLogic.rebirthShopEffect("petSlots", 9) == 2, "pet slot level clamped to max")
	check(near(TycoonLogic.rebirthShopEffect("offlineRate", 4), 0.2), "offline rate effect")
	check(TycoonLogic.rebirthShopEffect("startingCash", 1) == 1e3, "starting cash level 1")
	check(TycoonLogic.rebirthShopEffect(5, 1) == 0, "non-string key")
	check(TycoonLogic.startingCash({}) == 0 and TycoonLogic.startingCash({ startingCash = 1 }) == 1e3, "startingCash")
	check(TycoonLogic.startingCash({ startingCash = "x" }) == 0 and TycoonLogic.startingCash(nil) == 0, "hostile")
	for _, key in RebirthConfig.ShopOrder do
		check(RebirthConfig.Shop[key] ~= nil, `ShopOrder key {key} exists`)
	end
end

--------------------------------------------------------------------------------------------------
-- INVARIANT (owner rule, kid-friendly): no purchase ever lowers a number the player sees.
-- For every producer: shown cash per cycle (clicked payout before its Manager, automated output
-- after) never drops and its cycle never gets longer; the plot's idle $/s never drops. Checked for
-- every pad in config order, every producer level 1..MaxLevel, and every Rebirth-shop level, with
-- no bonuses, with rebirths, with every shop item maxed, and with floor-hitting speed boosts.
--------------------------------------------------------------------------------------------------
do
	local maxedShop: { [string]: number } = {}
	for key, upgrade in RebirthConfig.Shop do
		maxedShop[key] = upgrade.maxLevel
	end
	local variants: { { name: string, mods: any } } = {
		{ name = "no bonuses", mods = nil },
		{ name = "3 rebirths", mods = { rebirths = 3 } },
		{ name = "3 rebirths + maxed shop", mods = { rebirths = 3, rebirthShop = maxedShop } },
		{
			name = "maxed shop + floor-hitting boosts",
			mods = {
				rebirths = 3,
				rebirthShop = maxedShop,
				boostSpeed = 64,
				boostCash = 2,
				vip = true,
				cashPass = true,
				petCash = 0.5,
			},
		},
	}
	local SLACK = 1e-12 -- relative float slack (products of the same factors in a different order)

	-- What the billboard shows for one producer: cash per cycle and cycle seconds.
	local function shown(state: any, mods: any, producer: any): (number, number)
		local level = TycoonLogic.levelOf(state, producer.id)
		if level < 1 then
			return 0, INF
		end
		if TycoonLogic.isAutomated(state, producer.id) then
			return TycoonLogic.producerOutput(producer, level, mods, state),
				TycoonLogic.cycleTime(producer, level, mods, state)
		end
		return TycoonLogic.clickValue(producer, level, mods, state),
			TycoonLogic.clickCycleTime(producer, level, mods, state)
	end

	type Snapshot = { income: number, output: { [string]: number }, cycle: { [string]: number } }
	local function snapshot(state: any, mods: any): Snapshot
		local snap: Snapshot = { income = TycoonLogic.incomePerSecond(state, mods), output = {}, cycle = {} }
		for _, producer in TycoonConfig.Producers do
			snap.output[producer.id], snap.cycle[producer.id] = shown(state, mods, producer)
		end
		return snap
	end

	-- First violation between two snapshots, or nil.
	local function regression(before: Snapshot, after: Snapshot): string?
		if after.income < before.income * (1 - SLACK) then
			return `idle $/s {before.income} -> {after.income}`
		end
		for id, output in before.output do
			if after.output[id] < output * (1 - SLACK) then
				return `{id} cash per cycle {output} -> {after.output[id]}`
			end
			if after.cycle[id] > before.cycle[id] * (1 + SLACK) then
				return `{id} cycle {before.cycle[id]} -> {after.cycle[id]} s`
			end
		end
		return nil
	end

	for _, variant in variants do
		-- 1. Every pad in config order, producers at the level a pad builds them at (1) and levelled
		--    deep into milestones (400: speed milestones push every cycle onto the 0.1 s floor).
		for _, buildLevel in { 1, 400 } do
			local state = TycoonLogic.newState()
			for _, pad in TycoonConfig.PadOrder do
				local before = snapshot(state, variant.mods)
				check(TycoonLogic.applyPad(state, pad.id), `walk {pad.id}`)
				local built = TycoonConfig.ProducerBuiltBy[pad.id]
				if built then
					state.producers[built] = buildLevel
				end
				local problem = regression(before, snapshot(state, variant.mods))
				check(problem == nil, `[{variant.name}, lv {buildLevel}] buying {pad.id} lowered {problem}`)
			end
		end

		-- 2. Every level 1 -> MaxLevel of every producer, before its Manager and after.
		for _, managed in { false, true } do
			local state = TycoonLogic.newState()
			for _, pad in TycoonConfig.PadOrder do
				if managed or pad.kind ~= "Manager" then
					state.pads[pad.id] = true
				end
			end
			for _, producer in TycoonConfig.Producers do
				state.producers[producer.id] = 1
			end
			for _, producer in TycoonConfig.Producers do
				local problem: string? = nil
				local beforeOut, beforeCycle = shown(state, variant.mods, producer)
				local beforeIncome = TycoonLogic.incomePerSecond(state, variant.mods)
				for level = 2, MAX_LEVEL do
					state.producers[producer.id] = level
					local out, cycle = shown(state, variant.mods, producer)
					local income = TycoonLogic.incomePerSecond(state, variant.mods)
					if out < beforeOut * (1 - SLACK) or cycle > beforeCycle * (1 + SLACK) then
						problem = `level {level}: cash/cycle {beforeOut} -> {out}, cycle {beforeCycle} -> {cycle}`
						break
					end
					if income < beforeIncome * (1 - SLACK) then
						problem = `level {level}: idle $/s {beforeIncome} -> {income}`
						break
					end
					beforeOut, beforeCycle, beforeIncome = out, cycle, income
				end
				state.producers[producer.id] = 1
				local mode = if managed then "managed" else "manual"
				check(problem == nil, `[{variant.name}, {mode}] levelling {producer.id} lowered {problem}`)
			end
		end
	end

	-- 3. Every Rebirth-shop level (one item at a time, on a full plot levelled onto the floor).
	for _, managed in { false, true } do
		local state = TycoonLogic.newState()
		for _, pad in TycoonConfig.PadOrder do
			if managed or pad.kind ~= "Manager" then
				state.pads[pad.id] = true
			end
		end
		for _, producer in TycoonConfig.Producers do
			state.producers[producer.id] = 400
		end
		for key, upgrade in RebirthConfig.Shop do
			local shop: { [string]: number } = {}
			for level = 1, upgrade.maxLevel do
				local before = snapshot(state, { rebirths = 2, rebirthShop = table.clone(shop) })
				shop[key] = level
				local problem = regression(before, snapshot(state, { rebirths = 2, rebirthShop = shop }))
				check(problem == nil, `shop {key} level {level} lowered {problem}`)
			end
		end
	end
end

--------------------------------------------------------------------------------------------------
-- Worlds: TycoonLogic.bind / forWorld, the same suite for every world, linkCash, per-world rebirth
--------------------------------------------------------------------------------------------------
local WorldsConfig = load("src/shared/Config/Worlds/WorldsConfig")

do
	-- forWorld("main") IS the module-level API; other worlds are cached Logic tables.
	local Main = TycoonLogic.forWorld("main")
	check(Main.worldId == "main" and Main.index == TycoonConfig.Index, "main Logic binds TycoonConfig.Index")
	check(Main.rebirth == RebirthConfig, "main Logic binds RebirthConfig")
	for key, value in Main do
		check(TycoonLogic[key] == value, `module-level TycoonLogic.{key} is main's`)
	end
	for _, worldId in WorldsConfig.Order do
		local logic = TycoonLogic.forWorld(worldId)
		check(TycoonLogic.forWorld(worldId) == logic, `forWorld({worldId}) is cached`)
		check(logic.worldId == worldId and logic.index == WorldsConfig.get(worldId).economy, `{worldId} Logic index`)
		check(table.isfrozen(logic), `{worldId} Logic is frozen`)
	end
	check(not pcall(TycoonLogic.forWorld, "nope"), "forWorld unknown id errors")
	check(not pcall(TycoonLogic.forWorld, 5 :: any), "forWorld non-string errors")
	-- A Logic bound twice is a separate, equivalent table (bind is pure).
	local dinoDef = WorldsConfig.get("dino")
	local rebound = TycoonLogic.bind(dinoDef.economy, dinoDef.rebirth)
	check(rebound ~= TycoonLogic.forWorld("dino") and rebound.worldId == "dino", "bind builds a fresh Logic")
end

--[[
	The world-generic suite: everything that must hold for ANY world's economy + rebirth track.
	@param worldId string
]]
local function worldSuite(worldId: string)
	local def = WorldsConfig.get(worldId)
	local L = TycoonLogic.forWorld(worldId)
	local C = def.economy
	local R = def.rebirth
	local tag = `[{worldId}]`

	-- Config contracts.
	check(#C.Areas == def.geometry.areaCount, `{tag} one area per slot`)
	local previousUnlock: string? = nil
	for index, area in C.Areas do
		check(area.index == index and area.producer.clickable == true, `{tag} area {index} shape`)
		check(area.pads[1].requires == previousUnlock, `{tag} area {index} chains from the previous Unlock`)
		check(area.pads[#area.pads].kind == "Unlock", `{tag} area {index} ends with an Unlock pad`)
		previousUnlock = area.pads[#area.pads].id
		local previousCost = -1
		for _, pad in area.pads do
			check(#pad.blurb > 0 and #pad.blurb <= 40, `{tag} blurb fits a billboard: {pad.blurb}`)
			check(pad.cost >= previousCost, `{tag} prices rise at {pad.id}`)
			previousCost = pad.cost
			if pad.cost >= 100 then
				local digits = pad.cost / 10 ^ (math.floor(math.log10(pad.cost)) - 1)
				check(near(digits, math.floor(digits + 0.5), 1e-9), `{tag} friendly price {pad.id} = {pad.cost}`)
			end
		end
	end
	check(C.PadOrder[1].cost == 0 and C.PadOrder[1].requires == nil, `{tag} the first pad is free`)
	check(C.FeaturePadOf.Rebirth == C.FinalePadId, `{tag} the finale unlocks Rebirth`)
	check(not pcall(function()
		(C.PadOrder[2] :: any).cost = 1
	end), `{tag} pad records are frozen`)
	check(not pcall(function()
		(C.PadsById :: any).hack = {}
	end), `{tag} lookups are frozen`)

	-- Hostile input on the bound functions.
	local first = C.Producers[1]
	check(
		L.levelOf(nil, first.id) == 0 and L.levelOf({ producers = { [first.id] = NAN } }, first.id) == 0,
		`{tag} levelOf`
	)
	for _, bad in HOSTILE do
		local out = L.producerOutput(first, bad, { linkCash = bad }, nil)
		check(finite(out) and out >= 0, `{tag} output hostile {tostring(bad)}`)
		check(L.cycleTime(first, bad, nil, nil) >= C.CycleFloor, `{tag} cycle hostile {tostring(bad)}`)
		local n, cost = L.maxAffordable(first, 1, bad)
		check(n >= 0 and finite(cost), `{tag} maxAffordable hostile {tostring(bad)}`)
	end
	check(L.producerStats(L.newState(), "p1_workbench_nope", nil) == nil, `{tag} stats unknown id`)
	check(L.padAvailable(L.newState(), "nope") == false, `{tag} unknown pad unavailable`)
	check(select(2, L.padAvailable(L.newState(), C.PadOrder[2].id)) == "locked", `{tag} locked pad`)

	-- Walk the whole chain: every pad is the single next pad, areas open in order, finale -> rebirth.
	local state = L.newState()
	for position, pad in C.PadOrder do
		check(L.nextPads(state)[1] == pad, `{tag} next pad #{position} is {pad.id}`)
		check(L.padAvailable(state, pad.id), `{tag} {pad.id} available in order`)
		check(L.applyPad(state, pad.id), `{tag} apply {pad.id}`)
		check(not L.padAvailable(state, pad.id), `{tag} {pad.id} owned`)
		if pad.kind == "Unlock" and pad.unlocks then
			check(L.areaUnlocked(state, pad.unlocks) and state.area == pad.unlocks, `{tag} {pad.id} opens area`)
		end
	end
	check(#L.nextPads(state) == 0 and L.canRebirth(state) and L.hasFeature(state, "Rebirth"), `{tag} finale`)
	for _, area in C.Areas do
		local bought, total = L.areaProgress(state, area.index)
		check(bought == total and total == #area.pads, `{tag} area {area.index} complete`)
		check(L.levelOf(state, area.producer.id) == 1 and L.isAutomated(state, area.producer.id), `{tag} built`)
	end
	check(L.areaProgress(state, #C.Areas + 1) == 0 and not L.areaUnlocked(state, #C.Areas + 1), `{tag} no extra area`)
	for _, producer in C.Producers do
		check(L.applyLevels(state, producer.id, 24) == 25, `{tag} level {producer.id}`)
	end

	-- Rebirth maths on the world's OWN track.
	local levels = L.totalLevels(state)
	check(levels == 25 * #C.Producers, `{tag} total levels`)
	local tokens = R.Tokens
	check(
		L.rebirthReward(state, 2)
			== math.floor((tokens.Base + levels / tokens.LevelsPerToken) * (1 + tokens.GrowthPerRebirth * 2)),
		`{tag} rebirth reward formula`
	)
	check(L.rebirthReward(L.newState(), 0) == 0, `{tag} no reward before the finale`)
	check(L.rebirthMultiplier(2, nil) == 1 + R.BonusPerRebirth * 2, `{tag} rebirth multiplier`)
	check(
		near(
			L.rebirthMultiplier(1, { rebirthPower = 2 }),
			1 + R.BonusPerRebirth + 2 * (R.Shop.rebirthPower.perLevel :: number)
		),
		`{tag} rebirth power`
	)
	for key, upgrade in R.Shop do
		check(L.rebirthShopCost(key, 0) == math.ceil(upgrade.baseCost * (1 - 1e-12)), `{tag} {key} first cost`)
		check(L.rebirthShopCost(key, upgrade.maxLevel) == INF, `{tag} {key} maxed`)
		check(
			L.rebirthShopEffect(key, upgrade.maxLevel + 5) == L.rebirthShopEffect(key, upgrade.maxLevel),
			`{tag} {key} clamp`
		)
	end
	check(L.rebirthShopCost("nope", 0) == INF and L.rebirthShopEffect("nope", 3) == 0, `{tag} unknown shop key`)
	local stash = R.Shop.startingCash
	check(L.startingCash({ startingCash = 1 }) == (stash.values :: { number })[1], `{tag} starting cash level 1`)
	check(L.startingCash({ startingCash = "x" }) == 0 and L.startingCash(nil) == 0, `{tag} hostile starting cash`)
	-- Offline limits are player-level (Nuke Town's shop keys) on every world.
	local shopLevels = { offlineHours = 5, offlineRate = 2 }
	local capA, rateA = L.offlineLimits(shopLevels, false)
	local capB, rateB = TycoonLogic.offlineLimits(shopLevels, false)
	check(capA == capB and rateA == rateB, `{tag} offline limits are player-level`)

	-- Modifiers resolve against the world's RebirthDef.
	local resolved = Modifiers.resolve({ rebirths = 2, rebirthShop = { clickPower = 3, managerSpeed = 2 } }, R)
	check(near(resolved.rebirth, 1 + R.BonusPerRebirth * 2), `{tag} resolved rebirth share`)
	check(near(resolved.production, 1 + 3 * (R.Shop.clickPower.perLevel :: number)), `{tag} resolved production`)
	check(near(resolved.managerSpeed, 1 + 2 * (R.Shop.managerSpeed.perLevel :: number)), `{tag} resolved manager speed`)
	check(near(resolved.cash, resolved.rebirth * resolved.production) and resolved.link == 1, `{tag} resolved cash`)

	-- linkCash: an exact cash factor on every cycle, sanitised like every other bonus.
	local built = L.newState()
	for _, pad in C.PadOrder do
		L.applyPad(built, pad.id)
	end
	local base = L.incomePerSecond(built, nil)
	check(base > 0, `{tag} built plot earns`)
	check(near(L.incomePerSecond(built, { linkCash = 1.25 }), base * 1.25), `{tag} linkCash x1.25`)
	check(near(L.incomePerSecond(built, { linkCash = 3 }), base * 3), `{tag} linkCash x3`)
	for _, bad in { NAN, INF, -INF, -2, 0, 0.5, "2", true } do
		check(L.incomePerSecond(built, { linkCash = bad }) == base, `{tag} linkCash hostile {tostring(bad)} is neutral`)
	end
	check(
		Modifiers.resolve({ linkCash = 1e300 }).link == TycoonConfig.Modifiers.MaxMultiplier,
		`{tag} linkCash capped at MaxMultiplier`
	)

	-- INVARIANT on this world: no purchase lowers a number the player sees (incl. link + this
	-- world's rebirth variants).
	local maxedShop: { [string]: number } = {}
	for key, upgrade in R.Shop do
		maxedShop[key] = upgrade.maxLevel
	end
	local variants: { { name: string, mods: any } } = {
		{ name = "no bonuses", mods = nil },
		{ name = "link x1.25", mods = { linkCash = 1.25 } },
		{ name = "2 rebirths + maxed shop + link x3", mods = { rebirths = 2, rebirthShop = maxedShop, linkCash = 3 } },
		{
			name = "everything + floor-hitting boosts",
			mods = {
				rebirths = 3,
				rebirthShop = maxedShop,
				linkCash = 1.5,
				boostSpeed = 64,
				boostCash = 2,
				vip = true,
				cashPass = true,
				petCash = 0.5,
			},
		},
	}
	local SLACK = 1e-12
	local function shown(st: any, mods: any, producer: any): (number, number)
		local level = L.levelOf(st, producer.id)
		if level < 1 then
			return 0, INF
		end
		if L.isAutomated(st, producer.id) then
			return L.producerOutput(producer, level, mods, st), L.cycleTime(producer, level, mods, st)
		end
		return L.clickValue(producer, level, mods, st), L.clickCycleTime(producer, level, mods, st)
	end
	local function snapshot(st: any, mods: any): any
		local snap = { income = L.incomePerSecond(st, mods), output = {}, cycle = {} }
		for _, producer in C.Producers do
			snap.output[producer.id], snap.cycle[producer.id] = shown(st, mods, producer)
		end
		return snap
	end
	local function regression(before: any, after: any): string?
		if after.income < before.income * (1 - SLACK) then
			return `idle {before.income} -> {after.income}`
		end
		for id, output in before.output do
			if after.output[id] < output * (1 - SLACK) then
				return `{id} per cycle {output} -> {after.output[id]}`
			end
			if after.cycle[id] > before.cycle[id] * (1 + SLACK) then
				return `{id} cycle {before.cycle[id]} -> {after.cycle[id]}`
			end
		end
		return nil
	end
	for _, variant in variants do
		for _, buildLevel in { 1, 400 } do
			local st = L.newState()
			for _, pad in C.PadOrder do
				local before = snapshot(st, variant.mods)
				L.applyPad(st, pad.id)
				local producerId = C.ProducerBuiltBy[pad.id]
				if producerId then
					st.producers[producerId] = buildLevel
				end
				local problem = regression(before, snapshot(st, variant.mods))
				check(problem == nil, `{tag}[{variant.name}, lv {buildLevel}] buying {pad.id} lowered {problem}`)
			end
		end
		for _, managed in { false, true } do
			local st = L.newState()
			for _, pad in C.PadOrder do
				if managed or pad.kind ~= "Manager" then
					st.pads[pad.id] = true
				end
			end
			for _, producer in C.Producers do
				st.producers[producer.id] = 1
			end
			for _, producer in C.Producers do
				local problem: string? = nil
				local beforeOut, beforeCycle = shown(st, variant.mods, producer)
				local beforeIncome = L.incomePerSecond(st, variant.mods)
				for level = 2, C.MaxLevel do
					st.producers[producer.id] = level
					local out, cycle = shown(st, variant.mods, producer)
					local income = L.incomePerSecond(st, variant.mods)
					if
						out < beforeOut * (1 - SLACK)
						or cycle > beforeCycle * (1 + SLACK)
						or income < beforeIncome * (1 - SLACK)
					then
						problem = `level {level}`
						break
					end
					beforeOut, beforeCycle, beforeIncome = out, cycle, income
				end
				st.producers[producer.id] = 1
				check(problem == nil, `{tag}[{variant.name}] levelling {producer.id} lowered at {problem}`)
			end
		end
	end
	-- Every shop level of this world's track, and the link rising, on a full plot on the floor.
	local full = L.newState()
	for _, pad in C.PadOrder do
		full.pads[pad.id] = true
	end
	for _, producer in C.Producers do
		full.producers[producer.id] = 400
	end
	for key, upgrade in R.Shop do
		local shop: { [string]: number } = {}
		for level = 1, upgrade.maxLevel do
			local before = snapshot(full, { rebirths = 2, rebirthShop = table.clone(shop), linkCash = 1.2 })
			shop[key] = level
			local problem = regression(before, snapshot(full, { rebirths = 2, rebirthShop = shop, linkCash = 1.2 }))
			check(problem == nil, `{tag} shop {key} level {level} lowered {problem}`)
		end
	end
	local previous = snapshot(full, { rebirths = 1 })
	for rebirths = 1, 25 do
		local link = WorldsConfig.linkCash(worldId, { main = rebirths, dino = rebirths })
		local now = snapshot(full, { rebirths = 1, linkCash = link })
		local problem = regression(previous, now)
		check(problem == nil, `{tag} link at {rebirths} rebirths lowered {problem}`)
		previous = now
	end
end

for _, worldId in WorldsConfig.Order do
	worldSuite(worldId)
end

-- Dino rebirth specifics (spec §6.4): +50 % Bones per Dino rebirth, Golden Amber +5 %, the Amber
-- shop has no player-level keys (offline stays Nuke Town's), the two tracks never mix.
do
	local Dino = TycoonLogic.forWorld("dino")
	local DinoRebirth = WorldsConfig.get("dino").rebirth
	check(Dino.rebirthMultiplier(1, nil) == 1.5 and Dino.rebirthMultiplier(2, nil) == 2, "Dino +50 % per rebirth")
	check(near(Dino.rebirthMultiplier(2, { rebirthPower = 2 }), 1 + (0.5 + 0.1) * 2), "Golden Amber")
	check(Modifiers.shopEffect("offlineHours", 5, DinoRebirth) == 0, "no offline keys in the Amber shop")
	check(Modifiers.shopLevel({ petSlots = 2 }, "petSlots", DinoRebirth) == 0, "no pet slots in the Amber shop")
	check(Modifiers.shopLevel({ startingCash = 9 }, "startingCash", DinoRebirth) == 4, "Bone Stash max 4")
	check(Modifiers.shopLevel({ startingCash = 9 }, "startingCash") == 5, "Head Start max 5 (main default)")
	check(
		near(Modifiers.rebirthMultiplier(3, { rebirthPower = 1 }, DinoRebirth), 1 + 0.55 * 3),
		"Modifiers.rebirthMultiplier per def"
	)
	check(Dino.rebirthShopCost("clickPower", 0) == 3 and Dino.rebirthShopCost("offlineHours", 0) == INF, "Amber costs")
	-- A Dino producer through the Dino Logic; a Nuke Town producer is unknown to it.
	local bench = Dino.index.ProducersById.dp1_pebble_bench
	check(Dino.producerOutput(bench, 10, nil, nil) == 10 * bench.baseRevenue, "Dino output linear in level")
	check(Dino.producerStats(Dino.newState(), "p1_workbench", nil) == nil, "main producer unknown to Dino")
	check(
		TycoonLogic.producerStats(TycoonLogic.newState(), "dp1_pebble_bench", nil) == nil,
		"Dino producer unknown to main"
	)
	check(not Dino.padAvailable(Dino.newState(), "a1_workbench"), "main pad unknown to Dino")
end

-- R70 World 3: Moon Base runs on its own Logic + Star Shard track; ids never cross worlds.
do
	local Moon = TycoonLogic.forWorld("moon")
	local Dino = TycoonLogic.forWorld("dino")
	local MoonRebirth = WorldsConfig.get("moon").rebirth
	check(
		Moon.worldId == "moon" and Moon.rebirth == MoonRebirth and Moon.rebirth ~= Dino.rebirth,
		"Moon binds its track"
	)
	check(
		Moon.rebirthMultiplier(2, { rebirthPower = 2 }) == Dino.rebirthMultiplier(2, { rebirthPower = 2 }),
		"same curve"
	)
	local bench = Moon.index.ProducersById.mp1_rock_bench
	check(Moon.producerOutput(bench, 10, nil, nil) == 10 * bench.baseRevenue, "Moon output linear in level")
	check(Moon.nextPads(Moon.newState())[1].id == "m1_capsule_bench", "Moon starts at the free Capsule Bench")
	check(Dino.producerStats(Dino.newState(), "mp1_rock_bench", nil) == nil, "Moon producer unknown to Dino")
	check(Moon.producerStats(Moon.newState(), "dp1_pebble_bench", nil) == nil, "Dino producer unknown to Moon")
	check(not Moon.padAvailable(Moon.newState(), "d1_stone_bench"), "Dino pad unknown to Moon")
	check(TycoonLogic.producerStats(TycoonLogic.newState(), "mp1_rock_bench", nil) == nil, "Moon unknown to main")
	-- Nuke Town's link sums both worlds: a Moon rebirth boosts Nuke Town exactly like a Dino one.
	local state = TycoonLogic.newState()
	for _, pad in TycoonConfig.PadOrder do
		TycoonLogic.applyPad(state, pad.id)
	end
	local base = TycoonLogic.incomePerSecond(state, nil)
	local link = WorldsConfig.linkCash("main", { dino = 2, moon = 3 })
	check(near(TycoonLogic.incomePerSecond(state, { linkCash = link }), base * 1.5), "main x1.5 from 2 Dino + 3 Moon")
end

print(`tycoon-logic: {checks} checks passed`)
