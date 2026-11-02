--!nocheck
--[[
	happy_hours_server.luau — SERVER half of the R89 Happy Hours Studio QA (E-events), run by
	tools/qa/happy_hours.py through eval_server_runtime in ONE solo playtest (Studio lock held).
	The driver substitutes COMMAND (whitelisted) and ARGS (numbers only). Everything goes through
	the real server seams the admin panel uses (HappyHourService.force / stop / skip / setEnabled,
	HappyHourPickups.spawnFor), never the client.

		COMMAND  "status"     live / next, override, store health, pickups, eventCash, world, wallet
		         "force"      HappyHourService.force(event number ARGS 1, seconds ARGS 2)
		         "stop"       HappyHourService.stop()
		         "skip"       HappyHourService.skip()
		         "kill"       HappyHourService.setEnabled(false)
		         "revive"     HappyHourService.setEnabled(true)
		         "spawn"      HappyHourPickups.spawnFor(player, live, ARGS[1] == 1 golden)
		         "pickups"    the player's live pickup wires (positions)
		         "send"       WorldService.adminSend(player, EVENT world of ARGS[1] index, "plot") —
		                      only when that world is ALREADY unlocked on this profile (never unlocks)
		         "home"       WorldService.sendHome(player)
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }

local Server = ServerScriptService:WaitForChild("Server")
local HappyHourConfig = require(ReplicatedStorage.Shared.Config.HappyHourConfig)
local HappyHourLogic = require(ReplicatedStorage.Shared.Events.HappyHourLogic)
local HappyHourPickups = require(Server.HappyHour.HappyHourPickups)
local HappyHourService = require(Server.Services.HappyHourService)
local ModifierSources = require(Server.Tycoon.ModifierSources)
local PlayerDataService = require(Server.Services.PlayerDataService)
local WorldService = require(Server.Tycoon.WorldService)

local EVENT_IDS = HappyHourConfig.EventIds

local player = Players:GetPlayers()[1]
if player == nil then
	return HttpService:JSONEncode({ error = "no player" })
end

local function liveTable(live)
	if live == nil then
		return nil
	end
	return { id = live.id, forced = live.forced, left = math.floor(live.endsAt - os.time()), world = live.world }
end

local function status()
	local profile = PlayerDataService.getProfile(player)
	local mods = if profile ~= nil then ModifierSources.build(player, profile) else nil
	local override = HappyHourLogic.currentOverride()
	return {
		live = liveTable(HappyHourService.live()),
		nextEvent = liveTable(HappyHourService.nextEvent()),
		kill = override.kill,
		version = override.v,
		skips = #override.skips,
		luck = HappyHourLogic.flavorLuckAt(os.time()),
		eventCash = if mods ~= nil then mods.eventCash else nil,
		world = WorldService.currentWorld(player),
		cash = if profile ~= nil then profile.cash else nil,
		gems = if profile ~= nil then profile.gems else nil,
		pickups = HappyHourPickups.status(),
		statusLine = HappyHourService.status(),
		liveAttribute = ReplicatedStorage:GetAttribute(HappyHourConfig.Attributes.Live),
	}
end

local out
if COMMAND == "status" then
	out = status()
elseif COMMAND == "force" then
	local ok, message = HappyHourService.force(EVENT_IDS[ARGS[1]], ARGS[2])
	out = { ok = ok, message = message, status = status() }
elseif COMMAND == "stop" then
	local ok, message = HappyHourService.stop()
	out = { ok = ok, message = message, status = status() }
elseif COMMAND == "skip" then
	local ok, message = HappyHourService.skip()
	out = { ok = ok, message = message, status = status() }
elseif COMMAND == "kill" then
	local ok, message = HappyHourService.setEnabled(false)
	out = { ok = ok, message = message, status = status() }
elseif COMMAND == "revive" then
	local ok, message = HappyHourService.setEnabled(true)
	out = { ok = ok, message = message, status = status() }
elseif COMMAND == "spawn" then
	local ok, result = HappyHourPickups.spawnFor(player, HappyHourService.live(), ARGS[1] == 1)
	out = { ok = ok, result = result }
elseif COMMAND == "pickups" then
	local list = {}
	for _, wire in HappyHourPickups.pickupsOf(player) do
		local p = wire.points[1]
		table.insert(list, { id = wire.id, event = wire.event, golden = wire.golden, x = p.X, y = p.Y, z = p.Z })
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local nearest = math.huge
	for _, item in list do
		if root ~= nil then
			local d = (Vector3.new(item.x, item.y, item.z) - root.Position).Magnitude
			nearest = math.min(nearest, d)
		end
	end
	out = { list = list, nearest = if nearest < math.huge then math.floor(nearest) else nil }
elseif COMMAND == "send" then
	local world = HappyHourConfig.Events[EVENT_IDS[ARGS[1]]].world
	if world == nil then
		out = { ok = false, reason = "global event" }
	elseif not WorldService.isUnlocked(player, world) then
		out = { ok = false, reason = `{world} locked on this profile (not unlocking it)` }
	else
		local ok, reason = WorldService.adminSend(player, world, "plot")
		out = { ok = ok, reason = reason, world = world }
	end
elseif COMMAND == "home" then
	WorldService.sendHome(player)
	out = { ok = true }
end
return HttpService:JSONEncode(out)
