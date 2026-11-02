--!strict
--[[
	AdminWidgets — the small stud-style building blocks every admin panel page shares (labels,
	chips, dark scroll wells, wrap rows, the touch tap floor, formatting and amount parsing).

	Why one module: the Players / Economy / Server / World / New Player / Live / Log pages and the
	schema-driven CommandForm all need the same chip, well and label look, the same 44 pt touch
	floor (owner rule R11) and the same number / time formatting, so they are defined once here
	instead of being re-implemented per page.

	Pieces:
		AdminWidgets.label(options)        outlined left-aligned label that truncates / wraps
		AdminWidgets.chip(options)         light stud chip button (selectable, gamepad ring,
		                                   double-tap guard, selected / enabled states)
		AdminWidgets.well(name, parent)    dark outlined vertical ScrollingFrame with a list layout
		AdminWidgets.column(name, parent)  transparent auto-height frame with a vertical list
		AdminWidgets.wrapRow(name, parent) transparent auto-height frame whose children wrap
		AdminWidgets.tapFloor(fit)         minimum design px of a tap target (0 off touch)
		AdminWidgets.sized(gui, w, h, fit) size a control to max(authored, tap floor), kept up to
		                                   date on ScreenManager.LayoutChanged (one connection)
		AdminWidgets.format*(...)          money / gems / count / seconds / hour / ban length / clock
		AdminWidgets.parseAmount(text)     "1.5M" / "2b" / "1e12" / "12,000" → number (client
		                                   convenience only; the server re-validates every value)

	Performance: chips are a few Instances each (stud surface, edge, label); `sized` keeps ONE
	LayoutChanged connection for every tracked control and forgets destroyed ones (Destroying).
	Nothing here runs per frame.

	Security: presentational only. Parsed amounts are INTENTS sent to the server, which validates
	type, range and finiteness again (Server/Admin/AdminValidate).

	Connects to: Kit/StudUI (text), Widgets/StudWindow (surface, edge), UI/ScreenManager
	(touchTargets, pointScale, LayoutChanged), Shared/Util/{TouchLayout, NumberFormat},
	Shared/Config/{TouchUIConfig, UIStyleConfig, AdminConfig}. Used by every Screens/Admin page.

	Example:
		local chip = AdminWidgets.chip({ text = "1K", color = "green", width = 120, height = 48,
			parent = row, onActivated = function() setAmount(1000) end })
		chip.setSelected(true)
		print(AdminWidgets.parseAmount("1.5M")) --> 1500000
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AdminConfig = require(ReplicatedStorage.Shared.Config.AdminConfig)
local Create = require(script.Parent.Parent.Parent.Create)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local ScreenManager = require(script.Parent.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Parent.Widgets.StudWindow)
local TouchLayout = require(ReplicatedStorage.Shared.Util.TouchLayout)
local TouchUIConfig = require(ReplicatedStorage.Shared.Config.TouchUIConfig)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

type ColorName = UIStyleConfig.ColorName

-- ── Shared page contract (AdminPanelScreen ↔ every tab page) ─────────────────────────────────

-- One request for the panel's IN-PANEL confirm layer (destructive / important commands).
export type ConfirmRequest = {
	title: string,
	message: string,
	confirmText: string,
	color: ColorName, -- confirm button colour ("red" for destructive commands, else "green")
	onConfirm: () -> (),
}
export type Ask = (request: ConfirmRequest) -> ()

-- What the panel hands every page constructor (`Tab.new(options)`).
export type PageOptions = {
	parent: GuiObject,
	width: number, -- page area in design px
	height: number,
	setStatus: (text: string, ok: boolean?) -> (), -- panel status line (true ok / false error / nil neutral)
	isActive: () -> boolean, -- true while this page is the visible tab of an open panel
	refresh: () -> (), -- ask the panel to re-render this page now
	fitScale: () -> number, -- the window's current ModalShell fit (touch floor)
	ask: Ask, -- the in-panel confirm layer
	tab: string?, -- ActionsTab: which AdminConfig tab it renders
}

-- What every page constructor returns.
export type Page = {
	frame: Frame,
	render: () -> (), -- cheap when nothing changed (called on every AdminState push)
	first: () -> GuiObject?, -- default gamepad selection inside the page
	topRow: () -> { GuiObject }, -- controls whose NextSelectionUp is the tab bar
}

local AdminWidgets = {}

local Neutral = UIStyleConfig.Neutral
local Style = UIStyleConfig

-- Seconds during which a second activation of the same chip is ignored (one tap = one intent).
local ACTIVATE_DEBOUNCE = 0.25

-- ── Text ─────────────────────────────────────────────────────────────────────────────────────

export type LabelOptions = {
	text: string,
	size: UDim2,
	textSize: number,
	color: Color3?,
	font: StudUI.FontRole?,
	align: Enum.TextXAlignment?,
	wrap: boolean?,
	rich: boolean?,
	layoutOrder: number?,
	parent: Instance?,
	name: string?,
}

--[[
	An outlined label (body font, left-aligned by default) that truncates instead of overflowing
	unless `wrap` is set.
	@return TextLabel
	Example: AdminWidgets.label({ text = "Cash", size = UDim2.new(1, 0, 0, 30), textSize = 24, parent = card })
]]
function AdminWidgets.label(options: LabelOptions): TextLabel
	local made = StudUI.text({
		name = options.name,
		text = options.text,
		size = options.size,
		textSize = options.textSize,
		color = options.color,
		font = options.font or "body",
		align = options.align or Enum.TextXAlignment.Left,
		wrap = options.wrap,
		rich = options.rich,
		layoutOrder = options.layoutOrder,
		parent = options.parent,
	})
	if options.wrap ~= true then
		made.TextTruncate = Enum.TextTruncate.AtEnd
	end
	return made
end

-- ── Touch floor ──────────────────────────────────────────────────────────────────────────────

--[[
	The minimum design-px side of a tap target right now: TouchUIConfig.MinTapPoints (44 pt) at
	the current UI scale × the panel's fit, or 0 when targets are not finger-sized (desktop /
	gamepad). `fit` is the window's ModalShell scale (1 when unknown).
	Example: local h = math.max(48, AdminWidgets.tapFloor(shell.scale()))
]]
function AdminWidgets.tapFloor(fit: number?): number
	if not ScreenManager.touchTargets() then
		return 0
	end
	local scale = ScreenManager.pointScale() * math.max(fit or 1, 0.05)
	return TouchLayout.pointsToDesign(TouchUIConfig.MinTapPoints, scale)
end

-- Controls sized through `sized`: authored size + the fit getter. Strong keys, cleaned on
-- Destroying (a weak table would drop live entries; see RoBeasts' ForgetOnDestroy note).
type Tracked = { width: number, height: number, fit: () -> number, widthIsScale: boolean }
local tracked: { [GuiObject]: Tracked } = {}
local layoutConnected = false

-- Applies max(authored, floor) to one tracked control.
local function applySize(gui: GuiObject, entry: Tracked)
	local floor = AdminWidgets.tapFloor(entry.fit())
	local height = math.max(entry.height, floor)
	if entry.widthIsScale then
		gui.Size = UDim2.new(entry.width, 0, 0, height)
	else
		gui.Size = UDim2.fromOffset(math.max(entry.width, floor), height)
	end
end

--[[
	Sizes `gui` to its authored size raised to the touch tap floor, and keeps it right when the
	device / scale changes (one shared LayoutChanged connection). `width` ≤ 1 with
	`widthIsScale` = true means a scale width (e.g. 1 = full row) with an offset height.
	@param gui      the control (button / row)
	@param width    authored width in design px (or a 0..1 scale with widthIsScale)
	@param height   authored height in design px
	@param fit      returns the panel's current ModalShell fit (nil = 1)
	Example: AdminWidgets.sized(row, 1, 64, shell.scale, true)
]]
function AdminWidgets.sized(gui: GuiObject, width: number, height: number, fit: (() -> number)?, widthIsScale: boolean?)
	local entry: Tracked = {
		width = width,
		height = height,
		fit = fit or function(): number
			return 1
		end,
		widthIsScale = widthIsScale == true,
	}
	tracked[gui] = entry
	applySize(gui, entry)
	gui.Destroying:Connect(function()
		tracked[gui] = nil
	end)
	if not layoutConnected then
		layoutConnected = true
		ScreenManager.LayoutChanged:Connect(function()
			for control, item in tracked do
				applySize(control, item)
			end
		end)
	end
end

--[[ Re-applies every tracked size now (a panel calls it after its fit changed). ]]
function AdminWidgets.refit()
	for control, item in tracked do
		applySize(control, item)
	end
end

-- ── Chips ────────────────────────────────────────────────────────────────────────────────────

export type ChipOptions = {
	text: string,
	color: ColorName?, -- face colour when selected (or always, when `solid`)
	solid: boolean?, -- always painted `color` (action chips); else grey until selected
	width: number?, -- design px (default 140)
	height: number?, -- design px (default 48)
	textSize: number?,
	fit: (() -> number)?, -- panel fit for the touch floor
	layoutOrder: number?,
	name: string?,
	parent: Instance?,
	onActivated: (() -> ())?,
}

export type Chip = {
	button: TextButton,
	label: TextLabel,
	setText: (text: string) -> (),
	setSelected: (selected: boolean) -> (),
	setEnabled: (enabled: boolean) -> (),
	setColor: (color: ColorName) -> (),
	setCallback: (callback: (() -> ())?) -> (),
	isEnabled: () -> boolean,
}

--[[
	A light stud chip: stud face (grey, or `color` while selected / solid), dark outline that
	turns into the white gamepad ring while selected, centred label. Disabled chips are dimmed,
	skipped by gamepad navigation and ignore activation.
	@return Chip handle
	Example: AdminWidgets.chip({ text = "1 day", color = "red", parent = row, onActivated = pick })
]]
function AdminWidgets.chip(options: ChipOptions): Chip
	local width = options.width or 140
	local height = options.height or 48
	local color: ColorName = options.color or "blue"
	local solid = options.solid == true
	local selected = false
	local enabled = true
	local callback = options.onActivated
	local button = Create.new("TextButton", {
		Name = options.name or `Chip_{options.text}`,
		AutoButtonColor = false,
		Text = "",
		LayoutOrder = options.layoutOrder or 0,
		Selectable = true,
		-- Our outline is the gamepad highlight; the engine's selection image stays invisible.
		SelectionImageObject = Create.new("Frame", { BackgroundTransparency = 1 }),
	}) :: TextButton
	AdminWidgets.sized(button, width, height, options.fit)
	local surface = StudWindow.surface(button, if solid then color else "grey", {
		tile = Style.StudTile.Button,
		studTransparency = Style.StudTransparency.Button,
		corner = 8,
	})
	local edge = StudWindow.edge(button, 3)
	local label = AdminWidgets.label({
		name = "Label",
		text = options.text,
		size = UDim2.new(1, -12, 1, 0),
		textSize = options.textSize or math.min(24, math.floor(height * 0.5)),
		align = Enum.TextXAlignment.Center,
		parent = button,
	})
	label.Position = UDim2.fromOffset(6, 0)
	label.ZIndex = 3
	label.TextScaled = true
	Create.new("UITextSizeConstraint", {
		MaxTextSize = options.textSize or math.min(24, math.floor(height * 0.5)),
		MinTextSize = 10,
		Parent = label,
	})

	-- Single writer of the chip visuals.
	local function render()
		surface.setColor(if solid or selected then color else "grey")
		button.BackgroundTransparency = if enabled then 0 else 0.5
		label.TextTransparency = if enabled then 0 else 0.45
	end
	button.SelectionGained:Connect(function()
		edge.Color = Neutral.Text
		edge.Thickness = 4
	end)
	button.SelectionLost:Connect(function()
		edge.Color = Neutral.Edge
		edge.Thickness = 3
	end)
	local last = -math.huge
	button.Activated:Connect(function()
		local now = os.clock()
		if not enabled or now - last < ACTIVATE_DEBOUNCE then
			return
		end
		last = now
		local fn = callback
		if fn ~= nil then
			local ok, err = pcall(fn)
			if not ok then
				warn(`[AdminWidgets] chip callback error: {err}`)
			end
		end
	end)
	render()
	if options.parent ~= nil then
		button.Parent = options.parent
	end
	return {
		button = button,
		label = label,
		setText = function(text: string)
			label.Text = text
		end,
		setSelected = function(on: boolean)
			if selected ~= on then
				selected = on
				render()
			end
		end,
		setEnabled = function(on: boolean)
			if enabled ~= on then
				enabled = on
				button.Selectable = on
				render()
			end
		end,
		setColor = function(name: ColorName)
			color = name
			render()
		end,
		setCallback = function(fn: (() -> ())?)
			callback = fn
		end,
		isEnabled = function(): boolean
			return enabled
		end,
	}
end

-- ── Containers ───────────────────────────────────────────────────────────────────────────────

--[[
	A dark outlined vertical ScrollingFrame with padding and a vertical UIListLayout
	(AutomaticCanvasSize Y). Gamepad selection scrolls it automatically.
	@return ScrollingFrame
	Example: local list = AdminWidgets.well("Players", page)
]]
function AdminWidgets.well(name: string, parent: Instance?, padding: number?): ScrollingFrame
	local gap = padding or 8
	local scroller = Create.new("ScrollingFrame", {
		Name = name,
		BackgroundColor3 = Neutral.Well,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 10,
		ScrollBarImageColor3 = Neutral.Text,
		ScrollBarImageTransparency = 0.4,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ElasticBehavior = Enum.ElasticBehavior.WhenScrollable,
		Selectable = false,
		Children = {
			Create.new("UICorner", { CornerRadius = UDim.new(0, 8) }),
			Create.new("UIPadding", {
				PaddingTop = UDim.new(0, 10),
				PaddingBottom = UDim.new(0, 14),
				PaddingLeft = UDim.new(0, 10),
				PaddingRight = UDim.new(0, 18),
			}),
			Create.new("UIListLayout", { Padding = UDim.new(0, gap), SortOrder = Enum.SortOrder.LayoutOrder }),
		},
	}) :: ScrollingFrame
	StudWindow.edge(scroller, 3)
	if parent ~= nil then
		scroller.Parent = parent
	end
	return scroller
end

--[[
	A transparent full-width frame whose height follows its children (vertical list).
	@return Frame
]]
function AdminWidgets.column(name: string, parent: Instance?, padding: number?, layoutOrder: number?): Frame
	local frame = Create.new("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = layoutOrder or 0,
		Children = {
			Create.new("UIListLayout", {
				Padding = UDim.new(0, padding or 8),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		},
	}) :: Frame
	if parent ~= nil then
		frame.Parent = parent
	end
	return frame
end

--[[
	A transparent full-width frame whose children flow left → right and wrap onto new lines; its
	height follows the content (chip rows, compact command buttons).
	@return Frame
]]
function AdminWidgets.wrapRow(name: string, parent: Instance?, gap: number?, layoutOrder: number?): Frame
	local spacing = gap or 10
	local frame = Create.new("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = layoutOrder or 0,
		Children = {
			Create.new("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				Wraps = true,
				Padding = UDim.new(0, spacing),
				SortOrder = Enum.SortOrder.LayoutOrder,
				VerticalAlignment = Enum.VerticalAlignment.Center,
			}),
			-- Room under each wrapped line for the stud buttons' 3D lip.
			Create.new("UIPadding", { PaddingBottom = UDim.new(0, 6), PaddingTop = UDim.new(0, 4) }),
		},
	}) :: Frame
	if parent ~= nil then
		frame.Parent = parent
	end
	return frame
end

--[[
	A dark rounded panel (card body) with an outline and padding; height follows its children
	(vertical list). Used for command forms and info blocks inside wells.
	@return Frame
]]
function AdminWidgets.panel(name: string, parent: Instance?, layoutOrder: number?): Frame
	local frame = Create.new("Frame", {
		Name = name,
		BackgroundColor3 = Neutral.Body,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = layoutOrder or 0,
		Children = {
			Create.new("UICorner", { CornerRadius = UDim.new(0, 8) }),
			Create.new("UIPadding", {
				PaddingTop = UDim.new(0, 10),
				PaddingBottom = UDim.new(0, 12),
				PaddingLeft = UDim.new(0, 12),
				PaddingRight = UDim.new(0, 12),
			}),
			Create.new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
		},
	}) :: Frame
	StudWindow.edge(frame, 2)
	if parent ~= nil then
		frame.Parent = parent
	end
	return frame
end

-- ── Formatting ───────────────────────────────────────────────────────────────────────────────

--[[ "1h 02m" style duration (NumberFormat.duration). ]]
function AdminWidgets.formatSeconds(seconds: number): string
	return NumberFormat.duration(seconds)
end

--[[ "4:05" / "1:02:03" clock-style countdown text. ]]
function AdminWidgets.formatClock(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	local hours, minutes, secs = s // 3600, (s % 3600) // 60, s % 60
	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, minutes, secs)
	end
	return string.format("%d:%02d", minutes, secs)
end

--[[ A clock hour 0..24 as "14:30". ]]
function AdminWidgets.formatHour(hour: number): string
	local total = math.floor(math.clamp(hour, 0, 24) * 60 + 0.5)
	return string.format("%02d:%02d", (total // 60) % 25, total % 60)
end

--[[ "HH:MM:SS UTC" for a unix time (audit log rows). ]]
function AdminWidgets.formatUtc(unix: number): string
	-- (os.date's bundled type only knows the "*t" table form; the string form is standard Luau.)
	local ok, text = pcall(os.date :: any, "!%H:%M:%S", math.floor(unix))
	return if ok and type(text) == "string" then text else "--:--:--"
end

--[[ A ban length for display ("1 day", "Permanent", or a duration). ]]
function AdminWidgets.formatBanLength(seconds: number): string
	for _, option in AdminConfig.BanDurations do
		if option.seconds == seconds then
			return option.label
		end
	end
	if seconds < 0 then
		return "Permanent"
	end
	return NumberFormat.duration(seconds)
end

--[[
	Formats an argument value for chips, summaries and the confirm dialog, following the arg's
	`format` hint ("money" | "gems" | "count" | "minutes" | "seconds" | "hour").
	Example: AdminWidgets.formatValue(1500000, "money") --> "$1.5M"
]]
function AdminWidgets.formatValue(value: unknown, format: string?): string
	if type(value) == "number" then
		if format == "money" then
			return NumberFormat.money(value)
		elseif format == "gems" then
			return NumberFormat.short(value) .. " gems"
		elseif format == "minutes" then
			return if value == 1 then "1 min" else `{NumberFormat.commas(value)} min`
		elseif format == "seconds" then
			return AdminWidgets.formatBanLength(value)
		elseif format == "hour" then
			return AdminWidgets.formatHour(value)
		elseif format == "count" then
			return NumberFormat.commas(value)
		end
		return if value == math.floor(value) and math.abs(value) < 1e15
			then NumberFormat.commas(value)
			else NumberFormat.short(value)
	elseif type(value) == "boolean" then
		return if value then "ON" else "OFF"
	elseif type(value) == "string" then
		return if value == "" then "(empty)" else value
	end
	return "-"
end

-- ── Amount parsing ───────────────────────────────────────────────────────────────────────────

-- Lower-case NumberFormat suffix → power of ten ("k" → 3, "m" → 6, "qa" → 15, ...).
local SUFFIX_POWER: { [string]: number } = {}
for tier, suffix in NumberFormat.Suffixes do
	local key = string.lower(suffix)
	if SUFFIX_POWER[key] == nil then
		SUFFIX_POWER[key] = tier * 3
	end
end

--[[
	Parses an admin-typed amount: plain numbers, thousands separators, scientific notation and
	NumberFormat suffixes (case-insensitive). Returns nil for anything else / non-finite.
	Client convenience only — the server re-validates every value it receives.
	Example: parseAmount("1.5M") --> 1500000 ; parseAmount("2 qa") --> 2e15 ; parseAmount("x") --> nil
]]
function AdminWidgets.parseAmount(text: string): number?
	if #text > 64 then
		return nil
	end
	local cleaned = string.gsub(string.gsub(text, ",", ""), "%$", "")
	cleaned = string.match(cleaned, "^%s*(.-)%s*$") or ""
	if cleaned == "" then
		return nil
	end
	local direct = tonumber(cleaned)
	if direct == nil then
		local digits, suffix = string.match(cleaned, "^([%d%.]+)%s*(%a+)$")
		if digits == nil or suffix == nil then
			return nil
		end
		local base = tonumber(digits)
		local power = SUFFIX_POWER[string.lower(suffix)]
		if base == nil or power == nil then
			return nil
		end
		direct = base * 10 ^ power
	end
	local value = direct :: number
	if value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	return value
end

return AdminWidgets
