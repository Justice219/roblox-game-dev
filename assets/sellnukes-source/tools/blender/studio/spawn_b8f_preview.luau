--!strict
--[[
	spawn_b8f_preview.luau — EDIT-MODE art check for the B8f set (pets, eggs, crates, attack mode,
	Harvest Feast items). Spawns everything through the real MeshLibrary + WorldMaterials, far from
	the play area and from the other art previews (origin -2600, 0, 2600), on a stud ground plate.

	It also proves the animation contracts the runtime relies on:
	  * one GarageEgg is spawned "hatching": its ShellTop* pieces rotated about the hinge joint
	    parsed from MeshAssets[key].pivot (`joints ShellTop@(x,y,z)`);
	  * one SupplyCrate is spawned with its Lid* pieces opened about `joints Lid@(...)`;
	  * one AATower4 has its Turret* yawed and Barrel* pitched about their joints.

	Run (Studio open, Rojo synced, hold the studio lock):
		python3 scripts/studio-lock.py acquire B8f
		python3 scripts/studio_mcp.py luau-file tools/blender/studio/spawn_b8f_preview.luau
		python3 tools/blender/studio_shot.py docs/verification/world-art/pets-studio-1.jpg \
			--luau <camera file>          (camera files: tools/blender/studio/b8f_camera_*.luau)
		python3 scripts/studio_mcp.py luau-file tools/blender/studio/cleanup_b8f_preview.luau
		python3 scripts/studio-lock.py release B8f
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local World = ServerScriptService:WaitForChild("Server"):WaitForChild("World")
local MeshLibrary = (require :: any)(World:WaitForChild("MeshLibrary"))
local WorldMaterials = (require :: any)(World:WaitForChild("WorldMaterials"))
local MeshAssets = (require :: any)(
	ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("MeshAssets")
)

local ORIGIN = CFrame.new(-2600, 0, 2600)
local FOLDER_NAME = "SN_ArtPreview_B8f"

local PETS = {
	"GlowSlime",
	"AtomPup",
	"IsotopeKitty",
	"QuarkDuck",
	"UraniumBunny",
	"NeutronNewt",
	"PlasmaPig",
	"MegaMole",
	"FissionFox",
	"ReactorOwl",
	"ProtonPanda",
	"GammaGator",
	"NuclearNarwhal",
	"CosmicCorgi",
	"RadRaccoon",
	"AtomicAxolotl",
	"MeltdownMoose",
	"FusionPhoenix",
	"ReactorRex",
	"CoreDragon",
	"NovaUnicorn",
	"IonJelly",
	"GoldenNukey",
	"VoidCat",
	"BuilderBeaver",
	"GobbleBomb",
	"AcornSquirrel",
	"HarvestHedgehog",
	"CranberryCrab",
}
local EGGS = {
	"GarageEgg",
	"StandEgg",
	"BoomDashEgg",
	"MineEgg",
	"LabEgg",
	"FactoryEgg",
	"SiloEgg",
	"MegastoreEgg",
	"SpaceEgg",
	"MegaEgg",
	"HarvestEgg",
}
local CRATES = { "SupplyCrate", "MegaCrate", "GoldenCrate" }
local NUKES = { "NukeT1", "NukeT2", "NukeT3", "NukeT4", "NukeT5", "Interceptor" }
local TOWERS = { "AATower1", "AATower2", "AATower3", "AATower4", "AATower5" }
local EVENTS = { "GoldenTurkey", "FeastSticker", "FeastStickerPlaque", "Acorn", "Pie" }

local old = workspace:FindFirstChild(FOLDER_NAME)
if old then
	old:Destroy()
end
local root = Instance.new("Folder")
root.Name = FOLDER_NAME
root.Parent = workspace

local installed = WorldMaterials.ensure()

-- Every key we spawn, preloaded once (bounded concurrency inside MeshLibrary).
local all: { string } = {}
for _, list in { PETS, EGGS, CRATES, NUKES, TOWERS, EVENTS, { "ShieldDome", "ConfettiCloud" } } do
	for _, key in list do
		table.insert(all, key)
	end
end
local started = os.clock()
local ready, failed = MeshLibrary.preload(all)
local loadSeconds = os.clock() - started

--[[
	Parse `joints Name@(x,y,z) ...` out of a MeshAssets pivot string (the B8f joint contract).
	Example: jointsOf("...; joints Head@(0,1.11,-0.11) Tail@(0,0.82,0.74)").Head --> Vector3
]]
local function jointsOf(key: string): { [string]: Vector3 }
	local joints: { [string]: Vector3 } = {}
	local asset = MeshAssets[key]
	if not asset then
		return joints
	end
	for name, x, y, z in string.gmatch(asset.pivot, "(%w+)@%(([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)%)") do
		joints[name] = Vector3.new(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
	end
	return joints
end

--[[
	Hover height from a pet pivot string ("hover 0.8"), 0 when absent.
]]
local function hoverOf(key: string): number
	local asset = MeshAssets[key]
	local value = asset and string.match(asset.pivot, "hover ([%d%.]+)")
	return tonumber(value) or 0
end

--[[
	Rotate every piece whose name starts with `prefix` about a model-space joint by `rotation`
	(the same maths the client animators use: joint frame * rotation * joint frame inverse).
]]
local function rotateGroup(model: Model, prefix: string, joint: Vector3, rotation: CFrame)
	local pivot = model:GetPivot()
	local hinge = pivot * CFrame.new(joint)
	local delta = hinge * rotation * hinge:Inverse()
	for _, part in model:GetChildren() do
		if part:IsA("BasePart") and string.sub(part.Name, 1, #prefix) == prefix then
			part.CFrame = delta * part.CFrame
		end
	end
end

local function at(x: number, y: number, z: number, yawDeg: number?): CFrame
	return ORIGIN * CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yawDeg or 0), 0)
end

-- Stud ground plate under the whole preview (one primitive, real stud material).
local ground = Instance.new("Part")
ground.Name = "Ground"
ground.Anchored = true
ground.Size = Vector3.new(220, 1, 200)
ground.CFrame = at(40, -0.5, 40)
ground.Color = Color3.fromRGB(98, 204, 70)
WorldMaterials.apply(ground, "StudsLarge")
ground.Parent = root

-- Pets: three rows of ten, facing -Z (toward the camera), floaters at their hover height.
for i, key in PETS do
	local row = (i - 1) // 10
	local col = (i - 1) % 10
	MeshLibrary.spawn(key, root, at(-16.2 + col * 3.6, hoverOf(key), row * 5.5))
end

-- Eggs in a row, one GarageEgg hatching (ShellTop flipped back about its hinge).
for i, key in EGGS do
	MeshLibrary.spawn(key, root, at(-17 + (i - 1) * 3.4, 0, 30))
end
local hatching = MeshLibrary.spawn("GarageEgg", root, at(-20.4, 0, 30), { name = "GarageEgg_Hatching" })
local eggJoints = jointsOf("GarageEgg")
if eggJoints.ShellTop then
	rotateGroup(hatching, "ShellTop", eggJoints.ShellTop, CFrame.new(0, 0.5, 0) * CFrame.Angles(math.rad(115), 0, 0))
end

-- Crates (+ one opened Supply Crate).
for i, key in CRATES do
	MeshLibrary.spawn(key, root, at(-8 + (i - 1) * 5.5, 0, 38))
end
local opened = MeshLibrary.spawn("SupplyCrate", root, at(10, 0, 38), { name = "SupplyCrate_Open" })
local crateJoints = jointsOf("SupplyCrate")
if crateJoints.Lid then
	rotateGroup(opened, "Lid", crateJoints.Lid, CFrame.Angles(math.rad(105), 0, 0))
end

-- Attack: AA towers 1-5 in a row, rockets flying side-on above them, the interceptor climbing.
for i, key in TOWERS do
	MeshLibrary.spawn(key, root, at(52 + (i - 1) * 15, 0, 0))
end
local aimed = MeshLibrary.spawn("AATower4", root, at(97, 0, 22), { name = "AATower4_Aimed" })
local towerJoints = jointsOf("AATower4")
if towerJoints.Turret then
	rotateGroup(aimed, "Turret", towerJoints.Turret, CFrame.Angles(0, math.rad(35), 0))
	rotateGroup(aimed, "Barrel", towerJoints.Turret, CFrame.Angles(0, math.rad(35), 0))
end
if towerJoints.Barrel then
	-- Pitch about the barrel joint AFTER the yaw: transform the joint by the same yaw first.
	local yawed = CFrame.new(towerJoints.Turret or Vector3.zero)
		* CFrame.Angles(0, math.rad(35), 0)
		* CFrame.new(-(towerJoints.Turret or Vector3.zero))
	local barrelJoint = (yawed * CFrame.new(towerJoints.Barrel)).Position
	local pivot = aimed:GetPivot()
	local hinge = pivot * CFrame.new(barrelJoint) * CFrame.Angles(0, math.rad(35), 0)
	local delta = hinge * CFrame.Angles(math.rad(40), 0, 0) * hinge:Inverse()
	for _, part in aimed:GetChildren() do
		if part:IsA("BasePart") and string.sub(part.Name, 1, 6) == "Barrel" then
			part.CFrame = delta * part.CFrame
		end
	end
end
for i, key in NUKES do
	local cf = at(50 + (i - 1) * 11, 16 + (i % 2) * 2, 4, -90) * CFrame.Angles(math.rad(12), 0, 0)
	if key == "Interceptor" then
		cf = at(108, 13, 4) * CFrame.Angles(math.rad(70), 0, 0)
	end
	MeshLibrary.spawn(key, root, cf)
end

-- Shield dome (scaled to radius 18) over a tower, and the confetti cloud beside it.
MeshLibrary.spawn("AATower3", root, at(60, 0, 50), { name = "AATower3_Shielded" })
local dome = MeshLibrary.spawn("ShieldDome", root, at(60, 0, 50))
dome:ScaleTo(18 / 50)
MeshLibrary.spawn("ConfettiCloud", root, at(92, 0, 50))

-- Harvest Feast items.
MeshLibrary.spawn("FeastStickerPlaque", root, at(-6, 0, 62))
MeshLibrary.spawn("GoldenTurkey", root, at(-14, 0, 56, 20))
MeshLibrary.spawn("FeastSticker", root, at(6, 0, 56))
MeshLibrary.spawn("Acorn", root, at(9.5, 0, 55))
MeshLibrary.spawn("Pie", root, at(13.5, 0, 56))

local parts, meshes, fallbacks = 0, 0, {}
for _, item in root:GetDescendants() do
	if item:IsA("BasePart") then
		parts += 1
		if item:IsA("MeshPart") then
			meshes += 1
		end
	elseif item:IsA("Model") and item:GetAttribute("MeshSource") == "Fallback" then
		table.insert(fallbacks, item.Name)
	end
end
return string.format(
	"variants=%s preload ready=%d failed=%d in %.2fs; parts=%d meshparts=%d; fallback models=%d %s",
	tostring(installed),
	ready,
	failed,
	loadSeconds,
	parts,
	meshes,
	#fallbacks,
	table.concat(fallbacks, ",")
)
