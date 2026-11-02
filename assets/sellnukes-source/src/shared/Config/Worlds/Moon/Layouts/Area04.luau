--!strict
--[[
	Worlds/Moon/Layouts/Area04 — slot layout of Moon Base area M4 "Asteroid Mine" (spec
	2026-10-31-r69-moon-lucky-juice-design §2.2, owner R70; W7 art-d34). Replaces W1's placeholder.

	Contract: identical to AreaLayouts/AreaNN (docs/superpowers/plans/2026-10-30-sellnukes-build.md
	→ "World layout"), validated by src/server/Tycoon/LayoutLogic.luau against the Moon AreaConfig
	(Worlds/Moon/Areas/Area04). `base` is built when M3's Unlock pad (build key `M4_EntryArch`) is
	bought, `builds[buildKey]` when that pad is bought, pads / producer / spawnPoint at plot build
	time. The Unlock pad's key `M5_EntryArch` is NOT here: it resolves to Moon Area05.base.

	Meshes: tools/blender/models/moon_area04.py (keys `M4_*`, MeshAssets). Art notes:
	docs/areas-art.md → "Moon Base M3 / M4".

	Frame: SLOT-LOCAL studs. Origin = road-side edge midpoint, +Z away from the road, +Y up,
	x ∈ [-52, 52], z ∈ [0, 70]. Identity rotation = model front (-Z) faces the road. Standing on the
	road looking in, +X is on your LEFT. The moon-dust slab tops out at y = 0.4 (FLOOR).

	Scene (top-down, road at the bottom):
		z 57-70  Mega Asteroid (hero, x 0) floating at y ~20 on four cables; back rocks + crystals
		z 40-56  Drill Rig (producer, x 0): platform, cradled asteroid, drill gantry, console at z 40;
		         the crystal chute runs to the cart track's loading stop at (14, 49.2)
		z 35.9   producer billboard at eye level in front of the console (R31 / R32)
		z 31-59  ore-cart loop (centre (22.5, 45): straights at x 14 / 31, z 40 .. 50) with the crystal
		         sorter on its +X side (x 32.8 .. 40.2); two carts run the loop (VehicleRouteConfig)
		z 21-27  laser drills (x 34 .. 46); Drillbert beside the walkway (x 8, z 27)
		z 33-62  gravity magnets (x -14 / -24), tethered asteroids (x -22 .. -44, z 53 .. 62)
		z 18-45  hover steps rising from (-28, 18) to the lookout deck at (-45, 41.5), top y 9.8
		z 18     ASTEROID MINE arch (W6's shared moon_arch) over the tile walkway x ∈ [-5, 5]
		z 9      pad row (alternating either side of the walkway, buy order outward)

	Low gravity (spec §2.4: gravityScale 0.4): players jump ~16 studs, so the floating rocks, the
	magnets, the hover steps and the Mega Asteroid all have collision boxes (static; their visuals
	bob a little around them). The carts (routed, R56) and the rails stay walk-through.

	Static checks: no interpenetration (owner R24, check_area_overlaps.py --world moon), no coplanar
	faces (R18), billboard spot clear (R31 / R32), the cart route clears every collider
	(tests/vehicle-routes).

	Example (PlotBuilder):
		local layout = require(ReplicatedStorage.Shared.Config.Worlds.Moon.Layouts.Area04)
		print(layout.builds.M4_OreCarts.models[2].key) --> "M4_OreCart"
]]

export type ModelPlacement = { key: string, cf: CFrame }
export type CollisionBox = { size: Vector3, cf: CFrame }
export type BuildGroup = { models: { ModelPlacement }, collision: { CollisionBox } }

-- Floor slab top (M4_Floor); every floor-standing model is placed at this height.
local FLOOR = 0.4
-- Rail top above the floor (moon_area04.py RAIL_TOP): the carts' pivot height.
local RAIL_TOP = 0.3

--[[
	Slot-local CFrame helper: position + yaw in degrees (CCW from above, Roblox convention).
	yaw -90 turns a model's front (-Z) toward +X; yaw 90 toward -X; 180 toward +Z.

	Example: at(35.4, FLOOR, 45, 90) -- the sorter: its hopper (local front) faces the track (-X)
]]
local function at(x: number, y: number, z: number, yawDeg: number?): CFrame
	return CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yawDeg or 0), 0)
end

--[[
	Collision box anchored to a placed model: `localCentre` is the box centre in the model's own
	frame, so the box follows the model's yaw.
]]
local function boxOn(model: CFrame, size: Vector3, localCentre: Vector3): CollisionBox
	return { size = size, cf = model * CFrame.new(localCentre) }
end

-- Shared placements (models, collision and VehicleRouteConfig's M4 cart route use these).
local DRILL = at(0, FLOOR, 48) -- producer: platform centre at local z 1.2 (slot 49.2); console at slot z 40
local TRACK = at(22.5, FLOOR, 45) -- loop centre; straights at slot x 14 / 31 (z 40 .. 50)
-- Carts rest at the loading stop under the drill's crystal chute, heading +Z (yaw 180); the second
-- cart is coupled 5.2 studs behind (VehicleRouteConfig "M4_Carts" follower gap).
local CARTS = {
	at(14, FLOOR + RAIL_TOP, 49.2, 180),
	at(14, FLOOR + RAIL_TOP, 44.0, 180),
}
local SORTER = at(35.4, FLOOR, 45, 90) -- hopper front at slot x 32.8, along z 39 .. 51
local TETHERS = {
	at(-22, FLOOR, 58, 20),
	at(-34, FLOOR, 53, -35),
	at(-44, FLOOR, 62, 60),
}
local MAGNETS = {
	at(-14, FLOOR, 33, -15),
	at(-24, FLOOR, 40, 30),
}
local LASERS = at(40, FLOOR, 24)
local MEGA = at(0, FLOOR, 62)
-- Drillbert (manager NPC, owner R30) starts beside the walkway, turned toward it; the client
-- ManagerController walks him from here, so he has no collision box.
local DRILLBERT = at(8, FLOOR, 27, 20)
-- Hover steps (pivot = step underside): rising 1.5 per step toward the lookout deck.
local STEPS = {
	at(-28, FLOOR + 1.4, 18),
	at(-33, FLOOR + 2.9, 21.5),
	at(-37.5, FLOOR + 4.4, 25.5),
	at(-41.5, FLOOR + 5.9, 30),
	at(-44.5, FLOOR + 7.4, 35),
}
-- Lookout deck: identity yaw keeps its railing (model +Z half) on the far side, open toward the steps.
local DECK = at(-45, FLOOR + 8.9, 41.5)
-- Producer click box (wraps platform, gantry and console) and the billboard spot in front of it
-- (owner R31 / R32): the billboard sits FrontGap (2.5) past the click box's road-side face at
-- EyeHeight (7.5). The slot in front (z 35.3 .. 36.5, x within ±7.2, y 2 .. 14) is clear of every
-- visible piece box: Drillbert at x 8, the near magnet at x -14, the loop at x >= 14.
local PRODUCER_CLICK = DRILL * CFrame.new(0, 6, -0.6)
local PRODUCER_CLICK_SIZE = Vector3.new(14, 12, 18)
local BILLBOARD_Z = PRODUCER_CLICK.Position.Z - PRODUCER_CLICK_SIZE.Z / 2 - 2.5

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

local tetherCollision = listCollision(TETHERS, Vector3.new(2.2, 1.1, 2.2), Vector3.new(0, 0.55, 0))
for _, box in listCollision(TETHERS, Vector3.new(3.6, 3.2, 3.6), Vector3.new(0, 7.2, 0)) do
	table.insert(tetherCollision, box) -- the floating rock (low-gravity jumpers can land on it)
end

local magnetCollision: { CollisionBox } = {}
for _, cf in MAGNETS do
	table.insert(magnetCollision, boxOn(cf, Vector3.new(2.8, 0.5, 2.8), Vector3.new(0, 0.25, 0)))
	table.insert(magnetCollision, boxOn(cf, Vector3.new(0.8, 6.6, 0.8), Vector3.new(0, 3.3, 0.9)))
	table.insert(magnetCollision, boxOn(cf, Vector3.new(3.4, 1.4, 2.6), Vector3.new(0, 6.2, -0.4)))
end

local hoverModels = listModels("M4_HoverStep", STEPS)
table.insert(hoverModels, { key = "M4_HoverDeck", cf = DECK })
local stepCollision = listCollision(STEPS, Vector3.new(3.6, 0.6, 3.6), Vector3.new(0, 0.12, 0))
table.insert(stepCollision, boxOn(DECK, Vector3.new(6.2, 0.7, 6.2), Vector3.new(0, 0.15, 0)))

local megaCollision = {
	boxOn(MEGA, Vector3.new(10.4, 8, 9.6), Vector3.new(0, 20, 0)), -- the floating asteroid
}
for k = 0, 3 do
	local a = math.rad(45 + 90 * k)
	table.insert(
		megaCollision,
		boxOn(MEGA, Vector3.new(2.4, 1.4, 2.4), Vector3.new(7.2 * math.cos(a), 0.7, 7.2 * math.sin(a)))
	)
end

local layout = {
	area = 4,

	-- Built when M4 unlocks: moon-dust floor, ASTEROID MINE arch, back-corner rocks + crystals.
	base = {
		models = {
			{ key = "M4_Floor", cf = at(0, 0, 35) },
			{ key = "M4_EntryArch", cf = at(0, FLOOR, 18) },
			{ key = "M4_Rocks", cf = at(0, FLOOR, 0) },
		},
		collision = {
			{ size = Vector3.new(104, 1, 70), cf = at(0, FLOOR - 0.5, 35) }, -- floor (top = FLOOR)
			{ size = Vector3.new(4.4, 9.1, 4.4), cf = at(-9, FLOOR + 4.55, 18) }, -- arch capsule posts
			{ size = Vector3.new(4.4, 9.1, 4.4), cf = at(9, FLOOR + 4.55, 18) },
			{ size = Vector3.new(9, 5.6, 6.6), cf = at(-42, FLOOR + 2.8, 66) }, -- back-corner rocks
			{ size = Vector3.new(6.6, 4, 5), cf = at(-24, FLOOR + 2, 67) },
			{ size = Vector3.new(6.6, 4, 5), cf = at(22, FLOOR + 2, 67) },
			{ size = Vector3.new(9, 5.8, 6.6), cf = at(40, FLOOR + 2.9, 66) },
		},
	},

	builds = {
		-- First pad (builder): the Drill Rig producer.
		M4_DrillRig = {
			models = { { key = "M4_DrillRig", cf = DRILL } },
			collision = {
				boxOn(DRILL, Vector3.new(12.4, 0.8, 8.6), Vector3.new(0, 0.4, 1.2)), -- octagon platform
				boxOn(DRILL, Vector3.new(8.6, 0.8, 12.4), Vector3.new(0, 0.4, 1.2)),
				boxOn(DRILL, Vector3.new(6.6, 7.0, 6.2), Vector3.new(0, 4.0, 1.2)), -- cradled asteroid
				boxOn(DRILL, Vector3.new(1.0, 11, 1.0), Vector3.new(-4.6, 6.1, 1.2)), -- gantry posts
				boxOn(DRILL, Vector3.new(1.0, 11, 1.0), Vector3.new(4.6, 6.1, 1.2)),
				boxOn(DRILL, Vector3.new(8.9, 2.6, 2.3), Vector3.new(0, 1.3, -8)), -- console
			},
		},
		M4_TetherCables = {
			models = listModels("M4_TetherRock", TETHERS),
			collision = tetherCollision,
		},
		M4_OreCarts = {
			models = {
				{ key = "M4_CartTrack", cf = TRACK },
				{ key = "M4_OreCart", cf = CARTS[1] },
				{ key = "M4_OreCart", cf = CARTS[2] },
			},
			collision = {},
		},
		M4_CrystalSorter = {
			models = { { key = "M4_CrystalSorter", cf = SORTER } },
			collision = {
				boxOn(SORTER, Vector3.new(8.0, 4.4, 3.2), Vector3.new(0, 2.2, 1.4)), -- machine
				boxOn(SORTER, Vector3.new(8.4, 1.4, 1.6), Vector3.new(0, 0.7, 4.0)), -- candy bins
			},
		},
		M4_GravityMagnets = {
			models = listModels("M4_GravityMagnet", MAGNETS),
			collision = magnetCollision,
		},
		M4_LaserDrills = {
			models = { { key = "M4_LaserDrills", cf = LASERS } },
			collision = {
				boxOn(LASERS, Vector3.new(4.6, 3.2, 4.0), Vector3.new(0, 1.6, 0)), -- crystal rock
				boxOn(LASERS, Vector3.new(2.6, 3.6, 2.6), Vector3.new(-6, 1.8, 0)), -- turrets
				boxOn(LASERS, Vector3.new(2.6, 3.6, 2.6), Vector3.new(6, 1.8, 0)),
			},
		},
		M4_MegaAsteroid = {
			models = { { key = "M4_MegaAsteroid", cf = MEGA } },
			collision = megaCollision,
		},
		M4_Drillbert = {
			models = { { key = "M4_Drillbert", cf = DRILLBERT } },
			collision = {},
		},
		M4_HoverSteps = {
			models = hoverModels,
			collision = stepCollision,
		},
	} :: { [string]: BuildGroup },

	-- BuyPad ground positions (slot-local), alternating either side of the walkway in buy order;
	-- the Unlock pad sits at the far (away-from-hub) end of the row.
	pads = {
		m4_drill_rig = Vector3.new(-11, FLOOR, 9),
		m4_tether_cables = Vector3.new(11, FLOOR, 9),
		m4_ore_carts = Vector3.new(-20, FLOOR, 9),
		m4_crystal_sorter = Vector3.new(20, FLOOR, 9),
		m4_gravity_magnets = Vector3.new(-29, FLOOR, 9),
		m4_laser_drills = Vector3.new(29, FLOOR, 9),
		m4_mega_asteroid = Vector3.new(-38, FLOOR, 9),
		m4_drillbert = Vector3.new(38, FLOOR, 9),
		m4_hover_steps = Vector3.new(-47, FLOOR, 9),
		m4_build_star_lab = Vector3.new(47, FLOOR, 9),
	} :: { [string]: Vector3 },

	-- Billboard anchor at eye level in the clear space in front of the console; the click box wraps
	-- platform, rock, gantry and console.
	producer = {
		anchor = Vector3.new(0, FLOOR + 7.5, BILLBOARD_Z),
		click = { size = PRODUCER_CLICK_SIZE, cf = PRODUCER_CLICK },
	},

	-- Teleport target: on the walkway between the pad row and the arch.
	spawnPoint = Vector3.new(0, FLOOR + 3, 13),
}

return layout
