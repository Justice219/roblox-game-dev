--!strict
--[[
	KnockdownFx — the client side of the temporary area knockdown (owner R50: "temporarily
	knockdown peoples areas depending on where it hits"). Kid-friendly by construction: the stud
	buildings topple apart like toy bricks with a confetti puff and cartoon bonks, lie scattered
	while the area is down, then the LEGO master-builder fly-in (BuildInController.rebuild) lifts
	every piece off the rubble and snaps it home (hard rule 4). No fire, no debris, nothing removed.

	Discovery: CollectionService tag `KnockdownTarget` (KnockdownConfig.Tag) on ANY instance — a
	plot's `AreaNN` model (Server/Tycoon/Knockdown) or a Rival Factory section (Q2-attack). The
	target is down while its `KnockedUntil` attribute (server time) is in the future; `KnockedAt`
	decides fresh (tumble) vs late (instant rubble), `KnockCenter` is the impact point the bricks
	fly away from. What topples: the target's `Builds` child when it has one (plot areas: never the
	floor, pads or producer anchors), else every part inside except a `Keep` child and parts with
	`KnockdownKeep = true`. Manager builds never topple — their managers sit dazed with stars
	(ManagerController.setAreaDazed). Spinning / bobbing pieces are frozen while down
	(WorldFxController.setSuspended) so nothing fights the rubble.

	Worlds (owner R57, spec §7 "Knockdown (R50) is not used in Dino Valley"): only Nuke Town plot
	areas (and non-plot targets such as the Rival Factory) are ever knocked down. A target tagged
	inside another world's plot (Workspace.Worlds.<id>.Plots) is ignored here, so a stray or future
	tag can never topple a Dino build on the client.

	Transform-only on the EXISTING pieces, locally: their CFrames move on this client only (the
	server copies never change, no physics anywhere), collisions of the knocked builds are switched
	off locally so nobody gets stuck in rubble, and everything is put back exactly before the
	rebuild flies in. A purchase made inside a knocked area (still allowed) stays hidden and builds
	in after the rebuild (BuildInController.setDeferHook). Reduce Motion (Roblox setting or
	profile.settings.reducedMotion): the area fades down to ghostly and fades back up — no flight.

	Performance (owner R11, console + mobile first):
		* ONE RenderStepped connection, connected only while something is down / flying / fading;
		  deadlines are checked every KnockdownConfig.TickSeconds, flights every frame.
		* One BulkMoveTo per frame for every tumbling piece; no Instance.new, no tables or closures
		  per frame (flight / fade lists are reused, swap-removed).
		* Per-device budgets (KnockdownConfig.Client.Tiers via FxQuality): MaxAnimated pieces per
		  knockdown (nearest the impact first; the rest drop straight into the rubble), Range from the
		  camera (beyond it: instant rubble, no sound), confetti scale, MaxBonks sounds.

	Connects to: Shared/Config/KnockdownConfig, Shared/Config/ManagerNpcConfig (manager builds),
	BuildIn/BuildInController (rebuild, settle, setDeferHook), Fx/{WorldFxController, Confetti,
	FxQuality, FxSound}, Npc/ManagerController (setAreaDazed), Tycoon/TycoonWorld (own plot),
	ClientState (reduced motion).

	Boot: controller contract Init() / Start() (idempotent), listed after Tycoon/Npc/ManagerController
	in src/client/init.client.luau; UI/Screens/Knockdown/KnockdownHudScreen also calls Start().
	Example (Studio console, client):
		local fx = require(game.Players.LocalPlayer.PlayerScripts.Client.Tycoon.BuildIn.KnockdownFx)
		print(fx.stats()) --> { targets = 1, down = 1, flying = 0, pieces = 84 }
]]

local CollectionService = game:GetService("CollectionService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local KnockdownConfig = require(ReplicatedStorage.Shared.Config.KnockdownConfig)
local ManagerNpcConfig = require(ReplicatedStorage.Shared.Config.ManagerNpcConfig)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local BuildInController = require(script.Parent.BuildInController)
local Confetti = require(script.Parent.Parent.Fx.Confetti)
local FxQuality = require(script.Parent.Parent.Fx.FxQuality)
local FxSound = require(script.Parent.Parent.Fx.FxSound)
local ManagerController = require(script.Parent.Parent.Npc.ManagerController)
local PlotWatcher = require(script.Parent.Parent.Fx.PlotWatcher)
local TycoonWorld = require(script.Parent.Parent.TycoonWorld)
local WorldFxController = require(script.Parent.Parent.Fx.WorldFxController)

local CFG = KnockdownConfig.Client
local ATTR = KnockdownConfig.Attr
-- Seconds between two builds of one area starting their rebuild fly-in.
local REBUILD_STAGGER = 0.15

type Piece = {
	part: BasePart,
	home: CFrame, -- authored CFrame (restored before the rebuild)
	rubble: CFrame, -- where it lies while down
	collide: boolean, -- original CanCollide (restored)
	t0: number, -- launch (os.clock)
	dur: number,
	arc: number, -- arc height (studs)
	bounce: number, -- landing bounce seconds
	flying: boolean,
	owner: Target,
}

type Container = {
	model: Instance,
	pieces: { Piece }, -- visible parts that topple (or fade / hide)
	colliders: { BasePart }, -- invisible parts: collision off while down
	colliderStates: { boolean },
	deferred: boolean, -- bought while down: hidden, builds in after the rebuild
	buyerIsMe: boolean,
	ancestry: RBXScriptConnection?,
}

type Fade = { pieces: { Piece }, from: number, to: number, t0: number, dur: number }

export type Target = {
	instance: Instance,
	root: Instance?, -- what topples (Builds child, or the instance itself)
	down: boolean,
	untilTime: number,
	center: Vector3,
	groundY: number, -- where rubble rests (the lowest non-ground part's bottom)
	lowest: number, -- the lowest visible bottom (ground-slab detection)
	plot: Model?,
	areaIndex: number?,
	isOwn: boolean,
	containers: { [Instance]: Container },
	-- Containers whose staggered rebuild has not started yet (still lying as rubble).
	pending: { [Instance]: Container },
	connections: { RBXScriptConnection },
	rootConnections: { RBXScriptConnection },
	landed: number,
	bonks: number,
	animatedLeft: number, -- tumble budget left for this knockdown
	animate: boolean, -- this knockdown tumbles (fresh, in range, no Reduce Motion)
	reduced: boolean, -- this knockdown uses the Reduce Motion fade
}

local KnockdownFx = {}

local started = false
local targets: { [Instance]: Target } = {}
local downList: { Target } = {}
local flights: { Piece } = {}
local fades: { Fade } = {}
local stepConnection: RBXScriptConnection? = nil
local tickClock = 0
local random = Random.new()
-- Verification aid (setTimeScale): 1 = normal speed; 0.25 = 4x slower tumbles for frame captures.
local timeScale = 1

-- Scratch arrays reused every frame for BulkMoveTo (no per-frame table churn).
local movedParts: { BasePart } = {}
local movedFrames: { CFrame } = {}

-- Forward declarations (mutual recursion between the state changes and the frame loop).
local ensureLoop: () -> ()

--------------------------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------------------------

-- Reduce Motion: Roblox's own setting OR SellNukes' profile setting.
local function reducedMotion(): boolean
	if GuiService.ReducedMotionEnabled then
		return true
	end
	local profile = ClientState.profile
	local settings = profile and profile.settings
	return type(settings) == "table" and settings.reducedMotion == true
end

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

-- The device budget row.
local function budget(): KnockdownConfig.FxBudget
	return CFG.Tiers[FxQuality.tier()] or CFG.Tiers.Mid
end

-- A finite number attribute, else nil.
local function numberAttr(instance: Instance, name: string): number?
	local value = instance:GetAttribute(name)
	if type(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return value
	end
	return nil
end

-- World-space bottom Y of a (possibly rotated) box with this rotation and size.
local function halfHeight(rotation: CFrame, size: Vector3): number
	return math.abs(rotation.RightVector.Y) * size.X / 2
		+ math.abs(rotation.UpVector.Y) * size.Y / 2
		+ math.abs(rotation.LookVector.Y) * size.Z / 2
end

-- True for parts that must never topple (Rival Factory floors and the like).
local function kept(part: BasePart, root: Instance): boolean
	if part:GetAttribute(ATTR.Keep) == true then
		return true
	end
	local keep = root:FindFirstChild(KnockdownConfig.KeepFolder)
	return keep ~= nil and part:IsDescendantOf(keep)
end

-- The containers (build models) of a target: plot areas → every child of Builds + the area's Base
-- (walls, arch, props; its ground never topples); other targets → the root itself as one container.
local function containersOf(target: Target): { Instance }
	local root = target.root
	if root == nil then
		return {}
	end
	if root ~= target.instance then
		local list = root:GetChildren()
		local base = target.instance:FindFirstChild(KnockdownConfig.BaseModel)
		if base ~= nil then
			table.insert(list, base)
		end
		return list
	end
	return { root }
end

-- Larger world-space horizontal half extent of a (possibly rotated) box.
local function halfWidth(rotation: CFrame, size: Vector3): number
	local x = math.abs(rotation.RightVector.X) * size.X / 2
		+ math.abs(rotation.UpVector.X) * size.Y / 2
		+ math.abs(rotation.LookVector.X) * size.Z / 2
	local z = math.abs(rotation.RightVector.Z) * size.X / 2
		+ math.abs(rotation.UpVector.Z) * size.Y / 2
		+ math.abs(rotation.LookVector.Z) * size.Z / 2
	return math.max(x, z)
end

-- A ground piece (floor slab, driveway, road, track): thin and lying at the area's lowest level.
-- It never topples and keeps its collision, so nobody falls through the area.
local function isGround(target: Target, part: BasePart): boolean
	local half = halfHeight(part.CFrame.Rotation, part.Size)
	return half * 2 <= CFG.GroundMaxHeight and part.Position.Y - half <= target.lowest + CFG.GroundTolerance
end

-- Is this container a manager's build (managers sit dazed instead of toppling)?
local function isManagerBuild(model: Instance): boolean
	return ManagerNpcConfig.ownsModel(model.Name)
end

-- Optional hooks on modules other agents own (guarded: a missing hook never breaks the FX).
local function setSuspended(root: Instance, on: boolean)
	local hook = (WorldFxController :: any).setSuspended
	if type(hook) == "function" then
		pcall(hook, root, on)
	end
end

local function setDazed(target: Target, on: boolean)
	local hook = (ManagerController :: any).setAreaDazed
	if type(hook) == "function" and target.plot ~= nil and target.areaIndex ~= nil then
		pcall(hook, target.plot, target.areaIndex, on)
	end
end

--------------------------------------------------------------------------------------------------
-- Toppling
--------------------------------------------------------------------------------------------------

--[[
	Where a piece lands: pushed away from the impact (further when near it, less when big), tipped
	over outward about a horizontal axis plus a random yaw, resting on the area's lowest level.
]]
local function rubbleFor(part: BasePart, home: CFrame, center: Vector3, groundY: number): CFrame
	local position = home.Position
	local flat = Vector3.new(position.X - center.X, 0, position.Z - center.Z)
	local distance = flat.Magnitude
	local direction: Vector3
	if distance > 0.05 then
		direction = flat / distance
	else
		local angle = random:NextNumber(0, 2 * math.pi)
		direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
	end
	local size = part.Size
	local biggest = math.max(size.X, size.Y, size.Z)
	local nearness = 1 - math.clamp(distance / CFG.PushFalloff, 0, 1)
	local push = (CFG.PushFar + (CFG.PushNear - CFG.PushFar) * nearness) * random:NextNumber(0.75, 1.2)
	if biggest > CFG.BigPiece then
		push *= CFG.BigPiece / biggest
	end
	local side = Vector3.new(-direction.Z, 0, direction.X)
	local land = position + direction * push + side * random:NextNumber(-CFG.PushJitter, CFG.PushJitter)
	-- Axis up × direction tips the piece's top toward `direction` (outward from the blast).
	local axis = Vector3.new(direction.Z, 0, -direction.X)
	-- Flat pieces (roofs, shelves) only tip a little; tall ones (walls, posts) fall over.
	local isFlat = halfHeight(home.Rotation, size) < CFG.FlatAspect * halfWidth(home.Rotation, size)
	local range = if isFlat then CFG.FlatTiltDegrees else CFG.TiltDegrees
	local tilt = math.rad(random:NextNumber(range.Min, range.Max))
	local yaw = math.rad(random:NextNumber(-CFG.YawDegrees, CFG.YawDegrees))
	local rotation = CFrame.fromAxisAngle(Vector3.yAxis, yaw) * CFrame.fromAxisAngle(axis, tilt) * home.Rotation
	return CFrame.new(land.X, groundY + halfHeight(rotation, size), land.Z) * rotation
end

-- Collects a container's pieces (sets their rubble later). Never called per frame.
local function collect(target: Target, model: Instance): Container
	local container: Container = {
		model = model,
		pieces = {},
		colliders = {},
		colliderStates = {},
		deferred = false,
		buyerIsMe = false,
		ancestry = nil,
	}
	local root = target.root or model
	local function consider(item: Instance)
		if not item:IsA("BasePart") or kept(item, root) or isGround(target, item) then
			return
		end
		if item.Transparency >= 1 then
			table.insert(container.colliders, item)
			table.insert(container.colliderStates, item.CanCollide)
		else
			table.insert(container.pieces, {
				part = item,
				home = item.CFrame,
				rubble = item.CFrame,
				collide = item.CanCollide,
				t0 = 0,
				dur = 0,
				arc = 0,
				bounce = CFG.BounceSeconds,
				flying = false,
				owner = target,
			})
		end
	end
	if model:IsA("BasePart") then
		consider(model)
	end
	for _, item in model:GetDescendants() do
		consider(item)
	end
	return container
end

-- Collisions of a container on / off locally (rubble is walk-through; restored exactly).
local function setCollisions(container: Container, down: boolean)
	for _, piece in container.pieces do
		if piece.part.Parent ~= nil then
			piece.part.CanCollide = if down then false else piece.collide
		end
	end
	for i, part in container.colliders do
		if part.Parent ~= nil then
			part.CanCollide = if down then false else container.colliderStates[i]
		end
	end
end

-- Hides / shows a container's visible pieces on this client (LocalTransparencyModifier).
local function setLocalFade(container: Container, value: number)
	for _, piece in container.pieces do
		if piece.part.Parent ~= nil then
			piece.part.LocalTransparencyModifier = value
		end
	end
end

-- Starts a Reduce Motion fade over a container's pieces.
local function startFade(container: Container, from: number, to: number)
	table.insert(
		fades,
		{ pieces = container.pieces, from = from, to = to, t0 = os.clock(), dur = CFG.ReducedFadeSeconds }
	)
	setLocalFade(container, from)
	ensureLoop()
end

-- Knocks one container down (topple / snap / fade). `fresh` = the knockdown just happened.
local function knockContainer(target: Target, model: Instance, fresh: boolean)
	if target.containers[model] ~= nil or (model:IsA("Model") and isManagerBuild(model)) then
		return
	end
	local pending = target.pending[model]
	if pending ~= nil then
		-- Knocked down again before its staggered rebuild started: it is still rubble (and its
		-- `home` CFrames are still the authored ones), so it simply stays down.
		target.pending[model] = nil
		target.containers[model] = pending
		return
	end
	BuildInController.settle(model) -- a purchase still flying in: finish it first
	local container = collect(target, model)
	target.containers[model] = container
	setCollisions(container, true)
	if target.reduced then
		if fresh then
			startFade(container, 0, CFG.ReducedFade)
		else
			setLocalFade(container, CFG.ReducedFade)
		end
		return
	end
	-- Nearest the impact first: they tumble; beyond the budget they drop straight into the rubble.
	local center = target.center
	table.sort(container.pieces, function(a: Piece, b: Piece): boolean
		return (a.home.Position - center).Magnitude < (b.home.Position - center).Magnitude
	end)
	local clock = os.clock()
	table.clear(movedParts)
	table.clear(movedFrames)
	for _, piece in container.pieces do
		piece.rubble = rubbleFor(piece.part, piece.home, center, target.groundY)
		if fresh and target.animate and target.animatedLeft > 0 then
			target.animatedLeft -= 1
			local flat = Vector3.new(piece.home.Position.X - center.X, 0, piece.home.Position.Z - center.Z)
			piece.t0 = clock
				+ (
						CFG.Spread * math.clamp(flat.Magnitude / CFG.PushFalloff, 0, 1)
						+ random:NextNumber(0, CFG.SpreadJitter)
					)
					/ timeScale
			piece.dur = random:NextNumber(CFG.FlightSeconds.Min, CFG.FlightSeconds.Max) / timeScale
			piece.bounce = CFG.BounceSeconds / timeScale
			piece.arc = random:NextNumber(CFG.ArcHeight.Min, CFG.ArcHeight.Max)
			piece.flying = true
			table.insert(flights, piece)
		elseif piece.part.Parent ~= nil then
			table.insert(movedParts, piece.part)
			table.insert(movedFrames, piece.rubble)
		end
	end
	if #movedParts > 0 then
		Workspace:BulkMoveTo(movedParts, movedFrames, Enum.BulkMoveMode.FireCFrameChanged)
		table.clear(movedParts)
		table.clear(movedFrames)
	end
	-- Streamed out / destroyed mid-knockdown: forget it (a streamed-in copy comes back clean).
	container.ancestry = model.AncestryChanged:Connect(function()
		if not model:IsDescendantOf(Workspace) then
			local current = target.containers[model]
			if current ~= nil then
				target.containers[model] = nil
				for _, piece in current.pieces do
					piece.flying = false
				end
				if current.ancestry ~= nil then
					current.ancestry:Disconnect()
				end
			end
		end
	end)
	ensureLoop()
end

--[[
	Measures the target once per knockdown: `lowest` = the lowest visible bottom (ground-slab
	detection), `groundY` = the lowest bottom of the parts that are NOT ground (what buildings stand
	on: the floor's top), where the rubble comes to rest.
]]
local function measureGround(target: Target)
	local lowest = math.huge
	local models = containersOf(target)
	for _, model in models do
		for _, item in model:GetDescendants() do
			if item:IsA("BasePart") and item.Transparency < 1 then
				lowest = math.min(lowest, item.Position.Y - halfHeight(item.CFrame.Rotation, item.Size))
			end
		end
	end
	target.lowest = if lowest < math.huge then lowest else target.center.Y
	local standing = math.huge
	for _, model in models do
		for _, item in model:GetDescendants() do
			if item:IsA("BasePart") and item.Transparency < 1 and not isGround(target, item) then
				standing = math.min(standing, item.Position.Y - halfHeight(item.CFrame.Rotation, item.Size))
			end
		end
	end
	target.groundY = if standing < math.huge then standing else target.lowest
end

-- A build container appeared under a knocked target's root (streamed in, or a purchase).
local function onRootChild(target: Target, child: Instance)
	task.defer(function()
		if not target.down or child.Parent == nil then
			return
		end
		-- A fresh purchase is the defer hook's (PlotWatcher reports it one frame later).
		local stamp = numberAttr(child, "BuildIn")
		if stamp ~= nil and serverNow() - stamp <= CFG.FreshWindow then
			return
		end
		knockContainer(target, child, false)
	end)
end

-- Plays the knockdown of a target (fresh = it just happened → tumble + confetti + bonks).
local function knock(target: Target, fresh: boolean)
	target.down = true
	table.insert(downList, target)
	local tier = budget()
	local camera = Workspace.CurrentCamera
	local distance = if camera ~= nil then (camera.CFrame.Position - target.center).Magnitude else 0
	target.reduced = reducedMotion()
	target.animate = fresh and not target.reduced and distance <= tier.Range
	target.animatedLeft = tier.MaxAnimated
	target.landed = 0
	target.bonks = 0
	local root = target.root
	if root ~= nil then
		setSuspended(target.instance, true)
		measureGround(target)
		for _, model in containersOf(target) do
			knockContainer(target, model, fresh)
		end
		if root ~= target.instance then
			table.insert(
				target.rootConnections,
				root.ChildAdded:Connect(function(child: Instance)
					onRootChild(target, child)
				end)
			)
			-- The area's Base streams in on its own (Atomic): it lies as rubble too.
			table.insert(
				target.rootConnections,
				target.instance.ChildAdded:Connect(function(child: Instance)
					if child.Name == KnockdownConfig.BaseModel then
						onRootChild(target, child)
					end
				end)
			)
		end
	end
	setDazed(target, true)
	if target.animate then
		local scale = tier.ConfettiScale
		local puff = target.center + Vector3.new(0, 3, 0)
		Confetti.burst(puff, math.floor(CFG.Confetti * scale), math.floor(CFG.Sparkle * scale))
		FxSound.play("pop", puff, { pitch = 0.8 })
	end
	ensureLoop()
end

--------------------------------------------------------------------------------------------------
-- Rebuilding
--------------------------------------------------------------------------------------------------

-- Puts one container back and starts its rebuild fly-in (or fade-up / instant when not animated).
local function rebuildContainer(target: Target, container: Container, animate: boolean)
	if container.ancestry ~= nil then
		container.ancestry:Disconnect()
		container.ancestry = nil
	end
	local model = container.model
	local starts: { [BasePart]: CFrame } = {}
	table.clear(movedParts)
	table.clear(movedFrames)
	for _, piece in container.pieces do
		piece.flying = false
		if piece.part.Parent ~= nil then
			starts[piece.part] = piece.part.CFrame
			table.insert(movedParts, piece.part)
			table.insert(movedFrames, piece.home)
		end
	end
	if not container.deferred and #movedParts > 0 then
		Workspace:BulkMoveTo(movedParts, movedFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
	table.clear(movedParts)
	table.clear(movedFrames)
	setCollisions(container, false)
	if target.reduced then
		startFade(container, if container.deferred then 1 else CFG.ReducedFade, 0)
		return
	end
	setLocalFade(container, 0)
	if animate and model:IsA("Model") and model:IsDescendantOf(Workspace) then
		BuildInController.rebuild(model, {
			starts = if container.deferred then nil else starts,
			isOwner = if container.deferred then container.buyerIsMe else target.isOwn,
			areaIndex = target.areaIndex,
		})
	end
end

-- Ends a target's knockdown: every container flies back (staggered from the impact outward).
local function rebuild(target: Target, animate: boolean)
	if not target.down then
		return
	end
	target.down = false
	local index = table.find(downList, target)
	if index ~= nil then
		table.remove(downList, index)
	end
	for _, connection in target.rootConnections do
		connection:Disconnect()
	end
	table.clear(target.rootConnections)
	local ordered: { Container } = {}
	for _, container in target.containers do
		table.insert(ordered, container)
	end
	table.clear(target.containers)
	local center = target.center
	-- Nearest the impact first, like the topple; deferred purchases last.
	local function distanceOf(container: Container): number
		if container.deferred then
			return math.huge
		end
		local model = container.model
		local position = if model:IsA("Model")
			then model:GetPivot().Position
			elseif model:IsA("BasePart") then model.Position
			else center
		return (position - center).Magnitude
	end
	table.sort(ordered, function(a: Container, b: Container): boolean
		return distanceOf(a) < distanceOf(b)
	end)
	local camera = Workspace.CurrentCamera
	local inRange = camera ~= nil and (camera.CFrame.Position - center).Magnitude <= budget().Range
	for _, container in target.pending do
		rebuildContainer(target, container, false) -- an older stagger still waiting: finish it now
	end
	table.clear(target.pending)
	for order, container in ordered do
		if order == 1 or not animate or not inRange then
			rebuildContainer(target, container, animate and inRange)
		else
			-- Staggered so the area reassembles build by build (not one burst of ghosts). If the
			-- area is knocked down again first, knockContainer takes it back from `pending`.
			target.pending[container.model] = container
			task.delay((order - 1) * REBUILD_STAGGER, function()
				if target.pending[container.model] == container then
					target.pending[container.model] = nil
					rebuildContainer(target, container, true)
				end
			end)
		end
	end
	if target.root ~= nil then
		setSuspended(target.instance, false)
	end
	setDazed(target, false)
end

--------------------------------------------------------------------------------------------------
-- Targets
--------------------------------------------------------------------------------------------------

-- Re-reads a target's attributes: knock it down / update its deadline / rebuild it.
local function evaluate(target: Target)
	local untilTime = numberAttr(target.instance, ATTR.Until) or 0
	local now = serverNow()
	target.untilTime = untilTime
	local center = target.instance:GetAttribute(ATTR.Center)
	if typeof(center) == "Vector3" then
		target.center = center
	end
	if untilTime > now and not target.down then
		local at = numberAttr(target.instance, ATTR.At) or 0
		knock(target, now - at <= CFG.FreshWindow)
	elseif untilTime <= now and target.down then
		rebuild(target, true)
	end
end

-- Forgets a target (tag removed / destroyed / streamed out): pieces back instantly.
local function dropTarget(instance: Instance)
	local target = targets[instance]
	if target == nil then
		return
	end
	targets[instance] = nil
	for _, connection in target.connections do
		connection:Disconnect()
	end
	rebuild(target, false)
end

-- A tagged instance appeared (or streamed in).
local function onTagged(instance: Instance)
	if targets[instance] ~= nil or not instance:IsDescendantOf(Workspace) then
		return
	end
	local plot = TycoonWorld.plotOf(instance)
	-- Nuke Town only (owner R57): a plot target in another world never topples.
	if plot ~= nil and TycoonWorld.worldOf(plot) ~= WorldsConfig.MAIN then
		return
	end
	local areaIndex = numberAttr(instance, "AreaIndex")
	local root: Instance? = instance:FindFirstChild(KnockdownConfig.BuildsFolder)
	if root == nil and areaIndex == nil then
		root = instance -- a non-plot target topples as a whole (minus Keep)
	end
	local pivot = if instance:IsA("Model") then instance:GetPivot().Position else Vector3.zero
	local target: Target = {
		instance = instance,
		root = root,
		down = false,
		untilTime = 0,
		center = pivot,
		groundY = pivot.Y,
		lowest = pivot.Y,
		plot = plot,
		areaIndex = areaIndex,
		isOwn = plot ~= nil and TycoonWorld.isMine(instance),
		containers = {},
		pending = {},
		connections = {},
		rootConnections = {},
		landed = 0,
		bonks = 0,
		animatedLeft = 0,
		animate = false,
		reduced = false,
	}
	targets[instance] = target
	table.insert(
		target.connections,
		instance:GetAttributeChangedSignal(ATTR.Until):Connect(function()
			evaluate(target)
		end)
	)
	table.insert(
		target.connections,
		instance.AncestryChanged:Connect(function()
			if not instance:IsDescendantOf(Workspace) then
				dropTarget(instance)
			end
		end)
	)
	evaluate(target)
end

-- BuildInController defer hook: a FRESH purchase inside a knocked-down area waits for its rebuild.
local function deferBuild(model: Model, info: PlotWatcher.BuildInfo): boolean
	for _, target in downList do
		local root = target.root
		if root ~= nil and model:IsDescendantOf(root) and target.containers[model] == nil then
			local container = collect(target, model)
			container.deferred = true
			container.buyerIsMe = info.isBuyer
			target.containers[model] = container
			setCollisions(container, true)
			setLocalFade(container, 1)
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------------------------------
-- Frame loop
--------------------------------------------------------------------------------------------------

-- Lands one piece: bonk on the beat (budgeted), counts it.
local function landed(piece: Piece)
	local target = piece.owner
	target.landed += 1
	if target.landed % CFG.BonkEvery == 1 and target.bonks < budget().MaxBonks then
		target.bonks += 1
		FxSound.play(
			"clack",
			piece.rubble.Position,
			{ pitch = random:NextNumber(CFG.BonkPitch.Min, CFG.BonkPitch.Max), volume = 1.2 }
		)
	end
end

local function step(dt: number)
	local clock = os.clock()
	-- Tumbling pieces: arc from home to the rubble while tipping over, then a small bounce.
	if #flights > 0 then
		table.clear(movedParts)
		table.clear(movedFrames)
		local i = #flights
		while i >= 1 do
			local piece = flights[i]
			local part = piece.part
			local finished = not piece.flying or part.Parent == nil
			if not finished then
				local elapsed = clock - piece.t0
				if elapsed >= 0 then
					local u = math.min(elapsed / piece.dur, 1)
					local frame: CFrame
					if u < 1 then
						local position = piece.home.Position:Lerp(piece.rubble.Position, u)
							+ Vector3.new(0, piece.arc * 4 * u * (1 - u), 0)
						local turn = 1 - (1 - u) * (1 - u) -- ease-out: tips over fast, settles
						frame = CFrame.new(position) * piece.home.Rotation:Lerp(piece.rubble.Rotation, turn)
					else
						local v = (elapsed - piece.dur) / piece.bounce
						if v >= 1 then
							frame = piece.rubble
							finished = true
							landed(piece)
						else
							frame = piece.rubble + Vector3.new(0, CFG.BounceHeight * math.sin(math.pi * v), 0)
						end
					end
					table.insert(movedParts, part)
					table.insert(movedFrames, frame)
				end
			end
			if finished then
				piece.flying = false
				flights[i] = flights[#flights]
				flights[#flights] = nil
			end
			i -= 1
		end
		if #movedParts > 0 then
			Workspace:BulkMoveTo(movedParts, movedFrames, Enum.BulkMoveMode.FireCFrameChanged)
		end
	end
	-- Reduce Motion fades.
	if #fades > 0 then
		local f = #fades
		while f >= 1 do
			local fade = fades[f]
			local u = math.clamp((clock - fade.t0) / fade.dur, 0, 1)
			local value = fade.from + (fade.to - fade.from) * u
			for _, piece in fade.pieces do
				if piece.part.Parent ~= nil then
					piece.part.LocalTransparencyModifier = value
				end
			end
			if u >= 1 then
				fades[f] = fades[#fades]
				fades[#fades] = nil
			end
			f -= 1
		end
	end
	-- Deadlines (the server clears KnockedUntil too; whichever comes first rebuilds).
	tickClock += dt
	if tickClock >= KnockdownConfig.TickSeconds then
		tickClock = 0
		local now = serverNow()
		for d = #downList, 1, -1 do
			local target = downList[d]
			if target ~= nil and target.untilTime <= now then
				rebuild(target, true)
			end
		end
	end
	if #flights == 0 and #fades == 0 and #downList == 0 and stepConnection ~= nil then
		stepConnection:Disconnect()
		stepConnection = nil
	end
end

ensureLoop = function()
	if stepConnection == nil then
		tickClock = 0
		stepConnection = RunService.RenderStepped:Connect(step)
	end
end

--------------------------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------------------------

function KnockdownFx.Init() end

-- Subscribes to the tag + installs the BuildIn defer hook (idempotent).
function KnockdownFx.Start()
	if started then
		return
	end
	started = true
	BuildInController.setDeferHook(deferBuild)
	CollectionService:GetInstanceAddedSignal(KnockdownConfig.Tag):Connect(onTagged)
	CollectionService:GetInstanceRemovedSignal(KnockdownConfig.Tag):Connect(dropTarget)
	for _, instance in CollectionService:GetTagged(KnockdownConfig.Tag) do
		onTagged(instance)
	end
end

--[[
	Is this instance (or an ancestor target) knocked down on this client right now?
	Example: KnockdownFx.isDown(areaModel) --> true
]]
function KnockdownFx.isDown(instance: Instance): boolean
	for _, target in downList do
		if instance == target.instance or instance:IsDescendantOf(target.instance) then
			return true
		end
	end
	return false
end

--[[
	Slows every NEW knockdown tumble down (verification frame captures only; default 1). Clamped
	0.1..1. Pair with BuildInController.setTimeScale for the rebuild.
	Example (Studio playtest, eval_client_runtime): KnockdownFx.setTimeScale(0.25)
]]
function KnockdownFx.setTimeScale(scale: number)
	timeScale = math.clamp(scale, 0.1, 1)
end

-- Debug / verification counters.
function KnockdownFx.stats(): { targets: number, down: number, flying: number, fading: number, pieces: number }
	local count, pieces = 0, 0
	for _, target in targets do
		count += 1
		for _, container in target.containers do
			pieces += #container.pieces
		end
	end
	return { targets = count, down = #downList, flying = #flights, fading = #fades, pieces = pieces }
end

return KnockdownFx
