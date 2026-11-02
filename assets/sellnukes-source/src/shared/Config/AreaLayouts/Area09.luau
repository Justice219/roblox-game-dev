--!strict
--[[
	AreaLayouts/Area09 — slot layout of Area 9 "Space Port" (spec §3.9).

	Contract: docs/superpowers/plans/2026-10-30-sellnukes-build.md → "World layout", validated by
	src/server/Tycoon/LayoutLogic.luau (tests/area-layouts.luau). Consumed by B5's PlotBuilder:
	`base` is built when Area 8's Unlock pad (build key `A9_EntryArch`) is bought, `builds[buildKey]`
	when that pad is bought (LEGO build-in), pads / producer / spawnPoint are read at plot build time.
	The Unlock pad's key `A10_EntryArch` is NOT here: it resolves to Area10.base.

	Meshes: tools/blender/models/area09.py (A9_*), uploaded; ids in MeshAssets.luau.
	Art + FX notes: docs/areas-art.md → "Area 9".

	Frame: SLOT-LOCAL studs. Origin = road-side edge midpoint, +Z away from the road, +Y up,
	x ∈ [-52, 52], z ∈ [0, 70], height budget 80. Identity rotation = model front (-Z) faces the road.
	The launch-complex floor (A9_Floor) is a 0.5-stud plate: everything stands at y = LOT (0.5).

	Scene (top-down, road at the bottom):
		z 48-63  fuel farm (x -34) · booster rack (x 21) · space elevator (x 39, 79 tall)
		z 24-48  launch platform (r 12) at the centre with the rocket + gantry tower (+X side),
		         mission control (x -37, z 30) · satellite dish (x 38, z 28)
		z 19-25  flight director console (x -20) · astronaut crew stage (x 22); platform steps
		z  0-18  navy walkway with runway lights from the arch to the apron ring / platform steps
		z  3     SPACE PORT entry arch over the walkway (clear width 20)
		z 10     pad row: each pad sits in front of what it builds; Unlock pad at the far +X end

	Collision: invisible primitive boxes (meshes never collide). The round launch deck uses six
	nested boxes whose corners lie ON the r = 12 circle, so the collider never pokes outside the mesh.

	Example (B5):
		local layout = require(ReplicatedStorage.Shared.Config.AreaLayouts.Area09)
		for _, placement in layout.builds.A9_LaunchPad.models do
			MeshLibrary.spawn(placement.key, plotFolder, slotCFrame * placement.cf)
		end
]]

export type ModelPlacement = { key: string, cf: CFrame, tint: Color3?, castShadow: boolean?, collide: boolean? }
export type CollisionBox = { size: Vector3, cf: CFrame }
export type BuildGroup = { models: { ModelPlacement }, collision: { CollisionBox } }

-- Floor plate top (A9_Floor): every model stands at this height.
local LOT = 0.5
-- Launch platform deck: radius and top height above the platform pivot (A9_LaunchPlatform).
local DECK_R = 12
local DECK_TOP = 3
-- Pad row z (inside the 2..16 pad strip) — BuyPads are ~7.3 studs wide, centres 8.25 apart,
-- starting at |x| = 15 so the arch posts (|x| 9.5..13.1) never hide a pad from the road.
local PAD_Z = 10

--[[
	Slot-local CFrame from a position + yaw in degrees (CCW seen from above, Roblox convention).
	Example: at(-37, LOT, 30) -- mission control, glass front facing the road
]]
local function at(x: number, y: number, z: number, yawDeg: number?): CFrame
	return CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yawDeg or 0), 0)
end

--[[
	Collision box anchored to a placed model: `localCentre` is in the model's own frame, so the box
	follows the model's yaw.
	Example: boxOn(DISH, Vector3.new(6.4, 4, 6.4), Vector3.new(0, 2, 0)) -- the dish's block base
]]
local function boxOn(model: CFrame, size: Vector3, localCentre: Vector3): CollisionBox
	return { size = size, cf = model * CFrame.new(localCentre) }
end

--[[
	Nested boxes approximating an upright cylinder from the inside: for each half-depth `hz` the
	box half-width is sqrt(r² - hz²), so every box corner lies on the circle (never outside it).
	Example: roundCollision(PLATFORM, 12, 3, 1.5, { 2, 4, 6, 8, 10, 11.5 })
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
local PLATFORM = at(0, LOT, 36) -- launch pad centre
local DECK = PLATFORM * CFrame.new(0, DECK_TOP, 0) -- deck top: the rocket stands here
local TOWER = DECK * CFrame.new(9, 0, 0) -- gantry beside the rocket, service arms toward -X
local MISSION = at(-37, LOT, 30)
local FUEL = at(-34, LOT, 56)
local DIRECTOR = at(-20, LOT, 22)
local CREW = at(22, LOT, 22) -- 17.6-wide stage starts at x 13.8: clear of the apron hazard ring
local BOOSTERS = at(21, LOT, 55)
local DISH = at(38, LOT, 28)
local ELEVATOR = at(39, LOT, 55)

-- Launch platform steps (A9_LaunchPlatform): step k top height and its front edge (platform-local z).
local STEPS = { { top = 0.95, front = -14.65 }, { top = 1.95, front = -13.4 }, { top = 2.95, front = -12.15 } }
local STEP_BACK = -10.4

--[[ Deck (nested boxes) + the three front steps of the launch platform. ]]
local function platformCollision(): { CollisionBox }
	local boxes = roundCollision(PLATFORM, DECK_R, DECK_TOP, DECK_TOP / 2, { 2, 4, 6, 8, 10, 11.5 })
	for _, step in STEPS do
		local depth = STEP_BACK - step.front
		table.insert(
			boxes,
			boxOn(PLATFORM, Vector3.new(9, step.top, depth), Vector3.new(0, step.top / 2, (step.front + STEP_BACK) / 2))
		)
	end
	return boxes
end

local layout = {
	area = 9,
	-- Built when Area 8's Unlock pad ("Build the Space Port", key A9_EntryArch) is bought.
	base = {
		models = {
			{ key = "A9_Floor", cf = CFrame.identity, castShadow = false },
			{ key = "A9_EntryArch", cf = ARCH },
		},
		collision = {
			{ size = Vector3.new(104, LOT, 70), cf = at(0, LOT / 2, 35) }, -- floor plate (top = LOT)
			boxOn(ARCH, Vector3.new(4, 10, 4), Vector3.new(11.5, 5, 0)), -- arch posts (plinth + shaft)
			boxOn(ARCH, Vector3.new(4, 10, 4), Vector3.new(-11.5, 5, 0)),
		},
	} :: BuildGroup,
	builds = {
		-- Pad 1: the producer "Orbital Launches" — round launch platform, the orbital rocket and
		-- its red gantry tower. A9_Rocket is the liftable launch FX model (EngineGlow = flame).
		A9_LaunchPad = {
			models = {
				{ key = "A9_LaunchPlatform", cf = PLATFORM },
				{ key = "A9_Rocket", cf = DECK },
				{ key = "A9_LaunchTower", cf = TOWER },
			},
			collision = join(platformCollision(), {
				boxOn(DECK, Vector3.new(9, 34, 9), Vector3.new(0, 17, 0)), -- rocket body + fins
				boxOn(TOWER, Vector3.new(6.6, 45, 6.6), Vector3.new(0, 22.5, 0)), -- gantry
			}),
		},
		A9_FuelTanks = {
			models = { { key = "A9_FuelTanks", cf = FUEL } },
			collision = {
				boxOn(FUEL, Vector3.new(22, 0.5, 14), Vector3.new(0, 0.25, 0)), -- slab (walkable step)
				boxOn(FUEL, Vector3.new(8.6, 10.5, 8.6), Vector3.new(-6, 5.25, 2)), -- sphere tank
				boxOn(FUEL, Vector3.new(6.2, 11.4, 6.2), Vector3.new(6, 5.7, 2)), -- upright tank
				boxOn(FUEL, Vector3.new(11, 3.6, 3.6), Vector3.new(0, 2.6, -4.3)), -- capsule tank
			},
		},
		A9_MissionControl = {
			models = { { key = "A9_MissionControl", cf = MISSION } },
			collision = {
				boxOn(MISSION, Vector3.new(22.4, 10.1, 14), Vector3.new(0, 5.05, 0)), -- building + roof slab
				boxOn(MISSION, Vector3.new(0.5, 5.2, 0.5), Vector3.new(2.7, 2.6, -9.5)), -- canopy posts
				boxOn(MISSION, Vector3.new(0.5, 5.2, 0.5), Vector3.new(-2.7, 2.6, -9.5)),
			},
		},
		A9_BoosterRockets = {
			models = { { key = "A9_BoosterRockets", cf = BOOSTERS } },
			collision = { boxOn(BOOSTERS, Vector3.new(19, 19.4, 7.4), Vector3.new(0, 9.7, 0.2)) },
		},
		-- The white Dish piece oscillates about its bbox centre (WorldFx "Dish"), which sits on the
		-- pivot's vertical axis, so it turns on its column.
		A9_SatelliteDish = {
			models = { { key = "A9_SatelliteDish", cf = DISH } },
			collision = {
				boxOn(DISH, Vector3.new(6.4, 4, 6.4), Vector3.new(0, 2, 0)), -- block base
				boxOn(DISH, Vector3.new(2, 4.6, 2), Vector3.new(0, 6.3, 0)), -- turntable column
			},
		},
		A9_AstronautCrew = {
			models = { { key = "A9_AstronautCrew", cf = CREW } },
			collision = { boxOn(CREW, Vector3.new(17.6, 7, 4.6), Vector3.new(0, 3.5, 0)) },
		},
		A9_SpaceElevator = {
			models = { { key = "A9_SpaceElevator", cf = ELEVATOR } },
			collision = join(roundCollision(ELEVATOR, 6, 5.9, 2.95, { 2, 4, 5.5 }), {
				boxOn(ELEVATOR, Vector3.new(4, 65, 4), Vector3.new(0, 38, 0)), -- column
			}),
		},
		-- Manager: the Flight Director with headset + clipboard behind his launch console.
		A9_FlightDirector = {
			models = { { key = "A9_FlightDirector", cf = DIRECTOR } },
			collision = {
				boxOn(DIRECTOR, Vector3.new(7, 4.2, 2.6), Vector3.new(0, 2.1, -0.9)), -- console + side monitors
				boxOn(DIRECTOR, Vector3.new(2.6, 6.6, 1.6), Vector3.new(0, 3.5, 0.9)), -- the director
			},
		},
	} :: { [string]: BuildGroup },
	-- BuyPad ground positions: each pad sits on the pad row in front of what it builds (left of the
	-- walkway: launch pad, director, mission control, fuel; right: crew, boosters, dish, elevator),
	-- the Unlock pad ("Build the Mega Facility", across the road) at the far +X end.
	pads = {
		a9_launch_pad = Vector3.new(-15, LOT, PAD_Z),
		a9_fuel_tanks = Vector3.new(-39.75, LOT, PAD_Z),
		a9_mission_control = Vector3.new(-31.5, LOT, PAD_Z),
		a9_booster_rockets = Vector3.new(23.25, LOT, PAD_Z),
		a9_satellite_dish = Vector3.new(31.5, LOT, PAD_Z),
		a9_astronaut_crew = Vector3.new(15, LOT, PAD_Z),
		a9_space_elevator = Vector3.new(39.75, LOT, PAD_Z),
		a9_flight_director = Vector3.new(-23.25, LOT, PAD_Z),
		a9_build_mega_facility = Vector3.new(48, LOT, PAD_Z),
	} :: { [string]: Vector3 },
	-- Billboard (owner R31 / R32, tests/billboard-clearance.luau): the client puts it FrontGap
	-- (2.5) in front of the click box (front z 29) at eye level, 7.5 over the deck's hazard ring
	-- (top LOT + DECK_TOP + 0.12): slot (0, 11.1, 26.5), in front of the rocket. Anchor = that spot.
	-- The click box wraps the rocket and the deck top (the whole hero reads as "the producer").
	producer = {
		anchor = Vector3.new(0, LOT + DECK_TOP + 7.62, 26.5),
		click = { size = Vector3.new(14, 36, 14), cf = DECK * CFrame.new(0, 17, 0) },
	},
	-- Teleport target (ground level on the walkway, just inside the arch).
	spawnPoint = Vector3.new(0, LOT, 9),
}

return layout
