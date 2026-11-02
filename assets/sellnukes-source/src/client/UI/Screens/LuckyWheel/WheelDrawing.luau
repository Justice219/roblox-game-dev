--!strict
--[[
	WheelDrawing — draws the Lucky Wheel disc from plain GuiObjects (no image assets exist for
	it): a white studded rim, a dark ring, the rotating coloured disc with its slice dividers,
	slice labels and slice icons, a dark hub and the white down-arrow pointer at the top
	(reference: docs/reference/ui-style/03-lucky-wheel.png).

	How the disc is drawn (built ONCE, never per frame):
		- The disc is a CanvasGroup: its own Rotation turns everything inside it (the spin is one
		  property tween), and UICorner(1, 0) clips its whole content to a circle.
		- Slices are RADIAL BARS: every STEP_DEGREES a thin Frame of height = radius runs from
		  the centre to the rim, centred at centre + (radius / 2)·(sin a, −cos a) with
		  Rotation = a (a GuiObject rotates about its own centre), coloured by the slice that
		  owns angle a. Bars sit at the middle of each step inside their slice, so a slice is
		  filled edge to edge without any image.
		- A bar is a rectangle, so near the centre it pokes a few px past its slice edge. The dark
		  divider on every slice edge is exactly as wide as a bar, which always covers that
		  overlap (overlap = halfWidth − ρ·sin(step / 2) ≤ halfWidth for every radius ρ).
		- The stud material (Widgets/PanelBackdrop) lies over the bars, then the dividers, icons
		  and labels; the hub and the pointer are outside the disc's CanvasGroup (the spin never
		  turns them; the pointer only swings as the ticker flapper, below).
	Angles are degrees clockwise from the top (Roblox GuiObject.Rotation is clockwise too).
	Slice i (1-based) spans [(i − 1)·span, i·span) with span = 360 / #slices.

	Spin juice layers (owner R81; animated by Screens/LuckyWheel/WheelFx, tuned in
	Shared/Config/LuckyWheelFxConfig). Everything is built here ONCE and only shown / moved later:
		- Pegs: gold studs on the disc rim at every slice edge (inside the CanvasGroup, so they turn
		  with it). The wheel always rests on a slice centre, halfway between two pegs.
		- Flapper: the pointer is the ticker. Its arrow lives in a small CanvasGroup whose centre is
		  the hinge (Flapper.Pivot down the arrow), so rotating that group swings the tip sideways.
		  A CanvasGroup (not a Frame) because the arrow head is clipped by ClipsDescendants, which
		  Roblox ignores under a rotated Frame; inside a CanvasGroup the content renders unrotated
		  into its texture and only the texture turns.
		- Bulbs: light bulbs on the white rim (never turn), the top one left out under the pointer.
		- WinGlow: a white wedge over the slice under the pointer (the winner always lands there) in
		  a small CanvasGroup, so a pulse is one GroupTransparency write.
		- Streaks: translucent motion arcs (short tangent bars, head bright, tail fading) in a plain
		  Frame that turns with the disc while it is fast.
		- WinRays: light rays BEHIND the wheel (only their ends past the rim show).
	`body` holds the whole wheel so a shake can move it without touching `root`'s layout position.

	Purely presentational: labels are passed in by the screen (which derives them from the
	profile snapshot through RewardPreview); nothing here talks to the server.

	Connects to: Screens/LuckyWheel (the only caller) + its WheelFx (animates the handles below),
	Kit/StudUI (icons, outlined text), Widgets/PanelBackdrop (studs), UI/Create,
	Shared/Config/{LuckySpinConfig, LuckyWheelFxConfig, UIStyleConfig}.

	Example:
		local wheel = WheelDrawing.build({ diameter = 520, slices = LuckySpinConfig.Slices,
			labels = { "500 Cash", "5 GEMS", ... } })
		wheel.root.Parent = stage
		wheel.canvas.Rotation = -WheelDrawing.midAngle(3, #LuckySpinConfig.Slices) -- slice 3 on top
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Create = require(script.Parent.Parent.Parent.Create)
local LuckySpinConfig = require(ReplicatedStorage.Shared.Config.LuckySpinConfig)
local LuckyWheelFxConfig = require(ReplicatedStorage.Shared.Config.LuckyWheelFxConfig)
local PanelBackdrop = require(script.Parent.Parent.Parent.Widgets.PanelBackdrop)
local SpinMotion = require(script.Parent.SpinMotion)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local Neutral = UIStyleConfig.Neutral

-- ── Geometry (fractions of the disc diameter D unless noted) ─────────────────────────────────

-- Angular distance between two radial bars (degrees).
local STEP_DEGREES = 2.5
-- Bar width = the chord a step covers at the rim × this margin (> 1 so neighbouring bars
-- overlap a little at the rim and no background seam can show between them).
local BAR_OVERLAP = 1.12
-- White rim around the disc and the dark ring between rim and disc.
local RIM = 0.045
local RING = 0.012
-- Dark outline around the white rim (px).
local RIM_EDGE = 4
-- Hub (dark centre circle) diameter.
local HUB = 0.13
-- Slice label: distance from the centre (× radius), box size (× radius), max text size (× D).
-- The box is tall enough for TWO lines ("1.25K" / "Cash"), so TextScaled settles near 30 px
-- for a 520 px disc: ≥ 14 pt even on the narrowest phone (side layout, fit ≈ 0.82 × 0.62).
-- 0.42 R wide keeps the box inside the slice: the chord at 0.6 R minus the dividers.
local LABEL_RADIUS = 0.6
local LABEL_WIDTH = 0.42
local LABEL_HEIGHT = 0.28
local LABEL_TEXT = 0.07
-- Slice icon: distance from the centre (× radius) and side (× D); it sits outside the label
-- (label spans 0.46–0.74 R, icon 0.75–0.97 R).
local ICON_RADIUS = 0.86
local ICON_SIZE = 0.11
-- Pointer: arrow width / total height (× D) and outline thickness (× D, ≥ 3 px).
local POINTER_WIDTH = 0.11
local POINTER_HEIGHT = 0.13
local POINTER_EDGE = 0.009
-- How far the pointer tip reaches into the coloured disc (× D).
local POINTER_TIP_INSET = 0.035
-- Stud texture on the disc / rim (opacity: 1 = invisible).
local DISC_STUD_TRANSPARENCY = 0.6
local RIM_STUD_TRANSPARENCY = 0.55
local RIM_COLOR = Color3.fromRGB(248, 248, 250)

export type Options = {
	diameter: number, -- coloured disc diameter (design px)
	slices: { LuckySpinConfig.Slice },
	labels: { string }, -- one caption per slice (same order)
}

-- Sizes derived from a disc diameter (design px); the screen lays out with them before building.
export type Metrics = {
	diameter: number, -- coloured disc diameter
	rim: number, -- white rim width
	ring: number, -- dark ring width
	side: number, -- root side = diameter + 2 * (rim + ring)
	edge: number, -- pointer outline thickness
	pointerWidth: number,
	pointerHeight: number,
	pointerTop: number, -- y of the pointer's bounding box inside root (negative = above root)
	overhang: number, -- px the pointer reaches above root (>= 0)
}

-- One motion-arc bar and how far along its arc it sits (0 = bright head .. <1 = faded tail).
export type StreakSegment = { frame: Frame, fade: number }

export type Wheel = {
	root: Frame, -- square holder (rim outer diameter); the pointer pokes above it by `overhang`
	body: Frame, -- the whole wheel inside `root` (shake target; root keeps the layout position)
	canvas: CanvasGroup, -- the rotating disc (WheelFx drives its Rotation)
	flapper: CanvasGroup, -- the pointer / ticker (its Rotation swings the tip; 0 = straight down)
	bulbs: { Frame }, -- rim bulbs; bulbs[i] sits i · 360 / Bulbs.Count degrees from the top
	glow: CanvasGroup, -- white wedge over the top slice (GroupTransparency pulses; hidden at rest)
	streaks: Frame, -- motion arcs (turn with the disc; hidden at rest)
	streakSegments: { StreakSegment },
	rays: Frame, -- light rays behind the wheel (hidden at rest)
	rayBars: { Frame },
	pegSpacing: number, -- degrees between neighbouring pegs
	centre: number, -- wheel centre inside root / body (x = y, design px)
	radius: number, -- coloured disc radius (design px)
	size: number, -- root side (design px)
	overhang: number, -- px the pointer reaches above `root`
	setLabels: (labels: { string }) -> (),
	Destroy: () -> (),
}

local WheelDrawing = {}

--[[
	Every size of a wheel with a `diameter` px disc (pure math, no Instances).
	@param diameter coloured disc diameter (design px)
	@return Metrics
	Example: WheelDrawing.metrics(520).side --> 578
]]
function WheelDrawing.metrics(diameter: number): Metrics
	local d = math.floor(diameter)
	local rim = math.floor(d * RIM + 0.5)
	local ring = math.max(4, math.floor(d * RING + 0.5))
	local edge = math.max(3, math.floor(d * POINTER_EDGE + 0.5))
	local pointerWidth = d * POINTER_WIDTH
	local pointerHeight = d * POINTER_HEIGHT
	-- The fill tip sits POINTER_TIP_INSET inside the disc; the arrow box is height + edge above it.
	local tipY = rim + ring + d * POINTER_TIP_INSET
	local pointerTop = tipY - (pointerHeight + edge)
	return {
		diameter = d,
		rim = rim,
		ring = ring,
		side = d + 2 * (rim + ring),
		edge = edge,
		pointerWidth = pointerWidth,
		pointerHeight = pointerHeight,
		pointerTop = pointerTop,
		overhang = math.max(0, math.ceil(-pointerTop)),
	}
end

--[[
	Mid-angle of slice `index` (degrees clockwise from the top).
	@param index 1-based slice index
	@param count number of slices
	@return number
	Example: WheelDrawing.midAngle(1, 8) --> 22.5
]]
function WheelDrawing.midAngle(index: number, count: number): number
	local span = 360 / math.max(1, count)
	return (index - 0.5) * span
end

--[[
	The canvas rotation that brings slice `index` under the top pointer, at least `extraTurns`
	full turns past `current` (so the spin always moves forward, clockwise).
	The result r satisfies (midAngle(index) + r) mod 360 == 0: rotating the disc by r moves the
	slice's mid-angle to 0° (the top).
	@param current    the canvas Rotation now
	@param index      1-based slice index
	@param count      number of slices
	@param extraTurns whole turns to add (5 on a normal spin, 0 for an instant snap)
	@return number
	Example: WheelDrawing.targetRotation(0, 1, 8, 5) --> 1800 + 337.5
]]
function WheelDrawing.targetRotation(current: number, index: number, count: number, extraTurns: number): number
	local base = current + extraTurns * 360
	-- Luau's % is floored (non-negative for a positive divisor), so delta is in [0, 360).
	local delta = (-WheelDrawing.midAngle(index, count) - base) % 360
	return base + delta
end

-- A plain filled circle (UICorner 1,0) centred at (x, y) inside its parent.
local function circle(name: string, side: number, x: number, y: number, color: Color3, zIndex: number): Frame
	return Create.new("Frame", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(side, side),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Active = false,
		Selectable = false,
		ZIndex = zIndex,
		Children = { Create.new("UICorner", { CornerRadius = UDim.new(1, 0) }) },
	}) :: Frame
end

-- A bar from the disc centre to the rim at angle `angle` (degrees clockwise from the top).
-- Its centre sits half a radius out along the angle; Rotation turns it about that centre.
local function radialBar(
	name: string,
	radius: number,
	angle: number,
	width: number,
	color: Color3,
	zIndex: number
): Frame
	local rad = math.rad(angle)
	return Create.new("Frame", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		-- +2 px: one past the rim (clipped by the circle) and one past the centre (no pinhole).
		Size = UDim2.fromOffset(width, radius + 2),
		Position = UDim2.fromOffset(radius + (radius / 2) * math.sin(rad), radius - (radius / 2) * math.cos(rad)),
		Rotation = angle,
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Active = false,
		Selectable = false,
		ZIndex = zIndex,
	}) :: Frame
end

--[[
	Builds the white down-arrow pointer (stem + triangular head) with a dark outline, from
	plain frames: each triangle is the lower half of a 45°-rotated square, cut by an unrotated
	ClipsDescendants frame. The outline layer is the same shape grown by `edge` px on every side
	and drawn under the fill layer, so stem and head share one clean silhouette.
	@param width  arrow head width (px)
	@param height total arrow height (px)
	@param edge   outline thickness (px)
	@return Frame (size = the arrow's bounding box incl. outline; tip at the bottom centre)
]]
local function buildPointer(width: number, height: number, edge: number): Frame
	local boxW = math.ceil(width + 4 * edge)
	local boxH = math.ceil(height + 2 * edge)
	local holder = Create.new("Frame", {
		Name = "Pointer",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(boxW, boxH),
		Active = false,
		Selectable = false,
	}) :: Frame
	holder:SetAttribute("Decorative", true)
	local cx = boxW / 2
	local headH = width / 2 -- a right-angled head: half as tall as it is wide
	local stemW = width * 0.42
	local stemTop = edge
	local headTop = edge + (height - headH) -- y of the head's flat top edge
	local square = width / math.sqrt(2) -- side of the square whose lower half is the head

	-- One stem rectangle (outline or fill).
	local function stem(name: string, grow: number, color: Color3, zIndex: number)
		Create.new("Frame", {
			Name = name,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromOffset(cx, stemTop - grow),
			-- Runs 2 px into the head so the fill has no seam.
			Size = UDim2.fromOffset(stemW + 2 * grow, (headTop - stemTop) + grow + 2),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Active = false,
			ZIndex = zIndex,
			Parent = holder,
			Children = { Create.new("UICorner", { CornerRadius = UDim.new(0, math.max(2, math.floor(edge))) }) },
		})
	end

	-- One head triangle (outline or fill): clip lane from the flat top edge (raised by `grow`)
	-- down, holding a 45° square whose centre sits on the original top edge.
	local function head(name: string, grow: number, color: Color3, zIndex: number)
		local side = square + 2 * grow -- every edge pushed out by `grow`
		local clipW = width + 4 * grow + 2
		local clipH = headH + 3 * grow + 2
		local clip = Create.new("Frame", {
			Name = name,
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromOffset(cx, headTop - grow),
			Size = UDim2.fromOffset(clipW, clipH),
			ClipsDescendants = true,
			Active = false,
			ZIndex = zIndex,
			Parent = holder,
		}) :: Frame
		Create.new("Frame", {
			Name = "Square",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0, grow),
			Size = UDim2.fromOffset(side, side),
			Rotation = 45,
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Active = false,
			ZIndex = zIndex,
			Parent = clip,
		})
	end

	stem("StemOutline", edge, Neutral.Edge, 1)
	head("HeadOutline", edge, Neutral.Edge, 1)
	stem("StemFill", 0, Color3.new(1, 1, 1), 2)
	head("HeadFill", 0, Color3.new(1, 1, 1), 2)
	return holder
end

--[[
	Builds the whole wheel (see the module header). Call once per screen.
	@param options diameter / slices / labels
	@return Wheel handle
	Example: local wheel = WheelDrawing.build({ diameter = 520, slices = slices, labels = labels })
]]
function WheelDrawing.build(options: Options): Wheel
	local m = WheelDrawing.metrics(options.diameter)
	local diameter = m.diameter
	local radius = diameter / 2
	local slices = options.slices
	local count = math.max(1, #slices)
	local span = 360 / count
	local ringW = m.ring
	local side = m.side
	local centre = side / 2

	local root = Create.new("Frame", {
		Name = "Wheel",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(side, side),
		Active = false,
		Selectable = false,
	}) :: Frame
	-- Everything visible lives in `body` (same size as root): WheelFx shakes body, root keeps
	-- the position the screen's layout gave it.
	local body = Create.new("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Active = false,
		Selectable = false,
		Parent = root,
	}) :: Frame

	-- Win rays behind everything (ZIndex 0): bars through the centre, faded by a gradient so the
	-- part under the wheel is irrelevant and the ends past the rim glow, then fade to nothing.
	local raysCfg = LuckyWheelFxConfig.Rays
	local raySide = math.floor(side * raysCfg.Size)
	local rays = Create.new("Frame", {
		Name = "WinRays",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(centre, centre),
		Size = UDim2.fromOffset(raySide, raySide),
		BackgroundTransparency = 1,
		Visible = false,
		Active = false,
		Selectable = false,
		ZIndex = 0,
		Parent = body,
	}) :: Frame
	rays:SetAttribute("Decorative", true)
	-- Brightest just outside the rim (the rim sits at 0.5 ± (side / 2) / raySide along a bar).
	local rimAt = math.clamp(0.5 - (side / 2) / raySide, 0.05, 0.45)
	local brightest = 1 - raysCfg.Opacity
	local rayFade = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(rimAt * 0.55, brightest + (1 - brightest) * 0.5),
		NumberSequenceKeypoint.new(rimAt, brightest),
		NumberSequenceKeypoint.new(1 - rimAt, brightest),
		NumberSequenceKeypoint.new(1 - rimAt * 0.55, brightest + (1 - brightest) * 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	local rayBars: { Frame } = {}
	for index = 0, raysCfg.Count - 1 do
		local bar = Create.new("Frame", {
			Name = `Ray{index}`,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(raysCfg.Width, 1),
			Rotation = index * 180 / raysCfg.Count,
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Active = false,
			Selectable = false,
			ZIndex = 0,
			Parent = rays,
			Children = { Create.new("UIGradient", { Rotation = 90, Transparency = rayFade }) },
		}) :: Frame
		table.insert(rayBars, bar)
	end

	-- White studded rim with a dark outline, then the dark ring the disc sits in.
	local rim = circle("Rim", side, centre, centre, RIM_COLOR, 1)
	Create.new("UIStroke", {
		Name = "RimEdge",
		Color = Neutral.Edge,
		Thickness = RIM_EDGE,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = rim,
	})
	rim.Parent = body
	PanelBackdrop.new(rim, {
		zIndex = 1,
		textureTransparency = RIM_STUD_TRANSPARENCY,
		tileSize = UIStyleConfig.StudTile.Button,
		tint = Color3.fromRGB(200, 204, 214),
	})
	circle("Ring", diameter + 2 * ringW, centre, centre, Neutral.Edge, 2).Parent = body

	-- Rim light bulbs (ZIndex 2, over the rim studs): bulb i at i · step from the top, i = 0 (the
	-- pointer's spot) left out, so bulbs[i] is always the bulb at angle i · step.
	local bulbCfg = LuckyWheelFxConfig.Bulbs
	local bulbSide = math.max(6, math.floor(m.rim * bulbCfg.Size + 0.5))
	local bulbRadius = radius + ringW + m.rim / 2
	local bulbs: { Frame } = {}
	for index = 1, bulbCfg.Count - 1 do
		local rad = math.rad(index * 360 / bulbCfg.Count)
		local bulb = circle(
			`Bulb{index}`,
			bulbSide,
			centre + bulbRadius * math.sin(rad),
			centre - bulbRadius * math.cos(rad),
			-- Chase step 0 (WheelFx moves it on from here).
			if SpinMotion.bulbLit(index, 0, bulbCfg.Group) then bulbCfg.Lit else bulbCfg.Dim,
			2
		)
		Create.new("UIStroke", {
			Name = "BulbEdge",
			Color = Neutral.Edge,
			Thickness = bulbCfg.Edge,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Parent = bulb,
		})
		bulb.Parent = body
		bulbs[index] = bulb
	end

	-- The rotating disc.
	local canvas = Create.new("CanvasGroup", {
		Name = "Disc",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(centre, centre),
		Size = UDim2.fromOffset(diameter, diameter),
		BackgroundColor3 = Neutral.Edge,
		BorderSizePixel = 0,
		Active = false,
		Selectable = false,
		ZIndex = 3,
		Children = { Create.new("UICorner", { CornerRadius = UDim.new(1, 0) }) },
		Parent = body,
	}) :: CanvasGroup

	-- Slice colours as radial bars (ZIndex 1). perSlice bars per slice, evenly inside it.
	local perSlice = math.max(1, math.ceil(span / STEP_DEGREES - 1e-6))
	local step = span / perSlice
	-- Chord of one step at the rim, widened by BAR_OVERLAP (see the module header).
	local barWidth = math.ceil(2 * radius * math.tan(math.rad(step / 2)) * BAR_OVERLAP)
	for index, slice in slices do
		local start = (index - 1) * span
		for j = 0, perSlice - 1 do
			local angle = start + step / 2 + j * step
			radialBar(`Bar{index}_{j}`, radius, angle, barWidth, slice.color, 1).Parent = canvas
		end
	end

	-- Studs over the colours (ZIndex 2), rounded by the disc's own UICorner.
	PanelBackdrop.new(canvas, {
		zIndex = 2,
		textureTransparency = DISC_STUD_TRANSPARENCY,
		tileSize = UIStyleConfig.StudTile.Card,
	})

	-- Dark dividers on every slice edge (ZIndex 3), as wide as a bar so they hide the overlap.
	for index = 1, count do
		radialBar(`Divider{index}`, radius, (index - 1) * span, barWidth, Neutral.Edge, 3).Parent = canvas
	end

	-- Rim pegs (ZIndex 4): PerSlice per slice starting on every slice edge, near the disc edge.
	local pegCfg = LuckyWheelFxConfig.Pegs
	local pegCount = count * math.max(1, pegCfg.PerSlice)
	local pegSide = math.max(6, math.floor(diameter * pegCfg.Size + 0.5))
	local pegRadius = pegCfg.Radius * radius
	for index = 0, pegCount - 1 do
		local rad = math.rad(index * 360 / pegCount)
		local peg = circle(
			`Peg{index}`,
			pegSide,
			radius + pegRadius * math.sin(rad),
			radius - pegRadius * math.cos(rad),
			pegCfg.Color,
			4
		)
		Create.new("UIStroke", {
			Name = "PegEdge",
			Color = Neutral.Edge,
			Thickness = pegCfg.Edge,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Parent = peg,
		})
		peg.Parent = canvas
	end

	-- Icons (outer) and labels (inner), both turned to the slice's mid-angle (tops outward).
	local captionLabels: { TextLabel } = {}
	local iconSide = math.floor(diameter * ICON_SIZE)
	local labelText = math.floor(diameter * LABEL_TEXT)
	for index, slice in slices do
		local mid = WheelDrawing.midAngle(index, count)
		local rad = math.rad(mid)
		local sinA, cosA = math.sin(rad), math.cos(rad)

		local icon = StudUI.icon(slice.icon, iconSide, 4)
		icon.Name = `SliceIcon{index}`
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromOffset(radius + ICON_RADIUS * radius * sinA, radius - ICON_RADIUS * radius * cosA)
		icon.Rotation = mid
		icon.Parent = canvas

		local label = StudUI.text({
			name = `SliceLabel{index}`,
			text = options.labels[index] or slice.label,
			textSize = labelText,
			font = "title",
			scaled = true,
			size = UDim2.fromOffset(math.floor(LABEL_WIDTH * radius), math.floor(LABEL_HEIGHT * radius)),
			position = UDim2.fromOffset(radius + LABEL_RADIUS * radius * sinA, radius - LABEL_RADIUS * radius * cosA),
			anchor = Vector2.new(0.5, 0.5),
			zIndex = 5,
			parent = canvas,
		})
		label.Rotation = mid
		captionLabels[index] = label
	end

	-- Win glow over the top slice (ZIndex 4, above the disc): opaque white radial bars from the
	-- hub inside a small CanvasGroup whose bottom-centre is the wheel centre; GroupTransparency is
	-- the only thing WheelFx animates (opaque bars inside the group never stripe where they
	-- overlap). Bars stay `EdgeInset` degrees off the dividers and end inside the disc edge.
	local glowCfg = LuckyWheelFxConfig.Glow
	local glowHalf = math.max(1, span / 2 - glowCfg.EdgeInset)
	local reach = glowCfg.Length * radius
	local glowW = math.ceil(2 * reach * math.sin(math.rad(glowHalf)) + barWidth + 4)
	local glowH = math.ceil(reach) + 2
	local glow = Create.new("CanvasGroup", {
		Name = "WinGlow",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromOffset(centre, centre),
		Size = UDim2.fromOffset(glowW, glowH),
		BackgroundTransparency = 1,
		GroupTransparency = 1,
		Visible = false,
		Active = false,
		Selectable = false,
		ZIndex = 4,
		Parent = body,
	}) :: CanvasGroup
	glow:SetAttribute("Decorative", true)
	local glowBars = math.max(1, math.ceil(2 * glowHalf / STEP_DEGREES - 1e-6))
	local glowStep = 2 * glowHalf / glowBars
	for j = 0, glowBars - 1 do
		local angle = -glowHalf + glowStep / 2 + j * glowStep
		local rad = math.rad(angle)
		Create.new("Frame", {
			Name = `GlowBar{j}`,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(barWidth, reach),
			Position = UDim2.fromOffset(glowW / 2 + (reach / 2) * math.sin(rad), glowH - (reach / 2) * math.cos(rad)),
			Rotation = angle,
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
			Active = false,
			Selectable = false,
			Parent = glow,
		})
	end

	-- Motion arcs (ZIndex 4): per radius `Copies` arcs evenly round the disc, each `Segments`
	-- tangent bars trailing anticlockwise behind a bright head (the disc turns clockwise).
	local streakCfg = LuckyWheelFxConfig.Streaks
	local streaks = Create.new("Frame", {
		Name = "Streaks",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(centre, centre),
		Size = UDim2.fromOffset(diameter, diameter),
		BackgroundTransparency = 1,
		Visible = false,
		Active = false,
		Selectable = false,
		ZIndex = 4,
		Parent = body,
	}) :: Frame
	streaks:SetAttribute("Decorative", true)
	local streakSegments: { StreakSegment } = {}
	local thickness = math.max(3, math.floor(diameter * streakCfg.Width + 0.5))
	for ring, fraction in streakCfg.Radii do
		local r = fraction * radius
		-- Chord of one segment, a little long so neighbouring bars touch along the curve.
		local segLength = math.ceil(2 * r * math.sin(math.rad(streakCfg.SegmentDegrees / 2)) * 1.15)
		for copy = 0, streakCfg.Copies - 1 do
			-- Rings are offset by half a copy gap so the arcs never line up radially.
			local head = (copy + (ring - 1) * 0.5) * 360 / streakCfg.Copies
			for k = 0, streakCfg.Segments - 1 do
				local angle = head - k * streakCfg.SegmentDegrees
				local rad = math.rad(angle)
				local bar = Create.new("Frame", {
					Name = `Streak{ring}_{copy}_{k}`,
					AnchorPoint = Vector2.new(0.5, 0.5),
					Size = UDim2.fromOffset(segLength, thickness),
					Position = UDim2.fromOffset(radius + r * math.sin(rad), radius - r * math.cos(rad)),
					Rotation = angle,
					BackgroundColor3 = Color3.new(1, 1, 1),
					BackgroundTransparency = 1,
					BorderSizePixel = 0,
					Active = false,
					Selectable = false,
					ZIndex = 4,
					Parent = streaks,
				}) :: Frame
				table.insert(streakSegments, { frame = bar, fade = k / streakCfg.Segments })
			end
		end
	end

	-- Hub (never rotates; outside the CanvasGroup so it stays crisp).
	local hub = circle("Hub", math.floor(diameter * HUB), centre, centre, Neutral.Edge, 5)
	Create.new("UIStroke", {
		Name = "HubEdge",
		Color = Color3.fromRGB(70, 74, 88),
		Thickness = 3,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = hub,
	})
	hub.Parent = body

	-- Pointer = ticker flapper: tip a little inside the disc, the rest above the rim (see
	-- metrics). The arrow sits in a CanvasGroup whose CENTRE is the hinge (`Pivot` of the arrow's
	-- height down from its top): the group is twice the hinge-to-bottom distance tall, the arrow in
	-- its lower part, so Rotation turns the arrow about the hinge (the upper part is empty).
	local pointer = buildPointer(m.pointerWidth, m.pointerHeight, m.edge)
	local boxW, boxH = pointer.Size.X.Offset, pointer.Size.Y.Offset
	local pivotY = math.floor(boxH * LuckyWheelFxConfig.Flapper.Pivot + 0.5)
	local flapH = 2 * (boxH - pivotY)
	local flapper = Create.new("CanvasGroup", {
		Name = "Flapper",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(centre, m.pointerTop + pivotY),
		Size = UDim2.fromOffset(boxW, flapH),
		BackgroundTransparency = 1,
		Active = false,
		Selectable = false,
		ZIndex = 6,
		Parent = body,
	}) :: CanvasGroup
	flapper:SetAttribute("Decorative", true)
	pointer.AnchorPoint = Vector2.new(0.5, 0)
	pointer.Position = UDim2.new(0.5, 0, 0, flapH / 2 - pivotY)
	pointer.Parent = flapper

	return {
		root = root,
		body = body,
		canvas = canvas,
		flapper = flapper,
		bulbs = bulbs,
		glow = glow,
		streaks = streaks,
		streakSegments = streakSegments,
		rays = rays,
		rayBars = rayBars,
		pegSpacing = 360 / pegCount,
		centre = centre,
		radius = radius,
		size = side,
		overhang = m.overhang,
		setLabels = function(labels: { string })
			for index, label in captionLabels do
				local text = labels[index]
				if text ~= nil and label.Text ~= text then
					label.Text = text
				end
			end
		end,
		Destroy = function()
			root:Destroy()
		end,
	}
end

return table.freeze(WheelDrawing)
