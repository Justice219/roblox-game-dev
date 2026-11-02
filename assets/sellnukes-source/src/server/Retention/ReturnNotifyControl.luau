--!strict
--[[
	ReturnNotifyControl — the universe-wide switches of the return notifications (owner R122
	§2.3 admin "kill switch, per-kind on/off"): one control { v, on, off = { kind } } that EVERY
	server runs, so the kill switch really stops every sender (each server polls the shared queue).

	How (same pattern as Server/HappyHour/HappyHourOverrideStore; all failure-tolerant):
		1. DataStore NotifyConfig.Control.StoreName, key StoreKey, holds the control. An admin edit
		   runs INSIDE UpdateAsync on the newest stored value (two admins on two servers never
		   overwrite each other) with version = max(stored.v + 1, now in ms).
		2. MessagingService topic Topic fans it out at once (one PublishAsync per edit).
		3. Every server loads it at boot and re-reads it every PollSeconds (a missed message heals).
		   A control is adopted only when its version is higher than the one this server runs.
		Studio uses "<name>_Studio" for the store and the topic, so a Studio test never switches
		live servers. Nothing stored = everything ON (ReturnNotifyLogic.defaultControl).
	The control this server runs is mirrored into ReplicatedStorage attributes
	(NotifyConfig.Attributes) for the admin panel's notifications section (display only).

	Security: only ReturnNotifyAdmin's audited admin commands call `apply`; everything read back
	(DataStore value, message payload) is size-checked and sanitised (ReturnNotifyLogic.
	sanitizeControl) before use.

	Performance: one GetAsync per PollSeconds per server (budget-checked), one UpdateAsync + one
	PublishAsync per admin edit; nothing per player.

	API:
		start()                        subscribe + boot load + poll loop (background; idempotent)
		current() -> Control           the control this server runs (never yields)
		apply(edit) -> (Control, persisted)   edit(base, version) -> Control?; yields
		health() -> { ... }            store / messaging health (admin status)

	Connects to: Server/Retention/ReturnNotifyLogic, Shared/Config/NotifyConfig; used by
	ReturnNotifyService / ReturnNotifyAdmin.

	Example:
		ReturnNotifyControl.start()
		ReturnNotifyControl.apply(function(base, v) return ReturnNotifyLogic.withOn(base, false, v) end)
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local NotifyConfig = require(ReplicatedStorage.Shared.Config.NotifyConfig)
local ReturnNotifyLogic = require(script.Parent.ReturnNotifyLogic)

type Control = ReturnNotifyLogic.Control
export type Edit = (base: Control, version: number) -> Control?

local Limits = NotifyConfig.Control
local SUFFIX = if RunService:IsStudio() then "_Studio" else ""
local STORE_NAME = Limits.StoreName .. SUFFIX
local TOPIC = Limits.Topic .. SUFFIX

local ReturnNotifyControl = {}

local current: Control = ReturnNotifyLogic.defaultControl()
local started = false
local store: DataStore? = nil
local storeFailed = false
local subscribed = false
-- Health counters for the admin status.
local health = { loads = 0, loadErrors = 0, writes = 0, writeErrors = 0, published = 0, publishErrors = 0 }

-- Unix time in milliseconds (version source).
local function nowMillis(): number
	return DateTime.now().UnixTimestampMillis
end

-- Mirrors the running control into the ReplicatedStorage display attributes.
local function publishAttributes()
	for name, value in ReturnNotifyLogic.controlAttributes(current) do
		ReplicatedStorage:SetAttribute(name, value)
	end
end

-- The control DataStore, or nil when DataStoreService is unavailable (Studio without access).
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
		warn(`[ReturnNotify] control DataStore unavailable ({result}); switches stay on this server`)
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

-- Decodes a stored / message value with the size bound first.
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

-- Adopts a newer control. @return true when adopted
local function adopt(raw: unknown): boolean
	local control = ReturnNotifyLogic.sanitizeControl(raw)
	if control == nil or control.v <= current.v then
		return false
	end
	current = control
	publishAttributes()
	return true
end

-- Reads the stored control once (boot / poll). Yields.
local function load()
	local target = storeOf()
	if target == nil or not hasBudget(Enum.DataStoreRequestType.GetAsync) then
		return
	end
	local ok, value = pcall(function()
		return (target :: DataStore):GetAsync(Limits.StoreKey)
	end)
	if ok then
		health.loads += 1
		adopt(decode(value))
	else
		health.loadErrors += 1
	end
end

-- Publishes a control to every server (best effort). Yields.
local function publish(control: Control)
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, ReturnNotifyLogic.encodeControl(control))
	if not ok or #encoded > Limits.MaxWireBytes then
		return
	end
	local sent, err = pcall(function()
		MessagingService:PublishAsync(TOPIC, encoded)
	end)
	if sent then
		health.published += 1
	else
		health.publishErrors += 1
		warn(`[ReturnNotify] control publish failed ({err}); other servers catch up on their next poll`)
	end
end

--[[ Starts the store (subscribe + boot load + poll loop, in background threads). Idempotent. ]]
function ReturnNotifyControl.start()
	if started then
		return
	end
	started = true
	publishAttributes()
	task.spawn(function()
		local ok, err = pcall(function()
			MessagingService:SubscribeAsync(TOPIC, function(message: any)
				local data = if type(message) == "table" then message.Data else nil
				adopt(decode(data))
			end)
		end)
		subscribed = ok
		if not ok then
			warn(`[ReturnNotify] MessagingService subscribe failed ({err}); switches arrive by polling`)
		end
	end)
	task.spawn(function()
		load()
		while true do
			task.wait(Limits.PollSeconds)
			load()
		end
	end)
end

--[[ The control this server runs right now (never yields). ]]
function ReturnNotifyControl.current(): Control
	return current
end

--[[
	Applies an admin edit everywhere: inside UpdateAsync on the newest stored control (or this
	server's copy when the store is unavailable), version above both; adopted here at once, then
	published. Yields.
	@param edit (base, version) -> new control, or nil to refuse
	@return (control now in force here, persisted to the DataStore)
]]
function ReturnNotifyControl.apply(edit: Edit): (Control, boolean)
	local result: Control? = nil
	local persisted = false
	local target = storeOf()
	if target ~= nil and hasBudget(Enum.DataStoreRequestType.UpdateAsync) then
		local ok = pcall(function()
			(target :: DataStore):UpdateAsync(Limits.StoreKey, function(old: any): any
				local stored = ReturnNotifyLogic.sanitizeControl(decode(old))
				local base = current
				if stored ~= nil and stored.v > base.v then
					base = stored
				end
				local edited = edit(base, math.max(base.v + 1, nowMillis()))
				result = edited
				if edited == nil then
					return nil
				end
				return ReturnNotifyLogic.encodeControl(edited)
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
		result = edit(current, math.max(current.v + 1, nowMillis()))
	end
	local final = result
	if final == nil then
		return current, false
	end
	adopt(ReturnNotifyLogic.encodeControl(final))
	task.spawn(publish, final)
	return current, persisted
end

--[[ Store / messaging health for the admin status. ]]
function ReturnNotifyControl.health(): { [string]: any }
	return {
		store = if storeFailed then "unavailable" else STORE_NAME,
		subscribed = subscribed,
		version = current.v,
		loads = health.loads,
		loadErrors = health.loadErrors,
		writes = health.writes,
		writeErrors = health.writeErrors,
		published = health.published,
		publishErrors = health.publishErrors,
	}
end

return ReturnNotifyControl
