--!strict
--[[
	R78 Rush + Friends pure logic (spec docs/superpowers/specs/2026-10-31-r78-retention-pack-design.md
	§3 / §4; docs/social.md). Run: lune run tests/social-logic

	Proves on the shipped modules:
	  1. SocialConfig: saved-record repair (pre-0.6.0 saves → no rush), live admin overrides,
	     multiplier text.
	  2. RushLogic: Rookie grant, online-only countdown across a rejoin, comeback threshold edges,
	     no stacking + validUntil.
	  3. Modifier plumbing: rushCash / friendCash resolve, sanitise (NaN / inf / <= 1 / huge), merge
	     multiplicatively, neutral = bit-identical, offline = false providers excluded from offline
	     earnings, reward income ignores them.
	  4. FriendLogic: percent cap, pair cache, referrer parsing, newcomer verdicts (self, non-new,
	     swap, unsaved, already), inviter ledger (cap 10, dedupe, seen bound), queue enqueue /
	     read / dequeue (dedupe, cap, age, concurrent append) and an idempotent replay.
	  5. ProfileLogic: defaults, reconcile of an old save, snapshot shapes (no other UserIds).
	  6. BoostChipLogic: chips, no-stacking rule, labels, timers; the R82 corner badge (each boost's
	     multiplier, combined number, timer pick, friends-only text, size, digit-safe tilted gap).
	  7. RewardsBadges Friends tile: boost / invite states and their lines.
]]

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local SocialConfig = loader.load("src/shared/Config/SocialConfig")
local RushLogic = loader.load("src/server/Social/RushLogic")
local FriendLogic = loader.load("src/server/Social/FriendLogic")
local Modifiers = loader.load("src/shared/Tycoon/Modifiers")
local TycoonRules = loader.load("src/server/Tycoon/TycoonRules")
local ModifierSources = loader.load("src/server/Tycoon/ModifierSources")
local ProfileLogic = loader.load("src/server/Economy/ProfileLogic")
local RewardLogic = loader.load("src/server/Retention/RewardLogic")
local BoostChipLogic = loader.load("src/client/Social/BoostChipLogic")
local Badges = loader.load("src/client/UI/RewardsBadges")
local HubConfig = loader.load("src/shared/Config/RewardsHubConfig")
local AnalyticsConfig = loader.load("src/shared/Config/AnalyticsConfig")

local checks = 0
local function check(ok: boolean, message: string)
	assert(ok, message)
	checks += 1
end

local NAN = 0 / 0
local INF = math.huge
local RUSH = SocialConfig.Rush
local REFERRAL = SocialConfig.Referral
local RATES = { rookie = RUSH.RookieMultiplier, comeback = RUSH.ComebackMultiplier }

--------------------------------------------------------------------------------------------------
-- 1. SocialConfig
--------------------------------------------------------------------------------------------------
do
	check(RUSH.RookieMinutes == 15 and RUSH.RookieMultiplier == 2, "spec: Rookie Rush 2x for 15 minutes")
	check(RUSH.ComebackMinutes == 10 and RUSH.ComebackMultiplier == 2, "spec: Comeback Rush 2x for 10 minutes")
	check(RUSH.ComebackAwayHours == 48, "spec: comeback after 48 h away")
	check(SocialConfig.Friends.PercentPerFriend == 10 and SocialConfig.Friends.MaxPercent == 50, "spec: +10 % / friend, max +50 %")
	check(REFERRAL.NewcomerReward.gems == 50 and REFERRAL.NewcomerReward.boost.seconds == 900, "spec: newcomer 50 gems + 15 min")
	check(REFERRAL.NewcomerReward.boost.key == "cash2x", "newcomer boost is the existing 2x Cash boost")
	check(REFERRAL.InviterReward.gems == 100 and REFERRAL.InviterReward.spins == 1, "spec: inviter 100 gems + 1 spin")
	check(REFERRAL.MaxPaid == 10, "spec: max 10 lifetime")
	check(REFERRAL.StoreName == "SellNukesReferrals_v1" and REFERRAL.StudioSuffix == "_Studio", "store names")

	-- Saved records
	local fresh = SocialConfig.newRush()
	check(fresh.rookieLeft == 0 and fresh.comebackUntil == 0, "fresh rush is empty")
	check(SocialConfig.newRush() ~= fresh, "newRush returns new tables")
	local old = SocialConfig.reconcileRush(nil)
	check(old.rookieLeft == 0, "a pre-0.6.0 save (no rush record) never gets a Rookie Rush")
	local repaired = SocialConfig.reconcileRush({ rookieLeft = 1e9, comebackUntil = -5 })
	check(repaired.rookieLeft == RUSH.MaxMinutes * 60 and repaired.comebackUntil == 0, "rush clamps")
	repaired = SocialConfig.reconcileRush({ rookieLeft = NAN, comebackUntil = INF })
	check(repaired.rookieLeft == 0 and repaired.comebackUntil == 0, "rush NaN / inf → 0")
	check(SocialConfig.reconcileRush({ rookieLeft = 900.7 }).rookieLeft == 900, "rookieLeft floored")
	local referral = SocialConfig.reconcileReferral({ by = 12, paid = 2, seen = { 5, 5, "x", 7, 2.5, -1, 0 } })
	check(referral.by == 12 and referral.paid == 2, "referral by / paid kept")
	check(#referral.seen == 2 and referral.seen[1] == 5 and referral.seen[2] == 7, "seen deduped + junk dropped")
	referral = SocialConfig.reconcileReferral({ by = 1.5, paid = -3, seen = "nope" })
	check(referral.by == 0 and referral.paid == 0 and #referral.seen == 0, "referral junk → empty")
	local many = {}
	for index = 1, REFERRAL.MaxSeen + 10 do
		many[index] = index
	end
	referral = SocialConfig.reconcileReferral({ seen = many })
	check(#referral.seen == REFERRAL.MaxSeen and referral.seen[1] == 11, "seen keeps the newest MaxSeen")

	-- Live overrides
	local live = SocialConfig.live(nil)
	check(live.rushOn and live.friendsOn and live.rookieMinutes == 15 and live.friendPercent == 10, "defaults")
	local attrs: { [string]: any } = {
		[SocialConfig.Attributes.RushEnabled] = false,
		[SocialConfig.Attributes.RookieMinutes] = 30,
		[SocialConfig.Attributes.ComebackMinutes] = 9999,
		[SocialConfig.Attributes.FriendPercent] = NAN,
	}
	live = SocialConfig.live(function(name)
		return attrs[name]
	end)
	check(not live.rushOn and live.friendsOn, "switches read")
	check(live.rookieMinutes == 30 and live.comebackMinutes == 10, "minutes override + out-of-range ignored")
	check(live.friendPercent == 10, "NaN percent ignored")
	live = SocialConfig.live(function()
		error("boom")
	end)
	check(live.rushOn and live.rookieMinutes == 15, "a failing reader reads as defaults")
	check(SocialConfig.times(2) == "2x" and SocialConfig.times(1.5) == "1.5x", "multiplier text")
	check(SocialConfig.times(NAN) == "1.0x", "NaN multiplier text never errors")
end

--------------------------------------------------------------------------------------------------
-- 2. RushLogic
--------------------------------------------------------------------------------------------------
do
	-- Rookie Rush: online-only countdown that survives a rejoin.
	local state = SocialConfig.newRush()
	check(RushLogic.grantRookie(state, 900), "rookie granted")
	check(state.rookieLeft == 900, "15 minutes")
	check(not RushLogic.grantRookie(state, 600), "a shorter grant never shortens")
	check(not RushLogic.grantRookie(state, NAN) and not RushLogic.grantRookie(state, -5), "junk grants refused")
	local endsAt = RushLogic.sessionEndsAt(state, 1000)
	check(endsAt == 1900, "session end = now + left")
	check(RushLogic.consume(state, endsAt, 1300) == 600, "5 minutes played → 10 left")
	-- The player leaves at 1300 and comes back a day later: nothing ran while offline.
	local rejoin = 1300 + 86400
	endsAt = RushLogic.sessionEndsAt(state, rejoin)
	check(endsAt == rejoin + 600, "rejoin continues where it stopped")
	local multiplier, validUntil, kind = RushLogic.multiplier(endsAt, 0, rejoin + 10, RATES)
	check(multiplier == 2 and validUntil == endsAt and kind == "rookie", "2x while running, valid until its end")
	check(RushLogic.consume(state, endsAt, rejoin + 0.2) == 600, "a partial second is kept (ceil)")
	check(RushLogic.consume(state, endsAt, rejoin + 700) == 0, "runs out at 0")
	check(RushLogic.sessionEndsAt(state, rejoin + 700) == nil, "no session once used up")
	check(RushLogic.consume(state, nil, 5) == 0, "nothing running: unchanged")
	multiplier = RushLogic.multiplier(nil, 0, 5000, RATES)
	check(multiplier == 1, "no rush = neutral")

	-- Comeback threshold edges (48 h).
	local now = 2_000_000_000
	local H48 = 48 * 3600
	local empty = SocialConfig.newRush()
	local due, away = RushLogic.comebackDue(empty, now - H48, now, 48, 600)
	check(due and away == H48, "exactly 48 h away → comeback")
	due = RushLogic.comebackDue(empty, now - H48 + 1, now, 48, 600)
	check(not due, "1 s short of 48 h → no comeback")
	due, away = RushLogic.comebackDue(empty, 0, now, 48, 600)
	check(not due and away == nil, "brand-new profile (never seen) → no comeback")
	due = RushLogic.comebackDue(empty, now + 60, now, 48, 600)
	check(not due, "a stamp in the future → no comeback")
	due = RushLogic.comebackDue(empty, NAN, now, 48, 600)
	check(not due, "NaN stamp → no comeback")
	local rookie = { rookieLeft = 600, comebackUntil = 0 }
	check(not RushLogic.comebackDue(rookie, now - H48 * 3, now, 48, 600), "a Rookie Rush covering the window blocks it")
	rookie.rookieLeft = 599
	check(RushLogic.comebackDue(rookie, now - H48 * 3, now, 48, 600), "a nearly used Rookie Rush does not")
	local comeback = SocialConfig.newRush()
	check(RushLogic.grantComeback(comeback, now, 600) == now + 600, "comeback until now + 10 min")
	check(RushLogic.grantComeback(comeback, now, 60) == now + 600, "a shorter grant never shortens")

	-- No stacking.
	multiplier, validUntil, kind = RushLogic.multiplier(now + 300, now + 600, now, RATES)
	check(multiplier == 2 and kind == "rookie" and validUntil == now + 300, "both: 2x (not 4x), rookie on a tie")
	multiplier, validUntil, kind = RushLogic.multiplier(now + 300, now + 600, now, { rookie = 2, comeback = 3 })
	check(multiplier == 3 and kind == "comeback" and validUntil == now + 300, "larger wins; recompute at the soonest end")
	multiplier, validUntil, kind = RushLogic.multiplier(nil, now + 600, now, RATES)
	check(multiplier == 2 and kind == "comeback" and validUntil == now + 600, "comeback alone")
	multiplier = RushLogic.multiplier(nil, now + 600, now, { rookie = NAN, comeback = -2 })
	check(multiplier == 1, "junk rates → neutral")
end

--------------------------------------------------------------------------------------------------
-- 3. Modifier plumbing
--------------------------------------------------------------------------------------------------
do
	check(Modifiers.resolve({ rushCash = 2 }).cash == 2, "rushCash multiplies cash")
	check(math.abs(Modifiers.resolve({ friendCash = 1.2 }).cash - 1.2) < 1e-12, "friendCash multiplies cash")
	local both = Modifiers.resolve({ rushCash = 2, friendCash = 1.5, boostCash = 2, vip = true })
	check(math.abs(both.cash - 2 * 1.5 * 2 * 1.5) < 1e-9, "categories multiply")
	for _, bad in { NAN, INF, -INF, 0, -3, 0.5, "2", true } do
		local resolved = Modifiers.resolve({ rushCash = bad :: any, friendCash = bad :: any })
		check(resolved.cash == 1, `junk rush / friend {tostring(bad)} → neutral`)
	end
	local huge = Modifiers.resolve({ rushCash = 1e300, friendCash = 1e300 })
	check(huge.cash == RUSH.MaxMultiplier * SocialConfig.Friends.MaxMultiplier, "huge values clamp to the sane caps")
	local base = { petCash = 0.37, cashPass = true, boostCash = 2, serverCash = 2, eventCash = 1.5, rebirths = 3 }
	local neutral = table.clone(base) :: any
	neutral.rushCash = 1
	neutral.friendCash = 1
	check(Modifiers.resolve(base).cash == Modifiers.resolve(neutral).cash, "neutral rush / friend = bit-identical")
	check(Modifiers.resolve({ rushCash = 2 }).speed == 1, "rush never touches speed")

	local merged = TycoonRules.mergeModifiers({
		{ rushCash = 2 },
		{ friendCash = 1.2 },
		{ rushCash = NAN, friendCash = -1 },
		{ rushCash = INF },
		"junk",
	}, 0, {})
	check(merged.rushCash == 2 and math.abs(merged.friendCash - 1.2) < 1e-12, "merge multiplies, drops junk")
	local empty = TycoonRules.mergeModifiers({}, 0, {})
	check(empty.rushCash == 1 and empty.friendCash == 1, "no sources = neutral")

	-- offline = false providers never inflate offline earnings.
	local player = {} :: any
	local profile = { rebirths = 0, rebirthShop = {} }
	ModifierSources.register("rush", function()
		return { rushCash = 2 }, 1_900_000_000
	end, { offline = false })
	ModifierSources.register("friendBoost", function()
		return { friendCash = 1.3 }
	end, { offline = false })
	local online, validUntil = ModifierSources.build(player, profile)
	check(online.rushCash == 2 and math.abs(online.friendCash - 1.3) < 1e-12, "online build includes both")
	check(validUntil == 1_900_000_000, "rush validUntil reaches the tycoon")
	local offline = ModifierSources.build(player, profile, true)
	check(offline.rushCash == 1 and offline.friendCash == 1, "offline build excludes rush + friends")
	ModifierSources.unregister("rush")
	ModifierSources.unregister("friendBoost")

	-- Reward cash scales with permanent income only: rush state on the profile changes nothing.
	local rewardProfile = ProfileLogic.defaultProfile()
	local before = RewardLogic.incomeOf(rewardProfile)
	rewardProfile.rush.rookieLeft = 900
	rewardProfile.rush.comebackUntil = 2_000_000_000
	check(RewardLogic.incomeOf(rewardProfile) == before, "reward income ignores rush")
end

--------------------------------------------------------------------------------------------------
-- 4. FriendLogic
--------------------------------------------------------------------------------------------------
do
	check(FriendLogic.percent(0, 10, 50) == 0 and FriendLogic.percent(1, 10, 50) == 10, "+10 % per friend")
	check(FriendLogic.percent(2, 10, 50) == 20, "two friends +20 %")
	check(FriendLogic.percent(5, 10, 50) == 50 and FriendLogic.percent(7, 10, 50) == 50, "cap +50 %")
	check(FriendLogic.percent(3, 25, 50) == 50, "a bigger admin percent still caps")
	for _, bad in { NAN, INF, -2, "3" } do
		check(FriendLogic.percent(bad :: any, 10, 50) == 0, `junk count {tostring(bad)} → 0`)
	end
	check(FriendLogic.percent(2.9, 10, 50) == 20, "count floored")
	check(math.abs(FriendLogic.multiplier(20) - 1.2) < 1e-12 and FriendLogic.multiplier(0) == 1, "multiplier")
	check(FriendLogic.multiplier(NAN) == 1 and FriendLogic.multiplier(INF) == 1, "junk multiplier → 1")
	check(FriendLogic.pairKey(9, 3) == "3:9" and FriendLogic.pairKey(3, 9) == "3:9", "pair key is symmetric")
	local cache = { ["1:2"] = true, ["1:3"] = false, ["2:3"] = true }
	local count, ids = FriendLogic.friendsOf(1, { 1, 2, 3, 4 }, cache)
	check(count == 1 and ids[1] == 2, "friends of 1 (unknown pair 1:4 = not yet)")
	count = FriendLogic.friendsOf(2, { 1, 2, 3 }, cache)
	check(count == 2, "cached both directions")

	-- Referrer parsing
	check(FriendLogic.referrerOf({ ReferredByPlayerId = 42 }, 7) == 42, "referrer read")
	check(FriendLogic.referrerOf({ ReferredByPlayerId = 7 }, 7) == nil, "self-referral rejected")
	for _, bad in { 0, -5, 1.5, NAN, INF, "42", 2 ^ 60 } do
		check(FriendLogic.referrerOf({ ReferredByPlayerId = bad }, 7) == nil, `junk referrer {tostring(bad)}`)
	end
	check(FriendLogic.referrerOf(nil, 7) == nil and FriendLogic.referrerOf({}, 7) == nil, "no join data")

	-- Newcomer verdicts
	local function verdict(overrides: { [string]: any }): (string, number?)
		local input: { [string]: any } = {
			isNew = true,
			reason = "join",
			canMutate = true,
			sandbox = false,
			rawReferrer = 42,
			selfId = 7,
			by = 0,
		}
		for key, value in overrides do
			input[key] = value
		end
		return FriendLogic.newcomerVerdict(input :: any)
	end
	local v, inviter = verdict({})
	check(v == "ok" and inviter == 42, "brand-new referred profile → ok")
	check(verdict({ rawReferrer = 7 }) == "self", "self")
	check(verdict({ isNew = false }) == "notNew", "existing profiles are never newcomers")
	check(verdict({ reason = "enterNewPlayerMode" }) == "swap", "New Player Mode swap never claims")
	check(verdict({ sandbox = true }) == "swap", "sandbox never claims")
	check(verdict({ canMutate = false }) == "unsaved", "in-memory fallback never claims")
	check(verdict({ by = 99 }) == "already", "already referred")
	check(verdict({ rawReferrer = "none" }) == "none", "no (valid) referrer")
	check(verdict({ rawReferrer = false }) == "none", "no referrer")

	-- Inviter ledger: cap 10, dedupe, bounded seen
	local referral = SocialConfig.newReferral()
	check(FriendLogic.payInviter(referral, 1001, 10, 32) == "paid", "first newcomer paid")
	check(FriendLogic.payInviter(referral, 1001, 10, 32) == "seen", "same newcomer never twice")
	check(referral.paid == 1 and #referral.seen == 1, "ledger counts one")
	check(FriendLogic.payInviter(referral, "1002" :: any, 10, 32) == "invalid", "junk id refused")
	for id = 1002, 1010 do
		FriendLogic.payInviter(referral, id, 10, 32)
	end
	check(referral.paid == 10, "ten paid")
	check(FriendLogic.payInviter(referral, 2000, 10, 32) == "capped", "eleventh capped")
	check(referral.paid == 10 and table.find(referral.seen, 2000) == nil, "capped changes nothing")
	local small = SocialConfig.newReferral()
	for id = 1, 5 do
		FriendLogic.payInviter(small, id, 100, 3)
	end
	check(#small.seen == 3 and small.seen[1] == 3, "seen keeps the newest maxSeen")

	-- Queue: enqueue / read / dequeue
	local now = 2_000_000_000
	local maxAge = REFERRAL.QueueMaxAgeDays * 86400
	local record, status = FriendLogic.enqueue(nil, 501, now, 3, maxAge)
	check(status == "queued" and record ~= nil and #record.list == 1, "first entry queued")
	local again, dup = FriendLogic.enqueue(record, 501, now + 5, 3, maxAge)
	check(again == nil and dup == "duplicate", "dedupe by newcomer id (write cancelled)")
	record = FriendLogic.enqueue(record, 502, now, 3, maxAge)
	record = FriendLogic.enqueue(record, 503, now, 3, maxAge)
	local full, fullStatus = FriendLogic.enqueue(record, 504, now, 3, maxAge)
	check(full == nil and fullStatus == "full", "capped list")
	local aged = { v = 1, list = { { id = 601, at = now - maxAge - 1 }, { id = 602, at = now - 10 } } }
	local entries = FriendLogic.readQueue(aged, now, maxAge, 20)
	check(#entries == 1 and entries[1].id == 602, "entries past the max age dropped")
	local junk = { v = 1, list = { { id = "x", at = now }, { id = 5, at = NAN }, 7, { id = 8, at = now + 3600 }, { id = 9, at = now } } }
	entries = FriendLogic.readQueue(junk, now, maxAge, 20)
	check(#entries == 1 and entries[1].id == 9, "junk entries dropped")
	check(#FriendLogic.readQueue("garbage", now, maxAge, 20) == 0, "garbage record → empty")
	-- Another server appended 505 between our read and our cleanup: it survives the dequeue.
	local live = FriendLogic.enqueue({ v = 1, list = { { id = 501, at = now }, { id = 502, at = now } } }, 505, now, 20, maxAge)
	local cleaned = FriendLogic.dequeue(live, { 501, 502 }, now, 20, maxAge)
	check(#cleaned.list == 1 and cleaned.list[1].id == 505, "dequeue removes only handled ids")
	local ids2 = FriendLogic.recordUserIds(cleaned, 42)
	check(ids2[1] == 42 and ids2[2] == 505, "GDPR user ids: inviter + queued newcomers")

	-- Idempotent replay: a crash after paying but before the dequeue re-reads the same queue.
	local inviterRef = SocialConfig.newReferral()
	local queue = { v = 1, list = { { id = 701, at = now }, { id = 702, at = now }, { id = 703, at = now } } }
	local paid = 0
	for _, entry in FriendLogic.readQueue(queue, now, maxAge, 20) do
		if FriendLogic.payInviter(inviterRef, entry.id, 10, 32) == "paid" then
			paid += 1
		end
	end
	check(paid == 3, "first consume pays three")
	paid = 0
	for _, entry in FriendLogic.readQueue(queue, now, maxAge, 20) do
		if FriendLogic.payInviter(inviterRef, entry.id, 10, 32) == "paid" then
			paid += 1
		end
	end
	check(paid == 0 and inviterRef.paid == 3, "replayed consume pays nothing (exactly once)")
end

--------------------------------------------------------------------------------------------------
-- 5. ProfileLogic
--------------------------------------------------------------------------------------------------
do
	local profile = ProfileLogic.defaultProfile()
	check(profile.rush.rookieLeft == 0 and profile.rush.comebackUntil == 0, "default: no rush")
	check(profile.referral.by == 0 and profile.referral.paid == 0 and #profile.referral.seen == 0, "default referral")
	local oldSave = ProfileLogic.reconcile({ cash = 50, gems = 3 })
	check(oldSave.rush.rookieLeft == 0, "an old save reconciles to no Rookie Rush")
	local stored = ProfileLogic.reconcile({
		rush = { rookieLeft = 321, comebackUntil = 2_000_000_100 },
		referral = { by = 42, paid = 4, seen = { 1, 2, 3, 4 } },
	})
	check(stored.rush.rookieLeft == 321 and stored.rush.comebackUntil == 2_000_000_100, "rush round-trips")
	check(stored.referral.by == 42 and stored.referral.paid == 4 and #stored.referral.seen == 4, "referral round-trips")
	local context = { saveStatus = "ok", paidRandomRestricted = false, policyKnown = true }
	local snapshot = ProfileLogic.snapshot(stored, context, { "rush", "referral" })
	check(snapshot.rush.rookieLeft == 321 and snapshot.rush.comebackUntil == 2_000_000_100, "rush snapshot")
	check(snapshot.rush ~= stored.rush, "rush snapshot is a copy")
	check(snapshot.referral.paid == 4 and snapshot.referral.invited == true, "referral snapshot = progress")
	check(snapshot.referral.by == nil and snapshot.referral.seen == nil, "other players' UserIds stay private")
	check(table.find(ProfileLogic.SnapshotFields, "rush") ~= nil, "rush is a snapshot field")
	check(table.find(ProfileLogic.SnapshotFields, "referral") ~= nil, "referral is a snapshot field")
	local saved = ProfileLogic.toSave(stored)
	check(saved.rush.rookieLeft == 321 and #saved.referral.seen == 4, "saved as plain data")
end

--------------------------------------------------------------------------------------------------
-- 6. BoostChipLogic
--------------------------------------------------------------------------------------------------
do
	local now = 1_800_000_000
	local function input(overrides: { [string]: any }): any
		local base: { [string]: any } = {
			now = now,
			rushOn = true,
			friendsOn = true,
			rookieEndsAt = 0,
			comebackEndsAt = 0,
			rookieMultiplier = 2,
			comebackMultiplier = 2,
			friendPercent = 0,
			boosts = {},
			serverEndsAt = 0,
		}
		for key, value in overrides do
			base[key] = value
		end
		return base
	end
	check(#BoostChipLogic.chips(input({})) == 0, "nothing active → no chips")
	local chips = BoostChipLogic.chips(input({ rookieEndsAt = now + 761, friendPercent = 20 }))
	check(#chips == 2 and chips[1].kind == "rookie" and chips[2].kind == "friends", "rookie + friends")
	check(BoostChipLogic.label(chips[1], now, false) == "ROOKIE RUSH 2x 12:41", "rookie label (spec)")
	check(BoostChipLogic.label(chips[1], now, true) == "2x 12:41", "compact rookie label")
	check(BoostChipLogic.label(chips[2], now, false) == "FRIENDS +20%", "friends label (spec)")
	check(BoostChipLogic.label(chips[2], now, true) == "+20%", "compact friends label")
	chips = BoostChipLogic.chips(input({ rookieEndsAt = now + 100, comebackEndsAt = now + 500 }))
	check(#chips == 1 and chips[1].kind == "rookie", "no stacking: one rush chip (rookie on a tie)")
	chips = BoostChipLogic.chips(input({ rookieEndsAt = now + 100, comebackEndsAt = now + 500, comebackMultiplier = 3 }))
	check(#chips == 1 and chips[1].kind == "comeback", "the larger rush shows")
	chips = BoostChipLogic.chips(input({ comebackEndsAt = now + 482 }))
	check(BoostChipLogic.label(chips[1], now, false) == "COMEBACK 2x 8:02", "comeback label")
	chips = BoostChipLogic.chips(input({ rushOn = false, friendsOn = false, rookieEndsAt = now + 5, friendPercent = 30 }))
	check(#chips == 0, "switched off → hidden")
	chips = BoostChipLogic.chips(input({ rookieEndsAt = now - 1, comebackEndsAt = now }))
	check(#chips == 0, "expired rushes hidden")
	chips = BoostChipLogic.chips(input({
		boosts = { cash2x = now + 299, speed2x = now + 60, junk = now + 10 },
		serverEndsAt = now + 3725,
	}))
	check(#chips == 3 and chips[1].kind == "cash" and chips[2].kind == "speed" and chips[3].kind == "server", "boost chips")
	check(BoostChipLogic.label(chips[1], now, false) == "2x CASH 4:59", "cash boost label")
	check(BoostChipLogic.label(chips[3], now, false) == "SERVER 2x 1:02:05", "hour clock")
	check(BoostChipLogic.nextChange(chips) == now + 60, "next change = soonest end")
	local boostChips = chips
	chips = BoostChipLogic.chips(input({ boosts = { cash2x = NAN }, rookieEndsAt = NAN, friendPercent = INF }))
	check(#chips == 0, "junk numbers → no chips")
	check(BoostChipLogic.clock(-5) == "0:00" and BoostChipLogic.clock(NAN) == "0:00", "clock never negative / NaN")

	-- R82 corner badge: what each boost multiplies, the combined number, the timer pick.
	check(boostChips[1].multiplier == 2 and boostChips[2].multiplier == 2 and boostChips[3].multiplier == 2, "multipliers")
	check(BoostChipLogic.badge({}) == nil, "no boosts → no badge")
	local badge = BoostChipLogic.badge(boostChips)
	check(badge ~= nil and badge.multiplier == 8 and badge.text == "8x" and badge.count == 3, "cash x speed x server = 8x")
	check(badge.headline.kind == "speed" and badge.color == "sky" and badge.endsAt == now + 60, "headline = soonest end")
	check(badge.second ~= nil and badge.second.kind == "cash", "stacked sticker = the first other boost")
	check(BoostChipLogic.badgeSmall(badge, now) == "1:00", "badge timer = the soonest")
	local cashOnly = BoostChipLogic.badge(BoostChipLogic.chips(input({ boosts = { cash2x = now + 85 } })))
	check(cashOnly ~= nil and cashOnly.text == "2x" and cashOnly.color == "green" and cashOnly.second == nil, "2x Cash alone")
	check(BoostChipLogic.badgeSmall(cashOnly, now) == "1:25", "owner's screenshot: 2x / 1:25")
	local rookieFriends = BoostChipLogic.chips(input({ rookieEndsAt = now + 761, friendPercent = 20 }))
	check(rookieFriends[2].multiplier == 1.2, "Friend Boost +20 % = x1.2")
	badge = BoostChipLogic.badge(rookieFriends)
	check(badge ~= nil and badge.text == "2.4x" and badge.headline.kind == "rookie", "rush x friends = 2.4x")
	check(BoostChipLogic.badgeSmall(badge, now) == "12:41", "friends never take the timer slot")
	badge = BoostChipLogic.badge(BoostChipLogic.chips(input({ friendPercent = 20 })))
	check(badge ~= nil and badge.text == "+20%" and badge.endsAt == nil and badge.color == "blue", "friends alone read +20%")
	check(BoostChipLogic.badgeSmall(badge, now) == SocialConfig.Text.BadgeNoTimer, "no timer → FRIENDS")
	badge = BoostChipLogic.badge(BoostChipLogic.chips(input({
		comebackEndsAt = now + 100,
		comebackMultiplier = 3,
		friendPercent = 50,
		boosts = { cash2x = now + 50 },
	})))
	check(badge ~= nil and badge.text == "9x" and badge.headline.kind == "cash", "3x rush x 2x cash x 1.5 friends = 9x")
	check(BoostChipLogic.rowTime(rookieFriends[1], now) == "12:41" and BoostChipLogic.rowTime(rookieFriends[2], now) == "", "row times")
	-- Rounded DOWN to one decimal (never more than the player gets), float-safe, junk = 1x.
	check(BoostChipLogic.times(2.42) == "2.4x" and BoostChipLogic.times(2.49) == "2.4x", "times floors")
	check(BoostChipLogic.times(1.2 * 2 * 2) == "4.8x" and BoostChipLogic.times(4) == "4x", "times float-safe")
	check(BoostChipLogic.times(NAN) == "1x" and BoostChipLogic.times(0.5) == "1x" and BoostChipLogic.times(INF) == "1x", "times junk")
	local junk = BoostChipLogic.badge({
		{ kind = "cash", color = "green", icon = "x2Cash", text = "2x CASH", compact = "2x", endsAt = now + 5, multiplier = NAN },
	} :: any)
	check(junk ~= nil and junk.text == "1x", "a junk multiplier counts as x1")

	-- Size: two lines + padding, wide enough for the longer line, never under the minimum.
	local function size(big: string, small: string): (number, number)
		return BoostChipLogic.badgeSize({
			big = big,
			small = small,
			bigSize = 34,
			smallSize = 20,
			padX = 10,
			padY = 5,
			charRatio = 0.7,
			minWidth = 72,
		})
	end
	local w1, h1 = size("2x", "1:25")
	check(w1 == 76 and h1 == 64, "2x / 1:25 badge size")
	local w2 = size("2x", "23:59:59")
	check(w2 > w1, "a longer timer widens the badge")
	check((size("2x", "")) == 72, "never under the minimum width")

	-- The gap keeps every corner of the tilted sticker (and its outline) right of the digits' box.
	check(BoostChipLogic.cornerGap(96, 64, 8, 11) == 15, "8 degree tilt adds its corner overhang")
	check(BoostChipLogic.cornerGap(96, 64, -8, 11) == 15, "either tilt direction")
	check(BoostChipLogic.cornerGap(96, 64, 0, 11) == 11 and BoostChipLogic.cornerGap(400, 10, 8, 11) == 11, "never under the base")
	check(BoostChipLogic.cornerGap(96, 64, NAN, 11) == 11, "junk tilt = no tilt")
	for _, case in { { 72, 64, 8 }, { 76, 64, 8 }, { 180, 100, 8 }, { 90, 120, 12 }, { 120, 99, -5 } } do
		local w, h, tilt = case[1], case[2], case[3]
		local gap = BoostChipLogic.cornerGap(w, h, tilt, 11)
		local r = math.rad(tilt)
		local leftmost = math.huge
		for _, corner in { { -w / 2, -h / 2 }, { w / 2, -h / 2 }, { -w / 2, h / 2 }, { w / 2, h / 2 } } do
			-- Screen space (y down): Rotation > 0 turns clockwise.
			local x = corner[1] * math.cos(r) - corner[2] * math.sin(r)
			leftmost = math.min(leftmost, gap + w / 2 + x)
		end
		check(leftmost >= 11 - 1e-9, `tilted corner stays clear of the digits ({w}x{h} @ {tilt})`)
	end
end

--------------------------------------------------------------------------------------------------
-- 7. RewardsBadges Friends tile
--------------------------------------------------------------------------------------------------
do
	check(HubConfig.byId("Friends") ~= nil and HubConfig.byId("Friends").screen == "Friends", "Friends tile opens Friends")
	check(table.find(AnalyticsConfig.ClientFunnel.Screens, "Friends") ~= nil, "Friends screen id allowlisted")
	local now = 1_800_000_000
	local snap = Badges.evaluate({ profile = {}, now = now, groupEnabled = false, friendPercent = 20 })
	local friends = snap.features.Friends
	check(friends.count == 0 and friends.kind == "boost" and friends.value == 20, "boost state")
	local text, tone = Badges.statusText(friends, now)
	check(text == "+20% cash!" and tone == "ready", "boost line")
	snap = Badges.evaluate({ profile = {}, now = now, groupEnabled = false })
	check(snap.features.Friends.kind == "invite", "no friends → invite")
	text = Badges.statusText(snap.features.Friends, now)
	check(text == HubConfig.Text.FriendsInvite, "invite line")
	snap = Badges.evaluate({ profile = {}, now = NAN, groupEnabled = false, friendPercent = 20 })
	check(snap.features.Friends.kind == "invite" and snap.total == 0, "no clock → invite, never badges")
	snap = Badges.evaluate({ profile = {}, now = now, groupEnabled = false, friendPercent = NAN })
	check(snap.features.Friends.kind == "invite", "junk percent → invite")
end

print(`social-logic: {checks} checks passed`)
