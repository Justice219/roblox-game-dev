--!strict
--[[
	FlightMath — the pure, deterministic flight + interception maths of Attack mode (spec §9:
	"nukes are physics-free server-timed arcs; the server decides hit/miss and timing; clients only
	render the arc").

	The model
		A nuke flies from a launch point A (attacker's silo) to an impact point B (target plot) in
		`duration` seconds along a parabola lifted `apex` studs above the straight line:
			s    = t / duration                                    (0..1, linear in time)
			p(t) = A + (B - A) * s + up * 4 * apex * s * (1 - s)
		Both the server (to decide interceptions) and every client (to draw the arc, the trail and
		the interceptor) evaluate the SAME function, so what players see is exactly what the
		server decided. No physics, no network traffic during the flight.

		A defending AA tower (muzzle M, level stats range / reload / chance) can intercept while the
		nuke is within `range` of M: `rangeWindow` finds that time window (the in-range run closest
		to impact, sampled then refined by bisection). `engage` then schedules interceptor shots:
		an interceptor fired at time f meets the nuke at f + InterceptorSeconds, the meeting time
		must lie inside the window and at least ImpactMargin before impact, the tower fires at most
		once per `reload` seconds (the tower's next free time carries over between nukes, so a
		20-nuke Barrage can saturate a tower), and every shot succeeds with chance
		`chance * (1 - armor)` drawn from the seeded AttackRng. First success = intercepted.
		Owner R80: a plot defends with EVERY tower it owns — `engageMany` merges all towers' shots
		in fire-time order on the same rng (one tower = exactly `engage`).

	Times: everything here is RELATIVE to the flight's t0 (seconds after launch); the services
	convert to server time (Workspace:GetServerTimeNow()).

	Pure: Vector3 maths only; no Instances, no services, no globals beyond the datatypes. Tested
	by tests/attack-logic.luau under Lune.

	Connects to: Shared/Config/AttackConfig (Flight), Shared/Attack/AttackRng, Shared/Attack/
	AttackGeometry (world points), Server/Services/{AttackService, DefenseService},
	Client/Attack/FlightRenderer.

	Example:
		local flight = FlightMath.build(launchPos, impactPos)
		local pos = FlightMath.position(flight, 2.5)
		local from, to = FlightMath.rangeWindow(flight, muzzle, 200)
		local result = FlightMath.engage({ windowFrom = from, windowTo = to, ... })
]]

local AttackConfig = require(script.Parent.Parent.Config.AttackConfig)
local AttackRng = require(script.Parent.AttackRng)

local FlightMath = {}

local FLIGHT = AttackConfig.Flight
local UP = Vector3.new(0, 1, 0)

export type Flight = {
	from: Vector3, -- launch point (world)
	to: Vector3, -- impact point (world)
	duration: number, -- seconds from t0 to impact
	apex: number, -- studs the arc rises above the straight line at mid-flight
}

export type EngageInput = {
	windowFrom: number, -- earliest meeting time (relative), from rangeWindow
	windowTo: number, -- latest meeting time (relative), already clipped by the impact margin
	reload: number, -- seconds between two shots of the tower
	chance: number, -- 0..1 per-shot intercept chance before armor
	armor: number, -- 0..1 nuke armor (launcher level): effective chance = chance * (1 - armor)
	towerFreeAt: number, -- relative time the tower may fire next (negative = already free)
	rng: AttackRng.Rng,
}

export type EngageResult = {
	intercepted: boolean,
	interceptAt: number, -- relative meeting time (0 when not intercepted)
	firstShotAt: number, -- relative fire time of the first interceptor (0 when no shot)
	shots: number, -- interceptors fired at this nuke, `reload` apart (clients draw every one; the
	-- last one is the hit when intercepted)
	towerFreeAt: number, -- relative time the tower may fire again after this nuke
}

-- A finite number, else `fallback`.
local function finite(value: number, fallback: number): number
	if value ~= value or value == math.huge or value == -math.huge then
		return fallback
	end
	return value
end

--[[
	Flight time for a launch→impact distance: clamp(Base + d / StudsPerSecond, Min, Max).
	@param distance number — studs (horizontal + vertical straight-line distance)
	@return number — seconds
	Example: FlightMath.duration(500) --> ~6.03
]]
function FlightMath.duration(distance: number): number
	local d = math.max(finite(distance, 0), 0)
	return math.clamp(FLIGHT.BaseSeconds + d / FLIGHT.StudsPerSecond, FLIGHT.MinSeconds, FLIGHT.MaxSeconds)
end

--[[
	Arc apex height above the straight line for a distance: clamp(d * ApexPerStud, ApexMin, ApexMax).
	@param distance number — studs
	@return number — studs
]]
function FlightMath.apex(distance: number): number
	local d = math.max(finite(distance, 0), 0)
	return math.clamp(d * FLIGHT.ApexPerStud, FLIGHT.ApexMin, FLIGHT.ApexMax)
end

--[[
	Builds the flight between two world points (duration and apex from their distance).
	@param from Vector3 — launch point
	@param to Vector3 — impact point
	@param duration number? — override (e.g. the server-published value on the client)
	@return Flight
	Example: local flight = FlightMath.build(silo, impact)
]]
function FlightMath.build(from: Vector3, to: Vector3, duration: number?): Flight
	local distance = (to - from).Magnitude
	local seconds = if duration ~= nil
			and duration == duration
			and duration > 0
		then math.clamp(duration, FLIGHT.MinSeconds * 0.5, FLIGHT.MaxSeconds * 2)
		else FlightMath.duration(distance)
	return { from = from, to = to, duration = seconds, apex = FlightMath.apex(distance) }
end

--[[
	Position of the nuke at relative time t (clamped to [0, duration]).
	@param flight Flight
	@param t number — seconds after t0
	@return Vector3 — world position
]]
function FlightMath.position(flight: Flight, t: number): Vector3
	local s = math.clamp(finite(t, 0) / flight.duration, 0, 1)
	return flight.from:Lerp(flight.to, s) + UP * (4 * flight.apex * s * (1 - s))
end

--[[
	Velocity (studs/s) at relative time t — the tangent clients orient the nuke along.
	@param flight Flight
	@param t number — seconds after t0
	@return Vector3
]]
function FlightMath.velocity(flight: Flight, t: number): Vector3
	local s = math.clamp(finite(t, 0) / flight.duration, 0, 1)
	local along = (flight.to - flight.from) / flight.duration
	return along + UP * (4 * flight.apex * (1 - 2 * s) / flight.duration)
end

-- True when the nuke is within `range` of `muzzle` at relative time t.
local function inRange(flight: Flight, muzzle: Vector3, range: number, t: number): boolean
	return (FlightMath.position(flight, t) - muzzle).Magnitude <= range
end

-- Bisection: the boundary time between `outside` (not in range) and `inside` (in range).
local function refine(flight: Flight, muzzle: Vector3, range: number, outside: number, inside: number): number
	local a, b = outside, inside
	for _ = 1, FLIGHT.RangeRefineSteps do
		local mid = (a + b) * 0.5
		if inRange(flight, muzzle, range, mid) then
			b = mid
		else
			a = mid
		end
	end
	return b
end

--[[
	The time window (relative) during which the nuke is within `range` of `muzzle`. When the flight
	enters range more than once, the run CLOSEST TO IMPACT is used (the descent onto the target is
	what a defending tower engages). Boundaries are sampled (RangeSamples) then bisected.
	@param flight Flight
	@param muzzle Vector3 — the tower's muzzle (world)
	@param range number — studs
	@return (number?, number?) — (enter, exit) seconds after t0, or nil when never in range
	Example: local from, to = FlightMath.rangeWindow(flight, muzzle, 200)
]]
function FlightMath.rangeWindow(flight: Flight, muzzle: Vector3, range: number): (number?, number?)
	local r = finite(range, 0)
	if r <= 0 then
		return nil, nil
	end
	local samples = FLIGHT.RangeSamples
	local step = flight.duration / samples
	-- Walk backwards from impact to find the last in-range run.
	local runEnd: number? = nil
	local index = samples
	while index >= 0 do
		if inRange(flight, muzzle, r, index * step) then
			runEnd = index
			break
		end
		index -= 1
	end
	if runEnd == nil then
		return nil, nil
	end
	local runStart = runEnd
	while runStart > 0 and inRange(flight, muzzle, r, (runStart - 1) * step) do
		runStart -= 1
	end
	local enter = if runStart == 0 then 0 else refine(flight, muzzle, r, (runStart - 1) * step, runStart * step)
	local exit = if runEnd == samples
		then flight.duration
		else refine(flight, muzzle, r, (runEnd + 1) * step, runEnd * step)
	return enter, exit
end

--[[
	The meeting-time window a tower can use against a flight: rangeWindow clipped so every meeting
	is at least ImpactMargin before impact and after the interceptor could have left the muzzle.
	@return (number?, number?) — nil when the tower cannot engage this flight at all
]]
function FlightMath.engageWindow(flight: Flight, muzzle: Vector3, range: number): (number?, number?)
	local enter, exit = FlightMath.rangeWindow(flight, muzzle, range)
	if enter == nil or exit == nil then
		return nil, nil
	end
	local from = math.max(enter, FLIGHT.InterceptorSeconds)
	local to = math.min(exit, flight.duration - FLIGHT.ImpactMargin)
	if to < from then
		return nil, nil
	end
	return from, to
end

--[[
	One tower of a multi-tower engagement (engageMany): its meeting window against this flight
	(engageWindow), its level stats and its next free fire time — all RELATIVE to t0.
]]
export type TowerWindow = {
	windowFrom: number, -- earliest meeting time (relative)
	windowTo: number, -- latest meeting time (relative), already clipped by the impact margin
	reload: number, -- seconds between two shots of this tower
	chance: number, -- 0..1 per-shot intercept chance before armor
	towerFreeAt: number, -- relative time this tower may fire next (negative = already free)
}

-- What one tower did against one nuke (engageMany), in input order.
export type TowerVolley = {
	shots: number, -- interceptors this tower fired, `reload` apart
	firstShotAt: number, -- relative fire time of its first interceptor (0 when no shot)
	towerFreeAt: number, -- relative time it may fire again (unchanged input value when no shot)
}

export type ManyResult = {
	intercepted: boolean,
	interceptAt: number, -- relative meeting time of the hit (0 when not intercepted)
	hitIndex: number, -- input index of the tower whose shot hit (0 = none)
	shots: number, -- interceptors fired by every tower together
	volleys: { TowerVolley }, -- one per input tower, same order
}

--[[
	Every defending tower against ONE nuke (owner R80: a plot defends with all of its AA towers,
	each from its own muzzle on its own fire schedule). The shots of all towers are merged in FIRE
	TIME order (ties: the lower input index first) and rolled one by one on the shared seeded rng;
	the first success intercepts the nuke and every tower stops (interceptors fly a constant
	InterceptorSeconds, so fire order == meeting order and no later shot is ever wasted). Each
	tower keeps the single-tower rules: first shot as soon as it is free AND its meeting point is
	inside its window, then every `reload` seconds, at most MaxShotsPerNuke shots per nuke; its
	towerFreeAt carries over to the next nuke, so a Barrage still saturates every tower.
	With ONE tower this is exactly the classic engage (same shots, same rng draws).
	Deterministic for the same input + rng state. Never errors on hostile numbers (NaN → no shot).
	@param towers { TowerWindow }
	@param armor number — 0..1 nuke armor: every tower's chance is multiplied by (1 - armor)
	@param rng AttackRng.Rng
	@return ManyResult
	Example:
		local r = FlightMath.engageMany({
			{ windowFrom = 3, windowTo = 5.5, reload = 1.5, chance = 0.22, towerFreeAt = -1 },
			{ windowFrom = 2, windowTo = 6, reload = 0.75, chance = 0.34, towerFreeAt = -1 },
		}, 0.08, AttackRng.new(42))
]]
function FlightMath.engageMany(towers: { TowerWindow }, armor: number, rng: AttackRng.Rng): ManyResult
	local travel = FLIGHT.InterceptorSeconds
	local maxShots = FLIGHT.MaxShotsPerNuke
	local keep = 1 - math.clamp(finite(armor, 0), 0, 1)
	local result: ManyResult = {
		intercepted = false,
		interceptAt = 0,
		hitIndex = 0,
		shots = 0,
		volleys = {},
	}
	-- Per tower: its next fire time, latest meeting time, reload, effective chance, live flag.
	local nextFire: { number } = {}
	local lastMeet: { number } = {}
	local reloads: { number } = {}
	local chances: { number } = {}
	local live: { boolean } = {}
	for index, tower in towers do
		local from = finite(tower.windowFrom, math.huge)
		local to = finite(tower.windowTo, -math.huge)
		local reload = math.max(finite(tower.reload, math.huge), 0.05)
		local freeAt = finite(tower.towerFreeAt, -math.huge)
		result.volleys[index] = { shots = 0, firstShotAt = 0, towerFreeAt = freeAt }
		-- First shot: as soon as the tower is free AND the meeting point is inside the window.
		local fire = math.max(freeAt, from - travel, 0)
		nextFire[index] = fire
		lastMeet[index] = to
		reloads[index] = reload
		chances[index] = math.clamp(finite(tower.chance, 0), 0, 1) * keep
		live[index] = from <= to and reload ~= math.huge and fire + travel <= to
	end
	while true do
		-- The live tower that fires next (strict <, so ties go to the lower index).
		local pick = 0
		local pickAt = math.huge
		for index = 1, #towers do
			if live[index] and nextFire[index] < pickAt then
				pick, pickAt = index, nextFire[index]
			end
		end
		if pick == 0 then
			break
		end
		local volley = result.volleys[pick]
		if volley.shots == 0 then
			volley.firstShotAt = pickAt
		end
		volley.shots += 1
		volley.towerFreeAt = pickAt + reloads[pick]
		result.shots += 1
		if rng:next() < chances[pick] then
			result.intercepted = true
			result.interceptAt = pickAt + travel
			result.hitIndex = pick
			break
		end
		local fire = pickAt + reloads[pick]
		nextFire[pick] = fire
		live[pick] = fire + travel <= lastMeet[pick] and volley.shots < maxShots
	end
	return result
end

--[[
	Schedules ONE tower's interceptor shots at one nuke and rolls them (see the header): the
	single-tower case of engageMany (identical shots and rng draws), kept for rival / bot towers
	and tests.
	Deterministic for the same input + rng state. Never errors on hostile numbers (NaN → no shot).
	@param input EngageInput
	@return EngageResult
	Example:
		local r = FlightMath.engage({ windowFrom = 3, windowTo = 5.5, reload = 1.6, chance = 0.24,
			armor = 0, towerFreeAt = -1, rng = AttackRng.new(42) })
]]
function FlightMath.engage(input: EngageInput): EngageResult
	local many = FlightMath.engageMany({
		{
			windowFrom = input.windowFrom,
			windowTo = input.windowTo,
			reload = input.reload,
			chance = input.chance,
			towerFreeAt = input.towerFreeAt,
		},
	}, input.armor, input.rng)
	local volley = many.volleys[1]
	return {
		intercepted = many.intercepted,
		interceptAt = many.interceptAt,
		firstShotAt = volley.firstShotAt,
		shots = volley.shots,
		towerFreeAt = volley.towerFreeAt,
	}
end

--[[
	The fire time of interceptor `n` (1-based) of an engagement, for clients drawing every shot
	(misses fly past and pop; the last shot of an intercepted flight is the hit).
	@param firstShotAt number — relative fire time of shot 1 (EngageResult.firstShotAt)
	@param n number — shot index, 1..shots
	@param reload number — seconds between shots (the defender's AA level at launch)
	@return number — relative fire time
	Example: FlightMath.shotTime(3.1, 2, 1.6) --> 4.7
]]
function FlightMath.shotTime(firstShotAt: number, n: number, reload: number): number
	return firstShotAt + (n - 1) * reload
end

return FlightMath
