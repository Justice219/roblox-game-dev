--!strict
--[[
	Manager nametags + speech bubbles regressions (owner R87). Run:
		lune run tests/manager-tags

	Loads the REAL modules (src/shared/Config/ManagerTagConfig.luau, src/client/Tycoon/Npc/
	ManagerTagLogic.luau, src/shared/Config/ManagerNpcConfig.luau) with Roblox datatypes injected
	from @lune/roblox, reads every world's Manager pads from the area configs, and proves:
	  1. Coverage: every manager key of every world (ManagerNpcConfig.WorldManagerKeys) has a
	     ManagerTagConfig.Managers row and every row is a listed manager; pooled rows name an
	     existing pool; each listed key has a Manager pad (name + target producer) in its world's
	     area config; canon-named managers' pad names fit the tag.
	  2. Pools: non-empty, names unique across all pools, 2..16 characters, and every pool holds at
	     least as many names as one world has managers drawing from it.
	  3. Lines: every world with managers has a line list, every line 4..26 characters, no
	     duplicates inside a list; linesFor merges general + world (+ robot).
	  4. hash = FNV-1a 32 (published vectors); seedOf differs by owner / world / pool.
	  5. pickName is a deterministic permutation: ordinals 1..#pool give every name once; for 500
	     owners no two managers of one plot share a name; different owners do not all get the
	     same names; describe() applies the pool rule (chip = job title) and the canon rule
	     (name = pad name, chip = DefaultRole).
	  6. Scheduler over 30 simulated minutes (always someone eligible): first bubble within
	     FirstDelay, never two at once, gaps between starts within ShowSeconds + Interval, the
	     speaker and the line never repeat back to back, `ended` cuts a bubble short without
	     moving the next one; with nobody eligible the plot stays due (speaks as soon as possible).
	  7. overlaps() edge cases (touching, margin, containment); nudge() picks the smallest clear
	     sideways shift, keeps its side when feasible, never exceeds the cap (4000-case sweep: every
	     "clear" result really is clear); widthScale() stays in [MinWidthScale, 1].
	  8. Readability (owner R11): at 25 studs on a phone viewport (390 pt high, FOV 70, device
	     scale) the name row >= 24 pt, the "runs" row >= 15 pt and the longest "runs <producer>"
	     still renders >= 13.5 pt wide-fitted; every real tag at its fitted width keeps its name and
	     "runs" line >= 13.5 pt; the rows fit inside the tag.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local checks = 0
local function ok(condition: any, label: string)
	if not condition then
		error(label, 2)
	end
	checks += 1
end

local function load(path: string): any
	local env = {
		Vector3 = roblox.Vector3,
		Color3 = roblox.Color3,
		Enum = roblox.Enum,
		string = string,
		table = table,
		math = math,
		bit32 = bit32,
		type = type,
		error = error,
	}
	return luau.load(fs.readFile(path), { debugName = path, environment = env })()
end

local Config = load("src/shared/Config/ManagerTagConfig.luau")
local Logic = load("src/client/Tycoon/Npc/ManagerTagLogic.luau")
local Npc = load("src/shared/Config/ManagerNpcConfig.luau")

-- Every world with manager keys (Nuke Town first, then by id).
local WORLDS: { string } = {}
for worldId in Npc.WorldManagerKeys do
	if worldId ~= "main" then
		table.insert(WORLDS, worldId)
	end
end
table.sort(WORLDS)
table.insert(WORLDS, 1, "main")

-- A world's area config file ("main" -> TycoonAreas, others -> Worlds/<World>/Areas).
local function areaPath(worldId: string, area: number): string
	if worldId == "main" then
		return string.format("src/shared/Config/TycoonAreas/Area%02d.luau", area)
	end
	local folder = string.upper(string.sub(worldId, 1, 1)) .. string.sub(worldId, 2)
	return string.format("src/shared/Config/Worlds/%s/Areas/Area%02d.luau", folder, area)
end

-- Manager pads of every world: build key -> { name, producer display name }.
type PadInfo = { name: string, producer: string, world: string }
local pads: { [string]: PadInfo } = {}
for _, worldId in WORLDS do
	for area = 1, #Npc.managerKeysOf(worldId) do
		local path = areaPath(worldId, area)
		if fs.isFile(path) then
			local source = fs.readFile(path)
			local producerName = string.match(source, "producer = {%s*id = [%w_\"]+,%s*name = \"([^\"]+)\"") or ""
			for name, rest in string.gmatch(source, 'name = "([^"]+)",%s*kind = "Manager",(.-)}') do
				local build = string.match(rest, 'build = "([%w_]+)"')
				if build ~= nil then
					pads[build] = { name = name, producer = producerName, world = worldId }
				end
			end
		end
	end
end

-- 1. Coverage ------------------------------------------------------------------------------------
local listed: { [string]: string } = {}
local poolUsers: { [string]: { [string]: number } } = {} -- world -> pool -> managers drawing from it
for _, worldId in WORLDS do
	poolUsers[worldId] = {}
	for _, key in Npc.managerKeysOf(worldId) do
		listed[key] = worldId
		local row = Config.Managers[key]
		ok(row ~= nil, `{key}: has a ManagerTagConfig.Managers row`)
		if row.pool ~= nil then
			ok(Config.NamePools[row.pool] ~= nil, `{key}: pool {row.pool} exists`)
			poolUsers[worldId][row.pool] = (poolUsers[worldId][row.pool] or 0) + 1
		end
		local pad = pads[key]
		ok(pad ~= nil, `{key}: has a Manager pad in {worldId}'s area config`)
		ok(pad.world == worldId, `{key}: pad lives in its world`)
		ok(pad.producer ~= "", `{key}: its area has a producer name`)
		if row.pool == nil then
			ok(#pad.name >= 2 and #pad.name <= 16, `{key}: canon name "{pad.name}" fits the tag`)
		else
			ok(#pad.name >= 2 and #pad.name <= 18, `{key}: job title "{pad.name}" fits the chip`)
		end
	end
end
for key in Config.Managers do
	ok(listed[key] ~= nil, `{key}: Managers row belongs to a listed manager`)
end
ok(type(Config.DefaultRole) == "string" and #Config.DefaultRole > 0, "DefaultRole")
for _, worldId in WORLDS do
	ok(type(Config.ChipColors[worldId]) == "string", `{worldId}: has a chip colour`)
end

-- 2. Pools ---------------------------------------------------------------------------------------
local seen: { [string]: string } = {}
for poolName, pool in Config.NamePools do
	ok(#pool > 0, `{poolName}: non-empty`)
	for _, name in pool do
		ok(#name >= 2 and #name <= 16, `{poolName}: "{name}" is 2..16 characters`)
		ok(seen[name] == nil, `"{name}" appears once across pools`)
		seen[name] = poolName
	end
end
for worldId, users in poolUsers do
	for poolName, count in users do
		ok(#Config.NamePools[poolName] >= count, `{worldId}: pool {poolName} covers its {count} managers`)
	end
end

-- 3. Lines ---------------------------------------------------------------------------------------
local function checkLines(listName: string, list: { string })
	ok(#list > 0, `lines {listName}: non-empty`)
	local inList: { [string]: boolean } = {}
	for _, line in list do
		ok(#line >= 4 and #line <= 26, `lines {listName}: "{line}" is 4..26 characters`)
		ok(not inList[line], `lines {listName}: "{line}" listed once`)
		inList[line] = true
	end
end
checkLines("general", Config.Lines.general)
checkLines("robot", Config.Lines.robot)
for _, worldId in WORLDS do
	ok(Config.Lines[worldId] ~= nil, `{worldId}: has world lines`)
	checkLines(worldId, Config.Lines[worldId])
end
local mainLines = Logic.linesFor(Config.Lines, "main", false)
ok(#mainLines == #Config.Lines.general + #Config.Lines.main, "linesFor(main) = general + main")
local robotLines = Logic.linesFor(Config.Lines, "main", true)
ok(#robotLines == #mainLines + #Config.Lines.robot, "linesFor(main, robot) adds robot lines")
ok(#Logic.linesFor(Config.Lines, "nowhere", false) == #Config.Lines.general, "unknown world: general only")

-- 4. hash / seedOf -------------------------------------------------------------------------------
ok(Logic.hash("") == 2166136261, "FNV-1a('')")
ok(Logic.hash("a") == 0xE40C292C, "FNV-1a('a')")
ok(Logic.hash("foobar") == 0xBF9CF968, "FNV-1a('foobar')")
ok(Logic.seedOf(1, "main", "crew") ~= Logic.seedOf(2, "main", "crew"), "seed differs by owner")
ok(Logic.seedOf(1, "main", "crew") ~= Logic.seedOf(1, "dino", "crew"), "seed differs by world")
ok(Logic.seedOf(1, "main", "crew") ~= Logic.seedOf(1, "main", "robot"), "seed differs by pool")
ok(Logic.seedOf(-1, "main", "crew") == Logic.seedOf(-1, "main", "crew"), "seed is stable (Studio test ids)")

-- 5. pickName / ordinalOf / describe -------------------------------------------------------------
for poolName, pool in Config.NamePools do
	for _, seed in { 0, 1, 7, 123456789, Logic.seedOf(42, "main", poolName) } do
		local names: { [string]: boolean } = {}
		for ordinal = 1, #pool do
			local name = Logic.pickName(pool, seed, ordinal)
			ok(name ~= "" and not names[name], `{poolName} seed {seed}: ordinal {ordinal} is a fresh name`)
			names[name] = true
		end
		ok(Logic.pickName(pool, seed, 1) == Logic.pickName(pool, seed, 1), `{poolName}: deterministic`)
		ok(Logic.pickName(pool, seed, #pool + 1) == Logic.pickName(pool, seed, 1), `{poolName}: wraps`)
	end
end
ok(Logic.pickName({}, 1, 1) == "", "empty pool")

local mainKeys = Npc.managerKeysOf("main")
ok(Logic.ordinalOf(mainKeys, Config.Managers, "A1_UncleAtom") == 0, "canon manager: ordinal 0")
ok(Logic.ordinalOf(mainKeys, Config.Managers, "A2_CashierBot") == 1, "first robot: ordinal 1")
ok(Logic.ordinalOf(mainKeys, Config.Managers, "A8_StoreManager") == 2, "second robot: ordinal 2")
ok(Logic.ordinalOf(mainKeys, Config.Managers, "A3_Dispatcher") == 1, "first crew: ordinal 1")
ok(Logic.ordinalOf(mainKeys, Config.Managers, "nope") == 0, "unknown key: ordinal 0")

local function describeAll(worldId: string, owner: number): { [string]: any }
	local out: { [string]: any } = {}
	local keys = Npc.managerKeysOf(worldId)
	for _, key in keys do
		local pad = pads[key]
		out[key] = Logic.describe(
			key,
			pad.name,
			pad.producer,
			keys,
			Config.Managers,
			Config.NamePools,
			function(pool: string): number
				return Logic.seedOf(owner, worldId, pool)
			end,
			Config.DefaultRole
		)
	end
	return out
end

local firstNames: { [string]: boolean } = {}
for owner = 1, 500 do
	for _, worldId in WORLDS do
		local names: { [string]: boolean } = {}
		for key, tag in describeAll(worldId, owner) do
			ok(not names[tag.name], `owner {owner} {worldId}: "{tag.name}" unique on the plot ({key})`)
			names[tag.name] = true
			ok(tag.runs == pads[key].producer, `{key}: runs its pad's producer`)
			local row = Config.Managers[key]
			if row.pool ~= nil then
				ok(tag.role == pads[key].name and tag.pool == row.pool, `{key}: chip = job title, pooled name`)
			else
				ok(tag.name == pads[key].name and tag.role == (row.role or Config.DefaultRole), `{key}: canon`)
			end
		end
	end
	firstNames[describeAll("main", owner).A4_Foreman.name] = true
end
local variety = 0
for _ in firstNames do
	variety += 1
end
ok(variety >= 10, `pooled names vary between owners ({variety} distinct Foreman names over 500 owners)`)
local again = describeAll("main", 777)
ok(again.A4_Foreman.name == describeAll("main", 777).A4_Foreman.name, "same owner, same name (rejoin)")

-- 6. Scheduler -----------------------------------------------------------------------------------
local Bubble = Config.Bubble
ok(Bubble.IntervalMin >= 20 and Bubble.IntervalMax <= 40, "owner R87: every 20-40 s")
ok(Bubble.IntervalMin <= Bubble.IntervalMax and Bubble.FirstDelayMin <= Bubble.FirstDelayMax, "ranges ordered")
local keys = { "A1", "A2", "A3" }
local lines = { "one", "two", "three", "four" }
for seed = 1, 20 do
	local s = Logic.newScheduler(seed * 7919, 100, Bubble)
	ok(s.nextAt >= 100 + Bubble.FirstDelayMin and s.nextAt <= 100 + Bubble.FirstDelayMax, "first delay")
	local lastStart: number? = nil
	local lastKey: string? = nil
	local lastLine: string? = nil
	local starts = 0
	local t = 100
	while t < 100 + 1800 do
		if Logic.due(s, t) then
			ok(not Logic.showing(s, t), "never two bubbles at once")
			local index = Logic.choose(s, keys)
			ok(index >= 1 and index <= #keys, "speaker index in range")
			ok(keys[index] ~= lastKey, "speaker never repeats back to back")
			local line = Logic.chooseLine(s, lines)
			ok(line ~= lastLine, "line never repeats back to back")
			if lastStart ~= nil then
				local gap = t - lastStart
				ok(
					gap >= Bubble.ShowSeconds + Bubble.IntervalMin - 1e-6
						and gap <= Bubble.ShowSeconds + Bubble.IntervalMax + 0.25 + 1e-6,
					`gap between bubbles {gap}`
				)
			end
			Logic.started(s, t, Bubble, keys[index], line)
			lastStart, lastKey, lastLine = t, keys[index], line
			starts += 1
		end
		t += 0.25
	end
	ok(starts >= 1800 / (Bubble.ShowSeconds + Bubble.IntervalMax) - 1, `enough bubbles in 30 min ({starts})`)
end
do
	local s = Logic.newScheduler(5, 0, Bubble)
	Logic.started(s, 50, Bubble, "A1", "one")
	local nextAt = s.nextAt
	ok(Logic.showing(s, 51), "showing after start")
	Logic.ended(s, 51)
	ok(not Logic.showing(s, 51) and s.nextAt == nextAt, "ended: gone at once, schedule kept")
	ok(not Logic.due(s, 52), "ended: not due before nextAt")
	ok(Logic.due(s, nextAt), "due at nextAt")
	ok(Logic.due(s, nextAt + 300), "nobody eligible: stays due (speaks as soon as possible)")
	ok(Logic.choose(s, {}) == 0, "choose: empty list")
	ok(Logic.choose(s, { "A1" }) == 1, "choose: the only manager may repeat")
	ok(Logic.chooseLine(s, {}) == "", "chooseLine: empty list")
	ok(Logic.chooseLine(s, { "solo" }) == "solo", "chooseLine: the only line may repeat")
end

-- 7. overlaps ------------------------------------------------------------------------------------
ok(Logic.overlaps(100, 100, 50, 20, 100, 100, 10, 10, 0), "contained")
ok(Logic.overlaps(100, 100, 50, 20, 100, 125, 50, 20, 6), "5 px apart < 6 px margin")
ok(not Logic.overlaps(100, 100, 50, 20, 100, 130, 50, 20, 6), "10 px apart > 6 px margin")
ok(not Logic.overlaps(100, 100, 50, 20, 150, 100, 50, 20, 0), "touching edges do not overlap")
ok(not Logic.overlaps(0, 0, 10, 10, 500, 500, 10, 10, 50), "far apart")

-- 7b. nudge (sideways clearance from the producer board) ----------------------------------------
do
	-- No overlap: stay put.
	local shift, clear = Logic.nudge(100, 50, 100, 30, 300, 50, 40, 40, 6, 80, 0)
	ok(shift == 0 and clear, "nudge: clear tag stays")
	-- Board on the right half: smallest move is left.
	shift, clear = Logic.nudge(100, 50, 100, 30, 160, 50, 40, 40, 6, 80, 0)
	ok(clear and shift < 0 and math.abs(shift - -16.5) < 1e-9, `nudge: left by 16.5 ({shift})`)
	ok(not Logic.overlaps(100 + shift, 50, 100, 30, 160, 50, 40, 40, 6), "nudge: shifted tag is clear")
	-- Prefer the current side when it is feasible, even if the other side is shorter.
	shift, clear = Logic.nudge(100, 50, 100, 30, 160, 50, 40, 40, 6, 200, 1)
	ok(clear and shift > 0, "nudge: keeps the right side")
	ok(not Logic.overlaps(100 + shift, 50, 100, 30, 160, 50, 40, 40, 6), "nudge: right shift is clear")
	-- Too far: cannot clear within the cap -> hide.
	shift, clear = Logic.nudge(100, 50, 100, 30, 100, 50, 300, 40, 6, 80, 0)
	ok(not clear and shift == 0, "nudge: a board wider than the cap hides the tag")
	-- Preferred side infeasible, other side feasible.
	shift, clear = Logic.nudge(100, 50, 100, 30, 160, 50, 40, 40, 6, 50, 1)
	ok(clear and shift < 0, "nudge: falls back to the other side")
	-- Random sweep: every clear result is really clear and within the cap.
	local seed = 1
	local function rnd(): number
		seed = (seed * 48271) % 2147483647
		return seed / 2147483647
	end
	for _ = 1, 4000 do
		local tx, ty, tw, th = rnd() * 800, rnd() * 400, 40 + rnd() * 200, 20 + rnd() * 60
		local bx, by, bw, bh = rnd() * 800, rnd() * 400, 30 + rnd() * 200, 30 + rnd() * 150
		local cap = tw * Config.Tag.NudgeMaxFraction
		local prefer = math.floor(rnd() * 3) - 1
		local s2, c2 = Logic.nudge(tx, ty, tw, th, bx, by, bw, bh, 6, cap, prefer)
		if c2 then
			ok(math.abs(s2) <= cap + 1e-9, "nudge sweep: within the cap")
			ok(not Logic.overlaps(tx + s2, ty, tw, th, bx, by, bw, bh, 6), "nudge sweep: result is clear")
		else
			ok(Logic.overlaps(tx, ty, tw, th, bx, by, bw, bh, 6), "nudge sweep: only overlapping tags hide")
		end
	end
end

-- 7c. widthScale (tags only as wide as their text) -----------------------------------------------
do
	local Tag = Config.Tag
	local short = Logic.widthScale("Zappy-3", "runs Nuke Stand", "CASHIER BOT", Tag, Tag.FullWidthChars, Tag.MinWidthScale)
	local long = Logic.widthScale("Uncle Atom", "runs Pocket Nuke Workbench", "MANAGER", Tag, Tag.FullWidthChars, Tag.MinWidthScale)
	ok(short >= Tag.MinWidthScale and short < 0.8, `widthScale: short tag is narrow ({short})`)
	ok(long > short and long <= 1, `widthScale: long tag is wider ({long})`)
	ok(Logic.widthScale("A", "", "", Tag, Tag.FullWidthChars, Tag.MinWidthScale) == Tag.MinWidthScale, "widthScale floor")
	ok(
		Logic.widthScale(string.rep("W", 40), "", "", Tag, Tag.FullWidthChars, Tag.MinWidthScale) == 1,
		"widthScale ceiling"
	)
end

-- 8. Readability ---------------------------------------------------------------------------------
local Tag = Config.Tag
ok(Tag.ChipHeight + Tag.NameHeight + Tag.RunsHeight + 0.03 <= 1, "tag rows fit inside the tag")
local viewportY, fov, distance = 390, 70, 25
local focal = viewportY / (2 * math.tan(math.rad(fov) / 2))
local perStud = focal / distance
local k = Tag.DeviceScale
local tagW = (Tag.StudsWidth * perStud + Tag.PixelWidth) * k
local tagH = (Tag.StudsHeight * perStud + Tag.PixelHeight) * k
ok(Tag.NameHeight * tagH >= 24, `phone @25: name row {Tag.NameHeight * tagH} pt >= 24`)
ok(Tag.RunsHeight * tagH >= 15, `phone @25: runs row {Tag.RunsHeight * tagH} pt >= 15`)
-- Fredoka One averages ~0.56 em per character: the width-fitted size of the longest runs line.
local longest = 0
for _, pad in pads do
	longest = math.max(longest, #Tag.RunsPrefix + 1 + #pad.producer)
end
local runsSize = math.min(Tag.RunsHeight * tagH * 0.9, 0.96 * tagW / (0.56 * longest))
ok(runsSize >= 13.5, `phone @25: longest runs line (~{longest} chars) renders {runsSize} pt`)
-- Every real tag, at its fitted width: the name and runs lines still render >= 13.5 pt.
for key, pad in pads do
	local row = Config.Managers[key]
	local name = if row.pool ~= nil then "Millie Megawatt" else pad.name -- the longest pooled name
	local runsText = `{Tag.RunsPrefix} {pad.producer}`
	local role = string.upper(if row.pool ~= nil then pad.name else (row.role or Config.DefaultRole))
	local scale = Logic.widthScale(name, runsText, role, Tag, Tag.FullWidthChars, Tag.MinWidthScale)
	local width = tagW * scale
	local runsPt = math.min(Tag.RunsHeight * tagH * 0.9, 0.96 * width / (0.56 * #runsText))
	local namePt = math.min(Tag.NameHeight * tagH * 0.9, width / (0.56 * #name))
	ok(runsPt >= 13.5 and namePt >= 13.5, `{key}: fitted tag keeps runs {runsPt} / name {namePt} pt >= 13.5`)
end
ok(Tag.MaxDistanceOther <= Tag.MaxDistanceOwn, "others' tags cull sooner than your own")
ok(Bubble.HeightRatio > 0 and Bubble.HeightRatio < 1, "bubble smaller than the tag")

print(`[manager-tags] {checks} checks passed`)
