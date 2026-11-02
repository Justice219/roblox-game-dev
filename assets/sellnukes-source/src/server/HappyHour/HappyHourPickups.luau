--!strict
--[[
	HappyHourPickups — the server side of the Happy Hour pickups (owner R89 §2, docs/happy-hours.md):
	Confetti Storm coins that fall from the clouds, Egg Stampede eggs that run round Dino Valley
	plots, Low-Gravity Hour moon rocks that float at jump height on Moon Base.

	Purpose:
		While an event with a `pickup` definition (HappyHourConfig) is live, every eligible player
		(profile loaded, past the guided first-minute tutorial, alive, in the event's world) gets
		their OWN pickups near them, at most `maxLive` at once and `maxPerEvent` per event:
			- on their own plot: a free ground spot from the Lucky Button placement rules
			  (LuckyButtonService.pickGroundSpot — never inside a pad / producer / building), eggs on
			  a loop along the plot road beside them;
			- anywhere else (hub, someone else's plot): a ring round the character, dropped onto
			  the ground with one ray and accepted only near the character's feet height.
		Walking into one claims it: cash = `incomeSeconds` of the player's income in that world
		(LuckyButtonService.cashBurst, fixed at spawn), a golden one adds `goldenGems` gems.

	No server Instances (the Golden Turkey / Lucky Button pattern): the server keeps each pickup's
	wire + compiled motion; ONLY the owner's client is told (Remotes.fireClient "HappyHour") and
	draws pooled models along the same maths (Shared/Events/HappyHourPickupLogic; run = the turkey
	path, EventConfig.compilePath).

	Wire (S→C "HappyHour"):
		{ kind = "spawn", pickup = HappyHourPickupLogic.Wire }
		{ kind = "claimed", id, amount, currency, gems, golden }
		{ kind = "gone", id }            refused because it no longer exists (client drops it)
		{ kind = "clear" }               event over / world change / admin stop / kill switch
	Collect (C→S "HappyHourCollect"): (id: string) → RateLimiter, Validate.key + id shape, the
	player's OWN live pickup of the live event, same world, alive character, per-player cooldown,
	server-side distance from the character root to the pickup's pose now and LagSamples ago.

	Performance: ONE 1 Hz tick for every player (HappyHourService's loop), bounded spawn attempts
	(Pickups.MaxPicks), no per-pickup threads, no per-frame work, one ray per placement attempt off
	the plot (zero on the plot: layout data, LuckyButtonService).

	Security: the client sends only the id of a pickup it walked into. Ownership, event, world,
	expiry, distance (server-side character position), amounts and gems are all server-side.

	API (HappyHourService is the only caller):
		tick(now, live)                     spawn / expire / reset on event change
		onCollect(player, rawId)            the HappyHourCollect handler
		clearAll(reason)                    drop every pickup (admin stop / kill switch)
		forget(player)                      PlayerRemoving cleanup
		spawnFor(player, live, golden?)     admin / QA: one pickup now (caps still apply)
		status() -> { ... }                 counters for the admin status line / QA
		pickupsOf(player) -> { Wire }       QA inspection

	Example:
		HappyHourPickups.tick(Workspace:GetServerTimeNow(), HappyHourLogic.liveAt(now))
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local FtueConfig = require(ReplicatedStorage.Shared.Config.FtueConfig)
local HappyHourConfig = require(ReplicatedStorage.Shared.Config.HappyHourConfig)
local HappyHourLogic = require(ReplicatedStorage.Shared.Events.HappyHourLogic)
local HappyHourPickupLogic = require(ReplicatedStorage.Shared.Events.HappyHourPickupLogic)
local Lazy = require(ServerScriptService.Server.Event.Lazy)
local PlayerDataService = require(ServerScriptService.Server.Services.PlayerDataService)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Validate = require(ReplicatedStorage.Shared.Net.Validate)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)

type Live = HappyHourLogic.Live
type Wire = HappyHourPickupLogic.Wire
type PickupDef = HappyHourConfig.PickupDef

-- One live pickup (server truth).
type Record = {
	wire: Wire,
	compiled: HappyHourPickupLogic.Compiled,
	world: string,
	amount: number, -- cash granted on collection (fixed at spawn)
	currency: string, -- that world's currency key
	gems: number, -- golden: gems granted on collection
}

-- Per-player state for the CURRENT event instance (reset on every event change).
type State = {
	pickups: { [string]: Record },
	world: string?,
	nextAt: number?,
	spawned: number, -- pickups spawned for this player this event
	golden: number, -- golden pickups spawned this event
	lastCollect: number, -- os.clock() of the last collection
}

local Pickups = HappyHourConfig.Pickups

local HappyHourPickups = {}

local states: { [Player]: State } = {}
local activeSignature = ""
local nextId = 0
local rng = Random.new()
local collectLimiter = RateLimiter.new(Pickups.CollectBurst, Pickups.CollectPerSecond)
local counters = { spawned = 0, collected = 0, golden = 0, refused = 0, expired = 0 }
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

-- ── Helpers ──────────────────────────────────────────────────────────────────────────────────

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

-- Counts an event-family analytics key (never errors / yields).
local function track(player: Player?, key: string, amount: number?)
	Lazy.analytics("event", player, key, amount)
end

-- The alive character's root part, or nil.
local function rootOf(player: Player): BasePart?
	local character = player.Character
	if character == nil then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if root == nil or not root:IsA("BasePart") or humanoid == nil or humanoid.Health <= 0 then
		return nil
	end
	return root
end

-- The y of the character's feet (root centre - half its height - the legs).
local function feetY(player: Player, root: BasePart): number
	local character = player.Character
	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	local legs = if humanoid ~= nil and humanoid.RigType == Enum.HumanoidRigType.R15 then humanoid.HipHeight else 2
	return root.Position.Y - root.Size.Y / 2 - legs
end

-- True while the player is on a guided first-minute tutorial step (nothing competes with it).
local function inGuidedTutorial(profile: any): boolean
	local tycoon = if type(profile) == "table" then profile.tycoon else nil
	return type(tycoon) == "table" and FtueConfig.isGuided(tycoon.tutorialStep)
end

-- The world a player is in (WorldService; "main" when it is not loaded).
local function worldOf(player: Player): string
	local currentWorld = Lazy.fn("Tycoon/WorldService", "currentWorld")
	if currentWorld ~= nil then
		local ok, world = pcall(currentWorld, player)
		if ok and type(world) == "string" then
			return world
		end
	end
	return "main"
end

-- The player's plot index (PlotService), or nil.
local function plotOf(player: Player): number?
	local getPlotIndex = Lazy.fn("Tycoon/PlotService", "getPlotIndex")
	if getPlotIndex == nil then
		return nil
	end
	local ok, index = pcall(getPlotIndex, player)
	return if ok and type(index) == "number" then index else nil
end

-- A fresh per-player state.
local function newState(): State
	return { pickups = {}, world = nil, nextAt = nil, spawned = 0, golden = 0, lastCollect = -math.huge }
end

-- The state of a present player (created on demand).
local function stateOf(player: Player): State?
	if player.Parent ~= Players then
		return nil
	end
	local state = states[player]
	if state == nil then
		state = newState()
		states[player] = state
	end
	return state
end

-- Clears one player's pickups (tells the client when there were any).
local function clearPlayer(player: Player, state: State)
	if next(state.pickups) ~= nil then
		table.clear(state.pickups)
		Remotes.fireClient("HappyHour", player, { kind = "clear" })
	end
end

-- Refreshes the ground probe's exclusion list (characters are never "ground").
local function refreshRayFilter()
	local exclude: { Instance } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character ~= nil then
			table.insert(exclude, character)
		end
	end
	rayParams.FilterDescendantsInstances = exclude
end

--[[
	The ground under a point near a character whose feet are at `feet`: one ray down from above
	the feet; no hit = the world-contract ground y = 0. Accepted only within GroundTolerance of
	the feet (never a roof top, never a cliff bottom) and inside the expected world.
]]
local function groundAt(point: Vector3, feet: number, world: string): Vector3?
	if WorldLayout.worldAt(point) ~= world then
		return nil
	end
	local origin = Vector3.new(point.X, feet + Pickups.RayUp, point.Z)
	local hit = Workspace:Raycast(origin, Vector3.new(0, -Pickups.RayDepth, 0), rayParams)
	local y = if hit ~= nil then hit.Position.Y else 0
	if math.abs(y - feet) > Pickups.GroundTolerance then
		return nil
	end
	return Vector3.new(point.X, y, point.Z)
end

-- True when `point` keeps MinSpacing from every point in `others` (XZ).
local function spaced(point: Vector3, others: { Vector3 }): boolean
	local min = Pickups.MinSpacing
	for _, other in others do
		local dx, dz = point.X - other.X, point.Z - other.Z
		if dx * dx + dz * dz < min * min then
			return false
		end
	end
	return true
end

-- The rest points of a player's live pickups (spacing).
local function restPoints(state: State): { Vector3 }
	local list: { Vector3 } = {}
	for _, record in state.pickups do
		table.insert(list, record.wire.points[1])
	end
	return list
end

-- A ground point on a ring round the character (off-plot placement), or nil.
local function ringGround(root: BasePart, feet: number, world: string, others: { Vector3 }): Vector3?
	for _ = 1, Pickups.MaxPicks do
		local point = HappyHourPickupLogic.ringPoint(
			root.Position,
			Pickups.RingMin,
			Pickups.RingMax,
			rng:NextNumber() * math.pi * 2,
			rng:NextNumber()
		)
		local ground = groundAt(point, feet, world)
		if ground ~= nil and spaced(ground, others) then
			return ground
		end
	end
	return nil
end

-- True when the character stands on their own plot in `world`.
local function onOwnPlot(player: Player, root: BasePart, world: string): (boolean, number?)
	local plot = plotOf(player)
	if plot == nil then
		return false, nil
	end
	local position = root.Position
	return WorldLayout.worldAt(position) == world and WorldLayout.plotAt(position, world) == plot, plot
end

--[[
	A loop of waypoints for a running pickup near the character: on their own plot along the road
	beside them (plot-local, y = 0 ground); elsewhere round a ground point near them (every
	waypoint ground-probed). nil when no valid loop was found.
]]
local function runPoints(
	player: Player,
	root: BasePart,
	world: string,
	def: PickupDef,
	others: { Vector3 },
	offset: number
): { Vector3 }?
	local spread = def.runSpread or 16
	local side = 3 + rng:NextNumber() * 4
	local onPlot, plot = onOwnPlot(player, root, world)
	if onPlot and plot ~= nil then
		local origin = WorldLayout.plotOrigin(plot, world)
		local here = origin:PointToObjectSpace(root.Position)
		local length = WorldLayout.plotLength(world)
		local road = WorldLayout.RoadHalfWidth - 2
		local z =
			math.clamp(here.Z + offset, WorldLayout.EntranceZ + spread + 2, math.max(length - spread - 2, spread + 4))
		local center = Vector3.new(rng:NextNumber(-road, road), 0, z)
		local points: { Vector3 } = {}
		for _, point in HappyHourPickupLogic.runLoop(center, Vector3.new(0, 0, 1), spread, side) do
			table.insert(points, WorldLayout.plotToWorld(plot, CFrame.new(point), world).Position)
		end
		return points
	end
	local feet = feetY(player, root)
	local center = ringGround(root, feet, world, others)
	if center == nil then
		return nil
	end
	local angle = rng:NextNumber() * math.pi * 2
	local forward = Vector3.new(math.cos(angle), 0, math.sin(angle))
	local points: { Vector3 } = {}
	for _, point in HappyHourPickupLogic.runLoop(center + forward * offset, forward, spread, side) do
		local ground = groundAt(point, feet, world)
		if ground == nil then
			return nil
		end
		table.insert(points, ground)
	end
	return points
end

--[[
	Spawns one pickup for a player (schedule or admin). Caps are the caller's job; this only
	places, prices and announces it.
	@return the new record, or nil when no valid spot was found
]]
local function spawnOne(
	player: Player,
	state: State,
	live: Live,
	def: PickupDef,
	world: string,
	root: BasePart,
	golden: boolean,
	delay: number,
	offset: number
): Record?
	refreshRayFilter()
	local others = restPoints(state)
	local points: { Vector3 }? = nil
	if def.style == "run" then
		points = runPoints(player, root, world, def, others, offset)
	else
		local ground: Vector3? = nil
		local onPlot = onOwnPlot(player, root, world)
		local luckyService = Lazy.service("LuckyButtonService")
		if onPlot and luckyService ~= nil and type(luckyService.pickGroundSpot) == "function" then
			local ok, spot = pcall(
				luckyService.pickGroundSpot,
				player,
				world,
				others,
				Pickups.MinSpacing,
				root.Position,
				Pickups.NearRadius
			)
			ground = if ok and typeof(spot) == "Vector3" then spot else nil
		end
		if ground == nil then
			ground = ringGround(root, feetY(player, root), world, others)
		end
		if ground ~= nil then
			local lift = if def.style == "float"
				then (def.floatMin or 7) + rng:NextNumber() * math.max(0, (def.floatMax or 7) - (def.floatMin or 7))
				else Pickups.RestLift
			points = { ground + Vector3.new(0, lift, 0) }
		end
	end
	if points == nil then
		return nil
	end
	-- Price it now (fixed for its life): seconds of this world's income, floored.
	local amount, currency = 0, "cash"
	local luckyService = Lazy.service("LuckyButtonService")
	if luckyService ~= nil and type(luckyService.cashBurst) == "function" then
		local ok, value, key = pcall(luckyService.cashBurst, player, world, def.incomeSeconds, Pickups.FloorScale)
		if ok and type(value) == "number" and type(key) == "string" then
			amount, currency = value, key
		end
	end
	if amount <= 0 and not golden then
		return nil -- no run in this world yet: nothing worth dropping
	end
	nextId += 1
	local wire: Wire = {
		id = `{Pickups.IdPrefix}{nextId}`,
		event = live.id,
		style = def.style,
		golden = golden,
		points = points :: { Vector3 },
		t0 = serverNow() + delay,
		life = def.life,
	}
	local record: Record = {
		wire = wire,
		compiled = HappyHourPickupLogic.compile(wire),
		world = world,
		amount = amount,
		currency = currency,
		gems = if golden then def.goldenGems else 0,
	}
	state.pickups[wire.id] = record
	state.spawned += 1
	if golden then
		state.golden += 1
	end
	counters.spawned += 1
	Remotes.fireClient("HappyHour", player, { kind = "spawn", pickup = wire })
	track(player, `hh:spawn:{live.id}`)
	return record
end

-- Live pickups of a state.
local function liveCount(state: State): number
	local count = 0
	for _ in state.pickups do
		count += 1
	end
	return count
end

-- One player's tick for a live pickup event.
local function tickPlayer(player: Player, state: State, now: number, live: Live, def: PickupDef)
	local world = worldOf(player)
	if state.world ~= world then
		clearPlayer(player, state)
		state.world = world
	end
	-- Expiry (silent: the client fades it out on its own clock).
	for id, record in state.pickups do
		if now >= record.compiled.ends then
			state.pickups[id] = nil
			counters.expired += 1
		end
	end
	if live.world ~= nil and world ~= live.world then
		return
	end
	local profile = PlayerDataService.getProfile(player)
	if profile == nil or inGuidedTutorial(profile) then
		return
	end
	local root = rootOf(player)
	if root == nil then
		return
	end
	local nextAt = state.nextAt
	if nextAt == nil then
		-- The first drop comes quickly after the event starts (or the player arrives).
		state.nextAt = now + 1 + rng:NextNumber() * 2
		return
	end
	if now < nextAt then
		return
	end
	state.nextAt = now + HappyHourPickupLogic.nextDelay(def, rng:NextNumber())
	local count = HappyHourPickupLogic.spawnCount(def, liveCount(state), state.spawned)
	for index = 1, count do
		local golden = HappyHourPickupLogic.rollGolden(def, state.golden, rng:NextNumber())
		-- A herd staggers its members a little in time and along the road.
		local delay = (index - 1) * 0.35
		local offset = (index - 1 - (count - 1) / 2) * 5
		if spawnOne(player, state, live, def, world, root, golden, delay, offset) == nil then
			break
		end
	end
end

-- ── Public API ───────────────────────────────────────────────────────────────────────────────

--[[
	The 1 Hz tick: resets every player's pickups when the live event changes, then (for a pickup
	event) expires, spawns and re-arms per player.
	@param now  Workspace:GetServerTimeNow()
	@param live the effective live event (HappyHourLogic.liveAt) or nil
]]
function HappyHourPickups.tick(now: number, live: Live?)
	local signature = HappyHourLogic.signature(live)
	if signature ~= activeSignature then
		activeSignature = signature
		for player, state in states do
			clearPlayer(player, state)
			states[player] = newState()
		end
	end
	if live == nil then
		return
	end
	local def = HappyHourConfig.get(live.id)
	local pickup = if def ~= nil then def.pickup else nil
	if pickup == nil then
		return
	end
	for _, player in Players:GetPlayers() do
		local state = stateOf(player)
		if state ~= nil then
			local ok, err = pcall(tickPlayer, player, state, now, live, pickup)
			if not ok then
				warn(`[HappyHour] pickup tick failed for {player.Name}: {err}`)
			end
		end
	end
end

--[[ Drops every pickup on the server (admin stop / kill switch / tests). ]]
function HappyHourPickups.clearAll()
	for player, state in states do
		clearPlayer(player, state)
		state.nextAt = nil
	end
end

--[[ PlayerRemoving cleanup. ]]
function HappyHourPickups.forget(player: Player)
	states[player] = nil
	collectLimiter:Forget(player)
end

--[[
	HappyHourCollect(id): validates and pays one of the player's own pickups (see the header).
	Refusals are silent except "gone" (the pickup does not exist: the client drops it).
]]
function HappyHourPickups.onCollect(player: Player, rawId: unknown)
	if not collectLimiter:Allow(player) then
		return
	end
	local id = Validate.key(rawId, Pickups.IdMaxLength)
	if id == nil or not HappyHourPickupLogic.validId(id) then
		return
	end
	local state = states[player]
	local record = if state ~= nil then state.pickups[id] else nil
	if state == nil or record == nil then
		counters.refused += 1
		Remotes.fireClient("HappyHour", player, { kind = "gone", id = id })
		return
	end
	local now = serverNow()
	local live = HappyHourLogic.liveAt(now)
	if live == nil or live.id ~= record.wire.event or worldOf(player) ~= record.world then
		counters.refused += 1
		return
	end
	if os.clock() - state.lastCollect < Pickups.CollectCooldown then
		return
	end
	local root = rootOf(player)
	if root == nil then
		return
	end
	local distance = HappyHourPickupLogic.distance(record.compiled, now, root.Position, Pickups.LagSamples)
	if distance > Pickups.CatchRadius + Pickups.ServerSlack then
		counters.refused += 1
		return
	end
	-- Grant first; only a successful grant consumes the pickup.
	local granted = 0
	if record.amount > 0 then
		granted = PlayerDataService.grantCurrency(player, record.currency, record.amount, Pickups.GrantReason)
		if granted <= 0 then
			return
		end
	end
	local gems = 0
	if record.gems > 0 then
		gems = PlayerDataService.grantGems(player, record.gems, Pickups.GrantReason)
	end
	if granted <= 0 and gems <= 0 then
		return
	end
	state.pickups[id] = nil
	state.lastCollect = os.clock()
	counters.collected += 1
	local event = record.wire.event
	Remotes.fireClient("HappyHour", player, {
		kind = "claimed",
		id = id,
		amount = granted,
		currency = record.currency,
		gems = gems,
		golden = record.wire.golden,
	})
	track(player, `hh:pickup:{event}`)
	if record.wire.golden then
		counters.golden += 1
		track(player, `hh:golden:{event}`)
	end
	if gems > 0 then
		track(player, "hh:gems", gems)
	end
end

--[[
	Admin / QA: spawns one pickup of the live event for `player` now (live / event caps apply;
	the player must be in the event's world).
	@return (ok, id or reason)
]]
function HappyHourPickups.spawnFor(player: Player, live: Live?, golden: boolean?): (boolean, string)
	if live == nil then
		return false, "no event is live"
	end
	local def = HappyHourConfig.get(live.id)
	local pickup = if def ~= nil then def.pickup else nil
	if pickup == nil then
		return false, `{live.id} has no pickups`
	end
	local state = stateOf(player)
	local root = rootOf(player)
	if state == nil or root == nil then
		return false, "player has no character"
	end
	local world = worldOf(player)
	if live.world ~= nil and world ~= live.world then
		return false, `player is not in {live.world}`
	end
	if HappyHourPickupLogic.spawnCount(pickup, liveCount(state), state.spawned) <= 0 then
		return false, "live / event cap reached"
	end
	state.world = world
	local record = spawnOne(player, state, live, pickup, world, root, golden == true, 0, 0)
	if record == nil then
		return false, "no free spot / no run in this world"
	end
	return true, record.wire.id
end

--[[ Server counters + live pickups (admin status / QA). ]]
function HappyHourPickups.status(): { [string]: number }
	local live, players = 0, 0
	for _, state in states do
		local count = liveCount(state)
		live += count
		if count > 0 then
			players += 1
		end
	end
	return {
		live = live,
		players = players,
		spawned = counters.spawned,
		collected = counters.collected,
		golden = counters.golden,
		refused = counters.refused,
		expired = counters.expired,
	}
end

--[[ The live pickups of a player as wires (QA inspection). ]]
function HappyHourPickups.pickupsOf(player: Player): { Wire }
	local list: { Wire } = {}
	local state = states[player]
	if state ~= nil then
		for _, record in state.pickups do
			table.insert(list, record.wire)
		end
	end
	return list
end

return HappyHourPickups
