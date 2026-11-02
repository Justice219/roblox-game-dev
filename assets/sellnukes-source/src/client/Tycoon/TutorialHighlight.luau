--!strict
--[[
	TutorialHighlight — rings the exact control the tutorial wants pressed and tells the HUD arrow
	where it is (owner R84: "it doesn't actually point to the GUI. It kind of points towards the
	bench instead of where you're supposed to go ... maybe highlighting the button that needs to
	be clicked on the GUI so people know, because it wasn't very clear to me that X is what you
	were supposed to do to upgrade first").

	Purpose:
		Tycoon/Tutorial calls `show(kind, targetId, mode)` on every render. This module:
			1. resolves the live controls: the target producer's billboard (UPGRADE pill
			   `record.upgrade`, make bar `record.well`; Tycoon/ProducerBillboards), the on-screen
			   TAP! / UPGRADE touch buttons (Platform/TouchButtons.button) and the pad label's
			   price button (Tycoon/PadBillboards.priceButton);
			2. asks the pure Tycoon/TutorialFocusLogic what to point at, what to ring and which
			   glyph to show for the step on this device;
			3. puts a pulsing yellow ring (+ a soft halo) around every ringed control, removing
			   rings that no longer apply (the moment the step completes, the next render clears
			   them);
			4. returns the pointer (the GuiObject the HUD arrow must point at, else nil = the
			   step's world part), the trail spot for the ground chevrons (the billboard's spot,
			   which sits on the walkway side of the producer: walking there puts the player in
			   reach of E / X / RT and the touch buttons) and the HUD callout (the device glyph
			   badge behind the arrow: X / Square, E + cursor, RT / R2, F + cursor, a tap hand).
		`Changed` fires (deferred, coalesced) when a control appeared / vanished under the step
		(a billboard streamed in or was rebuilt, a touch button showed up as the player walked
		in reach, the Interact button turned into BUY near a pad), so Tutorial re-renders.

	Near a pad, Interact buys the pad (Tycoon/Interaction), so the on-screen Interact button is
	never ringed as "upgrade" while a pad is in reach (Platform/ActionMap "Pad" context).

	Performance: event-driven. No per-frame work of its own: every ring's pulse is one step on
	the shared OfferFx driver (one PreRender connection for all decorations, running only while a
	ring is on screen; Reduce Motion parks it, leaving a static bright ring; Low graphics keeps a
	slow 15 Hz pulse because this is guidance, not decoration). Rings and glyphs are built once
	per target change, never per frame; the callout table is cached so the HUD badge is rebuilt
	only when the pointer, glyph, device or gamepad family changes.

	Connects to: Tycoon/{Tutorial (caller), TutorialFocusLogic, ProducerBillboards, PadBillboards},
	Platform/{TouchButtons, ActionMap, GlyphFamily}, UI/Hud/HudObjective (Callout), UI/Widgets/
	OfferFx, UI/Kit/StudUI (Cursor icon), Shared/Config/{TycoonClientConfig (TutorialHighlight,
	TutorialPointer), PlatformConfig (bindings), UIStyleConfig}.

	Example:
		TutorialHighlight.start()
		local result = TutorialHighlight.show("upgrade", "p1_workbench", InputController.mode)
		Hud.setObjective(text, result.pointer or producerPart)
		HudObjective.setCallout(result.callout)
		TutorialHighlight.clear()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ActionMap = require(script.Parent.Parent.Platform.ActionMap)
local Create = require(script.Parent.Parent.UI.Create)
local GlyphFamily = require(script.Parent.Parent.Platform.GlyphFamily)
local HudObjective = require(script.Parent.Parent.UI.Hud.HudObjective)
local OfferFx = require(script.Parent.Parent.UI.Widgets.OfferFx)
local OfferFxConfig = require(ReplicatedStorage.Shared.Config.OfferFxConfig)
local PadBillboards = require(script.Parent.PadBillboards)
local PlatformConfig = require(ReplicatedStorage.Shared.Config.PlatformConfig)
local ProducerBillboards = require(script.Parent.ProducerBillboards)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local StudUI = require(script.Parent.Parent.UI.Kit.StudUI)
local TouchButtons = require(script.Parent.Parent.Platform.TouchButtons)
local TutorialFocusLogic = require(script.Parent.TutorialFocusLogic)
local TycoonClientConfig = require(ReplicatedStorage.Shared.Config.TycoonClientConfig)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local Config = TycoonClientConfig.TutorialHighlight
local Pointer = TycoonClientConfig.TutorialPointer

export type Result = {
	pointer: GuiObject?, -- the control the HUD arrow points at (nil = the step's world part)
	trail: Attachment?, -- where the ground chevrons lead (nil = the step's world part)
	callout: HudObjective.Callout?, -- the HUD badge + side preferences (cached table)
}

-- One ringed control.
type Ring = {
	control: GuiObject,
	frame: Frame, -- the bright ring
	stroke: UIStroke,
	halo: Frame, -- the soft outer halo
	haloStroke: UIStroke,
	handle: OfferFx.Handle?,
	sizeConnection: RBXScriptConnection,
}

local TutorialHighlight = {}

--[[ Fires () when the step's controls changed (deferred + coalesced); Tutorial re-renders. ]]
TutorialHighlight.Changed = Signal.new() :: Signal.Signal<>

-- The pulse value a ring shows while its animation is parked (Reduce Motion / off screen).
local STATIC_PULSE = 0.5
-- Ring pulse steps / s per graphics tier (OfferFx rate table, copied from the frozen config).
local PULSE_RATES: OfferFxConfig.PerTier = {
	Low = Config.Hz.Low,
	Medium = Config.Hz.Medium,
	High = Config.Hz.High,
}

local EMPTY: Result = table.freeze({ pointer = nil, trail = nil, callout = nil }) :: Result

local started = false
local pending = false
-- The step being highlighted (nil = none).
local currentKind: string? = nil
local currentId: string? = nil
local currentPoint: TutorialFocusLogic.Point = "world"
local rings: { [GuiObject]: Ring } = {}
-- The cached callout and what it was built for (identity compare: no rebuild while unchanged).
local cachedCallout: HudObjective.Callout? = nil
local cachedPointer: GuiObject? = nil
local cachedGlyph: string? = nil
local cachedMode = ""
local cachedFamily = ""
local cachedClear = ""

--[[
	Sizes a ring for a pulse value 0..1 (0 = at rest, 1 = peak). Sizes are fractions of the
	control's shorter side, applied as SCALE of the control (so a UIScale above the control never
	applies twice), so the ring looks the same on a stud-scaled billboard and a 72 pt button.
]]
local function applyRing(ring: Ring, pulse: number)
	local extent = ring.control.AbsoluteSize
	local side = math.min(extent.X, extent.Y)
	if side <= 0 then
		return
	end
	local pad = side * (Config.Pad + Config.PadGrow * pulse)
	ring.frame.Size = UDim2.fromScale(1 + 2 * pad / extent.X, 1 + 2 * pad / extent.Y)
	ring.stroke.Thickness =
		math.clamp(side * (Config.Thickness + Config.ThicknessGrow * pulse), Config.MinThickness, side * 0.25)
	local haloPad = side * (Config.HaloPad + Config.PadGrow * pulse)
	ring.halo.Size = UDim2.fromScale(1 + 2 * haloPad / extent.X, 1 + 2 * haloPad / extent.Y)
	ring.haloStroke.Thickness = math.clamp(side * Config.Thickness, Config.MinThickness, side * 0.25)
	-- The halo fades out as the ring swells: reads as a soft glow breathing outward.
	ring.haloStroke.Transparency = Config.HaloTransparency + (1 - Config.HaloTransparency) * pulse
end

-- One transparent rounded frame carrying a border stroke (the ring / the halo).
local function strokeFrame(name: string, radius: UDim, color: Color3, zIndex: number): (Frame, UIStroke)
	local frame = Create.new("Frame", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Active = false,
		Selectable = false,
		ZIndex = zIndex,
		Children = { Create.new("UICorner", { CornerRadius = radius }) },
	}) :: Frame
	local stroke = Create.new("UIStroke", {
		Color = color,
		Thickness = Config.MinThickness,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		LineJoinMode = Enum.LineJoinMode.Round,
		Parent = frame,
	}) :: UIStroke
	return frame, stroke
end

--[[
	Rings `control` (children of the control: they follow it, sit above its labels with a
	transparent middle so nothing is hidden, and die with it).
]]
local function makeRing(control: GuiObject): Ring
	local corner = control:FindFirstChildOfClass("UICorner")
	local radius = if corner ~= nil then corner.CornerRadius else UDim.new(0, Config.Corner)
	local frame, stroke = strokeFrame("TutorialRing", radius, Config.Color, 40)
	local halo, haloStroke = strokeFrame("TutorialHalo", radius, Config.HaloColor, 39)
	halo.Parent = control
	frame.Parent = control
	local ring: Ring
	ring = {
		control = control,
		frame = frame,
		stroke = stroke,
		halo = halo,
		haloStroke = haloStroke,
		handle = nil :: OfferFx.Handle?,
		-- Parked (Reduce Motion / not yet on screen): keep the static ring sized to the control.
		sizeConnection = control:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			local handle = ring.handle
			if handle == nil or not handle.running() then
				applyRing(ring, STATIC_PULSE)
			end
		end),
	}
	applyRing(ring, STATIC_PULSE)
	ring.handle = OfferFx.register({
		root = frame,
		rates = PULSE_RATES,
		step = function(_dt: number, elapsed: number)
			applyRing(ring, 0.5 + 0.5 * math.sin(elapsed * Config.PulseSpeed))
		end,
	})
	return ring
end

-- Removes a ring (the OfferFx item leaves with its root).
local function destroyRing(ring: Ring)
	ring.sizeConnection:Disconnect()
	ring.frame:Destroy()
	ring.halo:Destroy()
end

-- Removes every ring.
local function clearRings()
	for control, ring in rings do
		destroyRing(ring)
		rings[control] = nil
	end
end

--[[
	A cartoon tap hand (touch glyph): a white finger + palm with the chunky dark outline of the
	stud icons, and a yellow tap ripple at the fingertip. Frames only (no uploads).
	@param height px
]]
local function tapHand(height: number): Frame
	local root = Create.new("Frame", {
		Name = "TapHand",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(height, height),
	}) :: Frame
	local edge = math.max(2, math.floor(height / 18))
	-- Shape: centre x / y, width / height (fractions of the side), corner fraction, colour, z.
	local function shape(x: number, y: number, w: number, h: number, round: number, color: Color3?, z: number): Frame
		local frame = Create.new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(x, y),
			Size = UDim2.fromScale(w, h),
			BackgroundColor3 = color or Color3.new(1, 1, 1),
			BackgroundTransparency = if color == nil then 1 else 0,
			BorderSizePixel = 0,
			ZIndex = z,
			Parent = root,
			Children = {
				Create.new("UICorner", { CornerRadius = UDim.new(round, 0) }),
			},
		}) :: Frame
		return frame
	end
	-- Tap ripple (a ring around the fingertip).
	local ripple = shape(0.4, 0.2, 0.42, 0.42, 0.5, nil, 2)
	Create.new("UIStroke", {
		Color = Config.Color,
		Thickness = edge + 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = ripple,
	})
	local white = Color3.new(1, 1, 1)
	local palm = shape(0.56, 0.72, 0.5, 0.44, 0.3, white, 3)
	local finger = shape(0.4, 0.42, 0.18, 0.52, 0.5, white, 4)
	local thumb = shape(0.3, 0.7, 0.16, 0.3, 0.5, white, 4)
	thumb.Rotation = -35
	for _, part in { palm, finger, thumb } do
		Create.new("UIStroke", {
			Color = UIStyleConfig.Neutral.Edge,
			Thickness = edge,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Parent = part,
		})
	end
	return root
end

--[[
	The callout glyph for the device (owner R84 §2): gamepad = the engine button image for the
	binding (X / Square, RT / R2, through GlyphFamily); keyboard + mouse = the key cap + a cursor
	("press E or click"); touch = a tap hand.
	@param glyph "interact" | "produce" | "tap"
	@param mode  InputController mode
	@return a fresh GuiObject (the HUD parents it into its badge)
	Example: TutorialHighlight.glyph("interact", "Gamepad") -- the X button image
]]
function TutorialHighlight.glyph(glyph: TutorialFocusLogic.Glyph, mode: string): GuiObject
	local height = Pointer.BadgeGlyph
	if glyph == "tap" or mode == "Touch" then
		return tapHand(height)
	end
	local binding = if glyph == "interact" then PlatformConfig.Actions.Interact else PlatformConfig.Actions.Produce
	if mode == "Gamepad" then
		local button = binding.buttons[1]
		if button ~= nil then
			return GlyphFamily.glyph(button, height)
		end
	end
	local row = Create.new("Frame", {
		Name = "KeyAndClick",
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.fromOffset(0, 0),
		Children = {
			Create.new("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, 8),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		},
	}) :: Frame
	local key = binding.keys[1]
	if key ~= nil then
		local cap = GlyphFamily.glyph(key, height - 6)
		cap.LayoutOrder = 1
		cap.Parent = row
	end
	local cursor = StudUI.icon("Cursor", height, 3)
	cursor.LayoutOrder = 2
	cursor.Parent = row
	return row
end

-- The other on-screen touch buttons the pointer must not cover (never the pointed one).
local function keepClearOf(pointer: GuiObject): ({ GuiObject }, string)
	local list: { GuiObject } = {}
	local names: { string } = {}
	for _, action in TouchButtons.touchActions() do
		local button = TouchButtons.button(action)
		if button ~= nil and button ~= pointer then
			table.insert(list, button)
			table.insert(names, action)
		end
	end
	return list, table.concat(names, ",")
end

-- Schedules one deferred Changed (coalesces bursts; nothing while no step is highlighted).
local function schedule()
	if pending or currentKind == nil then
		return
	end
	pending = true
	task.defer(function()
		pending = false
		if currentKind ~= nil then
			TutorialHighlight.Changed:Fire()
		end
	end)
end

--[[
	Highlights the step: rings its control(s) and returns where the HUD arrow + chevrons go.
	Cheap and idempotent: unchanged controls keep their rings (no flicker), the callout table is
	reused while nothing changed.
	@param kind     server step kind ("pad" | "click" | "upgrade"; nil = no step)
	@param targetId the step's padId / producerId
	@param mode     InputController mode
	@return Result
]]
function TutorialHighlight.show(kind: string?, targetId: string?, mode: string): Result
	if kind == nil or targetId == nil or targetId == "" then
		TutorialHighlight.clear()
		return EMPTY
	end
	currentKind, currentId = kind, targetId
	local record = if kind ~= "pad" then ProducerBillboards.byId(targetId) else nil
	if record ~= nil and record.gui.Parent == nil then
		record = nil
	end
	local produce = TouchButtons.button("Produce")
	local interact = TouchButtons.button("Interact")
	-- Near a pad, Interact buys the pad instead of upgrading: never ring it as UPGRADE then.
	if interact ~= nil and ActionMap.context("Pad") then
		interact = nil
	end
	local price = if kind == "pad" then PadBillboards.priceButton(targetId) else nil
	local focus = TutorialFocusLogic.focus(kind, mode, {
		billboard = record ~= nil,
		touchProduce = produce ~= nil,
		touchInteract = interact ~= nil,
		padLabel = price ~= nil,
	})
	-- The live instance of a control name.
	local function controlOf(name: TutorialFocusLogic.Point): GuiObject?
		if name == "upgrade" then
			return if record ~= nil then record.upgrade else nil
		elseif name == "make" then
			return if record ~= nil then record.well else nil
		elseif name == "touchProduce" then
			return produce
		elseif name == "touchInteract" then
			return interact
		elseif name == "padPrice" then
			return price
		end
		return nil
	end
	-- Rings: keep the ones still wanted, add new ones, drop the rest.
	local want: { [GuiObject]: boolean } = {}
	for _, name in focus.rings do
		local control = controlOf(name)
		if control ~= nil then
			want[control] = true
			if rings[control] == nil then
				rings[control] = makeRing(control)
			end
		end
	end
	for control, ring in rings do
		if not want[control] then
			destroyRing(ring)
			rings[control] = nil
		end
	end
	-- Pointer + callout (cached while pointer, glyph, device, family and keep-clear set hold).
	local pointer = if focus.point ~= "world" then controlOf(focus.point) else nil
	currentPoint = if pointer ~= nil then focus.point else "world"
	if pointer == nil then
		cachedCallout, cachedPointer, cachedGlyph = nil, nil, nil
	else
		local family = GlyphFamily.family()
		local keepClear, clearKey = keepClearOf(pointer)
		local glyph = focus.glyph
		if
			cachedCallout == nil
			or cachedPointer ~= pointer
			or cachedGlyph ~= glyph
			or cachedMode ~= mode
			or cachedFamily ~= family
			or cachedClear ~= clearKey
		then
			local glyphKind = glyph
			cachedCallout = {
				target = pointer,
				build = if glyphKind ~= nil
					then function(): GuiObject
						return TutorialHighlight.glyph(glyphKind, mode)
					end
					else nil,
				sides = focus.sides,
				keepClear = keepClear,
			}
			cachedPointer, cachedGlyph, cachedMode, cachedFamily, cachedClear = pointer, glyph, mode, family, clearKey
		end
	end
	return {
		pointer = pointer,
		-- Producer steps: the billboard's spot (walkway side of the producer) leads the chevrons.
		trail = if record ~= nil and kind ~= "pad" then record.point else nil,
		callout = if pointer ~= nil then cachedCallout else nil,
	}
end

--[[ Removes every ring and forgets the step (the tutorial finished / no step). ]]
function TutorialHighlight.clear()
	currentKind, currentId = nil, nil
	currentPoint = "world"
	cachedCallout, cachedPointer, cachedGlyph = nil, nil, nil
	clearRings()
end

--[[
	What is highlighted right now (Studio QA / verification probes).
	Example: TutorialHighlight.state() --> { kind = "upgrade", point = "upgrade", rings = 1 }
]]
function TutorialHighlight.state(): { kind: string?, point: string, rings: number }
	local count = 0
	for _ in rings do
		count += 1
	end
	return { kind = currentKind, point = currentPoint, rings = count }
end

--[[ Starts listening for controls appearing / vanishing (once; Tutorial.start calls it). ]]
function TutorialHighlight.start()
	if started then
		return
	end
	started = true
	-- The target producer's board streamed in / out or was rebuilt.
	ProducerBillboards.Changed:Connect(function(producerId: string)
		if producerId == currentId then
			schedule()
		end
	end)
	-- A touch button appeared / vanished / changed caption (UPGRADE <-> BUY near a pad).
	TouchButtons.Changed:Connect(function()
		if currentKind == "click" or currentKind == "upgrade" then
			schedule()
		end
	end)
end

return TutorialHighlight
