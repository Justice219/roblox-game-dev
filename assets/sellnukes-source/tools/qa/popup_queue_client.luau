--!nocheck
--[[
	popup_queue_client.luau — client-VM probe for the owner R102 popup priority queue (Q-queue), run
	by tools/qa/popup_queue.py through eval_client_runtime during ONE solo playtest.

		COMMAND  "diag"         HUD shown, profile loaded, tutorial step, top modal, queue stats
		         "closeall"     closes every window (Welcome Back, What's New, ...)
		         "reveal"       FlavorController.preview(Galaxy) → the first-find card (forced) through
		                        the queue, then Studio DebugHold keeps it up for captures
		         "release"      clears DebugHold and closes the reveal (the queue frees the lane)
		         "luckytoast"   Hud.notify("reward", "LUCKY BUTTON!") — the R102 screenshot toast
		         "flavortoast"  the long new-Lucky-Nuke toast (wraps in the feed)
		         "goals"        three "Goal claimed! +10 Gems" toasts (R111: one "x3 +30 Gems" pill)
		         "bigpop"       four other-player Big Pop broadcasts (R120: ONE pill, the rest wait)
		         "pills"        three Galaxy Lucky Nukes (R120: one merged pill, nothing centre)
		         "quests"       opens the Quests window + a goal toast (R111: never over the window)
		         "juice"        JuiceBanner.show(milestone, ARGS[1] or 30) — kind "juice"
		         "happy"        JuiceBanner.show(Happy Hour start, ARGS[1] or 30, "happyHour")
		         "probe"        PopupQueue.stats(), Toasts.stats(), absolute rects of every popup /
		                        feed pill / HUD piece / the open window and the list of overlapping
		                        pairs (must be empty), the reveal card in the bottom-left corner,
		                        Lucky arrow + Happy pill visibility, YOU marker state vs the stack
	Presentation only: no server call, no currency (owner R102 + R108 + R111).
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }

local LOCAL = Players.LocalPlayer
local client = LOCAL:WaitForChild("PlayerScripts"):WaitForChild("Client")
local ClientState = require(client.ClientState)
local ScreenManager = require(client.UI.ScreenManager)
local Hud = require(client.UI.Hud.Hud)
local HudCurrency = require(client.UI.Hud.HudCurrency)
local HudZones = require(client.UI.Widgets.HudZones)
local PopupQueue = require(client.UI.Widgets.PopupQueue)
local Toasts = require(client.UI.Hud.Toasts)
local FlavorController = require(client.Tycoon.FlavorController)
local Tutorial = require(client.Tycoon.Tutorial)
local BigPopBanner = require(client.Tycoon.Fx.BigPopBanner)
local JuiceBanner = require(client.Tycoon.Fx.JuiceBanner)
local FlavorConfig = require(game:GetService("ReplicatedStorage").Shared.Config.FlavorConfig)
local TycoonClientConfig = require(game:GetService("ReplicatedStorage").Shared.Config.TycoonClientConfig)

local function gui(name: string): ScreenGui?
	return ScreenManager.getGui(name)
end

-- { x, y, w, h } absolute px of a visible GuiObject inside an enabled gui (nil otherwise).
local function rect(node: Instance?): { number }?
	if node == nil or not node:IsA("GuiObject") or not node.Visible then
		return nil
	end
	local layer = node:FindFirstAncestorOfClass("ScreenGui")
	if layer ~= nil and not layer.Enabled then
		return nil
	end
	return {
		math.floor(node.AbsolutePosition.X),
		math.floor(node.AbsolutePosition.Y),
		math.floor(node.AbsoluteSize.X),
		math.floor(node.AbsoluteSize.Y),
	}
end

local function find(screen: string, name: string): Instance?
	local root = gui(screen)
	return if root ~= nil then root:FindFirstChild(name, true) else nil
end

local function overlaps(a: { number }, b: { number }): boolean
	return a[1] < b[1] + b[3] and b[1] < a[1] + a[3] and a[2] < b[2] + b[4] and b[2] < a[2] + a[4]
end

-- The HUD's design → absolute conversion (origin = the currency stack's container).
local function hudRect(zone: { x: number, y: number, w: number, h: number }?): { number }?
	local corner = HudCurrency.corner()
	local stack = if corner ~= nil then corner:FindFirstAncestor("Currency") else nil
	local container = if stack ~= nil then stack.Parent else nil
	if zone == nil or container == nil then
		return nil
	end
	local s = ScreenManager.scale
	local o = container.AbsolutePosition
	return { math.floor(o.X + zone.x * s), math.floor(o.Y + zone.y * s), math.floor(zone.w * s), math.floor(zone.h * s) }
end

local function probe()
	local pieces: { [string]: { number }? } = {}
	-- Centre-lane banners + the feed's reveal card.
	pieces.juice = rect(find("JuiceBanner", "Banner"))
	pieces.plotReveal = rect(find("PlotReveal", "Banner"))
	pieces.revealCard = rect(find("FlavorReveal", "Card"))
	-- Feed pills (toasts + Big Pop), each visible item.
	local toasts = {}
	local stack = find("Toasts", "Stack")
	if stack ~= nil then
		for _, child in stack:GetChildren() do
			local r = rect(child)
			if r ~= nil and child:IsA("CanvasGroup") and child.GroupTransparency < 0.9 then
				table.insert(toasts, r)
			end
		end
	end
	-- HUD pieces + the open window.
	local corner = HudCurrency.corner()
	local currency = if corner ~= nil then corner:FindFirstAncestor("Currency") else nil
	local hud = {
		stack = rect(currency),
		top = hudRect(HudZones.rect("Top")),
		objective = hudRect(HudZones.rect("Bottom")),
		hints = hudRect(HudZones.rect("Hints")),
		left = hudRect(HudZones.rect("Left")),
		right = hudRect(HudZones.rect("Right")),
		window = hudRect(PopupQueue.windowRect()),
	}
	local popups = {}
	for name, r in pieces do
		if r ~= nil then
			popups[name] = r
		end
	end
	for index, r in toasts do
		popups[`toast{index}`] = r
	end
	local bad = {}
	for name, r in popups do
		for hudName, h in hud do
			-- A centre banner may sit under an open window (it waits for windows; one already up
			-- stays): only feed pills must never cover a window.
			local skip = hudName == "window" and string.sub(name, 1, 5) ~= "toast"
			if h ~= nil and not skip and overlaps(r, h) then
				table.insert(bad, `{name}~{hudName}`)
			end
		end
		for other, o in popups do
			if other > name and overlaps(r, o) then
				table.insert(bad, `{name}~{other}`)
			end
		end
	end
	-- The reveal card must sit in the left half, low on the screen (owner R108: never centre).
	local camera = Workspace.CurrentCamera
	local card = pieces.revealCard
	local cardCorner = if card ~= nil and camera ~= nil
		then card[1] < camera.ViewportSize.X * 0.5 and card[2] + card[4] > camera.ViewportSize.Y * 0.5
		else nil
	-- Chips.
	local arrow = find("LuckyArrow", "Chip")
	local pill = gui("HappyHourChip")
	-- YOU marker vs the stack.
	local playerGui = LOCAL:FindFirstChildOfClass("PlayerGui")
	local marker = if playerGui ~= nil then playerGui:FindFirstChild("YouMarker") else nil
	local you = nil
	if marker ~= nil and marker:IsA("BillboardGui") then
		local point = Workspace.Terrain:FindFirstChild("YouMarkerPoint")
		local covered = nil
		if point ~= nil then
			local screen = Workspace.CurrentCamera:WorldToScreenPoint(point.WorldPosition + TycoonClientConfig.You.OffsetStuds)
			local size = TycoonClientConfig.You.SizePx
			if screen.Z > 0 then
				covered = PopupQueue.coversStack({ x = screen.X - size.X / 2, y = screen.Y - size.Y / 2, w = size.X, h = size.Y }, false)
			end
		end
		you = { enabled = marker.Enabled, covered = covered }
	end
	return {
		queue = PopupQueue.stats(),
		toasts = Toasts.stats(),
		pieces = pieces,
		toastRects = toasts,
		hud = hud,
		overlaps = bad,
		cardInCorner = cardCorner,
		arrowVisible = arrow ~= nil and arrow.Visible,
		pillHidden = if pill ~= nil then pill:GetAttribute("HappyHourChipHidden") else nil,
		you = you,
		focus = ScreenManager.isFocusMode(),
		modal = ScreenManager.topModalName() or "",
	}
end

local function holdSeconds(default: number): number
	local value = ARGS[1]
	return if type(value) == "number" and value > 0 then value else default
end

if COMMAND == "diag" then
	local root = gui("Hud")
	return HttpService:JSONEncode({
		hud = root ~= nil and root.Enabled,
		profile = type(ClientState.profile) == "table",
		tutorial = Tutorial.step(),
		top = ScreenManager.topModalName() or "",
		queue = PopupQueue.stats(),
	})
elseif COMMAND == "closeall" then
	ScreenManager.closeAllModals()
	return ScreenManager.topModalName() or ""
elseif COMMAND == "reveal" then
	local def = FlavorConfig.byRank(4)
	local played = def ~= nil and FlavorController.preview(def.id)
	task.wait(0.4)
	local root = gui("FlavorReveal")
	if root ~= nil then
		root:SetAttribute("DebugHold", true)
	end
	return HttpService:JSONEncode({ played = played, open = ScreenManager.isOpen("FlavorReveal"), queue = PopupQueue.stats() })
elseif COMMAND == "release" then
	local root = gui("FlavorReveal")
	if root ~= nil then
		root:SetAttribute("DebugHold", nil)
	end
	ScreenManager.close("FlavorReveal")
	task.wait(0.2)
	return HttpService:JSONEncode(PopupQueue.stats())
elseif COMMAND == "luckytoast" then
	Hud.notify("reward", "LUCKY BUTTON!", "LuckyButton")
	return HttpService:JSONEncode(Toasts.stats())
elseif COMMAND == "flavortoast" then
	Hud.notify("reward", "New Lucky Nuke: GALAXY in Nuke Town! Claim 60 Gems in Pets -> FLAVOURS.", "Gem")
	return HttpService:JSONEncode(Toasts.stats())
elseif COMMAND == "goals" then
	-- The R111 screenshot: three goal claims in a row → one merged pill.
	for _ = 1, 3 do
		Hud.notify("reward", "Goal claimed! +10 Gems", "Trophy")
		task.wait(0.15)
	end
	return HttpService:JSONEncode(Toasts.stats())
elseif COMMAND == "bigpop" then
	-- Four other-player broadcasts in a row through the real handler (owner R120: one pill per
	-- 30 s, the rest coalesced into the next one).
	for index, name in { "JusticeDev", "Alex", "Sam", "Kim" } do
		FlavorController.previewBigPop({
			entries = { { name = name, kind = "batch", id = "galaxy", label = "GALAXY", oneIn = 2500 + index } },
			more = 0,
		})
	end
	return HttpService:JSONEncode(Toasts.stats())
elseif COMMAND == "pills" then
	-- Three Galaxy Lucky Nukes in a row → ONE merged pill ("GALAXY x3 +$95.4M"), never centre.
	for _ = 1, 3 do
		FlavorController.previewPill("galaxy", 31800000)
		task.wait(0.2)
	end
	return HttpService:JSONEncode({ toasts = Toasts.stats(), juice = JuiceBanner.isShowing() })
elseif COMMAND == "quests" then
	ScreenManager.open("Quests", { source = "qa" })
	task.wait(0.6)
	Hud.notify("reward", "Goal claimed! +10 Gems", "Trophy")
	return HttpService:JSONEncode({ open = ScreenManager.isOpen("Quests"), window = PopupQueue.windowRect() })
elseif COMMAND == "juice" then
	local shown = JuiceBanner.show("Pocket Nuke Workbench", "LEVEL 50!", "x2 SPEED!", "cyan", holdSeconds(30))
	return HttpService:JSONEncode({ accepted = shown, queue = PopupQueue.stats() })
elseif COMMAND == "happy" then
	local shown = JuiceBanner.show(
		"NUKEY'S HAPPY HOUR",
		"CONFETTI STORM!",
		"Grab the falling coins!",
		"pink",
		holdSeconds(30),
		"happyHour"
	)
	return HttpService:JSONEncode({ accepted = shown, queue = PopupQueue.stats() })
elseif COMMAND == "probe" then
	task.wait(0.35) -- let the pop-in punch settle (AbsoluteSize includes the UIScale)
	return HttpService:JSONEncode(probe())
end
return "unknown command"
