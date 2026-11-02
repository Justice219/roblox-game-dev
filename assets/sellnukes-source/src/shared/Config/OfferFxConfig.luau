--!strict
--[[
	OfferFxConfig — budgets of the ONE shared UI animation driver (Widgets/OfferFx) and of the
	animated stud decorations it runs (topbar stud drift, starburst spin, sunburst spin, shine).

	Purpose:
		Presentation numbers only (never a price or reward). Rates are "most steps per second"
		per graphics tier: Low graphics parks motion entirely (the art stays, static), Medium /
		High step at the listed rate. Reduce Motion (Roblox setting or the SellNukes
		`settings.reducedMotion` profile flag) also parks every animation.

	Connects to: UI/Widgets/OfferFx (driver), Shared/Util/OfferFxRules (pure math),
	UI/Widgets/PanelBackdrop (topbar drift), UI/Kit/StudUI (starburst + sunburst spin).

	Example: OfferFxConfig.Starburst.DegreesPerSecond --> 14
]]

export type Tier = "Low" | "Medium" | "High"
export type PerTier = { Low: number, Medium: number, High: number }

return table.freeze({
	-- Seconds between visibility re-checks of every registered animation (one shared thread).
	VisibilityCheckSeconds = 0.25,
	-- Roblox SavedQualityLevel (1..10, 0 = Automatic) at or below which the tier is Low / Medium.
	LowQualityMax = 3,
	MediumQualityMax = 6,
	-- Topbar / header stud drift (window headers): design px per second, leftward.
	TopbarDrift = table.freeze({
		PixelsPerSecond = 26,
		Hz = table.freeze({ Low = 0, Medium = 30, High = 60 }) :: PerTier,
	}),
	-- The dark spiky starburst behind every right-column Robux offer.
	Starburst = table.freeze({
		DegreesPerSecond = 14,
		Hz = table.freeze({ Low = 0, Medium = 20, High = 30 }) :: PerTier,
	}),
	-- The light sunburst behind card / offer icons.
	Sunburst = table.freeze({
		DegreesPerSecond = 10,
		Hz = table.freeze({ Low = 0, Medium = 20, High = 30 }) :: PerTier,
	}),
	-- Shine sweep across "buy" buttons and rainbow cards: one sweep every Period seconds.
	Shine = table.freeze({
		PeriodSeconds = 3.2,
		SweepSeconds = 0.7,
		Hz = table.freeze({ Low = 0, Medium = 30, High = 60 }) :: PerTier,
	}),
	-- Rainbow surfaces (Day 7 card, Lucky Wheel button): hue drift of the gradient.
	Rainbow = table.freeze({
		DegreesPerSecond = 40,
		Hz = table.freeze({ Low = 0, Medium = 20, High = 30 }) :: PerTier,
	}),
})
