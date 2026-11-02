--!nocheck
--[[
	defense_towers_client.luau — CLIENT half of the owner R80 defence tower Studio QA
	(tools/qa/defense_towers.py, eval_client_runtime, ONE solo playtest).

		COMMAND  "diag"        HUD shown, profile loaded, HUD Attack button visible + badge,
		                       DefenseWorld billboards, AttackClient.defenceAlert()
		         "close_all"   closes every modal
		         "open"        ARGS[1] = 1 Defense window / 2 Attack picker; returns state()
		         "state"       Defense summary + every card's title / button text, picker DEFEND text
		         "camera"      ARGS = { slot (0 = whole plot), height, back }: Scriptable camera on the
		                       slot's tower spot (three-quarter view from the road side)
		         "camera_reset" Custom camera again
		         "act"         DefenseWorld.nearest(root).act() — the REAL Interact path (E / X / touch)
		         "double"      ARGS = { slot, toLevel }: two DefenseTower intents back to back
		         "hostile"     junk DefenseTower / DefenseUpgrade arguments
		         "board"       ARGS[1] = tower slot: its billboard texts + the tap target's pixel size
		         "pad_on" / "pad_off" / "reopen"   forced Gamepad mode; reopen Defense → SelectedObject
	Presentation / intents only: every purchase is decided by the server.
]]

local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]]
}

local LOCAL = Players.LocalPlayer
local client = LOCAL:WaitForChild("PlayerScripts"):WaitForChild("Client")
local ClientState = require(client.ClientState)
local InputController = require(client.Controllers.InputController)
local ScreenManager = require(client.UI.ScreenManager)
local AttackClient = require(client.Attack.AttackClient)
local DefenseWorld = require(client.Attack.DefenseWorld)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local AttackConfig = require(ReplicatedStorage.Shared.Config.AttackConfig)
local AttackGeometry = require(ReplicatedStorage.Shared.Attack.AttackGeometry)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)

local function textOf(parent: Instance?, name: string): string
	local node = if parent ~= nil then parent:FindFirstChild(name, true) else nil
	return if node ~= nil and (node:IsA("TextLabel") or node:IsA("TextButton")) then node.Text else ""
end

local function hudButton(): (boolean, string)
	local hud = ScreenManager.getGui("Hud")
	if hud == nil then
		return false, "?"
	end
	for _, node in hud:GetDescendants() do
		if node:IsA("GuiButton") and string.find(node.Name, "Attack", 1, true) ~= nil then
			local badge = node:FindFirstChild("Badge", true)
			return node.Visible, if badge ~= nil and badge.Visible then textOf(badge, "BadgeText") else ""
		end
	end
	return false, "none"
end

local function state()
	local result = { cards = {} }
	local gui = ScreenManager.getGui("Defense")
	if gui ~= nil then
		for _, node in gui:GetDescendants() do
			if node:IsA("Frame") and node.Name == "StudCard" then
				local button = node:FindFirstChildWhichIsA("TextButton", true)
				table.insert(result.cards, {
					order = node.LayoutOrder,
					title = textOf(node, "Title"),
					button = if button ~= nil then textOf(button, "Label") else "",
				})
			end
		end
		table.sort(result.cards, function(a, b)
			return a.order < b.order
		end)
		for _, node in gui:GetDescendants() do
			if node:IsA("TextLabel") and node.LayoutOrder == 0 and node.Parent ~= nil and node.Parent:IsA("ScrollingFrame") then
				result.summary = node.Text
			end
		end
	end
	local picker = ScreenManager.getGui("Attack")
	if picker ~= nil then
		local defend = picker:FindFirstChild("Button_DEFENSE", true)
		result.defend = if defend ~= nil then textOf(defend, "Label") else ""
	end
	result.top = ScreenManager.topModalName() or ""
	return result
end

local function root(): BasePart?
	local character = LOCAL.Character
	local part = character and character:FindFirstChild("HumanoidRootPart")
	return if part ~= nil and part:IsA("BasePart") then part else nil
end

if COMMAND == "diag" then
	local hud = ScreenManager.getGui("Hud")
	local visible, badge = hudButton()
	return HttpService:JSONEncode({
		hud = hud ~= nil and hud.Enabled,
		profile = type(ClientState.profile) == "table" and type(ClientState.profile.attack) == "table",
		attackButton = visible,
		badge = badge,
		boards = DefenseWorld.count(),
		alert = AttackClient.defenceAlert(),
		me = AttackClient.myState(),
	})
elseif COMMAND == "close_all" then
	ScreenManager.closeAllModals()
	return "closed"
elseif COMMAND == "open" then
	ScreenManager.open(if ARGS[1] == 2 then "Attack" else "Defense", { source = "other" })
	task.wait(1.2)
	return HttpService:JSONEncode(state())
elseif COMMAND == "state" then
	return HttpService:JSONEncode(state())
elseif COMMAND == "camera" then
	local camera = Workspace.CurrentCamera
	local plot = math.floor(LOCAL:GetAttribute(AttackConfig.Attr.Plot) or 0)
	if plot < 1 then
		return "no plot"
	end
	local focus
	if ARGS[1] >= 1 then
		focus = AttackGeometry.towerSlotCFrame(plot, ARGS[1])
	else
		focus = WorldLayout.plotOrigin(plot) * CFrame.new(0, 0, 260)
	end
	camera.CameraType = Enum.CameraType.Scriptable
	local origin = WorldLayout.plotOrigin(plot)
	-- From the hub side of the spot (plot -Z), raised: a three-quarter view.
	local eye = focus.Position - origin.LookVector * -ARGS[3] + Vector3.new(0, ARGS[2], 0)
	camera.CFrame = CFrame.lookAt(eye, focus.Position + Vector3.new(0, 5, 0))
	return "ok"
elseif COMMAND == "camera_reset" then
	Workspace.CurrentCamera.CameraType = Enum.CameraType.Custom
	return "ok"
elseif COMMAND == "act" then
	local part = root()
	if part == nil then
		return HttpService:JSONEncode({ error = "no character" })
	end
	local offer = DefenseWorld.nearest(part.Position)
	if offer == nil then
		return HttpService:JSONEncode({ offer = false })
	end
	offer.act()
	return HttpService:JSONEncode({ offer = true, context = offer.context, hint = offer.hint })
elseif COMMAND == "double" then
	Remotes.event("DefenseTower"):FireServer(ARGS[1], ARGS[2])
	Remotes.event("DefenseTower"):FireServer(ARGS[1], ARGS[2])
	return "sent twice"
elseif COMMAND == "hostile" then
	local event = Remotes.event("DefenseTower")
	local junk = { 0 / 0, math.huge, -math.huge, -1, 0, 1.5, 99, 1e300, "1", true, {} }
	for _, a in junk do
		event:FireServer(a, 1)
		event:FireServer(1, a)
	end
	event:FireServer()
	Remotes.event("DefenseUpgrade"):FireServer("aa", 0 / 0)
	Remotes.event("DefenseUpgrade"):FireServer("aa", 99)
	return "sent junk"
elseif COMMAND == "board" then
	local player = LOCAL:FindFirstChildOfClass("PlayerGui")
	local slot = math.floor(ARGS[1])
	local result = { found = false }
	for _, name in { `DefensePad_{slot}`, `DefenseTower_{slot}` } do
		local gui = player and player:FindFirstChild(name)
		if gui ~= nil then
			local button = gui:FindFirstChildWhichIsA("TextButton")
			result = {
				found = true,
				name = name,
				title = textOf(gui, "Name"),
				cost = textOf(gui, "Cost"),
				upgrade = textOf(gui, "UpgradeText"),
				buttonPx = if button ~= nil then { button.AbsoluteSize.X, button.AbsoluteSize.Y } else {},
				onScreen = gui.Enabled,
			}
		end
	end
	return HttpService:JSONEncode(result)
elseif COMMAND == "padinfo" then
	local playerGui = LOCAL:FindFirstChildOfClass("PlayerGui")
	local gui = playerGui and playerGui:FindFirstChild(`DefensePad_{math.floor(ARGS[1])}`)
	if gui == nil then
		return HttpService:JSONEncode({ found = false })
	end
	local adornee = gui.Adornee
	local camera = Workspace.CurrentCamera
	local screen, visible = Vector3.zero, false
	if adornee ~= nil and adornee:IsA("BasePart") then
		screen, visible = camera:WorldToViewportPoint(adornee.Position + gui.StudsOffsetWorldSpace)
	end
	local texts = {}
	for _, node in gui:GetDescendants() do
		if node:IsA("TextLabel") then
			table.insert(texts, { node.Name, node.Text, node.TextTransparency, node.Visible, node.AbsoluteSize.Y })
		end
	end
	return HttpService:JSONEncode({
		found = true,
		parent = gui.Parent and gui.Parent.Name or "nil",
		adornee = adornee and adornee:GetFullName() or "nil",
		adorneePos = adornee and { adornee.Position.X, adornee.Position.Y, adornee.Position.Z } or {},
		screen = { screen.X, screen.Y, screen.Z },
		inView = visible,
		enabled = gui.Enabled,
		onTop = gui.AlwaysOnTop,
		size = { gui.AbsoluteSize.X, gui.AbsoluteSize.Y },
		maxDistance = gui.MaxDistance,
		texts = texts,
		camera = { camera.CFrame.Position.X, camera.CFrame.Position.Y, camera.CFrame.Position.Z },
	})
elseif COMMAND == "pad_on" then
	InputController.setForcedMode("Gamepad")
	return InputController.mode
elseif COMMAND == "pad_off" then
	InputController.setForcedMode(nil)
	return InputController.mode
elseif COMMAND == "reopen" then
	ScreenManager.close("Defense")
	task.wait(0.3)
	ScreenManager.open("Defense", { source = "other" })
	task.wait(0.9)
	local selected = GuiService.SelectedObject
	return HttpService:JSONEncode({
		selected = if selected ~= nil then selected.Name else "",
		label = if selected ~= nil then textOf(selected, "Label") else "",
	})
end
return "unknown command"
