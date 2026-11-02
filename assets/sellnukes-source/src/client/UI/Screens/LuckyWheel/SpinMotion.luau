--!strict
--[[
	SpinMotion — the pure maths behind the Lucky Wheel spin (owner R81 "ticker effect and more
	effects"): the launch + slowdown curve, the wind-up / rock-back easing, peg crossings (one tick
	each), the ticker flapper's spring, and the small helpers the FX driver reads every frame.

	No Instances, no services, no requires: every function is a plain function of its arguments,
	so tests/lucky-wheel-fx.luau runs the shipped code under Lune (tick schedule, landing between
	pegs, flapper limits, no NaN at any frame rate).

	Angles are degrees clockwise from the top (the disc's CanvasGroup.Rotation); speeds are
	degrees / second. A rim peg sits at every multiple of `spacing` in disc space, so a peg is
	under the top pointer whenever the disc rotation R is a multiple of `spacing`: the disc crosses
	a peg each time R passes one (SpinMotion.crossings).

	The spin curve (SpinMotion.plan / sample):
		launch  0 → top speed with constant acceleration in `launch` s
		slow    ω(u) = top · (1 − u)^power over `decel` s (u = 0 → 1): a long, slowing tail, so the
		        ticks space out by themselves and the last ones crawl over the pegs
		top speed is solved so the curve ends exactly on `to` with zero speed:
			distance = top · launch / 2 + top · decel / (power + 1)

	Connects to: Screens/LuckyWheel/WheelFx (the per-frame driver), Shared/Config/LuckyWheelFxConfig
	(the numbers the driver passes in), tests/lucky-wheel-fx.luau.

	Example:
		local plan = SpinMotion.plan(337.5, 2137.5, 0.22, 3.78, 1.6)
		local angle, speed = SpinMotion.sample(plan, 1.0)
		local ticks = SpinMotion.crossings(previousAngle, angle, 45)
]]

export type Plan = {
	from: number, -- rotation at t = 0
	to: number, -- rotation at the end (speed 0)
	launch: number, -- seconds accelerating
	decel: number, -- seconds slowing down
	power: number, -- slowdown exponent
	top: number, -- top speed (deg/s), reached at t = launch
	launchDistance: number, -- degrees covered while accelerating
}

-- The ticker flapper's state: its Rotation (degrees; + = clockwise, the tip swings LEFT;
-- − = anticlockwise, the tip swings RIGHT, the way a clockwise disc pushes it) and its angular
-- velocity (deg/s).
export type Flapper = { angle: number, velocity: number }

-- Flapper tuning (LuckyWheelFxConfig.Flapper).
export type FlapperTuning = {
	MaxDeflect: number,
	Contact: number,
	Stiffness: number,
	Damping: number,
	HitFraction: number,
}

-- Longest spring integration sub-step (s): keeps the stiff spring stable at 20 fps.
local MAX_SUBSTEP = 1 / 240
-- Most sub-steps per call (a 0.5 s hitch is integrated as 1/240 s steps up to this cap).
local MAX_SUBSTEPS = 120

local SpinMotion = {}

-- x clamped into [lo, hi].
local function clamp(x: number, lo: number, hi: number): number
	if x < lo then
		return lo
	elseif x > hi then
		return hi
	end
	return x
end

--[[
	Smoothstep ease 0 → 1 (zero speed at both ends).
	@param u progress (clamped to 0..1)
	Example: SpinMotion.smooth(0.5) --> 0.5
]]
function SpinMotion.smooth(u: number): number
	local x = clamp(u, 0, 1)
	return x * x * (3 - 2 * x)
end

--[[
	Builds a spin from `from` to `to` (see the module header).
	@param from   rotation now (e.g. the wound-back pose)
	@param to     final rotation (≥ from; a backwards plan is flattened to a stop)
	@param launch seconds to reach top speed (≥ 0)
	@param decel  seconds of slowdown (> 0)
	@param power  slowdown exponent (≥ 0; 1 = constant deceleration)
	@return Plan
	Example: SpinMotion.plan(0, 1800, 0.2, 3.8, 1.6).top --> ≈ 1171
]]
function SpinMotion.plan(from: number, to: number, launch: number, decel: number, power: number): Plan
	local distance = math.max(0, to - from)
	local launchT = math.max(0, launch)
	local decelT = math.max(1e-3, decel)
	local p = math.max(0, power)
	local top = distance / (launchT / 2 + decelT / (p + 1))
	return {
		from = from,
		to = from + distance,
		launch = launchT,
		decel = decelT,
		power = p,
		top = top,
		launchDistance = top * launchT / 2,
	}
end

--[[
	Total seconds of a plan.
	@param plan Plan
	@return number
]]
function SpinMotion.duration(plan: Plan): number
	return plan.launch + plan.decel
end

--[[
	Rotation and speed of a plan at time `t` (clamped to the plan: before 0 = start, after the
	end = `to` at rest).
	@param plan Plan
	@param t    seconds since the launch
	@return (rotation, speed in deg/s)
	Example: local r, w = SpinMotion.sample(plan, plan.launch) -- w == plan.top
]]
function SpinMotion.sample(plan: Plan, t: number): (number, number)
	if t <= 0 then
		return plan.from, 0
	end
	if t < plan.launch then
		-- Constant acceleration: v = top · t / launch, θ = top · t² / (2 · launch).
		return plan.from + plan.top * t * t / (2 * plan.launch), plan.top * t / plan.launch
	end
	local s = t - plan.launch
	if s >= plan.decel then
		return plan.to, 0
	end
	local rest = 1 - s / plan.decel
	local p1 = plan.power + 1
	-- ∫ top · (1 − u)^p dt = top · decel · (1 − (1 − u)^(p+1)) / (p + 1)
	local angle = plan.from + plan.launchDistance + plan.top * plan.decel * (1 - rest ^ p1) / p1
	return angle, plan.top * rest ^ plan.power
end

--[[
	Eases from `from` to `to` over `seconds` (smoothstep): the wind-up pull-back, the hold → unwind
	after a refused spin, and the rock-back from the overshoot. Starting from the CURRENT offset
	keeps every hand-over continuous (a wind-up pressed mid-rock-back never jumps).
	@param from    value at t = 0
	@param to      value from t = seconds on
	@param t       seconds since the start
	@param seconds length (≤ 0 = already at `to`)
	Example: SpinMotion.blend(0, -16, 0.15, 0.3) --> -8
]]
function SpinMotion.blend(from: number, to: number, t: number, seconds: number): number
	if seconds <= 0 then
		return to
	end
	return from + (to - from) * SpinMotion.smooth(t / seconds)
end

--[[
	"Back" ease-out 0 → 1 with a small overshoot (the reward pop's punch-in). 1 from u ≥ 1 on.
	@param u progress (clamped to 0..1)
	Example: SpinMotion.backOut(1) --> 1
]]
function SpinMotion.backOut(u: number): number
	local x = clamp(u, 0, 1) - 1
	local c1 = 1.70158
	return 1 + (c1 + 1) * x * x * x + c1 * x * x
end

--[[
	Degrees between two neighbouring pegs.
	@param count     slices on the wheel
	@param perSlice  pegs per slice (odd keeps the slice centre between pegs)
	Example: SpinMotion.pegSpacing(8, 1) --> 45
]]
function SpinMotion.pegSpacing(count: number, perSlice: number): number
	return 360 / (math.max(1, count) * math.max(1, perSlice))
end

--[[
	Signed number of pegs that passed the pointer while the rotation went `previous` → `current`
	(+ forwards / clockwise, − backwards). Landing exactly on a peg counts it as passed.
	@param previous rotation last frame
	@param current  rotation now
	@param spacing  degrees between pegs
	Example: SpinMotion.crossings(40, 95, 45) --> 2
]]
function SpinMotion.crossings(previous: number, current: number, spacing: number): number
	return math.floor(current / spacing) - math.floor(previous / spacing)
end

--[[
	Steps the ticker flapper by `dt` seconds (mutates `state`).
	1. A damped spring pulls the flapper towards 0 (sub-stepped: stable at any frame rate).
	2. A peg that crossed during this frame (fast spin) knocks the tip aside to
	   HitFraction × MaxDeflect (against the motion: forwards = negative).
	3. The peg BEHIND the tip in the motion direction pushes it while it is within `Contact`
	   degrees of the top: forwards that is the next peg (gap = spacing − R mod spacing, pushing the
	   tip right = negative rotation), backwards the last one (gap = R mod spacing, positive). The
	   push grows to MaxDeflect at the moment the peg slips past; the peg holds the tip (speed 0).
	@param state     Flapper (mutated)
	@param rotation  disc rotation now
	@param direction +1 disc moving clockwise, −1 anticlockwise (wind-up / rock-back), 0 none
	@param crossed   SpinMotion.crossings for this frame
	@param dt        seconds since the last step
	@param spacing   degrees between pegs
	@param tuning    FlapperTuning
	Example: SpinMotion.stepFlapper(flap, 44, 1, 0, 1/60, 45, LuckyWheelFxConfig.Flapper)
]]
function SpinMotion.stepFlapper(
	state: Flapper,
	rotation: number,
	direction: number,
	crossed: number,
	dt: number,
	spacing: number,
	tuning: FlapperTuning
)
	local step = math.max(0, dt)
	if step > 0 then
		local count = math.clamp(math.ceil(step / MAX_SUBSTEP), 1, MAX_SUBSTEPS)
		local h = step / count
		local angle, velocity = state.angle, state.velocity
		for _ = 1, count do
			-- Semi-implicit Euler: velocity first, then position (energy-stable for springs).
			velocity += (-tuning.Stiffness * angle - tuning.Damping * velocity) * h
			angle += velocity * h
		end
		state.angle, state.velocity = angle, velocity
	end
	local maxDeflect = tuning.MaxDeflect
	if crossed > 0 then
		local knocked = -maxDeflect * tuning.HitFraction
		if state.angle > knocked then
			state.angle, state.velocity = knocked, 0
		end
	elseif crossed < 0 then
		local knocked = maxDeflect * tuning.HitFraction
		if state.angle < knocked then
			state.angle, state.velocity = knocked, 0
		end
	end
	if tuning.Contact <= 0 or spacing <= 0 then
		return
	end
	local phase = rotation % spacing -- Luau % is floored: phase ∈ [0, spacing)
	if direction > 0 then
		local gap = spacing - phase
		if gap < tuning.Contact then
			local push = -maxDeflect * (1 - gap / tuning.Contact)
			if state.angle > push then
				state.angle, state.velocity = push, 0
			end
		end
	elseif direction < 0 then
		local gap = phase
		if gap < tuning.Contact then
			local push = maxDeflect * (1 - gap / tuning.Contact)
			if state.angle < push then
				state.angle, state.velocity = push, 0
			end
		end
	end
end

--[[
	True when the flapper has come to rest (nothing left to animate).
	Example: SpinMotion.flapperResting({ angle = 0.01, velocity = 0.1 }) --> true
]]
function SpinMotion.flapperResting(state: Flapper): boolean
	return math.abs(state.angle) < 0.05 and math.abs(state.velocity) < 0.5
end

--[[
	Speed as a 0..1 fraction of `top` (absolute value; non-finite → 0).
	Example: SpinMotion.speedNorm(-650, 1300) --> 0.5
]]
function SpinMotion.speedNorm(speed: number, top: number): number
	if speed ~= speed or top <= 0 then
		return 0
	end
	return clamp(math.abs(speed) / top, 0, 1)
end

--[[
	Linear interpolation inside `range` ({ Min, Max }) at fraction `u` (clamped).
	Example: SpinMotion.lerpRange({ Min = 0.8, Max = 1.4 }, 0.5) --> 1.1
]]
function SpinMotion.lerpRange(range: { Min: number, Max: number }, u: number): number
	return range.Min + (range.Max - range.Min) * clamp(u, 0, 1)
end

--[[
	Motion-arc opacity for a speed: 0 below `start`, `maxOpacity` from `full`, linear between,
	rounded to `step` (so a steady speed produces the same value and no property writes).
	Example: SpinMotion.streakOpacity(580, 260, 900, 0.5, 0.05) --> 0.25
]]
function SpinMotion.streakOpacity(speed: number, start: number, full: number, maxOpacity: number, step: number): number
	if speed ~= speed or full <= start then
		return 0
	end
	local u = clamp((math.abs(speed) - start) / (full - start), 0, 1)
	return SpinMotion.quantize(u * maxOpacity, step)
end

--[[
	`x` rounded to the nearest multiple of `step` (step ≤ 0 returns x).
	Example: SpinMotion.quantize(0.237, 0.05) --> 0.25
]]
function SpinMotion.quantize(x: number, step: number): number
	if step <= 0 then
		return x
	end
	return math.floor(x / step + 0.5) * step
end

--[[
	Is bulb `index` lit at chase step `chaseStep`? Every `group`-th bulb is lit and the lit set
	moves clockwise (to higher indices) as the step grows.
	Example: SpinMotion.bulbLit(4, 1, 3) --> true
]]
function SpinMotion.bulbLit(index: number, chaseStep: number, group: number): boolean
	return (index - chaseStep) % math.max(1, group) == 0
end

--[[
	Win glow strength 0..1 at `t` seconds into a `seconds` celebration: fades in over 0.12 s and out
	over the last 0.35 s, pulsing at `hz` between 35 % and 100 % in between. 0 outside the window.
	Example: SpinMotion.pulse(0.5, 2, 2) --> 1
]]
function SpinMotion.pulse(t: number, seconds: number, hz: number): number
	if t < 0 or t >= seconds then
		return 0
	end
	local envelope = math.min(1, t / 0.12, (seconds - t) / 0.35)
	local wave = 0.5 + 0.5 * math.cos(2 * math.pi * hz * t)
	return clamp(envelope * (0.35 + 0.65 * wave), 0, 1)
end

--[[
	Rays opacity factor 0..1: fade in over `fadeIn`, hold, fade out over the last `fadeOut` s.
	Example: SpinMotion.fade(1, 2, 0.25, 0.5) --> 1
]]
function SpinMotion.fade(t: number, seconds: number, fadeIn: number, fadeOut: number): number
	if t < 0 or t >= seconds then
		return 0
	end
	local inU = if fadeIn > 0 then t / fadeIn else 1
	local outU = if fadeOut > 0 then (seconds - t) / fadeOut else 1
	return clamp(math.min(1, inU, outU), 0, 1)
end

--[[
	Is the win blink "on" at `t` seconds (on / off halves at `hz` blinks per second)?
	Example: SpinMotion.blinkOn(0.05, 5) --> true
]]
function SpinMotion.blinkOn(t: number, hz: number): boolean
	if hz <= 0 then
		return true
	end
	return math.floor(t * hz * 2) % 2 == 0
end

--[[
	Wheel shake offset (design px) `t` seconds into a `seconds` shake of `amplitude` px: two
	unrelated sines (no repeating pattern) under a quadratic decay. (0, 0) when done.
	Example: local x, y = SpinMotion.shake(0.1, 0.45, 8)
]]
function SpinMotion.shake(t: number, seconds: number, amplitude: number): (number, number)
	if t < 0 or t >= seconds or amplitude <= 0 or seconds <= 0 then
		return 0, 0
	end
	local decay = (1 - t / seconds) ^ 2
	return amplitude * decay * math.sin(t * 2 * math.pi * 13), amplitude * decay * 0.6 * math.cos(t * 2 * math.pi * 17)
end

--[[
	Is a spin pressed at `now` a back-to-back one (within `window` s of the last landing)?
	@param now           os.clock() at the press
	@param lastLandedAt  os.clock() of the last landing (−math.huge = never)
	Example: SpinMotion.isQuick(10, 5, 8) --> true
]]
function SpinMotion.isQuick(now: number, lastLandedAt: number, window: number): boolean
	return now - lastLandedAt <= window
end

return table.freeze(SpinMotion)
