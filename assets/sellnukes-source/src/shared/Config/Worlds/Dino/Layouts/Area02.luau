--!strict
--[[
	Worlds/Dino/Layouts/Area02 — slot layout of Dino Valley area D2 "Fern Market" (spec
	2026-10-31-world2-design §6.2 / §16; W6 art-d12).

	Contract: identical to AreaLayouts/AreaNN (docs/superpowers/plans/2026-10-30-sellnukes-build.md
	→ "World layout"), validated by src/server/Tycoon/LayoutLogic.luau against the Dino AreaConfig
	(Worlds/Dino/Areas/Area02). Consumed by PlotBuilder.world("dino"): `base` is built when D2
	unlocks (D1's Unlock pad key `D2_EntryArch` resolves here), `builds[buildKey]` when that pad is
	bought, pads / producer / spawnPoint at plot build time. The Unlock pad's key `D3_EntryArch` is
	NOT here: it resolves to Dino Area03.base.

	Meshes: tools/blender/models/dino_area02.py (D2_*). Art notes: docs/areas-art.md → "Dino D2".

	Frame: SLOT-LOCAL studs. Origin = road-side edge midpoint, +Z away from the road, +Y up,
	x ∈ [-52, 52], z ∈ [0, 70]. Identity rotation = model front (-Z) faces the road. Standing on
	the road looking in, +X is on your LEFT. The lot (D2_Floor) is a 0.5-stud plate (y = LOT) with a
	sandy market square (x ±24, z 18..54) and a path stub down to the arch.

	Scene (top-down, road at the bottom):
		z 69     bamboo fence across the back (+ both sides from z 20)
		z 50-66  two thatched huts (x ±22, z 60), palms, banana plants, ferns and boulders
		z 36-46  the stall: shell counter (producer) under a giant leaf awning, Stego Sally behind
		         it, the coconut till on the counter's +X end
		z 42-46  the NUKES! totem (x -17) and the mammoth fan (x 16) either side of the stall
		z 33     berry baskets at x ±12, in front of the stall's flanks
		z 24/44  picnic logs at x ±34 on the grass beside the square
		z 4      FERN MARKET arch (clear width 14)
		z 10     pad row: buy order alternates either side of the arch, moving outward

	Animated pieces (for WorldFx / W10): D2_MammothFan `Ears` (both ears in one piece, box centre on
	the head's vertical axis; suggested row oscillate about Y). Manager: D2_StegoSally (R30 rig
	pieces; joints printed by the Blender build).

	Example:
		local layout = require(ReplicatedStorage.Shared.Config.Worlds.Dino.Layouts.Area02)
		print(layout.builds.D2_ShellCounter.models[1].key) --> "D2_ShellCounter"
]]

export type ModelPlacement = { key: string, cf: CFrame, tint: Color3?, castShadow: boolean?, collide: boolean? }
export type CollisionBox = { size: Vector3, cf: CFrame }
export type BuildGroup = { models: { ModelPlacement }, collision: { CollisionBox } }

-- Lot top (D2_Floor).
local LOT = 0.5
-- Counter top above the stall pivot (D2_ShellCounter COUNTER_TOP).
local COUNTER_TOP = 3.3

--[[
	Slot-local CFrame from a position + yaw in degrees (CCW seen from above, Roblox convention).
	yaw 90 turns a model's front (-Z) toward -X; yaw -90 toward +X; 180 toward +Z.

	Example: at(-51, LOT, 28, 90) -- a fence run along Z facing out (-X)
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
local STALL = at(0, LOT, 40) -- counter x ±7.2, z 38.6..41.4; awning poles at x ±8.5, z 37.6 / 44.4
local SALLY = STALL * CFrame.new(-2.5, 0, 3.2) -- behind the counter, facing the customers
local TOTEM = at(-17, LOT, 44, -12)
local MAMMOTH = at(16, LOT, 43, 22) -- turned toward the stall front
local BASKETS = { at(-12, LOT, 33, 20), at(12, LOT, 33, -20) }
local PICNICS = { at(-34, LOT, 24), at(34, LOT, 24), at(-34, LOT, 44), at(34, LOT, 44) }
-- Bamboo fence: 16-stud runs; sides face out (±X), the back faces out (+Z).
local FENCE_RUNS = {
	at(-51, LOT, 28, 90),
	at(-51, LOT, 44.6, 90),
	at(-51, LOT, 61.2, 90),
	at(51, LOT, 28, -90),
	at(51, LOT, 44.6, -90),
	at(51, LOT, 61.2, -90),
	at(-41.5, LOT, 69, 180),
	at(-24.9, LOT, 69, 180),
	at(-8.3, LOT, 69, 180),
	at(8.3, LOT, 69, 180),
	at(24.9, LOT, 69, 180),
	at(41.5, LOT, 69, 180),
}
-- D2_Grove palm trunks {x, z}, berry bushes {x, z} and boulders {x, z, half extent} (colliders).
local PALMS = { { -45, 60 }, { -34, 65 }, { 45, 59 }, { 34, 65.5 }, { -46, 22 }, { 46, 22 } }
local BUSHES = { { -29, 18 }, { 29, 18 }, { -44, 36 }, { 44, 36 } }
local ROCKS = { { -30, 52, 1.7 }, { 30, 52, 1.6 } }
-- D2_Huts: two round huts (wall radius 4) at x ±22, z 60.
local HUTS = { { -22, 60 }, { 22, 60 } }

local baseCollision: { CollisionBox } = {
	{ size = Vector3.new(104, LOT, 70), cf = at(0, LOT / 2, 35) }, -- lot (top = LOT)
	boxOn(ARCH, Vector3.new(3.4, 9, 3.4), Vector3.new(8.8, 4.5, 0)), -- bamboo arch posts
	boxOn(ARCH, Vector3.new(3.4, 9, 3.4), Vector3.new(-8.8, 4.5, 0)),
}
for _, palm in PALMS do
	table.insert(baseCollision, { size = Vector3.new(1.3, 6, 1.3), cf = at(palm[1], LOT + 3, palm[2]) })
end
for _, bush in BUSHES do
	table.insert(baseCollision, { size = Vector3.new(3.4, 2.2, 3.0), cf = at(bush[1] + 0.3, LOT + 1.1, bush[2] - 0.2) })
end
for _, rock in ROCKS do
	local r = rock[3]
	table.insert(baseCollision, { size = Vector3.new(2 * r, r * 1.3, 2 * r), cf = at(rock[1], LOT + r * 0.7, rock[2]) })
end
for _, hut in HUTS do
	-- Two crossed boxes approximate the round wall (players walk round it, not into the doorway).
	table.insert(baseCollision, { size = Vector3.new(8, 4.2, 5.6), cf = at(hut[1], LOT + 2.1, hut[2]) })
	table.insert(baseCollision, { size = Vector3.new(5.6, 4.2, 8), cf = at(hut[1], LOT + 2.1, hut[2]) })
end

local layout = {
	area = 2,
	-- Built when D2 unlocks: lot + market square, the arch, the jungle grove and the huts.
	base = {
		models = {
			{ key = "D2_Floor", cf = CFrame.identity, castShadow = false },
			{ key = "D2_Grove", cf = CFrame.identity },
			{ key = "D2_Huts", cf = CFrame.identity },
			{ key = "D2_EntryArch", cf = ARCH },
		},
		collision = baseCollision,
	} :: BuildGroup,
	builds = {
		-- Pad 1: the producer — shell-trimmed stone counter with pebble nukes on leaf plates.
		D2_ShellCounter = {
			models = { { key = "D2_ShellCounter", cf = STALL } },
			collision = { boxOn(STALL, Vector3.new(14.6, COUNTER_TOP, 2.8), Vector3.new(0, COUNTER_TOP / 2, 0)) },
		},
		D2_LeafAwning = {
			models = { { key = "D2_LeafAwning", cf = STALL } },
			collision = {
				boxOn(STALL, Vector3.new(0.7, 8, 0.7), Vector3.new(-8.5, 4, -2.4)), -- front poles
				boxOn(STALL, Vector3.new(0.7, 8, 0.7), Vector3.new(8.5, 4, -2.4)),
				boxOn(STALL, Vector3.new(0.7, 9.6, 0.7), Vector3.new(-8.5, 4.8, 4.4)), -- back poles
				boxOn(STALL, Vector3.new(0.7, 9.6, 0.7), Vector3.new(8.5, 4.8, 4.4)),
			},
		},
		-- Counter-top prop (the counter's own box covers it).
		D2_CoconutTill = {
			models = { { key = "D2_CoconutTill", cf = STALL * CFrame.new(4.0, COUNTER_TOP, 0.1) } },
			collision = {},
		},
		D2_BerryBaskets = {
			models = listModels("D2_BerryBaskets", BASKETS),
			collision = listCollision(BASKETS, Vector3.new(4.2, 1.6, 4.0), Vector3.new(0, 0.8, 0.4)),
		},
		D2_TotemSign = {
			models = { { key = "D2_TotemSign", cf = TOTEM } },
			collision = { boxOn(TOTEM, Vector3.new(3.6, 9.3, 3.4), Vector3.new(0, 4.65, 0)) },
		},
		D2_MammothFan = {
			models = { { key = "D2_MammothFan", cf = MAMMOTH } },
			collision = { boxOn(MAMMOTH, Vector3.new(3.6, 4.4, 3.4), Vector3.new(0, 2.2, 0.4)) },
		},
		D2_PicnicLogs = {
			models = listModels("D2_PicnicLogs", PICNICS),
			collision = (function(): { CollisionBox }
				local boxes = listCollision(PICNICS, Vector3.new(2.6, 2.4, 2.6), Vector3.new(0, 1.2, 0))
				for _, z in { -2.6, 2.6 } do
					for _, box in listCollision(PICNICS, Vector3.new(5, 1.2, 1.2), Vector3.new(0, 0.6, z)) do
						table.insert(boxes, box)
					end
				end
				return boxes
			end)(),
		},
		-- Manager: Stego Sally behind the counter.
		D2_StegoSally = {
			models = { { key = "D2_StegoSally", cf = SALLY } },
			collision = { boxOn(SALLY, Vector3.new(3.2, 6.6, 2.8), Vector3.new(0, 3.3, 0.3)) },
		},
		D2_BambooFence = {
			models = listModels("D2_BambooFence", FENCE_RUNS),
			collision = listCollision(FENCE_RUNS, Vector3.new(16.4, 3.2, 0.9), Vector3.new(0, 1.6, -0.2)),
		},
	} :: { [string]: BuildGroup },
	-- BuyPad ground positions: alternate either side of the arch in buy order, moving outward; the
	-- Unlock pad (Hire the Pteros) at the +X end.
	pads = {
		d2_shell_counter = Vector3.new(-16, LOT, 10),
		d2_leaf_awning = Vector3.new(16, LOT, 10),
		d2_coconut_till = Vector3.new(-24, LOT, 10),
		d2_berry_baskets = Vector3.new(24, LOT, 10),
		d2_totem_sign = Vector3.new(-32, LOT, 10),
		d2_mammoth_fan = Vector3.new(32, LOT, 10),
		d2_picnic_logs = Vector3.new(-40, LOT, 10),
		d2_stego_sally = Vector3.new(40, LOT, 10),
		d2_bamboo_fence = Vector3.new(-48, LOT, 10),
		d2_hire_pteros = Vector3.new(48, LOT, 10),
	} :: { [string]: Vector3 },
	-- The anchor is where the client puts the producer billboard (owner R31 / R32): 2.5 in front of
	-- the click box's front face (z 38.2), 6 above the lot, out from under the awning's front edge.
	producer = {
		anchor = Vector3.new(0, LOT + 6, 35.7),
		click = { size = Vector3.new(14.8, 4.2, 3.6), cf = STALL * CFrame.new(0, 2.1, 0) },
	},
	-- Teleport target (ground level, on the path inside the arch).
	spawnPoint = Vector3.new(0, LOT, 12),
}

return layout
