--!strict
--[[
	ItemFxLogic — pure maths behind the Shop's item idle animation and backing plates (owner R98:
	"the item in the shop should be animated. also they are hard to see with the stud
	background"). No Instances: every function is a plain function of its arguments, so
	tests/shop-item-fx.luau proves it under Lune.

		phase        stagger phase of item `index` on the card with seed `seed` (radians)
		pose         bob offset (design px, negative = up) + scale pulse at a time and phase
		glintOffset  where item `index` of `count` sits in the shared glint period (seconds)
		glint        sparkle size (0 = hidden .. 1) + rotation at a time and offset
		plateLook    the plate colours for a card colour preset (fill / ring / halo / shadow)
		parked       true when a per-tier rate parks the motion (Low graphics) or motion is reduced

	Connects to: Shared/Config/{ShopItemFxConfig (motion), UIStyleConfig (ItemPlate look)},
	Shared/Util/OfferFxRules (tier rates). Used by Screens/Shop/ItemFx.

	Example:
		local y, s = ItemFxLogic.pose(1.2, ItemFxLogic.phase(3, 2)) --> -2.1, 1.024 (say)
		local amount, rotation = ItemFxLogic.glint(3.3, 0)           --> 1, 45 (mid-glint)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local OfferFxRules = require(ReplicatedStorage.Shared.Util.OfferFxRules)
local ShopItemFxConfig = require(ReplicatedStorage.Shared.Config.ShopItemFxConfig)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

-- The colours of one plate (see UIStyleConfig.ItemPlate).
export type PlateLook = {
	fill: Color3, -- disc + name-plate fill (a deep shade of the card)
	ring: Color3, -- glow ring stroke (the card's light accent)
	halo: Color3, -- soft halo disc behind the plate (accent)
	shadow: Color3, -- drop shadow
}

local ItemFxLogic = {}

local TAU = 2 * math.pi
local Bob = ShopItemFxConfig.Bob
local Pulse = ShopItemFxConfig.Pulse
local Stagger = ShopItemFxConfig.Stagger
local Glint = ShopItemFxConfig.Glint

-- True for a usable time / number (rejects NaN and +/- inf).
local function finite(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

--[[
	Stagger phase of an item: cards differ by Stagger.CardRadians per seed step, items of a card
	by Stagger.ItemRadians, so neighbouring tiles ripple instead of moving together.
	@param seed  the card's seed (its LayoutOrder in the Shop list)
	@param index the item's index inside the card (1-based)
	@return radians in [0, 2pi)
	Example: ItemFxLogic.phase(0, 1) --> 0 ; ItemFxLogic.phase(0, 2) --> 1.1
]]
function ItemFxLogic.phase(seed: number, index: number): number
	local s = if finite(seed) then seed else 0
	local i = if finite(index) then index else 1
	return (s * Stagger.CardRadians + (i - 1) * Stagger.ItemRadians) % TAU
end

--[[
	The idle pose of an item at `elapsed` seconds: one sine drives both the bob (up to
	Bob.Pixels each way; negative = up, a UDim2 Y offset) and the pulse (1 +/- Pulse.Amount),
	so the item is largest at the top of its bob. Non-finite input rests the item.
	@param elapsed seconds the animation has run (OfferFx's elapsed: pauses while hidden)
	@param phase   radians (ItemFxLogic.phase)
	@return (offsetY design px, scale)
	Example: ItemFxLogic.pose(0, 0) --> 0, 1 (rest)
]]
function ItemFxLogic.pose(elapsed: number, phase: number): (number, number)
	if not finite(elapsed) or not finite(phase) then
		return 0, 1
	end
	local wave = math.sin(TAU * elapsed / Bob.PeriodSeconds + phase)
	return -Bob.Pixels * wave, 1 + Pulse.Amount * wave
end

--[[
	Where item `index` of `count` sits in the glint period: offsets spread evenly, so the glints
	of a rare card travel across its tiles one after another.
	@param index 1-based item index
	@param count items on the card (>= 1)
	@return seconds in [0, Glint.PeriodSeconds)
	Example: ItemFxLogic.glintOffset(2, 4) --> 0.9 (a quarter of a 3.6 s period)
]]
function ItemFxLogic.glintOffset(index: number, count: number): number
	local n = if finite(count) then math.max(1, math.floor(count)) else 1
	local i = if finite(index) then math.floor(index) else 1
	return ((i - 1) % n) / n * Glint.PeriodSeconds
end

--[[
	The sparkle glint at `elapsed`: it shows during the LAST Glint.Seconds of each period
	(shifted by `offset`), so nothing glints the instant the Shop opens. It pops in and out
	(size = sin(pi * progress)) while turning Glint.SweepDegrees.
	@param elapsed seconds the animation has run
	@param offset  seconds (ItemFxLogic.glintOffset)
	@return (amount 0..1 — 0 = hidden, rotation degrees)
	Example: ItemFxLogic.glint(3.3, 0) --> 1, 45 (the middle of the first glint)
]]
function ItemFxLogic.glint(elapsed: number, offset: number): (number, number)
	if not finite(elapsed) or not finite(offset) then
		return 0, 0
	end
	local period = Glint.PeriodSeconds
	local start = period - Glint.Seconds
	local t = (elapsed + offset) % period
	if t < start then
		return 0, 0
	end
	local progress = (t - start) / Glint.Seconds
	return math.sin(math.pi * progress), Glint.SweepDegrees * progress
end

-- Linear blend of two colours (component-wise; t clamped to 0..1).
local function mix(a: Color3, b: Color3, t: number): Color3
	local k = math.clamp(t, 0, 1)
	return Color3.new(a.R + (b.R - a.R) * k, a.G + (b.G - a.G) * k, a.B + (b.B - a.B) * k)
end

--[[
	The plate colours for a card colour preset: the fill is the card's lip pulled toward the
	dark Neutral.Well (UIStyleConfig.ItemPlate.FillDarken) — a deeper shade of the same card, so
	white outlined text reads on it; the ring + halo use the card's light accent (a glow in the
	card's colour); the shadow is Neutral.Shadow.
	@param preset a UIStyleConfig.Colors entry
	@return PlateLook (new table; callers cache it per colour)
	Example: ItemFxLogic.plateLook(UIStyleConfig.Colors.red).fill --> a deep crimson
]]
function ItemFxLogic.plateLook(preset: UIStyleConfig.Preset): PlateLook
	local neutral = UIStyleConfig.Neutral
	return {
		fill = mix(preset.lip, neutral.Well, UIStyleConfig.ItemPlate.FillDarken),
		ring = preset.accent,
		halo = preset.accent,
		shadow = neutral.Shadow,
	}
end

--[[
	True when the motion is parked: Reduce Motion is on, or the tier's rate is 0 (Low graphics).
	Parked items rest at their neutral pose.
	@param rates per-tier steps / s (ShopItemFxConfig.Hz)
	@param tier  "Low" | "Medium" | "High"
	@param reduced Reduce Motion (Roblox or SellNukes setting)
	Example: ItemFxLogic.parked(ShopItemFxConfig.Hz, "Low", false) --> true
]]
function ItemFxLogic.parked(rates: ShopItemFxConfig.PerTier, tier: "Low" | "Medium" | "High", reduced: boolean): boolean
	return reduced or OfferFxRules.stepInterval(rates, tier) == math.huge
end

return table.freeze(ItemFxLogic)
