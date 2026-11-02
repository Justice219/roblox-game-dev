--!nocheck
--[[
	quests_client.luau — client-VM probe for R78 Quests, run by tools/qa/quests.py through
	eval_client_runtime during ONE solo playtest.

		COMMAND  "diag"       HUD shown, profile loaded (quests field), Quests HUD badge text
		         "close_all"  closes every modal (Welcome Back etc.)
		         "open"       ScreenManager.open("Quests", { tab = ARGS[1]: 1 goals / 2 daily /
		                      3 trophies }); returns state()
		         "state"      state(): open, tab colours, visible row titles + button texts, tab
		                      badges, banner texts, HUD badge, the objective chip text / bar
		         "chip"       the objective chip: visible, text, counter, bar, tap target
		         "point"      viewport centre of the first visible CLAIM button (simulate_mouse_input)
		         "pad_on" / "pad_off" / "reopen"   forced Gamepad mode; reopen → SelectedObject name
	Presentation only: claims in the .py go through a real click or the server probe.
]]

local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }

local LOCAL = Players.LocalPlayer
local client = LOCAL:WaitForChild("PlayerScripts"):WaitForChild("Client")
local ClientState = require(client.ClientState)
local InputController = require(client.Controllers.InputController)
local ScreenManager = require(client.UI.ScreenManager)

local TABS = { "goals", "daily", "trophies" }

local function gui(): ScreenGui?
	return ScreenManager.getGui("Quests")
end

local function shown(node: Instance): boolean
	local current: Instance? = node
	while current ~= nil and not current:IsA("ScreenGui") do
		if current:IsA("GuiObject") and not current.Visible then
			return false
		end
		current = current.Parent
	end
	return current ~= nil and (current :: ScreenGui).Enabled
end

local function textOf(parent: Instance?, name: string): string
	local node = if parent ~= nil then parent:FindFirstChild(name, true) else nil
	return if node ~= nil and (node:IsA("TextLabel") or node:IsA("TextButton")) then node.Text else ""
end

local function hudBadge(): string
	local hud = ScreenManager.getGui("Hud")
	if hud == nil then
		return "?"
	end
	for _, node in hud:GetDescendants() do
		if node.Name == "Badge" and node:IsA("Frame") and node.Visible then
			local holder = node.Parent
			while holder ~= nil and holder ~= hud do
				if string.find(holder.Name, "Quests", 1, true) ~= nil then
					return textOf(node, "BadgeText")
				end
				holder = holder.Parent
			end
		end
	end
	return ""
end

local function chip(): { [string]: any }
	local hud = ScreenManager.getGui("Hud")
	local objective = if hud ~= nil then hud:FindFirstChild("Objective", true) else nil
	if objective == nil then
		return { found = false }
	end
	local bar = objective:FindFirstChild("ProgressBar")
	local fill = if bar ~= nil then bar:FindFirstChild("Fill") else nil
	local tap = objective:FindFirstChild("OpenQuests")
	return {
		found = true,
		visible = objective.Visible,
		text = textOf(objective, "Text"),
		counter = textOf(objective, "Counter"),
		bar = bar ~= nil and bar.Visible,
		fill = if fill ~= nil then math.floor(fill.Size.X.Scale * 100 + 0.5) else -1,
		tappable = tap ~= nil and tap.Visible,
		arrow = hud:FindFirstChild("TargetArrow", true) ~= nil and hud:FindFirstChild("TargetArrow", true).Visible,
	}
end

local function state(): { [string]: any }
	local root = gui()
	local rows = {}
	local tabs = {}
	local banner = {}
	if root ~= nil then
		for _, node in root:GetDescendants() do
			if node:IsA("Frame") and string.match(node.Name, "^Row%d+$") and shown(node) then
				table.insert(rows, {
					order = node.LayoutOrder,
					title = textOf(node, "Title"),
					detail = textOf(node, "Detail"),
					counter = textOf(node, "Counter"),
					action = textOf(node:FindFirstChild("Action"), "Label") ~= "" and textOf(node:FindFirstChild("Action"), "Label")
						or textOf(node, "Action"),
					swap = node:FindFirstChild("Swap") ~= nil and node:FindFirstChild("Swap").Visible,
				})
			elseif node:IsA("TextButton") and string.match(node.Name, "^Tab_") then
				local badge = node:FindFirstChild("Badge")
				table.insert(tabs, {
					name = node.Name,
					badge = if badge ~= nil and badge.Visible then textOf(badge, "BadgeText") else "",
				})
			end
		end
		local bannerFrame = root:FindFirstChild("PassBanner", true)
		if bannerFrame ~= nil then
			banner = {
				title = textOf(bannerFrame, "Title"),
				tier = textOf(bannerFrame, "Tier"),
				subtitle = textOf(bannerFrame, "Subtitle"),
				xp = textOf(bannerFrame, "Xp"),
				countdown = textOf(bannerFrame, "Countdown"),
				open = textOf(bannerFrame:FindFirstChild("OpenPass"), "Label"),
			}
		end
	end
	table.sort(rows, function(a, b)
		return a.order < b.order
	end)
	local list = if root ~= nil then root:FindFirstChild("List", true) else nil
	return {
		open = ScreenManager.isOpen("Quests"),
		top = ScreenManager.topModalName() or "",
		header = if list ~= nil then textOf(list:FindFirstChild("Header"), "Summary") else "",
		reset = if list ~= nil then textOf(list:FindFirstChild("Header"), "Countdown") else "",
		rows = rows,
		tabs = tabs,
		banner = banner,
		hudBadge = hudBadge(),
		chip = chip(),
	}
end

local function centre(node: GuiObject?): { [string]: number }
	if node == nil then
		return {}
	end
	local inset = GuiService:GetGuiInset()
	local camera = Workspace.CurrentCamera
	return {
		x = node.AbsolutePosition.X + node.AbsoluteSize.X / 2 + inset.X,
		y = node.AbsolutePosition.Y + node.AbsoluteSize.Y / 2 + inset.Y,
		viewportX = if camera ~= nil then camera.ViewportSize.X else 1,
	}
end

if COMMAND == "diag" then
	local hud = ScreenManager.getGui("Hud")
	local profile = ClientState.profile
	return HttpService:JSONEncode({
		hud = hud ~= nil and hud.Enabled,
		profile = type(profile) == "table" and type(profile.quests) == "table",
		top = ScreenManager.topModalName() or "",
		hudBadge = hudBadge(),
	})
elseif COMMAND == "close_all" then
	ScreenManager.closeAllModals()
	return "closed"
elseif COMMAND == "open" then
	local tab = TABS[math.clamp(math.floor(ARGS[1] or 1), 1, 3)]
	ScreenManager.open("Quests", { tab = tab, source = "other" })
	task.wait(0.7)
	return HttpService:JSONEncode(state())
elseif COMMAND == "state" then
	return HttpService:JSONEncode(state())
elseif COMMAND == "chip" then
	return HttpService:JSONEncode(chip())
elseif COMMAND == "point" then
	local root = gui()
	if root ~= nil then
		for _, node in root:GetDescendants() do
			if node:IsA("TextButton") and node.Name == "Action" and shown(node) and textOf(node, "Label") == "CLAIM" then
				return HttpService:JSONEncode(centre(node))
			end
		end
		for _, node in root:GetDescendants() do
			if node:IsA("TextButton") and node.Name == "Action" and shown(node) and node.Text == "CLAIM" then
				return HttpService:JSONEncode(centre(node))
			end
		end
	end
	return HttpService:JSONEncode({})
elseif COMMAND == "pad_on" then
	InputController.setForcedMode("Gamepad")
	return InputController.mode
elseif COMMAND == "pad_off" then
	InputController.setForcedMode(nil)
	return InputController.mode
elseif COMMAND == "reopen" then
	ScreenManager.close("Quests")
	task.wait(0.3)
	ScreenManager.open("Quests", { source = "other" })
	task.wait(0.7)
	local selected = GuiService.SelectedObject
	return HttpService:JSONEncode({
		selected = if selected ~= nil then selected.Name else "",
		label = if selected ~= nil then textOf(selected, "Label") else "",
	})
end
return "unknown command"
