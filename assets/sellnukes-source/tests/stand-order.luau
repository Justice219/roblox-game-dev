--!strict
--[[
	Nuke Stand buy order (owner R137, 2026-11-01 — the R130 BoomDash treatment for area 2).

	Why: live first-run data (2026-11-01, docs/owner-requests.md R135–R137): the Cashier Bot (the
	Nuke Stand Manager) was pad 8 of 10, hired ~6.5 sim minutes after the area opened, behind a 5.8x
	price jump (Tip Jar -> Neon Sign) and a 4x one (Picket Fence -> Cashier Bot); 150 players opened
	the area, 102 hired the Cashier Bot and 82 opened BoomDash Delivery. The Cashier Bot moved to
	pad 4 and the prices were re-paced (largest step 4.3x, the Unlock ~2.5x the pad before it):
		Counter -> Awning -> Cash Register -> Cashier Bot -> Tip Jar -> Neon Sign -> Cooler ->
		Picket Fence -> Picnic Tables -> Start BoomDash
	Pad ids are SAVE DATA and never change, so the move must be invisible to existing saves.

	Proves on the shipped modules (TycoonConfig / TycoonLogic / ProfileLogic / AreaLayouts):
	  1. The new order: area 2's pads, the `requires` chain (each pad needs the one before; the
	     Counter still needs the Garage Lab's Unlock, BoomDash's first pad still needs Start
	     BoomDash), the Cashier Bot = pad 4 = the Nuke Stand's Manager pad, prices strictly rising,
	     no step above 5x, the Neon Sign still unlocks the sign rename.
	  2. The pad row keeps its layout contract in the new order: buy order alternates either side
	     of the arch, moving outward (AreaLayouts/Area02 `pads`), every spot used once.
	  3. Migration safety for every OLD-order save (area 1 finished + each prefix of the old area-2
	     order, with cash and levelled producers): it loads unchanged through the real save path
	     (toSave -> migrate), keeps every owned pad, level and its cash, owned pads are refused as
	     "owned" (never charged twice), the Cashier Bot is offered (first) as soon as the Cash
	     Register is owned, and buying the offered pads always opens BoomDash Delivery (no
	     soft-lock) without ever removing a pad, lowering idle income, or automating the Nuke Stand
	     before the Cashier Bot is hired.

	Run: lune run tests/stand-order.luau
]]

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local TycoonConfig = loader.load("src/shared/Config/TycoonConfig")
local TycoonLogic = loader.load("src/shared/Tycoon/TycoonLogic")
local ProfileLogic = loader.load("src/server/Economy/ProfileLogic")
local Area02Layout = loader.load("src/shared/Config/AreaLayouts/Area02")

local checks = 0
local function check(ok: boolean, message: string)
	assert(ok, message)
	checks += 1
end

local STAND = "p2_nuke_stand"

-- The R137 buy order (new) and the order every save before it was built in (old).
local NEW_ORDER = {
	"a2_counter",
	"a2_awning",
	"a2_cash_register",
	"a2_cashier_bot",
	"a2_tip_jar",
	"a2_neon_sign",
	"a2_cooler",
	"a2_picket_fence",
	"a2_picnic_tables",
	"a2_start_boomdash",
}
local OLD_ORDER = {
	"a2_counter",
	"a2_awning",
	"a2_cash_register",
	"a2_tip_jar",
	"a2_neon_sign",
	"a2_cooler",
	"a2_picket_fence",
	"a2_cashier_bot",
	"a2_picnic_tables",
	"a2_start_boomdash",
}

-- Sorted pad ids a state owns (for set comparisons in messages).
local function ownedIds(pads: { [string]: any }): { string }
	local ids = {}
	for id, owned in pads do
		if owned == true then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	return ids
end

--------------------------------------------------------------------------------------------------
-- 1. The new order and its prerequisite chain
--------------------------------------------------------------------------------------------------
do
	local areaPads = TycoonConfig.AreaPads[2]
	check(#areaPads == #NEW_ORDER, "the Nuke Stand still has 10 pads")
	local lastArea1 = TycoonConfig.AreaPads[1][#TycoonConfig.AreaPads[1]].id
	local previousCost = -1
	for index, id in NEW_ORDER do
		local pad = areaPads[index]
		check(pad.id == id, `Nuke Stand pad {index} is {id} (got {pad.id})`)
		local expectedRequires = if index == 1 then lastArea1 else NEW_ORDER[index - 1]
		check(pad.requires == expectedRequires, `{id} requires {tostring(expectedRequires)}`)
		check(pad.cost > previousCost, `{id} costs more than the pad before it`)
		previousCost = pad.cost
	end
	local cashierBot = TycoonConfig.PadsById.a2_cashier_bot
	check(cashierBot.kind == "Manager" and cashierBot.target == STAND, "the Cashier Bot automates the Nuke Stand")
	check(TycoonConfig.ManagerPadOf[STAND] == "a2_cashier_bot", "the Nuke Stand's Manager pad is the Cashier Bot")
	-- The Neon Sign still carries the sign rename (feature StandRename), wherever it sits now.
	check(TycoonConfig.PadsById.a2_neon_sign.feature == "StandRename", "the Neon Sign still unlocks the rename")
	-- BoomDash's first pad still opens from Start BoomDash (the chain across the area border).
	check(TycoonConfig.AreaPads[3][1].requires == "a2_start_boomdash", "BoomDash still opens from Start BoomDash")
	-- No price step in the area is above 5x the one before (the old Neon Sign was 5.8x the Tip Jar).
	for index = 2, #areaPads do
		local ratio = areaPads[index].cost / areaPads[index - 1].cost
		check(ratio <= 5, `{areaPads[index].id} costs {string.format("%.1f", ratio)}x the pad before it (<= 5x)`)
	end
	-- Every pad of the old order still exists (same ids, same set).
	local seen: { [string]: boolean } = {}
	for _, id in OLD_ORDER do
		check(TycoonConfig.PadsById[id] ~= nil, `old-order pad {id} still exists`)
		seen[id] = true
	end
	for _, id in NEW_ORDER do
		check(seen[id] == true, `{id} was a pad before R137 (no new / renamed ids)`)
	end
end

--------------------------------------------------------------------------------------------------
-- 2. The pad row follows the buy order (alternating sides, moving outward)
--------------------------------------------------------------------------------------------------
do
	local spots = Area02Layout.pads
	local used: { [string]: boolean } = {}
	local previousSide = 0
	local previousReach = 0
	for index, id in NEW_ORDER do
		local spot = spots[id]
		check(spot ~= nil, `{id} has a pad spot`)
		local key = `{spot.X},{spot.Z}`
		check(not used[key], `{id} has its own spot`)
		used[key] = true
		local side = if spot.X < 0 then -1 else 1
		check(index == 1 or side ~= previousSide, `{id} is across the arch from the pad before it`)
		check(math.abs(spot.X) >= previousReach, `{id} is no closer to the arch than the pad before it`)
		previousSide, previousReach = side, math.abs(spot.X)
	end
end

--------------------------------------------------------------------------------------------------
-- 3. Old-order saves (area 1 done + every prefix of the old area-2 order) migrate safely
--------------------------------------------------------------------------------------------------
do
	local CASH = 123_456.75
	local WORKBENCH_LEVEL = 45
	for owned = 0, #OLD_ORDER do
		local tag = `old save with {owned} Nuke Stand pad(s)`
		-- A save as a pre-R137 server wrote it: area 1 finished, the old area-2 prefix, cash.
		local before = ProfileLogic.defaultProfile()
		before.cash = CASH
		for _, pad in TycoonConfig.AreaPads[1] do
			before.tycoon.pads[pad.id] = true
		end
		before.tycoon.producers.p1_workbench = WORKBENCH_LEVEL
		for index = 1, owned do
			before.tycoon.pads[OLD_ORDER[index]] = true
		end
		if owned >= 1 then
			before.tycoon.producers[STAND] = 10 + owned * 3
		end
		before.tycoon.area = if owned == #OLD_ORDER then 3 else 2
		local profile, status = ProfileLogic.migrate(ProfileLogic.toSave(before))
		check(status == "current", `{tag}: loads as a current save ({tostring(status)})`)
		local state = profile.tycoon

		-- Keeps every pad, its levels and its cash.
		check(
			table.concat(ownedIds(state.pads), ",") == table.concat(ownedIds(before.tycoon.pads), ","),
			`{tag}: keeps exactly its pads`
		)
		check(profile.cash == CASH, `{tag}: keeps its cash`)
		check(TycoonLogic.levelOf(state, "p1_workbench") == WORKBENCH_LEVEL, `{tag}: keeps its Workbench level`)
		check(
			TycoonLogic.levelOf(state, STAND) == TycoonLogic.levelOf(before.tycoon, STAND),
			`{tag}: keeps its Nuke Stand level`
		)
		local bought, total = TycoonLogic.areaProgress(state, 2)
		check(bought == owned and total == #NEW_ORDER, `{tag}: area progress {bought} / {total}`)
		-- A save that owned the Neon Sign keeps its sign rename.
		check(
			TycoonLogic.hasFeature(state, "StandRename") == (state.pads.a2_neon_sign == true),
			`{tag}: the sign rename follows the Neon Sign`
		)

		-- Owned pads are never offered or purchasable again (the server charges nothing twice).
		for index = 1, owned do
			local ok, reason = TycoonLogic.padAvailable(state, OLD_ORDER[index])
			check(not ok and reason == "owned", `{tag}: {OLD_ORDER[index]} refused as owned`)
		end

		-- The Cashier Bot is on offer (first) as soon as the Cash Register is owned and he is not hired.
		local hasRegister = state.pads.a2_cash_register == true
		local hasBot = state.pads.a2_cashier_bot == true
		local offered: { [string]: boolean } = {}
		for _, pad in TycoonLogic.nextPads(state) do
			offered[pad.id] = true
			check(TycoonLogic.padAvailable(state, pad.id), `{tag}: offered pad {pad.id} is buyable`)
		end
		if hasRegister and not hasBot then
			check(offered.a2_cashier_bot == true, `{tag}: the Cashier Bot is offered`)
			check(TycoonLogic.nextPads(state)[1].id == "a2_cashier_bot", `{tag}: the Cashier Bot is offered first`)
		end
		check(
			TycoonLogic.isAutomated(state, STAND) == hasBot,
			`{tag}: the Nuke Stand runs by itself exactly when the Cashier Bot is hired`
		)
		if owned < #OLD_ORDER then
			check(next(offered) ~= nil, `{tag}: always has a pad to buy (no soft-lock)`)
		end

		-- Buying whatever is offered (first offer each time) always opens BoomDash Delivery: no pad
		-- is removed, idle income never drops, and the Nuke Stand automates only with the Cashier Bot.
		local steps = 0
		while state.pads.a2_start_boomdash ~= true do
			steps += 1
			check(steps <= #NEW_ORDER, `{tag}: reaches Start BoomDash within {#NEW_ORDER} purchases`)
			local nextPad = TycoonLogic.nextPads(state)[1]
			check(nextPad ~= nil and nextPad.area == 2, `{tag}: a Nuke Stand pad is on offer`)
			local ownedBefore = #ownedIds(state.pads)
			local income = TycoonLogic.incomePerSecond(state, nil)
			check(TycoonLogic.applyPad(state, nextPad.id), `{tag}: {nextPad.id} applies`)
			check(#ownedIds(state.pads) == ownedBefore + 1, `{tag}: {nextPad.id} adds a pad, removes none`)
			check(
				TycoonLogic.incomePerSecond(state, nil) >= income,
				`{tag}: buying {nextPad.id} never lowers idle income`
			)
			check(
				TycoonLogic.isAutomated(state, STAND) == (state.pads.a2_cashier_bot == true),
				`{tag}: automation follows the Cashier Bot after {nextPad.id}`
			)
		end
		check(TycoonLogic.areaUnlocked(state, 3), `{tag}: BoomDash Delivery opens`)
		-- A save that opened BoomDash before hiring the Cashier Bot still gets him offered first.
		if state.pads.a2_cashier_bot ~= true then
			check(TycoonLogic.nextPads(state)[1].id == "a2_cashier_bot", `{tag}: the Cashier Bot stays on offer`)
		end
	end

	-- The saves a player is most likely to be in: stopped at the old 5.8x Neon Sign jump (Tip Jar
	-- owned), and in the old wait right before the Cashier Bot (Picket Fence owned).
	local function oldSave(ids: { string }): any
		local state = TycoonLogic.newState()
		for _, pad in TycoonConfig.AreaPads[1] do
			state.pads[pad.id] = true
		end
		state.area = 2
		for _, id in ids do
			state.pads[id] = true
		end
		state.producers.p1_workbench = 40
		state.producers[STAND] = 20
		return state
	end
	local toTipJar = oldSave({ "a2_counter", "a2_awning", "a2_cash_register", "a2_tip_jar" })
	local offer = TycoonLogic.nextPads(toTipJar)
	check(#offer == 2, "counter..tip_jar: two pads on offer")
	check(offer[1].id == "a2_cashier_bot" and offer[2].id == "a2_neon_sign", "Cashier Bot + Neon Sign")
	local toFence = oldSave({
		"a2_counter",
		"a2_awning",
		"a2_cash_register",
		"a2_tip_jar",
		"a2_neon_sign",
		"a2_cooler",
		"a2_picket_fence",
	})
	offer = TycoonLogic.nextPads(toFence)
	check(#offer == 2, "counter..picket_fence: two pads on offer")
	check(offer[1].id == "a2_cashier_bot" and offer[2].id == "a2_picnic_tables", "Cashier Bot + Picnic Tables")
	check(not TycoonLogic.isAutomated(toFence, STAND), "counter..picket_fence: the Nuke Stand is still manual")
end

print(`[stand-order] {checks} checks passed`)
