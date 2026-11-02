--!nocheck
--[[
	r88_plot_name_client.luau — client-VM probe for the owner R88 plot names (N-plotname), run by
	tools/qa/r88_plot_name.py through eval_client_runtime during ONE solo playtest.

	Placeholders filled by the runner with whitelisted values only (world_tour.render):
		COMMAND  one of the commands below
		ARGS     numbers (unused today; kept for the shared render helper)

		"diag"     HUD + profile loaded, PlotIndex, PlotRevealed, live PlotSign rigs, profile.plotName
		"calm"     closes every open modal (join pop-ups such as WELCOME BACK pause the rigs on
		           purpose: nothing opens over another window) so the shots show the feature
		"walk"     stands the character just outside its own entrance arch, facing the plot, with a
		           Scriptable camera behind it looking at the arch; promptShown = the walk-up prompt's
		           PromptShown fired (its CoreGui UI is not in Studio captures)
		"clickcam" HUD on, Scriptable camera on the sign from the road; returns the sign centre in
		           viewport pixels (the runner clicks it with simulate_mouse_input: a REAL click on
		           the client ClickDetector, which must open the window)
		"ray"      the click path's geometry: a camera ray through the sign centre (what a mouse click
		           / tap raycasts) must hit the client ClickBox first, within the detector's reach
		"hover"    turns the sign's hover Highlight on (what a mouse hover shows) for a shot
		"unhover"  turns it off again
		"open"     ScreenManager.open("RenameStand", { mode = "plot" }) — returns the window state
		"close"    closes the window
		"rename"   fires the REAL RenamePlot remote with the preset QA name "Sparkle Base"
		"reset"    fires RenamePlot("") (the RESET intent)
		"signcam"  HUD hidden, Scriptable camera on the sign from the road (clean sign shots)
		"camoff"   restores the HUD, the default camera and the character
		"probe"    sign label texts, the plot's PlotName attribute, profile.plotName, rig state
	Presentation + real remotes only: every rule (validation, filter, save) runs on the server.
]]

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }
local _ = ARGS

local QA_NAME = "Sparkle Base"

local LOCAL = Players.LocalPlayer
local client = LOCAL:WaitForChild("PlayerScripts"):WaitForChild("Client")
local ClientState = require(client.ClientState)
local ScreenManager = require(client.UI.ScreenManager)
local PlotSign = require(client.Tycoon.PlotSign)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local PlotNameConfig = require(ReplicatedStorage.Shared.Config.PlotNameConfig)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)

local camera = workspace.CurrentCamera
local playerGui = LOCAL:WaitForChild("PlayerGui")

-- The local player's sign part in Nuke Town (tagged, inside the owned plot), or nil.
local function mySign(): BasePart?
	for _, sign in CollectionService:GetTagged(PlotNameConfig.SignTag) do
		local node = sign
		while node ~= nil and node:GetAttribute("OwnerUserId") == nil do
			node = node.Parent
		end
		if node ~= nil and node:GetAttribute("OwnerUserId") == LOCAL.UserId and node:GetAttribute("WorldId") == "main" then
			return sign, node
		end
	end
	return nil
end

local function labels(sign: BasePart?): { string }
	local out = {}
	if sign ~= nil then
		for _, item in sign:GetDescendants() do
			if item:IsA("TextLabel") then
				table.insert(out, item.Text)
			end
		end
	end
	return out
end

local function setCharacterHidden(hidden: boolean)
	local character = LOCAL.Character
	if character == nil then
		return
	end
	for _, item in character:GetDescendants() do
		if item:IsA("BasePart") or item:IsA("Decal") then
			item.LocalTransparencyModifier = if hidden then 1 else 0
		end
	end
end

local function setHud(on: boolean)
	for _, gui in playerGui:GetChildren() do
		if gui:IsA("ScreenGui") then
			if on and gui:GetAttribute("QaWasEnabled") then
				gui:SetAttribute("QaWasEnabled", nil)
				gui.Enabled = true
			elseif not on and gui.Enabled then
				gui:SetAttribute("QaWasEnabled", true)
				gui.Enabled = false
			end
		end
	end
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, on)
	end)
end

local function rigOf(sign: BasePart?): (Instance?, ProximityPrompt?, Highlight?)
	local box = if sign ~= nil then sign:FindFirstChild(PlotSign.ClickBoxName) else nil
	local prompt = if box ~= nil then box:FindFirstChild(PlotSign.PromptName, true) else nil
	local highlight = if box ~= nil then box:FindFirstChildWhichIsA("Highlight") else nil
	return box, prompt, highlight
end

local function probe(): { [string]: any }
	local sign, plot = mySign()
	local box, prompt, highlight = rigOf(sign)
	local profile = ClientState.profile
	return {
		plotIndex = LOCAL:GetAttribute("PlotIndex"),
		sign = sign ~= nil,
		labels = labels(sign),
		plotNameAttr = if plot ~= nil then plot:GetAttribute("PlotName") else nil,
		profilePlotName = if profile ~= nil then profile.plotName else nil,
		rigs = #PlotSign.signs(),
		clickBox = box ~= nil,
		prompt = if prompt ~= nil
			then {
				action = prompt.ActionText,
				enabled = prompt.Enabled,
				hold = prompt.HoldDuration,
				distance = prompt.MaxActivationDistance,
				key = prompt.KeyboardKeyCode.Name,
				pad = prompt.GamepadKeyCode.Name,
			}
			else nil,
		highlight = if highlight ~= nil then highlight.Enabled else nil,
		topModal = ScreenManager.topModalName(),
	}
end

local function window(): { [string]: any }
	local gui = ScreenManager.getGui("RenameStand")
	local root = if gui ~= nil then gui:FindFirstChild("RenameStandWindow", true) else nil
	local reset = if gui ~= nil then gui:FindFirstChild("Button_RESET", true) else nil
	local texts = {}
	if root ~= nil then
		for _, item in root:GetDescendants() do
			if (item:IsA("TextLabel") or item:IsA("TextBox")) and item.Visible and item.Text ~= "" then
				table.insert(texts, item.Text)
			end
		end
	end
	local selected = game:GetService("GuiService").SelectedObject
	return {
		open = ScreenManager.isOpen("RenameStand"),
		resetVisible = reset ~= nil and reset.Visible,
		texts = texts,
		selected = if selected ~= nil then selected.ClassName .. ":" .. selected.Name else nil,
	}
end

local result: any
if COMMAND == "diag" then
	result = {
		profile = ClientState.profile ~= nil,
		revealed = LOCAL:GetAttribute("PlotRevealed") == true,
		hud = playerGui:FindFirstChild("Hud") ~= nil or #playerGui:GetChildren() > 3,
		probe = probe(),
	}
elseif COMMAND == "calm" then
	ScreenManager.closeAllModals()
	task.wait(0.3)
	result = { topModal = ScreenManager.topModalName(), revealed = LOCAL:GetAttribute("PlotRevealed") == true }
elseif COMMAND == "walk" then
	local sign = mySign()
	local index = LOCAL:GetAttribute("PlotIndex")
	if sign == nil or type(index) ~= "number" or index < 1 then
		result = { error = "no sign / plot", probe = probe() }
	else
		local origin = WorldLayout.plotOrigin(index)
		local toHub = origin.LookVector -- plot-local -Z: from the plot towards the hub
		local under = Vector3.new(sign.Position.X, origin.Position.Y, sign.Position.Z)
		local stand = under + toHub * 7
		local character = LOCAL.Character
		-- Out of range first, then into range: PromptShown is the engine's own "the prompt UI is on
		-- screen" signal (the default prompt UI lives in CoreGui, which Studio captures leave out).
		local _, prompt = rigOf(sign)
		local shown = false
		local connection = if prompt ~= nil
			then prompt.PromptShown:Connect(function()
				shown = true
			end)
			else nil
		if character ~= nil then
			character:PivotTo(CFrame.new(stand + toHub * 40 + Vector3.new(0, 3, 0)))
			task.wait(0.6)
			shown = false
			character:PivotTo(CFrame.lookAt(stand + Vector3.new(0, 3, 0), stand + Vector3.new(0, 3, 0) - toHub))
		end
		setCharacterHidden(false)
		camera.CameraType = Enum.CameraType.Scriptable
		camera.FieldOfView = 70
		camera.CFrame = CFrame.lookAt(stand + toHub * 11 + Vector3.new(0, 7, 0), under + Vector3.new(0, 5, 0))
		task.wait(1.0)
		if connection ~= nil then
			connection:Disconnect()
		end
		result = { stand = { stand.X, stand.Y, stand.Z }, promptShown = shown, probe = probe() }
	end
elseif COMMAND == "clickcam" then
	local sign = mySign()
	local index = LOCAL:GetAttribute("PlotIndex")
	if sign == nil or type(index) ~= "number" or index < 1 then
		result = { error = "no sign / plot" }
	else
		setHud(true)
		local origin = WorldLayout.plotOrigin(index)
		local toHub = origin.LookVector
		camera.CameraType = Enum.CameraType.Scriptable
		camera.FieldOfView = 60
		camera.CFrame = CFrame.lookAt(sign.Position + toHub * 30 + Vector3.new(0, -9, 0), sign.Position)
		task.wait(0.1)
		-- Viewport points count from the very top of the viewport (what simulate_mouse_input takes).
		local point, onScreen = camera:WorldToViewportPoint(sign.Position)
		result = {
			x = math.floor(point.X),
			y = math.floor(point.Y),
			onScreen = onScreen,
			viewportX = math.floor(camera.ViewportSize.X),
		}
	end
elseif COMMAND == "ray" then
	local sign = mySign()
	local box = if sign ~= nil then sign:FindFirstChild(PlotSign.ClickBoxName) else nil
	if sign == nil or box == nil then
		result = { error = "no sign / rig" }
	else
		local point = camera:WorldToViewportPoint(sign.Position)
		local ray = camera:ViewportPointToRay(point.X, point.Y)
		local hit = workspace:Raycast(ray.Origin, ray.Direction * 500)
		local detector = box:FindFirstChildWhichIsA("ClickDetector")
		local root = LOCAL.Character and LOCAL.Character:FindFirstChild("HumanoidRootPart")
		result = {
			hit = if hit ~= nil then hit.Instance:GetFullName() else nil,
			hitsClickBox = hit ~= nil and hit.Instance == box,
			reach = if detector ~= nil then detector.MaxActivationDistance else nil,
			characterDistance = if root ~= nil then math.floor((root.Position - sign.Position).Magnitude) else nil,
		}
	end
elseif COMMAND == "hover" or COMMAND == "unhover" then
	local _, _, highlight = rigOf(mySign())
	if highlight ~= nil then
		highlight.Enabled = COMMAND == "hover"
	end
	result = probe()
elseif COMMAND == "open" then
	ScreenManager.open("RenameStand", { mode = "plot" })
	task.wait(0.4)
	result = window()
elseif COMMAND == "close" then
	ScreenManager.close("RenameStand")
	result = window()
elseif COMMAND == "rename" then
	Remotes.event("RenamePlot"):FireServer(QA_NAME)
	result = "sent"
elseif COMMAND == "reset" then
	Remotes.event("RenamePlot"):FireServer("")
	result = "sent"
elseif COMMAND == "signcam" then
	local sign = mySign()
	local index = LOCAL:GetAttribute("PlotIndex")
	if sign == nil or type(index) ~= "number" or index < 1 then
		result = { error = "no sign / plot" }
	else
		setHud(false)
		local origin = WorldLayout.plotOrigin(index)
		local toHub = origin.LookVector
		camera.CameraType = Enum.CameraType.Scriptable
		camera.FieldOfView = 60
		camera.CFrame = CFrame.lookAt(sign.Position + toHub * 30 + Vector3.new(0, -9, 0), sign.Position)
		setCharacterHidden(true)
		result = probe()
	end
elseif COMMAND == "camoff" then
	setHud(true)
	camera.CameraType = Enum.CameraType.Custom
	camera.FieldOfView = 70
	setCharacterHidden(false)
	result = "camera restored"
elseif COMMAND == "probe" then
	result = probe()
else
	result = { error = "unknown command" }
end

return if type(result) == "string" then result else HttpService:JSONEncode(result)
