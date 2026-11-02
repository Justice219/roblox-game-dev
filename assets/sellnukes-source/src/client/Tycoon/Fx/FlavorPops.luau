--!strict
--[[
	FlavorPops — the owner's look of a flavoured batch (owner R89 Surprise Batches, spec §1): the
	producer's "+$X" income pops wear the flavour colour for a moment (IncomePops.tint), a flavour
	word ("GLITTER! x3") rises beside the pop point, and a short sparkle burst in the flavour colour
	pops at the producer. Server FlavorPop (unreliable, owner only) → Tycoon/FlavorController → here.

	Performance:
		- POOLED: FlavorConfig.Pop.Pool BillboardGuis (built once, the oldest is recycled) and a few
		  sparkle emitters under Workspace.Terrain (moved + Emit) — no Instance.new per pop.
		- Per producer at most one word per Pop.MinGap seconds (faster pops only re-tint).
		- Off-screen / far pops skip the word + sparkle entirely (the tint still applies).
		- Each word is two tweens; no per-frame code.
	Display only: amounts / flavours come from the server; a dropped (unreliable) pop shows nothing.

	Owner R112 words: the pop says "GALAXY x20" (FlavorConfig.popWord, never "batch"), and the first
	Lucky Nuke a player ever gets opens the one-time tip card (Tycoon/FlavorTip.maybeShow).

	Connects to: Tycoon/{IncomePops (tint), ProducerBillboards (pop point), FlavorTip}, Fx/{FxQuality,
	FxSound, JuiceRules}, UI/{Create, Kit/StudUI}, Shared/Config/FlavorConfig.

	Example: FlavorPops.show("garage", FlavorConfig.byId("glitter"), 1)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Create = require(script.Parent.Parent.Parent.UI.Create)
local FlavorConfig = require(ReplicatedStorage.Shared.Config.FlavorConfig)
local FxQuality = require(script.Parent.FxQuality)
local FlavorTip = require(script.Parent.Parent.FlavorTip)
local FxSound = require(script.Parent.FxSound)
local IncomePops = require(script.Parent.Parent.IncomePops)
local JuiceRules = require(script.Parent.JuiceRules)
local ProducerBillboards = require(script.Parent.Parent.ProducerBillboards)
local StudUI = require(script.Parent.Parent.Parent.UI.Kit.StudUI)

local Config = FlavorConfig.Pop
local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local SPARKLE_EMITTERS = 3

type Word = {
	gui: BillboardGui,
	label: TextLabel,
	stroke: UIStroke?,
	busyUntil: number,
	tweens: { Tween },
}

local FlavorPops = {}

local words: { Word } = {}
local sparkles: { { host: Attachment, emitter: ParticleEmitter } } = {}
local nextSparkle = 1
local lastWord: { [string]: number } = {}

--[[
	"x1.5" / "x20" — a multiplier the way the pop, the reveal and the Book print it.
	@param mult number
	@return string
]]
function FlavorPops.multText(mult: number): string
	return FlavorConfig.multText(mult) -- one formatter for every presenter (owner R112)
end

-- Builds the word pool once (PlayerGui exists by the first pop).
local function ensureWords()
	if #words > 0 then
		return
	end
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	for index = 1, Config.Pool do
		local gui = Create.new("BillboardGui", {
			Name = `FlavorPop{index}`,
			Size = UDim2.fromScale(Config.SizeStuds.X, Config.SizeStuds.Y),
			MaxDistance = Config.MaxDistance,
			LightInfluence = 0,
			AlwaysOnTop = true,
			ResetOnSpawn = false,
			Enabled = false,
			Parent = playerGui,
		}) :: BillboardGui
		local label = StudUI.text({
			name = "Word",
			text = "",
			textSize = 60,
			font = "shout",
			scaled = true,
			size = UDim2.fromScale(1, 1),
			parent = gui,
		})
		table.insert(words, {
			gui = gui,
			label = label,
			stroke = label:FindFirstChildOfClass("UIStroke"),
			busyUntil = 0,
			tweens = {} :: { Tween },
		})
	end
end

-- A free word (or the one finishing soonest), its tweens cancelled.
local function takeWord(): Word
	ensureWords()
	local best = words[1]
	for _, word in words do
		if word.busyUntil < best.busyUntil then
			best = word
		end
	end
	for _, tween in best.tweens do
		tween:Cancel()
	end
	table.clear(best.tweens)
	return best
end

-- Builds the sparkle emitters once.
local function ensureSparkles()
	if #sparkles > 0 then
		return
	end
	for index = 1, SPARKLE_EMITTERS do
		local host = Instance.new("Attachment")
		host.Name = `SN_FlavorSparkle{index}`
		host.Parent = Workspace.Terrain
		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "Sparkle"
		emitter.Texture = SPARKLE_TEXTURE
		emitter.Enabled = false
		emitter.Lifetime = NumberRange.new(0.5, 0.9)
		emitter.Speed = NumberRange.new(5, 11)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Drag = 4
		emitter.LightEmission = 0.4 -- owner R19: soft
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.9),
			NumberSequenceKeypoint.new(1, 0),
		})
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.Parent = host
		table.insert(sparkles, { host = host, emitter = emitter })
	end
end

--[[
	A one-shot sparkle burst in `color` at `position` (FxQuality-budgeted count).
	@param position Vector3
	@param color Color3
	@param count number
]]
function FlavorPops.sparkle(position: Vector3, color: Color3, count: number)
	if count <= 0 then
		return
	end
	ensureSparkles()
	local slot = sparkles[nextSparkle]
	nextSparkle = nextSparkle % #sparkles + 1
	slot.host.WorldPosition = position
	slot.emitter.Color = ColorSequence.new(color, Color3.new(1, 1, 1))
	slot.emitter:Emit(count)
end

-- True when the point is on screen and within the pop distance.
local function visibleAt(position: Vector3): boolean
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return false
	end
	local _, onScreen = camera:WorldToViewportPoint(position)
	return onScreen and (position - camera.CFrame.Position).Magnitude <= Config.MaxDistance
end

--[[
	Shows a flavoured batch on one of the local player's producers.
	@param producerId string — own producer (unknown ids do nothing)
	@param def FlavorConfig.FlavorDef — the best special flavour of that payout
	@param count number — special batches folded into it (shown as "+n" when > 1)
]]
function FlavorPops.show(producerId: string, def: FlavorConfig.FlavorDef, count: number)
	if def.rank < 1 then
		return
	end
	-- Owner R112: the first Lucky Nuke ever explains itself once (Tycoon/FlavorTip; cheap after).
	FlavorTip.maybeShow()
	IncomePops.tint(producerId, def.color, Config.TintSeconds)
	local record = ProducerBillboards.byId(producerId)
	if record == nil then
		return
	end
	local now = os.clock()
	local last = lastWord[producerId]
	if last ~= nil and now - last < Config.MinGap then
		return
	end
	local start = record.popPoint.WorldPosition
	if not visibleAt(start) then
		return
	end
	lastWord[producerId] = now
	local word = takeWord()
	local seconds = Config.Seconds
	word.busyUntil = now + seconds
	-- Owner R112 words: "GALAXY x20" (never "batch"), from FlavorConfig.Text.
	word.label.Text = FlavorConfig.popWord(def, count)
	word.label.TextColor3 = def.color
	word.label.TextTransparency = 0
	local stroke = word.stroke
	if stroke ~= nil then
		stroke.Transparency = 0
	end
	-- Starts a little above the income pop so the two never overlap, drifting with it.
	local lift = Vector3.new(0, 1.6, 0)
	word.gui.Adornee = record.popPoint
	word.gui.StudsOffsetWorldSpace = lift
	word.gui.Enabled = true
	local info = TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local drift = if record.popDrift.Magnitude > 0 then record.popDrift.Unit * 0.5 else Vector3.zero
	local rise = TweenService:Create(word.gui, info, {
		StudsOffsetWorldSpace = lift + drift + Vector3.new(0, Config.RiseStuds, 0),
	})
	local fadeInfo =
		TweenInfo.new(seconds * 0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, seconds * 0.55)
	local fade = TweenService:Create(word.label, fadeInfo, { TextTransparency = 1 })
	word.tweens = { rise, fade }
	if stroke ~= nil then
		table.insert(word.tweens, TweenService:Create(stroke, fadeInfo, { Transparency = 1 }))
	end
	for _, tween in word.tweens do
		tween:Play()
	end
	fade.Completed:Once(function(state: Enum.PlaybackState)
		if state == Enum.PlaybackState.Completed then
			word.gui.Enabled = false
		end
	end)
	FlavorPops.sparkle(start, def.color, JuiceRules.perTier(Config.Sparkles, FxQuality.tier()))
	-- Rarer flavours chime louder + higher (3D at the producer; the sound system rate-limits).
	FxSound.play("sparkle", start, { volume = 0.5 + def.rank * 0.1, pitch = 0.9 + def.rank * 0.08 })
end

return FlavorPops
