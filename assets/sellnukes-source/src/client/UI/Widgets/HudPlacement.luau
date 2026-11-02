--!strict
--[[
	HudPlacement — where the HUD zones go on the current canvas (rebuilt for SellNukes from the
	RoBeasts HudPlacement idea: one place computes every HUD position, screens just apply it).

	Purpose:
		The HUD must fit a 1920x1080 desktop, a 1360x630-design-px landscape phone (with Roblox's
		thumbstick bottom-left and jump button bottom-right) and a 10-foot console alike. The
		functions here are PURE (numbers in, rects out) so every rule is testable and the HUD
		screens stay simple:
			packLeft(...)   packs the left stud-button grid (square buttons + wide Lucky Wheel)
			               into rows, choosing the column count and cell size that fit
			rightColumn(...) how many starburst offer slots fit, and their size
			compute(input)  the full Layout for one canvas (left grid, right column, top stack,
			                bottom chip)

	Rules (desktop / phone):
		- Left grid: 2 columns at up to UIStyleConfig.Hud.ButtonSize (references); if the cells
		  would fall under MinButtonSize, add columns (max 4). Vertically centred in its band.
		- Touch devices keep the bottom TouchBottomReserve px clear on both sides (thumbstick /
		  jump button) and let the left grid start right under the Roblox top bar (the chat
		  window is collapsed by default on phones; on desktop the grid starts lower, clear of the
		  chat window). Touch placement tries, in order (QA 2026-10-30, tests/hud-cluster):
		    1. beside the currency stack (left of the Top zone) at >= MinButtonSize,
		    2. beside it with cells down to the 44 pt tap (minTap),
		    3. below the currency stack at >= MinButtonSize (up to TouchMaxColumns columns),
		    4. below it at minTap (last resort).
		  The first that fits both the band height and the width budget wins, so a small phone
		  never slides the grid under the cash counter or into the thumbstick ring.
		- Right column: as many slots as fit (max = offers); HudOffers rotates the rest.
		- Bottom-right corner (optional `corner` input, owner R58): the WHAT'S NEW chip, under the
		  right column, above the jump-button reserve on touch; the column's band shrinks for it.
		- Top-right admin chip (optional `chip` input, owner R62): a small square right under the
		  top bar at the side margin; the offer column starts below it.
		- Top-right INVITE button (optional `invite` input, owner R122): on the same row, LEFT of
		  the admin chip (or at the side margin without one); when that row would reach the
		  currency stack (a narrow canvas) it stacks under the chip instead. The offer column
		  starts below both (`inviteRect`).
		- PHONES (owner R59 + R62's six buttons, input `phone`; HudZonesConfig.Phone):
		  computePhone packs the stack as a compact Phone.Columns-wide grid pinned to the
		  top-left corner right under the top bar, tiles exactly the 44 pt tap tall and
		  Phone.TileWidthRatio wide (labels >= 14 pt), with smaller offers (Phone.OfferScale) and
		  the corner chip (an icon-only WHAT'S NEW on phones). Tablets / desktop / console keep
		  the classic layout.
		- MORE flyout (owner R110, optional input `flyoutCount`; HudZonesConfig.MoreFlyout):
		  `flyout(...)` places the HudMoreMenu stud panel BESIDE the stack (right of the grid),
		  its first tile row level with the MORE tile (the last stack tile), tiles the MORE tile's
		  own size and the stack's gap (so >= 44 pt on touch, >= MinButtonSize elsewhere). Shapes
		  tried: one row, two rows, one column; the first that fits on the canvas (under the top
		  bar, above the thumbs / bottom margin) without covering the currency stack, the offer
		  column, the objective chip, WHAT'S NEW or the admin chip wins, nearest to level.

	Connects to: Shared/Config/{UIStyleConfig, HudZonesConfig}, UI/Hud/* (apply the layout),
	Widgets/HudZones (publishes the zone rects).

	Example:
		local layout = HudPlacement.compute({
			canvas = Vector2.new(1920, 1080), safeTop = 58, wides = { false, false, true },
			offerCount = 6, touch = false,
		})
		print(layout.left.cell, layout.right.slots)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HudZonesConfig = require(ReplicatedStorage.Shared.Config.HudZonesConfig)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

export type Rect = { x: number, y: number, w: number, h: number }

export type LeftLayout = {
	rects: { Rect }, -- one per input item, in order (relative to the grid origin)
	cell: number,
	columns: number,
	width: number,
	height: number,
	x: number, -- grid origin on the canvas
	y: number,
}

export type RightLayout = {
	slot: number, -- slot side (design px)
	slots: number, -- how many offers are shown at once
	x: number, -- column centre x on the canvas
	y: number, -- first slot top
	gap: number,
}

export type Layout = {
	canvas: Vector2,
	left: LeftLayout,
	right: RightLayout,
	topY: number, -- the currency stack's top edge
	bottomY: number, -- the objective chip's bottom edge
	bottomMaxWidth: number,
	-- The bottom-right WHAT'S NEW chip (owner R58: "put it in like the bottom right"), when the
	-- input asked for one: right-aligned at the side margin, its bottom on the same line the
	-- right column's band ends (desktop: the bottom margin; touch: just above the jump button /
	-- thumbstick reserve, so it never sits under a thumb). The offer column's band gives up its
	-- height + Gap, so the two never overlap.
	corner: Rect?,
	-- The top-right admin wrench chip (owner R62), when the input asked for one.
	chip: Rect?,
	-- The top-right INVITE button (owner R122), when the input asked for one.
	invite: Rect?,
	-- Owner R123: the top-right area reserved for Roblox's player list (desktop), when the input
	-- asked for one; the chip / INVITE row and the offer column keep clear of it.
	playerList: Rect?,
	-- The MORE flyout (owner R110), when the input asked for one (`flyoutCount` > 0).
	flyout: FlyoutLayout?,
}

-- Owner R110: the MORE flyout panel on the canvas + its tiles (relative to the panel origin).
export type FlyoutLayout = {
	x: number,
	y: number,
	w: number,
	h: number,
	rects: { Rect }, -- one per visible flyout item, in order (relative to the panel origin)
	columns: number,
	rows: number,
}

-- Owner R110: what `HudPlacement.flyout` needs (all design px on the canvas).
export type FlyoutInput = {
	canvas: Vector2,
	grid: Rect, -- the stack's bounding box on the canvas
	anchor: Rect, -- the MORE tile on the canvas (tiles take its size)
	count: number, -- visible flyout items
	gap: number, -- the stack's gap (between tiles and between grid and panel)
	pad: number, -- panel padding around the tiles
	top: number, -- the panel never starts above this (under the Roblox top bar)
	bottom: number, -- ... nor ends below this (thumbs reserve / bottom margin)
	right: number, -- ... nor past this x
	avoid: { Rect }, -- HUD rects it must not cover (currency stack, offers, chips)
}

export type Input = {
	canvas: Vector2,
	safeTop: number, -- design px hidden by the Roblox top bar
	wides: { boolean }, -- visible left items in order (true = wide)
	offerCount: number,
	touch: boolean, -- touch device (thumbstick / jump button reserve)
	-- Design px the Roblox jump button / thumbstick ring need above the bottom edge on THIS
	-- device (Hud derives it from Platform/LayoutLogic.jumpRect); nil = TouchBottomReserve.
	touchReserve: number?,
	phone: boolean?, -- phones cap the objective chip (PhoneObjectiveMax) so it wraps instead
	-- Touch: design px of a 44 pt tap on THIS device (TouchLayout.pointsToDesign(MinTapPoints,
	-- pointScale)). When the MinButtonSize grid does not fit, cells may shrink down to it.
	minTap: number?,
	-- Size (design px) of the bottom-right WHAT'S NEW chip (Hud/HudWhatsNew, owner R58); nil = no
	-- chip (the right column keeps the whole band, the old layout exactly).
	corner: Vector2?,
	-- Size (design px) of the top-right admin chip (Hud/HudAdminChip, owner R62); nil = none.
	chip: Vector2?,
	-- Size (design px) of the top-right INVITE button (Hud/HudInvite, owner R122); nil = none
	-- (invites unavailable: the old layout exactly).
	invite: Vector2?,
	-- Owner R123: size (design px, from the canvas top) of Roblox's player list in the top-right
	-- corner where it shows by default (desktop; Hud sizes it from HudZonesConfig.PlayerList and
	-- the player count); nil = not shown (touch / console / PlayerList CoreGui off). Ignored on touch.
	playerList: Vector2?,
	-- Owner R110: visible MORE flyout items (Hud/HudMoreMenu); nil / 0 = no flyout layout. The
	-- MORE tile is the LAST entry of `wides` (HudButtons always builds it last).
	flyoutCount: number?,
}

local HudPlacement = {}

-- Design px kept clear at the bottom on touch devices (Roblox thumbstick / jump button).
HudPlacement.TouchBottomReserve = 170
-- Design px each bottom corner keeps for the thumbstick / jump button on touch devices (the
-- objective chip fits between them; the HUD columns end above them).
HudPlacement.TouchCornerWidth = 280
-- Widest objective chip on phones (design px; longer objectives wrap to two lines) so B16's
-- touch-action cluster keeps room beside the jump button.
HudPlacement.PhoneObjectiveMax = 520
-- The currency stack's content box (design px), centred under topY: the widest realistic row
-- (cash icon + a 9-character amount, e.g. "$999.99Dc") and the three rows' height. Measured in
-- Studio 2026-10-30: "5.97Qi" row = 264 px wide, stack 166 px tall. Hud publishes it as the
-- "Top" zone; touch layouts keep the left grid out of it.
HudPlacement.TopZoneWidth = 400
HudPlacement.TopZoneHeight = 166
-- Most left-grid columns on touch screens: wide, short landscape phones may need a 5th / 6th
-- column before the grid would spill into the thumbstick zone (desktop keeps 4).
HudPlacement.TouchMaxColumns = 6
-- Wide (Lucky Wheel) row height as a fraction of a square cell.
HudPlacement.WideRatio = UIStyleConfig.Hud.WideHeight / UIStyleConfig.Hud.ButtonSize

-- Packs items into rows for `columns` columns. Returns the rows as lists of item indexes.
local function rowsFor(wides: { boolean }, columns: number): { { number } }
	local rows: { { number } } = {}
	local current: { number } = {}
	local used = 0
	for index, wide in wides do
		local span = if wide then math.min(2, columns) else 1
		if used + span > columns then
			table.insert(rows, current)
			current = {}
			used = 0
		end
		table.insert(current, index)
		used += span
	end
	if #current > 0 then
		table.insert(rows, current)
	end
	return rows
end

-- True when every item of `row` is wide (the row then uses the shorter wide height).
local function wideRow(row: { number }, wides: { boolean }): boolean
	for _, index in row do
		if not wides[index] then
			return false
		end
	end
	return true
end

--[[
	Packs the left grid (see the module header).
	@param wides           visible items in order (true = wide)
	@param availableHeight design px the grid may use
	@param gap             design px between cells
	@param minCell         smallest acceptable cell
	@param maxCell         largest cell
	@param maxColumns      most columns to try (default 4)
	@param maxWidth        widest the grid may be (default unlimited)
	@param minWideHeight   floor for an all-wide row's height (touch: the 44 pt tap in design px)
	@return LeftLayout with rects relative to the grid origin (x / y left at 0). It may be taller
	        or wider than allowed when even maxColumns at minCell does not fit: callers compare
	        `height` / `width` with what they offered.
]]
function HudPlacement.packLeft(
	wides: { boolean },
	availableHeight: number,
	gap: number,
	minCell: number,
	maxCell: number,
	maxColumns: number?,
	maxWidth: number?,
	minWideHeight: number?
): LeftLayout
	local ratio = HudPlacement.WideRatio
	local columnCap = math.max(2, maxColumns or 4)
	local columns = 2
	local rows = rowsFor(wides, columns)
	local cell = maxCell
	while true do
		rows = rowsFor(wides, columns)
		local units = 0
		for _, row in rows do
			units += if wideRow(row, wides) then ratio else 1
		end
		cell = if units > 0 then (availableHeight - gap * math.max(0, #rows - 1)) / units else maxCell
		-- A width budget (touch: keep left of the currency stack) caps the cell too; more
		-- columns cannot help then, so the caller falls back to another placement.
		if maxWidth ~= nil then
			cell = math.min(cell, (maxWidth - gap * (columns - 1)) / columns)
		end
		if cell >= minCell or columns >= columnCap then
			break
		end
		columns += 1
	end
	cell = math.floor(math.clamp(cell, math.min(minCell, maxCell), maxCell))
	-- A row of only wide buttons is shorter (WideRatio), but never under the tap floor.
	local wideHeight = math.max(math.floor(cell * ratio), math.min(cell, minWideHeight or 0))
	local rects: { Rect } = {}
	local y = 0
	for _, row in rows do
		local height = if wideRow(row, wides) then wideHeight else cell
		local column = 0
		for _, index in row do
			local span = if wides[index] then math.min(2, columns) else 1
			rects[index] = {
				x = column * (cell + gap),
				y = y,
				w = span * cell + (span - 1) * gap,
				h = height,
			}
			column += span
		end
		y += height + gap
	end
	local height = math.max(0, y - gap)
	return {
		rects = rects,
		cell = cell,
		columns = columns,
		width = columns * cell + (columns - 1) * gap,
		height = height,
		x = 0,
		y = 0,
	}
end

--[[
	How many starburst offer slots fit in `availableHeight`, and their size.
	@param slotOverride a fixed slot side (phones, owner R59); nil = the touch / desktop size
	@return (slot, slots)
	Example: HudPlacement.rightColumn(389, 6, true) --> (152, 2)
]]
function HudPlacement.rightColumn(
	availableHeight: number,
	offerCount: number,
	touch: boolean,
	slotOverride: number?
): (number, number)
	local hud = UIStyleConfig.Hud
	local slot = slotOverride
		or math.floor(math.clamp(hud.OfferSize * (if touch then 0.8 else 1), hud.OfferMinSize, hud.OfferSize))
	if offerCount <= 0 then
		return slot, 0
	end
	local slots = math.floor((availableHeight + hud.Gap) / (slot + hud.Gap))
	-- Owner R95 ("a lot of UI on the screen … 1-2 offers at a time"): never more than
	-- Hud.MaxOfferSlots at once; HudOffers rotates the rest through the last slot.
	return slot, math.clamp(slots, 1, math.min(offerCount, hud.MaxOfferSlots))
end

--[[
	Packs items into a grid with a FIXED column count and tile size (phones, owner R59 / R62: the
	44 pt tile never grows, so the stack stays a tight top-left block). Tiles are `tileW` x
	`tileH` (wider than tall so labels stay readable); wide items span two columns; every row is
	one tile tall.
	@return LeftLayout with rects relative to the grid origin (x / y left at 0); `cell` = tileH
	Example: HudPlacement.packFixed({ false, false, false, false, false, false }, 2, 96, 71, 6)
	         --> 3 rows of 2, 198 x 225
]]
function HudPlacement.packFixed(
	wides: { boolean },
	columns: number,
	tileW: number,
	tileH: number,
	gap: number
): LeftLayout
	local count = math.max(1, math.floor(columns))
	local rows = rowsFor(wides, count)
	local rects: { Rect } = {}
	for rowIndex, row in rows do
		local column = 0
		for _, index in row do
			local span = if wides[index] then math.min(2, count) else 1
			rects[index] = {
				x = column * (tileW + gap),
				y = (rowIndex - 1) * (tileH + gap),
				w = span * tileW + (span - 1) * gap,
				h = tileH,
			}
			column += span
		end
	end
	return {
		rects = rects,
		cell = tileH,
		columns = count,
		width = count * tileW + (count - 1) * gap,
		height = math.max(0, #rows * (tileH + gap) - gap),
		x = 0,
		y = 0,
	}
end

-- True when rects `a` and `b` overlap (shared edges do not count).
local function overlaps(a: Rect, b: Rect): boolean
	return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end

-- The currency stack's box (the "Top" zone + `gap` around it), centred at the top of the canvas.
-- The top-right row (admin chip / INVITE) never reaches into it.
local function stackRect(canvas: Vector2, gap: number): Rect
	return {
		x = canvas.X / 2 - HudPlacement.TopZoneWidth / 2 - gap,
		y = 0,
		w = HudPlacement.TopZoneWidth + gap * 2,
		h = 8 + HudPlacement.TopZoneHeight + gap,
	}
end

--[[
	Owner R123 ("leaderboard covers the invite ui"): the top-right area Roblox's player list
	(leaderboard) takes on THIS device, reserved so no HUD sits under it. Hud passes its size only
	where the list shows by default (desktop with the PlayerList CoreGui on; HudZonesConfig.PlayerList
	sizes it from the server's player count); nil elsewhere (phones / tablets / console: the old
	layout exactly). PURE.
	@param canvas the HUD canvas (design px)
	@param list   the reserved size (design px, measured from the canvas top), or nil
	@return Rect? right-aligned at the canvas edge, top at 0
	Example: HudPlacement.playerListRect(Vector2.new(1920, 1080), Vector2.new(320, 290))
	         --> { x = 1600, y = 0, w = 320, h = 290 }
]]
function HudPlacement.playerListRect(canvas: Vector2, list: Vector2?): Rect?
	if list == nil or list.X <= 0 or list.Y <= 0 then
		return nil
	end
	return { x = canvas.X - list.X, y = 0, w = list.X, h = list.Y }
end

--[[
	The top-right admin chip's rect (owner R62): right-aligned at the side margin, right under the
	top bar (+ TopReserve). nil without a chip. With Roblox's player list reserved (`list`, owner
	R123) the chip sits LEFT of it on the same row, or below it when that row would reach the
	currency stack.
	Example: HudPlacement.chipRect(Vector2.new(1920, 1080), 58, Vector2.new(64, 64))
	         --> { x = 1840, y = 68, w = 64, h = 64 }
	Example: HudPlacement.chipRect(Vector2.new(1920, 1080), 58, Vector2.new(64, 64), { x = 1600, y = 0, w = 320, h = 290 })
	         --> { x = 1524, y = 68, w = 64, h = 64 }
]]
function HudPlacement.chipRect(canvas: Vector2, safeTop: number, chip: Vector2?, list: Rect?): Rect?
	if chip == nil then
		return nil
	end
	local margins = HudZonesConfig.Margins
	local gap = UIStyleConfig.Hud.Gap
	local rect: Rect = {
		x = canvas.X - margins.Side - chip.X,
		y = safeTop + margins.TopReserve,
		w = chip.X,
		h = chip.Y,
	}
	if list ~= nil then
		-- Owner R123: left of Roblox's player list on the same top row; when that would reach the
		-- currency stack (narrow windows), right-aligned again just below the reserved list.
		rect.x = list.x - gap - chip.X
		if overlaps(rect, stackRect(canvas, gap)) then
			rect.x = canvas.X - margins.Side - chip.X
			rect.y = list.y + list.h + gap
		end
	end
	return rect
end

--[[
	The top-right INVITE button's rect (owner R122): on the admin chip's row, left of it (or at the
	side margin without a chip), tops aligned under the top bar. When that would reach the currency
	stack's box (the Top zone + Gap; only very narrow canvases) it stacks under the chip at the side
	margin instead. nil without an invite.
	@param canvas  the HUD canvas (design px)
	@param safeTop design px hidden by the Roblox top bar
	@param invite  the button's size, or nil
	@param chip    the admin chip's rect (chipRect), or nil
	@param list    Roblox's reserved player list (playerListRect, owner R123), or nil: without a chip
	               the button sits left of it; the stacked fallback starts below it
	Example: HudPlacement.inviteRect(Vector2.new(1920, 1080), 58, Vector2.new(190, 64), nil)
	         --> { x = 1714, y = 68, w = 190, h = 64 }
]]
function HudPlacement.inviteRect(canvas: Vector2, safeTop: number, invite: Vector2?, chip: Rect?, list: Rect?): Rect?
	if invite == nil then
		return nil
	end
	local margins = HudZonesConfig.Margins
	local gap = UIStyleConfig.Hud.Gap
	-- The row: the chip's (it may have moved under the player list, R123), else under the top bar.
	local top = if chip ~= nil then chip.y else safeTop + margins.TopReserve
	-- Its right edge: left of the chip, else left of Roblox's player list (R123), else the margin.
	local right = if chip ~= nil then chip.x - gap elseif list ~= nil then list.x - gap else canvas.X - margins.Side
	local rect: Rect = { x = right - invite.X, y = top, w = invite.X, h = invite.Y }
	if overlaps(rect, stackRect(canvas, gap)) then
		-- Narrow canvases: stacked under everything above it at the side margin.
		local below = top
		if chip ~= nil then
			below = math.max(below, chip.y + chip.h + gap)
		end
		if list ~= nil then
			below = math.max(below, list.y + list.h + gap)
		end
		rect = { x = canvas.X - margins.Side - invite.X, y = below, w = invite.X, h = invite.Y }
	end
	return rect
end

--[[
	Owner R110: places the MORE flyout (see the module header). PURE.
	@param input FlyoutInput (grid / MORE tile / item count / limits / rects to keep clear)
	@return FlyoutLayout, or nil with no items. When no shape fits every rule (never on the
	        tests/hud-cluster device matrix) the one-row shape is clamped onto the canvas: the
	        flyout is a transient popover drawn above the HUD, so it is still usable.
	Example: HudPlacement.flyout({ canvas = Vector2.new(1920, 1080), grid = grid, anchor = moreTile,
	         count = 4, gap = 12, pad = 10, top = 68, bottom = 1064, right = 1904, avoid = {} })
	         --> a 1 x 4 panel right of the grid, level with the MORE tile
]]
function HudPlacement.flyout(input: FlyoutInput): FlyoutLayout?
	local count = math.floor(input.count)
	if count <= 0 then
		return nil
	end
	local tileW, tileH = input.anchor.w, input.anchor.h
	local gap, pad = input.gap, input.pad
	local x = input.grid.x + input.grid.w + gap
	-- Level: the first tile row on the MORE tile's row.
	local level = input.anchor.y - pad
	-- Column counts to try: one row, two rows, one column (deduplicated, in that order).
	local shapes: { number } = {}
	for _, columns in { count, math.ceil(count / 2), 1 } do
		if table.find(shapes, columns) == nil then
			table.insert(shapes, columns)
		end
	end
	local function build(columns: number, y: number): FlyoutLayout
		local rows = math.ceil(count / columns)
		local rects: { Rect } = {}
		for index = 1, count do
			local column = (index - 1) % columns
			local row = (index - 1) // columns
			rects[index] = { x = pad + column * (tileW + gap), y = pad + row * (tileH + gap), w = tileW, h = tileH }
		end
		return {
			x = x,
			y = y,
			w = columns * tileW + (columns - 1) * gap + pad * 2,
			h = rows * tileH + (rows - 1) * gap + pad * 2,
			rects = rects,
			columns = columns,
			rows = rows,
		}
	end
	for _, columns in shapes do
		local probe = build(columns, level)
		local w, h = probe.w, probe.h
		if x + w <= input.right and h <= input.bottom - input.top then
			-- Candidate tops: level (clamped into the band), and just below / above every rect
			-- to keep clear. The valid one nearest to level wins.
			local candidates = { math.clamp(level, input.top, input.bottom - h) }
			for _, rect in input.avoid do
				table.insert(candidates, rect.y + rect.h + gap)
				table.insert(candidates, rect.y - gap - h)
			end
			local best: number? = nil
			for _, y in candidates do
				if y >= input.top and y + h <= input.bottom then
					local panel: Rect = { x = x, y = y, w = w, h = h }
					local clear = true
					for _, rect in input.avoid do
						if rect.w > 0 and rect.h > 0 and overlaps(panel, rect) then
							clear = false
							break
						end
					end
					if clear and (best == nil or math.abs(y - level) < math.abs((best :: number) - level)) then
						best = y
					end
				end
			end
			if best ~= nil then
				return build(columns, best)
			end
		end
	end
	-- Fallback (see the doc comment): one row, clamped onto the canvas.
	local fallback = build(shapes[1], level)
	fallback.x = math.max(0, math.min(fallback.x, input.canvas.X - fallback.w))
	fallback.y = math.max(0, math.min(math.max(fallback.y, input.top), input.canvas.Y - fallback.h))
	return fallback
end

--[[
	The MORE flyout for a computed layout (owner R110): anchors on the LAST stack tile and keeps
	clear of every other HUD cluster of `layout`. nil without `input.flyoutCount`.
	@param objectiveHeight the objective chip's height reserved above bottomY (design px)
]]
local function flyoutFor(
	input: Input,
	layout: Layout,
	gap: number,
	top: number,
	bottom: number,
	objectiveHeight: number
): FlyoutLayout?
	local count = input.flyoutCount or 0
	local left = layout.left
	local anchor = left.rects[#input.wides]
	if count <= 0 or anchor == nil then
		return nil
	end
	local canvas = layout.canvas
	local right = layout.right
	local stack = right.slots * right.slot + math.max(0, right.slots - 1) * right.gap
	local avoid: { Rect } = {
		-- The currency stack (Top zone), the offer column, the objective chip.
		{
			x = canvas.X / 2 - HudPlacement.TopZoneWidth / 2,
			y = layout.topY,
			w = HudPlacement.TopZoneWidth,
			h = HudPlacement.TopZoneHeight,
		},
		{ x = right.x - right.slot / 2, y = right.y, w = right.slot, h = stack },
		{
			x = canvas.X / 2 - layout.bottomMaxWidth / 2,
			y = layout.bottomY - objectiveHeight,
			w = layout.bottomMaxWidth,
			h = objectiveHeight,
		},
	}
	if layout.corner ~= nil then
		table.insert(avoid, layout.corner :: Rect)
	end
	if layout.chip ~= nil then
		table.insert(avoid, layout.chip :: Rect)
	end
	if layout.invite ~= nil then
		table.insert(avoid, layout.invite :: Rect)
	end
	return HudPlacement.flyout({
		canvas = canvas,
		grid = { x = left.x, y = left.y, w = left.width, h = left.height },
		anchor = { x = left.x + anchor.x, y = left.y + anchor.y, w = anchor.w, h = anchor.h },
		count = count,
		gap = gap,
		pad = HudZonesConfig.MoreFlyout.Pad,
		top = top,
		bottom = bottom,
		right = canvas.X - HudZonesConfig.Margins.Side,
		avoid = avoid,
	})
end

--[[
	The PHONE layout (owner R59 + R62; see the module header and HudZonesConfig.Phone).
	@param input as compute (touch + phone set)
	@return Layout
]]
function HudPlacement.computePhone(input: Input): Layout
	local hud = UIStyleConfig.Hud
	local margins = HudZonesConfig.Margins
	local phone = HudZonesConfig.Phone
	local canvas = input.canvas
	local topY = 8
	local gap = phone.Gap
	local bottomReserve = math.max(HudPlacement.TouchBottomReserve, input.touchReserve or 0)
	-- The 44 pt tap in design px (whole px, never under it); tiles are wider for their labels.
	local tileH = math.ceil(input.minTap or hud.MinButtonSize)
	local tileW = math.ceil(tileH * phone.TileWidthRatio)
	local top = input.safeTop + margins.TopReserve
	-- Phone.Columns wide unless the space left of the currency stack is narrower; more columns
	-- only if the rows would otherwise reach the thumbstick zone.
	local beside = canvas.X / 2 - HudPlacement.TopZoneWidth / 2 - hud.Gap - margins.Side
	local band = canvas.Y - top - bottomReserve
	local columns = phone.Columns
	local left = HudPlacement.packFixed(input.wides, columns, tileW, tileH, gap)
	while left.height > band and (columns + 1) * tileW + columns * gap <= beside do
		columns += 1
		left = HudPlacement.packFixed(input.wides, columns, tileW, tileH, gap)
	end
	left.x = margins.Side
	left.y = top
	-- Admin chip top-right (+ the R122 INVITE button beside it); the offers start under them
	-- (or right under the top bar).
	local chip = HudPlacement.chipRect(canvas, input.safeTop, input.chip)
	local invite = HudPlacement.inviteRect(canvas, input.safeTop, input.invite, chip)
	local rightTop = if chip ~= nil then chip.y + chip.h + hud.Gap else top
	if invite ~= nil then
		rightTop = math.max(rightTop, invite.y + invite.h + hud.Gap)
	end
	local slotSide = math.floor(math.clamp(hud.OfferSize * phone.OfferScale, tileH, hud.OfferSize))
	local corner = input.corner
	local cornerReserve = if corner ~= nil then corner.Y + hud.Gap else 0
	local rightBand = math.max(1, canvas.Y - rightTop - bottomReserve - cornerReserve)
	-- A short band shrinks the slot to fit, never under the tap.
	slotSide = math.max(tileH, math.min(slotSide, math.floor(rightBand)))
	local slot, slots = HudPlacement.rightColumn(rightBand, input.offerCount, true, slotSide)
	local stack = slots * slot + math.max(0, slots - 1) * hud.Gap
	local right: RightLayout = {
		slot = slot,
		slots = slots,
		x = canvas.X - margins.Side - slot / 2,
		y = rightTop + math.max(0, (rightBand - stack) / 2),
		gap = hud.Gap,
	}
	local cornerRect: Rect? = if corner ~= nil
		then {
			x = canvas.X - margins.Side - corner.X,
			y = canvas.Y - bottomReserve - corner.Y,
			w = corner.X,
			h = corner.Y,
		}
		else nil
	local layout: Layout = {
		corner = cornerRect,
		chip = chip,
		invite = invite,
		canvas = canvas,
		left = left,
		right = right,
		topY = topY,
		bottomY = canvas.Y - margins.Bottom,
		bottomMaxWidth = math.max(
			240,
			math.min(HudPlacement.PhoneObjectiveMax, canvas.X - 2 * HudPlacement.TouchCornerWidth)
		),
	}
	-- R110: the MORE flyout beside the stack, above the thumbs.
	layout.flyout = flyoutFor(input, layout, gap, top, canvas.Y - bottomReserve, hud.ObjectiveHeight)
	return layout
end

--[[
	The full HUD layout for one canvas (see the module header).
	@param input canvas / safe top / left items / offer count / touch
	@return Layout (all values in design px on the canvas)
]]
function HudPlacement.compute(input: Input): Layout
	if input.touch and input.phone == true then
		return HudPlacement.computePhone(input)
	end
	local hud = UIStyleConfig.Hud
	local margins = HudZonesConfig.Margins
	local canvas = input.canvas
	local topY = 8
	-- Touch: never under the jump button / thumbstick ring (taller on tablets: B16 matrix).
	local bottomReserve = if input.touch
		then math.max(HudPlacement.TouchBottomReserve, input.touchReserve or 0)
		else margins.Bottom
	-- Right band (first: on touch the left grid's width budget ends at the offer column).
	local rightTop = math.max(input.safeTop + margins.TopReserve, if input.touch then 0 else margins.RightTop)
	-- Owner R123: Roblox's player list (desktop) owns the top-right corner; the offer column starts
	-- below it and the chip / INVITE row moves left of it (touch / console: nil, unchanged).
	local list = if input.touch then nil else HudPlacement.playerListRect(canvas, input.playerList)
	if list ~= nil then
		rightTop = math.max(rightTop, list.y + list.h + hud.Gap)
	end
	-- The admin chip (R62) sits top-right; the offer column starts under it.
	local chip = HudPlacement.chipRect(canvas, input.safeTop, input.chip, list)
	if chip ~= nil then
		rightTop = math.max(rightTop, chip.y + chip.h + hud.Gap)
	end
	-- The R122 INVITE button sits on the chip's row (left of it); the offers start under it too.
	local invite = HudPlacement.inviteRect(canvas, input.safeTop, input.invite, chip, list)
	if invite ~= nil then
		rightTop = math.max(rightTop, invite.y + invite.h + hud.Gap)
	end
	-- The WHAT'S NEW chip sits under the right column (its height + Gap come off the band).
	local corner = input.corner
	local cornerReserve = if corner ~= nil then corner.Y + hud.Gap else 0
	local rightBand = math.max(1, canvas.Y - rightTop - bottomReserve - cornerReserve)
	local slot, slots = HudPlacement.rightColumn(rightBand, input.offerCount, input.touch)
	local stack = slots * slot + math.max(0, slots - 1) * hud.Gap
	local right: RightLayout = {
		slot = slot,
		slots = slots,
		x = canvas.X - margins.Side - slot / 2,
		y = rightTop + math.max(0, (rightBand - stack) / 2),
		gap = hud.Gap,
	}
	-- Left band: desktop keeps clear of the chat window; touch starts right under the top bar.
	local leftTop = math.max(input.safeTop + margins.TopReserve, if input.touch then 0 else margins.LeftTop)
	local chosen: LeftLayout? = nil
	if input.touch then
		-- See the header: beside the currency stack, then below it; MinButtonSize, then the
		-- 44 pt tap. The first placement that fits the band AND the width budget wins.
		local minTap = math.min(input.minTap or hud.MinButtonSize, hud.MinButtonSize)
		local besideWidth = canvas.X / 2 - HudPlacement.TopZoneWidth / 2 - hud.Gap - margins.Side
		local belowTop = math.max(leftTop, topY + HudPlacement.TopZoneHeight + hud.Gap)
		local belowWidth = canvas.X - margins.Side - slot - hud.Gap - margins.Side
		local attempts = {
			{ top = leftTop, width = besideWidth, min = hud.MinButtonSize },
			{ top = leftTop, width = besideWidth, min = minTap },
			{ top = belowTop, width = belowWidth, min = hud.MinButtonSize },
			{ top = belowTop, width = belowWidth, min = minTap },
		}
		for index, attempt in attempts do
			local band = math.max(1, canvas.Y - attempt.top - bottomReserve)
			local packed = HudPlacement.packLeft(
				input.wides,
				band,
				hud.Gap,
				attempt.min,
				hud.ButtonSize,
				HudPlacement.TouchMaxColumns,
				math.max(1, attempt.width),
				minTap
			)
			if (packed.height <= band and packed.width <= attempt.width) or index == #attempts then
				packed.x = margins.Side
				packed.y = attempt.top + math.max(0, (band - packed.height) / 2)
				chosen = packed
				break
			end
		end
	else
		local leftBand = math.max(1, canvas.Y - leftTop - bottomReserve)
		local packed = HudPlacement.packLeft(input.wides, leftBand, hud.Gap, hud.MinButtonSize, hud.ButtonSize)
		packed.x = margins.Side
		packed.y = leftTop + math.max(0, (leftBand - packed.height) / 2)
		chosen = packed
	end
	local left = chosen :: LeftLayout
	-- Desktop columns run to the bottom, so the chip fits between them; on touch the columns
	-- end above the thumbstick / jump button, so the chip fits between those instead.
	local sideWidth = if input.touch
		then HudPlacement.TouchCornerWidth
		else math.max(left.width, slot) + margins.Side * 2
	local cornerRect: Rect? = if corner ~= nil
		then {
			x = canvas.X - margins.Side - corner.X,
			y = canvas.Y - bottomReserve - corner.Y,
			w = corner.X,
			h = corner.Y,
		}
		else nil
	local layout: Layout = {
		corner = cornerRect,
		chip = chip,
		invite = invite,
		playerList = list,
		canvas = canvas,
		left = left,
		right = right,
		topY = topY,
		bottomY = canvas.Y - margins.Bottom,
		bottomMaxWidth = math.max(
			240,
			math.min(
				if input.phone then HudPlacement.PhoneObjectiveMax else hud.ObjectiveMaxWidth,
				canvas.X - 2 * sideWidth
			)
		),
	}
	-- R110: the MORE flyout beside the stack (touch: above the thumbs; desktop: the bottom margin).
	layout.flyout = flyoutFor(
		input,
		layout,
		hud.Gap,
		input.safeTop + margins.TopReserve,
		canvas.Y - bottomReserve,
		hud.ObjectiveHeight
	)
	return layout
end

return table.freeze(HudPlacement)
