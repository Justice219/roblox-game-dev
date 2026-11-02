--!nocheck
--[[
	r96_feast_server.luau — server-VM steps for the owner R96 (turkey on the ground) + R97 (3 free
	starter stickers) QA (tools/qa/r96_feast.py, ONE solo playtest, eval_server_runtime). Uses the
	same seams the admin panel uses (EventService.setForced / resetSheet / grantSticker /
	resetStarter / spawnTurkey).

		COMMAND  "force"    forces the Harvest Feast ON on this server (refreshActive runs within 1 s,
		                    which also runs the join-time starter grant); returns status()
		         "fresh"    new-sheet path: resetSheet + resetStarter(now) → granted (expect 3),
		                    then a second grant attempt (expect 0: idempotent); returns status()
		         "topup"    top-up path: resetSheet + grantSticker(ARGS[1]) + resetStarter(now) →
		                    granted (expect 2: 1 owned + 2 = 3); returns status()
		         "status"   status(): active, season, starterSeason, stickers, count
		         "spawn"    spawns one turkey on the player's plot (ARGS[1] = 1) or in the hub
		                    (ARGS[1] = 2); returns { id, x, y, z } of its current pose (server)
		         "goto"     moves the character to (ARGS[1], ARGS[2], ARGS[3]) + 6 studs back (so the
		                    client streams the area and the turkey is in prompt range)
		         "restore"  force back to Auto (by date)
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }

local Server = game:GetService("ServerScriptService").Server
local PlayerDataService = require(Server.Services.PlayerDataService)
local EventService = require(Server.Services.EventService)
local TurkeySpawner = require(Server.Event.TurkeySpawner)
local EventConfig = require(ReplicatedStorage.Shared.Config.EventConfig)

local player = Players:GetPlayers()[1]
if player == nil then
	return "no player"
end
local profile = PlayerDataService.getProfile(player)
if profile == nil then
	return "no profile"
end

-- The event record as plain JSON-able facts.
local function status(extra: { [string]: any }?): string
	local event = profile.event
	local owned = {}
	for index in event.stickers do
		table.insert(owned, index)
	end
	table.sort(owned)
	local record = {
		active = EventService.isActive(),
		season = event.season,
		currentSeason = EventService.seasonId(),
		starterSeason = event.starterSeason,
		stickers = owned,
		count = EventConfig.countStickers(event.stickers),
		starters = EventConfig.StarterStickers,
	}
	for key, value in extra or {} do
		record[key] = value
	end
	return HttpService:JSONEncode(record)
end

if COMMAND == "force" then
	EventService.setForced("on")
	task.wait(1.6) -- the 1 Hz tick applies the change (welcome toast + starter grant)
	return status()
elseif COMMAND == "fresh" then
	EventService.resetSheet(player)
	local _, granted = EventService.resetStarter(player, true)
	-- A second join this season: the stamp holds, nothing more.
	local again = 0
	local event = profile.event
	if event.starterSeason ~= "" then
		local before = EventConfig.countStickers(event.stickers)
		local EventLogic = require(Server.Event.EventLogic)
		again = #EventLogic.grantStarters(event, event.season)
		assert(EventConfig.countStickers(event.stickers) == before + again)
	end
	return status({ granted = granted, again = again })
elseif COMMAND == "topup" then
	EventService.resetSheet(player)
	EventService.grantSticker(player, math.floor(ARGS[1] or 1))
	local _, granted = EventService.resetStarter(player, true)
	return status({ granted = granted })
elseif COMMAND == "status" then
	return status()
elseif COMMAND == "spawn" then
	local id = EventService.spawnTurkey(if ARGS[1] == 2 then "hub" else "plot", if ARGS[1] == 2 then nil else player)
	if id == nil then
		return HttpService:JSONEncode({ error = "spawn refused (cap / no plot)" })
	end
	local live = TurkeySpawner.get(id)
	local pose = EventConfig.pose(live.compiled, Workspace:GetServerTimeNow())
	return HttpService:JSONEncode({
		id = id,
		world = live.world,
		x = pose.position.X,
		y = pose.position.Y,
		z = pose.position.Z,
	})
elseif COMMAND == "goto" then
	local character = player.Character
	if character == nil then
		return "no character"
	end
	local target = Vector3.new(ARGS[1], ARGS[2], ARGS[3])
	character:PivotTo(CFrame.lookAt(target + Vector3.new(0, 4, 8), target + Vector3.new(0, 4, 0)))
	return "ok"
elseif COMMAND == "restore" then
	EventService.setForced(nil)
	return "auto"
end
return "unknown command"
