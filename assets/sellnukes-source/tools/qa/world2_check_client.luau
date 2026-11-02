--!strict
--[[
	world2_check_client.luau — CLIENT half of the World 2 QA tour (owner R57, W12;
	tools/qa/world2_check.py, eval_client_runtime). Placeholders filled with whitelisted values only:
		COMMAND  one of the commands below
		WORLD    a world id matching ^[a-z][a-z0-9]{0,15}$
		ARGS     numbers (see each command)

	state         JSON: PlotIndex, LoadingDone, CurrentWorld, top modal, open World 2 screens,
	              the world the character stands in, Lighting preset hints
	modal_close   closes every open modal window (Welcome Back etc.), up to 6
	travel        fires the REAL TravelWorld intent: ARGS[1] 1 = WORLD spawn, 2 = WORLD area
	              ARGS[2], 3 = WORLD plot ARGS[2], 4 = Nuke Town spawn (server validates everything)
	rebirth       fires the REAL Rebirth intent for WORLD (refused unless the finale is owned)
	open          opens a screen by code ARGS[1] (1 Teleport, 2 Rebirth, 3 Pets, 4 RewardsHub) through ScreenManager
	upgrade       fires the REAL ProducerUpgrade intent ("1" level) for WORLD's first producer
	              (ARGS[1] = 1) or Nuke Town's (2) — the R61 billboard-on-screen upgrade shot
	camera        Scriptable camera: ARGS = eye x, y, z, target x, y, z, fov
	camera_plot   Scriptable camera over our own WORLD plot: ARGS[1] = area (0 = plot aerial,
	              99 = the world's finale area)
	camera_reset  back to the default follow camera
	frame_ms      samples RenderStepped for ARGS[1] seconds (default 5): JSON avg / p95 ms, the
	              FX tier (FxQuality) and the client memory (Stats) — the Low-tier Valley figure
	              is taken with the phone device preset active
	swirl         the Time Machine swirls this client sees ("Swirl" parts / mesh pieces within
	              ARGS[4] studs of ARGS[1..3]): their rotation over 1 s (degrees) — spinning > 0
	gui_point     JSON viewport pixel centre (for simulate_mouse_input) of a visible GUI control by
	              code ARGS[1]: 1 the admin panel header "NewPlayerQuick", 2 the panel confirm
	              "Confirm", 3 the overlay chip's "Exit" (under NewPlayerChip); { found = false } else
	open_panel    opens the admin panel (ScreenManager) on the Players tab
	popup_state   JSON: WORLD UNLOCKED open? + WorldClient.popupState() (owed / shown / impolite)
	admin_send    AdminClient.send of NewPlayerMode (ARGS[1] = 1) / ExitNewPlayerMode (2): the send
	              the panel's buttons make after their confirm (fallback when synthetic clicks
	              do not reach Roblox GUI buttons)
	attack_ui     attack-mode surfaces this client shows right now: visible HUD buttons / hints
	              named "Attack*" / "Launch*" / "Defense*" and enabled ProximityPrompts whose text
	              mentions attack / launch (owner: none in Dino Valley)
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")

local COMMAND = "__COMMAND__"
local WORLD = "__WORLD__"
local ARGS: { number } = { --[[ARGS]]
}

local player = Players.LocalPlayer
local client = player:WaitForChild("PlayerScripts"):WaitForChild("Client")
local Remotes = (require :: any)(ReplicatedStorage.Shared.Net.Remotes)
local WorldLayout = (require :: any)(ReplicatedStorage.Shared.Config.WorldLayout)
local ScreenManager = (require :: any)(client.UI.ScreenManager)
local camera = workspace.CurrentCamera

-- World 2 screens the tour checks (W5 names; missing screens simply report false).
local SCREENS = { "WorldUnlocked", "WorldTravel", "Teleport", "WelcomeBack", "Rebirth" }
local OPEN_CODES = { "Teleport", "Rebirth", "Pets", "RewardsHub" }

local function rootPosition(): Vector3?
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	return if root ~= nil then (root :: BasePart).Position else nil
end

if COMMAND == "state" then
	local open: { [string]: boolean } = {}
	for _, name in SCREENS do
		local ok, isOpen = pcall(ScreenManager.isOpen, name)
		open[name] = ok and isOpen == true
	end
	local position = rootPosition()
	return HttpService:JSONEncode({
		plotIndex = player:GetAttribute("PlotIndex") or 0,
		loadingDone = player:GetAttribute("LoadingDone") == true,
		currentWorld = player:GetAttribute("CurrentWorld") or "main",
		modal = ScreenManager.topModalName() or "",
		open = open,
		standingIn = if position ~= nil then (WorldLayout.worldAt(position) or "none") else "no character",
	})
elseif COMMAND == "modal_close" then
	local closed = 0
	while ScreenManager.anyModalOpen() and closed < 6 do
		ScreenManager.closeTopModal()
		closed += 1
		task.wait(0.3)
	end
	return `closed {closed}`
elseif COMMAND == "travel" then
	local code = math.floor(ARGS[1] or 1)
	local index = math.floor(ARGS[2] or 1)
	local remote = Remotes.event("TravelWorld")
	if code == 1 then
		remote:FireServer(WORLD, "spawn")
	elseif code == 2 then
		remote:FireServer(WORLD, "area", index)
	elseif code == 3 then
		remote:FireServer(WORLD, "plot", index)
	else
		remote:FireServer("main", "spawn")
	end
	return `travel intent {code}`
elseif COMMAND == "upgrade" then
	local WorldsConfig = (require :: any)(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)
	local def = WorldsConfig.get(if (ARGS[1] or 1) == 2 then "main" else WORLD)
	local producer = def.economy.Producers[1].id
	Remotes.event("ProducerUpgrade"):FireServer(producer, "1")
	return `upgrade intent {producer}`
elseif COMMAND == "rebirth" then
	Remotes.event("Rebirth"):FireServer(WORLD)
	return "rebirth intent"
elseif COMMAND == "open" then
	local name = OPEN_CODES[math.clamp(math.floor(ARGS[1] or 1), 1, #OPEN_CODES)]
	local ok, err = pcall(ScreenManager.open, name, { source = "other" })
	return if ok then `opened {name}` else `ERROR {err}`
elseif COMMAND == "camera" then
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = ARGS[7] or 70
	camera.CFrame = CFrame.lookAt(Vector3.new(ARGS[1], ARGS[2], ARGS[3]), Vector3.new(ARGS[4], ARGS[5], ARGS[6]))
	return "camera set"
elseif COMMAND == "camera_plot" then
	local plotIndex = player:GetAttribute("PlotIndex")
	if type(plotIndex) ~= "number" then
		return "ERROR no plot"
	end
	local area = math.floor(ARGS[1] or 0)
	-- 99 (or anything past the end) = the world's finale area (Dino 6, Moon 6, ... any count).
	area = math.min(area, WorldLayout.areaCount(WORLD))
	local origin: CFrame = WorldLayout.plotOrigin(plotIndex, WORLD)
	local target: Vector3
	local eye: Vector3
	if area <= 0 then
		local length = WorldLayout.plotLength(WORLD)
		target = (origin * CFrame.new(0, 0, length / 2)).Position
		eye = (origin * CFrame.new(-length * 0.55, length * 0.6, length * 0.15)).Position
	else
		local slot: CFrame = WorldLayout.slotOrigin(plotIndex, area, WORLD)
		target = slot.Position + Vector3.new(0, 6, 0)
		eye = (slot * CFrame.new(-34, 26, -10)).Position
	end
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = 62
	camera.CFrame = CFrame.lookAt(eye, target)
	return HttpService:JSONEncode({ eye = { eye.X, eye.Y, eye.Z }, target = { target.X, target.Y, target.Z } })
elseif COMMAND == "camera_reset" then
	camera.CameraType = Enum.CameraType.Custom
	camera.FieldOfView = 70
	return "reset"
elseif COMMAND == "gui_point" then
	local GuiService = game:GetService("GuiService")
	local code = math.floor(ARGS[1] or 1)
	local playerGui = player:WaitForChild("PlayerGui")
	local target: GuiObject? = nil
	-- Visible on screen: the control and every ancestor up to its ScreenGui.
	local function onScreen(item: GuiObject): boolean
		local node: Instance? = item
		while node ~= nil and node ~= playerGui do
			if node:IsA("GuiObject") and not node.Visible then
				return false
			end
			if node:IsA("ScreenGui") and not node.Enabled then
				return false
			end
			node = node.Parent
		end
		return true
	end
	for _, item in playerGui:GetDescendants() do
		if item:IsA("GuiObject") and item.AbsoluteSize.X > 0 and onScreen(item) then
			local hit = (code == 4 and item.Name == "Tab_Economy")
				or (code == 1 and item.Name == "NewPlayerQuick")
				or (code == 2 and item.Name == "Confirm" and item:FindFirstAncestor("ConfirmLayer") ~= nil)
				or (code == 3 and item.Name == "Exit" and item:FindFirstAncestor("NewPlayerChip") ~= nil)
			if hit and item:IsA("GuiButton") then
				target = item
				break
			end
		end
	end
	if target == nil then
		return HttpService:JSONEncode({ found = false })
	end
	-- Logical screen point = the control's centre + the Roblox top-bar inset (measured in Studio
	-- 2026-10-31: AbsolutePosition starts under the top bar even for full-screen guis, and the
	-- capture includes the bar). The driver scales it to screenshot pixels.
	local viewport = camera.ViewportSize
	local offsetY = GuiService:GetGuiInset().Y
	local centre = target.AbsolutePosition + target.AbsoluteSize / 2
	return HttpService:JSONEncode({
		found = true,
		x = math.floor(centre.X),
		y = math.floor(centre.Y + offsetY),
		viewportX = viewport.X,
		viewportY = viewport.Y,
		-- Stud buttons draw their caption in a child label.
		text = (function(): string
			local label = target:FindFirstChildWhichIsA("TextLabel", true)
			return if label ~= nil then label.Text else ""
		end)(),
	})
elseif COMMAND == "popup_state" then
	-- W5b's read-only probe of the WORLD UNLOCKED gate + whether the screen is open right now.
	local WorldClient = (require :: any)(client.Worlds.WorldClient)
	local ok, state = pcall(WorldClient.popupState)
	local open = false
	pcall(function()
		open = ScreenManager.isOpen("WorldUnlocked")
	end)
	return HttpService:JSONEncode({ open = open, gate = if ok then state else tostring(state) })
elseif COMMAND == "admin_send" then
	-- The same send the panel buttons do after their confirm (AdminCommand → the server pipeline).
	local AdminClient = (require :: any)(client.UI.Screens.Admin.AdminClient)
	local name = if (ARGS[1] or 1) == 2 then "ExitNewPlayerMode" else "NewPlayerMode"
	AdminClient.start()
	return if AdminClient.send(name) then `sent {name}` else `throttled {name}`
elseif COMMAND == "open_panel" then
	ScreenManager.open("AdminPanel", { tab = "Players" })
	return "opened"
elseif COMMAND == "swirl" then
	local centre = Vector3.new(ARGS[1] or 0, ARGS[2] or 0, ARGS[3] or 0)
	local radius = ARGS[4] or 60
	local parts: { BasePart } = {}
	for _, item in workspace:GetDescendants() do
		if item:IsA("BasePart") and string.find(item.Name, "Swirl", 1, true) ~= nil then
			if (item.Position - centre).Magnitude <= radius then
				table.insert(parts, item)
			end
		end
	end
	local before: { CFrame } = {}
	for index, part in parts do
		before[index] = part.CFrame
	end
	task.wait(1)
	local degrees: { number } = {}
	for index, part in parts do
		local relative = before[index]:ToObjectSpace(part.CFrame)
		local _, angle = relative:ToAxisAngle()
		table.insert(degrees, math.round(math.deg(angle) * 10) / 10)
	end
	return HttpService:JSONEncode({ swirls = #parts, degreesPerSecond = degrees })
elseif COMMAND == "attack_ui" then
	local found: { string } = {}
	local playerGui = player:WaitForChild("PlayerGui")
	local function shown(gui: GuiObject): boolean
		local node: Instance? = gui
		while node ~= nil and node ~= playerGui do
			if node:IsA("GuiObject") and not node.Visible then
				return false
			end
			if node:IsA("ScreenGui") and not node.Enabled then
				return false
			end
			node = node.Parent
		end
		return true
	end
	for _, item in playerGui:GetDescendants() do
		if item:IsA("GuiObject") then
			local name = item.Name
			if
				(string.find(name, "Attack", 1, true) or string.find(name, "Launch", 1, true) or string.find(name, "Defense", 1, true))
				and shown(item)
			then
				table.insert(found, `gui:{item:GetFullName()}`)
			end
		end
	end
	local position = rootPosition()
	for _, item in workspace:GetDescendants() do
		if item:IsA("ProximityPrompt") and item.Enabled then
			local text = string.lower(item.ActionText .. " " .. item.ObjectText)
			local holder = item.Parent
			local near = position ~= nil and holder ~= nil and holder:IsA("BasePart") and (holder.Position - position).Magnitude < 400
			if near and (string.find(text, "attack", 1, true) or string.find(text, "launch", 1, true)) then
				table.insert(found, `prompt:{item:GetFullName()}`)
			end
		end
	end
	return HttpService:JSONEncode({ currentWorld = player:GetAttribute("CurrentWorld") or "main", found = found })
elseif COMMAND == "frame_ms" then
	local seconds = math.clamp(ARGS[1] or 5, 1, 30)
	local samples: { number } = {}
	local connection = RunService.RenderStepped:Connect(function(dt: number)
		table.insert(samples, dt * 1000)
	end)
	task.wait(seconds)
	connection:Disconnect()
	table.sort(samples)
	local total = 0
	for _, ms in samples do
		total += ms
	end
	local tier = "unknown"
	pcall(function()
		local FxQuality = (require :: any)(client.Tycoon.Fx.FxQuality)
		tier = FxQuality.tier()
	end)
	return HttpService:JSONEncode({
		frames = #samples,
		avgMs = if #samples > 0 then math.round(total / #samples * 100) / 100 else -1,
		p95Ms = if #samples > 0 then math.round(samples[math.max(1, math.ceil(#samples * 0.95))] * 100) / 100 else -1,
		fxTier = tier,
		memoryMb = math.floor(Stats:GetTotalMemoryUsageMb()),
		instances = Stats.InstanceCount,
		currentWorld = player:GetAttribute("CurrentWorld") or "main",
	})
end
return `ERROR unknown command {COMMAND}`
