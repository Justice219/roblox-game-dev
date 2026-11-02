--!strict
--[[
	AreaLayouts/Area05 — slot layout of Area 5 "Enrichment Lab" (spec §3.5).

	Contract: docs/superpowers/plans/2026-10-30-sellnukes-build.md → "World layout". Consumed by B5's
	PlotBuilder: `base` is built when the area unlocks (Area 4's Unlock pad key `A5_EntryArch`
	resolves here), `builds[buildKey]` when that pad is bought, pads/producer/spawnPoint are read
	at plot build time. Meshes come from tools/blender/models/area05.py (keys `A5_*`, MeshAssets).

	Frame: SLOT-LOCAL studs. Origin = road-side edge midpoint of the slot, +Z away from the road,
	+Y up, slot x ∈ [-52, 52], z ∈ [0, 70]. Identity rotation = model front (-Z) faces the road.
	Area 5 is a LEFT-side slot: the hub is toward -X, so the Unlock pad sits at the +X end.

	Heights: the yard slab (A5_Floor) tops out at y = 0.4 (FLOOR). Pad 2 (A5_CleanRoomFloor) lays
	0.3-stud tiles inside the lab, and pads are bought strictly in order, so every model bought
	after it that stands inside the lab is placed at y = TILES (0.7). The lab shell and the
	producer (pad 1) stand at FLOOR; the producer's 0.8 plinth simply sits 0.3 into the tiles.

	Scene (top-down, road at the bottom):
		z 28-66  lab shell, x ∈ [-44, 44], open front at z = 28, airlock at x = 22. Four meshes so no
		         shell piece's bounding box covers the producer's billboard space (owner R31 / R32):
		         A5_LabShell (front pillars + header + skylight), A5_LabSide x2, A5_LabBack
		z 38-46  producer "Centrifuge Row" (A5_CentrifugeRow) at x = 0, single centrifuges at x = ±17
		         lockers on the left wall (x ≈ -41), glow vats along the right wall (x = 37),
		         computer wall on the back wall (x = -12), head scientist on a podium at (-13, 33)
		z 21-25  safety-sign corners either side of the walkway
		z 18     entry arch over the teal walkway x ∈ [-6, 6]
		z 9      pad row (alternating either side of the walkway, buy order outward)

	Collision: invisible primitive boxes (meshes never collide). Walls, machines, furniture and the
	sign posts get boxes; chairs, cones and the floor markings stay walk-through on purpose.

	Example (B5):
		local layout = require(ReplicatedStorage.Shared.Config.AreaLayouts.Area05)
		for _, placement in layout.builds.A5_GlowVats.models do
			MeshLibrary.spawn(placement.key, plotFolder, slotCFrame * placement.cf)
		end
]]

export type ModelPlacement = { key: string, cf: CFrame }
export type CollisionBox = { size: Vector3, cf: CFrame }
export type BuildGroup = { models: { ModelPlacement }, collision: { CollisionBox } }

-- Yard slab top (A5_Floor).
local FLOOR = 0.4
-- Clean-room tile top (A5_CleanRoomFloor, pad 2): later lab furniture stands here.
local TILES = 0.7

--[[
	Slot-local CFrame helper: position + yaw in degrees (CCW from above, Roblox convention).
	yaw -90 turns a model's front (-Z) toward +X; yaw 90 toward -X; 180 toward +Z.

	Example: at(-41, TILES, 40, -90) -- the lockers against the left wall, facing into the lab (+X)
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
local SHELL = at(0, FLOOR, 47) -- also the A5_CleanRoomFloor / A5_LabBack pivot
-- The one side-wall mesh, placed twice: centre 43.4 either side of the shell centre (the -X copy
-- is turned 180°; the wall is symmetric, so it reads the same and the GPU instances both).
local SIDE_WALLS = {
	SHELL * at(43.4, 0, 0),
	SHELL * at(-43.4, 0, 0, 180),
}
local PRODUCER = at(0, FLOOR, 42)
--[[
	The Centrifuge Row's three rotors (owner R41): one A5_CentrifugeRotor placement per drum, pivot
	on the drum top centre (row-local (x, 3.7, 0); models/area05.py CENTRIFUGE_ROTOR_X /
	ROW_DRUM_TOP). Separate models on purpose: WorldFx moves all same-row pieces of ONE model as one
	group, so three rotors inside A5_CentrifugeRow orbited the middle dome instead of each spinning
	in its own.
]]
local CENTRIFUGE_ROTORS = {
	PRODUCER * CFrame.new(-6.5, 3.7, 0),
	PRODUCER * CFrame.new(0, 3.7, 0),
	PRODUCER * CFrame.new(6.5, 3.7, 0),
}
-- Producer click box (wraps the plinth, drums, domes and the feed manifold).
local CLICK_SIZE = Vector3.new(21.5, 9, 7.5)
local CLICK_CF = PRODUCER * CFrame.new(0, 4.5, 0)
local LAB_COATS = at(-41, TILES, 40, -90)
local COMPUTER_WALL = at(-12, TILES, 63.3)
local SCIENTIST = at(-13, TILES, 33, -20)
local CENTRIFUGES = {
	at(-17, TILES, 42),
	at(17, TILES, 42),
}
local VATS = {
	at(37, TILES, 36, 90), -- gauges face into the lab (-X)
	at(37, TILES, 46, 90),
	at(37, TILES, 56, 90),
}
local SIGNS = {
	at(-27, FLOOR, 23, 12),
	at(27, FLOOR, 23, -12),
}

-- Collision helpers for repeated props.
local function listCollision(placements: { CFrame }, size: Vector3, localCentre: Vector3): { CollisionBox }
	local boxes: { CollisionBox } = {}
	for _, cf in placements do
		table.insert(boxes, boxOn(cf, size, localCentre))
	end
	return boxes
end

local function listModels(key: string, placements: { CFrame }): { ModelPlacement }
	local models: { ModelPlacement } = {}
	for _, cf in placements do
		table.insert(models, { key = key, cf = cf })
	end
	return models
end

-- Sign posts + the caution A-frame of every safety-sign corner (cones stay walk-through).
local function signCollision(): { CollisionBox }
	local boxes: { CollisionBox } = {}
	for _, cf in SIGNS do
		table.insert(boxes, boxOn(cf, Vector3.new(1.4, 7.6, 1.4), Vector3.new(-4, 3.8, 0.8))) -- trefoil sign
		table.insert(boxes, boxOn(cf, Vector3.new(1.4, 7.6, 1.4), Vector3.new(0.2, 3.8, 1))) -- goggles sign
		table.insert(boxes, boxOn(cf, Vector3.new(2, 2.6, 1.6), Vector3.new(3.8, 1.3, 0.3))) -- A-frame
	end
	return boxes
end

local layout = {
	area = 5,

	-- Built when Area 5 unlocks: lab yard slab + entry arch.
	base = {
		models = {
			{ key = "A5_Floor", cf = at(0, 0, 35) },
			{ key = "A5_EntryArch", cf = at(0, FLOOR, 18) },
		},
		collision = {
			{ size = Vector3.new(104, 1, 70), cf = at(0, FLOOR - 0.5, 35) }, -- floor (top = FLOOR)
			{ size = Vector3.new(6, 14, 5.6), cf = at(-10, FLOOR + 7, 18) }, -- arch pillars
			{ size = Vector3.new(6, 14, 5.6), cf = at(10, FLOOR + 7, 18) },
		},
	},

	builds = {
		-- First pad: the lab shell + the producer "Centrifuge Row".
		A5_LabShell = {
			models = {
				{ key = "A5_LabShell", cf = SHELL },
				{ key = "A5_LabSide", cf = SIDE_WALLS[1] },
				{ key = "A5_LabSide", cf = SIDE_WALLS[2] },
				{ key = "A5_LabBack", cf = SHELL },
				{ key = "A5_CentrifugeRow", cf = PRODUCER },
				{ key = "A5_CentrifugeRotor", cf = CENTRIFUGE_ROTORS[1] },
				{ key = "A5_CentrifugeRotor", cf = CENTRIFUGE_ROTORS[2] },
				{ key = "A5_CentrifugeRotor", cf = CENTRIFUGE_ROTORS[3] },
			},
			collision = {
				boxOn(SHELL, Vector3.new(1.2, 18, 38), Vector3.new(-43.4, 9, 0)), -- left wall
				boxOn(SHELL, Vector3.new(1.2, 18, 38), Vector3.new(43.4, 9, 0)), -- right wall
				boxOn(SHELL, Vector3.new(88, 18, 1.2), Vector3.new(0, 9, 18.4)), -- back wall (airlock stays shut)
				boxOn(SHELL, Vector3.new(2.4, 18, 2.4), Vector3.new(-22, 9, -18.3)), -- front pillars
				boxOn(SHELL, Vector3.new(2.4, 18, 2.4), Vector3.new(22, 9, -18.3)),
				boxOn(PRODUCER, Vector3.new(21, 6.2, 7), Vector3.new(0, 3.1, 0)), -- plinth + drums + domes
			},
		},
		A5_CleanRoomFloor = {
			models = { { key = "A5_CleanRoomFloor", cf = SHELL } },
			-- Tile surface (top = TILES) so feet sit on the tiles, not 0.3 inside them.
			collision = { boxOn(SHELL, Vector3.new(85.2, 0.3, 36.2), Vector3.new(0, 0.15, -0.5)) },
		},
		A5_Centrifuges = {
			models = listModels("A5_Centrifuge", CENTRIFUGES),
			collision = listCollision(CENTRIFUGES, Vector3.new(6.4, 6, 6.4), Vector3.new(0, 3, 0)),
		},
		A5_LabCoats = {
			models = { { key = "A5_LabCoats", cf = LAB_COATS } },
			collision = { boxOn(LAB_COATS, Vector3.new(18.4, 7, 2.8), Vector3.new(0, 3.5, 0.35)) },
		},
		A5_ComputerWall = {
			models = { { key = "A5_ComputerWall", cf = COMPUTER_WALL } },
			collision = { boxOn(COMPUTER_WALL, Vector3.new(20.4, 10.8, 4.2), Vector3.new(0, 5.4, -0.6)) },
		},
		A5_GlowVats = {
			models = listModels("A5_GlowVat", VATS),
			collision = listCollision(VATS, Vector3.new(5.8, 7.8, 5.8), Vector3.new(0, 3.9, 0)),
		},
		A5_SafetySigns = {
			models = listModels("A5_SafetySigns", SIGNS),
			collision = signCollision(),
		},
		A5_HeadScientist = {
			models = { { key = "A5_HeadScientist", cf = SCIENTIST } },
			collision = { boxOn(SCIENTIST, Vector3.new(5.6, 7.2, 5.6), Vector3.new(0, 3.6, 0)) },
		},
	} :: { [string]: BuildGroup },

	-- BuyPad ground positions (slot-local), alternating either side of the walkway in buy order;
	-- left-side slot, so the row runs outward toward +X and the Unlock pad sits at x = 47.
	pads = {
		a5_lab_shell = Vector3.new(11, FLOOR, 9),
		a5_clean_room_floor = Vector3.new(-11, FLOOR, 9),
		a5_centrifuges = Vector3.new(20, FLOOR, 9),
		a5_lab_coats = Vector3.new(-20, FLOOR, 9),
		a5_computer_wall = Vector3.new(29, FLOOR, 9),
		a5_glow_vats = Vector3.new(-29, FLOOR, 9),
		a5_safety_signs = Vector3.new(38, FLOOR, 9),
		a5_head_scientist = Vector3.new(-38, FLOOR, 9),
		a5_open_factory = Vector3.new(47, FLOOR, 9),
	} :: { [string]: Vector3 },

	-- Billboard anchor (owner R31 / R32): eye level (tile top + 7.5) in the clear space 2.5 studs in
	-- front of the click box's road-side face (z 38.25), exactly where ProducerBillboards.place
	-- puts the billboard; the click box wraps the whole centrifuge row.
	producer = {
		anchor = Vector3.new(0, TILES + 7.5, CLICK_CF.Position.Z - CLICK_SIZE.Z / 2 - 2.5),
		click = { size = CLICK_SIZE, cf = CLICK_CF },
	},

	-- Teleport target: on the walkway between the pad row and the arch.
	spawnPoint = Vector3.new(0, FLOOR + 3, 13),
}

return layout
