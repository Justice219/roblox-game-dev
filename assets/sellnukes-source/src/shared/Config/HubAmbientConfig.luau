--!strict
--[[
	HubAmbientConfig — particle presets for the lobby centre's ambient motion (owner R55, L1-lobby):
	the toy-nuke fountain's water jets + splashes and the gold sparkles round the floating coins.

	Where the emitters go is layout data: HubLayout.anchors.AmbientFx = { { preset, cf } } (world
	CFrames). Server/World/HubBuilder builds ONE invisible holder part with an Attachment +
	ParticleEmitter per entry once the hub art exists; nothing runs per frame (Roblox simulates the
	particles, culls them off screen and thins them on low graphics quality by itself).

	Rules (owner R19 soft glows, R11 mobile first): LightEmission stays low, rates are small (the
	whole lobby is ~150 live particles), every texture is a built-in rbxasset shipped with the client
	(no upload, never moderated, nothing to stream).

	Spray matches the Blender water arcs (tools/blender/models/hub_plaza.py spout_arc): the arc rises
	at 0.75 (36.9°) and drops 12.8 * t² over 8.2 studs, i.e. a ballistic path with horizontal speed
	8.9 and gravity 30, so droplets ride the solid arc instead of flying off it.

	Example
		local preset = HubAmbientConfig.Presets.Spray
		emitter.Rate = preset.rate
]]

export type Preset = {
	texture: string,
	color: ColorSequence,
	size: NumberSequence,
	transparency: NumberSequence,
	lifetime: NumberRange,
	speed: NumberRange,
	rate: number,
	spread: Vector2,
	acceleration: Vector3,
	lightEmission: number,
	-- Attachment axis the particles leave along (Front = the anchor CFrame's LookVector).
	emission: Enum.NormalId,
}

local HubAmbientConfig = {}

-- Built-in particle textures (ship with every client).
local SPARKLE = "rbxasset://textures/particles/sparkles_main.dds"

-- Hard cap on hub emitters HubBuilder will create (a malformed layout can never spam emitters).
HubAmbientConfig.MaxEmitters = 48

-- Spray launch speed along the anchor's LookVector (sqrt(8.9² + 6.7²), see the header).
local SPRAY_SPEED = 11.1

local PRESETS: { [string]: Preset } = {
	-- Droplets riding each toy-nuke spout's water arc into the pool.
	Spray = {
		texture = SPARKLE,
		color = ColorSequence.new(Color3.fromRGB(235, 250, 255), Color3.fromRGB(140, 214, 255)),
		size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.42), NumberSequenceKeypoint.new(1, 0.18) }),
		transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.15),
			NumberSequenceKeypoint.new(0.8, 0.35),
			NumberSequenceKeypoint.new(1, 1),
		}),
		lifetime = NumberRange.new(0.85, 0.95),
		speed = NumberRange.new(SPRAY_SPEED - 0.4, SPRAY_SPEED + 0.4),
		rate = 9,
		spread = Vector2.new(3, 3),
		acceleration = Vector3.new(0, -30, 0),
		lightEmission = 0.15,
		emission = Enum.NormalId.Front,
	},
	-- Little splash where each arc lands.
	Splash = {
		texture = SPARKLE,
		color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(170, 226, 255)),
		size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0) }),
		transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) }),
		lifetime = NumberRange.new(0.35, 0.55),
		speed = NumberRange.new(3, 5),
		rate = 7,
		spread = Vector2.new(35, 35),
		acceleration = Vector3.new(0, -24, 0),
		lightEmission = 0.1,
		emission = Enum.NormalId.Top,
	},
	-- Soft gold twinkles round the floating coins and Nukey's coin halo.
	Sparkle = {
		texture = SPARKLE,
		color = ColorSequence.new(Color3.fromRGB(255, 236, 140), Color3.fromRGB(255, 190, 40)),
		size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.3, 0.55),
			NumberSequenceKeypoint.new(1, 0),
		}),
		transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) }),
		lifetime = NumberRange.new(0.9, 1.5),
		speed = NumberRange.new(0.6, 1.4),
		rate = 2.5,
		spread = Vector2.new(180, 180),
		acceleration = Vector3.new(0, 0.6, 0),
		lightEmission = 0.35,
		emission = Enum.NormalId.Top,
	},
}
HubAmbientConfig.Presets = PRESETS

return HubAmbientConfig
