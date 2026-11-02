--!nocheck
--[[
	rewards_hub_client.luau — client-VM probe for the Rewards hub (owner R62: UI/Screens/RewardsHub
	+ UI/RewardsBadges), run by tools/qa/rewards_hub.py through eval_client_runtime during ONE solo
	playtest.

		COMMAND  "diag"        loading / HUD readiness, top modal, hub registered, badge snapshot
		         "close_all"   closes every modal (Welcome Back etc.)
		         "open_hub"    ScreenManager.open("RewardsHub", { source = "hud" }) like the HUD button
		         "hub_state"   hub window shown?, top modal, every tile's badge / status text / size
		         "tile_point"  viewport pixel centre of tile ARGS[1] (for simulate_mouse_input)
		         "back"        ScreenManager.closeTopModal() — exactly what B / Back does
		         "pad_on"      forces the Gamepad input mode (default-selection checks)
		         "pad_off"     clears the forced mode
		         "selected"    GuiService.SelectedObject's name (nil → "")
		         "reopen"      closes + reopens the hub (fresh default selection)
		         "open_tile"   ScreenManager.open("RewardsHub", { open = <feature ARGS[1]> }) — the tile
		                       path (openFeature) when a simulated click does not land
	Presentation only: no intents are sent (opening a screen is local UI).
]]

local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }

local client = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local InputController = require(client.Controllers.InputController)
local RewardsBadges = require(client.UI.RewardsBadges)
local ScreenManager = require(client.UI.ScreenManager)

local HUB = "RewardsHub"

-- The hub's ScreenGui (built at boot: lazy = false).
local function hubGui(): ScreenGui?
	return ScreenManager.getGui(HUB)
end

-- Every tile button of the hub, in hub order.
local function tiles(): { TextButton }
	local list = {}
	local gui = hubGui()
	if gui == nil then
		return list
	end
	for _, id in { "Daily", "Time", "LuckyWheel", "Group", "Codes" } do
		local button = gui:FindFirstChild(`Open{id}`, true)
		if button ~= nil then
			table.insert(list, button)
		end
	end
	return list
end

local function snapshot(): { [string]: any }
	local snap = RewardsBadges.snapshot()
	local features = {}
	for id, state in snap.features do
		features[id] = { count = state.count, kind = state.kind, readyAt = state.readyAt }
	end
	return { total = snap.total, badge = RewardsBadges.badgeText() or "", features = features }
end

local function hubState(): { [string]: any }
	local gui = hubGui()
	local window = if gui ~= nil then gui:FindFirstChild(`{HUB}Window`, true) else nil
	local out = {
		open = ScreenManager.isOpen(HUB),
		top = ScreenManager.topModalName() or "",
		windowShown = window ~= nil and window.Visible,
		tiles = {},
	}
	for _, button in tiles() do
		local holder = button.Parent
		local badge = button:FindFirstChild("Badge")
		local status = holder and holder:FindFirstChild("StatusText", true)
		table.insert(out.tiles, {
			name = button.Name,
			badge = if badge ~= nil and badge.Visible then badge:FindFirstChild("BadgeText", true).Text else "",
			status = if status ~= nil then status.Text else "?",
			px = { math.floor(button.AbsoluteSize.X), math.floor(button.AbsoluteSize.Y) },
		})
	end
	return out
end

if COMMAND == "diag" then
	local hud = ScreenManager.getGui("Hud")
	return HttpService:JSONEncode({
		registered = ScreenManager.isRegistered(HUB),
		hud = hud ~= nil and hud.Enabled,
		top = ScreenManager.topModalName() or "",
		badges = snapshot(),
	})
elseif COMMAND == "close_all" then
	ScreenManager.closeAllModals()
	return "closed"
elseif COMMAND == "open_hub" then
	ScreenManager.open(HUB, { source = "hud" })
	task.wait(0.4)
	return HttpService:JSONEncode(hubState())
elseif COMMAND == "hub_state" then
	return HttpService:JSONEncode(hubState())
elseif COMMAND == "tile_point" then
	local button = tiles()[math.floor(ARGS[1] or 1)]
	if button == nil then
		return "{}"
	end
	local gui = hubGui()
	local inset = if gui ~= nil and gui.IgnoreGuiInset then Vector2.zero else GuiService:GetGuiInset()
	local centre = button.AbsolutePosition + button.AbsoluteSize / 2 + inset
	return HttpService:JSONEncode({ x = math.floor(centre.X), y = math.floor(centre.Y) })
elseif COMMAND == "back" then
	return tostring(ScreenManager.closeTopModal())
elseif COMMAND == "pad_on" then
	InputController.setForcedMode("Gamepad")
	return InputController.mode
elseif COMMAND == "pad_off" then
	InputController.setForcedMode(nil)
	return InputController.mode
elseif COMMAND == "selected" then
	local selected = GuiService.SelectedObject
	return if selected ~= nil then selected.Name else ""
elseif COMMAND == "open_tile" then
	local ids = { "Daily", "Time", "LuckyWheel", "Group", "Codes" }
	ScreenManager.open(HUB, { source = "hud", open = ids[math.floor(ARGS[1] or 1)] })
	task.wait(0.5)
	return HttpService:JSONEncode(hubState())
elseif COMMAND == "reopen" then
	ScreenManager.close(HUB)
	task.wait(0.2)
	ScreenManager.open(HUB, { source = "hud" })
	task.wait(0.4)
	local selected = GuiService.SelectedObject
	return if selected ~= nil then selected.Name else ""
end
return "unknown"
