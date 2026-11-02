--!nocheck
--[[
	attack_view_server.luau — SERVER half of the owner R104 / R105 / R106 Studio QA
	(tools/qa/attack_view.py, eval_server_runtime, ONE solo playtest). The shared setup commands
	(prepare / area / grant / testnuke / restore / focus) come from defense_towers_server.luau.
	Placeholders are filled with whitelisted values only:
		COMMAND  "bot" | "bots_clear" | "focus_stats" | "plot"
		ARGS     numbers (see each command)

	bot          { area, aa }: an admin test bot (Server/Attack/TestBots) on a free plot — a target
	             across the hub, outside the player's stream radius (the R104 repro)
	bots_clear   removes every test bot
	focus_stats  JSON: Server/Attack/PickerFocus.stats() + the focus parts under Workspace.SN_PickerFoci
	plot         JSON: the player's plot index + the plots of the bots
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]]
}

local Server = game:GetService("ServerScriptService").Server
local PickerFocus = require(Server.Attack.PickerFocus)
local TestBots = require(Server.Attack.TestBots)
local AttackConfig = require(game:GetService("ReplicatedStorage").Shared.Config.AttackConfig)

local player = Players:GetPlayers()[1]
if player == nil then
	return HttpService:JSONEncode({ error = "no player" })
end

local function botPlots()
	local list = {}
	for _, bot in TestBots.all() do
		table.insert(list, { id = bot.id, plot = bot.plotIndex, area = bot.area, aa = bot.aa, ready = bot.ready })
	end
	return list
end

if COMMAND == "bot" then
	local bot, message = TestBots.spawn(player, { area = math.floor(ARGS[1] or 9), aa = math.floor(ARGS[2] or 3), shield = false })
	return HttpService:JSONEncode({ ok = bot ~= nil, message = message, bots = botPlots() })
elseif COMMAND == "bots_clear" then
	return HttpService:JSONEncode({ removed = TestBots.removeAll() })
elseif COMMAND == "focus_stats" then
	local stats = PickerFocus.stats()
	local parts = {}
	local folder = Workspace:FindFirstChild("SN_PickerFoci")
	if folder ~= nil then
		for _, part in folder:GetChildren() do
			if part:IsA("BasePart") then
				table.insert(parts, { part.Position.X, part.Position.Y, part.Position.Z })
			end
		end
	end
	local slots = {}
	for userId, slot in stats.slots do
		slots[tostring(userId)] = slot
	end
	return HttpService:JSONEncode({ count = stats.count, slots = slots, parts = parts, mine = slots[tostring(player.UserId)] })
elseif COMMAND == "plot" then
	return HttpService:JSONEncode({ plot = player:GetAttribute(AttackConfig.Attr.Plot), bots = botPlots() })
end
return "unknown command"
