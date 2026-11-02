--!nocheck
--[[
	manager_tags_client.luau — CLIENT half of the R87 manager nametag Studio QA (M-managers), run by
	tools/qa/manager_tags.py through eval_client_runtime during ONE solo playtest.
	Placeholders filled with whitelisted values only:
		COMMAND  "diag" | "camera" | "camera_reset" | "probe" | "bubble" | "hold" | "modal_close"
		ARGS     numbers: camera = { area, back, up }, hold = { seconds }

	diag          loading done, PlotIndex, ManagerController.stats()
	camera        Scriptable camera like the default follow camera: `back` studs behind the
	              character and `up` above it, looking at the area's manager (head height)
	camera_reset  back to the default follow camera
	probe         JSON: stats, the local player's tags (tagStats), enabled ManagerTag / ManagerBubble
	              billboards in PlayerGui (text + size), the current device class
	bubble        ManagerController.debugBubbleNow() (the next refresh lets a manager speak)
	hold          ManagerController.debugBubbleNow(seconds): the bubble up stays that long
	modal_close   closes every open modal window (WelcomeBack etc. cover the world)
	Presentation only: nothing here changes server state.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }

local player = Players.LocalPlayer
local client = player:WaitForChild("PlayerScripts"):WaitForChild("Client")
local ManagerController = require(client.Tycoon.Npc.ManagerController)
local ScreenManager = require(client.UI.ScreenManager)
local ManagerNpcConfig = require(ReplicatedStorage.Shared.Config.ManagerNpcConfig)
local camera = workspace.CurrentCamera

-- The local player's Nuke Town plot model.
local function plotModel(): Model?
	local index = player:GetAttribute("PlotIndex")
	local plots = workspace:FindFirstChild("Plots")
	if type(index) ~= "number" or plots == nil then
		return nil
	end
	return plots:FindFirstChild(`Plot{index}`)
end

-- The spawned manager mesh model of `area` on the local plot (MeshKey = the area's manager key).
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

if COMMAND == "diag" then
	return HttpService:JSONEncode({
		loadingDone = player:GetAttribute("LoadingDone") == true,
		plotIndex = player:GetAttribute("PlotIndex") or 0,
		modal = ScreenManager.topModalName() or "",
		stats = ManagerController.stats(),
	})
elseif COMMAND == "camera" then
	local model = managerModel(ARGS[1])
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if model == nil or root == nil then
		return `no manager / root (area {ARGS[1]})`
	end
	local target = model:GetPivot().Position + Vector3.new(0, 4.5, 0)
	local eye = root.Position - root.CFrame.LookVector * ARGS[2] + Vector3.new(0, ARGS[3], 0)
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = 70
	camera.CFrame = CFrame.lookAt(eye, target)
	return HttpService:JSONEncode({ distance = math.floor((target - eye).Magnitude) })
elseif COMMAND == "camera_reset" then
	camera.CameraType = Enum.CameraType.Custom
	camera.FieldOfView = 70
	return "reset"
elseif COMMAND == "probe" then
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	local tags, bubbles = {}, {}
	for _, item in playerGui:GetChildren() do
		if item:IsA("BillboardGui") and item.Enabled then
			if item.Name == "ManagerTag" then
				local name = item:FindFirstChild("Name")
				local runs = item:FindFirstChild("Runs")
				local role = item:FindFirstChild("Role", true)
				table.insert(tags, {
					role = role and role.Text or "",
					name = name and name.Text or "",
					runs = runs and runs.Text or "",
					pixels = { math.floor(item.AbsoluteSize.X), math.floor(item.AbsoluteSize.Y) },
					adornee = item.Adornee and item.Adornee.Name or "",
				})
			elseif item.Name == "ManagerBubble" then
				local line = item:FindFirstChild("Line", true)
				table.insert(bubbles, { line = line and line.Text or "", adornee = item.Adornee and item.Adornee.Name or "" })
			end
		end
	end
	local snapshot = ManagerController.tagStats()
	local mine = {}
	for _, entry in snapshot.list do
		if entry.mine and entry.distance <= 120 then
			table.insert(mine, entry)
		end
	end
	return HttpService:JSONEncode({
		stats = ManagerController.stats(),
		device = ScreenManager.device.class,
		viewport = { math.floor(camera.ViewportSize.X), math.floor(camera.ViewportSize.Y) },
		mine = mine,
		enabledTags = tags,
		enabledBubbles = bubbles,
		bubbleState = snapshot.bubbles,
	})
elseif COMMAND == "bubble" then
	ManagerController.debugBubbleNow()
	return "bubble due"
elseif COMMAND == "hold" then
	ManagerController.debugBubbleNow(ARGS[1])
	return "held"
elseif COMMAND == "modal_close" then
	local closed = 0
	while ScreenManager.anyModalOpen() and closed < 6 do
		ScreenManager.closeTopModal()
		closed += 1
		task.wait(0.3)
	end
	return `closed {closed}`
end
return "unknown"
