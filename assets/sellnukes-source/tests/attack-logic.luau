--!strict
--[[
	Attack mode pure-logic regressions (spec §9). Run:
		lune run tests/attack-logic            (from the repo root)
		ATTACK_REPORT=1 lune run tests/attack-logic   (also prints the intercept-rate tuning table)

	Proves on the shipped modules (Shared/Attack/{AttackRng, FlightMath, AttackLogic, AttackGeometry},
	Shared/Config/AttackConfig):
	  1. AttackRng: same seed → same stream; mix() spreads neighbouring ids; uniform mean / range;
	     integer() bounds.
	  2. FlightMath: duration / apex clamps; the arc starts at the silo and ends at the impact point;
	     velocity is the true derivative; rangeWindow boundaries sit exactly on the range sphere;
	     engageWindow respects the interceptor travel time and the impact margin.
	  3. Interception determinism + probability: identical inputs + seed → identical results; over
	     many seeded trials the intercept rate matches 1 - (1 - p(1 - armor))^shots; shots are
	     `reload` apart and the tower's next free time carries between nukes (a Barrage saturates).
	  4. Geometry: every attacker/target plot pair, every silo and impact point gives a flight the
	     target's tower can engage at EVERY AA level (towers are never useless), flight times stay in
	     [MinSeconds, MaxSeconds], and the tower is never in range of the attacker's own silo.
	  5. AttackLogic rules: effective levels, upgrade prices, the reward band (never negative, never
	     above MaxRatio x attacker income x rewardSeconds x passes), eligibility (new players,
	     shields, cooldown, self, missing console, empty barrage, revenge rules; AFK players ARE
	     targetable — owner R43), shields, reasons.
	  6. The tuning targets: a single nuke is intercepted ~20-40 % at AA 1 vs Launcher 1 and
	     ~60-85 % at AA 5 vs Launcher 1; armor lowers it; AA 5 vs Launcher 5 stays below AA 5 vs L1.
	  7. Server helpers: TimeQueue pops in time order (random pushes, ties, interleaved pops);
	     AttackProfile reads / writes `profile.attack` nil-safely, whole and clamped (barrage).
]]

local process = require("@lune/process")
local roblox = require("@lune/roblox")

local Vector3 = roblox.Vector3

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local AttackConfig = loader.load("src/shared/Config/AttackConfig")
local AttackRng = loader.load("src/shared/Attack/AttackRng")
local FlightMath = loader.load("src/shared/Attack/FlightMath")
local AttackLogic = loader.load("src/shared/Attack/AttackLogic")
local AttackGeometry = loader.load("src/shared/Attack/AttackGeometry")
local WorldLayout = loader.load("src/shared/Config/WorldLayout")
local TimeQueue = loader.load("src/server/Attack/TimeQueue")
local AttackProfile = loader.load("src/server/Attack/AttackProfile")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

local function near(a: number, b: number, eps: number): boolean
	return math.abs(a - b) <= eps
end

local nan = 0 / 0
local inf = math.huge
local FLIGHT = AttackConfig.Flight

--------------------------------------------------------------------------------------------------
-- 1. AttackRng
--------------------------------------------------------------------------------------------------

do
	local a = AttackRng.new(12345)
	local b = AttackRng.new(12345)
	for _ = 1, 200 do
		check(a:next() == b:next(), "rng: same seed, same stream")
	end
	local c = AttackRng.new(12346)
	local same = 0
	local x = AttackRng.new(12345)
	for _ = 1, 50 do
		if x:next() == c:next() then
			same += 1
		end
	end
	check(same < 3, "rng: different seeds diverge")

	local sum, low, high = 0, 1, 0
	local r = AttackRng.new(AttackRng.mix(99, 7))
	local n = 20000
	for _ = 1, n do
		local v = r:next()
		check(v >= 0 and v < 1, "rng: [0, 1)")
		sum += v
		low = math.min(low, v)
		high = math.max(high, v)
	end
	check(near(sum / n, 0.5, 0.01), `rng: mean ≈ 0.5 (got {sum / n})`)
	check(low < 0.001 and high > 0.999, "rng: covers the range")

	local counts = { 0, 0, 0, 0, 0, 0, 0, 0 }
	for _ = 1, 16000 do
		local i = r:integer(1, 8)
		check(i >= 1 and i <= 8 and i % 1 == 0, "rng: integer bounds")
		counts[i] += 1
	end
	for i = 1, 8 do
		check(counts[i] > 1700 and counts[i] < 2300, `rng: integer uniform ({i}: {counts[i]})`)
	end
	check(r:integer(5, 5) == 5 and r:integer(5, 2) == 5, "rng: degenerate integer range")

	local seeds: { [number]: boolean } = {}
	for id = 1, 1000 do
		local seed = AttackRng.mix(424242, id)
		check(seed >= 0 and seed < 2 ^ 32 and seed % 1 == 0, "rng: mix is u32")
		check(seeds[seed] == nil, "rng: mix spreads neighbouring ids")
		seeds[seed] = true
	end
	check(AttackRng.mix(nan, inf) == AttackRng.mix(0, 0), "rng: mix NaN/inf → 0")
	check(AttackRng.imul(0xFFFFFFFF, 0xFFFFFFFF) == 1, "rng: imul wraps exactly")
	check(AttackRng.imul(123456789, 987654321) == 4227814277, "rng: imul matches C (123456789*987654321 mod 2^32)")
end

--------------------------------------------------------------------------------------------------
-- 2. FlightMath geometry
--------------------------------------------------------------------------------------------------

do
	check(FlightMath.duration(0) == FLIGHT.MinSeconds, "duration: min clamp")
	check(FlightMath.duration(1e9) == FLIGHT.MaxSeconds, "duration: max clamp")
	check(
		FlightMath.duration(nan) == FLIGHT.MinSeconds and FlightMath.duration(-5) == FLIGHT.MinSeconds,
		"duration: hostile"
	)
	check(FlightMath.apex(0) == FLIGHT.ApexMin and FlightMath.apex(1e9) == FLIGHT.ApexMax, "apex: clamps")

	local from = Vector3.new(10, 18, -40)
	local to = Vector3.new(520, 0, 300)
	local flight = FlightMath.build(from, to)
	check(near((FlightMath.position(flight, 0) - from).Magnitude, 0, 1e-3), "position(0) = launch point")
	check(near((FlightMath.position(flight, flight.duration) - to).Magnitude, 0, 1e-3), "position(T) = impact point")
	check(near((FlightMath.position(flight, -3) - from).Magnitude, 0, 1e-3), "position clamps below 0")
	check(near((FlightMath.position(flight, nan) - from).Magnitude, 0, 1e-3), "position NaN → start")
	local mid = FlightMath.position(flight, flight.duration / 2)
	check(near(mid.Y - (from.Y + to.Y) / 2, flight.apex, 1e-3), "apex at mid-flight")
	for _, t in { 0.3, 1.1, 2.9, 4.4 } do
		local h = 0.01
		local numeric = (FlightMath.position(flight, t + h) - FlightMath.position(flight, t - h)) / (2 * h)
		check((numeric - FlightMath.velocity(flight, t)).Magnitude < 0.05, `velocity is the derivative at t={t}`)
	end
	local custom = FlightMath.build(from, to, 7.25)
	check(custom.duration == 7.25, "build: published duration wins")
	check(FlightMath.build(from, to, nan).duration == flight.duration, "build: NaN duration → computed")

	-- rangeWindow: a tower right at the impact point.
	local range = 200
	local enter, exit = FlightMath.rangeWindow(flight, to, range)
	check(enter ~= nil and exit ~= nil, "window: tower at impact engages")
	check(near(exit :: number, flight.duration, 1e-9), "window: in range until impact")
	check(
		near((FlightMath.position(flight, enter :: number) - to).Magnitude, range, 0.05),
		"window: enter on the sphere"
	)
	check(
		(FlightMath.position(flight, (enter :: number) - 0.01) - to).Magnitude > range,
		"window: before enter is outside"
	)
	check(FlightMath.rangeWindow(flight, Vector3.new(0, -5000, 0), range) == nil, "window: far tower never engages")
	check(
		FlightMath.rangeWindow(flight, to, nan) == nil and FlightMath.rangeWindow(flight, to, -1) == nil,
		"window: bad range"
	)

	local from2, to2 = FlightMath.engageWindow(flight, to, range)
	check(from2 ~= nil and to2 ~= nil, "engageWindow exists")
	check((from2 :: number) >= FLIGHT.InterceptorSeconds - 1e-9, "engageWindow: after interceptor travel")
	check(near(to2 :: number, flight.duration - FLIGHT.ImpactMargin, 1e-9), "engageWindow: impact margin")
end

--------------------------------------------------------------------------------------------------
-- 3. Interception: determinism, probability, shot spacing, saturation
--------------------------------------------------------------------------------------------------

local function engageOnce(seed: number, windowFrom: number, windowTo: number, aa: any, armor: number, freeAt: number)
	return FlightMath.engage({
		windowFrom = windowFrom,
		windowTo = windowTo,
		reload = aa.reload,
		chance = aa.chance,
		armor = armor,
		towerFreeAt = freeAt,
		rng = AttackRng.new(seed),
	})
end

do
	local aa = AttackConfig.AA[1]
	local r1 = engageOnce(777, 2, 6, aa, 0, -10)
	local r2 = engageOnce(777, 2, 6, aa, 0, -10)
	check(
		r1.intercepted == r2.intercepted
			and r1.interceptAt == r2.interceptAt
			and r1.shots == r2.shots
			and r1.firstShotAt == r2.firstShotAt
			and r1.towerFreeAt == r2.towerFreeAt,
		"engage: deterministic"
	)
	-- Shots: first fires so the meeting time is the window start, then every `reload`.
	local expectedFirst = 2 - FLIGHT.InterceptorSeconds
	check(r1.shots >= 1 and near(r1.firstShotAt, expectedFirst, 1e-9), "engage: first shot meets at window start")
	local maxShots = math.floor((6 - 2) / aa.reload) + 1
	check(r1.shots <= maxShots, "engage: shot count bounded by the window")
	if r1.intercepted then
		local lastFire = FlightMath.shotTime(r1.firstShotAt, r1.shots, aa.reload)
		check(
			near(r1.interceptAt, lastFire + FLIGHT.InterceptorSeconds, 1e-9),
			"engage: intercept = last shot + travel"
		)
		check(r1.interceptAt >= 2 - 1e-9 and r1.interceptAt <= 6 + 1e-9, "engage: intercept inside window")
	end
	-- Busy tower: the first shot waits for it.
	local busy = engageOnce(5, 2, 6, aa, 0, 3)
	check(busy.shots == 0 or busy.firstShotAt >= 3, "engage: waits for the tower")
	-- Hostile inputs.
	local none = FlightMath.engage({
		windowFrom = nan,
		windowTo = 5,
		reload = 1,
		chance = 1,
		armor = 0,
		towerFreeAt = 0,
		rng = AttackRng.new(1),
	})
	check(not none.intercepted and none.shots == 0, "engage: NaN window → no shot")
	local sure = FlightMath.engage({
		windowFrom = 2,
		windowTo = 5,
		reload = 1,
		chance = 5,
		armor = -3,
		towerFreeAt = -inf,
		rng = AttackRng.new(1),
	})
	check(sure.intercepted and sure.shots == 1, "engage: chance clamps to 1, armor clamps to 0")
	local armored = FlightMath.engage({
		windowFrom = 2,
		windowTo = 5,
		reload = 1,
		chance = 1,
		armor = 1,
		towerFreeAt = -inf,
		rng = AttackRng.new(1),
	})
	check(not armored.intercepted and armored.shots >= 1, "engage: full armor never intercepted")
	local tiny = FlightMath.engage({
		windowFrom = 0,
		windowTo = 1000,
		reload = 0,
		chance = 0,
		armor = 0,
		towerFreeAt = -inf,
		rng = AttackRng.new(1),
	})
	check(tiny.shots == FLIGHT.MaxShotsPerNuke, "engage: shots bounded by MaxShotsPerNuke")

	-- Probability: seeded trials vs the analytic rate for a fixed shot count.
	for _, case in { { aa = 1, armor = 0 }, { aa = 3, armor = 0.16 }, { aa = 5, armor = 0.32 } } do
		local stats = AttackConfig.AA[case.aa]
		local windowFrom, windowTo = 2.4, 5.6
		local shots = math.min(math.floor((windowTo - windowFrom) / stats.reload) + 1, FLIGHT.MaxShotsPerNuke)
		local p = stats.chance * (1 - case.armor)
		local expected = 1 - (1 - p) ^ shots
		local hits = 0
		local trials = 20000
		for seed = 1, trials do
			if engageOnce(AttackRng.mix(31337, seed), windowFrom, windowTo, stats, case.armor, -inf).intercepted then
				hits += 1
			end
		end
		local rate = hits / trials
		check(near(rate, expected, 0.015), `engage: AA{case.aa} armor {case.armor} rate {rate} ≈ {expected}`)
	end

	-- Saturation: a 20-nuke barrage, 0.2 s apart, same window shape → at most ~window/reload intercepts.
	local stats = AttackConfig.AA[5]
	local freeAt = -inf
	local intercepts, totalShots = 0, 0
	for i = 0, AttackConfig.BarrageSize - 1 do
		local offset = i * AttackConfig.BarrageStagger
		-- Tower time is relative to each nuke's t0: shift the carried free time by the stagger.
		local result = engageOnce(
			AttackRng.mix(1, i),
			2.4,
			5.6,
			stats,
			0,
			freeAt - (if i == 0 then 0 else AttackConfig.BarrageStagger)
		)
		freeAt = result.towerFreeAt
		totalShots += result.shots
		if result.intercepted then
			intercepts += 1
		end
		check(result.shots == 0 or result.firstShotAt >= 0, `barrage nuke {i} fires after launch ({offset})`)
	end
	local span = 5.6 - 2.4 + (AttackConfig.BarrageSize - 1) * AttackConfig.BarrageStagger
	check(totalShots <= math.floor(span / stats.reload) + 1, `barrage: tower fire rate respected ({totalShots} shots)`)
	check(intercepts < AttackConfig.BarrageSize, "barrage: a saturated tower lets nukes through")
end

--------------------------------------------------------------------------------------------------
-- 4. Geometry over every plot pair
--------------------------------------------------------------------------------------------------

local function interceptRate(aaLevel: number, launcherLevel: number, trials: number): number
	local aa = AttackConfig.AA[aaLevel]
	local armor = AttackConfig.Launcher[launcherLevel].armor
	local intercepted, total = 0, 0
	local seed = 0
	for fromPlot = 1, WorldLayout.PlotCount do
		for toPlot = 1, WorldLayout.PlotCount do
			if fromPlot ~= toPlot then
				for impact = 1, AttackGeometry.impactCount() do
					local flight = AttackGeometry.flight(fromPlot, 1, toPlot, impact)
					local from, to = FlightMath.engageWindow(flight, AttackGeometry.muzzle(toPlot), aa.range)
					for _ = 1, trials do
						seed += 1
						total += 1
						if from ~= nil and to ~= nil then
							local result = FlightMath.engage({
								windowFrom = from,
								windowTo = to,
								reload = aa.reload,
								chance = aa.chance,
								armor = armor,
								towerFreeAt = -inf,
								rng = AttackRng.new(AttackRng.mix(2024, seed)),
							})
							if result.intercepted then
								intercepted += 1
							end
						end
					end
				end
			end
		end
	end
	return intercepted / total
end

do
	for fromPlot = 1, WorldLayout.PlotCount do
		for toPlot = 1, WorldLayout.PlotCount do
			if fromPlot ~= toPlot then
				for silo = 1, 3 do
					for impact = 1, AttackGeometry.impactCount() do
						local flight = AttackGeometry.flight(fromPlot, silo, toPlot, impact)
						check(
							flight.duration >= FLIGHT.MinSeconds and flight.duration <= FLIGHT.MaxSeconds,
							"geometry: flight time in bounds"
						)
						check(WorldLayout.plotAt(flight.to) == toPlot, "geometry: impact lands on the target plot")
						for level = 1, AttackConfig.MaxLevel do
							local from, to = FlightMath.engageWindow(
								flight,
								AttackGeometry.muzzle(toPlot),
								AttackConfig.AA[level].range
							)
							check(
								from ~= nil and to ~= nil,
								`geometry: AA{level} of plot {toPlot} engages from plot {fromPlot}`
							)
						end
						-- The defender's tower must never reach the attacker's silo.
						check(
							(AttackGeometry.muzzle(toPlot) - flight.from).Magnitude
								> AttackConfig.AA[AttackConfig.MaxLevel].range,
							"geometry: silo outside the target tower's range"
						)
					end
				end
			end
		end
	end
	check(
		AttackGeometry.validPlot(0) == nil
			and AttackGeometry.validPlot(9) == nil
			and AttackGeometry.validPlot(1.5) == nil,
		"geometry: plot validation"
	)
	local cf, size = AttackGeometry.shield(3)
	check(WorldLayout.plotAt(cf.Position) == 3 and size.Z > WorldLayout.PlotLength, "geometry: shield covers the plot")
	check(WorldLayout.plotAt(AttackGeometry.consolePrompt(2)) == 2, "geometry: console prompt on its plot")
	check(WorldLayout.plotAt(AttackGeometry.towerMount(6).Position) == 6, "geometry: tower on its plot")
end

--------------------------------------------------------------------------------------------------
-- 5. AttackLogic rules
--------------------------------------------------------------------------------------------------

do
	check(
		AttackLogic.effectiveLevel(0, false) == 0 and AttackLogic.effectiveLevel(4, false) == 0,
		"level: no feature → 0"
	)
	check(AttackLogic.effectiveLevel(0, true) == 1 and AttackLogic.effectiveLevel(3, true) == 3, "level: pad = level 1")
	check(
		AttackLogic.effectiveLevel(99, true) == AttackConfig.MaxLevel and AttackLogic.effectiveLevel(nan, true) == 1,
		"level: clamps"
	)
	check(
		AttackLogic.launcherStats(0) == nil and AttackLogic.launcherStats(2) == AttackConfig.Launcher[2],
		"launcherStats"
	)
	check(AttackLogic.aaStats(nan) == nil and AttackLogic.aaStats(5) == AttackConfig.AA[5], "aaStats")

	check(AttackLogic.upgradeCost(1, 100) == 100 * AttackConfig.CostMultiplier[2], "upgradeCost L1→2")
	check(AttackLogic.upgradeCost(AttackConfig.MaxLevel, 100) == inf, "upgradeCost at max")
	check(
		AttackLogic.upgradeCost(0, 100) == inf
			and AttackLogic.upgradeCost(2, nan) == inf
			and AttackLogic.upgradeCost(2, -1) == inf,
		"upgradeCost hostile"
	)
	local last = 0
	for level = 1, AttackConfig.MaxLevel - 1 do
		local cost = AttackLogic.upgradeCost(level, 1e14)
		check(cost > last, "upgradeCost rises")
		last = cost
	end
	-- Owner rule: no purchase ever lowers a number the player sees (every level only improves).
	for level = 2, AttackConfig.MaxLevel do
		local a, b = AttackConfig.Launcher[level - 1], AttackConfig.Launcher[level]
		check(
			b.cooldown <= a.cooldown and b.rewardSeconds >= a.rewardSeconds and b.armor >= a.armor and b.tier > a.tier,
			`launcher L{level} improves`
		)
		local x, y = AttackConfig.AA[level - 1], AttackConfig.AA[level]
		check(y.range >= x.range and y.reload <= x.reload and y.chance >= x.chance, `AA L{level} improves`)
	end
	-- Side-mode balance: reward per cooldown second stays below the attacker's own income.
	for level = 1, AttackConfig.MaxLevel do
		local l = AttackConfig.Launcher[level]
		check(l.rewardSeconds / l.cooldown < 1, `launcher L{level} reward rate < income`)
	end

	-- Rewards: band, kinds, pass, hostile.
	local r = AttackConfig.Launcher[1].rewardSeconds
	check(AttackLogic.reward("normal", 1, 100, 100, false) == r * 100, "reward: equal incomes")
	check(
		AttackLogic.reward("normal", 1, 1e9, 100, false) == r * 100 * AttackConfig.Reward.MaxRatio,
		"reward: capped by attacker income"
	)
	check(
		AttackLogic.reward("normal", 1, 0, 100, false) == r * 100 * AttackConfig.Reward.MinRatio,
		"reward: floored by attacker income"
	)
	check(
		AttackLogic.reward("normal", 1, 100, 100, true) == r * 100 * AttackConfig.Reward.MegaLauncherMultiplier,
		"reward: Mega Launcher"
	)
	check(
		AttackLogic.reward("barrage", 1, 100, 100, false) == r * 100 * AttackConfig.Reward.Factor.barrage,
		"reward: barrage factor"
	)
	check(AttackLogic.reward("normal", 0, 100, 100, false) == 0, "reward: no launcher → 0")
	check(AttackLogic.reward("normal", 1, nan, inf, false) == 0, "reward: hostile → 0")
	check(AttackLogic.reward("bogus" :: any, 1, 100, 100, false) == 0, "reward: unknown kind → 0")
	for level = 1, AttackConfig.MaxLevel do
		for _, kind in AttackLogic.Kinds do
			local amount = AttackLogic.reward(kind, level, 1e30, 1e12, true)
			local bound = AttackConfig.Launcher[level].rewardSeconds
				* 1e12
				* AttackConfig.Reward.MaxRatio
				* AttackConfig.Reward.Factor[kind]
				* AttackConfig.Reward.MegaLauncherMultiplier
			check(amount >= 0 and amount <= bound * (1 + 1e-12), `reward: bounded L{level} {kind}`)
		end
	end

	-- Eligibility.
	local now = 1000
	local function actor(overrides: { [string]: any }?): any
		local a: { [string]: any } = {
			userId = 1,
			loaded = true,
			plot = 1,
			area = 7,
			console = true,
			launcher = 1,
			cooldownUntil = 0,
			shieldUntil = 0,
			barrage = 0,
		}
		for key, value in overrides or {} do
			a[key] = value
		end
		return a
	end
	local me = actor()
	local them = actor({ userId = 2, plot = 2, console = false, launcher = 0 })
	local function can(attacker: any, target: any, kind: string, revenge: boolean?): (boolean, string?)
		return AttackLogic.canLaunch(attacker, target, kind, now, revenge == true)
	end
	check(can(me, them, "normal") == true, "can: normal launch")
	check(select(2, can(me, me, "normal")) == "target", "can: not self")
	check(select(2, can(me, nil, "normal")) == "target", "can: missing target")
	check(select(2, can(me, actor({ userId = 2, plot = 0 }), "normal")) == "target", "can: target without plot")
	check(
		select(2, can(me, actor({ userId = 2, plot = 2, loaded = false }), "normal")) == "target",
		"can: target not loaded"
	)
	-- Owner R85: only brand-new players are protected (no area gate any more).
	check(
		select(2, can(me, actor({ userId = 2, plot = 2, newbie = true }), "normal")) == "protected",
		"can: new players protected"
	)
	check(can(me, actor({ userId = 2, plot = 2, area = 1 }), "normal") == true, "can: area 1 players targetable (R85)")
	-- No AFK protection (owner R43 "AFK nuke system"): an away player is a valid target, and the
	-- Actor has no AFK flag at all any more.
	check(can(me, actor({ userId = 2, plot = 2, afk = true }), "normal") == true, "can: AFK players targetable")
	check(
		select(2, can(me, actor({ userId = 2, plot = 2, shieldUntil = now + 1 }), "normal")) == "shield",
		"can: shield"
	)
	check(can(me, actor({ userId = 2, plot = 2, shieldUntil = now }), "normal") == true, "can: expired shield")
	check(select(2, can(actor({ cooldownUntil = now + 5 }), them, "normal")) == "cooldown", "can: cooldown")
	check(can(actor({ console = false }), them, "normal") == true, "can: no console needed (R85 starter launcher)")
	check(select(2, can(actor({ launcher = 0 }), them, "normal")) == "locked", "can: needs launcher level")
	check(select(2, can(actor({ plot = 0 }), them, "normal")) == "locked", "can: attacker without plot")
	check(select(2, can(me, them, "barrage")) == "empty", "can: barrage needs stored nukes")
	check(
		can(actor({ barrage = 20, cooldownUntil = now + 99 }), them, "barrage") == true,
		"can: barrage ignores cooldown"
	)
	check(
		select(2, can(actor({ barrage = 20 }), actor({ userId = 2, plot = 2, shieldUntil = now + 9 }), "barrage"))
			== "shield",
		"can: barrage blocked by shield"
	)
	check(select(2, can(me, them, "revenge")) == "target", "can: revenge needs a token")
	check(
		can(
			actor({ console = false, launcher = 0, cooldownUntil = now + 99 }),
			actor({ userId = 2, plot = 2, shieldUntil = now + 99 }),
			"revenge",
			true
		) == true,
		"can: revenge ignores console, cooldown, shield"
	)
	check(
		select(2, can(me, actor({ userId = 2, plot = 0 }), "revenge", true)) == "target",
		"can: revenge target must still have a plot"
	)
	check(select(2, can(me, them, "bogus")) == "locked", "can: unknown kind refused")
	-- Owner R85 golden revenge nuke: a stored charge, no cooldown, blocked by shields / protection.
	check(select(2, can(me, them, "golden")) == "empty", "can: golden needs a stored charge")
	check(can(actor({ golden = 1, cooldownUntil = now + 99 }), them, "golden") == true, "can: golden ignores cooldown")
	check(
		select(2, can(actor({ golden = 1 }), actor({ userId = 2, plot = 2, shieldUntil = now + 9 }), "golden")) == "shield",
		"can: golden blocked by shield"
	)
	check(
		select(2, can(actor({ golden = 1 }), actor({ userId = 2, plot = 2, newbie = true }), "golden")) == "protected",
		"can: golden respects new-player protection (the server lifts it for the one who hit you)"
	)
	-- Owner R85 starter launcher: L1 for everyone, the Console gives ConsoleLauncher at least.
	check(AttackLogic.launcherLevel(0, false) == AttackConfig.StarterLauncher, "launcherLevel: starter")
	check(AttackLogic.launcherLevel(5, false) == AttackConfig.StarterLauncher, "launcherLevel: upgrades need the Console")
	check(AttackLogic.launcherLevel(1, true) == AttackConfig.ConsoleLauncher, "launcherLevel: Console gives L2")
	check(AttackLogic.launcherLevel(4, true) == 4, "launcherLevel: stored upgrades count")
	check(AttackLogic.launcherLevel(nan, true) == AttackConfig.ConsoleLauncher, "launcherLevel: hostile")
	for lvl = 1, AttackConfig.MaxLevel do
		local armor = AttackLogic.goldenArmor(lvl)
		check(
			armor > AttackConfig.Launcher[lvl].armor - 1e-9 and armor <= AttackConfig.Golden.MaxArmor + 1e-9,
			`goldenArmor L{lvl}: extra armor, capped`
		)
	end
	check(AttackConfig.Reward.Factor.golden == AttackConfig.Reward.Factor.revenge, "golden pays the revenge factor")
	check(AttackLogic.isTargetable(actor({ userId = 3, plot = 3 })) == true, "isTargetable")

	-- Shields, cooldown, reasons, silos.
	check(AttackLogic.addShield(0, now, 600) == now + 600, "addShield from none")
	check(AttackLogic.addShield(now + 100, now, 600) == now + 700, "addShield stacks")
	check(AttackLogic.addShield(nan, now, nan) == now, "addShield hostile")
	check(AttackLogic.shieldActive(now + 1, now) and not AttackLogic.shieldActive(now, now), "shieldActive")
	check(
		AttackLogic.freeShieldReady(AttackConfig.FreeShieldHits)
			and not AttackLogic.freeShieldReady(AttackConfig.FreeShieldHits - 1),
		"freeShieldReady"
	)
	check(
		AttackLogic.cooldownAfter(now + 0.4, 1) == math.ceil(now + 0.4 + AttackConfig.Launcher[1].cooldown),
		"cooldownAfter"
	)
	check(
		AttackLogic.analyticsReason("empty") == "other" and AttackLogic.analyticsReason("shield") == "shield",
		"analyticsReason"
	)
	check(type(AttackLogic.reasonText("cooldown")) == "string" and AttackLogic.reasonText(nil) ~= "", "reasonText")
	local silos = AttackLogic.silos({ a7_silo_pad = true, a7_silo_3 = true })
	check(#silos == 2 and silos[1] == 1 and silos[2] == 3, "silos: owned pads")
	check(#AttackLogic.silos(nil) == 1, "silos: always silo 1")
end

--------------------------------------------------------------------------------------------------
-- 6. Tuning targets
--------------------------------------------------------------------------------------------------

do
	local trials = 6
	local table6: { [number]: { [number]: number } } = {}
	for aa = 1, AttackConfig.MaxLevel do
		table6[aa] = {}
		for launcher = 1, AttackConfig.MaxLevel do
			table6[aa][launcher] = interceptRate(aa, launcher, trials)
		end
	end
	if process.env.ATTACK_REPORT == "1" then
		print("Single-nuke intercept rate (rows AA level, columns Launcher level):")
		for aa = 1, AttackConfig.MaxLevel do
			local row = {}
			for launcher = 1, AttackConfig.MaxLevel do
				table.insert(row, string.format("%5.1f%%", table6[aa][launcher] * 100))
			end
			print(`  AA{aa}: {table.concat(row, "  ")}`)
		end
	end
	check(table6[1][1] >= 0.2 and table6[1][1] <= 0.4, `tuning: AA1 vs L1 ≈ 20-40 % (got {table6[1][1]})`)
	check(table6[5][1] >= 0.6 and table6[5][1] <= 0.85, `tuning: AA5 vs L1 ≈ 60-85 % (got {table6[5][1]})`)
	check(table6[5][5] < table6[5][1], "tuning: armor lowers the rate")
	for aa = 2, AttackConfig.MaxLevel do
		check(table6[aa][1] > table6[aa - 1][1], `tuning: AA{aa} beats AA{aa - 1}`)
	end
end

--------------------------------------------------------------------------------------------------
-- 7. Server helpers
--------------------------------------------------------------------------------------------------

do
	local queue = TimeQueue.new()
	check(queue:count() == 0 and queue:peekTime() == inf and queue:pop() == nil, "queue: empty")
	local rng = AttackRng.new(5150)
	local pushed = 0
	for i = 1, 500 do
		queue:push(math.floor(rng:next() * 100) / 4, i)
		pushed += 1
	end
	local last = -inf
	local popped = 0
	while queue:count() > 0 do
		local time, item = queue:pop()
		check(time ~= nil and item ~= nil and time >= last, "queue: non-decreasing pops")
		last = time :: number
		popped += 1
		-- Interleave: occasionally push something later than the current head.
		if popped % 50 == 0 and pushed < 600 then
			queue:push(last + 1, -popped)
			pushed += 1
		end
	end
	check(popped == pushed, `queue: every item popped once ({popped}/{pushed})`)

	local profile: any = { attack = { aa = 2, launcher = 1, shieldUntil = 10, cooldownUntil = 5, hitsTaken = 1 } }
	check(AttackProfile.barrage(profile) == 0, "profile: missing barrage reads 0")
	AttackProfile.setBarrage(profile, 25.7)
	check(profile.attack.barrage == 25, "profile: barrage whole")
	AttackProfile.setBarrage(profile, 1e12)
	check(profile.attack.barrage == AttackConfig.BarrageStorageLimit, "profile: barrage capped at the storage bound")
	AttackProfile.setBarrage(profile, -4)
	check(profile.attack.barrage == 0, "profile: barrage floored at 0")
	AttackProfile.setBarrage(profile, nan)
	check(profile.attack.barrage == 0, "profile: barrage NaN → 0")
	check(AttackProfile.get(profile, "aa") == 2 and AttackProfile.get(profile, "nope") == 0, "profile: get")
	AttackProfile.set(profile, "hitsTaken", -3)
	check(profile.attack.hitsTaken == 0, "profile: set clamps to >= 0")
	check(AttackProfile.barrage(nil) == 0 and AttackProfile.of({}) == nil, "profile: malformed profile")
	AttackProfile.setBarrage({}, 5) -- no attack table: no error
end

print(`[attack-logic] {checks} checks passed`)
