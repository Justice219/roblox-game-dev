--!strict
--[[
	spawn_area05.luau — EDIT-MODE art check for Area 5 "Enrichment Lab": builds the area exactly as
	src/shared/Config/AreaLayouts/Area05.luau describes it (base + every pad's build group in buy
	order + tinted BuyPads), through the real MeshLibrary + WorldMaterials, far from the play area.
	Because it reads the layout module itself, a clean run also proves the layout's keys, CFrames
	and collision boxes are valid.

	Run (Studio open, Rojo synced; hold the studio lock):
		python3 scripts/studio-lock.py acquire B8b-a5
		python3 scripts/studio_mcp.py luau-file tools/blender/studio/spawn_area05.luau
		python3 tools/blender/studio_shot.py docs/verification/world-art/area05-overview.jpg --luau <camera.luau>
		python3 scripts/studio_mcp.py luau 'workspace.SN_ArtPreview_A05:Destroy()'   -- or cleanup below
		python3 scripts/studio_mcp.py luau-file tools/blender/studio/cleanup_preview.luau
		python3 scripts/studio-lock.py release B8b-a5

	Knobs (edit before running):
		COMPENSATE_IMPORT_YAW  see the comment at its definition (importer 180 deg yaw workaround)
		STAGE           how many pad build groups to include, in buy order (math.huge = all; 0 = base only)
		SHOW_COLLISION  true = draw every collision box as a translucent red Part (layout debugging)

	Preview frame: the slot origin is placed at PREVIEW_ORIGIN (Area 5 is a left-side slot; in slot space
	the plot road still runs along slot z ∈ [-18, -2]); a grass plate + road strip give context. Everything lives under
	workspace.SN_ArtPreview_A05 and must be removed afterwards (never saved into the place).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AREA = 5
local STAGE = math.huge
local SHOW_COLLISION = false
-- The Open Cloud FBX importer stores every mesh yawed 180 deg about Y. MeshLibrary now undoes it
-- itself (MeshPlacement.pieceCFrame), so this legacy preview-only patch stays OFF; if turned on it
-- skips itself anyway because MeshLibrary's old placement line no longer exists.
local COMPENSATE_IMPORT_YAW = false
local PREVIEW_ORIGIN = CFrame.new(3000, 0, 2200)
local FOLDER_NAME = string.format("SN_ArtPreview_A%02d", AREA)

-- Pad kind -> BuyPad top colour (matches the Area 1 preview / pad colour language).
local PAD_COLOURS: { [string]: Color3 } = {
	Build = Color3.fromRGB(98, 204, 70),
	Multiplier = Color3.fromRGB(255, 206, 36),
	Speed = Color3.fromRGB(96, 168, 236),
	Manager = Color3.fromRGB(150, 96, 220),
	Unlock = Color3.fromRGB(255, 146, 40),
	Feature = Color3.fromRGB(232, 64, 56),
}

local World = ServerScriptService:WaitForChild("Server"):WaitForChild("World")
local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")

--[[
	Fresh module copies. Edit-mode `require` caches each ModuleScript instance for the lifetime of
	the plugin VM, so after `sync_meshes.py` the cached MeshAssets (and the MeshLibrary that
	captured it) still miss the newly uploaded keys ("unknown model key"), and a cached
	WorldFxConfig may predate functions the current MeshLibrary calls (groupFor). We clone
	MeshAssets, WorldFxConfig, MeshPlacement, WorldMaterials and MeshLibrary into a temporary
	ServerStorage sandbox (not Rojo-managed) and point the MeshLibrary clone's absolute requires at
	the sibling clones. Nothing Rojo owns is modified; the sandbox is destroyed at the end.
]]
local sandbox = Instance.new("Folder")
sandbox.Name = string.format("SN_PreviewModules_A%02d", AREA)
sandbox.Parent = game:GetService("ServerStorage")
local meshAssetsCopy = Config:WaitForChild("MeshAssets"):Clone()
meshAssetsCopy.Parent = sandbox
-- Pure modules MeshLibrary requires by absolute path (no requires of their own).
Config:WaitForChild("WorldFxConfig"):Clone().Parent = sandbox
ReplicatedStorage:WaitForChild("Shared"):WaitForChild("World"):WaitForChild("MeshPlacement"):Clone().Parent = sandbox
local worldMaterialsCopy = World:WaitForChild("WorldMaterials"):Clone()
worldMaterialsCopy.Parent = sandbox
-- WorldMaterials.ensure() clones its MaterialVariant templates from script.Parent, so the copy
-- needs the template folder next to it. (The cached original is unsafe too: its `installed`
-- flag stays true after another preview's cleanup emptied MaterialService.)
World:WaitForChild("StudMaterialVariants"):Clone().Parent = sandbox
local meshLibraryCopy = World:WaitForChild("MeshLibrary"):Clone() :: ModuleScript
local patched, replaced = string.gsub(
	(meshLibraryCopy :: any).Source,
	"require%(ReplicatedStorage%.Shared%.Config%.MeshAssets%)",
	"require(script.Parent.MeshAssets)"
)
assert(replaced == 1, "MeshLibrary no longer requires MeshAssets by its absolute path; update this preview script")
for _, path in { "Config%.WorldFxConfig", "World%.MeshPlacement" } do
	local leaf = string.match(path, "%.(%w+)$") :: string
	local count
	patched, count =
		string.gsub(patched, "require%(ReplicatedStorage%.Shared%." .. path .. "%)", `require(script.Parent.{leaf})`)
	assert(count == 1, `MeshLibrary no longer requires {leaf} by its absolute path; update this preview script`)
end
local yawFix = "off"
if COMPENSATE_IMPORT_YAW then
	local fixed, count = string.gsub(
		patched,
		"part%.CFrame = pivot %* CFrame%.new%(piece%.offset%)\n",
		"part.CFrame = pivot * CFrame.new(piece.offset) * CFrame.Angles(0, math.pi, 0)\n"
	)
	patched = fixed
	yawFix = if count == 1 then "applied" else "skipped (MeshLibrary changed)"
end
(meshLibraryCopy :: any).Source = patched
meshLibraryCopy.Parent = sandbox
local MeshLibrary = (require :: any)(meshLibraryCopy)
local WorldMaterials = (require :: any)(worldMaterialsCopy)
-- Clone before requiring: edit-mode `require` caches by instance, so a fresh clone always picks
-- up the layout Rojo just synced (the layout module has no relative requires).
local layoutModule = Config:WaitForChild("AreaLayouts"):WaitForChild(string.format("Area%02d", AREA))
local layout = (require :: any)(layoutModule:Clone())
local areaConfig = (require :: any)(Config:WaitForChild("TycoonAreas"):WaitForChild(string.format("Area%02d", AREA)))

local old = workspace:FindFirstChild(FOLDER_NAME)
if old then
	old:Destroy()
end
local root = Instance.new("Folder")
root.Name = FOLDER_NAME

local installed = WorldMaterials.ensure()

-- Context ground: grass plate under the slot + the plot road in front of it (preview only).
local function plate(name: string, size: Vector3, cf: CFrame, colour: Color3)
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.CFrame = PREVIEW_ORIGIN * cf
	part.Color = colour
	WorldMaterials.apply(part, "StudsLarge")
	part.Parent = root
end
plate("Grass", Vector3.new(140, 1, 110), CFrame.new(0, -0.5, 30), Color3.fromRGB(98, 204, 70))
plate("Road", Vector3.new(140, 1, 16), CFrame.new(0, -0.45, -10), Color3.fromRGB(78, 82, 98))

-- Ordered build groups: base, then each pad's build key in buy order (the area's own keys only).
type Placement = { key: string, cf: CFrame }
type Box = { size: Vector3, cf: CFrame }
local groups: { { name: string, models: { Placement }, collision: { Box } } } = {
	{ name = "base", models = layout.base.models, collision = layout.base.collision },
}
local missing: { string } = {}
local included = 0
for _, pad in areaConfig.pads do
	local key = pad.build
	if key ~= nil and string.sub(key, 1, 3) == string.format("A%d_", AREA) then
		local group = layout.builds[key]
		if group == nil then
			table.insert(missing, key)
		elseif included < STAGE then
			table.insert(groups, { name = key, models = group.models, collision = group.collision })
			included += 1
		end
	end
	if layout.pads[pad.id] == nil then
		table.insert(missing, "pad:" .. pad.id)
	end
end

-- Preload every key once (bounded concurrency inside MeshLibrary), then spawn.
local keys: { string } = { "BuyPad" }
local seen: { [string]: boolean } = { BuyPad = true }
for _, group in groups do
	for _, placement in group.models do
		if not seen[placement.key] then
			seen[placement.key] = true
			table.insert(keys, placement.key)
		end
	end
end
local started = os.clock()
local ready, failed = MeshLibrary.preload(keys)
local loadSeconds = os.clock() - started

local fallbacks: { string } = {}
local boxes = 0
for _, group in groups do
	local folder = Instance.new("Folder")
	folder.Name = group.name
	folder.Parent = root
	for _, placement in group.models do
		local model = MeshLibrary.spawn(placement.key, folder, PREVIEW_ORIGIN * placement.cf)
		if model:GetAttribute("MeshSource") ~= "Mesh" then
			table.insert(fallbacks, placement.key)
		end
	end
	for _, box in group.collision do
		boxes += 1
		if SHOW_COLLISION then
			local part = Instance.new("Part")
			part.Name = "Collision"
			part.Anchored = true
			part.CanCollide = false
			part.Size = box.size
			part.CFrame = PREVIEW_ORIGIN * box.cf
			part.Color = Color3.fromRGB(255, 0, 0)
			part.Transparency = 0.6
			part.Material = Enum.Material.SmoothPlastic
			part.Parent = folder
		end
	end
end

-- Pads (all of them, tinted by kind) so the road strip reads like the real game.
for _, pad in areaConfig.pads do
	local position = layout.pads[pad.id]
	if position ~= nil then
		MeshLibrary.spawn("BuyPad", root, PREVIEW_ORIGIN * CFrame.new(position), {
			tint = PAD_COLOURS[pad.kind] or PAD_COLOURS.Build,
			name = "Pad_" .. pad.id,
		})
	end
end

-- Producer click box + billboard anchor markers (debug only).
if SHOW_COLLISION then
	local click = Instance.new("Part")
	click.Name = "ProducerClick"
	click.Anchored = true
	click.CanCollide = false
	click.Size = layout.producer.click.size
	click.CFrame = PREVIEW_ORIGIN * layout.producer.click.cf
	click.Color = Color3.fromRGB(0, 120, 255)
	click.Transparency = 0.7
	click.Parent = root
end

root.Parent = workspace
-- Spawned models no longer need the module copies.
sandbox:Destroy()

local parts, meshes = 0, 0
for _, item in root:GetDescendants() do
	if item:IsA("BasePart") then
		parts += 1
		if item:IsA("MeshPart") then
			meshes += 1
		end
	end
end
return string.format(
	"area=%d yawFix=%s variants=%s groups=%d preload ready=%d failed=%d in %.2fs; parts=%d meshparts=%d; boxes=%d; fallback=[%s]; missing=[%s]",
	AREA,
	yawFix,
	tostring(installed),
	#groups,
	ready,
	failed,
	loadSeconds,
	parts,
	meshes,
	boxes,
	table.concat(fallbacks, ","),
	table.concat(missing, ",")
)
