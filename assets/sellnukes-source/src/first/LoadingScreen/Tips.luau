--!strict
--[[
	Tips — the kid-friendly loading tips, worded for the player's device.

	Purpose:
		While the game loads, a tip card rotates through short how-to-play lines. The action verb
		matches how the player plays (UserInputService.PreferredInput, with a fallback for older
		clients): "Tap" on touch, "Click" on keyboard + mouse, "Press" + the button name on a
		gamepad, so a console player never reads "click".

	Example:
		local device = Tips.device()
		local line = Tips.line(3, device) --> "Tap the Lucky Wheel every 20 minutes for a FREE spin!"
]]

local UserInputService = game:GetService("UserInputService")

export type Device = "Touch" | "Keyboard" | "Gamepad"

local Tips = {}

-- Seconds each tip stays before the next one slides in.
Tips.ROTATE_SECONDS = 4.5

-- {verb} is replaced by the device's action word ("Tap" / "Click" / "Press A on").
local LINES: { string } = {
	"Step on the green pads to build your nuke business!",
	"Hire a manager and your nukes keep selling while you're away!",
	"{verb} the Lucky Wheel every 20 minutes for a FREE spin!",
	"Pets give you bonus cash. Hatch eggs in the hub!",
	"Come back every day: your daily reward streak grows!",
	"Rebirth to start over with a permanent cash boost!",
	"Attack mode sends confetti nukes. Nobody ever loses anything!",
	"{verb} Teleport to jump to any area you have unlocked!",
	"Every purchase flies in and builds itself, watch!",
}

--[[
	The player's main input device (PreferredInput when available, else inferred).
	@return "Touch" | "Keyboard" | "Gamepad"
]]
function Tips.device(): Device
	local ok, preferred = pcall(function()
		return (UserInputService :: any).PreferredInput
	end)
	if ok and preferred ~= nil then
		if preferred == (Enum :: any).PreferredInput.Touch then
			return "Touch"
		elseif preferred == (Enum :: any).PreferredInput.Gamepad then
			return "Gamepad"
		end
		return "Keyboard"
	end
	if UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		return "Gamepad"
	end
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "Touch"
	end
	return "Keyboard"
end

--[[ The device's action verb for "{verb}". ]]
function Tips.verb(device: Device): string
	if device == "Touch" then
		return "Tap"
	elseif device == "Gamepad" then
		return "Select"
	end
	return "Click"
end

--[[ Number of tips. ]]
function Tips.count(): number
	return #LINES
end

--[[
	Tip `index` (wraps) worded for `device`.
	@param index  1-based, any integer (wraps around)
	@return the tip text
]]
function Tips.line(index: number, device: Device): string
	local line = LINES[((index - 1) % #LINES) + 1]
	return (string.gsub(line, "{verb}", Tips.verb(device)))
end

return Tips
