--!strict
--[[
	HudButtons — the HUD's left stack of stud buttons (owner R110: Shop, Pets, Quests, Rewards,
	Attack + the MORE tile; HudZonesConfig.Stack) and the MORE flyout it owns (Hud/HudMoreMenu:
	Teleport, Rebirth, the Event while it is live, Settings; HudZonesConfig.MoreRows).

	Purpose:
		Builds one StudUI.hudButton per HudZonesConfig.Stack row, then the MORE tile LAST (the
		flyout anchors on the last stack tile, HudPlacement.flyout). Each stack tile opens its
		screen through ScreenManager.open(row.screen); a screen that is not registered yet opens
		the stud "Coming soon" window (ScreenManager fallback), so no button ever does nothing.
		MORE toggles the flyout (gamepad: the cursor lands on its first item).
		Every keyed setter (setVisible / setBadge / setNew / has / button) ROUTES: a stack key to
		its tile, a key that moved into the flyout (Teleport, Rebirth, Event, Settings) to the
		flyout item — so Hud.setButtonVisible("Event", on), Hud.setButtonBadge("Event", "!") and
		Hud.setButtonNew("Teleport", on) keep working unchanged for their callers. The flyout's
		badges / NEW tags roll up onto the MORE tile (HudMoreLogic.rollup).
		Visibility per tile is decided by Hud (explicit calls, Attack's automatic unlock rule and
		the world rule that hides Attack where attacks are off); this module only applies it.
		Layout (positions / sizes) comes from Hud through `apply(layout, flyout)`; this module
		never measures the screen itself.

	Phones (owner R59): `setLabelFloor(px)` keeps every tile label (stack + flyout) at >= 14 pt on
	the 44 pt tiles (nil = the kit's default sizing). Keys without a row (the folded Daily / Time /
	LuckyWheel / Codes, R62) are ignored by every setter, so older callers stay harmless.

	NEW tag (owner R57 World 2): `setNew(key, on)` puts a small yellow "NEW" stud tag on a
	tile's top-left corner (Teleport until the first visit of an unlocked world; now a flyout
	item, so MORE wears the rolled-up tag too); the red badge (top-right) stays free for
	counts / "!". The tag is built on first use and sized in scale, so re-layouts never touch it.

	Connects to: Shared/Config/HudZonesConfig (Stack, MoreTile, MoreRows), Kit/StudUI.hudButton,
	UI/ScreenManager, Widgets/HudPlacement (layout input/output), UI/Hud/{Hud (owner),
	HudMoreMenu (the flyout + NEW tag builder)}.

	Example:
		local buttons = HudButtons.new(container)
		buttons.setVisible("Attack", true)
		buttons.setBadge("Event", "!") -- the flyout item + the MORE roll-up
		local layout = HudPlacement.compute({ wides = buttons.visibleWides(),
			flyoutCount = buttons.moreCount(), ... })
		buttons.apply(layout.left, layout.flyout)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HudMoreMenu = require(script.Parent.HudMoreMenu)
local HudPlacement = require(script.Parent.Parent.Widgets.HudPlacement)
local HudZonesConfig = require(ReplicatedStorage.Shared.Config.HudZonesConfig)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Kit.StudUI)

export type HudButtons = {
	-- Wide flags of the VISIBLE stack tiles, in order (HudPlacement.compute input; MORE last).
	visibleWides: () -> { boolean },
	-- Positions / sizes every visible stack tile from a packed left layout, and the MORE flyout
	-- from its placement (nil = no flyout layout: it closes).
	apply: (layout: HudPlacement.LeftLayout, flyout: HudPlacement.FlyoutLayout?) -> (),
	setVisible: (key: string, visible: boolean) -> (),
	setBadge: (key: string, text: string?) -> (),
	-- R59: smallest label text in design px on every tile (phones: 14 pt); nil = default sizing.
	setLabelFloor: (px: number?) -> (),
	-- True when `key` is a stack tile or a MORE flyout item.
	has: (key: string) -> boolean,
	-- R57: a yellow "NEW" tag on the tile's top-left corner (on / off).
	setNew: (key: string, on: boolean) -> (),
	-- The first visible stack tile (gamepad HudFocus target).
	first: () -> GuiObject?,
	-- The right-most tile of the top row (where the offers column exits to).
	topRight: () -> GuiObject?,
	-- Re-links D-pad navigation over the current layout; `rightExit` = the first offer.
	linkNav: (rightExit: GuiObject?) -> (),
	button: (key: string) -> TextButton?,
	-- R110: visible MORE flyout items (HudPlacement.compute `flyoutCount`).
	moreCount: () -> number,
	-- R110: the MORE flyout (open / close / isOpen; Hud.setMoreOpen, QA).
	more: () -> HudMoreMenu.HudMoreMenu,
	-- Fires when the stack or the flyout changed shape (Hud re-lays out).
	onChanged: (callback: () -> ()) -> (),
}

type Item = {
	key: string,
	wide: boolean,
	handle: StudUI.HudButton,
	visible: boolean,
	newTag: Frame?, -- the R57 NEW tag (built on first use)
}

local HudButtons = {}

--[[
	Builds every stack tile + the MORE tile and its flyout under `container` (the HUD's R79
	MenuLayer, a transparent full-canvas frame).
	@param container parent frame (positions are absolute design px on the HUD canvas)
	@return HudButtons handle
]]
function HudButtons.new(container: Frame): HudButtons
	local items: { Item } = {}
	local byKey: { [string]: Item } = {}
	-- The last applied rects of the visible tiles (for navigation links).
	local placed: { { button: TextButton, rect: HudPlacement.Rect } } = {}
	local changed: (() -> ())? = nil
	local function notifyChanged()
		local callback = changed
		if callback ~= nil then
			callback()
		end
	end
	local function addItem(key: string, wide: boolean, handle: StudUI.HudButton, visible: boolean)
		handle.instance.Visible = visible
		handle.instance.Parent = container
		local item: Item = { key = key, wide = wide, handle = handle, visible = visible }
		table.insert(items, item)
		byKey[key] = item
	end
	for index, row in HudZonesConfig.Stack do
		local screen = row.screen
		local handle = StudUI.hudButton({
			label = row.label,
			icon = row.icon,
			color = row.color,
			wide = row.wide,
			layoutOrder = index,
			name = `Hud_{row.key}`,
			onActivated = function()
				-- HUD navigation switches windows: pressing another button replaces the open one.
				if ScreenManager.isOpen(screen) then
					ScreenManager.close(screen)
				else
					ScreenManager.closeAllModals()
					ScreenManager.open(screen)
				end
			end,
		})
		addItem(row.key, row.wide == true, handle, row.hidden ~= true)
	end
	-- R110: the MORE tile, always last and always visible; it toggles the flyout.
	local moreRow = HudZonesConfig.MoreTile
	local menu: HudMoreMenu.HudMoreMenu? = nil
	local moreHandle = StudUI.hudButton({
		label = moreRow.label,
		icon = moreRow.icon,
		color = moreRow.color,
		layoutOrder = #HudZonesConfig.Stack + 1,
		name = `Hud_{moreRow.key}`,
		onActivated = function()
			local flyout = menu
			if flyout ~= nil then
				flyout.toggle(true)
			end
		end,
	})
	addItem(moreRow.key, false, moreHandle, true)
	local moreItem = byKey[moreRow.key]
	local flyout = HudMoreMenu.new(container, moreHandle.instance)
	menu = flyout
	-- The flyout's badges / NEW tags roll up onto MORE (a closed flyout still shows them).
	flyout.onRollup(function(badge: string?, isNew: boolean)
		moreHandle.setBadge(badge)
		local tag = moreItem.newTag
		if tag == nil and isNew then
			tag = HudMoreMenu.newTag(moreHandle.instance)
			moreItem.newTag = tag
		end
		if tag ~= nil then
			tag.Visible = isNew
		end
	end)
	flyout.onChanged(notifyChanged)

	local function visibleItems(): { Item }
		local list: { Item } = {}
		for _, item in items do
			if item.visible then
				table.insert(list, item)
			end
		end
		return list
	end

	return {
		visibleWides = function(): { boolean }
			local wides: { boolean } = {}
			for _, item in visibleItems() do
				table.insert(wides, item.wide)
			end
			return wides
		end,
		apply = function(layout: HudPlacement.LeftLayout, flyoutLayout: HudPlacement.FlyoutLayout?)
			table.clear(placed)
			for index, item in visibleItems() do
				local rect = layout.rects[index]
				if rect ~= nil then
					item.handle.instance.Position = UDim2.fromOffset(layout.x + rect.x, layout.y + rect.y)
					item.handle.setSize(rect.w, rect.h)
					table.insert(placed, { button = item.handle.instance, rect = rect })
				end
			end
			flyout.place(flyoutLayout)
		end,
		topRight = function(): GuiObject?
			local best: TextButton? = nil
			local bestX, bestY = -math.huge, math.huge
			for _, entry in placed do
				local r = entry.rect
				if r.y < bestY or (r.y == bestY and r.x > bestX) then
					best, bestX, bestY = entry.button, r.x, r.y
				end
			end
			return best
		end,
		linkNav = function(rightExit: GuiObject?)
			-- Same row = same top edge; up / down pick the overlapping neighbour row (nearest centre),
			-- wrapping top <-> bottom; right of a row's last tile exits to the offers column.
			for _, a in placed do
				local ra = a.rect
				local acx = ra.x + ra.w / 2
				local right: GuiObject? = nil
				local left: GuiObject? = nil
				local rightX, leftX = math.huge, -math.huge
				local below, above = math.huge, -math.huge
				local bottomRow, topRow = -math.huge, math.huge
				for _, b in placed do
					local rb = b.rect
					if b ~= a then
						if rb.y == ra.y then
							if rb.x > ra.x and rb.x < rightX then
								right, rightX = b.button, rb.x
							elseif rb.x < ra.x and rb.x > leftX then
								left, leftX = b.button, rb.x
							end
						elseif rb.y > ra.y then
							below = math.min(below, rb.y)
						else
							above = math.max(above, rb.y)
						end
					end
					bottomRow = math.max(bottomRow, rb.y)
					topRow = math.min(topRow, rb.y)
				end
				-- Nearest-centre tile on a given row.
				local function onRow(rowY: number): GuiObject?
					local pick: GuiObject? = nil
					local pickDistance = math.huge
					for _, b in placed do
						if b.rect.y == rowY and b ~= a then
							local distance = math.abs(b.rect.x + b.rect.w / 2 - acx)
							if distance < pickDistance then
								pick, pickDistance = b.button, distance
							end
						end
					end
					return pick
				end
				-- `any` view: nil (= engine geometric default) is valid for NextSelection*, but the
				-- type definitions declare them non-optional.
				local button: any = a.button
				button.NextSelectionRight = right or rightExit
				button.NextSelectionLeft = left
				button.NextSelectionDown = if below < math.huge then onRow(below) else onRow(topRow)
				button.NextSelectionUp = if above > -math.huge then onRow(above) else onRow(bottomRow)
			end
			-- R110: MORE's Right enters the flyout while it is open (else the link computed above).
			local moreButton: any = moreHandle.instance
			flyout.linkNav(moreButton.NextSelectionRight)
		end,
		setVisible = function(key: string, visible: boolean)
			local item = byKey[key]
			if item == nil then
				flyout.setVisible(key, visible) -- a MORE item (no-op for unknown keys)
				return
			end
			if item == moreItem or item.visible == visible then
				return -- MORE itself always shows (it holds Teleport / Settings)
			end
			item.visible = visible
			item.handle.instance.Visible = visible
			notifyChanged()
		end,
		setBadge = function(key: string, text: string?)
			local item = byKey[key]
			if item == nil then
				flyout.setBadge(key, text)
			elseif item ~= moreItem then
				item.handle.setBadge(text) -- MORE's badge is the flyout roll-up only
			end
		end,
		setLabelFloor = function(px: number?)
			for _, item in items do
				item.handle.setLabelFloor(px)
			end
			flyout.setLabelFloor(px)
		end,
		has = function(key: string): boolean
			return byKey[key] ~= nil or flyout.has(key)
		end,
		setNew = function(key: string, on: boolean)
			local item = byKey[key]
			if item == nil then
				flyout.setNew(key, on)
				return
			end
			if item == moreItem then
				return -- MORE's NEW tag is the flyout roll-up only
			end
			local tag = item.newTag
			if tag == nil then
				if not on then
					return
				end
				tag = HudMoreMenu.newTag(item.handle.instance)
				item.newTag = tag
			end
			(tag :: Frame).Visible = on
		end,
		first = function(): GuiObject?
			local list = visibleItems()
			return if list[1] ~= nil then list[1].handle.instance else nil
		end,
		button = function(key: string): TextButton?
			local item = byKey[key]
			if item ~= nil then
				return item.handle.instance
			end
			return flyout.button(key)
		end,
		moreCount = function(): number
			return flyout.count()
		end,
		more = function(): HudMoreMenu.HudMoreMenu
			return flyout
		end,
		onChanged = function(callback: () -> ())
			changed = callback
		end,
	}
end

return table.freeze(HudButtons)
