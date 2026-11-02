--!strict
--[[
	Dino Valley area 5 — Fossil Lab (World 2 spec §6.2).

	A thatched lab-museum with a giant (friendly, plastic) dino skeleton, amber jars and egg incubators. Dr. Trike
	runs the experiments.

	Producer: Fossil Lab (`dp5_fossil_lab`). Pads in their fixed linear buy order; every pad requires the one
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
local SCALE = 2.62e7

-- Producer id (SAVE DATA).
local PRODUCER = "dp5_fossil_lab"

local area: TycoonTypes.AreaConfig = {
	index = 5,
	id = "fossil_lab",
	name = "Fossil Lab",
	producer = {
		id = PRODUCER,
		name = "Fossil Lab",
		area = 5,
		builtBy = "d5_lab_hut",
		-- Level 1 -> 2 costs baseCost; each further level costs costGrowth x the previous one.
		baseCost = 3 * SCALE,
		costGrowth = 1.2,
		-- Bones per cycle at level 1 (linear in level) and seconds per cycle before speed-ups.
		baseRevenue = 2e6,
		baseCycle = 3.5,
		clickable = true,
	},
	pads = {
		{
			id = "d5_lab_hut",
			area = 5,
			name = "Lab Hut",
			kind = "Build",
			cost = 10 * SCALE,
			requires = "d4_build_lab",
			target = PRODUCER,
			value = 0,
			build = "D5_LabHut",
			blurb = "Builds the Fossil Lab!",
		},
		{
			id = "d5_amber_jars",
			area = 5,
			name = "Amber Jars",
			kind = "Build",
			cost = 12 * SCALE,
			requires = "d5_lab_hut",
			target = PRODUCER,
			value = 0.1,
			build = "D5_AmberJars",
			blurb = "+10% Lab Bones",
		},
		{
			id = "d5_microscope",
			area = 5,
			name = "Microscope",
			kind = "Multiplier",
			cost = 45 * SCALE,
			requires = "d5_amber_jars",
			target = PRODUCER,
			value = 2,
			build = "D5_Microscope",
			blurb = "x2 Lab Bones",
		},
		{
			id = "d5_incubators",
			area = 5,
			name = "Egg Incubators",
			kind = "Multiplier",
			cost = 120 * SCALE,
			requires = "d5_microscope",
			target = PRODUCER,
			value = 2,
			build = "D5_Incubators",
			blurb = "x2 Lab Bones",
		},
		{
			id = "d5_dusting_brushes",
			area = 5,
			name = "Dusting Brushes",
			kind = "Speed",
			cost = 350 * SCALE,
			requires = "d5_incubators",
			target = PRODUCER,
			value = 2,
			build = "D5_DustingBrushes",
			blurb = "x2 Lab speed",
		},
		{
			id = "d5_skeleton",
			area = 5,
			name = "Big Skeleton",
			kind = "Multiplier",
			cost = 2400 * SCALE,
			requires = "d5_dusting_brushes",
			target = PRODUCER,
			value = 3,
			build = "D5_Skeleton",
			blurb = "x3 Lab Bones",
		},
		{
			id = "d5_dig_site",
			area = 5,
			name = "Dig Site",
			kind = "Build",
			cost = 2800 * SCALE,
			requires = "d5_skeleton",
			target = PRODUCER,
			value = 0.1,
			build = "D5_DigSite",
			blurb = "+10% Lab Bones",
		},
		{
			id = "d5_dr_trike",
			area = 5,
			name = "Dr. Trike",
			kind = "Manager",
			cost = 6000 * SCALE,
			requires = "d5_dig_site",
			target = PRODUCER,
			build = "D5_DrTrike",
			blurb = "Dr. Trike runs the lab for you!",
		},
		{
			id = "d5_museum_banners",
			area = 5,
			name = "Museum Banners",
			kind = "Build",
			cost = 8900 * SCALE,
			requires = "d5_dr_trike",
			target = PRODUCER,
			value = 0.1,
			build = "D5_MuseumBanners",
			blurb = "+10% Lab Bones",
		},
		{
			id = "d5_wake_volcano",
			area = 5,
			name = "Wake the Volcano",
			kind = "Unlock",
			cost = 27000 * SCALE,
			requires = "d5_museum_banners",
			unlocks = 6,
			build = "D6_EntryArch",
			blurb = "Opens the Volcano Reactor",
		},
	},
}

return area
