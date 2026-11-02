--!strict
--[[
	World frames (World 2 plan §4 W1.4, §5 "world-frames"): the world-aware WorldLayout.

	Proves
		1. MAIN PARITY: every WorldLayout helper called without a worldId (and with "main") returns
		   exactly what the pre-framework formulas returned (re-implemented below from the shipped
		   module) for all 8 plots x 10 areas — component-for-component equal CFrames.
		2. Every world's frames round-trip for all 8 plots x every area: slot-local -> world ->
		   plotAt / worldAt -> back to slot-local; plots sit at the world's origin; slot frames are the
		   same contract in every world; plots fit inside the world's boundary.
		3. Separation: no two worlds' scenery discs come within WorldGeometry.MinSeparation (3000).
		4. `worldAt` is correct (origins, disc edges, the void between worlds); `toWorld`,
		   `areaCount`, `plotLength`, per-world finale heights in `inSlot`; unknown worlds and
		   out-of-range areas error.

	Run: lune run tests/world-frames.luau            (from the repo root)
]]

local Loader = require("./fixtures/RobloxLoader")
local roblox = require("@lune/roblox")

local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3

local loader = Loader.new()
local WorldLayout = loader.load("src/shared/Config/WorldLayout")
local WorldGeometry = loader.load("src/shared/Config/Worlds/WorldGeometry")
local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")

local checks = 0
local function check(ok: boolean, message: string)
	assert(ok, message)
	checks += 1
end

-- Exact CFrame equality (all 12 components).
local function same(a: any, b: any): boolean
	local ca = { a:GetComponents() }
	local cb = { b:GetComponents() }
	for i = 1, 12 do
		if ca[i] ~= cb[i] then
			return false
		end
	end
	return true
end

-- Near CFrame equality. Roblox CFrames are single precision: at the Valley's 6000-stud offset one
-- float step is ~0.0005 studs, so world-space round trips are compared at ROUND_TRIP (5 mm).
local ROUND_TRIP = 5e-3
local function close(a: any, b: any, eps: number?): boolean
	local ca = { a:GetComponents() }
	local cb = { b:GetComponents() }
	for i = 1, 12 do
		if math.abs(ca[i] - cb[i]) > (eps or 1e-6) then
			return false
		end
	end
	return true
end

--------------------------------------------------------------------------------------------------
-- 1. Main parity against the shipped formulas
--------------------------------------------------------------------------------------------------
do
	-- The pre-framework WorldLayout maths, verbatim.
	local function oldPlotOrigin(index: number): any
		return CFrame.Angles(0, (index - 1) * math.rad(360 / 8), 0) * CFrame.new(0, 0, 260)
	end
	local function oldSlotLocal(area: number): any
		local row = math.ceil(area / 2)
		local zCentre = (row - 0.5) * 104
		if area % 2 == 1 then
			return CFrame.new(-10, 0, zCentre) * CFrame.Angles(0, -math.pi / 2, 0)
		end
		return CFrame.new(10, 0, zCentre) * CFrame.Angles(0, math.pi / 2, 0)
	end
	local function oldInSlot(area: number, point: any, margin: number?): boolean
		local m = margin or 0
		local height = if area == 10 then 140 else 80
		return math.abs(point.X) <= 52 + m
			and point.Z >= -m
			and point.Z <= 70 + m
			and point.Y >= -4 - m
			and point.Y <= height + m
	end
	local function oldPlotAt(position: any): number?
		for index = 1, 8 do
			local localPoint = oldPlotOrigin(index):PointToObjectSpace(position)
			if math.abs(localPoint.X) <= 80 and localPoint.Z >= 0 and localPoint.Z <= 520 then
				return index
			end
		end
		return nil
	end

	local sample = CFrame.new(3, 2, 40) * CFrame.Angles(0, 0.3, 0)
	for plot = 1, 8 do
		check(same(WorldLayout.plotOrigin(plot), oldPlotOrigin(plot)), `main plotOrigin({plot})`)
		check(same(WorldLayout.plotOrigin(plot, "main"), oldPlotOrigin(plot)), `"main" plotOrigin({plot})`)
		local spawn = oldPlotOrigin(plot) * (CFrame.new(0, 0, 14) * CFrame.Angles(0, math.pi, 0))
		check(same(WorldLayout.entranceSpawn(plot), spawn), `main entranceSpawn({plot})`)
		check(same(WorldLayout.plotToWorld(plot, sample), oldPlotOrigin(plot) * sample), `main plotToWorld({plot})`)
		for area = 1, 10 do
			local slotOld = oldPlotOrigin(plot) * oldSlotLocal(area)
			check(same(WorldLayout.slotLocal(area), oldSlotLocal(area)), `main slotLocal({area})`)
			check(same(WorldLayout.slotOrigin(plot, area), slotOld), `main slotOrigin({plot}, {area})`)
			check(same(WorldLayout.slotToWorld(plot, area, sample), slotOld * sample), `main slotToWorld`)
			check(same(WorldLayout.slotToWorld(plot, area, sample, "main"), slotOld * sample), `"main" slotToWorld`)
			local point = Vector3.new(5, 1, 30)
			check(WorldLayout.slotPointToWorld(plot, area, point) == slotOld * point, `main slotPointToWorld`)
		end
	end
	for area = 1, 10 do
		for _, point in
			{ Vector3.new(0, 79, 30), Vector3.new(0, 120, 30), Vector3.new(53, 0, 10), Vector3.new(0, 0, 71) }
		do
			check(WorldLayout.inSlot(area, point) == oldInSlot(area, point), `main inSlot({area})`)
			check(WorldLayout.inSlot(area, point, 2) == oldInSlot(area, point, 2), `main inSlot margin`)
		end
	end
	for x = -900, 900, 37 do
		for z = -900, 900, 41 do
			local position = Vector3.new(x, 3, z)
			check(WorldLayout.plotAt(position) == oldPlotAt(position), `main plotAt({x}, {z})`)
		end
	end
	check(WorldLayout.AreaCount == 10 and WorldLayout.PlotLength == 520, "main constants unchanged")
	check(WorldLayout.areaCount() == 10 and WorldLayout.plotLength() == 520, "main areaCount / plotLength")
end

--------------------------------------------------------------------------------------------------
-- 2. Every world's frames round-trip
--------------------------------------------------------------------------------------------------
do
	check(#WorldGeometry.Order == #WorldsConfig.Order, "one geometry row per world")
	for index, worldId in WorldsConfig.Order do
		check(WorldGeometry.Order[index] == worldId, `WorldGeometry.Order[{index}] == {worldId}`)
	end
	for _, worldId in WorldGeometry.Order do
		local geometry = WorldGeometry.get(worldId)
		local origin = geometry.origin
		check(WorldLayout.areaCount(worldId) == geometry.areaCount, `{worldId} areaCount`)
		check(WorldLayout.plotLength(worldId) == 104 * math.ceil(geometry.areaCount / 2), `{worldId} plotLength`)
		check(same(WorldLayout.toWorld(worldId, CFrame.new()), origin), `{worldId} toWorld(identity) = origin`)
		local farthest = 0
		for plot = 1, 8 do
			-- The ring is the Nuke Town ring moved to the world's origin.
			local plotCf = WorldLayout.plotOrigin(plot, worldId)
			check(
				close(plotCf, origin * WorldLayout.plotOrigin(plot), ROUND_TRIP),
				`{worldId} plot {plot} = origin * ring`
			)
			check(WorldLayout.worldAt(plotCf.Position) == worldId, `{worldId} plot {plot} origin is in the world`)
			for _, corner in { Vector3.new(-80, 0, geometry.plotLength), Vector3.new(80, 0, geometry.plotLength) } do
				local p = plotCf * corner - origin.Position
				farthest = math.max(farthest, math.sqrt(p.X * p.X + p.Z * p.Z))
			end
			for area = 1, geometry.areaCount do
				-- Same slot frame contract in every world.
				check(
					same(WorldLayout.slotLocal(area, worldId), WorldLayout.slotLocal(area)),
					`{worldId} slotLocal({area})`
				)
				local slotCf = WorldLayout.slotOrigin(plot, area, worldId)
				check(
					close(slotCf, plotCf * WorldLayout.slotLocal(area), ROUND_TRIP),
					`{worldId} slotOrigin({plot}, {area})`
				)
				for _, localCf in { CFrame.new(0, 0, 1), CFrame.new(-40, 10, 35), CFrame.new(40, 2, 68) } do
					local worldCf = WorldLayout.slotToWorld(plot, area, localCf, worldId)
					check(
						close(slotCf:ToObjectSpace(worldCf), localCf, ROUND_TRIP),
						`{worldId} round trip {plot}/{area}`
					)
					check(WorldLayout.plotAt(worldCf.Position, worldId) == plot, `{worldId} plotAt {plot}/{area}`)
					check(WorldLayout.worldAt(worldCf.Position) == worldId, `{worldId} worldAt {plot}/{area}`)
					local point = WorldLayout.slotPointToWorld(plot, area, localCf.Position, worldId)
					check((point - worldCf.Position).Magnitude < ROUND_TRIP, `{worldId} slotPointToWorld`)
				end
			end
			local spawn = WorldLayout.entranceSpawn(plot, worldId)
			check(WorldLayout.plotAt(spawn.Position, worldId) == plot, `{worldId} spawn on plot {plot}`)
			check(
				close(
					WorldLayout.plotToWorld(plot, CFrame.new(1, 2, 3), worldId),
					plotCf * CFrame.new(1, 2, 3),
					ROUND_TRIP
				),
				"p2w"
			)
		end
		check(
			farthest <= geometry.boundaryRadius,
			`{worldId} plots ({farthest}) fit inside r {geometry.boundaryRadius}`
		)
		-- The world's finale slot gets its taller height budget; other slots keep 80.
		local tall = Vector3.new(0, geometry.finaleHeight - 1, 30)
		check(WorldLayout.inSlot(geometry.finaleArea, tall, 0, worldId), `{worldId} finale height`)
		check(not WorldLayout.inSlot(1, tall, 0, worldId), `{worldId} normal slot height 80`)
		check(not pcall(WorldLayout.slotLocal, geometry.areaCount + 1, worldId), `{worldId} area out of range`)
	end
	-- The Valley's finale is slot 6; in Nuke Town slot 6 is a normal slot.
	check(WorldLayout.inSlot(6, Vector3.new(0, 139, 30), 0, "dino"), "D6 height 140")
	check(not WorldLayout.inSlot(6, Vector3.new(0, 139, 30)), "Nuke Town area 6 height 80")
	check(same(WorldLayout.plotOrigin(1, "dino"), CFrame.new(6000, 0, 260)), "dino plot 1 at (6000, 0, 260)")
	check(not pcall(WorldLayout.plotOrigin, 1, "nope"), "unknown world errors")
	check(not pcall(WorldLayout.plotOrigin, 9, "dino"), "bad plot index errors")
	check(not pcall(WorldLayout.toWorld, "nope", CFrame.new()), "toWorld unknown world errors")
	-- Nuke Town plotAt without a worldId never finds a Valley plot.
	check(WorldLayout.plotAt(WorldLayout.entranceSpawn(1, "dino").Position) == nil, "main plotAt ignores dino")
end

--------------------------------------------------------------------------------------------------
-- 3. Separation and 4. worldAt
--------------------------------------------------------------------------------------------------
do
	for i, idA in WorldGeometry.Order do
		for j = i + 1, #WorldGeometry.Order do
			local idB = WorldGeometry.Order[j]
			local gap = WorldGeometry.gap(WorldGeometry.get(idA), WorldGeometry.get(idB))
			check(gap >= 3000, `{idA} / {idB} scenery gap {gap} >= 3000`)
		end
	end
	for _, worldId in WorldGeometry.Order do
		local geometry = WorldGeometry.get(worldId)
		local o = geometry.origin.Position
		check(WorldLayout.worldAt(o) == worldId, `worldAt({worldId} origin)`)
		for angle = 0, 7 do
			local direction = Vector3.new(math.cos(angle * math.pi / 4), 0, math.sin(angle * math.pi / 4))
			local inside = o + direction * (geometry.sceneryRadius - 1) + Vector3.new(0, 50, 0)
			local outside = o + direction * (geometry.sceneryRadius + 1)
			check(WorldLayout.worldAt(inside) == worldId, `worldAt inside {worldId} disc`)
			check(WorldLayout.worldAt(outside) ~= worldId, `worldAt outside {worldId} disc`)
		end
	end
	check(WorldLayout.worldAt(Vector3.new(3600, 0, 0)) == nil, "the void between Nuke Town and the Valley")
	-- R70 World 3: Moon Base mirrors the Valley on the other side of Nuke Town.
	check(WorldLayout.worldAt(Vector3.new(-3600, 0, 0)) == nil, "the void between Nuke Town and Moon Base")
	check(WorldLayout.worldAt(Vector3.new(-6000, 30, 400)) == "moon", "Moon Base disc")
	check(same(WorldLayout.plotOrigin(1, "moon"), CFrame.new(-6000, 0, 260)), "moon plot 1 at (-6000, 0, 260)")
	check(WorldLayout.areaCount("moon") == 6 and WorldLayout.plotLength("moon") == 312, "moon areas / plot length")
	check(WorldLayout.inSlot(6, Vector3.new(0, 139, 30), 0, "moon"), "M6 height 140")
	check(
		WorldLayout.worldAt(Vector3.new(0, 0, 0)) == "main" and WorldLayout.worldAt(Vector3.new(6000, 0, 0)) == "dino",
		"hubs"
	)
end

print(`world-frames: {checks} checks passed`)
