--!strict
--[[
	PetModels — builds the CLIENT models of pets, eggs and crates (followers, UI viewports, the
	hatch cinematic, the crate reveal) from the Blender manifest (Shared/Config/MeshAssets).

	Three looks, best available first:
		1. MESH       every piece of the MeshAssets key has an uploaded MeshId whose template loaded
		              (AssetService:CreateMeshPartAsync on this client, one template per id, cached).
		2. BOXES      the key is in MeshAssets but not uploaded / not loaded yet: one stud-textured box
		              per piece (the manifest's size / offset / colour) — same as MeshLibrary's fallback.
		3. CRITTER    the key is not in MeshAssets yet (art in progress): a cute primitive stand-in —
		              round body, big eyes with shine, glowing atom antenna, wings for flyers — in the
		              pet's colours; eggs / crates get a shell / box built the same way.
	When a key's meshes finish loading, `Ready(key)` fires once and owners (PetController,
	viewports, the hatch reveal) rebuild. Templates download in parallel (≤ 8 in flight, one fetch
	per MeshId, one shared load per key); `prefetch(keys)` warms them early, `waitReady(key)` yields
	on the same load.

	Every part is Anchored, CanCollide / CanQuery / CanTouch false, CastShadow false, Massless:
	no physics and no queries. A model's PrimaryPart is an invisible "Root" at the pivot (ground
	centre under a pet / egg / crate, front = -Z). `rig(model)` returns the parts + their offsets
	from the root so a renderer can move a whole pet with ONE workspace:BulkMoveTo per frame.
	Named pieces the animations use (B8f art contract): eggs "ShellTop*" / "ShellBottom*", crates
	"Lid*" (every piece whose name starts with the prefix moves together); pets keep their own
	Blender colours unless PetConfig recolours Body / Head / Glow.
	Pets animate procedurally (owner R44): `animRig(model)` = rig + PetAnim rig (groups Head* / Tail* /
	WingL* / WingR* / ClawL* / ClawR* / Orbit*, joints from the MeshAssets pivot string), and
	`applyLook` / `resetLook` write the pose's Size squash + Glow pulse. The critter stand-in names
	its wings WingL / WingR and its atom ring Orbit so it animates like the real meshes.

	Connects to: Shared/Config/{MeshAssets, PetConfig, PetAnimConfig, EggConfig, CrateConfig,
	WorldMaterialConfig}, Client/Pets/{PetAnim, PetController, PetViewport}, UI/Screens/{Pets, EggHatch, CrateShop, CrateOpen}.

	Example:
		local model = PetModels.pet("fission_fox")      -- Model, PrimaryPart = Root
		local parts, offsets = PetModels.rig(model)
		PetModels.Ready:Connect(function(key) print(key, "meshes ready") end)
]]

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CrateConfig = require(ReplicatedStorage.Shared.Config.CrateConfig)
local EggConfig = require(ReplicatedStorage.Shared.Config.EggConfig)
local MeshAssets = require(ReplicatedStorage.Shared.Config.MeshAssets)
local MeshPlacement = require(ReplicatedStorage.Shared.World.MeshPlacement)
local PetAnim = require(script.Parent.PetAnim)
local PetAnimConfig = require(ReplicatedStorage.Shared.Config.PetAnimConfig)
local PetConfig = require(ReplicatedStorage.Shared.Config.PetConfig)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local WorldMaterialConfig = require(ReplicatedStorage.Shared.Config.WorldMaterialConfig)

local PetModels = {}

-- Fires (meshKey) when every piece template of that key has loaded.
PetModels.Ready = Signal.new() :: Signal.Signal<string>

type LoadState = "loading" | "ready" | "failed"

--[[
	A self-stepped idle-animation handle for ONE pet model (see PetModels.animator): the caller owns
	the RenderStepped and calls step(dt). Poses are relative to the model's Root, so moving the whole
	model (PivotTo) or rescaling it (ScaleTo) between steps is fine.
]]
export type AnimatorOptions = {
	reduced: boolean?, -- Reduce Motion: gentle idle only
	simple: boolean?, -- Low tier: body bob + wings only
	seed: number?, -- idle rhythm seed (default: a fresh one per handle)
}

export type Animator = {
	step: (dt: number) -> (), -- advance + pose (no-op once destroyed / when the model has no Root)
	happy: (delay: number?) -> (), -- the followers' happy spin (ignored while one is playing)
	setReduced: (on: boolean) -> (), -- Reduce Motion: gentle idle only
	setDetail: (detail: number) -> (), -- PetAnim.Detail.Full (default) / Simple (body bob + wings)
	rest: () -> (), -- put every piece back at rest (sizes / glows too); step() resumes the loop
	Destroy: () -> (), -- rest() + drop every reference (the model itself is NOT destroyed)
}

--[[
	TEMPLATE LOADING (EH1 hatch QA: a first hatch showed missing shards because the 13 EggShards
	pieces loaded one after another). Same model as the server MeshLibrary prefetch:
		* one fetch per MeshId, ever: ids shared between keys / callers are requested once and the
		  template is cached (`templates`), cloned per model, never parented;
		* bounded concurrency: at most MAX_IN_FLIGHT AssetService:CreateMeshPartAsync calls at once,
		  the rest wait in a queue (most urgent first, then oldest);
		* one record per key = the single in-flight "promise": every caller of request / prefetch /
		  waitReady joins it; Ready(key) fires ONCE when the key's last piece lands (never for a key
		  that was already loaded when first asked for: its first build already uses the meshes);
		* a failed id makes its keys "failed" (stand-in look, one warning) and may be retried after
		  RETRY_AFTER seconds by a later request.
]]
local MAX_IN_FLIGHT = 8
local RETRY_AFTER = 30
-- Request priorities: a model being shown right now beats a warm-up prefetch.
local URGENT = 1
local PREFETCH = 2

type IdRecord = {
	state: "queued" | "loading" | "ready" | "failed",
	keys: { string }, -- keys waiting on this id
	priority: number,
	seq: number,
	retryAt: number,
}

type Waiter = { thread: thread, done: boolean }

type KeyRecord = {
	state: LoadState,
	missing: number, -- ids still loading
	failed: boolean,
	retryAt: number,
	waiters: { Waiter }, -- waitReady callers
}

-- MeshId → loaded template (never parented, cloned per model).
local templates: { [number]: MeshPart } = {}
-- MeshId → fetch record.
local idRecords: { [number]: IdRecord } = {}
-- Mesh key → load record.
local keyRecords: { [string]: KeyRecord } = {}
-- Queued (not yet started) MeshIds.
local queue: { number } = {}
local inFlight = 0
local sequence = 0

local MANIFEST = MeshAssets :: { [string]: any }

-- Dark ink used for eyes / outlines of the critter fallback.
local INK = Color3.fromRGB(28, 26, 40)
local WHITE = Color3.new(1, 1, 1)
local BLUSH = Color3.fromRGB(255, 150, 175)

--------------------------------------------------------------------------------------------------
-- Part helpers
--------------------------------------------------------------------------------------------------

-- Applies a WorldMaterialConfig material ("Studs", "StudsSmall", "Neon", ...) to a part.
local function dress(part: BasePart, materialName: string)
	local spec = WorldMaterialConfig.Materials[materialName] or WorldMaterialConfig.Materials.StudsSmall
	part.Material = spec.material
	part.MaterialVariant = spec.variant or ""
end

-- Makes a part inert (no physics, no queries, no touches, no shadow).
local function inert(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
end

-- A new inert Part.
local function newPart(name: string, size: Vector3, cf: CFrame, color: Color3, material: string, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	inert(part)
	dress(part, material)
	part.Parent = parent
	return part
end

-- A new inert ellipsoid (Part + SpecialMesh sphere, scaled by the part size).
local function ball(name: string, size: Vector3, cf: CFrame, color: Color3, material: string, parent: Instance): Part
	local part = newPart(name, size, cf, color, material, parent)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = part
	return part
end

-- A new model with an invisible Root at `pivot`.
local function newModel(name: string, pivot: CFrame): (Model, Part)
	local model = Instance.new("Model")
	model.Name = name
	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(0.2, 0.2, 0.2)
	root.Transparency = 1
	root.CFrame = pivot
	inert(root)
	root.Parent = model
	model.PrimaryPart = root
	return model, root
end

--------------------------------------------------------------------------------------------------
-- Manifest meshes
--------------------------------------------------------------------------------------------------

-- The manifest entry of `key`, or nil.
local function asset(key: string): any
	return MANIFEST[key]
end

-- True when every piece of the manifest entry has an uploaded id.
local function uploaded(entry: any): boolean
	for _, piece in entry.pieces do
		if type(piece.id) ~= "number" or piece.id <= 0 then
			return false
		end
	end
	return true
end

-- Settles a key whose last id resolved: state, waiters, Ready (only when `announce`).
local function settleKey(key: string, record: KeyRecord, announce: boolean)
	local ok = not record.failed
	record.state = if ok then "ready" else "failed"
	if not ok then
		record.retryAt = os.clock() + RETRY_AFTER
		warn(`[PetModels] {key} meshes failed to load; using the stand-in look`)
	end
	local waiters = record.waiters
	record.waiters = {}
	for _, waiter in waiters do
		if not waiter.done then
			waiter.done = true
			task.spawn(waiter.thread, ok)
		end
	end
	if ok and announce then
		PetModels.Ready:Fire(key)
	end
end

-- One MeshId finished (or failed): updates every key waiting on it.
local function resolveId(id: number, ok: boolean)
	local record = idRecords[id]
	record.state = if ok then "ready" else "failed"
	record.retryAt = if ok then 0 else os.clock() + RETRY_AFTER
	local waitingKeys = record.keys
	record.keys = {}
	for _, key in waitingKeys do
		local keyRecord = keyRecords[key]
		if keyRecord ~= nil and keyRecord.state == "loading" then
			keyRecord.missing -= 1
			if not ok then
				keyRecord.failed = true
			end
			if keyRecord.missing <= 0 then
				settleKey(key, keyRecord, true)
			end
		end
	end
end

local pump: () -> ()

-- Fetches one template (yields), then frees its slot and starts the next queued id.
local function fetch(id: number)
	local success, result = pcall(function(): MeshPart
		return AssetService:CreateMeshPartAsync(Content.fromAssetId(id), {
			CollisionFidelity = Enum.CollisionFidelity.Box,
			RenderFidelity = Enum.RenderFidelity.Automatic,
		})
	end)
	if success then
		templates[id] = result
	end
	inFlight -= 1
	resolveId(id, success)
	pump()
end

-- Starts queued ids while a slot is free: most urgent first, then oldest.
pump = function()
	while inFlight < MAX_IN_FLIGHT and #queue > 0 do
		local bestIndex = 1
		for index = 2, #queue do
			local candidate, best = idRecords[queue[index]], idRecords[queue[bestIndex]]
			if
				candidate.priority < best.priority
				or (candidate.priority == best.priority and candidate.seq < best.seq)
			then
				bestIndex = index
			end
		end
		local id = table.remove(queue, bestIndex) :: number
		idRecords[id].state = "loading"
		inFlight += 1
		task.spawn(fetch, id)
	end
end

--[[
	Joins or starts the load of `key` at `priority`.
	@return the number of MeshIds newly queued (0 when everything was cached / already queued)
]]
local function startKey(key: string, priority: number): number
	local record = keyRecords[key]
	if record ~= nil and (record.state ~= "failed" or os.clock() < record.retryAt) then
		-- Joined. An urgent caller promotes this key's still-queued ids.
		if record.state == "loading" and priority == URGENT then
			local entry = asset(key)
			for _, piece in (if entry ~= nil then entry.pieces else {}) :: { [string]: any } do
				local idRecord = idRecords[piece.id]
				if idRecord ~= nil and idRecord.state == "queued" and idRecord.priority > priority then
					idRecord.priority = priority
				end
			end
		end
		return 0
	end
	local entry = asset(key)
	if entry == nil or not uploaded(entry) then
		return 0
	end
	local fresh: KeyRecord = {
		state = "loading",
		missing = 0,
		failed = false,
		retryAt = 0,
		waiters = if record ~= nil then record.waiters else {},
	}
	keyRecords[key] = fresh
	local queued = 0
	local now = os.clock()
	local seen: { [number]: boolean } = {}
	for _, piece in entry.pieces do
		local id = piece.id :: number
		if seen[id] then
			continue
		end
		seen[id] = true
		local idRecord = idRecords[id]
		if idRecord ~= nil and idRecord.state == "ready" then
			continue
		end
		if idRecord ~= nil and idRecord.state == "failed" and now < idRecord.retryAt then
			fresh.failed = true
			continue
		end
		if idRecord == nil or idRecord.state == "failed" then
			sequence += 1
			idRecord = { state = "queued", keys = {}, priority = priority, seq = sequence, retryAt = 0 }
			idRecords[id] = idRecord :: IdRecord
			table.insert(queue, id)
			queued += 1
		elseif idRecord.state == "queued" and priority < idRecord.priority then
			idRecord.priority = priority
		end
		fresh.missing += 1
		table.insert((idRecord :: IdRecord).keys, key)
	end
	if fresh.missing == 0 then
		-- Everything cached (or failed recently): settle now. No Ready: nothing was built with
		-- the stand-in look for a key nobody asked for before.
		settleKey(key, fresh, false)
	else
		pump()
	end
	return queued
end

--[[
	Starts loading `key`'s mesh templates for a model shown NOW (jumps ahead of prefetches).
	No-op when unknown / not uploaded / already loading or loaded. Never yields.
	Example: PetModels.request("FusionPhoenix")
]]
function PetModels.request(key: string)
	if type(key) == "string" then
		startKey(key, URGENT)
	end
end

--[[
	Warms the template cache for several keys early (pets about to show, the hatch reveal's egg +
	EggShards) at prefetch priority, bounded to MAX_IN_FLIGHT downloads at once. Never yields.
	@return the number of MeshIds newly queued
	Example: PetModels.prefetch({ "EggShards", egg.model })
]]
function PetModels.prefetch(keys: { string }): number
	local queued = 0
	if type(keys) ~= "table" then
		return 0
	end
	for _, key in keys do
		if type(key) == "string" then
			queued += startKey(key, PREFETCH)
		end
	end
	return queued
end

--[[
	Yields until `key`'s meshes are loaded (true) or failed / unknown / timed out (false), joining
	the in-flight load (starting it at request priority when nobody has yet).
	@param timeout seconds (default: wait for the load to settle)
	Example: if PetModels.waitReady("EggShards", 3) then shards = PetModels.fromKey("EggShards") end
]]
function PetModels.waitReady(key: string, timeout: number?): boolean
	PetModels.request(key)
	local record = keyRecords[key]
	if record == nil then
		return false
	elseif record.state ~= "loading" then
		return record.state == "ready"
	end
	local waiter: Waiter = { thread = coroutine.running(), done = false }
	table.insert(record.waiters, waiter)
	if timeout ~= nil and timeout == timeout and timeout < math.huge then
		task.delay(math.max(timeout, 0), function()
			if not waiter.done then
				waiter.done = true
				task.spawn(waiter.thread, false)
			end
		end)
	end
	return coroutine.yield()
end

--[[ Loader counters (tests / debug overlay): downloads in flight, queued, cap, cached templates. ]]
function PetModels.loadStats(): { inFlight: number, queued: number, maxInFlight: number, cached: number }
	local cached = 0
	for _ in templates do
		cached += 1
	end
	return { inFlight = inFlight, queued = #queue, maxInFlight = MAX_IN_FLIGHT, cached = cached }
end

--[[ True when `key` can be built from loaded meshes right now. ]]
function PetModels.isMeshReady(key: string): boolean
	local record = keyRecords[key]
	return record ~= nil and record.state == "ready"
end

--[[
	Builds the manifest model of `key` (meshes when ready, else boxes). `colors` overrides pieces.
	Same placement rules as the server's MeshLibrary (Shared/World/MeshPlacement): uploaded mesh
	pieces are placed with the FBX import yaw undone (else they show spun 180°: eyes on the back)
	and tagged MeshYaw; primitive boxes are not rotated; oversized Neon pieces follow the glow
	budget.
]]
local function fromManifest(key: string, entry: any, name: string, colors: { [string]: Color3 }?): Model
	local model = newModel(name, CFrame.new())
	local meshes = PetModels.isMeshReady(key)
	for pieceName, piece in entry.pieces do
		local material, color = MeshPlacement.resolveGlow(
			piece.material or "StudsSmall",
			piece.size,
			(colors ~= nil and colors[pieceName]) or piece.color
		)
		local template = if meshes then templates[piece.id] else nil
		if template ~= nil then
			local clone = template:Clone()
			clone.Name = pieceName
			-- The template keeps the uploaded mesh's import size (Blender export units — ~100x too
			-- big); every piece is resized to its manifest box exactly like MeshLibrary does.
			clone.Size = piece.size
			clone.CFrame = MeshPlacement.pieceCFrame(CFrame.new(), piece.offset, true)
			clone:SetAttribute(MeshPlacement.YawAttribute, true)
			clone.Color = color
			clone.Transparency = math.clamp(piece.transparency or 0, 0, 1)
			inert(clone)
			dress(clone, material)
			clone.Parent = model
		else
			local part = newPart(
				pieceName,
				piece.size,
				MeshPlacement.pieceCFrame(CFrame.new(), piece.offset, false),
				color,
				material,
				model
			)
			part.Transparency = math.clamp(piece.transparency or 0, 0, 1)
		end
	end
	return model
end

--------------------------------------------------------------------------------------------------
-- Stand-in looks (art not in MeshAssets yet)
--------------------------------------------------------------------------------------------------

-- A cute critter: body, eyes with shine, blush, glowing atom antenna, wings for flyers.
local function critter(def: PetConfig.PetDef): Model
	local model = newModel(def.id, CFrame.new())
	local body = def.palette.body
	local glow = def.palette.glow
	local lift = if def.flying then 0.4 else 0
	local bodyCf = CFrame.new(0, 1.05 + lift, 0)
	ball("Body", Vector3.new(2.3, 2, 2.2), bodyCf, body, "StudsSmall", model)
	-- Little feet / belly highlight.
	ball(
		"Belly",
		Vector3.new(1.4, 1.1, 0.6),
		bodyCf * CFrame.new(0, -0.3, -0.85),
		body:Lerp(WHITE, 0.45),
		"StudsSmall",
		model
	)
	for side = -1, 1, 2 do
		-- Eyes: dark ovals with a white shine dot.
		local eye = bodyCf * CFrame.new(0.45 * side, 0.3, -0.98)
		ball(`Eye{side}`, Vector3.new(0.36, 0.46, 0.18), eye, INK, "Smooth", model)
		ball(`Shine{side}`, Vector3.new(0.13, 0.13, 0.08), eye * CFrame.new(0.06, 0.1, -0.08), WHITE, "Neon", model)
		ball(
			`Blush{side}`,
			Vector3.new(0.34, 0.18, 0.1),
			bodyCf * CFrame.new(0.78 * side, -0.05, -0.82),
			BLUSH,
			"Smooth",
			model
		)
		if def.flying then
			-- WingL / WingR: the PetAnim rig flaps them (B8f prefix contract).
			ball(
				if side < 0 then "WingL" else "WingR",
				Vector3.new(1.3, 0.25, 0.9),
				bodyCf * CFrame.new(1.25 * side, 0.15, 0.2) * CFrame.Angles(0, 0, math.rad(-20 * side)),
				glow,
				"Neon",
				model
			).Transparency =
				0.25
		else
			ball(
				`Foot{side}`,
				Vector3.new(0.6, 0.35, 0.7),
				CFrame.new(0.55 * side, 0.18, -0.15),
				body:Lerp(INK, 0.15),
				"StudsSmall",
				model
			)
			ball(
				`Ear{side}`,
				Vector3.new(0.5, 0.75, 0.3),
				bodyCf * CFrame.new(0.6 * side, 0.95, 0) * CFrame.Angles(0, 0, math.rad(-18 * side)),
				body,
				"StudsSmall",
				model
			)
		end
	end
	-- Glowing atom antenna (the radioactive critter signature).
	newPart(
		"Stalk",
		Vector3.new(0.12, 0.7, 0.12),
		bodyCf * CFrame.new(0, 1.25, 0),
		body:Lerp(INK, 0.3),
		"Smooth",
		model
	)
	ball("Glow", Vector3.new(0.5, 0.5, 0.5), bodyCf * CFrame.new(0, 1.7, 0), glow, "Neon", model)
	-- "Orbit": PetAnim spins it about +Y like the real pets' atom rings.
	local ring = ball(
		"Orbit",
		Vector3.new(0.95, 0.08, 0.95),
		bodyCf * CFrame.new(0, 1.7, 0) * CFrame.Angles(math.rad(25), 0, math.rad(20)),
		glow,
		"Neon",
		model
	)
	ring.Transparency = 0.3
	return model
end

-- An egg stand-in: bottom shell, top shell cap, glowing spots.
local function eggStandIn(egg: EggConfig.EggDef): Model
	local model = newModel(egg.id, CFrame.new())
	ball("ShellBottom", Vector3.new(3.2, 3.6, 3.2), CFrame.new(0, 1.8, 0), egg.shell, "StudsSmall", model)
	ball(
		"ShellTop",
		Vector3.new(2.7, 2.2, 2.7),
		CFrame.new(0, 3.05, 0),
		egg.shell:Lerp(WHITE, 0.08),
		"StudsSmall",
		model
	)
	local spots = {
		CFrame.new(0.9, 2.2, -1.2),
		CFrame.new(-1.1, 1.6, -0.9),
		CFrame.new(0.1, 3.3, -1.0),
		CFrame.new(-0.6, 2.7, 1.3),
		CFrame.new(1.3, 1.4, 0.7),
	}
	for index, cf in spots do
		ball(
			`Spot{index}`,
			Vector3.new(0.55, 0.55, 0.3),
			cf * CFrame.lookAt(Vector3.zero, cf.Position * Vector3.new(1, 0, 1)).Rotation,
			egg.spots,
			"Neon",
			model
		)
	end
	return model
end

-- A crate stand-in: stud body, lid, glowing band and a star badge.
local function crateStandIn(crate: CrateConfig.CrateDef): Model
	local model = newModel(crate.id, CFrame.new())
	newPart("Body", Vector3.new(3.4, 2.8, 3.4), CFrame.new(0, 1.4, 0), crate.color, "StudsSmall", model)
	newPart("Band", Vector3.new(3.5, 0.4, 3.5), CFrame.new(0, 1.4, 0), crate.accent, "Neon", model)
	newPart(
		"Lid",
		Vector3.new(3.7, 0.7, 3.7),
		CFrame.new(0, 3.15, 0),
		crate.color:Lerp(WHITE, 0.15),
		"StudsSmall",
		model
	)
	newPart(
		"Badge",
		Vector3.new(1, 1, 0.2),
		CFrame.new(0, 1.6, -1.75) * CFrame.Angles(0, 0, math.rad(45)),
		crate.accent,
		"Neon",
		model
	)
	return model
end

--------------------------------------------------------------------------------------------------
-- Public builders
--------------------------------------------------------------------------------------------------

--[[
	A pet model (Root at the ground pivot, scaled by rarity). Unknown ids → a grey critter.
	Starts the mesh load for its species (Ready fires when done).
]]
function PetModels.pet(petId: string): Model
	local def = PetConfig.get(petId)
	if def == nil then
		def = PetConfig.Pets.glow_slime
	end
	local pet = def :: PetConfig.PetDef
	PetModels.request(pet.model)
	local entry = asset(pet.model)
	local model = if entry ~= nil then fromManifest(pet.model, entry, pet.id, pet.colors) else critter(pet)
	local rarity = PetConfig.rarity(pet.rarity)
	local scale = if rarity ~= nil then rarity.scale else 1
	if scale ~= 1 then
		model:ScaleTo(scale)
	end
	model:SetAttribute("PetId", pet.id)
	return model
end

--[[
	A model of ANY MeshAssets key built with the same rules as pets / eggs / crates (template
	cache, meshes when loaded else stud boxes, inert parts, invisible Root at the pivot, import yaw
	undone). Starts the key's mesh load; `PetModels.Ready(key)` fires when the meshes are in (rebuild
	then for the real look). Used by the hatch reveal for its shell shards / crack ribbons.
	@param key    MeshAssets key, e.g. "EggShards"
	@param colors optional piece colour overrides (piece name → Color3)
	@return the Model, or nil when the key is not in MeshAssets
	Example: local shards = PetModels.fromKey("EggShards", { Shard1 = egg.shell })
]]
function PetModels.fromKey(key: string, colors: { [string]: Color3 }?): Model?
	local entry = if type(key) == "string" then asset(key) else nil
	if entry == nil then
		return nil
	end
	PetModels.request(key)
	return fromManifest(key, entry, key, colors)
end

--[[ An egg model (Root at the egg's bottom centre). ]]
function PetModels.egg(eggId: string): Model
	local egg = EggConfig.get(eggId) or EggConfig.Eggs.garage_egg
	PetModels.request(egg.model)
	local entry = asset(egg.model)
	if entry ~= nil then
		return fromManifest(egg.model, entry, egg.id, egg.colors)
	end
	return eggStandIn(egg)
end

--[[ A crate model (Root at the crate's bottom centre). ]]
function PetModels.crate(crateId: string): Model
	local crate = CrateConfig.get(crateId) or CrateConfig.Crates.supply_crate
	PetModels.request(crate.model)
	local entry = asset(crate.model)
	if entry ~= nil then
		return fromManifest(crate.model, entry, crate.id, nil)
	end
	return crateStandIn(crate)
end

--[[
	The mesh key a pet / egg / crate id builds from (owners compare it with Ready's key).
	Example: PetModels.keyOf("pet", "fission_fox") --> "Pet_Fox"
]]
function PetModels.keyOf(kind: "pet" | "egg" | "crate", id: string): string
	if kind == "pet" then
		local def = PetConfig.get(id)
		return if def ~= nil then def.model else ""
	elseif kind == "egg" then
		local egg = EggConfig.get(id)
		return if egg ~= nil then egg.model else ""
	end
	local crate = CrateConfig.get(id)
	return if crate ~= nil then crate.model else ""
end

--[[
	Every visible part of `model` and its CFrame relative to the Root (for BulkMoveTo / pivots).
	@return (parts, offsets) in matching order (Root excluded)
]]
function PetModels.rig(model: Model): ({ BasePart }, { CFrame })
	local root = model.PrimaryPart :: BasePart
	local parts: { BasePart } = {}
	local offsets: { CFrame } = {}
	local inverse = root.CFrame:Inverse()
	for _, item in model:GetDescendants() do
		if item:IsA("BasePart") and item ~= root then
			table.insert(parts, item)
			table.insert(offsets, inverse * item.CFrame)
		end
	end
	return parts, offsets
end

--[[
	The model's bounding box size (for camera framing in viewports).
	Example: local size = PetModels.extents(model)
]]
function PetModels.extents(model: Model): Vector3
	local _, size = model:GetBoundingBox()
	return size
end

--[[
	The parts, rest offsets and PetAnim rig of a pet model built by PetModels.pet (owner R44).
	Joints come from the species' MeshAssets pivot string, scaled like the model (rarity ScaleTo);
	species without an entry (critter stand-in) get joints derived from their pieces.
	@return (parts, offsets, rig) — parts / offsets exactly as PetModels.rig, rig aligned with them
	Example:
		local parts, offsets, rig = PetModels.animRig(PetModels.pet("fusion_phoenix"))
		print(rig.style) --> "Fly"
]]
function PetModels.animRig(model: Model): ({ BasePart }, { CFrame }, PetAnim.Rig)
	local parts, offsets = PetModels.rig(model)
	local petId = model:GetAttribute("PetId")
	local def = (if type(petId) == "string" then PetConfig.get(petId) else nil) or PetConfig.Pets.glow_slime
	local entry = asset(def.model)
	local scale = model:GetScale()
	local joints = PetAnim.parseJoints(if entry ~= nil then entry.pivot else nil)
	for name, joint in joints do
		joints[name] = joint * scale
	end
	local names: { string } = {}
	local sizes: { Vector3 } = {}
	local transparency: { number } = {}
	for index, part in parts do
		names[index] = part.Name
		sizes[index] = part.Size
		transparency[index] = part.Transparency
	end
	local rig = PetAnim.buildRig({
		key = def.model,
		names = names,
		rest = offsets,
		sizes = sizes,
		transparency = transparency,
		joints = joints,
		hover = def.hover,
		scale = scale,
	})
	return parts, offsets, rig
end

--[[
	Applies the non-CFrame part of a pose: Size squash of the body shells and the soft Glow pulse
	(owner R19: only ever dimmer than at rest). Writes only when a value changed by more than
	Motion.SizeEpsilon / one Glow.Step, so a resting pet costs no property writes.
	Call after PetAnim.step at Full detail (Simple / Off: call resetLook once instead).
]]
function PetModels.applyLook(rig: PetAnim.Rig, state: PetAnim.State, parts: { BasePart })
	local epsilon = PetAnimConfig.Motion.SizeEpsilon
	if math.abs(state.sx - state.lastSx) > epsilon or math.abs(state.sy - state.lastSy) > epsilon then
		state.lastSx, state.lastSy = state.sx, state.sy
		for n, index in rig.squash do
			parts[index].Size = PetAnim.squashSize(rig, state, n)
		end
	end
	if #rig.glow > 0 then
		-- The quantised dimming level (same maths as PetAnim.glowTransparency): write on change only.
		local step = PetAnimConfig.Motion.Glow.Step
		local dim = math.floor(state.glow * PetAnimConfig.Motion.Glow.Amount / step + 0.5) * step
		if dim ~= state.lastGlow then
			state.lastGlow = dim
			for n, index in rig.glow do
				parts[index].Transparency = PetAnim.glowTransparency(rig, state, n)
			end
		end
	end
end

--[[
	Puts squashed sizes and pulsed glows back to rest (a pet dropping to Simple / Off detail).
	No-op when nothing is off rest.
]]
function PetModels.resetLook(rig: PetAnim.Rig, state: PetAnim.State, parts: { BasePart })
	if state.lastSx ~= 1 or state.lastSy ~= 1 then
		state.lastSx, state.lastSy = 1, 1
		for n, index in rig.squash do
			parts[index].Size = rig.restSize[n]
		end
	end
	if state.lastGlow ~= 0 then
		state.lastGlow = 0
		for n, index in rig.glow do
			parts[index].Transparency = rig.glowRest[n]
		end
	end
end

-- Animator seeds (every handle idles on its own rhythm).
local animatorSeed = 0

--[[
	A self-stepped idle-animation handle for one pet model built by PetModels.pet (owner R44): the
	same PetAnim loop as the followers (viewport flavour: no big hops, gentler vertical moves).
	The caller owns the frame loop (e.g. the hatch reveal's one RenderStepped) and calls step(dt).
	Pieces are posed relative to the model's Root every step, so PivotTo of the whole model and
	ScaleTo (detected via Model:GetScale, the rig is rescaled to match) between steps both compose.
	@param model   a pet model (PetModels.pet), PrimaryPart = Root
	@param options reduced (Reduce Motion), simple (Low tier: body bob + wings), seed
	@return Animator, or nil when `model` is not a pet model (no Root / no PetId)
	Example:
		local anim = PetModels.animator(model, { reduced = reduced })
		connection = RunService.RenderStepped:Connect(function(dt) anim.step(dt) end)
		anim.happy()   -- one happy spin
		anim.Destroy() -- back at rest, references dropped
]]
function PetModels.animator(model: Model, options: AnimatorOptions?): Animator?
	if model.PrimaryPart == nil or type(model:GetAttribute("PetId")) ~= "string" then
		return nil
	end
	local opts: AnimatorOptions = options or {}
	local parts, offsets, rig = PetModels.animRig(model)
	animatorSeed += 1
	local state = PetAnim.newState(opts.seed or animatorSeed * 977, true)
	local pose = table.clone(offsets)
	local reduced = opts.reduced == true
	local detail = if opts.simple == true then PetAnim.Detail.Simple else PetAnim.Detail.Full
	local destroyed = false

	-- Matches the rig to the model's current scale (a ScaleTo since the last step).
	local function syncScale()
		local now = model:GetScale()
		if math.abs(now - rig.scale) > 1e-4 then
			PetAnim.rescaleRig(rig, now / rig.scale)
			-- ScaleTo rescaled the (possibly squashed) sizes: force the next Size write.
			state.lastSx = -1
		end
	end

	local function rest()
		local root = model.PrimaryPart
		if root == nil then
			return
		end
		syncScale()
		PetModels.resetLook(rig, state, parts)
		local base = root.CFrame
		for index, part in parts do
			part.CFrame = base * rig.rest[index]
		end
	end

	return {
		step = function(dt: number)
			local root = model.PrimaryPart
			if destroyed or root == nil then
				return
			end
			syncScale()
			PetAnim.step(rig, state, dt, 0, 0, false, detail, reduced)
			PetAnim.pose(rig, state, pose, detail)
			local base = root.CFrame
			for index, part in parts do
				part.CFrame = base * pose[index]
			end
			if detail == PetAnim.Detail.Full then
				PetModels.applyLook(rig, state, parts)
			end
		end,
		happy = function(delay: number?)
			if not destroyed then
				PetAnim.happy(state, delay)
			end
		end,
		setReduced = function(on: boolean)
			reduced = on
		end,
		setDetail = function(value: number)
			if value == detail then
				return
			end
			if detail == PetAnim.Detail.Full then
				PetModels.resetLook(rig, state, parts)
			end
			detail = if value == PetAnim.Detail.Simple then PetAnim.Detail.Simple else PetAnim.Detail.Full
		end,
		rest = function()
			if not destroyed then
				rest()
			end
		end,
		Destroy = function()
			if destroyed then
				return
			end
			rest()
			destroyed = true
			table.clear(parts)
			table.clear(pose)
		end,
	}
end

return PetModels
