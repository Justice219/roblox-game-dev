--!strict
--[[
	spawn_area10.luau — EDIT-MODE art check for Area 10 "Mega Nuclear Facility": builds the whole area from the
	real layout module (ReplicatedStorage.Shared.Config.AreaLayouts.Area10) through the real
	MeshLibrary + WorldMaterials, far from the play area, so screenshots verify the Blender meshes,
	the layout placements, collision boxes, pads, the producer billboard anchor / click box and the
	spawn point together.

	Run (Studio open in EDIT mode, Rojo synced; hold the studio lock for the whole batch):
		python3 scripts/studio-lock.py acquire B8d
		python3 scripts/studio_mcp.py luau-file tools/blender/studio/spawn_area10.luau
		python3 tools/blender/studio_shot.py docs/verification/world-art/area10-overview.jpg --luau <camera.luau>
		python3 scripts/studio_mcp.py luau 'workspace.SN_ArtPreview_A10:Destroy()'      # ALWAYS:
		python3 scripts/studio_mcp.py luau-file tools/blender/studio/cleanup_preview.luau   # + variant clones
		python3 scripts/studio-lock.py release B8d

	Options (edit the constants below): SHOW_COLLISION draws the invisible collision boxes as
	translucent red blocks; BUILDS = false spawns only the base (what the player sees on unlock).

	The slot origin is placed at ORIGIN (10000, 0, 10000) in its own folder SN_ArtPreview_A10 (shared
	convention: every area preview has its own folder + origin); slot +Z (away from the road) = world +Z, so
	camera files can use slot-local offsets from ORIGIN directly. A strip of road tiles is laid in
	front (slot z -18..-2) for context.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local World = ServerScriptService:WaitForChild("Server"):WaitForChild("World")
local MeshLibrary = (require :: any)(World:WaitForChild("MeshLibrary"))
local WorldMaterials = (require :: any)(World:WaitForChild("WorldMaterials"))
local Layouts = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("AreaLayouts")
local layout = (require :: any)(Layouts:WaitForChild("Area10"))

local ORIGIN = CFrame.new(10000, 0, 10000)
local FOLDER_NAME = "SN_ArtPreview_A10"
local SHOW_COLLISION = false
local BUILDS = true

local old = workspace:FindFirstChild(FOLDER_NAME)
if old then
	old:Destroy()
end
local root = Instance.new("Folder")
root.Name = FOLDER_NAME

local installed = WorldMaterials.ensure()

-- Every mesh key the layout uses (+ context props), preloaded so spawns never yield per model.
local keys: { string } = { "BuyPad", "Tile_Road" }
local seen: { [string]: boolean } = {}
local function addKeys(group: any)
	for _, placement in group.models do
		if not seen[placement.key] then
			seen[placement.key] = true
			table.insert(keys, placement.key)
		end
	end
end
addKeys(layout.base)
for _, group in layout.builds do
	addKeys(group)
end
local started = os.clock()
local ready, failed = MeshLibrary.preload(keys)
local loadSeconds = os.clock() - started

--[[ Spawns one build group (models + optional visible collision boxes) under `parent`. ]]
local function spawnGroup(name: string, group: any, parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	for _, placement in group.models do
		MeshLibrary.spawn(placement.key, folder, ORIGIN * placement.cf, {
			tint = placement.tint,
			castShadow = placement.castShadow,
		})
	end
	if SHOW_COLLISION then
		for _, box in group.collision or {} do
			local part = Instance.new("Part")
			part.Name = "Collision"
			part.Anchored = true
			part.CanCollide = false
			part.Size = box.size
			part.CFrame = ORIGIN * box.cf
			part.Color = Color3.fromRGB(255, 40, 40)
			part.Transparency = 0.6
			part.Material = Enum.Material.SmoothPlastic
			part.Parent = folder
		end
	end
end

spawnGroup("Base", layout.base, root)
if BUILDS then
	for key, group in layout.builds do
		spawnGroup(key, group, root)
	end
end

-- Road strip in front of the slot (context only): 16-stud tiles along slot X at slot z = -10.
for x = -48, 48, 16 do
	MeshLibrary.spawn("Tile_Road", root, ORIGIN * CFrame.new(x, 0, -10) * CFrame.Angles(0, math.rad(90), 0), {
		castShadow = false,
	})
end

-- Buy pads (green tops) at every pad position.
for padId, point in layout.pads do
	MeshLibrary.spawn("BuyPad", root, ORIGIN * CFrame.new(point), {
		tint = Color3.fromRGB(98, 204, 70),
		name = "Pad_" .. padId,
	})
end

-- Producer billboard anchor (yellow ball), click box (translucent blue), spawn point (white disc).
local function marker(
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	transparency: number,
	shape: Enum.PartType
)
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.Shape = shape
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Transparency = transparency
	part.Material = Enum.Material.Neon
	part.Parent = root
end
marker(
	"ProducerAnchor",
	Vector3.new(1.4, 1.4, 1.4),
	ORIGIN * CFrame.new(layout.producer.anchor),
	Color3.fromRGB(255, 220, 40),
	0,
	Enum.PartType.Ball
)
if SHOW_COLLISION then
	marker(
		"ProducerClick",
		layout.producer.click.size,
		ORIGIN * layout.producer.click.cf,
		Color3.fromRGB(60, 140, 255),
		0.85,
		Enum.PartType.Block
	)
end
marker(
	"SpawnPoint",
	Vector3.new(0.2, 3, 3),
	ORIGIN * CFrame.new(layout.spawnPoint) * CFrame.Angles(0, 0, math.rad(90)),
	Color3.fromRGB(255, 255, 255),
	0.3,
	Enum.PartType.Cylinder
)

root.Parent = workspace

local parts, meshes, fallbacks = 0, 0, 0
for _, item in root:GetDescendants() do
	if item:IsA("BasePart") then
		parts += 1
		if item:IsA("MeshPart") then
			meshes += 1
		end
	elseif item:IsA("Model") and item:GetAttribute("MeshSource") == "Fallback" then
		fallbacks += 1
	end
end
return string.format(
	"variants=%s keys=%d preload ready=%d failed=%d in %.2fs; parts=%d meshparts=%d fallbackModels=%d",
	tostring(installed),
	#keys,
	ready,
	failed,
	loadSeconds,
	parts,
	meshes,
	fallbacks
)
