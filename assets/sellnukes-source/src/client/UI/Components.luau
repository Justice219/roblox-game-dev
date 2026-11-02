--!strict
--[[
	Components — low-level reusable UI building blocks (ported from RoBeasts).

	Purpose:
		The framework-level pieces every screen and the StudUI kit build on, so the game looks
		consistent and is fully gamepad-friendly:
			Components.corner / stroke / padding / listLayout / gridLayout  (decorators)
			Components.label(...)      styled TextLabel (outlined, Fredoka / Luckiest Guy)
			Components.panel(...)      rounded slate panel with a dark border
			Components.button(...)     chunky 3D button: Selectable for gamepad, grows on hover /
			                           selection, squashes on press; drawn by "Lip" + "Face"
			                           children (see the function's header)
			Components.setButtonDimmed(button, dimmed)   disabled look for a Components.button
			Components.hideInTouch(o)  collapses a key-only hint while the player uses touch
		Higher-level, reference-matching widgets (windows, cards, stud buttons, starbursts) live in
		UI/Kit/StudUI, which restyles these.

	Connects to: UI/Create, UI/Theme, Controllers/InputController (touch mode), UI/Kit/StudUI.

	Example:
		local play = Components.button({
			text = "PLAY", color = Theme.Colors.Primary, size = UDim2.fromOffset(320, 72),
			onActivated = function() ScreenManager.close("ComingSoon") end,
		})
		play.Parent = menuFrame
]]

local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")

local Create = require(script.Parent.Create)
local InputController = require(script.Parent.Parent.Controllers.InputController)
local Theme = require(script.Parent.Theme)

local Components = {}

-- CollectionService tag on every Components.button (a sound controller can hook every button).
Components.ButtonTag = "SellNukesButton"

--[[
	UICorner decorator (rendered radius; default Theme.Corner).
	Example: Components.corner(UDim.new(0, 6))
]]
function Components.corner(radius: UDim?): UICorner
	return Create.new("UICorner", { CornerRadius = radius or Theme.Corner }) :: UICorner
end

--[[
	UIStroke decorator. Border mode outlines the frame; Contextual mode outlines text.
	Example: Components.stroke(Theme.Colors.Edge, 4)
]]
function Components.stroke(color: Color3?, thickness: number?, mode: Enum.ApplyStrokeMode?): UIStroke
	return Create.new("UIStroke", {
		Color = color or Theme.Colors.Stroke,
		Thickness = thickness or Theme.StrokeThickness,
		ApplyStrokeMode = mode or Enum.ApplyStrokeMode.Border,
		LineJoinMode = Enum.LineJoinMode.Round,
	}) :: UIStroke
end

--[[ Uniform UIPadding of `pixels` on every side. ]]
function Components.padding(pixels: number): UIPadding
	local p = UDim.new(0, pixels)
	return Create.new(
			"UIPadding",
			{ PaddingTop = p, PaddingBottom = p, PaddingLeft = p, PaddingRight = p }
		) :: UIPadding
end

--[[
	Vertical (default) or horizontal list layout, centred, sorted by LayoutOrder.
	Example: Components.listLayout(12, true).Parent = row
]]
function Components.listLayout(padding: number, horizontal: boolean?, align: Enum.HorizontalAlignment?): UIListLayout
	return Create.new("UIListLayout", {
		Padding = UDim.new(0, padding),
		FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical,
		HorizontalAlignment = align or Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
	}) :: UIListLayout
end

--[[
	Grid layout with fixed cell size and padding, sorted by LayoutOrder.
	Example: Components.gridLayout(UDim2.fromOffset(200, 220), 12).Parent = grid
]]
function Components.gridLayout(cellSize: UDim2, padding: number): UIGridLayout
	return Create.new("UIGridLayout", {
		CellSize = cellSize,
		CellPadding = UDim2.fromOffset(padding, padding),
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Top,
		SortOrder = Enum.SortOrder.LayoutOrder,
	}) :: UIGridLayout
end

export type LabelOptions = {
	text: string,
	size: UDim2?,
	position: UDim2?,
	anchor: Vector2?,
	textSize: number?,
	display: boolean?, -- Luckiest Guy (numbers / shouty) vs Fredoka One
	color: Color3?,
	outline: boolean?, -- dark text outline (default on: readable over the game world)
	outlineThickness: number?,
	align: Enum.TextXAlignment?,
	layoutOrder: number?,
	wrap: boolean?,
	rich: boolean?,
}

--[[
	A styled, transparent TextLabel with an optional dark Contextual outline.
	Example: Components.label({ text = "Daily Rewards", textSize = 60 })
]]
function Components.label(options: LabelOptions): TextLabel
	local label = Create.new("TextLabel", {
		BackgroundTransparency = 1,
		Size = options.size or UDim2.new(1, 0, 0, (options.textSize or Theme.TextSize.Body) + 8),
		Position = options.position or UDim2.new(),
		AnchorPoint = options.anchor or Vector2.zero,
		Text = options.text,
		TextSize = options.textSize or Theme.TextSize.Body,
		FontFace = if options.display then Theme.Fonts.Display else Theme.Fonts.Body,
		TextColor3 = options.color or Theme.Colors.Text,
		TextXAlignment = options.align or Enum.TextXAlignment.Center,
		TextWrapped = options.wrap == true,
		LayoutOrder = options.layoutOrder or 0,
		RichText = options.rich == true,
	}) :: TextLabel
	if options.outline ~= false then
		local stroke =
			Components.stroke(Theme.Colors.Stroke, options.outlineThickness or 2.5, Enum.ApplyStrokeMode.Contextual)
		stroke.Name = "TextOutline"
		stroke.Parent = label
	end
	return label
end

export type PanelOptions = {
	size: UDim2,
	position: UDim2?,
	anchor: Vector2?,
	color: Color3?,
	transparency: number?,
	name: string?,
}

--[[ A rounded slate panel with a dark border. ]]
function Components.panel(options: PanelOptions): Frame
	return Create.new("Frame", {
		Name = options.name or "Panel",
		Size = options.size,
		Position = options.position or UDim2.new(),
		AnchorPoint = options.anchor or Vector2.zero,
		BackgroundColor3 = options.color or Theme.Colors.Panel,
		BackgroundTransparency = options.transparency or 0,
		Children = { Components.corner(), Components.stroke(Theme.Colors.Edge, Theme.StrokeThickness) },
	}) :: Frame
end

export type ButtonOptions = {
	text: string,
	size: UDim2?,
	position: UDim2?,
	anchor: Vector2?,
	color: Color3?,
	darkColor: Color3?, -- the "3D" lip under the button
	textColor: Color3?,
	textSize: number?,
	layoutOrder: number?,
	name: string?,
	lipDepth: number?, -- design px the lip pokes out below the face (default 5)
	onActivated: (() -> ())?,
}

-- Darkens a colour for the button lip when no darkColor is supplied.
local function darken(color: Color3, amount: number): Color3
	return Color3.new(color.R * (1 - amount), color.G * (1 - amount), color.B * (1 - amount))
end

-- Default lip depth (design px).
local LIP_DEPTH = 5
-- Disabled look applied by Components.setButtonDimmed.
local DIMMED_FACE_TRANSPARENCY = 0.55
local DIMMED_TEXT_TRANSPARENCY = 0.5
-- Hover / selection grow and press squash (UIScale).
local HOVER_SCALE = 1.05
local PRESS_SCALE = 0.93

-- Root TextButton properties copied onto the visible Face label (see Components.button). Typed
-- copy functions instead of dynamic `face[name] = root[name]` so strict mode checks every one.
type Mirror = (from: TextButton, to: TextLabel) -> ()
local MIRRORS: { [string]: Mirror } = {
	Text = function(from, to)
		to.Text = from.Text
	end,
	TextColor3 = function(from, to)
		to.TextColor3 = from.TextColor3
	end,
	TextSize = function(from, to)
		to.TextSize = from.TextSize
	end,
	FontFace = function(from, to)
		to.FontFace = from.FontFace
	end,
	TextWrapped = function(from, to)
		to.TextWrapped = from.TextWrapped
	end,
	TextScaled = function(from, to)
		to.TextScaled = from.TextScaled
	end,
	RichText = function(from, to)
		to.RichText = from.RichText
	end,
	BackgroundColor3 = function(from, to)
		to.BackgroundColor3 = from.BackgroundColor3
	end,
}

--[[
	A chunky 3D button. Returns the TextButton itself, so GuiService selection, Activated,
	layouts and ordinary property writes (Text, TextColor3, BackgroundColor3, Visible, ...) work
	like on any TextButton. Grows while hovered / gamepad-selected, squashes while pressed.

	Why the face is a child: every ScreenGui uses ZIndexBehavior.Sibling, where a child ALWAYS
	draws on top of its parent. A darker "lip" child could never sit behind the button's own
	background / text, so the root draws nothing and two children draw, in sibling order:

		TextButton (root)        hit area, gamepad selection target, UIScale bounce; its own
		│                        background and text are fully transparent
		├─ Lip  (Frame, Z 1)     darker copy of the face, `lipDepth` px lower = the 3D edge
		└─ Face (TextLabel, Z 2) the visible face + text + selection outline

	Writes to the root's text properties and BackgroundColor3 (MIRRORS) are copied to the Face as
	they happen (event-driven, no per-frame work). Use Components.setButtonDimmed for a disabled
	look (never write the root's BackgroundTransparency / TextTransparency).

	Example:
		local back = Components.button({ text = "BACK", onActivated = close })
		back.Text = "CLOSE"  -- the face updates immediately
]]
function Components.button(options: ButtonOptions): TextButton
	local color = options.color or Theme.Colors.Primary
	local size = options.size or UDim2.fromOffset(280, 64)
	local depth = options.lipDepth or LIP_DEPTH
	local scale = Create.new("UIScale", { Name = "PressScale", Scale = 1 }) :: UIScale
	local selectionStroke = Create.new("UIStroke", {
		Name = "SelectionRing",
		Color = Theme.Colors.Selection,
		Thickness = 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}) :: UIStroke

	local button = Create.new("TextButton", {
		Name = options.name or options.text,
		Size = size,
		Position = options.position or UDim2.new(),
		AnchorPoint = options.anchor or Vector2.zero,
		-- The root is the property source of truth but never renders (see header).
		BackgroundColor3 = color,
		BackgroundTransparency = 1,
		TextTransparency = 1,
		AutoButtonColor = false,
		Text = options.text,
		TextSize = options.textSize or Theme.TextSize.Large,
		FontFace = Theme.Fonts.Body,
		TextColor3 = options.textColor or Theme.Colors.Text,
		LayoutOrder = options.layoutOrder or 0,
		Selectable = true,
		-- An invisible selection image: the SelectionRing stroke is the gamepad highlight.
		SelectionImageObject = Create.new("Frame", { BackgroundTransparency = 1 }),
		Children = { scale },
	}) :: TextButton

	-- The 3D lip: a darker copy offset downward. First sibling = drawn first = behind the face.
	Create.new("Frame", {
		Name = "Lip",
		ZIndex = 1,
		BackgroundColor3 = options.darkColor or darken(color, 0.3),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromOffset(0, depth),
		Active = false,
		Parent = button,
		Children = { Components.corner() },
	})
	-- The visible face: background + label, drawn above the lip.
	local face = Create.new("TextLabel", {
		Name = "Face",
		ZIndex = 2,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Active = false, -- input goes to the root TextButton
		Parent = button,
		Children = { Components.corner(), selectionStroke },
	}) :: TextLabel
	-- Copy the root's current values now, then keep the face in sync with every later write.
	for property, mirror in MIRRORS do
		mirror(button, face)
		button:GetPropertyChangedSignal(property):Connect(function()
			mirror(button, face)
		end)
	end

	local hovered = false
	local selected = false
	local pressed = false
	local function refresh()
		local target = if pressed then PRESS_SCALE elseif hovered or selected then HOVER_SCALE else 1
		TweenService:Create(scale, if pressed then Theme.Tween.Fast else Theme.Tween.Bounce, { Scale = target }):Play()
		selectionStroke.Thickness = if selected then 4 else 0
	end
	button.MouseEnter:Connect(function()
		hovered = true
		refresh()
	end)
	button.MouseLeave:Connect(function()
		hovered = false
		pressed = false
		refresh()
	end)
	button.SelectionGained:Connect(function()
		selected = true
		refresh()
	end)
	button.SelectionLost:Connect(function()
		selected = false
		refresh()
	end)
	button.MouseButton1Down:Connect(function()
		pressed = true
		refresh()
	end)
	button.MouseButton1Up:Connect(function()
		pressed = false
		refresh()
	end)
	-- Tagged so a sound controller can give every button hover / click sounds without coupling.
	CollectionService:AddTag(button, Components.ButtonTag)
	local onActivated = options.onActivated
	if onActivated ~= nil then
		button.Activated:Connect(function()
			onActivated()
		end)
	end
	return button
end

--[[
	Gives a Components.button its disabled look (or restores it): the face and lip fade and the
	label dims. Purely visual: the caller still decides whether activation does anything.
	Example: Components.setButtonDimmed(saveButton, not canSave)
]]
function Components.setButtonDimmed(button: TextButton, dimmed: boolean)
	local face = button:FindFirstChild("Face")
	if face ~= nil and face:IsA("TextLabel") then
		face.BackgroundTransparency = if dimmed then DIMMED_FACE_TRANSPARENCY else 0
		face.TextTransparency = if dimmed then DIMMED_TEXT_TRANSPARENCY else 0
	end
	local lip = button:FindFirstChild("Lip")
	if lip ~= nil and lip:IsA("Frame") then
		lip.BackgroundTransparency = if dimmed then DIMMED_FACE_TRANSPARENCY else 0
	end
end

-- ── Touch mode ──────────────────────────────────────────────────────────────────────────────

-- Every object registered with hideInTouch -> the visibility its owner WANTS (the screen may
-- toggle it while touch keeps it hidden). STRONG keys removed on Destroying (weak Instance keys
-- can silently drop live entries).
local touchHidden: { [GuiObject]: boolean } = {}
local touchHideConnected = false
-- True while this module itself writes Visible (so the Visible listener ignores the write).
local writing = false

-- Applies the current input mode to every registered key-only hint.
local function applyTouchHidden()
	local touch = InputController.mode == "Touch"
	writing = true
	for object, wanted in touchHidden do
		object.Visible = wanted and not touch
	end
	writing = false
end

--[[
	Hides `object` while the player uses touch (a key-cap hint such as "[E] Upgrade" means
	nothing to a finger) and restores the visibility its owner wants when they switch back.
	The owner may keep writing `object.Visible`; the write is remembered and re-applied.
	Example: Components.hideInTouch(keyHintRow)
]]
function Components.hideInTouch(object: GuiObject)
	if touchHidden[object] ~= nil then
		return
	end
	touchHidden[object] = object.Visible
	local visibleChanged = object:GetPropertyChangedSignal("Visible"):Connect(function()
		if writing then
			return
		end
		touchHidden[object] = object.Visible
		if object.Visible and InputController.mode == "Touch" then
			writing = true
			object.Visible = false
			writing = false
		end
	end)
	object.Destroying:Once(function()
		visibleChanged:Disconnect()
		touchHidden[object] = nil
	end)
	if not touchHideConnected then
		touchHideConnected = true
		InputController.ModeChanged:Connect(applyTouchHidden)
	end
	if InputController.mode == "Touch" then
		writing = true
		object.Visible = false
		writing = false
	end
end

return table.freeze(Components)
