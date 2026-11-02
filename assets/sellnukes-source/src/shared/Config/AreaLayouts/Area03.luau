--!strict
--[[
	AreaLayouts/Area03 — slot layout of Area 3 "BoomDash Delivery" (spec §3.3).

	Contract: docs/superpowers/plans/2026-10-30-sellnukes-build.md → "World layout", validated by
	src/server/Tycoon/LayoutLogic.luau (tests/area-layouts.luau). Consumed by B5's PlotBuilder:
	`base` is built when Area 3 unlocks (Area 2's Unlock pad key `A3_EntryArch` resolves here),
	`builds[buildKey]` when that pad is bought, pads / producer / spawnPoint at plot build time.
	The Unlock pad's key `A4_EntryArch` is NOT here: it resolves to Area04.base.

	Meshes: tools/blender/models/area03.py (A3_*). BoomDash is an original parody brand (orange +
	yellow comic starburst) — no real logos. Art notes: docs/areas-art.md → "Area 3".

	Frame: SLOT-LOCAL studs. Origin = road-side edge midpoint, +Z away from the road, +Y up,
	x ∈ [-52, 52], z ∈ [0, 70]. Identity rotation = model front (-Z) faces the road.
	The paved lot (A3_Lot) is a 0.5-stud plate (y = LOT); the lane surface is LANE_Y = 0.56.

	Scene (top-down, road at the bottom):
		z 46-62  BoomDash HQ (32 x 16 x 12), pickup window at x = 0; phone + GPS mast on the roof
		z 19-41  scooter lane loop (stadium) around a grass island with a star flower bed
		x -52..-35  scooter rack with an orange shelter (z 33-40)
		x  35..51   parking pad: the van (z 24-35), stall lines + loading zone (Parking Lot pad)
		z 4      BOOMDASH entry arch (clear width 15)
		z 10     pad row: buy order alternates either side of the arch, moving outward

	Extra top-level field (LayoutLogic passes unknown fields through):
		lane = { center, halfLength, radius, width, scooterKey } — the scooter loop for the
		"scooters zipping along a lane" FX (B4/B6): a stadium around `center` (slot-local, y = lane
		surface) with straights of ±halfLength along X at z = center.Z ± radius (centre line) and
		semicircular ends of `radius`. Travel direction used by the parked lane scooters: +X along
		the front straight (z = center.Z - radius), -X along the back straight.

	Example (B5):
		local layout = require(ReplicatedStorage.Shared.Config.AreaLayouts.Area03)
		for _, placement in layout.builds.A3_Scooters.models do
			MeshLibrary.spawn(placement.key, folder, slotCFrame * placement.cf)
		end
]]

export type ModelPlacement = { key: string, cf: CFrame, tint: Color3?, castShadow: boolean?, collide: boolean? }
export type CollisionBox = { size: Vector3, cf: CFrame }
export type BuildGroup = { models: { ModelPlacement }, collision: { CollisionBox } }

-- Paved lot top (A3_Lot) and the lane surface on top of it.
local LOT = 0.5
local LANE_Y = 0.56
-- HQ roof top above the HQ pivot (A3_HQ roof slab).
local ROOF = 12.1

--[[
	Slot-local CFrame from a position + yaw in degrees (CCW seen from above, Roblox convention).
	yaw 90 turns a model's front (-Z) toward -X; yaw -90 toward +X; 180 toward +Z.

	Example: at(-8, LANE_Y, 21, -90) -- a scooter riding +X along the lane's front straight
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
local HQ = at(0, LOT, 54) -- facade (front, -Z) at z = 46
local RACK = at(-43.5, LOT, 36) -- slots along X at rack-local x = -4.8, -1.6, 1.6, 4.8
local VAN = at(39.45, LANE_Y, 29.4) -- in the first parking stall, cab toward the road
local DISPATCH = at(-11, LOT, 43) -- dispatcher + desk (desk at his +X), between the lane (z <= 41.25) and the HQ
local ARCH = at(0, LOT, 4)
local BASE_LAMPS = { at(-20, LOT, 17.6), at(20, LOT, 17.6), at(-24, LOT, 43.6), at(24, LOT, 43.6) }
local PARKING_LAMPS = { at(35, LOT, 19), at(51, LOT, 19) }
-- Scooters: three nose-in in the rack (yaw 180, front wheel in the U-loop) + three on the lane.
local SCOOTERS = {
	RACK * at(-4.8, 0.12, 0.65, 180),
	RACK * at(-1.6, 0.12, 0.65, 180),
	RACK * at(1.6, 0.12, 0.65, 180),
	at(-8, LANE_Y, 21, -90), -- front straight, riding +X
	at(31, LANE_Y, 30, 180), -- right bend, riding +Z
	at(12, LANE_Y, 39, 90), -- back straight, riding -X
}
-- Yard trees (A3_Yard, slot-origin pivot): {x, y, z, height}; lollipop trunk = 45 % of the height.
local TREES = {
	{ -46, LOT, 62, 9 },
	{ -36, LOT, 65, 8 },
	{ 46, LOT, 62, 9 },
	{ -24, LOT + 0.14, 30, 7 },
	{ 24, LOT + 0.14, 30, 7 },
}

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

local LAMP_POST = Vector3.new(0.6, 6.0, 0.6)

local baseModels: { ModelPlacement } = {
	{ key = "A3_Lot", cf = CFrame.identity, castShadow = false },
	{ key = "A3_Yard", cf = CFrame.identity },
	{ key = "A3_EntryArch", cf = ARCH },
}
for _, model in listModels("A3_Lamp", BASE_LAMPS) do
	table.insert(baseModels, model)
end

local baseCollision: { CollisionBox } = {
	{ size = Vector3.new(104, LOT, 70), cf = at(0, LOT / 2, 35) }, -- paved lot (top = LOT)
	boxOn(ARCH, Vector3.new(4, 10, 4), Vector3.new(9, 5, 0)), -- arch posts
	boxOn(ARCH, Vector3.new(4, 10, 4), Vector3.new(-9, 5, 0)),
}
for _, tree in TREES do
	local h = tree[4] * 0.45
	table.insert(baseCollision, { size = Vector3.new(1.2, h, 1.2), cf = at(tree[1], tree[2] + h / 2, tree[3]) })
end
for _, box in listCollision(BASE_LAMPS, LAMP_POST, Vector3.new(0, 3, 0)) do
	table.insert(baseCollision, box)
end

local parkingCollision = listCollision(PARKING_LAMPS, LAMP_POST, Vector3.new(0, 3, 0))
table.insert(parkingCollision, { size = Vector3.new(0.4, 8.7, 0.4), cf = at(51, LOT + 4.35, 42.5) }) -- P sign pole

local parkingModels: { ModelPlacement } = { { key = "A3_ParkingLot", cf = CFrame.identity, castShadow = false } }
for _, model in listModels("A3_Lamp", PARKING_LAMPS) do
	table.insert(parkingModels, model)
end

local layout = {
	area = 3,
	-- Built when Area 3 unlocks: paved lot with the lane loop + island + parking pad, the arch,
	-- the island flowers / trees and four lane lamps.
	base = {
		models = baseModels,
		collision = baseCollision,
	} :: BuildGroup,
	builds = {
		-- Pad 1: the producer — BoomDash HQ with its pickup window.
		A3_HQShell = {
			models = { { key = "A3_HQ", cf = HQ } },
			collision = {
				boxOn(HQ, Vector3.new(32.8, 0.5, 16.8), Vector3.new(0, 0.25, 0)), -- plinth
				boxOn(HQ, Vector3.new(32, 12.2, 1.4), Vector3.new(0, 6.1, -7.4)), -- facade
				boxOn(HQ, Vector3.new(32, 12.2, 1.0), Vector3.new(0, 6.1, 7.5)), -- back wall
				boxOn(HQ, Vector3.new(1.0, 12.2, 16), Vector3.new(15.5, 6.1, 0)), -- side walls
				boxOn(HQ, Vector3.new(1.0, 12.2, 16), Vector3.new(-15.5, 6.1, 0)),
				boxOn(HQ, Vector3.new(9.6, 3.4, 2.4), Vector3.new(0, 1.7, -8.2)), -- pickup counter
			},
		},
		A3_ScooterRack = {
			models = { { key = "A3_ScooterRack", cf = RACK } },
			collision = {
				boxOn(RACK, Vector3.new(1.4, 3.2, 1.2), Vector3.new(7.2, 1.6, 1.0)), -- charge kiosk
				boxOn(RACK, Vector3.new(13.2, 1.6, 0.4), Vector3.new(0, 0.8, 2.2)), -- U-loop rail
				boxOn(RACK, Vector3.new(0.4, 6.8, 0.4), Vector3.new(-7.4, 3.4, -1.6)), -- shelter posts
				boxOn(RACK, Vector3.new(0.4, 6.8, 0.4), Vector3.new(7.4, 3.4, -1.6)),
				boxOn(RACK, Vector3.new(0.4, 6.8, 0.4), Vector3.new(-7.4, 3.4, 3.4)),
				boxOn(RACK, Vector3.new(0.4, 6.8, 0.4), Vector3.new(7.4, 3.4, 3.4)),
			},
		},
		-- Six scooters (walk-through on purpose: the lane ones are FX candidates).
		A3_Scooters = {
			models = listModels("A3_Scooter", SCOOTERS),
			collision = {},
		},
		-- Roof-mounted upgrades (out of reach: no collision).
		A3_GPS = {
			models = { { key = "A3_GPSBeacon", cf = HQ * CFrame.new(10, ROOF - 0.1, 3) } },
			collision = {},
		},
		A3_MobileApp = {
			models = { { key = "A3_AppPhone", cf = HQ * CFrame.new(-9, ROOF, 3) } },
			collision = {},
		},
		-- The van DRIVES (owner R56, Client/Tycoon/Fx/VehicleRoutes + VehicleRouteConfig "A3_Van"):
		-- walk-through, no collision box (a box would stay behind while it is out delivering).
		A3_DeliveryVan = {
			models = { { key = "A3_DeliveryVan", cf = VAN } },
			collision = {},
		},
		A3_ParkingLot = {
			models = parkingModels,
			collision = parkingCollision,
		},
		-- Manager: the Dispatcher at his desk beside the pickup window.
		A3_Dispatcher = {
			models = { { key = "A3_Dispatcher", cf = DISPATCH, collide = true } },
			collision = {},
		},
	} :: { [string]: BuildGroup },
	-- BuyPad ground positions: alternate either side of the arch in buy order, moving outward;
	-- the Unlock pad (Dig the Mine) at the hub-side end of the row.
	pads = {
		a3_hq_shell = Vector3.new(-16, LOT, 10),
		a3_scooter_rack = Vector3.new(16, LOT, 10),
		a3_scooters = Vector3.new(-24, LOT, 10),
		-- Owner R130: the Dispatcher is pad 4 now (TycoonAreas/Area03), so it takes the 4th spot
		-- (+24) and GPS .. Parking Lot move one spot outward; the next pad is still always the
		-- closest unbought one across the arch.
		a3_dispatcher = Vector3.new(24, LOT, 10),
		a3_gps = Vector3.new(-32, LOT, 10),
		a3_mobile_app = Vector3.new(32, LOT, 10),
		a3_delivery_van = Vector3.new(-40, LOT, 10),
		a3_parking_lot = Vector3.new(40, LOT, 10),
		a3_dig_mine = Vector3.new(-48, LOT, 10),
	} :: { [string]: Vector3 },
	-- The click box wraps the counter + window. The anchor is where the client puts the billboard
	-- (ProducerBillboards.place, owner R31/R32): 2.5 in front of the click box's front face
	-- (z 43.2), 6.4 above the lane edge (y LOT + 0.1) = the click box's top, under the 7.5 eye height.
	producer = {
		anchor = Vector3.new(0, LOT + 6.5, 40.7),
		click = { size = Vector3.new(10.4, 6.0, 4.4), cf = HQ * CFrame.new(0, 3.5, -8.6) },
	},
	-- Teleport target (ground level, in front of the arch).
	spawnPoint = Vector3.new(0, LOT, 12),
	-- Scooter lane loop for FX (see header).
	lane = {
		center = Vector3.new(0, LANE_Y, 30),
		halfLength = 22,
		radius = 9,
		width = 4.5,
		scooterKey = "A3_Scooter",
	},
}

return layout
