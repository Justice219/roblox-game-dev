--!strict
--[[
	LuckyButtonClient — draws the player's Lucky Buttons (owner R69; spec
	docs/superpowers/specs/2026-10-31-r69-moon-lucky-juice-design.md §1) and claims them when the
	character walks in (works with every input: keyboard / gamepad / touch all just walk).

	Purpose:
		The server (Server/Services/LuckyButtonService) keeps the buttons and tells only the owner
		("LuckyButtons" spawn / claimed / expired / clear). This module turns each into a pooled
		Lucky_Button model (Blender mesh: white studded housing, kind-tinted Ring + Cap) with:
			- a label billboard ("+$1.2K!", "2x CASH 2 MIN!", paid: the Robux icon + live PriceBook
			  price), a light beam to the sky and sparkles (Mid / High graphics),
			- a pop-up rise, a bob + spin and a blink (last BlinkSeconds) — all in ONE Heartbeat with
			  ONE Workspace:BulkMoveTo for every live button,
			- a "LUCKY BUTTON!" toast + spawn sound, and the edge arrow (UI/Screens/LuckyButtons/
			  LuckyArrowScreen reads `nearest()`),
			- claim FX: confetti + coins flying into the HUD counter (CurrencyFly.fromWorld, which
			  also marks the grant as explained so it never flies twice) + the claim sound.
		Walking in: free kinds send LuckyButtonClaim(id) on entering the claim radius and retry
		every ClaimRetrySeconds while inside until the server answers. Paid kinds (owner R122,
		spec §2.4: no accidental purchase prompts) never prompt on a walk-in: entering the claim
		radius asks PopupQueue's centre lane (kind "luckyDeal") for the small non-blocking DEAL
		card (UI/Screens/DealCard at the bottom of the feed: art, name, line, live price, BUY +
		CLOSE; never auto-focused, X / E / a tap buys, never A). Only its BUY sends
		LuckyButtonClaim(id, "buy") (the server prompts); the card reports "shown" / "close" for
		luckyDeal:<shown|buy|close>:<kind>. It stays while the character is within
		Deal.KeepRadius, hides past it, and after CLOSE / BUY stays away until the player walks out
		and back in (pure rules: LuckyButtonLogic.dealStep / dealClosed).

	Performance: models are pooled (≤ MaxLive + 1 ever built; meshes rebuilt once when they finish
	loading), the Heartbeat connection exists only while a button is live, buttons beyond
	RenderDistance are unparented, off-camera buttons (ViewCone) skip their motion, billboards use
	MaxDistance, sounds are rate-limited, sparkles follow FxQuality, Reduce Motion freezes bob /
	spin / pop / flashing.

	Security: display + intents only. The client validates every payload (LuckyButtonLogic.readWire)
	and sends only button ids; the server decides grants, prompts and amounts.

	Connects to: Shared/Config/{LuckyButtonConfig, AudioConfig, Worlds/WorldsConfig},
	Shared/Tycoon/LuckyButtonLogic, Shared/Net/Remotes, Shared/Util/{Signal, ViewCone},
	Client/{ClientState, Pets/PetModels, Audio/Sound, Tycoon/Fx/{Confetti, FxQuality},
	Worlds/WorldClient}, UI/{Hud/Hud, Hud/CurrencyFly, PriceBook, Kit/StudUI, Create,
	Widgets/{OfferFx, PopupQueue}, ScreenManager, Screens/DealCard (opened by name)}. Read by UI/Screens/LuckyButtons/LuckyArrowScreen.

	Example:
		local target = LuckyButtonClient.nearest() -- { position, color, kind } or nil
		LuckyButtonClient.Changed:Connect(function() ... end)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local AudioConfig = require(ReplicatedStorage.Shared.Config.AudioConfig)
local Confetti = require(script.Parent.Parent.Tycoon.Fx.Confetti)
local Create = require(script.Parent.Parent.UI.Create)
local CurrencyFly = require(script.Parent.Parent.UI.Hud.CurrencyFly)
local FxQuality = require(script.Parent.Parent.Tycoon.Fx.FxQuality)
local Hud = require(script.Parent.Parent.UI.Hud.Hud)
local LuckyButtonConfig = require(ReplicatedStorage.Shared.Config.LuckyButtonConfig)
local LuckyButtonLogic = require(ReplicatedStorage.Shared.Tycoon.LuckyButtonLogic)
local OfferFx = require(script.Parent.Parent.UI.Widgets.OfferFx)
local PetModels = require(script.Parent.Parent.Pets.PetModels)
-- Owner R122: the DEAL card goes through the popup lane (never over a menu / another moment).
local PopupQueue = require(script.Parent.Parent.UI.Widgets.PopupQueue)
local PriceBook = require(script.Parent.Parent.UI.PriceBook)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Sound = require(script.Parent.Parent.Audio.Sound)
local StudUI = require(script.Parent.Parent.UI.Kit.StudUI)
local ViewCone = require(ReplicatedStorage.Shared.Util.ViewCone)
local WorldClient = require(script.Parent.Parent.Worlds.WorldClient)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local CFG = LuckyButtonConfig.Client
local KEY = CFG.MeshKey
-- Pop-up rise depth (studs below the ground the button starts from).
local RISE_DEPTH = 2.6
-- Seconds the blink tick sound waits between plays.
local BLINK_SOUND_GAP = 1
-- Height above the ground the coins / confetti start from (studs).
local FX_HEIGHT = 3
-- Seconds after `expires` a button whose "expired" message was lost is dropped locally.
local EXPIRY_GRACE = 2
-- Owner R122: the DEAL card screen (UI/Screens/DealCard) and its open-card id attribute.
local DEAL_SCREEN = "DealCard"
local DEAL_ID_ATTRIBUTE = "DealId"

-- A pooled model with its rig and decorations (built once, reused for every kind).
type Pooled = {
	model: Model,
	root: BasePart,
	parts: { BasePart },
	offsets: { CFrame },
	cap: BasePart?,
	ring: BasePart?,
	capMaterial: Enum.Material,
	beam: Beam,
	sparkles: ParticleEmitter,
	billboard: BillboardGui,
	label: TextLabel,
	priceRow: Frame,
	price: TextLabel,
	meshed: boolean, -- built from loaded meshes (false = stud boxes until PetModels.Ready)
}

-- A live button on screen.
type Live = {
	wire: LuckyButtonLogic.Wire,
	kind: LuckyButtonConfig.Kind,
	pooled: Pooled,
	shownAt: number, -- os.clock() of the spawn (pop-up)
	phase: number, -- bob phase offset (two buttons never bob in sync)
	inside: boolean, -- the character is inside the claim radius
	sentAt: number, -- os.clock() of the last claim intent
	blinkOn: boolean,
	blinkSoundAt: number,
	visible: boolean,
	-- Owner R122 (paid kinds): the DEAL card state, its popup-lane handle and why WE are closing it.
	deal: LuckyButtonLogic.DealState,
	dealHandle: PopupQueue.Handle?,
	dealEnding: LuckyButtonLogic.DealEnd?,
}

export type Target = { position: Vector3, color: Color3, ui: string, kind: string }

local LuckyButtonClient = {}

-- Fires when the set of live buttons changes (the arrow screen re-evaluates).
LuckyButtonClient.Changed = Signal.new() :: Signal.Signal<>

local live: { [string]: Live } = {}
local liveCount = 0
local pool: { Pooled } = {}
local folder: Folder? = nil
local heartbeat: RBXScriptConnection? = nil
local started = false
-- Session counters (QA / support: LuckyButtonClient.stats()); plain increments, no per-frame cost.
local counters = {
	messages = 0, -- LuckyButtons messages received
	invalid = 0, -- spawn payloads refused by readWire / unknown kinds
	otherWorld = 0, -- spawns for a world other than the current one (ignored)
	added = 0, -- buttons drawn
	claimsSent = 0, -- LuckyButtonClaim intents sent
	dealsShown = 0, -- owner R122: DEAL cards that appeared
	dealBuys = 0, -- DEAL card BUY presses sent
	claimed = 0, -- claimed / bought messages applied
	expired = 0, -- expired messages applied
	buildErrors = 0, -- a model / FX build that failed (warned)
}
-- Shared BulkMoveTo buffers (reused every frame: no per-frame tables).
local movedParts: { BasePart } = {}
local movedFrames: { CFrame } = {}

-- ── Helpers ──────────────────────────────────────────────────────────────────────────────────

-- The first sound key of `list` that AudioConfig knows (H1 adds the lucky_* keys).
local function soundKey(list: { string }): string?
	local sfx: any = AudioConfig.Sfx
	local aliases: any = AudioConfig.Aliases
	for _, key in list do
		if (sfx ~= nil and sfx[key] ~= nil) or (aliases ~= nil and aliases[key] ~= nil) then
			return key
		end
	end
	return nil
end

-- Plays one of the configured sounds at a position (silently skipped when none exists).
local function playSound(which: "spawn" | "claim" | "blink", position: Vector3?)
	local sounds: any = CFG.Sounds
	local key = soundKey(sounds[which])
	if key ~= nil then
		Sound.play(key, { position = position })
	end
end

-- The toast / arrow icon (the LuckyButton icon once W1b ships it, else the fallback).
local function iconKey(): string
	return if StudUI.hasIcon(CFG.Icon) then CFG.Icon else CFG.IconFallback
end

-- The Workspace folder the models live in (created lazily).
local function container(): Folder
	local existing = folder
	if existing ~= nil and existing.Parent ~= nil then
		return existing
	end
	local made = Create.new("Folder", { Name = "SN_LuckyButtons", Parent = Workspace }) :: Folder
	folder = made
	return made
end

-- The local character's root position, or nil.
local function characterRoot(): Vector3?
	local character = Players.LocalPlayer.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	return if root ~= nil and root:IsA("BasePart") then root.Position else nil
end

-- Reduce Motion (profile setting OR the platform setting).
local function reduced(): boolean
	return OfferFx.reducedMotion()
end

-- A stand-in model when MeshAssets has no Lucky_Button entry (art missing): three stud cylinders.
local function standIn(): Model
	local model = Create.new("Model", { Name = KEY }) :: Model
	local root = Create.new("Part", {
		Name = "Root",
		Size = Vector3.new(0.2, 0.2, 0.2),
		Transparency = 1,
		Anchored = true,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		Parent = model,
	}) :: Part
	model.PrimaryPart = root
	local function disc(name: string, diameter: number, height: number, y: number, color: Color3)
		Create.new("Part", {
			Name = name,
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(height, diameter, diameter),
			CFrame = CFrame.new(0, y, 0) * CFrame.Angles(0, 0, math.rad(90)),
			Color = color,
			Material = Enum.Material.Plastic,
			Anchored = true,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
			Parent = model,
		})
	end
	disc("Base", 4.8, 1.2, 0.6, Color3.fromRGB(244, 244, 248))
	disc("Ring", 4.1, 0.34, 1.36, Color3.fromRGB(255, 214, 50))
	disc("Cap", 3.2, 0.9, 1.65, Color3.fromRGB(255, 214, 50))
	return model
end

-- Builds one pooled model with its beam, sparkles and label billboard (once per pool slot).
local function build(): Pooled
	local model = PetModels.fromKey(KEY) or standIn()
	model.Name = "LuckyButton"
	if CFG.Scale ~= 1 then
		model:ScaleTo(CFG.Scale)
	end
	local root = model.PrimaryPart :: BasePart
	local parts, offsets = PetModels.rig(model)
	local cap = model:FindFirstChild("Cap", true)
	local ring = model:FindFirstChild("Ring", true)
	local capPart = if cap ~= nil and cap:IsA("BasePart") then cap else nil
	local ringPart = if ring ~= nil and ring:IsA("BasePart") then ring else nil
	-- Beam to the sky (how a button is found from across the plot).
	local base = Create.new("Attachment", { Name = "BeamBase", Parent = root }) :: Attachment
	local sky = Create.new("Attachment", {
		Name = "BeamSky",
		Position = Vector3.new(0, CFG.BeamHeight, 0),
		Parent = root,
	}) :: Attachment
	local beam = Create.new("Beam", {
		Name = "SkyBeam",
		Attachment0 = base,
		Attachment1 = sky,
		FaceCamera = true,
		LightEmission = 1,
		LightInfluence = 0,
		Segments = 1,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, CFG.BeamTransparency),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = root,
	}) :: Beam
	local sparkles = Create.new("ParticleEmitter", {
		Name = "Sparkles",
		Texture = "rbxasset://textures/particles/sparkles_main.dds",
		Rate = 0,
		Lifetime = NumberRange.new(0.6, 1.1),
		Speed = NumberRange.new(2, 4),
		SpreadAngle = Vector2.new(180, 180),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 0) }),
		LightEmission = 1,
		Parent = base,
	}) :: ParticleEmitter
	-- Label billboard (studs-sized: shrinks with distance like the pad boards; MaxDistance cull).
	local billboard = Create.new("BillboardGui", {
		Name = "LuckyLabel",
		Size = UDim2.fromScale(CFG.LabelSize.X, CFG.LabelSize.Y),
		StudsOffsetWorldSpace = Vector3.new(0, CFG.LabelOffset, 0),
		MaxDistance = CFG.LabelMaxDistance,
		LightInfluence = 0,
		AlwaysOnTop = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Adornee = root,
		Parent = root,
	}) :: BillboardGui
	local label = StudUI.text({
		name = "Label",
		text = "",
		textSize = 64,
		font = "shout",
		scaled = true,
		size = UDim2.fromScale(1, 0.6),
		parent = billboard,
	})
	-- Paid: Robux icon + live price under the label.
	local priceRow = Create.new("Frame", {
		Name = "Price",
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0, 0.6),
		Size = UDim2.fromScale(1, 0.4),
		Visible = false,
		Parent = billboard,
		Children = {
			Create.new("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0.02, 0),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		},
	}) :: Frame
	Create.new("ImageLabel", {
		Name = "Robux",
		BackgroundTransparency = 1,
		Image = StudUI.iconImage("Robux") or "",
		ScaleType = Enum.ScaleType.Fit,
		Size = UDim2.fromScale(0.22, 0.9),
		LayoutOrder = 1,
		Parent = priceRow,
	})
	local price = StudUI.text({
		name = "Amount",
		text = "",
		textSize = 48,
		font = "number",
		scaled = true,
		color = Color3.fromRGB(96, 214, 70),
		size = UDim2.fromScale(0.5, 1),
		layoutOrder = 2,
		parent = priceRow,
	})
	return {
		model = model,
		root = root,
		parts = parts,
		offsets = offsets,
		cap = capPart,
		ring = ringPart,
		capMaterial = if capPart ~= nil then capPart.Material else Enum.Material.Plastic,
		beam = beam,
		sparkles = sparkles,
		billboard = billboard,
		label = label,
		priceRow = priceRow,
		price = price,
		meshed = PetModels.isMeshReady(KEY),
	}
end

-- A pooled model (rebuilt once when the meshes finished loading after it was made).
local function acquire(): Pooled
	local pooled = table.remove(pool)
	if pooled ~= nil and not pooled.meshed and PetModels.isMeshReady(KEY) then
		pooled.model:Destroy()
		pooled = nil
	end
	return pooled or build()
end

-- Hides a model and returns it to the pool.
local function release(pooled: Pooled)
	pooled.sparkles.Rate = 0
	pooled.sparkles:Clear()
	PriceBook.unbind(pooled.price)
	pooled.model.Parent = nil
	if #pool < LuckyButtonConfig.MaxLive + 1 then
		table.insert(pool, pooled)
	else
		pooled.model:Destroy()
	end
end

-- Dresses a pooled model for a button (colour, label, price, beam, sparkles).
local function dress(pooled: Pooled, wire: LuckyButtonLogic.Wire, kind: LuckyButtonConfig.Kind)
	local color = kind.color
	if pooled.cap ~= nil then
		pooled.cap.Color = color
		pooled.cap.Material = pooled.capMaterial
	end
	if pooled.ring ~= nil then
		pooled.ring.Color = color
	end
	pooled.beam.Color = ColorSequence.new(color)
	local width = if FxQuality.tier() == "Low" then CFG.BeamWidthLow else CFG.BeamWidth
	pooled.beam.Width0 = width
	pooled.beam.Width1 = width * 0.6
	pooled.sparkles.Color = ColorSequence.new(color, Color3.new(1, 1, 1))
	local rate = if FxQuality.tier() == "Low" then 0 else CFG.SparkleRate
	pooled.sparkles.Rate = if reduced() then rate / 2 else rate
	local def = WorldsConfig.get(wire.world)
	pooled.label.Text = LuckyButtonLogic.label(kind, wire.amount, if def ~= nil then def.currency else nil)
	local product = wire.product
	pooled.priceRow.Visible = product ~= nil
	if product ~= nil then
		pooled.price.Text = PriceBook.text(product)
		PriceBook.bind(pooled.price, product, function(value: number?)
			pooled.price.Text = PriceBook.format(value)
		end)
	end
end

-- ── Per-frame update (ONE Heartbeat for every live button) ───────────────────────────────────

-- ── DEAL card (owner R122) ─────────────────────────────────────────────────────────────────────

-- The DealCard id of a button (the screen's DealId attribute while it shows that button's card).
local function dealIdOf(entry: Live): string
	return `lucky:{entry.wire.id}`
end

-- True while the DEAL card on screen is this button's.
local function dealOpenFor(entry: Live): boolean
	if not ScreenManager.isOpen(DEAL_SCREEN) then
		return false
	end
	local gui = ScreenManager.getGui(DEAL_SCREEN)
	return gui ~= nil and gui:GetAttribute(DEAL_ID_ATTRIBUTE) == dealIdOf(entry)
end

--[[
	The card ended (DealCard's onClosed: buy / close / timeout / replaced / modal / hidden): free
	the popup lane, report a CLOSE by the player, and update the button's DealState. A close WE
	asked for (walked away, lane busy) carries our own reason (dealEnding) instead of "hidden".
]]
local function onDealClosed(entry: Live, reason: LuckyButtonLogic.DealEnd)
	local handle = entry.dealHandle
	entry.dealHandle = nil
	if handle ~= nil then
		handle.done()
	end
	local why = entry.dealEnding or reason
	entry.dealEnding = nil
	if why == "close" and live[entry.wire.id] == entry then
		Remotes.event("LuckyButtonClaim"):FireServer(entry.wire.id, "close")
	end
	LuckyButtonLogic.dealClosed(entry.deal, why)
end

-- Closes this button's card (on screen) or withdraws its waiting request, for `why`.
local function closeDeal(entry: Live, why: LuckyButtonLogic.DealEnd)
	if dealOpenFor(entry) then
		entry.dealEnding = why
		ScreenManager.close(DEAL_SCREEN) -- → onClosed → onDealClosed (with `why`)
		return
	end
	local handle = entry.dealHandle
	entry.dealHandle = nil
	if handle ~= nil then
		handle.cancel()
	end
	if entry.deal.showing then
		LuckyButtonLogic.dealClosed(entry.deal, why)
	end
end

--[[
	Asks the popup lane for this paid button's DEAL card (kind "luckyDeal": waits a few seconds
	behind a more important moment, never over a menu / cinematic). Its BUY sends
	LuckyButtonClaim(id, "buy") — the only way a Lucky Button opens a Robux prompt.
]]
local function showDeal(entry: Live)
	local wire = entry.wire
	local key, productType = wire.product, wire.productType
	if key == nil or productType == nil then
		-- Nothing to sell (never happens for a valid paid wire): never an empty card.
		LuckyButtonLogic.dealClosed(entry.deal, "close")
		return
	end
	local handle = PopupQueue.request({
		kind = "luckyDeal",
		maxShow = LuckyButtonConfig.Lifetime + EXPIRY_GRACE + 3,
		show = function(): boolean
			if live[wire.id] ~= entry or not entry.deal.showing then
				return false
			end
			ScreenManager.open(DEAL_SCREEN, {
				id = dealIdOf(entry),
				source = "lucky",
				key = key,
				kind = productType,
				promptSource = LuckyButtonConfig.PromptSource,
				title = entry.kind.label,
				onBuy = function()
					counters.dealBuys += 1
					Remotes.event("LuckyButtonClaim"):FireServer(wire.id, "buy")
				end,
				onClosed = function(reason: LuckyButtonLogic.DealEnd)
					onDealClosed(entry, reason)
				end,
			})
			local opened = dealOpenFor(entry)
			if opened then
				counters.dealsShown += 1
				Remotes.event("LuckyButtonClaim"):FireServer(wire.id, "shown")
			end
			return opened
		end,
		hide = function(_reason: string)
			-- Pre-empted by a more important moment / its cap: the lane already ended it.
			entry.dealHandle = nil
			closeDeal(entry, "expired")
		end,
		onExpire = function()
			entry.dealHandle = nil
			LuckyButtonLogic.dealClosed(entry.deal, "expired")
		end,
	})
	if handle == nil then
		-- Dropped at once (the card could not open): try again on the next walk-in step.
		if not dealOpenFor(entry) then
			LuckyButtonLogic.dealClosed(entry.deal, "expired")
		end
		return
	end
	entry.dealHandle = handle
end

local function step(_dt: number)
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	local clock = os.clock()
	local serverNow = Workspace:GetServerTimeNow()
	local motion = not reduced()
	local viewport = camera.ViewportSize
	local cosLimit = ViewCone.cosLimit(camera.FieldOfView, viewport.X / math.max(viewport.Y, 1), CFG.ConeMargin)
	local camPos = camera.CFrame.Position
	local look = camera.CFrame.LookVector
	local root = characterRoot()
	local n = 0
	local stale: { string }? = nil
	for id, entry in live do
		local wire = entry.wire
		if serverNow > wire.expires + EXPIRY_GRACE then
			stale = stale or {}
			table.insert(stale :: { string }, id)
			continue
		end
		local pooled = entry.pooled
		local offset = wire.position - camPos
		-- Distance cull: unparent far buttons (the arrow still points at them).
		local near = offset.Magnitude <= CFG.RenderDistance
		if near ~= entry.visible then
			entry.visible = near
			pooled.model.Parent = if near then container() else nil
		end
		-- Walk-in (every input walks): free kinds claim (level-triggered with retry); paid kinds
		-- (owner R122) show / keep / hide the DEAL card — a walk-in never prompts by itself.
		local flat: number? = nil
		if root ~= nil then
			local rel = root - wire.position
			if rel.Y > -4 and rel.Y < LuckyButtonConfig.ClaimHeight then
				flat = math.sqrt(rel.X * rel.X + rel.Z * rel.Z)
			end
		end
		if entry.kind.paid then
			local action = LuckyButtonLogic.dealStep(entry.deal, flat)
			if action == "show" then
				showDeal(entry)
			elseif action == "hide" then
				closeDeal(entry, "away")
			end
		elseif root ~= nil then
			local inside = flat ~= nil and flat <= LuckyButtonConfig.ClaimRadius
			if inside and clock - entry.sentAt >= CFG.ClaimRetrySeconds then
				entry.sentAt = clock
				counters.claimsSent += 1
				Remotes.event("LuckyButtonClaim"):FireServer(wire.id)
			end
			entry.inside = inside
		end
		if not near or not ViewCone.visible(offset, look, cosLimit, 8) then
			continue -- off camera: keep the last pose, skip the motion
		end
		-- Blink in the last seconds: the cap flashes neon (steady glow with Reduce Motion).
		local blinking = LuckyButtonLogic.blinking(serverNow, wire.expires)
		local blinkOn = blinking and (not motion or math.floor(clock * CFG.BlinkHz * 2) % 2 == 0)
		if blinkOn ~= entry.blinkOn then
			entry.blinkOn = blinkOn
			if pooled.cap ~= nil then
				pooled.cap.Material = if blinkOn then Enum.Material.Neon else pooled.capMaterial
			end
		end
		if blinking and clock - entry.blinkSoundAt >= BLINK_SOUND_GAP then
			entry.blinkSoundAt = clock
			playSound("blink", wire.position)
		end
		-- Pose: pop-up rise (Back ease), bob, spin.
		local age = clock - entry.shownAt
		local rise = 0
		if motion and age < CFG.PopSeconds then
			local t = age / CFG.PopSeconds
			local s = 1.70158
			local back = 1 + (s + 1) * (t - 1) ^ 3 + s * (t - 1) ^ 2
			rise = -RISE_DEPTH * (1 - back)
		end
		local bob = if motion
			then CFG.BobHeight * (0.5 + 0.5 * math.sin((clock + entry.phase) * CFG.BobHz * 2 * math.pi))
			else 0
		local yaw = if motion then math.rad((clock + entry.phase) * CFG.SpinDegrees) else 0
		local pivot = CFrame.new(wire.position + Vector3.new(0, rise + bob, 0)) * CFrame.Angles(0, yaw, 0)
		n += 1
		movedParts[n] = pooled.root
		movedFrames[n] = pivot
		for index, part in pooled.parts do
			n += 1
			movedParts[n] = part
			movedFrames[n] = pivot * pooled.offsets[index]
		end
	end
	if n > 0 then
		-- Trim the shared buffers to this frame's count, then ONE bulk move.
		for index = #movedParts, n + 1, -1 do
			movedParts[index] = nil
			movedFrames[index] = nil
		end
		Workspace:BulkMoveTo(movedParts, movedFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
	if stale ~= nil then
		for _, id in stale do
			LuckyButtonClient.remove(id)
		end
	end
end

-- Connects / disconnects the Heartbeat with the live set (no work while nothing is live).
local function refreshLoop()
	if liveCount > 0 and heartbeat == nil then
		heartbeat = RunService.Heartbeat:Connect(step)
	elseif liveCount == 0 and heartbeat ~= nil then
		(heartbeat :: RBXScriptConnection):Disconnect()
		heartbeat = nil
	end
end

-- ── Live set ─────────────────────────────────────────────────────────────────────────────────

--[[
	Shows a validated button (spawn message). A known id is ignored.
	@param wire LuckyButtonLogic.Wire (already validated)
]]
function LuckyButtonClient.add(wire: LuckyButtonLogic.Wire)
	if live[wire.id] ~= nil then
		return
	end
	if wire.world ~= WorldClient.current() then
		counters.otherWorld += 1
		return
	end
	local kind = LuckyButtonConfig.byId(wire.kind)
	if kind == nil then
		counters.invalid += 1
		return
	end
	local okBuild, built = pcall(acquire)
	if not okBuild then
		counters.buildErrors += 1
		warn(`[LuckyButtonClient] model build failed: {built}`)
		return
	end
	local pooled = built :: Pooled
	dress(pooled, wire, kind)
	-- First pose before parenting (pop-up starts below the ground).
	local start = CFrame.new(wire.position - Vector3.new(0, if reduced() then 0 else RISE_DEPTH, 0))
	pooled.model:PivotTo(start)
	pooled.model.Parent = container()
	live[wire.id] = {
		wire = wire,
		kind = kind,
		pooled = pooled,
		shownAt = os.clock(),
		phase = math.random() * 10,
		inside = false,
		sentAt = -math.huge,
		blinkOn = false,
		blinkSoundAt = -math.huge,
		visible = true,
		deal = LuckyButtonLogic.newDeal(),
		dealHandle = nil,
		dealEnding = nil,
	}
	liveCount += 1
	counters.added += 1
	refreshLoop()
	Hud.notify("reward", CFG.ToastText, iconKey())
	playSound("spawn", nil) -- 2D: a notification wherever the camera is
	LuckyButtonClient.Changed:Fire()
end

--[[ Removes a button (no FX). ]]
function LuckyButtonClient.remove(id: string)
	local entry = live[id]
	if entry == nil then
		return
	end
	-- Owner R122: its DEAL card goes with it (bought, expired, cleared, another world).
	if entry.deal.showing or entry.dealHandle ~= nil then
		closeDeal(entry, "away")
	end
	live[id] = nil
	liveCount -= 1
	release(entry.pooled)
	refreshLoop()
	LuckyButtonClient.Changed:Fire()
end

--[[ Removes every button (world change / admin clear / kill switch). ]]
function LuckyButtonClient.clear()
	local ids = {}
	for id in live do
		table.insert(ids, id)
	end
	for _, id in ids do
		LuckyButtonClient.remove(id)
	end
end

-- Claim FX: confetti + sound + coins (free cash) or a toast (boost / purchase), then remove.
local function claimed(id: string, amount: number?, currency: string?)
	local entry = live[id]
	if entry == nil then
		return
	end
	counters.claimed += 1
	local position = entry.wire.position + Vector3.new(0, FX_HEIGHT, 0)
	local low = FxQuality.tier() == "Low" or reduced()
	Confetti.burst(
		position,
		if low then math.ceil(CFG.Confetti / 3) else CFG.Confetti,
		if low then math.ceil(CFG.Sparkles / 3) else CFG.Sparkles
	)
	playSound("claim", nil) -- 2D jingle
	if amount ~= nil and amount > 0 and currency ~= nil then
		CurrencyFly.fromWorld(currency, amount, position, "reward")
	elseif not entry.kind.paid then
		Hud.notify("reward", entry.kind.label, iconKey())
	end
	LuckyButtonClient.remove(id)
end

--[[
	The nearest live button to the character (or the camera), for the edge arrow.
	@return Target? ({ position, color, kind })
]]
function LuckyButtonClient.nearest(): Target?
	local from = characterRoot()
	if from == nil then
		local camera = Workspace.CurrentCamera
		from = if camera ~= nil then camera.CFrame.Position else nil
	end
	if from == nil then
		return nil
	end
	local best: Live? = nil
	local bestDistance = math.huge
	for _, entry in live do
		local distance = (entry.wire.position - from).Magnitude
		if distance < bestDistance then
			best = entry
			bestDistance = distance
		end
	end
	if best == nil then
		return nil
	end
	return { position = best.wire.position, color = best.kind.color, ui = best.kind.ui, kind = best.kind.id }
end

--[[ Number of live buttons (QA / arrow). ]]
function LuckyButtonClient.count(): number
	return liveCount
end

--[[
	A copy of this session's counters (QA / support): messages, invalid, otherWorld, added,
	claimsSent, claimed, expired, buildErrors, dealsShown, dealBuys (owner R122).
	Example: LuckyButtonClient.stats().added --> 3
]]
function LuckyButtonClient.stats(): { [string]: number }
	return table.clone(counters)
end

-- ── Remote ───────────────────────────────────────────────────────────────────────────────────

-- LuckyButtons (S→C) handler: every field is validated before use.
local function onMessage(raw: unknown)
	if type(raw) ~= "table" then
		return
	end
	counters.messages += 1
	local message = raw :: { [string]: unknown }
	local kind = message.kind
	if kind == "spawn" then
		local wire = LuckyButtonLogic.readWire(message.button)
		if wire ~= nil then
			LuckyButtonClient.add(wire)
		else
			counters.invalid += 1
		end
	elseif kind == "claimed" or kind == "expired" then
		local id = message.id
		if not LuckyButtonLogic.validId(id) then
			return
		end
		if kind == "expired" then
			counters.expired += 1
			LuckyButtonClient.remove(id :: string)
			return
		end
		local amount = message.amount
		local currency = message.currency
		local cleanAmount = if type(amount) == "number"
				and amount == amount
				and amount > 0
				and amount < math.huge
			then amount
			else nil
		local cleanCurrency = if type(currency) == "string"
				and #currency <= 24
				and string.match(currency, "^%w+$") ~= nil
			then currency
			else nil
		claimed(id :: string, cleanAmount, cleanCurrency)
	elseif kind == "clear" then
		LuckyButtonClient.clear()
	end
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────────────────────

--[[ Controller Init (nothing before Start). ]]
function LuckyButtonClient.Init() end

--[[ Starts listening (idempotent): the remote, world changes, mesh loads. ]]
function LuckyButtonClient.Start()
	if started then
		return
	end
	started = true
	-- Start the mesh load before the first button (pooled stud-box stand-ins built before the
	-- meshes finished are rebuilt on their next use: see acquire).
	PetModels.request(KEY)
	WorldClient.Changed:Connect(function()
		LuckyButtonClient.clear() -- the server clears too; never draw another world's buttons
	end)
	task.spawn(function()
		Remotes.event("LuckyButtons").OnClientEvent:Connect(onMessage)
	end)
end

return LuckyButtonClient
