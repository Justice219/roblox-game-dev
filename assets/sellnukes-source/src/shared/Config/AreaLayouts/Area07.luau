--!strict
--[[
	AreaLayouts/Area07 — slot layout of Area 7 "Launch Silos" (spec §3.7, attack mode §9).

	Contract: docs/superpowers/plans/2026-10-30-sellnukes-build.md → "World layout", validated by
	src/server/Tycoon/LayoutLogic.luau (tests/area-layouts.luau). Consumed by B5's PlotBuilder: `base`
	is built when the area unlocks (Area 6's Unlock pad key `A7_EntryArch` resolves here),
	`builds[buildKey]` when that pad is bought, pads / producer / spawnPoint at plot build time.
	Area 7's own Unlock pad (`a7_open_megastore`, key `A8_EntryArch`) resolves to Area08.base.
	Meshes: tools/blender/models/area07.py (keys `A7_*`, ids in MeshAssets).

	Frame: SLOT-LOCAL studs. Origin = road-side edge midpoint of the slot, +Z away from the road,
	+Y up, slot x ∈ [-52, 52], z ∈ [0, 70]. Identity rotation = model front (-Z) faces the road.
	The launch deck tops out at y = DECK (0.5); everything standing on it sits at y = DECK.
	Area 7 is a LEFT-side slot: the hub is toward -X; Area 8 (the Megastore) is directly across the
	road, so the Unlock pad sits next to the arch where its new arch appears opposite.

	Scene (top-down, road at the bottom):
		z 41-59  three silos (A7_SiloBase gantry + candy nuke): Silo 2 (x -26, mint), Silo 1 = producer
		         (x 0, red), Silo 3 (x 26, white/gold); nose tips at y 25.7 = attack launch points
		z 55-65  radar dish (x -44, Dish sweeps) and the AA Tower base plinth (x 43.5; B8f's levelled
		         AATower1..5 stand on it at `aaTowerMount`, spawned by attack mode, B10)
		z 19-33  mission control (x -36), attack console (x 16), launch director robot (x 27)
		z 22-36  hazard loading zone with fuel barrels (x 36..50, part of A7_HazardFloor)
		z 0-41   light walkway x ∈ [-6, 6]; hazard lanes, chevrons and bollards come with A7_HazardFloor
		z 3      entry arch (pillars at x = ±7.6)
		z 9      pad row (8 studs apart, each pad in front of what it builds)

	Collision: invisible primitive boxes (meshes never collide). Overhead frame beams and the radar
	head are out of reach and have none; everything a player could walk into does. The levelled AA
	tower on the plinth is attack mode's model, so its collision is attack mode's too.

	Attack mode (B10, src/shared/Attack/AttackGeometry.luau reads these optional fields):
		launchPoints   { CFrame x3 }  silo 1 / 2 / 3 launch frames, +Y up, at each standing nuke's NOSE
		               TIP (y 25.7): a launched projectile rises out of the open gantry top without
		               clipping the standing nuke. The silo mouth (collar centre) is 24 studs below.
		aaTowerMount   CFrame          plinth top centre (+Y up, -Z = turret default facing)
		consolePrompt  Vector3         Attack Console ProximityPrompt spot, operator side (-Z), ~3 up

	Animatable pieces (client visuals; listed in `animations` below and docs/areas-art.md):
		A7_RadarDish piece `Dish`       AUTOMATIC: WorldFxConfig.Pieces.Dish oscillates it about Y (its
		                                bounding-box centre is on the pivot axis thanks to a counterweight)
		A7_*.`Core` pieces              AUTOMATIC: pulsing light (WorldFxConfig.Pieces.Core)
		A7_ControlRoom piece `Door`     gameplay-driven: slide +X by 4.4 studs (into the wall pocket)
		A7_SiloNuke_* models (Nuke)     attack mode (optional): tween the model pivot up (+Y) to launch;
		                                `launchPoints` = nose tips

	Example (B5):
		local layout = require(ReplicatedStorage.Shared.Config.AreaLayouts.Area07)
		for _, placement in layout.builds.A7_SiloPad.models do
			MeshLibrary.spawn(placement.key, plotFolder, slotCFrame * placement.cf)
		end
]]

export type ModelPlacement = { key: string, cf: CFrame, castShadow: boolean? }
export type CollisionBox = { size: Vector3, cf: CFrame }
export type BuildGroup = { models: { ModelPlacement }, collision: { CollisionBox } }
export type Animation = {
	build: string, -- build key that spawns the model
	model: string, -- mesh key (the spawned Model's name)
	part: string?, -- piece name inside the model; nil = the whole model moves
	kind: "worldFx" | "slideX" | "launch", -- worldFx = handled by WorldFxController by piece name
	pivot: CFrame, -- slot-local frame the motion is relative to
	distance: number?, -- slideX travel in studs
}

-- Deck top (A7_Deck); every deck-standing model is placed at this height.
local DECK = 0.5
-- Silo platform top above the deck (A7_SiloBase) and silo nuke length (A7_SiloNuke_*).
local PLAT_TOP = 1.2
local NUKE_LEN = 24
-- Gantry corner-post centres and post height (A7_SiloBase).
local POST = 7.4
local FRAME_TOP = 30
-- AA plinth top above its pivot (A7_AATower: AATower1..5 stand here) and the control-room door slide.
local AA_MOUNT_Y = 1
local DOOR_SLIDE = 4.4

--[[
	Slot-local CFrame helper: position + yaw in degrees (CCW from above, Roblox convention).

	Example: at(-26, DECK, 50) -- Silo 2's platform centre on the deck
]]
local function at(x: number, y: number, z: number, yawDeg: number?): CFrame
	return CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yawDeg or 0), 0)
end

--[[
	Collision box anchored to a placed model: `localCentre` is the box centre in the model's own
	frame, so the box follows the model's placement (and yaw, if any).
]]
local function boxOn(model: CFrame, size: Vector3, localCentre: Vector3): CollisionBox
	return { size = size, cf = model * CFrame.new(localCentre) }
end

-- Placements (shared by models, collision, producer and the attack-mode points).
local ORIGIN = CFrame.new()
local ARCH = at(0, DECK, 3)
local SILO_1 = at(0, DECK, 50)
local SILO_2 = at(-26, DECK, 50)
local SILO_3 = at(26, DECK, 50)
local RADAR = at(-44, DECK, 60)
local CONTROL_ROOM = at(-36, DECK, 26)
local CONSOLE = at(16, DECK, 26)
local DIRECTOR = at(27, DECK, 26)
-- 14 x 14 plinth at x 36.5..50.5, z 53..67 (clear of Silo 3 and the side curb).
local AA_TOWER = at(43.5, DECK, 60)

--[[
	Attack-mode launch frame of a silo: identity rotation (+Y up) at the standing nuke's nose tip.
	@param silo CFrame — the A7_SiloBase placement
]]
local function launchFrame(silo: CFrame): CFrame
	return silo * CFrame.new(0, PLAT_TOP + NUKE_LEN, 0)
end

--[[
	Collision of one silo (platform, front step, four gantry posts, the standing nuke).
	@param silo CFrame — the A7_SiloBase placement
	@return { CollisionBox }
]]
local function siloCollision(silo: CFrame): { CollisionBox }
	local boxes = {
		boxOn(silo, Vector3.new(18, PLAT_TOP, 18), Vector3.new(0, PLAT_TOP / 2, 0)),
		boxOn(silo, Vector3.new(6, 0.8, 1.8), Vector3.new(0, 0.4, -9.9)),
		-- Nuke: chubby body (r 3.8) + a wider, low box over the fins.
		boxOn(silo, Vector3.new(7.6, NUKE_LEN - 1, 7.6), Vector3.new(0, PLAT_TOP + (NUKE_LEN - 1) / 2, 0)),
		boxOn(silo, Vector3.new(9.2, 5, 9.2), Vector3.new(0, PLAT_TOP + 2.5, 0)),
	}
	local postHeight = FRAME_TOP - PLAT_TOP
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			table.insert(
				boxes,
				boxOn(
					silo,
					Vector3.new(1.7, postHeight, 1.7),
					Vector3.new(sx * POST, PLAT_TOP + postHeight / 2, sz * POST)
				)
			)
		end
	end
	return boxes
end

-- Hazard-floor bollards and loading-zone barrels (A7_HazardFloor, slot-origin coordinates).
local function hazardFloorCollision(): { CollisionBox }
	local boxes = {}
	for _, z in { 18, 26, 34 } do
		for _, sx in { -1, 1 } do
			table.insert(boxes, { size = Vector3.new(0.9, 2.4, 0.9), cf = CFrame.new(sx * 9.2, DECK + 1.2, z) })
		end
	end
	for _, p in { { 40, 26 }, { 42.4, 26.4 }, { 41.2, 28.4 }, { 45.6, 31.6 }, { 46, 25.4 } } do
		table.insert(boxes, { size = Vector3.new(2.1, 2.6, 2.1), cf = CFrame.new(p[1], DECK + 1.3, p[2]) })
	end
	return boxes
end

local layout = {
	area = 7,
	base = {
		models = {
			-- Flat plates skip shadows (wasted on a plane; shared art convention).
			{ key = "A7_Deck", cf = ORIGIN, castShadow = false },
			{ key = "A7_EntryArch", cf = ARCH },
		},
		collision = {
			-- Deck slab (y -0.2 .. 0.5) and the back / side curbs (top y 1.0).
			{ size = Vector3.new(104, 0.7, 70), cf = CFrame.new(0, 0.15, 35) },
			{ size = Vector3.new(104, 0.7, 1.2), cf = CFrame.new(0, 0.65, 69.4) },
			{ size = Vector3.new(1.2, 0.7, 68.8), cf = CFrame.new(-51.4, 0.65, 34.4) },
			{ size = Vector3.new(1.2, 0.7, 68.8), cf = CFrame.new(51.4, 0.65, 34.4) },
			-- Arch: plinths + banded pillars, beam, lettered sign (toppers are out of reach).
			boxOn(ARCH, Vector3.new(3.4, 15.8, 3.4), Vector3.new(-7.6, 7.9, 0)),
			boxOn(ARCH, Vector3.new(3.4, 15.8, 3.4), Vector3.new(7.6, 7.9, 0)),
			boxOn(ARCH, Vector3.new(19.6, 1.6, 2.2), Vector3.new(0, 16.6, 0)),
			boxOn(ARCH, Vector3.new(18.4, 4, 0.7), Vector3.new(0, 19.4, -0.3)), -- lettered sign
		},
	},
	builds = {
		-- First pad: Silo 1 = the producer "Silo Launches" (red nuke).
		A7_SiloPad = {
			models = {
				{ key = "A7_SiloBase", cf = SILO_1 },
				{ key = "A7_SiloNuke_Red", cf = SILO_1 * CFrame.new(0, PLAT_TOP, 0) },
			},
			collision = siloCollision(SILO_1),
		},
		A7_Silo2 = {
			models = {
				{ key = "A7_SiloBase", cf = SILO_2 },
				{ key = "A7_SiloNuke_Mint", cf = SILO_2 * CFrame.new(0, PLAT_TOP, 0) },
			},
			collision = siloCollision(SILO_2),
		},
		A7_Silo3 = {
			models = {
				{ key = "A7_SiloBase", cf = SILO_3 },
				{ key = "A7_SiloNuke_Gold", cf = SILO_3 * CFrame.new(0, PLAT_TOP, 0) },
			},
			collision = siloCollision(SILO_3),
		},
		A7_RadarDish = {
			models = { { key = "A7_RadarDish", cf = RADAR } },
			collision = {
				boxOn(RADAR, Vector3.new(10, 1, 10), Vector3.new(0, 0.5, 0)),
				boxOn(RADAR, Vector3.new(6.8, 7, 6.8), Vector3.new(0, 4.5, 0)),
				boxOn(RADAR, Vector3.new(5.2, 8, 5.2), Vector3.new(0, 11, 0)),
			},
		},
		A7_ControlRoom = {
			models = { { key = "A7_ControlRoom", cf = CONTROL_ROOM } },
			collision = { boxOn(CONTROL_ROOM, Vector3.new(25, 12.2, 15), Vector3.new(0, 6.1, 0)) },
		},
		A7_HazardFloor = {
			models = { { key = "A7_HazardFloor", cf = ORIGIN, castShadow = false } },
			collision = hazardFloorCollision(),
		},
		A7_LaunchDirector = {
			models = { { key = "A7_LaunchDirector", cf = DIRECTOR } },
			collision = { boxOn(DIRECTOR, Vector3.new(5, 8.6, 3.2), Vector3.new(0.3, 4.3, -0.4)) },
		},
		-- Feature: the AA tower BASE only (plinth, corner beacons, placard). Attack mode puts B8f's
		-- levelled AATower1..5 on top at aaTowerMount, so buying a level never touches this build.
		A7_AATower = {
			models = { { key = "A7_AATower", cf = AA_TOWER } },
			collision = {
				boxOn(AA_TOWER, Vector3.new(14, AA_MOUNT_Y, 14), Vector3.new(0, AA_MOUNT_Y / 2, 0)),
				boxOn(AA_TOWER, Vector3.new(7.2, 3.3, 0.5), Vector3.new(0, 1.65, -7.7)), -- placard
				boxOn(AA_TOWER, Vector3.new(0.6, 2.7, 0.6), Vector3.new(-6.5, AA_MOUNT_Y + 1.35, -6.5)),
				boxOn(AA_TOWER, Vector3.new(0.6, 2.7, 0.6), Vector3.new(6.5, AA_MOUNT_Y + 1.35, -6.5)),
				boxOn(AA_TOWER, Vector3.new(0.6, 2.7, 0.6), Vector3.new(-6.5, AA_MOUNT_Y + 1.35, 6.5)),
				boxOn(AA_TOWER, Vector3.new(0.6, 2.7, 0.6), Vector3.new(6.5, AA_MOUNT_Y + 1.35, 6.5)),
			},
		},
		-- Feature: unlocks Attack mode (operator stands at the -Z side, facing the screen).
		A7_AttackConsole = {
			models = { { key = "A7_AttackConsole", cf = CONSOLE } },
			collision = {
				boxOn(CONSOLE, Vector3.new(12, 0.6, 7), Vector3.new(0, 0.3, 0)),
				boxOn(CONSOLE, Vector3.new(10.4, 3.8, 3.8), Vector3.new(0, 2.5, 0.2)),
				boxOn(CONSOLE, Vector3.new(9.4, 6.4, 1.4), Vector3.new(0, 7.6, 1.6)),
			},
		},
	},
	-- BuyPad ground positions (pad row z = 9, 8 studs apart, clear of the arch pillars).
	pads = {
		a7_silo_pad = Vector3.new(-13.5, DECK, 9),
		a7_silo_2 = Vector3.new(-21.5, DECK, 9),
		a7_silo_3 = Vector3.new(21.5, DECK, 9),
		a7_radar_dish = Vector3.new(-45.5, DECK, 9),
		a7_control_room = Vector3.new(-37.5, DECK, 9),
		a7_hazard_floor = Vector3.new(37.5, DECK, 9),
		a7_launch_director = Vector3.new(29.5, DECK, 9),
		a7_aa_tower = Vector3.new(45.5, DECK, 9),
		a7_attack_console = Vector3.new(13.5, DECK, 9),
		a7_open_megastore = Vector3.new(-29.5, DECK, 9),
	},
	-- Producer billboard (owner R31 / R32, tests/billboard-clearance.luau): the client puts it
	-- FrontGap (2.5) in front of the click box at eye level (7.5 over the platform), nudging forward
	-- while any visible piece's BOUNDING BOX overlaps it. The gantry's Frame / Beams / Hazard boxes
	-- span the whole gantry (front face silo-local z -8.7), so the click box is 13.4 deep (it wraps
	-- the nuke incl. its fins, r 6.5): the billboard lands just in front of the front posts (slot
	-- z 40.8) over the front step, the nuke visible above it. Anchor = that spot.
	producer = {
		anchor = Vector3.new(0, DECK + PLAT_TOP + 7.5, 40.8),
		click = { size = Vector3.new(9, 25, 13.4), cf = SILO_1 * CFrame.new(0, PLAT_TOP + 12.5, 0) },
	},
	spawnPoint = Vector3.new(0, DECK + 3, 20),

	-- Attack mode (spec §9; B10 AttackGeometry; extra fields pass through LayoutLogic.merge) ------
	-- Launch frames (+Y up) at each standing nuke's nose tip, in silo build order (Silo 1, 2, 3).
	-- A silo's frame is only valid once its build key (launchBuilds) is owned.
	launchPoints = { launchFrame(SILO_1), launchFrame(SILO_2), launchFrame(SILO_3) },
	launchBuilds = { "A7_SiloPad", "A7_Silo2", "A7_Silo3" },
	-- Plinth top centre where the levelled AATower1..5 stand (+Y up, -Z = turret default facing).
	aaTowerMount = AA_TOWER * CFrame.new(0, AA_MOUNT_Y, 0),
	-- Attack Console ProximityPrompt: operator side (-Z) just in front of the desk, ~3 studs above
	-- the console plinth (plinth top y 1.1).
	consolePrompt = (CONSOLE * CFrame.new(0, 3.5, -2.6)).Position,

	-- Animatable pieces (client-side visuals only; see the header).
	animations = {
		{ build = "A7_RadarDish", model = "A7_RadarDish", part = "Dish", kind = "worldFx", pivot = RADAR },
		{
			build = "A7_ControlRoom",
			model = "A7_ControlRoom",
			part = "Door",
			kind = "slideX",
			pivot = CONTROL_ROOM,
			distance = DOOR_SLIDE,
		},
		{
			build = "A7_SiloPad",
			model = "A7_SiloNuke_Red",
			kind = "launch",
			pivot = SILO_1 * CFrame.new(0, PLAT_TOP, 0),
		},
		{
			build = "A7_Silo2",
			model = "A7_SiloNuke_Mint",
			kind = "launch",
			pivot = SILO_2 * CFrame.new(0, PLAT_TOP, 0),
		},
		{
			build = "A7_Silo3",
			model = "A7_SiloNuke_Gold",
			kind = "launch",
			pivot = SILO_3 * CFrame.new(0, PLAT_TOP, 0),
		},
	} :: { Animation },
}

return layout
