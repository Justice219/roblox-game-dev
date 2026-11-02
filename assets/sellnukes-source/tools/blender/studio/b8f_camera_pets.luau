--!strict
--[[
	b8f_camera_pets.luau — edit-camera preset for the B8f preview shot "pets"
	(used by tools/blender/studio_shot.py --luau). Offsets are from the preview origin (-2600, 0, 2600);
	Focus is set with CFrame because edit cameras orbit their focus.
]]
local ORIGIN = Vector3.new(-2600, 0, 2600)
local cam = workspace.CurrentCamera
cam.CameraType = Enum.CameraType.Fixed
cam.FieldOfView = 55
cam.Focus = CFrame.new(ORIGIN + Vector3.new(0, 1.6, 5.5))
cam.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(0, 13, -24), ORIGIN + Vector3.new(0, 1.6, 5.5))
return "camera pets"
