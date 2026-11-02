--!strict
--[[
	HappyHourFx — the cosmetic layer of the Happy Hours (owner R89 §2, docs/happy-hours.md):

		CONFETTI STORM   a ring of cartoon clouds (the Blender `Scenery_Cloud` mesh) high over the
		                 player and a gentle confetti rain from them (ONE ParticleEmitter); the
		                 ring re-centres when the player wanders far (checked 2x per second, only
		                 while the storm runs). The coins themselves are HappyHourPickupsClient.
		DOUBLE POPS      every income pop over your producers pops TWICE: a second "+bonus" pop
		                 (the +25 % part, display only) drifts the other way, through the public
		                 Tycoon/IncomePops.show (IncomePops itself is untouched; the real money
		                 is the server's eventCash modifier and the profile sync).

	Performance: nothing exists until an event needs it; clouds / the emitter are built once and
	parked between storms; the storm follow-loop runs only during a storm; bonus pops are throttled
	per producer (Client.BonusPopGap) and skipped off screen. FxQuality "Low" halves the rain;
	Reduce Motion turns the rain off (the clouds stay, still).

	Connects to: Shared/Config/HappyHourConfig, Shared/Net/Remotes ("IncomePop", unreliable),
	Client/{Pets/PetModels, Tycoon/{IncomePops, ProducerBillboards, Fx/FxQuality},
	UI/{Create, Widgets/OfferFx}}, Shared/Config/WorldMaterialConfig (confetti texture).
	Driven by Client/HappyHour/HappyHourClient (setStorm / setDoublePops).

	Example:
		HappyHourFx.setStorm(true)       -- Confetti Storm started
		HappyHourFx.setDoublePops(1.25)  -- Double Pops started (1 = off)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Create = require(script.Parent.Parent.UI.Create)
local FxQuality = require(script.Parent.Parent.Tycoon.Fx.FxQuality)
local HappyHourConfig = require(ReplicatedStorage.Shared.Config.HappyHourConfig)
local IncomePops = require(script.Parent.Parent.Tycoon.IncomePops)
local OfferFx = require(script.Parent.Parent.UI.Widgets.OfferFx)
local PetModels = require(script.Parent.Parent.Pets.PetModels)
local ProducerBillboards = require(script.Parent.Parent.Tycoon.ProducerBillboards)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local WorldMaterialConfig = require(ReplicatedStorage.Shared.Config.WorldMaterialConfig)

local Client = HappyHourConfig.Client

local HappyHourFx = {}

-- Candy colours of the confetti squares (the Confetti burst palette).
local CONFETTI_COLORS = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(232, 64, 56)),
	ColorSequenceKeypoint.new(0.2, Color3.fromRGB(255, 206, 36)),
	ColorSequenceKeypoint.new(0.4, Color3.fromRGB(98, 204, 70)),
	ColorSequenceKeypoint.new(0.6, Color3.fromRGB(96, 168, 236)),
	ColorSequenceKeypoint.new(0.8, Color3.fromRGB(150, 96, 220)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 120, 180)),
})

local localPlayer = Players.LocalPlayer
local storm = false
local stormToken = 0
local clouds: { Model } = {}
local cloudsMeshed = false
local rainPart: Part? = nil
local rainEmitter: ParticleEmitter? = nil
local ringCentre: Vector3? = nil
local popMultiplier = 1
local popConnected = false
local lastBonus: { [string]: number } = {}
local bonusPops = 0

-- The character root position (else the camera's), or nil.
local function focusPosition(): Vector3?
	local character = localPlayer.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root ~= nil and root:IsA("BasePart") then
		return root.Position
	end
	local camera = Workspace.CurrentCamera
	return if camera ~= nil then camera.CFrame.Position else nil
end

-- Builds the cloud ring + rain emitter once (rebuilt once when the cloud mesh finishes loading).
local function ensureSky()
	local ready = PetModels.isMeshReady(Client.CloudKey)
	if #clouds > 0 and (cloudsMeshed or not ready) then
		return
	end
	for _, cloud in clouds do
		cloud:Destroy()
	end
	table.clear(clouds)
	cloudsMeshed = ready
	for index = 1, Client.CloudCount do
		local model = PetModels.fromKey(Client.CloudKey)
		if model == nil then
			break
		end
		model.Name = `SN_HappyCloud{index}`
		if Client.CloudScale ~= 1 then
			model:ScaleTo(Client.CloudScale)
		end
		for _, item in model:GetDescendants() do
			if item:IsA("BasePart") then
				item.Anchored = true
				item.CanCollide = false
				item.CanQuery = false
				item.CanTouch = false
				item.CastShadow = false
			end
		end
		table.insert(clouds, model)
	end
	if rainPart == nil then
		local part = Create.new("Part", {
			Name = "SN_HappyRain",
			Size = Vector3.new(Client.CloudRadius * 2, 1, Client.CloudRadius * 2),
			Transparency = 1,
			Anchored = true,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
			CastShadow = false,
		}) :: Part
		local emitter = Create.new("ParticleEmitter", {
			Name = "Confetti",
			Texture = `rbxassetid://{WorldMaterialConfig.Images.Color}`,
			Color = CONFETTI_COLORS,
			Enabled = false,
			Rate = Client.ConfettiRate,
			Lifetime = NumberRange.new(5, 7),
			Speed = NumberRange.new(10, 16),
			SpreadAngle = Vector2.new(12, 12),
			EmissionDirection = Enum.NormalId.Bottom,
			Acceleration = Vector3.new(0, -2, 0),
			Drag = 0.4,
			Size = NumberSequence.new(0.45),
			RotSpeed = NumberRange.new(-220, 220),
			Rotation = NumberRange.new(0, 360),
			LightEmission = 0.15,
			LightInfluence = 0.6,
			Parent = part,
		}) :: ParticleEmitter
		rainPart = part
		rainEmitter = emitter
	end
end

-- Places the cloud ring + rain round `centre` (clouds at CloudHeight on a CloudRadius ring).
local function placeSky(centre: Vector3)
	ringCentre = centre
	local base = Vector3.new(centre.X, 0, centre.Z)
	local count = #clouds
	for index, cloud in clouds do
		local angle = (index / math.max(count, 1)) * math.pi * 2
		local radius = Client.CloudRadius * (0.55 + 0.45 * ((index % 2) * 0.8 + 0.2))
		local position = base
			+ Vector3.new(math.cos(angle) * radius, Client.CloudHeight + (index % 3) * 6, math.sin(angle) * radius)
		cloud:PivotTo(CFrame.new(position) * CFrame.Angles(0, angle, 0))
	end
	local part = rainPart
	if part ~= nil then
		part.CFrame = CFrame.new(base + Vector3.new(0, Client.CloudHeight - 4, 0))
	end
end

-- Rain rate for the graphics tier (0 with Reduce Motion).
local function applyRain()
	local emitter = rainEmitter
	if emitter == nil then
		return
	end
	if not storm or OfferFx.reducedMotion() then
		emitter.Enabled = false
		return
	end
	emitter.Rate = if FxQuality.tier() == "Low" then Client.ConfettiRate / 2 else Client.ConfettiRate
	emitter.Enabled = true
end

--[[
	Starts / ends the Confetti Storm sky (idempotent).
	@param on true while the storm is live
]]
function HappyHourFx.setStorm(on: boolean)
	if on == storm then
		return
	end
	storm = on
	stormToken += 1
	local token = stormToken
	if not on then
		for _, cloud in clouds do
			cloud.Parent = nil
		end
		local part = rainPart
		if part ~= nil then
			part.Parent = nil
		end
		applyRain()
		return
	end
	ensureSky()
	local centre = focusPosition()
	if centre ~= nil then
		placeSky(centre)
	end
	for _, cloud in clouds do
		cloud.Parent = Workspace
	end
	local part = rainPart
	if part ~= nil then
		part.Parent = Workspace
	end
	applyRain()
	-- Follow loop (only during the storm): re-centre when the player wanders off; swap in the
	-- real cloud mesh once it loaded; follow graphics / Reduce Motion changes.
	task.spawn(function()
		while storm and token == stormToken do
			task.wait(0.5)
			if not storm or token ~= stormToken then
				break
			end
			if not cloudsMeshed and PetModels.isMeshReady(Client.CloudKey) then
				ensureSky()
				for _, cloud in clouds do
					cloud.Parent = Workspace
				end
				ringCentre = nil
			end
			local focus = focusPosition()
			local current = ringCentre
			if
				focus ~= nil
				and (
					current == nil
					or Vector3.new(focus.X - current.X, 0, focus.Z - current.Z).Magnitude > Client.CloudRadius * 0.6
				)
			then
				placeSky(focus)
			end
			applyRain()
		end
	end)
end

-- One income pop of an own producer: during Double Pops, a throttled bonus pop beside it.
local function onIncomePop(payload: unknown)
	if popMultiplier <= 1 or type(payload) ~= "table" then
		return
	end
	local data = payload :: { [string]: unknown }
	local id, amount = data.producerId, data.amount
	if type(id) ~= "string" or type(amount) ~= "number" or amount ~= amount or amount <= 0 or amount == math.huge then
		return
	end
	local now = os.clock()
	if now - (lastBonus[id] or -math.huge) < Client.BonusPopGap then
		return
	end
	local record = ProducerBillboards.byId(id)
	if record == nil then
		return
	end
	local camera = Workspace.CurrentCamera
	if camera ~= nil then
		local start = record.popPoint.WorldPosition
		local _, onScreen = camera:WorldToViewportPoint(start)
		if not onScreen then
			return
		end
	end
	lastBonus[id] = now
	bonusPops += 1
	-- The bonus share of a boosted payout: amount x (1 - 1 / multiplier) (display only).
	local bonus = amount * (1 - 1 / popMultiplier)
	if bonus <= 0 then
		return
	end
	-- Mirrored sideways drift: the two pops fan out from the same point.
	local drift = record.popDrift
	IncomePops.show(record.popPoint, bonus, Vector3.new(-drift.X, drift.Y, -drift.Z), record.worldId)
end

--[[
	Starts / ends the Double Pops bonus pops.
	@param multiplier the live cash multiplier (1 = off)
]]
function HappyHourFx.setDoublePops(multiplier: number)
	popMultiplier = if multiplier == multiplier and multiplier > 1 and multiplier < 10 then multiplier else 1
	if popMultiplier <= 1 then
		table.clear(lastBonus)
		return
	end
	if not popConnected then
		popConnected = true
		task.spawn(function()
			Remotes.unreliable("IncomePop").OnClientEvent:Connect(onIncomePop)
		end)
	end
end

--[[ Verification counters (Studio QA). ]]
function HappyHourFx.stats(): { [string]: any }
	local rain = rainEmitter
	return {
		storm = storm,
		clouds = #clouds,
		cloudsMeshed = cloudsMeshed,
		rain = rain ~= nil and rain.Enabled,
		doublePops = popMultiplier,
		bonusPops = bonusPops,
	}
end

return HappyHourFx
