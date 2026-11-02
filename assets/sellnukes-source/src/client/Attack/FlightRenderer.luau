--!strict
--[[
	FlightRenderer — draws every nuke flight locally from the server's one-shot NukeFlight timeline
	(spec §9: "clients only render the arc"): the rising nuke with its smoke trail, the AA
	turret swinging round, every interceptor (misses fly past and puff, the last one of an
	intercepted flight meets it), and the outcome (mid-air POP! or the confetti mushroom cloud).

	Determinism: positions come from Shared/Attack/AttackGeometry.flight (the same function the
	server used) evaluated at Workspace:GetServerTimeNow() - t0, so every client shows the nuke in
	the same place at the same time and the interception happens exactly where the server
	decided. Nothing here can influence an outcome.

	Owner R80 multi-tower defence: a flight carries one volley per defending tower that fired
	(tower 0 = the HQ / rival / bot turret, 1.. = a defence slot tower). Each volley's
	interceptors leave THAT tower's muzzle (AttackGeometry.muzzle(slot, tower)) and that tower's
	turret swings round while it engages; the volley flagged `hit` ends with the hit.
	Owner R106: the tower rigs belong to Client/Attack/TowerAnim (idle scan, dish, recoil, muzzle
	flash, one loop for every tower); this renderer only tells it where each engaging tower aims
	(TowerAnim.aim, every frame of the engagement) and when a shot leaves (TowerAnim.fire).

	Performance:
		* ONE PreRender connection, alive only while flights are active.
		* All nuke + interceptor parts move with ONE Workspace:BulkMoveTo per frame (no per-model
		  PivotTo, no property events beyond CFrame).
		* Models are pooled clones of ReplicatedStorage.AttackTemplates (Nuke1..5, Interceptor),
		  parked far below the map when idle; trails are disabled + cleared before every reuse so
		  no streak is drawn from the parking spot. Pools grow on demand up to MAX_ACTIVE.
		* Flights whose launch and impact are both beyond AttackConfig.Client.RenderDistance from
		  the camera are not drawn at all (the server toast still tells the story).

	Connects to: Shared/Attack/{AttackGeometry, FlightMath}, Shared/Config/AttackConfig,
	Client/Attack/{AttackClient (add), AttackFx (outcomes, sounds), TowerAnim (tower aim / shots),
	SiloLaunch (owner R109: the silo rocket lifts off and flies the first HandOff seconds)}.

	Example:
		FlightRenderer.start()
		FlightRenderer.add(flightData, Players.LocalPlayer.UserId)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local AttackConfig = require(ReplicatedStorage.Shared.Config.AttackConfig)
local AttackFx = require(script.Parent.AttackFx)
local AttackGeometry = require(ReplicatedStorage.Shared.Attack.AttackGeometry)
local AttackRng = require(ReplicatedStorage.Shared.Attack.AttackRng)
local FlightMath = require(ReplicatedStorage.Shared.Attack.FlightMath)
local SiloLaunch = require(script.Parent.SiloLaunch)
local TowerAnim = require(script.Parent.TowerAnim)

local FlightRenderer = {}

local CLIENT = AttackConfig.Client
local FLIGHT = AttackConfig.Flight
local PARK = CFrame.new(0, -4000, 0)
-- Rotates a lookAt frame (-Z forward) so the model's +Y (nose) points forward.
local NOSE_UP = CFrame.Angles(-math.pi / 2, 0, 0)
-- Hard bound on drawn models (nukes + interceptors) at once.
local MAX_ACTIVE = 72
-- Seconds a missed interceptor keeps flying past the nuke before it puffs.
local MISS_COAST = 0.35
-- Studs a missed interceptor passes beside the nuke.
local MISS_OFFSET = 7
-- Owner R80: defence tower slots per plot (towers 1..TOWER_SLOTS, plus the HQ tower 0).
local TOWER_SLOTS = #AttackConfig.Towers.Slots

-- One defending tower's shots at a flight (NukeFlight `volleys`, owner R80).
export type Volley = {
	tower: number, -- 0 = HQ / rival / bot turret, 1.. = defence slot
	shots: number,
	firstShot: number, -- relative fire time of its first interceptor
	reload: number,
	hit: boolean, -- its last shot is the hit
}

export type FlightData = {
	id: number,
	fromUserId: number,
	toUserId: number,
	t0: number,
	duration: number,
	intercepted: boolean,
	interceptAt: number,
	kind: string,
	fromPlot: number,
	toPlot: number,
	silo: number,
	impact: number,
	-- Owner R50 aiming: the aimed area / rival section (0 = legacy impact index) + scatter (studs).
	area: number,
	sx: number,
	sz: number,
	-- Owner R51 admin test bots: the attacking / attacked bot's key ("bot:3"), else nil.
	fromBot: string?,
	toBot: string?,
	tier: number,
	shots: number,
	firstShot: number,
	reload: number,
	volleys: { Volley }?, -- owner R80; nil / empty = the legacy single-tower fields above
}

type Pooled = {
	model: Model,
	parts: { BasePart },
	offsets: { CFrame },
	trails: { Trail },
	emitters: { ParticleEmitter },
	key: string,
}

type Shot = {
	tower: number, -- the firing tower (owner R80; its turret aims while this shot engages)
	fireAt: number, -- relative to t0
	meetAt: number,
	hit: boolean,
	from: Vector3,
	to: Vector3, -- meeting point (hit) or the pass-by point (miss)
	model: Pooled?,
	fired: boolean,
	done: boolean,
}

type Active = {
	data: FlightData,
	flight: FlightMath.Flight,
	endAt: number, -- relative outcome time
	model: Pooled?,
	shots: { Shot },
	started: boolean,
	-- Owner R109: seconds after t0 the launching silo's own rocket flies before this nuke is drawn
	-- (Client/Attack/SiloLaunch hand-off; 0 = drawn from t0) and whether the nuke model is shown.
	handOff: number,
	shown: boolean,
	drawn: boolean,
	mine: boolean,
	onMe: boolean,
}

local active: { Active } = {}
local pools: { [string]: { Pooled } } = {}
local drawnCount = 0
local connection: RBXScriptConnection? = nil
local folder: Folder? = nil
local started = false

-- Reused per-frame BulkMoveTo buffers (cleared, never reallocated).
local moveParts: { BasePart } = {}
local moveFrames: { CFrame } = {}

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function fxFolder(): Folder
	local existing = folder
	if existing ~= nil and existing.Parent ~= nil then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = "SN_AttackFlights"
	created.Parent = Workspace
	folder = created
	return created
end

--------------------------------------------------------------------------------------------------
-- Pools
--------------------------------------------------------------------------------------------------

-- The replicated template for a pool key ("Nuke3", "Interceptor"), or nil while not there yet.
local function template(key: string): Model?
	local templates = ReplicatedStorage:FindFirstChild(AttackConfig.TemplateFolder)
	local model = if templates ~= nil then templates:FindFirstChild(key) else nil
	return if model ~= nil and model:IsA("Model") then model else nil
end

-- Adds a smoke trail + exhaust sparks at the model's tail (pivot) to a fresh clone.
local function dress(model: Model, pooled: Pooled, interceptor: boolean)
	local body = pooled.parts[1]
	if body == nil then
		return
	end
	-- Largest part carries the attachments (most stable anchor).
	for _, part in pooled.parts do
		if part.Size.Magnitude > body.Size.Magnitude then
			body = part
		end
	end
	local pivot = model:GetPivot()
	local tail = body.CFrame:PointToObjectSpace(pivot.Position)
	local width = if interceptor then 0.5 else 1.4
	local a0 = Instance.new("Attachment")
	a0.Name = "TrailA"
	a0.Position = tail + body.CFrame:VectorToObjectSpace(pivot.RightVector * width)
	a0.Parent = body
	local a1 = Instance.new("Attachment")
	a1.Name = "TrailB"
	a1.Position = tail - body.CFrame:VectorToObjectSpace(pivot.RightVector * width)
	a1.Parent = body
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.FaceCamera = true
	trail.Lifetime = if interceptor then 0.35 else 0.9
	trail.MinLength = 0.2
	trail.LightEmission = 0.25
	trail.Color = if interceptor
		then ColorSequence.new(Color3.fromRGB(230, 245, 255))
		else ColorSequence.new(Color3.fromRGB(255, 250, 235), Color3.fromRGB(210, 215, 225))
	trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(1, 1) })
	trail.WidthScale = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 2.4) })
	trail.Enabled = false
	trail.Parent = body
	table.insert(pooled.trails, trail)

	local flame = Instance.new("ParticleEmitter")
	flame.Name = "Exhaust"
	flame.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	flame.Color = ColorSequence.new(Color3.fromRGB(255, 220, 90), Color3.fromRGB(255, 120, 40))
	flame.LightEmission = 0.8
	flame.LightInfluence = 0
	flame.Rate = if interceptor then 20 else 45
	flame.Lifetime = NumberRange.new(0.15, 0.3)
	flame.Speed = NumberRange.new(2, 5)
	flame.SpreadAngle = Vector2.new(25, 25)
	flame.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, if interceptor then 0.8 else 2),
		NumberSequenceKeypoint.new(1, 0),
	})
	flame.EmissionDirection = Enum.NormalId.Bottom
	flame.Enabled = false
	local mid = Instance.new("Attachment")
	mid.Name = "Exhaust"
	mid.Position = tail
	mid.Parent = body
	flame.Parent = mid
	table.insert(pooled.emitters, flame)
end

-- A pooled model for `key`, or nil (template missing / over budget).
local function acquire(key: string): Pooled?
	if drawnCount >= MAX_ACTIVE then
		return nil
	end
	local pool = pools[key]
	if pool == nil then
		pool = {}
		pools[key] = pool
	end
	local pooled = table.remove(pool :: { Pooled })
	if pooled == nil then
		local source = template(key)
		if source == nil then
			return nil
		end
		local model = source:Clone()
		local pivot = model:GetPivot()
		local created: Pooled = { model = model, parts = {}, offsets = {}, trails = {}, emitters = {}, key = key }
		for _, item in model:GetDescendants() do
			if item:IsA("BasePart") then
				item.Anchored = true
				item.CanCollide = false
				item.CanQuery = false
				item.CanTouch = false
				item.CastShadow = false
				table.insert(created.parts, item)
				local offset: CFrame = pivot:ToObjectSpace(item.CFrame)
				table.insert(created.offsets, offset)
			end
		end
		dress(model, created, key == "Interceptor")
		model:PivotTo(PARK)
		model.Parent = fxFolder()
		pooled = created
	end
	drawnCount += 1
	return pooled
end

-- Returns a model to its pool (trails off + cleared, parked).
local function release(pooled: Pooled)
	for _, trail in pooled.trails do
		trail.Enabled = false
	end
	for _, emitter in pooled.emitters do
		emitter.Enabled = false
	end
	pooled.model:PivotTo(PARK)
	for _, trail in pooled.trails do
		trail:Clear()
	end
	drawnCount -= 1
	table.insert(pools[pooled.key], pooled)
end

-- Queues a pooled model's parts at `pivot` for this frame's BulkMoveTo.
local function place(pooled: Pooled, pivot: CFrame)
	for index, part in pooled.parts do
		table.insert(moveParts, part)
		table.insert(moveFrames, pivot * pooled.offsets[index])
	end
end

-- Moves a model right now (first placement before its trail is switched on).
local function placeNow(pooled: Pooled, pivot: CFrame)
	pooled.model:PivotTo(pivot)
	for _, trail in pooled.trails do
		trail:Clear()
		trail.Enabled = true
	end
	for _, emitter in pooled.emitters do
		emitter.Enabled = true
	end
end

-- Pivot of a model flying along `velocity` (nose = +Y) at `position`.
local function along(position: Vector3, velocity: Vector3): CFrame
	if velocity.Magnitude < 1e-3 then
		return CFrame.new(position)
	end
	return CFrame.lookAt(position, position + velocity) * NOSE_UP
end

--------------------------------------------------------------------------------------------------
-- Frame step
--------------------------------------------------------------------------------------------------

-- Ends a flight: outcome FX and model release.
local function finish(entry: Active)
	local data = entry.data
	if entry.model ~= nil then
		release(entry.model)
		entry.model = nil
	end
	for _, shot in entry.shots do
		if shot.model ~= nil then
			release(shot.model)
			shot.model = nil
		end
	end
	if not entry.drawn then
		return
	end
	if data.intercepted then
		AttackFx.pop(FlightMath.position(entry.flight, data.interceptAt))
	else
		AttackFx.explode(entry.flight.to, {
			plot = data.toPlot,
			mine = entry.mine,
			onMe = entry.onMe,
			-- Owner R85: a golden revenge nuke ends in an extra-big confetti blast.
			scale = if data.kind == "golden" then AttackConfig.Golden.ExplosionScale else 0.85 + data.tier * 0.1,
		})
	end
end

-- Interceptor position at relative time `rel` (fired, not done).
local function shotPosition(shot: Shot, rel: number): (Vector3, Vector3)
	local travel = FLIGHT.InterceptorSeconds
	local k = (rel - shot.fireAt) / travel
	-- Gentle arc: up first, then onto the meeting point.
	local lift = Vector3.new(0, (shot.to - shot.from).Magnitude * 0.18, 0)
	local function point(u: number): Vector3
		local a = shot.from:Lerp(shot.from + lift, u)
		local b = (shot.from + lift):Lerp(shot.to, u)
		return a:Lerp(b, u)
	end
	if k <= 1 then
		local p = point(math.clamp(k, 0, 1))
		local q = point(math.clamp(k + 0.02, 0, 1))
		return p, q - p
	end
	-- Missed: keep coasting along the last direction.
	local last = shot.to - point(0.98)
	local direction = if last.Magnitude > 1e-3 then last.Unit else Vector3.yAxis
	local speed = (shot.to - shot.from).Magnitude / travel
	return shot.to + direction * speed * (rel - shot.meetAt), direction
end

local function step()
	local t = serverNow()
	table.clear(moveParts)
	table.clear(moveFrames)
	for index = #active, 1, -1 do
		local entry = active[index]
		local data = entry.data
		local rel = t - data.t0
		if rel >= entry.endAt then
			finish(entry)
			table.remove(active, index)
		elseif rel >= 0 and entry.drawn then
			local position = FlightMath.position(entry.flight, rel)
			local pivot = along(position, FlightMath.velocity(entry.flight, rel))
			if not entry.started then
				entry.started = true
				-- A silo hand-off puffs at the gantry itself (SiloLaunch); the roar plays at t0 always.
				if entry.handOff <= 0 then
					AttackFx.puff(entry.flight.from, 10)
				end
				AttackFx.sound("nuke_launch", entry.flight.from, 1, 1)
			end
			if not entry.shown and rel >= entry.handOff then
				-- Owner R109: the silo rocket has blended onto this exact pose; the flight nuke takes over.
				entry.shown = true
				entry.model = acquire(`Nuke{data.tier}`)
				if entry.model ~= nil then
					placeNow(entry.model, pivot)
				end
			elseif entry.model ~= nil then
				place(entry.model, pivot)
			end
			-- Interceptors (and each firing tower's turret following the nuke while it engages).
			local engagingMask = 0
			for _, shot in entry.shots do
				if not shot.done then
					if rel >= shot.fireAt - 0.6 and rel <= shot.meetAt then
						engagingMask = bit32.bor(engagingMask, bit32.lshift(1, shot.tower))
					end
					if rel >= shot.fireAt then
						if not shot.fired then
							shot.fired = true
							shot.model = acquire("Interceptor")
							local p, v = shotPosition(shot, rel)
							if shot.model ~= nil then
								placeNow(shot.model, along(p, v))
							end
							AttackFx.sound("nuke_whoosh", shot.from, 1.5, 0.6)
							-- Owner R106: the firing tower recoils + muzzle flash.
							TowerAnim.fire(data.toPlot, shot.tower)
						end
						local ends = if shot.hit then shot.meetAt else shot.meetAt + MISS_COAST
						if rel >= ends then
							shot.done = true
							if shot.model ~= nil then
								if not shot.hit then
									AttackFx.puff((shotPosition(shot, rel)), 5, true)
								end
								release(shot.model)
								shot.model = nil
							end
						elseif shot.model ~= nil then
							local p, v = shotPosition(shot, rel)
							place(shot.model, along(p, v))
						end
					end
				end
			end
			if engagingMask ~= 0 then
				for tower = 0, TOWER_SLOTS do
					if bit32.btest(engagingMask, bit32.lshift(1, tower)) then
						TowerAnim.aim(data.toPlot, tower, position)
					end
				end
			end
		end
	end
	if #moveParts > 0 then
		Workspace:BulkMoveTo(moveParts, moveFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
	if #active == 0 and connection ~= nil then
		connection:Disconnect()
		connection = nil
	end
end

--------------------------------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------------------------------

--[[
	Adds one server-decided flight (AttackClient validated it).
	@param data FlightData
	@param myUserId number — the local player's UserId (attacker / victim flavour)
]]
function FlightRenderer.add(data: FlightData, myUserId: number)
	-- Aim-aware (owner R50): the same arc the server built from these indices.
	local indices: AttackGeometry.FlightIndices = {
		fromPlot = data.fromPlot,
		silo = data.silo,
		toPlot = data.toPlot,
		impact = data.impact,
		area = data.area,
		sx = data.sx,
		sz = data.sz,
		duration = data.duration,
	}
	local ok, flight = pcall(AttackGeometry.flightOf, indices)
	if not ok then
		return
	end
	local endAt = if data.intercepted then math.min(data.interceptAt, flight.duration) else flight.duration
	local camera = Workspace.CurrentCamera
	local drawn = true
	if camera ~= nil then
		local eye = camera.CFrame.Position
		local far = CLIENT.RenderDistance
		local mid = FlightMath.position(flight, flight.duration * 0.5)
		drawn = (flight.from - eye).Magnitude <= far
			or (flight.to - eye).Magnitude <= far
			or (mid - eye).Magnitude <= far
		-- My own nuke is always drawn: the launch cinematic (owner R54) follows it.
		drawn = drawn or data.fromUserId == myUserId
	end
	local shots: { Shot } = {}
	-- Owner R80: the volleys of every defending tower; legacy payloads (no volleys) = one HQ volley.
	local volleys: { Volley } = data.volleys or {}
	if #volleys == 0 and data.shots > 0 and data.reload > 0 then
		volleys = {
			{ tower = 0, shots = data.shots, firstShot = data.firstShot, reload = data.reload, hit = data.intercepted },
		}
	end
	if drawn and #volleys > 0 then
		-- Deterministic per-flight miss offsets (any client draws the same picture).
		local rng = AttackRng.new(AttackRng.mix(data.id, 77))
		for _, volley in volleys do
			local okMuzzle, muzzle = pcall(AttackGeometry.muzzle, data.toPlot, volley.tower)
			if not okMuzzle then
				continue
			end
			for n = 1, volley.shots do
				local fireAt = FlightMath.shotTime(volley.firstShot, n, volley.reload)
				local meetAt = fireAt + FLIGHT.InterceptorSeconds
				local hit = data.intercepted and volley.hit and n == volley.shots
				local meet = FlightMath.position(flight, math.min(meetAt, flight.duration))
				local to = meet
				if not hit then
					local side = Vector3.new(rng:next() - 0.5, rng:next() * 0.5, rng:next() - 0.5)
					to = meet + (if side.Magnitude > 1e-3 then side.Unit else Vector3.xAxis) * MISS_OFFSET
				end
				table.insert(shots, {
					tower = volley.tower,
					fireAt = fireAt,
					meetAt = meetAt,
					hit = hit,
					from = muzzle,
					to = to,
					model = nil,
					fired = false,
					done = false,
				})
			end
		end
	end
	-- Owner R109: the launching silo's rocket lifts off and flies the first HandOff seconds of the
	-- arc (every client; 0 when it is not drawn here).
	local okSilo, handOff = pcall(SiloLaunch.launch, data, flight)
	table.insert(active, {
		data = data,
		flight = flight,
		endAt = endAt,
		model = nil,
		shots = shots,
		started = false,
		handOff = if okSilo and type(handOff) == "number" and drawn then math.min(handOff, endAt) else 0,
		shown = false,
		drawn = drawn,
		mine = data.fromUserId == myUserId,
		onMe = data.toUserId == myUserId,
	})
	if connection == nil then
		connection = RunService.PreRender:Connect(step)
	end
end

--[[ Number of flights being drawn (tests / debug overlay). ]]
function FlightRenderer.activeCount(): number
	return #active
end

--[[ Starts the renderer (idempotent): the tower rigs it aims are TowerAnim's (owner R106). ]]
function FlightRenderer.start()
	if started then
		return
	end
	started = true
	TowerAnim.start()
end

return FlightRenderer
