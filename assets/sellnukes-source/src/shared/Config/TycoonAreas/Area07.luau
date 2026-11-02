--!strict
--[[
	Area 7 — Launch Silos (spec §3.7).

	Hazard-striped pad field with three silos, a control room and a radar dish. Unlocks the side Attack mode:
	the AA Tower and Attack Console are Feature pads (no income, they switch systems on).

	Producer: Silo Launches (`p7_silo`). Pads in their fixed linear buy order; every pad requires the one
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
local SCALE = 2.5e10

-- Producer id (SAVE DATA).
local PRODUCER = "p7_silo"

local area: TycoonTypes.AreaConfig = {
	index = 7,
	id = "launch_silos",
	name = "Launch Silos",
	producer = {
		id = PRODUCER,
		name = "Silo Launches",
		area = 7,
		builtBy = "a7_silo_pad",
		-- Level 1 -> 2 costs baseCost; each further level costs costGrowth x the previous one.
		baseCost = 3 * SCALE,
		costGrowth = 1.2,
		-- Cash per cycle at level 1 (linear in level) and seconds per cycle before speed-ups.
		baseRevenue = 1.4e9,
		baseCycle = 4,
		clickable = true,
	},
	pads = {
		{
			id = "a7_silo_pad",
			area = 7,
			name = "Silo Pad",
			kind = "Build",
			cost = 10 * SCALE,
			requires = "a6_dig_silos",
			target = PRODUCER,
			value = 0,
			build = "A7_SiloPad",
			blurb = "Builds the Silo Launches!",
		},
		{
			id = "a7_silo_2",
			area = 7,
			name = "Silo 2",
			kind = "Multiplier",
			cost = 13 * SCALE,
			requires = "a7_silo_pad",
			target = PRODUCER,
			value = 2,
			build = "A7_Silo2",
			blurb = "x2 Silo cash",
		},
		{
			id = "a7_silo_3",
			area = 7,
			name = "Silo 3",
			kind = "Multiplier",
			cost = 90 * SCALE,
			requires = "a7_silo_2",
			target = PRODUCER,
			value = 3,
			build = "A7_Silo3",
			blurb = "x3 Silo cash",
		},
		{
			id = "a7_radar_dish",
			area = 7,
			name = "Radar Dish",
			kind = "Multiplier",
			cost = 120 * SCALE,
			requires = "a7_silo_3",
			target = PRODUCER,
			value = 2,
			build = "A7_RadarDish",
			blurb = "x2 Silo cash",
		},
		{
			id = "a7_control_room",
			area = 7,
			name = "Control Room",
			kind = "Speed",
			cost = 350 * SCALE,
			requires = "a7_radar_dish",
			target = PRODUCER,
			value = 2,
			build = "A7_ControlRoom",
			blurb = "x2 Silo speed",
		},
		{
			id = "a7_hazard_floor",
			area = 7,
			name = "Hazard Floor",
			kind = "Build",
			cost = 600 * SCALE,
			requires = "a7_control_room",
			target = PRODUCER,
			value = 0.1,
			build = "A7_HazardFloor",
			blurb = "+10% Silo cash",
		},
		{
			id = "a7_launch_director",
			area = 7,
			name = "Launch Director",
			kind = "Manager",
			cost = 6000 * SCALE,
			requires = "a7_hazard_floor",
			target = PRODUCER,
			build = "A7_LaunchDirector",
			blurb = "Automates the Silo",
		},
		{
			id = "a7_aa_tower",
			area = 7,
			name = "AA Tower",
			kind = "Feature",
			cost = 6900 * SCALE,
			requires = "a7_launch_director",
			feature = "AATower",
			build = "A7_AATower",
			blurb = "Defend your plot from nukes",
		},
		{
			id = "a7_attack_console",
			area = 7,
			name = "Attack Console",
			kind = "Feature",
			cost = 14000 * SCALE,
			requires = "a7_aa_tower",
			feature = "AttackConsole",
			build = "A7_AttackConsole",
			blurb = "Unlocks Attack mode",
		},
		{
			id = "a7_open_megastore",
			area = 7,
			name = "Open the Megastore",
			kind = "Unlock",
			cost = 42000 * SCALE,
			requires = "a7_attack_console",
			unlocks = 8,
			build = "A8_EntryArch",
			blurb = "Opens the Nuke Megastore",
		},
	},
}

return area
