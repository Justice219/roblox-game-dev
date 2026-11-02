--!strict
--[[
	ArtWorlds — the worlds whose art the art regression suites audit (owner R57 worlds framework,
	W6 art-d12 2026-10-31). Used by tests/zfight-audit.luau, tests/glow-budget.luau and
	tests/mesh-assets.luau so every art builder of every world is gated by the same three suites.

	Source of truth: `WorldsConfig.Order` (src/shared/Config/Worlds/WorldsConfig.luau, W1). Each
	WorldDef names its layout folder (`layoutFolder`, under ReplicatedStorage.Shared.Config) and its
	hub layout module (`hubLayout`). Until the registry exists the main world is the only one, with
	today's paths (AreaLayouts/AreaNN + HubLayout), so the suites never depend on build order.

	Layout resolution (`ArtWorlds.areaLayout`) mirrors what the server builds (Tycoon/AreaLayouts.get):
	  * main: the authored file merged with its generated placeholder when the file validates
	    (partial), the placeholder alone otherwise (the runtime falls back the same way);
	  * other worlds: the same merge with that world's placeholder (PlaceholderLayouts.generate(area,
	    worldId), LayoutLogic.validate(..., worldId)), but an authored file that does not validate is
	    returned as problems instead of silently replaced, so the suites fail on it. A missing file
	    builds the placeholder, like the runtime.

	Owners (who placed a piece, for offender lists): main areas 1-3 B8a, 4-6 B8b, 7-8 B8c, 9-10 B8d,
	hub / frame B8e; Dino areas 1-2 W6, 3-4 W7, 5-6 W8, Base Camp / frame W9; Moon areas 1-2 W6,
	3-4 W7, 5-6 W8, Moon hub / frame W9b; any later world "<id>-art". BuyPads and placeholder blocks are always "B3".

	Example:
		local Loader = require("./fixtures/RobloxLoader")
		local ArtWorlds = require("./fixtures/ArtWorlds")
		local loader = Loader.new()
		for _, world in ArtWorlds.list(loader) do
			for area = 1, world.areaCount do
				local layout, problems = ArtWorlds.areaLayout(loader, world, area)
				if layout ~= nil then print(world.id, area, #layout.base.models) end
			end
		end
]]

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

export type World = {
	id: string,
	isMain: boolean,
	-- Folder of the world's AreaNN.luau files, e.g. "src/shared/Config/Worlds/Dino/Layouts".
	layoutDir: string,
	-- The world's hub layout module path WITHOUT ".luau" (nil when the file does not exist yet).
	hubPath: string?,
	-- EconomyIndex of the world (Areas, PadsById, PadIndex, PadOrder; TycoonConfig for main).
	economy: any,
	areaCount: number,
	-- The world's origin (WorldGeometry; identity for main). Hub layouts of non-main worlds are
	-- relative to it, WorldLayout.plotOrigin(plot, id) is not.
	origin: any,
	-- Who placed an area's art / the hub + plot frame (offender attribution).
	areaOwner: (area: number) -> string,
	hubOwner: string,
}

local ArtWorlds = {}

-- Module root that WorldDef.layoutFolder / hubLayout paths are relative to.
local CONFIG_ROOT = "src/shared/Config"
local WORLDS_CONFIG = `{CONFIG_ROOT}/Worlds/WorldsConfig`

-- Builder roles per world: one owner per pair of areas (plan §1) and the hub builder.
local AREA_OWNERS: { [string]: { string } } = {
	main = { "B8a", "B8a", "B8a", "B8b", "B8b", "B8b", "B8c", "B8c", "B8d", "B8d" },
	dino = { "W6", "W6", "W7", "W7", "W8", "W8" },
	moon = { "W6", "W6", "W7", "W7", "W8", "W8" }, -- R70 Moon Base (spec 2026-10-31-r69 §4)
}
local HUB_OWNERS: { [string]: string } = { main = "B8e", dino = "W9", moon = "W9b" }

--[[
	Builds one World row.
	@param id string — world id ("main", "dino", ...)
	@param isMain boolean
	@param layoutDir string — folder of AreaNN.luau
	@param hubModule string — hub layout module path without ".luau"
	@param economy any — EconomyIndex
	@param origin CFrame — world origin
	@return World
]]
local function row(id: string, isMain: boolean, layoutDir: string, hubModule: string, economy: any, origin: any): World
	local owners = AREA_OWNERS[id]
	return {
		id = id,
		isMain = isMain,
		layoutDir = layoutDir,
		hubPath = if fs.isFile(hubModule .. ".luau") then hubModule else nil,
		economy = economy,
		areaCount = #economy.Areas,
		origin = origin,
		areaOwner = function(area: number): string
			return if owners ~= nil and owners[area] ~= nil then owners[area] else `{id}-art`
		end,
		hubOwner = HUB_OWNERS[id] or `{id}-art`,
	}
end

--[[
	Every world in WorldsConfig.Order (main first), or just main before the registry exists.
	@param loader RobloxLoader
	@return {World}
]]
function ArtWorlds.list(loader: any): { World }
	if not fs.isFile(WORLDS_CONFIG .. ".luau") then
		local TycoonConfig = loader.load(`{CONFIG_ROOT}/TycoonConfig`)
		return {
			row(
				"main",
				true,
				`{CONFIG_ROOT}/AreaLayouts`,
				`{CONFIG_ROOT}/HubLayout`,
				TycoonConfig,
				roblox.CFrame.new()
			),
		}
	end
	local WorldsConfig = loader.load(WORLDS_CONFIG)
	local worlds: { World } = {}
	for _, id in WorldsConfig.Order do
		local def = WorldsConfig.Worlds[id]
		assert(def ~= nil, `WorldsConfig.Order names unknown world {id}`)
		table.insert(
			worlds,
			row(
				id,
				id == WorldsConfig.MAIN,
				`{CONFIG_ROOT}/{table.concat(def.layoutFolder, "/")}`,
				`{CONFIG_ROOT}/{table.concat(def.hubLayout, "/")}`,
				def.economy,
				def.geometry.origin
			)
		)
	end
	assert(#worlds > 0 and worlds[1].isMain, "WorldsConfig.Order starts with the main world")
	return worlds
end

--[[
	The layout area `area` of `world` is built from (see the header for the per-world rules).
	@param loader RobloxLoader
	@param world World
	@param area number — 1..world.areaCount
	@return (any?, {string}) — the layout (nil = nothing authored yet in a non-main world) and the
	        validation problems of an authored non-main file (non-empty = the suite must fail)
]]
function ArtWorlds.areaLayout(loader: any, world: World, area: number): (any?, { string })
	local LayoutLogic = loader.load("src/server/Tycoon/LayoutLogic")
	local PlaceholderLayouts = loader.load("src/server/Tycoon/PlaceholderLayouts")
	local path = string.format("%s/Area%02d", world.layoutDir, area)
	local exists = fs.isFile(path .. ".luau")
	local config = world.economy.Areas[area]
	-- Main keeps today's calls exactly (nil world); other worlds pass their id (W3 made
	-- PlaceholderLayouts.generate / LayoutLogic.validate world-aware: geometry + Areas per world).
	local worldArg: string? = if world.isMain then nil else world.id
	local placeholder = PlaceholderLayouts.generate(area, worldArg)
	if not exists then
		return placeholder, {}
	end
	local authored = loader.load(path)
	local problems = LayoutLogic.validate(authored, config, nil, true, worldArg)
	if #problems > 0 then
		-- Main falls back silently like the runtime; another world's broken file fails the suites.
		return if world.isMain then placeholder else nil, if world.isMain then {} else problems
	end
	return (LayoutLogic.merge(authored, placeholder)), {}
end

--[[
	Every model placement of a fully built area (base + every build group), in slot-local space.
	@param layout any — an AreaLayout
	@return {{ key: string?, cf: CFrame, box: Vector3?, shape: string?, material: string?, group: string }}
]]
function ArtWorlds.placements(layout: any): { any }
	local out = {}
	local function add(group: string, entry: any)
		for _, model in entry.models or {} do
			table.insert(out, {
				key = model.key,
				cf = model.cf,
				box = model.box,
				shape = model.shape,
				material = model.material,
				group = group,
			})
		end
	end
	add("base", layout.base)
	for key, entry in layout.builds do
		add(key, entry)
	end
	return out
end

return ArtWorlds
