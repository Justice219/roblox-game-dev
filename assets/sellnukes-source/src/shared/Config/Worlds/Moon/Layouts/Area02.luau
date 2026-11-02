--!strict
--[[
	Worlds/Moon/Layouts/Area02 — slot layout of Moon Base area M2 "Cosmic Diner" (spec
	2026-10-31-r69-moon-lucky-juice-design §2.2; W6 art-d12, owner R70). Replaces W1's temporary
	placeholder.

	Contract: identical to AreaLayouts/AreaNN (docs/superpowers/plans/2026-10-30-sellnukes-build.md
	→ "World layout"), validated by src/server/Tycoon/LayoutLogic.luau against the Moon AreaConfig
	(Worlds/Moon/Areas/Area02). Consumed by PlotBuilder.world("moon"): `base` is built when M2
	unlocks (M1's Unlock pad key `M2_EntryArch` resolves here), `builds[buildKey]` when that pad is
	bought, pads / producer / spawnPoint at plot build time. The Unlock pad's key `M3_EntryArch` is
	NOT here: it resolves to Moon Area03.base.

	Meshes: tools/blender/models/moon_area02.py (M2_*) + M1_RockCluster (moon_area01.py) as base
	decor. Art notes: docs/areas-art.md → "Moon M2".

	Frame: SLOT-LOCAL studs. Origin = road-side edge midpoint, +Z away from the road, +Y up,
	x ∈ [-52, 52], z ∈ [0, 70]. Identity rotation = model front (-Z) faces the road. Standing on
	the road looking in, +X is on your LEFT. The lot (M2_Floor) is a 0.5-stud plate (y = LOT) with a
	mint / white checkered patio (x ±22, z 18..50, top +0.08) and a dust path down to the arch.

	Scene (top-down, road at the bottom):
		z 56-66  the retro diner hall (x ±19), rocket fin on the roof
		z 39-45  the walk-up counter (producer) with stools, Zip Zorp behind it, the star
		         register + shake machine on the counter top
		z 47     the rocket NUKES sign (x -16) and the rocket jukebox (x 15)
		z 30     two booths on the patio (x ±15)
		z 17-29  two rows of runway lights either side of the patio's middle aisle (x ±6.5)
		z 24/42  four saucer-umbrella tables on the moon dust beside the patio (x ±34)
		z 4      COSMIC DINER arch (clear width 14)
		z 10     pad row: buy order alternates either side of the arch, moving outward

	Animated pieces (WorldFx "-- Moon Base M1/M2" rows): M2_RocketJukebox `Jukebox*` light bands
	(soft pulsing light), `Bulb*` sign stars / runway globes (soft light). Manager: M2_ZipZorp
	(R30 rig; ManagerNpcConfig.Rigs.M2_ZipZorp).

	Example:
		local layout = require(ReplicatedStorage.Shared.Config.Worlds.Moon.Layouts.Area02)
		print(layout.builds.M2_DinerCounter.models[1].key) --> "M2_DinerCounter"
]]

export type ModelPlacement = { key: string, cf: CFrame, tint: Color3?, castShadow: boolean?, collide: boolean? }
export type CollisionBox = { size: Vector3, cf: CFrame }
export type BuildGroup = { models: { ModelPlacement }, collision: { CollisionBox } }

-- Lot top (M2_Floor).
local LOT = 0.5
-- Counter top above the counter pivot (M2_DinerCounter COUNTER_TOP).
local COUNTER_TOP = 3.2

--[[
	Slot-local CFrame from a position + yaw in degrees (CCW seen from above, Roblox convention).
	yaw 90 turns a model's front (-Z) toward -X; yaw -90 toward +X; 180 toward +Z.

	Example: at(6.5, LOT, 23, 90) -- a runway light row along Z
]]
local function at(x: number, y: number, z: number, yawDeg: number?): CFrame
	return CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yawDeg or 0), 0)
end

--[[
	Collision box anchored to a placed model: `localCentre` is in the model's own frame, so the box
	follows the model's yaw.
]]
local function boxOn(model: CFrame, size: Vector3, localCentre: Vector3): CollisionBox
	return { size = size, cf = model * CFrame.new(localCentre) }
end

--[[ Builds a list of the same mesh at several placements. ]]
local function listModels(key: string, placements: { CFrame }): { ModelPlacement }
	local models: { ModelPlacement } = {}
	for _, cf in placements do
		table.insert(models, { key = key, cf = cf })
	end
	return models
end

--[[ One box per placement, each in that placement's own frame. ]]
local function listCollision(placements: { CFrame }, size: Vector3, localCentre: Vector3): { CollisionBox }
	local boxes: { CollisionBox } = {}
	for _, cf in placements do
		table.insert(boxes, boxOn(cf, size, localCentre))
	end
	return boxes
end

-- Shared placements.
local ARCH = at(0, LOT, 4)
local HALL = at(0, LOT, 61) -- stadium 38 x 10: x ±19, z 56..66
local COUNTER = at(0, LOT, 41) -- counter x ±7.2, z 39.6..42.4; stools at z 38.3
local ZORP = COUNTER * CFrame.new(-2.5, 0, 3.4) -- behind the counter, facing the customers
local SIGN = at(-16, LOT, 47)
local JUKEBOX = at(15, LOT, 47, 20)
local BOOTHS = { at(-15, LOT, 30), at(15, LOT, 30) }
local TABLES = { at(-34, LOT, 24), at(34, LOT, 24), at(-34, LOT, 42), at(34, LOT, 42) }
-- Runway light rows (12 long along local X), turned to run along Z either side of the aisle.
local RUNWAYS = { at(-6.5, LOT, 23, 90), at(6.5, LOT, 23, 90) }
-- M1_RockCluster placements (base decor; any yaw) clear of the pads, patio and builds.
local ROCKS = {
	at(-44, LOT, 50, 40),
	at(45, LOT, 52, -20),
	at(-28, LOT, 62, 110),
	at(37, LOT, 63, 200),
	at(-41, LOT, 18, 70),
	at(42, LOT, 17, -60),
}

local baseCollision: { CollisionBox } = {
	{ size = Vector3.new(104, LOT, 70), cf = at(0, LOT / 2, 35) }, -- lot (top = LOT)
	boxOn(ARCH, Vector3.new(4.4, 9, 4.4), Vector3.new(9, 4.5, 0)), -- capsule arch posts
	boxOn(ARCH, Vector3.new(4.4, 9, 4.4), Vector3.new(-9, 4.5, 0)),
	boxOn(HALL, Vector3.new(28, 7.7, 10.6), Vector3.new(0, 3.85, 0)), -- diner hall middle
	boxOn(HALL, Vector3.new(7.6, 7.7, 7.6), Vector3.new(-15.6, 3.85, 0)), -- its round ends
	boxOn(HALL, Vector3.new(7.6, 7.7, 7.6), Vector3.new(15.6, 3.85, 0)),
}
for _, cf in ROCKS do
	table.insert(baseCollision, boxOn(cf, Vector3.new(4.6, 2.4, 3.8), Vector3.new(0, 1.2, 0)))
end

local layout = {
	area = 2,
	-- Built when M2 unlocks: lot + checkered patio, the arch, the diner hall, rock clusters.
	base = {
		models = (function(): { ModelPlacement }
			local models: { ModelPlacement } = {
				{ key = "M2_Floor", cf = CFrame.identity, castShadow = false },
				{ key = "M2_DinerHall", cf = HALL },
				{ key = "M2_EntryArch", cf = ARCH },
			}
			for _, cf in ROCKS do
				table.insert(models, { key = "M1_RockCluster", cf = cf })
			end
			return models
		end)(),
		collision = baseCollision,
	} :: BuildGroup,
	builds = {
		-- Pad 1: the producer — walk-up counter with stools and moon-rock nukes on cake stands.
		M2_DinerCounter = {
			models = { { key = "M2_DinerCounter", cf = COUNTER } },
			collision = {
				boxOn(COUNTER, Vector3.new(14.4, COUNTER_TOP, 2.9), Vector3.new(0, COUNTER_TOP / 2, 0.1)),
				boxOn(COUNTER, Vector3.new(11, 2.3, 1.4), Vector3.new(0, 1.15, -2.7)), -- stools
			},
		},
		M2_NeonSign = {
			models = { { key = "M2_NeonSign", cf = SIGN } },
			collision = {
				boxOn(SIGN, Vector3.new(2.8, 0.6, 2.8), Vector3.new(0, 0.3, 0)),
				boxOn(SIGN, Vector3.new(0.7, 7.2, 0.7), Vector3.new(0, 3.6, 0)),
			},
		},
		-- Counter-top props (the counter's own box covers them).
		M2_StarRegister = {
			models = { { key = "M2_StarRegister", cf = COUNTER * CFrame.new(4.6, COUNTER_TOP, 0.2) } },
			collision = {},
		},
		M2_BoothSeats = {
			models = listModels("M2_BoothSeats", BOOTHS),
			collision = (function(): { CollisionBox }
				local boxes = listCollision(BOOTHS, Vector3.new(3.2, 2.5, 3.2), Vector3.new(0, 1.25, 0))
				for _, z in { -2.5, 2.5 } do
					for _, box in listCollision(BOOTHS, Vector3.new(4.2, 3.6, 1.6), Vector3.new(0, 1.8, z * 1.1)) do
						table.insert(boxes, box)
					end
				end
				return boxes
			end)(),
		},
		M2_RocketJukebox = {
			models = { { key = "M2_RocketJukebox", cf = JUKEBOX } },
			collision = { boxOn(JUKEBOX, Vector3.new(3.6, 6.8, 3.6), Vector3.new(0, 3.4, 0)) },
		},
		M2_ShakeMachine = {
			models = { { key = "M2_ShakeMachine", cf = COUNTER * CFrame.new(-4.4, COUNTER_TOP, 0.2) } },
			collision = {},
		},
		M2_CraterTables = {
			models = listModels("M2_CraterTables", TABLES),
			collision = (function(): { CollisionBox }
				local boxes = listCollision(TABLES, Vector3.new(2.7, 2.4, 2.7), Vector3.new(0, 1.2, 0))
				for _, x in { -1.9, 1.9 } do
					for _, box in listCollision(TABLES, Vector3.new(1.1, 1.6, 1.1), Vector3.new(x, 0.8, 0)) do
						table.insert(boxes, box)
					end
				end
				return boxes
			end)(),
		},
		-- Manager: Zip Zorp behind the counter.
		M2_ZipZorp = {
			models = { { key = "M2_ZipZorp", cf = ZORP } },
			collision = { boxOn(ZORP, Vector3.new(3, 6.6, 2.6), Vector3.new(0, 3.3, 0)) },
		},
		M2_LandingLights = {
			models = listModels("M2_LandingLights", RUNWAYS),
			collision = listCollision(RUNWAYS, Vector3.new(10, 2.3, 0.6), Vector3.new(0, 1.15, 0)),
		},
	} :: { [string]: BuildGroup },
	-- BuyPad ground positions: alternate either side of the arch in buy order, moving outward; the
	-- Unlock pad (Call the UFO Couriers) at the +X end.
	pads = {
		m2_diner_counter = Vector3.new(-16, LOT, 10),
		m2_neon_sign = Vector3.new(16, LOT, 10),
		m2_star_register = Vector3.new(-24, LOT, 10),
		m2_booth_seats = Vector3.new(24, LOT, 10),
		m2_rocket_jukebox = Vector3.new(-32, LOT, 10),
		m2_shake_machine = Vector3.new(32, LOT, 10),
		m2_crater_tables = Vector3.new(-40, LOT, 10),
		m2_zip_zorp = Vector3.new(40, LOT, 10),
		m2_landing_lights = Vector3.new(-48, LOT, 10),
		m2_call_ufos = Vector3.new(48, LOT, 10),
	} :: { [string]: Vector3 },
	-- The anchor is where the client puts the producer billboard (owner R31 / R32): in front of the
	-- stools (z 37.6), 6 above the lot, over the patio's middle aisle.
	producer = {
		anchor = Vector3.new(0, LOT + 6, 35.4),
		click = { size = Vector3.new(14.8, 4.0, 4.0), cf = COUNTER * CFrame.new(0, 2, 0) },
	},
	-- Teleport target (ground level, on the dust path inside the arch).
	spawnPoint = Vector3.new(0, LOT, 12),
}

return layout
