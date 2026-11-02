--!strict
--[[
	AnalyticsExportScreen — the COPY FOR AI / COPY RAW DATA dialog of the admin panel's Analytics
	tab (screen name "AnalyticsExport"; spec §13 "COPY FOR AI / COPY RAW DATA exports (paged text
	the owner can paste into an AI)"). Ported from RoBeasts' Screens/AnalyticsExport and rebuilt
	as a SellNukes stud window (Kit/StudUI.window inside Widgets/ModalShell).

	Why a TextBox: Roblox gives games no API to write the system clipboard. So this dialog shows the
	whole report (AnalyticsReport.toText: markdown summary + one JSON block with the raw counters)
	in a read-only, scrollable TextBox, focuses it and pre-selects ALL of its text — the admin only
	presses Ctrl+C (Cmd+C on Mac) and pastes it into an AI assistant. SELECT ALL re-selects if the
	selection was lost (e.g. after a click). A controller cannot copy text, so the hint says a
	keyboard is needed; B / the X key / the red X close the dialog.

	Opening (from Screens/Admin/AnalyticsTab; ScreenManager.open args):
		ScreenManager.open("AnalyticsExport", { mode = "ai", text = reportText, title = "ANALYTICS · 7 DAYS" })
		ScreenManager.open("AnalyticsExport", { mode = "raw", rawId = summary.rawId, range = "today",
			title = "ANALYTICS · TODAY" })
	Opening it again while open re-runs onOpen with the new args (refresh in place). The text is
	capped at AnalyticsConfig.ReportMaxChars.

	COPY RAW DATA: every counter of the range, uncapped, in pages (the server's Analytics/
	AnalyticsRaw snapshot of the summary the admin loaded). The dialog asks for one page at a
	time over AnalyticsRawRequest(requestId, rawId, page) and gets AnalyticsRawPage(requestId,
	{ ok, code, page? }); AnalyticsReport.parseRawPage validates the page and rawText writes it.
	Pages already fetched are kept for this snapshot, so flipping back costs no request.
	Page controls:
		gamepad  LB / RB (a sink action while open; glyph hint in the footer)
		mouse    PREV / NEXT footer buttons (selectable on gamepad too)
		touch    the same buttons, grown to ≥ 44 pt
	One request in flight at a time, at least MIN_PAGE_GAP s apart (the server also rate-limits).
	After a failed page (Shared/Analytics/RawPaging holds the rules): PREV / LB still goes back to
	pages already fetched; NEXT / RB (it reads RETRY there) retries a RateLimited / Timeout / Error
	page; an Expired / NotAuthorized / BadRequest snapshot is "dead": no more requests, the fetched
	pages stay readable and the rest say to REFRESH.

	While open, LB / RB are sunk so the admin panel underneath cannot switch tabs and steal the
	gamepad selection (in RAW mode they turn the page instead).

	Mobile (owner R11): ModalShell shrinks the window to the phone; while targets are
	finger-sized (ScreenManager.touchTargets) the footer buttons grow to ≥ 44 pt, the report and
	hint text are lifted to ≥ 11 / 12 pt, the scroll bar thickens, and the box is NOT auto-focused
	(that would raise the on-screen keyboard over the report) — SELECT ALL still focuses it.
	Re-laid out only on ScreenManager.LayoutChanged / input mode changes (no per-frame work).

	Security: admin-only display. The server answers analytics requests only for admins; this
	screen also refuses to open unless the server-set IsAdmin attribute is true.

	Connects to: Shared/Analytics/{AnalyticsReport, RawPaging}, Shared/Config/AnalyticsConfig,
	Shared/Net/Remotes, UI/Kit/StudUI, Widgets/{ModalShell, InputGlyph}, UI/ScreenManager,
	Controllers/InputController, Screens/Admin/AnalyticsTab (the opener).

	Example:
		ScreenManager.open("AnalyticsExport", { mode = "ai", text = AnalyticsReport.toText(summary),
			title = "ANALYTICS · 7 DAYS" })
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnalyticsConfig = require(ReplicatedStorage.Shared.Config.AnalyticsConfig)
local AnalyticsReport = require(ReplicatedStorage.Shared.Analytics.AnalyticsReport)
local Create = require(script.Parent.Parent.Parent.Create)
local InputController = require(script.Parent.Parent.Parent.Parent.Controllers.InputController)
local InputGlyph = require(script.Parent.Parent.Parent.Widgets.InputGlyph)
local ModalShell = require(script.Parent.Parent.Parent.Widgets.ModalShell)
local RawPaging = require(ReplicatedStorage.Shared.Analytics.RawPaging)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ScreenManager = require(script.Parent.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Parent.Widgets.StudWindow)
local Theme = require(script.Parent.Parent.Parent.Theme)
local TouchLayout = require(ReplicatedStorage.Shared.Util.TouchLayout)
local TouchUIConfig = require(ReplicatedStorage.Shared.Config.TouchUIConfig)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local NAME = "AnalyticsExport"
-- Authored window size (design px at 1080p); ModalShell shrinks it on small screens.
local SIZE = Vector2.new(1400, 860)
local HINT_HEIGHT = 56 -- desktop hint height (touch: HINT_HEIGHT_TOUCH)
local HINT_HEIGHT_TOUCH = 96
local GAP = 10
local FOOTER_BUTTON_HEIGHT = 60 -- authored (touch may grow it to 44 pt)
local FOOTER_LIP = 10 -- room under a stud button for its lip + outline
local REPORT_TEXT_SIZE = 16 -- desktop report text (touch: lifted to ≥ REPORT_MIN_POINTS)
local REPORT_MIN_POINTS = 11
local HINT_TEXT_SIZE = 20
local HINT_MIN_POINTS = 12
local SINK_ACTION = "SellNukesAnalyticsExportSink"
-- RAW paging: seconds between page requests, and how long an unanswered one blocks.
local MIN_PAGE_GAP = 0.4
local PAGE_TIMEOUT = 10

local Neutral = UIStyleConfig.Neutral

local REPORT_HINT =
	"The whole report is selected: press Ctrl+C (Cmd+C on Mac) to copy it, then paste it into your AI assistant. A controller can't copy - use a keyboard."

-- What the dialog says for a refused page request (server codes, Server/Analytics/AnalyticsRaw).
-- The snapshot lifetime comes from the config (Raw.KeepSeconds), never a number typed in here.
local RAW_ERRORS: { [string]: string } = {
	RateLimited = "Too many page requests - wait a second, then press RETRY / RB (PREV / LB goes back).",
	Expired = `This RAW DATA snapshot expired (kept {AnalyticsConfig.Raw.KeepSeconds // 60} minutes). Pages already shown stay readable with PREV / LB; for the rest close, press REFRESH, then COPY RAW DATA again.`,
	NotAuthorized = "Only admins can export analytics.",
	BadRequest = "The page request was rejected. Close and press COPY RAW DATA again.",
	Error = "The server could not build this page. Press RETRY / RB in a moment (PREV / LB goes back).",
	Timeout = "No answer from the server yet. Press RETRY / RB to ask again (PREV / LB goes back).",
}

-- The RAW mode's state for one server snapshot.
type RawState = {
	rawId: number,
	range: string,
	title: string,
	page: number,
	pages: number, -- 0 until the first page arrives
	texts: { [number]: string }, -- fetched pages of this snapshot
	pendingId: number?, -- request in flight
	pendingPage: number,
	requestedAt: number,
	errorText: string?, -- what failed on the page on screen (nil = loading or shown)
	errorCode: string?, -- its code (RAW_ERRORS key): retryable or not
	dead: string?, -- a non-retryable code for the whole snapshot: no more requests
}

-- Studio probe state (read by AnalyticsExportScreen.probe; set by build).
local probeState: () -> { [string]: any } = function()
	return { built = false }
end
-- The PREV / NEXT / LB / RB page handler (set by build; AnalyticsExportScreen.testTurn).
local pageTurner: ((delta: number) -> ())? = nil

--[[
	Builds the dialog (ScreenManager calls this once, lazily, on the first open).
	@param gui the screen's ScreenGui
	@return ScreenHandle (onOpen(args) / onClose / defaultSelection)
]]
local function build(gui: ScreenGui): ScreenManager.ScreenHandle
	local window = StudUI.window({
		title = "COPY FOR AI",
		color = "purple",
		icon = "Star",
		size = SIZE,
		name = `{NAME}Window`,
		onClose = function()
			ScreenManager.close(NAME)
		end,
	})
	local shell = ModalShell.new(gui, window.frame, SIZE)
	local body = window.body

	local hint = StudUI.text({
		name = "Hint",
		text = REPORT_HINT,
		textSize = HINT_TEXT_SIZE,
		font = "body",
		color = UIStyleConfig.Colors.yellow.bottom,
		align = Enum.TextXAlignment.Left,
		alignY = Enum.TextYAlignment.Top,
		wrap = true,
		size = UDim2.new(1, 0, 0, HINT_HEIGHT),
		parent = body,
	})

	local scroller = Create.new("ScrollingFrame", {
		Name = "Scroller",
		BackgroundColor3 = Neutral.Well,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 10,
		ScrollBarImageColor3 = Neutral.Text,
		ScrollBarImageTransparency = 0.4,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Selectable = false,
		Parent = body,
		Children = {
			Create.new("UICorner", { CornerRadius = UDim.new(0, 8) }),
			Create.new("UIPadding", {
				PaddingTop = UDim.new(0, 12),
				PaddingBottom = UDim.new(0, 12),
				PaddingLeft = UDim.new(0, 14),
				PaddingRight = UDim.new(0, 20),
			}),
		},
	}) :: ScrollingFrame
	StudWindow.edge(scroller, 3)

	-- Read-only, multi-line, never cleared on focus; selection + Ctrl+C still work. Plain mono
	-- text (no outline): this is data to copy, legibility first.
	local box = Create.new("TextBox", {
		Name = "Report",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Text = "",
		TextEditable = false,
		ClearTextOnFocus = false,
		MultiLine = true,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		FontFace = Theme.Fonts.Mono,
		TextSize = REPORT_TEXT_SIZE,
		TextColor3 = Neutral.Text,
		Selectable = false,
		Parent = scroller,
	}) :: TextBox

	-- Footer: [LB RB Pages] [PREV] [NEXT] [size] [SELECT ALL], right-aligned.
	local footer = Create.new("Frame", {
		Name = "Footer",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, FOOTER_BUTTON_HEIGHT + FOOTER_LIP),
		Parent = body,
		Children = {
			Create.new("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Right,
				VerticalAlignment = Enum.VerticalAlignment.Top,
				Padding = UDim.new(0, 14),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		},
	}) :: Frame

	-- Focuses the box and selects every character (SelectionStart 1 → CursorPosition end + 1).
	local function selectAll()
		box:CaptureFocus()
		box.SelectionStart = 1
		box.CursorPosition = #box.Text + 1
	end
	-- Pre-selects after a text change, except where focusing a TextBox would raise an on-screen
	-- keyboard (controller: console keyboard; touch: phone keyboard over the report).
	local function autoSelect()
		if
			InputController.mode ~= "Gamepad"
			and InputController.mode ~= "Touch"
			and not ScreenManager.touchTargets()
		then
			task.defer(selectAll)
		end
	end

	local turnPage: (delta: number) -> ()

	local pageHint = Create.new("Frame", {
		Name = "PageHint",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(0, FOOTER_BUTTON_HEIGHT),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 1,
		Visible = false,
		Parent = footer,
		Children = {
			Create.new("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, 6),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		},
	}) :: Frame
	local lbGlyph = InputGlyph.dynamic(nil, Enum.KeyCode.ButtonL1, 34)
	lbGlyph.LayoutOrder = 1
	lbGlyph.Parent = pageHint
	local rbGlyph = InputGlyph.dynamic(nil, Enum.KeyCode.ButtonR1, 34)
	rbGlyph.LayoutOrder = 2
	rbGlyph.Parent = pageHint
	StudUI.text({
		name = "PagesText",
		text = "Pages",
		textSize = 22,
		font = "body",
		color = Neutral.TextDim,
		size = UDim2.fromOffset(80, 34),
		align = Enum.TextXAlignment.Left,
		layoutOrder = 3,
		parent = pageHint,
	})

	local prevButton = StudUI.button({
		text = "PREV",
		color = "grey",
		size = UDim2.fromOffset(150, FOOTER_BUTTON_HEIGHT),
		textSize = 26,
		name = "PrevPage",
		layoutOrder = 2,
		parent = footer,
		onActivated = function()
			turnPage(-1)
		end,
	})
	prevButton.instance.Visible = false
	local nextButton = StudUI.button({
		text = "NEXT",
		color = "blue",
		size = UDim2.fromOffset(150, FOOTER_BUTTON_HEIGHT),
		textSize = 26,
		name = "NextPage",
		layoutOrder = 3,
		parent = footer,
		onActivated = function()
			turnPage(1)
		end,
	})
	nextButton.instance.Visible = false
	local sizeLabel = StudUI.text({
		name = "Size",
		text = "",
		textSize = 20,
		font = "body",
		color = Neutral.TextDim,
		size = UDim2.fromOffset(400, FOOTER_BUTTON_HEIGHT),
		align = Enum.TextXAlignment.Right,
		wrap = true,
		layoutOrder = 4,
		parent = footer,
	})
	local selectButton = StudUI.button({
		text = "SELECT ALL",
		color = "green",
		size = UDim2.fromOffset(240, FOOTER_BUTTON_HEIGHT),
		textSize = 26,
		name = "SelectAll",
		layoutOrder = 5,
		parent = footer,
		onActivated = selectAll,
	})
	-- Gamepad: PREV ↔ NEXT ↔ SELECT ALL along the footer (spatial navigation handles the rest).
	prevButton.instance.NextSelectionRight = nextButton.instance
	nextButton.instance.NextSelectionLeft = prevButton.instance
	nextButton.instance.NextSelectionRight = selectButton.instance
	selectButton.instance.NextSelectionLeft = nextButton.instance

	------------------------------------------------------------------ layout (desktop / touch)
	--[[
		Applies the desktop or touch geometry. Desktop: every value is the authored one. Touch
		(ScreenManager.touchTargets): the footer buttons are at least 44 pt tall at the current UI
		scale × window fit, the hint is taller (its lifted text wraps to more lines), report /
		hint text sizes are lifted to ≥ 11 / 12 pt, the scroll bar is thicker and the report box
		is at least one tap tall (tappable even while empty).
	]]
	local function applyLayout()
		local touch = ScreenManager.touchTargets()
		local points = math.max(ScreenManager.pointScale() * shell.scale(), 0.05)
		local tap = if touch then TouchLayout.pointsToDesign(TouchUIConfig.MinTapPoints, points) else 0
		local buttonHeight = math.max(FOOTER_BUTTON_HEIGHT, tap)
		for _, button in { prevButton, nextButton, selectButton } do
			local current = button.instance.Size
			button.instance.Size = UDim2.fromOffset(current.X.Offset, buttonHeight)
		end
		sizeLabel.Size = UDim2.fromOffset(400, buttonHeight)
		pageHint.Size = UDim2.fromOffset(0, buttonHeight)
		local footerHeight = buttonHeight + FOOTER_LIP
		footer.Size = UDim2.new(1, 0, 0, footerHeight)
		local hintHeight = if touch then HINT_HEIGHT_TOUCH else HINT_HEIGHT
		hint.Size = UDim2.new(1, 0, 0, hintHeight)
		hint.TextSize = if touch
			then math.max(HINT_TEXT_SIZE, TouchLayout.pointsToDesign(HINT_MIN_POINTS, points))
			else HINT_TEXT_SIZE
		box.TextSize = if touch
			then math.max(REPORT_TEXT_SIZE, TouchLayout.pointsToDesign(REPORT_MIN_POINTS, points))
			else REPORT_TEXT_SIZE
		box.Size = UDim2.new(1, 0, 0, tap)
		scroller.ScrollBarThickness = if touch then 18 else 10
		local top = hintHeight + GAP
		scroller.Position = UDim2.fromOffset(0, top)
		scroller.Size = UDim2.new(1, 0, 1, -(top + footerHeight + GAP))
	end
	applyLayout()
	local layoutConnection = ScreenManager.LayoutChanged:Connect(applyLayout)

	------------------------------------------------------------------ RAW state
	local mode: "report" | "raw" = "report"
	local raw: RawState? = nil
	local requestCounter = 0

	-- Whether the page on screen failed with a code a NEXT / RB press may retry (rate limit,
	-- timeout, server error) while the snapshot is still alive.
	local function retryable(state: RawState): boolean
		return state.texts[state.page] == nil
			and state.pendingId == nil
			and state.dead == nil
			and RawPaging.retryable(state.errorCode)
	end

	-- Shows / hides the page controls and paints PREV / NEXT for the current page (NEXT reads
	-- RETRY on a page that failed with a retryable code: that is what the press does there).
	local function renderPageControls()
		local state = raw
		local paging = mode == "raw" and state ~= nil
		prevButton.instance.Visible = paging
		nextButton.instance.Visible = paging
		pageHint.Visible = paging and InputController.mode == "Gamepad"
		if state ~= nil and paging then
			local retry = retryable(state)
			nextButton.setText(if retry then "RETRY" else "NEXT")
			prevButton.setState(if state.page <= 1 then "disabled" else "normal")
			nextButton.setState(if not retry and state.pages <= state.page then "disabled" else "normal")
		end
	end
	local modeConnection = InputController.ModeChanged:Connect(function()
		renderPageControls()
		applyLayout()
	end)

	-- Puts the current RAW page (or its loading / error state) into the box.
	local function renderRaw()
		local state = raw
		if state == nil then
			return
		end
		local pagesText = if state.pages > 0 then tostring(state.pages) else "?"
		window.setTitle("COPY RAW DATA")
		local text = state.texts[state.page]
		if text ~= nil then
			-- A dead snapshot (Expired ...) still shows the pages already fetched: say why the
			-- pages after them will not load.
			hint.Text = if state.dead ~= nil
				then `RAW DATA page {state.page} of {pagesText} is selected: press Ctrl+C (Cmd+C on Mac) to copy it. This snapshot can no longer be read: for pages not fetched yet, close, press REFRESH, then COPY RAW DATA.`
				else `RAW DATA page {state.page} of {pagesText} is selected: press Ctrl+C (Cmd+C on Mac), paste it, then take the next page (NEXT / RB). Copy every page from this snapshot; check its omission / read warnings. A controller can't copy - use a keyboard.`
			box.Text = text
			sizeLabel.Text = `RAW {state.page}/{pagesText} · {#text} characters`
			scroller.CanvasPosition = Vector2.zero
			autoSelect()
		elseif state.errorText ~= nil then
			hint.Text = `RAW DATA page {state.page}: {state.errorText}`
			box.Text = state.errorText :: string
			sizeLabel.Text = `RAW {state.page}/{pagesText}`
		else
			hint.Text = `Loading RAW DATA page {state.page} of {pagesText}...`
			box.Text = `Loading RAW DATA page {state.page}...`
			sizeLabel.Text = `RAW {state.page}/{pagesText} · loading`
		end
		renderPageControls()
	end

	-- Whether a page request may go out now: none in flight (or the last one timed out) and,
	-- unless `force` (a fresh open), at least MIN_PAGE_GAP s since the previous one.
	local function canRequest(state: RawState, force: boolean): boolean
		local elapsed = os.clock() - state.requestedAt
		if state.pendingId ~= nil and elapsed < PAGE_TIMEOUT then
			return false -- a page is on its way
		end
		return force or elapsed >= MIN_PAGE_GAP
	end

	-- Records a failed page request (`code`: a server code, "Timeout" or "Error"). A code that
	-- would only fail again (Expired, NotAuthorized, BadRequest) marks the whole snapshot dead:
	-- no more requests for it, the pages already fetched stay readable.
	local function fail(state: RawState, code: string)
		local known = if RAW_ERRORS[code] ~= nil then code else "Error"
		state.errorCode = known
		state.errorText = RAW_ERRORS[known]
		if not RawPaging.retryable(known) then
			state.dead = known
		end
	end

	-- Asks the server for `page` of the current snapshot. A request with no answer after
	-- PAGE_TIMEOUT s turns into a "press RETRY" message (one delayed check per request).
	local function requestPage(state: RawState, page: number)
		requestCounter += 1
		local id = requestCounter
		state.pendingId = id
		state.pendingPage = page
		state.requestedAt = os.clock()
		state.errorText = nil
		state.errorCode = nil
		Remotes.event("AnalyticsRawRequest"):FireServer(id, state.rawId, page)
		task.delay(PAGE_TIMEOUT, function()
			if raw == state and state.pendingId == id then
				state.pendingId = nil
				fail(state, "Timeout")
				if mode == "raw" and state.page == page then
					renderRaw()
				end
			end
		end)
	end

	--[[
		PREV (-1) / NEXT (+1), and LB / RB: RawPaging.decide picks the action (nothing while a
		page is in flight; a fetched page shows at once, also from a failed page, so PREV / LB
		always goes back; NEXT / RB RETRIES a page that failed with a retryable code instead of
		skipping it; a dead snapshot shows its failure without asking the server again). Requests
		stay spaced by MIN_PAGE_GAP (canRequest).
		@param delta  -1 or +1
	]]
	turnPage = function(delta: number)
		local state = raw
		if mode ~= "raw" or state == nil then
			return
		end
		local action, target = RawPaging.decide({
			page = state.page,
			pages = state.pages,
			delta = delta,
			pending = state.pendingId ~= nil,
			shown = state.texts[state.page] ~= nil,
			targetCached = state.texts[state.page + delta] ~= nil,
			errorCode = state.errorCode,
			dead = state.dead ~= nil,
		})
		if action == "none" then
			return
		elseif action == "show" then
			state.page = target
		elseif action == "deadPage" then
			local dead = state.dead :: string
			state.page = target
			state.errorCode = dead
			state.errorText = RAW_ERRORS[dead]
		else -- "retry" (target = the page on screen) / "request"
			if not canRequest(state, false) then
				return
			end
			state.page = target
			requestPage(state, target)
		end
		renderRaw()
	end

	-- One page from the server (stale / foreign replies are ignored by request id).
	local pageConnection = Remotes.event("AnalyticsRawPage").OnClientEvent
		:Connect(function(rawRequestId: unknown, rawPayload: unknown)
			local state = raw
			if state == nil or type(rawRequestId) ~= "number" or rawRequestId ~= state.pendingId then
				return -- stale or not ours
			end
			state.pendingId = nil
			if type(rawPayload) ~= "table" then
				fail(state, "Error")
			else
				local payload = rawPayload :: { [string]: unknown }
				local code = if type(payload.code) == "string" then payload.code :: string else "Error"
				local page = if code == "Ok" then AnalyticsReport.parseRawPage(payload.page) else nil
				if page ~= nil and page.rawId == state.rawId and page.page == state.pendingPage then
					state.pages = page.pages
					state.texts[page.page] = AnalyticsReport.rawText(page)
				else
					fail(state, if code == "Ok" then "Error" else code)
				end
			end
			if mode == "raw" and state.page == state.pendingPage then
				renderRaw()
			end
		end)

	-- COPY FOR AI: the whole report text (capped).
	local function setReport(text: string, title: string)
		mode = "report"
		local capped = string.sub(text, 1, AnalyticsConfig.ReportMaxChars)
		window.setTitle("COPY FOR AI")
		hint.Text = REPORT_HINT
		box.Text = capped
		sizeLabel.Text = `{title} · {#capped} characters`
		scroller.CanvasPosition = Vector2.zero
		renderPageControls()
		autoSelect()
	end

	-- COPY RAW DATA: page 1 (or the page last shown) of a snapshot; same snapshot = cached pages.
	local function startRaw(rawId: number, range: string, title: string)
		mode = "raw"
		local existing = raw
		local current: RawState
		if existing ~= nil and existing.rawId == rawId then
			current = existing
		else
			local fresh: RawState = {
				rawId = rawId,
				range = range,
				title = title,
				page = 1,
				pages = 0,
				texts = {},
				pendingPage = 1,
				requestedAt = -math.huge,
			}
			current = fresh
			raw = fresh
		end
		local dead = current.dead
		if current.texts[current.page] ~= nil then
			current.errorText = nil
			current.errorCode = nil
		elseif dead ~= nil then
			-- The snapshot already answered Expired / NotAuthorized: say so, no new request.
			current.errorCode = dead
			current.errorText = RAW_ERRORS[dead]
		elseif canRequest(current, true) then
			requestPage(current, current.page)
		end
		renderRaw()
	end

	pageTurner = turnPage

	probeState = function(): { [string]: any }
		local state = raw
		return {
			built = true,
			open = ScreenManager.isOpen(NAME),
			mode = mode,
			focused = box:IsFocused(),
			length = #box.Text,
			editable = box.TextEditable,
			page = if state ~= nil then state.page else 0,
			pages = if state ~= nil then state.pages else 0,
			loading = state ~= nil and state.pendingId ~= nil,
			error = if state ~= nil then state.errorText else nil,
			errorCode = if state ~= nil then state.errorCode else nil,
			dead = if state ~= nil then state.dead else nil,
			nextText = nextButton.label.Text,
		}
	end

	-- A rebuilt screen drops its listeners with the old window.
	window.frame.Destroying:Once(function()
		layoutConnection:Disconnect()
		modeConnection:Disconnect()
		pageConnection:Disconnect()
	end)

	-- Applies one open request's args (validated: they come from our own tab, but stay defensive).
	local function apply(args: any?)
		if type(args) ~= "table" then
			return
		end
		local title = if type(args.title) == "string" then string.sub(args.title, 1, 80) else "ANALYTICS"
		if args.mode == "raw" then
			local rawId = args.rawId
			if type(rawId) == "number" and rawId >= 1 and rawId == math.floor(rawId) then
				startRaw(rawId, if type(args.range) == "string" then args.range else "", title)
			end
		elseif type(args.text) == "string" then
			setReport(args.text, title)
		end
	end

	return {
		onOpen = function(args: any?)
			-- Admin-only: the report itself only ever reaches admins (server authorisation);
			-- refuse to show this screen to anyone else.
			if Players.LocalPlayer:GetAttribute("IsAdmin") ~= true then
				task.defer(ScreenManager.close, NAME)
				return
			end
			shell.popIn()
			applyLayout()
			apply(args)
			-- Sink LB / RB so the admin panel underneath keeps its tab (and the selection stays
			-- here); in RAW mode they turn the page.
			ContextActionService:BindActionAtPriority(
				SINK_ACTION,
				function(_name: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
					if mode == "raw" and state == Enum.UserInputState.Begin then
						turnPage(if input.KeyCode == Enum.KeyCode.ButtonL1 then -1 else 1)
					end
					return Enum.ContextActionResult.Sink
				end,
				false,
				Enum.ContextActionPriority.High.Value + 10,
				Enum.KeyCode.ButtonL1,
				Enum.KeyCode.ButtonR1
			)
		end,
		onClose = function()
			ContextActionService:UnbindAction(SINK_ACTION)
			box:ReleaseFocus()
		end,
		defaultSelection = function(): GuiObject?
			local state = raw
			if mode == "raw" and state ~= nil and state.pages > state.page then
				return nextButton.instance
			end
			return selectButton.instance
		end,
	}
end

-- The ScreenModule (UIController registers every `*Screen` module in this folder).
local AnalyticsExportScreen = {
	name = NAME,
	modal = true,
	closeOnBack = true,
	lazy = true,
	build = build,
}

--[[
	Studio test hook: turns the RAW page exactly as PREV (-1) / NEXT (+1) and LB / RB do (same
	guards: one page in flight, spaced requests). No-op before the dialog is built.
	Example: AnalyticsExportScreen.testTurn(1)
]]
function AnalyticsExportScreen.testTurn(delta: number)
	local turner = pageTurner
	if turner ~= nil then
		turner(if delta < 0 then -1 else 1)
	end
end

--[[
	Studio test probe: { built, open, mode ("report" | "raw"), focused, length, editable, page,
	pages, loading, error, errorCode, dead, nextText }.
	Example: print(AnalyticsExportScreen.probe().mode)
]]
function AnalyticsExportScreen.probe(): { [string]: any }
	return probeState()
end

return AnalyticsExportScreen
