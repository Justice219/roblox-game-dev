--!strict
--[[
	ProfileLogic regressions (src/server/Economy/ProfileLogic.luau). Run:
		lune run tests/profile-logic

	Proves on the shipped module:
	  1. defaultProfile() is EXACTLY the build plan's schema v1 (every key, every default value,
	     no extras) and returns fresh tables every call.
	  2. migrate(): non-tables → "new"; current data → "current"; a missing schemaVersion → v1;
	     a newer schema → "newer" (kept as-is for the read-only session).
	  3. reconcile() repairs hostile data: wrong types, NaN / inf / negative / huge numbers, long
	     and invalid UTF-8 strings, oversized maps, dangling equipped pets, colliding nextUid,
	     numeric sets in both map and array form.
	  4. Currency: addCash (also totalEarned, clamp), spendCash (atomic, no negative dust),
	     addGems / spendGems (whole only).
	  5. Receipts: record once, repeat refused, ledger trimmed to the newest 64 (the new one is
	     never evicted).
	  6. applySetting: allowlisted keys, booleans only, change detection.
	  7. toSave(): numeric sets → arrays, non-finite numbers scrubbed (with a warning), live
	     profile untouched; migrate(toSave(p)) round-trips to an equal profile.
	  8. snapshot(): never contains private data (receipts, codes, offline, analytics,
	     lastSaveAt, nextUid), sets become arrays, values are copies, `fields` builds a subset.
	  9. analytics.payDays (B13): canonical block keys "0".."1562" only, whole 32-bit masks,
	     bounded, saved as a JSON-safe string-keyed map, round-trips, never sent to the client.
	 10. B9 pets.eggs / pets.pity / pets.index, crates { held, pity, opened }, trails { owned,
	     equipped ⊆ owned } and B10 attack.barrage: hostile values repaired, zero counts dropped,
	     maps bounded, round-trip through toSave, present (as copies) in the snapshot.
	 11. B11 event.decor ([%w_-] ≤ 24-byte keys, ≤ 32), event.turkeys, event.lures: repaired,
	     bounded, round-trip, in the `event` snapshot field (decor as a copied key set); owner R97
	     event.starterSeason: additive, bounded, round-trips, never in the snapshot.
	 12. Schema v2 (owner R57 World 2, spec §10): a realistic v1 save migrates to v2 with EVERY v1
	     value carried over, `worlds` defaulted and `lastWorld = "main"`; the migration is
	     idempotent and round-trips through toSave + a real JSON encode / decode; a v3 save opens as
	     "newer"; garbage / NaN / huge values in worlds.* are repaired; unknown well-formed world
	     keys are kept and malformed ones dropped; the cap of 8 worlds keeps known worlds first;
	     known worlds clamp area to their area count; pad sets are bounded; lastWorld rules; the
	     world currency / token math; worldState errors on misuse; the snapshot shape (structure
	     only, known worlds only, copies) and the partial `worldCash` build.
	 13. Owner R88 plotName: top-level (outside tycoon, so Rebirth keeps it), default "", junk /
	     invalid UTF-8 → "", capped on characters, round-trips through toSave / migrate (v1 too),
	     its own snapshot field (a rename pushes only `plotName`).
]]

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local ProfileLogic = loader.load("src/server/Economy/ProfileLogic")
local WorldGeometry = loader.load("src/shared/Config/Worlds/WorldGeometry")
local serde = require("@lune/serde")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

-- Deep equality for plain data (used to compare profiles).
local function deepEqual(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for key, value in a do
		if not deepEqual(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

-- R57 (schema v2): the default state of one non-main world, exactly as spec §10 lists it.
local function expectedWorld(): any
	return {
		unlocked = false,
		unlockedAt = 0,
		cash = 0,
		totalEarned = 0,
		tycoon = { pads = {}, producers = {}, area = 1, standName = "", lastSaveAt = 0, tutorialStep = 0 },
		rebirths = 0,
		rebirthTokens = 0,
		rebirthShop = {},
		stats = { playSeconds = 0, runSeconds = 0, visits = 0, padsBought = 0, clicks = 0, lastVisitDay = -1 },
		starter = { bought = false }, -- W2: the world's one-time WorldStarter pack flag
	}
end
check(table.find(ProfileLogic.KnownWorlds, "dino") ~= nil, "Dino Valley is a known world")
check(table.find(ProfileLogic.KnownWorlds, "main") == nil, "main is never a profile.worlds key")
local expectedWorlds = {}
for _, worldId in ProfileLogic.KnownWorlds do
	expectedWorlds[worldId] = expectedWorld()
end

-- 1. Schema v2 exactly as the build plan lists it (v1 fields + worlds + lastWorld).
local EXPECTED = {
	schemaVersion = 2,
	cash = 0,
	gems = 0,
	totalEarned = 0,
	rebirths = 0,
	rebirthTokens = 0,
	rebirthShop = {},
	tycoon = { pads = {}, producers = {}, area = 1, standName = "", lastSaveAt = 0, tutorialStep = 0 },
	stats = { playSeconds = 0, clicks = 0, padsBought = 0, launches = 0, hits = 0, hatched = 0 },
	passes = {},
	receipts = {},
	-- plan fields + B9's pets / crates / trails blocks (2026-10-30 request) + R78 indexClaimed
	pets = { owned = {}, equipped = {}, nextUid = 1, eggs = {}, pity = {}, index = {}, indexClaimed = {} },
	crates = { held = {}, pity = {}, opened = 0 },
	trails = { owned = {}, equipped = "" },
	boosts = {},
	daily = { streak = 0, lastDay = -1 },
	-- + owner R89's gift ladder version (PlaytimeConfig.LadderVersion; older saves = 1)
	timeRewards = { day = -1, seconds = 0, claimed = {}, ladder = 2 },
	-- + the paid-random spin split (2026-10-30): bonus = free reward spins
	spin = { free = 1, lastFreeAt = 0, paid = 0, bonus = 0 },
	codes = {},
	group = { claimed = false },
	notify = { claimed = false, hour = -1 }, -- owner R122: usual start hour unknown
	offline = { lastSeenAt = 0 },
	starter = { bought = false },
	secretPack = { bought = false },
	-- + B10's stored Barrage nukes (2026-10-30 request)
	-- + owner R80's defence tower slot levels (attack.towers, dense list; tests/attack-defense.luau)
	attack = {
		aa = 0,
		launcher = 0,
		shieldUntil = 0,
		cooldownUntil = 0,
		hitsTaken = 0,
		barrage = 0,
		towers = {},
		golden = 0, -- owner R85 stored golden revenge nukes
	},
	-- + B11's Harvest Feast fields (2026-10-30 request)
	-- + owner R97's starterSeason (free starter stickers; "" = never granted)
	event = {
		season = "",
		acorns = 0,
		stickers = {},
		redeemed = false,
		decor = {},
		turkeys = 0,
		lures = 0,
		starterSeason = "",
	},
	-- + B16's haptics toggle (2026-10-30 request)
	settings = {
		music = true,
		sfx = true,
		reducedMotion = false,
		hideOtherPets = false,
		haptics = true,
		fastHatch = false,
		autoClicker = true, -- owner R64: the AutoClicker pass's on / off toggle
		showTitle = true, -- owner R73 / R74: a title holder's own tag on / off
	},
	-- plan fields + B13's analytics-owned keys (2026-10-30 request)
	analytics = {
		first = 0,
		last = 0,
		payFirst = 0,
		payLast = 0,
		marks = 0,
		robux = 0,
		seenDay = 0,
		seen = 0,
		ftue = 0,
		runAt = 0,
		play = 0,
		carry = 0,
		sessions = 0,
		rbxDay = 0, -- owner R122 capped playtime (W-R122-analytics)
		rbxSec = 0,
		staff = false,
		payDays = {}, -- B13 payer-day bitmap (2026-10-30 request)
		outbox = {},
	},
	-- + the WHAT'S NEW seen record (owner R58, ChangeNotesConfig.newState)
	notes = { seen = "", at = 0 },
	-- + owner R74's granted Player Titles (none on a fresh profile)
	titles = {},
	-- + owner R78's Nuke Pass (PassConfig.newState: no season played yet)
	pass = {
		season = "",
		xp = 0,
		dayXp = 0,
		day = 0,
		claimedFree = {},
		claimedPremium = {},
		premium = {},
		overflow = 0,
	},
	-- + owner R78's Rush boosts and referrals (none on a fresh profile; RushService grants rookie)
	rush = { rookieLeft = 0, comebackUntil = 0 },
	referral = { by = 0, paid = 0, seen = {} },
	-- + owner R78's Quests record (QuestConfig.newState: chain at goal 1, nothing seeded)
	quests = {
		starter = {
			step = 0,
			base = {},
			claimed = { false, false, false, false, false, false, false, false, false, false, false, false },
		},
		daily = { day = -1, picks = {}, chest = false, rerolled = false },
		life = {},
		trophies = {},
	},
	-- + schema v2 (owner R57 World 2): every known non-main world, and the last session's world
	worlds = expectedWorlds,
	lastWorld = "main",
	-- + owner R88's custom plot name ("" = the default "<DisplayName>'s Nukes" sign)
	plotName = "",
	-- + owner R89's Pocket Rocket day + one-time favorite prompt record (GiftsConfig.newState)
	gifts = { rocketDay = -1, favorite = 0, favoriteAsks = 0 },
	-- + owner R89's Flavour Book (Shared/Tycoon/FlavorLogic; tests/flavor-logic.luau)
	flavors = { found = {}, claimed = {}, tip = false }, -- + owner R112's one-time tip flag
	-- + owner R90's Mega Lever cooldowns + Tip Jar coins (Shared/Tycoon/KineticLogic; server-only)
	kinetic = { worlds = {} },
	-- (owner R128 removed the R90 Order Window: no `orders` field any more)
}
local fresh = ProfileLogic.defaultProfile()
check(deepEqual(fresh, EXPECTED), "defaultProfile matches the plan's schema v2 exactly")

-- Owner R128: an old save's `orders` field (the retired Order Window's Customer Fame) is dropped
-- on load without touching anything else, and is no snapshot field any more.
do
	local oldSave = {
		cash = 1234,
		gems = 77,
		orders = { stars = 140, served = 52, claimed = 7, tip = true },
		quests = { starter = { step = 2 } },
	}
	local loaded = ProfileLogic.reconcile(oldSave)
	check((loaded :: any).orders == nil, "R128: the retired orders field is dropped on load")
	check(loaded.cash == 1234 and loaded.gems == 77, "R128: currencies untouched")
	check(loaded.quests.starter.step == 2, "R128: other fields untouched")
	check((ProfileLogic.toSave(loaded) :: any).orders == nil, "R128: never written back")
	check(table.find(ProfileLogic.SnapshotFields, "orders") == nil, "R128: orders is no snapshot field")
	check(ProfileLogic.reconcile({ orders = "junk" }) ~= nil, "R128: a junk orders field never breaks a load")
end
check(fresh.worlds.dino ~= ProfileLogic.defaultProfile().worlds.dino, "default worlds are fresh tables")
local other = ProfileLogic.defaultProfile()
check(fresh.tycoon ~= other.tycoon and fresh.settings ~= other.settings, "defaultProfile returns fresh tables")
check(not table.isfrozen(fresh.settings), "default settings are mutable")

-- 2. migrate
local profile, status = ProfileLogic.migrate(nil)
check(status == "new" and deepEqual(profile, EXPECTED), "nil → new default")
_, status = ProfileLogic.migrate("junk")
check(status == "new", "string → new")
profile, status = ProfileLogic.migrate({ schemaVersion = 1, cash = 50 })
check(status == "migrated" and profile.cash == 50 and profile.schemaVersion == 2, "v1 → migrated to v2")
profile, status = ProfileLogic.migrate({ schemaVersion = 2, cash = 50 })
check(status == "current" and profile.cash == 50, "v2 → current")
profile, status = ProfileLogic.migrate({ cash = 7 })
check(status == "migrated" and profile.schemaVersion == 2 and profile.cash == 7, "missing version → v1 → v2")
profile, status = ProfileLogic.migrate({ schemaVersion = 99, cash = 3 })
check(status == "newer" and profile.schemaVersion == 99 and profile.cash == 3, "newer schema kept for read-only")
profile, status = ProfileLogic.migrate({ schemaVersion = 3, cash = 4, worlds = { dino = { cash = 9 } } })
check(status == "newer" and profile.schemaVersion == 3 and profile.worlds.dino.cash == 9, "a v3 save opens as newer")

-- 3. reconcile hostile data
local nan = 0 / 0
local hostile = {
	cash = nan,
	gems = -5,
	totalEarned = math.huge,
	rebirths = 2.7,
	rebirthTokens = "lots",
	rebirthShop = { clickPower = 3.9, [5] = 2, bad = nan, [string.rep("k", 100)] = 1 },
	tycoon = {
		pads = { a1_bench = true, a1_wall = false, [7] = true },
		producers = { garage = 12.5, stand = -3 },
		area = 999,
		standName = "Ünïcödé Nuke Shack With A Really Long Name",
		lastSaveAt = -10,
		tutorialStep = "x",
	},
	stats = { clicks = 1e20, hits = nan },
	passes = { VIP = true, DoubleCash = "yes" },
	pets = {
		owned = {
			["1"] = { id = "glow_slime" },
			["5"] = { id = "atom_pup", locked = true },
			["9"] = { id = 42 },
			bad = "nope",
		},
		equipped = { "5", "5", "404", "1" },
		nextUid = 2,
	},
	boosts = { cash2x = 1_800_000_000 },
	daily = { streak = -1, lastDay = "today" },
	timeRewards = { day = 20_000, seconds = 1e9, claimed = { 1, 3, 99, "x", 2.5 } },
	spin = { free = 1e12 },
	codes = { LAUNCH = true, [""] = true },
	group = { claimed = 1 },
	event = { season = string.rep("s", 80), acorns = nan, stickers = { [2] = true, [70] = true }, redeemed = "y" },
	settings = { music = false, sfx = "off", unknown = true },
	analytics = {
		outbox = { ["p-1"] = { robux = 49, key = "GemsSmall", nested = {} } },
		last = 1_793_318_400, -- a unix time must survive (semantics belong to analytics)
		play = 12.5,
		sessions = -3,
		staff = "yes",
		ftue = nan,
	},
	junkField = { 1, 2, 3 },
}
profile = ProfileLogic.reconcile(hostile)
check(profile.cash == 0 and profile.gems == 0, "NaN / negative currency → 0")
check(profile.totalEarned == 0, "non-finite totalEarned → default (never trusted)")
check(profile.rebirths == 2 and profile.rebirthTokens == 0, "whole numbers floored / defaulted")
check(profile.rebirthShop.clickPower == 3 and profile.rebirthShop.bad == nil, "rebirthShop cleaned")
local shopCount = 0
for _ in profile.rebirthShop do
	shopCount += 1
end
check(shopCount == 1, "numeric / overlong rebirthShop keys dropped")
check(profile.tycoon.pads.a1_bench == true and profile.tycoon.pads.a1_wall == nil, "pad set keeps true only")
check(
	profile.tycoon.producers.garage == 12 and profile.tycoon.producers.stand == 0,
	"producer levels floored + clamped"
)
check(profile.tycoon.area == ProfileLogic.Limits.MaxArea, "area clamped")
check(utf8.len(profile.tycoon.standName) == ProfileLogic.Limits.MaxStandNameChars, "stand name cut on characters")
check(profile.tycoon.lastSaveAt == 0 and profile.tycoon.tutorialStep == 0, "bad tycoon numbers defaulted")
check(profile.stats.clicks == ProfileLogic.Limits.MaxCounter and profile.stats.hits == 0, "stats clamped")
check(profile.passes.VIP == true and profile.passes.DoubleCash == nil, "passes keep true only")
check(
	profile.pets.owned["1"] ~= nil and profile.pets.owned["9"] == nil and profile.pets.owned.bad == nil,
	"pets cleaned"
)
check(
	profile.pets.owned["5"].locked == true and profile.pets.owned["1"].locked == nil,
	"locked flag kept only when true"
)
check(deepEqual(profile.pets.equipped, { "5", "1" }), "equipped: deduped, dangling dropped, order kept")
check(profile.pets.nextUid == 6, "nextUid moved past the highest numeric uid")
check(profile.daily.streak == 0 and profile.daily.lastDay == -1, "daily defaulted")
check(profile.timeRewards.seconds == 172_800, "time reward seconds clamped")
check(
	profile.timeRewards.claimed[1] and profile.timeRewards.claimed[3] and not profile.timeRewards.claimed[99],
	"claimed array form read, out-of-range dropped"
)
check(profile.spin.free == ProfileLogic.Limits.MaxSpins, "spins clamped")
-- A pre-split save (no `bonus`) keeps its paid spins as Robux-sourced and gets bonus = 0.
do
	local legacy = ProfileLogic.reconcile({ spin = { free = 2, lastFreeAt = 5, paid = 7 } } :: any)
	check(legacy.spin.paid == 7 and legacy.spin.bonus == 0 and legacy.spin.free == 2, "legacy spins stay paid")
	local junk = ProfileLogic.reconcile({ spin = { bonus = -3, paid = 0 / 0 } } :: any)
	check(junk.spin.bonus == 0 and junk.spin.paid == 0, "junk spin counts repaired")
end
check(profile.codes.LAUNCH == true and profile.codes[""] == nil, "empty code key dropped")
check(profile.group.claimed == false, "non-boolean claimed → false")
check(#profile.event.season == ProfileLogic.Limits.MaxSeasonChars, "season cut")
check(profile.event.stickers[2] == true and profile.event.stickers[70] == nil, "sticker map form read, range checked")
check(profile.event.redeemed == false and profile.event.acorns == 0, "event defaults")
check(profile.settings.music == false and profile.settings.sfx == true, "settings: booleans only")
check((profile.settings :: any).unknown == nil, "unknown setting dropped")
check(profile.analytics.outbox["p-1"].robux == 49 and profile.analytics.outbox["p-1"].nested == nil, "outbox flat")
check(profile.analytics.last == 1_793_318_400 and profile.analytics.play == 12.5, "analytics values kept as stored")
check(profile.analytics.sessions == 0 and profile.analytics.ftue == 0, "analytics negatives / NaN → 0")
check(profile.analytics.staff == false, "analytics staff boolean only")
check((profile :: any).junkField == nil, "unknown top-level field dropped")

-- Oversized maps are bounded.
local manyPads = {}
for index = 1, 3000 do
	manyPads[`pad{index}`] = true
end
profile = ProfileLogic.reconcile({ tycoon = { pads = manyPads } })
local padCount = 0
for _ in profile.tycoon.pads do
	padCount += 1
end
check(padCount == ProfileLogic.Limits.MaxPads, "pad set bounded")

-- 4. Currency
profile = ProfileLogic.defaultProfile()
check(ProfileLogic.addCash(profile, 250) == 250 and profile.cash == 250 and profile.totalEarned == 250, "addCash")
check(ProfileLogic.addCash(profile, -5) == 0 and ProfileLogic.addCash(profile, nan) == 0, "addCash rejects bad amounts")
check(ProfileLogic.addCash(profile, math.huge) == 0, "addCash rejects inf")
check(not ProfileLogic.spendCash(profile, 251) and profile.cash == 250, "spendCash refuses overdraft")
check(ProfileLogic.spendCash(profile, 250) and profile.cash == 0, "spendCash exact")
check(profile.totalEarned == 250, "spending never lowers totalEarned")
profile.cash = 0.1 + 0.2
check(ProfileLogic.spendCash(profile, 0.3) or profile.cash > 0, "float dust handled")
check(profile.cash >= 0, "never negative")
profile.cash = ProfileLogic.Limits.MaxCash - 1
ProfileLogic.addCash(profile, 1e299)
check(profile.cash == ProfileLogic.Limits.MaxCash, "cash clamped at MaxCash")
check(ProfileLogic.addGems(profile, 2.5) == 0 and ProfileLogic.addGems(profile, 10) == 10, "addGems whole only")
check(
	not ProfileLogic.spendGems(profile, 11) and ProfileLogic.spendGems(profile, 10) and profile.gems == 0,
	"spendGems"
)

-- 5. Receipts
profile = ProfileLogic.defaultProfile()
check(ProfileLogic.recordReceipt(profile, "r-1", 100), "first record")
check(not ProfileLogic.recordReceipt(profile, "r-1", 101), "repeat refused")
for index = 2, 80 do
	ProfileLogic.recordReceipt(profile, `r-{index}`, 100 + index)
end
local receiptCount = 0
for _ in profile.receipts do
	receiptCount += 1
end
check(receiptCount == 64, "ledger trimmed to 64")
check(profile.receipts["r-80"] ~= nil and profile.receipts["r-1"] == nil, "newest kept, oldest evicted")
check(ProfileLogic.hasReceipt(profile, "r-17") and not ProfileLogic.hasReceipt(profile, "r-16"), "exact window")

-- 6. Settings
profile = ProfileLogic.defaultProfile()
check(ProfileLogic.applySetting(profile.settings, "music", false), "setting changed")
check(not ProfileLogic.applySetting(profile.settings, "music", false), "same value → no change")
check(not ProfileLogic.applySetting(profile.settings, "music", "no"), "non-boolean refused")
check(not ProfileLogic.applySetting(profile.settings, "admin", true), "unknown key refused")
check(not ProfileLogic.applySetting(profile.settings, 5, true), "non-string key refused")
check(
	ProfileLogic.applySetting(profile.settings, "haptics", false) and profile.settings.haptics == false,
	"haptics toggles"
)
check(not ProfileLogic.applySetting(profile.settings, "haptics", "off"), "haptics booleans only")
check(ProfileLogic.reconcile({ settings = { haptics = 0 } }).settings.haptics == true, "bad haptics → default true")
check(ProfileLogic.reconcile({ settings = { haptics = false } }).settings.haptics == false, "stored haptics kept")
-- Owner R49: the Fast Hatch toggle (short hatch cinematic), default off.
check(ProfileLogic.defaultProfile().settings.fastHatch == false, "fast hatch defaults off")
check(
	ProfileLogic.applySetting(profile.settings, "fastHatch", true) and profile.settings.fastHatch == true,
	"fast hatch toggles"
)
check(not ProfileLogic.applySetting(profile.settings, "fastHatch", 1), "fast hatch booleans only")
check(
	ProfileLogic.reconcile({ settings = { fastHatch = "yes" } }).settings.fastHatch == false,
	"bad fast hatch → off"
)
-- Owner R64: the AutoClicker pass toggle ("Toggle it any time"), default ON, booleans only, and a
-- stored OFF survives a reload (the pass then never clicks for the player until it is ON again).
check(ProfileLogic.defaultProfile().settings.autoClicker == true, "auto clicker toggle defaults on")
check(
	ProfileLogic.applySetting(profile.settings, "autoClicker", false) and profile.settings.autoClicker == false,
	"auto clicker toggles off"
)
check(not ProfileLogic.applySetting(profile.settings, "autoClicker", false), "unchanged auto clicker → false")
check(not ProfileLogic.applySetting(profile.settings, "autoClicker", 0), "auto clicker booleans only")
-- R73 / R74: the title tag toggle (defaults on; booleans only like every setting).
check(ProfileLogic.defaultProfile().settings.showTitle == true, "title tag defaults on")
check(
	ProfileLogic.applySetting(profile.settings, "showTitle", false) and profile.settings.showTitle == false,
	"title tag can be hidden"
)
check(not ProfileLogic.applySetting(profile.settings, "showTitle", "no"), "title tag booleans only")
check(not ProfileLogic.applySetting(profile.settings, "autoClicker", "on"), "auto clicker strings refused")
check(ProfileLogic.reconcile({ settings = { autoClicker = false } }).settings.autoClicker == false, "stored off kept")
check(ProfileLogic.reconcile({ settings = { autoClicker = "x" } }).settings.autoClicker == true, "bad → default on")
check(ProfileLogic.reconcile({ settings = {} }).settings.autoClicker == true, "old profiles get the toggle on")

-- 7. toSave + round trip
profile = ProfileLogic.defaultProfile()
ProfileLogic.addCash(profile, 1234.5)
profile.timeRewards.claimed[3] = true
profile.timeRewards.claimed[1] = true
profile.event.stickers[7] = true
profile.pets.owned["1"] = { id = "glow_slime" }
profile.pets.equipped = { "1" }
profile.pets.nextUid = 2
profile.tycoon.pads.a1_bench = true
local saved = ProfileLogic.toSave(profile)
check(deepEqual(saved.timeRewards.claimed, { 1, 3 }) and deepEqual(saved.event.stickers, { 7 }), "sets saved as arrays")
check(profile.timeRewards.claimed[3] == true, "live profile untouched")
local restored, restoredStatus = ProfileLogic.migrate(saved)
check(restoredStatus == "current" and deepEqual(restored, profile), "toSave → migrate round-trips")
profile.stats.clicks = nan
local warningsBefore = #loader.warnings
saved = ProfileLogic.toSave(profile)
check(saved.stats.clicks == 0 and #loader.warnings == warningsBefore + 1, "NaN scrubbed with a warning")

-- 8. Snapshot
profile = ProfileLogic.defaultProfile()
profile.receipts["r"] = 1
profile.codes.LAUNCH = true
profile.timeRewards.claimed[2] = true
local context = { saveStatus = "ok", paidRandomRestricted = true, policyKnown = false }
local snapshot = ProfileLogic.snapshot(profile, context)
for _, private in { "receipts", "codes", "offline", "analytics" } do
	check(snapshot[private] == nil, `snapshot hides {private}`)
end
check(snapshot.tycoon.lastSaveAt == nil and snapshot.pets.nextUid == nil, "snapshot hides bookkeeping")
check(deepEqual(snapshot.timeRewards.claimed, { 2 }), "snapshot sets as arrays")
check(snapshot.saveStatus == "ok" and snapshot.policy.paidRandomRestricted == true, "context fields")
check(snapshot.settings ~= profile.settings and snapshot.tycoon.pads ~= profile.tycoon.pads, "snapshot copies")
local fieldCount = 0
for _ in snapshot do
	fieldCount += 1
end
check(fieldCount == #ProfileLogic.SnapshotFields, "full snapshot has every field")
local partial = ProfileLogic.snapshot(profile, context, { "cash", "totalEarned", "nope" })
local partialCount = 0
for _ in partial do
	partialCount += 1
end
check(partialCount == 2 and partial.cash == 0, "partial snapshot builds only the asked fields")

-- 9. analytics.payDays (B13 payer-day bitmap)
local payDays = ProfileLogic.reconcile({
	analytics = {
		payDays = {
			["0"] = 5,
			["1562"] = 0xFFFFFFFF,
			["640"] = 1,
			["01"] = 1, -- leading zero: aliases "1"
			["-0"] = 1, -- sign: aliases "0"
			[" 2"] = 1,
			["1.0"] = 1,
			["0x10"] = 1,
			["1563"] = 1, -- past the last block
			["7"] = 2 ^ 32, -- mask too wide
			["8"] = -1,
			["9"] = 3.5,
			["10"] = nan,
			["11"] = "4",
			[12] = 4, -- numeric key (never written by analytics)
		},
	},
}).analytics.payDays
local payCount = 0
for _ in payDays do
	payCount += 1
end
check(
	payCount == 3 and payDays["0"] == 5 and payDays["1562"] == 0xFFFFFFFF and payDays["640"] == 1,
	"payDays keeps canonical blocks with whole 32-bit masks only"
)
check(
	deepEqual(ProfileLogic.reconcile({ analytics = { payDays = "x" } }).analytics.payDays, {}),
	"payDays non-table → {}"
)
local fullPayDays = {}
for block = 0, 1600 do
	fullPayDays[tostring(block)] = block
end
local fullCount = 0
for _ in ProfileLogic.reconcile({ analytics = { payDays = fullPayDays } }).analytics.payDays do
	fullCount += 1
end
check(fullCount == ProfileLogic.Limits.MaxPayDayBlock + 1, "payDays bounded to 1563 blocks")
profile = ProfileLogic.defaultProfile()
profile.analytics.payDays["640"] = 0x80000001
saved = ProfileLogic.toSave(profile)
check(saved.analytics.payDays["640"] == 0x80000001, "payDays saved as a string-keyed map")
restored = ProfileLogic.migrate(saved)
check(restored.analytics.payDays["640"] == 0x80000001, "payDays round-trips")
check(ProfileLogic.snapshot(profile, context).analytics == nil, "payDays never reaches the client")

-- 10. B9 pets / crates / trails + B10 attack.barrage
local items = ProfileLogic.reconcile({
	pets = {
		owned = { ["1"] = { id = "glow_slime" } },
		equipped = { "1" },
		nextUid = 2,
		eggs = { lucky_egg = 3.9, area1_egg = 0, bad = nan, neg = -2, [7] = 1, huge = 1e30 },
		pity = { lucky_egg = 12, area1_egg = "x" },
		index = { glow_slime = true, atom_pup = false, [string.rep("p", 80)] = true },
	},
	crates = {
		held = { supply_crate = 2, mega_crate = 0, golden_crate = -1 },
		pity = { mega_crate = 5.5 },
		opened = nan,
	},
	trails = { owned = { trail_rainbow = true, trail_gold_sparkle = "yes" }, equipped = "trail_gold_sparkle" },
	attack = { barrage = 40.7 },
})
check(items.pets.eggs.lucky_egg == 3 and items.pets.eggs.area1_egg == nil, "eggs floored, zero counts dropped")
check(
	items.pets.eggs.bad == nil and items.pets.eggs.neg == nil and items.pets.eggs[7] == nil,
	"bad egg entries dropped"
)
check(items.pets.eggs.huge == ProfileLogic.Limits.MaxItemCount, "held eggs clamped")
check(items.pets.pity.lucky_egg == 12 and items.pets.pity.area1_egg == nil, "egg pity repaired")
local indexCount = 0
for _ in items.pets.index do
	indexCount += 1
end
check(indexCount == 1 and items.pets.index.glow_slime == true, "pet index keeps valid true entries only")
check(items.crates.held.supply_crate == 2 and items.crates.held.mega_crate == nil, "held crates, zero dropped")
check(items.crates.held.golden_crate == nil and items.crates.pity.mega_crate == 5, "crate counts repaired")
check(items.crates.opened == 0, "non-finite crates.opened → 0")
check(items.trails.owned.trail_rainbow == true and items.trails.owned.trail_gold_sparkle == nil, "trails owned set")
check(items.trails.equipped == "", "an unowned equipped trail is cleared")
check(
	ProfileLogic.reconcile({ trails = { owned = { trail_rainbow = true }, equipped = "trail_rainbow" } }).trails.equipped
		== "trail_rainbow",
	"an owned equipped trail is kept"
)
check(items.attack.barrage == 40, "barrage floored")
check(ProfileLogic.reconcile({ attack = { barrage = -3 } }).attack.barrage == 0, "negative barrage → 0")
check(
	ProfileLogic.reconcile({ attack = { barrage = 1e20 } }).attack.barrage == ProfileLogic.Limits.MaxItemCount,
	"barrage clamped"
)
local manyEggs = {}
for index = 1, 200 do
	manyEggs[`egg{index}`] = 1
end
local eggCount = 0
for _ in ProfileLogic.reconcile({ pets = { eggs = manyEggs } }).pets.eggs do
	eggCount += 1
end
check(eggCount == ProfileLogic.Limits.MaxEggKinds, "egg map bounded")
local trailsMap = {}
for index = 1, 400 do
	trailsMap[`trail{index}`] = true
end
local trailCount = 0
for _ in ProfileLogic.reconcile({ trails = { owned = trailsMap } }).trails.owned do
	trailCount += 1
end
check(trailCount == ProfileLogic.Limits.MaxTrails, "trail set bounded")
-- Round trip + snapshot.
local itemsSaved = ProfileLogic.toSave(items)
local itemsRestored = ProfileLogic.migrate(itemsSaved)
check(deepEqual(itemsRestored, items), "pets / crates / trails / barrage round-trip")
local itemsSnapshot = ProfileLogic.snapshot(items, context)
check(itemsSnapshot.pets.eggs.lucky_egg == 3 and itemsSnapshot.pets.index.glow_slime == true, "snapshot pets meta")
check(itemsSnapshot.pets.pity.lucky_egg == 12 and itemsSnapshot.pets.nextUid == nil, "snapshot pets pity, no nextUid")
check(itemsSnapshot.pets.eggs ~= items.pets.eggs and itemsSnapshot.pets.index ~= items.pets.index, "pets meta copied")
check(itemsSnapshot.crates.held.supply_crate == 2 and itemsSnapshot.crates.opened == 0, "snapshot crates")
check(itemsSnapshot.crates.held ~= items.crates.held, "crates copied")
check(itemsSnapshot.trails.owned.trail_rainbow == true and itemsSnapshot.trails.equipped == "", "snapshot trails")
check(itemsSnapshot.trails.owned ~= items.trails.owned, "trails copied")
check(itemsSnapshot.attack.barrage == 40, "snapshot attack.barrage")
local partialItems = ProfileLogic.snapshot(items, context, { "crates", "trails" })
check(partialItems.crates ~= nil and partialItems.trails ~= nil and partialItems.pets == nil, "crates / trails fields")

-- 11. B11 event.decor / turkeys / lures
local feast = ProfileLogic.reconcile({
	event = {
		season = "harvest2026",
		decor = {
			scarecrow = true,
			hay_bale = true,
			["bad key"] = true, -- space
			[string.rep("d", 25)] = true, -- too long
			pumpkin = false,
			[3] = true,
		},
		turkeys = 4.8,
		lures = -1,
	},
})
local decorCount = 0
for _ in feast.event.decor do
	decorCount += 1
end
check(decorCount == 2 and feast.event.decor.scarecrow and feast.event.decor.hay_bale, "decor keeps well-formed keys")
check(feast.event.turkeys == 4 and feast.event.lures == 0, "turkeys floored, negative lures → 0")
check(
	ProfileLogic.reconcile({ event = { lures = 1e9 } }).event.lures == ProfileLogic.Limits.MaxItemCount,
	"lures clamped"
)
check(ProfileLogic.reconcile({ event = { turkeys = nan } }).event.turkeys == 0, "NaN turkeys → 0")
local manyDecor = {}
for index = 1, 100 do
	manyDecor[`decor{index}`] = true
end
local manyDecorCount = 0
for _ in ProfileLogic.reconcile({ event = { decor = manyDecor } }).event.decor do
	manyDecorCount += 1
end
check(manyDecorCount == ProfileLogic.Limits.MaxDecor, "decor bounded")
feast.event.lures = 2
check(deepEqual(ProfileLogic.migrate(ProfileLogic.toSave(feast)), feast), "event fields round-trip")
local feastSnapshot = ProfileLogic.snapshot(feast, context, { "event" }).event
check(feastSnapshot.decor.scarecrow == true and feastSnapshot.decor ~= feast.event.decor, "snapshot decor copied")
check(feastSnapshot.turkeys == 4 and feastSnapshot.lures == 2, "snapshot turkeys / lures")
-- Owner R97: event.starterSeason is additive (older saves → ""), a bounded string, round-trips,
-- and stays server-side (not in the snapshot).
check(feast.event.starterSeason == "", 'older save → starterSeason ""')
check(ProfileLogic.reconcile({ event = { starterSeason = 7 } }).event.starterSeason == "", 'junk starterSeason → ""')
check(
	#ProfileLogic.reconcile({ event = { starterSeason = string.rep("s", 80) } }).event.starterSeason
		== ProfileLogic.Limits.MaxSeasonChars,
	"starterSeason cut"
)
feast.event.starterSeason = "harvest2026"
check(deepEqual(ProfileLogic.migrate(ProfileLogic.toSave(feast)), feast), "starterSeason round-trips")
check(ProfileLogic.snapshot(feast, context, { "event" }).event.starterSeason == nil, "starterSeason server-only")

-- 12. Schema v2: worlds + lastWorld (owner R57 World 2, spec §10) ------------------------------
local DINO_AREAS = (WorldGeometry.get("dino") :: any).areaCount
check(type(DINO_AREAS) == "number" and DINO_AREAS >= 1, "Dino Valley has an area count")

-- (a) A realistic v1 save (every v1 block populated, exactly as a v1 server's toSave wrote it)
-- migrates to v2 with every v1 value carried over.
do
	local live = ProfileLogic.defaultProfile()
	ProfileLogic.addCash(live, 98765.25)
	ProfileLogic.addGems(live, 321)
	live.rebirths, live.rebirthTokens = 3, 44
	live.rebirthShop.clickPower = 4
	live.tycoon.pads.a1_toolwall = true
	live.tycoon.pads.a2_bench = true
	live.tycoon.producers.garage = 120
	live.tycoon.area, live.tycoon.standName, live.tycoon.tutorialStep = 4, "Nuke Shack", 9
	live.tycoon.lastSaveAt = 1_793_000_000
	live.stats.clicks, live.stats.playSeconds = 5000, 7200
	live.passes.VIP = true
	ProfileLogic.recordReceipt(live, "receipt-a", 1_793_000_001)
	live.pets.owned["1"] = { id = "glow_slime", locked = true }
	live.pets.equipped = { "1" }
	live.pets.nextUid = 2
	live.pets.eggs.garage_egg = 2
	live.crates.held.supply_crate = 1
	live.trails.owned.trail_rainbow = true
	live.trails.equipped = "trail_rainbow"
	live.boosts.cash2x = 1_793_000_500
	live.daily.streak, live.daily.lastDay = 6, 20_700
	live.timeRewards.day, live.timeRewards.seconds = 20_700, 900
	live.timeRewards.claimed[1] = true
	live.spin.paid, live.spin.bonus = 2, 1
	live.codes.LAUNCH = true
	live.offline.lastSeenAt = 1_793_000_000
	live.starter.bought = true
	live.attack.barrage = 20
	live.event.season, live.event.acorns = "harvest2026", 75
	live.event.stickers[3] = true
	live.event.decor.scarecrow = true
	live.settings.music = false
	live.analytics.sessions, live.analytics.payDays["640"] = 12, 7
	live.notes.seen = "2026-10-30-whats-new"
	-- The v1 shape on disk: no worlds / lastWorld, schemaVersion 1.
	local v1 = ProfileLogic.toSave(live)
	v1.worlds, v1.lastWorld, v1.schemaVersion = nil, nil, 1
	local v1Copy = ProfileLogic.deepCopy(v1)
	local migrated, migratedStatus = ProfileLogic.migrate(v1)
	check(migratedStatus == "migrated" and migrated.schemaVersion == 2, "v1 save → migrated v2")
	check(deepEqual(v1, v1Copy), "migrate never mutates the stored table")
	local expected = ProfileLogic.deepCopy(live)
	expected.worlds = expectedWorlds
	check(deepEqual(migrated, expected), "every v1 value carried over; worlds defaulted; lastWorld main")
	check(migrated.lastWorld == "main" and migrated.worlds.dino.unlocked == false, "v2 defaults after migration")
	-- Idempotent: the same v1 data migrates to the same profile; a migrated profile is "current".
	check(deepEqual(ProfileLogic.migrate(v1Copy), migrated), "migration is deterministic")
	local again, againStatus = ProfileLogic.migrate(ProfileLogic.toSave(migrated))
	check(againStatus == "current" and deepEqual(again, migrated), "migrated profile round-trips as current")
	-- Through a REAL JSON encode / decode (what a DataStore stores).
	local json = serde.encode("json", ProfileLogic.toSave(migrated))
	local decoded, decodedStatus = ProfileLogic.migrate(serde.decode("json", json))
	check(decodedStatus == "current" and deepEqual(decoded, migrated), "v2 save round-trips through JSON")
	local v1Json = serde.decode("json", serde.encode("json", v1Copy))
	check(deepEqual(ProfileLogic.migrate(v1Json), migrated), "a JSON-decoded v1 save migrates identically")
end

-- (b) A populated v2 world round-trips through toSave + JSON, and is JSON-safe.
do
	local live = ProfileLogic.defaultProfile()
	local dino = ProfileLogic.worldState(live, "dino")
	dino.unlocked, dino.unlockedAt = true, 1_793_100_000
	ProfileLogic.addWorldCash(live, "dino", 12345.5)
	dino.tycoon.pads.d1_bone_pit = true
	dino.tycoon.pads.d2_wind_sock = true
	dino.tycoon.producers.dp1_bone_digger = 77
	dino.tycoon.area = 2
	dino.rebirths, dino.rebirthTokens = 1, 15
	dino.rebirthShop.clickPower = 2
	dino.stats.visits, dino.stats.playSeconds, dino.stats.runSeconds, dino.stats.lastVisitDay = 4, 600, 120, 20_701
	dino.starter.bought = true
	live.lastWorld = "dino"
	-- An unknown (newer server's) world is kept too.
	live.worlds.space = ProfileLogic.newWorldState()
	live.worlds.space.cash, live.worlds.space.tycoon.area = 5, 9
	local json = serde.encode("json", ProfileLogic.toSave(live))
	local back, backStatus = ProfileLogic.migrate(serde.decode("json", json))
	check(backStatus == "current" and deepEqual(back, live), "worlds (known + unknown) round-trip through JSON")
end

-- (c) Hostile worlds data is repaired; unknown well-formed keys kept; malformed ones dropped.
do
	local bigPads = {}
	for index = 1, 3000 do
		bigPads[`d1_pad{index}`] = true
	end
	local repaired = ProfileLogic.reconcile({
		worlds = {
			dino = {
				unlocked = "yes",
				unlockedAt = -5,
				cash = nan,
				totalEarned = math.huge,
				tycoon = {
					pads = bigPads,
					producers = { dp1_bone_digger = 1e30, dp2_x = -4, [3] = 1 },
					area = 99,
					standName = 7,
				},
				rebirths = 2.9,
				rebirthTokens = -1,
				rebirthShop = { clickPower = nan, startingCash = 2.5, [string.rep("k", 80)] = 1 },
				stats = { visits = 1e40, clicks = "many", lastVisitDay = -99, runSeconds = nan },
				starter = { bought = 1 },
				junk = true,
			},
			space = { cash = 1e301, tycoon = { area = 500 } }, -- unknown, well-formed: kept + clamped
			moon2 = { unlocked = true }, -- unknown, well-formed: kept
			main = { cash = 5 }, -- never a worlds key
			Dino = { cash = 5 }, -- uppercase
			["1abc"] = {}, -- must start with a letter
			["a-b"] = {}, -- charset
			[string.rep("a", 17)] = {}, -- longer than 16
			[42] = {}, -- numeric key
			lava = "notatable", -- value must be a table
			ice = setmetatable({}, {}), -- metatables are not plain data
		},
		lastWorld = "Dino",
	})
	local dino = repaired.worlds.dino
	check(dino.unlocked == false and dino.unlockedAt == 0, "bad unlock fields → defaults")
	check(dino.cash == 0 and dino.totalEarned == 0, "NaN / inf Bones → 0")
	check(dino.tycoon.area == DINO_AREAS, "known world area clamped to its area count")
	check(dino.tycoon.producers.dp1_bone_digger == ProfileLogic.Limits.MaxLevel, "huge level clamped")
	check(dino.tycoon.producers.dp2_x == 0 and dino.tycoon.producers[3] == nil, "levels clamped, bad keys dropped")
	local count = 0
	for _ in dino.tycoon.pads do
		count += 1
	end
	check(count == ProfileLogic.Limits.MaxPads, "world pad set bounded")
	check(dino.tycoon.standName == "", "non-string stand name → empty")
	check(dino.rebirths == 2 and dino.rebirthTokens == 0, "rebirth counters floored / defaulted")
	check(dino.rebirthShop.clickPower == nil and dino.rebirthShop.startingCash == 2, "world shop cleaned")
	check(dino.stats.visits == ProfileLogic.Limits.MaxCounter and dino.stats.clicks == 0, "world stats clamped")
	check(dino.stats.lastVisitDay == -1 and dino.stats.runSeconds == 0, "bad day / NaN seconds → defaults")
	check(dino.starter.bought == false and (dino :: any).junk == nil, "starter boolean only; unknown fields dropped")
	check(repaired.worlds.space ~= nil and repaired.worlds.space.cash == ProfileLogic.Limits.MaxCash, "unknown kept")
	check(repaired.worlds.space.tycoon.area == ProfileLogic.Limits.MaxArea, "unknown world area ≤ MaxArea")
	check(repaired.worlds.moon2 ~= nil and repaired.worlds.moon2.unlocked == true, "unknown world values kept")
	for _, bad in { "main", "Dino", "1abc", "a-b", string.rep("a", 17), "lava", "ice" } do
		check(repaired.worlds[bad] == nil, `malformed world key {bad} dropped`)
	end
	check((repaired.worlds :: any)[42] == nil, "numeric world key dropped")
	check(repaired.lastWorld == "main", "malformed lastWorld → main")
	check(ProfileLogic.reconcile({ lastWorld = "dino" }).lastWorld == "dino", "known lastWorld kept")
	check(ProfileLogic.reconcile({ lastWorld = "space" }).lastWorld == "space", "unknown well-formed lastWorld kept")
	for _, bad in { 5, "", string.rep("z", 17), "x y", {}, nan } do
		check(ProfileLogic.reconcile({ lastWorld = bad }).lastWorld == "main", "junk lastWorld → main")
	end
	check(deepEqual(ProfileLogic.reconcile({ worlds = "x" }).worlds, expectedWorlds), "non-table worlds → defaults")
end

-- (d) The cap: ≤ 8 entries, known worlds always first, unknown ones in key order.
do
	local many = {}
	for index = 1, 30 do
		many[`w{string.format("%02d", index)}`] = { cash = index }
	end
	local capped = ProfileLogic.reconcile({ worlds = many })
	local count = 0
	for _ in capped.worlds do
		count += 1
	end
	check(count == ProfileLogic.Limits.MaxWorlds, "worlds capped at 8")
	for _, worldId in ProfileLogic.KnownWorlds do
		check(capped.worlds[worldId] ~= nil, `known world {worldId} survives the cap`)
	end
	local free = ProfileLogic.Limits.MaxWorlds - #ProfileLogic.KnownWorlds
	check(capped.worlds[`w{string.format("%02d", free)}`] ~= nil, "unknown worlds kept in key order")
	check(capped.worlds[`w{string.format("%02d", free + 1)}`] == nil, "past the cap dropped")
	-- worldState refuses to grow past the cap and refuses misuse.
	check(not pcall(ProfileLogic.worldState, capped, "zz"), "worldState: no room past MaxWorlds")
	check(not pcall(ProfileLogic.worldState, capped, "main"), "worldState: main is not a world entry")
	check(not pcall(ProfileLogic.worldState, capped, "Bad"), "worldState: malformed id")
	check(ProfileLogic.worldState(capped, "dino") == capped.worlds.dino, "worldState returns the live entry")
end

-- (e) World currency + tokens (Bones / Amber) and the read-only lookup.
do
	local p = ProfileLogic.defaultProfile()
	check(ProfileLogic.peekWorld(p, "main") == nil and ProfileLogic.peekWorld(p, "nope") == nil, "peekWorld misses")
	check(ProfileLogic.peekWorld(p, "dino") == p.worlds.dino, "peekWorld finds a known world")
	p.worlds.dino = nil
	check(ProfileLogic.peekWorld(p, "dino") == nil, "peekWorld never creates")
	check(ProfileLogic.addWorldCash(p, "dino", 40) == 40 and p.worlds.dino.cash == 40, "addWorldCash creates on demand")
	check(p.worlds.dino.totalEarned == 40 and p.cash == 0 and p.totalEarned == 0, "Bones never touch main cash")
	check(ProfileLogic.addWorldCash(p, "dino", nan) == 0 and ProfileLogic.addWorldCash(p, "dino", -1) == 0, "bad grant")
	check(ProfileLogic.addWorldCash(p, "dino", math.huge) == 0, "inf grant refused")
	check(not ProfileLogic.spendWorldCash(p, "dino", 41) and p.worlds.dino.cash == 40, "no overdraft")
	check(
		not ProfileLogic.spendWorldCash(p, "dino", nan) and not ProfileLogic.spendWorldCash(p, "dino", 0),
		"bad spend"
	)
	check(ProfileLogic.spendWorldCash(p, "dino", 40) and p.worlds.dino.cash == 0, "exact spend")
	check(p.worlds.dino.totalEarned == 40, "spending never lowers totalEarned")
	p.worlds.dino.cash = ProfileLogic.Limits.MaxCash - 1
	ProfileLogic.addWorldCash(p, "dino", 1e299)
	check(p.worlds.dino.cash == ProfileLogic.Limits.MaxCash, "Bones clamped at MaxCash")
	p.cash = 10
	check(not ProfileLogic.spendWorldCash(ProfileLogic.defaultProfile(), "dino", 5), "main cash never pays Bones")
	check(
		ProfileLogic.addWorldTokens(p, "dino", 2.5) == 0 and ProfileLogic.addWorldTokens(p, "dino", 12) == 12,
		"Amber whole"
	)
	check(
		not ProfileLogic.spendWorldTokens(p, "dino", 13) and ProfileLogic.spendWorldTokens(p, "dino", 12),
		"Amber spend"
	)
	check(p.worlds.dino.rebirthTokens == 0 and p.rebirthTokens == 0, "Amber never touches main tokens")
end

-- (f) Snapshot: structure only, known worlds only, fresh copies; worldCash; lastWorld.
do
	local p = ProfileLogic.defaultProfile()
	local dino = p.worlds.dino
	dino.unlocked, dino.unlockedAt = true, 1_793_100_000
	ProfileLogic.addWorldCash(p, "dino", 500)
	dino.tycoon.pads.d1_bone_pit = true
	dino.tycoon.producers.dp1_bone_digger = 3
	dino.stats.visits, dino.stats.playSeconds = 2, 999
	p.worlds.space = ProfileLogic.newWorldState()
	p.lastWorld = "dino"
	local ctx = { saveStatus = "ok", paidRandomRestricted = false, policyKnown = true }
	local snap = ProfileLogic.snapshot(p, ctx)
	local w = snap.worlds.dino
	check(
		deepEqual(w, {
			unlocked = true,
			unlockedAt = 1_793_100_000,
			tycoon = { pads = { d1_bone_pit = true }, producers = { dp1_bone_digger = 3 }, area = 1 },
			rebirths = 0,
			rebirthTokens = 0,
			rebirthShop = {},
			stats = { visits = 2 },
			starter = { bought = false },
		}),
		"worlds snapshot = structure only (no cash, no private stats / bookkeeping)"
	)
	check(snap.worlds.space == nil, "unknown worlds never reach the client")
	check(w.tycoon.pads ~= dino.tycoon.pads and w.rebirthShop ~= dino.rebirthShop, "worlds snapshot copies")
	check(deepEqual(snap.worldCash, { dino = { cash = 500, totalEarned = 500 } }), "worldCash snapshot")
	check(snap.lastWorld == "dino", "lastWorld snapshot")
	for _, field in { "worlds", "worldCash", "lastWorld" } do
		check(table.find(ProfileLogic.SnapshotFields, field) ~= nil, `snapshot field {field} declared`)
	end
	local tick = ProfileLogic.snapshot(p, ctx, { "worldCash" })
	local fields = 0
	for _ in tick do
		fields += 1
	end
	check(fields == 1 and tick.worldCash.dino.cash == 500, "a Bones tick builds only worldCash")
	-- R70 (World 3): worldCash carries only the worlds a player has started (unlocked, or holding /
	-- having earned currency), so a currency tick's size grows with worlds PLAYED, not registered.
	local fresh = ProfileLogic.defaultProfile()
	for _, worldId in ProfileLogic.KnownWorlds do
		check(ProfileLogic.snapshot(fresh, ctx).worldCash[worldId] == nil, `locked, empty {worldId} not in worldCash`)
		local started = ProfileLogic.defaultProfile()
		started.worlds[worldId].unlocked = true
		local entry = ProfileLogic.snapshot(started, ctx).worldCash[worldId]
		check(entry ~= nil and entry.cash == 0 and entry.totalEarned == 0, `unlocked {worldId} in worldCash at 0`)
		local paid = ProfileLogic.defaultProfile()
		ProfileLogic.addWorldCash(paid, worldId, 7)
		check(ProfileLogic.snapshot(paid, ctx).worldCash[worldId].cash == 7, `locked {worldId} holding cash is listed`)
	end
	-- Remote-safe: every key in the world snapshot is a string (no sparse numeric tables).
	local function stringKeysOnly(value: any): boolean
		for key, item in value do
			if type(key) ~= "string" or (type(item) == "table" and not stringKeysOnly(item)) then
				return false
			end
		end
		return true
	end
	check(stringKeysOnly(snap.worlds) and stringKeysOnly(snap.worldCash), "world snapshot is remote-safe")
end

-- 13. Owner R88 plot name: a top-level string (survives Rebirth, which replaces `tycoon`), capped on
-- characters, junk → "", saved + round-tripped, sent to the owner as its own snapshot field.
do
	check(ProfileLogic.Limits.MaxPlotNameChars == 24, "plot name cap is 24 characters")
	local named = ProfileLogic.reconcile({ plotName = "Sparkle Base" })
	check(named.plotName == "Sparkle Base", "a stored plot name is kept")
	check(ProfileLogic.reconcile({}).plotName == "", "pre-R88 saves get the default (empty) plot name")
	check(ProfileLogic.reconcile({ plotName = 42 }).plotName == "", "non-string plot name → empty")
	check(ProfileLogic.reconcile({ plotName = { "x" } }).plotName == "", "table plot name → empty")
	check(ProfileLogic.reconcile({ plotName = "\255bad" }).plotName == "", "invalid UTF-8 plot name → empty")
	local long = ProfileLogic.reconcile({ plotName = string.rep("Ü", 40) }).plotName
	check(utf8.len(long) == ProfileLogic.Limits.MaxPlotNameChars, "plot name cut on characters (UTF-8 safe)")
	-- Rebirth replaces profile.tycoon; the plot name lives outside it.
	check(named.tycoon.standName == "" and named.plotName ~= "", "plotName is not part of tycoon")
	local migrated, migratedStatus = ProfileLogic.migrate(ProfileLogic.toSave(named))
	check(migratedStatus == "current" and migrated.plotName == "Sparkle Base", "plot name round-trips through toSave")
	local v1 = ProfileLogic.migrate({ schemaVersion = 1, plotName = "Old Save Base" })
	check(v1.plotName == "Old Save Base", "plot name survives the v1 → v2 migration")
	local ctx = { saveStatus = "ok", paidRandomRestricted = false, policyKnown = true }
	check(ProfileLogic.snapshot(named, ctx).plotName == "Sparkle Base", "plotName in the full snapshot")
	local delta = ProfileLogic.snapshot(named, ctx, { "plotName" })
	local count = 0
	for _ in delta do
		count += 1
	end
	check(count == 1 and delta.plotName == "Sparkle Base", "a rename pushes only plotName")
	check(table.find(ProfileLogic.SnapshotFields, "plotName") ~= nil, "plotName is a snapshot field")
end

print(`[profile-logic] {checks} checks passed`)
