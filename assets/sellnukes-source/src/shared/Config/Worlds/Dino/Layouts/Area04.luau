--!strict
--[[
	Worlds/Dino/Layouts/Area04 — slot layout of Dino Valley area D4 "Geyser Springs" (spec
	2026-10-31-world2-design §6.2 / §16; W7 art-d34).

	Contract: identical to AreaLayouts/AreaNN (docs/superpowers/plans/2026-10-30-sellnukes-build.md
	→ "World layout"), validated by src/server/Tycoon/LayoutLogic.luau against the Dino AreaConfig
	(Worlds/Dino/Areas/Area04). Consumed by PlotBuilder for world "dino": `base` is built when D3's
	Unlock pad (build key `D4_EntryArch`) is bought, `builds[buildKey]` when that pad is bought,
	pads / producer / spawnPoint at plot build time. The Unlock pad's key `D5_EntryArch` is NOT here:
	it resolves to Dino Area05.base.

	Meshes: tools/blender/models/dino_area04.py (keys `D4_*`, MeshAssets). Art notes:
	docs/areas-art.md → "Dino D3 / D4".

	Frame: SLOT-LOCAL studs. Origin = road-side edge midpoint, +Z away from the road, +Y up,
	x ∈ [-52, 52], z ∈ [0, 70]. Identity rotation = model front (-Z) faces the road. Standing on the
	road looking in, +X is on your LEFT. The sandy-stone floor slab tops out at y = 0.4 (FLOOR).

	Scene (top-down, road at the bottom):
		z 53-70  Mega Geyser (hero, x 0): terraced mound, jet to y ~31, rope fence arc + "WHOOSH!"
		         board; mossy outcrops + bamboo clumps in both back corners (D4_Rocks, base)
		z 38-54  Geyser Vent (producer, x 0) with its pump bench at z 39; bamboo pipes at z 46 run
		         +X to the water-wheel riser (x 26) and -X to the hot springs' inlet (x -20.85)
		z 35.5   producer billboard at eye level in front of the bench (R31 / R32)
		z 44-48  water wheel (x 28..41, axle along slot Z so it faces the road)
		z 40-56  hot springs (x -21..-40): raised upper pool + lower pool with a bathing baby dino
		z 26-32  pressure valves (x 18) with Para Pete beside them (x 10), steam whistles (x 40),
		         stone-steps lookout (x -39..-47, steps facing the walkway)
		z 18     GEYSER SPRINGS arch over the flagstone walkway x ∈ [-5, 5]
		z 9      pad row (alternating either side of the walkway, buy order outward)

	Collision: invisible primitive boxes (meshes never collide). The bamboo pipes, the lower pool's
	water and the manager stay walk-through on purpose; the stone steps are real stairs.

	Static checks: no two models interpenetrate (owner R24), no coplanar faces (R18), the billboard
	spot in front of the click box is clear of every visible piece box (R31 / R32), mesh budgets
	(spec §15: area ≤ 28k triangles).

	Example (PlotBuilder):
		local layout = require(ReplicatedStorage.Shared.Config.Worlds.Dino.Layouts.Area04)
		print(layout.builds.D4_WaterWheel.models[1].key) --> "D4_WaterWheel"
]]

export type ModelPlacement = { key: string, cf: CFrame }
export type CollisionBox = { size: Vector3, cf: CFrame }
export type BuildGroup = { models: { ModelPlacement }, collision: { CollisionBox } }

-- Floor slab top (D4_Floor); every floor-standing model is placed at this height.
local FLOOR = 0.4

--[[
	Slot-local CFrame helper: position + yaw in degrees (CCW from above, Roblox convention).
	yaw -90 turns a model's front (-Z) toward +X; yaw 90 toward -X; 180 toward +Z.

	Example: at(34, FLOOR, 46, 90) -- the water wheel: its axle (local X) runs along slot Z
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

-- Shared placements (referenced by both models and collision below).
local VENT = at(0, FLOOR, 46) -- producer: vent mound centre; pump bench at local z -7 (slot 39)
-- The pipes share the vent's pivot: +X run ends at slot x 25.4 (wheel riser at 26 ± 0.58), -X run
-- ends at slot x -20.4 (the springs' inlet riser at -20.85 ± 0.4).
local PIPES = VENT
-- yaw 90: the wheel's local X (axle) -> slot -Z, local Z -> slot +X, so the aqueduct riser at
-- local z -8 stands at slot (26, 46) right where the +X pipe run ends.
local WHEEL = at(34, FLOOR, 46, 90)
local WHISTLES = at(40, FLOOR, 28, 30) -- whistles turned toward the walkway and the road
local SPRINGS = at(-31, FLOOR, 47) -- inlet riser at local (10.15, y, -1) = slot (-20.85, 46)
local VALVES = at(18, FLOOR, 31, 15)
local MEGA = at(0, FLOOR, 61.5) -- hero; base radius 8 (slot z 53.5 .. 69.5)
-- Para Pete (manager NPC, owner R30) starts beside the valves, turned toward the walkway; the
-- client ManagerController walks him from here, so he has no collision box.
local PETE = at(10, FLOOR, 29, 25)
-- yaw -90: the steps (model front, -Z) face +X (the walkway); the ledge sits toward the slot edge.
local STEPS = at(-42, FLOOR, 27, -90)
-- Producer click box (wraps mound, jet and bench) and the billboard spot in front of it (owner
-- R31 / R32): the billboard sits FrontGap (2.5) past the click box's road-side face at EyeHeight
-- (7.5). The slot in front (z 34.9 .. 36.1, x within ±7.2, y 2 .. 14) is kept free of every
-- visible piece box: valves at x >= 14.8, Pete at x 10, the backdrop's near-road ferns are in
-- their own FernsL / FernsR pieces at |x| 48.5.
local PRODUCER_CLICK = VENT * CFrame.new(0, 6.5, -1)
local PRODUCER_CLICK_SIZE = Vector3.new(15, 13, 14)
local BILLBOARD_Z = PRODUCER_CLICK.Position.Z - PRODUCER_CLICK_SIZE.Z / 2 - 2.5

local layout = {
	area = 4,

	-- Built when D4 unlocks: sandy-stone floor, GEYSER SPRINGS arch, back-corner rocks + bamboo.
	base = {
		models = {
			{ key = "D4_Floor", cf = at(0, 0, 35) },
			{ key = "D4_EntryArch", cf = at(0, FLOOR, 18) },
			{ key = "D4_Rocks", cf = at(0, FLOOR, 0) },
		},
		collision = {
			{ size = Vector3.new(104, 1, 70), cf = at(0, FLOOR - 0.5, 35) }, -- floor (top = FLOOR)
			{ size = Vector3.new(5, 13, 4.6), cf = at(-9.6, FLOOR + 6.5, 18) }, -- arch pillars
			{ size = Vector3.new(5, 13, 4.6), cf = at(9.6, FLOOR + 6.5, 18) },
			-- Back-corner outcrops (D4_Rocks).
			{ size = Vector3.new(9, 6, 6.6), cf = at(-40, FLOOR + 3, 66) },
			{ size = Vector3.new(7.6, 5, 6), cf = at(-22, FLOOR + 2.5, 66.5) },
			{ size = Vector3.new(8, 5, 6), cf = at(24, FLOOR + 2.5, 66.5) },
			{ size = Vector3.new(9.4, 6.6, 6.8), cf = at(42, FLOOR + 3.3, 65.5) },
		},
	},

	builds = {
		-- First pad (builder): the Geyser Vent producer.
		D4_GeyserVent = {
			models = { { key = "D4_GeyserVent", cf = VENT } },
			collision = {
				-- Crossing boxes approximate the round mound; the crater block on top; the bench.
				boxOn(VENT, Vector3.new(11, 2.2, 7.4), Vector3.new(0, 1.1, 0)),
				boxOn(VENT, Vector3.new(7.4, 2.2, 11), Vector3.new(0, 1.1, 0)),
				boxOn(VENT, Vector3.new(5.6, 3.9, 5.6), Vector3.new(0, 1.95, 0)),
				boxOn(VENT, Vector3.new(9.2, 2.6, 1.9), Vector3.new(0, 1.3, -7)),
			},
		},
		D4_BambooPipes = {
			models = { { key = "D4_BambooPipes", cf = PIPES } },
			collision = {},
		},
		D4_WaterWheel = {
			models = { { key = "D4_WaterWheel", cf = WHEEL } },
			collision = {
				boxOn(WHEEL, Vector3.new(3.6, 1.5, 14.4), Vector3.new(0, 0.75, 0)), -- stone trough
				boxOn(WHEEL, Vector3.new(4.6, 12, 12), Vector3.new(0, 7.2, 0)), -- wheel + A-frames
				boxOn(WHEEL, Vector3.new(1.2, 14, 1.2), Vector3.new(0, 7, -8)), -- aqueduct riser
			},
		},
		D4_SteamWhistles = {
			models = { { key = "D4_SteamWhistles", cf = WHISTLES } },
			collision = { boxOn(WHISTLES, Vector3.new(7.4, 2.2, 1.6), Vector3.new(0, 1.1, 0)) },
		},
		D4_HotSprings = {
			models = { { key = "D4_HotSprings", cf = SPRINGS } },
			collision = {
				boxOn(SPRINGS, Vector3.new(7.4, 1.6, 7.4), Vector3.new(4, 0.8, 3.5)), -- raised upper tier
				boxOn(SPRINGS, Vector3.new(0.9, 3, 0.9), Vector3.new(10.15, 1.5, -1)), -- inlet riser
			},
		},
		D4_PressureValves = {
			models = { { key = "D4_PressureValves", cf = VALVES } },
			collision = { boxOn(VALVES, Vector3.new(6.4, 1.8, 2.2), Vector3.new(0, 0.9, 0)) },
		},
		D4_MegaGeyser = {
			models = { { key = "D4_MegaGeyser", cf = MEGA } },
			collision = {
				boxOn(MEGA, Vector3.new(15.6, 2.4, 9.8), Vector3.new(0, 1.2, 0)),
				boxOn(MEGA, Vector3.new(9.8, 2.4, 15.6), Vector3.new(0, 1.2, 0)),
				boxOn(MEGA, Vector3.new(8, 5, 8), Vector3.new(0, 2.5, 0)),
				boxOn(MEGA, Vector3.new(4.6, 7.2, 4.6), Vector3.new(0, 3.6, 0)),
			},
		},
		D4_ParaPete = {
			models = { { key = "D4_ParaPete", cf = PETE } },
			collision = {},
		},
		D4_StoneSteps = {
			models = { { key = "D4_StoneSteps", cf = STEPS } },
			collision = {
				-- Real stairs: four steps (0.6 rise each) up to the 2.4-high ledge.
				boxOn(STEPS, Vector3.new(3.4, 0.6, 1.2), Vector3.new(0, 0.3, -2.4)),
				boxOn(STEPS, Vector3.new(3.3, 1.2, 1.2), Vector3.new(0, 0.6, -1.2)),
				boxOn(STEPS, Vector3.new(3.2, 1.8, 1.2), Vector3.new(0, 0.9, 0)),
				boxOn(STEPS, Vector3.new(3.1, 2.4, 1.2), Vector3.new(0, 1.2, 1.2)),
				boxOn(STEPS, Vector3.new(5.6, 2.4, 4.4), Vector3.new(0, 1.2, 2.8)),
			},
		},
	} :: { [string]: BuildGroup },

	-- BuyPad ground positions (slot-local), alternating either side of the walkway in buy order;
	-- the Unlock pad sits at the far (away-from-hub) end of the row.
	pads = {
		d4_geyser_vent = Vector3.new(-11, FLOOR, 9),
		d4_bamboo_pipes = Vector3.new(11, FLOOR, 9),
		d4_water_wheel = Vector3.new(-20, FLOOR, 9),
		d4_steam_whistles = Vector3.new(20, FLOOR, 9),
		d4_hot_springs = Vector3.new(-29, FLOOR, 9),
		d4_pressure_valves = Vector3.new(29, FLOOR, 9),
		d4_mega_geyser = Vector3.new(-38, FLOOR, 9),
		d4_para_pete = Vector3.new(38, FLOOR, 9),
		d4_stone_steps = Vector3.new(-47, FLOOR, 9),
		d4_build_lab = Vector3.new(47, FLOOR, 9),
	} :: { [string]: Vector3 },

	-- Billboard anchor at eye level in the clear space in front of the pump bench; the click box
	-- wraps mound, jet and bench.
	producer = {
		anchor = Vector3.new(0, FLOOR + 7.5, BILLBOARD_Z),
		click = { size = PRODUCER_CLICK_SIZE, cf = PRODUCER_CLICK },
	},

	-- Teleport target: on the walkway between the pad row and the arch.
	spawnPoint = Vector3.new(0, FLOOR + 3, 13),
}

return layout
