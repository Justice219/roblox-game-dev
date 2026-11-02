--!strict
--[[
	CameraPunch — the ONE camera "punch" helper of the juice pass (owner R71): a quick FOV kick plus
	a tiny shake for area unlocks, rebirths, the finale and huge click combos.

	How it works:
		punch(strength) starts (or strengthens) one punch. While a punch is alive ONE
		BindToRenderStep runs right after Roblox's camera (RenderPriority.Camera + 1): it adds the
		envelope's FOV kick on top of the camera's own FieldOfView and multiplies a small sin/cos
		shake onto the camera CFrame, then unbinds itself when the punch ends (no idle cost).
		The FOV is additive and tolerant of other writers: if another system set FieldOfView since
		the last frame, that value becomes the new base, so the punch never fights the attack
		picker / launch cam and always restores what it found.

	Safety (owner rules):
		* Reduce Motion (Roblox setting or SellNukes `settings.reducedMotion`) -> punch is a no-op.
		* Only on the normal gameplay camera (CameraType Custom): scripted cameras (plot reveal,
		  launch cam, hatch stage) are left alone, so their CFrames never accumulate a shake.
		* Gentle by design: JuiceConfig.Punch caps (tests/juice.luau).

	Connects to: Shared/Config/JuiceConfig (Punch), Client/Tycoon/Fx/JuiceRules (envelope),
	UI/Widgets/OfferFx (reduced motion), callers JuiceController / ClickCombo.

	Example: CameraPunch.punch(0.6) -- area unlock
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local JuiceConfig = require(ReplicatedStorage.Shared.Config.JuiceConfig)
local JuiceRules = require(script.Parent.JuiceRules)
local OfferFx = require(script.Parent.Parent.Parent.UI.Widgets.OfferFx)

local CameraPunch = {}

local BINDING = "SN_JuicePunch"
local Punch = JuiceConfig.Punch

local active = false
local startedAt = 0
local strength = 0
local applied = 0 -- FOV degrees we added last frame
local written = -1 -- the FieldOfView value we wrote last frame (detects other writers)

-- Ends the punch: removes our FOV share and unbinds.
local function stop(camera: Camera?)
	if camera ~= nil and applied ~= 0 and camera.FieldOfView == written then
		camera.FieldOfView -= applied
	end
	applied, written = 0, -1
	active = false
	RunService:UnbindFromRenderStep(BINDING)
end

-- The per-frame step (bound only while a punch is alive).
local function step()
	local camera = Workspace.CurrentCamera
	if camera == nil then
		stop(nil)
		return
	end
	local age = os.clock() - startedAt
	local fov, shake = JuiceRules.punch(age, Punch.Seconds)
	if (fov <= 0 and shake <= 0) or camera.CameraType ~= Enum.CameraType.Custom then
		stop(camera)
		return
	end
	-- Base = the camera's own FOV (ours removed, unless someone else wrote it meanwhile).
	local base = if camera.FieldOfView == written then camera.FieldOfView - applied else camera.FieldOfView
	local add = Punch.FovKick * strength * fov
	camera.FieldOfView = math.clamp(base + add, 1, 120)
	applied = camera.FieldOfView - base
	written = camera.FieldOfView
	local amp = Punch.Shake * strength * shake
	if amp > 0 then
		local w = age * Punch.ShakeHz * 2 * math.pi
		camera.CFrame *= CFrame.new(math.sin(w) * amp, math.cos(w * 1.13) * amp, 0)
	end
end

--[[
	Starts a camera punch (a running one is restarted at the larger strength).
	@param amount strength 0..1 (default 1); no-op with Reduce Motion or a scripted camera
	Example: CameraPunch.punch(0.8) -- rebirth
]]
function CameraPunch.punch(amount: number?)
	local value = math.clamp(if amount ~= nil and amount == amount then amount else 1, 0, 1)
	if value <= 0 or OfferFx.reducedMotion() then
		return
	end
	local camera = Workspace.CurrentCamera
	if camera == nil or camera.CameraType ~= Enum.CameraType.Custom then
		return
	end
	-- A punch still fading keeps whatever is left of its strength (two quick punches never shrink).
	local fading = 0
	if active then
		fading = JuiceRules.punch(os.clock() - startedAt, Punch.Seconds)
	end
	strength = math.max(value, strength * fading)
	startedAt = os.clock()
	if not active then
		active = true
		RunService:BindToRenderStep(BINDING, Enum.RenderPriority.Camera.Value + 1, step)
	end
end

--[[ True while a punch is running (Studio probes / tests). ]]
function CameraPunch.isActive(): boolean
	return active
end

return CameraPunch
