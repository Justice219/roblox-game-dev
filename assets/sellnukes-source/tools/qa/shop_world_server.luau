--!strict
--[[
	shop_world_server.luau — SERVER half of the Shop world-section check (eval_server_runtime; driven
	by tools/qa/shop_world.py, which fills COMMAND and WORLD with whitelisted values only).

	Commands (everything through the REAL game code: AdminService.dispatchAsync runs the owner-admin
	pipeline — re-auth, schema validation, audit — exactly like the admin panel):
		unlock   remembers whether WORLD was unlocked for player 1, then runs admin "WorldUnlock"
		restore  runs "WorldRelock" only if WORLD was locked before `unlock` (the test profile is put
		         back exactly; Studio's DataStore is separate from production)
		state    { unlocked, enabled } of WORLD for player 1
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local COMMAND = "__COMMAND__"
local WORLD = "__WORLD__"

local Server = ServerScriptService:WaitForChild("Server")
local AdminService = (require :: any)(Server.Services.AdminService)
local WorldService = (require :: any)(Server.Tycoon.WorldService)
local AdminConfig = (require :: any)(ReplicatedStorage.Shared.Config.AdminConfig)

local player = Players:GetPlayers()[1]
if player == nil then
	return "ERROR no player"
end

-- Runs one admin command as the (Studio owner) player, targeting themselves when needed.
local function dispatch(name: string): string
	local args: { [string]: any } = { world = WORLD }
	local command = AdminConfig.Commands[name]
	if command ~= nil and command.target == "Player" then
		args.userId = player.UserId
	end
	local caller = { userId = player.UserId, name = player.Name, player = player }
	local result = AdminService.dispatchAsync(caller, name, args)
	return `{name}: {if result.ok == true then "ok" else "failed"} ({tostring(result.message)})`
end

local memo = (_G :: any).__ShopWorldQA
if memo == nil then
	memo = {}
	;(_G :: any).__ShopWorldQA = memo
end

if COMMAND == "unlock" then
	memo[WORLD] = WorldService.isUnlocked(player, WORLD) == true
	if memo[WORLD] then
		return `{WORLD} already unlocked`
	end
	return dispatch("WorldUnlock")
elseif COMMAND == "restore" then
	if memo[WORLD] == false then
		memo[WORLD] = nil
		return dispatch("WorldRelock")
	end
	return `{WORLD} left as it was (unlocked before the check)`
elseif COMMAND == "state" then
	return `unlocked={tostring(WorldService.isUnlocked(player, WORLD))}`
end
return "ERROR unknown command"
