--!strict
--[[
	Harvest Feast regressions (B11). Run:
		lune run tests/event-logic

	Proves on the shipped modules (src/shared/Config/EventConfig, src/server/Event/EventLogic):
	  1. Window math: half-open [starts, ends), admin force on / off, redeem grace, and the season
	     equals MonetizationConfig's Acorn / Turkey Lure sale window.
	  2. Sticker weighting + dupe protection: deterministic picks, owned stickers weigh
	     DupeWeightFactor, the observed frequency of the last unowned sticker matches its weight,
	     rarer stickers drop less often; a full-sheet simulation reports turkeys-to-complete.
	  3. Rewards: acorn range, lure multiplier + guaranteed roll, dupe consolation, applyReward.
	  4. Redeem idempotency: incomplete → ok → (redeemed) already; closed after the grace.
	  5. Season rollover: a previous season resets acorns / stickers / redeemed, keeps decor + lures.
	  6. Acorn spending is atomic; shop checks; catch checks (every refusal reason).
	  7. Turkey paths: pose timeline (peck, walk, loop, life), minDistance with lag samples,
	     parseTurkey rejects malformed wires.
	  8. Spawn scheduler: first delays, caps, lures even when the event is off, timers cleared.
	  9. Owner R96 ground placement: groundFrame puts a model's REAL bounding-box bottom on the
	     ground whatever its pivot (the mid-bird PrimaryPart pivot that sank turkeys, rotated
	     parts, empty / junk input); the full peck nod's dip is measurable; groundSnapY climbs
	     curbs within GroundUp, sinks within GroundDown, ignores roofs / holes / NaN.
	 10. Owner R97 starter stickers: the 3 commonest stickers; a new sheet gets all 3; top-up to
	     3 only with stickers not owned; idempotent per season; a new season grants again; a
	     record of another season is never stamped; nothing is ever removed; the Gobble Bomb
	     still needs all 20.
]]

local Loader = require("./fixtures/RobloxLoader")
local roblox = require("@lune/roblox")

local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame

local loader = Loader.new()
local EventConfig = loader.load("src/shared/Config/EventConfig")
local EventLogic = loader.load("src/server/Event/EventLogic")
local MonetizationConfig = loader.load("src/shared/Config/MonetizationConfig")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

-- Deterministic uniform [0, 1) generator (LCG) for reproducible statistics.
local function lcg(seed: number): () -> number
	local state = seed
	return function(): number
		state = (state * 48271) % 2147483647
		return state / 2147483647
	end
end

local season = EventConfig.Season

-- 1. Window -------------------------------------------------------------------------------------
check(season.starts == 1_793_491_200 and season.ends == 1_796_083_200, "season = 2026-11-01 .. 2026-12-01 UTC")
check(EventConfig.isInWindow(season.starts), "active at the start instant")
check(not EventConfig.isInWindow(season.starts - 1), "inactive one second before")
check(EventConfig.isInWindow(season.ends - 1), "active one second before the end")
check(not EventConfig.isInWindow(season.ends), "inactive at the end instant (half-open)")
check(EventConfig.resolveActive(season.starts - 86400, "on"), "force on wins before the window")
check(not EventConfig.resolveActive(season.starts + 10, "off"), "force off wins inside the window")
check(EventConfig.resolveActive(season.starts + 10, nil), "no force = by date")
check(EventConfig.redeemUntil() == season.ends + EventConfig.RedeemGraceSeconds, "redeem grace")
for _, key in { "AcornsSmall", "AcornsLarge", "TurkeyLure" } do
	local product = MonetizationConfig.getProduct(key)
	check(
		product ~= nil and product.saleStarts == season.starts and product.saleEnds == season.ends,
		`{key} sale window = season`
	)
end

-- 2. Sticker weighting ----------------------------------------------------------------------------
check(EventConfig.StickerCount == 20, "20 stickers")
local seenKeys: { [string]: boolean } = {}
for index, def in EventConfig.Stickers do
	check(def.index == index and not seenKeys[def.key], `sticker {index} indexed + unique`)
	seenKeys[def.key] = true
	check(EventConfig.RarityWeight[def.rarity] ~= nil, `sticker {index} has a rarity weight`)
end
check(EventLogic.rollSticker({}, 0) == 1, "r = 0 picks the first sticker")
check(EventLogic.rollSticker({}, 0.9999999) == 20, "r -> 1 picks the last sticker")
local weights, total = EventLogic.stickerWeights({ [1] = true })
check(
	math.abs(weights[1] - EventConfig.RarityWeight.Common * EventConfig.Rewards.DupeWeightFactor) < 1e-9,
	"owned weight reduced"
)
check(weights[2] == EventConfig.RarityWeight.Common and total > 0, "unowned weight intact")

-- Only sticker 20 (Legendary) missing: its expected share = 1.5 / (1.5 + sum(others) * 0.08).
local almost: { [number]: true } = {}
for index = 1, 19 do
	almost[index] = true
end
local almostWeights, almostTotal = EventLogic.stickerWeights(almost)
local expected = almostWeights[20] / almostTotal
local rng = lcg(4242)
local hits = 0
local trials = 20000
for _ = 1, trials do
	if EventLogic.rollSticker(almost, rng()) == 20 then
		hits += 1
	end
end
local observed = hits / trials
local _, freshTotal = EventLogic.stickerWeights({})
local unprotected = EventConfig.RarityWeight.Legendary / freshTotal
check(expected > 5 * unprotected, `dupe protection favours the missing sticker ({expected} vs {unprotected})`)
check(math.abs(observed - expected) < 0.02, `observed {observed} ~ expected {expected}`)

-- Fresh sheet: commons drop far more than the legendary.
rng = lcg(99)
local counts: { [number]: number } = {}
for _ = 1, trials do
	local index = EventLogic.rollSticker({}, rng())
	counts[index] = (counts[index] or 0) + 1
end
check((counts[1] or 0) > 4 * (counts[20] or 0), "common >> legendary on a fresh sheet")

-- Full-sheet simulation: turkeys a player catches before completing the sheet (natural turkeys).
local function turkeysToComplete(seed: number): number
	local r = lcg(seed)
	local owned: { [number]: true } = {}
	local turkeys = 0
	while EventConfig.countStickers(owned) < EventConfig.StickerCount do
		turkeys += 1
		local reward = EventLogic.rollReward(owned, false, r)
		local event = { season = "s", acorns = 0, stickers = owned, redeemed = false }
		EventLogic.applyReward(event :: any, reward)
		check(turkeys < 5000, "sheet completes")
	end
	return turkeys
end
local sum = 0
for seed = 1, 40 do
	sum += turkeysToComplete(seed * 7919)
end
local mean = sum / 40
print(
	`[event-logic] mean turkeys to complete the sheet: {math.floor(mean)} (sticker chance {EventConfig.Rewards.StickerChance})`
)
check(mean > 60 and mean < 400, `sheet takes a few hours of turkeys (mean {mean})`)

-- 3. Rewards ------------------------------------------------------------------------------------
rng = lcg(7)
for _ = 1, 500 do
	local reward = EventLogic.rollReward({}, false, rng)
	check(
		reward.acorns >= EventConfig.Rewards.AcornsMin and reward.acorns <= EventConfig.Rewards.AcornsMax,
		"acorns in range"
	)
	check(reward.sticker == 0 or (reward.sticker >= 1 and reward.sticker <= 20), "sticker index valid")
	check(not reward.dup and reward.bonus == 0, "no dupes on an empty sheet")
end
for _ = 1, 200 do
	-- A lure's roll is a paid random item: only with an allowed policy (paidRandomAllowed = true).
	local reward = EventLogic.rollReward({}, true, rng, true)
	check(reward.sticker >= 1, "a lure always rolls a sticker")
	check(
		reward.acorns % EventConfig.Rewards.LureMultiplier == 0 and reward.acorns >= EventConfig.Rewards.AcornsMin * 3,
		"lure x3 acorns"
	)
end
local full: { [number]: true } = {}
for index = 1, 20 do
	full[index] = true
end
local dupReward = EventLogic.rollReward(full, true, rng, true)
check(
	dupReward.dup and dupReward.bonus == EventConfig.Rewards.DupeAcorns,
	"a full sheet rolls dupes with the consolation"
)
-- Restricted / unknown policy (false / nil): a lure pays the FIXED reward and never rolls.
for _, allowed in { false, nil :: boolean? } do
	local draws = 0
	local fixed = EventLogic.rollReward({}, true, function(): number
		draws += 1
		return 0.5
	end, allowed)
	check(
		fixed.sticker == 0
			and not fixed.dup
			and fixed.bonus == 0
			and fixed.acorns == EventConfig.Rewards.AcornsMax * EventConfig.Rewards.LureMultiplier,
		"restricted lure: fixed acorns, no sticker"
	)
	check(draws == 0, "restricted lure: no random draw at all")
end
-- Natural turkeys are free: the policy flag changes nothing for them.
local natural = EventLogic.rollReward({}, false, lcg(3), false)
check(natural.acorns >= EventConfig.Rewards.AcornsMin and natural.acorns <= EventConfig.Rewards.AcornsMax, "natural ok")
local record = { season = "s", acorns = 10, stickers = {}, redeemed = false, turkeys = 0 }
local added = EventLogic.applyReward(record :: any, { acorns = 5, sticker = 3, dup = false, bonus = 0 })
check(added == 5 and record.acorns == 15 and record.stickers[3] == true and record.turkeys == 1, "applyReward grants")
EventLogic.applyReward(record :: any, { acorns = 1, sticker = 3, dup = true, bonus = 12 })
check(record.acorns == 28 and EventConfig.countStickers(record.stickers) == 1, "dupe pays bonus, set unchanged")
record.acorns = EventConfig.Rewards.MaxAcorns - 2
check(EventLogic.addAcorns(record :: any, 10) == 2, "acorns clamp at MaxAcorns")
check(
	EventLogic.addAcorns(record :: any, 0 / 0) == 0 and EventLogic.addAcorns(record :: any, -5) == 0,
	"junk grants refused"
)

-- 4. Redeem idempotency ---------------------------------------------------------------------------
local sheet = { season = "s", acorns = 0, stickers = {}, redeemed = false }
check(EventLogic.redeemCheck(sheet :: any, true) == "incomplete", "incomplete sheet")
for index = 1, 19 do
	sheet.stickers[index] = true
end
check(EventLogic.redeemCheck(sheet :: any, true) == "incomplete", "19/20 still incomplete")
sheet.stickers[20] = true
check(EventLogic.redeemCheck(sheet :: any, false) == "closed", "complete but closed")
check(EventLogic.redeemCheck(sheet :: any, true) == "ok", "complete + open = ok")
sheet.redeemed = true
check(EventLogic.redeemCheck(sheet :: any, true) == "already", "second redeem refused")
check(EventLogic.redeemCheck(sheet :: any, true) == "already", "and stays refused")

-- 5. Season rollover ------------------------------------------------------------------------------
local old = {
	season = "harvest2025",
	acorns = 900,
	stickers = { [1] = true },
	redeemed = true,
	decor = { HayBales = true },
	turkeys = 40,
	lures = 2,
}
check(EventLogic.ensureSeason(old :: any, season.id), "rollover reports a change")
check(
	old.season == season.id and old.acorns == 0 and next(old.stickers) == nil and not old.redeemed,
	"season data reset"
)
check(old.decor.HayBales == true and old.lures == 2 and old.turkeys == 0, "decor + pending lures kept")
check(not EventLogic.ensureSeason(old :: any, season.id), "same season: no change")

-- 6. Spending, shop, catch checks ---------------------------------------------------------------
local wallet = { season = season.id, acorns = 100, stickers = {}, redeemed = false }
check(not EventLogic.spendAcorns(wallet :: any, 101) and wallet.acorns == 100, "overspend refused, balance intact")
check(
	not EventLogic.spendAcorns(wallet :: any, 1.5) and not EventLogic.spendAcorns(wallet :: any, 0 / 0),
	"junk spend refused"
)
check(EventLogic.spendAcorns(wallet :: any, 100) and wallet.acorns == 0, "exact spend")
local hay = EventConfig.ShopByKey.HayBales
local rush = EventConfig.ShopByKey.HarvestRush
local buyer = { season = season.id, acorns = 1000, stickers = {}, redeemed = false, decor = {} }
check(EventLogic.shopCheck(nil, buyer :: any, true, true) == "unknown", "unknown item")
check(EventLogic.shopCheck(hay, buyer :: any, false, true) == "inactive", "shop closed when off")
check(EventLogic.shopCheck(hay, buyer :: any, true, false) == "unsupported", "decor needs the profile field")
check(EventLogic.shopCheck(hay, buyer :: any, true, true) == "ok", "decor ok")
buyer.decor.HayBales = true
check(EventLogic.shopCheck(hay, buyer :: any, true, true) == "owned", "decor owned once")
buyer.acorns = rush.price - 1
check(EventLogic.shopCheck(rush, buyer :: any, true, true) == "poor", "too few acorns")
check(EventLogic.shopCheck(rush, buyer :: any, true, false) == "poor", "boosts do not need the decor field")

local function facts(overrides: { [string]: any }): any
	local base = {
		exists = true,
		active = true,
		lure = false,
		owner = 0,
		userId = 7,
		already = false,
		sinceLast = math.huge,
		hasCharacter = true,
		distance = 3,
	}
	for key, value in overrides do
		base[key] = value
	end
	return base
end
local range = EventLogic.serverRange()
check(EventLogic.collectCheck(facts({}), range) == "ok", "valid catch")
check(EventLogic.collectCheck(facts({ exists = false }), range) == "missing", "missing turkey")
check(EventLogic.collectCheck(facts({ active = false }), range) == "inactive", "event off")
check(
	EventLogic.collectCheck(facts({ active = false, lure = true, owner = 7 }), range) == "ok",
	"a paid lure works after the end"
)
check(EventLogic.collectCheck(facts({ owner = 8 }), range) == "notOwner", "someone else's lure")
check(EventLogic.collectCheck(facts({ already = true }), range) == "already", "once per turkey")
check(EventLogic.collectCheck(facts({ sinceLast = 0.1 }), range) == "cooldown", "cooldown")
check(EventLogic.collectCheck(facts({ hasCharacter = false }), range) == "noCharacter", "needs a character")
check(EventLogic.collectCheck(facts({ distance = range + 0.5 }), range) == "far", "too far")
check(EventLogic.collectCheck(facts({ distance = 0 / 0 }), range) == "far", "NaN distance refused")

-- 7. Paths -------------------------------------------------------------------------------------------
local wire = {
	id = "t1",
	zone = "hub",
	points = { Vector3.new(0, 0, 0), Vector3.new(10, 0, 0), Vector3.new(10, 0, 10) },
	t0 = 1000,
	speed = 5,
	pause = 2,
	life = 60,
	owner = 0,
	lure = false,
}
local compiled = EventConfig.compilePath(wire :: any)
-- Legs: (pause 2 + walk 2) + (2 + 2) + (2 + sqrt(200)/5) = 8 + 2 + 2.828 = 12.828
check(math.abs(compiled.cycle - (8 + 2 + math.sqrt(200) / 5)) < 1e-9, "cycle length")
local p0 = EventConfig.pose(compiled, 1000)
check(p0.alive and p0.pecking and p0.position == Vector3.new(0, 0, 0), "starts pecking at P1")
local p1 = EventConfig.pose(compiled, 1003)
check(p1.moving and (p1.position - Vector3.new(5, 0, 0)).Magnitude < 1e-6, "walks half way after 1 s of walking")
check((p1.facing - Vector3.new(1, 0, 0)).Magnitude < 1e-6, "faces its walking direction")
local p2 = EventConfig.pose(compiled, 1000 + compiled.cycle + 3)
check((p2.position - Vector3.new(5, 0, 0)).Magnitude < 1e-6, "loops")
check(not EventConfig.pose(compiled, 1060).alive and not EventConfig.pose(compiled, 999).alive, "life window")
check(EventLogic.minDistance(compiled, 1003, Vector3.new(5, 0, 3), { 0 }) - 3 < 1e-6, "distance now")
-- Player standing where the turkey WAS 0.8 s ago is still close by the lag samples.
local lagged = EventLogic.minDistance(compiled, 1003.8, Vector3.new(5, 0, 0), EventConfig.Turkey.LagSamples)
check(lagged < 0.01, "lag samples catch a trailing root")

check(EventConfig.parseTurkey(wire) ~= nil, "valid wire parses")
local function broken(field: string, value: any): boolean
	local copy = table.clone(wire) :: any
	copy[field] = value
	return EventConfig.parseTurkey(copy) == nil
end
check(broken("id", "bad id!"), "id charset")
check(broken("zone", "moon"), "zone allowlist")
check(broken("speed", 0 / 0) and broken("speed", 999), "speed bounds")
check(broken("life", -1) and broken("owner", 1.5), "life / owner")
check(broken("points", {}) and broken("points", { "x" }), "points")
local many = {}
for index = 1, EventConfig.Turkey.MaxPoints + 1 do
	many[index] = Vector3.new(index, 0, 0)
end
check(broken("points", many), "point count bound")

-- 8. Scheduler ---------------------------------------------------------------------------------------
local state = EventLogic.newSpawnState()
local schedRng = lcg(5)
local players = {
	{ userId = 1, plotIndex = 1, plotAlive = 0, lurePending = 0, lureAlive = 0 },
	{ userId = 2, plotIndex = nil, plotAlive = 0, lurePending = 1, lureAlive = 0 },
}
local orders = EventLogic.planSpawns(
	0,
	{ active = true, totalAlive = 0, naturalAlive = 0, hubAlive = 0, players = players },
	state,
	schedRng
)
check(#orders == 1 and orders[1].lure and orders[1].userId == 2, "first tick: only the pending lure (timers start)")
check(
	state.nextHubAt == EventConfig.Turkey.Hub.FirstDelay and state.plotNextAt[1] == EventConfig.Turkey.Plot.FirstDelay,
	"first delays scheduled"
)
players[2].lurePending = 0
orders = EventLogic.planSpawns(
	EventConfig.Turkey.Plot.FirstDelay,
	{ active = true, totalAlive = 1, naturalAlive = 0, hubAlive = 0, players = players },
	state,
	schedRng
)
local zones: { [string]: number } = {}
for _, order in orders do
	zones[order.zone] = (zones[order.zone] or 0) + 1
end
check(zones.hub == 1 and zones.plot == 1, "hub + plot spawn when due")
check(state.nextHubAt > EventConfig.Turkey.Plot.FirstDelay, "hub timer advanced")
orders = EventLogic.planSpawns(10_000, {
	active = true,
	totalAlive = 3,
	naturalAlive = 3,
	hubAlive = EventConfig.Turkey.Hub.Max,
	players = { { userId = 1, plotIndex = 1, plotAlive = 1, lurePending = 0, lureAlive = 0 } },
}, state, schedRng)
check(#orders == 0, "per-zone caps hold")
orders = EventLogic.planSpawns(
	20_000,
	{ active = true, totalAlive = 30, naturalAlive = EventConfig.Turkey.MaxAlive, hubAlive = 0, players = players },
	state,
	schedRng
)
check(#orders == 0, "global cap holds")
orders = EventLogic.planSpawns(30_000, {
	active = false,
	totalAlive = 0,
	naturalAlive = 0,
	hubAlive = 0,
	players = { { userId = 3, plotIndex = 2, plotAlive = 0, lurePending = 2, lureAlive = 0 } },
}, state, schedRng)
check(#orders == 1 and orders[1].lure, "lures spawn even when the event is off")
check(state.nextHubAt == 0 and next(state.plotNextAt) == nil, "off resets the natural timers")
orders = EventLogic.planSpawns(
	30_001,
	{ active = true, totalAlive = 0, naturalAlive = 0, hubAlive = 0, players = {} },
	state,
	schedRng
)
check(#orders == 0, "nobody present: no natural spawns")

-- Plot wander points stay on the road and within the unlocked rows.
local wanderRng = lcg(11)
for area = 1, 10 do
	for _, point in EventLogic.plotWanderPoints(area, 520, 104, wanderRng) do
		local rows = math.ceil(area / 2)
		check(math.abs(point.X) <= EventConfig.Turkey.Plot.RoadHalfWidth, "road half width")
		check(point.Z >= EventConfig.Turkey.Plot.StartZ and point.Z <= rows * 104, "inside unlocked rows")
	end
end
local hubPoints = EventLogic.hubWanderPoints({}, Vector3.new(0, 0, -150), wanderRng)
check(#hubPoints == EventConfig.Turkey.Waypoints, "fallback hub ring")
for _, point in hubPoints do
	check(
		(point - Vector3.new(0, 0, -150)).Magnitude <= EventConfig.Turkey.Hub.WanderRadius + 1e-6,
		"inside the square"
	)
end
local anchors = { Vector3.new(100, 0, 0), Vector3.new(-100, 0, 0), Vector3.new(0, 0, 100) }
for _ = 1, 50 do
	local loop = EventLogic.hubWanderPoints(anchors, Vector3.zero, wanderRng)
	check(#loop == EventConfig.Turkey.Waypoints, "anchor loop size")
	-- Every point of one loop stays near ONE anchor (no cross-hub walks).
	local nearest = math.huge
	local centre = Vector3.zero
	for _, anchor in anchors do
		local d = (loop[1] - anchor).Magnitude
		if d < nearest then
			nearest, centre = d, anchor
		end
	end
	for _, point in loop do
		check((point - centre).Magnitude <= EventConfig.Turkey.Hub.AnchorWander + 1e-6, "loop stays around its anchor")
	end
end

-- Fallback decor slots: area-1 lawn spots stay inside the slot and clear of the pad row / driveway.
for name, slot in EventConfig.DecorSlots do
	if slot.area == 1 then
		local p = slot.cf.Position
		check(math.abs(p.X) <= 52 and p.Z >= 15 and p.Z <= 28, `{name} on the area-1 front lawn`)
		check(math.abs(p.X) >= 13, `{name} clear of the driveway + lamps`)
	end
end

-- Shop catalogue sanity.
for _, item in EventConfig.Shop do
	check(item.price > 0 and #item.key <= EventConfig.MaxShopKeyLength, `{item.key} priced + key bounded`)
	if item.kind == "decor" then
		check(EventConfig.DecorSlots[(item.decor :: any).slot] ~= nil, `{item.key} has a decor slot`)
	end
end

-- 9. Owner R96 ground placement --------------------------------------------------------------------
local function near(a: number, b: number): boolean
	return math.abs(a - b) < 1e-4
end
-- The R96 bug: the template's PrimaryPart (Hitbox, 4.5 tall, bottom on the feet at y = 0) made
-- the pivot the hitbox centre (y = 2.25). Measured from the visual parts, the feet are y = 0.
local scale = EventConfig.Turkey.ModelScale
local birdBoxes = {
	{ cframe = CFrame.new(0, 1.35 * scale, 0.1 * scale), size = Vector3.new(1.777, 1.6, 1.8) * scale }, -- Body
	{ cframe = CFrame.new(-0.38 * scale, 0.369 * scale, 0), size = Vector3.new(0.391, 0.726, 0.469) * scale }, -- FeetL
	{ cframe = CFrame.new(0, 2.336 * scale, -0.611 * scale), size = Vector3.new(0.68, 1.147, 0.681) * scale }, -- Head
}
local midPivot = CFrame.new(0, 2.25, 0)
local feet = EventConfig.groundFrame(midPivot, birdBoxes)
local feetBottom = (0.369 - 0.726 / 2) * scale
check(near(feet.Position.Y, feetBottom), "feet = the lowest visual point, not the mid-bird pivot")
check(near(feet.Position.X, 0) and near(feet.Position.Z, 0), "feet keep the pivot's x / z")
-- Placing the feet frame on a ground point puts every box bottom at or above the ground.
local groundPoint = CFrame.new(40, 7.5, -12) * CFrame.Angles(0, math.rad(73), 0)
local lowestPlaced = math.huge
for _, box in birdBoxes do
	local placed = groundPoint * feet:ToObjectSpace(box.cframe)
	lowestPlaced = math.min(lowestPlaced, placed.Position.Y - box.size.Y / 2)
end
check(near(lowestPlaced, 7.5), "placed bird stands exactly on the ground (no part below it)")
-- A rotated part is measured by its corners, not its centre: a 4-stud bar tilted 90 degrees about
-- Z reaches 2 studs down from its centre.
local bar = { cframe = CFrame.new(0, 3, 0) * CFrame.Angles(0, 0, math.rad(90)), size = Vector3.new(4, 0.5, 0.5) }
check(near(EventConfig.groundFrame(CFrame.new(), { bar }).Position.Y, 1), "rotated part measured exactly")
-- A pivot that is itself yawed keeps its rotation (the bird keeps facing its path).
local yawed = CFrame.new(5, 2, 5) * CFrame.Angles(0, math.rad(30), 0)
local yawedFeet = EventConfig.groundFrame(yawed, { { cframe = CFrame.new(5, 1, 5), size = Vector3.new(1, 2, 1) } })
check(near(yawedFeet.Position.Y, 0) and near(yawedFeet.LookVector.X, yawed.LookVector.X), "pivot rotation kept")
-- Empty / junk input returns the pivot unchanged (never NaN).
check(EventConfig.groundFrame(midPivot, {}) == midPivot, "no boxes: pivot")
local junk = EventConfig.groundFrame(midPivot, { { cframe = CFrame.new(0, 0 / 0, 0), size = Vector3.one } })
check(junk.Position.Y == junk.Position.Y, "NaN box ignored")
-- The full peck nod tips the toes below the ground by a measurable, small amount (the renderer
-- lifts by it); without the lift a part would dip under the road.
local nod = CFrame.Angles(-math.rad(26), 0, 0)
local tipped = {}
for _, box in birdBoxes do
	table.insert(tipped, { cframe = nod * feet:ToObjectSpace(box.cframe), size = box.size })
end
local dip = -EventConfig.groundFrame(CFrame.identity, tipped).Position.Y
check(dip > 0 and dip < 1.5, `peck dip measured ({dip})`)
-- groundSnapY: climbs a curb within GroundUp, sinks within GroundDown, never onto a roof / car or
-- into a hole, and ignores no-hit / NaN.
local up, down = EventConfig.Turkey.GroundUp, EventConfig.Turkey.GroundDown
check(EventConfig.groundSnapY(0, 0.8, up, down) == 0.8, "curb climbed")
check(EventConfig.groundSnapY(0, -1, up, down) == -1, "dip followed")
check(EventConfig.groundSnapY(0, up + 0.5, up, down) == 0, "too high (car roof / bench) ignored")
check(EventConfig.groundSnapY(0, -(down + 0.5), up, down) == 0, "too deep (hole) ignored")
check(EventConfig.groundSnapY(3, nil, up, down) == 3, "no hit keeps the path height")
check(EventConfig.groundSnapY(3, 0 / 0, up, down) == 3, "NaN hit ignored")
check(up < 2 and down > 0 and EventConfig.Turkey.GroundHz >= 1, "ground follow tunables sane")
check(EventConfig.Turkey.PromptLift > 0, "prompt floats above the hitbox top")

-- 10. Owner R97 starter stickers ------------------------------------------------------------------
local starters = EventConfig.StarterStickers
check(#starters == EventConfig.Starter.Count and EventConfig.Starter.Count == 3, "3 starter stickers")
local topWeight = 0
for _, weight in EventConfig.RarityWeight do
	topWeight = math.max(topWeight, weight)
end
for position, index in starters do
	local def = EventConfig.Stickers[index]
	check(EventConfig.RarityWeight[def.rarity] == topWeight, `starter {def.name} is of the commonest rarity`)
	if position > 1 then
		check(index > starters[position - 1], "ties broken by the lowest sheet slot")
	end
end
check(starters[1] == 1 and starters[2] == 2 and starters[3] == 3, "Roast Turkey, Pumpkin Pie, Corn Cob")

local function stickerCount(record: any): number
	return EventConfig.countStickers(record.stickers)
end
-- New player: all 3.
local fresh = { season = "", acorns = 0, stickers = {}, redeemed = false, starterSeason = "" }
EventLogic.ensureSeason(fresh :: any, season.id)
local granted = EventLogic.grantStarters(fresh :: any, season.id)
check(#granted == 3 and stickerCount(fresh) == 3, "new sheet gets 3")
check(fresh.stickers[1] and fresh.stickers[2] and fresh.stickers[3], "the commonest three")
check(fresh.starterSeason == season.id, "season stamped")
-- Idempotent: a second join (or a second server) grants nothing.
check(#EventLogic.grantStarters(fresh :: any, season.id) == 0 and stickerCount(fresh) == 3, "idempotent")
-- An admin sheet reset in the same season does not re-grant (the stamp holds).
fresh.stickers = {}
check(#EventLogic.grantStarters(fresh :: any, season.id) == 0, "no re-grant in the same season")
-- Top-up: owns Sticker02 + a rare → gets one more (Sticker01), never a duplicate of Sticker02.
local partial =
	{ season = season.id, acorns = 5, stickers = { [2] = true, [9] = true }, redeemed = false, starterSeason = "" }
local topped = EventLogic.grantStarters(partial :: any, season.id)
check(#topped == 1 and topped[1] == 1 and stickerCount(partial) == 3, "1-sticker top-up to 3")
check(partial.stickers[2] and partial.stickers[9] and partial.acorns == 5, "owned stickers + acorns kept")
-- Owns one starter (Sticker01) → gets the next two unowned starters.
local one = { season = season.id, acorns = 0, stickers = { [1] = true }, redeemed = false }
local two = EventLogic.grantStarters(one :: any, season.id)
check(#two == 2 and two[1] == 2 and two[2] == 3 and stickerCount(one) == 3, "owned starter skipped")
-- 3+ stickers: nothing granted, but stamped (no later grant this season).
local rich = { season = season.id, acorns = 0, stickers = { [10] = true, [15] = true, [20] = true }, redeemed = false }
check(#EventLogic.grantStarters(rich :: any, season.id) == 0 and stickerCount(rich) == 3, "3+ stickers: none")
check(rich.starterSeason == season.id and rich.stickers[1] == nil, "stamped, nothing added")
-- Never removes anything: a full, redeemed sheet stays full + redeemed.
local full = { season = season.id, acorns = 0, stickers = {}, redeemed = true }
for index = 1, EventConfig.StickerCount do
	full.stickers[index] = true
end
EventLogic.grantStarters(full :: any, season.id)
check(stickerCount(full) == EventConfig.StickerCount and full.redeemed, "full sheet untouched")
-- Season scoping: a record of another season is skipped (and not stamped) until ensureSeason
-- moves it; then the new season grants again on its fresh sheet.
local lastYear =
	{ season = "harvest2025", acorns = 0, stickers = { [5] = true }, redeemed = false, starterSeason = "harvest2025" }
check(#EventLogic.grantStarters(lastYear :: any, season.id) == 0, "stale season: no grant")
check(lastYear.starterSeason == "harvest2025" and lastYear.stickers[5], "stale season: untouched")
EventLogic.ensureSeason(lastYear :: any, season.id)
check(#EventLogic.grantStarters(lastYear :: any, season.id) == 3, "new season: granted again")
-- A preview season (owner force-on before launch) does not block the real launch.
local preview = { season = season.id .. "_preview", acorns = 0, stickers = {}, redeemed = false }
EventLogic.grantStarters(preview :: any, season.id .. "_preview")
EventLogic.ensureSeason(preview :: any, season.id)
check(#EventLogic.grantStarters(preview :: any, season.id) == 3, "preview stamp does not block launch")
-- Missing stickers table (junk record) is repaired, not crashed on.
local junkRecord = { season = season.id, acorns = 0, redeemed = false }
check(#EventLogic.grantStarters(junkRecord :: any, season.id) == 3, "junk record repaired")
-- The Gobble Bomb still needs all 20: 3 starters are nowhere near a complete sheet.
check(EventLogic.redeemCheck(fresh :: any, true) == "incomplete", "starters do not complete the sheet")
local starterOnly = { season = season.id, acorns = 0, stickers = {}, redeemed = false }
EventLogic.grantStarters(starterOnly :: any, season.id)
check(EventLogic.redeemCheck(starterOnly :: any, true) == "incomplete", "3/20 cannot redeem")

print(`[event-logic] {checks} checks passed`)
