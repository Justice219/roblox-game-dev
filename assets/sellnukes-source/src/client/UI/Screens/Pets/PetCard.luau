--!strict
--[[
	PetCard — one square stud card of the Pets screen grids (inventory, held eggs, Pet Index): a
	rarity-coloured stud surface, the 3D model in a static viewport, a bottom caption, a top-left
	badge (lock / count) and a top-right check (equipped / selected for delete).

	Cards are POOLED: a grid builds its cards once and re-fills them with `show(...)` when the page
	or the data changes; the viewport only rebuilds when the model id changes, so paging is cheap.
	Every card is a Selectable button (gamepad) with a white selection ring.

	Connects to: UI/Screens/Pets/PetsScreen, Client/Pets/PetViewport, UI/Widgets/StudWindow,
	Shared/Config/{PetConfig, UIStyleConfig}.

	Example:
		local card = PetCard.new(grid, 1, function() select(1) end)
		card.show({ kind = "pet", id = "fission_fox", color = "purple", caption = "+20%" })
		card.hide()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Create = require(script.Parent.Parent.Parent.Create)
local PetViewport = require(script.Parent.Parent.Parent.Parent.Pets.PetViewport)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Parent.Widgets.StudWindow)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local Neutral = UIStyleConfig.Neutral

export type Content = {
	kind: PetViewport.Kind?, -- nil = no model (mystery card)
	id: string?,
	color: string, -- StudUI colour preset of the surface
	caption: string,
	captionColor: Color3?,
	badge: string?, -- top-left ("LOCK" / "x3")
	check: string?, -- top-right ("ON" equipped / "X" delete pick)
	checkColor: Color3?,
	mystery: string?, -- big centred text instead of a model ("?")
	swatch: { Color3 }?, -- a colour band instead of a model (trails)
	highlight: boolean?, -- white outline (the selected card)
}

export type Card = {
	button: TextButton,
	show: (content: Content) -> (),
	hide: () -> (),
	Destroy: () -> (),
}

local PetCard = {}

--[[
	A pooled card inside `parent` (a grid with a UIGridLayout). `onPress` runs on click / tap /
	gamepad A.
]]
function PetCard.new(parent: Instance, order: number, onPress: () -> ()): Card
	local button = Create.new("TextButton", {
		Name = `Card{order}`,
		Text = "",
		AutoButtonColor = false,
		LayoutOrder = order,
		Selectable = true,
		BackgroundTransparency = 0,
		SelectionImageObject = Create.new("Frame", { BackgroundTransparency = 1 }),
		Parent = parent,
	}) :: TextButton
	local surface = StudWindow.surface(button, "grey", { edge = 3, corner = 14 })
	local ring = Create.new("UIStroke", {
		Name = "Ring",
		Color = Color3.new(1, 1, 1),
		Thickness = 4,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Enabled = false,
		Parent = button,
	}) :: UIStroke
	local view = PetViewport.new({
		size = UDim2.fromScale(1, 0.74),
		position = UDim2.fromScale(0, 0.02),
		zIndex = 3,
		parent = button,
	})
	local swatch = Create.new("Frame", {
		Name = "Swatch",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromScale(0.8, 0.3),
		Position = UDim2.fromScale(0.1, 0.3),
		Visible = false,
		ZIndex = 3,
		Parent = button,
		Children = {
			Create.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
			Create.new("UIStroke", { Color = Neutral.Edge, Thickness = 3 }),
		},
	}) :: Frame
	local swatchGradient = Create.new("UIGradient", { Parent = swatch }) :: UIGradient
	local mystery = StudUI.text({
		text = "?",
		textSize = 70,
		font = "shout",
		scaled = true,
		size = UDim2.fromScale(0.6, 0.55),
		position = UDim2.fromScale(0.2, 0.1),
		parent = button,
	})
	mystery.ZIndex = 3
	local caption = StudUI.text({
		text = "",
		textSize = 26,
		font = "number",
		scaled = true,
		size = UDim2.fromScale(0.92, 0.2),
		position = UDim2.fromScale(0.04, 0.77),
		parent = button,
	})
	caption.ZIndex = 4
	local badge = StudUI.text({
		text = "",
		textSize = 24,
		font = "number",
		scaled = true,
		size = UDim2.fromScale(0.36, 0.2),
		position = UDim2.fromScale(0.04, 0.03),
		align = Enum.TextXAlignment.Left,
		parent = button,
	})
	badge.ZIndex = 4
	local check = StudUI.text({
		text = "",
		textSize = 30,
		font = "shout",
		scaled = true,
		size = UDim2.fromScale(0.3, 0.24),
		position = UDim2.fromScale(0.66, 0.02),
		align = Enum.TextXAlignment.Right,
		parent = button,
	})
	check.ZIndex = 4

	local selected = false
	local highlighted = false
	local function refreshRing()
		ring.Enabled = selected or highlighted
	end
	button.SelectionGained:Connect(function()
		selected = true
		refreshRing()
	end)
	button.SelectionLost:Connect(function()
		selected = false
		refreshRing()
	end)
	button.Activated:Connect(function()
		onPress()
	end)

	return {
		button = button,
		show = function(content: Content)
			button.Visible = true
			surface.setColor(content.color :: any)
			if content.kind ~= nil and content.id ~= nil then
				view.frame.Visible = true
				view.set(content.kind, content.id)
			else
				view.frame.Visible = false
			end
			local colors = content.swatch
			swatch.Visible = colors ~= nil and #colors > 0
			if colors ~= nil and #colors > 0 then
				local keypoints: { ColorSequenceKeypoint } = {}
				for index, color in colors do
					table.insert(
						keypoints,
						ColorSequenceKeypoint.new(if #colors == 1 then 0 else (index - 1) / (#colors - 1), color)
					)
				end
				if #keypoints == 1 then
					table.insert(keypoints, ColorSequenceKeypoint.new(1, colors[1]))
				end
				swatchGradient.Color = ColorSequence.new(keypoints)
			end
			mystery.Visible = content.mystery ~= nil
			mystery.Text = content.mystery or ""
			caption.Text = content.caption
			caption.TextColor3 = content.captionColor or Neutral.Text
			badge.Text = content.badge or ""
			check.Text = content.check or ""
			check.TextColor3 = content.checkColor or Neutral.CashGreen
			highlighted = content.highlight == true
			refreshRing()
		end,
		hide = function()
			button.Visible = false
			highlighted = false
			refreshRing()
		end,
		Destroy = function()
			view.Destroy()
			button:Destroy()
		end,
	}
end

return PetCard
