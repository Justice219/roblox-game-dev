--!strict
--[[
	CommandForm — builds the controls for ONE admin command from its server-sent schema
	(AdminConfig.CommandInfo: label, description, target, args, argOrder, confirm, color) and
	sends it as an intent. Every tab of the admin panel renders its commands through this module,
	so a command another system registers at runtime (pets, attack, event —
	AdminService.registerCommand) appears with working controls without any panel change.

	Controls per argument kind (AdminConfig.ArgSpec + panel hints label / presets / format /
	default):
		integer / number  value well (tap / select to type: "1.5M", "2B", "1e12", "12,000" are
		                  parsed client-side), ÷10 / ×10 steps for money / gems, −/+ steps
		                  otherwise (±0.5 h for a time of day), preset chips formatted per `format`
		banDuration       chips from AdminConfig.BanDurations (Permanent only if allowed)
		enum              chips with the display labels (a scrolling chip box past 12 values)
		text / code       StudUI text box (maxLength; codes upper-cased, letters / digits only)
		                  + optional preset chips (`textPresets`; "reason" args get
		                  AdminConfig.ReasonPresets automatically)
		boolean           ON / OFF toggle chip
	The run button uses the command's colour. It is greyed with the reason while the command is
	unusable (AdminClient.unavailable: "needs Tycoon (B5 TycoonAdmin)", "Studio only", ...) or
	while a Player / AnyUser target is missing ("pick a player"). Commands marked `confirm` ask
	through the panel's IN-PANEL confirm layer first (Options.ask) with a summary of target + args.
	A command without arguments renders COMPACT (just its button + reason), so pages can line
	several up in a wrap row.

	Security: the form only sends an INTENT (`AdminCommand(name, args)`); the server re-authorises
	the caller, re-validates every argument against the same schema (rejecting unknown / extra
	ones) and resolves the target itself. Client-side clamping only spares a pointless round trip.

	Performance: built once per command (pages rebuild forms only when the catalogue changes);
	`refresh` touches the run button only when its state changed. No per-frame work.

	Connects to: Screens/Admin/AdminClient (send, unavailable), Screens/Admin/AdminWidgets (chips,
	labels, sizing, formatting, parsing), Kit/StudUI (button, textBox), Shared/Config/AdminConfig
	(wire types, BanDurations, ReasonPresets). Used by PlayersTab and ActionsTab.

	Example:
		local form = CommandForm.new({
			info = AdminClient.command("GrantGems") :: any, parent = list, ask = panelConfirm,
			setStatus = setStatus, getTarget = function() return { userId = 123, label = "Bob" } end,
		})
		form.refresh() -- after every AdminState push
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AdminClient = require(script.Parent.AdminClient)
local AdminConfig = require(ReplicatedStorage.Shared.Config.AdminConfig)
local AdminWidgets = require(script.Parent.AdminWidgets)
local Create = require(script.Parent.Parent.Parent.Create)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

type ColorName = UIStyleConfig.ColorName
type CommandInfo = AdminConfig.CommandInfo
type ArgSpec = AdminConfig.ArgSpec

-- The panel's in-panel confirm hook (types live in AdminWidgets, shared by every page).
export type ConfirmRequest = AdminWidgets.ConfirmRequest
export type Ask = AdminWidgets.Ask

-- A resolved target: the user id to send and a label for the confirm summary.
export type Target = { userId: number, label: string }

export type Options = {
	info: CommandInfo,
	parent: Instance,
	ask: Ask,
	setStatus: (text: string, ok: boolean?) -> (),
	getTarget: (() -> Target?)?, -- required for Player / AnyUser commands
	textPresets: { [string]: { string } }?, -- arg key → preset texts (chips fill the box)
	fit: (() -> number)?, -- panel fit for the touch floor
	layoutOrder: number?,
	compactWidth: number?, -- width of a compact (argument-less) form (default 300)
}

export type Form = {
	frame: Frame,
	info: CommandInfo,
	compact: boolean,
	refresh: () -> (),
	first: () -> GuiObject?,
	setValue: (key: string, value: any) -> (),
	Destroy: () -> (),
}

local CommandForm = {}

local Neutral = UIStyleConfig.Neutral

-- Layout (design px at 1080p).
local FIELD_LABEL_SIZE = 22
local CHIP_HEIGHT = 46
local VALUE_WIDTH = 300
local STEP_WIDTH = 72
local RUN_HEIGHT = 56
local RUN_WIDTH = 300
local TEXT_HEIGHT = 58
-- Past this many enum values the chips live in a scrolling box of fixed height.
local ENUM_SCROLL_AFTER = 12
local ENUM_SCROLL_HEIGHT = 3 * (CHIP_HEIGHT + 10) + 16

-- Every colour preset name (validates the server-sent colour before using it).
local COLOR_NAMES: { [string]: boolean } = {}
for name in UIStyleConfig.Colors do
	COLOR_NAMES[name] = true
end
COLOR_NAMES.rainbow = true

-- The command's colour as a ColorName (unknown → "blue").
local function colorOf(info: CommandInfo): ColorName
	local name = info.color
	return if type(name) == "string" and COLOR_NAMES[name] then name :: ColorName else "blue"
end

-- A chip width that fits `text` (design px).
local function chipWidth(text: string): number
	return math.clamp(#text * 12 + 40, 84, 280)
end

-- The argument keys in display order (server argOrder, else sorted).
local function orderedKeys(info: CommandInfo): { string }
	local keys: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, key in info.argOrder or {} do
		if info.args[key] ~= nil and not seen[key] then
			seen[key] = true
			table.insert(keys, key)
		end
	end
	local rest: { string } = {}
	for key in info.args do
		if not seen[key] then
			table.insert(rest, key)
		end
	end
	table.sort(rest)
	for _, key in rest do
		table.insert(keys, key)
	end
	return keys
end

-- Clamps a numeric value into the spec (integers rounded to whole numbers).
local function clampValue(spec: ArgSpec, value: number): number
	local v = value
	if spec.kind == "integer" or spec.kind == "banDuration" then
		v = math.floor(v + 0.5)
	end
	if spec.min ~= nil then
		v = math.max(v, spec.min)
	end
	if spec.max ~= nil then
		v = math.min(v, spec.max)
	end
	return v
end

-- The starting value of an argument (default hint, first preset, the minimum, ...).
local function initialValue(spec: ArgSpec): any
	if spec.default ~= nil then
		return spec.default
	end
	local kind = spec.kind
	if kind == "integer" or kind == "number" then
		local presets = spec.presets
		if presets ~= nil and presets[1] ~= nil then
			return clampValue(spec, presets[1])
		end
		return clampValue(spec, math.max(spec.min or 0, if spec.nonZero then 1 else 0))
	elseif kind == "banDuration" then
		return AdminConfig.BanDurations[1].seconds
	elseif kind == "enum" then
		local values = spec.values
		return if values ~= nil and values[1] ~= nil then values[1] else ""
	elseif kind == "boolean" then
		return false
	end
	return ""
end

-- The display label of an enum value.
local function enumLabel(spec: ArgSpec, value: string): string
	local values, labels = spec.values, spec.labels
	if values ~= nil and labels ~= nil then
		local index = table.find(values, value)
		if index ~= nil and labels[index] ~= nil then
			return labels[index]
		end
	end
	return value
end

--[[
	Builds the form for one command (see the module header).
	@param options the command info, parent, confirm hook, status hook, target getter, ...
	@return Form { frame, info, compact, refresh, first, setValue, Destroy }
]]
function CommandForm.new(options: Options): Form
	local info = options.info
	local fit = options.fit
	local keys = orderedKeys(info)
	local compact = #keys == 0
	local color = colorOf(info)
	local values: { [string]: any } = {}
	-- Readers for text-like args (read at send time from their boxes).
	local textReaders: { [string]: () -> string } = {}
	-- Re-render hooks per arg (chip selection / value text after a change).
	local renderers: { [string]: () -> () } = {}
	local firstControl: GuiObject? = nil

	local function remember(control: GuiObject)
		if firstControl == nil then
			firstControl = control
		end
	end

	-- Root -----------------------------------------------------------------------------------------
	local frame: Frame
	if compact then
		frame = AdminWidgets.column(`Cmd_{info.name}`, nil, 4, options.layoutOrder)
		frame.Size = UDim2.fromOffset(options.compactWidth or RUN_WIDTH, 0)
	else
		frame = AdminWidgets.panel(`Cmd_{info.name}`, nil, options.layoutOrder)
		AdminWidgets.label({
			name = "Title",
			text = info.label,
			size = UDim2.new(1, 0, 0, 34),
			textSize = 28,
			font = "title",
			layoutOrder = 1,
			parent = frame,
		})
		if info.description ~= "" then
			AdminWidgets.label({
				name = "Description",
				text = info.description,
				size = UDim2.fromScale(1, 0),
				textSize = 18,
				color = Neutral.TextDim,
				wrap = true,
				layoutOrder = 2,
				parent = frame,
			}).AutomaticSize =
				Enum.AutomaticSize.Y
		end
	end

	-- Fields ---------------------------------------------------------------------------------------
	local function fieldLabel(spec: ArgSpec, key: string, parent: Instance, order: number)
		local text = spec.label or key
		if spec.optional then
			text ..= " (optional)"
		end
		AdminWidgets.label({
			name = "FieldLabel",
			text = text,
			size = UDim2.new(1, 0, 0, FIELD_LABEL_SIZE + 6),
			textSize = FIELD_LABEL_SIZE,
			color = Neutral.TextDim,
			layoutOrder = order,
			parent = parent,
		})
	end

	-- A numeric field: value well (typed entry) + steps + preset chips.
	local function numericField(key: string, spec: ArgSpec, holder: Frame)
		values[key] = initialValue(spec)
		local row = AdminWidgets.wrapRow("ValueRow", holder, 10, 2)
		local well = Create.new("TextBox", {
			Name = "Value",
			BackgroundColor3 = Neutral.Well,
			Text = "",
			PlaceholderText = "type e.g. 1.5M",
			PlaceholderColor3 = Neutral.Placeholder,
			TextColor3 = Neutral.CashGreen,
			TextSize = 26,
			FontFace = UIStyleConfig.Fonts.Number,
			ClearTextOnFocus = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Selectable = true,
			LayoutOrder = 1,
			Children = { Create.new("UICorner", { CornerRadius = UDim.new(0, 6) }) },
		}) :: TextBox
		AdminWidgets.sized(well, VALUE_WIDTH, CHIP_HEIGHT, fit)
		Create.new("UIStroke", {
			Name = "Edge",
			Color = Neutral.Edge,
			Thickness = 3,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Parent = well,
		})
		well.Parent = row
		remember(well)

		local presetChips: { { value: number, chip: AdminWidgets.Chip } } = {}
		local function render()
			local value = values[key]
			if not well:IsFocused() then
				well.Text = AdminWidgets.formatValue(value, spec.format)
			end
			for _, item in presetChips do
				item.chip.setSelected(item.value == value)
			end
		end
		renderers[key] = render

		local function set(value: number)
			values[key] = clampValue(spec, value)
			render()
		end
		well.Focused:Connect(function()
			local value = values[key]
			well.Text = if type(value) == "number" then tostring(value) else ""
		end)
		well.FocusLost:Connect(function()
			local parsed = AdminWidgets.parseAmount(well.Text)
			if parsed == nil then
				options.setStatus(`{spec.label or key}: not a number`, false)
			elseif spec.kind == "integer" and parsed ~= math.floor(parsed) then
				set(parsed) -- rounded by clampValue
				options.setStatus(`{spec.label or key}: rounded to a whole number`, false)
			else
				set(parsed)
			end
			render()
		end)

		-- Steps: ×10 / ÷10 for currencies, ±0.5 h for a time of day, ±1 otherwise.
		local multiplicative = spec.format == "money" or spec.format == "gems"
		local stepSize = if spec.format == "hour" then 0.5 else 1
		local downText = if multiplicative then "÷10" else "−"
		local upText = if multiplicative then "×10" else "+"
		AdminWidgets.chip({
			text = downText,
			color = "grey",
			solid = true,
			width = STEP_WIDTH,
			height = CHIP_HEIGHT,
			fit = fit,
			layoutOrder = 2,
			parent = row,
			onActivated = function()
				local value = values[key] :: number
				set(if multiplicative then value / 10 else value - stepSize)
			end,
		})
		AdminWidgets.chip({
			text = upText,
			color = "grey",
			solid = true,
			width = STEP_WIDTH,
			height = CHIP_HEIGHT,
			fit = fit,
			layoutOrder = 3,
			parent = row,
			onActivated = function()
				local value = values[key] :: number
				set(if multiplicative then math.max(value, 1) * 10 else value + stepSize)
			end,
		})
		local presets = spec.presets
		if presets ~= nil and #presets > 0 then
			local chips = AdminWidgets.wrapRow("Presets", holder, 8, 3)
			for index, preset in presets do
				local text = AdminWidgets.formatValue(preset, spec.format)
				local chip = AdminWidgets.chip({
					text = text,
					color = color,
					width = chipWidth(text),
					height = CHIP_HEIGHT,
					fit = fit,
					layoutOrder = index,
					parent = chips,
					onActivated = function()
						set(preset)
					end,
				})
				table.insert(presetChips, { value = clampValue(spec, preset), chip = chip })
			end
		end
		render()
	end

	-- A chip choice (enum / ban duration): one selected chip.
	local function choiceField(key: string, spec: ArgSpec, holder: Frame, choices: { { value: any, text: string } })
		values[key] = initialValue(spec)
		local container: Instance
		if #choices > ENUM_SCROLL_AFTER then
			local box = AdminWidgets.well("Choices", holder, 8)
			box.Size = UDim2.new(1, 0, 0, ENUM_SCROLL_HEIGHT)
			box.LayoutOrder = 2
			local layout = box:FindFirstChildOfClass("UIListLayout")
			if layout ~= nil then
				layout.FillDirection = Enum.FillDirection.Horizontal
				layout.Wraps = true
			end
			container = box
		else
			container = AdminWidgets.wrapRow("Choices", holder, 8, 2)
		end
		local chips: { { value: any, chip: AdminWidgets.Chip } } = {}
		local function render()
			for _, item in chips do
				item.chip.setSelected(item.value == values[key])
			end
		end
		renderers[key] = render
		for index, choice in choices do
			local chip = AdminWidgets.chip({
				text = choice.text,
				color = color,
				width = chipWidth(choice.text),
				height = CHIP_HEIGHT,
				fit = fit,
				layoutOrder = index,
				parent = container,
				onActivated = function()
					values[key] = choice.value
					render()
				end,
			})
			if index == 1 then
				remember(chip.button)
			end
			table.insert(chips, { value = choice.value, chip = chip })
		end
		render()
	end

	-- A text / code field: text box + optional preset chips.
	local function textField(key: string, spec: ArgSpec, holder: Frame)
		local isCode = spec.kind == "code"
		local maxLength = spec.maxLength or 200
		local box = StudUI.textBox({
			placeholder = if isCode then "LETTERS / NUMBERS" else (spec.label or key),
			maxLength = maxLength,
			textSize = 26,
			size = UDim2.new(1, 0, 0, TEXT_HEIGHT),
			layoutOrder = 2,
			parent = holder,
		})
		AdminWidgets.sized(box.frame, 1, TEXT_HEIGHT, fit, true)
		remember(box.instance)
		if isCode then
			-- Codes: upper-case letters and digits only (the server normalises the same way).
			box.instance:GetPropertyChangedSignal("Text"):Connect(function()
				local cleaned = string.upper((string.gsub(box.instance.Text, "[^%w]", "")))
				if cleaned ~= box.instance.Text then
					box.instance.Text = cleaned
				end
			end)
		end
		textReaders[key] = function(): string
			return string.match(box.instance.Text, "^%s*(.-)%s*$") or ""
		end
		renderers[key] = function()
			local value = values[key]
			if type(value) == "string" then
				box.instance.Text = value
			end
		end
		local presets = if options.textPresets ~= nil then options.textPresets[key] else nil
		if presets == nil and key == "reason" then
			presets = AdminConfig.ReasonPresets :: any
		end
		if presets ~= nil and #presets > 0 then
			local chips = AdminWidgets.wrapRow("TextPresets", holder, 8, 3)
			for index, preset in presets do
				local short = if #preset > 28 then string.sub(preset, 1, 26) .. "…" else preset
				AdminWidgets.chip({
					text = short,
					color = "grey",
					solid = true,
					width = chipWidth(short),
					height = CHIP_HEIGHT,
					fit = fit,
					layoutOrder = index,
					parent = chips,
					onActivated = function()
						box.instance.Text = string.sub(preset, 1, maxLength)
					end,
				})
			end
		end
	end

	-- A boolean toggle chip.
	local function booleanField(key: string, spec: ArgSpec, holder: Frame)
		values[key] = initialValue(spec) == true
		local chip: AdminWidgets.Chip
		local function render()
			chip.setText(if values[key] then "ON" else "OFF")
			chip.setSelected(values[key] == true)
		end
		chip = AdminWidgets.chip({
			text = "OFF",
			color = "green",
			width = 140,
			height = CHIP_HEIGHT,
			fit = fit,
			layoutOrder = 2,
			parent = holder,
			onActivated = function()
				values[key] = not values[key]
				render()
			end,
		})
		remember(chip.button)
		renderers[key] = render
		render()
	end

	for index, key in keys do
		local spec = info.args[key]
		local holder = AdminWidgets.column(`Field_{key}`, frame, 6, 10 + index)
		fieldLabel(spec, key, holder, 1)
		local kind = spec.kind
		if kind == "integer" or kind == "number" then
			numericField(key, spec, holder)
		elseif kind == "banDuration" then
			local choices: { { value: any, text: string } } = {}
			for _, option in AdminConfig.BanDurations do
				if option.seconds >= 0 or AdminConfig.AllowPermanentBans then
					table.insert(choices, { value = option.seconds, text = option.label })
				end
			end
			choiceField(key, spec, holder, choices)
		elseif kind == "enum" then
			local choices: { { value: any, text: string } } = {}
			for _, value in spec.values or {} do
				table.insert(choices, { value = value, text = enumLabel(spec, value) })
			end
			choiceField(key, spec, holder, choices)
		elseif kind == "boolean" then
			booleanField(key, spec, holder)
		else
			textField(key, spec, holder)
		end
	end

	-- Run row --------------------------------------------------------------------------------------
	local runRow = AdminWidgets.wrapRow("RunRow", frame, 12, 100)
	local run = StudUI.button({
		text = if compact then info.label else string.upper(info.label),
		color = color,
		size = UDim2.fromOffset(if compact then options.compactWidth or RUN_WIDTH else RUN_WIDTH, RUN_HEIGHT),
		textSize = 24,
		name = `Run_{info.name}`,
		layoutOrder = 1,
		parent = runRow,
	})
	AdminWidgets.sized(run.instance, if compact then options.compactWidth or RUN_WIDTH else RUN_WIDTH, RUN_HEIGHT, fit)
	remember(run.instance)
	local reasonLabel = AdminWidgets.label({
		name = "Reason",
		text = "",
		size = UDim2.fromOffset(if compact then options.compactWidth or RUN_WIDTH else 520, 0),
		textSize = 18,
		color = Neutral.Danger,
		wrap = true,
		layoutOrder = 2,
		parent = if compact then frame else runRow,
	})
	reasonLabel.AutomaticSize = Enum.AutomaticSize.Y
	reasonLabel.Visible = false

	-- Collects the validated-looking args (the server validates for real). nil + reason on a
	-- missing required value / target.
	local function collect(): ({ [string]: any }?, string?, string)
		local args: { [string]: any } = {}
		local summary: { string } = {}
		local targetLabel = ""
		if info.target ~= "None" then
			local getTarget = options.getTarget
			local target = if getTarget ~= nil then getTarget() else nil
			if target == nil then
				return nil, if info.target == "AnyUser" then "type a user id first" else "pick a player first", ""
			end
			args.userId = target.userId
			targetLabel = target.label
		end
		for _, key in keys do
			local spec = info.args[key]
			local reader = textReaders[key]
			local value: any = if reader ~= nil then reader() else values[key]
			if reader ~= nil and value == "" then
				if spec.optional then
					continue
				elseif spec.allowEmpty ~= true then
					return nil, `{spec.label or key} is empty`, targetLabel
				end
			end
			args[key] = value
			local shown = if spec.kind == "enum"
				then enumLabel(spec, value)
				elseif spec.kind == "banDuration" then AdminWidgets.formatBanLength(value)
				else AdminWidgets.formatValue(value, spec.format)
			table.insert(summary, `{spec.label or key}: {shown}`)
		end
		return args, nil, table.concat(summary, "\n") .. (if targetLabel ~= "" then `\nTarget: {targetLabel}` else "")
	end

	local function send(args: { [string]: any })
		if AdminClient.send(info.name, args) then
			options.setStatus(`{info.label}...`, nil)
		else
			options.setStatus("Too fast - wait a moment", false)
		end
	end

	run.setCallback(function()
		local blocked = AdminClient.unavailable(info.name)
		if blocked ~= nil then
			options.setStatus(`{info.label}: {blocked}`, false)
			return
		end
		local args, problem, summary = collect()
		if args == nil then
			options.setStatus(`{info.label}: {problem or "invalid"}`, false)
			return
		end
		local ready = args :: { [string]: any }
		if info.confirm then
			local lines: { string } = {}
			if info.description ~= "" then
				table.insert(lines, info.description)
			end
			if summary ~= "" then
				table.insert(lines, summary)
			end
			options.ask({
				title = `{info.label}?`,
				message = table.concat(lines, "\n"),
				confirmText = string.upper(info.label),
				color = if color == "red" then "red" else "green",
				onConfirm = function()
					send(ready)
				end,
			})
		else
			send(ready)
		end
	end)

	-- Run button state: unusable (server reason) / missing target / ready.
	local lastReason: string? = "init"
	local function refresh()
		local reason = AdminClient.unavailable(info.name)
		if reason == nil and info.target ~= "None" then
			local getTarget = options.getTarget
			if getTarget == nil or getTarget() == nil then
				reason = if info.target == "AnyUser" then "type a user id" else "pick a player"
			end
		end
		if reason == lastReason then
			return
		end
		lastReason = reason
		if reason ~= nil then
			run.setState("disabled")
			reasonLabel.Text = reason :: string
			reasonLabel.Visible = true
		else
			run.setState("normal")
			reasonLabel.Visible = false
		end
	end
	refresh()

	frame.Parent = options.parent
	return {
		frame = frame,
		info = info,
		compact = compact,
		refresh = refresh,
		first = function(): GuiObject?
			return firstControl
		end,
		setValue = function(key: string, value: any)
			values[key] = value
			local render = renderers[key]
			if render ~= nil then
				render()
			end
		end,
		Destroy = function()
			frame:Destroy()
		end,
	}
end

return CommandForm
