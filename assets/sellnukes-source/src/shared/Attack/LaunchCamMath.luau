--!strict
--[[
	LaunchCamMath — the pure maths of the launch cinematic (owner R54): countdown beats, punch-in
	curves, the camera shots (silo / chase / impact / Reduce-Motion wide shot), the critically damped
	spring that smooths the chase, deterministic shake, and the overlay burst / confetti paths.

	Why a separate module: Client/Attack/LaunchCam (the director, RenderStepped) and
	UI/Screens/LaunchCountdown/CountdownOverlay only EVALUATE these functions each frame; keeping
	them pure (no services, no instances) lets tests/launch-cam.luau prove them under Lune: no NaN /
	inf for any input, continuity across every phase boundary, a skip always lands exactly on the
	player's camera, springs that converge and never explode on a long frame.

	Time base: `rel` = seconds after the flight's SERVER t0 (Workspace:GetServerTimeNow() - t0),
	negative while counting down — the same clock FlightRenderer draws the nuke with, so the camera
	and the nuke can never drift apart.

	Connects to: Shared/Config/LaunchCamConfig (every number), Shared/Attack/FlightMath (the arc the
	chase follows), Client/Attack/LaunchCam, UI/Screens/LaunchCountdown/CountdownOverlay,
	tests/launch-cam.luau.

	Example:
		local phase, step, elapsed, length = LaunchCamMath.countdown(-2.4, 1, { 3, 2, 1 }, 1)
		--> "count", 3, 0.6, 1
		local x, v = LaunchCamMath.spring(x, v, target, 4, dt)
]]

local AttackRng = require(script.Parent.AttackRng)
local FlightMath = require(script.Parent.FlightMath)

local LaunchCamMath = {}

local UP = Vector3.new(0, 1, 0)
local DEFAULT_FORWARD = Vector3.new(0, 0, -1)
local TAU = 2 * math.pi

-- One camera framing: where the eye is and what it looks at (world).
export type Pose = { eye: Vector3, focus: Vector3 }

-- The cinematic's schedule for one flight (all `rel` seconds).
export type Timeline = {
	duration: number, -- flight seconds (t0 → impact)
	endAt: number, -- the outcome: impact, or the interception (FlightRenderer's endAt)
	intercepted: boolean,
	chaseStart: number, -- the silo shot starts blending into the chase
	chaseFull: number, -- the chase is fully in
	approachAt: number, -- the camera starts easing into the impact shot
	holdUntil: number, -- the outcome hold ends (before any knockdown extension)
}

-- Config parameters are typed `any`: callers pass the frozen LaunchCamConfig tables
-- (Shots / Countdown / Reduced / Burst / Confetti) or test variants; every field is read through
-- `finite(...)` with a sane fallback, so a missing or junk field can never produce NaN.

--------------------------------------------------------------------------------------------------
-- Scalars
--------------------------------------------------------------------------------------------------

--[[ `value` when it is a finite number, else `fallback` (NaN / ±inf / non-numbers never leak). ]]
function LaunchCamMath.finite(value: unknown, fallback: number): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return fallback
	end
	return value
end

local finite = LaunchCamMath.finite

-- Clamps x (made finite) into [0, 1].
local function clamp01(x: number): number
	return math.clamp(finite(x, 0), 0, 1)
end

--[[ Smoothstep 3x² − 2x³ on [0, 1] (zero slope at both ends: blends start and stop gently). ]]
function LaunchCamMath.smoothstep(x: number): number
	local t = clamp01(x)
	return t * t * (3 - 2 * t)
end

--[[ Cubic ease-out (fast start, gentle stop). ]]
function LaunchCamMath.easeOutCubic(x: number): number
	local t = 1 - clamp01(x)
	return 1 - t * t * t
end

--[[ Cubic ease-in-out (zero slope at both ends; the return-to-player curve). ]]
function LaunchCamMath.easeInOutCubic(x: number): number
	local t = clamp01(x)
	if t < 0.5 then
		return 4 * t * t * t
	end
	local u = -2 * t + 2
	return 1 - u * u * u / 2
end

--[[
	Back-out ease: overshoots past 1 (to ≈ 1.1) then settles at exactly 1 — the "punch" of a
	countdown number landing.
]]
function LaunchCamMath.backOut(x: number): number
	local t = clamp01(x)
	local c1 = 1.70158
	local c3 = c1 + 1
	local u = t - 1
	return 1 + c3 * u * u * u + c1 * u * u
end

--[[ 1 → 0 linear decay over `seconds` starting at elapsed 0 (0 before the start and after it). ]]
function LaunchCamMath.decay(elapsed: number, seconds: number): number
	local e = finite(elapsed, -1)
	local s = finite(seconds, 0)
	if e < 0 or s <= 0 or e >= s then
		return 0
	end
	return 1 - e / s
end

--[[
	Deterministic 0..1 hash of (seed, index, salt) — the per-piece randomness of the overlay
	(identical every play, no Random object, no allocation). Two rounds of AttackRng.mix (murmur3
	fmix32 on bit32), so different salts of the same piece are independent (a linear hash made the
	confetti line up on one curve in Studio QA).
	@return number in [0, 1)
]]
function LaunchCamMath.hash01(seed: number, index: number, salt: number): number
	local h = AttackRng.mix(AttackRng.mix(finite(seed, 0), finite(index, 0)), finite(salt, 0) + 0x5BD1)
	return h / 4294967296
end

--------------------------------------------------------------------------------------------------
-- Vectors / poses
--------------------------------------------------------------------------------------------------

-- True when every component of v is finite.
local function finiteVector(v: Vector3): boolean
	return v.X == v.X
		and v.Y == v.Y
		and v.Z == v.Z
		and math.abs(v.X) < math.huge
		and math.abs(v.Y) < math.huge
		and math.abs(v.Z) < math.huge
end

LaunchCamMath.finiteVector = finiteVector

--[[ v's unit vector, or `fallback` when v is (near) zero or not finite. ]]
function LaunchCamMath.safeUnit(v: Vector3, fallback: Vector3): Vector3
	if not finiteVector(v) then
		return fallback
	end
	local m = v.Magnitude
	if m < 1e-6 then
		return fallback
	end
	return v / m
end

local safeUnit = LaunchCamMath.safeUnit

--[[ The horizontal travel direction from → to (unit, Y = 0); −Z when they share an XZ point. ]]
function LaunchCamMath.flatDir(from: Vector3, to: Vector3): Vector3
	local d = to - from
	return safeUnit(Vector3.new(d.X, 0, d.Z), DEFAULT_FORWARD)
end

--[[ The right-hand horizontal unit of a flat forward direction. ]]
local function rightOf(flat: Vector3): Vector3
	return safeUnit(flat:Cross(UP), Vector3.new(1, 0, 0))
end

--[[ Linear blend of two poses (each component continuous in w). ]]
function LaunchCamMath.blend(a: Pose, b: Pose, w: number): Pose
	local t = clamp01(w)
	if t <= 0 then
		return a
	end
	if t >= 1 then
		return b
	end
	return { eye = a.eye:Lerp(b.eye, t), focus = a.focus:Lerp(b.focus, t) }
end

--[[
	A camera CFrame at `eye` looking at `focus`, never degenerate: a coincident focus looks along
	`forward`, a (near-)vertical view gets a tiny horizontal nudge so lookAt's up vector stays valid,
	and non-finite input falls back to `forward` from the origin of the eye.
	@return CFrame — always finite
]]
function LaunchCamMath.lookAt(eye: Vector3, focus: Vector3, forward: Vector3?): CFrame
	local fallback = safeUnit(forward or DEFAULT_FORWARD, DEFAULT_FORWARD)
	local origin = if finiteVector(eye) then eye else Vector3.zero
	local dir = safeUnit(if finiteVector(focus) then focus - origin else fallback, fallback)
	if math.abs(dir.Y) > 0.995 then
		local flat = safeUnit(Vector3.new(fallback.X, 0, fallback.Z), DEFAULT_FORWARD)
		dir = safeUnit(dir + flat * 0.12, flat)
	end
	-- Built from its basis (the same frame CFrame.lookAt gives in Roblox: right = look × up), so
	-- the result is identical in Studio and in the Lune tests.
	local right = safeUnit(dir:Cross(UP), Vector3.new(1, 0, 0))
	local up = right:Cross(dir)
	return CFrame.fromMatrix(origin, right, up, -dir)
end

--------------------------------------------------------------------------------------------------
-- Spring (critically damped, exact solution: stable for any dt)
--------------------------------------------------------------------------------------------------

--[[
	One step of a critically damped spring toward a (momentarily constant) target — the closed-form
	solution x(t) = target + (Δ + (v + ωΔ)t)e^(−ωt), so a long frame never overshoots or explodes.
	@param x Vector3 current value, v Vector3 its velocity, target Vector3
	@param omega number stiffness (rad/s), dt number seconds (clamped ≥ 0, non-finite → 0)
	@return (Vector3, Vector3) new value, new velocity
	Example: offset, offsetVel = LaunchCamMath.spring(offset, offsetVel, desired, 3.6, dt)
]]
function LaunchCamMath.spring(x: Vector3, v: Vector3, target: Vector3, omega: number, dt: number): (Vector3, Vector3)
	local w = math.max(finite(omega, 0), 0)
	local step = math.max(finite(dt, 0), 0)
	if not finiteVector(target) then
		return x, v
	end
	if not finiteVector(x) or not finiteVector(v) or w <= 0 then
		return target, Vector3.zero
	end
	local delta = x - target
	local decay = math.exp(-w * step)
	local tmp = v + delta * w
	local newDelta = (delta + tmp * step) * decay
	local newVelocity = (v - tmp * (w * step)) * decay
	return target + newDelta, newVelocity
end

--[[ The scalar version of `spring`. ]]
function LaunchCamMath.springNumber(x: number, v: number, target: number, omega: number, dt: number): (number, number)
	local w = math.max(finite(omega, 0), 0)
	local step = math.max(finite(dt, 0), 0)
	local goal = finite(target, x)
	if x ~= x or v ~= v or w <= 0 then
		return goal, 0
	end
	local delta = x - goal
	local decay = math.exp(-w * step)
	local tmp = v + w * delta
	return goal + (delta + tmp * step) * decay, (v - tmp * w * step) * decay
end

--------------------------------------------------------------------------------------------------
-- Countdown
--------------------------------------------------------------------------------------------------

export type CountdownPhase = "pre" | "count" | "launch" | "after"

--[[
	Where the countdown is at `rel` (seconds after t0).
	@param rel number, beat number (seconds per number), steps { number } (e.g. { 3, 2, 1 }),
	       launchHold number (seconds "LAUNCH!" stays)
	@return phase, step (the number shown in "count", nil otherwise), elapsed seconds inside the
	        current beat / launch hold, that beat's length
	Example: LaunchCamMath.countdown(-0.2, 1, { 3, 2, 1 }, 1) --> "count", 1, 0.8, 1
]]
function LaunchCamMath.countdown(
	rel: number,
	beat: number,
	steps: { number },
	launchHold: number
): (CountdownPhase, number?, number, number)
	local b = math.max(finite(beat, 1), 0.05)
	local hold = math.max(finite(launchHold, 1), 0)
	local r = finite(rel, -math.huge)
	local count = #steps
	local start = -count * b
	if r < start or count == 0 and r < 0 then
		return "pre", nil, 0, b
	end
	if r < 0 then
		local index = math.clamp(math.floor((r - start) / b) + 1, 1, count)
		return "count", steps[index], (r - start) - (index - 1) * b, b
	end
	if r < hold then
		return "launch", nil, r, hold
	end
	return "after", nil, r - hold, hold
end

--[[
	Punch-in / hold / exit of one countdown element over a beat of `length` seconds.
	@param elapsed seconds since the element appeared, length its total time
	@param cfg LaunchCamConfig.Countdown (PunchFrom / PunchSeconds / PunchDegrees / ExitSeconds / ExitScale)
	@param reduced Reduce Motion: no scale / rotation, fades only
	@return (scale, rotation degrees before the side sign, transparency 0..1)
]]
function LaunchCamMath.punch(elapsed: number, length: number, cfg: any, reduced: boolean): (number, number, number)
	local e = math.max(finite(elapsed, 0), 0)
	local total = math.max(finite(length, 1), 0.05)
	local punchSeconds = math.clamp(finite(cfg.PunchSeconds, 0.3), 0.01, total)
	local exitSeconds = math.clamp(finite(cfg.ExitSeconds, 0.15), 0.01, total)
	if e >= total then
		return 1, 0, 1
	end
	if reduced then
		local fadeIn = math.clamp(e / punchSeconds, 0, 1)
		local fadeOut = math.clamp((total - e) / exitSeconds, 0, 1)
		return 1, 0, 1 - math.min(fadeIn, fadeOut)
	end
	if e < punchSeconds then
		local p = e / punchSeconds
		local from = finite(cfg.PunchFrom, 2)
		local scale = from + (1 - from) * LaunchCamMath.backOut(p)
		local rotation = finite(cfg.PunchDegrees, 15) * (1 - LaunchCamMath.easeOutCubic(p))
		return math.max(scale, 0.05), rotation, 1 - math.clamp(p * 3, 0, 1)
	end
	if e > total - exitSeconds then
		local q = math.clamp((e - (total - exitSeconds)) / exitSeconds, 0, 1)
		local exitScale = finite(cfg.ExitScale, 0.6)
		return 1 + (exitScale - 1) * q, 0, q
	end
	return 1, 0, 0
end

--------------------------------------------------------------------------------------------------
-- Timeline + shots
--------------------------------------------------------------------------------------------------

--[[
	The cinematic schedule of one flight.
	@param duration flight seconds, intercepted, interceptAt (rel), cfg LaunchCamConfig.Shots
	@return Timeline — every field finite, chaseStart ≤ chaseFull, approachAt < endAt < holdUntil
]]
function LaunchCamMath.timeline(duration: number, intercepted: boolean, interceptAt: number, cfg: any): Timeline
	local seconds = math.max(finite(duration, 5), 0.5)
	local endAt = seconds
	if intercepted then
		endAt = math.clamp(finite(interceptAt, seconds), 0.2, seconds)
	end
	local chaseStart = math.max(finite(cfg.LiftHold, 0.75), 0)
	local chaseFull = chaseStart + math.max(finite(cfg.ChaseBlend, 0.9), 0.05)
	local approachAt = math.max(endAt - math.max(finite(cfg.ApproachSeconds, 1.7), 0.05), 0)
	if approachAt >= endAt then
		approachAt = math.max(endAt - 0.05, 0)
	end
	return {
		duration = seconds,
		endAt = endAt,
		intercepted = intercepted,
		chaseStart = chaseStart,
		chaseFull = chaseFull,
		approachAt = approachAt,
		holdUntil = endAt + math.max(finite(cfg.Hold, 1.9), 0),
	}
end

--[[
	The silo shot: behind the silo (opposite the target), a little to the side, above its mouth,
	looking ahead / up along the launch direction. `push` (0..PushIn) dollies the eye in.
	@param from Vector3 silo mouth, to Vector3 impact point, push 0..1 share of SiloBack removed
	@return Pose
]]
function LaunchCamMath.siloPose(from: Vector3, to: Vector3, push: number, cfg: any): Pose
	local flat = LaunchCamMath.flatDir(from, to)
	local right = rightOf(flat)
	local back = finite(cfg.SiloBack, 40) * (1 - math.clamp(finite(push, 0), 0, 0.9))
	return {
		eye = from - flat * back + UP * finite(cfg.SiloUp, 14) + right * finite(cfg.SiloSide, 0),
		focus = from + flat * finite(cfg.SiloLookAhead, 40) + UP * finite(cfg.SiloLookUp, 30),
	}
end

--[[
	The chase's DESIRED offset (camera = nuke + offset) and look direction at one moment; the
	director smooths both with `spring`.
	@param position Vector3 nuke position, velocity Vector3 its velocity, impact Vector3 target point
	@param flat Vector3 the flight's horizontal direction (fallback when the velocity is vertical)
	@param s number share of the flight done (0..1)
	@return (Vector3 offset, Vector3 unit look direction)
]]
function LaunchCamMath.chaseTargets(
	position: Vector3,
	velocity: Vector3,
	impact: Vector3,
	flat: Vector3,
	s: number,
	cfg: any
): (Vector3, Vector3)
	local dir = safeUnit(velocity, flat)
	local travelFlat = safeUnit(Vector3.new(dir.X, 0, dir.Z), flat)
	local offset = -travelFlat * finite(cfg.ChaseBack, 34) + UP * finite(cfg.ChaseUp, 13)
	-- Lean toward the horizon (a rising nuke would otherwise stare at the sky)...
	local bias = math.clamp(finite(cfg.HorizonBias, 0.35), 0, 1)
	local look = safeUnit(dir:Lerp(travelFlat, bias), flat)
	-- ...then turn toward the target over the second part of the flight.
	local from = math.clamp(finite(cfg.TargetTurnFrom, 0.4), 0, 0.99)
	local turn = LaunchCamMath.smoothstep((finite(s, 0) - from) / (1 - from))
	if turn > 0 then
		look = safeUnit(look:Lerp(safeUnit(impact - position, look), turn), look)
	end
	return offset, look
end

--[[
	The outcome shot: a 3/4 view from behind the flight, looking at the impact (ground hit) or at
	the interception point (mid-air POP), optionally orbited by `orbitDegrees` around the focus.
	@param focus Vector3 the outcome point, flat Vector3 the flight's horizontal direction
	@return Pose
]]
function LaunchCamMath.impactPose(
	focus: Vector3,
	flat: Vector3,
	intercepted: boolean,
	orbitDegrees: number,
	cfg: any
): Pose
	local forward = safeUnit(flat, DEFAULT_FORWARD)
	local right = rightOf(forward)
	local back = if intercepted then finite(cfg.InterceptBack, 62) else finite(cfg.ImpactBack, 92)
	local up = if intercepted then finite(cfg.InterceptUp, 16) else finite(cfg.ImpactUp, 52)
	local side = if intercepted then finite(cfg.InterceptSide, 22) else finite(cfg.ImpactSide, 30)
	local arm = -forward * back + right * side
	local angle = math.rad(finite(orbitDegrees, 0))
	if angle ~= 0 then
		local c, sn = math.cos(angle), math.sin(angle)
		arm = Vector3.new(arm.X * c - arm.Z * sn, 0, arm.X * sn + arm.Z * c)
	end
	return { eye = focus + arm + UP * up, focus = focus }
end

--[[
	Reduce Motion's static wide shot: off to the side of the arc's midpoint, far enough to see the
	whole arc, looking at the apex region.
	@param from Vector3, to Vector3, apex Vector3 (position at mid-flight), cfg LaunchCamConfig.Reduced
	@return Pose
]]
function LaunchCamMath.widePose(from: Vector3, to: Vector3, apex: Vector3, cfg: any): Pose
	local flat = LaunchCamMath.flatDir(from, to)
	local right = rightOf(flat)
	local d = to - from
	local length = Vector3.new(d.X, 0, d.Z).Magnitude
	local side = math.clamp(
		length * finite(cfg.WideSideFactor, 0.55),
		finite(cfg.WideSideMin, 160),
		finite(cfg.WideSideMax, 700)
	)
	local mid = from:Lerp(to, 0.5)
	local focus = mid:Lerp(apex, 0.6)
	return { eye = mid + right * side + UP * (finite(cfg.WideUp, 60) + (apex.Y - mid.Y) * 0.4), focus = focus }
end

--[[
	Deterministic camera shake offset (studs): sums of incommensurate sines, so it never repeats
	visibly and needs no random state.
	@param t number seconds, amplitude number studs, frequency number Hz
	@return Vector3 (zero when amplitude is 0)
]]
function LaunchCamMath.shake(t: number, amplitude: number, frequency: number): Vector3
	local a = finite(amplitude, 0)
	if a == 0 then
		return Vector3.zero
	end
	local w = TAU * finite(frequency, 9) * finite(t, 0)
	return Vector3.new(
		math.sin(w + 1.3) * 0.6 + math.sin(w * 2.31 + 0.2) * 0.4,
		math.sin(w * 1.17 + 0.4) * 0.6 + math.sin(w * 3.07 + 2.1) * 0.4,
		math.sin(w * 0.93 + 2.7) * 0.6 + math.sin(w * 2.71 + 1.1) * 0.4
	) * a
end

--[[
	The return-to-player blend weight: 0 at the start, exactly 1 once `seconds` passed (0 or less
	seconds = an instant cut).
]]
function LaunchCamMath.returnBlend(elapsed: number, seconds: number): number
	local s = finite(seconds, 0)
	if s <= 0 then
		return 1
	end
	return LaunchCamMath.easeInOutCubic(finite(elapsed, s) / s)
end

--------------------------------------------------------------------------------------------------
-- Frame composer (the whole cinematic camera at one moment)
--------------------------------------------------------------------------------------------------

-- Seconds the lift-off look takes to lock onto the rising nuke.
local LIFT_LOOK_SECONDS = 0.35
-- Seconds the FOV kick takes to rise before decaying.
local KICK_RISE = 0.15
-- Lift of an occlusion ray origin above its subject (studs); the director raycasts from here.
LaunchCamMath.RayLift = 2

-- The chase springs (mutated in place by `frame`; one per cinematic, no per-frame tables).
export type ChaseState = {
	ready: boolean,
	offset: Vector3,
	offsetVel: Vector3,
	look: Vector3,
	lookVel: Vector3,
}

-- Everything `frame` needs about one cinematic (built once by the director in play()).
export type Shot = {
	flight: FlightMath.Flight, -- the arc (AttackGeometry.flight with the server's duration)
	timeline: Timeline,
	flat: Vector3, -- horizontal flight direction (flatDir)
	startRel: number, -- rel when the cinematic opened (≤ 0; the silo dolly runs from here to t0)
	reduced: boolean, -- Reduce Motion: static shots + hard cuts
	siloReach: number, -- max eye distance from the silo mouth (occlusion; math.huge = clear)
	impactReach: number, -- max eye distance from the outcome point (occlusion; math.huge = clear)
	chase: ChaseState,
}

--[[ A fresh chase state looking along `flat`. ]]
function LaunchCamMath.newChase(flat: Vector3): ChaseState
	return { ready = false, offset = Vector3.zero, offsetVel = Vector3.zero, look = flat, lookVel = Vector3.zero }
end

--[[
	Pulls `eye` toward `subject` (raised by RayLift) so it is at most `limit` studs away — the
	occlusion clamp for a shot whose ray hit scenery. math.huge / a closer eye = unchanged.
]]
function LaunchCamMath.clampEye(subject: Vector3, eye: Vector3, limit: number): Vector3
	local cap = finite(limit, math.huge)
	if limit == math.huge or cap == math.huge then
		return eye
	end
	local origin = subject + UP * LaunchCamMath.RayLift
	local delta = eye - origin
	local distance = delta.Magnitude
	if distance <= cap or distance < 1e-6 then
		return eye
	end
	return origin + delta * (math.max(cap, 0) / distance)
end

--[[ The silo shot at dolly progress `push` (0..1 of Shots.PushIn), occlusion-clamped. ]]
function LaunchCamMath.siloShot(shot: Shot, push: number, shots: any): Pose
	local path = shot.flight
	local pose = LaunchCamMath.siloPose(path.from, path.to, push * finite(shots.PushIn, 0.25), shots)
	return { eye = LaunchCamMath.clampEye(path.from, pose.eye, shot.siloReach), focus = pose.focus }
end

--[[ The outcome shot at `orbit` degrees, occlusion-clamped. ]]
function LaunchCamMath.impactShot(shot: Shot, orbit: number, shots: any): Pose
	local focus = FlightMath.position(shot.flight, shot.timeline.endAt)
	local pose = LaunchCamMath.impactPose(focus, shot.flat, shot.timeline.intercepted, orbit, shots)
	return { eye = LaunchCamMath.clampEye(focus, pose.eye, shot.impactReach), focus = pose.focus }
end

--[[
	The cinematic camera at `rel` (seconds after t0): silo dolly → lift-off look → spring chase →
	impact approach (deceleration + zoom) → orbiting hold; with Reduce Motion, hard cuts between
	static shots. Mutates `shot.chase` (springs advance by `dt`, clamped to Shots.MaxDt).
	@param shot Shot, rel number, dt number (frame seconds), cfg LaunchCamConfig (Shots / Fov /
	       Shake / Reduced)
	@return (CFrame, number) — camera CFrame and FOV, always finite
	Example: camera.CFrame, camera.FieldOfView = LaunchCamMath.frame(shot, rel, dt, LaunchCamConfig)
]]
function LaunchCamMath.frame(shot: Shot, rel: number, dt: number, cfg: any): (CFrame, number)
	local shots = cfg.Shots
	local fovCfg = cfg.Fov
	local shakeCfg = cfg.Shake
	local timeline = shot.timeline
	local path = shot.flight
	local flat = shot.flat
	local r = finite(rel, 0)
	local base = finite(fovCfg.Base, 70)
	if shot.reduced then
		local reducedCfg = cfg.Reduced
		local pose: Pose
		if r < finite(reducedCfg.WideCutAt, 0.6) then
			pose = LaunchCamMath.siloShot(shot, 1, shots)
		elseif r < timeline.endAt - finite(reducedCfg.ImpactCutBefore, 1.2) then
			pose =
				LaunchCamMath.widePose(path.from, path.to, FlightMath.position(path, path.duration * 0.5), reducedCfg)
		else
			pose = LaunchCamMath.impactShot(shot, 0, shots)
		end
		return LaunchCamMath.lookAt(pose.eye, pose.focus, flat), base
	end

	local position = FlightMath.position(path, r)
	-- 1. Silo shot, dollying in over the countdown; after t0 the look locks onto the rising nuke.
	local startRel = math.min(finite(shot.startRel, 0), 0)
	local pushT = if startRel < 0 then clamp01((r - startRel) / -startRel) else 1
	local pose = LaunchCamMath.siloShot(shot, LaunchCamMath.easeInOutCubic(pushT), shots)
	if r > 0 then
		pose = { eye = pose.eye, focus = pose.focus:Lerp(position, LaunchCamMath.smoothstep(r / LIFT_LOOK_SECONDS)) }
	end
	-- 2. Chase. The camera rides the arc at "camera time" tau: real time until the approach, then
	--    tau slows to a stop at the outcome (speed 1 − p), so the camera brakes BEHIND the nuke while
	--    the nuke races on into the target — the slow-mo feel by camera easing only, and the camera
	--    can never overtake the nuke. The springs settle until the approach, then hold.
	local approachSpan = math.max(timeline.endAt - timeline.approachAt, 0.05)
	local p = clamp01((r - timeline.approachAt) / approachSpan)
	local tau = if r <= timeline.approachAt then r else timeline.approachAt + approachSpan * (p - 0.5 * p * p)
	local chase = shot.chase
	if r >= timeline.chaseStart and (r < timeline.approachAt or not chase.ready) then
		local wantOffset, wantLook = LaunchCamMath.chaseTargets(
			FlightMath.position(path, tau),
			FlightMath.velocity(path, tau),
			path.to,
			flat,
			tau / path.duration,
			shots
		)
		if not chase.ready then
			chase.ready = true
			chase.offset, chase.offsetVel = wantOffset, Vector3.zero
			chase.look, chase.lookVel = wantLook, Vector3.zero
		else
			local step = math.min(math.max(finite(dt, 0), 0), finite(shots.MaxDt, 1 / 15))
			chase.offset, chase.offsetVel =
				LaunchCamMath.spring(chase.offset, chase.offsetVel, wantOffset, finite(shots.OffsetOmega, 3.6), step)
			chase.look, chase.lookVel =
				LaunchCamMath.spring(chase.look, chase.lookVel, wantLook, finite(shots.LookOmega, 5), step)
		end
	end
	local outcome = FlightMath.position(path, timeline.endAt)
	local approach = LaunchCamMath.smoothstep(p)
	if chase.ready then
		-- Look ahead of the REAL nuke, turning onto the outcome point over the approach.
		local ahead = position + safeUnit(chase.look, flat) * finite(shots.LookAhead, 70)
		local chasePose: Pose = {
			eye = FlightMath.position(path, tau) + chase.offset,
			focus = if approach > 0 then ahead:Lerp(outcome, approach) else ahead,
		}
		local w = LaunchCamMath.smoothstep((r - timeline.chaseStart) / (timeline.chaseFull - timeline.chaseStart))
		pose = LaunchCamMath.blend(pose, chasePose, w)
	elseif approach > 0 then
		pose = { eye = pose.eye, focus = pose.focus:Lerp(outcome, approach) }
	end
	-- 3. Outcome hold: from where the camera braked, ease into the 3/4 outcome shot (slow orbit).
	if r >= timeline.endAt then
		local held = r - timeline.endAt
		local orbit = held * finite(shots.OrbitDegreesPerSecond, 0)
		local w = LaunchCamMath.smoothstep(held / math.max(finite(shots.HoldBlend, 1.3), 0.05))
		pose = LaunchCamMath.blend(pose, LaunchCamMath.impactShot(shot, orbit, shots), w)
	end
	-- Shake: light at lift-off, a small bump at a ground hit.
	local frequency = finite(shakeCfg.Frequency, 9)
	local amplitude = finite(shakeCfg.LiftAmplitude, 0) * LaunchCamMath.decay(r, finite(shakeCfg.LiftSeconds, 0))
	if not timeline.intercepted then
		amplitude += finite(shakeCfg.ImpactAmplitude, 0) * LaunchCamMath.decay(
			r - timeline.endAt,
			finite(shakeCfg.ImpactSeconds, 0)
		)
	end
	local jitter = LaunchCamMath.shake(r, amplitude, frequency)
	-- FOV: a kick at lift-off (rise, then decay), a zoom-in over the approach.
	local liftKick = finite(fovCfg.LiftKick, 0)
	local kick = 0
	if r > 0 then
		kick = if r < KICK_RISE
			then liftKick * r / KICK_RISE
			else liftKick * math.max(
				1 - (r - KICK_RISE) / math.max(finite(fovCfg.KickSeconds, 1) - KICK_RISE, 0.05),
				0
			)
	end
	local fov = math.clamp(base + kick - finite(fovCfg.ApproachZoom, 0) * approach, 20, 110)
	return LaunchCamMath.lookAt(pose.eye + jitter, pose.focus + jitter * 0.5, flat), fov
end

--[[
	Whether an input may skip now: forced sources (the Roblox menu opening, the screen closed by
	something else, a script call) always may; taps / buttons / keys only after the grace window
	(the click that pressed LAUNCH! never skips its own cinematic).
]]
function LaunchCamMath.skipAllowed(source: string, sinceOpen: number, grace: number): boolean
	if source == "menu" or source == "closed" or source == "external" then
		return true
	end
	return finite(sinceOpen, 0) >= finite(grace, 0)
end

--------------------------------------------------------------------------------------------------
-- Overlay particle paths (design px, relative to the emitter centre; +Y is DOWN on screen)
--------------------------------------------------------------------------------------------------

--[[
	One stud brick of a countdown badge burst at `elapsed` seconds: flies radially out with spin,
	fading. Pieces are spread evenly round the circle with a seeded jitter.
	@return (dx, dy, rotation degrees, transparency) — transparency 1 once done
]]
function LaunchCamMath.burstPiece(
	index: number,
	count: number,
	elapsed: number,
	seed: number,
	cfg: any
): (number, number, number, number)
	local seconds = math.max(finite(cfg.Seconds, 0.55), 0.05)
	local p = finite(elapsed, seconds) / seconds
	if p < 0 or p >= 1 then
		return 0, 0, 0, 1
	end
	local n = math.max(math.floor(finite(count, 1)), 1)
	local jitter = (LaunchCamMath.hash01(seed, index, 1) - 0.5) * (TAU / n) * 0.6
	local angle = (index - 1) / n * TAU + jitter
	local minD = finite(cfg.DistanceMin, 220)
	local maxD = finite(cfg.DistanceMax, 420)
	local distance = minD + (maxD - minD) * LaunchCamMath.hash01(seed, index, 2)
	local travel = LaunchCamMath.easeOutCubic(p) * distance
	local spin = finite(cfg.SpinDegrees, 240) * (if LaunchCamMath.hash01(seed, index, 3) < 0.5 then -1 else 1)
	return math.cos(angle) * travel, math.sin(angle) * travel, spin * p, p * p
end

--[[
	One confetti piece of the LAUNCH! burst at `elapsed` seconds: launched up and out, then falls
	with gravity while tumbling; fades over the last 30 %.
	@return (dx, dy, rotation degrees, transparency) — transparency 1 once done
]]
function LaunchCamMath.confettiPiece(
	index: number,
	elapsed: number,
	seed: number,
	cfg: any
): (number, number, number, number)
	local seconds = math.max(finite(cfg.Seconds, 1.6), 0.05)
	local t = finite(elapsed, seconds)
	if t < 0 or t >= seconds then
		return 0, 0, 0, 1
	end
	-- Up-and-out: angles from 200° to 340° on screen (−Y is up).
	local angle = math.rad(200 + 140 * LaunchCamMath.hash01(seed, index, 4))
	local minS = finite(cfg.SpeedMin, 650)
	local maxS = finite(cfg.SpeedMax, 1250)
	local speed = minS + (maxS - minS) * LaunchCamMath.hash01(seed, index, 5)
	local gravity = finite(cfg.Gravity, 1500)
	local dx = math.cos(angle) * speed * t
	local dy = math.sin(angle) * speed * t + 0.5 * gravity * t * t
	local spin = finite(cfg.SpinDegrees, 720) * (LaunchCamMath.hash01(seed, index, 6) - 0.5) * 2
	local fade = math.clamp((t / seconds - 0.7) / 0.3, 0, 1)
	return dx, dy, spin * t, fade
end

return LaunchCamMath
