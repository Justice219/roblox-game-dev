--!strict
--[[
	OfferFxRules — pure math behind Widgets/OfferFx (the shared UI animation driver).

	Purpose:
		Keeps the driver's decisions testable in Lune without Instances:
			tierFor       Roblox SavedQualityLevel -> "Low" | "Medium" | "High"
			stepInterval  most-steps-per-second budget -> seconds between steps (math.huge = parked)
			clipRect      intersect a rect with a clip rect (ScrollingFrames, the screen)
			hasArea       true when a rect still covers a positive area

	Connects to: Shared/Config/OfferFxConfig, UI/Widgets/OfferFx.

	Example:
		OfferFxRules.tierFor(0) --> "High" (Automatic)
		OfferFxRules.stepInterval({ Low = 0, Medium = 30, High = 60 }, "Medium") --> 0.0333
]]

local OfferFxConfig = require(script.Parent.Parent.Config.OfferFxConfig)

local OfferFxRules = {}

--[[
	Graphics tier for a Roblox SavedQualityLevel (Enum value 0..10; 0 = Automatic, which the
	engine already scales down on weak devices, so it counts as High).
	@param level the numeric SavedQualityLevel value
	@return "Low" | "Medium" | "High"
]]
function OfferFxRules.tierFor(level: number): OfferFxConfig.Tier
	if level ~= level or level <= 0 then
		return "High"
	end
	if level <= OfferFxConfig.LowQualityMax then
		return "Low"
	end
	if level <= OfferFxConfig.MediumQualityMax then
		return "Medium"
	end
	return "High"
end

--[[
	Seconds between steps for a per-tier rate (steps per second). A rate of 0 (or invalid) parks
	the animation: math.huge means "never step".
	@param rates PerTier budget
	@param tier  current tier
	@return seconds between steps (math.huge when parked)
]]
function OfferFxRules.stepInterval(rates: OfferFxConfig.PerTier, tier: OfferFxConfig.Tier): number
	local hz = if tier == "Low" then rates.Low elseif tier == "Medium" then rates.Medium else rates.High
	if hz ~= hz or hz <= 0 then
		return math.huge
	end
	return 1 / hz
end

--[[
	Intersects rect (x0, y0)-(x1, y1) with clip rect (cx0, cy0)-(cx1, cy1).
	@return the clipped rect's four edges (may be empty: x1 <= x0 or y1 <= y0)
]]
function OfferFxRules.clipRect(
	x0: number,
	y0: number,
	x1: number,
	y1: number,
	cx0: number,
	cy0: number,
	cx1: number,
	cy1: number
): (number, number, number, number)
	return math.max(x0, cx0), math.max(y0, cy0), math.min(x1, cx1), math.min(y1, cy1)
end

--[[ True when the rect (x0, y0)-(x1, y1) covers a positive area. ]]
function OfferFxRules.hasArea(x0: number, y0: number, x1: number, y1: number): boolean
	return x1 > x0 and y1 > y0
end

return table.freeze(OfferFxRules)
