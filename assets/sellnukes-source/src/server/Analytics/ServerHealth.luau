--!strict
--[[
	ServerHealth — always-on, near-zero-cost sampler of live-server performance (measurement only:
	it never changes gameplay). Adapted from RoBeasts' ServerHealth.

	What it samples (running totals since start; ServerHealthLogic diffs two snapshots):
		- every Heartbeat: the frame's dt → frame count, ms sum and histogram (arithmetic only).
		- every Health.SampleInterval (2 Hz): Stats.HeartbeatTimeMs / PhysicsStepTimeMs /
		  DataSendKbps / DataReceiveKbps, Stats:GetTotalMemoryUsageMb(), the player count and each
		  player's Player:GetNetworkPing().
		- `addTime(system, seconds)`: Luau time of each server loop, called by the loop owners
		  (producers, build-in, pets, attack, ...) around their tick: two os.clock() reads per tick.
		  System ids are AnalyticsConfig.Health.Systems (anything else → "Other").
		- every server→client remote send through Shared/Net/Remotes' send observer: fires and
		  bytes × recipients per remote name (bounded at Health.MaxRemoteKeys names).
	AnalyticsService turns one window per Health.WindowSeconds into "health" counters, and the admin
	panel's Live tab reads `liveStats()` (instant values, no DataStore).

	Example:
		local started = os.clock()
		tickProducers()
		ServerHealth.addTime("Producers", os.clock() - started)
		print(ServerHealth.liveStats().fps)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")

local AnalyticsConfig = require(ReplicatedStorage.Shared.Config.AnalyticsConfig)

-- Stats.HeartbeatTimeMs / PhysicsStepTimeMs exist at runtime (RoBeasts verified them in Studio)
-- but are missing from the pinned type definitions: read them through an untyped alias.
local StatsUntyped: any = Stats
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ServerHealthLogic = require(script.Parent.ServerHealthLogic)

-- Instant values for the admin Live tab.
export type LiveStats = {
	fps: number, -- frames per second over the last sampled second
	heartbeatMs: number,
	physicsMs: number,
	memoryMb: number,
	sendKbps: number,
	receiveKbps: number,
	players: number,
	avgPingMs: number,
	uptimeSeconds: number,
	systemsMsPerSecond: { [string]: number }, -- over the current window
}

local ServerHealth = {}

local cfg = AnalyticsConfig.Health
local totals = ServerHealthLogic.newTotals(cfg)
local started = false
local startedAt = os.clock()

local SYSTEMS: { [string]: boolean } = {}
for _, system in cfg.Systems do
	SYSTEMS[system] = true
end
local remoteNames = 0

-- Latest 2 Hz sample (Live tab).
local last = { heartbeat = 0, physics = 0, memory = 0, send = 0, receive = 0, players = 0, ping = 0 }
-- Frames / seconds since the last 2 Hz sample (instant fps).
local recentFrames, recentSeconds = 0, 0
local lastFps = 0
-- Window start snapshot of `systems` (Live tab per-second rates).
local windowSystems: { [string]: number } = {}
local windowStartedAt = os.clock()

--[[ Adds `seconds` of Luau time to a server system (never yields; bad input ignored). ]]
function ServerHealth.addTime(system: string, seconds: number)
	if type(seconds) ~= "number" or seconds ~= seconds or seconds <= 0 or seconds > 60 then
		return
	end
	local id = if SYSTEMS[system] then system else "Other"
	totals.systems[id] = (totals.systems[id] or 0) + seconds
end

-- Remote send observer (Shared/Net/Remotes): bytes are one copy; recipients -1 = every client.
local function onRemoteSend(name: string, bytes: number, recipients: number)
	local copies = if recipients == Remotes.AllClients then #Players:GetPlayers() else math.max(0, recipients)
	if copies <= 0 then
		return
	end
	if totals.remoteFires[name] == nil then
		if remoteNames >= cfg.MaxRemoteKeys then
			name = "other"
		else
			remoteNames += 1
		end
	end
	totals.remoteFires[name] = (totals.remoteFires[name] or 0) + copies
	totals.remoteBytes[name] = (totals.remoteBytes[name] or 0) + bytes * copies
end

-- A Stats reading (0 when the property is unavailable).
local function stat(read: () -> number): number
	local ok, value = pcall(read)
	if ok and type(value) == "number" and value == value and value >= 0 and value < 1e9 then
		return value
	end
	return 0
end

-- One 2 Hz sample.
local function sample()
	local heartbeat = stat(function(): number
		return StatsUntyped.HeartbeatTimeMs
	end)
	local physics = stat(function(): number
		return StatsUntyped.PhysicsStepTimeMs
	end)
	local send = stat(function(): number
		return Stats.DataSendKbps
	end)
	local receive = stat(function(): number
		return Stats.DataReceiveKbps
	end)
	local memory = stat(function(): number
		return Stats:GetTotalMemoryUsageMb()
	end)
	local players = Players:GetPlayers()
	totals.hbN += 1
	totals.hbSum += heartbeat
	local hb = ServerHealthLogic.bucketIndex(heartbeat, cfg.HeartbeatBucketsMs)
	totals.hbBuckets[hb] += 1
	totals.physSum += physics
	totals.sendSum += send
	totals.recvSum += receive
	totals.plrSum += #players
	totals.memSum += memory
	local mem = ServerHealthLogic.bucketIndex(memory, cfg.MemoryBucketsMb)
	totals.memBuckets[mem] += 1
	local pingSum, pingN = 0, 0
	for _, player in players do
		local ok, ping = pcall(player.GetNetworkPing, player)
		if ok and type(ping) == "number" and ping == ping and ping >= 0 and ping < 60 then
			local ms = ping * 1000
			totals.pingN += 1
			totals.pingSum += ms
			local index = ServerHealthLogic.bucketIndex(ms, cfg.PingBucketsMs)
			totals.pingBuckets[index] += 1
			pingSum += ms
			pingN += 1
		end
	end
	last.heartbeat, last.physics, last.memory = heartbeat, physics, memory
	last.send, last.receive, last.players = send, receive, #players
	last.ping = if pingN > 0 then pingSum / pingN else 0
	lastFps = if recentSeconds > 0 then recentFrames / recentSeconds else 0
	recentFrames, recentSeconds = 0, 0
end

--[[ Starts sampling (idempotent): one Heartbeat connection + one 2 Hz loop for the server's life. ]]
function ServerHealth.start()
	if started then
		return
	end
	started = true
	startedAt = os.clock()
	local sinceSample = 0
	RunService.Heartbeat:Connect(function(dt: number)
		if dt ~= dt or dt <= 0 or dt > 5 then
			return
		end
		local ms = dt * 1000
		totals.seconds += dt
		totals.frames += 1
		totals.frameMsSum += ms
		local index = ServerHealthLogic.bucketIndex(ms, cfg.FrameBucketsMs)
		totals.frameBuckets[index] += 1
		recentFrames += 1
		recentSeconds += dt
		sinceSample += dt
		if sinceSample >= cfg.SampleInterval then
			sinceSample = 0
			sample()
		end
	end)
	pcall(Remotes.setSendObserver, onRemoteSend)
end

--[[ A snapshot of the running totals (the next window starts from it). ]]
function ServerHealth.snapshot(): ServerHealthLogic.Totals
	return ServerHealthLogic.copy(totals)
end

--[[ Marks the start of a new window for the Live tab's per-second system rates. ]]
function ServerHealth.markWindow()
	windowSystems = table.clone(totals.systems)
	windowStartedAt = os.clock()
end

--[[ Instant values for the admin Live tab (no yields, no DataStore). ]]
function ServerHealth.liveStats(): LiveStats
	local elapsed = math.max(0.001, os.clock() - windowStartedAt)
	local rates: { [string]: number } = {}
	for system, seconds in totals.systems do
		local delta = seconds - (windowSystems[system] or 0)
		if delta > 0 then
			rates[system] = math.floor(delta * 1000 / elapsed * 100 + 0.5) / 100
		end
	end
	return {
		fps = math.floor(lastFps * 10 + 0.5) / 10,
		heartbeatMs = last.heartbeat,
		physicsMs = last.physics,
		memoryMb = last.memory,
		sendKbps = last.send,
		receiveKbps = last.receive,
		players = last.players,
		avgPingMs = math.floor(last.ping + 0.5),
		uptimeSeconds = math.floor(os.clock() - startedAt),
		systemsMsPerSecond = rates,
	}
end

return ServerHealth
