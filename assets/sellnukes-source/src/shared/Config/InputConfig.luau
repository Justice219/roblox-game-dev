--!strict
--[[
	InputConfig — every key / gamepad button binding the SellNukes client listens to.

	Purpose:
		One table of named ACTIONS (Interact, HudFocus, ...) with their keyboard keys and gamepad
		buttons, so InputController, prompts (InputGlyph) and docs all agree. SellNukes uses the
		default Roblox character controls for movement; these actions are the extras a tycoon
		needs (interact with the producer you stand at, jump the gamepad cursor onto the HUD).
		Later builders add actions HERE (never hard-code KeyCodes in screens).

	Close / Back keys (ported from RoBeasts' PopupCloseRule): every modal shows an [X] close
	chip. Keyboard X closes the top modal (Backspace is a silent alternate) unless a TextBox has
	focus (typing a code must never close the Codes window). Gamepad B always closes it.

	Connects to: Controllers/InputController (ActionPressed / ActionReleased), UI/ScreenManager
	(BackKeys), Shared/Util/PopupCloseRule (typing guard), UI/Widgets/InputGlyph (labels).

	Example:
		InputController.ActionPressed:Connect(function(action)
			if action == "Interact" then upgradeNearestProducer() end
		end)
]]

-- Every action name (add new ones here AND in Actions below).
local PlatformConfig = require(script.Parent.PlatformConfig)

-- The action map itself lives in Shared/Config/PlatformConfig (B16, owner rule R11: one map for
-- keyboard, gamepad and touch, with priorities + contexts). These re-exports keep every
-- existing `InputConfig.ActionName` / `InputConfig.Actions` user working unchanged.
export type ActionName = PlatformConfig.ActionName
export type Binding = PlatformConfig.Binding

local InputConfig = {}

-- Every named action (keys, gamepad buttons, priorities, contexts, touch buttons): PlatformConfig.
InputConfig.Actions = PlatformConfig.Actions

-- The key every modal's [X] chip SHOWS, plus the silent alternate.
InputConfig.CloseKey = Enum.KeyCode.X
InputConfig.CloseKeys = table.freeze({ Enum.KeyCode.X, Enum.KeyCode.Backspace })
InputConfig.BackButton = Enum.KeyCode.ButtonB
-- What ScreenManager binds while a modal is open (gamepad B + the keyboard close keys).
InputConfig.BackKeys = table.freeze({ Enum.KeyCode.ButtonB, Enum.KeyCode.X, Enum.KeyCode.Backspace })

-- Human-readable key-cap text for keys whose Enum name is not what the key shows.
InputConfig.KeyLabels = table.freeze({
	Backspace = "⌫",
	Return = "Enter",
	LeftShift = "Shift",
	RightShift = "Shift",
	Space = "Space",
	Escape = "Esc",
} :: { [string]: string })

-- Gamepad button names shown on glyph chips (Xbox naming; PlayStation maps by position).
InputConfig.ButtonLabels = table.freeze({
	ButtonA = "A",
	ButtonB = "B",
	ButtonX = "X",
	ButtonY = "Y",
	ButtonL1 = "LB",
	ButtonR1 = "RB",
	ButtonL2 = "LT",
	ButtonR2 = "RT",
	DPadLeft = "◀",
	DPadRight = "▶",
	DPadUp = "▲",
	DPadDown = "▼",
	ButtonSelect = "View",
	ButtonStart = "Menu",
} :: { [string]: string })

-- Gamepad colours per face button (glyph chip fill), Xbox convention.
InputConfig.ButtonColors = table.freeze({
	ButtonA = Color3.fromRGB(96, 186, 60),
	ButtonB = Color3.fromRGB(220, 58, 64),
	ButtonX = Color3.fromRGB(52, 120, 230),
	ButtonY = Color3.fromRGB(240, 190, 30),
} :: { [string]: Color3 })

return table.freeze(InputConfig)
