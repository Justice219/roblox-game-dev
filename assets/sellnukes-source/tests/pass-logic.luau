--!strict
--[[
	Nuke Pass regressions (owner R78; spec docs/superpowers/specs/2026-10-31-r78-retention-pack-
	design.md §2; docs/nuke-pass.md). Run:
		lune run tests/pass-logic
	Proves on the shipped modules (Shared/Config/PassConfig, Server/Pass/PassLogic,
	Server/Economy/ProfileLogic):
	  1. Catalogue: validate() clean, Season 1 instants = the Harvest Feast window, 30 tiers × 400 XP,
	     free gems 10–40, exclusives where the spec puts them (and real in their catalogues: the
	     Harvest Glow trail in NO crate pool, SEASON 1 / NUKE PASS titles with showOwn), every boost /
	     egg id real, premium ≈ double + eggs and clearly worth 159 R$ vs the gem packs, the product
	     row (kind PassPremium, 159 R$, live id), analytics keys + the "pass" prompt source.
	  2. Season boundaries at the exact instants (start inclusive, end exclusive), next / last season.
	  3. Tier math: tierOf / progress / overflowEarned incl. tier 30 → bonus chest progress.
	  4. XP: only into the active season, play cap 360 per UTC day (resets next day), quest XP
	     uncapped, MaxXp bound, garbage amounts ignored, tiers-reached lists.
	  5. Claims: every refusal code, idempotency (a second claim pays nothing), premium needs
	     premium, CLAIM ALL, overflow chests.
	  6. Premium: retroactive (buying late unlocks every reached tier), receipt outcomes (granted /
	     already owned → fallback / grace after the end / too late or other season → fallback).
	  7. Rollover: end-of-season auto-grant (free + premium + chests) exactly once, state kept between
	     seasons, fresh / unknown states reset for the active season, premium seasons kept.
	  8. Reward shaping: premium spins / eggs → gems where paid random items are restricted; the
	     exclusive split keeps exactly one fallback.
	  9. State repair + wire: NaN / garbage / hostile tables, array ↔ map tier sets, bounded premium
	     set, ProfileLogic default / reconcile / toSave / snapshot carry `pass`.
	 10. claimableCount / offerVisible / status on raw, garbage and stale states; the Studio clock.
	 11. Settle / XP ordering (Server/Pass/PassFlow, lead review): XP arriving while a season-end
	     settle owes premium spins / eggs and the policy is unknown (or another settle / claim is in
	     flight) is HELD, never settles with a guessed policy; once the policy is known the settle
	     pays spins / eggs to an allowed buyer; the held XP drains exactly once (dropped between
	     seasons, applied after a reset into an active season); the hold queue is bounded.
]]
local Loader = require("./fixtures/RobloxLoader")
local loader = Loader.new()
local PassConfig = loader.load("src/shared/Config/PassConfig")
local PassLogic = loader.load("src/server/Pass/PassLogic")
local PassFlow = loader.load("src/server/Pass/PassFlow")
local ProfileLogic = loader.load("src/server/Economy/ProfileLogic")
local CrateConfig = loader.load("src/shared/Config/CrateConfig")
local PlayerTitlesConfig = loader.load("src/shared/Config/PlayerTitlesConfig")
local MonetizationConfig = loader.load("src/shared/Config/MonetizationConfig")
local EventConfig = loader.load("src/shared/Config/EventConfig")
local BoostConfig = loader.load("src/shared/Config/BoostConfig")
local EggConfig = loader.load("src/shared/Config/EggConfig")
local AnalyticsConfig = loader.load("src/shared/Config/AnalyticsConfig")
local PurchasePromptConfig = loader.load("src/shared/Config/PurchasePromptConfig")
local LuckySpinConfig = loader.load("src/shared/Config/LuckySpinConfig")

local checks = 0
local function ok(condition: boolean, label: string)
	checks += 1
	assert(condition, label)
end

local SEASON = PassConfig.Seasons.harvest1
local START = SEASON.startsAt
local END_ = SEASON.endsAt
local MID = START + 10 * 86_400
local PER = PassConfig.XpPerTier

-- A fresh state already rolled into Season 1 (what a join during the season produces).
local function seasonState(): any
	local state = PassConfig.newState()
	PassLogic.rollover(state, MID)
	return state
end

-- 1. Catalogue -------------------------------------------------------------------------------------
local problems = PassConfig.validate()
ok(#problems == 0, "PassConfig.validate: " .. table.concat(problems, "; "))
ok(SEASON.id == "harvest1" and SEASON.number == 1 and SEASON.name == "Harvest Season", "Season 1 identity")
ok(START == EventConfig.Season.starts and END_ == EventConfig.Season.ends, "Season 1 = the Harvest Feast window")
ok(START == 1_793_491_200 and END_ == 1_796_083_200, "Season 1 instants: 2026-11-01 → 2026-12-01 UTC")
ok(PassConfig.TierCount == 30 and PER == 400, "30 tiers × 400 XP")
ok(#SEASON.tiers == 30, "Season 1 has 30 tiers")
ok(PassConfig.OverflowXp == 800 and PassConfig.OverflowReward.gems == 20, "bonus chest every 800 XP = 20 gems")
ok(
	PassConfig.PlayXp.Amount == 10 and PassConfig.PlayXp.EveryMinutes == 5 and PassConfig.PlayXp.DailyCap == 360,
	"play XP: 10 per 5 online minutes, cap 360 per UTC day"
)
for index, tier in SEASON.tiers do
	local free = tier.free
	if free.gems ~= nil then
		ok(free.gems >= 10 and free.gems <= 40, `free tier {index}: gems 10–40`)
	end
	for _, reward in { tier.free, tier.premium } do
		if reward.boost ~= nil then
			ok(BoostConfig.get(reward.boost.key) ~= nil, `tier {index}: boost {reward.boost.key} exists`)
			ok(reward.boost.seconds == 900 or reward.boost.seconds == 1_800, `tier {index}: 15 / 30 min boost`)
		end
		if reward.egg ~= nil then
			ok(EggConfig.get(reward.egg) ~= nil, `tier {index}: egg {reward.egg} exists`)
			ok(EggConfig.get(reward.egg).currency == "held", `tier {index}: eggs are held-only (never a purchase)`)
		end
	end
end
ok(SEASON.tiers[30].free.title == "season1", "free tier 30 = title SEASON 1")
ok(SEASON.tiers[10].premium.trail == "harvest_glow", "premium tier 10 = Harvest Glow trail")
ok(SEASON.tiers[20].premium.title == "nukePass", "premium tier 20 = title NUKE PASS")
ok(SEASON.tiers[30].premium.pet == "golden_nukey", "premium tier 30 = Golden Nukey")
ok(
	SEASON.tiers[30].premium.fallbackGems ~= nil and SEASON.tiers[30].premium.fallbackGems >= 300,
	"pet fallback is generous"
)
-- Exclusives exist in their catalogues.
local glow = CrateConfig.getTrail("harvest_glow")
ok(glow ~= nil and glow.name == "Harvest Glow", "Harvest Glow trail row exists")
ok(table.find(CrateConfig.TrailOrder, "harvest_glow") ~= nil, "Harvest Glow listed (Pets screen trails tab)")
for crateId, crate in CrateConfig.Crates do
	for _, reward in crate.rewards do
		ok(not (reward.kind == "trail" and reward.id == "harvest_glow"), `Harvest Glow is in NO crate pool ({crateId})`)
	end
end
for _, key in { "season1", "nukePass" } do
	local def = PlayerTitlesConfig.Titles[key]
	ok(def ~= nil and def.key == key, `title {key} exists`)
	ok(def.showOwn == true and def.grantable == true, `title {key}: showOwn + grantable`)
	ok(table.find(PlayerTitlesConfig.Order, key) ~= nil, `title {key} in Order`)
end
ok(PlayerTitlesConfig.Titles.season1.label == "SEASON 1", "SEASON 1 label")
ok(PlayerTitlesConfig.Titles.nukePass.label == "NUKE PASS", "NUKE PASS label")
-- Value: premium ≈ double free + eggs, and clearly worth 159 R$ against the gem packs.
local free, premium = PassConfig.totals(SEASON, "free"), PassConfig.totals(SEASON, "premium")
ok(premium.gems >= 2 * free.gems, `premium gems ({premium.gems}) ≥ 2 × free ({free.gems})`)
ok(premium.spins >= 2 * free.spins, "premium spins ≥ 2 × free")
ok(premium.eggs > free.eggs and premium.exclusives == 3, "premium adds eggs + 3 exclusives")
local product = MonetizationConfig.getProduct("NukePassPremium")
ok(
	product ~= nil and product.kind == "PassPremium" and product.price == 159,
	"product NukePassPremium: PassPremium, 159 R$"
)
ok(MonetizationConfig.isConfigured(product.id), "NukePassPremium has its live dashboard id")
ok(not product.paidRandom and not product.oneTime, "premium is deterministic (not paid random) and per season")
ok(
	product.saleStarts == nil and product.saleEnds == nil,
	"season gating is PassService's refusal (one source of truth)"
)
local bestRate = 0
for _, key in { "GemsSmall", "GemsMedium", "GemsLarge" } do
	local gems = MonetizationConfig.getProduct(key)
	bestRate = math.max(bestRate, gems.gems / gems.price)
end
local premiumValue = premium.gems + premium.spins * LuckySpinConfig.GemsPerSpin + premium.eggs * 15
ok(premiumValue > 2 * product.price * bestRate, `premium value {premiumValue} gems > 2 × what 159 R$ buys in packs`)
ok(PassConfig.PremiumFallbackGems >= product.price * bestRate, "fallback gems ≥ what 159 R$ buys in packs")
ok(PassConfig.PremiumProduct == "NukePassPremium", "PremiumProduct key")
ok(table.find(PurchasePromptConfig.Sources, "pass") ~= nil, '"pass" prompt source allowlisted')
local retention = AnalyticsConfig.Metrics.retention
for _, pattern in
	{
		"pass:xp:<starter|daily|chest|trophy|play|admin|other>",
		"pass:tier:<1-30>",
		"pass:claims:<free|premium|overflow>",
		"pass:claim:<free|premium>:<1-30>",
		"pass:claimAll",
		"pass:auto:<free|premium|overflow>",
		"pass:premium:<granted|grace|fallback|admin>",
		"pass:premiumTier:<0-30>",
		"pass:policyGems",
		"pass:season:<seasonId>",
		"pass:refused:<wait|recheck>",
	}
do
	ok(retention[pattern] ~= nil, `analytics key {pattern} documented`)
end
ok(table.find(AnalyticsConfig.ClientFunnel.Screens, "NukePass") ~= nil, "NukePass screen id allowlisted")

-- 2. Season boundaries ------------------------------------------------------------------------------
ok(PassConfig.activeSeason(START - 1) == nil, "one second before the start: no season")
ok(PassConfig.activeSeason(START) == SEASON, "the start instant is inside (inclusive)")
ok(PassConfig.activeSeason(END_ - 1) == SEASON, "one second before the end: still Season 1")
ok(PassConfig.activeSeason(END_) == nil, "the end instant is outside (exclusive)")
ok(PassConfig.activeSeason(0 / 0) == nil and PassConfig.activeSeason(math.huge) == nil, "NaN / inf clock: no season")
ok(PassConfig.nextSeason(START - 1) == SEASON and PassConfig.nextSeason(START) == nil, "next season before the start")
ok(PassConfig.lastEndedSeason(END_ - 1) == nil and PassConfig.lastEndedSeason(END_) == SEASON, "last ended season")
ok(PassConfig.hasEnded("harvest1", END_) and not PassConfig.hasEnded("harvest1", END_ - 1), "hasEnded at the instant")
ok(not PassConfig.hasEnded("nope", END_ + 1), "unknown seasons never 'end'")

-- 3. Tier math --------------------------------------------------------------------------------------
ok(PassConfig.tierOf(0) == 0 and PassConfig.tierOf(399) == 0 and PassConfig.tierOf(400) == 1, "tier edges")
ok(PassConfig.tierOf(12_000) == 30 and PassConfig.tierOf(99_999) == 30, "tier caps at 30")
ok(
	PassConfig.tierOf(0 / 0) == 0 and PassConfig.tierOf(-5) == 0 and PassConfig.tierOf("x") == 0,
	"garbage xp → tier 0"
)
local t, into, per = PassConfig.progress(1_320)
ok(t == 3 and into == 120 and per == 400, "progress(1320) = 3, 120, 400")
t, into, per = PassConfig.progress(12_500)
ok(t == 30 and into == 500 and per == 800, "tier 30: progress toward the next chest")
t, into, per = PassConfig.progress(0 / 0)
ok(t == 0 and into == 0 and per == 400, "progress(NaN) = 0, 0, 400")
ok(PassConfig.overflowEarned(12_000) == 0 and PassConfig.overflowEarned(12_799) == 0, "no chest before 800 XP extra")
ok(PassConfig.overflowEarned(12_800) == 1 and PassConfig.overflowEarned(14_400) == 3, "chests every 800 XP")

-- 4. XP ---------------------------------------------------------------------------------------------
do
	local state = PassConfig.newState()
	local added = PassLogic.addXp(state, 100, "daily", MID)
	ok(added == 0 and state.xp == 0, "no XP before the state joined the season (rollover first)")
	PassLogic.rollover(state, MID)
	ok(state.season == "harvest1", "rollover joins the active season")
	local reached
	added, reached = PassLogic.addXp(state, 450, "starter", MID)
	ok(added == 450 and #reached == 1 and reached[1] == 1, "450 quest XP → tier 1 reached")
	added, reached = PassLogic.addXp(state, 800, "daily", MID)
	ok(added == 800 and #reached == 2 and reached[1] == 2 and reached[2] == 3, "800 more → tiers 2 and 3")
	-- Play cap.
	local before = state.xp
	local total = 0
	for _ = 1, 60 do
		total += PassLogic.addXp(state, 10, "play", MID)
	end
	ok(total == 360 and state.dayXp == 360 and state.xp == before + 360, "play XP capped at 360 per UTC day")
	ok(PassLogic.addXp(state, 500, "trophy", MID) == 500, "quest XP ignores the play cap")
	ok(
		PassLogic.addXp(state, 10, "play", MID + 86_400) == 10 and state.dayXp == 10,
		"the cap resets on the next UTC day"
	)
	ok(PassLogic.addXp(state, 0 / 0, "daily", MID) == 0, "NaN XP ignored")
	ok(PassLogic.addXp(state, -50, "daily", MID) == 0, "negative XP ignored")
	ok(PassLogic.addXp(state, "100", "daily", MID) == 0, "string XP ignored")
	ok(PassLogic.addXp(state, 100, "daily", END_) == 0, "no XP once the season ended")
	PassLogic.addXp(state, 5_000_000, "admin", MID)
	ok(state.xp == PassConfig.MaxXp, "XP bounded by MaxXp")
	ok(PassLogic.playXpFor(5) == 10 and PassLogic.playXpFor(10) == 10, "10 XP every 5 online minutes")
	ok(
		PassLogic.playXpFor(4) == 0 and PassLogic.playXpFor(0) == 0 and PassLogic.playXpFor(0 / 0) == 0,
		"no XP off-beat"
	)
end

-- 5. Claims -----------------------------------------------------------------------------------------
do
	local state = seasonState()
	PassLogic.addXp(state, 3 * PER, "daily", MID)
	local code, grant = PassLogic.claim(state, "free", 1, MID)
	ok(code == "Ok" and grant ~= nil and grant.tier == 1 and grant.track == "free", "claim free tier 1")
	ok(grant.reward == SEASON.tiers[1].free, "the grant pays the catalogue reward")
	code, grant = PassLogic.claim(state, "free", 1, MID)
	ok(code == "Claimed" and grant == nil, "a second claim pays nothing (idempotent)")
	ok(PassLogic.claim(state, "free", 4, MID) == "NotReached", "tier 4 not reached")
	ok(PassLogic.claim(state, "premium", 1, MID) == "NotPremium", "premium needs premium")
	ok(PassLogic.claim(state, "gold", 1, MID) == "BadTrack", "unknown track")
	for _, bad in { 0, 31, 1.5, 0 / 0, math.huge, "1", nil :: any, {} } do
		ok(PassLogic.claim(state, "free", bad, MID) == "BadTier", `bad tier {tostring(bad)}`)
	end
	ok(PassLogic.claim(state, "free", 2, END_) == "NoSeason", "no claims once the season ended")
	ok(PassLogic.claim(state, "free", 2, START - 1) == "NoSeason", "no claims before the season")
	local allCode, grants = PassLogic.claimAll(state, MID)
	ok(allCode == "Ok" and #grants == 2, "CLAIM ALL pays the 2 remaining free tiers")
	allCode, grants = PassLogic.claimAll(state, MID)
	ok(allCode == "Claimed" and #grants == 0, "CLAIM ALL twice pays nothing")
	-- Overflow chests.
	PassLogic.setTier(state, 30, MID)
	PassLogic.addXp(state, 2 * 800 + 10, "admin", MID)
	local chests = PassLogic.claimOverflow(state, MID)
	ok(#chests == 2 and chests[1].track == "overflow" and chests[2].tier == 2, "two bonus chests")
	ok(chests[1].reward.gems == 20, "a chest pays 20 gems")
	ok(#PassLogic.claimOverflow(state, MID) == 0, "chests claim once")
	PassLogic.addXp(state, 800, "admin", MID)
	allCode, grants = PassLogic.claimAll(state, MID)
	local overflowCount = 0
	for _, g in grants do
		overflowCount += if g.track == "overflow" then 1 else 0
	end
	ok(overflowCount == 1 and state.overflow == 3, "CLAIM ALL includes new chests")
end

-- 6. Premium -----------------------------------------------------------------------------------------
do
	local state = seasonState()
	PassLogic.addXp(state, 12 * PER, "daily", MID)
	PassLogic.claimAll(state, MID)
	local outcome, seasonId = PassLogic.premiumReceipt(state, MID)
	ok(outcome == "granted" and seasonId == "harvest1" and state.premium.harvest1 == true, "receipt unlocks the season")
	local code, grants = PassLogic.claimAll(state, MID)
	ok(code == "Ok" and #grants == 12, "buying late unlocks every reached premium tier (12)")
	for _, g in grants do
		ok(g.track == "premium", "retroactive grants are premium")
	end
	ok(PassLogic.premiumReceipt(state, MID) == "fallback", "a second receipt this season → fallback gems")
	-- Grace: the season just ended, the state still holds it.
	local late = seasonState()
	PassLogic.addXp(late, 5 * PER, "daily", MID)
	outcome, seasonId = PassLogic.premiumReceipt(late, END_ + 60)
	ok(outcome == "grace" and seasonId == "harvest1", "receipt 1 min after the end → grace unlock")
	local result = PassLogic.rollover(late, END_ + 61)
	local premiumGrants = 0
	for _, g in result.grants do
		premiumGrants += if g.track == "premium" then 1 else 0
	end
	ok(premiumGrants == 5, "the grace unlock auto-grants the ended season's premium tiers")
	local tooLate = seasonState()
	ok(
		PassLogic.premiumReceipt(tooLate, END_ + PassConfig.PremiumGraceSeconds) == "fallback",
		"receipt after the grace → fallback"
	)
	local other = PassConfig.newState()
	ok(PassLogic.premiumReceipt(other, END_ + 60) == "fallback", "grace needs the state to hold that season")
	ok(PassLogic.premiumReceipt(PassConfig.newState(), START - 60) == "fallback", "before any season → fallback")
	ok(PassLogic.premiumReceipt(PassConfig.newState(), 0 / 0) == "fallback", "NaN clock → fallback")
	-- Admin toggles.
	local admin = seasonState()
	local changed, id = PassLogic.setPremium(admin, true, MID)
	ok(changed and id == "harvest1" and admin.premium.harvest1, "admin premium on")
	ok(PassLogic.setPremium(admin, true, MID) == false, "admin premium on twice: no change")
	ok(PassLogic.setPremium(admin, false, MID) and admin.premium.harvest1 == nil, "admin premium off")
	ok(PassLogic.setPremium(PassConfig.newState(), true, MID) == false, "admin premium needs the active season")
	ok(PassLogic.setTier(admin, 7, MID) and admin.xp == 7 * PER, "admin set tier 7")
	ok(not PassLogic.setTier(admin, 0 / 0, MID) and not PassLogic.setTier(admin, 2.5, MID), "admin set tier: garbage")
	ok(PassLogic.setTier(admin, 99, MID) and admin.xp == 30 * PER, "admin set tier clamps to 30")
end

-- 7. Rollover ----------------------------------------------------------------------------------------
do
	local state = seasonState()
	ok(state.season == "harvest1" and state.xp == 0, "join during the season")
	local again = PassLogic.rollover(state, MID)
	ok(#again.grants == 0 and again.started == nil and again.ended == nil, "rollover mid-season is a no-op")
	PassLogic.addXp(state, 30 * PER + 1_700, "daily", MID) -- tier 30 + 2 chests
	PassLogic.claim(state, "free", 1, MID)
	state.premium.harvest1 = true
	PassLogic.claim(state, "premium", 2, MID)
	ok(PassLogic.needsRollover(state, END_ - 1) == false, "nothing to settle before the end")
	ok(PassLogic.needsRollover(state, END_) == true, "leftovers to settle at the end instant")
	local result = PassLogic.rollover(state, END_)
	local counts = { free = 0, premium = 0, overflow = 0 }
	for _, g in result.grants do
		counts[g.track] += 1
	end
	ok(result.ended == "harvest1", "the ended season is reported")
	ok(
		counts.free == 29 and counts.premium == 29 and counts.overflow == 2,
		"auto-grant: 29 free + 29 premium + 2 chests"
	)
	ok(state.season == "harvest1" and state.xp == 30 * PER + 1_700, "the state is kept between seasons")
	ok(result.started == nil, "no new season to start yet")
	local second = PassLogic.rollover(state, END_ + 86_400)
	ok(#second.grants == 0, "auto-grant happens exactly once")
	ok(not PassLogic.needsRollover(state, END_ + 86_400), "nothing left to settle")
	ok(PassConfig.claimableCount(state, END_ + 10) == 0, "nothing claimable between seasons")
	-- Unknown / garbage season ids reset for the active season; premium seasons survive.
	local stranger = PassConfig.reconcileState({ season = "future9", xp = 5_000, premium = { future9 = true } })
	local reset = PassLogic.rollover(stranger, MID)
	ok(reset.started == "harvest1" and stranger.xp == 0 and stranger.season == "harvest1", "unknown season → reset")
	ok(stranger.premium.future9 == true, "premium of other seasons is kept")
	local fresh = PassConfig.newState()
	ok(PassLogic.rollover(fresh, START - 1).started == nil and fresh.season == "", "no season yet: state untouched")
	ok(#PassLogic.rollover(fresh, 0 / 0).grants == 0, "NaN clock: rollover does nothing")
end

-- 8. Reward shaping --------------------------------------------------------------------------------
do
	local shaped, paid = PassLogic.premiumReward({ spins = 2, gems = 10 }, false, 40)
	ok(shaped.spins == nil and shaped.gems == 90 and paid == false, "restricted: 2 spins → 80 gems (+10)")
	shaped, paid = PassLogic.premiumReward({ egg = "lucky_egg", fallbackGems = 15 }, false, 40)
	ok(shaped.egg == nil and shaped.gems == 15 and shaped.fallbackGems == nil, "restricted: egg → its fallback gems")
	local original = { spins = 3 }
	shaped, paid = PassLogic.premiumReward(original, true, 40)
	ok(shaped == original and paid == true, "allowed: unchanged, spins to the paid bank")
	shaped = PassLogic.premiumReward({ cashSeconds = 60, cashFloor = 10 }, false, 40)
	ok(shaped.gems == nil and shaped.cashSeconds == 60, "restricted: cash untouched, no phantom gems")
	local base, exclusive = PassLogic.splitReward(SEASON.tiers[30].premium)
	ok(base.gems == 100 and base.pet == nil and base.fallbackGems == nil, "pet tier: RewardLogic part has gems only")
	ok(
		exclusive ~= nil and exclusive.pet == "golden_nukey" and exclusive.fallbackGems == 400,
		"pet tier: exclusive + fallback"
	)
	base, exclusive = PassLogic.splitReward(SEASON.tiers[1].premium)
	ok(
		base.egg == "lucky_egg" and base.fallbackGems == 15 and exclusive == nil,
		"egg tier: egg + fallback stay in base"
	)
	base, exclusive = PassLogic.splitReward(SEASON.tiers[20].premium)
	ok(exclusive ~= nil and exclusive.title == "nukePass" and base.gems == 75, "title tier split")
	ok(
		PassLogic.needsPolicy({ { track = "premium", tier = 3, season = "harvest1", reward = { spins = 2 } } }),
		"premium spins need the policy"
	)
	ok(
		not PassLogic.needsPolicy({ { track = "free", tier = 3, season = "harvest1", reward = { spins = 1 } } }),
		"free spins never do"
	)
end

-- 9. State repair + wire ----------------------------------------------------------------------------
do
	local repaired = PassConfig.reconcileState({
		season = "harvest1",
		xp = 0 / 0,
		dayXp = 99_999,
		day = -4,
		claimedFree = { 1, 2, 99, 2.5, "x", -1 },
		claimedPremium = { [3] = true, [40] = true, [4] = "yes" },
		premium = { harvest1 = true, ["BAD ID"] = true, [5] = "harvest2" },
		overflow = -3,
	})
	ok(repaired.xp == 0 and repaired.dayXp == 360 and repaired.day == 0, "numbers repaired + clamped")
	ok(repaired.claimedFree[1] and repaired.claimedFree[2] and repaired.claimedFree[99] == nil, "array tier set read")
	ok(
		repaired.claimedPremium[3] and repaired.claimedPremium[40] == nil and repaired.claimedPremium[4] == nil,
		"map tier set read"
	)
	ok(
		repaired.premium.harvest1 and repaired.premium.harvest2 and repaired.premium["BAD ID"] == nil,
		"premium ids validated"
	)
	ok(repaired.overflow == 0, "negative overflow → 0")
	for _, junk in
		{ nil :: any, "junk", 42, true, setmetatable({}, {
			__index = function()
				error("trap")
			end,
		}) }
	do
		local state = PassConfig.reconcileState(junk)
		ok(
			state.season == "" and state.xp == 0 and next(state.claimedFree) == nil,
			`junk {typeof(junk)} → fresh state`
		)
	end
	local noSeason = PassConfig.reconcileState({ season = "", xp = 900, claimedFree = { 1 } })
	ok(noSeason.xp == 0 and next(noSeason.claimedFree) == nil, "no season → nothing earned or claimed")
	local tooMany: { [string]: boolean } = {}
	for i = 1, 100 do
		tooMany[`s{i}`] = true
	end
	local bounded = PassConfig.reconcileState({ season = "harvest1", premium = tooMany })
	local premiumCount = 0
	for _ in bounded.premium do
		premiumCount += 1
	end
	ok(premiumCount <= PassConfig.MaxPremiumSeasons, "premium set bounded")
	local hostile: { [number]: boolean } = {}
	for i = 1, 10_000 do
		hostile[i] = true
	end
	-- 10,000 entries: the walk stops after 4 × TierCount entries (array part 1..120 first).
	local walked = PassConfig.reconcileState({ season = "harvest1", claimedFree = hostile })
	ok(walked.claimedFree[30] == true and walked.claimedFree[31] == nil, "huge sets are walked boundedly")
	-- Wire / save form round-trips.
	local state = seasonState()
	PassLogic.addXp(state, 5 * PER, "daily", MID)
	PassLogic.claim(state, "free", 3, MID)
	PassLogic.claim(state, "free", 1, MID)
	local wire = PassConfig.toWire(state)
	ok(wire.claimedFree[1] == 1 and wire.claimedFree[2] == 3 and #wire.claimedFree == 2, "tier sets → sorted arrays")
	ok(wire.claimedFree ~= state.claimedFree and wire.premium ~= state.premium, "wire never shares live tables")
	local back = PassConfig.readState(wire)
	ok(back.claimedFree[1] and back.claimedFree[3] and back.xp == state.xp, "array form reads back")
	-- ProfileLogic carries the field.
	local profile = ProfileLogic.defaultProfile()
	ok(profile.pass ~= nil and profile.pass.season == "" and profile.pass.xp == 0, "default profile has pass")
	ok(table.find(ProfileLogic.SnapshotFields, "pass") ~= nil, "pass is a snapshot field")
	local stored = ProfileLogic.toSave(profile)
	ok(type(stored.pass.claimedFree) == "table" and #stored.pass.claimedFree == 0, "toSave writes the array form")
	local migrated = ProfileLogic.reconcile({ pass = { season = "harvest1", xp = 800, claimedFree = { 1 } } } :: any)
	ok(migrated.pass.xp == 800 and migrated.pass.claimedFree[1] == true, "reconcile reads the saved pass")
	local legacy = ProfileLogic.reconcile({} :: any)
	ok(legacy.pass.season == "" and legacy.pass.xp == 0, "pre-0.6.0 saves get a fresh pass")
	local snap = ProfileLogic.snapshot(
		migrated,
		{ saveStatus = "ok", paidRandomRestricted = false, policyKnown = true } :: any,
		{ "pass" }
	)
	ok(snap.pass.claimedFree[1] == 1 and snap.pass.xp == 800, "snapshot pass = wire form")
end

-- 10. claimableCount / offerVisible / status / clock --------------------------------------------------
do
	ok(PassConfig.claimableCount(nil, MID) == 0, "claimableCount(nil) = 0")
	ok(PassConfig.claimableCount("junk", MID) == 0, "claimableCount(junk) = 0")
	ok(PassConfig.claimableCount({}, 0 / 0) == 0, "claimableCount(NaN clock) = 0")
	ok(PassConfig.claimableCount({ season = "harvest1", xp = "lots" }, MID) == 0, "garbage xp = 0")
	local state = seasonState()
	PassLogic.addXp(state, 3 * PER, "daily", MID)
	ok(PassConfig.claimableCount(state, MID) == 3, "3 free tiers claimable")
	state.premium.harvest1 = true
	ok(PassConfig.claimableCount(state, MID) == 6, "premium adds 3 more")
	ok(PassConfig.claimableCount(PassConfig.toWire(state), MID) == 6, "works on the client's wire form")
	PassLogic.claimAll(state, MID)
	ok(PassConfig.claimableCount(state, MID) == 0, "0 after CLAIM ALL")
	PassLogic.setTier(state, 30, MID)
	PassLogic.claimAll(state, MID)
	PassLogic.addXp(state, 1_600, "admin", MID)
	ok(PassConfig.claimableCount(state, MID) == 1, "earned chests count as one CLAIM")
	ok(PassConfig.claimableCount(state, END_) == 0, "an ended season's leftovers are auto-granted, not claimed")
	local stale = PassConfig.reconcileState({ season = "oldseason", xp = 4_000 })
	ok(PassConfig.claimableCount(stale, MID) == 0, "a stale season state claims nothing")
	local status = PassConfig.statusOf({ season = "harvest1", xp = 2 * PER }, MID)
	ok(
		status.season == SEASON and status.tier == 2 and #status.premiumLocked == 2 and not status.premium,
		"status: locked premium"
	)
	ok(PassConfig.offerVisible(nil, MID) == true, "offer visible during the season without premium")
	ok(
		PassConfig.offerVisible({ season = "harvest1", premium = { harvest1 = true } }, MID) == false,
		"hidden once premium"
	)
	ok(
		PassConfig.offerVisible(nil, END_) == false and PassConfig.offerVisible(nil, START - 1) == false,
		"hidden outside seasons"
	)
	ok(PassConfig.utcDay(86_400 * 3 + 5) == 3 and PassConfig.utcDay(0 / 0) == 0, "utcDay")
	-- Studio clock offset (attribute) applies only in Studio.
	local studio = Loader.new({
		ReplicatedStorage = {
			Shared = Loader.node("src/shared"),
			GetAttribute = function(_self: any, name: string): any
				return if name == "NukePassClockOffset" then 86_400 else nil
			end,
		},
	})
	local StudioPass = studio.load("src/shared/Config/PassConfig")
	ok(StudioPass.clockNow(1_000) == 87_400, "Studio: clock offset applied")
	local live = Loader.new({
		ReplicatedStorage = {
			Shared = Loader.node("src/shared"),
			GetAttribute = function(): any
				return 86_400
			end,
		},
		RunService = {
			IsStudio = function()
				return false
			end,
		},
	})
	ok(live.load("src/shared/Config/PassConfig").clockNow(1_000) == 1_000, "live: the offset is ignored")
	ok(PassConfig.clockNow(1_000) == 1_000, "no attribute API → no offset")
end

-- 11. Settle / XP ordering (PassFlow) ---------------------------------------------------------------
do
	-- A buyer reached tier 3 with premium and claimed nothing; the season then ended.
	local state = seasonState()
	state.premium.harvest1 = true
	PassLogic.addXp(state, 3 * PER, "daily", MID)
	local at = END_ + 30 -- they join 30 s after the end; PolicyService has not answered yet
	ok(PassFlow.decide(state, MID, false, false) == "settled", "mid-season: nothing to settle")
	ok(PassFlow.decide(state, at, false, false) == "wait", "premium spins / eggs owed + policy unknown → wait")
	ok(PassFlow.decide(state, at, false, true) == "wait", "a settle / claim in flight → wait")
	ok(PassFlow.decide(state, at, true, false) == "now", "policy known → settle now")
	-- A quest claim fires XP during the wait: held, the state is untouched (nothing converted).
	local queue: { any } = {}
	local before = PassConfig.toSave(state)
	ok(PassFlow.hold(queue, 100, "daily", at), "XP held during the wait")
	ok(
		#queue == 1 and next(state.claimedPremium) == nil and state.xp == before.xp,
		"held XP never touches the stale state"
	)
	-- The policy answers ALLOWED: the waiting settle pays the premium spins / eggs as items.
	ok(PassFlow.decide(state, at + 5, true, false) == "now", "policy now known → the settle runs")
	local result = PassLogic.rollover(state, at + 5)
	local spinsKept, eggsKept, converted = 0, 0, 0
	for _, grant in result.grants do
		if grant.track == "premium" then
			local paid, paidSpins = PassLogic.premiumReward(grant.reward, true, LuckySpinConfig.GemsPerSpin)
			spinsKept += if paid.spins ~= nil and paidSpins then paid.spins else 0
			eggsKept += if paid.egg ~= nil then 1 else 0
			converted += if paid ~= grant.reward then 1 else 0
		end
	end
	ok(
		spinsKept == 2 and eggsKept == 1 and converted == 0,
		"allowed buyer: 2 spins + 1 egg paid as items, nothing converted to gems"
	)
	ok(#PassLogic.rollover(state, at + 6).grants == 0, "nothing left for a second settle")
	-- The held XP drains exactly once; between seasons the documented rule drops it.
	local held = PassFlow.drain(queue)
	ok(#held == 1 and #queue == 0, "held XP drained once")
	ok(#PassFlow.drain(queue) == 0, "a second drain returns nothing (never applied twice)")
	local xpBefore = state.xp
	for _, entry in held do
		ok(PassFlow.decide(state, at + 6, true, false) == "settled", "state is current before the held XP applies")
		ok(
			PassLogic.addXp(state, entry.amount, entry.source, at + 6) == 0,
			"between seasons the held XP is dropped (rule)"
		)
	end
	ok(state.xp == xpBefore, "no XP leaked into the ended season")
	-- Free-only leftovers never need the policy: settle at once even while it is unknown.
	local freeOnly = seasonState()
	PassLogic.addXp(freeOnly, 2 * PER, "daily", MID)
	ok(PassFlow.decide(freeOnly, END_ + 1, false, false) == "now", "free leftovers only → settle now")
	-- A stale state during an ACTIVE season: held XP lands in the new season after the reset.
	local stale = PassConfig.reconcileState({ season = "oldseason", xp = 3_000 })
	ok(PassFlow.decide(stale, MID, false, true) == "wait", "busy → even a plain reset waits")
	local q2: { any } = {}
	PassFlow.hold(q2, 250, "starter", MID)
	ok(PassFlow.decide(stale, MID, false, false) == "now", "a reset owes nothing → settle now once free")
	PassLogic.rollover(stale, MID)
	local applied = 0
	for _, entry in PassFlow.drain(q2) do
		applied += PassLogic.addXp(stale, entry.amount, entry.source, MID)
	end
	ok(stale.season == "harvest1" and applied == 250 and stale.xp == 250, "held XP applied once into the active season")
	-- The hold queue is bounded and refuses garbage.
	local full: { any } = {}
	for _ = 1, PassFlow.MaxHeld do
		PassFlow.hold(full, 10, "play", MID)
	end
	ok(#full == PassFlow.MaxHeld and not PassFlow.hold(full, 10, "play", MID), "hold queue bounded")
	ok(not PassFlow.hold({}, 0 / 0, "daily", MID) and not PassFlow.hold({}, 0, "daily", MID), "garbage XP never held")
end

print(`[pass-logic] OK — {checks} checks`)
