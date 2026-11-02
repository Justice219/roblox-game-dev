--!strict
--[[
	CrateShopScreen ("CrateShop") — the Supply Crate stall (hub crate stall prompt, the Pets
	screen's CRATES button, shop links): three crate cards side by side.

	Each card: the crate model spinning on a sunburst, its blurb, an ODDS toggle that flips the
	card to the full published reward list (CrateConfig weights = the server's roll), the pity line
	("Legendary+ in 3 opens"), and the ways to open it:
		OPEN FREE (n)   held crates (Robux receipts / admin; no gems)
		<gems> GEMS     the gem price (OpenCrate intent → CrateOpen screen plays the reveal)
		R$ <price>      the Robux product (PromptProduct intent; COMING SOON until published)
	ODDS BEFORE EVERY PURCHASE: the first press of the GEMS or Robux button on the card's front
	flips the card to its odds (the button stays put); the next press buys. So the published odds
	are always on screen when gems or Robux are spent.
	Paid random items (CrateConfig.PaidRandomPay — every open, held crates included): where the
	player's region restricts them (EggConfig.policyState(profile.policy) == "restricted") every
	open / buy button is locked ("UNAVAILABLE"; held crates read "KEPT SAFE (n)") and the
	card line says so — nothing is sent or prompted. While the answer is still unknown the card
	line says it is checking and the buttons stay usable: the server re-checks every request and
	fails closed (an unknown answer is refused with "try again").

	Console + mobile: StudUI buttons only, gamepad starts on the first card's main button (held /
	gems — owner R122: never the Robux button, a tagged BUY behind UI/PurchaseGuard whose prompt
	is sent only for a press that began after the window opened), B closes.

	Connects to: UI/Screens/CrateOpen/CrateOpenScreen, Client/Pets/PetViewport, Client/ClientState,
	Shared/Config/{CrateConfig, PetConfig, EggConfig, MonetizationConfig}, Shared/Net/Remotes,
	UI/Kit/StudUI.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientState = require(script.Parent.Parent.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.Parent.Create)
local CrateConfig = require(ReplicatedStorage.Shared.Config.CrateConfig)
local EggConfig = require(ReplicatedStorage.Shared.Config.EggConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local PetConfig = require(ReplicatedStorage.Shared.Config.PetConfig)
local PetUI = require(script.Parent.Parent.Parent.Parent.Pets.PetUI)
local PetViewport = require(script.Parent.Parent.Parent.Parent.Pets.PetViewport)
-- Owner R122 purchase-focus hygiene (opening-press guard, BUY tags, safe default selection).
local PurchaseGuard = require(script.Parent.Parent.Parent.PurchaseGuard)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ScreenManager = require(script.Parent.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local Neutral = UIStyleConfig.Neutral
local CARD = Vector2.new(380, 640)
-- The pity line's gold (the region / checking lines use Neutral.TextDim instead).
local PITY_COLOR = Color3.fromRGB(255, 230, 90)

type CrateCard = {
	crateId: string,
	preview: Frame,
	odds: ScrollingFrame,
	pity: TextLabel,
	oddsButton: StudUI.Button,
	held: StudUI.Button,
	gems: StudUI.Button,
	robux: StudUI.Button,
	showingOdds: boolean,
}

-- The reward lines of a crate's odds list ("2x Cash 15m  30%"): the published weights, formatted
-- by CrateConfig.formatChance (the same text as the CrateOpen odds summary).
local function oddsLines(crate: CrateConfig.CrateDef): { { text: string, chance: string, color: Color3 } }
	local lines = {}
	for _, reward in crate.rewards do
		local rarity = PetConfig.rarity(reward.rarity)
		table.insert(lines, {
			text = reward.label,
			chance = CrateConfig.formatChance(reward.bp),
			color = if rarity ~= nil then rarity.color else Neutral.Text,
		})
	end
	return lines
end

-- The ScreenManager name (PurchaseGuard tracks its open time).
local NAME = "CrateShop"

return StudUI.modalScreen({
	name = NAME,
	title = "Supply Crates",
	color = "yellow",
	icon = "Gift",
	size = Vector2.new(1260, 800),
	build = function(window: StudUI.Window): ScreenManager.ScreenHandle?
		Create.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 22),
			Parent = window.body,
		})
		local cards: { CrateCard } = {}
		local refresh: () -> ()

		-- Opens one crate: the CrateOpen screen sends the request and plays the reveal.
		local function open(crateId: string)
			ScreenManager.close("CrateShop")
			ScreenManager.open("CrateOpen", { crateId = crateId })
		end

		--[[
			Odds before every purchase: a buy press on the card's FRONT flips the card to its odds
			and stops there (true = consumed); with the odds already showing the press buys.
		]]
		local function oddsFirst(entry: CrateCard): boolean
			if entry.showingOdds then
				return false
			end
			entry.showingOdds = true
			refresh()
			return true
		end

		for order, crateId in CrateConfig.Order do
			local crate = CrateConfig.Crates[crateId]
			local card = StudUI.card({
				color = crate.ui :: any,
				title = crate.name,
				titleSize = 40,
				sunburst = false,
				size = UDim2.fromOffset(CARD.X, CARD.Y),
				layoutOrder = order,
				parent = window.body,
			})
			Create.new("UIListLayout", {
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 8),
				Parent = card.content,
			})
			-- Preview (model + blurb) and odds share the same slot.
			local preview = Create.new("Frame", {
				Name = "Preview",
				BackgroundTransparency = 1,
				Size = UDim2.fromOffset(CARD.X - 30, 240),
				LayoutOrder = 1,
				Parent = card.content,
			}) :: Frame
			local view = PetViewport.new({
				size = UDim2.fromOffset(CARD.X - 30, 170),
				spin = true,
				zoom = 0.9,
				parent = preview,
			})
			view.set("crate", crateId)
			local blurb = StudUI.text({
				text = crate.blurb,
				textSize = 24,
				font = "body",
				scaled = true,
				wrap = true,
				size = UDim2.fromOffset(CARD.X - 40, 70),
				position = UDim2.fromOffset(5, 172),
				parent = preview,
			})
			blurb.TextColor3 = Neutral.Text
			local odds = Create.new("ScrollingFrame", {
				Name = "Odds",
				BackgroundColor3 = Neutral.Well,
				BackgroundTransparency = 0.15,
				Size = UDim2.fromOffset(CARD.X - 30, 240),
				CanvasSize = UDim2.new(),
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
				ScrollBarThickness = 6,
				Visible = false,
				LayoutOrder = 1,
				Selectable = true,
				Parent = card.content,
				Children = {
					Create.new("UICorner", { CornerRadius = UDim.new(0, 10) }),
					Create.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 2) }),
					Create.new(
						"UIPadding",
						{ PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), PaddingTop = UDim.new(0, 6) }
					),
				},
			}) :: ScrollingFrame
			for index, line in oddsLines(crate) do
				local row = Create.new(
					"Frame",
					{ BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = index, Parent = odds }
				) :: Frame
				local name = StudUI.text({
					text = line.text,
					textSize = 22,
					font = "title",
					scaled = true,
					align = Enum.TextXAlignment.Left,
					size = UDim2.fromScale(0.7, 1),
					parent = row,
				})
				name.TextColor3 = line.color
				StudUI.text({
					text = line.chance,
					textSize = 22,
					font = "number",
					scaled = true,
					align = Enum.TextXAlignment.Right,
					size = UDim2.fromScale(0.3, 1),
					position = UDim2.fromScale(0.7, 0),
					parent = row,
				})
			end
			local pity = StudUI.text({
				text = "",
				textSize = 22,
				font = "body",
				scaled = true,
				size = UDim2.fromOffset(CARD.X - 30, 28),
				layoutOrder = 2,
				parent = card.content,
			})
			pity.TextColor3 = PITY_COLOR
			local entry: CrateCard
			local oddsButton = StudUI.button({
				text = "ODDS",
				color = "blue",
				size = UDim2.fromOffset(CARD.X - 60, 66),
				textSize = 24,
				layoutOrder = 3,
				parent = card.content,
				onActivated = function()
					entry.showingOdds = not entry.showingOdds
					refresh()
				end,
			})
			local held = StudUI.button({
				text = "OPEN FREE",
				color = "green",
				size = UDim2.fromOffset(CARD.X - 60, 66),
				textSize = 28,
				layoutOrder = 4,
				parent = card.content,
				onActivated = function()
					open(crateId)
				end,
			})
			local gems = StudUI.button({
				text = `{crate.gems} GEMS`,
				color = "purple",
				icon = "Gems",
				size = UDim2.fromOffset(CARD.X - 60, 66),
				textSize = 28,
				layoutOrder = 5,
				parent = card.content,
				onActivated = function()
					if oddsFirst(entry) then
						return
					end
					open(crateId)
				end,
			})
			local robux = StudUI.button({
				text = "",
				color = "green",
				productKey = crate.product, -- live managed price (PriceBook)
				size = UDim2.fromOffset(CARD.X - 60, 66),
				textSize = 28,
				layoutOrder = 6,
				parent = card.content,
				onActivated = function()
					if oddsFirst(entry) then
						return
					end
					-- R122: the press that opened the window never buys (PurchaseGuard).
					if not PurchaseGuard.allow(NAME) then
						return
					end
					-- Intent only: the server validates the product, the policy and the prompt.
					Remotes.event("PromptProduct"):FireServer(crate.product, "shop")
				end,
			})
			PurchaseGuard.markBuy(robux.instance)
			entry = {
				crateId = crateId,
				preview = preview,
				odds = odds,
				pity = pity,
				oddsButton = oddsButton,
				held = held,
				gems = gems,
				robux = robux,
				showingOdds = false,
			}
			table.insert(cards, entry)
		end

		refresh = function()
			local profile: any = ClientState.profile or {}
			-- "restricted" locks every open (held crates included); "checking" leaves the buttons to
			-- the server (it re-checks each request and fails closed).
			local policy = EggConfig.policyState(profile.policy)
			local restricted = policy == "restricted"
			local crates = if type(profile.crates) == "table" then profile.crates else {}
			local held = if type(crates.held) == "table" then crates.held else {}
			local pityMap = if type(crates.pity) == "table" then crates.pity else {}
			local balance = tonumber(profile.gems) or 0
			local now = workspace:GetServerTimeNow()
			for _, entry in cards do
				local crate = CrateConfig.Crates[entry.crateId]
				entry.preview.Visible = not entry.showingOdds
				entry.odds.Visible = entry.showingOdds
				entry.oddsButton.setText(if entry.showingOdds then "BACK" else "ODDS")
				local count = tonumber(held[crate.id]) or 0
				entry.held.instance.Visible = count > 0
				if restricted then
					PetUI.setButton(entry.held, "locked", `{CrateConfig.PolicyText.KeptSafe} ({count})`)
				else
					PetUI.setButton(entry.held, "normal", `OPEN FREE ({count})`)
				end
				-- The card line: the region state wins over the pity meter.
				if restricted then
					entry.pity.Text = CrateConfig.PolicyText.CardLine
					entry.pity.TextColor3 = Neutral.TextDim
				elseif policy == "checking" then
					entry.pity.Text = CrateConfig.PolicyText.Checking
					entry.pity.TextColor3 = Neutral.TextDim
				elseif crate.pity ~= nil then
					local counter = tonumber(pityMap[crate.id]) or 0
					local left = math.max(1, crate.pity.opens - counter)
					local rarity = PetConfig.Rarities[crate.pity.rank]
					entry.pity.Text =
						`{if rarity ~= nil then rarity.id else "Rare"}+ in {left} open{if left == 1 then "" else "s"}`
					entry.pity.TextColor3 = PITY_COLOR
				end
				if restricted then
					PetUI.setButton(entry.gems, "locked", CrateConfig.PolicyText.Button)
					PetUI.setButton(entry.robux, "locked", CrateConfig.PolicyText.Button)
				else
					-- With the odds showing, the gem button is the confirm ("OPEN 120").
					PetUI.setButton(
						entry.gems,
						if balance >= crate.gems then "normal" else "disabled",
						if entry.showingOdds then `OPEN {crate.gems}` else `{crate.gems} GEMS`
					)
					if MonetizationConfig.isProductAvailable(crate.product, now) then
						entry.robux.setState("normal")
					else
						PetUI.setButton(entry.robux, "locked", "COMING SOON")
					end
				end
			end
		end

		local connection: any = nil
		return {
			onOpen = function()
				refresh()
				-- onOpen also runs when the screen is re-opened while open: never stack listeners.
				if connection == nil then
					connection = ClientState.ProfileChanged:Connect(function()
						refresh()
					end)
				end
			end,
			onClose = function()
				if connection ~= nil then
					connection:Disconnect()
					connection = nil
				end
				for _, entry in cards do
					entry.showingOdds = false
				end
			end,
			defaultSelection = function(): GuiObject?
				local first = cards[1]
				if first == nil then
					return nil
				end
				-- Held / gems (never the Robux BUY: R122 PurchaseGuard).
				return PurchaseGuard.safeDefault({
					if first.held.instance.Visible then first.held.instance else nil,
					first.gems.instance,
					first.oddsButton.instance,
				})
			end,
		}
	end,
})
