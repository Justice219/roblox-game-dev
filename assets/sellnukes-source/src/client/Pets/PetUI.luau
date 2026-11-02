--!strict
--[[
	PetUI — small UI helpers shared by the pets / eggs / crates screens.

	setButton(button, state, text)
		StudUI buttons only show a custom label for "locked" / "claimed" states (setState's text);
		"normal" / "disabled" always show the base text. This sets both consistently, so a screen
		can say setButton(hatch, "disabled", "NO EGGS") or setButton(hatch, "locked", "EVENT OVER").

	haptic(name)
		B16's Platform/Haptics.play (pad rumble / phone vibration) through a guarded lazy require,
		so a missing platform layer never breaks a reveal. Names: "Hatch", "Reward", "Error", ...

	Connects to: UI/Kit/StudUI, Client/Platform/Haptics (B16), UI/Screens/{Pets, EggHatch,
	CrateShop, CrateOpen}.

	Example:
		PetUI.setButton(button, if canBuy then "normal" else "disabled", "HATCH")
		PetUI.haptic("Hatch")
]]

local StudUI = require(script.Parent.Parent.UI.Kit.StudUI)

local PetUI = {}

--[[ Sets a StudUI button's state AND its label (see the header). ]]
function PetUI.setButton(button: StudUI.Button, state: string, text: string)
	if state == "normal" or state == "disabled" then
		button.setText(text)
		button.setState(state :: any)
	else
		button.setState(state :: any, text)
	end
end

-- Platform/Haptics, resolved once (false = unavailable).
local haptics: any = nil

--[[ Plays a B16 haptic preset (no-op when the platform layer is missing). ]]
function PetUI.haptic(name: string)
	if haptics == nil then
		local platform = script.Parent.Parent:FindFirstChild("Platform")
		local module = if platform ~= nil then platform:FindFirstChild("Haptics") else nil
		local ok, result = false, nil
		if module ~= nil and module:IsA("ModuleScript") then
			ok, result = pcall(require, module)
		end
		haptics = if ok and type(result) == "table" and type(result.play) == "function" then result else false
	end
	if haptics ~= false then
		pcall(haptics.play, name)
	end
end

return table.freeze(PetUI)
