--!strict
--[[
	AreaLayouts/Area04 — slot layout of Area 4 "Glow Rock Mine" (spec §3.4).

	Contract: docs/superpowers/plans/2026-10-30-sellnukes-build.md → "World layout". Consumed by B5's
	PlotBuilder: `base` is built when the area unlocks (Area 3's Unlock pad key `A4_EntryArch`
	resolves here), `builds[buildKey]` when that pad is bought, pads/producer/spawnPoint are read
	at plot build time. Meshes come from tools/blender/models/area04.py (keys `A4_*`, MeshAssets).

	Frame: SLOT-LOCAL studs. Origin = road-side edge midpoint of the slot, +Z away from the road,
	+Y up, slot x ∈ [-52, 52], z ∈ [0, 70]. Identity rotation = model front (-Z) faces the road.
	The cave floor slab tops out at y = 0.4 (FLOOR), so everything standing on it sits at y = FLOOR.

	Scene (top-down, road at the bottom):
		z 58-70  back cliff (A4_CaveBack) with the cart tunnel at x = -22
		z 38-48  producer "Glow Rock Drill" (A4_GlowDrill) at x = 0, drill rig at x = 30
		z 35     producer billboard at eye level, framed by the walkway beam frames (z 25 / 31)
		z 20-62  cart track at x = -22 (carts roll into the tunnel), side cliffs at x = ±(43..52)
		z 23-31  foreman's shack at x = 34..40 (open to the walkway), the Foreman NPC in front
		z 18     entry arch over the flagstone walkway x ∈ [-6, 6]
		z 9      pad row (alternating either side of the walkway, buy order outward)

	Collision: invisible primitive boxes (meshes never collide). Small props (carts, crystals on
	the floor) stay walk-through on purpose; anything a player could stand inside gets a box.

	Static checks: no two models interpenetrate (owner R24, tools/blender/check_area_overlaps.py),
	no coplanar faces (R18, tests/zfight-audit.luau), and the producer billboard's spot in front of
	the click box is clear of every visible piece box (R31 / R32).

	Example (B5):
		local layout = require(ReplicatedStorage.Shared.Config.AreaLayouts.Area04)
		for _, placement in layout.base.models do
			MeshLibrary.spawn(placement.key, plotFolder, slotCFrame * placement.cf)
		end
]]

export type ModelPlacement = { key: string, cf: CFrame }
export type CollisionBox = { size: Vector3, cf: CFrame }
export type BuildGroup = { models: { ModelPlacement }, collision: { CollisionBox } }

-- Floor slab top (A4_Floor); every floor-standing model is placed at this height.
local FLOOR = 0.4

--[[
	Slot-local CFrame helper: position + yaw in degrees (CCW from above, Roblox convention).
	yaw -90 turns a model's front (-Z) toward +X; yaw 90 toward -X; 180 toward +Z.

	Example: at(36, FLOOR, 27, 90) -- the foreman's shack, open side facing the walkway (-X)
]]
local function at(x: number, y: number, z: number, yawDeg: number?): CFrame
	return CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yawDeg or 0), 0)
end

--[[
	Collision box anchored to a placed model: `local` is the box centre in the model's own frame,
	so the box follows the model's yaw. Used for rotated props (miners, shack).
]]
local function boxOn(model: CFrame, size: Vector3, localCentre: Vector3): CollisionBox
	return { size = size, cf = model * CFrame.new(localCentre) }
end

-- Shared placements (referenced by both models and collision below).
local GLOW_DRILL = at(0, FLOOR, 42)
local CART_TRACK = at(-22, FLOOR, 41.5)
local DRILL_RIG = at(30, FLOOR, 50)
local FOREMAN = at(36, FLOOR, 27, 90) -- the foreman's shack, open side facing the walkway (-X)
-- The Foreman himself (manager NPC, owner R30) starts in front of his shack's counter; the client
-- ManagerController walks him from here, so he is a separate model with no collision box.
local FOREMAN_FIGURE = FOREMAN * CFrame.new(1.6, 0, -3.4)
-- Producer click box (wraps the whole drill) and the billboard spot in front of it (owner R31 /
-- R32): ProducerBillboards.place puts the billboard FrontGap (2.5) past the click box's road-side
-- face at EyeHeight (7.5) above the walkway; the anchor sits on that same spot so the tutorial
-- arrow and click reach target where the billboard is. The slot in front (z 34.4 .. 35.6, x within
-- +-7.2, y 2 .. 14) is kept free of every visible piece box: the walkway beam frames stop at z 31.9
-- and the lamps stand at x = +-11.
local PRODUCER_CLICK = GLOW_DRILL * CFrame.new(0, 9, 0.5)
local PRODUCER_CLICK_SIZE = Vector3.new(17, 18, 10)
local BILLBOARD_Z = PRODUCER_CLICK.Position.Z - PRODUCER_CLICK_SIZE.Z / 2 - 2.5
local MINERS = {
	at(37, FLOOR, 40, -90), -- chipping at the right cliff
	at(-36, FLOOR, 44, 90), -- chipping at the left cliff
	at(14, FLOOR, 52, -160), -- chipping at the back cliff, 3/4 to the road
}
local BEAM_FRAMES = {
	at(0, FLOOR, 25), -- two frames over the walkway: arch -> frames -> producer
	at(0, FLOOR, 31),
	at(-22, FLOOR, 54), -- over the cart track at the tunnel mouth
}
local LAMPS = {
	at(-11, FLOOR, 36),
	at(11, FLOOR, 36),
	at(-30, FLOOR, 24),
	at(22, FLOOR, 36),
	at(-11, FLOOR, 50), -- lights the tunnel approach; clear of the back cliff foot and the beam frame (R24)
}
-- Glow veins stand free on the floor, clear of the cliffs, the derrick and each other (R24: the
-- old corner spots pushed them into the cliff rock and into the back cliff's own crystals).
local VEINS = {
	at(-35.5, FLOOR, 30, 25), -- clear of the left cliff's foot boulder
	at(-36, FLOOR, 51), -- left pocket between the side cliff, the miner and the tunnel frame
	at(17.5, FLOOR, 41.5), -- beside the producer (right of its crystal bin)
	at(22, FLOOR, 25, -15),
}

-- Collision helpers for repeated props.
local function frameCollision(): { CollisionBox }
	local boxes: { CollisionBox } = {}
	for _, frame in BEAM_FRAMES do
		for _, x in { -8.2, 8.2 } do
			table.insert(boxes, boxOn(frame, Vector3.new(2.6, 13, 2.6), Vector3.new(x, 6.5, 0)))
		end
	end
	return boxes
end

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

local layout = {
	area = 4,

	-- Built when Area 4 unlocks: cave floor, entry arch, both side cliffs.
	base = {
		models = {
			{ key = "A4_Floor", cf = at(0, 0, 35) },
			{ key = "A4_EntryArch", cf = at(0, FLOOR, 18) },
			{ key = "A4_CaveSideR", cf = at(52, FLOOR, 39) },
			{ key = "A4_CaveSideL", cf = at(-52, FLOOR, 39) },
		},
		collision = {
			{ size = Vector3.new(104, 1, 70), cf = at(0, FLOOR - 0.5, 35) }, -- floor (top = FLOOR)
			{ size = Vector3.new(6, 14, 5.6), cf = at(-10, FLOOR + 7, 18) }, -- arch pillars
			{ size = Vector3.new(6, 14, 5.6), cf = at(10, FLOOR + 7, 18) },
			{ size = Vector3.new(8.6, 14, 19), cf = at(47.7, FLOOR + 7, 29.5) }, -- right cliff, low front half
			{ size = Vector3.new(8.6, 24, 19), cf = at(47.7, FLOOR + 12, 48.5) }, -- right cliff, tall back half
			{ size = Vector3.new(8.6, 14, 19), cf = at(-47.7, FLOOR + 7, 29.5) },
			{ size = Vector3.new(8.6, 24, 19), cf = at(-47.7, FLOOR + 12, 48.5) },
		},
	},

	builds = {
		-- First pad: back cliff with the cart tunnel + the producer "Glow Rock Drill".
		A4_MineEntrance = {
			models = {
				{ key = "A4_CaveBack", cf = at(0, FLOOR, 64) },
				{ key = "A4_GlowDrill", cf = GLOW_DRILL },
			},
			collision = {
				{ size = Vector3.new(104, 26, 12), cf = at(0, FLOOR + 13, 64) },
				boxOn(GLOW_DRILL, Vector3.new(13, 6.5, 9), Vector3.new(0, 3.25, 1)), -- base plate + boulder
				boxOn(GLOW_DRILL, Vector3.new(2.4, 3.2, 1.8), Vector3.new(-7.6, 1.6, -1.2)), -- control panel
				boxOn(GLOW_DRILL, Vector3.new(3.4, 2.6, 3), Vector3.new(8, 1.3, -1.6)), -- crystal bin
			},
		},
		A4_SupportBeams = {
			models = listModels("A4_BeamFrame", BEAM_FRAMES),
			collision = frameCollision(),
		},
		A4_PickaxeCrew = {
			models = listModels("A4_Miner", MINERS),
			collision = listCollision(MINERS, Vector3.new(3.2, 6.4, 6), Vector3.new(0.2, 3.2, -1.7)),
		},
		A4_CartTrack = {
			models = {
				{ key = "A4_CartTrack", cf = CART_TRACK },
				-- Carts sit on the rail top (track-local y = 0.6). Owner R56: they run as a two-cart
				-- train (VehicleRouteConfig "A4_Carts"): the second cart is coupled 5.2 studs behind
				-- the first, out of the tunnel to the ore bin and back. Parked near the tunnel mouth,
				-- clear of the producer billboard's side (BillboardSpots).
				{ key = "A4_MineCart", cf = CART_TRACK * CFrame.new(0, 0.6, 3.8) },
				{ key = "A4_MineCart", cf = CART_TRACK * CFrame.new(0, 0.6, 9) },
			},
			collision = {
				boxOn(CART_TRACK, Vector3.new(4.4, 2.5, 1), Vector3.new(0, 1.25, -20.7)), -- buffer stop
				boxOn(CART_TRACK, Vector3.new(4.2, 2.6, 4.2), Vector3.new(5.2, 1.3, -18)), -- ore bin
			},
		},
		A4_DrillRig = {
			models = { { key = "A4_DrillRig", cf = DRILL_RIG } },
			collision = { boxOn(DRILL_RIG, Vector3.new(11, 27, 11), Vector3.new(0, 13.5, 0)) },
		},
		A4_CrystalLamps = {
			models = listModels("A4_CrystalLamp", LAMPS),
			collision = listCollision(LAMPS, Vector3.new(2.4, 8.4, 2.4), Vector3.new(0, 4.2, 0)),
		},
		A4_GlowVein = {
			models = listModels("A4_GlowVein", VEINS),
			collision = listCollision(VEINS, Vector3.new(7.4, 4, 6.6), Vector3.new(0, 2, 0.4)),
		},
		A4_Foreman = {
			models = {
				{ key = "A4_ForemanShack", cf = FOREMAN },
				{ key = "A4_Foreman", cf = FOREMAN_FIGURE },
			},
			collision = { boxOn(FOREMAN, Vector3.new(8, 9, 6), Vector3.new(0, 4.5, 1)) }, -- the shack only
		},
	} :: { [string]: BuildGroup },

	-- BuyPad ground positions (slot-local), alternating either side of the walkway in buy order;
	-- the Unlock pad sits at the far (away-from-hub) end of the row.
	pads = {
		a4_mine_entrance = Vector3.new(-11, FLOOR, 9),
		a4_support_beams = Vector3.new(11, FLOOR, 9),
		a4_pickaxe_crew = Vector3.new(-20, FLOOR, 9),
		a4_cart_track = Vector3.new(20, FLOOR, 9),
		a4_drill_rig = Vector3.new(-29, FLOOR, 9),
		a4_crystal_lamps = Vector3.new(29, FLOOR, 9),
		a4_glow_vein = Vector3.new(-38, FLOOR, 9),
		a4_foreman = Vector3.new(38, FLOOR, 9),
		a4_build_lab = Vector3.new(-47, FLOOR, 9),
	} :: { [string]: Vector3 },

	-- Billboard anchor at eye level in the clear space in front of the drill (owner R32: the old
	-- anchor floated 20.5 studs up over the motor); click box wraps the whole machine.
	producer = {
		anchor = Vector3.new(0, FLOOR + 7.5, BILLBOARD_Z),
		click = { size = PRODUCER_CLICK_SIZE, cf = PRODUCER_CLICK },
	},

	-- Teleport target: on the walkway between the pad row and the arch.
	spawnPoint = Vector3.new(0, FLOOR + 3, 13),
}

return layout
