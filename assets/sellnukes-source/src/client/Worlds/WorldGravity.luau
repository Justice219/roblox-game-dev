--!strict
--[[
	WorldGravity — the per-world gravity twist on the client (owner R70: "a space world" — Moon Base
	has low gravity) plus its landing feedback: a soft "boing" and a moon-dust puff.

	Purpose:
		While the player's CurrentWorld (server Player attribute, WorldService) is a world with a
		`WorldClientConfig.Physics[worldId].gravityScale` row, Workspace.Gravity = the place's
		default x that scale; everywhere else it is the default. Any world may set a row (data, not
		code: spec §18 "add a world = add config + art"). Re-evaluated on every world change, every
		respawn, a New Player Mode swap (NewPlayerMode attribute) and a fresh profile snapshot, and
		put back when the player object goes away. Always computed from the default captured at
		start, so re-applying never compounds.

	Why the client: the player's own character is client-simulated (network owner), so a local
	Workspace.Gravity changes exactly their jumps; the server's value (and every other client)
	stays untouched, and nothing server-side reads gravity. Server reach checks tolerate the
	higher, slower jumps (touch / prompt based, or a vertical allowance above the ~19-stud apex;
	docs/tycoon-client.md "Low gravity").

	Landing feedback (low-gravity worlds only, GravityLogic.landing): touching down faster than
	WorldGravityConfig.Landing.MinFallSpeed plays `moon_boing` (2D, own landing; pitch rises with
	the fall) and emits a dust ring from ONE pooled ParticleEmitter at the feet (count by fall
	speed, halved on the Low FX tier). Reduce Motion keeps the sound and skips the puff. An
	unknown sound key (not uploaded / not in AudioConfig yet) is skipped silently.

	Happy Hour event gravity (owner R89 "Low-Gravity Hour", Client/HappyHour/HappyHourClient):
	`setEvent(worldId, multiplier, glideFallSpeed)` multiplies that world's scale by `multiplier`
	while the event is live (clamped to WorldGravityConfig.Limits; tests/happy-hours.luau proves the
	apex stays inside the server reach checks) and caps the falling speed at `glideFallSpeed`
	studs/s inside the existing fall sampler (a feather-soft descent that never raises the apex).
	`setEvent(nil, 1)` puts everything back. Recomputed from the default like every other change.

	Performance: event-driven. The only per-frame work is one Heartbeat connection that exists
	ONLY while the character is falling in a low-gravity world (it samples the root's downward
	speed); it disconnects on touchdown. The emitter is built once, on the first landing.

	Connects to: Shared/Config/{WorldClientConfig (Physics rows), WorldGravityConfig, AudioConfig,
	Worlds/WorldsConfig}, Client/Worlds/GravityLogic, Client/Audio/Sound, Client/Tycoon/Fx/FxQuality,
	Client/ClientState (reduced-motion setting). Started by Client/Worlds/WorldClient.Start.

	Example:
		WorldGravity.start()
		print(WorldGravity.scale(), workspace.Gravity) --> 0.4  78.48 (in Moon Base)
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local AudioConfig = require(ReplicatedStorage.Shared.Config.AudioConfig)
local ClientState = require(script.Parent.Parent.ClientState)
local Config = require(ReplicatedStorage.Shared.Config.WorldGravityConfig)
local FxQuality = require(script.Parent.Parent.Tycoon.Fx.FxQuality)
local GravityLogic = require(script.Parent.GravityLogic)
local Sound = require(script.Parent.Parent.Audio.Sound)
local WorldClientConfig = require(ReplicatedStorage.Shared.Config.WorldClientConfig)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local WorldGravity = {}

-- Server Player attributes this module follows.
local CURRENT_ATTR = "CurrentWorld"
local NEW_PLAYER_ATTR = "NewPlayerMode"

local localPlayer = Players.LocalPlayer
local started = false
local defaultGravity = 196.2 -- replaced by the place's own value at start
local scale = 1 -- the applied multiplier
local worldApplied = WorldsConfig.MAIN
-- R89 Happy Hour event gravity (setEvent): the world it applies to, its extra multiplier and the
-- fall-speed cap of the glide (0 = no glide).
local eventWorld: string? = nil
local eventScale = 1
local glideSpeed = 0

-- Landing tracking (own character only).
local humanoid: Humanoid? = nil
local root: BasePart? = nil
local stateConnection: RBXScriptConnection? = nil
local fallConnection: RBXScriptConnection? = nil
local falling = false
local peakFall = 0 -- largest downward speed (studs/s) seen during the current fall
local landings = 0 -- landings with feedback (verification)
local puffs = 0 -- landings that emitted dust (not Reduce Motion; verification)

-- The pooled dust emitter (client-only Attachment under Workspace.Terrain).
local puffPoint: Attachment? = nil
local puffEmitter: ParticleEmitter? = nil

-- The world the player is in (registered id; "main" before the attribute exists).
local function currentWorld(): string
	local value = localPlayer:GetAttribute(CURRENT_ATTR)
	return if type(value) == "string" and WorldsConfig.get(value) ~= nil then value else WorldsConfig.MAIN
end

-- Reduce Motion: Roblox's own setting OR SellNukes' profile setting.
local function reducedMotion(): boolean
	if GuiService.ReducedMotionEnabled then
		return true
	end
	local profile = ClientState.profile
	local settings = if profile ~= nil then profile.settings else nil
	return type(settings) == "table" and (settings :: any).reducedMotion == true
end

-- Stops sampling the fall (touchdown, death, a world without landing feedback).
local function stopFall()
	falling = false
	peakFall = 0
	local connection = fallConnection
	if connection ~= nil then
		connection:Disconnect()
		fallConnection = nil
	end
end

-- Builds the dust emitter once (first landing).
local function ensurePuff(): ParticleEmitter
	local existing = puffEmitter
	if existing ~= nil and existing.Parent ~= nil then
		return existing
	end
	local puff = Config.Puff
	local point = Instance.new("Attachment")
	point.Name = "SN_MoonDustPoint"
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "SN_MoonDust"
	emitter.Texture = puff.Texture
	emitter.Color = ColorSequence.new(puff.Color)
	emitter.Enabled = false -- Emit() only
	emitter.Rate = 0
	emitter.Lifetime = puff.Lifetime
	emitter.Speed = puff.Speed
	emitter.Drag = puff.Drag
	emitter.SpreadAngle = Vector2.new(puff.SpreadDeg, puff.SpreadDeg)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Acceleration = Vector3.new(0, puff.Rise, 0)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, puff.SizeStart),
		NumberSequenceKeypoint.new(1, puff.SizeEnd),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, puff.TransparencyStart),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.RotSpeed = NumberRange.new(-40, 40)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.LightInfluence = 0.8
	emitter.Parent = point
	point.Parent = Workspace.Terrain
	puffPoint = point
	puffEmitter = emitter
	return emitter
end

-- The ground point under the character's feet (R15: HipHeight; R6: legs are 2 studs).
local function feetOf(body: BasePart, hum: Humanoid): Vector3
	local legs = if hum.RigType == Enum.HumanoidRigType.R6 then 2 else hum.HipHeight
	return body.Position - Vector3.new(0, body.Size.Y / 2 + legs, 0)
end

-- One touchdown at `speed` (studs/s): boing + dust puff when GravityLogic says so.
local function land(speed: number)
	local play, pitch, count = GravityLogic.landing(speed, scale, Config.Landing, Config.Puff)
	if not play then
		return
	end
	landings += 1
	local landing = Config.Landing
	-- Silent fallback while the key is not in AudioConfig yet (Sound.play would warn once).
	if AudioConfig.Sfx[landing.Sound] ~= nil then
		Sound.play(landing.Sound, { pitch = pitch, volume = landing.Volume })
	end
	local body, hum = root, humanoid
	if reducedMotion() or body == nil or hum == nil or body.Parent == nil then
		return
	end
	if FxQuality.tier() == "Low" then
		count = math.max(1, math.floor(count * Config.Puff.LowTierScale))
	end
	local emitter = ensurePuff()
	local point = puffPoint
	if point ~= nil then
		point.WorldPosition = feetOf(body, hum)
		emitter:Emit(count)
		puffs += 1
	end
end

-- Heartbeat while falling: remember the fastest downward speed (= the impact speed).
local function sampleFall()
	local body = root
	if body == nil or body.Parent == nil then
		stopFall()
		return
	end
	local velocity = body.AssemblyLinearVelocity
	local down = -velocity.Y
	-- R89 Low-Gravity Hour glide: cap the descent (own, client-simulated character only; the
	-- ascent and so the apex are untouched).
	if glideSpeed > 0 and eventWorld == worldApplied and down > glideSpeed then
		body.AssemblyLinearVelocity = Vector3.new(velocity.X, -glideSpeed, velocity.Z)
		down = glideSpeed
	end
	if down > peakFall then
		peakFall = down
	end
end

-- Humanoid states: Freefall starts sampling (low-gravity worlds only), Landed plays the feedback.
local function onState(_old: Enum.HumanoidStateType, new: Enum.HumanoidStateType)
	if new == Enum.HumanoidStateType.Freefall then
		if scale < Config.Landing.FxBelowScale and fallConnection == nil then
			falling = true
			peakFall = 0
			fallConnection = RunService.Heartbeat:Connect(sampleFall)
		end
	elseif new == Enum.HumanoidStateType.Landed then
		local speed = peakFall
		local wasFalling = falling
		stopFall()
		if wasFalling then
			land(speed)
		end
	elseif new ~= Enum.HumanoidStateType.Jumping then
		-- Swimming / climbing / dead / seated: that fall never touched down.
		stopFall()
	end
end

-- A (re)spawned character: hook its humanoid's states (one connection per character).
local function onCharacter(character: Model?)
	stopFall()
	local connection = stateConnection
	if connection ~= nil then
		connection:Disconnect()
		stateConnection = nil
	end
	humanoid, root = nil, nil
	if character == nil then
		return
	end
	task.spawn(function()
		local hum = character:WaitForChild("Humanoid", 10)
		local body = character:WaitForChild("HumanoidRootPart", 10)
		if hum == nil or body == nil or not hum:IsA("Humanoid") or not body:IsA("BasePart") then
			return
		end
		if localPlayer.Character ~= character then
			return -- respawned again meanwhile
		end
		humanoid, root = hum, body
		stateConnection = hum.StateChanged:Connect(onState)
	end)
end

--[[
	Re-evaluates the gravity for the world the player is in (idempotent; called on every world
	change / respawn / New Player Mode swap / profile snapshot). Writes Workspace.Gravity only
	when the target changed.
	@return the applied scale
]]
function WorldGravity.refresh(): number
	local worldId = currentWorld()
	local physics = (WorldClientConfig :: any).Physics
	local target = GravityLogic.scaleFor(physics, worldId, Config.Limits)
	-- R89 Happy Hour event gravity on top of the world's own scale (clamped like any scale).
	if eventWorld == worldId and eventScale ~= 1 then
		target = math.clamp(target * eventScale, Config.Limits.MinScale, Config.Limits.MaxScale)
	end
	worldApplied = worldId
	scale = target
	local gravity = GravityLogic.gravity(defaultGravity, target)
	if Workspace.Gravity ~= gravity then
		Workspace.Gravity = gravity
	end
	if target >= Config.Landing.FxBelowScale then
		stopFall()
	end
	return target
end

--[[
	R89 Happy Hours (Low-Gravity Hour): sets / clears the event gravity of one world and
	re-applies. `multiplier` scales that world's own gravity scale (a junk value = 1);
	`glideFallSpeed` (studs/s, nil / <= 0 = none) caps the falling speed while in that world.
	@return the applied scale
	Example:
		WorldGravity.setEvent("moon", 0.9, 18) -- Low-Gravity Hour starts
		WorldGravity.setEvent(nil, 1)          -- it ended
]]
function WorldGravity.setEvent(worldId: string?, multiplier: number, glideFallSpeed: number?): number
	local valid = worldId ~= nil and WorldsConfig.get(worldId) ~= nil
	local factor = if multiplier == multiplier and multiplier > 0 and multiplier < math.huge then multiplier else 1
	local glide = glideFallSpeed
	eventWorld = if valid then worldId else nil
	eventScale = if valid then factor else 1
	glideSpeed = if valid and glide ~= nil and glide == glide and glide > 0 and glide < math.huge then glide else 0
	return WorldGravity.refresh()
end

--[[ The gravity scale applied right now (1 = normal). ]]
function WorldGravity.scale(): number
	return scale
end

--[[ Verification counters (Studio QA): world, scale, gravity, default, falling, landings, puffs. ]]
function WorldGravity.stats(): { [string]: any }
	return {
		world = worldApplied,
		scale = scale,
		gravity = Workspace.Gravity,
		default = defaultGravity,
		falling = falling,
		landings = landings,
		puffs = puffs,
		-- R89 Happy Hour event gravity (setEvent).
		eventWorld = eventWorld,
		eventScale = eventScale,
		glide = glideSpeed,
	}
end

--[[
	Starts the controller (idempotent; Client/Worlds/WorldClient.Start calls it). Captures the
	place's default gravity first, so every later value is default x scale.
]]
function WorldGravity.start()
	if started then
		return
	end
	started = true
	defaultGravity = Workspace.Gravity
	local function reapply()
		WorldGravity.refresh()
	end
	localPlayer:GetAttributeChangedSignal(CURRENT_ATTR):Connect(reapply)
	localPlayer:GetAttributeChangedSignal(NEW_PLAYER_ATTR):Connect(reapply)
	localPlayer.CharacterAdded:Connect(function(character: Model)
		WorldGravity.refresh()
		onCharacter(character)
	end)
	localPlayer.CharacterRemoving:Connect(function()
		onCharacter(nil)
	end)
	-- A fresh snapshot (New Player Mode swap, reconnect) re-checks where we are.
	ClientState.ProfileChanged:Connect(function(_profile, fields: { string }?)
		if fields == nil then
			WorldGravity.refresh()
		end
	end)
	-- Leaving (the player object goes away): put the place's gravity back.
	localPlayer.AncestryChanged:Connect(function(_, parent: Instance?)
		if parent == nil then
			stopFall()
			Workspace.Gravity = defaultGravity
			scale = 1
		end
	end)
	WorldGravity.refresh()
	onCharacter(localPlayer.Character)
end

return WorldGravity
