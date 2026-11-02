--!strict
--[[
	Area 8 — Nuke Megastore (spec §3.8).

	Mall storefront with shelves, the mascot "Nukey" and a giant billboard.

	Producer: Megastore Checkout (`p8_checkout`). Pads in their fixed linear buy order; every pad requires the one
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
]]

local TycoonTypes = require(script.Parent.Parent.Parent.Tycoon.TycoonTypes)

-- Cost unit (tuned for the pacing target; see header).
local SCALE = 1.03e12

-- Producer id (SAVE DATA).
local PRODUCER = "p8_checkout"

local area: TycoonTypes.AreaConfig = {
	index = 8,
	id = "nuke_megastore",
	name = "Nuke Megastore",
	producer = {
		id = PRODUCER,
		name = "Megastore Checkout",
		area = 8,
		builtBy = "a8_storefront",
		-- Level 1 -> 2 costs baseCost; each further level costs costGrowth x the previous one.
		baseCost = 3 * SCALE,
		costGrowth = 1.2,
		-- Cash per cycle at level 1 (linear in level) and seconds per cycle before speed-ups.
		baseRevenue = 3.5e10,
		baseCycle = 5,
		clickable = true,
	},
	pads = {
		{
			id = "a8_storefront",
			area = 8,
			name = "Storefront",
			kind = "Build",
			cost = 10 * SCALE,
			requires = "a7_open_megastore",
			target = PRODUCER,
			value = 0,
			build = "A8_Storefront",
			blurb = "Builds the Megastore Checkout!",
		},
		{
			id = "a8_shelves",
			area = 8,
			name = "Shelves",
			kind = "Multiplier",
			cost = 13 * SCALE,
			requires = "a8_storefront",
			target = PRODUCER,
			value = 2,
			build = "A8_Shelves",
			blurb = "x2 Checkout cash",
		},
		{
			id = "a8_escalators",
			area = 8,
			name = "Escalators",
			kind = "Build",
			cost = 22 * SCALE,
			requires = "a8_shelves",
			target = PRODUCER,
			value = 0.1,
			build = "A8_Escalators",
			blurb = "+10% Checkout cash",
		},
		{
			id = "a8_mascot_nukey",
			area = 8,
			name = "Mascot Nukey",
			kind = "Multiplier",
			cost = 230 * SCALE,
			requires = "a8_escalators",
			target = PRODUCER,
			value = 3,
			build = "A8_MascotNukey",
			blurb = "x3 Checkout cash",
		},
		{
			id = "a8_billboard",
			area = 8,
			name = "Billboard",
			kind = "Multiplier",
			cost = 350 * SCALE,
			requires = "a8_mascot_nukey",
			target = PRODUCER,
			value = 2,
			build = "A8_Billboard",
			blurb = "x2 Checkout cash",
		},
		{
			id = "a8_food_court",
			area = 8,
			name = "Food Court",
			kind = "Build",
			cost = 600 * SCALE,
			requires = "a8_billboard",
			target = PRODUCER,
			value = 0.1,
			build = "A8_FoodCourt",
			blurb = "+10% Checkout cash",
		},
		{
			id = "a8_parking_garage",
			area = 8,
			name = "Parking Garage",
			kind = "Speed",
			cost = 3000 * SCALE,
			requires = "a8_food_court",
			target = PRODUCER,
			value = 2,
			build = "A8_ParkingGarage",
			blurb = "x2 Checkout speed",
		},
		{
			id = "a8_store_manager",
			area = 8,
			name = "Store Manager",
			kind = "Manager",
			cost = 6000 * SCALE,
			requires = "a8_parking_garage",
			target = PRODUCER,
			build = "A8_StoreManager",
			blurb = "Automates the Checkout",
		},
		{
			id = "a8_build_space_port",
			area = 8,
			name = "Build the Space Port",
			kind = "Unlock",
			cost = 18000 * SCALE,
			requires = "a8_store_manager",
			unlocks = 9,
			build = "A9_EntryArch",
			blurb = "Opens the Space Port",
		},
	},
}

return area
