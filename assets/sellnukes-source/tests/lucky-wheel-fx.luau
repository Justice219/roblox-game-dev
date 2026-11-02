--!strict
--[[
	Lucky Wheel spin presentation maths (owner R81 "ticker effect and more effects"). Run:
		lune run tests/lucky-wheel-fx

	Loads the REAL src/client/UI/Screens/LuckyWheel/SpinMotion.luau and
	src/shared/Config/{LuckyWheelFxConfig, LuckySpinConfig, AudioConfig}.luau and proves:
	  1. Config: every wheel slice has a celebration tier; every sound cue is a real AudioConfig
	     key (a typo would play silence); celebrations grow with the reward (small → jackpot);
	     graphics tiers only trim (Low ≤ Medium ≤ High); confetti fits the pool.
	  2. Geometry: an odd PerSlice puts every slice centre exactly halfway between two pegs, and
	     the wind-up, the overshoot and the flapper's contact zone all fit inside that half gap
	     (pulling back / rocking back never crosses a peg).
	  3. Spin curve: starts at `from` at rest, ends exactly on `to` at rest, never moves
	     backwards, no jump at the launch → slowdown hand-over, top speed at the launch end;
	     a normal spin lasts LuckySpinConfig.SpinAnimationSeconds and a quick one is shorter.
	  4. Tick schedule (60 / 30 / 144 fps, normal + quick): every peg passed is counted; the
	     ticks the player hears (MinGap) space out through the slowdown; the last tick lands
	     inside a suspense window before the stop; tick pitch falls with the speed; the
	     rock-back adds no tick.
	  5. Flapper: stays inside ±MaxDeflect (+ spring overshoot), is pushed against the motion,
	     comes back to rest after the spin, survives a 0.5 s hitch without NaN, and the wind-up
	     presses it the other way.
	  6. Helpers: crossings, blend / backOut / pulse / fade / shake envelopes, streak opacity,
	     bulb chase (one lit per group, moving clockwise), blink, quick-spin window.
]]

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local SpinMotion = loader.load("src/client/UI/Screens/LuckyWheel/SpinMotion")
local Cfg = loader.load("src/shared/Config/LuckyWheelFxConfig")
local LuckySpinConfig = loader.load("src/shared/Config/LuckySpinConfig")
local AudioConfig = loader.load("src/shared/Config/AudioConfig")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

local function finite(x: number): boolean
	return type(x) == "number" and x == x and x > -math.huge and x < math.huge
end

local function near(a: number, b: number, eps: number?): boolean
	return math.abs(a - b) <= (eps or 1e-6)
end

local SLICES = LuckySpinConfig.Slices
local COUNT = #SLICES
local SPAN = 360 / COUNT
local SPACING = SpinMotion.pegSpacing(COUNT, Cfg.Pegs.PerSlice)

-- 1. Config ---------------------------------------------------------------------------------------

local ORDER = { "small", "medium", "big", "rare", "jackpot" }
for _, slice in SLICES do
	check(Cfg.SliceTier[slice.id] ~= nil, `slice {slice.id} has a celebration tier`)
end
check(Cfg.SliceTier.pet == "jackpot" and Cfg.SliceTier.egg == "rare", "RARE PET / EGG get the biggest stings")
for _, name in ORDER do
	local tier = Cfg.Tiers[name]
	check(tier ~= nil, `tier {name} exists`)
	check(tier.seconds > 0 and tier.glow > 0 and tier.glow <= 1 and tier.pulseHz > 0, `tier {name}: timings`)
	check(tier.confetti >= 0 and tier.confetti <= Cfg.ConfettiPool, `tier {name}: confetti fits the pool`)
	check(tier.confetti + tier.sparkles <= Cfg.ConfettiPool, `tier {name}: confetti + sparkles fit the pool`)
	check(#tier.sting >= 1, `tier {name}: has a sting`)
	for _, cue in tier.sting do
		local key = AudioConfig.Aliases[cue.key] or cue.key
		check(AudioConfig.Sfx[key] ~= nil, `tier {name}: sting "{cue.key}" is an AudioConfig key`)
		check(cue.pitch > 0 and cue.volume > 0 and cue.delay >= 0 and cue.delay < tier.seconds, `tier {name}: sane cue`)
	end
end
for i = 2, #ORDER do
	local lower, upper = Cfg.Tiers[ORDER[i - 1]], Cfg.Tiers[ORDER[i]]
	check(upper.confetti >= lower.confetti, `{ORDER[i]} confetti ≥ {ORDER[i - 1]}`)
	check(upper.shake >= lower.shake, `{ORDER[i]} shake ≥ {ORDER[i - 1]}`)
	check(upper.seconds >= lower.seconds, `{ORDER[i]} lasts ≥ {ORDER[i - 1]}`)
	check(#upper.sting >= #lower.sting, `{ORDER[i]} sting ≥ {ORDER[i - 1]}`)
end
for _, key in Cfg.soundKeys() do
	local resolved = AudioConfig.Aliases[key] or key
	check(AudioConfig.Sfx[resolved] ~= nil, `wheel sound "{key}" resolves to an AudioConfig.Sfx key`)
end
check(table.find(Cfg.soundKeys(), "wheel_tick") ~= nil, "the tick is warmed")
check(AudioConfig.Aliases.wheel_tick ~= nil, "wheel_tick is an AudioConfig alias")
local quality = Cfg.Quality
for _, field in { "confetti", "sparkles" } do
	check(quality.Low[field] <= quality.Medium[field], `Low {field} ≤ Medium`)
	check(quality.Medium[field] <= quality.High[field] and quality.High[field] <= 1, `Medium {field} ≤ High ≤ 1`)
end
check(quality.Low.streaks == false and quality.Low.rays == false, "Low graphics drops the motion arcs and rays")
check(Cfg.Bulbs.IdleRates.Low == 0, "the idle bulb chase parks on Low graphics")
check(Cfg.Bulbs.SpinHz.Min > Cfg.Bulbs.IdleHz, "spinning chases faster than idle")
check(Cfg.Bulbs.Count % Cfg.Bulbs.Group == 0, "the chase pattern wraps evenly round the rim")
check(Cfg.Tick.MinGap > 0 and Cfg.Tick.MinGap < 0.1, "tick gap: a rattle, not a buzz")
check(Cfg.QuickSpin.Scale > 0 and Cfg.QuickSpin.Scale < 1, "quick spins are shorter")
check(Cfg.QuickSpin.Turns >= 2 and Cfg.QuickSpin.Turns < Cfg.Spin.Turns, "quick spins turn less (still a spin)")

-- 2. Geometry -------------------------------------------------------------------------------------

check(Cfg.Pegs.PerSlice % 2 == 1, "PerSlice is odd")
for index = 1, COUNT do
	-- WheelDrawing.targetRotation rests the disc at −midAngle (mod 360).
	local rest = (-(index - 0.5) * SPAN) % 360
	check(near(rest % SPACING, SPACING / 2, 1e-9), `slice {index}: rests halfway between two pegs`)
end
local halfGap = SPACING / 2
check(Cfg.WindUp.Degrees < halfGap, "the wind-up never pulls a peg past the pointer")
check(Cfg.WindUp.Degrees + Cfg.WindUp.Tremble < halfGap, "nor does the tremble")
check(halfGap - Cfg.WindUp.Degrees < Cfg.Flapper.Contact, "the wound-up wheel presses the flapper on the peg behind it")
check(Cfg.Spin.Overshoot < halfGap - Cfg.Flapper.Contact, "the overshoot never reaches the next peg's contact zone")
check(Cfg.Flapper.Contact < halfGap, "the contact zone is inside a half gap")

-- 3. Spin curve -----------------------------------------------------------------------------------

-- The screen's plan for a spin from slice-1 rest (wound back) onto slice `index`.
local function spinPlan(index: number, quick: boolean)
	local rest = (-0.5 * SPAN) % 360
	local turns = if quick then Cfg.QuickSpin.Turns else Cfg.Spin.Turns
	local base = rest + turns * 360
	local target = base + ((-(index - 0.5) * SPAN - base) % 360)
	local scale = if quick then Cfg.QuickSpin.Scale else 1
	local total = LuckySpinConfig.SpinAnimationSeconds * scale
	local launch = math.min(Cfg.Spin.Launch * scale, total * 0.5)
	local from = rest - Cfg.WindUp.Degrees
	return SpinMotion.plan(from, target + Cfg.Spin.Overshoot, launch, total - launch, Cfg.Spin.Power), target, rest
end

for _, quick in { false, true } do
	for index = 1, COUNT do
		local plan = spinPlan(index, quick)
		local duration = SpinMotion.duration(plan)
		local expected = LuckySpinConfig.SpinAnimationSeconds * (if quick then Cfg.QuickSpin.Scale else 1)
		check(near(duration, expected, 1e-9), `spin length (quick={quick})`)
		local a0, v0 = SpinMotion.sample(plan, 0)
		check(a0 == plan.from and v0 == 0, "starts at rest on `from`")
		local aEnd, vEnd = SpinMotion.sample(plan, duration)
		check(near(aEnd, plan.to, 1e-6) and vEnd == 0, "ends at rest on `to`")
		local _, vTop = SpinMotion.sample(plan, plan.launch)
		check(near(vTop, plan.top, 1e-6), "top speed at the end of the launch")
		local just = SpinMotion.sample(plan, plan.launch - 1e-7)
		local after = SpinMotion.sample(plan, plan.launch + 1e-7)
		check(math.abs(after - just) < 0.01, "no jump at the launch → slowdown hand-over")
		local previous = a0
		for k = 1, math.ceil(duration * 240) + 10 do
			local a, v = SpinMotion.sample(plan, k / 240)
			check(finite(a) and finite(v), "finite samples")
			check(a >= previous - 1e-9, "the disc never turns backwards during a spin")
			check(v >= 0 and v <= plan.top + 1e-6, "speed within 0..top")
			previous = a
		end
	end
end
local flat = SpinMotion.plan(100, 50, 0.2, 1, 1.6)
check(flat.to == 100 and flat.top == 0, "a backwards plan flattens to a stop")

-- 4. Tick schedule --------------------------------------------------------------------------------

-- Simulates the driver's tick logic at `fps` and returns every audible tick time + pitch, the
-- peg crossings counted, and the plan.
local function simulate(index: number, quick: boolean, fps: number)
	local plan, target, _rest = spinPlan(index, quick)
	local dt = 1 / fps
	local duration = SpinMotion.duration(plan)
	local t, previous = 0, plan.from
	local lastTick = -math.huge
	local ticks: { { t: number, pitch: number } } = {}
	local crossed = 0
	while t < duration do
		t += dt
		local angle, speed = SpinMotion.sample(plan, t)
		local c = SpinMotion.crossings(previous, angle, SPACING)
		crossed += c
		if c ~= 0 and t - lastTick >= Cfg.Tick.MinGap then
			lastTick = t
			local u = SpinMotion.speedNorm(speed, Cfg.Tick.TopSpeed)
			table.insert(ticks, { t = t, pitch = SpinMotion.lerpRange(Cfg.Tick.Pitch, u) })
		end
		previous = angle
	end
	-- Rock-back: target + overshoot → target.
	local settleCrossings = SpinMotion.crossings(target + Cfg.Spin.Overshoot, target, SPACING)
	return ticks, crossed, plan, duration, settleCrossings
end

for _, quick in { false, true } do
	for _, fps in { 30, 60, 144 } do
		for index = 1, COUNT do
			local ticks, crossed, plan, duration, settleCrossings = simulate(index, quick, fps)
			local expected = math.floor(plan.to / SPACING) - math.floor(plan.from / SPACING)
			check(crossed == expected, `every peg passed is counted ({crossed} vs {expected})`)
			check(#ticks >= 12, `a spin ticks plenty (got {#ticks}, quick={quick}, fps={fps})`)
			check(settleCrossings == 0, "the rock-back crosses no peg")
			local last = ticks[#ticks]
			local quiet = duration - last.t
			-- Suspense: the last tick comes a moment before the stop, never at the very end and
			-- never long before it.
			check(quiet >= 0.2 and quiet <= 1.2, `last tick {quiet}s before the stop (quick={quick})`)
			-- The final ticks space out (each gap at least as long as the one before, minus one
			-- frame of sampling jitter) and drop in pitch.
			local n = #ticks
			for k = n - 3, n - 1 do
				local gapBefore = ticks[k].t - ticks[k - 1].t
				local gapAfter = ticks[k + 1].t - ticks[k].t
				check(gapAfter >= gapBefore - 1.5 / fps, `ticks space out through the slowdown (fps={fps})`)
				check(ticks[k + 1].pitch <= ticks[k].pitch + 1e-9, "tick pitch falls with the speed")
			end
			check(ticks[1].pitch > ticks[n].pitch, "the rattle is higher than the last tick")
		end
	end
end

-- 5. Flapper --------------------------------------------------------------------------------------

local tuning = Cfg.Flapper
do
	local plan = spinPlan(3, false)
	local duration = SpinMotion.duration(plan)
	local flap = { angle = 0, velocity = 0 }
	local previous = plan.from
	local t = 0
	local minAngle, maxAngle = 0, 0
	local pushedNegative = false
	while t < duration do
		t += 1 / 60
		local angle = SpinMotion.sample(plan, t)
		local c = SpinMotion.crossings(previous, angle, SPACING)
		SpinMotion.stepFlapper(flap, angle, 1, c, 1 / 60, SPACING, tuning)
		check(finite(flap.angle) and finite(flap.velocity), "flapper stays finite")
		minAngle = math.min(minAngle, flap.angle)
		maxAngle = math.max(maxAngle, flap.angle)
		if flap.angle < -tuning.MaxDeflect * 0.5 then
			pushedNegative = true
		end
		previous = angle
	end
	check(pushedNegative, "a clockwise disc pushes the tip right (negative rotation)")
	check(minAngle >= -tuning.MaxDeflect - 1e-9, "never pushed past MaxDeflect")
	check(maxAngle <= tuning.MaxDeflect, "the snap-back overshoot stays smaller than a push")
	-- At rest after the spin it settles to 0 within 1.5 s.
	local settled = false
	for k = 1, 90 do
		SpinMotion.stepFlapper(flap, previous, 0, 0, 1 / 60, SPACING, tuning)
		if SpinMotion.flapperResting(flap) then
			settled = true
			check(k / 60 <= 1.5, "flapper settles within 1.5 s")
			break
		end
	end
	check(settled, "flapper comes to rest")
	-- A 0.5 s hitch mid-swing: still finite and bounded.
	local hitch = { angle = -tuning.MaxDeflect, velocity = 0 }
	SpinMotion.stepFlapper(hitch, 22.5, 0, 0, 0.5, SPACING, tuning)
	check(finite(hitch.angle) and math.abs(hitch.angle) <= tuning.MaxDeflect, "a long frame stays stable")
	-- Fast frame: a peg crossing inside one frame knocks the tip aside.
	local knock = { angle = 0, velocity = 0 }
	SpinMotion.stepFlapper(knock, 22.5, 1, 1, 1 / 60, SPACING, tuning)
	check(near(knock.angle, -tuning.MaxDeflect * tuning.HitFraction), "a crossed peg knocks the tip")
	-- Wind-up: pulled back from a slice centre, the peg behind presses the tip the other way.
	local wound = { angle = 0, velocity = 0 }
	local rest = SPACING * 7 + SPACING / 2
	SpinMotion.stepFlapper(wound, rest - Cfg.WindUp.Degrees, -1, 0, 1 / 60, SPACING, tuning)
	check(wound.angle > 0 and wound.angle <= tuning.MaxDeflect, "the wind-up presses the flapper (positive)")
	-- Contact grows towards the peg: closer peg, bigger push.
	local far, close = { angle = 0, velocity = 0 }, { angle = 0, velocity = 0 }
	SpinMotion.stepFlapper(far, SPACING - tuning.Contact * 0.8, 1, 0, 0, SPACING, tuning)
	SpinMotion.stepFlapper(close, SPACING - tuning.Contact * 0.2, 1, 0, 0, SPACING, tuning)
	check(close.angle < far.angle and far.angle < 0, "the push grows as the peg approaches")
	-- No contact mid-gap.
	local free = { angle = 0, velocity = 0 }
	SpinMotion.stepFlapper(free, SPACING / 2, 1, 0, 1 / 60, SPACING, tuning)
	check(free.angle == 0, "no push half a gap away from any peg")
end

-- 6. Helpers --------------------------------------------------------------------------------------

check(SpinMotion.crossings(40, 95, 45) == 2, "crossings forwards")
check(SpinMotion.crossings(95, 40, 45) == -2, "crossings backwards")
check(SpinMotion.crossings(44.9, 45, 45) == 1, "landing on a peg counts it")
check(SpinMotion.crossings(-10, 10, 45) == 1, "crossings through zero")
check(SpinMotion.crossings(10, 30, 45) == 0, "no crossing inside a gap")
check(SpinMotion.pegSpacing(8, 1) == 45 and SpinMotion.pegSpacing(8, 3) == 15, "peg spacing")

check(SpinMotion.blend(0, -16, 0, 0.3) == 0 and SpinMotion.blend(0, -16, 0.3, 0.3) == -16, "blend endpoints")
check(near(SpinMotion.blend(0, -16, 0.15, 0.3), -8), "blend midpoint")
check(SpinMotion.blend(3, 0, 1, 0) == 0, "blend with no time is already there")
check(near(SpinMotion.backOut(0), 0) and near(SpinMotion.backOut(1), 1), "backOut endpoints")
local peak = 0
for k = 0, 100 do
	peak = math.max(peak, SpinMotion.backOut(k / 100))
end
check(peak > 1 and peak < 1.15, "backOut punches a little past 1")
check(SpinMotion.pulse(-0.1, 2, 2) == 0 and SpinMotion.pulse(2, 2, 2) == 0, "pulse is 0 outside its window")
for k = 0, 200 do
	local p = SpinMotion.pulse(k / 100, 2, 3)
	check(p >= 0 and p <= 1, "pulse within 0..1")
end
check(SpinMotion.fade(1, 2, 0.25, 0.5) == 1 and SpinMotion.fade(0, 2, 0.25, 0.5) == 0, "fade in / hold")
check(near(SpinMotion.fade(1.75, 2, 0.25, 0.5), 0.5), "fade out")
local x0, y0 = SpinMotion.shake(0.45, 0.45, 8)
check(x0 == 0 and y0 == 0, "shake ends at rest")
for k = 0, 45 do
	local x, y = SpinMotion.shake(k / 100, 0.45, 8)
	check(math.abs(x) <= 8 and math.abs(y) <= 8, "shake within its amplitude")
end
local s = Cfg.Streaks
check(SpinMotion.streakOpacity(0, s.StartSpeed, s.FullSpeed, s.MaxOpacity, s.Step) == 0, "no arcs at rest")
check(near(SpinMotion.streakOpacity(5000, s.StartSpeed, s.FullSpeed, s.MaxOpacity, s.Step), s.MaxOpacity), "full arcs")
local lastOpacity = 0
for speed = 0, 1400, 10 do
	local o = SpinMotion.streakOpacity(speed, s.StartSpeed, s.FullSpeed, s.MaxOpacity, s.Step)
	check(o >= lastOpacity - 1e-9 and o <= s.MaxOpacity + 1e-9, "arc opacity rises with speed, capped")
	lastOpacity = o
end
check(near(SpinMotion.quantize(0.237, 0.05), 0.25), "quantize")
check(SpinMotion.speedNorm(0 / 0, 100) == 0 and SpinMotion.speedNorm(-650, 1300) == 0.5, "speedNorm")
check(near(SpinMotion.lerpRange({ Min = 0.8, Max = 1.4 }, 0.5), 1.1), "lerpRange")

-- Bulbs: exactly one lit per group at every step, and the lit one moves clockwise.
local group = Cfg.Bulbs.Group
for stepIndex = 0, group * 2 do
	for first = 1, Cfg.Bulbs.Count - group, group do
		local lit = 0
		for index = first, first + group - 1 do
			if SpinMotion.bulbLit(index, stepIndex, group) then
				lit += 1
			end
		end
		check(lit == 1, "one bulb lit per group")
	end
end
check(SpinMotion.bulbLit(3, 0, 3) and SpinMotion.bulbLit(4, 1, 3), "the lit bulb steps clockwise")
check(SpinMotion.blinkOn(0.05, 5) and not SpinMotion.blinkOn(0.15, 5), "blink halves")
check(SpinMotion.isQuick(10, 5, 8) and not SpinMotion.isQuick(20, 5, 8), "quick-spin window")
check(not SpinMotion.isQuick(0, -math.huge, 8), "the first spin is never quick")

print(`[lucky-wheel-fx] {checks} checks passed`)
