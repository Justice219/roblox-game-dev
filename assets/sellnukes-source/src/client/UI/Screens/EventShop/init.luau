--!strict
--[[
	EventShop — the HARVEST SHOP (screen "EventShop"): spend acorns from Golden Turkeys on Harvest
	Eggs, plot decorations and boosts; buy acorn packs / a Turkey Lure with Robux. Opened from the
	sticker sheet's HARVEST SHOP button.

	Sections (scrolling stud window, top to bottom):
		header        acorn balance + "ends in" countdown
		GET ACORNS    Acorn Basket / Acorn Wagon / Golden Turkey Lure (MonetizationConfig products;
		              PromptProduct intent with source "event"; COMING SOON while the id is 0).
		              The lure is a PAID RANDOM item (its guaranteed Feast Sticker roll): where the
		              region restricts them (EggConfig.policyState(profile.policy)) its button is
		              locked "UNAVAILABLE" and its card says why (EventConfig.LurePolicyText); the
		              server refuses the prompt anyway (fail closed).
		HARVEST EGG   B9's acorn egg (EggConfig.Eggs.harvest_egg): HATCH opens B9's EggHatch window
		              for it (odds, pity, x3 / auto, the reveal); COMING SOON until EggConfig has it
		DECORATIONS   EventConfig.Decor cards: BUY → EventShopBuy(key) → the server spends acorns and
		              builds it on your plot with the LEGO build-in. OWNED once bought.
		BOOSTS        EventConfig.Boosts cards (2x cash / 2x speed for acorns) → EventShopBuy(key)

	Rules: display only, intents only — every price, balance and ownership check is re-done by the
	server. Unaffordable rows show their price dimmed (disabled); everything locks "CLOSED" when the
	event is not running. Fully gamepad / touch navigable (owner R11): every buy button is
	selectable, the default selection is the first enabled ACORN item (owner R122: never a Robux
	acorn pack — those are tagged BUYs behind UI/PurchaseGuard, and the press that opened the shop
	never buys), B / the red X close.

	Connects to: Client/Event/EventView, Kit/StudUI, Shared/Config/{EventConfig,MonetizationConfig},
	B9 Shared/Config/EggConfig (optional), Shared/Net/Remotes (EventShopBuy, PromptProduct), B9 Screens/EggHatch.

	Example: ScreenManager.open("EventShop")
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.Create)
-- EggConfig.policyState: the shared reader of profile.policy (allowed / restricted / checking).
local EggConfig = require(ReplicatedStorage.Shared.Config.EggConfig)
local EventConfig = require(ReplicatedStorage.Shared.Config.EventConfig)
local EventView = require(script.Parent.Parent.Parent.Event.EventView)
local GamepadNav = require(script.Parent.Parent.Parent.Platform.GamepadNav)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
-- Owner R122 purchase-focus hygiene (opening-press guard, BUY tags, safe default selection).
local PurchaseGuard = require(script.Parent.Parent.PurchaseGuard)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local NAME = "EventShop"
local PRODUCT_KEYS = { "AcornsSmall", "AcornsLarge", "TurkeyLure" }
local CARD_HEIGHT = 300
local ACORN_COLOR = Color3.fromRGB(255, 196, 92)

-- One acorn-priced buy row (decor / boost / egg).
type AcornRow = {
	key: string,
	kind: "decor" | "boost" | "egg",
	price: number,
	button: StudUI.Button,
}

-- One Robux product row (description: the card's text, swapped for the region note when a
-- paid random product is restricted).
type ProductRow = { key: string, button: StudUI.Button, description: TextLabel?, text: string }

-- B9's Harvest Egg: { price, name } from EggConfig when it exists (nil = not built yet).
local function harvestEgg(): { price: number, name: string }?
	local module = ReplicatedStorage.Shared.Config:FindFirstChild("EggConfig")
	if module == nil or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, config = pcall(require, module)
	if not ok or type(config) ~= "table" or type(config.Eggs) ~= "table" then
		return nil
	end
	local egg = config.Eggs[EventConfig.HarvestEggId]
	if type(egg) ~= "table" then
		return nil
	end
	local price = egg.price or egg.cost
	if type(price) ~= "number" or price ~= price or price <= 0 then
		return nil
	end
	return { price = price, name = if type(egg.name) == "string" then egg.name else "Harvest Egg" }
end

return StudUI.modalScreen({
	name = NAME,
	title = "Harvest Shop",
	color = "orange",
	icon = "Acorn",
	size = Vector2.new(1120, 860),
	scroll = true,
	build = function(window: StudUI.Window): ScreenManager.ScreenHandle?
		local body = window.body
		Create.new("UIListLayout", {
			Padding = UDim.new(0, 12),
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = body,
		})
		Create.new("UIPadding", {
			PaddingTop = UDim.new(0, 8),
			PaddingBottom = UDim.new(0, 16),
			Parent = body,
		})

		local order = 0
		local function nextOrder(): number
			order += 1
			return order
		end

		-- ── Header ────────────────────────────────────────────────────────────────────────
		local header = Create.new("Frame", {
			Name = "Header",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, -24, 0, 84),
			LayoutOrder = nextOrder(),
			Parent = body,
		}) :: Frame
		local acornIcon = StudUI.icon("Acorn", 72, 3)
		acornIcon.Parent = header
		local balance = StudUI.text({
			text = "0",
			textSize = 52,
			font = "number",
			color = ACORN_COLOR,
			align = Enum.TextXAlignment.Left,
			position = UDim2.fromOffset(82, 4),
			size = UDim2.fromOffset(300, 58),
			parent = header,
		})
		StudUI.text({
			text = "ACORNS",
			textSize = 20,
			color = UIStyleConfig.Neutral.TextDim,
			align = Enum.TextXAlignment.Left,
			position = UDim2.fromOffset(84, 58),
			size = UDim2.fromOffset(200, 24),
			parent = header,
		})
		local status = StudUI.text({
			text = "",
			textSize = 24,
			color = UIStyleConfig.Neutral.TextDim,
			align = Enum.TextXAlignment.Right,
			position = UDim2.new(1, 0, 0, 2),
			anchor = Vector2.new(1, 0),
			size = UDim2.fromOffset(460, 28),
			parent = header,
		})
		local countdown = StudUI.countdown({
			endsAt = EventConfig.Season.ends,
			format = "auto",
			textSize = 36,
			color = Color3.fromRGB(255, 226, 80),
			size = UDim2.fromOffset(460, 44),
			parent = header,
		})
		countdown.label.AnchorPoint = Vector2.new(1, 0)
		countdown.label.Position = UDim2.new(1, 0, 0, 32)
		countdown.label.TextXAlignment = Enum.TextXAlignment.Right

		-- A section title + a 3-column card row container.
		local function section(title: string, rows: number): Frame
			local label = StudUI.sectionLabel(title, 40)
			label.LayoutOrder = nextOrder()
			label.Parent = body
			local container = Create.new("Frame", {
				Name = `Section_{title}`,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, -24, 0, rows * CARD_HEIGHT + (rows - 1) * 12),
				LayoutOrder = nextOrder(),
				Parent = body,
				Children = {
					Create.new("UIGridLayout", {
						CellPadding = UDim2.fromOffset(12, 12),
						CellSize = UDim2.new(1 / 3, -8, 0, CARD_HEIGHT),
						SortOrder = Enum.SortOrder.LayoutOrder,
						HorizontalAlignment = Enum.HorizontalAlignment.Center,
					}),
				},
			}) :: Frame
			return container
		end

		-- One shop card: icon, name, description, button (returned for wiring).
		local function shopCard(
			parent: Frame,
			layoutOrder: number,
			color: StudUI.ColorName,
			icon: string,
			title: string,
			description: string,
			button: StudUI.ButtonOptions
		): StudUI.Button
			local card = StudUI.card({
				color = color,
				sunburst = true,
				title = title,
				titleSize = 30,
				layoutOrder = layoutOrder,
				parent = parent,
			})
			local iconFrame = StudUI.icon(icon, 96, 4)
			iconFrame.AnchorPoint = Vector2.new(0.5, 0)
			iconFrame.Position = UDim2.new(0.5, 0, 0, 40)
			iconFrame.Parent = card.content
			StudUI.text({
				name = "Description",
				text = description,
				textSize = 20,
				wrap = true,
				position = UDim2.fromOffset(4, 140),
				size = UDim2.new(1, -8, 0, 52),
				parent = card.content,
			})
			button.size = UDim2.new(1, -16, 0, 74) -- >= 44 pt on phones after ModalShell scaling
			button.position = UDim2.new(0.5, 0, 1, -6)
			button.anchor = Vector2.new(0.5, 1)
			button.parent = card.content
			return StudUI.button(button)
		end

		-- Buttons per section, in order (gamepad grid links, see the end of build).
		local sectionCells: { { GuiObject } } = {}

		-- ── Get acorns (Robux) ────────────────────────────────────────────────────────────
		local productRows: { ProductRow } = {}
		local products = section("Get Acorns", 1)
		local productCells: { GuiObject } = {}
		table.insert(sectionCells, productCells)
		for index, key in PRODUCT_KEYS do
			local def = MonetizationConfig.getProduct(key)
			if def == nil then
				continue
			end
			local productKey = key
			local button = shopCard(products, index, "green", def.icon, def.name, def.description, {
				text = "",
				productKey = key, -- live managed price (PriceBook)
				color = "green",
				-- R122: the press that opened the Event Shop never buys (PurchaseGuard).
				onActivated = PurchaseGuard.gate(NAME, function()
					Remotes.event("PromptProduct"):FireServer(productKey, "event")
				end),
			})
			PurchaseGuard.markBuy(button.instance)
			local descriptionLabel = (button.instance.Parent :: Instance):FindFirstChild("Description")
			table.insert(productRows, {
				key = key,
				button = button,
				description = if descriptionLabel ~= nil and descriptionLabel:IsA("TextLabel")
					then descriptionLabel
					else nil,
				text = def.description,
			})
			table.insert(productCells, button.instance)
		end

		local acornRows: { AcornRow } = {}

		-- ── Harvest Egg (B9) ──────────────────────────────────────────────────────────────
		local eggs = section("Harvest Egg", 1)
		local egg = harvestEgg()
		local eggButton = shopCard(
			eggs,
			1,
			"purple",
			"HarvestEgg",
			if egg ~= nil then egg.name else "Harvest Egg",
			"Hatch cozy harvest pets with your acorns!",
			{
				text = "HATCH",
				color = "yellow",
				onActivated = function()
					-- B9's egg window (odds, pity, x3, auto) owns hatching + its request ids.
					ScreenManager.open("EggHatch", { eggId = EventConfig.HarvestEggId })
				end,
			}
		)
		local eggRow: AcornRow = {
			key = EventConfig.HarvestEggId,
			kind = "egg",
			price = if egg ~= nil then egg.price else 0,
			button = eggButton,
		}
		table.insert(acornRows, eggRow)
		local eggCells: { GuiObject } = { eggButton.instance }
		table.insert(sectionCells, eggCells)

		-- ── Decorations + boosts (acorns) ─────────────────────────────────────────────────
		local function acornSection(title: string, kind: "decor" | "boost", color: StudUI.ColorName)
			local items: { EventConfig.ShopItem } = {}
			for _, item in EventConfig.Shop do
				if item.kind == kind then
					table.insert(items, item)
				end
			end
			local container = section(title, math.ceil(#items / 3))
			local cells: { GuiObject } = {}
			table.insert(sectionCells, cells)
			for index, item in items do
				local itemKey = item.key
				local button = shopCard(container, index, color, item.icon, item.name, item.description, {
					text = NumberFormat.commas(item.price),
					icon = "Acorn",
					color = "yellow",
					onActivated = function()
						Remotes.event("EventShopBuy"):FireServer(itemKey)
					end,
				})
				local row: AcornRow = { key = item.key, kind = kind, price = item.price, button = button }
				table.insert(acornRows, row)
				table.insert(cells, button.instance)
			end
		end
		acornSection("Decorations", "decor", "orange")
		acornSection("Boosts", "boost", "blue")

		-- Gamepad (owner R11): each section is a 3-column grid; its top / bottom edges exit to the
		-- neighbouring sections; the scrolling body follows the cursor.
		for index, cells in sectionCells do
			local above = sectionCells[index - 1]
			local below = sectionCells[index + 1]
			GamepadNav.linkGrid(cells, 3, {
				wrapH = true,
				up = if above ~= nil then above[1] else nil,
				down = if below ~= nil then below[1] else nil,
			})
		end
		if window.body:IsA("ScrollingFrame") then
			GamepadNav.followScroll(window.body)
		end

		-- Re-renders balances and every button state from server data.
		local function render()
			local acorns = EventView.acorns()
			local active = EventView.active()
			local now = Workspace:GetServerTimeNow()
			balance.Text = NumberFormat.commas(acorns)
			countdown.label.Visible = active
			if active then
				status.Text = "HARVEST FEAST ENDS IN"
				countdown.setEndsAt(EventView.endsAt())
			else
				status.Text = "THE HARVEST SHOP IS CLOSED"
			end
			local profile = ClientState.profile
			local restricted = EggConfig.policyState(if profile ~= nil then profile.policy else nil) == "restricted"
			for _, row in productRows do
				local def = MonetizationConfig.getProduct(row.key)
				-- A paid random product (the lure) where the region restricts them: locked + why.
				local blocked = def ~= nil and def.paidRandom and restricted
				local description = row.description
				if description ~= nil then
					description.Text = if blocked then EventConfig.LurePolicyText else row.text
				end
				if blocked then
					row.button.setRobux(nil)
					row.button.setState("locked", "UNAVAILABLE")
				elseif def ~= nil and MonetizationConfig.isProductAvailable(row.key, now) then
					row.button.setState("normal")
					row.button.setProductKey(row.key)
				else
					row.button.setRobux(nil)
					row.button.setState("locked", if active then "COMING SOON" else "CLOSED")
				end
			end
			for _, row in acornRows do
				local priceText = NumberFormat.commas(row.price)
				if not active then
					row.button.setState("locked", "CLOSED")
				elseif row.kind == "egg" then
					if row.price <= 0 then
						row.button.setState("locked", "COMING SOON")
					else
						row.button.setText(`HATCH  {priceText}`)
						row.button.setState(if acorns >= row.price then "normal" else "disabled")
					end
				elseif row.kind == "decor" and EventView.ownsDecor(row.key) then
					row.button.setState("claimed", "OWNED")
				elseif row.kind == "decor" and not EventView.decorSupported() then
					row.button.setState("locked", "COMING SOON")
				else
					row.button.setText(priceText)
					row.button.setState(if acorns >= row.price then "normal" else "disabled")
				end
			end
		end

		local connection: any = nil
		local policyConnection: any = nil
		return {
			onOpen = function()
				render()
				if connection == nil then
					connection = EventView.Changed:Connect(render)
				end
				-- The lure's region state follows profile.policy pushes while open.
				if policyConnection == nil then
					policyConnection = ClientState.ProfileChanged:Connect(function(_profile: any, fields: { string }?)
						if fields == nil or table.find(fields, "policy") ~= nil then
							render()
						end
					end)
				end
			end,
			onClose = function()
				if connection ~= nil then
					connection:Disconnect()
					connection = nil
				end
				if policyConnection ~= nil then
					policyConnection:Disconnect()
					policyConnection = nil
				end
			end,
			defaultSelection = function(): GuiObject?
				for _, row in acornRows do
					if row.button.state() == "normal" then
						return row.button.instance
					end
				end
				-- Owner R122: nothing affordable used to fall back to the first selectable button = the
				-- first ROBUX acorn pack; now the first acorn item (even if not affordable yet), never
				-- a BUY.
				local firstAcorn = acornRows[1]
				return PurchaseGuard.safeDefault({
					if firstAcorn ~= nil then firstAcorn.button.instance else nil,
					GamepadNav.firstSelectable(window.body),
					window.closeButton,
				})
			end,
		}
	end,
})
