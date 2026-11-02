--!nocheck
--[[
	gifts_client.luau — client-VM probe for the owner R89 Early Gift Ladder, Pocket Rocket HUD offer
	and favorite prompt (G-gifts), run by tools/qa/gifts.py through eval_client_runtime during ONE
	solo playtest.

		COMMAND  "diag"      HUD shown, profile loaded, top modal
		         "open"      closes every modal, opens TimeRewards (source "qa"); returns probe()
		         "closeall"  closes every modal (join pop-ups); returns the top modal + queued items
		         "close"     closes TimeRewards; returns probe()
		         "probe"     probe(): window open, layout mode (grid / row = scrolling), 10 cards with
		                     title / detail / button state, ready glows, CLAIM ALL text + state,
		                     toolbar lines, the gamepad default selection, button rects (44 pt check
		                     happens in the runner per device)
		         "point"     viewport centre of CLAIM ALL (the runner clicks it: the real button)
		         "gamepad"   the gamepad default selection of the open window (Gamepad mode for one
		                     ScreenManager refresh, then restored)
		         "hud"       the Pocket Rocket starburst: present, visible, label, icon, slot rect
		         "favorite"  FavoriteClient.debugState() + JoinFlow quiet / guided + tutorial step
	Presentation only: every claim / purchase goes through the server.
]]

local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }
local _ = ARGS

local LOCAL = Players.LocalPlayer
local client = LOCAL:WaitForChild("PlayerScripts"):WaitForChild("Client")
local ClientState = require(client.ClientState)
local ScreenManager = require(client.UI.ScreenManager)

local function gui(name: string): ScreenGui?
	return ScreenManager.getGui(name)
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

-- The first visible non-empty TextLabel text under `node` (button labels, titles).
local function textOf(node: Instance?): string
	if node == nil then
		return ""
	end
	if node:IsA("TextLabel") and node.Visible then
		return node.Text
	end
	for _, child in node:GetDescendants() do
		if child:IsA("TextLabel") and child.Visible and child.Text ~= "" then
			return child.Text
		end
	end
	return ""
end

local function probe()
	local root = gui("TimeRewards")
	local grid = if root ~= nil then root:FindFirstChild("GiftGrid", true) else nil
	local cards = {}
	local ready = 0
	local host = if grid ~= nil then grid:FindFirstChild("Cards") else nil
	if host ~= nil then
		for index = 1, 12 do
			local card = host:FindFirstChild(`Gift{index}`)
			if card == nil then
				break
			end
			local claim = card:FindFirstChild("Claim", true)
			local glow = card:FindFirstChild("ReadyGlow")
			if glow ~= nil and glow.Visible then
				ready += 1
			end
			local title = card:FindFirstChild("Title", true)
			local titleText = if title ~= nil and title.Visible then title.Text else "(countdown)"
			if titleText == "(countdown)" then
				-- the live countdown label replaced the title
				for _, child in card:GetDescendants() do
					if child:IsA("TextLabel") and child.Visible and string.match(child.Text, "%d+:%d+") then
						titleText = child.Text
						break
					end
				end
			end
			local detail = card:FindFirstChild("Detail", true)
			table.insert(cards, {
				title = titleText,
				detail = if detail ~= nil then detail.Text else "",
				button = textOf(claim),
				buttonRect = rect(claim),
				glow = glow ~= nil and glow.Visible,
			})
		end
	end
	local toolbar = if grid ~= nil then grid:FindFirstChild("Toolbar") else nil
	local claimAll = if toolbar ~= nil then toolbar:FindFirstChild("ClaimAll") else nil
	local nextText = ""
	if toolbar ~= nil then
		for _, child in toolbar:GetChildren() do
			if child:IsA("TextLabel") and child.Visible and child.Name ~= "Opened" and child.Name ~= "Note" then
				nextText = child.Text
			end
		end
	end
	local selected = GuiService.SelectedObject
	return {
		open = ScreenManager.isOpen("TimeRewards"),
		mode = if host ~= nil and host.ScrollingEnabled then "row" else "grid",
		canvas = if host ~= nil then { math.floor(host.AbsoluteCanvasSize.X), math.floor(host.AbsoluteSize.X) } else nil,
		cards = cards,
		count = #cards,
		ready = ready,
		claimAll = textOf(claimAll),
		claimAllRect = rect(claimAll),
		opened = if toolbar ~= nil and toolbar:FindFirstChild("Opened") then toolbar.Opened.Text else "",
		note = if toolbar ~= nil and toolbar:FindFirstChild("Note") then toolbar.Note.Text else "",
		nextLine = nextText,
		selected = if selected ~= nil then selected:GetFullName() else "",
		timeRewards = ClientState.profile and ClientState.profile.timeRewards or nil,
	}
end

if COMMAND == "diag" then
	local hud = gui("Hud")
	return HttpService:JSONEncode({
		hud = hud ~= nil and hud.Enabled,
		profile = type(ClientState.profile) == "table",
		top = ScreenManager.topModalName() or "",
	})
elseif COMMAND == "open" then
	ScreenManager.closeAllModals()
	ScreenManager.open("TimeRewards", { source = "qa" })
	task.wait(1.0)
	return HttpService:JSONEncode(probe())
elseif COMMAND == "closeall" then
	-- Join pop-ups (Welcome Back, What's New) out of the way; reports what is still queued.
	ScreenManager.closeAllModals()
	task.wait(0.3)
	local joinFlow = require(client.Platform.JoinFlow)
	return HttpService:JSONEncode({ top = ScreenManager.topModalName() or "", pending = joinFlow.debugState().pending })
elseif COMMAND == "close" then
	ScreenManager.close("TimeRewards")
	task.wait(0.2)
	return HttpService:JSONEncode(probe())
elseif COMMAND == "probe" then
	return HttpService:JSONEncode(probe())
elseif COMMAND == "point" then
	-- Viewport centre of CLAIM ALL (the runner presses it with simulate_mouse_input: the REAL
	-- button path → the ClaimTimeRewardsAll intent).
	local root = gui("TimeRewards")
	local button = if root ~= nil then root:FindFirstChild("ClaimAll", true) else nil
	if button == nil then
		return "{}"
	end
	local inset = GuiService:GetGuiInset()
	local c = button.AbsolutePosition + button.AbsoluteSize / 2 + inset
	local viewport = workspace.CurrentCamera.ViewportSize
	return HttpService:JSONEncode({ x = math.floor(c.X), y = math.floor(c.Y), viewportX = math.floor(viewport.X) })
elseif COMMAND == "gamepad" then
	-- The gift card ("Gift4") a selected button sits in ("" = not in a card, e.g. CLAIM ALL).
	local function cardOf(node: Instance?): string
		while node ~= nil do
			if string.match(node.Name, "^Gift%d+$") then
				return node.Name
			end
			node = node.Parent
		end
		return ""
	end
	-- The gamepad default selection of the open window: switch the input mode to Gamepad for one
	-- refresh (ScreenManager applies the screen's defaultSelection), read it, restore everything.
	local InputController = require(client.Controllers.InputController)
	local previous = InputController.mode
	GuiService.SelectedObject = nil
	local ok, err = pcall(function()
		InputController.mode = "Gamepad"
		ScreenManager.refreshSelection()
	end)
	local selected = GuiService.SelectedObject
	pcall(function()
		InputController.mode = previous
	end)
	GuiService.SelectedObject = nil
	return HttpService:JSONEncode({
		ok = ok,
		err = if ok then nil else tostring(err),
		selected = if selected ~= nil then selected.Name else "",
		parent = if selected ~= nil and selected.Parent ~= nil then selected.Parent.Name else "",
		card = cardOf(selected),
	})
elseif COMMAND == "hud" then
	local hud = gui("Hud")
	local offer = if hud ~= nil then hud:FindFirstChild("Offer_Rocket", true) else nil
	local label = if offer ~= nil then offer:FindFirstChild("Label", true) else nil
	local gifts = ClientState.profile and ClientState.profile.gifts or nil
	return HttpService:JSONEncode({
		present = offer ~= nil,
		visible = offer ~= nil and offer.Visible,
		label = if label ~= nil then label.Text else "",
		rect = rect(offer),
		gifts = gifts,
	})
elseif COMMAND == "favorite" then
	local favorite = require(client.UI.Screens.TimeRewards.FavoriteClient)
	local joinFlow = require(client.Platform.JoinFlow)
	local tycoon = ClientState.profile and ClientState.profile.tycoon or nil
	return HttpService:JSONEncode({
		state = favorite.debugState(),
		quiet = joinFlow.isQuiet(),
		join = joinFlow.debugState(),
		tutorialStep = if tycoon ~= nil then tycoon.tutorialStep else nil,
		gifts = ClientState.profile and ClientState.profile.gifts or nil,
	})
end
return "unknown command"
