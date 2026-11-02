--!strict
--[[
	AreaLayouts/Area02 — slot layout of Area 2 "Nuke Stand" (spec §3.2).

	Contract: docs/superpowers/plans/2026-10-30-sellnukes-build.md → "World layout", validated by
	src/server/Tycoon/LayoutLogic.luau (tests/area-layouts.luau). Consumed by B5's PlotBuilder:
	`base` is built when Area 2 unlocks (Area 1's Unlock pad key `A2_EntryArch` resolves here),
	`builds[buildKey]` when that pad is bought, pads / producer / spawnPoint at plot build time.
	The Unlock pad's key `A3_EntryArch` is NOT here: it resolves to Area03.base.

	Meshes: tools/blender/models/area02.py (A2_*). Art notes: docs/areas-art.md → "Area 2".

	Frame: SLOT-LOCAL studs. Origin = road-side edge midpoint, +Z away from the road, +Y up,
	x ∈ [-52, 52], z ∈ [0, 70]. Identity rotation = model front (-Z) faces the road.
	The lawn lot (A2_Lot) is a 0.5-stud plate (y = LOT); the stand sits on a plank deck
	(x ∈ [-20, 20], z ∈ [22, 42]) whose top is DECK = 0.8.

	Scene (top-down, road at the bottom):
		z 69     white picket fence across the back (+ both sides from z 20)
		z 38.5   the renamable neon sign on tall posts, mascot nuke on top
		z 26-35  the stand: counter (crates of nukes) + back rack, striped awning, fridge at x 13.5
		z 30/50  picnic tables with umbrellas either side (x ±31)
		z 4      NUKE STAND entry arch over a sandy path (clear width 15)
		z 10     pad row: buy order alternates either side of the arch, moving outward

	Extra top-level field (LayoutLogic passes unknown fields through):
		standSign = { cf = CFrame, backCf = CFrame, size = Vector3 } — the Neon Sign's two display
		faces (the board is double-sided, owner R17), slot-local. cf is the road-side face centre with
		its LookVector toward the road; backCf the rear face centre with its LookVector away from
		the road; size is one panel (15 x 4.2). Mount the filtered stand name on BOTH as a
		SurfaceGui (Face = Front) on an invisible part of that size, so it reads correctly from either
		side; default text "Fresh Nukes!" (spec §3.2, StandRename).

	Example (B5):
		local layout = require(ReplicatedStorage.Shared.Config.AreaLayouts.Area02)
		local panel = Instance.new("Part"); panel.Size = layout.standSign.size
		panel.CFrame = slotCFrame * layout.standSign.cf -- then a SurfaceGui with Face = Front;
		-- repeat with layout.standSign.backCf for the rear face
]]

export type ModelPlacement = { key: string, cf: CFrame, tint: Color3?, castShadow: boolean?, collide: boolean? }
export type CollisionBox = { size: Vector3, cf: CFrame }
export type BuildGroup = { models: { ModelPlacement }, collision: { CollisionBox } }

-- Lawn lot top (A2_Lot) and the plank deck top under the stand.
local LOT = 0.5
local DECK = 0.8
-- Stand counter top above the stand pivot (A2_StandCounter).
local COUNTER_TOP = 3.5

--[[
	Slot-local CFrame from a position + yaw in degrees (CCW seen from above, Roblox convention).
	yaw 90 turns a model's front (-Z) toward -X; yaw -90 toward +X; 180 toward +Z.

	Example: at(-51, LOT, 28, 90) -- a fence run along Z with its pickets facing out (-X)
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

-- Shared placements.
local STAND = at(0, DECK, 30) -- stand pivot: counter front at z ~27.3, back rack at z 34
local SIGN = at(0, DECK, 38.5) -- neon sign posts on the deck behind the rack
local ARCH = at(0, LOT, 4)
-- Picket fence: 16-stud runs; sides face out (±X), the back faces out (+Z).
local FENCE_RUNS = {
	-- Runs are 16.6 apart so neighbouring end posts stand side by side instead of overlapping.
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
local PICNIC_TABLES = { at(-31, LOT, 30), at(31, LOT, 30), at(-31, LOT, 50), at(31, LOT, 50) }
-- Yard pines (A2_Yard, slot-origin pivot): {x, z, height}; blocky trunk = 38 % of the height.
local TREES = { { -44, 62, 11 }, { -34, 64, 9 }, { 44, 62, 11 }, { 35, 64, 9.5 }, { -45, 22, 9 }, { 45, 22, 9 } }

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

local baseCollision: { CollisionBox } = {
	{ size = Vector3.new(104, LOT, 70), cf = at(0, LOT / 2, 35) }, -- lawn lot (top = LOT)
	{ size = Vector3.new(40, DECK - LOT, 20), cf = at(0, (LOT + DECK) / 2, 32) }, -- plank deck
	boxOn(ARCH, Vector3.new(4, 10, 4), Vector3.new(9, 5, 0)), -- arch posts
	boxOn(ARCH, Vector3.new(4, 10, 4), Vector3.new(-9, 5, 0)),
	{ size = Vector3.new(9.2, 1.8, 1.6), cf = at(-14.75, LOT + 0.9, 20.6) }, -- bushes by the deck
	{ size = Vector3.new(9.2, 1.8, 1.6), cf = at(14.75, LOT + 0.9, 20.6) },
	{ size = Vector3.new(2.4, 3.4, 6.2), cf = at(-24, LOT + 1.7, 27.6) }, -- hay stacks
	{ size = Vector3.new(5.2, 1.7, 3.0), cf = at(25.3, LOT + 0.85, 38) },
}
for _, tree in TREES do
	local h = tree[3] * 0.38
	table.insert(baseCollision, { size = Vector3.new(1.3, h, 1.3), cf = at(tree[1], LOT + h / 2, tree[2]) })
end

local layout = {
	area = 2,
	-- Built when Area 2 unlocks: lawn lot + plank deck, the arch, pines / bushes / hay.
	base = {
		models = {
			{ key = "A2_Lot", cf = CFrame.identity, castShadow = false },
			{ key = "A2_Yard", cf = CFrame.identity },
			{ key = "A2_EntryArch", cf = ARCH },
		},
		collision = baseCollision,
	} :: BuildGroup,
	builds = {
		-- Pad 1: the producer — planked counter with crates of nukes and the stocked back rack.
		A2_Counter = {
			models = { { key = "A2_StandCounter", cf = STAND } },
			collision = {
				boxOn(STAND, Vector3.new(16.6, COUNTER_TOP, 2.8), Vector3.new(0, COUNTER_TOP / 2, -1.25)),
				boxOn(STAND, Vector3.new(15.2, 7.5, 1.4), Vector3.new(0, 3.75, 4.0)),
			},
		},
		A2_Awning = {
			models = { { key = "A2_Awning", cf = STAND } },
			collision = {
				boxOn(STAND, Vector3.new(0.6, 8.6, 0.6), Vector3.new(-8.5, 4.3, -3.2)), -- front posts
				boxOn(STAND, Vector3.new(0.6, 8.6, 0.6), Vector3.new(8.5, 4.3, -3.2)),
				boxOn(STAND, Vector3.new(0.6, 10.4, 0.6), Vector3.new(-8.5, 5.2, 4.8)), -- back posts
				boxOn(STAND, Vector3.new(0.6, 10.4, 0.6), Vector3.new(8.5, 5.2, 4.8)),
			},
		},
		-- Counter-top props (the counter's own box already covers them).
		A2_CashRegister = {
			models = { { key = "A2_Register", cf = STAND * CFrame.new(5.4, COUNTER_TOP, -1.4) } },
			collision = {},
		},
		A2_TipJar = {
			models = { { key = "A2_TipJar", cf = STAND * CFrame.new(2.3, COUNTER_TOP, -1.4) } },
			collision = {},
		},
		A2_NeonSign = {
			models = { { key = "A2_NeonSign", cf = SIGN } },
			collision = {
				boxOn(SIGN, Vector3.new(1.0, 12.5, 1.0), Vector3.new(-5.5, 6.25, 0.6)),
				boxOn(SIGN, Vector3.new(1.0, 12.5, 1.0), Vector3.new(5.5, 6.25, 0.6)),
			},
		},
		-- "Cooler" pad: the glass-door fridge, turned a little toward the counter.
		A2_Cooler = {
			models = { { key = "A2_Fridge", cf = at(13.5, DECK, 30.5, 12), collide = true } },
			collision = {},
		},
		A2_PicketFence = {
			models = listModels("A2_FenceRun", FENCE_RUNS),
			collision = listCollision(FENCE_RUNS, Vector3.new(16.4, 3.6, 0.7), Vector3.new(0, 1.8, 0.15)),
		},
		-- Manager: the Cashier Bot hovering behind the counter.
		A2_CashierBot = {
			-- z 2.2: the nuke in its right hand stays above/behind the counter top (back edge z 0.5).
			models = { { key = "A2_CashierBot", cf = STAND * CFrame.new(0, 0, 2.2) } },
			collision = { boxOn(STAND, Vector3.new(2.8, 7.2, 2.0), Vector3.new(0, 3.6, 2.2)) },
		},
		A2_PicnicTables = {
			models = listModels("A2_PicnicTable", PICNIC_TABLES),
			collision = (function(): { CollisionBox }
				local boxes = listCollision(PICNIC_TABLES, Vector3.new(6, 2.7, 2.4), Vector3.new(0, 1.35, 0))
				for _, box in listCollision(PICNIC_TABLES, Vector3.new(6, 1.6, 0.9), Vector3.new(0, 0.8, 2)) do
					table.insert(boxes, box)
				end
				for _, box in listCollision(PICNIC_TABLES, Vector3.new(6, 1.6, 0.9), Vector3.new(0, 0.8, -2)) do
					table.insert(boxes, box)
				end
				return boxes
			end)(),
		},
	} :: { [string]: BuildGroup },
	-- BuyPad ground positions: alternate either side of the arch in buy order, moving outward;
	-- the Unlock pad (Start BoomDash) at the +X end.
	pads = {
		a2_counter = Vector3.new(-16, LOT, 10),
		a2_awning = Vector3.new(16, LOT, 10),
		a2_cash_register = Vector3.new(-24, LOT, 10),
		-- Owner R137: the Cashier Bot is pad 4 now (TycoonAreas/Area02), so he takes the 4th spot
		-- (+24) and Tip Jar .. Picket Fence move one spot outward; Picnic Tables and Start BoomDash
		-- keep theirs, so the next pad is still always the closest unbought one across the arch.
		a2_cashier_bot = Vector3.new(24, LOT, 10),
		a2_tip_jar = Vector3.new(-32, LOT, 10),
		a2_neon_sign = Vector3.new(32, LOT, 10),
		a2_cooler = Vector3.new(-40, LOT, 10),
		a2_picket_fence = Vector3.new(40, LOT, 10),
		a2_picnic_tables = Vector3.new(-48, LOT, 10),
		a2_start_boomdash = Vector3.new(48, LOT, 10),
	} :: { [string]: Vector3 },
	-- The anchor is where the client puts the billboard (ProducerBillboards.place, owner R31/R32):
	-- 2.5 in front of the click box's front face (z 27.0) and MinHeight 6 above the deck (the
	-- counter is lower than the 7.5 eye height), out from under the awning.
	producer = {
		anchor = Vector3.new(0, DECK + 6.0, 24.5),
		click = { size = Vector3.new(16.8, 4.2, 3.6), cf = STAND * CFrame.new(0, 2.1, -1.2) },
	},
	-- Teleport target (ground level, on the sandy path in front of the arch).
	spawnPoint = Vector3.new(0, LOT, 12),
	-- The Neon Sign's display panel (see header): front-face centre, LookVector toward the road.
	standSign = {
		cf = SIGN * CFrame.new(0, 15, -0.31),
		-- Rear panel face (z = +0.8 on the sign), turned 180 degrees so its Front face looks away
		-- from the road and the text reads correctly from behind.
		backCf = SIGN * CFrame.new(0, 15, 0.81) * CFrame.Angles(0, math.pi, 0),
		size = Vector3.new(15, 4.2, 0.1),
	},
}

return layout
