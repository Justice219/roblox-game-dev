--!strict
--[[
	WindLogic — the pure math of the running wind effect (owner R21). No services, no Instances, so
	tests/movement-logic.luau exercises every rule under Lune.

	Model:
		intensity  0..1 from the character's HORIZONTAL speed: 0 below Wind.MinSpeed, 1 at
		           Wind.FullSpeed, smoothed exponentially (fast Attack when speeding up, faster
		           Release when stopping) so the overlay never pops.
		lines      speed lines live on an ellipse band around the screen edges (LineInner..LineOuter
		           of the half-size): each has a fixed angle and a radial progress 0..1 that grows
		           with time; it fades in and out (sin curve) and respawns at a new angle when done.
		           The centre stays clear (player + HUD never covered).
		whoosh     plays once when intensity rises past WhooshAt, re-arms below WhooshRearm, and
		           never more often than WhooshCooldown seconds.

	Example:
		local target = WindLogic.target(24, MovementConfig.Wind)              --> 0.9
		intensity = WindLogic.smooth(intensity, target, dt, MovementConfig.Wind)
		local x, y, rot, len, transparency = WindLogic.lineFrame(line, intensity, 1920, 1080, cfg)
]]

export type WindConfig = {
	read MinSpeed: number,
	read FullSpeed: number,
	read Attack: number,
	read Release: number,
	read LineLength: number,
	read LineSpeed: number,
	read LineInner: number,
	read LineOuter: number,
	read LineMaxOpacity: number,
	read WhooshAt: number,
	read WhooshRearm: number,
	read WhooshCooldown: number,
}

-- One speed line: direction angle (radians), radial progress 0..1, speed / length jitter.
export type Line = { angle: number, progress: number, speed: number, length: number }

-- Whoosh trigger state (one per client).
export type WhooshState = { armed: boolean, lastAt: number }

-- A source of random numbers in [0, 1) (math.random or Random:NextNumber wrapped).
export type Rand = () -> number

local WindLogic = {}

--[[
	Target intensity for a horizontal speed (studs / s): 0 at or below MinSpeed, 1 at FullSpeed and
	above, linear between. Non-finite / negative speeds give 0.
	Example: WindLogic.target(16, cfg) --> 0.5 with MinSpeed 6, FullSpeed 26
]]
function WindLogic.target(speed: number, cfg: WindConfig): number
	if type(speed) ~= "number" or speed ~= speed or speed <= cfg.MinSpeed then
		return 0
	end
	if speed == math.huge then
		return 1
	end
	return math.clamp((speed - cfg.MinSpeed) / math.max(0.001, cfg.FullSpeed - cfg.MinSpeed), 0, 1)
end

--[[
	Exponential smoothing toward `target` over `dt` seconds (Attack rate when rising, Release when
	falling). Frame-rate independent; snaps to the target within 0.001.
]]
function WindLogic.smooth(current: number, target: number, dt: number, cfg: WindConfig): number
	if dt ~= dt or dt <= 0 then
		return current
	end
	local rate = if target > current then cfg.Attack else cfg.Release
	local nextValue = current + (target - current) * (1 - math.exp(-rate * math.min(dt, 1)))
	if math.abs(nextValue - target) < 0.001 then
		return target
	end
	return math.clamp(nextValue, 0, 1)
end

--[[ A fresh line at a random angle (progress randomised so lines are staggered). ]]
function WindLogic.newLine(rand: Rand, staggered: boolean?): Line
	return {
		angle = rand() * math.pi * 2,
		progress = if staggered then rand() else 0,
		speed = 0.75 + rand() * 0.5,
		length = 0.6 + rand() * 0.6,
	}
end

--[[
	Advances a line by `dt` seconds at the given intensity (lines move faster when running faster);
	a finished line respawns at a new angle. Returns true when it respawned.
]]
function WindLogic.stepLine(line: Line, dt: number, intensity: number, cfg: WindConfig, rand: Rand): boolean
	line.progress += dt * cfg.LineSpeed * line.speed * (0.5 + intensity)
	if line.progress < 1 then
		return false
	end
	line.angle = rand() * math.pi * 2
	line.progress = 0
	line.speed = 0.75 + rand() * 0.5
	line.length = 0.6 + rand() * 0.6
	return true
end

--[[
	Screen placement of a line for a viewport of `width` × `height` pixels:
	@return x, y (pixel centre), rotation (degrees, pointing away from the centre), length (px),
	        transparency (1 = invisible)
]]
function WindLogic.lineFrame(
	line: Line,
	intensity: number,
	width: number,
	height: number,
	cfg: WindConfig
): (number, number, number, number, number)
	local halfW, halfH = width / 2, height / 2
	local radial = cfg.LineInner + (cfg.LineOuter - cfg.LineInner) * line.progress
	local dx, dy = math.cos(line.angle) * halfW, math.sin(line.angle) * halfH
	local x, y = halfW + dx * radial, halfH + dy * radial
	local rotation = math.deg(math.atan2(dy, dx))
	local fade = math.sin(math.pi * math.clamp(line.progress, 0, 1))
	local opacity = cfg.LineMaxOpacity * math.clamp(intensity, 0, 1) * fade
	local length = cfg.LineLength * line.length * (0.4 + 0.6 * math.clamp(intensity, 0, 1))
	return x, y, rotation, length, 1 - opacity
end

--[[ A fresh whoosh state (armed). ]]
function WindLogic.newWhoosh(): WhooshState
	return { armed = true, lastAt = -math.huge }
end

--[[
	True when the whoosh should play now: intensity crossed WhooshAt while armed and the cooldown
	passed. Falling below WhooshRearm re-arms it. Mutates `state`.
]]
function WindLogic.whoosh(state: WhooshState, intensity: number, now: number, cfg: WindConfig): boolean
	if intensity <= cfg.WhooshRearm then
		state.armed = true
		return false
	end
	if state.armed and intensity >= cfg.WhooshAt and now - state.lastAt >= cfg.WhooshCooldown then
		state.armed = false
		state.lastAt = now
		return true
	end
	return false
end

return table.freeze(WindLogic)
