--!strict
--[[
	BoomDash Delivery buy order (owner R130, 2026-11-01 — the R122 Garage Lab treatment for area 3).

	Why: live first-run data (2026-11-01, docs/owner-requests.md R129 / R130): the Dispatcher (the
	BoomDash Manager) was pad 8 of 9, reached after a 6:20 wait, so players hand-clicked the
	BoomDash ~13 min; the Mobile App cost 8.3x the GPS; 41 players opened the area and 4 reached the
	Glow Rock Mine. The Dispatcher moved to pad 4 and the prices were re-paced:
		HQ Shell -> Scooter Rack -> Scooters -> Dispatcher -> GPS -> Mobile App -> Delivery Van ->
		Parking Lot -> Dig the Mine
	Pad ids are SAVE DATA and never change, so the move must be invisible to existing saves.

	Proves on the shipped modules (TycoonConfig / TycoonLogic / ProfileLogic / AreaLayouts):
	  1. The new order: area 3's pads, the `requires` chain (each pad needs the one before; the
	     HQ Shell still needs the Nuke Stand's Unlock, the Mine's first pad still needs Dig the
	     Mine), the Dispatcher = pad 4 = the BoomDash's Manager pad, prices strictly rising.
	  2. The pad row keeps its layout contract in the new order: buy order alternates either side
	     of the arch, moving outward (AreaLayouts/Area03 `pads`), every spot used once.
	  3. Migration safety for every OLD-order save (areas 1–2 finished + each prefix of the old
	     area-3 order, with cash and levelled producers): it loads unchanged through the real save
	     path (toSave -> migrate), keeps every owned pad, level and its cash, owned pads are refused
	     as "owned" (never charged twice), the Dispatcher is offered (first) as soon as the Scooters
	     are owned, and buying the offered pads always opens the Glow Rock Mine (no soft-lock)
	     without ever removing a pad, lowering idle income, or automating the BoomDash before the
	     Dispatcher is hired.

	Run: lune run tests/boomdash-order.luau
]]

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local TycoonConfig = loader.load("src/shared/Config/TycoonConfig")
local TycoonLogic = loader.load("src/shared/Tycoon/TycoonLogic")
local ProfileLogic = loader.load("src/server/Economy/ProfileLogic")
local Area03Layout = loader.load("src/shared/Config/AreaLayouts/Area03")

local checks = 0
local function check(ok: boolean, message: string)
	assert(ok, message)
	checks += 1
end

local BOOMDASH = "p3_boomdash"

-- The R130 buy order (new) and the order every save before it was built in (old).
local NEW_ORDER = {
	"a3_hq_shell",
	"a3_scooter_rack",
	"a3_scooters",
	"a3_dispatcher",
	"a3_gps",
	"a3_mobile_app",
	"a3_delivery_van",
	"a3_parking_lot",
	"a3_dig_mine",
}
local OLD_ORDER = {
	"a3_hq_shell",
	"a3_scooter_rack",
	"a3_scooters",
	"a3_gps",
	"a3_mobile_app",
	"a3_delivery_van",
	"a3_parking_lot",
	"a3_dispatcher",
	"a3_dig_mine",
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
	local areaPads = TycoonConfig.AreaPads[3]
	check(#areaPads == #NEW_ORDER, "BoomDash Delivery still has 9 pads")
	local lastArea2 = TycoonConfig.AreaPads[2][#TycoonConfig.AreaPads[2]].id
	local previousCost = -1
	for index, id in NEW_ORDER do
		local pad = areaPads[index]
		check(pad.id == id, `BoomDash pad {index} is {id} (got {pad.id})`)
		local expectedRequires = if index == 1 then lastArea2 else NEW_ORDER[index - 1]
		check(pad.requires == expectedRequires, `{id} requires {tostring(expectedRequires)}`)
		check(pad.cost > previousCost, `{id} costs more than the pad before it`)
		previousCost = pad.cost
	end
	local dispatcher = TycoonConfig.PadsById.a3_dispatcher
	check(dispatcher.kind == "Manager" and dispatcher.target == BOOMDASH, "the Dispatcher automates the BoomDash")
	check(TycoonConfig.ManagerPadOf[BOOMDASH] == "a3_dispatcher", "the BoomDash's Manager pad is the Dispatcher")
	-- The Mine's first pad still opens from Dig the Mine (the chain across the area border).
	check(TycoonConfig.AreaPads[4][1].requires == "a3_dig_mine", "the Glow Rock Mine still opens from Dig the Mine")
	-- No price step in the area is above 5x the one before (the old Mobile App was 8.3x).
	for index = 2, #areaPads - 1 do
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
		check(seen[id] == true, `{id} was a pad before R130 (no new / renamed ids)`)
	end
end

--------------------------------------------------------------------------------------------------
-- 2. The pad row follows the buy order (alternating sides, moving outward)
--------------------------------------------------------------------------------------------------
do
	local spots = Area03Layout.pads
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
-- 3. Old-order saves (areas 1–2 done + every prefix of the old area-3 order) migrate safely
--------------------------------------------------------------------------------------------------
do
	local CASH = 5_432_100.25
	local EARLIER_PRODUCERS = { p1_workbench = 60, p2_nuke_stand = 45 }
	for owned = 0, #OLD_ORDER do
		local tag = `old save with {owned} BoomDash pad(s)`
		-- A save as a pre-R130 server wrote it: areas 1–2 finished, the old area-3 prefix, cash.
		local before = ProfileLogic.defaultProfile()
		before.cash = CASH
		for areaIndex = 1, 2 do
			for _, pad in TycoonConfig.AreaPads[areaIndex] do
				before.tycoon.pads[pad.id] = true
			end
		end
		for producerId, level in EARLIER_PRODUCERS do
			before.tycoon.producers[producerId] = level
		end
		for index = 1, owned do
			before.tycoon.pads[OLD_ORDER[index]] = true
		end
		if owned >= 1 then
			before.tycoon.producers[BOOMDASH] = 10 + owned * 3
		end
		before.tycoon.area = if owned == #OLD_ORDER then 4 else 3
		local profile, status = ProfileLogic.migrate(ProfileLogic.toSave(before))
		check(status == "current", `{tag}: loads as a current save ({tostring(status)})`)
		local state = profile.tycoon

		-- Keeps every pad, its levels and its cash.
		check(
			table.concat(ownedIds(state.pads), ",") == table.concat(ownedIds(before.tycoon.pads), ","),
			`{tag}: keeps exactly its pads`
		)
		check(profile.cash == CASH, `{tag}: keeps its cash`)
		for producerId, level in EARLIER_PRODUCERS do
			check(TycoonLogic.levelOf(state, producerId) == level, `{tag}: keeps {producerId} level {level}`)
		end
		check(
			TycoonLogic.levelOf(state, BOOMDASH) == TycoonLogic.levelOf(before.tycoon, BOOMDASH),
			`{tag}: keeps its BoomDash level`
		)
		local bought, total = TycoonLogic.areaProgress(state, 3)
		check(bought == owned and total == #NEW_ORDER, `{tag}: area progress {bought} / {total}`)

		-- Owned pads are never offered or purchasable again (the server charges nothing twice).
		for index = 1, owned do
			local ok, reason = TycoonLogic.padAvailable(state, OLD_ORDER[index])
			check(not ok and reason == "owned", `{tag}: {OLD_ORDER[index]} refused as owned`)
		end

		-- The Dispatcher is on offer (first) as soon as the Scooters are owned and he is not hired.
		local hasScooters = state.pads.a3_scooters == true
		local hasDispatcher = state.pads.a3_dispatcher == true
		local offered: { [string]: boolean } = {}
		for _, pad in TycoonLogic.nextPads(state) do
			offered[pad.id] = true
			check(TycoonLogic.padAvailable(state, pad.id), `{tag}: offered pad {pad.id} is buyable`)
		end
		if hasScooters and not hasDispatcher then
			check(offered.a3_dispatcher == true, `{tag}: the Dispatcher is offered`)
			check(TycoonLogic.nextPads(state)[1].id == "a3_dispatcher", `{tag}: the Dispatcher is offered first`)
		end
		check(
			TycoonLogic.isAutomated(state, BOOMDASH) == hasDispatcher,
			`{tag}: the BoomDash runs by itself exactly when the Dispatcher is hired`
		)
		if owned < #OLD_ORDER then
			check(next(offered) ~= nil, `{tag}: always has a pad to buy (no soft-lock)`)
		end

		-- Buying whatever is offered (first offer each time) always opens the Glow Rock Mine: no pad
		-- is removed, idle income never drops, and the BoomDash automates only with the Dispatcher.
		local steps = 0
		while state.pads.a3_dig_mine ~= true do
			steps += 1
			check(steps <= #NEW_ORDER, `{tag}: reaches Dig the Mine within {#NEW_ORDER} purchases`)
			local nextPad = TycoonLogic.nextPads(state)[1]
			check(nextPad ~= nil and nextPad.area == 3, `{tag}: a BoomDash pad is on offer`)
			local ownedBefore = #ownedIds(state.pads)
			local income = TycoonLogic.incomePerSecond(state, nil)
			check(TycoonLogic.applyPad(state, nextPad.id), `{tag}: {nextPad.id} applies`)
			check(#ownedIds(state.pads) == ownedBefore + 1, `{tag}: {nextPad.id} adds a pad, removes none`)
			check(
				TycoonLogic.incomePerSecond(state, nil) >= income,
				`{tag}: buying {nextPad.id} never lowers idle income`
			)
			check(
				TycoonLogic.isAutomated(state, BOOMDASH) == (state.pads.a3_dispatcher == true),
				`{tag}: automation follows the Dispatcher after {nextPad.id}`
			)
		end
		check(TycoonLogic.areaUnlocked(state, 4), `{tag}: the Glow Rock Mine opens`)
		-- A save that opened the Mine before hiring the Dispatcher still gets him offered first.
		if state.pads.a3_dispatcher ~= true then
			check(TycoonLogic.nextPads(state)[1].id == "a3_dispatcher", `{tag}: the Dispatcher stays on offer`)
		end
	end

	-- The two saves a player is most likely to be in: stopped before the old Mobile App jump, and
	-- the old 6:20 wait before the Dispatcher.
	local function oldSave(ids: { string }): any
		local state = TycoonLogic.newState()
		for areaIndex = 1, 2 do
			for _, pad in TycoonConfig.AreaPads[areaIndex] do
				state.pads[pad.id] = true
			end
		end
		for _, id in ids do
			state.pads[id] = true
		end
		state.producers[BOOMDASH] = 20
		return state
	end
	local toGps = oldSave({ "a3_hq_shell", "a3_scooter_rack", "a3_scooters", "a3_gps" })
	local offer = TycoonLogic.nextPads(toGps)
	check(#offer == 2, "hq..gps: two pads on offer")
	check(offer[1].id == "a3_dispatcher" and offer[2].id == "a3_mobile_app", "Dispatcher + Mobile App")
	local toParking = oldSave({
		"a3_hq_shell",
		"a3_scooter_rack",
		"a3_scooters",
		"a3_gps",
		"a3_mobile_app",
		"a3_delivery_van",
		"a3_parking_lot",
	})
	offer = TycoonLogic.nextPads(toParking)
	check(#offer == 2, "hq..parking_lot: two pads on offer")
	check(offer[1].id == "a3_dispatcher" and offer[2].id == "a3_dig_mine", "Dispatcher + Dig the Mine")
end

print(`[boomdash-order] {checks} checks passed`)
