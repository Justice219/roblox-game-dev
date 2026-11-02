--!strict
--[[
	Fireworks — pooled cartoon toy fireworks (owner R71 juice): area unlocks, rebirths and the finale
	statue. Each rocket whistles up on a sparkly trail, then pops into a soft candy-coloured spark
	ball. Kid-friendly: no bangs, no flashes (owner R19: modest LightEmission).

	Pool: JuiceConfig.Fireworks.Pool rockets, each one Attachment under Workspace.Terrain with a
	"Trail" emitter (on while rising) and a "Burst" emitter (Emit at the apex). Built on first use;
	afterwards a show only moves attachments, toggles the trail and Emits — no Instance.new.
	A show only queues rockets; the juice pass's ONE Heartbeat (Fx/JuiceLoop) calls
	Fireworks.step(now), which moves the rising rockets (a handful of WorldPosition writes) and pops
	them on time; the Heartbeat disconnects once every rocket popped.

	Reduce Motion: callers skip shows (JuiceController plays a plain sparkle burst + the pop instead).

	Connects to: Shared/Config/JuiceConfig (Fireworks), Client/Tycoon/Fx/{JuiceRules (plans),
	JuiceLoop, FxSound}, caller JuiceController.

	Example:
		Fireworks.show(areaTop, 4) -- then JuiceController steps it
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local FxSound = require(script.Parent.FxSound)
local JuiceConfig = require(ReplicatedStorage.Shared.Config.JuiceConfig)
local JuiceLoop = require(script.Parent.JuiceLoop)
local JuiceRules = require(script.Parent.JuiceRules)

local Fireworks = {}

local Config = JuiceConfig.Fireworks
local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

type Rocket = {
	host: Attachment,
	trail: ParticleEmitter,
	burst: ParticleEmitter,
	live: boolean,
	launched: boolean,
	startAt: number,
	rise: number,
	from: Vector3,
	to: Vector3,
	hue: number,
	sparks: number,
}

local rockets: { Rocket } = {}
local serial = 0

-- Builds one pooled rocket.
local function makeRocket(index: number): Rocket
	local host = Instance.new("Attachment")
	host.Name = `SN_Firework{index}`
	host.Parent = Workspace.Terrain
	local trail = Instance.new("ParticleEmitter")
	trail.Name = "Trail"
	trail.Enabled = false
	trail.Texture = SPARKLE_TEXTURE
	trail.Color = ColorSequence.new(Color3.fromRGB(255, 236, 170), Color3.fromRGB(255, 190, 120))
	trail.Rate = 45
	trail.Lifetime = NumberRange.new(0.3, 0.55)
	trail.Speed = NumberRange.new(0.5, 2)
	trail.SpreadAngle = Vector2.new(180, 180)
	trail.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.7),
		NumberSequenceKeypoint.new(1, 0),
	})
	trail.LightEmission = 0.5
	trail.LightInfluence = 0
	trail.Parent = host
	local burst = Instance.new("ParticleEmitter")
	burst.Name = "Burst"
	burst.Enabled = false
	burst.Texture = SPARKLE_TEXTURE
	burst.Lifetime = NumberRange.new(0.9, 1.4)
	burst.Speed = NumberRange.new(15, 23)
	burst.SpreadAngle = Vector2.new(180, 180)
	burst.Drag = 2.2
	burst.Acceleration = Vector3.new(0, -9, 0)
	burst.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.3),
		NumberSequenceKeypoint.new(0.7, 0.9),
		NumberSequenceKeypoint.new(1, 0),
	})
	burst.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.75, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	burst.LightEmission = 0.6
	burst.LightInfluence = 0
	burst.Parent = host
	return {
		host = host,
		trail = trail,
		burst = burst,
		live = false,
		launched = false,
		startAt = 0,
		rise = 1,
		from = Vector3.zero,
		to = Vector3.zero,
		hue = 0,
		sparks = 0,
	}
end

-- A free rocket (built on first use), or nil when the whole pool is in the air.
local function freeRocket(): Rocket?
	for _, rocket in rockets do
		if not rocket.live then
			return rocket
		end
	end
	if #rockets < Config.Pool then
		local rocket = makeRocket(#rockets + 1)
		table.insert(rockets, rocket)
		return rocket
	end
	return nil
end

--[[
	Queues a show of `count` rockets around `center` (launch points spread, heights and colours
	varied by a per-show seed). Skipped beyond Config.MaxDistance of the camera.
	@param center ground point the rockets launch around
	@param count rockets (capped by the free pool)
	@param sparks sparks per pop (FxQuality tier budget)
	@return how many rockets were queued
]]
function Fireworks.show(center: Vector3, count: number, sparks: number): number
	local camera = Workspace.CurrentCamera
	if camera == nil or (camera.CFrame.Position - center).Magnitude > Config.MaxDistance then
		return 0
	end
	serial += 1
	local now = os.clock()
	local queued = 0
	for index = 1, count do
		local rocket = freeRocket()
		if rocket == nil then
			break
		end
		local dx, dz, height, rise, delay, hue = JuiceRules.fireworkPlan(serial * 13, index)
		rocket.live = true
		rocket.launched = false
		rocket.startAt = now + delay
		rocket.rise = rise
		rocket.from = center + Vector3.new(dx, 0, dz)
		rocket.to = rocket.from + Vector3.new(dx * 0.25, height, dz * 0.25)
		rocket.hue = hue
		rocket.sparks = sparks
		queued += 1
	end
	if queued > 0 then
		JuiceLoop.wake()
	end
	return queued
end

--[[
	Advances every rocket in the air (Fx/JuiceLoop's Heartbeat).
	@param now os.clock()
	@return true while any rocket is still queued / rising
]]
function Fireworks.step(now: number): boolean
	local any = false
	for _, rocket in rockets do
		if not rocket.live then
			continue
		end
		local age = now - rocket.startAt
		if age < 0 then
			any = true
			continue
		end
		if not rocket.launched then
			rocket.launched = true
			rocket.host.WorldPosition = rocket.from
			rocket.trail.Enabled = true
			FxSound.play(Config.WhistleSound, rocket.from, { volume = Config.WhistleVolume })
		end
		local k = age / rocket.rise
		if k >= 1 then
			-- Pop: candy-coloured spark ball at the apex.
			rocket.trail.Enabled = false
			rocket.host.WorldPosition = rocket.to
			local color = Color3.fromHSV(rocket.hue, 0.55, 1)
			rocket.burst.Color = ColorSequence.new(color, Color3.fromRGB(255, 255, 255))
			rocket.burst:Emit(rocket.sparks)
			FxSound.play(Config.PopSound, rocket.to, { volume = Config.PopVolume })
			rocket.live = false
		else
			-- Ease-out climb (fast off the ground, slowing at the top like a real toy rocket).
			local e = 1 - (1 - k) * (1 - k)
			rocket.host.WorldPosition = rocket.from:Lerp(rocket.to, e)
			any = true
		end
	end
	return any
end

--[[ Builds the whole rocket pool up front (JuiceController.Start, deferred). ]]
function Fireworks.prewarm()
	while #rockets < Config.Pool do
		table.insert(rockets, makeRocket(#rockets + 1))
	end
end

--[[ Rockets currently queued / rising (Studio probes). ]]
function Fireworks.live(): number
	local count = 0
	for _, rocket in rockets do
		if rocket.live then
			count += 1
		end
	end
	return count
end

JuiceLoop.add("Fireworks", Fireworks.step)

return Fireworks
