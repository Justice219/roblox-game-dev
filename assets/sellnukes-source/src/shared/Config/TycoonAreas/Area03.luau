--!strict
--[[
	Area 3 — BoomDash Delivery (spec §3.3).

	Delivery-app HQ with scooters zipping along a lane.

	Producer: BoomDash Orders (`p3_boomdash`). Pads in their fixed linear buy order; every pad requires the one
	before it (the first pad requires the previous area's Unlock pad), so `requires` forms one chain
	across the whole game. TycoonConfig validates the chain at load.

	SAVE DATA: every pad `id` and the producer `id` are stored in profiles. Never rename or reuse them.
	`build` is the build-group key the world builders map to Blender meshes.

	Costs are multiples of SCALE, this area's cost unit (a few seconds of the income the player has
	when the area opens). Pads sit on the producer's level-cost curve (price = weight x L x 3 x
	costGrowth^(L-1) SCALE units at a designated level L), so a greedy player buys them in between
	upgrades; the Unlock pad costs 3x the pad before it. SCALE (pace) and baseRevenue (level-1
	producer = 1 % of arrival income) are written by the pacing simulator:
	`lune run tests/economy-sim.luau --tune --write`. TycoonConfig rounds each price to 2
	significant digits at load. Formulas and retuning: docs/economy.md.

	Owner R130 (2026-11-01) — the Dispatcher (Manager) is pad 4: live first-run data showed the
	BoomDash hand-clicked for ~13 min (Dispatcher was pad 8, after a 6:20 wait) and an 8.3x price
	jump to the Mobile App; 41 players opened this area and 4 reached the next. New buy order:
	HQ Shell -> Scooter Rack -> Scooters -> Dispatcher -> GPS -> Mobile App -> Delivery Van ->
	Parking Lot -> Dig the Mine. The multiples below are shaped by hand (like R122's Garage Lab)
	with the pacing sim: Dispatcher hired ~1.6 min after the area opens, the later pads ~4 min
	apart (longest wait ~4.4 min, was 6.7), area length unchanged (~22 min sim), SCALE raised
	22100 -> 25000 to hold that length with the smoother steps. Asserted by tests/economy-sim.luau
	OPENING_CHECKS (area 3). Pad ids unchanged: saves bought in the old order keep every pad
	(tests/boomdash-order.luau; docs/tycoon-server.md "BoomDash order").
]]

local TycoonTypes = require(script.Parent.Parent.Parent.Tycoon.TycoonTypes)

-- Cost unit (tuned for the pacing target; see header; owner R130 hand-paced 25000).
local SCALE = 25000

-- Producer id (SAVE DATA).
local PRODUCER = "p3_boomdash"

local area: TycoonTypes.AreaConfig = {
	index = 3,
	id = "boomdash",
	name = "BoomDash Delivery",
	producer = {
		id = PRODUCER,
		name = "BoomDash Orders",
		area = 3,
		builtBy = "a3_hq_shell",
		-- Level 1 -> 2 costs baseCost; each further level costs costGrowth x the previous one.
		baseCost = 3 * SCALE,
		costGrowth = 1.2,
		-- Cash per cycle at level 1 (linear in level) and seconds per cycle before speed-ups.
		baseRevenue = 760,
		baseCycle = 2,
		clickable = true,
	},
	pads = {
		{
			id = "a3_hq_shell",
			area = 3,
			name = "HQ Shell",
			kind = "Build",
			cost = 10 * SCALE,
			requires = "a2_start_boomdash",
			target = PRODUCER,
			value = 0,
			build = "A3_HQShell",
			blurb = "Builds the BoomDash Orders!",
		},
		{
			id = "a3_scooter_rack",
			area = 3,
			name = "Scooter Rack",
			kind = "Build",
			cost = 12 * SCALE,
			requires = "a3_hq_shell",
			target = PRODUCER,
			value = 0.1,
			build = "A3_ScooterRack",
			blurb = "+10% BoomDash cash",
		},
		{
			id = "a3_scooters",
			area = 3,
			name = "Scooters",
			kind = "Multiplier",
			cost = 45 * SCALE,
			requires = "a3_scooter_rack",
			target = PRODUCER,
			value = 2,
			build = "A3_Scooters",
			blurb = "x2 BoomDash cash",
		},
		{
			-- Owner R130: the Manager comes right after the first burst (was pad 8 at 6000 x SCALE).
			id = "a3_dispatcher",
			area = 3,
			name = "Dispatcher",
			kind = "Manager",
			cost = 70 * SCALE,
			requires = "a3_scooters",
			target = PRODUCER,
			build = "A3_Dispatcher",
			blurb = "Automates the BoomDash",
		},
		{
			id = "a3_gps",
			area = 3,
			name = "GPS",
			kind = "Speed",
			cost = 340 * SCALE,
			requires = "a3_dispatcher",
			target = PRODUCER,
			value = 2,
			build = "A3_GPS",
			blurb = "x2 BoomDash speed",
		},
		{
			id = "a3_mobile_app",
			area = 3,
			name = "Mobile App",
			kind = "Multiplier",
			cost = 650 * SCALE,
			requires = "a3_gps",
			target = PRODUCER,
			value = 4,
			build = "A3_MobileApp",
			blurb = "x4 BoomDash cash",
		},
		{
			id = "a3_delivery_van",
			area = 3,
			name = "Delivery Van",
			kind = "Multiplier",
			cost = 2000 * SCALE,
			requires = "a3_mobile_app",
			target = PRODUCER,
			value = 3,
			build = "A3_DeliveryVan",
			blurb = "x3 BoomDash cash",
		},
		{
			id = "a3_parking_lot",
			area = 3,
			name = "Parking Lot",
			kind = "Build",
			cost = 6000 * SCALE,
			requires = "a3_delivery_van",
			target = PRODUCER,
			value = 0.1,
			build = "A3_ParkingLot",
			blurb = "+10% BoomDash cash",
		},
		{
			id = "a3_dig_mine",
			area = 3,
			name = "Dig the Mine",
			kind = "Unlock",
			cost = 18000 * SCALE,
			requires = "a3_parking_lot",
			unlocks = 4,
			build = "A4_EntryArch",
			blurb = "Opens the Glow Rock Mine",
		},
	},
}

return area
