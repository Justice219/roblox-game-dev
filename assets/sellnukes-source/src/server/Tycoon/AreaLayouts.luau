--!strict
--[[
	AreaLayouts — resolves the layout every area of every world is built from (server runtime).

	Purpose
		Each area has an art-authored layout: Nuke Town's at ReplicatedStorage.Shared.Config.
		AreaLayouts.AreaNN, every other world's under its WorldDef.layoutFolder (Dino Valley:
		Shared.Config.Worlds.Dino.Layouts.AreaNN), all written by the art builders against the
		contract in Tycoon/LayoutLogic. Art lands area by area, in parallel with the server, so this
		module:
		  * uses the art file when it exists and validates (LayoutLogic.validate, partial mode, with
		    the world's slot geometry). Mesh keys are NOT checked here: a key whose meshes are not
		    synced into MeshAssets yet becomes a placeholder box (PlotBuilder, warned once) so the
		    rest of the art still shows; the strict mesh-key gate is tests/area-layouts.luau;
		  * fills anything the file leaves out (a build key, a pad, the producer, the spawn point)
		    from the generated placeholder (Tycoon/PlaceholderLayouts) and warns once, listing what;
		  * falls back to the full placeholder when the file is missing, errors, or is malformed
		    (warns once with the problems) — the plot is ALWAYS fully playable.
		Results are cached per server per (world, area) (layouts are static).

	Worlds (owner R57, plan §3.3): every function takes an optional trailing `worldId` (nil =
	"main", so every existing call is unchanged). Non-main worlds read their area configs and
	layout folder from WorldsConfig (required lazily: the main path never depends on it).
	`worldHub(worldId)` loads a non-main world's hub layout module (Dino: ValleyLayout) for the
	plot frames / locked slots PlotBuilder builds.

	Connections
		World/PlotBuilder builds from `get`; Tycoon/TycoonService preloads `meshKeys` and reads pad
		positions / spawn points; tests/area-layouts.luau validates the same files offline.

	Usage
		local layout = AreaLayouts.get(3)
		print(AreaLayouts.source(3)) --> "art" | "partial" | "placeholder"
		local d1 = AreaLayouts.get(1, "dino")
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LayoutLogic = require(script.Parent.LayoutLogic)
local PlaceholderLayouts = require(script.Parent.PlaceholderLayouts)
local TycoonConfig = require(ReplicatedStorage.Shared.Config.TycoonConfig)
local TycoonTypes = require(ReplicatedStorage.Shared.Tycoon.TycoonTypes)

type AreaLayout = LayoutLogic.AreaLayout

export type Source = "art" | "partial" | "placeholder"

local AreaLayouts = {}

-- The main world's id (a literal so the main path never requires the registry).
local MAIN = "main"

-- Per world: area index -> resolved layout / where it came from.
local cache: { [string]: { [number]: AreaLayout } } = {}
local sources: { [string]: { [number]: Source } } = {}
-- Per non-main world: its hub layout module result (false = missing / failed; resolved once).
local hubCache: { [string]: any } = {}

-- The registry, required on first non-main use.
local function registry(): any
	return require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)
end

-- The world definition of a non-main world (errors for an unknown id: a programming bug).
local function defOf(worldId: string): any
	local def = registry().get(worldId)
	assert(def ~= nil, `AreaLayouts: unknown world {worldId}`)
	return def
end

-- Walks a path of child names under ReplicatedStorage.Shared.Config ({"Worlds", "Dino", "Layouts"}).
local function configChild(path: { string }): Instance?
	local node: Instance? = ReplicatedStorage.Shared.Config
	for _, name in path do
		if node == nil then
			return nil
		end
		node = (node :: Instance):FindFirstChild(name)
	end
	return node
end

-- The economy areas of a world.
local function areasOf(worldId: string): { TycoonTypes.AreaConfig }
	if worldId == MAIN then
		return TycoonConfig.Areas
	end
	return defOf(worldId).economy.Areas
end

-- The art ModuleScript of an area of a world, or nil.
local function artModule(areaIndex: number, worldId: string): ModuleScript?
	local folder: Instance? = if worldId == MAIN
		then ReplicatedStorage.Shared.Config:FindFirstChild("AreaLayouts")
		else configChild(defOf(worldId).layoutFolder)
	local module = if folder ~= nil then folder:FindFirstChild(string.format("Area%02d", areaIndex)) else nil
	return if module ~= nil and module:IsA("ModuleScript") then module else nil
end

--[[
	The layout an area is built from (cached). Never errors for a valid area index of a known world.
	@param areaIndex number — 1..that world's area count (Nuke Town 10, Dino Valley 6)
	@param worldId string? — R57: nil = Nuke Town
	@return AreaLayout
	Example: AreaLayouts.get(2, "dino").pads.d2_leaf_awning
]]
function AreaLayouts.get(areaIndex: number, worldId: string?): AreaLayout
	local world = worldId or MAIN
	local perWorld = cache[world]
	local cached = if perWorld ~= nil then perWorld[areaIndex] else nil
	if cached ~= nil then
		return cached
	end
	local area = assert(areasOf(world)[areaIndex], "AreaLayouts.get: bad area index")
	-- Messages name the world for non-main areas ("dino Area03").
	local label = if world == MAIN then `Area{areaIndex}` else `{world} Area{areaIndex}`
	local placeholder = PlaceholderLayouts.generate(areaIndex, world)
	local layout: AreaLayout = placeholder
	local source: Source = "placeholder"
	local module = artModule(areaIndex, world)
	if module ~= nil then
		local ok, authored = pcall(require, module)
		if not ok then
			warn(`[AreaLayouts] {label}: layout failed to load ({authored}); using the placeholder`)
		else
			local problems = LayoutLogic.validate(authored, area, nil, true, world)
			if #problems > 0 then
				warn(
					`[AreaLayouts] {label}: layout has {#problems} problem(s); using the placeholder:\n  `
						.. table.concat(problems, "\n  ", 1, math.min(#problems, 12))
				)
			else
				local merged, filled = LayoutLogic.merge(authored, placeholder)
				layout = merged
				if #filled > 0 then
					source = "partial"
					warn(
						`[AreaLayouts] {label}: {#filled} part(s) not authored yet, using placeholders: `
							.. table.concat(filled, ", ", 1, math.min(#filled, 12))
					)
				else
					source = "art"
				end
			end
		end
	end
	if perWorld == nil then
		perWorld = {}
		cache[world] = perWorld
		sources[world] = {}
	end
	(perWorld :: { [number]: AreaLayout })[areaIndex] = layout
	sources[world][areaIndex] = source
	return layout
end

--[[ Where an area's layout came from ("art", "partial" or "placeholder"). ]]
function AreaLayouts.source(areaIndex: number, worldId: string?): Source
	AreaLayouts.get(areaIndex, worldId)
	return sources[worldId or MAIN][areaIndex]
end

--[[
	Every mesh key an area's layout uses (base + all builds), deduplicated — for MeshLibrary.preload
	before a plot is built, so spawning never stalls mid-build.
	@param areaIndex number
	@param worldId string? — nil = Nuke Town
	@return {string}
]]
function AreaLayouts.meshKeys(areaIndex: number, worldId: string?): { string }
	local layout = AreaLayouts.get(areaIndex, worldId)
	local seen: { [string]: boolean } = {}
	local keys: { string } = {}
	local function collect(entry: LayoutLogic.BuildEntry)
		for _, model in entry.models do
			local key = model.key
			if key ~= nil and not seen[key] then
				seen[key] = true
				table.insert(keys, key)
			end
		end
	end
	collect(layout.base)
	for _, entry in layout.builds do
		collect(entry)
	end
	return keys
end

--[[
	The hub layout table of a NON-main world (WorldDef.hubLayout; Dino Valley: ValleyLayout,
	WORLD-LOCAL, same shape as HubLayout), or nil while the module is missing / fails to load
	(warned once). Read by PlotBuilder for that world's `plotFrame` / `lockedSlot` / `plotColors`.
	Nuke Town's hub layout is HubBuilder.layout() (unchanged); this returns nil for "main".
	@param worldId string
	@return any
]]
function AreaLayouts.worldHub(worldId: string): any
	if worldId == MAIN then
		return nil
	end
	local cached = hubCache[worldId]
	if cached ~= nil then
		return if cached == false then nil else cached
	end
	local module = configChild(defOf(worldId).hubLayout)
	local result: any = false
	if module ~= nil and module:IsA("ModuleScript") then
		local ok, layout = pcall(require, module)
		if ok and type(layout) == "table" then
			result = layout
		else
			warn(`[AreaLayouts] {worldId} hub layout failed to load ({layout}); placeholder plot frames`)
		end
	end
	hubCache[worldId] = result
	return if result == false then nil else result
end

--[[ The area count of a world (Nuke Town 10, Dino Valley 6). ]]
function AreaLayouts.areaCount(worldId: string?): number
	return #areasOf(worldId or MAIN)
end

return AreaLayouts
