--!strict
--[[
	b8f_camera_attack.luau — edit-camera preset for the B8f preview shot "attack"
	(used by tools/blender/studio_shot.py --luau). Offsets are from the preview origin (-2600, 0, 2600);
	Focus is set with CFrame because edit cameras orbit their focus.
]]
local ORIGIN = Vector3.new(-2600, 0, 2600)
local cam = workspace.CurrentCamera
cam.CameraType = Enum.CameraType.Fixed
cam.FieldOfView = 60
cam.Focus = CFrame.new(ORIGIN + Vector3.new(82, 7, 4))
cam.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(82, 16, -42), ORIGIN + Vector3.new(82, 7, 4))
return "camera attack"
