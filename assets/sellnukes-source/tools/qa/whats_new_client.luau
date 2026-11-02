--!nocheck
--[[
	whats_new_client.luau — client-VM probe for the WHAT'S NEW system (owner R58;
	ChangeNotes/ChangeNotesClient, UI/Screens/WhatsNew, UI/Hud/HudWhatsNew), run by
	tools/qa/whats_new.py through eval_client_runtime during ONE solo playtest.

		COMMAND  "diag"          loading / HUD / ChangeNotesClient state, the open modal, the
		                         chip's rect + NEW badge, the published Right zone, the panel's cards
		         "close_modals"  closes every open window (Welcome Back, tutorial card, ...)
		         "close_panel"   closes the WHAT'S NEW panel like the red X / B would
		         "open_menu"     presses the HUD chip (ChangeNotesClient.openMenu)
	Presentation only: the only intents sent are the normal player ones (ChangeNotesAction).
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local COMMAND = "__COMMAND__"

local client = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local ChangeNotesClient = require(client.ChangeNotes.ChangeNotesClient)
local HudZones = require(client.UI.Widgets.HudZones)
local LoadingGate = require(client.UI.Widgets.LoadingGate)
local ScreenManager = require(client.UI.ScreenManager)

local PANEL = "WhatsNew"

-- The chip's on-screen rect + badge state (nil before the HUD built it).
local function chip()
	local gui = ScreenManager.getGui("Hud")
	local holder = gui and gui:FindFirstChild("WhatsNewChip", true)
	if holder == nil then
		return nil
	end
	local badge = holder:FindFirstChild("NewBadge")
	local button = holder:FindFirstChild("WhatsNewButton")
	local up = button and button.NextSelectionUp
	return {
		navUp = up and up.Name or nil, -- D-pad Up goes back to the last offer (HudOffers downExit)
		navUpDownIsChip = up ~= nil and up.NextSelectionDown == button,
		visible = holder.Visible,
		x = holder.AbsolutePosition.X,
		y = holder.AbsolutePosition.Y,
		w = holder.AbsoluteSize.X,
		h = holder.AbsoluteSize.Y,
		badge = badge ~= nil and badge.Visible,
		viewport = workspace.CurrentCamera.ViewportSize.X .. "x" .. workspace.CurrentCamera.ViewportSize.Y,
	}
end

-- The open panel's cards: count, NEW / SOON ribbons, CTA buttons.
local function panel()
	local gui = ScreenManager.getGui(PANEL)
	if gui == nil or not ScreenManager.isOpen(PANEL) then
		return nil
	end
	local cards, ribbons = 0, 0
	for _, descendant in gui:GetDescendants() do
		if string.sub(descendant.Name, 1, 5) == "Note_" and descendant:IsA("Frame") then
			cards += 1
		elseif descendant.Name == "Ribbon" then
			ribbons += 1
		end
	end
	return { cards = cards, ribbons = ribbons }
end

if COMMAND == "diag" then
	local hud = ScreenManager.getGui("Hud")
	local state = ChangeNotesClient.testState()
	return HttpService:JSONEncode({
		loadingDone = LoadingGate.isDone(),
		hud = hud ~= nil and hud.Enabled,
		notes = state,
		open = ScreenManager.isOpen(PANEL),
		top = ScreenManager.topModalName(),
		chip = chip(),
		right = HudZones.rect("Right"),
		panel = panel(),
	})
elseif COMMAND == "close_modals" then
	ScreenManager.closeAllModals()
	return "closed"
elseif COMMAND == "close_panel" then
	ScreenManager.close(PANEL)
	return "closed"
elseif COMMAND == "open_menu" then
	ChangeNotesClient.openMenu()
	return "opened"
end
return "unknown command"
