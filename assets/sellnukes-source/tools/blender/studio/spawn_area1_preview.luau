--!strict
--[[
	spawn_area1_preview.luau — EDIT-MODE art check: spawns the Area 1 Garage Lab set, tiles, pads
	and pocket nukes through the real MeshLibrary + WorldMaterials, far from the play area.

	Run (Studio open, Rojo synced):
		python3 scripts/studio_mcp.py luau-file tools/blender/studio/spawn_area1_preview.luau
		python3 tools/blender/studio_shot.py docs/verification/world-art/area1-exterior.jpg \
			--luau tools/blender/studio/camera_exterior.luau
	Clean up afterwards (removes the preview folder AND the edit-mode MaterialService clones):
		python3 scripts/studio_mcp.py luau-file tools/blender/studio/cleanup_preview.luau

	Placement mirrors the suggestions in tools/blender/models/area1_garage.py (garage-origin
	pivot for shell pieces, prop pivots on the floor at y = 0.6).
]]

local ServerScriptService = game:GetService("ServerScriptService")

local World = ServerScriptService:WaitForChild("Server"):WaitForChild("World")
local MeshLibrary = (require :: any)(World:WaitForChild("MeshLibrary"))
local WorldMaterials = (require :: any)(World:WaitForChild("WorldMaterials"))

local ORIGIN = CFrame.new(2000, 0, 2000)
local FOLDER_NAME = "SN_ArtPreview"

local old = workspace:FindFirstChild(FOLDER_NAME)
if old then
	old:Destroy()
end
local root = Instance.new("Folder")
root.Name = FOLDER_NAME
root.Parent = workspace

local installed = WorldMaterials.ensure()
local keys = {
	"Tile_Grass",
	"Tile_Road",
	"Tile_Sidewalk",
	"Tile_Hazard",
	"BuyPad",
	"PocketNuke",
	"Garage_Floor",
	"Garage_WallBack",
	"Garage_WallSide",
	"Garage_WallFront",
	"Garage_Roof",
	"Garage_Door",
	"Workbench",
	"MiniReactor",
	"ToolWall",
	"GlowLamp",
	"PaintStation",
	"Driveway",
}
local started = os.clock()
local ready, failed = MeshLibrary.preload(keys)
local loadSeconds = os.clock() - started

local function at(x: number, y: number, z: number, yawDeg: number?): CFrame
	return ORIGIN * CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yawDeg or 0), 0)
end

-- Ground: grass field, sidewalk + road rows in front, a hazard loading zone.
for _, x in { -40, -24, -8, 8, 24, 40 } do
	for _, z in { -28, -12, 4, 20 } do
		MeshLibrary.spawn("Tile_Grass", root, at(x, 0, z), { castShadow = false })
	end
	MeshLibrary.spawn("Tile_Sidewalk", root, at(x, 0, -44), { castShadow = false })
	MeshLibrary.spawn("Tile_Road", root, at(x, 0, -60, 90), { castShadow = false })
end
MeshLibrary.spawn("Tile_Hazard", root, at(40, 0.05, -28), { castShadow = false })

-- Garage shell (shared garage-origin pivot).
local garage = at(0, 0, 0)
for _, key in { "Garage_Floor", "Garage_WallBack", "Garage_WallFront", "Garage_Roof", "Garage_Door" } do
	MeshLibrary.spawn(key, root, garage)
end
MeshLibrary.spawn("Garage_WallSide", root, garage, { name = "Garage_WallSide_PosX" })
MeshLibrary.spawn("Garage_WallSide", root, garage * CFrame.Angles(0, math.pi, 0), { name = "Garage_WallSide_NegX" })

-- Props inside.
local bench = at(-4, 0.6, 6)
MeshLibrary.spawn("Workbench", root, bench)
MeshLibrary.spawn("MiniReactor", root, bench * CFrame.new(2.6, 3.3, 0.2))
MeshLibrary.spawn("PocketNuke", root, bench * CFrame.new(-1.2, 3.3, -0.6), { tint = Color3.fromRGB(232, 64, 56) })
MeshLibrary.spawn("ToolWall", root, at(7, 0.6, 11))
MeshLibrary.spawn("GlowLamp", root, at(11, 0.6, -7))
MeshLibrary.spawn("GlowLamp", root, at(-11, 0.6, -7))
local paint = at(-10.4, 0.6, -0.5, -90)
MeshLibrary.spawn("PaintStation", root, paint)
MeshLibrary.spawn("PocketNuke", root, paint * CFrame.new(0, 0.5, 0.2), { tint = Color3.fromRGB(110, 222, 170) })

-- Outside: driveway, buy pads in the four pad colours, a tier line-up of pocket nukes.
MeshLibrary.spawn("Driveway", root, at(0, 0, -24))
local padColours = {
	Color3.fromRGB(98, 204, 70), -- buy / build (green)
	Color3.fromRGB(255, 206, 36), -- multiplier (yellow)
	Color3.fromRGB(232, 64, 56), -- decoration (red)
	Color3.fromRGB(150, 150, 160), -- locked (grey)
}
for i, colour in padColours do
	local x = if i <= 2 then -26 + (i - 1) * 8 else 18 + (i - 3) * 8
	MeshLibrary.spawn("BuyPad", root, at(x, 0, -27), { tint = colour })
end
local tiers = {
	Color3.fromRGB(232, 64, 56),
	Color3.fromRGB(110, 222, 170),
	Color3.fromRGB(150, 96, 220),
	Color3.fromRGB(255, 146, 40),
	Color3.fromRGB(255, 214, 50),
}
for i, colour in tiers do
	MeshLibrary.spawn("PocketNuke", root, at(-8 + (i - 1) * 4, 0, -42), { tint = colour })
end
-- Fallback path check: the same workbench built from primitives (no mesh ids used).
local fallback = MeshLibrary.spawn("Workbench", root, at(26, 0, 8), { fallback = true, name = "Workbench_Fallback" })

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
	"variants=%s preload ready=%d failed=%d in %.2fs; parts=%d meshparts=%d; fallback=%s",
	tostring(installed),
	ready,
	failed,
	loadSeconds,
	parts,
	meshes,
	tostring(fallback:GetAttribute("MeshSource"))
)
