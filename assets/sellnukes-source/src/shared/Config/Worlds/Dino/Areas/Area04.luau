--!strict
--[[
	Dino Valley area 4 — Geyser Springs (World 2 spec §6.2).

	Steaming geysers piped through bamboo into a big water wheel and hot springs. The Mega Geyser is the star of
	the show; Para Pete keeps the pumps running.

	Producer: Geyser Pump (`dp4_geyser_pump`). Pads in their fixed linear buy order; every pad requires the one
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
local SCALE = 452000

-- Producer id (SAVE DATA).
local PRODUCER = "dp4_geyser_pump"

local area: TycoonTypes.AreaConfig = {
	index = 4,
	id = "geyser_springs",
	name = "Geyser Springs",
	producer = {
		id = PRODUCER,
		name = "Geyser Pump",
		area = 4,
		builtBy = "d4_geyser_vent",
		-- Level 1 -> 2 costs baseCost; each further level costs costGrowth x the previous one.
		baseCost = 3 * SCALE,
		costGrowth = 1.2,
		-- Bones per cycle at level 1 (linear in level) and seconds per cycle before speed-ups.
		baseRevenue = 26000,
		baseCycle = 2.5,
		clickable = true,
	},
	pads = {
		{
			id = "d4_geyser_vent",
			area = 4,
			name = "Geyser Vent",
			kind = "Build",
			cost = 10 * SCALE,
			requires = "d3_tap_springs",
			target = PRODUCER,
			value = 0,
			build = "D4_GeyserVent",
			blurb = "Builds the Geyser Pump!",
		},
		{
			id = "d4_bamboo_pipes",
			area = 4,
			name = "Bamboo Pipes",
			kind = "Build",
			cost = 12 * SCALE,
			requires = "d4_geyser_vent",
			target = PRODUCER,
			value = 0.1,
			build = "D4_BambooPipes",
			blurb = "+10% Geyser Bones",
		},
		{
			id = "d4_water_wheel",
			area = 4,
			name = "Water Wheel",
			kind = "Multiplier",
			cost = 45 * SCALE,
			requires = "d4_bamboo_pipes",
			target = PRODUCER,
			value = 2,
			build = "D4_WaterWheel",
			blurb = "x2 Geyser Bones",
		},
		{
			id = "d4_steam_whistles",
			area = 4,
			name = "Steam Whistles",
			kind = "Build",
			cost = 58 * SCALE,
			requires = "d4_water_wheel",
			target = PRODUCER,
			value = 0.1,
			build = "D4_SteamWhistles",
			blurb = "+10% Geyser Bones",
		},
		{
			id = "d4_hot_springs",
			area = 4,
			name = "Hot Springs",
			kind = "Multiplier",
			cost = 700 * SCALE,
			requires = "d4_steam_whistles",
			target = PRODUCER,
			value = 3,
			build = "D4_HotSprings",
			blurb = "x3 Geyser Bones",
		},
		{
			id = "d4_pressure_valves",
			area = 4,
			name = "Pressure Valves",
			kind = "Speed",
			cost = 1200 * SCALE,
			requires = "d4_hot_springs",
			target = PRODUCER,
			value = 2,
			build = "D4_PressureValves",
			blurb = "x2 Geyser speed",
		},
		{
			id = "d4_mega_geyser",
			area = 4,
			name = "Mega Geyser",
			kind = "Multiplier",
			cost = 5800 * SCALE,
			requires = "d4_pressure_valves",
			target = PRODUCER,
			value = 4,
			build = "D4_MegaGeyser",
			blurb = "x4 Geyser Bones",
		},
		{
			id = "d4_para_pete",
			area = 4,
			name = "Para Pete",
			kind = "Manager",
			cost = 6700 * SCALE,
			requires = "d4_mega_geyser",
			target = PRODUCER,
			build = "D4_ParaPete",
			blurb = "Para Pete pumps it for you!",
		},
		{
			id = "d4_stone_steps",
			area = 4,
			name = "Stone Steps",
			kind = "Build",
			cost = 8900 * SCALE,
			requires = "d4_para_pete",
			target = PRODUCER,
			value = 0.1,
			build = "D4_StoneSteps",
			blurb = "+10% Geyser Bones",
		},
		{
			id = "d4_build_lab",
			area = 4,
			name = "Build the Fossil Lab",
			kind = "Unlock",
			cost = 27000 * SCALE,
			requires = "d4_stone_steps",
			unlocks = 5,
			build = "D5_EntryArch",
			blurb = "Opens the Fossil Lab",
		},
	},
}

return area
