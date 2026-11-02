--!strict
--[[
	MathUtil — small numeric helpers shared by camera, build-in FX, economy and validation code
	(copied from RoBeasts).

	Kept free of Instance access so it is safe everywhere (server, client, parallel).

	Example:
		local alpha = MathUtil.damp(12, dt)              -- frame-rate independent smoothing factor
		smoothed = smoothed:Lerp(target, alpha)
		local flat = MathUtil.flatten(camera.CFrame.LookVector)  -- horizontal unit vector
]]

local MathUtil = {}

--[[ Clamps x into [lo, hi]. ]]
function MathUtil.clamp(x: number, lo: number, hi: number): number
	if x < lo then
		return lo
	elseif x > hi then
		return hi
	end
	return x
end

--[[ Linear interpolation between a and b by t (not clamped). ]]
function MathUtil.lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

--[[
	Frame-rate independent smoothing factor for exponential decay.
	Use as `value = lerp(value, target, damp(speed, dt))`. Higher speed = snappier.
	Returns a value in [0, 1).
]]
function MathUtil.damp(speed: number, dt: number): number
	return 1 - math.exp(-speed * dt)
end

--[[ Moves `current` toward `target` by at most `maxDelta`. ]]
function MathUtil.approach(current: number, target: number, maxDelta: number): number
	if current < target then
		return math.min(current + maxDelta, target)
	end
	return math.max(current - maxDelta, target)
end

--[[ True when n is a real, finite number (rejects NaN and ±inf). ]]
function MathUtil.isFinite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

--[[ True when every component of v is finite. ]]
function MathUtil.isFiniteVector3(v: Vector3): boolean
	return MathUtil.isFinite(v.X) and MathUtil.isFinite(v.Y) and MathUtil.isFinite(v.Z)
end

--[[
	Projects v onto the horizontal (XZ) plane and normalizes it.
	Returns Vector3.zero when v is (nearly) vertical, so callers never get NaN.
]]
function MathUtil.flatten(v: Vector3): Vector3
	local flat = Vector3.new(v.X, 0, v.Z)
	local magnitude = flat.Magnitude
	if magnitude < 1e-5 then
		return Vector3.zero
	end
	return flat / magnitude
end

--[[ Unit vector of v, or `fallback` (default zero) if v is too short to normalize safely. ]]
function MathUtil.safeUnit(v: Vector3, fallback: Vector3?): Vector3
	local magnitude = v.Magnitude
	if magnitude < 1e-5 or not MathUtil.isFinite(magnitude) then
		return fallback or Vector3.zero
	end
	return v / magnitude
end

--[[
	Yaw angle (radians) of a horizontal direction, matching Roblox's convention where
	CFrame.Angles(0, yaw, 0).LookVector == direction (LookVector is -Z at yaw 0).
]]
function MathUtil.yawFromDirection(direction: Vector3): number
	return math.atan2(-direction.X, -direction.Z)
end

--[[ Horizontal unit look direction for a yaw angle (inverse of yawFromDirection). ]]
function MathUtil.directionFromYaw(yaw: number): Vector3
	return Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
end

--[[ Wraps an angle to (-pi, pi]. ]]
function MathUtil.wrapAngle(angle: number): number
	local wrapped = (angle + math.pi) % (2 * math.pi) - math.pi
	if wrapped <= -math.pi then
		wrapped += 2 * math.pi
	end
	return wrapped
end

--[[ Rotates angle `current` toward `target` by at most `maxDelta`, taking the short way round. ]]
function MathUtil.approachAngle(current: number, target: number, maxDelta: number): number
	local delta = MathUtil.wrapAngle(target - current)
	if math.abs(delta) <= maxDelta then
		return target
	end
	return current + math.sign(delta) * maxDelta
end

--[[ Clamps a vector's magnitude to at most maxLength (direction preserved). ]]
function MathUtil.clampMagnitude(v: Vector3, maxLength: number): Vector3
	local magnitude = v.Magnitude
	if magnitude > maxLength and magnitude > 0 then
		return v * (maxLength / magnitude)
	end
	return v
end

return table.freeze(MathUtil)
