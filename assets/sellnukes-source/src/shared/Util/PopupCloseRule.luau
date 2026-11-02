--!strict
--[[
	PopupCloseRule — the pure rule for "does this key press close the top pop-up?"
	(ported from RoBeasts, trimmed to SellNukes' single modal stack).

	Rules:
		1. Only the top-most modal handles a press, and one press closes exactly one thing
		   (ScreenManager.closeTopModal enforces this).
		2. A KEYBOARD close key (X, or the silent Backspace) never closes anything while a TextBox
		   has focus: those keys are letters / deletes while typing (Roblox chat, the Codes box,
		   the stand rename box).
		3. A press the engine already processed (gameProcessed) never closes anything.
		Gamepad B is never a typing key, so it always closes.

	Pure (no services): Lune-testable.

	Connects to: Shared/Config/InputConfig (CloseKeys), UI/ScreenManager (Back handler).

	Example:
		PopupCloseRule.blocked({ keyName = "X", typing = true, gameProcessed = false })       --> true
		PopupCloseRule.blocked({ keyName = "ButtonB", typing = true, gameProcessed = false }) --> false
]]

local InputConfig = require(script.Parent.Parent.Config.InputConfig)

export type Press = {
	keyName: string, -- Enum.KeyCode name of the press ("X", "ButtonB", ...)
	typing: boolean, -- a TextBox has focus right now
	gameProcessed: boolean, -- the engine already consumed the press
}

local PopupCloseRule = {}

-- The key every pop-up SHOWS ("X").
PopupCloseRule.ShownKey = InputConfig.CloseKey.Name

-- Set of keyboard close keys by name (built once).
local KEYBOARD_CLOSE: { [string]: boolean } = {}
for _, keyCode in InputConfig.CloseKeys do
	KEYBOARD_CLOSE[keyCode.Name] = true
end
table.freeze(KEYBOARD_CLOSE)

--[[
	True when `keyName` is a KEYBOARD close key (X, or the silent Backspace).
	@param keyName Enum.KeyCode name
	@return boolean
	Example: PopupCloseRule.isKeyboardClose("X") --> true; ("ButtonB") --> false
]]
function PopupCloseRule.isKeyboardClose(keyName: string): boolean
	return KEYBOARD_CLOSE[keyName] == true
end

--[[
	True when the press must not close anything at all (rules 2 and 3 above).
	@param press the close-key press
	@return boolean
]]
function PopupCloseRule.blocked(press: Press): boolean
	if press.gameProcessed then
		return true
	end
	return press.typing and PopupCloseRule.isKeyboardClose(press.keyName)
end

return table.freeze(PopupCloseRule)
