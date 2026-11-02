--!strict
--[[
	TouchLayout — pure geometry for touch / small-screen layouts (ported from RoBeasts wave 7,
	plus SellNukes' HUD grid fit).

	Purpose:
		Every function is pure math on numbers (no services, no Instances), so Lune tests cover it
		and every screen computes phone layouts the same way:
			pointsToDesign     device points -> design px (finger-sized targets)
			virtualPointScale  Studio virtual-viewport shrink factor
			fitRow             shrink a row of buttons to fit a width
			closeLayout        generic touch CLOSE button geometry
			windowFit          uniform scale that fits a window into the canvas
			gridFit            HUD button-column cell size + column count for the available height

	Connects to: Shared/Config/TouchUIConfig, UI/ScreenManager, UI/Widgets/ModalShell,
	UI/Widgets/HudPlacement.

	Example:
		local cell, columns = TouchLayout.gridFit(13, 2, 560, 10, 96, 132)
]]

local TouchUIConfig = require(script.Parent.Parent.Config.TouchUIConfig)

local TouchLayout = {}

-- True for a finite, strictly positive number (rejects NaN, ±inf, 0 and negatives).
local function positive(value: number): boolean
	return value == value and value > 0 and value < math.huge
end

--[[
	Design px needed so something measures at least `points` on the device.
	@param points     size in device points (e.g. TouchUIConfig.MinTapPoints)
	@param pointScale points per design px (ScreenManager.pointScale())
	@return whole design px (rounded up so the result never falls short)
	Example: TouchLayout.pointsToDesign(44, 0.62) --> 71
]]
function TouchLayout.pointsToDesign(points: number, pointScale: number): number
	local scale = if positive(pointScale) then math.max(pointScale, 0.01) else 1
	-- 1e-6 slack: 44 / 0.5 must be 88, not 89 after float noise.
	return math.ceil(points / scale - 1e-6)
end

--[[
	Shrink factor (≤ 1) that makes a virtual device viewport fit inside the real one (Studio
	layout audit: a phone-sized canvas drawn inside a smaller Studio window).
	@return 1 when the device fits (or for invalid input), otherwise min(realX/vX, realY/vY)
	Example: TouchLayout.virtualPointScale(1000, 700, 1180, 820) --> 0.847...
]]
function TouchLayout.virtualPointScale(realX: number, realY: number, virtualX: number, virtualY: number): number
	if not positive(realX) or not positive(realY) or not positive(virtualX) or not positive(virtualY) then
		return 1
	end
	return math.min(1, realX / virtualX, realY / virtualY)
end

--[[
	Shrinks a row of button widths proportionally so the row fits `available` (never below
	`minWidth`). Rows that already fit are returned unchanged (a copy).
	@param widths    authored widths
	@param fixed     width of the row's other visible items
	@param gaps      total layout padding between all items
	@param available the row's width
	@param minWidth  narrowest a button may become
	Example: TouchLayout.fitRow({ 300, 300, 270 }, 0, 36, 800, 72) --> { 262, 262, 236 }
]]
function TouchLayout.fitRow(
	widths: { number },
	fixed: number,
	gaps: number,
	available: number,
	minWidth: number
): { number }
	local result = table.clone(widths)
	local sum = 0
	for _, width in widths do
		sum += width
	end
	local room = available - fixed - gaps
	if sum <= 0 or sum <= room or not positive(available) then
		return result
	end
	local factor = math.max(room, 0) / sum
	for index, width in widths do
		result[index] = math.max(minWidth, math.floor(width * factor))
	end
	return result
end

--[[
	Generic touch CLOSE button geometry: a square ≥ MinTapPoints at the right end of the Roblox
	top-bar row (the right side of the bar is free on every platform).
	@param pointScale   points per design px
	@param topbarMinY   GuiService.TopbarInset.Min.Y (points)
	@param topbarHeight GuiService.TopbarInset.Height (points)
	@return (sizeDesign, rightInsetDesign, centerYDesign)
	Example: TouchLayout.closeLayout(0.62, 0, 58)
]]
function TouchLayout.closeLayout(pointScale: number, topbarMinY: number, topbarHeight: number): (number, number, number)
	local close = TouchUIConfig.Close
	local scale = if positive(pointScale) then pointScale else 1
	local size = TouchLayout.pointsToDesign(math.max(close.ButtonPoints, TouchUIConfig.MinTapPoints), scale)
	local barHeight = if positive(topbarHeight) then topbarHeight else close.ButtonPoints
	local minY = if topbarMinY == topbarMinY then topbarMinY else 0
	local centerY = (minY + barHeight / 2) / scale
	return size, close.RightPoints / scale, centerY
end

--[[
	The uniform scale (≤ 1) that fits a `width` x `height` window into a canvas with `margin`
	design px free on every side, never below `minFit`.
	@return fit factor in [minFit, 1]; 1 for invalid input
	Example: TouchLayout.windowFit(1000, 640, 1376, 629, 16, 0.55) --> 0.9325
]]
function TouchLayout.windowFit(
	width: number,
	height: number,
	canvasX: number,
	canvasY: number,
	margin: number,
	minFit: number
): number
	if not positive(width) or not positive(height) or not positive(canvasX) or not positive(canvasY) then
		return 1
	end
	local fit = math.min(1, (canvasX - 2 * margin) / width, (canvasY - 2 * margin) / height)
	return math.clamp(fit, math.min(minFit, 1), 1)
end

--[[
	Cell size and column count for the HUD's left button grid. `units` counts grid cells (a wide
	button counts 2). The grid starts at `columns` columns; while the cells would fall below
	`minCell` it adds a column (max 4), then picks the largest cell (≤ `maxCell`) whose rows fit
	`availableHeight` with `gap` between rows.
	@param units           total grid cells to place (wide buttons = 2)
	@param columns         preferred column count (2 on desktop, like the references)
	@param availableHeight design px available for the grid
	@param gap             design px between cells
	@param minCell         smallest acceptable cell side
	@param maxCell         largest cell side (the authored desktop size)
	@return (cell, columns)
	Example: TouchLayout.gridFit(13, 2, 560, 10, 84, 132) --> (approx 84..., 3)
]]
function TouchLayout.gridFit(
	units: number,
	columns: number,
	availableHeight: number,
	gap: number,
	minCell: number,
	maxCell: number
): (number, number)
	local count = math.max(1, math.floor(units))
	local cols = math.max(1, math.floor(columns))
	if not positive(availableHeight) then
		return maxCell, cols
	end
	local function cellFor(c: number): number
		local rows = math.ceil(count / c)
		return (availableHeight - (rows - 1) * gap) / rows
	end
	while cols < 4 and cellFor(cols) < minCell do
		cols += 1
	end
	return math.floor(math.clamp(cellFor(cols), math.min(minCell, maxCell), maxCell)), cols
end

return table.freeze(TouchLayout)
