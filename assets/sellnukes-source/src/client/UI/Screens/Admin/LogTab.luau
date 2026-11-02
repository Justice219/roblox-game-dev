--!strict
--[[
	LogTab — the admin panel's LOG page (spec §14 "Log (audit)"): the server's admin audit log,
	newest first. Every executed command, every rejected / malformed call and every DENIED call
	from a non-admin lands in the server's ring buffer (AdminConfig.AuditLogSize, printed to the
	server output too); the server sends the newest AdminConfig.AuditTailSize entries to each admin
	whenever the log changed (AdminState.log + logVersion).

	Row:  12:03:44 UTC · Owner · GrantGems                                       [OK]
	      amount=100 userId=123
	      Granted 100 gems: Bob (123) (now 220)
	Filters: ALL · FAILED (rejected / denied / errors) · MINE (your own commands).

	Performance: rows are a pool (≤ AuditTailSize) built on demand and reused; `render` does
	nothing unless the log version or the filter changed. No per-frame work.

	Gamepad: the filter chips and every row are selectable (rows do nothing on A; selecting them
	scrolls the list).

	Security: display only — entries are server-sanitised (control characters stripped, values
	truncated) before they are sent; labels never use RichText for log content.

	Connects to: Screens/Admin/{AdminClient, AdminWidgets}, Widgets/StudWindow,
	Shared/Config/AdminConfig. Mounted by Screens/Admin/AdminPanelScreen.

	Example:
		local page = LogTab.new(pageOptions)
		page.frame.Visible = true
		page.render()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AdminClient = require(script.Parent.AdminClient)
local AdminConfig = require(ReplicatedStorage.Shared.Config.AdminConfig)
local AdminWidgets = require(script.Parent.AdminWidgets)
local Create = require(script.Parent.Parent.Parent.Create)
local StudWindow = require(script.Parent.Parent.Parent.Widgets.StudWindow)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

type AuditEntry = AdminConfig.AuditEntry

local LogTab = {}

local Neutral = UIStyleConfig.Neutral

-- Layout (design px at 1080p).
local ROW_HEIGHT = 92
local TAG_WIDTH = 120
local MAX_ROWS = AdminConfig.AuditTailSize

type Filter = "All" | "Failed" | "Mine"
local FILTERS: { Filter } = { "All", "Failed", "Mine" }

local localPlayer = Players.LocalPlayer

-- One pooled log row.
type RowParts = {
	button: TextButton,
	head: TextLabel,
	args: TextLabel,
	result: TextLabel,
	tag: TextLabel,
}

--[[
	Builds the page (see the module header).
	@param options the panel's PageOptions
	@return Page { frame, render, first, topRow }
]]
function LogTab.new(options: AdminWidgets.PageOptions): AdminWidgets.Page
	local fit = options.fitScale
	local page = Create.new("Frame", {
		Name = "Log",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(options.width, options.height),
		Visible = false,
		Parent = options.parent,
	}) :: Frame
	local well = AdminWidgets.well("Entries", page, 8)
	well.Size = UDim2.fromScale(1, 1)

	local filter: Filter = "All"
	local renderedVersion = -1
	local renderedFilter: Filter? = nil
	local rows: { RowParts } = {}

	-- Filters ----------------------------------------------------------------------------------------
	local filterRow = AdminWidgets.wrapRow("Filters", well, 10, 0)
	local filterChips: { [Filter]: AdminWidgets.Chip } = {}
	local render: () -> ()
	for index, name in FILTERS do
		filterChips[name] = AdminWidgets.chip({
			text = string.upper(name),
			color = if name == "Failed" then "red" elseif name == "Mine" then "blue" else "grey",
			width = 160,
			height = 50,
			fit = fit,
			layoutOrder = index,
			parent = filterRow,
			onActivated = function()
				filter = name
				render()
			end,
		})
	end
	local countLabel = AdminWidgets.label({
		text = "",
		size = UDim2.fromOffset(420, 50),
		textSize = 20,
		color = Neutral.TextDim,
		layoutOrder = 10,
		parent = filterRow,
	})
	local emptyLabel = AdminWidgets.label({
		text = "No entries yet.",
		size = UDim2.new(1, 0, 0, 30),
		textSize = 22,
		color = Neutral.TextDim,
		layoutOrder = 1,
		parent = well,
	})

	-- Rows -------------------------------------------------------------------------------------------
	local function makeRow(index: number): RowParts
		local button = Create.new("TextButton", {
			Name = `Entry{index}`,
			AutoButtonColor = false,
			BackgroundColor3 = Neutral.Body,
			Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
			Text = "",
			LayoutOrder = 10 + index,
			Visible = false,
			Selectable = true, -- gamepad scrolling; activating does nothing
			SelectionImageObject = Create.new("Frame", { BackgroundTransparency = 1 }),
			Children = { Create.new("UICorner", { CornerRadius = UDim.new(0, 8) }) },
		}) :: TextButton
		local edge = StudWindow.edge(button, 2)
		button.SelectionGained:Connect(function()
			edge.Color = Neutral.Text
			edge.Thickness = 4
		end)
		button.SelectionLost:Connect(function()
			edge.Color = Neutral.Edge
			edge.Thickness = 2
		end)
		local head = AdminWidgets.label({
			name = "Head",
			text = "",
			size = UDim2.new(1, -(TAG_WIDTH + 36), 0, 28),
			textSize = 22,
			font = "title",
			parent = button,
		})
		head.Position = UDim2.fromOffset(12, 6)
		local args = AdminWidgets.label({
			name = "Args",
			text = "",
			size = UDim2.new(1, -24, 0, 24),
			textSize = 18,
			color = Neutral.TextDim,
			parent = button,
		})
		args.Position = UDim2.fromOffset(12, 36)
		local result = AdminWidgets.label({
			name = "Result",
			text = "",
			size = UDim2.new(1, -24, 0, 24),
			textSize = 18,
			parent = button,
		})
		result.Position = UDim2.fromOffset(12, 62)
		local tag = AdminWidgets.label({
			name = "Tag",
			text = "",
			size = UDim2.fromOffset(TAG_WIDTH, 28),
			textSize = 22,
			font = "number",
			align = Enum.TextXAlignment.Right,
			parent = button,
		})
		tag.AnchorPoint = Vector2.new(1, 0)
		tag.Position = UDim2.new(1, -14, 0, 6)
		button.Parent = well
		return { button = button, head = head, args = args, result = result, tag = tag }
	end

	-- True when `entry` passes the current filter.
	local function passes(entry: AuditEntry): boolean
		if filter == "Failed" then
			return not entry.ok
		elseif filter == "Mine" then
			return entry.adminUserId == localPlayer.UserId
		end
		return true
	end

	render = function()
		local state = AdminClient.state
		if state == nil then
			return
		end
		if state.logVersion == renderedVersion and filter == renderedFilter then
			return
		end
		renderedVersion = state.logVersion
		renderedFilter = filter
		for name, chip in filterChips do
			chip.setSelected(name == filter)
		end
		local log = state.log
		local shown = 0
		-- The server sends oldest first; show newest first.
		for index = #log, 1, -1 do
			local entry = log[index]
			if type(entry) ~= "table" or not passes(entry) then
				continue
			end
			shown += 1
			if shown > MAX_ROWS then
				break
			end
			local row = rows[shown]
			if row == nil then
				row = makeRow(shown)
				rows[shown] = row
			end
			row.head.Text = `{AdminWidgets.formatUtc(entry.time)} UTC · {entry.adminName} · {entry.command}`
			row.args.Text = if entry.args ~= "" then entry.args else "(no arguments)"
			row.result.Text = entry.result
			row.result.TextColor3 = if entry.ok then Neutral.Text else Neutral.Danger
			row.tag.Text = if entry.ok then "OK" else "FAILED"
			row.tag.TextColor3 = if entry.ok then Neutral.CashGreen else Neutral.Danger
			row.button.Visible = true
		end
		shown = math.min(shown, MAX_ROWS)
		for index = shown + 1, #rows do
			rows[index].button.Visible = false
		end
		emptyLabel.Visible = shown == 0
		countLabel.Text = `{shown} of the last {#log} entries · server keeps {AdminConfig.AuditLogSize}`
	end

	return {
		frame = page,
		render = render,
		first = function(): GuiObject?
			return filterChips[filter].button
		end,
		topRow = function(): { GuiObject }
			local top: { GuiObject } = {}
			for _, name in FILTERS do
				table.insert(top, filterChips[name].button)
			end
			return top
		end,
	}
end

return LogTab
