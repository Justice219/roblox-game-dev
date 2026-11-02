--!strict
--[[
	AdminStatePush — builds and delivers the `AdminState` payload that drives the admin panel
	(spec §14 Players / Live / Log tabs + the command catalogue).

	Wire contract (types: Shared/Config/AdminConfig; reader: Client/UI/Screens/Admin/AdminClient):
		AdminState (server → each admin only):
		{
			isAdmin = true, serverTime = Workspace:GetServerTimeNow(), isStudio,
			stats = { players, maxPlayers, fps, heartbeatMs, physicsFps, memoryMb, uptime,
			          instanceCount, sendKbps, receiveKbps, avgPingMs, timeOfDay, shutdownAt,
			          serverBoostSeconds, savingEnabled, forwardSent, forwardDropped,
			          forwardFailed, systemsMs = { [system] = ms per second }, jobId, placeVersion,
			          worlds = { [worldId] = players in that world } },   -- R57 Live tab
			players = { PlayerRow }        -- sorted by lower-case name
			playerWorlds = { ["<userId>"] = { world, worlds = { [extraWorldId] = { unlocked, cash,
			                 area, rebirths } } } }   -- R57 Players list: current world, Bones, Dino
			                 area, Dino rebirths (loaded profiles; world = Player attr CurrentWorld)
			recentBans = { RecentBan },
			logVersion, log?,              -- log (tail ≤ AuditTailSize, oldest first) only when it
			                               -- changed since this admin's last push (or a full push)
			catalogVersion, catalog?, availability?,  -- only when the catalogue / availability
			                               -- changed for this admin (or a full push)
		}
		A player who stops being an admin receives one `{ isAdmin = false }`.

	Cadence (performance):
		- change-triggered pushes are coalesced: at most one per StatePushMinInterval (≤ 4 Hz),
		- a periodic push every StatePushInterval (3 s) while any admin is online (Live tab),
		- nothing is built when no admin is online,
		- the shared part is built ONCE per push for all admins; per-admin deltas (log, catalogue)
		  are only attached when that admin has not seen the current version,
		- ONE Heartbeat connection counts frames (fallback FPS when analytics is absent),
		- the push's own Luau time is reported to AnalyticsService.systemTime("Admin", seconds).

	Connects to: Server/Admin/AdminRegistry (catalog / availability / version), AdminAudit (tail /
	version), Server/Admin/Seams (AnalyticsService live health, ServerBoostService), Server/
	Services/PlayerDataService (profiles, sessions), Shared/Net/Remotes ("AdminState"),
	Shared/Config/Worlds/WorldsConfig (R57 world columns; CurrentWorld is set by WorldService).

	Example:
		local push = AdminStatePush.new({ registry = registry, audit = audit, admins = adminsOnline,
			isAdmin = AdminService.isAdmin, recentBans = PlayerHandlers.recentBans,
			shutdownAt = ServerHandlers.shutdownAt })
		push.start(function() recheckRanks() end)
		push.schedule()
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local Workspace = game:GetService("Workspace")

local AdminAudit = require(script.Parent.AdminAudit)
local AdminConfig = require(ReplicatedStorage.Shared.Config.AdminConfig)
local AdminRegistry = require(script.Parent.AdminRegistry)
local PlayerDataService = require(script.Parent.Parent.Services.PlayerDataService)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Seams = require(script.Parent.Seams)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

type PlayerRow = AdminConfig.PlayerRow
type RecentBan = AdminConfig.RecentBan

export type Deps = {
	registry: AdminRegistry.Registry,
	audit: AdminAudit.Audit,
	admins: () -> { Player }, -- online players with admin rights right now
	isAdmin: (player: Player) -> boolean,
	recentBans: () -> { RecentBan },
	shutdownAt: () -> number,
}

export type StatePush = {
	start: (onTick: (() -> ())?) -> (),
	schedule: () -> (),
	pushTo: (player: Player, full: boolean) -> (),
	markFull: (player: Player) -> (),
	revoke: (player: Player) -> (),
	noteJoin: (player: Player) -> (),
	forget: (player: Player) -> (),
}

type Delivery = { logVersion: number, catalogVersion: number }

local AdminStatePush = {}

-- Seconds of heartbeat counting before the fallback FPS is refreshed.
local FPS_SAMPLE_SECONDS = 0.5

-- Server-set Player attribute naming the player's world (WorldService, owner R57).
local CURRENT_WORLD_ATTRIBUTE = "CurrentWorld"

-- R57: one extra world's columns of a player row (Players list).
export type WorldColumns = { unlocked: boolean, cash: number, area: number, rebirths: number }
export type PlayerWorlds = { world: string, worlds: { [string]: WorldColumns } }

-- One decimal place.
local function round1(n: number): number
	return math.round(n * 10) / 10
end

-- A finite number or 0.
local function finite(value: unknown): number
	return if type(value) == "number"
			and value == value
			and value ~= math.huge
			and value ~= -math.huge
		then value
		else 0
end

--[[
	Creates the state pusher. Call `start` once (AdminService.Start).
	@return the StatePush API
]]
function AdminStatePush.new(deps: Deps): StatePush
	local deliveries: { [Player]: Delivery } = {}
	local joinedAt: { [Player]: number } = {}
	local pushScheduled = false
	local lastPushAt = 0
	local started = false

	-- Catalogue stamp: bumps when the registry version or the availability map changes.
	local catalogStamp = 0
	local lastRegistryVersion = -1
	local lastSignature = ""
	local availability: { [string]: string } = {}

	-- Fallback FPS from one Heartbeat connection.
	local frames = 0
	local sampleStart = os.clock()
	local heartbeatFps = 0

	-- Recomputes availability; bumps catalogStamp when anything changed.
	local function refreshCatalogStamp(isStudio: boolean)
		local names = deps.registry.names()
		table.sort(names)
		local parts: { string } = {}
		local map: { [string]: string } = {}
		for _, name in names do
			local reason = deps.registry.availability(name, isStudio)
			map[name] = reason
			table.insert(parts, `{name}={reason}`)
		end
		local signature = table.concat(parts, ";")
		local version = deps.registry.version()
		if version ~= lastRegistryVersion or signature ~= lastSignature then
			lastRegistryVersion = version
			lastSignature = signature
			availability = map
			catalogStamp += 1
		end
	end

	-- One player's row (cheap reads only; never yields).
	local function playerRow(player: Player, analytics: any): PlayerRow
		local profile = PlayerDataService.getProfile(player)
		local session = PlayerDataService.getSession(player)
		local saving = "none"
		if session ~= nil then
			saving = if (session :: any).sandbox == true then "sandbox" else session.status
		end
		local okPing, ping = pcall(function(): number
			return player:GetNetworkPing()
		end)
		local device = ""
		if analytics ~= nil and type(analytics.deviceOf) == "function" then
			local okDevice, value = pcall(analytics.deviceOf, player)
			if okDevice and type(value) == "string" then
				device = value
			end
		end
		local tycoon = if profile ~= nil then profile.tycoon else nil
		local npm = player:GetAttribute("NewPlayerMode") == true
		return {
			name = player.Name,
			displayName = player.DisplayName,
			userId = player.UserId,
			isAdmin = deps.isAdmin(player),
			loaded = profile ~= nil,
			saving = saving,
			cash = if profile ~= nil then finite(profile.cash) else 0,
			gems = if profile ~= nil then finite(profile.gems) else 0,
			area = if tycoon ~= nil then finite(tycoon.area) else 0,
			rebirths = if profile ~= nil then finite(profile.rebirths) else 0,
			totalEarned = if profile ~= nil then finite(profile.totalEarned) else 0,
			pingMs = if okPing and type(ping) == "number" then math.round(ping * 1000) else -1,
			newPlayerMode = npm,
			sessionSeconds = math.floor(os.clock() - (joinedAt[player] or os.clock())),
			device = device,
		}
	end

	--[[
		R57: the world a player is in (server-set attribute; unknown values → "main") and the
		columns of every extra world from their profile (cheap reads; never yields).
	]]
	local function playerWorlds(player: Player): PlayerWorlds
		local attribute = player:GetAttribute(CURRENT_WORLD_ATTRIBUTE)
		local world = if type(attribute) == "string" and WorldsConfig.get(attribute) ~= nil
			then attribute
			else WorldsConfig.MAIN
		local columns: { [string]: WorldColumns } = {}
		local profile = PlayerDataService.getProfile(player)
		local worlds = if profile ~= nil then profile.worlds else nil
		if type(worlds) == "table" then
			for _, def in WorldsConfig.extra() do
				local state = worlds[def.id]
				if type(state) == "table" then
					local tycoon = state.tycoon
					columns[def.id] = {
						unlocked = state.unlocked == true,
						cash = finite(state.cash),
						area = if type(tycoon) == "table" then finite(tycoon.area) else 0,
						rebirths = finite(state.rebirths),
					}
				end
			end
		end
		return { world = world, worlds = columns }
	end

	-- The part of the state every admin receives identically (built once per push).
	local function buildShared(): { [string]: any }
		local now = os.clock()
		local elapsed = now - sampleStart
		if elapsed >= FPS_SAMPLE_SECONDS then
			heartbeatFps = frames / elapsed
			frames = 0
			sampleStart = now
		end
		local analytics = Seams.service("AnalyticsService")
		local health: { [string]: any } = {}
		if analytics ~= nil and type(analytics.liveHealth) == "function" then
			local ok, value = pcall(analytics.liveHealth)
			if ok and type(value) == "table" then
				health = value
			end
		end
		local forward: { [string]: any } = {}
		if analytics ~= nil and type(analytics.forwardStats) == "function" then
			local ok, value = pcall(analytics.forwardStats)
			if ok and type(value) == "table" then
				forward = value
			end
		end
		local systems: { [string]: number } = {}
		if type(health.systemsMsPerSecond) == "table" then
			for system, ms in health.systemsMsPerSecond do
				if type(system) == "string" and type(ms) == "number" then
					systems[system] = round1(ms)
				end
			end
		end
		local boostSeconds = 0
		local boost = Seams.service("ServerBoostService")
		if Seams.has(boost, "endsAt") then
			local ok, endsAt = pcall(boost.endsAt)
			if ok and type(endsAt) == "number" then
				boostSeconds = math.max(0, endsAt - os.time())
			end
		end

		local rows: { PlayerRow } = {}
		local worldsOf: { [string]: PlayerWorlds } = {}
		local perWorld: { [string]: number } = {}
		for _, worldId in WorldsConfig.Order do
			perWorld[worldId] = 0
		end
		for _, player in Players:GetPlayers() do
			table.insert(rows, playerRow(player, analytics))
			local columns = playerWorlds(player)
			worldsOf[tostring(player.UserId)] = columns
			perWorld[columns.world] = (perWorld[columns.world] or 0) + 1
		end
		table.sort(rows, function(a: PlayerRow, b: PlayerRow): boolean
			return string.lower(a.name) < string.lower(b.name)
		end)

		local pings = 0
		local pingCount = 0
		for _, row in rows do
			if row.pingMs >= 0 then
				pings += row.pingMs
				pingCount += 1
			end
		end

		local jobId = if game.JobId ~= "" then string.sub(game.JobId, 1, 8) else "studio"
		return {
			isAdmin = true,
			serverTime = Workspace:GetServerTimeNow(),
			isStudio = RunService:IsStudio(),
			stats = {
				players = #rows,
				maxPlayers = Players.MaxPlayers,
				fps = round1(if health.fps ~= nil then finite(health.fps) else heartbeatFps),
				heartbeatMs = round1(finite(health.heartbeatMs)),
				physicsFps = round1(Workspace:GetRealPhysicsFPS()),
				memoryMb = round1(Stats:GetTotalMemoryUsageMb()),
				uptime = math.floor(Workspace.DistributedGameTime),
				instanceCount = Stats.InstanceCount,
				sendKbps = round1(Stats.DataSendKbps),
				receiveKbps = round1(Stats.DataReceiveKbps),
				avgPingMs = if pingCount > 0 then math.round(pings / pingCount) else 0,
				timeOfDay = round1(Lighting.ClockTime),
				shutdownAt = deps.shutdownAt(),
				serverBoostSeconds = boostSeconds,
				savingEnabled = PlayerDataService.isSavingEnabled(),
				forwardSent = finite(forward.sent),
				forwardDropped = finite(forward.dropped),
				forwardFailed = finite(forward.failed),
				systemsMs = systems,
				jobId = jobId,
				placeVersion = game.PlaceVersion,
				worlds = perWorld,
			},
			players = rows,
			playerWorlds = worldsOf,
			recentBans = deps.recentBans(),
			logVersion = deps.audit.version(),
			catalogVersion = catalogStamp,
		}
	end

	-- Sends `shared` + this admin's deltas.
	local function deliver(player: Player, shared: { [string]: any }, full: boolean, isStudio: boolean)
		local state = deliveries[player]
		if state == nil or full then
			state = { logVersion = -1, catalogVersion = -1 }
			deliveries[player] = state
		end
		local payload = table.clone(shared)
		local logVersion = deps.audit.version()
		if state.logVersion ~= logVersion then
			payload.log = deps.audit.tail(AdminConfig.AuditTailSize)
			state.logVersion = logVersion
		end
		if state.catalogVersion ~= catalogStamp then
			payload.catalog = deps.registry.catalog(isStudio)
			payload.availability = availability
			state.catalogVersion = catalogStamp
		end
		Remotes.fireClient("AdminState", player, payload)
	end

	-- Reports this push's Luau time to analytics (lazy; never throws).
	local function reportTime(seconds: number)
		local analytics = Seams.service("AnalyticsService")
		if analytics ~= nil and type(analytics.systemTime) == "function" then
			pcall(analytics.systemTime, "Admin", seconds)
		end
	end

	-- Pushes the current state to every admin online.
	local function pushAll()
		lastPushAt = os.clock()
		local admins = deps.admins()
		if #admins == 0 then
			return
		end
		local began = os.clock()
		local isStudio = RunService:IsStudio()
		refreshCatalogStamp(isStudio)
		local shared = buildShared()
		for _, player in admins do
			if player.Parent == Players then
				deliver(player, shared, false, isStudio)
			end
		end
		reportTime(os.clock() - began)
	end

	local push = {} :: StatePush

	--[[ Coalesces change-triggered pushes (at most one per StatePushMinInterval). ]]
	function push.schedule()
		if pushScheduled or not started then
			return
		end
		pushScheduled = true
		local wait = math.max(0, lastPushAt + AdminConfig.StatePushMinInterval - os.clock())
		task.delay(wait, function()
			pushScheduled = false
			local ok, err = pcall(pushAll)
			if not ok then
				warn(`[AdminService] state push failed: {err}`)
			end
		end)
	end

	--[[ Pushes to one admin now (full = resend the log + catalogue). ]]
	function push.pushTo(player: Player, full: boolean)
		if not deps.isAdmin(player) or player.Parent ~= Players then
			return
		end
		local began = os.clock()
		local isStudio = RunService:IsStudio()
		refreshCatalogStamp(isStudio)
		deliver(player, buildShared(), full, isStudio)
		reportTime(os.clock() - began)
	end

	--[[ The next push to this admin carries the full log + catalogue (RequestState). ]]
	function push.markFull(player: Player)
		deliveries[player] = nil
	end

	--[[ Tells a player who lost admin rights; forgets their delivery state. ]]
	function push.revoke(player: Player)
		deliveries[player] = nil
		if player.Parent == Players then
			Remotes.fireClient("AdminState", player, { isAdmin = false })
		end
	end

	--[[ Remembers when a player joined (PlayerRow.sessionSeconds). ]]
	function push.noteJoin(player: Player)
		joinedAt[player] = os.clock()
	end

	--[[ Drops every per-player record of a player who left. ]]
	function push.forget(player: Player)
		deliveries[player] = nil
		joinedAt[player] = nil
	end

	--[[
		Starts the heartbeat counter and the periodic loop (once).
		@param onTick runs before each periodic push (AdminService re-checks expired admin ranks)
	]]
	function push.start(onTick: (() -> ())?)
		if started then
			return
		end
		started = true
		RunService.Heartbeat:Connect(function()
			frames += 1
		end)
		task.spawn(function()
			while true do
				task.wait(AdminConfig.StatePushInterval)
				local tick = onTick
				if tick ~= nil then
					local okTick, errTick = pcall(tick)
					if not okTick then
						warn(`[AdminService] periodic check failed: {errTick}`)
					end
				end
				local ok, err = pcall(pushAll)
				if not ok then
					warn(`[AdminService] state push failed: {err}`)
				end
			end
		end)
	end

	return push
end

return table.freeze(AdminStatePush)
