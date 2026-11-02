--!strict
--[[
	Retention rules (B7) on the shipped modules. Run:
		lune run tests/retention-logic

	Proves:
	  1. Daily streak (RetentionConfig.dailyStatus + DailyLogic.claim): first claim = Day 1, one
	     claim per UTC day, the next day continues, a missed day restarts at Day 1 (reset flag),
	     Day 7 wraps to Day 1 of a new cycle, a clock behind the last claim opens nothing,
	     junk days are refused, status and claim always agree.
	  2. Time rewards (PlaytimeLogic + PlaytimeConfig.status): rollover only forward, per-tick
	     and per-day caps, NaN / negative / inf credit mints nothing, claims need the minutes,
	     pay once per day, a new day reopens the ladder, the client view (set or array form).
	  3. Lucky wheel (WheelLogic + LuckySpinConfig.status): no back-fill on first contact, one
	     free spin per 20 min up to 3, timer idles at 3 and restarts on use, free before paid,
	     no spins → nil, the client status mirrors the server refill, roll respects the weights
	     (100 000 deterministic rolls within ±1 % of each slice's weight).
	  4. Codes: normalize (trim, upper case, junk refused), find, check (used / expired /
	     notStarted / ok), redeem once.
	  5. Boosts: extend stacks and caps, expired restarts from now, unknown key / junk refused,
	     multipliers per modifier field, prune.
	  6. Stock: count once per purchase id, junk records read as 0, sold keeps counting past
	     the id cap without remembering.
	  7. Rewards (RewardLogic): income scaling vs floor, gems / spins / boost applied, fields,
	     item granters (registered → item; missing / failing / false → fallback gems),
	     describe text.
]]

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local RetentionConfig = loader.load("src/shared/Config/RetentionConfig")
local PlaytimeConfig = loader.load("src/shared/Config/PlaytimeConfig")
local LuckySpinConfig = loader.load("src/shared/Config/LuckySpinConfig")
local CodesConfig = loader.load("src/shared/Config/CodesConfig")
local BoostConfig = loader.load("src/shared/Config/BoostConfig")
local DailyLogic = loader.load("src/server/Retention/DailyLogic")
local PlaytimeLogic = loader.load("src/server/Retention/PlaytimeLogic")
local WheelLogic = loader.load("src/server/Retention/WheelLogic")
local CodeLogic = loader.load("src/server/Retention/CodeLogic")
local BoostLogic = loader.load("src/server/Retention/BoostLogic")
local StockLogic = loader.load("src/server/Retention/StockLogic")
local RewardLogic = loader.load("src/server/Retention/RewardLogic")
local ProfileLogic = loader.load("src/server/Economy/ProfileLogic")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

-- 1. Daily streak -------------------------------------------------------------------------------
local daily = { streak = 0, lastDay = -1 }
local day0 = 20_000
local status = RetentionConfig.dailyStatus(daily, day0)
check(status.canClaim and status.nextIndex == 1 and status.claimedUpTo == 0 and not status.resetting, "fresh")
local index, reset = DailyLogic.claim(daily, day0)
check(index == 1 and not reset and daily.streak == 1 and daily.lastDay == day0, "first claim = Day 1")
check(DailyLogic.claim(daily, day0) == nil, "one claim per day")
status = RetentionConfig.dailyStatus(daily, day0)
check(not status.canClaim and status.claimedUpTo == 1 and status.nextIndex == 2, "claimed today view")
for expected = 2, 7 do
	local day = day0 + expected - 1
	check(RetentionConfig.dailyStatus(daily, day).nextIndex == expected, `status says Day {expected}`)
	check(DailyLogic.claim(daily, day) == expected, `continues to Day {expected}`)
end
status = RetentionConfig.dailyStatus(daily, day0 + 6)
check(status.claimedUpTo == 7 and status.nextIndex == 1, "Day 7 claimed: full cycle shown, Day 1 next")
status = RetentionConfig.dailyStatus(daily, day0 + 7)
check(status.canClaim and status.nextIndex == 1 and status.claimedUpTo == 0 and not status.resetting, "new cycle")
check(DailyLogic.claim(daily, day0 + 7) == 1 and daily.streak == 8, "Day 7 wraps to Day 1 (streak keeps counting)")
check(DailyLogic.claim(daily, day0 + 8) == 2, "cycle 2 Day 2")
status = RetentionConfig.dailyStatus(daily, day0 + 10)
check(status.canClaim and status.nextIndex == 1 and status.resetting, "missed a day → reset")
index, reset = DailyLogic.claim(daily, day0 + 10)
check(index == 1 and reset and daily.streak == 1, "reset claim restarts at Day 1")
check(not RetentionConfig.dailyStatus(daily, day0 + 5).canClaim, "clock behind: nothing opens")
check(DailyLogic.claim(daily, day0 + 5) == nil and daily.lastDay == day0 + 10, "clock behind: no claim")
check(DailyLogic.claim(daily, 0 / 0) == nil and DailyLogic.claim(daily, day0 + 11.5) == nil, "junk day refused")
check(
	RetentionConfig.utcDay(1_793_318_400) == 20_756 and RetentionConfig.secondsToNextDay(1_793_318_400) == 86_400,
	"utc"
)

-- 2. Time rewards -------------------------------------------------------------------------------
local state = { day = -1, seconds = 0, claimed = {} }
check(PlaytimeLogic.rollover(state, 100) and state.day == 100, "first rollover")
check(not PlaytimeLogic.rollover(state, 99) and state.day == 100, "never backwards")
check(PlaytimeLogic.accrue(state, 1, 100) == 1, "credit 1 s")
check(PlaytimeLogic.accrue(state, 60, 100) == PlaytimeConfig.MaxTickCredit, "per-tick cap")
for _, junk in { 0 / 0, -5, math.huge, 0 } do
	check(PlaytimeLogic.accrue(state, junk, 100) == 0, `junk credit {junk}`)
end
-- Owner R89 ladder: gift 1 at 1 min, gift 2 at 3 min (tests/gift-ladder.luau covers the rest).
state.seconds = 0
check(PlaytimeLogic.claim(state, 1, 100) == "locked", "gift 1 needs 1 min")
state.seconds = 60
check(PlaytimeLogic.claim(state, 1, 100) == "ok", "gift 1 at 1 min")
check(PlaytimeLogic.claim(state, 1, 100) == "claimed", "gift 1 once")
check(PlaytimeLogic.claim(state, 2, 100) == "locked", "gift 2 needs 3 min")
check(
	PlaytimeLogic.claim(state, 11, 100) == "invalid" and PlaytimeLogic.claim(state, 1.5, 100) == "invalid",
	"bad index"
)
local view = PlaytimeConfig.status(state, 100)
check(view[1].state == "claimed" and view[2].state == "locked" and view[2].secondsLeft == 120, "server view")
local snapshotForm = { day = 100, seconds = 60, claimed = { 1 } }
check(PlaytimeConfig.status(snapshotForm, 100, 120)[2].state == "ready", "client view: array form + extrapolation")
state.seconds = PlaytimeConfig.MaxSecondsPerDay - 1
PlaytimeLogic.accrue(state, 5, 100)
check(state.seconds == PlaytimeConfig.MaxSecondsPerDay, "day cap")
check(PlaytimeLogic.claim(state, 10, 101) == "locked" and state.day == 101 and state.seconds == 0, "new day reopens")
check(PlaytimeLogic.claim(state, 1, 101) == "locked" and next(state.claimed) == nil, "new day: nothing claimed")
check(PlaytimeConfig.status(state, 102)[1].state == "locked", "stale day reads as fresh")

-- 3. Lucky wheel --------------------------------------------------------------------------------
local every = LuckySpinConfig.FreeEverySeconds
local spin = { free = 1, lastFreeAt = 0, paid = 0, bonus = 0 }
local t0 = 1_800_000_000
check(WheelLogic.refill(spin, t0) == 1 and spin.lastFreeAt == t0, "first contact starts the timer, no back-fill")
check(LuckySpinConfig.status(spin, t0 + every - 1).free == 1, "not yet")
check(WheelLogic.refill(spin, t0 + every) == 2, "one free spin per 20 min")
check(LuckySpinConfig.status(spin, t0 + every * 10).free == 3, "client status caps at 3")
check(WheelLogic.refill(spin, t0 + every * 10) == 3, "server caps at 3")
check(LuckySpinConfig.status(spin, t0 + every * 20).nextFreeIn == 0, "timer idles at max")
check(WheelLogic.consume(spin, t0 + every * 20, false) == "free" and spin.free == 2, "free spin used")
check(spin.lastFreeAt == t0 + every * 20, "timer restarts when the bank drops below max")
local mid = LuckySpinConfig.status(spin, t0 + every * 20 + 100)
check(mid.free == 2 and mid.nextFreeIn == every - 100, "countdown")
spin.free, spin.paid, spin.bonus = 0, 2, 1
spin.lastFreeAt = t0 + every * 30
-- Spend order free → bonus → paid; a PAID (Robux) spin needs an allowed policy (fail closed).
check(WheelLogic.peek(spin, t0 + every * 30 + 1) == "bonus", "peek: bonus before paid")
check(WheelLogic.consume(spin, t0 + every * 30 + 2, false) == "bonus" and spin.bonus == 0, "bonus always spins")
check(WheelLogic.peek(spin, t0 + every * 30 + 3) == "paid", "peek: paid last")
local blocked, why = WheelLogic.consume(spin, t0 + every * 30 + 4, false)
check(blocked == nil and why == "restricted" and spin.paid == 2, "restricted: paid spins kept, nothing used")
check(WheelLogic.consume(spin, t0 + every * 30 + 5, true) == "paid" and spin.paid == 1, "paid when allowed")
spin.paid = 0
local none, noneWhy = WheelLogic.consume(spin, t0 + every * 30 + 6, true)
check(none == nil and noneWhy == "none", "no spins")
-- Junk banks never go negative and never spin.
local junk = { free = 0, lastFreeAt = t0 + every * 30, paid = 0 / 0, bonus = -4 }
check(WheelLogic.peek(junk, t0 + every * 30 + 7) == nil, "junk banks are empty")
-- Spins product receipts: unknown → defer (unchanged), restricted → gems, allowed → paid spins.
do
	local buyer = ProfileLogic.defaultProfile()
	local before = ProfileLogic.deepCopy(buyer)
	local outcome, amount = WheelLogic.receipt(buyer, 5, false, true)
	check(
		outcome == "defer" and amount == 0 and ProfileLogic.deepCopy(buyer).spin.paid == before.spin.paid,
		"unknown defers"
	)
	outcome, amount = WheelLogic.receipt(buyer, 5, false, false)
	check(outcome == "defer", "unknown defers even if the stale flag says allowed")
	outcome, amount = WheelLogic.receipt(buyer, 5, true, true)
	check(
		outcome == "gems" and amount == 5 * LuckySpinConfig.GemsPerSpin and buyer.spin.paid == 0,
		"restricted → gems"
	)
	check(buyer.gems == before.gems, "receipt gems are granted by the caller (analytics source)")
	outcome, amount = WheelLogic.receipt(buyer, 5, true, false)
	check(outcome == "spins" and amount == 5 and buyer.spin.paid == 5 and buyer.spin.bonus == 0, "allowed → paid")
	for _, bad in { 0, -1, 1.5, 0 / 0, "5" } do
		check(WheelLogic.receipt(buyer, bad, true, false) == "defer" and buyer.spin.paid == 5, `bad spins {bad}`)
	end
	check(LuckySpinConfig.GemsPerSpin == 40, "documented rate (Spins5 price at the GemsSmall rate)")
	local status = LuckySpinConfig.status({ free = 0, lastFreeAt = t0, paid = 3, bonus = 2 }, t0)
	check(status.bonus == 2 and status.paid == 3 and LuckySpinConfig.nextSource(status) == "bonus", "status banks")
	check(LuckySpinConfig.status({ free = 0, lastFreeAt = t0, paid = 1 } :: any, t0).bonus == 0, "old snapshot bonus 0")
end
spin = { free = 0, lastFreeAt = t0 + 10_000, paid = 0, bonus = 0 }
check(WheelLogic.refill(spin, t0) == 0 and spin.lastFreeAt == t0, "clock jump back restarts the timer safely")
local counts: { number } = {}
local random = Loader.Random.new(7)
local ROLLS = 100_000
for _ = 1, ROLLS do
	local slice = WheelLogic.roll(random:NextNumber())
	counts[slice] = (counts[slice] or 0) + 1
end
for sliceIndex, slice in LuckySpinConfig.Slices do
	local share = (counts[sliceIndex] or 0) / ROLLS * LuckySpinConfig.TotalWeight
	check(math.abs(share - slice.weight) <= 1, `slice {slice.id} odds {share} vs {slice.weight}`)
end
check(WheelLogic.roll(0) == 1 and WheelLogic.roll(0.999999) == #LuckySpinConfig.Slices, "roll bounds")
check(WheelLogic.roll(0 / 0) == 1 and WheelLogic.roll(5) == #LuckySpinConfig.Slices, "roll junk clamped")

-- 4. Codes --------------------------------------------------------------------------------------
check(CodesConfig.normalize("  nukes ") == "NUKES", "normalize")
check(CodesConfig.normalize("") == nil and CodesConfig.normalize("a b") == nil, "normalize refuses junk")
check(CodesConfig.normalize(string.rep("A", 21)) == nil and CodesConfig.normalize(5) == nil, "normalize length / type")
local launch = CodesConfig.find("Nukes")
check(launch ~= nil and launch.id == "launch", "find case-insensitive")
check(CodesConfig.find("NOPE") == nil, "unknown code")
local codes = {}
check(CodeLogic.check(launch, codes, 0) == "ok", "ok")
check(CodeLogic.redeem(launch, codes) and not CodeLogic.redeem(launch, codes), "redeem once")
check(CodeLogic.check(launch, codes, 0) == "used", "used")
local harvest = CodesConfig.find("harvest")
check(CodeLogic.check(harvest, {}, 1_793_491_199) == "notStarted", "not started")
check(CodeLogic.check(harvest, {}, 1_793_491_200) == "ok", "starts")
check(CodeLogic.check(harvest, {}, 1_796_083_200) == "expired", "expires (exclusive)")
check(CodeLogic.check(CodesConfig.find("spooky"), {}, 1_793_491_200) == "expired", "spooky expired")

-- 5. Boosts -------------------------------------------------------------------------------------
local boosts: { [string]: number } = {}
check(BoostLogic.extend(boosts, "cash2x", 600, 1000) == 1600, "new boost")
check(BoostLogic.extend(boosts, "cash2x", 600, 1100) == 2200, "stacks from expiry")
check(BoostLogic.extend(boosts, "cash2x", 1e9, 1100) == 1100 + BoostConfig.MaxStackSeconds, "capped")
check(
	BoostLogic.extend(boosts, "nope", 60, 1100) == nil and BoostLogic.extend(boosts, "cash2x", 0 / 0, 1100) == nil,
	"junk"
)
boosts.speed2x = 900
check(BoostLogic.extend(boosts, "speed2x", 60, 1000) == 1060, "expired restarts from now")
local mods = BoostLogic.multipliers(boosts, 1050)
check(mods.boostCash == 2 and mods.boostSpeed == 2, "multipliers")
check(BoostLogic.multipliers(boosts, 1e12).boostCash == nil, "nothing active later")
check(
	BoostLogic.nextExpiry(boosts, 1050) == 1060 and BoostLogic.nextExpiry(boosts, 1e12) == nil,
	"next expiry (cache hint)"
)
boosts.bogus = 99999
check(BoostLogic.prune(boosts, 1070) == 2 and boosts.speed2x == nil and boosts.cash2x ~= nil, "prune expired + unknown")

-- 6. Stock --------------------------------------------------------------------------------------
local record, outcome = StockLogic.count(nil, "p1")
check(record.sold == 1 and outcome == "counted", "first sale")
record, outcome = StockLogic.count(record, "p1")
check(record.sold == 1 and outcome == "already", "idempotent")
record = StockLogic.count(record, "p2")
check(StockLogic.read(record) == 2 and StockLogic.read("junk") == 0 and StockLogic.read({ sold = 0 / 0 }) == 0, "read")
local full = { sold = StockLogic.MaxIds, ids = {} }
for i = 1, StockLogic.MaxIds do
	full.ids[`id{i}`] = true
end
local after = StockLogic.count(full, "late")
check(after.sold == StockLogic.MaxIds + 1 and after.ids.late == nil, "past the id cap: counted, not remembered")

-- 7. Rewards ------------------------------------------------------------------------------------
local profile = ProfileLogic.defaultProfile()
check(RewardLogic.incomeOf(profile) == 0, "no managers → no income")
check(RewardLogic.cashFor({ cashSeconds = 60, cashFloor = 500 }, 0) == 500, "floor when no income")
check(RewardLogic.cashFor({ cashSeconds = 60, cashFloor = 500 }, 100) == 6000, "income scaled")
check(RewardLogic.cashFor({ gems = 5 }, 100) == 0 and RewardLogic.cashFor({ cashSeconds = 60 }, 0 / 0) == 0, "no cash")
local summary = RewardLogic.apply(profile, {
	cashSeconds = 60,
	cashFloor = 500,
	gems = 10,
	spins = 2,
	boost = { key = "cash2x", seconds = 600 },
}, 5000, nil, 100)
check(summary.cash == 6000 and profile.cash == 6000 and profile.totalEarned == 6000, "cash applied")
-- Reward spins are FREE (bonus bank); only Robux rewards (paidSpins) fill the gated paid bank.
check(summary.gems == 10 and profile.gems == 10 and summary.spins == 2 and profile.spin.bonus == 2, "gems + spins")
check(profile.spin.paid == 0, "free reward spins never land in the paid bank")
check(profile.boosts.cash2x == 5600 and summary.boost ~= nil, "boost applied")
check(table.concat(summary.fields, ",") == "boosts,cash,gems,spin,totalEarned", "fields touched")
local text = RewardLogic.describe(summary)
check(string.find(text, "+$6K", 1, true) ~= nil and string.find(text, "+10 Gems", 1, true) ~= nil, `describe: {text}`)
summary = RewardLogic.apply(profile, { pet = "lucky_atom", fallbackGems = 60 }, 5000, nil, 0)
check(summary.pet == nil and summary.fallbackGems == 60 and summary.gems == 60, "no granter → fallback gems")
local granted: { string } = {}
local granters = {
	pet = function(_p: any, id: string): boolean
		table.insert(granted, id)
		return true
	end,
	egg = function(): boolean
		error("boom")
	end,
}
summary = RewardLogic.apply(profile, { pet = "lucky_atom", fallbackGems = 60 }, 5000, granters, 0)
check(summary.pet == "lucky_atom" and summary.gems == 0 and granted[1] == "lucky_atom", "granter used")
check(table.find(summary.fields, "pets") ~= nil, "pets field marked")
summary = RewardLogic.apply(profile, { egg = "lucky_egg", fallbackGems = 15 }, 5000, granters, 0)
check(summary.egg == nil and summary.gems == 15, "failing granter → fallback")
check(RewardLogic.describe(RewardLogic.apply(profile, {}, 0, nil, 0)) == "nothing", "empty reward")

print(`[retention-logic] {checks} checks passed`)
