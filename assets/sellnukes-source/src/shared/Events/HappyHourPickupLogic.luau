--!strict
--[[
	HappyHourPickupLogic — the shared, pure maths of the Happy Hour pickups (owner R89 §2: Confetti
	Storm coins, Egg Stampede eggs, Low-Gravity moon rocks; docs/happy-hours.md).

	Why shared: the server validates a collection against WHERE the pickup is at the server's
	time, and the client animates it from the same wire with the same maths, so a falling coin or a
	running egg costs zero replication and zero physics (the Golden Turkey pattern:
	Server/Event/TurkeySpawner + EventConfig.pose). "run" pickups literally reuse the turkey path
	maths — a run wire is compiled with EventConfig.compilePath and posed with EventConfig.pose.

	Motion styles (HappyHourConfig.PickupDef.style):
		fall    drops from `dropHeight` above points[1] onto it in `fallSeconds` (ease-in), then rests
		float   hangs at points[1] (the client adds a cosmetic bob)
		run     loops through points (closed loop) at runSpeed with runPause at each waypoint

	API:
		readWire(raw) -> Wire?                     validates a wire (client: defence in depth)
		compile(wire) -> Compiled                  pre-processed motion (run: a turkey path)
		position(compiled, t) -> (Vector3, alive)  where the pickup's centre is at server time t
		distance(compiled, t, root, lags) -> number  min distance from a character root over lag
		                                           samples (XZ + height beyond the vertical
		                                           tolerance: Float* for floating pickups)
		validId(id) -> boolean                     "H<digits>" shape (cheap pre-check)
		spawnCount(def, live, spawned) -> number   how many may spawn now (batch / live / event caps)
		nextDelay(def, r) -> number                seconds to the next spawn for r in [0, 1)
		rollGolden(def, goldenSoFar, r) -> boolean golden roll with the per-event cap
		ringPoint(origin, rMin, rMax, a, r) -> Vector3   a point on a ring round `origin`
		runLoop(center, forward, spread, side) -> { Vector3 }  a 3-point loop along `forward`

	Example:
		local wire = HappyHourPickupLogic.readWire(payload.pickup)
		local compiled = HappyHourPickupLogic.compile(wire)
		local position, alive = HappyHourPickupLogic.position(compiled, workspace:GetServerTimeNow())
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EventConfig = require(ReplicatedStorage.Shared.Config.EventConfig)
local HappyHourConfig = require(ReplicatedStorage.Shared.Config.HappyHourConfig)

type EventId = HappyHourConfig.EventId
type PickupDef = HappyHourConfig.PickupDef

-- One pickup as sent to its owner (HappyHour { kind = "spawn", pickup = Wire }).
export type Wire = {
	id: string,
	event: EventId,
	style: HappyHourConfig.PickupStyle,
	golden: boolean,
	points: { Vector3 }, -- fall: rest point; float: hover point; run: loop waypoints
	t0: number, -- server time it appeared (Workspace:GetServerTimeNow())
	life: number, -- seconds it lives
}

-- A wire pre-processed for posing.
export type Compiled = {
	wire: Wire,
	def: PickupDef,
	ends: number,
	path: EventConfig.CompiledPath?, -- run only (the Golden Turkey path maths)
}

local Pickups = HappyHourConfig.Pickups

local HappyHourPickupLogic = {}

-- True for a finite number.
local function finite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- True for a Vector3 with finite components inside a sane world box.
local function goodVector(value: unknown): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local v = value :: Vector3
	return finite(v.X)
		and finite(v.Y)
		and finite(v.Z)
		and math.abs(v.X) < 1e5
		and math.abs(v.Y) < 1e5
		and math.abs(v.Z) < 1e5
end

--[[
	True for an id of the pickup shape ("H" + digits, short).
	Example: HappyHourPickupLogic.validId("H12") --> true
]]
function HappyHourPickupLogic.validId(id: unknown): boolean
	if type(id) ~= "string" or #id < 2 or #id > Pickups.IdMaxLength then
		return false
	end
	return string.sub(id, 1, #Pickups.IdPrefix) == Pickups.IdPrefix
		and string.find(id, "^%d+$", #Pickups.IdPrefix + 1) ~= nil
end

--[[
	Validates a pickup wire (shape, known event with a pickup, matching style, bounded points /
	life, finite numbers).
	@return a clean Wire, or nil when anything is malformed
]]
function HappyHourPickupLogic.readWire(raw: unknown): Wire?
	if type(raw) ~= "table" then
		return nil
	end
	local data = raw :: { [string]: unknown }
	local def = HappyHourConfig.get(data.event)
	local pickup = if def ~= nil then def.pickup else nil
	if def == nil or pickup == nil then
		return nil
	end
	if not HappyHourPickupLogic.validId(data.id) or data.style ~= pickup.style then
		return nil
	end
	if not finite(data.t0) or not finite(data.life) then
		return nil
	end
	local life = data.life :: number
	if life <= 0 or life > Pickups.MaxLife then
		return nil
	end
	local rawPoints = data.points
	if type(rawPoints) ~= "table" then
		return nil
	end
	local points: { Vector3 } = {}
	local count = 0
	for index, value in rawPoints :: { unknown } do
		if type(index) ~= "number" or index > Pickups.MaxPoints or not goodVector(value) then
			return nil
		end
		points[index] = value :: Vector3
		count += 1
	end
	-- A dense array only (a hole would make #points ambiguous).
	local needed = if pickup.style == "run" then 2 else 1
	if count ~= #points or #points < needed then
		return nil
	end
	return {
		id = data.id :: string,
		event = def.id,
		style = pickup.style,
		golden = data.golden == true,
		points = points,
		t0 = data.t0 :: number,
		life = life,
	}
end

--[[
	Pre-processes a wire for posing (a run wire becomes a Golden Turkey path).
	@param wire a server-built or readWire'd Wire (its event must have a pickup)
]]
function HappyHourPickupLogic.compile(wire: Wire): Compiled
	local def = HappyHourConfig.Events[wire.event].pickup :: PickupDef
	local path: EventConfig.CompiledPath? = nil
	if wire.style == "run" then
		path = EventConfig.compilePath({
			id = wire.id,
			zone = "plot",
			points = wire.points,
			t0 = wire.t0,
			speed = def.runSpeed or 8,
			pause = def.runPause or 0,
			life = wire.life,
			owner = 0,
			lure = false,
		})
	end
	return { wire = wire, def = def, ends = wire.t0 + wire.life, path = path }
end

--[[
	Where the pickup's centre is at server time `t`.
	@return (position, alive) — alive = false before t0 / at or after t0 + life
	Example: local position, alive = HappyHourPickupLogic.position(compiled, now)
]]
function HappyHourPickupLogic.position(compiled: Compiled, t: number): (Vector3, boolean)
	local wire = compiled.wire
	local alive = t >= wire.t0 and t < compiled.ends
	local path = compiled.path
	if path ~= nil then
		return EventConfig.pose(path, t).position, alive
	end
	local rest = wire.points[1]
	if wire.style == "fall" then
		local def = compiled.def
		local seconds = math.max(def.fallSeconds or 1, 0.05)
		local p = math.clamp((t - wire.t0) / seconds, 0, 1)
		-- Ease-in drop: slow out of the cloud, fast onto the ground.
		local height = (def.dropHeight or 0) * (1 - p * p)
		return rest + Vector3.new(0, height, 0), alive
	end
	return rest, alive
end

--[[
	Smallest distance from a character root to the pickup at `t - lag` for each lag sample: XZ
	distance plus the height difference beyond Pickups.VerticalTolerance (root vs centre;
	FloatVerticalTolerance for a floating pickup, so it takes a jump).
	@return studs (math.huge when the pickup is not alive at any sample)
]]
function HappyHourPickupLogic.distance(compiled: Compiled, t: number, root: Vector3, lags: { number }): number
	local best = math.huge
	local tolerance = if compiled.wire.style == "float"
		then Pickups.FloatVerticalTolerance
		else Pickups.VerticalTolerance
	for _, lag in lags do
		local position, alive = HappyHourPickupLogic.position(compiled, t - lag)
		-- A lag sample just before t0 + life still counts (the client saw it alive).
		if alive or (lag > 0 and t < compiled.ends + lag) then
			local delta = root - position
			local flat = Vector3.new(delta.X, 0, delta.Z).Magnitude
			local distance = flat + math.max(0, math.abs(delta.Y) - tolerance)
			if distance < best then
				best = distance
			end
		end
	end
	return best
end

--[[
	How many pickups may spawn for a player right now: a batch, bounded by the live cap and the
	per-event cap.
	Example: HappyHourPickupLogic.spawnCount(def, 3, 29) --> 1 (confetti: maxLive 4, maxPerEvent 30)
]]
function HappyHourPickupLogic.spawnCount(def: PickupDef, live: number, spawned: number): number
	return math.max(0, math.min(def.batch, def.maxLive - live, def.maxPerEvent - spawned))
end

--[[ Seconds until the next spawn for a uniform r in [0, 1). ]]
function HappyHourPickupLogic.nextDelay(def: PickupDef, r: number): number
	local low, high = def.intervalMin, math.max(def.intervalMin, def.intervalMax)
	return low + math.clamp(r, 0, 1) * (high - low)
end

--[[ Golden roll for a uniform r in [0, 1): r < goldenChance while under the per-event cap. ]]
function HappyHourPickupLogic.rollGolden(def: PickupDef, goldenSoFar: number, r: number): boolean
	return goldenSoFar < def.maxGoldenPerEvent and r < def.goldenChance
end

--[[
	A point on a flat ring round `origin`: angle a (radians), radius lerp(rMin, rMax, r).
	Example: HappyHourPickupLogic.ringPoint(root, 8, 22, math.pi, 0.5) --> 15 studs behind on -X
]]
function HappyHourPickupLogic.ringPoint(origin: Vector3, rMin: number, rMax: number, a: number, r: number): Vector3
	local radius = rMin + math.clamp(r, 0, 1) * (rMax - rMin)
	return origin + Vector3.new(math.cos(a) * radius, 0, math.sin(a) * radius)
end

--[[
	A closed 3-point loop for a running pickup: along `forward` (unit XZ) from -spread to +spread
	round `center`, swinging out `side` studs sideways on the way back (a lap, not a line).
	@return { start, far end, back swing }
]]
function HappyHourPickupLogic.runLoop(center: Vector3, forward: Vector3, spread: number, side: number): { Vector3 }
	local flat = Vector3.new(forward.X, 0, forward.Z)
	local dir = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
	local right = Vector3.new(-dir.Z, 0, dir.X)
	return {
		center - dir * spread,
		center + dir * spread,
		center + right * side,
	}
end

return table.freeze(HappyHourPickupLogic)
