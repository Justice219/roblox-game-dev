--!strict
--[[
	PetEmotes — the little world emotes above pets (owner R44): a burst of cartoon hearts when the
	owner buys / hatches / equips (with PetAnim's happy spin) and a sleepy "Z z z" bubble while the
	owner is AFK.

	Look: frame-drawn hearts (two round lobes + a rotated square, each with a chunky dark outline,
	a white shine dot — the Glyphs style) and Fredoka "Z" letters with the UI outline, on
	BillboardGuis that face the camera and are not lit (LightInfluence 0, never AlwaysOnTop).

	Performance (owner R11 — phones first):
		* POOLED: billboards are built the first time they are needed, up to the FxQuality tier's
		  PetAnimConfig.Tiers caps (Hearts / Zzz), then reused forever. No Instance.new per emote
		  once warm; a request beyond the cap is skipped (the pet still spins / sleeps).
		* `step(dt)` is called from PetController's one render step; it touches only ACTIVE emotes
		  (a few UIScale / Position / Transparency writes each) and returns at once when none are.
		* MaxDistance culls far billboards in the engine; disabled billboards cost nothing.

	Connects to: Client/Pets/PetController (hearts / setZzz / release / step),
	Shared/Config/{PetAnimConfig, UIStyleConfig}, Client/Tycoon/Fx/FxQuality.

	Example:
		PetEmotes.hearts(bodyPart, 2.4, 0.1, 80)        -- burst above the part, after 0.1 s
		PetEmotes.setZzz(slot, headPart, 2.2, true, 80)   -- start (key = any table)
		PetEmotes.setZzz(slot, nil, 0, false, 0)          -- stop
		PetEmotes.step(dt)                                -- once per frame
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FxQuality = require(script.Parent.Parent.Tycoon.Fx.FxQuality)
local PetAnimConfig = require(ReplicatedStorage.Shared.Config.PetAnimConfig)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local Happy = PetAnimConfig.Happy
local Sleep = PetAnimConfig.Sleep

local INK = UIStyleConfig.Neutral.Edge
local WHITE = Color3.new(1, 1, 1)
local TAU = 2 * math.pi

-- One heart burst: `count` hearts rising from the pet with a pop and a little sway.
type Burst = {
	gui: BillboardGui,
	hearts: { Frame },
	scales: { UIScale },
	t: number, -- seconds since start (negative while delayed)
	active: boolean,
}

-- One sleep bubble: three Z letters drifting up in a loop.
type Bubble = {
	gui: BillboardGui,
	letters: { TextLabel },
	strokes: { UIStroke },
	scales: { UIScale },
	t: number,
	active: boolean,
}

local PetEmotes = {}

local bursts: { Burst } = {}
local bubbles: { Bubble } = {}
local activeBursts = 0
local activeBubbles = 0
-- Sleep bubbles by owner key (a pet slot table).
local bubbleOf: { [any]: Bubble } = {}

--------------------------------------------------------------------------------------------------
-- Building (pooled: once per billboard)
--------------------------------------------------------------------------------------------------

-- The PlayerGui billboards live in (nil until it exists).
local function playerGui(): Instance?
	local player = Players.LocalPlayer
	return if player ~= nil then player:FindFirstChildOfClass("PlayerGui") else nil
end

-- A billboard shell (disabled until used).
local function newBillboard(name: string, size: Vector2): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Name = name
	gui.Size = UDim2.fromScale(size.X, size.Y) -- studs
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	gui.ResetOnSpawn = false
	gui.ClipsDescendants = false
	gui.Active = false
	gui.Enabled = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	return gui
end

-- A round or square shape on a heart's 1×1 canvas (centre-based fractions).
local function shape(
	parent: Instance,
	cx: number,
	cy: number,
	w: number,
	h: number,
	color: Color3,
	z: number,
	round: boolean,
	rotation: number
)
	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(cx, cy)
	frame.Size = UDim2.fromScale(w, h)
	frame.BackgroundColor3 = color
	frame.BorderSizePixel = 0
	frame.Rotation = rotation
	frame.ZIndex = z
	if round then
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = frame
	end
	frame.Parent = parent
end

--[[
	One cartoon heart: outline layer (INK, a little bigger) under the fill layer, plus a shine.
	Lobes at (0.32, 0.36) / (0.68, 0.36), point = a 45° square centred at (0.5, 0.58).
]]
local function buildHeart(parent: Instance): (Frame, UIScale)
	local heart = Instance.new("Frame")
	heart.Name = "Heart"
	heart.AnchorPoint = Vector2.new(0.5, 0.5)
	heart.Size = UDim2.fromScale(0.36, 0.33)
	heart.BackgroundTransparency = 1
	local scale = Instance.new("UIScale")
	scale.Scale = 0
	scale.Parent = heart
	local edge = 0.09
	for layer = 1, 2 do
		local grow = if layer == 1 then edge else 0
		local color = if layer == 1 then INK else Happy.HeartColor
		shape(heart, 0.32, 0.36, 0.44 + grow, 0.44 + grow, color, layer, true, 0)
		shape(heart, 0.68, 0.36, 0.44 + grow, 0.44 + grow, color, layer, true, 0)
		shape(heart, 0.5, 0.56, 0.48 + grow, 0.48 + grow, color, layer, false, 45)
	end
	shape(heart, 0.27, 0.3, 0.13, 0.13, WHITE, 3, true, 0)
	heart.Parent = parent
	return heart, scale
end

local function newBurst(parent: Instance): Burst
	local gui = newBillboard("PetHearts", Vector2.new(2.4, 2.8))
	local hearts: { Frame } = {}
	local scales: { UIScale } = {}
	for _ = 1, Happy.Hearts do
		local heart, scale = buildHeart(gui)
		table.insert(hearts, heart)
		table.insert(scales, scale)
	end
	gui.Parent = parent
	return { gui = gui, hearts = hearts, scales = scales, t = 0, active = false }
end

local function newBubble(parent: Instance): Bubble
	local gui = newBillboard("PetZzz", Vector2.new(1.8, 2.2))
	local letters: { TextLabel } = {}
	local strokes: { UIStroke } = {}
	local scales: { UIScale } = {}
	for _ = 1, 3 do
		local label = Instance.new("TextLabel")
		label.Name = "Z"
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Size = UDim2.fromScale(0.45, 0.32)
		label.BackgroundTransparency = 1
		label.Text = "Z"
		label.FontFace = UIStyleConfig.Fonts.Body
		label.TextScaled = true
		label.TextColor3 = Sleep.ZzzColor
		label.TextTransparency = 1
		local stroke = Instance.new("UIStroke")
		stroke.Color = INK
		stroke.Thickness = 2
		stroke.Transparency = 1
		stroke.Parent = label
		local scale = Instance.new("UIScale")
		scale.Parent = label
		label.Parent = gui
		table.insert(letters, label)
		table.insert(strokes, stroke)
		table.insert(scales, scale)
	end
	gui.Parent = parent
	return { gui = gui, letters = letters, strokes = strokes, scales = scales, t = 0, active = false }
end

-- Disables a billboard and drops its adornee (so a destroyed pet part is not kept alive by the
-- pool). The type definitions declare Adornee non-optional, hence the cast.
local function detach(gui: BillboardGui)
	gui.Enabled = false
	(gui :: any).Adornee = nil
end

-- The current tier's caps.
local function tier(): PetAnimConfig.Tier
	return PetAnimConfig.Tiers[FxQuality.tier()] or PetAnimConfig.Tiers.Mid
end

-- A free pooled entry (building one while under `cap`), or nil when the pool is exhausted.
local function take<T>(pool: { T }, cap: number, build: (Instance) -> T, isFree: (T) -> boolean): T?
	for index = 1, math.min(#pool, cap) do
		local entry = pool[index]
		if isFree(entry) then
			return entry
		end
	end
	if #pool >= cap then
		return nil
	end
	local parent = playerGui()
	if parent == nil then
		return nil
	end
	local entry = build(parent)
	table.insert(pool, entry)
	return entry
end

local function burstFree(entry: Burst): boolean
	return not entry.active
end

local function bubbleFree(entry: Bubble): boolean
	return not entry.active
end

--------------------------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------------------------

--[[
	A heart burst above `adornee` (a pet piece), `offsetY` studs above the part's centre.
	@param delay       seconds before it starts (team stagger)
	@param maxDistance engine culling distance (studs)
]]
function PetEmotes.hearts(adornee: BasePart, offsetY: number, delay: number, maxDistance: number)
	local burst = take(bursts, tier().Hearts, newBurst, burstFree)
	if burst == nil then
		return
	end
	burst.active = true
	burst.t = -math.max(delay, 0)
	burst.gui.Adornee = adornee
	burst.gui.StudsOffsetWorldSpace = Vector3.new(0, offsetY, 0)
	burst.gui.MaxDistance = maxDistance
	for _, scale in burst.scales do
		scale.Scale = 0
	end
	burst.gui.Enabled = true
	activeBursts += 1
end

--[[
	Starts / stops the sleep bubble of `key` (one per pet slot).
	@param key         any stable table (the pet slot)
	@param adornee     the piece to float above (nil when stopping)
	@param offsetY     studs above the part's centre
	@param on          true = show, false = hide + return to the pool
	@param maxDistance engine culling distance (studs)
]]
function PetEmotes.setZzz(key: any, adornee: BasePart?, offsetY: number, on: boolean, maxDistance: number)
	local current = bubbleOf[key]
	if not on or adornee == nil then
		if current ~= nil then
			bubbleOf[key] = nil
			current.active = false
			detach(current.gui)
			activeBubbles -= 1
		end
		return
	end
	if current ~= nil then
		current.gui.Adornee = adornee
		current.gui.StudsOffsetWorldSpace = Vector3.new(0, offsetY, 0)
		current.gui.MaxDistance = maxDistance
		return
	end
	local bubble = take(bubbles, tier().Zzz, newBubble, bubbleFree)
	if bubble == nil then
		return
	end
	bubble.active = true
	bubble.t = 0
	bubble.gui.Adornee = adornee
	bubble.gui.StudsOffsetWorldSpace = Vector3.new(0, offsetY, 0)
	bubble.gui.MaxDistance = maxDistance
	bubble.gui.Enabled = true
	bubbleOf[key] = bubble
	activeBubbles += 1
end

--[[ True when `key` currently shows a sleep bubble. ]]
function PetEmotes.hasZzz(key: any): boolean
	return bubbleOf[key] ~= nil
end

--[[ Releases everything `key` holds (a pet slot being destroyed). ]]
function PetEmotes.release(key: any)
	PetEmotes.setZzz(key, nil, 0, false, 0)
end

-- Smoothstep 0..1.
local function smooth(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

--[[
	Animates every active emote (call once per frame). Hearts: pop in, rise with a sway, shrink
	away; Zzz: three letters drift up and fade in a loop.
]]
function PetEmotes.step(dt: number)
	if activeBursts > 0 then
		local life = Happy.HeartsTime
		for _, burst in bursts do
			if not burst.active then
				continue
			end
			burst.t += dt
			if burst.t >= life + 0.3 then
				burst.active = false
				detach(burst.gui)
				activeBursts -= 1
				continue
			end
			local count = #burst.hearts
			for index, heart in burst.hearts do
				-- Each heart starts a little later and from its own column.
				local u = (burst.t - (index - 1) * 0.12) / life
				if u <= 0 then
					burst.scales[index].Scale = 0
					continue
				end
				local column = if count > 1 then (index - 1) / (count - 1) else 0.5
				local x = 0.28 + column * 0.44 + math.sin(u * TAU * 1.2 + index) * 0.08
				local y = 0.85 - smooth(u) * 0.7
				heart.Position = UDim2.fromScale(x, y)
				heart.Rotation = math.sin(u * TAU + index) * 12
				-- Pop to 1.15, settle at 1, shrink away over the last quarter.
				local pop = if u < 0.15 then smooth(u / 0.15) * 1.15 else 1 + 0.15 * (1 - smooth((u - 0.15) / 0.15))
				local fade = if u > 0.75 then 1 - smooth((u - 0.75) / 0.25) else 1
				burst.scales[index].Scale = math.max(pop * fade, 0)
			end
		end
	end
	if activeBubbles > 0 then
		local period = Sleep.ZzzPeriod
		for _, bubble in bubbles do
			if not bubble.active then
				continue
			end
			bubble.t = (bubble.t + dt) % (period * 3)
			for index, label in bubble.letters do
				-- Three letters a third of a period apart, each looping bottom-left → top-right.
				local u = ((bubble.t / period) + (index - 1) / 3) % 1
				label.Position = UDim2.fromScale(0.3 + u * 0.45, 0.85 - u * 0.7)
				label.Rotation = -12 + u * 18
				bubble.scales[index].Scale = 0.6 + u * 0.55
				local alpha = if u < 0.2 then 1 - u / 0.2 elseif u > 0.7 then (u - 0.7) / 0.3 else 0
				label.TextTransparency = alpha
				bubble.strokes[index].Transparency = alpha
			end
		end
	end
end

return PetEmotes
