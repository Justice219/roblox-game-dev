--!strict
--[[
	WorldLayout — the world's geometry contract: hub, the ring of 8 plots, the 10 area slots of a
	plot, and the CFrame helpers that turn plot-local / slot-local coordinates into world space.

	Purpose
		Art builders author every area in SLOT-LOCAL space (src/shared/Config/AreaLayouts/AreaNN.luau)
		and the hub in WORLD space (src/shared/Config/HubLayout.luau); PlotBuilder / HubBuilder
		(server) and the client (teleport, billboards, YOU marker) place everything through this
		module, so one plot rotation formula serves all 8 plots. Build plan "World layout".

	Frames (studs, +Y up, ground top at y = 0 everywhere)
		Hub         world origin; plaza radius 0..HubRadius (230), ring road HubRadius..PlotRadius (260).
		Plot i      origin = CFrame.Angles(0, (i-1) * 45°, 0) * CFrame.new(0, 0, 260): the entrance centre,
		            touching the ring road. Plot-local +Z points AWAY from the hub, +X is the player's right
		            when walking outward. Footprint x ∈ [-80, 80], z ∈ [0, 520]; central road x ∈ [-8, 8];
		            entrance arch + owner sign at z ≈ 4.
		Slot k      (area k lives in slot k, k = 1..10) row r = ceil(k / 2) covers z ∈ [(r-1)*104, r*104];
		            odd k = left side x ∈ [-80, -10], even k = right side x ∈ [10, 80].
		            Slot-local origin = the slot's road-side edge midpoint (x = ±10, z = (r - 0.5) * 104, y = 0).
		            +Z_s points AWAY from the road into the area, +Y up, and the frame is a pure Y rotation:
		              left  side: slot = CFrame.new(-10, 0, zc) * CFrame.Angles(0, -90°, 0)  (+X_s = plot +Z)
		              right side: slot = CFrame.new( 10, 0, zc) * CFrame.Angles(0,  90°, 0)  (+X_s = plot -Z)
		            So toward the hub is -X_s on the left side and +X_s on the right side; standing on the
		            road facing the area (+Z_s), +X_s is on your LEFT. Models face the road with their
		            front (-Z) as authored (identity rotation in slot space faces the road).
		            Slot extent x_s ∈ [-52, 52], z_s ∈ [0, 70]; height budget 80 (area 10: 140).
		            Pads sit in the road-side strip z_s ∈ [2, 16]; the producer in the middle.

	HubLayout contract (src/shared/Config/HubLayout.luau, written by the hub art builder; optional —
	HubBuilder builds a clean primitive hub until it exists). All CFrames in WORLD space:
		return {
			models = { { key = "MeshModelKey", cf = CFrame, tint = Color3?, castShadow = boolean? } },
			collision = { { size = Vector3, cf = CFrame } },   -- invisible primitive collision
			spawn = CFrame?,                                   -- hub spawn / TeleportHub target
		}
		(`base = { models, collision }` is accepted as an alias of the top-level lists.)

	Worlds (World 2 plan §3.1)
		Every world reuses this exact plot / slot contract around its own origin
		(`Shared/Config/Worlds/WorldGeometry`: Nuke Town at the identity with 10 areas, Dino Valley at
		(6000, 0, 0) with 6 areas and a 312-stud plot). Every helper takes an OPTIONAL trailing
		`worldId` — nil means Nuke Town, so every existing call is unchanged and bit-identical.
		`worldAt(position)` tells which world a point is in; `toWorld(worldId, cf)` places a
		world-local CFrame (the Valley's Base Camp layout); `areaCount` / `plotLength` per world.

	Connections
		* Geometry rows: Shared/Config/Worlds/WorldGeometry (no requires).
		* Server: World/PlotBuilder, World/HubBuilder, Tycoon/PlotService, Tycoon/TycoonService.
		* Client (B6): teleport targets, YOU marker, camera framing.
		* Tests: tests/area-layouts.luau (frames, bounds, every layout file).

	Usage
		local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)
		local cf = WorldLayout.slotToWorld(plotIndex, 3, CFrame.new(0, 0, 40))
		local entrance = WorldLayout.entranceSpawn(plotIndex)
		local dinoSlot = WorldLayout.slotToWorld(plotIndex, 2, CFrame.new(0, 0, 40), "dino")
]]

local WorldGeometry = require(script.Parent.Worlds.WorldGeometry)

local WorldLayout = {}

WorldLayout.PlotCount = 8
WorldLayout.AreaCount = 10

-- Hub plaza / ring road radii (studs). Plots start at PlotRadius.
WorldLayout.HubRadius = 230
WorldLayout.PlotRadius = 260
-- Radius of the decorative ground disc under everything (fills the wedges between plots).
WorldLayout.WorldRadius = 820

-- Plot footprint (plot-local): x ∈ [-PlotHalfWidth, PlotHalfWidth], z ∈ [0, PlotLength].
WorldLayout.PlotHalfWidth = 80
WorldLayout.PlotLength = 520
WorldLayout.RoadHalfWidth = 8
-- Entrance arch / owner sign distance from the plot origin.
WorldLayout.EntranceZ = 4

-- Area slots.
WorldLayout.RowLength = 104
WorldLayout.SlotRoadOffset = 10 -- |x| of the slot's road-side edge
WorldLayout.SlotHalfWidth = 52 -- x_s ∈ [-52, 52]
WorldLayout.SlotDepth = 70 -- z_s ∈ [0, 70]
WorldLayout.SlotHeight = 80
WorldLayout.SlotHeightFinale = 140 -- area 10
WorldLayout.PadStripMin = 2 -- pads sit in z_s ∈ [2, 16]
WorldLayout.PadStripMax = 16

-- Angle between neighbouring plots (radians).
WorldLayout.PlotYawStep = math.rad(360 / WorldLayout.PlotCount)

-- Worlds framework: one geometry row per world (origin, area count, plot length, finale height).
assert(WorldGeometry.RowLength == WorldLayout.RowLength, "WorldLayout: WorldGeometry.RowLength mismatch")
local MAIN_GEOMETRY = WorldGeometry.get("main") :: WorldGeometry.Geometry
assert(
	MAIN_GEOMETRY.areaCount == WorldLayout.AreaCount
		and MAIN_GEOMETRY.plotLength == WorldLayout.PlotLength
		and MAIN_GEOMETRY.finaleHeight == WorldLayout.SlotHeightFinale,
	"WorldLayout: the main geometry row must match the Nuke Town constants"
)

--[[
	The geometry row of a world; nil / "main" = Nuke Town. Errors on an unknown id (a programming
	bug, never player input: validate ids with WorldsConfig.get first).
	@param worldId string?
	@return Geometry
]]
local function geometryOf(worldId: string?): WorldGeometry.Geometry
	if worldId == nil then
		return MAIN_GEOMETRY
	end
	local geometry = WorldGeometry.get(worldId)
	if geometry == nil then
		error(`WorldLayout: unknown world {worldId}`)
	end
	return geometry
end

-- Plot origins per world, computed once on first use (8 CFrames per world; hot callers such as
-- billboards and PlotBuilder never rebuild the rotation). [worldId][plotIndex] = CFrame.
local plotOrigins: { [string]: { CFrame } } = {}

--[[
	World CFrame of plot `index`'s origin (entrance centre on the ring road, +Z away from the hub).
	In another world the same ring is placed relative to that world's origin.
	@param index number — 1..PlotCount (errors otherwise: a programming bug, not player input)
	@param worldId string? — nil / "main" = Nuke Town (unchanged), "dino", ...
	@return CFrame
	Example: WorldLayout.plotOrigin(1) --> CFrame.new(0, 0, 260)
	         WorldLayout.plotOrigin(1, "dino") --> CFrame.new(6000, 0, 260)
]]
function WorldLayout.plotOrigin(index: number, worldId: string?): CFrame
	assert(
		type(index) == "number" and index % 1 == 0 and index >= 1 and index <= WorldLayout.PlotCount,
		"WorldLayout.plotOrigin: bad plot index"
	)
	local geometry = geometryOf(worldId)
	local origins = plotOrigins[geometry.id]
	if origins == nil then
		origins = {}
		for plot = 1, WorldLayout.PlotCount do
			local ring = CFrame.Angles(0, (plot - 1) * WorldLayout.PlotYawStep, 0)
				* CFrame.new(0, 0, WorldLayout.PlotRadius)
			-- Nuke Town keeps today's exact CFrames (no multiplication by the identity origin).
			origins[plot] = if geometry.id == "main" then ring else geometry.origin * ring
		end
		plotOrigins[geometry.id] = origins
	end
	return origins[index]
end

--[[
	Plot-local CFrame of slot `area`'s origin (see the header for the axes). The slot frame is the
	same in every world; only the number of slots differs.
	@param area number — 1..areaCount of the world
	@param worldId string? — nil / "main" = Nuke Town
	@return CFrame
	Example: WorldLayout.slotLocal(1) --> CFrame.new(-10, 0, 52) * CFrame.Angles(0, -pi/2, 0)
]]
local function slotLocal(area: number, worldId: string?): CFrame
	local areaCount = geometryOf(worldId).areaCount
	assert(
		type(area) == "number" and area % 1 == 0 and area >= 1 and area <= areaCount,
		"WorldLayout.slotLocal: bad area index"
	)
	local row = math.ceil(area / 2)
	local zCentre = (row - 0.5) * WorldLayout.RowLength
	if area % 2 == 1 then
		return CFrame.new(-WorldLayout.SlotRoadOffset, 0, zCentre) * CFrame.Angles(0, -math.pi / 2, 0)
	end
	return CFrame.new(WorldLayout.SlotRoadOffset, 0, zCentre) * CFrame.Angles(0, math.pi / 2, 0)
end
-- Exposed as an overload so existing callers that store it as a `(area: number) -> CFrame`
-- callback (BillboardPlacement.Sources.slotLocal) keep type-checking; both forms are the same code.
WorldLayout.slotLocal = (slotLocal :: any) :: ((area: number) -> CFrame) & ((area: number, worldId: string?) -> CFrame)

--[[
	World CFrame of a slot's origin.
	@param plotIndex number — 1..8
	@param area number — 1..areaCount
	@param worldId string? — nil / "main" = Nuke Town
	@return CFrame
]]
function WorldLayout.slotOrigin(plotIndex: number, area: number, worldId: string?): CFrame
	return WorldLayout.plotOrigin(plotIndex, worldId) * WorldLayout.slotLocal(area, worldId)
end

--[[
	Converts a slot-local CFrame into world space.
	@param plotIndex number, area number
	@param localCFrame CFrame — slot-local (as written in AreaLayouts / Worlds/<Name>/Layouts)
	@param worldId string? — nil / "main" = Nuke Town
	@return CFrame
	Example: WorldLayout.slotToWorld(2, 1, CFrame.new(0, 0, 40)) -- area 1's middle in plot 2
]]
function WorldLayout.slotToWorld(plotIndex: number, area: number, localCFrame: CFrame, worldId: string?): CFrame
	return WorldLayout.slotOrigin(plotIndex, area, worldId) * localCFrame
end

--[[
	Converts a slot-local point into world space.
	@param plotIndex number, area number
	@param localPoint Vector3
	@param worldId string? — nil / "main" = Nuke Town
	@return Vector3
]]
function WorldLayout.slotPointToWorld(plotIndex: number, area: number, localPoint: Vector3, worldId: string?): Vector3
	return WorldLayout.slotOrigin(plotIndex, area, worldId) * localPoint
end

--[[
	Converts a plot-local CFrame into world space.
	@param plotIndex number
	@param localCFrame CFrame — plot-local
	@param worldId string? — nil / "main" = Nuke Town
	@return CFrame
]]
function WorldLayout.plotToWorld(plotIndex: number, localCFrame: CFrame, worldId: string?): CFrame
	return WorldLayout.plotOrigin(plotIndex, worldId) * localCFrame
end

--[[
	Where a player respawns on their plot: on the road just past the entrance arch, facing outward
	(down the road, toward their areas). Character pivot height is added by the caller.
	@param plotIndex number
	@param worldId string? — nil / "main" = Nuke Town
	@return CFrame — world CFrame at ground level
]]
function WorldLayout.entranceSpawn(plotIndex: number, worldId: string?): CFrame
	return WorldLayout.plotToWorld(
		plotIndex,
		CFrame.new(0, 0, WorldLayout.EntranceZ + 10) * CFrame.Angles(0, math.pi, 0),
		worldId
	)
end

--[[
	True when a slot-local point lies inside the slot footprint (optionally with a margin) and
	under the slot's height budget (the world's finale slot gets its taller budget). Used by layout
	validation and placeholder generation.
	@param area number
	@param point Vector3 — slot-local
	@param margin number? — studs of tolerance (default 0)
	@param worldId string? — nil / "main" = Nuke Town (finale = area 10); "dino": finale = area 6
	@return boolean
]]
function WorldLayout.inSlot(area: number, point: Vector3, margin: number?, worldId: string?): boolean
	local m = margin or 0
	local geometry = geometryOf(worldId)
	local height = if area == geometry.finaleArea then geometry.finaleHeight else WorldLayout.SlotHeight
	return math.abs(point.X) <= WorldLayout.SlotHalfWidth + m
		and point.Z >= -m
		and point.Z <= WorldLayout.SlotDepth + m
		and point.Y >= -4 - m
		and point.Y <= height + m
end

--[[
	Which plot (1..8) a world position is on, or nil (hub, ring road, wedges, outside).
	@param position Vector3 — world
	@param worldId string? — nil = Nuke Town's plots only (today's behaviour); "dino" = the Valley's
	       plots (their 312-stud length). Use WorldLayout.worldAt first when the world is unknown.
	@return number?
]]
function WorldLayout.plotAt(position: Vector3, worldId: string?): number?
	local plotLength = geometryOf(worldId).plotLength
	for index = 1, WorldLayout.PlotCount do
		local localPoint = WorldLayout.plotOrigin(index, worldId):PointToObjectSpace(position)
		if math.abs(localPoint.X) <= WorldLayout.PlotHalfWidth and localPoint.Z >= 0 and localPoint.Z <= plotLength then
			return index
		end
	end
	return nil
end

--[[
	Which world a position is in: the world whose scenery disc (horizontal distance from its
	origin <= sceneryRadius) contains it. Discs never overlap (WorldGeometry validates a 3000-stud
	gap), so at most one world matches.
	@param position Vector3 — world
	@return string? — "main", "dino", ... or nil (the void between worlds)
	Example: WorldLayout.worldAt(Vector3.new(6000, 5, 300)) --> "dino"
]]
function WorldLayout.worldAt(position: Vector3): string?
	for _, worldId in WorldGeometry.Order do
		local geometry = WorldGeometry.get(worldId) :: WorldGeometry.Geometry
		local origin = geometry.origin.Position
		local dx, dz = position.X - origin.X, position.Z - origin.Z
		if dx * dx + dz * dz <= geometry.sceneryRadius * geometry.sceneryRadius then
			return worldId
		end
	end
	return nil
end

--[[
	Converts a WORLD-LOCAL CFrame (relative to a world's origin, e.g. Worlds/Dino/ValleyLayout)
	into workspace space.
	@param worldId string — "main" (identity) / "dino" / ...
	@param worldLocal CFrame
	@return CFrame
	Example: WorldLayout.toWorld("dino", CFrame.new(0, 0, 0)) --> CFrame.new(6000, 0, 0)
]]
function WorldLayout.toWorld(worldId: string, worldLocal: CFrame): CFrame
	local geometry = geometryOf(worldId)
	if geometry.id == "main" then
		return worldLocal
	end
	return geometry.origin * worldLocal
end

--[[
	Number of areas (slots) a world's plot has.
	@param worldId string? — nil / "main" = Nuke Town (10)
	@return number
]]
function WorldLayout.areaCount(worldId: string?): number
	return geometryOf(worldId).areaCount
end

--[[
	Length (plot-local z extent) of a world's plot: 104 * ceil(areaCount / 2).
	@param worldId string? — nil / "main" = Nuke Town (520)
	@return number
]]
function WorldLayout.plotLength(worldId: string?): number
	return geometryOf(worldId).plotLength
end

--[[ The hub spawn when HubLayout gives none: plaza centre, facing plot 1. ]]
WorldLayout.DefaultHubSpawn = CFrame.new(0, 0, 0)

return table.freeze(WorldLayout)
