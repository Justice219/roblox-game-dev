--!strict
--[[
	Moon Base area 5 — Star Lab (R69–R71 spec §2.2, World 3).

	A domed observatory with a giant telescope, a planet mobile and jars of twinkling stars. Dr. Nova, an
	alien scientist in a lab coat, runs the experiments.

	Producer: Star Lab (`mp5_star_lab`). Pads in their fixed linear buy order; every pad requires the one
	before it (the first pad requires the previous Moon area's Unlock pad), so `requires` forms one chain
	across the whole Moon Base tycoon. Pad kinds mirror Dino Valley pad-for-pad, so the pricing structure
	is identical. EconomyIndex validates the chain and the id rules at load: pads m<area>_name, producers
	mp<area>_name, build keys M<area>_Name (an Unlock pad builds the NEXT area's M<area+1>_EntryArch, which
	resolves to Worlds/Moon/Layouts/Area<area+1>.base).

	SAVE DATA: every pad `id` and the producer `id` are stored in profile.worlds.moon. Never rename or reuse
	them. `build` is the build-group key the Moon area art builders map to Blender meshes.

	Costs are multiples of SCALE, this area's cost unit, priced exactly like Nuke Town (docs/economy.md
	"Pricing structure"): builder pad = 10 x SCALE, the other pads on the producer's level-cost curve
	(weight x L x 3 x 1.2^(L-1) SCALE units at a designated level L, forced to rise >= 15 % along the chain),
	the Unlock pad = 3x the pad before it. SCALE (pace) and baseRevenue (level-1 producer = 1 % of arrival
	income) are written by the pacing simulator:
	`lune run tests/economy-sim.luau --world moon --tune --write`. EconomyIndex rounds each price to 2
	significant digits at load. Formulas, pacing table and retuning: docs/economy.md ("Moon Base").
]]

local TycoonTypes = require(script.Parent.Parent.Parent.Parent.Parent.Tycoon.TycoonTypes)

-- Cost unit (tuned for the pacing target; see header).
local SCALE = 2.62e7

-- Producer id (SAVE DATA).
local PRODUCER = "mp5_star_lab"

local area: TycoonTypes.AreaConfig = {
	index = 5,
	id = "star_lab",
	name = "Star Lab",
	producer = {
		id = PRODUCER,
		name = "Star Lab",
		area = 5,
		builtBy = "m5_lab_dome",
		-- Level 1 -> 2 costs baseCost; each further level costs costGrowth x the previous one.
		baseCost = 3 * SCALE,
		costGrowth = 1.2,
		-- Moon Rocks per cycle at level 1 (linear in level) and seconds per cycle before speed-ups.
		baseRevenue = 2e6,
		baseCycle = 3.5,
		clickable = true,
	},
	pads = {
		{
			id = "m5_lab_dome",
			area = 5,
			name = "Lab Dome",
			kind = "Build",
			cost = 10 * SCALE,
			requires = "m4_build_star_lab",
			target = PRODUCER,
			value = 0,
			build = "M5_LabDome",
			blurb = "Builds the Star Lab!",
		},
		{
			id = "m5_star_jars",
			area = 5,
			name = "Star Jars",
			kind = "Build",
			cost = 12 * SCALE,
			requires = "m5_lab_dome",
			target = PRODUCER,
			value = 0.1,
			build = "M5_StarJars",
			blurb = "+10% Lab Moon Rocks",
		},
		{
			id = "m5_big_telescope",
			area = 5,
			name = "Big Telescope",
			kind = "Multiplier",
			cost = 45 * SCALE,
			requires = "m5_star_jars",
			target = PRODUCER,
			value = 2,
			build = "M5_BigTelescope",
			blurb = "x2 Lab Moon Rocks",
		},
		{
			id = "m5_planet_mobile",
			area = 5,
			name = "Planet Mobile",
			kind = "Multiplier",
			cost = 120 * SCALE,
			requires = "m5_big_telescope",
			target = PRODUCER,
			value = 2,
			build = "M5_PlanetMobile",
			blurb = "x2 Lab Moon Rocks",
		},
		{
			id = "m5_comet_catcher",
			area = 5,
			name = "Comet Catcher",
			kind = "Speed",
			cost = 350 * SCALE,
			requires = "m5_planet_mobile",
			target = PRODUCER,
			value = 2,
			build = "M5_CometCatcher",
			blurb = "x2 Lab speed",
		},
		{
			id = "m5_robot_arm",
			area = 5,
			name = "Robot Arm",
			kind = "Multiplier",
			cost = 2400 * SCALE,
			requires = "m5_comet_catcher",
			target = PRODUCER,
			value = 3,
			build = "M5_RobotArm",
			blurb = "x3 Lab Moon Rocks",
		},
		{
			id = "m5_moon_garden",
			area = 5,
			name = "Moon Garden",
			kind = "Build",
			cost = 2800 * SCALE,
			requires = "m5_robot_arm",
			target = PRODUCER,
			value = 0.1,
			build = "M5_MoonGarden",
			blurb = "+10% Lab Moon Rocks",
		},
		{
			id = "m5_dr_nova",
			area = 5,
			name = "Dr. Nova",
			kind = "Manager",
			cost = 6000 * SCALE,
			requires = "m5_moon_garden",
			target = PRODUCER,
			build = "M5_DrNova",
			blurb = "Dr. Nova runs the lab for you!",
		},
		{
			id = "m5_mission_banners",
			area = 5,
			name = "Mission Banners",
			kind = "Build",
			cost = 8900 * SCALE,
			requires = "m5_dr_nova",
			target = PRODUCER,
			value = 0.1,
			build = "M5_MissionBanners",
			blurb = "+10% Lab Moon Rocks",
		},
		{
			id = "m5_light_star",
			area = 5,
			name = "Light the Star Reactor",
			kind = "Unlock",
			cost = 27000 * SCALE,
			requires = "m5_mission_banners",
			unlocks = 6,
			build = "M6_EntryArch",
			blurb = "Opens the Star Reactor",
		},
	},
}

return area
