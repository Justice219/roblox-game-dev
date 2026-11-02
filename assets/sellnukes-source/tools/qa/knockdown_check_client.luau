--!strict
--[[
	knockdown_check_client.luau — CLIENT half of the knockdown Studio QA (owner R50,
	tools/qa/knockdown_check.py, eval_client_runtime). Placeholders filled with whitelisted values only:
		COMMAND  "state" | "camera" | "camera_reset" | "slow" | "tap" | "modal_close"
		ARGS     numbers: camera = { area }, slow = { scale }, tap = { area, count }

	state         JSON: ready flags, PlotIndex, KnockdownFx.stats(), chip visible + text, dazed stars on
	camera        Scriptable camera on the area's high three-quarter view (slot-local frame, same
	              framing as tools/qa/world_tour.luau "areaNN_high")
	camera_reset  back to the default follow camera
	slow          KnockdownFx + BuildInController time scale (frame captures)
	tap           fires KnockdownTap(area) `count` times, 0.2 s apart (the real HUD-chip intent)
	modal_close   closes every open modal window (WelcomeBack etc. cover the world)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local COMMAND = "__COMMAND__"
local ARGS: { number } = { --[[ARGS]]
}

local player = Players.LocalPlayer
local client = player:WaitForChild("PlayerScripts"):WaitForChild("Client")
local WorldLayout = (require :: any)(ReplicatedStorage.Shared.Config.WorldLayout)
local Remotes = (require :: any)(ReplicatedStorage.Shared.Net.Remotes)
local KnockdownFx = (require :: any)(client.Tycoon.BuildIn.KnockdownFx)
local BuildInController = (require :: any)(client.Tycoon.BuildIn.BuildInController)
local ScreenManager = (require :: any)(client.UI.ScreenManager)
local camera = workspace.CurrentCamera

if COMMAND == "state" then
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	local hud = playerGui and playerGui:FindFirstChild("KnockdownHud")
	local root = hud and hud:FindFirstChild("KnockdownHudRoot")
	local chip = root and root:FindFirstChild("KnockdownChip")
	local stars = 0
	for _, item in workspace:GetDescendants() do
		if item:IsA("BillboardGui") and item.Name == "DazedStars" and item.Enabled then
			stars += 1
		end
	end
	local title = ""
	if chip ~= nil then
		for _, label in chip:GetDescendants() do
			if label:IsA("TextLabel") and label.Text ~= "" and #label.Text > #title then
				title = label.Text
			end
		end
	end
	return HttpService:JSONEncode({
		plotIndex = player:GetAttribute("PlotIndex") or 0,
		loadingDone = player:GetAttribute("LoadingDone") == true,
		modal = ScreenManager.topModalName() or "",
		fx = KnockdownFx.stats(),
		chip = chip ~= nil and (chip :: GuiObject).Visible,
		chipText = title,
		dazedStars = stars,
	})
elseif COMMAND == "camera" then
	local index = player:GetAttribute("PlotIndex")
	if type(index) ~= "number" or index < 1 then
		return "no plot"
	end
	local slot = WorldLayout.slotOrigin(index, ARGS[1])
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = 62
	camera.CFrame = CFrame.lookAt((slot * CFrame.new(42, 46, -38)).Position, (slot * CFrame.new(0, 4, 30)).Position)
	return "camera"
elseif COMMAND == "camera_reset" then
	camera.CameraType = Enum.CameraType.Custom
	camera.FieldOfView = 70
	return "reset"
elseif COMMAND == "slow" then
	KnockdownFx.setTimeScale(ARGS[1])
	BuildInController.setTimeScale(ARGS[1])
	return "slow"
elseif COMMAND == "tap" then
	local remote = Remotes.event("KnockdownTap")
	for _ = 1, math.clamp(math.floor(ARGS[2]), 1, 20) do
		remote:FireServer(ARGS[1])
		task.wait(0.2)
	end
	return "tapped"
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
