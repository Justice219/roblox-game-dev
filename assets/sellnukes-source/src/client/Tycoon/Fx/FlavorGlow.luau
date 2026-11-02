--!strict
--[[
	FlavorGlow — the Rainbow+ producer glow every player in the world can see (owner R89 Surprise
	Batches, spec §1): a soft coloured light + drifting sparkles over the producer for
	FlavorConfig.Glow.Seconds (Rainbow cycles through the rainbow; Galaxy / Mystery keep their
	colour). Server FlavorGlow (unreliable, per-producer server cooldown) → FlavorController → here.

	Performance:
		- POOLED: FlavorConfig.Glow.Pool rigs (an Attachment under Workspace.Terrain with a PointLight
		  + a sparkle ParticleEmitter), built on first use; a glow only moves an attachment and
		  toggles / tints — no Instance.new afterwards. A busy pool recycles the oldest glow.
		- Animated by the juice pass's ONE Heartbeat (Fx/JuiceLoop): a step that only runs while a
		  glow is live (fade in / out + Rainbow hue), then the loop disconnects.
		- Glows farther than Glow.MaxDistance from the camera are skipped.
	Owner R19 light caps: Brightness <= 0.6, Range <= 10, no shadows (tests/glow-budget.luau rules).
	Look: the capped light, drifting sparkles and a soft rotating halo (big translucent sparkles that
	stay put) so it reads in daylight without any bright flash.
	Reduce Motion: the light + the halo only (no drifting sparkles).

	Connects to: Fx/{JuiceLoop, FxQuality, FxSound, JuiceRules}, UI/Widgets/OfferFx (Reduce Motion),
	Shared/Config/FlavorConfig, caller Tycoon/FlavorController.

	Example: FlavorGlow.show(anchor, FlavorConfig.byId("rainbow"))
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local FlavorConfig = require(ReplicatedStorage.Shared.Config.FlavorConfig)
local FxQuality = require(script.Parent.FxQuality)
local FxSound = require(script.Parent.FxSound)
local JuiceLoop = require(script.Parent.JuiceLoop)
local JuiceRules = require(script.Parent.JuiceRules)
local OfferFx = require(script.Parent.Parent.Parent.UI.Widgets.OfferFx)

local Config = FlavorConfig.Glow
local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local FADE = 0.35 -- seconds of fade in / out at each end
local RISE = 2.5 -- studs above the producer anchor

type Rig = {
	host: Attachment,
	light: PointLight,
	sparkle: ParticleEmitter,
	aura: ParticleEmitter,
	live: boolean,
	startAt: number,
	untilAt: number,
	rainbow: boolean,
	color: Color3,
	anchor: BasePart?,
}

local FlavorGlow = {}

local rigs: { Rig } = {}
local liveCount = 0

-- Builds one pooled rig.
local function makeRig(index: number): Rig
	local host = Instance.new("Attachment")
	host.Name = `SN_FlavorGlow{index}`
	host.Parent = Workspace.Terrain
	local light = Instance.new("PointLight")
	light.Name = "Glow"
	light.Range = Config.LightRange
	light.Brightness = 0
	light.Shadows = false
	light.Enabled = false
	light.Parent = host
	local sparkle = Instance.new("ParticleEmitter")
	sparkle.Name = "Sparkle"
	sparkle.Texture = SPARKLE_TEXTURE
	sparkle.Enabled = false
	sparkle.Lifetime = NumberRange.new(1, 1.6)
	sparkle.Speed = NumberRange.new(3, 6)
	sparkle.SpreadAngle = Vector2.new(180, 180)
	sparkle.Acceleration = Vector3.new(0, 3, 0)
	sparkle.Drag = 1.5
	sparkle.LightEmission = 0.5
	sparkle.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.1),
		NumberSequenceKeypoint.new(1, 0),
	})
	sparkle.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	sparkle.Parent = host
	-- A soft pulsing halo (big, very transparent sparkles that stay put): readable in daylight
	-- where a capped PointLight alone is barely visible, without any bright flash.
	local aura = Instance.new("ParticleEmitter")
	aura.Name = "Aura"
	aura.Texture = SPARKLE_TEXTURE
	aura.Enabled = false
	aura.Rate = 7
	aura.Lifetime = NumberRange.new(0.7, 1)
	aura.Speed = NumberRange.new(0, 0)
	aura.LockedToPart = true
	aura.Rotation = NumberRange.new(0, 360)
	aura.RotSpeed = NumberRange.new(-60, 60)
	aura.LightEmission = 0.4
	aura.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 3.5),
		NumberSequenceKeypoint.new(1, 5.5),
	})
	aura.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(1, 1),
	})
	aura.Parent = host
	return {
		host = host,
		light = light,
		sparkle = sparkle,
		aura = aura,
		live = false,
		startAt = 0,
		untilAt = 0,
		rainbow = false,
		color = Color3.new(1, 1, 1),
		anchor = nil,
	}
end

-- The rig already glowing over this anchor, else a free one, else the one ending soonest.
local function rigFor(anchor: BasePart): Rig
	if #rigs == 0 then
		for index = 1, Config.Pool do
			table.insert(rigs, makeRig(index))
		end
	end
	local free: Rig? = nil
	local soonest = rigs[1]
	for _, rig in rigs do
		if rig.live and rig.anchor == anchor then
			return rig
		end
		if not rig.live and free == nil then
			free = rig
		end
		if rig.untilAt < soonest.untilAt then
			soonest = rig
		end
	end
	return free or soonest
end

-- Switches a rig off.
local function stop(rig: Rig)
	if rig.live then
		liveCount -= 1
	end
	rig.live = false
	rig.anchor = nil
	rig.light.Enabled = false
	rig.sparkle.Enabled = false
	rig.aura.Enabled = false
end

-- The juice Heartbeat step: fades + Rainbow hue; true while any glow is live.
local function step(now: number): boolean
	if liveCount <= 0 then
		return false
	end
	for _, rig in rigs do
		if not rig.live then
			continue
		end
		if now >= rig.untilAt or rig.anchor == nil or rig.anchor.Parent == nil then
			stop(rig)
			continue
		end
		local fadeIn = math.clamp((now - rig.startAt) / FADE, 0, 1)
		local fadeOut = math.clamp((rig.untilAt - now) / FADE, 0, 1)
		rig.light.Brightness = Config.LightBrightness * math.min(fadeIn, fadeOut)
		if rig.rainbow then
			local hue = (now * Config.HueSpeed) % 1
			local color = Color3.fromHSV(hue, 0.55, 1)
			rig.light.Color = color
			rig.sparkle.Color = ColorSequence.new(color)
			rig.aura.Color = rig.sparkle.Color
		end
	end
	return liveCount > 0
end

JuiceLoop.add("FlavorGlow", step)

--[[
	Glows one producer anchor (anyone's) in the flavour's colour for Glow.Seconds; a repeat on the
	same anchor extends it.
	@param anchor BasePart — a producer anchor (tag SNProducer; the caller checked)
	@param def FlavorConfig.FlavorDef — Rainbow+ (others are ignored)
]]
function FlavorGlow.show(anchor: BasePart, def: FlavorConfig.FlavorDef)
	if not def.glow then
		return
	end
	local camera = Workspace.CurrentCamera
	local position = anchor.Position + Vector3.new(0, RISE, 0)
	if camera == nil or (camera.CFrame.Position - position).Magnitude > Config.MaxDistance then
		return
	end
	local rig = rigFor(anchor)
	local now = os.clock()
	if not rig.live then
		liveCount += 1
		rig.startAt = now
	end
	rig.live = true
	rig.anchor = anchor
	rig.untilAt = now + Config.Seconds
	rig.rainbow = def.id == "rainbow"
	rig.color = def.color
	rig.host.WorldPosition = position
	rig.light.Color = def.color
	rig.light.Enabled = true
	rig.sparkle.Color = ColorSequence.new(def.color)
	rig.aura.Color = rig.sparkle.Color
	local rate = JuiceRules.perTier(Config.SparkleRate, FxQuality.tier())
	local moving = not OfferFx.reducedMotion()
	rig.sparkle.Rate = rate
	rig.sparkle.Enabled = moving
	rig.aura.Enabled = true -- a static halo is fine with Reduce Motion
	if moving then
		rig.sparkle:Emit(rate) -- an opening puff, then the steady drift
	end
	FxSound.play("star_chime", position, { volume = 0.8 })
	JuiceLoop.wake()
end

--[[ Live glows right now (Studio probes / captures). ]]
function FlavorGlow.live(): number
	return liveCount
end

return FlavorGlow
