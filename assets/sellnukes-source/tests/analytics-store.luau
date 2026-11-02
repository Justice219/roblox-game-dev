--!strict
--[[
	Analytics storage regressions (lune run tests/analytics-store). Real AnalyticsStore over its
	in-memory backend (failure injection), the Recorder buffer and the durable receipt journal.

	Proves:
	  1. flush merges deltas into "d:<day>:<family>:<shard>" with pure UpdateAsync transforms; a
	     second flush adds; a failed update is returned UNSENT (requeued by the Recorder); a store
	     without write permission (Studio) keeps everything unsent.
	  2. budget reserve: no update while the backend's budget is at / under the reserve.
	  3. loadRange: stored + this server's unsaved deltas; per-day series; cohort sizes; old days
	     compacted into "c:<day>" on first read (and read back from it); ended months into
	     "m:<yyyy-mm>" for "all"; read failures mark the load partial.
	  4. Recorder: count / detach / settle / restoreInflight / unsavedCopy; nothing is lost when a
	     flush fails, and the release slice ("build:*") rides with allowlisted counters.
	  5. Receipt journal: complete() is idempotent by PurchaseId (a replay never double-counts),
	     the ledger counters reach loadRange totals, a malformed / unfinished record is refused.
]]

local Loader = require("./analytics-fixtures/Loader")
local env = Loader.new()
local check, done = Loader.checker()

local AnalyticsConfig = env.load("src/shared/Config/AnalyticsConfig")
local AnalyticsLogic = env.load("src/server/Analytics/AnalyticsLogic")
local AnalyticsStore = env.load("src/server/Analytics/AnalyticsStore")
local Recorder = env.load("src/server/Analytics/Recorder")
local ReceiptAccounting = env.load("src/server/Analytics/ReceiptAccounting")

local noWait = function() end
local DAY = 20756 -- 2026-10-30
env.setTime(DAY * 86400 + 12 * 3600)

local function newStore(backend: any, canWrite: boolean?)
	return AnalyticsStore.new(backend, { canWrite = canWrite ~= false, shard = 0, wait = noWait })
end

-- 1. Flush ------------------------------------------------------------------------------------------
do
	local backend = AnalyticsStore.memoryBackend()
	local store = newStore(backend)
	local pending = {}
	AnalyticsLogic.record(pending, DAY, "tycoon", "pad:a1_workbench", 2)
	AnalyticsLogic.record(pending, DAY, "core", "dau", 1)
	local unsent = store.flush(pending)
	check(next(unsent) == nil, "flush wrote everything")
	local key = AnalyticsLogic.familyKey(DAY, "tycoon", 0)
	check((backend.data[key] :: any).c["pad:a1_workbench"] == 2, "stored family-day value")
	store.flush(pending)
	check((backend.data[key] :: any).c["pad:a1_workbench"] == 4, "second flush adds")
	backend.failNext.update = 1
	local second = {}
	AnalyticsLogic.record(second, DAY, "tycoon", "clicks", 5)
	unsent = store.flush(second)
	check(unsent[DAY] ~= nil and unsent[DAY].tycoon.clicks == 5, "failed update returned unsent")
	local readOnly = newStore(AnalyticsStore.memoryBackend(), false)
	local kept = readOnly.flush(second)
	check(kept == second, "no write permission: everything stays unsent")
	check(next(newStore(nil).flush({})) == nil, "memory mode with nothing pending")

	-- 2. Budget reserve: the backend says only the reserve is left → the write waits / skips.
	local starved = AnalyticsStore.memoryBackend()
	starved.budget = function(): number
		return AnalyticsConfig.UpdateBudgetReserve
	end
	local tight = newStore(starved)
	local left = tight.flush(second)
	check(left[DAY] ~= nil and starved.calls.update == 0, "budget reserve respected (profiles first)")
end

-- 3. loadRange ---------------------------------------------------------------------------------------
do
	local backend = AnalyticsStore.memoryBackend()
	local store = newStore(backend)
	-- Two days ago (still live) and five days ago (final: compacted on first read).
	local pending = {}
	AnalyticsLogic.record(pending, DAY - 5, "core", "new", 4)
	AnalyticsLogic.record(pending, DAY - 5, "core", "dau", 6)
	AnalyticsLogic.record(pending, DAY - 4, "core", "r1", 2)
	AnalyticsLogic.record(pending, DAY - 4, "core", "dau", 5)
	AnalyticsLogic.record(pending, DAY, "core", "dau", 3)
	AnalyticsLogic.record(pending, DAY, "tycoon", "padKind:Build", 7)
	store.flush(pending)
	store.noteActivity(DAY - 5)
	local extra = {}
	AnalyticsLogic.record(extra, DAY, "core", "dau", 1)
	local plan, loaded = store.loadRange("7d", DAY, extra)
	check(plan.from == DAY - 6, "7d plan")
	check(loaded.totals.core.dau == 15, `totals include stored + unsaved (got {loaded.totals.core.dau})`)
	check(loaded.daily[DAY].dau == 4 and loaded.daily[DAY].pads == 7, "today's series includes unsaved deltas")
	check(loaded.daily[DAY - 5].new == 4, "old day series")
	check(not loaded.partial and loaded.source == "datastore", "complete load")
	check(backend.data[AnalyticsLogic.compactDayKey(DAY - 5)] ~= nil, "final day compacted")
	check(backend.data[AnalyticsLogic.compactDayKey(DAY - 1)] == nil, "live day not compacted")
	-- A fresh store (another server) reads the compacted day.
	local other = newStore(backend)
	local _, again = other.loadRange("7d", DAY, nil)
	check(again.totals.core.new == 4 and again.totals.core.r1 == 2, "compact day read back")
	-- Retention cohort size of DAY-4's D1 = new players of DAY-5.
	local _, today = other.loadRange("today", DAY - 4, nil)
	check(
		today.cohortNew[DAY - 5] == 4 or (today.daily[DAY - 5] ~= nil and today.daily[DAY - 5].new == 4),
		"cohort sizes loaded"
	)

	-- Month compaction for "all": data 70 days back lives in an ended month.
	local monthBackend = AnalyticsStore.memoryBackend()
	local monthStore = newStore(monthBackend)
	local old = {}
	AnalyticsLogic.record(old, DAY - 70, "core", "dau", 9)
	AnalyticsLogic.record(old, DAY - 70, "core", "new", 9)
	monthStore.flush(old)
	monthStore.noteActivity(DAY - 70)
	local allPlan, all = monthStore.loadRange("all", DAY, nil)
	check(#allPlan.months >= 1, "all range plans months")
	check(
		all.totals.core.dau == 9 and all.daily[DAY - 70] ~= nil and all.daily[DAY - 70].new == 9,
		"month totals + series"
	)
	check(
		monthBackend.data[AnalyticsLogic.compactMonthKey(AnalyticsLogic.monthOf(DAY - 70))] ~= nil,
		"ended month compacted"
	)

	-- Read failures → partial (never a silent zero).
	local flaky = AnalyticsStore.memoryBackend()
	local flakyStore = newStore(flaky)
	flaky.failNext.get = 1000
	local _, broken = flakyStore.loadRange("today", DAY, nil)
	check(broken.partial, "failed reads mark the load partial")
	local memoryStore = newStore(nil)
	local _, memoryLoad = memoryStore.loadRange("today", DAY, extra)
	check(memoryLoad.totals.core.dau == 1, "memory mode: unsaved deltas only")
end

-- 4. Recorder -------------------------------------------------------------------------------------------
do
	local restore = Recorder.swapForTests()
	Recorder.count("tycoon", "clicks", 3)
	Recorder.count("core", "dau")
	local copy = Recorder.unsavedCopy()
	local today = Recorder.today()
	check(copy[today].tycoon.clicks == 3, "count recorded today")
	check(copy[today].core["build:unknown:punknown:dau"] == 1, "build slice of an allowlisted metric")
	check(copy[today].core["build:unknown:punknown:clicks"] == nil, "no slice for other metrics")
	local batch = Recorder.detach()
	check(Recorder.isEmpty(), "detach empties pending")
	Recorder.count("tycoon", "clicks", 1) -- recorded while the flush writes
	local inflightCopy = Recorder.unsavedCopy()
	check(inflightCopy[today].tycoon.clicks == 4, "unsavedCopy = in flight + pending")
	-- The write fails for tycoon only.
	Recorder.settle(batch, { [today] = { tycoon = batch[today].tycoon } })
	local after = Recorder.unsavedCopy()
	check(
		after[today].tycoon.clicks == 4 and after[today].core == nil or after[today].core.dau == nil,
		"failed family requeued, written family gone"
	)
	local batch2 = Recorder.detach()
	check(batch2[today].tycoon.clicks == 4, "requeued deltas are in the next batch")
	Recorder.restoreInflight()
	check(Recorder.unsavedCopy()[today].tycoon.clicks == 4, "an erroring flush puts the batch back")
	restore()
end

-- 5. Receipt journal -------------------------------------------------------------------------------------
do
	local backend = AnalyticsStore.memoryBackend()
	local store = newStore(backend)
	local record = ReceiptAccounting.read({
		day = DAY,
		userId = 77,
		productId = 9001,
		product = "GemsSmall",
		kind = "Gems",
		robux = 49,
		source = "shop",
		device = "phone",
		area = 2,
		rebirths = 0,
		staff = false,
		payEligible = true,
		ready = false,
		gems = 0,
	})
	check(record ~= nil, "record valid")
	check(not store.recordReceipt("P-1", record), "an unfinished record is refused")
	ReceiptAccounting.finalize(record, { payFirst = 0, payLast = 0, payDays = {} }, 100)
	check(store.recordReceipt("P-1", record), "journal accepts a finalized record")
	check(store.recordReceipt("P-1", record), "a replay is acknowledged")
	local _, loaded = store.loadRange("today", DAY, nil)
	check(loaded.totals.revenue.robux == 49, `ledger counted once (got {loaded.totals.revenue.robux})`)
	check(loaded.totals.revenue["purchase:GemsSmall:shop"] == 1, "purchase by source from the ledger")
	check(loaded.totals.core.payers == 1 and loaded.totals.core.newPayers == 1, "payer facts from the ledger")
	check(loaded.daily[DAY].robux == 49, "ledger Robux in the daily series")
	local tampered = table.clone(record)
	tampered.robux = 1
	check(not store.recordReceipt("P-1", tampered), "a tampered replay cannot rewrite the facts")
	check(not newStore(backend, false).recordReceipt("P-2", record), "no write permission: journal unavailable")
end

done("analytics-store")
