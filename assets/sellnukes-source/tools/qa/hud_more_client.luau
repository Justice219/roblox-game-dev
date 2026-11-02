--!nocheck
--[[
	hud_more_client.luau — client-VM probe for the owner R110 HUD MORE flyout (U-hud), run by
	tools/qa/hud_more.py through eval_client_runtime during ONE solo playtest.

		COMMAND  "diag"      HUD shown, profile loaded, top modal, flyout open, menus hiding the HUD
		         "probe"     probe(): stack tiles (names / rects), MORE badge + NEW, the flyout panel
		                     and items (visible / rect / badge / NEW), the B binding, the gamepad
		                     selection, HudZones "Left"
		         "point"     viewport centre of a HUD target for simulate_mouse_input (a REAL press):
		                     ARGS[1] 1 = Hud_More, 2 = Hud_Teleport (flyout), 3 = an empty spot of
		                     the play view (centre-right, between the HUD columns)
		         "open"      Hud.setMoreOpen(true) (API path); returns probe()
		         "close"     Hud.setMoreOpen(false); returns probe()
		         "rollup"    presentation-only badges on keys no live system drives: Rebirth "2" +
		                     Settings NEW (so restoring is exact); returns probe()
		         "unrollup"  clears those two; returns probe()
		         "gamepad"   forced Gamepad mode: cursor on MORE, open with focus (first item
		                     selected?), then the REAL B binding through ContextActionService
		                     :CallFunction (closed + cursor back on MORE?); forced mode cleared
		         "modal"     open the flyout, then ScreenManager.open("Shop"): the flyout must close
		                     (and the R79 MenuLayer hide); closes the Shop again
		         "closeall"  ScreenManager.closeAllModals(); returns probe()
	Presentation only: nothing here grants, buys or changes server state.
]]

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }

local BACK_ACTION = "SellNukes_HudMoreBack"
local STACK = { "Shop", "Pets", "Quests", "Rewards", "Attack", "More" }
local FLYOUT = { "Teleport", "Rebirth", "Event", "Settings" }

local LOCAL = Players.LocalPlayer
local client = LOCAL:WaitForChild("PlayerScripts"):WaitForChild("Client")
local ClientState = require(client.ClientState)
local Hud = require(client.UI.Hud.Hud)
local HudZones = require(client.UI.Widgets.HudZones)
local InputController = require(client.Controllers.InputController)
local ScreenManager = require(client.UI.ScreenManager)

local function hudFind(name: string): Instance?
	local gui = ScreenManager.getGui("Hud")
	return if gui ~= nil then gui:FindFirstChild(name, true) else nil
end

-- Drawn = every GuiObject ancestor visible and the ScreenGui enabled.
local function shown(node: Instance?): boolean
	local current = node
	while current ~= nil do
		if current:IsA("GuiObject") and not current.Visible then
			return false
		end
		if current:IsA("ScreenGui") then
			return current.Enabled
		end
		current = current.Parent
	end
	return false
end

local function rect(node: Instance?): { number }?
	if node == nil or not node:IsA("GuiObject") then
		return nil
	end
	return {
		math.floor(node.AbsolutePosition.X),
		math.floor(node.AbsolutePosition.Y),
		math.floor(node.AbsoluteSize.X),
		math.floor(node.AbsoluteSize.Y),
	}
end

local function tile(name: string)
	local node = hudFind(`Hud_{name}`)
	local badge = if node ~= nil then node:FindFirstChild("Badge") else nil
	local badgeText = if badge ~= nil then badge:FindFirstChild("BadgeText", true) else nil
	local newTag = if node ~= nil then node:FindFirstChild("NewTag") else nil
	return {
		exists = node ~= nil,
		shown = shown(node),
		rect = rect(node),
		badge = if badge ~= nil and badge.Visible then (if badgeText ~= nil then badgeText.Text else "?") else "",
		new = newTag ~= nil and newTag.Visible,
	}
end

local function probe()
	local stack = {}
	local stackShown = 0
	for _, name in STACK do
		local entry = tile(name)
		stack[name] = entry
		if entry.shown then
			stackShown += 1
		end
	end
	local items = {}
	for _, name in FLYOUT do
		items[name] = tile(name)
	end
	local panel = hudFind("HudMore")
	local backInfo = ContextActionService:GetBoundActionInfo(BACK_ACTION)
	local selected = GuiService.SelectedObject
	return {
		moreOpen = Hud.moreOpen(),
		menuHidden = Hud.menuHidden(),
		top = ScreenManager.topModalName() or "",
		stackShown = stackShown,
		stack = stack,
		panelShown = shown(panel),
		panel = rect(panel),
		items = items,
		backBound = backInfo ~= nil and next(backInfo) ~= nil,
		backPriority = if backInfo ~= nil then backInfo.priorityLevel else nil,
		selected = if selected ~= nil then selected.Name else "",
		inputMode = InputController.mode,
		leftZone = HudZones.rect("Left"),
	}
end

local function encode(value: any): string
	return HttpService:JSONEncode(value)
end

if COMMAND == "diag" then
	local hud = ScreenManager.getGui("Hud")
	return encode({
		hud = hud ~= nil and hud.Enabled,
		profile = type(ClientState.profile) == "table",
		top = ScreenManager.topModalName() or "",
		moreOpen = Hud.moreOpen(),
		menuHidden = Hud.menuHidden(),
	})
elseif COMMAND == "probe" then
	return encode(probe())
elseif COMMAND == "point" then
	local which = ARGS[1] or 1
	local viewport = Workspace.CurrentCamera.ViewportSize
	local c: Vector2
	if which == 3 then
		-- An empty spot of the play view: centre-right, below the currency stack.
		c = Vector2.new(viewport.X * 0.62, viewport.Y * 0.45)
	else
		local node = hudFind(if which == 2 then "Hud_Teleport" else "Hud_More")
		if node == nil then
			return "{}"
		end
		-- simulate_mouse_input counts from the top of the viewport; AbsolutePosition starts under
		-- the top bar inset (same correction as tools/qa/lucky_wheel_client.luau).
		c = node.AbsolutePosition + node.AbsoluteSize / 2 + GuiService:GetGuiInset()
	end
	return encode({ x = math.floor(c.X), y = math.floor(c.Y), viewportX = math.floor(viewport.X) })
elseif COMMAND == "open" then
	ScreenManager.closeAllModals()
	task.wait(0.4)
	Hud.setMoreOpen(true, false)
	task.wait(0.3)
	return encode(probe())
elseif COMMAND == "close" then
	Hud.setMoreOpen(false, false)
	task.wait(0.1)
	return encode(probe())
elseif COMMAND == "rollup" then
	Hud.setButtonBadge("Rebirth", "2")
	Hud.setButtonNew("Settings", true)
	task.wait(0.1)
	return encode(probe())
elseif COMMAND == "unrollup" then
	Hud.setButtonBadge("Rebirth", nil)
	Hud.setButtonNew("Settings", false)
	task.wait(0.1)
	return encode(probe())
elseif COMMAND == "gamepad" then
	local record = {}
	ScreenManager.closeAllModals()
	Hud.setMoreOpen(false, false)
	InputController.setForcedMode("Gamepad")
	task.wait(0.3)
	GuiService.SelectedObject = hudFind("Hud_More")
	Hud.setMoreOpen(true, true)
	task.wait(0.3)
	record.opened = probe()
	-- The REAL B binding (the function ContextActionService would call on ButtonB).
	local ok, err = pcall(function()
		ContextActionService:CallFunction(BACK_ACTION, Enum.UserInputState.Begin, nil)
	end)
	record.backCall = if ok then "ok" else tostring(err)
	task.wait(0.2)
	record.afterBack = probe()
	-- HudFocus (D-pad left) while open lands on the first item.
	Hud.setMoreOpen(true, true)
	task.wait(0.2)
	GuiService.SelectedObject = nil
	Hud.focusButtons()
	task.wait(0.1)
	record.focusWhileOpen = probe().selected
	Hud.setMoreOpen(false, false)
	GuiService.SelectedObject = nil
	InputController.setForcedMode(nil)
	task.wait(0.2)
	record.after = probe()
	return encode(record)
elseif COMMAND == "modal" then
	local record = {}
	ScreenManager.closeAllModals()
	task.wait(0.4)
	Hud.setMoreOpen(true, false)
	task.wait(0.2)
	record.before = probe()
	ScreenManager.open("Shop")
	task.wait(0.8)
	record.withShop = probe()
	ScreenManager.closeAllModals()
	task.wait(0.8)
	record.after = probe()
	return encode(record)
elseif COMMAND == "closeall" then
	ScreenManager.closeAllModals()
	task.wait(0.6)
	return encode(probe())
end
return "unknown command"
