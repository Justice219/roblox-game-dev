--!strict
--[[
	EventController — the client half of the Harvest Feast (spec §10, docs/event.md).

	Purpose:
		- EventState (S→C) → TurkeyRenderer: "sync" replaces every turkey, "spawn" / "despawn" add /
		  remove one, "caught" plays the reward (confetti poof, "+7" acorn popup, sticker toast,
		  a soft chime, platform haptics), "refused" re-allows a catch request.
		- Catching (console + mobile first, owner R11): walk into a turkey (auto-catch within
		  CatchRadius, checked at 10 Hz), the platform action "EventCollect" (gamepad A / E / the
		  touch CATCH! button while a turkey is near; ProximityPrompt fallback until the action
		  exists), or click / tap the turkey itself (ClickDetector on an enlarged hitbox,
		  TapRange). Every path sends only EventCollect(turkeyId); the server validates distance,
		  cooldown and ownership.
		- HUD: the left-column "Event" button is visible while the event runs (and during the redeem
		  grace for a completed, unredeemed sheet) with a "!" badge when the Gobble Bomb is ready.
		- Hub NPC: a "Sticker Sheet" ProximityPrompt in front of the Harvest turkey statue
		  (HubLayout.event.harvest) opens the HarvestFeast screen while the event runs.

	Performance: one Heartbeat for all turkeys (TurkeyRenderer), one 10 Hz auto-catch loop, pooled
	FX (no Instance churn per catch), nothing at all while no turkey exists.

	Connects to: Client/Event/{TurkeyRenderer,EventView}, UI/Hud/Hud, UI/ScreenManager,
	Shared/Config/EventConfig, Shared/Net/Remotes (EventState, EventCollect).
	Boot: the client entry point loads it like every controller (Init, then Start).

	Example: EventController.Init(); EventController.Start()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local ActionMap = require(script.Parent.Parent.Platform.ActionMap)
local ClientState = require(script.Parent.Parent.ClientState)
local EventConfig = require(ReplicatedStorage.Shared.Config.EventConfig)
local EventView = require(script.Parent.EventView)
local Haptics = require(script.Parent.Parent.Platform.Haptics)
local Hud = require(script.Parent.Parent.UI.Hud.Hud)
local InputController = require(script.Parent.Parent.Controllers.InputController)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local PlatformConfig = require(ReplicatedStorage.Shared.Config.PlatformConfig)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local TurkeyRenderer = require(script.Parent.TurkeyRenderer)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local EventController = {}

local localPlayer = Players.LocalPlayer
local started = false

-- The screen the HUD Event button / the hub NPC open (Screens/StickerSheet registers it).
local SHEET_SCREEN = "HarvestFeast"
-- Platform action + context names (B16 PlatformConfig) for catching with gamepad A / touch.
local COLLECT_ACTION = "EventCollect"
local NEAR_CONTEXT = "TurkeyNear"
-- Catch chime (built-in client sound; muted when profile.settings.sfx is off).
local CATCH_SOUND = "rbxasset://sounds/electronicpingshort.wav"
-- Pooled reward FX.
local FX_POOL_SIZE = 4
local POPUP_SECONDS = 1.3

type Fx = { anchor: Part, confetti: ParticleEmitter, billboard: BillboardGui, label: TextLabel, busy: boolean }

local fxPool: { Fx } = {}
local catchSound: Sound? = nil
local npcPrompt: ProximityPrompt? = nil

-- A finite number from an untyped payload field (nil when junk).
local function num(value: unknown): number?
	if type(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return value
	end
	return nil
end

-- profile.settings.<key> (default true when unknown).
local function setting(key: string, default: boolean): boolean
	local profile = ClientState.profile
	local settings = if type(profile) == "table" then profile.settings else nil
	if type(settings) == "table" and type(settings[key]) == "boolean" then
		return settings[key]
	end
	return default
end

--------------------------------------------------------------------------------------------------
-- FX (pooled)
--------------------------------------------------------------------------------------------------

-- Builds one reusable FX rig: an invisible anchor with a confetti emitter and a "+N" billboard.
local function newFx(): Fx
	local anchor = Instance.new("Part")
	anchor.Name = "HarvestFx"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	local confetti = Instance.new("ParticleEmitter")
	confetti.Name = "Confetti"
	confetti.Enabled = false
	confetti.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 205, 60)),
		ColorSequenceKeypoint.new(0.35, Color3.fromRGB(245, 120, 40)),
		ColorSequenceKeypoint.new(0.7, Color3.fromRGB(222, 62, 52)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(112, 176, 64)),
	})
	confetti.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 0.1) })
	confetti.Lifetime = NumberRange.new(0.7, 1.2)
	confetti.Speed = NumberRange.new(10, 18)
	confetti.SpreadAngle = Vector2.new(60, 60)
	confetti.Acceleration = Vector3.new(0, -30, 0)
	confetti.Rotation = NumberRange.new(0, 360)
	confetti.RotSpeed = NumberRange.new(-300, 300)
	confetti.EmissionDirection = Enum.NormalId.Top
	confetti.Parent = anchor
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Popup"
	billboard.Size = UDim2.fromOffset(240, 70)
	billboard.StudsOffset = Vector3.new(0, 4, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 120
	billboard.Enabled = false
	billboard.Adornee = anchor
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.FontFace = UIStyleConfig.Fonts.Shout
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 214, 72)
	label.TextStrokeColor3 = Color3.fromRGB(40, 24, 10)
	label.TextStrokeTransparency = 0
	label.Text = ""
	label.Parent = billboard
	billboard.Parent = anchor
	local fx: Fx = { anchor = anchor, confetti = confetti, billboard = billboard, label = label, busy = false }
	return fx
end

-- Plays the catch burst + popup at `position` (skips the burst with Reduced Motion).
local function playCatchFx(position: Vector3, text: string)
	local fx: Fx? = nil
	for _, candidate in fxPool do
		if not candidate.busy then
			fx = candidate
			break
		end
	end
	if fx == nil then
		if #fxPool >= FX_POOL_SIZE then
			return
		end
		fx = newFx()
		table.insert(fxPool, fx :: Fx)
	end
	local rig = fx :: Fx
	rig.busy = true
	rig.anchor.CFrame = CFrame.new(position + Vector3.new(0, 2, 0))
	rig.anchor.Parent = Workspace
	local reduced = setting("reducedMotion", false)
	if not reduced then
		rig.confetti:Emit(36)
	end
	rig.label.Text = text
	rig.label.TextTransparency = 0
	rig.label.TextStrokeTransparency = 0
	rig.billboard.StudsOffset = Vector3.new(0, 3, 0)
	rig.billboard.Enabled = true
	local info = TweenInfo.new(POPUP_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(rig.billboard, info, { StudsOffset = Vector3.new(0, 7, 0) }):Play()
	TweenService:Create(rig.label, info, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	task.delay(POPUP_SECONDS + 0.4, function()
		rig.billboard.Enabled = false
		rig.anchor.Parent = nil
		rig.busy = false
	end)
end

-- Soft chime (local only) when sfx is on.
local function playChime()
	if not setting("sfx", true) then
		return
	end
	local sound = catchSound
	if sound == nil then
		local created = Instance.new("Sound")
		created.Name = "HarvestCatch"
		created.SoundId = CATCH_SOUND
		created.Volume = 0.6
		created.Parent = SoundService
		catchSound = created
		sound = created
	end
	pcall(function()
		SoundService:PlayLocalSound(sound :: Sound)
	end)
end

-- Platform haptics (gamepad rumble / phone HapticEffect; owner R11 "haptics on key moments").
local function haptic(name: "Tap" | "Reward" | "Purchase")
	pcall(Haptics.play, name)
end

--------------------------------------------------------------------------------------------------
-- HUD + NPC
--------------------------------------------------------------------------------------------------

-- Event button visibility + "!" badge, from EventView.
local function refreshHud()
	-- Quick-menu wheel Event tile (B16) follows the same rule as the HUD button.
	ActionMap.setContext("EventLive", EventView.buttonVisible())
	Hud.setButtonVisible("Event", EventView.buttonVisible())
	Hud.setButtonBadge("Event", if EventView.canRedeem() then "!" else nil)
	local prompt = npcPrompt
	if prompt ~= nil then
		prompt.Enabled = EventView.active()
	end
end

-- The hub "Sticker Sheet" prompt at the Harvest turkey statue (HubLayout.event.harvest, B8e).
local function buildNpcPrompt()
	local module = ReplicatedStorage.Shared.Config:FindFirstChild("HubLayout")
	if module == nil or not module:IsA("ModuleScript") then
		return
	end
	local ok, layout = pcall(require, module)
	if not ok or type(layout) ~= "table" or type(layout.event) ~= "table" then
		return
	end
	-- B8e: event.npc = in front of the statue, 3 studs up; else derive it from the statue placement.
	local spot: CFrame? = if typeof(layout.event.npc) == "CFrame" then layout.event.npc else nil
	local harvest = layout.event.harvest
	if spot == nil and type(harvest) == "table" and type(harvest.models) == "table" then
		for _, entry in harvest.models do
			if type(entry) == "table" and entry.key == "Harvest_TurkeyStatue" and typeof(entry.cf) == "CFrame" then
				spot = (entry.cf :: CFrame) * CFrame.new(0, 3, -5)
				break
			end
		end
	end
	if spot == nil then
		return
	end
	local anchor = Instance.new("Part")
	anchor.Name = "HarvestNpcPrompt"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.CFrame = spot :: CFrame
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Sticker Sheet"
	prompt.ObjectText = "Harvest Feast"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 14
	prompt.RequiresLineOfSight = false
	prompt.Triggered:Connect(function()
		ScreenManager.open(SHEET_SCREEN)
	end)
	prompt.Parent = anchor
	anchor.Parent = Workspace
	npcPrompt = prompt
end

--------------------------------------------------------------------------------------------------
-- EventState
--------------------------------------------------------------------------------------------------

-- Validated turkey ids from a payload list.
local function idList(value: unknown): { string }
	local ids: { string } = {}
	if type(value) == "table" then
		for _, item in value :: { unknown } do
			if type(item) == "string" and #item <= EventConfig.Limits.MaxTurkeyIdLength then
				table.insert(ids, item)
			end
			if #ids >= 64 then
				break
			end
		end
	end
	return ids
end

-- A "caught" reply: remove the turkey here, celebrate, toast the sticker.
local function onCaught(payload: { [string]: unknown })
	local id = payload.id
	if type(id) ~= "string" then
		return
	end
	local position = TurkeyRenderer.remove(id)
	local acorns = math.max(0, math.floor(num(payload.acorns) or 0))
	local bonus = math.max(0, math.floor(num(payload.bonus) or 0))
	local sticker = math.floor(num(payload.sticker) or 0)
	local count = math.floor(num(payload.count) or 0)
	if position == nil then
		local character = localPlayer.Character
		local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
		position = if root ~= nil and root:IsA("BasePart") then root.Position else nil
	end
	if position ~= nil then
		playCatchFx(position, `+{NumberFormat.commas(acorns + bonus)}`)
	end
	playChime()
	haptic("Tap")
	local def = EventConfig.Stickers[sticker]
	if def ~= nil then
		if payload.dup == true then
			Hud.notify("reward", `{def.name} again! +{bonus} bonus acorns`, def.icon)
		else
			Hud.notify("reward", `NEW STICKER! {def.name} ({count}/{EventConfig.StickerCount})`, def.icon)
			haptic("Reward")
			if count >= EventConfig.StickerCount then
				Hud.notify(
					"success",
					`Sticker sheet complete! Redeem your {EventConfig.RewardPetName}!`,
					EventConfig.RewardIcon
				)
			end
		end
	end
end

local function onState(payload: unknown)
	if type(payload) ~= "table" then
		return
	end
	local data = payload :: { [string]: unknown }
	local kind = data.kind
	if kind == "sync" then
		TurkeyRenderer.clear()
		local caught: { [string]: boolean } = {}
		for _, id in idList(data.caught) do
			caught[id] = true
		end
		if type(data.turkeys) == "table" then
			for index, raw in data.turkeys :: { unknown } do
				if index > EventConfig.Turkey.MaxAliveWithLures * 2 then
					break
				end
				local wire = EventConfig.parseTurkey(raw)
				if wire ~= nil and not caught[wire.id] then
					TurkeyRenderer.add(wire)
				end
			end
		end
	elseif kind == "spawn" then
		local wire = EventConfig.parseTurkey(data.turkey)
		if wire ~= nil then
			TurkeyRenderer.add(wire)
		end
	elseif kind == "despawn" then
		if type(data.id) == "string" then
			TurkeyRenderer.remove(data.id)
		end
	elseif kind == "caught" then
		onCaught(data)
	elseif kind == "refused" then
		local id = data.id
		if type(id) == "string" then
			if data.reason == "missing" or data.reason == "already" or data.reason == "notOwner" then
				TurkeyRenderer.remove(id)
			else
				TurkeyRenderer.clearPending(id)
			end
		end
	elseif kind == "redeemed" then
		haptic("Reward")
		playChime()
	end
end

--------------------------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------------------------

function EventController.Init() end

function EventController.Start()
	if started then
		return
	end
	started = true
	EventView.start()
	local collect = Remotes.event("EventCollect")
	TurkeyRenderer.start(function(id: string)
		collect:FireServer(id)
	end)
	TurkeyRenderer.setReducedMotion(setting("reducedMotion", false))
	ClientState.ProfileChanged:Connect(function(_profile: any, fields: { string }?)
		if fields == nil or table.find(fields, "settings") ~= nil then
			TurkeyRenderer.setReducedMotion(setting("reducedMotion", false))
		end
	end)
	Remotes.event("EventState").OnClientEvent:Connect(onState)

	-- The turkey template replicates from the server (built once at server start).
	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild(EventConfig.AssetFolder, 60)
		local template = if folder ~= nil then folder:WaitForChild(EventConfig.TurkeyTemplate, 60) else nil
		if template ~= nil and template:IsA("Model") then
			TurkeyRenderer.setTemplate(template)
		else
			warn("[EventController] GoldenTurkey template did not replicate; turkeys stay invisible")
		end
	end)

	EventView.Changed:Connect(refreshHud)
	pcall(buildNpcPrompt)
	refreshHud()

	-- Console + mobile (owner R11): the platform action "EventCollect" (gamepad A / E / a touch
	-- CATCH! button, bound while the context "TurkeyNear" is on) catches the nearest turkey. Until
	-- PlatformConfig declares it, every turkey keeps its ProximityPrompt (E / gamepad X / tap).
	local actions = PlatformConfig.Actions :: { [string]: any }
	if actions[COLLECT_ACTION] ~= nil and table.find(PlatformConfig.Contexts :: { string }, NEAR_CONTEXT) ~= nil then
		TurkeyRenderer.setPromptsEnabled(false)
		ActionMap.addContextProvider(function(root: Vector3): { [string]: boolean }?
			return { [NEAR_CONTEXT] = TurkeyRenderer.nearest(root, EventConfig.Turkey.PromptRange) ~= nil } :: any
		end)
		InputController.ActionPressed:Connect(function(action: string)
			if action ~= COLLECT_ACTION then
				return
			end
			local character = localPlayer.Character
			local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
			if root ~= nil and root:IsA("BasePart") then
				local id = TurkeyRenderer.nearest(root.Position, EventConfig.Turkey.PromptRange)
				if id ~= nil then
					TurkeyRenderer.requestCatch(id)
				end
			end
		end)
	end

	-- Auto-catch: walking into a turkey (10 Hz; cheap: only runs a distance check per turkey).
	task.spawn(function()
		while true do
			task.wait(0.1)
			if TurkeyRenderer.count() == 0 then
				continue
			end
			local character = localPlayer.Character
			local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
			if root ~= nil and root:IsA("BasePart") then
				for _, id in TurkeyRenderer.near(root.Position, EventConfig.Turkey.CatchRadius) do
					TurkeyRenderer.requestCatch(id)
				end
			end
		end
	end)
end

return EventController
