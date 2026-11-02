--!strict
--[[
	Dino Valley area 2 — Fern Market (World 2 spec §6.2).

	A cheerful market stall under a giant leaf awning: coconut tills, berry baskets and a totem sign. Stego
	Sally runs the stall once she is hired.

	Producer: Fern Market Stall (`dp2_fern_market`). Pads in their fixed linear buy order; every pad requires the one
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
local SCALE = 201

-- Producer id (SAVE DATA).
local PRODUCER = "dp2_fern_market"

local area: TycoonTypes.AreaConfig = {
	index = 2,
	id = "fern_market",
	name = "Fern Market",
	producer = {
		id = PRODUCER,
		name = "Fern Market Stall",
		area = 2,
		builtBy = "d2_shell_counter",
		-- Level 1 -> 2 costs baseCost; each further level costs costGrowth x the previous one.
		baseCost = 3 * SCALE,
		costGrowth = 1.2,
		-- Bones per cycle at level 1 (linear in level) and seconds per cycle before speed-ups.
		baseRevenue = 19,
		baseCycle = 1.5,
		clickable = true,
	},
	pads = {
		{
			id = "d2_shell_counter",
			area = 2,
			name = "Shell Counter",
			kind = "Build",
			cost = 10 * SCALE,
			requires = "d1_open_market",
			target = PRODUCER,
			value = 0,
			build = "D2_ShellCounter",
			blurb = "Builds the Fern Market Stall!",
		},
		{
			id = "d2_leaf_awning",
			area = 2,
			name = "Leaf Awning",
			kind = "Build",
			cost = 12 * SCALE,
			requires = "d2_shell_counter",
			target = PRODUCER,
			value = 0.1,
			build = "D2_LeafAwning",
			blurb = "+10% Market Bones",
		},
		{
			id = "d2_coconut_till",
			area = 2,
			name = "Coconut Till",
			kind = "Multiplier",
			cost = 45 * SCALE,
			requires = "d2_leaf_awning",
			target = PRODUCER,
			value = 2,
			build = "D2_CoconutTill",
			blurb = "x2 Market Bones",
		},
		{
			id = "d2_berry_baskets",
			area = 2,
			name = "Berry Baskets",
			kind = "Build",
			cost = 58 * SCALE,
			requires = "d2_coconut_till",
			target = PRODUCER,
			value = 0.1,
			build = "D2_BerryBaskets",
			blurb = "+10% Market Bones",
		},
		{
			id = "d2_totem_sign",
			area = 2,
			name = "Totem Sign",
			kind = "Multiplier",
			cost = 700 * SCALE,
			requires = "d2_berry_baskets",
			target = PRODUCER,
			value = 3,
			build = "D2_TotemSign",
			blurb = "x3 Market Bones",
		},
		{
			id = "d2_mammoth_fan",
			area = 2,
			name = "Mammoth Fan",
			kind = "Speed",
			cost = 1200 * SCALE,
			requires = "d2_totem_sign",
			target = PRODUCER,
			value = 2,
			build = "D2_MammothFan",
			blurb = "x2 Market speed",
		},
		{
			id = "d2_picnic_logs",
			area = 2,
			name = "Picnic Logs",
			kind = "Build",
			cost = 1500 * SCALE,
			requires = "d2_mammoth_fan",
			target = PRODUCER,
			value = 0.1,
			build = "D2_PicnicLogs",
			blurb = "+10% Market Bones",
		},
		{
			id = "d2_stego_sally",
			area = 2,
			name = "Stego Sally",
			kind = "Manager",
			cost = 6000 * SCALE,
			requires = "d2_picnic_logs",
			target = PRODUCER,
			build = "D2_StegoSally",
			blurb = "Sally runs the stall for you!",
		},
		{
			id = "d2_bamboo_fence",
			area = 2,
			name = "Bamboo Fence",
			kind = "Build",
			cost = 8900 * SCALE,
			requires = "d2_stego_sally",
			target = PRODUCER,
			value = 0.1,
			build = "D2_BambooFence",
			blurb = "+10% Market Bones",
		},
		{
			id = "d2_hire_pteros",
			area = 2,
			name = "Hire the Pteros",
			kind = "Unlock",
			cost = 27000 * SCALE,
			requires = "d2_bamboo_fence",
			unlocks = 3,
			build = "D3_EntryArch",
			blurb = "Opens the Ptero Post",
		},
	},
}

return area
