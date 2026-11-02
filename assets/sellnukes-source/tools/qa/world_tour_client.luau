--!strict
--[[
	world_tour_client.luau — CLIENT half of the World-QA camera tour (eval_client_runtime).

	Placeholders filled by tools/qa/world_tour.py with whitelisted values only:
		COMMAND  "hud_off" | "camera" | "hud_on"
		ARGS     numbers: camera = { eyeX, eyeY, eyeZ, targetX, targetY, targetZ, fov }

	hud_off  hides every PlayerGui ScreenGui (remembering which were on) and the core GUI, so the
	         shots show only the world (billboards in the world stay — they are part of the look)
	camera   hides the HUD again (late-mounted guis), Scriptable camera at eye -> target, hides the
	         local character (LocalTransparency)
	hud_on   restores the GUIs and the default camera
]]

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")

local COMMAND = "__COMMAND__"
local ARGS: { number } = { --[[ARGS]]
}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = workspace.CurrentCamera

local function setCharacterHidden(hidden: boolean)
	local character = player.Character
	if character == nil then
		return
	end
	for _, item in character:GetDescendants() do
		if item:IsA("BasePart") or item:IsA("Decal") then
			item.LocalTransparencyModifier = if hidden then 1 else 0
		end
	end
end

-- Hides every enabled PlayerGui ScreenGui (marked QaWasEnabled for hud_on) + the core GUI.
-- Runs before EVERY shot: the react HUD mounts / re-enables its ScreenGuis after the first
-- hud_off (2026-10-30 tour: every shot still showed the HUD), so one hide at start is not enough.
local function hideHud(): number
	local hidden = 0
	for _, gui in playerGui:GetChildren() do
		if gui:IsA("ScreenGui") and gui.Enabled then
			gui:SetAttribute("QaWasEnabled", true)
			gui.Enabled = false
			hidden += 1
		end
	end
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, false)
	end)
	return hidden
end

if COMMAND == "hud_off" then
	return `hud off ({hideHud()} guis)`
elseif COMMAND == "camera" then
	hideHud()
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = ARGS[7] or 70
	local eye = Vector3.new(ARGS[1], ARGS[2], ARGS[3])
	local target = Vector3.new(ARGS[4], ARGS[5], ARGS[6])
	camera.CFrame = CFrame.lookAt(eye, target)
	setCharacterHidden(true)
	return "camera set"
elseif COMMAND == "hud_on" then
	for _, gui in playerGui:GetChildren() do
		if gui:IsA("ScreenGui") and gui:GetAttribute("QaWasEnabled") then
			gui:SetAttribute("QaWasEnabled", nil)
			gui.Enabled = true
		end
	end
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, true)
	end)
	camera.CameraType = Enum.CameraType.Custom
	camera.FieldOfView = 70
	setCharacterHidden(false)
	return "hud on"
end
return `ERROR unknown command {COMMAND}`
