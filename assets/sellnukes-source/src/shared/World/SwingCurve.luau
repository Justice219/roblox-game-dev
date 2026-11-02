--!strict
--[[
	SwingCurve — the pure maths behind WorldFx "swing" motions (owner R75: "animate the miners ...
	they don't actually do anything"): a keyframed angle loop with per-segment easing (a pickaxe
	wind-up, a fast strike, a recoil, a pause), the gentle sine sway Reduce Motion uses instead,
	and a wrap-aware "did the loop pass this fraction" test for impact events (chips, clink, glow).

	Pure (no Instances, no services): used by Client/Tycoon/Fx/WorldFxController each frame and
	unit-tested by tests/world-fx-swing.luau. Keys are authored in Shared/Config/WorldFxConfig rows.

	Key format: { t = fraction of the period (0..1), angle = degrees, ease = "in" | "out" | "inout" }
		`ease` shapes the segment that ENDS at this key: "in" accelerates into it (a strike), "out"
		decelerates into it (a recoil settling), "inout" / nil is a smooth step. The first key must
		be t = 0 and the last t = 1 with the same angle, so the loop joins without a jump.

	Example:
		local keys = { { t = 0, angle = 0 }, { t = 0.4, angle = 45 }, { t = 0.5, angle = -80, ease = "in" }, { t = 1, angle = 0 } }
		SwingCurve.angle(keys, 0.45) --> about -17 (half-way through the accelerating strike)
		SwingCurve.crossed(0.49, 0.51, 0.5) --> true
]]

export type Key = { t: number, angle: number, ease: string? }
export type Gentle = { amplitude: number, period: number }

local SwingCurve = {}

--[[
	Easing of one segment.
	@param kind "in" | "out" | "inout" | nil
	@param u number in [0, 1]
	@return number in [0, 1]
]]
function SwingCurve.ease(kind: string?, u: number): number
	if kind == "in" then
		return u * u -- accelerating (a strike gathers speed into the rock)
	elseif kind == "out" then
		return 1 - (1 - u) * (1 - u) -- decelerating (a recoil comes to rest)
	end
	return u * u * (3 - 2 * u) -- smooth step
end

--[[
	Angle of a keyframed loop at fraction u.
	@param keys {Key} sorted by t, first t = 0, last t = 1 (see the module header)
	@param u number fraction of the period; wrapped into [0, 1)
	@return number degrees
]]
function SwingCurve.angle(keys: { Key }, u: number): number
	local count = #keys
	if count == 0 then
		return 0
	end
	local f = u % 1
	for i = 1, count - 1 do
		local a, b = keys[i], keys[i + 1]
		if f >= a.t and f <= b.t then
			local span = b.t - a.t
			local s = if span > 0 then (f - a.t) / span else 1
			return a.angle + (b.angle - a.angle) * SwingCurve.ease(b.ease, s)
		end
	end
	return keys[count].angle
end

--[[
	Reduce Motion's replacement: a slow, small sine sway (no strike, no impact).
	@param gentle Gentle  amplitude (degrees) + period (seconds)
	@param time number    seconds (controller clock + the owner's phase)
	@return number degrees
]]
function SwingCurve.gentleAngle(gentle: Gentle, time: number): number
	return gentle.amplitude * math.sin(2 * math.pi * time / gentle.period)
end

--[[
	True when a loop moving forward from fraction `last` to `now` (both in [0, 1), wrapping at 1)
	passed `at` on this step (at = last excluded, at = now included). A negative `last` means "not
	armed yet" (first frame / just came back into range) and never fires.
	@return boolean
]]
function SwingCurve.crossed(last: number, now: number, at: number): boolean
	if last < 0 then
		return false
	end
	if last <= now then
		return last < at and at <= now
	end
	return at > last or at <= now -- wrapped past 1 this step
end

--[[
	Problems with a key list (empty = valid): at least two keys, sorted strictly by t, first t = 0,
	last t = 1, first and last angle equal (seamless loop), finite angles within ±maxAngle, known
	ease names.
	@param keys any (untrusted config table)
	@param maxAngle number? default 150
	@return {string}
]]
function SwingCurve.validate(keys: any, maxAngle: number?): { string }
	local problems: { string } = {}
	local limit = maxAngle or 150
	if type(keys) ~= "table" or #keys < 2 then
		return { "keys: needs at least two keys" }
	end
	for i, key in keys do
		if type(key) ~= "table" or type(key.t) ~= "number" or type(key.angle) ~= "number" then
			table.insert(problems, `keys[{i}]: needs numeric t and angle`)
			continue
		end
		if key.angle ~= key.angle or math.abs(key.angle) > limit then
			table.insert(problems, `keys[{i}]: angle {key.angle} outside ±{limit}`)
		end
		if key.ease ~= nil and key.ease ~= "in" and key.ease ~= "out" and key.ease ~= "inout" then
			table.insert(problems, `keys[{i}]: unknown ease {tostring(key.ease)}`)
		end
		if i > 1 and type(keys[i - 1]) == "table" and type(keys[i - 1].t) == "number" and key.t <= keys[i - 1].t then
			table.insert(problems, `keys[{i}]: t must rise strictly`)
		end
	end
	local first, last = keys[1], keys[#keys]
	if type(first) == "table" and first.t ~= 0 then
		table.insert(problems, "keys: first t must be 0")
	end
	if type(last) == "table" and last.t ~= 1 then
		table.insert(problems, "keys: last t must be 1")
	end
	if type(first) == "table" and type(last) == "table" and first.angle ~= last.angle then
		table.insert(problems, "keys: first and last angle must match (seamless loop)")
	end
	return problems
end

return SwingCurve
