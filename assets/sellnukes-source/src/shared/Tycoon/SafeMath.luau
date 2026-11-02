--!strict
--[[
	SafeMath — hostile-input number guards for the tycoon economy.

	Purpose
		The server calls TycoonLogic with values that came (indirectly) from saved profiles and
		remotes. A single NaN, inf, negative or non-number reaching the money maths could mint
		infinite cash or corrupt a save forever (NaN poisons every sum it touches). Every public
		TycoonLogic / Modifiers entry point funnels its numeric inputs through these helpers.

	Connections
		Used by `Shared/Tycoon/TycoonLogic` and `Shared/Tycoon/Modifiers`. Pure, no requires.

	Usage
		local SafeMath = require(script.Parent.SafeMath)
		local seconds = SafeMath.clamp(elapsed, 0, capSeconds, 0) -- NaN / "abc" -> 0
		local level = SafeMath.int(rawLevel, 0, MaxLevel)       -- 12.7 -> 12, -3 -> 0, inf -> 0
]]

local SafeMath = {}

--[[
	True when `x` is a real, finite number (not NaN, not +/-inf, not another type).
	@param x any — value to test
	@return boolean
	Example: SafeMath.isFinite(0 / 0) --> false; SafeMath.isFinite(5) --> true
]]
function SafeMath.isFinite(x: any): boolean
	-- NaN is the only value not equal to itself; math.huge bounds catch both infinities.
	return type(x) == "number" and x == x and x > -math.huge and x < math.huge
end

--[[
	Returns `x` when it is a finite number, else `default`.
	@param x any — untrusted value
	@param default number — fallback for NaN / inf / non-numbers
	@return number
	Example: SafeMath.num(nil, 1) --> 1
]]
function SafeMath.num(x: any, default: number): number
	if SafeMath.isFinite(x) then
		return x :: number
	end
	return default
end

--[[
	Finite-checks `x` (falling back to `default`) and clamps it into [lo, hi].
	@param x any — untrusted value
	@param lo number — inclusive lower bound
	@param hi number — inclusive upper bound
	@param default number — used when x is NaN / inf / not a number (then clamped too)
	@return number
	Example: SafeMath.clamp(-5, 0, 10, 0) --> 0; SafeMath.clamp(0/0, 0, 10, 3) --> 3
]]
function SafeMath.clamp(x: any, lo: number, hi: number, default: number): number
	local value = SafeMath.num(x, default)
	if value < lo then
		return lo
	elseif value > hi then
		return hi
	end
	return value
end

--[[
	Finite-checks, floors and clamps `x` into the integer range [lo, hi]. Non-finite -> lo.
	Used for levels, counts and rebirth numbers, which are always whole.
	@param x any — untrusted value
	@param lo number — inclusive lower bound (integer)
	@param hi number — inclusive upper bound (integer)
	@return number — an integer
	Example: SafeMath.int(7.9, 0, 5) --> 5; SafeMath.int(math.huge, 0, 5) --> 0
]]
function SafeMath.int(x: any, lo: number, hi: number): number
	local value = math.floor(SafeMath.num(x, lo))
	if value < lo then
		return lo
	elseif value > hi then
		return hi
	end
	return value
end

--[[
	A multiplier that is only ever a bonus: finite, >= 1 and <= `cap`. Anything else -> 1.
	Every global modifier in SellNukes is a bonus (nothing ever reduces income), so clamping at 1
	also neutralises negative / zero values a corrupted save could carry.
	@param x any — untrusted multiplier
	@param cap number — maximum allowed multiplier
	@return number
	Example: SafeMath.bonus(2, 1e6) --> 2; SafeMath.bonus(-3, 1e6) --> 1
]]
function SafeMath.bonus(x: any, cap: number): number
	return SafeMath.clamp(x, 1, cap, 1)
end

return SafeMath
