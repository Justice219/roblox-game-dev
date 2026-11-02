--!strict
--[[
	Area 1 — Garage Lab (spec §3.1).

	Tiny suburban garage with pegboard tools and a bubbling "Mini Reactor" on a workbench. The tutorial IS this area:
	the free Workbench pad is tutorial step 1, the player clicks to make the first Pocket Nukes, then upgrades and
	automates with Uncle Atom.

	Producer: Pocket Nuke Workbench (`p1_workbench`). Pads in their fixed linear buy order; every pad requires the one
	before it (the first pad requires the previous area's Unlock pad), so `requires` forms one chain
	across the whole game. TycoonConfig validates the chain at load.

	Buy order (owner R122, 2026-11-01 — "automation by minute ~4"): Workbench -> Tool Wall -> Glow Lamp ->
	UNCLE ATOM (the Manager) -> Garage Door -> Mini Reactor -> Paint Station -> Driveway -> Open the Nuke Stand.
	Uncle Atom used to be pad 7 (after the Paint Station): live first-run players hand-clicked ~11 min before
	the Workbench ran by itself and 74 % of them left at that tutorial step. Old-order saves stay valid: pads are
	stored by id, so a save that already owns later pads keeps them and simply gets Uncle Atom offered next to
	its next pad (tests/tycoon-logic.luau "R122 migration").

	SAVE DATA: every pad `id` and the producer `id` are stored in profiles. Never rename or reuse them.
	`build` is the build-group key the world builders map to Blender meshes.

	Costs are multiples of SCALE, this area's cost unit (a few seconds of the income the player has
	when the area opens). Other areas put their pads on the producer's level-cost curve (price =
	weight x L x 3 x costGrowth^(L-1) SCALE units at a designated level L); the Garage Lab is
	shaped BY HAND (R122, re-paced R137) around the pinned $10 level curve.

	Owner R137 (2026-11-01, "do whatever you want and fix") — the first two minutes: live data showed
	~50 % of first sessions end within 3 min and the first pads far apart (Workbench 0.7 min -> Tool
	Wall 1.7 min, a full minute of $1 clicks -> Glow Lamp 2.3 -> Uncle Atom). The head is now cheap so
	something new builds every ~10-40 s in the greedy sim: Tool Wall $11 (0.48 min, was 1.1), Glow
	Lamp $19 (0.64, was 1.6), Uncle Atom $300 (1.22, was 1.9), Garage Door $340 (1.9, was 2.5).
	Why the head and the rest of the area are shaped the way they are (scratch harness around the
	real sim):
		* The Tool Wall stays dearer than the $10 first upgrade (R65: the tutorial teaches UPGRADE
		  first; tests/tycoon-logic.luau). A lone +10 % pad that dear loses to the levels until
		  level ~5 (0.6 min), so the Glow Lamp is cheap enough that the greedy player values the
		  pair (Tool Wall + Glow Lamp <= ~$31) and buys the Tool Wall at Workbench level 3, the
		  Glow Lamp right after.
		* The Garage Door (+10 %) must stay under ~$355 (it flips at $360): dearer, it loses to the
		  Workbench levels until the level-25 milestone (bought at ~3.0 min, a ~100 s wait after
		  Uncle Atom).
		* The Mini Reactor is bought right after the level-25 milestone (~3.2 min) and the Driveway
		  (+10 %) right before level ~40 (~5.6 min); a Driveway dearer than ~$40K slips past the
		  level-50 milestone (~10 min, a 5 min wait). Those two milestones, not the prices, pin the
		  tail once the head is fast.
		* Steps from the Garage Door on are <= 7x (was 8.5x Garage Door -> Mini Reactor), so the
		  Paint Station can cost at most ~7x the Mini Reactor.
	Together that caps the area at ~7.0 min with no wait above ~85 s (8.0 min would need a ~2 min
	save for the Unlock or a 95-100 s gap). Area 2 opens ~1.0 min sooner; the income it opens with
	is unchanged ($1.42K/s, Workbench level 40), so every later area plays exactly as before.
	Asserted by tests/economy-sim.luau OPENING_CHECKS (area 1: Manager by 1.5 min, never 45 s without
	a new pad in the first 2 min, no wait > 85 s). Pad order unchanged.

	SCALE (pace) and baseRevenue (level-1 producer = 1 % of arrival income) are written by the
	pacing simulator: `lune run tests/economy-sim.luau --tune --write --upto 1`, which never picks a
	SCALE that breaks the opening limits (OPENING_CHECKS), so it cannot stretch the area back to
	8 min: today it settles on SCALE 6.67 (7.1 min, 84 s; Tool Wall + Glow Lamp $31, right at the
	edge, Paint Station 7.1x the Mini Reactor). 6.49 is kept by hand: round prices, steps <= 7x and
	a $1 margin under the pair limit. TycoonConfig rounds each price to 2 significant digits at
	load (and to whole dollars under $100). Formulas and retuning: docs/economy.md "Garage Lab
	opening".
]]

local TycoonTypes = require(script.Parent.Parent.Parent.Tycoon.TycoonTypes)

-- Cost unit (tuned for the pacing target; see header).
local SCALE = 6.49

-- Owner R65 (2026-10-31): "I'd make like the first upgrade $10." The Workbench's level 1 -> 2 is
-- pinned to exactly $10 (ten $1 clicks), so it is NOT 3 x SCALE like every other area's producer;
-- the tuner only moves SCALE (the pads), never this. docs/economy.md "Garage Lab opening".
local FIRST_UPGRADE_COST = 10

-- Producer id (SAVE DATA).
local PRODUCER = "p1_workbench"

local area: TycoonTypes.AreaConfig = {
	index = 1,
	id = "garage_lab",
	name = "Garage Lab",
	producer = {
		id = PRODUCER,
		name = "Pocket Nuke Workbench",
		area = 1,
		builtBy = "a1_workbench",
		-- Level 1 -> 2 costs baseCost; each further level costs costGrowth x the previous one.
		-- Pinned (R65): $10, $12, $15, $18, $21, ... (see FIRST_UPGRADE_COST).
		baseCost = FIRST_UPGRADE_COST,
		costGrowth = 1.2,
		-- Cash per cycle at level 1 (linear in level) and seconds per cycle before speed-ups.
		baseRevenue = 1,
		baseCycle = 1,
		clickable = true,
	},
	pads = {
		{
			id = "a1_workbench",
			area = 1,
			name = "Workbench",
			kind = "Build",
			cost = 0, -- free: tutorial step 1
			target = PRODUCER,
			value = 0,
			build = "A1_Workbench",
			blurb = "Builds the Pocket Nuke Workbench!",
		},
		{
			id = "a1_tool_wall",
			area = 1,
			name = "Tool Wall",
			kind = "Build",
			cost = 1.7 * SCALE, -- $11: ~0.48 min in the pacing sim (greedy run 1), Workbench level 3 (R137)
			requires = "a1_workbench",
			target = PRODUCER,
			value = 0.1,
			build = "A1_ToolWall",
			blurb = "+10% Workbench cash",
		},
		{
			id = "a1_glow_lamp",
			area = 1,
			name = "Glow Lamp",
			kind = "Multiplier",
			cost = 3 * SCALE, -- $19: ~0.64 min (R137; was $260 at 1.6); Tool Wall + Glow Lamp <= ~$31 (header)
			requires = "a1_tool_wall",
			target = PRODUCER,
			value = 2,
			build = "A1_GlowLamp",
			blurb = "x2 Workbench cash",
		},
		{
			id = "a1_uncle_atom",
			area = 1,
			name = "Uncle Atom",
			kind = "Manager",
			cost = 46 * SCALE, -- $300: ~1.22 min — the Workbench runs by itself from here (R122 / R137)
			requires = "a1_glow_lamp",
			target = PRODUCER,
			build = "A1_UncleAtom",
			blurb = "Automates the Workbench",
		},
		{
			id = "a1_garage_door",
			area = 1,
			name = "Garage Door",
			kind = "Build",
			cost = 52 * SCALE, -- $340: ~1.9 min; keep under ~$355 (header)
			requires = "a1_uncle_atom",
			target = PRODUCER,
			value = 0.1,
			build = "A1_GarageDoor",
			blurb = "+10% Workbench cash",
		},
		{
			id = "a1_mini_reactor",
			area = 1,
			name = "Mini Reactor",
			kind = "Speed",
			cost = 360 * SCALE, -- $2.3K: ~3.2 min, right after the level-25 milestone (6.8x the Garage Door)
			requires = "a1_garage_door",
			target = PRODUCER,
			value = 2,
			build = "A1_MiniReactor",
			blurb = "x2 Workbench speed",
		},
		{
			id = "a1_paint_station",
			area = 1,
			name = "Paint Station",
			kind = "Multiplier",
			cost = 2500 * SCALE, -- $16K: ~4.3 min (7.0x the Mini Reactor)
			requires = "a1_mini_reactor",
			target = PRODUCER,
			value = 3,
			build = "A1_PaintStation",
			blurb = "x3 Workbench cash",
		},
		{
			id = "a1_driveway",
			area = 1,
			name = "Driveway",
			kind = "Build",
			cost = 5400 * SCALE, -- $35K: ~5.6 min; keep under ~$40K (header)
			requires = "a1_paint_station",
			target = PRODUCER,
			value = 0.1,
			build = "A1_Driveway",
			blurb = "+10% Workbench cash",
		},
		{
			id = "a1_open_stand",
			area = 1,
			name = "Open the Nuke Stand",
			kind = "Unlock",
			cost = 17000 * SCALE, -- $110K: ~7.0 min (area target 8; R137 header)
			requires = "a1_driveway",
			unlocks = 2,
			build = "A2_EntryArch",
			blurb = "Opens the Nuke Stand",
		},
	},
}

return area
