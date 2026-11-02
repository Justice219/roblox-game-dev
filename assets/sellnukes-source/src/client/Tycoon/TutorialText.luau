--!strict
--[[
	TutorialText — the tutorial's words for the device in the player's hands (owner R78 §6, R11
	"correct button-hint glyphs"). Pure: no Instances, unit-tested by tests/ftue-logic.luau.

	Why: the server's objective lines were written for a mouse ("Click your Workbench to make
	Pocket Nukes!", "Press UPGRADE ..."). On a console that is a riddle (there is no cursor: the
	producer is run with RT / R2 and upgraded with X / Square) and on a phone the button is the
	big TAP! button, not a click. The 2026-10-31 data had 15 of 25 players on touch and 8 on a
	gamepad, so every line names the real control:
		KeyboardMouse  "Press F or click your Workbench to make nukes!"
		               "Press E or click UPGRADE on your Workbench!"
		Gamepad        "Press RT at your Workbench to make nukes!"   (R2 on a PlayStation)
		               "Press X to UPGRADE your Workbench!"          (Square on a PlayStation)
		Touch          "Tap TAP! at your Workbench to make nukes!"
		               "Tap UPGRADE on your Workbench!"
	Owner R84: each line names the SAME control the tutorial highlight rings and shows as the
	callout glyph (Tycoon/TutorialFocusLogic.glyphLabel; tests/ftue-logic.luau proves it).
	The button names come from Shared/Config/PlatformConfig (the same bindings the hint bar and
	touch buttons use) through `Keys`, resolved by the caller (Tycoon/Tutorial: GlyphFamily for
	the Xbox / PlayStation label, InputGlyph for keyboard keys), so text and glyphs never disagree.

	Steps (Server/Tycoon/TutorialLogic kinds):
		pad      step 1 (the free Workbench): "Walk onto the glowing pad to build your Workbench!"
		         later pads: the server's own line (device-neutral: you walk onto pads everywhere)
		click    run the producer once (Produce action)
		upgrade  buy a producer level (Interact action)
	The intro coach card (Screens/TycoonTutorial) uses `coach(index, ...)` for its three tiles,
	in the SAME order the tutorial really runs (pad → make nukes → upgrade); the old card said
	"1. Click the Workbench" while the first real step was the pad.

	Connects to: Tycoon/Tutorial (objective chip), Screens/TycoonTutorial (coach tiles),
	tests/ftue-logic.luau.

	Example:
		TutorialText.objective("click", "Workbench", 2, nil, "Gamepad", keys)
		--> "Press RT at your Workbench to make nukes!"
]]

export type Mode = "KeyboardMouse" | "Gamepad" | "Touch"

-- Button names for the two tutorial actions on each device (display strings).
export type Keys = {
	produceKey: string, -- keyboard key of Produce ("F")
	producePad: string, -- gamepad label of Produce ("RT" / "R2")
	produceTouch: string, -- touch button caption of Produce ("TAP!")
	interactKey: string, -- keyboard key of Interact ("E")
	interactPad: string, -- gamepad label of Interact ("X" / "Square")
	interactTouch: string, -- touch button caption of Interact ("UPGRADE")
}

local TutorialText = {}

-- Normalises an untrusted mode string (anything unknown reads as keyboard + mouse).
local function modeOf(mode: string): Mode
	if mode == "Gamepad" or mode == "Touch" then
		return mode
	end
	return "KeyboardMouse"
end

--[[
	The objective line for a tutorial step on the player's device.
	@param kind       server step kind: "pad" | "click" | "upgrade" (anything else → serverText)
	@param name       display name of the target (pad name, or the producer's short name)
	@param step       server tutorial step number (1 = the free Workbench pad)
	@param serverText the server's line (fallback; device-neutral pad lines are kept)
	@param mode       InputController mode: "KeyboardMouse" | "Gamepad" | "Touch"
	@param keys       button names (see Keys)
	@return the line for the HUD objective chip
]]
function TutorialText.objective(
	kind: string,
	name: string,
	step: number,
	serverText: string?,
	mode: string,
	keys: Keys
): string
	local device = modeOf(mode)
	if kind == "pad" then
		if step == 1 then
			return `Walk onto the glowing pad to build your {name}!`
		end
		return serverText or `Walk onto the {name} pad to buy it!`
	elseif kind == "click" then
		-- Owner R84: the line leads with the control the highlight shows (the callout glyph
		-- beside the make bar / TAP! button: RT, F, a tap hand).
		if device == "Gamepad" then
			return `Press {keys.producePad} at your {name} to make nukes!`
		elseif device == "Touch" then
			return `Tap {keys.produceTouch} at your {name} to make nukes!`
		end
		return `Press {keys.produceKey} or click your {name} to make nukes!`
	elseif kind == "upgrade" then
		-- Owner R84 ("it wasn't very clear to me that X is what you were supposed to do to
		-- upgrade"): name the button AND the highlighted UPGRADE pill it presses.
		if device == "Gamepad" then
			return `Press {keys.interactPad} to UPGRADE your {name}!`
		elseif device == "Touch" then
			return `Tap {keys.interactTouch} on your {name}!`
		end
		return `Press {keys.interactKey} or click UPGRADE on your {name}!`
	end
	return serverText or "Follow the arrows!"
end

--[[
	The coach card's tile `index` (1..3), in the order the tutorial really runs.
	@param index 1 = pads, 2 = make nukes, 3 = upgrade + managers
	@param mode  InputController mode
	@param keys  button names
	@return the tile caption ("" for an unknown index)
	Captions stay short (two lines of a compact tile on a phone).
	Example: TutorialText.coach(2, "Touch", keys) --> "Tap TAP! to make nukes"
]]
function TutorialText.coach(index: number, mode: string, keys: Keys): string
	local device = modeOf(mode)
	if index == 1 then
		return "Walk onto glowing pads"
	elseif index == 2 then
		if device == "Gamepad" then
			return `Press {keys.producePad} to make nukes`
		elseif device == "Touch" then
			return `Tap {keys.produceTouch} to make nukes`
		end
		return `Click or press {keys.produceKey} for nukes`
	elseif index == 3 then
		return "Upgrade & hire managers"
	end
	return ""
end

--[[
	The short name of a producer for tutorial lines: the name of the pad that builds it
	("Workbench") when there is one, else its full name ("Pocket Nuke Workbench").
	@param producerName the producer's display name
	@param builtByName  the display name of its `builtBy` pad, or nil
]]
function TutorialText.shortName(producerName: string, builtByName: string?): string
	if builtByName ~= nil and #builtByName > 0 then
		return builtByName
	end
	return producerName
end

return table.freeze(TutorialText)
