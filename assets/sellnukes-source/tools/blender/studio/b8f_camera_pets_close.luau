--!strict
--[[
	b8f_camera_pets_close.luau — edit-camera preset for the B8f preview shot "pets_close"
	(used by tools/blender/studio_shot.py --luau). Offsets are from the preview origin (-2600, 0, 2600);
	Focus is set with CFrame because edit cameras orbit their focus.
]]
local ORIGIN = Vector3.new(-2600, 0, 2600)
local cam = workspace.CurrentCamera
cam.CameraType = Enum.CameraType.Fixed
cam.FieldOfView = 50
cam.Focus = CFrame.new(ORIGIN + Vector3.new(-9, 1.4, 1.5))
cam.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(-9, 5.5, -10), ORIGIN + Vector3.new(-9, 1.4, 1.5))
return "camera pets_close"
