--!strict
--[[
	NpcBrain — the pure behaviour state machine of one manager NPC (owner R30). No services, no
	Instances, no requires: plain numbers in, plain numbers out, so tests/npc-logic.luau runs it in
	lune and the controller can step dozens of managers per frame with zero allocation.

	Modes (all positions / yaws in the manager MODEL's space, see ManagerNpcConfig):
		Idle  standing at a waypoint for its pause (breathing), turning to the waypoint's facing
		Walk  heading to the next waypoint: turns in place first when the heading is far off,
		      eases the stride in / out, snaps onto the waypoint on arrival
		Work  at a `work` waypoint: one action per producer cycle (`cycleWrapped`), never faster
		      than MinBeatInterval; unsynced fallback cadence when the producer is unknown / manual.
		      Leaves after WorkBeats actions (>= WorkMinSeconds) or WorkMaxSeconds.
		Wave  the plot owner stepped inside WaveRadius (an arrival, not every frame they stay):
		      stop, turn to them, wave for WaveSeconds, then resume the interrupted mode
		      (cooldown WaveCooldown before the next arrival counts)
	Overlays that run in any mode: the work action timer, the happy hop (`requestHop`), the head
	look toward a nearby owner, the breathing clock.
	Reduced motion: snaps home and stays Idle (breathing only) until it is switched off.

	One-frame events (cleared at the start of every step, read by the controller after it):
		brain.hit     the current work action just "landed" (sound + sparkle)
		brain.hopped  a requested hop just started (pop sound)

	Example:
		local brain = NpcBrain.new(rig, ManagerNpcConfig.Motion, 7)
		local input = NpcBrain.newInput()
		input.dt = 1 / 60
		NpcBrain.step(brain, input)
]]

-- ManagerNpcConfig.Motion / ManagerNpcConfig.Rig (kept `any` so this module needs no requires
-- and runs unchanged in lune).
export type Motion = any
export type Rig = any
export type Mode = "Idle" | "Walk" | "Work" | "Wave"

export type Input = {
	dt: number,
	ownerValid: boolean, -- the plot owner's character is known
	ownerX: number, -- owner position, model space
	ownerZ: number,
	producerValid: boolean, -- the producer anchor is known
	producerX: number, -- producer anchor position, model space
	producerZ: number,
	synced: boolean, -- producer automated with a valid cycle: beats follow cycleWrapped
	cycleWrapped: boolean, -- a producer cycle completed since the previous step
	reduced: boolean, -- reduced motion: idle at home only
}

export type Brain = {
	rig: Rig,
	motion: Motion,
	-- Figure root (feet centre) + facing, model space. yaw in radians (0 = facing -Z).
	x: number,
	y: number,
	z: number,
	yaw: number,
	mode: Mode,
	resume: Mode, -- mode a wave interrupted
	target: number, -- waypoint index: destination while walking, the current stop otherwise
	timer: number, -- Idle: seconds left; Work: seconds spent
	stride: number, -- 0..1 walk blend
	gait: number, -- stride phase (radians)
	beats: number, -- actions done this work visit
	sinceBeat: number,
	actionT: number, -- seconds into the current work action, -1 = none
	hitDone: boolean,
	waveT: number, -- seconds into the wave, -1 = none
	waveCooldown: number,
	ownerInside: boolean, -- owner was inside WaveRadius last step (waves fire on arrival)
	look: number, -- head yaw offset toward the owner (radians)
	hopT: number, -- seconds into the hop, -1 = none
	hopDelay: number, -- seconds until a requested hop starts, -1 = none
	clock: number, -- local seconds (breathing / hover)
	phase: number, -- random phase so managers never breathe in sync
	rng: number, -- Park-Miller state (deterministic in tests)
	reducedLatched: boolean,
	-- One-frame events.
	hit: boolean,
	hopped: boolean,
}

local NpcBrain = {}

local TAU = 2 * math.pi
local RNG_MOD = 2147483647

-- Next pseudo-random number in [0, 1) (Park-Miller; products stay < 2^53, exact in doubles).
local function random01(brain: Brain): number
	brain.rng = (brain.rng * 16807) % RNG_MOD
	return brain.rng / RNG_MOD
end

-- Wraps an angle difference to [-pi, pi).
local function wrap(angle: number): number
	return (angle + math.pi) % TAU - math.pi
end
NpcBrain.wrap = wrap

--[[
	Model-space yaw that faces from (fromX, fromZ) toward (toX, toZ). Facing yaw psi looks along
	(-sin psi, -cos psi), matching CFrame.Angles(0, psi, 0) * -Z.
	Example: yawToward(0, 0, -1, 0) --> pi / 2 (toward -X)
]]
function NpcBrain.yawToward(fromX: number, fromZ: number, toX: number, toZ: number): number
	return math.atan2(-(toX - fromX), -(toZ - fromZ))
end

-- Moves `value` toward `goal` by at most `maxStep`.
local function approach(value: number, goal: number, maxStep: number): number
	if value < goal then
		return math.min(value + maxStep, goal)
	end
	return math.max(value - maxStep, goal)
end

-- Turns the body toward `goal` at TurnSpeed.
local function turnToward(brain: Brain, goal: number, dt: number)
	local diff = wrap(goal - brain.yaw)
	local maxTurn = math.rad(brain.motion.TurnSpeed) * dt
	if math.abs(diff) <= maxTurn then
		brain.yaw = goal
	else
		brain.yaw = wrap(brain.yaw + (if diff > 0 then maxTurn else -maxTurn))
	end
end

-- The facing a waypoint asks for (radians), or nil to keep the current heading.
local function faceOf(brain: Brain, index: number, input: Input): number?
	local face = brain.rig.waypoints[index].face
	if type(face) == "number" then
		return math.rad(face)
	elseif face == "producer" and input.producerValid then
		return NpcBrain.yawToward(brain.x, brain.z, input.producerX, input.producerZ)
	end
	return nil
end

-- Idle pause for a stop: its own `pause` (0 = pass through) or the default, +- jitter.
local function pauseFor(brain: Brain, index: number): number
	local motion = brain.motion
	local pause = brain.rig.waypoints[index].pause
	if pause ~= nil and pause <= 0 then
		return 0
	end
	local base = pause or motion.PauseDefault
	return math.max(0.2, base + (random01(brain) * 2 - 1) * motion.PauseJitter)
end

-- Enters the stop at `index` (already standing on it): Work for work spots, else Idle.
local function enterStop(brain: Brain, index: number)
	brain.target = index
	if brain.rig.waypoints[index].work == true then
		brain.mode = "Work"
		brain.timer = 0
		brain.beats = 0
		brain.sinceBeat = brain.motion.MinBeatInterval -- the first cycle may beat at once
	else
		brain.mode = "Idle"
		brain.timer = pauseFor(brain, index)
	end
end

-- Starts walking to the stop after the current one.
local function walkToNext(brain: Brain)
	local count = #brain.rig.waypoints
	brain.target = brain.target % count + 1
	brain.mode = "Walk"
end

-- Snaps onto the current destination and enters it.
local function arrive(brain: Brain)
	local wp = brain.rig.waypoints[brain.target].at
	brain.x, brain.y, brain.z = wp.X, wp.Y, wp.Z
	enterStop(brain, brain.target)
end

--[[
	New brain standing on waypoint 1 (the rest pose position) with the figure's rest facing.
	@param rig    ManagerNpcConfig.Rigs row
	@param motion ManagerNpcConfig.Motion
	@param seed   positive integer (e.g. a per-manager counter) — de-syncs pauses and breathing
]]
function NpcBrain.new(rig: Rig, motion: Motion, seed: number): Brain
	local home = rig.waypoints[1].at
	local brain: Brain = {
		rig = rig,
		motion = motion,
		x = home.X,
		y = home.Y,
		z = home.Z,
		yaw = wrap(math.rad(rig.figure.yaw)),
		mode = "Idle",
		resume = "Idle",
		target = 1,
		timer = 0,
		stride = 0,
		gait = 0,
		beats = 0,
		sinceBeat = 0,
		actionT = -1,
		hitDone = false,
		waveT = -1,
		waveCooldown = 0,
		ownerInside = false,
		look = 0,
		hopT = -1,
		hopDelay = -1,
		clock = 0,
		phase = 0,
		rng = (math.floor(math.abs(seed)) % (RNG_MOD - 1)) + 1,
		reducedLatched = false,
		hit = false,
		hopped = false,
	}
	brain.phase = random01(brain) * TAU
	enterStop(brain, 1)
	if brain.mode == "Idle" then
		-- First pause randomised so a freshly loaded plot never starts pacing in lock-step.
		brain.timer = 0.4 + random01(brain) * (motion.PauseDefault + motion.PauseJitter)
	end
	return brain
end

-- A reusable input table (the controller keeps one per manager and refills it every frame).
function NpcBrain.newInput(): Input
	return {
		dt = 0,
		ownerValid = false,
		ownerX = 0,
		ownerZ = 0,
		producerValid = false,
		producerX = 0,
		producerZ = 0,
		synced = false,
		cycleWrapped = false,
		reduced = false,
	}
end

--[[
	Queues a happy hop `delay` seconds from now (a purchase on the manager's plot). A hop already
	queued or playing is not restarted. Ignored under reduced motion by `step`.
]]
function NpcBrain.requestHop(brain: Brain, delay: number)
	if brain.reducedLatched then
		return -- reduced motion: no hops (a stale one must not fire when it is switched off)
	end
	if brain.hopT < 0 and brain.hopDelay < 0 then
		brain.hopDelay = math.max(delay, 0)
	end
end

-- Advances the stride phase by the distance a full stride would have covered.
local function advanceGait(brain: Brain, dt: number)
	local motion = brain.motion
	if brain.stride > 0 then
		brain.gait = (brain.gait + motion.WalkSpeed * brain.stride * dt / motion.StrideLength * TAU) % TAU
	end
end

-- Reduced motion: home, still, idle. Returns after resetting every overlay.
local function holdHome(brain: Brain)
	local home = brain.rig.waypoints[1].at
	brain.x, brain.y, brain.z = home.X, home.Y, home.Z
	local face = brain.rig.waypoints[1].face
	brain.yaw = wrap(if type(face) == "number" then math.rad(face) else math.rad(brain.rig.figure.yaw))
	brain.mode = "Idle"
	brain.target = 1
	brain.timer = 0
	brain.stride = 0
	brain.actionT = -1
	brain.waveT = -1
	brain.hopT = -1
	brain.hopDelay = -1
	brain.look = 0
	brain.reducedLatched = true
end

--[[
	Advances the brain by input.dt seconds. Sets the one-frame events `hit` / `hopped`.
	@param brain Brain
	@param input Input (refilled by the caller each frame; never retained)
]]
function NpcBrain.step(brain: Brain, input: Input)
	local motion = brain.motion
	local dt = math.clamp(input.dt, 0, 0.25) -- hitches never teleport a manager through a desk
	brain.hit = false
	brain.hopped = false
	brain.clock += dt

	if input.reduced then
		if not brain.reducedLatched then
			holdHome(brain)
		end
		return
	end
	if brain.reducedLatched then
		-- Reduced motion just switched off: resume the loop from home.
		brain.reducedLatched = false
		enterStop(brain, 1)
	end

	-- Happy hop overlay.
	if brain.hopDelay >= 0 then
		brain.hopDelay -= dt
		if brain.hopDelay < 0 then
			brain.hopDelay = -1
			brain.hopT = 0
			brain.hopped = true
		end
	elseif brain.hopT >= 0 then
		brain.hopT += dt
		if brain.hopT >= motion.HopSeconds then
			brain.hopT = -1
		end
	end

	-- Work action overlay (finishes even if the manager starts walking or waving).
	if brain.actionT >= 0 then
		local action = brain.rig.workAction
		local duration = motion.ActionSeconds[action]
		brain.actionT += dt
		if not brain.hitDone and brain.actionT >= duration * motion.HitFraction[action] then
			brain.hitDone = true
			brain.hit = true
		end
		if brain.actionT >= duration then
			brain.actionT = -1
		end
	end

	-- Owner: wave trigger + head look.
	brain.waveCooldown = math.max(0, brain.waveCooldown - dt)
	local ownerDistance = math.huge
	if input.ownerValid then
		local dx, dz = input.ownerX - brain.x, input.ownerZ - brain.z
		ownerDistance = math.sqrt(dx * dx + dz * dz)
	end
	local inside = ownerDistance <= motion.WaveRadius
	if inside and not brain.ownerInside and brain.mode ~= "Wave" and brain.waveCooldown <= 0 then
		brain.resume = brain.mode
		brain.mode = "Wave"
		brain.waveT = 0
	end
	-- An arrival still pending behind a cooldown is not remembered: only a fresh entry waves.
	brain.ownerInside = inside
	local lookGoal = 0
	if ownerDistance <= motion.LookRadius and ownerDistance > 0.5 then
		local want = NpcBrain.yawToward(brain.x, brain.z, input.ownerX, input.ownerZ)
		local limit = math.rad(motion.LookLimit)
		lookGoal = math.clamp(wrap(want - brain.yaw), -limit, limit)
	end
	brain.look += (lookGoal - brain.look) * math.min(1, motion.LookSpeed * dt)

	local mode = brain.mode
	if mode == "Wave" then
		brain.waveT += dt
		if input.ownerValid then
			turnToward(brain, NpcBrain.yawToward(brain.x, brain.z, input.ownerX, input.ownerZ), dt)
		end
		brain.stride = approach(brain.stride, 0, motion.Accel * dt)
		if brain.waveT >= motion.WaveSeconds then
			brain.waveT = -1
			brain.waveCooldown = motion.WaveCooldown
			brain.mode = brain.resume
		end
	elseif mode == "Idle" then
		brain.stride = approach(brain.stride, 0, motion.Accel * dt)
		local face = faceOf(brain, brain.target, input)
		if face ~= nil then
			turnToward(brain, face, dt)
		end
		brain.timer -= dt
		if brain.timer <= 0 then
			walkToNext(brain)
		end
	elseif mode == "Work" then
		brain.stride = approach(brain.stride, 0, motion.Accel * dt)
		local face = faceOf(brain, brain.target, input)
		if face ~= nil then
			turnToward(brain, face, dt)
		end
		brain.timer += dt
		brain.sinceBeat += dt
		local wantsBeat = if input.synced then input.cycleWrapped else brain.sinceBeat >= motion.UnsyncedBeatSeconds
		if wantsBeat and brain.actionT < 0 and brain.sinceBeat >= motion.MinBeatInterval then
			brain.actionT = 0
			brain.hitDone = false
			brain.beats += 1
			brain.sinceBeat = 0
		end
		local done = (brain.beats >= motion.WorkBeats and brain.timer >= motion.WorkMinSeconds)
			or brain.timer >= motion.WorkMaxSeconds
		if done and brain.actionT < 0 and #brain.rig.waypoints > 1 then
			walkToNext(brain)
		elseif done and brain.actionT < 0 then
			-- Single-stop rig: stay and keep working (new visit).
			brain.timer = 0
			brain.beats = 0
		end
	else -- Walk
		local wp = brain.rig.waypoints[brain.target].at
		local dx, dz = wp.X - brain.x, wp.Z - brain.z
		local distance = math.sqrt(dx * dx + dz * dz)
		if distance <= motion.ArriveRadius then
			arrive(brain)
		else
			local want = math.atan2(-dx, -dz)
			local off = math.abs(wrap(want - brain.yaw))
			turnToward(brain, want, dt)
			local goal = if off > math.rad(motion.TurnBeforeWalk) then 0 else 1
			brain.stride = approach(brain.stride, goal, motion.Accel * dt)
			-- Ease into the stop over the last ~0.8 studs.
			local ease = math.clamp(distance / 0.8, 0.35, 1)
			local stepLength = motion.WalkSpeed * brain.stride * ease * dt
			if stepLength >= distance then
				arrive(brain)
			elseif stepLength > 0 then
				local t = stepLength / distance
				brain.x += dx * t
				brain.z += dz * t
				brain.y += (wp.Y - brain.y) * t
			end
		end
	end
	advanceGait(brain, dt)
end

return NpcBrain
