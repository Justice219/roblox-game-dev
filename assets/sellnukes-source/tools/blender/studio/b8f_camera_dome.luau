--!strict
--[[
	b8f_camera_dome.luau — edit-camera preset for the B8f preview shot "dome"
	(used by tools/blender/studio_shot.py --luau). Offsets are from the preview origin (-2600, 0, 2600);
	Focus is set with CFrame because edit cameras orbit their focus.
]]
local ORIGIN = Vector3.new(-2600, 0, 2600)
local cam = workspace.CurrentCamera
cam.CameraType = Enum.CameraType.Fixed
cam.FieldOfView = 60
cam.Focus = CFrame.new(ORIGIN + Vector3.new(72, 6, 50))
cam.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(76, 16, 14), ORIGIN + Vector3.new(72, 6, 50))
return "camera dome"
