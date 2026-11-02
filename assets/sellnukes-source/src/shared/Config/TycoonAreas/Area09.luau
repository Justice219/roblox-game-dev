--!strict
--[[
	Area 9 — Space Port (spec §3.9).

	Launch tower, mission control, fuel tanks and a satellite dish.

	Producer: Orbital Launches (`p9_orbital`). Pads in their fixed linear buy order; every pad requires the one
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
local SCALE = 2.64e13

-- Producer id (SAVE DATA).
local PRODUCER = "p9_orbital"

local area: TycoonTypes.AreaConfig = {
	index = 9,
	id = "space_port",
	name = "Space Port",
	producer = {
		id = PRODUCER,
		name = "Orbital Launches",
		area = 9,
		builtBy = "a9_launch_pad",
		-- Level 1 -> 2 costs baseCost; each further level costs costGrowth x the previous one.
		baseCost = 3 * SCALE,
		costGrowth = 1.2,
		-- Cash per cycle at level 1 (linear in level) and seconds per cycle before speed-ups.
		baseRevenue = 8e11,
		baseCycle = 6,
		clickable = true,
	},
	pads = {
		{
			id = "a9_launch_pad",
			area = 9,
			name = "Launch Pad",
			kind = "Build",
			cost = 10 * SCALE,
			requires = "a8_build_space_port",
			target = PRODUCER,
			value = 0,
			build = "A9_LaunchPad",
			blurb = "Builds the Orbital Launches!",
		},
		{
			id = "a9_fuel_tanks",
			area = 9,
			name = "Fuel Tanks",
			kind = "Build",
			cost = 12 * SCALE,
			requires = "a9_launch_pad",
			target = PRODUCER,
			value = 0.1,
			build = "A9_FuelTanks",
			blurb = "+10% Orbital cash",
		},
		{
			id = "a9_mission_control",
			area = 9,
			name = "Mission Control",
			kind = "Multiplier",
			cost = 45 * SCALE,
			requires = "a9_fuel_tanks",
			target = PRODUCER,
			value = 2,
			build = "A9_MissionControl",
			blurb = "x2 Orbital cash",
		},
		{
			id = "a9_booster_rockets",
			area = 9,
			name = "Booster Rockets",
			kind = "Multiplier",
			cost = 230 * SCALE,
			requires = "a9_mission_control",
			target = PRODUCER,
			value = 3,
			build = "A9_BoosterRockets",
			blurb = "x3 Orbital cash",
		},
		{
			id = "a9_satellite_dish",
			area = 9,
			name = "Satellite Dish",
			kind = "Speed",
			cost = 350 * SCALE,
			requires = "a9_booster_rockets",
			target = PRODUCER,
			value = 2,
			build = "A9_SatelliteDish",
			blurb = "x2 Orbital speed",
		},
		{
			id = "a9_astronaut_crew",
			area = 9,
			name = "Astronaut Crew",
			kind = "Multiplier",
			cost = 1200 * SCALE,
			requires = "a9_satellite_dish",
			target = PRODUCER,
			value = 2,
			build = "A9_AstronautCrew",
			blurb = "x2 Orbital cash",
		},
		{
			id = "a9_space_elevator",
			area = 9,
			name = "Space Elevator",
			kind = "Multiplier",
			cost = 9100 * SCALE,
			requires = "a9_astronaut_crew",
			target = PRODUCER,
			value = 4,
			build = "A9_SpaceElevator",
			blurb = "x4 Orbital cash",
		},
		{
			id = "a9_flight_director",
			area = 9,
			name = "Flight Director",
			kind = "Manager",
			cost = 10000 * SCALE,
			requires = "a9_space_elevator",
			target = PRODUCER,
			build = "A9_FlightDirector",
			blurb = "Automates the Orbital",
		},
		{
			id = "a9_build_mega_facility",
			area = 9,
			name = "Build the Mega Facility",
			kind = "Unlock",
			cost = 30000 * SCALE,
			requires = "a9_flight_director",
			unlocks = 10,
			build = "A10_EntryArch",
			blurb = "Opens the Mega Nuclear Facility",
		},
	},
}

return area
