--!strict
--[[
	AreaLayouts/Area01 — slot layout of Area 1 "Garage Lab" (spec §3.1, the tutorial area).

	Contract: docs/superpowers/plans/2026-10-30-sellnukes-build.md → "World layout", validated by
	src/server/Tycoon/LayoutLogic.luau (tests/area-layouts.luau). Consumed by B5's PlotBuilder:
	`base` is built when the plot is claimed (Area 1 is always open), `builds[buildKey]` when that
	pad is bought (LEGO build-in), pads / producer / spawnPoint are read at plot build time.
	The Unlock pad's key `A2_EntryArch` is NOT here: it resolves to Area02.base.

	Meshes: B4's garage set (tools/blender/models/area1_garage.py: Garage_*, Workbench, MiniReactor,
	ToolWall, GlowLamp, PaintStation, Driveway), the shared PocketNuke, and B8a's
	tools/blender/models/area01.py (A1_*). Art notes: docs/areas-art.md → "Area 1".

	Frame: SLOT-LOCAL studs. Origin = road-side edge midpoint, +Z away from the road, +Y up,
	x ∈ [-52, 52], z ∈ [0, 70]. Identity rotation = model front (-Z) faces the road.
	The lawn lot (A1_Lot) is a 0.5-stud plate: everything outdoors stands at y = LOT (0.5); the
	garage's own floor slab tops out at LOT + 0.6, so indoor props stand at GARAGE * (x, GF, z).

	Scene (top-down, road at the bottom):
		z 66-70  hedge along the back edge, trees in the back corners
		z 32-56  the garage (28 x 24, door toward the road), coolant pack on its +X wall at z 40
		z  8-32  stepping stones → (Driveway pad) concrete drive with the Nuke-Mobile, lamps at z 26
		z  4     GARAGE LAB entry arch over the drive mouth (clear width 22)
		z 10     pad row: buy order alternates either side of the arch, moving outward

	Collision: invisible primitive boxes (meshes never collide). Flower beds, stones and tiny props
	stay walk-through on purpose; floors, walls, furniture and characters get boxes.

	Example (B5):
		local layout = require(ReplicatedStorage.Shared.Config.AreaLayouts.Area01)
		for _, placement in layout.base.models do
			MeshLibrary.spawn(placement.key, plotFolder, slotCFrame * placement.cf)
		end
]]

export type ModelPlacement = { key: string, cf: CFrame, tint: Color3?, castShadow: boolean?, collide: boolean? }
export type CollisionBox = { size: Vector3, cf: CFrame }
export type BuildGroup = { models: { ModelPlacement }, collision: { CollisionBox } }

-- Lawn lot top (A1_Lot): outdoor models stand at this height.
local LOT = 0.5
-- Garage floor top above the garage pivot (B4's Garage_Floor: 0.6-stud slab).
local GF = 0.6

--[[
	Slot-local CFrame from a position + yaw in degrees (CCW seen from above, Roblox convention).
	yaw 90 turns a model's front (-Z) toward -X; yaw -90 toward +X; 180 toward +Z.

	Example: at(15.5, LOT, 40, -90) -- the coolant pack, fan facing +X, back on the garage wall
]]
local function at(x: number, y: number, z: number, yawDeg: number?): CFrame
	return CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yawDeg or 0), 0)
end

--[[
	Collision box anchored to a placed model: `localCentre` is in the model's own frame, so the box
	follows the model's yaw.

	Example: boxOn(BENCH, Vector3.new(10.2, 3.3, 4.4), Vector3.new(0, 1.65, 0))
]]
local function boxOn(model: CFrame, size: Vector3, localCentre: Vector3): CollisionBox
	return { size = size, cf = model * CFrame.new(localCentre) }
end

-- Shared placements (used by models, collision and the producer below).
local GARAGE = at(0, LOT, 44) -- B4 garage origin: floor centre at ground, door toward the road
local BENCH = GARAGE * CFrame.new(-4, GF, 6) -- producer "Pocket Nuke Workbench"
-- Tool wall 0.5 off the back wall so the pegboard clears the window sill (sill reaches z 10.575),
-- and x 7.5 so its 11-stud board ends exactly at the +X wall's inner face (x 13).
local TOOL_WALL = GARAGE * CFrame.new(7.5, GF, 10.5)
-- Booth back 0.45 off the -X wall so it clears that wall's window trim; open side facing in.
-- z -3.2 keeps the booth (local z -7.1..0.7) clear of the producer billboard's spot in front of the
-- bench (local z ~1.2, x -11.2..3.2 on phones; owner R31/R32, tests/billboard-clearance.luau).
local PAINT = GARAGE * at(-9.95, GF, -3.2, -90)
-- Manager, turned a little toward the bench. x 6.5 keeps his left arm (2.2 studs left of his centre)
-- clear of the phone billboard's +X edge in front of the bench (local x -4 + 7.15 = 3.15).
local UNCLE = GARAGE * at(6.5, GF, 1, 15)
-- Back (+Z local) against the garage's +X wall; skid starts at x 14.3 (the garage slab edge),
-- coolant pipes still reach into the wall.
local REACTOR_PACK = at(15.8, LOT, 40, -90)
-- B4 Driveway (garage pivot * (0, 0, -24.3)): its slab ends flush with the garage slab's front edge.
local DRIVEWAY = at(0, LOT, 19.7)
local CAR = at(0, LOT + 0.3, 16.7) -- on the drive slab (top 0.3), nose toward the road
local ARCH = at(0, LOT, 4)
local LAMPS = {
	-- Inside, either side of the door, just behind the door pillars (z -9.6: clear of the paint
	-- booth, which moved toward the door to free the billboard spot in front of the bench).
	GARAGE * CFrame.new(-11, GF, -9.6),
	GARAGE * CFrame.new(11, GF, -9.6),
	at(-11.5, LOT, 26), -- outside, flanking the drive
	at(11.5, LOT, 26),
}
-- Yard trees (A1_Yard, slot-origin pivot): {x, z, height} — trunks get collision boxes.
local TREES = { { -42, 30, 9 }, { -46, 56, 10 }, { -26, 63, 8.5 }, { 44, 29, 9.5 }, { 46, 55, 8 }, { 28, 63, 10 } }

--[[ Trunk boxes for the yard's lollipop trees (trunk height = 45 % of the tree). ]]
local function treeCollision(): { CollisionBox }
	local boxes: { CollisionBox } = {}
	for _, tree in TREES do
		local h = tree[3] * 0.45
		table.insert(boxes, { size = Vector3.new(1.2, h, 1.2), cf = at(tree[1], LOT + h / 2, tree[2]) })
	end
	return boxes
end

--[[ Lamp post boxes (GlowLamp: 2.4 base, slim post up to the bulb at y = 5.6). ]]
local function lampCollision(): { CollisionBox }
	local boxes: { CollisionBox } = {}
	for _, cf in LAMPS do
		table.insert(boxes, boxOn(cf, Vector3.new(1.0, 6.8, 1.0), Vector3.new(0, 3.4, 0)))
	end
	return boxes
end

--[[ Builds a list of the same mesh at several placements. ]]
local function listModels(key: string, placements: { CFrame }): { ModelPlacement }
	local models: { ModelPlacement } = {}
	for _, cf in placements do
		table.insert(models, { key = key, cf = cf })
	end
	return models
end

local baseCollision: { CollisionBox } = {
	{ size = Vector3.new(104, LOT, 70), cf = at(0, LOT / 2, 35) }, -- lawn lot (top = LOT)
	boxOn(GARAGE, Vector3.new(28.6, GF, 24.6), Vector3.new(0, GF / 2, 0)), -- garage floor slab
	boxOn(GARAGE, Vector3.new(28, 12.3, 1), Vector3.new(0, 6.75, 11.5)), -- back wall
	boxOn(GARAGE, Vector3.new(1, 12.3, 24), Vector3.new(13.5, 6.75, 0)), -- +X wall
	boxOn(GARAGE, Vector3.new(1, 12.3, 24), Vector3.new(-13.5, 6.75, 0)), -- -X wall
	boxOn(GARAGE, Vector3.new(5, 12.3, 1), Vector3.new(11.5, 6.75, -11.5)), -- door pillars
	boxOn(GARAGE, Vector3.new(5, 12.3, 1), Vector3.new(-11.5, 6.75, -11.5)),
	boxOn(GARAGE, Vector3.new(18, 2.3, 1), Vector3.new(0, 11.75, -11.5)), -- door header
	boxOn(ARCH, Vector3.new(4, 10, 4), Vector3.new(12.5, 5, 0)), -- arch posts (plinth + shaft)
	boxOn(ARCH, Vector3.new(4, 10, 4), Vector3.new(-12.5, 5, 0)),
	{ size = Vector3.new(48.5, 2.2, 2.2), cf = at(-26.25, LOT + 1.1, 68.2) }, -- back hedges
	{ size = Vector3.new(48.5, 2.2, 2.2), cf = at(26.25, LOT + 1.1, 68.2) },
	{ size = Vector3.new(2.2, 2.2, 30), cf = at(-50.4, LOT + 1.1, 52) }, -- side hedges
	{ size = Vector3.new(2.2, 2.2, 30), cf = at(50.4, LOT + 1.1, 52) },
}
for _, box in treeCollision() do
	table.insert(baseCollision, box)
end

local layout = {
	area = 1,
	-- Built when the plot is claimed: lawn lot, arch, yard, and the empty garage shell (the
	-- player starts in "a little garage"; the door, bench and everything inside are pads).
	base = {
		models = {
			{ key = "A1_Lot", cf = CFrame.identity, castShadow = false },
			{ key = "A1_Yard", cf = CFrame.identity },
			{ key = "A1_EntryArch", cf = ARCH },
			{ key = "Garage_Floor", cf = GARAGE, castShadow = false },
			{ key = "Garage_WallBack", cf = GARAGE },
			{ key = "Garage_WallSide", cf = GARAGE }, -- +X wall
			{ key = "Garage_WallSide", cf = GARAGE * CFrame.Angles(0, math.pi, 0) }, -- -X wall
			{ key = "Garage_WallFront", cf = GARAGE },
			{ key = "Garage_Roof", cf = GARAGE },
		},
		collision = baseCollision,
	} :: BuildGroup,
	builds = {
		-- Pad 1 (free, tutorial step 1): the producer, with a first pocket nuke on the bench.
		A1_Workbench = {
			models = {
				{ key = "Workbench", cf = BENCH },
				{ key = "PocketNuke", cf = BENCH * CFrame.new(-1.2, 3.3, -0.6) },
			},
			collision = { boxOn(BENCH, Vector3.new(10.2, 3.3, 4.4), Vector3.new(0, 1.65, 0)) },
		},
		A1_ToolWall = {
			models = { { key = "ToolWall", cf = TOOL_WALL } },
			collision = { boxOn(TOOL_WALL, Vector3.new(9.3, 3.45, 2.7), Vector3.new(0, 1.72, -1.25)) },
		},
		-- Four glowing lamps: two inside by the door, two outside along the drive (visible growth).
		A1_GlowLamp = {
			models = listModels("GlowLamp", LAMPS),
			collision = lampCollision(),
		},
		-- Roll-up door, parked open (bottom edge 7.5 above the garage pivot): nothing to collide.
		A1_GarageDoor = {
			models = { { key = "Garage_Door", cf = GARAGE } },
			collision = {},
		},
		-- Reactor jar on the bench + its coolant pack bolted to the outside wall.
		A1_MiniReactor = {
			models = {
				-- (2.2, 0.5) keeps the reactor's base clear of the bench vise at (4.1, -1.45).
				{ key = "MiniReactor", cf = BENCH * CFrame.new(2.2, 3.3, 0.5) },
				{ key = "A1_ReactorPack", cf = REACTOR_PACK },
			},
			collision = { boxOn(REACTOR_PACK, Vector3.new(5.0, 3.6, 3.2), Vector3.new(0, 1.8, -0.1)) },
		},
		A1_PaintStation = {
			models = {
				{ key = "PaintStation", cf = PAINT },
				{ key = "PocketNuke", cf = PAINT * CFrame.new(0, 0.5, 0.2), tint = Color3.fromRGB(110, 222, 170) },
			},
			collision = {
				boxOn(PAINT, Vector3.new(7.6, 6.8, 0.6), Vector3.new(0, 3.4, 2.35)), -- booth back
				boxOn(PAINT, Vector3.new(0.6, 6.4, 5.0), Vector3.new(3.4, 3.2, 0.1)), -- booth sides
				boxOn(PAINT, Vector3.new(0.6, 6.4, 5.0), Vector3.new(-3.4, 3.2, 0.1)),
			},
		},
		-- Manager: Uncle Atom, waving next to the bench.
		A1_UncleAtom = {
			models = { { key = "A1_UncleAtom", cf = UNCLE } },
			collision = { boxOn(UNCLE, Vector3.new(2.4, 6.4, 1.6), Vector3.new(0, 3.2, 0)) },
		},
		-- Concrete drive over the stepping stones + the family Nuke-Mobile parked on it.
		A1_Driveway = {
			models = {
				{ key = "Driveway", cf = DRIVEWAY, castShadow = false },
				{ key = "A1_NukeMobile", cf = CAR },
			},
			collision = {
				boxOn(DRIVEWAY, Vector3.new(16, 0.3, 24), Vector3.new(0, 0.15, 0)), -- slab (top 0.3)
				boxOn(DRIVEWAY, Vector3.new(0.9, 0.6, 24), Vector3.new(8.45, 0.3, 0)), -- curbs
				boxOn(DRIVEWAY, Vector3.new(0.9, 0.6, 24), Vector3.new(-8.45, 0.3, 0)),
				boxOn(CAR, Vector3.new(5.6, 4.4, 8.8), Vector3.new(0, 2.2, 0)),
			},
		},
	} :: { [string]: BuildGroup },
	-- BuyPad ground positions: alternate either side of the arch in buy order, moving outward;
	-- the Unlock pad (opens the Nuke Stand across the road) at the hub-side end of the row.
	-- R122 (2026-11-01): Uncle Atom is pad 4 now (Area01 config), so it takes the 4th spot (+24)
	-- and Garage Door / Mini Reactor / Paint Station move one spot outward; the next pad is still
	-- always the closest unbought one across the arch.
	pads = {
		a1_workbench = Vector3.new(-16, LOT, 10),
		a1_tool_wall = Vector3.new(16, LOT, 10),
		a1_glow_lamp = Vector3.new(-24, LOT, 10),
		a1_uncle_atom = Vector3.new(24, LOT, 10),
		a1_garage_door = Vector3.new(-32, LOT, 10),
		a1_mini_reactor = Vector3.new(32, LOT, 10),
		a1_paint_station = Vector3.new(-40, LOT, 10),
		a1_driveway = Vector3.new(40, LOT, 10),
		a1_open_stand = Vector3.new(-48, LOT, 10),
	} :: { [string]: Vector3 },
	-- The click box wraps the bench and everything on it. The anchor is where the client puts the
	-- billboard (ProducerBillboards.place, owner R31/R32): 2.5 in front of the click box's front
	-- face (local z -2.3 - 2.5) and MinHeight 6 above the garage floor (the bench top is lower than
	-- the 7.5 eye height); its phone-size slab clears the roof (y 12.95) and the paint booth.
	producer = {
		anchor = (BENCH * CFrame.new(0, 6.0, -4.8)).Position,
		click = { size = Vector3.new(10.4, 4.6, 4.6), cf = BENCH * CFrame.new(0, 2.3, 0) },
	},
	-- Teleport target (ground level, in front of the arch on the drive axis).
	spawnPoint = Vector3.new(0, LOT, 12),
}

return layout
