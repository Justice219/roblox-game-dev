--!strict
--[[
	HubBuilder — builds the hub (the lobby) at the world origin: walkable ground, the spawn, the
	Time Machine portals to the other worlds, and the hub art from HubLayout when it exists.

	Purpose
		There is no baseplate: the world is built by code (docs/core.md). Players spawn here (owner rule
		R13: the hub is the lobby) and are sent to their plot after the plot reveal.

		With HubLayout (src/shared/Config/HubLayout.luau, B8e — WORLD space):
		  * `collision` boxes, the SpawnLocation and the Time Machine portal parts are built
		    SYNCHRONOUSLY (walkable + playable the moment Start returns, no mesh download needed);
		  * `models` (meshes) stream in ASYNCHRONOUSLY after a preload, named `entry.name` or
		    "<key>_<index>" (what HubLayout's anchors reference), Persistent streaming for
		    `persistent` landmarks, `tint` / `colors` / `castShadow` honoured. Two passes (owner R16 /
		    R55 perf): pass 1 = placements MeshLibrary.isNearHub and not HubLayout.isDeferred decor,
		    under MeshLibrary.holdWorldReady(HubHold) (released after it, even on error); pass 2 =
		    far scenery + decor (gardens, bunting, banners, coins, benches) at Background priority,
		    spawned `deferred` so it never holds WorldReady;
		  * `ground = false` skips the generated ground discs (HubLayout ships its own);
		  * `anchors.AmbientFx` ({ preset, cf }) become one invisible "AmbientFx" holder part in Art
		    with an Attachment + ParticleEmitter each (presets: Shared/Config/HubAmbientConfig, owner
		    R55 lobby: fountain jets + splashes, coin sparkles); built once, nothing per frame;
		  * `event`, `plotDecor`, `leaderboards` and every other anchor are NOT built here (the event
		    service / leaderboard service own them).
		Without HubLayout: primitive stud ground discs (world disc, ring road, plaza) and a spawn pad.

	No plot teleport pads (owner R134, 2026-11-01: "can we remove these little teleports")
		Neither the lobby nor any extra world's hub has plot teleport pads any more: no touch
		triggers, no "PLOT N + owner" pad labels, and NO generated neon-portal fallback (the
		placeholder hub has none either). Players walk to plots (paths, avenues, the numbered
		PlotGates) or use the Teleport menu (PlotService TeleportHub / TeleportPlot, TycoonService
		TeleportArea, WorldService travel). tests/hub-no-teleport-pads.luau keeps it that way.

	Instance tree
		Workspace.Hub (Model, streaming Default)
		  WorldGround, RingRoad, Plaza (Part)     placeholder ground discs (no HubLayout / ground ~= false)
		  Spawn (SpawnLocation)                   neutral, no force field (HubLayout.spawn inside Hub_SpawnPad)
		  Collision (Folder)                      HubLayout colliders (invisible)
		  WorldPortals (Folder)                   owner R57 lobby Time Machines (see Worlds below)
		    WorldPortal_<id> (Folder)             Trigger (touch volume), PromptPoint (+ TravelPrompt), Sign
		    TimeMachine_<id> (Model)              primitive placeholder machine (only without the anchor)
		  Art (Model)                             HubLayout meshes (async)
		    AmbientFx (Part)                      invisible holder: Attachment + ParticleEmitter per AmbientFx
		Workspace.Worlds.<id>.Hub (Model)         an extra world's hub (Dino Valley's Base Camp), same
		                                          children minus the SpawnLocation (+ the return portal)

	Worlds (owner R57 World 2, spec §4.4 / §5 / §16; plan §3.4)
		* Lobby Time Machines: one per WorldsConfig.extra() world, from HubLayout.anchors.WorldPortals[
		  def.portalAnchor] = { model, cf, trigger = { cf, size }, prompt, sign, arrive } (WORLD
		  space; the machine mesh is an ordinary HubLayout model placement, spawned with the art).
		  Without that anchor: a primitive stud machine at HubBuilder.LobbyPortalFallback.
		* buildWorld(worldId): Workspace.Worlds.<id>.Hub from the world's hub layout (WorldDef.hubLayout,
		  e.g. Worlds/Dino/ValleyLayout — WORLD-LOCAL, mapped with WorldLayout.toWorld): ground,
		  collision, the return portal (anchors.ReturnPortal, sign "BACK TO NUKE TOWN"), art (async,
		  Background priority — never holds WorldReady) and ambient particles. Without a usable
		  layout: a primitive stud Base Camp (ground discs, boundary ring, spawn pad, placeholder
		  machine). Never a
		  SpawnLocation: joins always start in the lobby (R13); WorldService pivots travellers.
		* getWorldPortal(worldId, "main" | "world") → { trigger, prompt, arrive } for WorldService.
		* spawnCFrame(worldId?) — the hub spawn of the lobby or an extra world.
		* A portal's FRONT is its CFrame's LookVector (-Z): the prompt and the arrival spot sit out
		  front, the sign's text faces that way.

	Connections
		Tycoon/PlotService builds it at Start (and every extra world's hub) and uses spawnCFrame()
		for TeleportHub. Tycoon/WorldService connects the Time Machine portals and uses
		spawnCFrame(worldId) / getWorldPortal for destinations.
		World/PlotBuilder reads `layout()` for the plot frame and the locked-slot placeholder.
		WorldLayout gives the radii + world transforms; MeshLibrary / WorldMaterials art + studs.

	Usage
		local hub = HubBuilder.build() --> { model, spawn, source }
		HubBuilder.buildWorld("dino")
		local portal = HubBuilder.getWorldPortal("dino", "main") --> { trigger, prompt, arrive }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local HubAmbientConfig = require(ReplicatedStorage.Shared.Config.HubAmbientConfig)
local MeshLibrary = require(script.Parent.MeshLibrary)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)
local WorldMaterials = require(script.Parent.WorldMaterials)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

--[[
	One built hub (the lobby or an extra world's hub): its Model, the ground-level spawn CFrame and
	whether the layout art or the primitive placeholder was used. Owner R134: no `portals` field —
	hubs have no plot teleport pads.
]]
export type HubBuild = {
	model: Model,
	spawn: CFrame,
	source: "art" | "placeholder",
}

--[[
	A Time Machine portal's live parts (owner R57 World 2, spec §4.4): the invisible touch volume
	inside the swirl, the ProximityPrompt, and where travellers arriving through it land (ground
	level). WorldService connects them; getWorldPortal(worldId, side) returns them.
]]
export type WorldPortal = {
	trigger: BasePart,
	prompt: ProximityPrompt,
	arrive: CFrame,
}

-- A PortalAnchor resolved to workspace space (HubLayout.anchors.WorldPortals / ValleyLayout
-- anchors.ReturnPortal, or the primitive placeholder).
type PortalSpec = {
	cf: CFrame,
	triggerCf: CFrame,
	triggerSize: Vector3,
	prompt: CFrame,
	sign: CFrame?,
	signSize: Vector2, -- the machine's blank sign panel (studs) the label must fit inside
	arrive: CFrame,
}

local HubBuilder = {}

-- Placeholder colours.
local WORLD_GROUND = Color3.fromRGB(90, 190, 80)
local RING_ROAD = Color3.fromRGB(95, 98, 110)
local PLAZA = Color3.fromRGB(225, 225, 232)
-- The visible placeholder spawn pad (the lobby's SpawnLocation without HubLayout art, an extra
-- world's primitive Base Camp spawn pad).
local SPAWN_PAD = Color3.fromRGB(90, 200, 255)
-- Wall segments of an extra world's placeholder boundary ring (at its geometry.boundaryRadius).
HubBuilder.BoundarySegments = 36

local MAIN = WorldsConfig.MAIN

local built: HubBuild? = nil
local cachedLayout: any = nil
local layoutResolved = false
-- Extra worlds (owner R57): built hubs, resolved hub layouts (false = none / not usable yet) and
-- the Time Machine portals per world ("main" = the lobby machine, "world" = its return portal).
local worldBuilds: { [string]: HubBuild } = {}
local worldLayouts: { [string]: any } = {}
type PortalPair = { main: WorldPortal?, world: WorldPortal? }
local worldPortals: { [string]: PortalPair } = {}

-- Time Machine portals: ProximityPrompt reach (studs).
HubBuilder.PortalPromptDistance = 12
-- The machine's blank cream "Sign" panel (studs) when the layout's `surfaces` does not say
-- (W9 hub_time_machine: 13.6 x 3.0); the label is sized to fit INSIDE it.
HubBuilder.PortalSignSize = Vector2.new(13.6, 3.0)
-- Placeholder Time Machine of the lobby while HubLayout has no anchors.WorldPortals entry yet:
-- in front of the hub spawn (inside the fresh-spawn view), facing it. W9's anchor replaces it.
HubBuilder.LobbyPortalFallback = CFrame.new(0, 0, -48) * CFrame.Angles(0, math.pi, 0)
-- Placeholder return portal of an extra world (relative to its hub spawn), facing the spawn.
HubBuilder.ReturnPortalFallback = CFrame.new(0, 0, -30) * CFrame.Angles(0, math.pi, 0)
-- Primitive Base Camp colours (until the world's hub layout art is synced).
local CAMP_GROUND = Color3.fromRGB(96, 168, 70)
local CAMP_ROAD = Color3.fromRGB(150, 110, 70)
local CAMP_PLAZA = Color3.fromRGB(222, 196, 140)
local MACHINE_BRASS = Color3.fromRGB(226, 178, 64)
local MACHINE_DARK = Color3.fromRGB(70, 60, 92)
local MACHINE_SWIRL = Color3.fromRGB(150, 96, 255)

-- Every mesh key HubLayout builds at runtime (world models, plot frame, locked slot).
local function layoutKeys(layout: any): { string }
	local keys: { string } = {}
	local function add(list: any)
		if type(list) ~= "table" then
			return
		end
		for _, entry in list do
			if type(entry) == "table" and type(entry.key) == "string" then
				table.insert(keys, entry.key)
			end
		end
	end
	add(layout.models)
	add(type(layout.base) == "table" and layout.base.models or nil)
	add(type(layout.plotFrame) == "table" and layout.plotFrame.models or nil)
	add(type(layout.lockedSlot) == "table" and layout.lockedSlot.models or nil)
	return keys
end

--[[
	The HubLayout table (cached), or nil: when the file is missing / fails to load / is not a table,
	AND while any mesh key it builds is not in MeshAssets yet (art in flight). All-or-nothing on
	purpose: HubLayout ships `ground = false`, so a half-synced layout would leave invisible ground;
	until every mesh exists the proven placeholder hub + plots are used (one warning).
	PlotBuilder reads `plotFrame` / `lockedSlot` / `plotColors` from it.
	@return any
]]
function HubBuilder.layout(): any
	if layoutResolved then
		return cachedLayout
	end
	layoutResolved = true
	local module = ReplicatedStorage.Shared.Config:FindFirstChild("HubLayout")
	if module == nil or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, layout = pcall(require, module)
	if not ok or type(layout) ~= "table" then
		warn(`[HubBuilder] HubLayout failed to load ({layout}); building the placeholder hub`)
		return nil
	end
	local missing = 0
	local keys = layoutKeys(layout)
	for _, key in keys do
		if not MeshLibrary.has(key) then
			missing += 1
		end
	end
	if missing > 0 then
		warn(
			`[HubBuilder] HubLayout uses {missing} of {#keys} mesh keys not in MeshAssets yet; using the placeholder hub + plots`
		)
		return nil
	end
	cachedLayout = layout
	return layout
end

-- A flat ground disc whose top sits at `top` (cylinder axis along X, turned upright), centred on
-- `centre` (default: the world origin).
local function disc(name: string, radius: number, top: number, color: Color3, parent: Instance, centre: Vector3?): Part
	local at = centre or Vector3.zero
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = Enum.PartType.Cylinder
	part.Anchored = true
	part.Size = Vector3.new(4, radius * 2, radius * 2)
	part.CFrame = CFrame.new(at.X, top - 2, at.Z) * CFrame.Angles(0, 0, math.pi / 2)
	part.Color = color
	part.CastShadow = false
	part.CanTouch = false
	WorldMaterials.apply(part, "StudsLarge")
	part.Parent = parent
	return part
end

-- An invisible anchored collision box.
local function collider(size: Vector3, cf: CFrame, parent: Instance)
	local part = Instance.new("Part")
	part.Name = "Collision"
	part.Anchored = true
	part.Size = size
	part.CFrame = cf
	part.Transparency = 1
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Parent = parent
end

--[[
	Lobby ambient particles (owner R55): one invisible holder part with an Attachment +
	ParticleEmitter per HubLayout.anchors.AmbientFx entry ({ preset, cf }, world CFrames), presets
	from Shared/Config/HubAmbientConfig. Built once with the art; nothing runs per frame. Entries with
	an unknown preset or a bad CFrame are skipped; at most HubAmbientConfig.MaxEmitters are made.
	@param layout any       the HubLayout table (or an extra world's hub layout)
	@param parent Instance  the hub's Art model
	@param toWorld ((CFrame) -> CFrame)?  maps the layout's CFrames to workspace (WORLD-LOCAL
	                        layouts such as ValleyLayout); nil = already world space
	@return number          emitters created
	Example: buildAmbient(HubLayout, art) --> 26
]]
local function buildAmbient(layout: any, parent: Instance, toWorld: ((CFrame) -> CFrame)?): number
	local list = if type(layout.anchors) == "table" then layout.anchors.AmbientFx else nil
	if type(list) ~= "table" or #list == 0 then
		return 0
	end
	local holder = Instance.new("Part")
	holder.Name = "AmbientFx"
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.CastShadow = false
	holder.Transparency = 1
	holder.Size = Vector3.new(1, 1, 1)
	holder.CFrame = CFrame.new()
	local made = 0
	for index, entry in list do
		if made >= HubAmbientConfig.MaxEmitters then
			break
		end
		local preset = if type(entry) == "table" and type(entry.preset) == "string"
			then HubAmbientConfig.Presets[entry.preset]
			else nil
		if preset == nil or typeof(entry.cf) ~= "CFrame" then
			continue
		end
		local attachment = Instance.new("Attachment")
		attachment.Name = `{entry.preset}{index}`
		attachment.Parent = holder
		attachment.WorldCFrame = if toWorld ~= nil then toWorld(entry.cf) else entry.cf
		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = entry.preset
		emitter.Texture = preset.texture
		emitter.Color = preset.color
		emitter.Size = preset.size
		emitter.Transparency = preset.transparency
		emitter.Lifetime = preset.lifetime
		emitter.Speed = preset.speed
		emitter.Rate = preset.rate
		emitter.SpreadAngle = preset.spread
		emitter.Acceleration = preset.acceleration
		emitter.LightEmission = preset.lightEmission
		emitter.LightInfluence = 0.6
		emitter.EmissionDirection = preset.emission
		emitter.Parent = attachment
		made += 1
	end
	holder.Parent = parent
	return made
end

-- Spawns HubLayout meshes (yields while templates load). Bad entries are skipped, warned once.
local function buildArt(layout: any, parent: Instance, releaseWorldReady: () -> ())
	local models = layout.models or (type(layout.base) == "table" and layout.base.models) or {}
	-- Pass 1 = first view: within MeshLibrary's near-hub radius of the spawn and not lobby decor
	-- (HubLayout.isDeferred). Pass 2 = the rest: far scenery + decor (gardens, bunting, banners,
	-- coins, benches), loaded behind the first view.
	local isDeferred: (string) -> boolean = if type(layout.isDeferred) == "function"
		then layout.isDeferred
		else function(_key: string): boolean
			return false
		end
	local near: { number } = {}
	local far: { number } = {}
	local nearKeys: { string } = {}
	local farKeys: { string } = {}
	local nearSeen: { [string]: boolean } = {}
	local farSeen: { [string]: boolean } = {}
	local skipped = 0
	for index, entry in models do
		if type(entry) ~= "table" or type(entry.key) ~= "string" or typeof(entry.cf) ~= "CFrame" then
			skipped += 1
			continue
		end
		if MeshLibrary.isNearHub(entry.cf) and not isDeferred(entry.key) then
			table.insert(near, index)
			if not nearSeen[entry.key] then
				nearSeen[entry.key] = true
				table.insert(nearKeys, entry.key)
			end
		else
			table.insert(far, index)
			if not farSeen[entry.key] then
				farSeen[entry.key] = true
				table.insert(farKeys, entry.key)
			end
		end
	end
	-- Spawns HubLayout.models[index] (named "<key>_<index>" so anchors find it). `deferred` spawns
	-- load at Background priority and never hold WorldReady (MeshLibrary player-first order).
	local function spawnEntry(index: number, deferred: boolean)
		local entry = models[index]
		if not MeshLibrary.has(entry.key) then
			skipped += 1
			return
		end
		MeshLibrary.spawn(entry.key, parent, entry.cf, {
			tint = if typeof(entry.tint) == "Color3" then entry.tint else nil,
			colors = if type(entry.colors) == "table" then entry.colors else nil,
			castShadow = if type(entry.castShadow) == "boolean" then entry.castShadow else nil,
			name = if type(entry.name) == "string" then entry.name else `{entry.key}_{index}`,
			streamingMode = if entry.persistent == true then Enum.ModelStreamingMode.Persistent else nil,
			deferred = if deferred then true else nil,
		})
	end
	-- Pass 1 under the WorldReady hold taken in build(); released even if a spawn errors, so the
	-- loading screen can never hang on the hub.
	local ok, problem = pcall(function()
		MeshLibrary.preload(nearKeys, MeshLibrary.Priority.Hub)
		for _, index in near do
			spawnEntry(index, false)
		end
	end)
	releaseWorldReady()
	if not ok then
		warn(`[HubBuilder] first-view pass failed: {problem}`)
	end
	-- Pass 2: far scenery + lobby decor behind the first view.
	MeshLibrary.preload(farKeys, MeshLibrary.Priority.Background)
	for _, index in far do
		spawnEntry(index, true)
	end
	if skipped > 0 then
		warn(`[HubBuilder] skipped {skipped} malformed / unknown HubLayout model entries`)
	end
	-- Lobby ambient particles (fountain jets / splashes, coin sparkles) once the decor exists.
	buildAmbient(layout, parent)
end

--------------------------------------------------------------------------------------------------
-- Time Machine portals (owner R57 World 2, spec §4.4)
--------------------------------------------------------------------------------------------------

-- The portal record of a world (created on first use).
local function portalsOf(worldId: string): PortalPair
	local entry = worldPortals[worldId]
	if entry ~= nil then
		return entry
	end
	local created: PortalPair = { main = nil, world = nil }
	worldPortals[worldId] = created
	return created
end

--[[
	The size of a portal machine's sign panel from the layout's `surfaces` table: the placement
	named `modelName` ("<key>_<index>" or entry.name) gives the mesh key, whose first "Sign" surface
	carries `size` (Vector2, studs). HubBuilder.PortalSignSize when anything is missing.
	@param layout any       HubLayout / an extra world's hub layout (nil = placeholder)
	@param modelName any    the anchor's `model` (Art child name of the machine)
	@return Vector2
	Example: signSizeOf(HubLayout, "Hub_TimeMachine_448") --> Vector2.new(13.6, 3.0)
]]
local function signSizeOf(layout: any, modelName: any): Vector2
	if type(layout) ~= "table" or type(modelName) ~= "string" or type(layout.models) ~= "table" then
		return HubBuilder.PortalSignSize
	end
	local key: string? = nil
	for index, entry in layout.models do
		if type(entry) == "table" and type(entry.key) == "string" then
			local name = if type(entry.name) == "string" then entry.name else `{entry.key}_{index}`
			if name == modelName then
				key = entry.key
				break
			end
		end
	end
	local surfaces = if key ~= nil and type(layout.surfaces) == "table" then layout.surfaces[key] else nil
	if type(surfaces) == "table" then
		for _, surface in surfaces do
			if type(surface) == "table" and surface.piece == "Sign" and typeof(surface.size) == "Vector2" then
				return surface.size
			end
		end
	end
	return HubBuilder.PortalSignSize
end

--[[
	A layout PortalAnchor ({ model, cf, trigger = { cf, size }, prompt, sign, arrive }) mapped to
	workspace space by `toWorld`, or nil when any required field is malformed (then the caller
	builds the placeholder machine instead). `layout` sizes the sign label (signSizeOf).
]]
local function portalSpec(raw: any, toWorld: (CFrame) -> CFrame, layout: any): PortalSpec?
	if
		type(raw) ~= "table"
		or typeof(raw.cf) ~= "CFrame"
		or typeof(raw.prompt) ~= "CFrame"
		or typeof(raw.arrive) ~= "CFrame"
		or type(raw.trigger) ~= "table"
		or typeof(raw.trigger.cf) ~= "CFrame"
		or typeof(raw.trigger.size) ~= "Vector3"
	then
		return nil
	end
	return {
		cf = toWorld(raw.cf),
		triggerCf = toWorld(raw.trigger.cf),
		triggerSize = raw.trigger.size,
		prompt = toWorld(raw.prompt),
		sign = if typeof(raw.sign) == "CFrame" then toWorld(raw.sign) else nil,
		signSize = signSizeOf(layout, raw.model),
		arrive = toWorld(raw.arrive),
	}
end

--[[
	The placeholder machine's anchor around a ground-level `base` CFrame whose FRONT (-Z, the
	LookVector) faces the travellers: swirl trigger inside the arch, prompt just in front, the
	sign on the top beam, the arrival spot 14 studs out front (outside the trigger, facing away).
]]
local function placeholderSpec(base: CFrame): PortalSpec
	return {
		cf = base,
		triggerCf = base * CFrame.new(0, 7.5, 0),
		triggerSize = Vector3.new(10, 13, 3),
		prompt = base * CFrame.new(0, 4, -3),
		sign = base * CFrame.new(0, 19.5, -2.15),
		signSize = HubBuilder.PortalSignSize,
		arrive = base * CFrame.new(0, 0, -14),
	}
end

--[[
	Builds the primitive stud Time Machine (plinth, two brass pillars, top beam, clock face, a neon
	swirl ring, a lever) at `base` — the fallback until the Blender machine (W9 hub_time_machine)
	and its anchors are synced. Everything stud-textured (hard rule 2); collisions only on the solid
	parts, the swirl is walk-through.
	@return Model
]]
local function placeholderMachine(base: CFrame, parent: Instance, name: string): Model
	local model = Instance.new("Model")
	model.Name = name
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	local function piece(
		pieceName: string,
		size: Vector3,
		cf: CFrame,
		color: Color3,
		material: string,
		shape: Enum.PartType?,
		collide: boolean
	): Part
		local part = Instance.new("Part")
		part.Name = pieceName
		part.Anchored = true
		part.Shape = shape or Enum.PartType.Block
		part.Size = size
		part.CFrame = cf
		part.Color = color
		part.CanCollide = collide
		part.CanTouch = false
		part.CanQuery = collide
		WorldMaterials.apply(part, material)
		part.Parent = model
		return part
	end
	piece("Plinth", Vector3.new(22, 1, 8), base * CFrame.new(0, 0.5, 0), MACHINE_DARK, "Studs", nil, true)
	piece("PillarL", Vector3.new(4, 17, 4), base * CFrame.new(-8, 9.5, 0), MACHINE_BRASS, "Studs", nil, true)
	piece("PillarR", Vector3.new(4, 17, 4), base * CFrame.new(8, 9.5, 0), MACHINE_BRASS, "Studs", nil, true)
	piece("Beam", Vector3.new(22, 4, 4), base * CFrame.new(0, 19.5, 0), MACHINE_BRASS, "Studs", nil, true)
	-- Cylinders run along X: turn them so the flat faces look along the machine's Z.
	local faceOn = CFrame.Angles(0, math.pi / 2, 0)
	piece(
		"ClockFace",
		Vector3.new(0.6, 7, 7),
		base * CFrame.new(0, 25, 0) * faceOn,
		Color3.new(1, 1, 1),
		"Studs",
		Enum.PartType.Cylinder,
		true
	)
	piece(
		"ClockRim",
		Vector3.new(0.5, 8, 8),
		base * CFrame.new(0, 25, 0.1) * faceOn,
		MACHINE_DARK,
		"Studs",
		Enum.PartType.Cylinder,
		false
	)
	piece(
		"Swirl",
		Vector3.new(0.4, 12, 12),
		base * CFrame.new(0, 8, 0) * faceOn,
		MACHINE_SWIRL,
		"Neon",
		Enum.PartType.Cylinder,
		false
	)
	piece(
		"Lever",
		Vector3.new(1, 5, 1),
		base * CFrame.new(11, 3, -2) * CFrame.Angles(math.rad(-25), 0, 0),
		Color3.fromRGB(230, 70, 70),
		"Studs",
		nil,
		false
	)
	model.Parent = parent
	return model
end

--[[
	The machine's sign text: a SurfaceGui on the FRONT face of an invisible board exactly the size
	of the mesh's blank cream panel (`size`, studs), centred on the panel face (`cf` = the anchor's
	sign), so the text never runs past the frame. Navy on cream with a soft white stroke and low
	light influence (the lobby's sign look), readable from afar.
]]
local function signBoard(cf: CFrame, size: Vector2, text: string, parent: Instance)
	local board = Instance.new("Part")
	board.Name = "Sign"
	board.Anchored = true
	board.CanCollide = false
	board.CanQuery = false
	board.CanTouch = false
	board.CastShadow = false
	board.Transparency = 1
	board.Size = Vector3.new(size.X, size.Y, 0.2)
	board.CFrame = cf
	local gui = Instance.new("SurfaceGui")
	gui.Name = "SignGui"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0.2
	gui.MaxDistance = 260
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	-- Dark navy on the cream panel, soft white outline.
	label.TextColor3 = Color3.fromRGB(40, 48, 84)
	label.TextStrokeColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.5
	label.Text = text
	-- Keeps the letters off the panel's frame.
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0.04, 0)
	padding.PaddingRight = UDim.new(0.04, 0)
	padding.PaddingTop = UDim.new(0.1, 0)
	padding.PaddingBottom = UDim.new(0.1, 0)
	padding.Parent = label
	label.Parent = gui
	gui.Parent = board
	board.Parent = parent
end

--[[
	Builds a portal's live parts from its spec into `parent`: the touch volume ("Trigger"), the
	prompt holder ("PromptPoint" + ProximityPrompt "Travel" / objectText; E, ButtonX or tap,
	HoldDuration 0, no line of sight) and the sign. Attributes WorldId + PortalSide on both.
	@return WorldPortal
]]
local function buildPortal(
	spec: PortalSpec,
	parent: Instance,
	worldId: string,
	side: "main" | "world",
	objectText: string,
	signText: string
): WorldPortal
	local folder = Instance.new("Folder")
	folder.Name = `WorldPortal_{worldId}`
	local volume = Instance.new("Part")
	volume.Name = "Trigger"
	volume.Anchored = true
	volume.CanCollide = false
	volume.CanQuery = false
	volume.CanTouch = true
	volume.CastShadow = false
	volume.Transparency = 1
	volume.Size = spec.triggerSize
	volume.CFrame = spec.triggerCf
	volume:SetAttribute("WorldId", worldId)
	volume:SetAttribute("PortalSide", side)
	volume.Parent = folder
	local point = Instance.new("Part")
	point.Name = "PromptPoint"
	point.Anchored = true
	point.CanCollide = false
	point.CanQuery = false
	point.CanTouch = false
	point.Transparency = 1
	point.Size = Vector3.new(1, 1, 1)
	point.CFrame = spec.prompt
	point.Parent = folder
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "TravelPrompt"
	prompt.ActionText = "Travel"
	prompt.ObjectText = objectText
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = HubBuilder.PortalPromptDistance
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.Style = Enum.ProximityPromptStyle.Default
	prompt:SetAttribute("WorldId", worldId)
	prompt:SetAttribute("PortalSide", side)
	prompt.Parent = point
	local sign = spec.sign
	if sign ~= nil then
		signBoard(sign, spec.signSize, signText, folder)
	end
	folder.Parent = parent
	return { trigger = volume, prompt = prompt, arrive = spec.arrive }
end

-- Identity transform (layouts already in world space).
local function worldSpace(cf: CFrame): CFrame
	return cf
end

--[[
	The lobby Time Machines (one per extra world, spec §4.4): HubLayout.anchors.WorldPortals[
	def.portalAnchor] when W9's anchor exists (the machine mesh itself is a HubLayout model
	placement, spawned with the art), else the primitive placeholder machine in front of the spawn.
	Built synchronously with the rest of the hub's triggers.
]]
local function buildLobbyPortals(layout: any, hub: Model, spawnCf: CFrame)
	local anchors = if layout ~= nil and type(layout.anchors) == "table" then layout.anchors.WorldPortals else nil
	local folder = Instance.new("Folder")
	folder.Name = "WorldPortals"
	folder.Parent = hub
	for index, def in WorldsConfig.extra() do
		local key = def.portalAnchor or def.id
		local spec = portalSpec(if type(anchors) == "table" then anchors[key] else nil, worldSpace, layout)
		if spec == nil then
			-- Several extra worlds without anchors: fan the placeholders out sideways.
			local base = spawnCf * CFrame.new((index - 1) * 26, 0, 0) * HubBuilder.LobbyPortalFallback
			spec = placeholderSpec(base)
			placeholderMachine(base, folder, `TimeMachine_{def.id}`)
		end
		portalsOf(def.id).main =
			buildPortal(spec :: PortalSpec, folder, def.id, "main", def.name, string.upper(def.name))
	end
end

--[[
	Builds the hub once (idempotent; later calls return the first build). Never yields: collision,
	spawn and the Time Machine portals are built synchronously, meshes stream in on a separate
	thread. No plot teleport pads (owner R134).
	@return HubBuild
]]
function HubBuilder.build(): HubBuild
	if built ~= nil then
		return built
	end
	WorldMaterials.ensure()
	local existing = Workspace:FindFirstChild("Hub")
	if existing ~= nil then
		existing:Destroy()
	end
	local model = Instance.new("Model")
	model.Name = "Hub"
	model.ModelStreamingMode = Enum.ModelStreamingMode.Default

	local layout = HubBuilder.layout()
	if layout == nil or layout.ground ~= false then
		disc("WorldGround", WorldLayout.WorldRadius, -0.1, WORLD_GROUND, model)
		disc("RingRoad", WorldLayout.PlotRadius, -0.03, RING_ROAD, model)
		disc("Plaza", WorldLayout.HubRadius, 0, PLAZA, model)
	end

	-- Spawn: HubLayout.spawn (or anchors.SpawnPoint), else the default.
	local spawnCf = WorldLayout.DefaultHubSpawn
	if layout ~= nil then
		if typeof(layout.spawn) == "CFrame" then
			spawnCf = layout.spawn
		elseif type(layout.anchors) == "table" and typeof(layout.anchors.SpawnPoint) == "CFrame" then
			spawnCf = layout.anchors.SpawnPoint
		end
	end
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "Spawn"
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Size = Vector3.new(12, 1, 12)
	spawn.CFrame = spawnCf * CFrame.new(0, 0.5, 0)
	spawn.Color = SPAWN_PAD
	spawn.CanTouch = true
	-- HubLayout's Hub_SpawnPad mesh encloses the SpawnLocation: keep it invisible under the art.
	spawn.Transparency = if layout ~= nil then 1 else 0
	WorldMaterials.apply(spawn, "Studs")
	spawn.Parent = model

	-- Collision first (synchronous: the hub is walkable before any mesh arrives).
	if layout ~= nil then
		local collisionFolder = Instance.new("Folder")
		collisionFolder.Name = "Collision"
		local boxes = layout.collision or (type(layout.base) == "table" and layout.base.collision) or {}
		for _, box in boxes do
			if type(box) == "table" and typeof(box.size) == "Vector3" and typeof(box.cf) == "CFrame" then
				collider(box.size, box.cf, collisionFolder)
			end
		end
		collisionFolder.Parent = model
	end

	-- Time Machine portals to the extra worlds (owner R57; synchronous, like the collision).
	buildLobbyPortals(layout, model, spawnCf)

	if layout ~= nil then
		local art = Instance.new("Model")
		art.Name = "Art"
		art.ModelStreamingMode = Enum.ModelStreamingMode.Default
		art.Parent = model
		-- Hold WorldReady for the hub's first-view pass (buildArt releases it) BEFORE any preload,
		-- so far scenery + decor can load after the loading screen (MeshLibrary player-first order).
		local releaseWorldReady = MeshLibrary.holdWorldReady(MeshLibrary.HubHold)
		task.spawn(buildArt, layout, art, releaseWorldReady)
	end

	model.Parent = Workspace
	local result: HubBuild = {
		model = model,
		spawn = spawnCf,
		source = if layout ~= nil then "art" else "placeholder",
	}
	built = result
	return result
end

--[[
	The hub spawn at ground level: the lobby (TeleportHub target) for nil / "main", else that
	extra world's hub spawn (Base Camp). Builds the hub if needed.
	@param worldId string? — nil / "main" = Nuke Town
	@return CFrame
]]
function HubBuilder.spawnCFrame(worldId: string?): CFrame
	if worldId == nil or worldId == MAIN then
		return HubBuilder.build().spawn
	end
	return HubBuilder.worldHub(worldId).spawn
end

--------------------------------------------------------------------------------------------------
-- Extra worlds (owner R57 World 2: Dino Valley's Base Camp; spec §3, §4.4, §5, §16)
--------------------------------------------------------------------------------------------------

-- Workspace.Worlds.<id> (Folders, found or created; PlotBuilder puts the world's Plots there too).
local function worldRegion(worldId: string): Instance
	local root = Workspace:FindFirstChild("Worlds")
	if root == nil then
		local created = Instance.new("Folder")
		created.Name = "Worlds"
		created.Parent = Workspace
		root = created
	end
	local region = (root :: Instance):FindFirstChild(worldId)
	if region == nil then
		local created = Instance.new("Folder")
		created.Name = worldId
		created.Parent = root
		region = created
	end
	return region :: Instance
end

--[[
	An extra world's hub layout (WorldDef.hubLayout under ReplicatedStorage.Shared.Config, e.g.
	Worlds/Dino/ValleyLayout — WORLD-LOCAL CFrames, HubLayout-shaped), cached; or nil when the
	module is missing / fails / is not a table, and while any mesh key it builds is not in
	MeshAssets yet (all-or-nothing like layout(): a half-synced layout could leave invisible
	ground, so the primitive Base Camp is used until every mesh exists; warned once).
	@param worldId string
	@return any
]]
function HubBuilder.worldLayout(worldId: string): any
	local cached = worldLayouts[worldId]
	if cached ~= nil then
		return if cached == false then nil else cached
	end
	worldLayouts[worldId] = false
	local def = WorldsConfig.get(worldId)
	if def == nil or def.id == MAIN then
		return nil
	end
	local node: Instance? = ReplicatedStorage.Shared.Config
	for _, segment in def.hubLayout do
		node = if node ~= nil then node:FindFirstChild(segment) else nil
	end
	if node == nil or not node:IsA("ModuleScript") then
		return nil
	end
	local ok, layout = pcall(require, node)
	if not ok or type(layout) ~= "table" then
		warn(`[HubBuilder] {def.id} hub layout failed to load ({layout}); building the placeholder hub`)
		return nil
	end
	local missing = 0
	local keys = layoutKeys(layout)
	for _, key in keys do
		if not MeshLibrary.has(key) then
			missing += 1
		end
	end
	if missing > 0 then
		warn(
			`[HubBuilder] {def.id} hub layout uses {missing} of {#keys} mesh keys not in MeshAssets yet; using the placeholder hub`
		)
		return nil
	end
	worldLayouts[def.id] = layout
	return layout
end

--[[
	Spawns an extra world's hub meshes (yields while templates load). Every placement is mapped by
	`toWorld`, nearest to the world spawn first, all `deferred` (Background priority): nobody
	spawns in an extra world, so it never holds the lobby's WorldReady (the client preloads the
	destination's keys while the warp overlay plays). Then the ambient particles.
]]
local function buildWorldArt(
	worldId: string,
	layout: any,
	parent: Instance,
	toWorld: (CFrame) -> CFrame,
	localSpawn: CFrame
)
	local models = if type(layout.models) == "table" then layout.models else {}
	local order: { number } = {}
	local distance: { [number]: number } = {}
	local keys: { string } = {}
	local seen: { [string]: boolean } = {}
	local skipped = 0
	for index, entry in models do
		if type(entry) ~= "table" or type(entry.key) ~= "string" or typeof(entry.cf) ~= "CFrame" then
			skipped += 1
			continue
		end
		table.insert(order, index)
		distance[index] = (entry.cf.Position - localSpawn.Position).Magnitude
		if not seen[entry.key] then
			seen[entry.key] = true
			table.insert(keys, entry.key)
		end
	end
	table.sort(order, function(a: number, b: number): boolean
		return distance[a] < distance[b]
	end)
	MeshLibrary.preload(keys, MeshLibrary.Priority.Background)
	for _, index in order do
		local entry = models[index]
		if not MeshLibrary.has(entry.key) then
			skipped += 1
			continue
		end
		MeshLibrary.spawn(entry.key, parent, toWorld(entry.cf), {
			tint = if typeof(entry.tint) == "Color3" then entry.tint else nil,
			colors = if type(entry.colors) == "table" then entry.colors else nil,
			castShadow = if type(entry.castShadow) == "boolean" then entry.castShadow else nil,
			name = if type(entry.name) == "string" then entry.name else `{entry.key}_{index}`,
			streamingMode = if entry.persistent == true then Enum.ModelStreamingMode.Persistent else nil,
			deferred = true,
		})
	end
	if skipped > 0 then
		warn(`[HubBuilder] {worldId}: skipped {skipped} malformed / unknown hub layout model entries`)
	end
	buildAmbient(layout, parent, toWorld)
end

--[[
	Builds an extra world's hub once (idempotent) and returns the build record: Workspace.Worlds.
	<id>.Hub at the world's origin (WorldLayout.toWorld). With the world's hub layout: its ground
	(unless `ground = false`), collision, the return Time Machine (anchors.ReturnPortal) and the
	art (async). Without it (art in flight): a primitive stud Base Camp — ground discs, an
	invisible boundary ring at the world's boundaryRadius, a spawn pad and the placeholder Time
	Machine. No plot teleport pads (owner R134). Never yields.
	NO SpawnLocation is created: Roblox would randomly spawn joining players there (owner R13:
	every join starts in the Nuke Town lobby); WorldService pivots travellers to `spawn`.
	@param worldId string — an extra world ("dino"); errors for "main" / unknown ids
	@return HubBuild
]]
function HubBuilder.worldHub(worldId: string): HubBuild
	local existing = worldBuilds[worldId]
	if existing ~= nil then
		return existing
	end
	local def = WorldsConfig.get(worldId)
	assert(def ~= nil and def.id ~= MAIN, `HubBuilder.buildWorld: {tostring(worldId)} is not an extra world`)
	local worldDef = def :: WorldsConfig.WorldDef
	WorldMaterials.ensure()
	local region = worldRegion(worldDef.id)
	local stale = region:FindFirstChild("Hub")
	if stale ~= nil then
		stale:Destroy()
	end
	local model = Instance.new("Model")
	model.Name = "Hub"
	model.ModelStreamingMode = Enum.ModelStreamingMode.Default
	model:SetAttribute("WorldId", worldDef.id)

	local layout = HubBuilder.worldLayout(worldDef.id)
	local function toWorld(cf: CFrame): CFrame
		return WorldLayout.toWorld(worldDef.id, cf)
	end
	local origin = worldDef.geometry.origin

	if layout == nil or layout.ground ~= false then
		disc("WorldGround", worldDef.geometry.boundaryRadius, -0.1, CAMP_GROUND, model, origin.Position)
		disc("RingRoad", WorldLayout.PlotRadius, -0.03, CAMP_ROAD, model, origin.Position)
		disc("Plaza", WorldLayout.HubRadius, 0, CAMP_PLAZA, model, origin.Position)
	end

	-- Spawn (world-local in the layout): layout.spawn, anchors.SpawnPoint, else the default.
	local localSpawn = WorldLayout.DefaultHubSpawn
	if layout ~= nil then
		if typeof(layout.spawn) == "CFrame" then
			localSpawn = layout.spawn
		elseif type(layout.anchors) == "table" and typeof(layout.anchors.SpawnPoint) == "CFrame" then
			localSpawn = layout.anchors.SpawnPoint
		end
	end
	local spawnCf = toWorld(localSpawn)
	if layout == nil then
		local pad = Instance.new("Part")
		pad.Name = "SpawnPad"
		pad.Anchored = true
		pad.Size = Vector3.new(12, 1, 12)
		pad.CFrame = spawnCf * CFrame.new(0, 0.5, 0)
		pad.Color = SPAWN_PAD
		pad.CanTouch = false
		WorldMaterials.apply(pad, "Studs")
		pad.Parent = model
	end

	-- Collision (synchronous): the layout's boxes, or the placeholder boundary ring.
	local collisionFolder = Instance.new("Folder")
	collisionFolder.Name = "Collision"
	if layout ~= nil then
		local boxes = if type(layout.collision) == "table" then layout.collision else {}
		for _, box in boxes do
			if type(box) == "table" and typeof(box.size) == "Vector3" and typeof(box.cf) == "CFrame" then
				collider(box.size, toWorld(box.cf), collisionFolder)
			end
		end
	else
		local radius = worldDef.geometry.boundaryRadius
		local segments = HubBuilder.BoundarySegments
		local width = 2 * radius * math.tan(math.pi / segments) + 2
		for segment = 0, segments - 1 do
			local cf = origin * CFrame.Angles(0, segment * 2 * math.pi / segments, 0) * CFrame.new(0, 30, -radius)
			collider(Vector3.new(width, 60, 4), cf, collisionFolder)
		end
	end
	collisionFolder.Parent = model

	-- The return Time Machine ("BACK TO NUKE TOWN").
	local portalFolder = Instance.new("Folder")
	portalFolder.Name = "WorldPortals"
	portalFolder.Parent = model
	local anchors = if layout ~= nil and type(layout.anchors) == "table" then layout.anchors else nil
	local spec = portalSpec(if anchors ~= nil then anchors.ReturnPortal else nil, toWorld, layout)
	if spec == nil then
		local base = spawnCf * HubBuilder.ReturnPortalFallback
		spec = placeholderSpec(base)
		placeholderMachine(base, portalFolder, "TimeMachine_return")
	end
	local home = WorldsConfig.get(MAIN)
	local homeName = if home ~= nil then home.name else "Nuke Town"
	portalsOf(worldDef.id).world = buildPortal(
		spec :: PortalSpec,
		portalFolder,
		worldDef.id,
		"world",
		homeName,
		`BACK TO {string.upper(homeName)}`
	)

	if layout ~= nil then
		local art = Instance.new("Model")
		art.Name = "Art"
		art.ModelStreamingMode = Enum.ModelStreamingMode.Default
		art.Parent = model
		task.spawn(buildWorldArt, worldDef.id, layout, art, toWorld, localSpawn)
	end

	model.Parent = region
	local result: HubBuild = {
		model = model,
		spawn = spawnCf,
		source = if layout ~= nil then "art" else "placeholder",
	}
	worldBuilds[worldDef.id] = result
	return result
end

--[[
	Builds an extra world's hub (Workspace.Worlds.<id>.Hub; idempotent, never yields) — plan §3.4.
	@param worldId string — e.g. "dino"
	@return Model
	Example: HubBuilder.buildWorld("dino")
]]
function HubBuilder.buildWorld(worldId: string): Model
	return HubBuilder.worldHub(worldId).model
end

--[[
	A Time Machine portal of an extra world: side "main" = the lobby machine that leads THERE,
	"world" = its return portal in that world's hub. Builds the hub it lives in if needed.
	@return WorldPortal? — nil for "main" / unknown worlds
	Example: HubBuilder.getWorldPortal("dino", "main").prompt.Triggered:Connect(...)
]]
function HubBuilder.getWorldPortal(worldId: string, side: "main" | "world"): WorldPortal?
	local def = WorldsConfig.get(worldId)
	if def == nil or def.id == MAIN then
		return nil
	end
	if side == "main" then
		HubBuilder.build()
	else
		HubBuilder.worldHub(def.id)
	end
	local entry = worldPortals[def.id]
	if entry == nil then
		return nil
	end
	return if side == "main" then entry.main else entry.world
end

return HubBuilder
