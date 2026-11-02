--!strict
--[[
	ImpactBursts — pooled one-shot particle bursts for WorldFx impacts (owner R75: the Glow Rock
	miners' pick strikes throw rock chips + green glow sparkles).

	Pool: per burst kind (WorldFxConfig.Bursts), POOL Attachments under Workspace.Terrain, each with
	one "Chips" emitter (stud-square chips that hop out and fall, one colour per particle from the
	kind's palette) and one "Sparkles" emitter (soft glints). Built on the kind's first use, then only
	moved + Emit()-ed: no Instance.new after warm-up, nothing runs per frame here (owner perf rules).
	Soft by design (R19): sparkles use modest LightEmission, chips take scene lighting.

	Connects to: Shared/Config/{WorldFxConfig (Bursts), WorldMaterialConfig (stud texture)}; caller
	Tycoon/Fx/WorldFxController (impact events: on screen, in range, tier Bursts > 0, no Reduce Motion).

	Example:
		ImpactBursts.burst("rockChips", strikePoint, 1)   -- full-size burst (High tier)
		ImpactBursts.burst("rockChips", strikePoint, 0.7) -- Mid tier
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local WorldFxConfig = require(ReplicatedStorage.Shared.Config.WorldFxConfig)
local WorldMaterialConfig = require(ReplicatedStorage.Shared.Config.WorldMaterialConfig)

local ImpactBursts = {}

-- Attachments per kind: three miners can strike within one burst lifetime, so 3 never steals a
-- burst that is still in the air.
local POOL = 3
local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

type Slot = { attachment: Attachment, chips: ParticleEmitter, sparkles: ParticleEmitter }
type Pool = { slots: { Slot }, cursor: number, fx: WorldFxConfig.BurstFx }

local pools: { [string]: Pool } = {}

--[[
	A ColorSequence that gives each particle ONE colour of the palette (stepped keypoints: Roblox
	samples the sequence at a random point per particle).
]]
local function palette(colors: { Color3 }): ColorSequence
	if #colors == 1 then
		return ColorSequence.new(colors[1])
	end
	local points: { ColorSequenceKeypoint } = {}
	local count = #colors
	for i, color in colors do
		local t0 = (i - 1) / count
		local t1 = i / count
		table.insert(points, ColorSequenceKeypoint.new(t0, color))
		-- Hold the colour until just before the next band starts (a hard step, no blend).
		table.insert(points, ColorSequenceKeypoint.new(math.max(t0, t1 - 0.001), color))
	end
	points[#points] = ColorSequenceKeypoint.new(1, colors[count])
	return ColorSequence.new(points)
end

-- Builds one pooled slot for a burst kind (an Attachment + its two emitters, all disabled).
local function makeSlot(kind: string, index: number, fx: WorldFxConfig.BurstFx): Slot
	local attachment = Instance.new("Attachment")
	attachment.Name = `SN_Impact_{kind}{index}`

	local chips = Instance.new("ParticleEmitter")
	chips.Name = "Chips"
	chips.Enabled = false
	chips.Texture = `rbxassetid://{WorldMaterialConfig.Images.Color}`
	chips.Color = palette(fx.chipColors)
	chips.Lifetime = NumberRange.new(0.5, 0.85)
	chips.Speed = NumberRange.new(6, 11)
	chips.SpreadAngle = Vector2.new(55, 55)
	chips.EmissionDirection = Enum.NormalId.Top
	chips.Acceleration = Vector3.new(0, -40, 0)
	chips.Drag = 1.2
	chips.Rotation = NumberRange.new(0, 360)
	chips.RotSpeed = NumberRange.new(-300, 300)
	chips.Size = NumberSequence.new(fx.chipSize)
	chips.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.75, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	chips.LightInfluence = 0.8
	chips.Parent = attachment

	local sparkles = Instance.new("ParticleEmitter")
	sparkles.Name = "Sparkles"
	sparkles.Enabled = false
	sparkles.Texture = SPARKLE_TEXTURE
	sparkles.Color = ColorSequence.new(fx.sparkleColor)
	sparkles.Lifetime = NumberRange.new(0.35, 0.6)
	sparkles.Speed = NumberRange.new(3, 7)
	sparkles.SpreadAngle = Vector2.new(80, 80)
	sparkles.EmissionDirection = Enum.NormalId.Top
	sparkles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.9),
		NumberSequenceKeypoint.new(1, 0),
	})
	sparkles.LightEmission = 0.6
	sparkles.LightInfluence = 0
	sparkles.Parent = attachment

	attachment.Parent = Workspace.Terrain
	return { attachment = attachment, chips = chips, sparkles = sparkles }
end

--[[
	One-shot burst at a world position.
	@param kind string      WorldFxConfig.Bursts key (unknown kinds are ignored)
	@param position Vector3
	@param scale number     count multiplier (the tier's Bursts; <= 0 = nothing)
]]
function ImpactBursts.burst(kind: string, position: Vector3, scale: number)
	if scale <= 0 then
		return
	end
	local fx = WorldFxConfig.Bursts[kind]
	if fx == nil then
		return
	end
	local pool = pools[kind]
	if pool == nil then
		local slots: { Slot } = {}
		for i = 1, POOL do
			slots[i] = makeSlot(kind, i, fx)
		end
		pool = { slots = slots, cursor = 1, fx = fx }
		pools[kind] = pool
	end
	local current = pool :: Pool
	local slot = current.slots[current.cursor]
	current.cursor = current.cursor % POOL + 1
	slot.attachment.WorldPosition = position
	local chips = math.floor(fx.chips * scale + 0.5)
	local sparkles = math.floor(fx.sparkles * scale + 0.5)
	if chips > 0 then
		slot.chips:Emit(chips)
	end
	if sparkles > 0 then
		slot.sparkles:Emit(sparkles)
	end
end

-- Debug / verification: burst kinds built so far and their pool sizes.
function ImpactBursts.stats(): { [string]: number }
	local out: { [string]: number } = {}
	for kind, pool in pools do
		out[kind] = #pool.slots
	end
	return out
end

return ImpactBursts
