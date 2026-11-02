--!strict
--[[
	Dino Valley area 3 — Ptero Post (World 2 spec §6.2).

	A treetop nest tower where friendly pterosaurs fly parcels of toy nukes in and out, with a rope bridge and a
	landing pad. Captain Ptera takes over the deliveries.

	Producer: Ptero Express (`dp3_ptero_express`). Pads in their fixed linear buy order; every pad requires the one
	before it (the first pad requires the previous Dino area's Unlock pad), so `requires` forms one chain
	across the whole Dino Valley tycoon. EconomyIndex validates the chain and the id rules at load:
	pads d<area>_name, producers dp<area>_name, build keys D<area>_Name (an Unlock pad builds the NEXT
	area's D<area+1>_EntryArch, which resolves to Worlds/Dino/Layouts/Area<area+1>.base).

	SAVE DATA: every pad `id` and the producer `id` are stored in profile.worlds.dino. Never rename or reuse
	them. `build` is the build-group key the Dino area art builders map to Blender meshes.

	Costs are multiples of SCALE, this area's cost unit, priced exactly like Nuke Town (docs/economy.md
	"Pricing structure"): builder pad = 10 x SCALE, the other pads on the producer's level-cost curve
	(weight x L x 3 x 1.2^(L-1) SCALE units at a designated level L, forced to rise >= 15 % along the chain),
	the Unlock pad = 3x the pad before it. SCALE (pace) and baseRevenue (level-1 producer = 1 % of arrival
	income) are written by the pacing simulator:
	`lune run tests/economy-sim.luau --world dino --tune --write`. EconomyIndex rounds each price to 2
	significant digits at load. Formulas, pacing table and retuning: docs/economy.md ("Dino Valley").
]]

local TycoonTypes = require(script.Parent.Parent.Parent.Parent.Parent.Tycoon.TycoonTypes)

-- Cost unit (tuned for the pacing target; see header).
local SCALE = 11400

-- Producer id (SAVE DATA).
local PRODUCER = "dp3_ptero_express"

local area: TycoonTypes.AreaConfig = {
	index = 3,
	id = "ptero_post",
	name = "Ptero Post",
	producer = {
		id = PRODUCER,
		name = "Ptero Express",
		area = 3,
		builtBy = "d3_nest_tower",
		-- Level 1 -> 2 costs baseCost; each further level costs costGrowth x the previous one.
		baseCost = 3 * SCALE,
		costGrowth = 1.2,
		-- Bones per cycle at level 1 (linear in level) and seconds per cycle before speed-ups.
		baseRevenue = 450,
		baseCycle = 2,
		clickable = true,
	},
	pads = {
		{
			id = "d3_nest_tower",
			area = 3,
			name = "Nest Tower",
			kind = "Build",
			cost = 10 * SCALE,
			requires = "d2_hire_pteros",
			target = PRODUCER,
			value = 0,
			build = "D3_NestTower",
			blurb = "Builds the Ptero Express!",
		},
		{
			id = "d3_rope_bridge",
			area = 3,
			name = "Rope Bridge",
			kind = "Build",
			cost = 12 * SCALE,
			requires = "d3_nest_tower",
			target = PRODUCER,
			value = 0.1,
			build = "D3_RopeBridge",
			blurb = "+10% Ptero Bones",
		},
		{
			id = "d3_parcel_baskets",
			area = 3,
			name = "Parcel Baskets",
			kind = "Multiplier",
			cost = 45 * SCALE,
			requires = "d3_rope_bridge",
			target = PRODUCER,
			value = 2,
			build = "D3_ParcelBaskets",
			blurb = "x2 Ptero Bones",
		},
		{
			id = "d3_wind_sock",
			area = 3,
			name = "Wind Sock",
			kind = "Speed",
			cost = 120 * SCALE,
			requires = "d3_parcel_baskets",
			target = PRODUCER,
			value = 2,
			build = "D3_WindSock",
			blurb = "x2 Ptero speed",
		},
		{
			id = "d3_ptero_flock",
			area = 3,
			name = "Ptero Flock",
			kind = "Multiplier",
			cost = 700 * SCALE,
			requires = "d3_wind_sock",
			target = PRODUCER,
			value = 3,
			build = "D3_PteroFlock",
			blurb = "x3 Ptero Bones",
		},
		{
			id = "d3_treasure_map",
			area = 3,
			name = "Treasure Map",
			kind = "Multiplier",
			cost = 3600 * SCALE,
			requires = "d3_ptero_flock",
			target = PRODUCER,
			value = 4,
			build = "D3_TreasureMap",
			blurb = "x4 Ptero Bones",
		},
		{
			id = "d3_landing_pad",
			area = 3,
			name = "Landing Pad",
			kind = "Build",
			cost = 4200 * SCALE,
			requires = "d3_treasure_map",
			target = PRODUCER,
			value = 0.1,
			build = "D3_LandingPad",
			blurb = "+10% Ptero Bones",
		},
		{
			id = "d3_captain_ptera",
			area = 3,
			name = "Captain Ptera",
			kind = "Manager",
			cost = 6000 * SCALE,
			requires = "d3_landing_pad",
			target = PRODUCER,
			build = "D3_CaptainPtera",
			blurb = "Captain Ptera flies it for you!",
		},
		{
			id = "d3_tap_springs",
			area = 3,
			name = "Tap the Geyser Springs",
			kind = "Unlock",
			cost = 18000 * SCALE,
			requires = "d3_captain_ptera",
			unlocks = 4,
			build = "D4_EntryArch",
			blurb = "Opens the Geyser Springs",
		},
	},
}

return area
