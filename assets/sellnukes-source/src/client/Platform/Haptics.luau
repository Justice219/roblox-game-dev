--!strict
--[[
	Haptics — rumble / vibration presets for key moments (owner R11: "haptics on key moments").

	Presets (PlatformConfig.Haptics.Presets): Tap, Purchase, BuildComplete, Hatch, Hit, Reward,
	Error. Each drives:
		- GAMEPAD (mode Gamepad): HapticService:SetMotor on the gamepad the player last used —
		  small (high-frequency) + large (low-frequency) motors for `seconds`, then off. One
		  pending stop per gamepad (a newer buzz extends / replaces the older one).
		- PHONE / TABLET (mode Touch): a pooled HapticEffect of the preset's type (the engine's
		  phone waveform; silently nothing on devices without haptics).
		- Keyboard / mouse: nothing.
	Respects the player's Vibration setting (profile.settings.haptics; default ON while the key
	does not exist yet) and a local override (setEnabled, e.g. a Studio test). The same preset
	never restarts within MinGap seconds (a burst of purchase toasts = one buzz). Motors stop
	when the window loses focus, the gamepad disconnects, or haptics are switched off.

	Automatic hooks (PlatformController.start → Haptics.start):
		ClientState.PurchaseGranted        → Purchase
		ClientState.Notified kind purchase → Purchase; reward → Reward; error → Error
		ActionPressed "Produce" (gamepad)  → Tap
	Other systems call Haptics.play: build-in complete (B4) "BuildComplete", egg hatch (B9)
	"Hatch", nuke hit on your plot (B10) "Hit".

	Performance: no per-frame work; at most one task.delay per gamepad and one HapticEffect per
	preset type, created on first use.

	Connects to: Shared/Config/PlatformConfig, Client/ClientState, Controllers/InputController,
	Platform/{PlatformController, TouchButtons}.

	Example:
		Haptics.play("BuildComplete")
		Haptics.setEnabled(false)
]]

local HapticService = game:GetService("HapticService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local ClientState = require(script.Parent.Parent.ClientState)
local InputController = require(script.Parent.Parent.Controllers.InputController)
local PlatformConfig = require(ReplicatedStorage.Shared.Config.PlatformConfig)

export type HapticName = PlatformConfig.HapticName

local Config = PlatformConfig.Haptics

local Haptics = {}

local started = false
local settingEnabled = true -- profile.settings.haptics (default on)
local localEnabled = true -- setEnabled override
local lastGamepad: Enum.UserInputType = Enum.UserInputType.Gamepad1
local lastPlayed: { [string]: number } = {}
-- Per gamepad: the token of the latest buzz (a stop only applies to its own buzz).
local stopTokens: { [Enum.UserInputType]: number } = {}
-- Pooled HapticEffects by type name.
local effects: { [string]: HapticEffect } = {}
-- Plays counted for QA / tests (Haptics.stats()).
local playCount = 0

-- True for Gamepad1..Gamepad8.
local function isGamepad(inputType: Enum.UserInputType): boolean
	return string.sub(inputType.Name, 1, 7) == "Gamepad"
end

-- Turns both motors of a gamepad off (pcall: unsupported motors throw on some platforms).
local function stopMotors(gamepad: Enum.UserInputType)
	stopTokens[gamepad] = (stopTokens[gamepad] or 0) + 1
	pcall(function()
		HapticService:SetMotor(gamepad, Enum.VibrationMotor.Small, 0)
		HapticService:SetMotor(gamepad, Enum.VibrationMotor.Large, 0)
	end)
end

--[[ True when haptics may play (setting + local override). ]]
function Haptics.isEnabled(): boolean
	return settingEnabled and localEnabled
end

--[[
	Local override (e.g. Studio tests, a cutscene). Switching off stops running motors.
	Example: Haptics.setEnabled(false)
]]
function Haptics.setEnabled(on: boolean)
	localEnabled = on
	if not Haptics.isEnabled() then
		stopMotors(lastGamepad)
	end
end

-- Gamepad buzz: both motors for `seconds`, then off (only if no newer buzz started).
local function buzzGamepad(preset: PlatformConfig.HapticPreset)
	local gamepad = lastGamepad
	local supported = false
	pcall(function()
		supported = HapticService:IsVibrationSupported(gamepad)
	end)
	if not supported then
		return
	end
	local token = (stopTokens[gamepad] or 0) + 1
	stopTokens[gamepad] = token
	pcall(function()
		if HapticService:IsMotorSupported(gamepad, Enum.VibrationMotor.Small) then
			HapticService:SetMotor(gamepad, Enum.VibrationMotor.Small, preset.small)
		end
		if HapticService:IsMotorSupported(gamepad, Enum.VibrationMotor.Large) then
			HapticService:SetMotor(gamepad, Enum.VibrationMotor.Large, preset.large)
		end
	end)
	task.delay(preset.seconds, function()
		if stopTokens[gamepad] == token then
			stopMotors(gamepad)
		end
	end)
end

-- Phone vibration through a pooled HapticEffect of the preset's type.
local function buzzTouch(preset: PlatformConfig.HapticPreset)
	local key = preset.effect.Name
	local effect = effects[key]
	if effect == nil or effect.Parent == nil then
		local ok, created = pcall(function(): HapticEffect
			local instance = Instance.new("HapticEffect")
			instance.Name = `SellNukesHaptic_{key}`
			instance.Type = preset.effect
			instance.Parent = Workspace
			return instance
		end)
		if not ok then
			return -- HapticEffect unavailable on this client
		end
		effect = created
		effects[key] = created
	end
	pcall(function()
		effect:Play()
	end)
end

--[[
	Plays a preset on the device in hand (see the module header).
	@param name preset name
	@return true when something was sent to a device
	Example: Haptics.play("Hatch")
]]
function Haptics.play(name: HapticName): boolean
	local preset = Config.Presets[name]
	if preset == nil or not Haptics.isEnabled() then
		return false
	end
	local now = os.clock()
	if now - (lastPlayed[name] or -math.huge) < Config.MinGap then
		return false
	end
	lastPlayed[name] = now
	local mode = InputController.mode
	if mode == "Gamepad" then
		buzzGamepad(preset)
	elseif mode == "Touch" then
		buzzTouch(preset)
	else
		return false
	end
	playCount += 1
	return true
end

--[[ QA counters: { plays, enabled, gamepad }. ]]
function Haptics.stats(): { plays: number, enabled: boolean, gamepad: string }
	return { plays = playCount, enabled = Haptics.isEnabled(), gamepad = lastGamepad.Name }
end

-- Mirrors profile.settings.haptics (missing key = on).
local function readSetting(profile: ClientState.Profile?)
	local settings = if profile ~= nil then profile.settings else nil
	local value = if type(settings) == "table" then settings.haptics else nil
	settingEnabled = value ~= false
	if not settingEnabled then
		stopMotors(lastGamepad)
	end
end

--[[ Wires the automatic hooks and device tracking (once; PlatformController). ]]
function Haptics.start()
	if started then
		return
	end
	started = true
	UserInputService.InputBegan:Connect(function(input: InputObject)
		if isGamepad(input.UserInputType) then
			lastGamepad = input.UserInputType
		end
	end)
	UserInputService.GamepadDisconnected:Connect(function(gamepad: Enum.UserInputType)
		stopTokens[gamepad] = (stopTokens[gamepad] or 0) + 1
	end)
	UserInputService.WindowFocusReleased:Connect(function()
		stopMotors(lastGamepad)
	end)
	ClientState.ProfileChanged:Connect(function(profile, fields)
		if fields == nil or table.find(fields, "settings") ~= nil then
			readSetting(profile)
		end
	end)
	readSetting(ClientState.profile)
	ClientState.PurchaseGranted:Connect(function()
		Haptics.play("Purchase")
	end)
	ClientState.Notified:Connect(function(payload)
		if payload.kind == "purchase" then
			Haptics.play("Purchase")
		elseif payload.kind == "reward" then
			Haptics.play("Reward")
		elseif payload.kind == "error" then
			Haptics.play("Error")
		end
	end)
	InputController.ActionPressed:Connect(function(action)
		if action == "Produce" and InputController.mode == "Gamepad" then
			Haptics.play("Tap")
		end
	end)
end

return Haptics
