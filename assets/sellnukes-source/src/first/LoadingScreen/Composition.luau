--!strict
--[[
	Composition — pure layout math for the loading screen HUD (no Instances; Lune-tested).

	Purpose:
		The HUD is authored on a 1280 x 720 design canvas and scaled uniformly (one UIScale) to
		whatever screen the player has, so it is readable on a phone, crisp on a monitor and safe on
		a TV:
			- scale = the largest factor at which the canvas fits the available rect;
			- phones: a readability floor (MIN_SCALE) — the canvas may then be cropped by the
			  CanvasGroup edges, so the HUD is centred and its parts keep inner padding;
			- consoles / TVs (GuiService:IsTenFootInterface): a 5 % title-safe margin on every edge
			  before fitting.
		The rect passed in is already the DEVICE-SAFE rect (the HUD ScreenGui uses ScreenInsets =
		DeviceSafeInsets, so notches / home bars / the Roblox top bar are excluded by the engine).

	Example:
		local scale, width, height = Composition.fit(Vector2.new(844, 390), false)
		uiScale.Scale = scale
		root.Size = UDim2.fromOffset(width, height)
]]

local Composition = {}

-- Design canvas (units = px at scale 1).
Composition.DESIGN_WIDTH = 1280
Composition.DESIGN_HEIGHT = 720
-- Readability floor (phones) and ceiling (huge monitors).
Composition.MIN_SCALE = 0.5
Composition.MAX_SCALE = 2.4
-- TV title-safe margin (fraction of each edge).
Composition.TEN_FOOT_MARGIN = 0.05

--[[
	Fits the design canvas into `available` (px).
	@param available  the safe rect size in px
	@param tenFoot    true on consoles / TVs (adds the title-safe margin)
	@return scale, canvasWidth, canvasHeight  (canvas in design units: grows along the longer axis
	        so the HUD spans the whole rect at that scale; never smaller than the design canvas)
	Example: Composition.fit(Vector2.new(1920, 1080), false) --> 1.5, 1280, 720
]]
function Composition.fit(available: Vector2, tenFoot: boolean): (number, number, number)
	local width, height = math.max(available.X, 1), math.max(available.Y, 1)
	if tenFoot then
		width *= 1 - 2 * Composition.TEN_FOOT_MARGIN
		height *= 1 - 2 * Composition.TEN_FOOT_MARGIN
	end
	local scale = math.min(width / Composition.DESIGN_WIDTH, height / Composition.DESIGN_HEIGHT)
	scale = math.clamp(scale, Composition.MIN_SCALE, Composition.MAX_SCALE)
	local canvasWidth = math.max(Composition.DESIGN_WIDTH, width / scale)
	local canvasHeight = math.max(Composition.DESIGN_HEIGHT, height / scale)
	-- Below the floor the canvas would exceed the rect: keep it at the design size (centred).
	if Composition.DESIGN_WIDTH * scale > width or Composition.DESIGN_HEIGHT * scale > height then
		canvasWidth, canvasHeight = Composition.DESIGN_WIDTH, Composition.DESIGN_HEIGHT
	end
	return scale, canvasWidth, canvasHeight
end

--[[
	Smooth display value for a progress bar: moves `shown` toward `target` with an exponential
	ease (frame-rate independent), never backwards, snapping when close.
	@param shown   current displayed fraction 0..1
	@param target  real progress 0..1
	@param dt      seconds since the last frame
	@return the new displayed fraction
	Example: shown = Composition.approach(shown, tracker:progress(), dt)
]]
function Composition.approach(shown: number, target: number, dt: number): number
	if target <= shown then
		return shown
	end
	local blend = 1 - math.exp(-6 * math.max(dt, 0))
	local nextValue = shown + (target - shown) * blend
	if target - nextValue < 0.002 then
		return target
	end
	return nextValue
end

return Composition
