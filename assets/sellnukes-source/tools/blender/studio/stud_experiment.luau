--!strict
-- Stud material experiment (edit mode). Rows, left to right in each row: Part cube, Part cyl, MeshPart cube, MeshPart cyl.
-- Row A: MaterialVariant (StudsPerTile 2). Row B: SurfaceAppearance (MeshParts only). Row C: Texture x6. Row D: legacy Studs surface.
local AssetService = game:GetService("AssetService")
local MaterialService = game:GetService("MaterialService")
local IMG = { color = 111053696270611, normal = 88518149682413, rough = 93245873035569 }
local MESH = { Cube = 131438796825936, Cyl = 87401197441342 }
local ORIGIN = Vector3.new(2000, 50, 2000)
local old = workspace:FindFirstChild("SN_StudExperiment")
if old then
	old:Destroy()
end
local oldMv = MaterialService:FindFirstChild("SN_StudTest")
if oldMv then
	oldMv:Destroy()
end
local mv = Instance.new("MaterialVariant")
mv.Name = "SN_StudTest"
mv.BaseMaterial = Enum.Material.Plastic
mv.ColorMap = "rbxassetid://" .. IMG.color
mv.NormalMap = "rbxassetid://" .. IMG.normal
mv.RoughnessMap = "rbxassetid://" .. IMG.rough
mv.StudsPerTile = 2
mv.Parent = MaterialService

local root = Instance.new("Folder")
root.Name = "SN_StudExperiment"
root.Parent = workspace
local GREEN = Color3.fromRGB(98, 204, 70)
local YELLOW = Color3.fromRGB(255, 206, 36)
local BLUE = Color3.fromRGB(96, 168, 236)

local templates: { [string]: MeshPart } = {}
for name, id in MESH do
	templates[name] =
		AssetService:CreateMeshPartAsync(Content.fromAssetId(id), { CollisionFidelity = Enum.CollisionFidelity.Box })
end

local function base(p: BasePart, pos: Vector3, color: Color3)
	p.Anchored = true
	p.Color = color
	p.Position = ORIGIN + pos
	p.Parent = root
end

local function parts(z: number, color: Color3): { BasePart }
	local list = {}
	local cube = Instance.new("Part")
	cube.Size = Vector3.new(4, 4, 4)
	base(cube, Vector3.new(-12, 2, z), color)
	local cyl = Instance.new("Part")
	cyl.Shape = Enum.PartType.Cylinder
	cyl.Size = Vector3.new(4, 3, 3)
	cyl.Orientation = Vector3.new(0, 0, 90)
	base(cyl, Vector3.new(-6, 2, z), color)
	local mcube = templates.Cube:Clone()
	mcube.Size = Vector3.new(4, 4, 4)
	base(mcube, Vector3.new(0, 2, z), color)
	local mcyl = templates.Cyl:Clone()
	mcyl.Size = Vector3.new(3, 4, 3)
	base(mcyl, Vector3.new(6, 2, z), color)
	-- a big mesh scaled 3x (to see how UV density changes when a mesh is resized)
	local big = templates.Cube:Clone()
	big.Size = Vector3.new(8, 8, 8)
	base(big, Vector3.new(14, 4, z), color)
	table.insert(list, cube)
	table.insert(list, cyl)
	table.insert(list, mcube)
	table.insert(list, mcyl)
	table.insert(list, big)
	return list
end

-- Ground slab with the variant (density reference against character-sized objects)
local ground = Instance.new("Part")
ground.Size = Vector3.new(48, 1, 60)
ground.Material = Enum.Material.Plastic
ground.MaterialVariant = "SN_StudTest"
base(ground, Vector3.new(0, -0.5, -6), Color3.fromRGB(78, 82, 98))

-- Row A: MaterialVariant
for _, p in parts(-24, GREEN) do
	p.Material = Enum.Material.Plastic
	p.MaterialVariant = "SN_StudTest"
end
-- Row B: SurfaceAppearance (Parts get nothing: unsupported)
for i, p in parts(-12, YELLOW) do
	p.Material = Enum.Material.Plastic
	if p:IsA("MeshPart") then
		local sa = Instance.new("SurfaceAppearance")
		sa.ColorMap = "rbxassetid://" .. IMG.color
		sa.NormalMap = "rbxassetid://" .. IMG.normal
		sa.RoughnessMap = "rbxassetid://" .. IMG.rough
		pcall(function()
			(sa :: any).Color = YELLOW
		end)
		sa.Parent = p
	end
end
-- Row C: 6 Texture instances
for _, p in parts(0, BLUE) do
	p.Material = Enum.Material.SmoothPlastic
	for _, face in Enum.NormalId:GetEnumItems() do
		local t = Instance.new("Texture")
		t.Texture = "rbxassetid://" .. IMG.color
		t.StudsPerTileU = 2
		t.StudsPerTileV = 2
		t.Face = face
		t.Color3 = BLUE
		t.Parent = p
	end
end
-- Row D: legacy Studs surfaces (Parts only)
for _, p in parts(12, GREEN) do
	p.Material = Enum.Material.Plastic
	if not p:IsA("MeshPart") then
		local bp = p :: Part
		bp.TopSurface = Enum.SurfaceType.Studs
		bp.FrontSurface = Enum.SurfaceType.Studs
		bp.RightSurface = Enum.SurfaceType.Studs
		bp.LeftSurface = Enum.SurfaceType.Studs
		bp.BackSurface = Enum.SurfaceType.Studs
	end
end
local cam = workspace.CurrentCamera
cam.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(-30, 26, -48), ORIGIN + Vector3.new(0, 0, -6))
return "ok " .. #root:GetChildren()
