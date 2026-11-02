--!strict
--[[
	AttackFx — the kid-friendly effects of Attack mode (spec §1: "explosions are confetti mushroom
	clouds (green/yellow puffs, stars, "BOOM!" pop text). Hit buildings wobble and puff smoke,
	then recover"):
		explode(position, options)  confetti mushroom cloud + stars + "BOOM!" + nearby buildings
		                            wobble (and recover exactly) + a gentle camera nudge when the
		                            local player stands on the hit plot
		pop(position)               the small mid-air burst of an intercepted nuke ("POP!")
		puff(position, size)        a little smoke puff (missed interceptors, launches)

	Pools: puff rigs (the server's AttackTemplates.Puff clones), particle burst attachments and
	BillboardGui texts are created once and reused — zero Instance.new after warm-up. Animations
	are TweenService tweens (engine side) plus one shared PreRender step that only runs while a
	wobble or a camera nudge is active.

	Accessibility: Reduce Motion (profile.settings.reducedMotion) skips the wobble, the camera
	nudge and the puff growth (the cloud just fades); no screen flashes ever.

	Sounds: the shared client SFX API Audio/Sound (AudioConfig keys; guarded lazy require, silent if
	missing): "nuke_boom" for the cloud, "sparkle" for intercepts, "cash_big" for the attacker's own
	hits, "pop" for missed interceptors; FlightRenderer uses "nuke_launch" / "nuke_whoosh".

	Connects to: Shared/Config/{AttackConfig, WorldMaterialConfig}, Client/ClientState,
	Client/Audio/Sound, Client/Attack/FlightRenderer (caller).

	Example:
		AttackFx.explode(position, { plot = 3, mine = true })
		AttackFx.pop(position)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local AttackConfig = require(ReplicatedStorage.Shared.Config.AttackConfig)
local ClientState = require(script.Parent.Parent.ClientState)
local WorldMaterialConfig = require(ReplicatedStorage.Shared.Config.WorldMaterialConfig)

local AttackFx = {}

local CLIENT = AttackConfig.Client
local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local SMOKE_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local CONFETTI_COLORS = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(232, 64, 56)),
	ColorSequenceKeypoint.new(0.2, Color3.fromRGB(255, 206, 36)),
	ColorSequenceKeypoint.new(0.4, Color3.fromRGB(98, 204, 70)),
	ColorSequenceKeypoint.new(0.6, Color3.fromRGB(96, 168, 236)),
	ColorSequenceKeypoint.new(0.8, Color3.fromRGB(150, 96, 220)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 120, 180)),
})
-- Rig counts (bursts are cheap; texts and puffs are the visible budget).
local BURSTS = 6
local TEXTS = 6

export type ExplodeOptions = {
	plot: number?, -- the hit plot (buildings wobble there)
	mine: boolean?, -- the local player launched it (fanfare)
	onMe: boolean?, -- it hit the local player's plot (camera nudge when standing there)
	scale: number?, -- size multiplier (tier)
}

type Burst = { attachment: Attachment, confetti: ParticleEmitter, sparkle: ParticleEmitter, smoke: ParticleEmitter }
type TextRig = { attachment: Attachment, gui: BillboardGui, label: TextLabel, scale: UIScale }
type PuffRig = { model: Model, parts: { BasePart }, sizes: { Vector3 }, offsets: { CFrame } }
type Wobble = { model: Model, base: CFrame, start: number, applied: CFrame, axis: Vector3 }

local folder: Folder? = nil
local bursts: { Burst } = {}
local nextBurst = 1
local texts: { TextRig } = {}
local nextText = 1
local freePuffs: { PuffRig } = {}
local wobbles: { [Model]: Wobble } = {}
local shakeUntil = 0
local shakeStart = 0
local stepConnection: RBXScriptConnection? = nil
local soundModule: any = nil

-- True when the player asked for reduced motion.
local function reducedMotion(): boolean
	local profile: any = ClientState.profile
	return type(profile) == "table" and type(profile.settings) == "table" and profile.settings.reducedMotion == true
end

-- Plays a 3D sound through the shared client SFX API (Audio/Sound; silent when unavailable).
local function sound(key: string, position: Vector3, pitch: number?, volume: number?)
	if soundModule == nil then
		local ok, module = pcall(function(): any
			return require(script.Parent.Parent.Audio.Sound) :: any
		end)
		soundModule = if ok and type(module) == "table" and type(module.play) == "function" then module else false
	end
	if soundModule ~= false then
		pcall(soundModule.play, key, { position = position, pitch = pitch, volume = volume })
	end
end
AttackFx.sound = sound

-- The client-only folder for FX instances.
local function fxFolder(): Folder
	local existing = folder
	if existing ~= nil and existing.Parent ~= nil then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = "SN_AttackFx"
	created.Parent = Workspace
	folder = created
	return created
end

-- One particle burst rig (confetti squares, sparkle stars, smoke puffs).
local function makeBurst(index: number): Burst
	local attachment = Instance.new("Attachment")
	attachment.Name = `SN_AttackBurst{index}`
	attachment.Parent = Workspace.Terrain

	local confetti = Instance.new("ParticleEmitter")
	confetti.Name = "Confetti"
	confetti.Enabled = false
	confetti.Texture = `rbxassetid://{WorldMaterialConfig.Images.Color}`
	confetti.Color = CONFETTI_COLORS
	confetti.Lifetime = NumberRange.new(1.6, 2.6)
	confetti.Speed = NumberRange.new(30, 60)
	confetti.SpreadAngle = Vector2.new(60, 60)
	confetti.EmissionDirection = Enum.NormalId.Top
	confetti.Acceleration = Vector3.new(0, -40, 0)
	confetti.Drag = 1.4
	confetti.Rotation = NumberRange.new(0, 360)
	confetti.RotSpeed = NumberRange.new(-260, 260)
	confetti.Size = NumberSequence.new(0.9)
	confetti.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.8, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	confetti.Orientation = Enum.ParticleOrientation.VelocityPerpendicular
	confetti.LightInfluence = 0.6
	confetti.Parent = attachment

	local sparkle = Instance.new("ParticleEmitter")
	sparkle.Name = "Stars"
	sparkle.Enabled = false
	sparkle.Texture = SPARKLE_TEXTURE
	sparkle.Color = ColorSequence.new(Color3.fromRGB(255, 244, 150), Color3.fromRGB(190, 255, 150))
	sparkle.Lifetime = NumberRange.new(0.6, 1.1)
	sparkle.Speed = NumberRange.new(14, 30)
	sparkle.SpreadAngle = Vector2.new(180, 180)
	sparkle.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(1, 0) })
	sparkle.LightEmission = 0.6
	sparkle.LightInfluence = 0
	sparkle.Parent = attachment

	local smoke = Instance.new("ParticleEmitter")
	smoke.Name = "Smoke"
	smoke.Enabled = false
	smoke.Texture = SMOKE_TEXTURE
	smoke.Color = ColorSequence.new(Color3.fromRGB(235, 245, 225))
	smoke.Lifetime = NumberRange.new(1.4, 2.2)
	smoke.Speed = NumberRange.new(4, 9)
	smoke.SpreadAngle = Vector2.new(180, 40)
	smoke.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 4), NumberSequenceKeypoint.new(1, 12) })
	smoke.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) })
	smoke.LightInfluence = 0.8
	smoke.Parent = attachment

	return { attachment = attachment, confetti = confetti, sparkle = sparkle, smoke = smoke }
end

-- The next burst rig (round robin).
local function burst(): Burst
	if #bursts == 0 then
		for index = 1, BURSTS do
			bursts[index] = makeBurst(index)
		end
	end
	local rig = bursts[nextBurst]
	nextBurst = nextBurst % BURSTS + 1
	return rig
end

-- One pop-text rig ("BOOM!" / "POP!").
local function makeText(index: number): TextRig
	local attachment = Instance.new("Attachment")
	attachment.Name = `SN_AttackText{index}`
	attachment.Parent = Workspace.Terrain
	local gui = Instance.new("BillboardGui")
	gui.Name = "Pop"
	gui.Size = UDim2.fromOffset(260, 110)
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = CLIENT.RenderDistance
	gui.Enabled = false
	gui.Adornee = attachment
	gui.Parent = attachment
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.FontFace = Font.fromName("LuckiestGuy")
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 226, 60)
	label.TextStrokeTransparency = 1
	label.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 4
	stroke.Color = Color3.fromRGB(40, 24, 10)
	stroke.Parent = label
	local scale = Instance.new("UIScale")
	scale.Parent = label
	return { attachment = attachment, gui = gui, label = label, scale = scale }
end

-- Shows a pop text at a position for ~1 s.
local function popText(position: Vector3, text: string, color: Color3)
	if #texts == 0 then
		for index = 1, TEXTS do
			texts[index] = makeText(index)
		end
	end
	local rig = texts[nextText]
	nextText = nextText % TEXTS + 1
	rig.attachment.WorldPosition = position
	rig.label.Text = text
	rig.label.TextColor3 = color
	rig.label.TextTransparency = 0
	rig.scale.Scale = 0.2
	rig.gui.Enabled = true
	TweenService:Create(rig.scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		:Play()
	local fade = TweenService:Create(
		rig.label,
		TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, 0.7),
		{
			TextTransparency = 1,
		}
	)
	fade:Play()
	fade.Completed:Once(function()
		if rig.label.Text == text then
			rig.gui.Enabled = false
		end
	end)
end

-- A pooled mushroom-cloud puff (clone of AttackTemplates.Puff), or nil while not replicated.
local function takePuff(): PuffRig?
	local rig = table.remove(freePuffs)
	if rig ~= nil then
		return rig
	end
	local templates = ReplicatedStorage:FindFirstChild(AttackConfig.TemplateFolder)
	local template = if templates ~= nil then templates:FindFirstChild("Puff") else nil
	if template == nil or not template:IsA("Model") then
		return nil
	end
	local model = template:Clone()
	local pivot = model:GetPivot()
	local parts: { BasePart } = {}
	local sizes: { Vector3 } = {}
	local offsets: { CFrame } = {}
	for _, item in model:GetDescendants() do
		if item:IsA("BasePart") then
			table.insert(parts, item)
			table.insert(sizes, item.Size)
			local offset: CFrame = pivot:ToObjectSpace(item.CFrame)
			table.insert(offsets, offset)
		end
	end
	model.Parent = fxFolder()
	return { model = model, parts = parts, sizes = sizes, offsets = offsets }
end

-- Plays one puff rig: grows from 20 % to `scale`, holds, fades, returns to the pool.
local function playPuff(rig: PuffRig, position: Vector3, scale: number)
	local still = reducedMotion()
	local grow = TweenInfo.new(0.55, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	local fade = TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, 0.9)
	local base = CFrame.new(position)
	local lastTween: Tween? = nil
	for index, part in rig.parts do
		local offset = rig.offsets[index]
		local size = rig.sizes[index]
		local finalCf = base * CFrame.new(offset.Position * scale) * offset.Rotation
		part.Transparency = 0
		if still then
			part.Size = size * scale
			part.CFrame = finalCf
		else
			part.Size = size * scale * 0.2
			part.CFrame = base * CFrame.new(offset.Position * scale * 0.2) * offset.Rotation
			TweenService:Create(part, grow, { Size = size * scale, CFrame = finalCf }):Play()
		end
		lastTween = TweenService:Create(part, fade, { Transparency = 1 })
		lastTween:Play()
	end
	if lastTween ~= nil then
		lastTween.Completed:Once(function()
			for _, part in rig.parts do
				part.CFrame = CFrame.new(0, -5000, 0)
			end
			table.insert(freePuffs, rig)
		end)
	end
end

--------------------------------------------------------------------------------------------------
-- Wobble + camera nudge (one shared step while active)
--------------------------------------------------------------------------------------------------

local function step()
	local clock = os.clock()
	local any = false
	for model, wobble in wobbles do
		local age = clock - wobble.start
		if model.Parent == nil then
			wobbles[model] = nil
		elseif age < 0 then
			-- Not started yet (the blast wave reaches farther buildings a moment later).
			any = true
		elseif age >= CLIENT.WobbleSeconds then
			-- Restore exactly (only if nothing else moved the model meanwhile).
			if model:GetPivot() == wobble.applied then
				model:PivotTo(wobble.base)
			end
			wobbles[model] = nil
		else
			any = true
			local k = age / CLIENT.WobbleSeconds
			local angle = math.rad(CLIENT.WobbleDegrees) * math.sin(k * math.pi * 5) * (1 - k)
			local applied = wobble.base * CFrame.fromAxisAngle(wobble.axis, angle)
			-- A model someone else moved (rebuild / build-in) is left alone.
			if model:GetPivot() ~= wobble.applied then
				wobbles[model] = nil
			else
				model:PivotTo(applied)
				wobble.applied = applied
			end
		end
	end
	if not any and stepConnection ~= nil then
		stepConnection:Disconnect()
		stepConnection = nil
	end
end

local function ensureStep()
	if stepConnection == nil then
		stepConnection = RunService.PreRender:Connect(step)
	end
end

local SHAKE_BINDING = "SN_AttackShake"
local shaking = false

-- Camera nudge: runs right after the default camera each frame (BindToRenderStep), then unbinds.
local function shakeStep()
	local clock = os.clock()
	local camera = Workspace.CurrentCamera
	if clock >= shakeUntil or camera == nil then
		shaking = false
		RunService:UnbindFromRenderStep(SHAKE_BINDING)
		return
	end
	local k = (clock - shakeStart) / math.max(shakeUntil - shakeStart, 0.01)
	local amp = 0.35 * (1 - k)
	camera.CFrame = camera.CFrame * CFrame.new(math.sin(clock * 47) * amp, math.cos(clock * 53) * amp, 0)
end

local function startShake(seconds: number)
	shakeStart = os.clock()
	shakeUntil = shakeStart + seconds
	if not shaking then
		shaking = true
		RunService:BindToRenderStep(SHAKE_BINDING, Enum.RenderPriority.Camera.Value + 1, shakeStep)
	end
end

-- Wobbles the plot's buildings near `position` (bounded count; skipped with Reduce Motion).
local function wobbleNear(plot: number, position: Vector3)
	local plots = Workspace:FindFirstChild("Plots")
	local plotModel = if plots ~= nil then plots:FindFirstChild(`Plot{plot}`) else nil
	if plotModel == nil then
		return
	end
	local count = 0
	local clock = os.clock()
	for _, area in plotModel:GetChildren() do
		local builds = if area:IsA("Model") then area:FindFirstChild("Builds") else nil
		if builds ~= nil then
			for _, model in builds:GetChildren() do
				if count >= CLIENT.MaxWobbleModels then
					return
				end
				if model:IsA("Model") and wobbles[model] == nil and model.PrimaryPart == nil then
					local pivot = model:GetPivot()
					local offset = pivot.Position - position
					local distance = Vector3.new(offset.X, 0, offset.Z).Magnitude
					if distance <= CLIENT.WobbleRadius then
						-- Tilt away from the blast (axis perpendicular to the blast direction).
						local flat = if distance > 0.5 then Vector3.new(offset.X, 0, offset.Z).Unit else Vector3.xAxis
						local up = Vector3.new(0, 1, 0)
						local axis = pivot:VectorToObjectSpace(up:Cross(flat))
						wobbles[model] = {
							model = model,
							base = pivot,
							start = clock + distance / 120,
							applied = pivot,
							axis = if axis.Magnitude > 0.01 then axis.Unit else Vector3.xAxis,
						}
						count += 1
					end
				end
			end
		end
	end
	if count > 0 then
		ensureStep()
	end
end

-- True when the local character stands within `radius` of `position`.
local function standingNear(position: Vector3, radius: number): boolean
	local character = Players.LocalPlayer.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	return root ~= nil and root:IsA("BasePart") and (root.Position - position).Magnitude <= radius
end

--------------------------------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------------------------------

--[[
	The confetti mushroom cloud of a hit (see the header).
	@param position Vector3 — impact point (ground)
	@param options ExplodeOptions?
]]
function AttackFx.explode(position: Vector3, options: ExplodeOptions?)
	local opts: ExplodeOptions = options or {}
	local scale = opts.scale or 1
	local rig = burst()
	rig.attachment.WorldPosition = position + Vector3.new(0, 6, 0)
	rig.confetti:Emit(math.floor(70 * scale))
	rig.sparkle:Emit(math.floor(30 * scale))
	rig.smoke:Emit(12)
	local puff = takePuff()
	if puff ~= nil then
		playPuff(puff, position, 1.4 * scale)
	end
	popText(position + Vector3.new(0, 34 * scale, 0), "BOOM!", Color3.fromRGB(255, 226, 60))
	sound("nuke_boom", position, 1, 1)
	if opts.mine then
		sound("cash_big", position, 1, 1)
	end
	if not reducedMotion() then
		if opts.plot ~= nil then
			wobbleNear(opts.plot, position)
		end
		if opts.onMe and standingNear(position, 160) then
			startShake(0.45)
		end
	end
end

--[[
	The mid-air "POP!" of an intercepted nuke.
	@param position Vector3
]]
function AttackFx.pop(position: Vector3)
	local rig = burst()
	rig.attachment.WorldPosition = position
	rig.confetti:Emit(30)
	rig.sparkle:Emit(24)
	rig.smoke:Emit(6)
	popText(position + Vector3.new(0, 10, 0), "POP!", Color3.fromRGB(120, 220, 255))
	sound("sparkle", position, 1.2, 0.9)
end

--[[
	A small smoke puff (launch blast, missed interceptor).
	@param position Vector3
	@param count number? — smoke particles (default 6)
	@param withSound boolean? — also a small "pop" (missed interceptors; launches have their own)
]]
function AttackFx.puff(position: Vector3, count: number?, withSound: boolean?)
	local rig = burst()
	rig.attachment.WorldPosition = position
	rig.smoke:Emit(count or 6)
	if withSound then
		sound("pop", position, 1.3, 0.5)
	end
end

return AttackFx
