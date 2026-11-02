--!strict
--[[
	AreaLayouts/Area08 — slot layout of Area 8 "Nuke Megastore" (spec §3.8).

	Contract: docs/superpowers/plans/2026-10-30-sellnukes-build.md → "World layout", validated by
	src/server/Tycoon/LayoutLogic.luau (tests/area-layouts.luau). Consumed by B5's PlotBuilder: `base`
	is built when the area unlocks (Area 7's Unlock pad key `A8_EntryArch` resolves here),
	`builds[buildKey]` when that pad is bought, pads / producer / spawnPoint at plot build time.
	Area 8's own Unlock pad (`a8_build_space_port`, key `A9_EntryArch`) resolves to Area09.base.
	Meshes: tools/blender/models/area08.py (keys `A8_*`, ids in MeshAssets).

	Frame: SLOT-LOCAL studs. Origin = road-side edge midpoint of the slot, +Z away from the road,
	+Y up, slot x ∈ [-52, 52], z ∈ [0, 70]. Identity rotation = model front (-Z) faces the road.
	The plaza tops out at y = DECK (0.5); everything standing on it sits at y = DECK.
	Area 8 is a RIGHT-side slot: the hub is toward +X, Area 9 (Space Port) further along the road
	toward -X, so the Unlock pad sits at the -X end. Area 7 is directly across the road.

	Scene (top-down, road at the bottom):
		z 42.5-68.5  the store (STORE origin, 48 x 26 footprint): open ground floor with three checkout
		             counters (producer), shelves inside, balcony at y 13.5, roof sign, rooftop billboard
		x -51..-26   food court (z 43-69, giant donut) and mascot Nukey on his pedestal (x -36, z 28)
		x 26..51     three-level parking garage (z 20.5-68.5), entrance toward the road
		x 10.8..20.2 twin escalators from the plaza (z 17.5) up to the balcony (z 38.5)
		z 0-42.5     sky-blue carpet walkway x ∈ [-5.5, 5.5] with lamps; store manager robot at (-10, 37)
		z 3          entry arch (pillars at x = ±7.6)
		z 9          pad row (8 studs apart, each pad in front of what it builds)

	Collision: invisible primitive boxes (meshes never collide). The escalators are walkable ramps
	with balustrade walls; the garage decks and ramps are walkable; the roof and billboard are out of
	reach (billboard legs only).

	Example (B5):
		local layout = require(ReplicatedStorage.Shared.Config.AreaLayouts.Area08)
		for _, placement in layout.base.models do
			MeshLibrary.spawn(placement.key, plotFolder, slotCFrame * placement.cf)
		end
]]

export type ModelPlacement = { key: string, cf: CFrame, castShadow: boolean? }
export type CollisionBox = { size: Vector3, cf: CFrame }
export type BuildGroup = { models: { ModelPlacement }, collision: { CollisionBox } }

-- Plaza top (A8_Plaza); every plaza-standing model is placed at this height.
local DECK = 0.5
-- Store shell heights (A8_Storefront, store-local): first-floor slab 12..13, roof slab 22..23.
local F1 = 12
local F2 = 22

--[[
	Slot-local CFrame helper: position + yaw in degrees (CCW from above, Roblox convention).

	Example: at(-36, DECK, 28) -- Nukey's pedestal centre on the plaza
]]
local function at(x: number, y: number, z: number, yawDeg: number?): CFrame
	return CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yawDeg or 0), 0)
end

--[[
	Collision box anchored to a placed model: `localCentre` is the box centre in the model's own
	frame, so the box follows the model's placement (and yaw, if any).
]]
local function boxOn(model: CFrame, size: Vector3, localCentre: Vector3): CollisionBox
	return { size = size, cf = model * CFrame.new(localCentre) }
end

--[[
	Inclined collision slab whose TOP surface runs along the line `fromLocal` -> `toLocal` (model
	frame), `width` across and `thick` deep (escalators, garage ramps). `lift` raises the slab's
	centre line along the incline normal (used for balustrade / rail walls standing on a ramp).

	Example: incline(STORE, Vector3.new(15.5, 0.3, -35), Vector3.new(15.5, 13, -17.5), 9.4, 1, 0)
]]
local function incline(
	model: CFrame,
	fromLocal: Vector3,
	toLocal: Vector3,
	width: number,
	thick: number,
	lift: number
): CollisionBox
	local a = model * fromLocal
	local b = model * toLocal
	-- Explicit basis (not CFrame.lookAt, whose Lune implementation flips mixed Y/Z targets): local
	-- -Z runs up the incline, local +Y is the incline normal, so the slab's top face is the line.
	local back = (a - b).Unit
	local right = Vector3.new(0, 1, 0):Cross(back).Unit
	local up = back:Cross(right)
	local frame = CFrame.fromMatrix((a + b) / 2, right, up, back) * CFrame.new(0, lift - thick / 2, 0)
	return { size = Vector3.new(width, thick, (b - a).Magnitude), cf = frame }
end

-- Placements (shared by models, collision and the producer).
local ORIGIN = CFrame.new()
local ARCH = at(0, DECK, 3)
local STORE = at(0, DECK, 55.5)
local NUKEY = at(-36, DECK, 28)
local FOOD_COURT = at(-38.5, DECK, 56)
local GARAGE = at(38.5, DECK, 44.5)
local MANAGER = at(-10, DECK, 37)

-- Store shell: side + back walls, ground-floor facade pieces, slabs, balcony railing, counters.
local function storefrontCollision(): { CollisionBox }
	local boxes = {
		boxOn(STORE, Vector3.new(46, F2 + 1, 1), Vector3.new(0, (F2 + 1) / 2, 12.5)),
		boxOn(STORE, Vector3.new(48, 1, 30), Vector3.new(0, F1 + 0.5, -2)), -- first floor + balcony
		boxOn(STORE, Vector3.new(48, 1, 26), Vector3.new(0, F2 + 0.5, 0)), -- roof
		boxOn(STORE, Vector3.new(46, F2 - F1 - 1, 1), Vector3.new(0, (F1 + 1 + F2) / 2, -12.5)), -- upper glass
		boxOn(STORE, Vector3.new(34.3, 1.5, 0.3), Vector3.new(-6.65, F1 + 1.75, -16.7)), -- railing (left of gap)
		boxOn(STORE, Vector3.new(3.3, 1.5, 0.3), Vector3.new(22.15, F1 + 1.75, -16.7)), -- railing (right of gap)
		boxOn(STORE, Vector3.new(30, 5.2, 0.9), Vector3.new(0, F2 + 4.6, -12.8)), -- roof sign
	}
	for _, s in { -1, 1 } do
		table.insert(boxes, boxOn(STORE, Vector3.new(1, F2 + 1, 26), Vector3.new(s * 23.5, (F2 + 1) / 2, 0)))
		table.insert(boxes, boxOn(STORE, Vector3.new(8.4, F1, 1), Vector3.new(s * 18.8, F1 / 2, -12.5)))
		table.insert(boxes, boxOn(STORE, Vector3.new(1.6, F1, 1.6), Vector3.new(s * 13.8, F1 / 2, -12.7)))
		table.insert(boxes, boxOn(STORE, Vector3.new(0.3, 1.5, 3.7), Vector3.new(s * 23.8, F1 + 1.75, -14.85)))
	end
	for _, cx in { -9, 0, 9 } do
		table.insert(boxes, boxOn(STORE, Vector3.new(6.3, 3.3, 2.5), Vector3.new(cx, 1.65, -6)))
	end
	return boxes
end

-- Escalators: one walkable incline over both lanes, balustrade walls, landing plate, column.
local function escalatorCollision(): { CollisionBox }
	local bottom, top = Vector3.new(15.5, 0.3, -35), Vector3.new(15.5, F1 + 1, -17.5)
	local boxes = {
		incline(STORE, bottom, top, 9.4, 1, 0),
		boxOn(STORE, Vector3.new(9.4, 0.3, 3), Vector3.new(15.5, 0.15, -36.5)),
		boxOn(STORE, Vector3.new(1.8, 8.36, 1.8), Vector3.new(15.5, 4.18, -21)),
	}
	-- Outer balustrades (x 11.05 / 19.95) and the shared middle divider (x 15.5), 2.6 tall.
	for _, x in { 11.05, 19.95 } do
		local offset = Vector3.new(x - 15.5, 0, 0)
		table.insert(boxes, incline(STORE, bottom + offset, top + offset, 0.3, 2.6, 2.6))
	end
	table.insert(boxes, incline(STORE, bottom, top, 1.4, 2.6, 2.6))
	return boxes
end

-- Parking garage: decks, ramps (+ outer rails), columns, parapets, well railings, cars, booth.
local function garageCollision(): { CollisionBox }
	local L1, ROOF = 6.8, 13.8
	local boxes = {
		-- L1 deck pieces (top 6.8): main, left-front, left-back landing, side ledge over ramp A.
		boxOn(GARAGE, Vector3.new(17, 0.8, 48), Vector3.new(3.5, L1 - 0.4, 0)),
		boxOn(GARAGE, Vector3.new(7, 0.8, 26), Vector3.new(-8.5, L1 - 0.4, -11)),
		boxOn(GARAGE, Vector3.new(7, 0.8, 2), Vector3.new(-8.5, L1 - 0.4, 23)),
		boxOn(GARAGE, Vector3.new(1.4, 0.8, 20), Vector3.new(-11.3, L1 - 0.4, 12)),
		-- Roof deck pieces (top 13.8): main + right-front.
		boxOn(GARAGE, Vector3.new(17, 0.8, 48), Vector3.new(-3.5, ROOF - 0.4, 0)),
		boxOn(GARAGE, Vector3.new(7, 0.8, 26), Vector3.new(8.5, ROOF - 0.4, -11)),
		-- Ramps A (ground -> L1) and B (L1 -> roof) + their outer hand rails.
		incline(GARAGE, Vector3.new(-7.8, 0, 2), Vector3.new(-7.8, L1, 22), 5.6, 0.6, 0),
		incline(GARAGE, Vector3.new(7.8, L1, 22), Vector3.new(7.8, ROOF, 2), 5.6, 0.6, 0),
		incline(GARAGE, Vector3.new(-10.45, 0, 2), Vector3.new(-10.45, L1, 22), 0.3, 1.4, 1.4),
		incline(GARAGE, Vector3.new(10.45, L1, 22), Vector3.new(10.45, ROOF, 2), 0.3, 1.4, 1.4),
		-- Parapets (1.2 tall incl. cap).
		boxOn(GARAGE, Vector3.new(24, 1.2, 0.6), Vector3.new(0, L1 + 0.6, -23.7)),
		boxOn(GARAGE, Vector3.new(24, 1.2, 0.6), Vector3.new(0, L1 + 0.6, 23.7)),
		boxOn(GARAGE, Vector3.new(0.6, 1.2, 48), Vector3.new(-11.7, L1 + 0.6, 0)),
		boxOn(GARAGE, Vector3.new(0.6, 1.2, 48), Vector3.new(11.7, L1 + 0.6, 0)),
		boxOn(GARAGE, Vector3.new(24, 1.2, 0.6), Vector3.new(0, ROOF + 0.6, -23.7)),
		boxOn(GARAGE, Vector3.new(17, 1.2, 0.6), Vector3.new(-3.5, ROOF + 0.6, 23.7)),
		boxOn(GARAGE, Vector3.new(0.6, 1.2, 48), Vector3.new(-11.7, ROOF + 0.6, 0)),
		boxOn(GARAGE, Vector3.new(0.6, 1.2, 26), Vector3.new(11.7, ROOF + 0.6, -11)),
		-- Railings along the ramp wells.
		boxOn(GARAGE, Vector3.new(0.3, 1.3, 20), Vector3.new(-5, L1 + 0.65, 12)),
		boxOn(GARAGE, Vector3.new(6.4, 1.3, 0.3), Vector3.new(-8.2, L1 + 0.65, 2)),
		boxOn(GARAGE, Vector3.new(0.3, 1.3, 21.4), Vector3.new(5, ROOF + 0.65, 12.7)),
		-- Ticket booth.
		boxOn(GARAGE, Vector3.new(2.2, 3.4, 2.2), Vector3.new(-2.6, 1.7, -21.5)),
	}
	for _, sx in { -1, 1 } do
		for _, z in { -23.4, -12, 0, 12, 23.4 } do
			table.insert(boxes, boxOn(GARAGE, Vector3.new(1, ROOF, 1), Vector3.new(sx * 11.4, ROOF / 2, z)))
		end
	end
	for _, p in { { -4.6, 2 }, { -4.6, 22 }, { 4.6, 2 }, { 4.6, 22 } } do
		table.insert(boxes, boxOn(GARAGE, Vector3.new(1, ROOF, 1), Vector3.new(p[1], ROOF / 2, p[2])))
	end
	-- Toy cars (x, deck top, z, yaw) as in area08.py build_parking_garage. The ground-floor car at
	-- (6.8, -7) is the shopper car that drives in / out (owner R56, A8_ShopperCar): no box.
	for _, car in
		{
			{ 6.8, 0.08, -19, 90 },
			{ -7.8, L1, -13, -90 },
			{ -7.8, L1, -1, -90 },
			{ -6.5, ROOF, -13, -90 },
			{ -6.5, ROOF, 10, 180 },
		}
	do
		local carFrame = GARAGE * at(car[1], car[2], car[3], car[4])
		table.insert(boxes, boxOn(carFrame, Vector3.new(3.8, 3.4, 7), Vector3.new(0, 1.8, 0)))
	end
	return boxes
end

-- Food court: kiosk, four table clusters (table + stools), trash bin.
local function foodCourtCollision(): { CollisionBox }
	local boxes = {
		boxOn(FOOD_COURT, Vector3.new(18.8, 9.2, 6), Vector3.new(0, 4.6, 10)),
		boxOn(FOOD_COURT, Vector3.new(1.8, 2.7, 1.8), Vector3.new(10.4, 1.35, 5.2)),
	}
	for _, t in { { -6.2, -6.5 }, { 6.2, -6.5 }, { -6.2, 0.8 }, { 6.2, 0.8 } } do
		table.insert(boxes, boxOn(FOOD_COURT, Vector3.new(5.4, 2.9, 5.4), Vector3.new(t[1], 1.45, t[2])))
	end
	return boxes
end

local layout = {
	area = 8,
	base = {
		models = {
			-- Flat plates skip shadows (wasted on a plane; shared art convention).
			{ key = "A8_Plaza", cf = ORIGIN, castShadow = false },
			{ key = "A8_EntryArch", cf = ARCH },
		},
		collision = {
			-- Plaza slab (y -0.2 .. 0.5) and the back / side curbs (top y 1.0).
			{ size = Vector3.new(104, 0.7, 70), cf = CFrame.new(0, 0.15, 35) },
			{ size = Vector3.new(104, 0.7, 1.2), cf = CFrame.new(0, 0.65, 69.4) },
			{ size = Vector3.new(1.2, 0.7, 68.8), cf = CFrame.new(-51.4, 0.65, 34.4) },
			{ size = Vector3.new(1.2, 0.7, 68.8), cf = CFrame.new(51.4, 0.65, 34.4) },
			-- Arch: plinths + candy pillars, beam, lettered sign.
			boxOn(ARCH, Vector3.new(3.4, 15.8, 3.4), Vector3.new(-7.6, 7.9, 0)),
			boxOn(ARCH, Vector3.new(3.4, 15.8, 3.4), Vector3.new(7.6, 7.9, 0)),
			boxOn(ARCH, Vector3.new(19.6, 1.8, 2.2), Vector3.new(0, 16.6, 0)),
			boxOn(ARCH, Vector3.new(16, 5.8, 0.7), Vector3.new(0, 20.4, -0.3)), -- lettered sign
			-- Lamp posts along the walkway and the two corner planters (+ tree trunks).
			{ size = Vector3.new(0.6, 7, 0.6), cf = CFrame.new(-8.5, DECK + 3.5, 22) },
			{ size = Vector3.new(0.6, 7, 0.6), cf = CFrame.new(8.5, DECK + 3.5, 22) },
			{ size = Vector3.new(0.6, 7, 0.6), cf = CFrame.new(-8.5, DECK + 3.5, 34) },
			{ size = Vector3.new(0.6, 7, 0.6), cf = CFrame.new(8.5, DECK + 3.5, 34) },
			{ size = Vector3.new(4, 4.2, 4), cf = CFrame.new(-48, DECK + 2.1, 17) },
			{ size = Vector3.new(4, 4.2, 4), cf = CFrame.new(48, DECK + 2.1, 17) },
		},
	},
	builds = {
		-- First pad: the store shell + the producer "Megastore Checkout" (three counters).
		A8_Storefront = {
			models = { { key = "A8_Storefront", cf = STORE } },
			collision = storefrontCollision(),
		},
		A8_Shelves = {
			models = { { key = "A8_Shelves", cf = STORE } },
			collision = {
				boxOn(STORE, Vector3.new(15, 6.8, 2.6), Vector3.new(-9.5, 3.4, 1.5)),
				boxOn(STORE, Vector3.new(15, 6.8, 2.6), Vector3.new(9.5, 3.4, 1.5)),
				boxOn(STORE, Vector3.new(15, 6.8, 2.6), Vector3.new(-9.5, 3.4, 7.5)),
				boxOn(STORE, Vector3.new(15, 6.8, 2.6), Vector3.new(9.5, 3.4, 7.5)),
			},
		},
		A8_Escalators = {
			models = { { key = "A8_Escalators", cf = STORE } },
			collision = escalatorCollision(),
		},
		A8_MascotNukey = {
			models = { { key = "A8_MascotNukey", cf = NUKEY } },
			collision = {
				-- Octagonal pedestal (two crossed squares, apothem 6.2) + Nukey's body.
				boxOn(NUKEY, Vector3.new(12.4, 3, 12.4), Vector3.new(0, 1.5, 0)),
				{
					size = Vector3.new(12.4, 3, 12.4),
					cf = NUKEY * CFrame.new(0, 1.5, 0) * CFrame.Angles(0, math.rad(45), 0),
				},
				boxOn(NUKEY, Vector3.new(8, 18, 8), Vector3.new(0, 12, 0)),
			},
		},
		A8_Billboard = {
			models = { { key = "A8_Billboard", cf = STORE } },
			collision = {
				boxOn(STORE, Vector3.new(1, 7, 1), Vector3.new(-12, F2 + 4.5, 5.3)),
				boxOn(STORE, Vector3.new(1, 7, 1), Vector3.new(0, F2 + 4.5, 5.3)),
				boxOn(STORE, Vector3.new(1, 7, 1), Vector3.new(12, F2 + 4.5, 5.3)),
			},
		},
		A8_FoodCourt = {
			models = { { key = "A8_FoodCourt", cf = FOOD_COURT } },
			collision = foodCourtCollision(),
		},
		A8_ParkingGarage = {
			models = {
				{ key = "A8_ParkingGarage", cf = GARAGE },
				-- Shopper car (owner R56, VehicleRouteConfig "A8_ShopperCar"): parked nose-in (+X) in
				-- its ground-floor bay; it drives in past the lifting barrier, shops, backs out, leaves.
				{ key = "A8_ShopperCar", cf = GARAGE * at(6.8, 0.08, -7, -90) },
			},
			collision = garageCollision(),
		},
		A8_StoreManager = {
			models = { { key = "A8_StoreManager", cf = MANAGER } },
			collision = { boxOn(MANAGER, Vector3.new(4, 8, 3), Vector3.new(0, 4, -0.3)) },
		},
	},
	-- BuyPad ground positions (pad row z = 9, 8 studs apart, clear of the arch pillars).
	pads = {
		a8_storefront = Vector3.new(-13.5, DECK, 9),
		a8_shelves = Vector3.new(13.5, DECK, 9),
		a8_escalators = Vector3.new(21.5, DECK, 9),
		a8_mascot_nukey = Vector3.new(-29.5, DECK, 9),
		a8_billboard = Vector3.new(-21.5, DECK, 9),
		a8_food_court = Vector3.new(-37.5, DECK, 9),
		a8_parking_garage = Vector3.new(37.5, DECK, 9),
		a8_store_manager = Vector3.new(29.5, DECK, 9),
		a8_build_space_port = Vector3.new(-45.5, DECK, 9),
	},
	-- Producer billboard (owner R31 / R32, tests/billboard-clearance.luau). The client puts it
	-- FrontGap (2.5) in front of the click box at eye level, then nudges forward while any visible
	-- piece's BOUNDING BOX overlaps it. Inside the store every shell piece's box (Walls, Accent,
	-- Trim, Counter, Glass) covers the counters, so the click box runs from the three checkout
	-- counters (store-local z -4.5) out under the entrance canopy (z -15.6, slot z 39.9): the
	-- billboard lands on the carpet right outside the entrance (slot z 37.4), clear of the
	-- storefront's front-most box (slot z 38.1) and the plaza lamps (z <= 34.6), at eye level
	-- clamped to the click box top (6 above the carpet). Anchor = that spot.
	producer = {
		anchor = Vector3.new(0, DECK + 6.08, 37.4),
		click = { size = Vector3.new(26, 4, 11.1), cf = STORE * CFrame.new(0, 2, -10.05) },
	},
	spawnPoint = Vector3.new(0, DECK + 3, 20),
}

return layout
