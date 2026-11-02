--!strict
-- runtime_check_client.luau — run with eval_client_runtime after runtime_check_server.luau:
-- proves the variants replicated to the client and the spawned pieces carry them.
local MaterialService = game:GetService("MaterialService")
local names = {}
for _, item in MaterialService:GetChildren() do
	if item:IsA("MaterialVariant") then
		table.insert(names, item.Name)
	end
end
local folder = workspace:FindFirstChild("SN_RuntimeCheck")
local studded, total = 0, 0
if folder then
	for _, item in folder:GetDescendants() do
		if item:IsA("MeshPart") then
			total += 1
			if item.MaterialVariant ~= "" and MaterialService:FindFirstChild(item.MaterialVariant) then
				studded += 1
			end
		end
	end
end
local cam = workspace.CurrentCamera
return string.format(
	"client variants=[%s] meshparts=%d studded=%d cam=%s",
	table.concat(names, ","),
	total,
	studded,
	tostring(cam and cam.CFrame.Position)
)
