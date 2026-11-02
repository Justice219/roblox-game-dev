--!strict
--[[
	HubLayout — pure geometry + gamepad links of the Rewards hub's tiles (owner R62), so the
	screen only writes properties and Lune can prove the layout (tests/rewards-hub.luau).

	Arrangements (RewardsHubConfig.Modes; ResponsiveModal picks one):
		"grid"  rows of up to ceil(n / 2) tiles, each row centred (5 tiles = 3 + 2); the block is
		        centred vertically (desktop / console / tablet)
		"row"   every tile in one row, top-aligned (landscape phones: the bottom thumbstick / jump
		        corners stay as clear as the window allows)
	Every tile = a square stud button (the HUD tile look, side `side`) above a status pill. The
	button side is the largest square that fits the tile column and the row height minus the pill,
	never below RewardsHubConfig.Layout.MinSide or the device's tap minimum. On touch the pill is
	tall enough for two lines at the 14 pt minimum, so long lines wrap instead of shrinking.

	Gamepad links (`links`): left / right walk the row; up / down go to the tile in the next row
	whose centre is nearest (ties → the lower index), so a centred short row still links sensibly.
	The first row's "up" is left nil here: the screen sends it to the window's close button.

	Lives inside Screens/RewardsHub (a ModuleScript folder), so UIController never registers it.

	Connects to: Shared/Config/RewardsHubConfig (Layout metrics). Used by Screens/RewardsHub.

	Example:
		local placement = HubLayout.place("grid", 1048, 599, 5, 0, 0)
		print(placement.tiles[1].side, placement.tiles[4].frame.x)
		local links = HubLayout.links(placement) -- links[4].up --> 2 (nearest centre above)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RewardsHubConfig = require(ReplicatedStorage.Shared.Config.RewardsHubConfig)

export type Rect = { x: number, y: number, width: number, height: number }

export type TilePlace = {
	frame: Rect, -- the tile holder inside the window body (design px)
	side: number, -- the square button side (top-centred in the holder)
	pill: Rect, -- the status pill, relative to the holder
	textSize: number, -- status text size cap
	minText: number, -- status text floor (0 = the kit default)
}

export type Placement = {
	mode: string,
	rows: { { number } }, -- tile indices per row, in visual order
	tiles: { TilePlace },
}

export type Link = { left: number?, right: number?, up: number?, down: number? }

local HubLayout = {}

--[[
	Tile indices per row for `mode`: "row" = one row; otherwise rows of ceil(count / 2) (5 → 3 + 2,
	4 → 2 + 2, 3 or fewer → one row).
	@param mode  "grid" | "row" (unknown → "grid")
	@param count number of tiles (≥ 0)
	@return { { index } }
	Example: HubLayout.rows("grid", 5) --> { { 1, 2, 3 }, { 4, 5 } }
]]
function HubLayout.rows(mode: string, count: number): { { number } }
	local n = math.max(0, math.floor(count))
	local perRow = if mode == "row" or n <= 3 then math.max(1, n) else math.ceil(n / 2)
	local rows: { { number } } = {}
	for index = 1, n do
		local row = (index - 1) // perRow + 1
		local list = rows[row]
		if list == nil then
			list = {}
			rows[row] = list
		end
		table.insert(list, index)
	end
	return rows
end

--[[
	Places `count` tiles inside a window body of `width` x `height` design px.
	@param mode    "grid" | "row"
	@param width   body inner width (ResponsiveModal Layout.area.X)
	@param height  body inner height (Layout.area.Y)
	@param count   number of tiles
	@param tap     smallest tap side in design px (Layout.tap; 0 = none)
	@param minText smallest text size in design px (Layout.minText; 0 = none)
	@return Placement
	Example: HubLayout.place("row", 1208, 309, 5, 71, 23).tiles[5].frame
]]
function HubLayout.place(
	mode: string,
	width: number,
	height: number,
	count: number,
	tap: number,
	minText: number
): Placement
	local cfg = RewardsHubConfig.Layout
	local rows = HubLayout.rows(mode, count)
	local oneRow = mode == "row"
	local gap = if oneRow then cfg.RowGap else cfg.Gap
	local floorText = math.max(0, if minText == minText then minText else 0)
	local floorTap = math.max(0, if tap == tap then tap else 0)
	local columns = 1
	for _, row in rows do
		columns = math.max(columns, #row)
	end
	local rowCount = math.max(1, #rows)
	-- Status text: the authored size, never below the readable floor.
	local textSize = math.max(cfg.StatusText, math.ceil(floorText))
	-- Pill: one authored line, or (touch floor set) two floor-sized lines so long text wraps
	-- ("Coming soon!" -> "Coming / soon!" on a six-tile phone row) instead of being cut.
	local lines = if floorText > 0 then 2 else 1
	local pillHeight = math.max(cfg.StatusHeight, math.ceil(lines * floorText * cfg.PillLineHeight + 2 * cfg.PillPad))
	local tileWidth = math.max(1, math.floor((width - (columns - 1) * gap) / columns))
	local rowHeight = math.max(1, math.floor((height - (rowCount - 1) * gap) / rowCount))
	local side = math.floor(math.min(tileWidth, rowHeight - cfg.StatusGap - pillHeight))
	side = math.max(side, cfg.MinSide, math.ceil(floorTap))
	local tileHeight = side + cfg.StatusGap + pillHeight
	local pillWidth = math.min(tileWidth, math.floor(side * cfg.PillWidthRatio))
	local blockHeight = rowCount * tileHeight + (rowCount - 1) * gap
	local top = if oneRow then 0 else math.max(0, math.floor((height - blockHeight) / 2))
	local tiles: { TilePlace } = {}
	for r, row in rows do
		local rowWidth = #row * tileWidth + (#row - 1) * gap
		local left = math.floor((width - rowWidth) / 2)
		local y = top + (r - 1) * (tileHeight + gap)
		for c, index in row do
			tiles[index] = {
				frame = { x = left + (c - 1) * (tileWidth + gap), y = y, width = tileWidth, height = tileHeight },
				side = side,
				pill = {
					x = math.floor((tileWidth - pillWidth) / 2),
					y = side + cfg.StatusGap,
					width = pillWidth,
					height = pillHeight,
				},
				textSize = textSize,
				minText = floorText,
			}
		end
	end
	return { mode = mode, rows = rows, tiles = tiles }
end

-- The kit's smallest text in rendered px (StudUI.text's own UITextSizeConstraint floor).
local KIT_MIN_TEXT = 10
-- The readable minimum on touch in rendered px. A UITextSizeConstraint counts RENDERED px, and
-- on phones / tablets those are device points, so 14 here IS the platform's 14 pt rule.
local TOUCH_MIN_TEXT = 14

--[[
	The status label's UITextSizeConstraint sizes for a placed tile. A UITextSizeConstraint counts
	RENDERED px (AbsoluteSize units = device points on touch), while every HubLayout number is
	DESIGN px. R78 fix: the floor used to be the raw design-px `minText` (~23 on a phone, i.e.
	14 pt), which acted as 23 pt, so a wrapped status could not shrink into its two-line pill and
	its second line was cut ("CLAIM" / "Coming" / "Next in 6h"). The floor is now the 14 pt rule
	itself on touch (the kit's 10 px otherwise); the cap stays the authored size (the pill box is
	what limits it, unchanged from the reference look on desktop / console).
	@param tile  a TilePlace from HubLayout.place (textSize in design px; minText > 0 = touch)
	@return (maxTextSize, minTextSize) in rendered px
	Example: HubLayout.textLimits(phoneTile) --> 30, 14 ; HubLayout.textLimits(desktopTile) --> 30, 10
]]
function HubLayout.textLimits(tile: TilePlace): (number, number)
	local maxSize = math.max(KIT_MIN_TEXT, math.floor(tile.textSize))
	local minSize = if tile.minText > 0 then TOUCH_MIN_TEXT else KIT_MIN_TEXT
	return maxSize, math.min(maxSize, minSize)
end

-- The tile in `row` whose horizontal centre is nearest `x` (ties → the lower index).
local function nearest(placement: Placement, row: { number }, x: number): number?
	local best: number? = nil
	local bestDistance = math.huge
	for _, index in row do
		local frame = placement.tiles[index].frame
		local distance = math.abs(frame.x + frame.width / 2 - x)
		if distance < bestDistance - 0.5 then
			best = index
			bestDistance = distance
		end
	end
	return best
end

--[[
	Gamepad neighbours of every tile (see the module header).
	@param placement from HubLayout.place
	@return { [index]: Link }
	Example: HubLayout.links(HubLayout.place("grid", 1048, 599, 5, 0, 0))[3].down --> 5
]]
function HubLayout.links(placement: Placement): { [number]: Link }
	local links: { [number]: Link } = {}
	local rows = placement.rows
	for r, row in rows do
		for c, index in row do
			local frame = placement.tiles[index].frame
			local centre = frame.x + frame.width / 2
			local above = rows[r - 1]
			local below = rows[r + 1]
			links[index] = {
				left = row[c - 1],
				right = row[c + 1],
				up = if above ~= nil then nearest(placement, above, centre) else nil,
				down = if below ~= nil then nearest(placement, below, centre) else nil,
			}
		end
	end
	return links
end

return table.freeze(HubLayout)
