--!strict
--[[
	EconomyIndex regression (World 2 plan §4 W1.1, §5 "economy-index").

	What it proves
		1. PARITY: the Nuke Town economy built through `Shared/Tycoon/EconomyIndex` is BIT-IDENTICAL
		   to the tables (and TycoonLogic results) the game shipped before the worlds framework.
		   `collect` flattens every area / producer / pad field, every lookup table, the shared
		   tunables and ~1,700 sampled TycoonLogic results (output, cycle, click, costs,
		   max-affordable, idle, offline, rebirth) into `key -> "n:<%.17g>"` strings and compares
		   them with the frozen snapshot `tests/fixtures/EconomyMainSnapshot.luau`.
		2. VALIDATION: `EconomyIndex.build` errors loudly on a broken chain, bad id prefixes, bad
		   build keys, a feature the world does not allow, duplicate ids, non-finite numbers, a
		   missing Manager / finale, and areas that were already built (frozen).
		3. The generic index fields every world shares (WorldId, IdPrefix, AllowedFeatures, BuildKeys,
		   shared tunable table refs) and the Dino index.

	Snapshot maintenance
		The snapshot is the economy as it shipped on 2026-10-30. After an INTENTIONAL Nuke Town
		retune (`lune run tests/economy-sim.luau --tune --write`), refresh it:
			lune run tests/economy-index.luau --update-snapshot
		and say so in the commit message. Never refresh it to silence an unexplained diff.

	Run: lune run tests/economy-index.luau            (from the repo root)
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local Loader = require("./fixtures/RobloxLoader")

local SNAPSHOT_PATH = "tests/fixtures/EconomyMainSnapshot.luau"
local UPDATE = table.find(process.args, "--update-snapshot") ~= nil

local checks = 0
local function check(ok: boolean, message: string)
	assert(ok, message)
	checks += 1
end

--------------------------------------------------------------------------------------------------
-- Flattening: config + sampled logic -> { [key]: "<type>:<value>" }
--------------------------------------------------------------------------------------------------

-- One value as a tagged string, numbers at full precision (%.17g round-trips every double).
local function encode(value: any): string
	local kind = type(value)
	if kind == "number" then
		return "n:" .. string.format("%.17g", value)
	elseif kind == "string" then
		return "s:" .. value
	elseif kind == "boolean" then
		return "b:" .. tostring(value)
	elseif value == nil then
		return "nil"
	end
	error("economy-index: cannot encode a " .. kind)
end

-- Every pad / producer field the game reads (absent optional fields encode as "nil").
local PAD_FIELDS =
	{ "id", "area", "name", "kind", "cost", "requires", "target", "value", "unlocks", "feature", "build" }
local PRODUCER_FIELDS =
	{ "id", "name", "area", "builtBy", "baseCost", "costGrowth", "baseRevenue", "baseCycle", "clickable" }

--[[
	Flattens the main economy: config tables plus sampled TycoonLogic results.
	@param Config any — TycoonConfig
	@param Logic any — TycoonLogic (module-level main functions)
	@param Rebirth any — RebirthConfig
	@return {[string]: string}
]]
local function collect(Config: any, Logic: any, Rebirth: any): { [string]: string }
	local out: { [string]: string } = {}
	local function put(key: string, value: any)
		assert(out[key] == nil, "duplicate snapshot key " .. key)
		out[key] = encode(value)
	end

	-- Shared tunables.
	for _, key in { "MilestoneEvery", "MilestoneFactor", "CycleFloor", "MaxLevel", "MaxBulkLevels" } do
		put("tun." .. key, Config[key])
	end
	for _, key in
		{ "BaseCapSeconds", "BaseRate", "MaxCapSeconds", "MaxRate", "PassCapSeconds", "PassRate", "MinSeconds" }
	do
		put("tun.Offline." .. key, Config.Offline[key])
	end
	for _, key in { "CashPassMultiplier", "VipMultiplier", "MaxPetCash", "MaxMultiplier" } do
		put("tun.Modifiers." .. key, Config.Modifiers[key])
	end
	put("pacing.count", #Config.Pacing.TargetMinutes)
	for index, minutes in Config.Pacing.TargetMinutes do
		put(`pacing.{index}`, minutes)
	end
	put("pacing.tolerance", Config.Pacing.Tolerance)

	-- Areas, producers, pads (full records, in order).
	put("areas.count", #Config.Areas)
	for areaIndex, area in Config.Areas do
		local prefix = `area.{areaIndex}.`
		put(prefix .. "index", area.index)
		put(prefix .. "id", area.id)
		put(prefix .. "name", area.name)
		for _, field in PRODUCER_FIELDS do
			put(prefix .. "producer." .. field, area.producer[field])
		end
		put(prefix .. "pads", #area.pads)
		for position, pad in area.pads do
			for _, field in PAD_FIELDS do
				put(`{prefix}pad.{position}.{field}`, pad[field])
			end
			put(`{prefix}pad.{position}.blurb`, pad.blurb)
		end
	end

	-- Lookup tables.
	put("padOrder.count", #Config.PadOrder)
	for position, pad in Config.PadOrder do
		put(`padOrder.{position}`, pad.id)
		put(`padIndex.{pad.id}`, Config.PadIndex[pad.id])
		check(Config.PadsById[pad.id] == pad, `PadsById.{pad.id} is the PadOrder record`)
	end
	put("producers.count", #Config.Producers)
	for position, producer in Config.Producers do
		put(`producers.{position}`, producer.id)
		check(Config.ProducersById[producer.id] == producer, `ProducersById.{producer.id}`)
		put(`managerPadOf.{producer.id}`, Config.ManagerPadOf[producer.id])
		local targeted = {}
		for _, pad in Config.PadsByTarget[producer.id] do
			table.insert(targeted, pad.id)
		end
		put(`padsByTarget.{producer.id}`, table.concat(targeted, ","))
	end
	for padId, producerId in Config.ProducerBuiltBy do
		put(`producerBuiltBy.{padId}`, producerId)
	end
	for areaIndex, pads in Config.AreaPads do
		local ids = {}
		for _, pad in pads do
			table.insert(ids, pad.id)
		end
		put(`areaPads.{areaIndex}`, table.concat(ids, ","))
	end
	for feature, padId in Config.FeaturePadOf do
		put(`featurePadOf.{feature}`, padId)
	end
	put("finalePadId", Config.FinalePadId)

	-- Sampled TycoonLogic results on two plots (every pad but the Managers / every pad), with no
	-- bonuses and with a maxed-out bonus stack.
	local maxedShop: { [string]: number } = {}
	for key, upgrade in Rebirth.Shop do
		maxedShop[key] = upgrade.maxLevel
	end
	local modsVariants: { { name: string, mods: any } } = {
		{ name = "none", mods = nil },
		{
			name = "stack",
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
	for _, managed in { false, true } do
		local state = Logic.newState()
		for _, pad in Config.PadOrder do
			if managed or pad.kind ~= "Manager" then
				state.pads[pad.id] = true
			end
		end
		local plot = if managed then "managed" else "manual"
		for _, level in { 1, 25, 50, 400, 999 } do
			for _, producer in Config.Producers do
				state.producers[producer.id] = level
			end
			for _, variant in modsVariants do
				local mods = variant.mods
				local prefix = `logic.{plot}.{level}.{variant.name}.`
				for _, producer in Config.Producers do
					local p = prefix .. producer.id .. "."
					put(p .. "output", Logic.producerOutput(producer, level, mods, state))
					put(p .. "cycle", Logic.cycleTime(producer, level, mods, state))
					put(p .. "click", Logic.clickValue(producer, level, mods, state))
					put(p .. "clickCycle", Logic.clickCycleTime(producer, level, mods, state))
					local stats = Logic.producerStats(state, producer.id, mods)
					put(p .. "stats.cashMultiplier", stats.cashMultiplier)
					put(p .. "stats.perSecond", stats.perSecond)
					if variant.name == "none" then
						put(p .. "cost1", Logic.upgradeCost(producer, level, 1))
						put(p .. "cost10", Logic.upgradeCost(producer, level, 10))
						local n, cost = Logic.maxAffordable(producer, level, 1e30)
						put(p .. "max.n", n)
						put(p .. "max.cost", cost)
					end
				end
				put(prefix .. "income", Logic.incomePerSecond(state, mods))
				put(prefix .. "offline", (Logic.offlineEarnings(state, mods, 7200, 10800, 0.5)))
			end
			put(`logic.{plot}.{level}.reward`, Logic.rebirthReward(state, 2))
			put(`logic.{plot}.{level}.levels`, Logic.totalLevels(state))
		end
	end
	-- The pad chain walked in order: what the plot shows / allows after every purchase.
	do
		local state = Logic.newState()
		local features = { "StandRename", "AATower", "AttackConsole", "Rebirth", "Nope" }
		for position, pad in Config.PadOrder do
			local p = `chain.{position}.`
			put(p .. "available", (Logic.padAvailable(state, pad.id)))
			put(p .. "applied", Logic.applyPad(state, pad.id))
			put(p .. "again", (Logic.padAvailable(state, pad.id)))
			put(p .. "owns", Logic.ownsPad(state, pad.id))
			put(p .. "area", state.area)
			local nextPad = Logic.nextPads(state)[1]
			put(p .. "next", if nextPad then nextPad.id else nil)
			local built = Config.ProducerBuiltBy[pad.id]
			if built then
				put(p .. "builtLevel", Logic.levelOf(state, built))
				put(p .. "levelled", Logic.applyLevels(state, built, position))
			end
			-- One joined string per question keeps the snapshot compact ("1/9 0/10 ...").
			local progress, unlocked, owned, automated = {}, {}, {}, {}
			for areaIndex = 0, #Config.Areas + 1 do
				local bought, total = Logic.areaProgress(state, areaIndex)
				table.insert(progress, `{bought}/{total}`)
				table.insert(unlocked, tostring(Logic.areaUnlocked(state, areaIndex)))
			end
			for _, feature in features do
				table.insert(owned, tostring(Logic.hasFeature(state, feature)))
			end
			for _, producer in Config.Producers do
				table.insert(automated, tostring(Logic.isAutomated(state, producer.id)))
			end
			put(p .. "progress", table.concat(progress, " "))
			put(p .. "unlocked", table.concat(unlocked, " "))
			put(p .. "features", table.concat(owned, " "))
			put(p .. "automated", table.concat(automated, " "))
			put(p .. "canRebirth", Logic.canRebirth(state))
		end
	end
	for level = 0, 1001, 7 do
		local badge = Logic.milestoneBadge(level)
		put(
			`badge.{level}`,
			`{badge.milestones}|{badge.cash}|{badge.speed}|{badge.nextAt}|{badge.nextKind}|{badge.text}`
		)
	end
	for key, upgrade in Rebirth.Shop do
		for level = 0, upgrade.maxLevel do
			put(`shop.{key}.{level}.cost`, Logic.rebirthShopCost(key, level))
			put(`shop.{key}.{level}.effect`, Logic.rebirthShopEffect(key, level))
		end
	end
	put("shop.order", table.concat(Rebirth.ShopOrder, ","))
	put("rebirth.bonus", Rebirth.BonusPerRebirth)
	put("rebirth.max", Rebirth.MaxRebirths)
	for _, key in { "Base", "LevelsPerToken", "GrowthPerRebirth" } do
		put("rebirth.tokens." .. key, Rebirth.Tokens[key])
	end
	local cap, rate = Logic.offlineLimits(maxedShop, false)
	put("offline.maxedShop.cap", cap)
	put("offline.maxedShop.rate", rate)
	return out
end

--[[
	Writes the snapshot module (sorted keys, so diffs are readable).
	@param flat {[string]: string}
]]
local function writeSnapshot(flat: { [string]: string })
	local keys = {}
	for key in flat do
		table.insert(keys, key)
	end
	table.sort(keys)
	local lines = {
		"--!strict",
		"-- GENERATED by `lune run tests/economy-index.luau --update-snapshot` — the Nuke Town economy parity",
		"-- snapshot. First taken before the worlds framework (2026-10-30); refreshed ONLY for intentional retunes,",
		'-- each logged in docs/economy.md "Snapshot refreshes" (R65 2026-10-31: Workbench first upgrade $10;',
		"-- R122 2026-11-01: Garage Lab order with Uncle Atom as pad 4 + its re-pace).",
		"-- Do not edit by hand; see tests/economy-index.luau.",
		"return {",
	}
	for _, key in keys do
		table.insert(lines, string.format("\t[%q] = %q,", key, flat[key]))
	end
	table.insert(lines, "}")
	fs.writeFile(SNAPSHOT_PATH, table.concat(lines, "\n") .. "\n")
end

local loader = Loader.new()
local TycoonConfig = loader.load("src/shared/Config/TycoonConfig")
local TycoonLogic = loader.load("src/shared/Tycoon/TycoonLogic")
local RebirthConfig = loader.load("src/shared/Config/RebirthConfig")

local current = collect(TycoonConfig, TycoonLogic, RebirthConfig)
if UPDATE then
	writeSnapshot(current)
	local count = 0
	for _ in current do
		count += 1
	end
	print(`economy-index: wrote {count} snapshot values to {SNAPSHOT_PATH}`)
	return
end

--------------------------------------------------------------------------------------------------
-- 1. Parity with the frozen snapshot
--------------------------------------------------------------------------------------------------
do
	local snapshot = loader.load((string.gsub(SNAPSHOT_PATH, "%.luau$", "")))
	local mismatches: { string } = {}
	for key, expected in snapshot do
		local actual = current[key]
		if actual ~= expected then
			table.insert(mismatches, `{key}: snapshot {expected}, now {actual or "missing"}`)
		end
	end
	for key, actual in current do
		if snapshot[key] == nil then
			table.insert(mismatches, `{key}: new value {actual} (not in the snapshot)`)
		end
	end
	table.sort(mismatches)
	if #mismatches > 0 then
		local shown = table.move(mismatches, 1, math.min(#mismatches, 25), 1, {})
		error(`economy-index: {#mismatches} parity mismatches with {SNAPSHOT_PATH}:\n  ` .. table.concat(shown, "\n  "))
	end
	local count = 0
	for _ in snapshot do
		count += 1
	end
	check(count > 1000, `snapshot holds {count} values`)
end

--------------------------------------------------------------------------------------------------
-- 2. Validation: EconomyIndex.build errors loudly on every broken rule
--------------------------------------------------------------------------------------------------
local EconomyIndex = loader.load("src/shared/Tycoon/EconomyIndex")

--[[
	A fresh, VALID two-area world "t" (prefix "t": pads t<N>_, producers tp<N>_, keys T<N>_).
	Returns brand-new tables every call (build freezes what it is given).
	@param mutate ((spec) -> ())? — breaks one rule before building
	@return the spec
]]
local function tinySpec(mutate: ((any) -> ())?): any
	local function area(n: number, last: boolean): any
		local producer = `tp{n}_maker`
		local prev = if n == 1 then nil else `t{n - 1}_open`
		local pads = {
			{
				id = `t{n}_base`,
				area = n,
				name = "Base",
				kind = "Build",
				cost = if n == 1 then 0 else 10,
				requires = prev,
				target = producer,
				value = 0,
				build = `T{n}_Base`,
				blurb = "Builds it",
			},
			{
				id = `t{n}_boost`,
				area = n,
				name = "Boost",
				kind = "Multiplier",
				cost = 45,
				requires = `t{n}_base`,
				target = producer,
				value = 2,
				build = `T{n}_Boost`,
				blurb = "x2",
			},
			{
				id = `t{n}_boss`,
				area = n,
				name = "Boss",
				kind = "Manager",
				cost = 60,
				requires = `t{n}_boost`,
				target = producer,
				build = `T{n}_Boss`,
				blurb = "Automates",
			},
		}
		if last then
			table.insert(pads, {
				id = `t{n}_statue`,
				area = n,
				name = "Statue",
				kind = "Unlock",
				cost = 180,
				requires = `t{n}_boss`,
				feature = "Rebirth",
				build = `T{n}_Statue`,
				blurb = "Rebirth",
			})
		else
			table.insert(pads, {
				id = `t{n}_open`,
				area = n,
				name = "Open",
				kind = "Unlock",
				cost = 180,
				requires = `t{n}_boss`,
				unlocks = n + 1,
				build = `T{n + 1}_EntryArch`,
				blurb = "Opens",
			})
		end
		return {
			index = n,
			id = `area{n}`,
			name = `Area {n}`,
			producer = {
				id = producer,
				name = "Maker",
				area = n,
				builtBy = `t{n}_base`,
				baseCost = 3,
				costGrowth = 1.2,
				baseRevenue = 1,
				baseCycle = 1,
				clickable = true,
			},
			pads = pads,
		}
	end
	local spec = {
		worldId = "t",
		idPrefix = "t",
		areas = { area(1, false), area(2, true) },
		pacing = { TargetMinutes = { 5, 9 }, Tolerance = 0.2 },
		allowedFeatures = { Rebirth = true },
		tunables = TycoonConfig.Tunables,
	}
	if mutate then
		mutate(spec)
	end
	return spec
end

-- Expects build to fail with an error containing `fragment`.
local function rejects(mutate: (any) -> (), fragment: string, what: string)
	local ok, err = pcall(EconomyIndex.build, tinySpec(mutate))
	check(not ok, `{what}: build must fail`)
	check(string.find(tostring(err), fragment, 1, true) ~= nil, `{what}: error mentions "{fragment}" ({err})`)
end

do
	-- The valid tiny world builds, with prefixes, lookups, frozen data and shared tunable refs.
	local index = EconomyIndex.build(tinySpec(nil))
	check(index.WorldId == "t" and index.IdPrefix == "t", "tiny world identity")
	check(index.PadPrefix == "t" and index.ProducerPrefix == "tp" and index.BuildPrefix == "T", "tiny prefixes")
	check(
		#index.PadOrder == 8 and index.FinalePadId == "t2_statue" and index.FeaturePadOf.Rebirth == "t2_statue",
		"chain"
	)
	check(index.BuildKeys.T2_EntryArch == "t1_open" and index.ManagerPadOf.tp2_maker == "t2_boss", "lookups")
	check(index.Offline == TycoonConfig.Offline and index.Modifiers == TycoonConfig.Modifiers, "shared tunable refs")
	check(index.MaxLevel == TycoonConfig.MaxLevel and index.CycleFloor == TycoonConfig.CycleFloor, "shared tunables")
	check(table.isfrozen(index) and table.isfrozen(index.PadOrder) and table.isfrozen(index.Areas[1].pads[1]), "frozen")
	check(index.PadsById.t1_boost.cost == 45 and index.ProducersById.tp1_maker.baseCost == 3, "friendly prices")

	-- Rebuilding the same (now frozen) area tables is a config bug.
	local spec = tinySpec(nil)
	EconomyIndex.build(spec)
	check(not pcall(EconomyIndex.build, spec), "building the same area tables twice fails")

	rejects(function(s)
		s.areas[1].pads[2].requires = nil
	end, "must require", "broken chain")
	rejects(function(s)
		s.areas[2].pads[1].requires = "t1_boss"
	end, "must require", "area chain skips the Unlock")
	rejects(function(s)
		s.areas[1].pads[2].id = "x1_boost"
		s.areas[1].pads[3].requires = "x1_boost"
	end, "must match t1_name", "foreign pad prefix")
	rejects(function(s)
		s.areas[1].pads[2].id = "t2_boost"
		s.areas[1].pads[3].requires = "t2_boost"
	end, "must match t1_name", "pad id names the wrong area")
	rejects(function(s)
		s.areas[1].producer.id = "p1_maker"
	end, "must match tp1_name", "producer prefix")
	rejects(function(s)
		s.areas[1].pads[2].build = "A1_Boost"
	end, "must match T1_Name", "build key prefix")
	rejects(function(s)
		s.areas[1].pads[2].build = "T2_Boost"
	end, "must match T1_Name", "build key area")
	rejects(function(s)
		s.areas[1].pads[4].build = "T2_Gate"
	end, "must build T2_EntryArch", "Unlock pad build key")
	rejects(function(s)
		s.areas[1].pads[2].build = s.areas[1].pads[1].build
	end, "duplicate build key", "duplicate build key")
	rejects(function(s)
		s.areas[1].pads[2].feature = "AATower"
	end, "not allowed", "feature not allowed in this world")
	rejects(function(s)
		s.allowedFeatures = { Rebirth = true, Teleport = true }
	end, "unknown feature", "unknown feature key")
	rejects(function(s)
		s.allowedFeatures = { AATower = true }
	end, "Rebirth", "a world without Rebirth")
	rejects(function(s)
		s.idPrefix = "a"
	end, "idPrefix", "reserved prefix a")
	rejects(function(s)
		s.idPrefix = "p"
	end, "idPrefix", "reserved prefix p")
	rejects(function(s)
		s.idPrefix = "tt"
	end, "idPrefix", "two-letter prefix")
	rejects(function(s)
		s.worldId = "Bad World"
	end, "bad worldId", "world id format")
	rejects(function(s)
		s.areas[1].pads[3].id = "t1_boost"
		s.areas[1].pads[4].requires = "t1_boost"
	end, "duplicate pad id", "duplicate pad id")
	rejects(function(s)
		s.areas[1].pads[2].cost = 0 / 0
	end, "must be a number", "NaN cost")
	rejects(function(s)
		s.areas[1].producer.baseRevenue = math.huge
	end, "outside", "infinite revenue")
	rejects(function(s)
		s.areas[1].producer.costGrowth = 1
	end, "outside", "costGrowth 1")
	rejects(function(s)
		s.areas[1].pads[3].kind = "Build"
		s.areas[1].pads[3].value = 0.1
	end, "has no Manager", "missing Manager")
	rejects(function(s)
		s.areas[2].pads[4].feature = nil
	end, "Rebirth", "finale without Rebirth")
	rejects(function(s)
		s.areas[1].pads[4].unlocks = 3
	end, "must unlock area 2", "Unlock to the wrong area")
	rejects(function(s)
		s.areas[1].pads[2].kind = "Teleport"
	end, "unknown kind", "unknown kind")
	rejects(function(s)
		s.areas[1].pads[2].blurb = ""
	end, "needs a blurb", "empty blurb")
	rejects(function(s)
		s.pacing = { TargetMinutes = { 5 }, Tolerance = 0.2 }
	end, "one pacing target per area", "pacing count")
	rejects(function(s)
		s.areas[1].pads[2].target = "tp2_maker"
	end, "must target tp1_maker", "wrong target")
	rejects(function(s)
		s.areas[1].pads[1].kind = "Multiplier"
		s.areas[1].pads[1].value = 2
	end, "must be a Build pad", "builder not a Build pad")
	rejects(function(s)
		s.areas[1].pads[2].value = 0.5
	end, "outside", "Multiplier below 1")
end

--------------------------------------------------------------------------------------------------
-- 3. The real indexes: main re-exports, Dino built through the same path
--------------------------------------------------------------------------------------------------
do
	local index = TycoonConfig.Index
	check(index.WorldId == "main" and TycoonConfig.WorldId == "main" and index.IdPrefix == "", "main identity")
	check(index.PadPrefix == "a" and index.ProducerPrefix == "p" and index.BuildPrefix == "A", "main legacy prefixes")
	for _, key in
		{
			"Areas",
			"PadOrder",
			"PadsById",
			"PadIndex",
			"Producers",
			"ProducersById",
			"PadsByTarget",
			"ManagerPadOf",
			"ProducerBuiltBy",
			"AreaPads",
			"FeaturePadOf",
			"FinalePadId",
			"Pacing",
			"Offline",
			"Modifiers",
		}
	do
		check(TycoonConfig[key] == index[key], `TycoonConfig.{key} is TycoonConfig.Index.{key}`)
	end
	check(TycoonConfig.friendlyPrice == EconomyIndex.friendlyPrice, "friendlyPrice re-export")
	check(EconomyIndex.friendlyPrice(72913402) == 73000000 and EconomyIndex.friendlyPrice(-1) == 0, "friendlyPrice")
	local tunables = TycoonConfig.Tunables
	check(table.isfrozen(tunables) and tunables.Offline == TycoonConfig.Offline, "Tunables frozen, same refs")
	check(table.isfrozen(TycoonConfig.Offline) and table.isfrozen(TycoonConfig.Modifiers), "tunable tables frozen")
	local d, dp, D = EconomyIndex.prefixes("d")
	check(d == "d" and dp == "dp" and D == "D", "prefixes(d)")

	local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")
	local dino = WorldsConfig.get("dino").economy
	check(dino.WorldId == "dino" and dino.PadPrefix == "d" and dino.ProducerPrefix == "dp", "dino index identity")
	check(dino.Offline == index.Offline and dino.Modifiers == index.Modifiers, "dino shares the tunables")
	check(dino.MilestoneEvery == index.MilestoneEvery and dino.MaxBulkLevels == index.MaxBulkLevels, "dino tunables")
	check(table.isfrozen(dino) and table.isfrozen(dino.BuildKeys), "dino index frozen")
	check(dino.BuildKeys.D3_WindSock == "d3_wind_sock" and dino.BuildKeys.D2_EntryArch == "d1_open_market", "BuildKeys")

	-- R70 World 3: Moon Base through the same builder (prefix "m": m<N>_ / mp<N>_ / M<N>_).
	local moon = WorldsConfig.get("moon").economy
	check(moon.WorldId == "moon" and moon.IdPrefix == "m", "moon index identity")
	check(moon.PadPrefix == "m" and moon.ProducerPrefix == "mp" and moon.BuildPrefix == "M", "moon prefixes")
	check(moon.Offline == index.Offline and moon.Modifiers == index.Modifiers, "moon shares the tunables")
	check(table.isfrozen(moon) and table.isfrozen(moon.PadsById) and table.isfrozen(moon.Areas[1].pads[1]), "frozen")
	check(
		moon.BuildKeys.M3_RadarDish == "m3_radar_dish" and moon.BuildKeys.M2_EntryArch == "m1_open_diner",
		"moon keys"
	)
	check(moon.Areas ~= dino.Areas and moon.PadsById.d1_stone_bench == nil, "moon never shares Dino's records")
end

print(`economy-index: {checks} checks passed`)
