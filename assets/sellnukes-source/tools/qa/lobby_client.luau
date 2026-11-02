--!nocheck
--[[
	lobby_client.luau — client-VM probe for the R99 / R100 / R101 lobby work (L-lobby), run by
	tools/qa/lobby.py through eval_client_runtime during ONE solo playtest.

		COMMAND  "state"        loading / plot / top modal / world / distance to the wheel stage
		         "modal_close"  closes every open modal (up to 6)
		         "place"        ARGS[1]: 1 = on the bed in front of the wheel stage steps, 2 = hub spawn
		         "walk_on"      Humanoid:MoveTo onto the stage in front of the wheel (REAL walking)
		         "walk_off"     Humanoid:MoveTo back off the stage
		         "wheel"        { open, top } — is the LuckyWheel screen open
		         "close_wheel"  closes the LuckyWheel screen
		         "prompt"       triggers the Lucky Wheel ProximityPrompt (InputHoldBegin / End)
		         "tap"          ActionMap.tap("LobbyUse") (the console / touch action path)
		         "frame"        ARGS[1]: Scriptable camera framing — 1 crate stall, 2 wheel stage,
		                        3 group chest, 4 codes board, 5 lobby aerial, 6 nearest visitor
		         "camera_reset" Custom camera again
		         "fixtures"     LobbyFixtures.stats() + every lobby prompt's texts / enabled
		         "npcs"         LobbyNpcs.stats() + a raycast through the nearest visitor (must miss it)
		         "speak"        LobbyNpcs.speakSoon() (next refresh shows a bubble)
		         "spin"         fires SpinWheel(id) directly (the physical wheel reacts to the result)
	Presentation / probes only; spins are server-rolled (the server grants the QA spins first).
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }

local player = Players.LocalPlayer
local client = player:WaitForChild("PlayerScripts"):WaitForChild("Client")
local HubLayout = require(ReplicatedStorage.Shared.Config.HubLayout)
local ScreenManager = require(client.UI.ScreenManager)
local LobbyFixtures = require(client.Lobby.LobbyFixtures)
local LobbyNpcs = require(client.Lobby.LobbyNpcs)
local camera = workspace.CurrentCamera
local anchors = HubLayout.anchors
local stage: CFrame = anchors.LuckyWheelStage.cf

local function humanoid(): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

local function rootPart(): BasePart?
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

-- Scriptable framing `index` → (eye CFrame, fov).
local function frame(index: number): (CFrame, number)
	if index == 1 then
		local cf = anchors.CrateStall.cf
		return CFrame.lookAt((cf * CFrame.new(0, 8, -22)).Position, (cf * CFrame.new(0, 10, -4.3)).Position), 60
	elseif index == 2 then
		return CFrame.lookAt((stage * CFrame.new(0, 10, -34)).Position, (stage * CFrame.new(0, 12, 0)).Position), 62
	elseif index == 3 then
		local cf = anchors.GroupChest.cf
		return CFrame.lookAt((cf * CFrame.new(0, 7, -18)).Position, (cf * CFrame.new(0, 7, 2)).Position), 60
	elseif index == 4 then
		local cf = anchors.CodesBoard.cf
		return CFrame.lookAt((cf * CFrame.new(0, 8, -20)).Position, (cf * CFrame.new(0, 9.6, 0)).Position), 60
	elseif index == 5 then
		return CFrame.lookAt(Vector3.new(0, 70, -150), Vector3.new(0, 0, -20)), 62
	end
	local root = rootPart()
	local model = LobbyNpcs.nearest(if root ~= nil then root.Position else Vector3.zero)
	if model == nil or model:FindFirstChild("Head") == nil then
		return camera.CFrame, 70
	end
	local head = model.Head.Position
	local look = model.HumanoidRootPart.CFrame.LookVector
	return CFrame.lookAt(head + look * 9 + Vector3.new(0, 1.5, 0), head + Vector3.new(0, 1, 0)), 55
end

if COMMAND == "state" then
	local root = rootPart()
	return HttpService:JSONEncode({
		plotIndex = player:GetAttribute("PlotIndex") or 0,
		loadingDone = player:GetAttribute("LoadingDone") == true,
		modal = ScreenManager.topModalName() or "",
		world = player:GetAttribute("CurrentWorld") or "main",
		fromStage = if root ~= nil then math.floor((root.Position - stage.Position).Magnitude) else -1,
	})
elseif COMMAND == "modal_close" then
	local closed = 0
	while ScreenManager.anyModalOpen() and closed < 6 do
		ScreenManager.closeTopModal()
		closed += 1
		task.wait(0.3)
	end
	return `closed {closed}`
elseif COMMAND == "place" then
	local character = player.Character
	if character == nil then
		return "no character"
	end
	local spot = if ARGS[1] == 2 then HubLayout.spawn * CFrame.new(0, 4, 0) else stage * CFrame.new(0, 3.5, -17)
	character:PivotTo(spot)
	return "placed"
elseif COMMAND == "walk_on" or COMMAND == "walk_off" then
	local h = humanoid()
	if h == nil then
		return "no humanoid"
	end
	local goal = if COMMAND == "walk_on" then stage * CFrame.new(0, 2, -5) else stage * CFrame.new(0, 0.2, -18)
	h:MoveTo(goal.Position)
	return "walking"
elseif COMMAND == "wheel" then
	return HttpService:JSONEncode({ open = ScreenManager.isOpen("LuckyWheel"), top = ScreenManager.topModalName() or "" })
elseif COMMAND == "close_wheel" then
	ScreenManager.close("LuckyWheel")
	return "closed"
elseif COMMAND == "prompt" then
	local folder = workspace:FindFirstChild("LobbyFixturesClient")
	local part = folder and folder:FindFirstChild("Prompt_LuckyWheel")
	local prompt = part and part:FindFirstChildOfClass("ProximityPrompt")
	if prompt == nil then
		return "no prompt"
	end
	prompt:InputHoldBegin()
	task.wait(0.1)
	prompt:InputHoldEnd()
	return "triggered"
elseif COMMAND == "tap" then
	local ActionMap = require(client.Platform.ActionMap)
	return HttpService:JSONEncode({
		active = ActionMap.isActive("LobbyUse"),
		fired = ActionMap.tap("LobbyUse"),
		hint = ActionMap.hintTexts().LobbyUse or "",
	})
elseif COMMAND == "frame" then
	local cf, fov = frame(math.clamp(math.floor(ARGS[1] or 1), 1, 6))
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = fov
	camera.CFrame = cf
	return "framed"
elseif COMMAND == "camera_reset" then
	camera.CameraType = Enum.CameraType.Custom
	camera.FieldOfView = 70
	return "reset"
elseif COMMAND == "fixtures" then
	local stats = LobbyFixtures.stats()
	local prompts = {}
	local folder = workspace:FindFirstChild("LobbyFixturesClient")
	for _, part in (folder and folder:GetChildren() or {}) do
		local prompt = part:FindFirstChildOfClass("ProximityPrompt")
		if prompt ~= nil then
			prompts[part.Name] = `{prompt.ActionText} / {prompt.ObjectText} enabled={prompt.Enabled}`
		end
	end
	stats.promptList = prompts
	-- The crate stall's old floating billboard must be gone (hub mesh stall).
	local stands = workspace:FindFirstChild("PetStands")
	local stall = stands and stands:FindFirstChild("CrateStall")
	stats.crateBillboard = stall ~= nil and stall:FindFirstChild("CrateSign") ~= nil
	return HttpService:JSONEncode(stats)
elseif COMMAND == "npcs" then
	local stats = LobbyNpcs.stats()
	local root = rootPart()
	local model = LobbyNpcs.nearest(if root ~= nil then root.Position else Vector3.zero)
	if model ~= nil and model:FindFirstChild("HumanoidRootPart") then
		local at = model.HumanoidRootPart.Position
		local hit = workspace:Raycast(at + Vector3.new(0, 20, 0), Vector3.new(0, -40, 0))
		stats.raycastHitsVisitor = hit ~= nil and hit.Instance:IsDescendantOf(model)
		stats.nearestDistance = if root ~= nil then math.floor((root.Position - at).Magnitude) else -1
		local collide = false
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") and (part.CanCollide or part.CanQuery or part.CanTouch) then
				collide = true
			end
		end
		stats.anyCollidable = collide
	end
	return HttpService:JSONEncode(stats)
elseif COMMAND == "speak" then
	LobbyNpcs.speakSoon()
	return "speak"
elseif COMMAND == "spin" then
	local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
	Remotes.event("SpinWheel"):FireServer(900000 + math.random(1, 9999))
	return "spin sent"
end
return "unknown"
