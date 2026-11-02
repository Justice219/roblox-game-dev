--!strict
--[[
	ShopCard — one grid card of the Shop window (game passes, cash / gem / spin packs, boosts):
	a coloured stud card in its section's colour with the item's name, its REAL 3D model (owner
	R39: a rotating, lit Widgets/ModelViewport; the icon stands in while it loads), an optional
	preview line ("$1.25K", "+350 Gems", or a live "ACTIVE 12:34" boost countdown), a short
	description (or the pass's first two perks) and the green Robux price button.

	Two layouts of the SAME instances (setLayout; the Shop picks one per screen size):

		"tall" (desktop / console / tablet)          "wide" (phones: short windows)
		┌────────────────┐                           ┌──────────────────────────────────┐
		│ BEST  Bag of   │ name                      │ BEST     Bag of Cash             │
		│     [ icon ]   │ icon (+ badge ribbon)     │ [icon]   $1.25K                  │
		│     $1.25K     │ preview / countdown       │          30 minutes of your      │
		│ 30 minutes of  │ lines                     │          income, instantly.      │
		│  your income   │ side price (locked only)  │ (R) 79           [ (R) 79      ] │
		│ [ (R) 79     ] │ button                    └──────────────────────────────────┘
		└────────────────┘
		248 x 350 design px                           440..560 x 200 design px

		badge      optional yellow ribbon ("BEST VALUE", "POPULAR")
		preview    cash preview / amount; a boost's "ACTIVE 12:34" countdown replaces it
		side price the Robux price, ONLY while the button is locked (SOON / SOLD OUT / ...)
		button     price (buy) / OWNED / SOON / SOLD OUT / UNAVAILABLE

	Readability (owner R11, phones / tablets): the smallest text a card can shrink to is
	ShopCard.MinTextSize design px and the button is ShopCard.ButtonHeight tall; the Shop scales
	the whole card list so both stay >= 14 pt / 44 pt on the device (Shop/ShopLayout).
	Owner R98 ("hard to see with the stud background"): the item sits on a soft dark plate in
	the card's shade (glow ring + drop shadow), and the preview + description sit on one dark
	rounded InfoPlate (it starts at the description while there is no preview line), so text
	reads on every section colour (Shop/ItemFx).

	Idle animation (owner R98): the item bobs and pulses (staggered between cards by `seed`);
	rare items (pets / eggs / crates: ShopModels.isRare, or `rare`) glint now and then. One
	OfferFx animator per card, on screen only, parked by Low graphics / Reduce Motion; the Shop
	switches it with open / close (`fx`).

	Performance: every Instance is built ONCE; setters and setLayout only write properties. The
	countdown exists only on boost cards (`countdown = true`) and uses StudUI's shared 1 Hz ticker,
	which skips hidden labels. The model slot spins only while on screen, within ModelViewport's
	per-device live budget (still frames otherwise).

	Security: display only. The button calls the screen's `onBuy`, which fires a PromptProduct /
	PromptPass intent; MonetizationService validates every prompt and grant server-side.

	Connects to: Kit/StudUI (card, text, icon, button, robuxTag, countdown), Widgets/ModelViewport
	(the 3D model slot), Shop/{ShopLogic (Status, button looks), ShopModels (isRare), ItemFx (plates
	+ idle motion)}, Shared/Config/UIStyleConfig. Used by Shop/init and Shop/ShopLayout.

	Example:
		local card = ShopCard.new({
			key = "CashMedium", name = "Bag of Cash", icon = "cash", price = 79,
			model = { key = "Shop_MoneyBag" }, -- Shop/ShopModels.forProduct(def)
			lines = { "30 minutes of your income, instantly." }, color = "green",
			layoutOrder = 2, parent = grid,
			onBuy = function() Remotes.event("PromptProduct"):FireServer("CashMedium", "shop") end,
		})
		card.setPreview("$12.5K", UIStyleConfig.Neutral.CashGreen)
		card.setStatus("buy")
		card.setLayout("wide")
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemFx = require(script.Parent.ItemFx)
local ModelViewport = require(script.Parent.Parent.Parent.Widgets.ModelViewport)
local ShopLogic = require(script.Parent.ShopLogic)
local ShopModels = require(script.Parent.ShopModels)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

export type CardLayout = "tall" | "wide"

export type Options = {
	key: string, -- product / pass key (names the card; analytics id)
	name: string, -- display name
	icon: string, -- icon key (ShopLogic.iconFor); the model's loading fallback
	model: ModelViewport.Spec?, -- the 3D model (Shop/ShopModels); nil = the icon only
	price: number, -- Robux (MonetizationConfig); labels show the LIVE price of `key` (UI/PriceBook)
	lines: { string }, -- description / perks (joined with line breaks)
	badge: string?, -- optional ribbon ("BEST VALUE")
	color: StudUI.ColorName,
	countdown: boolean?, -- true: boost card with a live "ACTIVE 12:34" line
	rare: boolean?, -- true: the item glints (pets / eggs / crates glint anyway: ShopModels.isRare)
	seed: number?, -- animation stagger seed (default layoutOrder; the Shop passes a running count)
	layoutOrder: number,
	parent: Instance,
	onBuy: () -> (),
}

export type Card = {
	frame: Frame,
	button: StudUI.Button,
	-- The item's idle animation (Shop/ItemFx): the Shop switches it off on close / on on open.
	fx: ItemFx.Group,
	-- The preview line (nil hides it). Hidden while a boost countdown is active.
	setPreview: (text: string?, color: Color3?) -> (),
	-- Boost cards: show "ACTIVE 12:34" until `endsAt` (server unix s); nil hides it.
	setActiveUntil: (endsAt: number?) -> (),
	setStatus: (status: ShopLogic.Status) -> (),
	-- Re-arranges the card's instances for a layout (the grid sets the cell size).
	setLayout: (layout: CardLayout) -> (),
}

local ShopCard = {}

-- "tall" card size (design px). Four cards + three gaps fit the 1100 px Shop window's body.
ShopCard.Width = 248
ShopCard.Height = 350
-- "wide" card size: height fixed, width stretched between these to fill the row.
ShopCard.WideMinWidth = 440
ShopCard.WideMaxWidth = 560
ShopCard.WideHeight = 200
ShopCard.Gap = 14
-- Readability floor (design px, before the Shop's content scale): the smallest any card text
-- may shrink to, and the buy button's height (the smallest tap target).
ShopCard.MinTextSize = 18
ShopCard.ButtonHeight = 52

-- Under the button: its 3D lip (Button.Lip) + dark outline (Button.Edge) must stay inside.
local BUTTON_BOTTOM_GAP = UIStyleConfig.Button.Lip + UIStyleConfig.Button.Edge
local WIDE_BUTTON_WIDTH = 200
-- Left column of the wide layout (icon) and where its text column starts.
local WIDE_ICON = 96
local WIDE_TEXT_X = 110
local TALL_ICON = 84
local PRICE_TEXT = 22
local ACTIVE_COLOR = UIStyleConfig.Colors.green.accent
local BADGE_COLOR = UIStyleConfig.Colors.yellow.top
-- InfoPlate (preview + description backing), design px inside the content: its top with / without
-- a preview line and its bottom, per layout (2 px around the labels it backs).
local TALL_INFO_TOP = 122
local TALL_INFO_TOP_NO_PREVIEW = 156
local TALL_INFO_BOTTOM = 238
local WIDE_INFO_TOP = 30
local WIDE_INFO_TOP_NO_PREVIEW = 60
local WIDE_INFO_BOTTOM = 122
local WIDE_INFO_X = WIDE_TEXT_X - 6

-- Sets the smallest size a TextScaled label may shrink to (StudUI.text adds the constraint).
local function setMinTextSize(label: TextLabel, size: number)
	local constraint = label:FindFirstChildOfClass("UITextSizeConstraint")
	if constraint ~= nil then
		constraint.MinTextSize = size
	end
end

--[[
	Builds one grid card (see the module header for the slots); starts in the "tall" layout.
	@param options key / name / icon / price / lines / badge / colour / countdown / onBuy
	@return Card handle (setters only write properties)
	Example: see the module header
]]
function ShopCard.new(options: Options): Card
	local card = StudUI.card({
		name = `Card_{options.key}`,
		color = options.color,
		size = UDim2.fromOffset(ShopCard.Width, ShopCard.Height),
		layoutOrder = options.layoutOrder,
		parent = options.parent,
	})
	local content = card.content

	-- Name: scaled so long names ("2x Cash (30 min)") still fit on one line.
	local nameLabel = StudUI.text({
		name = "ItemName",
		text = options.name,
		textSize = 30,
		scaled = true,
		zIndex = 4,
		parent = content,
	})
	setMinTextSize(nameLabel, 20)

	-- The item slot (Shop/ItemFx): plate + glow ring + shadow, and the float that bobs, holding
	-- the rotating 3D model (icon until it loads) or just the icon. `icon` (the slot holder) is
	-- what the layouts place.
	local slot = ItemFx.slot({
		color = options.color,
		parent = content,
		zIndex = 3,
		seed = options.seed or options.layoutOrder,
		index = 1,
		count = 1,
		rare = options.rare == true or ShopModels.isRare(options.model),
	})
	local icon: Frame = slot.frame
	icon.Size = UDim2.fromOffset(TALL_ICON, TALL_ICON)
	if options.model ~= nil then
		local spec = options.model
		ModelViewport.new({
			key = spec.key,
			pet = spec.pet,
			egg = spec.egg,
			crate = spec.crate,
			copies = spec.copies,
			icon = options.icon,
			size = UDim2.fromScale(1, 1),
			position = UDim2.fromScale(0.5, 0.5),
			anchor = Vector2.new(0.5, 0.5),
			zIndex = 3,
			name = "Model",
			parent = slot.float,
		})
	else
		ItemFx.fill(StudUI.icon(options.icon, TALL_ICON, 3), slot)
	end
	-- One dark plate behind the preview line + description (placed by placeInfoPlate).
	local infoPlate = ItemFx.panel(content, options.color, 3, "InfoPlate")

	local badge: TextLabel? = nil
	if options.badge ~= nil and options.badge ~= "" then
		-- A tilted yellow ribbon over the icon's shoulder (decorative only).
		local ribbon = StudUI.text({
			name = "Badge",
			text = options.badge,
			textSize = 20,
			font = "shout",
			color = BADGE_COLOR,
			align = Enum.TextXAlignment.Left,
			size = UDim2.fromOffset(120, 24),
			zIndex = 5,
			parent = content,
		})
		ribbon.Rotation = -10
		badge = ribbon
	end

	local preview = StudUI.text({
		name = "Preview",
		text = "",
		textSize = 30,
		font = "number",
		scaled = true,
		zIndex = 4,
		parent = content,
	})
	setMinTextSize(preview, 22)
	preview.Visible = false

	local linesLabel = StudUI.text({
		name = "Lines",
		text = table.concat(options.lines, "\n"),
		textSize = 20,
		font = "body",
		scaled = true,
		alignY = Enum.TextYAlignment.Top,
		zIndex = 4,
		parent = content,
	})
	setMinTextSize(linesLabel, ShopCard.MinTextSize)

	-- The price stays readable while the button says SOON / SOLD OUT / UNAVAILABLE.
	local sidePrice = StudUI.robuxTag(options.price, PRICE_TEXT, options.key) -- live price (PriceBook)
	sidePrice.ZIndex = 4
	sidePrice.Visible = false
	sidePrice.Parent = content

	local button = StudUI.button({
		name = "Buy",
		text = "", -- price-only: the Robux tag IS the label
		robux = options.price,
		productKey = options.key, -- the LIVE managed price wins over the configured one
		color = "green",
		textSize = 28,
		size = UDim2.new(1, -8, 0, ShopCard.ButtonHeight),
		parent = content,
		onActivated = options.onBuy,
	})

	-- Boost cards: one countdown label sharing the preview slot (hidden while inactive).
	local countdown: StudUI.Countdown? = nil
	local activeUntil: number? = nil
	local previewText: string? = nil
	local currentLayout: CardLayout = "tall"

	-- Fits the InfoPlate to the labels it backs: from the preview line (or, with no preview /
	-- countdown showing, from the description) down to the description's bottom.
	local function placeInfoPlate()
		local hasLine = activeUntil ~= nil or previewText ~= nil
		if currentLayout == "tall" then
			local top = if hasLine then TALL_INFO_TOP else TALL_INFO_TOP_NO_PREVIEW
			infoPlate.Position = UDim2.fromOffset(0, top)
			infoPlate.Size = UDim2.new(1, 0, 0, TALL_INFO_BOTTOM - top)
		else
			local top = if hasLine then WIDE_INFO_TOP else WIDE_INFO_TOP_NO_PREVIEW
			infoPlate.Position = UDim2.fromOffset(WIDE_INFO_X, top)
			infoPlate.Size = UDim2.new(1, -WIDE_INFO_X, 0, WIDE_INFO_BOTTOM - top)
		end
	end

	-- Shows the countdown when a boost is active, else the preview line (single writer).
	local function renderLine()
		local active = activeUntil ~= nil
		local live = countdown
		if live ~= nil then
			live.label.Visible = active
		end
		preview.Visible = not active and previewText ~= nil
		placeInfoPlate()
	end

	if options.countdown == true then
		local built = StudUI.countdown({
			endsAt = 0,
			prefix = "ACTIVE ",
			doneText = "",
			textSize = 28,
			color = ACTIVE_COLOR,
			parent = content,
			onFinished = function()
				-- The boost ran out on the server clock: hide the line (the profile push that
				-- prunes the boost arrives a few seconds later and agrees).
				activeUntil = nil
				renderLine()
			end,
		})
		built.label.ZIndex = 4
		built.label.Visible = false
		countdown = built
	end

	--[[
		Places every slot for `layout` (design px inside the card's padded content).
		tall: a centred column; wide: icon left, text column right, button bottom-right.
	]]
	local function applyLayout(layout: CardLayout)
		local live = countdown
		currentLayout = layout
		if layout == "tall" then
			nameLabel.TextXAlignment = Enum.TextXAlignment.Center
			nameLabel.Position = UDim2.fromOffset(0, 0)
			nameLabel.Size = UDim2.new(1, 0, 0, 36)
			icon.AnchorPoint = Vector2.new(0.5, 0)
			icon.Position = UDim2.new(0.5, 0, 0, 38)
			icon.Size = UDim2.fromOffset(TALL_ICON, TALL_ICON)
			preview.TextXAlignment = Enum.TextXAlignment.Center
			preview.Position = UDim2.fromOffset(0, 124)
			preview.Size = UDim2.new(1, 0, 0, 32)
			linesLabel.TextXAlignment = Enum.TextXAlignment.Center
			linesLabel.Position = UDim2.fromOffset(2, 158)
			linesLabel.Size = UDim2.new(1, -4, 0, 78)
			sidePrice.AnchorPoint = Vector2.new(0.5, 0)
			sidePrice.Position = UDim2.new(0.5, 0, 0, 240)
			button.instance.AnchorPoint = Vector2.new(0.5, 1)
			button.instance.Position = UDim2.new(0.5, 0, 1, -BUTTON_BOTTOM_GAP)
			button.instance.Size = UDim2.new(1, -8, 0, ShopCard.ButtonHeight)
		else
			nameLabel.TextXAlignment = Enum.TextXAlignment.Left
			nameLabel.Position = UDim2.fromOffset(WIDE_TEXT_X, 0)
			nameLabel.Size = UDim2.new(1, -WIDE_TEXT_X, 0, 32)
			icon.AnchorPoint = Vector2.new(0, 0)
			icon.Position = UDim2.fromOffset(4, 28)
			icon.Size = UDim2.fromOffset(WIDE_ICON, WIDE_ICON)
			preview.TextXAlignment = Enum.TextXAlignment.Left
			preview.Position = UDim2.fromOffset(WIDE_TEXT_X, 32)
			preview.Size = UDim2.new(1, -WIDE_TEXT_X, 0, 28)
			linesLabel.TextXAlignment = Enum.TextXAlignment.Left
			linesLabel.Position = UDim2.fromOffset(WIDE_TEXT_X, 62)
			linesLabel.Size = UDim2.new(1, -(WIDE_TEXT_X + 4), 0, 60)
			-- Price left of the button, on the button's centre line.
			sidePrice.AnchorPoint = Vector2.new(0, 0.5)
			sidePrice.Position = UDim2.new(0, WIDE_TEXT_X, 1, -(BUTTON_BOTTOM_GAP + ShopCard.ButtonHeight / 2))
			button.instance.AnchorPoint = Vector2.new(1, 1)
			button.instance.Position = UDim2.new(1, 0, 1, -BUTTON_BOTTOM_GAP)
			button.instance.Size = UDim2.fromOffset(WIDE_BUTTON_WIDTH, ShopCard.ButtonHeight)
		end
		local ribbon = badge
		if ribbon ~= nil then
			ribbon.Position = if layout == "tall" then UDim2.fromOffset(-4, 40) else UDim2.fromOffset(-4, 6)
		end
		if live ~= nil then
			-- The countdown shares the preview slot.
			live.label.TextXAlignment = preview.TextXAlignment
			live.label.Position = preview.Position
			live.label.Size = preview.Size
		end
		placeInfoPlate()
	end
	applyLayout("tall")

	return {
		frame = card.frame,
		button = button,
		fx = ItemFx.animate(card.frame, { slot }),
		setPreview = function(text: string?, color: Color3?)
			previewText = text
			if text ~= nil then
				preview.Text = text
				preview.TextColor3 = color or UIStyleConfig.Neutral.Text
			end
			renderLine()
		end,
		setActiveUntil = function(endsAt: number?)
			local live = countdown
			if live == nil then
				return
			end
			if endsAt ~= nil and endsAt == endsAt then
				activeUntil = endsAt
				live.setEndsAt(endsAt)
			else
				activeUntil = nil
			end
			renderLine()
		end,
		setStatus = function(status: ShopLogic.Status)
			local state, text = ShopLogic.buttonLook(status)
			button.setState(state, text)
			sidePrice.Visible = ShopLogic.showsSidePrice(status)
		end,
		setLayout = applyLayout,
	}
end

return table.freeze(ShopCard)
