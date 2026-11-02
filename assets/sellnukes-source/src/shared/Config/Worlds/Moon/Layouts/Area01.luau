--!strict
--[[
	Worlds/Moon/Layouts/Area01 — slot layout of Moon Base area M1 "Crater Camp" (spec
	2026-10-31-r69-moon-lucky-juice-design §2.2; W6 art-d12, owner R70). Replaces W1's temporary
	placeholder.

	Contract: identical to AreaLayouts/AreaNN (docs/superpowers/plans/2026-10-30-sellnukes-build.md
	→ "World layout"), validated by src/server/Tycoon/LayoutLogic.luau against the Moon AreaConfig
	(Worlds/Moon/Areas/Area01). Consumed by PlotBuilder.world("moon"): `base` is built when the
	Moon plot is first built (M1 has no unlock pad), `builds[buildKey]` when that pad is bought,
	pads / producer / spawnPoint at plot build time. The Unlock pad's key `M2_EntryArch` is NOT
	here: it resolves to Moon Area02.base.

	Meshes: tools/blender/models/moon_area01.py (M1_*). Art notes: docs/areas-art.md → "Moon M1".

	Frame: SLOT-LOCAL studs. Origin = road-side edge midpoint, +Z away from the road, +Y up,
	x ∈ [-52, 52], z ∈ [0, 70]. Identity rotation = model front (-Z) faces the road. Standing on
	the road looking in, +X is on your LEFT. The moon-dust lot (M1_Floor) is a 0.5-stud plate
	(y = LOT); its dust path runs from the arch to a round clearing (r 11) round the bench.

	Scene (top-down, road at the bottom):
		z 54-70  the crater rim (a lofted lilac bank + crest rocks); the landed capsule leans
		         against it at x -24, z 52.5; violet crystal clusters along its foot
		z 46-49  solar panels on the +X side (x 26 / 34 / 42), the flag pole at x -16
		z 40-46  the capsule workbench (producer) under its arc lamp, Bleep Bot behind it at x 5.5,
		         the moon-tool rack at x 16
		z 34-47  four globe lamps round the clearing (x ±10)
		z 34     the air pump at x -18
		z 13-46  chrome crater railings along both slot edges
		z 4      CRATER CAMP arch over the path (clear width 14)
		z 10     pad row: buy order alternates either side of the arch, moving outward

	Animated pieces (WorldFx "-- Moon Base M1/M2" rows): M1_SolarPanels `Solar*` (one tilting
	group per stand), lamp / bench `Bulb*` globes (soft light), M1_CapsuleBench `Nuke*` (existing
	bob row, one group). Manager: M1_BleepBot (R30 rig; ManagerNpcConfig.Rigs.M1_BleepBot).

	Example:
		local layout = require(ReplicatedStorage.Shared.Config.Worlds.Moon.Layouts.Area01)
		print(layout.builds.M1_CapsuleBench.models[1].key) --> "M1_CapsuleBench"
]]

export type ModelPlacement = { key: string, cf: CFrame, tint: Color3?, castShadow: boolean?, collide: boolean? }
export type CollisionBox = { size: Vector3, cf: CFrame }
export type BuildGroup = { models: { ModelPlacement }, collision: { CollisionBox } }

-- Moon-dust lot top (M1_Floor).
local LOT = 0.5
-- Workbench top above the bench pivot (M1_CapsuleBench BENCH_TOP).
local BENCH_TOP = 3.4

--[[
	Slot-local CFrame from a position + yaw in degrees (CCW seen from above, Roblox convention).
	yaw 90 turns a model's front (-Z) toward -X; yaw -90 toward +X; 180 toward +Z.

	Example: at(-51, LOT, 21, 90) -- a railing run along Z facing out (-X)
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
local BENCH = at(0, LOT, 40) -- top x ±5, z 38.1..41.9; the arc lamp curves over from x -4.6, z +2.4
local BLEEP = at(5.5, LOT, 45) -- behind the bench, facing the customers
local TOOLS = at(16, LOT, 42, 25) -- turned toward the bench
local FLAG = at(-16, LOT, 47)
local PUMP = at(-18, LOT, 33, -30)
local LAMPS = { at(-10, LOT, 34), at(10, LOT, 34), at(-10, LOT, 47.5), at(10, LOT, 47.5) }
local PANELS = { at(26, LOT, 48, 8), at(34, LOT, 47, 0), at(42, LOT, 48, -8) }
-- Crater railing runs (16 long, along local X): both slot edges, facing out.
local RAIL_RUNS = { at(-51, LOT, 21, 90), at(-51, LOT, 37.6, 90), at(51, LOT, 21, -90), at(51, LOT, 37.6, -90) }
-- M1_RockCluster placements (base decor; any yaw) clear of the pads, path and builds.
local ROCKS = {
	at(-37, LOT, 19, 30),
	at(37, LOT, 18, -40),
	at(-22, LOT, 28, 75),
	at(22, LOT, 30, 160),
	at(-45, LOT, 48, 10),
	at(46, LOT, 30, -70),
	at(-27, LOT, 3, 120),
	at(28, LOT, 3, 200),
}

local baseCollision: { CollisionBox } = {
	{ size = Vector3.new(104, LOT, 70), cf = at(0, LOT / 2, 35) }, -- moon-dust lot (top = LOT)
	boxOn(ARCH, Vector3.new(4.4, 9, 4.4), Vector3.new(9, 4.5, 0)), -- capsule arch posts
	boxOn(ARCH, Vector3.new(4.4, 9, 4.4), Vector3.new(-9, 4.5, 0)),
	{ size = Vector3.new(104, 12, 15.6), cf = at(0, 6, 62.2) }, -- crater rim bank + crest rocks
	{ size = Vector3.new(9, 9, 8), cf = at(-24, LOT + 4.5, 52.8) }, -- landed capsule
}
for _, cf in ROCKS do
	table.insert(baseCollision, boxOn(cf, Vector3.new(4.6, 2.4, 3.8), Vector3.new(0, 1.2, 0)))
end

local layout = {
	area = 1,
	-- Built with the Moon plot: moon-dust lot, the arch, the crater rim + capsule, rock clusters.
	base = {
		models = (function(): { ModelPlacement }
			local models: { ModelPlacement } = {
				{ key = "M1_Floor", cf = CFrame.identity, castShadow = false },
				{ key = "M1_CraterWall", cf = CFrame.identity },
				{ key = "M1_EntryArch", cf = ARCH },
			}
			for _, cf in ROCKS do
				table.insert(models, { key = "M1_RockCluster", cf = cf })
			end
			return models
		end)(),
		collision = baseCollision,
	} :: BuildGroup,
	builds = {
		-- Pad 1: the producer — chrome workbench on fuel-tank legs, hovering moon-rock nuke, arc lamp.
		M1_CapsuleBench = {
			models = { { key = "M1_CapsuleBench", cf = BENCH } },
			collision = {
				boxOn(BENCH, Vector3.new(10, BENCH_TOP, 3.8), Vector3.new(0, BENCH_TOP / 2, 0)),
				boxOn(BENCH, Vector3.new(1.6, 9.6, 1.6), Vector3.new(-4.6, 4.8, 2.4)), -- lamp post
			},
		},
		M1_CraterLamps = {
			models = listModels("M1_CraterLamps", LAMPS),
			collision = listCollision(LAMPS, Vector3.new(0.9, 6.5, 0.9), Vector3.new(0, 3.25, 0)),
		},
		M1_MoonTools = {
			models = { { key = "M1_MoonTools", cf = TOOLS } },
			collision = {
				boxOn(TOOLS, Vector3.new(7, 5, 0.6), Vector3.new(0, 2.5, 0)),
				boxOn(TOOLS, Vector3.new(1.8, 1.1, 1), Vector3.new(2.2, 0.55, -1.2)), -- toolbox
			},
		},
		M1_FlagPole = {
			models = { { key = "M1_FlagPole", cf = FLAG } },
			collision = {
				boxOn(FLAG, Vector3.new(2.6, 0.5, 2.6), Vector3.new(0, 0.25, 0)),
				boxOn(FLAG, Vector3.new(0.6, 13, 0.6), Vector3.new(0, 6.5, 0)),
			},
		},
		M1_SolarPanels = {
			models = listModels("M1_SolarPanels", PANELS),
			collision = listCollision(PANELS, Vector3.new(1, 3.4, 1), Vector3.new(0, 1.7, 0)),
		},
		M1_AirPump = {
			models = { { key = "M1_AirPump", cf = PUMP } },
			collision = { boxOn(PUMP, Vector3.new(3.4, 3.6, 3.4), Vector3.new(0, 1.8, 0)) },
		},
		-- Manager: Bleep Bot behind the bench.
		M1_BleepBot = {
			models = { { key = "M1_BleepBot", cf = BLEEP } },
			collision = { boxOn(BLEEP, Vector3.new(3.2, 6.5, 2.8), Vector3.new(0, 3.25, 0)) },
		},
		M1_CraterRail = {
			models = listModels("M1_CraterRail", RAIL_RUNS),
			collision = listCollision(RAIL_RUNS, Vector3.new(16.4, 3, 0.9), Vector3.new(0, 1.5, -0.2)),
		},
	} :: { [string]: BuildGroup },
	-- BuyPad ground positions: alternate either side of the arch in buy order, moving outward; the
	-- Unlock pad (Open the Cosmic Diner) at the +X end.
	pads = {
		m1_capsule_bench = Vector3.new(-16, LOT, 10),
		m1_crater_lamps = Vector3.new(16, LOT, 10),
		m1_moon_tools = Vector3.new(-24, LOT, 10),
		m1_flag_pole = Vector3.new(24, LOT, 10),
		m1_solar_panels = Vector3.new(-32, LOT, 10),
		m1_air_pump = Vector3.new(32, LOT, 10),
		m1_bleep_bot = Vector3.new(-40, LOT, 10),
		m1_crater_rail = Vector3.new(40, LOT, 10),
		m1_open_diner = Vector3.new(48, LOT, 10),
	} :: { [string]: Vector3 },
	-- The anchor is where the client puts the producer billboard (owner R31 / R32): 2.5 in front of
	-- the click box's front face (z 37.8), 6 above the lot, on the open clearing.
	producer = {
		anchor = Vector3.new(0, LOT + 6, 35.3),
		click = { size = Vector3.new(10.4, 4.0, 4.4), cf = BENCH * CFrame.new(0, 2, 0) },
	},
	-- Teleport target (ground level, on the dust path inside the arch).
	spawnPoint = Vector3.new(0, LOT, 12),
}

return layout
