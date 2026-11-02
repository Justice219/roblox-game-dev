--!strict
--[[
	spawn_hub.luau — EDIT-MODE art check for the B8e hub: spawns src/shared/Config/HubLayout.luau
	(hub plaza + fixtures, island scenery, the Harvest Feast event group, plot frames with every
	area slot showing the locked placeholder) through the real MeshLibrary + WorldMaterials.

	Everything is lifted by OFFSET (300 studs up) so the preview never touches edit-mode content at
	the origin (the place's default SpawnLocation); world-space layout is otherwise identical.

	Run (Studio open, Rojo synced, hold the Studio lock):
		python3 scripts/studio-lock.py acquire B8e
		python3 scripts/studio_mcp.py luau-file tools/blender/studio/spawn_hub.luau
		python3 tools/blender/studio_shot.py docs/verification/world-art/hub-wide.jpg --luau <camera.luau>
		python3 scripts/studio_mcp.py luau-file tools/blender/studio/cleanup_preview.luau   # ALWAYS
		python3 scripts/studio-lock.py release B8e
	cleanup_preview.luau removes the SN_ArtPreview folder and the edit-mode MaterialVariant clones.

	Toggles below: SHOW_EVENT (Harvest Feast decor), PLOTS (which plot frames), SHOW_COLLISION
	(translucent red boxes for every HubLayout collider — checks colliders line up with the meshes).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local World = ServerScriptService:WaitForChild("Server"):WaitForChild("World")
local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local MeshLibrary = (require :: any)(World:WaitForChild("MeshLibrary"))
local WorldMaterials = (require :: any)(World:WaitForChild("WorldMaterials"))
local HubLayout = (require :: any)(Config:WaitForChild("HubLayout"))
local WorldLayout = (require :: any)(Config:WaitForChild("WorldLayout"))

local OFFSET = CFrame.new(0, 300, 0)
local FOLDER_NAME = "SN_ArtPreview"
local SHOW_EVENT = true
local PLOTS = { 1, 2, 3, 8 }
local SHOW_COLLISION = false
-- Sample Harvest plot decorations on plot 1's HubLayout.plotDecor slots (B11 places the real ones).
local PLOT_DECOR_SAMPLE: { [string]: string } = {
	GroundL1 = "Harvest_PumpkinPile",
	GroundL2 = "Harvest_Scarecrow",
	GroundR1 = "Harvest_CornucopiaMini",
	GroundR2 = "Harvest_HayBale",
	Arch = "Harvest_Garland",
}

local old = workspace:FindFirstChild(FOLDER_NAME)
if old then
	old:Destroy()
end
local root = Instance.new("Folder")
root.Name = FOLDER_NAME

local installed = WorldMaterials.ensure()
local started = os.clock()
local preloadKeys = HubLayout.keys()
for _, key in PLOT_DECOR_SAMPLE do
	if not table.find(preloadKeys, key) then
		table.insert(preloadKeys, key)
	end
end
local ready, failed = MeshLibrary.preload(preloadKeys)
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

local hub = Instance.new("Folder")
hub.Name = "Hub"
hub.Parent = root
spawnList(HubLayout.models, hub, OFFSET)
spawnColliders(HubLayout.collision, hub, OFFSET)

if SHOW_EVENT then
	local event = Instance.new("Folder")
	event.Name = "HarvestFeast"
	event.Parent = root
	spawnList(HubLayout.event.harvest.models, event, OFFSET)
	spawnColliders(HubLayout.event.harvest.collision, event, OFFSET)
end

for _, plotIndex in PLOTS do
	local plot = Instance.new("Folder")
	plot.Name = `Plot{plotIndex}`
	plot.Parent = root
	local origin = OFFSET * WorldLayout.plotOrigin(plotIndex)
	spawnList(HubLayout.plotFrame.models, plot, origin, HubLayout.plotColors[plotIndex])
	spawnColliders(HubLayout.plotFrame.collision, plot, origin)
	for area = 1, WorldLayout.AreaCount do
		local slot = origin * WorldLayout.slotLocal(area)
		spawnList(HubLayout.lockedSlot.models, plot, slot)
		spawnColliders(HubLayout.lockedSlot.collision, plot, slot)
	end
	if plotIndex == 1 and HubLayout.plotDecor then
		for slotName, key in PLOT_DECOR_SAMPLE do
			local cf = HubLayout.plotDecor[slotName]
			if cf then
				MeshLibrary.spawn(key, plot, origin * cf, { name = `Decor_{slotName}` })
			end
		end
	end
end

root.Parent = workspace

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
