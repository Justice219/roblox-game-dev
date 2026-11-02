--!strict
--[[
	PlotBuilder — builds and clears the 8 plots: ground, road, entrance arch + owner sign, each
	unlocked area's base, every bought pad's build, the producers' billboard anchors / click boxes
	and the BuyPads of the pads available next.

	Purpose
		The server-authoritative world of a tycoon (spec §4, §5). Everything a player owns is real,
		collidable server geometry; the client only animates it (LEGO build-in) from attributes this
		module sets. Unbought content is never instanced (performance rule).

	Instance tree (B6 reads it; names and attributes are the contract, docs/tycoon-server.md):
		Workspace.Plots (Folder)
		  PlotN (Model)              PlotIndex, OwnerUserId (0 = free), OwnerName, StandName,
		                             PlotReady (true once the owner's bought builds are placed),
		                             PlotName (owner R88: the filtered custom plot name, "" = the
		                             default "<DisplayName>'s Nukes"; reset on every owner change)
		    YouAnchor (Part)         invisible; the owner's client hangs its YOU marker here
		    Frame (Model)            HubLayout.plotFrame: colliders + tinted meshes (ground, road,
		                             border, EntranceArch with the owner sign on its OwnerSign piece)
		      — or, without HubLayout: Ground, Road (Part) + Entrance (Model) primitive arch + sign
		                             The owner-sign part (arch OwnerSign piece / primitive Sign) carries
		                             the CollectionService tag PlotNameConfig.SignTag ("SNPlotSign"):
		                             the owner's client hangs its naming click box + prompt on it (R88)
		    Locked (Folder)          LockedNN (Model, LockedArea): HubLayout.lockedSlot on every locked
		                             slot, sign "COMING SOON" / "x / y purchases" (syncLocked)
		    AreaNN (Model)           AreaIndex; WorldPivot = the slot frame
		      Base (Model)           area base: floor + entry arch      [BuildIn, BuyerUserId, AreaUnlock]
		      Builds (Folder)
		        <BuildKey> (Model)   BuildKey, PadId, AreaIndex          [BuildIn, BuyerUserId]
		      Pads (Folder)
		        <padId> (Model)      tag "SNPad": PadId, OwnerUserId, Cost, Kind, Name, Blurb, Color, Area,
		                             Order, Value?, Feature?, [PressedAt]; children Trigger (Part), Visual
		      Producer (Model)       ProducerId
		        Anchor (Part)        tag "SNProducer": billboard adornee; TycoonService publishes the
		                             producer attributes on it
		        ClickBox (Part)      invisible, CanQuery, ClickDetector (3D mouse click / touch tap →
		                             server); the client's CLICK bar / keys fire ProducerClick instead
		Purchases only: BuildIn = workspace:GetServerTimeNow(), BuyerUserId and the CollectionService tag
		"BuildIn" are set on the build Model BEFORE it is parented, so a client sees them the moment the
		model streams in (B4 animates). The Unlock pad of area N builds Area{N+1}.Base (entry-arch
		convention) and stamps AreaUnlock = N+1 on it (fanfare). A restored plot (rejoin, rebirth,
		admin rebuild) has no BuildIn and no tag: clients show it finished. A bought pad gets
		PressedAt = server time and is destroyed PadPressSeconds later (squish + ka-ching).

	Streaming (Workspace.StreamingEnabled): plot root Default (streams by region); every build /
	base / entrance Model Atomic (never half-built); Pads and Producer Models PersistentPerPlayer
	for the owner (their billboards and pads are always present on the owner's client, even after
	a teleport), Atomic for everyone else.

	Async safety: building spawns meshes (MeshLibrary.spawn yields while templates load). Every
	async build captures the plot's `generation`; clear() bumps it, so a build finishing after a
	release / rebirth is destroyed instead of appearing on the wrong owner's plot.

	Connections
		Shared/Config/WorldLayout (frames), Tycoon/AreaLayouts (what to build), World/MeshLibrary +
		World/WorldMaterials (meshes, stud material), Shared/Config/TycoonConfig (pads, producers).
		Driven by Tycoon/PlotService (owner, sign) and Tycoon/TycoonService (restore, purchases,
		pads, producers); events reach TycoonService through setHandlers().

	Worlds (owner R57, plan §3.3)
		Every world has the same 8-plot ring (WorldLayout, relative to its WorldGeometry origin) and
		the same contract. `PlotBuilder.world(worldId)` returns that world's builder: the full
		function set below, bound to the world's economy (WorldsConfig economy index + bound
		TycoonLogic), layouts (AreaLayouts.get(area, worldId)) and frames. `PlotBuilder.<fn>` IS
		`PlotBuilder.world("main").<fn>`, so every existing caller is unchanged.
		Trees: Nuke Town keeps Workspace.Plots.PlotN; another world builds
		Workspace.Worlds.<id>.Plots.PlotN. Every plot model carries attribute WorldId. A non-main
		world's plot frame / locked slot come from its hub layout (WorldDef.hubLayout, Dino:
		ValleyLayout.plotFrame / lockedSlot, plot-local) once every mesh key of them is synced;
		until then the primitive ground + road + arch frame is used (warned once).
		Handlers stay world-agnostic: pad and producer ids are globally unique (prefixed), so
		TycoonService resolves the world from the id it receives.

	Usage
		PlotBuilder.createPlots()
		PlotBuilder.setHandlers({ padTouched = onPad, producerClicked = onClick })
		PlotBuilder.restore(1, profile.tycoon, player)          -- yields; no BuildIn
		PlotBuilder.buildPurchase(1, "a1_tool_wall", player)    -- async; BuildIn set
		local Dino = PlotBuilder.world("dino")
		PlotBuilder.createWorldPlots("dino")                    -- 8 empty Valley frames at boot
		Dino.restore(1, profile.worlds.dino.tycoon)             -- yields; Workspace.Worlds.dino.Plots.Plot1
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AreaLayouts = require(script.Parent.Parent.Tycoon.AreaLayouts)
local HubBuilder = require(script.Parent.HubBuilder)
local LayoutLogic = require(script.Parent.Parent.Tycoon.LayoutLogic)
local MeshLibrary = require(script.Parent.MeshLibrary)
local TycoonConfig = require(ReplicatedStorage.Shared.Config.TycoonConfig)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)
local TycoonTypes = require(ReplicatedStorage.Shared.Tycoon.TycoonTypes)
local MeshPlacement = require(ReplicatedStorage.Shared.World.MeshPlacement)
-- Owner R88 plot names: the owner-sign tag, the default suffix and the sign text rule.
local PlotNameConfig = require(ReplicatedStorage.Shared.Config.PlotNameConfig)
local PlotNameLogic = require(ReplicatedStorage.Shared.Tycoon.PlotNameLogic)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)
local WorldMaterials = require(script.Parent.WorldMaterials)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

type PadConfig = TycoonTypes.PadConfig
type TycoonState = TycoonTypes.TycoonState
type BuildEntry = LayoutLogic.BuildEntry

export type Handlers = {
	padTouched: (plotIndex: number, padId: string, hit: BasePart) -> (),
	-- ClickDetector on a producer's ClickBox (mouse / touch tap on the 3D producer).
	producerClicked: ((plotIndex: number, producerId: string, player: Player) -> ())?,
}

local PlotBuilder = {}

-- Folder in Workspace holding every plot (Nuke Town). Another world: Workspace.<WorldsFolderName>.<id>.<FolderName>.
PlotBuilder.FolderName = "Plots"
-- R57: Workspace folder holding every non-main world's region (W4's HubBuilder builds `<id>.Hub` in it).
PlotBuilder.WorldsFolderName = "Worlds"

-- Pad top colours by kind (reference 11: red = decoration, yellow = multiplier). The area's
-- builder pad (first pad) is green: "start here".
local PAD_COLORS: { [string]: Color3 } = {
	Build = Color3.fromRGB(235, 70, 70),
	Builder = Color3.fromRGB(80, 220, 100),
	Multiplier = Color3.fromRGB(255, 205, 50),
	Speed = Color3.fromRGB(70, 175, 255),
	Manager = Color3.fromRGB(80, 220, 100),
	Feature = Color3.fromRGB(170, 90, 240),
	Unlock = Color3.fromRGB(255, 140, 40),
}
PlotBuilder.PadColors = table.freeze(PAD_COLORS)

-- Pad touch volume (studs): wide enough to step on, short so it only catches feet.
local TRIGGER_SIZE = Vector3.new(7, 3, 7)
-- Seconds a bought pad stays (with PressedAt) before it is destroyed, for the client squish.
PlotBuilder.PadPressSeconds = 0.6
-- ClickDetector reach on a producer's ClickBox (the server re-checks reach too).
PlotBuilder.ClickDistance = 48

-- CollectionService tags (client contract, docs/tycoon-server.md).
PlotBuilder.Tags = table.freeze({ BuildIn = "BuildIn", Pad = "SNPad", Producer = "SNProducer" })

-- Colours of the plot shell.
local GROUND_COLOR = Color3.fromRGB(95, 200, 85)
local ROAD_COLOR = Color3.fromRGB(95, 98, 110)
local ARCH_COLOR = Color3.fromRGB(245, 245, 250)
local SIGN_COLOR = Color3.fromRGB(40, 44, 60)
-- Outline of sign text (owner plate, stand name): dark navy, readable on cream and dark plates.
local SIGN_OUTLINE = Color3.fromRGB(30, 34, 52)
-- The stand name on the Nuke Stand's Neon Sign (yellow neon; default before a rename).
local STAND_NAME_COLOR = Color3.fromRGB(255, 240, 120)
local STAND_DEFAULT_NAME = "Fresh Nukes!"

type PlotState = {
	index: number,
	world: WorldCtx, -- R57: the world this plot belongs to
	model: Model,
	generation: number,
	owner: Player?,
	signLabels: { TextLabel },
	signText: string,
	entrance: CFrame, -- world, ground level: where the owner respawns / arrives
	locked: { [number]: Model }, -- area index -> locked-slot placeholder model
	lockedLabels: { [number]: { text: string, label: TextLabel? } },
}

--[[
	R57: one world's builder context. `economy` / `logic` replace the old module-level TycoonConfig /
	TycoonLogic (Nuke Town's are the very same tables), `plots` / `folder` the old module state.
]]
type WorldCtx = {
	id: string,
	def: WorldsConfig.WorldDef,
	economy: TycoonTypes.EconomyIndex,
	logic: TycoonLogic.Logic,
	plots: { [number]: PlotState },
	folder: Folder?,
	-- Hub layout (plotFrame / lockedSlot / plotColors), resolved once (main: HubBuilder.layout()).
	hubResolved: boolean,
	hub: any,
	-- Owner sign: "<DisplayName>'s <signSuffix>" ("Nukes" in Nuke Town, the world name elsewhere).
	signSuffix: string,
}

local handlers: Handlers? = nil
-- Every world's context (created on first use by ctxOf).
local worlds: { [string]: WorldCtx } = {}

--[[
	The builder context of a world (created once). Errors for an unknown world id: callers only pass
	registry ids (a programming error, never player input).
]]
local function ctxOf(worldId: string): WorldCtx
	local existing = worlds[worldId]
	if existing ~= nil then
		return existing
	end
	local def = WorldsConfig.get(worldId)
	assert(def ~= nil, `PlotBuilder: unknown world {tostring(worldId)}`)
	local isMain = def.id == WorldsConfig.MAIN
	local ctx: WorldCtx = {
		id = def.id,
		def = def,
		-- Nuke Town keeps its exact module tables (TycoonConfig IS the main economy index).
		economy = if isMain then TycoonConfig :: any else def.economy,
		logic = if isMain then TycoonLogic :: any else TycoonLogic.forWorld(def.id),
		plots = {},
		folder = nil,
		hubResolved = false,
		hub = nil,
		signSuffix = if isMain then PlotNameConfig.MainSuffix else def.name,
	}
	worlds[def.id] = ctx
	return ctx
end

-- Every mesh key a hub layout's plot frame + locked slot place (to adopt it only when all exist).
local function frameKeys(hub: any): { string }
	local keys: { string } = {}
	for _, list in { hub.plotFrame and hub.plotFrame.models, hub.lockedSlot and hub.lockedSlot.models } do
		for _, entry in if type(list) == "table" then list else {} do
			if type(entry) == "table" and type(entry.key) == "string" then
				table.insert(keys, entry.key)
			end
		end
	end
	return keys
end

--[[
	The hub layout a world's plot frames come from (nil = primitive frame). Nuke Town: HubBuilder's
	(it already falls back when meshes are missing). Another world: its WorldDef.hubLayout module
	(AreaLayouts.worldHub), adopted only once every plot-frame / locked-slot mesh key is synced, so a
	half-uploaded frame never leaves invisible ground (warned once).
]]
local function hubOf(w: WorldCtx): any
	if w.hubResolved then
		return w.hub
	end
	w.hubResolved = true
	if w.id == WorldsConfig.MAIN then
		w.hub = HubBuilder.layout()
		return w.hub
	end
	local hub = AreaLayouts.worldHub(w.id)
	if type(hub) ~= "table" then
		return nil
	end
	local missing = 0
	local keys = frameKeys(hub)
	for _, key in keys do
		if not MeshLibrary.has(key) then
			missing += 1
		end
	end
	if missing > 0 then
		warn(
			`[PlotBuilder] {w.id} plot frame uses {missing} of {#keys} mesh keys not in MeshAssets yet; primitive frames`
		)
		return nil
	end
	w.hub = hub
	return hub
end

--------------------------------------------------------------------------------------------------
-- Primitive helpers
--------------------------------------------------------------------------------------------------

-- An anchored part with the stud material (or `material` from WorldMaterialConfig).
local function studPart(
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	collide: boolean,
	material: string?
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.CanCollide = collide
	part.CanQuery = collide
	part.CanTouch = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	WorldMaterials.apply(part, material or "Studs")
	return part
end

-- An invisible anchored collision box (never touched / queried by game code).
local function collisionPart(size: Vector3, cf: CFrame): Part
	local part = Instance.new("Part")
	part.Name = "Collision"
	part.Anchored = true
	part.Size = size
	part.CFrame = cf
	part.Transparency = 1
	part.CanCollide = true
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	return part
end

-- Big friendly label on one face of a part (signs, placeholder labels).
-- `face` is the MODEL's side: MeshPlacement.face swaps Front/Back on yawed mesh pieces (Roblox's
-- FBX import turns meshes 180°), primitives are unchanged.
local function faceLabel(part: BasePart, face: Enum.NormalId, text: string): TextLabel
	local partFace = MeshPlacement.face(part, face)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Label" .. face.Name
	gui.Face = partFace
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0.2
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = Color3.new(1, 1, 1)
	-- A thick dark outline instead of the 1 px TextStroke (World-QA E1, 2026-10-30: white text
	-- on the cream entrance-arch plate was unreadable); it also reads on the dark fallback sign.
	label.TextStrokeTransparency = 1
	local stroke = Instance.new("UIStroke")
	stroke.Color = SIGN_OUTLINE
	stroke.Thickness = 6
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = label
	label.Text = text
	label.Parent = gui
	gui.Parent = part
	return label
end

--------------------------------------------------------------------------------------------------
-- Building layout entries
--------------------------------------------------------------------------------------------------

-- Keys we already warned about (missing from MeshAssets); warn once each.
local warnedKeys: { [string]: boolean } = {}

--[[
	Builds one layout entry (models + collision) into `container`, in world space via `slot`.
	Mesh entries go through MeshLibrary (may yield while templates load); primitive placeholder
	entries become stud Parts; `collide` mesh entries get an invisible box from the mesh bounds.
]]
local function buildEntry(container: Instance, entry: BuildEntry, slot: CFrame)
	for index, model in entry.models do
		local world = slot * model.cf
		local key = model.key
		if key ~= nil and MeshLibrary.has(key) then
			MeshLibrary.spawn(key, container, world, {
				tint = model.tint,
				castShadow = model.castShadow,
				name = `{key}_{index}`,
			})
			if model.collide then
				local centre, size = MeshLibrary.getBounds(key)
				collisionPart(size, world * centre).Parent = container
			end
		elseif model.box ~= nil then
			local part = studPart(
				`Block_{index}`,
				model.box,
				world,
				model.color or Color3.fromRGB(200, 200, 200),
				model.collide == true,
				model.material
			)
			if model.shape == "Ball" then
				part.Shape = Enum.PartType.Ball
			elseif model.shape == "Cylinder" then
				part.Shape = Enum.PartType.Cylinder
			end
			part:SetAttribute("BuildOrder", index)
			if model.label ~= nil then
				faceLabel(part, Enum.NormalId.Front, model.label)
			end
			part.Parent = container
		else
			-- A mesh key the art builder referenced but MeshAssets does not have yet: a neutral box,
			-- so the build still appears (and collides) where the art will go.
			if key ~= nil and not warnedKeys[key] then
				warnedKeys[key] = true
				warn(`[PlotBuilder] mesh key {key} is not in MeshAssets yet; building a placeholder box`)
			end
			local part = studPart(
				`Missing_{index}`,
				Vector3.new(4, 4, 4),
				world * CFrame.new(0, 2, 0),
				Color3.fromRGB(255, 120, 200),
				true
			)
			part.Parent = container
		end
	end
	for _, box in entry.collision or {} do
		collisionPart(box.size, slot * box.cf).Parent = container
	end
end

--------------------------------------------------------------------------------------------------
-- Plots
--------------------------------------------------------------------------------------------------

-- Updates every sign label on a plot's entrance (remembered for labels created later: the
-- HubLayout arch mesh streams in after the plot exists).
local function setSignText(state: PlotState, text: string)
	state.signText = text
	for _, label in state.signLabels do
		label.Text = text
	end
end

-- A small invisible marker part (YOU anchor).
local function markerPart(name: string, cf: CFrame): Part
	local marker = Instance.new("Part")
	marker.Name = name
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanQuery = false
	marker.CanTouch = false
	marker.Transparency = 1
	marker.Size = Vector3.new(1, 1, 1)
	marker.CFrame = cf
	return marker
end

--[[
	Spawns the HubLayout plot-frame meshes of one plot (yields while templates load), tinting
	`plotTint` pieces with the plot colour, then puts the owner sign labels on the arch's sign piece.
]]
local function buildFrameMeshes(state: PlotState, frame: any, hub: any, container: Instance)
	local origin = WorldLayout.plotOrigin(state.index, state.world.id)
	local plotColor = if type(hub.plotColors) == "table" then hub.plotColors[state.index] else nil
	for index, entry in frame.models or {} do
		if
			type(entry) ~= "table"
			or type(entry.key) ~= "string"
			or typeof(entry.cf) ~= "CFrame"
			or not MeshLibrary.has(entry.key)
		then
			continue
		end
		local tint = if entry.plotTint == true and typeof(plotColor) == "Color3" then plotColor else entry.tint
		MeshLibrary.spawn(entry.key, container, origin * entry.cf, {
			tint = if typeof(tint) == "Color3" then tint else nil,
			colors = if type(entry.colors) == "table" then entry.colors else nil,
			castShadow = if type(entry.castShadow) == "boolean" then entry.castShadow else nil,
			name = if type(entry.name) == "string" then entry.name else `{entry.key}_{index}`,
		})
	end
	local sign = type(frame.anchors) == "table" and frame.anchors.OwnerSign or nil
	local arch = if type(sign) == "table" and type(sign.model) == "string"
		then container:FindFirstChild(sign.model)
		else nil
	local piece = if arch ~= nil and type(sign.piece) == "string" then arch:FindFirstChild(sign.piece) else nil
	if piece ~= nil and piece:IsA("BasePart") then
		-- Owner R88: the owner's client finds its own sign by this tag (naming click box + prompt).
		CollectionService:AddTag(piece, PlotNameConfig.SignTag)
		for _, faceName in sign.faces or { "Front" } do
			local ok, face = pcall(function()
				return (Enum.NormalId :: any)[faceName]
			end)
			if ok and face ~= nil then
				table.insert(state.signLabels, faceLabel(piece, face, state.signText))
			end
		end
	end
end

--[[
	Builds one empty plot. With HubLayout.plotFrame: its colliders (synchronous, walkable at once),
	YouAnchor at anchors.YouMarker, the entrance at anchors.Entrance, and the frame meshes
	asynchronously. Without it: primitive stud ground, road and an entrance arch with the sign.
]]
local function createPlot(w: WorldCtx, index: number, parent: Instance): PlotState
	local origin = WorldLayout.plotOrigin(index, w.id)
	local model = Instance.new("Model")
	model.Name = `Plot{index}`
	model.ModelStreamingMode = Enum.ModelStreamingMode.Default
	model:SetAttribute("PlotIndex", index)
	model:SetAttribute("WorldId", w.id)
	model:SetAttribute("OwnerUserId", 0)
	model:SetAttribute("OwnerName", "")
	model:SetAttribute("StandName", "")
	model:SetAttribute("PlotName", "") -- owner R88: no custom plot name
	model:SetAttribute("PlotReady", false)
	local state: PlotState = {
		index = index,
		world = w,
		model = model,
		generation = 0,
		owner = nil,
		signLabels = {},
		signText = "FREE PLOT",
		entrance = WorldLayout.entranceSpawn(index, w.id),
		locked = {},
		lockedLabels = {},
	}

	-- HubLayout (or the world's hub layout) is optional, untyped art data (validated field by field below).
	local hub: any = hubOf(w)
	local frame: any = if hub ~= nil and type(hub.plotFrame) == "table" then hub.plotFrame else nil
	local anchors: any = if frame ~= nil and type(frame.anchors) == "table" then frame.anchors else {}
	if frame ~= nil then
		local frameModel = Instance.new("Model")
		frameModel.Name = "Frame"
		frameModel.ModelStreamingMode = Enum.ModelStreamingMode.Default
		for _, box in frame.collision or {} do
			if type(box) == "table" and typeof(box.size) == "Vector3" and typeof(box.cf) == "CFrame" then
				collisionPart(box.size, origin * box.cf).Parent = frameModel
			end
		end
		frameModel.Parent = model
		if typeof(anchors.Entrance) == "CFrame" then
			state.entrance = origin * anchors.Entrance
		end
		task.spawn(buildFrameMeshes, state, frame, hub, frameModel)
	else
		local length = WorldLayout.plotLength(w.id)
		local ground = studPart(
			"Ground",
			Vector3.new(WorldLayout.PlotHalfWidth * 2, 4, length),
			origin * CFrame.new(0, -2, length / 2),
			GROUND_COLOR,
			true,
			"StudsLarge"
		)
		ground.CastShadow = false
		ground.Parent = model
		local road = studPart(
			"Road",
			Vector3.new(WorldLayout.RoadHalfWidth * 2, 0.2, length),
			origin * CFrame.new(0, -0.06, length / 2),
			ROAD_COLOR,
			true
		)
		road.CastShadow = false
		road.Parent = model

		local entrance = Instance.new("Model")
		entrance.Name = "Entrance"
		entrance.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
		local z = WorldLayout.EntranceZ
		studPart("PillarLeft", Vector3.new(3, 16, 3), origin * CFrame.new(-11, 8, z), ARCH_COLOR, true).Parent =
			entrance
		studPart("PillarRight", Vector3.new(3, 16, 3), origin * CFrame.new(11, 8, z), ARCH_COLOR, true).Parent =
			entrance
		local sign = studPart("Sign", Vector3.new(26, 5, 2), origin * CFrame.new(0, 18.5, z), SIGN_COLOR, true)
		CollectionService:AddTag(sign, PlotNameConfig.SignTag) -- owner R88: the naming sign
		sign.Parent = entrance
		table.insert(state.signLabels, faceLabel(sign, Enum.NormalId.Front, state.signText))
		table.insert(state.signLabels, faceLabel(sign, Enum.NormalId.Back, state.signText))
		entrance.Parent = model
	end
	-- Where the owner's client hangs its "YOU" BillboardGui (direct child of the plot).
	local youCf = if typeof(anchors.YouMarker) == "CFrame"
		then origin * anchors.YouMarker
		else origin * CFrame.new(0, 26, WorldLayout.EntranceZ)
	markerPart("YouAnchor", youCf).Parent = model

	model.WorldPivot = origin
	model.Parent = parent
	return state
end

local syncLocked: (w: WorldCtx, index: number, tycoon: TycoonState?) -> ()

--[[
	The parent a world's plots folder lives in: Workspace for Nuke Town, Workspace.Worlds.<id> for
	another world (found or created; W4's HubBuilder puts the world's Hub in the same folder).
]]
local function worldParent(w: WorldCtx): Instance
	if w.id == WorldsConfig.MAIN then
		return Workspace
	end
	local root = Workspace:FindFirstChild(PlotBuilder.WorldsFolderName)
	if root == nil then
		local created = Instance.new("Folder")
		created.Name = PlotBuilder.WorldsFolderName
		created.Parent = Workspace
		root = created
	end
	local region = (root :: Instance):FindFirstChild(w.id)
	if region == nil then
		local created = Instance.new("Folder")
		created.Name = w.id
		created.Parent = root
		region = created
	end
	return region :: Instance
end

--[[
	Creates a world's plots folder and its 8 empty plots (idempotent): Workspace.Plots for Nuke
	Town, Workspace.Worlds.<id>.Plots for another world.
	@return {Model}
]]
local function createPlots(w: WorldCtx): { Model }
	if w.folder == nil then
		local parent = worldParent(w)
		local existing = parent:FindFirstChild(PlotBuilder.FolderName)
		if existing ~= nil then
			existing:Destroy()
		end
		local created = Instance.new("Folder")
		created.Name = PlotBuilder.FolderName
		created.Parent = parent
		w.folder = created
		WorldMaterials.ensure()
		for index = 1, WorldLayout.PlotCount do
			w.plots[index] = createPlot(w, index, created)
			syncLocked(w, index, nil)
		end
	end
	local list: { Model } = {}
	for index = 1, WorldLayout.PlotCount do
		table.insert(list, w.plots[index].model)
	end
	return list
end

-- The state of a plot (errors for a bad index / plots not created: programming bug).
local function stateOf(w: WorldCtx, index: number): PlotState
	return assert(w.plots[index], "PlotBuilder: plots not created or bad plot index")
end

--[[ The plot Model. ]]
local function getPlot(w: WorldCtx, index: number): Model
	return stateOf(w, index).model
end

--[[
	Installs the event callbacks (TycoonService). Pad touches and producer ClickDetector clicks are
	forwarded with the plot index; the handlers do every validation (owner, reach, idle). The
	client sends ProducerClick only for its CLICK bar / keys, never for 3D clicks, and a cycle can
	only start while idle, so a click is never counted twice.
]]
function PlotBuilder.setHandlers(newHandlers: Handlers)
	handlers = newHandlers
end

--[[
	Sets / clears a plot's owner: sign text "<DisplayName>'s Nukes" ("<DisplayName>'s Dino Valley"
	in another world; Roblox display names are already moderated), OwnerUserId / OwnerName
	attributes (the client draws YOU from OwnerUserId).
	@param index number
	@param owner Player?
]]
local function setOwner(w: WorldCtx, index: number, owner: Player?)
	local state = stateOf(w, index)
	state.owner = owner
	state.model:SetAttribute("PlotReady", false) -- a (re)assigned plot is ready after its restore
	state.model:SetAttribute("OwnerUserId", if owner ~= nil then owner.UserId else 0)
	state.model:SetAttribute("OwnerName", if owner ~= nil then owner.DisplayName else "")
	-- Owner R88: a new owner starts on the default sign; PlotNames re-applies their custom name.
	state.model:SetAttribute("PlotName", "")
	setSignText(state, if owner ~= nil then PlotNameLogic.defaultName(owner.DisplayName, w.signSuffix) else "FREE PLOT")
end

--[[
	Overrides the owner sign text of an unowned plot (owner R51: an admin attack test bot's plot
	reads "TestBot 3 (BOT)"). setOwner resets it. Server-built text only (never player input).
	@param index number
	@param text string
]]
local function setSignLabel(w: WorldCtx, index: number, text: string)
	local state = stateOf(w, index)
	state.model:SetAttribute("OwnerName", text)
	setSignText(state, text)
end

--[[
	Owner R88: shows an OWNED plot's custom name on its entrance sign (every face, labels created
	later included) and publishes it as the plot attribute PlotName. "" restores the default
	"<DisplayName>'s Nukes" ("<DisplayName>'s Dino Valley" in another world). A free / bot plot is
	left untouched (only setOwner / setSignLabel write those). The text must ALREADY be filtered for
	broadcast by the caller (Server/Tycoon/PlotNames) — never pass raw player input.
	@param index number
	@param text string — filtered custom name, or "" for the default
	Example: PlotBuilder.setPlotName(3, "Sparkle Base")
]]
local function setPlotName(w: WorldCtx, index: number, text: string)
	local state = stateOf(w, index)
	local owner = state.owner
	if owner == nil then
		return
	end
	state.model:SetAttribute("PlotName", text)
	setSignText(state, PlotNameLogic.signText(owner.DisplayName, w.signSuffix, text))
end

--------------------------------------------------------------------------------------------------
-- Areas
--------------------------------------------------------------------------------------------------

-- The AreaNN model of a plot (created on demand).
local function areaModel(state: PlotState, areaIndex: number): Model
	local name = string.format("Area%02d", areaIndex)
	local existing = state.model:FindFirstChild(name)
	if existing ~= nil and existing:IsA("Model") then
		return existing
	end
	local model = Instance.new("Model")
	model.Name = name
	model.ModelStreamingMode = Enum.ModelStreamingMode.Default
	model:SetAttribute("AreaIndex", areaIndex)
	model.WorldPivot = WorldLayout.slotOrigin(state.index, areaIndex, state.world.id)
	for _, childName in { "Builds", "Pads" } do
		local child = Instance.new("Folder")
		child.Name = childName
		child.Parent = model
	end
	model.Parent = state.model
	return model
end

-- Child folder of an area model.
local function areaFolder(state: PlotState, areaIndex: number, name: string): Instance
	return areaModel(state, areaIndex):FindFirstChild(name) :: Instance
end

--[[
	Builds one container (area base or a build key) into its area. Yields while meshes load.
	`buyer` set = a purchase: BuildIn / BuyerUserId are stamped BEFORE parenting.
	Returns nil when the plot was cleared meanwhile (the stale build is destroyed).
]]
local function buildContainer(
	state: PlotState,
	areaIndex: number,
	name: string,
	entry: BuildEntry,
	parentName: string?,
	attributes: { [string]: any },
	buyer: Player?
): Model?
	local generation = state.generation
	local container = Instance.new("Model")
	container.Name = name
	container.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	for key, value in attributes do
		container:SetAttribute(key, value)
	end
	buildEntry(container, entry, WorldLayout.slotOrigin(state.index, areaIndex, state.world.id))
	if state.generation ~= generation then
		container:Destroy()
		return nil
	end
	if buyer ~= nil then
		container:SetAttribute("BuildIn", Workspace:GetServerTimeNow())
		container:SetAttribute("BuyerUserId", buyer.UserId)
		CollectionService:AddTag(container, PlotBuilder.Tags.BuildIn)
	end
	local area = areaModel(state, areaIndex)
	local parent = if parentName ~= nil then area:FindFirstChild(parentName) :: Instance else area
	local old = parent:FindFirstChild(name)
	if old ~= nil then
		old:Destroy()
	end
	container.Parent = parent
	return container
end

-- Builds an area's base (yields). A purchase (`buyer`) stamps AreaUnlock for the unlock fanfare;
-- area 1's base is built at plot claim without it.
local function buildAreaBase(state: PlotState, areaIndex: number, buyer: Player?)
	local layout = AreaLayouts.get(areaIndex, state.world.id)
	local attributes: { [string]: any } = { AreaIndex = areaIndex }
	if buyer ~= nil and areaIndex > 1 then
		attributes.AreaUnlock = areaIndex
	end
	buildContainer(state, areaIndex, "Base", layout.base, nil, attributes, buyer)
end

-- Builds the build key of a pad (yields). Returns the container. An Unlock pad that opens an area
-- has no build of its own: its key is the next area's base (entry-arch convention).
local function buildPadBuild(state: PlotState, pad: PadConfig, buyer: Player?): Model?
	if LayoutLogic.opensArea(pad) then
		return nil
	end
	local layout = AreaLayouts.get(pad.area, state.world.id)
	local entry = layout.builds[pad.build]
	if entry == nil then
		return nil
	end
	return buildContainer(
		state,
		pad.area,
		pad.build,
		entry,
		"Builds",
		{ BuildKey = pad.build, PadId = pad.id, AreaIndex = pad.area },
		buyer
	)
end

--------------------------------------------------------------------------------------------------
-- Producers
--------------------------------------------------------------------------------------------------

-- Marks a Model persistent for the plot owner (owner always has it; Atomic for everyone else).
local function persistForOwner(model: Model, owner: Player?)
	if owner ~= nil and owner.Parent == Players then
		model.ModelStreamingMode = Enum.ModelStreamingMode.PersistentPerPlayer
		model:AddPersistentPlayer(owner)
	else
		model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	end
end

--[[
	Creates (once) the producer model of an area: Anchor (billboard adornee, tag SNProducer, attributes
	published by TycoonService) and ClickBox (ClickDetector). Synchronous (no meshes).
	@return BasePart — the Anchor
]]
local function ensureProducer(w: WorldCtx, index: number, producerId: string): BasePart
	local state = stateOf(w, index)
	local producer = assert(w.economy.ProducersById[producerId], "PlotBuilder.ensureProducer: bad producer")
	local area = areaModel(state, producer.area)
	local existing = area:FindFirstChild("Producer")
	if existing ~= nil then
		return (existing :: Instance):FindFirstChild("Anchor") :: BasePart
	end
	local layout = AreaLayouts.get(producer.area, w.id)
	local slot = WorldLayout.slotOrigin(index, producer.area, w.id)
	local model = Instance.new("Model")
	model.Name = "Producer"
	model:SetAttribute("ProducerId", producerId)

	local anchor = Instance.new("Part")
	anchor.Name = "Anchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.CFrame = slot * CFrame.new(layout.producer.anchor)
	anchor:SetAttribute("ProducerId", producerId)
	anchor:SetAttribute("Area", producer.area)
	anchor:SetAttribute("Name", producer.name)
	anchor:SetAttribute("OwnerUserId", if state.owner ~= nil then state.owner.UserId else 0)
	CollectionService:AddTag(anchor, PlotBuilder.Tags.Producer)
	anchor.Parent = model

	-- Mouse clicks / touch taps on the 3D producer: the ClickDetector reports the authentic player
	-- to the server (validated there); CanQuery so the detector and client raycasts see it.
	local clickBox = Instance.new("Part")
	clickBox.Name = "ClickBox"
	clickBox.Anchored = true
	clickBox.CanCollide = false
	clickBox.CanQuery = true
	clickBox.CanTouch = false
	clickBox.Transparency = 1
	clickBox.Size = layout.producer.click.size
	clickBox.CFrame = slot * layout.producer.click.cf
	local detector = Instance.new("ClickDetector")
	detector.MaxActivationDistance = PlotBuilder.ClickDistance
	detector.MouseClick:Connect(function(player: Player)
		local current = handlers
		if current ~= nil and current.producerClicked ~= nil then
			current.producerClicked(index, producerId, player)
		end
	end)
	detector.Parent = clickBox
	clickBox.Parent = model

	model.WorldPivot = anchor.CFrame
	persistForOwner(model, state.owner)
	model.Parent = area
	return anchor
end

--[[ The producer's billboard anchor, or nil when not built on this plot. ]]
local function getProducerAnchor(w: WorldCtx, index: number, producerId: string): BasePart?
	local state = stateOf(w, index)
	local producer = w.economy.ProducersById[producerId]
	if producer == nil then
		return nil
	end
	local area = state.model:FindFirstChild(string.format("Area%02d", producer.area))
	local model = if area ~= nil then area:FindFirstChild("Producer") else nil
	local anchor = if model ~= nil then model:FindFirstChild("Anchor") else nil
	return if anchor ~= nil and anchor:IsA("BasePart") then anchor else nil
end

--------------------------------------------------------------------------------------------------
-- Pads
--------------------------------------------------------------------------------------------------

-- The pad top colour of a pad of a world (the builder pad of an area is green).
local function padColorIn(w: WorldCtx, pad: PadConfig): Color3
	if w.economy.ProducerBuiltBy[pad.id] ~= nil then
		return PAD_COLORS.Builder
	end
	return PAD_COLORS[pad.kind] or PAD_COLORS.Build
end

--[[
	The pad top colour of a pad.
	@param pad PadConfig
	@param worldId string? — R57: the pad's world (nil = resolved from the pad id, else Nuke Town)
	@return Color3
]]
function PlotBuilder.padColor(pad: PadConfig, worldId: string?): Color3
	return padColorIn(ctxOf(worldId or WorldsConfig.worldOfPad(pad.id) or WorldsConfig.MAIN), pad)
end

--[[ The pad Model on a plot, or nil. ]]
local function getPad(w: WorldCtx, index: number, padId: string): Model?
	local state = stateOf(w, index)
	local pad = w.economy.PadsById[padId]
	if pad == nil then
		return nil
	end
	local area = state.model:FindFirstChild(string.format("Area%02d", pad.area))
	local pads = if area ~= nil then area:FindFirstChild("Pads") else nil
	local model = if pads ~= nil then pads:FindFirstChild(padId) else nil
	return if model ~= nil and model:IsA("Model") then model else nil
end

-- World position of a pad's centre (ground level).
local function padPosition(w: WorldCtx, index: number, padId: string): Vector3?
	local pad = w.economy.PadsById[padId]
	if pad == nil then
		return nil
	end
	local layout = AreaLayouts.get(pad.area, w.id)
	local point = layout.pads[padId]
	return if point ~= nil then WorldLayout.slotPointToWorld(index, pad.area, point, w.id) else nil
end

-- Creates one BuyPad (attributes + trigger synchronously, the mesh visual asynchronously).
local function createPad(state: PlotState, pad: PadConfig)
	local w = state.world
	local position = assert(padPosition(w, state.index, pad.id), "pad position")
	local slot = WorldLayout.slotOrigin(state.index, pad.area, w.id)
	-- Pads face the road like everything else in the slot (yaw of the slot frame).
	local cf = CFrame.new(position) * (slot - slot.Position)
	local color = padColorIn(w, pad)
	local model = Instance.new("Model")
	model.Name = pad.id
	model:SetAttribute("PadId", pad.id)
	model:SetAttribute("OwnerUserId", if state.owner ~= nil then state.owner.UserId else 0)
	model:SetAttribute("Cost", pad.cost)
	model:SetAttribute("Kind", pad.kind)
	model:SetAttribute("Name", pad.name)
	model:SetAttribute("Blurb", pad.blurb)
	model:SetAttribute("Color", color)
	model:SetAttribute("Area", pad.area)
	model:SetAttribute("Order", w.economy.PadIndex[pad.id])
	if pad.value ~= nil then
		model:SetAttribute("Value", pad.value)
	end
	if pad.feature ~= nil then
		model:SetAttribute("Feature", pad.feature)
	end
	local trigger = Instance.new("Part")
	trigger.Name = "Trigger"
	trigger.Anchored = true
	trigger.CanCollide = false
	trigger.CanQuery = false
	trigger.CanTouch = true
	trigger.Transparency = 1
	trigger.Size = TRIGGER_SIZE
	trigger.CFrame = cf * CFrame.new(0, TRIGGER_SIZE.Y / 2, 0)
	local index, padId = state.index, pad.id
	trigger.Touched:Connect(function(hit: BasePart)
		local current = handlers
		if current ~= nil then
			current.padTouched(index, padId, hit)
		end
	end)
	trigger.Parent = model
	model.WorldPivot = cf
	persistForOwner(model, state.owner)
	CollectionService:AddTag(model, PlotBuilder.Tags.Pad)
	model.Parent = areaFolder(state, pad.area, "Pads")

	-- Visual (may wait for the BuyPad template on a cold server).
	local generation = state.generation
	task.spawn(function()
		if not MeshLibrary.has("BuyPad") then
			studPart("Top", Vector3.new(6, 1, 6), cf * CFrame.new(0, 0.5, 0), color, false).Parent = model
			return
		end
		local visual = MeshLibrary.spawn("BuyPad", nil, cf, { tint = color, name = "Visual" })
		if state.generation ~= generation or model.Parent == nil then
			visual:Destroy()
			return
		end
		visual.Parent = model
	end)
end

--[[
	Makes the plot show exactly `pads` as BuyPads (the next pads of the chain): creates missing
	ones, removes every other pad. Synchronous (pad visuals finish asynchronously).
	@param index number
	@param pads {PadConfig} — TycoonLogic.nextPads(state)
]]
local function syncPads(w: WorldCtx, index: number, pads: { PadConfig })
	local state = stateOf(w, index)
	local wanted: { [string]: PadConfig } = {}
	for _, pad in pads do
		wanted[pad.id] = pad
	end
	for _, child in state.model:GetChildren() do
		local padsFolder = child:FindFirstChild("Pads")
		if child:IsA("Model") and padsFolder ~= nil then
			for _, padModel in padsFolder:GetChildren() do
				if padModel:GetAttribute("PressedAt") ~= nil then
					continue -- a bought pad finishing its squish; pressPad destroys it
				elseif wanted[padModel.Name] == nil then
					padModel:Destroy()
				else
					wanted[padModel.Name] = nil
				end
			end
		end
	end
	for _, pad in pads do
		if wanted[pad.id] ~= nil then
			createPad(state, pad)
		end
	end
end

--[[
	Marks a bought pad: PressedAt = server time (the client plays its squish + ka-ching), its
	trigger stops catching touches at once, and the model is destroyed PadPressSeconds later.
	Call BEFORE syncPads (which then leaves the pressed pad alone).
	@param index number
	@param padId string
]]
local function pressPad(w: WorldCtx, index: number, padId: string)
	local model = getPad(w, index, padId)
	if model == nil or model:GetAttribute("PressedAt") ~= nil then
		return
	end
	model:SetAttribute("PressedAt", Workspace:GetServerTimeNow())
	local trigger = model:FindFirstChild("Trigger")
	if trigger ~= nil and trigger:IsA("BasePart") then
		trigger.CanTouch = false
	end
	task.delay(PlotBuilder.PadPressSeconds, function()
		model:Destroy()
	end)
end

--------------------------------------------------------------------------------------------------
-- Locked slots
--------------------------------------------------------------------------------------------------

-- Spawns one locked-slot placeholder's meshes (yields) and puts its sign label on the "Sign"
-- piece (HubLayout.surfaces.Plot_LockedSlot), or on an invisible face at `lockedSlot.sign`.
local function buildLockedMeshes(state: PlotState, area: number, model: Model, lockedSlot: any)
	local slot = WorldLayout.slotOrigin(state.index, area, state.world.id)
	local keys: { string } = {}
	for _, entry in lockedSlot.models or {} do
		if type(entry) == "table" and type(entry.key) == "string" then
			table.insert(keys, entry.key)
		end
	end
	MeshLibrary.preload(keys)
	local signPiece: BasePart? = nil
	for index, entry in lockedSlot.models or {} do
		if model.Parent == nil then
			return -- unlocked meanwhile
		end
		if
			type(entry) ~= "table"
			or type(entry.key) ~= "string"
			or typeof(entry.cf) ~= "CFrame"
			or not MeshLibrary.has(entry.key)
		then
			continue
		end
		local spawned = MeshLibrary.spawn(entry.key, model, slot * entry.cf, {
			name = if type(entry.name) == "string" then entry.name else `{entry.key}_{index}`,
			castShadow = if type(entry.castShadow) == "boolean" then entry.castShadow else nil,
		})
		local piece = spawned:FindFirstChild("Sign")
		if signPiece == nil and piece ~= nil and piece:IsA("BasePart") then
			signPiece = piece
		end
	end
	if model.Parent == nil then
		return
	end
	if signPiece == nil and typeof(lockedSlot.sign) == "CFrame" then
		local face = Instance.new("Part")
		face.Name = "SignFace"
		face.Anchored = true
		face.CanCollide = false
		face.CanQuery = false
		face.CanTouch = false
		face.Transparency = 1
		face.Size = Vector3.new(13.5, 4.5, 0.2)
		face.CFrame = slot * lockedSlot.sign
		face.Parent = model
		signPiece = face
	end
	local entry = state.lockedLabels[area]
	if signPiece ~= nil and entry ~= nil then
		entry.label = faceLabel(signPiece, Enum.NormalId.Front, entry.text)
	end
end

--[[
	Shows HubLayout's locked-slot placeholder on every area slot the plot has not unlocked (all ten
	on a free plot), removes it where the area is open, and keeps each sign current: the next area
	to open reads "x / y purchases" (progress of the area before it), the others "COMING SOON".
	Collision is built at once; meshes stream in. No-op when HubLayout has no `lockedSlot`.
	@param index number
	@param tycoon TycoonState? — nil = free plot (every slot locked)
]]
syncLocked = function(w: WorldCtx, index: number, tycoon: TycoonState?)
	local hub = hubOf(w)
	local lockedSlot = if hub ~= nil then hub.lockedSlot else nil
	if type(lockedSlot) ~= "table" then
		return
	end
	local state = stateOf(w, index)
	local logic = w.logic
	local lockedFolder = state.model:FindFirstChild("Locked")
	if lockedFolder == nil then
		local created = Instance.new("Folder")
		created.Name = "Locked"
		created.Parent = state.model
		lockedFolder = created
	end
	for area = 1, #w.economy.Areas do
		local unlocked = tycoon ~= nil and logic.areaUnlocked(tycoon, area)
		local existing = state.locked[area]
		if unlocked then
			if existing ~= nil then
				existing:Destroy()
				state.locked[area] = nil
				state.lockedLabels[area] = nil
			end
			continue
		end
		local text = "COMING SOON"
		if tycoon ~= nil and area == tycoon.area + 1 then
			local bought, total = logic.areaProgress(tycoon, area - 1)
			text = `COMING SOON\n{bought} / {total} purchases`
		end
		if existing == nil then
			local slot = WorldLayout.slotOrigin(index, area, w.id)
			local model = Instance.new("Model")
			model.Name = string.format("Locked%02d", area)
			model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
			model:SetAttribute("LockedArea", area) -- not "AreaIndex": clear() keeps locked slots
			for _, box in lockedSlot.collision or {} do
				if type(box) == "table" and typeof(box.size) == "Vector3" and typeof(box.cf) == "CFrame" then
					collisionPart(box.size, slot * box.cf).Parent = model
				end
			end
			model.WorldPivot = slot
			model.Parent = lockedFolder
			state.locked[area] = model
			state.lockedLabels[area] = { text = text, label = nil }
			task.spawn(buildLockedMeshes, state, area, model, lockedSlot)
		else
			local entry = state.lockedLabels[area]
			if entry ~= nil and entry.text ~= text then
				entry.text = text
				if entry.label ~= nil then
					entry.label.Text = text
				end
			end
		end
	end
end

--------------------------------------------------------------------------------------------------
-- Restore / purchase / clear
--------------------------------------------------------------------------------------------------

-- Mesh keys one unlocked area places on restore: its base + the builds of OWNED pads, in buy order.
local function ownedMeshKeys(w: WorldCtx, areaIndex: number, tycoon: TycoonState): { string }
	local layout = AreaLayouts.get(areaIndex, w.id)
	local keys: { string } = {}
	local seen: { [string]: boolean } = {}
	local function collect(entry: BuildEntry?)
		for _, model in if entry ~= nil then entry.models else {} do
			local key = model.key
			if key ~= nil and not seen[key] then
				seen[key] = true
				table.insert(keys, key)
			end
		end
	end
	collect(layout.base)
	for _, pad in w.economy.AreaPads[areaIndex] do
		if w.logic.ownsPad(tycoon, pad.id) and not LayoutLogic.opensArea(pad) then
			collect(layout.builds[pad.build])
		end
	end
	return keys
end

--[[
	Rebuilds a plot instantly from a saved tycoon state: every unlocked area's base, every bought
	pad's build, every built producer's anchor. NO BuildIn attributes (clients show it finished).
	Pads are not created here (TycoonService.syncPads after it has published producer stats).
	Yields while meshes load (preloads every needed key first, in parallel).
	@param index number
	@param tycoon TycoonState
	@return boolean — false when the plot was cleared while restoring (caller should stop)
]]
local function restore(w: WorldCtx, index: number, tycoon: TycoonState): boolean
	local state = stateOf(w, index)
	local logic = w.logic
	local economy = w.economy
	local generation = state.generation
	state.model:SetAttribute("PlotReady", false)
	-- Owner rule R16 (W1 benchmark: a full plot took 13.7 s because each area's preload only
	-- started once the previous area had finished, leaving the request slots idle at every area
	-- boundary). Queue EVERY owned area's meshes up front, without yielding: area 1 (the plot
	-- entrance) and the owner's current area (highest unlocked, where they keep building) at Hub
	-- priority, the areas in between at Plot priority in area order. The loop below is unchanged
	-- and only waits for what its area still needs, so build order and visibility stay the same.
	local currentArea = 1
	for areaIndex = 1, #economy.Areas do
		if logic.areaUnlocked(tycoon, areaIndex) then
			currentArea = areaIndex
		end
	end
	for _, areaIndex in if currentArea == 1 then { 1 } else { 1, currentArea } do
		if logic.areaUnlocked(tycoon, areaIndex) then
			MeshLibrary.prefetch(ownedMeshKeys(w, areaIndex, tycoon), MeshLibrary.Priority.Hub)
		end
	end
	for areaIndex = 2, currentArea - 1 do
		if logic.areaUnlocked(tycoon, areaIndex) then
			MeshLibrary.prefetch(ownedMeshKeys(w, areaIndex, tycoon), MeshLibrary.Priority.Plot)
		end
	end
	-- Owner rule R16 / B4: area by area (area 1 first), preload only what is built there (the base +
	-- the OWNED builds, never unbought or locked content) at Plot priority, then place it, so the
	-- nearest areas appear first and nothing waits on far content.
	for areaIndex = 1, #economy.Areas do
		if not logic.areaUnlocked(tycoon, areaIndex) then
			continue
		end
		MeshLibrary.preload(ownedMeshKeys(w, areaIndex, tycoon), MeshLibrary.Priority.Plot)
		if state.generation ~= generation then
			return false
		end
		buildAreaBase(state, areaIndex, nil)
		for _, pad in economy.AreaPads[areaIndex] do
			if logic.ownsPad(tycoon, pad.id) then
				buildPadBuild(state, pad, nil)
			end
		end
		local producer = economy.Areas[areaIndex].producer
		if logic.levelOf(tycoon, producer.id) >= 1 then
			ensureProducer(w, index, producer.id)
		end
		if state.generation ~= generation then
			return false
		end
	end
	syncLocked(w, index, tycoon)
	if state.generation ~= generation then
		return false
	end
	-- Every bought build is placed: the loading screen (B15) / reveal can show the plot.
	state.model:SetAttribute("PlotReady", true)
	return true
end

--[[
	Builds what a just-bought pad adds, with BuildIn (async: returns immediately):
	the pad's build key; for a builder pad the producer anchor (synchronously, so attributes can
	be published at once); for an Unlock pad the next area's base.
	@param index number
	@param padId string — already applied to the state
	@param buyer Player
]]
local function buildPurchase(w: WorldCtx, index: number, padId: string, buyer: Player)
	local state = stateOf(w, index)
	local pad = w.economy.PadsById[padId]
	if pad == nil then
		return
	end
	local producerId = w.economy.ProducerBuiltBy[padId]
	if producerId ~= nil then
		ensureProducer(w, index, producerId)
	end
	task.spawn(function()
		buildPadBuild(state, pad, buyer)
		local opens = pad.unlocks
		if opens ~= nil then
			MeshLibrary.preload(AreaLayouts.meshKeys(opens, w.id))
			buildAreaBase(state, opens, buyer)
		end
	end)
end

--[[
	Removes everything a player built on a plot (areas, pads, producers) and invalidates in-flight
	builds. Keeps the empty plot shell. Used on leave, rebirth and admin resets.
	@param index number
]]
local function clear(w: WorldCtx, index: number)
	local state = stateOf(w, index)
	state.generation += 1
	for _, child in state.model:GetChildren() do
		if child:IsA("Model") and child:GetAttribute("AreaIndex") ~= nil then
			child:Destroy()
		end
	end
	state.model:SetAttribute("StandName", "")
	state.model:SetAttribute("PlotReady", false)
	syncLocked(w, index, nil)
end

--[[ World CFrame (ground level) where the plot's owner arrives / respawns: HubLayout's entrance. ]]
local function entrance(w: WorldCtx, index: number): CFrame
	return stateOf(w, index).entrance
end

--[[
	World CFrame a teleport to an area lands on (layout spawn point, facing the area), at ground
	level; the caller lifts the character by its hip height.
	@param index number, areaIndex number
	@return CFrame
]]
local function areaSpawn(w: WorldCtx, index: number, areaIndex: number): CFrame
	local layout = AreaLayouts.get(areaIndex, w.id)
	local slot = WorldLayout.slotOrigin(index, areaIndex, w.id)
	local at = slot * layout.spawnPoint
	local look = slot * Vector3.new(layout.spawnPoint.X, 0, layout.spawnPoint.Z + 10)
	return CFrame.lookAt(at, Vector3.new(look.X, at.Y, look.Z))
end

--[[
	Shows the (already filtered) stand name: plot attribute StandName (clients may render it) and
	the name painted on both faces of the Nuke Stand's Neon Sign panel (AreaLayouts `standSign`)
	when that build exists; a BillboardGui above the build only if the layout has no panel.
	@param index number
	@param text string — filtered text ("" = default sign)
]]
local function setStandName(w: WorldCtx, index: number, text: string)
	local state = stateOf(w, index)
	state.model:SetAttribute("StandName", text)
	local featurePad = w.economy.FeaturePadOf.StandRename
	local pad = if featurePad ~= nil then w.economy.PadsById[featurePad] else nil
	if pad == nil then
		return
	end
	local area = state.model:FindFirstChild(string.format("Area%02d", pad.area))
	local builds = if area ~= nil then area:FindFirstChild("Builds") else nil
	local build = if builds ~= nil then builds:FindFirstChild(pad.build) else nil
	if build == nil or not build:IsA("Model") then
		return
	end
	local shown = if text ~= "" then text else STAND_DEFAULT_NAME
	local holder = build:FindFirstChild("StandSign")
	if holder == nil then
		local signFolder = Instance.new("Folder")
		signFolder.Name = "StandSign"
		-- World-QA A2-1 (2026-10-30): the name used to float above the sign as a BillboardGui
		-- while the board stayed blank. The area layout gives the board's two display faces
		-- (`standSign`, owner R17: double-sided), so the name is painted ON the panel: one thin
		-- invisible part per face with a SurfaceGui on its Front (primitives: no FBX yaw).
		local layout = AreaLayouts.get(pad.area, w.id) :: any
		local panel = if type(layout) == "table" then layout.standSign else nil
		local slot = WorldLayout.slotOrigin(index, pad.area, w.id)
		local painted = false
		if type(panel) == "table" and typeof(panel.size) == "Vector3" then
			local faces: { [string]: any } = { Front = panel.cf, Back = panel.backCf }
			for name, cf in faces do
				if typeof(cf) == "CFrame" then
					local part = Instance.new("Part")
					part.Name = `StandSign{name}`
					part.Anchored = true
					part.CanCollide = false
					part.CanQuery = false
					part.CanTouch = false
					part.CastShadow = false
					part.Transparency = 1
					part.Size = panel.size
					part.CFrame = slot * cf
					local label = faceLabel(part, Enum.NormalId.Front, shown)
					label.TextColor3 = STAND_NAME_COLOR
					part.Parent = signFolder
					painted = true
				end
			end
		end
		if not painted then
			-- Layout without a `standSign` panel: the name floats above the build instead.
			local cf, size = build:GetBoundingBox()
			local part = Instance.new("Part")
			part.Name = "StandSignFloat"
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Transparency = 1
			part.Size = Vector3.new(1, 1, 1)
			part.CFrame = cf * CFrame.new(0, size.Y / 2 + 2, 0)
			local gui = Instance.new("BillboardGui")
			gui.Name = "Name"
			gui.Size = UDim2.fromScale(14, 3)
			gui.MaxDistance = 140
			gui.AlwaysOnTop = false
			local label = Instance.new("TextLabel")
			label.Name = "Text"
			label.BackgroundTransparency = 1
			label.Size = UDim2.fromScale(1, 1)
			label.Font = Enum.Font.FredokaOne
			label.TextScaled = true
			label.TextColor3 = STAND_NAME_COLOR
			label.TextStrokeTransparency = 0
			label.Parent = gui
			gui.Parent = part
			part.Parent = signFolder
		end
		signFolder.Parent = build
		holder = signFolder
	end
	for _, descendant in (holder :: Instance):GetDescendants() do
		if descendant:IsA("TextLabel") and descendant.Name == "Text" then
			descendant.Text = shown
		end
	end
end

--------------------------------------------------------------------------------------------------
-- Per-world builders (R57, plan §3.3)
--------------------------------------------------------------------------------------------------

--[[
	One world's plot builder: the full function set, bound to that world (economy, layouts, frames,
	plots tree). Same signatures and behaviour as the module-level functions documented above.
]]
export type WorldPlotBuilder = {
	worldId: string,
	createPlots: () -> { Model },
	getPlot: (index: number) -> Model,
	setOwner: (index: number, owner: Player?) -> (),
	setSignLabel: (index: number, text: string) -> (),
	setPlotName: (index: number, text: string) -> (), -- owner R88 (filtered text; "" = default)
	ensureProducer: (index: number, producerId: string) -> BasePart,
	getProducerAnchor: (index: number, producerId: string) -> BasePart?,
	getPad: (index: number, padId: string) -> Model?,
	padPosition: (index: number, padId: string) -> Vector3?,
	syncPads: (index: number, pads: { PadConfig }) -> (),
	pressPad: (index: number, padId: string) -> (),
	syncLocked: (index: number, tycoon: TycoonState?) -> (),
	restore: (index: number, tycoon: TycoonState) -> boolean,
	buildPurchase: (index: number, padId: string, buyer: Player) -> (),
	clear: (index: number) -> (),
	entrance: (index: number) -> CFrame,
	areaSpawn: (index: number, areaIndex: number) -> CFrame,
	setStandName: (index: number, text: string) -> (),
	hasPlots: () -> boolean,
}

-- Built builders per world id (frozen; closures over the world's context).
local builders: { [string]: WorldPlotBuilder } = {}

-- Binds every builder function to one world's context.
local function bind(w: WorldCtx): WorldPlotBuilder
	local builder: WorldPlotBuilder = {
		worldId = w.id,
		createPlots = function(): { Model }
			return createPlots(w)
		end,
		getPlot = function(index: number): Model
			return getPlot(w, index)
		end,
		setOwner = function(index: number, owner: Player?)
			setOwner(w, index, owner)
		end,
		setSignLabel = function(index: number, text: string)
			setSignLabel(w, index, text)
		end,
		setPlotName = function(index: number, text: string)
			setPlotName(w, index, text)
		end,
		ensureProducer = function(index: number, producerId: string): BasePart
			return ensureProducer(w, index, producerId)
		end,
		getProducerAnchor = function(index: number, producerId: string): BasePart?
			return getProducerAnchor(w, index, producerId)
		end,
		getPad = function(index: number, padId: string): Model?
			return getPad(w, index, padId)
		end,
		padPosition = function(index: number, padId: string): Vector3?
			return padPosition(w, index, padId)
		end,
		syncPads = function(index: number, pads: { PadConfig })
			syncPads(w, index, pads)
		end,
		pressPad = function(index: number, padId: string)
			pressPad(w, index, padId)
		end,
		syncLocked = function(index: number, tycoon: TycoonState?)
			syncLocked(w, index, tycoon)
		end,
		restore = function(index: number, tycoon: TycoonState): boolean
			return restore(w, index, tycoon)
		end,
		buildPurchase = function(index: number, padId: string, buyer: Player)
			buildPurchase(w, index, padId, buyer)
		end,
		clear = function(index: number)
			clear(w, index)
		end,
		entrance = function(index: number): CFrame
			return entrance(w, index)
		end,
		areaSpawn = function(index: number, areaIndex: number): CFrame
			return areaSpawn(w, index, areaIndex)
		end,
		setStandName = function(index: number, text: string)
			setStandName(w, index, text)
		end,
		-- True once this world's 8 plots exist (createPlots / createWorldPlots ran).
		hasPlots = function(): boolean
			return w.folder ~= nil
		end,
	}
	-- Frozen: a shared builder must never be patched by a caller (the cast keeps the plain record type).
	return (table.freeze(builder) :: any) :: WorldPlotBuilder
end

--[[
	The plot builder of a world (cached). Errors for an unknown world id (programming bug).
	@param worldId string — "main", "dino", ...
	@return WorldPlotBuilder
	Example: PlotBuilder.world("dino").entrance(3) --> the entrance of Valley plot 3
]]
function PlotBuilder.world(worldId: string): WorldPlotBuilder
	local cached = builders[worldId]
	if cached ~= nil then
		return cached
	end
	local w = ctxOf(worldId)
	local builder = bind(w)
	builders[w.id] = builder
	return builder
end

--[[
	Builds the 8 empty plot frames of a NON-main world at boot (idempotent): ground, road, entrance
	arch + owner sign, locked slots. Static and streamed, like Nuke Town's.
	@param worldId string
	@return {Model}
]]
function PlotBuilder.createWorldPlots(worldId: string): { Model }
	assert(worldId ~= WorldsConfig.MAIN, "PlotBuilder.createWorldPlots: Nuke Town uses createPlots")
	return PlotBuilder.world(worldId).createPlots()
end

-- The module-level API is Nuke Town's builder (every existing caller is unchanged).
local MAIN_BUILDER = PlotBuilder.world(WorldsConfig.MAIN)
PlotBuilder.createPlots = MAIN_BUILDER.createPlots
PlotBuilder.getPlot = MAIN_BUILDER.getPlot
PlotBuilder.setOwner = MAIN_BUILDER.setOwner
PlotBuilder.setSignLabel = MAIN_BUILDER.setSignLabel
PlotBuilder.setPlotName = MAIN_BUILDER.setPlotName
PlotBuilder.ensureProducer = MAIN_BUILDER.ensureProducer
PlotBuilder.getProducerAnchor = MAIN_BUILDER.getProducerAnchor
PlotBuilder.getPad = MAIN_BUILDER.getPad
PlotBuilder.padPosition = MAIN_BUILDER.padPosition
PlotBuilder.syncPads = MAIN_BUILDER.syncPads
PlotBuilder.pressPad = MAIN_BUILDER.pressPad
PlotBuilder.syncLocked = MAIN_BUILDER.syncLocked
PlotBuilder.restore = MAIN_BUILDER.restore
PlotBuilder.buildPurchase = MAIN_BUILDER.buildPurchase
PlotBuilder.clear = MAIN_BUILDER.clear
PlotBuilder.entrance = MAIN_BUILDER.entrance
PlotBuilder.areaSpawn = MAIN_BUILDER.areaSpawn
PlotBuilder.setStandName = MAIN_BUILDER.setStandName

return PlotBuilder
