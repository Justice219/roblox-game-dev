--!strict
--[[
	Moon Base area 6 — Star Reactor (R69–R71 spec §2.2, World 3).

	The finale (height budget 140): a friendly mini-sun glowing inside a ring cage, with beam towers and orbit
	rings. Buying the Golden Astronaut Statue unlocks Moon Rebirth (feature "Rebirth").

	Producer: Star Core (`mp6_star_core`). Pads in their fixed linear buy order; every pad requires the one
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
local SCALE = 1.09e9

-- Producer id (SAVE DATA).
local PRODUCER = "mp6_star_core"

local area: TycoonTypes.AreaConfig = {
	index = 6,
	id = "star_reactor",
	name = "Star Reactor",
	producer = {
		id = PRODUCER,
		name = "Star Core",
		area = 6,
		builtBy = "m6_star_core",
		-- Level 1 -> 2 costs baseCost; each further level costs costGrowth x the previous one.
		baseCost = 3 * SCALE,
		costGrowth = 1.2,
		-- Moon Rocks per cycle at level 1 (linear in level) and seconds per cycle before speed-ups.
		baseRevenue = 8e7,
		baseCycle = 5,
		clickable = true,
	},
	pads = {
		{
			id = "m6_star_core",
			area = 6,
			name = "Star Core",
			kind = "Build",
			cost = 10 * SCALE,
			requires = "m5_light_star",
			target = PRODUCER,
			value = 0,
			build = "M6_StarCore",
			blurb = "Builds the Star Core!",
		},
		{
			id = "m6_plasma_pipes",
			area = 6,
			name = "Plasma Pipes",
			kind = "Build",
			cost = 12 * SCALE,
			requires = "m6_star_core",
			target = PRODUCER,
			value = 0.1,
			build = "M6_PlasmaPipes",
			blurb = "+10% Star Moon Rocks",
		},
		{
			id = "m6_orbit_rings",
			area = 6,
			name = "Orbit Rings",
			kind = "Multiplier",
			cost = 45 * SCALE,
			requires = "m6_plasma_pipes",
			target = PRODUCER,
			value = 2,
			build = "M6_OrbitRings",
			blurb = "x2 Star Moon Rocks",
		},
		{
			id = "m6_beam_towers",
			area = 6,
			name = "Beam Towers",
			kind = "Build",
			cost = 58 * SCALE,
			requires = "m6_orbit_rings",
			target = PRODUCER,
			value = 0.1,
			build = "M6_BeamTowers",
			blurb = "+10% Star Moon Rocks",
		},
		{
			id = "m6_coolant_pumps",
			area = 6,
			name = "Coolant Pumps",
			kind = "Speed",
			cost = 350 * SCALE,
			requires = "m6_beam_towers",
			target = PRODUCER,
			value = 2,
			build = "M6_CoolantPumps",
			blurb = "x2 Star speed",
		},
		{
			id = "m6_nebula_core",
			area = 6,
			name = "Nebula Core",
			kind = "Multiplier",
			cost = 1500 * SCALE,
			requires = "m6_coolant_pumps",
			target = PRODUCER,
			value = 3,
			build = "M6_NebulaCore",
			blurb = "x3 Star Moon Rocks",
		},
		{
			id = "m6_meteor_falls",
			area = 6,
			name = "Meteor Falls",
			kind = "Multiplier",
			cost = 1800 * SCALE,
			requires = "m6_nebula_core",
			target = PRODUCER,
			value = 2,
			build = "M6_MeteorFalls",
			blurb = "x2 Star Moon Rocks",
		},
		{
			id = "m6_star_bridge",
			area = 6,
			name = "Star Bridge",
			kind = "Build",
			cost = 2100 * SCALE,
			requires = "m6_meteor_falls",
			target = PRODUCER,
			value = 0.1,
			build = "M6_StarBridge",
			blurb = "+10% Star Moon Rocks",
		},
		{
			id = "m6_galaxy_crown",
			area = 6,
			name = "Galaxy Crown",
			kind = "Multiplier",
			cost = 12000 * SCALE,
			requires = "m6_star_bridge",
			target = PRODUCER,
			value = 5,
			build = "M6_GalaxyCrown",
			blurb = "x5 Star Moon Rocks",
		},
		{
			id = "m6_commander_lux",
			area = 6,
			name = "Commander Lux",
			kind = "Manager",
			cost = 14000 * SCALE,
			requires = "m6_galaxy_crown",
			target = PRODUCER,
			build = "M6_CommanderLux",
			blurb = "Commander Lux runs it for you!",
		},
		{
			id = "m6_golden_astronaut",
			area = 6,
			name = "Golden Astronaut Statue",
			kind = "Unlock",
			cost = 42000 * SCALE,
			requires = "m6_commander_lux",
			feature = "Rebirth",
			build = "M6_GoldenAstronaut",
			blurb = "Unlocks Moon Rebirth!",
		},
	},
}

return area
