--!strict
--[[
	AnalyticsTab — the owner admin panel's ANALYTICS page (spec §13 "read back in the admin panel
	→ Analytics tab"; owner R6). Ported from RoBeasts' UI/Admin/AnalyticsTab and rebuilt on the
	SellNukes stud kit (Kit/StudUI + Widgets/StudWindow) so it matches every other screen.

	Layout (inside the panel's page area, `width` x `height` design px):
		[TODAY] [7 DAYS] [30 DAYS] [ALL TIME] [REFRESH] [COPY FOR AI] [COPY RAW DATA]  status
		┌ 12 stud headline cards: DAU · new players · sessions · median session · D1 · D7 ·
		└ Robux · ARPDAU · payer % · tutorial done · reached area 2 · pads bought
		┌ sections (scroll) ┐┌ ranked rows with stud bars: #, name, value, details (scroll) ───┐
		│ Daily activity     ││ 1  Starter Pack (`StarterPack`)            R$ 4,200          │
		│ Top Robux products ││    ██████████████████   84 bought · 300 prompts · 28% ...     │
		│ ...                ││ ...                                     +12 more rows ...    │
		└────────────────────┘└──────────────────────────────────────────────────────────────┘
	States: loading ("LOADING 12 / 45" progress), empty ("No data in this range yet"), error
	(reason + REFRESH) and memory mode (the compact status says THIS SERVER ONLY).
	If the page is too narrow for the status beside the buttons, the status takes its own line.

	Data flow (server: Server/Analytics/Reports + AnalyticsRaw, B13):
		AnalyticsRequest(requestId, range) → server (admin re-checked, shared cache, rate-limited)
		→ AnalyticsReport(requestId, payload): code "Loading" { done, total } progress, then "Ok"
		+ summary (AnalyticsReport.parse validates every field) or an error code. Replies with an
		old requestId are ignored. Loaded ranges are reused for AnalyticsConfig.CacheSeconds
		(flipping ranges never re-requests) and reloaded after 5 minutes on screen.
		COPY FOR AI opens the "AnalyticsExport" screen with AnalyticsReport.toText(summary).
		COPY RAW DATA opens it on page 1 of the server's uncapped snapshot of the loaded summary
		(summary.rawId; AnalyticsExportScreen pages it with PREV / NEXT and LB / RB).
		A ranked table the server cut shows "+N more rows" under its last row.
		Scorecard rows (owner R122 "Roblox algorithm scorecard": rows with a `tone`) render TALL:
		the value is coloured by its verdict, a verdict tag (ON TARGET / WATCH / BELOW TARGET /
		PARTIAL DATA / N/A / INFO) sits beside the attainment bar, and the details wrap over two
		full-width lines (they hold the window, the goal and the raw numbers).

	Performance: every Instance is built once. The section buttons and row slots are POOLS that
	grow on demand (never past ReportMaxTables + 1 / MAX_ROWS) and are reused for every summary;
	`render` does nothing unless something changed (the panel calls it on every state push).
	Layout re-runs only on ScreenManager.LayoutChanged (device / scale switch) — no per-frame work.

	Mobile + gamepad (owner R11):
		- Touch: control buttons, section buttons and rows grow to at least TouchUIConfig
		  .MinTapPoints (44 pt) at the current UI scale × the panel's fit (options.fitScale).
		- Gamepad: tab bar ↓ → the selected range button (`first`). Range row ↓ → the active
		  section; section → (right) its rows; rows ← back to the section. Moving through the
		  sections with the D-pad shows each one. Cards are display only (not selectable).

	Security: display only. The client sends a range INTENT; the server authorises every request
	and only ever answers admins. The page forgets loaded data when IsAdmin turns false.

	Connects to: Shared/Analytics/AnalyticsReport (parse, formatting, toText), Shared/Config/
	AnalyticsConfig (ranges, cache), Shared/Net/Remotes, UI/Kit/StudUI, Widgets/StudWindow,
	UI/ScreenManager (export screen, layout signal), Screens/Admin/AnalyticsExportScreen,
	the admin panel shell (Screens/Admin/AdminPanelScreen) which mounts this page.

	API (the panel's page shape):
		AnalyticsTab.new({ parent, width, height, setStatus, isActive, refresh, fitScale? })
			-> { frame, render, first, topRow }
		The frame starts hidden (Visible = false); the panel shows the active page.

	Example:
		local page = AnalyticsTab.new({
			parent = pageHost, width = 1500, height = 640,
			setStatus = function(text, ok) statusLabel.Text = text end,
			isActive = function() return activeTab == "Analytics" end,
			refresh = function() page.render() end,
		})
		page.frame.Visible = true
		page.render()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnalyticsConfig = require(ReplicatedStorage.Shared.Config.AnalyticsConfig)
local AnalyticsReport = require(ReplicatedStorage.Shared.Analytics.AnalyticsReport)
local Create = require(script.Parent.Parent.Parent.Create)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ScreenManager = require(script.Parent.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Parent.Widgets.StudWindow)
local TouchLayout = require(ReplicatedStorage.Shared.Util.TouchLayout)
local TouchUIConfig = require(ReplicatedStorage.Shared.Config.TouchUIConfig)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

export type Options = {
	parent: GuiObject,
	width: number,
	height: number,
	-- Panel status line: ok = true (success), false (warning / error), nil (neutral).
	setStatus: (text: string, ok: boolean?) -> (),
	isActive: () -> boolean,
	refresh: () -> (),
	-- The panel window's current fit scale (ModalShell); used for the 44 pt touch floor. Default 1.
	fitScale: (() -> number)?,
}

export type Page = {
	frame: Frame,
	render: () -> (),
	first: () -> GuiObject?,
	topRow: () -> { GuiObject },
}

-- Studio test handle of the built page (lets a playtest drive the tab without clicking).
export type Probe = {
	state: () -> { loaded: boolean, loading: boolean, error: string?, range: string, sections: number },
	selectRange: (range: string) -> (),
	copy: () -> boolean,
	copyRaw: () -> boolean,
}

type Summary = AnalyticsReport.Summary
type ColorName = UIStyleConfig.ColorName

local AnalyticsTab = {}

-- The last built page's probe (one admin panel per client).
AnalyticsTab.active = nil :: Probe?

local Neutral = UIStyleConfig.Neutral
local Style = UIStyleConfig

-- ── Layout constants (design px at 1080p) ────────────────────────────────────────────────────
local CONTROL_HEIGHT = 56 -- authored control button height (touch may grow it)
local CONTROL_GAP = 10
local CONTROL_LIP = 12 -- room under a stud button for its 3D lip + outline
local RANGE_WIDTH = 132
local REFRESH_WIDTH = 140
local COPY_WIDTH = 184
local RAW_WIDTH = 214
-- Below this width the status line moves under the buttons (its own row).
local STATUS_MIN_WIDTH = 280
local STATUS_ROW_HEIGHT = 44
local CARD_HEIGHT = 84
local CARD_GAP = 12
local CARDS_PER_ROW = 6
local SECTION_WIDTH = 300
local SECTION_HEIGHT = 48
local ROW_HEIGHT = 60
-- R122 scorecard rows: name + value, bar + verdict tag, two wrapped detail lines.
local TONE_ROW_HEIGHT = 108
local TONE_TAG_WIDTH = 170
local LIST_GAP = 16

-- Headline cards (spec §13 "headline cards (DAU, new, D1/D7, revenue, ARPDAU, payer %, median
-- session, tutorial completion, area funnel)") with their stud colour.
local CARD_KEYS: { { key: string, color: ColorName } } = {
	{ key = "dau", color = "blue" },
	{ key = "newPlayers", color = "blue" },
	{ key = "sessions", color = "blue" },
	{ key = "medianSession", color = "blue" },
	{ key = "d1", color = "purple" },
	{ key = "d7", color = "purple" },
	{ key = "robux", color = "green" },
	{ key = "arpdau", color = "green" },
	{ key = "conversion", color = "green" },
	{ key = "tutorialCompletion", color = "orange" },
	{ key = "area2Rate", color = "orange" },
	{ key = "padsBought", color = "orange" },
}
-- Card captions that differ from AnalyticsReport.HeadlineLabels (short enough for a card).
local CARD_CAPTIONS: { [string]: string } = {
	conversion = "Payer %",
	tutorialCompletion = "Tutorial done",
	area2Rate = "Reached area 2",
}

-- Pools: the section list holds the summary's tables + the client-built Daily section.
local MAX_SECTIONS = AnalyticsConfig.ReportMaxTables + 1
local MAX_ROWS = 60
local DAILY_ROWS = 60 -- the Daily section shows the newest days
-- Client spacing between requests (the server also rate-limits with a token bucket).
local MIN_REQUEST_GAP = 1.5
-- A range on screen older than this is re-requested on the next render.
local STALE_SECONDS = 300

-- What the status says for a refused request (server codes, Server/Analytics/Reports).
local ERROR_TEXT: { [string]: string } = {
	NotAuthorized = "Only admins can view analytics.",
	RateLimited = "Too many requests - wait a few seconds.",
	BadRequest = "The request was rejected.",
	Error = "The server could not load analytics.",
}

local localPlayer = Players.LocalPlayer

-- Verdict colours of R122 scorecard rows (AnalyticsReport.Tones): value text + verdict tag.
local TONE_COLOR: { [string]: Color3 } = {
	good = Style.Colors.green.accent,
	watch = Style.Colors.yellow.accent,
	bad = Style.Colors.red.accent,
	partial = Style.Colors.orange.accent,
	na = Neutral.TextDim,
	info = Style.Colors.blue.accent,
}

-- ── Small builders ───────────────────────────────────────────────────────────────────────────

-- An outlined label that truncates (or wraps) instead of overflowing its box.
local function label(options: {
	text: string,
	size: UDim2,
	textSize: number,
	color: Color3?,
	font: StudUI.FontRole?,
	align: Enum.TextXAlignment?,
	wrap: boolean?,
	parent: Instance?,
	name: string?,
}): TextLabel
	local made = StudUI.text({
		name = options.name,
		text = options.text,
		size = options.size,
		textSize = options.textSize,
		color = options.color,
		font = options.font or "body",
		align = options.align or Enum.TextXAlignment.Left,
		wrap = options.wrap,
		parent = options.parent,
	})
	if options.wrap ~= true then
		made.TextTruncate = Enum.TextTruncate.AtEnd
	end
	return made
end

-- A stud list button (section picker): stud face, dark outline that turns into the white
-- gamepad ring while selected, truncated left-aligned title. Returns the parts the pool keeps.
type ListButton = {
	button: TextButton,
	title: TextLabel,
	surface: StudWindow.Surface,
}
local function listButton(parent: Instance, index: number, height: number): ListButton
	local button = Create.new("TextButton", {
		Name = `Section{index}`,
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, height),
		Text = "",
		LayoutOrder = index,
		Visible = false,
		Selectable = true,
		-- Our outline is the gamepad highlight; the engine's selection image stays invisible.
		SelectionImageObject = Create.new("Frame", { BackgroundTransparency = 1 }),
	}) :: TextButton
	local surface = StudWindow.surface(button, "grey", {
		tile = Style.StudTile.Button,
		studTransparency = Style.StudTransparency.Button,
		corner = 8,
	})
	local edge = StudWindow.edge(button, 3)
	button.SelectionGained:Connect(function()
		edge.Color = Neutral.Text
		edge.Thickness = 4
	end)
	button.SelectionLost:Connect(function()
		edge.Color = Neutral.Edge
		edge.Thickness = 3
	end)
	local title = label({
		name = "Title",
		text = "",
		size = UDim2.new(1, -24, 1, 0),
		textSize = 22,
		parent = button,
	})
	title.Position = UDim2.fromOffset(12, 0)
	title.ZIndex = 3
	button.Parent = parent
	return { button = button, title = title, surface = surface }
end

-- One pooled ranked row: rank, name, value, stud bar, details, and (R122 scorecard rows) the
-- verdict tag. `tall` = the row currently has the scorecard shape (shapeRow).
type RowParts = {
	button: TextButton,
	rank: TextLabel,
	name: TextLabel,
	value: TextLabel,
	bar: StudUI.ProgressBar,
	extra: TextLabel,
	tag: TextLabel,
	trackWidth: number,
	tall: boolean,
}
local function rowSlot(parent: Instance, index: number, height: number, trackWidth: number): RowParts
	local button = Create.new("TextButton", {
		Name = `Row{index}`,
		AutoButtonColor = false,
		BackgroundColor3 = Neutral.Body,
		Size = UDim2.new(1, 0, 0, height),
		Text = "",
		LayoutOrder = index,
		Visible = false,
		-- Selectable so a gamepad can walk (and scroll) the list; activating does nothing.
		Selectable = true,
		SelectionImageObject = Create.new("Frame", { BackgroundTransparency = 1 }),
		Children = { Create.new("UICorner", { CornerRadius = UDim.new(0, 8) }) },
	}) :: TextButton
	local edge = StudWindow.edge(button, 2)
	button.SelectionGained:Connect(function()
		edge.Color = Neutral.Text
		edge.Thickness = 4
	end)
	button.SelectionLost:Connect(function()
		edge.Color = Neutral.Edge
		edge.Thickness = 2
	end)
	local rank = label({ text = tostring(index), size = UDim2.fromOffset(44, 26), textSize = 20, parent = button })
	rank.Name = "Rank"
	rank.TextColor3 = Neutral.TextDim
	rank.Position = UDim2.fromOffset(12, 4)
	local name = label({ text = "", size = UDim2.new(1, -330, 0, 26), textSize = 22, parent = button })
	name.Name = "Name"
	name.Position = UDim2.fromOffset(60, 4)
	local value = label({
		text = "",
		size = UDim2.fromOffset(250, 26),
		textSize = 22,
		font = "number",
		align = Enum.TextXAlignment.Right,
		color = Neutral.CashGreen,
		parent = button,
	})
	value.Name = "Value"
	value.AnchorPoint = Vector2.new(1, 0)
	value.Position = UDim2.new(1, -14, 0, 4)
	local bar = StudUI.progressBar({
		color = "teal",
		size = UDim2.fromOffset(trackWidth, 14),
		parent = button,
	})
	bar.frame.Position = UDim2.new(0, 60, 1, -22)
	local extra = label({
		text = "",
		size = UDim2.new(1, -(trackWidth + 90), 0, 22),
		textSize = 16,
		color = Neutral.TextDim,
		parent = button,
	})
	extra.Name = "Extra"
	extra.Position = UDim2.new(0, trackWidth + 76, 1, -26)
	-- R122 verdict tag beside the bar (outlined coloured text; hidden on plain ranked rows).
	local tag = label({
		text = "",
		size = UDim2.fromOffset(TONE_TAG_WIDTH, 24),
		textSize = 18,
		font = "title",
		parent = button,
	})
	tag.Name = "Tone"
	tag.Position = UDim2.fromOffset(trackWidth + 76, 32)
	tag.Visible = false
	button.Parent = parent
	return {
		button = button,
		rank = rank,
		name = name,
		value = value,
		bar = bar,
		extra = extra,
		tag = tag,
		trackWidth = trackWidth,
		tall = false,
	}
end

--[[
	Switches a pooled row between the plain ranked shape and the R122 scorecard shape (bar + verdict
	tag on line 2, the details wrapped over two full-width lines below). Only touches properties when
	the shape changes; the height itself is set by the caller (layout / renderRows).
]]
local function shapeRow(row: RowParts, tall: boolean)
	if row.tall == tall then
		return
	end
	row.tall = tall
	row.tag.Visible = tall
	row.extra.TextWrapped = tall
	if tall then
		row.bar.frame.Position = UDim2.fromOffset(60, 37)
		row.extra.Position = UDim2.fromOffset(60, 60)
		row.extra.Size = UDim2.new(1, -74, 0, 44)
	else
		row.bar.frame.Position = UDim2.new(0, 60, 1, -22)
		row.extra.Position = UDim2.new(0, row.trackWidth + 76, 1, -26)
		row.extra.Size = UDim2.new(1, -(row.trackWidth + 90), 0, 22)
	end
end

-- A dark scrolling well (sections / rows) with an outline, padding and a vertical list.
local function scrollWell(name: string, parent: Instance): ScrollingFrame
	local scroller = Create.new("ScrollingFrame", {
		Name = name,
		BackgroundColor3 = Neutral.Well,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 10,
		ScrollBarImageColor3 = Neutral.Text,
		ScrollBarImageTransparency = 0.4,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ElasticBehavior = Enum.ElasticBehavior.WhenScrollable,
		Selectable = false,
		Parent = parent,
		Children = {
			Create.new("UICorner", { CornerRadius = UDim.new(0, 8) }),
			Create.new("UIPadding", {
				PaddingTop = UDim.new(0, 8),
				PaddingBottom = UDim.new(0, 8),
				PaddingLeft = UDim.new(0, 8),
				PaddingRight = UDim.new(0, 16),
			}),
			Create.new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
		},
	}) :: ScrollingFrame
	StudWindow.edge(scroller, 3)
	return scroller
end

--[[
	Builds the page (see module header).
	@param options the panel's page options (parent, size, status / refresh hooks, fit scale)
	@return Page { frame, render, first, topRow }
]]
function AnalyticsTab.new(options: Options): Page
	local width, height = options.width, options.height
	local fitScale = options.fitScale

	-- State ---------------------------------------------------------------------------------------
	local range: string = "7d"
	local loaded: { [string]: { at: number, summary: Summary } } = {}
	local pendingId: number? = nil
	local pendingRange: string? = nil
	local progressText = ""
	local errorText: string? = nil
	local requestCounter = 0
	local lastRequestAt = -math.huge
	local sectionIndex = 1
	local dirty = true
	-- Remote / attribute listeners of this page (disconnected when the page is destroyed).
	local connections: { RBXScriptConnection } = {}

	local page = Create.new("Frame", {
		Name = "Analytics",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(width, height),
		Visible = false,
		Parent = options.parent,
	}) :: Frame

	-- Tap height for interactive rows: the authored size, raised to 44 pt on touch.
	local function tapHeight(authored: number): number
		if not ScreenManager.touchTargets() then
			return authored
		end
		local fit = if fitScale ~= nil then math.max(fitScale(), 0.05) else 1
		local minimum = TouchLayout.pointsToDesign(TouchUIConfig.MinTapPoints, ScreenManager.pointScale() * fit)
		return math.max(authored, minimum)
	end

	-- Row 1: ranges, refresh, copy, status ---------------------------------------------------------
	local request: (targetRange: string, force: boolean) -> ()
	local copyReport: () -> boolean
	local copyRaw: () -> boolean

	type Control = { button: StudUI.Button, width: number }
	local controls: { Control } = {}
	local rangeButtons: { [string]: StudUI.Button } = {}
	local rangeOrder: { TextButton } = {}
	for index, rangeId in AnalyticsConfig.Ranges do
		local button = StudUI.button({
			text = AnalyticsConfig.RangeLabels[rangeId] or rangeId,
			color = "grey",
			size = UDim2.fromOffset(RANGE_WIDTH, CONTROL_HEIGHT),
			textSize = 22,
			name = `Range_{rangeId}`,
			layoutOrder = index,
			parent = page,
			onActivated = function()
				if range ~= rangeId then
					range = rangeId
					sectionIndex = 1
					dirty = true
				end
				request(rangeId, false)
				options.refresh()
			end,
		})
		rangeButtons[rangeId] = button
		table.insert(rangeOrder, button.instance)
		table.insert(controls, { button = button, width = RANGE_WIDTH })
	end
	local refreshButton = StudUI.button({
		text = "REFRESH",
		color = "blue",
		size = UDim2.fromOffset(REFRESH_WIDTH, CONTROL_HEIGHT),
		textSize = 22,
		name = "Refresh",
		parent = page,
		onActivated = function()
			request(range, true)
			options.refresh()
		end,
	})
	table.insert(controls, { button = refreshButton, width = REFRESH_WIDTH })
	local copyButton = StudUI.button({
		text = "COPY FOR AI",
		color = "green",
		size = UDim2.fromOffset(COPY_WIDTH, CONTROL_HEIGHT),
		textSize = 22,
		name = "CopyForAI",
		parent = page,
		onActivated = function()
			copyReport()
		end,
	})
	table.insert(controls, { button = copyButton, width = COPY_WIDTH })
	local rawButton = StudUI.button({
		text = "COPY RAW DATA",
		color = "purple",
		size = UDim2.fromOffset(RAW_WIDTH, CONTROL_HEIGHT),
		textSize = 22,
		name = "CopyRawData",
		parent = page,
		onActivated = function()
			copyRaw()
		end,
	})
	table.insert(controls, { button = rawButton, width = RAW_WIDTH })
	local status = label({
		name = "Status",
		text = "",
		size = UDim2.fromOffset(STATUS_MIN_WIDTH, CONTROL_HEIGHT),
		textSize = 18,
		color = Neutral.TextDim,
		wrap = true,
		parent = page,
	})

	-- Row 2: headline cards ------------------------------------------------------------------------
	local cardWidth = math.floor((width - CARD_GAP * (CARDS_PER_ROW - 1)) / CARDS_PER_ROW)
	local cards: { [string]: TextLabel } = {}
	local cardFrames: { Frame } = {}
	for index, entry in CARD_KEYS do
		local card = StudUI.card({
			name = `Card_{entry.key}`,
			color = entry.color,
			size = UDim2.fromOffset(cardWidth, CARD_HEIGHT),
			parent = page,
		})
		local caption = label({
			text = string.upper(CARD_CAPTIONS[entry.key] or AnalyticsReport.HeadlineLabels[entry.key] or entry.key),
			size = UDim2.new(1, 0, 0, 22),
			textSize = 17,
			parent = card.content,
		})
		caption.ZIndex = 3
		local value = StudUI.text({
			name = "Value",
			text = "-",
			textSize = 38,
			font = "number",
			scaled = true,
			align = Enum.TextXAlignment.Left,
			size = UDim2.new(1, 0, 0, 40),
			position = UDim2.fromOffset(0, 24),
			zIndex = 3,
			parent = card.content,
		})
		cards[entry.key] = value
		cardFrames[index] = card.frame
	end

	-- Row 3: sections + rows -----------------------------------------------------------------------
	local sectionList = scrollWell("Sections", page)
	local rowList = scrollWell("Rows", page)
	local rowsWidth = width - SECTION_WIDTH - LIST_GAP
	local trackWidth = math.floor(rowsWidth * 0.4)
	-- Centred message for loading / empty / error states (over the rows area).
	local message = StudUI.text({
		name = "Message",
		text = "",
		textSize = 26,
		font = "body",
		color = Neutral.TextDim,
		wrap = true,
		size = UDim2.fromOffset(rowsWidth - 80, 140),
		anchor = Vector2.new(0.5, 0.5),
		zIndex = 4,
		parent = page,
	})
	-- "+N more rows" under a table the server cut (display only, never selectable).
	local moreLabel = label({
		name = "MoreRows",
		text = "",
		size = UDim2.new(1, -24, 0, 30),
		textSize = 18,
		color = Neutral.TextDim,
		wrap = true,
		parent = rowList,
	})
	moreLabel.AutomaticSize = Enum.AutomaticSize.Y
	moreLabel.LayoutOrder = MAX_ROWS + 1
	moreLabel.Visible = false

	-- Pools (grown on demand).
	local sections: { ListButton } = {}
	local rows: { RowParts } = {}
	local sectionHeight = tapHeight(SECTION_HEIGHT)
	local rowHeight = tapHeight(ROW_HEIGHT)
	local toneRowHeight = tapHeight(TONE_ROW_HEIGHT)
	local selectSection: (index: number) -> ()

	-- Makes sure the first `count` section buttons exist (bounded by MAX_SECTIONS).
	local function ensureSections(count: number)
		for index = #sections + 1, math.min(count, MAX_SECTIONS) do
			local made = listButton(sectionList, index, sectionHeight)
			made.button.Activated:Connect(function()
				selectSection(index)
			end)
			-- D-pad browsing: focusing a section shows it.
			made.button.SelectionGained:Connect(function()
				if sectionIndex ~= index then
					selectSection(index)
				end
			end)
			table.insert(sections, made)
		end
	end

	-- Makes sure the first `count` row slots exist (bounded by MAX_ROWS).
	local function ensureRows(count: number)
		for index = #rows + 1, math.min(count, MAX_ROWS) do
			table.insert(rows, rowSlot(rowList, index, rowHeight, trackWidth))
		end
	end

	-- Layout (event-driven: build + ScreenManager.LayoutChanged) ----------------------------------

	local function layout()
		local controlHeight = tapHeight(CONTROL_HEIGHT)
		local x = 0
		for _, control in controls do
			control.button.instance.Size = UDim2.fromOffset(control.width, controlHeight)
			control.button.instance.Position = UDim2.fromOffset(x, 0)
			x += control.width + CONTROL_GAP
		end
		local statusWidth = width - x
		local cardsTop: number
		if statusWidth >= STATUS_MIN_WIDTH then
			status.Position = UDim2.fromOffset(x, 0)
			status.Size = UDim2.fromOffset(statusWidth, controlHeight)
			cardsTop = controlHeight + CONTROL_LIP + 6
		else
			-- Narrow page: the status gets its own line under the buttons.
			status.Position = UDim2.fromOffset(0, controlHeight + CONTROL_LIP)
			status.Size = UDim2.fromOffset(width, STATUS_ROW_HEIGHT)
			cardsTop = controlHeight + CONTROL_LIP + STATUS_ROW_HEIGHT + 6
		end
		for index, frame in cardFrames do
			local column = (index - 1) % CARDS_PER_ROW
			local rowIndex = (index - 1) // CARDS_PER_ROW
			frame.Position =
				UDim2.fromOffset(column * (cardWidth + CARD_GAP), cardsTop + rowIndex * (CARD_HEIGHT + CARD_GAP))
		end
		local cardRows = math.ceil(#CARD_KEYS / CARDS_PER_ROW)
		local listTop = cardsTop + cardRows * CARD_HEIGHT + (cardRows - 1) * CARD_GAP + LIST_GAP
		local listHeight = math.max(120, height - listTop)
		sectionList.Position = UDim2.fromOffset(0, listTop)
		sectionList.Size = UDim2.fromOffset(SECTION_WIDTH, listHeight)
		rowList.Position = UDim2.fromOffset(SECTION_WIDTH + LIST_GAP, listTop)
		rowList.Size = UDim2.fromOffset(rowsWidth, listHeight)
		message.Position = UDim2.fromOffset(SECTION_WIDTH + LIST_GAP + rowsWidth / 2, listTop + listHeight / 2)
		-- Touch: thicker scroll bars are easier to grab.
		local barThickness = if ScreenManager.touchTargets() then 16 else 10
		sectionList.ScrollBarThickness = barThickness
		rowList.ScrollBarThickness = barThickness
		-- Pools keep their slots; only their heights follow the tap size.
		sectionHeight = tapHeight(SECTION_HEIGHT)
		rowHeight = tapHeight(ROW_HEIGHT)
		toneRowHeight = tapHeight(TONE_ROW_HEIGHT)
		for _, section in sections do
			section.button.Size = UDim2.new(1, 0, 0, sectionHeight)
		end
		for _, row in rows do
			row.button.Size = UDim2.new(1, 0, 0, if row.tall then toneRowHeight else rowHeight)
		end
	end
	layout()
	local layoutConnection = ScreenManager.LayoutChanged:Connect(layout)

	-- Rendering ---------------------------------------------------------------------------------

	-- sectionsOf memo: the list built for the summary currently shown. Section browsing (D-pad
	-- focus fires selectSection per button) re-renders often; the list only changes with a new
	-- summary, so it is built once per summary instead of on every render.
	local sectionsFor: Summary? = nil
	local sectionsList: { AnalyticsReport.Table } = {}

	-- The sections of a summary: its tables plus a client-built "Daily activity" section first.
	local function sectionsOf(summary: Summary): { AnalyticsReport.Table }
		if sectionsFor == summary then
			return sectionsList
		end
		local list = table.clone(summary.tables)
		local daily: { AnalyticsReport.Row } = {}
		local largest = 0
		for _, day in summary.daily do
			largest = math.max(largest, day.dau)
		end
		for index = #summary.daily, math.max(1, #summary.daily - DAILY_ROWS + 1), -1 do
			local day = summary.daily[index]
			table.insert(daily, {
				id = day.day,
				label = day.day,
				value = day.dau,
				display = `{AnalyticsReport.formatInteger(day.dau)} DAU`,
				extra = `{AnalyticsReport.formatInteger(day.new)} new · {AnalyticsReport.formatInteger(day.sessions)} sessions · R$ {AnalyticsReport.formatInteger(
					day.robux
				)} · {AnalyticsReport.formatInteger(day.payers)} payers · {AnalyticsReport.formatInteger(day.pads)} pads`,
				share = if largest > 0 then day.dau / largest else 0,
			})
		end
		table.insert(list, 1, {
			id = "daily",
			title = "Daily activity",
			note = "Newest day first (UTC).",
			total = 0,
			rows = daily,
		})
		sectionsFor = summary
		sectionsList = list
		return list
	end

	local function currentSummary(): Summary?
		local entry = loaded[range]
		return if entry ~= nil then entry.summary else nil
	end

	-- Gamepad links that depend on what is visible. (NextSelection* = nil clears a link; the
	-- engine then falls back to spatial navigation — the properties are typed non-optional.)
	local function link()
		local activeSection = sections[sectionIndex]
		local firstRow = rows[1]
		local firstSection = sections[1]
		local down: GuiObject? = if firstSection ~= nil
				and firstSection.button.Visible
				and activeSection ~= nil
			then activeSection.button
			else nil
		local right: GuiObject? = if firstRow ~= nil and firstRow.button.Visible then firstRow.button else nil
		for _, control in controls do
			control.button.instance.NextSelectionDown = down :: any
		end
		for index, section in sections do
			section.button.NextSelectionRight = right :: any
			if index == 1 then
				section.button.NextSelectionUp = rangeButtons[range].instance
			end
		end
		for _, row in rows do
			row.button.NextSelectionLeft = (if activeSection ~= nil then activeSection.button else nil) :: any
		end
		if firstRow ~= nil then
			firstRow.button.NextSelectionUp = copyButton.instance
		end
	end

	-- The shown list's identity (range + section index + section id): the row list scrolls back to
	-- the top only when it changes, so a refresh of the same section keeps the reader's place.
	local shownRowsKey = ""

	local function renderRows(summary: Summary?)
		local list = if summary ~= nil then sectionsOf(summary) else {}
		if sectionIndex > #list then
			sectionIndex = 1
		end
		ensureSections(#list)
		for index, section in sections do
			local data = list[index]
			section.button.Visible = data ~= nil
			if data ~= nil then
				section.title.Text = data.title
				local active = index == sectionIndex
				section.surface.setColor(if active then "yellow" else "grey")
			end
		end
		local section = list[sectionIndex]
		local sectionRows = if section ~= nil then section.rows else {}
		ensureRows(#sectionRows)
		for index, row in rows do
			local data = sectionRows[index]
			row.button.Visible = data ~= nil
			if data ~= nil then
				-- R122 scorecard rows (a verdict tone) take the tall shape + verdict colours.
				local tone = data.tone
				local tall = tone ~= nil
				shapeRow(row, tall)
				row.button.Size = UDim2.new(1, 0, 0, if tall then toneRowHeight else rowHeight)
				row.rank.Text = tostring(index)
				row.name.Text = if data.label ~= data.id then `{data.label}  ({data.id})` else data.label
				row.value.Text = data.display
				row.value.TextColor3 = if tone ~= nil then TONE_COLOR[tone] or Neutral.CashGreen else Neutral.CashGreen
				row.bar.setProgress(data.share)
				row.extra.Text = data.extra
				if tone ~= nil then
					row.tag.Text = AnalyticsReport.ToneLabels[tone] or ""
					row.tag.TextColor3 = TONE_COLOR[tone] or Neutral.TextDim
				end
			end
		end
		-- Rows the server (or the parser) left out of this table: never a silent cut.
		local more = if section ~= nil then (section.more or 0) + math.max(0, #sectionRows - MAX_ROWS) else 0
		moreLabel.Visible = more > 0
		if more > 0 then
			-- Only COPY RAW DATA is sure to hold them: the rows a table cuts are its smallest, and
			-- so are the keys COPY FOR AI's JSON trim drops first (its countersOmitted says how many).
			moreLabel.Text =
				`+{AnalyticsReport.formatInteger(more)} more rows not shown here. RAW pages and COPY FOR AI have limits; check their omission counts.`
		end
		-- Empty state only when a summary exists but this section has no rows.
		local empty = summary ~= nil and (section == nil or #sectionRows == 0)
		if empty and section ~= nil and section.note ~= "" then
			message.Text = `No data in this range yet.\n{section.note}`
		elseif empty then
			message.Text = "No data in this range yet."
		else
			message.Text = ""
		end
		local rowsKey = `{range}|{sectionIndex}|{if section ~= nil then section.id else ""}`
		if rowsKey ~= shownRowsKey then
			shownRowsKey = rowsKey
			rowList.CanvasPosition = Vector2.zero
		end
	end

	local function renderCards(summary: Summary?)
		for key, value in cards do
			local number = if summary ~= nil then summary.headline[key] else nil
			value.Text = if number ~= nil then AnalyticsReport.formatHeadline(key, number) else "-"
		end
	end

	local function renderStatus(summary: Summary?)
		if pendingId ~= nil and pendingRange == range then
			status.Text = if progressText ~= "" then progressText else "LOADING..."
			status.TextColor3 = Style.Colors.yellow.bottom
		elseif errorText ~= nil then
			status.Text = errorText
			status.TextColor3 = Neutral.Danger
		elseif summary ~= nil then
			-- Full window / time / omission facts stay in the report coverage and the exports.
			local compact, warning = AnalyticsReport.compactStatus(summary)
			status.Text = compact
			status.TextColor3 = if warning then Style.Colors.yellow.bottom else Neutral.TextDim
		else
			status.Text = ""
		end
	end

	-- Full render (only when something changed).
	local function renderAll()
		for rangeId, button in rangeButtons do
			button.setColor(if rangeId == range then "yellow" else "grey")
		end
		local summary = currentSummary()
		copyButton.setState(if summary == nil then "disabled" else "normal")
		rawButton.setState(if summary == nil or (summary.rawId or 0) < 1 then "disabled" else "normal")
		renderStatus(summary)
		renderCards(summary)
		renderRows(summary)
		if summary == nil then
			if pendingId ~= nil then
				message.Text = if progressText ~= ""
					then `Loading analytics...\n{progressText}`
					else "Loading analytics..."
			elseif errorText ~= nil then
				message.Text = `{errorText}\nPress REFRESH to try again.`
			else
				message.Text = "Pick a range to load analytics."
			end
		elseif summary.note ~= "" and message.Text == "" and #summary.daily == 0 then
			message.Text = summary.note
		end
		link()
	end

	-- Shows section `index` (renderRows also repaints the active / idle section buttons).
	selectSection = function(index: number)
		sectionIndex = index
		renderRows(currentSummary())
		link()
	end

	-- Exports -----------------------------------------------------------------------------------

	-- The footer title of an export ("ANALYTICS · 7 DAYS").
	local function exportTitle(): string
		return `ANALYTICS · {AnalyticsConfig.RangeLabels[range] or range}`
	end

	-- COPY FOR AI: opens the export dialog with the full report (false if nothing is loaded).
	copyReport = function(): boolean
		local entry = loaded[range]
		if entry == nil then
			options.setStatus("Load a range first.", false)
			return false
		end
		ScreenManager.open("AnalyticsExport", {
			mode = "ai",
			text = AnalyticsReport.toText(entry.summary),
			title = exportTitle(),
		})
		return true
	end

	--[[
		COPY RAW DATA: opens the export dialog on page 1 of the server's uncapped snapshot of the
		loaded summary (every counter, paged). False when nothing is loaded or the summary came
		without a snapshot (REFRESH first).
	]]
	copyRaw = function(): boolean
		local entry = loaded[range]
		if entry == nil then
			options.setStatus("Load a range first.", false)
			return false
		end
		local rawId = entry.summary.rawId or 0
		if rawId < 1 then
			options.setStatus("No raw data for this load - press REFRESH.", false)
			return false
		end
		ScreenManager.open("AnalyticsExport", { mode = "raw", rawId = rawId, range = range, title = exportTitle() })
		return true
	end

	-- Requests ----------------------------------------------------------------------------------

	--[[
		Asks the server for `targetRange` (or reuses a fresh cached load unless `force`). At most
		one request per range in flight and one per MIN_REQUEST_GAP seconds.
	]]
	request = function(targetRange: string, force: boolean)
		local cached = loaded[targetRange]
		if not force and cached ~= nil and os.clock() - cached.at < AnalyticsConfig.CacheSeconds then
			dirty = true
			return
		end
		if pendingId ~= nil and pendingRange == targetRange then
			return -- already loading this range
		end
		local now = os.clock()
		if now - lastRequestAt < MIN_REQUEST_GAP then
			options.setStatus("Slow down a little...", false)
			return
		end
		lastRequestAt = now
		requestCounter += 1
		pendingId = requestCounter
		pendingRange = targetRange
		progressText = ""
		errorText = nil
		dirty = true
		Remotes.event("AnalyticsRequest"):FireServer(requestCounter, targetRange)
	end

	-- Server replies: progress, the summary, or an error code. Stale ids are ignored.
	table.insert(
		connections,
		Remotes.event("AnalyticsReport").OnClientEvent:Connect(function(rawId: unknown, rawPayload: unknown)
			if type(rawId) ~= "number" or rawId ~= pendingId or type(rawPayload) ~= "table" then
				return -- stale or malformed
			end
			local payload = rawPayload :: { [string]: unknown }
			local code = if type(payload.code) == "string" then payload.code :: string else "Error"
			if code == "Loading" then
				local done = if type(payload.done) == "number" then payload.done :: number else 0
				local total = if type(payload.total) == "number" then payload.total :: number else 0
				progressText = `LOADING {math.floor(done)} / {math.floor(total)}`
			elseif code == "Ok" then
				local summary = AnalyticsReport.parse(payload.summary)
				local target = pendingRange
				pendingId, pendingRange = nil, nil
				if summary ~= nil and target ~= nil then
					loaded[target] = { at = os.clock(), summary = summary }
					errorText = nil
				else
					errorText = ERROR_TEXT.Error
				end
			else
				pendingId, pendingRange = nil, nil
				errorText = ERROR_TEXT[code] or ERROR_TEXT.Error
			end
			dirty = true
			if options.isActive() then
				options.refresh()
			end
		end)
	)

	-- Rights can be revoked while the panel is open: forget loaded data then.
	table.insert(
		connections,
		localPlayer:GetAttributeChangedSignal("IsAdmin"):Connect(function()
			if localPlayer:GetAttribute("IsAdmin") ~= true then
				table.clear(loaded)
				pendingId, pendingRange = nil, nil
				dirty = true
			end
		end)
	)

	-- A rebuilt panel destroys the old page: drop its listeners with it.
	page.Destroying:Once(function()
		layoutConnection:Disconnect()
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
	end)

	-- Page API ----------------------------------------------------------------------------------

	--[[ Cheap unless something changed; loads the range on the first visit / when stale. ]]
	local function render()
		if not options.isActive() then
			return
		end
		local cached = loaded[range]
		if pendingId == nil and errorText == nil and (cached == nil or os.clock() - cached.at > STALE_SECONDS) then
			request(range, cached ~= nil)
		end
		if dirty then
			dirty = false
			renderAll()
		end
	end

	AnalyticsTab.active = {
		state = function()
			local summary = currentSummary()
			return {
				loaded = summary ~= nil,
				loading = pendingId ~= nil,
				error = errorText,
				range = range,
				sections = if summary ~= nil then #summary.tables + 1 else 0,
			}
		end,
		selectRange = function(target: string)
			if range ~= target then
				range = target
				sectionIndex = 1
				dirty = true
			end
			request(target, false)
			options.refresh()
		end,
		copy = function(): boolean
			return copyReport()
		end,
		copyRaw = function(): boolean
			return copyRaw()
		end,
	}

	return {
		frame = page,
		render = render,
		first = function(): GuiObject?
			return rangeButtons[range].instance
		end,
		topRow = function(): { GuiObject }
			local top: { GuiObject } = {}
			for _, button in rangeOrder do
				table.insert(top, button)
			end
			table.insert(top, refreshButton.instance)
			table.insert(top, copyButton.instance)
			table.insert(top, rawButton.instance)
			return top
		end,
	}
end

-- Not frozen: `active` is set when the page is built.
return AnalyticsTab
