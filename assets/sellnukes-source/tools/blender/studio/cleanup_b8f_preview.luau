--!strict
--[[
	cleanup_b8f_preview.luau — remove the B8f art preview (spawn_b8f_preview.luau) from the place:
	the SN_ArtPreview_B8f folder and the edit-mode SN* MaterialVariant clones in MaterialService
	(WorldMaterials.ensure() recreates them on the server at runtime; they must never be saved into
	the place — Rojo's StudMaterialVariants.model.json is the source of truth). Restores the camera.
	Run while holding the studio lock (another builder's preview may also rely on the variants).
]]
local MaterialService = game:GetService("MaterialService")
local removed = {}
local folder = workspace:FindFirstChild("SN_ArtPreview_B8f")
if folder then
	folder:Destroy()
	table.insert(removed, "SN_ArtPreview_B8f")
end
for _, item in MaterialService:GetChildren() do
	if item:IsA("MaterialVariant") and string.sub(item.Name, 1, 2) == "SN" then
		table.insert(removed, item.Name)
		item:Destroy()
	end
end
local cam = workspace.CurrentCamera
cam.CameraType = Enum.CameraType.Fixed
cam.Focus = CFrame.new(0, 5, 0)
cam.CFrame = CFrame.lookAt(Vector3.new(-20, 15, -20), Vector3.new(0, 5, 0))
return "removed: " .. table.concat(removed, ", ")
