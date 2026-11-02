--!strict
--[[
	RouteMath — the pure maths behind the map vehicles (owner R56: "the delivery truck should drive
	in and out, semi-truck should drive in and out"). No services, no instances: unit-tested by
	tests/vehicle-routes.luau and used by Client/Tycoon/Fx/VehicleRoutes every frame.

	Pieces:
		* PATHS — centripetal Catmull-Rom splines through authored knots (slot-local studs), with an
		  arc-length table so `pathPoint(path, s)` moves at a true studs-per-second speed. Open paths
		  extrapolate straight past both ends (a trailing cart behind the first knot); closed paths
		  wrap (the scooter lane loop). Each table sample also stores the heading turn rate and the
		  indicator side for the turn coming up.
		* PROFILES — trapezoid speed profiles per drive leg (accelerate from v0, cruise, brake to v1).
		* TIMELINES — a route (VehicleRouteConfig.Route) compiled once into timed segments (drive legs
		  and waits), cargo load / unload events, honks, reverse beeps, tips, signals and gate windows.
		  `sample(timeline, t, gap, out)` is a pure function of the clock: a vehicle can be culled,
		  skip frames or jump and still lands exactly where it should. `gap` places a follower (the
		  second mine cart) that many studs behind the leader along the same path.

	Flyers (owner R57 D3 ptero couriers): paths are 3D, so a sample also reports the climb angle of
	its heading (`climb`, + = nose up) and whether the wings are working (`flying`: drive legs and
	`hover` waits). A wait may `spin` the model on the spot (eased); every later wait until the next
	drive keeps the turned heading (`yaw0`). A route with `period` stretches its one `stretch` wait
	so the loop lasts exactly that long (`periodOk` = false when the legs alone are longer).

	Conventions (Roblox): yaw 0 faces -Z, positive yaw turns CCW seen from above (front toward -X).
	A reverse leg moves along its path while the vehicle FACES the other way. Odometer = signed
	studs driven along the vehicle's own front (reverse legs count down) -> wheel spin.

	Example:
		local timeline = RouteMath.compile(VehicleRouteConfig.Routes[1])
		local out = RouteMath.newSample()
		RouteMath.sample(timeline, 12.5, 0, out)
		part.CFrame = slotCFrame * RouteMath.localFrame(out.position, out.yaw)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VehicleRouteConfig = require(ReplicatedStorage.Shared.Config.VehicleRouteConfig)

local RouteMath = {}

-- Centripetal Catmull-Rom (0.5): no cusps or self-loops on unevenly spaced knots.
local ALPHA = 0.5
-- Arc-length table resolution (samples per spline segment).
local SAMPLES = 16
-- Indicator look-ahead (studs) and the heading change (radians) that counts as a turn.
local SIGNAL_AHEAD = 10
local SIGNAL_TURN = math.rad(25)

export type Path = {
	points: { Vector3 },
	closed: boolean,
	length: number,
	segments: number,
	-- Per spline segment: p(u) = a + b u + c u^2 + d u^3, u in [0, 1].
	ca: { Vector3 },
	cb: { Vector3 },
	cc: { Vector3 },
	cd: { Vector3 },
	-- Arc-length table: cumulative studs and the global spline parameter g in [0, segments].
	tableS: { number },
	tableG: { number },
	-- Per table sample: heading turn rate (rad / stud, + = left) and indicator side (1 L, -1 R, 0).
	turn: { number },
	signal: { number },
	startTangent: Vector3,
	endTangent: Vector3,
}

export type Profile = {
	length: number,
	v0: number,
	v1: number,
	vpeak: number,
	accel: number,
	decel: number,
	t1: number,
	t2: number,
	s1: number,
	s2: number,
	duration: number,
	feasible: boolean, -- false when the leg is too short to reach v0 / v1 (config error)
}

export type Seg = {
	kind: string, -- "drive" | "wait"
	t0: number,
	t1: number,
	odo0: number, -- odometer at the segment start
	-- drive
	path: Path?,
	profile: Profile?,
	gear: number, -- 1 forward, -1 reverse (wait: the anchor's gear)
	fadeIn: number,
	fadeOut: number,
	-- wait: index of the drive leg whose END pose the vehicle holds
	anchor: number,
	hover: boolean, -- wait: a flyer keeps flapping
	spin: number, -- wait: radians turned on the spot over the wait (eased)
	yaw0: number, -- wait: radians already turned (earlier spins since the anchor leg)
}

export type Event = { t: number, kind: string, group: number?, chance: number?, pitch: number? }
export type CargoEvent = { t: number, loaded: boolean }
export type Window = { t0: number, t1: number, value: number }

-- One driven model of a route: the leader (index 1) or a follower sharing its clock.
export type Instance = {
	offset: number, -- seconds added to the shared clock (sync = "nearest" followers)
	gap: number, -- studs behind the leader along the path (gap followers)
	yaw: number?, -- orient = "fixed": this instance keeps its rest yaw (conveyor items)
}

export type Timeline = {
	id: string,
	period: number,
	segs: { Seg },
	start: number,
	netOdo: number,
	events: { Event },
	cargo: { { CargoEvent } },
	tips: { Window }, -- value = angle (degrees)
	signals: { Window }, -- value = side (1 L, -1 R)
	gates: { Window }, -- value unused (1)
	instances: { Instance },
	brakeHold: number,
	periodOk: boolean, -- false when route.period is shorter than the legs need (config error)
}

-- Reused per-frame output of `sample` (no allocations per frame).
export type Sample = {
	position: Vector3,
	yaw: number,
	speed: number,
	accel: number,
	gear: number,
	alpha: number, -- 1 visible .. 0 faded out (off-plot / inside the tunnel)
	odo: number,
	turn: number,
	signal: number,
	brake: boolean,
	seg: number,
	climb: number, -- radians: the heading's climb (+ = nose up), 0 while waiting
	flying: boolean, -- drive legs and hover waits (a flyer's wings work)
}

--------------------------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------------------------

--[[
	Yaw (radians, Roblox convention) of a vehicle FACING `direction`; Y is ignored.
	Example: RouteMath.yawOf(Vector3.new(-1, 0, 0)) --> math.pi / 2 (front toward -X)
]]
function RouteMath.yawOf(direction: Vector3): number
	return math.atan2(-direction.X, -direction.Z)
end

--[[
	Slot-local CFrame of a pose (yaw only: vehicles stay level).
	Example: slotCFrame * RouteMath.localFrame(Vector3.new(39.45, 0.56, 29.4), 0)
]]
function RouteMath.localFrame(position: Vector3, yaw: number): CFrame
	return CFrame.new(position) * CFrame.Angles(0, yaw, 0)
end

-- Wraps an angle into (-pi, pi].
local function wrapAngle(angle: number): number
	return (angle + math.pi) % (2 * math.pi) - math.pi
end

--[[
	Ease-out bounce (0 -> 1, two small bounces at the end) for cargo landing in its spot.
	Example: RouteMath.bounce(1) --> 1
]]
function RouteMath.bounce(u: number): number
	u = math.clamp(u, 0, 1)
	local n, d = 7.5625, 2.75
	if u < 1 / d then
		return n * u * u
	elseif u < 2 / d then
		u -= 1.5 / d
		return n * u * u + 0.75
	elseif u < 2.5 / d then
		u -= 2.25 / d
		return n * u * u + 0.9375
	end
	u -= 2.625 / d
	return n * u * u + 0.984375
end

-- Smoothstep 0 -> 1.
local function smooth(u: number): number
	u = math.clamp(u, 0, 1)
	return u * u * (3 - 2 * u)
end
RouteMath.smooth = smooth

--------------------------------------------------------------------------------------------------
-- Paths
--------------------------------------------------------------------------------------------------

-- Distance-based knot spacing for centripetal Catmull-Rom (never 0: duplicate knots are dropped).
local function knot(a: Vector3, b: Vector3): number
	return math.max((b - a).Magnitude ^ ALPHA, 1e-4)
end

--[[
	Builds a spline path through `points` (slot-local, ≥ 2 distinct knots). Open paths use mirrored
	phantom knots at both ends, so the end tangents run along the first / last chord: author a
	straight lead-in to a parking spot and the vehicle arrives exactly on its heading.
	@param points { Vector3 }
	@param closed boolean?  loop back from the last knot to the first (do not repeat the first knot)
	@return Path
	Example: RouteMath.buildPath({ Vector3.new(0, 0, 0), Vector3.new(10, 0, 0) })
]]
function RouteMath.buildPath(points: { Vector3 }, closed: boolean?): Path
	-- Drop consecutive duplicates (and a closing duplicate of the first knot).
	local knots: { Vector3 } = {}
	for _, point in points do
		local last = knots[#knots]
		if last == nil or (point - last).Magnitude > 1e-3 then
			table.insert(knots, point)
		end
	end
	local isClosed = closed == true
	if isClosed and #knots > 2 and (knots[#knots] - knots[1]).Magnitude <= 1e-3 then
		table.remove(knots)
	end
	assert(#knots >= 2, "RouteMath.buildPath: needs at least two distinct points")
	local n = #knots
	local function get(index: number): Vector3
		if isClosed then
			return knots[(index - 1) % n + 1]
		elseif index < 1 then
			return knots[1] * 2 - knots[2]
		elseif index > n then
			return knots[n] * 2 - knots[n - 1]
		end
		return knots[index]
	end
	local segments = if isClosed then n else n - 1
	local ca, cb, cc, cd = {}, {}, {}, {}
	for i = 1, segments do
		local p0, p1, p2, p3 = get(i - 1), get(i), get(i + 1), get(i + 2)
		local dt0, dt1, dt2 = knot(p0, p1), knot(p1, p2), knot(p2, p3)
		local m1 = ((p1 - p0) / dt0 - (p2 - p0) / (dt0 + dt1) + (p2 - p1) / dt1) * dt1
		local m2 = ((p2 - p1) / dt1 - (p3 - p1) / (dt1 + dt2) + (p3 - p2) / dt2) * dt1
		ca[i] = p1
		cb[i] = m1
		cc[i] = p1 * -3 - m1 * 2 + p2 * 3 - m2
		cd[i] = p1 * 2 + m1 - p2 * 2 + m2
	end
	local path: Path = {
		points = knots,
		closed = isClosed,
		length = 0,
		segments = segments,
		ca = ca,
		cb = cb,
		cc = cc,
		cd = cd,
		tableS = {},
		tableG = {},
		turn = {},
		signal = {},
		startTangent = Vector3.zAxis,
		endTangent = Vector3.zAxis,
	}
	-- Arc-length table.
	local previous: Vector3? = nil
	local total = 0
	local headings: { number } = {}
	for i = 1, segments do
		for k = (if i == 1 then 0 else 1), SAMPLES do
			local u = k / SAMPLES
			local a, b, c, d = ca[i], cb[i], cc[i], cd[i]
			local position = a + (b + (c + d * u) * u) * u
			if previous ~= nil then
				total += (position - previous).Magnitude
			end
			previous = position
			table.insert(path.tableS, total)
			table.insert(path.tableG, (i - 1) + u)
			local tangent = b + (c * 2 + d * (3 * u)) * u
			local flat = Vector3.new(tangent.X, 0, tangent.Z)
			table.insert(headings, if flat.Magnitude > 1e-6 then RouteMath.yawOf(flat) else (headings[#headings] or 0))
		end
	end
	path.length = total
	-- Turn rate per sample (rad / stud) and the indicator side for the turn ahead.
	local count = #path.tableS
	for i = 1, count do
		local j = if i < count then i + 1 else i
		local h = if i < count then i else i - 1
		local ds = path.tableS[j] - path.tableS[h]
		path.turn[i] = if ds > 1e-6 then wrapAngle(headings[j] - headings[h]) / ds else 0
	end
	for i = 1, count do
		local sum = 0
		local k = i
		while k < count and path.tableS[k] - path.tableS[i] < SIGNAL_AHEAD do
			sum += path.turn[k] * (path.tableS[k + 1] - path.tableS[k])
			k += 1
		end
		path.signal[i] = if sum > SIGNAL_TURN then 1 elseif sum < -SIGNAL_TURN then -1 else 0
	end
	local function tangentAt(i: number, u: number): Vector3
		local tangent = cb[i] + (cc[i] * 2 + cd[i] * (3 * u)) * u
		return if tangent.Magnitude > 1e-6 then tangent.Unit else Vector3.zAxis
	end
	path.startTangent = tangentAt(1, 0)
	path.endTangent = tangentAt(segments, 1)
	return path
end

--[[
	Point + unit tangent (direction of increasing s) at arc length `s`, and the arc-length table
	index (for turn / signal lookups). Open paths extrapolate straight beyond both ends; closed
	paths wrap.
	Example: local position, tangent = RouteMath.pathPoint(path, 12)
]]
function RouteMath.pathPoint(path: Path, s: number): (Vector3, Vector3, number)
	local length = path.length
	local tableS = path.tableS
	local count = #tableS
	if path.closed then
		s %= length
	elseif s <= 0 then
		return path.points[1] + path.startTangent * s, path.startTangent, 1
	elseif s >= length then
		return path.points[#path.points] + path.endTangent * (s - length), path.endTangent, count
	end
	-- Binary search: tableS[lo] <= s < tableS[lo + 1].
	local lo, hi = 1, count
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if tableS[mid] <= s then
			lo = mid
		else
			hi = mid
		end
	end
	local span = tableS[hi] - tableS[lo]
	local f = if span > 1e-9 then (s - tableS[lo]) / span else 0
	local g = path.tableG[lo] + (path.tableG[hi] - path.tableG[lo]) * f
	local i = math.min(math.floor(g) + 1, path.segments)
	local u = g - (i - 1)
	local a, b, c, d = path.ca[i], path.cb[i], path.cc[i], path.cd[i]
	local position = a + (b + (c + d * u) * u) * u
	local tangent = b + (c * 2 + d * (3 * u)) * u
	if tangent.Magnitude < 1e-6 then
		tangent = path.endTangent
	end
	return position, tangent.Unit, lo
end

--[[
	Arc length of the path point nearest `point` (coarse scan of the arc-length table, then a
	golden-section refine around the best sample). Used at compile time only.
	Example: RouteMath.nearestS(path, Vector3.new(-8, 0.56, 21)) --> 14
]]
function RouteMath.nearestS(path: Path, point: Vector3): number
	local tableS = path.tableS
	local best, bestDistance = 1, math.huge
	for i = 1, #tableS do
		local position = RouteMath.pathPoint(path, tableS[i])
		local distance = (position - point).Magnitude
		if distance < bestDistance then
			best, bestDistance = i, distance
		end
	end
	local lo = tableS[math.max(best - 1, 1)]
	local hi = tableS[math.min(best + 1, #tableS)]
	local ratio = (math.sqrt(5) - 1) / 2
	local function cost(s: number): number
		local position = RouteMath.pathPoint(path, s)
		return (position - point).Magnitude
	end
	for _ = 1, 40 do
		local a = hi - (hi - lo) * ratio
		local b = lo + (hi - lo) * ratio
		if cost(a) < cost(b) then
			hi = b
		else
			lo = a
		end
	end
	return (lo + hi) / 2
end

--------------------------------------------------------------------------------------------------
-- Speed profiles
--------------------------------------------------------------------------------------------------

--[[
	Trapezoid speed profile over `length` studs: accelerate from v0 at `accel`, cruise at up to
	`vmax`, brake at `decel` to v1. Short legs never reach vmax (triangle profile).
	Example: RouteMath.profile(40, 0, 0, 12, 4, 6).duration
]]
function RouteMath.profile(length: number, v0: number, v1: number, vmax: number, accel: number, decel: number): Profile
	local peak =
		math.sqrt(math.max(0, (2 * accel * decel * length + decel * v0 * v0 + accel * v1 * v1) / (accel + decel)))
	local vpeak = math.max(math.min(vmax, peak), v0, v1, 1e-3)
	local t1 = math.max(0, (vpeak - v0) / accel)
	local s1 = math.max(0, (vpeak * vpeak - v0 * v0) / (2 * accel))
	local t3 = math.max(0, (vpeak - v1) / decel)
	local s3 = math.max(0, (vpeak * vpeak - v1 * v1) / (2 * decel))
	local s2 = math.max(0, length - s1 - s3)
	local t2 = s2 / vpeak
	return {
		length = length,
		v0 = v0,
		v1 = v1,
		vpeak = vpeak,
		accel = accel,
		decel = decel,
		t1 = t1,
		t2 = t2,
		s1 = s1,
		s2 = s2,
		duration = t1 + t2 + t3,
		feasible = s1 + s3 <= length + 1e-6,
	}
end

--[[
	Distance travelled, speed and acceleration at `tau` seconds into the leg (clamped).
	Example: local distance, speed, accel = RouteMath.profileAt(profile, 1.5)
]]
function RouteMath.profileAt(p: Profile, tau: number): (number, number, number)
	tau = math.clamp(tau, 0, p.duration)
	if tau < p.t1 then
		return p.v0 * tau + 0.5 * p.accel * tau * tau, p.v0 + p.accel * tau, p.accel
	elseif tau < p.t1 + p.t2 then
		return p.s1 + p.vpeak * (tau - p.t1), p.vpeak, 0
	end
	local t3 = tau - p.t1 - p.t2
	local distance = p.s1 + p.s2 + p.vpeak * t3 - 0.5 * p.decel * t3 * t3
	return math.min(distance, p.length), math.max(p.vpeak - p.decel * t3, 0), -p.decel
end

--[[
	Inverse of profileAt: seconds into the leg when `distance` studs are reached.
	Example: RouteMath.profileTimeAt(profile, profile.length) --> profile.duration
]]
function RouteMath.profileTimeAt(p: Profile, distance: number): number
	distance = math.clamp(distance, 0, p.length)
	if distance <= p.s1 and p.s1 > 0 then
		local root = math.sqrt(math.max(0, p.v0 * p.v0 + 2 * p.accel * distance))
		return (root - p.v0) / p.accel
	elseif distance <= p.s1 + p.s2 then
		return p.t1 + (distance - p.s1) / p.vpeak
	end
	local d3 = distance - p.s1 - p.s2
	local root = math.sqrt(math.max(0, p.vpeak * p.vpeak - 2 * p.decel * d3))
	return math.min(p.t1 + p.t2 + (p.vpeak - root) / p.decel, p.duration)
end

--------------------------------------------------------------------------------------------------
-- Timelines
--------------------------------------------------------------------------------------------------

local function byTime(a: { t: number }, b: { t: number }): boolean
	return a.t < b.t
end

--[[
	Compiles a route definition (VehicleRouteConfig.Route) into a looping timeline. Pure and
	deterministic; VehicleRoutes compiles each route once and shares it across all 8 plots.
	@param route VehicleRouteConfig.Route
	@param rests { CFrame }  slot-local rest placements: [1] the leader, [1 + k] follower k (needed
	                         by start.nearest, sync = "nearest" followers and orient = "fixed")
	@return Timeline
	Example: RouteMath.compile(VehicleRouteConfig.byId.A3_Van, { layoutVanCFrame })
]]
function RouteMath.compile(route: VehicleRouteConfig.Route, rests: { CFrame }): Timeline
	local tuning = VehicleRouteConfig.Tuning
	local segs: { Seg } = {}
	local events: { Event } = {}
	local cargo: { { CargoEvent } } = {}
	for i = 1, #(route.cargo or {}) do
		cargo[i] = {}
	end
	local tips: { Window } = {}
	local signals: { Window } = {}
	local gates: { Window } = {}
	-- Pre-pass: every drive leg's path + speed profile, and the loop's natural length (the slack a
	-- `stretch` wait takes when the route fixes its `period`).
	local legs: { [number]: { path: Path, profile: Profile } } = {}
	local natural = 0
	local stretchIndex = 0
	for index, def in route.segments do
		if def.kind == "drive" then
			local path = RouteMath.buildPath(def.points or {}, def.closed)
			local profile = RouteMath.profile(
				path.length,
				def.v0 or 0,
				def.v1 or 0,
				def.speed or tuning.Speed,
				def.accel or tuning.Accel,
				def.decel or tuning.Decel
			)
			legs[index] = { path = path, profile = profile }
			natural += profile.duration
		else
			natural += def.duration or 1
			if def.stretch == true and stretchIndex == 0 then
				stretchIndex = index
			end
		end
	end
	local slack = 0
	local periodOk = true
	if route.period ~= nil then
		slack = route.period - natural
		if slack < -1e-6 or stretchIndex == 0 then
			periodOk = false
			slack = 0
		end
	end
	local t = 0
	local odo = 0
	local lastDrive = 0
	local pendingGate: number? = nil
	for index, def in route.segments do
		if def.kind == "drive" then
			local leg = legs[index]
			local path = leg.path
			local profile = leg.profile
			local gear = if def.reverse then -1 else 1
			local seg: Seg = {
				kind = "drive",
				t0 = t,
				t1 = t + profile.duration,
				odo0 = odo,
				path = path,
				profile = profile,
				gear = gear,
				fadeIn = def.fadeIn or 0,
				fadeOut = def.fadeOut or 0,
				anchor = index,
				hover = false,
				spin = 0,
				yaw0 = 0,
			}
			table.insert(segs, seg)
			-- Reverse beeper (`vehicle_beep`, a 1.6 s run of beeps): once per reverse leg, as the
			-- vehicle starts backing up.
			if def.beep == true then
				table.insert(events, { t = t + 0.2, kind = "beep" })
			end
			-- Gate (the A8 garage barrier): opens / closes as the vehicle passes the given points
			-- (projected onto this leg); a close on a later leg pairs with the pending open.
			local gate = def.gate
			if gate ~= nil then
				if gate.open ~= nil then
					pendingGate = t + RouteMath.profileTimeAt(profile, RouteMath.nearestS(path, gate.open))
				end
				if gate.close ~= nil and pendingGate ~= nil then
					table.insert(gates, {
						t0 = pendingGate,
						t1 = t + RouteMath.profileTimeAt(profile, RouteMath.nearestS(path, gate.close)),
						value = 1,
					})
					pendingGate = nil
				end
			end
			t = seg.t1
			odo += path.length * gear
			lastDrive = #segs
		else
			local duration = (def.duration or 1) + (if index == stretchIndex then slack else 0)
			local seg: Seg = {
				kind = "wait",
				t0 = t,
				t1 = t + duration,
				odo0 = odo,
				path = nil,
				profile = nil,
				gear = 1,
				fadeIn = 0,
				fadeOut = 0,
				anchor = lastDrive, -- 0 = resolved below (wait before the first drive: the last leg)
				hover = def.hover == true,
				spin = math.rad(def.spin or 0),
				yaw0 = 0,
			}
			table.insert(segs, seg)
			local function cargoAction(action: VehicleRouteConfig.CargoAction?, loaded: boolean)
				if action == nil then
					return
				end
				for k, group in action.groups do
					local at = t + action.at + (action.every or 0) * (k - 1)
					local list = cargo[group]
					if list ~= nil then
						table.insert(list, { t = at, loaded = loaded })
						table.insert(events, {
							t = at,
							kind = if loaded then "load" else "unload",
							group = group,
							pitch = 1 + 0.08 * (k - 1),
						})
					end
				end
			end
			cargoAction(def.unload, false)
			cargoAction(def.load, true)
			if def.honk ~= nil then
				table.insert(
					events,
					{ t = t + def.honk, kind = "honk", chance = route.honkChance or tuning.HonkChance }
				)
			end
			if def.signal ~= nil then
				table.insert(signals, { t0 = t + def.signal.from, t1 = t + def.signal.to, value = def.signal.side })
			end
			if def.tip ~= nil then
				table.insert(
					tips,
					{ t0 = t + def.tip.at, t1 = t + def.tip.at + def.tip.duration, value = def.tip.angle }
				)
			end
			t = seg.t1
		end
	end
	-- Waits before the first drive leg hold the LAST leg's end pose (the loop wraps there).
	for _, seg in segs do
		if seg.kind == "wait" then
			if seg.anchor == 0 then
				seg.anchor = lastDrive
			end
			local anchor = segs[seg.anchor]
			if anchor ~= nil then
				seg.gear = anchor.gear
			end
		end
	end
	-- Spins: a wait keeps every turn made since its anchor leg ended. Waits before the first leg
	-- continue from the waits after the last leg (the loop wraps), so start from their total.
	local turned = 0
	for i = lastDrive + 1, #segs do
		turned += segs[i].spin
	end
	for _, seg in segs do
		if seg.kind == "drive" then
			turned = 0
		else
			seg.yaw0 = turned
			turned += seg.spin
		end
	end
	table.sort(events, byTime)
	for _, list in cargo do
		table.sort(list, byTime)
	end
	local fixed = route.orient == "fixed"
	local function yawOfRest(rest: CFrame?): number?
		if not fixed or rest == nil then
			return nil
		end
		return RouteMath.yawOf(rest.LookVector)
	end
	local timeline: Timeline = {
		id = route.id,
		period = t,
		segs = segs,
		start = 0,
		netOdo = odo,
		events = events,
		cargo = cargo,
		tips = tips,
		signals = signals,
		gates = gates,
		instances = { { offset = 0, gap = 0, yaw = yawOfRest(rests[1]) } },
		brakeHold = tuning.BrakeHold,
		periodOk = periodOk,
	}
	-- Clock start: where the vehicle sits on its authored rest placement (seconds into a wait,
	-- studs along a drive leg, or the leg point nearest the rest placement).
	local start = route.start
	local startSeg = segs[start.segment]
	-- Seconds into the start leg where it passes `point` (sync followers, start.nearest).
	local function timeNearest(point: Vector3): number
		if startSeg == nil or startSeg.path == nil or startSeg.profile == nil then
			return 0
		end
		local s = RouteMath.nearestS(startSeg.path :: Path, point)
		return startSeg.t0 + RouteMath.profileTimeAt(startSeg.profile :: Profile, s)
	end
	if startSeg ~= nil then
		if start.nearest and rests[1] ~= nil then
			timeline.start = timeNearest(rests[1].Position)
		elseif start.before ~= nil then
			-- Counted back from the segment's end (stays put when a `stretch` grows the segment).
			timeline.start = math.clamp(startSeg.t1 - start.before, startSeg.t0, startSeg.t1)
		elseif startSeg.kind == "drive" and startSeg.profile ~= nil then
			timeline.start = startSeg.t0 + RouteMath.profileTimeAt(startSeg.profile :: Profile, start.at or 0)
		else
			timeline.start = startSeg.t0 + math.clamp(start.at or 0, 0, startSeg.t1 - startSeg.t0)
		end
	end
	for k, follower in route.followers or {} do
		local rest = rests[1 + k]
		local offset = 0
		if follower.sync == "nearest" and rest ~= nil then
			offset = timeNearest(rest.Position) - timeline.start
		end
		timeline.instances[1 + k] = { offset = offset, gap = follower.gap or 0, yaw = yawOfRest(rest) }
	end
	return timeline
end

-- Fade alpha of a pose at arc length `s` on a drive segment.
local function fadeAlpha(seg: Seg, s: number): number
	local alpha = 1
	if seg.fadeIn > 0 then
		alpha = math.min(alpha, math.clamp(s / seg.fadeIn, 0, 1))
	end
	if seg.fadeOut > 0 then
		local path = seg.path :: Path
		alpha = math.min(alpha, math.clamp((path.length - s) / seg.fadeOut, 0, 1))
	end
	return alpha
end

--[[ A fresh Sample table (allocate once per vehicle instance, reuse every frame). ]]
function RouteMath.newSample(): Sample
	return {
		position = Vector3.zero,
		yaw = 0,
		speed = 0,
		accel = 0,
		gear = 1,
		alpha = 1,
		odo = 0,
		turn = 0,
		signal = 0,
		brake = false,
		seg = 1,
		climb = 0,
		flying = false,
	}
end

-- Index of the segment active at clock `t` (t already wrapped into [0, period)).
local function segmentAt(timeline: Timeline, t: number): number
	local segs = timeline.segs
	for i = 1, #segs do
		if t < segs[i].t1 then
			return i
		end
	end
	return #segs
end

--[[
	Pose of one route instance at clock `t` (any value; wrapped by the period). Instance 1 is the
	leader; followers add their clock offset / sit `gap` studs behind (their fade comes from their
	own position, so the second mine cart enters the tunnel after the first).
	@param instance number  index into timeline.instances
	@param out Sample  written in place and returned
	Example: RouteMath.sample(timeline, clock, 1, sampleTable).position
]]
function RouteMath.sample(timeline: Timeline, t: number, instance: number, out: Sample): Sample
	local spec = timeline.instances[instance] or timeline.instances[1]
	local gap = spec.gap
	local fixedYaw = spec.yaw
	local period = timeline.period
	t = (t + spec.offset) % period
	local index = segmentAt(timeline, t)
	local seg = timeline.segs[index]
	out.seg = index
	if seg.kind == "drive" then
		local path = seg.path :: Path
		local distance, speed, accel = RouteMath.profileAt(seg.profile :: Profile, t - seg.t0)
		local s = distance - gap * seg.gear
		local position, tangent, at = RouteMath.pathPoint(path, s)
		out.position = position
		out.yaw = fixedYaw or RouteMath.yawOf(if seg.gear > 0 then tangent else -tangent)
		out.speed = speed
		out.accel = accel
		out.gear = seg.gear
		out.alpha = fadeAlpha(seg, s)
		out.odo = seg.odo0 + distance * seg.gear
		out.turn = path.turn[at] or 0
		out.signal = if seg.gear > 0 then (path.signal[at] or 0) else 0
		out.brake = accel < -1e-3
		-- Climb of the way the model FACES (a reverse leg climbing backwards dips its nose).
		local horizontal = math.sqrt(tangent.X * tangent.X + tangent.Z * tangent.Z)
		out.climb = math.atan2(tangent.Y * seg.gear, horizontal)
		out.flying = true
	else
		local anchor = timeline.segs[seg.anchor]
		local path = anchor.path :: Path
		local s = path.length - gap * anchor.gear
		local position, tangent = RouteMath.pathPoint(path, s)
		out.position = position
		-- A spinning wait turns on the spot (eased); later waits keep the turn (yaw0).
		local span = seg.t1 - seg.t0
		local turn = seg.yaw0 + seg.spin * (if span > 0 then smooth((t - seg.t0) / span) else 1)
		out.yaw = fixedYaw or (RouteMath.yawOf(if anchor.gear > 0 then tangent else -tangent) + turn)
		out.climb = 0
		out.flying = seg.hover
		out.speed = 0
		out.accel = 0
		out.gear = anchor.gear
		out.alpha = fadeAlpha(anchor, s)
		out.odo = seg.odo0
		out.turn = 0
		local side = 0
		for _, window in timeline.signals do
			if t >= window.t0 and t < window.t1 then
				side = window.value
			end
		end
		out.signal = side
		out.brake = t - seg.t0 < timeline.brakeHold
	end
	return out
end

--[[
	Cargo group state at clock `t`: loaded?, and the progress (0..1) of its last change (1 =
	settled). Events wrap around the loop (state before the first event = after the last one).
	Example: local loaded, u = RouteMath.cargoAt(timeline, 1, clock)
]]
function RouteMath.cargoAt(timeline: Timeline, group: number, t: number): (boolean, number)
	local list = timeline.cargo[group]
	if list == nil or #list == 0 then
		return true, 1
	end
	local period = timeline.period
	t %= period
	local last: CargoEvent = list[#list]
	local at = last.t - period
	for _, event in list do
		if event.t <= t then
			last = event
			at = event.t
		else
			break
		end
	end
	return last.loaded, math.clamp((t - at) / VehicleRouteConfig.Tuning.PopSeconds, 0, 1)
end

--[[
	Tip angle (degrees) at clock `t`: eases up, holds, eases back (the mine cart dumping its ore).
	Example: RouteMath.tipAt(timeline, clock) --> 0 .. 30
]]
function RouteMath.tipAt(timeline: Timeline, t: number): number
	t %= timeline.period
	local rise = VehicleRouteConfig.Tuning.TipEase
	for _, window in timeline.tips do
		if t >= window.t0 and t < window.t1 then
			local up = smooth((t - window.t0) / rise)
			local down = smooth((window.t1 - t) / rise)
			return window.value * math.min(up, down)
		end
	end
	return 0
end

--[[
	Gate (barrier) open fraction 0..1 at clock `t`: lifts over GateSeconds from t0, lowers over
	GateSeconds from t1. Windows may wrap past the loop end.
]]
function RouteMath.gateAt(timeline: Timeline, t: number): number
	local period = timeline.period
	t %= period
	local ease = VehicleRouteConfig.Tuning.GateSeconds
	local open = 0
	for _, window in timeline.gates do
		local t1 = window.t1
		if t1 < window.t0 then
			t1 += period
		end
		-- Check the clock and the clock one lap later (a window running past the loop end).
		for lap = 0, 1 do
			local shifted = t + lap * period
			if shifted >= window.t0 and shifted < t1 + ease then
				local up = smooth((shifted - window.t0) / ease)
				local down = 1 - smooth((shifted - t1) / ease)
				open = math.max(open, math.min(up, down))
			end
		end
	end
	return open
end

--[[
	Collects the indices of timeline events in the clock window (from, to], wrap-aware: when the
	clock wrapped this frame, `to` < `from`. Writes into `out` (cleared) and returns the count.
]]
function RouteMath.eventsBetween(timeline: Timeline, from: number, to: number, out: { number }): number
	table.clear(out)
	local period = timeline.period
	from %= period
	to %= period
	for index, event in timeline.events do
		local hit = if from <= to then (event.t > from and event.t <= to) else (event.t > from or event.t <= to)
		if hit then
			table.insert(out, index)
		end
	end
	return #out
end

return RouteMath
