--!strict
--[[
	DeviceConfig — device classification and UI-scale tunables (ported from RoBeasts wave 7).

	Purpose:
		SellNukes screens are designed at 1920x1080 "design px" and scaled to the viewport by one
		UIScale per ScreenGui (ScreenManager). Phones and tablets need a different scale policy than
		desktop windows:
			- Desktop: fit the whole design (min of the two axis ratios), floor 0.4.
			- Tablet:  the same fit-the-design formula with a higher floor (0.5).
			- Phone:   HEIGHT-led with a floor of 0.62 so text and buttons stay readable on a
			  ~390 pt tall landscape screen; the HUD re-flows into the wider design canvas
			  (HudPlacement) and windows shrink to fit (ModalShell).
			- Console: identical to Desktop (ten-foot UI, gamepad only).
		A device is a PHONE when the short side of its viewport is under `PhoneShortSide` points,
		a TABLET when its primary input is touch and it is not a phone, otherwise DESKTOP (touch
		laptops with a keyboard stay Desktop).

	Connects to: Shared/Util/DeviceProfile (classify + uiScale), Controllers/UIController (applies
	the scale through ScreenManager.setDeviceProfile).

	Example:
		local DeviceConfig = require(ReplicatedStorage.Shared.Config.DeviceConfig)
		print(DeviceConfig.Scale.Phone.min) --> 0.62
]]

-- What kind of screen the client runs on (DeviceProfile.classify). "Console" = ten-foot UI.
export type DeviceClass = "Phone" | "Tablet" | "Desktop" | "Console"

-- Per-class UI scale clamp (fractions of the 1080p design size).
export type ScaleLimits = { min: number, max: number }

local DeviceConfig = {}

-- The resolution every screen is laid out at (design px).
DeviceConfig.DesignWidth = 1920
DeviceConfig.DesignHeight = 1080

-- A viewport whose short side is below this (points) is a phone. 600 pt is the usual
-- phone / small-tablet boundary (largest phones ~430-440 pt, smallest tablets ~744 pt).
DeviceConfig.PhoneShortSide = 600

--[[
	UI scale clamps per device class.
		Desktop min 0.4: keeps the full design visible down to ~770x430 windows.
		Tablet  min 0.5: only lifts tiny split-screen windows into readable territory.
		Phone   min 0.62: ≈11 pt for the smallest (18 px) body text and ≥44 pt for 72 px buttons.
		Console min 0.4: same as Desktop (a 1080p TV gives ~1.0 anyway).
		Console max 2.0: a 4K-POINT ten-foot viewport (3840x2160, Android TV / consoles at 4K)
		  must keep the 1080p proportions (B16 device matrix 2026-10-30: at 1.25 the HUD shrank to
		  ~62 % with tiles hugging the edges).
		max 1.25 elsewhere: huge desktop monitors do not get comically large UI.
]]
DeviceConfig.Scale = table.freeze({
	Desktop = table.freeze({ min = 0.4, max = 1.25 }) :: ScaleLimits,
	Tablet = table.freeze({ min = 0.5, max = 1.25 }) :: ScaleLimits,
	Phone = table.freeze({ min = 0.62, max = 1.25 }) :: ScaleLimits,
	Console = table.freeze({ min = 0.4, max = 2.0 }) :: ScaleLimits,
})

return table.freeze(DeviceConfig)
