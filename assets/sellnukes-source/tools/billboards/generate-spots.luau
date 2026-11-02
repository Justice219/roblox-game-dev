--!strict
--[[
	generate-spots.luau — writes src/shared/Config/BillboardSpots.luau: the producer billboard spot
	of every area (desktop + device board size), solved offline by the SAME pure code the client
	runs (BillboardPlacement.areaInput -> choose, tests/fixtures/BillboardSources). The client
	then places every billboard with a table lookup (zero solve cost at join); it only solves at
	runtime for an area missing from the table.

	Worlds (owner R57): the file always holds EVERY world, deterministically — Nuke Town's areas
	1-10 as the top-level rows (byte-identical to the pre-worlds table) and every other world of
	WorldsConfig.Order under `worlds[worldId][area]`. So a regeneration never drops another world's
	rows, whichever world changed.

	tests/billboard-clearance.luau fails when the table is stale (a layout, mesh, manager or
	placement tunable changed): re-run this and commit the result.

	Run from the repo root:
		lune run tools/billboards/generate-spots.luau               writes the file; one summary line per world
		lune run tools/billboards/generate-spots.luau --world dino  writes the SAME file; also prints every
		                                                            spot of that world and exits 1 when one is
		                                                            not clear + inside-geometry-free + readable
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local Loader = require("../../tests/fixtures/RobloxLoader")
local BillboardSources = require("../../tests/fixtures/BillboardSources")

local loader = Loader.new()
local WorldLayout = loader.load("src/shared/Config/WorldLayout")
local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")
local TycoonClientConfig = loader.load("src/shared/Config/TycoonClientConfig")
local BillboardPlacement = loader.load("src/client/Tycoon/BillboardPlacement")

local OUT = "src/shared/Config/BillboardSpots.luau"

-- `--world <id>` / `--world=<id>`: the world whose spots are printed + asserted (all are written).
local focus: string? = nil
for i, arg in process.args do
	if arg == "--world" then
		focus = process.args[i + 1]
		assert(focus ~= nil, "generate-spots: --world needs a world id (e.g. --world dino)")
	elseif string.sub(arg, 1, 8) == "--world=" then
		focus = string.sub(arg, 9)
	end
end
if focus ~= nil then
	assert(WorldsConfig.get(focus) ~= nil, `generate-spots: unknown world "{focus}" (WorldsConfig.Order)`)
end

-- Shortest exact-enough decimal (4 places, trailing zeros dropped, never "-0").
local function num(x: number): string
	local text = string.format("%.4f", x):gsub("0+$", ""):gsub("%.$", "")
	return if text == "-0" then "0" else text
end

local function vec(v: any): string
	return `Vector3.new({num(v.X)}, {num(v.Y)}, {num(v.Z)})`
end

-- One solved area: the BillboardPlacement.Result per board size.
type AreaResult = { desktop: any, device: any }

--[[
	Solves every area of one world, desktop + device, exactly as the client would.
	@param worldId string — "main" or another WorldsConfig id
	@return { AreaResult } by area index (1..areaCount)
]]
local function solveWorld(worldId: string): { AreaResult }
	local sources = BillboardSources.load(loader, worldId)
	local rows: { AreaResult } = {}
	for area = 1, WorldLayout.areaCount(worldId) do
		local row = {} :: any
		for _, device in { false, true } do
			local input = BillboardPlacement.areaInput(
				area,
				sources,
				device,
				TycoonClientConfig.Billboard,
				TycoonClientConfig.Placement
			)
			assert(input ~= nil, `{worldId} Area{area}: no layout producer`)
			row[if device then "device" else "desktop"] = BillboardPlacement.choose(input)
		end
		rows[area] = row
	end
	return rows
end

--[[
	Appends one area's `[area] = { desktop = {...}, device = {...} },` block at `indent`. Nuke Town
	uses one tab (the pre-worlds layout, byte for byte); worlds nest three tabs deep.
]]
local function emitArea(lines: { string }, indent: string, area: number, row: AreaResult)
	table.insert(lines, `{indent}[{area}] = \{`)
	for _, device in { false, true } do
		local r = if device then row.device else row.desktop
		local inner = indent .. "\t\t"
		table.insert(lines, `{indent}\t{if device then "device" else "desktop"} = \{`)
		table.insert(lines, `{inner}position = {vec(r.position)},`)
		table.insert(lines, `{inner}side = {r.side},`)
		table.insert(lines, `{inner}right = {vec(r.right)},`)
		table.insert(lines, `{inner}family = "{r.family}",`)
		table.insert(lines, `{inner}clear = {r.clear},`)
		table.insert(lines, `{inner}readable = {r.readable},`)
		table.insert(lines, `{inner}slabClear = {r.slabClear},`)
		table.insert(lines, `{inner}blockedRays = {r.blockedRays},`)
		table.insert(lines, `{inner}elevation = {num(r.elevation)},`)
		table.insert(lines, `{inner}height = {num(r.height)},`)
		table.insert(lines, `{indent}\t},`)
	end
	table.insert(lines, `{indent}},`)
end

-- Solve every world once (in WorldsConfig.Order: deterministic output).
local solved: { [string]: { AreaResult } } = {}
for _, worldId in WorldsConfig.Order do
	solved[worldId] = solveWorld(worldId)
end
assert(solved.main ~= nil, "generate-spots: WorldsConfig.Order must contain main")

local lines = {
	"--!strict",
	"--[[",
	"\tBillboardSpots — GENERATED by tools/billboards/generate-spots.luau. Do not edit by hand: re-run",
	"\t`lune run tools/billboards/generate-spots.luau` after changing an area layout, a mesh, a manager",
	"\trig or a Placement / Billboard tunable (tests/billboard-clearance.luau fails while it is stale).",
	"",
	"\tThe producer billboard spot of every area in SLOT-LOCAL space (one answer for all 8 plots),",
	"\tfor the desktop and the phone / tablet / console board size, exactly as",
	"\tTycoon/BillboardPlacement.choose(areaInput(...)) returns it. ProducerBillboards maps it through",
	"\tthe plot's slot frame (world = WorldLayout.slotOrigin(plot, area) * position).",
	"",
	"\tWorlds (owner R57): Nuke Town's areas 1-10 are the top-level rows `BillboardSpots[area]`;",
	"\tevery other world of WorldsConfig.Order is `BillboardSpots.worlds[worldId][area]` (same Spot",
	"\tshape, same slot-local space: world = WorldLayout.slotOrigin(plot, area, worldId) * position).",
	"\tRead-only all the way down (deep-frozen).",
	"\tExample: (BillboardSpots.worlds.dino or {})[6].device.position --> D6's board, phone size",
	"]]",
	"",
	"export type Spot = {",
	"\tposition: Vector3, -- slot-local board centre",
	"\tside: number, -- +1 / -1: the viewer's right / left of the producer (income pops go there)",
	"\tright: Vector3, -- the viewer's right in slot space",
	'\tfamily: string, -- "above" | "side" | "fallback"',
	"\tclear: boolean,",
	"\treadable: boolean,",
	"\tslabClear: boolean,",
	"\tblockedRays: number,",
	"\televation: number,",
	"\theight: number,",
	"}",
	"",
	"-- One area: its spot per board size.",
	"export type AreaSpots = { desktop: Spot, device: Spot }",
	"",
	"-- [area] = Nuke Town; worlds[worldId][area] = every other world (WorldsConfig.Order).",
	"export type Spots = { [number]: AreaSpots, worlds: { [string]: { [number]: AreaSpots } } }",
	"",
	"local spots: Spots = {",
}
for area, row in solved.main do
	emitArea(lines, "\t", area, row)
end
table.insert(lines, "\tworlds = {")
for _, worldId in WorldsConfig.Order do
	if worldId ~= "main" then
		table.insert(lines, `\t\t{worldId} = \{`)
		for area, row in solved[worldId] do
			emitArea(lines, "\t\t\t", area, row)
		end
		table.insert(lines, "\t\t},")
	end
end
table.insert(lines, "\t},")
table.insert(lines, "}")
table.insert(lines, "")
table.insert(lines, "-- Freezes every nested table (rows, spots, worlds): callers copy what they need, never mutate.")
table.insert(lines, "local function deepFreeze(t: any): any")
table.insert(lines, "\tfor _, value in t do")
table.insert(lines, '\t\tif type(value) == "table" then')
table.insert(lines, "\t\t\tdeepFreeze(value)")
table.insert(lines, "\t\tend")
table.insert(lines, "\tend")
table.insert(lines, "\treturn table.freeze(t)")
table.insert(lines, "end")
table.insert(lines, "")
table.insert(lines, "return deepFreeze(spots) :: Spots")
fs.writeFile(OUT, table.concat(lines, "\n") .. "\n")
print(`[billboards] wrote {OUT}`)

-- Summary: one line per world; the focused world (--world) lists every spot and must be perfect.
local bad = 0
for _, worldId in WorldsConfig.Order do
	local problems: { string } = {}
	for area, row in solved[worldId] do
		for _, device in { false, true } do
			local r = if device then row.device else row.desktop
			local ok = r.clear and r.slabClear and r.readable
			local tag = `{worldId}:{area} {if device then "device" else "desktop"}`
			if worldId == focus then
				print(
					string.format(
						"  %-18s %-8s (%.1f, %.1f, %.1f) elev %.1f° rays %d%s",
						tag,
						r.family,
						r.position.X,
						r.position.Y,
						r.position.Z,
						r.elevation,
						r.blockedRays,
						if ok then "" else " NOT CLEAR / READABLE"
					)
				)
			end
			if not ok then
				table.insert(problems, tag)
			end
		end
	end
	print(
		`[billboards] {worldId}: {#solved[worldId]} areas, {if #problems == 0
			then "every spot clear + readable"
			else "NOT clear / readable: " .. table.concat(problems, ", ")}`
	)
	if worldId == focus then
		bad = #problems
	end
end
if bad > 0 then
	process.exit(1)
end
