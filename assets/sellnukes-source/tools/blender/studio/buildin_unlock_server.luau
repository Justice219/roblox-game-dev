--!strict
--[[
	buildin_unlock_server.luau — simulates ANOTHER player's area unlock: a "Base" container with
	AreaIndex = 2, BuildIn and a foreign BuyerUserId -> this client plays the Light build-in and,
	when it lands, the area-unlock fanfare + confetti.
]]
local ServerScriptService = game:GetService("ServerScriptService")
local World = ServerScriptService:WaitForChild("Server"):WaitForChild("World")
local MeshLibrary = (require :: any)(World:WaitForChild("MeshLibrary"))
local plot = workspace.Plots.PlotTest
local base = plot:GetAttribute("TestBase") :: CFrame
local area = plot:FindFirstChild("Area02") or Instance.new("Model")
area.Name = "Area02"
area:SetAttribute("AreaIndex", 2)
area.Parent = plot
local old = area:FindFirstChild("Base")
if old then
	old:Destroy()
end
local container = Instance.new("Model")
container.Name = "Base"
container.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
for i, key in { "Tile_Hazard", "Tile_Road", "Tile_Hazard" } do
	MeshLibrary.spawn(key, container, base * CFrame.new(-20 + (i - 1) * 16, 0.06, -34))
end
MeshLibrary.spawn("A4_CrystalLamp", container, base * CFrame.new(-4, 0.06, -34) * CFrame.Angles(0, math.pi, 0))
container:SetAttribute("AreaIndex", 2)
container:SetAttribute("BuildIn", workspace:GetServerTimeNow())
container:SetAttribute("BuyerUserId", 1) -- someone else
container:SetAttribute("AreaUnlock", 2) -- B5: set on the Base of an area opened by an Unlock pad
container:AddTag("BuildIn")
container.Parent = area
return "area base built"
