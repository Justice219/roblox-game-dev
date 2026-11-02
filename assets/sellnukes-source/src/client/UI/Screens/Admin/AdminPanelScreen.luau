--!strict
--[[
	AdminPanelScreen — the owner-only ADMIN PANEL (spec §14; owner R6 "an admin panel built in that
	I have access to as the owner of the experience"). ScreenModule "AdminPanel" (modal, lazy:
	built the first time an admin opens it). UIController registers it automatically (a
	`*Screen` module inside Screens/Admin).

	Opening: F2 / gamepad D-pad down (bound only for admins by AdminOverlayScreen), the admin-only
	"Admin" HUD button, or ScreenManager.open("AdminPanel", { tab = "Live" }).

	Layout (stud window, 1640 x 940 design px; ModalShell shrinks it on phones):
		header: Admin Panel                    [ PLAY AS NEW PLAYER ]  [X]   (owner R67, every tab)
		[LB] [Players][Economy][Server][World][Live][Log][Analytics][New Player] [RB]
		status: last command result (green ok / red failed)            3/8 players · STUDIO
		┌ page area ─────────────────────────────────────────────────────────────────────────┐
		│ PlayersTab / ActionsTab (Economy, Server, World, NewPlayer) / LiveTab / LogTab /    │
		│ AnalyticsTab — every page implements AdminWidgets.Page                               │
		└─────────────────────────────────────────────────────────────────────────────────────┘
	Pages are created the first time their tab is shown; on every AdminState push only the
	VISIBLE page renders (and pages make that cheap when nothing changed).

	PLAY AS NEW PLAYER (owner R67: the owner could not find the New Player tab): a big yellow
	header button, visible on every tab, that turns green "EXIT NEW PLAYER MODE" while the mode is
	on (server-set NewPlayerMode attribute). It asks through the in-panel confirm with the
	command's own description, then sends the EXISTING commands "NewPlayerMode" /
	"ExitNewPlayerMode" (server: re-auth, cooldown, audit; rules in Screens/Admin/NewPlayerQuick).
	Unavailable (server availability map) → the press shows the reason instead. Gamepad: Up from
	the tab bar reaches it; while the mode is on it is the panel's default selection (D-pad down
	opens the panel straight onto EXIT).

	In-panel confirm: commands marked `confirm` (and quick UNBANs) open a confirm layer INSIDE the
	window (dim cover + stud dialog: what will happen, the arguments, the target; CONFIRM in the
	command's colour + CANCEL). Gamepad: CANCEL is pre-selected, the dialog traps the selection,
	B cancels (ScreenHandle.onBack). Clicks never reach the panel under the cover.

	Gamepad: LB / RB switch tabs (bound while the panel is the top modal); D-pad down from the tab
	bar enters the page (page.first), the page's top row leads back up to the active tab; B closes
	(or cancels the confirm layer). Touch: tabs and every control honour the 44 pt tap floor
	(AdminWidgets.sized / tapFloor at the window's fit).

	Non-admins: the panel shows "ADMINS ONLY" and nothing else (the server also never sends them
	state and refuses every command; IsAdmin / AdminState are display hints only).

	Security: display + intents only. Every button sends `AdminCommand(name, args)`; the server
	(AdminService) re-authorises the caller on every call, checks the allowlist, cooldown and the
	strict argument schema, resolves targets itself and audits the result.

	Connects to: Screens/Admin/{AdminClient, AdminWidgets, CommandForm, PlayersTab, ActionsTab,
	LiveTab, LogTab, AnalyticsTab}, Kit/StudUI, Widgets/{ModalShell, InputGlyph, StudWindow},
	UI/ScreenManager, Controllers/InputController, Shared/Config/AdminConfig.

	Example:
		ScreenManager.open("AdminPanel")                    -- last tab (Players first)
		ScreenManager.open("AdminPanel", { tab = "Log" })   -- jump to a tab
]]

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local ActionsTab = require(script.Parent.ActionsTab)
local AdminClient = require(script.Parent.AdminClient)
local AdminConfig = require(ReplicatedStorage.Shared.Config.AdminConfig)
local AdminWidgets = require(script.Parent.AdminWidgets)
local AnalyticsTab = require(script.Parent.AnalyticsTab)
local Create = require(script.Parent.Parent.Parent.Create)
local InputController = require(script.Parent.Parent.Parent.Parent.Controllers.InputController)
local InputGlyph = require(script.Parent.Parent.Parent.Widgets.InputGlyph)
local LiveTab = require(script.Parent.LiveTab)
local LogTab = require(script.Parent.LogTab)
local NewPlayerMode = require(ReplicatedStorage.Shared.Util.NewPlayerMode)
local NewPlayerQuick = require(script.Parent.NewPlayerQuick)
local ModalShell = require(script.Parent.Parent.Parent.Widgets.ModalShell)
local PlayersTab = require(script.Parent.PlayersTab)
local ScreenManager = require(script.Parent.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

type ColorName = UIStyleConfig.ColorName
type Page = AdminWidgets.Page

local SCREEN_NAME = "AdminPanel"
local Neutral = UIStyleConfig.Neutral
local Style = UIStyleConfig

-- Layout (design px at 1080p).
local PANEL_SIZE = Vector2.new(1640, 940)
local TAB_WIDTH = 176
local TAB_HEIGHT = 56
local TAB_GAP = 8
local TAB_LIP = 10 -- room under a stud button for its 3D lip + outline
local GLYPH_SIZE = 36
local STATUS_HEIGHT = 40
local ROW_GAP = 8
local INFO_WIDTH = 420
local CONFIRM_WIDTH = 780
local CONFIRM_BUTTON_WIDTH = 280
local CONFIRM_BUTTON_HEIGHT = 60
-- R67 header quick button (PLAY AS NEW PLAYER / EXIT NEW PLAYER MODE).
local QUICK_WIDTH = 460
local QUICK_HEIGHT = 72
local QUICK_GAP = 18

-- ContextActionService action for LB / RB tab switching.
local TAB_ACTION = "SellNukesAdminTabs"

local localPlayer = Players.LocalPlayer

-- The tab keys in panel order (AdminConfig.Tabs without the hidden Meta tab).
local TAB_KEYS: { string } = {}
local TAB_DEFS: { [string]: AdminConfig.TabDef } = {}
for _, def in AdminConfig.Tabs do
	if def.key ~= "Meta" then
		table.insert(TAB_KEYS, def.key)
		TAB_DEFS[def.key] = def
	end
end

-- Valid colour preset names (a tab def colour that is not a preset falls back to grey).
local function colorName(name: string): ColorName
	return if Style.Colors[name :: ColorName] ~= nil then name :: ColorName else "grey"
end

--[[
	Builds the panel inside its ScreenGui (ScreenManager calls it on first open).
	@return ScreenHandle (onOpen / onClose / onBack / defaultSelection)
]]
local function build(gui: ScreenGui): ScreenManager.ScreenHandle
	AdminClient.start()

	local isOpen = false
	local activeTab = TAB_KEYS[1]
	local pages: { [string]: Page } = {}
	local tabButtons: { [string]: StudUI.Button } = {}

	local window = StudUI.window({
		title = "Admin Panel",
		color = "purple",
		icon = "Admin",
		size = PANEL_SIZE,
		name = "AdminPanelWindow",
		onClose = function()
			ScreenManager.close(SCREEN_NAME)
		end,
	})
	local shell = ModalShell.new(gui, window.frame, PANEL_SIZE)
	local body = window.body
	local bodyWidth = PANEL_SIZE.X - 2 * Style.Window.BodyPadding
	local bodyHeight = PANEL_SIZE.Y - Style.Window.HeaderHeight - Style.Window.HeaderLip - 2 * Style.Window.BodyPadding

	local function fit(): number
		return shell.scale()
	end

	-- Tab bar -------------------------------------------------------------------------------------
	local tabBar = Create.new("Frame", {
		Name = "Tabs",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, TAB_HEIGHT + TAB_LIP),
		Parent = body,
	}) :: Frame
	local tabRow = Create.new("Frame", {
		Name = "Row",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(GLYPH_SIZE + 12, 0),
		Size = UDim2.new(1, -2 * (GLYPH_SIZE + 12), 1, 0),
		Parent = tabBar,
		Children = {
			Create.new("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				Padding = UDim.new(0, TAB_GAP),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		},
	}) :: Frame
	local lbGlyph = InputGlyph.dynamic(nil, Enum.KeyCode.ButtonL1, GLYPH_SIZE)
	lbGlyph.AnchorPoint = Vector2.new(0, 0.5)
	lbGlyph.Position = UDim2.fromOffset(0, TAB_HEIGHT / 2)
	lbGlyph.Parent = tabBar
	local rbGlyph = InputGlyph.dynamic(nil, Enum.KeyCode.ButtonR1, GLYPH_SIZE)
	rbGlyph.AnchorPoint = Vector2.new(1, 0.5)
	rbGlyph.Position = UDim2.new(1, 0, 0, TAB_HEIGHT / 2)
	rbGlyph.Parent = tabBar

	-- Status row ------------------------------------------------------------------------------------
	local statusRow = Create.new("Frame", {
		Name = "Status",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, TAB_HEIGHT + TAB_LIP + ROW_GAP),
		Size = UDim2.new(1, 0, 0, STATUS_HEIGHT),
		Parent = body,
	}) :: Frame
	local statusLabel = AdminWidgets.label({
		name = "Result",
		text = "Pick a tab. Every command is checked again by the server.",
		size = UDim2.new(1, -(INFO_WIDTH + 12), 1, 0),
		textSize = 24,
		color = Neutral.TextDim,
		parent = statusRow,
	})
	local infoLabel = AdminWidgets.label({
		name = "Info",
		text = "",
		size = UDim2.fromOffset(INFO_WIDTH, STATUS_HEIGHT),
		textSize = 22,
		color = Neutral.TextDim,
		align = Enum.TextXAlignment.Right,
		parent = statusRow,
	})
	infoLabel.AnchorPoint = Vector2.new(1, 0)
	infoLabel.Position = UDim2.fromScale(1, 0)

	-- Page area --------------------------------------------------------------------------------------
	local pageTop = TAB_HEIGHT + TAB_LIP + ROW_GAP + STATUS_HEIGHT + ROW_GAP
	local pageHost = Create.new("Frame", {
		Name = "Pages",
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Position = UDim2.fromOffset(0, pageTop),
		Size = UDim2.new(1, 0, 1, -pageTop),
		Parent = body,
	}) :: Frame

	-- Admins-only notice (covers the body while the local player is not an admin).
	local notice = Create.new("Frame", {
		Name = "AdminsOnly",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 10,
		Parent = body,
	}) :: Frame
	StudUI.text({
		text = "ADMINS ONLY",
		textSize = 72,
		font = "shout",
		size = UDim2.new(1, 0, 0, 90),
		position = UDim2.fromScale(0.5, 0.4),
		anchor = Vector2.new(0.5, 0.5),
		zIndex = 11,
		parent = notice,
	})
	StudUI.text({
		text = "This panel is only for the owner of the experience and their admins.",
		textSize = 30,
		size = UDim2.new(1, -80, 0, 40),
		position = UDim2.fromScale(0.5, 0.55),
		anchor = Vector2.new(0.5, 0.5),
		color = Neutral.TextDim,
		zIndex = 11,
		parent = notice,
	})

	-- Status -----------------------------------------------------------------------------------------
	local function setStatus(text: string, ok: boolean?)
		statusLabel.Text = text
		statusLabel.TextColor3 = if ok == true
			then Neutral.CashGreen
			elseif ok == false then Neutral.Danger
			else Neutral.Text
	end
	AdminClient.Result:Connect(function(result)
		setStatus(result.text, result.ok)
	end)

	-- Confirm layer ----------------------------------------------------------------------------------
	local cover = Create.new("TextButton", {
		Name = "ConfirmLayer",
		AutoButtonColor = false,
		BackgroundColor3 = Neutral.Shadow,
		BackgroundTransparency = 0.35,
		Size = UDim2.fromScale(1, 1),
		Text = "",
		Active = true, -- swallows clicks: nothing under the dialog can be pressed
		Selectable = false,
		Visible = false,
		ZIndex = 50,
		Parent = window.frame,
	}) :: TextButton
	local dialog = StudUI.card({
		color = "red",
		size = UDim2.fromOffset(CONFIRM_WIDTH, 0),
		anchor = Vector2.new(0.5, 0.5),
		position = UDim2.fromScale(0.5, 0.5),
		name = "Dialog",
		parent = cover,
	})
	dialog.frame.AutomaticSize = Enum.AutomaticSize.Y
	dialog.frame.ZIndex = 51
	-- Trap the gamepad selection inside the dialog while it is open.
	dialog.frame.SelectionGroup = true
	dialog.frame.SelectionBehaviorUp = Enum.SelectionBehavior.Stop
	dialog.frame.SelectionBehaviorDown = Enum.SelectionBehavior.Stop
	dialog.frame.SelectionBehaviorLeft = Enum.SelectionBehavior.Stop
	dialog.frame.SelectionBehaviorRight = Enum.SelectionBehavior.Stop
	local dialogContent = dialog.content
	dialogContent.AutomaticSize = Enum.AutomaticSize.Y
	dialogContent.Size = UDim2.fromScale(1, 0)
	Create.new("UIListLayout", {
		Padding = UDim.new(0, 14),
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = dialogContent,
	})
	Create.new("UIPadding", {
		PaddingTop = UDim.new(0, 18),
		PaddingBottom = UDim.new(0, 22),
		PaddingLeft = UDim.new(0, 26),
		PaddingRight = UDim.new(0, 26),
		Parent = dialogContent,
	})
	local confirmTitle = StudUI.text({
		name = "Title",
		text = "ARE YOU SURE?",
		textSize = 44,
		size = UDim2.new(1, 0, 0, 52),
		layoutOrder = 1,
		zIndex = 52,
		parent = dialogContent,
	})
	local confirmMessage = StudUI.text({
		name = "Message",
		text = "",
		textSize = 24,
		font = "body",
		wrap = true,
		size = UDim2.fromScale(1, 0),
		layoutOrder = 2,
		zIndex = 52,
		parent = dialogContent,
	})
	confirmMessage.AutomaticSize = Enum.AutomaticSize.Y
	local confirmButtons = AdminWidgets.wrapRow("Buttons", dialogContent, 24, 3)
	local layout = confirmButtons:FindFirstChildOfClass("UIListLayout")
	if layout ~= nil then
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	end
	local pendingConfirm: (() -> ())? = nil
	local selectionBefore: GuiObject? = nil

	local confirmButton = StudUI.button({
		text = "CONFIRM",
		color = "green",
		size = UDim2.fromOffset(CONFIRM_BUTTON_WIDTH, CONFIRM_BUTTON_HEIGHT),
		textSize = 28,
		name = "Confirm",
		layoutOrder = 1,
		parent = confirmButtons,
	})
	AdminWidgets.sized(confirmButton.instance, CONFIRM_BUTTON_WIDTH, CONFIRM_BUTTON_HEIGHT, fit)
	local cancelButton = StudUI.button({
		text = "CANCEL",
		color = "grey",
		size = UDim2.fromOffset(CONFIRM_BUTTON_WIDTH, CONFIRM_BUTTON_HEIGHT),
		textSize = 28,
		name = "Cancel",
		layoutOrder = 2,
		parent = confirmButtons,
	})
	AdminWidgets.sized(cancelButton.instance, CONFIRM_BUTTON_WIDTH, CONFIRM_BUTTON_HEIGHT, fit)
	confirmButton.instance.NextSelectionRight = cancelButton.instance
	cancelButton.instance.NextSelectionLeft = confirmButton.instance

	local function closeConfirm()
		cover.Visible = false
		pendingConfirm = nil
		local previous = selectionBefore
		selectionBefore = nil
		if InputController.mode == "Gamepad" then
			GuiService.SelectedObject = if previous ~= nil and previous:IsDescendantOf(gui) then previous else nil
		end
	end
	cancelButton.setCallback(closeConfirm)
	confirmButton.setCallback(function()
		local action = pendingConfirm
		closeConfirm()
		if action ~= nil then
			action()
		end
	end)

	--[[ Shows the confirm layer; `request.onConfirm` runs only after CONFIRM. CANCEL is pre-selected. ]]
	local function ask(request: AdminWidgets.ConfirmRequest)
		pendingConfirm = request.onConfirm
		confirmTitle.Text = request.title
		confirmMessage.Text = request.message
		confirmButton.setText(request.confirmText)
		confirmButton.setColor(request.color)
		dialog.setColor(if request.color == "red" then "red" else "blue")
		selectionBefore = GuiService.SelectedObject
		cover.Visible = true
		if InputController.mode == "Gamepad" then
			GuiService.SelectedObject = cancelButton.instance
		end
	end

	-- Admin check -------------------------------------------------------------------------------------
	local function admin(): boolean
		return AdminClient.isAdmin()
	end

	-- R67 header quick button: PLAY AS NEW PLAYER / EXIT NEW PLAYER MODE (every tab) -----------------
	local quick = StudUI.button({
		text = NewPlayerQuick.Copy.Enter,
		color = "yellow",
		size = UDim2.fromOffset(QUICK_WIDTH, QUICK_HEIGHT),
		textSize = 28,
		anchor = Vector2.new(1, 0.5),
		position = UDim2.new(1, -(14 + Style.Window.CloseSize + QUICK_GAP), 0.5, -math.floor(Style.Button.Lip / 2)),
		name = "NewPlayerQuick",
		parent = window.header,
	})
	quick.instance.ZIndex = 5
	quick.instance.Visible = false
	AdminWidgets.sized(quick.instance, QUICK_WIDTH, QUICK_HEIGHT, fit)
	-- The title gives the button its room (it would run under it on a long title).
	window.titleLabel.Size = window.titleLabel.Size - UDim2.fromOffset(QUICK_WIDTH + QUICK_GAP, 0)
	local quickAction: NewPlayerQuick.HeaderAction? = nil

	-- Repaints the button from the mode attribute + the server's availability map (cheap).
	local function paintQuick()
		local action = NewPlayerQuick.headerAction(NewPlayerMode.isActive(localPlayer), AdminClient.unavailable)
		local previous = quickAction
		quickAction = action
		quick.instance.Visible = admin()
		if previous == nil or previous.text ~= action.text or previous.color ~= action.color then
			quick.setText(action.text)
			quick.setColor(colorName(action.color))
		end
		quick.setState(if action.enabled then "normal" else "disabled")
	end
	quick.setCallback(function()
		local action = quickAction
		if action == nil or not admin() then
			return
		end
		if not action.enabled then
			setStatus(`{action.text}: {action.reason or "not available"}`, false)
			return
		end
		local info = AdminClient.command(action.command)
		ask({
			title = `{action.text}?`,
			message = if info ~= nil then info.description else action.text,
			confirmText = action.text,
			color = colorName(action.color),
			onConfirm = function()
				setStatus(`{action.text}...`, nil)
				AdminClient.send(action.command)
			end,
		})
	end)
	localPlayer:GetAttributeChangedSignal(NewPlayerMode.Attribute):Connect(paintQuick)
	AdminClient.Changed:Connect(paintQuick)
	localPlayer:GetAttributeChangedSignal("IsAdmin"):Connect(paintQuick)
	paintQuick()

	-- Pages ------------------------------------------------------------------------------------------
	local pageWidth = bodyWidth
	-- The page area's current top (moves down when the touch floor grows the tab bar).
	local currentPageTop = pageTop

	local function ensurePage(key: string): Page
		local existing = pages[key]
		if existing ~= nil then
			return existing
		end
		local pageHeight = bodyHeight - currentPageTop
		local options: AdminWidgets.PageOptions = {
			parent = pageHost,
			width = pageWidth,
			height = pageHeight,
			setStatus = setStatus,
			isActive = function(): boolean
				return isOpen and activeTab == key
			end,
			refresh = function()
				local page = pages[key]
				if page ~= nil then
					page.render()
				end
			end,
			fitScale = fit,
			ask = ask,
			tab = key,
		}
		local page: Page
		if key == "Players" then
			page = PlayersTab.new(options)
		elseif key == "Live" then
			page = LiveTab.new(options)
		elseif key == "Log" then
			page = LogTab.new(options)
		elseif key == "Analytics" then
			page = AnalyticsTab.new({
				parent = pageHost,
				width = pageWidth,
				height = pageHeight,
				setStatus = setStatus,
				isActive = options.isActive,
				refresh = options.refresh,
				fitScale = fit,
			})
		else
			page = ActionsTab.new(options)
		end
		if key ~= "Analytics" then
			-- Our pages lay out with scale sizes inside: let them follow the page area on relayout.
			page.frame.Size = UDim2.fromScale(1, 1)
		end
		pages[key] = page
		return page
	end

	-- Points the tab bar and the active page's top row at each other (gamepad D-pad up / down).
	local function wireSelection(page: Page)
		local entry = page.first()
		local activeButton = tabButtons[activeTab]
		for _, key in TAB_KEYS do
			local button = tabButtons[key]
			if button ~= nil then
				-- (nil clears the link; the engine property accepts nil.)
				button.instance.NextSelectionDown = entry :: any
			end
		end
		if activeButton ~= nil then
			for _, control in page.topRow() do
				control.NextSelectionUp = activeButton.instance
			end
		end
	end

	-- Renders the visible page (and the info line); cheap when nothing changed.
	local function renderActive()
		local isAdmin = admin()
		notice.Visible = not isAdmin
		tabBar.Visible = isAdmin
		statusRow.Visible = isAdmin
		pageHost.Visible = isAdmin
		if not isAdmin or not isOpen then
			return
		end
		local state = AdminClient.state
		if state ~= nil then
			infoLabel.Text = `{state.stats.players}/{state.stats.maxPlayers} players`
				.. (if state.isStudio then " · STUDIO" else "")
				.. (if state.stats.savingEnabled then "" else " · NOT SAVING")
		else
			infoLabel.Text = "waiting for the server..."
		end
		local page = ensurePage(activeTab)
		page.render()
		wireSelection(page)
	end

	local function paintTabs()
		for _, key in TAB_KEYS do
			local button = tabButtons[key]
			if button ~= nil then
				button.setColor(if key == activeTab then colorName(TAB_DEFS[key].color) else "grey")
			end
		end
		-- Down from the header button lands on the active tab.
		local active = tabButtons[activeTab]
		quick.instance.NextSelectionDown = (if active ~= nil then active.instance else nil) :: any
	end

	--[[ Shows tab `key` (creating its page on first use) and moves the gamepad selection into it. ]]
	local function selectTab(key: string)
		if TAB_DEFS[key] == nil then
			return
		end
		activeTab = key
		for name, page in pages do
			page.frame.Visible = name == key
		end
		local page = ensurePage(key)
		page.frame.Visible = true
		paintTabs()
		renderActive()
		if InputController.mode == "Gamepad" and isOpen and not cover.Visible then
			local target = page.first() or tabButtons[key].instance
			GuiService.SelectedObject = target
		end
	end

	for index, key in TAB_KEYS do
		local def = TAB_DEFS[key]
		local button = StudUI.button({
			text = def.label,
			color = "grey",
			size = UDim2.fromOffset(TAB_WIDTH, TAB_HEIGHT),
			textSize = 24,
			name = `Tab_{key}`,
			layoutOrder = index,
			parent = tabRow,
			onActivated = function()
				selectTab(key)
			end,
		})
		AdminWidgets.sized(button.instance, TAB_WIDTH, TAB_HEIGHT, fit)
		tabButtons[key] = button
	end
	for index, key in TAB_KEYS do
		local button = tabButtons[key].instance
		local left = TAB_KEYS[index - 1]
		local right = TAB_KEYS[index + 1]
		button.NextSelectionLeft = (if left ~= nil then tabButtons[left].instance else nil) :: any
		button.NextSelectionRight = (if right ~= nil then tabButtons[right].instance else nil) :: any
		-- R67: Up from any tab reaches the header's PLAY AS NEW PLAYER / EXIT button.
		button.NextSelectionUp = quick.instance
	end

	-- Touch: tab bar height follows the tap floor; the status row and page area move below it.
	local function relayout()
		local floor = AdminWidgets.tapFloor(fit())
		local tabHeight = math.max(TAB_HEIGHT, floor)
		tabBar.Size = UDim2.new(1, 0, 0, tabHeight + TAB_LIP)
		lbGlyph.Position = UDim2.fromOffset(0, tabHeight / 2)
		rbGlyph.Position = UDim2.new(1, 0, 0, tabHeight / 2)
		statusRow.Position = UDim2.fromOffset(0, tabHeight + TAB_LIP + ROW_GAP)
		local top = tabHeight + TAB_LIP + ROW_GAP + STATUS_HEIGHT + ROW_GAP
		currentPageTop = top
		pageHost.Position = UDim2.fromOffset(0, top)
		pageHost.Size = UDim2.new(1, 0, 1, -top)
	end
	ScreenManager.LayoutChanged:Connect(relayout)
	relayout()

	-- LB / RB tab switching (only while the panel is the top modal and no confirm is open).
	local function onTabAction(_name: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
		if state ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		if
			not ScreenManager.isTopModal(SCREEN_NAME)
			or cover.Visible
			or not admin()
			or UserInputService:GetFocusedTextBox() ~= nil
		then
			return Enum.ContextActionResult.Pass
		end
		local index = table.find(TAB_KEYS, activeTab) or 1
		local step = if input.KeyCode == Enum.KeyCode.ButtonL1 then -1 else 1
		local nextIndex = ((index - 1 + step) % #TAB_KEYS) + 1
		selectTab(TAB_KEYS[nextIndex])
		return Enum.ContextActionResult.Sink
	end

	-- Server pushes → re-render the visible page; revoked rights → close.
	AdminClient.Changed:Connect(function()
		if isOpen then
			renderActive()
		end
	end)
	AdminClient.Revoked:Connect(function()
		if isOpen then
			ScreenManager.close(SCREEN_NAME)
		end
	end)
	localPlayer:GetAttributeChangedSignal("IsAdmin"):Connect(function()
		if isOpen then
			renderActive()
		end
	end)

	selectTab(activeTab)

	return {
		onOpen = function(args: any?)
			local wasOpen = isOpen
			isOpen = true
			if not wasOpen then
				paintQuick()
				shell.popIn()
				AdminWidgets.refit()
				relayout()
				ContextActionService:BindActionAtPriority(
					TAB_ACTION,
					onTabAction,
					false,
					Enum.ContextActionPriority.High.Value,
					Enum.KeyCode.ButtonL1,
					Enum.KeyCode.ButtonR1
				)
				if admin() then
					AdminClient.send("RequestState")
				end
			end
			local requested = if type(args) == "table" then (args :: any).tab else nil
			if type(requested) == "string" and TAB_DEFS[requested] ~= nil then
				selectTab(requested)
			else
				selectTab(activeTab)
			end
		end,
		onClose = function()
			isOpen = false
			cover.Visible = false
			pendingConfirm = nil
			ContextActionService:UnbindAction(TAB_ACTION)
		end,
		onBack = function(): boolean
			if cover.Visible then
				closeConfirm()
				return true
			end
			return false
		end,
		defaultSelection = function(): GuiObject?
			if cover.Visible then
				return cancelButton.instance
			end
			if not admin() then
				return window.closeButton
			end
			-- R67: in New Player Mode the panel opens straight onto EXIT NEW PLAYER MODE.
			if NewPlayerMode.isActive(localPlayer) and quick.instance.Visible then
				return quick.instance
			end
			local page = pages[activeTab]
			local target = if page ~= nil then page.first() else nil
			return target or tabButtons[activeTab].instance
		end,
	}
end

local AdminPanelScreen: ScreenManager.ScreenModule = {
	name = SCREEN_NAME,
	modal = true,
	lazy = true,
	closeOnBack = true,
	-- No world blur: admins watch the effect of their commands (build-in replays, teleports).
	blur = false,
	build = build,
}

return AdminPanelScreen
