--!strict
--[[
	SiloLaunchMath — the pure timeline of a silo rocket's lift-off and reload (owner R109: "make sure
	when you launch rockets the rockets actually leave the base and recharge load back").
	Client/Attack/SiloLaunch poses its clones from these numbers; tests/attack-view.luau proves them.

	Times are relative to the flight's t0 (`rel` = serverNow - t0); see AttackConfig.SiloFx:
		ignite   rel in [-IgniteLead, 0)       rise SlowRise studs (ease-in), shaking
		handoff  rel in [0, HandOff)           climb fast + blend onto the flight arc (smoothstep)
		gone     rel >= HandOff                the flight nuke flies on; the gantry is empty
	Reload: from t0 + HandOff for `reloadSeconds(kind, tier)`; the fresh rocket starts ReloadDepth
	studs low at ReloadFade transparency and eases (out) into its rest pose, solid.

	Connects to: Shared/Config/AttackConfig (SiloFx, Launcher); used by Client/Attack/SiloLaunch.

	Example:
		SiloLaunchMath.phase(-0.5)              --> "ignite"
		SiloLaunchMath.rise(-0.5)               -- studs above rest
		SiloLaunchMath.blend(0.4)               -- 0..1 toward the flight arc
		SiloLaunchMath.reloadSeconds("normal", 2) --> 27 (Launcher[2].cooldown)
]]

local AttackConfig = require(script.Parent.Parent.Config.AttackConfig)

local SiloLaunchMath = {}

local FX = AttackConfig.SiloFx

export type Phase = "before" | "ignite" | "handoff" | "gone"

-- A finite number, else `fallback`.
local function finite(value: unknown, fallback: number): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return fallback
	end
	return value
end

--[[ The lift-off phase at `rel` seconds after t0. ]]
function SiloLaunchMath.phase(rel: number): Phase
	local t = finite(rel, -math.huge)
	if t < -FX.IgniteLead then
		return "before"
	elseif t < 0 then
		return "ignite"
	elseif t < FX.HandOff then
		return "handoff"
	end
	return "gone"
end

--[[ Studs the rocket has risen during the ignite (0 at ignition, SlowRise at t0; ease-in). ]]
function SiloLaunchMath.rise(rel: number): number
	local u = math.clamp((finite(rel, -math.huge) + FX.IgniteLead) / FX.IgniteLead, 0, 1)
	return FX.SlowRise * u * u
end

--[[ Studs climbed above the rest pose during the hand-off before blending (fast, accelerating). ]]
function SiloLaunchMath.climb(rel: number): number
	local t = math.max(finite(rel, 0), 0)
	return FX.SlowRise + FX.Climb * t + FX.ClimbAccel * t * t
end

--[[ Hand-off blend 0..1 toward the flight arc (smoothstep over HandOff). ]]
function SiloLaunchMath.blend(rel: number): number
	local u = math.clamp(finite(rel, 0) / FX.HandOff, 0, 1)
	return u * u * (3 - 2 * u)
end

--[[
	The clone's scale during the hand-off: the silo rocket (SiloLength) shrinks to the flight nuke's
	length as it blends onto the arc.
	@param rel number
	@param flightLength number — the flight nuke's length (studs; junk = FlightLength)
]]
function SiloLaunchMath.scale(rel: number, flightLength: number): number
	local target = finite(flightLength, FX.FlightLength)
	if target <= 0 then
		target = FX.FlightLength
	end
	local b = SiloLaunchMath.blend(rel)
	return 1 + (target / FX.SiloLength - 1) * b
end

--[[
	Seconds a silo takes to reload after a launch: the launcher cooldown for a normal launch (its
	tier = the launcher level), QuickReload for revenge / golden / barrage (no cooldown), never below
	MinReload.
]]
function SiloLaunchMath.reloadSeconds(kind: string, tier: number): number
	if kind == "normal" then
		local level = math.clamp(math.floor(finite(tier, 1)), 1, #AttackConfig.Launcher)
		return math.max(AttackConfig.Launcher[level].cooldown, FX.MinReload)
	end
	return math.max(FX.QuickReload, FX.MinReload)
end

--[[ Reload progress 0..1 at server time `now` for a reload running [start, finish]. ]]
function SiloLaunchMath.progress(now: number, start: number, finish: number): number
	local span = finite(finish, 0) - finite(start, 0)
	if span <= 0 then
		return 1
	end
	return math.clamp((finite(now, 0) - start) / span, 0, 1)
end

--[[ Studs below rest of the reloading rocket at progress p (ease-out: fast first, settles). ]]
function SiloLaunchMath.reloadOffset(p: number): number
	local u = 1 - math.clamp(finite(p, 1), 0, 1)
	return -FX.ReloadDepth * u * u
end

--[[ Transparency of the reloading rocket at progress p (ReloadFade → solid). ]]
function SiloLaunchMath.reloadFade(p: number): number
	return FX.ReloadFade * (1 - math.clamp(finite(p, 1), 0, 1))
end

return SiloLaunchMath
