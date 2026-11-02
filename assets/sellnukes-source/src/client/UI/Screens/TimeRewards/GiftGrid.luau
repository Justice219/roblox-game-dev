--!strict
--[[
	GiftGrid — the owner R89 Early Gift Ladder layout of the Time Rewards window: a TOOLBAR (gifts
	opened today, "saved all day" note, a progress bar to the last gift with the next-gift
	countdown, and the CLAIM ALL button) above TEN reward cards. Display only: the screen
	(Screens/TimeRewards) decides what every card shows from the server profile.

		┌──────────────────────────────────────────────────────────────────────┐
		│ 3 / 10 opened        Next gift in 02:26             [ CLAIM ALL (2) ] │  toolbar
		│ Saved all day!       [██████░░░░░░░░░░░░░░░░░░]                       │
		├──────┬──────┬──────┬──────┬──────┐                                    │
		│ card │ card │ card │ card │ card │   "grid": 5 x 2 (desktop / console /│
		├──────┼──────┼──────┼──────┼──────┤            tablet), card 10 rainbow │
		│ card │ card │ card │ card │ RAIN │   "row":  one horizontally SCROLLING │
		└──────┴──────┴──────┴──────┴──────┘            row (landscape phone)     │

	Every card (StudUI.card + sunburst) stacks its slots from the bottom: CLAIM button, the reward
	detail, then the title on top and the icon in the space left (capped at its authored size) —
	the same rule as Screens/DailyRewards/CardGrid, so a taller touch button never overlaps text.
	`grid.layout(layout)` places everything in exact design px for the active mode and lifts button
	heights / text sizes to the layout's touch minimums (`tap` = 44 pt, `minText` = 14 pt).

	Phone ("row"): 10 cards in one row would be ~120 px wide — too narrow for a 44 pt CLAIM and
	14 pt text — so the row SCROLLS sideways (touch swipe; the gamepad cursor scrolls it through
	GamepadNav.followScroll) with cards wide enough for both.

	Gamepad (owner R11): "grid" links the ten CLAIM buttons as a 5 x 2 grid whose top row leads Up
	to CLAIM ALL; "row" links them as one list, Up = CLAIM ALL. Links are rewritten on every layout.

	Performance: every Instance is built ONCE; layout() and the setters only write properties
	(layout runs on open / rotation / device switch, never per frame). Live countdowns exist only
	while a card / the toolbar shows one (StudUI's shared 1 Hz ticker).

	Security: display only. CLAIM / CLAIM ALL call the screen's callbacks, which send intents; the
	server re-checks every claim.

	Connects to: Kit/StudUI (card, button, countdown, icon, text, progressBar), Widgets/StudWindow
	(text outline), Platform/GamepadNav, Screens/DailyRewards/ResponsiveModal (Layout),
	Shared/Config/UIStyleConfig. Used by Screens/TimeRewards (lives inside it, so UIController's
	screen discovery never registers it).

	Example:
		local grid = GiftGrid.new({ parent = window.body, count = 10, bigIndex = 10,
			onClaim = function(i) end, onClaimAll = function() end })
		grid.layout(controller.current())
		grid.cells[1].setTitle("Ready!"); grid.setOpened(3, 10)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Create = require(script.Parent.Parent.Parent.Create)
local GamepadNav = require(script.Parent.Parent.Parent.Parent.Platform.GamepadNav)
local ResponsiveModal = require(script.Parent.Parent.DailyRewards.ResponsiveModal)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Parent.Widgets.StudWindow)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

-- Columns of the "grid" mode (two rows of five).
local GRID_COLUMNS = 5
-- Gap between cards / toolbar parts (design px).
local GAP = 12
-- Card width of the scrolling "row" mode (design px; ~5.6 cards visible in the 1320 window).
local ROW_CARD_WIDTH = 220
-- Smallest icon side ever drawn (design px), even on the tightest layout.
local MIN_ICON = 36
-- Vertical gap between stacked slots (design px).
local SLOT_GAP = 4
-- Button bottom inset: keeps its 3D lip + outline inside the card.
local BUTTON_BOTTOM = UIStyleConfig.Button.Lip + UIStyleConfig.Button.Edge
-- A countdown re-target closer than this to the current target is ignored (no reset churn).
local RETARGET_EPSILON = 0.5

-- Authored slot sizes (design px) per arrangement; touch minimums lift them.
type Metrics = {
	title: number,
	icon: number,
	detail: number,
	detailLines: number,
	button: number,
	buttonInset: number,
	toolbar: number, -- toolbar height
	toolbarText: number, -- toolbar main line text size
	toolbarNote: number, -- toolbar note text size
	claimAllWidth: number, -- CLAIM ALL button width
}

local METRICS: { [string]: Metrics } = {
	grid = {
		title = 30,
		icon = 96,
		detail = 20,
		detailLines = 3,
		button = 48,
		buttonInset = 8,
		toolbar = 76,
		toolbarText = 30,
		toolbarNote = 20,
		claimAllWidth = 280,
	},
	row = {
		title = 30,
		icon = 120,
		detail = 20,
		detailLines = 3,
		button = 56,
		buttonInset = 8,
		toolbar = 76,
		toolbarText = 28,
		toolbarNote = 20,
		claimAllWidth = 300,
	},
}

export type Cell = {
	index: number,
	card: StudUI.Card,
	button: StudUI.Button,
	setTitle: (text: string) -> (), -- static title (drops a live countdown)
	-- Live countdown title to server time `endsAt`; `onFinished` fires once at 0 (on StudUI's
	-- ticker thread: callers should only DEFER work from it).
	setCountdown: (endsAt: number, onFinished: (() -> ())?) -> (),
	setIcon: (key: string) -> (),
	setDetail: (text: string) -> (), -- one reward part per line ("\n"), at most 3 lines
	setReady: (ready: boolean) -> (), -- ready cards glow (a bright outline)
}

export type GridOptions = {
	parent: GuiObject, -- the window body
	count: number, -- number of cards (PlaytimeConfig.Gifts)
	bigIndex: number, -- the rainbow card
	color: StudUI.ColorName, -- small card colour
	onClaim: (index: number) -> (),
	onClaimAll: () -> (),
}

export type Grid = {
	frame: Frame,
	cells: { Cell },
	claimAll: StudUI.Button,
	setOpened: (opened: number, total: number) -> (),
	-- Next-gift countdown (endsAt = server time) or a static line (endsAt nil).
	setNext: (text: string, endsAt: number?, onFinished: (() -> ())?) -> (),
	setProgress: (fraction: number) -> (),
	layout: (layout: ResponsiveModal.Layout) -> (),
	Destroy: () -> (),
}

-- Internal per-card parts the layout pass writes.
type CellParts = {
	cell: Cell,
	content: Frame,
	title: TextLabel,
	iconHolder: Frame,
	detail: TextLabel,
	detailLimit: UITextSizeConstraint?,
	place: (titleSize: number, titleHeight: number) -> (),
}

local GiftGrid = {}

-- The two window modes for ResponsiveModal (first = desktop / console / tablet).
GiftGrid.Modes = table.freeze({
	table.freeze({ name = "grid", size = Vector2.new(1120, 800) }),
	table.freeze({ name = "row", size = Vector2.new(1320, 540) }),
}) :: { ResponsiveModal.Mode }

-- The kit's text outline thickness for `size` px text (StudUI's rule; re-applied on resize).
local function restyle(label: TextLabel, size: number)
	label.TextSize = size
	StudWindow.outline(label, math.max(2, math.floor(size * UIStyleConfig.Button.TextStrokeRatio + 0.5)))
end

--[[
	Builds one card and its slots. Sizes are placeholders until the first layout() pass.
]]
local function buildCell(host: GuiObject, index: number, options: GridOptions): CellParts
	local card = StudUI.card({
		name = `Gift{index}`,
		color = if index == options.bigIndex then "rainbow" else options.color,
		sunburst = true,
		layoutOrder = index,
		parent = host,
	})
	local content = card.content
	local title = StudUI.text({ name = "Title", text = "", textSize = 30, zIndex = 4, parent = content })
	local iconHolder = Create.new("Frame", {
		Name = "IconSlot",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 3,
		Parent = content,
	}) :: Frame
	-- Detail: one reward part per line (the screen joins them with "\n", at most detailLines),
	-- bottom-aligned on the button, at a FIXED size — never TextScaled, which can neither go below
	-- the 14 pt touch floor nor grow past the box (Studio check 2026-10-31: scaled details clipped
	-- behind the button on phone / tablet).
	local detail = StudUI.text({
		name = "Detail",
		text = "",
		textSize = 20,
		alignY = Enum.TextYAlignment.Bottom,
		zIndex = 4,
		parent = content,
	})
	detail.LineHeight = 1
	local detailLimit: UITextSizeConstraint? = nil
	local button = StudUI.button({
		name = "Claim",
		text = "CLAIM",
		color = "green",
		anchor = Vector2.new(0.5, 1),
		position = UDim2.new(0.5, 0, 1, -BUTTON_BOTTOM),
		parent = content,
		onActivated = function()
			options.onClaim(index)
		end,
	})
	button.instance.ZIndex = 5
	-- Ready glow: a bright ring just outside the card's own outline (its own frame, because the
	-- card frame already carries the dark edge stroke; off until the gift is ready).
	local glow = Create.new("Frame", {
		Name = "ReadyGlow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, 12, 1, 12),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 6,
		Children = {
			Create.new("UICorner", { CornerRadius = UDim.new(0, UIStyleConfig.Card.Corner + 4) }),
			Create.new("UIStroke", {
				Color = Color3.fromRGB(255, 240, 110),
				Thickness = 5,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			}),
		},
		Parent = card.frame,
	}) :: Frame

	local iconKey: string? = nil
	local countdown: StudUI.Countdown? = nil
	local countdownEndsAt = 0
	local finishedCallback: (() -> ())? = nil
	local titleSize, titleHeight = 30, 36

	local function placeCountdown(label: TextLabel)
		restyle(label, titleSize)
		label.Size = UDim2.new(1, 0, 0, titleHeight)
		label.Position = UDim2.fromOffset(0, -2)
		label.ZIndex = 4
	end

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
		card = card,
		button = button,
		setTitle = function(text: string)
			dropCountdown()
			title.Visible = true
			title.Text = text
		end,
		setCountdown = function(endsAt: number, onFinished: (() -> ())?)
			title.Visible = false
			finishedCallback = onFinished
			local current = countdown
			if current ~= nil then
				-- Same target (± epsilon): keep ticking untouched (a re-target could re-fire).
				if math.abs(countdownEndsAt - endsAt) > RETARGET_EPSILON then
					countdownEndsAt = endsAt
					current.setEndsAt(endsAt)
				end
				return
			end
			countdownEndsAt = endsAt
			local created = StudUI.countdown({
				endsAt = endsAt,
				format = "auto",
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
				return
			end
			iconKey = key
			iconHolder:ClearAllChildren()
			local icon = StudUI.icon(key, 96, 3)
			icon.Size = UDim2.fromScale(1, 1)
			icon.Parent = iconHolder
		end,
		setDetail = function(text: string)
			detail.Text = text
		end,
		setReady = function(ready: boolean)
			glow.Visible = ready
		end,
	}
	return {
		cell = cell,
		content = content,
		title = title,
		iconHolder = iconHolder,
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
	Places one card's slots inside its content frame (bottom-up: button, detail; title on top;
	the icon fills the band between, ≤ its authored size).
]]
local function placeSlots(parts: CellParts, width: number, height: number, m: Metrics, layout: ResponsiveModal.Layout)
	local minText = layout.minText
	local buttonHeight = math.max(m.button, layout.tap)
	local button = parts.cell.button
	button.instance.Size = UDim2.new(1, -math.min(m.buttonInset, math.max(0, width - layout.tap)), 0, buttonHeight)
	restyle(button.label, math.floor(buttonHeight * 0.58))
	local buttonTop = height - BUTTON_BOTTOM - buttonHeight

	local detailSize = math.max(m.detail, minText)
	local detailHeight = m.detailLines * (detailSize + 2) + 4
	local detailTop = buttonTop - SLOT_GAP - detailHeight
	parts.detail.Position = UDim2.fromOffset(0, detailTop)
	parts.detail.Size = UDim2.new(1, 0, 0, detailHeight)
	restyle(parts.detail, detailSize)
	local limit = parts.detailLimit
	if limit ~= nil then
		limit.MaxTextSize = detailSize
		limit.MinTextSize = math.min(detailSize, math.max(10, minText))
	end

	local titleSize = math.max(m.title, minText)
	local titleHeight = titleSize + 6
	parts.title.Position = UDim2.fromOffset(0, -2)
	parts.title.Size = UDim2.new(1, 0, 0, titleHeight)
	restyle(parts.title, titleSize)
	parts.place(titleSize, titleHeight)

	local bandTop = titleHeight - 2
	local band = math.max(0, detailTop - SLOT_GAP - bandTop)
	local side = math.floor(math.clamp(band, MIN_ICON, m.icon))
	side = math.min(side, width)
	local top = bandTop + math.max(0, (band - side) / 2)
	parts.iconHolder.Position = UDim2.new(0.5, 0, 0, math.floor(top))
	parts.iconHolder.Size = UDim2.fromOffset(side, side)
end

--[[
	Builds the toolbar + ten cards inside `options.parent`. Call `layout()` once with the window's
	current Layout (and again whenever it changes).
	@return Grid (`cells[1..count]`)
]]
function GiftGrid.new(options: GridOptions): Grid
	local frame = Create.new("Frame", {
		Name = "GiftGrid",
		BackgroundTransparency = 1,
		Parent = options.parent,
	}) :: Frame

	-- Toolbar -----------------------------------------------------------------------------------
	local toolbar = Create.new("Frame", { Name = "Toolbar", BackgroundTransparency = 1, Parent = frame }) :: Frame
	local opened = StudUI.text({
		name = "Opened",
		text = "",
		textSize = 30,
		align = Enum.TextXAlignment.Left,
		parent = toolbar,
	})
	local note = StudUI.text({
		name = "Note",
		text = "Playtime saved all day!",
		textSize = 20,
		align = Enum.TextXAlignment.Left,
		color = Color3.fromRGB(255, 240, 170),
		parent = toolbar,
	})
	local nextLine = StudUI.text({ name = "Next", text = "", textSize = 26, parent = toolbar })
	local nextCountdown: StudUI.Countdown? = nil
	local nextPrefix = ""
	local nextEndsAt = 0
	local nextFinished: (() -> ())? = nil
	local bar = StudUI.progressBar({ color = "green", parent = toolbar })
	local claimAll = StudUI.button({
		name = "ClaimAll",
		text = "CLAIM ALL",
		color = "green",
		icon = "Gift",
		parent = toolbar,
		onActivated = function()
			options.onClaimAll()
		end,
	})

	-- Cards host: a ScrollingFrame in both modes (no scrolling in "grid": canvas = frame size).
	local host = Create.new("ScrollingFrame", {
		Name = "Cards",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 8,
		ScrollingDirection = Enum.ScrollingDirection.X,
		ElasticBehavior = Enum.ElasticBehavior.Never,
		ScrollBarImageColor3 = Color3.fromRGB(255, 255, 255),
		Parent = frame,
	}) :: ScrollingFrame
	local unfollow = GamepadNav.followScroll(host, 24)

	local parts: { CellParts } = {}
	local cells: { Cell } = {}
	local buttons: { GuiObject } = {}
	for index = 1, options.count do
		local built = buildCell(host, index, options)
		table.insert(parts, built)
		table.insert(cells, built.cell)
		table.insert(buttons, built.cell.button.instance)
	end
	local padding = UIStyleConfig.Card.Padding
	local currentNextSize = 26

	-- Places the next-gift countdown label exactly where the static line sits.
	local function placeNext(label: TextLabel)
		restyle(label, currentNextSize)
		label.Size = nextLine.Size
		label.Position = nextLine.Position
		label.AnchorPoint = nextLine.AnchorPoint
		label.ZIndex = nextLine.ZIndex
	end

	local grid: Grid = {
		frame = frame,
		cells = cells,
		claimAll = claimAll,
		setOpened = function(count: number, total: number)
			opened.Text = `{count} / {total} opened`
		end,
		setNext = function(text: string, endsAt: number?, onFinished: (() -> ())?)
			if endsAt == nil then
				local current = nextCountdown
				if current ~= nil then
					nextCountdown = nil
					current.Destroy()
				end
				nextFinished = nil
				nextLine.Visible = true
				nextLine.Text = text
				return
			end
			nextLine.Visible = false
			nextFinished = onFinished
			local current = nextCountdown
			if current ~= nil and nextPrefix == text then
				if math.abs(nextEndsAt - endsAt) > RETARGET_EPSILON then
					nextEndsAt = endsAt
					current.setEndsAt(endsAt)
				end
				return
			end
			if current ~= nil then
				current.Destroy()
			end
			nextPrefix, nextEndsAt = text, endsAt
			local created = StudUI.countdown({
				endsAt = endsAt,
				format = "auto",
				prefix = text,
				doneText = "Ready!",
				textSize = currentNextSize,
				onFinished = function()
					local done = nextFinished
					if done ~= nil then
						done()
					end
				end,
				parent = toolbar,
			})
			placeNext(created.label)
			nextCountdown = created
		end,
		setProgress = function(fraction: number)
			bar.setProgress(fraction)
		end,
		layout = function(layout: ResponsiveModal.Layout)
			local mode = if METRICS[layout.mode] ~= nil then layout.mode else "grid"
			local m = METRICS[mode]
			local area = layout.area
			frame.Size = UDim2.fromOffset(area.X, area.Y)

			-- Toolbar: [opened + note] [next line + bar] [CLAIM ALL].
			local buttonHeight = math.max(56, layout.tap)
			local textSize = math.max(m.toolbarText, layout.minText)
			local noteSize = math.max(m.toolbarNote, layout.minText)
			local toolbarHeight = math.max(m.toolbar, buttonHeight + 2 * BUTTON_BOTTOM, textSize + noteSize + 16)
			toolbar.Size = UDim2.fromOffset(area.X, toolbarHeight)
			local claimWidth = math.max(m.claimAllWidth, layout.tap * 3)
			local leftWidth = math.floor((area.X - claimWidth - 2 * GAP) * 0.38)
			local middleWidth = area.X - claimWidth - leftWidth - 2 * GAP
			opened.Position = UDim2.fromOffset(0, 2)
			opened.Size = UDim2.fromOffset(leftWidth, textSize + 6)
			restyle(opened, textSize)
			note.Position = UDim2.fromOffset(0, textSize + 10)
			note.Size = UDim2.fromOffset(leftWidth, noteSize + 6)
			restyle(note, noteSize)
			currentNextSize = math.max(26, layout.minText)
			nextLine.AnchorPoint = Vector2.new(0, 0)
			nextLine.Position = UDim2.fromOffset(leftWidth + GAP, 2)
			nextLine.Size = UDim2.fromOffset(middleWidth, currentNextSize + 6)
			restyle(nextLine, currentNextSize)
			local liveNext = nextCountdown
			if liveNext ~= nil then
				placeNext(liveNext.label)
			end
			local barHeight = math.max(22, math.floor(toolbarHeight * 0.3))
			bar.frame.Position = UDim2.fromOffset(leftWidth + GAP, toolbarHeight - barHeight - 6)
			bar.frame.Size = UDim2.fromOffset(middleWidth, barHeight)
			claimAll.instance.AnchorPoint = Vector2.new(1, 0.5)
			claimAll.instance.Position = UDim2.new(1, 0, 0, math.floor((toolbarHeight - BUTTON_BOTTOM) / 2))
			claimAll.instance.Size = UDim2.fromOffset(claimWidth, buttonHeight)
			restyle(claimAll.label, math.floor(buttonHeight * 0.5))

			-- Cards.
			local cardsTop = toolbarHeight + GAP
			local cardsHeight = area.Y - cardsTop
			host.Position = UDim2.fromOffset(0, cardsTop)
			host.Size = UDim2.fromOffset(area.X, cardsHeight)
			local count = #parts
			if mode == "row" then
				-- One scrolling row; leave room under the cards for the scroll bar.
				local cardHeight = cardsHeight - host.ScrollBarThickness - 4
				host.CanvasSize = UDim2.fromOffset(count * ROW_CARD_WIDTH + (count - 1) * GAP, cardsHeight)
				host.ScrollingEnabled = true
				for index, part in parts do
					part.cell.card.frame.Position = UDim2.fromOffset((index - 1) * (ROW_CARD_WIDTH + GAP), 0)
					part.cell.card.frame.Size = UDim2.fromOffset(ROW_CARD_WIDTH, cardHeight)
					placeSlots(part, ROW_CARD_WIDTH - 2 * padding, cardHeight - 2 * padding, m, layout)
				end
				GamepadNav.linkList(buttons, false, { up = claimAll.instance })
			else
				local rows = math.ceil(count / GRID_COLUMNS)
				local width = math.floor((area.X - (GRID_COLUMNS - 1) * GAP) / GRID_COLUMNS)
				local height = math.floor((cardsHeight - (rows - 1) * GAP) / rows)
				host.CanvasSize = UDim2.fromOffset(area.X, cardsHeight)
				host.CanvasPosition = Vector2.zero
				host.ScrollingEnabled = false
				for index, part in parts do
					local column = (index - 1) % GRID_COLUMNS
					local row = (index - 1) // GRID_COLUMNS
					part.cell.card.frame.Position = UDim2.fromOffset(column * (width + GAP), row * (height + GAP))
					part.cell.card.frame.Size = UDim2.fromOffset(width, height)
					placeSlots(part, width - 2 * padding, height - 2 * padding, m, layout)
				end
				GamepadNav.linkGrid(buttons, GRID_COLUMNS, { up = claimAll.instance })
			end
			-- CLAIM ALL: Down returns to the first card's button; no sideways exits.
			local claimNav: any = claimAll.instance
			claimNav.NextSelectionDown = buttons[1]
			claimNav.NextSelectionLeft = nil
			claimNav.NextSelectionRight = nil
		end,
		Destroy = function()
			unfollow()
			frame:Destroy()
		end,
	}
	return grid
end

return table.freeze(GiftGrid)
