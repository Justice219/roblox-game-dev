--!strict
--[[
	AnalyticsRaw — COPY RAW DATA: every counter of an analytics range, uncapped, page by page.

	Purpose (2026-10-23 analytics fix list W1.12, C50):
		The COPY FOR AI report has to fit ReportMaxChars (130,000 characters), so on a busy day it
		cannot carry every raw counter (2,135 on 2026-10-23, many more over 7 / 30 days). The
		summary payload is capped too (ReportSummaryKeys). This module keeps the UNCAPPED totals
		behind every summary the server builds and hands them to admins in pages of at most
		AnalyticsConfig.Raw.PageChars JSON characters, so "omitted" is always 0 for RAW DATA.

	How it connects:
		AnalyticsService.summaryAsync → AnalyticsLogic.summarize → AnalyticsRaw.remember(range,
		summary, loaded.totals): stores a snapshot and stamps `summary.rawId`.
		Client (Screens/AnalyticsExport, opened by Admin/AnalyticsTab's COPY RAW DATA) →
		AnalyticsRawRequest(requestId, rawId, page) → pageAsync (token bucket → Validate →
		AdminService.isAuthorizedAsync → snapshot lookup → AnalyticsReport.rawIndex / rawPage) →
		AnalyticsRawPage(requestId, { ok, code, page? }) after an isAdmin re-check.

	Snapshots: at most Raw.KeepPerRange per range (2: a newer summary of the same range, from a
	second admin or a REFRESH after CacheSeconds, never cuts off an export already running; the
	oldest of a range goes first), at most Raw.MaxSnapshots in all (8 = 4 ranges x 2) and none
	older than Raw.KeepSeconds. One pending task.delay frees each snapshot when it expires, so an
	ALL TIME snapshot (tens of thousands of keys) leaves memory on time even when no admin acts
	again. Each holds a reference to its totals (AnalyticsStore.loadRange builds a fresh table per
	load and summarize never mutates it) and lazily its page index (built on the first page
	request).

	Security: admins only (isAuthorizedAsync on every request, isAdmin again before replying);
	ids and page numbers are Validate.integer-checked; per-admin token bucket (Raw.Burst /
	Raw.PerSecond); payloads hold aggregate counters only (no names, no user ids). Codes:
	"Ok" | "RateLimited" | "BadRequest" | "NotAuthorized" | "Expired" (snapshot gone: REFRESH).

	Example:
		AnalyticsRaw.remember("today", summary, loaded.totals)        -- summary.rawId = 7
		local payload = AnalyticsRaw.pageAsync(caller, 1, summary.rawId, 1)
		-- payload.ok, payload.page.pages, payload.page.counters.core["dau"] ...
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnalyticsConfig = require(ReplicatedStorage.Shared.Config.AnalyticsConfig)
local AnalyticsReport = require(ReplicatedStorage.Shared.Analytics.AnalyticsReport)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Validate = require(ReplicatedStorage.Shared.Net.Validate)

-- The caller of a page request (same shape as AnalyticsService.Caller; tests pass player = nil).
export type Caller = { userId: number, name: string, player: Player? }

-- Admin checks, injected by AnalyticsService.Start (AdminService requires services that require
-- AnalyticsService, so this module never requires it directly).
export type Deps = {
	isAuthorizedAsync: (caller: Caller) -> boolean,
	isAdmin: (player: Player) -> boolean,
}

-- Reply to one AnalyticsRawRequest.
export type Payload = {
	ok: boolean,
	code: string, -- "Ok" | "RateLimited" | "BadRequest" | "NotAuthorized" | "Expired"
	page: AnalyticsReport.RawPage?,
}

type Snapshot = {
	meta: AnalyticsReport.RawMeta,
	at: number, -- os.clock() when its summary was built
	totals: AnalyticsReport.FamilyCounters,
	index: AnalyticsReport.RawIndex?, -- built on the first page request
}

local MAX_ID = 2 ^ 31 - 1
-- The expiry timer fires this long after the oldest snapshot's KeepSeconds ends (prune needs
-- "older than", and os.clock / task.delay timing differ by a frame or so).
local PRUNE_SLACK_SECONDS = 1

local AnalyticsRaw = {}

local snapshots: { [number]: Snapshot } = {}
local byRange: { [string]: { number } } = {} -- snapshot ids of each range, oldest first
local held = 0 -- snapshots in `snapshots`
local nextId = 0
local limiter = RateLimiter.new(AnalyticsConfig.Raw.Burst, AnalyticsConfig.Raw.PerSecond)
local deps: Deps? = nil
local started = false
local pruneThread: thread? = nil -- the one pending expiry timer (nil = none scheduled)

-- Forgets one snapshot and its range slot (no-op for an unknown id).
local function forget(id: number)
	local snapshot = snapshots[id]
	if snapshot == nil then
		return
	end
	snapshots[id] = nil
	held -= 1
	local range = snapshot.meta.range
	local ids = byRange[range]
	if ids ~= nil then
		local at = table.find(ids, id)
		if at ~= nil then
			table.remove(ids, at)
		end
		if #ids == 0 then
			byRange[range] = nil
		end
	end
end

-- Forgets snapshots older than Raw.KeepSeconds (at most MaxSnapshots entries to scan).
local function prune(now: number)
	for id, snapshot in snapshots do
		if now - snapshot.at > AnalyticsConfig.Raw.KeepSeconds then
			forget(id)
		end
	end
end

-- The id of the oldest snapshot held (nil when none): the one MaxSnapshots evicts first.
local function oldestId(): number?
	local bestId: number? = nil
	local bestAt = math.huge
	for id, snapshot in snapshots do
		if snapshot.at < bestAt then
			bestId = id
			bestAt = snapshot.at
		end
	end
	return bestId
end

--[[
	Schedules the expiry timer: ONE pending task.delay at a time, set to fire just after the
	oldest snapshot expires. When it fires it prunes and re-schedules for the next oldest, so
	every snapshot leaves memory about KeepSeconds after it was built, with no admin traffic
	(prune inside remember / pageAsync alone kept an expired ALL TIME snapshot until the next
	admin action). New snapshots are always the newest, so the pending timer stays correct.
]]
local function schedulePrune()
	if pruneThread ~= nil then
		return
	end
	local oldest = oldestId()
	if oldest == nil then
		return
	end
	local expiresIn = snapshots[oldest].at + AnalyticsConfig.Raw.KeepSeconds - os.clock()
	pruneThread = task.delay(math.max(0, expiresIn) + PRUNE_SLACK_SECONDS, function()
		pruneThread = nil
		prune(os.clock())
		schedulePrune()
	end)
end

--[[
	Keeps the uncapped totals behind a summary readable for COPY RAW DATA and stamps the summary
	with the snapshot id (`summary.rawId`, sent to the admin with the summary). A range keeps its
	Raw.KeepPerRange newest snapshots (an older export keeps working until its own KeepSeconds
	end), Raw.MaxSnapshots in all; past either cap the oldest goes. Starts the expiry timer.
	Never yields; O(MaxSnapshots) (pages are built lazily).
	@param range    the summary's range id ("today" | "7d" | "30d" | "all")
	@param summary  the summary just built from `totals`
	@param totals   AnalyticsStore.loadRange's totals (every family, uncapped)
	@return the snapshot id (1 .. 2^31 - 1)
]]
function AnalyticsRaw.remember(
	range: string,
	summary: AnalyticsReport.Summary,
	totals: AnalyticsReport.FamilyCounters
): number
	local now = os.clock()
	prune(now)
	-- Ids wrap inside the remote's validated range (2^31 - 1 summaries is decades of reports).
	nextId = (nextId % (MAX_ID - 1)) + 1
	forget(nextId) -- only after a wrap: an id is never shared
	snapshots[nextId] = {
		meta = {
			rawId = nextId,
			range = range,
			from = summary.from,
			to = summary.to,
			generatedAt = summary.generatedAt,
			source = summary.source,
			partial = summary.partial,
			exporterVersion = summary.exporterVersion,
			windowComplete = summary.windowComplete,
			openDayElapsedSeconds = summary.openDayElapsedSeconds,
		},
		at = now,
		totals = totals,
		index = nil,
	}
	held += 1
	local ids = byRange[range]
	if ids == nil then
		ids = {}
		byRange[range] = ids
	end
	table.insert(ids, nextId)
	-- Per-range cap, then the overall cap: the oldest snapshot goes first.
	while #ids > AnalyticsConfig.Raw.KeepPerRange do
		forget(ids[1])
	end
	while held > AnalyticsConfig.Raw.MaxSnapshots do
		local oldest = oldestId()
		if oldest == nil then
			break
		end
		forget(oldest)
	end
	schedulePrune()
	summary.rawId = nextId
	return nextId
end

--[[
	Serves one RAW page to an authorized admin. Order: token bucket (cheapest first), argument
	validation, AdminService.isAuthorizedAsync (the full check, every time), snapshot lookup.
	Yields (authorization). Also used by tests with fake callers.
	@param caller          the requester (its userId keys the token bucket)
	@param rawRequestId    client request id (integer 1 .. 2^31 - 1)
	@param rawSnapshotId   summary.rawId (integer 1 .. 2^31 - 1)
	@param rawPage         page number (integer 1 .. Raw.MaxPages)
	@return Payload ("Expired" when the snapshot is gone: the admin presses REFRESH)
]]
function AnalyticsRaw.pageAsync(
	caller: Caller,
	rawRequestId: unknown,
	rawSnapshotId: unknown,
	rawPage: unknown
): Payload
	if not limiter:Allow(caller.userId) then
		return { ok = false, code = "RateLimited" }
	end
	local requestId = Validate.integer(rawRequestId, 1, MAX_ID)
	local snapshotId = Validate.integer(rawSnapshotId, 1, MAX_ID)
	local page = Validate.integer(rawPage, 1, AnalyticsConfig.Raw.MaxPages)
	if requestId == nil or snapshotId == nil or page == nil then
		return { ok = false, code = "BadRequest" }
	end
	local current = deps
	if current == nil or not current.isAuthorizedAsync(caller) then
		return { ok = false, code = "NotAuthorized" }
	end
	prune(os.clock())
	local snapshot = snapshots[snapshotId]
	if snapshot == nil then
		return { ok = false, code = "Expired" }
	end
	local index = snapshot.index
	if index == nil then
		index = AnalyticsReport.rawIndex(snapshot.totals, AnalyticsConfig.Raw.PageChars, AnalyticsConfig.Raw.MaxPages)
		snapshot.index = index
	end
	local built = AnalyticsReport.rawPage(index :: AnalyticsReport.RawIndex, snapshot.totals, page, snapshot.meta)
	if built == nil then
		return { ok = false, code = "BadRequest" }
	end
	return { ok = true, code = "Ok", page = built }
end

-- Remote entry (own thread): serve the page, re-check rights, reply.
local function onRequest(player: Player, rawRequestId: unknown, rawSnapshotId: unknown, rawPage: unknown)
	local requestId = Validate.integer(rawRequestId, 1, MAX_ID)
	local payload = AnalyticsRaw.pageAsync(
		{ userId = player.UserId, name = player.Name, player = player },
		rawRequestId,
		rawSnapshotId,
		rawPage
	)
	if requestId == nil or player.Parent ~= Players then
		return
	end
	local current = deps
	if payload.ok and (current == nil or not current.isAdmin(player)) then
		return -- rights revoked while loading
	end
	Remotes.fireClient("AnalyticsRawPage", player, requestId, payload)
end

--[[
	Wires the AnalyticsRawRequest remote (once; AnalyticsService.Start calls it after its
	dependencies resolve). Each request runs on its own thread: authorization yields.
	@param newDeps  the admin checks (AdminService.isAuthorizedAsync / isAdmin)
]]
function AnalyticsRaw.start(newDeps: Deps)
	deps = newDeps
	if started then
		return
	end
	started = true
	Remotes.onServerEvent(
		"AnalyticsRawRequest",
		function(player: Player, rawRequestId: unknown, rawSnapshotId: unknown, rawPage: unknown)
			task.spawn(function()
				local ok, err = pcall(onRequest, player, rawRequestId, rawSnapshotId, rawPage)
				if not ok then
					warn(`[AnalyticsRaw] request: {err}`)
				end
			end)
		end
	)
	Players.PlayerRemoving:Connect(function(player: Player)
		limiter:Forget(player.UserId)
	end)
end

--[[
	Tests: forgets every snapshot (a swapped analytics backend must not serve live totals) and
	cancels the expiry timer.
]]
function AnalyticsRaw.clear()
	table.clear(snapshots)
	table.clear(byRange)
	held = 0
	local thread = pruneThread
	pruneThread = nil
	if thread ~= nil then
		task.cancel(thread)
	end
end

--[[ Tests: how many snapshots are held (bounded: Raw.KeepPerRange per range, Raw.MaxSnapshots). ]]
function AnalyticsRaw.count(): number
	return held
end

--[[ Tests: whether the expiry timer is pending (one task.delay at most, only while snapshots exist). ]]
function AnalyticsRaw.timerPending(): boolean
	return pruneThread ~= nil
end

return table.freeze(AnalyticsRaw)
