--!nocheck
--[[
	flavors_server.luau — server-VM steps for the owner R89 Surprise Batches / Flavour Book / Big Pop
	QA (tools/qa/flavors.py, ONE solo playtest, eval_server_runtime). Uses the same seams the admin
	panel uses (FlavorService.setSettings / adminForce / adminReset).

		COMMAND  "prep"    tutorial finished, Garage Lab pads up to Uncle Atom granted (the Workbench
		                   runs automated), flavours ON at x1 odds + Big Pop ON, the Book cleared;
		                   returns status()
		         "force"   FlavorService.adminForce(player, rank ARGS[1]) — the NEXT finished batch
		                   becomes that flavour (the whole real pipeline); returns the message
		         "seed"    marks a few more Book entries found (Nuke Town Sprinkle / Glitter, Dino
		                   Sprinkle) so the Book shows every tile state; pushes `flavors`
		         "luck"    FlavorService.setSettings(true, ARGS[1], true) (the Book's LUCK chip)
		         "status"  status(): Book, gems, settings, Big Pop counters, producer automation
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]]
}

local Server = game:GetService("ServerScriptService").Server
local PlayerDataService = require(Server.Services.PlayerDataService)
local TycoonService = require(Server.Tycoon.TycoonService)
local TutorialLogic = require(Server.Tycoon.TutorialLogic)
local FlavorService = require(Server.Tycoon.FlavorService)
local BigPop = require(Server.Tycoon.BigPop)
local FlavorConfig = require(ReplicatedStorage.Shared.Config.FlavorConfig)
local FlavorLogic = require(ReplicatedStorage.Shared.Tycoon.FlavorLogic)

local player = Players:GetPlayers()[1]
if player == nil then
	return "no player"
end
local profile = PlayerDataService.getProfile(player)
if profile == nil then
	return "no profile"
end

-- Garage Lab pads through the Paint Station, in buy order (owner R122: Uncle Atom is pad 4).
local AREA1 = {
	"a1_workbench",
	"a1_tool_wall",
	"a1_glow_lamp",
	"a1_uncle_atom",
	"a1_garage_door",
	"a1_mini_reactor",
	"a1_paint_station",
}

local function status()
	return {
		book = FlavorLogic.toWire(profile.flavors),
		claimable = FlavorLogic.claimable(profile.flavors),
		gems = profile.gems,
		settings = FlavorService.settings(),
		bigPop = BigPop.stats(),
		pads = profile.tycoon.pads.a1_uncle_atom == true,
		tutorialStep = profile.tycoon.tutorialStep,
		world = player:GetAttribute("CurrentWorld"),
		attrs = {
			enabled = ReplicatedStorage:GetAttribute(FlavorConfig.Attr.Enabled),
			luck = ReplicatedStorage:GetAttribute(FlavorConfig.Attr.Luck),
		},
	}
end

if COMMAND == "prep" then
	profile.tycoon.tutorialStep = TutorialLogic.DoneStep
	local granted = TycoonService.grantPads(player, AREA1, false)
	FlavorService.setSettings(true, 1, true)
	FlavorService.adminReset(player)
	local out = status()
	out.granted = granted
	return HttpService:JSONEncode(out)
elseif COMMAND == "force" then
	local def = FlavorConfig.byRank(math.floor(ARGS[1] or 4))
	local ok, message = FlavorService.adminForce(player, if def ~= nil then def.id else nil)
	return HttpService:JSONEncode({ ok = ok, message = message })
elseif COMMAND == "seed" then
	FlavorLogic.addFound(profile.flavors, "main", 1, 12)
	FlavorLogic.addFound(profile.flavors, "main", 2, 3)
	FlavorLogic.addFound(profile.flavors, "dino", 1, 2)
	PlayerDataService.markChanged(player, false, { "flavors" })
	return HttpService:JSONEncode(status())
elseif COMMAND == "luck" then
	local ok, message = FlavorService.setSettings(true, ARGS[1] or 1, true)
	return HttpService:JSONEncode({ ok = ok, message = message })
elseif COMMAND == "status" then
	return HttpService:JSONEncode(status())
end
return "unknown command"
