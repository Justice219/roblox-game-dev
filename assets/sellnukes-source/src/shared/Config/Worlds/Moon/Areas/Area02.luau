--!strict
--[[
	Moon Base area 2 — Cosmic Diner (R69–R71 spec §2.2, World 3).

	A retro chrome-and-neon diner where cute alien customers order pocket nukes with their milkshakes. Zip
	Zorp, a three-eyed waiter on roller skates, runs it once hired.

	Producer: Cosmic Diner (`mp2_cosmic_diner`). Pads in their fixed linear buy order; every pad requires the one
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
local SCALE = 201

-- Producer id (SAVE DATA).
local PRODUCER = "mp2_cosmic_diner"

local area: TycoonTypes.AreaConfig = {
	index = 2,
	id = "cosmic_diner",
	name = "Cosmic Diner",
	producer = {
		id = PRODUCER,
		name = "Cosmic Diner",
		area = 2,
		builtBy = "m2_diner_counter",
		-- Level 1 -> 2 costs baseCost; each further level costs costGrowth x the previous one.
		baseCost = 3 * SCALE,
		costGrowth = 1.2,
		-- Moon Rocks per cycle at level 1 (linear in level) and seconds per cycle before speed-ups.
		baseRevenue = 19,
		baseCycle = 1.5,
		clickable = true,
	},
	pads = {
		{
			id = "m2_diner_counter",
			area = 2,
			name = "Diner Counter",
			kind = "Build",
			cost = 10 * SCALE,
			requires = "m1_open_diner",
			target = PRODUCER,
			value = 0,
			build = "M2_DinerCounter",
			blurb = "Builds the Cosmic Diner!",
		},
		{
			id = "m2_neon_sign",
			area = 2,
			name = "Neon Sign",
			kind = "Build",
			cost = 12 * SCALE,
			requires = "m2_diner_counter",
			target = PRODUCER,
			value = 0.1,
			build = "M2_NeonSign",
			blurb = "+10% Diner Moon Rocks",
		},
		{
			id = "m2_star_register",
			area = 2,
			name = "Star Register",
			kind = "Multiplier",
			cost = 45 * SCALE,
			requires = "m2_neon_sign",
			target = PRODUCER,
			value = 2,
			build = "M2_StarRegister",
			blurb = "x2 Diner Moon Rocks",
		},
		{
			id = "m2_booth_seats",
			area = 2,
			name = "Booth Seats",
			kind = "Build",
			cost = 58 * SCALE,
			requires = "m2_star_register",
			target = PRODUCER,
			value = 0.1,
			build = "M2_BoothSeats",
			blurb = "+10% Diner Moon Rocks",
		},
		{
			id = "m2_rocket_jukebox",
			area = 2,
			name = "Rocket Jukebox",
			kind = "Multiplier",
			cost = 700 * SCALE,
			requires = "m2_booth_seats",
			target = PRODUCER,
			value = 3,
			build = "M2_RocketJukebox",
			blurb = "x3 Diner Moon Rocks",
		},
		{
			id = "m2_shake_machine",
			area = 2,
			name = "Milkshake Machine",
			kind = "Speed",
			cost = 1200 * SCALE,
			requires = "m2_rocket_jukebox",
			target = PRODUCER,
			value = 2,
			build = "M2_ShakeMachine",
			blurb = "x2 Diner speed",
		},
		{
			id = "m2_crater_tables",
			area = 2,
			name = "Crater Tables",
			kind = "Build",
			cost = 1500 * SCALE,
			requires = "m2_shake_machine",
			target = PRODUCER,
			value = 0.1,
			build = "M2_CraterTables",
			blurb = "+10% Diner Moon Rocks",
		},
		{
			id = "m2_zip_zorp",
			area = 2,
			name = "Zip Zorp",
			kind = "Manager",
			cost = 6000 * SCALE,
			requires = "m2_crater_tables",
			target = PRODUCER,
			build = "M2_ZipZorp",
			blurb = "Zip Zorp runs the diner for you!",
		},
		{
			id = "m2_landing_lights",
			area = 2,
			name = "Landing Lights",
			kind = "Build",
			cost = 8900 * SCALE,
			requires = "m2_zip_zorp",
			target = PRODUCER,
			value = 0.1,
			build = "M2_LandingLights",
			blurb = "+10% Diner Moon Rocks",
		},
		{
			id = "m2_call_ufos",
			area = 2,
			name = "Call the UFO Couriers",
			kind = "Unlock",
			cost = 27000 * SCALE,
			requires = "m2_landing_lights",
			unlocks = 3,
			build = "M3_EntryArch",
			blurb = "Opens UFO Delivery",
		},
	},
}

return area
