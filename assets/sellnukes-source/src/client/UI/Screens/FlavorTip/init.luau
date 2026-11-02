--!strict
--[[
	FlavorTip — the one-time "what are Lucky Nukes?" tip card (owner R112). Opened once by
	Tycoon/FlavorTip on the player's first Lucky Nuke (flavoured batch):

		┌ Lucky Nukes! ───────────────────────────── X ┐
		│  [toy]  Lucky Nukes! Sometimes your machines  │
		│         make rare flavoured nukes that sell   │
		│         for more. Collect them all in         │
		│         Pets → FLAVOURS for gems!             │
		│                  [    OK    ]                 │
		└───────────────────────────────────────────────┘

	OK, the red X, gamepad B and keyboard X / Backspace all close it (ScreenManager closeOnBack);
	closing in ANY way sends FlavorTipSeen once (Tycoon/FlavorTip.markSeen), so it never shows again.
	Console + mobile (owner R11): OK is the default gamepad selection and a >= 44 pt stud button
	(300 x 100 design px inside a modest window, so ModalShell keeps it finger-sized on phones); the
	body text stays >= 14 pt on a phone (34 design px). Every word comes from FlavorConfig.Text.

	Connects to: UI/{ScreenManager, Kit/StudUI}, Tycoon/FlavorTip, Shared/Config/FlavorConfig.

	Example: ScreenManager.open("FlavorTip")
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FlavorConfig = require(ReplicatedStorage.Shared.Config.FlavorConfig)
local FlavorTip = require(script.Parent.Parent.Parent.Tycoon.FlavorTip)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Kit.StudUI)

local Text = FlavorConfig.Text

return StudUI.modalScreen({
	name = FlavorConfig.TipScreen,
	title = Text.TipTitle,
	color = "rainbow",
	icon = "Nuke",
	size = Vector2.new(940, 520),
	build = function(window: StudUI.Window): ScreenManager.ScreenHandle?
		local body = window.body
		-- A big tinted toy nuke on the left (the Book's flavour look), the explanation on the right.
		local icon = StudUI.icon("Nuke", 190, 3)
		icon.AnchorPoint = Vector2.new(0, 0.5)
		icon.Position = UDim2.new(0, 10, 0.5, -50)
		icon.Parent = body
		local image = icon:FindFirstChildOfClass("ImageLabel")
		if image ~= nil then
			local galaxy = FlavorConfig.byId("galaxy")
			image.ImageColor3 = if galaxy ~= nil
				then galaxy.color:Lerp(Color3.new(1, 1, 1), 0.35)
				else image.ImageColor3
		end
		StudUI.text({
			name = "Body",
			text = Text.TipBody,
			textSize = 34,
			wrap = true,
			align = Enum.TextXAlignment.Left,
			alignY = Enum.TextYAlignment.Center,
			position = UDim2.fromOffset(220, 0),
			size = UDim2.new(1, -230, 1, -130),
			parent = body,
		})
		local ok = StudUI.button({
			name = "Ok",
			text = Text.TipOk,
			color = "green",
			size = UDim2.fromOffset(300, 100),
			textSize = 44,
			anchor = Vector2.new(0.5, 1),
			position = UDim2.new(0.5, 0, 1, -8),
			parent = body,
			onActivated = function()
				ScreenManager.close(FlavorConfig.TipScreen)
			end,
		})
		return {
			onClose = function()
				FlavorTip.markSeen() -- OK, X and B all count as "got it"
			end,
			defaultSelection = function(): GuiObject?
				return ok.instance
			end,
		}
	end,
})
