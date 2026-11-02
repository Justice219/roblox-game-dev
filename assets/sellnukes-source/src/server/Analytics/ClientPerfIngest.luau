--!strict
--[[
	ClientPerfIngest — the server end of the ClientPerf remote (ported from RoBeasts'
	ClientPerfService). Measurement only.

	Each client (Client/Analytics/ClientPerfReporter) sends one fixed-size buffer about once a minute
	(ClientPerfLogic wire: frame-time histogram, memory, ping, receive, boot / plot-ready seconds,
	memory tags, session minutes, the boot-step block). Every number is an UNTRUSTED claim:
		- per-player token bucket (ClientPerfConfig.RateLimit),
		- a live analytics session is required,
		- ClientPerfLogic.decode: exact length + version, finite checks, clamps, and the claimed
		  window may not exceed the time since this player's previous accepted report (+ slack),
		  the claimed session minutes not the time since their join (+ slack),
		- R122 boot steps: the boot time and its step block (each loading step's completion second,
		  the hand-off reason) count ONCE per analytics session: decode checks the block strictly
		  (finite, -1 or 0 .. boot, known reasons only, consistent with the boot), and a later
		  report claiming another boot this session has its boot fields stripped (counted as
		  "cp:<Class>:bootDrop"; the rest of the report still counts),
		- the server buckets the values itself (ClientPerfLogic.counters) into "health" counters
		  "cp:<Class>:*" (a bounded key set: 5 device classes × ~130 keys),
		- R57 world split: the core subset (reports, seconds, frames, ft:<bucket>, sampled, memMb,
		  pingMs, instN, inst) is ALSO counted as "perfW:<world>:*" for the world the server knows
		  the player is in (Player attribute CurrentWorld, set by WorldService — never a client
		  claim; a report spanning a trip lands on the arrival world). ≤ worlds × ~16 keys.
	A lying client can at most skew its own device class's averages within the clamps; nothing is
	granted or changed from a report.

	Connects to: ClientPerfLogic / ClientPerfConfig (shared), Runtime.sessions (window clock),
	Recorder ("health" counters), AnalyticsService.Start (remote wiring).

	Example:
		Remotes.onServerEvent("ClientPerf", ClientPerfIngest.handleReport)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientPerfConfig = require(ReplicatedStorage.Shared.Analytics.ClientPerfConfig)
local ClientPerfLogic = require(ReplicatedStorage.Shared.Analytics.ClientPerfLogic)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)
local Recorder = require(script.Parent.Recorder)
local Runtime = require(script.Parent.Runtime)

local ClientPerfIngest = {}

local limiter = RateLimiter.new(ClientPerfConfig.RateLimit.Burst, ClientPerfConfig.RateLimit.PerSecond)
local accepted, rejected = 0, 0
-- Analytics sessions (Runtime.sessions values) whose boot time was already counted. Weak keys:
-- a session's entry goes away with the session table itself (a new session = a new table), so
-- "once per session" needs no cleanup and can never leak.
local bootCounted: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- Counter suffixes (after "cp:<Class>:") mirrored per world as "perfW:<world>:<suffix>"; plus
-- every frame-time bucket "ft:<bucket>" (p50 / p95 per world).
local WORLD_SUFFIXES: { [string]: boolean } = {
	reports = true,
	seconds = true,
	frames = true,
	sampled = true,
	memMb = true,
	pingMs = true,
	instN = true,
	inst = true,
}
-- Server-set Player attribute naming the player's world (WorldService).
local CURRENT_WORLD_ATTRIBUTE = "CurrentWorld"

-- The world id the player is in ("main" when the attribute is unset or not a known world).
local function worldOf(player: Player): string
	local value = player:GetAttribute(CURRENT_WORLD_ATTRIBUTE)
	if type(value) == "string" and WorldsConfig.get(value) ~= nil then
		return value
	end
	return WorldsConfig.MAIN
end

--[[
	Validates one ClientPerf report from `player` and records it.
	@param player the sender (authentic: the remote's first argument)
	@param raw    the untrusted payload
	@return true when the report was accepted
]]
function ClientPerfIngest.handleReport(player: Player, raw: unknown): boolean
	if not limiter:Allow(player.UserId) then
		rejected += 1
		return false
	end
	local info = Runtime.sessions[player]
	if info == nil or player.Parent ~= Players then
		rejected += 1
		return false
	end
	local now = os.clock()
	local limits = ClientPerfConfig.Limits
	local since = info.perfAt or info.startedClock
	local sessionCap = (now - info.startedClock) / 60 + limits.SessionSlackMinutes
	local report = ClientPerfLogic.decode(raw, now - since + limits.WindowSlackSeconds, sessionCap)
	if report == nil then
		rejected += 1
		Recorder.count("core", "ops:clientRefused:ClientPerf")
		return false
	end
	info.perfAt = now
	accepted += 1
	-- R122: the boot time + its step block count once per session; a repeat claim is stripped.
	if report.bootSeconds ~= nil then
		if bootCounted[info] then
			report.bootSeconds = nil
			report.bootSteps = nil
			report.bootEnd = nil
			report.bootDropped = true
		else
			bootCounted[info] = true
		end
	end
	local world = worldOf(player)
	for key, amount in ClientPerfLogic.counters(report) do
		Recorder.count("health", key, amount)
		local suffix = string.match(key, "^[^:]+:[^:]+:(.+)$")
		if suffix ~= nil and (WORLD_SUFFIXES[suffix] or string.sub(suffix, 1, 3) == "ft:") then
			Recorder.count("health", `perfW:{world}:{suffix}`, amount)
		end
	end
	return true
end

--[[ Drops the player's bucket (PlayerRemoving). ]]
function ClientPerfIngest.forget(player: Player)
	limiter:Forget(player.UserId)
end

--[[ Accepted / rejected report counts since start (diagnostics / tests). ]]
function ClientPerfIngest.stats(): { accepted: number, rejected: number }
	return { accepted = accepted, rejected = rejected }
end

return table.freeze(ClientPerfIngest)
