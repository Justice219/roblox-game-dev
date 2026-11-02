--!strict
--[[
	HappyHourOverrideStore — keeps the Happy Hour admin override (force / stop / skip / kill switch)
	identical on EVERY server (owner R89 §2, docs/happy-hours.md).

	Why: the schedule itself needs no network (pure UTC maths in Shared/Events/HappyHourLogic), but
	when the owner presses FORCE / STOP / SKIP / KILL on one server, all servers must follow.

	How (all optional and failure-tolerant — Studio without API access just runs this server):
		1. DataStore `HappyHourConfig.Override.StoreName` key `StoreKey` holds the current override.
		   An admin change runs INSIDE UpdateAsync on the latest stored value (two admins on two
		   servers never overwrite each other) with version = max(stored.v + 1, now in ms).
		2. MessagingService topic `Topic` fans the new override out at once (one PublishAsync per
		   admin change; the payload is the small encoded override).
		3. Every server loads the stored override at boot and re-reads it every PollSeconds (a
		   missed message heals within ~90 s). A newly loaded / received override is applied only
		   when its version is higher than the one this server runs.
		Studio uses "<name>_Studio" for both the store and the topic, so a Studio test never
		changes live servers.

	Security: only HappyHourService's audited admin commands call `apply`; everything read back
	(DataStore value, message payload) is size-checked and passed through HappyHourLogic.sanitize
	(known ids, finite numbers, bounded arrays) before use.

	Performance: one GetAsync per PollSeconds per server (budget-checked), one UpdateAsync +
	one PublishAsync per admin action, nothing per player.

	API (HappyHourService is the only caller):
		start(onChange)                 subscribe + initial load + poll loop; onChange(override, source)
		current() -> Override           the override this server runs
		apply(edit, now) -> (Override, persisted)
		                                edit(base, version) -> Override?; runs on the latest stored
		                                value, then publishes; falls back to local-only on failure
		status() -> { ... }             store / messaging health (admin status line)

	Example:
		HappyHourOverrideStore.start(function(o, source) HappyHourLogic.setOverride(o) end)
		HappyHourOverrideStore.apply(function(base, v) return HappyHourLogic.withKill(base, true, now, v) end, now)
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local HappyHourConfig = require(ReplicatedStorage.Shared.Config.HappyHourConfig)
local HappyHourLogic = require(ReplicatedStorage.Shared.Events.HappyHourLogic)

type Override = HappyHourLogic.Override
export type Source = "boot" | "poll" | "message" | "admin"
export type Edit = (base: Override, version: number) -> Override?

local Limits = HappyHourConfig.Override
local SUFFIX = if RunService:IsStudio() then "_Studio" else ""
local STORE_NAME = Limits.StoreName .. SUFFIX
local TOPIC = Limits.Topic .. SUFFIX

local HappyHourOverrideStore = {}

local current: Override = HappyHourLogic.emptyOverride()
local listener: ((override: Override, source: Source) -> ())? = nil
local started = false
local store: DataStore? = nil
local storeFailed = false
-- Health counters for the admin status line.
local health =
	{ loads = 0, loadErrors = 0, writes = 0, writeErrors = 0, published = 0, publishErrors = 0, received = 0 }
local subscribed = false

-- Unix time in milliseconds (version source).
local function nowMillis(): number
	return DateTime.now().UnixTimestampMillis
end

-- The override DataStore, or nil when DataStoreService is unavailable (Studio without access).
local function storeOf(): DataStore?
	if store ~= nil or storeFailed then
		return store
	end
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = result
	else
		storeFailed = true
		warn(`[HappyHour] override DataStore unavailable ({result}); admin overrides stay on this server`)
	end
	return store
end

-- True when the DataStore budget allows one request of `kind` right now (never waits).
local function hasBudget(kind: Enum.DataStoreRequestType): boolean
	local ok, budget = pcall(function()
		return DataStoreService:GetRequestBudgetForRequestType(kind)
	end)
	return not ok or budget > 0
end

--[[
	Adopts `override` when it is newer than the one this server runs; tells the listener.
	@return true when adopted
]]
local function adopt(raw: unknown, source: Source): boolean
	local override = HappyHourLogic.sanitize(raw)
	if override == nil or override.v <= current.v then
		return false
	end
	current = override
	local callback = listener
	if callback ~= nil then
		local ok, err = pcall(callback, override, source)
		if not ok then
			warn(`[HappyHour] override listener failed: {err}`)
		end
	end
	return true
end

-- Decodes a message / store string with the size bound first.
local function decode(raw: unknown): unknown
	if type(raw) == "table" then
		return raw
	end
	if type(raw) ~= "string" or #raw > Limits.MaxWireBytes then
		return nil
	end
	local ok, value = pcall(HttpService.JSONDecode, HttpService, raw)
	return if ok then value else nil
end

-- Reads the stored override once (boot / poll). Yields.
local function load(source: Source)
	local target = storeOf()
	if target == nil or not hasBudget(Enum.DataStoreRequestType.GetAsync) then
		return
	end
	local ok, value = pcall(function()
		return (target :: DataStore):GetAsync(Limits.StoreKey)
	end)
	if ok then
		health.loads += 1
		adopt(decode(value), source)
	else
		health.loadErrors += 1
	end
end

-- Publishes an override to every server (best effort). Yields.
local function publish(override: Override)
	local encoded = HttpService:JSONEncode(HappyHourLogic.encode(override))
	if #encoded > Limits.MaxWireBytes then
		warn("[HappyHour] override too large to publish")
		return
	end
	local ok, err = pcall(function()
		MessagingService:PublishAsync(TOPIC, encoded)
	end)
	if ok then
		health.published += 1
	else
		health.publishErrors += 1
		warn(`[HappyHour] override publish failed ({err}); other servers catch up on their next poll`)
	end
end

--[[
	Starts the store: subscribes to the topic, loads the stored override and polls every
	PollSeconds (all in background threads; returns at once). Idempotent.
	@param onChange called with every newer override adopted (boot / poll / message / admin)
]]
function HappyHourOverrideStore.start(onChange: (override: Override, source: Source) -> ())
	listener = onChange
	if started then
		return
	end
	started = true
	task.spawn(function()
		local ok, err = pcall(function()
			MessagingService:SubscribeAsync(TOPIC, function(message: any)
				health.received += 1
				local data = if type(message) == "table" then message.Data else nil
				adopt(decode(data), "message")
			end)
		end)
		subscribed = ok
		if not ok then
			warn(`[HappyHour] MessagingService subscribe failed ({err}); overrides arrive by polling`)
		end
	end)
	task.spawn(function()
		load("boot")
		while true do
			task.wait(Limits.PollSeconds)
			load("poll")
		end
	end)
end

--[[ The override this server runs right now. ]]
function HappyHourOverrideStore.current(): Override
	return current
end

--[[
	Applies an admin edit everywhere. The edit runs inside UpdateAsync on the newest stored
	override (or on this server's copy when the store is unavailable / failed), with a version
	that is always higher than both. The result is adopted here at once, then published.
	Yields (DataStore + MessagingService).
	@param edit (base, version) -> new override, or nil to refuse (nothing changes)
	@param now  unix seconds (prune base)
	@return (the override now in force here, true when it was persisted to the DataStore)
]]
function HappyHourOverrideStore.apply(edit: Edit, now: number): (Override, boolean)
	local result: Override? = nil
	local persisted = false
	local target = storeOf()
	if target ~= nil and hasBudget(Enum.DataStoreRequestType.UpdateAsync) then
		local ok = pcall(function()
			(target :: DataStore):UpdateAsync(Limits.StoreKey, function(old: any): any
				local stored = HappyHourLogic.sanitize(decode(old))
				local base = current
				if stored ~= nil and stored.v > base.v then
					base = stored
				end
				local version = math.max(base.v + 1, nowMillis())
				local edited = edit(HappyHourLogic.prune(base, now), version)
				result = edited
				if edited == nil then
					return nil -- refused: keep the stored value
				end
				return HappyHourLogic.encode(edited)
			end)
		end)
		if ok then
			persisted = result ~= nil
			health.writes += 1
		else
			health.writeErrors += 1
			result = nil
		end
	end
	if not persisted and result == nil then
		-- Local fallback (no store / write failed): this server, then the topic.
		result = edit(HappyHourLogic.prune(current, now), math.max(current.v + 1, nowMillis()))
	end
	local final = result
	if final == nil then
		return current, false
	end
	adopt(final, "admin")
	task.spawn(publish, final)
	return current, persisted
end

--[[ Store / messaging health for the admin status line. ]]
function HappyHourOverrideStore.status(): { [string]: any }
	return {
		store = if storeFailed then "unavailable" else STORE_NAME,
		topic = TOPIC,
		subscribed = subscribed,
		version = current.v,
		loads = health.loads,
		loadErrors = health.loadErrors,
		writes = health.writes,
		writeErrors = health.writeErrors,
		published = health.published,
		publishErrors = health.publishErrors,
		received = health.received,
	}
end

return HappyHourOverrideStore
