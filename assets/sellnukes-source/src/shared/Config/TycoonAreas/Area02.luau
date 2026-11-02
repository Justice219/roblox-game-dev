--!strict
--[[
	Area 2 — Nuke Stand (spec §3.2).

	Roadside wooden stand with a striped awning and a "Fresh Nukes!" sign. The Neon Sign pad also unlocks renaming
	the sign (feature "StandRename"; the server filters the text with TextService before anyone else sees it).

	Producer: Nuke Stand (`p2_nuke_stand`). Pads in their fixed linear buy order; every pad requires the one
	before it (the first pad requires the previous area's Unlock pad), so `requires` forms one chain
	across the whole game. TycoonConfig validates the chain at load.

	SAVE DATA: every pad `id` and the producer `id` are stored in profiles. Never rename or reuse them.
	`build` is the build-group key the world builders map to Blender meshes.

	Costs are multiples of SCALE, this area's cost unit (a few seconds of the income the player has
	when the area opens). Until R137 the pads sat on the producer's level-cost curve (price = weight x
	L x 3 x costGrowth^(L-1) SCALE units at a designated level L) with the Unlock at 3x the pad before
	it; since R137 they are shaped by hand around that curve (below). SCALE (pace) and baseRevenue (level-1
	producer = 1 % of arrival income) are written by the pacing simulator:
	`lune run tests/economy-sim.luau --tune --write`. TycoonConfig rounds each price to 2
	significant digits at load. Formulas and retuning: docs/economy.md.

	Owner R137 (2026-11-01, "do whatever you want and fix") — the R130 BoomDash treatment for the
	Nuke Stand. Live first-run data: 150 players opened the area, 102 bought the Cashier Bot (its
	Manager, pad 8 of 10, ~6.5 sim min after the area opened, behind 5.8x Tip Jar -> Neon Sign and
	4x Picket Fence -> Cashier Bot price jumps) and 82 opened BoomDash Delivery. New buy order:
	Counter -> Awning -> Cash Register -> CASHIER BOT -> Tip Jar -> Neon Sign -> Cooler ->
	Picket Fence -> Picnic Tables -> Start BoomDash. The multiples below are shaped by hand with a
	scratch harness around the pacing sim (SCALE unchanged at 269, so the Counter, the Stand Egg,
	the Front Tower and every Nuke Stand level keep their prices):
		* Cashier Bot hired ~0.85 min after the area opens (was ~6.5);
		* the later pads ~1.5-2.2 min apart, longest wait ~132 s (was ~189 s, the Unlock save);
		* largest step between pads 4.3x (was 5.9x);
		* the Unlock costs ~2.5x the pad before it, not the usual 3x: the save for it IS the area's
		  longest wait (Unlock price / income at the Unlock), and at 3x it stays at 155-170 s
		  whatever the other pads cost;
		* area length unchanged (12.5 sim min, -16 % of the 15 target since R89/R90) and the same
		  income at the Unlock ($38.6K/s, Nuke Stand level 39), so BoomDash plays exactly as before.
	Asserted by tests/economy-sim.luau OPENING_CHECKS (area 2). Pad ids unchanged: saves bought in
	the old order keep every pad (tests/stand-order.luau; docs/tycoon-server.md "Nuke Stand order").
	Retuning note: a plain `--tune --write` targets 15 min and would move SCALE; re-pace this area
	with a scratch copy of the sim (docs/economy.md "Nuke Stand order (R137)").
]]

local TycoonTypes = require(script.Parent.Parent.Parent.Tycoon.TycoonTypes)

-- Cost unit (tuned for the pacing target; see header; kept at 269 by the R137 re-pace).
local SCALE = 269

-- Producer id (SAVE DATA).
local PRODUCER = "p2_nuke_stand"

local area: TycoonTypes.AreaConfig = {
	index = 2,
	id = "nuke_stand",
	name = "Nuke Stand",
	producer = {
		id = PRODUCER,
		name = "Nuke Stand",
		area = 2,
		builtBy = "a2_counter",
		-- Level 1 -> 2 costs baseCost; each further level costs costGrowth x the previous one.
		baseCost = 3 * SCALE,
		costGrowth = 1.2,
		-- Cash per cycle at level 1 (linear in level) and seconds per cycle before speed-ups.
		baseRevenue = 19,
		baseCycle = 1.5,
		clickable = true,
	},
	pads = {
		{
			id = "a2_counter",
			area = 2,
			name = "Counter",
			kind = "Build",
			cost = 10 * SCALE, -- $2.7K: ~0.1 min after the area opens (R137 sim)
			requires = "a1_open_stand",
			target = PRODUCER,
			value = 0,
			build = "A2_Counter",
			blurb = "Builds the Nuke Stand!",
		},
		{
			id = "a2_awning",
			area = 2,
			name = "Awning",
			kind = "Build",
			cost = 12 * SCALE, -- $3.2K: ~0.2 min
			requires = "a2_counter",
			target = PRODUCER,
			value = 0.1,
			build = "A2_Awning",
			blurb = "+10% Nuke Stand cash",
		},
		{
			id = "a2_cash_register",
			area = 2,
			name = "Cash Register",
			kind = "Multiplier",
			cost = 45 * SCALE, -- $12K: ~0.3 min
			requires = "a2_awning",
			target = PRODUCER,
			value = 2,
			build = "A2_CashRegister",
			blurb = "x2 Nuke Stand cash",
		},
		{
			-- Owner R137: the Manager comes right after the first burst (was pad 8 at 6000 x SCALE).
			id = "a2_cashier_bot",
			area = 2,
			name = "Cashier Bot",
			kind = "Manager",
			cost = 190 * SCALE, -- $51K: ~0.85 min — the Nuke Stand runs by itself from here (R137)
			requires = "a2_cash_register",
			target = PRODUCER,
			build = "A2_CashierBot",
			blurb = "Automates the Nuke Stand",
		},
		{
			id = "a2_tip_jar",
			area = 2,
			name = "Tip Jar",
			kind = "Multiplier",
			cost = 460 * SCALE, -- $120K: ~2.3 min
			requires = "a2_cashier_bot",
			target = PRODUCER,
			value = 2,
			build = "A2_TipJar",
			blurb = "x2 Nuke Stand cash",
		},
		{
			id = "a2_neon_sign",
			area = 2,
			name = "Neon Sign",
			kind = "Multiplier",
			cost = 920 * SCALE, -- $250K: ~4.1 min
			requires = "a2_tip_jar",
			target = PRODUCER,
			value = 3,
			feature = "StandRename",
			build = "A2_NeonSign",
			blurb = "x3 Nuke Stand cash + rename your sign",
		},
		{
			id = "a2_cooler",
			area = 2,
			name = "Cooler",
			kind = "Speed",
			cost = 3200 * SCALE, -- $860K: ~6.3 min, right after the level-25 milestone
			requires = "a2_neon_sign",
			target = PRODUCER,
			value = 2,
			build = "A2_Cooler",
			blurb = "x2 Nuke Stand speed",
		},
		{
			id = "a2_picket_fence",
			area = 2,
			name = "Picket Fence",
			kind = "Build",
			cost = 4600 * SCALE, -- $1.2M: ~8.3 min
			requires = "a2_cooler",
			target = PRODUCER,
			value = 0.1,
			build = "A2_PicketFence",
			blurb = "+10% Nuke Stand cash",
		},
		{
			id = "a2_picnic_tables",
			area = 2,
			name = "Picnic Tables",
			kind = "Build",
			cost = 7700 * SCALE, -- $2.1M: ~10.3 min
			requires = "a2_picket_fence",
			target = PRODUCER,
			value = 0.1,
			build = "A2_PicnicTables",
			blurb = "+10% Nuke Stand cash",
		},
		{
			id = "a2_start_boomdash",
			area = 2,
			name = "Start BoomDash",
			kind = "Unlock",
			cost = 19000 * SCALE, -- $5.1M: ~12.5 min (~2.5x the pad before; header)
			requires = "a2_picnic_tables",
			unlocks = 3,
			build = "A3_EntryArch",
			blurb = "Opens the BoomDash Delivery",
		},
	},
}

return area
