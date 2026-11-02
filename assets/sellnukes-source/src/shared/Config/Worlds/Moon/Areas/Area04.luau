--!strict
--[[
	Moon Base area 4 — Asteroid Mine (R69–R71 spec §2.2, World 3).

	Chunky asteroids bob on tethers above a drill rig, and crystal carts roll the glowing ore away. The Mega
	Asteroid is the star of the show; Drillbert, a drill-hat robot, keeps the rig humming.

	Producer: Asteroid Drill (`mp4_asteroid_drill`). Pads in their fixed linear buy order; every pad requires the one
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
local SCALE = 452000

-- Producer id (SAVE DATA).
local PRODUCER = "mp4_asteroid_drill"

local area: TycoonTypes.AreaConfig = {
	index = 4,
	id = "asteroid_mine",
	name = "Asteroid Mine",
	producer = {
		id = PRODUCER,
		name = "Asteroid Drill",
		area = 4,
		builtBy = "m4_drill_rig",
		-- Level 1 -> 2 costs baseCost; each further level costs costGrowth x the previous one.
		baseCost = 3 * SCALE,
		costGrowth = 1.2,
		-- Moon Rocks per cycle at level 1 (linear in level) and seconds per cycle before speed-ups.
		baseRevenue = 26000,
		baseCycle = 2.5,
		clickable = true,
	},
	pads = {
		{
			id = "m4_drill_rig",
			area = 4,
			name = "Drill Rig",
			kind = "Build",
			cost = 10 * SCALE,
			requires = "m3_mine_asteroids",
			target = PRODUCER,
			value = 0,
			build = "M4_DrillRig",
			blurb = "Builds the Asteroid Drill!",
		},
		{
			id = "m4_tether_cables",
			area = 4,
			name = "Tether Cables",
			kind = "Build",
			cost = 12 * SCALE,
			requires = "m4_drill_rig",
			target = PRODUCER,
			value = 0.1,
			build = "M4_TetherCables",
			blurb = "+10% Drill Moon Rocks",
		},
		{
			id = "m4_ore_carts",
			area = 4,
			name = "Ore Carts",
			kind = "Multiplier",
			cost = 45 * SCALE,
			requires = "m4_tether_cables",
			target = PRODUCER,
			value = 2,
			build = "M4_OreCarts",
			blurb = "x2 Drill Moon Rocks",
		},
		{
			id = "m4_crystal_sorter",
			area = 4,
			name = "Crystal Sorter",
			kind = "Build",
			cost = 58 * SCALE,
			requires = "m4_ore_carts",
			target = PRODUCER,
			value = 0.1,
			build = "M4_CrystalSorter",
			blurb = "+10% Drill Moon Rocks",
		},
		{
			id = "m4_gravity_magnets",
			area = 4,
			name = "Gravity Magnets",
			kind = "Multiplier",
			cost = 700 * SCALE,
			requires = "m4_crystal_sorter",
			target = PRODUCER,
			value = 3,
			build = "M4_GravityMagnets",
			blurb = "x3 Drill Moon Rocks",
		},
		{
			id = "m4_laser_drills",
			area = 4,
			name = "Laser Drills",
			kind = "Speed",
			cost = 1200 * SCALE,
			requires = "m4_gravity_magnets",
			target = PRODUCER,
			value = 2,
			build = "M4_LaserDrills",
			blurb = "x2 Drill speed",
		},
		{
			id = "m4_mega_asteroid",
			area = 4,
			name = "Mega Asteroid",
			kind = "Multiplier",
			cost = 5800 * SCALE,
			requires = "m4_laser_drills",
			target = PRODUCER,
			value = 4,
			build = "M4_MegaAsteroid",
			blurb = "x4 Drill Moon Rocks",
		},
		{
			id = "m4_drillbert",
			area = 4,
			name = "Drillbert",
			kind = "Manager",
			cost = 6700 * SCALE,
			requires = "m4_mega_asteroid",
			target = PRODUCER,
			build = "M4_Drillbert",
			blurb = "Drillbert drills it for you!",
		},
		{
			id = "m4_hover_steps",
			area = 4,
			name = "Hover Steps",
			kind = "Build",
			cost = 8900 * SCALE,
			requires = "m4_drillbert",
			target = PRODUCER,
			value = 0.1,
			build = "M4_HoverSteps",
			blurb = "+10% Drill Moon Rocks",
		},
		{
			id = "m4_build_star_lab",
			area = 4,
			name = "Build the Star Lab",
			kind = "Unlock",
			cost = 27000 * SCALE,
			requires = "m4_hover_steps",
			unlocks = 5,
			build = "M5_EntryArch",
			blurb = "Opens the Star Lab",
		},
	},
}

return area
