--!strict
--[[
	PetAnim — pure procedural pose maths for every pet (owner R44: "make sure all of the pets have
	animations and stuff too"). No services, no Instances: a rig is built from piece NAMES + rest
	offsets, a per-pet State is stepped with plain numbers, and `pose` writes one model-space
	CFrame per piece. The renderers (PetController followers, PetViewport UI models) multiply those
	by the pet's world / viewport frame and move everything in one BulkMoveTo / one pass.
	tests/pet-anim.luau runs this module in lune for all 29 species.

	RIG (B8f art contract, docs/pets-art.md §1 — piece-name prefix = animation group):
		Head*            nod / look about the neck joint (Head, HeadFace, HeadShine, HeadEars, ...)
		Tail*            wag about the tail root (axis per species: Yaw wag, Pitch thump, Roll fan,
		                 Sway for the jelly's tentacle skirt)
		WingL* / WingR*  flap about the shoulders (mirrored: WingL = -WingR), flippers too
		ClawL* / ClawR*  crab claws: raise / snip / wave
		Orbit*           Neon atom rings spin about +Y through their joint
		anything else    the rigid Body (Glow* pieces additionally pulse their Transparency)
	Joints come from the MeshAssets pivot string (`joints Head@(x,y,z) ...`, parseJoints); a group
	without one gets a joint derived from its bounding box (neck = bottom of the head, wings = the
	inner edge, ...). Every group moves rigidly (R25: an assembly moves as one unit): squash
	compresses the BODY pieces about the pivot and translates each limb group by its joint's
	compression, so a head never comes apart from its face / ears / hat.

	STYLE (derived; PetAnimConfig.Species overrides): ClawL/ClawR -> Scuttle, hover + wings -> Fly,
	hover -> Float, else Walk; overrides add Hop / Blob / Swim.

	LAYERS per frame (`step`):
		1. locomotion by style, scaled by the smoothed stride blend `move` (speed / MoveSpeedRef):
		   Walk waddle + step bounce + squash-stretch + head bob; Hop / Blob hops; Fly flap + bank
		   on turns; Swim undulate + paddle; Float bell pulse + drift; Scuttle rock + claw snips.
		2. tail wag (faster when moving), orbit spin, glow pulse.
		3. idle (1 - move): breathing, looking around, random cute actions (Sit / Spin / Hop /
		   Swoop / Flip / Wave / Jiggle per style).
		4. events: happy spin + hop (PetAnim.happy, staggered per team slot); sleep blend (owner
		   AFK): lie down / sink, droop head, curl tail, slow breathing.
	DETAIL: Full = everything; Simple (Low tier / mid distance) = body bob + wings only; Off = the
	caller skips the pet. REDUCED (Reduce Motion) = gentle idle only: no hops, spins, look-arounds
	or actions; wings / tail / orbit at reduced amplitude.

	Performance: no tables / closures are created per frame (State, its `frames` / `shift` maps and
	the caller's `out` array are reused). CFrame maths allocates userdata (unavoidable in Luau);
	`pose` builds one CFrame per group + one per piece.

	Example:
		local rig = PetAnim.buildRig({ key = "FissionFox", names = names, rest = offsets,
			sizes = sizes, transparency = alphas, joints = PetAnim.parseJoints(entry.pivot), hover = 0 })
		local state = PetAnim.newState(42)
		PetAnim.step(rig, state, dt, speed, turnRate, false, PetAnim.Detail.Full, false)
		PetAnim.pose(rig, state, out, PetAnim.Detail.Full)  -- out[i] = model-space CFrame of piece i
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PetAnimConfig = require(ReplicatedStorage.Shared.Config.PetAnimConfig)
local PetConfig = require(ReplicatedStorage.Shared.Config.PetConfig)

type Style = PetAnimConfig.Style
type TailAxis = PetAnimConfig.TailAxis
type Action = PetAnimConfig.Action

export type Group = "Body" | "Head" | "Tail" | "WingL" | "WingR" | "ClawL" | "ClawR" | "Orbit"

-- What a renderer knows about one pet model (arrays aligned by piece index).
export type RigSpec = {
	key: string, -- MeshAssets species key (PetConfig model)
	names: { string },
	rest: { CFrame }, -- each piece relative to the pet root (ground pivot, front = -Z)
	sizes: { Vector3 },
	transparency: { number },
	joints: { [string]: Vector3 }, -- model space (already scaled like the model)
	hover: number, -- species flying height (PetConfig hover)
	scale: number?, -- the model's scale (Model:GetScale(); default 1): motion amplitudes follow it
}

export type Rig = {
	key: string,
	style: Style,
	tailAxis: TailAxis,
	jiggle: number,
	hover: number,
	airborne: boolean, -- rocks / squashes about the body centre instead of the feet
	count: number,
	names: { string },
	groups: { Group },
	rest: { CFrame },
	joints: { [Group]: Vector3 },
	has: { [Group]: boolean },
	squash: { number }, -- piece indices whose Size squashes (PetAnimConfig.SquashPieces)
	restSize: { Vector3 }, -- aligned with `squash`
	glow: { number }, -- piece indices that pulse
	glowRest: { number }, -- their rest Transparency, aligned with `glow`
	pivotY: number,
	centerY: number,
	height: number, -- top of the model (emote anchor)
	anchor: number, -- piece index emotes attach to (Head, else Body, else 1)
	scale: number, -- model scale the rig is sized for (rescaleRig keeps it in step with ScaleTo)
}

export type State = {
	seed: number, -- deterministic per-pet random stream
	viewport: boolean, -- UI viewport (smaller vertical moves, no big hops)
	t: number,
	-- smoothed drivers
	move: number, -- 0..1 stride blend
	turn: number, -- rad/s
	sleep: number, -- 0..1
	-- phases
	stride: number,
	flap: number,
	wag: number,
	cycle: number,
	breathe: number,
	glowPhase: number,
	orbit: number,
	-- look around
	lookYaw: number,
	lookPitch: number,
	lookYawGoal: number,
	lookPitchGoal: number,
	lookIn: number,
	-- idle actions
	action: Action?,
	actionT: number,
	actionIn: number,
	-- happy
	happyDelay: number,
	happyLeft: number,
	-- OUTPUT pose (radians / studs / scale)
	y: number,
	pitch: number,
	yaw: number,
	roll: number,
	swayX: number,
	swayZ: number,
	sx: number,
	sy: number,
	headPitch: number,
	headYaw: number,
	headRoll: number,
	tailPitch: number,
	tailYaw: number,
	tailRoll: number,
	wing: number, -- WingR roll (up = +); WingL mirrors it
	clawL: number,
	clawR: number,
	clawPitch: number,
	glow: number, -- 0 (rest) .. 1 (dimmest)
	-- reused buffers
	frames: { [Group]: CFrame? },
	shift: { [Group]: Vector3? },
	-- renderer bookkeeping (PetModels.applyLook): last written values
	lastSx: number,
	lastSy: number,
	lastGlow: number,
}

local PetAnim = {}

PetAnim.Detail = PetAnimConfig.Detail

local Motion = PetAnimConfig.Motion
local Idle = PetAnimConfig.Idle
local Happy = PetAnimConfig.Happy
local Sleep = PetAnimConfig.Sleep
local Reduced = PetAnimConfig.Reduced
local Limits = PetAnimConfig.Limits
local Shape = PetAnimConfig.ActionShape
local Follow = PetConfig.Follow

local DETAIL_FULL = PetAnimConfig.Detail.Full
local TAU = 2 * math.pi
local PI = math.pi
local rad = math.rad
local sin = math.sin
local cos = math.cos
local abs = math.abs

-- Group prefixes, longest / most specific first (art contract: "match the longest first").
local PREFIXES: { Group } = { "WingL", "WingR", "ClawL", "ClawR", "Orbit", "Head", "Tail" }
local LIMB_GROUPS: { Group } = { "Head", "Tail", "WingL", "WingR", "ClawL", "ClawR", "Orbit" }

--------------------------------------------------------------------------------------------------
-- Small maths helpers
--------------------------------------------------------------------------------------------------

-- True for a real, finite number (rejects NaN and ±inf).
local function finite(x: number): boolean
	return x == x and x > -math.huge and x < math.huge
end

-- `x` clamped to [lo, hi]; NaN / inf become `fallback`.
local function safe(x: number, lo: number, hi: number, fallback: number): number
	if not finite(x) then
		return fallback
	end
	return math.clamp(x, lo, hi)
end

-- Frame-rate independent smoothing factor (same curve as PetFollow.alpha).
local function alpha(rate: number, dt: number): number
	return 1 - math.exp(-rate * dt)
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Smoothstep 0..1.
local function smooth01(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- 0 → 1 over the first `edge` of u, 1 → 0 over the last `edge` (u in 0..1): eases an action in
-- and out so it never pops.
local function envelope(u: number, edge: number): number
	return smooth01(u / edge) * smooth01((1 - u) / edge)
end

-- Moves `value` toward `target` by at most `delta`.
local function toward(value: number, target: number, delta: number): number
	if value < target then
		return math.min(value + delta, target)
	end
	return math.max(value - delta, target)
end

-- The next number of the state's deterministic stream in [0, 1) (Park–Miller LCG; exact in doubles).
local function random(state: State): number
	state.seed = (state.seed * 48271) % 2147483647
	return state.seed / 2147483647
end

-- A random number inside a { min, max } range table.
local function within(state: State, range: { number }): number
	return lerp(range[1], range[2], random(state))
end

-- The rotation `rotation` applied about model-space point `joint` (T(j) * R * T(-j), one alloc).
local function about(joint: Vector3, rotation: CFrame): CFrame
	return rotation + (joint - rotation * joint)
end

--------------------------------------------------------------------------------------------------
-- Rig building
--------------------------------------------------------------------------------------------------

--[[
	The animation group of a piece name (B8f prefix contract).
	Example: PetAnim.groupOf("HeadEars") --> "Head"; PetAnim.groupOf("Glow") --> "Body"
]]
function PetAnim.groupOf(name: string): Group
	for _, prefix in PREFIXES do
		if string.sub(name, 1, #prefix) == prefix then
			return prefix
		end
	end
	return "Body"
end

--[[
	Joints out of a MeshAssets pivot string ("...; joints Head@(0,1.11,-0.11) Tail@(0,0.82,0.74)").
	Unparsable numbers are skipped (never NaN). "joints none" → {}.
	Example: PetAnim.parseJoints(MeshAssets.FissionFox.pivot).Head --> Vector3(0, 1.11, -0.11)
]]
function PetAnim.parseJoints(pivot: string?): { [string]: Vector3 }
	local joints: { [string]: Vector3 } = {}
	if type(pivot) ~= "string" then
		return joints
	end
	for name, x, y, z in string.gmatch(pivot, "(%w+)@%(([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)%)") do
		local nx, ny, nz = tonumber(x), tonumber(y), tonumber(z)
		if nx ~= nil and ny ~= nil and nz ~= nil and finite(nx) and finite(ny) and finite(nz) then
			joints[name] = Vector3.new(nx, ny, nz)
		end
	end
	return joints
end

-- A joint for a group the pivot string does not list, from the group's bounding box.
local function deriveJoint(group: Group, lo: Vector3, hi: Vector3): Vector3
	local c = (lo + hi) / 2
	if group == "Head" then
		-- The neck: low in the head, where it is buried in the body.
		return Vector3.new(c.X, lo.Y + (hi.Y - lo.Y) * 0.15, c.Z)
	elseif group == "Tail" then
		-- The tail root: its front edge (toward the body; the pet faces -Z).
		return Vector3.new(c.X, c.Y, lo.Z)
	elseif group == "WingL" or group == "ClawL" then
		-- Left limbs hinge on their inner (+X) edge, right limbs on their inner (-X) edge.
		return Vector3.new(hi.X, c.Y, c.Z)
	elseif group == "WingR" or group == "ClawR" then
		return Vector3.new(lo.X, c.Y, c.Z)
	end
	return c
end

local function minV(a: Vector3, b: Vector3): Vector3
	return Vector3.new(math.min(a.X, b.X), math.min(a.Y, b.Y), math.min(a.Z, b.Z))
end

local function maxV(a: Vector3, b: Vector3): Vector3
	return Vector3.new(math.max(a.X, b.X), math.max(a.Y, b.Y), math.max(a.Z, b.Z))
end

--[[
	Builds the animation rig of one pet model (once per model, not per frame).
	@param spec RigSpec  piece names / rest offsets / sizes / transparencies + joints + hover
	@return Rig
]]
function PetAnim.buildRig(spec: RigSpec): Rig
	local count = #spec.names
	local groups: { Group } = {}
	local has: { [Group]: boolean } = {}
	local lo: { [Group]: Vector3 } = {}
	local hi: { [Group]: Vector3 } = {}
	local top = 0
	local bodyIndex: number? = nil
	local headIndex: number? = nil
	for index, name in spec.names do
		local group = PetAnim.groupOf(name)
		groups[index] = group
		has[group] = true
		local position = spec.rest[index].Position
		local half = spec.sizes[index] / 2
		local low, high = position - half, position + half
		lo[group] = if lo[group] ~= nil then minV(lo[group], low) else low
		hi[group] = if hi[group] ~= nil then maxV(hi[group], high) else high
		top = math.max(top, high.Y)
		if name == "Body" then
			bodyIndex = index
		elseif name == "Head" then
			headIndex = index
		end
	end

	local joints: { [Group]: Vector3 } = {}
	for _, group in LIMB_GROUPS do
		if has[group] then
			joints[group] = spec.joints[group] or deriveJoint(group, lo[group], hi[group])
		end
	end

	-- Style: species override, else derived from the pieces + hover.
	local override = PetAnimConfig.Species[spec.key]
	local style: Style
	if override ~= nil and override.style ~= nil then
		style = override.style
	elseif has.ClawL and has.ClawR then
		style = "Scuttle"
	elseif spec.hover > 0 and has.WingL and has.WingR then
		style = "Fly"
	elseif spec.hover > 0 then
		style = "Float"
	else
		style = "Walk"
	end
	local airborne = spec.hover > 0 or style == "Fly" or style == "Swim" or style == "Float"

	local centerY = 0
	if bodyIndex ~= nil then
		centerY = spec.rest[bodyIndex].Position.Y
	elseif lo.Body ~= nil then
		centerY = (lo.Body.Y + hi.Body.Y) / 2
	end

	local squash: { number } = {}
	local restSize: { Vector3 } = {}
	local glow: { number } = {}
	local glowRest: { number } = {}
	for index, name in spec.names do
		if groups[index] == "Body" and PetAnimConfig.SquashPieces[name] == true then
			table.insert(squash, index)
			table.insert(restSize, spec.sizes[index])
		end
		local transparency = spec.transparency[index] or 0
		if string.find(name, PetAnimConfig.GlowToken, 1, true) ~= nil and transparency < 0.95 then
			table.insert(glow, index)
			table.insert(glowRest, transparency)
		end
	end

	return {
		key = spec.key,
		style = style,
		tailAxis = (override ~= nil and override.tailAxis) or "Yaw",
		jiggle = (override ~= nil and override.jiggle) or 1,
		hover = spec.hover,
		airborne = airborne,
		count = count,
		names = spec.names,
		groups = groups,
		rest = spec.rest,
		joints = joints,
		has = has,
		squash = squash,
		restSize = restSize,
		glow = glow,
		glowRest = glowRest,
		pivotY = if airborne then centerY else 0,
		centerY = centerY,
		height = top,
		anchor = headIndex or bodyIndex or 1,
		scale = if spec.scale ~= nil and finite(spec.scale) and spec.scale > 0 then spec.scale else 1,
	}
end

--------------------------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------------------------

--[[
	A fresh per-pet animation state (reused every frame). `seed` desynchronises a team: different
	seeds start every phase / look / action timer at a different point.
	@param seed      any number (slot index, hashed pet id, ...)
	@param viewport  true inside a UI viewport (gentler vertical moves, no big hops)
]]
function PetAnim.newState(seed: number, viewport: boolean?): State
	local start = if finite(seed) then math.floor(abs(seed) * 7919) % 2147483646 + 1 else 1
	local state: State = {
		seed = start,
		viewport = viewport == true,
		t = 0,
		move = 0,
		turn = 0,
		sleep = 0,
		stride = 0,
		flap = 0,
		wag = 0,
		cycle = 0,
		breathe = 0,
		glowPhase = 0,
		orbit = 0,
		lookYaw = 0,
		lookPitch = 0,
		lookYawGoal = 0,
		lookPitchGoal = 0,
		lookIn = 0,
		action = nil,
		actionT = 0,
		actionIn = 0,
		happyDelay = 0,
		happyLeft = 0,
		y = 0,
		pitch = 0,
		yaw = 0,
		roll = 0,
		swayX = 0,
		swayZ = 0,
		sx = 1,
		sy = 1,
		headPitch = 0,
		headYaw = 0,
		headRoll = 0,
		tailPitch = 0,
		tailYaw = 0,
		tailRoll = 0,
		wing = 0,
		clawL = 0,
		clawR = 0,
		clawPitch = 0,
		glow = 0,
		frames = {},
		shift = {},
		lastSx = 1,
		lastSy = 1,
		lastGlow = 0,
	}
	-- Warm the stream a little (nearby seeds diverge), then scatter every phase.
	random(state)
	random(state)
	state.flap = random(state)
	state.wag = random(state)
	state.cycle = random(state)
	state.breathe = random(state)
	state.glowPhase = random(state)
	state.orbit = random(state) * TAU
	state.lookIn = random(state) * 2
	state.actionIn = within(state, Idle.ActionEvery)
	return state
end

--[[
	Starts the happy spin (owner purchase / hatch / equip). Ignored while one is already playing (a
	restart mid-spin would pop the yaw). Cancels any idle action.
	@param delay seconds before this pet starts (team stagger)
]]
function PetAnim.happy(state: State, delay: number?)
	if state.happyLeft > 0 then
		return
	end
	local wait = delay or 0
	state.happyDelay = if finite(wait) then math.max(wait, 0) else 0
	state.happyLeft = Happy.Duration
	state.action = nil
end

--[[ True while the happy spin is pending or playing. ]]
function PetAnim.isHappy(state: State): boolean
	return state.happyLeft > 0
end

--------------------------------------------------------------------------------------------------
-- Step
--------------------------------------------------------------------------------------------------

--[[
	Advances one pet's animation by `dt` and writes the output pose fields of `s`.
	@param rig       the pet's Rig
	@param s         its State (mutated)
	@param dt        seconds since the last step (clamped to Motion.MaxDt; NaN / negative → 0)
	@param speed     the pet's horizontal speed (studs/s; 0 in viewports)
	@param turnRate  its yaw rate (rad/s, + = turning left)
	@param asleep    the owner has been AFK for Sleep.After seconds
	@param detail    PetAnim.Detail.Full / Simple (Off: do not call)
	@param reduced   Reduce Motion: gentle idle only
]]
function PetAnim.step(
	rig: Rig,
	s: State,
	dt: number,
	speed: number,
	turnRate: number,
	asleep: boolean,
	detail: number,
	reduced: boolean
)
	if not finite(dt) or dt < 0 then
		dt = 0
	end
	dt = math.min(dt, Motion.MaxDt)
	if not finite(speed) or speed < 0 then
		speed = 0
	end
	speed = math.min(speed, 200)
	if not finite(turnRate) then
		turnRate = 0
	end
	turnRate = math.clamp(turnRate, -30, 30)
	s.t += dt

	local full = detail >= DETAIL_FULL
	local calm = reduced
	local amp = if calm then Reduced.Scale else 1
	-- Positional amplitudes follow the model's scale (a 2× reveal pet bobs 2× as far).
	local size = rig.scale
	local lift = (if s.viewport then Shape.ViewportLift else 1) * size
	local style = rig.style

	-- Smoothed drivers.
	local moveTarget = if speed < Motion.MoveDeadzone then 0 else math.min(speed / Motion.MoveSpeedRef, 1)
	s.move += (moveTarget - s.move) * alpha(Motion.MoveBlendRate, dt)
	s.turn += (turnRate - s.turn) * alpha(Motion.TurnSmoothing, dt)
	s.sleep = toward(s.sleep, if asleep then 1 else 0, Sleep.BlendRate * dt)
	local m = s.move
	local sl = s.sleep

	-- Happy progress (u 0..1 while playing, -1 otherwise).
	local happyU = -1
	if s.happyLeft > 0 then
		if s.happyDelay > 0 then
			s.happyDelay -= dt
		else
			s.happyLeft = math.max(s.happyLeft - dt, 0)
			happyU = 1 - s.happyLeft / Happy.Duration
		end
	end
	local happy = happyU >= 0

	local y, pitch, yaw, roll, swayX, swayZ = 0, 0, 0, 0, 0, 0
	local sx, sy = 1, 1
	local headPitch, headYaw, headRoll = 0, 0, 0
	local tailPitch, tailYaw, tailRoll = 0, 0, 0
	local wing = 0
	local clawL, clawR, clawPitch = 0, 0, 0
	local styleTail: number? = nil -- a style that drives the tail itself (Swim undulation)

	-- Banking into turns (flyers / swimmers), + turn (left) → + roll (left side down).
	local bank = safe(s.turn * Motion.Fly.BankGain, -rad(Motion.Fly.BankMax), rad(Motion.Fly.BankMax), 0) * amp

	-- 1. Locomotion by style ---------------------------------------------------------------------
	if style == "Walk" or style == "Scuttle" then
		local walk = Motion.Walk
		local scuttle = Motion.Scuttle
		local strideLength = if style == "Walk" then walk.StrideLength else scuttle.StrideLength
		local maxRate = if style == "Walk" then walk.MaxStepRate else scuttle.MaxStepRate
		s.stride = (s.stride + math.min(speed / strideLength, maxRate) * dt) % 1024
		local x = s.stride
		-- 0 at each foot contact, 1 mid-step; alternating sign → waddle side to side.
		local hop = abs(sin(PI * x))
		if not calm then
			y += (if style == "Walk" then walk.Bounce else scuttle.Bounce) * hop * m * lift
		end
		roll += rad(if style == "Walk" then walk.Waddle else scuttle.Rock) * sin(PI * x) * m * amp
		if style == "Walk" then
			pitch -= rad(walk.Lean) * m
			if not calm then
				sy += m * (walk.Stretch * hop - walk.Squash * (1 - hop) ^ 4)
			end
			headPitch += rad(walk.HeadBob) * sin(TAU * x) * m * amp
			wing += rad(walk.WingFlap) * m * amp * (0.5 + 0.5 * sin(TAU * x))
		else
			local snip = rad(scuttle.ClawSnip) * sin(TAU * scuttle.SnipRate * s.t) * (0.3 + 0.7 * m) * amp
			clawL += rad(scuttle.ClawRaise) * m + snip
			clawR += rad(scuttle.ClawRaise) * m + snip
		end
	elseif style == "Hop" or style == "Blob" then
		local hopCfg = Motion.Hop
		local rate = math.min(speed / hopCfg.HopLength, hopCfg.MaxRate)
		if m > 0.05 then
			rate = math.max(rate, hopCfg.MinRate)
		end
		s.stride = (s.stride + rate * dt) % 1024
		local f = s.stride % 1
		local u = sin(PI * f) -- 0 on the ground, 1 at the top of the hop
		if not calm then
			y += hopCfg.Height * u * m * lift
			-- Nose up while rising, down while falling (continuous across landings).
			pitch += rad(hopCfg.Tilt) * sin(TAU * f) * m
			sy += m * (hopCfg.Stretch * u - hopCfg.Squash * (1 - u) ^ 4)
		end
		if style == "Blob" then
			local wobble = Motion.Blob.Jiggle
				* rig.jiggle
				* sin(TAU * Motion.Blob.JiggleRate * s.t)
				* (1 - 0.5 * m)
				* amp
			sy += wobble
			sx -= wobble * 0.5
		end
	elseif style == "Fly" then
		local fly = Motion.Fly
		local rate = lerp(fly.FlapRateIdle, fly.FlapRateMove, m) * (1 - 0.6 * sl)
		if happy then
			rate *= Happy.FlapBoost
		end
		s.flap = (s.flap + rate * dt) % 1024
		local beat = TAU * s.flap
		wing += rad(lerp(fly.FlapIdle, fly.FlapMove, m)) * (1 - 0.6 * sl) * amp * sin(beat)
		-- The body lifts on each downstroke.
		y += fly.Bob * sin(beat - PI / 2) * amp * lift
		pitch -= rad(fly.Lean) * m
		roll += bank
		tailPitch += rad(fly.TailSwing) * sin(beat - 1) * amp
	elseif style == "Swim" then
		local swim = Motion.Swim
		s.cycle = (s.cycle + lerp(swim.Rate, swim.RateMove, m) * (1 - 0.5 * sl) * dt) % 1024
		local c = TAU * s.cycle
		pitch += rad(swim.Undulate) * sin(c) * amp - rad(swim.Lean) * m
		y += swim.Bob * sin(c + 1.2) * amp * lift
		wing += rad(swim.Flipper) * sin(c) * amp * (1 - 0.6 * sl)
		roll += bank * swim.BankScale
		styleTail = rad(swim.TailSwing) * sin(c - 1) * amp * (1 - 0.6 * sl)
	elseif style == "Float" then
		local float = Motion.Float
		s.cycle = (s.cycle + lerp(float.Rate, float.RateMove, m) * (1 - 0.5 * sl) * dt) % 1024
		local c = TAU * s.cycle
		local pulse = sin(c) * float.Pulse * rig.jiggle * amp
		sy += pulse
		sx -= pulse * 0.5
		y += float.Bob * sin(c - 0.8) * amp * lift
		swayX += float.Drift * sin(c * 0.37) * amp * size
		swayZ += float.Drift * sin(c * 0.29 + 1) * amp * size
		pitch -= rad(float.Lean) * m
		roll += bank * 0.5
	end

	-- Every airborne pet also bobs gently around its hover height (PetConfig.Follow curve).
	if rig.airborne then
		y += sin((s.t * Follow.BobRate) * TAU) * Follow.BobHeight * Motion.AirBobScale * amp * lift
	end

	-- 2. Tail, orbit, glow (Full detail) ----------------------------------------------------------
	if full and rig.has.Tail then
		local tail = Motion.Tail
		local rate = if happy then tail.HappyRate else lerp(tail.RateIdle, tail.RateMove, m)
		s.wag = (s.wag + rate * (1 - sl) * dt) % 1024
		local amount = rad(if happy then tail.Move else lerp(tail.Idle, tail.Move, m)) * (1 - sl) * amp
		local w = styleTail or amount * sin(TAU * s.wag)
		local axis = rig.tailAxis
		if axis == "Pitch" then
			tailPitch += w - rad(Sleep.Curl) * 0.4 * sl
		elseif axis == "Roll" then
			tailRoll += w * 0.5
		elseif axis == "Sway" then
			-- The jelly's tentacle skirt: a slow circular sway.
			local c = TAU * s.cycle
			local tentacle = rad(Motion.Float.Tentacle) * amp
			tailPitch += tentacle * sin(c - 1.4)
			tailRoll += tentacle * 0.6 * cos(c * 0.8)
		else
			tailYaw += w + rad(Sleep.Curl) * sl
		end
	end
	if full and rig.has.Orbit then
		local spin = rad(Motion.OrbitSpeed) * (if calm then Reduced.OrbitScale else 1) * (1 - 0.5 * sl)
		s.orbit = (s.orbit + spin * dt) % TAU
	end
	if full and #rig.glow > 0 then
		s.glowPhase = (s.glowPhase + dt / Motion.Glow.Period) % 1
		s.glow = 0.5 - 0.5 * cos(TAU * s.glowPhase)
	else
		s.glow = 0
	end

	-- 3. Idle: breathing, looking around, cute actions -------------------------------------------
	s.breathe = (s.breathe + dt / (Idle.BreathePeriod * (1 + Sleep.BreatheSlow * sl))) % 1024
	local breath = sin(TAU * s.breathe) * Idle.Breathe * (1 + 0.5 * sl) * (1 - m)
	if full then
		sy += breath
		sx -= breath * 0.5
	else
		-- Simple detail has no squash: breathe as a tiny body lift instead.
		y += breath * rig.height * 0.5
	end

	local lookYawTarget, lookPitchTarget = 0, 0
	if full and not calm then
		s.lookIn -= dt
		if s.lookIn <= 0 then
			s.lookIn = within(s, Idle.LookEvery)
			s.lookYawGoal = if random(s) < 0.3 then 0 else (random(s) * 2 - 1) * rad(Idle.LookYaw)
			s.lookPitchGoal = (random(s) * 2 - 1) * rad(Idle.LookPitch)
		end
		local idleLook = (1 - m) * (1 - sl) * (if happy then 0 else 1)
		local lead = math.clamp(s.turn * Motion.HeadLead, -rad(Motion.HeadLeadMax), rad(Motion.HeadLeadMax))
		lookYawTarget = s.lookYawGoal * idleLook + lead * m
		lookPitchTarget = s.lookPitchGoal * idleLook
	end
	local look = alpha(Idle.LookSharpness, dt)
	s.lookYaw += (lookYawTarget - s.lookYaw) * look
	s.lookPitch += (lookPitchTarget - s.lookPitch) * look
	if rig.has.Head then
		headYaw += s.lookYaw
		headPitch += s.lookPitch
	else
		-- No separate head: the whole pet glances around a little.
		yaw += s.lookYaw * 0.4
	end

	if calm or not full then
		s.action = nil
	elseif s.action == nil and s.happyLeft <= 0 then
		s.actionIn -= dt
		if s.actionIn <= 0 then
			s.actionIn = within(s, Idle.ActionEvery)
			if m < Idle.MaxMoveForAction and sl < 0.1 then
				local lists = if s.viewport then PetAnimConfig.ViewportActions else PetAnimConfig.Actions
				local list = lists[style]
				if list ~= nil and #list > 0 then
					s.action = list[1 + math.floor(random(s) * #list) % #list]
					s.actionT = 0
				end
			end
		end
	end
	local action = s.action
	if action ~= nil then
		s.actionT += dt
		local u = math.min(s.actionT / PetAnimConfig.ActionDuration[action], 1)
		local k = 1 - m -- fades if the owner starts walking mid-action
		if action == "Sit" then
			local e = envelope(u, 0.2) * k
			pitch += rad(Shape.SitPitch) * e
			y -= Shape.SitDrop * e * lift
			headPitch += rad(Shape.SitLookUp) * e
		elseif action == "Spin" then
			-- Spins always complete (a faded spin would end off-angle and pop).
			yaw += TAU * smooth01(u)
			y += Shape.SpinHop * sin(PI * u) * lift
		elseif action == "Hop" then
			local h = abs(sin(TAU * u))
			y += Shape.HopHeight * h * lift * k
			sy += k * envelope(u, 0.15) * (Motion.Hop.Stretch * h - Motion.Hop.Squash * (1 - h) ^ 4)
		elseif action == "Swoop" then
			y -= Shape.SwoopDip * sin(PI * u) * lift * k
			pitch -= rad(Shape.SwoopPitch) * sin(TAU * u) * k
		elseif action == "Flip" then
			roll += TAU * smooth01(u)
			y += 0.25 * sin(PI * u) * lift
		elseif action == "Wave" then
			local e = envelope(u, 0.2) * k
			clawR += rad(Shape.WaveRaise) * e + rad(Shape.WaveWiggle) * sin(TAU * 4 * u) * e
		elseif action == "Jiggle" then
			local w = Shape.Jiggle * sin(3 * TAU * u) * (1 - u) * k
			sy += w
			sx -= w * 0.5
		end
		if u >= 1 then
			s.action = nil
		end
	end

	-- 4. Events ----------------------------------------------------------------------------------
	if happy then
		local u = happyU
		if not calm then
			yaw += TAU * smooth01(u)
			y += (if rig.airborne then Happy.AirHeight else Happy.Height) * sin(PI * u) * lift
			local landing = math.max(0, (u - 0.85) / 0.15)
			sy -= Happy.Landing * sin(PI * landing)
		else
			-- Reduce Motion: a small happy nod instead of the spin.
			headPitch += rad(6) * sin(TAU * u)
		end
	end
	if sl > 0 then
		if rig.airborne then
			y -= rig.hover * Sleep.HoverDrop * sl
		else
			y -= Sleep.Drop * sl * lift
			sy -= Sleep.Flatten * sl
		end
		if rig.has.Head then
			headPitch -= rad(Sleep.Droop) * sl
		else
			pitch -= rad(Sleep.Droop) * 0.3 * sl
		end
	end

	-- Simple detail: body bob + wings only.
	if not full then
		sx, sy = 1, 1
		headPitch, headYaw, headRoll = 0, 0, 0
		tailPitch, tailYaw, tailRoll = 0, 0, 0
		clawL, clawR, clawPitch = 0, 0, 0
	end

	-- Write the pose, bounded and NaN-proof.
	local maxJoint = rad(Limits.MaxJointAngle)
	s.y = safe(y, Limits.MinY * size, Limits.MaxY * size, 0)
	s.pitch = safe(pitch, -TAU, TAU, 0)
	s.yaw = safe(yaw, -2 * TAU, 2 * TAU, 0)
	s.roll = safe(roll, -2 * TAU, 2 * TAU, 0)
	s.swayX = safe(swayX, -Limits.MaxSway * size, Limits.MaxSway * size, 0)
	s.swayZ = safe(swayZ, -Limits.MaxSway * size, Limits.MaxSway * size, 0)
	s.sx = safe(sx, Limits.MinScaleX, Limits.MaxScaleX, 1)
	s.sy = safe(sy, Limits.MinScaleY, Limits.MaxScaleY, 1)
	s.headPitch = safe(headPitch, -maxJoint, maxJoint, 0)
	s.headYaw = safe(headYaw, -maxJoint, maxJoint, 0)
	s.headRoll = safe(headRoll, -maxJoint, maxJoint, 0)
	s.tailPitch = safe(tailPitch, -maxJoint, maxJoint, 0)
	s.tailYaw = safe(tailYaw, -maxJoint, maxJoint, 0)
	s.tailRoll = safe(tailRoll, -maxJoint, maxJoint, 0)
	s.wing = safe(wing, -maxJoint, maxJoint, 0)
	s.clawL = safe(clawL, -maxJoint, maxJoint, 0)
	s.clawR = safe(clawR, -maxJoint, maxJoint, 0)
	s.clawPitch = safe(clawPitch, -maxJoint, maxJoint, 0)
	s.glow = safe(s.glow, 0, 1, 0)
end

--------------------------------------------------------------------------------------------------
-- Pose
--------------------------------------------------------------------------------------------------

--[[
	Writes out[i] = the model-space CFrame of piece i for the state's current pose.
	World CFrame of a piece = petFrame * out[i] (petFrame = the pet root's world CFrame).
	Body pieces squash about the pivot (their Size squash is PetModels.applyLook's job); every limb
	group rotates about its joint and moves rigidly with its joint's squash offset.
]]
function PetAnim.pose(rig: Rig, s: State, out: { CFrame }, detail: number)
	local full = detail >= DETAIL_FULL
	local pivotY = rig.pivotY
	local root = CFrame.new(s.swayX, s.y + pivotY, s.swayZ)
		* CFrame.fromEulerAnglesYXZ(s.pitch, s.yaw, s.roll)
		* CFrame.new(0, -pivotY, 0)

	local frames = s.frames
	local shift = s.shift
	local joints = rig.joints
	local has = rig.has
	local kx, ky = s.sx - 1, s.sy - 1
	local squash = full and (abs(kx) > 1e-4 or abs(ky) > 1e-4)

	-- One frame (rotation about the joint) + one squash shift per limb group.
	for _, group in LIMB_GROUPS do
		local joint = joints[group]
		if joint == nil or not has[group] then
			continue
		end
		local rotation: CFrame? = nil
		if group == "WingR" then
			rotation = CFrame.Angles(0, 0, s.wing)
		elseif group == "WingL" then
			rotation = CFrame.Angles(0, 0, -s.wing)
		elseif full then
			if group == "Head" then
				rotation = CFrame.fromEulerAnglesYXZ(s.headPitch, s.headYaw, s.headRoll)
			elseif group == "Tail" then
				rotation = CFrame.fromEulerAnglesYXZ(s.tailPitch, s.tailYaw, s.tailRoll)
			elseif group == "ClawR" then
				rotation = CFrame.fromEulerAnglesYXZ(s.clawPitch, 0, s.clawR)
			elseif group == "ClawL" then
				rotation = CFrame.fromEulerAnglesYXZ(s.clawPitch, 0, -s.clawL)
			elseif group == "Orbit" then
				rotation = CFrame.Angles(0, s.orbit, 0)
			end
		end
		frames[group] = if rotation ~= nil then about(joint, rotation) else nil
		shift[group] = if squash then Vector3.new(joint.X * kx, (joint.Y - pivotY) * ky, joint.Z * kx) else nil
	end

	local rest = rig.rest
	local groups = rig.groups
	for index = 1, rig.count do
		local group = groups[index]
		local cf = rest[index]
		if group == "Body" then
			if squash then
				local p = cf.Position
				cf += Vector3.new(p.X * kx, (p.Y - pivotY) * ky, p.Z * kx)
			end
		else
			local frame = frames[group]
			if frame ~= nil then
				cf = frame * cf
			end
			local offset = shift[group]
			if offset ~= nil then
				cf += offset
			end
		end
		out[index] = root * cf
	end
end

--[[
	Keeps a rig in step with a Model:ScaleTo (a reveal pop, a bigger detail pet): multiplies the
	rest offsets, joints, squash sizes, hover / pivot / height and the motion scale by `factor`
	(new scale / old scale), in place. Rotations are unchanged. No-op for 1, ≤ 0, NaN or inf.
	Example: PetAnim.rescaleRig(rig, model:GetScale() / rig.scale)
]]
function PetAnim.rescaleRig(rig: Rig, factor: number)
	if not finite(factor) or factor <= 0 or factor == 1 then
		return
	end
	local rest = rig.rest
	for index, cf in rest do
		rest[index] = cf.Rotation + cf.Position * factor
	end
	for group, joint in rig.joints do
		rig.joints[group] = joint * factor
	end
	for n, size in rig.restSize do
		rig.restSize[n] = size * factor
	end
	rig.hover *= factor
	rig.pivotY *= factor
	rig.centerY *= factor
	rig.height *= factor
	rig.scale *= factor
end

--[[
	Current Size of squash piece `n` (index into rig.squash) for the state's pose.
	Example: part.Size = PetAnim.squashSize(rig, state, 1)
]]
function PetAnim.squashSize(rig: Rig, s: State, n: number): Vector3
	local size = rig.restSize[n]
	return Vector3.new(size.X * s.sx, size.Y * s.sy, size.Z * s.sx)
end

--[[
	Current Transparency of glow piece `n` (index into rig.glow): rest + a soft dimming pulse
	quantised to Glow.Step (owner R19: a pulse never makes a piece brighter than at rest).
]]
function PetAnim.glowTransparency(rig: Rig, s: State, n: number): number
	local step = Motion.Glow.Step
	local dim = math.floor(s.glow * Motion.Glow.Amount / step + 0.5) * step
	return math.clamp(rig.glowRest[n] + dim, 0, 1)
end

return table.freeze(PetAnim)
