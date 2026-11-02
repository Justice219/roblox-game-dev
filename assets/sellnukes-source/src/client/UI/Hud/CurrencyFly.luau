--!strict
--[[
	CurrencyFly — money flies into the HUD counters (owner R46: "add particles on screen going into
	the money on the top").

	What it does:
		Whenever cash goes up, cash sprites (the rendered 3D Cash icon) burst from where the money
		came from and fly on a curved, spinning, shrinking path into the top-centre cash counter;
		gems fly into the gem counter. Each landing pops + glints the counter (HudCurrency.land)
		and plays a soft coin tick whose pitch climbs during a streak. Big bursts mix in a few
		twinkling stars (the Star icon) that land silently.

	Sources (CurrencyFlyConfig.Sources):
		click     a clicked producer's payout: 2-4 sprites from its pop point (IncomePops)
		tick      an automated / auto-clicker payout: 1-2 sprites, at most one burst per 1.2 s
		reward    a reward toast's cash (daily / time / wheel / codes / group ...): 12-20 from the
		          HUD's safe-area centre
		purchase  a Robux product's cash (PurchaseGranted): 12-20 from the centre
		offline   the welcome-back payout: 14-20 from the centre when that window closes ("claim")
		gems      every gem increase flies into the gem counter from the centre
	World currencies (owner R57 World 2): every WorldsConfig currency key is a fly kind too
	("bones"): a Dino producer's payout (fromProducer(..., "bones")) and an unexplained Bones
	increase paired with a reward / purchase signal (Bones packs) fly into the Bones counter. A
	kind whose counter is not on screen (Bones while in Nuke Town) never spawns sprites.
	Counts scale with log10(amount), with the FxQuality tier (Low = a third) and are capped by
	Reduce Motion (a short straight fade under the counter instead of the flight).

	How rewards are told apart from income (CurrencyFlyRules.grantPart / onGrant / onHint):
	a profile cash increase is a "grant" only when it beats the expected income (the HUD's $/s x
	the time since the last push + producer payouts seen lately) AND a reward toast
	(ClientState.Notified kind "reward") or a PurchaseGranted arrives within a short window, in
	either order. So clicks, ticks, spending and pet / spin rewards never fly from the centre.

	Visual only: nothing here changes or sends a value; the counter's roll-up is the server's
	profile sync (Hud). Owner bug R61 guards: sprites only target a counter that is really drawn
	(every ancestor visible, laid out) and is the current world's counter of that kind
	(HudCurrency via CurrencyFlyRules.counterFor; Cash has none outside Nuke Town, R60); balance
	decreases (spends) and unchanged balances (world swaps) never fly (Rules.isIncrease); a gui
	origin inside a billboard is projected to the screen (Widgets/ScreenRect). World producers that are off-screen, too far, or covered by a window
	never spawn sprites.

	Performance (console / phone): one pool of CurrencyFlyConfig.Capacity ImageLabels (+ a
	UICorner each for the no-image fallback), all built at start — no Instance.new afterwards;
	a global cap of live sprites; one PreRender connection that exists only while sprites fly and
	disconnects when idle; the counters' screen positions are read once per frame; transparency is
	written only when it changes. Every sprite is Active = false / not Selectable on its own
	ScreenGui, so touch, mouse and gamepad selection are never blocked.

	Console + mobile (owner R11): targets are the HUD icons, which already sit inside the TV-safe /
	notch-safe HUD; the centre origin is the HUD root's (safe) centre; sizes come from the icon's
	on-screen size, so phones get smaller sprites and TVs bigger ones.

	Connects to: UI/Hud/Hud (attach: counter targets, landing, HUD gui, safe area, rate per kind),
	UI/Hud/HudCurrency (target / land), UI/Hud/CurrencyFlyRules (maths), Tycoon/IncomePops
	(fromWorld), Client/ClientState (ProfileChanged / Notified / PurchaseGranted),
	UI/ScreenManager (modal state, welcome-back open / close), UI/Widgets/OfferFx (reduced motion),
	Tycoon/Fx/FxQuality (tier), Client/Audio/Sound (ticks), UI/Kit/StudUI (icon images),
	Shared/Config/CurrencyFlyConfig.

	Example:
		CurrencyFly.attach({ target = currency.target, land = currency.land, gui = hudGui,
			area = hudRoot, rate = currentRate })
		CurrencyFly.start()
		CurrencyFly.fromProducer(1250, popPoint.WorldPosition, false, record.lastClick, 1)
		CurrencyFly.fromWorld("cash", 1250, somePosition, "click")
		CurrencyFly.fromScreen("gems", 100, "reward") -- from the screen centre
		CurrencyFly.fromProducer(40, popPoint.WorldPosition, true, 0, 2, "bones") -- a Dino producer
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ClientState = require(script.Parent.Parent.Parent.ClientState)
local CurrencyFlyConfig = require(ReplicatedStorage.Shared.Config.CurrencyFlyConfig)
local FxQuality = require(script.Parent.Parent.Parent.Tycoon.Fx.FxQuality)
local OfferFx = require(script.Parent.Parent.Widgets.OfferFx)
local Rules = require(script.Parent.CurrencyFlyRules)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local ScreenRect = require(script.Parent.Parent.Widgets.ScreenRect)
local Sound = require(script.Parent.Parent.Parent.Audio.Sound)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

-- "cash" | "gems" | a world currency key ("bones"; CurrencyFlyRules.isKind).
export type Kind = string
export type Source = Rules.Source

-- What Hud hands over: the counters and the HUD's state (see attach).
export type Counter = {
	-- The counter icon sprites of `kind` fly into; nil when that counter is not shown.
	target: (kind: Kind) -> GuiObject?,
	land: (kind: Kind, reduced: boolean) -> (), -- landing feedback (pop + glint + flash)
	gui: ScreenGui, -- the HUD ScreenGui (disabled = HUD hidden: nothing flies)
	area: GuiObject, -- the HUD root (inside the safe area): centre bursts start at its centre
	rate: (kind: Kind) -> number?, -- the player's income of `kind` per second (attribution)
}

-- Which picture a pooled sprite shows: an IconAssets key ("Cash", "Gems", "Bones", ...) or "Star".
type Visual = string

-- Income attribution state of one money kind (cash + every world currency; gems fly directly).
type Tracker = {
	matcher: Rules.Matcher,
	last: number?,
	lastAt: number,
}

type Slot = {
	root: ImageLabel,
	plan: Rules.Plan,
	kind: Kind,
	visual: Visual,
	image: boolean, -- false: no uploaded image, the rounded background is the sprite
	live: boolean,
	started: number,
	size: number, -- px at scale 1
	transparency: number, -- last written (writes only on change)
}

local CurrencyFly = {}

local Config = CurrencyFlyConfig
local Land = Config.Land
local World = Config.World
local CAPACITY = Config.Capacity
local POP_RING = 32

-- Fallback colours while an icon image is not uploaded (a gold coin / purple gem / pale star;
-- world currencies add their CurrencyDef colour at start).
local FALLBACK: { [Visual]: Color3 } = {
	Cash = Color3.fromRGB(255, 204, 40),
	Gems = Color3.fromRGB(206, 130, 255),
	Star = Color3.fromRGB(255, 244, 170),
}
local DEFAULT_FALLBACK = Color3.fromRGB(255, 204, 40)

local counter: Counter? = nil
local overlay: ScreenGui? = nil
local canvas: Frame? = nil
local slots: { Slot } = {}
local images: { [Visual]: string? } = {}
local render: RBXScriptConnection? = nil
local started = false
local live = 0
local serial = 0
-- Last burst time per (kind, source): a reward paying cash AND gems flies into both counters.
local lastBurst: { [Kind]: { [string]: number } } = {}
-- Bursts spawned per source ("gems" for gem bursts): Studio probes / QA only.
local bursts: { [string]: number } = {}
-- Landing tick state (soft, rate-limited, pitch climbs during a streak).
local lastTick, lastLanding, streak = -math.huge, -math.huge, 0
-- Income ledger: recent producer payouts (ring, per kind) so clicks / ticks never count as rewards.
local popAmounts: { number } = table.create(POP_RING, 0)
local popTimes: { number } = table.create(POP_RING, -math.huge)
local popKinds: { Kind } = table.create(POP_RING, "cash")
local popCursor = 0
-- Profile tracking for reward / purchase bursts: "cash" + every world currency key.
local trackers: { [Kind]: Tracker } = {}
local lastGems: number? = nil
local absorbUntil = -math.huge
local offlinePending = false
-- Re-used per-frame landing counters / target points + tick options (no allocation in the step:
-- the per-kind tables are created once, the first time a kind flies).
local landed: { [Kind]: number } = { cash = 0, gems = 0 }
local targetX: { [Kind]: number } = {}
local targetY: { [Kind]: number } = {}
local targetFrame: { [Kind]: number } = {}
local frameSerial = 0
local tickOptions: Sound.PlayOptions = { volume = Land.TickVolume, pitch = Land.TickPitch }

--[[
	True when `object` is really drawn: it and every GuiObject ancestor Visible, its ScreenGui
	enabled, and it has a laid-out size (owner R61: a hidden or not-yet-laid-out counter reports
	a stale AbsolutePosition, e.g. the top-left corner, and sprites must never fly there).
]]
local function drawn(object: GuiObject): boolean
	if object.AbsoluteSize.X < 4 or object.AbsoluteSize.Y < 4 then
		return false
	end
	local node: Instance? = object
	while node ~= nil do
		if node:IsA("GuiObject") then
			if not node.Visible then
				return false
			end
		elseif node:IsA("LayerCollector") then
			return node.Enabled
		end
		node = node.Parent
	end
	return false
end

-- A finite number from an untyped value, else nil.
local function finite(value: unknown): number?
	if type(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return value
	end
	return nil
end

-- Canvas-space centre of a gui object (AbsolutePosition shares one space; the canvas is the origin).
local function centreOf(object: GuiObject, origin: Vector2): (number, number)
	local position, size = object.AbsolutePosition, object.AbsoluteSize
	return position.X + size.X / 2 - origin.X, position.Y + size.Y / 2 - origin.Y
end

-- Writes a sprite's transparency (image or fallback background).
local function paint(slot: Slot, transparency: number)
	slot.transparency = transparency
	if slot.image then
		slot.root.ImageTransparency = transparency
	else
		slot.root.BackgroundTransparency = transparency
	end
end

-- One pooled sprite (an ImageLabel; the UICorner rounds the no-image fallback).
local function makeSlot(parent: Frame): Slot
	local root = Instance.new("ImageLabel")
	root.Name = "FlySprite"
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Size = UDim2.fromOffset(32, 32)
	root.ScaleType = Enum.ScaleType.Fit
	root.Active = false
	root.Selectable = false
	root.Visible = false
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = root
	root.Parent = parent
	return {
		root = root,
		plan = Rules.newPlan(),
		kind = "cash" :: Kind,
		visual = "Cash" :: Visual,
		image = true,
		live = false,
		started = 0,
		size = 32,
		transparency = -1,
	}
end

-- Shows a slot as `visual` (sets the image or the fallback colour; only on change).
local function theme(slot: Slot, visual: Visual)
	local image = images[visual]
	slot.visual = visual
	slot.image = image ~= nil
	if image ~= nil then
		if slot.root.Image ~= image then
			slot.root.Image = image
		end
		slot.root.BackgroundTransparency = 1
	else
		slot.root.Image = ""
		slot.root.BackgroundColor3 = FALLBACK[visual] or DEFAULT_FALLBACK
	end
	slot.transparency = -1
end

-- Hides every sprite and drops the per-frame connection.
local function clear()
	for _, slot in slots do
		if slot.live then
			slot.live = false
			slot.root.Visible = false
		end
	end
	live = 0
	if render ~= nil then
		render:Disconnect()
		render = nil
	end
end

-- Landing feedback for the `kind` sprites that arrived this frame (once per kind per frame).
local function landing(kind: Kind, reduced: boolean)
	local target = counter
	if target ~= nil then
		pcall(target.land, kind, reduced)
	end
	local now = os.clock()
	if now - lastLanding > Land.StreakReset then
		streak = 0
	end
	lastLanding = now
	if now - lastTick < Land.TickGap then
		return
	end
	lastTick = now
	local pitch = math.min(Land.TickPitch + streak * Land.TickPitchStep, Land.TickPitchMax)
	streak += 1
	local key = Rules.sound(kind)
	if key ~= nil then
		tickOptions.pitch = pitch
		Sound.play(key, tickOptions)
	end
end

-- The single per-frame step (connected only while sprites fly).
local function step()
	local target, layer = counter, canvas
	if target == nil or layer == nil or not target.gui.Enabled then
		clear()
		return
	end
	local origin = layer.AbsolutePosition
	local now = os.clock()
	local remaining = 0
	-- Counter points are read once per frame per kind in flight (re-laid-out HUDs still catch).
	frameSerial += 1
	for kind in landed do
		landed[kind] = 0
	end
	for _, slot in slots do
		if not slot.live then
			continue
		end
		local kind = slot.kind
		if targetFrame[kind] ~= frameSerial then
			targetFrame[kind] = frameSerial
			local object = target.target(kind)
			if object ~= nil and drawn(object) then
				targetX[kind], targetY[kind] = centreOf(object, origin)
			else
				targetX[kind], targetY[kind] = nil, nil
			end
		end
		local tx, ty = targetX[kind], targetY[kind]
		if tx == nil or ty == nil then
			-- Its counter left the screen mid-flight (a world switch): drop the sprite.
			slot.live = false
			slot.root.Visible = false
			continue
		end
		local x, y, rotation, scale, transparency, done = Rules.pose(slot.plan, now - slot.started, tx, ty)
		if done then
			slot.live = false
			slot.root.Visible = false
			if slot.visual ~= "Star" then
				landed[kind] = (landed[kind] or 0) + 1
			end
			continue
		end
		local root = slot.root
		root.Position = UDim2.fromOffset(x, y)
		root.Rotation = rotation
		local px = slot.size * scale
		root.Size = UDim2.fromOffset(px, px)
		if transparency ~= slot.transparency then
			paint(slot, transparency)
		end
		remaining += 1
	end
	live = remaining
	local reduced: boolean? = nil
	for kind, count in landed do
		if count > 0 then
			if reduced == nil then
				reduced = OfferFx.reducedMotion()
			end
			landing(kind, reduced == true)
		end
	end
	if remaining == 0 then
		clear()
	end
end

--[[
	Spawns one burst at canvas point (x, y) (nil = the HUD's safe-area centre).
	@param kind   "cash" | "gems" | a world currency key ("bones")
	@param amount money paid (finite > 0; nil = unknown -> CurrencyFlyConfig.UnknownFraction)
	@param source burst source (count, spread, gap)
]]
local function spawnBurst(kind: Kind, amount: number?, source: Source, x: number?, y: number?)
	local target, layer = counter, canvas
	if target == nil or layer == nil or not target.gui.Enabled then
		return
	end
	local spec = Config.Sources[source]
	if spec == nil then
		return
	end
	if not Rules.isKind(kind) then
		return
	end
	local now = os.clock()
	-- Per-counter gaps: a reward paying cash AND gems flies into both counters at once.
	local gaps = lastBurst[kind]
	if gaps == nil then
		gaps = {}
		lastBurst[kind] = gaps
	end
	if now - (gaps[source] or -math.huge) < spec.Gap then
		return
	end
	local icon = target.target(kind)
	if icon == nil then
		return -- no counter of this kind on screen (Bones while in Nuke Town)
	end
	local unit = icon.AbsoluteSize.X
	if not drawn(icon) then
		return -- the HUD is not laid out / the counter (or its row) is hidden
	end
	local reduced = OfferFx.reducedMotion()
	local count = Rules.admit(Rules.count(source, amount, FxQuality.tier(), reduced), live, CAPACITY)
	if count <= 0 then
		return
	end
	gaps[source] = now
	local origin = layer.AbsolutePosition
	local ox: number, oy: number
	if x ~= nil and y ~= nil then
		ox, oy = x, y
	else
		ox, oy = centreOf(target.area, origin)
	end
	local stars = if reduced then 0 else Rules.sparkles(source, count)
	local size = math.clamp(unit * Config.Sprite.Scale, Config.Sprite.MinPx, Config.Sprite.MaxPx)
	local visual: Visual = Rules.iconOf(kind)
	if images[visual] == nil and FALLBACK[visual] == nil then
		images[visual] = StudUI.iconImage(visual)
	end
	if landed[kind] == nil then
		landed[kind] = 0
	end
	serial += 1
	local index = 0
	for _, slot in slots do
		if index >= count then
			break
		end
		if slot.live then
			continue
		end
		index += 1
		local star = index > count - stars
		theme(slot, if star then "Star" else visual)
		slot.kind = kind
		slot.size = size
		slot.started = now
		slot.live = true
		Rules.plan(slot.plan, serial * 37 + index, index, source, ox, oy, unit, reduced, star)
		if kind == "gems" and not star then
			slot.plan.spin *= Config.Sprite.GemSpin
		end
		paint(slot, 1)
		slot.root.Visible = true
	end
	live += index
	local key = if kind == "gems" then "gems" else source
	bursts[key] = (bursts[key] or 0) + 1
	if render == nil and live > 0 then
		render = RunService.PreRender:Connect(step)
	end
end

--[[
	Hud hands over its counters (called from the HUD build, before start()).
	@param target Counter { target, land, gui, area, rate }
]]
function CurrencyFly.attach(target: Counter)
	counter = target
end

-- Records a producer payout of `kind` in the income ledger (newest overwrites the oldest).
local function notePop(kind: Kind, amount: number)
	popCursor = popCursor % POP_RING + 1
	popAmounts[popCursor] = amount
	popTimes[popCursor] = os.clock()
	popKinds[popCursor] = kind
end

-- Producer payouts of `kind` seen in the last PopWindow seconds.
local function popSum(now: number, kind: Kind): number
	local total = 0
	local window = Config.Attribution.PopWindow
	for index = 1, POP_RING do
		if popKinds[index] == kind and now - popTimes[index] <= window then
			total += popAmounts[index]
		end
	end
	return total
end

--[[
	Money from a world point (a producer's pop point): flies only when that point is on screen,
	within World.MaxDistance of the camera and no window covers the world. Cash payouts are also
	recorded as income so they never count as rewards.
	@param kind     "cash" | "gems" | a world currency key ("bones")
	@param amount   money paid (finite > 0)
	@param position world position
	@param source   "click" (a clicked producer) | "tick" (an automated one)
	Example: CurrencyFly.fromWorld("cash", 1250, record.popPoint.WorldPosition, "click")
]]
function CurrencyFly.fromWorld(kind: Kind, amount: number, position: Vector3, source: Source)
	local value = finite(amount)
	if value == nil or value <= 0 or typeof(position) ~= "Vector3" or not Rules.isKind(kind) then
		return
	end
	if kind ~= "gems" then
		notePop(kind, value)
	end
	if canvas == nil or ScreenManager.anyModalOpen() then
		return
	end
	local camera = Workspace.CurrentCamera
	if camera == nil or (camera.CFrame.Position - position).Magnitude > World.MaxDistance then
		return
	end
	local point, onScreen = camera:WorldToViewportPoint(position)
	local viewport = camera.ViewportSize
	local margin = World.EdgeMargin
	if
		not onScreen
		or point.Z <= 0
		or point.X < margin
		or point.Y < margin
		or point.X > viewport.X - margin
		or point.Y > viewport.Y - margin
	then
		return
	end
	-- Viewport space == the overlay canvas (IgnoreGuiInset, no screen insets).
	spawnBurst(kind, value, source, point.X, point.Y)
end

--[[
	A producer payout from its billboard record (Tycoon/IncomePops): "click" right after the
	player's own click on a manual producer, else an occasional "tick" (managers, auto-clicker).
	@param automated  record.automated
	@param lastClick  record.lastClick (Workspace:GetServerTimeNow() of the last own click)
	@param cycleTime  record.cycleTime
	@param kind       the producer's currency (nil = "cash"; Dino producers pay "bones" — the
	                  caller resolves it from the globally unique producer id, R57)
	Example: CurrencyFly.fromProducer(1250, popPoint.WorldPosition, false, record.lastClick, 1)
]]
function CurrencyFly.fromProducer(
	amount: number,
	position: Vector3,
	automated: boolean,
	lastClick: number,
	cycleTime: number,
	kind: Kind?
)
	local source = Rules.payoutSource(automated, Workspace:GetServerTimeNow() - lastClick, cycleTime)
	CurrencyFly.fromWorld(kind or "cash", amount, position, source)
end

--[[
	Money from a screen point (canvas px; nil = the HUD's safe-area centre).
	@param amount money paid (finite > 0) or nil when unknown
	Example: CurrencyFly.fromScreen("gems", 100, "reward")
]]
function CurrencyFly.fromScreen(kind: Kind, amount: number?, source: Source, point: Vector2?)
	if amount ~= nil and (finite(amount) == nil or amount <= 0) then
		return
	end
	spawnBurst(kind, amount, source, if point ~= nil then point.X else nil, if point ~= nil then point.Y else nil)
end

--[[
	Money from a gui object's centre (e.g. a CLAIM button): any screen may call it.
	Example: CurrencyFly.fromGui("cash", 5000, "reward", claimButton)
]]
function CurrencyFly.fromGui(kind: Kind, amount: number?, source: Source, object: GuiObject)
	local layer = canvas
	-- The object's real screen rect (a billboard button is projected, owner R61).
	local position, size = ScreenRect.of(object)
	if layer == nil or position == nil or size == nil or size.X <= 0 then
		CurrencyFly.fromScreen(kind, amount, source)
		return
	end
	local origin = layer.AbsolutePosition
	CurrencyFly.fromScreen(
		kind,
		amount,
		source,
		Vector2.new(position.X + size.X / 2 - origin.X, position.Y + size.Y / 2 - origin.Y)
	)
end

-- The attribution tracker of a money kind (created once per kind).
local function trackerOf(kind: Kind): Tracker
	local existing = trackers[kind]
	if existing ~= nil then
		return existing
	end
	local tracker: Tracker = { matcher = Rules.newMatcher(), last = nil, lastAt = 0 }
	trackers[kind] = tracker
	return tracker
end

-- A reward toast / PurchaseGranted: flies pending unexplained money (any kind), or waits for it.
local function onHint(source: Source)
	local now = os.clock()
	for kind, tracker in trackers do
		local amount, matched = Rules.onHint(tracker.matcher, source, now)
		if amount ~= nil and matched ~= nil then
			spawnBurst(kind, amount, matched)
		end
	end
end

--[[
	One money kind's balance moved: an increase beyond the expected income (rate x time + recent
	producer payouts) is a grant, paired with a reward / purchase signal (CurrencyFlyRules).
	@param kind  "cash" or a world currency key
	@param value the new balance (server truth)
	@param now   os.clock()
]]
local function onBalance(kind: Kind, value: number, now: number)
	local tracker = trackerOf(kind)
	local previous = tracker.last
	local dt = now - tracker.lastAt
	tracker.last, tracker.lastAt = value, now
	-- Spends (upgrades, pad buys, eggs) and unchanged balances (a world swap) never fly (R61).
	if previous == nil or not Rules.isIncrease(previous, value) then
		return
	end
	local target = counter
	local rate: number? = nil
	if target ~= nil then
		local ok, result = pcall(target.rate, kind)
		rate = if ok then finite(result) else nil
	end
	local part = Rules.grantPart(value - previous, rate, dt, popSum(now, kind))
	if part > 0 and now >= absorbUntil then
		local amount, source = Rules.onGrant(tracker.matcher, part, now)
		if amount ~= nil and source ~= nil then
			spawnBurst(kind, amount, source)
		end
	end
end

-- Profile pushes: cash / world-currency grants (paired with a signal) and every gem increase.
local function onProfile(profile: ClientState.Profile, fields: { string }?)
	local cash = finite(profile.cash)
	local gems = finite(profile.gems)
	local now = os.clock()
	if fields == nil then
		-- A full snapshot (join / resync): re-baseline only.
		local cashTracker = trackerOf("cash")
		cashTracker.last, cashTracker.lastAt = cash, now
		lastGems = gems
		for _, def in WorldsConfig.extra() do
			local tracker = trackerOf(def.currency.key)
			tracker.last, tracker.lastAt = ClientState.worldCash(def.id), now
		end
		return
	end
	if cash ~= nil and table.find(fields, "cash") ~= nil then
		onBalance("cash", cash, now)
	end
	-- World currencies (Bones, ...) move in their own small "worldCash" delta field.
	if table.find(fields, "worldCash") ~= nil then
		for _, def in WorldsConfig.extra() do
			onBalance(def.currency.key, ClientState.worldCash(def.id), now)
		end
	end
	if gems ~= nil and table.find(fields, "gems") ~= nil then
		local previous = lastGems
		lastGems = gems
		if previous ~= nil and Rules.isIncrease(previous, gems) then
			spawnBurst("gems", gems - previous, "reward")
		end
	end
end

--[[ Counters for Studio probes / tests. ]]
function CurrencyFly.state(): {
	capacity: number,
	live: number,
	running: boolean,
	ready: boolean,
	bursts: { [string]: number },
}
	return {
		capacity = #slots,
		live = live,
		running = render ~= nil,
		ready = overlay ~= nil and counter ~= nil,
		bursts = table.clone(bursts),
	}
end

--[[
	Builds the overlay + the whole pool and starts listening (once; Hud calls it from its build).
	The overlay is created on the next resumption cycle (PlayerGui may still be loading).
]]
function CurrencyFly.start()
	if started then
		return
	end
	started = true
	images.Cash = StudUI.iconImage("Cash")
	images.Gems = StudUI.iconImage("Gems")
	images.Star = StudUI.iconImage("Star")
	-- World currencies (R57): their icon + a fallback colour, and an attribution tracker each.
	trackerOf("cash")
	for _, def in WorldsConfig.extra() do
		local icon = def.currency.icon
		images[icon] = StudUI.iconImage(icon)
		FALLBACK[icon] = def.currency.color
		trackerOf(def.currency.key)
	end
	task.spawn(function()
		local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
		local gui = Instance.new("ScreenGui")
		gui.Name = "CurrencyFly"
		gui.ResetOnSpawn = false
		gui.IgnoreGuiInset = true
		gui.ScreenInsets = Enum.ScreenInsets.None
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.DisplayOrder = Config.DisplayOrder
		local layer = Instance.new("Frame")
		layer.Name = "Sprites"
		layer.BackgroundTransparency = 1
		layer.Size = UDim2.fromScale(1, 1)
		layer.Active = false
		layer.Selectable = false
		layer.Parent = gui
		for index = 1, CAPACITY do
			slots[index] = makeSlot(layer)
		end
		gui.Parent = playerGui
		overlay, canvas = gui, layer
	end)
	ClientState.ProfileChanged:Connect(onProfile)
	local profile = ClientState.profile
	if profile ~= nil then
		onProfile(profile, nil)
	end
	ClientState.Notified:Connect(function(payload: ClientState.NotifyPayload)
		if payload.kind == "reward" then
			onHint("reward")
		end
	end)
	ClientState.PurchaseGranted:Connect(function()
		onHint("purchase")
	end)
	-- The welcome-back window shows the offline payout; closing it is the claim that flies it in.
	if ScreenManager.isOpen(Config.OfflineScreen) then
		offlinePending = true
	end
	ScreenManager.Opened:Connect(function(name: string)
		if name == Config.OfflineScreen then
			offlinePending = true
			absorbUntil = os.clock() + Config.Attribution.OfflineAbsorb
			for _, tracker in trackers do
				Rules.clearGrant(tracker.matcher)
			end
		end
	end)
	ScreenManager.Closed:Connect(function(name: string)
		if name == Config.OfflineScreen and offlinePending then
			offlinePending = false
			task.defer(function()
				spawnBurst("cash", nil, "offline")
			end)
		end
	end)
	-- The HUD hiding (focus mode, e.g. an egg hatch) drops sprites in flight.
	local target = counter
	if target ~= nil then
		target.gui:GetPropertyChangedSignal("Enabled"):Connect(function()
			if not target.gui.Enabled then
				clear()
			end
		end)
	end
end

return CurrencyFly
