--!strict
--[[
	AreaLayouts/Area10 — slot layout of Area 10 "Mega Nuclear Facility" (spec §3.10), the finale.

	Contract: docs/superpowers/plans/2026-10-30-sellnukes-build.md → "World layout", validated by
	src/server/Tycoon/LayoutLogic.luau (tests/area-layouts.luau). Consumed by B5's PlotBuilder:
	`base` is built when Area 9's Unlock pad (build key `A10_EntryArch`) is bought, `builds[buildKey]`
	when that pad is bought (LEGO build-in), pads / producer / spawnPoint are read at plot build time.
	The finale pad (Golden Atom Statue, unlocks Rebirth) is an ordinary own build of this area.

	Meshes: tools/blender/models/area10.py (A10_*), uploaded; ids in MeshAssets.luau.
	Art + FX notes: docs/areas-art.md → "Area 10".

	Frame: SLOT-LOCAL studs. Origin = road-side edge midpoint, +Z away from the road, +Y up,
	x ∈ [-52, 52], z ∈ [0, 70], height budget 140 (finale; the skyline tops out at ~78).
	Identity rotation = model front (-Z) faces the road. The facility floor (A10_Floor) is a
	0.5-stud plate: everything stands at y = LOT (0.5).

	Scene (top-down, road at the bottom):
		z 38-68  twin cooling towers (x ±35, 58 / 64 tall, steam) feeding pipes into the reactor
		z 31-61  reactor dome (r 15, crown 29.1) at the centre — the Golden Atom crowns it (y ~ 64)
		z 31-38  power pylons (x 21 / 34 / 47) behind the turbine hall
		z 19-31  control tower (x -41) · fusion core (x -21) · chief engineer (x 13) · turbine hall (x 30)
		z  0-26  green hazard-edged walkway to the plaza; floodlights at z 21.5
		z  3     MEGA NUCLEAR / FACILITY entry arch (clear width 22)
		z 10     pad row: each pad sits in front of what it builds; the finale pad right of the walkway
	Low slate perimeter wall on the sides and back (2.5 high, collidable).

	Collision: invisible primitive boxes (meshes never collide). Round shapes (drum, tower bases,
	fusion pedestal) use nested boxes whose corners lie ON the circle, so colliders never poke out.

	Example (B5):
		local layout = require(ReplicatedStorage.Shared.Config.AreaLayouts.Area10)
		for _, placement in layout.builds.A10_ReactorDome.models do
			MeshLibrary.spawn(placement.key, plotFolder, slotCFrame * placement.cf)
		end
]]

export type ModelPlacement = { key: string, cf: CFrame, tint: Color3?, castShadow: boolean?, collide: boolean? }
export type CollisionBox = { size: Vector3, cf: CFrame }
export type BuildGroup = { models: { ModelPlacement }, collision: { CollisionBox } }

-- Floor plate top (A10_Floor): every model stands at this height.
local LOT = 0.5
-- Reactor drum radius / height and the crown top above the dome pivot (A10_ReactorDome).
local DRUM_R = 15
local DRUM_H = 9
local CROWN_Y = 28.6
-- Cooling tower rim heights (A10_CoolingTower / A10_CoolingTower2) and the radius the base boxes use.
local TOWER_H_LEFT = 58
local TOWER_H_RIGHT = 64
local TOWER_BASE_R = 13.4
-- Pad row z (inside the 2..16 pad strip) — BuyPads are ~7.3 studs wide, centres 8 apart,
-- starting at |x| = 16 so the arch posts (|x| 10.5..14.1) never hide a pad from the road.
local PAD_Z = 10

--[[
	Slot-local CFrame from a position + yaw in degrees (CCW seen from above, Roblox convention).
	Example: at(-41, LOT, 25) -- the control tower, door facing the road
]]
local function at(x: number, y: number, z: number, yawDeg: number?): CFrame
	return CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yawDeg or 0), 0)
end

--[[
	Collision box anchored to a placed model: `localCentre` is in the model's own frame, so the box
	follows the model's yaw.
	Example: boxOn(CONTROL, Vector3.new(10, 1, 10), Vector3.new(0, 0.5, 0)) -- the tower plinth
]]
local function boxOn(model: CFrame, size: Vector3, localCentre: Vector3): CollisionBox
	return { size = size, cf = model * CFrame.new(localCentre) }
end

--[[
	Nested boxes approximating an upright cylinder from the inside: for each half-depth `hz` the
	box half-width is sqrt(r² - hz²), so every box corner lies on the circle (never outside it).
	Example: roundCollision(DOME, 15, 9, 4.5, { 3, 6, 9, 12, 14 })
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

-- Shared placements (used by models, collision and the producer below).
local ARCH = at(0, LOT, 3)
local DOME = at(0, LOT, 46)
local CROWN = DOME * CFrame.new(0, CROWN_Y, 0) -- Golden Atom pivot (dome crown top)
local TOWER_L = at(-35, LOT, 53)
local TOWER_R = at(35, LOT, 53)
local HALL = at(30, LOT, 25) -- its roof power post (local (4, 14.5, 4)) takes the pylon drop cable
local PYLONS = at(34, LOT, 34.5) -- middle pylon foot; pylons at local x = -13, 0, 13
local CONTROL = at(-41, LOT, 25)
local FUSION = at(-21, LOT, 25)
local ENGINEER = at(13, LOT, 22)

--[[
	Cooling tower colliders: nested base boxes (legs + flared foot, r 13.4 up to y 12), a central
	shaft box inside the narrowest waist (r 9.9 -> half-width 7), and the feed pipe (r 1.1 at y 3)
	running from 14 studs out to 0.6 inside the reactor drum along the tower -> dome direction.
]]
local function towerCollision(tower: CFrame, height: number): { CollisionBox }
	local boxes = roundCollision(tower, TOWER_BASE_R, 12, 6, { 4, 8, 11 })
	table.insert(boxes, boxOn(tower, Vector3.new(14, height - 12, 14), Vector3.new(0, 12 + (height - 12) / 2, 0)))
	-- Pipe direction in tower space (towers carry no yaw, so slot deltas are tower-local).
	local toDome = DOME.Position - tower.Position
	local dir = Vector3.new(toDome.X, 0, toDome.Z).Unit
	local reach = Vector3.new(toDome.X, 0, toDome.Z).Magnitude - DRUM_R + 0.6
	local length = reach - 14
	local mid = dir * (14 + length / 2)
	local yaw = math.atan2(-dir.Z, dir.X) -- local +X along the pipe
	table.insert(boxes, {
		size = Vector3.new(length, 2.2, 2.2),
		cf = tower * CFrame.new(mid.X, 3, mid.Z) * CFrame.Angles(0, yaw, 0),
	})
	return boxes
end

local layout = {
	area = 10,
	-- Built when Area 9's Unlock pad ("Build the Mega Facility", key A10_EntryArch) is bought.
	base = {
		models = {
			{ key = "A10_Floor", cf = CFrame.identity, castShadow = false },
			{ key = "A10_EntryArch", cf = ARCH },
		},
		collision = {
			{ size = Vector3.new(104, LOT, 70), cf = at(0, LOT / 2, 35) }, -- floor plate (top = LOT)
			boxOn(ARCH, Vector3.new(4, 10, 4), Vector3.new(12.5, 5, 0)), -- arch posts (plinth + shaft)
			boxOn(ARCH, Vector3.new(4, 10, 4), Vector3.new(-12.5, 5, 0)),
			{ size = Vector3.new(104, 2.5, 1.2), cf = at(0, LOT + 1.25, 69.4) }, -- back wall (+ cap)
			{ size = Vector3.new(1.2, 2.5, 67.2), cf = at(51.4, LOT + 1.25, 36.4) }, -- side walls
			{ size = Vector3.new(1.2, 2.5, 67.2), cf = at(-51.4, LOT + 1.25, 36.4) },
			{ size = Vector3.new(1.6, 13.6, 1.6), cf = at(8, LOT + 6.8, 21.5) }, -- floodlight poles
			{ size = Vector3.new(1.6, 13.6, 1.6), cf = at(-8, LOT + 6.8, 21.5) },
		},
	} :: BuildGroup,
	builds = {
		-- Pad 1: the producer "Mega Reactor" (Core = pulsing green band + oculus + door strip).
		A10_ReactorDome = {
			models = { { key = "A10_ReactorDome", cf = DOME } },
			collision = join(roundCollision(DOME, DRUM_R, DRUM_H, DRUM_H / 2, { 3, 6, 9, 12, 14 }), {
				boxOn(DOME, Vector3.new(17, 10, 17), Vector3.new(0, 14, 0)), -- dome, y 9..19
				boxOn(DOME, Vector3.new(12.8, 4.5, 12.8), Vector3.new(0, 21.25, 0)), -- y 19..23.5
				boxOn(DOME, Vector3.new(5, 4, 5), Vector3.new(0, 25.5, 0)), -- y 23.5..27.5
				boxOn(DOME, Vector3.new(8, 7.4, 2.6), Vector3.new(0, 3.7, -15.2)), -- door portal
			}),
		},
		A10_CoolingTower = {
			models = { { key = "A10_CoolingTower", cf = TOWER_L } },
			collision = towerCollision(TOWER_L, TOWER_H_LEFT),
		},
		A10_CoolingTower2 = {
			models = { { key = "A10_CoolingTower2", cf = TOWER_R } },
			collision = towerCollision(TOWER_R, TOWER_H_RIGHT),
		},
		-- The yellow Turbine rotor on the front face spins (WorldFx "Turbine", axis Z).
		A10_TurbineHall = {
			models = { { key = "A10_TurbineHall", cf = HALL } },
			collision = {
				boxOn(HALL, Vector3.new(24.8, 10, 12.8), Vector3.new(0, 5, 0)), -- slab + walls
				boxOn(HALL, Vector3.new(24.8, 2.2, 10), Vector3.new(0, 11, 0)), -- barrel roof (inscribed)
				boxOn(HALL, Vector3.new(10.6, 10.6, 1.5), Vector3.new(-5.5, 5.6, -6.7)), -- turbine housing
			},
		},
		A10_PowerLines = {
			models = { { key = "A10_PowerLines", cf = PYLONS } },
			collision = {
				boxOn(PYLONS, Vector3.new(6.2, 6, 6.2), Vector3.new(-13, 3, 0)), -- pylon feet + lower legs
				boxOn(PYLONS, Vector3.new(6.2, 6, 6.2), Vector3.new(0, 3, 0)),
				boxOn(PYLONS, Vector3.new(6.2, 6, 6.2), Vector3.new(13, 3, 0)),
				boxOn(PYLONS, Vector3.new(3.4, 24, 3.4), Vector3.new(-13, 18, 0)), -- upper lattice
				boxOn(PYLONS, Vector3.new(3.4, 24, 3.4), Vector3.new(0, 18, 0)),
				boxOn(PYLONS, Vector3.new(3.4, 24, 3.4), Vector3.new(13, 18, 0)),
			},
		},
		A10_ControlTower = {
			models = { { key = "A10_ControlTower", cf = CONTROL } },
			collision = {
				boxOn(CONTROL, Vector3.new(10, 1, 10), Vector3.new(0, 0.5, 0)), -- plinth
				boxOn(CONTROL, Vector3.new(6.4, 33, 6.4), Vector3.new(0, 17.5, 0)), -- shaft
				boxOn(CONTROL, Vector3.new(12, 6.4, 12), Vector3.new(0, 37.2, 0)), -- glass cab + roof
			},
		},
		-- Pink plasma torus + floating orb inside spinning golden gyro rings (WorldFx Core/Glow/Rotor).
		A10_FusionCore = {
			models = { { key = "A10_FusionCore", cf = FUSION } },
			collision = roundCollision(FUSION, 5.6, 11.2, 5.6, { 2.2, 3.9 }),
		},
		-- Manager: the Chief Engineer (hard hat, clipboard, waving) beside his blueprint table.
		A10_ChiefEngineer = {
			models = { { key = "A10_ChiefEngineer", cf = ENGINEER } },
			collision = {
				boxOn(ENGINEER, Vector3.new(2.6, 6.4, 1.8), Vector3.new(-1, 3.4, 0.2)), -- engineer
				boxOn(ENGINEER, Vector3.new(2.8, 3.4, 2.4), Vector3.new(2.9, 1.9, 0.4)), -- drafting table
			},
		},
		-- FINALE: the Golden Atom Statue crowns the reactor dome (RotorOrbits + RotorElectrons spin).
		A10_GoldenAtom = {
			models = { { key = "A10_GoldenAtom", cf = CROWN } },
			collision = { boxOn(CROWN, Vector3.new(4, 11, 4), Vector3.new(0, 5.5, 0)) }, -- spire
		},
	} :: { [string]: BuildGroup },
	-- BuyPad ground positions: each pad sits on the pad row in front of what it builds (left of the
	-- walkway: dome, fusion core, left tower, control tower; right: the finale Golden Atom right
	-- beside the walkway, engineer, right tower, turbine hall, power lines).
	pads = {
		a10_reactor_dome = Vector3.new(-16, LOT, PAD_Z),
		a10_cooling_tower = Vector3.new(-32, LOT, PAD_Z),
		a10_cooling_tower_2 = Vector3.new(32, LOT, PAD_Z),
		a10_turbine_hall = Vector3.new(40, LOT, PAD_Z),
		a10_power_lines = Vector3.new(48, LOT, PAD_Z),
		a10_control_tower = Vector3.new(-40, LOT, PAD_Z),
		a10_fusion_core = Vector3.new(-24, LOT, PAD_Z),
		a10_chief_engineer = Vector3.new(24, LOT, PAD_Z),
		a10_golden_atom = Vector3.new(16, LOT, PAD_Z),
	} :: { [string]: Vector3 },
	-- Billboard (owner R31 / R32, tests/billboard-clearance.luau): the client puts it FrontGap (2.5)
	-- in front of the click box (front z 31) at eye level, 7.5 over the plaza ground there (y 3.0):
	-- slot (0, 10.5, 28.5), in front of the door portal. Anchor = that spot. The click box wraps
	-- the reactor.
	producer = {
		anchor = Vector3.new(0, LOT + 10, 28.5),
		click = { size = Vector3.new(30, 28, 30), cf = DOME * CFrame.new(0, 14, 0) },
	},
	-- Teleport target (ground level on the walkway, just inside the arch).
	spawnPoint = Vector3.new(0, LOT, 9),
}

return layout
