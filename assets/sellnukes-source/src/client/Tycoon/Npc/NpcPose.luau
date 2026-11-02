--!strict
--[[
	NpcPose — pure pose maths for one manager NPC: turns an NpcBrain's state into joint angles
	(radians) and a root transform (model space). No services / Instances / requires, so
	tests/npc-logic.luau runs it in lune; the controller turns the numbers into CFrames.

	Rig (pivots in ManagerNpcConfig.Rigs[key].joints):
		root    figure feet centre: x, y, z, yaw (walk position, step bounce, hover bob, hop)
		Torso   about the hip centre: lean (pitch), hip twist (yaw), idle sway (roll), breathe lift
		Head    about the neck, rides the torso: nod (pitch), look at the owner (yaw)
		ArmL/R  about the shoulders, ride the torso: swing (pitch), outward (roll)
		LegL/R  about the hip sockets: stride (pitch)
	Signs: +pitch swings a hanging limb's far end FORWARD (-Z) and tips the torso / head BACK, so a
	forward lean / nod is negative. +roll swings a hanging limb toward +X: ArmR outward = +roll,
	ArmL outward = -roll.

	Layers, in order: walk cycle (scaled by stride), idle breathing (scaled by 1 - stride),
	work action (Tap / Hammer / Press), wave (overrides the wave arm), hop (both arms fling out).

	Example:
		local pose = NpcPose.new()
		NpcPose.compute(brain, pose)
		-- pose.armRPitch, pose.legLPitch, pose.y ...
]]

export type Pose = {
	x: number,
	y: number,
	z: number,
	yaw: number,
	torsoLift: number, -- studs (breathing)
	torsoPitch: number,
	torsoYaw: number,
	torsoRoll: number,
	headPitch: number,
	headYaw: number,
	armLPitch: number,
	armLRoll: number,
	armRPitch: number,
	armRRoll: number,
	legLPitch: number,
	legRPitch: number,
}

local NpcPose = {}

local TAU = 2 * math.pi
local rad = math.rad

-- A zeroed pose table (one per manager, reused every frame).
function NpcPose.new(): Pose
	return {
		x = 0,
		y = 0,
		z = 0,
		yaw = 0,
		torsoLift = 0,
		torsoPitch = 0,
		torsoYaw = 0,
		torsoRoll = 0,
		headPitch = 0,
		headYaw = 0,
		armLPitch = 0,
		armLRoll = 0,
		armRPitch = 0,
		armRRoll = 0,
		legLPitch = 0,
		legRPitch = 0,
	}
end

-- Smoothstep 0..1.
local function smooth(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

--[[
	Rest pose at the brain's current root (every angle 0): applied once when a manager leaves the
	animated set, so it never freezes mid-stride.
]]
function NpcPose.rest(brain: any, out: Pose)
	out.x, out.y, out.z, out.yaw = brain.x, brain.y, brain.z, brain.yaw
	out.torsoLift, out.torsoPitch, out.torsoYaw, out.torsoRoll = 0, 0, 0, 0
	out.headPitch, out.headYaw = 0, 0
	out.armLPitch, out.armLRoll, out.armRPitch, out.armRRoll = 0, 0, 0, 0
	out.legLPitch, out.legRPitch = 0, 0
end

--[[
	Arm pitch of a work action at progress u (0..1) for the acting arm.
	Tap: reach forward and back. Hammer: wind up overhead, strike fast, recover. Press: push forward.
]]
--[[
	Dazed pose (owner R50 knockdown: "managers sit dazed with stars"): the manager plops down where
	it stands (Biped: root lowered by `sitDrop`, legs straight out in front; Hover: sags low),
	slumps, sways in a slow woozy circle with a lolling head, arms flopped outward. The brain is not
	stepped meanwhile, so the work loop resumes exactly where it stopped. Pure + allocation-free.
	@param brain   NpcBrain.Brain (position / yaw / phase are read, never written)
	@param out     Pose (reused)
	@param clock   seconds (any running clock; drives the sway)
	@param sitDrop studs the root sinks (Biped: hip height minus a little; Hover: a sag)
	Example: NpcPose.dazed(brain, pose, os.clock(), 1.6)
]]
function NpcPose.dazed(brain: any, out: Pose, clock: number, sitDrop: number)
	local hover = brain.rig.style == "Hover"
	local angle = TAU * clock / 1.7 + brain.phase
	local sway, nod = math.sin(angle), math.cos(angle)
	out.x, out.y, out.z, out.yaw = brain.x, brain.y - math.max(sitDrop, 0), brain.z, brain.yaw
	out.torsoLift = 0
	out.torsoPitch = rad(7) + rad(6) * nod -- slumped back, rocking
	out.torsoYaw = 0
	out.torsoRoll = rad(11) * sway -- the woozy circle
	out.headPitch = rad(12) + rad(9) * nod -- head lolls
	out.headYaw = rad(20) * sway
	out.armLPitch, out.armRPitch = rad(-15), rad(-15)
	out.armLRoll, out.armRRoll = -rad(38), rad(38) -- arms flopped out
	local legs = if hover then 0 else rad(82) -- +pitch = far end forward: legs straight out
	out.legLPitch, out.legRPitch = legs, legs
end

function NpcPose.actionPitch(action: string, u: number, motion: any): number
	if action == "Hammer" then
		if u < 0.45 then
			return rad(motion.HammerRaise) * smooth(u / 0.45)
		end
		local v = (u - 0.45) / 0.55
		if v < 0.3 then
			-- The strike: fast, linear, from the wind-up down to the strike angle.
			return rad(motion.HammerRaise + (motion.HammerStrike - motion.HammerRaise) * (v / 0.3))
		end
		return rad(motion.HammerStrike) * (1 - smooth((v - 0.3) / 0.7))
	elseif action == "Press" then
		return rad(motion.PressReach) * math.sin(math.pi * math.clamp(u, 0, 1))
	end
	return rad(motion.TapReach) * math.sin(math.pi * math.clamp(u, 0, 1))
end

--[[
	Fills `out` from the brain's current state.
	@param brain NpcBrain.Brain
	@param out   Pose (reused)
]]
function NpcPose.compute(brain: any, out: Pose)
	local motion = brain.motion
	local rig = brain.rig
	local hover = rig.style == "Hover"
	local stride = brain.stride
	local idle = 1 - stride
	local swing = math.sin(brain.gait)
	local breathe = math.sin(TAU * brain.clock / motion.BreathePeriod + brain.phase)
	local carry = rig.carry

	-- Root: walk position + step bounce (two per gait cycle) or hover bob, + hop arc.
	local y = brain.y
	if hover then
		y += motion.HoverBob * (0.5 + 0.5 * math.sin(TAU * brain.clock / motion.HoverPeriod + brain.phase))
	else
		y += math.abs(swing) * motion.WalkBob * stride
	end
	local hop = 0
	if brain.hopT >= 0 then
		hop = math.sin(math.pi * math.clamp(brain.hopT / motion.HopSeconds, 0, 1))
		y += motion.HopHeight * hop
	end
	out.x, out.y, out.z, out.yaw = brain.x, y, brain.z, brain.yaw

	-- Torso + head: lean into the walk, breathe + sway when standing, look at the owner.
	out.torsoLift = motion.BreatheLift * breathe * idle
	out.torsoPitch = -rad(if hover then motion.HoverLean else motion.WalkLean) * stride
	out.torsoYaw = if hover then 0 else rad(4) * swing * stride
	out.torsoRoll = rad(motion.SwayDegrees)
		* math.sin(TAU * brain.clock / (motion.BreathePeriod * 2.3) + brain.phase)
		* idle
	out.headPitch = rad(motion.BreatheNod) * breathe * idle
	out.headYaw = brain.look - out.torsoYaw

	-- Legs: opposite stride swing (Hover rigs have no legs; the values are simply unused).
	local leg = rad(motion.LegSwing) * swing * stride
	out.legLPitch = leg
	out.legRPitch = -leg

	-- Arms: swing against the same-side leg; prop-holding arms barely move.
	local scale = if hover then motion.HoverArmScale else 1
	local ampL = rad(if carry ~= nil and carry.ArmL then motion.CarrySwing else motion.ArmSwing) * scale
	local ampR = rad(if carry ~= nil and carry.ArmR then motion.CarrySwing else motion.ArmSwing) * scale
	out.armLPitch = -ampL * swing * stride
	out.armRPitch = ampR * swing * stride
	local relax = rad(3) * (0.5 + 0.5 * breathe) * idle
	out.armLRoll = -relax
	out.armRRoll = relax

	-- Work action (synced beat).
	if brain.actionT >= 0 then
		local action = rig.workAction
		local u = brain.actionT / motion.ActionSeconds[action]
		local pitch = NpcPose.actionPitch(action, u, motion)
		local bump = math.sin(math.pi * math.clamp(u, 0, 1))
		if action == "Press" then
			out.armLPitch += pitch
			out.armRPitch += pitch
		elseif rig.workArm == "ArmL" then
			out.armLPitch += pitch
		else
			out.armRPitch += pitch
		end
		out.torsoPitch -= rad(motion.WorkLean) * bump
		out.headPitch -= rad(motion.WorkNod) * bump
	end

	-- Wave: the wave arm rises sideways and wiggles; its walk / work swing fades out under it.
	if brain.waveT >= 0 then
		local u = brain.waveT / motion.WaveSeconds
		local envelope = math.clamp(math.min(u / 0.18, (1 - u) / 0.18), 0, 1)
		envelope = smooth(envelope)
		local wiggle = math.sin(TAU * motion.WaveRate * brain.waveT)
		local roll = (rad(motion.WaveLift) + rad(motion.WaveWiggle) * wiggle) * envelope
		if rig.waveArm == "ArmL" then
			out.armLRoll = out.armLRoll * (1 - envelope) - roll
			out.armLPitch *= 1 - envelope
		else
			out.armRRoll = out.armRRoll * (1 - envelope) + roll
			out.armRPitch *= 1 - envelope
		end
		out.headPitch += rad(4) * envelope -- chin up toward the owner
	end

	-- Happy hop: both arms fling outward at the top of the arc.
	if hop > 0 then
		local fling = rad(motion.HopArms) * hop
		out.armLRoll -= fling
		out.armRRoll += fling
	end
end

return NpcPose
