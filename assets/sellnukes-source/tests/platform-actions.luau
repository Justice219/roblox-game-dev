--!strict
--[[
	Platform action-map regressions (Shared/Config/PlatformConfig + Platform/ActionLogic). Run:
		lune run tests/platform-actions

	Proves on the shipped modules:
	  1. The action table is valid (ActionLogic.validate): every context name is known, every
	     action has a gamepad button (console first) and a keyboard key unless whitelisted, and
	     no two actions can be bound on the same key at the same priority.
	  2. The ActionName type list and the table agree (every exported name has a binding).
	  3. Context rules: menus unbind gameplay, keep UI actions; freeNav D-pad actions unbind while
	     a GUI object is selected; contexts are any-of; studioOnly actions only in Studio.
	  4. Priorities: Buy beats the default jump (Medium), Hatch beats Interact, Back (High) beats
	     every platform action.
	  5. Hints per device: keyboard / gamepad glyph keys, de-dup by text (A Buy over X Buy on a
	     pad), gamepad idle navigation hints after contextual ones, the MaxHints cap, nothing on
	     Touch, live text overrides.
	  6. Touch buttons: order, upper-cased live captions, one button per slot (Hatch takes the
	     Produce slot at an egg stand), minimum tap size ≥ 44 pt.
]]

local Loader = require("./fixtures/RobloxLoader")
local roblox = require("@lune/roblox")

-- The test script itself does not get the loader's Roblox globals.
local Enum = (roblox :: any).Enum

local loader = Loader.new()
local PlatformConfig = loader.load("src/shared/Config/PlatformConfig")
local ActionLogic = loader.load("src/client/Platform/ActionLogic")
local TouchUIConfig = loader.load("src/shared/Config/TouchUIConfig")

local checks = 0
local function eq(actual: any, expected: any, label: string)
	if actual ~= expected then
		error(`{label}: expected {tostring(expected)}, got {tostring(actual)}`, 2)
	end
	checks += 1
end
local function truthy(value: any, label: string)
	if not value then
		error(`{label}: expected truthy, got {tostring(value)}`, 2)
	end
	checks += 1
end

local Actions = PlatformConfig.Actions
local KeyCode = Enum.KeyCode

local function env(contexts: { [string]: boolean }?, menu: boolean?, selecting: boolean?, studio: boolean?): any
	return {
		studio = studio == true,
		menu = menu == true,
		selecting = selecting == true,
		contexts = contexts or {},
	}
end

-- 1. Validation.
local problems = ActionLogic.validate(Actions)
eq(#problems, 0, `validate: {table.concat(problems, "; ")}`)

-- 2. Every documented action exists (keep in sync with PlatformConfig.ActionName).
local NAMES = {
	"Interact",
	"Produce",
	"UpgradeMode",
	"Buy",
	"Hatch",
	"HudFocus",
	"OffersFocus",
	"Menu",
	"Teleport",
	"Attack",
	"Deselect",
	"TabPrev",
	"TabNext",
	"DevGallery",
	"GemUpgrade", -- owner R86
	"LobbyUse", -- owner R99: lobby fixtures (Lucky Wheel stage, group chest, codes board)
}
local count = 0
for _ in Actions do
	count += 1
end
eq(count, #NAMES, "action count matches the ActionName list")
for _, name in NAMES do
	truthy(Actions[name] ~= nil, `action {name} exists`)
	truthy(type(Actions[name].priority) == "number", `{name} has a priority`)
end
-- The InputController-compatible fields are present on every binding.
for name, binding in Actions do
	truthy(type(binding.keys) == "table" and type(binding.buttons) == "table", `{name} keys/buttons`)
	truthy(type(binding.whileBlocked) == "boolean", `{name} whileBlocked`)
	truthy(type(binding.label) == "string", `{name} label`)
end
-- Owner / spec bindings.
eq(Actions.Produce.buttons[1], KeyCode.ButtonR2, "Produce = R2")
eq(Actions.Produce.keys[1], KeyCode.F, "Produce = F")
eq(Actions.UpgradeMode.buttons[1], KeyCode.ButtonY, "UpgradeMode = Y")
eq(Actions.Buy.buttons[1], KeyCode.ButtonA, "Buy = A")
eq(Actions.HudFocus.buttons[1], KeyCode.DPadLeft, "HudFocus = D-pad left")
eq(Actions.Teleport.buttons[1], KeyCode.DPadUp, "Teleport = D-pad up")
eq(Actions.Menu.buttons[1], KeyCode.ButtonSelect, "Menu = View/Select")
-- Owner R86 gem upgrade: C / LB, only while a gem level can be bought, never inside a menu.
eq(Actions.GemUpgrade.keys[1], KeyCode.C, "GemUpgrade = C")
eq(Actions.GemUpgrade.buttons[1], KeyCode.ButtonL1, "GemUpgrade = LB")
eq(ActionLogic.isActive(Actions.GemUpgrade, env({ Producer = true })), false, "gem needs its own context")
eq(ActionLogic.isActive(Actions.GemUpgrade, env({ GemUpgrade = true })), true, "gem near a producer that can take one")
eq(ActionLogic.isActive(Actions.GemUpgrade, env({ GemUpgrade = true }, true)), false, "menu unbinds the gem upgrade")
truthy(Actions.GemUpgrade.priority ~= Actions.TabPrev.priority, "LB: gameplay gem vs menu TabPrev never share a priority")

-- 3. Context rules.
eq(ActionLogic.isActive(Actions.Produce, env()), false, "Produce needs a manual producer")
eq(ActionLogic.isActive(Actions.Produce, env({ ManualProducer = true })), true, "Produce near a manual producer")
eq(ActionLogic.isActive(Actions.Produce, env({ Producer = true })), false, "automated producer: no Produce")
eq(ActionLogic.isActive(Actions.Interact, env({ Pad = true })), true, "Interact on a pad (any-of)")
eq(ActionLogic.isActive(Actions.Interact, env({ Producer = true })), true, "Interact near a producer")
eq(ActionLogic.isActive(Actions.Buy, env({ Producer = true })), false, "Buy only on a pad")
eq(ActionLogic.isActive(Actions.Buy, env({ Pad = true })), true, "Buy on a pad")
eq(ActionLogic.isActive(Actions.Buy, env({ Pad = true }, true)), false, "menu unbinds Buy")
eq(ActionLogic.isActive(Actions.Buy, env({ Pad = true }, false, true)), false, "A presses the selected HUD button")
eq(ActionLogic.isActive(Actions.Produce, env({ ManualProducer = true }, true)), false, "menu unbinds Produce")
eq(ActionLogic.isActive(Actions.Menu, env(nil, true)), true, "Menu stays bound in menus")
eq(ActionLogic.isActive(Actions.TabNext, env({ Tabs = true }, true)), true, "tabs in a menu")
eq(ActionLogic.isActive(Actions.TabNext, env(nil, true)), false, "no tabs without a cycler")
eq(ActionLogic.isActive(Actions.HudFocus, env()), true, "D-pad left focuses the HUD")
eq(ActionLogic.isActive(Actions.HudFocus, env(nil, false, true)), false, "D-pad walks the selection")
eq(ActionLogic.isActive(Actions.Teleport, env(nil, false, true)), false, "Teleport freeNav")
eq(ActionLogic.isActive(Actions.Attack, env()), false, "Attack locked")
eq(ActionLogic.isActive(Actions.Attack, env({ AttackUnlocked = true })), true, "Attack after the launcher")
eq(ActionLogic.isActive(Actions.Deselect, env({ Selecting = true })), true, "B drops a HUD selection")
eq(ActionLogic.isActive(Actions.Deselect, env({ Selecting = true }, true)), false, "modal Back owns B in menus")
eq(ActionLogic.isActive(Actions.DevGallery, env()), false, "DevGallery live: never")
eq(ActionLogic.isActive(Actions.DevGallery, env(nil, false, false, true)), true, "DevGallery in Studio")
local set = ActionLogic.activeSet(Actions, env({ Producer = true, ManualProducer = true }))
truthy(set.Produce and set.Interact and set.UpgradeMode, "producer set")
eq(set.Buy, nil, "producer set has no Buy")

-- 4. Priorities.
local MEDIUM = Enum.ContextActionPriority.Medium.Value
local HIGH = Enum.ContextActionPriority.High.Value
truthy(Actions.Buy.priority > MEDIUM, "Buy beats the default jump binding")
truthy(Actions.Hatch.priority > Actions.Interact.priority, "Hatch beats Interact on E / X")
for name, binding in Actions do
	truthy(binding.priority < HIGH, `{name} stays below the modal Back`)
end

-- 5. Hints.
local producer = ActionLogic.activeSet(Actions, env({ Producer = true, ManualProducer = true }))
local kb = ActionLogic.hints(Actions, producer, "KeyboardMouse", {}, 4)
eq(#kb, 3, "keyboard producer hints: Produce, Upgrade, Amount (no idle hints)")
eq(kb[1].action, "Produce", "Produce first")
eq(kb[1].keyCodes[1], KeyCode.F, "keyboard glyph F")
eq(kb[2].text, "Upgrade", "default Interact text")
local pad = ActionLogic.hints(Actions, producer, "Gamepad", { Interact = "Upgrade x10" }, 4)
eq(pad[1].keyCodes[1], KeyCode.ButtonR2, "gamepad glyph RT")
eq(pad[2].text, "Upgrade x10", "live hint text")
eq(#pad, 4, "contextual + one idle hint within the cap")
eq(pad[4].action, "HudFocus", "idle hint after contextual ones")
local idle = ActionLogic.hints(Actions, ActionLogic.activeSet(Actions, env()), "Gamepad", {}, 4)
eq(#idle, 2, "gamepad idle: Menus + Quick menu")
eq(#ActionLogic.hints(Actions, ActionLogic.activeSet(Actions, env()), "KeyboardMouse", {}, 4), 0, "no idle KB hints")
eq(#ActionLogic.hints(Actions, producer, "Touch", {}, 4), 0, "no hints on touch")
local onPad = ActionLogic.activeSet(Actions, env({ Pad = true }))
local padHints = ActionLogic.hints(Actions, onPad, "Gamepad", { Interact = "Buy" }, 4)
eq(padHints[1].action, "Buy", "gamepad on a pad: A Buy first")
for _, hint in padHints do
	truthy(hint.action ~= "Interact", "X Buy de-duplicated against A Buy")
end
local kbPad = ActionLogic.hints(Actions, onPad, "KeyboardMouse", { Interact = "Buy $10" }, 4)
eq(kbPad[1].action, "Interact", "keyboard buys with E")
eq(kbPad[1].text, "Buy $10", "keyboard buy text")
eq(#ActionLogic.hints(Actions, producer, "Gamepad", {}, 2), 2, "MaxHints cap")

-- 6. Touch buttons.
local touch = ActionLogic.touchButtons(Actions, producer, { UpgradeMode = "x10" })
eq(#touch, 3, "producer touch buttons")
eq(touch[1].action, "Produce", "TAP! nearest the jump button")
eq(touch[1].label, "TAP!", "default caption")
eq(touch[3].label, "X10", "live caption upper-cased")
local egg = ActionLogic.activeSet(Actions, env({ Egg = true, ManualProducer = true }))
local eggTouch = ActionLogic.touchButtons(Actions, egg, {})
eq(eggTouch[1].action, "Hatch", "Hatch takes slot 1 over Produce")
eq(#eggTouch, 1, "one button per slot")
eq(
	#ActionLogic.touchButtons(Actions, ActionLogic.activeSet(Actions, env({ Pad = true })), {}),
	1,
	"pad: BUY via Interact"
)
for size, points in PlatformConfig.Touch.Sizes do
	truthy(points >= TouchUIConfig.MinTapPoints, `touch size {size} ≥ 44 pt`)
end

print(`[platform-actions] {checks} checks passed`)
