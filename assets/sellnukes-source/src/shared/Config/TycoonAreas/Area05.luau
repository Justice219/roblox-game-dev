--!strict
--[[
	Area 5 — Enrichment Lab (spec §3.5).

	White clean-room lab with spinning centrifuges and bubbling vats.

	Producer: Centrifuge Row (`p5_centrifuge`). Pads in their fixed linear buy order; every pad requires the one
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
local SCALE = 5.84e7

-- Producer id (SAVE DATA).
local PRODUCER = "p5_centrifuge"

local area: TycoonTypes.AreaConfig = {
	index = 5,
	id = "enrichment_lab",
	name = "Enrichment Lab",
	producer = {
		id = PRODUCER,
		name = "Centrifuge Row",
		area = 5,
		builtBy = "a5_lab_shell",
		-- Level 1 -> 2 costs baseCost; each further level costs costGrowth x the previous one.
		baseCost = 3 * SCALE,
		costGrowth = 1.2,
		-- Cash per cycle at level 1 (linear in level) and seconds per cycle before speed-ups.
		baseRevenue = 2.1e6,
		baseCycle = 3,
		clickable = true,
	},
	pads = {
		{
			id = "a5_lab_shell",
			area = 5,
			name = "Lab Shell",
			kind = "Build",
			cost = 10 * SCALE,
			requires = "a4_build_lab",
			target = PRODUCER,
			value = 0,
			build = "A5_LabShell",
			blurb = "Builds the Centrifuge Row!",
		},
		{
			id = "a5_clean_room_floor",
			area = 5,
			name = "Clean Room Floor",
			kind = "Build",
			cost = 12 * SCALE,
			requires = "a5_lab_shell",
			target = PRODUCER,
			value = 0.1,
			build = "A5_CleanRoomFloor",
			blurb = "+10% Centrifuge cash",
		},
		{
			id = "a5_centrifuges",
			area = 5,
			name = "Centrifuges",
			kind = "Multiplier",
			cost = 45 * SCALE,
			requires = "a5_clean_room_floor",
			target = PRODUCER,
			value = 2,
			build = "A5_Centrifuges",
			blurb = "x2 Centrifuge cash",
		},
		{
			id = "a5_lab_coats",
			area = 5,
			name = "Lab Coats",
			kind = "Multiplier",
			cost = 120 * SCALE,
			requires = "a5_centrifuges",
			target = PRODUCER,
			value = 2,
			build = "A5_LabCoats",
			blurb = "x2 Centrifuge cash",
		},
		{
			id = "a5_computer_wall",
			area = 5,
			name = "Computer Wall",
			kind = "Speed",
			cost = 350 * SCALE,
			requires = "a5_lab_coats",
			target = PRODUCER,
			value = 2,
			build = "A5_ComputerWall",
			blurb = "x2 Centrifuge speed",
		},
		{
			id = "a5_glow_vats",
			area = 5,
			name = "Glow Vats",
			kind = "Multiplier",
			cost = 2400 * SCALE,
			requires = "a5_computer_wall",
			target = PRODUCER,
			value = 3,
			build = "A5_GlowVats",
			blurb = "x3 Centrifuge cash",
		},
		{
			id = "a5_safety_signs",
			area = 5,
			name = "Safety Signs",
			kind = "Build",
			cost = 2800 * SCALE,
			requires = "a5_glow_vats",
			target = PRODUCER,
			value = 0.1,
			build = "A5_SafetySigns",
			blurb = "+10% Centrifuge cash",
		},
		{
			id = "a5_head_scientist",
			area = 5,
			name = "Head Scientist",
			kind = "Manager",
			cost = 6000 * SCALE,
			requires = "a5_safety_signs",
			target = PRODUCER,
			build = "A5_HeadScientist",
			blurb = "Automates the Centrifuge",
		},
		{
			id = "a5_open_factory",
			area = 5,
			name = "Open the Factory",
			kind = "Unlock",
			cost = 18000 * SCALE,
			requires = "a5_head_scientist",
			unlocks = 6,
			build = "A6_EntryArch",
			blurb = "Opens the Rocket Factory",
		},
	},
}

return area
