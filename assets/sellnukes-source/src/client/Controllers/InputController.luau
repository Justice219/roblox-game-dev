--!strict
--[[
	InputController — input MODE tracking and named UI / tycoon actions for SellNukes.

	Purpose:
		SellNukes uses Roblox's default character controls (PlayerModule) for movement, so this
		controller does NOT drive the character. It provides what the UI framework and tycoon
		client need on top of that:
			- `InputController.mode`: "KeyboardMouse" | "Gamepad" | "Touch" — the device the
			  player is using RIGHT NOW (follows UserInputService.LastInputType), with
			  `ModeChanged` so glyphs, tap-target sizes and gamepad selection follow live.
			- `ActionPressed(action)` / `ActionReleased(action)` for the named actions of
			  Shared/Config/PlatformConfig (re-exported by InputConfig). Platform/ActionMap (B16)
			  binds them with ContextActionService (priorities, contexts) and its touch buttons,
			  and fires them through `pressAction` / `releaseAction` — one path for every device.
			- `setGameplayBlocked(reason, blocked)`: a COUNTED switch (on while any reason is on).
			  ScreenManager sets "Menus" while a modal window is open. While blocked, gameplay
			  actions do not fire, and on a gamepad the character's movement is paused so the
			  thumbstick / D-pad only move the menu selection (keyboard and touch players can
			  still walk with a shop open, like the references).
			- `consumeInputPress(keyCode)`: claims a press already handled elsewhere (the modal
			  Back key) so no ActionPressed fires for it until it is released.

	Security / trust: input is presentation-only. Every action ends in a server INTENT remote
	that the server validates; nothing here grants anything.

	Performance: event-driven (InputBegan / InputEnded / LastInputTypeChanged for the mode); no
	per-frame work.

	Connects to: Shared/Config/InputConfig, UI/ScreenManager (blocking, mode), UI/Components
	(touch hints), UI/Widgets/InputGlyph (live glyphs), Controllers/UIController (boot).

	Example:
		InputController.ActionPressed:Connect(function(action)
			if action == "Interact" then TycoonClient.upgradeNearest() end
		end)
		print(InputController.mode) --> "KeyboardMouse"
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local InputConfig = require(ReplicatedStorage.Shared.Config.InputConfig)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

export type InputMode = "KeyboardMouse" | "Gamepad" | "Touch"
export type ActionName = InputConfig.ActionName

local InputController = {}

--[[
	The mode at boot: touch-first devices start in Touch (so the very first frame lays out for a
	finger), a gamepad-only console starts in Gamepad, everything else in KeyboardMouse.
]]
local function initialMode(): InputMode
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "Touch"
	end
	if UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		return "Gamepad"
	end
	return "KeyboardMouse"
end

InputController.mode = initialMode() :: InputMode
InputController.ModeChanged = Signal.new() :: Signal.Signal<InputMode>
InputController.ActionPressed = Signal.new() :: Signal.Signal<ActionName>
InputController.ActionReleased = Signal.new() :: Signal.Signal<ActionName>
-- Fires (enabled) when gameplay input becomes blocked / unblocked.
InputController.GameplayEnabledChanged = Signal.new() :: Signal.Signal<boolean>

-- Reverse index: KeyCode -> actions bound to it (built once from InputConfig).
local actionsOn: { [Enum.KeyCode]: { ActionName } } = {}
-- Gameplay block reasons (counted switch).
local blockReasons: { [string]: true } = {}
local gameplayEnabled = true
-- Actions currently held (pressed and not released) -> true.
local held: { [ActionName]: boolean } = {}
-- KeyCodes whose current press was consumed by another handler (cleared on release).
local consumed: { [Enum.KeyCode]: boolean } = {}
-- Studio-only forced mode (setForcedMode); nil = follow the devices.
local forcedMode: InputMode? = nil
local started = false

for action, binding in InputConfig.Actions do
	local name = action :: ActionName
	for _, keyCode in binding.keys do
		local list = actionsOn[keyCode] or {}
		table.insert(list, name)
		actionsOn[keyCode] = list
	end
	for _, keyCode in binding.buttons do
		local list = actionsOn[keyCode] or {}
		table.insert(list, name)
		actionsOn[keyCode] = list
	end
end

--[[ Maps a Roblox input type onto an InputMode (nil = not a device switch, e.g. Focus). ]]
local function modeFor(inputType: Enum.UserInputType): InputMode?
	if inputType == Enum.UserInputType.Touch then
		return "Touch"
	end
	if
		inputType == Enum.UserInputType.Keyboard
		or inputType == Enum.UserInputType.MouseButton1
		or inputType == Enum.UserInputType.MouseButton2
		or inputType == Enum.UserInputType.MouseButton3
		or inputType == Enum.UserInputType.MouseWheel
		or inputType == Enum.UserInputType.MouseMovement
	then
		return "KeyboardMouse"
	end
	if inputType.Name:sub(1, 7) == "Gamepad" then
		return "Gamepad"
	end
	return nil
end

-- Pauses / resumes the default character controls (gamepad + modal only; see header).
local function applyCharacterControls()
	local player = Players.LocalPlayer
	if player == nil then
		return
	end
	local scripts = player:FindFirstChildOfClass("PlayerScripts")
	local moduleScript = if scripts ~= nil then scripts:FindFirstChild("PlayerModule") else nil
	if moduleScript == nil or not moduleScript:IsA("ModuleScript") then
		return
	end
	local ok, loaded = pcall(require, moduleScript)
	if not ok or type(loaded) ~= "table" then
		return
	end
	-- The PlayerModule is Roblox's untyped default script: treat it as `any` behind type checks.
	local playerModule: any = loaded
	local gotControls, controls = pcall(function(): any
		return playerModule:GetControls()
	end)
	if not gotControls or controls == nil then
		return
	end
	local pause = not gameplayEnabled and InputController.mode == "Gamepad"
	pcall(function()
		if pause then
			controls:Disable()
		else
			controls:Enable()
		end
	end)
end

-- Switches the mode (ignored while a Studio test forces one) and notifies listeners.
local function setMode(mode: InputMode)
	if forcedMode ~= nil then
		mode = forcedMode
	end
	if InputController.mode == mode then
		return
	end
	InputController.mode = mode
	-- A device switch releases every held action (a released key on the old device would
	-- otherwise never send its ActionReleased).
	for action in held do
		held[action] = nil
		InputController.ActionReleased:Fire(action)
	end
	table.clear(consumed)
	applyCharacterControls()
	InputController.ModeChanged:Fire(mode)
end

--[[
	Blocks / unblocks gameplay input for `reason` (counted: gameplay is enabled only when no
	reason is active, so two systems can never leave input stuck).
	@param reason  stable id ("Menus", "Cutscene", ...)
	@param blocked true to add the reason, false to remove it
	Example: InputController.setGameplayBlocked("Menus", true)
]]
function InputController.setGameplayBlocked(reason: string, blocked: boolean)
	if blocked then
		blockReasons[reason] = true
	else
		blockReasons[reason] = nil
	end
	local enabled = next(blockReasons) == nil
	if enabled == gameplayEnabled then
		return
	end
	gameplayEnabled = enabled
	if not enabled then
		-- Release held gameplay actions so nothing stays "down" behind a menu.
		for action in held do
			local binding = InputConfig.Actions[action]
			if binding ~= nil and not binding.whileBlocked then
				held[action] = nil
				InputController.ActionReleased:Fire(action)
			end
		end
	end
	applyCharacterControls()
	InputController.GameplayEnabledChanged:Fire(enabled)
end

--[[ True while no gameplay block reason is active. ]]
function InputController.isGameplayEnabled(): boolean
	return gameplayEnabled
end

--[[
	Claims the current press of `keyCode` (already handled elsewhere, e.g. ScreenManager's Back):
	no ActionPressed fires for it, and actions it holds are released, until the key goes up.
	@param keyCode the pressed key / button
	@param _inputType reserved (mouse buttons share KeyCode.Unknown; not used by SellNukes)
]]
function InputController.consumeInputPress(keyCode: Enum.KeyCode, _inputType: Enum.UserInputType?)
	consumed[keyCode] = true
	local actions = actionsOn[keyCode]
	if actions == nil then
		return
	end
	for _, action in actions do
		if held[action] then
			held[action] = nil
			InputController.ActionReleased:Fire(action)
		end
	end
end

--[[
	True while `action` is held.
	Example: if InputController.isHeld("Interact") then ... end
]]
function InputController.isHeld(action: ActionName): boolean
	return held[action] == true
end

--[[
	STUDIO ONLY test hook: pins the input mode (nil = follow the devices again), e.g. "Touch" to
	check phone layouts from a desktop Studio session. Ignored on live servers.
	Example: InputController.setForcedMode("Touch")
]]
function InputController.setForcedMode(mode: InputMode?)
	if not RunService:IsStudio() then
		return
	end
	forcedMode = mode
	if mode ~= nil then
		forcedMode = nil -- let setMode apply it, then pin
		setMode(mode)
		forcedMode = mode
	else
		local live = modeFor(UserInputService:GetLastInputType())
		if live ~= nil then
			setMode(live)
		end
	end
end

-- True when `action` may fire right now (blocking + Studio-only rules).
local function allowed(action: ActionName): boolean
	local binding = InputConfig.Actions[action]
	if binding == nil then
		return false
	end
	if binding.studioOnly == true and not RunService:IsStudio() then
		return false
	end
	return gameplayEnabled or binding.whileBlocked
end

--[[
	Fires `action` (ActionPressed) when it is allowed right now: not already held, not Studio-only
	on a live server, gameplay not blocked (unless the action is UI-only `whileBlocked`), and no
	TextBox has focus (typing a code must never trigger an action).
	The ONLY way actions fire (owner rule R11): Platform/ActionMap calls it from its
	ContextActionService bindings (priorities + contexts) and from the on-screen touch buttons,
	so keyboard, gamepad and touch share one path. This module keeps the input MODE.
	@param action the PlatformConfig action
	@return true when ActionPressed fired
	Example: InputController.pressAction("Produce")
]]
function InputController.pressAction(action: ActionName): boolean
	if held[action] or not allowed(action) then
		return false
	end
	if UserInputService:GetFocusedTextBox() ~= nil then
		return false
	end
	held[action] = true
	InputController.ActionPressed:Fire(action)
	return true
end

--[[
	Releases a held action (ActionReleased); no-op when it is not held.
	@param action the PlatformConfig action
	Example: InputController.releaseAction("Produce")
]]
function InputController.releaseAction(action: ActionName)
	if held[action] then
		held[action] = nil
		InputController.ActionReleased:Fire(action)
	end
end

-- Mode tracking only: every input event moves the mode (actions come from pressAction).
local function onInputBegan(input: InputObject, _gameProcessed: boolean)
	local mode = modeFor(input.UserInputType)
	if mode ~= nil then
		setMode(mode)
	end
end

-- A released key ends any "consumed" claim on it (consumeInputPress).
local function onInputEnded(input: InputObject, _gameProcessed: boolean)
	consumed[input.KeyCode] = nil
end

function InputController.Init() end

--[[
	Connects the device listeners (once). Called by the client boot after Init.
]]
function InputController.Start()
	if started then
		return
	end
	started = true
	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)
	UserInputService.LastInputTypeChanged:Connect(function(inputType: Enum.UserInputType)
		local mode = modeFor(inputType)
		if mode ~= nil then
			setMode(mode)
		end
	end)
	local live = modeFor(UserInputService:GetLastInputType())
	if live ~= nil then
		setMode(live)
	end
	-- The PlayerModule may be rebuilt on respawn; re-apply the pause state for the new controls.
	local player = Players.LocalPlayer
	if player ~= nil then
		player.CharacterAdded:Connect(function()
			task.defer(applyCharacterControls)
		end)
	end
end

return InputController
