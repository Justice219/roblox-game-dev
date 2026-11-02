--!strict
--[[
	Worlds/Dino/Layouts/Area05 — slot layout of Dino Valley area D5 "Fossil Lab" (spec
	2026-10-31-world2-design §6.2 / §16; W8 art-d56).

	Contract: identical to AreaLayouts/AreaNN (docs/superpowers/plans/2026-10-30-sellnukes-build.md
	→ "World layout"), validated by src/server/Tycoon/LayoutLogic.luau against the Dino AreaConfig
	(Worlds/Dino/Areas/Area05). Consumed by PlotBuilder for world "dino": `base` is built when D4's
	Unlock pad ("Build the Fossil Lab", key D5_EntryArch) is bought, `builds[buildKey]` when that pad
	is bought (LEGO build-in), pads / producer / spawnPoint at plot build time. D5's own Unlock pad
	(`d5_wake_volcano`, key D6_EntryArch) is NOT here: it resolves to Dino Area06.base.

	Meshes: tools/blender/models/dino_area05.py (D5_*). Art + FX notes: docs/areas-art.md → "Dino D5-D6".

	Frame: SLOT-LOCAL studs. Origin = road-side edge midpoint, +Z away from the road, +Y up,
	x ∈ [-52, 52], z ∈ [0, 70], height budget 80. Identity rotation = model front (-Z) faces the
	road. Standing on the road looking in, +X is on your LEFT. The sand lot (D5_Floor) is a 0.5-stud
	plate: everything stands at y = LOT.

	Scene (top-down, road at the bottom):
		z 51-59  the Big Skeleton on its museum plinth (x 17.5..44.5; skull at x ~14, y ~22)
		z 35-65  the round thatched Lab Hut (producer, r 9.5, roof r 12.6, chimney puffing)
		z 51-59  the giant microscope (x -29) · Dr. Trike + specimen desk (x -42, z 44)
		z 23-33  dusting table (x 19) · dig site (x 38) · amber jars (x -21) · incubators (x -37)
		z 33     museum banner poles either side of the path (x ±9) with bunting across
		z  3     FOSSIL LAB arch (clear width 20), stepping stones up to the hut plaza (r 15)
		z 10     pad row: each pad in front of what it builds; Unlock (wake the volcano) at x 16
	Low mossy stone wall on the sides (z 20..70) and back; palms in the back corners.

	Animated pieces (WorldFx, piece names): D5_LabHut SteamA (existing `Steam` puffs) + Lamp (alias
	`Bulb` light); D5_Microscope Lamp; D5_Incubators Lamp + Wobble* eggs (W10 row "Wobble", bob as one
	group); D5_MuseumBanners Pennant* (existing `Pennant` sway; the rope is the pivot line).
	Manager: D5_DrTrike (R30 rig pieces; joints printed by the Blender build, see docs/areas-art.md).

	Collision: invisible primitive boxes (meshes never collide). Round shapes use nested boxes whose
	corners lie ON the circle (roundCollision), so colliders never poke out of the art.

	Example:
		local layout = require(ReplicatedStorage.Shared.Config.Worlds.Dino.Layouts.Area05)
		print(layout.builds.D5_LabHut.models[1].key) --> "D5_LabHut"
]]

export type ModelPlacement = { key: string, cf: CFrame, tint: Color3?, castShadow: boolean?, collide: boolean? }
export type CollisionBox = { size: Vector3, cf: CFrame }
export type BuildGroup = { models: { ModelPlacement }, collision: { CollisionBox } }

-- Sand lot top (D5_Floor): every model stands at this height.
local LOT = 0.5
-- Lab hut wall radius / wall top and the roof's first tier (D5_LabHut HUT_R, walls y 1..9.2, eave r 12.6).
local HUT_R = 9.5
local HUT_WALL_TOP = 9.2
-- Arch post centre |x| (dino_arch: inner 20 + post 3.6 → 11.8) and pad row z.
local ARCH_POST_X = 11.8
local PAD_Z = 10

--[[
	Slot-local CFrame from a position + yaw in degrees (CCW seen from above, Roblox convention).
	yaw 90 turns a model's front (-Z) toward -X; yaw -90 toward +X; 180 toward +Z.

	Example: at(-29, LOT, 55) -- the microscope, profile facing the road
]]
local function at(x: number, y: number, z: number, yawDeg: number?): CFrame
	return CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yawDeg or 0), 0)
end

--[[
	Collision box anchored to a placed model: `localCentre` is in the model's own frame, so the box
	follows the model's yaw.

	Example: boxOn(AMBER, Vector3.new(6.4, 5.8, 1.8), Vector3.new(0, 2.9, 0)) -- the jar shelf
]]
local function boxOn(model: CFrame, size: Vector3, localCentre: Vector3): CollisionBox
	return { size = size, cf = model * CFrame.new(localCentre) }
end

--[[
	Nested boxes approximating an upright cylinder from the inside: for each half-depth `hz` the box
	half-width is sqrt(r² - hz²), so every box corner lies on the circle (never outside it).

	Example: roundCollision(HUT, 9.5, 9.2, 4.6, { 3, 6, 8.5 }) -- the hut walls
]]
local function roundCollision(
	model: CFrame,
	radius: number,
	height: number,
	centreY: number,
	halfDepths: { number }
): { CollisionBox }
	local boxes: { CollisionBox } = {}
	for _, hz in halfDepths do
		local hw = math.sqrt(radius * radius - hz * hz)
		table.insert(boxes, boxOn(model, Vector3.new(hw * 2, height, hz * 2), Vector3.new(0, centreY, 0)))
	end
	return boxes
end

--[[ Appends every box of `extra` to `list` and returns `list` (keeps the tables below readable). ]]
local function join(list: { CollisionBox }, extra: { CollisionBox }): { CollisionBox }
	for _, box in extra do
		table.insert(list, box)
	end
	return list
end

-- Shared placements (models, collision and the producer below).
local ARCH = at(0, LOT, 3)
local HUT = at(0, LOT, 50) -- door front at local z -10.6 → slot z 39.4
local SKELETON = at(31, LOT, 55) -- plinth 27 x 8; rope barrier at local z -5.4
local MICROSCOPE = at(-29, LOT, 55)
local DR_TRIKE = at(-42.9, LOT, 44) -- figure at the model origin (shared Dino body), specimen desk at local x 3.9
local AMBER = at(-21, LOT, 27)
local INCUBATORS = at(-37, LOT, 28)
local BRUSHES = at(19, LOT, 27)
local DIG_SITE = at(38, LOT, 28)
local BANNERS = at(0, LOT, 33) -- poles at local x ±9
-- Back-corner palms (D5_Floor): trunk foot positions.
local PALMS = { { 46.5, 64 }, { -46.5, 64 } }

local baseCollision: { CollisionBox } = {
	{ size = Vector3.new(104, LOT, 70), cf = at(0, LOT / 2, 35) }, -- sand lot (top = LOT)
	boxOn(ARCH, Vector3.new(4.4, 10, 4.4), Vector3.new(ARCH_POST_X, 5, 0)), -- arch posts (stacked stones)
	boxOn(ARCH, Vector3.new(4.4, 10, 4.4), Vector3.new(-ARCH_POST_X, 5, 0)),
	{ size = Vector3.new(104, 2.3, 1.4), cf = at(0, LOT + 1.15, 69.3) }, -- back wall (+ moss cap)
	{ size = Vector3.new(1.4, 2.3, 50), cf = at(51.3, LOT + 1.15, 45) }, -- side walls (z 20..70)
	{ size = Vector3.new(1.4, 2.3, 50), cf = at(-51.3, LOT + 1.15, 45) },
}
for _, palm in PALMS do
	table.insert(baseCollision, { size = Vector3.new(1.3, 6, 1.3), cf = at(palm[1], LOT + 3, palm[2]) })
end

local layout = {
	area = 5,
	-- Built when D4's Unlock pad ("Build the Fossil Lab", key D5_EntryArch) is bought.
	base = {
		models = {
			{ key = "D5_Floor", cf = CFrame.identity, castShadow = false },
			{ key = "D5_EntryArch", cf = ARCH },
		},
		collision = baseCollision,
	} :: BuildGroup,
	builds = {
		-- Pad 1: the producer "Fossil Lab" (round thatched hut; SteamA chimney puffs, Lamp lanterns).
		D5_LabHut = {
			models = { { key = "D5_LabHut", cf = HUT } },
			collision = join(roundCollision(HUT, HUT_R, HUT_WALL_TOP, HUT_WALL_TOP / 2, { 3, 6, 8.5 }), {
				boxOn(HUT, Vector3.new(17.8, 5.4, 17.8), Vector3.new(0, 11.2, 0)), -- thatch roof tier 1 (inscribed)
				boxOn(HUT, Vector3.new(5.4, 1.1, 1.8), Vector3.new(0, 0.55, -11.35)), -- door step
			}),
		},
		D5_AmberJars = {
			models = { { key = "D5_AmberJars", cf = AMBER } },
			collision = { boxOn(AMBER, Vector3.new(6.4, 5.8, 1.8), Vector3.new(0, 2.9, 0)) },
		},
		-- Giant microscope on a round platform; the ladder on its -X side reaches the eyepiece.
		D5_Microscope = {
			models = { { key = "D5_Microscope", cf = MICROSCOPE } },
			collision = join(roundCollision(MICROSCOPE, 4.4, 0.6, 0.3, { 1.6, 3.2 }), {
				boxOn(MICROSCOPE, Vector3.new(6.4, 10.4, 3.8), Vector3.new(0.4, 5.8, 0)), -- body + arm + tube
				boxOn(MICROSCOPE, Vector3.new(0.5, 10.2, 1.8), Vector3.new(-4, 5.7, 0)), -- ladder
			}),
		},
		-- Three speckled eggs (Wobble*) in straw nests under a heat lamp.
		D5_Incubators = {
			models = { { key = "D5_Incubators", cf = INCUBATORS } },
			collision = {
				boxOn(INCUBATORS, Vector3.new(9.6, 2.5, 3.6), Vector3.new(0, 1.25, 0)), -- bamboo table
				boxOn(INCUBATORS, Vector3.new(8.4, 2.8, 2.4), Vector3.new(0, 3.9, 0)), -- nests + eggs
				boxOn(INCUBATORS, Vector3.new(0.6, 7.4, 0.6), Vector3.new(4.4, 3.7, 1.4)), -- lamp arm pole
			},
		},
		D5_DustingBrushes = {
			models = { { key = "D5_DustingBrushes", cf = BRUSHES } },
			collision = {
				boxOn(BRUSHES, Vector3.new(6.4, 2.8, 3.2), Vector3.new(0, 1.4, 0)), -- work table
				boxOn(BRUSHES, Vector3.new(1.4, 5, 1), Vector3.new(4.2, 2.5, -0.2)), -- giant brush
			},
		},
		-- HERO: the friendly long-neck skeleton (head toward -X, skull at y ~22).
		D5_Skeleton = {
			models = { { key = "D5_Skeleton", cf = SKELETON } },
			collision = {
				boxOn(SKELETON, Vector3.new(27, 1.36, 8), Vector3.new(0, 0.68, 0)), -- plinth
				boxOn(SKELETON, Vector3.new(13, 9.6, 6), Vector3.new(-0.5, 6.2, 0)), -- ribs + legs
				boxOn(SKELETON, Vector3.new(23, 2.6, 0.4), Vector3.new(0.25, 1.3, -5.4)), -- velvet rope barrier
			},
		},
		D5_DigSite = {
			models = { { key = "D5_DigSite", cf = DIG_SITE } },
			collision = {
				boxOn(DIG_SITE, Vector3.new(1.6, 0.9, 10), Vector3.new(5.9, 0.45, 0)), -- side berms
				boxOn(DIG_SITE, Vector3.new(1.6, 0.9, 10), Vector3.new(-5.9, 0.45, 0)),
				boxOn(DIG_SITE, Vector3.new(10, 0.84, 1.5), Vector3.new(0, 0.42, 3.9)), -- back / front berms
				boxOn(DIG_SITE, Vector3.new(10, 0.84, 1.5), Vector3.new(0, 0.42, -3.9)),
				boxOn(DIG_SITE, Vector3.new(0.4, 3.9, 0.4), Vector3.new(-5.3, 1.95, -5.1)), -- DIG sign post
			},
		},
		-- Manager: Dr. Trike (lab coat, goggles, magnifier) beside the specimen desk.
		D5_DrTrike = {
			models = { { key = "D5_DrTrike", cf = DR_TRIKE } },
			collision = {
				boxOn(DR_TRIKE, Vector3.new(2.8, 6.6, 2.6), Vector3.new(0, 3.3, 0)), -- Dr. Trike
				boxOn(DR_TRIKE, Vector3.new(1.4, 2.2, 3.2), Vector3.new(0, 1.9, 2.3)), -- his tail
				boxOn(DR_TRIKE, Vector3.new(2.4, 2.7, 2), Vector3.new(3.9, 1.35, 0)), -- specimen desk
			},
		},
		-- Banner poles either side of the path; bunting (Pennant*) sways over it at y ~12-14.6.
		D5_MuseumBanners = {
			models = { { key = "D5_MuseumBanners", cf = BANNERS } },
			collision = {
				boxOn(BANNERS, Vector3.new(0.8, 15, 0.8), Vector3.new(9, 7.5, 0)),
				boxOn(BANNERS, Vector3.new(0.8, 15, 0.8), Vector3.new(-9, 7.5, 0)),
			},
		},
	} :: { [string]: BuildGroup },
	-- BuyPad ground positions: each pad sits on the pad row in front of what it builds (right of the
	-- path, seen from the road: hut, amber jars, microscope, incubators, Dr. Trike; left: the Unlock
	-- pad right beside the arch, then brushes, skeleton, dig site, banners).
	pads = {
		d5_lab_hut = Vector3.new(-16, LOT, PAD_Z),
		d5_amber_jars = Vector3.new(-24, LOT, PAD_Z),
		d5_microscope = Vector3.new(-32, LOT, PAD_Z),
		d5_incubators = Vector3.new(-40, LOT, PAD_Z),
		d5_dr_trike = Vector3.new(-48, LOT, PAD_Z),
		d5_wake_volcano = Vector3.new(16, LOT, PAD_Z),
		d5_dusting_brushes = Vector3.new(24, LOT, PAD_Z),
		d5_skeleton = Vector3.new(32, LOT, PAD_Z),
		d5_dig_site = Vector3.new(40, LOT, PAD_Z),
		d5_museum_banners = Vector3.new(48, LOT, PAD_Z),
	} :: { [string]: Vector3 },
	-- Billboard (owner R31 / R32): the client puts it FrontGap (2.5) in front of the click box (front
	-- z 39.5, just in front of the door jambs at 39.3) at eye level (7.5 over the lot): slot
	-- (0, 8, 37), between the banner poles (x ±9) and under the bunting (lowest flag y ~12).
	producer = {
		anchor = Vector3.new(0, LOT + 7.5, 37),
		click = { size = Vector3.new(21, 22, 21), cf = HUT * CFrame.new(0, 11, 0) },
	},
	-- Teleport target (ground level on the stepping stones, just inside the arch).
	spawnPoint = Vector3.new(0, LOT, 9),
}

return layout
