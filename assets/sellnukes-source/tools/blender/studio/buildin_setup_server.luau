--!strict
--[[
	buildin_setup_server.luau — PLAY-MODE verification (eval_server_runtime, holding the B4 lock).
	Builds a throwaway test plot under Workspace.Plots (created if the tycoon server has not made
	it): a buy pad in front of the player plus static FX demo props (fallback Area-4 drill rig with
	Rotor/Glow/Crystal pieces, mini reactor, glow lamp). Lives only in the playtest DataModel.
]]
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local World = ServerScriptService:WaitForChild("Server"):WaitForChild("World")
local MeshLibrary = (require :: any)(World:WaitForChild("MeshLibrary"))
local WorldMaterials = (require :: any)(World:WaitForChild("WorldMaterials"))
WorldMaterials.ensure()

local player = Players:GetPlayers()[1]
local character = player and (player.Character or player.CharacterAdded:Wait())
local root = character and character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
if root == nil then
	return "no character"
end
local plots = workspace:FindFirstChild("Plots") or Instance.new("Folder")
plots.Name = "Plots"
plots.Parent = workspace
local old = plots:FindFirstChild("PlotTest")
if old then
	old:Destroy()
end
local plot = Instance.new("Model")
plot.Name = "PlotTest"
local area = Instance.new("Model")
area.Name = "AreaTest"
area.Parent = plot
for _, name in { "Builds", "Pads", "Static" } do
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = area
end
local look = root.CFrame.LookVector * Vector3.new(1, 0, 1)
local forward = if look.Magnitude > 0.1 then look.Unit else Vector3.new(0, 0, -1)
local ground = root.Position.Y - 3
local base = CFrame.lookAt(
	Vector3.new(root.Position.X, ground, root.Position.Z),
	Vector3.new(root.Position.X, ground, root.Position.Z) + forward
)
-- The models' fronts face -Z; turn them to face the player.
local face = CFrame.Angles(0, math.pi, 0)
plot:SetAttribute("TestBase", base)

local pad = Instance.new("Model")
pad.Name = "a1_test_pad"
pad:SetAttribute("PadId", "a1_test_pad")
pad:AddTag("SNPad") -- B5 contract: pad Models carry the SNPad tag
MeshLibrary.spawn(
	"BuyPad",
	pad,
	base * CFrame.new(0, 0.02, -7),
	{ tint = Color3.fromRGB(98, 204, 70), name = "Visual" }
)
pad.Parent = area.Pads

local static = area.Static
MeshLibrary.spawn("A4_DrillRig", static, base * CFrame.new(-16, 0.02, -20) * face)
MeshLibrary.spawn("MiniReactor", static, base * CFrame.new(10, 0.02, -12) * face)
MeshLibrary.spawn("GlowLamp", static, base * CFrame.new(-8, 0.02, -10))
MeshLibrary.spawn("A4_CrystalLamp", static, base * CFrame.new(13, 0.02, -20) * face)
plot.Parent = plots
return "setup ok"
