--!nocheck
--[[
	lucky_buttons_server.luau — SERVER half of the Lucky Buttons Studio QA (owner R69), run by
	tools/qa/lucky_buttons.py through eval_server_runtime in ONE solo playtest (Studio lock held).
	The driver substitutes COMMAND (whitelisted) and ARGS (numbers only).

		COMMAND  "setup"       interval multiplier ARGS[1]; player facts (plot, world, NPM, cash)
		         "to_plot"     stands the character on its own plot (area 1, slot-local 0, 45)
		         "status"      LuckyButtonService.status() + the player's live buttons
		         "near_button" stands the character ARGS[1] studs from the first live button
		         "to_button"   stands the character ON the first live button (walk-in claim)
		         "spawn"       LuckyButtonService.spawnFor(player, KIND) (KIND = ARGS[1] index)
		         "cash"        the profile's cash
		         "reset"       interval 1, clears every button
	Everything goes through the real service code (admin seam spawnFor, real claim remote from the
	client's walk-in). Studio DataStores are separate from production.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }

local Server = ServerScriptService:WaitForChild("Server")
local LuckyButtonService = require(Server.Services.LuckyButtonService)
local LuckyButtonConfig = require(ReplicatedStorage.Shared.Config.LuckyButtonConfig)
local PlayerDataService = require(Server.Services.PlayerDataService)
local PlotService = require(Server.Tycoon.PlotService)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)
local WorldService = require(Server.Tycoon.WorldService)

local player = Players:GetPlayers()[1]
if player == nil then
	return "no player"
end

local function root(): BasePart?
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

local function stand(position: Vector3, lookAt: Vector3?)
	local character = player.Character
	if character == nil then
		return
	end
	local at = position + Vector3.new(0, 3, 0)
	local target = lookAt or (at + Vector3.new(0, 0, -1))
	character:PivotTo(CFrame.lookAt(at, Vector3.new(target.X, at.Y, target.Z)))
end

local function firstButton()
	return LuckyButtonService.buttonsOf(player)[1]
end

if COMMAND == "setup" then
	ReplicatedStorage:SetAttribute(LuckyButtonConfig.IntervalAttribute, ARGS[1] or 1)
	ReplicatedStorage:SetAttribute(LuckyButtonConfig.EnabledAttribute, true)
	local profile = PlayerDataService.getProfile(player)
	return HttpService:JSONEncode({
		plot = PlotService.getPlotIndex(player),
		world = WorldService.currentWorld(player),
		npm = PlayerDataService.isNewPlayerMode(player),
		cash = profile and profile.cash or -1,
		loaded = profile ~= nil,
	})
elseif COMMAND == "to_plot" then
	local plot = PlotService.getPlotIndex(player)
	if plot == nil then
		return "no plot"
	end
	local world = WorldService.currentWorld(player)
	stand(WorldLayout.slotPointToWorld(plot, 1, Vector3.new(0, 0, 45), world))
	return "ok"
elseif COMMAND == "status" then
	local list = {}
	for _, wire in LuckyButtonService.buttonsOf(player) do
		table.insert(list, {
			id = wire.id,
			kind = wire.kind,
			x = wire.position.X,
			y = wire.position.Y,
			z = wire.position.Z,
			amount = wire.amount,
			product = wire.product,
		})
	end
	local r = root()
	return HttpService:JSONEncode({
		status = LuckyButtonService.status(),
		buttons = list,
		root = r and { r.Position.X, r.Position.Y, r.Position.Z } or nil,
	})
elseif COMMAND == "near_button" then
	local wire = firstButton()
	if wire == nil then
		return "none"
	end
	local away = (ARGS[1] or 16)
	stand(wire.position + Vector3.new(0, 0, away), wire.position)
	return "ok"
elseif COMMAND == "to_button" then
	local wire = firstButton()
	if wire == nil then
		return "none"
	end
	stand(wire.position)
	return wire.id
elseif COMMAND == "spawn" then
	local kind = LuckyButtonConfig.KindIds[math.floor(ARGS[1] or 1)]
	local ok, result = LuckyButtonService.spawnFor(player, kind)
	return HttpService:JSONEncode({ ok = ok, result = result, kind = kind })
elseif COMMAND == "cash" then
	local profile = PlayerDataService.getProfile(player)
	return tostring(profile and profile.cash or -1)
elseif COMMAND == "reset" then
	ReplicatedStorage:SetAttribute(LuckyButtonConfig.IntervalAttribute, 1)
	LuckyButtonService.clearAll()
	return "reset"
end
return "unknown"
