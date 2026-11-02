--!strict
--[[
	buildin_purchase_server.luau — simulates a purchase exactly like PlotBuilder: pad PressedAt,
	then a build Model (Workbench + MiniReactor + PocketNuke + 2 GlowLamps) stamped with BuildIn /
	BuyerUserId / PadId BEFORE parenting; the pad is removed 0.6 s later.
]]
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local World = ServerScriptService:WaitForChild("Server"):WaitForChild("World")
local MeshLibrary = (require :: any)(World:WaitForChild("MeshLibrary"))

local player = Players:GetPlayers()[1]
local plot = workspace.Plots.PlotTest
local area = plot.AreaTest
local base = plot:GetAttribute("TestBase") :: CFrame
local face = CFrame.Angles(0, math.pi, 0)
local pad = area.Pads:FindFirstChild("a1_test_pad")
if pad then
	pad:SetAttribute("PressedAt", workspace:GetServerTimeNow())
	task.delay(0.6, function()
		pad:Destroy()
	end)
end
local old = area.Builds:FindFirstChild("a1_workbench")
if old then
	old:Destroy()
end
local build = Instance.new("Model")
build.Name = "a1_workbench"
build.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
local bench = base * CFrame.new(0, 0.02, -15) * face
MeshLibrary.spawn("Workbench", build, bench)
MeshLibrary.spawn("MiniReactor", build, bench * CFrame.new(2.6, 3.3, 0.2))
MeshLibrary.spawn("PocketNuke", build, bench * CFrame.new(-1.2, 3.3, -0.6), { tint = Color3.fromRGB(150, 96, 220) })
MeshLibrary.spawn("GlowLamp", build, base * CFrame.new(-6.5, 0.02, -16))
MeshLibrary.spawn("GlowLamp", build, base * CFrame.new(6.5, 0.02, -16))
build:SetAttribute("PadId", "a1_test_pad")
build:SetAttribute("BuildIn", workspace:GetServerTimeNow())
build:SetAttribute("BuyerUserId", player.UserId)
build:AddTag("BuildIn") -- B5 contract: attributes + tag BEFORE parenting
build.Parent = area.Builds
return "purchase built: " .. #build:GetDescendants() .. " descendants"
