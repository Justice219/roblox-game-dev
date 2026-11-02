--!strict
--[[
	ActionCard — the small non-modal stud card shared by the owner R122 surfaces (spec §2.4):
	UI/Screens/DealCard (a paid Lucky Button walk-in / a HUD offer or golden-revenge chip tap) and
	UI/Screens/InviteMoment (the once-per-session "PLAY WITH FRIENDS!" card). Owner R120: popups are
	annoying — keep everything small and non-modal.

		┌──── stud card (preset colour) ──────────────────┐
		│ [art]  TITLE                                     │
		│        a short line (two lines max)              │
		│        [B] CLOSE / LATER      [X] ⏣ 199 / INVITE  │
		└──────────────────────────────────────────────────┘

	Input (owner R11): nothing on the card is Selectable — a card never steals the gamepad cursor.
	The two buttons are pressed by tap / click, or by the bound keys their glyphs show (the screens
	bind them through ContextActionService: primary X / E BELOW gameplay priority, secondary B /
	X / Backspace above). Glyphs follow the device (InputGlyph.dynamic; hidden on touch).

	Sizing: Widgets/FeedCardMetrics (text >= 14 pt, buttons >= 44 pt at the drawn fit). Buttons are
	rebuilt only when their height / text size changes (a device / layout change), never per frame.

	Connects to: Kit/StudUI, UI/Create, Widgets/{FeedCardMetrics, InputGlyph, OfferFx}, the screens
	above.

	Example:
		local view = ActionCard.new(root, { primaryWidth = 220, secondaryWidth = 150, glyphHeight = 30,
			primaryKey = Enum.KeyCode.E, primaryPad = Enum.KeyCode.ButtonX,
			secondaryKey = InputConfig.CloseKey, secondaryPad = InputConfig.BackButton })
		view.setContent({ color = "purple", icon = "x2Cash", title = "2x CASH", line = "Forever!",
			primaryText = "", primaryProductKey = "DoubleCash", secondaryText = "CLOSE" })
		view.apply(FeedCardMetrics.compute(spec, 1, { text = 0, tap = 0 }), 1)
]]

local TweenService = game:GetService("TweenService")

local Create = require(script.Parent.Parent.Create)
local FeedCardMetrics = require(script.Parent.FeedCardMetrics)
local InputGlyph = require(script.Parent.InputGlyph)
local OfferFx = require(script.Parent.OfferFx)
local StudUI = require(script.Parent.Parent.Kit.StudUI)

export type Options = {
	primaryWidth: number, -- design px at fit 1
	secondaryWidth: number,
	glyphHeight: number,
	primaryKey: Enum.KeyCode?,
	primaryPad: Enum.KeyCode?,
	secondaryKey: Enum.KeyCode?,
	secondaryPad: Enum.KeyCode?,
	onPrimary: () -> (),
	onSecondary: () -> (),
}

export type Content = {
	color: string, -- UIStyleConfig colour preset of the card
	icon: string, -- IconAssets key of the art (unknown keys draw a star)
	title: string,
	line: string,
	primaryText: string, -- "" + primaryProductKey = the live Robux price (BUY)
	primaryProductKey: string?,
	primaryColor: string?, -- default "green"
	secondaryText: string,
}

export type ActionCard = {
	holder: Frame, -- the caller positions / sizes it (design px) and scales it with `fitScale`
	fitScale: UIScale,
	setContent: (content: Content) -> (),
	apply: (metrics: FeedCardMetrics.Metrics) -> (),
	-- The primary (BUY / INVITE) button's instance (callers tag a BUY with PurchaseGuard.markBuy).
	primaryButton: () -> GuiObject?,
	pop: (from: number, seconds: number) -> (),
	-- The card's frame (for pointer hit tests: a press inside the card).
	frame: () -> Frame,
}

local ActionCard = {}

--[[
	Builds the (hidden) card under `parent`.
	@param parent the screen root
	@param options button widths, glyph keys and the two press callbacks
	@return ActionCard handle
]]
function ActionCard.new(parent: Instance, options: Options): ActionCard
	local holder = Create.new("Frame", {
		Name = "CardHolder",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(options.primaryWidth + options.secondaryWidth, 200),
		Active = false,
		Parent = parent,
	}) :: Frame
	local fitScale = Create.new("UIScale", { Name = "Fit", Scale = 1, Parent = holder }) :: UIScale
	local card = StudUI.card({
		name = "Card",
		color = "blue",
		sunburst = true,
		size = UDim2.fromScale(1, 1),
		parent = holder,
	})
	card.frame.Active = false
	local punch = Create.new("UIScale", { Name = "Punch", Scale = 1, Parent = card.frame }) :: UIScale
	local artHolder = Create.new("Frame", {
		Name = "Art",
		BackgroundTransparency = 1,
		Active = false,
		ZIndex = 4,
		Parent = card.frame,
	}) :: Frame
	local title = StudUI.text({
		name = "Title",
		text = "",
		textSize = 34,
		font = "shout",
		scaled = true,
		align = Enum.TextXAlignment.Left,
		zIndex = 5,
		parent = card.frame,
	})
	local line = StudUI.text({
		name = "Line",
		text = "",
		textSize = 24,
		wrap = true,
		align = Enum.TextXAlignment.Left,
		alignY = Enum.TextYAlignment.Top,
		zIndex = 5,
		parent = card.frame,
	})
	-- Glyphs left of each button (gamepad / keyboard; collapse on touch).
	local primaryGlyph = InputGlyph.dynamic(options.primaryKey, options.primaryPad, options.glyphHeight)
	primaryGlyph.AnchorPoint = Vector2.new(1, 0.5)
	primaryGlyph.ZIndex = 6
	primaryGlyph.Parent = card.frame
	local secondaryGlyph = InputGlyph.dynamic(options.secondaryKey, options.secondaryPad, options.glyphHeight)
	secondaryGlyph.AnchorPoint = Vector2.new(1, 0.5)
	secondaryGlyph.ZIndex = 6
	secondaryGlyph.Parent = card.frame

	local content: Content? = nil
	local metrics: FeedCardMetrics.Metrics? = nil
	local primary: StudUI.Button? = nil
	local secondary: StudUI.Button? = nil
	local builtKey = "" -- height / text size / texts the buttons were built for
	local art: Frame? = nil
	local artKey = ""

	-- (Re)builds both buttons for the current content + metrics (only when something changed).
	local function buildButtons()
		local c, m = content, metrics
		if c == nil or m == nil then
			return
		end
		local textSize = math.max(math.floor(m.buttonHeight * 0.5), m.lineSize)
		local key =
			`{m.buttonHeight}|{textSize}|{c.primaryText}|{c.primaryProductKey or ""}|{c.primaryColor or ""}|{c.secondaryText}`
		if key == builtKey and primary ~= nil and secondary ~= nil then
			return
		end
		builtKey = key
		if primary ~= nil then
			primary.Destroy()
		end
		if secondary ~= nil then
			secondary.Destroy()
		end
		local newPrimary = StudUI.button({
			name = "Primary",
			text = c.primaryText,
			productKey = c.primaryProductKey,
			color = (c.primaryColor or "green") :: any,
			textSize = textSize,
			size = UDim2.fromOffset(options.primaryWidth, m.buttonHeight),
			parent = card.frame,
			onActivated = options.onPrimary,
		})
		newPrimary.instance.Selectable = false
		newPrimary.instance.ZIndex = 6
		local newSecondary = StudUI.button({
			name = "Secondary",
			text = c.secondaryText,
			color = "grey",
			textSize = textSize,
			size = UDim2.fromOffset(options.secondaryWidth, m.buttonHeight),
			parent = card.frame,
			onActivated = options.onSecondary,
		})
		newSecondary.instance.Selectable = false
		newSecondary.instance.ZIndex = 6
		primary = newPrimary
		secondary = newSecondary
	end

	-- Positions every piece for the current metrics (card px): art left (centred in the upper
	-- block), title + line beside it, the button row along the bottom, right-aligned, each button
	-- with its glyph on its left.
	local function layout()
		local m = metrics
		if m == nil then
			return
		end
		holder.Size = UDim2.fromOffset(m.width, m.height)
		artHolder.Position = UDim2.fromOffset(m.pad, m.pad + math.floor((m.upper - m.artSize) / 2))
		artHolder.Size = UDim2.fromOffset(m.artSize, m.artSize)
		local textWidth = m.width - m.textX - m.pad
		local textTop = m.pad + math.max(0, math.floor((m.upper - m.titleHeight - m.gap - m.lineHeight) / 2))
		title.Size = UDim2.fromOffset(textWidth, m.titleHeight)
		title.TextSize = m.titleSize
		title.Position = UDim2.fromOffset(m.textX, textTop)
		line.Size = UDim2.fromOffset(textWidth, m.lineHeight)
		line.TextSize = m.lineSize
		line.Position = UDim2.fromOffset(m.textX, textTop + m.titleHeight + m.gap)
		buildButtons()
		local p, s = primary, secondary
		if p == nil or s == nil then
			return
		end
		local right = m.width - m.pad
		local middle = m.buttonY + m.buttonHeight / 2
		local glyphGap = 8
		-- Glyph widths in card px (AbsoluteSize is screen px: undo the UI + fit scales).
		local scale = math.max(holder.AbsoluteSize.X / math.max(m.width, 1), 0.01)
		local primaryGlyphWidth = primaryGlyph.AbsoluteSize.X / scale
		p.instance.AnchorPoint = Vector2.new(1, 0)
		p.instance.Position = UDim2.fromOffset(right, m.buttonY)
		primaryGlyph.Position = UDim2.fromOffset(right - options.primaryWidth - glyphGap, middle)
		local secondaryRight = right
			- options.primaryWidth
			- (if primaryGlyphWidth > 0 then glyphGap + primaryGlyphWidth else 0)
			- m.gap * 2
		s.instance.AnchorPoint = Vector2.new(1, 0)
		s.instance.Position = UDim2.fromOffset(secondaryRight, m.buttonY)
		secondaryGlyph.Position = UDim2.fromOffset(secondaryRight - options.secondaryWidth - glyphGap, middle)
	end
	-- The primary glyph's width changes with the device (keyboard cap vs pad image): re-place.
	primaryGlyph:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)

	return {
		holder = holder,
		fitScale = fitScale,
		setContent = function(next: Content)
			content = next
			card.setColor(next.color :: any)
			title.Text = next.title
			line.Text = next.line
			if next.icon ~= artKey then
				artKey = next.icon
				local old = art
				if old ~= nil then
					old:Destroy()
				end
				local icon = StudUI.icon(next.icon, 100, 4)
				icon.Size = UDim2.fromScale(1, 1)
				icon.Parent = artHolder
				art = icon
			end
			buildButtons()
			layout()
		end,
		apply = function(next: FeedCardMetrics.Metrics)
			metrics = next
			layout()
		end,
		primaryButton = function(): GuiObject?
			local button = primary
			return if button ~= nil then button.instance else nil
		end,
		pop = function(from: number, seconds: number)
			if OfferFx.reducedMotion() then
				punch.Scale = 1
				return
			end
			punch.Scale = from
			TweenService
				:Create(punch, TweenInfo.new(seconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
				:Play()
		end,
		frame = function(): Frame
			return card.frame
		end,
	}
end

return table.freeze(ActionCard)
