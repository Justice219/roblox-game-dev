--!strict
--[[
	CardGrid — the shared reward-card grid of the Daily Rewards and Time Rewards windows
	(references docs/reference/ui-style/01-daily-rewards.png and 04-time-rewards.png). Every card
	is a StudUI.card with a sunburst and the same slots:

		┌──────────────┐   title    "Day 1" / a live countdown ("04:11", "11:48:16") / "Ready!"
		│    Day 1     │   icon     the reward's 3D icon (as big as the card allows)
		│   [ icon ]   │   caption  optional word under the icon ("One" .. "Seven")
		│     One      │   detail   the reward headline, small ("$1.25K + 10 Gems")
		│  $250 + ...  │   button   CLAIM (green) / LOCKED! (grey) / CLAIMED
		│ [  CLAIM  ]  │
		└──────────────┘

	Two arrangements (ResponsiveModal picks the mode; CardGrid.Modes lists the window sizes):
		"grid"  the reference: six small cards in a 3 x 2 grid + ONE big rainbow card spanning
		        both rows on the right (desktop, console, tablet)
		"row"   all seven cards in one row in a wide, short window — on a landscape phone this
		        renders unshrunk, so the buttons reach 44 pt and the text 14 pt
	`grid.layout(layout)` places everything in exact design px for the active mode and lifts
	button heights / text sizes to the layout's touch minimums (`tap`, `minText`). Inside a card
	the slots are stacked from the BOTTOM (button, detail, caption) and the icon takes the space
	that is left, capped at its authored size — so a taller button never overlaps the text.

	Gamepad (owner R11, Platform/GamepadNav): "grid" links the six small CLAIM buttons as a 3 x 2
	grid whose right edge (rows 1 and 2) leads to the big card's button, and the big button's
	left leads back to row 1; "row" links all seven as one horizontal list. Links are rewritten
	on every layout.

	Purpose: both reward windows look the same, so the geometry, the countdown-title swap and the
	button wiring live here once. The SCREENS decide what each card shows (server profile +
	shared configs); this module only draws what it is told.

	Lives inside Screens/DailyRewards (a ModuleScript folder), so UIController's screen discovery
	never registers it as a screen.

	Performance: every Instance is built ONCE; layout() and the setters only write properties
	(layout runs on open / rotation / device switch, never per frame). A card's live countdown
	exists only while that card shows one (StudUI's shared 1 Hz ticker; destroyed when the title
	goes back to static text).

	Security: display only. CLAIM calls the screen's `onClaim(index)`, which sends an intent; the
	server re-checks every claim.

	Connects to: Kit/StudUI (card, button, countdown, icon, text), Widgets/StudWindow (text
	outline on resize), Platform/GamepadNav, Screens/DailyRewards/ResponsiveModal (Layout),
	Shared/Config/UIStyleConfig. Used by Screens/DailyRewards and Screens/TimeRewards.

	Example:
		local grid = CardGrid.new({ parent = window.body, color = "sky", captions = true,
			onClaim = function(index) Remotes.event("ClaimDaily"):FireServer() end })
		grid.layout(layoutController.current())
		local first = grid.cells[1]
		first.setTitle("Day 1"); first.setIcon("Cash"); first.setCaption("One")
		first.setDetail("$250"); first.button.setState("claimed")
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Create = require(script.Parent.Parent.Parent.Create)
local GamepadNav = require(script.Parent.Parent.Parent.Parent.Platform.GamepadNav)
local ResponsiveModal = require(script.Parent.ResponsiveModal)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Parent.Widgets.StudWindow)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

-- Number of cards: 6 small + the big last one.
local SMALL_COUNT = 6
local CARD_COUNT = SMALL_COUNT + 1
-- Columns of small cards in the "grid" mode.
local GRID_COLUMNS = 3
-- Gap between cards (design px) and the big card's width as a multiple of a small card's.
local GAP = 12
local BIG_WIDTH_RATIO = 1.2
-- How far (fraction of the icon size) the caption overlaps the icon's foot (reference look).
local CAPTION_OVERLAP = 0.12
-- Smallest icon side ever drawn (design px), even on the tightest layout.
local MIN_ICON = 40
-- Vertical gap between stacked slots (design px).
local SLOT_GAP = 4
-- Button bottom inset: keeps its 3D lip + outline inside the card.
local BUTTON_BOTTOM = UIStyleConfig.Button.Lip + UIStyleConfig.Button.Edge
-- A countdown re-target closer than this to the current target is ignored (no reset churn).
local RETARGET_EPSILON = 0.5

-- Authored slot sizes (design px) per arrangement and card size; touch minimums lift them.
type Metrics = {
	title: number, -- title / countdown text size
	icon: number, -- largest icon side
	caption: number, -- caption text size
	detail: number, -- detail (reward headline) max text size
	detailLines: number, -- lines the detail may wrap to
	button: number, -- button height
	buttonInset: number, -- button width = card content width - inset
}

local METRICS: { [string]: { small: Metrics, big: Metrics } } = {
	grid = {
		small = {
			title = 36,
			icon = 84,
			caption = 32,
			detail = 20,
			detailLines = 1,
			button = 50,
			buttonInset = 8,
		},
		big = {
			title = 56,
			icon = 190,
			caption = 56,
			detail = 26,
			detailLines = 3,
			button = 68,
			buttonInset = 28,
		},
	},
	row = {
		small = {
			title = 34,
			icon = 96,
			caption = 30,
			detail = 20,
			detailLines = 2,
			button = 56,
			buttonInset = 8,
		},
		big = {
			title = 44,
			icon = 150,
			caption = 36,
			detail = 22,
			detailLines = 3,
			button = 60,
			buttonInset = 16,
		},
	},
}

export type Cell = {
	index: number,
	big: boolean,
	card: StudUI.Card,
	button: StudUI.Button,
	-- Static title text (removes a live countdown title).
	setTitle: (text: string) -> (),
	-- Live countdown title to the server time `endsAt`; `onFinished` fires once at 0 (on
	-- StudUI's ticker thread: callers should only DEFER work from it).
	setCountdown: (endsAt: number, format: StudUI.CountdownFormat, onFinished: (() -> ())?) -> (),
	setIcon: (key: string) -> (),
	setCaption: (text: string) -> (),
	setDetail: (text: string) -> (),
}

export type GridOptions = {
	parent: GuiObject, -- the window body
	color: StudUI.ColorName, -- small card colour ("sky" daily, "orange" time)
	bigColor: StudUI.ColorName?, -- default "rainbow"
	captions: boolean, -- true: cards have a caption word under the icon
	claimText: string?, -- the button's normal text (default "CLAIM")
	onClaim: (index: number) -> (),
}

export type Grid = {
	frame: Frame,
	cells: { Cell },
	layout: (layout: ResponsiveModal.Layout) -> (),
	Destroy: () -> (),
}

-- Internal per-card state the layout pass writes (the public Cell is the screens' API).
type CellParts = {
	cell: Cell,
	content: Frame,
	title: TextLabel,
	iconHolder: Frame,
	caption: TextLabel?,
	detail: TextLabel,
	detailLimit: UITextSizeConstraint?,
	place: (titleSize: number, titleHeight: number) -> (), -- re-places a live countdown title
}

type Rect = { position: Vector2, size: Vector2 }

local CardGrid = {}

CardGrid.Count = CARD_COUNT

-- The two window modes for ResponsiveModal (first = the reference arrangement).
CardGrid.Modes = table.freeze({
	table.freeze({ name = "grid", size = Vector2.new(960, 660) }),
	table.freeze({ name = "row", size = Vector2.new(1320, 500) }),
}) :: { ResponsiveModal.Mode }

-- The kit's text outline thickness for `size` px text (StudUI's rule; re-applied on resize).
local function restyle(label: TextLabel, size: number)
	label.TextSize = size
	StudWindow.outline(label, math.max(2, math.floor(size * UIStyleConfig.Button.TextStrokeRatio + 0.5)))
end

--[[
	Card rectangles (design px) for `area` in `mode`, in card order (1..7, 7 = the big card).
	Widths fill the width exactly: `n` small cards + 1 big (BIG_WIDTH_RATIO x small) + gaps, so
	small = (W - gaps) / (n + ratio); the big card takes whatever is left (no rounding gap).
		grid: 3 small columns x 2 rows, the big card spans both rows on the right
		row:  6 small + the big card in one row, full height
]]
local function rects(area: Vector2, mode: string): { Rect }
	local result: { Rect } = {}
	if mode == "row" then
		local small = math.floor((area.X - SMALL_COUNT * GAP) / (SMALL_COUNT + BIG_WIDTH_RATIO))
		for index = 1, SMALL_COUNT do
			table.insert(result, {
				position = Vector2.new((index - 1) * (small + GAP), 0),
				size = Vector2.new(small, area.Y),
			})
		end
		local bigX = SMALL_COUNT * (small + GAP)
		table.insert(result, { position = Vector2.new(bigX, 0), size = Vector2.new(area.X - bigX, area.Y) })
		return result
	end
	local small = math.floor((area.X - GRID_COLUMNS * GAP) / (GRID_COLUMNS + BIG_WIDTH_RATIO))
	local rowHeight = math.floor((area.Y - GAP) / 2)
	for index = 1, SMALL_COUNT do
		local column = (index - 1) % GRID_COLUMNS
		local row = (index - 1) // GRID_COLUMNS
		table.insert(result, {
			position = Vector2.new(column * (small + GAP), row * (rowHeight + GAP)),
			size = Vector2.new(small, rowHeight),
		})
	end
	local bigX = GRID_COLUMNS * (small + GAP)
	table.insert(result, {
		position = Vector2.new(bigX, 0),
		size = Vector2.new(area.X - bigX, 2 * rowHeight + GAP),
	})
	return result
end

--[[
	Builds one card and its slots (see the module header). Sizes are placeholders until the
	first layout() pass.
	@param grid    the grid frame (parent)
	@param index   1..7 (7 = the big card)
	@param options the grid options
	@return CellParts
]]
local function buildCell(grid: Frame, index: number, options: GridOptions): CellParts
	local big = index == CARD_COUNT
	local card = StudUI.card({
		name = `Card{index}`,
		color = if big then options.bigColor or "rainbow" else options.color,
		sunburst = true,
		layoutOrder = index,
		parent = grid,
	})
	local content = card.content
	local title = StudUI.text({
		name = "Title",
		text = "",
		textSize = 36,
		zIndex = 4,
		parent = content,
	})
	local iconHolder = Create.new("Frame", {
		Name = "IconSlot",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 3,
		Parent = content,
	}) :: Frame
	local caption: TextLabel? = nil
	if options.captions then
		caption = StudUI.text({
			name = "Caption",
			text = "",
			textSize = 32,
			zIndex = 4,
			parent = content,
		})
	end
	-- Detail: TextScaled so a long headline wraps / shrinks instead of overflowing (the size
	-- constraint's floor is lifted to the touch minimum in layout()).
	local detail = StudUI.text({
		name = "Detail",
		text = "",
		textSize = 20,
		scaled = true,
		zIndex = 4,
		parent = content,
	})
	local detailLimit = detail:FindFirstChildOfClass("UITextSizeConstraint")
	local button = StudUI.button({
		name = "Claim",
		text = options.claimText or "CLAIM",
		color = "green",
		anchor = Vector2.new(0.5, 1),
		position = UDim2.new(0.5, 0, 1, -BUTTON_BOTTOM),
		parent = content,
		onActivated = function()
			options.onClaim(index)
		end,
	})
	button.instance.ZIndex = 5

	local iconKey: string? = nil
	local countdown: StudUI.Countdown? = nil
	-- The live countdown's target (server unix seconds); meaningful only while `countdown` exists.
	local countdownEndsAt = 0
	-- The callback the live countdown runs at 0 (mutable: a re-target may bring a new one).
	local finishedCallback: (() -> ())? = nil
	-- Current title geometry (layout() writes it; a countdown created later copies it).
	local titleSize = 36
	local titleHeight = 42

	-- Places a countdown label exactly where the static title sits.
	local function placeCountdown(label: TextLabel)
		restyle(label, titleSize)
		label.Size = UDim2.new(1, 0, 0, titleHeight)
		label.Position = UDim2.fromOffset(0, -2)
		label.ZIndex = 4
	end

	-- Removes the live countdown title (its label leaves the shared ticker when destroyed).
	local function dropCountdown()
		local current = countdown
		if current ~= nil then
			countdown = nil
			finishedCallback = nil
			current.Destroy()
		end
	end

	local cell: Cell = {
		index = index,
		big = big,
		card = card,
		button = button,
		setTitle = function(text: string)
			dropCountdown()
			title.Visible = true
			title.Text = text
		end,
		setCountdown = function(endsAt: number, format: StudUI.CountdownFormat, onFinished: (() -> ())?)
			title.Visible = false
			finishedCallback = onFinished
			local current = countdown
			if current ~= nil then
				-- Same target (± epsilon): keep ticking untouched (setEndsAt would reset it and
				-- could re-fire onFinished for a target already reached).
				if math.abs(countdownEndsAt - endsAt) > RETARGET_EPSILON then
					countdownEndsAt = endsAt
					current.setEndsAt(endsAt)
				end
				return
			end
			countdownEndsAt = endsAt
			local created = StudUI.countdown({
				endsAt = endsAt,
				format = format,
				doneText = "00:00",
				textSize = titleSize,
				onFinished = function()
					local done = finishedCallback
					if done ~= nil then
						done()
					end
				end,
				parent = content,
			})
			placeCountdown(created.label)
			countdown = created
		end,
		setIcon = function(key: string)
			if key == iconKey then
				return -- unchanged: keep the existing image (no rebuild)
			end
			iconKey = key
			iconHolder:ClearAllChildren()
			-- Built at the authored size; it scales with the slot (layout() resizes the slot).
			local icon = StudUI.icon(key, 96, 3)
			icon.Size = UDim2.fromScale(1, 1)
			icon.Parent = iconHolder
		end,
		setCaption = function(text: string)
			if caption ~= nil then
				caption.Text = text
			end
		end,
		setDetail = function(text: string)
			detail.Text = text
		end,
	}
	return {
		cell = cell,
		content = content,
		title = title,
		iconHolder = iconHolder,
		caption = caption,
		detail = detail,
		detailLimit = detailLimit,
		place = function(size: number, height: number)
			titleSize, titleHeight = size, height
			local current = countdown
			if current ~= nil then
				placeCountdown(current.label)
			end
		end,
	}
end

--[[
	Places one card's slots inside its content frame (design px). Bottom-up: button, detail,
	caption; the title sits on top; the icon fills what is left (≤ its authored size, centred in
	the free band, the caption overlapping its foot).
	@param parts   the card
	@param width   content width (card width - padding)
	@param height  content height
	@param m       authored metrics
	@param layout  the active layout (touch minimums)
]]
local function placeSlots(parts: CellParts, width: number, height: number, m: Metrics, layout: ResponsiveModal.Layout)
	local minText = layout.minText
	-- Button (bottom): at least one tap tall; its label follows the kit's 0.58 x height rule.
	local buttonHeight = math.max(m.button, layout.tap)
	local button = parts.cell.button
	button.instance.Size = UDim2.new(1, -math.min(m.buttonInset, math.max(0, width - layout.tap)), 0, buttonHeight)
	restyle(button.label, math.floor(buttonHeight * 0.58))
	local buttonTop = height - BUTTON_BOTTOM - buttonHeight

	-- Detail (above the button).
	local detailSize = math.max(m.detail, minText)
	local detailHeight = m.detailLines * (detailSize + 4) + 4
	local detailTop = buttonTop - SLOT_GAP - detailHeight
	parts.detail.Position = UDim2.fromOffset(0, detailTop)
	parts.detail.Size = UDim2.new(1, 0, 0, detailHeight)
	restyle(parts.detail, detailSize)
	local limit = parts.detailLimit
	if limit ~= nil then
		limit.MaxTextSize = detailSize
		-- Never shrink below the readable minimum on touch (the kit's floor is 10 px).
		limit.MinTextSize = math.min(detailSize, math.max(10, minText))
	end

	-- Caption (above the detail), when the grid has captions.
	local bandBottom = detailTop - SLOT_GAP
	local caption = parts.caption
	if caption ~= nil then
		local captionSize = math.max(m.caption, minText)
		local captionTop = detailTop - (captionSize + 6)
		caption.Position = UDim2.fromOffset(0, captionTop)
		caption.Size = UDim2.new(1, 0, 0, captionSize + 6)
		restyle(caption, captionSize)
		bandBottom = captionTop
	end

	-- Title (top).
	local titleSize = math.max(m.title, minText)
	local titleHeight = titleSize + 6
	parts.title.Position = UDim2.fromOffset(0, -2)
	parts.title.Size = UDim2.new(1, 0, 0, titleHeight)
	restyle(parts.title, titleSize)
	parts.place(titleSize, titleHeight)

	-- Icon: the band between the title and the caption (or detail). With a caption the icon's
	-- foot may tuck CAPTION_OVERLAP under it, so side = band / (1 - overlap).
	local bandTop = titleHeight - 4
	local band = math.max(0, bandBottom - bandTop)
	local overlap = if caption ~= nil then CAPTION_OVERLAP else 0
	local side = math.floor(math.clamp(band / (1 - overlap), MIN_ICON, m.icon))
	side = math.min(side, width)
	-- Centre the icon's visible part in the band when there is spare room.
	local visible = side * (1 - overlap)
	local top = bandTop + math.max(0, (band - visible) / 2)
	parts.iconHolder.Position = UDim2.new(0.5, 0, 0, math.floor(top))
	parts.iconHolder.Size = UDim2.fromOffset(side, side)
end

--[[
	Rewrites the gamepad links for `mode` (see the module header).
	@param buttons the seven CLAIM button instances in card order
	@param mode    "grid" | "row"
]]
local function linkNav(buttons: { GuiObject }, mode: string)
	if mode == "row" then
		GamepadNav.linkList(buttons, false)
		return
	end
	local small = table.move(buttons, 1, SMALL_COUNT, 1, {})
	local bigButton = buttons[CARD_COUNT]
	-- Right from the last column of rows 1 and 2 reaches the big card; its left returns to row 1.
	GamepadNav.linkGrid(small, GRID_COLUMNS, { right = bigButton })
	bigButton.NextSelectionLeft = small[GRID_COLUMNS]
	-- Clear stale "row" links (nil = the engine's own spatial pick; the API types say GuiObject).
	bigButton.NextSelectionRight = nil :: any
	bigButton.NextSelectionUp = nil :: any
	bigButton.NextSelectionDown = nil :: any
end

--[[
	Builds the 7-card grid inside `options.parent` (see the module header). Call `layout()`
	once with the window's current Layout (and again whenever it changes).
	@param options parent / colours / captions / onClaim
	@return Grid (`cells[1..7]`, 7 = the big card)
	Example: local grid = CardGrid.new({ parent = window.body, color = "orange",
		captions = false, onClaim = claimGift }); grid.layout(controller.current())
]]
function CardGrid.new(options: GridOptions): Grid
	local frame = Create.new("Frame", {
		Name = "CardGrid",
		BackgroundTransparency = 1,
		Parent = options.parent,
	}) :: Frame
	local parts: { CellParts } = {}
	local cells: { Cell } = {}
	local buttons: { GuiObject } = {}
	for index = 1, CARD_COUNT do
		local built = buildCell(frame, index, options)
		table.insert(parts, built)
		table.insert(cells, built.cell)
		table.insert(buttons, built.cell.button.instance)
	end
	local padding = UIStyleConfig.Card.Padding
	return {
		frame = frame,
		cells = cells,
		layout = function(layout: ResponsiveModal.Layout)
			local mode = if METRICS[layout.mode] ~= nil then layout.mode else "grid"
			frame.Size = UDim2.fromOffset(layout.area.X, layout.area.Y)
			for index, rect in rects(layout.area, mode) do
				local part = parts[index]
				part.cell.card.frame.Position = UDim2.fromOffset(rect.position.X, rect.position.Y)
				part.cell.card.frame.Size = UDim2.fromOffset(rect.size.X, rect.size.Y)
				local metrics = if part.cell.big then METRICS[mode].big else METRICS[mode].small
				placeSlots(part, rect.size.X - 2 * padding, rect.size.Y - 2 * padding, metrics, layout)
			end
			linkNav(buttons, mode)
		end,
		Destroy = function()
			frame:Destroy()
		end,
	}
end

--[[
	A cancellable one-shot wake-up (the screens' "next UTC midnight" / "next gift ready" timer).
	`schedule` replaces any pending wake; the callback runs at most once per schedule.
	@param callback what to run when the time comes
	@return { schedule(seconds), cancel() }
	Example:
		local wake = CardGrid.wakeTimer(refreshBadge)
		wake.schedule(RetentionConfig.secondsToNextDay(now))
]]
function CardGrid.wakeTimer(callback: () -> ()): { schedule: (seconds: number) -> (), cancel: () -> () }
	local pending: thread? = nil
	local function cancel()
		local thread = pending
		pending = nil
		-- Never cancel the running thread (a callback that reschedules itself).
		if thread ~= nil and thread ~= coroutine.running() then
			task.cancel(thread)
		end
	end
	return {
		schedule = function(seconds: number)
			cancel()
			-- NaN / inf guard; a small margin so the wake lands just AFTER the boundary.
			local delay = if seconds == seconds and seconds < math.huge then math.max(0, seconds) + 0.05 else nil
			if delay == nil then
				return
			end
			pending = task.delay(delay, function()
				pending = nil
				callback()
			end)
		end,
		cancel = cancel,
	}
end

return table.freeze(CardGrid)
