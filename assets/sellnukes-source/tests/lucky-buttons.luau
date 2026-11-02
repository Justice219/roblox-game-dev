--!strict
--[[
	Lucky Buttons regressions (owner R69; spec 2026-10-31-r69-moon-lucky-juice-design.md §1). Run:
		lune run tests/lucky-buttons
	Proves on the shipped modules (Shared/Config/LuckyButtonConfig, Shared/Tycoon/LuckyButtonLogic):
	  1. Config: eight kinds with unique ids, the spec's weights / free-paid split, every paid key
	     is a real MonetizationConfig product / pass, free boosts are real BoostConfig keys, the
	     analytics choice sets + "lucky" prompt source are allowlisted.
	  2. Rules: the first button of a session is free, New Player Mode = free only, caps (MaxLive /
	     MaxPaidLive), owned passes never offered, products that are not live never rolled, pack
	     only with a world Large pack, skip only with a next pad; the weighted pick follows weights.
	  3. Packs: every world's Large pack (Nuke Town CashLarge, Dino BonesLarge, any world added).
	  4. Schedule + rewards: delays inside the spec windows x the clamped multiplier; cash burst
	     floors, scales, never NaN; AFK; blink window; labels per currency style.
	  5. Placement: oriented-box distances, clearance, candidates inside the slot margins.
	  6. Claims: world / expiry / distance / height checks.
	  7. Wire: valid payloads round-trip, hostile payloads are refused (never error).
	  8. Edge arrow: always inside the safe rect, out of avoid rects, mirrored when behind.
	  9. Slot geometry (the real surface check from layout data — plot colliders are CanQuery =
	     false, so rays see nothing): slab / classify / inside / spotOk on synthetic boxes, then
	     EVERY world's real layouts (plot frame colliders, area colliders, MeshAssets pieces,
	     billboards) on two plots: every valid spot stands on the frame's ground collider, keeps
	     Clearance from pads / producer / billboards and never overlaps a collider or prop piece,
	     and most areas of every world have room.
	 10. Owner R122 DEAL card (no accidental purchase prompts): config (actions, KeepRadius >
	     ClaimRadius, per-button cap, the luckyDeal analytics key), canClaim's `radius` reach (BUY
	     works while the card is up, never beyond KeepRadius, hostile radii ignored), the client
	     state machine (show on walk-in, keep inside KeepRadius, hide past it; CLOSE / BUY keep it
	     away until the player walks out and back in; "away" / "expired" do not), a randomised walk
	     that never shows the card while far and never shows two at once, and the source: walk-in
	     claims of paid kinds never prompt (the prompt sits only behind the "buy" action).
]]
local Loader = require("./fixtures/RobloxLoader")
local roblox = require("@lune/roblox")
local loader = Loader.new()
local Config = loader.load("src/shared/Config/LuckyButtonConfig")
local Logic = loader.load("src/shared/Tycoon/LuckyButtonLogic")
local MonetizationConfig = loader.load("src/shared/Config/MonetizationConfig")
local BoostConfig = loader.load("src/shared/Config/BoostConfig")
local AnalyticsConfig = loader.load("src/shared/Config/AnalyticsConfig")
local PurchasePromptConfig = loader.load("src/shared/Config/PurchasePromptConfig")
local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")
local WorldLayout = loader.load("src/shared/Config/WorldLayout")

local Vector3 = roblox.Vector3
local Vector2 = roblox.Vector2

local checks = 0
local function ok(condition: boolean, label: string)
	checks += 1
	assert(condition, label)
end

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- 1. Config -----------------------------------------------------------------------------------------
local SPEC = {
	cash = { paid = false, weight = 38 },
	boost2x = { paid = false, weight = 14 },
	speed2x = { paid = false, weight = 8 },
	boost30 = { paid = true, weight = 14 },
	pass2x = { paid = true, weight = 9 },
	autoclick = { paid = true, weight = 4 },
	pack = { paid = true, weight = 8 },
	skip = { paid = true, weight = 5 },
}
local seen = {}
for _, kind in Config.Kinds do
	ok(seen[kind.id] == nil, `unique kind {kind.id}`)
	seen[kind.id] = true
	local spec = SPEC[kind.id]
	ok(spec ~= nil, `kind {kind.id} is in the spec`)
	ok(kind.paid == spec.paid and kind.weight == spec.weight, `{kind.id}: spec paid / weight`)
	ok(Config.byId(kind.id) == kind, `byId {kind.id}`)
	if kind.paid then
		if kind.pass ~= nil then
			ok(MonetizationConfig.getPass(kind.pass) ~= nil, `{kind.id}: pass {kind.pass} exists`)
		elseif kind.product ~= nil then
			ok(MonetizationConfig.getProduct(kind.product) ~= nil, `{kind.id}: product {kind.product} exists`)
		else
			ok(kind.rule == "worldPack", `{kind.id}: a paid kind without a key resolves the world pack`)
		end
	else
		ok(kind.boost ~= nil or kind.income ~= nil, `{kind.id}: free kind grants something`)
		if kind.boost ~= nil then
			ok(
				BoostConfig.get ~= nil and BoostConfig.get(kind.boost) ~= nil
					or (BoostConfig.Boosts or {})[kind.boost] ~= nil,
				`{kind.id}: boost {kind.boost} exists`
			)
			ok(kind.seconds == 120, `{kind.id}: +120 s`)
		end
	end
end
for id in SPEC do
	ok(seen[id] == true, `spec kind {id} configured`)
end
ok(#Config.KindIds == 8, "eight kinds")
ok(Config.byId("nope") == nil and Config.byId(5) == nil, "unknown kind → nil")
local retention = AnalyticsConfig.Metrics.retention
local choice = "<" .. table.concat(Config.KindIds, "|") .. ">"
for _, family in { "luckySpawned", "luckyClaimed", "luckyPrompted", "luckyPurchased", "luckyExpired" } do
	ok(retention[`{family}:{choice}`] ~= nil, `analytics retention {family}:<kinds> documented`)
end
ok(table.find(PurchasePromptConfig.Sources, Config.PromptSource) ~= nil, "'lucky' prompt source allowlisted")

-- 2. Rules --------------------------------------------------------------------------------------------
local function ctx(over: { [string]: any }?): any
	local base: { [string]: any } = {
		firstOfSession = false,
		live = 0,
		livePaid = 0,
		newPlayerMode = false,
		owns = function(_key: string): boolean
			return false
		end,
		available = function(_key: string, _kind: string): boolean
			return true
		end,
		packKey = "CashLarge",
		hasNextPad = true,
	}
	for key, value in over or {} do
		base[key] = value
	end
	return base
end
local function ids(list: { any }): { [string]: boolean }
	local out = {}
	for _, kind in list do
		out[kind.id] = true
	end
	return out
end
do
	local all = ids(Logic.eligible(ctx()))
	for id in SPEC do
		ok(all[id] == true, `everything allowed in a normal context: {id}`)
	end
	local first = ids(Logic.eligible(ctx({ firstOfSession = true })))
	for id, spec in SPEC do
		ok((first[id] == true) == not spec.paid, `first button of a session is free only ({id})`)
	end
	local npm = ids(Logic.eligible(ctx({ newPlayerMode = true })))
	for id, spec in SPEC do
		ok((npm[id] == true) == not spec.paid, `New Player Mode: free only ({id})`)
	end
	ok(#Logic.eligible(ctx({ live = Config.MaxLive })) == 0, "MaxLive: nothing spawns")
	local onePaid = ids(Logic.eligible(ctx({ live = 1, livePaid = Config.MaxPaidLive })))
	for id, spec in SPEC do
		ok((onePaid[id] == true) == not spec.paid, `MaxPaidLive: no second paid button ({id})`)
	end
	local owned = ids(Logic.eligible(ctx({
		owns = function(key: string): boolean
			return key == "DoubleCash" or key == "AutoClicker"
		end,
	})))
	ok(not owned.pass2x and not owned.autoclick and owned.boost30, "owned passes are never offered")
	local soon = ids(Logic.eligible(ctx({
		available = function(key: string, _kind: string): boolean
			return key ~= "Cash2x30" and key ~= "SkipPad"
		end,
	})))
	ok(not soon.boost30 and not soon.skip and soon.pass2x, "products that are not live are never rolled")
	local noPack = ctx()
	noPack.packKey = nil
	ok(not ids(Logic.eligible(noPack)).pack, "no world pack → no pack button")
	ok(not ids(Logic.eligible(ctx({ hasNextPad = false }))).skip, "no next pad → no skip button")
	ok(Logic.roll(ctx({ live = 2 }), 0.5) == nil, "roll at the cap → nil")
	-- Weighted pick: the bands follow the weights.
	local list = Logic.eligible(ctx())
	local total = 0
	for _, kind in list do
		total += kind.weight
	end
	local counts: { [string]: number } = {}
	local samples = 20000
	for i = 0, samples - 1 do
		local kind = Logic.pick(list, (i + 0.5) / samples)
		counts[kind.id] = (counts[kind.id] or 0) + 1
	end
	for _, kind in list do
		local share = (counts[kind.id] or 0) / samples
		ok(math.abs(share - kind.weight / total) < 0.002, `pick share of {kind.id} follows its weight`)
	end
	ok(Logic.pick(list, 0 / 0) == list[1], "NaN uniform → the first band")
	ok(Logic.pick(list, 5) == list[#list], "uniform > 1 clamps to the last band")
	ok(Logic.pick({}, 0.3) == nil, "empty list → nil")
	-- productOf
	local key, kindType = Logic.productOf(Config.byId("pass2x"), nil)
	ok(key == "DoubleCash" and kindType == "pass", "pass2x prompts the DoubleCash pass")
	key, kindType = Logic.productOf(Config.byId("pack"), "BonesLarge")
	ok(key == "BonesLarge" and kindType == "product", "pack prompts the world pack")
	ok(Logic.productOf(Config.byId("cash"), "CashLarge") == nil, "free kinds prompt nothing")
end

-- 3. Packs ----------------------------------------------------------------------------------------------
ok(Logic.packFor("main", MonetizationConfig.Products, WorldsConfig.MAIN) == "CashLarge", "Nuke Town → CashLarge")
ok(Logic.packFor("dino", MonetizationConfig.Products, WorldsConfig.MAIN) == "BonesLarge", "Dino → BonesLarge")
for _, worldId in WorldsConfig.Order do
	local pack = Logic.packFor(worldId, MonetizationConfig.Products, WorldsConfig.MAIN)
	if pack ~= nil then
		local def = MonetizationConfig.getProduct(pack)
		ok(def ~= nil, `{worldId}: pack {pack} exists`)
		local ofWorld = if worldId == WorldsConfig.MAIN then def.world == nil else def.world == worldId
		ok(ofWorld, `{worldId}: pack {pack} pays that world's currency`)
	end
end
ok(Logic.packFor("nowhere", MonetizationConfig.Products, WorldsConfig.MAIN) == nil, "unknown world → no pack")
ok(Logic.packFor("x", {
	BigLarge = { kind = "WorldCash", world = "x", incomeSeconds = 1 },
	Huge = { kind = "WorldCash", world = "x", incomeSeconds = 99 },
}, "main") == "BigLarge", "a '...Large' key wins over a bigger pack")

-- 4. Schedule + rewards -------------------------------------------------------------------------------
for _, first in { true, false } do
	local lo = if first then Config.FirstDelayMin else Config.DelayMin
	local hi = if first then Config.FirstDelayMax else Config.DelayMax
	for _, r in { 0, 0.25, 0.5, 0.999, 1.5, -1, 0 / 0 } do
		local d = Logic.delay(r, first, 1)
		ok(isFinite(d) and d >= lo and d <= hi, `delay in [{lo}, {hi}] (first={first}, r={r})`)
	end
	ok(Logic.delay(0.5, first, 2) == 2 * Logic.delay(0.5, first, 1), "multiplier scales the delay")
	ok(Logic.delay(0.5, first, 1000) == Config.IntervalMax * Logic.delay(0.5, first, 1), "multiplier clamps high")
	ok(Logic.delay(0.5, first, 0 / 0) == Logic.delay(0.5, first, 1), "NaN multiplier = 1")
end
ok(Logic.cashAmount(20, 60, 500) == 1200, "60 s of income")
ok(Logic.cashAmount(1, 60, 500) == 500, "floor = the area's first pad")
ok(Logic.cashAmount(0 / 0, 60, 0 / 0) == 1, "NaN income + floor → 1")
ok(Logic.cashAmount(math.huge, 60, 5) == 5, "inf income is corrupt → floor")
ok(Logic.cashAmount(1e306, 60, 5) == 1e300, "an overflowing burst is capped")
ok(Logic.cashAmount(-50, 60, 10) == 10, "negative income → floor")
ok(Logic.cashAmount(12.7, 60, 1) == 762, "whole units")
ok(Logic.isAfk(0, Config.AfkSeconds), "AFK at AfkSeconds")
ok(not Logic.isAfk(0, Config.AfkSeconds - 1), "active just before")
ok(Logic.isAfk(0 / 0, 5), "NaN last active → AFK (no spawns)")
ok(Logic.blinking(100, 100 + Config.BlinkSeconds), "blinks in the last seconds")
ok(not Logic.blinking(100, 100 + Config.BlinkSeconds + 1), "no blink before")
ok(not Logic.blinking(100, 100), "expired → no blink")
local cashKind = Config.byId("cash")
ok(Logic.label(cashKind, 1200, { style = "money", name = "Cash" }) == "+$1.2K!", "cash label in money style")
ok(Logic.label(cashKind, 1200, { style = "count", name = "Bones" }) == "+1.2K Bones!", "cash label in count style")
ok(Logic.label(cashKind, nil, nil) == cashKind.label, "cash without an amount → config label")
ok(Logic.label(Config.byId("boost2x"), 99, nil) == "2x CASH 2 MIN!", "boost label")

-- 5. Placement -------------------------------------------------------------------------------------------
do
	local p = Logic.point(0, 0, 1)
	ok(math.abs(Logic.distance(p, 4, 0) - 3) < 1e-9, "point distance")
	ok(Logic.distance(p, 0.5, 0.5) == 0, "inside → 0")
	local rotated = Logic.box(0, 0, 10, 1, math.rad(90))
	ok(math.abs(Logic.distance(rotated, 0, 9) - 0) < 1e-6, "rotated box covers its long axis")
	ok(math.abs(Logic.distance(rotated, 5, 0) - 4) < 1e-6, "rotated box is thin across")
	ok(Logic.isClear(0, 30, { Logic.point(0, 9, 3.5) }, 7), "far from a pad is clear")
	ok(not Logic.isClear(0, 15, { Logic.point(0, 9, 3.5) }, 7), "next to a pad is not clear")
	for _, rx in { 0, 0.5, 0.9999, -2, 7 } do
		for _, rz in { 0, 0.3, 1 } do
			local x, z = Logic.candidate(rx, rz, Config.SlotMargin, WorldLayout.SlotHalfWidth, WorldLayout.SlotDepth)
			ok(math.abs(x) <= WorldLayout.SlotHalfWidth - Config.SlotMargin + 1e-9, "candidate x inside the margin")
			ok(
				z >= Config.SlotMargin and z <= WorldLayout.SlotDepth - Config.SlotMargin,
				"candidate z inside the margin"
			)
		end
	end
end

-- 6. Claims ---------------------------------------------------------------------------------------------
do
	local button = { world = "main", expires = 200, position = Vector3.new(10, 0, 10) }
	ok(Logic.canClaim(button, { world = "main", now = 150, root = Vector3.new(12, 3, 10) }), "close + alive → ok")
	local okFar, why = Logic.canClaim(button, { world = "main", now = 150, root = Vector3.new(30, 3, 10) })
	ok(not okFar and why == "far", "far away → refused")
	local okEdge = Logic.canClaim(button, {
		world = "main",
		now = 150,
		root = Vector3.new(10 + Config.ClaimRadius + Config.ClaimSlack - 0.01, 3, 10),
	})
	ok(okEdge, "lag slack accepted")
	ok(
		select(2, Logic.canClaim(button, { world = "dino", now = 150, root = button.position })) == "world",
		"other world → refused"
	)
	ok(
		select(2, Logic.canClaim(button, { world = "main", now = 200, root = button.position })) == "expired",
		"expired → refused"
	)
	ok(
		select(2, Logic.canClaim(button, { world = "main", now = 0 / 0, root = button.position })) == "expired",
		"NaN clock → refused"
	)
	ok(
		select(2, Logic.canClaim(button, { world = "main", now = 150, root = nil })) == "character",
		"no character → refused"
	)
	ok(
		not Logic.canClaim(button, { world = "main", now = 150, root = Vector3.new(10, 40, 10) }),
		"far above → refused"
	)
	-- Moon Base 0.4 g: measured apex 21.8 studs + ~3 root height (W10b) — bouncing onto a button claims.
	ok(Config.ClaimHeight >= 21.8 * 1.15 + 3, "vertical allowance covers a Moon jump (apex x 1.15 + 3)")
	-- Never stricter than the server's pad reach (both cover a bouncing Moon jump; lead R70 order).
	local fs = require("@lune/fs")
	local service = fs.readFile("src/server/Tycoon/TycoonService.luau")
	local padVertical = tonumber(string.match(service, "TycoonService%.PadReachVertical = ([%d%.]+)"))
	ok(padVertical ~= nil, "TycoonService.PadReachVertical found")
	ok(
		Config.ClaimHeight >= (padVertical or math.huge),
		`ClaimHeight {Config.ClaimHeight} >= PadReachVertical {padVertical}`
	)
	ok(
		Logic.canClaim(button, { world = "main", now = 150, root = Vector3.new(11, 22, 10) }),
		"mid Moon jump above the button → ok"
	)
	ok(
		not Logic.canClaim(button, { world = "main", now = 150, root = Vector3.new(0 / 0, 0, 0) }),
		"NaN position → refused"
	)
end

-- 10. Owner R122 DEAL card --------------------------------------------------------------------------------
do
	local Deal = Config.Deal
	ok(table.isfrozen(Deal), "Deal frozen")
	ok(#Deal.Actions == 3, "three deal actions")
	for _, action in { "shown", "buy", "close" } do
		ok(table.find(Deal.Actions, action) ~= nil, `deal action {action}`)
	end
	ok(Deal.KeepRadius > Config.ClaimRadius, "the card stays a little past the walk-in radius (hysteresis)")
	ok(Deal.MaxReportsPerButton >= 1 and Deal.MaxReportsPerButton <= 20, "per-button report cap")
	ok(
		retention["luckyDeal:<shown|buy|close>:<pass2x|autoclick|boost30|pack|skip>"] ~= nil,
		"luckyDeal analytics key documented"
	)
	-- Every paid kind is in the analytics choice set of luckyDeal.
	for _, kind in Config.Kinds do
		if kind.paid then
			ok(
				string.find("pass2x|autoclick|boost30|pack|skip", kind.id, 1, true) ~= nil,
				`{kind.id} in the luckyDeal key`
			)
		end
	end

	-- canClaim radius: BUY reaches as far as the card stays up, never further.
	local button = { world = "main", expires = 200, position = Vector3.new(0, 0, 0) }
	local function at(distance: number, radius: any): boolean
		return (
			Logic.canClaim(button, { world = "main", now = 100, root = Vector3.new(distance, 2, 0), radius = radius })
		)
	end
	local walkReach = Config.ClaimRadius + Config.ClaimSlack
	local dealReach = Deal.KeepRadius + Config.ClaimSlack
	ok(not at(walkReach + 0.5), "walk-in reach unchanged without a radius")
	ok(at(dealReach - 0.01, Deal.KeepRadius), "BUY accepted within KeepRadius + slack")
	ok(not at(dealReach + 0.01, Deal.KeepRadius), "BUY refused beyond KeepRadius + slack")
	for _, hostile in { 1e9, math.huge, 0 / 0, -5, 0, "far" } do
		ok(not at(walkReach + 0.5, hostile), `hostile radius {tostring(hostile)} falls back to ClaimRadius`)
	end

	-- The client state machine.
	local state = Logic.newDeal()
	ok(Logic.dealStep(state, 30) == nil and not state.showing, "far: nothing")
	ok(Logic.dealStep(state, nil) == nil, "no character: nothing")
	ok(Logic.dealStep(state, Deal.KeepRadius - 0.5) == nil, "between the radii: not yet (walk-in = ClaimRadius)")
	ok(Logic.dealStep(state, Config.ClaimRadius - 0.1) == "show" and state.showing, "walk-in shows")
	ok(Logic.dealStep(state, 1) == nil, "standing on it: still shown, no repeat")
	ok(Logic.dealStep(state, Deal.KeepRadius - 0.1) == nil, "stepping back inside KeepRadius keeps it")
	ok(Logic.dealStep(state, Deal.KeepRadius + 0.1) == "hide" and not state.showing, "walking away hides it")
	ok(Logic.dealStep(state, 0) == "show", "walking back in shows it again")
	-- CLOSE keeps it away until the player walks out of KeepRadius and back in.
	Logic.dealClosed(state, "close")
	ok(not state.showing and state.dismissed, "CLOSE: dismissed")
	ok(Logic.dealStep(state, 0) == nil, "still standing there: no re-show")
	ok(Logic.dealStep(state, Deal.KeepRadius - 0.2) == nil, "inside KeepRadius: no re-show")
	ok(Logic.dealStep(state, Deal.KeepRadius + 1) == nil and not state.dismissed, "walked out: re-armed")
	ok(Logic.dealStep(state, 0) == "show", "walked back in: shows")
	for _, reason in { "buy", "timeout", "replaced", "modal", "hidden" } do
		Logic.dealClosed(state, reason)
		ok(state.dismissed and not state.showing, `{reason}: stays away until the player walks out`)
		Logic.dealStep(state, 100)
		Logic.dealStep(state, 0)
	end
	for _, reason in { "away", "expired" } do
		state = Logic.newDeal()
		Logic.dealStep(state, 0)
		Logic.dealClosed(state, reason)
		ok(not state.dismissed and not state.showing, `{reason}: not a dismissal`)
		ok(Logic.dealStep(state, 0) == "show", `{reason}: the next walk-in step shows it again`)
	end
	ok(Logic.dealStep(Logic.newDeal(), 0 / 0) == nil, "NaN distance: nothing")

	-- Randomised walk: shows only on a walk-in, never while far; hide exactly once per show.
	local seed = 122
	local function rand(): number
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	local walk = Logic.newDeal()
	local shows, hides = 0, 0
	for _ = 1, 5000 do
		local distance = rand() * 20
		local action = Logic.dealStep(walk, distance)
		if action == "show" then
			shows += 1
			ok(distance <= Config.ClaimRadius, "shows only inside the walk-in radius")
		elseif action == "hide" then
			hides += 1
			ok(distance > Deal.KeepRadius, "hides only past KeepRadius")
		end
		ok(not (walk.showing and distance > Deal.KeepRadius), "never showing while far")
		if walk.showing and rand() < 0.05 then
			Logic.dealClosed(walk, if rand() < 0.5 then "close" else "buy")
		end
	end
	ok(shows > 0 and hides > 0, "the walk exercised show and hide")

	-- Source: a paid walk-in never prompts; only the "buy" action reaches promptPass / promptProduct.
	local fs = require("@lune/fs")
	local service = fs.readFile("src/server/Services/LuckyButtonService.luau")
	local onClaim = string.match(service, "local function onClaim%(.-\nend\n") or ""
	ok(#onClaim > 0, "onClaim found")
	ok(string.find(onClaim, "promptPass", 1, true) == nil, "onClaim (walk-in) never prompts a pass")
	ok(string.find(onClaim, "promptProduct", 1, true) == nil, "onClaim (walk-in) never prompts a product")
	local onDeal = string.match(service, "local function onDeal%(.-\nend\n") or ""
	ok(string.find(onDeal, 'action ~= "buy"', 1, true) ~= nil, "onDeal prompts only for buy")
	ok(string.find(onDeal, "promptPass", 1, true) ~= nil, "onDeal holds the prompt")
	local client = fs.readFile("src/client/LuckyButtons/LuckyButtonClient.luau")
	ok(
		string.find(client, 'FireServer(wire.id, "buy")', 1, true) ~= nil,
		"the client's only paid prompt path is the card's BUY"
	)
end

-- 7. Wire -----------------------------------------------------------------------------------------------
do
	local good = {
		id = "L12",
		kind = "boost30",
		world = "main",
		position = Vector3.new(1, 2, 3),
		born = 100,
		expires = 145,
		product = "Cash2x30",
		productType = "product",
	}
	local wire = Logic.readWire(good)
	ok(wire ~= nil and wire.id == "L12" and wire.product == "Cash2x30" and wire.productType == "product", "valid wire")
	local cash = Logic.readWire({
		id = "L1",
		kind = "cash",
		world = "dino",
		position = Vector3.new(0, 0, 0),
		born = 1,
		expires = 46,
		amount = 500,
	})
	ok(cash ~= nil and cash.amount == 500, "valid cash wire")
	local nan = 0 / 0
	local bad: { any } = {
		nil,
		5,
		"x",
		{},
		{ id = "X1", kind = "cash", world = "main", position = Vector3.new(), born = 1, expires = 2 },
		{ id = "L1", kind = "nope", world = "main", position = Vector3.new(), born = 1, expires = 2 },
		{ id = "L1", kind = "cash", world = "main", position = Vector3.new(nan, 0, 0), born = 1, expires = 2 },
		{ id = "L1", kind = "cash", world = "main", position = { 1, 2, 3 }, born = 1, expires = 2 },
		{ id = "L1", kind = "cash", world = "main", position = Vector3.new(), born = 5, expires = 2 },
		{ id = "L1", kind = "cash", world = "ma in", position = Vector3.new(), born = 1, expires = 2 },
		{ id = "L1", kind = "cash", world = "main", position = Vector3.new(), born = 1, expires = 2, amount = -5 },
		{ id = "L1", kind = "cash", world = "main", position = Vector3.new(), born = 1, expires = 2, amount = "9" },
		{
			id = "L1",
			kind = "boost30",
			world = "main",
			position = Vector3.new(),
			born = 1,
			expires = 2,
			product = "a b",
			productType = "product",
		},
		{
			id = "L1",
			kind = "boost30",
			world = "main",
			position = Vector3.new(),
			born = 1,
			expires = 2,
			product = "Cash2x30",
			productType = "gift",
		},
		{ id = string.rep("L", 30), kind = "cash", world = "main", position = Vector3.new(), born = 1, expires = 2 },
	}
	for index = 1, 15 do
		local okCall, result = pcall(Logic.readWire, bad[index])
		ok(okCall and result == nil, `hostile wire {index} refused without error`)
	end
	ok(
		Logic.validId("L42") and not Logic.validId("L") and not Logic.validId("l42") and not Logic.validId(42),
		"id pattern"
	)
end

-- 8. Edge arrow ------------------------------------------------------------------------------------------
do
	local canvas = Vector2.new(1920, 1080)
	local safe = { left = 40, top = 60, right = 40, bottom = 30 }
	local inset = Config.Client.ArrowInset
	local thumb = { x = 0, y = 700, width = 500, height = 380 }
	local jump = { x = 1500, y = 760, width = 420, height = 320 }
	local cases = {
		{ point = Vector2.new(5000, 540), inFront = true },
		{ point = Vector2.new(-3000, 540), inFront = true },
		{ point = Vector2.new(960, -4000), inFront = true },
		{ point = Vector2.new(100, 5000), inFront = true },
		{ point = Vector2.new(2400, 2000), inFront = true },
		{ point = Vector2.new(960, 540), inFront = false },
		{ point = Vector2.new(1200, 300), inFront = false },
		{ point = Vector2.new(0 / 0, 0 / 0), inFront = true },
	}
	for index, case in cases do
		local place = Logic.arrow({
			point = case.point,
			inFront = case.inFront,
			canvas = canvas,
			safe = safe,
			inset = inset,
			avoid = { thumb, jump },
			clearance = Config.Client.ArrowTouchClearance,
		})
		local p = place.position
		ok(isFinite(p.X) and isFinite(p.Y) and isFinite(place.rotation), `arrow {index}: finite`)
		ok(
			p.X >= safe.left + inset - 1e-6 and p.X <= canvas.X - safe.right - inset + 1e-6,
			`arrow {index}: inside the safe width`
		)
		ok(
			p.Y >= safe.top + inset - 1e-6 and p.Y <= canvas.Y - safe.bottom - inset + 1e-6,
			`arrow {index}: inside the safe height`
		)
		for _, rect in { thumb, jump } do
			local inside = p.X >= rect.x
				and p.X <= rect.x + rect.width
				and p.Y >= rect.y
				and p.Y <= rect.y + rect.height
			ok(not inside, `arrow {index}: clear of the touch zones`)
		end
	end
	local right = Logic.arrow({
		point = Vector2.new(5000, 540),
		inFront = true,
		canvas = canvas,
		safe = safe,
		inset = inset,
		avoid = {},
		clearance = 0,
	})
	ok(math.abs(right.rotation) < 5 and right.position.X > 1700, "target far right → right edge, pointing right")
	local behind = Logic.arrow({
		point = Vector2.new(1500, 545),
		inFront = false,
		canvas = canvas,
		safe = safe,
		inset = inset,
		avoid = {},
		clearance = 0,
	})
	ok(behind.position.X < 960, "behind the camera mirrors to the other side")
	-- A top HUD zone pushes the arrow DOWN (toward the centre), a bottom touch zone lifts it UP.
	local topZone = { x = 700, y = 0, width = 520, height = 300 }
	local up = Logic.arrow({
		point = Vector2.new(960, -5000),
		inFront = true,
		canvas = canvas,
		safe = safe,
		inset = inset,
		avoid = { topZone },
		clearance = 10,
	})
	ok(up.position.Y > topZone.y + topZone.height, "top zone pushes the arrow below it")
	local down = Logic.arrow({
		point = Vector2.new(-3000, 3000),
		inFront = true,
		canvas = canvas,
		safe = safe,
		inset = inset,
		avoid = { thumb },
		clearance = 10,
	})
	ok(down.position.Y < thumb.y, "thumbstick zone lifts the arrow above it")
end

-- 9. Slot geometry ------------------------------------------------------------------------------------
local CFrame = roblox.CFrame
local MeshAssets = loader.load("src/shared/Config/MeshAssets")
local BillboardSpots = loader.load("src/shared/Config/BillboardSpots")
do
	-- classify: ground-level tops are support, buried = ignore, standing = solid, overhead = ignore.
	ok(Logic.classify(0, -4) == "support", "ground slab → support")
	ok(Logic.classify(-6, -10) == "ignore", "buried box → ignore")
	ok(Logic.classify(12, 0) == "solid", "wall → solid")
	ok(Logic.classify(14, 6) == "solid", "roof over a yard → solid (a button never sits under it)")
	ok(Logic.classify(40, Config.HeadRoom + 1) == "ignore", "high arch beam → ignore")
	-- slab: a 90°-yawed 20 x 4 x 2 wall is 2 wide along X and 20 long along Z.
	local wall, top, bottom =
		Logic.slab(CFrame.new(10, 2, 30) * CFrame.Angles(0, math.rad(90), 0), Vector3.new(20, 4, 2))
	ok(math.abs(top - 4) < 1e-6 and math.abs(bottom) < 1e-6, "slab top / bottom")
	ok(Logic.distance(wall, 10, 39) < 1e-6 and math.abs(Logic.distance(wall, 13, 30) - 2) < 1e-6, "slab yaw rect")
	local tilted = Logic.slab(CFrame.new(0, 1, 0) * CFrame.Angles(math.rad(30), 0, 0), Vector3.new(4, 4, 4))
	ok(Logic.distance(tilted, 0, 0) == 0, "tilted box: axis-aligned corner bounds cover its centre")
	ok(
		Logic.inside(Logic.point(0, 0, 10), 7, 0, 2.7) and not Logic.inside(Logic.point(0, 0, 10), 8, 0, 2.7),
		"inside margin"
	)
	-- spotOk on a synthetic slot: ground slab, a pad, a prop.
	local geometry = {
		supports = { Logic.point(0, 35, 40) },
		keepouts = { Logic.point(0, 10, Config.PadHalf) },
		solids = { Logic.point(20, 40, 2) },
	}
	ok(Logic.spotOk(-20, 40, geometry, {}), "open ground → ok")
	ok(select(2, Logic.spotOk(0, 15, geometry, {})) == "blocked", "next to a pad → blocked (7 studs)")
	ok(
		Logic.spotOk(0, 10 + Config.PadHalf + Config.Clearance + 0.1, geometry, {}),
		"just past a pad's clearance → ok"
	)
	ok(select(2, Logic.spotOk(20, 43, geometry, {})) == "blocked", "inside a prop → blocked")
	ok(Logic.spotOk(20 + 2 + Config.PropClearance + 0.1, 40, geometry, {}), "just past a prop → ok")
	ok(select(2, Logic.spotOk(0, 74, geometry, {})) == "gap", "no ground → gap")
	ok(
		select(2, Logic.spotOk(-20, 40, geometry, { Logic.point(-22, 40, 0) })) == "blocked",
		"another button → blocked"
	)
	local grid = Logic.validSpots(geometry, 4, 52, 70)
	ok(#grid > 0, "synthetic slot has spots")
	for _, spot in grid do
		ok(Logic.spotOk(spot.X, spot.Y, geometry, nil), "grid spots are valid")
	end
end
do
	-- Every world's REAL layouts, exactly as the server builds them (plots 1 and 8).
	local function configPath(parts: { string }): string
		return "src/shared/Config/" .. table.concat(parts, "/")
	end
	for _, worldId in WorldsConfig.Order do
		local def = WorldsConfig.get(worldId)
		local okHub, hub = pcall(loader.load, configPath(def.hubLayout))
		local frame = if okHub and type(hub) == "table" then hub.plotFrame else nil
		local areas = WorldLayout.areaCount(worldId)
		local roomy = 0
		for area = 1, areas do
			local okLayout, layout =
				pcall(loader.load, string.format(configPath(def.layoutFolder) .. "/Area%02d", area))
			if not okLayout then
				continue
			end
			local spots = if worldId == WorldsConfig.MAIN
				then BillboardSpots[area]
				else (BillboardSpots.worlds[worldId] or {})[area]
			local counted = false
			for _, plot in { 1, 8 } do
				local toSlot = WorldLayout.slotOrigin(plot, area, worldId):Inverse()
					* WorldLayout.plotOrigin(plot, worldId)
				local geometry = Logic.slotGeometry({
					layout = layout,
					spots = spots,
					frame = frame,
					toSlot = toSlot,
					plotHalfWidth = WorldLayout.PlotHalfWidth,
					plotLength = WorldLayout.plotLength(worldId),
					meshes = MeshAssets,
				})
				local label = `{worldId} area {area} plot {plot}`
				ok(#geometry.supports > 0, `{label}: walkable ground colliders found`)
				local list =
					Logic.validSpots(geometry, Config.GridStep, WorldLayout.SlotHalfWidth, WorldLayout.SlotDepth)
				for _, spot in list do
					local x, z = spot.X, spot.Y
					-- Independent re-checks straight from the layout: pads + billboards at 7 studs.
					for _, pad in layout.pads or {} do
						ok(
							math.max(0, math.max(math.abs(x - pad.X), math.abs(z - pad.Z)) - Config.PadHalf)
									>= Config.Clearance - 1e-6
								or Logic.distance(Logic.point(pad.X, pad.Z, Config.PadHalf), x, z)
									>= Config.Clearance - 1e-6,
							`{label}: spot keeps 7 studs from a pad`
						)
					end
					for _, solid in geometry.solids do
						ok(
							Logic.distance(solid, x, z) >= Config.PropClearance - 1e-6,
							`{label}: spot never overlaps a prop / collider`
						)
					end
					local onGround = false
					for _, support in geometry.supports do
						if Logic.inside(support, x, z, Config.ButtonRadius) then
							onGround = true
						end
					end
					ok(onGround, `{label}: spot stands on a ground collider`)
				end
				if #list > 0 and not counted then
					roomy += 1
					counted = true
				end
			end
		end
		ok(roomy * 2 >= areas, `{worldId}: most areas have room for a Lucky Button ({roomy}/{areas})`)
	end
end

print(`lucky-buttons: {checks} checks passed`)
