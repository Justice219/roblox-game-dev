--!strict
--[[
	ButtonFeedback — a sound and a particle burst on EVERY button press (owner rule R22:
	"whenever you click the upgrade button you hear a sound and see particles — particles that
	spin around the button or drop down from it"). Ported from RoBeasts' ButtonFeedback.

	What a press does:
		- plays a Sound (Client/Audio/Sound): "ui_click", "ui_claim" for Coins presses,
		  "ui_locked" on a locked / unaffordable button, or the button's own FeedbackSound
		  ("upgrade", "producer_pop", ...; "" = silent),
		- spawns a pooled burst of stars / studs / coins, colour-matched to the button's StudUI
		  preset, that ORBITS just outside the button and then DROPS down with gravity
		  (ButtonFeedbackRules.pose); purchases / claims / upgrades burst bigger,
		- hover (mouse only, desktop) plays a throttled "ui_hover"; opening / closing a modal plays
		  "ui_open" / "ui_close".
	Works for ScreenGui buttons AND world billboard buttons: a BillboardGui button reports its
	AbsolutePosition in the billboard's own canvas, so its burst rect comes from
	Widgets/ScreenRect (projected through the camera). Owner bug R61: the billboard UPGRADE's
	coin burst used to land around the top-left HUD tiles.

	Button attributes (StudUI sets them; any screen may):
		FeedbackKind    "Stars" | "Studs" | "Coins"          FeedbackColor   UIStyleConfig ColorName
		FeedbackSound   Sound key, "" = silent              FeedbackLocked  true = locked sound, no burst
		FeedbackBig     bigger burst                         FeedbackManual  the owner calls fire() itself
		ButtonParticlesDisabled  no burst at all (sound still plays)

	Performance (console / phone): one fixed pool of ButtonFeedbackRules.Capacity particles
	(12 built at start, the rest on first need: no Instance.new once warm), one PreRender
	connection that exists only while a burst is alive, bursts closer than MinGap merge, the
	count follows B4's FxQuality tier (Low 5 / Mid 8 / High 12) and Reduce Motion (Roblox or
	SellNukes settings) means sound only. Raw Instance.new (not Create.new): Create calls bind().

	Connects to: UI/Create (setButtonFeedbackBinder, by UIController), UI/ButtonFeedbackRules,
	Client/Audio/Sound, Tycoon/Fx/FxQuality (tier, optional), Widgets/OfferFx (reduced motion),
	Controllers/InputController (hover only with a mouse), UI/ScreenManager (foreground, open /
	close sounds), Widgets/ScreenRect (billboard buttons' screen rect), Shared/Config/UIStyleConfig
	(colours).

	Example:
		Create.setButtonFeedbackBinder(ButtonFeedback.bind) -- before any screen builds
		ButtonFeedback.start(playerGui)
		ButtonFeedback.fire(upgradeButton) -- manual feedback (keyboard / gamepad upgrade)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local InputController = require(script.Parent.Parent.Controllers.InputController)
local OfferFx = require(script.Parent.Widgets.OfferFx)
local Rules = require(script.Parent.ButtonFeedbackRules)
local ScreenManager = require(script.Parent.ScreenManager)
local ScreenRect = require(script.Parent.Widgets.ScreenRect)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

type Kind = Rules.Kind
type Slot = {
	root: Frame,
	scale: UIScale,
	motifs: { [Kind]: Frame },
	paints: { [Kind]: { Frame } },
	stroke: UIStroke,
	kind: Kind,
	live: boolean,
	started: number,
	seed: number,
	x: number,
	y: number,
	w: number,
	h: number,
}

local ButtonFeedback = {}

local CAPACITY = Rules.Capacity
local PREWARM = 12
local HOVER_GAP = 0.08
local COIN = Color3.fromRGB(255, 204, 40)
local COIN_DARK = Color3.fromRGB(214, 150, 12)
local EDGE = UIStyleConfig.Neutral.Edge

local bound: { [GuiButton]: { RBXScriptConnection } } = {}
local slots: { Slot } = {}
local overlay: ScreenGui? = nil
local canvas: Frame? = nil
local render: RBXScriptConnection? = nil
local cursor, serial, active = 0, 0, 0
local lastBurst, lastHover = -math.huge, -math.huge
local soundPlay: ((key: string) -> ())? = nil
local tierRead: (() -> string)? = nil

-- A raw Frame (never Create.new: Create calls bind for buttons).
local function frame(parent: Instance, name: string, color: Color3, size: UDim2, position: UDim2, radius: number): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundColor3 = color
	f.BorderSizePixel = 0
	f.Size = size
	f.Position = position
	f.Active = false
	f.Selectable = false
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(radius, 0)
	corner.Parent = f
	f.Parent = parent
	return f
end

-- Builds one pooled particle with all three motifs (only the chosen one is visible).
local function makeSlot(parent: Frame): Slot
	local root = Instance.new("Frame")
	root.Name = "PressParticle"
	root.BackgroundTransparency = 1
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Size = UDim2.fromOffset(22, 22)
	root.Visible = false
	root.Active = false
	local scale = Instance.new("UIScale")
	scale.Parent = root
	-- Star: two overlapping squares (8 points).
	local star = frame(root, "Star", Color3.new(1, 1, 1), UDim2.fromScale(0.8, 0.8), UDim2.fromScale(0.1, 0.1), 0.15)
	local starTwo = frame(star, "Turn", Color3.new(1, 1, 1), UDim2.fromScale(1, 1), UDim2.new(), 0.15)
	starTwo.Rotation = 45
	-- Stud: a rounded square with a dark outline and a lighter top (the RoBeasts stud look).
	local stud = frame(root, "Stud", Color3.new(1, 1, 1), UDim2.fromScale(0.9, 0.9), UDim2.fromScale(0.05, 0.05), 0.2)
	local stroke = Instance.new("UIStroke")
	stroke.Color = EDGE
	stroke.Thickness = 2
	stroke.Parent = stud
	local studTop = frame(stud, "Top", Color3.new(1, 1, 1), UDim2.fromScale(0.6, 0.3), UDim2.fromScale(0.2, 0.15), 0.4)
	-- Coin: gold disc, darker inset, gleam.
	local coin = frame(root, "Coin", COIN, UDim2.fromScale(1, 1), UDim2.new(), 1)
	local inset = frame(coin, "Inset", COIN_DARK, UDim2.fromScale(0.62, 0.62), UDim2.fromScale(0.19, 0.19), 1)
	local gleam =
		frame(coin, "Gleam", Color3.fromRGB(255, 244, 170), UDim2.fromScale(0.26, 0.2), UDim2.fromScale(0.18, 0.14), 1)
	root.Parent = parent
	return {
		root = root,
		scale = scale,
		motifs = { Stars = star, Studs = stud, Coins = coin },
		paints = { Stars = { star, starTwo }, Studs = { stud, studTop }, Coins = { coin, inset, gleam } },
		stroke = stroke,
		kind = "Stars",
		live = false,
		started = 0,
		seed = 0,
		x = 0,
		y = 0,
		w = 0,
		h = 0,
	}
end

-- Hides every particle and drops the per-frame connection.
local function clear()
	for _, slot in slots do
		slot.live = false
		slot.root.Visible = false
	end
	active = 0
	if render ~= nil then
		render:Disconnect()
		render = nil
	end
end

-- The single per-frame step (alive only while particles are).
local function step()
	local now = os.clock()
	local remaining = 0
	for _, slot in slots do
		if slot.live then
			local age = now - slot.started
			if age >= Rules.Duration then
				slot.live = false
				slot.root.Visible = false
			else
				local dx, dy, rotation, fade, scale = Rules.pose(slot.seed, age, slot.w, slot.h)
				slot.root.Position = UDim2.fromOffset(slot.x + dx, slot.y + dy)
				slot.root.Rotation = rotation
				slot.scale.Scale = scale
				for _, paint in slot.paints[slot.kind] do
					paint.BackgroundTransparency = fade
				end
				if slot.kind == "Studs" then
					slot.stroke.Transparency = fade
				end
				remaining += 1
			end
		end
	end
	active = remaining
	if active == 0 then
		clear()
	end
end

-- Paints one slot for a kind + colour.
local function theme(slot: Slot, kind: Kind, color: Color3, big: boolean, index: number)
	slot.kind = kind
	for name, motif in slot.motifs do
		motif.Visible = name == kind
	end
	if kind ~= "Coins" then
		local light = color:Lerp(Color3.new(1, 1, 1), 0.35)
		for position, paint in slot.paints[kind] do
			paint.BackgroundColor3 = if position == 1 then color else light
		end
	end
	local side = (if big then 26 else 20) + index % 3 * 3
	slot.root.Size = UDim2.fromOffset(side, side)
end

--[[
	Bursts particles around a screen rectangle (canvas space).
	@param x, y, w, h the button rectangle relative to the overlay canvas
	@param kind / color / big burst style
]]
local function burst(x: number, y: number, w: number, h: number, kind: Kind, color: Color3, big: boolean)
	local layer = canvas
	if layer == nil then
		return
	end
	local tier = "Mid"
	local reader = tierRead
	if reader ~= nil then
		tier = reader()
	end
	local count = Rules.count(tier, OfferFx.reducedMotion(), big)
	local now = os.clock()
	if count == 0 or now - lastBurst < Rules.MinGap then
		return
	end
	lastBurst = now
	serial += 1
	for index = 1, count do
		cursor = cursor % CAPACITY + 1
		local slot = slots[cursor]
		if slot == nil then
			slot = makeSlot(layer)
			slots[cursor] = slot
		end
		slot.live = true
		slot.started = now
		slot.seed = index + serial * 17
		slot.x, slot.y, slot.w, slot.h = x + w / 2, y + h / 2, w, h
		theme(slot, kind, color, big, index)
		slot.root.Visible = true
	end
	step()
	if render == nil then
		render = RunService.PreRender:Connect(step)
	end
end

-- True when presses on `button` should show (its gui is on screen and not covered by a modal).
local function foreground(button: GuiButton): boolean
	local node: Instance? = button
	while node ~= nil do
		if node:IsA("GuiObject") and not node.Visible then
			return false
		end
		if node:IsA("ScreenGui") then
			if not node.Enabled then
				return false
			end
			local name = node.Name
			if ScreenManager.isRegistered(name) and ScreenManager.anyModalOpen() then
				return ScreenManager.isTopModal(name)
			end
			return true
		elseif node:IsA("LayerCollector") then
			-- World billboards: only while no window covers the world.
			return node.Enabled and not ScreenManager.anyModalOpen()
		end
		node = node.Parent
	end
	return false
end

-- Plays a Sound key (missing audio module / unknown key never breaks a press).
local function playSound(key: string)
	local play = soundPlay
	if play ~= nil and key ~= "" then
		pcall(play, key)
	end
end

--[[
	The feedback of one press of `button` (sound + burst), as if it was clicked. Buttons marked
	FeedbackManual call this themselves (e.g. the billboard UPGRADE for keyboard / gamepad too).
	@param button the pressed button
]]
function ButtonFeedback.fire(button: GuiButton)
	local kind = Rules.kind(button:GetAttribute("FeedbackKind"))
	local locked = button:GetAttribute("FeedbackLocked") == true
	playSound(Rules.soundFor(kind, locked, button:GetAttribute("FeedbackSound")))
	if locked or button:GetAttribute("ButtonParticlesDisabled") == true or not foreground(button) then
		return
	end
	local layer = canvas
	if layer == nil then
		return
	end
	local origin = layer.AbsolutePosition
	-- The button's real screen rect (billboard buttons are projected; R61). Off screen = no burst.
	local position, size = ScreenRect.of(button)
	if position == nil or size == nil or size.X < 2 or size.Y < 2 then
		return
	end
	local preset = (UIStyleConfig.Colors :: any)[button:GetAttribute("FeedbackColor")]
	local color = if preset ~= nil then preset.accent else Color3.fromRGB(255, 226, 90)
	local big = button:GetAttribute("FeedbackBig") == true or kind == "Coins"
	burst(position.X - origin.X, position.Y - origin.Y, size.X, size.Y, kind, color, big)
end

--[[
	Binds press + hover feedback to a button (idempotent; Create calls it for every GuiButton it
	builds, the PlayerGui DescendantAdded fallback for the rest). FeedbackManual buttons only get
	hover (their owner calls fire()).
]]
function ButtonFeedback.bind(button: GuiButton)
	if bound[button] ~= nil then
		return
	end
	local connections: { RBXScriptConnection } = {}
	bound[button] = connections
	table.insert(
		connections,
		button.Activated:Connect(function()
			if button:GetAttribute("FeedbackManual") ~= true then
				ButtonFeedback.fire(button)
			end
		end)
	)
	table.insert(
		connections,
		button.MouseEnter:Connect(function()
			local now = os.clock()
			if InputController.mode == "KeyboardMouse" and now - lastHover >= HOVER_GAP then
				lastHover = now
				playSound("ui_hover")
			end
		end)
	)
	table.insert(
		connections,
		button.Destroying:Connect(function()
			for _, connection in connections do
				connection:Disconnect()
			end
			bound[button] = nil
		end)
	)
end

--[[ Counters for Studio probes / tests. ]]
function ButtonFeedback.state(): { capacity: number, active: number, bound: number, running: boolean }
	local count = 0
	for _ in bound do
		count += 1
	end
	return { capacity = #slots, active = active, bound = count, running = render ~= nil }
end

--[[
	Builds the overlay + pool and hooks the fallbacks (once; UIController calls it at boot).
	@param playerGui the local PlayerGui
]]
function ButtonFeedback.start(playerGui: Instance)
	if overlay ~= nil then
		return
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "ButtonClickEffects"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = Enum.ScreenInsets.None
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 1000
	local layer = Instance.new("Frame")
	layer.Name = "Particles"
	layer.BackgroundTransparency = 1
	layer.Size = UDim2.fromScale(1, 1)
	layer.Active = false
	layer.Parent = gui
	gui.Parent = playerGui
	overlay, canvas = gui, layer
	for _ = 1, PREWARM do
		cursor += 1
		slots[cursor] = makeSlot(layer)
	end
	cursor = 0
	-- Optional collaborators (other builders' modules): never block the UI on them.
	local client = script.Parent.Parent
	local audio = client:FindFirstChild("Audio")
	local soundModule = if audio ~= nil then audio:FindFirstChild("Sound") else nil
	if soundModule ~= nil and soundModule:IsA("ModuleScript") then
		local ok, loaded = pcall(require, soundModule)
		if ok and type(loaded) == "table" then
			local api: any = loaded
			soundPlay = function(key: string)
				api.play(key)
			end
		end
	end
	local tycoon = client:FindFirstChild("Tycoon")
	local fx = if tycoon ~= nil then tycoon:FindFirstChild("Fx") else nil
	local qualityModule = if fx ~= nil then fx:FindFirstChild("FxQuality") else nil
	if qualityModule ~= nil and qualityModule:IsA("ModuleScript") then
		local ok, loaded = pcall(require, qualityModule)
		if ok and type(loaded) == "table" then
			local api: any = loaded
			tierRead = function(): string
				local okTier, value = pcall(api.tier)
				return if okTier and type(value) == "string" then value else "Mid"
			end
		end
	end
	-- Buttons not built through Create (other modules' raw GuiButtons) bind here.
	for _, descendant in playerGui:GetDescendants() do
		if descendant:IsA("GuiButton") then
			ButtonFeedback.bind(descendant)
		end
	end
	playerGui.DescendantAdded:Connect(function(descendant: Instance)
		if descendant:IsA("GuiButton") then
			ButtonFeedback.bind(descendant)
		end
	end)
	-- Window open / close sounds (modals only; the HUD and toasts open silently).
	ScreenManager.Opened:Connect(function(name: string)
		if ScreenManager.isModal(name) then
			playSound("ui_open")
		end
	end)
	ScreenManager.Closed:Connect(function(name: string)
		if ScreenManager.isModal(name) then
			playSound("ui_close")
		end
	end)
end

return ButtonFeedback
