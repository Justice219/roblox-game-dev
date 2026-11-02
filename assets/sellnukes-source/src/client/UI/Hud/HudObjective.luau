--!strict
--[[
	HudObjective — the HUD's bottom-centre objective chip and the arrow that points at a world target
	or at the exact BUTTON to press (spec §6: "tutorial arrow / objective chip"; R78 Quests: the
	post-tutorial goal chip; owner R84: "it doesn't actually point to the GUI").

	Purpose:
		`set(text, target?)` shows a dark stud chip with a bouncing yellow arrow and the objective
		text ("Buy your first Reactor pad!"); nil text hides it. With a `target` a big yellow arrow
		also points at it:
			BasePart / Attachment / Model / Vector3  floats over that spot (HEIGHT_ABOVE studs up)
			                                         when it is on screen;
			GuiObject (owner R84)                    a button on a world BillboardGui (the
			                                         producer's UPGRADE pill / make bar) or on a
			                                         ScreenGui (the TAP! / UPGRADE touch buttons):
			                                         the arrow sits BESIDE the button, outside its
			                                         whole board, pointing at it (UI/Hud/
			                                         PointerLogic), so it never covers the button;
		and in every case sits on the screen edge pointing towards the target when it is off
		screen (behind the camera counts as off screen). A billboard button whose board is not
		drawn (beyond its MaxDistance, disabled, behind the camera) is pointed at through the
		board's world spot instead, like a world target. The tutorial / tycoon client owns WHAT the
		objective is (server TutorialState); this module only draws it.

	Callout (owner R84): `HudObjective.setCallout({ target, build?, sides?, keepClear? })` adds
	a badge with the device glyph ("[X]", "[E] + cursor", a tap hand; built by `build`, owned by
	Tycoon/TutorialHighlight) behind the arrow's tail while the arrow points at that very GuiObject
	`target`, the preferred arrow sides around it (`sides`, PointerLogic order) and screen
	controls the pointer must keep clear of (`keepClear`: the other touch buttons). Applies only
	while `target` is the shown arrow target (a world objective or a quest chip never shows it).

	Two layers (R78 Quests):
		PRIMARY    `set(text, target)` — Hud.setObjective / setWorldObjective (the Nuke Town
		           tutorial, or the current non-main world's WorldObjectives chip). Always wins.
		SECONDARY  `HudObjective.setSecondary({ text, target?, progress?, progressText?,
		           onActivated? })` — module-level, shown on every chip ONLY while the primary text
		           is nil (Client/Quests/QuestObjective: the current starter goal, then the first
		           unfinished daily mission). It adds a progress bar under the text and a "3/5"
		           counter, and the whole chip becomes tappable (touch / mouse) to open Quests. The
		           tap target is never gamepad-selectable (it would trap the cursor in the HUD);
		           gamepads use the HUD Quests button. nil clears it.

	Performance: the arrow's per-frame placement runs on ONE PreRender connection that exists only
	while a target is set and the HUD is shown; no table or Instance allocation per frame (the
	pointer's Input / Box / Placement tables are reused; the badge is built once per callout). The
	chip is static (its arrow bob shares the OfferFx driver); text / bar change only when an
	objective changes. Reduce Motion (OfferFx.reducedMotion) stills the arrow bob.

	Connects to: Kit/StudUI (text, icon, progressBar), Widgets/{StudWindow, OfferFx, HudZones},
	UI/ScreenManager (scale), UI/Hud/{Hud (owner: Hud.setObjective), PointerLogic},
	Client/Quests/QuestObjective (setSecondary), Tycoon/{Tutorial, TutorialHighlight} (GuiObject
	targets + setCallout), Shared/Config/TycoonClientConfig (TutorialPointer).

	Example:
		objective.set("Buy the Reactor pad!", workspace.Plots.Plot1.Pads.Reactor)
		objective.set("Press X to UPGRADE your Workbench!", record.upgrade) -- a billboard button
		objective.set(nil) -- hide (the secondary objective shows, if any)
		HudObjective.setSecondary({ text = "Own 5 pads in Nuke Town", progress = 0.4, progressText = "2/5",
			target = padPart, onActivated = function() ScreenManager.open("Quests", { source = "chip" }) end })
		HudObjective.setCallout({ target = record.upgrade, build = function() return glyph end,
			sides = { "below", "left", "right", "above" } })
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")
local Workspace = game:GetService("Workspace")

local Create = require(script.Parent.Parent.Create)
local HudZones = require(script.Parent.Parent.Widgets.HudZones)
local OfferFx = require(script.Parent.Parent.Widgets.OfferFx)
local OfferFxConfig = require(ReplicatedStorage.Shared.Config.OfferFxConfig)
local PlatformConfig = require(ReplicatedStorage.Shared.Config.PlatformConfig)
local PointerLogic = require(script.Parent.PointerLogic)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Widgets.StudWindow)
local TycoonClientConfig = require(ReplicatedStorage.Shared.Config.TycoonClientConfig)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

export type ArrowTarget = BasePart | Attachment | Model | Vector3 | GuiObject

-- The secondary (quest) objective: shown while no primary objective is set.
export type Secondary = {
	text: string,
	target: ArrowTarget?,
	progress: number?, -- 0..1 bar fill (nil = no bar)
	progressText: string?, -- "3/5" next to the text
	onActivated: (() -> ())?, -- tapping / clicking the chip (nil = not tappable)
}

-- Owner R84: how the arrow presents a GuiObject target (see the module header).
export type Callout = {
	target: ArrowTarget, -- applies only while this is the arrow's target
	build: (() -> GuiObject)?, -- the device glyph for the badge behind the arrow (nil = no badge)
	sides: { PointerLogic.Side }?, -- preferred arrow sides around the button (nil = default)
	keepClear: { GuiObject }?, -- screen controls the pointer must not cover
}

export type HudObjective = {
	set: (text: string?, target: ArrowTarget?) -> (),
	place: (bottomY: number, maxWidth: number, centerX: number) -> (),
	frame: Frame,
	target: () -> ArrowTarget?,
}

local HudObjective = {}

-- World-arrow tunables (design px / seconds).
local ARROW_SIZE = 84
local EDGE_INSET = 70 -- off-screen arrows keep this far from the canvas edge
local HEIGHT_ABOVE = 9 -- studs above the target's position (clears producer / pad billboards)
local BOB_PIXELS = 10
local BOB_SPEED = 4
-- Progress bar under the text (design px): height, side inset, extra chip height while shown.
local BAR_HEIGHT = 12
local BAR_INSET = 14
local BAR_SPACE = 18
-- R84 pointer beside a button (design px).
local Pointer = TycoonClientConfig.TutorialPointer
-- HUD zones the button pointer keeps clear of (the HUD columns, the top stack, the chip).
local POINTER_ZONES: { HudZones.ZoneName } = { "Left", "Right", "Top", "TopRight", "Bottom" }
-- The gamepad / keyboard hint bar sits just above the chip (Platform/HintBar: Margin + Height + 12)
-- but publishes no zone, so the pointer treats that band as part of the chip's zone (R84 QA: the
-- [X] badge under an UPGRADE pill was half hidden behind the hint bar).
local HINT_BAND = PlatformConfig.HintBar.Margin + PlatformConfig.HintBar.Height + 12

-- The current secondary objective + every live chip's re-apply function (the HUD builds one
-- chip; a rebuilt HUD registers its new chip and the old one unregisters on Destroying).
local secondary: Secondary? = nil
local appliers: { [Frame]: () -> () } = {}
-- R84: the current callout + every live chip's callout re-apply function.
local callout: Callout? = nil
local calloutAppliers: { [Frame]: () -> () } = {}

-- World position of a target (nil when an Instance target left the world, or a GuiObject).
local function positionOf(target: ArrowTarget): Vector3?
	if typeof(target) == "Vector3" then
		return target
	end
	if typeof(target) == "Instance" then
		if not target:IsDescendantOf(Workspace) then
			return nil
		end
		if target:IsA("BasePart") then
			return target.Position
		elseif target:IsA("Attachment") then
			return target.WorldPosition
		elseif target:IsA("Model") then
			return target:GetPivot().Position
		end
	end
	return nil
end

-- World spot a BillboardGui is drawn around (its adornee, or the part it is parented to, plus
-- its stud offsets), or nil when it has none in the world.
local function billboardCenter(board: BillboardGui, cameraFrame: CFrame): Vector3?
	local adornee: Instance? = board.Adornee
	if adornee == nil then
		local parent = board.Parent
		adornee = if parent ~= nil and parent:IsA("BasePart") then parent else nil
	end
	if adornee == nil or not adornee:IsDescendantOf(Workspace) then
		return nil
	end
	local base: Vector3
	if adornee:IsA("Attachment") then
		base = adornee.WorldPosition
	elseif adornee:IsA("BasePart") then
		base = adornee.Position
	elseif adornee:IsA("Model") then
		base = adornee:GetPivot().Position
	else
		return nil
	end
	-- StudsOffset is in camera space (right / up / back), StudsOffsetWorldSpace in world space.
	return base + board.StudsOffsetWorldSpace + cameraFrame:VectorToWorldSpace(board.StudsOffset)
end

-- True when the control and every GuiObject between it and its LayerCollector are Visible.
local function chainVisible(control: GuiObject, layer: Instance): boolean
	local node: Instance? = control
	while node ~= nil and node ~= layer do
		if node:IsA("GuiObject") and not node.Visible then
			return false
		end
		node = node.Parent
	end
	return node == layer
end

--[[
	Sets (or with nil clears) the secondary objective on every chip. Shown only while the chip
	has no primary objective. Cheap: callers may call it on every relevant change.
	Example: HudObjective.setSecondary({ text = "Hatch an egg", progress = 0, progressText = "0/1" })
]]
function HudObjective.setSecondary(objective: Secondary?)
	if objective ~= nil and (type(objective.text) ~= "string" or objective.text == "") then
		objective = nil
	end
	secondary = objective
	for _, apply in appliers do
		apply()
	end
end

--[[
	Owner R84: sets (or with nil clears) the pointer callout (see the module header). The badge is
	rebuilt only when a DIFFERENT callout table arrives, so callers should reuse the same table
	while nothing changed (Tycoon/TutorialHighlight caches it).
	Example: HudObjective.setCallout({ target = upgradeButton, build = buildGlyph })
]]
function HudObjective.setCallout(spec: Callout?)
	if spec == callout then
		return
	end
	callout = spec
	for _, apply in calloutAppliers do
		apply()
	end
end

--[[
	Builds the chip and the world arrow under `container` (the HUD's full-screen frame).
	@return HudObjective handle
]]
function HudObjective.new(container: Frame): HudObjective
	local hud = UIStyleConfig.Hud
	local chip = Create.new("Frame", {
		Name = "Objective",
		AnchorPoint = Vector2.new(0.5, 1),
		Size = UDim2.fromOffset(240, hud.ObjectiveHeight),
		BackgroundColor3 = UIStyleConfig.Neutral.Body,
		Visible = false,
		Parent = container,
		Children = {
			Create.new("UICorner", { CornerRadius = UDim.new(0, 8) }),
		},
	}) :: Frame
	StudWindow.edge(chip, 4)
	local studs = StudWindow.surface(chip, "grey", {
		tile = UIStyleConfig.StudTile.Button,
		studTransparency = 0.8,
		corner = 8,
		highlight = false,
	})
	-- A slate gradient instead of the grey preset (the chip should read as a quiet panel).
	studs.gradient.Color = ColorSequence.new(Color3.fromRGB(96, 110, 136), UIStyleConfig.Neutral.Body)
	-- Widest the chip may grow (design px); `place` narrows it between the HUD columns.
	local maxWidth = hud.ObjectiveMaxWidth
	local row = Create.new("Frame", {
		Name = "Row",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(0, hud.ObjectiveHeight),
		AutomaticSize = Enum.AutomaticSize.X,
		ZIndex = 2,
		Parent = chip,
		Children = {
			Create.new("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, 10),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			Create.new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 20) }),
		},
	}) :: Frame
	local chipArrow = StudUI.icon("Arrow", hud.ObjectiveHeight - 16, 3)
	chipArrow.LayoutOrder = 1
	chipArrow.Parent = row
	local textSize = math.floor(hud.ObjectiveHeight * 0.48)
	local label = StudUI.text({
		name = "Text",
		text = "",
		textSize = textSize,
		size = UDim2.fromOffset(0, hud.ObjectiveHeight),
		zIndex = 3,
		layoutOrder = 2,
		parent = row,
	})
	label.TextTruncate = Enum.TextTruncate.AtEnd
	-- R78 quest counter ("3/5"), only with a secondary objective that has one.
	local counter = StudUI.text({
		name = "Counter",
		text = "",
		textSize = textSize,
		font = "number",
		color = UIStyleConfig.Neutral.CashGreen,
		size = UDim2.fromOffset(0, hud.ObjectiveHeight),
		zIndex = 3,
		layoutOrder = 3,
		parent = row,
	})
	counter.Visible = false
	-- R78 progress bar under the text (secondary objectives with a progress value).
	local bar = StudUI.progressBar({
		color = "green",
		size = UDim2.new(1, -BAR_INSET * 2, 0, BAR_HEIGHT),
		parent = chip,
	})
	bar.frame.AnchorPoint = Vector2.new(0.5, 1)
	bar.frame.Position = UDim2.new(0.5, 0, 1, -7)
	bar.frame.ZIndex = 3
	bar.frame.Visible = false
	-- R78: the whole chip opens Quests on touch / mouse while a tappable secondary shows. Never
	-- gamepad-selectable (no HUD cursor trap); B / Back never sees it.
	local tap = Create.new("TextButton", {
		Name = "OpenQuests",
		BackgroundTransparency = 1,
		Text = "",
		Size = UDim2.fromScale(1, 1),
		ZIndex = 10,
		AutoButtonColor = false,
		Selectable = false,
		Visible = false,
		Parent = chip,
	}) :: TextButton
	-- Arrow + gaps + paddings around the label (design px).
	local chrome = (hud.ObjectiveHeight - 16) + 10 + 32
	-- Sizes the label to its text (measured synchronously; FredokaOne matches the label's font).
	-- One line while it fits the chip's cap minus the chrome; otherwise the label wraps to two
	-- lines and the chip grows upward (anchored at its bottom), truncating with "..." only
	-- beyond two lines (phones cap the chip at HudPlacement.PhoneObjectiveMax). A progress bar
	-- adds BAR_SPACE under the row.
	local twoLineHeight = textSize * 2 + 18
	local function sizeLabel()
		local counterWidth = 0
		if counter.Visible then
			local measuredCounter =
				TextService:GetTextSize(counter.Text, textSize, Enum.Font.LuckiestGuy, Vector2.new(4096, 4096))
			counterWidth = math.ceil(measuredCounter.X + 6)
			counter.Size = UDim2.fromOffset(counterWidth, hud.ObjectiveHeight)
			counterWidth += 10 -- the list padding before it
		end
		local measured = TextService:GetTextSize(label.Text, textSize, Enum.Font.FredokaOne, Vector2.new(4096, 4096))
		local room = math.max(80, maxWidth - chrome - counterWidth)
		local wraps = measured.X + 6 > room
		local height = if wraps then math.max(hud.ObjectiveHeight, twoLineHeight) else hud.ObjectiveHeight
		label.TextWrapped = wraps
		label.Size = UDim2.fromOffset(math.ceil(if wraps then room else measured.X + 6), height)
		row.Size = UDim2.fromOffset(0, height)
		local barSpace = if bar.frame.Visible then BAR_SPACE else 0
		chip.Size = UDim2.fromOffset(chip.Size.X.Offset, height + barSpace)
	end
	-- The chip is exactly as wide as its row (StudUI.fitWidth), capped at maxWidth.
	local refit = StudUI.fitWidth(chip, row, 0, function(): number
		return maxWidth
	end)
	-- Chip arrow bob (shared driver; parked when hidden / Reduce Motion / Low graphics).
	local bob = Create.new("UIScale", { Name = "Bob", Parent = chipArrow }) :: UIScale
	OfferFx.register({
		root = chipArrow,
		rates = OfferFxConfig.Sunburst.Hz,
		step = function(_dt: number, elapsed: number)
			bob.Scale = 1 + 0.08 * math.sin(elapsed * BOB_SPEED)
		end,
	})

	local worldArrow = StudUI.icon("Arrow", ARROW_SIZE, 2)
	worldArrow.Name = "TargetArrow"
	worldArrow.AnchorPoint = Vector2.new(0.5, 0.5)
	worldArrow.Visible = false
	worldArrow.Parent = container

	local currentTarget: ArrowTarget? = nil
	local stepConnection: RBXScriptConnection? = nil
	local clock = 0
	-- The primary objective (Hud.setObjective / setWorldObjective).
	local primaryText: string? = nil
	local primaryTarget: ArrowTarget? = nil
	-- The tap callback of the secondary objective currently shown.
	local tapCallback: (() -> ())? = nil

	-- R84 callout badge: built once per callout (never per frame), parked while unused.
	local badge: Frame? = nil
	local badgeFor: Callout? = nil
	-- R84 pointer scratch (reused every frame: no allocation in the per-frame path).
	local targetBox: PointerLogic.Box = { x0 = 0, y0 = 0, x1 = 0, y1 = 0 }
	local avoidBox: PointerLogic.Box = { x0 = 0, y0 = 0, x1 = 0, y1 = 0 }
	local boundsBox: PointerLogic.Box = { x0 = 0, y0 = 0, x1 = 0, y1 = 0 }
	local blockedPool: { PointerLogic.Box } = {}
	local blocked: { PointerLogic.Box } = {}
	local pointerInput: PointerLogic.Input = {
		target = targetBox,
		avoid = avoidBox,
		arrow = ARROW_SIZE,
		gap = Pointer.Gap,
		bob = Pointer.Bob,
		badgeW = 0,
		badgeH = 0,
		bounds = boundsBox,
		blocked = blocked,
		order = PointerLogic.DefaultOrder,
		previous = nil,
	}
	local placed: PointerLogic.Placement = {
		side = "below",
		x = 0,
		y = 0,
		rotation = 0,
		dirX = 0,
		dirY = -1,
		badgeX = 0,
		badgeY = 0,
		fits = false,
	}

	-- (Re)builds the badge for the current callout (only when a different callout arrives).
	local function applyCallout()
		local spec = callout
		if spec == badgeFor then
			return
		end
		badgeFor = spec
		pointerInput.previous = nil -- a new pointer picks its side afresh
		if badge ~= nil then
			badge:Destroy()
			badge = nil
		end
		local build = if spec ~= nil then spec.build else nil
		if build == nil then
			return
		end
		local ok, glyph = pcall(build)
		if not ok or typeof(glyph) ~= "Instance" or not glyph:IsA("GuiObject") then
			warn(`[HudObjective] callout glyph build failed: {glyph}`)
			return
		end
		-- A dark stud badge with a yellow edge around the glyph (the arrow's colour).
		local holder = Create.new("Frame", {
			Name = "TargetBadge",
			AnchorPoint = Vector2.new(0.5, 0.5),
			AutomaticSize = Enum.AutomaticSize.XY,
			Size = UDim2.fromOffset(0, 0),
			BackgroundColor3 = UIStyleConfig.Neutral.Body,
			Visible = false,
			ZIndex = 2,
			Parent = container,
			Children = {
				Create.new("UICorner", { CornerRadius = UDim.new(0, 12) }),
				Create.new("UIStroke", {
					Color = TycoonClientConfig.TutorialHighlight.Color,
					Thickness = 4,
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				}),
				Create.new("UIPadding", {
					PaddingLeft = UDim.new(0, Pointer.BadgePad),
					PaddingRight = UDim.new(0, Pointer.BadgePad),
					PaddingTop = UDim.new(0, Pointer.BadgePad),
					PaddingBottom = UDim.new(0, Pointer.BadgePad),
				}),
			},
		}) :: Frame
		glyph.Parent = holder
		badge = holder
	end
	calloutAppliers[chip] = applyCallout

	-- Hides the arrow and the badge.
	local function hideArrow()
		worldArrow.Visible = false
		if badge ~= nil then
			badge.Visible = false
		end
	end

	--[[
		Measures a GuiObject target into targetBox (the button) + avoidBox (its whole board for a
		billboard button; the button for a screen button), in design px on the HUD canvas.
		@return ("shown") boxes valid | ("world", spot) point at that world spot instead (board
		        not drawn / behind the camera) | ("gone") nothing to point at
	]]
	local function measureControl(control: GuiObject, camera: Camera, scale: number): (string, Vector3?)
		local layer = control:FindFirstAncestorWhichIsA("LayerCollector")
		if layer == nil then
			return "gone", nil
		end
		if layer:IsA("BillboardGui") then
			local cameraFrame = camera.CFrame
			local center = billboardCenter(layer, cameraFrame)
			if center == nil then
				return "gone", nil
			end
			if not layer.Enabled or not chainVisible(control, layer) then
				return "world", center
			end
			local toCenter = center - cameraFrame.Position
			local depth = toCenter:Dot(cameraFrame.LookVector)
			-- Not drawn (culled by distance) or behind / at the camera: the world path handles it.
			if toCenter.Magnitude > layer.MaxDistance or depth <= 0.5 then
				return "world", center
			end
			local layerSize = layer.AbsoluteSize
			if layerSize.X <= 0 or layerSize.Y <= 0 then
				return "world", center
			end
			-- The board faces the camera, so its rect on screen is its stud size at this depth.
			local viewport = camera.ViewportSize
			local pxPerStud = viewport.Y / (2 * depth * math.tan(math.rad(camera.FieldOfView) / 2))
			local size = layer.Size
			local boardW = size.X.Scale * pxPerStud + size.X.Offset
			local boardH = size.Y.Scale * pxPerStud + size.Y.Offset
			if boardW <= 0 or boardH <= 0 then
				return "world", center
			end
			local point = camera:WorldToViewportPoint(center)
			local sizeOffset = layer.SizeOffset
			local left = point.X - boardW / 2 + sizeOffset.X * boardW
			local top = point.Y - boardH / 2 - sizeOffset.Y * boardH
			-- The control's place on the board as fractions of the board's canvas.
			local layerPosition = layer.AbsolutePosition
			local position, extent = control.AbsolutePosition, control.AbsoluteSize
			local fx0 = (position.X - layerPosition.X) / layerSize.X
			local fy0 = (position.Y - layerPosition.Y) / layerSize.Y
			local fx1 = fx0 + extent.X / layerSize.X
			local fy1 = fy0 + extent.Y / layerSize.Y
			targetBox.x0, targetBox.y0 = (left + fx0 * boardW) / scale, (top + fy0 * boardH) / scale
			targetBox.x1, targetBox.y1 = (left + fx1 * boardW) / scale, (top + fy1 * boardH) / scale
			avoidBox.x0, avoidBox.y0 = left / scale, top / scale
			avoidBox.x1, avoidBox.y1 = (left + boardW) / scale, (top + boardH) / scale
			return "shown", center
		end
		-- A ScreenGui button (touch controls): its rect relative to our full-screen container.
		if not layer.Enabled or not chainVisible(control, layer) then
			return "gone", nil
		end
		local position, extent = control.AbsolutePosition, control.AbsoluteSize
		if extent.X <= 0 or extent.Y <= 0 then
			return "gone", nil
		end
		local origin = container.AbsolutePosition
		local x0, y0 = (position.X - origin.X) / scale, (position.Y - origin.Y) / scale
		local x1, y1 = x0 + extent.X / scale, y0 + extent.Y / scale
		targetBox.x0, targetBox.y0, targetBox.x1, targetBox.y1 = x0, y0, x1, y1
		avoidBox.x0, avoidBox.y0, avoidBox.x1, avoidBox.y1 = x0, y0, x1, y1
		return "shown", nil
	end

	-- A pooled Box for blocked slot `index` (grown once, then reused every frame).
	local function pooledBox(index: number): PointerLogic.Box
		local box = blockedPool[index]
		if box == nil then
			box = { x0 = 0, y0 = 0, x1 = 0, y1 = 0 }
			blockedPool[index] = box
		end
		return box
	end

	-- Fills `blocked` with the HUD zones + the callout's keep-clear controls (design px).
	local function collectBlocked(scale: number, target: GuiObject)
		table.clear(blocked)
		local count = 0
		for _, name in POINTER_ZONES do
			local rect = HudZones.rect(name)
			if rect ~= nil then
				count += 1
				local box = pooledBox(count)
				-- The chip's zone grows upward over the hint bar band (see HINT_BAND).
				local top = if name == "Bottom" then rect.y - HINT_BAND else rect.y
				box.x0, box.y0, box.x1, box.y1 = rect.x, top, rect.x + rect.w, rect.y + rect.h
				table.insert(blocked, box)
			end
		end
		local spec = badgeFor
		local keepClear = if spec ~= nil then spec.keepClear else nil
		if keepClear ~= nil then
			local origin = container.AbsolutePosition
			for _, object in keepClear do
				if object ~= target and object.Parent ~= nil and object.Visible then
					local position, extent = object.AbsolutePosition, object.AbsoluteSize
					if extent.X > 0 and extent.Y > 0 then
						count += 1
						local box = pooledBox(count)
						box.x0 = (position.X - origin.X) / scale
						box.y0 = (position.Y - origin.Y) / scale
						box.x1 = box.x0 + extent.X / scale
						box.y1 = box.y0 + extent.Y / scale
						table.insert(blocked, box)
					end
				end
			end
		end
	end

	-- Off screen: the arrow on the screen edge pointing towards (x, y) (see `step`).
	local function edgeArrow(x: number, y: number, behind: boolean, width: number, height: number)
		if badge ~= nil then
			badge.Visible = false
		end
		-- Clamp to the play area between the HUD columns (so the arrow never sits on a HUD
		-- button / offer), pointing towards the target (behind the camera mirrors).
		local minX, maxX = EDGE_INSET, width - EDGE_INSET
		local left, right = HudZones.rect("Left"), HudZones.rect("Right")
		if left ~= nil then
			minX = math.max(minX, left.x + left.w + ARROW_SIZE / 2 + 8)
		end
		if right ~= nil then
			maxX = math.min(maxX, right.x - ARROW_SIZE / 2 - 8)
		end
		local minY, maxY = EDGE_INSET, height - EDGE_INSET
		if maxX <= minX then
			minX, maxX = EDGE_INSET, width - EDGE_INSET
		end
		local cx, cy = width / 2, height / 2
		local dx, dy = x - cx, y - cy
		if behind then
			dx, dy = -dx, -dy
		end
		if dx == 0 and dy == 0 then
			dy = 1
		end
		-- Ray from the centre to the first edge of the [minX, maxX] x [minY, maxY] box.
		local tx = if dx > 0 then (maxX - cx) / dx elseif dx < 0 then (minX - cx) / dx else math.huge
		local ty = if dy > 0 then (maxY - cy) / dy elseif dy < 0 then (minY - cy) / dy else math.huge
		local t = math.max(0, math.min(tx, ty))
		worldArrow.Visible = true
		worldArrow.Position = UDim2.fromOffset(cx + dx * t, cy + dy * t)
		-- The glyph points down (+90° in screen space); rotate it onto the direction.
		worldArrow.Rotation = PointerLogic.rotationFor(dx, dy)
	end

	-- R84: the arrow (+ badge) beside an on-screen button (PointerLogic), bobbing away from it.
	local function pointAtControl(control: GuiObject, scale: number, width: number, height: number, bobPx: number)
		local spec = badgeFor
		local own = spec ~= nil and spec.target == control
		local holder = if own then badge else nil
		local badgeW, badgeH = 0, 0
		if holder ~= nil then
			local extent = holder.AbsoluteSize
			-- First frame (not laid out yet): estimate from the glyph height + padding.
			local estimate = Pointer.BadgeGlyph + Pointer.BadgePad * 2
			badgeW = if extent.X > 0 then extent.X / scale else estimate
			badgeH = if extent.Y > 0 then extent.Y / scale else estimate
		end
		boundsBox.x0, boundsBox.y0 = EDGE_INSET / 2, EDGE_INSET / 2
		boundsBox.x1, boundsBox.y1 = width - EDGE_INSET / 2, height - EDGE_INSET / 2
		collectBlocked(scale, control)
		pointerInput.badgeW, pointerInput.badgeH = badgeW, badgeH
		local sides = if own and spec ~= nil then spec.sides else nil
		pointerInput.order = if sides ~= nil and #sides > 0 then sides else PointerLogic.DefaultOrder
		PointerLogic.place(pointerInput, placed)
		pointerInput.previous = placed.side
		local ox, oy = -placed.dirX * bobPx, -placed.dirY * bobPx
		worldArrow.Visible = true
		worldArrow.Rotation = placed.rotation
		worldArrow.Position = UDim2.fromOffset(placed.x + ox, placed.y + oy)
		if badge ~= nil then
			badge.Visible = holder ~= nil
			if holder ~= nil then
				holder.Position = UDim2.fromOffset(placed.badgeX + ox, placed.badgeY + oy)
			end
		end
	end

	-- Places the world arrow for this frame (see the module header).
	local function step(dt: number)
		local target = currentTarget
		local camera = Workspace.CurrentCamera
		local gui = container:FindFirstAncestorOfClass("ScreenGui")
		if target == nil or camera == nil or gui == nil or not gui.Enabled then
			hideArrow()
			return
		end
		-- Reduce Motion: the arrow stays still (no bob).
		if not OfferFx.reducedMotion() then
			clock += dt
		end
		local bobPx = BOB_PIXELS * math.abs(math.sin(clock * BOB_SPEED))
		local scale = math.max(ScreenManager.scale, 0.01)
		local viewport = camera.ViewportSize
		local width, height = viewport.X / scale, viewport.Y / scale
		local position: Vector3? = nil
		local lift = HEIGHT_ABOVE
		if typeof(target) == "Instance" and target:IsA("GuiObject") then
			local status, spot = measureControl(target, camera, scale)
			if status == "shown" then
				local cx, cy = (targetBox.x0 + targetBox.x1) / 2, (targetBox.y0 + targetBox.y1) / 2
				if cx >= EDGE_INSET and cx <= width - EDGE_INSET and cy >= EDGE_INSET and cy <= height - EDGE_INSET then
					pointAtControl(target, scale, width, height, bobPx)
				else
					edgeArrow(cx, cy, false, width, height)
				end
				return
			elseif status == "world" then
				-- The board is not drawn: point at its spot like a world target (no extra lift;
				-- the spot already floats where the board would be).
				position, lift = spot, 0
			else
				hideArrow()
				return
			end
		else
			position = positionOf(target)
		end
		if position == nil then
			hideArrow()
			return
		end
		if badge ~= nil then
			badge.Visible = false
		end
		local point = camera:WorldToViewportPoint(position + Vector3.new(0, lift, 0))
		local x, y = point.X / scale, point.Y / scale
		local inside = point.Z > 0
			and x >= EDGE_INSET
			and x <= width - EDGE_INSET
			and y >= EDGE_INSET
			and y <= height - EDGE_INSET
		if inside then
			-- Over the target, pointing down, bobbing.
			worldArrow.Visible = true
			worldArrow.Rotation = 0
			worldArrow.Position = UDim2.fromOffset(x, y - ARROW_SIZE / 2 - bobPx)
			return
		end
		edgeArrow(x, y, point.Z <= 0, width, height)
	end

	local function refreshStep()
		local want = currentTarget ~= nil
		if want and stepConnection == nil then
			stepConnection = RunService.PreRender:Connect(step)
		elseif not want and stepConnection ~= nil then
			stepConnection:Disconnect()
			stepConnection = nil
			hideArrow()
		end
	end

	-- Shows the primary objective, else the secondary one, else hides the chip.
	local function apply()
		local text: string? = nil
		local target: ArrowTarget? = nil
		local extra: Secondary? = nil
		if primaryText ~= nil and primaryText ~= "" then
			text, target = primaryText, primaryTarget
		elseif secondary ~= nil then
			extra = secondary
			text, target = secondary.text, secondary.target
		end
		local progress = if extra ~= nil then extra.progress else nil
		local showBar = progress ~= nil and progress == progress
		bar.frame.Visible = showBar
		if showBar then
			bar.setProgress(progress :: number)
		end
		local counterText = if extra ~= nil then extra.progressText else nil
		counter.Visible = counterText ~= nil and counterText ~= ""
		counter.Text = counterText or ""
		tapCallback = if extra ~= nil then extra.onActivated else nil
		-- Inert under any open window: a click on a window's empty area must never fall through
		-- to the chip (R78 QA: Quests stacked over NukePass). Re-checked on every open / close.
		tap.Visible = tapCallback ~= nil and not ScreenManager.anyModalOpen()
		local previousTarget = currentTarget
		if text == nil then
			chip.Visible = false
			currentTarget = nil
		else
			label.Text = text
			sizeLabel() -- fitWidth follows the row's AbsoluteSize on its own
			chip.Visible = true
			currentTarget = target
		end
		if currentTarget ~= previousTarget then
			pointerInput.previous = nil -- a new target picks its side afresh
		end
		refreshStep()
	end
	appliers[chip] = apply

	-- Windows opening / closing toggle the tap target (event-driven, no polling).
	local function refreshTap()
		tap.Visible = tapCallback ~= nil and not ScreenManager.anyModalOpen()
	end
	local openedConnection = ScreenManager.Opened:Connect(refreshTap)
	local closedConnection = ScreenManager.Closed:Connect(refreshTap)

	tap.Activated:Connect(function()
		local callback = tapCallback
		if callback ~= nil then
			callback()
		end
	end)

	container.Destroying:Once(function()
		appliers[chip] = nil
		calloutAppliers[chip] = nil
		openedConnection:Disconnect()
		closedConnection:Disconnect()
		if stepConnection ~= nil then
			stepConnection:Disconnect()
			stepConnection = nil
		end
	end)

	-- A secondary objective / callout set before the HUD existed shows at once.
	applyCallout()
	apply()

	return {
		frame = chip,
		set = function(text: string?, target: ArrowTarget?)
			primaryText = text
			primaryTarget = if text ~= nil and text ~= "" then target else nil
			apply()
		end,
		place = function(bottomY: number, width: number, centerX: number)
			chip.Position = UDim2.fromOffset(centerX, bottomY)
			if width ~= maxWidth then
				maxWidth = width
				sizeLabel()
				refit()
			end
		end,
		target = function(): ArrowTarget?
			return currentTarget
		end,
	}
end

return table.freeze(HudObjective)
