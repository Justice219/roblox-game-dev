--!strict
--[[
	NavLogic — pure gamepad-navigation math (no services / Instances; Lune tests in
	tests/platform-nav.luau). Platform/GamepadNav applies the results to GuiObjects.

	Functions:
		gridLinks     NextSelection{Up,Down,Left,Right} indexes for a row-major grid (partial
		              last row, optional wrap)
		listLinks     the same for a single row / column
		scrollTarget  the new CanvasPosition (one axis) that brings an item into view with padding
		readingOrder  sort points top-to-bottom, then left-to-right (row tolerance)

	Connects to: Platform/GamepadNav.

	Example:
		local links = NavLogic.gridLinks(5, 3, false, false)
		print(links[2].down) --> 5 (the partial last row: column 2 is index 5)
]]

export type Links = { up: number?, down: number?, left: number?, right: number? }

local NavLogic = {}

--[[
	Links for `count` cells laid out row-major in `columns` columns.
		left / right   neighbours in the same row; wrapH wraps to the row's other end
		up / down      the cell in the same column; a column that is short in the partial last
		               row links down to the LAST cell instead (no dead D-pad press); wrapV wraps
		               to the top / bottom of the column
	@return one Links per cell (nil fields = no link; the engine then picks geometrically)
	Example: NavLogic.gridLinks(4, 2, true, false)[2].right --> 1
]]
function NavLogic.gridLinks(count: number, columns: number, wrapH: boolean, wrapV: boolean): { Links }
	local n = math.max(0, math.floor(count))
	local cols = math.max(1, math.floor(columns))
	local rows = math.ceil(n / cols)
	local links: { Links } = {}
	for index = 1, n do
		local row = (index - 1) // cols -- 0-based
		local col = (index - 1) % cols
		local rowStart = row * cols + 1
		local rowEnd = math.min(rowStart + cols - 1, n)
		local link: Links = {}
		if index > rowStart then
			link.left = index - 1
		elseif wrapH and rowEnd > rowStart then
			link.left = rowEnd
		end
		if index < rowEnd then
			link.right = index + 1
		elseif wrapH and rowEnd > rowStart then
			link.right = rowStart
		end
		if row > 0 then
			link.up = index - cols
		elseif wrapV and rows > 1 then
			-- Bottom-most cell of this column (the partial last row may not reach it).
			local bottom = (rows - 1) * cols + col + 1
			link.up = if bottom <= n then bottom else bottom - cols
		end
		if row < rows - 1 then
			link.down = math.min(index + cols, n)
		elseif wrapV and rows > 1 then
			link.down = col + 1
		end
		-- A single cell row never links to itself.
		if link.left == index then
			link.left = nil
		end
		if link.right == index then
			link.right = nil
		end
		if link.up == index then
			link.up = nil
		end
		if link.down == index then
			link.down = nil
		end
		links[index] = link
	end
	return links
end

--[[
	Links for a single list (vertical = a column, else a row), optional wrap.
	Example: NavLogic.listLinks(3, true, true)[1].up --> 3
]]
function NavLogic.listLinks(count: number, vertical: boolean, wrap: boolean): { Links }
	if vertical then
		return NavLogic.gridLinks(count, 1, false, wrap)
	end
	return NavLogic.gridLinks(count, math.max(1, count), wrap, false)
end

--[[
	One axis of a scroll-follow: the CanvasPosition that shows the item [itemStart,
	itemStart + itemSize] (canvas coordinates) inside the window with `pad` free, moving as
	little as possible, clamped to the scrollable range. Items larger than the window align to
	their start.
	@param itemStart  item offset from the canvas origin (absolute px)
	@param itemSize   item size (absolute px)
	@param current    current CanvasPosition on this axis
	@param window     AbsoluteWindowSize on this axis
	@param canvas     AbsoluteCanvasSize on this axis
	@param pad        px kept between the item and the window edge
	@return the new CanvasPosition (== current when already visible)
	Example: NavLogic.scrollTarget(900, 100, 0, 400, 2000, 20) --> 620
]]
function NavLogic.scrollTarget(
	itemStart: number,
	itemSize: number,
	current: number,
	window: number,
	canvas: number,
	pad: number
): number
	local maxScroll = math.max(0, canvas - window)
	local target = current
	-- Too big for the window, or above the visible part: align its start (minus pad).
	if itemSize + 2 * pad >= window or itemStart - pad < current then
		target = itemStart - pad
	elseif itemStart + itemSize + pad > current + window then
		target = itemStart + itemSize + pad - window
	end
	return math.clamp(target, 0, maxScroll)
end

--[[
	Indexes of `points` in reading order: rows top-to-bottom (points whose y differ by less than
	`tolerance` share a row), then left-to-right.
	Example: NavLogic.readingOrder({ {x=200,y=10}, {x=10,y=12}, {x=10,y=200} }, 8) --> { 2, 1, 3 }
]]
function NavLogic.readingOrder(points: { { x: number, y: number } }, tolerance: number): { number }
	-- Two passes keep the comparators strict weak orders (a tolerance inside one comparator is
	-- not transitive and can break table.sort): sort by y, cut rows where the gap to the row's
	-- first point reaches `tolerance`, then sort each row by x.
	local byY: { number } = {}
	for index in points do
		table.insert(byY, index)
	end
	table.sort(byY, function(a: number, b: number): boolean
		if points[a].y ~= points[b].y then
			return points[a].y < points[b].y
		end
		return a < b
	end)
	local order: { number } = {}
	local row: { number } = {}
	local rowY = 0
	local function flush()
		table.sort(row, function(a: number, b: number): boolean
			if points[a].x ~= points[b].x then
				return points[a].x < points[b].x
			end
			return a < b
		end)
		for _, index in row do
			table.insert(order, index)
		end
		table.clear(row)
	end
	for _, index in byY do
		if #row > 0 and points[index].y - rowY >= tolerance then
			flush()
		end
		if #row == 0 then
			rowY = points[index].y
		end
		table.insert(row, index)
	end
	flush()
	return order
end

return table.freeze(NavLogic)
