--!strict
--[[
	TierStrip — the Nuke Pass track: a horizontal, gamepad-scrollable strip of tier columns, each
	a FREE card (top row), a tier chip on the progress line (middle) and a PREMIUM card (bottom
	row), plus a BONUS CHEST column after the last tier. Row labels FREE / PREMIUM stay pinned on
	the left. Built once by Screens/NukePass (lazy, first open); updated through setters only.

	Look (stud kit, docs/ui.md): every card is a StudUI.card (free = sky, premium = purple,
	milestones every 5 tiers = yellow / rainbow), every button a StudUI.button, the chips are stud
	pills on a dark well line whose stud fill runs up to the player's tier. Claimed cards get a
	dark veil + a check badge; premium cards the player cannot claim yet get a lock badge.

	Cell content per state (PassView.CellState): claimable → green CLAIM; claimed → CLAIMED;
	locked → "TIER N" (grey); unlock → purple UNLOCK (the premium prompt); premiumLocked →
	LOCKED! + lock badge; preview → "TIER N" (no season running: read-only).

	Input: cards are not selectable, their buttons are (StudUI buttons). `buttons()` returns the
	two rows in row-major order (31 columns each incl. the chest column; the chest's premium slot
	is a non-interactive placeholder, so the premium row has 30) for GamepadNav.linkGrid; the
	screen registers the scroller with GamepadNav.followScroll so the cursor stays in view.
	Touch scrolls the strip natively; KB/M uses the wheel / scrollbar; LB/RB page (screen).

	Juice: burst(track, tier) pops the card and flings 8 pooled stars from it (pool built once;
	no Instance.new per claim). Reduce Motion: a short colour flash only.

	Connects to: Kit/StudUI, Widgets/{ModelViewport (the Golden Nukey card), OfferFx (reduced
	motion)}, UI/Create, Screens/NukePass/{init (owner), PassView (CellState)},
	Shared/Config/UIStyleConfig.

	Example:
		local strip = TierStrip.new({ parent = body, count = 30, onClaim = claim, onUnlock = buy, onChest = chest })
		strip.layout(metrics)
		strip.setCell("free", 3, { icon = "Gems", caption = "15 Gems", state = "claimable", milestone = false })
		strip.scrollToTier(7, true)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Create = require(script.Parent.Parent.Parent.Create)
local ModelViewport = require(script.Parent.Parent.Parent.Widgets.ModelViewport)
local OfferFx = require(script.Parent.Parent.Parent.Widgets.OfferFx)
local PassView = require(script.Parent.PassView)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local Neutral = UIStyleConfig.Neutral

-- Layout of the strip inside its rect (design px), computed by the screen per window mode.
export type Metrics = {
	size: Vector2, -- the strip's rect
	labelW: number, -- pinned FREE / PREMIUM label column
	colW: number, -- one tier column
	gap: number, -- between columns / rows
	rowH: number, -- one card
	chipH: number, -- the middle chip row
	buttonH: number, -- card buttons (≥ 44 pt on touch)
	textSize: number, -- card captions (≥ 14 pt on touch)
	compact: boolean?, -- phone: one-line captions beside the icon, never shrunk under textSize
}

-- What one card shows.
export type CellView = {
	icon: string,
	caption: string,
	state: PassView.CellState,
	milestone: boolean,
	swatch: { Color3 }?, -- trail colours (the exclusive trail card)
	pet: string?, -- PetConfig id shown in 3D (the exclusive pet card)
	buttonText: string?, -- overrides the state's default text
	tier: number,
}

type Cell = {
	card: StudUI.Card,
	scale: UIScale,
	iconHolder: Frame,
	iconFrame: Frame?,
	iconKey: string?,
	iconSize: number,
	viewport: ModelViewport.Viewport?,
	swatch: Frame,
	caption: TextLabel,
	button: StudUI.Button,
	veil: Frame,
	badge: Frame?,
	badgeKey: string?,
	color: string?,
	view: CellView?,
}

export type Strip = {
	root: Frame,
	scroller: ScrollingFrame,
	layout: (metrics: Metrics) -> (),
	setCell: (track: "free" | "premium", tier: number, view: CellView) -> (),
	setChest: (view: CellView) -> (),
	setProgress: (tier: number, fraction: number) -> (),
	setPremiumOwned: (owned: boolean) -> (),
	scrollToTier: (tier: number, instant: boolean) -> (),
	page: (direction: number) -> (),
	burst: (track: "free" | "premium" | "chest", tier: number) -> (),
	buttons: () -> ({ GuiObject }, { GuiObject }),
	focusButton: (track: "free" | "premium" | "chest", tier: number) -> GuiObject?,
	Destroy: () -> (),
}

export type Options = {
	parent: Instance,
	count: number,
	onClaim: (track: "free" | "premium", tier: number) -> (),
	onUnlock: () -> (),
	onChest: () -> (),
}

local TierStrip = {}

-- Juice tunables.
local STAR_COUNT = 8
local STAR_SIZE = 34
local STAR_DISTANCE = 120
local BURST = TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local POP_IN = TweenInfo.new(0.09, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local POP_OUT = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SCROLL = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- Tiers one LB / RB press pages.
local PAGE_TIERS = 5
-- Card content padding (StudUI.card) and the button's 3D depth below its face (lip + edge).
local CARD_PAD = UIStyleConfig.Card.Padding
local BUTTON_DEPTH = UIStyleConfig.Button.Lip + UIStyleConfig.Button.Edge

--[[
	A card's content geometry for `m`: (icon size, caption top, caption height, side). Tall cards
	(desktop / console / tablet) stack icon → caption (two lines) → button. When the space above
	the button is too short to stack (phones: the button alone is 44 pt), the icon sits on the
	LEFT and the caption beside it (`side`), so both stay readable.
]]
local function cellGeometry(m: Metrics): (number, number, number, boolean)
	local inner = m.rowH - 2 * CARD_PAD
	local area = inner - m.buttonH - BUTTON_DEPTH - 4
	local twoLines = area >= m.textSize * 2.3 + 72
	local captionH = math.floor(m.textSize * (if twoLines then 2.3 else 1.25))
	if m.compact == true or area < captionH + 40 then
		local side = math.floor(math.min(area, (m.colW - 2 * CARD_PAD) * 0.42))
		return math.max(20, side), 0, math.max(0, math.floor(area)), true
	end
	local icon = math.min(m.colW - 2 * CARD_PAD, math.max(area - captionH, math.min(56, area)))
	return math.max(20, math.floor(icon)), math.max(0, area - captionH), captionH, false
end

-- The card colour of a cell (track + milestone + claimed).
local function colorOf(track: string, view: CellView): string
	if view.state == "claimed" then
		return "grey"
	end
	if track == "chest" then
		return "yellow"
	end
	if track == "premium" then
		return if view.milestone then "rainbow" else "purple"
	end
	return if view.milestone then "yellow" else "sky"
end

-- Default button text + state for a cell state.
local function buttonFor(view: CellView): (StudUI.ButtonState, string, string)
	local state = view.state
	if state == "claimable" then
		return "normal", view.buttonText or "CLAIM", "green"
	elseif state == "claimed" then
		return "claimed", "CLAIMED", "green"
	elseif state == "unlock" then
		return "normal", view.buttonText or "UNLOCK", "purple"
	elseif state == "premiumLocked" then
		return "locked", "LOCKED!", "grey"
	end
	return "locked", view.buttonText or `TIER {view.tier}`, "grey"
end

--[[
	Sets a StudUI button's state AND its text: StudUI shows the button's base text in the
	"normal" / "disabled" states (the state text only replaces it for locked / claimed), so a
	normal button that must read "UNLOCK" or "CLAIM ALL (3)" gets its base text set first.
	Example: TierStrip.setButton(claimAll, "normal", "CLAIM ALL (3)")
]]
function TierStrip.setButton(button: StudUI.Button, state: StudUI.ButtonState, text: string)
	if state == "normal" or state == "disabled" then
		button.setText(text)
		button.setState(state)
	else
		button.setState(state, text)
	end
end

--[[
	Builds the strip under `options.parent` (sizes come later from layout()).
	@return Strip handle
]]
function TierStrip.new(options: Options): Strip
	local count = math.max(1, options.count)
	local root = Create.new("Frame", {
		Name = "TierStrip",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = options.parent,
	}) :: Frame

	-- Pinned row labels (FREE / PREMIUM) on the left.
	local freeLabel = StudUI.card({ color = "sky", name = "FreeLabel", parent = root })
	local freeText = StudUI.text({
		text = "FREE",
		textSize = 30,
		size = UDim2.fromScale(1, 1),
		scaled = true,
		zIndex = 4,
		parent = freeLabel.content,
	})
	freeText.Active = false
	local premiumLabel = StudUI.card({ color = "purple", name = "PremiumLabel", parent = root })
	local premiumText = StudUI.text({
		text = "PREMIUM",
		textSize = 30,
		size = UDim2.fromScale(1, 0.5),
		scaled = true,
		zIndex = 4,
		parent = premiumLabel.content,
	})
	premiumText.Active = false
	local premiumLock = StudUI.icon("Lock", 44, 4)
	premiumLock.AnchorPoint = Vector2.new(0.5, 0)
	premiumLock.Position = UDim2.fromScale(0.5, 0.55)
	premiumLock.Parent = premiumLabel.content

	local scroller = Create.new("ScrollingFrame", {
		Name = "Track",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.X,
		ScrollBarThickness = 10,
		ScrollBarImageColor3 = Neutral.Edge,
		ElasticBehavior = Enum.ElasticBehavior.WhenScrollable,
		VerticalScrollBarInset = Enum.ScrollBarInset.None,
		HorizontalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
		ClipsDescendants = true,
		Selectable = false,
		Parent = root,
	}) :: ScrollingFrame

	-- The progress line behind the chips (dark well + stud fill up to the player's tier).
	local line = Create.new("Frame", {
		Name = "ProgressLine",
		BackgroundColor3 = Neutral.Well,
		BorderSizePixel = 0,
		ZIndex = 1,
		Parent = scroller,
		Children = { Create.new("UICorner", { CornerRadius = UDim.new(0, 6) }) },
	}) :: Frame
	local lineFill = StudUI.progressBar({ color = "green", size = UDim2.fromScale(1, 1), parent = line })
	lineFill.frame.BackgroundTransparency = 1

	local free: { Cell } = {}
	local premium: { Cell } = {}
	local chips: { { frame: Frame, label: TextLabel, card: StudUI.Card, color: string } } = {}
	local columns: { Frame } = {}
	local metrics: Metrics? = nil

	-- Builds one card cell inside `column`.
	local function makeCell(column: Frame, name: string, onActivated: () -> ()): Cell
		local card = StudUI.card({ color = "sky", name = name, parent = column })
		local scale = Create.new("UIScale", { Parent = card.frame }) :: UIScale
		local iconHolder = Create.new("Frame", {
			Name = "IconHolder",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, 0),
			ZIndex = 3,
			Active = false,
			Parent = card.content,
		}) :: Frame
		-- Trail colour swatch (the exclusive trail card), hidden otherwise.
		local swatch = Create.new("Frame", {
			Name = "Swatch",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.82),
			Size = UDim2.fromScale(0.9, 0.16),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
			Visible = false,
			ZIndex = 4,
			Parent = iconHolder,
			Children = {
				Create.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
				Create.new("UIStroke", { Thickness = 3, Color = Neutral.Edge }),
				Create.new("UIGradient", {}),
			},
		}) :: Frame
		local caption = StudUI.text({
			text = "",
			textSize = 22,
			wrap = true,
			scaled = true,
			alignY = Enum.TextYAlignment.Center,
			zIndex = 4,
			parent = card.content,
		})
		caption.Active = false
		local button = StudUI.button({
			text = "CLAIM",
			color = "green",
			textSize = 26,
			name = `{name}_Button`,
			parent = card.content,
			onActivated = onActivated,
		})
		button.instance.AnchorPoint = Vector2.new(0.5, 1)
		-- Leave room for the button's 3D lip under its face (it must stay inside the card).
		button.instance.Position = UDim2.new(0.5, 0, 1, -BUTTON_DEPTH)
		local veil = Create.new("Frame", {
			Name = "Veil",
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 3,
			Active = false,
			Parent = card.frame,
			Children = { Create.new("UICorner", { CornerRadius = UDim.new(0, 12) }) },
		}) :: Frame
		return {
			card = card,
			scale = scale,
			iconHolder = iconHolder,
			iconFrame = nil,
			iconKey = nil,
			iconSize = 0,
			viewport = nil,
			swatch = swatch,
			caption = caption,
			button = button,
			veil = veil,
			badge = nil,
			badgeKey = nil,
			color = nil,
			view = nil,
		}
	end

	for tier = 1, count + 1 do
		local isChest = tier > count
		local column = Create.new("Frame", {
			Name = if isChest then "ChestColumn" else `Tier{tier}`,
			BackgroundTransparency = 1,
			ZIndex = 2,
			Parent = scroller,
		}) :: Frame
		columns[tier] = column
		local chip = StudUI.card({ color = "grey", name = "Chip", parent = column })
		local chipLabel = StudUI.text({
			text = if isChest then "+" else tostring(tier),
			textSize = 26,
			size = UDim2.fromScale(1, 1),
			scaled = true,
			font = "number",
			zIndex = 4,
			parent = chip.content,
		})
		chipLabel.Active = false
		chips[tier] = { frame = chip.frame, label = chipLabel, card = chip, color = "grey" }
		if isChest then
			local cell = makeCell(column, "Chest", options.onChest)
			free[tier] = cell
		else
			free[tier] = makeCell(column, `Free{tier}`, function()
				local view = free[tier].view
				if view ~= nil and view.state == "claimable" then
					options.onClaim("free", tier)
				end
			end)
			premium[tier] = makeCell(column, `Premium{tier}`, function()
				local view = premium[tier].view
				if view == nil then
					return
				end
				if view.state == "claimable" then
					options.onClaim("premium", tier)
				elseif view.state == "unlock" then
					options.onUnlock()
				end
			end)
		end
	end

	-- Star pool for bursts (built once).
	local stars: { Frame } = {}
	for index = 1, STAR_COUNT do
		local star = StudUI.icon("Star", STAR_SIZE, 30)
		star.Name = `BurstStar{index}`
		star.AnchorPoint = Vector2.new(0.5, 0.5)
		star.Visible = false
		star.Parent = scroller
		table.insert(stars, star)
	end

	-- (Re)builds the card icon when its key / size changes (rare: setters skip unchanged ones).
	local function setIcon(cell: Cell, key: string, size: number, pet: string?)
		if pet ~= nil then
			if cell.viewport == nil then
				local frame = cell.iconFrame
				if frame ~= nil then
					frame:Destroy()
					cell.iconFrame = nil
				end
				cell.viewport = ModelViewport.new({
					pet = pet,
					icon = key,
					size = UDim2.fromOffset(size, size),
					anchor = Vector2.new(0.5, 0),
					position = UDim2.fromScale(0.5, 0),
					zIndex = 3,
					spin = true,
					parent = cell.iconHolder,
				})
			end
			local viewport = cell.viewport :: ModelViewport.Viewport
			viewport.frame.Size = UDim2.fromOffset(size, size)
			cell.iconKey, cell.iconSize = key, size
			return
		end
		if cell.iconKey == key and cell.iconSize == size and cell.iconFrame ~= nil then
			return
		end
		local old = cell.iconFrame
		if old ~= nil then
			old:Destroy()
		end
		local frame = StudUI.icon(key, size, 3)
		frame.AnchorPoint = Vector2.new(0.5, 0)
		frame.Position = UDim2.fromScale(0.5, 0)
		frame.Parent = cell.iconHolder
		cell.iconFrame, cell.iconKey, cell.iconSize = frame, key, size
	end

	-- Corner badge (Check / Lock) on a card; nil removes it.
	local function setBadge(cell: Cell, key: string?)
		if cell.badgeKey == key then
			return
		end
		local old = cell.badge
		if old ~= nil then
			old:Destroy()
			cell.badge = nil
		end
		cell.badgeKey = key
		if key ~= nil then
			local badge = StudUI.icon(key, 40, 6)
			badge.AnchorPoint = Vector2.new(1, 0)
			badge.Position = UDim2.new(1, 6, 0, -6)
			badge.Parent = cell.card.frame
			cell.badge = badge
		end
	end

	-- Lays out one cell's content for the current metrics.
	local function layoutCell(cell: Cell, m: Metrics)
		local iconSize, captionY, captionH, side = cellGeometry(m)
		local innerW = m.colW - 2 * CARD_PAD
		cell.card.frame.Size = UDim2.fromOffset(m.colW, m.rowH)
		if side then
			-- Icon on the left, caption beside it (phones).
			cell.iconHolder.AnchorPoint = Vector2.zero
			cell.iconHolder.Position = UDim2.fromOffset(0, math.max(0, (captionH - iconSize) / 2))
			cell.iconHolder.Size = UDim2.fromOffset(iconSize, iconSize)
			cell.caption.Size = UDim2.fromOffset(math.max(0, innerW - iconSize - 4), captionH)
			cell.caption.Position = UDim2.fromOffset(iconSize + 4, captionY)
		else
			cell.iconHolder.AnchorPoint = Vector2.new(0.5, 0)
			cell.iconHolder.Position = UDim2.fromScale(0.5, 0)
			cell.iconHolder.Size = UDim2.fromOffset(innerW, iconSize)
			cell.caption.Size = UDim2.new(1, 0, 0, captionH)
			cell.caption.Position = UDim2.fromOffset(0, captionY)
		end
		cell.caption.TextSize = m.textSize
		local constraint = cell.caption:FindFirstChildOfClass("UITextSizeConstraint")
		if constraint ~= nil then
			constraint.MaxTextSize = m.textSize
			-- Touch layouts never shrink under the 14 pt floor (textSize); the caption wraps instead.
			constraint.MinTextSize = if m.compact == true
				then m.textSize
				else math.min(m.textSize, math.max(10, math.floor(m.textSize * 0.7)))
		end
		cell.button.instance.Size = UDim2.new(1, 0, 0, m.buttonH)
		local view = cell.view
		if view ~= nil then
			setIcon(cell, view.icon, iconSize, view.pet)
		end
	end

	local function layout(m: Metrics)
		metrics = m
		local rowsTop = 0
		freeLabel.frame.Size = UDim2.fromOffset(m.labelW, m.rowH)
		freeLabel.frame.Position = UDim2.fromOffset(0, rowsTop)
		premiumLabel.frame.Size = UDim2.fromOffset(m.labelW, m.rowH)
		premiumLabel.frame.Position = UDim2.fromOffset(0, rowsTop + m.rowH + m.chipH + 2 * m.gap)
		premiumLock.Size = UDim2.fromOffset(math.min(48, m.labelW * 0.4), math.min(48, m.labelW * 0.4))
		local scrollX = m.labelW + m.gap
		scroller.Position = UDim2.fromOffset(scrollX, 0)
		scroller.Size = UDim2.fromOffset(m.size.X - scrollX, m.size.Y)
		local step = m.colW + m.gap
		local total = (count + 1) * step - m.gap
		scroller.CanvasSize = UDim2.fromOffset(total, 0)
		local chipY = m.rowH + m.gap
		for index, column in columns do
			column.Position = UDim2.fromOffset((index - 1) * step, 0)
			column.Size = UDim2.fromOffset(m.colW, 2 * m.rowH + m.chipH + 2 * m.gap)
			local chip = chips[index]
			local chipW = math.min(m.colW, m.chipH * 1.8)
			chip.frame.Size = UDim2.fromOffset(chipW, m.chipH)
			chip.frame.Position = UDim2.fromOffset((m.colW - chipW) / 2, chipY)
		end
		line.Position = UDim2.fromOffset(m.colW / 2, chipY + m.chipH / 2 - 8)
		line.Size = UDim2.fromOffset(math.max(0, total - m.colW), 16)
		for _, cell in free do
			cell.card.frame.Position = UDim2.fromOffset(0, 0)
			layoutCell(cell, m)
		end
		for _, cell in premium do
			cell.card.frame.Position = UDim2.fromOffset(0, m.rowH + m.chipH + 2 * m.gap)
			layoutCell(cell, m)
		end
	end

	-- Writes one cell (only changed properties).
	local function writeCell(cell: Cell, trackId: string, view: CellView)
		cell.view = view
		local color = colorOf(trackId, view)
		if color ~= cell.color then
			cell.color = color
			cell.card.setColor(color :: any)
		end
		cell.caption.Text = view.caption
		local state, text, buttonColor = buttonFor(view)
		cell.button.setColor(buttonColor :: any)
		TierStrip.setButton(cell.button, state, text)
		cell.veil.BackgroundTransparency = if view.state == "claimed" then 0.45 else 1
		setBadge(
			cell,
			if view.state == "claimed"
				then "Check"
				elseif view.state == "premiumLocked" or view.state == "unlock" then "Lock"
				else nil
		)
		local swatch = view.swatch
		cell.swatch.Visible = swatch ~= nil
		if swatch ~= nil then
			local gradient = cell.swatch:FindFirstChildOfClass("UIGradient")
			if gradient ~= nil then
				local keypoints: { ColorSequenceKeypoint } = {}
				for index, color3 in swatch do
					table.insert(keypoints, ColorSequenceKeypoint.new((index - 1) / math.max(1, #swatch - 1), color3))
				end
				if #keypoints >= 2 then
					gradient.Color = ColorSequence.new(keypoints)
				end
			end
		end
		local m = metrics
		if m ~= nil then
			local iconSize = cellGeometry(m)
			setIcon(cell, view.icon, iconSize, view.pet)
		end
	end

	-- Horizontal canvas X that centres column `tier` (clamped to the canvas).
	local function targetX(tier: number): number
		local m = metrics
		if m == nil then
			return 0
		end
		local step = m.colW + m.gap
		local window = m.size.X - m.labelW - m.gap
		local total = (count + 1) * step - m.gap
		local x = (math.clamp(tier, 1, count + 1) - 1) * step + m.colW / 2 - window / 2
		return math.clamp(x, 0, math.max(0, total - window))
	end

	-- Scroll in DESIGN px → absolute px (CanvasPosition is absolute, UIScale applied).
	local function toAbsolute(x: number): number
		local m = metrics
		if m == nil or m.size.X <= 0 then
			return x
		end
		local ratio = root.AbsoluteSize.X / m.size.X
		return x * (if ratio > 0 and ratio == ratio then ratio else 1)
	end

	local function scrollTo(x: number, instant: boolean)
		local target = Vector2.new(toAbsolute(x), 0)
		if instant or OfferFx.reducedMotion() then
			scroller.CanvasPosition = target
		else
			TweenService:Create(scroller, SCROLL, { CanvasPosition = target }):Play()
		end
	end

	local function pop(scale: UIScale)
		TweenService:Create(scale, POP_IN, { Scale = 1.1 }):Play()
		task.delay(POP_IN.Time, function()
			if scale.Parent ~= nil then
				TweenService:Create(scale, POP_OUT, { Scale = 1 }):Play()
			end
		end)
	end

	local strip: Strip
	strip =
		{
			root = root,
			scroller = scroller,
			layout = layout,
			setCell = function(trackId: "free" | "premium", tier: number, view: CellView)
				local cell = if trackId == "free" then free[tier] else premium[tier]
				if cell ~= nil and tier <= count then
					writeCell(cell, trackId, view)
				end
			end,
			setChest = function(view: CellView)
				writeCell(free[count + 1], "chest", view)
			end,
			setProgress = function(tier: number, fraction: number)
				-- Reached chips green, the next one yellow (the one being earned), the rest grey.
				for index, chip in chips do
					local color = if index <= tier then "green" elseif index == tier + 1 then "yellow" else "grey"
					if chip.color ~= color then
						chip.color = color
						chip.card.setColor(color :: any)
					end
				end
				-- Fill: through the reached chips + the fraction toward the next one.
				local m = metrics
				if m ~= nil then
					local segments = count -- chip 1 → chest chip
					local filled = math.clamp((tier - 1) + fraction, 0, segments)
					lineFill.setProgress(if tier <= 0 then 0 else filled / segments)
				end
			end,
			setPremiumOwned = function(owned: boolean)
				premiumLock.Visible = not owned
				premiumText.Size = if owned then UDim2.fromScale(1, 1) else UDim2.fromScale(1, 0.5)
			end,
			scrollToTier = function(tier: number, instant: boolean)
				scrollTo(targetX(tier), instant)
			end,
			page = function(direction: number)
				local m = metrics
				if m == nil then
					return
				end
				local step = m.colW + m.gap
				local ratio = if m.size.X > 0 then root.AbsoluteSize.X / m.size.X else 1
				local currentDesign = scroller.CanvasPosition.X / (if ratio > 0 then ratio else 1)
				local window = m.size.X - m.labelW - m.gap
				local centre = math.floor((currentDesign + window / 2) / step) + 1
				scrollTo(targetX(centre + direction * PAGE_TIERS), false)
			end,
			burst = function(trackId: "free" | "premium" | "chest", tier: number)
				local cell = if trackId == "premium"
					then premium[tier]
					elseif trackId == "chest" then free[count + 1]
					else free[tier]
				local m = metrics
				if cell == nil or m == nil then
					return
				end
				if OfferFx.reducedMotion() then
					cell.veil.BackgroundColor3 = Color3.new(1, 1, 1)
					cell.veil.BackgroundTransparency = 0.6
					task.delay(0.15, function()
						cell.veil.BackgroundColor3 = Color3.new(0, 0, 0)
						local view = cell.view
						cell.veil.BackgroundTransparency = if view ~= nil and view.state == "claimed" then 0.45 else 1
					end)
					return
				end
				pop(cell.scale)
				local column = if trackId == "chest" then count + 1 else tier
				local step = m.colW + m.gap
				local y = if trackId == "premium" then m.rowH * 1.5 + m.chipH + 2 * m.gap else m.rowH / 2
				local origin = UDim2.fromOffset((column - 1) * step + m.colW / 2, y)
				for index, star in stars do
					local angle = (index - 1) / STAR_COUNT * math.pi * 2 + math.random() * 0.4
					local distance = STAR_DISTANCE * (0.7 + math.random() * 0.4)
					star.Position = origin
					star.Rotation = 0
					star.Size = UDim2.fromOffset(STAR_SIZE, STAR_SIZE)
					star.Visible = true
					TweenService:Create(star, BURST, {
						Position = origin
							+ UDim2.fromOffset(math.cos(angle) * distance, math.sin(angle) * distance * 0.8),
						Rotation = 200,
						Size = UDim2.fromOffset(STAR_SIZE * 0.3, STAR_SIZE * 0.3),
					}):Play()
				end
				task.delay(BURST.Time, function()
					for _, star in stars do
						star.Visible = false
					end
				end)
			end,
			buttons = function(): ({ GuiObject }, { GuiObject })
				local top: { GuiObject } = {}
				local bottom: { GuiObject } = {}
				for tier = 1, count + 1 do
					table.insert(top, free[tier].button.instance)
				end
				for tier = 1, count do
					table.insert(bottom, premium[tier].button.instance)
				end
				return top, bottom
			end,
			focusButton = function(trackId: "free" | "premium" | "chest", tier: number): GuiObject?
				local cell = if trackId == "premium"
					then premium[tier]
					elseif trackId == "chest" then free[count + 1]
					else free[tier]
				return if cell ~= nil then cell.button.instance else nil
			end,
			Destroy = function()
				for _, cell in free do
					local viewport = cell.viewport
					if viewport ~= nil then
						viewport.Destroy()
					end
				end
				for _, cell in premium do
					local viewport = cell.viewport
					if viewport ~= nil then
						viewport.Destroy()
					end
				end
				root:Destroy()
			end,
		}
	return strip
end

return table.freeze(TierStrip)
