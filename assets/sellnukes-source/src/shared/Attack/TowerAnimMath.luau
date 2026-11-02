--!strict
--[[
	TowerAnimMath — the pure maths of the AA tower rig animation (owner R106: "the AA towers should
	aniamte around"). Client/Attack/TowerAnim drives the parts; everything that decides an angle,
	a recoil or which piece moves lives here so tests/attack-view.luau can prove it.

	Pieces (MeshAssets.AATower1..5 order lists; the primitive fallback turret of Server/Attack/
	AttackWorld): Turret / TurretTrim / TurretGlow (+ the fallback's Pip lights) YAW about the
	turret joint, TurretDish yaws AND spins about its own vertical axis, Barrel / BarrelTip PITCH
	about the barrel joint (and recoil along the barrel). Everything else (Base, Tower, Glow,
	hazard rings) stands still.

	Connects to: Shared/Config/AttackConfig (TowerAnim); used by Client/Attack/TowerAnim.

	Example:
		TowerAnimMath.classify("TurretDish")             --> "dish"
		local yaw = TowerAnimMath.idleYaw(t, phase)      -- radians, within ±(1 + Wobble) x Sweep
		local back = TowerAnimMath.recoil(0.05)          -- 0..1 share of RecoilStuds
		yaw = TowerAnimMath.follow(yaw, target, 16, dt)  -- shortest-path exponential follow
]]

local AttackConfig = require(script.Parent.Parent.Config.AttackConfig)

local TowerAnimMath = {}

local ANIM = AttackConfig.TowerAnim
local TAU = 2 * math.pi

export type Group = "yaw" | "pitch" | "dish"

--[[
	Which motion group a tower piece belongs to (nil = it stands still).
	@param name string — the piece (part) name
	@return Group?
]]
function TowerAnimMath.classify(name: string): Group?
	if name == "TurretDish" then
		return "dish"
	end
	if string.sub(name, 1, 6) == "Turret" or name == "Pip" then
		return "yaw"
	end
	if string.sub(name, 1, 6) == "Barrel" then
		return "pitch"
	end
	return nil
end

--[[
	The rig joints of tower level `level` (mount space): (yaw pivot, pitch hinge). Unknown levels
	clamp to the nearest authored one.
	@return (Vector3, Vector3)
]]
function TowerAnimMath.joints(level: number): (Vector3, Vector3)
	local count = #ANIM.Joints
	local index = if type(level) == "number" and level == level then math.clamp(math.floor(level), 1, count) else 1
	local joint = ANIM.Joints[index]
	return joint.turret, joint.barrel
end

--[[
	A deterministic phase (radians) per tower so neighbouring towers never sweep in lockstep.
	@param plot number — target slot
	@param tower number — 0 = HQ / rival, 1.. = defence slot
]]
function TowerAnimMath.phase(plot: number, tower: number): number
	local seed = (plot * 7919 + tower * 104729) % 1000
	return seed / 1000 * TAU
end

--[[ Idle scan yaw (radians) at clock `t` for a tower with `phase`. ]]
function TowerAnimMath.idleYaw(t: number, phase: number): number
	local sweep = math.rad(ANIM.SweepDegrees)
	local w = ANIM.SweepSpeed
	return sweep * math.sin(w * t + phase) + sweep * ANIM.Wobble * math.sin(2.3 * w * t + 2 * phase)
end

--[[ Idle barrel elevation (radians, absolute) at clock `t`. ]]
function TowerAnimMath.idlePitch(t: number, phase: number): number
	local rest = math.rad(ANIM.PitchRestDegrees)
	local bob = math.rad(ANIM.PitchBobDegrees)
	return rest + bob * (0.5 + 0.5 * math.sin(ANIM.PitchBobSpeed * t + phase * 1.7))
end

--[[
	Recoil share (0..1) `since` seconds after a shot: snaps back at once, eases home (quadratic)
	over RecoilSeconds; 0 before the shot / after it settled.
]]
function TowerAnimMath.recoil(since: number): number
	if type(since) ~= "number" or since ~= since or since < 0 or since >= ANIM.RecoilSeconds then
		return 0
	end
	local u = 1 - since / ANIM.RecoilSeconds
	return u * u
end

-- An angle wrapped into (-pi, pi].
local function wrap(angle: number): number
	local a = (angle + math.pi) % TAU
	return a - math.pi
end
TowerAnimMath.wrap = wrap

--[[
	Exponential follow of an ANGLE toward `target` along the shortest way round (frame-rate
	independent): current + wrap(target - current) x (1 - e^(-rate x dt)).
	@param rate number — 1 / s
	@param dt number — seconds
]]
function TowerAnimMath.follow(current: number, target: number, rate: number, dt: number): number
	local k = 1 - math.exp(-math.max(rate, 0) * math.clamp(dt, 0, 0.25))
	return current + wrap(target - current) * k
end

--[[
	The yaw / elevation (radians) that points a turret at `d` (the target relative to the barrel
	hinge, mount space; the turret faces -Z at rest).
	@return (number yaw, number pitch)
]]
function TowerAnimMath.aim(d: Vector3): (number, number)
	local flat = math.sqrt(d.X * d.X + d.Z * d.Z)
	return math.atan2(-d.X, -d.Z), math.atan2(d.Y, math.max(flat, 0.01))
end

--[[
	The idle animation distance for an FxQuality tier (0 = idle off on that tier).
	@param tier string — "Low" | "Mid" | "High"
]]
function TowerAnimMath.cullDistance(tier: string): number
	local value = (ANIM.Cull :: any)[tier]
	return if type(value) == "number" then value else ANIM.Cull.Mid
end

return TowerAnimMath
