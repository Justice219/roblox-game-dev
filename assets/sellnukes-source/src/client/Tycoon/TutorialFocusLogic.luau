--!strict
--[[
	TutorialFocusLogic — WHAT the tutorial points at and highlights on each step, per device
	(owner R84: "it doesn't actually point to the GUI ... maybe highlighting the button that needs
	to be clicked on the GUI ... it wasn't very clear to me that X is what you were supposed to
	do to upgrade first"). Pure: no Instances. Unit-tested by tests/ftue-logic.luau.

	The server step kinds (Server/Tycoon/TutorialLogic) map to the control the player must use:

		kind     device          arrow points at               rings (pulsing)              glyph
		upgrade  any             billboard UPGRADE pill        UPGRADE pill                  X/Square, E+click, tap
		         Touch           (same)                        + the on-screen UPGRADE btn   tap hand
		click    Touch, TAP!     billboard make bar (CLICK)    TAP! + billboard make bar     tap hand
		         shown           (TAP! itself only while no board: it sits under the thumb-cluster
		                         layer, so a HUD arrow beside it would be hidden; R84 Studio QA)
		click    otherwise       billboard make bar (CLICK)    make bar                      RT/R2, F+click, tap
		pad      any             the pad itself (walk onto)    the pad's price button        none
		other    any             the target part               none                          none

	"world" = the server target part itself (pad trigger / producer anchor): used for pads (you
	walk onto them, so the arrow keeps pointing down at the pad) and as the fallback while the
	producer's billboard has not streamed in yet (no control to point at; the old behaviour).
	Pads get no glyph on purpose: the objective says "Walk onto the glowing pad", and a button
	glyph next to it would contradict the words (owner R84 §3: text and highlight agree).

	`sides` is the preferred arrow-side order around the pointed control (UI/Hud/PointerLogic):
	the UPGRADE pill is the bottom row of the billboard, so the arrow goes UNDER the board first;
	the make bar is the middle row, so the arrow comes from the LEFT / RIGHT (from below it would
	cross the UPGRADE pill and point at the wrong thing); touch buttons live in the thumb corner,
	so the arrow comes from ABOVE first.

	`glyphLabel` is the caption of the callout glyph; tests/ftue-logic.luau proves every
	objective line (Tycoon/TutorialText) names the same control, so words and glyph never
	disagree.

	Connects to: Tycoon/TutorialHighlight (resolves the controls, draws the rings and glyph),
	Tycoon/TutorialText (Keys, the objective lines), UI/Hud/PointerLogic (Side).

	Example:
		TutorialFocusLogic.focus("upgrade", "Gamepad", { billboard = true, touchProduce = false,
			touchInteract = false, padLabel = false })
		--> { point = "upgrade", rings = { "upgrade" }, glyph = "interact", sides = { "below", ... } }
]]

export type Mode = "KeyboardMouse" | "Gamepad" | "Touch"
-- A highlightable control: the billboard UPGRADE pill / make bar, the on-screen touch buttons,
-- the pad label's price button.
export type Control = "upgrade" | "make" | "touchProduce" | "touchInteract" | "padPrice"
-- What the arrow points at: a control, or the server target part itself.
export type Point = Control | "world"
-- The callout glyph next to the pointed control.
export type Glyph = "interact" | "produce" | "tap"
export type Side = "below" | "above" | "left" | "right"

-- What exists on the client right now (streamed in / shown).
export type Facts = {
	billboard: boolean, -- the target producer's own billboard exists
	touchProduce: boolean, -- the on-screen TAP! button is shown (Touch, near a manual producer)
	touchInteract: boolean, -- the on-screen UPGRADE button is shown (Touch, near a producer)
	padLabel: boolean, -- the target pad's label (with its price button) exists
}

export type Focus = {
	point: Point,
	rings: { Control },
	glyph: Glyph?,
	sides: { Side },
}

-- Button names for the callout caption (same shape as TutorialText.Keys).
export type Keys = {
	produceKey: string,
	producePad: string,
	produceTouch: string,
	interactKey: string,
	interactPad: string,
	interactTouch: string,
}

local TutorialFocusLogic = {}

-- Preferred arrow sides per pointed control (see the module header).
local UNDER_FIRST: { Side } = table.freeze({ "below", "left", "right", "above" }) :: { Side }
local BESIDE_FIRST: { Side } = table.freeze({ "left", "right", "above", "below" }) :: { Side }
local OVER_FIRST: { Side } = table.freeze({ "above", "left", "right", "below" }) :: { Side }

-- Normalises an untrusted mode string (anything unknown reads as keyboard + mouse).
local function modeOf(mode: string): Mode
	if mode == "Gamepad" or mode == "Touch" then
		return mode
	end
	return "KeyboardMouse"
end

--[[
	The focus for a tutorial step on the player's device.
	@param kind  server step kind: "pad" | "click" | "upgrade" (anything else: the target part)
	@param mode  InputController mode: "KeyboardMouse" | "Gamepad" | "Touch"
	@param facts what is streamed in / on screen right now
	@return Focus (fresh tables; callers may keep them)
]]
function TutorialFocusLogic.focus(kind: string, mode: string, facts: Facts): Focus
	local device = modeOf(mode)
	local touch = device == "Touch"
	if kind == "upgrade" then
		if not facts.billboard then
			return { point = "world", rings = {}, glyph = nil, sides = UNDER_FIRST }
		end
		local rings: { Control } = if touch and facts.touchInteract
			then { "upgrade", "touchInteract" }
			else { "upgrade" }
		return {
			point = "upgrade",
			rings = rings,
			glyph = if touch then "tap" else "interact",
			sides = UNDER_FIRST,
		}
	elseif kind == "click" then
		if touch and facts.touchProduce then
			-- Studio QA (R84 run 4): the TAP! button sits inside the thumb cluster (UPGRADE, x1,
			-- GEMS, jump) on a GUI layer ABOVE the HUD, so a HUD arrow beside it was drawn under
			-- the neighbouring buttons. The arrow + tap hand therefore point at the board's make
			-- bar (tappable too, drawn in the 3D view) and TAP! carries the pulsing ring; only
			-- without a board does the arrow fall back to TAP! itself.
			if facts.billboard then
				return { point = "make", rings = { "touchProduce", "make" }, glyph = "tap", sides = BESIDE_FIRST }
			end
			return { point = "touchProduce", rings = { "touchProduce" }, glyph = "tap", sides = OVER_FIRST }
		end
		if not facts.billboard then
			return { point = "world", rings = {}, glyph = nil, sides = BESIDE_FIRST }
		end
		return {
			point = "make",
			rings = { "make" },
			glyph = if touch then "tap" else "produce",
			sides = BESIDE_FIRST,
		}
	elseif kind == "pad" then
		return {
			point = "world",
			rings = if facts.padLabel then { "padPrice" } else {},
			glyph = nil,
			sides = UNDER_FIRST,
		}
	end
	return { point = "world", rings = {}, glyph = nil, sides = UNDER_FIRST }
end

--[[
	The caption of a callout glyph on the device ("X", "Square", "E", "RT", "F", "TAP").
	The drawn glyph is the engine button image / key cap for the same binding; this caption is
	its text twin (fallback chip, tests).
	@param glyph Glyph
	@param mode  InputController mode
	@param keys  button names (Tycoon/Tutorial.keys)
	Example: TutorialFocusLogic.glyphLabel("interact", "Gamepad", keys) --> "X"
]]
function TutorialFocusLogic.glyphLabel(glyph: Glyph, mode: string, keys: Keys): string
	if glyph == "tap" then
		return "TAP"
	end
	local device = modeOf(mode)
	if glyph == "interact" then
		return if device == "Gamepad" then keys.interactPad else keys.interactKey
	end
	return if device == "Gamepad" then keys.producePad else keys.produceKey
end

--[[
	True when `control` is one of the on-screen touch buttons (Platform/TouchButtons) rather than
	a control on a world billboard.
]]
function TutorialFocusLogic.isTouchControl(control: Point): boolean
	return control == "touchProduce" or control == "touchInteract"
end

--[[
	The Platform action behind a touch control ("Produce" / "Interact"), or nil.
	Example: TutorialFocusLogic.touchAction("touchProduce") --> "Produce"
]]
function TutorialFocusLogic.touchAction(control: Point): string?
	if control == "touchProduce" then
		return "Produce"
	elseif control == "touchInteract" then
		return "Interact"
	end
	return nil
end

return table.freeze(TutorialFocusLogic)
