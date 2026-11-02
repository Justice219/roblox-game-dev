--!strict
--[[
	Reports — admin read-back of analytics (ported from RoBeasts' AnalyticsService report half).

	Remotes:
		AnalyticsRequest (C→S)  (requestId: integer, range: "today" | "7d" | "30d" | "all")
		AnalyticsReport  (S→C)  (requestId, { ok, code, range?, summary?, done?, total? })
		                        code: "Ok" (summary attached) | "Loading" (progress done/total) |
		                        "RateLimited" | "BadRequest" | "NotAuthorized" | "Error"
		AnalyticsRawRequest / AnalyticsRawPage — COPY RAW DATA pages (Server/Analytics/AnalyticsRaw)
	Every request: per-user token bucket → typeof checks → AnalyticsAuth.isAuthorizedAsync
	(re-checked every time) → a 30 s shared cache per range; concurrent requests for a range join
	ONE load job, so clients can never drive DataStore reads in a loop. Replies re-check isAdmin.

	summaryAsync(range): snapshot this server's unsaved deltas → AnalyticsStore.loadRange → (retry
	if a flush overlapped: never a doubled count) → AnalyticsLogic.summarize with ReportSections
	→ AnalyticsRaw.remember (stamps summary.rawId for COPY RAW DATA).

	Connects to: Flusher (store, generation), Recorder (unsaved deltas), AnalyticsLogic,
	ReportSections, AnalyticsRaw, AnalyticsAuth, Remotes, Validate, RateLimiter.

	Example:
		local summary = Reports.summaryAsync("7d")                 -- server-internal, no auth
		local text = AnalyticsReport.toText(summary)               -- COPY FOR AI
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnalyticsConfig = require(ReplicatedStorage.Shared.Config.AnalyticsConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local TycoonConfig = require(ReplicatedStorage.Shared.Config.TycoonConfig)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)
local AnalyticsReport = require(ReplicatedStorage.Shared.Analytics.AnalyticsReport)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Validate = require(ReplicatedStorage.Shared.Net.Validate)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local AnalyticsAuth = require(script.Parent.AnalyticsAuth)
local AnalyticsLogic = require(script.Parent.AnalyticsLogic)
local AnalyticsRaw = require(script.Parent.AnalyticsRaw)
local AnalyticsStore = require(script.Parent.AnalyticsStore)
local Flusher = require(script.Parent.Flusher)
local Recorder = require(script.Parent.Recorder)
local ReportSections = require(script.Parent.ReportSections)

export type Payload = {
	ok: boolean,
	code: string,
	range: string?,
	summary: AnalyticsReport.Summary?,
	done: number?,
	total: number?,
}

type Waiter = { player: Player?, requestId: number, thread: thread }
type Job = { waiters: { Waiter }, done: number, total: number, progressAt: number }

local Reports = {}

local requestLimiter = RateLimiter.new(AnalyticsConfig.RequestBurst, AnalyticsConfig.RequestPerSecond)
local jobs: { [string]: Job } = {}
local summaryCache: { [string]: { at: number, summary: AnalyticsReport.Summary } } = {}
-- Serializes report loaders (they share AnalyticsStore's caches). Recorders never wait on it.
local reportLoading = false

local REPORT_SYNC_SECONDS = 20
local REPORT_LOAD_ATTEMPTS = 3
local STORAGE_POLL_SECONDS = 0.05

--[[
	Display names for report rows (config lookups; unknown ids show the id).
	Kinds: pad, producer, area, product, pass, reason, feature (others return the id). Pads and
	producers of an extra world (R57: d3_… / dp3_…) are labelled with their world's name.
]]
function Reports.labelOf(kind: string, id: string, sub: string?): string
	local ok, label = pcall(function(): string?
		if kind == "pad" then
			local pad = TycoonConfig.PadsById[id]
			if pad ~= nil then
				return `{pad.name} (area {pad.area})`
			end
			local world = WorldsConfig.get(WorldsConfig.worldOfPad(id))
			local worldPad = if world ~= nil then world.economy.PadsById[id] else nil
			return if world ~= nil and worldPad ~= nil
				then `{worldPad.name} ({world.name} area {worldPad.area})`
				else nil
		elseif kind == "producer" then
			local producer = TycoonConfig.ProducersById[id]
			if producer ~= nil then
				return producer.name
			end
			local world = WorldsConfig.get(WorldsConfig.worldOfProducer(id))
			local worldProducer = if world ~= nil then world.economy.ProducersById[id] else nil
			return if world ~= nil and worldProducer ~= nil then `{worldProducer.name} ({world.name})` else nil
		elseif kind == "area" then
			local area = TycoonConfig.Areas[tonumber(id) or 0]
			return if area ~= nil then `{id}. {area.name}` else nil
		elseif kind == "product" then
			local product = MonetizationConfig.getProduct(id)
			if product ~= nil then
				return product.name
			end
			local pass = MonetizationConfig.getPass(id)
			return if pass ~= nil then `{pass.name} (pass)` else nil
		elseif kind == "pass" then
			local pass = MonetizationConfig.getPass(id)
			return if pass ~= nil then pass.name else nil
		end
		return nil
	end)
	if ok and type(label) == "string" and label ~= "" then
		return label
	end
	return if sub ~= nil then `{id}:{sub}` else id
end

--[[
	Builds a consistent summary (loads + caches through AnalyticsStore). A concurrent flush
	invalidates the local-delta snapshot and triggers a bounded retry, never a doubled count.
	No authorization (server-internal; the remote path authorizes first). Yields.
	@param progress optional (done, total) callback while keys load
]]
function Reports.summaryAsync(
	range: AnalyticsConfig.Range,
	progress: ((done: number, total: number) -> ())?
): AnalyticsReport.Summary
	local deadline = os.clock() + REPORT_SYNC_SECONDS
	while reportLoading do
		if os.clock() >= deadline then
			error("Analytics report is busy; retry shortly", 0)
		end
		task.wait(STORAGE_POLL_SECONDS)
	end
	reportLoading = true
	local activeStore = Flusher.store() or AnalyticsStore.new(nil, { canWrite = false, shard = 0 })
	local ok, result = pcall(function(): AnalyticsReport.Summary
		for _ = 1, REPORT_LOAD_ATTEMPTS do
			local syncDeadline = os.clock() + REPORT_SYNC_SECONDS
			while Flusher.isFlushing() do
				if os.clock() >= syncDeadline then
					error("Analytics storage is busy; retry shortly", 0)
				end
				task.wait(STORAGE_POLL_SECONDS)
			end
			local generation = Flusher.generation()
			local day = Recorder.today()
			local extra = Recorder.unsavedCopy()
			local plan, loaded = activeStore.loadRange(range, day, extra, progress)
			if generation == Flusher.generation() and not Flusher.isFlushing() then
				local summary =
					AnalyticsLogic.summarize(range, plan, day, loaded, Reports.labelOf, os.time(), ReportSections.build)
				AnalyticsRaw.remember(range, summary, loaded.totals)
				return summary
			end
			-- A flush overlapped our reads: discard the result and the caches it filled.
			activeStore.clearCaches()
		end
		error("Analytics changed during report loading; retry shortly", 0)
	end)
	if not ok then
		activeStore.clearCaches()
	end
	reportLoading = false
	if not ok then
		error(tostring(result), 0)
	end
	return result
end

-- Sends one payload to a waiting admin (re-checking rights at send time).
local function reply(waiter: Waiter, payload: Payload)
	local player = waiter.player
	if player == nil or player.Parent ~= Players then
		return
	end
	if payload.ok and not AnalyticsAuth.isAdmin(player) then
		return
	end
	Remotes.fireClient("AnalyticsReport", player, waiter.requestId, payload)
end

-- Runs (or joins) the load job of a range; returns the finished payload. Yields.
local function loadShared(range: AnalyticsConfig.Range, waiter: Waiter): Payload
	local rangeName: string = range
	local cached = summaryCache[range]
	if cached ~= nil and os.clock() - cached.at < AnalyticsConfig.CacheSeconds then
		return { ok = true, code = "Ok", range = rangeName, summary = cached.summary }
	end
	local job = jobs[range]
	if job ~= nil then
		table.insert(job.waiters, waiter)
		return coroutine.yield() :: Payload
	end
	local newJob: Job = { waiters = {}, done = 0, total = 0, progressAt = 0 }
	jobs[range] = newJob
	local ok, result = pcall(Reports.summaryAsync, range, function(done: number, total: number)
		newJob.done, newJob.total = done, total
		if os.clock() - newJob.progressAt >= 0.5 then
			newJob.progressAt = os.clock()
			local progressPayload: Payload =
				{ ok = true, code = "Loading", range = rangeName, done = done, total = total }
			reply(waiter, progressPayload)
			for _, other in newJob.waiters do
				reply(other, progressPayload)
			end
		end
	end)
	jobs[range] = nil
	if ok then
		summaryCache[range] = { at = os.clock(), summary = result }
	else
		Recorder.warn("summary", tostring(result))
	end
	local payload: Payload = if ok
		then { ok = true, code = "Ok", range = rangeName, summary = result }
		else { ok = false, code = "Error", range = rangeName }
	for _, other in newJob.waiters do
		task.spawn(other.thread, payload)
	end
	return payload
end

--[[
	Handles one AnalyticsRequest: rate limit → validation → authorization → shared load. Yields.
	@return the final payload (also used by tests)
]]
function Reports.requestAsync(player: Player, rawRequestId: unknown, rawRange: unknown): Payload
	if not requestLimiter:Allow(player.UserId) then
		return { ok = false, code = "RateLimited" }
	end
	local requestId = Validate.requestId(rawRequestId)
	local range = Validate.oneOf(rawRange, AnalyticsConfig.Ranges)
	if requestId == nil or range == nil then
		return { ok = false, code = "BadRequest" }
	end
	if not AnalyticsAuth.isAuthorizedAsync(player) then
		-- One shared throttle key: a per-UserId key would grow the warn table for every visitor.
		Recorder.warn("denied", `analytics request refused for non-admin {player.UserId}`)
		return { ok = false, code = "NotAuthorized", range = range }
	end
	return loadShared(range, { player = player, requestId = requestId, thread = coroutine.running() })
end

-- Remote entry: run the request on its own thread and send the final payload.
local function onRequest(player: Player, rawRequestId: unknown, rawRange: unknown)
	local requestId = Validate.requestId(rawRequestId)
	local payload = Reports.requestAsync(player, rawRequestId, rawRange)
	if requestId ~= nil and player.Parent == Players then
		if payload.ok and not AnalyticsAuth.isAdmin(player) then
			return -- rights revoked while loading
		end
		Remotes.fireClient("AnalyticsReport", player, requestId, payload)
	end
end

--[[ Wires the admin remotes (AnalyticsRequest + the RAW pages). Called once from Start. ]]
function Reports.start()
	Remotes.onServerEvent("AnalyticsRequest", function(player: Player, rawRequestId: unknown, rawRange: unknown)
		task.spawn(function()
			local ok, err = pcall(onRequest, player, rawRequestId, rawRange)
			if not ok then
				Recorder.warn("request", tostring(err))
			end
		end)
	end)
	AnalyticsRaw.start({
		isAuthorizedAsync = function(caller: AnalyticsRaw.Caller): boolean
			local player = caller.player
			return player ~= nil and AnalyticsAuth.isAuthorizedAsync(player)
		end,
		isAdmin = AnalyticsAuth.isAdmin,
	})
end

--[[ Drops a departing player's request bucket. ]]
function Reports.forget(player: Player)
	requestLimiter:Forget(player.UserId)
end

--[[ Clears the shared summary cache (tests / after a manual data repair). ]]
function Reports.clearCache()
	table.clear(summaryCache)
end

return table.freeze(Reports)
