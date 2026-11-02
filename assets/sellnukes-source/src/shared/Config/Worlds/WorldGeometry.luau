--!strict
--[[
	WorldGeometry — where every world sits and how big it is (World 2 plan §3.1, spec §3 / §5).

	Purpose
		Pure geometry rows, one per world, with NO requires: `Shared/Config/WorldLayout` depends on
		this module to place plots / slots in any world, and every economy-free system (streaming,
		travel, scenery, QA) can read it without loading an economy.

		Every world reuses Nuke Town's plot contract unchanged (WorldLayout header): 8 plots on a
		ring at yaw (i-1)·45°, origin radius 260, slot frame / size (104 × 70), pad strip, height
		budget 80 and a taller finale slot. Only the world origin, the number of areas (so the plot
		length = 104 × ceil(areaCount / 2)), the boundary and the scenery radius differ.

	Rows (studs)
		id      origin                  areas  plotLength  finale (area / height)  boundary  scenery
		main    CFrame.identity          10      520         10 / 140                880       2000
		dino    CFrame.new(6000, 0, 0)    6      312          6 / 140                650        950
		moon    CFrame.new(-6000, 0, 0)   6      312          6 / 140                650        950
		* boundaryRadius — the invisible collision ring (Nuke Town: the wall at r 880 past the beach;
		  Dino Valley: the collision ring at r 650 behind the cliffs at r 640).
		* sceneryRadius — the farthest scenery of the world (Nuke Town's sea to r 2000; the Valley's
		  far hills to r ~950; Moon Base's crater ridges to r ~950). Two worlds' scenery discs must stay
		  >= MinSeparation (3000) apart (main–dino and main–moon 3050, dino–moon 10100), so a
		  client streaming one world (StreamingTargetRadius 768) never streams the other.

	Load-time validation: ids unique and in Order, plotLength matches the area count, finale is the
	last area, radii positive, every pair of worlds' scenery discs >= MinSeparation apart.

	Adding World 3 (spec §18 step 1): add a row + its id to Order; tests/world-frames.luau checks it.

	Usage
		local WorldGeometry = require(ReplicatedStorage.Shared.Config.Worlds.WorldGeometry)
		local dino = WorldGeometry.get("dino")
		print(dino.origin.Position, dino.plotLength) --> 6000, 0, 0   312
]]

export type Geometry = {
	id: string,
	origin: CFrame, -- world origin: the hub / Base Camp centre, ground top at y = 0
	areaCount: number,
	plotLength: number, -- 104 * ceil(areaCount / 2)
	finaleArea: number, -- the slot with the taller height budget (always the last area)
	finaleHeight: number,
	boundaryRadius: number,
	sceneryRadius: number,
}

local WorldGeometry = {}

-- Length of one plot row (two slots side by side). Must equal WorldLayout.RowLength.
WorldGeometry.RowLength = 104

-- Smallest allowed gap between two worlds' scenery discs (spec §3: >> 2 x StreamingTargetRadius 768).
WorldGeometry.MinSeparation = 3000

-- Every world, in display order (WorldsConfig.Order must list the same ids in the same order).
WorldGeometry.Order = table.freeze({ "main", "dino", "moon" }) :: { string }

local ROWS: { [string]: Geometry } = {
	main = {
		id = "main",
		origin = CFrame.identity,
		areaCount = 10,
		plotLength = 520,
		finaleArea = 10,
		finaleHeight = 140,
		boundaryRadius = 880,
		sceneryRadius = 2000,
	},
	dino = {
		id = "dino",
		origin = CFrame.new(6000, 0, 0),
		areaCount = 6,
		plotLength = 312,
		finaleArea = 6,
		finaleHeight = 140,
		boundaryRadius = 650,
		sceneryRadius = 950,
	},
	-- R70 World 3 Moon Base: the mirror of the Valley on the other side of Nuke Town.
	moon = {
		id = "moon",
		origin = CFrame.new(-6000, 0, 0),
		areaCount = 6,
		plotLength = 312,
		finaleArea = 6,
		finaleHeight = 140,
		boundaryRadius = 650,
		sceneryRadius = 950,
	},
}

--[[
	The geometry row of a world.
	@param worldId any — world id (untrusted input is fine: non-strings / unknown ids -> nil)
	@return Geometry?
	Example: WorldGeometry.get("main").plotLength --> 520
]]
function WorldGeometry.get(worldId: any): Geometry?
	if type(worldId) ~= "string" then
		return nil
	end
	return ROWS[worldId]
end

--[[
	Horizontal (XZ) distance between two worlds' origins minus both scenery radii: the empty gap
	between their scenery discs. Negative means they overlap.
	@param a Geometry, b Geometry
	@return number — studs
	Example: WorldGeometry.gap(get("main"), get("dino")) --> 6000 - 2000 - 950 = 3050
]]
function WorldGeometry.gap(a: Geometry, b: Geometry): number
	local delta = b.origin.Position - a.origin.Position
	local horizontal = math.sqrt(delta.X * delta.X + delta.Z * delta.Z)
	return horizontal - a.sceneryRadius - b.sceneryRadius
end

-- Load-time validation (a broken row is a config bug: fail loudly in Studio and the lune tests).
do
	local seen: { [string]: boolean } = {}
	for _, id in WorldGeometry.Order do
		local row = ROWS[id]
		assert(row ~= nil and row.id == id and not seen[id], `WorldGeometry: bad or duplicate row {id}`)
		seen[id] = true
		assert(row.areaCount >= 1 and row.areaCount % 1 == 0, `WorldGeometry: {id}.areaCount`)
		assert(
			row.plotLength == WorldGeometry.RowLength * math.ceil(row.areaCount / 2),
			`WorldGeometry: {id}.plotLength must be 104 * ceil(areaCount / 2)`
		)
		assert(row.finaleArea == row.areaCount, `WorldGeometry: {id}.finaleArea must be the last area`)
		assert(row.finaleHeight > 0 and row.boundaryRadius > 0, `WorldGeometry: {id} radii / heights`)
		assert(row.sceneryRadius >= row.boundaryRadius, `WorldGeometry: {id}.sceneryRadius < boundaryRadius`)
	end
	for id in ROWS do
		assert(seen[id], `WorldGeometry: row {id} missing from Order`)
	end
	for i, idA in WorldGeometry.Order do
		for j = i + 1, #WorldGeometry.Order do
			local idB = WorldGeometry.Order[j]
			assert(
				WorldGeometry.gap(ROWS[idA], ROWS[idB]) >= WorldGeometry.MinSeparation,
				`WorldGeometry: {idA} and {idB} scenery discs closer than {WorldGeometry.MinSeparation} studs`
			)
		end
	end
	for _, row in ROWS do
		table.freeze(row)
	end
	table.freeze(ROWS)
end

return table.freeze(WorldGeometry)
