--!strict
--[[
	FeedCardMetrics — PURE sizing of the owner R122 small non-modal cards (UI/Screens/DealCard and
	UI/Screens/InviteMoment): art on the left, a title + a short line beside it, a row of stud
	buttons along the bottom.

	Why a helper: the cards are drawn at a fit scale (UIScale) chosen from the space the bottom-left
	feed column has (Widgets/PopupQueue.feedArea) or the space beside a HUD chip. On a phone that fit
	can be < 1, and owner R11 still wants text >= 14 pt and taps >= 44 pt. So the card's design
	sizes grow by 1 / fit where a floor would be broken (text, button height), and the card grows
	taller to hold them. tests/purchase-focus.luau proves the floors hold at every fit.

		compute(spec, fit, floors)   the design-px layout at a given fit
		fit(spec, width, room, minFit, floors)
		                             the largest fit (<= 1, >= minFit) at which the card fits
		                             `width` x `room` design px (re-computing the floors at that fit)

	Connects to: UI/Screens/{DealCard, InviteMoment}, Widgets/PopupQueue (feed area), Shared/Config/
	{PurchaseFocusConfig.DealCard, InviteConfig.Moment} (the specs), tests/purchase-focus.luau.

	Example:
		local m = FeedCardMetrics.compute(spec, 0.8, { text = 23, tap = 71 })
		print(m.height, m.buttonHeight) -- the card height and button height in card px
]]

export type Spec = {
	width: number, -- card width (design px at fit 1)
	artSize: number, -- square art on the left
	titleSize: number, -- title text size
	lineSize: number, -- body line text size (the smallest text)
	lineRows: number, -- body lines reserved (wrap)
	buttonHeight: number, -- bottom row button height
	pad: number, -- inner padding
	gap: number, -- gap between blocks
}

-- Floors in design px on THIS device (0 = none): 14 pt text and the 44 pt tap.
export type Floors = { text: number, tap: number }

export type Metrics = {
	width: number,
	height: number,
	titleSize: number,
	lineSize: number,
	titleHeight: number,
	lineHeight: number, -- the body block (lineRows lines)
	buttonHeight: number,
	artSize: number,
	textX: number, -- left edge of the title / line column
	buttonY: number, -- top of the bottom button row
	upper: number, -- height of the art / text block above the buttons
	pad: number,
	gap: number,
	fit: number,
}

local FeedCardMetrics = {}

-- Line height per text size (font ascent + descent of the stud fonts, generous).
local LINE = 1.2

--[[
	The design-px layout of a card drawn at `fit` (text and buttons grown so that, once scaled by
	`fit`, they still meet `floors`).
	@param spec   the card's design sizes at fit 1
	@param fit    the UIScale the card is drawn at (0 < fit <= 1)
	@param floors design-px floors on this device (0 = none)
	@return Metrics (card px, i.e. before the fit scale)
]]
function FeedCardMetrics.compute(spec: Spec, fit: number, floors: Floors): Metrics
	local scale = if fit == fit and fit > 0 then math.min(fit, 1) else 1
	local titleSize = math.max(spec.titleSize, math.ceil(floors.text / scale))
	local lineSize = math.max(spec.lineSize, math.ceil(floors.text / scale))
	local buttonHeight = math.max(spec.buttonHeight, math.ceil(floors.tap / scale))
	local titleHeight = math.ceil(titleSize * LINE)
	local lineHeight = math.ceil(lineSize * LINE * spec.lineRows)
	local textBlock = titleHeight + spec.gap + lineHeight
	local upper = math.max(spec.artSize, textBlock)
	local height = spec.pad + upper + spec.gap + buttonHeight + spec.pad
	return {
		width = spec.width,
		height = height,
		titleSize = titleSize,
		lineSize = lineSize,
		titleHeight = titleHeight,
		lineHeight = lineHeight,
		buttonHeight = buttonHeight,
		artSize = spec.artSize,
		textX = spec.pad + spec.artSize + spec.gap,
		buttonY = spec.pad + upper + spec.gap,
		upper = upper,
		pad = spec.pad,
		gap = spec.gap,
		fit = scale,
	}
end

--[[
	The largest fit in [minFit, 1] at which the card fits `width` x `room` design px, with its
	metrics at that fit. When even minFit does not fit, minFit is used (the card then overhangs a
	little; callers place it from the bottom so it never covers the thumbs).
	@return Metrics (its `fit` is the chosen fit)
	Example: FeedCardMetrics.fit(spec, 460, 300, 0.62, { text = 0, tap = 0 }).fit --> <= 1
]]
function FeedCardMetrics.fit(spec: Spec, width: number, room: number, minFit: number, floors: Floors): Metrics
	local low = math.clamp(if minFit == minFit then minFit else 1, 0.05, 1)
	local function fits(fit: number): (boolean, Metrics)
		local metrics = FeedCardMetrics.compute(spec, fit, floors)
		return metrics.width * fit <= width + 1e-6 and metrics.height * fit <= room + 1e-6, metrics
	end
	local ok, metrics = fits(1)
	if ok then
		return metrics
	end
	-- Shrinking the fit grows the floored sizes, so search instead of dividing: 24 halvings of
	-- [low, 1] pin the largest fitting fit to well under a pixel.
	local okLow, lowMetrics = fits(low)
	if not okLow then
		return lowMetrics
	end
	local lo, hi = low, 1
	local best = lowMetrics
	for _ = 1, 24 do
		local mid = (lo + hi) / 2
		local good, candidate = fits(mid)
		if good then
			lo = mid
			best = candidate
		else
			hi = mid
		end
	end
	return best
end

return table.freeze(FeedCardMetrics)
