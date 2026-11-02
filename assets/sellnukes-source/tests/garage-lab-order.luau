--!strict
--[[
	Garage Lab buy order (owner R122, 2026-11-01 spec §2.2 "automation by minute ~4").

	Why: live first-run players hand-clicked the Workbench ~11 min before Uncle Atom (the first
	Manager, then pad 7) and the tutorial lost 74 % between step 6 and 7. Uncle Atom moved to pad 4:
		Workbench -> Tool Wall -> Glow Lamp -> Uncle Atom -> Garage Door -> Mini Reactor ->
		Paint Station -> Driveway -> Open the Nuke Stand
	Pad ids are SAVE DATA and never change, so the move must be invisible to existing saves.

	Proves on the shipped modules (TycoonConfig / TycoonLogic / ProfileLogic / AreaLayouts):
	  1. The new order: Area 1's PadOrder, the `requires` chain (each pad needs the one before; the
	     Nuke Stand's first pad still needs the Unlock), Uncle Atom = pad 4 = the Workbench's
	     Manager pad, prices strictly rising, PadIndex matches.
	  2. The pad row keeps its layout contract in the new order: buy order alternates either side
	     of the arch, moving outward (AreaLayouts/Area01 `pads`), every spot used once.
	  3. Migration safety for every OLD-order save (each prefix of the old order, with cash and a
	     levelled Workbench): it loads unchanged through the real save path (toSave -> migrate),
	     keeps every owned pad and its cash, already-owned pads are refused as "owned" (never
	     charged twice), Uncle Atom is offered as soon as the Glow Lamp is owned, and buying the
	     offered pads always reaches the Nuke Stand (no soft-lock) without ever removing a pad,
	     lowering idle income, or automating before Uncle Atom is hired.

	Run: lune run tests/garage-lab-order.luau
]]

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local TycoonConfig = loader.load("src/shared/Config/TycoonConfig")
local TycoonLogic = loader.load("src/shared/Tycoon/TycoonLogic")
local ProfileLogic = loader.load("src/server/Economy/ProfileLogic")
local Area01Layout = loader.load("src/shared/Config/AreaLayouts/Area01")

local checks = 0
local function check(ok: boolean, message: string)
	assert(ok, message)
	checks += 1
end

local WORKBENCH = "p1_workbench"

-- The R122 buy order (new) and the order every save before 0.8.0 was built in (old).
local NEW_ORDER = {
	"a1_workbench",
	"a1_tool_wall",
	"a1_glow_lamp",
	"a1_uncle_atom",
	"a1_garage_door",
	"a1_mini_reactor",
	"a1_paint_station",
	"a1_driveway",
	"a1_open_stand",
}
local OLD_ORDER = {
	"a1_workbench",
	"a1_tool_wall",
	"a1_glow_lamp",
	"a1_garage_door",
	"a1_mini_reactor",
	"a1_paint_station",
	"a1_uncle_atom",
	"a1_driveway",
	"a1_open_stand",
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
	local areaPads = TycoonConfig.AreaPads[1]
	check(#areaPads == #NEW_ORDER, "Garage Lab still has 9 pads")
	local previousCost = -1
	for index, id in NEW_ORDER do
		local pad = areaPads[index]
		check(pad.id == id, `Garage Lab pad {index} is {id} (got {pad.id})`)
		check(TycoonConfig.PadOrder[index].id == id, `PadOrder[{index}] = {id}`)
		check(TycoonConfig.PadIndex[id] == index, `PadIndex[{id}] = {index}`)
		local expectedRequires = if index == 1 then nil else NEW_ORDER[index - 1]
		check(pad.requires == expectedRequires, `{id} requires {tostring(expectedRequires)}`)
		check(pad.cost > previousCost, `{id} costs more than the pad before it`)
		previousCost = pad.cost
	end
	local uncle = TycoonConfig.PadsById.a1_uncle_atom
	check(uncle.kind == "Manager" and uncle.target == WORKBENCH, "Uncle Atom automates the Workbench")
	check(TycoonConfig.ManagerPadOf[WORKBENCH] == "a1_uncle_atom", "the Workbench's Manager pad is Uncle Atom")
	-- The first Manager of the whole game is pad 4 (right after the Glow Lamp).
	local firstManager: number? = nil
	for index, pad in TycoonConfig.PadOrder do
		if pad.kind == "Manager" then
			firstManager = index
			break
		end
	end
	check(firstManager == 4, "the first Manager is pad 4")
	-- The chain across the area border is untouched.
	check(TycoonConfig.AreaPads[2][1].requires == "a1_open_stand", "the Nuke Stand still opens from the Unlock pad")
	-- Every pad of the old order still exists (same ids, same set).
	local seen: { [string]: boolean } = {}
	for _, id in OLD_ORDER do
		check(TycoonConfig.PadsById[id] ~= nil, `old-order pad {id} still exists`)
		seen[id] = true
	end
	for _, id in NEW_ORDER do
		check(seen[id] == true, `{id} was a pad before R122 (no new / renamed ids)`)
	end
end

--------------------------------------------------------------------------------------------------
-- 2. The pad row follows the buy order (alternating sides, moving outward)
--------------------------------------------------------------------------------------------------
do
	local spots = Area01Layout.pads
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
-- 3. Old-order saves (every prefix of the old order) migrate safely
--------------------------------------------------------------------------------------------------
do
	local CASH = 123_456.5
	for owned = 0, #OLD_ORDER do
		local tag = `old save with {owned} pad(s)`
		-- A save as a pre-R122 server wrote it: the old-order prefix, a levelled Workbench, cash.
		local before = ProfileLogic.defaultProfile()
		before.cash = CASH
		for index = 1, owned do
			before.tycoon.pads[OLD_ORDER[index]] = true
		end
		if owned >= 1 then
			before.tycoon.producers[WORKBENCH] = 10 + owned * 3
		end
		before.tycoon.tutorialStep = math.min(owned, 7)
		local profile, status = ProfileLogic.migrate(ProfileLogic.toSave(before))
		check(status == "current", `{tag}: loads as a current save ({tostring(status)})`)
		local state = profile.tycoon

		-- Keeps every pad, its levels and its cash.
		check(
			table.concat(ownedIds(state.pads), ",") == table.concat(ownedIds(before.tycoon.pads), ","),
			`{tag}: keeps exactly its pads`
		)
		check(profile.cash == CASH, `{tag}: keeps its cash`)
		check(
			TycoonLogic.levelOf(state, WORKBENCH) == TycoonLogic.levelOf(before.tycoon, WORKBENCH),
			`{tag}: keeps its Workbench level`
		)
		local bought, total = TycoonLogic.areaProgress(state, 1)
		check(bought == owned and total == #NEW_ORDER, `{tag}: area progress {bought} / {total}`)

		-- Owned pads are never offered or purchasable again (the server charges nothing twice).
		for index = 1, owned do
			local ok, reason = TycoonLogic.padAvailable(state, OLD_ORDER[index])
			check(not ok and reason == "owned", `{tag}: {OLD_ORDER[index]} refused as owned`)
		end

		-- Uncle Atom is on offer as soon as the Glow Lamp is owned (and he is not yet hired).
		local hasLamp = state.pads.a1_glow_lamp == true
		local hasUncle = state.pads.a1_uncle_atom == true
		local offered: { [string]: boolean } = {}
		for _, pad in TycoonLogic.nextPads(state) do
			offered[pad.id] = true
			check(TycoonLogic.padAvailable(state, pad.id), `{tag}: offered pad {pad.id} is buyable`)
		end
		if hasLamp and not hasUncle then
			check(offered.a1_uncle_atom == true, `{tag}: Uncle Atom is offered`)
			check(TycoonLogic.nextPads(state)[1].id == "a1_uncle_atom", `{tag}: Uncle Atom is offered first`)
		end
		check(
			TycoonLogic.isAutomated(state, WORKBENCH) == hasUncle,
			`{tag}: the Workbench runs by itself exactly when Uncle Atom is hired`
		)
		if owned < #OLD_ORDER then
			check(next(offered) ~= nil, `{tag}: always has a pad to buy (no soft-lock)`)
		end

		-- Buying whatever is offered (first offer each time) always reaches the Nuke Stand: no pad is
		-- removed, idle income never drops, and the Workbench automates only with Uncle Atom.
		local steps = 0
		while state.pads.a1_open_stand ~= true do
			steps += 1
			check(steps <= #NEW_ORDER, `{tag}: reaches the Nuke Stand within {#NEW_ORDER} purchases`)
			local nextPad = TycoonLogic.nextPads(state)[1]
			check(nextPad ~= nil and nextPad.area == 1, `{tag}: a Garage Lab pad is on offer`)
			local ownedBefore = #ownedIds(state.pads)
			local income = TycoonLogic.incomePerSecond(state, nil)
			check(TycoonLogic.applyPad(state, nextPad.id), `{tag}: {nextPad.id} applies`)
			check(#ownedIds(state.pads) == ownedBefore + 1, `{tag}: {nextPad.id} adds a pad, removes none`)
			check(
				TycoonLogic.incomePerSecond(state, nil) >= income,
				`{tag}: buying {nextPad.id} never lowers idle income`
			)
			check(
				TycoonLogic.isAutomated(state, WORKBENCH) == (state.pads.a1_uncle_atom == true),
				`{tag}: automation follows Uncle Atom after {nextPad.id}`
			)
		end
		for _, id in NEW_ORDER do
			check(state.pads[id] == true, `{tag}: owns {id} at the end`)
		end
		check(TycoonLogic.areaUnlocked(state, 2), `{tag}: the Nuke Stand opens`)
	end

	-- The two saves the spec names explicitly.
	local function oldSave(ids: { string }): any
		local state = TycoonLogic.newState()
		for _, id in ids do
			state.pads[id] = true
		end
		state.producers[WORKBENCH] = 25
		return state
	end
	local toReactor = oldSave({ "a1_workbench", "a1_tool_wall", "a1_glow_lamp", "a1_garage_door", "a1_mini_reactor" })
	local offer = TycoonLogic.nextPads(toReactor)
	check(#offer == 2, "workbench..mini_reactor: two pads on offer")
	check(offer[1].id == "a1_uncle_atom" and offer[2].id == "a1_paint_station", "Uncle Atom + Paint Station")
	local toPaint = oldSave({
		"a1_workbench",
		"a1_tool_wall",
		"a1_glow_lamp",
		"a1_garage_door",
		"a1_mini_reactor",
		"a1_paint_station",
	})
	offer = TycoonLogic.nextPads(toPaint)
	check(#offer == 2, "workbench..paint_station: two pads on offer")
	check(offer[1].id == "a1_uncle_atom" and offer[2].id == "a1_driveway", "Uncle Atom + Driveway")
	-- Buying the Driveway first is allowed, and Uncle Atom stays on offer next to the Unlock.
	TycoonLogic.applyPad(toPaint, "a1_driveway")
	offer = TycoonLogic.nextPads(toPaint)
	check(offer[1].id == "a1_uncle_atom" and offer[2].id == "a1_open_stand", "Uncle Atom stays on offer")
end

print(`[garage-lab-order] {checks} checks passed`)
