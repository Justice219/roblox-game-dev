--!strict
--[[
	UIGallery — DEV ONLY (Studio): every StudUI component on one scrollable page, so screenshots
	can verify the stud look against docs/reference/ui-style/*.png after any style change.

	Purpose:
		UIController registers this screen ONLY when RunService:IsStudio() (never on live
		servers). Open it with F6 in a Studio playtest (InputConfig "DevGallery"), from the MCP
		(`eval_client_runtime`: ScreenManager.open("UIGallery")), or by setting the local player's
		"DevOpenScreen" attribute to "UIGallery" from the server (Studio hook in UIController).
		Sections: buttons (every colour preset + every state + Robux), cards (Daily-style day
		tiles, rainbow final card, orange time cards with live countdowns), starburst offers,
		HUD tiles, money labels, text box, section label, progress bar, toasts and every icon
		glyph (fallbacks until Blender icons are uploaded).

	Connects to: Kit/StudUI (everything, incl. StudUI.IconKeys), Shared/Config/UIStyleConfig,
	Controllers/UIController (Studio-only registration).

	Example: ScreenManager.open("UIGallery")
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Create = require(script.Parent.Parent.Create)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local NAME = "UIGallery"

-- A titled section with a wrapping row of items. Both the section and its row grow with their
-- content (AutomaticSize Y), so wrapped rows never overlap the next section. `height` is the
-- minimum row height (one line of items).
local function section(parent: GuiObject, order: number, title: string, height: number): Frame
	local holder = Create.new("Frame", {
		Name = `Section_{title}`,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Parent = parent,
		Children = {
			Create.new("UIListLayout", {
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, 8),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		},
	}) :: Frame
	StudUI.text({
		text = title,
		textSize = 34,
		align = Enum.TextXAlignment.Left,
		size = UDim2.new(1, 0, 0, 44),
		layoutOrder = 1,
		parent = holder,
	})
	local row = Create.new("Frame", {
		Name = "Row",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, height),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Parent = holder,
		Children = {
			Create.new("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				Wraps = true,
				VerticalAlignment = Enum.VerticalAlignment.Top,
				Padding = UDim.new(0, 18),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			-- Room under the last line for Robux tags hanging below buttons.
			Create.new("UIPadding", { PaddingBottom = UDim.new(0, 30) }),
		},
	}) :: Frame
	return row
end

-- A Daily-rewards style day card (title, icon, word, button) for the gallery.
local function dayCard(
	parent: Instance,
	order: number,
	day: string,
	word: string,
	icon: string,
	state: StudUI.ButtonState
)
	local card = StudUI.card({
		color = "sky",
		sunburst = true,
		title = day,
		size = UDim2.fromOffset(196, 214),
		layoutOrder = order,
		parent = parent,
	})
	local glyph = StudUI.icon(icon, 92, 3)
	glyph.AnchorPoint = Vector2.new(0.5, 0.5)
	glyph.Position = UDim2.fromScale(0.5, 0.44)
	glyph.Parent = card.content
	StudUI.text({
		text = word,
		textSize = 32,
		position = UDim2.fromScale(0, 0.62),
		size = UDim2.new(1, 0, 0, 36),
		zIndex = 4,
		parent = card.content,
	})
	local button = StudUI.button({
		text = "CLAIM",
		color = "green",
		size = UDim2.new(1, -16, 0, 40),
		position = UDim2.new(0.5, 0, 1, -8),
		anchor = Vector2.new(0.5, 1),
		parent = card.content,
	})
	button.instance.Size = UDim2.new(0.9, 0, 0, 40)
	button.setState(state)
end

return StudUI.modalScreen({
	name = NAME,
	title = "UI Gallery",
	color = "purple",
	icon = "Star",
	size = Vector2.new(1640, 940),
	scroll = true,
	lazy = true,
	build = function(window: StudUI.Window): ScreenManager.ScreenHandle?
		local body = window.body
		Create.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			Padding = UDim.new(0, 12),
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = body,
		})
		local first: GuiObject? = nil

		-- Buttons: every colour preset, then the states and Robux variants.
		local colors = section(body, 1, "Buttons — colour presets", 160)
		local names: { UIStyleConfig.ColorName } =
			{ "green", "yellow", "red", "blue", "sky", "purple", "orange", "grey", "white", "teal", "rainbow" }
		for index, name in names do
			local button = StudUI.button({
				text = string.upper(name),
				color = name,
				size = UDim2.fromOffset(200, 60),
				layoutOrder = index,
				parent = colors,
			})
			if first == nil then
				first = button.instance
			end
		end
		local states = section(body, 2, "Buttons — states, Robux, close", 110)
		StudUI.button({
			text = "CLAIM",
			color = "green",
			size = UDim2.fromOffset(220, 60),
			layoutOrder = 1,
			parent = states,
		})
		StudUI.button({
			text = "CLAIM",
			color = "green",
			size = UDim2.fromOffset(220, 60),
			layoutOrder = 2,
			parent = states,
		}).setState("claimed")
		StudUI.button({
			text = "CLAIM",
			color = "green",
			size = UDim2.fromOffset(220, 60),
			layoutOrder = 3,
			parent = states,
		}).setState("locked")
		StudUI.button({
			text = "SAVE",
			color = "blue",
			size = UDim2.fromOffset(220, 60),
			layoutOrder = 4,
			parent = states,
		}).setState("disabled")
		StudUI.button({
			text = "",
			color = "green",
			robux = 25,
			size = UDim2.fromOffset(200, 60),
			layoutOrder = 5,
			parent = states,
		})
		StudUI.button({
			text = "(5x) 59 R$",
			color = "yellow",
			size = UDim2.fromOffset(240, 60),
			layoutOrder = 6,
			parent = states,
		})
		StudUI.button({
			text = "DOUBLE IT!",
			color = "green",
			robux = 39,
			size = UDim2.fromOffset(260, 60),
			layoutOrder = 7,
			parent = states,
		})
		StudUI.button({
			text = "OKAY",
			color = "grey",
			size = UDim2.fromOffset(200, 60),
			layoutOrder = 8,
			parent = states,
		})
		StudUI.closeButton({ size = 70, parent = states }).instance.LayoutOrder = 9

		-- Cards: Daily-rewards style row + rainbow final card + orange time cards.
		local cards = section(body, 3, "Cards — daily / rainbow / time", 230)
		dayCard(cards, 1, "Day 1", "One", "Gift", "claimed")
		dayCard(cards, 2, "Day 2", "Two", "SecretPack", "normal")
		dayCard(cards, 3, "Day 3", "Three", "StarterPack", "locked")
		local final = StudUI.card({
			color = "rainbow",
			sunburst = true,
			title = "Day 7",
			titleSize = 46,
			size = UDim2.fromOffset(250, 214),
			layoutOrder = 4,
			parent = cards,
		})
		local key = StudUI.icon("VIP", 96, 3)
		key.AnchorPoint = Vector2.new(0.5, 0.5)
		key.Position = UDim2.fromScale(0.5, 0.48)
		key.Parent = final.content
		for index = 1, 2 do
			local time = StudUI.card({
				color = "orange",
				sunburst = true,
				size = UDim2.fromOffset(196, 214),
				layoutOrder = 4 + index,
				parent = cards,
			})
			StudUI.countdown({
				endsAt = Workspace:GetServerTimeNow() + (if index == 1 then 251 else 3 * 3600 - 49),
				textSize = 36,
				size = UDim2.new(1, 0, 0, 40),
				parent = time.content,
			})
			local gift = StudUI.icon("Gift", 92, 3)
			gift.AnchorPoint = Vector2.new(0.5, 0.5)
			gift.Position = UDim2.fromScale(0.5, 0.5)
			gift.Parent = time.content
			local locked = StudUI.button({
				text = "LOCKED!",
				color = "grey",
				size = UDim2.new(0.9, 0, 0, 40),
				position = UDim2.new(0.5, 0, 1, -8),
				anchor = Vector2.new(0.5, 1),
				parent = time.content,
			})
			locked.setState("locked")
		end

		-- Starburst offers (right column).
		local burstRow = section(body, 4, "Starburst offers", 210)
		local offers = {
			{ "x2 Cash", "x2Cash", 399 },
			{ "Starter Pack", "StarterPack", 49 },
			{ "VIP", "VIP", 249 },
			{ "x5 Spins", "Spins", 79 },
			{ "Teleporter", "Teleporter", 99 },
			{ "Secret Pack", "SecretPack", 0 },
		}
		for index, offer in offers do
			StudUI.starburst({
				label = offer[1] :: string,
				icon = offer[2] :: string,
				robuxPrice = offer[3] :: number,
				size = 190,
				layoutOrder = index,
				parent = burstRow,
			})
		end

		-- HUD tiles.
		local hudRow = section(body, 5, "HUD buttons", 140)
		local hudItems: { { string | boolean } } = {
			{ "Shop", "Shop", "yellow", false },
			{ "Rewards", "Rewards", "green", false },
			{ "Daily", "Daily", "red", false },
			{ "Codes", "Codes", "blue", false },
			{ "Lucky Wheel", "LuckyWheel", "rainbow", true },
			{ "Time", "Time", "red", false },
			{ "Pets", "Pets", "purple", false },
			{ "Rebirth", "Rebirth", "teal", false },
		}
		for index, item in hudItems do
			local tile = StudUI.hudButton({
				label = item[1] :: string,
				icon = item[2] :: string,
				color = item[3] :: any,
				wide = item[4] :: boolean,
				layoutOrder = index,
				parent = hudRow,
			})
			if index == 3 then
				tile.setBadge("!")
			end
		end

		-- Money, text box, section label, progress, toasts.
		local misc = section(body, 6, "Money / inputs / progress / toasts", 250)
		local cash = StudUI.moneyLabel({ kind = "cash", amount = 119080, layoutOrder = 1, parent = misc })
		cash.setAmount(119080)
		StudUI.moneyLabel({ kind = "gems", amount = 9671, layoutOrder = 2, parent = misc })
		StudUI.moneyLabel({ kind = "rate", amount = 1259, layoutOrder = 3, parent = misc })
		StudUI.textBox({
			placeholder = "Code Here",
			maxLength = 24,
			size = UDim2.fromOffset(440, 84),
			layoutOrder = 4,
			parent = misc,
		})
		local section2 = StudUI.sectionLabel("Limited Time", 40)
		section2.Size = UDim2.fromOffset(420, 50)
		section2.LayoutOrder = 5
		section2.Parent = misc
		local bar =
			StudUI.progressBar({ color = "green", size = UDim2.fromOffset(360, 30), layoutOrder = 6, parent = misc })
		bar.setProgress(0.62)
		local kinds: { StudUI.ToastKind } = { "success", "reward", "error", "info", "purchase" }
		for index, kind in kinds do
			local toast = StudUI.toast({ text = `{kind} toast`, kind = kind })
			toast.LayoutOrder = 6 + index
			toast.Parent = misc
		end

		-- Every icon (uploaded image or frame-drawn fallback).
		local iconRow = section(body, 7, "Icons (uploaded 3D icon, or the glyph while its image is empty)", 200)
		for index, iconKey in StudUI.IconKeys do
			local cell = Create.new("Frame", {
				Name = iconKey,
				BackgroundTransparency = 1,
				Size = UDim2.fromOffset(84, 92),
				LayoutOrder = index,
				Parent = iconRow,
			}) :: Frame
			local glyph = StudUI.icon(iconKey, 64, 2)
			glyph.Position = UDim2.fromOffset(10, 0)
			glyph.Parent = cell
			StudUI.text({
				text = iconKey,
				textSize = 14,
				position = UDim2.fromOffset(0, 68),
				size = UDim2.new(1, 0, 0, 20),
				parent = cell,
			})
		end

		return {
			defaultSelection = function(): GuiObject?
				return first
			end,
		}
	end,
})
