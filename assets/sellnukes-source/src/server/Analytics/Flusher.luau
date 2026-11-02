--!strict
--[[
	Flusher — owns the AnalyticsStore of this server and writes the Recorder's deltas to it.

	Purpose:
		- `start()` opens the DataStore backend (AnalyticsConfig.StoreName). Live servers write;
		  Studio never writes (AnalyticsConfig.WriteInStudio) and falls back to a memory-only store
		  when the place has no DataStore access, so playtests still show their own counters.
		- `flushOnce()` runs the registered before-flush hooks (Sessions.flushActivity: midnight
		  carry-overs + play clock; Revenue.drainOutboxes: unfinished receipt accounting), then
		  detaches the Recorder's pending deltas and merges them into the DataStore (one
		  UpdateAsync per family-day; AnalyticsStore.flush), requeueing whatever failed.
		  Never throws, never runs twice at once, yields (DataStore calls) on its own thread.
		- `flushPendingAsync(seconds)` drains the final deltas at shutdown (BindToClose), bounded by
		  AnalyticsConfig.CloseFlushSeconds; gameplay recorders never wait on it.
		- `generation()` changes whenever a flush starts, so a report that snapshotted unsaved
		  deltas can detect an overlapping flush and retry (never a doubled count).

	Connects to: Recorder (pending deltas), AnalyticsStore (I/O), AnalyticsService (loop +
	BindToClose), Reports (store reads), Revenue (receipt journal through `store()`).

	Example:
		Flusher.start()
		Flusher.onBeforeFlush(Sessions.flushActivity)
		task.spawn(function() while true do task.wait(60) Flusher.flushOnce() end end)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AnalyticsConfig = require(ReplicatedStorage.Shared.Config.AnalyticsConfig)
local AnalyticsLogic = require(script.Parent.AnalyticsLogic)
local AnalyticsStore = require(script.Parent.AnalyticsStore)
local Recorder = require(script.Parent.Recorder)

local Flusher = {}

local store: AnalyticsStore.Store? = nil
local writesEnabled = false
local flushing = false
local generation = 0
local activityNoted = false
local hooks: { () -> () } = {}

local STORAGE_POLL_SECONDS = 0.05
local DRAIN_RETRY_SECONDS = 1

--[[
	Opens this server's store. Idempotent. Studio: read-only, and memory-only when the DataStore
	probe fails (no API access), so admins still get a report of the server's own counts.
]]
function Flusher.start()
	if store ~= nil then
		return
	end
	local isStudio = RunService:IsStudio()
	writesEnabled = not isStudio or AnalyticsConfig.WriteInStudio
	local backend = AnalyticsStore.dataStoreBackend(AnalyticsConfig.StoreName)
	local live = AnalyticsStore.new(backend, {
		canWrite = writesEnabled,
		shard = AnalyticsLogic.shardFor(game.JobId, AnalyticsConfig.ShardCount),
	})
	store = live
	if isStudio and backend ~= nil then
		task.spawn(function()
			local ok = (backend :: AnalyticsStore.Backend).get(AnalyticsLogic.MetaKey)
			if not ok and store == live then
				store = AnalyticsStore.new(nil, { canWrite = false, shard = 0 })
			end
		end)
	end
end

--[[ The live store (nil before start). ]]
function Flusher.store(): AnalyticsStore.Store?
	return store
end

--[[ True when this server writes analytics (live servers; never Studio by default). ]]
function Flusher.writesEnabled(): boolean
	return writesEnabled
end

--[[ True while a flush is writing. ]]
function Flusher.isFlushing(): boolean
	return flushing
end

--[[ Changes every time a flush starts writing (report snapshot consistency). ]]
function Flusher.generation(): number
	return generation
end

--[[ Registers a hook that runs (pcall'd) at the start of every flush, before the write. ]]
function Flusher.onBeforeFlush(hook: () -> ())
	table.insert(hooks, hook)
end

--[[
	One flush. Never throws; never runs twice at once. Yields (DataStore calls).
	@return true when the pending deltas were all written (or there was nothing to write)
]]
function Flusher.flushOnce(): boolean
	if flushing or store == nil then
		return false
	end
	flushing = true
	for _, hook in hooks do
		local ok, err = pcall(hook)
		if not ok then
			Recorder.warn("beforeFlush", tostring(err))
		end
	end
	local done = false
	local ok, err = pcall(function()
		if not writesEnabled or Recorder.isEmpty() then
			done = true
			return
		end
		local batch = Recorder.detach()
		generation += 1 -- before the first yielding write, even if it later fails
		local unsent = (store :: AnalyticsStore.Store).flush(batch)
		Recorder.settle(batch, unsent)
		done = next(unsent) == nil
		if not activityNoted then
			activityNoted = true
			(store :: AnalyticsStore.Store).noteActivity(Recorder.today())
		end
	end)
	if not ok then
		Recorder.restoreInflight()
		Recorder.warn("flush", tostring(err))
		done = false
	end
	flushing = false
	return done
end

--[[
	Drains the final pending counters within `seconds` (capped at CloseFlushSeconds). Waits for a
	running periodic flush, then saves events recorded after it (e.g. session ends during
	BindToClose). Storage failures retry at most once per second while budget remains.
	@return true only when no writable deltas remain
]]
function Flusher.flushPendingAsync(seconds: number): boolean
	local budget = if seconds == seconds then math.clamp(seconds, 0, AnalyticsConfig.CloseFlushSeconds) else 0
	local deadline = os.clock() + budget
	local finished = false
	task.spawn(function()
		while os.clock() < deadline do
			if flushing then
				task.wait(STORAGE_POLL_SECONDS)
			elseif not writesEnabled or Recorder.isEmpty() then
				finished = true
				return
			else
				Flusher.flushOnce()
				if not flushing and Recorder.isEmpty() then
					finished = true
					return
				end
				local left = deadline - os.clock()
				if left > 0 then
					task.wait(math.min(DRAIN_RETRY_SECONDS, left))
				end
			end
		end
	end)
	while not finished and os.clock() < deadline do
		task.wait(math.min(STORAGE_POLL_SECONDS, deadline - os.clock()))
	end
	return finished
end

-- The live store while a test backend is swapped in (nil otherwise).
local liveState: { store: AnalyticsStore.Store?, writes: boolean, noted: boolean }? = nil

--[[
	Studio / tests: swaps in a test backend (e.g. AnalyticsStore.memoryBackend()) with its own write
	permission; returns a restore function. Errors outside Studio (never on a live server).
]]
function Flusher.useBackendForTests(backend: AnalyticsStore.Backend?, canWrite: boolean): () -> ()
	if not RunService:IsStudio() then
		error("[Analytics] test backends are Studio-only")
	end
	if liveState == nil then
		liveState = { store = store, writes = writesEnabled, noted = activityNoted }
	end
	store = AnalyticsStore.new(backend, { canWrite = canWrite, shard = 0 })
	writesEnabled = canWrite
	activityNoted = false
	return function()
		local saved = liveState
		if saved == nil then
			return
		end
		liveState = nil
		store, writesEnabled, activityNoted = saved.store, saved.writes, saved.noted
	end
end

return Flusher
