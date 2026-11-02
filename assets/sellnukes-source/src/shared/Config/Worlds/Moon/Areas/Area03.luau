--!strict
--[[
	Moon Base area 3 — UFO Delivery (R69–R71 spec §2.2, World 3).

	A saucer depot with a glowing tractor-beam pad: little UFOs fly parcels of toy nukes in and out across the
	craters. Captain Glorp, a goggled pilot alien, takes over the deliveries.

	Producer: UFO Express (`mp3_ufo_express`). Pads in their fixed linear buy order; every pad requires the one
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
local SCALE = 11400

-- Producer id (SAVE DATA).
local PRODUCER = "mp3_ufo_express"

local area: TycoonTypes.AreaConfig = {
	index = 3,
	id = "ufo_delivery",
	name = "UFO Delivery",
	producer = {
		id = PRODUCER,
		name = "UFO Express",
		area = 3,
		builtBy = "m3_saucer_dock",
		-- Level 1 -> 2 costs baseCost; each further level costs costGrowth x the previous one.
		baseCost = 3 * SCALE,
		costGrowth = 1.2,
		-- Moon Rocks per cycle at level 1 (linear in level) and seconds per cycle before speed-ups.
		baseRevenue = 450,
		baseCycle = 2,
		clickable = true,
	},
	pads = {
		{
			id = "m3_saucer_dock",
			area = 3,
			name = "Saucer Dock",
			kind = "Build",
			cost = 10 * SCALE,
			requires = "m2_call_ufos",
			target = PRODUCER,
			value = 0,
			build = "M3_SaucerDock",
			blurb = "Builds the UFO Express!",
		},
		{
			id = "m3_tractor_beam",
			area = 3,
			name = "Tractor Beam",
			kind = "Build",
			cost = 12 * SCALE,
			requires = "m3_saucer_dock",
			target = PRODUCER,
			value = 0.1,
			build = "M3_TractorBeam",
			blurb = "+10% UFO Moon Rocks",
		},
		{
			id = "m3_parcel_pods",
			area = 3,
			name = "Parcel Pods",
			kind = "Multiplier",
			cost = 45 * SCALE,
			requires = "m3_tractor_beam",
			target = PRODUCER,
			value = 2,
			build = "M3_ParcelPods",
			blurb = "x2 UFO Moon Rocks",
		},
		{
			id = "m3_radar_dish",
			area = 3,
			name = "Radar Dish",
			kind = "Speed",
			cost = 120 * SCALE,
			requires = "m3_parcel_pods",
			target = PRODUCER,
			value = 2,
			build = "M3_RadarDish",
			blurb = "x2 UFO speed",
		},
		{
			id = "m3_ufo_fleet",
			area = 3,
			name = "UFO Fleet",
			kind = "Multiplier",
			cost = 700 * SCALE,
			requires = "m3_radar_dish",
			target = PRODUCER,
			value = 3,
			build = "M3_UfoFleet",
			blurb = "x3 UFO Moon Rocks",
		},
		{
			id = "m3_star_map",
			area = 3,
			name = "Star Map",
			kind = "Multiplier",
			cost = 3600 * SCALE,
			requires = "m3_ufo_fleet",
			target = PRODUCER,
			value = 4,
			build = "M3_StarMap",
			blurb = "x4 UFO Moon Rocks",
		},
		{
			id = "m3_launch_ring",
			area = 3,
			name = "Launch Ring",
			kind = "Build",
			cost = 4200 * SCALE,
			requires = "m3_star_map",
			target = PRODUCER,
			value = 0.1,
			build = "M3_LaunchRing",
			blurb = "+10% UFO Moon Rocks",
		},
		{
			id = "m3_captain_glorp",
			area = 3,
			name = "Captain Glorp",
			kind = "Manager",
			cost = 6000 * SCALE,
			requires = "m3_launch_ring",
			target = PRODUCER,
			build = "M3_CaptainGlorp",
			blurb = "Captain Glorp flies it for you!",
		},
		{
			id = "m3_mine_asteroids",
			area = 3,
			name = "Mine the Asteroids",
			kind = "Unlock",
			cost = 18000 * SCALE,
			requires = "m3_captain_glorp",
			unlocks = 4,
			build = "M4_EntryArch",
			blurb = "Opens the Asteroid Mine",
		},
	},
}

return area
