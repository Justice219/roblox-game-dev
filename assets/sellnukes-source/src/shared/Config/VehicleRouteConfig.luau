--!strict
--[[
	VehicleRouteConfig — every moving vehicle / machine on the map (owner R56: "animate more of
	the places in the map too, like, I feel like the delivery truck should drive in and out,
	semi-truck should drive in and out, you know, stuff like that").

	What moves (docs/build-in.md "Vehicles + map motion" has the full table):
		A3  BoomDash delivery van   road -> backs into its stall -> parcels pop onto the roof -> out
		A3  lane scooters (x3)      zip round the stadium lane, leaning into the bends
		A4  mine-cart train (x2)    rolls out of the tunnel -> tips its ore into the bin -> back in
		A6  semi-truck              road -> backs up to the loading dock (beep beep) -> crates pop
		                            onto the flatbed -> honk -> out
		A6  forklift                shuttles pallets: pallet pops on -> drive -> drop -> back up
		A6  belt toy rockets (x3)   ride the conveyor at belt speed, fading in / out at the ends
		A8  shopper car             road -> barrier lifts -> parks in the garage -> backs out -> out
		D3  ptero couriers (x2)     Dino Valley (owner R57): one flies a parcel from the nest deck to
		                            the landing pad and drops it; the other drops its parcel into the
		                            nest, flies off into the sky and comes back with a new one. Wings
		                            flap (route `flyer`), the two share one clock (route `sync`)

	Worlds (owner R57): a route's optional `world` (nil = Nuke Town "main") names the world whose
	plots it runs in; its `area` / placements index that world's layouts (WorldDef.layoutFolder).
	The client only binds a route to models in plots of the same world.

	Data model (pure; compiled by Client/Tycoon/Fx/RouteMath, played by Client/Tycoon/Fx/VehicleRoutes):
		* Coordinates are SLOT-LOCAL studs (AreaLayouts frame: +Z away from the road, +Y up, the
		  road's near lane at z = ROAD_Z). The client maps them through WorldLayout.slotOrigin, so
		  every plot rotation is handled by one CFrame.
		* A route is a list of segments: `drive` legs (spline through `points`, optional `reverse`,
		  boundary speeds v0 / v1, fades) and `wait`s (cargo load / unload, honk, indicator signal,
		  cart tip). The loop repeats forever; off-plot legs fade out / in on the road.
		* `rest` names the vehicle's layout placement: the server spawns it there, the clock starts
		  where the route passes through it (`start`), and Reduce Motion / the admin switch leave it there.
		  tests/vehicle-routes.luau proves the rest pose lies on the route, every leg joins the next
		  smoothly, and no route clips a collider of its area.
		* `followers` share the leader's clock: `gap` = studs behind along the path (the second mine
		  cart), `sync = "nearest"` = same path, own spot on it (belt rockets, lane scooters).
		* Flyers (owner R57): `flyer` flaps the WingL / WingR pieces (about the model's local Z through
		  the body centre line), pitches the nose with the climb and banks through `lean`. A `wait`
		  may `hover` (wings keep flapping) and `spin` (turn on the spot by that many degrees, eased:
		  a flyer lands facing in, turns round, and takes off facing out).
		* `period` + one `stretch` wait: the loop is exactly `period` seconds (the stretch wait takes
		  the slack). Routes with the same `sync` key in one area share ONE clock, so their
		  choreography is fixed (tests/vehicle-routes.luau proves they never touch).
		* `start.before` = seconds before the start segment ENDS (stays put when `stretch` grows it).

	Piece contract (Blender builders tools/blender/models/area03/04/06/08.py, R56):
		Tyres* / Hubs* / Wheels*   one piece per AXLE, bbox centre on the axle -> spin about local X
		BrakeLights                Smooth red, switched to Neon while braking / just stopped
		IndicatorL / IndicatorR    Smooth amber, blink while turning / signalling
		Cargo1..N (route `cargo`)  pop in / out one by one
	Routed models are never animated by WorldFx (WorldFxConfig.RoutedModels; lights still glow).

	Example:
		local route = VehicleRouteConfig.byId.A3_Van
		local timeline = RouteMath.compile(route, restCFrames)
]]

local VehicleRouteConfig = {}

export type Placement = { build: string, index: number }

-- One cargo action inside a wait: groups pop at `at`, `at + every`, ... seconds into the wait.
export type CargoAction = { groups: { number }, at: number, every: number? }

-- A segment: kind "drive" (fields up to `gate`) or "wait" (fields from `duration`).
export type Segment = {
	kind: string,
	-- drive
	points: { Vector3 }?,
	closed: boolean?,
	reverse: boolean?,
	speed: number?,
	v0: number?,
	v1: number?,
	accel: number?,
	decel: number?,
	fadeIn: number?,
	fadeOut: number?,
	beep: boolean?, -- reverse beeper (`vehicle_beep`) once as this leg starts
	gate: { open: Vector3?, close: Vector3? }?, -- linked gate opens / closes as the vehicle passes
	-- wait
	duration: number?,
	hover: boolean?, -- flyers: wings keep flapping through this wait (else they settle)
	spin: number?, -- degrees turned on the spot over the wait (eased; + = counter-clockwise from above)
	stretch: boolean?, -- takes the slack so the loop lasts exactly route.period (one per route)
	load: CargoAction?,
	unload: CargoAction?,
	honk: number?, -- seconds into the wait (rolled against honkChance per lap)
	signal: { side: number, from: number, to: number }?, -- 1 left, -1 right
	tip: { at: number, duration: number, angle: number }?, -- degrees, toward tipSide
}

export type Follower = { placement: Placement, gap: number?, sync: string? }

-- A gate: pieces of another model in the same area that swing open while `gates` windows run.
export type Gate = {
	modelKey: string,
	pieces: { string },
	hinge: Vector3, -- model-local
	axis: Vector3, -- model-local unit axis
	angle: number, -- degrees when fully open
}

--[[
	A flying route's wing + attitude tuning (owner R57 D3 ptero couriers). Wing pieces are balanced
	about the body centre line, so the piece CFrame turns about the shoulder line (model local Z).
]]
export type Flyer = {
	wingLeft: string, -- piece name on the model's -X side
	wingRight: string, -- piece name on the +X side
	amplitude: number, -- degrees each way while flying / hovering
	period: number, -- seconds per flap while flying / hovering
	restAmplitude: number, -- degrees while perched (a slow "breathing" ripple)
	restPeriod: number,
	blendSeconds: number, -- time constant easing between perched and flying flaps
	heave: number, -- studs the body rises and falls with each flap (full flight)
	climbGain: number, -- fraction of the path's climb angle shown as nose pitch
	climbMax: number, -- degrees
}

export type Route = {
	id: string,
	world: string?, -- WorldsConfig id; nil = Nuke Town ("main")
	area: number,
	modelKey: string,
	rest: Placement,
	followers: { Follower }?,
	orient: string?, -- "path" (default) | "fixed" (keeps the rest yaw: conveyor items)
	wheelRadius: number?, -- nil = no wheel spin
	cargo: { { string } }?,
	unloadDir: Vector3?, -- model-local hop of unloaded cargo (studs)
	tipSide: number?, -- +1 tips toward local +X, -1 toward -X
	tipHinge: Vector3?, -- model-local hinge point of the tip
	lean: number?, -- 0..1 lean into bends (two-wheelers)
	lights: boolean?, -- BrakeLights / IndicatorL / IndicatorR present
	honkChance: number?,
	-- The sound a `honk` wait plays (default Sounds.Honk): owner R57's ptero couriers squawk.
	horn: { key: string, volume: number }?,
	gate: Gate?,
	-- Collider labels ("<build>#<index>", tests/vehicle-routes.luau) the route deliberately drives
	-- into: e.g. the A4 back cliff, whose mesh has an open tunnel mouth while its collider is a
	-- solid wall (players never walk in). The vehicle is fading out there.
	passThrough: { string }?,
	flyer: Flyer?, -- a flying route (wings flap; nose follows the climb)
	period: number?, -- exact loop length (seconds); one `stretch` wait absorbs the slack
	sync: string?, -- routes of one area with the same key share one clock (fixed choreography)
	segments: { Segment },
	start: { segment: number, at: number?, nearest: boolean?, before: number? },
}

export type TierBudget = {
	Enabled: boolean, -- false = every vehicle stays parked on its layout spot
	Range: number, -- animate only routes within this many studs of the camera
	MaxActive: number, -- nearest N routes move
	HalfRateBeyond: number, -- farther routes write every other frame
}

--[[
	Per device tier (FxQuality, owner R11). Every tier drives vehicles; lower tiers move fewer,
	nearer routes. Owner R103 ("none of the vehicles are animating like they used to"): Low used to
	park EVERY vehicle while the machines (WorldFxConfig Low: 48 moving parts within 140 studs) and
	the manager NPCs (ManagerNpcConfig Low: 3 within 70) kept moving, so on a phone (Automatic
	graphics -> Low; ~30 % of live sessions) or at graphics 1-3 only the vehicles stood still. Low now
	moves the nearest 4 routes within the machines' 140-stud range (your own area's van + scooter lap
	+ the next two; ~60 BulkMoveTo parts a frame at most, half rate beyond 45 studs, off-screen routes
	skip their writes). Reduce Motion and the admin switch still park everything.
]]
VehicleRouteConfig.Tiers = table.freeze({
	Low = { Enabled = true, Range = 140, MaxActive = 4, HalfRateBeyond = 45 },
	Mid = { Enabled = true, Range = 190, MaxActive = 8, HalfRateBeyond = 90 },
	High = { Enabled = true, Range = 260, MaxActive = 16, HalfRateBeyond = 140 },
} :: { [string]: TierBudget })

-- Motion + FX tunables.
VehicleRouteConfig.Tuning = table.freeze({
	Speed = 10, -- default cruise (studs / s)
	Accel = 4,
	Decel = 6,
	BrakeHold = 1.2, -- brake lights stay on this long after stopping
	PopSeconds = 0.45, -- cargo pop in / out duration
	PopHeight = 1.6, -- cargo drops in from this high
	PopFade = 0.3, -- fraction of the pop spent fading in
	TipEase = 0.6, -- seconds to tip up / back
	GateSeconds = 0.9, -- barrier lift / lower time
	HonkChance = 0.65,
	-- Body motion (radians / studs).
	BobIdle = 0.025, -- engine idle shiver
	BobMove = 0.06, -- road bumps at cruise
	BobHz = 2.2,
	PitchGain = 0.012, -- nose dip per stud/s² of braking
	PitchMax = math.rad(2.5),
	LeanGain = 0.02, -- lean per (rad/stud * (stud/s)²)
	LeanMax = math.rad(16),
	SmoothSeconds = 0.25, -- pitch / lean smoothing
	-- Lights.
	BlinkHz = 1.6,
	IndicatorColor = Color3.fromRGB(255, 190, 70),
	BrakeColor = Color3.fromRGB(255, 70, 70),
	-- Refresh (distance ranking) interval, knockdown resume delay (rebuild fly-in), build hold.
	RefreshInterval = 0.5,
	ResumeAfterKnockdown = 5,
	BuildHold = 5,
	-- Rest-pose match tolerance when binding a spawned model to its route.
	BindTolerance = 1,
})

-- Sounds (existing AudioConfig.Sfx keys only; tests/vehicle-routes.luau checks them).
VehicleRouteConfig.Sounds = table.freeze({
	Range = 70, -- studs: farther vehicles stay silent
	Honk = { key = "vehicle_honk", volume = 1 }, -- cartoon toy "honk-honk" (0.88 s)
	Beep = { key = "vehicle_beep", volume = 1 }, -- soft reversing beeper (6 beeps over 1.6 s)
	Load = { key = "pop", pitch = 1.05, volume = 0.6 },
	Unload = { key = "clack", pitch = 0.75, volume = 0.6 },
})

-- Admin switch (World tab "Vehicles on/off", Server/Admin/Handlers/WorldHandlers): the server sets
-- this ReplicatedStorage attribute; false = every vehicle parks on its layout spot (read live).
VehicleRouteConfig.EnabledAttribute = "VehiclesEnabled"

-- Wheel / light / gate piece names (Blender contract above).
VehicleRouteConfig.WheelPrefixes = table.freeze({ "Tyres", "Hubs", "Wheels" })
VehicleRouteConfig.BrakePiece = "BrakeLights"
VehicleRouteConfig.IndicatorLeft = "IndicatorL"
VehicleRouteConfig.IndicatorRight = "IndicatorR"

--------------------------------------------------------------------------------------------------
-- Authoring helpers (slot-local)
--------------------------------------------------------------------------------------------------

-- Near lane of the plot road (slot z; the asphalt is z in [-18, -2], the curb z in [-2, 0]).
local ROAD_Z = -6
local ROAD_Y = 0.02
-- Off-plot ends of the road legs (|x|): vehicles fade over the last FADE studs.
local ROAD_END = 74
local FADE = 10

--[[
	Ground height under a point that crosses from the road (y = ROAD_Y) over the curb onto a lot
	whose top is `lotY` (linear ramp over z in [-2.5, 0.5]).
]]
local function ground(z: number, lotY: number): number
	local u = math.clamp((z + 2.5) / 3, 0, 1)
	return ROAD_Y + (lotY - ROAD_Y) * u
end

--[[
	Points along a straight line every ~`step` studs (both ends included). Dense straights keep the
	Catmull-Rom spline straight next to a bend.
	Example: line(Vector3.new(0, 0, 0), Vector3.new(0, 0, 20), 4)
]]
local function line(a: Vector3, b: Vector3, step: number?): { Vector3 }
	local count = math.max(1, math.ceil((b - a).Magnitude / (step or 4)))
	local points = {}
	for i = 0, count do
		table.insert(points, a:Lerp(b, i / count))
	end
	return points
end

--[[
	Points on a horizontal circular arc: angle 0 = +X, 90 = +Z (degrees), from `fromDeg` to `toDeg`
	every ~`stepDeg`. `y` may be a function of z (curb crossings).
]]
local function arc(
	centre: Vector3,
	radius: number,
	fromDeg: number,
	toDeg: number,
	y: ((z: number) -> number)?
): { Vector3 }
	local count = math.max(2, math.ceil(math.abs(toDeg - fromDeg) / 12))
	local points = {}
	for i = 0, count do
		local a = math.rad(fromDeg + (toDeg - fromDeg) * i / count)
		local x = centre.X + radius * math.cos(a)
		local z = centre.Z + radius * math.sin(a)
		table.insert(points, Vector3.new(x, if y ~= nil then y(z) else centre.Y, z))
	end
	return points
end

--[[
	Smooth lateral S-curve from (x0, z0) to (x1, z1) along +Z or -Z (smoothstep in x over z).
]]
local function sCurve(x0: number, z0: number, x1: number, z1: number, y: number, steps: number?): { Vector3 }
	local count = steps or 8
	local points = {}
	for i = 0, count do
		local u = i / count
		local s = u * u * (3 - 2 * u)
		table.insert(points, Vector3.new(x0 + (x1 - x0) * s, y, z0 + (z1 - z0) * u))
	end
	return points
end

--[[ Concatenates point lists (consecutive duplicates are dropped by RouteMath.buildPath). ]]
local function join(...: { Vector3 }): { Vector3 }
	local out = {}
	for _, list in { ... } do
		for _, point in list do
			table.insert(out, point)
		end
	end
	return out
end

--[[ The same points in reverse order (a reverse leg retracing a forward one). ]]
local function reversed(points: { Vector3 }): { Vector3 }
	local out = {}
	for i = #points, 1, -1 do
		table.insert(out, points[i])
	end
	return out
end

-- Road leg along the near lane at ROAD_Z from x0 to x1.
local function road(x0: number, x1: number): { Vector3 }
	return line(Vector3.new(x0, ROAD_Y, ROAD_Z), Vector3.new(x1, ROAD_Y, ROAD_Z), 8)
end

VehicleRouteConfig.Helpers = table.freeze({
	ground = ground,
	line = line,
	arc = arc,
	sCurve = sCurve,
	join = join,
	reversed = reversed,
	road = road,
	ROAD_Z = ROAD_Z,
	ROAD_Y = ROAD_Y,
	ROAD_END = ROAD_END,
})

--------------------------------------------------------------------------------------------------
-- Routes
--------------------------------------------------------------------------------------------------

local routes: { Route } = {}

do -- A3 BoomDash delivery van: in from the hub side, backs into stall 1, parcels pop on, out.
	local LOT = 0.56 -- AreaLayouts/Area03 LANE_Y: the parking pad surface
	local REST_X, REST_Z = 39.45, 29.4 -- Area03 VAN
	local LANE_X = 47.15 -- second stall: keeps the van clear of the dispatcher's pad (40, 10)
	local R = 12
	local function y(z: number): number
		return ground(z, LOT)
	end
	local inLane = join(
		arc(Vector3.new(LANE_X + R, 0, ROAD_Z + R), R, -90, -180, y),
		line(Vector3.new(LANE_X, LOT, ROAD_Z + R), Vector3.new(LANE_X, LOT, 8), 2),
		sCurve(LANE_X, 8, REST_X, 24, LOT, 10),
		line(Vector3.new(REST_X, LOT, 24), Vector3.new(REST_X, LOT, REST_Z), 2)
	)
	local outLane = join(
		line(Vector3.new(REST_X, LOT, REST_Z), Vector3.new(REST_X, LOT, 24), 2),
		sCurve(REST_X, 24, LANE_X, 8, LOT, 10),
		line(Vector3.new(LANE_X, LOT, 8), Vector3.new(LANE_X, LOT, 7), 1),
		arc(Vector3.new(LANE_X + 13, 0, 7), 13, 180, 270, y)
	)
	table.insert(routes, {
		id = "A3_Van",
		area = 3,
		modelKey = "A3_DeliveryVan",
		rest = { build = "A3_DeliveryVan", index = 1 },
		wheelRadius = 1.3,
		cargo = { { "Cargo1" }, { "Cargo2" }, { "Cargo3" } },
		lights = true,
		segments = {
			-- 1 arrive along the road from the hub side, stop past the lane
			{ kind = "drive", points = road(-ROAD_END, LANE_X + R), speed = 14, v0 = 14, fadeIn = FADE, decel = 5 },
			{ kind = "wait", duration = 0.8 },
			-- 3 back into the stall
			{ kind = "drive", points = inLane, reverse = true, speed = 5, accel = 2.5, decel = 3, beep = true },
			-- 4 parcels pop onto the roof, indicate right, honk, go
			{
				kind = "wait",
				duration = 9,
				load = { groups = { 1, 2, 3 }, at = 2, every = 1 },
				signal = { side = -1, from = 6.5, to = 9 },
				honk = 7.6,
			},
			-- 5 pull out and turn onto the road, then speed off and fade
			{ kind = "drive", points = outLane, speed = 8, v1 = 8, accel = 3 },
			{
				kind = "drive",
				points = road(LANE_X + 13, ROAD_END),
				speed = 14,
				v0 = 8,
				v1 = 14,
				accel = 5,
				fadeOut = FADE,
			},
			-- 7 off-plot: deliveries done, parcels gone (hidden)
			{ kind = "wait", duration = 6, unload = { groups = { 1, 2, 3 }, at = 0.5 } },
		},
		start = { segment = 4, at = 6.2 },
	})
end

do -- A3 lane scooters: three on the stadium loop (lane centre (0, 30), straights ±22, radius 9).
	local LANE_Y = 0.56
	local C, HALF, R = 30, 22, 9
	local loop = join(
		line(Vector3.new(-HALF, LANE_Y, C - R), Vector3.new(HALF, LANE_Y, C - R), 4),
		arc(Vector3.new(HALF, LANE_Y, C), R, -90, 90),
		line(Vector3.new(HALF, LANE_Y, C + R), Vector3.new(-HALF, LANE_Y, C + R), 4),
		arc(Vector3.new(-HALF, LANE_Y, C), R, 90, 270)
	)
	-- The rest scooters (Area03 SCOOTERS 4..6) sit on the loop: two on straights (collinear knots
	-- keep the spline exactly straight), one on the right bend's apex.
	table.insert(routes, {
		id = "A3_Scooters",
		area = 3,
		modelKey = "A3_Scooter",
		rest = { build = "A3_Scooters", index = 4 },
		followers = {
			{ placement = { build = "A3_Scooters", index = 5 }, sync = "nearest" },
			{ placement = { build = "A3_Scooters", index = 6 }, sync = "nearest" },
		},
		lean = 1,
		segments = {
			{ kind = "drive", points = loop, closed = true, speed = 8.5, v0 = 8.5, v1 = 8.5 },
		},
		start = { segment = 1, nearest = true },
	})
end

do -- A4 mine-cart train: out of the tunnel, tip the ore into the bin, back into the tunnel.
	local X, Y = -22, 1.0 -- AreaLayouts/Area04 CART_TRACK x; rail top = FLOOR 0.4 + 0.6
	local TUNNEL_Z, BUFFER_Z = 62, 23.9 -- buffer stop face z 21.2 + half cart 2.3 + 0.4
	local track = line(Vector3.new(X, Y, TUNNEL_Z), Vector3.new(X, Y, BUFFER_Z), 4)
	table.insert(routes, {
		id = "A4_Carts",
		area = 4,
		modelKey = "A4_MineCart",
		rest = { build = "A4_CartTrack", index = 2 },
		followers = { { placement = { build = "A4_CartTrack", index = 3 }, gap = 5.2 } },
		wheelRadius = 0.55,
		cargo = { { "Gem", "Glow" } },
		unloadDir = Vector3.new(2.8, 0.6, 0),
		tipSide = 1,
		tipHinge = Vector3.new(1.8, 0.95, 0),
		passThrough = { "A4_MineEntrance#1" },
		segments = {
			{ kind = "drive", points = track, speed = 5, accel = 2.5, decel = 3, fadeIn = 5 },
			{
				kind = "wait",
				duration = 6,
				tip = { at = 0.8, duration = 3.4, angle = 28 },
				unload = { groups = { 1 }, at = 1.5 },
			},
			{
				kind = "drive",
				points = reversed(track),
				reverse = true,
				speed = 4.5,
				accel = 2,
				decel = 3,
				fadeOut = 5,
			},
			-- inside the tunnel (hidden): fresh glow rock
			{ kind = "wait", duration = 4, load = { groups = { 1 }, at = 1 } },
		},
		start = { segment = 1, at = TUNNEL_Z - 45.3 }, -- Area04 lead cart at z 45.3
	})
end

do -- A6 semi-truck: in along the road, reverses up to the loading dock, crates pop on, out.
	local FLOOR = 0.4 -- AreaLayouts/Area06 FLOOR
	local REST_X, REST_Z = 46.4, 51.25 -- rear (z + 7.25) against the dock bumpers
	local LANE_X = 41 -- road-side lane (clear of the boss pad at (47, 9))
	local R = 14
	local function y(z: number): number
		return ground(z, FLOOR)
	end
	local inLane = join(
		arc(Vector3.new(LANE_X + R, 0, ROAD_Z + R), R, -90, -180, y),
		-- A long, gentle S (z 8 -> 38): reversing, the trailer end swings toward the side wall
		-- (x 49.4 from z 20.4), so the lateral shift is spread out.
		sCurve(LANE_X, ROAD_Z + R, REST_X, 38, FLOOR, 16),
		line(Vector3.new(REST_X, FLOOR, 38), Vector3.new(REST_X, FLOOR, REST_Z), 3)
	)
	table.insert(routes, {
		id = "A6_Truck",
		area = 6,
		modelKey = "A6_DeliveryTruck",
		rest = { build = "A6_LoadingDock", index = 2 },
		wheelRadius = 1.0,
		cargo = { { "Cargo1" }, { "Cargo2" }, { "Cargo3" }, { "Cargo4" } },
		lights = true,
		honkChance = 0.75,
		segments = {
			{ kind = "drive", points = road(-ROAD_END, LANE_X + R), speed = 15, v0 = 15, fadeIn = FADE, decel = 5 },
			{ kind = "wait", duration = 1 },
			-- 3 back up to the dock (beep beep)
			{ kind = "drive", points = inLane, reverse = true, speed = 5, accel = 2, decel = 2.5, beep = true },
			-- 4 crates pop onto the flatbed, indicate right, honk
			{
				kind = "wait",
				duration = 9,
				load = { groups = { 1, 2, 3, 4 }, at = 1.8, every = 0.9 },
				signal = { side = -1, from = 6.5, to = 9 },
				honk = 8,
			},
			{ kind = "drive", points = reversed(inLane), speed = 7, v1 = 7, accel = 2.5 },
			{
				kind = "drive",
				points = road(LANE_X + R, ROAD_END),
				speed = 15,
				v0 = 7,
				v1 = 15,
				accel = 5,
				fadeOut = FADE,
			},
			{ kind = "wait", duration = 5, unload = { groups = { 1, 2, 3, 4 }, at = 0.5 } },
		},
		start = { segment = 4, at = 6.4 },
	})
end

do -- A6 forklift: pallet pops onto the forks at A, drive to B, drop it, back up to A.
	local FLOOR = 0.4
	local shuttle = {
		Vector3.new(-41, FLOOR, 28), -- A (AreaLayouts/Area06 FORKLIFT, facing +X)
		Vector3.new(-38, FLOOR, 28),
		Vector3.new(-35, FLOOR, 28.1),
		Vector3.new(-32, FLOOR, 28.6),
		Vector3.new(-29, FLOOR, 29.4),
		Vector3.new(-26, FLOOR, 30.2),
		Vector3.new(-23, FLOOR, 30.8), -- B: in front of the fin press, forks toward the rocket line
	}
	table.insert(routes, {
		id = "A6_Forklift",
		area = 6,
		modelKey = "A6_Forklift",
		rest = { build = "A6_Forklift", index = 1 },
		wheelRadius = 0.85,
		cargo = { { "Pallet", "Crates" } },
		unloadDir = Vector3.new(0, -0.3, -2.4),
		segments = {
			{ kind = "wait", duration = 2.6, load = { groups = { 1 }, at = 0.4 } },
			{ kind = "drive", points = shuttle, speed = 5, accel = 2, decel = 2.5 },
			{ kind = "wait", duration = 3, unload = { groups = { 1 }, at = 0.8 } },
			{
				kind = "drive",
				points = reversed(shuttle),
				reverse = true,
				speed = 4,
				accel = 2,
				decel = 2.5,
				beep = true,
			},
		},
		start = { segment = 1, at = 2.4 },
	})
end

do -- A6 belt toy rockets: carried along the conveyor (z 40, x 9..43) at belt speed.
	-- Direction matches the WorldFx belt texture scroll (Belt row speed 3, tests check it).
	local BELT_Y, BELT_Z = 3.65, 40 -- AreaLayouts/Area06 FLOOR + BELT_TOP
	local FROM_X, TO_X = 9.8, 42.2
	table.insert(routes, {
		id = "A6_BeltRockets",
		area = 6,
		modelKey = "A6_ToyRocket",
		rest = { build = "A6_Conveyor", index = 2 },
		followers = {
			{ placement = { build = "A6_Conveyor", index = 3 }, sync = "nearest" },
			{ placement = { build = "A6_Conveyor", index = 4 }, sync = "nearest" },
		},
		orient = "fixed",
		segments = {
			{
				kind = "drive",
				points = line(Vector3.new(FROM_X, BELT_Y, BELT_Z), Vector3.new(TO_X, BELT_Y, BELT_Z), 4),
				speed = 3,
				v0 = 3,
				v1 = 3,
				fadeIn = 1.2,
				fadeOut = 1.2,
			},
		},
		start = { segment = 1, nearest = true },
	})
end

do -- A8 shopper car: in from the road, the barrier lifts, parks nose-in, backs out, leaves.
	local DECK = 0.5 -- AreaLayouts/Area08 DECK
	local CAR_Y = DECK + 0.08 -- garage floor
	local LANE_X = 30.7 -- entrance lane between the corner pillar (27.6) and the booth (34.8)
	local REST_X, REST_Z = 45.3, 37.5 -- GARAGE (38.5, 44.5) * (6.8, -7)
	local BARRIER_Z = 21.7 -- GARAGE * (-4.3, -22.8)
	local function y(z: number): number
		return ground(z, CAR_Y)
	end
	local R = 10
	local enter = join(
		arc(Vector3.new(LANE_X - R, 0, ROAD_Z + R), R, -90, 0, y),
		line(Vector3.new(LANE_X, CAR_Y, ROAD_Z + R), Vector3.new(LANE_X, CAR_Y, 32), 3),
		arc(Vector3.new(LANE_X + 5.5, CAR_Y, 32), 5.5, 180, 90),
		line(Vector3.new(LANE_X + 5.5, CAR_Y, REST_Z), Vector3.new(REST_X, CAR_Y, REST_Z), 2)
	)
	local backOut = join(
		line(Vector3.new(REST_X, CAR_Y, REST_Z), Vector3.new(37, CAR_Y, REST_Z), 2),
		arc(Vector3.new(37, CAR_Y, REST_Z + 6), 6, -90, -180)
	)
	local leave = join(
		line(Vector3.new(31, CAR_Y, REST_Z + 6), Vector3.new(31, CAR_Y, 4), 3),
		arc(Vector3.new(41, 0, 4), 10, 180, 270, y)
	)
	table.insert(routes, {
		id = "A8_ShopperCar",
		area = 8,
		modelKey = "A8_ShopperCar",
		rest = { build = "A8_ParkingGarage", index = 2 },
		wheelRadius = 0.85,
		lights = true,
		honkChance = 0.4,
		gate = {
			modelKey = "A8_ParkingGarage",
			pieces = { "BarrierYellow", "BarrierBlack" },
			hinge = Vector3.new(-4.3, 2.4, -22.8),
			axis = Vector3.new(0, 0, 1),
			angle = -70,
		},
		segments = {
			{
				kind = "drive",
				points = road(-ROAD_END, LANE_X - R),
				speed = 13,
				v0 = 13,
				v1 = 6,
				fadeIn = FADE,
				decel = 4,
			},
			{
				kind = "drive",
				points = enter,
				speed = 6,
				v0 = 6,
				accel = 2.5,
				decel = 3,
				gate = {
					open = Vector3.new(LANE_X, CAR_Y, BARRIER_Z - 9),
					close = Vector3.new(LANE_X, CAR_Y, BARRIER_Z + 7),
				},
			},
			-- 3 shopping (the barrier closed behind the car)
			{ kind = "wait", duration = 12, signal = { side = 1, from = 10, to = 12 } },
			{ kind = "drive", points = backOut, reverse = true, speed = 3.5, accel = 2, decel = 2.5 },
			{ kind = "wait", duration = 0.8 },
			{
				kind = "drive",
				points = leave,
				speed = 6,
				v1 = 6,
				accel = 2.5,
				gate = { open = Vector3.new(31, CAR_Y, BARRIER_Z + 9), close = Vector3.new(31, CAR_Y, BARRIER_Z - 7) },
			},
			{ kind = "drive", points = road(41, ROAD_END), speed = 13, v0 = 6, v1 = 13, accel = 4, fadeOut = FADE },
			{ kind = "wait", duration = 7 },
		},
		start = { segment = 3, at = 6 },
	})
end

do -- Dino Valley D3 Ptero Post (owner R57): two ptero couriers on the nest deck (W7 art).
	--[[
		Geometry (slot-local, Worlds/Dino/Layouts/Area03): the Nest Tower stands at (0, 0.4, 50); its
		deck floor is y 20.6 (tower y + NEST_FLOOR 20.2), the twig rim tops out at y 21.4 at r 9, and
		the canopy hangs over the deck from y 26.4 (x -8.6 .. 8.4, z 42.5 .. 56). The couriers perch
		on their parcels (pivot = parcel bottom) facing straight out from the trunk:
			courier 1  (4.6, 20.6, 46.8)  yaw -55   (toward the landing pad)
			courier 2  (-4.8, 20.6, 48.4) yaw 71    (toward the rope bridge)
		Under the canopy a courier stays at y <= 21.6 (crest + flapping wing tips clear 26.4) and
		crosses the rim at y >= 21.6 (its parcel clears the twigs). Over the back jungle (z > 41.6:
		palm fronds up to y 15.5) it stays above y 16; over the PTERO POST arch (z 14.5 .. 21.5,
		|x| < 13.3, top 25.2) above y 25.6. tests/vehicle-routes.luau sweeps both against every
		piece box and collider of the area.

		Courier 1 "parcels OUT": perched -> flies out over the slot and hovers over the landing pad
		(28, 1.6, 34) -> drops its parcel onto the pad -> turns round -> flies home -> turns round on
		its perch -> a new parcel pops into its feet -> perched.
		Courier 2 "parcels IN": perched -> pushes its parcel into the nest -> turns toward the road ->
		climbs out over the walkway and the arch and fades into the sky over the road -> comes back
		with a new parcel -> lands -> turns round on its perch.
		Both share one 36 s clock (`sync`), so their nest moments never overlap: courier 2 leaves at
		1 s and is home by 23.6 s; courier 1 leaves at 12 s and is home by ~32 s.
		Sound (sparse, W10b): a cute squawk (`horn` = ptero_squawk_cute through the honk event) as
		courier 1 drops its parcel on the pad and as courier 2 lands home, each rolled per lap
		(honkChance 0.5): about one squawk every 36 s per nest; Reduce Motion parks both (silent).
	]]
	local SQUAWK = { key = "ptero_squawk_cute", volume = 0.8 }
	local DECK_Y = 20.6
	local function facing(yawDeg: number): Vector3
		local yaw = math.rad(yawDeg)
		return Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
	end
	local function lift(point: Vector3, y: number): Vector3
		return Vector3.new(point.X, y, point.Z)
	end
	local FLYER: Flyer = {
		wingLeft = "WingL",
		wingRight = "WingR",
		amplitude = 24,
		period = 0.6,
		restAmplitude = 3,
		restPeriod = 2.6,
		blendSeconds = 0.35,
		heave = 0.22,
		climbGain = 0.35,
		climbMax = 12,
	}

	-- Courier 1: out and back along its facing line (u = studs from the perch along it).
	local PERCH1 = Vector3.new(4.6, DECK_Y, 46.8)
	local OUT1 = facing(-55)
	local function along1(u: number, y: number): Vector3
		return lift(PERCH1 + OUT1 * u, y)
	end
	local toPad = {
		along1(0, DECK_Y),
		along1(1.5, DECK_Y), -- level first chord: leaves exactly on its perch heading
		along1(3.6, 21.6), -- over the rim
		along1(6.4, 21.6),
		along1(12, 21.4), -- clear of the canopy
		along1(16, 19.6),
		along1(20.5, 16.6), -- past the frond line: free to swoop down
		along1(24, 13.6),
		along1(27, 11.4),
		along1(30, 10), -- hover over the pad deck (8.3 above its paint)
	}
	local toNest = {
		along1(30, 10),
		along1(28, 10.6),
		along1(25, 12.6),
		along1(22, 15.2),
		along1(20, 17),
		along1(16, 19.6),
		along1(12, 21.4),
		along1(6.4, 21.6),
		along1(3.6, 21.6),
		along1(1.5, DECK_Y),
		along1(0, DECK_Y), -- level last chord: lands facing the trunk
	}
	table.insert(routes, {
		id = "D3_CourierOut",
		world = "dino",
		area = 3,
		modelKey = "D3_PteroCourier",
		rest = { build = "D3_NestTower", index = 2 },
		cargo = { { "Parcel", "ParcelTie" } },
		unloadDir = Vector3.new(0, -8.3, 0), -- the parcel drops onto the pad
		lean = 1.2,
		flyer = FLYER,
		horn = SQUAWK,
		honkChance = 0.5,
		period = 36,
		sync = "D3_Couriers",
		segments = {
			-- 1 perched (stretch: takes the loop's slack)
			{ kind = "wait", duration = 12, stretch = true },
			-- 2 out to the landing pad
			{ kind = "drive", points = toPad, speed = 9, accel = 2.8, decel = 2.4 },
			-- 3 hover, drop the parcel; 4 turn round
			{ kind = "wait", duration = 1.3, hover = true, unload = { groups = { 1 }, at = 0.35 }, honk = 0.3 },
			{ kind = "wait", duration = 1.6, hover = true, spin = 180 },
			-- 5 home
			{ kind = "drive", points = toNest, speed = 9, accel = 2.8, decel = 2.4 },
			-- 6 turn round on the perch; 7 a new parcel pops into its feet
			{ kind = "wait", duration = 1.8, hover = true, spin = 180 },
			{ kind = "wait", duration = 0.9, hover = true, load = { groups = { 1 }, at = 0.25 } },
		},
		start = { segment = 1, before = 12 },
	})

	-- Courier 2: turns toward the road (yaw 35), climbs out along x -7.6, fades over the road.
	local PERCH2 = Vector3.new(-4.8, DECK_Y, 48.4)
	local LEAVE2 = facing(35)
	local skyway = {
		Vector3.new(-7.3, 22, 41), -- off the rim (r 11.5)
		Vector3.new(-7.6, 22.1, 37), -- still under the canopy's reach: low
		Vector3.new(-7.6, 23.6, 31),
		Vector3.new(-7.6, 27, 25), -- over the arch (top 25.2)
		Vector3.new(-7.6, 29.6, 19),
		Vector3.new(-7.6, 32, 13),
		Vector3.new(-7.6, 34.6, 6),
		Vector3.new(-7.6, 36.6, 0),
		Vector3.new(-7.6, 38, -5),
		Vector3.new(-7.6, 39, -10), -- faded out above the road
	}
	local leave = join({
		PERCH2,
		PERCH2 + LEAVE2 * 1.5,
		Vector3.new(-6.55, 21.6, 44.6), -- over the rim (r 8.5)
	}, skyway)
	local arrive = join(reversed(skyway), {
		Vector3.new(-6.55, 21.9, 44.6), -- the parcel clears the rim
		lift(PERCH2 + LEAVE2 * 1.5, 20.9),
		PERCH2,
	})
	table.insert(routes, {
		id = "D3_CourierIn",
		world = "dino",
		area = 3,
		modelKey = "D3_PteroCourier",
		rest = { build = "D3_NestTower", index = 3 },
		cargo = { { "Parcel", "ParcelTie" } },
		unloadDir = Vector3.new(0, 0.2, 2.4), -- pushed back into the nest pile
		lean = 1.2,
		flyer = FLYER,
		horn = SQUAWK,
		honkChance = 0.5,
		period = 36,
		sync = "D3_Couriers",
		segments = {
			-- 1 perched
			{ kind = "wait", duration = 13.4 },
			-- 2 parcel into the nest; 3 turn toward the road (71 -> 35)
			{ kind = "wait", duration = 1, hover = true, unload = { groups = { 1 }, at = 0.15 } },
			{ kind = "wait", duration = 1, hover = true, spin = -36 },
			-- 4 up, over the arch, away into the sky
			{ kind = "drive", points = leave, speed = 11, v1 = 11, accel = 3, fadeOut = 11 },
			-- 5 off screen: pick up a new parcel (stretch)
			{ kind = "wait", duration = 2, stretch = true, load = { groups = { 1 }, at = 0.2 } },
			-- 6 back from the sky, land facing the trunk
			{ kind = "drive", points = arrive, speed = 11, v0 = 11, decel = 2.6, fadeIn = 11 },
			-- 7 turn round on the parcel (-145 -> 71)
			{ kind = "wait", duration = 1.6, hover = true, spin = -144, honk = 0.2 },
		},
		start = { segment = 1, before = 1 },
	})
end

do -- Moon Base M3 UFO couriers (owner R70, W7): parcels OUT to the tractor pad, parcels IN via the launch ring.
	--[[
		Geometry (slot-local, Worlds/Moon/Layouts/Area03): the Saucer Dock stands at (0, 0.4, 50); its
		landing deck top is y 10.8 (DECK_TOP 10.4 + FLOOR), the coral rim reaches r 8.8. The UFOs park
		on their landing feet (pivot) facing straight out from the dock:
			courier 1  (4.4, 10.8, 48.4)   yaw -58.6  (toward the tractor-beam pad)
			courier 2  (-4.4, 10.8, 51.6)  yaw 60     (toward the launch ring)
		The tractor beam (pad (28, 0.4, 34)) rises to y 6.4: courier 1 hovers over it at y 7.6 and drops
		its parcel through the beam. Courier 2 climbs off the deck, threads the candy launch ring
		(centre (-16.5, 16.4, 31), hole radius 5.95; its eight arc pieces' boxes leave the middle
		clear) heading straight for the road, passes the UFO DELIVERY arch at x -16.5 (the arch's
		frame ends at |x| 12.3) and fades out over the road. It comes back the same way.
		Both share one 36 s clock (`sync`), so the deck moments never overlap (same choreography as
		the Dino D3 ptero couriers). Sound: H1's `ufo_whirr` (`horn` through the honk event) as
		courier 1 drops its parcel and as courier 2 lands home, rolled per lap (honkChance 0.5).
		Fins: FinL / FinR (balanced on the centre line) wiggle through the flyer hook (small angle).
	]]
	local WHIRR = { key = "ufo_whirr", volume = 0.7 }
	local DECK_Y = 10.8
	local function facing(yawDeg: number): Vector3
		local yaw = math.rad(yawDeg)
		return Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
	end
	local function lift(point: Vector3, y: number): Vector3
		return Vector3.new(point.X, y, point.Z)
	end
	local UFO: Flyer = {
		wingLeft = "FinL",
		wingRight = "FinR",
		amplitude = 10,
		period = 0.9,
		restAmplitude = 2,
		restPeriod = 2.6,
		blendSeconds = 0.35,
		heave = 0.25,
		climbGain = 0.25,
		climbMax = 8,
	}

	-- Courier 1: out and back along its facing line (u = studs from the parking spot along it).
	local PARK1 = Vector3.new(4.4, DECK_Y, 48.4)
	local OUT1 = facing(-58.6)
	local function along1(u: number, y: number): Vector3
		return lift(PARK1 + OUT1 * u, y)
	end
	local toPad = {
		along1(0, DECK_Y),
		along1(1.5, DECK_Y), -- level first chord: leaves exactly on its parking heading
		along1(4.0, 11.4), -- over the rim
		along1(7.0, 11.6),
		along1(12, 11.4), -- over the parcel pod (top y 4.1)
		along1(17, 10.4),
		along1(21, 9.2),
		along1(24.5, 8.2),
		along1(27.65, 7.6), -- hover over the pad centre, 1.2 above the beam top
	}
	table.insert(routes, {
		id = "M3_CourierOut",
		world = "moon",
		area = 3,
		modelKey = "M3_UfoCourier",
		rest = { build = "M3_SaucerDock", index = 2 },
		cargo = { { "Parcel", "ParcelTie" } },
		unloadDir = Vector3.new(0, -6.6, 0), -- the parcel sinks down the beam onto the pad
		lean = 1,
		flyer = UFO,
		horn = WHIRR,
		honkChance = 0.5,
		period = 36,
		sync = "M3_Couriers",
		segments = {
			-- 1 parked (stretch: takes the loop's slack)
			{ kind = "wait", duration = 12, stretch = true },
			-- 2 out to the tractor pad
			{ kind = "drive", points = toPad, speed = 9, accel = 2.8, decel = 2.4 },
			-- 3 hover, drop the parcel; 4 turn round
			{ kind = "wait", duration = 1.3, hover = true, unload = { groups = { 1 }, at = 0.35 }, honk = 0.3 },
			{ kind = "wait", duration = 1.6, hover = true, spin = 180 },
			-- 5 home
			{ kind = "drive", points = reversed(toPad), speed = 9, accel = 2.8, decel = 2.4 },
			-- 6 turn round on the deck; 7 a new parcel pops into its clamp
			{ kind = "wait", duration = 1.8, hover = true, spin = 180 },
			{ kind = "wait", duration = 0.9, hover = true, load = { groups = { 1 }, at = 0.25 } },
		},
		start = { segment = 1, before = 12 },
	})

	-- Courier 2: off the deck toward -X, through the launch ring, over the arch, away over the road.
	local PARK2 = Vector3.new(-4.4, DECK_Y, 51.6)
	local LEAVE2 = facing(60)
	local RING_X = -16.5
	local skyway = {
		Vector3.new(-8.6, 11.6, 49.1), -- off the rim (r 8.7)
		Vector3.new(-12.0, 12.8, 45.0),
		Vector3.new(-14.9, 13.9, 40.0),
		Vector3.new(-16.3, 14.5, 35.5),
		Vector3.new(RING_X, 14.75, 31), -- through the ring's middle (pivot 1.65 under its centre)
		Vector3.new(RING_X, 15.2, 27),
		Vector3.new(RING_X, 17.0, 23),
		Vector3.new(RING_X, 20.0, 18), -- past the arch
		Vector3.new(RING_X, 23.5, 12),
		Vector3.new(RING_X, 27.0, 5),
		Vector3.new(RING_X, 30.0, -1),
		Vector3.new(RING_X, 32.0, -6),
		Vector3.new(RING_X, 33.0, -11), -- faded out above the road
	}
	local leave = join({ PARK2, PARK2 + LEAVE2 * 1.5 }, skyway)
	local arrive = reversed(leave)
	table.insert(routes, {
		id = "M3_CourierIn",
		world = "moon",
		area = 3,
		modelKey = "M3_UfoCourier",
		rest = { build = "M3_SaucerDock", index = 3 },
		cargo = { { "Parcel", "ParcelTie" } },
		unloadDir = Vector3.new(2.6, 0, 2.2), -- popped into the dock's parcel elevator (behind-right)
		lean = 1,
		flyer = UFO,
		horn = WHIRR,
		honkChance = 0.5,
		period = 36,
		sync = "M3_Couriers",
		segments = {
			-- 1 parked (its legs are ~8.5 s each: the longest flight in the game, so a shorter rest)
			{ kind = "wait", duration = 11 },
			-- 2 parcel into the elevator
			{ kind = "wait", duration = 1, hover = true, unload = { groups = { 1 }, at = 0.15 } },
			-- 3 up, through the ring, over the arch, away into the sky
			{ kind = "drive", points = leave, speed = 11, v1 = 11, accel = 3, fadeOut = 11 },
			-- 4 off screen: pick up a new parcel (stretch)
			{ kind = "wait", duration = 2, stretch = true, load = { groups = { 1 }, at = 0.2 } },
			-- 5 back through the ring, land facing out again
			{ kind = "drive", points = arrive, speed = 11, v0 = 11, decel = 2.6, fadeIn = 11 },
			-- 6 settle on the deck (lands facing back toward the ring: turn round on the spot)
			{ kind = "wait", duration = 1.6, hover = true, spin = 180, honk = 0.2 },
		},
		start = { segment = 1, before = 1 },
	})
end

do -- Moon Base M4 ore carts (owner R70, W7): a two-cart train round the oval loop.
	--[[
		Geometry (slot-local, Worlds/Moon/Layouts/Area04): the loop (M4_CartTrack at (22.5, 0.4, 45))
		has straights at x 14 (driven +Z) and x 31 (driven -Z), z 40 .. 50, joined by r 8.5
		semicircles; rail top y 0.7 (FLOOR 0.4 + RAIL_TOP 0.3). The lead cart rests under the Drill
		Rig's crystal chute at (14, 0.7, 49.2) heading +Z; the second is coupled 5.2 behind.
		Loop: load crystals at the chute -> round the back bend -> stop beside the Crystal Sorter on
		the x 31 straight, tip toward +X (the sorter's hopper front is x 32.8) -> round the front bend
		-> back under the chute. No colliders on the loop (the sorter's boxes start at x 35).
	]]
	local Y = 0.7
	local LOAD = Vector3.new(14, Y, 49.2)
	local SORT = Vector3.new(31, Y, 45)
	local out = join(
		line(LOAD, Vector3.new(14, Y, 50), 1),
		arc(Vector3.new(22.5, Y, 50), 8.5, 180, 0),
		line(Vector3.new(31, Y, 50), SORT, 2)
	)
	local back = join(
		line(SORT, Vector3.new(31, Y, 40), 2),
		arc(Vector3.new(22.5, Y, 40), 8.5, 0, -180),
		line(Vector3.new(14, Y, 40), LOAD, 2)
	)
	table.insert(routes, {
		id = "M4_Carts",
		world = "moon",
		area = 4,
		modelKey = "M4_OreCart",
		rest = { build = "M4_OreCarts", index = 2 },
		followers = { { placement = { build = "M4_OreCarts", index = 3 }, gap = 5.2 } },
		wheelRadius = 0.45,
		cargo = { { "Ore", "OreCyan" } },
		unloadDir = Vector3.new(2.8, 0.6, 0),
		tipSide = 1,
		tipHinge = Vector3.new(1.3, 0.8, 0),
		segments = {
			-- 1 under the chute: fresh crystals pop in
			{ kind = "wait", duration = 3, load = { groups = { 1 }, at = 1 } },
			-- 2 round the back bend to the sorter
			{ kind = "drive", points = out, speed = 4.5, accel = 2, decel = 2.5 },
			-- 3 tip the crystals into the sorter's hopper
			{
				kind = "wait",
				duration = 6,
				tip = { at = 0.8, duration = 3.4, angle = 28 },
				unload = { groups = { 1 }, at = 1.5 },
			},
			-- 4 round the front bend, back under the chute
			{ kind = "drive", points = back, speed = 4.5, accel = 2, decel = 2.5 },
		},
		-- 2 s into the load wait: the crystals popped in at 1 s and have settled (the authored look).
		start = { segment = 1, at = 2 },
	})
end

VehicleRouteConfig.Routes = routes

-- Lookups.
local byId: { [string]: Route } = {}
local byKey: { [string]: { Route } } = {}
local routedModels: { [string]: boolean } = {}
for _, route in routes do
	byId[route.id] = route
	local list = byKey[route.modelKey]
	if list == nil then
		list = {}
		byKey[route.modelKey] = list
	end
	table.insert(list, route)
	routedModels[route.modelKey] = true
end
VehicleRouteConfig.byId = byId
VehicleRouteConfig.byKey = byKey
-- Every model key a route drives (WorldFxConfig.RoutedModels must equal this; tests check it).
VehicleRouteConfig.RoutedModels = routedModels

return VehicleRouteConfig
