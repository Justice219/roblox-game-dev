--!strict
--[[
	GamepadNav — helpers every screen builder calls so each screen is fully controller-navigable
	(owner R11 / CLAUDE.md rule 11: GuiService.SelectedObject, sensible default selection, B
	closes, scroll follows the cursor).

	API:
		GamepadNav.linkGrid(cells, columns, options?)   NextSelection links for a row-major grid
		                                                (partial last row, optional wrap, edge
		                                                exits to a tab bar / button row)
		GamepadNav.linkList(items, vertical, options?)  the same for one row / column
		GamepadNav.followScroll(scrollingFrame, pad?)   keep the selected descendant in view
		                                                (one shared SelectedObject listener)
		GamepadNav.firstSelectable(root)                first visible Selectable in reading
		                                                order (a defaultSelection helper);
		                                                elements with attribute DefaultSelect win
		GamepadNav.defaultSelection(root, preferred?)   () -> GuiObject? for ScreenHandle
		GamepadNav.select(target)                       set the cursor (gamepad mode only)
		GamepadNav.trap(container)                      SelectionGroup: the cursor cannot leave
		GamepadNav.cycler(onPrev, onNext)               LB / RB (Q / E) previous / next while
		                                                enabled — tabs, attack-target ◀ ▶

	Example (a shop screen's build):
		local cards = {}                     -- StudUI buttons in a 3-column grid
		GamepadNav.linkGrid(cards, 3, { up = tabBar[1], wrapH = true })
		GamepadNav.followScroll(window.body :: ScrollingFrame)
		local tabs = GamepadNav.cycler(prevTab, nextTab)
		return {
			onOpen = function() tabs.enable() end,
			onClose = function() tabs.disable() end,
			defaultSelection = GamepadNav.defaultSelection(window.body, cards[1]),
		}

	Performance: links are written once per layout; followScroll uses ONE GuiService listener
	for every registered frame (weak keys: a destroyed screen unregisters itself).

	Connects to: Platform/{NavLogic, ActionMap}, Controllers/InputController,
	Shared/Config/PlatformConfig, UI/Widgets/OfferFx (reduced motion), every screen.
]]

local GuiService = game:GetService("GuiService")
local TweenService = game:GetService("TweenService")

local ActionMap = require(script.Parent.ActionMap)
local InputController = require(script.Parent.Parent.Controllers.InputController)
local NavLogic = require(script.Parent.NavLogic)
local OfferFx = require(script.Parent.Parent.UI.Widgets.OfferFx)

export type GridOptions = {
	wrapH: boolean?, -- left of the first column goes to the row's last cell
	wrapV: boolean?, -- up from the first row goes to the column's bottom
	up: GuiObject?, -- exit above the first row (tab bar, header button)
	down: GuiObject?, -- exit below the last row (footer buttons)
	left: GuiObject?, -- exit left of the first column (when not wrapping)
	right: GuiObject?, -- exit right of the last column
}

export type Cycler = {
	enable: () -> (),
	disable: () -> (),
	Destroy: () -> (),
}

local GamepadNav = {}

-- Pixels kept between a followed item and the scroll window edge.
local DEFAULT_SCROLL_PAD = 16
local SCROLL_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- Rows within this many px count as one row in reading order.
local ROW_TOLERANCE = 12

--[[
	Writes NextSelection{Up,Down,Left,Right} for `cells` laid out row-major in `columns`.
	Hidden cells should be left out of `cells` (re-call after filtering / re-layout).
	@param cells   GuiObjects in visual order
	@param columns column count
	@param options wrap + exits (see GridOptions)
	Example: GamepadNav.linkGrid(dayCards, 4, { down = claimButton })
]]
function GamepadNav.linkGrid(cells: { GuiObject }, columns: number, options: GridOptions?)
	local opts: GridOptions = options or {}
	local links = NavLogic.gridLinks(#cells, columns, opts.wrapH == true, opts.wrapV == true)
	local cols = math.max(1, math.floor(columns))
	local rows = math.ceil(#cells / cols)
	for index, cell in cells do
		local link = links[index]
		local row = (index - 1) // cols
		local col = (index - 1) % cols
		local isLastInRow = index == #cells or col == cols - 1
		cell.NextSelectionLeft = (
			if link.left ~= nil then cells[link.left] elseif col == 0 then opts.left else nil
		) :: any
		cell.NextSelectionRight = (
			if link.right ~= nil then cells[link.right] elseif isLastInRow then opts.right else nil
		) :: any
		cell.NextSelectionUp = (if link.up ~= nil then cells[link.up] elseif row == 0 then opts.up else nil) :: any
		cell.NextSelectionDown = (
			if link.down ~= nil then cells[link.down] elseif row == rows - 1 then opts.down else nil
		) :: any
	end
	-- The exits lead back into the grid (first row / first cell).
	if opts.up ~= nil and #cells > 0 then
		opts.up.NextSelectionDown = cells[1]
	end
	if opts.down ~= nil and #cells > 0 then
		opts.down.NextSelectionUp = cells[(rows - 1) * cols + 1]
	end
end

--[[
	Links a single row (vertical = false) or column (vertical = true).
	Example: GamepadNav.linkList(rewardRows, true, { down = closeButton })
]]
function GamepadNav.linkList(items: { GuiObject }, vertical: boolean, options: GridOptions?)
	GamepadNav.linkGrid(items, if vertical then 1 else math.max(1, #items), options)
end

-- Registered scroll frames -> padding (weak keys: destroyed frames drop out).
local scrollFrames: { [ScrollingFrame]: number } = setmetatable({}, { __mode = "k" }) :: any
local scrollConnected = false

-- Scrolls the registered ancestor of the selection so the selection is in view.
local function onSelectionChanged()
	local selected = GuiService.SelectedObject
	if selected == nil then
		return
	end
	local node: Instance? = selected.Parent
	while node ~= nil do
		if node:IsA("ScrollingFrame") then
			local pad = scrollFrames[node]
			if pad ~= nil then
				-- CanvasPosition, AbsoluteWindowSize and AbsoluteCanvasSize are all in absolute
				-- (UIScale-applied) px (verified in Studio), like AbsolutePosition.
				local relative = selected.AbsolutePosition - node.AbsolutePosition + node.CanvasPosition
				local size = selected.AbsoluteSize
				local window = node.AbsoluteWindowSize
				local canvas = node.AbsoluteCanvasSize
				local current = node.CanvasPosition
				local x = NavLogic.scrollTarget(relative.X, size.X, current.X, window.X, canvas.X, pad)
				local y = NavLogic.scrollTarget(relative.Y, size.Y, current.Y, window.Y, canvas.Y, pad)
				local target = Vector2.new(x, y)
				if target ~= current then
					if OfferFx.reducedMotion() then
						node.CanvasPosition = target
					else
						TweenService:Create(node, SCROLL_TWEEN, { CanvasPosition = target }):Play()
					end
				end
				return
			end
		end
		node = node.Parent
	end
end

--[[
	Keeps the gamepad cursor's element visible inside `frame` (nested frames: the nearest
	registered ancestor scrolls). Roblox's own auto-scroll leaves the item flush with the edge;
	this keeps `pad` px of context and eases (instant with Reduce Motion).
	@return unregister()
	Example: GamepadNav.followScroll(window.body :: ScrollingFrame)
]]
function GamepadNav.followScroll(frame: ScrollingFrame, pad: number?): () -> ()
	scrollFrames[frame] = pad or DEFAULT_SCROLL_PAD
	if not scrollConnected then
		scrollConnected = true
		GuiService:GetPropertyChangedSignal("SelectedObject"):Connect(onSelectionChanged)
	end
	return function()
		scrollFrames[frame] = nil
	end
end

-- True when `object` and every GuiObject ancestor up to `root` is Visible.
local function shownWithin(object: GuiObject, root: Instance): boolean
	local node: Instance? = object
	while node ~= nil and node ~= root do
		if node:IsA("GuiObject") and not node.Visible then
			return false
		end
		node = node.Parent
	end
	return node == root
end

--[[
	The first visible Selectable descendant of `root` in reading order (top-to-bottom, then
	left-to-right). An element with the attribute DefaultSelect = true wins. Close buttons
	(name contains "Close") are never the default.
	Example: defaultSelection = function() return GamepadNav.firstSelectable(window.body) end
]]
function GamepadNav.firstSelectable(root: Instance): GuiObject?
	local candidates: { GuiObject } = {}
	for _, descendant in root:GetDescendants() do
		if
			descendant:IsA("GuiObject")
			and descendant.Selectable
			and string.find(descendant.Name, "Close", 1, true) == nil
			and shownWithin(descendant, root)
		then
			if descendant:GetAttribute("DefaultSelect") == true then
				return descendant
			end
			table.insert(candidates, descendant)
		end
	end
	if #candidates == 0 then
		return nil
	end
	local points: { { x: number, y: number } } = {}
	for index, candidate in candidates do
		points[index] = { x = candidate.AbsolutePosition.X, y = candidate.AbsolutePosition.Y }
	end
	return candidates[NavLogic.readingOrder(points, ROW_TOLERANCE)[1]]
end

--[[
	A ScreenHandle.defaultSelection function: `preferred` when it is shown, else the first
	selectable in `root`.
	Example: defaultSelection = GamepadNav.defaultSelection(window.body, claimButton.instance)
]]
function GamepadNav.defaultSelection(root: Instance, preferred: GuiObject?): () -> GuiObject?
	return function(): GuiObject?
		if preferred ~= nil and preferred.Selectable and preferred.Parent ~= nil and shownWithin(preferred, root) then
			return preferred
		end
		return GamepadNav.firstSelectable(root)
	end
end

--[[
	Puts the gamepad cursor on `target` — only in Gamepad mode (a finger / mouse has no cursor).
	Example: GamepadNav.select(nextCard)
]]
function GamepadNav.select(target: GuiObject?)
	if InputController.mode ~= "Gamepad" then
		return
	end
	if target == nil or (target.Selectable and target.Visible and target.Parent ~= nil) then
		GuiService.SelectedObject = target
	end
end

--[[
	Keeps the gamepad cursor inside `container` while it is selected (SelectionGroup + Stop at
	every edge), e.g. a confirm dialog drawn over another window.
	Example: GamepadNav.trap(dialog.frame)
]]
function GamepadNav.trap(container: GuiObject)
	container.SelectionGroup = true
	container.SelectionBehaviorUp = Enum.SelectionBehavior.Stop
	container.SelectionBehaviorDown = Enum.SelectionBehavior.Stop
	container.SelectionBehaviorLeft = Enum.SelectionBehavior.Stop
	container.SelectionBehaviorRight = Enum.SelectionBehavior.Stop
end

-- Enabled cyclers (the "Tabs" context is on while at least one is enabled).
local enabledCyclers: { [Cycler]: boolean } = {}

--[[
	LB / RB (Q / E on a keyboard while a menu is open) call onPrev / onNext while the cycler is
	enabled — tabbed shops, the attack target picker ◀ ▶. Enable it in onOpen, disable in
	onClose. The hint bar shows "LB RB Tabs" while one is enabled.
	@return Cycler { enable, disable, Destroy }
	Example: local tabs = GamepadNav.cycler(function() showTab(i - 1) end, function() showTab(i + 1) end)
]]
function GamepadNav.cycler(onPrev: () -> (), onNext: () -> ()): Cycler
	local on = false
	local cycler: Cycler
	local connection = InputController.ActionPressed:Connect(function(action)
		if not on then
			return
		end
		if action == "TabPrev" then
			onPrev()
		elseif action == "TabNext" then
			onNext()
		end
	end)
	local function refreshContext()
		ActionMap.setContext("Tabs", next(enabledCyclers) ~= nil)
	end
	cycler = {
		enable = function()
			on = true
			enabledCyclers[cycler] = true
			refreshContext()
		end,
		disable = function()
			on = false
			enabledCyclers[cycler] = nil
			refreshContext()
		end,
		Destroy = function()
			on = false
			enabledCyclers[cycler] = nil
			connection:Disconnect()
			refreshContext()
		end,
	}
	return cycler
end

return table.freeze(GamepadNav)
