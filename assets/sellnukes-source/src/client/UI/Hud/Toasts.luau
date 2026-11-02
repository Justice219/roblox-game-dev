--!strict
--[[
	Toasts — the bottom-left FEED: every toast and the Big Pop pills in ONE compact stack (owner
	R111: "collecting goals blocks up the ui. should be a toast on the bottom left"; owner R108:
	"can they just take up the bottom left?"). A non-modal screen drawn above windows.

	Sources:
		- the server's `Notify` remote ({ kind, text, icon? }), validated defensively here (type
		  checks, length cap, kind / icon allow-lists) even though only the server sends it,
		- local calls: Toasts.push(kind, text, icon?) (Hud.notify forwards here),
		- Big Pop pills: Toasts.pushPill({ text, color, icon, seconds, group = "bigPop" })
		  (Tycoon/Fx/BigPopBanner; display names are plain text, never rich text),
		- Lucky Nuke pills (owner R120): Toasts.pushPill({ group = "flavor", mergeId, amount, build })
		  from Tycoon/FlavorController — same-flavour pills inside their merge window fold into one
		  ("GALAXY x3 +$95M": count + summed payout through `build`),
		- Toasts.suppress(text, seconds): a card already said it (the first-find reveal card carries
		  the server's discovery toast text), so that toast is removed / swallowed.

	The stack (rules in UI/Widgets/FeedLogic, numbers in PopupQueueConfig.Feed):
		- bottom-left column from UI/Widgets/PopupQueue.feedArea: under (or beside) the left button
		  grid, clear of the objective chip, the hint bar, a centre popup, the touch thumbstick / jump
		  reserve and ANY open window (it uses the window's left gutter or the strip under it; with
		  no room the pills wait) — toasts are above windows, so they never cover a window's content,
		- newest at the bottom; at most Feed.MaxVisible (4) — a 5th makes the oldest fade early; at
		  most Feed.BigPopMax (3) Big Pop pills (~5 s each),
		- same-kind toasts arriving within Feed.MergeSeconds merge into one pill ("Goal claimed! x3
		  +30 Gems"), which moves to the bottom and gets its full time again,
		- pills that do not fit right now (the reveal card under them, a narrow window gutter) are
		  hidden with their timers paused and come back (kid-friendly: never cut short by layout);
		  pills that never showed are dropped after Feed.MaxWait,
		- colours / icons by kind (success green, error red, info blue, reward yellow, purchase
		  purple); phones use the smaller pill with >= 14 pt text (PopupQueue.pillMetrics); long
		  text wraps (up to Feed.MaxLines lines).
	While the owner's Lucky Nuke reveal card plays it sits at the bottom of the same column
	(PopupQueue.feedCard) and the pills stack above it.

	Performance: event-driven (PopupQueue.Changed: zones / windows / the centre lane / the card);
	one delayed task per shown pill and one for the oldest waiting pill's expiry; text widths are
	measured once per (text, size). No per-frame work. Display only: nothing is Active or Selectable.

	Connects to: Client/ClientState (Notified), Kit/StudUI (icons, text, hasIcon),
	Widgets/{StudWindow (stud surface), PopupQueue (area, metrics, card), FeedLogic (sizes,
	visibility, merging), OfferFx (Reduce Motion)}, Shared/Config/{PopupQueueConfig, UIStyleConfig},
	UI/Hud/Hud (notify), Tycoon/Fx/BigPopBanner (pushPill), Controllers/UIController (registers it).

	Example:
		Toasts.push("success", "Code redeemed!")
		Toasts.pushPill({ text = "Alex got GALAXY nukes! (1 in 2,500)", color = "purple", icon = "Nuke",
			group = "bigPop" })
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")

local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.Create)
local FeedLogic = require(script.Parent.Parent.Widgets.FeedLogic)
local OfferFx = require(script.Parent.Parent.Widgets.OfferFx)
local PopupQueue = require(script.Parent.Parent.Widgets.PopupQueue)
local PopupQueueConfig = require(ReplicatedStorage.Shared.Config.PopupQueueConfig)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Widgets.StudWindow)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local Toasts = {}

export type PillSpec = {
	text: string,
	color: UIStyleConfig.ColorName,
	icon: string?,
	seconds: number?,
	group: string?, -- "bigPop" (Feed.BigPopMax applies) | "flavor" | nil (a toast)
	-- Custom merge (owner R120 Lucky Nuke pills): pills with the same mergeId inside mergeSeconds
	-- fold into one; `build(count, total)` writes its line from the count + summed `amount`.
	mergeId: string?,
	mergeSeconds: number?,
	amount: number?,
	build: ((count: number, total: number) -> string)?,
}

-- Longest toast text accepted (characters); longer text is cut with "...".
local MAX_TEXT = 140
local Feed = PopupQueueConfig.Feed
local KINDS: { [string]: StudUI.ToastKind } = {
	info = "info",
	success = "success",
	error = "error",
	reward = "reward",
	purchase = "purchase",
}
local KindColors = Feed.KindColors :: { [string]: UIStyleConfig.ColorName }
local KindIcons = Feed.KindIcons :: { [string]: string }
-- The label font (StudUI.text "title" role) for the width measurement.
local MEASURE_FONT = Enum.Font.FredokaOne
local MOVE_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- One pill: waiting (no node yet), shown (timer running) or hidden (timer paused).
type Item = {
	group: string, -- "toast" | "bigPop"
	key: string, -- merge key
	merge: FeedLogic.MergeState,
	color: UIStyleConfig.ColorName,
	icon: string,
	seconds: number,
	queuedAt: number,
	updatedAt: number,
	order: number, -- LayoutOrder (newest = highest = bottom)
	remaining: number,
	endsAt: number?,
	token: number,
	node: CanvasGroup?,
	label: TextLabel?,
	iconFrame: Frame?,
	width: number,
	height: number,
	lines: number,
	fitKey: string, -- the size signature the node was last fitted to
	-- Custom merge (PillSpec.mergeId): count + summed amount → build(count, total).
	mergeId: string?,
	mergeSeconds: number,
	count: number,
	total: number,
	build: ((count: number, total: number) -> string)?,
}

local stack: Frame? = nil
local items: { Item } = {}
local order = 0
local expiryToken = 0
local stackPosition: Vector2? = nil
local stackTween: Tween? = nil
local widthCache: { [string]: number } = {}
local widthCacheSize = 0
-- Toast texts to drop for a while (Toasts.suppress: a card already said it), text → until.
local suppressed: { [string]: number } = {}

local relayout: () -> ()

-- The single-line width of `text` at `size` (cached; TextService is synchronous).
local function measure(text: string, size: number): number
	local key = `{size}|{text}`
	local cached = widthCache[key]
	if cached ~= nil then
		return cached
	end
	if widthCacheSize > 96 then
		table.clear(widthCache)
		widthCacheSize = 0
	end
	local width = TextService:GetTextSize(text, size, MEASURE_FONT, Vector2.new(4096, 4096)).X + 6
	widthCache[key] = width
	widthCacheSize += 1
	return width
end

-- Removes a pill (fades it out unless `instant`); idempotent.
local function dismiss(item: Item, instant: boolean)
	local index = table.find(items, item)
	if index == nil then
		return
	end
	table.remove(items, index)
	item.token += 1
	local node = item.node
	if node == nil then
		return
	end
	if instant or not node.Visible then
		node:Destroy()
		return
	end
	-- Fade AND collapse, so the stack never grows past its room while the pill leaves.
	local tween = TweenService:Create(
		node,
		TweenInfo.new(Feed.FadeOut),
		{ GroupTransparency = 1, Size = UDim2.fromOffset(node.Size.X.Offset, 0) }
	)
	tween.Completed:Once(function()
		node:Destroy()
	end)
	tween:Play()
end

-- Starts (or resumes) a shown pill's timer.
local function run(item: Item)
	if item.endsAt ~= nil then
		return
	end
	item.endsAt = os.clock() + item.remaining
	item.token += 1
	local mine = item.token
	task.delay(item.remaining, function()
		if item.token == mine then
			dismiss(item, false)
			relayout()
		end
	end)
end

-- Pauses a pill's timer (it keeps the time it has left, at least Feed.ResumeFloor).
local function pause(item: Item)
	local endsAt = item.endsAt
	if endsAt == nil then
		return
	end
	item.remaining = math.max(Feed.ResumeFloor, endsAt - os.clock())
	item.endsAt = nil
	item.token += 1
end

-- Builds a pill's node (stud surface + icon + label) into the stack; fades in.
local function build(item: Item, parent: Frame): CanvasGroup
	local node = Create.new("CanvasGroup", {
		Name = "FeedItem",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(item.width, item.height),
		LayoutOrder = item.order,
		GroupTransparency = 1,
	}) :: CanvasGroup
	local pill = Create.new("Frame", {
		Name = "Pill",
		Size = UDim2.fromScale(1, 1),
		Active = false,
		Parent = node,
	}) :: Frame
	StudWindow.surface(pill, item.color, {
		tile = UIStyleConfig.StudTile.Button,
		studTransparency = UIStyleConfig.StudTransparency.Button,
		edge = 3,
		corner = 10,
	})
	local label = StudUI.text({
		name = "Message",
		text = item.merge.text,
		textSize = Feed.TextSize,
		align = Enum.TextXAlignment.Left,
		wrap = true,
		zIndex = 4,
		parent = pill,
	})
	item.node = node
	item.label = label
	item.fitKey = ""
	node.Parent = parent
	if OfferFx.reducedMotion() then
		node.GroupTransparency = 0
	else
		TweenService:Create(node, TweenInfo.new(Feed.FadeIn), { GroupTransparency = 0 }):Play()
	end
	return node
end

-- Sizes a pill (and its node, when built) for the column width + metrics (only on change).
local function fit(item: Item, columnWidth: number, metrics: FeedLogic.PillMetrics)
	local textWidth = measure(item.merge.text, metrics.textSize)
	local width, height, lines = FeedLogic.pillSize(textWidth, columnWidth, metrics)
	item.width, item.height, item.lines = width, height, lines
	local node, label = item.node, item.label
	if node == nil or label == nil then
		return
	end
	local key = `{width}|{height}|{metrics.textSize}|{metrics.iconSize}|{item.merge.text}`
	if key == item.fitKey then
		return
	end
	item.fitKey = key
	node.Size = UDim2.fromOffset(width, height)
	-- The icon is rebuilt only when its size changed (StudUI icons are sized at creation).
	local icon = item.iconFrame
	if icon == nil or icon.Size.X.Offset ~= metrics.iconSize then
		if icon ~= nil then
			icon:Destroy()
		end
		local iconKey = if StudUI.hasIcon(item.icon) then item.icon else "Star"
		icon = StudUI.icon(iconKey, metrics.iconSize, 4)
		icon.AnchorPoint = Vector2.new(0, 0.5)
		icon.Position = UDim2.new(0, metrics.padX, 0.5, 0)
		icon.Parent = node:FindFirstChild("Pill")
		item.iconFrame = icon
	end
	local left = metrics.padX * 2 + metrics.iconSize
	label.Text = item.merge.text
	label.TextSize = metrics.textSize
	label.Position = UDim2.fromOffset(left, 0)
	label.Size = UDim2.new(1, -(left + metrics.padX), 1, 0)
	-- Past MaxLines the text scales down inside the pill instead of overflowing it.
	local overflow = textWidth > (columnWidth - metrics.padX * 3 - metrics.iconSize) * metrics.maxLines
	label.TextScaled = overflow
	local constraint = label:FindFirstChildOfClass("UITextSizeConstraint")
	if overflow and constraint == nil then
		Create.new("UITextSizeConstraint", {
			MaxTextSize = metrics.textSize,
			MinTextSize = math.floor(metrics.textSize * 0.75),
			Parent = label,
		})
	elseif constraint ~= nil then
		constraint.MaxTextSize = metrics.textSize
		constraint.MinTextSize = math.floor(metrics.textSize * 0.75)
	end
end

-- Moves the stack to (x, bottom): glides, except the first placement / Reduce Motion.
local function moveStack(parent: Frame, x: number, bottom: number)
	local target = Vector2.new(x, bottom)
	if stackPosition == target then
		return
	end
	local first = stackPosition == nil
	stackPosition = target
	local position = UDim2.fromOffset(x, bottom)
	local running = stackTween
	if running ~= nil then
		running:Cancel()
		stackTween = nil
	end
	if first or OfferFx.reducedMotion() then
		parent.Position = position
		return
	end
	local tween = TweenService:Create(parent, MOVE_INFO, { Position = position })
	stackTween = tween
	tween:Play()
end

-- Re-arms the expiry check of the oldest waiting (never shown) pill.
local function armExpiry()
	expiryToken += 1
	local oldest: number? = nil
	for _, item in items do
		if item.node == nil and (oldest == nil or item.queuedAt < (oldest :: number)) then
			oldest = item.queuedAt
		end
	end
	if oldest == nil then
		return
	end
	local mine = expiryToken
	task.delay(math.max(0, oldest + Feed.MaxWait - os.clock()) + 0.05, function()
		if mine == expiryToken then
			relayout()
		end
	end)
end

-- Applies the feed rules: column, sizes, which pills show (newest first), timers.
relayout = function()
	local parent = stack
	if parent == nil then
		return
	end
	local metrics = PopupQueue.pillMetrics()
	local card = PopupQueue.feedCard()
	local need = if card ~= nil then card.h else Feed.MinRows * metrics.height + (Feed.MinRows - 1) * Feed.RowGap
	local area = PopupQueue.feedArea(need)
	local bottom = area.bottom
	if card ~= nil then
		bottom = math.min(bottom, card.y - Feed.RowGap)
	end
	local room = math.max(0, bottom - area.top)
	-- Drop pills that never got to show within MaxWait.
	local now = os.clock()
	for index = #items, 1, -1 do
		local item = items[index]
		if item.node == nil and now - item.queuedAt > Feed.MaxWait then
			table.remove(items, index)
		end
	end
	local heights: { number } = {}
	for index, item in items do
		fit(item, area.width, metrics)
		heights[index] = item.height
	end
	local shown = FeedLogic.visible(heights, room, Feed.MaxVisible)
	for index, item in items do
		if shown[index] then
			local node = item.node or build(item, parent)
			fit(item, area.width, metrics)
			node.Visible = true
			run(item)
		else
			pause(item)
			local node = item.node
			if node ~= nil then
				node.Visible = false
			end
		end
	end
	parent.Size = UDim2.fromOffset(math.max(area.width, 1), room)
	moveStack(parent, area.x, bottom)
	armExpiry()
end

-- What add() needs to know about one pill.
type AddSpec = {
	group: string,
	text: string,
	color: UIStyleConfig.ColorName,
	icon: string,
	seconds: number,
	mergeKind: string,
	mergeId: string?,
	mergeSeconds: number?,
	amount: number?,
	build: ((count: number, total: number) -> string)?,
}

-- Moves a merged pill to the bottom (the newest) with its full time again + a soft flash.
local function refresh(item: Item, index: number, seconds: number, now: number)
	item.updatedAt = now
	item.remaining = seconds
	item.endsAt = nil
	item.token += 1
	order += 1
	item.order = order
	local node = item.node
	if node ~= nil then
		node.LayoutOrder = order
		if not OfferFx.reducedMotion() then
			node.GroupTransparency = 0.4
			TweenService:Create(node, TweenInfo.new(Feed.FadeIn), { GroupTransparency = 0 }):Play()
		end
	end
	table.remove(items, index)
	table.insert(items, item)
end

-- Adds (or merges) one pill; enforces MaxVisible / BigPopMax (the oldest fades early).
local function add(spec: AddSpec)
	local now = os.clock()
	local key = FeedLogic.mergeKey(spec.mergeKind, spec.text)
	local mergeId = spec.mergeId
	local amount = spec.amount or 0
	for index, item in items do
		if mergeId ~= nil and item.mergeId == mergeId and now - item.updatedAt <= item.mergeSeconds then
			-- Custom merge (Lucky Nuke pills): count + summed payout → its own line.
			item.count += 1
			item.total += amount
			local writer = item.build
			local line = if writer ~= nil then writer(item.count, item.total) else spec.text
			item.merge = { text = line, latest = line, count = item.count, sums = {}, units = {}, summable = false }
			refresh(item, index, spec.seconds, now)
			relayout()
			return
		elseif
			mergeId == nil
			and item.mergeId == nil
			and item.key == key
			and now - item.updatedAt <= Feed.MergeSeconds
		then
			-- Same-kind toast: new text / count ("Goal claimed! x3 +30 Gems").
			item.merge = FeedLogic.merge(item.merge, spec.text)
			refresh(item, index, spec.seconds, now)
			relayout()
			return
		end
	end
	if spec.group == "bigPop" then
		local count = 0
		for _, item in items do
			if item.group == "bigPop" then
				count += 1
			end
		end
		if count >= Feed.BigPopMax then
			for _, item in items do
				if item.group == "bigPop" then
					dismiss(item, false)
					break
				end
			end
		end
	end
	while #items >= Feed.MaxVisible do
		dismiss(items[1], false)
	end
	order += 1
	local item: Item = {
		group = spec.group,
		key = key,
		merge = FeedLogic.merge(nil, spec.text),
		color = spec.color,
		icon = spec.icon,
		seconds = spec.seconds,
		queuedAt = now,
		updatedAt = now,
		order = order,
		remaining = spec.seconds,
		endsAt = nil,
		token = 0,
		node = nil,
		label = nil,
		iconFrame = nil,
		width = 0,
		height = 0,
		lines = 1,
		fitKey = "",
		mergeId = mergeId,
		mergeSeconds = spec.mergeSeconds or Feed.MergeSeconds,
		count = 1,
		total = amount,
		build = spec.build,
	}
	table.insert(items, item)
	relayout()
end

-- Validates + trims a message (nil = refuse: empty / invalid UTF-8).
local function clean(text: unknown): string?
	if type(text) ~= "string" or text == "" then
		return nil
	end
	local message = text :: string
	local length = utf8.len(message)
	if length == nil then
		return nil -- invalid UTF-8 never reaches a label
	end
	if length > MAX_TEXT then
		local cut = utf8.offset(message, MAX_TEXT - 2) or (#message + 1)
		message = string.sub(message, 1, cut - 1) .. "..."
	end
	return message
end

--[[
	Shows one toast in the feed (see the module header; it may merge or wait for room).
	@param kind "info" | "success" | "error" | "reward" | "purchase" (unknown -> "info")
	@param text message (trimmed to MAX_TEXT characters)
	@param icon optional IconAssets key (unknown keys fall back to the kind's icon)
	Example: Toasts.push("reward", "+250 Gems", "Gem")
]]
function Toasts.push(kind: string, text: string, icon: string?)
	local message = clean(text)
	if stack == nil or message == nil then
		return
	end
	local untilTime = suppressed[message]
	if untilTime ~= nil then
		suppressed[message] = nil
		if os.clock() <= untilTime then
			return -- a card already said exactly this (Toasts.suppress)
		end
	end
	local safeKind: StudUI.ToastKind = KINDS[kind] or "info"
	local safeIcon = if icon ~= nil and StudUI.hasIcon(icon) then icon else KindIcons[safeKind]
	add({
		group = "toast",
		text = message,
		color = KindColors[safeKind] or "blue",
		icon = safeIcon,
		seconds = UIStyleConfig.Hud.ToastSeconds,
		mergeKind = safeKind,
	})
end

--[[
	Drops a toast that would repeat what a card already says (owner R120: the first-find reveal
	card carries the Flavour Book claim line, so the server's identical discovery toast is a
	duplicate): removes it when it is already in the feed, else swallows it if it arrives within
	`seconds`.
	@param text string — the exact toast text
	@param seconds number
	Example: Toasts.suppress("New Lucky Nuke: GALAXY in Nuke Town! Claim 60 Gems in Pets → FLAVOURS.", 8)
]]
function Toasts.suppress(text: string, seconds: number)
	local message = clean(text)
	if message == nil or seconds ~= seconds or seconds <= 0 then
		return
	end
	for _, item in items do
		if item.group == "toast" and item.merge.count == 1 and item.merge.latest == message then
			dismiss(item, false)
			relayout()
			return
		end
	end
	-- Expired entries are pruned here (bounded: one per suppressed text).
	local now = os.clock()
	for key, untilTime in suppressed do
		if untilTime < now then
			suppressed[key] = nil
		end
	end
	suppressed[message] = now + math.min(seconds, 60)
end

--[[
	Shows a coloured pill in the feed (Big Pop, owner R108; Lucky Nukes, owner R120).
	@param spec PillSpec — text (plain), stud colour, icon key, seconds (default BigPopSeconds),
	       group "bigPop" (at most Feed.BigPopMax of them) | "flavor"; mergeId / mergeSeconds /
	       amount / build for pills that fold into one ("GALAXY x3 +$95M")
	Example: Toasts.pushPill({ text = "Alex got GALAXY nukes! (1 in 2,500)", color = "purple", icon = "Nuke", group = "bigPop" })
]]
function Toasts.pushPill(spec: PillSpec)
	local message = clean(spec.text)
	if stack == nil or message == nil then
		return
	end
	local color: UIStyleConfig.ColorName = if UIStyleConfig.Colors[spec.color] ~= nil then spec.color else "blue"
	local icon = if spec.icon ~= nil and StudUI.hasIcon(spec.icon) then spec.icon else "Star"
	local seconds = spec.seconds
	local hold = if seconds ~= nil
			and seconds == seconds
			and seconds > 0
		then math.min(seconds, 60)
		else Feed.BigPopSeconds
	local group = if spec.group == "bigPop" or spec.group == "flavor" then spec.group :: string else "toast"
	local amount = spec.amount
	add({
		group = group,
		text = message,
		color = color,
		icon = icon,
		seconds = hold,
		mergeKind = group,
		mergeId = if type(spec.mergeId) == "string" then spec.mergeId else nil,
		mergeSeconds = spec.mergeSeconds,
		amount = if amount ~= nil and amount == amount and amount >= 0 and amount < math.huge then amount else 0,
		build = spec.build,
	})
end

--[[ QA probe: shown / paused / waiting pill counts, Big Pop pills, the column (design px). ]]
function Toasts.stats(): { [string]: any }
	local shown, paused, waiting, bigPops = 0, 0, 0, 0
	local texts: { string } = {}
	for _, item in items do
		if item.node == nil then
			waiting += 1
		elseif item.endsAt ~= nil then
			shown += 1
		else
			paused += 1
		end
		if item.group == "bigPop" then
			bigPops += 1
		end
		table.insert(texts, item.merge.text)
	end
	local position = stackPosition
	return {
		shown = shown,
		paused = paused,
		waiting = waiting,
		bigPops = bigPops,
		texts = texts,
		x = if position ~= nil then position.X else -1,
		bottom = if position ~= nil then position.Y else -1,
	}
end

--[[ The Toasts ScreenModule (registered by UIController; auto-opens, never modal). ]]
Toasts.screen = {
	name = "Toasts",
	modal = false,
	autoOpen = true,
	displayOrder = 45,
	build = function(gui: ScreenGui): ScreenManager.ScreenHandle
		local root = Create.new("Frame", {
			Name = "Stack",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, Feed.Margin, 1, -Feed.Margin),
			Size = UDim2.fromOffset(Feed.MaxWidth, 0),
			BackgroundTransparency = 1,
			Active = false,
			Parent = gui,
			Children = {
				Create.new("UIListLayout", {
					FillDirection = Enum.FillDirection.Vertical,
					HorizontalAlignment = Enum.HorizontalAlignment.Left,
					VerticalAlignment = Enum.VerticalAlignment.Bottom,
					Padding = UDim.new(0, Feed.RowGap),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
			},
		}) :: Frame
		stack = root
		-- Zones / windows / the centre lane / the reveal card moved: re-apply the feed rules.
		PopupQueue.Changed:Connect(function(_what: string)
			relayout()
		end)
		relayout()
		ClientState.Notified:Connect(function(payload: ClientState.NotifyPayload)
			Toasts.push(payload.kind, payload.text, payload.icon)
		end)
		return {}
	end,
} :: ScreenManager.ScreenModule

return Toasts
