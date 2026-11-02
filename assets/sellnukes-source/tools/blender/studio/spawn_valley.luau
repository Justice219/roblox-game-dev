--!strict
--[[
	spawn_valley.luau — EDIT-MODE art check for Dino Valley (W9 valley-hub-art, owner R57): spawns
	src/shared/Config/Worlds/Dino/ValleyLayout.luau (Base Camp, the Time Machine, pads, nest stands,
	leaderboard, title sign, decor, wedge scenery, cliffs, waterfall, volcano) and the plot frames of
	PLOTS with every slot showing the Valley locked placeholder, through the real MeshLibrary +
	WorldMaterials.

	ValleyLayout is WORLD-LOCAL; the preview puts its origin at PREVIEW_ORIGIN (far from Nuke Town's
	origin, from the Valley's runtime origin (6000, 0, 0) and from the dino-area previews at
	(9000, 0, -9000 - 300 N)), lifted 300 studs so it never touches edit-mode content.

	Run (Studio open, Rojo synced, hold the Studio lock):
		python3 scripts/studio-lock.py acquire W9
		python3 scripts/studio_mcp.py luau-file tools/blender/studio/spawn_valley.luau
		python3 tools/blender/studio_shot.py docs/verification/world2/valley-arrival.jpg --luau tools/blender/studio/camera_valley.luau
		python3 scripts/studio_mcp.py luau-file tools/blender/studio/cleanup_preview.luau   # ALWAYS
		python3 scripts/studio-lock.py release W9
	cleanup_preview.luau removes the SN_ArtPreview folder and the edit-mode MaterialVariant clones.

	Toggles: PLOTS (which plot frames), SHOW_COLLISION (translucent red boxes for every collider).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local World = ServerScriptService:WaitForChild("Server"):WaitForChild("World")
local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")

--[[
	Fresh module copies (pattern from spawn_dino_area01.luau / spawn_area06.luau). Edit-mode
	`require` caches each ModuleScript instance for the lifetime of the plugin VM, so after
	`sync_meshes.py` the cached MeshAssets (and the MeshLibrary that captured it) miss new keys
	("unknown model key"). MeshAssets, WorldMaterials (+ its variant templates) and MeshLibrary are
	cloned into a temporary ServerStorage sandbox (not Rojo-managed), the MeshLibrary clone points at
	the sibling MeshAssets clone, and the layout is required from a fresh clone. Nothing Rojo owns is
	modified; the sandbox is destroyed at the end.
]]
local sandbox = Instance.new("Folder")
sandbox.Name = "SN_PreviewModules_Valley"
local oldSandbox = game:GetService("ServerStorage"):FindFirstChild(sandbox.Name)
if oldSandbox then
	oldSandbox:Destroy()
end
sandbox.Parent = game:GetService("ServerStorage")
Config:WaitForChild("MeshAssets"):Clone().Parent = sandbox
local worldMaterialsCopy = World:WaitForChild("WorldMaterials"):Clone()
worldMaterialsCopy.Parent = sandbox
World:WaitForChild("StudMaterialVariants"):Clone().Parent = sandbox
local meshLibraryCopy: any = World:WaitForChild("MeshLibrary"):Clone()
local patched, replaced = string.gsub(
	meshLibraryCopy.Source,
	"require%(ReplicatedStorage%.Shared%.Config%.MeshAssets%)",
	"require(script.Parent.MeshAssets)"
)
assert(replaced == 1, "MeshLibrary no longer requires MeshAssets by its absolute path; update this preview script")
meshLibraryCopy.Source = patched
meshLibraryCopy.Parent = sandbox
local MeshLibrary = (require :: any)(meshLibraryCopy)
local WorldMaterials = (require :: any)(worldMaterialsCopy)
-- ValleyLayout has no requires, so a clone loads standalone (and is always the freshly synced copy).
local ValleyLayout = (require :: any)(
	Config:WaitForChild("Worlds"):WaitForChild("Dino"):WaitForChild("ValleyLayout"):Clone()
)

-- Dino plot geometry (WorldGeometry "dino": 6 areas; WorldLayout.slotLocal's formula, inlined so a
-- stale cached WorldLayout can never misplace the preview).
local AREA_COUNT = 6
local function slotLocal(area: number): CFrame
	local zCentre = (math.ceil(area / 2) - 0.5) * 104
	if area % 2 == 1 then
		return CFrame.new(-10, 0, zCentre) * CFrame.Angles(0, -math.pi / 2, 0)
	end
	return CFrame.new(10, 0, zCentre) * CFrame.Angles(0, math.pi / 2, 0)
end

local PREVIEW_ORIGIN = CFrame.new(-9000, 300, 9000)
local FOLDER_NAME = "SN_ArtPreview"
local PLOTS = { 1, 2, 8 }
local SHOW_COLLISION = false

local old = workspace:FindFirstChild(FOLDER_NAME)
if old then
	old:Destroy()
end
local root = Instance.new("Folder")
root.Name = FOLDER_NAME

local installed = WorldMaterials.ensure()
local started = os.clock()
local ready, failed = MeshLibrary.preload(ValleyLayout.keys())
local loadSeconds = os.clock() - started

-- Spawns one placement list under `parent`, every CFrame pre-multiplied by `base`.
local function spawnList(list: { any }, parent: Instance, base: CFrame, plotTint: Color3?)
	for _, entry in list do
		local tint = entry.tint
		if entry.plotTint and plotTint then
			tint = plotTint
		end
		MeshLibrary.spawn(entry.key, parent, base * entry.cf, {
			tint = tint,
			colors = entry.colors,
			castShadow = entry.castShadow,
			name = entry.name,
		})
	end
end

-- Translucent collider boxes (debug view only).
local function spawnColliders(list: { any }, parent: Instance, base: CFrame)
	if not SHOW_COLLISION then
		return
	end
	for _, box in list do
		local part = Instance.new("Part")
		part.Name = "Collider"
		part.Anchored = true
		part.CanCollide = false
		part.Size = box.size
		part.CFrame = base * box.cf
		part.Color = Color3.fromRGB(255, 40, 40)
		part.Transparency = 0.6
		part.Parent = parent
	end
end

local camp = Instance.new("Folder")
camp.Name = "Valley"
camp.Parent = root
spawnList(ValleyLayout.models, camp, PREVIEW_ORIGIN)
spawnColliders(ValleyLayout.collision, camp, PREVIEW_ORIGIN)

for _, plotIndex in PLOTS do
	local plot = Instance.new("Folder")
	plot.Name = `Plot{plotIndex}`
	plot.Parent = root
	-- World-local plot origin (same ring as Nuke Town), then the preview origin.
	local origin = PREVIEW_ORIGIN * CFrame.Angles(0, (plotIndex - 1) * math.pi / 4, 0) * CFrame.new(0, 0, 260)
	spawnList(ValleyLayout.plotFrame.models, plot, origin, ValleyLayout.plotColors[plotIndex])
	spawnColliders(ValleyLayout.plotFrame.collision, plot, origin)
	for area = 1, AREA_COUNT do
		local slot = origin * slotLocal(area)
		spawnList(ValleyLayout.lockedSlot.models, plot, slot)
		spawnColliders(ValleyLayout.lockedSlot.collision, plot, slot)
	end
end

root.Parent = workspace
sandbox:Destroy()

-- Stats: parts / mesh parts, and models that fell back to primitives (id 0 or failed loads).
local parts, meshes, fallbackModels = 0, 0, 0
for _, item in root:GetDescendants() do
	if item:IsA("BasePart") then
		parts += 1
		if item:IsA("MeshPart") then
			meshes += 1
		end
	elseif item:IsA("Model") and item:GetAttribute("MeshSource") == "Fallback" then
		fallbackModels += 1
	end
end
return string.format(
	"variants=%s preload ready=%d failed=%d in %.2fs; parts=%d meshparts=%d fallbackModels=%d",
	tostring(installed),
	ready,
	failed,
	loadSeconds,
	parts,
	meshes,
	fallbackModels
)
