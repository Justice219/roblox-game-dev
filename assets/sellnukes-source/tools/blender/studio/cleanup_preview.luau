--!strict
--[[
	cleanup_preview.luau — remove everything the art preview / stud experiment put into the place:
	the preview folders in Workspace and the edit-mode MaterialVariant clones in MaterialService
	(at runtime WorldMaterials.ensure() recreates them on the server; they must not be saved into
	the place file, the Rojo model.json is the source of truth). Restores the edit camera.
]]
local MaterialService = game:GetService("MaterialService")
local removed = {}
for _, name in { "SN_ArtPreview", "SN_StudExperiment" } do
	local item = workspace:FindFirstChild(name)
	if item then
		item:Destroy()
		table.insert(removed, name)
	end
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
