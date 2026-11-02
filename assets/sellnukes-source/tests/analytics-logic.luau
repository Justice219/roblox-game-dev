--!strict
--[[
	Analytics pure-logic regressions (lune run tests/analytics-logic). Loads the REAL modules.

	Proves:
	  1. AnalyticsLogic keys: sanitized parts, length caps, day / month math and DataStore key names.
	  2. Counters: cardinality cap → "_other", non-finite amounts ignored, overflow clamped at
	     MaxCounterValue, mergeStored is a PURE transform (a retried UpdateAsync never double-counts),
	     readCounters drops malformed stored data.
	  3. Range planning (today / 7d / all with month compaction, cohort days for retention).
	  4. Buckets: bucketOf / bucketLabels / countBucket / countBucketLabels agree; session / dwell.
	  5. Client validators: offersSeen caps + allowlists, screenOpen allowlist, R137 offerClick
	     (offer sources only, typeof / length / id allowlist, double-tap merge, per-session cap).
	  6. AnalyticsMarks: reconcile of hostile stored data, unique-per-day, cohort / milestones,
	     funnel bits, ensure() in place (outbox untouched), furthestStep.
	  7. ReturnTags + ReceiptAccounting (read validation, payer bitmap, finalize, counters).
	  8. ServerHealthLogic: diff, counters (laggy minute), rows.
	  9. Config sanity: every recorder pattern compiles, every FTUE / milestone / surface list fits
	     its bitmask.
]]

local Loader = require("./analytics-fixtures/Loader")
local env = Loader.new()
local check, done = Loader.checker()

local AnalyticsConfig = env.load("src/shared/Config/AnalyticsConfig")
local AnalyticsMarks = env.load("src/shared/Config/AnalyticsMarks")
local AnalyticsLogic = env.load("src/server/Analytics/AnalyticsLogic")
local ReturnTags = env.load("src/server/Analytics/ReturnTags")
local ReceiptAccounting = env.load("src/server/Analytics/ReceiptAccounting")
local ServerHealthLogic = env.load("src/server/Analytics/ServerHealthLogic")

-- 1. Keys and days -------------------------------------------------------------------------------
check(AnalyticsLogic.part("a1 workbench!") == "a1_workbench_", "part sanitizes")
check(#AnalyticsLogic.part(string.rep("x", 80)) == AnalyticsConfig.MaxKeyPart, "part capped")
check(AnalyticsLogic.part("") == "_", "empty part")
check(AnalyticsLogic.key("pad", "a1_workbench") == "pad:a1_workbench", "key joins")
check(
	#AnalyticsLogic.key(string.rep("a", 40), string.rep("b", 40), string.rep("c", 40)) <= AnalyticsConfig.MaxKeyLength,
	"key capped"
)
local day = AnalyticsLogic.dayNumber(1793318400) -- 2026-10-30 00:00 UTC
check(AnalyticsLogic.dayString(day) == "2026-10-30", "dayString")
check(AnalyticsLogic.monthOf(day) == "2026-10", "monthOf")
local first, last = AnalyticsLogic.monthBounds(day)
check(AnalyticsLogic.dayString(first) == "2026-10-01" and AnalyticsLogic.dayString(last) == "2026-10-31", "monthBounds")
check(AnalyticsLogic.familyKey(day, "tycoon", 0) == "d:2026-10-30:tycoon:0", "familyKey")
check(AnalyticsLogic.compactDayKey(day) == "c:2026-10-30", "compactDayKey")
check(AnalyticsLogic.shardFor("", 4) == 0 and AnalyticsLogic.shardFor("abc", 1) == 0, "shardFor bounds")

-- 2. Counters ----------------------------------------------------------------------------------------
do
	local counters = {}
	AnalyticsLogic.add(counters, "a", 1)
	AnalyticsLogic.add(counters, "a", 0 / 0)
	AnalyticsLogic.add(counters, "a", math.huge)
	AnalyticsLogic.add(counters, "a", 0)
	check(counters.a == 1, "non-finite / zero ignored")
	AnalyticsLogic.add(counters, "big", 1e300)
	AnalyticsLogic.add(counters, "big", 1e300)
	check(counters.big == AnalyticsConfig.MaxCounterValue, "overflow clamped")
	local capped = {}
	for index = 1, AnalyticsConfig.MaxKeysPerFamily + 5 do
		AnalyticsLogic.add(capped, `k{index}`, 1)
	end
	local n = 0
	for _ in capped do
		n += 1
	end
	check(n == AnalyticsConfig.MaxKeysPerFamily + 1, "cardinality cap + _other")
	check(capped._other == 5, "overflow folded into _other")

	-- Pure transform: retrying the same UpdateAsync transform gives the same stored value.
	local old = { v = 1, c = { x = 2 } }
	local a = AnalyticsLogic.mergeStored(old, { x = 3, y = 1 })
	local b = AnalyticsLogic.mergeStored(old, { x = 3, y = 1 })
	check(a.c.x == 5 and b.c.x == 5 and a.c.y == 1 and old.c.x == 2, "mergeStored is pure")
	local read = AnalyticsLogic.readCounters({ ok = 1, bad = "x", [5] = 2, nan = 0 / 0, [string.rep("z", 100)] = 1 })
	check(
		read.ok == 1 and read.bad == nil and read.nan == nil and next(read, next(read)) == nil,
		"readCounters drops junk"
	)
	check(next(AnalyticsLogic.readStored("garbage")) == nil, "readStored of junk")

	local pending = {}
	AnalyticsLogic.record(pending, day, "tycoon", "pad:a1_workbench", 1)
	AnalyticsLogic.record(pending, day, "tycoon", "pad:a1_workbench", 2)
	check(pending[day].tycoon["pad:a1_workbench"] == 3, "record accumulates")
	local families = { core = { dau = 3 } }
	AnalyticsLogic.mergeFamilies(families, { core = { dau = 2, new = 1 }, tycoon = { clicks = 4 } })
	check(families.core.dau == 5 and families.core.new == 1 and families.tycoon.clicks == 4, "mergeFamilies")

	local compact = AnalyticsLogic.compactDay(day, { core = { dau = 1 } })
	local back = AnalyticsLogic.readFamilies(compact)
	check(back ~= nil and back.core.dau == 1 and back.health ~= nil, "compact day roundtrip")
	check(AnalyticsLogic.readFamilies({ f = "x" }) == nil, "readFamilies rejects junk")
	local series = AnalyticsLogic.seriesOf({
		core = { dau = 4, new = 2, ["devNew:phone"] = 1, ["cohort:all"] = 2, ["r1:area2"] = 1 },
		revenue = { robux = 50 },
		tycoon = { ["padKind:Build"] = 3, ["padKind:Manager"] = 1 },
	})
	check(series.dau == 4 and series.pads == 4 and series.robux == 50, "seriesOf")
	check(series.devNew ~= nil and series.devNew.phone == 1, "seriesOf device map")
	check(
		series.msCohort ~= nil and series.msCohort.all == 2 and series.msR1 ~= nil and series.msR1.area2 == 1,
		"seriesOf milestone maps"
	)
	local month = AnalyticsLogic.compactMonth("2026-10", { core = { dau = 1 } }, { [day] = series })
	local days = AnalyticsLogic.readMonthDays(month)
	check(days[day] ~= nil and days[day].pads == 4 and days[day].msCohort.all == 2, "month series roundtrip")
	check(AnalyticsLogic.readMeta({ firstDay = 20000 }) == 20000 and AnalyticsLogic.readMeta({}) == nil, "readMeta")
end

-- 3. Plan -------------------------------------------------------------------------------------------
do
	local today = day
	local p1 = AnalyticsLogic.plan("today", today, today - 100)
	check(#p1.days == 1 and p1.days[1] == today and #p1.months == 0, "plan today")
	check(
		table.find(p1.cohortDays, today - 1) ~= nil and table.find(p1.cohortDays, today - 30) ~= nil,
		"plan cohort days"
	)
	local p7 = AnalyticsLogic.plan("7d", today, today - 3)
	check(p7.from == today - 6 and #p7.days == 4, "plan 7d clipped to the start day")
	local all = AnalyticsLogic.plan("all", today, today - 90)
	check(#all.months >= 2, "plan all uses compact months")
	local covered = 0
	for _, ref in all.months do
		local mFirst, mLast = AnalyticsLogic.monthBounds(ref.day)
		covered += mLast - math.max(mFirst, today - 90) + 1
	end
	check(covered + #all.days == 91, "plan all covers every day once")
end

-- 4. Buckets -------------------------------------------------------------------------------------------
do
	check(AnalyticsLogic.bucketOf(7, { 5, 10 }, "m") == "5-10m", "bucketOf middle")
	check(AnalyticsLogic.bucketOf(1, { 5, 10 }, "m") == "<5m", "bucketOf first")
	check(AnalyticsLogic.bucketOf(99, { 5, 10 }, "m") == "10m+", "bucketOf open")
	local labels = AnalyticsLogic.bucketLabels({ 5, 10 }, "m")
	check(#labels == 3 and labels[1] == "<5m" and labels[3] == "10m+", "bucketLabels")
	for _, value in { 0, 1, 2, 3, 4, 5, 6, 9, 10, 11, 20, 21, 500 } do
		local label = AnalyticsLogic.countBucket(value, AnalyticsConfig.SessionNumberBuckets)
		check(
			table.find(AnalyticsLogic.countBucketLabels(AnalyticsConfig.SessionNumberBuckets), label) ~= nil,
			`countBucket {value} → {label} is a listed label`
		)
	end
	check(AnalyticsLogic.countBucket(1, AnalyticsConfig.SessionNumberBuckets) == "1", "session #1")
	check(AnalyticsLogic.countBucket(5, AnalyticsConfig.SessionNumberBuckets) == "4-5", "session #5")
	check(AnalyticsLogic.countBucket(0, AnalyticsConfig.Pets.OwnedBuckets) == "0", "owned 0")
	check(AnalyticsLogic.countBucket(2, AnalyticsConfig.Pets.OwnedBuckets) == "1-2", "owned 2")
	local seen = {}
	for _, label in AnalyticsLogic.countBucketLabels(AnalyticsConfig.Pets.OwnedBuckets) do
		check(not seen[label], `unique owned label {label}`)
		seen[label] = true
	end
	check(AnalyticsLogic.sessionBucket(30) == "<2m" and AnalyticsLogic.sessionBucket(9000) == "120m+", "sessionBucket")
	check(
		AnalyticsLogic.dwellBucket(1) == "lt2"
			and AnalyticsLogic.dwellBucket(5) == "2to10"
			and AnalyticsLogic.dwellBucket(60) == "gt10",
		"dwell"
	)
	check(
		AnalyticsLogic.integerIn(3, 1, 7) == 3
			and AnalyticsLogic.integerIn(2.5, 1, 7) == nil
			and AnalyticsLogic.integerIn(0 / 0, 1, 7) == nil,
		"integerIn"
	)
	check(
		AnalyticsLogic.medianOf({ ["len:<2m"] = 1, ["len:2-5m"] = 3 }, "len:", { "<2m", "2-5m" }, { 1, 3.5 }) == 3.5,
		"medianOf"
	)
	check(AnalyticsLogic.medianOf({}, "len:", { "<2m" }, { 1 }) == -1, "medianOf empty")
end

-- 5. Client validators ---------------------------------------------------------------------------------
do
	local state = AnalyticsLogic.newOffersSeen()
	local isOffer = function(id: string): boolean
		return id == "VIP" or id == "StarterPack"
	end
	local keys = AnalyticsLogic.offersSeen(state, "starburst", { "VIP", "VIP", "<x>", "StarterPack" }, true, isOffer)
	check(#keys == 3 and keys[1] == "offers:open:starburst", "offersSeen new visit counts open + unique cards")
	keys = AnalyticsLogic.offersSeen(state, "starburst", { "VIP" }, false, isOffer)
	check(#keys == 0, "same visit: a card counts once per visit")
	keys = AnalyticsLogic.offersSeen(state, "hacker", { "VIP" }, true, isOffer)
	check(keys[1] == "offers:open:other" and keys[2] == "offers:card:VIP", "unknown source → other")
	check(#AnalyticsLogic.offersSeen(state, "shop", { "VIP" }, "yes", isOffer) == 0, "invalid newVisit")
	check(#AnalyticsLogic.offersSeen(state, "shop", "VIP", true, isOffer) == 1, "non-table cards: only the open")
	local capped = AnalyticsLogic.newOffersSeen()
	capped.opens = AnalyticsConfig.OffersSeen.MaxOpens
	check(#AnalyticsLogic.offersSeen(capped, "shop", { "VIP" }, true, isOffer) == 0, "open cap")

	-- R137 offer BUY presses (AnalyticsLogic.offerClick).
	local clickConfig = AnalyticsConfig.OfferClicks
	for _, source in clickConfig.Sources do
		check(
			table.find(AnalyticsConfig.PromptSources, source) ~= nil,
			`offer click source {source} is a MonetizationService prompt source (never folded to "other")`
		)
		check(AnalyticsLogic.isOfferClickSource(source), `isOfferClickSource({source})`)
	end
	check(
		not AnalyticsLogic.isOfferClickSource("pad")
			and not AnalyticsLogic.isOfferClickSource("lucky")
			and not AnalyticsLogic.isOfferClickSource(nil)
			and not AnalyticsLogic.isOfferClickSource(5),
		"isOfferClickSource: non-offer / non-string sources"
	)
	local clicks = AnalyticsLogic.newOffersSeen()
	check(clicks.clicks == 0 and next(clicks.clickAt) == nil, "fresh click state")
	local id, reason = AnalyticsLogic.offerClick(clicks, "VIP", "shop", 100, isOffer)
	check(id == "VIP" and reason == nil and clicks.clicks == 1, "offer press counted")
	id, reason = AnalyticsLogic.offerClick(clicks, "VIP", "offer", 100 + clickConfig.RepeatSeconds / 2, isOffer)
	check(id == nil and reason == nil and clicks.clicks == 1, "double tap on the same offer merged (not a refusal)")
	id = AnalyticsLogic.offerClick(clicks, "StarterPack", "welcomeBack", 100.1, isOffer)
	check(id == "StarterPack" and clicks.clicks == 2, "another offer inside the window still counts")
	id = AnalyticsLogic.offerClick(clicks, "VIP", "offer", 100 + clickConfig.RepeatSeconds, isOffer)
	check(id == "VIP" and clicks.clicks == 3, "same offer again after RepeatSeconds counts")
	id, reason = AnalyticsLogic.offerClick(clicks, "VIP", "pad", 200, isOffer)
	check(id == nil and reason == nil, "non-offer source: not an offer press, not a refusal")
	id, reason = AnalyticsLogic.offerClick(clicks, "VIP", { "shop" }, 200, isOffer)
	check(id == nil and reason == nil, "non-string source ignored")
	for _, raw in { 5, {}, "", string.rep("V", AnalyticsConfig.ClientSourceMaxLength + 1), true } do
		id, reason = AnalyticsLogic.offerClick(clicks, raw, "shop", 300, isOffer)
		check(id == nil and reason == "malformed", `malformed offer id refused ({typeof(raw)})`)
	end
	id, reason = AnalyticsLogic.offerClick(clicks, "<x>", "shop", 300, isOffer)
	check(id == nil and reason == "unknown", "unknown offer id refused")
	check(clicks.clicks == 3 and clicks.clickAt["<x>"] == nil, "refusals never mutate the state")
	clicks.clicks = clickConfig.MaxPerSession
	id, reason = AnalyticsLogic.offerClick(clicks, "StarterPack", "shop", 400, isOffer)
	check(id == nil and reason == "cap" and clicks.clicks == clickConfig.MaxPerSession, "per-session click cap")
	local open = AnalyticsLogic.screenOpen("Shop", "hud")
	check(open ~= nil and open[1] == "open:Shop" and open[2] == "openFrom:Shop:hud", "screenOpen")
	check(AnalyticsLogic.screenOpen("Shop", "x")[2] == "openFrom:Shop:other", "screen source folded")
	check(AnalyticsLogic.screenOpen("Defense", "hud") ~= nil, "Defense screen (B10)")
	check(
		AnalyticsLogic.screenOpen("NotAScreen", "hud") == nil and AnalyticsLogic.screenOpen(5, "hud") == nil,
		"screen allowlist"
	)
end

-- 6. AnalyticsMarks --------------------------------------------------------------------------------------
do
	local data = AnalyticsMarks.reconcileAnalytics({
		first = 20380,
		last = -5,
		seen = 3.7,
		marks = 2 ^ 40,
		staff = "yes",
		play = 0 / 0,
		runAt = 99,
		payDays = { ["10"] = 5, ["x"] = 1, ["99999"] = 1, ["11"] = -1, ["-0"] = 1, ["1e2"] = 1, ["007"] = 1 },
		outbox = { p1 = { robux = 5 } },
	})
	check(data.first == 20380 and data.last == 0 and data.seen == 3, "reconcile numbers")
	check(data.staff == false and data.play == 0 and data.runAt == 0, "reconcile clamps runAt ≤ play")
	check(
		data.payDays["10"] == 5 and data.payDays.x == nil and data.payDays["99999"] == nil and data.payDays["11"] == nil,
		"payDays bounded"
	)
	check(
		data.payDays["-0"] == nil and data.payDays["1e2"] == nil and data.payDays["007"] == nil,
		"payDays: canonical digit keys only"
	)
	check(data.outbox.p1.robux == 5, "outbox passed through")
	check(data.marks == 0, "marks masked to known bits")

	local fresh = AnalyticsMarks.newAnalytics()
	check(
		AnalyticsMarks.markSeen(fresh, 100, "shop") and not AnalyticsMarks.markSeen(fresh, 100, "shop"),
		"markSeen once a day"
	)
	check(AnalyticsMarks.markSeen(fresh, 101, "shop"), "markSeen new day")
	check(not AnalyticsMarks.markSeen(fresh, 101, "nope"), "unknown surface")
	check(not AnalyticsMarks.markMilestone(fresh, "area2"), "untracked profile records no milestone")
	check(not AnalyticsMarks.markFtue(fresh, "firstPad"), "untracked profile: no funnel")
	check(AnalyticsMarks.startCohort(fresh) and not AnalyticsMarks.startCohort(fresh), "startCohort once")
	check(
		AnalyticsMarks.markMilestone(fresh, "area2") and not AnalyticsMarks.markMilestone(fresh, "area2"),
		"milestone once"
	)
	check(AnalyticsMarks.markMilestone(fresh, "hatch"), "second milestone")
	local ms = AnalyticsMarks.milestonesOf(fresh)
	check(#ms == 2 and ms[1] == "area2" and ms[2] == "hatch", "milestonesOf in config order")
	check(AnalyticsMarks.markFtue(fresh, "firstPad") and not AnalyticsMarks.markFtue(fresh, "firstPad"), "ftue once")
	check(AnalyticsMarks.hasFtue(fresh, "firstPad") and not AnalyticsMarks.hasFtue(fresh, "manager"), "hasFtue")
	check(
		AnalyticsMarks.furthestStep({ joined = true, firstPad = true, hudShown = true }) == "firstPad",
		"furthestStep ignores side step"
	)
	check(AnalyticsMarks.furthestStep({}) == "none", "furthestStep none")
	check(
		AnalyticsMarks.returnKeyAt(7, "area2") == "r7:area2" and AnalyticsMarks.cohortKey("all") == "cohort:all",
		"keys"
	)

	local raw: any = { first = 5, outbox = { keep = { a = 1 } }, junk = true }
	local outbox = raw.outbox
	local ensured = AnalyticsMarks.ensure(raw)
	check(
		ensured == raw and raw.outbox == outbox and raw.sessions == 0 and raw.first == 5,
		"ensure in place keeps outbox"
	)
	local map = AnalyticsMarks.milestoneMap({ ["cohort:all"] = 3, ["cohort:x"] = 9 }, "cohort:")
	check(map ~= nil and map.all == 3 and map.x == nil, "milestoneMap bounded")
	check(AnalyticsMarks.readMilestoneMap({ all = 0 / 0, hatch = 2 }).hatch == 2, "readMilestoneMap")
end

-- 7. ReturnTags + ReceiptAccounting --------------------------------------------------------------------------
do
	check(ReturnTags.tagFor("flush", true) == "carry", "flush is always carry")
	check(ReturnTags.tagFor("load", true) == "notify" and ReturnTags.tagFor("load", false) == nil, "load tags")
	check(ReturnTags.carryMarkerAction(0, 10, false) == "none", "no marker")
	check(ReturnTags.carryMarkerAction(10, 10, false) == "rejoin", "today's marker")
	check(ReturnTags.carryMarkerAction(9, 10, false) == "clear", "stale marker")
	check(ReturnTags.carryMarkerAction(10, 10, true) == "keep", "server hop keeps")

	local record = {
		day = 20380,
		userId = 7,
		productId = 123,
		product = "GemsSmall",
		kind = "Gems",
		robux = 49,
		source = "shop",
		device = "phone",
		area = 3,
		rebirths = 4,
		staff = false,
		payEligible = true,
		ready = false,
		gems = 0,
	}
	check(ReceiptAccounting.read(record) ~= nil, "valid record reads")
	local bad = table.clone(record)
	bad.robux = -1
	check(ReceiptAccounting.read(bad) == nil, "negative robux rejected")
	bad = table.clone(record)
	bad.product = "has space"
	check(ReceiptAccounting.read(bad) == nil, "free text rejected")
	local marks = { payFirst = 0, payLast = 0, payDays = {} }
	local copy = ReceiptAccounting.read(record)
	ReceiptAccounting.finalize(copy, marks, 250)
	check(copy.ready and copy.payer == true and copy.newPayer == true and copy.gems == 250, "finalize payer facts")
	check(marks.payFirst == 20380 and marks.payLast == 20380, "finalize marks")
	local again = ReceiptAccounting.read(record)
	ReceiptAccounting.finalize(again, marks, nil)
	check(again.payer == false and again.newPayer == false, "second receipt same day: no new payer-day")
	local counters = ReceiptAccounting.counters(copy)
	check(counters.revenue.robux == 49 and counters.revenue["product:GemsSmall:robux"] == 49, "counters robux")
	check(
		counters.revenue["robuxByArea:3"] == 49 and counters.revenue["robuxByRebirth:4-5"] == 49,
		"counters area / rebirth tier"
	)
	check(counters.revenue["firstBuy:GemsSmall"] == 1 and counters.core.payers == 1, "counters first buy + payer")
	check(counters.economy["earn:gems:robux:GemsSmall"] == 250, "gems from Robux")
	local staff = ReceiptAccounting.read(record)
	staff.staff = true
	staff.ready = true
	check(ReceiptAccounting.counters(staff).revenue.robux == nil, "staff receipts never count as revenue")
	check(ReceiptAccounting.markPayerDay({ payFirst = 0, payLast = 0 } :: any, 33), "markPayerDay creates the bitmap")
end

-- 8. ServerHealthLogic -------------------------------------------------------------------------------------
do
	local cfg = AnalyticsConfig.Health
	local before = ServerHealthLogic.newTotals(cfg)
	local after = ServerHealthLogic.copy(before)
	after.seconds = 60
	after.frames = 600
	after.frameMsSum = 600 * 100
	after.frameBuckets[#after.frameBuckets] = 600 -- every frame > 100 ms: a laggy minute
	after.hbN, after.hbSum, after.memSum, after.plrSum = 120, 600, 120 * 1500, 240
	after.hbBuckets[3] = 120
	after.memBuckets[2] = 120
	after.pingN, after.pingSum = 2, 160
	after.pingBuckets[2] = 2
	after.systems.Producers = 0.5
	after.remoteFires.IncomePop = 10
	after.remoteBytes.IncomePop = 2048
	local window = ServerHealthLogic.diff(after, before)
	local counters = ServerHealthLogic.counters(window, cfg)
	check(counters.win == 1 and counters.laggy == 1 and counters["ft:100+"] == 600, "health counters + laggy")
	check(counters["sys:Producers"] == 500 and counters["rx:IncomePop:kb"] == 2, "systems + remotes")
	check(next(ServerHealthLogic.counters(ServerHealthLogic.diff(before, before), cfg)) == nil, "empty window")
	local rows = ServerHealthLogic.rows(counters, cfg)
	check(#rows >= 6 and rows[1].id == "windows", "health rows")
	check(#ServerHealthLogic.systemRows(counters) == 2, "system + remote rows")
	check(ServerHealthLogic.percentileIndex({ 90, 5, 5 }, 0.95) == 2, "percentile")
end

-- 9. Config sanity ----------------------------------------------------------------------------------------
do
	check(#AnalyticsConfig.Ftue.Steps <= 30 and #AnalyticsConfig.FirstDay.Milestones <= 30, "bit lists fit")
	for _, step in AnalyticsConfig.Ftue.OnboardingSteps do
		check(table.find(AnalyticsConfig.Ftue.Steps, step) ~= nil, `onboarding step {step} is a funnel step`)
	end
	for _, step in AnalyticsConfig.Ftue.ClientSteps do
		check(table.find(AnalyticsConfig.Ftue.Steps, step) ~= nil, `client step {step} is a funnel step`)
	end
	for _, family in AnalyticsConfig.RecorderFamilies do
		check(table.find(AnalyticsConfig.Families, family) ~= nil, `recorder family {family} stored`)
		check(AnalyticsConfig.Metrics[family] ~= nil, `recorder family {family} documented`)
	end
	for _, family in AnalyticsConfig.Families do
		check(
			AnalyticsConfig.FamilyTitles[family] ~= nil and AnalyticsConfig.Metrics[family] ~= nil,
			`family {family} titled`
		)
	end
end

done("analytics-logic")
