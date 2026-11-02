--!strict
--[[
	TouchUIConfig — touch / phone layout tunables (ported from RoBeasts wave 7, SellNukes values).

	Units: "points" (pt) are device-independent touch units (Roblox reports the viewport in
	points); "design px" are the 1920x1080 layout units every screen is authored in. Convert with
	TouchLayout.pointsToDesign(points, ScreenManager.pointScale()).

	Connects to: Shared/Util/TouchLayout (pure geometry), UI/ScreenManager (touch close button),
	UI/Widgets/ModalShell (window fit), UI/Widgets/HudPlacement (HUD columns on phones).

	Example:
		local minTap = TouchLayout.pointsToDesign(TouchUIConfig.MinTapPoints, ScreenManager.pointScale())
]]

local TouchUIConfig = {}

-- Smallest comfortable finger target (Apple HIG / Material: 44-48 pt).
TouchUIConfig.MinTapPoints = 44

--[[
	Generic touch CLOSE button (only for a modal that draws no close button of its own; every
	StudUI window has its red X, so this is a safety net).
		ButtonPoints  square button side (≥ MinTapPoints)
		RightPoints   inset from the right edge of the screen
		ZIndex        drawn above the modal's own content
]]
TouchUIConfig.Close = table.freeze({
	ButtonPoints = 48,
	RightPoints = 12,
	ZIndex = 50,
})

--[[
	Modal window fit (ModalShell).
		DesktopMargin  design px kept free around a window on desktop / console
		TouchMargin    design px kept free on phones / tablets (windows use more of the screen)
		MinFit         never shrink a window below this fraction (text must stay readable);
		               content that still does not fit scrolls (StudUI windows use a
		               ScrollingFrame body when asked)
]]
TouchUIConfig.Modal = table.freeze({
	DesktopMargin = 48,
	TouchMargin = 16,
	MinFit = 0.55,
})

return table.freeze(TouchUIConfig)
