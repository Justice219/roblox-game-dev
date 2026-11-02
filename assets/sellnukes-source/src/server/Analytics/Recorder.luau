--!strict
--[[
	Recorder — this server's in-memory analytics deltas (the one place counters are written).

	Purpose:
		Every recorder (Sessions, Revenue, Recorders, ServerHealth windows, ClientPerfIngest) calls
		`Recorder.count(family, key, amount)`. Deltas accumulate per UTC day and family in `pending`;
		the Flusher detaches them every FlushInterval s (`detach`), writes them (AnalyticsStore.flush)
		and hands back whatever could not be written (`settle` → requeue, dropped after
		MaxRetrySeconds with a core "ops:flushDropped:<family>" count). A report snapshots
		`unsavedCopy()` (pending + in flight) so admins see this server's last minute too.

		count() never yields, never throws on a bad amount (non-finite / zero amounts are ignored by
		AnalyticsLogic.add) and also writes the bounded per-release slice (BuildMetrics) on the
		same day, so neither retries nor exports can duplicate it.

	Connects to: AnalyticsLogic (record / merge), BuildMetrics (release slices), Flusher, every
	recorder module, AnalyticsService.snapshotUnsaved (tests / Studio verification).

	Example:
		Recorder.count("tycoon", "pad:a1_workbench")          -- +1 today
		Recorder.count("economy", "earn:cash:Producer", 1250)  -- +1250 today
		local batch = Recorder.detach()                        -- flush: pending → in flight
		Recorder.settle(batch, unsent)                         -- written / requeued
]]

local AnalyticsLogic = require(script.Parent.AnalyticsLogic)
local BuildMetrics = require(script.Parent.BuildMetrics)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AnalyticsConfig = require(ReplicatedStorage.Shared.Config.AnalyticsConfig)

type Pending = AnalyticsLogic.Pending

local Recorder = {}

-- This server's deltas: recorded → pending; a flush moves them to inflight while writing.
local pending: Pending = {}
local inflight: Pending = {}
-- "day|family" → os.clock() of the first failed write (retry budget).
local failedSince: { [string]: number } = {}
-- Throttled warnings: name → os.clock() of the last one (one per name per minute).
local lastWarn: { [string]: number } = {}

--[[ Today's UTC day number (server clock; never the client's). ]]
function Recorder.today(): number
	return AnalyticsLogic.dayNumber(os.time())
end

--[[
	Records `amount` (default 1) of `key` in `family` today, plus its release slice when the
	metric is one of BuildMetrics' fixed set.
	Example: Recorder.count("core", "sessions")
]]
function Recorder.count(family: string, key: string, amount: number?)
	local day = Recorder.today()
	local delta = amount or 1
	AnalyticsLogic.record(pending, day, family, key, delta)
	local buildKey = BuildMetrics.key(family, key)
	if buildKey ~= nil then
		AnalyticsLogic.record(pending, day, "core", buildKey, delta)
	end
end

--[[
	Records on an explicit UTC day (an event whose day was captured before a yield, e.g. a game
	pass price looked up asynchronously, or a session counted on its START day).
]]
function Recorder.countOn(day: number, family: string, key: string, amount: number)
	AnalyticsLogic.record(pending, day, family, key, amount)
	local buildKey = BuildMetrics.key(family, key)
	if buildKey ~= nil then
		AnalyticsLogic.record(pending, day, "core", buildKey, amount)
	end
end

--[[ A throttled warning (at most one per `name` per minute; never spams the output). ]]
function Recorder.warn(name: string, message: string)
	local now = os.clock()
	if now - (lastWarn[name] or -math.huge) < 60 then
		return
	end
	lastWarn[name] = now
	warn(`[Analytics] {name}: {message}`)
end

--[[ True when nothing is waiting to be written. ]]
function Recorder.isEmpty(): boolean
	return next(pending) == nil
end

--[[
	Moves every pending delta into the in-flight batch and returns it (the Flusher writes it).
	Recording continues into a fresh pending map meanwhile.
]]
function Recorder.detach(): Pending
	local batch = pending
	pending = {}
	inflight = batch
	return batch
end

--[[
	Puts unsent deltas back (merged with anything recorded meanwhile); drops ones that have failed
	for longer than MaxRetrySeconds (counted as core "ops:flushDropped:<family>").
]]
local function requeue(unsent: Pending)
	local now = os.clock()
	for day, families in unsent do
		for family, counters in families do
			local id = `{day}|{family}`
			local since = failedSince[id]
			if since == nil then
				failedSince[id] = now
			elseif now - since > AnalyticsConfig.MaxRetrySeconds then
				Recorder.warn("flush", `dropping unsaved {family} counts for day {day} after retries`)
				failedSince[id] = nil
				AnalyticsLogic.record(pending, Recorder.today(), "core", `ops:flushDropped:{family}`, 1)
				continue
			end
			for key, value in counters do
				AnalyticsLogic.record(pending, day, family, key, value)
			end
		end
	end
end

--[[
	Finishes a flush: clears the retry clock of every family-day that was written and requeues the
	unsent rest. `unsent` = AnalyticsStore.flush's return value.
]]
function Recorder.settle(batch: Pending, unsent: Pending)
	inflight = {}
	for day, families in batch do
		for family in families do
			if unsent[day] == nil or unsent[day][family] == nil then
				failedSince[`{day}|{family}`] = nil
			end
		end
	end
	requeue(unsent)
end

--[[ A flush failed with an error: whatever was in flight goes back to pending (never lost). ]]
function Recorder.restoreInflight()
	local batch = inflight
	inflight = {}
	requeue(batch)
end

--[[ A deep copy of this server's unsaved deltas (pending + in flight). ]]
function Recorder.unsavedCopy(): Pending
	local copy: Pending = {}
	for _, source in { inflight, pending } do
		for day, families in source do
			local target = copy[day]
			if target == nil then
				target = {}
				copy[day] = target
			end
			AnalyticsLogic.mergeFamilies(target, families)
		end
	end
	return copy
end

-- Saved live buffers while a test swap is active (nil otherwise).
local saved: { pending: Pending, inflight: Pending, failed: { [string]: number } }? = nil

--[[
	Tests / Studio verification: swaps in empty buffers and returns a restore function. Nested
	swaps restore to the first live state.
]]
function Recorder.swapForTests(): () -> ()
	if saved == nil then
		saved = { pending = pending, inflight = inflight, failed = failedSince }
	end
	pending, inflight, failedSince = {}, {}, {}
	return function()
		local live = saved
		if live == nil then
			return
		end
		saved = nil
		pending, inflight, failedSince = live.pending, live.inflight, live.failed
	end
end

return table.freeze(Recorder)
