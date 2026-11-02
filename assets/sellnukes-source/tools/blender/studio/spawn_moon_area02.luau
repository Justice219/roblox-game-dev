--!strict
--[[
	spawn_moon_area02.luau — EDIT-MODE art check for Moon Base areas M1 "Crater Camp" / M2 "Cosmic
	Diner" (W6 art-d12, owner R70). Builds the area exactly as
	src/shared/Config/Worlds/Moon/Layouts/AreaNN.luau describes it — base, then each pad's build
	group in buy order (Worlds/Moon/Areas/AreaNN), then tinted BuyPads — through the real
	MeshLibrary + WorldMaterials, far away from every world (origin (-9000, 0, -9000 - 300 * N)).
	Because it reads the layout module itself, a clean run also proves the layout's mesh keys,
	CFrames, tint / castShadow fields and collision boxes are valid.
	spawn_moon_area01/02.luau are identical except for AREA (PREVIEW_ORIGIN follows it).

	Run (Studio open, Rojo synced; hold the studio lock for the whole spawn -> shots -> cleanup):
		python3 scripts/studio-lock.py acquire W6
		python3 scripts/studio_mcp.py luau-file tools/blender/studio/spawn_moon_area01.luau
		python3 tools/blender/studio_shot.py docs/verification/world3/m01-front.jpg --luau <camera.luau>
		python3 scripts/studio_mcp.py luau 'workspace.SN_ArtPreview_M01:Destroy()'
		python3 scripts/studio_mcp.py luau-file tools/blender/studio/cleanup_preview.luau  -- MaterialVariant clones
		python3 scripts/studio-lock.py release W6

	Knobs (edit before running):
		STAGE           how many pad build groups to include, in buy order (math.huge = all; 0 = base only)
		SHOW_COLLISION  true = draw collision boxes (red), the producer click box (blue) and the
		                billboard anchor (yellow ball) as translucent Parts — layout debugging

	Preview frame: the slot origin sits at PREVIEW_ORIGIN with identity rotation (+Z away from the
	road); a grass plate + a road strip along slot z ∈ [-18, -2] give context. Everything lives under
	workspace.SN_ArtPreview_MNN and must be removed afterwards.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AREA = 2
local STAGE = math.huge
local SHOW_COLLISION = false
local PREVIEW_ORIGIN = CFrame.new(-9000, 0, -9000 - 300 * AREA)
local FOLDER_NAME = string.format("SN_ArtPreview_M%02d", AREA)

-- Pad kind -> BuyPad top colour (same pad colour language as the other area previews).
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
	Fresh module copies (pattern from spawn_area06.luau). Edit-mode `require` caches each
	ModuleScript instance for the lifetime of the plugin VM, so after `sync_meshes.py` the cached
	MeshAssets (and the MeshLibrary that captured it) still miss newly uploaded keys ("unknown model
	key"). MeshAssets, WorldMaterials (+ its variant templates) and MeshLibrary are cloned into a
	temporary ServerStorage sandbox (not Rojo-managed) and the MeshLibrary clone is pointed at the
	sibling MeshAssets clone. Nothing Rojo owns is modified; the sandbox is destroyed at the end.
]]
local sandbox = Instance.new("Folder")
sandbox.Name = string.format("SN_PreviewModules_M%02d", AREA)
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
-- Clone before requiring: edit-mode `require` caches by instance, so a fresh clone always picks up
-- the layout Rojo just synced (layout modules have no relative requires).
local Moon = Config:WaitForChild("Worlds"):WaitForChild("Moon")
local layoutModule = Moon:WaitForChild("Layouts"):WaitForChild(string.format("Area%02d", AREA))
local layout = (require :: any)(layoutModule:Clone())
local areaConfig = (require :: any)(Moon:WaitForChild("Areas"):WaitForChild(string.format("Area%02d", AREA)))
local MeshAssets = (require :: any)(sandbox:WaitForChild("MeshAssets"))

local old = workspace:FindFirstChild(FOLDER_NAME)
if old then
	old:Destroy()
end
local root = Instance.new("Folder")
root.Name = FOLDER_NAME

local installed = WorldMaterials.ensure()

--[[ Anchored debug / context Part under `parent`, positioned in slot space. ]]
local function part(name: string, size: Vector3, cf: CFrame, colour: Color3, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = PREVIEW_ORIGIN * cf
	p.Color = colour
	p.Parent = parent
	return p
end

-- Context ground: grass plate under the slot + the plot road in front of it (preview only).
WorldMaterials.apply(
	part("Grass", Vector3.new(150, 1, 110), CFrame.new(0, -0.5, 30), Color3.fromRGB(98, 204, 70), root),
	"StudsLarge"
)
WorldMaterials.apply(
	part("Road", Vector3.new(150, 1, 16), CFrame.new(0, -0.45, -10), Color3.fromRGB(78, 82, 98), root),
	"Studs"
)

-- Ordered build groups: base, then each pad's build key in buy order (the area's own keys only;
-- the Unlock pad's M{N+1}_EntryArch is the next area's base).
type Placement = { key: string, cf: CFrame, tint: Color3?, castShadow: boolean?, collide: boolean? }
type Box = { size: Vector3, cf: CFrame }
local groups: { { name: string, models: { Placement }, collision: { Box } } } = {
	{ name = "base", models = layout.base.models, collision = layout.base.collision or {} },
}
local missing: { string } = {}
local included = 0
local ownPrefix = string.format("M%d_", AREA)
for _, pad in areaConfig.pads do
	local key = pad.build
	if key ~= nil and string.sub(key, 1, #ownPrefix) == ownPrefix then
		local group = layout.builds[key]
		if group == nil then
			table.insert(missing, key)
		elseif included < STAGE then
			table.insert(groups, { name = key, models = group.models, collision = group.collision or {} })
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
local triangles = 0 -- authored triangle total of everything spawned (MeshAssets[key].triangles)
for _, group in groups do
	local folder = Instance.new("Folder")
	folder.Name = group.name
	folder.Parent = root
	for index, placement in group.models do
		local model = MeshLibrary.spawn(placement.key, folder, PREVIEW_ORIGIN * placement.cf, {
			tint = placement.tint,
			castShadow = placement.castShadow,
			name = `{placement.key}_{index}`,
		})
		if model:GetAttribute("MeshSource") ~= "Mesh" then
			table.insert(fallbacks, placement.key)
		end
		triangles += MeshAssets[placement.key].triangles
		if SHOW_COLLISION and placement.collide then
			local centre, size = MeshLibrary.getBounds(placement.key)
			local box = part("CollideBounds", size, placement.cf * centre, Color3.fromRGB(255, 0, 0), folder)
			box.CanCollide = false
			box.Transparency = 0.6
		end
	end
	for _, box in group.collision do
		boxes += 1
		if SHOW_COLLISION then
			local p = part("Collision", box.size, box.cf, Color3.fromRGB(255, 0, 0), folder)
			p.CanCollide = false
			p.Transparency = 0.6
			p.Material = Enum.Material.SmoothPlastic
		end
	end
end

-- Pads (all of them, tinted by kind) so the road-side strip reads like the real game.
for _, pad in areaConfig.pads do
	local position = layout.pads[pad.id]
	if position ~= nil then
		MeshLibrary.spawn("BuyPad", root, PREVIEW_ORIGIN * CFrame.new(position), {
			tint = PAD_COLOURS[pad.kind] or PAD_COLOURS.Build,
			name = "Pad_" .. pad.id,
		})
		triangles += MeshAssets.BuyPad.triangles
	end
end

-- Producer click box (blue) + billboard anchor (yellow ball): debug only.
if SHOW_COLLISION then
	local click =
		part("ProducerClick", layout.producer.click.size, layout.producer.click.cf, Color3.fromRGB(0, 120, 255), root)
	click.CanCollide = false
	click.Transparency = 0.7
	local anchor = part(
		"ProducerAnchor",
		Vector3.new(1, 1, 1),
		CFrame.new(layout.producer.anchor),
		Color3.fromRGB(255, 220, 0),
		root
	)
	anchor.Shape = Enum.PartType.Ball
	anchor.CanCollide = false
	local spawnMarker =
		part("SpawnPoint", Vector3.new(2, 0.2, 2), CFrame.new(layout.spawnPoint), Color3.fromRGB(255, 255, 255), root)
	spawnMarker.CanCollide = false
end

root.Parent = workspace
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
	"area=%d variants=%s groups=%d preload ready=%d failed=%d in %.2fs; parts=%d meshparts=%d tris~%d; boxes=%d; fallback=[%s]; missing=[%s]",
	AREA,
	tostring(installed),
	#groups,
	ready,
	failed,
	loadSeconds,
	parts,
	meshes,
	triangles,
	boxes,
	table.concat(fallbacks, ","),
	table.concat(missing, ",")
)
