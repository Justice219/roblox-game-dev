--!strict
--[[
	EggStands — the egg-stand eggs and the crate-stall crates in the hub (server side): one display
	egg per stand, its ProximityPrompt, the stall's display crates + prompt, and the authoritative
	stand positions the HatchEgg range check uses.

	Placement (HubLayout, B8e — via PetSeams.hubAnchors()):
		EggStands[area]  { area, model, cf, egg, prompt, tint }: B8e's HubBuilder already builds the
		                 stand mesh ("Hub_EggStand_<n>" in Workspace.Hub.Art, with a Sign face for
		                 the name + price). Here: the egg's Blender mesh at `egg` (bottom-centre pivot
		                 on the cradle) and the prompt at `prompt` (the interaction point in front).
		HarvestEggStand  the same shape, but the stand mesh exists only while the Harvest Feast runs
		                 (B11 EventDecor builds it in Workspace.HarvestFeastSquare), so the Harvest egg
		                 + prompt are built / removed with EventService.ActiveChanged.
		CrateStall       { model, cf, display, prompt }: the three crates on the counter around
		                 `display`, the prompt at `prompt`.
		World eggs       (owner R57 World 2) an egg whose `world` is not Nuke Town stands on its
		                 world's hub layout ("dino:EggStands1" → Worlds/Dino/ValleyLayout
		                 anchors.EggStands[1], W9's nest stands). Those anchors are WORLD-LOCAL:
		                 egg / prompt are placed with WorldLayout.toWorld(world, cf), so positionOf()
		                 and the HatchEgg range check measure in world space at Base Camp.
	Without HubLayout (Studio tests / an older place) a FALLBACK ring around the hub spawn with
	small stud pedestals is built, so the stands are always usable and positionOf() always answers.
	A world without its layout anchors yet gets the same ring around that world's origin.

	Instances (Workspace.PetStands, every model ModelStreamingMode Persistent so every client has the
	prompts + billboards):
		Stand_<eggId>  Model: "DisplayEgg" (the egg mesh via MeshLibrary, else a stud ellipsoid in the
		               egg's colours), "PromptPoint" (invisible anchor part with the ProximityPrompt,
		               attribute EggId; E / ButtonX / tap). Attributes EggId, StandName, HubModel
		               (the B8e stand mesh name, so the client can dress its Sign face),
		               BillboardHeight (odds billboard height above the egg pivot), WorldId (the
		               world whose hub holds the stand: "main" / "dino").
		CrateStall     Model: three display crates + "PromptPoint" (attribute CrateStall = true).
	The client (Pets/StandClient) adds the stud-UI odds billboards / sign text and the idle bob,
	and opens the EggHatch / CrateShop screens on the prompts. The server never handles
	PromptTriggered: hatching is the HatchEgg remote, which re-checks the distance here.
	Nothing runs per frame.

	Connects to: Shared/Config/{EggConfig, CrateConfig}, Server/Pets/PetSeams (HubLayout anchors,
	MeshLibrary, event hook), Server/World/WorldMaterials (stud material), Server/Services/PetService
	(build + isNear), Client/Pets/StandClient.

	Example:
		EggStands.build()
		local nearby = EggStands.isNear(player, "garage_egg", EggConfig.StandRange)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local CrateConfig = require(ReplicatedStorage.Shared.Config.CrateConfig)
local EggConfig = require(ReplicatedStorage.Shared.Config.EggConfig)
local MeshPlacement = require(ReplicatedStorage.Shared.World.MeshPlacement)
local PetSeams = require(script.Parent.PetSeams)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)
local WorldMaterials = require(ServerScriptService.Server.World.WorldMaterials)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local EggStands = {}

-- The client's odds billboard sits this high above the egg pivot: above B8e's stand Sign (centre
-- cf * (0, 11.4, 2.72), egg = cf * (0, 4, 0)) on hub stands; just above the egg on fallbacks.
local BILLBOARD_HEIGHT_HUB = 13
local BILLBOARD_HEIGHT_FALLBACK = 9.2
-- Fallback layout: the egg floats this high above the pedestal anchor (studs).
local FALLBACK_EGG_HEIGHT = 4.2
-- Display egg size of the stud-ellipsoid stand-in (studs).
local EGG_SIZE = Vector3.new(3.2, 4, 3.2)
-- Prompt reach (studs); the server's range check is EggConfig.StandRange (wider).
local PROMPT_DISTANCE = 11
-- Fallback layout: stands on an arc of this radius around the hub origin.
local FALLBACK_RADIUS = 58
-- Display crates on the stall counter are spread this far apart (studs, along the stall).
local CRATE_SPACING = 3.4
local FOLDER_NAME = "PetStands"

-- eggId → the egg's world position (range checks) ; eggId → its stand model.
local positions: { [string]: Vector3 } = {}
local standModels: { [string]: Model } = {}
local folder: Folder? = nil
local built = false

-- Fallback anchor for stand number `index` of `count` (an arc facing the spawn at the origin).
local function fallbackCf(index: number, count: number): CFrame
	local spread = math.rad(150)
	local angle = -spread / 2 + spread * (index - 1) / math.max(1, count - 1)
	local position = Vector3.new(math.sin(angle) * FALLBACK_RADIUS, 0, -math.cos(angle) * FALLBACK_RADIUS)
	return CFrame.lookAt(position, Vector3.zero)
end

-- A stud-textured anchored visual part (never collides / queries; collision is the hub's job).
local function visual(name: string, size: Vector3, cf: CFrame, color: Color3, parent: Instance, material: string?): Part
	-- Owner R19 glow budget: a big Neon face renders as a brightened Smooth instead (no bloom).
	local resolvedMaterial, resolvedColor = MeshPlacement.resolveGlow(material or "StudsSmall", size, color)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Color = resolvedColor
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	WorldMaterials.apply(part, resolvedMaterial)
	part.Parent = parent
	return part
end

-- A small stud pedestal with collision (fallback layout only).
local function pedestal(model: Model, cf: CFrame, color: Color3)
	visual(
		"PedestalBase",
		Vector3.new(6, 1.2, 6),
		cf * CFrame.new(0, 0.6, 0),
		Color3.fromRGB(70, 76, 92),
		model,
		"Studs"
	)
	visual("PedestalTop", Vector3.new(4.4, 2.4, 4.4), cf * CFrame.new(0, 2.4, 0), color, model, "Studs")
	local collider = Instance.new("Part")
	collider.Name = "Collider"
	collider.Size = Vector3.new(6, 3.6, 6)
	collider.CFrame = cf * CFrame.new(0, 1.8, 0)
	collider.Transparency = 1
	collider.Anchored = true
	collider.CanQuery = false
	collider.CanTouch = false
	collider.Parent = model
end

-- Spawns a MeshLibrary model (nil when the key is unknown or the spawn failed).
local function spawnMesh(key: string, parent: Instance, cf: CFrame, name: string, colors: { [string]: Color3 }?): Model?
	local meshLibrary = PetSeams.meshLibrary()
	if meshLibrary == nil or not meshLibrary.has(key) then
		return nil
	end
	local ok, spawned = pcall(meshLibrary.spawn, key, parent, cf, { name = name, colors = colors })
	if ok and typeof(spawned) == "Instance" and spawned:IsA("Model") then
		return spawned
	end
	return nil
end

-- The display egg "DisplayEgg" with its bottom-centre pivot at `cf`.
local function displayEgg(model: Model, egg: EggConfig.EggDef, cf: CFrame)
	if spawnMesh(egg.model, model, cf, "DisplayEgg", egg.colors) ~= nil then
		return
	end
	-- Stand-in: a stud ellipsoid with a glowing band (one model so the client bobs it as one).
	local group = Instance.new("Model")
	group.Name = "DisplayEgg"
	local shell = visual("Shell", EGG_SIZE, cf * CFrame.new(0, EGG_SIZE.Y / 2, 0), egg.shell, group)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = shell
	local band = visual(
		"Band",
		Vector3.new(EGG_SIZE.X * 1.02, 0.45, EGG_SIZE.Z * 1.02),
		shell.CFrame * CFrame.new(0, 0.2, 0),
		egg.spots,
		group,
		"Neon"
	)
	local bandMesh = Instance.new("SpecialMesh")
	bandMesh.MeshType = Enum.MeshType.Sphere
	bandMesh.Parent = band
	group.PrimaryPart = shell
	group.Parent = model
end

-- An invisible anchor part at `cf` carrying the ProximityPrompt (the model's PrimaryPart).
local function addPrompt(
	model: Model,
	cf: CFrame,
	actionText: string,
	objectText: string,
	attribute: string,
	value: any
)
	local point = Instance.new("Part")
	point.Name = "PromptPoint"
	point.Size = Vector3.new(1, 1, 1)
	point.CFrame = cf
	point.Transparency = 1
	point.Anchored = true
	point.CanCollide = false
	point.CanQuery = false
	point.CanTouch = false
	point.Parent = model
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "PetPrompt"
	prompt.ActionText = actionText
	prompt.ObjectText = objectText
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.Style = Enum.ProximityPromptStyle.Default
	prompt:SetAttribute(attribute, value)
	prompt.Parent = point
	model.PrimaryPart = point
end

-- Builds one egg stand. `anchor` = HubLayout EggStandAnchor, or nil for the fallback slot.
local function buildStand(
	parent: Folder,
	egg: EggConfig.EggDef,
	anchor: any,
	fallbackIndex: number,
	fallbackCount: number
)
	local model = Instance.new("Model")
	model.Name = `Stand_{egg.id}`
	model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	model:SetAttribute("EggId", egg.id)
	model:SetAttribute("StandName", egg.stand)
	model:SetAttribute("WorldId", egg.world)
	local eggCf: CFrame
	local promptCf: CFrame
	if type(anchor) == "table" and typeof(anchor.pedestal) == "CFrame" then
		-- A world's fallback slot (its layout has no anchor yet): pedestal + egg + prompt given.
		pedestal(model, anchor.pedestal, egg.shell)
		model:SetAttribute("BillboardHeight", BILLBOARD_HEIGHT_FALLBACK)
		eggCf, promptCf = anchor.egg, anchor.prompt
	elseif type(anchor) == "table" and typeof(anchor.egg) == "CFrame" and typeof(anchor.prompt) == "CFrame" then
		eggCf, promptCf = anchor.egg, anchor.prompt
		if type(anchor.model) == "string" then
			model:SetAttribute("HubModel", anchor.model)
		end
		model:SetAttribute("BillboardHeight", BILLBOARD_HEIGHT_HUB)
	else
		local base = fallbackCf(fallbackIndex, fallbackCount)
		pedestal(model, base, egg.shell)
		model:SetAttribute("BillboardHeight", BILLBOARD_HEIGHT_FALLBACK)
		eggCf = base * CFrame.new(0, FALLBACK_EGG_HEIGHT, 0)
		promptCf = base * CFrame.new(0, 3, -4)
	end
	displayEgg(model, egg, eggCf)
	addPrompt(model, promptCf, "Hatch", egg.name, "EggId", egg.id)
	model.Parent = parent
	positions[egg.id] = eggCf.Position
	standModels[egg.id] = model
end

--[[
	A world egg's stand anchor in WORLD space: the world hub layout's EggStandAnchor (world-local
	egg / prompt CFrames) moved by WorldLayout.toWorld, or nil when the layout / anchor is not
	there yet (the caller builds the fallback ring around the world origin instead).
]]
local function worldAnchor(egg: EggConfig.EggDef): any
	local worldId, list, index = EggConfig.parseStand(egg.stand)
	if worldId == nil or list == nil or index == nil then
		return nil
	end
	local anchors = PetSeams.worldHubAnchors(worldId)
	local entries = if type(anchors) == "table" then anchors[list] else nil
	local anchor = if type(entries) == "table" then entries[index] else nil
	if type(anchor) ~= "table" or typeof(anchor.egg) ~= "CFrame" or typeof(anchor.prompt) ~= "CFrame" then
		return nil
	end
	return {
		model = anchor.model,
		egg = WorldLayout.toWorld(worldId, anchor.egg),
		prompt = WorldLayout.toWorld(worldId, anchor.prompt),
	}
end

--[[
	Builds the stand of a world egg (R57): its world's layout anchor, else a fallback slot on a
	ring around that world's origin (the Base Camp centre) so the stand works before the art lands.
]]
local function buildWorldStand(parent: Folder, egg: EggConfig.EggDef, fallbackIndex: number)
	local anchor = worldAnchor(egg)
	if anchor ~= nil then
		buildStand(parent, egg, anchor, fallbackIndex, 12)
		return
	end
	local base = WorldLayout.toWorld(egg.world, fallbackCf(fallbackIndex, 12))
	buildStand(parent, egg, {
		egg = base * CFrame.new(0, FALLBACK_EGG_HEIGHT, 0),
		prompt = base * CFrame.new(0, 3, -4),
		pedestal = base,
	}, fallbackIndex, 12)
end

-- Removes one egg stand (the Harvest egg after the event).
local function removeStand(eggId: string)
	local model = standModels[eggId]
	if model ~= nil then
		model:Destroy()
	end
	standModels[eggId] = nil
	positions[eggId] = nil
end

-- Builds the crate stall (three display crates + one prompt).
local function buildCrateStall(parent: Folder, anchor: any, fallbackIndex: number, fallbackCount: number)
	local model = Instance.new("Model")
	model.Name = "CrateStall"
	model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	model:SetAttribute("CrateStall", true)
	local displayCf: CFrame
	local promptCf: CFrame
	if type(anchor) == "table" and typeof(anchor.display) == "CFrame" and typeof(anchor.prompt) == "CFrame" then
		displayCf, promptCf = anchor.display, anchor.prompt
		if type(anchor.model) == "string" then
			model:SetAttribute("HubModel", anchor.model)
		end
	else
		local base = fallbackCf(fallbackIndex, fallbackCount)
		visual(
			"Counter",
			Vector3.new(14, 2.6, 4.5),
			base * CFrame.new(0, 1.3, 0),
			Color3.fromRGB(150, 98, 60),
			model,
			"Studs"
		)
		displayCf = base * CFrame.new(0, 2.6, 0)
		promptCf = base * CFrame.new(0, 3, -5)
	end
	for index, crateId in CrateConfig.Order do
		local crate = CrateConfig.Crates[crateId]
		local cf = displayCf * CFrame.new((index - 2) * CRATE_SPACING, 0, 0)
		if spawnMesh(crate.model, model, cf, `Crate_{crateId}`, nil) == nil then
			visual(`Crate_{crateId}`, Vector3.new(3, 2.6, 3), cf * CFrame.new(0, 1.3, 0), crate.color, model)
			visual(`Lid_{crateId}`, Vector3.new(3.3, 0.5, 3.3), cf * CFrame.new(0, 2.8, 0), crate.accent, model)
		end
	end
	addPrompt(model, promptCf, "Open Crates", "Supply Crates", "CrateStall", true)
	model.Parent = parent
end

-- The Harvest egg follows the event (its stand mesh only exists while the event runs).
local function setHarvest(active: boolean)
	local parent = folder
	local egg = EggConfig.get("harvest_egg")
	if parent == nil or egg == nil then
		return
	end
	if not active then
		removeStand(egg.id)
		return
	end
	if standModels[egg.id] ~= nil then
		return
	end
	local anchors = PetSeams.hubAnchors()
	local ok, err = pcall(buildStand, parent, egg, if anchors ~= nil then anchors.HarvestEggStand else nil, 12, 12)
	if not ok then
		warn(`[EggStands] harvest stand failed: {err}`)
	end
end

--[[
	Builds every stand once (idempotent). Missing anchors use the fallback ring. Yields only while
	MeshLibrary loads uploaded meshes.
]]
function EggStands.build()
	if built then
		return
	end
	built = true
	local existing = Workspace:FindFirstChild(FOLDER_NAME)
	if existing ~= nil then
		existing:Destroy()
	end
	local root = Instance.new("Folder")
	root.Name = FOLDER_NAME
	root.Parent = Workspace
	folder = root

	local anchors = PetSeams.hubAnchors()
	local areaStands = if anchors ~= nil and type(anchors.EggStands) == "table" then anchors.EggStands else {}
	local count = 0
	local worldSlots: { [string]: number } = {}
	for _, id in EggConfig.Order do
		local egg = EggConfig.Eggs[id]
		if egg.world == WorldsConfig.MAIN and egg.currency == "cash" then
			count += 1
			local ok, err = pcall(buildStand, root, egg, areaStands[egg.area], count, 12)
			if not ok then
				warn(`[EggStands] stand {egg.id} failed: {err}`)
			end
		elseif egg.world ~= WorldsConfig.MAIN and egg.stand ~= nil then
			-- World eggs (R57): their own world's hub (Dino Valley's Base Camp nest stands).
			worldSlots[egg.world] = (worldSlots[egg.world] or 0) + 1
			local ok, err = pcall(buildWorldStand, root, egg, worldSlots[egg.world])
			if not ok then
				warn(`[EggStands] world stand {egg.id} failed: {err}`)
			end
		end
	end
	local ok, err = pcall(buildCrateStall, root, if anchors ~= nil then anchors.CrateStall else nil, 11, 12)
	if not ok then
		warn(`[EggStands] crate stall failed: {err}`)
	end
	-- The Harvest egg: now if the event already runs, and whenever it starts / ends.
	PetSeams.onEventChanged(setHarvest)
	setHarvest(PetSeams.eventActive() == true)
end

--[[ The egg's world position at its stand (nil: held-only egg / not built / event over). ]]
function EggStands.positionOf(eggId: string): Vector3?
	return positions[eggId]
end

--[[
	True when `player`'s character root is within `range` studs of the egg at the stand of `eggId`.
	Fails closed (no character / no stand → false).
]]
function EggStands.isNear(player: Player, eggId: string, range: number): boolean
	local position = positions[eggId]
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if position == nil or root == nil or not root:IsA("BasePart") then
		return false
	end
	return (root.Position - position).Magnitude <= range
end

return EggStands
