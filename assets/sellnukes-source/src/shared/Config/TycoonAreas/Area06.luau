--!strict
--[[
	Area 6 — Rocket Factory (spec §3.6).

	Conveyor line, robot arms and a paint booth turning out candy-coloured toy rockets.

	Producer: Rocket Line (`p6_rocket_line`). Pads in their fixed linear buy order; every pad requires the one
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
local SCALE = 1.75e9

-- Producer id (SAVE DATA).
local PRODUCER = "p6_rocket_line"

local area: TycoonTypes.AreaConfig = {
	index = 6,
	id = "rocket_factory",
	name = "Rocket Factory",
	producer = {
		id = PRODUCER,
		name = "Rocket Line",
		area = 6,
		builtBy = "a6_factory_shell",
		-- Level 1 -> 2 costs baseCost; each further level costs costGrowth x the previous one.
		baseCost = 3 * SCALE,
		costGrowth = 1.2,
		-- Cash per cycle at level 1 (linear in level) and seconds per cycle before speed-ups.
		baseRevenue = 5.7e7,
		baseCycle = 3.5,
		clickable = true,
	},
	pads = {
		{
			id = "a6_factory_shell",
			area = 6,
			name = "Factory Shell",
			kind = "Build",
			cost = 10 * SCALE,
			requires = "a5_open_factory",
			target = PRODUCER,
			value = 0,
			build = "A6_FactoryShell",
			blurb = "Builds the Rocket Line!",
		},
		{
			id = "a6_conveyor",
			area = 6,
			name = "Conveyor",
			kind = "Build",
			cost = 12 * SCALE,
			requires = "a6_factory_shell",
			target = PRODUCER,
			value = 0.1,
			build = "A6_Conveyor",
			blurb = "+10% Rocket Line cash",
		},
		{
			id = "a6_robot_arms",
			area = 6,
			name = "Robot Arms",
			kind = "Multiplier",
			cost = 45 * SCALE,
			requires = "a6_conveyor",
			target = PRODUCER,
			value = 2,
			build = "A6_RobotArms",
			blurb = "x2 Rocket Line cash",
		},
		{
			id = "a6_fin_press",
			area = 6,
			name = "Fin Press",
			kind = "Multiplier",
			cost = 120 * SCALE,
			requires = "a6_robot_arms",
			target = PRODUCER,
			value = 2,
			build = "A6_FinPress",
			blurb = "x2 Rocket Line cash",
		},
		{
			id = "a6_paint_booth",
			area = 6,
			name = "Paint Booth",
			kind = "Multiplier",
			cost = 700 * SCALE,
			requires = "a6_fin_press",
			target = PRODUCER,
			value = 3,
			build = "A6_PaintBooth",
			blurb = "x3 Rocket Line cash",
		},
		{
			id = "a6_quality_check",
			area = 6,
			name = "Quality Check",
			kind = "Speed",
			cost = 940 * SCALE,
			requires = "a6_paint_booth",
			target = PRODUCER,
			value = 2,
			build = "A6_QualityCheck",
			blurb = "x2 Rocket Line speed",
		},
		{
			id = "a6_forklift",
			area = 6,
			name = "Forklift",
			kind = "Build",
			cost = 1100 * SCALE,
			requires = "a6_quality_check",
			target = PRODUCER,
			value = 0.1,
			build = "A6_Forklift",
			blurb = "+10% Rocket Line cash",
		},
		{
			id = "a6_loading_dock",
			area = 6,
			name = "Loading Dock",
			kind = "Build",
			cost = 1500 * SCALE,
			requires = "a6_forklift",
			target = PRODUCER,
			value = 0.1,
			build = "A6_LoadingDock",
			blurb = "+10% Rocket Line cash",
		},
		{
			id = "a6_factory_boss",
			area = 6,
			name = "Factory Boss",
			kind = "Manager",
			cost = 6000 * SCALE,
			requires = "a6_loading_dock",
			target = PRODUCER,
			build = "A6_FactoryBoss",
			blurb = "Automates the Rocket Line",
		},
		{
			id = "a6_dig_silos",
			area = 6,
			name = "Dig the Silos",
			kind = "Unlock",
			cost = 18000 * SCALE,
			requires = "a6_factory_boss",
			unlocks = 7,
			build = "A7_EntryArch",
			blurb = "Opens the Launch Silos",
		},
	},
}

return area
