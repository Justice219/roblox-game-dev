--!strict
--[[
	ServerHandlers — built-in handlers of the admin panel's SERVER tab (spec §14): filtered
	announcements, time of day, runtime redeem codes (B7 CodesService seam), an analytics flush,
	and the graceful restart with a countdown.

	Announcements:
		The text is TextService-filtered for broadcast (filter failure → dropped, the log says
		"(withheld)"), then published as two ReplicatedStorage attributes that every client's admin
		overlay (Client/UI/Screens/Admin) shows as a banner: AdminConfig.Attributes.AnnounceText,
		then AnnounceAt = Workspace:GetServerTimeNow() (written last: clients react to it). No new
		remote is needed and late joiners see a recent banner too.

	Graceful restart (Shutdown / CancelShutdown):
		ShutdownAt (server time) + ShutdownReason (filtered) attributes drive the clients' countdown
		banner; one scheduled thread per request carries a token, so CancelShutdown or a new
		Shutdown invalidates the old one. At the deadline the server enters "closing": every player
		is kicked with AdminConfig.ShutdownKickMessage (profiles are released + saved by
		PlayerDataService on PlayerRemoving; BindToClose finishes the rest) and late joiners are
		kicked as they arrive, so the empty server closes.

	Connects to: Server/Admin/HandlerKit, Server/Admin/Seams (CodesService, AnalyticsService),
	Shared/Config/AdminConfig (attribute names, kick text), Lighting, Remotes (Notify toast).

	Example:
		ServerHandlers.install(registry, env)
		print(ServerHandlers.shutdownAt()) --> 0 (no restart scheduled)
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AdminConfig = require(ReplicatedStorage.Shared.Config.AdminConfig)
local AdminValidate = require(script.Parent.Parent.AdminValidate)
local HandlerKit = require(script.Parent.HandlerKit)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Seams = require(script.Parent.Parent.Seams)

type Context = HandlerKit.Context

local ServerHandlers = {}

local Kit = HandlerKit
local Attributes = AdminConfig.Attributes

-- Restart state: the active request's token (bumped by Shutdown / CancelShutdown), its deadline
-- (server time, 0 = none), and whether the server is already closing.
local shutdownToken = 0
local shutdownDeadline = 0
local closing = false
local lateJoinConnection: RBXScriptConnection? = nil
local closingMessage = AdminConfig.ShutdownKickMessage
-- Runtime codes added from the panel (id uniqueness).
local codeCounter = 0

-- Announce: filtered banner for everyone in this server.
local function announce(ctx: Context): (boolean, string)
	local text = Kit.str(ctx, "text") :: string
	local filtered = Kit.filterBroadcastAsync(text, ctx.caller.userId)
	if filtered == nil or string.match(filtered, "%S") == nil then
		return false, "Announcement dropped: text filtering failed (withheld)"
	end
	ReplicatedStorage:SetAttribute(Attributes.AnnounceText, filtered)
	ReplicatedStorage:SetAttribute(Attributes.AnnounceAt, Workspace:GetServerTimeNow())
	return true, `Announced: {AdminValidate.sanitizeForLog(filtered, 60)}`
end

-- SetTimeOfDay: Lighting.ClockTime (0..24).
local function setTimeOfDay(ctx: Context): (boolean, string)
	local hour = Kit.num(ctx, "hour") :: number
	Lighting.ClockTime = hour % 24
	local h = math.floor(hour % 24)
	local m = math.floor((hour % 1) * 60 + 0.5) % 60
	return true, string.format("Time of day set to %02d:%02d", h, m)
end

-- AddCode: a runtime redeem code for THIS server (CodesService.addCode).
local function addCode(ctx: Context): (boolean, string)
	local code = Kit.str(ctx, "code") :: string
	local gems = Kit.num(ctx, "gems") or 0
	local spins = Kit.num(ctx, "spins") or 0
	local cashSeconds = Kit.num(ctx, "cashSeconds") or 0
	local hours = Kit.num(ctx, "hours") or 24
	local reward: { [string]: number } = {}
	if gems > 0 then
		reward.gems = gems
	end
	if spins > 0 then
		reward.spins = spins
	end
	if cashSeconds > 0 then
		reward.cashSeconds = cashSeconds
	end
	if next(reward) == nil then
		return false, "A code needs at least one reward (gems, spins or cash)"
	end
	codeCounter += 1
	local id = string.sub(`admin_{string.lower(code)}_{codeCounter}`, 1, 32)
	local found, added = Seams.call(Seams.service("CodesService"), "addCode", {
		id = id,
		code = code,
		reward = reward,
		expiresAt = os.time() + hours * 3600,
	})
	if not found then
		return false, Kit.RETENTION
	end
	if added ~= true then
		return false, `Code {code} was refused (already exists or invalid reward)`
	end
	return true, `Code {code} works in this server for {hours}h`
end

-- FlushAnalytics: AnalyticsService.flushNow() (its own thread).
local function flushAnalytics(_ctx: Context): (boolean, string)
	local found = Seams.call(Seams.service("AnalyticsService"), "flushNow")
	if not found then
		return false, Kit.ANALYTICS
	end
	return true, "Analytics flush started"
end

-- Kicks every player (closing) and keeps kicking late joiners.
local function closeServer()
	closing = true
	if lateJoinConnection == nil then
		lateJoinConnection = Players.PlayerAdded:Connect(function(player: Player)
			player:Kick(closingMessage)
		end)
	end
	for _, player in Players:GetPlayers() do
		player:Kick(closingMessage)
	end
end

-- Shutdown: countdown banner, then close the server.
local function shutdown(ctx: Context): (boolean, string)
	if closing then
		return false, "The server is already closing"
	end
	local seconds = Kit.num(ctx, "seconds") :: number
	local reason = Kit.str(ctx, "reason") or ""
	local shownReason = ""
	if reason ~= "" then
		shownReason = Kit.filterBroadcastAsync(reason, ctx.caller.userId) or ""
		if string.match(shownReason, "%S") == nil then
			shownReason = ""
		end
	end
	shutdownToken += 1
	local token = shutdownToken
	shutdownDeadline = Workspace:GetServerTimeNow() + seconds
	closingMessage = if shownReason ~= ""
		then `{AdminConfig.ShutdownKickMessage} ({shownReason})`
		else AdminConfig.ShutdownKickMessage
	ReplicatedStorage:SetAttribute(Attributes.ShutdownReason, shownReason)
	ReplicatedStorage:SetAttribute(Attributes.ShutdownAt, shutdownDeadline)
	Remotes.fireAllClients("Notify", {
		kind = "info",
		text = `The server restarts in {seconds} seconds - your progress is saved!`,
	})
	task.delay(seconds, function()
		if token ~= shutdownToken or closing then
			return -- cancelled or replaced
		end
		closeServer()
	end)
	return true, `Restart scheduled in {seconds}s`
end

-- CancelShutdown: invalidates the scheduled restart and clears the banner.
local function cancelShutdown(_ctx: Context): (boolean, string)
	if closing then
		return false, "Too late: the server is already closing"
	end
	if shutdownDeadline == 0 then
		return false, "No restart is scheduled"
	end
	shutdownToken += 1
	shutdownDeadline = 0
	ReplicatedStorage:SetAttribute(Attributes.ShutdownAt, 0)
	ReplicatedStorage:SetAttribute(Attributes.ShutdownReason, "")
	Remotes.fireAllClients("Notify", { kind = "success", text = "The server restart was cancelled." })
	return true, "Restart cancelled"
end

--[[ Installs every Server-tab handler into the registry. ]]
function ServerHandlers.install(registry: HandlerKit.Registry, _env: HandlerKit.Env)
	registry.setBuiltin("Announce", announce)
	registry.setBuiltin("SetTimeOfDay", setTimeOfDay)
	registry.setBuiltin("AddCode", addCode, Kit.serviceProbe("CodesService", "addCode", Kit.RETENTION))
	registry.setBuiltin(
		"FlushAnalytics",
		flushAnalytics,
		Kit.serviceProbe("AnalyticsService", "flushNow", Kit.ANALYTICS)
	)
	registry.setBuiltin("Shutdown", shutdown)
	registry.setBuiltin("CancelShutdown", cancelShutdown)
end

--[[ The scheduled restart's deadline in server time (0 = none). ]]
function ServerHandlers.shutdownAt(): number
	return shutdownDeadline
end

return table.freeze(ServerHandlers)
