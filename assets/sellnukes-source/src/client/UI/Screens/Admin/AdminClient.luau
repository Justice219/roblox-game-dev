--!strict
--[[
	AdminClient — the admin panel's client-side store: the latest AdminState from the server, the
	command catalogue, the audit log, command sending and command results.

	Why a store: every admin tab (Players, Economy, Server, World, Live, Log, New Player) reads the
	same pushed state. This module listens to the two admin remotes ONCE, merges the partial pushes
	(the server only sends `log` / `catalog` when they changed), and fires `Changed` so open tabs
	re-render. Nothing here is trusted by the server: the panel only sends command INTENTS
	(`AdminCommand(name, args)`), which the server re-authorises and re-validates on every call.

	Server payloads (shapes: Shared/Config/AdminConfig wire types; producer: Server/Admin/AdminState):
		AdminState  { isAdmin = true, serverTime, isStudio, stats, players, recentBans, logVersion,
		              log?, catalogVersion, catalog?, availability?, playerWorlds }
		              or  { isAdmin = false }
		              (R57: stats.worlds = players per world; playerWorlds["<userId>"] = the
		              player's current world + each extra world's unlocked / cash / area / rebirths)
		AdminResult { seq, ok, name, text }  (to the caller only, after each command)

	API:
		AdminClient.start()                     connect the remotes (idempotent; UI boot calls it)
		AdminClient.state                       latest merged State (nil until the first push)
		AdminClient.Changed: Signal<State>      after every push
		AdminClient.Result: Signal<ResultPayload> after every command result
		AdminClient.isAdmin(): boolean          the latest server verdict (display only)
		AdminClient.send(name, args?)           fire AdminCommand (client-side throttle: 8 / s)
		AdminClient.commandsFor(tab)            catalogue commands of a tab, sorted
		AdminClient.command(name)               one CommandInfo or nil
		AdminClient.unavailable(name)           nil = usable; else the reason ("needs Tycoon ...")
		AdminClient.player(userId)              one PlayerRow or nil
		AdminClient.playerWorlds(userId)        R57: { world, worlds = { [id] = WorldColumns } } or nil

	Example:
		AdminClient.start()
		AdminClient.Changed:Connect(function(state) render(state.players) end)
		AdminClient.send("GrantGems", { userId = 123, amount = 100 })
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AdminConfig = require(ReplicatedStorage.Shared.Config.AdminConfig)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

export type CommandInfo = AdminConfig.CommandInfo
export type PlayerRow = AdminConfig.PlayerRow
export type AuditEntry = AdminConfig.AuditEntry
export type ResultPayload = AdminConfig.ResultPayload
export type RecentBan = AdminConfig.RecentBan

-- Server stats block (AdminState.stats). Every field is a number unless noted.
export type Stats = {
	players: number,
	maxPlayers: number,
	fps: number,
	heartbeatMs: number,
	physicsFps: number,
	memoryMb: number,
	uptime: number,
	instanceCount: number,
	sendKbps: number,
	receiveKbps: number,
	avgPingMs: number,
	timeOfDay: number,
	shutdownAt: number,
	serverBoostSeconds: number,
	savingEnabled: boolean,
	forwardSent: number,
	forwardDropped: number,
	forwardFailed: number,
	systemsMs: { [string]: number },
	jobId: string,
	placeVersion: number,
	worlds: { [string]: number }, -- R57: players per world id (Player attribute CurrentWorld)
}

-- R57: one extra world's columns of a player (Players list / detail header).
export type WorldColumns = { unlocked: boolean, cash: number, area: number, rebirths: number }
-- R57: the world a player is in + their extra worlds' columns.
export type PlayerWorlds = { world: string, worlds: { [string]: WorldColumns } }

export type State = {
	serverTime: number,
	receivedAt: number, -- os.clock() when this push arrived (for "updated Xs ago")
	isStudio: boolean,
	stats: Stats,
	players: { PlayerRow },
	recentBans: { RecentBan },
	log: { AuditEntry },
	logVersion: number,
	catalog: { CommandInfo },
	catalogVersion: number,
	availability: { [string]: string },
	playerWorlds: { [number]: PlayerWorlds }, -- R57: by user id
}

local AdminClient = {}

AdminClient.state = nil :: State?
AdminClient.Changed = Signal.new() :: Signal.Signal<State>
AdminClient.Result = Signal.new() :: Signal.Signal<ResultPayload>
AdminClient.Revoked = Signal.new() :: Signal.Signal<>

-- Client-side send throttle (the server has its own token bucket; this only spares a stuck
-- button from spamming the remote).
local SEND_WINDOW = 1
local SEND_MAX = 8

local started = false
local admin = false
local sendTimes: { number } = {}
local byName: { [string]: CommandInfo } = {}

-- The stats block with safe defaults for any missing field.
local function parseStats(raw: unknown): Stats
	local t: { [string]: any } = if type(raw) == "table" then raw :: any else {}
	local function num(key: string): number
		local v = t[key]
		return if type(v) == "number" and v == v then v else 0
	end
	local systems: { [string]: number } = {}
	if type(t.systemsMs) == "table" then
		for key, value in t.systemsMs :: { [unknown]: unknown } do
			if type(key) == "string" and type(value) == "number" then
				systems[key] = value
			end
		end
	end
	-- R57 players per world: known-shaped entries only (ids ≤ 16 chars, finite whole counts).
	local worlds: { [string]: number } = {}
	if type(t.worlds) == "table" then
		for key, value in t.worlds :: { [unknown]: unknown } do
			if type(key) == "string" and #key <= 16 and type(value) == "number" and value == value and value >= 0 then
				worlds[key] = math.floor(value)
			end
		end
	end
	return {
		worlds = worlds,
		players = num("players"),
		maxPlayers = num("maxPlayers"),
		fps = num("fps"),
		heartbeatMs = num("heartbeatMs"),
		physicsFps = num("physicsFps"),
		memoryMb = num("memoryMb"),
		uptime = num("uptime"),
		instanceCount = num("instanceCount"),
		sendKbps = num("sendKbps"),
		receiveKbps = num("receiveKbps"),
		avgPingMs = num("avgPingMs"),
		timeOfDay = num("timeOfDay"),
		shutdownAt = num("shutdownAt"),
		serverBoostSeconds = num("serverBoostSeconds"),
		savingEnabled = t.savingEnabled == true,
		forwardSent = num("forwardSent"),
		forwardDropped = num("forwardDropped"),
		forwardFailed = num("forwardFailed"),
		systemsMs = systems,
		jobId = if type(t.jobId) == "string" then t.jobId else "",
		placeVersion = num("placeVersion"),
	}
end

-- A list field as an array (anything else → empty).
local function list(raw: unknown): { any }
	return if type(raw) == "table" then raw :: any else {}
end

-- A finite number or 0 (display only).
local function finiteOr0(value: unknown): number
	return if type(value) == "number"
			and value == value
			and value ~= math.huge
			and value ~= -math.huge
		then value
		else 0
end

--[[
	R57: playerWorlds["<userId>"] → { [userId] = PlayerWorlds }, every field type-checked (the
	payload is display-only, but a malformed one must never break the panel).
]]
local function parsePlayerWorlds(raw: unknown): { [number]: PlayerWorlds }
	local out: { [number]: PlayerWorlds } = {}
	if type(raw) ~= "table" then
		return out
	end
	for key, entry in raw :: { [unknown]: unknown } do
		local userId = if type(key) == "string" then tonumber(key) else nil
		if userId == nil or type(entry) ~= "table" then
			continue
		end
		local source = entry :: { [string]: any }
		local columns: { [string]: WorldColumns } = {}
		if type(source.worlds) == "table" then
			for worldId, row in source.worlds :: { [unknown]: unknown } do
				if type(worldId) == "string" and #worldId <= 16 and type(row) == "table" then
					local fields = row :: { [string]: any }
					columns[worldId] = {
						unlocked = fields.unlocked == true,
						cash = finiteOr0(fields.cash),
						area = finiteOr0(fields.area),
						rebirths = finiteOr0(fields.rebirths),
					}
				end
			end
		end
		out[userId] = {
			world = if type(source.world) == "string" and #source.world <= 16 then source.world else "main",
			worlds = columns,
		}
	end
	return out
end

-- Merges one AdminState push into the store and fires Changed.
local function onState(raw: unknown)
	if type(raw) ~= "table" then
		return
	end
	local payload = raw :: { [string]: any }
	if payload.isAdmin ~= true then
		admin = false
		AdminClient.state = nil
		table.clear(byName)
		AdminClient.Revoked:Fire()
		return
	end
	admin = true
	local previous = AdminClient.state
	local catalog: { CommandInfo } = if previous ~= nil then previous.catalog else {}
	local availability: { [string]: string } = if previous ~= nil then previous.availability else {}
	local catalogVersion = if previous ~= nil then previous.catalogVersion else -1
	if type(payload.catalog) == "table" then
		catalog = payload.catalog
		table.clear(byName)
		for _, info in catalog do
			if type(info) == "table" and type(info.name) == "string" then
				byName[info.name] = info
			end
		end
	end
	if type(payload.availability) == "table" then
		availability = payload.availability
	end
	if type(payload.catalogVersion) == "number" then
		catalogVersion = payload.catalogVersion
	end
	local log: { AuditEntry } = if previous ~= nil then previous.log else {}
	if type(payload.log) == "table" then
		log = payload.log
	end
	local state: State = {
		serverTime = if type(payload.serverTime) == "number" then payload.serverTime else 0,
		receivedAt = os.clock(),
		isStudio = payload.isStudio == true,
		stats = parseStats(payload.stats),
		players = list(payload.players),
		recentBans = list(payload.recentBans),
		log = log,
		logVersion = if type(payload.logVersion) == "number" then payload.logVersion else 0,
		catalog = catalog,
		catalogVersion = catalogVersion,
		availability = availability,
		playerWorlds = parsePlayerWorlds(payload.playerWorlds),
	}
	AdminClient.state = state
	AdminClient.Changed:Fire(state)
end

-- Validates and forwards one AdminResult.
local function onResult(raw: unknown)
	if type(raw) ~= "table" then
		return
	end
	local payload = raw :: { [string]: any }
	if type(payload.name) ~= "string" or type(payload.text) ~= "string" then
		return
	end
	AdminClient.Result:Fire({
		seq = if type(payload.seq) == "number" then payload.seq else 0,
		ok = payload.ok == true,
		name = payload.name,
		text = string.sub(payload.text, 1, 300),
	})
end

--[[ Connects the admin remotes once (safe to call from every admin screen's build). ]]
function AdminClient.start()
	if started then
		return
	end
	started = true
	Remotes.event("AdminState").OnClientEvent:Connect(onState)
	Remotes.event("AdminResult").OnClientEvent:Connect(onResult)
end

--[[ The latest server verdict (display only; the server re-checks every command anyway). ]]
function AdminClient.isAdmin(): boolean
	return admin or Players.LocalPlayer:GetAttribute("IsAdmin") == true
end

--[[
	Sends one command intent. Returns false when the local throttle dropped it (the server's own
	token bucket is the real limit). Args are plain values; the server validates every one.
	Example: AdminClient.send("Kick", { userId = 123, reason = "Spamming" })
]]
function AdminClient.send(name: string, args: { [string]: any }?): boolean
	local now = os.clock()
	while #sendTimes > 0 and now - sendTimes[1] > SEND_WINDOW do
		table.remove(sendTimes, 1)
	end
	if #sendTimes >= SEND_MAX then
		return false
	end
	table.insert(sendTimes, now)
	Remotes.event("AdminCommand"):FireServer(name, args or {})
	return true
end

--[[ Catalogue commands of one tab, sorted by order then label. ]]
function AdminClient.commandsFor(tab: string): { CommandInfo }
	local result: { CommandInfo } = {}
	local state = AdminClient.state
	if state == nil then
		return result
	end
	for _, info in state.catalog do
		if info.tab == tab then
			table.insert(result, info)
		end
	end
	table.sort(result, function(a: CommandInfo, b: CommandInfo): boolean
		if a.order ~= b.order then
			return a.order < b.order
		end
		return a.label < b.label
	end)
	return result
end

--[[ One command's catalogue entry (nil before the first push / unknown name). ]]
function AdminClient.command(name: string): CommandInfo?
	return byName[name]
end

--[[ nil when the command can be used now; otherwise the reason shown on the greyed button. ]]
function AdminClient.unavailable(name: string): string?
	local state = AdminClient.state
	if state == nil then
		return "waiting for the server"
	end
	if byName[name] == nil then
		return "not available"
	end
	local reason = state.availability[name]
	if type(reason) == "string" and reason ~= "" then
		return reason
	end
	return nil
end

--[[
	R57: the world a player is in and their extra worlds' columns (nil when not in the server / no
	state yet). Example: AdminClient.playerWorlds(123).worlds.dino.cash --> Bones
]]
function AdminClient.playerWorlds(userId: number): PlayerWorlds?
	local state = AdminClient.state
	return if state ~= nil then state.playerWorlds[userId] else nil
end

--[[ One player row by user id (nil when not in the server / no state yet). ]]
function AdminClient.player(userId: number): PlayerRow?
	local state = AdminClient.state
	if state == nil then
		return nil
	end
	for _, row in state.players do
		if row.userId == userId then
			return row
		end
	end
	return nil
end

return AdminClient
