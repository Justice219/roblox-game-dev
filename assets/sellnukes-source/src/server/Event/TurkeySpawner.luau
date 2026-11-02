--!strict
--[[
	TurkeySpawner — the live Golden Turkeys of this server (Harvest Feast, docs/event.md).

	Purpose:
		Owns the table of turkeys alive right now and turns a scheduler order (EventLogic.planSpawns)
		into a concrete turkey: a closed wander loop of ground points (hub: the HubLayout event spawn
		points or a ring around the event square; plot: the owner's plot road up to their current
		area IN THE WORLD THEY ARE IN, placed with WorldLayout.plotToWorld(..., worldId)), each
		point dropped onto the real WALKABLE ground with one downward raycast (RespectCanCollide:
		the surface a character stands on, never an invisible trigger / hitbox — owner R96).
		Turkeys have NO server Instances: the server keeps only the path (compiled once) and
		clients render + animate their own pooled models along the same deterministic path
		(EventConfig.pose), so moving birds cost zero replication and zero physics.

	What it knows per turkey: its wire (sent to clients), the compiled path (catch validation), who
	already caught it (each player may catch each turkey once; it vanishes only for them), the plot
	it belongs to and, for a Turkey Lure, its owner, plus the world it was placed in (EventService
	re-places a plot turkey when its plot owner travels to another world).

	API (EventService is the only caller):
		spawn(order, ctx)          -> Live?   build + register a turkey (nil when no ground / no plot)
		get(id)                    -> Live?
		remove(id)                 -> Live?   forget it (the caller broadcasts the despawn)
		expired(now)               -> { Live } turkeys whose life ended (already removed)
		counts()                   -> Counts  totals for the scheduler
		forEach(fn)                           iterate live turkeys
		removeWhere(predicate)     -> { Live } e.g. every natural turkey when the event ends

	Example:
		local live = TurkeySpawner.spawn({ zone = "hub", lure = false }, ctx)
		if live then Remotes.fireAllClients("EventState", { kind = "spawn", turkey = live.wire }) end
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local EventConfig = require(ReplicatedStorage.Shared.Config.EventConfig)
local EventLogic = require(script.Parent.EventLogic)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

type TurkeyWire = EventConfig.TurkeyWire

-- One live turkey.
export type Live = {
	wire: TurkeyWire,
	compiled: EventConfig.CompiledPath,
	collected: { [number]: boolean }, -- userId -> caught it already
	plotUserId: number?, -- natural plot turkey: the plot owner's UserId (scheduler counts)
	plotOwner: number?, -- any plot turkey (natural or lure): whose plot it walks on
	world: string, -- WorldsConfig id the path was placed in ("main" for the hub)
}

-- What the spawner needs from the event service for one spawn.
export type SpawnContext = {
	now: number, -- Workspace:GetServerTimeNow()
	plotIndexOf: (userId: number) -> number?,
	worldOf: (userId: number) -> string, -- the world the player is in ("main" when unknown)
	areaOf: (userId: number, worldId: string) -> number, -- their area in that world
	hubAnchors: { Vector3 }, -- HubLayout.event.turkeySpawns (world) or {}
	square: Vector3, -- event square centre (world)
	rng: () -> number,
}

export type Counts = {
	total: number,
	natural: number,
	hub: number,
	plotAlive: { [number]: number }, -- userId -> natural turkeys on their plot
	lureAlive: { [number]: number }, -- userId -> lure turkeys alive for them
}

local TurkeySpawner = {}

local live: { [string]: Live } = {}
local nextId = 0

-- Ground probe parameters (characters excluded; refreshed per spawn). RespectCanCollide: the
-- probe hits what a character can stand on (collidable road / bed meshes count even when their
-- CanQuery is off; invisible non-collidable triggers, pickup hitboxes and zones never do), so a
-- turkey's feet land where a player's feet would (owner R96).
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
rayParams.RespectCanCollide = true

--[[
	Drops a point onto the walkable ground below it: one ray from RayUp above, RayDepth down.
	Points with no ground under them keep their y (y = 0 is the ground everywhere by the world
	contract). The client places the model's real feet (EventConfig.groundFrame) on this point.
]]
local function ground(point: Vector3): Vector3
	local cfg = EventConfig.Turkey
	local origin = point + Vector3.new(0, cfg.RayUp, 0)
	local hit = Workspace:Raycast(origin, Vector3.new(0, -cfg.RayDepth, 0), rayParams)
	if hit ~= nil then
		return Vector3.new(point.X, hit.Position.Y, point.Z)
	end
	return point
end

-- Refreshes the probe's exclusion list (player characters must never be "ground").
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
	Builds and registers one turkey for a scheduler order.
	@return the Live record, or nil when the order cannot be placed (no plot for a plot order)
]]
function TurkeySpawner.spawn(order: EventLogic.SpawnOrder, ctx: SpawnContext): Live?
	local cfg = EventConfig.Turkey
	local worldPoints: { Vector3 } = {}
	local plotUserId: number? = nil
	local plotOwner: number? = nil
	local world = WorldsConfig.MAIN
	if order.zone == "plot" then
		local userId = order.userId
		if userId == nil then
			return nil
		end
		local plotIndex = ctx.plotIndexOf(userId)
		if plotIndex == nil then
			if not order.lure then
				return nil
			end
			-- A paid lure for a player without a plot (should not happen): wander in the hub.
			worldPoints = EventLogic.hubWanderPoints(ctx.hubAnchors, ctx.square, ctx.rng)
		else
			-- The plot ring of the world the owner is in (Nuke Town, Dino Valley, ...), so the
			-- turkey walks on the road they actually see.
			world = ctx.worldOf(userId)
			plotOwner = userId
			local area = ctx.areaOf(userId, world)
			local plotLength = WorldLayout.plotLength(world)
			for _, point in EventLogic.plotWanderPoints(area, plotLength, WorldLayout.RowLength, ctx.rng) do
				table.insert(worldPoints, WorldLayout.plotToWorld(plotIndex, CFrame.new(point), world).Position)
			end
		end
		if not order.lure then
			plotUserId = userId
		end
	else
		worldPoints = EventLogic.hubWanderPoints(ctx.hubAnchors, ctx.square, ctx.rng)
	end
	if #worldPoints == 0 then
		return nil
	end
	refreshRayFilter()
	for index, point in worldPoints do
		worldPoints[index] = ground(point)
	end

	nextId += 1
	local id = `t{nextId}`
	local wire: TurkeyWire = {
		id = id,
		zone = if order.zone == "hub" then "hub" else "plot",
		points = worldPoints,
		t0 = ctx.now,
		speed = cfg.Speed,
		pause = cfg.PauseSeconds,
		life = if order.lure then cfg.LureLifeSeconds else cfg.LifeSeconds,
		owner = if order.lure and order.userId ~= nil then order.userId else 0,
		lure = order.lure,
	}
	local record: Live = {
		wire = wire,
		compiled = EventConfig.compilePath(wire),
		collected = {},
		plotUserId = plotUserId,
		plotOwner = plotOwner,
		world = world,
	}
	live[id] = record
	return record
end

--[[ The live turkey with this id, or nil. ]]
function TurkeySpawner.get(id: string): Live?
	return live[id]
end

--[[ Forgets a turkey. @return the removed record (nil when unknown) ]]
function TurkeySpawner.remove(id: string): Live?
	local record = live[id]
	live[id] = nil
	return record
end

--[[ Removes and returns every turkey whose life ended at `now`. ]]
function TurkeySpawner.expired(now: number): { Live }
	local gone: { Live } = {}
	for id, record in live do
		if now >= record.compiled.ends then
			live[id] = nil
			table.insert(gone, record)
		end
	end
	return gone
end

--[[ Removes and returns every turkey matching `predicate`. ]]
function TurkeySpawner.removeWhere(predicate: (record: Live) -> boolean): { Live }
	local gone: { Live } = {}
	for id, record in live do
		if predicate(record) then
			live[id] = nil
			table.insert(gone, record)
		end
	end
	return gone
end

--[[ Calls fn for every live turkey (do not add / remove inside fn). ]]
function TurkeySpawner.forEach(fn: (record: Live) -> ())
	for _, record in live do
		fn(record)
	end
end

--[[ Totals for the scheduler (EventLogic.SpawnFacts). ]]
function TurkeySpawner.counts(): Counts
	local counts: Counts = { total = 0, natural = 0, hub = 0, plotAlive = {}, lureAlive = {} }
	for _, record in live do
		counts.total += 1
		local wire = record.wire
		if wire.lure then
			counts.lureAlive[wire.owner] = (counts.lureAlive[wire.owner] or 0) + 1
		else
			counts.natural += 1
			if wire.zone == "hub" then
				counts.hub += 1
			elseif record.plotUserId ~= nil then
				local owner = record.plotUserId :: number
				counts.plotAlive[owner] = (counts.plotAlive[owner] or 0) + 1
			end
		end
	end
	return counts
end

return TurkeySpawner
