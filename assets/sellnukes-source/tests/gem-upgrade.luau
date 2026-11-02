--!strict
--[[
	Owner R86 gem upgrade regressions ("just buy the next upgrade with gems, but it stays at the
	same price for everything"). Run:
		lune run tests/gem-upgrade

	Loads the SHIPPED pure modules and proves:
	  1. Config: the flat price sits inside the admin range; the confirm window is shorter than the
	     repeat window; the spend reason is a clean analytics reason id; the analytics allowlists
	     carry the "gem" upgrade mode and the GemUpgrade transaction type.
	  2. Pacing guard (docs/economy.md "Gem upgrade", measured with the real simulator): at the
	     shipped price a "few thousand" gems (3,000) buy at most 40 levels, the level count that
	     halves an area instead of skipping it; 25 gems (the first proposal) would buy 120.
	  3. GemUpgradeRules.price: untrusted attribute values (nil, NaN, inf, fractions, out of range,
	     strings) fall back to the config default; in-range whole numbers pass.
	  4. GemUpgradeRules.enabled: off only for an explicit false.
	  5. GemUpgradeRules.check: switch off, not built, at MaxLevel, short of gems (incl. NaN gems),
	     the exact-price edge, no gem check when gems is nil (server: the atomic spend decides).
	  6. GemConfirmLogic: first press arms, second within ConfirmSeconds buys, an expired arm
	     re-arms, another producer moves the arm, presses within RepeatSeconds of the last buy go
	     straight through (any producer) and each buy restarts the window, cancel keeps the window.
]]

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local TycoonConfig = loader.load("src/shared/Config/TycoonConfig")
local AnalyticsConfig = loader.load("src/shared/Config/AnalyticsConfig")
local GemUpgradeRules = loader.load("src/shared/Tycoon/GemUpgradeRules")
local GemConfirmLogic = loader.load("src/client/Tycoon/GemConfirmLogic")

local checks = 0
local function check(condition: any, label: string)
	if not condition then
		error(`FAIL: {label}`, 2)
	end
	checks += 1
end
local function eq(actual: any, expected: any, label: string)
	if actual ~= expected then
		error(`FAIL: {label}: expected {tostring(expected)}, got {tostring(actual)}`, 2)
	end
	checks += 1
end

local Gem = TycoonConfig.GemUpgrade
local PRICE = TycoonConfig.GemUpgradePrice

-- 1. Config ------------------------------------------------------------------------------------------
check(PRICE % 1 == 0 and PRICE >= Gem.MinPrice and PRICE <= Gem.MaxPrice, "default price inside the admin range")
check(Gem.MinPrice >= 1, "a gem level is never free")
check(Gem.ConfirmSeconds > 0 and Gem.ConfirmSeconds < Gem.RepeatSeconds, "confirm window < repeat window")
check(string.find(Gem.Reason, "^%a+$") ~= nil, "spend reason is a clean analytics reason id")
check(table.find(AnalyticsConfig.Tycoon.UpgradeModes, "gem") ~= nil, "analytics allowlist has upgradeMode gem")
eq(AnalyticsConfig.Economy.TransactionTypes[Gem.Reason], "Shop", "gem sink booked as a Shop sink")

-- 2. Pacing guard --------------------------------------------------------------------------------------
-- Simulator (levels bought the moment an area's producer is built): 40 levels = area 1 8 -> 2.9 min,
-- area 9 80 -> 39.7 min (halved); 60 = 1.4 / 15.3; 120 = 0.6 / 2.8 (skipped). Keep 3,000 gems <= 40.
check(GemUpgradeRules.levelsFor(3000, PRICE) <= 40, `3,000 gems buy <= 40 levels at {PRICE}`)
eq(GemUpgradeRules.levelsFor(3000, 25), 120, "the 25-gem proposal: 3,000 gems = 120 levels (skips areas)")
eq(GemUpgradeRules.levelsFor(1000, 75), 13, "a 1,000-gem pack at 75 = 13 levels")
eq(GemUpgradeRules.levelsFor(0, 75), 0, "no gems, no levels")
eq(GemUpgradeRules.levelsFor(100, 0), 0, "bad price, no levels")
eq(GemUpgradeRules.levelsFor(0 / 0, 75), 0, "NaN gems, no levels")

-- 3. Price sanitising -----------------------------------------------------------------------------------
eq(GemUpgradeRules.price(nil), PRICE, "missing attribute = default")
eq(GemUpgradeRules.price(0 / 0), PRICE, "NaN = default")
eq(GemUpgradeRules.price(math.huge), PRICE, "inf = default")
eq(GemUpgradeRules.price(12.5), PRICE, "fraction = default")
eq(GemUpgradeRules.price(0), PRICE, "below MinPrice = default")
eq(GemUpgradeRules.price(Gem.MaxPrice + 1), PRICE, "above MaxPrice = default")
eq(GemUpgradeRules.price("50"), PRICE, "string = default")
eq(GemUpgradeRules.price(100), 100, "admin price 100 passes")
eq(GemUpgradeRules.price(Gem.MinPrice), Gem.MinPrice, "MinPrice passes")
eq(GemUpgradeRules.price(Gem.MaxPrice), Gem.MaxPrice, "MaxPrice passes")

-- 4. Switch ----------------------------------------------------------------------------------------------
check(GemUpgradeRules.enabled(nil), "unpublished switch = on (server re-checks)")
check(GemUpgradeRules.enabled(true), "on")
check(not GemUpgradeRules.enabled(false), "explicit false = off")
check(GemUpgradeRules.enabled("false"), "only a real false switches it off")

-- 5. Can-buy rules ---------------------------------------------------------------------------------------
local function facts(over: { [string]: any }?): any
	local base = { enabled = true, level = 12, maxLevel = 1000, gems = 500, price = 75 }
	for key, value in over or {} do
		base[key] = value
	end
	return base
end
local ok, reason = GemUpgradeRules.check(facts())
check(ok and reason == "ok", "built, below max, enough gems: ok")
ok, reason = GemUpgradeRules.check(facts({ enabled = false }))
check(not ok and reason == "off", "switch off")
ok, reason = GemUpgradeRules.check(facts({ level = 0 }))
check(not ok and reason == "notBuilt", "not built")
ok, reason = GemUpgradeRules.check(facts({ level = 0 / 0 }))
check(not ok and reason == "notBuilt", "NaN level = not built")
ok, reason = GemUpgradeRules.check(facts({ level = 1000 }))
check(not ok and reason == "max", "at MaxLevel: hidden")
ok, reason = GemUpgradeRules.check(facts({ level = 999 }))
check(ok, "one below MaxLevel: the last level is buyable")
ok, reason = GemUpgradeRules.check(facts({ gems = 74 }))
check(not ok and reason == "gems", "one gem short")
ok, reason = GemUpgradeRules.check(facts({ gems = 75 }))
check(ok, "exact price is enough")
ok, reason = GemUpgradeRules.check(facts({ gems = 0 / 0 }))
check(not ok and reason == "gems", "NaN gems = short")
ok, reason = GemUpgradeRules.check(facts({ gems = nil :: any }))
check(ok, "no gem check when gems is nil (server: atomic spend decides)")
ok, reason = GemUpgradeRules.check(facts({ enabled = false, level = 1000, gems = 0 }))
check(reason == "off", "the switch is reported first")

-- 6. Confirm state machine ---------------------------------------------------------------------------------
local C, R = Gem.ConfirmSeconds, Gem.RepeatSeconds
do
	local state = GemConfirmLogic.new()
	eq(GemConfirmLogic.press(state, "p1", 100, C, R), "arm", "first press arms")
	check(GemConfirmLogic.isArmed(state, "p1", 100 + C, C), "armed for ConfirmSeconds")
	check(not GemConfirmLogic.isArmed(state, "p2", 100, C), "only that producer is armed")
	eq(GemConfirmLogic.press(state, "p1", 100 + C - 0.1, C, R), "buy", "second press within the window buys")
	check(not GemConfirmLogic.isArmed(state, "p1", 100 + C, C), "a buy disarms")
	-- Repeat window: any producer, each buy restarts it.
	local t = 100 + C - 0.1
	eq(GemConfirmLogic.press(state, "p2", t + R - 0.1, C, R), "buy", "repeat press on another producer buys")
	t = t + R - 0.1
	eq(GemConfirmLogic.press(state, "p1", t + R - 0.1, C, R), "buy", "each buy restarts the window")
	t = t + R - 0.1
	eq(GemConfirmLogic.press(state, "p1", t + R + 0.5, C, R), "arm", "after the window: confirm again")
end
do
	local state = GemConfirmLogic.new()
	eq(GemConfirmLogic.press(state, "p1", 10, C, R), "arm", "arm")
	check(not GemConfirmLogic.isArmed(state, "p1", 10 + C + 0.1, C), "an arm expires by itself")
	eq(GemConfirmLogic.press(state, "p1", 10 + C + 0.1, C, R), "arm", "an expired arm re-arms (no buy)")
	eq(GemConfirmLogic.press(state, "p2", 10 + C + 0.5, C, R), "arm", "another producer moves the arm")
	check(not GemConfirmLogic.isArmed(state, "p1", 10 + C + 0.5, C), "the old arm is gone")
	check(GemConfirmLogic.isArmed(state, "p2", 10 + C + 0.5, C), "the new one is armed")
	GemConfirmLogic.cancel(state)
	check(not GemConfirmLogic.isArmed(state, "p2", 10 + C + 0.6, C), "cancel disarms")
	check(not GemConfirmLogic.inRepeat(state, 10 + C + 0.6, R), "no buy yet: no repeat window")
end
do
	local state = GemConfirmLogic.new()
	GemConfirmLogic.press(state, "p1", 0, C, R)
	GemConfirmLogic.press(state, "p1", 1, C, R) -- buy
	GemConfirmLogic.cancel(state)
	check(GemConfirmLogic.inRepeat(state, 2, R), "cancel keeps the repeat window")
	eq(GemConfirmLogic.press(state, "p1", 2, C, R), "buy", "still buys straight away")
end

print(`[gem-upgrade] {checks} checks passed`)
