--!strict
--[[
	Worlds/Dino/Layouts/Area03 — slot layout of Dino Valley area D3 "Ptero Post" (spec
	2026-10-31-world2-design §6.2 / §16; W7 art-d34).

	Contract: identical to AreaLayouts/AreaNN (docs/superpowers/plans/2026-10-30-sellnukes-build.md
	→ "World layout"), validated by src/server/Tycoon/LayoutLogic.luau against the Dino AreaConfig
	(Worlds/Dino/Areas/Area03). Consumed by PlotBuilder for world "dino": `base` is built when D2's
	Unlock pad (build key `D3_EntryArch`) is bought, `builds[buildKey]` when that pad is bought,
	pads / producer / spawnPoint at plot build time. The Unlock pad's key `D4_EntryArch` is NOT here:
	it resolves to Dino Area04.base.

	Meshes: tools/blender/models/dino_area03.py (keys `D3_*`, MeshAssets). Art notes:
	docs/areas-art.md → "Dino D3 / D4".

	Frame: SLOT-LOCAL studs. Origin = road-side edge midpoint, +Z away from the road, +Y up,
	x ∈ [-52, 52], z ∈ [0, 70]. Identity rotation = model front (-Z) faces the road. Standing on the
	road looking in, +X is on your LEFT. The jungle floor slab tops out at y = 0.4 (FLOOR), so
	everything standing on it sits at y = FLOOR.

	Scene (top-down, road at the bottom):
		z 58-70  back-row palms, boulders and ferns (D3_Jungle, base)
		z 40-60  the Nest Tower (producer, x 0): trunk, nest deck at y 20, canopy to y 34, the
		         bamboo chute spiralling down to the sorting counter at z 40; two Ptero couriers
		         perched on the deck
		z 36.3   producer billboard at eye level in front of the counter (R31 / R32)
		z 45-55  rope bridge from the nest rim to the lookout tree at x -31 (y 20)
		z 26-42  landing pad (x 28), Captain Ptera beside it (x 17), wind sock (x 41, z 23)
		z 26-34  ptero perch (x -38), parcel baskets either side of the counter (x ±13, z 40.5)
		z 47-53  treasure-map board (x 40), angled toward the walkway
		z 18     PTERO POST arch over the sand walkway x ∈ [-5, 5]
		z 9      pad row (alternating either side of the walkway, buy order outward)

	Collision: invisible primitive boxes (meshes never collide). Small props (couriers, the
	captain, pteros on the perch) stay walk-through; anything a player could stand inside gets a box.

	Static checks: no two models interpenetrate (owner R24), no coplanar faces (R18,
	tests/zfight-audit.luau once world-aware), the billboard spot in front of the click box is
	clear of every visible piece box (R31 / R32), mesh budgets (spec §15: area ≤ 28k triangles).

	Example (PlotBuilder):
		local layout = require(ReplicatedStorage.Shared.Config.Worlds.Dino.Layouts.Area03)
		for _, placement in layout.base.models do
			MeshLibrary.spawn(placement.key, plotFolder, slotCFrame * placement.cf)
		end
]]

export type ModelPlacement = { key: string, cf: CFrame }
export type CollisionBox = { size: Vector3, cf: CFrame }
export type BuildGroup = { models: { ModelPlacement }, collision: { CollisionBox } }

-- Floor slab top (D3_Floor); every floor-standing model is placed at this height.
local FLOOR = 0.4
-- Nest deck floor height above the tower pivot (dino_area03.py NEST_FLOOR).
local NEST_FLOOR = 20.2

--[[
	Slot-local CFrame helper: position + yaw in degrees (CCW from above, Roblox convention).
	yaw -90 turns a model's front (-Z) toward +X; yaw 90 toward -X; 180 toward +Z.

	Example: at(40, FLOOR, 50, 50) -- the treasure map, turned toward the walkway (-X) and road
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
local TOWER = at(0, FLOOR, 50) -- producer: trunk centre; counter at local z -9.6 (slot z 40.4)
-- Couriers perch on the nest deck facing outward, wings clear of each other and of the parcel
-- pile at the back of the deck. They are ROUTED (R56, W10 VehicleRouteConfig): these placements
-- are the rest poses that Low quality / Reduce Motion keep.
local COURIERS = {
	TOWER * at(4.6, NEST_FLOOR, -3.2, -55),
	TOWER * at(-4.8, NEST_FLOOR, -1.6, 71),
}
local LOOKOUT = at(-31, FLOOR, 50) -- rope-bridge model pivot; the bridge ends 0.15 short of the nest rim
local BASKETS = {
	at(-13, FLOOR, 40.5, 15),
	at(13, FLOOR, 40.5, -15),
}
local WIND_SOCK = at(41, FLOOR, 23)
local FLOCK = at(-38, FLOOR, 30, -50) -- perch turned toward the walkway and the road
local MAP = at(40, FLOOR, 50, 50) -- map board faces the walkway (-X) and the road
local LANDING = at(28, FLOOR, 34)
-- Captain Ptera (manager NPC, owner R30) starts beside the landing pad, turned toward the walkway;
-- the client ManagerController walks him from here, so he has no collision box.
local CAPTAIN = at(17, FLOOR, 26, 20)
-- Back-row palms of D3_Jungle (slot space): trunk boxes so players never walk through them.
local PALMS = {
	Vector3.new(-44, 0, 63),
	Vector3.new(-21, 0, 64.5),
	Vector3.new(20, 0, 65),
	Vector3.new(43, 0, 63),
	Vector3.new(44, 0, 46),
	Vector3.new(-44, 0, 48),
}
-- Producer click box (wraps trunk, chute and counter) and the billboard spot in front of it
-- (owner R31 / R32): ProducerBillboards.place puts the billboard FrontGap (2.5) past the click
-- box's road-side face at EyeHeight (7.5) above the walkway; the anchor sits on that same spot.
-- The slot in front (z 35.7 .. 36.9, x within ±7.2, y 2 .. 14) is kept free of every visible piece
-- box: the baskets stand at x ±13, the jungle backdrop starts at z 38.5, the arch is at z 18.
local PRODUCER_CLICK = TOWER * CFrame.new(0, 11, -2.6)
local PRODUCER_CLICK_SIZE = Vector3.new(17, 22, 17.2)
local BILLBOARD_Z = PRODUCER_CLICK.Position.Z - PRODUCER_CLICK_SIZE.Z / 2 - 2.5

-- Collision / model helpers for repeated props.
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

-- Base collision: floor, arch posts, palm trunks.
local baseCollision: { CollisionBox } = {
	{ size = Vector3.new(104, 1, 70), cf = at(0, FLOOR - 0.5, 35) }, -- floor (top = FLOOR)
	{ size = Vector3.new(3.2, 15, 3.2), cf = at(-9.2, FLOOR + 7.5, 18) }, -- arch posts
	{ size = Vector3.new(3.2, 15, 3.2), cf = at(9.2, FLOOR + 7.5, 18) },
}
for _, p in PALMS do
	table.insert(baseCollision, { size = Vector3.new(1.4, 10, 1.4), cf = at(p.X, FLOOR + 5, p.Z) })
end

local layout = {
	area = 3,

	-- Built when D3 unlocks: jungle floor, PTERO POST arch, back-row jungle.
	base = {
		models = {
			{ key = "D3_Floor", cf = at(0, 0, 35) },
			{ key = "D3_EntryArch", cf = at(0, FLOOR, 18) },
			{ key = "D3_Jungle", cf = at(0, FLOOR, 0) },
		},
		collision = baseCollision,
	},

	builds = {
		-- First pad (builder): the Nest Tower producer + its two perched couriers.
		D3_NestTower = {
			models = {
				{ key = "D3_NestTower", cf = TOWER },
				{ key = "D3_PteroCourier", cf = COURIERS[1] },
				{ key = "D3_PteroCourier", cf = COURIERS[2] },
			},
			collision = {
				boxOn(TOWER, Vector3.new(6.4, 19, 6.4), Vector3.new(0, 9.5, 0)), -- trunk
				boxOn(TOWER, Vector3.new(10, 3, 2.2), Vector3.new(0, 1.5, -9.6)), -- sorting counter
			},
		},
		D3_RopeBridge = {
			models = { { key = "D3_RopeBridge", cf = LOOKOUT } },
			collision = { boxOn(LOOKOUT, Vector3.new(3.6, 20, 3.6), Vector3.new(0, 10, 0)) }, -- lookout trunk
		},
		D3_ParcelBaskets = {
			models = listModels("D3_ParcelBaskets", BASKETS),
			collision = listCollision(BASKETS, Vector3.new(5.2, 2, 4.4), Vector3.new(0.2, 1, 0.3)),
		},
		D3_WindSock = {
			models = { { key = "D3_WindSock", cf = WIND_SOCK } },
			collision = {
				boxOn(WIND_SOCK, Vector3.new(3, 1.2, 3), Vector3.new(0, 0.6, 0)), -- boulder footing
				boxOn(WIND_SOCK, Vector3.new(0.7, 9, 0.7), Vector3.new(0, 4.5, 0)), -- pole
			},
		},
		D3_PteroFlock = {
			models = { { key = "D3_PteroFlock", cf = FLOCK } },
			collision = {
				boxOn(FLOCK, Vector3.new(1.2, 3.6, 1.2), Vector3.new(-3.9, 1.8, 0)),
				boxOn(FLOCK, Vector3.new(1.2, 3.6, 1.2), Vector3.new(3.9, 1.8, 0)),
			},
		},
		D3_TreasureMap = {
			models = { { key = "D3_TreasureMap", cf = MAP } },
			collision = { boxOn(MAP, Vector3.new(8.4, 7, 1.2), Vector3.new(0, 3.5, 0.1)) },
		},
		D3_LandingPad = {
			models = { { key = "D3_LandingPad", cf = LANDING } },
			collision = {
				-- Two crossing boxes approximate the round deck (top 1.2); the step in front.
				boxOn(LANDING, Vector3.new(14.6, 1.2, 9.4), Vector3.new(0, 0.6, 0)),
				boxOn(LANDING, Vector3.new(9.4, 1.2, 14.6), Vector3.new(0, 0.6, 0)),
				boxOn(LANDING, Vector3.new(3.6, 0.6, 1.3), Vector3.new(0, 0.3, -7.75)),
			},
		},
		D3_CaptainPtera = {
			models = { { key = "D3_CaptainPtera", cf = CAPTAIN } },
			collision = {},
		},
	} :: { [string]: BuildGroup },

	-- BuyPad ground positions (slot-local), alternating either side of the walkway in buy order;
	-- the Unlock pad sits at the far (away-from-hub) end of the row.
	pads = {
		d3_nest_tower = Vector3.new(-11, FLOOR, 9),
		d3_rope_bridge = Vector3.new(11, FLOOR, 9),
		d3_parcel_baskets = Vector3.new(-20, FLOOR, 9),
		d3_wind_sock = Vector3.new(20, FLOOR, 9),
		d3_ptero_flock = Vector3.new(-29, FLOOR, 9),
		d3_treasure_map = Vector3.new(29, FLOOR, 9),
		d3_landing_pad = Vector3.new(-38, FLOOR, 9),
		d3_captain_ptera = Vector3.new(38, FLOOR, 9),
		d3_tap_springs = Vector3.new(-47, FLOOR, 9),
	} :: { [string]: Vector3 },

	-- Billboard anchor at eye level in the clear space in front of the counter; the click box
	-- wraps the whole tree (counter, chute, trunk).
	producer = {
		anchor = Vector3.new(0, FLOOR + 7.5, BILLBOARD_Z),
		click = { size = PRODUCER_CLICK_SIZE, cf = PRODUCER_CLICK },
	},

	-- Teleport target: on the walkway between the pad row and the arch.
	spawnPoint = Vector3.new(0, FLOOR + 3, 13),
}

return layout
