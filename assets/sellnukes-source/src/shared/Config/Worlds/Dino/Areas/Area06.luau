--!strict
--[[
	Dino Valley area 6 — Volcano Reactor (World 2 spec §6.2).

	The finale (height budget 140): a tamed volcano with glowing lava channels, stone turbines and a crystal
	core. Buying the Golden T-Rex Statue unlocks Dino Rebirth (feature "Rebirth").

	Producer: Volcano Core (`dp6_volcano_core`). Pads in their fixed linear buy order; every pad requires the one
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
local SCALE = 1.09e9

-- Producer id (SAVE DATA).
local PRODUCER = "dp6_volcano_core"

local area: TycoonTypes.AreaConfig = {
	index = 6,
	id = "volcano_reactor",
	name = "Volcano Reactor",
	producer = {
		id = PRODUCER,
		name = "Volcano Core",
		area = 6,
		builtBy = "d6_volcano_core",
		-- Level 1 -> 2 costs baseCost; each further level costs costGrowth x the previous one.
		baseCost = 3 * SCALE,
		costGrowth = 1.2,
		-- Bones per cycle at level 1 (linear in level) and seconds per cycle before speed-ups.
		baseRevenue = 8e7,
		baseCycle = 5,
		clickable = true,
	},
	pads = {
		{
			id = "d6_volcano_core",
			area = 6,
			name = "Volcano Core",
			kind = "Build",
			cost = 10 * SCALE,
			requires = "d5_wake_volcano",
			target = PRODUCER,
			value = 0,
			build = "D6_VolcanoCore",
			blurb = "Builds the Volcano Core!",
		},
		{
			id = "d6_lava_channel",
			area = 6,
			name = "Lava Channel",
			kind = "Build",
			cost = 12 * SCALE,
			requires = "d6_volcano_core",
			target = PRODUCER,
			value = 0.1,
			build = "D6_LavaChannel",
			blurb = "+10% Volcano Bones",
		},
		{
			id = "d6_stone_turbines",
			area = 6,
			name = "Stone Turbines",
			kind = "Multiplier",
			cost = 45 * SCALE,
			requires = "d6_lava_channel",
			target = PRODUCER,
			value = 2,
			build = "D6_StoneTurbines",
			blurb = "x2 Volcano Bones",
		},
		{
			id = "d6_steam_vents",
			area = 6,
			name = "Steam Vents",
			kind = "Build",
			cost = 58 * SCALE,
			requires = "d6_stone_turbines",
			target = PRODUCER,
			value = 0.1,
			build = "D6_SteamVents",
			blurb = "+10% Volcano Bones",
		},
		{
			id = "d6_magma_pumps",
			area = 6,
			name = "Magma Pumps",
			kind = "Speed",
			cost = 350 * SCALE,
			requires = "d6_steam_vents",
			target = PRODUCER,
			value = 2,
			build = "D6_MagmaPumps",
			blurb = "x2 Volcano speed",
		},
		{
			id = "d6_crystal_core",
			area = 6,
			name = "Crystal Core",
			kind = "Multiplier",
			cost = 1500 * SCALE,
			requires = "d6_magma_pumps",
			target = PRODUCER,
			value = 3,
			build = "D6_CrystalCore",
			blurb = "x3 Volcano Bones",
		},
		{
			id = "d6_lava_falls",
			area = 6,
			name = "Lava Falls",
			kind = "Multiplier",
			cost = 1800 * SCALE,
			requires = "d6_crystal_core",
			target = PRODUCER,
			value = 2,
			build = "D6_LavaFalls",
			blurb = "x2 Volcano Bones",
		},
		{
			id = "d6_sky_bridge",
			area = 6,
			name = "Sky Bridge",
			kind = "Build",
			cost = 2100 * SCALE,
			requires = "d6_lava_falls",
			target = PRODUCER,
			value = 0.1,
			build = "D6_SkyBridge",
			blurb = "+10% Volcano Bones",
		},
		{
			id = "d6_obsidian_crown",
			area = 6,
			name = "Obsidian Crown",
			kind = "Multiplier",
			cost = 12000 * SCALE,
			requires = "d6_sky_bridge",
			target = PRODUCER,
			value = 5,
			build = "D6_ObsidianCrown",
			blurb = "x5 Volcano Bones",
		},
		{
			id = "d6_chief_tyra",
			area = 6,
			name = "Chief Tyra",
			kind = "Manager",
			cost = 14000 * SCALE,
			requires = "d6_obsidian_crown",
			target = PRODUCER,
			build = "D6_ChiefTyra",
			blurb = "Chief Tyra runs it for you!",
		},
		{
			id = "d6_golden_trex",
			area = 6,
			name = "Golden T-Rex Statue",
			kind = "Unlock",
			cost = 42000 * SCALE,
			requires = "d6_chief_tyra",
			feature = "Rebirth",
			build = "D6_GoldenTRex",
			blurb = "Unlocks Dino Rebirth!",
		},
	},
}

return area
