--!strict
--[[
	AnalyticsStore — DataStore I/O for analytics: delta flushes, range loads, caching, compaction.

	Purpose:
		Keeps every DataStore detail out of AnalyticsService:
			- flush(pending): merges this server's per-day deltas into "d:<day>:<family>:<shard>"
			  with UpdateAsync (one request per family-day; the transform is pure, so a retried
			  transform never double-counts). Returns whatever could not be written so the
			  service re-queues it (the next flush 60 s later is the backoff).
			- loadRange(range, today, extra): reads only what the range needs (AnalyticsLogic.plan),
			  sums it and returns AnalyticsLogic.Loaded. Days older than CompactAfterDays are final:
			  the first reader merges their family keys into one "c:<day>" key, and ended months
			  into "m:<yyyy-mm>" (with per-day series for cohorts). Final keys are cached in memory
			  for the server's life (bounded), live keys for CacheSeconds.
			- every request waits for DataStore budget above a reserve (profiles keep priority),
			  reads retry with backoff, and nothing here ever throws to the caller.

	Backends:
		`AnalyticsStore.dataStoreBackend(name)` wraps DataStoreService (nil if unavailable, e.g.
		Studio without API access). `AnalyticsStore.memoryBackend()` is an in-memory backend with
		failure injection for tests. Without a backend the service runs in "memory" mode.

	Example:
		local store = AnalyticsStore.new(AnalyticsStore.dataStoreBackend("SellNukesAnalytics_v1"), {
			canWrite = true, shard = 0,
		})
		local unsent = store.flush(pending)                 -- yields; returns a Pending
		local plan, loaded = store.loadRange("7d", today, pendingCopy, function(done, total) end)
]]

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnalyticsConfig = require(ReplicatedStorage.Shared.Config.AnalyticsConfig)
local AnalyticsLogic = require(script.Parent.AnalyticsLogic)
local ReceiptJournal = require(script.Parent.ReceiptJournal)
local ReceiptAccounting = require(script.Parent.ReceiptAccounting)

type Pending = AnalyticsLogic.Pending
type FamilyCounters = AnalyticsLogic.FamilyCounters
type DaySeries = AnalyticsLogic.DaySeries

export type RequestKind = "get" | "update" | "set"

export type Backend = {
	-- (ok, value): ok = false on any error (value is then nil).
	get: (key: string) -> (boolean, unknown),
	-- ok = false on any error. `transform` may return nil to leave the value unchanged.
	update: (key: string, transform: (old: unknown) -> unknown?) -> boolean,
	set: (key: string, value: unknown) -> boolean,
	-- Remaining request budget for this kind (math.huge when unlimited).
	budget: (kind: RequestKind) -> number,
}

export type MemoryBackend = Backend & {
	data: { [string]: unknown },
	calls: { [string]: number }, -- "get" / "update" / "set" request counts
	failNext: { [string]: number }, -- kind → number of upcoming requests that fail
}

export type Store = {
	reserveReceipt: (string, ReceiptAccounting.Record) -> (string, ReceiptAccounting.Record?, boolean?),
	recordReceipt: (string, ReceiptAccounting.Record) -> boolean,
	flush: (pending: Pending) -> Pending,
	loadRange: (
		range: string,
		today: number,
		extra: Pending?,
		progress: ((done: number, total: number) -> ())?
	) -> (AnalyticsLogic.Plan, AnalyticsLogic.Loaded),
	firstDay: () -> number?,
	noteActivity: (day: number) -> (),
	hasBackend: () -> boolean,
	clearCaches: () -> (),
}

export type Options = {
	canWrite: boolean, -- false in Studio: never write live analytics from playtests
	shard: number,
	clock: (() -> number)?, -- os.clock override (tests)
	wait: ((seconds: number) -> ())?, -- task.wait override (tests)
}

local AnalyticsStore = {}

local READ_ATTEMPTS = 3
local BUDGET_WAIT_LIMIT = 20 -- seconds a single request may wait for budget before giving up
local META_REFRESH_SECONDS = 3600

--------------------------------------------------------------------------------------------------
-- Backends
--------------------------------------------------------------------------------------------------

--[[
	DataStore backend (nil if DataStoreService refuses, e.g. Studio without API access).
	Every call is pcall'd; failures return ok = false.
]]
function AnalyticsStore.dataStoreBackend(name: string): Backend?
	local okStore, store = pcall(function()
		return DataStoreService:GetDataStore(name)
	end)
	if not okStore or store == nil then
		return nil
	end
	local dataStore = store :: DataStore
	local requestTypes = {
		get = Enum.DataStoreRequestType.GetAsync,
		update = Enum.DataStoreRequestType.UpdateAsync,
		set = Enum.DataStoreRequestType.SetIncrementAsync,
	}
	return {
		get = function(key: string): (boolean, unknown)
			local ok, value = pcall(function()
				return dataStore:GetAsync(key)
			end)
			if not ok then
				warn(`[AnalyticsStore] GetAsync {key} failed: {value}`)
				return false, nil
			end
			return true, value
		end,
		update = function(key: string, transform: (old: unknown) -> unknown?): boolean
			local ok, err = pcall(function()
				dataStore:UpdateAsync(key, function(old: unknown)
					return transform(old)
				end)
			end)
			if not ok then
				warn(`[AnalyticsStore] UpdateAsync {key} failed: {err}`)
			end
			return ok
		end,
		set = function(key: string, value: unknown): boolean
			local ok, err = pcall(function()
				dataStore:SetAsync(key, value)
			end)
			if not ok then
				warn(`[AnalyticsStore] SetAsync {key} failed: {err}`)
			end
			return ok
		end,
		budget = function(kind: RequestKind): number
			local ok, budget = pcall(function()
				return DataStoreService:GetRequestBudgetForRequestType(requestTypes[kind])
			end)
			return if ok and type(budget) == "number" then budget else 0
		end,
	}
end

-- Deep copy for the memory backend (callers must never share tables with "stored" data).
local function copy(value: unknown): unknown
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, inner in value :: { [any]: unknown } do
		out[key] = copy(inner)
	end
	return out
end

--[[
	In-memory backend for tests: `data` holds stored values (deep-copied in and out, like a real
	DataStore), `calls` counts requests and `failNext[kind] = n` makes the next n requests of a
	kind fail.
]]
function AnalyticsStore.memoryBackend(): MemoryBackend
	local data: { [string]: unknown } = {}
	local calls: { [string]: number } = { get = 0, update = 0, set = 0 }
	local failNext: { [string]: number } = {}
	local function shouldFail(kind: string): boolean
		calls[kind] = (calls[kind] or 0) + 1
		local remaining = failNext[kind] or 0
		if remaining > 0 then
			failNext[kind] = remaining - 1
			return true
		end
		return false
	end
	return {
		data = data,
		calls = calls,
		failNext = failNext,
		get = function(key: string): (boolean, unknown)
			if shouldFail("get") then
				return false, nil
			end
			return true, copy(data[key])
		end,
		update = function(key: string, transform: (old: unknown) -> unknown?): boolean
			if shouldFail("update") then
				return false
			end
			local result = transform(copy(data[key]))
			if result ~= nil then
				data[key] = copy(result)
			end
			return true
		end,
		set = function(key: string, value: unknown): boolean
			if shouldFail("set") then
				return false
			end
			data[key] = copy(value)
			return true
		end,
		budget = function(_kind: RequestKind): number
			return math.huge
		end,
	}
end

--------------------------------------------------------------------------------------------------
-- Store
--------------------------------------------------------------------------------------------------

--[[ Creates a store over `backend` (nil = memory mode: nothing persists, loads see only `extra`). ]]
function AnalyticsStore.new(backend: Backend?, options: Options): Store
	local clock = options.clock or os.clock
	local sleep = options.wait or function(seconds: number)
		task.wait(seconds)
	end

	-- Final (immutable) values: key → value, with insertion order for bounded eviction.
	local finalCache: { [string]: unknown } = {}
	local finalOrder: { string } = {}
	-- Live values: key → { at, value } (re-read after CacheSeconds).
	local liveCache: { [string]: { at: number, value: unknown } } = {}
	-- Only report counters, never receipt IDs, enter this bounded64-entry LRU.
	local receiptCache: { [string]: { at: number, days: { [number]: FamilyCounters } } } = {}
	local receiptOrder: { string } = {}
	-- Analytics start day (meta key), refreshed hourly.
	local metaDay: number? = nil
	local metaReadAt = -math.huge
	local metaWritten = false

	local function rememberFinal(key: string, value: unknown)
		if finalCache[key] == nil then
			table.insert(finalOrder, key)
			while #finalOrder > AnalyticsConfig.MaxCachedKeys do
				local oldest = table.remove(finalOrder, 1)
				if oldest ~= nil then
					finalCache[oldest] = nil
				end
			end
		end
		finalCache[key] = value
	end

	-- Waits until the backend has budget above `reserve` (false if it never does in time).
	local function waitBudget(kind: RequestKind, reserve: number): boolean
		if backend == nil then
			return false
		end
		local started = clock()
		while backend.budget(kind) <= reserve do
			if clock() - started > BUDGET_WAIT_LIMIT then
				return false
			end
			sleep(1)
		end
		return true
	end

	-- A read with budget wait and retries (1 s, 2 s backoff). (ok, value).
	local function read(key: string): (boolean, unknown)
		if backend == nil then
			return false, nil
		end
		for attempt = 1, READ_ATTEMPTS do
			if not waitBudget("get", AnalyticsConfig.GetBudgetReserve) then
				return false, nil
			end
			local ok, value = backend.get(key)
			if ok then
				return true, value
			end
			if attempt < READ_ATTEMPTS then
				sleep(attempt)
			end
		end
		return false, nil
	end

	-- A live (still-changing) key: cached for CacheSeconds.
	local function readLive(key: string): (boolean, unknown)
		local cached = liveCache[key]
		if cached ~= nil and clock() - cached.at < AnalyticsConfig.CacheSeconds then
			return true, cached.value
		end
		local ok, value = read(key)
		if ok then
			liveCache[key] = { at = clock(), value = value }
		end
		return ok, value
	end

	local function isFinal(day: number, today: number): boolean
		return day < today - AnalyticsConfig.CompactAfterDays
	end

	-- Reads the family keys of one day (every shard). (families, ok).
	local function readFamilyKeys(day: number, live: boolean): (FamilyCounters, boolean)
		local families: FamilyCounters = {}
		local allOk = true
		for _, family in AnalyticsConfig.Families do
			local counters: AnalyticsLogic.Counters = {}
			for shard = 0, math.max(1, AnalyticsConfig.ShardCount) - 1 do
				local key = AnalyticsLogic.familyKey(day, family, shard)
				local ok, value
				if live then
					ok, value = readLive(key)
				else
					ok, value = read(key)
				end
				if ok then
					AnalyticsLogic.mergeInto(counters, AnalyticsLogic.readStored(value))
				else
					allOk = false
				end
			end
			families[family] = counters
		end
		return families, allOk
	end

	--[[ One day's family counters (compacting a final day on first read). (families, ok). ]]
	local function loadDay(day: number, today: number): (FamilyCounters, boolean)
		if not isFinal(day, today) then
			return readFamilyKeys(day, true)
		end
		local key = AnalyticsLogic.compactDayKey(day)
		local cached = finalCache[key]
		if cached ~= nil then
			return AnalyticsLogic.readFamilies(cached) or {}, true
		end
		local ok, value = read(key)
		if not ok then
			return {}, false
		end
		local families = AnalyticsLogic.readFamilies(value)
		if families ~= nil then
			rememberFinal(key, value)
			return families, true
		end
		-- Not compacted yet: read the family keys, then store the compact value once.
		local merged, allOk = readFamilyKeys(day, false)
		if not allOk then
			return merged, false
		end
		local compact = AnalyticsLogic.compactDay(day, merged)
		if options.canWrite and waitBudget("set", AnalyticsConfig.UpdateBudgetReserve) and backend ~= nil then
			backend.set(key, compact)
		end
		rememberFinal(key, compact)
		return merged, true
	end

	--[[ A final month: merged families + per-day series (compacting on first read). ]]
	local function loadMonth(
		month: string,
		anyDay: number,
		today: number
	): (FamilyCounters, { [number]: DaySeries }, boolean)
		local key = AnalyticsLogic.compactMonthKey(month)
		local cached = finalCache[key]
		if cached == nil then
			local ok, value = read(key)
			if not ok then
				return {}, {}, false
			end
			if AnalyticsLogic.readFamilies(value) ~= nil then
				rememberFinal(key, value)
				cached = value
			end
		end
		if cached ~= nil then
			return AnalyticsLogic.readFamilies(cached) or {}, AnalyticsLogic.readMonthDays(cached), true
		end
		-- Compact it: every day of the month from the analytics start day on.
		local first, last = AnalyticsLogic.monthBounds(anyDay)
		local start = math.max(first, metaDay or first)
		local families: FamilyCounters = {}
		local series: { [number]: DaySeries } = {}
		for day = start, last do
			local dayFamilies, ok = loadDay(day, today)
			if not ok then
				return families, series, false
			end
			AnalyticsLogic.mergeFamilies(families, dayFamilies)
			series[day] = AnalyticsLogic.seriesOf(dayFamilies)
		end
		local compact = AnalyticsLogic.compactMonth(month, families, series)
		if options.canWrite and waitBudget("set", AnalyticsConfig.UpdateBudgetReserve) and backend ~= nil then
			backend.set(key, compact)
		end
		rememberFinal(key, compact)
		return families, series, true
	end

	local store = {} :: Store
	-- Budget-reserved writes keep receipt accounting from starving profile commits. The journal
	-- performs no retries internally: ambiguous failures return to the pinned durable outbox.
	local journal = ReceiptJournal.new({
		update = function(key, transform)
			if
				backend == nil
				or not options.canWrite
				or not waitBudget("update", AnalyticsConfig.UpdateBudgetReserve)
			then
				return false
			end
			local ok = backend.update(key, transform)
			liveCache[key] = nil
			receiptCache[key] = nil
			return ok
		end,
	})
	store.reserveReceipt = journal.reserve
	store.recordReceipt = journal.complete

	--[[ The analytics start day (meta key), read at most hourly. ]]
	function store.firstDay(): number?
		if backend ~= nil and clock() - metaReadAt > META_REFRESH_SECONDS then
			local ok, value = read(AnalyticsLogic.MetaKey)
			if ok then
				metaReadAt = clock()
				metaDay = AnalyticsLogic.readMeta(value) or metaDay
			end
		end
		return metaDay
	end

	--[[ Records that analytics data exists for `day` (keeps the meta start day ≤ day). ]]
	function store.noteActivity(day: number)
		if metaWritten or backend == nil or not options.canWrite then
			metaDay = if metaDay == nil then day else math.min(metaDay, day)
			return
		end
		local writer = backend :: Backend
		if not waitBudget("update", AnalyticsConfig.UpdateBudgetReserve) then
			return
		end
		local ok = writer.update(AnalyticsLogic.MetaKey, function(old: unknown): unknown?
			local existing = AnalyticsLogic.readMeta(old)
			if existing ~= nil and existing <= day then
				return nil -- already older: leave unchanged
			end
			return { firstDay = day }
		end)
		if ok then
			metaWritten = true
			metaDay = if metaDay == nil then day else math.min(metaDay, day)
		end
	end

	--[[
		Writes pending deltas (UpdateAsync merge per family-day). Returns what was not written
		(no backend / no write permission → everything is kept for the in-memory view only).
	]]
	function store.flush(pending: Pending): Pending
		local unsent: Pending = {}
		if backend == nil or not options.canWrite then
			return pending
		end
		for day, families in pending do
			for family, counters in families do
				if next(counters) == nil then
					continue
				end
				local written = false
				if backend.budget("update") > AnalyticsConfig.UpdateBudgetReserve then
					local key = AnalyticsLogic.familyKey(day, family, options.shard)
					written = backend.update(key, function(old: unknown): unknown?
						return AnalyticsLogic.mergeStored(old, counters)
					end)
					if written then
						-- Our own write changed the live key: drop the cached read.
						liveCache[key] = nil
					end
				end
				if not written then
					local keep = unsent[day]
					if keep == nil then
						keep = {}
						unsent[day] = keep
					end
					keep[family] = counters
				end
			end
		end
		return unsent
	end

	--[[
		Loads a range: totals over its days, per-day series and cohort sizes. `extra` (this
		server's unflushed deltas) is added on top so "today" includes the last minute.
		`progress(done, total)` is called after every key group.
	]]
	function store.loadRange(
		range: string,
		today: number,
		extra: Pending?,
		progress: ((done: number, total: number) -> ())?
	): (AnalyticsLogic.Plan, AnalyticsLogic.Loaded)
		local plan = AnalyticsLogic.plan(range, today, store.firstDay())
		local totals: FamilyCounters = {}
		local daily: { [number]: DaySeries } = {}
		local cohortNew: { [number]: number } = {}
		local partial = false
		local total = #plan.months + #plan.days + #plan.cohortDays
		local done = 0
		local function step()
			done += 1
			if progress ~= nil then
				progress(done, total)
			end
		end
		local function inRange(day: number): boolean
			return day >= plan.from and day <= plan.to
		end
		-- Adds unflushed local deltas of `day` (if any) into a day's families.
		local function withExtra(day: number, families: FamilyCounters): FamilyCounters
			local local_ = if extra ~= nil then extra[day] else nil
			if local_ == nil then
				return families
			end
			local merged: FamilyCounters = {}
			AnalyticsLogic.mergeFamilies(merged, families)
			AnalyticsLogic.mergeFamilies(merged, local_)
			return merged
		end

		if backend == nil then
			-- Memory mode: only this server's unsaved deltas exist.
			for day = plan.from, plan.to do
				local families = withExtra(day, {})
				AnalyticsLogic.mergeFamilies(totals, families)
				if next(families) ~= nil then
					daily[day] = AnalyticsLogic.seriesOf(families)
				end
			end
			return plan, { totals = totals, daily = daily, cohortNew = cohortNew, partial = false, source = "memory" }
		end

		-- Month series cache for cohort lookups within this load.
		local monthSeries: { [string]: { [number]: DaySeries } } = {}
		for _, ref in plan.months do
			local families, series, ok = loadMonth(ref.month, ref.day, today)
			partial = partial or not ok
			AnalyticsLogic.mergeFamilies(totals, families)
			monthSeries[ref.month] = series
			for day, values in series do
				if inRange(day) then
					-- Receipt overlays below must not mutate the final month cache's base series.
					daily[day] = table.clone(values)
				end
			end
			step()
		end
		for _, day in plan.days do
			local families, ok = loadDay(day, today)
			partial = partial or not ok
			families = withExtra(day, families)
			AnalyticsLogic.mergeFamilies(totals, families)
			daily[day] = AnalyticsLogic.seriesOf(families)
			step()
		end
		-- Read active monthly shards once each, retaining counters only. Late recovery remains
		-- visible beside immutable base day/month compactions, and all-time costs scale by month.
		local monthDay = math.max(plan.from, 1)
		while monthDay <= math.min(plan.to, ReceiptAccounting.MaxDay) do
			local month = ReceiptAccounting.month(monthDay)
			local indexOk, index = readLive(ReceiptAccounting.indexKey(monthDay))
			partial = partial or not indexOk or (index ~= nil and type(index) ~= "table")
			if indexOk and type(index) == "table" then
				for key, value in index :: { [unknown]: unknown } do
					local shard = if type(key) == "string" then tonumber(key) else nil
					if
						shard == nil
						or shard % 1 ~= 0
						or shard < 0
						or shard >= ReceiptAccounting.ShardCount
						or value ~= true
					then
						partial = true
					end
				end
				for shard = 0, ReceiptAccounting.ShardCount - 1 do
					if (index :: { [string]: unknown })[tostring(shard)] == true then
						local key = `receiptV1:{month}:{shard}`
						local cached = receiptCache[key]
						local days: { [number]: FamilyCounters } = {}
						if cached ~= nil and clock() - cached.at < AnalyticsConfig.CacheSeconds then
							days = cached.days
						else
							local ok, raw = read(key)
							partial = partial or not ok
							local byDay = if type(raw) == "table" then (raw :: { [string]: unknown }).byDay else nil
							local valid = raw == nil
								or (
									type(raw) == "table"
									and type(byDay) == "table"
									and type((raw :: { [string]: unknown }).ids) == "table"
								)
							if ok and type(byDay) == "table" then
								for rawDay, rawFamilies in byDay :: { [string]: unknown } do
									local day = tonumber(rawDay)
									if
										day ~= nil
										and day >= 1
										and day <= ReceiptAccounting.MaxDay
										and day % 1 == 0
										and ReceiptAccounting.month(day) == month
										and type(rawFamilies) == "table"
									then
										local families: FamilyCounters = {}
										for _, family in AnalyticsConfig.Families do
											families[family] = AnalyticsLogic.readCounters(
												(rawFamilies :: { [string]: unknown })[family]
											)
										end
										days[day] = families
									else
										valid = false
									end
								end
							end
							partial = partial or not valid
							if ok and valid then
								receiptCache[key] = { at = clock(), days = days }
							end
						end
						local existing = table.find(receiptOrder, key)
						if existing ~= nil then
							table.remove(receiptOrder, existing)
						end
						table.insert(receiptOrder, key)
						if #receiptOrder > 64 then
							local evicted = table.remove(receiptOrder, 1)
							if evicted ~= nil then
								receiptCache[evicted] = nil
							end
						end
						for day, families in days do
							if inRange(day) then
								AnalyticsLogic.mergeFamilies(totals, families)
								local added = AnalyticsLogic.seriesOf(families)
								local values = daily[day]
								if values == nil then
									daily[day] = added
								else
									values.robux += added.robux
									values.payers += added.payers
								end
							end
						end
					end
				end
			end
			local _, last = AnalyticsLogic.monthBounds(monthDay)
			monthDay = last + 1
		end
		for _, day in plan.cohortDays do
			local month = AnalyticsLogic.monthOf(day)
			local _, last = AnalyticsLogic.monthBounds(day)
			local newPlayers = 0
			if last < today - AnalyticsConfig.CompactAfterDays then
				-- A final month: one month key covers every cohort day in it.
				local series = monthSeries[month]
				if series == nil then
					local _families, loadedSeries, ok = loadMonth(month, day, today)
					partial = partial or not ok
					series = loadedSeries
					monthSeries[month] = series
				end
				local values = series[day]
				newPlayers = if values ~= nil then values.new else 0
			else
				local families, ok = loadDay(day, today)
				partial = partial or not ok
				families = withExtra(day, families)
				local core: AnalyticsLogic.Counters = families.core or {}
				newPlayers = core.new or 0
			end
			cohortNew[day] = newPlayers
			step()
		end
		return plan, { totals = totals, daily = daily, cohortNew = cohortNew, partial = partial, source = "datastore" }
	end

	function store.hasBackend(): boolean
		return backend ~= nil
	end

	--[[ Forgets every cached value (tests; or after a manual data repair). ]]
	function store.clearCaches()
		table.clear(receiptCache)
		table.clear(receiptOrder)
		table.clear(finalCache)
		table.clear(finalOrder)
		table.clear(liveCache)
		metaReadAt = -math.huge
	end

	return store
end

return table.freeze(AnalyticsStore)
