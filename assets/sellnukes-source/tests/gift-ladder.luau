--!strict
--[[
	Owner R89 Early Gift Ladder + Pocket Rocket + favorite prompt — pure rules on the shipped
	modules (spec docs/superpowers/specs/2026-10-31-r89-competitive-wave-design.md §3). Run:
		lune run tests/gift-ladder

	Proves:
	  1. Ladder config: ten gifts at 1 / 3 / 5 / 10 / 15 / 25 / 40 / 60 / 90 / 120 minutes, the
	     first inside the 2-minute churn window; deterministic rewards only (no pet / egg; spins
	     go to the free bonus bank); exactly one crate gift with fallback gems; the 10-minute gift
	     is the only favorite moment; only the last gift is big.
	  2. Ladder math: status / readyIndices at each mark, claim needs the minutes and pays once,
	     CLAIM ALL marks every ready gift in ladder order and nothing else.
	  3. Same-day carry-over: a save → reconcile round trip keeps today's seconds + claims, a
	     rejoin the same day does not reset, extrapolation unlocks the next gift.
	  4. Rollover: a new UTC day starts fresh, a clock behind never reopens, admin reset /
	     setSeconds clamp and never move the day backwards.
	  5. Migration: pre-R89 saves (ladder 1, 7 gifts) map their claims onto the 10-gift ladder by
	     minutes (never re-paying a gift); unknown versions close every reached gift; the
	     current ladder is kept; ProfileLogic.reconcile end to end.
	  6. Pocket Rocket price rule: value per Robux (income seconds AND floor) never beats any Cash
	     pack; MonetizationConfig.validate agrees; once per UTC day (refusal + late receipts).
	  7. Favorite prompt gate: announce only while unanswered with asks left, "shown" counts,
	     Success / PermissionDenied are final, Failed may come back, MaxAsks caps it.
	  8. profile.gifts block: newState / reconcileState (junk) / toWire.
]]

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local PlaytimeConfig = loader.load("src/shared/Config/PlaytimeConfig")
local GiftsConfig = loader.load("src/shared/Config/GiftsConfig")
local MonetizationConfig = loader.load("src/shared/Config/MonetizationConfig")
local CrateConfig = loader.load("src/shared/Config/CrateConfig")
local RetentionConfig = loader.load("src/shared/Config/RetentionConfig")
local PlaytimeLogic = loader.load("src/server/Retention/PlaytimeLogic")
local GiftsLogic = loader.load("src/server/Retention/GiftsLogic")
local ProfileLogic = loader.load("src/server/Economy/ProfileLogic")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

-- Sorted keys of a numeric set ({ [3] = true, [1] = true } → { 1, 3 }).
local function keys(set: { [number]: any }): { number }
	local list: { number } = {}
	for key in set do
		table.insert(list, key)
	end
	table.sort(list)
	return list
end

local function sameList(a: { number }, b: { number }): boolean
	if #a ~= #b then
		return false
	end
	for index, value in a do
		if b[index] ~= value then
			return false
		end
	end
	return true
end

-- 1. Ladder config -------------------------------------------------------------------------------
local MINUTES = { 1, 3, 5, 10, 15, 25, 40, 60, 90, 120 }
local gifts = PlaytimeConfig.Gifts
check(#gifts == #MINUTES, "ten gifts")
check(gifts[1].minutes <= 2, "first gift inside the 2-minute churn window")
local crateGifts, moments = 0, 0
for index, gift in gifts do
	check(gift.index == index and gift.minutes == MINUTES[index], `gift {index} at {MINUTES[index]} min`)
	check(index == 1 or gift.minutes > gifts[index - 1].minutes, `gift {index} later than the one before`)
	check(RetentionConfig.isRewardValid(gift.reward), `gift {index} reward valid`)
	check(gift.reward.pet == nil and gift.reward.egg == nil, `gift {index}: no random item rewards`)
	check(gift.big == (index == #gifts), `only the last gift is big ({index})`)
	if gift.crate ~= nil then
		crateGifts += 1
		check(CrateConfig.get(gift.crate.id) ~= nil, `gift {index}: crate {gift.crate.id} exists`)
		check(gift.crate.count == 1 and gift.crate.fallbackGems > 0, `gift {index}: one crate + fallback gems`)
	end
	if gift.favoriteMoment then
		moments += 1
		check(gift.minutes == 10, "the favorite moment is the 10-minute gift")
	end
	check(table.isfrozen(gift) and table.isfrozen(gift.reward), `gift {index} frozen`)
end
check(crateGifts == 1, "exactly one crate gift")
check(moments == 1, "exactly one favorite-moment gift")
check(PlaytimeConfig.giftAt(10) == gifts[4] and PlaytimeConfig.giftAt(11) == nil, "giftAt")

-- 2. Ladder math ---------------------------------------------------------------------------------
local DAY = 20_757
local state = { day = DAY, seconds = 0, claimed = {}, ladder = PlaytimeConfig.LadderVersion }
check(#PlaytimeConfig.readyIndices(state, DAY) == 0, "nothing ready at 0 s")
check(PlaytimeLogic.claim(state, 1, DAY) == "locked", "gift 1 locked at 0 s")
for index, minutes in MINUTES do
	local probe = { day = DAY, seconds = minutes * 60, claimed = {} }
	check(#PlaytimeConfig.readyIndices(probe, DAY) == index, `{index} gifts ready at {minutes} min`)
	local almost = { day = DAY, seconds = minutes * 60 - 1, claimed = {} }
	check(#PlaytimeConfig.readyIndices(almost, DAY) == index - 1, `gift {index} not ready 1 s early`)
	check(PlaytimeConfig.status(almost, DAY)[index].secondsLeft == 1, `gift {index}: 1 s left`)
end
state.seconds = 5 * 60
check(PlaytimeLogic.claim(state, 2, DAY) == "ok", "claim gift 2 at 5 min")
check(sameList(PlaytimeConfig.readyIndices(state, DAY), { 1, 3 }), "ready = reached minus claimed")
local opened = PlaytimeLogic.claimAll(state, DAY)
check(sameList(opened, { 1, 3 }), "CLAIM ALL opens every ready gift in order")
check(sameList(keys(state.claimed), { 1, 2, 3 }), "CLAIM ALL marks them")
check(#PlaytimeLogic.claimAll(state, DAY) == 0, "CLAIM ALL again opens nothing")
check(PlaytimeLogic.claim(state, 3, DAY) == "claimed", "a gift opened by CLAIM ALL is claimed")
check(PlaytimeLogic.claim(state, 4, DAY) == "locked", "gift 4 still needs 10 min")
check(#PlaytimeLogic.claimAll(state, DAY - 1) == 0 and state.day == DAY, "CLAIM ALL with a clock behind: nothing")

-- 3. Same-day carry-over -------------------------------------------------------------------------
local profile = ProfileLogic.defaultProfile()
profile.timeRewards.day, profile.timeRewards.seconds = DAY, 15 * 60
profile.timeRewards.claimed[1], profile.timeRewards.claimed[2] = true, true
local reloaded = ProfileLogic.reconcile(ProfileLogic.toSave(profile))
check(reloaded.timeRewards.day == DAY and reloaded.timeRewards.seconds == 900, "seconds survive a rejoin")
check(sameList(keys(reloaded.timeRewards.claimed), { 1, 2 }), "claims survive a rejoin")
check(reloaded.timeRewards.ladder == PlaytimeConfig.LadderVersion, "saved ladder version kept")
check(not PlaytimeLogic.rollover(reloaded.timeRewards, DAY), "a same-day rejoin never rolls over")
check(sameList(PlaytimeConfig.readyIndices(reloaded.timeRewards, DAY), { 3, 4, 5 }), "15 min: gifts 3-5 ready")
check(PlaytimeConfig.status(reloaded.timeRewards, DAY, 600)[6].state == "ready", "extrapolation: 25-min gift")
local snapshot = ProfileLogic.snapshot(reloaded, { saveStatus = "ok" } :: any, { "timeRewards" })
check(sameList(snapshot.timeRewards.claimed, { 1, 2 }), "snapshot sends claims as an array")
check(PlaytimeConfig.isClaimed(snapshot.timeRewards, 2, DAY), "client reads the array form")

-- 4. Rollover ------------------------------------------------------------------------------------
local roll = { day = DAY, seconds = 4_000, claimed = { [1] = true, [2] = true } }
check(not PlaytimeLogic.rollover(roll, DAY - 3) and roll.seconds == 4_000, "clock behind: no reset")
check(PlaytimeLogic.accrue(roll, 1, DAY - 3) == 0, "clock behind: no credit")
check(PlaytimeLogic.rollover(roll, DAY + 1) and roll.seconds == 0 and next(roll.claimed) == nil, "new day fresh")
check(PlaytimeConfig.status({ day = DAY, seconds = 99_999, claimed = { 1 } }, DAY + 1)[1].state == "locked", "stale")
check(PlaytimeLogic.setSeconds(roll, 1e12, DAY + 1) == PlaytimeConfig.MaxSecondsPerDay, "setSeconds caps a day")
check(PlaytimeLogic.setSeconds(roll, -5, DAY + 1) == 0, "setSeconds floors at 0")
check(PlaytimeLogic.setSeconds(roll, 0 / 0, DAY + 1) == nil, "setSeconds refuses NaN")
roll.claimed[4] = true
check(PlaytimeLogic.reset(roll, DAY + 1) and next(roll.claimed) == nil and roll.seconds == 0, "admin reset today")
check(not PlaytimeLogic.reset(roll, DAY) and roll.day == DAY + 1, "admin reset never moves the day back")

-- 5. Migration -----------------------------------------------------------------------------------
check(sameList(keys(PlaytimeConfig.migrateClaimed(1, { [1] = true }, 300)), { 1, 2, 3 }), "old 5-min → 1/3/5")
check(sameList(keys(PlaytimeConfig.migrateClaimed(1, { [2] = true }, 960)), { 1, 2, 3, 4, 5 }), "old 15 → ≤15")
check(
	sameList(keys(PlaytimeConfig.migrateClaimed(1, { [1] = true, [3] = true }, 1_900)), { 1, 2, 3, 4, 5, 6 }),
	"old 30-min → every gift ≤ 25 min"
)
check(#keys(PlaytimeConfig.migrateClaimed(1, { [7] = true }, 10_800)) == #gifts, "old 180-min → all closed")
check(next(PlaytimeConfig.migrateClaimed(1, {}, 2_000)) == nil, "old ladder, nothing claimed → all open")
check(
	sameList(keys(PlaytimeConfig.migrateClaimed(2, { [3] = true, [99] = true }, 0)), { 3 }),
	"current ladder kept (out of range dropped)"
)
check(sameList(keys(PlaytimeConfig.migrateClaimed(7, {}, 700)), { 1, 2, 3, 4 }), "unknown ladder: reached closed")
local legacy = ProfileLogic.toSave(ProfileLogic.defaultProfile())
legacy.timeRewards = { day = DAY, seconds = 20 * 60, claimed = { 1, 2 } } -- pre-R89: no ladder field
local migrated = ProfileLogic.reconcile(legacy)
check(migrated.timeRewards.ladder == PlaytimeConfig.LadderVersion, "reconcile stamps the current ladder")
check(sameList(keys(migrated.timeRewards.claimed), { 1, 2, 3, 4, 5 }), "reconcile maps old claims (15 min)")
check(migrated.timeRewards.seconds == 1_200, "reconcile keeps today's playtime")
check(sameList(PlaytimeConfig.readyIndices(migrated.timeRewards, DAY), {}), "migrated: nothing re-paid at 20 min")
check(
	sameList(keys(ProfileLogic.reconcile(ProfileLogic.toSave(migrated)).timeRewards.claimed), { 1, 2, 3, 4, 5 }),
	"a migrated save reloads unchanged"
)

-- 6. Pocket Rocket price rule --------------------------------------------------------------------
local rocket = MonetizationConfig.getProduct("PocketRocket")
check(rocket ~= nil and rocket.kind == "PocketRocket", "PocketRocket product, kind PocketRocket")
check(rocket.incomeSeconds == 300 and rocket.cashFloor == 500 and rocket.price == 15, "5 min, $500 floor, 15 R$")
check(not rocket.paidRandom and not rocket.oneTime, "fixed reward, repeatable (once per day by profile)")
local rocketSeconds, rocketFloor = GiftsConfig.valuePerRobux(rocket)
local packs = 0
for _, key in MonetizationConfig.ProductOrder do
	local def = MonetizationConfig.Products[key]
	if def.kind == "Cash" then
		packs += 1
		local packSeconds, packFloor = GiftsConfig.valuePerRobux(def)
		check(rocketSeconds <= packSeconds, `rocket {rocketSeconds} s/R$ <= {key} {packSeconds} s/R$`)
		check(rocketFloor <= packFloor, `rocket floor {rocketFloor} $/R$ <= {key} {packFloor} $/R$`)
	end
end
check(packs == 4, "four Cash packs compared")
check(#GiftsConfig.rocketBeatsCashPacks() == 0, "rocketBeatsCashPacks: none")
for _, problem in MonetizationConfig.validate() do
	check(string.find(problem, "PocketRocket", 1, true) == nil, `validate: {problem}`)
end
-- The rule really bites: a 5-minute rocket at 9 R$ (33 s/R$) would beat the 23 R$ Stack of Cash.
local cheapSeconds = GiftsConfig.valuePerRobux({ price = 9, incomeSeconds = 300, cashFloor = 500 } :: any)
local smallSeconds = GiftsConfig.valuePerRobux(MonetizationConfig.getProduct("CashSmall"))
check(cheapSeconds > smallSeconds, "a cheaper rocket would be flagged")
local reward = GiftsConfig.rocketReward()
check(reward.cashSeconds == 300 and reward.cashFloor == 500, "rocketReward mirrors the product row")
check(RetentionConfig.isRewardValid(reward), "rocketReward is a valid Reward")
local gs = GiftsConfig.newState()
check(GiftsLogic.promptRefusal(gs, DAY) == nil, "rocket available on a fresh day")
check(GiftsLogic.markRocket(gs, DAY) and gs.rocketDay == DAY, "grant stamps today")
check(GiftsLogic.promptRefusal(gs, DAY) == GiftsLogic.RocketUsedText, "second prompt the same day refused")
check(GiftsConfig.rocketBoughtToday(gs, DAY) and not GiftsConfig.rocketBoughtToday(gs, DAY + 1), "bought today")
check(GiftsLogic.promptRefusal(gs, DAY + 1) == nil, "back after UTC midnight")
check(not GiftsLogic.markRocket(gs, DAY - 1) and gs.rocketDay == DAY, "a clock behind never moves the day back")
check(GiftsLogic.markRocket(gs, DAY), "a late receipt the same day still stamps (grant happens)")
check(GiftsLogic.promptRefusal(gs, 0 / 0) ~= nil, "junk day refused")
check(not GiftsConfig.rocketBoughtToday(nil, DAY) and not GiftsConfig.rocketBoughtToday({}, DAY), "junk = not bought")

check(type(GiftsConfig.RocketEnabled) == "boolean", "Pocket Rocket kill switch exists")
check(type(GiftsConfig.FavoriteEnabled) == "boolean", "favorite prompt kill switch exists")

-- 7. Favorite prompt gate ------------------------------------------------------------------------
local Fav = GiftsConfig.FavoriteState
local f = GiftsConfig.newState()
check(GiftsLogic.mayAnnounce(f), "fresh: may announce")
check(GiftsLogic.markAnswered(f, "Success") == nil, "an answer without a shown dialog is refused")
check(GiftsLogic.markShown(f) and f.favoriteAsks == 1 and f.favorite == Fav.Shown, "shown counts")
check(GiftsLogic.markAnswered(f, "Failed") == Fav.Shown, "Failed is not an answer")
check(GiftsLogic.mayAnnounce(f), "after Failed: a later moment may ask again")
check(GiftsLogic.markAnswered(f, "Bogus") == nil, "unknown result refused")
check(GiftsLogic.markShown(f) and f.favoriteAsks == 2, "second showing")
check(not GiftsLogic.mayAnnounce(f), "MaxAsks reached: never again")
check(not GiftsLogic.markShown(f) and f.favoriteAsks == 2, "a third shown report is ignored")
check(GiftsLogic.markAnswered(f, "PermissionDenied") == Fav.Answered, "dismissed = answered")
local g = GiftsConfig.newState()
GiftsLogic.markShown(g)
check(GiftsLogic.markAnswered(g, "Success") == Fav.Answered, "favorited = answered")
check(not GiftsLogic.mayAnnounce(g) and not GiftsLogic.markShown(g), "answered: never prompted again")
check(GiftsLogic.markAnswered(g, "Failed") == nil, "answered is final")
check(GiftsConfig.Favorite.MaxAsks == 2, "at most two showings ever")

-- 8. profile.gifts block -------------------------------------------------------------------------
local fresh = GiftsConfig.reconcileState(nil)
check(fresh.rocketDay == -1 and fresh.favorite == 0 and fresh.favoriteAsks == 0, "missing → newState")
local junk = GiftsConfig.reconcileState({ rocketDay = 1.5, favorite = 9, favoriteAsks = -1 })
check(junk.rocketDay == -1 and junk.favorite == 0 and junk.favoriteAsks == 0, "junk → defaults")
local kept = GiftsConfig.reconcileState({ rocketDay = DAY, favorite = 2, favoriteAsks = 1 })
check(kept.rocketDay == DAY and kept.favorite == 2 and kept.favoriteAsks == 1, "valid values kept")
local wire = GiftsConfig.toWire(kept)
check(wire.rocketDay == DAY and wire.favorite == 2 and (wire :: any).favoriteAsks == nil, "toWire")
local p2 = ProfileLogic.defaultProfile()
p2.gifts.rocketDay, p2.gifts.favorite, p2.gifts.favoriteAsks = DAY, 1, 1
local p3 = ProfileLogic.reconcile(ProfileLogic.toSave(p2))
check(p3.gifts.rocketDay == DAY and p3.gifts.favorite == 1 and p3.gifts.favoriteAsks == 1, "gifts round trip")
check(table.find(ProfileLogic.SnapshotFields, "gifts") ~= nil, "gifts is a snapshot field")
local pre = ProfileLogic.toSave(ProfileLogic.defaultProfile())
pre.gifts = nil
check(ProfileLogic.reconcile(pre).gifts.rocketDay == -1, "pre-R89 save → fresh gifts block")

print(`[gift-ladder] {checks} checks passed`)
