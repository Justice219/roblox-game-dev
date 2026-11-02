--!strict
--[[
	HatchAnim — the PURE timeline maths of the egg hatch cinematic (owner R49). No instances, no
	services beyond the config require: every pose is a function of (timeline, t), so the screen
	can jump anywhere (tap to skip), rebuild a model mid-animation (a mesh finished loading) and
	the Lune suite (tests/hatch-anim.luau) can prove the curves: finite everywhere, phases in
	order, triple-hatch stagger with the best rarity last, skip lands on the reveal.

	One egg = one Timeline (absolute seconds on the reveal's clock, t = 0 when the screen opens):

		start ─ Intro ─ introEnd ─ Idle (+ stagger wait) ─ wobbleStart ─ bursts 1..n (crack
		stages on three of them) ─ wobbleEnd = squashStart ─ Squash ─ burst ─ Pop ─ popEnd
		                                                                   └ BannerDelay ─ banner ─ bannerEnd
		                                                                   └ Fly (shell pieces) ─ flyEnd
		done = the latest of popEnd / bannerEnd / flyEnd

	Reduced motion: start ─ Hold ─ burst ─ Fade (egg cross-fades into the pet) ─ done.
	Granted pets (server grants, no egg): the pet pops at `burst` right after `start`.

	Poses returned (the screen applies them; HatchStage):
		eggPose      visible / intro scale / squash-stretch / roll + lean / bob + hop / fade
		cap / cup    the ShellTop cap (ballistic + spin) and ShellBottom cup (sinks, tips, shrinks)
		shard        Shard<i> (ballistic + spin, hidden before the burst)
		crack        opacity of crack stage k;  crackGlow  0..1 pulse of the leaking light
		halo / rays / flash / wash / dim / ambient / jitter   the light show
		pet / banner the pop-out spring and the rarity banner spring
		events       sound cues, haptic, confetti, happy spin (fired once when t crosses them)

	Connects to: Shared/Config/HatchAnimConfig (every number), UI/Screens/EggHatch/{HatchStage,
	HatchRevealScreen} (the only callers), tests/hatch-anim.luau.

	Example:
		local timelines = HatchAnim.schedule({ 1, 5, 3 }, { fast = false, reduced = false, granted = false })
		local pose = HatchAnim.eggPose(timelines[2], 1.3)
		local action, nextT = HatchAnim.onTap(timelines, 0.8) --> "skip", <the last burst>
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HatchAnimConfig = require(ReplicatedStorage.Shared.Config.HatchAnimConfig)

local Egg = HatchAnimConfig.Egg
local Shell = HatchAnimConfig.Shell
local PetCfg = HatchAnimConfig.Pet
local Light = HatchAnimConfig.Light
local BannerCfg = HatchAnimConfig.Banner

export type Burst = {
	index: number,
	start: number,
	finish: number,
	amp: number, -- peak roll (radians)
	freq: number, -- shake frequency (Hz)
	strength: number, -- 1 for the first burst, growing
}

export type Timeline = {
	rank: number, -- PetConfig rarity rank 1..7
	beat: HatchAnimConfig.RarityBeat,
	speed: HatchAnimConfig.Profile,
	fast: boolean,
	reduced: boolean,
	granted: boolean,
	start: number,
	introEnd: number,
	wobbleStart: number,
	wobbleEnd: number,
	squashStart: number,
	burst: number,
	popEnd: number,
	banner: number,
	bannerEnd: number,
	flyEnd: number,
	done: number,
	bursts: { Burst },
	cracks: { number }, -- crack stage k appears at cracks[k]
}

export type Spec = {
	rank: number,
	fast: boolean,
	reduced: boolean,
	granted: boolean,
	introDelay: number?, -- seconds before the egg pops in (triple: left to right)
	wobbleDelay: number?, -- extra idle before the build-up (triple: rarity order)
}

export type Options = { fast: boolean, reduced: boolean, granted: boolean }

export type EggPose = {
	visible: boolean,
	scale: number, -- uniform intro scale
	sxz: number, -- squash / stretch (X and Z)
	sy: number, -- squash / stretch (Y)
	roll: number, -- radians about Z (side to side)
	lean: number, -- radians about X (forward / back)
	y: number, -- studs (bob + hop)
	fade: number, -- 0 = as authored .. 1 = invisible (reduced cross-fade)
	opened: boolean, -- the shell has burst (cap / cup / shards take over)
}

export type Motion = {
	offset: Vector3, -- studs from the rest position
	rx: number, -- radians
	ry: number,
	rz: number,
	scale: number,
	fade: number, -- 0 = as authored .. 1 = invisible
}

export type PetPose = { visible: boolean, scale: number, y: number, fade: number }

export type BannerPose = { visible: boolean, scale: number, fade: number }

export type EventKind = "sound" | "haptic" | "confetti" | "sparkles" | "happy"

export type Event = {
	time: number,
	kind: EventKind,
	key: string, -- Sound key ("" for non-sound events)
	pitch: number,
	volume: number,
}

export type TapAction = "skip" | "wait" | "close"

local HatchAnim = {}

local TAU = math.pi * 2
-- Smallest duration used as a divisor (config values are larger; guards against zero).
local EPSILON = 1e-3
-- Skip lands this far before the last burst, so its burst events still fire.
local SKIP_LEAD = 1e-3

--------------------------------------------------------------------------------------------------
-- Small maths
--------------------------------------------------------------------------------------------------

local function clamp01(x: number): number
	if x ~= x then
		return 0
	end
	return math.clamp(x, 0, 1)
end

local function lerp(a: number, b: number, u: number): number
	return a + (b - a) * u
end

-- 0..1 progress of `t` through [from, from + duration].
local function progress(t: number, from: number, duration: number): number
	return clamp01((t - from) / math.max(duration, EPSILON))
end

local function smooth(u: number): number
	local x = clamp01(u)
	return x * x * (3 - 2 * x)
end

local function easeOut(u: number): number
	local x = clamp01(u)
	return 1 - (1 - x) * (1 - x)
end

local function easeIn(u: number): number
	local x = clamp01(u)
	return x * x
end

--[[
	A damped spring from 0 to 1: 1 - e^(-damping u) cos(frequency u) (overshoots past 1, settles).
	Exactly 0 at u <= 0 and exactly 1 at u >= 1 (no drift once settled).
	Example: HatchAnim.spring(0.3, 5.5, 11) --> ~1.15 (the overshoot)
]]
function HatchAnim.spring(u: number, damping: number, frequency: number): number
	if u ~= u or u <= 0 then
		return 0
	elseif u >= 1 then
		return 1
	end
	return 1 - math.exp(-damping * u) * math.cos(frequency * u)
end

-- Deterministic 0..1 noise per (piece index, channel) — shards always fly the same way.
local function hash(index: number, channel: number): number
	local x = math.sin(index * 12.9898 + channel * 78.233) * 43758.5453
	return x - math.floor(x)
end
HatchAnim.hash = hash

local function rankOf(rank: number): number
	if type(rank) ~= "number" or rank ~= rank then
		return 1
	end
	return math.clamp(math.floor(rank), 1, #HatchAnimConfig.Rarity)
end

--------------------------------------------------------------------------------------------------
-- Timelines
--------------------------------------------------------------------------------------------------

--[[
	Builds one egg's timeline (see the module header).
	@param spec rank / fast / reduced / granted / introDelay / wobbleDelay
	@return Timeline (absolute seconds)
	Example: HatchAnim.build({ rank = 7, fast = false, reduced = false, granted = false })
]]
function HatchAnim.build(spec: Spec): Timeline
	local rank = rankOf(spec.rank)
	local beat = HatchAnimConfig.Rarity[rank]
	local speed = if spec.fast then HatchAnimConfig.Profiles.Fast else HatchAnimConfig.Profiles.Normal
	local start = math.max(0, spec.introDelay or 0)
	local wait = math.max(0, spec.wobbleDelay or 0)
	local tl: Timeline = {
		rank = rank,
		beat = beat,
		speed = speed,
		fast = spec.fast,
		reduced = spec.reduced,
		granted = spec.granted,
		start = start,
		introEnd = start,
		wobbleStart = start,
		wobbleEnd = start,
		squashStart = start,
		burst = start,
		popEnd = start,
		banner = start,
		bannerEnd = start,
		flyEnd = start,
		done = start,
		bursts = {},
		cracks = {},
	}
	if spec.reduced then
		-- A still egg (or nothing, for a grant), then the cross-fade.
		tl.burst = start + wait + (if spec.granted then EPSILON else speed.Hold)
		tl.introEnd, tl.wobbleStart, tl.wobbleEnd, tl.squashStart = start, tl.burst, tl.burst, tl.burst
		tl.popEnd = tl.burst + speed.Fade
		tl.banner = tl.burst
		tl.bannerEnd = tl.burst + speed.Fade
		tl.flyEnd = tl.burst
		tl.done = math.max(tl.popEnd, tl.bannerEnd)
		return tl
	end
	if spec.granted then
		-- No egg: the pet springs straight out of the flash.
		tl.burst = start + wait + 0.05
		tl.introEnd, tl.wobbleStart, tl.wobbleEnd, tl.squashStart = start, tl.burst, tl.burst, tl.burst
	else
		tl.introEnd = start + speed.Intro
		tl.wobbleStart = tl.introEnd + speed.Idle + wait
		local count = math.max(1, math.min(beat.bursts, speed.MaxBursts))
		local cursor = tl.wobbleStart
		for index = 1, count do
			local grow = speed.BurstGrowth ^ (index - 1)
			local duration = speed.BurstTime * grow
			local strength = 1 + Egg.WobbleGrowth * (index - 1)
			table.insert(tl.bursts, {
				index = index,
				start = cursor,
				finish = cursor + duration,
				amp = math.rad(Egg.WobbleDegrees * beat.strength * strength),
				freq = Egg.WobbleHz * (1 + Egg.HzGrowth * (index - 1)),
				strength = strength,
			})
			cursor += duration
			if index < count then
				cursor += speed.Pause * grow
			end
		end
		tl.wobbleEnd = cursor
		-- Crack stage k lands on the peak of burst round(k * n / 3) (n = 5: bursts 2, 3, 5 —
		-- the dramatic build-up shakes once before the first crack).
		local previous = -math.huge
		for stage = 1, HatchAnimConfig.CrackStages do
			local which = math.clamp(math.floor(stage * count / HatchAnimConfig.CrackStages + 0.5), 1, count)
			local b = tl.bursts[which]
			local at = (b.start + b.finish) / 2
			if at <= previous then
				at = previous + (b.finish - b.start) * 0.25
			end
			tl.cracks[stage] = at
			previous = at
		end
		tl.squashStart = tl.wobbleEnd
		tl.burst = tl.squashStart + speed.Squash
	end
	tl.popEnd = tl.burst + speed.Pop
	tl.banner = tl.burst + speed.BannerDelay
	tl.bannerEnd = tl.banner + speed.Banner
	tl.flyEnd = if spec.granted then tl.burst else tl.burst + speed.Fly
	tl.done = math.max(tl.popEnd, tl.bannerEnd, tl.flyEnd)
	return tl
end

-- Moves the build-up and everything after it later by `dt` (the intro stays).
local function delayBuildUp(tl: Timeline, dt: number)
	if dt <= 0 then
		return
	end
	tl.wobbleStart += dt
	tl.wobbleEnd += dt
	tl.squashStart += dt
	tl.burst += dt
	tl.popEnd += dt
	tl.banner += dt
	tl.bannerEnd += dt
	tl.flyEnd += dt
	tl.done += dt
	for _, b in tl.bursts do
		b.start += dt
		b.finish += dt
	end
	for stage, at in tl.cracks do
		tl.cracks[stage] = at + dt
	end
end

--[[
	The order eggs reveal in: slot indices sorted by rarity rank ascending, ties left to right
	(the best pet always comes last).
	Example: HatchAnim.revealOrder({ 5, 1, 3 }) --> { 2, 3, 1 }
]]
function HatchAnim.revealOrder(ranks: { number }): { number }
	local order: { number } = {}
	for index in ranks do
		table.insert(order, index)
	end
	table.sort(order, function(a: number, b: number): boolean
		local ra, rb = rankOf(ranks[a]), rankOf(ranks[b])
		if ra ~= rb then
			return ra < rb
		end
		return a < b
	end)
	return order
end

--[[
	Timelines for a whole reveal (1 or 3 eggs). Eggs pop in left to right; their build-ups are
	staggered in reveal order (rarity ascending) and every burst comes at least MinBurstGap after
	the previous one, so the best pet is always revealed last.
	@param ranks rarity rank per slot
	@return { Timeline } indexed like `ranks`
]]
function HatchAnim.schedule(ranks: { number }, options: Options): { Timeline }
	local speed = if options.fast then HatchAnimConfig.Profiles.Fast else HatchAnimConfig.Profiles.Normal
	local timelines: { Timeline } = {}
	local previousBurst = -math.huge
	for position, index in HatchAnim.revealOrder(ranks) do
		local tl = HatchAnim.build({
			rank = ranks[index],
			fast = options.fast,
			reduced = options.reduced,
			granted = options.granted,
			introDelay = (index - 1) * speed.IntroStagger,
			wobbleDelay = (position - 1) * speed.Stagger,
		})
		delayBuildUp(tl, previousBurst + speed.MinBurstGap - tl.burst)
		previousBurst = tl.burst
		timelines[index] = tl
	end
	return timelines
end

--[[ The moment the whole reveal is finished (every slot settled). ]]
function HatchAnim.total(timelines: { Timeline }): number
	local latest = 0
	for _, tl in timelines do
		latest = math.max(latest, tl.done)
	end
	return latest
end

--[[ The last burst of the reveal (the best pet's). ]]
function HatchAnim.lastBurst(timelines: { Timeline }): number
	local latest = 0
	for _, tl in timelines do
		latest = math.max(latest, tl.burst)
	end
	return latest
end

--[[
	What a tap / A / click does at time `t`:
		"skip"  before the last burst: jump to it (every egg shows its pet, the best pops now)
		"wait"  just after the last burst (MinReveal): ignored, so a double tap never closes
		        the result unseen
		"close" the result has been visible long enough: continue
	@return (action, the time to continue from)
]]
function HatchAnim.onTap(timelines: { Timeline }, t: number): (TapAction, number)
	local now = if t == t then t else 0
	local last = HatchAnim.lastBurst(timelines)
	if now < last - SKIP_LEAD then
		return "skip", last - SKIP_LEAD
	end
	local speed = if timelines[1] ~= nil then timelines[1].speed else HatchAnimConfig.Profiles.Normal
	if now < last + speed.MinReveal then
		return "wait", now
	end
	return "close", now
end

--------------------------------------------------------------------------------------------------
-- Egg
--------------------------------------------------------------------------------------------------

-- The burst `t` falls in (nil between / outside bursts).
local function burstAt(tl: Timeline, t: number): Burst?
	for _, b in tl.bursts do
		if t >= b.start and t < b.finish then
			return b
		end
	end
	return nil
end

-- 0..1 progress through the whole build-up (wobble start → burst).
local function buildUp(tl: Timeline, t: number): number
	return progress(t, tl.wobbleStart, tl.burst - tl.wobbleStart)
end

--[[
	The whole egg's pose at `t` (see EggPose). Shell pieces use it until the burst; after it the
	cap / cup / shards move on their own (cap, cup, shard) from the rest pose.
]]
function HatchAnim.eggPose(tl: Timeline, t: number): EggPose
	local pose: EggPose = {
		visible = false,
		scale = 1,
		sxz = 1,
		sy = 1,
		roll = 0,
		lean = 0,
		y = 0,
		fade = 0,
		opened = false,
	}
	if tl.granted or t ~= t or t < tl.start then
		return pose
	end
	if tl.reduced then
		pose.visible = t < tl.popEnd
		pose.fade = progress(t, tl.burst, tl.popEnd - tl.burst)
		return pose
	end
	if t >= tl.burst then
		pose.opened = true
		pose.visible = t < tl.flyEnd
		return pose
	end
	pose.visible = true
	-- Intro pop.
	if t < tl.introEnd then
		local u = progress(t, tl.start, tl.introEnd - tl.start)
		pose.scale = Egg.IntroFrom + (1 - Egg.IntroFrom) * HatchAnim.spring(u, 6, 10)
	end
	-- Gentle idle bob (fades out as the shaking takes over).
	local calm = 1 - smooth(progress(t, tl.wobbleStart - 0.2, 0.4))
	pose.y = Egg.BobHeight * math.sin(TAU * (t - tl.start) / Egg.BobPeriod) * calm
	local b = burstAt(tl, t)
	if b ~= nil then
		local u = progress(t, b.start, b.finish - b.start)
		local envelope = math.sin(math.pi * u)
		local phase = TAU * b.freq * (t - b.start)
		pose.roll = b.amp * envelope * math.sin(phase)
		pose.lean = b.amp * Egg.LeanRatio * envelope * math.sin(phase * 0.5 + 0.7)
		-- A little hop at the start of every burst.
		if u < 0.3 then
			pose.y += Egg.HopHeight * tl.beat.strength * math.sin(math.pi * u / 0.3)
		end
		local squash = Egg.WobbleSquash * envelope * math.abs(math.sin(phase))
		pose.sy = 1 - squash
		pose.sxz = 1 + squash * 0.5
	elseif t >= tl.squashStart then
		-- Crouch, then stretch into the burst (volume kept roughly constant).
		local u = progress(t, tl.squashStart, tl.burst - tl.squashStart)
		if u < Egg.CrouchAt then
			pose.sy = lerp(1, Egg.CrouchScale, easeOut(u / Egg.CrouchAt))
		else
			pose.sy = lerp(Egg.CrouchScale, Egg.StretchScale, easeIn((u - Egg.CrouchAt) / (1 - Egg.CrouchAt)))
		end
		pose.sxz = 1 / math.sqrt(pose.sy)
		-- Dramatic eggs tremble while crouched.
		if tl.beat.dramatic then
			pose.roll = math.rad(2.5) * math.sin(TAU * 18 * t)
		end
	end
	return pose
end

-- Fade-out of a flying piece: 0 until FadeFrom of the flight, then up to 1.
local function flightFade(tl: Timeline, tau: number): number
	local u = tau / math.max(tl.speed.Fly, EPSILON)
	return clamp01((u - Shell.FadeFrom) / (1 - Shell.FadeFrom))
end

--[[ The ShellTop cap after the burst: ballistic flight + spin, fading (about its own centre). ]]
function HatchAnim.cap(tl: Timeline, t: number): Motion
	local tau = if t == t then math.clamp(t - tl.burst, 0, tl.speed.Fly) else 0
	local v = Shell.CapVelocity
	local spin = Shell.CapSpin
	return {
		offset = Vector3.new(v.X * tau, v.Y * tau - 0.5 * Shell.Gravity * tau * tau, v.Z * tau),
		rx = spin.X * tau,
		ry = spin.Y * tau,
		rz = spin.Z * tau,
		scale = 1,
		fade = if t >= tl.burst + tl.speed.Fly then 1 else flightFade(tl, tau),
	}
end

--[[ The ShellBottom cup after the burst: sinks, tips and shrinks while it fades away. ]]
function HatchAnim.cup(tl: Timeline, t: number): Motion
	local u = if t == t
		then progress(t, tl.burst, Shell.CupTime * (tl.speed.Fly / HatchAnimConfig.Profiles.Normal.Fly))
		else 0
	return {
		offset = Vector3.new(0, -Shell.CupDrop * u * u, 0),
		rx = math.rad(Shell.CupTip) * u,
		ry = 0,
		rz = 0,
		scale = lerp(1, Shell.CupShrink, u),
		fade = u,
	}
end

--[[
	Shard `index` after the burst: flies out along `outward` (its rest direction from the egg
	axis, XZ) with an upward kick, gravity and a per-shard spin. Hidden before the burst.
]]
function HatchAnim.shard(tl: Timeline, t: number, index: number, outward: Vector3): Motion
	if t ~= t or t < tl.burst then
		return { offset = Vector3.zero, rx = 0, ry = 0, rz = 0, scale = 1, fade = 1 }
	end
	local tau = math.min(t - tl.burst, tl.speed.Fly)
	local flat = Vector3.new(outward.X, 0, outward.Z)
	local dir = if flat.Magnitude > 1e-4 then flat.Unit else Vector3.new(0, 0, -1)
	local speed = lerp(Shell.ShardSpeed.X, Shell.ShardSpeed.Y, hash(index, 1))
	local lift = lerp(Shell.ShardLift.X, Shell.ShardLift.Y, hash(index, 2))
	local spin = lerp(Shell.ShardSpin.X, Shell.ShardSpin.Y, hash(index, 3))
	local sign = if hash(index, 4) < 0.5 then -1 else 1
	return {
		offset = dir * speed * tau + Vector3.new(0, lift * tau - 0.5 * Shell.Gravity * tau * tau, 0),
		rx = spin * tau * sign,
		ry = spin * 0.6 * tau,
		rz = spin * 0.8 * tau * -sign,
		scale = 1,
		fade = if t >= tl.burst + tl.speed.Fly then 1 else flightFade(tl, tau),
	}
end

--------------------------------------------------------------------------------------------------
-- Cracks + light
--------------------------------------------------------------------------------------------------

--[[ Opacity 0..1 of crack stage `stage` (fades in at its time, gone at the burst). ]]
function HatchAnim.crack(tl: Timeline, t: number, stage: number): number
	local at = tl.cracks[stage]
	if at == nil or t ~= t or t >= tl.burst then
		return 0
	end
	return progress(t, at, Light.CrackFadeIn)
end

-- Number of crack stages visible at `t` (0..3).
local function crackCount(tl: Timeline, t: number): number
	local count = 0
	for _, at in tl.cracks do
		if t >= at then
			count += 1
		end
	end
	return count
end
HatchAnim.crackCount = crackCount

--[[ 0..1 brightness of the light leaking through the cracks (pulses, brighter per stage). ]]
function HatchAnim.crackGlow(tl: Timeline, t: number): number
	if t ~= t then
		return 0
	end
	local stages = crackCount(tl, t)
	if stages == 0 then
		return 0
	end
	local pulse = 0.78 + 0.22 * math.sin(TAU * Light.CrackPulseHz * t)
	return clamp01((0.45 + 0.55 * stages / HatchAnimConfig.CrackStages) * pulse)
end

--[[ 0..1 strength of the soft halo behind the egg / pet (x Rarity.glow). ]]
function HatchAnim.halo(tl: Timeline, t: number): number
	if t ~= t or t < tl.start then
		return 0
	end
	local glow = tl.beat.glow
	if t < tl.burst then
		local stages = crackCount(tl, t)
		local level = if stages > 0 then Light.HaloStage[stages] else 0
		-- Ramp from the previous stage's level over the fade-in so it never pops.
		if stages > 0 then
			local before = if stages > 1 then Light.HaloStage[stages - 1] else 0
			level = lerp(before, level, progress(t, tl.cracks[stages], 0.2))
		end
		if t >= tl.squashStart and not tl.reduced and not tl.granted then
			level = lerp(level, Light.HaloBurst * 0.8, progress(t, tl.squashStart, tl.burst - tl.squashStart))
		end
		return clamp01(level * glow)
	end
	if tl.reduced then
		return clamp01(Light.HaloRest * glow * progress(t, tl.burst, tl.popEnd - tl.burst))
	end
	-- Peak at the burst, settle behind the pet.
	return clamp01(lerp(Light.HaloBurst, Light.HaloRest, smooth(progress(t, tl.burst, 0.6))) * glow)
end

--[[
	The rays behind the egg / pet: (opacity 0..1, size multiplier, rotation degrees).
	Before the burst only Rare+ (`Rarity.rays`) show faint rays that grow with the cracks.
]]
function HatchAnim.rays(tl: Timeline, t: number): (number, number, number)
	if t ~= t or t < tl.start then
		return 0, Light.RayScaleBuild, 0
	end
	local beat = tl.beat
	local buildSpin = Light.RayBuildSpeed * (math.min(t, tl.burst) - tl.start)
	if t < tl.burst then
		local opacity = 0
		if beat.rays and not tl.reduced then
			local cracked = crackCount(tl, t) / HatchAnimConfig.CrackStages
			opacity = Light.RayBuildOpacity * smooth(cracked) * beat.glow
		end
		return opacity, Light.RayScaleBuild, buildSpin % 360
	end
	if tl.reduced then
		return Light.RayOpacity * progress(t, tl.burst, tl.popEnd - tl.burst), Light.RayScaleRest, 0
	end
	local u = progress(t, tl.burst, 0.45)
	local opacity = lerp(if beat.rays then Light.RayBuildOpacity * beat.glow else 0, Light.RayOpacity, smooth(u))
	local scale = Light.RayScaleBuild
		+ (Light.RayScaleRest - Light.RayScaleBuild) * HatchAnim.spring(u, BannerCfg.Damping, BannerCfg.Frequency)
	local rotation = (buildSpin + beat.raySpeed * (t - tl.burst)) % 360
	return opacity, scale, rotation
end

-- The flash curve 0..1 around the burst (linear rise, quadratic fall).
local function flashShape(tl: Timeline, t: number): number
	if tl.reduced or t ~= t or t < tl.burst then
		return 0
	end
	local tau = t - tl.burst
	local rise = math.max(Light.FlashRise, EPSILON)
	if tau < rise then
		return tau / rise
	end
	local fall = Light.FlashFall * (if tl.fast then 0.65 else 1)
	local u = clamp01((tau - rise) / math.max(fall, EPSILON))
	return (1 - u) * (1 - u)
end

--[[ Opacity of the soft flash over the egg (owner R19: peaks at Light.FlashPeak, never white-out). ]]
function HatchAnim.flash(tl: Timeline, t: number): number
	return Light.FlashPeak * flashShape(tl, t)
end

--[[ Opacity of the full-screen wash at the burst (rarer = a little stronger, still soft). ]]
function HatchAnim.wash(tl: Timeline, t: number): number
	return (Light.WashPeak + Light.WashPerRank * tl.rank) * flashShape(tl, t)
end

--[[ Room dim TRANSPARENCY for this egg at `t` (the screen uses the darkest of all slots). ]]
function HatchAnim.dim(tl: Timeline, t: number): number
	if t ~= t then
		return Light.DimBase
	end
	if t < tl.burst then
		if tl.beat.dramatic and not tl.reduced then
			return lerp(Light.DimBase, Light.DimDramatic, smooth(buildUp(tl, t)))
		end
		return Light.DimBase
	end
	local from = if tl.beat.dramatic and not tl.reduced then Light.DimDramatic else Light.DimBase
	return lerp(from, Light.DimReveal, smooth(progress(t, tl.burst, 0.4)))
end

--[[ Viewport ambient factor 0..1 (the egg darkens as it cracks so the Neon cracks pop). ]]
function HatchAnim.ambient(tl: Timeline, t: number): number
	if t ~= t or tl.reduced or tl.granted then
		return 1
	end
	local low = if tl.beat.dramatic then Light.AmbientDramatic else Light.AmbientCracked
	if t < tl.burst then
		local cracked = crackCount(tl, t) / HatchAnimConfig.CrackStages
		local target = lerp(1, low, cracked)
		if tl.beat.dramatic then
			target = math.min(target, lerp(1, low, smooth(buildUp(tl, t))))
		end
		return target
	end
	return lerp(low, 1, smooth(progress(t, tl.burst, 0.3)))
end

--[[
	Viewport jitter in design px (camera-shake look): dramatic eggs shake harder toward the
	burst; Legendary+ bursts kick once. (0, 0) for everything else and with reduced motion.
]]
function HatchAnim.jitter(tl: Timeline, t: number): (number, number)
	if tl.reduced or t ~= t or t < tl.start then
		return 0, 0
	end
	local amplitude = 0
	if tl.beat.dramatic and t < tl.burst then
		amplitude = Light.JitterPixels * easeIn(buildUp(tl, t))
	end
	if tl.rank >= 5 and t >= tl.burst then
		local u = progress(t, tl.burst, Light.JitterDecay)
		amplitude = math.max(amplitude, Light.JitterBurst * (1 - u) * (1 - u))
	end
	if amplitude <= 0 then
		return 0, 0
	end
	local dx = amplitude * (math.sin(t * 61.3) * 0.6 + math.sin(t * 97.1 + 1.7) * 0.4)
	local dy = amplitude * (math.sin(t * 53.7 + 0.3) * 0.6 + math.sin(t * 89.9 + 2.9) * 0.4)
	return dx, dy
end

--------------------------------------------------------------------------------------------------
-- Pet + banner
--------------------------------------------------------------------------------------------------

--[[ The pet's pop-out: hidden before the burst, then a spring scale + a jump out of the cup. ]]
function HatchAnim.pet(tl: Timeline, t: number): PetPose
	if t ~= t or t < tl.burst then
		return { visible = false, scale = PetCfg.From, y = 0, fade = 1 }
	end
	if tl.reduced then
		return { visible = true, scale = 1, y = 0, fade = 1 - progress(t, tl.burst, tl.popEnd - tl.burst) }
	end
	local u = progress(t, tl.burst, tl.popEnd - tl.burst)
	local scale = PetCfg.From + (1 - PetCfg.From) * HatchAnim.spring(u, PetCfg.Damping, PetCfg.Frequency)
	local v = clamp01(u / PetCfg.JumpPart)
	-- Starts low inside the cup (granted pets start at rest height), arcs up, lands at 0.
	local from = if tl.granted then 0 else 0.5
	local y = if v < 1 then from * (1 - v) + PetCfg.JumpHeight * 4 * v * (1 - v) else 0
	return { visible = true, scale = math.max(scale, 0.01), y = y, fade = 0 }
end

--[[ The rarity banner: hidden before `banner`, then a spring pop (a fade with reduced motion). ]]
function HatchAnim.banner(tl: Timeline, t: number): BannerPose
	if t ~= t or t < tl.banner then
		return { visible = false, scale = BannerCfg.From, fade = 1 }
	end
	local u = progress(t, tl.banner, tl.bannerEnd - tl.banner)
	if tl.reduced then
		return { visible = true, scale = 1, fade = 1 - u }
	end
	local scale = BannerCfg.From + (1 - BannerCfg.From) * HatchAnim.spring(u, BannerCfg.Damping, BannerCfg.Frequency)
	return { visible = true, scale = math.max(scale, 0.01), fade = 0 }
end

--------------------------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------------------------

local function push(list: { Event }, time: number, kind: EventKind, key: string?, pitch: number?, volume: number?)
	table.insert(list, { time = time, kind = kind, key = key or "", pitch = pitch or 1, volume = volume or 1 })
end

--[[
	Every one-shot of this egg in time order: build-up sounds (intro pop, a clack per shake
	burst rising in pitch, a sharper crack per stage, the dramatic low swell), the burst (hatch +
	pop, haptic, confetti), the rarity stinger cues, sparkles with the banner and the pet's
	happy spin once it has landed. Reduced motion keeps the sounds + haptic, drops the motion.
]]
function HatchAnim.events(tl: Timeline): { Event }
	local list: { Event } = {}
	local sounds = HatchAnimConfig.Sounds
	if not tl.granted and not tl.reduced then
		push(list, tl.start, "sound", sounds.Intro.key, sounds.Intro.pitch, sounds.Intro.volume)
		if tl.beat.dramatic then
			push(list, tl.wobbleStart, "sound", sounds.Rumble.key, sounds.Rumble.pitch, sounds.Rumble.volume)
		end
		for _, b in tl.bursts do
			local pitch = sounds.Wobble.pitch + sounds.WobblePitchStep * (b.index - 1)
			push(list, b.start, "sound", sounds.Wobble.key, pitch, sounds.Wobble.volume * (0.85 + 0.15 * b.strength))
		end
		for stage, at in tl.cracks do
			push(
				list,
				at,
				"sound",
				sounds.Crack.key,
				sounds.Crack.pitch + sounds.CrackPitchStep * (stage - 1),
				sounds.Crack.volume
			)
		end
	end
	if not tl.reduced then
		push(list, tl.burst, "sound", sounds.Burst.key, sounds.Burst.pitch, sounds.Burst.volume)
		push(list, tl.burst, "sound", sounds.BurstPop.key, sounds.BurstPop.pitch, sounds.BurstPop.volume)
		push(list, tl.burst, "confetti")
		push(list, tl.banner, "sparkles")
		push(list, tl.popEnd + PetCfg.HappyAfter, "happy")
	end
	push(list, tl.burst, "haptic")
	for _, c in tl.beat.reveal do
		push(list, tl.burst + c.delay, "sound", c.key, c.pitch, c.volume)
	end
	-- Stable sort by time (insertion order breaks ties).
	local order: { [Event]: number } = {}
	for index, event in list do
		order[event] = index
	end
	table.sort(list, function(a: Event, b: Event): boolean
		if a.time ~= b.time then
			return a.time < b.time
		end
		return order[a] < order[b]
	end)
	return list
end

return HatchAnim
