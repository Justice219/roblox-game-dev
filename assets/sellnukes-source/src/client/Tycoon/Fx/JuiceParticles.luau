--!strict
--[[
	JuiceParticles — the pooled 3D particle pieces of the juice pass (owner R71): coin bursts (pad
	buys), soft puffs (a manager arrives), sparkle rings (click combos) and the gentle ambient income
	sparkles over automated producers. Confetti + plain sparkle bursts stay in Fx/Confetti.

	Pools (all built on first use, then only moved / toggled / Emit()-ed — no Instance.new after
	warm-up, no per-frame work here at all):
		coins    3 Attachments (Workspace.Terrain), one ParticleEmitter each: the rendered Cash icon
		         as a tumbling sprite that pops up and falls (fallback: gold stud squares)
		puff     2 Attachments: soft white cloud puffs + sparkles
		ring     2 invisible anchored Parts (CanCollide / CanQuery / CanTouch off) under
		         Workspace.SN_JuiceFx with a Disc-shaped emitter: sparkles appear on a ring around
		         the producer and drift up (a Disc shape needs a Part host, not an Attachment)
		ambient  up to JuiceConfig.Ambient.Emitters.High Attachments with a low steady Rate, moved
		         onto the nearest automated producers by ProducerJuice (Enabled toggled, never rebuilt)
	Soft by design (owner R19): modest LightEmission, LightInfluence on the solid pieces, no flashes.

	Connects to: Shared/Config/{JuiceConfig, IconAssets, WorldMaterialConfig}, callers
	JuiceController / ClickCombo / ProducerJuice.

	Example:
		JuiceParticles.coins(pad:GetPivot().Position + Vector3.new(0, 2.5, 0), 9)
		JuiceParticles.ring(anchor.Position, 4, 16)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local IconAssets = require(ReplicatedStorage.Shared.Config.IconAssets)
local JuiceConfig = require(ReplicatedStorage.Shared.Config.JuiceConfig)
local WorldMaterialConfig = require(ReplicatedStorage.Shared.Config.WorldMaterialConfig)

local JuiceParticles = {}

local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local PUFF_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local GOLD = Color3.fromRGB(255, 214, 92)
local WARM_WHITE = Color3.fromRGB(255, 246, 220)
local COIN_POOL = 3
local PUFF_POOL = 2
local RING_POOL = 2

type Slot = { host: Instance, emitters: { ParticleEmitter } }

local folder: Folder? = nil
local coinSlots: { Slot } = {}
local puffSlots: { Slot } = {}
local ringSlots: { Slot } = {}
local ambientSlots: { Slot } = {}
local coinCursor, puffCursor, ringCursor = 0, 0, 0

-- The client-only folder for Part hosts (created once).
local function fxFolder(): Folder
	local existing = folder
	if existing ~= nil and existing.Parent ~= nil then
		return existing
	end
	local made = Instance.new("Folder")
	made.Name = "SN_JuiceFx"
	made.Parent = Workspace
	folder = made
	return made
end

-- A pooled Attachment under Terrain.
local function attachment(name: string): Attachment
	local item = Instance.new("Attachment")
	item.Name = name
	item.Parent = Workspace.Terrain
	return item
end

-- A sparkle emitter (shared look: small warm twinkles).
local function sparkleEmitter(parent: Instance, color: Color3, speed: NumberRange): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Sparkle"
	emitter.Enabled = false
	emitter.Texture = SPARKLE_TEXTURE
	emitter.Color = ColorSequence.new(color, Color3.fromRGB(255, 255, 255))
	emitter.Lifetime = NumberRange.new(0.5, 0.9)
	emitter.Speed = speed
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.9),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.LightEmission = 0.55
	emitter.LightInfluence = 0
	emitter.Parent = parent
	return emitter
end

-- Builds one coin slot: cash sprites that pop up, tumble and fall.
local function makeCoin(index: number): Slot
	local host = attachment(`SN_JuiceCoins{index}`)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Coins"
	emitter.Enabled = false
	local image = IconAssets.image("Cash")
	if image ~= nil and image ~= "" then
		emitter.Texture = image
		emitter.Color = ColorSequence.new(Color3.new(1, 1, 1))
	else
		-- Not uploaded: gold stud squares.
		emitter.Texture = `rbxassetid://{WorldMaterialConfig.Images.Color}`
		emitter.Color = ColorSequence.new(GOLD)
	end
	emitter.Lifetime = NumberRange.new(0.9, 1.25)
	emitter.Speed = NumberRange.new(11, 17)
	emitter.SpreadAngle = Vector2.new(32, 32)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Acceleration = Vector3.new(0, -42, 0)
	emitter.Drag = 0.6
	emitter.Rotation = NumberRange.new(-30, 30)
	emitter.RotSpeed = NumberRange.new(-220, 220)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.9),
		NumberSequenceKeypoint.new(0.15, 1.2),
		NumberSequenceKeypoint.new(1, 0.8),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.85, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.LightInfluence = 0.4
	emitter.Parent = host
	local sparkle = sparkleEmitter(host, GOLD, NumberRange.new(4, 9))
	return { host = host, emitters = { emitter, sparkle } }
end

-- Builds one puff slot: soft round clouds + a few sparkles.
local function makePuff(index: number): Slot
	local host = attachment(`SN_JuicePuff{index}`)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Puff"
	emitter.Enabled = false
	emitter.Texture = PUFF_TEXTURE
	emitter.Color = ColorSequence.new(WARM_WHITE)
	emitter.Lifetime = NumberRange.new(0.55, 0.85)
	emitter.Speed = NumberRange.new(5, 9)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Drag = 4
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.6),
		NumberSequenceKeypoint.new(1, 3.6),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.LightInfluence = 0.5
	emitter.Parent = host
	local sparkle = sparkleEmitter(host, WARM_WHITE, NumberRange.new(5, 10))
	return { host = host, emitters = { emitter, sparkle } }
end

-- Builds one ring slot: an invisible Part hosting a Disc emitter (sparkles on the rim).
local function makeRing(index: number): Slot
	local part = Instance.new("Part")
	part.Name = `SN_JuiceRing{index}`
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(8, 0.2, 8)
	part.Parent = fxFolder()
	local emitter = sparkleEmitter(part, GOLD, NumberRange.new(2, 4))
	emitter.Shape = Enum.ParticleEmitterShape.Disc
	emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	emitter.ShapeInOut = Enum.ParticleEmitterShapeInOut.Outward
	emitter.ShapePartial = 0.92 -- inner radius share: only the rim emits
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.SpreadAngle = Vector2.new(10, 10)
	emitter.Lifetime = NumberRange.new(0.6, 1)
	return { host = part, emitters = { emitter } }
end

-- Builds one ambient slot: a steady low-rate twinkle (Enabled only while assigned).
local function makeAmbient(index: number): Slot
	local host = attachment(`SN_JuiceAmbient{index}`)
	local emitter = sparkleEmitter(host, GOLD, NumberRange.new(1, 2.5))
	emitter.Rate = JuiceConfig.Ambient.Rate
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.SpreadAngle = Vector2.new(40, 40)
	emitter.Lifetime = NumberRange.new(0.9, 1.4)
	emitter.Acceleration = Vector3.new(0, 1.5, 0)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.LightEmission = 0.4
	return { host = host, emitters = { emitter } }
end

-- The next slot of a pool (built on first use), round-robin.
local function nextSlot(pool: { Slot }, size: number, cursor: number, make: (number) -> Slot): (Slot, number)
	local index = cursor % size + 1
	local slot = pool[index]
	if slot == nil then
		slot = make(index)
		pool[index] = slot
	end
	return slot, index
end

-- Emits `counts[i]` from each emitter of a slot (0 skips).
local function emit(slot: Slot, counts: { number })
	for index, emitter in slot.emitters do
		local count = counts[index] or 0
		if count > 0 then
			emitter:Emit(count)
		end
	end
end

--[[
	A coin burst (pad buys): cash sprites pop up and tumble down, with a few gold sparkles.
	@param position world position
	@param coins sprites; sparkles defaults to half of it
]]
function JuiceParticles.coins(position: Vector3, coins: number, sparkles: number?)
	local slot, index = nextSlot(coinSlots, COIN_POOL, coinCursor, makeCoin)
	coinCursor = index;
	(slot.host :: Attachment).WorldPosition = position
	emit(slot, { coins, sparkles or math.floor(coins / 2) })
end

--[[
	A soft cloud puff (a manager arrives).
	@param position world position
	@param puffs cloud puffs; sparkles twinkles
]]
function JuiceParticles.puff(position: Vector3, puffs: number, sparkles: number)
	local slot, index = nextSlot(puffSlots, PUFF_POOL, puffCursor, makePuff)
	puffCursor = index;
	(slot.host :: Attachment).WorldPosition = position
	emit(slot, { puffs, sparkles })
end

--[[
	A sparkle ring around a point (click combo every 10).
	@param position ring centre (world)
	@param radius ring radius (studs)
	@param sparkles twinkles on the rim
]]
function JuiceParticles.ring(position: Vector3, radius: number, sparkles: number)
	local slot, index = nextSlot(ringSlots, RING_POOL, ringCursor, makeRing)
	ringCursor = index
	local part = slot.host :: Part
	local diameter = math.max(radius, 0.5) * 2
	if part.Size.X ~= diameter then
		part.Size = Vector3.new(diameter, 0.2, diameter)
	end
	part.CFrame = CFrame.new(position)
	emit(slot, { sparkles })
end

--[[
	Points the ambient income sparkles at `positions` (the nearest automated producers, ranked by
	ProducerJuice): emitter i follows positions[i]; the rest switch off.
	@param positions world positions (at most `count` used)
	@param count how many emitters may run (FxQuality tier budget)
]]
function JuiceParticles.setAmbient(positions: { Vector3 }, count: number)
	local wanted = math.min(#positions, count)
	for index = 1, math.max(wanted, #ambientSlots) do
		local slot = ambientSlots[index]
		if index <= wanted then
			if slot == nil then
				slot = makeAmbient(index)
				ambientSlots[index] = slot
			end
			(slot.host :: Attachment).WorldPosition = positions[index]
			slot.emitters[1].Enabled = true
		elseif slot ~= nil then
			slot.emitters[1].Enabled = false
		end
	end
end

--[[
	Builds the one-shot pools up front (JuiceController.Start, deferred): coins, puffs and rings
	exist before the first purchase / hire / combo, so none of them hitches on first use.
]]
function JuiceParticles.prewarm()
	for index = 1, COIN_POOL do
		if coinSlots[index] == nil then
			coinSlots[index] = makeCoin(index)
		end
	end
	for index = 1, PUFF_POOL do
		if puffSlots[index] == nil then
			puffSlots[index] = makePuff(index)
		end
	end
	for index = 1, RING_POOL do
		if ringSlots[index] == nil then
			ringSlots[index] = makeRing(index)
		end
	end
end

--[[ The client-only Workspace folder for juice Instances (ring hosts, glow Highlights). ]]
function JuiceParticles.folder(): Folder
	return fxFolder()
end

--[[ Pool sizes for Studio probes. ]]
function JuiceParticles.stats(): { coins: number, puffs: number, rings: number, ambient: number }
	local running = 0
	for _, slot in ambientSlots do
		if slot.emitters[1].Enabled then
			running += 1
		end
	end
	return { coins = #coinSlots, puffs = #puffSlots, rings = #ringSlots, ambient = running }
end

return JuiceParticles
