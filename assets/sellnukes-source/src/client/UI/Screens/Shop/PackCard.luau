--!strict
--[[
	PackCard — the two big "- LIMITED TIME -" cards of the Shop (reference
	docs/reference/ui-style/02-shop-limited-time.png): the RED sunburst STARTER PACK and the
	WHITE / silver SECRET PACK with its red "Limited Stock" text and live stock line.

	"side" layout (wide enough for the tiles AND the button column):
		┌───────────────────────────────────────────────────────────────────────┐
		│ STARTER PACK                                        Limited Stock      │
		│                                                     123 / 500 left     │
		│  [cash]   [gems]   [spins]   [x2]    [pet]          ┌──────────────┐   │
		│  Big cash 100 Gems 5 Lucky   30 min  Golden Atom    │  (R) 99      │   │
		│  $50K               Spins    2x Cash Pup pet        └──────────────┘   │
		└───────────────────────────────────────────────────────────────────────┘
	"stacked" layout (narrow phones): the tiles take the full width and the button sits centred
	under them (the price, while locked, to its right).

		item tiles   one per ShopConfig.<Pack>.lines entry, each showing the item's REAL 3D model
		             (owner R39: a rotating, lit Widgets/ModelViewport — the reward pet is the
		             actual pet model; the icon stands in while a model loads); the cash tile
		             also shows the live cash preview (RewardPreview, same rule as the server grant)
		button       Robux price (buy) / OWNED / SOON / SOLD OUT; the price stays visible beside
		             a locked button

	Purpose:
		Both packs share the same layout and status handling; the Shop screen tells each card its
		width (setWidth -> height), status, cash preview and (Secret Pack only) stock line when
		they change.

	Readability (owner R11): tile captions never shrink below 18 design px; the Shop's content
	scale keeps that >= 14 pt on phones / tablets (Shop/ShopLayout).
	Owner R98 ("hard to see with the stud background"): every item sits on a soft dark plate
	in the card's shade with a glow ring + drop shadow, and its caption / cash value sit on dark
	name-plates with a thicker outline (Shop/ItemFx), so they read on the red AND white cards.

	Idle animation (owner R98 "the item in the shop should be animated"): the tiles bob and pulse,
	staggered, and rare items glint now and then — the pet tile of every pack, every tile of a
	`rare` pack (Secret Pack). One OfferFx animator per card (Shop/ItemFx.animate): on screen
	only, parked by Low graphics / Reduce Motion; the Shop switches it with open / close (`fx`).

	Performance: built ONCE; setters / setWidth only write properties. Model slots spin only while
	on screen, within ModelViewport's per-device live budget.

	Security: display only. The button calls the screen's `onBuy` (a PromptProduct intent); the
	server refuses bought-out / sold-out packs and validates every receipt.

	Connects to: Kit/StudUI (card, text, icon, button, robuxTag), UI/Create, Widgets/ModelViewport
	(item models), Shop/{ShopLogic, ShopModels (isRare), ItemFx (plates + idle motion)},
	Shared/Config/UIStyleConfig. Used by Shop/init (geometry also by Shop/ShopLayout).

	Example:
		local pack = PackCard.new({
			key = "StarterPack", title = "STARTER PACK", color = "red", sunburst = true,
			lines = ShopConfig.StarterPack.lines, icons = { "Cash", "Gems", "Spins", "x2Cash", "Pets" },
			models = ShopModels.packItems("StarterPack", ShopConfig.StarterPack, false),
			price = 99, limited = false, rare = false, layoutOrder = 1, parent = list,
			onBuy = function() Remotes.event("PromptProduct"):FireServer("StarterPack", "shop") end,
		})
		local height = pack.setWidth(1052)
		pack.setCashPreview("$50K")
		pack.setStatus("owned")
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Create = require(script.Parent.Parent.Parent.Create)
local ItemFx = require(script.Parent.ItemFx)
local ModelViewport = require(script.Parent.Parent.Parent.Widgets.ModelViewport)
local ShopLogic = require(script.Parent.ShopLogic)
local ShopModels = require(script.Parent.ShopModels)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

export type Options = {
	key: string, -- product key ("StarterPack" | "SecretPack")
	title: string, -- "STARTER PACK"
	color: StudUI.ColorName,
	sunburst: boolean,
	lines: { string }, -- ShopConfig.<Pack>.lines (one item tile each)
	icons: { string }, -- icon key per line (missing entries use "Gift"); the models' fallback
	models: { [number]: ModelViewport.Spec }?, -- 3D model per line (Shop/ShopModels.packItems)
	cashLine: number?, -- index of the tile that shows the live cash preview
	price: number, -- Robux (MonetizationConfig); labels show the LIVE price of `key` (UI/PriceBook)
	limited: boolean, -- true: "Limited Stock" + the stock line (Secret Pack)
	rare: boolean?, -- true: every tile glints (Secret Pack); pet / egg / crate tiles always do
	layoutOrder: number, -- also the card's animation seed (staggers it against other cards)
	parent: Instance,
	onBuy: () -> (),
}

export type Pack = {
	frame: Frame,
	button: StudUI.Button,
	-- The tiles' idle animation (Shop/ItemFx): the Shop switches it off on close / on on open.
	fx: ItemFx.Group,
	setStatus: (status: ShopLogic.Status) -> (),
	setCashPreview: (text: string?) -> (),
	setStock: (text: string) -> (),
	-- Re-captions item tile `index` (and swaps its icon / model when they differ) — e.g. the spins
	-- tile becomes "200 Gems" (gem model) where paid random items are restricted. No-op when
	-- unchanged.
	setItem: (index: number, caption: string, icon: string, model: ModelViewport.Spec?) -> (),
	-- Lays the card out for `width` design px (side / stacked); returns its height.
	setWidth: (width: number) -> number,
}

-- Pure geometry of a pack card at a given width (see PackCard.geometry).
export type Geometry = {
	stacked: boolean,
	tileWidth: number,
	icon: number,
	height: number,
}

local PackCard = {}

local TITLE_SIZE = 44
-- Top of the tiles row (under the title).
local ROW_Y = TITLE_SIZE + 14
local ROW_HEIGHT = 196
local TILE_MAX = 146
local TILE_MIN = 110 -- narrower tiles switch the card to the stacked layout
local TILE_GAP = 8
local TILE_ICON = 96
local BUTTON_SIZE = Vector2.new(240, 88)
-- Right-hand column reserved for the button (+ the stock text above it) in the side layout.
local RIGHT_COLUMN = 270
-- Card heights (design px) per layout. Stacked: tiles + gap + button + lip / edge + padding.
local SIDE_HEIGHT = 270
local STACKED_BUTTON_Y = ROW_Y + ROW_HEIGHT + 8
local STACKED_HEIGHT = STACKED_BUTTON_Y
	+ BUTTON_SIZE.Y
	+ UIStyleConfig.Button.Lip
	+ UIStyleConfig.Button.Edge
	+ 2 * UIStyleConfig.Card.Padding
local CARD_PADDING = UIStyleConfig.Card.Padding
local CASH_COLOR = UIStyleConfig.Neutral.CashGreen
local DANGER_COLOR = UIStyleConfig.Neutral.Danger

type Tile = {
	frame: Frame,
	slot: ItemFx.Slot, -- plate + float (positioned / sized like the old icon slot)
	icon: Frame, -- the item inside the slot's float (a ModelViewport frame, or a plain StudUI icon)
	view: ModelViewport.Viewport?,
	iconKey: string,
	caption: TextLabel,
	value: TextLabel,
}

-- Sets the smallest size a TextScaled label may shrink to (StudUI.text adds the constraint).
local function setMinTextSize(label: TextLabel, size: number)
	local constraint = label:FindFirstChildOfClass("UITextSizeConstraint")
	if constraint ~= nil then
		constraint.MinTextSize = size
	end
end

--[[
	Pure geometry of a pack card `width` design px wide with `count` item tiles: the side layout
	while every tile can be at least TILE_MIN wide next to the button column, else stacked.
	@param width card width (design px)
	@param count number of item tiles
	@return Geometry { stacked, tileWidth, icon, height }
	Example: PackCard.geometry(1052, 5).stacked --> false ; PackCard.geometry(700, 5).stacked --> true
]]
function PackCard.geometry(width: number, count: number): Geometry
	local n = math.max(1, count)
	local contentWidth = math.max(0, width - 2 * CARD_PADDING)
	local gaps = (n - 1) * TILE_GAP
	local sideTile = math.floor((contentWidth - RIGHT_COLUMN - gaps) / n)
	if sideTile >= TILE_MIN then
		local tile = math.min(TILE_MAX, sideTile)
		return { stacked = false, tileWidth = tile, icon = math.min(TILE_ICON, tile - 16), height = SIDE_HEIGHT }
	end
	local tile = math.clamp(math.floor((contentWidth - gaps) / n), 40, TILE_MAX)
	return { stacked = true, tileWidth = tile, icon = math.min(TILE_ICON, tile - 16), height = STACKED_HEIGHT }
end

--[[
	The item inside a tile's slot (filling its float, so it bobs over the plate): the 3D model
	(icon until it loads) when `model` is given, else the plain icon.
	@return (item frame, model viewport or nil)
]]
local function itemSlot(slot: ItemFx.Slot, icon: string, model: ModelViewport.Spec?): (Frame, ModelViewport.Viewport?)
	if model ~= nil then
		local view = ModelViewport.new({
			key = model.key,
			pet = model.pet,
			egg = model.egg,
			crate = model.crate,
			copies = model.copies,
			icon = icon,
			size = UDim2.fromScale(1, 1),
			position = UDim2.fromScale(0.5, 0.5),
			anchor = Vector2.new(0.5, 0.5),
			zIndex = 3,
			name = "Model",
			parent = slot.float,
		})
		return view.frame, view
	end
	local glyph = StudUI.icon(icon, TILE_ICON, 3)
	ItemFx.fill(glyph, slot)
	return glyph, nil
end

-- What itemTile needs to know about its card (plate shade, animation stagger, glints).
type TileLook = {
	color: StudUI.ColorName,
	seed: number,
	count: number,
	rare: boolean, -- the whole card glints (Secret Pack)
}

--[[
	Builds one item tile: the plated slot (Shop/ItemFx) holding the model / icon, caption (scaled
	to fit two lines, never below 18 px) and an optional small value line under it (the cash
	preview), both on dark name-plates. Positions are set by setWidth.
	@return Tile
]]
local function itemTile(
	parent: Instance,
	order: number,
	icon: string,
	caption: string,
	model: ModelViewport.Spec?,
	look: TileLook
): Tile
	local tile = Create.new("Frame", {
		Name = `Item{order}`,
		BackgroundTransparency = 1,
		Size = UDim2.new(0, TILE_MAX, 1, 0),
		LayoutOrder = order,
		Parent = parent,
	}) :: Frame
	local slot = ItemFx.slot({
		color = look.color,
		parent = tile,
		zIndex = 3,
		seed = look.seed,
		index = order,
		count = look.count,
		rare = look.rare or ShopModels.isRare(model),
	})
	slot.frame.AnchorPoint = Vector2.new(0.5, 0)
	slot.frame.Position = UDim2.new(0.5, 0, 0, 4)
	slot.frame.Size = UDim2.fromOffset(TILE_ICON, TILE_ICON)
	local glyph, view = itemSlot(slot, icon, model)
	local captionLabel = StudUI.text({
		name = "Caption",
		text = caption,
		textSize = 28,
		scaled = true,
		size = UDim2.new(1, 0, 0, 56),
		zIndex = 4,
		parent = tile,
	})
	setMinTextSize(captionLabel, 18)
	ItemFx.labelPlate(captionLabel, look.color)
	local value = StudUI.text({
		name = "Value",
		text = "",
		textSize = 26,
		font = "number",
		color = CASH_COLOR,
		scaled = true,
		size = UDim2.new(1, 0, 0, 30),
		zIndex = 4,
		parent = tile,
	})
	setMinTextSize(value, 20)
	ItemFx.labelPlate(value, look.color)
	value.Visible = false
	return {
		frame = tile,
		slot = slot,
		icon = glyph,
		view = view,
		iconKey = icon,
		caption = captionLabel,
		value = value,
	}
end

--[[
	Builds one big pack card (see the module header); call setWidth before showing it.
	@param options key / title / colour / sunburst / lines / icons / price / limited / onBuy
	@return Pack handle
	Example: see the module header
]]
function PackCard.new(options: Options): Pack
	local card = StudUI.card({
		name = `Pack_{options.key}`,
		color = options.color,
		sunburst = options.sunburst,
		size = UDim2.new(1, -8, 0, SIDE_HEIGHT),
		layoutOrder = options.layoutOrder,
		parent = options.parent,
	})
	local content = card.content

	-- Title, top-left like the reference.
	StudUI.text({
		name = "PackTitle",
		text = options.title,
		textSize = TITLE_SIZE,
		align = Enum.TextXAlignment.Left,
		size = UDim2.new(1, -RIGHT_COLUMN, 0, TITLE_SIZE + 8),
		position = UDim2.fromOffset(12, 2),
		zIndex = 4,
		parent = content,
	})

	-- Item tiles row (left of the button column, or full width when stacked).
	local row = Create.new("Frame", {
		Name = "Items",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, ROW_Y),
		Size = UDim2.new(1, -RIGHT_COLUMN, 0, ROW_HEIGHT),
		ZIndex = 3,
		Parent = content,
		Children = {
			Create.new("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				VerticalAlignment = Enum.VerticalAlignment.Top,
				Padding = UDim.new(0, TILE_GAP),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		},
	}) :: Frame
	local tiles: { Tile } = {}
	local slots: { ItemFx.Slot } = {}
	local cashValue: TextLabel? = nil
	local look: TileLook = {
		color = options.color,
		seed = options.layoutOrder,
		count = #options.lines,
		rare = options.rare == true,
	}
	for index, caption in options.lines do
		local models = options.models
		local model = if models ~= nil then models[index] else nil
		local tile = itemTile(row, index, options.icons[index] or "Gift", caption, model, look)
		table.insert(tiles, tile)
		table.insert(slots, tile.slot)
		if index == options.cashLine then
			cashValue = tile.value
		end
	end

	-- Secret Pack: red "Limited Stock" + the live stock line, top-right.
	local stockLabel: TextLabel? = nil
	if options.limited then
		StudUI.text({
			name = "LimitedStock",
			text = "Limited Stock",
			textSize = 38,
			color = DANGER_COLOR,
			align = Enum.TextXAlignment.Right,
			size = UDim2.fromOffset(RIGHT_COLUMN + 120, 44),
			position = UDim2.new(1, -12, 0, 2),
			anchor = Vector2.new(1, 0),
			zIndex = 4,
			parent = content,
		})
		stockLabel = StudUI.text({
			name = "StockLine",
			text = "Stock updating...",
			textSize = 26,
			align = Enum.TextXAlignment.Right,
			size = UDim2.fromOffset(RIGHT_COLUMN, 30),
			position = UDim2.new(1, -12, 0, 48),
			anchor = Vector2.new(1, 0),
			zIndex = 4,
			parent = content,
		})
	end

	local button = StudUI.button({
		name = "Buy",
		text = "", -- price-only: the Robux tag IS the label
		robux = options.price,
		productKey = options.key, -- the LIVE managed price wins over the configured one
		color = "green",
		textSize = 40,
		size = UDim2.fromOffset(BUTTON_SIZE.X, BUTTON_SIZE.Y),
		parent = content,
		onActivated = options.onBuy,
	})

	-- The price beside / under a locked button (SOON / SOLD OUT), so the card still shows it.
	local sidePrice = StudUI.robuxTag(options.price, 28, options.key) -- live price (PriceBook)
	sidePrice.ZIndex = 4
	sidePrice.Visible = false
	sidePrice.Parent = content

	-- Places the row, tiles, button and side price for `width` (see PackCard.geometry).
	local function setWidth(width: number): number
		local geo = PackCard.geometry(width, #tiles)
		card.frame.Size = UDim2.fromOffset(math.floor(width), geo.height)
		for _, tile in tiles do
			tile.frame.Size = UDim2.new(0, geo.tileWidth, 1, 0)
			tile.slot.frame.Size = UDim2.fromOffset(geo.icon, geo.icon)
			tile.caption.Position = UDim2.fromOffset(0, geo.icon + 10)
			-- 2 px under the caption plate, so the two name-plates read as separate pills.
			tile.value.Position = UDim2.fromOffset(0, geo.icon + 68)
		end
		local buttonRoot = button.instance
		if geo.stacked then
			row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
			buttonRoot.AnchorPoint = Vector2.new(0.5, 0)
			buttonRoot.Position = UDim2.new(0.5, 0, 0, STACKED_BUTTON_Y)
			sidePrice.AnchorPoint = Vector2.new(0, 0.5)
			sidePrice.Position = UDim2.new(0.5, BUTTON_SIZE.X / 2 + 16, 0, STACKED_BUTTON_Y + BUTTON_SIZE.Y / 2)
		else
			row.Size = UDim2.new(1, -RIGHT_COLUMN, 0, ROW_HEIGHT)
			buttonRoot.AnchorPoint = Vector2.new(1, 0.5)
			buttonRoot.Position = UDim2.new(1, -14, 0.5, 22)
			sidePrice.AnchorPoint = Vector2.new(0.5, 1)
			sidePrice.Position = UDim2.new(1, -(14 + BUTTON_SIZE.X / 2), 1, -2)
		end
		return geo.height
	end
	setWidth(1052)

	return {
		frame = card.frame,
		button = button,
		fx = ItemFx.animate(card.frame, slots),
		setStatus = function(status: ShopLogic.Status)
			local state, text = ShopLogic.buttonLook(status)
			button.setState(state, text)
			sidePrice.Visible = ShopLogic.showsSidePrice(status)
		end,
		setCashPreview = function(text: string?)
			local label = cashValue
			if label == nil then
				return
			end
			label.Visible = text ~= nil
			if text ~= nil then
				label.Text = text
			end
		end,
		setStock = function(text: string)
			local label = stockLabel
			if label ~= nil then
				label.Text = text
			end
		end,
		setItem = function(index: number, caption: string, icon: string, model: ModelViewport.Spec?)
			local tile = tiles[index]
			if tile == nil then
				return
			end
			if tile.caption.Text ~= caption then
				tile.caption.Text = caption
			end
			local view = tile.view
			if view ~= nil then
				-- Model slot: swap the model / fallback icon in place (no-op when unchanged).
				view.set(model, icon)
				tile.iconKey = icon
			elseif tile.iconKey ~= icon or model ~= nil then
				-- Rare (policy change): rebuild just the item inside the same plated slot.
				tile.icon:Destroy()
				local glyph, newView = itemSlot(tile.slot, icon, model)
				tile.icon = glyph
				tile.view = newView
				tile.iconKey = icon
			end
		end,
		setWidth = setWidth,
	}
end

return table.freeze(PackCard)
