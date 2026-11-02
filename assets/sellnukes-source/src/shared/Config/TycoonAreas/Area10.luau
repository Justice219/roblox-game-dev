--!strict
--[[
	Area 10 — Mega Nuclear Facility (spec §3.10).

	Reactor dome, twin cooling towers with steam, a turbine hall and pylons. The Golden Atom Statue is the finale:
	buying it unlocks Rebirth (feature "Rebirth").

	Producer: Mega Reactor (`p10_mega_reactor`). Pads in their fixed linear buy order; every pad requires the one
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
local SCALE = 2.3e15

-- Producer id (SAVE DATA).
local PRODUCER = "p10_mega_reactor"

local area: TycoonTypes.AreaConfig = {
	index = 10,
	id = "mega_facility",
	name = "Mega Nuclear Facility",
	producer = {
		id = PRODUCER,
		name = "Mega Reactor",
		area = 10,
		builtBy = "a10_reactor_dome",
		-- Level 1 -> 2 costs baseCost; each further level costs costGrowth x the previous one.
		baseCost = 3 * SCALE,
		costGrowth = 1.2,
		-- Cash per cycle at level 1 (linear in level) and seconds per cycle before speed-ups.
		baseRevenue = 7.8e13,
		baseCycle = 8,
		clickable = true,
	},
	pads = {
		{
			id = "a10_reactor_dome",
			area = 10,
			name = "Reactor Dome",
			kind = "Build",
			cost = 10 * SCALE,
			requires = "a9_build_mega_facility",
			target = PRODUCER,
			value = 0,
			build = "A10_ReactorDome",
			blurb = "Builds the Mega Reactor!",
		},
		{
			id = "a10_cooling_tower",
			area = 10,
			name = "Cooling Tower",
			kind = "Multiplier",
			cost = 13 * SCALE,
			requires = "a10_reactor_dome",
			target = PRODUCER,
			value = 2,
			build = "A10_CoolingTower",
			blurb = "x2 Mega Reactor cash",
		},
		{
			id = "a10_cooling_tower_2",
			area = 10,
			name = "Cooling Tower II",
			kind = "Multiplier",
			cost = 90 * SCALE,
			requires = "a10_cooling_tower",
			target = PRODUCER,
			value = 3,
			build = "A10_CoolingTower2",
			blurb = "x3 Mega Reactor cash",
		},
		{
			id = "a10_turbine_hall",
			area = 10,
			name = "Turbine Hall",
			kind = "Speed",
			cost = 120 * SCALE,
			requires = "a10_cooling_tower_2",
			target = PRODUCER,
			value = 2,
			build = "A10_TurbineHall",
			blurb = "x2 Mega Reactor speed",
		},
		{
			id = "a10_power_lines",
			area = 10,
			name = "Power Lines",
			kind = "Multiplier",
			cost = 350 * SCALE,
			requires = "a10_turbine_hall",
			target = PRODUCER,
			value = 2,
			build = "A10_PowerLines",
			blurb = "x2 Mega Reactor cash",
		},
		{
			id = "a10_control_tower",
			area = 10,
			name = "Control Tower",
			kind = "Build",
			cost = 600 * SCALE,
			requires = "a10_power_lines",
			target = PRODUCER,
			value = 0.1,
			build = "A10_ControlTower",
			blurb = "+10% Mega Reactor cash",
		},
		{
			id = "a10_fusion_core",
			area = 10,
			name = "Fusion Core",
			kind = "Multiplier",
			cost = 12000 * SCALE,
			requires = "a10_control_tower",
			target = PRODUCER,
			value = 5,
			build = "A10_FusionCore",
			blurb = "x5 Mega Reactor cash",
		},
		{
			id = "a10_chief_engineer",
			area = 10,
			name = "Chief Engineer",
			kind = "Manager",
			cost = 14000 * SCALE,
			requires = "a10_fusion_core",
			target = PRODUCER,
			build = "A10_ChiefEngineer",
			blurb = "Automates the Mega Reactor",
		},
		{
			id = "a10_golden_atom",
			area = 10,
			name = "Golden Atom Statue",
			kind = "Unlock",
			cost = 42000 * SCALE,
			requires = "a10_chief_engineer",
			feature = "Rebirth",
			build = "A10_GoldenAtom",
			blurb = "Finale! Unlocks Rebirth",
		},
	},
}

return area
