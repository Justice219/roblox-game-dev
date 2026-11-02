--!strict
--[[
	Worlds/Dino/Layouts/Area01 — slot layout of Dino Valley area D1 "Cave Workshop" (spec
	2026-10-31-world2-design §6.2 / §16; W6 art-d12).

	Contract: identical to AreaLayouts/AreaNN (docs/superpowers/plans/2026-10-30-sellnukes-build.md
	→ "World layout"), validated by src/server/Tycoon/LayoutLogic.luau against the Dino AreaConfig
	(Worlds/Dino/Areas/Area01). Consumed by PlotBuilder.world("dino"): `base` is built when the
	Dino plot is first built (D1 has no unlock pad), `builds[buildKey]` when that pad is bought,
	pads / producer / spawnPoint at plot build time. The Unlock pad's key `D2_EntryArch` is NOT
	here: it resolves to Dino Area02.base.

	Meshes: tools/blender/models/dino_area01.py (D1_*). Art notes: docs/areas-art.md → "Dino D1".

	Frame: SLOT-LOCAL studs. Origin = road-side edge midpoint, +Z away from the road, +Y up,
	x ∈ [-52, 52], z ∈ [0, 70]. Identity rotation = model front (-Z) faces the road. Standing on
	the road looking in, +X is on your LEFT. The jungle-floor lot (D1_Floor) is a 0.5-stud plate
	(y = LOT); its sand path runs from the arch to a round clearing (r 11) in front of the bench.

	Scene (top-down, road at the bottom):
		z 55-70  the mossy cave cliff across the back, cave mouth at x ±9 (15 high);
		         side cliff returns at x ±(44..52), z 46-55
		z 50     torch walls either side of the mouth (x ±20)
		z 42-47  the stone bench (producer) on the clearing, Rocky Raptor behind it at x 5.5
		z 41-46  bone-tool rack (x 14) and the cave paintings (x 31) on the +X side
		z 30     fire pit (x -15) with the leaf bellows blowing into it from x -22.5
		z 13-46  log fences along both slot edges
		z 4      CAVE WORKSHOP arch over the path (clear width 14)
		z 10     pad row: buy order alternates either side of the arch, moving outward

	Animated pieces (for WorldFx / W10): D1_TorchWall FlameA/B/C, D1_FirePit FlameOuter /
	FlameInner (`Flame` row: soft flicker light) + SteamAnchor (existing `Steam` row: campfire
	puffs), D1_StoneBench NukeStone / NukeFins / NukeBand (existing `Nuke` bob, one group).
	Manager: D1_RockyRaptor (R30 rig pieces; joints printed by the Blender build).

	Example:
		local layout = require(ReplicatedStorage.Shared.Config.Worlds.Dino.Layouts.Area01)
		print(layout.builds.D1_StoneBench.models[1].key) --> "D1_StoneBench"
]]

export type ModelPlacement = { key: string, cf: CFrame, tint: Color3?, castShadow: boolean?, collide: boolean? }
export type CollisionBox = { size: Vector3, cf: CFrame }
export type BuildGroup = { models: { ModelPlacement }, collision: { CollisionBox } }

-- Jungle-floor lot top (D1_Floor).
local LOT = 0.5
-- Stone bench slab top above the bench pivot (D1_StoneBench SLAB_TOP).
local SLAB_TOP = 3.5

--[[
	Slot-local CFrame from a position + yaw in degrees (CCW seen from above, Roblox convention).
	yaw 90 turns a model's front (-Z) toward -X; yaw -90 toward +X; 180 toward +Z.

	Example: at(-51, LOT, 21, 90) -- a fence run along Z facing out (-X)
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
local BENCH = at(0, LOT, 42) -- slab x ±5, z 40.1..43.9; the pebble nuke hovers over its centre
local TORCH_WALLS = { at(-20, LOT, 50), at(20, LOT, 50) }
local BONE_TOOLS = at(14, LOT, 41, 25) -- turned toward the bench
local PAINTINGS = at(31, LOT, 46, 18)
local FIRE_PIT = at(-15, LOT, 30)
local BELLOWS = at(-22.5, LOT, 30, -90) -- nozzle (-Z) turned toward +X, into the fire pit
local RAPTOR = at(5.5, LOT, 47) -- behind the bench, in front of the cave mouth
-- Log fence runs (16 long, along local X): both slot edges, facing out.
local FENCE_RUNS = { at(-51, LOT, 21, 90), at(-51, LOT, 37.6, 90), at(51, LOT, 21, -90), at(51, LOT, 37.6, -90) }
-- D1_Jungle palm trunks {x, z} and boulders {x, z, half extent} (slot pivot; colliders only).
local PALMS = { { -44, 20 }, { -38, 4.5 }, { 44, 22 }, { 39, 4.5 }, { -30, 36 }, { 38, 32 } }
local ROCKS = { { -46, 18, 1.8 }, { -29, 28, 1.3 }, { 47, 18, 1.7 }, { 28, 29, 1.4 } }

local baseCollision: { CollisionBox } = {
	{ size = Vector3.new(104, LOT, 70), cf = at(0, LOT / 2, 35) }, -- jungle-floor lot (top = LOT)
	boxOn(ARCH, Vector3.new(4.2, 9, 4.2), Vector3.new(8.8, 4.5, 0)), -- arch posts
	boxOn(ARCH, Vector3.new(4.2, 9, 4.2), Vector3.new(-8.8, 4.5, 0)),
	{ size = Vector3.new(104, 26, 15.6), cf = at(0, 13, 62.2) }, -- back cliff (incl. the dark cave mouth)
	{ size = Vector3.new(8, 15, 9), cf = at(-48, 7.5, 50.5) }, -- side cliff returns
	{ size = Vector3.new(8, 15, 9), cf = at(48, 7.5, 50.5) },
}
for _, palm in PALMS do
	table.insert(baseCollision, { size = Vector3.new(1.3, 6, 1.3), cf = at(palm[1], LOT + 3, palm[2]) })
end
for _, rock in ROCKS do
	local r = rock[3]
	table.insert(baseCollision, { size = Vector3.new(2 * r, r * 1.3, 2 * r), cf = at(rock[1], LOT + r * 0.7, rock[2]) })
end

local layout = {
	area = 1,
	-- Built with the Dino plot: jungle-floor lot, the arch, the cave cliff and the jungle frame.
	base = {
		models = {
			{ key = "D1_Floor", cf = CFrame.identity, castShadow = false },
			{ key = "D1_Jungle", cf = CFrame.identity },
			{ key = "D1_CaveCliff", cf = CFrame.identity },
			{ key = "D1_EntryArch", cf = ARCH },
		},
		collision = baseCollision,
	} :: BuildGroup,
	builds = {
		-- Pad 1: the producer — slab bench with the hovering pebble nuke, chisel, mallet, pebbles.
		D1_StoneBench = {
			models = { { key = "D1_StoneBench", cf = BENCH } },
			collision = { boxOn(BENCH, Vector3.new(10, SLAB_TOP, 3.8), Vector3.new(0, SLAB_TOP / 2, 0)) },
		},
		D1_TorchWall = {
			models = listModels("D1_TorchWall", TORCH_WALLS),
			collision = listCollision(TORCH_WALLS, Vector3.new(10, 3, 1.6), Vector3.new(0, 1.5, 0)),
		},
		D1_BoneTools = {
			models = { { key = "D1_BoneTools", cf = BONE_TOOLS } },
			collision = {
				boxOn(BONE_TOOLS, Vector3.new(0.8, 4.6, 0.8), Vector3.new(-3, 2.3, 0)),
				boxOn(BONE_TOOLS, Vector3.new(0.8, 4.6, 0.8), Vector3.new(3, 2.3, 0)),
				boxOn(BONE_TOOLS, Vector3.new(1.5, 1.2, 1.5), Vector3.new(4.6, 0.6, -0.6)), -- tool stump
			},
		},
		D1_CavePaintings = {
			models = { { key = "D1_CavePaintings", cf = PAINTINGS } },
			collision = { boxOn(PAINTINGS, Vector3.new(11.4, 8.2, 2.6), Vector3.new(0, 4.1, 0)) },
		},
		D1_FirePit = {
			models = { { key = "D1_FirePit", cf = FIRE_PIT } },
			collision = { boxOn(FIRE_PIT, Vector3.new(5.6, 1.2, 5.6), Vector3.new(0, 0.6, 0)) },
		},
		D1_LeafBellows = {
			models = { { key = "D1_LeafBellows", cf = BELLOWS } },
			collision = { boxOn(BELLOWS, Vector3.new(3.4, 4.2, 3.2), Vector3.new(0, 2.1, 0)) },
		},
		-- Manager: Rocky Raptor behind the bench, facing the customers.
		D1_RockyRaptor = {
			models = { { key = "D1_RockyRaptor", cf = RAPTOR } },
			collision = { boxOn(RAPTOR, Vector3.new(3, 6.8, 2.6), Vector3.new(0, 3.4, 0.3)) },
		},
		D1_LogFence = {
			models = listModels("D1_LogFence", FENCE_RUNS),
			collision = listCollision(FENCE_RUNS, Vector3.new(16.4, 3, 0.9), Vector3.new(0, 1.5, -0.2)),
		},
	} :: { [string]: BuildGroup },
	-- BuyPad ground positions: alternate either side of the arch in buy order, moving outward; the
	-- Unlock pad (Open the Fern Market) at the +X end.
	pads = {
		d1_stone_bench = Vector3.new(-16, LOT, 10),
		d1_torch_wall = Vector3.new(16, LOT, 10),
		d1_bone_tools = Vector3.new(-24, LOT, 10),
		d1_cave_paintings = Vector3.new(24, LOT, 10),
		d1_fire_pit = Vector3.new(-32, LOT, 10),
		d1_leaf_bellows = Vector3.new(32, LOT, 10),
		d1_rocky_raptor = Vector3.new(-40, LOT, 10),
		d1_log_fence = Vector3.new(40, LOT, 10),
		d1_open_market = Vector3.new(48, LOT, 10),
	} :: { [string]: Vector3 },
	-- The anchor is where the client puts the producer billboard (owner R31 / R32): 2.5 in front of
	-- the click box's front face (z 39.8), 6 above the lot, on the open clearing.
	producer = {
		anchor = Vector3.new(0, LOT + 6, 37.3),
		click = { size = Vector3.new(10.4, 4.4, 4.4), cf = BENCH * CFrame.new(0, 2.2, 0) },
	},
	-- Teleport target (ground level, on the sand path inside the arch).
	spawnPoint = Vector3.new(0, LOT, 12),
}

return layout
