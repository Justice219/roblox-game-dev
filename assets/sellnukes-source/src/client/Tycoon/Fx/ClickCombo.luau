--!strict
--[[
	ClickCombo — the click combo ladder (owner R71 juice). Presses on your own MANUAL producers
	within JuiceConfig.Combo.Window (0.7 s) of each other chain a combo:

		* every press plays "combo_tick" one semitone higher (1.0 -> 1.6, JuiceRules.comboPitch),
		  on top of the producer's own "producer_pop" when the press really started a cycle;
		* from x2 a punchy "x12!" label pops beside the producer's billboard (pooled BillboardGui
		  just under the "+$X" pop start, which sits off the board's outer side, so it never covers
		  billboard text — owner R32; above the anchor while the billboard is not placed yet);
		* every 10th press: a sparkle ring around the producer;
		* at 25 / 50 / 100 (and every 100 after): a big confetti burst + "coin_burst", and from 100
		  a small camera punch.

	Pure feedback — no economy effect, nothing is sent to the server. A press on a producer that is
	still mid-cycle counts too: with 1 s cycles early on, only counting accepted clicks would never
	chain inside 0.7 s, and the combo is about the player's clicking rhythm (decision R71, docs/ui.md).

	Performance: two pooled BillboardGuis (built on first use), the label animation runs in the
	juice pass's single Heartbeat (Fx/JuiceLoop) via ClickCombo.step(now) only while a label is up; rings /
	bursts use pooled emitters (JuiceParticles / Confetti). Reduce Motion: sounds + a still label,
	no rings, bursts or punches. FxQuality tier sets the particle counts.

	Connects to: Tycoon/ProducerBillboards.click (calls press), Client/Tycoon/Fx/{JuiceRules,
	JuiceParticles, Confetti, CameraPunch, FxQuality}, Client/Audio/Sound, UI/Widgets/OfferFx,
	Shared/Config/{JuiceConfig, UIStyleConfig}.

	Example: ClickCombo.press(record.anchor, record.popPoint)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CameraPunch = require(script.Parent.CameraPunch)
local Confetti = require(script.Parent.Confetti)
local FxQuality = require(script.Parent.FxQuality)
local JuiceConfig = require(ReplicatedStorage.Shared.Config.JuiceConfig)
local JuiceLoop = require(script.Parent.JuiceLoop)
local JuiceParticles = require(script.Parent.JuiceParticles)
local JuiceRules = require(script.Parent.JuiceRules)
local OfferFx = require(script.Parent.Parent.Parent.UI.Widgets.OfferFx)
local Sound = require(script.Parent.Parent.Parent.Audio.Sound)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local ClickCombo = {}

local Combo = JuiceConfig.Combo
-- Warm gold label with a dark outline (the cash-pop look, a little hotter).
local LABEL_COLOR = Color3.fromRGB(255, 214, 64)
local LABEL_BIG_COLOR = Color3.fromRGB(255, 132, 64)

type Label = {
	gui: BillboardGui,
	text: TextLabel,
	stroke: UIStroke,
	scale: UIScale,
	adornee: Instance?,
	pressedAt: number,
	live: boolean,
}

local labels: { Label } = {}
local count = 0
local lastAt = -math.huge
local soundOptions: Sound.PlayOptions = { pitch = 1, volume = Combo.Volume }

-- Builds one pooled label (parented to PlayerGui, disabled until used).
local function makeLabel(index: number): Label
	local stroke = Instance.new("UIStroke")
	stroke.Color = UIStyleConfig.Neutral.TextStroke
	stroke.Thickness = 3
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	local text = Instance.new("TextLabel")
	text.Name = "Combo"
	text.BackgroundTransparency = 1
	text.AnchorPoint = Vector2.new(0.5, 0.5)
	text.Position = UDim2.fromScale(0.5, 0.5)
	text.Size = UDim2.fromScale(1, 1)
	text.TextScaled = true
	text.FontFace = UIStyleConfig.Fonts.Shout
	text.TextColor3 = LABEL_COLOR
	text.Text = ""
	stroke.Parent = text
	local scale = Instance.new("UIScale")
	scale.Parent = text
	local gui = Instance.new("BillboardGui")
	gui.Name = `ComboLabel{index}`
	gui.Size = UDim2.fromScale(Combo.LabelStuds.X, Combo.LabelStuds.Y)
	gui.StudsOffsetWorldSpace = Vector3.new(0, Combo.LabelRise, 0)
	gui.MaxDistance = Combo.LabelMaxDistance
	gui.LightInfluence = 0
	gui.AlwaysOnTop = true
	gui.ResetOnSpawn = false
	gui.Active = false
	gui.Enabled = false
	text.Parent = gui
	gui.Parent = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	return { gui = gui, text = text, stroke = stroke, scale = scale, adornee = nil, pressedAt = 0, live = false }
end

-- The label for `adornee`: the one already on it, else a free one, else the oldest.
local function labelFor(adornee: Instance): Label
	local oldest: Label? = nil
	for _, label in labels do
		if label.live and label.adornee == adornee then
			return label
		end
	end
	for _, label in labels do
		if not label.live then
			return label
		end
		if oldest == nil or label.pressedAt < oldest.pressedAt then
			oldest = label
		end
	end
	if #labels < Combo.LabelPool then
		local label = makeLabel(#labels + 1)
		table.insert(labels, label)
		return label
	end
	return oldest :: Label
end

-- Shows / refreshes the combo label beside the producer.
local function showLabel(adornee: Instance, offset: Vector3, text: string, big: boolean, now: number, reduced: boolean)
	local label = labelFor(adornee)
	if label.adornee ~= adornee then
		label.adornee = adornee
		label.gui.Adornee = adornee
	end
	if label.gui.StudsOffsetWorldSpace ~= offset then
		label.gui.StudsOffsetWorldSpace = offset
	end
	label.text.Text = text
	label.text.TextColor3 = if big then LABEL_BIG_COLOR else LABEL_COLOR
	label.text.TextTransparency = 0
	label.stroke.Transparency = 0
	label.scale.Scale = if reduced then 1 else JuiceRules.labelScale(0)
	label.pressedAt = now
	label.live = true
	label.gui.Enabled = true
	JuiceLoop.wake()
end

--[[
	One press on an own manual producer (call it for every press, accepted or not).
	@param anchor   the producer anchor (rings / bursts centre on it)
	@param popPoint its "+$X" pop start (record.popPoint): the label sits just under it
]]
function ClickCombo.press(anchor: BasePart, popPoint: Attachment?)
	local now = os.clock()
	count = JuiceRules.comboNext(count, lastAt, now)
	lastAt = now
	soundOptions.pitch = JuiceRules.comboPitch(count)
	Sound.play(Combo.Sound, soundOptions)
	local reduced = OfferFx.reducedMotion()
	local event = JuiceRules.comboEvent(count)
	local text = JuiceRules.comboLabel(count)
	if text ~= nil then
		-- Beside the billboard, just under the "+$X" pop start: IncomePops already places that point
		-- off the board on its outer side (owner R32), so the label never covers billboard text
		-- (QA 2026-10-31: a label on the producer body sat on a low billboard's text). A pop point
		-- far from the producer (its billboard not placed yet) falls back to above the anchor.
		local adornee: Instance = anchor
		local offset = Vector3.new(0, anchor.Size.Y * 0.5 + Combo.LabelAbove, 0)
		if popPoint ~= nil and (popPoint.WorldPosition - anchor.Position).Magnitude <= Combo.PopPointRange then
			adornee, offset = popPoint, Vector3.new(0, Combo.LabelRise, 0)
		end
		showLabel(adornee, offset, text, event == "big", now, reduced)
	end
	if event == nil then
		return
	end
	if event == "big" then
		Sound.play(Combo.BigSound)
	end
	if reduced then
		return
	end
	local tier = FxQuality.tier()
	local centre = anchor.Position
	if event == "ring" then
		JuiceParticles.ring(
			centre,
			math.max(anchor.Size.X, anchor.Size.Z) * 0.5 + 2,
			JuiceRules.perTier(Combo.RingSparkles, tier)
		)
	else
		Confetti.burst(
			centre + Vector3.new(0, anchor.Size.Y * 0.5 + 3, 0),
			JuiceRules.perTier(Combo.BigConfetti, tier),
			JuiceRules.perTier(Combo.BigSparkles, tier)
		)
		if JuiceRules.comboPunches(count) then
			CameraPunch.punch(Combo.BigPunch)
		end
	end
end

--[[
	Animates the labels (Fx/JuiceLoop's Heartbeat): the press punch eases back, then the label
	fades LabelHold s after the last press.
	@param now os.clock()
	@return true while any label is up
]]
function ClickCombo.step(now: number): boolean
	local any = false
	local reduced = false
	for _, label in labels do
		if not label.live then
			continue
		end
		local since = now - label.pressedAt
		if since >= Combo.LabelHold + Combo.LabelFade then
			label.live = false
			label.gui.Enabled = false
			continue
		end
		any = true
		if since > Combo.LabelHold then
			local fade = (since - Combo.LabelHold) / Combo.LabelFade
			label.text.TextTransparency = fade
			label.stroke.Transparency = fade
		end
		if since <= Combo.PunchSeconds then
			reduced = reduced or OfferFx.reducedMotion()
			label.scale.Scale = if reduced then 1 else JuiceRules.labelScale(since)
		elseif label.scale.Scale ~= 1 then
			label.scale.Scale = 1
		end
	end
	return any
end

--[[
	Builds the label pool up front (JuiceController.Start, deferred): no hitch on the first combo,
	and the labels exist before any press.
]]
function ClickCombo.prewarm()
	while #labels < Combo.LabelPool do
		table.insert(labels, makeLabel(#labels + 1))
	end
end

--[[ The current combo count (Studio probes). ]]
function ClickCombo.count(): number
	return if os.clock() - lastAt <= Combo.Window then count else 0
end

JuiceLoop.add("ClickCombo", ClickCombo.step)

return ClickCombo
