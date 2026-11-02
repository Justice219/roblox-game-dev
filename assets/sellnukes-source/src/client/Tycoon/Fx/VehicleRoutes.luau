--!strict
--[[
	VehicleRoutes — drives the map's vehicles and machines along their routes (owner R56: "animate
	more of the places in the map too, like, I feel like the delivery truck should drive in and
	out, semi-truck should drive in and out, you know, stuff like that").

	What it does (routes: Shared/Config/VehicleRouteConfig, maths: Fx/RouteMath):
		The A3 delivery van, A6 semi-truck and A8 shopper car drive in along the plot road, back into
		their stall / dock / bay, get loaded (cargo pops in with a bounce) and drive off, fading out
		on the road; the A4 mine-cart train rolls out of the tunnel and tips its ore into the bin;
		the A6 forklift shuttles pallets; the A3 scooters lap their lane; the A6 belt rockets ride
		the conveyor; the A8 barrier lifts for the car. Wheels spin (odometer / radius), bodies bob,
		dip their nose when braking and lean in bends; brake lights and indicators glow softly
		(Neon toggles); honks, reverse beeps and cargo pops play through Fx/FxSound.
		Dino Valley (owner R57): the D3 ptero couriers fly parcels in and out of the nest — wings
		flap (WingL / WingR turn about the model's local Z through the body centre line, mirrored),
		the nose follows the climb, the body banks into turns and heaves with each flap; hover waits
		keep flapping, spin waits turn the bird on the spot. Routes with one `sync` key in an area
		share ONE clock (their choreography never lets them touch).

	Rules (CLAUDE.md performance + owner R11 / R25 / R50):
		* CLIENT-ONLY transforms of the server-spawned models (one unit per model, R25): the server
		  copies never move; every piece is anchored, CanCollide / CanQuery / CanTouch off locally
		  (the layouts give driven models no collision box).
		* ONE Heartbeat connection for every vehicle, ONE Workspace:BulkMoveTo per frame, no
		  Instance.new at all, no per-frame tables or closures (scratch arrays are reused).
		* Budgets per FxQuality tier (VehicleRouteConfig.Tiers): every tier moves only the nearest
		  MaxActive routes within Range (Low 4 / 140, Mid 8 / 190, High 16 / 260 — owner R103: Low
		  used to park every vehicle, so phones saw no vehicle move while machines and managers did),
		  far routes write every other frame, routes outside the camera cone keep their clock but
		  skip their writes. Reduce Motion (Roblox or profile setting) parks everything on its
		  layout spot; stats().parked says why vehicles are parked (live diagnosis).
		* Streaming-aware: models register when they stream in (DescendantAdded of EVERY world's plots
		  folder via Tycoon/PlotFolders, filtered to Models whose MeshKey a route drives) and
		  unregister when they stream out. Only built areas exist, so only built areas animate.
		* World-aware (owner R57): a model binds only to routes of its plot's world (route.world, nil =
		  Nuke Town); slot frames come from WorldLayout.slotOrigin(plot, area, world) and rest poses
		  from that world's layouts (Tycoon/WorldLookup.layout).
		* Knockdown (owner R50): when an area's `KnockedUntil` is set its vehicles freeze at once
		  (KnockdownFx topples them from where they are and rebuilds them there); they resume
		  ResumeAfterKnockdown seconds after the area is back up. A fresh purchase waits BuildHold
		  seconds for its LEGO build-in to land before it starts moving.
		* Admin: World tab "Vehicles on/off" (Server/Admin/Handlers/WorldHandlers) sets the
		  ReplicatedStorage attribute `VehiclesEnabled`; false parks every vehicle live.

	Boot: controller contract Init() / Start() (idempotent), after Tycoon/Fx/WorldFxController in
	src/client/init.client.luau.
	Example (Studio console, client):
		local vr = require(game.Players.LocalPlayer.PlayerScripts.Client.Tycoon.Fx.VehicleRoutes)
		print(vr.stats()) --> { groups = 6, active = 4, instances = 11, parts = 96, started = true, tier = "High" }
		vr.setTimeScale(0.5) -- slow motion for captures
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local KnockdownConfig = require(ReplicatedStorage.Shared.Config.KnockdownConfig)
local MeshAssets = require(ReplicatedStorage.Shared.Config.MeshAssets)
local MeshPlacement = require(ReplicatedStorage.Shared.World.MeshPlacement)
local VehicleRouteConfig = require(ReplicatedStorage.Shared.Config.VehicleRouteConfig)
local ViewCone = require(ReplicatedStorage.Shared.Util.ViewCone)
local WorldFxConfig = require(ReplicatedStorage.Shared.Config.WorldFxConfig)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local FxQuality = require(script.Parent.FxQuality)
local FxSound = require(script.Parent.FxSound)
local PlotFolders = require(script.Parent.Parent.PlotFolders)
local RouteMath = require(script.Parent.RouteMath)
local TycoonWorld = require(script.Parent.Parent.TycoonWorld)
local WorldLookup = require(script.Parent.Parent.WorldLookup)

local VehicleRoutes = {}

local TUNING = VehicleRouteConfig.Tuning
local SOUNDS = VehicleRouteConfig.Sounds
-- Admin kill switch (World tab "Vehicles on/off" sets this ReplicatedStorage attribute; false = park).
local ENABLED_ATTRIBUTE = VehicleRouteConfig.EnabledAttribute
-- Piece roles.
local ROLE_BODY, ROLE_WHEEL, ROLE_CARGO, ROLE_WING = 1, 2, 3, 4
local TAU = 2 * math.pi

type Piece = {
	part: BasePart,
	rel: CFrame, -- model-local rest CFrame (pivot space)
	role: number,
	cargo: number, -- cargo group (ROLE_CARGO)
	spinBase: CFrame, -- wheels: the axle point (pivot space)
	spinRot: CFrame, -- wheels: rest rotation (ImportYaw for meshes)
	wing: number, -- flyers (ROLE_WING): -1 left wing, +1 right wing, 0 otherwise
	ltm: number, -- last LocalTransparencyModifier written (-1 = unknown)
}

-- One clock shared by the routes of an area with the same `sync` key (fixed choreography).
type SyncClock = {
	master: number, -- seconds into the shared loop (each route adds its own timeline.start)
	frame: number, -- frameCount of the last advance (advanced once per frame, by any member)
	period: number,
}

type Light = {
	part: BasePart,
	material: Enum.Material,
	variant: string,
	color: Color3,
	onColor: Color3,
	on: boolean,
}

type Group = {
	route: VehicleRouteConfig.Route,
	timeline: RouteMath.Timeline,
	area: Model,
	slot: CFrame,
	instances: { Inst },
	clock: number,
	laps: number,
	holdUntil: number, -- server time: a fresh build-in is still landing
	knocked: boolean,
	resumeAt: number, -- os.clock(): knockdown rebuild still flying in
	active: boolean,
	halfRate: boolean,
	slotIndex: number,
	parked: boolean, -- sitting on the layout rest pose, untouched
	force: boolean, -- rewrite every LTM / light next write (after a knockdown / park)
	distance: number,
	position: Vector3, -- leader's last world position (ranking, view cone, sounds)
	visible: boolean,
	lastWrite: number,
	seed: number,
	gate: Gate?,
	gateOpen: number,
	cargoLoaded: { boolean }, -- per cargo group, scratch per instance write
	cargoU: { number },
	sync: SyncClock?, -- shared clock (route.sync), nil = the group's own clock
}

type Inst = {
	model: Model,
	index: number, -- RouteMath timeline instance
	group: Group,
	pieces: { Piece },
	brake: Light?,
	left: Light?,
	right: Light?,
	sample: RouteMath.Sample,
	pitch: number,
	lean: number,
	phase: number,
	restWorld: CFrame,
	flap: number, -- flyers: 0 perched .. 1 flying (eased)
	flapPhase: number, -- flyers: wing stroke phase (radians)
}

type Gate = {
	model: Model,
	parts: { BasePart },
	rels: { CFrame },
	hinge: CFrame,
	hingeInverse: CFrame,
	axis: Vector3,
	angle: number,
}

local started = false
local timeScale = 1
local random = Random.new()

-- Registries.
local groupsByArea: { [Model]: { [string]: Group } } = {}
local groupList: { Group } = {}
local activeGroups: { Group } = {}
local instByModel: { [Model]: Inst } = {}
local gateModels: { [Model]: { [string]: Model } } = {} -- area -> modelKey -> gate model
local areaWatch: { [Model]: RBXScriptConnection } = {}
local timelines: { [string]: RouteMath.Timeline } = {}
local restCache: { [string]: { CFrame } } = {}
local syncClocks: { [Model]: { [string]: SyncClock } } = {} -- area -> sync key -> clock
local groupSlots = 0

-- Per-frame scratch (reused, never reallocated).
local movedParts: { BasePart } = {}
local movedFrames: { CFrame } = {}
local eventHits: { number } = {}
local candidates: { Group } = {}
local refreshTimer = math.huge
local frameCount = 0
local viewCos = -1

--------------------------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------------------------

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

-- Reduce Motion: the Roblox accessibility setting or the in-game setting.
local function reducedMotion(): boolean
	if GuiService.ReducedMotionEnabled then
		return true
	end
	local profile = ClientState.profile
	local settings = profile and profile.settings
	return type(settings) == "table" and settings.reducedMotion == true
end

local function globallyEnabled(): boolean
	return ReplicatedStorage:GetAttribute(ENABLED_ATTRIBUTE) ~= false
end

local function numberAttr(instance: Instance, name: string): number
	local value = instance:GetAttribute(name)
	return if type(value) == "number" and value == value then value else 0
end

-- True while the area's knockdown runs (KnockdownConfig contract: `KnockedUntil` in the future).
local function isKnocked(area: Model): boolean
	return numberAttr(area, KnockdownConfig.Attr.Until) > serverNow()
end

--[[
	First ancestor Model carrying `attribute` (PlotN: PlotIndex; a build wrapper: BuildKey). NOT for
	the area: build wrappers carry `AreaIndex` too (B5 contract), so use areaOf.
]]
local function ancestorWith(instance: Instance, attribute: string): Model?
	local node = instance.Parent
	while node ~= nil and not PlotFolders.isPlotsFolder(node) do
		if node:IsA("Model") and node:GetAttribute(attribute) ~= nil then
			return node
		end
		node = node.Parent
	end
	return nil
end

--[[
	The plot's `AreaNN` Model containing `instance` (the plot's direct child; it carries AreaIndex
	and is the KnockdownTarget whose `KnockedUntil` pauses the area's vehicles), or nil.
]]
local function areaOf(instance: Instance, plot: Model): Model?
	local node: Instance? = instance
	while node ~= nil and node.Parent ~= plot do
		node = node.Parent
	end
	if node ~= nil and node:IsA("Model") and node:GetAttribute("AreaIndex") ~= nil then
		return node
	end
	return nil
end

-- The world a route runs in (nil = Nuke Town).
local function worldOfRoute(route: VehicleRouteConfig.Route): string
	return route.world or WorldLookup.MAIN
end

--[[
	Slot-local rest CFrames of a route ([1] leader, [1 + k] follower k), read once from its world's
	area layout (Nuke Town AreaLayouts, Dino Worlds/Dino/Layouts, ...).
]]
local function restsOf(route: VehicleRouteConfig.Route): { CFrame }?
	local cached = restCache[route.id]
	if cached ~= nil then
		return cached
	end
	local layout: any = WorldLookup.layout(worldOfRoute(route), route.area)
	if layout == nil then
		return nil
	end
	local function find(placement: VehicleRouteConfig.Placement): CFrame?
		local build = layout.builds and layout.builds[placement.build]
		local model = build and build.models and build.models[placement.index]
		return if model ~= nil and typeof(model.cf) == "CFrame" then model.cf else nil
	end
	local rests: { CFrame } = {}
	local lead = find(route.rest)
	if lead == nil then
		return nil
	end
	rests[1] = lead
	for k, follower in route.followers or {} do
		local cf = find(follower.placement)
		if cf == nil then
			return nil
		end
		rests[1 + k] = cf
	end
	restCache[route.id] = rests
	return rests
end

local function timelineOf(route: VehicleRouteConfig.Route, rests: { CFrame }): RouteMath.Timeline
	local timeline = timelines[route.id]
	if timeline == nil then
		timeline = RouteMath.compile(route, rests)
		timelines[route.id] = timeline
	end
	return timeline :: RouteMath.Timeline
end

local function startsWith(name: string, prefix: string): boolean
	return string.sub(name, 1, #prefix) == prefix
end

local function makeLight(part: BasePart?, onColor: Color3): Light?
	if part == nil then
		return nil
	end
	return {
		part = part,
		material = part.Material,
		variant = part.MaterialVariant,
		color = part.Color,
		onColor = onColor,
		on = false,
	}
end

-- Soft glow on / off: Neon in a lifted colour, or back to the authored look. Writes on change only.
local function setLight(light: Light?, on: boolean, force: boolean)
	if light == nil or (light.on == on and not force) then
		return
	end
	light.on = on
	local part = light.part
	if part.Parent == nil then
		return
	end
	if on then
		part.MaterialVariant = ""
		part.Material = Enum.Material.Neon
		part.Color = light.onColor
	else
		part.Material = light.material
		part.MaterialVariant = light.variant
		part.Color = light.color
	end
end

--------------------------------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------------------------------

local function attachGate(group: Group)
	local spec = group.route.gate
	if spec == nil or group.gate ~= nil then
		return
	end
	local models = gateModels[group.area]
	local model = models and models[spec.modelKey]
	local asset = MeshAssets[spec.modelKey]
	if model == nil or asset == nil then
		return
	end
	local gate: Gate = {
		model = model,
		parts = {},
		rels = {},
		hinge = CFrame.new(spec.hinge),
		hingeInverse = CFrame.new(-spec.hinge),
		axis = spec.axis.Unit,
		angle = math.rad(spec.angle),
	}
	for _, name in spec.pieces do
		local part = model:FindFirstChild(name)
		local piece = asset.pieces[name]
		if part ~= nil and part:IsA("BasePart") and piece ~= nil then
			local isMesh = part:GetAttribute(MeshPlacement.YawAttribute) == true
			table.insert(gate.parts, part)
			table.insert(gate.rels, MeshPlacement.pieceCFrame(CFrame.identity, piece.offset, isMesh))
		end
	end
	if #gate.parts > 0 then
		group.gate = gate
		group.gateOpen = -1
	end
end

local function onKnockChanged(area: Model)
	local groups = groupsByArea[area]
	if groups == nil then
		return
	end
	local knocked = isKnocked(area)
	for _, group in groups do
		if knocked then
			-- Freeze NOW (before the next Heartbeat): KnockdownFx topples the pieces from here.
			group.knocked = true
			group.active = false
		elseif group.knocked then
			group.knocked = false
			group.resumeAt = os.clock() + TUNING.ResumeAfterKnockdown
			group.force = true
		end
	end
	refreshTimer = math.huge
end

local function groupFor(route: VehicleRouteConfig.Route, area: Model, slot: CFrame, rests: { CFrame }): Group
	local byRoute = groupsByArea[area]
	if byRoute == nil then
		byRoute = {}
		groupsByArea[area] = byRoute
		areaWatch[area] = area:GetAttributeChangedSignal(KnockdownConfig.Attr.Until):Connect(function()
			onKnockChanged(area)
		end)
	end
	local group = byRoute[route.id]
	if group ~= nil then
		return group
	end
	local timeline = timelineOf(route, rests)
	local created: Group = {
		route = route,
		timeline = timeline,
		area = area,
		slot = slot,
		instances = {},
		clock = timeline.start,
		laps = 0,
		holdUntil = 0,
		knocked = isKnocked(area),
		resumeAt = 0,
		active = false,
		halfRate = false,
		slotIndex = groupSlots,
		parked = true,
		force = true,
		distance = math.huge,
		position = (slot * rests[1]).Position,
		visible = false,
		lastWrite = os.clock(),
		seed = random:NextInteger(0, 9973),
		gate = nil,
		gateOpen = -1,
		cargoLoaded = {},
		cargoU = {},
		sync = nil,
	}
	-- Shared clock (route.sync): the first group of the key in this area creates it.
	local syncKey = route.sync
	if syncKey ~= nil then
		local clocks = syncClocks[area]
		if clocks == nil then
			clocks = {}
			syncClocks[area] = clocks
		end
		local clock = clocks[syncKey]
		if clock == nil then
			clock = { master = 0, frame = -1, period = timeline.period }
			clocks[syncKey] = clock
		end
		created.sync = clock
		created.clock = (clock.master + timeline.start) % timeline.period
	end
	groupSlots += 1
	byRoute[route.id] = created
	table.insert(groupList, created)
	attachGate(created)
	return created
end

local function register(model: Model)
	if instByModel[model] ~= nil or not model:IsDescendantOf(Workspace) then
		return
	end
	local key = model:GetAttribute("MeshKey")
	if type(key) ~= "string" then
		return
	end
	local plot = ancestorWith(model, "PlotIndex")
	local area = plot and areaOf(model, plot)
	if area == nil or plot == nil then
		return
	end
	local areaIndex = numberAttr(area, "AreaIndex")
	local plotIndex = numberAttr(plot, "PlotIndex")
	-- The plot's world (WorldId attribute / its plots folder): routes of other worlds never bind.
	local worldId = TycoonWorld.worldOf(plot)
	if
		plotIndex < 1
		or plotIndex > WorldLayout.PlotCount
		or areaIndex < 1
		or areaIndex > WorldLayout.areaCount(worldId)
	then
		return
	end
	-- A gate host (the A8 garage): remember it for its route groups.
	local isGateHost = false
	for _, route in VehicleRouteConfig.Routes do
		if
			route.gate ~= nil
			and route.gate.modelKey == key
			and route.area == areaIndex
			and worldOfRoute(route) == worldId
		then
			isGateHost = true
		end
	end
	if isGateHost then
		local models = gateModels[area]
		if models == nil then
			models = {}
			gateModels[area] = models
		end
		models[key] = model
		local groups = groupsByArea[area]
		if groups ~= nil then
			for _, group in groups do
				attachGate(group)
			end
		end
	end
	local routes = VehicleRouteConfig.byKey[key]
	local asset = MeshAssets[key]
	if routes == nil or asset == nil then
		return
	end
	local slot = WorldLayout.slotOrigin(plotIndex, areaIndex, worldId)
	local pivot = model:GetPivot()
	-- Bind to the route instance whose layout rest spot this model sits on (rack scooters and
	-- other parked copies of a routed key match nothing and stay still).
	local bestRoute: VehicleRouteConfig.Route? = nil
	local bestIndex, bestDistance = 0, TUNING.BindTolerance
	local bestRests: { CFrame }? = nil
	for _, route in routes do
		if route.area == areaIndex and worldOfRoute(route) == worldId then
			local rests = restsOf(route)
			if rests ~= nil then
				for index, rest in rests do
					local distance = ((slot * rest).Position - pivot.Position).Magnitude
					if distance < bestDistance then
						bestRoute, bestIndex, bestDistance, bestRests = route, index, distance, rests
					end
				end
			end
		end
	end
	if bestRoute == nil or bestRests == nil then
		return
	end
	local route = bestRoute :: VehicleRouteConfig.Route
	local rests = bestRests :: { CFrame }
	local group = groupFor(route, area, slot, rests)
	local restWorld = slot * rests[bestIndex]
	local inst: Inst = {
		model = model,
		index = bestIndex,
		group = group,
		pieces = {},
		brake = nil,
		left = nil,
		right = nil,
		sample = RouteMath.newSample(),
		pitch = 0,
		lean = 0,
		phase = random:NextNumber(0, 10),
		restWorld = restWorld,
		flap = 0,
		flapPhase = random:NextNumber(0, TAU),
	}
	-- Cargo group of each piece name.
	local cargoOf: { [string]: number } = {}
	for groupIndex, names in route.cargo or {} do
		for _, name in names do
			cargoOf[name] = groupIndex
		end
	end
	local flyer = route.flyer
	for _, item in model:GetDescendants() do
		if not item:IsA("BasePart") then
			continue
		end
		local part = item :: BasePart
		-- Moving props never block or catch players / rays (CLAUDE.md, R56).
		if part.CanCollide then
			part.CanCollide = false
		end
		if part.CanQuery then
			part.CanQuery = false
		end
		if part.CanTouch then
			part.CanTouch = false
		end
		local piece = asset.pieces[part.Name]
		local isMesh = part:GetAttribute(MeshPlacement.YawAttribute) == true
		local rel = if piece ~= nil
			then MeshPlacement.pieceCFrame(CFrame.identity, piece.offset, isMesh)
			else restWorld:Inverse() * part.CFrame
		local role = ROLE_BODY
		if route.wheelRadius ~= nil and piece ~= nil then
			for _, prefix in VehicleRouteConfig.WheelPrefixes do
				if startsWith(part.Name, prefix) then
					role = ROLE_WHEEL
				end
			end
		end
		local cargo = cargoOf[part.Name] or 0
		if cargo > 0 then
			role = ROLE_CARGO
		end
		-- Flyer wings flap about the model's local Z through their (centre-line) box centre.
		local wing = 0
		if flyer ~= nil and piece ~= nil and cargo == 0 then
			if part.Name == flyer.wingLeft then
				wing = -1
			elseif part.Name == flyer.wingRight then
				wing = 1
			end
			if wing ~= 0 then
				role = ROLE_WING
			end
		end
		table.insert(inst.pieces, {
			part = part,
			rel = rel,
			role = role,
			cargo = cargo,
			spinBase = CFrame.new(rel.Position),
			spinRot = rel.Rotation,
			wing = wing,
			ltm = -1,
		})
		if route.lights then
			if part.Name == VehicleRouteConfig.BrakePiece then
				inst.brake = makeLight(part, TUNING.BrakeColor)
			elseif part.Name == VehicleRouteConfig.IndicatorLeft then
				inst.left = makeLight(part, TUNING.IndicatorColor)
			elseif part.Name == VehicleRouteConfig.IndicatorRight then
				inst.right = makeLight(part, TUNING.IndicatorColor)
			end
		end
	end
	-- A fresh purchase: let its build-in land first (BuildIn attribute on the build wrapper).
	local wrapper = ancestorWith(model, "BuildKey")
	local builtAt = if wrapper ~= nil then numberAttr(wrapper, "BuildIn") else 0
	if builtAt > 0 then
		group.holdUntil = math.max(group.holdUntil, builtAt + TUNING.BuildHold)
	end
	instByModel[model] = inst
	table.insert(group.instances, inst)
	group.force = true
	refreshTimer = math.huge
end

local function removeGroup(group: Group)
	local byRoute = groupsByArea[group.area]
	if byRoute ~= nil then
		byRoute[group.route.id] = nil
		if next(byRoute) == nil then
			groupsByArea[group.area] = nil
			syncClocks[group.area] = nil
			local watch = areaWatch[group.area]
			if watch ~= nil then
				watch:Disconnect()
				areaWatch[group.area] = nil
			end
		end
	end
	local index = table.find(groupList, group)
	if index ~= nil then
		table.remove(groupList, index)
	end
	local active = table.find(activeGroups, group)
	if active ~= nil then
		table.remove(activeGroups, active)
	end
end

local function unregister(model: Model)
	-- A gate host streaming out: detach it from its groups.
	for area, models in gateModels do
		for key, host in models do
			if host == model then
				models[key] = nil
				local groups = groupsByArea[area]
				if groups ~= nil then
					for _, group in groups do
						if group.gate ~= nil and group.gate.model == model then
							group.gate = nil
						end
					end
				end
			end
		end
		if next(models) == nil then
			gateModels[area] = nil
		end
	end
	local inst = instByModel[model]
	if inst == nil then
		return
	end
	instByModel[model] = nil
	local group = inst.group
	local index = table.find(group.instances, inst)
	if index ~= nil then
		table.remove(group.instances, index)
	end
	if #group.instances == 0 then
		removeGroup(group)
	end
	refreshTimer = math.huge
end

--------------------------------------------------------------------------------------------------
-- Writing poses
--------------------------------------------------------------------------------------------------

local function queue(part: BasePart, frame: CFrame)
	if part.Parent ~= nil then
		table.insert(movedParts, part)
		table.insert(movedFrames, frame)
	end
end

local function setLtm(piece: Piece, value: number, force: boolean)
	-- Write on a real change (always land exactly on 0 / 1), or when forced after a knockdown.
	if force or math.abs(piece.ltm - value) > 0.01 or ((value == 0 or value == 1) and piece.ltm ~= value) then
		piece.ltm = value
		if piece.part.Parent ~= nil then
			piece.part.LocalTransparencyModifier = value
		end
	end
end

-- Puts a group back on its layout rest pose (Low tier / Reduce Motion / admin off), once.
local function park(group: Group)
	if group.parked then
		return
	end
	group.parked = true
	group.clock = group.timeline.start
	group.laps = 0
	group.active = false
	local sync = group.sync
	if sync ~= nil then
		sync.master = 0 -- every partner parks too (tier / Reduce Motion / admin are global)
	end
	for _, inst in group.instances do
		inst.pitch = 0
		inst.lean = 0
		inst.flap = 0
		for _, piece in inst.pieces do
			queue(piece.part, inst.restWorld * piece.rel)
			setLtm(piece, 0, true)
		end
		setLight(inst.brake, false, true)
		setLight(inst.left, false, true)
		setLight(inst.right, false, true)
		if inst.index == 1 then
			group.position = inst.restWorld.Position
		end
	end
	local gate = group.gate
	if gate ~= nil then
		local pivot = gate.model:GetPivot()
		for k, part in gate.parts do
			queue(part, pivot * gate.rels[k])
		end
		group.gateOpen = 0
	end
end

-- One instance's pose at the group clock: body, wheels, cargo, fade, lights.
local function writeInst(group: Group, inst: Inst, dt: number, now: number)
	local route = group.route
	local timeline = group.timeline
	local spec = timeline.instances[inst.index]
	local clock = group.clock
	local sample = RouteMath.sample(timeline, clock, inst.index, inst.sample)
	local base = group.slot * RouteMath.localFrame(sample.position, sample.yaw)
	if inst.index == 1 then
		group.position = base.Position
	end
	-- Flyers: ease between perched and working wings, advance the stroke (time-based, so a culled
	-- or half-rate bird keeps its rhythm).
	local flyer = route.flyer
	local wingAngle = 0
	if flyer ~= nil then
		local target = if sample.flying then 1 else 0
		inst.flap += (target - inst.flap) * (1 - math.exp(-dt / flyer.blendSeconds))
		local period = flyer.restPeriod + (flyer.period - flyer.restPeriod) * inst.flap
		inst.flapPhase = (inst.flapPhase + dt * TAU / period) % TAU
		local amplitude = flyer.restAmplitude + (flyer.amplitude - flyer.restAmplitude) * inst.flap
		wingAngle = math.rad(amplitude) * math.sin(inst.flapPhase)
	end
	-- Body: suspension bob, nose dip when braking, lean into bends, tip (mine carts); flyers pitch
	-- with the climb and heave with each wing stroke instead.
	local body = base
	if spec.yaw == nil then
		local blend = 1 - math.exp(-dt / TUNING.SmoothSeconds)
		local pitchTarget = if flyer ~= nil
			then math.clamp(sample.climb * flyer.climbGain, -math.rad(flyer.climbMax), math.rad(flyer.climbMax))
			else math.clamp(sample.gear * sample.accel * TUNING.PitchGain, -TUNING.PitchMax, TUNING.PitchMax)
		inst.pitch += (pitchTarget - inst.pitch) * blend
		local leanTarget = 0
		if route.lean ~= nil and route.lean > 0 then
			leanTarget = math.clamp(
				sample.turn * sample.speed * sample.speed * TUNING.LeanGain * route.lean,
				-TUNING.LeanMax,
				TUNING.LeanMax
			)
		end
		inst.lean += (leanTarget - inst.lean) * blend
		local bob
		if flyer ~= nil then
			-- The body rises on the down-stroke (wings sweeping down after their top at phase pi / 2).
			bob = -flyer.heave * inst.flap * math.cos(inst.flapPhase)
		else
			local amplitude = if sample.speed > 0.1
				then TUNING.BobMove * math.min(sample.speed / 8, 1)
				else TUNING.BobIdle
			bob = amplitude * math.sin(2 * math.pi * TUNING.BobHz * (now + inst.phase))
		end
		body = base * CFrame.new(0, bob, 0) * CFrame.Angles(inst.pitch, 0, inst.lean)
		local tip = RouteMath.tipAt(timeline, clock + spec.offset)
		if tip > 0 and route.tipHinge ~= nil then
			local hinge = route.tipHinge :: Vector3
			body = body
				* CFrame.new(hinge)
				* CFrame.Angles(0, 0, -(route.tipSide or 1) * math.rad(tip))
				* CFrame.new(-hinge)
		end
	end
	-- Wheels: angle from the lap-continuous odometer (forward roll toward -Z = negative X spin).
	local angle = 0
	if route.wheelRadius ~= nil then
		local odometer = group.laps * timeline.netOdo + sample.odo
		angle = (-odometer / route.wheelRadius) % (2 * math.pi)
	end
	-- Cargo state per group (scratch arrays on the group).
	local cargoCount = #timeline.cargo
	for c = 1, cargoCount do
		local loaded, u = RouteMath.cargoAt(timeline, c, clock + spec.offset)
		group.cargoLoaded[c] = loaded
		group.cargoU[c] = u
	end
	local hidden = 1 - sample.alpha
	local force = group.force
	local unloadDir = route.unloadDir or Vector3.new(0, 0, -2)
	for _, piece in inst.pieces do
		local role = piece.role
		if role == ROLE_WHEEL then
			queue(piece.part, base * piece.spinBase * CFrame.Angles(angle, 0, 0) * piece.spinRot)
			setLtm(piece, hidden, force)
		elseif role == ROLE_WING then
			-- Mirrored stroke: + angle lifts both tips (left wing on -X turns by -angle about Z).
			queue(piece.part, body * piece.spinBase * CFrame.Angles(0, 0, piece.wing * wingAngle) * piece.spinRot)
			setLtm(piece, hidden, force)
		elseif role == ROLE_CARGO then
			local loaded = group.cargoLoaded[piece.cargo]
			local u = group.cargoU[piece.cargo] or 1
			local cargoHide = 0
			local frame = body * piece.rel
			if loaded and u < 1 then
				-- Pop in: drop from PopHeight with a bounce, fading in over the first PopFade.
				local drop = TUNING.PopHeight * (1 - RouteMath.bounce(u))
				frame = body * CFrame.new(0, drop, 0) * piece.rel
				cargoHide = math.clamp(1 - u / TUNING.PopFade, 0, 1)
			elseif not loaded then
				if u < 1 then
					-- Pop out: hop along unloadDir with a little arc, fading out.
					local hop = unloadDir * u + Vector3.new(0, 4 * 0.6 * u * (1 - u), 0)
					frame = body * CFrame.new(hop) * piece.rel
					cargoHide = u
				else
					cargoHide = 1
				end
			end
			queue(piece.part, frame)
			setLtm(piece, math.max(hidden, cargoHide), force)
		else
			queue(piece.part, body * piece.rel)
			setLtm(piece, hidden, force)
		end
	end
	-- Lights (soft Neon glow): brake while slowing / just stopped; indicators blink.
	local shown = sample.alpha > 0.5
	setLight(inst.brake, shown and sample.brake, force)
	local blinkOn = shown and (now * TUNING.BlinkHz) % 1 < 0.5
	setLight(inst.left, blinkOn and sample.signal > 0, force)
	setLight(inst.right, blinkOn and sample.signal < 0, force)
end

local function writeGate(group: Group)
	local gate = group.gate
	if gate == nil then
		return
	end
	local open = RouteMath.gateAt(group.timeline, group.clock)
	if math.abs(open - group.gateOpen) < 1e-3 and not group.force then
		return
	end
	group.gateOpen = open
	local pivot = gate.model:GetPivot()
	local swing = pivot * gate.hinge * CFrame.fromAxisAngle(gate.axis, gate.angle * open) * gate.hingeInverse
	for k, part in gate.parts do
		queue(part, swing * gate.rels[k])
	end
end

--------------------------------------------------------------------------------------------------
-- Sounds
--------------------------------------------------------------------------------------------------

local function playEvents(group: Group, from: number, to: number)
	local timeline = group.timeline
	local count = RouteMath.eventsBetween(timeline, from, to, eventHits)
	if count == 0 then
		return
	end
	local position = group.position + Vector3.new(0, 2, 0)
	for _, index in eventHits do
		local event = timeline.events[index]
		local kind = event.kind
		if kind == "honk" then
			-- "Occasionally": a deterministic roll per lap and vehicle.
			local roll = ((group.seed + group.laps * 7919 + index * 31) % 100) / 100
			if roll < (event.chance or TUNING.HonkChance) then
				-- The route's own horn (owner R57: the ptero couriers squawk) or the toy honk.
				local horn = group.route.horn or SOUNDS.Honk
				FxSound.play(horn.key, position, { volume = horn.volume })
			end
		elseif kind == "beep" then
			-- One beeper run per reverse leg (AudioConfig minInterval guards stacking).
			FxSound.play(SOUNDS.Beep.key, position, { volume = SOUNDS.Beep.volume })
		elseif kind == "load" then
			FxSound.play(
				SOUNDS.Load.key,
				position,
				{ pitch = SOUNDS.Load.pitch * (event.pitch or 1), volume = SOUNDS.Load.volume }
			)
		elseif kind == "unload" then
			FxSound.play(SOUNDS.Unload.key, position, { pitch = SOUNDS.Unload.pitch, volume = SOUNDS.Unload.volume })
		end
	end
end

--------------------------------------------------------------------------------------------------
-- Loop
--------------------------------------------------------------------------------------------------

local function byDistance(a: Group, b: Group): boolean
	return a.distance < b.distance
end

local function paused(group: Group): boolean
	return group.knocked or os.clock() < group.resumeAt or serverNow() < group.holdUntil
end

--[[
	Every RefreshInterval (never per frame): budgets from the device tier, knockdown recovery,
	park / un-park, and the nearest MaxActive routes within Range become the moving set.
]]
local function refresh()
	local budget = VehicleRouteConfig.Tiers[FxQuality.tier()] or VehicleRouteConfig.Tiers.Mid
	local enabled = budget.Enabled and globallyEnabled() and not reducedMotion()
	local camera = Workspace.CurrentCamera
	local cameraAt = if camera ~= nil then camera.CFrame.Position else Vector3.zero
	viewCos = -1
	if camera ~= nil then
		local viewport = camera.ViewportSize
		if viewport.Y > 0 then
			viewCos = ViewCone.cosLimit(camera.FieldOfView, viewport.X / viewport.Y, WorldFxConfig.ViewMarginDeg)
		end
	end
	table.clear(candidates)
	for _, group in groupList do
		-- Knockdown over (KnockedUntil passed without an attribute change): resume after the rebuild.
		if group.knocked and not isKnocked(group.area) then
			group.knocked = false
			group.resumeAt = os.clock() + TUNING.ResumeAfterKnockdown
			group.force = true
		end
		if paused(group) then
			group.active = false
			continue
		end
		if not enabled then
			park(group)
			continue
		end
		group.distance = (group.position - cameraAt).Magnitude
		if group.distance <= budget.Range then
			table.insert(candidates, group)
		else
			group.active = false
		end
	end
	table.sort(candidates, byDistance)
	table.clear(activeGroups)
	for index, group in candidates do
		if index <= budget.MaxActive then
			group.active = true
			group.halfRate = group.distance > budget.HalfRateBeyond
			table.insert(activeGroups, group)
		else
			group.active = false
		end
	end
	-- Parked groups' rest writes (queued by park) go out now.
	if #movedParts > 0 then
		Workspace:BulkMoveTo(movedParts, movedFrames, Enum.BulkMoveMode.FireCFrameChanged)
		table.clear(movedParts)
		table.clear(movedFrames)
	end
end

local function step(rawDt: number)
	refreshTimer += rawDt
	if refreshTimer >= TUNING.RefreshInterval then
		refreshTimer = 0
		refresh()
	end
	if #activeGroups == 0 then
		return
	end
	local dt = rawDt * timeScale
	frameCount += 1
	table.clear(movedParts)
	table.clear(movedFrames)
	local camera = Workspace.CurrentCamera
	local cameraFrame = if camera ~= nil then camera.CFrame else CFrame.identity
	local cameraAt, look = cameraFrame.Position, cameraFrame.LookVector
	local near = WorldFxConfig.AlwaysMoveWithin
	local now = os.clock()
	for _, group in activeGroups do
		if group.knocked then
			continue -- frozen this instant by onKnockChanged; refresh drops it
		end
		local timeline = group.timeline
		local from = group.clock
		local sync = group.sync
		if sync ~= nil then
			-- Shared clock: advanced once per frame by whichever member runs first.
			if sync.frame ~= frameCount then
				sync.frame = frameCount
				sync.master = (sync.master + dt) % sync.period
			end
			local clock = (sync.master + timeline.start) % timeline.period
			if clock < from then
				group.laps += 1
			end
			group.clock = clock
			-- Catching up after sitting out (its partner kept flying): no burst of old sounds.
			if (clock - from) % timeline.period > dt + 1e-3 then
				from = clock
			end
		else
			group.clock += dt
			if group.clock >= timeline.period then
				group.clock -= timeline.period
				group.laps += 1
			end
		end
		group.parked = false
		local offset = group.position - cameraAt
		group.visible = ViewCone.visible(offset, look, viewCos, near)
		if group.visible and offset.Magnitude <= SOUNDS.Range then
			playEvents(group, from, group.clock)
		end
		-- Hold the pose this frame: off screen, or the off-beat frame of a far route.
		if not group.force then
			if not group.visible or (group.halfRate and (frameCount + group.slotIndex) % 2 ~= 0) then
				continue
			end
		end
		local writeDt = math.min(now - group.lastWrite, 0.25) * timeScale
		group.lastWrite = now
		for _, inst in group.instances do
			writeInst(group, inst, writeDt, now)
		end
		writeGate(group)
		group.force = false
	end
	if #movedParts > 0 then
		Workspace:BulkMoveTo(movedParts, movedFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

--------------------------------------------------------------------------------------------------
-- Discovery + boot
--------------------------------------------------------------------------------------------------

-- Cheap filter for every streamed instance: only Models whose MeshKey a route (or gate) uses.
local watchedKeys: { [string]: boolean } = {}
for _, route in VehicleRouteConfig.Routes do
	watchedKeys[route.modelKey] = true
	if route.gate ~= nil then
		watchedKeys[route.gate.modelKey] = true
	end
end

local function onAdded(instance: Instance)
	if instance.ClassName ~= "Model" then
		return
	end
	local key = instance:GetAttribute("MeshKey")
	if type(key) == "string" and watchedKeys[key] then
		-- Defer: the Atomic build model's pieces replicate in the same batch.
		task.defer(register, instance :: Model)
	end
end

local function onRemoving(instance: Instance)
	if
		instance.ClassName == "Model"
		and (instByModel[instance :: Model] ~= nil or watchedKeys[tostring(instance:GetAttribute("MeshKey"))])
	then
		unregister(instance :: Model)
	end
end

-- Hooks one world's plots folder (Tycoon/PlotFolders calls this once per folder, any world).
local function watchPlots(folder: Instance, _worldId: string)
	folder.DescendantAdded:Connect(onAdded)
	folder.DescendantRemoving:Connect(onRemoving)
	for _, descendant in folder:GetDescendants() do
		onAdded(descendant)
	end
end

function VehicleRoutes.Init() end

-- Watches every world's plots folder and runs the single Heartbeat loop (idempotent).
function VehicleRoutes.Start()
	if started then
		return
	end
	started = true
	PlotFolders.watch(watchPlots)
	ReplicatedStorage:GetAttributeChangedSignal(ENABLED_ATTRIBUTE):Connect(function()
		refreshTimer = math.huge
	end)
	RunService.Heartbeat:Connect(step)
end

--[[
	Slows every vehicle down (verification captures only; 1 = normal). Clamped 0.1..2.
	Example (Studio playtest, client): VehicleRoutes.setTimeScale(0.5)
]]
function VehicleRoutes.setTimeScale(scale: number)
	timeScale = math.clamp(scale, 0.1, 2)
end

--[[
	Jumps every group of a route id to `seconds` into its loop (verification captures only).
	Example: VehicleRoutes.seek("A6_Truck", 10)
]]
function VehicleRoutes.seek(routeId: string, seconds: number)
	for _, group in groupList do
		if group.route.id == routeId then
			group.clock = seconds % group.timeline.period
			group.force = true
			group.lastWrite = os.clock()
			local sync = group.sync
			if sync ~= nil then
				-- Move the shared clock, so the route's partners jump with it.
				sync.master = (seconds - group.timeline.start) % sync.period
			end
		end
	end
end

--[[
	The compiled timeline of a route id once any of its vehicles has streamed in (verification:
	segment times for captures), else nil.
	Example: VehicleRoutes.timeline("A6_Truck").segs[4].t0
]]
function VehicleRoutes.timeline(routeId: string): RouteMath.Timeline?
	return timelines[routeId]
end

--[[
	Debug / verification counters, plus WHY vehicles would be parked right now (owner R103: tells a
	tier / Reduce Motion / admin park apart from a real fault in a live console).
	@return groups / active / instances / parts counts; started (Start ran); tier (FxQuality);
	        parked = nil (driving) | "tier" | "reducedMotion" | "admin"
	Example: print(VehicleRoutes.stats().parked) --> nil
]]
function VehicleRoutes.stats(): {
	groups: number,
	active: number,
	instances: number,
	parts: number,
	started: boolean,
	tier: string,
	parked: string?,
}
	local instances, parts = 0, 0
	for _, inst in instByModel do
		instances += 1
		parts += #inst.pieces
	end
	local tier = FxQuality.tier()
	local budget = VehicleRouteConfig.Tiers[tier] or VehicleRouteConfig.Tiers.Mid
	local parked: string? = nil
	if not budget.Enabled then
		parked = "tier"
	elseif reducedMotion() then
		parked = "reducedMotion"
	elseif not globallyEnabled() then
		parked = "admin"
	end
	return {
		groups = #groupList,
		active = #activeGroups,
		instances = instances,
		parts = parts,
		started = started,
		tier = tier,
		parked = parked,
	}
end

-- Clock of every registered group (route id -> seconds into its loop), for verification.
function VehicleRoutes.clocks(): { [string]: number }
	local clocks = {}
	for _, group in groupList do
		clocks[`{group.route.id}@{group.area:GetFullName()}`] = group.clock
	end
	return clocks
end

return VehicleRoutes
