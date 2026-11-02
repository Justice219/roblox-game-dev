--!strict
--[[
	Theme — SellNukes' shared visual constants for the UI framework (ported from RoBeasts).

	Purpose:
		The framework pieces (Components, ScreenManager, Widgets) read colours / fonts / sizes from
		here. The stud style KIT (Kit/StudUI) reads its richer palette from
		Shared/Config/UIStyleConfig; Theme mirrors the few neutral values the framework needs so
		both always agree (Theme.Colors.Panel == UIStyleConfig.Neutral.Body, ...).
		All sizes are design px at 1080p, scaled by each ScreenGui's AutoScale UIScale.

	Connects to: UI/Components, UI/ScreenManager, UI/Widgets/*, Shared/Config/UIStyleConfig.

	Example:
		label.FontFace = Theme.Fonts.Display
		frame.BackgroundColor3 = Theme.Colors.Panel
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local Theme = {}

local neutral = UIStyleConfig.Neutral
local colors = UIStyleConfig.Colors

Theme.Colors = table.freeze({
	Panel = neutral.Body,
	PanelLight = Color3.fromRGB(104, 118, 144),
	PanelDark = neutral.Well,
	Overlay = Color3.fromRGB(8, 10, 18),
	Text = neutral.Text,
	TextDim = neutral.TextDim,
	TextDark = neutral.Edge,
	Stroke = neutral.TextStroke,
	Edge = neutral.Edge,
	Primary = colors.yellow.bottom,
	PrimaryDark = colors.yellow.lip,
	Danger = colors.red.bottom,
	DangerDark = colors.red.lip,
	Success = colors.green.bottom,
	SuccessDark = colors.green.lip,
	Cash = neutral.CashGreen,
	Gem = neutral.GemPurple,
	Selection = Color3.fromRGB(255, 255, 255),
})

Theme.Fonts = table.freeze({
	Display = UIStyleConfig.Fonts.Shout, -- Luckiest Guy: big numbers, shouty headlines
	Body = UIStyleConfig.Fonts.Body, -- Fredoka One: titles, labels, body copy
	Mono = Font.fromEnum(Enum.Font.RobotoMono),
})

Theme.TextSize = table.freeze({
	Huge = 96,
	Title = 60,
	Heading = 40,
	Large = 30,
	Body = 24,
	Small = 20,
	Tiny = 16,
})

-- Rendered corner radii (SellNukes' references are blocky: small radii everywhere).
Theme.Corner = UDim.new(0, 8)
Theme.CornerSmall = UDim.new(0, 5)
Theme.StrokeThickness = 3
Theme.Padding = 16

-- Animation timings (seconds).
Theme.Tween = table.freeze({
	Fast = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	Normal = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	Bounce = TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
	Slow = TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
})

return table.freeze(Theme)
