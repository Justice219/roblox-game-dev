--!nocheck
--[[
	kinetic_client.luau — CLIENT half of the Mega Lever + Tip Jar Studio QA (owner R90, K-kinetic),
	run by tools/qa/kinetic.py through eval_client_runtime in ONE solo playtest.

		COMMAND  "diag"        HUD shown, KineticClient.stats(), the own lever / jar prompts (exist,
		                       enabled, glyph keys, hold), board texts, coin pile size, arm offset
		         "look_lever"  scriptable camera on the own lever from ARGS[1] studs (front-left)
		         "look_jar"    scriptable camera on the own jar from ARGS[1] studs
		         "hold_lever"  the REAL prompt path: InputHoldBegin on the own lever prompt, waits its
		                       HoldDuration, InputHoldEnd → Triggered → KineticAction "pull"
		         "hold_jar"    the same on the jar prompt ("collect")
		         "camera_reset" camera back to Custom
		         "close_all"   closes every modal (boot windows)
	Presentation + the prompt path only; every amount / rule is the server's.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }

local client = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local KineticClient = require(client.Kinetic.KineticClient)
local ScreenManager = require(client.UI.ScreenManager)
local KineticConfig = require(ReplicatedStorage.Shared.Config.KineticConfig)
local MeshAssets = require(ReplicatedStorage.Shared.Config.MeshAssets)

local function mine(tag: string): Model?
	for _, instance in CollectionService:GetTagged(tag) do
		if instance:IsA("Model") and instance:GetAttribute("OwnerUserId") == Players.LocalPlayer.UserId then
			return instance
		end
	end
	return nil
end

local function promptOf(model: Model?, name: string): ProximityPrompt?
	local found = model and model:FindFirstChild(name, true)
	return if found ~= nil and found:IsA("ProximityPrompt") then found else nil
end

local function promptInfo(prompt: ProximityPrompt?)
	if prompt == nil then
		return { exists = false }
	end
	return {
		exists = true,
		enabled = prompt.Enabled,
		hold = prompt.HoldDuration,
		key = prompt.KeyboardKeyCode.Name,
		pad = prompt.GamepadKeyCode.Name,
		action = prompt.ActionText,
		distance = prompt.MaxActivationDistance,
	}
end

local function boardText(model: Model?): string
	local board = model and model:FindFirstChild(KineticClient.BoardName, true)
	local status = board and board:FindFirstChild("Status", true)
	return status and status.Text or ""
end

local function look(model: Model?, distance: number, height: number)
	local camera = Workspace.CurrentCamera
	if model == nil or camera == nil then
		return "none"
	end
	local pivot = model:GetPivot()
	local target = pivot.Position + Vector3.new(0, height, 0)
	local eye = (pivot * CFrame.new(distance * 0.45, 0, -distance)).Position + Vector3.new(0, distance * 0.45, 0)
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.lookAt(eye, target)
	return "ok"
end

local function hold(prompt: ProximityPrompt?): string
	if prompt == nil then
		return "no prompt"
	end
	if not prompt.Enabled then
		return "disabled"
	end
	local ok, err = pcall(function()
		prompt:InputHoldBegin()
		task.wait(prompt.HoldDuration + 0.15)
		prompt:InputHoldEnd()
	end)
	return if ok then "held" else "error: " .. tostring(err)
end

local lever = mine(KineticConfig.Tags.Lever)
local jar = mine(KineticConfig.Tags.Jar)

if COMMAND == "diag" then
	local hud = ScreenManager.getGui("Hud")
	local coins = jar and jar:FindFirstChild(KineticConfig.TipJar.CoinPiece)
	local arm = lever and lever:FindFirstChild(KineticConfig.Lever.ArmPieces[1])
	local restOffset = MeshAssets[KineticConfig.Models.Lever].pieces[KineticConfig.Lever.ArmPieces[1]].offset
	local armOffset = if arm ~= nil then lever:GetPivot():PointToObjectSpace(arm.Position) else nil
	return HttpService:JSONEncode({
		hud = hud ~= nil and hud.Enabled,
		stats = KineticClient.stats(),
		leverPrompt = promptInfo(promptOf(lever, KineticClient.LeverPromptName)),
		jarPrompt = promptInfo(promptOf(jar, KineticClient.JarPromptName)),
		leverBoard = boardText(lever),
		jarBoard = boardText(jar),
		coinHeight = coins and coins.Size.Y or -1,
		coinVisible = coins ~= nil and coins.Transparency < 1,
		armMoved = armOffset ~= nil and (armOffset - restOffset).Magnitude > 0.3,
		top = ScreenManager.topModalName() or "",
	})
elseif COMMAND == "look_lever" then
	return look(lever, ARGS[1] or 20, 4)
elseif COMMAND == "look_jar" then
	return look(jar, ARGS[1] or 12, 3)
elseif COMMAND == "hold_lever" then
	return hold(promptOf(lever, KineticClient.LeverPromptName))
elseif COMMAND == "hold_jar" then
	return hold(promptOf(jar, KineticClient.JarPromptName))
elseif COMMAND == "camera_reset" then
	Workspace.CurrentCamera.CameraType = Enum.CameraType.Custom
	return "ok"
elseif COMMAND == "close_all" then
	ScreenManager.closeAllModals()
	return "closed"
end
return "unknown"
