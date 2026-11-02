--!strict
--[[
	ModelViewport — a UI slot that shows a REAL 3D game model (owner R39: "in the shop we should
	use real 3d models"): a ViewportFrame + WorldModel with soft studio lighting, the camera framed
	automatically from the model's bounds and a slow turntable spin. Until the model's meshes have
	loaded (or forever, if they never do) the slot shows the 2D icon instead.

	What it can show (a Spec):
		key    any MeshAssets key (shop props "Shop_CashStack", nukes "NukeT3", "BuyPad", ...)
		pet    a PetConfig id  (built by Pets/PetModels: the pet's recolours + rarity scale, i.e.
		       exactly the follower the player gets — "Golden Atom Pup" is AtomPup in gold)
		egg    an EggConfig id (PetModels.egg)       crate  a CrateConfig id (PetModels.crate)
		copies 1..5 copies of the model in a little pile ("x5 Lucky Spins" shows three tokens)

	Loading (key specs; pet / egg / crate meshes load through PetModels' own cache so a pet
	the player already follows with is never fetched twice):
		* ONE template MeshPart per MeshId for the whole client (AssetService:CreateMeshPartAsync
		  in pcall), cloned per model. Requests are de-duplicated, at most Config.MaxInFlight run at
		  once (Config.MaxBackgroundInFlight for prefetch, which never runs ahead of a visible
		  slot; a slot that needs a prefetching id promotes it), retried with backoff, and a failed
		  id cools down for Config.RetryCooldown seconds (the icon stays meanwhile).
		* Pieces are placed exactly like the server's MeshLibrary (Shared/World/MeshPlacement: the
		  FBX import yaw undone, MeshYaw attribute, the Neon glow budget, stud MaterialVariants).
		* `ModelViewport.prefetch(specs)` warms templates in the background (the Shop does it a
		  little after boot so its first open is already 3D).

	Performance (owner R11, console + mobile first):
		* Framing is exact: the camera distance is solved (ModelViewportLogic.fitProfile) so the
		  model's part corners fill the viewport at its widest turntable angle and never clip; the
		  viewport is Config.Overflow (1.2) x its slot, centred, so the model fills ~85 % of the
		  slot most of the time and only its widest corners pass into the slot's margin.
		* The camera orbits; the model never moves: a spinning slot costs two property writes per
		  step (Camera.CFrame + the light direction). A still slot costs nothing per frame.
		* Spinning runs on Widgets/OfferFx's single visibility-gated PreRender driver: a slot spins
		  only while it is really on screen (its ScreenGui enabled, every ancestor visible, not
		  clipped away by the scrolling list) — a closed screen or a scrolled-away card is paused.
		* At most Config.MaxLive slots spin at once per FxQuality tier (High 12, Mid 8, Low 0 =
		  still frames only); the others hold a still three-quarter frame. Slots of viewports that
		  left the screen are freed every Config.PruneSeconds. Reduce Motion stops every spin.
		* Pooled: ViewportFrame rigs (frame + camera + WorldModel) and built models are reused when
		  a slot changes content or is destroyed; a ViewportFrame exists only once a model is ready.
		* Every part is Anchored, CanCollide / CanQuery / CanTouch false, CastShadow false.

	Connects to: Widgets/{ModelViewportLogic (maths + tunables), OfferFx (spin driver)},
	Kit/StudUI (fallback icon), Pets/PetModels (pet / egg / crate models), Tycoon/Fx/FxQuality,
	Shared/Config/{MeshAssets, WorldMaterialConfig}, Shared/World/MeshPlacement, Shared/Util/Signal.
	Used by Screens/Shop (ShopCard, PackCard).

	Security: display only; specs come from client config (Screens/Shop/ShopModels), never from
	the network. Unknown keys / ids show the icon.

	Example:
		local view = ModelViewport.new({
			key = "Shop_SpinToken", copies = 3, icon = "Spins",
			size = UDim2.fromOffset(96, 96), spin = true, parent = tile,
		})
		view.set({ key = "Shop_GemCluster" }, "Gems") -- swap content (no-op when unchanged)
		view.Destroy()                                 -- rig + model go back to the pools
]]

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FxQuality = require(script.Parent.Parent.Parent.Tycoon.Fx.FxQuality)
local MeshAssets = require(ReplicatedStorage.Shared.Config.MeshAssets)
local MeshPlacement = require(ReplicatedStorage.Shared.World.MeshPlacement)
local ModelViewportLogic = require(script.Parent.ModelViewportLogic)
local OfferFx = require(script.Parent.OfferFx)
local OfferFxConfig = require(ReplicatedStorage.Shared.Config.OfferFxConfig)
local PetModels = require(script.Parent.Parent.Parent.Pets.PetModels)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local WorldMaterialConfig = require(ReplicatedStorage.Shared.Config.WorldMaterialConfig)

-- What a slot shows (see the module header). The first of pet / egg / crate / key set wins.
export type Spec = {
	key: string?,
	pet: string?,
	egg: string?,
	crate: string?,
	copies: number?,
}

export type Options = {
	-- The spec fields (ModelViewport.new{ key = "Shop_CashStack", ... }).
	key: string?,
	pet: string?,
	egg: string?,
	crate: string?,
	copies: number?,
	icon: string?, -- StudUI icon key shown until the model is ready (nil = empty until then)
	size: UDim2?,
	position: UDim2?,
	anchor: Vector2?,
	zIndex: number?,
	layoutOrder: number?,
	spin: boolean?, -- slow turntable while on screen (default true)
	zoom: number?, -- magnification (1 = the whole model fits; 1.2 = 20 % closer)
	overflow: number?, -- viewport size / slot size, centred (default Config.Overflow; 1 = inside)
	yaw: number?, -- resting turntable angle in degrees (default Config.RestYaw)
	name: string?,
	parent: Instance?,
}

export type Viewport = {
	-- The slot: size / position / anchor it like an icon (the icon + viewport fill it).
	frame: Frame,
	-- Shows another spec (and icon, when given). No-op when the spec is unchanged.
	set: (spec: Spec?, icon: string?) -> (),
	setSpin: (on: boolean) -> (),
	-- True once the 3D model is on screen (false while the icon stands in).
	showsModel: () -> boolean,
	Destroy: () -> (),
}

type Kind = "key" | "pet" | "egg" | "crate"
type Resolved = { kind: Kind, id: string, meshKey: string, copies: number, specId: string }
type Rig = { viewport: ViewportFrame, camera: Camera, world: WorldModel }
type Entry = {
	holder: Frame,
	zIndex: number,
	iconKey: string?,
	iconFrame: Frame?,
	resolved: Resolved?,
	rig: Rig?,
	model: Model?,
	center: Vector3,
	distance: number,
	aspect: number,
	angle: number,
	restYaw: number,
	zoom: number,
	overflow: number,
	spin: boolean,
	fx: OfferFx.Handle?,
	slot: boolean,
	dead: boolean,
	sizeConnection: RBXScriptConnection?,
}
type LoadState = "loading" | "ready" | "failed"
-- A built model's turntable bounds: the axis centre (ModelViewportLogic.sweptBounds) and the
-- convex (radius, height) profile hull the exact fit frames (ModelViewportLogic.profile).
type Bounds = { center: Vector3, hull: { { number } } }
type Queued = { thread: thread, id: number }

local ModelViewport = {}

local Config = ModelViewportLogic.Config
local MANIFEST = MeshAssets :: { [string]: any }
local TEMPLATE_OPTIONS = {
	-- Viewport pieces never collide: the cheapest collision geometry.
	CollisionFidelity = Enum.CollisionFidelity.Box,
	RenderFidelity = Enum.RenderFidelity.Automatic,
}
-- Design px the fallback glyph is built at (it then scales to fill the slot).
local ICON_DESIGN_SIZE = 96

-- Fires (meshKey) when every template of a `key` spec has loaded.
local Ready = Signal.new() :: Signal.Signal<string>

-- ── Template cache (key specs) ──────────────────────────────────────────────────────────────
local templates: { [number]: MeshPart } = {}
local failedUntil: { [number]: number } = {}
-- Threads waiting for an id already being fetched.
local waitingIds: { [number]: { thread } } = {}
local keyState: { [string]: LoadState } = {}
local keyRetryAt: { [string]: number } = {}
-- Concurrency limiter: requests in flight + FIFO queues (visible slots first).
local activeLoads = 0
local foreground: { Queued } = {}
local background: { Queued } = {}

-- ── Live slots ───────────────────────────────────────────────────────────────────────────────
local entries: { [Entry]: boolean } = {}
local waitingByKey: { [string]: { [Entry]: boolean } } = {}
local slotHolders: { [Entry]: boolean } = {}
local slotCount = 0
local lastPrune = 0
local maxLive = 0

-- ── Framing ──────────────────────────────────────────────────────────────────────────────────
-- Turntable bounds per built model (weak keys) + a reused corner buffer (no per-call garbage).
local boundsCache: { [Model]: Bounds } = setmetatable({}, { __mode = "k" }) :: any
local cornerScratch: { Vector3 } = {}

-- ── Pools ────────────────────────────────────────────────────────────────────────────────────
local rigPool: { Rig } = {}
local modelPool: { [string]: { Model } } = {}
local pooledModels = 0

--------------------------------------------------------------------------------------------------
-- Template loading
--------------------------------------------------------------------------------------------------

-- Starts queued requests while their slot budget allows (visible slots first).
local function pump()
	while true do
		local nextItem: Queued? = nil
		if #foreground > 0 and activeLoads < Config.MaxInFlight then
			nextItem = table.remove(foreground, 1)
		elseif #foreground == 0 and #background > 0 and activeLoads < Config.MaxBackgroundInFlight then
			nextItem = table.remove(background, 1)
		end
		if nextItem == nil then
			return
		end
		activeLoads += 1
		task.spawn(nextItem.thread)
	end
end

-- Takes a request slot for `id`, yielding in the right queue until one is free.
local function acquireLoadSlot(id: number, urgent: boolean)
	local limit = if urgent then Config.MaxInFlight else Config.MaxBackgroundInFlight
	if activeLoads < limit and (urgent or #foreground == 0) then
		activeLoads += 1
		return
	end
	table.insert(if urgent then foreground else background, { thread = coroutine.running(), id = id })
	coroutine.yield() -- pump() resumes this thread with the slot already counted
end

-- Frees a request slot and starts the next queued request.
local function releaseLoadSlot()
	activeLoads -= 1
	pump()
end

-- Moves a background-queued request for `id` to the visible queue (a slot needs it now).
local function promote(id: number)
	for index, item in background do
		if item.id == id then
			table.remove(background, index)
			table.insert(foreground, item)
			pump()
			return
		end
	end
end

--[[
	The template MeshPart of `id` (yields while it loads; nil when it failed / is cooling down).
	Concurrent callers share one request.
]]
local function fetchTemplate(id: number, urgent: boolean): MeshPart?
	local cached = templates[id]
	if cached ~= nil then
		return cached
	end
	if (failedUntil[id] or 0) > os.clock() then
		return nil
	end
	local waiters = waitingIds[id]
	if waiters ~= nil then
		if urgent then
			promote(id)
		end
		table.insert(waiters, coroutine.running())
		coroutine.yield()
		return templates[id]
	end
	waitingIds[id] = {}
	acquireLoadSlot(id, urgent)
	local result: MeshPart? = nil
	for attempt = 1, Config.MaxAttempts do
		local ok, value = pcall(function(): MeshPart
			return AssetService:CreateMeshPartAsync(Content.fromAssetId(id), TEMPLATE_OPTIONS)
		end)
		if ok then
			result = value
			break
		end
		if attempt < Config.MaxAttempts then
			task.wait(Config.RetryBaseDelay * 2 ^ (attempt - 1))
		end
	end
	releaseLoadSlot()
	if result ~= nil then
		templates[id] = result
	else
		failedUntil[id] = os.clock() + Config.RetryCooldown
	end
	local list = waitingIds[id]
	waitingIds[id] = nil
	if list ~= nil then
		for _, thread in list do
			task.spawn(thread)
		end
	end
	return result
end

-- True when every piece of a manifest entry has an uploaded MeshId.
local function uploaded(entry: any): boolean
	for _, piece in entry.pieces do
		if type(piece.id) ~= "number" or piece.id <= 0 then
			return false
		end
	end
	return true
end

-- Loads every template of a manifest entry in parallel (yields); true when all loaded.
local function loadTemplates(entry: any, urgent: boolean): boolean
	local ids: { number } = {}
	local seen: { [number]: boolean } = {}
	for _, piece in entry.pieces do
		if not seen[piece.id] then
			seen[piece.id] = true
			table.insert(ids, piece.id)
		end
	end
	local parent = coroutine.running()
	local done, allOk, parked = 0, true, false
	for _, id in ids do
		task.spawn(function()
			if fetchTemplate(id, urgent) == nil then
				allOk = false
			end
			done += 1
			-- Resume the parent only if it actually parked (cached ids finish synchronously).
			if done == #ids and parked then
				task.spawn(parent)
			end
		end)
	end
	if done < #ids then
		parked = true
		coroutine.yield()
	end
	return allOk
end

--[[
	Starts loading a `key` spec's templates (no-op when unknown, not uploaded, loading, ready or
	cooling down after a failure). Fires Ready(key) when done.
]]
local function requestKey(key: string, urgent: boolean)
	local state = keyState[key]
	if state == "ready" then
		return
	end
	local entry = MANIFEST[key]
	if entry == nil or not uploaded(entry) then
		return
	end
	if state == "loading" then
		if urgent then
			for _, piece in entry.pieces do
				promote(piece.id)
			end
		end
		return
	end
	if state == "failed" and os.clock() < (keyRetryAt[key] or 0) then
		return
	end
	keyState[key] = "loading"
	task.spawn(function()
		local ok = loadTemplates(entry, urgent)
		keyState[key] = if ok then "ready" else "failed"
		if ok then
			Ready:Fire(key)
		else
			keyRetryAt[key] = os.clock() + Config.RetryCooldown
			warn(`[ModelViewport] {key} meshes failed to load; showing its icon`)
		end
	end)
end

--------------------------------------------------------------------------------------------------
-- Specs + models
--------------------------------------------------------------------------------------------------

-- A spec as one kind / id / mesh key, or nil when it cannot show a model (unknown / absent).
local function resolve(spec: Spec?): Resolved?
	if spec == nil then
		return nil
	end
	-- PetModels builds pets / eggs / crates (their mesh key comes from their config).
	local kind: Kind
	local id: string
	local meshKey: string
	if type(spec.pet) == "string" then
		kind = "pet"
		id = spec.pet
		meshKey = PetModels.keyOf("pet", id)
	elseif type(spec.egg) == "string" then
		kind = "egg"
		id = spec.egg
		meshKey = PetModels.keyOf("egg", id)
	elseif type(spec.crate) == "string" then
		kind = "crate"
		id = spec.crate
		meshKey = PetModels.keyOf("crate", id)
	elseif type(spec.key) == "string" then
		kind = "key"
		id = spec.key
		meshKey = id
	else
		return nil
	end
	if meshKey == "" or MANIFEST[meshKey] == nil then
		return nil
	end
	local copies = ModelViewportLogic.copies(spec.copies)
	return { kind = kind, id = id, meshKey = meshKey, copies = copies, specId = `{kind}:{id}:{copies}` }
end

-- True when the spec's meshes are loaded (the model can be built right now).
local function isReady(resolved: Resolved): boolean
	if resolved.kind == "key" then
		return keyState[resolved.meshKey] == "ready"
	end
	return PetModels.isMeshReady(resolved.meshKey)
end

-- Starts loading the spec's meshes.
local function request(resolved: Resolved, urgent: boolean)
	if resolved.kind == "key" then
		requestKey(resolved.meshKey, urgent)
	else
		PetModels.request(resolved.meshKey)
	end
end

-- Makes a part inert (no physics, queries, touches or shadow).
local function inert(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
end

-- Applies a WorldMaterialConfig material ("Studs", "StudsSmall", "Neon", ...) to a part.
local function dress(part: BasePart, materialName: string)
	local spec = WorldMaterialConfig.Materials[materialName] or WorldMaterialConfig.Materials.StudsSmall
	part.Material = spec.material
	part.MaterialVariant = spec.variant or ""
end

--[[
	One model of a `key` spec from the loaded templates (same placement rules as MeshLibrary:
	MeshPlacement yaw + MeshYaw, glow budget, stud materials; a missing template falls back to a
	stud box so a model is never incomplete). Pivot = the manifest pivot at the origin.
]]
local function buildKeyModel(meshKey: string): Model
	local entry = MANIFEST[meshKey]
	local model = Instance.new("Model")
	model.Name = meshKey
	for pieceName, piece in entry.pieces do
		local material, color = MeshPlacement.resolveGlow(piece.material or "StudsSmall", piece.size, piece.color)
		local template = templates[piece.id]
		local part: BasePart
		if template ~= nil then
			part = template:Clone()
			part.CFrame = MeshPlacement.pieceCFrame(CFrame.identity, piece.offset, true)
			part:SetAttribute(MeshPlacement.YawAttribute, true)
		else
			local box = Instance.new("Part")
			box.TopSurface = Enum.SurfaceType.Smooth
			box.BottomSurface = Enum.SurfaceType.Smooth
			box.CFrame = MeshPlacement.pieceCFrame(CFrame.identity, piece.offset, false)
			part = box
		end
		part.Name = pieceName
		-- Templates keep the import size; every piece is resized to its manifest box.
		part.Size = piece.size
		part.Color = color
		part.Transparency = math.clamp(piece.transparency or 0, 0, 1)
		inert(part)
		dress(part, material)
		part.Parent = model
	end
	model.WorldPivot = CFrame.identity
	return model
end

-- One unit model of a spec (meshes are ready when this is called).
local function buildUnit(resolved: Resolved): Model
	if resolved.kind == "pet" then
		return PetModels.pet(resolved.id)
	elseif resolved.kind == "egg" then
		return PetModels.egg(resolved.id)
	elseif resolved.kind == "crate" then
		return PetModels.crate(resolved.id)
	end
	return buildKeyModel(resolved.meshKey)
end

-- The spec's model: the unit, or `copies` of it arranged by ModelViewportLogic.copyOffsets.
local function buildModel(resolved: Resolved): Model
	local unit = buildUnit(resolved)
	if resolved.copies <= 1 then
		return unit
	end
	local group = Instance.new("Model")
	group.Name = resolved.specId
	local _, unitSize = unit:GetBoundingBox()
	for index, offset in ModelViewportLogic.copyOffsets(resolved.copies, unitSize) do
		local copy = if index == 1 then unit else unit:Clone()
		copy:PivotTo(offset)
		copy.Parent = group
	end
	group.WorldPivot = CFrame.identity
	return group
end

-- A pooled model of `specId`, or nil.
local function takeModel(specId: string): Model?
	local list = modelPool[specId]
	local model = if list ~= nil then table.remove(list) else nil
	if model ~= nil then
		pooledModels -= 1
	end
	return model
end

-- Returns a model to the pool (destroyed when the pool is full).
local function poolModel(specId: string, model: Model)
	model.Parent = nil
	local list = modelPool[specId]
	if list == nil then
		list = {}
		modelPool[specId] = list
	end
	if #list < Config.ModelPoolPerSpec and pooledModels < Config.ModelPoolTotal then
		table.insert(list, model)
		pooledModels += 1
	else
		model:Destroy()
	end
end

--------------------------------------------------------------------------------------------------
-- Camera + spin
--------------------------------------------------------------------------------------------------

-- Points the camera (and the camera-relative key light) at the model for the entry's angle.
local function applyCamera(entry: Entry)
	local rig = entry.rig
	if rig == nil then
		return
	end
	local cf = ModelViewportLogic.orbit(entry.center, entry.distance, Config.Pitch, entry.angle)
	rig.camera.CFrame = cf
	rig.viewport.LightDirection = ModelViewportLogic.lightDirection(cf)
end

--[[
	The turntable bounds of a model (ModelViewportLogic.sweptBounds + profile over every visible
	part's box corners), measured once per built model: models never move inside a viewport, and pooled
	models keep their entry (weak keys: a destroyed model drops out).
]]
local function modelBounds(model: Model): Bounds
	local cached = boundsCache[model]
	if cached ~= nil then
		return cached
	end
	table.clear(cornerScratch)
	for _, item in model:GetDescendants() do
		if item:IsA("BasePart") and item.Transparency < 1 then
			local cf, half = item.CFrame, item.Size / 2
			for sx = -1, 1, 2 do
				for sy = -1, 1, 2 do
					for sz = -1, 1, 2 do
						table.insert(cornerScratch, cf * Vector3.new(sx * half.X, sy * half.Y, sz * half.Z))
					end
				end
			end
		end
	end
	if #cornerScratch == 0 then
		-- Nothing visible (should not happen): frame the bounding box's corners instead.
		local cf, size = model:GetBoundingBox()
		local half = size / 2
		for sx = -1, 1, 2 do
			for sy = -1, 1, 2 do
				for sz = -1, 1, 2 do
					table.insert(cornerScratch, cf * Vector3.new(sx * half.X, sy * half.Y, sz * half.Z))
				end
			end
		end
	end
	local center = ModelViewportLogic.sweptBounds(cornerScratch)
	local bounds: Bounds = { center = center, hull = ModelViewportLogic.profile(cornerScratch, center) }
	table.clear(cornerScratch)
	boundsCache[model] = bounds
	return bounds
end

-- Measures the model + frame and fits the camera exactly (ModelViewportLogic.fitProfile).
local function frameEntry(entry: Entry)
	local model, rig = entry.model, entry.rig
	if model == nil or rig == nil then
		return
	end
	local bounds = modelBounds(model)
	local absolute = rig.viewport.AbsoluteSize
	entry.center = bounds.center
	entry.aspect = if absolute.X > 0 and absolute.Y > 0 then absolute.X / absolute.Y else 1
	entry.distance =
		ModelViewportLogic.fitProfile(bounds.hull, Config.FieldOfView, entry.aspect, Config.Pitch, entry.zoom)
	applyCamera(entry)
end

-- Frees every spin slot whose holder stopped being stepped (off screen / closed / destroyed).
local function prune()
	lastPrune = os.clock()
	for holder in slotHolders do
		local fx = holder.fx
		if holder.dead or holder.model == nil or fx == nil or not fx.running() then
			slotHolders[holder] = nil
			holder.slot = false
			slotCount -= 1
		end
	end
end

-- Gives the entry a spin slot if the tier budget allows (see Config.MaxLive).
local function acquireSpinSlot(entry: Entry): boolean
	if slotCount >= maxLive and os.clock() - lastPrune >= Config.PruneSeconds then
		prune()
	end
	if slotCount >= maxLive then
		return false
	end
	slotHolders[entry] = true
	entry.slot = true
	slotCount += 1
	return true
end

-- Gives the entry's spin slot back.
local function releaseSpinSlot(entry: Entry)
	if entry.slot then
		entry.slot = false
		slotHolders[entry] = nil
		slotCount -= 1
	end
end

-- One OfferFx step of a spinning slot (only called while it is on screen).
local function stepEntry(entry: Entry, dt: number)
	if entry.model == nil or (not entry.slot and not acquireSpinSlot(entry)) then
		return
	end
	entry.angle = (entry.angle + dt * Config.SpinSpeed) % 360
	applyCamera(entry)
end

-- Registers / enables / parks the entry's OfferFx spin for its current state and the budget.
local function updateSpin(entry: Entry)
	local wanted = entry.spin and entry.model ~= nil and not entry.dead and maxLive > 0
	local fx = entry.fx
	if wanted then
		if fx == nil then
			entry.fx = OfferFx.register({
				root = entry.holder,
				rates = Config.Hz :: OfferFxConfig.PerTier,
				step = function(dt: number)
					stepEntry(entry, dt)
				end,
			})
		else
			fx.setEnabled(true)
		end
	else
		if fx ~= nil then
			fx.setEnabled(false)
		end
		releaseSpinSlot(entry)
	end
end

-- Re-reads the live budget (FxQuality tier + Reduce Motion) and re-gates every slot.
local function refreshBudget()
	maxLive = ModelViewportLogic.maxLive(FxQuality.tier(), OfferFx.reducedMotion())
	for holder in slotHolders do
		releaseSpinSlot(holder)
	end
	for entry in entries do
		updateSpin(entry)
	end
end

--------------------------------------------------------------------------------------------------
-- Rigs + slot content
--------------------------------------------------------------------------------------------------

-- A ViewportFrame + Camera + WorldModel for the entry (pooled), parented into its holder.
local function takeRig(entry: Entry): Rig
	local rig = table.remove(rigPool)
	if rig == nil then
		local viewport = Instance.new("ViewportFrame")
		viewport.Name = "Viewport"
		viewport.BackgroundTransparency = 1
		viewport.Active = false
		viewport.Selectable = false
		viewport.Ambient = Config.Ambient
		viewport.LightColor = Config.LightColor
		local camera = Instance.new("Camera")
		camera.FieldOfView = Config.FieldOfView
		camera.Parent = viewport
		viewport.CurrentCamera = camera
		local world = Instance.new("WorldModel")
		world.Parent = viewport
		rig = { viewport = viewport, camera = camera, world = world }
	end
	local built = rig :: Rig
	-- Centred and `overflow` x the slot (pooled rigs are re-sized for their new slot).
	built.viewport.AnchorPoint = Vector2.new(0.5, 0.5)
	built.viewport.Position = UDim2.fromScale(0.5, 0.5)
	built.viewport.Size = UDim2.fromScale(entry.overflow, entry.overflow)
	built.viewport.ZIndex = entry.zIndex
	built.viewport.Visible = false
	built.viewport.Parent = entry.holder
	-- Re-frame when the slot's aspect ratio changes (wide / tall card layouts).
	entry.sizeConnection = built.viewport:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		local absolute = built.viewport.AbsoluteSize
		if absolute.X <= 0 or absolute.Y <= 0 or entry.model == nil then
			return
		end
		local aspect = absolute.X / absolute.Y
		if math.abs(aspect - entry.aspect) / entry.aspect > Config.AspectEpsilon then
			frameEntry(entry)
		end
	end)
	return built
end

-- Returns the entry's rig to the pool (or destroys it when the pool is full).
local function releaseRig(entry: Entry)
	local rig = entry.rig
	if rig == nil then
		return
	end
	entry.rig = nil
	local connection = entry.sizeConnection
	entry.sizeConnection = nil
	if connection ~= nil then
		connection:Disconnect()
	end
	rig.viewport.Parent = nil
	if #rigPool < Config.RigPool then
		table.insert(rigPool, rig)
	else
		rig.viewport:Destroy()
	end
end

-- Stops waiting for a mesh key.
local function stopWaiting(entry: Entry)
	local resolved = entry.resolved
	if resolved == nil then
		return
	end
	local set = waitingByKey[resolved.meshKey]
	if set ~= nil then
		set[entry] = nil
		if next(set) == nil then
			waitingByKey[resolved.meshKey] = nil
		end
	end
end

-- Takes the model off screen (into the pool) and shows the icon again.
local function dropModel(entry: Entry)
	local model, resolved = entry.model, entry.resolved
	if model ~= nil and resolved ~= nil then
		entry.model = nil
		poolModel(resolved.specId, model)
	end
	local rig = entry.rig
	if rig ~= nil then
		rig.viewport.Visible = false
	end
	local icon = entry.iconFrame
	if icon ~= nil then
		icon.Visible = true
	end
	updateSpin(entry)
end

-- Builds (or reuses) the spec's model and swaps the icon for it.
local function showModel(entry: Entry)
	local resolved = entry.resolved
	if entry.dead or resolved == nil or entry.model ~= nil or not isReady(resolved) then
		return
	end
	local rig = entry.rig or takeRig(entry)
	entry.rig = rig
	local model = takeModel(resolved.specId) or buildModel(resolved)
	model.Parent = rig.world
	entry.model = model
	entry.angle = entry.restYaw
	frameEntry(entry)
	rig.viewport.Visible = true
	local icon = entry.iconFrame
	if icon ~= nil then
		icon.Visible = false
	end
	updateSpin(entry)
end

-- One handler for both Ready signals: show every slot that waited for `meshKey`.
local function onReady(meshKey: string)
	local set = waitingByKey[meshKey]
	if set == nil then
		return
	end
	waitingByKey[meshKey] = nil
	for entry in set do
		showModel(entry)
	end
end

-- Swaps the fallback icon (StudUI.icon) of a slot.
local function setIcon(entry: Entry, key: string?)
	if entry.iconKey == key then
		return
	end
	local old = entry.iconFrame
	if old ~= nil then
		old:Destroy()
		entry.iconFrame = nil
	end
	entry.iconKey = key
	if key ~= nil then
		local glyph = StudUI.icon(key, ICON_DESIGN_SIZE, entry.zIndex)
		glyph.Name = "FallbackIcon"
		glyph.AnchorPoint = Vector2.zero
		glyph.Position = UDim2.new()
		glyph.Size = UDim2.fromScale(1, 1)
		glyph.Visible = entry.model == nil
		glyph.Parent = entry.holder
		entry.iconFrame = glyph
	end
end

-- Points a slot at a new spec: drop the old model, then show the new one or wait for it.
local function setSpec(entry: Entry, spec: Spec?)
	local resolved = resolve(spec)
	local old = entry.resolved
	if old ~= nil and resolved ~= nil and old.specId == resolved.specId then
		return
	end
	if old == nil and resolved == nil then
		return
	end
	stopWaiting(entry)
	dropModel(entry)
	entry.resolved = resolved
	if resolved == nil then
		return
	end
	if isReady(resolved) then
		showModel(entry)
		return
	end
	local set = waitingByKey[resolved.meshKey]
	if set == nil then
		set = {}
		waitingByKey[resolved.meshKey] = set
	end
	set[entry] = true
	request(resolved, true)
end

-- Forgets a slot whose holder is going away (pools only on an explicit Destroy).
local function retire(entry: Entry)
	if entry.dead then
		return
	end
	entry.dead = true
	entries[entry] = nil
	stopWaiting(entry)
	releaseSpinSlot(entry)
	local fx = entry.fx
	entry.fx = nil
	if fx ~= nil then
		fx.destroy()
	end
end

--------------------------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------------------------

--[[
	Creates a model slot (see the module header and Options).
	@param options spec fields + icon + layout + spin / zoom / yaw
	@return Viewport handle (frame, set, setSpin, showsModel, Destroy)
	Example: ModelViewport.new({ pet = "starter_atom_pup", icon = "Pets", size = UDim2.fromOffset(96, 96) })
]]
function ModelViewport.new(options: Options): Viewport
	local holder = Instance.new("Frame")
	holder.Name = options.name or "ModelViewport"
	holder.BackgroundTransparency = 1
	holder.Size = options.size or UDim2.fromScale(1, 1)
	holder.Position = options.position or UDim2.new()
	holder.AnchorPoint = options.anchor or Vector2.zero
	holder.ZIndex = options.zIndex or 2
	holder.LayoutOrder = options.layoutOrder or 0
	holder.Active = false
	holder.Selectable = false
	holder:SetAttribute("Decorative", true)

	local entry: Entry = {
		holder = holder,
		zIndex = options.zIndex or 2,
		iconKey = nil,
		iconFrame = nil,
		resolved = nil,
		rig = nil,
		model = nil,
		center = Vector3.zero,
		distance = 10,
		aspect = 1,
		angle = options.yaw or Config.RestYaw,
		restYaw = options.yaw or Config.RestYaw,
		zoom = options.zoom or 1,
		overflow = if options.overflow ~= nil and options.overflow > 0 then options.overflow else Config.Overflow,
		spin = options.spin ~= false,
		fx = nil,
		slot = false,
		dead = false,
		sizeConnection = nil,
	}
	entries[entry] = true
	-- The owner destroyed the slot (or its card): stop tracking it; the instances go with it.
	holder.Destroying:Connect(function()
		retire(entry)
	end)

	setIcon(entry, options.icon)
	setSpec(entry, {
		key = options.key,
		pet = options.pet,
		egg = options.egg,
		crate = options.crate,
		copies = options.copies,
	})
	holder.Parent = options.parent

	return {
		frame = holder,
		set = function(spec: Spec?, icon: string?)
			if entry.dead then
				return
			end
			if icon ~= nil then
				setIcon(entry, icon)
			end
			setSpec(entry, spec)
		end,
		setSpin = function(on: boolean)
			if entry.dead or entry.spin == on then
				return
			end
			entry.spin = on
			if not on then
				entry.angle = entry.restYaw
				applyCamera(entry)
			end
			updateSpin(entry)
		end,
		showsModel = function(): boolean
			return entry.model ~= nil
		end,
		Destroy = function()
			if entry.dead then
				return
			end
			retire(entry)
			-- Explicit destroy: the model and the rig go back to the pools before the holder goes.
			local model, resolved = entry.model, entry.resolved
			if model ~= nil and resolved ~= nil then
				entry.model = nil
				poolModel(resolved.specId, model)
			end
			releaseRig(entry)
			holder:Destroy()
		end,
	}
end

--[[
	Warms the meshes of `specs` in the background (low priority, never ahead of a visible slot),
	so a screen that shows them later opens straight into 3D. Unknown specs are ignored.
	Example: ModelViewport.prefetch({ { key = "Shop_CashStack" }, { pet = "starter_atom_pup" } })
]]
function ModelViewport.prefetch(specs: { Spec })
	for _, spec in specs do
		local resolved = resolve(spec)
		if resolved ~= nil and not isReady(resolved) then
			request(resolved, false)
		end
	end
end

--[[
	True when `spec` can show a 3D model at all (known key / id present in MeshAssets).
	Example: ModelViewport.canShow({ key = "Shop_VipCrown" }) --> false until the prop is synced
]]
function ModelViewport.canShow(spec: Spec?): boolean
	return resolve(spec) ~= nil
end

--[[
	Counters for Studio probes / QA (tools/qa/shop_models.py): live slots, slots showing a model,
	slots spinning right now (on screen + holding a spin slot), spin slots held + the budget,
	loaded templates, requests in flight / queued, pooled rigs / models.
	Example: print(ModelViewport.stats().spinning)
]]
function ModelViewport.stats(): { [string]: number }
	local live, showing, running = 0, 0, 0
	for entry in entries do
		live += 1
		if entry.model ~= nil then
			showing += 1
		end
		local fx = entry.fx
		if entry.slot and fx ~= nil and fx.running() then
			running += 1
		end
	end
	local loaded = 0
	for _ in templates do
		loaded += 1
	end
	return {
		live = live,
		showing = showing,
		running = running,
		slots = slotCount,
		maxLive = maxLive,
		templates = loaded,
		inFlight = activeLoads,
		queued = #foreground + #background,
		pooledRigs = #rigPool,
		pooledModels = pooledModels,
	}
end

Ready:Connect(onReady)
PetModels.Ready:Connect(onReady)
-- Graphics tier / Reduce Motion changed: re-gate next frame (FxQuality re-reads its cache on the
-- same quality signal; deferring guarantees it already did).
OfferFx.Changed:Connect(function()
	task.defer(refreshBudget)
end)
refreshBudget()

return ModelViewport
