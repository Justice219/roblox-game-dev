--!strict
--[[
	Movement regressions (lune run tests/movement-logic). Real MovementConfig + WindLogic.

	Proves:
	  1. Run speed: base 27 (> Roblox's 16), FastWalk ×1.35 stacks, bad multipliers are ignored,
	     each source is capped at MaxSourceMultiplier and the result clamped to Min/MaxWalkSpeed.
	  2. Wind intensity: 0 when standing still / slow / NaN, linear ramp, 1 at full speed; smoothing
	     is frame-rate independent (one 1/30 s step ≈ two 1/60 s steps), never leaves 0..1.
	  3. Speed lines: stay in the edge band (centre clear), point away from the centre, fade in and
	     out, invisible at intensity 0; respawn at a new angle when finished.
	  4. Whoosh: once per speed-up, re-arms only after slowing down, cooldown respected.
]]

local Loader = require("./fixtures/RobloxLoader")
local loader = Loader.new()

local MovementConfig = loader.load("src/shared/Config/MovementConfig")
local WindLogic = loader.load("src/client/Movement/WindLogic")

local checks = 0
local function check(ok: boolean, message: string)
	if not ok then
		error(message, 2)
	end
	checks += 1
end
local function near(a: number, b: number, eps: number?): boolean
	return math.abs(a - b) <= (eps or 1e-6)
end

local cfg = MovementConfig.Wind

-- 1. Run speed.
check(MovementConfig.BaseWalkSpeed > 16 and MovementConfig.BaseWalkSpeed <= 30, "base speed in the genre range")
check(MovementConfig.walkSpeedFor({}) == MovementConfig.BaseWalkSpeed, "no multipliers")
check(
	near(MovementConfig.walkSpeedFor({ MovementConfig.Passes.FastWalk }), MovementConfig.BaseWalkSpeed * 1.35),
	"FastWalk"
)
check(
	MovementConfig.walkSpeedFor({ 0 / 0, -2, 0, math.huge }) == MovementConfig.BaseWalkSpeed,
	"bad multipliers ignored"
)
check(MovementConfig.walkSpeedFor({ 100 }) == MovementConfig.MaxWalkSpeed, "capped source + clamp")
check(MovementConfig.walkSpeedFor({ 0.01 }) == MovementConfig.MinWalkSpeed, "minimum")
check(MovementConfig.JumpPower >= 50 and MovementConfig.JumpPower <= 70, "sane jump")

-- 2. Intensity.
check(WindLogic.target(0, cfg) == 0 and WindLogic.target(cfg.MinSpeed, cfg) == 0, "still / slow → 0")
check(WindLogic.target(0 / 0, cfg) == 0 and WindLogic.target(-5, cfg) == 0, "bad speed → 0")
check(near(WindLogic.target((cfg.MinSpeed + cfg.FullSpeed) / 2, cfg), 0.5), "linear ramp")
check(WindLogic.target(cfg.FullSpeed, cfg) == 1 and WindLogic.target(math.huge, cfg) == 1, "full speed → 1")
check(WindLogic.target(MovementConfig.BaseWalkSpeed, cfg) == 1, "base run speed reaches full wind")
local a = WindLogic.smooth(0, 1, 1 / 30, cfg)
local b = WindLogic.smooth(WindLogic.smooth(0, 1, 1 / 60, cfg), 1, 1 / 60, cfg)
check(near(a, b, 1e-3), "frame-rate independent smoothing")
local value = 0
for _ = 1, 600 do
	value = WindLogic.smooth(value, 1, 1 / 60, cfg)
	check(value >= 0 and value <= 1, "smoothing stays in 0..1")
end
check(value == 1, "reaches the target")
for _ = 1, 600 do
	value = WindLogic.smooth(value, 0, 1 / 60, cfg)
end
check(value == 0, "releases to 0 when standing still")
check(WindLogic.smooth(0.5, 1, 0 / 0, cfg) == 0.5, "bad dt ignored")

-- 3. Speed lines.
local seq = { 0.1, 0.5, 0.9, 0.3, 0.7, 0.2, 0.8, 0.4, 0.6 }
local i = 0
local function rand(): number
	i = i % #seq + 1
	return seq[i]
end
local W, H = 1920, 1080
for _ = 1, 50 do
	local line = WindLogic.newLine(rand, true)
	for _ = 1, 30 do
		local x, y, rotation, length, transparency = WindLogic.lineFrame(line, 1, W, H, cfg)
		local nx, ny = (x - W / 2) / (W / 2), (y - H / 2) / (H / 2)
		local radial = math.sqrt(nx * nx + ny * ny)
		check(radial >= cfg.LineInner - 1e-6 and radial <= cfg.LineOuter + 1e-6, "line in the edge band")
		local dirX, dirY = math.cos(math.rad(rotation)), math.sin(math.rad(rotation))
		check(dirX * nx + dirY * ny > 0 or radial < 1e-6, "line points away from the centre")
		check(transparency >= 1 - cfg.LineMaxOpacity - 1e-6 and transparency <= 1, "subtle opacity")
		check(length > 0 and length <= cfg.LineLength * 1.2 + 1e-6, "length bound")
		WindLogic.stepLine(line, 1 / 60, 1, cfg, rand)
	end
end
local still = WindLogic.newLine(rand, false)
still.progress = 0.5
local _, _, _, _, hidden = WindLogic.lineFrame(still, 0, W, H, cfg)
check(hidden == 1, "invisible at intensity 0")
local edge = WindLogic.newLine(rand, false)
local _, _, _, _, atStart = WindLogic.lineFrame(edge, 1, W, H, cfg)
check(near(atStart, 1), "fades in from transparent")
edge.progress = 0.999
check(WindLogic.stepLine(edge, 1, 1, cfg, rand), "finished line respawns")
check(edge.progress == 0 and edge.angle >= 0 and edge.angle < math.pi * 2, "respawned line restarts at a new angle")

-- 4. Whoosh.
local state = WindLogic.newWhoosh()
check(not WindLogic.whoosh(state, 0.3, 0, cfg), "no whoosh below the threshold")
check(WindLogic.whoosh(state, 0.8, 1, cfg), "whoosh on speed-up")
check(not WindLogic.whoosh(state, 0.9, 2, cfg), "once per speed-up")
check(not WindLogic.whoosh(state, 0.1, 2.5, cfg), "slowing re-arms")
check(not WindLogic.whoosh(state, 0.8, 3, cfg), "cooldown respected")
check(WindLogic.whoosh(state, 0.8, 1 + cfg.WhooshCooldown, cfg), "plays again after the cooldown")

print(`[movement-logic] {checks} checks passed`)
