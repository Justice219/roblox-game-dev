--!strict
--[[
	Launch cinematic regressions (owner R54: "follow the missile ... animated 3, 2, 1. And a
	voiceover"). Run:
		lune run tests/launch-cam
		LAUNCH_CAM_REPORT=1 lune run tests/launch-cam     (also prints the sweep maxima)

	Loads the REAL shipped modules (src/shared/Config/{LaunchCamConfig, AttackConfig},
	src/shared/Attack/{LaunchCamMath, FlightMath, AttackGeometry}) through tests/fixtures/RobloxLoader
	and proves:
	  1. Server timing: the whole 3-2-1 countdown + its network slack fits INSIDE the server's flight
	     lead-in (AttackConfig.Flight.LeadIn), so the cinematic never delays or changes an outcome;
	     every beat has a voice key; overlay budgets fit the pools.
	  2. Countdown: rel sweeps pre → 3 → 2 → 1 → LAUNCH! → after in order, "3" starts exactly at
	     t0 − 3 beats and "LAUNCH!" exactly at t0; elapsed always inside its beat; junk rel is "pre".
	  3. Punch curves: start at PunchFrom, land at 1, bounded overshoot, exit to ExitScale; Reduce
	     Motion = no scale / rotation; junk input stays finite.
	  4. Spring: converges, never overshoots from rest (critically damped), a 10 s frame lands on the
	     target without exploding, dt 0 / NaN dt / NaN target / omega 0 are safe.
	  5. Timelines: for random durations / interceptions (incl. NaN, negative, huge) every field is
	     finite and ordered (chaseStart ≤ chaseFull, approachAt < endAt ≤ duration < holdUntil...).
	  6. Full cinematic sweep over every attacker plot × silo × target (8 plots + 4 Rival islands) ×
	     impact × hit / intercept × Reduce Motion: every frame's CFrame + FOV is finite, the camera
	     never teleports between frames (except Reduce Motion's intended cuts), the nuke stays in
	     front of the camera for the whole chase, and the outcome point is centred during the hold.
	  7. Degenerate input (from == to, vertical view, NaN rel / dt) never yields NaN.
	  8. Skip: from any moment, the return reaches the player's camera exactly within
	     SkipReturnSeconds, getting monotonically closer; Reduce Motion returns instantly; taps are
	     ignored during the grace window, forced sources (menu / closed / external) never are.
	  9. Overlay paths: burst + confetti pieces are finite, hidden outside their window, inside a
	     sane screen box; hash01 ∈ [0, 1); shake bounded by its amplitude.
]]

local process = require("@lune/process")
local roblox = require("@lune/roblox")

local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local AttackConfig = loader.load("src/shared/Config/AttackConfig")
local LaunchCamConfig = loader.load("src/shared/Config/LaunchCamConfig")
local LaunchCamMath = loader.load("src/shared/Attack/LaunchCamMath")
local FlightMath = loader.load("src/shared/Attack/FlightMath")
local AttackGeometry = loader.load("src/shared/Attack/AttackGeometry")
local WorldLayout = loader.load("src/shared/Config/WorldLayout")

local REPORT = process.env.LAUNCH_CAM_REPORT == "1"
local NAN = 0 / 0
local INF = math.huge

local checks = 0
local function ok(condition: any, label: string)
	if not condition then
		error(`FAIL: {label}`, 2)
	end
	checks += 1
end

local function finiteNumber(x: number): boolean
	return x == x and x > -INF and x < INF
end

local function finiteVector(v: any): boolean
	return finiteNumber(v.X) and finiteNumber(v.Y) and finiteNumber(v.Z)
end

local function finiteCFrame(cf: any): boolean
	local components = { cf:GetComponents() }
	for _, value in components do
		if not finiteNumber(value) then
			return false
		end
	end
	return #components == 12
end

local function near(a: number, b: number, eps: number, label: string)
	ok(math.abs(a - b) <= eps, `{label} (got {a}, want {b})`)
end

local COUNTDOWN = LaunchCamConfig.Countdown
local SHOTS = LaunchCamConfig.Shots

-- 1. Server timing + config ------------------------------------------------------------------------
do
	local countdownSeconds = #COUNTDOWN.Steps * COUNTDOWN.Beat
	ok(
		countdownSeconds + COUNTDOWN.NetSlack <= AttackConfig.Flight.LeadIn + 1e-9,
		`the countdown ({countdownSeconds} s + {COUNTDOWN.NetSlack} s slack) fits the server lead-in ({AttackConfig.Flight.LeadIn} s)`
	)
	ok(COUNTDOWN.NetSlack >= 0.25, "at least 0.25 s of network slack before '3'")
	for _, number in COUNTDOWN.Steps do
		ok(type(COUNTDOWN.Voice[number]) == "string", `voice key for {number}`)
		ok(type(COUNTDOWN.Colors[number]) == "string", `colour for {number}`)
	end
	ok(type(COUNTDOWN.LaunchVoice) == "string", "LAUNCH! voice key")
	for _, kind in { "Hit", "Intercepted", "Knockdown" } do
		local shout = LaunchCamConfig.Outcome.Shouts[kind]
		ok(shout ~= nil and type(shout.voice) == "string" and type(shout.text) == "string", `shout {kind}`)
	end
	for tier, budget in LaunchCamConfig.FxTiers do
		ok(budget.burst >= 1 and budget.burst <= 16, `{tier} burst fits the 16-piece pool`)
		ok(budget.confetti >= 0 and budget.confetti <= 40, `{tier} confetti fits the 40-piece pool`)
	end
	ok(LaunchCamConfig.FxTiers.Low.confetti < LaunchCamConfig.FxTiers.High.confetti, "Low tier = fewer particles")
	ok(SHOTS.SkipReturnSeconds < SHOTS.ReturnSeconds, "a skip returns faster than the normal end")
	ok(LaunchCamConfig.Input.SkipGraceSeconds <= 0.5, "skip grace stays short")
end

-- 2. Countdown -----------------------------------------------------------------------------------
do
	local beat = COUNTDOWN.Beat
	local steps = COUNTDOWN.Steps
	local hold = COUNTDOWN.LaunchHold
	local order = { pre = 0, count = 1, launch = 2, after = 3 }
	local lastRank, lastStepIndex = -1, 0
	local rel = -4.5
	while rel <= 3 do
		local phase, step, elapsed, length = LaunchCamMath.countdown(rel, beat, steps, hold)
		local rank = order[phase]
		ok(rank ~= nil, `phase name at {rel}`)
		ok(rank >= lastRank, `phases never go backwards at {rel}`)
		if phase == "count" then
			local index = table.find(steps, step)
			ok(index ~= nil, `count shows a configured number at {rel}`)
			ok(index >= lastStepIndex, `numbers count down in order at {rel}`)
			lastStepIndex = index
			ok(elapsed >= -1e-9 and elapsed < length + 1e-9, `elapsed inside the beat at {rel}`)
		end
		if phase == "launch" then
			ok(elapsed >= 0 and elapsed < length, "elapsed inside LAUNCH!")
		end
		lastRank = rank
		rel += 0.001
	end
	local phase, step, elapsed = LaunchCamMath.countdown(-3 * beat, beat, steps, hold)
	ok(phase == "count" and step == steps[1] and math.abs(elapsed) < 1e-9, "'3' starts exactly at t0 - 3 beats")
	phase, step = LaunchCamMath.countdown(-1e-6, beat, steps, hold)
	ok(phase == "count" and step == steps[#steps], "'1' is up until t0")
	phase, _, elapsed = LaunchCamMath.countdown(0, beat, steps, hold)
	ok(phase == "launch" and elapsed == 0, "LAUNCH! exactly at t0")
	phase = LaunchCamMath.countdown(NAN, beat, steps, hold)
	ok(phase == "pre", "NaN rel is 'pre'")
	phase = LaunchCamMath.countdown(-1, NAN, steps, hold)
	ok(phase == "count", "NaN beat falls back to 1 s")
end

-- 3. Punch curves --------------------------------------------------------------------------------
do
	local length = COUNTDOWN.Beat
	local s0, r0 = LaunchCamMath.punch(0, length, COUNTDOWN, false)
	near(s0, COUNTDOWN.PunchFrom, 1e-9, "punch starts at PunchFrom")
	near(r0, COUNTDOWN.PunchDegrees, 1e-9, "punch starts rotated")
	local s1, r1, t1 = LaunchCamMath.punch(COUNTDOWN.PunchSeconds, length, COUNTDOWN, false)
	near(s1, 1, 1e-9, "punch lands at scale 1")
	near(r1, 0, 1e-9, "punch lands upright")
	ok(t1 == 0, "fully visible after the punch")
	local minScale, maxScale = INF, -INF
	for i = 0, 1000 do
		local e = i / 1000 * length
		local s, r, t = LaunchCamMath.punch(e, length, COUNTDOWN, false)
		ok(finiteNumber(s) and finiteNumber(r) and finiteNumber(t), "punch finite")
		if e <= COUNTDOWN.PunchSeconds then
			minScale = math.min(minScale, s)
			maxScale = math.max(maxScale, s)
		end
	end
	ok(maxScale <= COUNTDOWN.PunchFrom + 1e-9, "punch never grows past PunchFrom")
	ok(minScale >= 0.8, `punch overshoot stays readable (min scale {minScale})`)
	local sEnd = LaunchCamMath.punch(length - 1e-6, length, COUNTDOWN, false)
	near(sEnd, COUNTDOWN.ExitScale, 1e-3, "exit shrinks to ExitScale")
	local _, _, gone = LaunchCamMath.punch(length, length, COUNTDOWN, false)
	ok(gone == 1, "hidden once the beat is over")
	for i = 0, 100 do
		local s, r = LaunchCamMath.punch(i / 100 * length, length, COUNTDOWN, true)
		ok(s == 1 and r == 0, "Reduce Motion: no scale / rotation")
	end
	for _, junk in { NAN, INF, -INF, -5, 1e300 } do
		local s, r, t = LaunchCamMath.punch(junk, junk, COUNTDOWN, false)
		ok(finiteNumber(s) and finiteNumber(r) and finiteNumber(t), `punch finite for {junk}`)
	end
end

-- 4. Spring --------------------------------------------------------------------------------------
do
	local target = Vector3.new(100, -40, 25)
	local x, v = Vector3.zero, Vector3.zero
	local lastDistance = (x - target).Magnitude
	for _ = 1, 600 do
		x, v = LaunchCamMath.spring(x, v, target, 4, 1 / 60)
		local distance = (x - target).Magnitude
		ok(distance <= lastDistance + 1e-9, "critically damped from rest: never overshoots")
		lastDistance = distance
	end
	ok((x - target).Magnitude < 1e-3, "spring converges in 10 s")
	local bx, bv = LaunchCamMath.spring(Vector3.new(5000, 0, 0), Vector3.new(0, 9000, 0), target, 4, 10)
	ok(finiteVector(bx) and finiteVector(bv) and (bx - target).Magnitude < 1, "a 10 s frame lands on the target")
	local sx, sv = LaunchCamMath.spring(Vector3.one, Vector3.zero, target, 4, 0)
	ok(sx == Vector3.one and sv == Vector3.zero, "dt 0 changes nothing")
	sx = LaunchCamMath.spring(Vector3.one, Vector3.zero, target, 4, NAN)
	ok(sx == Vector3.one, "NaN dt is treated as 0")
	sx = LaunchCamMath.spring(Vector3.one, Vector3.zero, Vector3.new(NAN, 0, 0), 4, 1 / 60)
	ok(sx == Vector3.one, "NaN target leaves the value alone")
	sx = LaunchCamMath.spring(Vector3.new(NAN, 0, 0), Vector3.zero, target, 4, 1 / 60)
	ok(sx == target, "a NaN state snaps to the target")
	sx = LaunchCamMath.spring(Vector3.one, Vector3.zero, target, 0, 1 / 60)
	ok(sx == target, "omega 0 snaps")
	local n, nv = 0, 0
	for _ = 1, 600 do
		n, nv = LaunchCamMath.springNumber(n, nv, 10, 4, 1 / 60)
	end
	near(n, 10, 1e-3, "scalar spring converges")
	n = LaunchCamMath.springNumber(NAN, 0, 3, 4, 1 / 60)
	ok(n == 3, "scalar NaN snaps")
end

-- 5. Timelines -----------------------------------------------------------------------------------
local seed = 12345
local function rand(): number
	seed = (seed * 48271) % 2147483647
	return seed / 2147483647
end

do
	local junk = { NAN, INF, -INF, -3, 0, 1e9 }
	for i = 1, 4000 do
		local duration = if i % 50 == 0 then junk[(i // 50) % #junk + 1] else 0.1 + rand() * 30
		local intercepted = rand() < 0.5
		local interceptAt = if i % 37 == 0 then junk[(i // 37) % #junk + 1] else rand() * 32 - 1
		local tl = LaunchCamMath.timeline(duration, intercepted, interceptAt, SHOTS)
		for key, value in tl do
			if type(value) == "number" then
				ok(finiteNumber(value), `timeline.{key} finite`)
			end
		end
		ok(tl.chaseStart <= tl.chaseFull, "chaseStart <= chaseFull")
		ok(tl.approachAt < tl.endAt, "approachAt < endAt")
		ok(tl.endAt <= tl.duration + 1e-9, "endAt <= duration")
		ok(tl.endAt > 0, "endAt > 0")
		ok(tl.holdUntil > tl.endAt, "holdUntil > endAt")
		if not intercepted then
			ok(tl.endAt == tl.duration, "a hit ends at impact")
		end
	end
end

-- 6. Full cinematic sweep ------------------------------------------------------------------------
local function angleBetween(a: any, b: any): number
	local dot = math.clamp(a.Unit:Dot(b.Unit), -1, 1)
	return math.deg(math.acos(dot))
end

--[[
	Simulates one cinematic at `fps` from the countdown to the end of the hold, the same way the
	director calls LaunchCamMath.frame. Returns the per-frame maxima for the report.
]]
local function simulate(
	fromPlot: number,
	silo: number,
	toPlot: number,
	impact: number,
	area: number,
	intercept: number?,
	reduced: boolean,
	fps: number
)
	-- The same aim-aware arc FlightRenderer / LaunchCam build (area 0 = legacy impact index).
	local path = AttackGeometry.flightOf({
		fromPlot = fromPlot,
		silo = silo,
		toPlot = toPlot,
		impact = impact,
		area = area,
		sx = if area > 0 then 6 else 0,
		sz = if area > 0 then -5 else 0,
	})
	local intercepted = intercept ~= nil
	local tl = LaunchCamMath.timeline(path.duration, intercepted, (intercept or 0) * path.duration, SHOTS)
	local flat = LaunchCamMath.flatDir(path.from, path.to)
	local startRel = -AttackConfig.Flight.LeadIn
	local shot = {
		flight = path,
		timeline = tl,
		flat = flat,
		startRel = startRel,
		reduced = reduced,
		siloReach = INF,
		impactReach = INF,
		chase = LaunchCamMath.newChase(flat),
	}
	local dt = 1 / fps
	local lastCf: any = nil
	local maxStep, maxTurn, minChaseDot, minHoldDot = 0, 0, 1, 1
	local rel = startRel
	while rel <= tl.holdUntil + 0.5 do
		local cf, fov = LaunchCamMath.frame(shot, rel, dt, LaunchCamConfig)
		ok(finiteCFrame(cf), "frame CFrame finite")
		ok(finiteNumber(fov) and fov >= 20 and fov <= 110, "frame FOV finite and sane")
		if lastCf ~= nil and not reduced then
			maxStep = math.max(maxStep, (cf.Position - lastCf.Position).Magnitude)
			maxTurn = math.max(maxTurn, angleBetween(cf.LookVector, lastCf.LookVector))
		end
		-- The nuke stays in front of the camera for the whole chase AND the braking approach (the
		-- camera never overtakes it).
		if not reduced and rel >= tl.chaseFull and rel <= tl.endAt - 0.05 then
			local nuke = FlightMath.position(path, rel)
			minChaseDot = math.min(minChaseDot, cf.LookVector:Dot((nuke - cf.Position).Unit))
		end
		if rel >= tl.endAt + 0.05 then
			local point = FlightMath.position(path, tl.endAt)
			minHoldDot = math.min(minHoldDot, cf.LookVector:Dot((point - cf.Position).Unit))
		end
		lastCf = cf
		rel += dt
	end
	return maxStep, maxTurn, minChaseDot, minHoldDot
end

do
	local slots = AttackGeometry.slotCount()
	ok(slots == WorldLayout.PlotCount + #AttackConfig.Rivals.List, "slot count = plots + rivals")
	local worstStep, worstTurn, worstChase, worstHold = 0, 0, 1, 1
	local sims = 0
	local fps = 30
	for fromPlot = 1, WorldLayout.PlotCount do
		-- Silo 1 on odd plots, silo 3 on even ones (both ends of the silo row, half the runtime).
		do
			local silo = if fromPlot % 2 == 0 then 3 else 1
			for toPlot = 1, slots do
				if toPlot ~= fromPlot then
					-- The legacy last impact point, and an aimed shot at the slot's last area (owner R50).
					local aims = {
						{ impact = AttackGeometry.impactCount(toPlot), area = 0 },
						{ impact = 1, area = AttackGeometry.areaCount(toPlot) },
					}
					for _, aim in aims do
						for _, intercept in { false, 0.55 } do
							for _, reduced in { false, true } do
								local step, turn, chase, hold = simulate(
									fromPlot,
									silo,
									toPlot,
									aim.impact,
									aim.area,
									if intercept == false then nil else intercept :: number,
									reduced,
									fps
								)
								sims += 1
								worstStep = math.max(worstStep, step)
								worstTurn = math.max(worstTurn, turn)
								worstChase = math.min(worstChase, chase)
								worstHold = math.min(worstHold, hold)
							end
						end
					end
				end
			end
		end
	end
	-- 30 fps: a step of 30 studs = 900 studs/s; the fastest flight + blend stays well under it.
	ok(worstStep < 30, `the camera never teleports between frames (max step {worstStep})`)
	ok(worstTurn < 25, `the view never snaps round (max turn {worstTurn}° per frame)`)
	ok(worstChase > 0.5, `the nuke stays in front of the camera during the chase (min dot {worstChase})`)
	ok(worstHold > 0.85, `the outcome is centred during the hold (min dot {worstHold})`)
	if REPORT then
		print(
			string.format(
				"[launch-cam] %d sims @%d fps: max step %.2f studs, max turn %.2f°, min chase dot %.3f, min hold dot %.3f",
				sims,
				fps,
				worstStep,
				worstTurn,
				worstChase,
				worstHold
			)
		)
	end
	-- 120 fps on a few flights: continuity at every phase boundary.
	local fineStep, fineTurn = 0, 0
	-- { fromPlot, silo, toPlot, impact, area }
	for _, case in { { 1, 1, 5, 1, 0 }, { 2, 3, 9, 2, 1 }, { 8, 1, 12, 1, 2 }, { 4, 2, 3, 3, 6 } } do
		for _, intercept in { false, 0.25, 0.8 } do
			local step, turn = simulate(
				case[1],
				case[2],
				case[3],
				case[4],
				case[5],
				if intercept == false then nil else intercept :: number,
				false,
				120
			)
			fineStep = math.max(fineStep, step)
			fineTurn = math.max(fineTurn, turn)
		end
	end
	ok(fineStep < 8, `120 fps: no jump at any phase boundary (max step {fineStep})`)
	ok(fineTurn < 8, `120 fps: no view snap at any phase boundary (max turn {fineTurn}°)`)
	if REPORT then
		print(string.format("[launch-cam] 120 fps: max step %.2f studs, max turn %.2f°", fineStep, fineTurn))
	end
end

-- 7. Degenerate input ----------------------------------------------------------------------------
do
	local same = FlightMath.build(Vector3.new(10, 5, 10), Vector3.new(10, 5, 10), 5)
	local flat = LaunchCamMath.flatDir(same.from, same.to)
	ok(finiteVector(flat) and math.abs(flat.Magnitude - 1) < 1e-6, "flatDir of coincident points is a unit vector")
	local shot = {
		flight = same,
		timeline = LaunchCamMath.timeline(same.duration, false, 0, SHOTS),
		flat = flat,
		startRel = -3.4,
		reduced = false,
		siloReach = 10,
		impactReach = 0,
		chase = LaunchCamMath.newChase(flat),
	}
	for _, rel in { NAN, INF, -INF, -3.4, 0, 0.75, 2, 5, 9, 1e9 } do
		for _, dt in { NAN, -1, 0, 1 / 60, 100 } do
			local cf, fov = LaunchCamMath.frame(shot, rel, dt, LaunchCamConfig)
			ok(finiteCFrame(cf) and finiteNumber(fov), `degenerate frame finite (rel {rel}, dt {dt})`)
		end
	end
	local up = LaunchCamMath.lookAt(Vector3.zero, Vector3.new(0, 100, 0), nil)
	ok(finiteCFrame(up), "straight-up lookAt is finite")
	local coincident = LaunchCamMath.lookAt(Vector3.one, Vector3.one, Vector3.new(1, 0, 0))
	ok(finiteCFrame(coincident) and coincident.LookVector:Dot(Vector3.new(1, 0, 0)) > 0.99, "coincident lookAt uses forward")
	local junk = LaunchCamMath.lookAt(Vector3.new(NAN, 0, 0), Vector3.new(0, INF, 0), nil)
	ok(finiteCFrame(junk), "NaN lookAt is finite")
	local clamped = LaunchCamMath.clampEye(Vector3.zero, Vector3.new(0, 2, 100), 10)
	near((clamped - Vector3.new(0, LaunchCamMath.RayLift, 0)).Magnitude, 10, 1e-6, "clampEye pulls the eye in to the limit")
	ok(LaunchCamMath.clampEye(Vector3.zero, Vector3.new(0, 2, 5), 10) == Vector3.new(0, 2, 5), "clampEye keeps a close eye")
	ok(LaunchCamMath.clampEye(Vector3.zero, Vector3.new(0, 2, 500), INF) == Vector3.new(0, 2, 500), "clampEye: clear view")
end

-- 8. Skip ----------------------------------------------------------------------------------------
do
	local path = AttackGeometry.flightOf({ fromPlot = 1, silo = 1, toPlot = 10, impact = 1, area = 1, sx = 0, sz = 0 })
	local tl = LaunchCamMath.timeline(path.duration, false, 0, SHOTS)
	local playerView = CFrame.lookAt(Vector3.new(40, 30, 60), Vector3.new(0, 5, 0))
	for i = 1, 60 do
		local skipRel = -3.4 + (tl.holdUntil + 3.4) * (i / 60)
		local flat = LaunchCamMath.flatDir(path.from, path.to)
		local shot = {
			flight = path,
			timeline = tl,
			flat = flat,
			startRel = -3.4,
			reduced = false,
			siloReach = INF,
			impactReach = INF,
			chase = LaunchCamMath.newChase(flat),
		}
		local rel = -3.4
		local cf = playerView
		while rel < skipRel do
			cf = LaunchCamMath.frame(shot, rel, 1 / 30, LaunchCamConfig)
			rel += 1 / 30
		end
		local from = cf
		local seconds = SHOTS.SkipReturnSeconds
		local last = (from.Position - playerView.Position).Magnitude
		local e = 0
		while e <= seconds + 1e-9 do
			local w = LaunchCamMath.returnBlend(e, seconds)
			local now = from:Lerp(playerView, w)
			ok(finiteCFrame(now), "return frame finite")
			local d = (now.Position - playerView.Position).Magnitude
			ok(d <= last + 1e-6, "the return only gets closer")
			last = d
			e += 1 / 60
		end
		local final = from:Lerp(playerView, LaunchCamMath.returnBlend(seconds, seconds))
		ok((final.Position - playerView.Position).Magnitude < 1e-4, `skip at rel {skipRel} lands on the player's camera`)
		ok(final.LookVector:Dot(playerView.LookVector) > 0.99999, "and looks where the player looked")
	end
	ok(LaunchCamMath.returnBlend(0, 0) == 1, "Reduce Motion returns instantly")
	ok(LaunchCamMath.returnBlend(NAN, 0.35) == 1, "NaN elapsed finishes the return")
	local grace = LaunchCamConfig.Input.SkipGraceSeconds
	ok(not LaunchCamMath.skipAllowed("tap", 0.05, grace), "the launch click never skips its own cinematic")
	ok(LaunchCamMath.skipAllowed("tap", grace + 0.01, grace), "a tap after the grace skips")
	ok(LaunchCamMath.skipAllowed("back", grace, grace), "Back at the grace edge skips")
	for _, forced in { "menu", "closed", "external" } do
		ok(LaunchCamMath.skipAllowed(forced, 0, grace), `{forced} always ends it`)
	end
end

-- 9. Overlay paths -------------------------------------------------------------------------------
do
	for s = 1, 50 do
		for index = 1, 40 do
			local h = LaunchCamMath.hash01(s, index, 3)
			ok(h >= 0 and h < 1, "hash01 in [0, 1)")
		end
	end
	ok(LaunchCamMath.hash01(7, 3, 1) == LaunchCamMath.hash01(7, 3, 1), "hash01 deterministic")
	local burst = LaunchCamConfig.Burst
	local confetti = LaunchCamConfig.Confetti
	for index = 1, 16 do
		for i = -5, 70 do
			local e = i / 100
			local dx, dy, r, t = LaunchCamMath.burstPiece(index, 16, e, 99, burst)
			ok(finiteNumber(dx) and finiteNumber(dy) and finiteNumber(r) and finiteNumber(t), "burst finite")
			if e < 0 or e >= burst.Seconds then
				ok(t == 1, "burst hidden outside its window")
			else
				ok(math.sqrt(dx * dx + dy * dy) <= burst.DistanceMax + 1e-6, "burst stays within DistanceMax")
			end
		end
	end
	for index = 1, 40 do
		for i = -5, 200 do
			local e = i / 100
			local dx, dy, r, t = LaunchCamMath.confettiPiece(index, e, 99, confetti)
			ok(finiteNumber(dx) and finiteNumber(dy) and finiteNumber(r) and finiteNumber(t), "confetti finite")
			if e < 0 or e >= confetti.Seconds then
				ok(t == 1, "confetti hidden outside its window")
			else
				ok(math.abs(dx) <= 2200 and dy <= 3000 and dy >= -1300, "confetti stays in a sane screen box")
			end
		end
	end
	ok(LaunchCamMath.shake(1.2, 0, 9) == Vector3.zero, "no shake at amplitude 0")
	for i = 0, 500 do
		local v = LaunchCamMath.shake(i / 97, 0.5, 9)
		ok(finiteVector(v) and v.Magnitude <= 0.5 * math.sqrt(3) + 1e-9, "shake bounded by its amplitude")
	end
	ok(LaunchCamMath.decay(-0.1, 1) == 0 and LaunchCamMath.decay(0, 1) == 1 and LaunchCamMath.decay(1, 1) == 0, "decay window")
end

print(`[launch-cam] {checks} checks passed`)
