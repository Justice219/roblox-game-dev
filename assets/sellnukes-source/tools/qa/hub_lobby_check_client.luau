--!strict
--[[
	hub_lobby_check_client.luau — CLIENT half of the lobby-centre Studio QA (owner R55,
	tools/qa/hub_lobby_check.py, eval_client_runtime). Placeholders filled with whitelisted values only:
		COMMAND  "state" | "go_spawn" | "view" | "camera_reset" | "modal_close" | "fx"
		ARGS     numbers: view = { index } (1 spawn, 2 statue, 3 aerial, 4 path, 5 garden)

	state         JSON: PlotIndex, LoadingDone, open modal, distance from the hub spawn
	go_spawn      puts our own character on the hub spawn pad, facing the spawn direction (the
	              client owns its character, like the HUD's Teleport → Hub button does server-side)
	view          Scriptable camera on one of the review framings below (all from HubLayout)
	camera_reset  back to the default follow camera (behind the character = the real spawn view)
	modal_close   closes every open modal window (WelcomeBack etc. cover the world)
	fx            JSON: hub ambient emitters / WorldFx-tagged hub pieces present on this client
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")

local COMMAND = "__COMMAND__"
local ARGS: { number } = { --[[ARGS]]
}

local player = Players.LocalPlayer
local client = player:WaitForChild("PlayerScripts"):WaitForChild("Client")
local HubLayout = (require :: any)(ReplicatedStorage.Shared.Config.HubLayout)
local ScreenManager = (require :: any)(client.UI.ScreenManager)
local camera = workspace.CurrentCamera

local spawnCf: CFrame = HubLayout.spawn
-- Review framings (world space; the hub centre is the origin).
local function viewFor(index: number): (CFrame, number)
	local outward = spawnCf.LookVector
	if index == 1 then
		-- Spawn: just behind / above the character, looking the way the spawn faces (default camera).
		local eye = spawnCf.Position - outward * 16 + Vector3.new(0, 9, 0)
		return CFrame.lookAt(eye, spawnCf.Position + outward * 40 + Vector3.new(0, 6, 0)), 70
	elseif index == 2 then
		-- Turned round on the spawn: the fountain + Nukey statue.
		local eye = spawnCf.Position + outward * 6 + Vector3.new(0, 8, 0)
		return CFrame.lookAt(eye, Vector3.new(0, 22, 0)), 70
	elseif index == 3 then
		-- Aerial three-quarter over the whole lobby centre.
		local eye = Vector3.new(-70, 125, 150)
		return CFrame.lookAt(eye, Vector3.new(0, 0, 6)), 62
	elseif index == 4 then
		-- Down a plot path (plot 3): fountain walk -> pad + sign -> bunting gateway -> avenue -> gate.
		local yaw = CFrame.Angles(0, math.rad(90), 0)
		local eye = (yaw * CFrame.new(-6, 9, 30)).Position
		return CFrame.lookAt(eye, (yaw * CFrame.new(0, 5, 110)).Position), 70
	end
	-- Garden close-up (wedge 2 between plots 3 and 4).
	local yaw = CFrame.Angles(0, math.rad(112.5), 0)
	local eye = (yaw * CFrame.new(10, 10, 32)).Position
	return CFrame.lookAt(eye, (yaw * CFrame.new(0, 4, 62)).Position), 70
end

if COMMAND == "state" then
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return HttpService:JSONEncode({
		plotIndex = player:GetAttribute("PlotIndex") or 0,
		loadingDone = player:GetAttribute("LoadingDone") == true,
		modal = ScreenManager.topModalName() or "",
		fromSpawn = if root ~= nil then math.floor(((root :: BasePart).Position - spawnCf.Position).Magnitude) else -1,
	})
elseif COMMAND == "go_spawn" then
	local character = player.Character
	if character == nil then
		return "no character"
	end
	character:PivotTo(spawnCf * CFrame.new(0, 4, 0))
	return "spawned"
elseif COMMAND == "view" then
	local cf, fov = viewFor(math.clamp(math.floor(ARGS[1] or 1), 1, 5))
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = fov
	camera.CFrame = cf
	return "view"
elseif COMMAND == "camera_reset" then
	camera.CameraType = Enum.CameraType.Custom
	camera.FieldOfView = 70
	return "reset"
elseif COMMAND == "modal_close" then
	local closed = 0
	while ScreenManager.anyModalOpen() and closed < 6 do
		ScreenManager.closeTopModal()
		closed += 1
		task.wait(0.3)
	end
	return `closed {closed}`
elseif COMMAND == "fx" then
	local hub = workspace:FindFirstChild("Hub")
	local emitters, tagged, parts = 0, 0, 0
	if hub ~= nil then
		for _, item in hub:GetDescendants() do
			if item:IsA("ParticleEmitter") then
				emitters += 1
			elseif item:IsA("BasePart") then
				parts += 1
				if CollectionService:HasTag(item, "WorldFx") then
					tagged += 1
				end
			end
		end
	end
	return HttpService:JSONEncode({ emitters = emitters, worldFxPieces = tagged, hubParts = parts })
end
return "unknown"
