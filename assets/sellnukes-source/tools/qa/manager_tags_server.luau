--!nocheck
--[[
	manager_tags_server.luau — SERVER half of the R87 manager nametag Studio QA (M-managers), run by
	tools/qa/manager_tags.py through eval_server_runtime during ONE solo playtest.
	Placeholders filled with whitelisted values only:
		COMMAND  "setup" | "focus" | "knock" | "rebuild"
		ARGS     numbers: setup = { area }, focus = { area, distance }, knock = { area, seconds }

	setup    waits for the tycoon, counts the Nuke Town managers already owned; only when fewer
	         than `area - 1` are owned, TycoonAdmin.setArea(area) — ADDITIVE (grants the missing
	         pads of areas 1..area-1 with build-in, never removes anything) — then waits until the
	         plot stops changing. Studio profiles are "_Studio" stores (live saves untouched).
	focus    stands the character `distance` studs from the area's manager on the plot-entrance
	         side, facing it (PlotService.teleport), so the default camera sees it like a player
	knock    Knockdown.adminKnock(area, seconds) (the admin test path: bypasses switch / immunity)
	rebuild  Knockdown.forceRebuild (puts every knocked area back at once)
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }

local Server = ServerScriptService:WaitForChild("Server")
local Knockdown = require(Server.Tycoon.Knockdown)
local PlotService = require(Server.Tycoon.PlotService)
local TycoonAdmin = require(Server.Tycoon.TycoonAdmin)
local TycoonService = require(Server.Tycoon.TycoonService)
local ManagerNpcConfig = require(ReplicatedStorage.Shared.Config.ManagerNpcConfig)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)

local player = Players:GetPlayers()[1]
if player == nil then
	return "no player"
end

local function plotModel(): Model?
	local index = PlotService.getPlotIndex(player)
	local plots = workspace:FindFirstChild("Plots")
	return if index ~= nil and plots ~= nil then plots:FindFirstChild(`Plot{index}`) else nil
end

-- The spawned manager mesh model of `area` (MeshKey = the area's manager key), or nil.
local function managerModel(area: number): Model?
	local plot = plotModel()
	local key = ManagerNpcConfig.ManagerKeys[area]
	if plot == nil or key == nil then
		return nil
	end
	for _, item in plot:GetDescendants() do
		if item:IsA("Model") and item:GetAttribute("MeshKey") == key then
			return item
		end
	end
	return nil
end

local function ownedManagers(): number
	local count = 0
	for area = 1, #ManagerNpcConfig.ManagerKeys do
		if managerModel(area) ~= nil then
			count += 1
		end
	end
	return count
end

-- Waits until the plot's descendant count is unchanged for `settle` seconds (or `limit` passes).
local function waitStable(settle: number, limit: number): number
	local model = plotModel()
	if model == nil then
		return -1
	end
	local last, stableSince, started = -1, os.clock(), os.clock()
	while os.clock() - started < limit do
		local count = #model:GetDescendants()
		if count ~= last then
			last, stableSince = count, os.clock()
		elseif os.clock() - stableSince >= settle then
			break
		end
		task.wait(0.25)
	end
	return last
end

if COMMAND == "setup" then
	local started = os.clock()
	while not TycoonService.isReady(player) and os.clock() - started < 60 do
		task.wait(0.25)
	end
	local before = ownedManagers()
	local message = "already owned"
	if before < ARGS[1] - 1 then
		local _, text = TycoonAdmin.setArea(player, ARGS[1])
		message = text or ""
		task.wait(1)
		waitStable(3, 45)
	end
	return HttpService:JSONEncode({
		ready = TycoonService.isReady(player),
		before = before,
		after = ownedManagers(),
		message = message,
		plotIndex = PlotService.getPlotIndex(player) or 0,
	})
elseif COMMAND == "focus" then
	local index = PlotService.getPlotIndex(player)
	local model = managerModel(ARGS[1])
	if index == nil or model == nil then
		return `no plot / manager (area {ARGS[1]})`
	end
	local pivot = model:GetPivot().Position
	local entry = (WorldLayout.slotOrigin(index, ARGS[1]) * CFrame.new(0, 4, -8)).Position
	local flat = Vector3.new(entry.X - pivot.X, 0, entry.Z - pivot.Z)
	local direction = if flat.Magnitude > 0.1 then flat.Unit else Vector3.new(0, 0, -1)
	local stand = Vector3.new(pivot.X, entry.Y, pivot.Z) + direction * ARGS[2]
	local ok = PlotService.teleport(player, CFrame.lookAt(stand, Vector3.new(pivot.X, stand.Y, pivot.Z)))
	return HttpService:JSONEncode({ ok = ok, distance = math.floor((stand - pivot).Magnitude) })
elseif COMMAND == "knock" then
	local ok, reason = Knockdown.adminKnock(player, ARGS[1], ARGS[2])
	return HttpService:JSONEncode({ ok = ok, reason = reason or "" })
elseif COMMAND == "rebuild" then
	return tostring(Knockdown.forceRebuild(player))
end
return "unknown"
