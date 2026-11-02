--!strict
--[[
	Moon Base area 1 — Crater Camp (R69–R71 spec §2.2, World 3).

	A little capsule that landed in a crater, with a workbench under a big lamp where friendly robots snap
	together pocket nukes from moon rocks. The Moon tycoon starts here: the free Capsule Bench builds the producer,
	the player clicks it for the first Moon Rocks, then upgrades and automates with Bleep Bot.

	Producer: Moon Rock Bench (`mp1_rock_bench`). Pads in their fixed linear buy order; every pad requires the one
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
local SCALE = 6.15

-- Producer id (SAVE DATA).
local PRODUCER = "mp1_rock_bench"

local area: TycoonTypes.AreaConfig = {
	index = 1,
	id = "crater_camp",
	name = "Crater Camp",
	producer = {
		id = PRODUCER,
		name = "Moon Rock Bench",
		area = 1,
		builtBy = "m1_capsule_bench",
		-- Level 1 -> 2 costs baseCost; each further level costs costGrowth x the previous one.
		baseCost = 3 * SCALE,
		costGrowth = 1.2,
		-- Moon Rocks per cycle at level 1 (linear in level) and seconds per cycle before speed-ups.
		baseRevenue = 1,
		baseCycle = 1,
		clickable = true,
	},
	pads = {
		{
			id = "m1_capsule_bench",
			area = 1,
			name = "Capsule Bench",
			kind = "Build",
			cost = 0, -- free: the first Moon purchase
			target = PRODUCER,
			value = 0,
			build = "M1_CapsuleBench",
			blurb = "Builds the Moon Rock Bench!",
		},
		{
			id = "m1_crater_lamps",
			area = 1,
			name = "Crater Lamps",
			kind = "Build",
			cost = 6.5 * SCALE,
			requires = "m1_capsule_bench",
			target = PRODUCER,
			value = 0.1,
			build = "M1_CraterLamps",
			blurb = "+10% Bench Moon Rocks",
		},
		{
			id = "m1_moon_tools",
			area = 1,
			name = "Moon Tools",
			kind = "Multiplier",
			cost = 45 * SCALE,
			requires = "m1_crater_lamps",
			target = PRODUCER,
			value = 2,
			build = "M1_MoonTools",
			blurb = "x2 Bench Moon Rocks",
		},
		{
			id = "m1_flag_pole",
			area = 1,
			name = "Flag Pole",
			kind = "Build",
			cost = 58 * SCALE,
			requires = "m1_moon_tools",
			target = PRODUCER,
			value = 0.1,
			build = "M1_FlagPole",
			blurb = "+10% Bench Moon Rocks",
		},
		{
			id = "m1_solar_panels",
			area = 1,
			name = "Solar Panels",
			kind = "Multiplier",
			cost = 700 * SCALE,
			requires = "m1_flag_pole",
			target = PRODUCER,
			value = 3,
			build = "M1_SolarPanels",
			blurb = "x3 Bench Moon Rocks",
		},
		{
			id = "m1_air_pump",
			area = 1,
			name = "Air Pump",
			kind = "Speed",
			cost = 1200 * SCALE,
			requires = "m1_solar_panels",
			target = PRODUCER,
			value = 2,
			build = "M1_AirPump",
			blurb = "x2 Bench speed",
		},
		{
			id = "m1_bleep_bot",
			area = 1,
			name = "Bleep Bot",
			kind = "Manager",
			cost = 3000 * SCALE,
			requires = "m1_air_pump",
			target = PRODUCER,
			build = "M1_BleepBot",
			blurb = "Bleep Bot runs the bench for you!",
		},
		{
			id = "m1_crater_rail",
			area = 1,
			name = "Crater Railing",
			kind = "Build",
			cost = 3500 * SCALE,
			requires = "m1_bleep_bot",
			target = PRODUCER,
			value = 0.1,
			build = "M1_CraterRail",
			blurb = "+10% Bench Moon Rocks",
		},
		{
			id = "m1_open_diner",
			area = 1,
			name = "Open the Cosmic Diner",
			kind = "Unlock",
			cost = 10500 * SCALE,
			requires = "m1_crater_rail",
			unlocks = 2,
			build = "M2_EntryArch",
			blurb = "Opens the Cosmic Diner",
		},
	},
}

return area
