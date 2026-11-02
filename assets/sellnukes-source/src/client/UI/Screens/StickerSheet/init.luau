--!strict
--[[
	StickerSheet — the Harvest Feast's main window, registered as screen "HarvestFeast" (the HUD
	Event button and the hub Turkey NPC open it). Thanksgiving take on the reference
	docs/reference/sell-lemons/14-halloween-sticker-sheet.png, in SellNukes' stud style:

		┌ [acorn] 1,240      ENDS IN 12d 04:11:09        [ HARVEST SHOP ] ┐
		│   Catch Golden Turkeys on your plot + in the hub!                │
		│  ┌───┬───┬───┬───┬───┐   20 sticker tiles (5 x 4): owned = stud  │
		│  │ ? │ ? │ ? │ ? │ ? │   card in its rarity colour with the 3D   │
		│  ├───┼───┼───┼───┼───┤   icon + name; missing = grey "?"         │
		│  ...                                                              │
		│ ┌ [Gobble Bomb] Gobble Bomb · "Collect all stickers to redeem!" ┐ │
		│ └ [=========-----] 7/20                          [  REDEEM  ]  ┘ │

	Behaviour:
		- Everything shown comes from the server (profile.event via EventView + the event
		  attributes). REDEEM sends only the EventRedeemSheet intent; the server re-checks all 20
		  stickers, the season, the grace window and grants the pet.
		- REDEEM states: LOCKED! (sheet incomplete), REDEEM (green), CLAIMED (done this season),
		  "EVENT OVER" when the redeem grace has passed.
		- Gamepad / touch (owner R11): HARVEST SHOP and REDEEM are the only selectable controls
		  (default selection = REDEEM when ready, else the shop); B / the red X close.
		- Re-renders only on EventView.Changed while open (no polling); the countdown uses
		  StudUI's shared 1 Hz ticker.

	Connects to: Client/Event/EventView, Kit/StudUI, UI/ScreenManager, Shared/Config/EventConfig,
	Shared/Net/Remotes (EventRedeemSheet), Screens/EventShop.

	Example: ScreenManager.open("HarvestFeast")
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Create = require(script.Parent.Parent.Create)
local EventConfig = require(ReplicatedStorage.Shared.Config.EventConfig)
local EventView = require(script.Parent.Parent.Parent.Event.EventView)
local GamepadNav = require(script.Parent.Parent.Parent.Platform.GamepadNav)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local NAME = "HarvestFeast"
local COLUMNS = 5
local ROWS = 4
local GRID_HEIGHT = 470
local ACORN_COLOR = Color3.fromRGB(255, 196, 92)

type Tile = {
	def: EventConfig.StickerDef,
	card: StudUI.Card,
	icon: Frame,
	nameLabel: TextLabel,
	question: TextLabel,
	owned: boolean?,
}

return StudUI.modalScreen({
	name = NAME,
	title = "Feast Sticker Sheet",
	color = "orange",
	icon = "StickerSheet",
	size = Vector2.new(1120, 900),
	build = function(window: StudUI.Window): ScreenManager.ScreenHandle?
		local body = window.body
		Create.new("UIListLayout", {
			Padding = UDim.new(0, 12),
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = body,
		})

		-- ── Top strip: acorns · countdown · shop ──────────────────────────────────────────
		local top = Create.new("Frame", {
			Name = "Top",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, -16, 0, 96),
			LayoutOrder = 1,
			Parent = body,
		}) :: Frame
		local acornIcon = StudUI.icon("Acorn", 72, 3)
		acornIcon.Position = UDim2.fromOffset(0, 4)
		acornIcon.Parent = top
		local acornLabel = StudUI.text({
			name = "Acorns",
			text = "0",
			textSize = 52,
			font = "number",
			color = ACORN_COLOR,
			align = Enum.TextXAlignment.Left,
			position = UDim2.fromOffset(82, 8),
			size = UDim2.fromOffset(240, 60),
			parent = top,
		})
		StudUI.text({
			text = "ACORNS",
			textSize = 20,
			color = UIStyleConfig.Neutral.TextDim,
			align = Enum.TextXAlignment.Left,
			position = UDim2.fromOffset(84, 66),
			size = UDim2.fromOffset(200, 24),
			parent = top,
		})
		local caption = StudUI.text({
			name = "Caption",
			text = "ENDS IN",
			textSize = 22,
			color = UIStyleConfig.Neutral.TextDim,
			position = UDim2.fromScale(0.5, 0),
			anchor = Vector2.new(0.5, 0),
			size = UDim2.fromOffset(420, 26),
			parent = top,
		})
		local countdown = StudUI.countdown({
			endsAt = EventConfig.Season.ends,
			format = "auto",
			doneText = "00:00",
			textSize = 40,
			color = Color3.fromRGB(255, 226, 80),
			size = UDim2.fromOffset(420, 46),
			parent = top,
		})
		countdown.label.AnchorPoint = Vector2.new(0.5, 0)
		countdown.label.Position = UDim2.new(0.5, 0, 0, 24)
		local hint = StudUI.text({
			name = "Hint",
			text = "Catch Golden Turkeys on your plot and in the hub!",
			textSize = 20,
			wrap = true,
			position = UDim2.new(0.5, 0, 0, 70),
			anchor = Vector2.new(0.5, 0),
			size = UDim2.fromOffset(470, 26),
			parent = top,
		})
		local shopButton = StudUI.button({
			text = "HARVEST SHOP",
			color = "yellow",
			icon = "Acorn",
			-- Owner R94: 330 wide + 32 px text so "HARVEST SHOP" and the acorn fit inside the
			-- button (StudUI.button also shrinks any label that would still overflow).
			size = UDim2.fromOffset(330, 76), -- >= 44 pt on phones after ModalShell scaling
			textSize = 32,
			position = UDim2.new(1, 0, 0.5, -4),
			anchor = Vector2.new(1, 0.5),
			parent = top,
			onActivated = function()
				ScreenManager.open("EventShop")
			end,
		})

		-- ── The sheet: 5 x 4 sticker tiles ────────────────────────────────────────────────
		local grid = Create.new("Frame", {
			Name = "Sheet",
			BackgroundColor3 = UIStyleConfig.Neutral.Well,
			Size = UDim2.new(1, -16, 0, GRID_HEIGHT),
			LayoutOrder = 2,
			Parent = body,
			Children = {
				Create.new("UICorner", { CornerRadius = UDim.new(0, 10) }),
				Create.new("UIPadding", {
					PaddingTop = UDim.new(0, 8),
					PaddingBottom = UDim.new(0, 8),
					PaddingLeft = UDim.new(0, 8),
					PaddingRight = UDim.new(0, 8),
				}),
				Create.new("UIGridLayout", {
					CellPadding = UDim2.fromOffset(10, 10),
					CellSize = UDim2.new(1 / COLUMNS, -8, 1 / ROWS, -8),
					SortOrder = Enum.SortOrder.LayoutOrder,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
				}),
			},
		}) :: Frame
		local tiles: { Tile } = {}
		for _, def in EventConfig.Stickers do
			local card = StudUI.card({
				name = def.key,
				color = "grey",
				layoutOrder = def.index,
				parent = grid,
			})
			StudUI.text({
				name = "Number",
				text = `#{def.index}`,
				textSize = 18,
				color = UIStyleConfig.Neutral.TextDim,
				align = Enum.TextXAlignment.Left,
				position = UDim2.fromOffset(2, 0),
				size = UDim2.fromOffset(60, 20),
				zIndex = 6,
				parent = card.content,
			})
			local icon = StudUI.icon(def.icon, 64, 4)
			icon.AnchorPoint = Vector2.new(0.5, 0.5)
			icon.Position = UDim2.fromScale(0.5, 0.42)
			icon.Size = UDim2.fromScale(0.62, 0.62)
			Create.new("UIAspectRatioConstraint", { AspectRatio = 1, Parent = icon })
			icon.Visible = false
			icon.Parent = card.content
			local nameLabel = StudUI.text({
				name = "Name",
				text = def.name,
				textSize = 18,
				scaled = true,
				position = UDim2.new(0, 0, 1, -22),
				size = UDim2.new(1, 0, 0, 22),
				zIndex = 6,
				parent = card.content,
			})
			nameLabel.Visible = false
			local question = StudUI.text({
				name = "Unknown",
				text = "?",
				textSize = 64,
				font = "shout",
				position = UDim2.fromScale(0.5, 0.5),
				anchor = Vector2.new(0.5, 0.5),
				size = UDim2.fromScale(1, 0.8),
				zIndex = 6,
				parent = card.content,
			})
			table.insert(
				tiles,
				{ def = def, card = card, icon = icon, nameLabel = nameLabel, question = question, owned = nil }
			)
		end

		-- ── Reward bar ────────────────────────────────────────────────────────────────────
		local reward = StudUI.card({
			name = "Reward",
			color = "orange",
			sunburst = true,
			size = UDim2.new(1, -16, 0, 170),
			layoutOrder = 3,
			parent = body,
		})
		local petIcon = StudUI.icon(EventConfig.RewardIcon, 130, 4)
		petIcon.AnchorPoint = Vector2.new(0, 0.5)
		petIcon.Position = UDim2.new(0, 6, 0.5, 0)
		petIcon.Parent = reward.content
		local shade = Create.new("Frame", {
			Name = "Shade",
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = 0.45,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 5,
			Parent = petIcon,
			Children = { Create.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }) },
		}) :: Frame
		local lock = StudUI.icon("Lock", 56, 6)
		lock.AnchorPoint = Vector2.new(0.5, 0.5)
		lock.Position = UDim2.fromScale(0.5, 0.5)
		lock.Parent = shade
		local rewardTitle = StudUI.text({
			text = EventConfig.RewardPetName,
			textSize = 44,
			font = "shout",
			align = Enum.TextXAlignment.Left,
			position = UDim2.fromOffset(150, 6),
			size = UDim2.new(1, -440, 0, 50),
			parent = reward.content,
		})
		local rewardSub = StudUI.text({
			text = "Collect all stickers to redeem!",
			textSize = 26,
			wrap = true,
			align = Enum.TextXAlignment.Left,
			position = UDim2.fromOffset(150, 56),
			size = UDim2.new(1, -440, 0, 34),
			parent = reward.content,
		})
		local bar = StudUI.progressBar({ color = "green", size = UDim2.new(1, -450, 0, 34), parent = reward.content })
		bar.frame.Position = UDim2.fromOffset(150, 100)
		local barLabel = StudUI.text({
			text = "0/20",
			textSize = 26,
			font = "number",
			size = UDim2.fromScale(1, 1),
			zIndex = 8,
			parent = bar.frame,
		})
		local redeem = StudUI.button({
			text = "REDEEM",
			color = "green",
			size = UDim2.fromOffset(260, 88),
			position = UDim2.new(1, -8, 0.5, 0),
			anchor = Vector2.new(1, 0.5),
			parent = reward.content,
			onActivated = function()
				Remotes.event("EventRedeemSheet"):FireServer()
			end,
		})

		-- Gamepad (owner R11): the two controls link to each other; B / the red X close.
		GamepadNav.linkList({ shopButton.instance, redeem.instance }, true)

		-- Re-renders from EventView (server data only).
		local function render()
			acornLabel.Text = NumberFormat.commas(EventView.acorns())
			local stickers = EventView.stickers()
			for _, tile in tiles do
				local owned = stickers[tile.def.index] == true
				if tile.owned ~= owned then
					tile.owned = owned
					tile.card.setColor(
						(if owned then EventConfig.RarityColor[tile.def.rarity] else "grey") :: StudUI.ColorName
					)
					tile.icon.Visible = owned
					tile.nameLabel.Visible = owned
					tile.question.Visible = not owned
				end
			end
			local count = EventView.count()
			bar.setProgress(count / EventConfig.StickerCount)
			barLabel.Text = `{count}/{EventConfig.StickerCount}`
			local complete = count >= EventConfig.StickerCount
			shade.Visible = not complete and not EventView.redeemed()
			local active = EventView.active()
			if EventView.redeemed() then
				rewardSub.Text = "Redeemed! Your Gobble Bomb is in your pets."
				redeem.setState("claimed", "CLAIMED")
			elseif EventView.canRedeem() then
				rewardSub.Text = "Sheet complete! Redeem your reward!"
				redeem.setState("normal", "REDEEM")
			elseif complete then
				rewardSub.Text = "The redeem window has closed."
				redeem.setState("locked", "EVENT OVER")
			else
				rewardSub.Text = "Collect all stickers to redeem!"
				redeem.setState("locked", "LOCKED!")
			end
			rewardTitle.Text = EventConfig.RewardPetName
			countdown.label.Visible = true
			if active then
				caption.Text = "HARVEST FEAST ENDS IN"
				countdown.setEndsAt(EventView.endsAt())
				hint.Text = "Catch Golden Turkeys on your plot and in the hub!"
				shopButton.setState("normal", "HARVEST SHOP")
			elseif Workspace:GetServerTimeNow() < EventView.redeemUntil() and EventView.canRedeem() then
				caption.Text = "REDEEM CLOSES IN"
				countdown.setEndsAt(EventView.redeemUntil())
				hint.Text = "The feast is over - redeem your sheet before it closes!"
				shopButton.setState("locked", "SHOP CLOSED")
			else
				caption.Text = "HARVEST FEAST"
				countdown.label.Visible = false
				hint.Text = "The Golden Turkeys are resting. See you next harvest!"
				shopButton.setState("locked", "SHOP CLOSED")
			end
		end

		local connection: any = nil
		return {
			onOpen = function()
				render()
				if connection == nil then
					connection = EventView.Changed:Connect(render)
				end
			end,
			onClose = function()
				if connection ~= nil then
					connection:Disconnect()
					connection = nil
				end
			end,
			defaultSelection = function(): GuiObject?
				if redeem.state() == "normal" then
					return redeem.instance
				end
				if shopButton.state() == "normal" then
					return shopButton.instance
				end
				return GamepadNav.firstSelectable(window.body) or window.closeButton
			end,
		}
	end,
})
