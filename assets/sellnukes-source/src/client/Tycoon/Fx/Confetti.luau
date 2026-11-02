--!strict
--[[
	Confetti — pooled one-shot confetti + sparkle bursts (build-in finale, area unlock fanfare).

	Three burst emitters (Attachments under Workspace.Terrain, each with a "Confetti" and a "Sparkle"
	ParticleEmitter, Enabled = false) are created once; burst() moves the next one to the position
	and calls Emit — zero Instance.new after warm-up, no per-frame work.

	Look: confetti = little stud squares (the world stud colour map, tinted in candy colours) that
	pop up and tumble down; sparkle = Roblox's built-in sparkle texture. Camera-safe: modest light
	emission, no screen flashes, bursts happen at the build, never at the camera.

	Example:
		Confetti.burst(model:GetPivot().Position + Vector3.new(0, 6, 0), 40, 20)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldMaterialConfig = require(ReplicatedStorage.Shared.Config.WorldMaterialConfig)

local Confetti = {}

local EMITTERS = 3
local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
-- Candy colours (match snkit.core palette) for the confetti squares.
local CONFETTI_COLORS = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(232, 64, 56)),
	ColorSequenceKeypoint.new(0.2, Color3.fromRGB(255, 206, 36)),
	ColorSequenceKeypoint.new(0.4, Color3.fromRGB(98, 204, 70)),
	ColorSequenceKeypoint.new(0.6, Color3.fromRGB(96, 168, 236)),
	ColorSequenceKeypoint.new(0.8, Color3.fromRGB(150, 96, 220)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 120, 180)),
})

type Burst = { attachment: Attachment, confetti: ParticleEmitter, sparkle: ParticleEmitter }

local bursts: { Burst } = {}
local nextBurst = 1

local function makeBurst(index: number): Burst
	local attachment = Instance.new("Attachment")
	attachment.Name = `SN_Confetti{index}`
	attachment.Parent = workspace.Terrain

	local confetti = Instance.new("ParticleEmitter")
	confetti.Name = "Confetti"
	confetti.Enabled = false
	confetti.Texture = `rbxassetid://{WorldMaterialConfig.Images.Color}`
	-- Colour sampled per particle across the sequence (each square gets one candy colour).
	confetti.Color = CONFETTI_COLORS
	confetti.Lifetime = NumberRange.new(1.3, 2.1)
	confetti.Speed = NumberRange.new(16, 28)
	confetti.SpreadAngle = Vector2.new(38, 38)
	confetti.EmissionDirection = Enum.NormalId.Top
	confetti.Acceleration = Vector3.new(0, -34, 0)
	confetti.Drag = 1.6
	confetti.Rotation = NumberRange.new(0, 360)
	confetti.RotSpeed = NumberRange.new(-260, 260)
	confetti.Size = NumberSequence.new(0.42)
	confetti.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.8, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	confetti.Orientation = Enum.ParticleOrientation.VelocityPerpendicular
	confetti.LightInfluence = 0.6
	confetti.Parent = attachment

	local sparkle = Instance.new("ParticleEmitter")
	sparkle.Name = "Sparkle"
	sparkle.Enabled = false
	sparkle.Texture = SPARKLE_TEXTURE
	sparkle.Color = ColorSequence.new(Color3.fromRGB(255, 244, 180), Color3.fromRGB(200, 255, 170))
	sparkle.Lifetime = NumberRange.new(0.5, 0.9)
	sparkle.Speed = NumberRange.new(4, 10)
	sparkle.SpreadAngle = Vector2.new(180, 180)
	sparkle.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.1),
		NumberSequenceKeypoint.new(1, 0),
	})
	sparkle.LightEmission = 0.7
	sparkle.LightInfluence = 0
	sparkle.Parent = attachment

	return { attachment = attachment, confetti = confetti, sparkle = sparkle }
end

--[[
	One-shot burst at a world position.
	@param position Vector3
	@param confettiCount number  stud squares (0 = none)
	@param sparkleCount number   sparkles (0 = none)
]]
function Confetti.burst(position: Vector3, confettiCount: number, sparkleCount: number)
	if #bursts == 0 then
		for i = 1, EMITTERS do
			bursts[i] = makeBurst(i)
		end
	end
	local burst = bursts[nextBurst]
	nextBurst = nextBurst % EMITTERS + 1
	burst.attachment.WorldPosition = position
	if confettiCount > 0 then
		burst.confetti:Emit(confettiCount)
	end
	if sparkleCount > 0 then
		burst.sparkle:Emit(sparkleCount)
	end
end

return Confetti
