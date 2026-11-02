--!nocheck
--[[
	lucky_buttons_client.luau — CLIENT half of the Lucky Buttons Studio QA (owner R69), run by
	tools/qa/lucky_buttons.py through eval_client_runtime in ONE solo playtest.

		COMMAND  "diag"         HUD shown, live count, models in the folder (+ label text), arrow chip
		         "look_button"  scriptable camera looking at the nearest button from ARGS[1] studs
		         "look_away"    scriptable camera looking AWAY from it (the edge arrow must show)
		         "camera_reset" camera back to Custom
		         "close_all"    closes every modal (boot windows)
	Presentation only (camera + reads). No intents are sent from here: claims come from the real
	walk-in detection in LuckyButtonClient.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }

local client = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local LuckyButtonClient = require(client.LuckyButtons.LuckyButtonClient)
local ScreenManager = require(client.UI.ScreenManager)

local function arrowState()
	local gui = ScreenManager.getGui("LuckyArrow")
	local chip = gui and gui:FindFirstChild("Chip", true)
	if chip == nil then
		return { exists = false }
	end
	local pointer = chip:FindFirstChild("Pointer")
	return {
		exists = true,
		visible = chip.Visible,
		x = math.floor(chip.AbsolutePosition.X),
		y = math.floor(chip.AbsolutePosition.Y),
		rotation = pointer and pointer.Rotation or 0,
	}
end

if COMMAND == "diag" then
	local folder = Workspace:FindFirstChild("SN_LuckyButtons")
	local labels = {}
	if folder ~= nil then
		for _, model in folder:GetChildren() do
			local label = model:FindFirstChild("Label", true)
			table.insert(labels, label and label.Text or "?")
		end
	end
	local hud = ScreenManager.getGui("Hud")
	local target = LuckyButtonClient.nearest()
	return HttpService:JSONEncode({
		hud = hud ~= nil and hud.Enabled,
		live = LuckyButtonClient.count(),
		models = folder and #folder:GetChildren() or 0,
		labels = labels,
		arrow = arrowState(),
		nearest = target and target.kind or "",
		stats = LuckyButtonClient.stats(),
		top = ScreenManager.topModalName() or "",
	})
elseif COMMAND == "look_button" or COMMAND == "look_away" then
	local target = LuckyButtonClient.nearest()
	local camera = Workspace.CurrentCamera
	if target == nil or camera == nil then
		return "none"
	end
	local distance = ARGS[1] or 22
	local eye = target.position + Vector3.new(0, distance * 0.55, distance)
	camera.CameraType = Enum.CameraType.Scriptable
	if COMMAND == "look_button" then
		camera.CFrame = CFrame.lookAt(eye, target.position + Vector3.new(0, 2, 0))
	else
		camera.CFrame = CFrame.lookAt(eye, eye + Vector3.new(0.6, -0.15, 1))
	end
	task.wait(0.3)
	return HttpService:JSONEncode(arrowState())
elseif COMMAND == "camera_reset" then
	Workspace.CurrentCamera.CameraType = Enum.CameraType.Custom
	return "ok"
elseif COMMAND == "close_all" then
	ScreenManager.closeAllModals()
	return "closed"
end
return "unknown"
