--!strict
--[[
	Area 4 — Glow Rock Mine (spec §3.4).

	Stud cave with glowing green crystals and mine carts.

	Producer: Glow Rock Drill (`p4_glow_drill`). Pads in their fixed linear buy order; every pad requires the one
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
local SCALE = 916000

-- Producer id (SAVE DATA).
local PRODUCER = "p4_glow_drill"

local area: TycoonTypes.AreaConfig = {
	index = 4,
	id = "glow_rock_mine",
	name = "Glow Rock Mine",
	producer = {
		id = PRODUCER,
		name = "Glow Rock Drill",
		area = 4,
		builtBy = "a4_mine_entrance",
		-- Level 1 -> 2 costs baseCost; each further level costs costGrowth x the previous one.
		baseCost = 3 * SCALE,
		costGrowth = 1.2,
		-- Cash per cycle at level 1 (linear in level) and seconds per cycle before speed-ups.
		baseRevenue = 42000,
		baseCycle = 2.5,
		clickable = true,
	},
	pads = {
		{
			id = "a4_mine_entrance",
			area = 4,
			name = "Mine Entrance",
			kind = "Build",
			cost = 10 * SCALE,
			requires = "a3_dig_mine",
			target = PRODUCER,
			value = 0,
			build = "A4_MineEntrance",
			blurb = "Builds the Glow Rock Drill!",
		},
		{
			id = "a4_support_beams",
			area = 4,
			name = "Support Beams",
			kind = "Build",
			cost = 12 * SCALE,
			requires = "a4_mine_entrance",
			target = PRODUCER,
			value = 0.1,
			build = "A4_SupportBeams",
			blurb = "+10% Glow Drill cash",
		},
		{
			id = "a4_pickaxe_crew",
			area = 4,
			name = "Pickaxe Crew",
			kind = "Multiplier",
			cost = 45 * SCALE,
			requires = "a4_support_beams",
			target = PRODUCER,
			value = 2,
			build = "A4_PickaxeCrew",
			blurb = "x2 Glow Drill cash",
		},
		{
			id = "a4_cart_track",
			area = 4,
			name = "Cart Track",
			kind = "Speed",
			cost = 120 * SCALE,
			requires = "a4_pickaxe_crew",
			target = PRODUCER,
			value = 2,
			build = "A4_CartTrack",
			blurb = "x2 Glow Drill speed",
		},
		{
			id = "a4_drill_rig",
			area = 4,
			name = "Drill Rig",
			kind = "Multiplier",
			cost = 700 * SCALE,
			requires = "a4_cart_track",
			target = PRODUCER,
			value = 3,
			build = "A4_DrillRig",
			blurb = "x3 Glow Drill cash",
		},
		{
			id = "a4_crystal_lamps",
			area = 4,
			name = "Crystal Lamps",
			kind = "Build",
			cost = 800 * SCALE,
			requires = "a4_drill_rig",
			target = PRODUCER,
			value = 0.1,
			build = "A4_CrystalLamps",
			blurb = "+10% Glow Drill cash",
		},
		{
			id = "a4_glow_vein",
			area = 4,
			name = "Glow Vein",
			kind = "Multiplier",
			cost = 9100 * SCALE,
			requires = "a4_crystal_lamps",
			target = PRODUCER,
			value = 4,
			build = "A4_GlowVein",
			blurb = "x4 Glow Drill cash",
		},
		{
			id = "a4_foreman",
			area = 4,
			name = "Foreman",
			kind = "Manager",
			cost = 10000 * SCALE,
			requires = "a4_glow_vein",
			target = PRODUCER,
			build = "A4_Foreman",
			blurb = "Automates the Glow Drill",
		},
		{
			id = "a4_build_lab",
			area = 4,
			name = "Build the Lab",
			kind = "Unlock",
			cost = 30000 * SCALE,
			requires = "a4_foreman",
			unlocks = 5,
			build = "A5_EntryArch",
			blurb = "Opens the Enrichment Lab",
		},
	},
}

return area
