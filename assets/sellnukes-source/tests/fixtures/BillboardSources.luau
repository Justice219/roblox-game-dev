--!strict
--[[
	BillboardSources — the BillboardPlacement.Sources the client builds at runtime
	(ProducerBillboards `sourcesOf`), loaded offline from the same files: every authored
	AreaLayouts.AreaNN, MeshAssets, WorldLayout.slotLocal and the ManagerNpcConfig rigs.
	Shared by tests/billboard-clearance.luau (the audit) and tools/billboards/generate-spots.luau
	(writes src/shared/Config/BillboardSpots.luau), so both solve exactly what the client would.

	Worlds (owner R57): `load(loader, worldId)` builds ONE world's sources. nil / "main" is Nuke
	Town, exactly as before (AreaLayouts, ManagerKeys, no roundBodies: Placement.RoundBodies
	applies). Any other world reads its WorldDef: the AreaNN files of `layoutFolder` (under
	src/shared/Config) for areas 1..WorldLayout.areaCount(worldId), a slotLocal bound to that world,
	`ManagerNpcConfig.managerKeysOf(worldId)` and `Placement.WorldRoundBodies[worldId]`.

	Example:
		local loader = Loader.new()
		local sources = BillboardSources.load(loader) -- Nuke Town
		local input = BillboardPlacement.areaInput(3, sources, false, Billboard, Placement)
		local dino = BillboardSources.load(loader, "dino") -- Dino Valley D1-D6
]]

local BillboardSources = {}

-- Owner R117: the client's prop boxes (Tycoon/BillboardProps), loaded through the same loader.
local function BillboardProps(loader: any): any
	return loader.load("src/client/Tycoon/BillboardProps")
end

-- Placement.SeeThrough (glass threshold) for the prop boxes.
local function SeeThrough(loader: any): number
	return loader.load("src/shared/Config/TycoonClientConfig").Placement.SeeThrough
end

--[[
	Loads the billboard solve sources of one world.
	@param loader a tests/fixtures/RobloxLoader instance
	@param worldId string? — nil / "main" = Nuke Town (unchanged); "dino", ... = that world (errors
	       on an unknown id or a missing layout file: the audit must never silently skip an area)
	@return BillboardPlacement.Sources (layouts keyed by area index)
	Example: BillboardSources.load(loader, "dino").layouts[6].producer.click.size --> (14, 16, 10)
]]
function BillboardSources.load(loader: any, worldId: string?): any
	local WorldLayout = loader.load("src/shared/Config/WorldLayout")
	local ManagerNpcConfig = loader.load("src/shared/Config/ManagerNpcConfig")
	if worldId == nil or worldId == "main" then
		local layouts: { [number]: any } = {}
		for area = 1, WorldLayout.AreaCount do
			layouts[area] = loader.load(string.format("src/shared/Config/AreaLayouts/Area%02d", area))
		end
		local meshAssets = loader.load("src/shared/Config/MeshAssets")
		return {
			layouts = layouts,
			meshAssets = meshAssets,
			slotLocal = WorldLayout.slotLocal,
			managerKeys = ManagerNpcConfig.ManagerKeys,
			rigs = ManagerNpcConfig.Rigs,
			-- Owner R117: the Order Window, AA tower slots, Mega Lever + Tip Jar (as the client).
			props = BillboardProps(loader).boxes("main", WorldLayout.slotLocal, meshAssets, SeeThrough(loader)),
		}
	end
	local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")
	local TycoonClientConfig = loader.load("src/shared/Config/TycoonClientConfig")
	local def = WorldsConfig.get(worldId)
	assert(def ~= nil, `BillboardSources: unknown world {worldId}`)
	local folder = "src/shared/Config/" .. table.concat(def.layoutFolder, "/")
	local layouts: { [number]: any } = {}
	for area = 1, WorldLayout.areaCount(worldId) do
		layouts[area] = loader.load(string.format("%s/Area%02d", folder, area))
	end
	-- Bound once: BillboardPlacement calls slotLocal(area) for this world's slots only.
	local id: string = worldId
	local meshAssets = loader.load("src/shared/Config/MeshAssets")
	local function slotLocal(area: number): any
		return WorldLayout.slotLocal(area, id)
	end
	return {
		layouts = layouts,
		meshAssets = meshAssets,
		slotLocal = slotLocal,
		managerKeys = ManagerNpcConfig.managerKeysOf(id),
		rigs = ManagerNpcConfig.Rigs,
		roundBodies = TycoonClientConfig.Placement.WorldRoundBodies[id],
		props = BillboardProps(loader).boxes(id, slotLocal, meshAssets, TycoonClientConfig.Placement.SeeThrough),
	}
end

return BillboardSources
