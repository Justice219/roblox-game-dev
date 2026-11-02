--!strict
--[[
	Worlds/Moon/Layouts/Area03 — slot layout of Moon Base area M3 "UFO Delivery" (spec
	2026-10-31-r69-moon-lucky-juice-design §2.2, owner R70; W7 art-d34). Replaces W1's placeholder.

	Contract: identical to AreaLayouts/AreaNN (docs/superpowers/plans/2026-10-30-sellnukes-build.md
	→ "World layout"), validated by src/server/Tycoon/LayoutLogic.luau against the Moon AreaConfig
	(Worlds/Moon/Areas/Area03). `base` is built when M2's Unlock pad (build key `M3_EntryArch`) is
	bought, `builds[buildKey]` when that pad is bought, pads / producer / spawnPoint at plot build
	time. The Unlock pad's key `M4_EntryArch` is NOT here: it resolves to Moon Area04.base.

	Meshes: tools/blender/models/moon_area03.py (keys `M3_*`, MeshAssets). Art notes:
	docs/areas-art.md → "Moon Base M3 / M4".

	Frame: SLOT-LOCAL studs. Origin = road-side edge midpoint, +Z away from the road, +Y up,
	x ∈ [-52, 52], z ∈ [0, 70]. Identity rotation = model front (-Z) faces the road. Standing on the
	road looking in, +X is on your LEFT. The moon-dust slab tops out at y = 0.4 (FLOOR).

	Scene (top-down, road at the bottom):
		z 58-70  back moon rocks, crystal clusters and antenna masts (M3_Rocks, base)
		z 40-59  Saucer Dock (producer, x 0): landing deck on four legs (top y 10.8), glass parcel
		         elevator, conveyor to the sorting counter at z 40.4; two UFO couriers parked on the deck
		z 36.6   producer billboard at eye level in front of the counter (R31 / R32)
		z 26-42  tractor-beam pad (x 28), Captain Glorp beside the side path (x 17), radar dish (x 41)
		z 31     candy launch ring (x -16, centre y 16.4): courier IN flies through it toward the road
		z 19-43  three fleet saucers hovering on pads (x -37 .. -42), parcel pods (x ±13, z 40.5)
		z 47-53  star map (x 40), angled toward the walkway
		z 18     UFO DELIVERY arch (W6's shared moon_arch) over the tile walkway x ∈ [-5, 5]
		z 9      pad row (alternating either side of the walkway, buy order outward)

	Low gravity (spec §2.4: gravityScale 0.4): players jump ~16 studs here, so everything a player
	could land on (the landing deck, the pods, the ring legs) has a collision box; small props and the
	couriers (routed, R56) stay walk-through.

	Static checks: no interpenetration (owner R24, check_area_overlaps.py --world moon), no coplanar
	faces (R18, tests/zfight-audit.luau), billboard spot clear (R31 / R32), the couriers' routes
	(VehicleRouteConfig "Moon Base M3/M4") clear every piece box + collider (tests/vehicle-routes).

	Example (PlotBuilder):
		local layout = require(ReplicatedStorage.Shared.Config.Worlds.Moon.Layouts.Area03)
		print(layout.builds.M3_SaucerDock.models[2].key) --> "M3_UfoCourier"
]]

export type ModelPlacement = { key: string, cf: CFrame, tint: Color3? }
export type CollisionBox = { size: Vector3, cf: CFrame }
export type BuildGroup = { models: { ModelPlacement }, collision: { CollisionBox } }

-- Floor slab top (M3_Floor); every floor-standing model is placed at this height.
local FLOOR = 0.4
-- Landing deck top above the dock pivot (moon_area03.py DECK_TOP).
local DECK_TOP = 10.4

--[[
	Slot-local CFrame helper: position + yaw in degrees (CCW from above, Roblox convention).
	yaw -90 turns a model's front (-Z) toward +X; yaw 90 toward -X; 180 toward +Z.

	Example: at(40, FLOOR, 50, 50) -- the star map, turned toward the walkway (-X) and the road
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

-- Shared placements (models, collision and VehicleRouteConfig's M3 courier routes use these).
local DOCK = at(0, FLOOR, 50) -- producer: deck centre; counter at local z -9.6 (slot z 40.4)
-- Parked couriers (ROUTED, W7 VehicleRouteConfig "M3_CourierOut" / "M3_CourierIn"): these are the
-- rest poses Low quality / Reduce Motion keep. Courier OUT faces the tractor pad, courier IN the
-- launch ring.
local COURIERS = {
	DOCK * at(4.4, DECK_TOP, -1.6, -58.6),
	DOCK * at(-4.4, DECK_TOP, 1.6, 60),
}
local TRACTOR = at(28, FLOOR, 34)
local PODS = {
	at(-13, FLOOR, 40.5, 15),
	at(13, FLOOR, 40.5, -15),
}
local RADAR = at(41, FLOOR, 23)
-- Fleet saucers: one model, three placements, Hull tinted coral / mint / sunny.
local FLEET = {
	{ cf = at(-42, FLOOR, 22, -30), tint = Color3.fromRGB(255, 124, 108) },
	{ cf = at(-37, FLOOR, 31, -60), tint = Color3.fromRGB(110, 226, 180) },
	{ cf = at(-42, FLOOR, 40, -80), tint = Color3.fromRGB(255, 214, 60) },
}
local STAR_MAP = at(40, FLOOR, 50, 50)
-- Launch ring (plane faces the road): centre (-16, 16.4, 31); courier IN flies through it.
local RING = at(-16, FLOOR, 31)
-- Captain Glorp (manager NPC, owner R30) starts beside the side path, turned toward the walkway;
-- the client ManagerController walks him from here, so he has no collision box.
local CAPTAIN = at(17, FLOOR, 26, 20)
-- Producer click box (wraps legs, elevator, conveyor and counter) and the billboard spot in front
-- of it (owner R31 / R32): the billboard sits FrontGap (2.5) past the click box's road-side face at
-- EyeHeight (7.5). The slot in front (z 36 .. 37.2, x within ±7.2, y 2 .. 14) is clear of every
-- visible piece box: the pods stand at x ±13, the launch ring at z 31, the backdrop at z >= 50.
local PRODUCER_CLICK = DOCK * CFrame.new(0, 6, -2.6)
local PRODUCER_CLICK_SIZE = Vector3.new(17.4, 12.6, 16.6)
local BILLBOARD_Z = PRODUCER_CLICK.Position.Z - PRODUCER_CLICK_SIZE.Z / 2 - 2.5

-- Base collision: floor, arch posts.
local baseCollision: { CollisionBox } = {
	{ size = Vector3.new(104, 1, 70), cf = at(0, FLOOR - 0.5, 35) }, -- floor (top = FLOOR)
	{ size = Vector3.new(4.4, 9.1, 4.4), cf = at(-9, FLOOR + 4.55, 18) }, -- arch capsule posts
	{ size = Vector3.new(4.4, 9.1, 4.4), cf = at(9, FLOOR + 4.55, 18) },
}

-- Dock collision: four legs, the elevator, the counter and the round deck (two crossing boxes).
local dockCollision: { CollisionBox } = {
	boxOn(DOCK, Vector3.new(3.6, 9.4, 3.6), Vector3.new(0, 4.7, 0)), -- glass elevator + plinth
	boxOn(DOCK, Vector3.new(10.3, 2.7, 2.5), Vector3.new(0, 1.35, -9.6)), -- sorting counter
	boxOn(DOCK, Vector3.new(16.6, 1, 11.6), Vector3.new(0, 9.9, 0)), -- landing deck
	boxOn(DOCK, Vector3.new(11.6, 1, 16.6), Vector3.new(0, 9.9, 0)),
}
for k = 0, 3 do
	local a = math.rad(45 + 90 * k)
	table.insert(
		dockCollision,
		boxOn(DOCK, Vector3.new(1.4, 9.4, 1.4), Vector3.new(6.0 * math.sin(a), 4.7, -6.0 * math.cos(a)))
	)
end

local podCollision: { CollisionBox } = {}
for _, cf in PODS do
	table.insert(podCollision, boxOn(cf, Vector3.new(5.4, 3.7, 4.0), Vector3.new(0.2, 1.85, 0)))
end

local fleetModels: { ModelPlacement } = {}
local fleetCollision: { CollisionBox } = {}
for _, saucer in FLEET do
	table.insert(fleetModels, { key = "M3_FleetSaucer", cf = saucer.cf, tint = saucer.tint })
	-- Pad only (the saucer hovers above; low-gravity jumpers may land on its pad).
	table.insert(fleetCollision, boxOn(saucer.cf, Vector3.new(5.4, 0.35, 5.4), Vector3.new(0, 0.18, 0)))
end

local layout = {
	area = 3,

	-- Built when M3 unlocks: moon-dust floor, UFO DELIVERY arch, back rocks + crystals + masts.
	base = {
		models = {
			{ key = "M3_Floor", cf = at(0, 0, 35) },
			{ key = "M3_EntryArch", cf = at(0, FLOOR, 18) },
			{ key = "M3_Rocks", cf = at(0, FLOOR, 0) },
		},
		collision = baseCollision,
	},

	builds = {
		-- First pad (builder): the Saucer Dock producer + its two parked couriers.
		M3_SaucerDock = {
			models = {
				{ key = "M3_SaucerDock", cf = DOCK },
				{ key = "M3_UfoCourier", cf = COURIERS[1] },
				{ key = "M3_UfoCourier", cf = COURIERS[2] },
			},
			collision = dockCollision,
		},
		M3_TractorBeam = {
			models = { { key = "M3_TractorBeam", cf = TRACTOR } },
			collision = {
				boxOn(TRACTOR, Vector3.new(12.2, 0.7, 8.6), Vector3.new(0, 0.35, 0)),
				boxOn(TRACTOR, Vector3.new(8.6, 0.7, 12.2), Vector3.new(0, 0.35, 0)),
			},
		},
		M3_ParcelPods = {
			models = {
				{ key = "M3_ParcelPods", cf = PODS[1] },
				{ key = "M3_ParcelPods", cf = PODS[2] },
			},
			collision = podCollision,
		},
		M3_RadarDish = {
			models = { { key = "M3_RadarDish", cf = RADAR } },
			collision = {
				boxOn(RADAR, Vector3.new(3.6, 0.7, 3.6), Vector3.new(0, 0.35, 0)),
				boxOn(RADAR, Vector3.new(0.8, 9.2, 0.8), Vector3.new(0, 4.6, 0)), -- mast
			},
		},
		M3_UfoFleet = {
			models = fleetModels,
			collision = fleetCollision,
		},
		M3_StarMap = {
			models = { { key = "M3_StarMap", cf = STAR_MAP } },
			collision = { boxOn(STAR_MAP, Vector3.new(8.6, 7.2, 1.4), Vector3.new(0, 3.6, 0.1)) },
		},
		M3_LaunchRing = {
			models = { { key = "M3_LaunchRing", cf = RING } },
			collision = {
				boxOn(RING, Vector3.new(1.6, 16, 1.6), Vector3.new(-7.0, 8, 0)),
				boxOn(RING, Vector3.new(1.6, 16, 1.6), Vector3.new(7.0, 8, 0)),
			},
		},
		M3_CaptainGlorp = {
			models = { { key = "M3_CaptainGlorp", cf = CAPTAIN } },
			collision = {},
		},
	} :: { [string]: BuildGroup },

	-- BuyPad ground positions (slot-local), alternating either side of the walkway in buy order;
	-- the Unlock pad sits at the far (away-from-hub) end of the row.
	pads = {
		m3_saucer_dock = Vector3.new(-11, FLOOR, 9),
		m3_tractor_beam = Vector3.new(11, FLOOR, 9),
		m3_parcel_pods = Vector3.new(-20, FLOOR, 9),
		m3_radar_dish = Vector3.new(20, FLOOR, 9),
		m3_ufo_fleet = Vector3.new(-29, FLOOR, 9),
		m3_star_map = Vector3.new(29, FLOOR, 9),
		m3_launch_ring = Vector3.new(-38, FLOOR, 9),
		m3_captain_glorp = Vector3.new(38, FLOOR, 9),
		m3_mine_asteroids = Vector3.new(-47, FLOOR, 9),
	} :: { [string]: Vector3 },

	-- Billboard anchor at eye level in the clear space in front of the counter; the click box wraps
	-- the whole dock below the deck.
	producer = {
		anchor = Vector3.new(0, FLOOR + 7.5, BILLBOARD_Z),
		click = { size = PRODUCER_CLICK_SIZE, cf = PRODUCER_CLICK },
	},

	-- Teleport target: on the walkway between the pad row and the arch.
	spawnPoint = Vector3.new(0, FLOOR + 3, 13),
}

return layout
