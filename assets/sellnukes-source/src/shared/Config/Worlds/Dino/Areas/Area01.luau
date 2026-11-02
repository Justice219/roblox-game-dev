--!strict
--[[
	Dino Valley area 1 — Cave Workshop (World 2 spec §6.2).

	A mossy cliff with a cave mouth, flickering torches and a stone bench where cave kids snap together
	pebble-sized toy nukes. The Dino tycoon starts here: the free Stone Bench builds the producer, the player clicks
	it for the first Bones, then upgrades and automates with Rocky Raptor.

	Producer: Pebble Nuke Bench (`dp1_pebble_bench`). Pads in their fixed linear buy order; every pad requires the one
	before it (the first pad requires the previous Dino area's Unlock pad), so `requires` forms one chain
	across the whole Dino Valley tycoon. EconomyIndex validates the chain and the id rules at load:
	pads d<area>_name, producers dp<area>_name, build keys D<area>_Name (an Unlock pad builds the NEXT
	area's D<area+1>_EntryArch, which resolves to Worlds/Dino/Layouts/Area<area+1>.base).

	SAVE DATA: every pad `id` and the producer `id` are stored in profile.worlds.dino. Never rename or reuse
	them. `build` is the build-group key the Dino area art builders map to Blender meshes.

	Costs are multiples of SCALE, this area's cost unit, priced exactly like Nuke Town (docs/economy.md
	"Pricing structure"): builder pad = 10 x SCALE, the other pads on the producer's level-cost curve
	(weight x L x 3 x 1.2^(L-1) SCALE units at a designated level L, forced to rise >= 15 % along the chain),
	the Unlock pad = 3x the pad before it. SCALE (pace) and baseRevenue (level-1 producer = 1 % of arrival
	income) are written by the pacing simulator:
	`lune run tests/economy-sim.luau --world dino --tune --write`. EconomyIndex rounds each price to 2
	significant digits at load. Formulas, pacing table and retuning: docs/economy.md ("Dino Valley").
]]

local TycoonTypes = require(script.Parent.Parent.Parent.Parent.Parent.Tycoon.TycoonTypes)

-- Cost unit (tuned for the pacing target; see header).
local SCALE = 6.15

-- Producer id (SAVE DATA).
local PRODUCER = "dp1_pebble_bench"

local area: TycoonTypes.AreaConfig = {
	index = 1,
	id = "cave_workshop",
	name = "Cave Workshop",
	producer = {
		id = PRODUCER,
		name = "Pebble Nuke Bench",
		area = 1,
		builtBy = "d1_stone_bench",
		-- Level 1 -> 2 costs baseCost; each further level costs costGrowth x the previous one.
		baseCost = 3 * SCALE,
		costGrowth = 1.2,
		-- Bones per cycle at level 1 (linear in level) and seconds per cycle before speed-ups.
		baseRevenue = 1,
		baseCycle = 1,
		clickable = true,
	},
	pads = {
		{
			id = "d1_stone_bench",
			area = 1,
			name = "Stone Bench",
			kind = "Build",
			cost = 0, -- free: the first Dino purchase
			target = PRODUCER,
			value = 0,
			build = "D1_StoneBench",
			blurb = "Builds the Pebble Nuke Bench!",
		},
		{
			id = "d1_torch_wall",
			area = 1,
			name = "Torch Wall",
			kind = "Build",
			cost = 6.5 * SCALE,
			requires = "d1_stone_bench",
			target = PRODUCER,
			value = 0.1,
			build = "D1_TorchWall",
			blurb = "+10% Bench Bones",
		},
		{
			id = "d1_bone_tools",
			area = 1,
			name = "Bone Tools",
			kind = "Multiplier",
			cost = 45 * SCALE,
			requires = "d1_torch_wall",
			target = PRODUCER,
			value = 2,
			build = "D1_BoneTools",
			blurb = "x2 Bench Bones",
		},
		{
			id = "d1_cave_paintings",
			area = 1,
			name = "Cave Paintings",
			kind = "Build",
			cost = 58 * SCALE,
			requires = "d1_bone_tools",
			target = PRODUCER,
			value = 0.1,
			build = "D1_CavePaintings",
			blurb = "+10% Bench Bones",
		},
		{
			id = "d1_fire_pit",
			area = 1,
			name = "Cozy Fire Pit",
			kind = "Multiplier",
			cost = 700 * SCALE,
			requires = "d1_cave_paintings",
			target = PRODUCER,
			value = 3,
			build = "D1_FirePit",
			blurb = "x3 Bench Bones",
		},
		{
			id = "d1_leaf_bellows",
			area = 1,
			name = "Leaf Bellows",
			kind = "Speed",
			cost = 1200 * SCALE,
			requires = "d1_fire_pit",
			target = PRODUCER,
			value = 2,
			build = "D1_LeafBellows",
			blurb = "x2 Bench speed",
		},
		{
			id = "d1_rocky_raptor",
			area = 1,
			name = "Rocky Raptor",
			kind = "Manager",
			cost = 3000 * SCALE,
			requires = "d1_leaf_bellows",
			target = PRODUCER,
			build = "D1_RockyRaptor",
			blurb = "Rocky runs the bench for you!",
		},
		{
			id = "d1_log_fence",
			area = 1,
			name = "Log Fence",
			kind = "Build",
			cost = 3500 * SCALE,
			requires = "d1_rocky_raptor",
			target = PRODUCER,
			value = 0.1,
			build = "D1_LogFence",
			blurb = "+10% Bench Bones",
		},
		{
			id = "d1_open_market",
			area = 1,
			name = "Open the Fern Market",
			kind = "Unlock",
			cost = 10500 * SCALE,
			requires = "d1_log_fence",
			unlocks = 2,
			build = "D2_EntryArch",
			blurb = "Opens the Fern Market",
		},
	},
}

return area
