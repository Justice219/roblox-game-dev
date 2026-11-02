--!strict
--[[
	Worlds/Moon/Layouts/Area06 — slot layout of Moon Base area M6 "Star Reactor", the Moon FINALE
	(R69-R71 spec §2.2, owner R70; W8 art-d56). Replaces W1's temporary placeholder.

	Contract: identical to AreaLayouts/AreaNN (docs/superpowers/plans/2026-10-30-sellnukes-build.md
	→ "World layout"), validated by src/server/Tycoon/LayoutLogic.luau against the Moon AreaConfig
	(Worlds/Moon/Areas/Area06). `base` is built when M5's Unlock pad ("Light the Star Reactor", key
	M6_EntryArch) is bought, `builds[buildKey]` when that pad is bought (LEGO build-in). The finale
	pad (Golden Astronaut Statue, feature "Rebirth") is an ordinary own build of this area.

	Meshes: tools/blender/models/moon_area06.py (M6_*). Art + FX notes: docs/areas-art.md → "Moon M5-M6".

	Frame: SLOT-LOCAL studs. Origin = road-side edge midpoint, +Z away from the road, +Y up,
	x ∈ [-52, 52], z ∈ [0, 70], height budget 140 (finale; the statue tops out at ~60).
	Identity rotation = model front (-Z) faces the road; standing on the road, +X is on your LEFT.
	The moon-dust lot (M6_Floor) is a 0.5-stud plate: everything stands at y = LOT.

	Scene (top-down, road at the bottom):
		z 32-64  the Star Core (producer) at the centre: violet base tier (r 16), chrome upper tier
		         (r 13) with a walkable deck at y 9.5 slot, the smiling mini-sun (centre y 24) in a
		         chrome ring cage, orbit rings (r 17.5) round its lower half, the galaxy crown and the GOLDEN
		         ASTRONAUT on the top platform (y 37.5 slot)
		z 58-66  beam towers (x ±26, 34 tall) beaming soft light into the cage
		z 30     moon-rock spire (x -44) with the floating star-tile bridge up to the deck
		z 40-61  nebula core dome (x -38) · meteor falls cliff (x 40)
		z 21-32  plasma pipes from the pedestal front ports to two tanks (x ±11, z 23) · coolant
		         pumps (x 30 / 42) · Commander Lux at her console (x -22, z 22)
		z  3     STAR / REACTOR arch (clear width 20); chrome stepping tiles up to the pedestal
		z 10     pad row (x ±16..48) + the finale pad on the path at (0, 14)
	Low lumpy moon-rock wall with violet caps on the sides (z 20..70) and back; craters + crystals.

	Geometry coupling (all derived in moon_area06.py; move them together): CORE slot (0, 48); the
	plasma pipes end 0.15 short of the pedestal ports (pipes-local z 8.818); the bridge spire foot
	is SPIRE and its last tile rests on the deck top inside the railing gap (core angle 202.2 deg);
	the beam towers, orbit rings and galaxy crown share CORE; the statue pivot is CORE * (0, 37, 0).

	Animated pieces (WorldFx names): M6_StarCore CoreSun (pulsing light: the "star core pulse");
	M6_OrbitRings Carousel* (spin Y about the sun axis); M6_NebulaCore Twirl* + CoreOrb;
	M6_CoolantPumps WheelFly* (spin X) + Bubbles; M6_PlasmaPipes / M6_MeteorFalls Bubbles;
	M6_MeteorFalls StarFall (W8 row: scroll) + SteamA; M6_GalaxyCrown CrystalTips (light);
	M6_StarBridge Lamp. Manager: M6_CommanderLux (R30 rig pieces).

	Collision: invisible primitive boxes (meshes never collide). The pedestal tiers use nested
	boxes inscribed in their circles; the deck and the star bridge are walkable.

	Example:
		local layout = require(ReplicatedStorage.Shared.Config.Worlds.Moon.Layouts.Area06)
		print(layout.builds.M6_StarCore.models[1].key) --> "M6_StarCore"
]]

export type ModelPlacement = { key: string, cf: CFrame, tint: Color3?, castShadow: boolean?, collide: boolean? }
export type CollisionBox = { size: Vector3, cf: CFrame }
export type BuildGroup = { models: { ModelPlacement }, collision: { CollisionBox } }

-- Moon-dust lot top (M6_Floor): every model stands at this height.
local LOT = 0.5
-- Arch post centre |x| (W6 moon_arch: inner / 2 + post_r 1.6 + 0.4 → 12) and pad row z.
local ARCH_POST_X = 12
local PAD_Z = 10

-- Star core geometry (moon_area06.py): pedestal tiers, deck, sun, cage, top platform.
local TIER1_R, TIER1_H = 16, 3
local DECK_R, DECK_Y = 13, 9
local SUN_Y, SUN_R = 23.5, 9.5
local TOP_Y = 37 -- statue pivot (core-local y)
local BRIDGE_DEG = 202.249 -- core-local angle of the bridge landing (railing gap ±12 deg)
-- Plasma pipes: pipes-local z where each pipe ends (0.15 short of its pedestal port) and the tank |x|.
local PIPE_END_Z = 8.818
local TANK_X = 11
-- Star bridge (spire-local tile-centre line): start on the spire platform, end on the deck top.
local BRIDGE_START = Vector3.new(2.221, 9.25, 0.909)
local BRIDGE_END = Vector3.new(33.356, 9.25, 13.646)
local BRIDGE_RISE = 1.2
local SPIRE_TOP = 9 -- spire platform top (SPIRE_H 8.5 + 0.5) = the deck height

--[[
	Slot-local CFrame from a position + yaw in degrees (CCW seen from above, Roblox convention).
	yaw 90 turns a model's front (-Z) toward -X; yaw -90 toward +X; 180 toward +Z.

	Example: at(-44, LOT, 30) -- the star bridge spire
]]
local function at(x: number, y: number, z: number, yawDeg: number?): CFrame
	return CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yawDeg or 0), 0)
end

--[[
	Collision box anchored to a placed model: `localCentre` is in the model's own frame, so the box
	follows the model's yaw.

	Example: boxOn(NEBULA, Vector3.new(6, 8, 6), Vector3.new(0, 5.6, 0)) -- inside the glass dome
]]
local function boxOn(model: CFrame, size: Vector3, localCentre: Vector3): CollisionBox
	return { size = size, cf = model * CFrame.new(localCentre) }
end

--[[
	Nested boxes approximating an upright cylinder from the inside: for each half-depth `hz` the box
	half-width is sqrt(r² - hz²), so every box corner lies on the circle (never outside it).

	Example: roundCollision(CORE, 16, 3, 1.5, { 4.8, 9.6, 13.6 }) -- the violet base tier
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

--[[
	A box on an arc round a model's vertical axis: centre at angle `deg` (x = r cos a, z = r sin a),
	from rIn to rOut, `tangential` wide, y0..y1; local Z is radial (yaw 90 - deg).

	Example: arcBox(CORE, 0, 12.4, 12.9, 3, 9, 11) -- one railing segment on the deck edge
]]
local function arcBox(
	model: CFrame,
	deg: number,
	rIn: number,
	rOut: number,
	tangential: number,
	y0: number,
	y1: number
): CollisionBox
	local a = math.rad(deg)
	local r = (rIn + rOut) / 2
	return {
		size = Vector3.new(tangential, y1 - y0, rOut - rIn),
		cf = model
			* CFrame.new(r * math.cos(a), (y0 + y1) / 2, r * math.sin(a))
			* CFrame.Angles(0, math.rad(90 - deg), 0),
	}
end

-- Shared placements.
local ARCH = at(0, LOT, 3)
local CORE = at(0, LOT, 48)
local STATUE = CORE * CFrame.new(0, TOP_Y, 0)
local PIPES = at(0, LOT, 23) -- tanks at local (±11, 0, 0), clear of the finale pad board; pipes run toward +Z
local PUMPS = { at(30, LOT, 27), at(42, LOT, 27) }
local NEBULA = at(-38, LOT, 46)
local FALLS = at(40, LOT, 48) -- pool centre at local (0.8, 0, 0.6); cliff z 3..12.6 local
local SPIRE = at(-44, LOT, 30)
local LUX = at(-22, LOT, 22) -- figure at the model origin, console at local +X

--[[
	Star core collision: the two pedestal tiers (inscribed), the plasma ports, the sun-holder cup,
	the sun (three stacked inscribed slabs), and the deck railing (2 high on the deck edge, 16
	arc segments, skipping the bridge landing).
]]
local function coreCollision(): { CollisionBox }
	local boxes = roundCollision(CORE, TIER1_R, TIER1_H, TIER1_H / 2, { 4.8, 9.6, 13.6 })
	join(boxes, roundCollision(CORE, DECK_R, DECK_Y - TIER1_H, (TIER1_H + DECK_Y) / 2, { 3.9, 7.8, 11 }))
	for _, sx in { -1, 1 } do
		table.insert(boxes, boxOn(CORE, Vector3.new(2.4, 2.2, 1.6), Vector3.new(sx * 6, 1.5, -15.23))) -- plasma port
	end
	table.insert(
		boxes,
		boxOn(CORE, Vector3.new(3.6, SUN_Y - SUN_R - DECK_Y, 3.6), Vector3.new(0, (DECK_Y + SUN_Y - SUN_R) / 2, 0))
	) -- cup
	for _, slab in { { 0, 0.92 }, { 4.5, 0.75 }, { -4.5, 0.75 } } do
		local half = SUN_R * slab[2] * 0.7
		table.insert(boxes, boxOn(CORE, Vector3.new(half * 2, 4.5, half * 2), Vector3.new(0, SUN_Y + slab[1], 0)))
	end
	for k = 0, 15 do
		local deg = 11.25 + 22.5 * k
		local diff = math.abs(((deg - BRIDGE_DEG + 180) % 360) - 180)
		if diff > 16 then
			table.insert(boxes, arcBox(CORE, deg, DECK_R - 0.7, DECK_R - 0.1, 5.2, DECK_Y, DECK_Y + 2))
		end
	end
	return boxes
end

--[[ Star bridge: the spire column, its platform, and the arched tile deck (8 segments) with rails. ]]
local function bridgeCollision(): { CollisionBox }
	local boxes = roundCollision(SPIRE, 2.4, SPIRE_TOP, SPIRE_TOP / 2, { 0.8, 1.5, 2 })
	table.insert(boxes, boxOn(SPIRE, Vector3.new(4.6, 0.5, 4.6), Vector3.new(0, SPIRE_TOP - 0.25, 0)))
	local function deckAt(t: number): Vector3
		return BRIDGE_START:Lerp(BRIDGE_END, t) + Vector3.new(0, BRIDGE_RISE * 4 * t * (1 - t), 0)
	end
	local segments = 8
	for i = 0, segments - 1 do
		local p0, p1 = deckAt(i / segments), deckAt((i + 1) / segments)
		local mid = (p0 + p1) / 2
		local frame = CFrame.lookAt(mid, p1) -- -Z along the deck, +X across it
		local length = (p1 - p0).Magnitude + 0.2
		table.insert(boxes, { size = Vector3.new(2.6, 0.3, length), cf = SPIRE * frame })
		for _, side in { -1, 1 } do
			table.insert(
				boxes,
				{ size = Vector3.new(0.3, 1.8, length), cf = SPIRE * frame * CFrame.new(side * 1.4, 1, 0) }
			)
		end
	end
	return boxes
end

--[[ Coolant pumps (one set per placement): base, tank, flywheel post. ]]
local function pumpCollision(): { CollisionBox }
	local boxes: { CollisionBox } = {}
	for _, cf in PUMPS do
		table.insert(boxes, boxOn(cf, Vector3.new(5.2, 0.8, 4.2), Vector3.new(0, 0.4, 0)))
		join(boxes, roundCollision(cf * CFrame.new(-0.6, 0, 0), 1.7, 6.1, 3.05, { 0.6, 1.2 }))
		table.insert(boxes, boxOn(cf, Vector3.new(1, 3.2, 1), Vector3.new(1.6, 1.6, 0)))
	end
	return boxes
end

local layout = {
	area = 6,
	-- Built when M5's Unlock pad ("Light the Star Reactor", key M6_EntryArch) is bought.
	base = {
		models = {
			{ key = "M6_Floor", cf = CFrame.identity, castShadow = false },
			{ key = "M6_EntryArch", cf = ARCH },
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
		-- Pad 1: the producer "Star Core" (smiling mini-sun in its cage on the pedestal).
		M6_StarCore = {
			models = { { key = "M6_StarCore", cf = CORE } },
			collision = coreCollision(),
		},
		-- Glowing plasma pipes from the pedestal ports to two plasma tanks.
		M6_PlasmaPipes = {
			models = { { key = "M6_PlasmaPipes", cf = PIPES } },
			collision = (function(): { CollisionBox }
				local boxes: { CollisionBox } = {}
				for _, sx in { -1, 1 } do
					join(boxes, roundCollision(PIPES * CFrame.new(sx * TANK_X, 0, 0), 2.2, 5.6, 2.8, { 0.8, 1.6, 2 }))
					table.insert(
						boxes,
						boxOn(
							PIPES,
							Vector3.new(1.4, 1.6, PIPE_END_Z - 7),
							Vector3.new(sx * 6, 0.8, (7 + PIPE_END_Z) / 2)
						)
					)
				end
				return boxes
			end)(),
		},
		-- Two tilted rings + planets circling the sun (Carousel*); out of reach.
		M6_OrbitRings = {
			models = { { key = "M6_OrbitRings", cf = CORE } },
			collision = {},
		},
		-- Two chrome towers behind the sun beaming soft light into its cage.
		M6_BeamTowers = {
			models = { { key = "M6_BeamTowers", cf = CORE } },
			collision = (function(): { CollisionBox }
				local boxes: { CollisionBox } = {}
				for _, sx in { -1, 1 } do
					local tower = CORE * CFrame.new(sx * 26, 0, 14)
					join(boxes, roundCollision(tower, 3.4, 1.6, 0.8, { 1.2, 2.4 }))
					table.insert(boxes, boxOn(tower, Vector3.new(2.4, 30, 2.4), Vector3.new(0, 16.5, 0)))
				end
				return boxes
			end)(),
		},
		-- Two coolant pumps with spinning flywheels (WheelFly*).
		M6_CoolantPumps = {
			models = { { key = "M6_CoolantPumps", cf = PUMPS[1] }, { key = "M6_CoolantPumps", cf = PUMPS[2] } },
			collision = pumpCollision(),
		},
		-- Swirling nebula orb under a glass dome (Twirl* + CoreOrb).
		M6_NebulaCore = {
			models = { { key = "M6_NebulaCore", cf = NEBULA } },
			collision = join(roundCollision(NEBULA, 5.6, 1.6, 0.8, { 1.8, 3.6, 4.8 }), {
				boxOn(NEBULA, Vector3.new(6.4, 7.4, 6.4), Vector3.new(0, 5.3, 0)), -- glass dome (inscribed)
			}),
		},
		-- Moon-rock cliff with a sparkly star-water fall into a pool (StarFall + Bubbles).
		M6_MeteorFalls = {
			models = { { key = "M6_MeteorFalls", cf = FALLS } },
			collision = join({
				boxOn(FALLS, Vector3.new(15, 7, 9.6), Vector3.new(0, 3.5, 7.8)), -- cliff tiers
				boxOn(FALLS, Vector3.new(13.4, 6.6, 8.6), Vector3.new(0, 10.1, 7.9)),
				boxOn(FALLS, Vector3.new(11.6, 5.6, 7.8), Vector3.new(0, 16, 7.9)),
			}, roundCollision(FALLS * CFrame.new(0.8, 0, 0.6), 4.2, 1.4, 0.7, { 1.4, 2.8, 3.7 })),
		},
		-- Moon-rock spire + floating star-tile bridge up to the pedestal deck (walkable).
		M6_StarBridge = {
			models = { { key = "M6_StarBridge", cf = SPIRE } },
			collision = bridgeCollision(),
		},
		-- Gold circlet of stars round the statue platform (out of reach).
		M6_GalaxyCrown = {
			models = { { key = "M6_GalaxyCrown", cf = CORE } },
			collision = {},
		},
		-- Manager: Commander Lux (astronaut chief, clipboard) at her console.
		M6_CommanderLux = {
			models = { { key = "M6_CommanderLux", cf = LUX } },
			collision = {
				boxOn(LUX, Vector3.new(3, 6.8, 3), Vector3.new(0, 3.4, 0.2)), -- Commander Lux
				boxOn(LUX, Vector3.new(2.4, 3.2, 1.8), Vector3.new(4.1, 1.6, 0.2)), -- console
			},
		},
		-- FINALE: the Golden Astronaut on the star core's top platform (feature "Rebirth").
		M6_GoldenAstronaut = {
			models = { { key = "M6_GoldenAstronaut", cf = STATUE } },
			collision = { boxOn(STATUE, Vector3.new(4, 10, 4), Vector3.new(0, 5, 0)) },
		},
	} :: { [string]: BuildGroup },
	-- BuyPad ground positions: each pad sits on the pad row in front of what it builds (right of the
	-- path, seen from the road: star core, Lux, nebula, bridge, crown; left: pipes, orbit rings,
	-- pumps, falls, beam towers). The finale (Golden Astronaut) waits alone on the path at (0, 14),
	-- right in front of the star it crowns, once every other pad is bought.
	pads = {
		m6_star_core = Vector3.new(-16, LOT, PAD_Z),
		m6_commander_lux = Vector3.new(-24, LOT, PAD_Z),
		m6_nebula_core = Vector3.new(-32, LOT, PAD_Z),
		m6_star_bridge = Vector3.new(-40, LOT, PAD_Z),
		m6_galaxy_crown = Vector3.new(-48, LOT, PAD_Z),
		m6_plasma_pipes = Vector3.new(16, LOT, PAD_Z),
		m6_orbit_rings = Vector3.new(24, LOT, PAD_Z),
		m6_coolant_pumps = Vector3.new(32, LOT, PAD_Z),
		m6_meteor_falls = Vector3.new(40, LOT, PAD_Z),
		m6_beam_towers = Vector3.new(48, LOT, PAD_Z),
		m6_golden_astronaut = Vector3.new(0, LOT, 14),
	} :: { [string]: Vector3 },
	-- Billboard (owner R31 / R32): FrontGap (2.5) in front of the click box (front face slot z 31,
	-- in front of the plasma ports at 31.97) at eye level (7.5 over the lot): slot (0, 8, 28.5),
	-- between the plasma pipes (|x| >= 5.5). The click box wraps the pedestal front.
	producer = {
		anchor = Vector3.new(0, LOT + 7.5, 28.5),
		click = { size = Vector3.new(16, 14, 6), cf = CORE * CFrame.new(0, 7, -14) },
	},
	-- Teleport target (ground level on the stepping tiles between the arch and the finale pad).
	spawnPoint = Vector3.new(0, LOT, 7),
}

return layout
