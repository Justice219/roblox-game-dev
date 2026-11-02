--!strict
--[[
	FeedLogic — the PURE rules of the bottom-left FEED (owner R108: "can they just take up the
	bottom left?"; owner R111: "collecting goals blocks up the ui. should be a toast on the bottom
	left"). No Instances, no services: tests/popup-feed.luau runs it. The runtime pieces are
	UI/Widgets/PopupQueue (area + card slot), UI/Hud/Toasts (the stack) and
	UI/Screens/FlavorReveal (the reveal card).

	The feed is ONE column in the bottom-left corner: toasts and Big Pop pills (newest at the
	bottom, max PopupQueueConfig.Feed.MaxVisible) and, while it plays, the owner's Lucky Nuke reveal
	card under them.

	area(input)      where the column may live (design px on the HUD canvas):
	                   "below"  under the HUD's left button grid, from the bottom margin up (on
	                            touch: above the thumbstick / jump reserve);
	                   "beside" right of the grid, from the free band's top down, when "below" is
	                            too short for what must show (a phone, the reveal card).
	                 Its right edge stops short of the objective chip, the hint bar and any centre
	                 popup; when the gap left would be narrower than MinWidth the column ends above
	                 a low obstacle / starts under a high one instead. An open window is never
	                 covered: the column uses the gutter left of it, else the strip below it, else
	                 it has no room (height 0).
	pillSize(...)    one pill's width / height / lines for its measured text in a column width.
	visible(...)     which items show: newest first, within the room and MaxVisible.
	mergeKey(...)    toasts that only differ in their numbers ("Goal claimed! +10 Gems") merge;
	merge(...)       their pill reads "Goal claimed! x3 +30 Gems" (summed when every reward is a
	                 plain "+N Unit", else the latest text + " x3").

	Connects to: Shared/Config/PopupQueueConfig (Feed), UI/Widgets/{PopupQueue, PopupQueueLogic},
	UI/Hud/Toasts, UI/Screens/FlavorReveal, tests/popup-feed.luau.

	Example:
		local area = FeedLogic.area({ canvasW = 1920, canvasH = 1080, bandTop = 188,
			left = { x = 16, y = 397, w = 276, h = 420 }, obstacles = {}, need = 112, phone = false })
		--> { x = 16, top = 829, bottom = 1064, width = 560, spot = "below", fits = true }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PopupQueueConfig = require(ReplicatedStorage.Shared.Config.PopupQueueConfig)

export type Rect = { x: number, y: number, w: number, h: number }

export type AreaInput = {
	canvasW: number,
	canvasH: number,
	bandTop: number, -- first free y under the currency stack (PopupQueueLogic.band)
	left: Rect?, -- the HUD's left button grid
	obstacles: { Rect }, -- objective chip, hint bar, the centre popup (never covered)
	window: Rect?, -- the open modal window (toasts never cover its content)
	touchReserve: number?, -- touch: design px kept clear above the bottom edge (thumbstick / jump)
	need: number, -- the height the content wants (the reveal card, or MinRows pills)
	phone: boolean,
}

export type Area = {
	x: number,
	top: number,
	bottom: number,
	width: number,
	spot: "below" | "beside",
	fits: boolean, -- height >= need and width >= MinWidth
}

export type PillMetrics = {
	height: number, -- one-line pill height
	textSize: number,
	iconSize: number,
	padX: number,
	maxLines: number,
}

export type MergeState = {
	text: string, -- what the pill shows
	latest: string, -- the newest raw text
	count: number,
	sums: { [string]: number }, -- unit → summed "+N" (only while summable)
	units: { string }, -- units in first-seen order
	summable: boolean,
}

local Feed = PopupQueueConfig.Feed

local FeedLogic = {}

-- True when the vertical spans [a1, a2) and [b1, b2) overlap.
local function spans(a1: number, a2: number, b1: number, b2: number): boolean
	return a1 < b2 and b1 < a2
end

-- One candidate column at `x` from `top` down (see area()).
local function column(input: AreaInput, x: number, top: number, maxWidth: number): Area
	local bottom = if input.touchReserve ~= nil
		then input.canvasH - input.touchReserve - Feed.Gap
		else input.canvasH - Feed.Margin
	-- Pass 1 (lowest obstacle first): too little room left of it → the column ends above it (or,
	-- for an obstacle in its upper half such as a centre banner, starts under it).
	-- Horizontal tests grow the column by Gap, so it always keeps Gap from what it passes.
	local sorted = table.clone(input.obstacles)
	table.sort(sorted, function(a: Rect, b: Rect): boolean
		return a.y + a.h > b.y + b.h
	end)
	for _, obstacle in sorted do
		if
			spans(top, bottom, obstacle.y, obstacle.y + obstacle.h)
			and spans(x, x + maxWidth + Feed.Gap, obstacle.x, obstacle.x + obstacle.w)
			and obstacle.x - Feed.Gap - x < Feed.MinWidth
		then
			if obstacle.y + obstacle.h / 2 < (top + bottom) / 2 then
				top = math.max(top, obstacle.y + obstacle.h + Feed.Gap) -- above the middle: start under it
			else
				bottom = math.min(bottom, obstacle.y - Feed.Gap) -- below the middle: end above it
			end
		end
	end
	-- Pass 2: the right edge stops short of every obstacle still beside the column.
	local width = maxWidth
	for _, obstacle in sorted do
		if
			spans(top, bottom, obstacle.y, obstacle.y + obstacle.h)
			and spans(x, x + width + Feed.Gap, obstacle.x, obstacle.x + obstacle.w)
		then
			width = math.min(width, obstacle.x - Feed.Gap - x)
		end
	end
	-- An open window: its left gutter, else the strip under it, else no room.
	local window = input.window
	if
		window ~= nil
		and spans(top, bottom, window.y, window.y + window.h)
		and spans(x, x + width + Feed.Gap, window.x, window.x + window.w)
	then
		local gutter = window.x - Feed.Gap - x
		if gutter >= Feed.MinWidth then
			width = math.min(width, gutter)
		elseif window.y + window.h + Feed.Gap < bottom then
			top = math.max(top, window.y + window.h + Feed.Gap)
		else
			bottom = top
		end
	end
	bottom = math.max(bottom, top)
	return {
		x = x,
		top = top,
		bottom = bottom,
		width = math.max(0, width),
		spot = "below",
		fits = bottom - top >= input.need and width >= Feed.MinWidth,
	}
end

--[[
	Where the feed column lives right now (see the module header).
	@param input AreaInput
	@return Area
]]
function FeedLogic.area(input: AreaInput): Area
	local maxWidth = if input.phone then Feed.PhoneMaxWidth else Feed.MaxWidth
	local left = input.left
	if left == nil then
		local only = column(input, Feed.Margin, input.bandTop, maxWidth)
		return only
	end
	local below = column(input, Feed.Margin, math.max(input.bandTop, left.y + left.h + Feed.Gap), maxWidth)
	if below.fits then
		return below
	end
	local beside = column(input, left.x + left.w + Feed.Gap, input.bandTop, maxWidth)
	beside.spot = "beside"
	if beside.fits then
		return beside
	end
	-- Neither fits cleanly: the taller usable one (its content waits / shrinks inside it).
	local belowRoom = if below.width >= Feed.MinWidth then below.bottom - below.top else 0
	local besideRoom = if beside.width >= Feed.MinWidth then beside.bottom - beside.top else 0
	return if besideRoom > belowRoom then beside else below
end

--[[
	A pill's size for its single-line text width `textWidth` (measured at metrics.textSize) in a
	column `columnWidth` wide: grows to the column, then wraps (up to maxLines; the label scales
	its text down inside the last line beyond that).
	@return (width, height, lines)
	Example: FeedLogic.pillSize(300, 560, metrics) --> 300 + icon + padding, 48, 1
]]
function FeedLogic.pillSize(textWidth: number, columnWidth: number, metrics: PillMetrics): (number, number, number)
	local chrome = metrics.padX * 3 + metrics.iconSize
	local room = math.max(1, columnWidth - chrome)
	local lines = math.clamp(math.ceil(math.max(textWidth, 1) / room), 1, metrics.maxLines)
	local width = math.min(columnWidth, chrome + math.min(textWidth, room) + 4)
	local lineHeight = metrics.textSize * 1.15
	local height = metrics.height + (lines - 1) * lineHeight
	return math.ceil(width), math.ceil(height), lines
end

--[[
	Which items show, newest first: as many as fit in `room` design px (heights + RowGap between)
	and at most `maxVisible`. `heights` is oldest → newest; the result marks each index.
	@return { boolean } — shown flags in the same order
	Example: FeedLogic.visible({ 48, 48, 48 }, 104, 4) --> { false, true, true }
]]
function FeedLogic.visible(heights: { number }, room: number, maxVisible: number): { boolean }
	local shown: { boolean } = table.create(#heights, false)
	local used, count = 0, 0
	for index = #heights, 1, -1 do
		local need = heights[index] + (if count > 0 then Feed.RowGap else 0)
		if count >= maxVisible or used + need > room then
			break
		end
		used += need
		count += 1
		shown[index] = true
	end
	return shown
end

--[[
	The merge key of a toast: kind + its text with every number replaced, so "Goal claimed! +10
	Gems" and "Goal claimed! +20 Gems" merge, "Mission claimed! +10 Gems" does not.
	@param kind string
	@param text string
	@return string
]]
function FeedLogic.mergeKey(kind: string, text: string): string
	local stripped = string.gsub(text, "[%d][%d,%.]*", "#")
	return `{kind}|{stripped}`
end

-- The plain "+N Unit" rewards of a text ({ unit, amount } in order), and whether the text is
-- made only of summable rewards (no money "+$1.2K", no "a new pet" etc. after the first "+").
local function rewards(text: string): ({ { unit: string, amount: number } }, boolean)
	local list: { { unit: string, amount: number } } = {}
	local summable = string.find(text, "+", 1, true) ~= nil
	for raw in string.gmatch(text, "%+(%S+)") do
		local digits, unit = string.match(raw, "^([%d,]+)$"), nil
		if digits ~= nil then
			-- "+10 Gems": the unit is the next word.
			local pattern = "%+" .. string.gsub(raw, "%p", "%%%0") .. " (%a+)"
			unit = string.match(text, pattern)
		end
		local amount = if digits ~= nil then tonumber((string.gsub(digits, ",", ""))) else nil
		if amount == nil or unit == nil then
			summable = false
		else
			-- "Spin" / "Spins" are one unit.
			local key = string.lower(string.gsub(unit, "s$", "") :: string)
			table.insert(list, { unit = key, amount = amount })
		end
	end
	return list, summable and #list > 0
end

-- "1,234" for a whole number (merged sums).
local function commas(value: number): string
	local text = tostring(math.floor(value))
	local out = string.reverse((string.gsub(string.reverse(text), "(%d%d%d)", "%1,")))
	if string.sub(out, 1, 1) == "," then
		out = string.sub(out, 2)
	end
	return out
end

--[[
	Folds a newer same-key toast into a pill's merge state (`state` nil = the first one).
	@param state MergeState?
	@param text string — the newer raw text
	@return MergeState
	Example: merge(merge(nil, "Goal claimed! +10 Gems"), "Goal claimed! +20 Gems").text
		--> "Goal claimed! x2 +30 Gems"
]]
function FeedLogic.merge(state: MergeState?, text: string): MergeState
	local list, summable = rewards(text)
	if state == nil then
		local sums: { [string]: number } = {}
		local units: { string } = {}
		for _, reward in list do
			if sums[reward.unit] == nil then
				table.insert(units, reward.unit)
			end
			sums[reward.unit] = (sums[reward.unit] or 0) + reward.amount
		end
		return { text = text, latest = text, count = 1, sums = sums, units = units, summable = summable }
	end
	local count = state.count + 1
	local sums = table.clone(state.sums)
	local units = table.clone(state.units)
	local stillSummable = state.summable and summable
	if stillSummable then
		for _, reward in list do
			if sums[reward.unit] == nil then
				table.insert(units, reward.unit)
			end
			sums[reward.unit] = (sums[reward.unit] or 0) + reward.amount
		end
	end
	local shown: string
	local plus = string.find(text, "+", 1, true)
	if stillSummable and plus ~= nil then
		-- Rewrite each "+N Unit" of the newest text with its sum; "x3" before the first reward.
		local rewritten = string.gsub(
			string.sub(text, plus),
			"(%+[%d,]+ (%a+))",
				-- Two captures (the typedef only knows one-argument callbacks, hence the cast).
			(
					function(whole: string, unit: string): string
						local key = string.lower((string.gsub(unit, "s$", "")))
						local total = sums[key]
						if total == nil then
							return whole
						end
						-- "+1 Spin" x3 → "+3 Spins".
						local word = if total ~= 1 and string.sub(unit, -1) ~= "s" then unit .. "s" else unit
						return `+{commas(total)} {word}`
					end
				) :: any
		)
		shown = `{string.sub(text, 1, plus - 1)}x{count} {rewritten}`
	else
		shown = `{text} x{count}`
	end
	return {
		text = shown,
		latest = text,
		count = count,
		sums = sums,
		units = units,
		summable = stillSummable,
	}
end

return table.freeze(FeedLogic)
