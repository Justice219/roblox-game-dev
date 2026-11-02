--!strict
--[[
	camera.luau — point the Studio EDIT camera for art screenshots (used by studio_shot.py --luau).
	Edit-mode cameras orbit their Focus, so Focus must be set together with CFrame or Studio snaps
	back. Edit EYE/TARGET below (offsets from the preview origin 2000, 0, 2000).
]]
local ORIGIN = Vector3.new(2000, 0, 2000)
local EYE = Vector3.new(-34, 26, -62)
local TARGET = Vector3.new(0, 4, -8)
local cam = workspace.CurrentCamera
cam.CameraType = Enum.CameraType.Fixed
cam.FieldOfView = 55
cam.Focus = CFrame.new(ORIGIN + TARGET)
cam.CFrame = CFrame.lookAt(ORIGIN + EYE, ORIGIN + TARGET)
return "camera set"
