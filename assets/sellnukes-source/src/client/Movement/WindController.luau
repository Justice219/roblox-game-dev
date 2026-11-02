--!strict
--[[
	WindController — the on-screen wind while the player runs (owner R21: "add like a wind effect on
	the screen"). Purely cosmetic and client-only.

	What the player sees / hears (all scaled by WindLogic intensity from HORIZONTAL speed; nothing
	at all when standing still):
		- speed lines: a pool of thin tapered white streaks (Frames + UIGradient, no image assets) in
		  an elliptical band near the screen edges, sliding outward and fading; the centre stays
		  clear. One ScreenGui (DisplayOrder -20, below every HUD / screen), disabled when idle.
		- wind particles: one invisible, non-colliding part kept a few studs in front of the camera,
		  its ParticleEmitter blowing small streaks past the view, opposite to the run direction.
		- a soft whoosh (Client/Audio/Sound key Wind.WhooshKey) when the player gets up to speed.
	Respects reduced motion (profile.settings.reducedMotion OR the platform's
	GuiService.ReducedMotionEnabled): no lines, no particles (the whoosh still plays; it is not
	motion). Phones and consoles use the smaller line pool and particle rate.

	Performance: ONE RenderStepped connection; every Instance is created once at Start (fixed pool);
	idle frames only read the root part's velocity; settings are polled twice a second.

	Connects to: MovementConfig.Wind (tunables), WindLogic (math), ClientState (settings),
	Shared/Util/DeviceProfile (device class), Client/Audio/Sound (whoosh).

	Controller contract: Init() / Start(). Boot entry: "Movement/WindController".
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local MovementConfig = require(ReplicatedStorage.Shared.Config.MovementConfig)
local DeviceProfile = require(ReplicatedStorage.Shared.Util.DeviceProfile)
local ClientState = require(script.Parent.Parent.ClientState)
local Sound = require(script.Parent.Parent.Audio.Sound)
local WindLogic = require(script.Parent.WindLogic)

local WindController = {}

local cfg = MovementConfig.Wind
local localPlayer = Players.LocalPlayer

local started = false
local intensity = 0
local reduced = false
local nextSettingsAt = 0
local whooshState = WindLogic.newWhoosh()
local random = Random.new()
local function rand(): number
	return random:NextNumber()
end

-- The speed-line pool and its ScreenGui.
type LineView = { frame: Frame, line: WindLogic.Line }
local gui: ScreenGui? = nil
local views: { LineView } = {}
-- The near-camera wind emitter.
local windPart: Part? = nil
local emitter: ParticleEmitter? = nil
local particleRate = cfg.ParticleRate
-- The character's root part and humanoid (refreshed on spawn).
local root: BasePart? = nil
local humanoid: Humanoid? = nil
local visualsOn = false

-- Reduced motion: SellNukes' own setting or the platform's.
local function readReduced(): boolean
	local profile = ClientState.profile
	local settings = if profile ~= nil then profile.settings else nil
	local own = type(settings) == "table" and settings.reducedMotion == true
	return own or GuiService.ReducedMotionEnabled
end

-- Builds the line pool (once).
local function buildLines(count: number)
	local screen = Instance.new("ScreenGui")
	screen.Name = "WindLines"
	screen.IgnoreGuiInset = true
	screen.ResetOnSpawn = false
	screen.DisplayOrder = -20
	screen.Enabled = false
	local gradient = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	for index = 1, count do
		local frame = Instance.new("Frame")
		frame.Name = `Line{index}`
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.BackgroundColor3 = Color3.new(1, 1, 1)
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		local fade = Instance.new("UIGradient")
		fade.Transparency = gradient
		fade.Parent = frame
		frame.Parent = screen
		table.insert(views, { frame = frame, line = WindLogic.newLine(rand, true) })
	end
	screen.Parent = localPlayer:WaitForChild("PlayerGui")
	gui = screen
end

-- Builds the near-camera wind emitter (once).
local function buildParticles()
	local part = Instance.new("Part")
	part.Name = "WindEmitter"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(10, 6, 0.2)
	local particles = Instance.new("ParticleEmitter")
	particles.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	particles.Color = ColorSequence.new(Color3.new(1, 1, 1))
	particles.LightEmission = 0.4
	particles.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.25, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	particles.Size = NumberSequence.new(0.06, 0.02)
	particles.Squash = NumberSequence.new(-1.5)
	particles.Orientation = Enum.ParticleOrientation.VelocityParallel
	particles.Lifetime = NumberRange.new(0.35, 0.6)
	particles.Speed = NumberRange.new(32, 44)
	particles.EmissionDirection = Enum.NormalId.Front
	particles.Rate = 0
	particles.LockedToPart = false
	particles.Enabled = false
	particles.Parent = part
	part.Parent = Workspace.CurrentCamera
	windPart = part
	emitter = particles
end

-- Tracks the current character's root part and humanoid.
local function onCharacter(character: Model)
	root = nil
	humanoid = nil
	task.spawn(function()
		local foundRoot = character:WaitForChild("HumanoidRootPart", 10)
		local foundHumanoid = character:FindFirstChildOfClass("Humanoid")
		if localPlayer.Character == character and foundRoot ~= nil and foundRoot:IsA("BasePart") then
			root = foundRoot
			humanoid = foundHumanoid
		end
	end)
end

-- Hides every visual (idle, reduced motion, no character).
local function hide()
	if not visualsOn then
		return
	end
	visualsOn = false
	if gui ~= nil then
		gui.Enabled = false
	end
	if emitter ~= nil then
		emitter.Enabled = false
		emitter.Rate = 0
	end
end

-- The single per-frame update.
local function onRender(dt: number)
	local now = os.clock()
	if now >= nextSettingsAt then
		nextSettingsAt = now + cfg.SettingsPollSeconds
		reduced = readReduced()
	end
	-- Horizontal speed of the character (0 when dead, seated or missing).
	local speed = 0
	local rootPart = root
	local hum = humanoid
	local velocity = Vector3.zero
	if rootPart ~= nil and rootPart.Parent ~= nil and (hum == nil or (hum.Health > 0 and not hum.Sit)) then
		velocity = rootPart.AssemblyLinearVelocity
		speed = Vector2.new(velocity.X, velocity.Z).Magnitude
	end
	intensity = WindLogic.smooth(intensity, WindLogic.target(speed, cfg), dt, cfg)
	if WindLogic.whoosh(whooshState, intensity, now, cfg) then
		Sound.play(cfg.WhooshKey, { volume = cfg.WhooshVolume })
	end
	if reduced or intensity <= 0.01 then
		hide()
		return
	end
	if not visualsOn then
		visualsOn = true
		if gui ~= nil then
			gui.Enabled = true
		end
		if emitter ~= nil then
			emitter.Enabled = true
		end
	end
	-- Speed lines.
	local camera = Workspace.CurrentCamera
	local viewport = camera.ViewportSize
	for _, view in views do
		WindLogic.stepLine(view.line, dt, intensity, cfg, rand)
		local x, y, rotation, length, transparency =
			WindLogic.lineFrame(view.line, intensity, viewport.X, viewport.Y, cfg)
		local frame = view.frame
		frame.Position = UDim2.fromOffset(x, y)
		frame.Rotation = rotation
		frame.Size = UDim2.fromOffset(length, MovementConfig.Wind.LineThickness)
		frame.BackgroundTransparency = transparency
	end
	-- Wind particles: in front of the camera, blowing opposite to the run direction.
	local part = windPart
	local particles = emitter
	if part ~= nil and particles ~= nil then
		if part.Parent ~= camera then
			part.Parent = camera -- the camera object can be replaced (e.g. after a respawn script)
		end
		local flat = Vector3.new(velocity.X, 0, velocity.Z)
		local away = if flat.Magnitude > 0.1 then -flat.Unit else -camera.CFrame.LookVector
		local position = camera.CFrame.Position + camera.CFrame.LookVector * cfg.ParticleDistance
		part.CFrame = CFrame.lookAt(position, position + away)
		particles.Rate = particleRate * intensity
	end
end

--[[ Current wind intensity 0..1 (diagnostics / Studio verification). ]]
function WindController.intensity(): number
	return intensity
end

function WindController.Init() end

function WindController.Start()
	if started then
		return
	end
	started = true
	local class = DeviceProfile.current().class
	local lowEnd = class == "Phone" or class == "Console"
	particleRate = if lowEnd then cfg.ParticleRateLowEnd else cfg.ParticleRate
	buildLines(if lowEnd then cfg.LinesLowEnd else cfg.Lines)
	buildParticles()
	localPlayer.CharacterAdded:Connect(onCharacter)
	if localPlayer.Character ~= nil then
		onCharacter(localPlayer.Character)
	end
	RunService.RenderStepped:Connect(onRender)
end

return WindController
