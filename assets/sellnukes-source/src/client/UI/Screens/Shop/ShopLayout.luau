--!strict
--[[
	ShopLayout — the Shop window's responsive plan (owner R11: console and mobile are the primary
	platforms). Pure math on numbers: given the screen (design-px canvas, Roblox top bar, margin,
	device points per design px, touch or not) it answers

		windowSize   the window's design size: the authored 1100 x 760 on desktop / console /
		             tablet; on touch screens where that would shrink below COMPACT_BELOW_FIT
		             (phones: short landscape canvases) the window fills the usable area instead,
		             so ModalShell does not shrink it at all
		scale        the content UIScale (>= 1) that keeps, on touch screens, the smallest card
		             text >= 14 pt and the buy buttons >= 44 pt on the DEVICE
		             (points = design px x pointScale x window fit x scale)
		cardLayout   "tall" (248 x 350 cards) while a card fits the visible body height, else
		             "wide" (short 200 px cards, icon left), so a phone shows whole cards
		columns      cards per row (4 on desktop; fewer on tablets / narrow phones)
		cellSize     the grid cell (wide cards stretch to fill their row)
		contentWidth content width in content px (= design px before `scale`), for pack cards

	Purpose: one place for the numbers, so Shop/init only applies a plan and a test can check
	the math for any device.

	Connects to: Shop/ShopCard (card sizes, readability floor), Shared/Util/TouchLayout
	(windowFit, the same fit ModalShell uses), Shared/Config/{TouchUIConfig, UIStyleConfig}.

	Example:
		local plan = ShopLayout.plan({
			canvas = Vector2.new(1361, 629), usableY = 535, margin = 16, minFit = 0.55,
			pointScale = 0.62, touch = true,
		})
		print(plan.windowSize, plan.scale, plan.cardLayout, plan.columns) --> 1329x503, ~1.37, wide, 2
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ShopCard = require(script.Parent.ShopCard)
local TouchLayout = require(ReplicatedStorage.Shared.Util.TouchLayout)
local TouchUIConfig = require(ReplicatedStorage.Shared.Config.TouchUIConfig)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

export type Input = {
	canvas: Vector2, -- ScreenManager.canvasSize(gui) (design px)
	usableY: number, -- canvas height below the Roblox top bar (design px)
	margin: number, -- ModalShell margin (TouchUIConfig.Modal.TouchMargin / DesktopMargin)
	minFit: number, -- TouchUIConfig.Modal.MinFit
	pointScale: number, -- ScreenManager.pointScale() (device points per design px)
	touch: boolean, -- ScreenManager.touchTargets()
}

export type Plan = {
	windowSize: Vector2,
	compactWindow: boolean,
	fit: number,
	scale: number,
	contentWidth: number,
	cardLayout: ShopCard.CardLayout,
	columns: number,
	cellSize: Vector2,
}

local ShopLayout = {}

-- The authored window (reference look on desktop / console / tablet).
ShopLayout.DesktopSize = Vector2.new(1100, 760)
-- Touch screens whose fit for the authored window falls below this get the compact window.
local COMPACT_BELOW_FIT = 0.95
-- Compact window bounds (design px).
local COMPACT_MIN = Vector2.new(720, 400)
local COMPACT_MAX = Vector2.new(1400, 760)
-- Device minimums (owner R11 checklist).
local MIN_TEXT_POINTS = 14
local MIN_TAP_POINTS = TouchUIConfig.MinTapPoints
-- Never scale the content more than this (very small screens scroll instead).
local MAX_SCALE = 2
local MAX_COLUMNS = 4
-- Window chrome (design px): header + its dark line, body padding, the scroll bar.
local HEADER = UIStyleConfig.Window.HeaderHeight + UIStyleConfig.Window.HeaderLip
local BODY_PADDING = UIStyleConfig.Window.BodyPadding
local SCROLLBAR = 8

-- A finite, strictly positive number, else `fallback`.
local function positiveOr(value: number, fallback: number): number
	if value == value and value > 0 and value < math.huge then
		return value
	end
	return fallback
end

--[[
	The Shop layout plan for a screen (see the module header).
	@param input canvas / usable height / margin / min fit / point scale / touch
	@return Plan
	Example: see the module header
]]
function ShopLayout.plan(input: Input): Plan
	local canvas = input.canvas
	local usableY = positiveOr(input.usableY, canvas.Y)
	local function fitFor(size: Vector2): number
		return TouchLayout.windowFit(size.X, size.Y, canvas.X, usableY, input.margin, input.minFit)
	end

	-- Window: the authored size, or (touch screens it would shrink a lot) the usable area.
	local size = ShopLayout.DesktopSize
	local fit = fitFor(size)
	local compact = false
	if input.touch and fit < COMPACT_BELOW_FIT then
		size = Vector2.new(
			math.floor(math.clamp(canvas.X - 2 * input.margin, COMPACT_MIN.X, COMPACT_MAX.X)),
			math.floor(math.clamp(usableY - 2 * input.margin, COMPACT_MIN.Y, COMPACT_MAX.Y))
		)
		fit = fitFor(size)
		compact = true
	end

	-- Content scale: device points per design px inside the window = pointScale x fit.
	local points = positiveOr(input.pointScale, 1) * fit
	local scale = 1
	if input.touch then
		scale = math.max(
			1,
			MIN_TEXT_POINTS / (ShopCard.MinTextSize * points),
			MIN_TAP_POINTS / (ShopCard.ButtonHeight * points)
		)
		scale = math.min(scale, MAX_SCALE)
	end

	-- Content px available (the content frame is scaled by `scale`).
	local contentWidth = (size.X - 2 * BODY_PADDING - SCROLLBAR) / scale
	local viewHeight = (size.Y - HEADER - 2 * BODY_PADDING) / scale
	local gap = ShopCard.Gap

	-- Tall cards while one fits the visible body; otherwise the short wide cards.
	local cardLayout: ShopCard.CardLayout = if ShopCard.Height <= viewHeight then "tall" else "wide"
	local columns: number
	local cell: Vector2
	if cardLayout == "tall" then
		columns = math.clamp(math.floor((contentWidth + gap) / (ShopCard.Width + gap)), 1, MAX_COLUMNS)
		cell = Vector2.new(ShopCard.Width, ShopCard.Height)
	else
		columns = math.clamp(math.floor((contentWidth + gap) / (ShopCard.WideMinWidth + gap)), 1, MAX_COLUMNS)
		-- Stretch the cards to fill the row (never wider than WideMaxWidth, never wider than
		-- the content on a very narrow screen).
		local fill = math.floor((contentWidth - (columns - 1) * gap) / columns)
		local width = math.clamp(fill, math.min(ShopCard.WideMinWidth, math.floor(contentWidth)), ShopCard.WideMaxWidth)
		cell = Vector2.new(width, ShopCard.WideHeight)
	end

	return {
		windowSize = size,
		compactWindow = compact,
		fit = fit,
		scale = scale,
		contentWidth = math.floor(contentWidth),
		cardLayout = cardLayout,
		columns = columns,
		cellSize = cell,
	}
end

--[[
	True when two plans lay the Shop out identically (re-layout only when something changed).
	Example: if not ShopLayout.same(old, new) then apply(new) end
]]
function ShopLayout.same(a: Plan?, b: Plan): boolean
	return a ~= nil
		and a.windowSize == b.windowSize
		and math.abs(a.scale - b.scale) < 1e-3
		and a.contentWidth == b.contentWidth
		and a.cardLayout == b.cardLayout
		and a.columns == b.columns
		and a.cellSize == b.cellSize
end

return table.freeze(ShopLayout)
