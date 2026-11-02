--!strict
--[[
	Worlds/Moon/Layouts/Area05 — slot layout of Moon Base area M5 "Star Lab" (R69-R71 spec §2.2,
	owner R70; W8 art-d56).

	Contract: identical to AreaLayouts/AreaNN (docs/superpowers/plans/2026-10-30-sellnukes-build.md
	→ "World layout"), validated by src/server/Tycoon/LayoutLogic.luau against the Moon AreaConfig
	(Worlds/Moon/Areas/Area05). `base` is built when M4's Unlock pad ("Build the Star Lab", key
	M5_EntryArch) is bought, `builds[buildKey]` when that pad is bought (LEGO build-in), pads /
	producer / spawnPoint at plot build time. M5's own Unlock pad (`m5_light_star`, key
	M6_EntryArch) is NOT here: it resolves to Moon Area06.base.

	Meshes: tools/blender/models/moon_area05.py (M5_*). Art + FX notes: docs/areas-art.md → "Moon M5-M6".

	Frame: SLOT-LOCAL studs. Origin = road-side edge midpoint, +Z away from the road, +Y up,
	x ∈ [-52, 52], z ∈ [0, 70], height budget 80. Identity rotation = model front (-Z) faces the
	road. Standing on the road looking in, +X is on your LEFT. The moon-dust lot (M5_Floor) is a
	0.5-stud plate: everything stands at y = LOT.

	Scene (top-down, road at the bottom):
		z 38-61  the Lab Dome observatory (producer, r 9.5, dome top y ~17.8) on a round plaza (r 14)
		z 49-60  the Big Telescope (x 31, tube up toward the dome) · the Planet Mobile (x -29)
		z 40-48  Dr. Nova at her bench (x -43)
		z 23-33  comet catcher (x 19) · robot arm (x 39) · star jars (x -21) · moon garden (x -38)
		z 33     mission banner poles either side of the path (x ±9) with bunting across
		z  3     STAR LAB arch (clear width 20), round chrome stepping tiles up to the plaza
		z 10     pad row: each pad in front of what it builds; Unlock (light the star) at x 16
	Low lumpy moon-rock wall with violet caps on the sides (z 20..70) and back; craters + crystals.

	Animated pieces (WorldFx names): M5_PlanetMobile Twirl* (arms, strings, planet pairs, sun: all
	point-symmetric about the pole); M5_LabDome Lamp (porch light) + Beacon (static Neon);
	M5_MissionBanners Pennant* (sway). Manager: M5_DrNova (R30 rig pieces).

	Collision: invisible primitive boxes (meshes never collide). Round shapes use nested boxes whose
	corners lie ON the circle (roundCollision), so colliders never poke out of the art.

	Example:
		local layout = require(ReplicatedStorage.Shared.Config.Worlds.Moon.Layouts.Area05)
		print(layout.builds.M5_LabDome.models[1].key) --> "M5_LabDome"
]]

export type ModelPlacement = { key: string, cf: CFrame, tint: Color3?, castShadow: boolean?, collide: boolean? }
export type CollisionBox = { size: Vector3, cf: CFrame }
export type BuildGroup = { models: { ModelPlacement }, collision: { CollisionBox } }

-- Moon-dust lot top (M5_Floor): every model stands at this height.
local LOT = 0.5
-- Lab dome drum radius / drum top (M5_LabDome DOME_R, DRUM_H).
local DOME_R = 9.5
local DRUM_H = 7.5
-- Arch post centre |x| (W6 moon_arch: inner / 2 + post_r 1.6 + 0.4 → 12) and pad row z.
local ARCH_POST_X = 12
local PAD_Z = 10

--[[
	Slot-local CFrame from a position + yaw in degrees (CCW seen from above, Roblox convention).
	yaw 90 turns a model's front (-Z) toward -X; yaw -90 toward +X; 180 toward +Z.

	Example: at(-29, LOT, 54) -- the planet mobile
]]
local function at(x: number, y: number, z: number, yawDeg: number?): CFrame
	return CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yawDeg or 0), 0)
end

--[[
	Collision box anchored to a placed model: `localCentre` is in the model's own frame, so the box
	follows the model's yaw.

	Example: boxOn(JARS, Vector3.new(6.4, 5.8, 1.8), Vector3.new(0, 2.9, 0)) -- the jar rack
]]
local function boxOn(model: CFrame, size: Vector3, localCentre: Vector3): CollisionBox
	return { size = size, cf = model * CFrame.new(localCentre) }
end

--[[
	Nested boxes approximating an upright cylinder from the inside: for each half-depth `hz` the box
	half-width is sqrt(r² - hz²), so every box corner lies on the circle (never outside it).

	Example: roundCollision(DOME, 9.5, 7.5, 3.75, { 3, 6, 8.5 }) -- the dome drum
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

-- Shared placements.
local ARCH = at(0, LOT, 3)
local DOME = at(0, LOT, 50) -- door front at local z -10.45 → slot z 39.55
local JARS = at(-21, LOT, 27)
local TELESCOPE = at(31, LOT, 54) -- tube rises toward -X (lens at local x ~-10, y ~16)
local MOBILE = at(-29, LOT, 54) -- arms r 5.2 + planets → x -35.3..-22.7
local CATCHER = at(19, LOT, 27)
local ROBOT_ARM = at(39, LOT, 28)
local GARDEN = at(-38, LOT, 28)
local DR_NOVA = at(-43, LOT, 44) -- figure at the model origin, bench at local +X
local BANNERS = at(0, LOT, 33) -- poles at local x ±9

local layout = {
	area = 5,
	-- Built when M4's Unlock pad ("Build the Star Lab", key M5_EntryArch) is bought.
	base = {
		models = {
			{ key = "M5_Floor", cf = CFrame.identity, castShadow = false },
			{ key = "M5_EntryArch", cf = ARCH },
		},
		collision = {
			{ size = Vector3.new(104, LOT, 70), cf = at(0, LOT / 2, 35) }, -- moon-dust lot (top = LOT)
			boxOn(ARCH, Vector3.new(4.4, 10, 4.4), Vector3.new(ARCH_POST_X, 5, 0)), -- arch pillars (+ plinths)
			boxOn(ARCH, Vector3.new(4.4, 10, 4.4), Vector3.new(-ARCH_POST_X, 5, 0)),
			{ size = Vector3.new(104, 2.3, 1.4), cf = at(0, LOT + 1.15, 69.3) }, -- back wall (+ caps)
			{ size = Vector3.new(1.4, 2.3, 50), cf = at(51.3, LOT + 1.15, 45) }, -- side walls (z 20..70)
			{ size = Vector3.new(1.4, 2.3, 50), cf = at(-51.3, LOT + 1.15, 45) },
		},
	} :: BuildGroup,
	builds = {
		-- Pad 1: the producer "Star Lab" (domed observatory).
		M5_LabDome = {
			models = { { key = "M5_LabDome", cf = DOME } },
			collision = join(roundCollision(DOME, DOME_R, DRUM_H, DRUM_H / 2, { 3, 6, 8.5 }), {
				boxOn(DOME, Vector3.new(13, 7, 13), Vector3.new(0, DRUM_H + 3.5, 0)), -- dome (inscribed)
				boxOn(DOME, Vector3.new(5, 1.1, 2), Vector3.new(0, 0.55, -11.1)), -- door step
			}),
		},
		M5_StarJars = {
			models = { { key = "M5_StarJars", cf = JARS } },
			collision = { boxOn(JARS, Vector3.new(6.4, 5.8, 1.8), Vector3.new(0, 2.9, 0)) },
		},
		-- Giant telescope on a round platform (tube toward the dome, up into the sky).
		M5_BigTelescope = {
			models = { { key = "M5_BigTelescope", cf = TELESCOPE } },
			collision = join(roundCollision(TELESCOPE, 5, 0.7, 0.35, { 1.8, 3.4 }), {
				boxOn(TELESCOPE, Vector3.new(4.8, 3.6, 4.8), Vector3.new(0, 1.8, 0)), -- turret
				boxOn(TELESCOPE, Vector3.new(1.4, 7.4, 4.4), Vector3.new(0, 3.7, 0)), -- fork mount
			}),
		},
		-- Planet mobile: Twirl* arms + planets spin about the pole.
		M5_PlanetMobile = {
			models = { { key = "M5_PlanetMobile", cf = MOBILE } },
			collision = join(roundCollision(MOBILE, 3, 1.1, 0.55, { 1, 2 }), {
				boxOn(MOBILE, Vector3.new(0.7, 14.6, 0.7), Vector3.new(0, 8, 0)), -- pole
			}),
		},
		M5_CometCatcher = {
			models = { { key = "M5_CometCatcher", cf = CATCHER } },
			collision = { boxOn(CATCHER, Vector3.new(3.4, 6, 3.4), Vector3.new(0, 3, 0.6)) }, -- tripod
		},
		M5_RobotArm = {
			models = { { key = "M5_RobotArm", cf = ROBOT_ARM } },
			collision = join(roundCollision(ROBOT_ARM, 3, 2, 1, { 1, 2 }), {
				boxOn(ROBOT_ARM, Vector3.new(2.4, 7, 2.4), Vector3.new(0, 5.5, 1.2)), -- upright arm
				boxOn(ROBOT_ARM, Vector3.new(1.8, 2, 1.4), Vector3.new(3.6, 1, -1.6)), -- button box
			}),
		},
		M5_MoonGarden = {
			models = { { key = "M5_MoonGarden", cf = GARDEN } },
			collision = {
				boxOn(GARDEN, Vector3.new(4.4, 1, 3.4), Vector3.new(-2.6, 0.5, 0)), -- planters
				boxOn(GARDEN, Vector3.new(4.4, 1, 3.4), Vector3.new(2.6, 0.5, 0)),
				boxOn(GARDEN, Vector3.new(3.2, 2.8, 3.2), Vector3.new(2.6, 2.5, 0)), -- glass dome
			},
		},
		-- Manager: Dr. Nova (alien scientist, lab coat) beside her bench.
		M5_DrNova = {
			models = { { key = "M5_DrNova", cf = DR_NOVA } },
			collision = {
				boxOn(DR_NOVA, Vector3.new(2.8, 6.6, 2.6), Vector3.new(0, 3.3, 0)), -- Dr. Nova
				boxOn(DR_NOVA, Vector3.new(2.4, 2.7, 2), Vector3.new(3.9, 1.35, 0)), -- bench
			},
		},
		-- Banner poles either side of the path; bunting (Pennant*) sways over it at y ~12-14.6.
		M5_MissionBanners = {
			models = { { key = "M5_MissionBanners", cf = BANNERS } },
			collision = {
				boxOn(BANNERS, Vector3.new(0.8, 15, 0.8), Vector3.new(9, 7.5, 0)),
				boxOn(BANNERS, Vector3.new(0.8, 15, 0.8), Vector3.new(-9, 7.5, 0)),
			},
		},
	} :: { [string]: BuildGroup },
	-- BuyPad ground positions: each pad sits on the pad row in front of what it builds (right of the
	-- path, seen from the road: dome, jars, mobile, garden, Dr. Nova; left: the Unlock pad right
	-- beside the arch, then catcher, telescope, robot arm, banners).
	pads = {
		m5_lab_dome = Vector3.new(-16, LOT, PAD_Z),
		m5_star_jars = Vector3.new(-24, LOT, PAD_Z),
		m5_planet_mobile = Vector3.new(-32, LOT, PAD_Z),
		m5_moon_garden = Vector3.new(-40, LOT, PAD_Z),
		m5_dr_nova = Vector3.new(-48, LOT, PAD_Z),
		m5_light_star = Vector3.new(16, LOT, PAD_Z),
		m5_comet_catcher = Vector3.new(24, LOT, PAD_Z),
		m5_big_telescope = Vector3.new(32, LOT, PAD_Z),
		m5_robot_arm = Vector3.new(40, LOT, PAD_Z),
		m5_mission_banners = Vector3.new(48, LOT, PAD_Z),
	} :: { [string]: Vector3 },
	-- Billboard (owner R31 / R32): FrontGap (2.5) in front of the click box (front z 40, just in front
	-- of the door at 39.55) at eye level (7.5 over the lot): slot (0, 8, 37.5), between the banner
	-- poles (x ±9) and under the bunting (lowest flag y ~12).
	producer = {
		anchor = Vector3.new(0, LOT + 7.5, 37.5),
		click = { size = Vector3.new(20, 18, 20), cf = DOME * CFrame.new(0, 9, 0) },
	},
	-- Teleport target (ground level on the stepping tiles, just inside the arch).
	spawnPoint = Vector3.new(0, LOT, 9),
}

return layout
