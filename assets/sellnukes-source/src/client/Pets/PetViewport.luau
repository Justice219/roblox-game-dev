--!strict
--[[
	PetViewport — a ViewportFrame that shows one pet / egg / crate model in the UI (inventory cards,
	odds rows, the detail panel, crate cards, reveals). Rendered 3D models, not flat icons (owner
	R9: icons must look 3D — here they ARE the 3D model).

	Animation (owner R44): every PET viewport plays the same procedural idle loop as the followers
	(PetAnim: breathing, wing flaps, tail wags, orbit spin, glow pulse, looking around, random
	sit / spin / flip / wave / jiggle — never a big hop, so the pet stays in frame). Pieces are
	posed relative to the model's Root, so turntable spins and any screen's own PivotTo compose
	with it, and a ScaleTo is picked up (the rig rescales). A screen that poses individual pieces
	itself calls `setAnimate(false)` first (or passes `animate = false`). Reduce Motion → gentle
	idle; Low tier → body bob + wings only. The loop is PetModels.animator (also usable directly by
	a screen that owns its own ViewportFrame + frame loop).

	Performance:
		* A viewport renders only when its content changes; static egg / crate cards cost nothing.
		* ONE shared RenderStepped step for all viewports, connected only while something spins or
		  animates. It skips any viewport that is invisible (itself or an ancestor) or whose
		  ScreenGui is disabled. Reduce Motion (profile setting) stops the turntable spin.
		* Pet animation is budgeted per device (PetAnimConfig.Tiers via FxQuality): at most
		  `Viewports` pets animate at once, at `ViewportHz` (15 Hz on a low-end phone), because an
		  animated viewport re-renders every tick.
		* `set(kind, id)` with the same content is a no-op; a new model replaces the old one.
		* One PetModels.Ready connection for ALL viewports: when a species' meshes finish loading,
		  every live viewport showing that key rebuilds with the real mesh.

	Connects to: Client/Pets/{PetModels, PetAnim}, Client/ClientState (reduced motion),
	Client/Tycoon/Fx/FxQuality, Shared/Config/PetAnimConfig, UI/Screens/{Pets, EggHatch, CrateShop,
	CrateOpen}.

	Example:
		local view = PetViewport.new(card.content, { size = UDim2.fromScale(1, 0.7), spin = false })
		view.set("pet", "fission_fox")
		view.setAnimate(false) -- a screen that poses the pieces itself pauses the idle loop
		view.Destroy()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ClientState = require(script.Parent.Parent.ClientState)
local FxQuality = require(script.Parent.Parent.Tycoon.Fx.FxQuality)
local PetAnim = require(script.Parent.PetAnim)
local PetAnimConfig = require(ReplicatedStorage.Shared.Config.PetAnimConfig)
local PetModels = require(script.Parent.PetModels)

export type Kind = "pet" | "egg" | "crate"

export type Options = {
	size: UDim2?,
	position: UDim2?,
	anchor: Vector2?,
	zIndex: number?,
	layoutOrder: number?,
	spin: boolean?, -- slow turntable (detail panels, reveals)
	animate: boolean?, -- pet idle loop (default true; false = a screen poses the model itself)
	yaw: number?, -- resting yaw in degrees (default 25: a three-quarter view)
	zoom: number?, -- camera distance multiplier (default 1)
	name: string?,
	parent: Instance?,
}

export type Viewport = {
	frame: ViewportFrame,
	model: () -> Model?,
	set: (kind: Kind, id: string) -> (),
	clear: () -> (),
	setSpin: (on: boolean) -> (),
	setYaw: (degrees: number) -> (),
	setAnimate: (on: boolean) -> (),
	Destroy: () -> (),
}

type Entry = {
	frame: ViewportFrame,
	camera: Camera,
	kind: Kind?,
	id: string?,
	key: string,
	model: Model?,
	spin: boolean,
	yaw: number,
	zoom: number,
	center: Vector3,
	-- Pet animation (nil for eggs / crates / no model).
	animate: boolean,
	animator: PetModels.Animator?,
	accum: number, -- seconds since this viewport's last animation tick
}

local PetViewport = {}

-- Turntable speed (radians per second).
local SPIN_SPEED = 0.9
local FIELD_OF_VIEW = 32

local live: { [Entry]: boolean } = {}
local spinning: { [Entry]: boolean } = {}
-- Pet viewports with an animation rig (the step animates the visible ones, within budget).
local animated: { [Entry]: boolean } = {}
local spinConnection: RBXScriptConnection? = nil
local spinAngle = 0
-- Seed counter: every viewport pet idles on its own rhythm.
local seedCounter = 0

-- True when reduce motion is on (profile setting).
local function reducedMotion(): boolean
	local profile = ClientState.profile
	local settings = if type(profile) == "table" then profile.settings else nil
	return type(settings) == "table" and settings.reducedMotion == true
end

-- The ScreenGui ancestor is enabled and the frame visible (cheap visibility gate for the spin).
local function onScreen(frame: ViewportFrame): boolean
	if not frame.Visible then
		return false
	end
	local gui = frame:FindFirstAncestorWhichIsA("LayerCollector")
	return gui ~= nil and gui.Enabled
end

--[[
	True when the frame and every GuiObject ancestor are Visible and its LayerCollector is enabled
	(a hidden card in a pooled grid / a closed screen must not animate).
]]
local function onScreenDeep(frame: ViewportFrame): boolean
	local node: Instance? = frame
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

-- Places the model's pivot at the origin with `yaw` and frames the camera on it.
local function frameModel(entry: Entry)
	local model = entry.model
	if model == nil then
		return
	end
	model:PivotTo(CFrame.Angles(0, math.rad(entry.yaw), 0))
	local cf, size = model:GetBoundingBox()
	entry.center = cf.Position
	local radius = math.max(size.X, size.Y, size.Z) * 0.62
	local distance = radius / math.tan(math.rad(FIELD_OF_VIEW / 2)) * entry.zoom
	-- Models face -Z: the camera sits in front (-Z), a little above.
	entry.camera.CFrame = CFrame.lookAt(entry.center + Vector3.new(0, radius * 0.35, -distance), entry.center)
end

-- (Re)builds the entry's model for its kind / id.
local function rebuild(entry: Entry)
	if entry.model ~= nil then
		entry.model:Destroy()
		entry.model = nil
	end
	if entry.animator ~= nil then
		entry.animator.Destroy()
		entry.animator = nil
	end
	animated[entry] = nil
	local kind, id = entry.kind, entry.id
	if kind == nil or id == nil then
		return
	end
	local model = if kind == "pet"
		then PetModels.pet(id)
		elseif kind == "egg" then PetModels.egg(id)
		else PetModels.crate(id)
	model.Parent = entry.frame
	entry.model = model
	if kind == "pet" then
		-- Same rig + idle loop as the followers (PetModels.animator, viewport flavour).
		seedCounter += 1
		entry.animator = PetModels.animator(model, { seed = seedCounter * 977 })
		entry.accum = 0
		animated[entry] = if entry.animate and entry.animator ~= nil then true else nil
	end
	frameModel(entry)
end

--[[
	The shared step (runs only while something spins or animates): turntable spin first, then the
	pet idle loop of the visible pet viewports within the tier's count / rate budget.
]]
local function step(dt: number)
	local reduced = reducedMotion()
	if not reduced then
		spinAngle = (spinAngle + dt * SPIN_SPEED) % (math.pi * 2)
		for entry in spinning do
			local model = entry.model
			if model ~= nil and onScreen(entry.frame) then
				model:PivotTo(CFrame.new(entry.center) * CFrame.Angles(0, spinAngle, 0) * CFrame.new(-entry.center))
			end
		end
	end
	if next(animated) == nil then
		return
	end
	local tierName = FxQuality.tier()
	local tier = PetAnimConfig.Tiers[tierName] or PetAnimConfig.Tiers.Mid
	local detail = if tierName == "Low" then PetAnim.Detail.Simple else PetAnim.Detail.Full
	local interval = 1 / math.max(tier.ViewportHz, 1)
	local budget = tier.Viewports
	for entry in animated do
		if budget <= 0 then
			break
		end
		if not onScreenDeep(entry.frame) then
			continue
		end
		budget -= 1
		entry.accum += dt
		-- PivotTo (spin / screens) moves the model rigidly, so the last pose holds between ticks.
		local animator = entry.animator
		if entry.accum >= interval and animator ~= nil then
			animator.setDetail(detail)
			animator.setReduced(reduced)
			animator.step(entry.accum)
			entry.accum = 0
		end
	end
end

local function updateSpinLoop()
	local wanted = next(spinning) ~= nil or next(animated) ~= nil
	if wanted and spinConnection == nil then
		spinConnection = RunService.RenderStepped:Connect(step)
	elseif not wanted and spinConnection ~= nil then
		spinConnection:Disconnect()
		spinConnection = nil
	end
end

-- One Ready connection: rebuild every live viewport showing the loaded key.
PetModels.Ready:Connect(function(key: string)
	for entry in live do
		if entry.key == key then
			rebuild(entry)
		end
	end
	updateSpinLoop()
end)

--[[
	Creates a viewport (see Options). Destroy it (or its parent) when done.
	@return Viewport handle
]]
function PetViewport.new(options: Options): Viewport
	local frame = Instance.new("ViewportFrame")
	frame.Name = options.name or "PetViewport"
	frame.BackgroundTransparency = 1
	frame.Size = options.size or UDim2.fromScale(1, 1)
	frame.Position = options.position or UDim2.new()
	frame.AnchorPoint = options.anchor or Vector2.zero
	frame.ZIndex = options.zIndex or 2
	frame.LayoutOrder = options.layoutOrder or 0
	frame.Ambient = Color3.fromRGB(190, 190, 205)
	frame.LightColor = Color3.fromRGB(255, 250, 240)
	frame.LightDirection = Vector3.new(-0.4, -1, 0.6)
	frame.Active = false
	frame.Selectable = false
	local camera = Instance.new("Camera")
	camera.FieldOfView = FIELD_OF_VIEW
	camera.Parent = frame
	frame.CurrentCamera = camera

	local entry: Entry = {
		frame = frame,
		camera = camera,
		kind = nil,
		id = nil,
		key = "",
		model = nil,
		spin = options.spin == true,
		animate = options.animate ~= false,
		yaw = options.yaw or 25,
		zoom = options.zoom or 1,
		center = Vector3.zero,
		animator = nil,
		accum = 0,
	}
	live[entry] = true

	local handle: Viewport
	local destroyed = false
	local function setSpin(on: boolean)
		entry.spin = on
		spinning[entry] = if on and entry.model ~= nil then true else nil
		updateSpinLoop()
	end
	handle = {
		frame = frame,
		model = function(): Model?
			return entry.model
		end,
		set = function(kind: Kind, id: string)
			if destroyed or (entry.kind == kind and entry.id == id and entry.model ~= nil) then
				return
			end
			entry.kind = kind
			entry.id = id
			entry.key = PetModels.keyOf(kind, id)
			rebuild(entry)
			setSpin(entry.spin)
		end,
		clear = function()
			entry.kind = nil
			entry.id = nil
			entry.key = ""
			rebuild(entry)
			setSpin(entry.spin)
		end,
		setSpin = setSpin,
		setAnimate = function(on: boolean)
			if destroyed or entry.animate == on then
				return
			end
			entry.animate = on
			local animator = entry.animator
			if animator == nil then
				return
			end
			animated[entry] = if on then true else nil
			if not on then
				-- Hand the model back at rest so the screen's own posing starts clean.
				animator.rest()
			end
			updateSpinLoop()
		end,
		setYaw = function(degrees: number)
			entry.yaw = degrees
			frameModel(entry)
		end,
		Destroy = function()
			if destroyed then
				return
			end
			destroyed = true
			live[entry] = nil
			spinning[entry] = nil
			animated[entry] = nil
			updateSpinLoop()
			frame:Destroy()
		end,
	}
	frame.Destroying:Connect(function()
		if not destroyed then
			destroyed = true
			live[entry] = nil
			spinning[entry] = nil
			animated[entry] = nil
			updateSpinLoop()
		end
	end)
	frame.Parent = options.parent
	return handle
end

return PetViewport
