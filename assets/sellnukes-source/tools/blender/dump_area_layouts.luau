--!strict
--[[
	dump_area_layouts.luau — lune helper for tools/blender/check_area_overlaps.py: loads the REAL
	area layout modules (src/shared/Config/AreaLayouts/AreaNN.luau, through the test RobloxLoader)
	and writes every model placement of base + all builds as JSON:

		{ ["1"] = { { group = "base", key = "A1_Lot", index = 1, cf = {x, y, z, R00, R01, ... R22} }, ... } }

	cf components are CFrame:GetComponents() order (position, then the rotation matrix row by row),
	slot-local. Missing layout files are skipped.

	Worlds (owner R57, W7 2026-10-31): `--world <id>` right after <out.json> reads that world's
	layout folder (WorldsConfig.get(id).layoutFolder, e.g. Worlds/Dino/Layouts) and bounds the area
	index by the world's area count. Without the flag (or with `--world main`) nothing changes:
	AreaLayouts/AreaNN, areas 1..10, and WorldsConfig is never loaded.

	Usage (from the repo root):
		lune run tools/blender/dump_area_layouts.luau <out.json> 1 2 3
		lune run tools/blender/dump_area_layouts.luau <out.json> --world dino 1 2 3 4 5 6
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local Loader = require("../../tests/fixtures/RobloxLoader")

local out = process.args[1]
assert(type(out) == "string", "usage: dump_area_layouts.luau <out.json> [--world <id>] <area> [area ...]")

local loader = Loader.new()
local result: { [string]: { any } } = {}

-- Layout folder + area count of the requested world (main = today's AreaLayouts, 10 areas).
local first = 2
local layoutDir = "src/shared/Config/AreaLayouts"
local areaCount = 10
if process.args[2] == "--world" then
	local worldId = process.args[3]
	assert(type(worldId) == "string" and worldId ~= "", "usage: --world <id>")
	first = 4
	if worldId ~= "main" then
		local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")
		local def = WorldsConfig.get(worldId)
		assert(def ~= nil, `unknown world {worldId}`)
		layoutDir = "src/shared/Config/" .. table.concat(def.layoutFolder, "/")
		areaCount = #def.economy.Areas
	end
end

for i = first, #process.args do
	local area = tonumber(process.args[i])
	assert(area ~= nil and area >= 1 and area <= areaCount and area % 1 == 0, `bad area index {process.args[i]}`)
	local path = string.format("%s/Area%02d", layoutDir, area)
	if not fs.isFile(path .. ".luau") then
		continue
	end
	local layout = loader.load(path)
	local placements: { any } = {}
	--[[ Appends one build group's mesh placements (primitive placeholder boxes are skipped). ]]
	local function add(group: string, entry: any)
		for index, model in entry.models do
			if type(model.key) == "string" then
				table.insert(
					placements,
					{ group = group, key = model.key, index = index, cf = { model.cf:GetComponents() } }
				)
			end
		end
	end
	add("base", layout.base)
	for key, entry in layout.builds do
		add(key, entry)
	end
	result[tostring(area)] = placements
end

fs.writeFile(out, serde.encode("json", result, true))
