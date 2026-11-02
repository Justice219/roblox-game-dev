--!strict
--[[
	AdminOverlayScreen — the always-on, non-modal admin overlay (ScreenModule "AdminOverlay",
	autoOpen, built at boot for EVERY player). It draws what the admin system shows outside the
	panel and wires the panel's open controls for admins.

	For everyone:
		(a) Announcement banner — the latest filtered announcement from the server-set
		    ReplicatedStorage attributes AdminConfig.Attributes.AnnounceText / AnnounceAt (shown
		    for AdminConfig.AnnounceSeconds, and on join only if it is younger than that, measured
		    on Workspace:GetServerTimeNow()). Blue stud card under the HUD's top currency stack.
		(b) Restart countdown banner — while ShutdownAt (server time) is set: "SERVER RESTARTING
		    IN 0:42" + the filtered reason (ShutdownReason) + "your progress is saved". One shared
		    1 Hz ticker (StudUI.countdown).
	For the local player in New Player Mode (server-set attribute NewPlayerMode == true; only
	admins can enter it):
		(c) owner R67: a small persistent yellow chip "NEW PLAYER MODE · EXIT" in the top-right
		    corner, directly left of the HUD's admin wrench chip (its rect = HudZones "TopRight",
		    published by the HUD; placement rules in Screens/Admin/NewPlayerQuick.chipRect: clear
		    of the currency stack and the offer column). EXIT (tap twice:
		    NewPlayerMode.Copy.BadgeConfirm) → AdminCommand "ExitNewPlayerMode" (the server
		    re-authorises it). Gamepad: EXIT is a selectable stud button linked with the wrench
		    chip (Left / Right), and the admin panel opens straight onto its own EXIT button.
		    Hidden while a menu is open (the panel's header button covers that case). It replaced
		    the old bottom badge, which sat between the HUD columns.
	For admins (server-set IsAdmin attribute; display / binding only — the server re-checks every
	command):
		(d) Hud.setButtonVisible("Admin", isAdmin); binds AdminConfig.OpenKeys (F2: toggle) and
		    AdminConfig.OpenButtons (D-pad down: open, only when no menu is open and nothing is
		    selected, so normal D-pad navigation keeps working) through ContextActionService;
		    unbound again when the rights go away. Starts AdminClient (remote listeners).
		(e) the LOCAL debug perf overlay (AdminDebugState, toggled from the World tab): client
		    FPS / ping / memory / instances + server FPS / heartbeat / memory / players from the
		    last AdminState. Ticks at 1 Hz; its frame counter (one Heartbeat connection) exists
		    only while the overlay is on.

	Input: the overlay never blocks the game — every frame is non-Active except the chip's EXIT
	button. DisplayOrder 42: above modals (39), below toasts (45).

	Security: display only. Attributes are server-written (clients cannot change what other
	players see); announcement / reason text is filtered on the server before it is published.

	Connects to: Shared/Config/AdminConfig (attributes, keys, timings), Shared/Util/NewPlayerMode,
	Screens/Admin/{AdminClient, AdminDebugState, AdminWidgets}, UI/Hud/Hud, Widgets/HudZones,
	UI/ScreenManager, Controllers/InputController, Kit/StudUI.

	Example (server side, AdminService): ReplicatedStorage:SetAttribute("AdminAnnounceText", text)
	then ReplicatedStorage:SetAttribute("AdminAnnounceAt", Workspace:GetServerTimeNow()).
]]

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local AdminClient = require(script.Parent.AdminClient)
local AdminConfig = require(ReplicatedStorage.Shared.Config.AdminConfig)
local AdminDebugState = require(script.Parent.AdminDebugState)
local AdminWidgets = require(script.Parent.AdminWidgets)
local Create = require(script.Parent.Parent.Parent.Create)
local Hud = require(script.Parent.Parent.Parent.Hud.Hud)
local HudZones = require(script.Parent.Parent.Parent.Widgets.HudZones)
local InputController = require(script.Parent.Parent.Parent.Parent.Controllers.InputController)
local NewPlayerMode = require(ReplicatedStorage.Shared.Util.NewPlayerMode)
local NewPlayerQuick = require(script.Parent.NewPlayerQuick)
local OfferFx = require(script.Parent.Parent.Parent.Widgets.OfferFx)
local ScreenManager = require(script.Parent.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local Neutral = UIStyleConfig.Neutral
local Attributes = AdminConfig.Attributes

-- Layout (design px at 1080p).
local BANNER_WIDTH = 900
-- The New Player Mode chip (R67): width; its height follows the wrench chip (>= EXIT + padding).
local CHIP_WIDTH = 400
local CHIP_GAP = 10
local EXIT_WIDTH = 150
local EXIT_HEIGHT = 52
local DEBUG_WIDTH = 640
local TOP_GAP = 12
local MAX_ANNOUNCE_CHARS = 300
-- Seconds the chip's EXIT stays armed after the first tap.
local EXIT_ARM_SECONDS = 3

local OPEN_ACTION = "SellNukesAdminOpen"
local PANEL = "AdminPanel"

local localPlayer = Players.LocalPlayer

-- A short pop for a banner (UIScale), skipped with Reduce Motion.
local function pop(scale: UIScale)
	if OfferFx.reducedMotion() then
		scale.Scale = 1
		return
	end
	scale.Scale = 0.85
	TweenService:Create(scale, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		:Play()
end

-- A text line inside a banner card.
local function bannerText(text: string, size: number, order: number, parent: Instance, color: Color3?): TextLabel
	local label = StudUI.text({
		text = text,
		textSize = size,
		size = UDim2.fromScale(1, 0),
		wrap = true,
		color = color,
		layoutOrder = order,
		zIndex = 3,
		parent = parent,
	})
	label.AutomaticSize = Enum.AutomaticSize.Y
	return label
end

-- A centred vertical-list banner card (auto height). Returns the card and its UIScale.
local function bannerCard(
	name: string,
	color: UIStyleConfig.ColorName,
	order: number,
	parent: Instance
): (StudUI.Card, UIScale)
	local card = StudUI.card({
		color = color,
		size = UDim2.fromOffset(BANNER_WIDTH, 0),
		name = name,
		layoutOrder = order,
		parent = parent,
	})
	card.frame.AutomaticSize = Enum.AutomaticSize.Y
	card.frame.Visible = false
	card.content.Size = UDim2.fromScale(1, 0)
	card.content.AutomaticSize = Enum.AutomaticSize.Y
	Create.new("UIListLayout", {
		Padding = UDim.new(0, 4),
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = card.content,
	})
	Create.new("UIPadding", {
		PaddingTop = UDim.new(0, 10),
		PaddingBottom = UDim.new(0, 14),
		PaddingLeft = UDim.new(0, 18),
		PaddingRight = UDim.new(0, 18),
		Parent = card.content,
	})
	local scale = Create.new("UIScale", { Scale = 1, Parent = card.frame }) :: UIScale
	return card, scale
end

--[[
	Builds the overlay (ScreenManager runs it once at boot; see the module header).
	@return ScreenHandle (nothing selectable by default; the overlay never takes focus)
]]
local function build(gui: ScreenGui): ScreenManager.ScreenHandle
	local root = Create.new("Frame", {
		Name = "AdminOverlay",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Active = false,
		Parent = gui,
	}) :: Frame

	-- Top column (announcement, restart, debug) under the HUD's top currency stack.
	local column = Create.new("Frame", {
		Name = "Top",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(BANNER_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Active = false,
		Parent = root,
		Children = {
			Create.new("UIListLayout", {
				Padding = UDim.new(0, 10),
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		},
	}) :: Frame

	-- (a) Announcement ---------------------------------------------------------------------------
	local announce, announceScale = bannerCard("Announcement", "blue", 1, column)
	bannerText("ANNOUNCEMENT", 26, 1, announce.content, Neutral.TextDim)
	local announceText = bannerText("", 36, 2, announce.content)
	local announceToken = 0

	local function showAnnouncement()
		local text = ReplicatedStorage:GetAttribute(Attributes.AnnounceText)
		local at = ReplicatedStorage:GetAttribute(Attributes.AnnounceAt)
		if type(text) ~= "string" or text == "" or type(at) ~= "number" then
			announce.frame.Visible = false
			return
		end
		local remaining = AdminConfig.AnnounceSeconds - (Workspace:GetServerTimeNow() - at)
		if remaining <= 0 then
			announce.frame.Visible = false
			return
		end
		announceToken += 1
		local token = announceToken
		announceText.Text = if #text > MAX_ANNOUNCE_CHARS then string.sub(text, 1, MAX_ANNOUNCE_CHARS) else text
		announce.frame.Visible = true
		pop(announceScale)
		task.delay(remaining, function()
			if token == announceToken then
				announce.frame.Visible = false
			end
		end)
	end
	-- The server writes the text first, then the time: the time change is the trigger.
	ReplicatedStorage:GetAttributeChangedSignal(Attributes.AnnounceAt):Connect(showAnnouncement)
	showAnnouncement()

	-- (b) Restart countdown --------------------------------------------------------------------------
	local restart, restartScale = bannerCard("Restart", "red", 2, column)
	bannerText("SERVER RESTARTING", 30, 1, restart.content)
	local countdown = StudUI.countdown({
		endsAt = 0,
		format = "ms",
		prefix = "in ",
		doneText = "now...",
		textSize = 44,
		size = UDim2.new(1, 0, 0, 52),
		parent = restart.content,
	})
	countdown.label.LayoutOrder = 2
	countdown.label.ZIndex = 3
	local restartReason = bannerText("", 24, 3, restart.content, Neutral.TextDim)

	local function updateRestart()
		local at = ReplicatedStorage:GetAttribute(Attributes.ShutdownAt)
		if type(at) ~= "number" or at <= 0 then
			restart.frame.Visible = false
			return
		end
		local reason = ReplicatedStorage:GetAttribute(Attributes.ShutdownReason)
		restartReason.Text = if type(reason) == "string" and reason ~= ""
			then `{string.sub(reason, 1, MAX_ANNOUNCE_CHARS)} · your progress is saved!`
			else "Your progress is saved. Rejoin in a moment!"
		countdown.setEndsAt(at)
		local wasVisible = restart.frame.Visible
		restart.frame.Visible = true
		if not wasVisible then
			pop(restartScale)
		end
	end
	ReplicatedStorage:GetAttributeChangedSignal(Attributes.ShutdownAt):Connect(updateRestart)
	ReplicatedStorage:GetAttributeChangedSignal(Attributes.ShutdownReason):Connect(updateRestart)
	updateRestart()

	-- (e) Debug perf overlay -----------------------------------------------------------------------
	local debugFrame = Create.new("Frame", {
		Name = "Debug",
		BackgroundColor3 = Neutral.Well,
		BackgroundTransparency = 0.2,
		Size = UDim2.fromOffset(DEBUG_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 3,
		Visible = false,
		Active = false,
		Parent = column,
		Children = {
			Create.new("UICorner", { CornerRadius = UDim.new(0, 8) }),
			Create.new("UIPadding", {
				PaddingTop = UDim.new(0, 8),
				PaddingBottom = UDim.new(0, 8),
				PaddingLeft = UDim.new(0, 12),
				PaddingRight = UDim.new(0, 12),
			}),
			Create.new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }),
		},
	}) :: Frame
	local debugLines: { TextLabel } = {}
	for index = 1, 3 do
		debugLines[index] = AdminWidgets.label({
			text = "",
			size = UDim2.new(1, 0, 0, 26),
			textSize = 20,
			font = "number",
			layoutOrder = index,
			parent = debugFrame,
		})
	end
	local frames = 0
	local frameConnection: RBXScriptConnection? = nil
	local debugToken = 0

	local function sampleClient(): (number, number)
		local memoryOk, memory = pcall(function(): number
			return Stats:GetTotalMemoryUsageMb()
		end)
		local instancesOk, instances = pcall(function(): number
			return Stats.InstanceCount
		end)
		return if memoryOk then memory else -1, if instancesOk then instances else -1
	end

	local function setDebug(on: boolean)
		debugFrame.Visible = on
		debugToken += 1
		local token = debugToken
		if frameConnection ~= nil then
			frameConnection:Disconnect()
			frameConnection = nil
		end
		if not on then
			return
		end
		frames = 0
		frameConnection = RunService.Heartbeat:Connect(function()
			frames += 1
		end)
		task.spawn(function()
			local last = os.clock()
			while token == debugToken do
				task.wait(1)
				if token ~= debugToken then
					break
				end
				local now = os.clock()
				local fps = frames / math.max(now - last, 0.001)
				frames = 0
				last = now
				local memory, instances = sampleClient()
				local pingOk, ping = pcall(function(): number
					return localPlayer:GetNetworkPing()
				end)
				debugLines[1].Text = string.format(
					"CLIENT  %.0f fps · ping %s · mem %s MB · %s inst",
					fps,
					if pingOk then `{math.floor(ping * 1000)} ms` else "?",
					if memory >= 0 then tostring(math.floor(memory)) else "?",
					if instances >= 0 then tostring(instances) else "?"
				)
				local state = AdminClient.state
				if state ~= nil then
					local s = state.stats
					debugLines[2].Text = string.format(
						"SERVER  %.0f fps · hb %.1f ms · mem %d MB · %d/%d players",
						s.fps,
						s.heartbeatMs,
						math.floor(s.memoryMb),
						math.floor(s.players),
						math.floor(s.maxPlayers)
					)
				else
					debugLines[2].Text = "SERVER  waiting for admin state..."
				end
				debugLines[3].Text = `INPUT  {InputController.mode} · UI scale {string.format(
					"%.2f",
					ScreenManager.scale
				)} · {ScreenManager.device.class}`
			end
		end)
	end
	AdminDebugState.Changed:Connect(setDebug)

	-- Keeps the top column under the HUD's top zone (currency stack) or the Roblox top bar.
	local function placeColumn()
		local top = HudZones.rect("Top")
		local y = if top ~= nil then top.y + top.h + TOP_GAP else ScreenManager.safeTop(TOP_GAP)
		column.Position = UDim2.new(0.5, 0, 0, math.max(y, ScreenManager.safeTop(TOP_GAP)))
	end

	-- (c) New Player Mode chip (owner R67): top-right, left of the admin wrench chip -----------------------
	local chip = StudUI.card({
		color = "yellow",
		size = UDim2.fromOffset(CHIP_WIDTH, EXIT_HEIGHT + 14),
		name = "NewPlayerChip",
		parent = root,
	})
	chip.frame.Visible = false
	local chipTitle = StudUI.text({
		text = NewPlayerMode.Copy.Badge,
		textSize = 26,
		size = UDim2.new(1, -(EXIT_WIDTH + 26), 1, -10),
		position = UDim2.fromOffset(10, 4),
		align = Enum.TextXAlignment.Left,
		zIndex = 3,
		parent = chip.content,
	})
	chipTitle.TextScaled = true
	local exitArmedUntil = 0
	local exitButton = StudUI.button({
		text = NewPlayerMode.Copy.BadgeExit,
		color = "red",
		size = UDim2.fromOffset(EXIT_WIDTH, EXIT_HEIGHT),
		textSize = 24,
		anchor = Vector2.new(1, 0.5),
		position = UDim2.new(1, -8, 0.5, -2),
		name = "Exit",
		parent = chip.content,
	})
	AdminWidgets.sized(exitButton.instance, EXIT_WIDTH, EXIT_HEIGHT)
	exitButton.setCallback(function()
		local now = os.clock()
		if now > exitArmedUntil then
			-- First tap arms it (a stray tap never throws the admin out of the sandbox).
			exitArmedUntil = now + EXIT_ARM_SECONDS
			exitButton.setText(NewPlayerMode.Copy.BadgeConfirm)
			task.delay(EXIT_ARM_SECONDS, function()
				if os.clock() >= exitArmedUntil then
					exitButton.setText(NewPlayerMode.Copy.BadgeExit)
				end
			end)
			return
		end
		exitArmedUntil = 0
		exitButton.setText(NewPlayerMode.Copy.BadgeExit)
		AdminClient.start()
		AdminClient.send(NewPlayerQuick.Exit)
	end)

	-- The wrench chip's button (HudAdminChip: holder Frame "AdminChip", button "Hud_Admin"; rebuilt
	-- when its size changes, so it is looked up again on every placement).
	local function wrenchButton(): GuiObject?
		local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
		local holder = if playerGui ~= nil then playerGui:FindFirstChild("AdminChip", true) else nil
		local button = if holder ~= nil then holder:FindFirstChild("Hud_Admin", true) else nil
		return if button ~= nil and button:IsA("GuiObject") then button else nil
	end

	--[[
		Places the chip left of the wrench chip (HudZones "TopRight"; NewPlayerQuick.chipRect) and
		links it with the wrench for the D-pad (EXIT ⇄ wrench). Runs on every HudZones change (the
		wrench is rebuilt on device / rotation changes, so the link is re-applied each time).
	]]
	local function placeChip()
		local canvas = ScreenManager.canvasSize(gui)
		local wrenchRect = HudZones.rect("TopRight")
		local height = math.max(EXIT_HEIGHT + 14, if wrenchRect ~= nil then wrenchRect.h else 0)
		local rect = NewPlayerQuick.chipRect({
			canvas = canvas,
			safeTop = ScreenManager.safeTop(0),
			margin = TOP_GAP,
			gap = CHIP_GAP,
			size = Vector2.new(CHIP_WIDTH, height),
			-- Phones: shrink into the gap left of the wrench before dropping onto the playfield.
			minWidth = EXIT_WIDTH + 130,
			adminChip = wrenchRect,
			top = HudZones.rect("Top"),
			right = HudZones.rect("Right"),
		})
		chip.frame.Position = UDim2.fromOffset(rect.x, rect.y)
		chip.frame.Size = UDim2.fromOffset(rect.w, rect.h)
		local button = wrenchButton()
		local shown = chip.frame.Visible
		exitButton.instance.NextSelectionRight = (if shown then button else nil) :: any
		if button ~= nil then
			button.NextSelectionLeft = (if shown then exitButton.instance else nil) :: any
		end
	end

	local function updateBadge()
		local active = NewPlayerMode.isActive(localPlayer)
		-- Hidden while a menu is open: the admin panel's header EXIT button covers that case and
		-- windows keep their corners (close X) uncovered.
		local shown = active and not ScreenManager.anyModalOpen()
		if chip.frame.Visible ~= shown then
			chip.frame.Visible = shown
			placeChip()
		end
	end
	localPlayer:GetAttributeChangedSignal(NewPlayerMode.Attribute):Connect(updateBadge)
	ScreenManager.Opened:Connect(updateBadge)
	ScreenManager.Closed:Connect(updateBadge)
	updateBadge()

	local function placeAll()
		placeColumn()
		placeChip()
	end
	HudZones.Changed:Connect(placeAll)
	ScreenManager.LayoutChanged:Connect(placeAll)
	ScreenManager.SafeAreaChanged:Connect(placeAll)
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(placeAll)
	placeAll()

	-- (d) Admin wiring -----------------------------------------------------------------------------------
	local bound = false
	local function onOpenAction(_name: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
		if state ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		if localPlayer:GetAttribute("IsAdmin") ~= true or UserInputService:GetFocusedTextBox() ~= nil then
			return Enum.ContextActionResult.Pass
		end
		if table.find(AdminConfig.OpenButtons, input.KeyCode) ~= nil then
			-- D-pad down opens the panel only from plain gameplay: inside menus (or with the HUD
			-- columns focused) it keeps navigating.
			if ScreenManager.anyModalOpen() or GuiService.SelectedObject ~= nil then
				return Enum.ContextActionResult.Pass
			end
			ScreenManager.open(PANEL)
			return Enum.ContextActionResult.Sink
		end
		ScreenManager.toggle(PANEL)
		return Enum.ContextActionResult.Sink
	end

	local function applyAdmin()
		local isAdmin = localPlayer:GetAttribute("IsAdmin") == true
		Hud.setButtonVisible("Admin", isAdmin)
		if isAdmin then
			AdminClient.start()
			if not bound then
				bound = true
				local keys: { Enum.KeyCode } = {}
				for _, key in AdminConfig.OpenKeys do
					table.insert(keys, key)
				end
				for _, key in AdminConfig.OpenButtons do
					table.insert(keys, key)
				end
				ContextActionService:BindActionAtPriority(
					OPEN_ACTION,
					onOpenAction,
					false,
					Enum.ContextActionPriority.Medium.Value,
					table.unpack(keys)
				)
			end
		else
			if bound then
				bound = false
				ContextActionService:UnbindAction(OPEN_ACTION)
			end
			AdminDebugState.set(false)
			if ScreenManager.isOpen(PANEL) then
				ScreenManager.close(PANEL)
			end
		end
	end
	localPlayer:GetAttributeChangedSignal("IsAdmin"):Connect(applyAdmin)
	applyAdmin()

	return {
		defaultSelection = function(): GuiObject?
			return nil
		end,
	}
end

local AdminOverlayScreen: ScreenManager.ScreenModule = {
	name = "AdminOverlay",
	modal = false,
	autoOpen = true,
	lazy = false,
	-- Above modals (39), below toasts (45): banners stay readable over any open window.
	displayOrder = 42,
	build = build,
}

return AdminOverlayScreen
