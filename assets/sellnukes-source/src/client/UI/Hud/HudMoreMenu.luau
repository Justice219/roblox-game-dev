--!strict
--[[
	HudMoreMenu — the HUD's MORE flyout (owner R110, 2026-10-31: "can we cut down on the cards on
	the left at all? there is just a bunch lol").

	Purpose:
		The left stack shrank to Shop, Pets, Quests, Rewards, Attack + a MORE tile. Teleport,
		Rebirth, the Thanksgiving Event (only while it is live) and Settings live in this compact
		stud panel that pops out BESIDE the stack (HudZonesConfig.MoreRows; placement =
		Widgets/HudPlacement.flyout, applied through `place`). Each item is the same
		StudUI.hudButton tile as the stack (>= 44 pt on touch, the stack's size and labels) and
		opens its screen exactly like the old stack tile did (`ScreenManager.open(screen)`, no
		args, so every screen keeps reporting its own analytics id with source "hud").
		It is a popover, not a modal:
			- tapping / clicking anywhere else closes it (world, another HUD button, the thumbs),
			- gamepad B closes it and puts the cursor back on MORE (a CAS binding above the HUD
			  "Deselect" B, below ScreenManager's modal Back; bound only while open),
			- the D-pad walks its tiles (default selection = the first item when MORE was pressed
			  with a gamepad); Left from the first column returns to MORE, the other outer edges
			  stay put; moving the cursor anywhere else closes it,
			- any menu (modal) opening, or the HUD focus mode, closes it (it also lives in the R79
			  MenuLayer, which fades out with menus).
		Badges ("!", "3") and NEW tags set on its items ROLL UP onto the MORE tile
		(UI/Hud/HudMoreLogic.rollup -> `onRollup`), so a closed flyout still shows them.

	Analytics (rule 9): every open reports ClientAnalytics.screenOpened("More", "hud")
	("open:More" / "openFrom:More:hud", AnalyticsConfig.ClientFunnel.Screens).

	Security: display only — items open screens; every purchase / claim stays a server intent.

	Performance: the panel and its tiles are built once; the input watchers (UserInputService
	InputBegan + GuiService.SelectedObject) and the B binding exist only while the flyout is open;
	one reused pop tween; re-layout only through `place` (HUD layout events).

	Connects to: Shared/Config/{HudZonesConfig (MoreRows / MoreFlyout), PlatformConfig.Priority,
	UIStyleConfig}, UI/Hud/{HudButtons (owner: builds the MORE tile, routes keys), HudMoreLogic},
	Widgets/{HudPlacement (FlyoutLayout), StudWindow, OfferFx (Reduce Motion)}, Kit/StudUI,
	UI/ScreenManager, Platform/GamepadNav, Analytics/ClientAnalytics.

	Example (HudButtons):
		local menu = HudMoreMenu.new(layer, moreTile.instance)
		menu.onRollup(function(badge, isNew) moreTile.setBadge(badge) end)
		menu.setVisible("Event", true)        -- Harvest Feast is live
		menu.place(layout.flyout)             -- after HudPlacement.compute({ flyoutCount = menu.count() })
		menu.toggle(true)                     -- the MORE tile was pressed
]]

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local ClientAnalytics = require(script.Parent.Parent.Parent.Analytics.ClientAnalytics)
local Create = require(script.Parent.Parent.Create)
local GamepadNav = require(script.Parent.Parent.Parent.Platform.GamepadNav)
local HudMoreLogic = require(script.Parent.HudMoreLogic)
local HudPlacement = require(script.Parent.Parent.Widgets.HudPlacement)
local HudZonesConfig = require(ReplicatedStorage.Shared.Config.HudZonesConfig)
local OfferFx = require(script.Parent.Parent.Widgets.OfferFx)
local PlatformConfig = require(ReplicatedStorage.Shared.Config.PlatformConfig)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Widgets.StudWindow)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local Config = HudZonesConfig.MoreFlyout

-- Gamepad B closes the flyout: above ActionMap's HUD "Deselect" B (Priority.Ui), below
-- ScreenManager's modal Back (High) — a modal closes the flyout anyway.
local BACK_ACTION = "SellNukes_HudMoreBack"
local BACK_PRIORITY = PlatformConfig.Priority.Ui + 50
-- The panel's ZIndex among its MenuLayer siblings: above the stack tiles, offers and chips.
local PANEL_Z = 20
-- Rendered corner radius of the panel (design px).
local PANEL_CORNER = 10
local POP_INFO = TweenInfo.new(Config.PopSeconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

export type HudMoreMenu = {
	-- The stud panel (QA / tests find it as "HudMore").
	panel: Frame,
	-- True when `key` is a flyout row (HudZonesConfig.MoreRows).
	has: (key: string) -> boolean,
	setVisible: (key: string, visible: boolean) -> (),
	setBadge: (key: string, text: string?) -> (),
	setNew: (key: string, on: boolean) -> (),
	-- R59: smallest label text in design px (phones: 14 pt); nil = default sizing.
	setLabelFloor: (px: number?) -> (),
	button: (key: string) -> TextButton?,
	-- Visible items (HudPlacement.compute `flyoutCount`).
	count: () -> number,
	-- Applies a placement (nil = nothing to show: the flyout closes).
	place: (layout: HudPlacement.FlyoutLayout?) -> (),
	-- Re-links D-pad navigation; `baseRight` = the MORE tile's Right link while closed.
	linkNav: (baseRight: GuiObject?) -> (),
	-- Opens (focus = put the gamepad cursor on the first item; no-op without a gamepad).
	open: (focus: boolean) -> (),
	-- Closes (returnFocus = put the gamepad cursor back on MORE).
	close: (returnFocus: boolean) -> (),
	toggle: (focus: boolean) -> (),
	isOpen: () -> boolean,
	-- The MORE tile's roll-up right now (badge text or nil, any NEW).
	rollup: () -> (string?, boolean),
	-- Fires when an item's visibility changed (the HUD re-lays out: the panel size changes).
	onChanged: (callback: () -> ()) -> (),
	-- Fires when the roll-up changed (badge text, NEW).
	onRollup: (callback: (badge: string?, isNew: boolean) -> ()) -> (),
}

type Item = {
	row: HudZonesConfig.LeftRow,
	handle: StudUI.HudButton,
	visible: boolean,
	badge: string?,
	new: boolean,
	newTag: Frame?, -- the R57 NEW tag (built on first use)
}

local HudMoreMenu = {}

--[[
	Builds the yellow "NEW" stud tag of one HUD tile (owner R57; shared by the stack tiles in
	HudButtons and the flyout items): scale-sized 56 % x 26 % of the tile on its top-left corner,
	tilted a little, above the face, never selectable or blocking input. Starts hidden.
	@param button the tile's root TextButton
	@return the tag Frame (toggle its Visible)
	Example: HudMoreMenu.newTag(handle.instance).Visible = true
]]
function HudMoreMenu.newTag(button: GuiObject): Frame
	local tag = Create.new("Frame", {
		Name = "NewTag",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.16, 0.08),
		Size = UDim2.fromScale(0.56, 0.26),
		Rotation = -12,
		Active = false,
		Visible = false,
		ZIndex = 8,
		Parent = button,
		Children = { Create.new("UICorner", { CornerRadius = UDim.new(0.35, 0) }) },
	}) :: Frame
	StudWindow.surface(tag, "yellow", { edge = 3, corner = 8, zIndex = 8 })
	StudUI.text({
		text = "NEW",
		textSize = 26,
		font = "shout",
		scaled = true,
		size = UDim2.fromScale(0.9, 0.86),
		position = UDim2.fromScale(0.05, 0.07),
		zIndex = 9,
		parent = tag,
	})
	return tag
end

--[[
	Builds the flyout under `container` (the HUD's R79 MenuLayer), hidden until opened.
	@param container full-canvas frame (positions are absolute design px on the HUD canvas)
	@param anchor    the MORE tile (taps on it never count as "elsewhere"; B returns to it)
	@return HudMoreMenu handle
]]
function HudMoreMenu.new(container: Frame, anchor: TextButton): HudMoreMenu
	-- Left-centre anchor: the pop grows out of the stack side.
	local panel = Create.new("Frame", {
		Name = "HudMore",
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundColor3 = UIStyleConfig.Neutral.Body,
		-- Active: a press on the panel between tiles stays on the panel (never the world).
		Active = true,
		Visible = false,
		ZIndex = PANEL_Z,
		Size = UDim2.fromOffset(0, 0),
		Parent = container,
		Children = { Create.new("UICorner", { CornerRadius = UDim.new(0, PANEL_CORNER) }) },
	}) :: Frame
	StudWindow.edge(panel, 4)
	local studs = StudWindow.surface(panel, Config.PanelColor, {
		tile = UIStyleConfig.StudTile.Button,
		studTransparency = 0.8,
		corner = PANEL_CORNER,
		highlight = false,
	})
	studs.gradient.Color = ColorSequence.new(Config.PanelTop, UIStyleConfig.Neutral.Body)
	local scale = Create.new("UIScale", { Scale = 1, Parent = panel }) :: UIScale
	local popTween = TweenService:Create(scale, POP_INFO, { Scale = 1 })

	local items: { Item } = {}
	local byKey: { [string]: Item } = {}
	local opened = false
	local layout: HudPlacement.FlyoutLayout? = nil
	-- The MORE tile's Right link while closed (HudButtons.linkNav computes it).
	local baseRight: GuiObject? = nil
	local changed: (() -> ())? = nil
	local rolled: ((string?, boolean) -> ())? = nil
	local lastBadge: string? = nil
	local lastNew = false
	-- The last press that landed on the panel / an item / MORE (see watchInput).
	local insideInput: InputObject? = nil
	-- Watchers that exist only while the flyout is open.
	local watchers: { RBXScriptConnection } = {}
	local close: (returnFocus: boolean) -> ()

	local function markInside(input: InputObject)
		insideInput = input
	end
	panel.InputBegan:Connect(markInside)
	anchor.InputBegan:Connect(markInside)

	for index, row in HudZonesConfig.MoreRows do
		local screen = row.screen
		local handle = StudUI.hudButton({
			label = row.label,
			icon = row.icon,
			color = row.color,
			layoutOrder = index,
			name = `Hud_{row.key}`,
			onActivated = function()
				-- Exactly the old stack tile: replace the open window, or close it on a 2nd press.
				close(false)
				if ScreenManager.isOpen(screen) then
					ScreenManager.close(screen)
				else
					ScreenManager.closeAllModals()
					ScreenManager.open(screen)
				end
			end,
		})
		local visible = row.hidden ~= true
		handle.instance.Visible = visible
		handle.instance.Parent = panel
		handle.instance.InputBegan:Connect(markInside)
		local item: Item = { row = row, handle = handle, visible = visible, badge = nil, new = false }
		table.insert(items, item)
		byKey[row.key] = item
	end

	local function visibleItems(): { Item }
		local list: { Item } = {}
		for _, item in items do
			if item.visible then
				table.insert(list, item)
			end
		end
		return list
	end

	-- Recomputes the MORE roll-up; notifies only on a change.
	local function applyRollup()
		local children: { HudMoreLogic.Child } = {}
		for _, item in items do
			table.insert(children, { visible = item.visible, badge = item.badge, new = item.new })
		end
		local badge, isNew = HudMoreLogic.rollup(children)
		if badge == lastBadge and isNew == lastNew then
			return
		end
		lastBadge, lastNew = badge, isNew
		local callback = rolled
		if callback ~= nil then
			callback(badge, isNew)
		end
	end

	-- D-pad links: a grid over the visible tiles; Left of the first column -> MORE; the other
	-- outer edges link to the tile itself (linkGrid leaves them nil = the engine's geometric
	-- pick, which could wander onto the offers). MORE's Right enters the flyout while open.
	local function linkItems()
		local cells: { GuiObject } = {}
		for _, item in visibleItems() do
			table.insert(cells, item.handle.instance)
		end
		local current = layout
		GamepadNav.linkGrid(cells, if current ~= nil then current.columns else math.max(1, #cells), {
			left = anchor,
		})
		for _, cell in cells do
			-- `any` view: the NextSelection* type definitions are non-optional.
			local node: any = cell
			if node.NextSelectionUp == nil then
				node.NextSelectionUp = cell
			end
			if node.NextSelectionDown == nil then
				node.NextSelectionDown = cell
			end
			if node.NextSelectionRight == nil then
				node.NextSelectionRight = cell
			end
		end
		local moreTile: any = anchor
		moreTile.NextSelectionRight = if opened and cells[1] ~= nil then cells[1] else baseRight
	end

	-- True while the gamepad cursor is on a flyout tile (or the panel).
	local function selectionInside(): boolean
		local selected = GuiService.SelectedObject
		return selected ~= nil and selected:IsDescendantOf(panel)
	end

	-- Gamepad B while open: close and return the cursor to MORE (sunk: HUD Deselect never sees it).
	local function onBack(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
		if state ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Sink
		end
		close(true)
		return Enum.ContextActionResult.Sink
	end

	-- The watchers of an open flyout: taps elsewhere and the cursor leaving close it.
	local function watchInput()
		table.insert(
			watchers,
			UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
				local kind = input.UserInputType
				if kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch then
					return
				end
				if not processed then
					-- The press went to the world (no GUI took it): certainly not the flyout.
					insideInput = nil
					close(false)
					return
				end
				-- A GUI press: deferred, so the panel / item / MORE InputBegan of the same press has
				-- run. The marker is cleared after every check (Roblox reuses mouse InputObjects).
				task.defer(function()
					local inside = insideInput == input
					insideInput = nil
					if not inside then
						close(false)
					end
				end)
			end)
		)
		table.insert(
			watchers,
			GuiService:GetPropertyChangedSignal("SelectedObject"):Connect(function()
				local selected = GuiService.SelectedObject
				-- nil = no cursor (mouse / touch, or the gamepad went idle): taps decide then.
				if selected ~= nil and selected ~= anchor and not selected:IsDescendantOf(panel) then
					close(false)
				end
			end)
		)
	end

	-- The open pop (UIScale PopScale -> 1); Reduce Motion shows it at once.
	local function pop()
		popTween:Cancel()
		if OfferFx.reducedMotion() then
			scale.Scale = 1
			return
		end
		scale.Scale = Config.PopScale
		popTween:Play()
	end

	local function open(focus: boolean)
		local current = layout
		if opened or current == nil or ScreenManager.anyModalOpen() then
			return
		end
		opened = true
		-- A stale marker from the MORE press that opened us must never count (InputObject reuse).
		insideInput = nil
		panel.Visible = true
		pop()
		linkItems()
		watchInput()
		ContextActionService:BindActionAtPriority(BACK_ACTION, onBack, false, BACK_PRIORITY, Enum.KeyCode.ButtonB)
		ClientAnalytics.screenOpened(Config.AnalyticsScreen, Config.AnalyticsSource)
		if focus then
			local first = visibleItems()[1]
			GamepadNav.select(if first ~= nil then first.handle.instance else nil)
		end
	end

	close = function(returnFocus: boolean)
		if not opened then
			return
		end
		opened = false
		for _, connection in watchers do
			connection:Disconnect()
		end
		table.clear(watchers)
		ContextActionService:UnbindAction(BACK_ACTION)
		insideInput = nil
		popTween:Cancel()
		scale.Scale = 1
		-- The cursor never stays on a hidden tile: back to MORE (B) or off (a screen takes it).
		local wasInside = selectionInside()
		panel.Visible = false
		local moreTile: any = anchor
		moreTile.NextSelectionRight = baseRight
		if returnFocus then
			GamepadNav.select(anchor)
		elseif wasInside then
			GuiService.SelectedObject = nil
		end
	end

	local function place(nextLayout: HudPlacement.FlyoutLayout?)
		layout = nextLayout
		if nextLayout == nil then
			close(false)
			return
		end
		panel.Position = UDim2.fromOffset(nextLayout.x, nextLayout.y + nextLayout.h / 2)
		panel.Size = UDim2.fromOffset(nextLayout.w, nextLayout.h)
		for index, item in visibleItems() do
			local rect = nextLayout.rects[index]
			if rect ~= nil then
				item.handle.instance.Position = UDim2.fromOffset(rect.x, rect.y)
				item.handle.setSize(rect.w, rect.h)
			end
		end
		linkItems()
	end

	-- Any menu (modal) opening or the HUD focus mode closes the flyout (R79 MenuLayer rule).
	ScreenManager.Opened:Connect(function()
		if opened and ScreenManager.anyModalOpen() then
			close(false)
		end
	end)
	ScreenManager.FocusChanged:Connect(function()
		close(false)
	end)

	return {
		panel = panel,
		has = function(key: string): boolean
			return byKey[key] ~= nil
		end,
		setVisible = function(key: string, visible: boolean)
			local item = byKey[key]
			if item == nil or item.visible == visible then
				return
			end
			item.visible = visible
			item.handle.instance.Visible = visible
			applyRollup()
			local callback = changed
			if callback ~= nil then
				callback()
			end
		end,
		setBadge = function(key: string, text: string?)
			local item = byKey[key]
			if item ~= nil then
				item.badge = text
				item.handle.setBadge(text)
				applyRollup()
			end
		end,
		setNew = function(key: string, on: boolean)
			local item = byKey[key]
			if item == nil then
				return
			end
			item.new = on
			local tag = item.newTag
			if tag == nil and on then
				tag = HudMoreMenu.newTag(item.handle.instance)
				item.newTag = tag
			end
			if tag ~= nil then
				tag.Visible = on
			end
			applyRollup()
		end,
		setLabelFloor = function(px: number?)
			for _, item in items do
				item.handle.setLabelFloor(px)
			end
		end,
		button = function(key: string): TextButton?
			local item = byKey[key]
			return if item ~= nil then item.handle.instance else nil
		end,
		count = function(): number
			return #visibleItems()
		end,
		place = place,
		linkNav = function(right: GuiObject?)
			baseRight = right
			linkItems()
		end,
		open = open,
		close = close,
		toggle = function(focus: boolean)
			if opened then
				close(focus)
			else
				open(focus)
			end
		end,
		isOpen = function(): boolean
			return opened
		end,
		rollup = function(): (string?, boolean)
			return lastBadge, lastNew
		end,
		onChanged = function(callback: () -> ())
			changed = callback
		end,
		onRollup = function(callback: (badge: string?, isNew: boolean) -> ())
			rolled = callback
		end,
	}
end

return table.freeze(HudMoreMenu)
