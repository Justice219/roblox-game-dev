--!strict
--[[
	ShopItemFxConfig — tunables of the Shop's item idle animation (owner R98: "the item in the
	shop should be animated"): every pack tile / card item gently bobs and pulses over its
	backing plate, staggered so a row never moves in lock-step, and rare items (the pack pets,
	every Secret Pack tile, pet / egg / crate cards) get an occasional sparkle glint.

	Purpose:
		Presentation numbers only (never a price or reward). Steps run on the ONE shared UI
		driver (Widgets/OfferFx): `Hz` is the most steps per second per graphics tier — Low
		graphics parks the motion entirely (rate 0) and Reduce Motion (Roblox setting or the
		SellNukes `settings.reducedMotion` flag) parks it too; parked items rest at their
		neutral pose (no offset, scale 1, glint hidden).

		The plate LOOK (colours, transparency, ring, shadow) lives in UIStyleConfig.ItemPlate.

	Connects to: Screens/Shop/ItemFxLogic (pure maths), Screens/Shop/ItemFx (instances + the
	OfferFx animator), tests/shop-item-fx.luau.

	Example:
		ShopItemFxConfig.Bob.Pixels --> 3 (design px up and down)
]]

export type PerTier = { Low: number, Medium: number, High: number }

return table.freeze({
	-- Most steps per second per graphics tier (Low = parked: the items rest, still).
	Hz = table.freeze({ Low = 0, Medium = 20, High = 30 }) :: PerTier,
	-- Vertical bob: design px each way (scaled with the Shop's content scale) and its period.
	Bob = table.freeze({
		Pixels = 3,
		PeriodSeconds = 2.4,
	}),
	-- Scale pulse, in step with the bob (largest at the top of the bob): 1 +/- Amount.
	Pulse = table.freeze({
		Amount = 0.035,
	}),
	-- Stagger: phase step between neighbouring items of one card, and between cards (radians),
	-- so a row of tiles ripples instead of moving in lock-step.
	Stagger = table.freeze({
		ItemRadians = 1.1,
		CardRadians = 0.7,
	}),
	-- Sparkle glint on rare items: one glint every PeriodSeconds per item, lasting Seconds, a
	-- quick pop (scale 0 -> 1 -> 0) while it turns SweepDegrees. Items of one card spread their
	-- glints evenly over the period, so a glint travels across a rare pack.
	Glint = table.freeze({
		PeriodSeconds = 3.6,
		Seconds = 0.6,
		SweepDegrees = 90,
		-- Glint size (share of the item slot) and where it sits on the item (slot scale).
		Size = 0.34,
		X = 0.8,
		Y = 0.2,
		-- Thickness of the two crossed rays (share of the glint's size).
		RayWidth = 0.16,
	}),
	-- Skip a property write when the value moved less than this since the last write
	-- (sub-pixel / sub-0.1 % changes are invisible; saves writes on every step).
	WriteEpsilon = table.freeze({
		Pixels = 0.05,
		Scale = 0.0008,
	}),
})
