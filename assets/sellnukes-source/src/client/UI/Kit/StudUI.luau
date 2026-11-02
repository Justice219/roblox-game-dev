--!strict
--[[
	StudUI — the SellNukes stud-texture style kit. EVERY screen builds its UI from these pieces so
	the whole game matches the owner's reference shots (docs/reference/ui-style/*.png) and uses
	the RoBeasts stud material everywhere (owner rule 2).

	The look (sampled from the references; numbers in Shared/Config/UIStyleConfig):
		- coloured surfaces = vertical gradient (lighter top) + the RoBeasts stud tile + a thick
		  near-black outline; buttons add a darker 3D lip under the face,
		- windows = coloured stud header bar (icon + big outlined title + red square X) over a
		  dark slate body,
		- all text white with a fat dark outline (Fredoka One; numbers in Luckiest Guy).

	API (all sizes in design px at 1080p; every builder accepts `parent`, `layoutOrder`, and
	returns a handle whose `.frame` / `.instance` is the root Instance):
		StudUI.text(options)            outlined label
		StudUI.icon(key, size)          uploaded 3D icon (IconAssets.get), or the Glyphs fallback
		                                only while its image is "" (StudUI.IconKeys lists the keys)
		StudUI.window(options)          header bar + icon + title + red X + slate body
		StudUI.modalScreen(spec)        a complete ScreenModule around a window (ModalShell fit,
		                                pop-in, close X / Back / gamepad B, default selection)
		StudUI.card(options)            coloured stud card (optional sunburst + title)
		StudUI.button(options)          stud button (colour presets, Robux price, press / hover
		                                feel, states normal | locked | claimed | disabled)
		StudUI.closeButton(options)     the red square X
		StudUI.starburst(options)       right-column Robux offer (dark spiky burst + icon + label
		                                + green Robux tag)
		StudUI.hudButton(options)       left-column stud tile (icon + label, wide variant, badge)
		StudUI.moneyLabel(options)      cash / gems / rate counter with icon and roll-up
		StudUI.countdown(options)       live server-time countdown (one shared 1 Hz ticker)
		StudUI.toast(options)           one notification chip (the Toasts screen stacks them)
		StudUI.sectionLabel(text)       "- LIMITED TIME -" style section heading
		StudUI.textBox(options)         dark well text box ("Code Here")
		StudUI.robuxTag(price, size, productKey?)
		                                green Robux glyph + price (productKey: the LIVE price)
		StudUI.progressBar(options)     stud progress bar

	Security: purely presentational. Buttons only call the caller's callback; Robux prices shown
	come from UI/PriceBook (the live managed price, `productKey` options) or a caller's fixed
	number, and every purchase / claim is validated server-side (Roblox's own prompt charges).

	Performance: built once per screen; hover / press tweens only on input; animations run on
	the shared OfferFx driver (parked when hidden / Reduce Motion / Low graphics); countdowns
	share ONE 1 Hz thread that only touches labels on screen.

	Connects to: Widgets/{StudWindow, PanelBackdrop, OfferFx, ModalShell}, Kit/Glyphs,
	UI/ScreenManager, UI/Create, UI/PriceBook (live Robux prices), Shared/Config/{UIStyleConfig, IconAssets},
	Shared/Util/{NumberFormat, ForgetOnDestroy}. Used by every screen and the HUD.

	Example:
		return StudUI.modalScreen({
			name = "Codes", title = "Codes", color = "blue", icon = "Codes",
			size = Vector2.new(900, 520), lazy = true,
			build = function(window, gui)
				local box = StudUI.textBox({ placeholder = "Code Here", parent = window.body })
				local redeem = StudUI.button({ text = "Redeem", color = "green", parent = window.body,
					onActivated = function() Remotes.RedeemCode:FireServer(box.instance.Text) end })
				return { defaultSelection = function() return redeem.instance end }
			end,
		})
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Create = require(script.Parent.Parent.Create)
local ForgetOnDestroy = require(ReplicatedStorage.Shared.Util.ForgetOnDestroy)
local Glyphs = require(script.Parent.Glyphs)
local IconAssets = require(ReplicatedStorage.Shared.Config.IconAssets)
local ModalShell = require(script.Parent.Parent.Widgets.ModalShell)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local PanelBackdrop = require(script.Parent.Parent.Widgets.PanelBackdrop)
local PriceBook = require(script.Parent.Parent.PriceBook)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudWindow = require(script.Parent.Parent.Widgets.StudWindow)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

export type ColorName = UIStyleConfig.ColorName
export type ButtonState = "normal" | "locked" | "claimed" | "disabled"
export type FontRole = "title" | "body" | "number" | "shout"

local StudUI = {}

-- CollectionService tag on every StudUI button (a sound controller can hook every button).
StudUI.ButtonTag = "SellNukesButton"

local Neutral = UIStyleConfig.Neutral
local Style = UIStyleConfig
-- Seconds during which a second activation of the same button is ignored (double-tap guard:
-- one tap never sends two purchase prompts / claim intents).
local ACTIVATE_DEBOUNCE = 0.25

local FONTS: { [FontRole]: Font } = {
	title = Style.Fonts.Title,
	body = Style.Fonts.Body,
	number = Style.Fonts.Number,
	shout = Style.Fonts.Shout,
}

-- Outline thickness for text of `size` px (fat, like the references; never below 2).
local function strokeFor(size: number): number
	return math.max(2, math.floor(size * Style.Button.TextStrokeRatio + 0.5))
end

-- Adds / updates the Contextual text outline of a label.
local function outline(label: TextLabel | TextButton | TextBox, size: number)
	StudWindow.outline(label, strokeFor(size))
end

-- Hover / selection grow and press squash on a dedicated UIScale (one writer).
local function pressFeel(root: GuiButton, ring: UIStroke?)
	local scale = Create.new("UIScale", { Name = "PressScale", Scale = 1, Parent = root }) :: UIScale
	local hovered, selected, pressed = false, false, false
	local hoverInfo = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	local pressInfo = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local function refresh()
		local target = if pressed
			then Style.Button.PressScale
			elseif hovered or selected then Style.Button.HoverScale
			else 1
		TweenService:Create(scale, if pressed then pressInfo else hoverInfo, { Scale = target }):Play()
		if ring ~= nil then
			ring.Enabled = selected
		end
	end
	root.MouseEnter:Connect(function()
		hovered = true
		refresh()
	end)
	root.MouseLeave:Connect(function()
		hovered, pressed = false, false
		refresh()
	end)
	root.SelectionGained:Connect(function()
		selected = true
		refresh()
	end)
	root.SelectionLost:Connect(function()
		selected = false
		refresh()
	end)
	root.InputBegan:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
			or input.KeyCode == Enum.KeyCode.ButtonA
		then
			pressed = true
			refresh()
		end
	end)
	root.InputEnded:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
			or input.KeyCode == Enum.KeyCode.ButtonA
		then
			pressed = false
			refresh()
		end
	end)
	CollectionService:AddTag(root, StudUI.ButtonTag)
end

-- A white gamepad-selection ring (UIStroke) on `frame`, disabled until selected.
local function selectionRing(frame: GuiObject): UIStroke
	return Create.new("UIStroke", {
		Name = "SelectionRing",
		Color = Color3.new(1, 1, 1),
		Thickness = 4,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Enabled = false,
		Parent = frame,
	}) :: UIStroke
end

-- Common invisible root button (hit area + gamepad selection target).
local function rootButton(name: string, size: UDim2, options: { [string]: any }): TextButton
	return Create.new("TextButton", {
		Name = name,
		Size = size,
		Position = options.position or UDim2.new(),
		AnchorPoint = options.anchor or Vector2.zero,
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Selectable = true,
		LayoutOrder = options.layoutOrder or 0,
		-- Invisible engine selection image: our SelectionRing is the gamepad highlight.
		SelectionImageObject = Create.new("Frame", { BackgroundTransparency = 1 }),
	}) :: TextButton
end

-- Wraps a callback with the double-activation guard and a state gate. The returned handler
-- ignores the Activated arguments (InputObject, click count).
local function guarded(isEnabled: () -> boolean, callback: () -> ()): (any, any) -> ()
	local last = -math.huge
	return function(_input: any, _clicks: any)
		local now = os.clock()
		if now - last < ACTIVATE_DEBOUNCE or not isEnabled() then
			return
		end
		last = now
		local ok, err = pcall(callback)
		if not ok then
			warn(`[StudUI] button callback error: {err}`)
		end
	end
end

-- ── Text ─────────────────────────────────────────────────────────────────────────────────────

export type TextOptions = {
	text: string,
	textSize: number?,
	font: FontRole?,
	color: Color3?,
	size: UDim2?,
	position: UDim2?,
	anchor: Vector2?,
	align: Enum.TextXAlignment?,
	alignY: Enum.TextYAlignment?,
	wrap: boolean?,
	rich: boolean?,
	scaled: boolean?, -- TextScaled with textSize as the max
	autoWidth: boolean?, -- AutomaticSize X (width follows the text)
	zIndex: number?,
	layoutOrder: number?,
	parent: Instance?,
	name: string?,
}

--[[
	An outlined white label (Fredoka One by default).
	@param options text / size / font / colour / alignment / layout
	@return TextLabel
	Example: StudUI.text({ text = "Day 1", textSize = 40, parent = card.content })
]]
function StudUI.text(options: TextOptions): TextLabel
	local textSize = options.textSize or 32
	local label = Create.new("TextLabel", {
		Name = options.name or "Text",
		BackgroundTransparency = 1,
		Size = options.size or UDim2.new(1, 0, 0, textSize + 8),
		Position = options.position or UDim2.new(),
		AnchorPoint = options.anchor or Vector2.zero,
		Text = options.text,
		TextSize = textSize,
		TextScaled = options.scaled == true,
		FontFace = FONTS[(options.font or "title") :: FontRole],
		TextColor3 = options.color or Neutral.Text,
		TextXAlignment = options.align or Enum.TextXAlignment.Center,
		TextYAlignment = options.alignY or Enum.TextYAlignment.Center,
		TextWrapped = options.wrap == true or options.scaled == true,
		RichText = options.rich == true,
		AutomaticSize = if options.autoWidth then Enum.AutomaticSize.X else Enum.AutomaticSize.None,
		ZIndex = options.zIndex or 1,
		LayoutOrder = options.layoutOrder or 0,
	}) :: TextLabel
	if options.scaled then
		Create.new("UITextSizeConstraint", { MaxTextSize = textSize, MinTextSize = 10, Parent = label })
	end
	outline(label, textSize)
	if options.parent ~= nil then
		label.Parent = options.parent
	end
	return label
end

-- ── Icons ────────────────────────────────────────────────────────────────────────────────────

--[[
	Every icon key the kit and the HUD use (B15's icon pipeline renders + uploads these; the UI
	gallery shows them all). Keys are passed as plain strings, so screens may also use any other
	key IconAssets defines (e.g. MonetizationConfig's lowercase product icons).
]]
StudUI.IconKeys = table.freeze({
	-- HUD left column
	"Shop",
	"Rewards",
	"Daily",
	"Codes",
	"LuckyWheel",
	"Time",
	"Pets",
	"Rebirth",
	"Teleport",
	"Attack",
	"Event",
	"Admin",
	-- HUD right column offers
	"x2Cash",
	"StarterPack",
	"VIP",
	"Spins",
	"Teleporter",
	"SecretPack",
	-- currencies / prices
	"Cash",
	"Gems",
	"Robux",
	-- window + toasts + objective
	"Close",
	"Star",
	"Check",
	"Lock",
	"Gift",
	"Arrow",
})

-- Accepted uploaded-image content strings (config-driven, but never a stray URL).
local function validImage(value: unknown): string?
	if type(value) == "string" and string.match(value, "^rbxassetid://%d+$") ~= nil then
		return value
	end
	return nil
end

--[[
	The uploaded image for an icon key, or nil while it is not uploaded.
	Reads the agreed IconAssets shape owned by the icon builder (B15):
		IconAssets.get(key) -> { image: string ("" = not uploaded), size: Vector2 }?
	and, until that file is regenerated, the original shape (IconAssets.image(key) -> string?).
	Both are read through pcall + type checks, so a malformed entry falls back to the glyph.
	@param key icon key
	@return "rbxassetid://N" or nil
	Example: StudUI.iconImage("Shop")
]]
function StudUI.iconImage(key: string): string?
	local assets: any = IconAssets
	if type(assets.get) == "function" then
		local ok, entry = pcall(assets.get, key)
		if ok and type(entry) == "table" then
			return validImage(entry.image)
		end
		return nil
	end
	if type(assets.image) == "function" then
		local ok, image = pcall(assets.image, key)
		if ok then
			return validImage(image)
		end
	end
	return nil
end

--[[ True when `key` draws something specific (an uploaded image or a fallback glyph recipe). ]]
function StudUI.hasIcon(key: string): boolean
	return StudUI.iconImage(key) ~= nil or Glyphs.has(key)
end

--[[
	A `size` x `size` icon slot: an ImageLabel showing the uploaded 3D icon (IconAssets.get(key))
	scaled to FIT the slot, or, only while that image is "" / missing, the clean frame-drawn
	Glyphs fallback. Callers size the slot from UIStyleConfig.IconFill, which deliberately makes
	icons larger than their buttons so they poke out like the references. The returned Frame can
	be resized freely (content scales); nothing in it is Active / Selectable.
	@param key  icon key (unknown keys draw a star glyph)
	@param size design px
	@param zIndex optional base ZIndex
	@return Frame
	Example: StudUI.icon("Gems", 48).Parent = row
]]
function StudUI.icon(key: string, size: number, zIndex: number?): Frame
	local holder = Create.new("Frame", {
		Name = `Icon_{key}`,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size, size),
		Active = false,
		Selectable = false,
		ZIndex = zIndex or 2,
	}) :: Frame
	holder:SetAttribute("Decorative", true)
	holder:SetAttribute("IconKey", key)
	local image = StudUI.iconImage(key)
	if image ~= nil then
		Create.new("ImageLabel", {
			Name = "Image",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Image = image,
			ScaleType = Enum.ScaleType.Fit,
			Active = false,
			ZIndex = zIndex or 2,
			Parent = holder,
		})
	else
		local glyph = Glyphs.build(key, size, zIndex)
		glyph.Size = UDim2.fromScale(1, 1)
		glyph.Parent = holder
	end
	return holder
end

-- ── Robux tag ────────────────────────────────────────────────────────────────────────────────

--[[
	Green Robux glyph + price ("⏣ 25"), auto-width.
	@param price Robux price (nil / 0 shows "...": product not live yet); ignored with productKey
	@param textSize text height (glyph matches it)
	@param productKey MonetizationConfig pass / product key: the tag then shows the LIVE price
		from UI/PriceBook (managed pricing; "..." until known) and follows every change
	@return Frame (child "Price" is the TextLabel)
	Example: StudUI.robuxTag(39, 30).Parent = footer
	         StudUI.robuxTag(nil, 30, "VIP").Parent = footer -- live VIP price
]]
function StudUI.robuxTag(price: number?, textSize: number?, productKey: string?): Frame
	local h = textSize or 30
	local tag = Create.new("Frame", {
		Name = "RobuxTag",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(0, h + 6),
		AutomaticSize = Enum.AutomaticSize.X,
		Children = {
			Create.new("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				Padding = UDim.new(0, math.floor(h * 0.15)),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		},
	}) :: Frame
	local glyph = StudUI.icon("Robux", math.floor(h * 1.05))
	glyph.LayoutOrder = 1
	glyph.Parent = tag
	local priceLabel = StudUI.text({
		name = "Price",
		text = PriceBook.format(price),
		textSize = h,
		font = "title",
		color = Neutral.RobuxGreen,
		size = UDim2.fromOffset(0, h + 6),
		autoWidth = true,
		layoutOrder = 2,
		parent = tag,
	})
	if productKey ~= nil then
		-- Managed pricing: show what Roblox will actually charge ("..." until known); the
		-- binding ends when the label is destroyed.
		PriceBook.bind(priceLabel, productKey, function(live: number?)
			priceLabel.Text = PriceBook.format(live)
		end)
	end
	return tag
end

-- ── Buttons ──────────────────────────────────────────────────────────────────────────────────

export type ButtonOptions = {
	text: string,
	color: ColorName?,
	robux: number?, -- Robux price: empty text -> the tag IS the label; else a tag under the button
	-- MonetizationConfig pass / product key: like `robux`, but the LIVE price from UI/PriceBook
	-- (managed pricing; "..." until known; follows changes). Wins over `robux`.
	productKey: string?,
	icon: string?, -- optional IconAssets key left of the text
	size: UDim2?,
	textSize: number?,
	position: UDim2?,
	anchor: Vector2?,
	layoutOrder: number?,
	name: string?,
	parent: Instance?,
	onActivated: (() -> ())?,
}

export type Button = {
	instance: TextButton,
	label: TextLabel,
	setText: (text: string) -> (),
	setColor: (color: ColorName) -> (),
	setState: (state: ButtonState, text: string?) -> (),
	state: () -> ButtonState,
	setRobux: (price: number?) -> (), -- a fixed price (drops any live productKey binding)
	setProductKey: (key: string?) -> (), -- the live price of a pass / product key (nil = none)
	setCallback: (callback: (() -> ())?) -> (),
	Destroy: () -> (),
}

-- Default labels per state (the owner's references: "LOCKED!", "CLAIMED").
local STATE_TEXT: { [ButtonState]: string? } = {
	locked = "LOCKED!",
	claimed = "CLAIMED",
}

--[[
	A stud button (see the module header for the look). Gamepad-selectable; hover / select grows,
	press squashes; double activations within 0.25 s are ignored; only "normal" activates.
	States: locked (grey, "LOCKED!"), claimed (green, dimmed text, "CLAIMED"), disabled (faded).
	Prices: `robux` / setRobux show a fixed number; `productKey` / setProductKey show the LIVE
	Robux price of a pass / product (UI/PriceBook — managed pricing can change it) and follow it.
	@param options text / colour / robux / productKey / icon / size / callback
	@return Button handle
	Example:
		local claim = StudUI.button({ text = "CLAIM", color = "green", onActivated = claimDay })
		claim.setState("claimed")
		local buy = StudUI.button({ text = "", productKey = "CashSmall", onActivated = buyCash })
]]
function StudUI.button(options: ButtonOptions): Button
	local cfg = Style.Button
	local size = options.size or UDim2.fromOffset(240, cfg.DefaultHeight)
	local color: ColorName = options.color or "green"
	local state: ButtonState = "normal"
	local baseText = options.text
	local callback = options.onActivated
	local root = rootButton(options.name or `Button_{options.text}`, size, options :: any)
	local lip = cfg.Lip
	-- Dark outline behind face + lip (Edge px larger on every side).
	local edge = Create.new("Frame", {
		Name = "Edge",
		Position = UDim2.fromOffset(-cfg.Edge, -cfg.Edge),
		Size = UDim2.new(1, 2 * cfg.Edge, 1, 2 * cfg.Edge + lip),
		BackgroundColor3 = Neutral.Edge,
		BorderSizePixel = 0,
		Active = false,
		ZIndex = 1,
		Parent = root,
		Children = { Create.new("UICorner", { CornerRadius = UDim.new(0, cfg.Corner + cfg.Edge) }) },
	}) :: Frame
	edge:SetAttribute("Decorative", true)
	local lipFrame = Create.new("Frame", {
		Name = "Lip",
		Position = UDim2.fromOffset(0, lip),
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Style.Colors[color].lip,
		BorderSizePixel = 0,
		Active = false,
		ZIndex = 2,
		Parent = root,
		Children = { Create.new("UICorner", { CornerRadius = UDim.new(0, cfg.Corner) }) },
	}) :: Frame
	local face = Create.new("Frame", {
		Name = "Face",
		Size = UDim2.fromScale(1, 1),
		Active = false,
		ZIndex = 3,
		Parent = root,
	}) :: Frame
	local surface = StudWindow.surface(face, color, {
		tile = Style.StudTile.Button,
		studTransparency = Style.StudTransparency.Button,
		corner = cfg.Corner,
	})
	local ring = selectionRing(face)
	-- Content row: [icon] [robux glyph] [text], centred.
	local content = Create.new("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 3,
		Parent = face,
		Children = {
			Create.new("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, 8),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			Create.new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }),
		},
	}) :: Frame
	local heightPx = if size.Y.Scale == 0 then size.Y.Offset else cfg.DefaultHeight
	local textSize = options.textSize or math.floor(heightPx * 0.58)
	if options.icon ~= nil then
		local icon = StudUI.icon(options.icon, math.floor(heightPx * Style.IconFill.Button), 4)
		icon.LayoutOrder = 1
		icon.Parent = content
	end
	local robuxGlyph = StudUI.icon("Robux", math.floor(textSize * 1.05), 4)
	robuxGlyph.LayoutOrder = 2
	robuxGlyph.Visible = false
	robuxGlyph.Parent = content
	local label = StudUI.text({
		name = "Label",
		text = options.text,
		textSize = textSize,
		size = UDim2.fromScale(0, 1),
		autoWidth = true,
		zIndex = 4,
		layoutOrder = 3,
		parent = content,
	})
	--[[ Owner R94: a label wider than its button shrinks to fit instead of spilling past both
	     edges (the Harvest Feast's "HARVEST SHOP" + acorn in a 250 px button). Event-driven: re-fits
	     when the button resizes or its text changes, never grows past the requested size, and never
	     shrinks below 60 % of it. All widths are read in absolute pixels (UIScale-proof); the row's
	     side padding (2 x 10 design px) is estimated as 8 % of the row. ]]
	local rowLayout = content:FindFirstChildOfClass("UIListLayout") :: UIListLayout
	local function fitLabel()
		local rowWidth = content.AbsoluteSize.X
		if rowWidth <= 0 or rowLayout == nil then
			return
		end
		if label.TextSize ~= textSize then
			label.TextSize = textSize
		end
		local labelWidth = label.TextBounds.X
		local others = rowLayout.AbsoluteContentSize.X - label.AbsoluteSize.X
		local room = rowWidth * 0.92 - others
		if labelWidth > 0 and room > 0 and labelWidth > room then
			label.TextSize = math.max(math.floor(textSize * 0.6), math.floor(textSize * room / labelWidth))
		end
	end
	content:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitLabel)
	label:GetPropertyChangedSignal("Text"):Connect(fitLabel)
	-- The Robux tag shown UNDER a labelled button (reference: "DOUBLE IT!" with "⏣ 39" below).
	local underTag: Frame? = nil
	local robux: number? = nil

	-- Text shown for the current non-normal state (setState's optional override).
	local stateText: string? = nil

	-- Applies colour / text / dimming for the current state (single writer of the visuals).
	local function render()
		-- Locked buttons are always grey (references: "LOCKED!"); other states keep the preset.
		local shownColor: ColorName = if state == "locked" then "grey" else color
		surface.setColor(shownColor)
		-- Press feedback (UI/ButtonFeedback, owner R22): colour-matched burst, locked sound.
		root:SetAttribute("FeedbackColor", shownColor)
		root:SetAttribute("FeedbackLocked", state ~= "normal")
		lipFrame.BackgroundColor3 = Style.Colors[shownColor].lip
		local shownText = if state == "normal" or state == "disabled"
			then baseText
			else (stateText or STATE_TEXT[state] or baseText)
		local priceOnly = robux ~= nil and baseText == "" and state == "normal"
		robuxGlyph.Visible = priceOnly
		label.Text = if priceOnly then PriceBook.format(robux) else shownText
		local dim = state == "disabled"
		face.BackgroundTransparency = if dim then 0.45 else 0
		lipFrame.BackgroundTransparency = if dim then 0.45 else 0
		label.TextTransparency = if state == "claimed" then 0.25 elseif dim then 0.4 else 0
		local tag = underTag
		if tag ~= nil then
			tag.Visible = state == "normal"
		end
	end

	-- Shows `price` (nil = no price, 0 = "..."): price-only label or the tag under the button.
	local function applyRobux(price: number?)
		robux = price
		if price ~= nil and baseText ~= "" and underTag == nil then
			local tag = StudUI.robuxTag(price, math.floor(textSize * 0.6))
			tag.AnchorPoint = Vector2.new(0.5, 0)
			tag.Position = UDim2.new(0.5, 0, 1, lip + cfg.Edge + 4)
			tag.ZIndex = 5
			tag.Parent = root
			underTag = tag
		elseif underTag ~= nil then
			if price == nil then
				underTag:Destroy()
				underTag = nil
			else
				local priceLabel = underTag:FindFirstChild("Price")
				if priceLabel ~= nil and priceLabel:IsA("TextLabel") then
					priceLabel.Text = PriceBook.format(price)
				end
			end
		end
		render()
	end

	-- The PriceBook key whose live price this button shows (nil = fixed price / none).
	local liveKey: string? = nil

	-- A fixed price (nil hides it); drops any live binding first.
	local function setRobux(price: number?)
		if liveKey ~= nil then
			liveKey = nil
			PriceBook.unbind(root)
		end
		applyRobux(price)
	end

	-- The live price of a pass / product key ("..." until PriceBook knows it); nil = no price.
	local function setProductKey(key: string?)
		if key == nil then
			setRobux(nil)
			return
		end
		if key == liveKey then
			return
		end
		liveKey = key
		PriceBook.bind(root, key, function(live: number?)
			applyRobux(live or 0) -- 0 keeps the tag up with "..."
		end)
	end

	-- Purchases / claims burst coins (bigger) with the claim sound; everything else stars.
	local upper = string.upper(options.text)
	local rewarding = options.robux ~= nil
		or options.productKey ~= nil
		or string.find(upper, "CLAIM", 1, true) ~= nil
		or string.find(upper, "BUY", 1, true) ~= nil
		or string.find(upper, "REDEEM", 1, true) ~= nil
		or string.find(upper, "DOUBLE", 1, true) ~= nil
	root:SetAttribute("FeedbackKind", if rewarding then "Coins" else "Stars")
	pressFeel(root, ring)
	root.Activated:Connect(guarded(function()
		return state == "normal"
	end, function()
		local fn = callback
		if fn ~= nil then
			fn()
		end
	end))
	if options.productKey ~= nil then
		setProductKey(options.productKey)
	elseif options.robux ~= nil then
		setRobux(options.robux)
	else
		render()
	end
	if options.parent ~= nil then
		root.Parent = options.parent
	end
	return {
		instance = root,
		label = label,
		setText = function(text: string)
			baseText = text
			render()
		end,
		setColor = function(name: ColorName)
			color = name
			render()
		end,
		setState = function(newState: ButtonState, text: string?)
			state = newState
			stateText = text
			render()
		end,
		state = function(): ButtonState
			return state
		end,
		setRobux = setRobux,
		setProductKey = setProductKey,
		setCallback = function(fn: (() -> ())?)
			callback = fn
		end,
		Destroy = function()
			root:Destroy()
		end,
	}
end

--[[
	The red square X close button (stud face, dark outline, white X).
	@param options size (square side, default UIStyleConfig.Window.CloseSize) / callback / parent
	@return Button handle
	Example: StudUI.closeButton({ onActivated = function() ScreenManager.close("Shop") end })
]]
function StudUI.closeButton(options: {
	size: number?,
	onActivated: (() -> ())?,
	parent: Instance?,
	position: UDim2?,
	anchor: Vector2?,
}): Button
	local side = options.size or Style.Window.CloseSize
	local button = StudUI.button({
		text = "X",
		name = "Close",
		color = "red",
		size = UDim2.fromOffset(side, side - Style.Button.Lip),
		textSize = math.floor(side * 0.62),
		position = options.position,
		anchor = options.anchor,
		parent = options.parent,
		onActivated = options.onActivated,
	})
	-- The window's "ui_close" (ScreenManager.Closed) is the close sound: no extra click.
	button.instance:SetAttribute("FeedbackSound", "")
	-- Once the icon pipeline uploads a rendered "Close" icon, it replaces the text X (same red
	-- stud button, same hit area / selection / press feel; the icon pokes out slightly).
	if StudUI.iconImage("Close") ~= nil then
		local face = button.instance:FindFirstChild("Face")
		if face ~= nil and face:IsA("GuiObject") then
			button.label.Visible = false
			local closeSize = math.floor(side * Style.IconFill.Close)
			local icon = StudUI.icon("Close", closeSize, 5)
			icon.AnchorPoint = Vector2.new(0.5, 0.5)
			icon.Position = UDim2.fromScale(0.5, 0.5)
			icon.Parent = face
		end
	end
	return button
end

-- ── Window ───────────────────────────────────────────────────────────────────────────────────

export type WindowOptions = {
	title: string,
	color: ColorName?,
	icon: string?,
	size: Vector2?, -- design px (default 1000 x 640)
	scroll: boolean?, -- body is a vertical ScrollingFrame (AutomaticCanvasSize Y)
	onClose: (() -> ())?,
	name: string?,
	parent: Instance?,
}

export type Window = {
	frame: Frame,
	header: Frame,
	body: GuiObject, -- put content here (layouts allowed)
	closeButton: TextButton,
	titleLabel: TextLabel,
	designSize: Vector2,
	setTitle: (text: string) -> (),
	setColor: (color: ColorName) -> (),
	-- Swaps the header icon (R70: per-world popups show their own portal icon). No-op for a
	-- window built without an icon (its title stays where it is).
	setIcon: (key: string) -> (),
	Destroy: () -> (),
}

--[[
	A stud window: coloured drifting-stud header bar with the icon, a big outlined title and the
	red square X, over a dark slate body with a faint stud emboss.
	@param options title / colour / icon / size / scroll / onClose
	@return Window handle (`body` is where content goes)
	Example:
		local window = StudUI.window({ title = "Daily Rewards", color = "red", icon = "Daily",
			size = Vector2.new(980, 640), onClose = close })
]]
function StudUI.window(options: WindowOptions): Window
	local cfg = Style.Window
	local designSize = options.size or Vector2.new(1000, 640)
	local color: ColorName = options.color or "blue"
	local frame = Create.new("Frame", {
		Name = options.name or "StudWindow",
		Size = UDim2.fromOffset(designSize.X, designSize.Y),
		BackgroundColor3 = Neutral.Body,
		BorderSizePixel = 0,
		Active = true, -- swallow clicks so they never fall through to the world
		Children = {
			Create.new("UICorner", { CornerRadius = UDim.new(0, cfg.Corner) }),
		},
	}) :: Frame
	StudWindow.edge(frame, cfg.Edge)
	PanelBackdrop.new(frame, {
		zIndex = 0,
		textureTransparency = Style.StudTransparency.Body,
		tileSize = Style.StudTile.Window,
		cornerRadius = cfg.Corner,
	})
	local header = Create.new("Frame", {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, cfg.HeaderHeight),
		ZIndex = 2,
		Parent = frame,
	}) :: Frame
	local surface = StudWindow.surface(header, color, {
		tile = Style.StudTile.Window,
		studTransparency = Style.StudTransparency.Header,
		scroll = true,
		corner = cfg.Corner,
	})
	-- The dark line between header and body.
	Create.new("Frame", {
		Name = "HeaderLine",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, cfg.HeaderLip),
		Size = UDim2.new(1, 0, 0, cfg.HeaderLip),
		BackgroundColor3 = Neutral.Edge,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = header,
	})
	local titleX = 22
	-- Bigger than the bar (IconFill.Header): the 3D icon pokes out above it like the references.
	local iconSize = math.floor(cfg.HeaderHeight * Style.IconFill.Header)
	local iconKey: string? = options.icon
	local headerIcon: Frame? = nil
	-- Builds the header icon for `key` at the fixed header slot.
	local function placeIcon(key: string): Frame
		local icon = StudUI.icon(key, iconSize, 4)
		icon.AnchorPoint = Vector2.new(0, 0.5)
		icon.Position = UDim2.new(0, 10, 0.5, -4)
		icon.Rotation = -6
		icon.Parent = header
		return icon
	end
	if options.icon ~= nil then
		headerIcon = placeIcon(options.icon)
		titleX = 10 + iconSize + 10
	end
	local titleLabel = StudUI.text({
		name = "Title",
		text = options.title,
		textSize = cfg.TitleSize,
		font = "title",
		align = Enum.TextXAlignment.Left,
		position = UDim2.new(0, titleX, 0.5, 0),
		anchor = Vector2.new(0, 0.5),
		size = UDim2.new(1, -(titleX + cfg.CloseSize + 30), 0, cfg.TitleSize + 12),
		zIndex = 4,
		parent = header,
	})
	local close = StudUI.closeButton({
		position = UDim2.new(1, -14, 0.5, -math.floor(Style.Button.Lip / 2)),
		anchor = Vector2.new(1, 0.5),
		parent = header,
		onActivated = options.onClose,
	})
	close.instance.ZIndex = 5
	local bodyTop = cfg.HeaderHeight + cfg.HeaderLip
	local body: GuiObject
	if options.scroll then
		body = Create.new("ScrollingFrame", {
			Name = "Body",
			Position = UDim2.fromOffset(0, bodyTop),
			Size = UDim2.new(1, 0, 1, -bodyTop),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			ScrollBarThickness = 8,
			ScrollBarImageColor3 = Color3.new(1, 1, 1),
			ScrollBarImageTransparency = 0.4,
			ElasticBehavior = Enum.ElasticBehavior.WhenScrollable,
			Selectable = false,
			ZIndex = 1,
			Parent = frame,
		}) :: ScrollingFrame
	else
		body = Create.new("Frame", {
			Name = "Body",
			Position = UDim2.fromOffset(0, bodyTop),
			Size = UDim2.new(1, 0, 1, -bodyTop),
			BackgroundTransparency = 1,
			ZIndex = 1,
			Parent = frame,
		}) :: Frame
	end
	Create.new("UIPadding", {
		PaddingTop = UDim.new(0, cfg.BodyPadding),
		PaddingBottom = UDim.new(0, cfg.BodyPadding),
		PaddingLeft = UDim.new(0, cfg.BodyPadding),
		PaddingRight = UDim.new(0, cfg.BodyPadding),
		Parent = body,
	})
	if options.parent ~= nil then
		frame.Parent = options.parent
	end
	return {
		frame = frame,
		header = header,
		body = body,
		closeButton = close.instance,
		titleLabel = titleLabel,
		designSize = designSize,
		setTitle = function(text: string)
			titleLabel.Text = text
		end,
		setColor = function(name: ColorName)
			surface.setColor(name)
		end,
		setIcon = function(key: string)
			local current = headerIcon
			if current == nil or key == iconKey then
				return
			end
			iconKey = key
			current:Destroy()
			headerIcon = placeIcon(key)
		end,
		Destroy = function()
			frame:Destroy()
		end,
	}
end

export type ModalSpec = {
	name: string,
	title: string,
	color: ColorName?,
	icon: string?,
	size: Vector2,
	scroll: boolean?,
	lazy: boolean?,
	prebuild: boolean?,
	displayOrder: number?,
	blur: boolean?,
	-- Fill the window; return optional handle hooks (onOpen gets ScreenManager.open's args).
	build: (window: Window, gui: ScreenGui) -> ScreenManager.ScreenHandle?,
}

--[[
	A complete modal ScreenModule around a StudUI window: ModalShell fit + pop-in, the red X /
	keyboard X / gamepad B close it, and gamepad selection starts on the screen's
	defaultSelection (or the close button). Drop the result in UI/Screens/<Name>.luau.
	@param spec name / title / colour / icon / size / build(window, gui)
	@return ScreenManager.ScreenModule
	Example: return StudUI.modalScreen({ name = "Codes", title = "Codes", size = Vector2.new(900, 520),
		build = function(window) ... end })
]]
function StudUI.modalScreen(spec: ModalSpec): ScreenManager.ScreenModule
	return {
		name = spec.name,
		modal = true,
		closeOnBack = true,
		lazy = if spec.lazy == nil then true else spec.lazy,
		prebuild = spec.prebuild,
		displayOrder = spec.displayOrder,
		blur = spec.blur,
		build = function(gui: ScreenGui): ScreenManager.ScreenHandle
			local window = StudUI.window({
				title = spec.title,
				color = spec.color,
				icon = spec.icon,
				size = spec.size,
				scroll = spec.scroll,
				name = `{spec.name}Window`,
				onClose = function()
					ScreenManager.close(spec.name)
				end,
			})
			local shell = ModalShell.new(gui, window.frame, spec.size)
			local inner: ScreenManager.ScreenHandle = spec.build(window, gui) or {}
			return {
				onOpen = function(args: any?)
					shell.popIn()
					local onOpen = inner.onOpen
					if onOpen ~= nil then
						onOpen(args)
					end
				end,
				onClose = inner.onClose,
				onBack = inner.onBack,
				defaultSelection = inner.defaultSelection or function(): GuiObject?
					return window.closeButton
				end,
			}
		end,
	}
end

-- ── Cards ────────────────────────────────────────────────────────────────────────────────────

export type CardOptions = {
	color: ColorName?,
	sunburst: boolean?,
	title: string?,
	titleSize: number?,
	size: UDim2?,
	position: UDim2?,
	anchor: Vector2?,
	layoutOrder: number?,
	name: string?,
	parent: Instance?,
}

export type Card = {
	frame: Frame,
	content: Frame, -- put content here (layouts allowed)
	titleLabel: TextLabel?,
	setColor: (color: ColorName) -> (),
	setTitle: (text: string) -> (),
	Destroy: () -> (),
}

--[[
	A coloured stud card (reward tile / offer panel): gradient + studs + thick dark outline,
	optional light sunburst behind its content and an optional outlined title at the top.
	@param options colour ("rainbow" for the Day 7 / final card) / sunburst / title / size
	@return Card handle
	Example: local day = StudUI.card({ color = "sky", title = "Day 1", sunburst = true,
		size = UDim2.fromOffset(200, 220), parent = grid })
]]
function StudUI.card(options: CardOptions): Card
	local cfg = Style.Card
	local frame = Create.new("Frame", {
		Name = options.name or "StudCard",
		Size = options.size or UDim2.fromOffset(220, 240),
		Position = options.position or UDim2.new(),
		AnchorPoint = options.anchor or Vector2.zero,
		LayoutOrder = options.layoutOrder or 0,
	}) :: Frame
	local surface = StudWindow.surface(frame, options.color or "sky", {
		tile = Style.StudTile.Card,
		studTransparency = Style.StudTransparency.Card,
		edge = cfg.Edge,
		corner = cfg.Corner,
	})
	if options.sunburst then
		-- Clip lane so the rays stay inside the card (rotated children clip to an unrotated parent).
		local clip = Create.new("Frame", {
			Name = "BurstClip",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			ClipsDescendants = true,
			Active = false,
			ZIndex = 1,
			Parent = frame,
		}) :: Frame
		StudWindow.sunburst(clip, { zIndex = 1, size = UDim2.fromScale(1.5, 1.5) })
	end
	local content = Create.new("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		Parent = frame,
		Children = {
			Create.new("UIPadding", {
				PaddingTop = UDim.new(0, cfg.Padding),
				PaddingBottom = UDim.new(0, cfg.Padding),
				PaddingLeft = UDim.new(0, cfg.Padding),
				PaddingRight = UDim.new(0, cfg.Padding),
			}),
		},
	}) :: Frame
	local titleLabel: TextLabel? = nil
	if options.title ~= nil then
		local size = options.titleSize or cfg.TitleSize
		titleLabel = StudUI.text({
			name = "Title",
			text = options.title,
			textSize = size,
			size = UDim2.new(1, 0, 0, size + 6),
			zIndex = 3,
			parent = frame,
		})
		local title = titleLabel :: TextLabel
		title.Position = UDim2.fromOffset(0, 4)
	end
	if options.parent ~= nil then
		frame.Parent = options.parent
	end
	return {
		frame = frame,
		content = content,
		titleLabel = titleLabel,
		setColor = surface.setColor,
		setTitle = function(text: string)
			if titleLabel ~= nil then
				titleLabel.Text = text
			end
		end,
		Destroy = function()
			frame:Destroy()
		end,
	}
end

--[[
	"- LIMITED TIME -" style section heading (white, outlined, Fredoka One).
	@param text the heading (dashes are added)
	@param textSize optional (default 48)
	@return TextLabel
]]
function StudUI.sectionLabel(text: string, textSize: number?): TextLabel
	local size = textSize or 48
	return StudUI.text({
		name = "Section",
		text = `- {string.upper(text)} -`,
		textSize = size,
		size = UDim2.new(1, 0, 0, size + 10),
	})
end

export type TextBoxOptions = {
	placeholder: string?,
	textSize: number?,
	size: UDim2?,
	maxLength: number?, -- client-side typing cap (the server validates again)
	layoutOrder: number?,
	parent: Instance?,
	onSubmit: ((text: string) -> ())?, -- Enter pressed
}

export type TextBoxHandle = {
	instance: TextBox,
	frame: Frame,
	text: () -> string,
	clear: () -> (),
	Destroy: () -> (),
}

--[[
	The dark-well text box from the Codes reference (white heavy text, grey placeholder, dark
	outline). `maxLength` trims typing on the client only; servers re-validate every string.
	@return TextBoxHandle
	Example: local box = StudUI.textBox({ placeholder = "Code Here", maxLength = 24, parent = row })
]]
function StudUI.textBox(options: TextBoxOptions): TextBoxHandle
	local textSize = options.textSize or 44
	local frame = Create.new("Frame", {
		Name = "TextWell",
		Size = options.size or UDim2.fromOffset(520, 96),
		BackgroundColor3 = Neutral.Well,
		LayoutOrder = options.layoutOrder or 0,
		Children = { Create.new("UICorner", { CornerRadius = UDim.new(0, 6) }) },
	}) :: Frame
	StudWindow.edge(frame, 4)
	local box = Create.new("TextBox", {
		Name = "Input",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -36, 1, 0),
		Position = UDim2.fromOffset(18, 0),
		Text = "",
		PlaceholderText = options.placeholder or "",
		PlaceholderColor3 = Neutral.Placeholder,
		TextColor3 = Neutral.Text,
		TextSize = textSize,
		FontFace = Style.Fonts.Title,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClearTextOnFocus = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Selectable = true,
		Parent = frame,
	}) :: TextBox
	outline(box, math.floor(textSize * 0.7))
	local maxLength = options.maxLength
	if maxLength ~= nil and maxLength > 0 then
		box:GetPropertyChangedSignal("Text"):Connect(function()
			if utf8.len(box.Text) ~= nil and (utf8.len(box.Text) :: number) > maxLength then
				local cut = utf8.offset(box.Text, maxLength + 1)
				if cut ~= nil then
					box.Text = string.sub(box.Text, 1, cut - 1)
				end
			end
		end)
	end
	local onSubmit = options.onSubmit
	if onSubmit ~= nil then
		box.FocusLost:Connect(function(enterPressed: boolean)
			if enterPressed then
				onSubmit(box.Text)
			end
		end)
	end
	if options.parent ~= nil then
		frame.Parent = options.parent
	end
	return {
		instance = box,
		frame = frame,
		text = function(): string
			return box.Text
		end,
		clear = function()
			box.Text = ""
		end,
		Destroy = function()
			frame:Destroy()
		end,
	}
end

-- ── Right-column offers ──────────────────────────────────────────────────────────────────────

export type StarburstOptions = {
	label: string,
	robuxPrice: number?, -- nil hides the tag; 0 shows "..." (product not live yet)
	-- MonetizationConfig pass / product key: the tag shows its LIVE price (UI/PriceBook) and
	-- follows changes. Wins over robuxPrice.
	productKey: string?,
	icon: string?,
	size: number?, -- slot side (default UIStyleConfig.Hud.OfferSize)
	layoutOrder: number?,
	position: UDim2?,
	anchor: Vector2?,
	name: string?,
	parent: Instance?,
	onActivated: (() -> ())?,
}

export type Starburst = {
	instance: TextButton,
	setLabel: (text: string) -> (),
	setPrice: (price: number?) -> (), -- a fixed price (drops any live productKey binding)
	setProductKey: (key: string?) -> (), -- the live price of a pass / product key (nil = none)
	setIcon: (key: string) -> (),
	setSize: (side: number) -> (),
	setCallback: (callback: (() -> ())?) -> (),
	pop: () -> (), -- a short "new offer" bounce of the icon (rotation swaps)
	Destroy: () -> (),
}

--[[
	A right-column Robux offer: dark spiky starburst (slow spin), the item icon, a big outlined
	label at the bottom and a green Robux tag top-right (references: x2 Speed, Starter Pack, VIP).
	@param options label / robuxPrice or productKey (live price) / icon / size / callback
	@return Starburst handle
	Example: StudUI.starburst({ label = "VIP", productKey = "VIP", icon = "VIP", parent = column })
]]
function StudUI.starburst(options: StarburstOptions): Starburst
	local side = options.size or Style.Hud.OfferSize
	local callback = options.onActivated
	local root = rootButton(options.name or `Offer_{options.label}`, UDim2.fromOffset(side, side), options :: any)
	StudWindow.starburst(root, { zIndex = 1, size = UDim2.fromScale(1.05, 1.05) })
	local iconKey = options.icon or "Star"
	local fill = Style.IconFill.Starburst
	local icon = StudUI.icon(iconKey, math.floor(side * fill), 3)
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.42)
	icon.Size = UDim2.fromScale(fill, fill)
	icon.Parent = root
	local label = StudUI.text({
		name = "Label",
		text = options.label,
		textSize = math.floor(side * 0.2),
		scaled = true,
		size = UDim2.fromScale(1.05, 0.34),
		position = UDim2.fromScale(0.5, 1.02),
		anchor = Vector2.new(0.5, 1),
		zIndex = 6,
		parent = root,
	})
	local tag: Frame? = nil
	local tagKey: string? = nil -- the live PriceBook key the current tag follows
	-- (Re)builds the top-right Robux tag: a fixed price, a live key, or none (both nil).
	local function buildTag(price: number?, productKey: string?)
		if tag ~= nil then
			tag:Destroy() -- also ends its PriceBook binding (Destroying)
			tag = nil
		end
		tagKey = productKey
		if price == nil and productKey == nil then
			return
		end
		local built = StudUI.robuxTag(price, math.floor(side * 0.15), productKey)
		built.AnchorPoint = Vector2.new(0.5, 0)
		built.Position = UDim2.fromScale(0.68, 0.02)
		built.ZIndex = 6
		built.Parent = root
		tag = built
	end
	local function setPrice(price: number?)
		buildTag(price, nil)
	end
	local function setProductKey(key: string?)
		-- Same key: the existing tag already follows it (no Instance churn on profile updates).
		if key ~= nil and key == tagKey and tag ~= nil then
			return
		end
		buildTag(nil, key)
	end
	if options.productKey ~= nil then
		setProductKey(options.productKey)
	else
		setPrice(options.robuxPrice)
	end
	root:SetAttribute("FeedbackKind", "Coins")
	root:SetAttribute("FeedbackColor", "yellow")
	local ring = Create.new("UIStroke", {
		Name = "SelectionRing",
		Color = Color3.new(1, 1, 1),
		Thickness = 3,
		Enabled = false,
		Parent = icon,
	}) :: UIStroke
	pressFeel(root, ring)
	root.Activated:Connect(guarded(function()
		return true
	end, function()
		local fn = callback
		if fn ~= nil then
			fn()
		end
	end))
	if options.parent ~= nil then
		root.Parent = options.parent
	end
	return {
		instance = root,
		setLabel = function(text: string)
			label.Text = text
		end,
		setPrice = setPrice,
		setProductKey = setProductKey,
		setIcon = function(key: string)
			if key == iconKey then
				return
			end
			iconKey = key
			local fresh = StudUI.icon(key, math.floor(side * fill), 3)
			fresh.AnchorPoint = icon.AnchorPoint
			fresh.Position = icon.Position
			fresh.Size = icon.Size
			fresh.Parent = root
			ring.Parent = fresh
			icon:Destroy()
			icon = fresh
		end,
		setSize = function(newSide: number)
			side = newSide
			root.Size = UDim2.fromOffset(newSide, newSide)
			local constraint = label:FindFirstChildOfClass("UITextSizeConstraint")
			if constraint ~= nil then
				constraint.MaxTextSize = math.floor(newSide * 0.2)
			end
		end,
		setCallback = function(fn: (() -> ())?)
			callback = fn
		end,
		pop = function()
			-- The icon holder owns its own UIScale (the root's PressScale belongs to pressFeel).
			local scale = icon:FindFirstChild("Pop") :: UIScale?
			if scale == nil then
				scale = Create.new("UIScale", { Name = "Pop", Scale = 1, Parent = icon }) :: UIScale
			end
			assert(scale ~= nil, "pop scale")
			scale.Scale = 0.55
			TweenService:Create(scale, TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
				Scale = 1,
			}):Play()
		end,
		Destroy = function()
			root:Destroy()
		end,
	}
end

-- ── Left-column HUD buttons ──────────────────────────────────────────────────────────────────

export type HudButtonOptions = {
	label: string,
	icon: string,
	color: ColorName?,
	wide: boolean?,
	size: Vector2?, -- design px (HUD layout sets it later through setSize)
	layoutOrder: number?,
	name: string?,
	parent: Instance?,
	onActivated: (() -> ())?,
}

export type HudButton = {
	instance: TextButton,
	setSize: (width: number, height: number) -> (),
	setBadge: (text: string?) -> (), -- nil hides; e.g. "!" or "3"
	setLabel: (text: string) -> (),
	-- Smallest label text cap in design px (owner R59 phones: 14 pt on 44 pt tiles); nil = the
	-- default Hud.LabelRatio sizing only. Re-applies the current size.
	setLabelFloor: (px: number?) -> (),
	setColor: (color: ColorName) -> (),
	Destroy: () -> (),
}

--[[
	A left-column HUD stud tile: coloured stud face with a dark outline and a light inner border,
	a big icon, an outlined label across the bottom (wide: across the middle, over the icon like
	the reference "Lucky Wheel"), and an optional red notification badge.
	@param options label / icon / colour / wide / size / callback
	@return HudButton handle
	Example: StudUI.hudButton({ label = "Shop", icon = "Shop", color = "yellow",
		onActivated = function() ScreenManager.open("Shop") end })
]]
function StudUI.hudButton(options: HudButtonOptions): HudButton
	local hud = Style.Hud
	local wide = options.wide == true
	local initial = options.size
		or Vector2.new(
			if wide then hud.ButtonSize * 2 + hud.Gap else hud.ButtonSize,
			if wide then hud.WideHeight else hud.ButtonSize
		)
	local callback = options.onActivated
	local root =
		rootButton(options.name or `Hud_{options.label}`, UDim2.fromOffset(initial.X, initial.Y), options :: any)
	local face = Create.new("Frame", {
		Name = "Face",
		Size = UDim2.fromScale(1, 1),
		Active = false,
		ZIndex = 1,
		Parent = root,
	}) :: Frame
	local surface = StudWindow.surface(face, options.color or "blue", {
		tile = Style.StudTile.Hud,
		studTransparency = Style.StudTransparency.Hud,
		edge = 4,
		corner = 8,
	})
	-- Light inner border (the references' thin pale frame inside the dark outline).
	local inner = Create.new("Frame", {
		Name = "InnerBorder",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(3, 3),
		Size = UDim2.new(1, -6, 1, -6),
		Active = false,
		ZIndex = 1,
		Parent = face,
		Children = {
			Create.new("UICorner", { CornerRadius = UDim.new(0, 6) }),
			Create.new("UIStroke", { Color = Color3.new(1, 1, 1), Transparency = 0.45, Thickness = 2 }),
		},
	}) :: Frame
	inner:SetAttribute("Decorative", true)
	local ring = selectionRing(face)
	ring.Thickness = 5
	local icon = StudUI.icon(options.icon, math.floor(initial.Y * Style.IconFill.Hud), 2)
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Parent = face
	local label = StudUI.text({
		name = "Label",
		text = options.label,
		textSize = 30,
		scaled = true,
		anchor = Vector2.new(0.5, 1),
		zIndex = 6,
		parent = face,
	})
	local badge = Create.new("Frame", {
		Name = "Badge",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -6, 0, 6),
		Size = UDim2.fromOffset(38, 38),
		BackgroundColor3 = Style.Colors.red.bottom,
		Visible = false,
		ZIndex = 8,
		Parent = root,
		Children = { Create.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }) },
	}) :: Frame
	StudWindow.edge(badge, 3)
	local badgeText = StudUI.text({
		name = "BadgeText",
		text = "!",
		textSize = 26,
		size = UDim2.fromScale(1, 1),
		zIndex = 9,
		parent = badge,
	})

	-- The label text cap never goes under this (setLabelFloor; 0 = off).
	local labelFloor = 0
	-- Re-lays out icon / label / badge for a new size (called by the HUD on every re-layout).
	local function layout(width: number, height: number)
		root.Size = UDim2.fromOffset(width, height)
		local fill = Style.IconFill
		if wide then
			-- The wheel overflows the short wide bar above and below (reference "Lucky Wheel").
			local side = math.floor(height * fill.HudWide)
			icon.Size = UDim2.fromOffset(side, side)
			icon.Position = UDim2.fromScale(0.5, 0.5)
			label.Size = UDim2.new(1, -10, 0.5, 0)
			label.Position = UDim2.fromScale(0.5, 0.75)
			local constraint = label:FindFirstChildOfClass("UITextSizeConstraint")
			if constraint ~= nil then
				constraint.MaxTextSize = math.max(math.floor(height * 0.4), labelFloor)
			end
		else
			-- The icon fills the tile and pokes out of its TOP edge; the label overlaps its foot.
			local side = math.floor(height * fill.Hud)
			icon.Size = UDim2.fromOffset(side, side)
			icon.Position = UDim2.fromScale(0.5, fill.HudCenterY)
			label.Position = UDim2.new(0.5, 0, 1, -2)
			-- 34 % of the tile; a label floor (phones) also needs a box tall enough to reach it.
			label.Size = UDim2.new(1, -6, 0, math.max(math.floor(height * 0.34), labelFloor + 2))
			local constraint = label:FindFirstChildOfClass("UITextSizeConstraint")
			if constraint ~= nil then
				constraint.MaxTextSize = math.max(math.floor(height * hud.LabelRatio), labelFloor)
			end
		end
		local badgeSide = math.max(24, math.floor(height * 0.28))
		badge.Size = UDim2.fromOffset(badgeSide, badgeSide)
		badgeText.TextSize = math.floor(badgeSide * 0.7)
	end
	layout(initial.X, initial.Y)
	root:SetAttribute("FeedbackKind", "Studs")
	root:SetAttribute("FeedbackColor", options.color or "blue")
	pressFeel(root, ring)
	root.Activated:Connect(guarded(function()
		return true
	end, function()
		local fn = callback
		if fn ~= nil then
			fn()
		end
	end))
	if options.parent ~= nil then
		root.Parent = options.parent
	end
	return {
		instance = root,
		setSize = layout,
		setBadge = function(text: string?)
			badge.Visible = text ~= nil
			if text ~= nil then
				badgeText.Text = text
			end
		end,
		setLabel = function(text: string)
			label.Text = text
		end,
		setLabelFloor = function(px: number?)
			local floor = math.max(0, math.floor(px or 0))
			if floor ~= labelFloor then
				labelFloor = floor
				layout(root.Size.X.Offset, root.Size.Y.Offset)
			end
		end,
		setColor = function(name: ColorName)
			surface.setColor(name)
			root:SetAttribute("FeedbackColor", name)
		end,
		Destroy = function()
			root:Destroy()
		end,
	}
end

-- ── Money ────────────────────────────────────────────────────────────────────────────────────

export type MoneyKind = "cash" | "gems" | "rate"

export type MoneyOptions = {
	kind: MoneyKind?,
	textSize: number?,
	icon: boolean?, -- default true (rate: false)
	amount: number?,
	layoutOrder: number?,
	parent: Instance?,
	format: ((amount: number) -> string)?, -- default per kind (short numbers)
}

export type MoneyLabel = {
	frame: Frame,
	label: TextLabel,
	setAmount: (amount: number, animate: boolean?) -> (),
	amount: () -> number,
	Destroy: () -> (),
}

-- Default formatting per kind: the big HUD counters use NumberFormat.precise (two decimals at
-- every tier, the references' "119.08K"); the rate chip uses NumberFormat.rate ("+$1.25K/s").
local function formatFor(kind: MoneyKind): (number) -> string
	if kind == "rate" then
		return NumberFormat.rate
	end
	return function(amount: number): string
		return NumberFormat.precise(amount)
	end
end

--[[
	A chunky currency counter: icon (money stack / gem) + big outlined number (Luckiest Guy;
	cash green, gems purple, rate small green "+$X/s"). setAmount(n, true) rolls the number up
	over 0.35 s (increases only; decreases snap so spending feels instant).
	@param options kind / textSize / icon / amount / format
	@return MoneyLabel handle
	Example: local cash = StudUI.moneyLabel({ kind = "cash", parent = top }); cash.setAmount(119080, true)
]]
function StudUI.moneyLabel(options: MoneyOptions): MoneyLabel
	local kind: MoneyKind = options.kind or "cash"
	local hud = Style.Hud
	local textSize = options.textSize
		or (if kind == "cash" then hud.CashTextSize elseif kind == "gems" then hud.GemTextSize else hud.RateTextSize)
	local color = if kind == "gems" then Neutral.GemPurple else Neutral.CashGreen
	local format = options.format or formatFor(kind)
	local frame = Create.new("Frame", {
		Name = `Money_{kind}`,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(0, textSize + 10),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = options.layoutOrder or 0,
		Children = {
			Create.new("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				Padding = UDim.new(0, math.floor(textSize * 0.15)),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		},
	}) :: Frame
	local showIcon = if options.icon == nil then kind ~= "rate" else options.icon
	if showIcon then
		local icon =
			StudUI.icon(if kind == "gems" then "Gems" else "Cash", math.floor(textSize * Style.IconFill.Money), 2)
		icon.LayoutOrder = 1
		icon.Parent = frame
	end
	local label = StudUI.text({
		name = "Amount",
		text = format(options.amount or 0),
		textSize = textSize,
		font = if kind == "rate" then "title" else "number",
		color = color,
		size = UDim2.fromOffset(0, textSize + 10),
		autoWidth = true,
		layoutOrder = 2,
		parent = frame,
	})
	StudWindow.outline(label, math.max(3, math.floor(textSize * 0.1)))
	local current = options.amount or 0
	local roll = Create.new("NumberValue", { Value = current }) :: NumberValue
	roll.Changed:Connect(function(value: number)
		label.Text = format(value)
	end)
	local rollTween: Tween? = nil
	if options.parent ~= nil then
		frame.Parent = options.parent
	end
	frame.Destroying:Once(function()
		roll:Destroy()
	end)
	return {
		frame = frame,
		label = label,
		setAmount = function(amount: number, animate: boolean?)
			if amount ~= amount then
				return -- NaN never reaches the label
			end
			local previous = current
			current = amount
			if rollTween ~= nil then
				rollTween:Cancel()
				rollTween = nil
			end
			if animate and amount > previous then
				local tween = TweenService:Create(
					roll,
					TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ Value = amount }
				)
				rollTween = tween
				tween:Play()
			else
				roll.Value = amount
				label.Text = format(amount)
			end
		end,
		amount = function(): number
			return current
		end,
		Destroy = function()
			frame:Destroy()
		end,
	}
end

-- ── Countdown ────────────────────────────────────────────────────────────────────────────────

export type CountdownFormat = "auto" | "hms" | "ms"

export type CountdownOptions = {
	endsAt: number, -- server unix time (seconds) the countdown reaches 0 (workspace:GetServerTimeNow())
	format: CountdownFormat?,
	prefix: string?, -- e.g. "Next FREE spin in "
	suffix: string?,
	doneText: string?, -- shown at 0 (default "00:00")
	textSize: number?,
	color: Color3?,
	size: UDim2?,
	layoutOrder: number?,
	parent: Instance?,
	onFinished: (() -> ())?,
}

export type Countdown = {
	label: TextLabel,
	setEndsAt: (endsAt: number) -> (),
	remaining: () -> number,
	Destroy: () -> (),
}

type Ticking = {
	label: TextLabel,
	endsAt: number,
	format: CountdownFormat,
	prefix: string,
	suffix: string,
	doneText: string,
	finished: boolean,
	onFinished: (() -> ())?,
}

-- Every live countdown (strong keys; ForgetOnDestroy drops destroyed labels).
local ticking: { [TextLabel]: Ticking } = {}
local tickingCount = 0
local tickerRunning = false
local tickTracker = ForgetOnDestroy.new(function(instance: Instance)
	local label = instance :: TextLabel
	if ticking[label] ~= nil then
		ticking[label] = nil
		tickingCount -= 1
	end
end)

--[[
	Formats `seconds` like the references: "02:59:11" (≥ 1 h), "04:11" (< 1 h), "1d 02:03:04".
	@param seconds remaining seconds (clamped to ≥ 0)
	@param format "auto" | "hms" | "ms"
	@return string
	Example: StudUI.formatClock(4 * 60 + 11, "auto") --> "04:11"
]]
function StudUI.formatClock(seconds: number, format: CountdownFormat?): string
	local s = math.max(0, math.floor(if seconds == seconds then seconds else 0))
	local days = s // 86400
	local hours = (s % 86400) // 3600
	local minutes = (s % 3600) // 60
	local secs = s % 60
	local mode = format or "auto"
	if days > 0 and mode ~= "ms" then
		return string.format("%dd %02d:%02d:%02d", days, hours, minutes, secs)
	end
	if mode == "hms" or (mode == "auto" and hours > 0) then
		return string.format("%02d:%02d:%02d", hours, minutes, secs)
	end
	return string.format("%02d:%02d", hours * 60 + minutes, secs)
end

-- True when `label` is in an enabled ScreenGui and visible up its chain (skip hidden labels).
local function shown(label: TextLabel): boolean
	local node: Instance? = label
	while node ~= nil do
		if node:IsA("GuiObject") then
			if not node.Visible then
				return false
			end
		elseif node:IsA("LayerCollector") then
			return node.Enabled
		end
		node = node.Parent
	end
	return false
end

-- Renders one countdown now.
local function renderTick(entry: Ticking, now: number)
	local left = entry.endsAt - now
	if left <= 0 then
		entry.label.Text = entry.prefix .. entry.doneText .. entry.suffix
		if not entry.finished then
			entry.finished = true
			local done = entry.onFinished
			if done ~= nil then
				task.spawn(done)
			end
		end
		return
	end
	entry.label.Text = entry.prefix .. StudUI.formatClock(left, entry.format) .. entry.suffix
end

-- The ONE shared ticker: wakes on whole server seconds while any countdown exists.
local function ensureTicker()
	if tickerRunning then
		return
	end
	tickerRunning = true
	task.spawn(function()
		while tickingCount > 0 do
			local now = Workspace:GetServerTimeNow()
			for label, entry in ticking do
				-- Hidden labels skip the text write but still fire onFinished on time.
				if shown(label) or (not entry.finished and entry.endsAt - now <= 0) then
					renderTick(entry, now)
				end
			end
			-- Sleep to the next whole second (labels flip together, no drift).
			task.wait(1 - (Workspace:GetServerTimeNow() % 1) + 0.01)
		end
		tickerRunning = false
	end)
end

--[[
	A live countdown label on the server clock (Workspace:GetServerTimeNow, so it matches the
	server's timers). All countdowns share ONE thread that wakes once per second and only writes
	labels that are on screen; onFinished fires once at 0 (the server still decides claims).
	@param options endsAt / format / prefix / suffix / doneText / callback
	@return Countdown handle
	Example: StudUI.countdown({ endsAt = nextSpinAt, prefix = "Next FREE spin in ", parent = top })
]]
function StudUI.countdown(options: CountdownOptions): Countdown
	local textSize = options.textSize or 40
	local label = StudUI.text({
		name = "Countdown",
		text = "",
		textSize = textSize,
		color = options.color,
		size = options.size or UDim2.new(1, 0, 0, textSize + 8),
		layoutOrder = options.layoutOrder,
		parent = options.parent,
	})
	local entry: Ticking = {
		label = label,
		endsAt = if options.endsAt == options.endsAt then options.endsAt else 0,
		format = options.format or "auto",
		prefix = options.prefix or "",
		suffix = options.suffix or "",
		doneText = options.doneText or "00:00",
		finished = false,
		onFinished = options.onFinished,
	}
	ticking[label] = entry
	tickingCount += 1
	tickTracker.track(label)
	renderTick(entry, Workspace:GetServerTimeNow())
	ensureTicker()
	return {
		label = label,
		setEndsAt = function(endsAt: number)
			if endsAt ~= endsAt then
				return
			end
			entry.endsAt = endsAt
			entry.finished = false
			renderTick(entry, Workspace:GetServerTimeNow())
			if ticking[label] == nil and label.Parent ~= nil then
				ticking[label] = entry
				tickingCount += 1
				tickTracker.track(label)
			end
			ensureTicker()
		end,
		remaining = function(): number
			return math.max(0, entry.endsAt - Workspace:GetServerTimeNow())
		end,
		Destroy = function()
			label:Destroy()
		end,
	}
end

--[[
	Keeps `frame` exactly as wide as its offset-sized `content` row plus `padding` (≤ `maxWidth`),
	in design px. Why not AutomaticSize: a stud surface has full-size (Scale 1) decoration
	children, and AutomaticSize on such a frame feeds back on itself and grows to its maximum.
	The row (AutomaticSize X, offset-only children) is measured instead, converted from absolute
	px back to design px with the frame's own height ratio (so AutoScale / UIScale never skew it).
	Event-driven: re-fits when the row or the frame's absolute size changes.
	@param frame      the decorated frame (Size.Y.Offset = its design height)
	@param content    the measured row inside it
	@param padding    extra design px (left + right)
	@param maxWidth   widest allowed (design px), or a getter for a cap that changes
	@return refit() — call it after changing the cap
	Example: StudUI.fitWidth(chip, row, 0, 760)
]]
function StudUI.fitWidth(
	frame: GuiObject,
	content: GuiObject,
	padding: number,
	maxWidth: number | () -> number
): () -> ()
	local function cap(): number
		return if type(maxWidth) == "function" then maxWidth() else maxWidth
	end
	local function update()
		local designHeight = frame.Size.Y.Offset
		local absoluteHeight = frame.AbsoluteSize.Y
		if designHeight <= 0 or absoluteHeight <= 0 then
			return
		end
		local perAbsolute = designHeight / absoluteHeight
		local width = math.ceil(math.min(cap(), content.AbsoluteSize.X * perAbsolute + padding))
		if math.abs(frame.Size.X.Offset - width) >= 1 or frame.Size.X.Scale ~= 0 then
			frame.Size = UDim2.fromOffset(width, designHeight)
		end
	end
	content:GetPropertyChangedSignal("AbsoluteSize"):Connect(update)
	frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(update)
	task.defer(update)
	return update
end

-- ── Toasts / progress ────────────────────────────────────────────────────────────────────────

export type ToastKind = "info" | "success" | "error" | "reward" | "purchase"

local TOAST_COLORS: { [ToastKind]: ColorName } = {
	info = "blue",
	success = "green",
	error = "red",
	reward = "yellow",
	purchase = "purple",
}
-- Widest a toast may get (design px).
local TOAST_MAX_WIDTH = 760
local TOAST_ICONS: { [ToastKind]: string } = {
	info = "Star",
	success = "Check",
	error = "Lock",
	reward = "Gift",
	purchase = "Robux",
}

--[[
	One notification chip: a coloured stud card with an icon and outlined text, as wide as its
	text up to 760 px (StudUI.fitWidth). The Toasts screen positions, stacks and expires them.
	@param options text / kind ("info" | "success" | "error" | "reward" | "purchase") / icon
	@return Frame
	Example: StudUI.toast({ text = "+$1.2K", kind = "reward" }).Parent = stack
]]
function StudUI.toast(options: { text: string, kind: ToastKind?, icon: string?, parent: Instance? }): Frame
	local kind: ToastKind = options.kind or "info"
	local height = Style.Hud.ToastHeight
	local frame = Create.new("Frame", {
		Name = "Toast",
		Size = UDim2.fromOffset(240, height),
	}) :: Frame
	StudWindow.surface(frame, TOAST_COLORS[kind] or "blue", {
		tile = Style.StudTile.Button,
		studTransparency = Style.StudTransparency.Button,
		edge = 4,
		corner = 8,
	})
	local row = Create.new("Frame", {
		Name = "Row",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(0, height),
		AutomaticSize = Enum.AutomaticSize.X,
		ZIndex = 2,
		Parent = frame,
		Children = {
			Create.new("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, 10),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			Create.new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 18) }),
		},
	}) :: Frame
	local icon = StudUI.icon(options.icon or TOAST_ICONS[kind] or "Star", math.floor(height * Style.IconFill.Toast), 3)
	icon.LayoutOrder = 1
	icon.Parent = row
	-- Measure the text (synchronous; Fredoka One = the label font). A message wider than the
	-- toast's cap keeps one line and scales its text down to fit instead of overflowing.
	local textSize = math.floor(height * 0.5)
	local maxText = TOAST_MAX_WIDTH - math.floor(height * Style.IconFill.Toast) - 10 - 28 - 6
	local measured = TextService:GetTextSize(options.text, textSize, Enum.Font.FredokaOne, Vector2.new(4096, 4096))
	StudUI.text({
		name = "Message",
		text = options.text,
		textSize = textSize,
		scaled = measured.X + 6 > maxText,
		size = UDim2.fromOffset(math.ceil(math.min(maxText, measured.X + 6)), height),
		zIndex = 3,
		layoutOrder = 2,
		parent = row,
	})
	StudUI.fitWidth(frame, row, 6, TOAST_MAX_WIDTH)
	if options.parent ~= nil then
		frame.Parent = options.parent
	end
	return frame
end

export type ProgressBar = {
	frame: Frame,
	setProgress: (fraction: number) -> (),
	Destroy: () -> (),
}

--[[
	A stud progress bar: dark well with a coloured stud fill (event-driven; set it on change).
	@param options colour / size
	@return ProgressBar handle
	Example: local bar = StudUI.progressBar({ color = "green", parent = billboard }); bar.setProgress(0.4)
]]
function StudUI.progressBar(
	options: { color: ColorName?, size: UDim2?, layoutOrder: number?, parent: Instance? }
): ProgressBar
	local frame = Create.new("Frame", {
		Name = "ProgressBar",
		Size = options.size or UDim2.fromOffset(300, 28),
		BackgroundColor3 = Neutral.Well,
		LayoutOrder = options.layoutOrder or 0,
		Children = { Create.new("UICorner", { CornerRadius = UDim.new(0, 6) }) },
	}) :: Frame
	StudWindow.edge(frame, 3)
	local fill = Create.new("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(0, 1),
		ZIndex = 2,
		Parent = frame,
	}) :: Frame
	StudWindow.surface(fill, options.color or "green", {
		tile = Style.StudTile.Button,
		studTransparency = Style.StudTransparency.Button,
		corner = 6,
	})
	if options.parent ~= nil then
		frame.Parent = options.parent
	end
	return {
		frame = frame,
		setProgress = function(fraction: number)
			local f = if fraction == fraction then math.clamp(fraction, 0, 1) else 0
			fill.Size = UDim2.fromScale(f, 1)
			fill.Visible = f > 0
		end,
		Destroy = function()
			frame:Destroy()
		end,
	}
end

return table.freeze(StudUI)
