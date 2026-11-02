--!strict
--[[
	runtime_check_server.luau — PLAY-MODE verification (run with eval_server_runtime during a solo
	playtest, holding scripts/studio-lock.py). Proves the runtime path end to end on the server:
	WorldMaterials.ensure() clones the SN* variants into MaterialService, MeshLibrary preloads and
	spawns meshes next to the first player's character so the client screenshot shows them.
	Everything spawned lives in Workspace.SN_RuntimeCheck (playtest DataModel only; discarded on stop).
]]
local Players = game:GetService("Players")
local MaterialService = game:GetService("MaterialService")
local ServerScriptService = game:GetService("ServerScriptService")

local World = ServerScriptService:WaitForChild("Server"):WaitForChild("World")
local MeshLibrary = (require :: any)(World:WaitForChild("MeshLibrary"))
local WorldMaterials = (require :: any)(World:WaitForChild("WorldMaterials"))

local installed = WorldMaterials.ensure()
local player = Players:GetPlayers()[1]
local character = player and (player.Character or player.CharacterAdded:Wait())
local hrp = character and character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
if hrp == nil then
	return "no character"
end
local old = workspace:FindFirstChild("SN_RuntimeCheck")
if old then
	old:Destroy()
end
local root = Instance.new("Folder")
root.Name = "SN_RuntimeCheck"
root.Parent = workspace
local ground = hrp.Position.Y - 3
local look = hrp.CFrame.LookVector * Vector3.new(1, 0, 1)
local forward = if look.Magnitude > 0.1 then look.Unit else Vector3.new(0, 0, -1)
local base = CFrame.lookAt(
	Vector3.new(hrp.Position.X, ground, hrp.Position.Z),
	Vector3.new(hrp.Position.X, ground, hrp.Position.Z) + forward
)
local ready, failed =
	MeshLibrary.preload({ "Workbench", "MiniReactor", "BuyPad", "PocketNuke", "Tile_Hazard", "GlowLamp" })
-- Models face the player (their front is -Z; base looks along the player's facing, so rotate 180).
local face = CFrame.Angles(0, math.pi, 0)
MeshLibrary.spawn("Tile_Hazard", root, base * CFrame.new(0, 0.02, -12), { castShadow = false })
local bench = base * CFrame.new(0, 0.05, -14) * face
MeshLibrary.spawn("Workbench", root, bench)
MeshLibrary.spawn("MiniReactor", root, bench * CFrame.new(2.6, 3.3, 0.2))
MeshLibrary.spawn("PocketNuke", root, bench * CFrame.new(-1.2, 3.3, -0.6), { tint = Color3.fromRGB(150, 96, 220) })
MeshLibrary.spawn("BuyPad", root, base * CFrame.new(-6, 0.02, -7), { tint = Color3.fromRGB(255, 206, 36) })
MeshLibrary.spawn("BuyPad", root, base * CFrame.new(6, 0.02, -7), { tint = Color3.fromRGB(98, 204, 70) })
MeshLibrary.spawn("GlowLamp", root, base * CFrame.new(-7, 0.02, -15))
MeshLibrary.spawn("GlowLamp", root, base * CFrame.new(7, 0.02, -15))
local variants = {}
for _, item in MaterialService:GetChildren() do
	if item:IsA("MaterialVariant") then
		table.insert(variants, `{item.Name}@{item.StudsPerTile}`)
	end
end
local meshParts = 0
for _, item in root:GetDescendants() do
	if item:IsA("MeshPart") then
		meshParts += 1
	end
end
return string.format(
	"ensure=%s variants=[%s] ready=%d failed=%d meshparts=%d stats=%s",
	tostring(installed),
	table.concat(variants, ","),
	ready,
	failed,
	meshParts,
	tostring(MeshLibrary.stats().templates)
)
