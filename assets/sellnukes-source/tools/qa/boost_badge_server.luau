--!nocheck
--[[
	boost_badge_server.luau — SERVER half of the R82 boost-badge Studio QA (B-boost), run by
	tools/qa/boost_badge.py through eval_server_runtime in ONE solo playtest (Studio lock held).
	The driver substitutes COMMAND (whitelisted) and ARGS (numbers only). Every boost goes through
	the real server code paths (the same seams the admin panel / purchases use), never the client.

		COMMAND  "status"       profile.boosts, rush, server boost end, online cash multiplier
		         "grant_cash"   BoostService.grant(player, "cash2x", ARGS[1] seconds) (purchase path)
		         "grant_rookie" RushService.grant(player, "rookie", ARGS[1]) (admin RushGrant seam)
		         "server_on"    ServerBoostService.start(ARGS[1], "QA") (the product's grant step)
		         "server_off"   ServerBoostService.stop() (admin seam)
		         "fake_friends" DISPLAY ONLY Social push (+20 %): a solo playtest has no second
		                        Roblox friend (owner R72)
		         "no_friends"   DISPLAY ONLY: back to 0 friends
		         "cleanup"      ends what this QA started: rush cleared, server boost stopped, friends
		                        reset; ARGS[1] = 1 also removes cash2x (only when the driver saw none
		                        before the test, so a real boost on the Studio profile is kept)
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }

local Server = ServerScriptService:WaitForChild("Server")
local BoostService = require(Server.Services.BoostService)
local ModifierHook = require(Server.Retention.ModifierHook)
local ModifierSources = require(Server.Tycoon.ModifierSources)
local PlayerDataService = require(Server.Services.PlayerDataService)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local RushService = require(Server.Services.RushService)
local ServerBoostService = require(Server.Services.ServerBoostService)
local Modifiers = require(ReplicatedStorage.Shared.Tycoon.Modifiers)

local player = Players:GetPlayers()[1]
if player == nil then
	return "no player"
end

local function status()
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return { loaded = false }
	end
	local online = ModifierSources.build(player, profile)
	return {
		loaded = true,
		boosts = profile.boosts,
		rush = { rookieLeft = profile.rush.rookieLeft, comebackUntil = profile.rush.comebackUntil },
		serverEndsAt = ServerBoostService.endsAt(),
		now = os.time(),
		cash = Modifiers.resolve(online).cash,
	}
end

local out
if COMMAND == "status" then
	out = status()
elseif COMMAND == "grant_cash" then
	out = { expires = BoostService.grant(player, "cash2x", ARGS[1]), status = status() }
elseif COMMAND == "grant_rookie" then
	out = { granted = RushService.grant(player, "rookie", ARGS[1]), status = status() }
elseif COMMAND == "server_on" then
	out = { endsAt = ServerBoostService.start(ARGS[1], "QA"), status = status() }
elseif COMMAND == "server_off" then
	ServerBoostService.stop()
	out = status()
elseif COMMAND == "fake_friends" then
	Remotes.fireClient("Social", player, { kind = "friends", count = 2, percent = 20, names = { "Bob", "Ann" } })
	out = { sent = true }
elseif COMMAND == "no_friends" then
	Remotes.fireClient("Social", player, { kind = "friends", count = 0, percent = 0, names = {} })
	out = { sent = true }
elseif COMMAND == "cleanup" then
	RushService.clear(player)
	ServerBoostService.stop()
	Remotes.fireClient("Social", player, { kind = "friends", count = 0, percent = 0, names = {} })
	local profile = PlayerDataService.getProfile(player)
	if ARGS[1] == 1 and profile ~= nil and profile.boosts.cash2x ~= nil then
		profile.boosts.cash2x = nil
		PlayerDataService.markChanged(player, true, { "boosts" })
		ModifierHook.invalidate(player)
	end
	out = status()
else
	out = { error = "unknown command" }
end
return HttpService:JSONEncode(out)
