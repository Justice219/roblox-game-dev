--!strict
--[[
	AreaLayouts/Area06 — slot layout of Area 6 "Rocket Factory" (spec §3.6).

	Contract: docs/superpowers/plans/2026-10-30-sellnukes-build.md → "World layout". Consumed by B5's
	PlotBuilder: `base` is built when the area unlocks (Area 5's Unlock pad key `A6_EntryArch`
	resolves here), `builds[buildKey]` when that pad is bought, pads/producer/spawnPoint are read
	at plot build time. Meshes come from tools/blender/models/area06.py (keys `A6_*`, MeshAssets).

	Frame: SLOT-LOCAL studs. Origin = road-side edge midpoint of the slot, +Z away from the road,
	+Y up, slot x ∈ [-52, 52], z ∈ [0, 70]. Identity rotation = model front (-Z) faces the road.
	The factory floor slab tops out at y = 0.4 (FLOOR), so everything standing on it sits at y = FLOOR.
	Area 6 is a RIGHT-side slot: the hub is toward +X, so the Unlock pad sits at the -X end.

	Scene (top-down, road at the bottom):
		z 67-70  back wall (A6_ShellBack) with roll-up shutters behind the loading dock (x 25..49);
		         it ends inside the side walls' corner columns (one column per corner, owner R18)
		z 20-70  side walls at x = ±50.6 (A6_ShellSide; area06.py SIDE_WALL_X must match),
		         sawtooth roof frame overhead (y 23-31)
		z 37-47  producer "Rocket Line" (A6_RocketLine) at x = 0; its billboard stands in the clear
		         walkway space in front of it (z ≈ 34.3, eye height), see `producer` below
		z 40     conveyor along the road direction x ∈ [9, 43] (A6_Conveyor, yaw 90) with toy rockets,
		         two robot arms (x 16 / 23) and the scanner arch (A6_QualityCheck, x = 32)
		left     fin press (-20, 41), Factory Boss mezzanine (-40, 40), paint booth (-36, 58), forklift (-41, 28)
		         shuttling pallets toward (-23, 31) (owner R56, VehicleRouteConfig "A6_Forklift")
		right    loading dock (37, 63) with the semi-truck (A6_DeliveryTruck) backed up to it (x 46.4,
		         z 44-58.5); it drives in / out along the lane x 41 -> 46.4 (VehicleRouteConfig "A6_Truck")
		z 18     steel girder entry arch over the walkway x ∈ [-6, 6]
		z 9      pad row (alternating either side of the walkway, buy order outward)

	Collision: invisible primitive boxes (meshes never collide). The roof frame is overhead and the
	small toy rockets on the belt stay walk-through; everything a player could stand inside has a
	box. The dock and the boss mezzanine have stepped boxes so players can climb their stairs.

	Example (B5):
		local layout = require(ReplicatedStorage.Shared.Config.AreaLayouts.Area06)
		for _, placement in layout.base.models do
			MeshLibrary.spawn(placement.key, plotFolder, slotCFrame * placement.cf)
		end
]]

export type ModelPlacement = { key: string, cf: CFrame }
export type CollisionBox = { size: Vector3, cf: CFrame }
export type BuildGroup = { models: { ModelPlacement }, collision: { CollisionBox } }

-- Floor slab top (A6_Floor); every floor-standing model is placed at this height.
local FLOOR = 0.4
-- Conveyor belt surface height above the floor (A6_Conveyor belt top, model-local y).
local BELT_TOP = 3.25

--[[
	Slot-local CFrame helper: position + yaw in degrees (CCW from above, Roblox convention).
	yaw -90 turns a model's front (-Z) toward +X; yaw 90 toward -X; 180 toward +Z.

	Example: at(26, FLOOR, 40, 90) -- the conveyor: its local Z (belt direction) runs along slot +X
]]
local function at(x: number, y: number, z: number, yawDeg: number?): CFrame
	return CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yawDeg or 0), 0)
end

--[[
	Collision box anchored to a placed model: `localCentre` is the box centre in the model's own
	frame, so the box follows the model's yaw. Used for every rotated or multi-part machine.
]]
local function boxOn(model: CFrame, size: Vector3, localCentre: Vector3): CollisionBox
	return { size = size, cf = model * CFrame.new(localCentre) }
end

-- Shared placements (referenced by both models and collision below).
local ROCKET_LINE = at(0, FLOOR, 42)
local CONVEYOR = at(26, FLOOR, 40, 90)
local FIN_PRESS = at(-20, FLOOR, 41)
local PAINT_BOOTH = at(-36, FLOOR, 58)
local QUALITY_CHECK = at(32, FLOOR, 40)
-- Forklift rest = the pickup end of its shuttle (owner R56), forks toward +X (the fin press side).
local FORKLIFT = at(-41, FLOOR, 28, -90)
local LOADING_DOCK = at(37, FLOOR, 63)
-- Semi-truck parked against the dock (rear bumper at z 58.5), lane x 46.4: 0.5 clear of the conveyor
-- end (x 43.4) and the side wall (x 49.4). It drives (owner R56): no collision box.
local TRUCK = LOADING_DOCK * CFrame.new(9.4, 0, -11.75)
local FACTORY_BOSS = at(-40, FLOOR, 40)
local SIDE_WALLS = {
	at(50.6, FLOOR, 45.2), -- +X wall, inner face -X
	at(-50.6, FLOOR, 45.2, 180), -- same mesh turned around for the -X wall
}
local ROBOT_ARMS = {
	at(16, FLOOR, 35.4, 180), -- road side of the belt, gripper reaching +Z over the belt
	at(23, FLOOR, 44.4), -- far side of the belt, gripper reaching -Z over the belt
}
-- Toy rockets standing on the belt, between the arms and the scanner (portholes face the road).
local BELT_ROCKETS = {
	at(12, FLOOR + BELT_TOP, 40),
	at(28.5, FLOOR + BELT_TOP, 40),
	at(39, FLOOR + BELT_TOP, 40),
}

local function listModels(key: string, placements: { CFrame }): { ModelPlacement }
	local models: { ModelPlacement } = {}
	for _, cf in placements do
		table.insert(models, { key = key, cf = cf })
	end
	return models
end

local function listCollision(placements: { CFrame }, size: Vector3, localCentre: Vector3): { CollisionBox }
	local boxes: { CollisionBox } = {}
	for _, cf in placements do
		table.insert(boxes, boxOn(cf, size, localCentre))
	end
	return boxes
end

--[[
	Stair collision: one box per step so players can walk up (each step `rise` taller than the
	last). Step i is centred at local x = x0 + (i - 1) * run (run may be negative to climb toward
	-X), on local z `z`.
]]
local function stairCollision(
	model: CFrame,
	x0: number,
	run: number,
	z: number,
	width: number,
	heights: { number }
): { CollisionBox }
	local boxes: { CollisionBox } = {}
	for i, height in heights do
		local x = x0 + (i - 1) * run
		table.insert(boxes, boxOn(model, Vector3.new(math.abs(run), height, width), Vector3.new(x, height / 2, z)))
	end
	return boxes
end

-- FactoryShell collision: back wall, both side walls, the producer's base plate, rocket, towers,
-- hopper and desk.
local factoryShellCollision: { CollisionBox } = {
	{ size = Vector3.new(104, 22.6, 2.4), cf = at(0, FLOOR + 11.3, 68.8) },
	boxOn(ROCKET_LINE, Vector3.new(16.6, 0.8, 10), Vector3.new(0, 0.4, 0)), -- base plate (walkable)
	boxOn(ROCKET_LINE, Vector3.new(6.6, 11, 6.6), Vector3.new(0, 6.3, 0.5)), -- cradle + big rocket
	boxOn(ROCKET_LINE, Vector3.new(1.8, 13, 1.8), Vector3.new(-5.4, 7.3, 0.5)), -- gantry towers
	boxOn(ROCKET_LINE, Vector3.new(1.8, 13, 1.8), Vector3.new(5.4, 7.3, 0.5)),
	boxOn(ROCKET_LINE, Vector3.new(3.6, 6, 3.6), Vector3.new(6.9, 3.8, -2.8)), -- parts hopper
	boxOn(ROCKET_LINE, Vector3.new(3, 2.6, 2), Vector3.new(-6.6, 2.1, -3.2)), -- control desk
}
for _, wall in SIDE_WALLS do
	table.insert(factoryShellCollision, boxOn(wall, Vector3.new(2.4, 22.6, 49.6), Vector3.new(0, 11.3, 0)))
end

-- Loading dock: dock body, climbable steps, the three pallet stacks (the truck drives: no box).
local loadingDockCollision: { CollisionBox } = {
	boxOn(LOADING_DOCK, Vector3.new(24, 1.6, 8), Vector3.new(0, 0.8, 0)),
}
for _, x in { -8, -2.6, 2.6 } do
	table.insert(loadingDockCollision, boxOn(LOADING_DOCK, Vector3.new(3.4, 3.2, 3.4), Vector3.new(x, 3.2, 0.8)))
end
for _, step in stairCollision(LOADING_DOCK, -14, 0.8, -1, 4, { 0.4, 0.8, 1.2 }) do
	table.insert(loadingDockCollision, step)
end

-- Factory Boss: solid mezzanine block, climbable six-step stair (+X), railings, boss, sign + desk.
local factoryBossCollision: { CollisionBox } = {
	boxOn(FACTORY_BOSS, Vector3.new(9, 5.6, 7), Vector3.new(0, 2.8, 0.5)),
	boxOn(FACTORY_BOSS, Vector3.new(8.6, 1.8, 0.4), Vector3.new(0, 6.5, -2.7)), -- front railing
	boxOn(FACTORY_BOSS, Vector3.new(0.4, 1.8, 6.4), Vector3.new(-4.2, 6.5, 0.5)), -- side railing
	boxOn(FACTORY_BOSS, Vector3.new(2.4, 6.4, 2), Vector3.new(-1, 8.8, -1.3)), -- the boss
	boxOn(FACTORY_BOSS, Vector3.new(6.4, 4.8, 1.6), Vector3.new(0.6, 8, 3.2)), -- desk + sign posts
}
for _, step in stairCollision(FACTORY_BOSS, 8.65, -0.75, 2, 2.4, { 0.93, 1.87, 2.8, 3.73, 4.67, 5.6 }) do
	table.insert(factoryBossCollision, step)
end

-- Conveyor first (build-in order), then the toy rockets riding it.
local conveyorModels = listModels("A6_ToyRocket", BELT_ROCKETS)
table.insert(conveyorModels, 1, { key = "A6_Conveyor", cf = CONVEYOR })

local layout = {
	area = 6,

	-- Built when Area 6 unlocks: factory floor + steel girder entry arch.
	base = {
		models = {
			{ key = "A6_Floor", cf = at(0, 0, 35) },
			{ key = "A6_EntryArch", cf = at(0, FLOOR, 18) },
		},
		collision = {
			{ size = Vector3.new(104, 1, 70), cf = at(0, FLOOR - 0.5, 35) }, -- floor (top = FLOOR)
			{ size = Vector3.new(4.4, 15, 4.4), cf = at(-10, FLOOR + 7.5, 18) }, -- arch pillars
			{ size = Vector3.new(4.4, 15, 4.4), cf = at(10, FLOOR + 7.5, 18) },
		},
	},

	builds = {
		-- First pad: the factory shell (walls + sawtooth roof frame) + the producer "Rocket Line".
		A6_FactoryShell = {
			models = {
				{ key = "A6_ShellBack", cf = at(0, FLOOR, 68.8) },
				{ key = "A6_ShellSide", cf = SIDE_WALLS[1] },
				{ key = "A6_ShellSide", cf = SIDE_WALLS[2] },
				{ key = "A6_RoofFrame", cf = at(0, FLOOR, 46) },
				{ key = "A6_RocketLine", cf = ROCKET_LINE },
			},
			collision = factoryShellCollision,
		},
		-- Conveyor along the road direction (belt = model local Z, yaw 90) + toy rockets riding it.
		A6_Conveyor = {
			models = conveyorModels,
			collision = { boxOn(CONVEYOR, Vector3.new(5.4, 3.5, 34.8), Vector3.new(0, 1.75, 0)) },
		},
		A6_RobotArms = {
			models = listModels("A6_RobotArm", ROBOT_ARMS),
			collision = listCollision(ROBOT_ARMS, Vector3.new(3.6, 8, 3.6), Vector3.new(0, 4, 0)),
		},
		A6_FinPress = {
			models = { { key = "A6_FinPress", cf = FIN_PRESS } },
			collision = {
				boxOn(FIN_PRESS, Vector3.new(8, 10.8, 4.4), Vector3.new(0, 5.4, 0)),
				boxOn(FIN_PRESS, Vector3.new(2, 1.6, 2.2), Vector3.new(-5.4, 0.8, -1.2)), -- fin bin
			},
		},
		A6_PaintBooth = {
			models = { { key = "A6_PaintBooth", cf = PAINT_BOOTH } },
			collision = {
				boxOn(PAINT_BOOTH, Vector3.new(10.4, 10.6, 0.6), Vector3.new(0, 5.3, 4.7)), -- back wall
				boxOn(PAINT_BOOTH, Vector3.new(0.6, 10.6, 10.4), Vector3.new(-4.7, 5.3, 0)), -- side walls
				boxOn(PAINT_BOOTH, Vector3.new(0.6, 10.6, 10.4), Vector3.new(4.7, 5.3, 0)),
				boxOn(PAINT_BOOTH, Vector3.new(3, 7.2, 3), Vector3.new(0, 4, 0.6)), -- turntable + rocket
			},
		},
		A6_QualityCheck = {
			models = { { key = "A6_QualityCheck", cf = QUALITY_CHECK } },
			collision = listCollision(
				{ QUALITY_CHECK * CFrame.new(0, 0, -3.7), QUALITY_CHECK * CFrame.new(0, 0, 3.7) },
				Vector3.new(2.4, 8.6, 2),
				Vector3.new(0, 4.3, 0)
			),
		},
		-- The forklift shuttles (owner R56): walk-through, no collision box.
		A6_Forklift = {
			models = { { key = "A6_Forklift", cf = FORKLIFT } },
			collision = {},
		},
		A6_LoadingDock = {
			models = {
				{ key = "A6_LoadingDock", cf = LOADING_DOCK },
				{ key = "A6_DeliveryTruck", cf = TRUCK },
			},
			collision = loadingDockCollision,
		},
		A6_FactoryBoss = {
			models = { { key = "A6_FactoryBoss", cf = FACTORY_BOSS } },
			collision = factoryBossCollision,
		},
	} :: { [string]: BuildGroup },

	-- BuyPad ground positions (slot-local), alternating either side of the walkway in buy order;
	-- the Unlock pad sits at the far (away-from-hub, -X) end of the row.
	pads = {
		a6_factory_shell = Vector3.new(-11, FLOOR, 9),
		a6_conveyor = Vector3.new(11, FLOOR, 9),
		a6_robot_arms = Vector3.new(-20, FLOOR, 9),
		a6_fin_press = Vector3.new(20, FLOOR, 9),
		a6_paint_booth = Vector3.new(-29, FLOOR, 9),
		a6_quality_check = Vector3.new(29, FLOOR, 9),
		a6_forklift = Vector3.new(-38, FLOOR, 9),
		a6_loading_dock = Vector3.new(38, FLOOR, 9),
		a6_factory_boss = Vector3.new(47, FLOOR, 9),
		a6_dig_silos = Vector3.new(-47, FLOOR, 9),
	} :: { [string]: Vector3 },

	--[[
		Producer (owner R31 / R32: the billboard sits in CLEAR space in FRONT of the producer at eye
		level, never up in the gantry). The click box wraps the whole assembly station; its front face
		is at z = 42 - 5.2 = 36.8. The client (ProducerBillboards.place) puts the billboard
		TycoonClientConfig.Placement.FrontGap (2.5) in front of that face, centred EyeHeight (7.5)
		above the floor: (0, FLOOR + 7.5, 34.3). That 14.3 x 11.4 slab (phone / console size) is clear
		of every visible piece's bounding box (walkway between the arch at z 18 and the station), so
		it never nudges. The anchor (tutorial arrow target, click reach origin) is that same spot.
	]]
	producer = {
		anchor = Vector3.new(0, FLOOR + 7.5, 34.3),
		click = { size = Vector3.new(17, 15, 10.4), cf = ROCKET_LINE * CFrame.new(0, 7.5, 0) },
	},

	-- Teleport target: on the walkway between the pad row and the arch.
	spawnPoint = Vector3.new(0, FLOOR + 3, 13),
}

return layout
