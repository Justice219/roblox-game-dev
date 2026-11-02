--!strict
--[[
	worlds_ui_client.luau — CLIENT half of the worlds UI check (owner R57 World 2, W5 worlds-ui;
	tools/qa/worlds_ui.py, eval_client_runtime). Placeholders are filled with whitelisted values
	only (no free-form text reaches Luau):
		COMMAND  one of the commands below
		ARGS     numbers (see each command)

	state         JSON probe of everything W5 owns: current world, open screens, the gamepad
	              selection, the HUD (Bones primary, Cash pill, Attack, Teleport NEW tag, offers,
	              objective text), the lighting preset (Atmosphere density, WorldTint), the music
	              context, whether the ambience bed is playing and the WORLD UNLOCKED gate
	              (WorldClient.popupState: waiting / owed / impolite reason / unlock stamps)
	modal_close   closes every open modal window (up to 8) + the rejoin chip
	open          opens a W5 screen by code ARGS[1] (through the REAL ScreenManager / WorldClient):
	                1 Teleport (current world tab)   2 Teleport { world = "dino" }
	                3 Rebirth (current world tab)    4 Shop (lands on the world's section)
	                5 Welcome Back with two world rows (display only: Nuke Town $1.2T + 4.5M Bones)
	                6 the rejoin chip "Back to Dino Valley?"
	                7 the WORLD UNLOCKED locked preview (WorldClient.previewLocked("dino", "hud"))
	                8 the WORLD UNLOCKED celebration (mode "unlocked", source "auto")
	                9 Rebirth { world = "dino" }
	travel        the REAL travel intent through WorldClient.travel: ARGS[1] 1 = Dino Base Camp,
	              2 = Nuke Town hub (server validates everything)
	upgrade       owner bug R61: presses UPGRADE on the nearest own producer through the REAL
	              path (ProducerBillboards.upgrade: feedback burst + intent) and returns the button's
	              raw AbsolutePosition (where the old burst went) vs its projected ScreenRect
	padbuy        R61: stands on the next buyable pad of the current world and sends the REAL
	              PadBuy intent (a spend: nothing may fly)
	flystate      CurrencyFly.state() (bursts per source) + the current world balances

	Example (python): client("open", [2]) ; json.loads(client("state"))
]]

local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")

local COMMAND = "__COMMAND__"
local ARGS: { number } = { --[[ARGS]]
}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local client = player:WaitForChild("PlayerScripts"):WaitForChild("Client")
local ScreenManager = (require :: any)(client.UI.ScreenManager)
local HudZones = (require :: any)(client.UI.Widgets.HudZones)
local WorldClient = (require :: any)(client.Worlds.WorldClient)

local SCREENS = { "WorldUnlocked", "WorldTravel", "WorldRejoin", "Teleport", "Rebirth", "Shop", "WelcomeBack" }

-- True when `object` and every GuiObject ancestor are Visible (and its ScreenGui is enabled).
local function shown(object: Instance?): boolean
	local node = object
	while node ~= nil and node ~= playerGui do
		if node:IsA("GuiObject") and not node.Visible then
			return false
		end
		if node:IsA("ScreenGui") and not node.Enabled then
			return false
		end
		node = node.Parent
	end
	return object ~= nil
end

-- The first descendant of the HUD gui named `name`.
local function hudFind(name: string): Instance?
	local hud = playerGui:FindFirstChild("Hud")
	return if hud ~= nil then hud:FindFirstChild(name, true) else nil
end

-- First TextLabel text under `object` (a HUD row), or "".
local function textOf(object: Instance?): string
	if object == nil then
		return ""
	end
	if object:IsA("TextLabel") then
		return object.Text
	end
	for _, child in object:GetDescendants() do
		if child:IsA("TextLabel") and child.Text ~= "" and shown(child) then
			return child.Text
		end
	end
	return ""
end

if COMMAND == "state" then
	local open: { [string]: boolean } = {}
	for _, name in SCREENS do
		local ok, isOpen = pcall(ScreenManager.isOpen, name)
		open[name] = ok and isOpen == true
	end
	-- HUD (owner R58: no new left buttons; Teleport wears NEW until the first visit).
	local teleport = hudFind("Hud_Teleport")
	local newTag = if teleport ~= nil then teleport:FindFirstChild("NewTag", true) else nil
	local offers: { string } = {}
	local hud = playerGui:FindFirstChild("Hud")
	if hud ~= nil then
		for _, child in hud:GetDescendants() do
			if string.sub(child.Name, 1, 6) == "Offer_" and shown(child) then
				table.insert(offers, string.sub(child.Name, 7))
			end
		end
	end
	local objective = hudFind("Objective")
	local objectiveText = if objective ~= nil and shown(objective)
		then textOf(objective:FindFirstChild("Text", true))
		else ""
	-- Lighting: every Atmosphere's density + the client-only WorldTint.
	local densities: { number } = {}
	for _, child in Lighting:GetChildren() do
		if child:IsA("Atmosphere") then
			table.insert(densities, math.round(child.Density * 1000) / 1000)
		end
	end
	local tint = Lighting:FindFirstChild("WorldTint")
	local tintColor = if tint ~= nil and tint:IsA("ColorCorrectionEffect") then tint.TintColor else nil
	-- Music + the ambience bed (Audio/Sound's 2D folder).
	local context = "?"
	pcall(function()
		local SoundController = (require :: any)(client.Audio.SoundController)
		context = SoundController.currentContext() or "auto"
	end)
	local bedPlaying = false
	local folder = SoundService:FindFirstChild("SN_Sfx2D")
	if folder ~= nil then
		for _, sound in folder:GetDescendants() do
			if sound:IsA("Sound") and sound.Name == "amb_jungle" and sound.IsPlaying then
				bedPlaying = true
			end
		end
	end
	local selected = GuiService.SelectedObject
	return HttpService:JSONEncode({
		plotIndex = player:GetAttribute("PlotIndex") or 0,
		loadingDone = player:GetAttribute("LoadingDone") == true,
		revealed = player:GetAttribute("PlotRevealed") == true,
		currentWorld = WorldClient.current(),
		unlocked = WorldClient.isUnlocked("dino"),
		modal = ScreenManager.topModalName() or "",
		open = open,
		selected = if selected ~= nil then selected:GetFullName() else "",
		hud = {
			bonesShown = shown(hudFind("Money_bones")),
			bonesText = textOf(hudFind("Money_bones")),
			cashPillShown = shown(hudFind("CashPill")),
			worldRowShown = shown(hudFind("WorldRow_dino")),
			attackShown = shown(hudFind("Hud_Attack")),
			teleportNew = shown(newTag),
			offers = offers,
			objective = objectiveText,
		},
		lighting = {
			densities = densities,
			tint = if tintColor ~= nil
				then { math.round(tintColor.R * 255), math.round(tintColor.G * 255), math.round(tintColor.B * 255) }
				else nil,
		},
		music = context,
		bedPlaying = bedPlaying,
		popup = WorldClient.popupState(),
		-- The HUD zones Hud published (design px; "TopRight" = the R59 phone row).
		zones = {
			Left = HudZones.rect("Left"),
			Right = HudZones.rect("Right"),
			Top = HudZones.rect("Top"),
			TopRight = HudZones.rect("TopRight"),
			Bottom = HudZones.rect("Bottom"),
		},
		device = { phone = ScreenManager.device.isPhone == true, touch = ScreenManager.isTouchDevice() },
	})
elseif COMMAND == "modal_close" then
	local closed = 0
	while ScreenManager.anyModalOpen() and closed < 8 do
		ScreenManager.closeTopModal()
		closed += 1
		task.wait(0.3)
	end
	if ScreenManager.isOpen("WorldRejoin") then
		ScreenManager.close("WorldRejoin")
	end
	return `closed {closed}`
elseif COMMAND == "open" then
	local code = math.floor(ARGS[1] or 1)
	local ok, err = pcall(function()
		if code == 1 then
			ScreenManager.open("Teleport")
		elseif code == 2 then
			ScreenManager.open("Teleport", { world = "dino" })
		elseif code == 3 then
			ScreenManager.open("Rebirth")
		elseif code == 4 then
			ScreenManager.open("Shop", { source = "other" })
		elseif code == 5 then
			ScreenManager.open(
				"WelcomeBack",
				{ amount = 1.2e12, seconds = 3275, worlds = { { id = "dino", amount = 4.5e6 } } }
			)
		elseif code == 6 then
			ScreenManager.open("WorldRejoin", { worldId = "dino" })
		elseif code == 7 then
			WorldClient.previewLocked("dino", "hud")
		elseif code == 8 then
			ScreenManager.open("WorldUnlocked", { worldId = "dino", mode = "unlocked", source = "auto" })
		elseif code == 9 then
			ScreenManager.open("Rebirth", { world = "dino" })
		end
	end)
	return if ok then `opened {code}` else `ERROR {err}`
elseif COMMAND == "upgrade" then
	local ProducerBillboards = (require :: any)(client.Tycoon.ProducerBillboards)
	local ScreenRect = (require :: any)(client.UI.Widgets.ScreenRect)
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root == nil then
		return "ERROR no character"
	end
	local record = ProducerBillboards.nearestOwn((root :: BasePart).Position, 600)
	if record == nil then
		return "ERROR no own producer nearby"
	end
	local button: GuiObject = record.upgrade
	local raw = button.AbsolutePosition
	local position, size = ScreenRect.of(button)
	local sent = ProducerBillboards.upgrade(record)
	return HttpService:JSONEncode({
		sent = sent,
		raw = { raw.X, raw.Y },
		projected = if position ~= nil then { math.round(position.X), math.round(position.Y) } else "offscreen",
		size = if size ~= nil then { math.round(size.X), math.round(size.Y) } else nil,
		viewport = { workspace.CurrentCamera.ViewportSize.X, workspace.CurrentCamera.ViewportSize.Y },
	})
elseif COMMAND == "padbuy" then
	local WorldLookup = (require :: any)(client.Tycoon.WorldLookup)
	local TycoonWorld = (require :: any)(client.Tycoon.TycoonWorld)
	local Remotes = (require :: any)(ReplicatedStorage.Shared.Net.Remotes)
	local worldId = WorldClient.current()
	local tycoon = WorldLookup.tycoon(worldId)
	if tycoon == nil then
		return "ERROR no tycoon"
	end
	local nextPad = WorldLookup.logic(worldId).nextPads(tycoon)[1]
	if nextPad == nil then
		return "ERROR no next pad"
	end
	local padId: string = nextPad.id
	local pad = TycoonWorld.myPad(padId)
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if pad == nil or root == nil then
		return `ERROR pad {padId} not streamed / no character`
	end
	(root :: BasePart).CFrame = (pad :: BasePart).CFrame + Vector3.new(0, 4, 0)
	task.wait(0.4)
	Remotes.event("PadBuy"):FireServer(padId)
	return `padbuy {padId}`
elseif COMMAND == "flystate" then
	local CurrencyFly = (require :: any)(client.UI.Hud.CurrencyFly)
	local ClientState = (require :: any)(client.ClientState)
	local profile = ClientState.profile
	return HttpService:JSONEncode({
		bursts = CurrencyFly.state().bursts,
		cash = if profile ~= nil then profile.cash else nil,
		bones = ClientState.worldCash("dino"),
		world = WorldClient.current(),
	})
elseif COMMAND == "travel" then
	local code = math.floor(ARGS[1] or 1)
	local sent = if code == 1
		then WorldClient.travel("dino", "spawn", nil, "menu")
		else WorldClient.travel("main", "spawn", nil, "menu")
	return `travel {code} sent={sent}`
end
return `ERROR unknown command {COMMAND}`
