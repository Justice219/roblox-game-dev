--!strict
--[[
	LiveTab — the admin panel's LIVE page (spec §14 "Live (players, server FPS, memory, uptime,
	bandwidth, per-system ms)"): this server's health right now, from the AdminState stats the
	server pushes (≤ 4 Hz on change, every 3 s otherwise; producer Server/Admin/AdminState, which
	reads AnalyticsService.liveHealth + Stats).

	Layout:
		updated 2s ago · job 1a2b3c4d · place v42
		[Players 3/8] [Server FPS 60] [Heartbeat 2.1 ms] [Physics FPS 60] [Memory 812 MB]
		[Uptime 1h 02m] [Instances 41,233] [Send 38 kbps] [Receive 12 kbps] [Avg ping 61 ms]
		[Saving ON] [Analytics sent 1,204] [dropped 0] [failed 0] [Server 2x Cash off]
		[In Nuke Town 5] [In Dino Valley 3]       (R57: one card per WorldsConfig world)
		- PER-SYSTEM LUAU TIME (ms per second) -
		Producers  ██████████  1.82
		Tycoon     ████         0.70 ...
	Card colours flag trouble at a glance (green fine / orange watch / red bad) for FPS,
	heartbeat, memory and ping.

	Performance: every Instance is built once; the system rows are a pool that grows to the
	number of systems the server reports (AnalyticsConfig.Health.Systems, ~14). `render` only
	writes labels whose text changed; the "updated Xs ago" line ticks on one 1 Hz thread that
	runs only while this page is visible.

	Gamepad: the system rows are selectable (no action) so the D-pad can scroll the page.

	Security: display only — every number is server-sent.

	Connects to: Screens/Admin/{AdminClient, AdminWidgets}, Kit/StudUI (card, progressBar,
	sectionLabel), Shared/Util/NumberFormat, Shared/Config/Worlds/WorldsConfig (the per-world
	cards; counts = AdminState stats.worlds from the server-set CurrentWorld attribute). Mounted by
	Screens/Admin/AdminPanelScreen.

	Example:
		local page = LiveTab.new(pageOptions)
		page.frame.Visible = true
		page.render()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AdminClient = require(script.Parent.AdminClient)
local AdminWidgets = require(script.Parent.AdminWidgets)
local Create = require(script.Parent.Parent.Parent.Create)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Parent.Widgets.StudWindow)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

type ColorName = UIStyleConfig.ColorName
type Stats = AdminClient.Stats

local LiveTab = {}

local Neutral = UIStyleConfig.Neutral

-- Layout (design px at 1080p).
local CARD_HEIGHT = 112
local CARD_GAP = 12
local CARDS_PER_ROW = 5
local SYSTEM_ROW_HEIGHT = 48
local SYSTEM_NAME_WIDTH = 220
local SYSTEM_VALUE_WIDTH = 140
local MAX_SYSTEMS = 32

-- One stat card: its key, caption and how to read / colour the value.
type CardDef = {
	key: string,
	caption: string,
	text: (stats: Stats) -> string,
	color: ((stats: Stats) -> ColorName)?,
}

-- Health thresholds: (good, warn) → green below/above good, orange to warn, red past warn.
local function band(value: number, good: number, warn: number, higherIsBetter: boolean): ColorName
	if higherIsBetter then
		return if value >= good then "green" elseif value >= warn then "orange" else "red"
	end
	return if value <= good then "green" elseif value <= warn then "orange" else "red"
end

local CARDS: { CardDef } = {
	{
		key = "players",
		caption = "Players",
		text = function(s: Stats): string
			return `{s.players} / {s.maxPlayers}`
		end,
	},
	{
		key = "fps",
		caption = "Server FPS",
		text = function(s: Stats): string
			return string.format("%.1f", s.fps)
		end,
		color = function(s: Stats): ColorName
			return band(s.fps, 55, 30, true)
		end,
	},
	{
		key = "heartbeat",
		caption = "Heartbeat",
		text = function(s: Stats): string
			return string.format("%.2f ms", s.heartbeatMs)
		end,
		color = function(s: Stats): ColorName
			return band(s.heartbeatMs, 8, 16, false)
		end,
	},
	{
		key = "physics",
		caption = "Physics FPS",
		text = function(s: Stats): string
			return string.format("%.1f", s.physicsFps)
		end,
		color = function(s: Stats): ColorName
			return band(s.physicsFps, 55, 30, true)
		end,
	},
	{
		key = "memory",
		caption = "Memory",
		text = function(s: Stats): string
			return `{NumberFormat.commas(math.floor(s.memoryMb))} MB`
		end,
		color = function(s: Stats): ColorName
			return band(s.memoryMb, 2500, 4000, false)
		end,
	},
	{
		key = "uptime",
		caption = "Uptime",
		text = function(s: Stats): string
			return AdminWidgets.formatSeconds(s.uptime)
		end,
	},
	{
		key = "instances",
		caption = "Instances",
		text = function(s: Stats): string
			return NumberFormat.commas(math.floor(s.instanceCount))
		end,
	},
	{
		key = "send",
		caption = "Send",
		text = function(s: Stats): string
			return string.format("%.1f kbps", s.sendKbps)
		end,
	},
	{
		key = "receive",
		caption = "Receive",
		text = function(s: Stats): string
			return string.format("%.1f kbps", s.receiveKbps)
		end,
	},
	{
		key = "ping",
		caption = "Avg ping",
		text = function(s: Stats): string
			return `{math.floor(s.avgPingMs)} ms`
		end,
		color = function(s: Stats): ColorName
			return band(s.avgPingMs, 120, 250, false)
		end,
	},
	{
		key = "saving",
		caption = "Saving",
		text = function(s: Stats): string
			return if s.savingEnabled then "ON" else "OFF"
		end,
		color = function(s: Stats): ColorName
			return if s.savingEnabled then "green" else "red"
		end,
	},
	{
		key = "fwdSent",
		caption = "Analytics sent",
		text = function(s: Stats): string
			return NumberFormat.commas(math.floor(s.forwardSent))
		end,
	},
	{
		key = "fwdDropped",
		caption = "Analytics dropped",
		text = function(s: Stats): string
			return NumberFormat.commas(math.floor(s.forwardDropped))
		end,
		color = function(s: Stats): ColorName
			return if s.forwardDropped > 0 then "orange" else "green"
		end,
	},
	{
		key = "fwdFailed",
		caption = "Analytics failed",
		text = function(s: Stats): string
			return NumberFormat.commas(math.floor(s.forwardFailed))
		end,
		color = function(s: Stats): ColorName
			return if s.forwardFailed > 0 then "red" else "green"
		end,
	},
	{
		key = "boost",
		caption = "Server 2x Cash",
		text = function(s: Stats): string
			return if s.serverBoostSeconds > 0 then AdminWidgets.formatClock(s.serverBoostSeconds) else "off"
		end,
	},
}

-- R57: one "players in <world>" card per world (WorldsConfig.Order), after the fixed cards.
for _, worldId in WorldsConfig.Order do
	local def = WorldsConfig.get(worldId)
	if def ~= nil then
		table.insert(CARDS, {
			key = `world_{worldId}`,
			caption = `In {def.name}`,
			text = function(s: Stats): string
				return NumberFormat.commas(s.worlds[worldId] or 0)
			end,
		})
	end
end

--[[
	Builds the page (see the module header).
	@param options the panel's PageOptions
	@return Page { frame, render, first, topRow }
]]
function LiveTab.new(options: AdminWidgets.PageOptions): AdminWidgets.Page
	local page = Create.new("Frame", {
		Name = "Live",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(options.width, options.height),
		Visible = false,
		Parent = options.parent,
	}) :: Frame
	local well = AdminWidgets.well("Content", page, 14)
	well.Size = UDim2.fromScale(1, 1)

	local updated = AdminWidgets.label({
		name = "Updated",
		text = "waiting for the server...",
		size = UDim2.new(1, 0, 0, 30),
		textSize = 22,
		color = Neutral.TextDim,
		layoutOrder = 1,
		parent = well,
	})

	-- Cards ------------------------------------------------------------------------------------------
	local grid = Create.new("Frame", {
		Name = "Cards",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Parent = well,
	}) :: Frame
	-- Usable width inside the well (its padding 10 + 18 and the scroll bar).
	local innerWidth = options.width - 28 - 12
	local cardWidth = math.floor((innerWidth - (CARDS_PER_ROW - 1) * CARD_GAP) / CARDS_PER_ROW)
	Create.new("UIGridLayout", {
		CellSize = UDim2.fromOffset(cardWidth, CARD_HEIGHT),
		CellPadding = UDim2.fromOffset(CARD_GAP, CARD_GAP + 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = grid,
	})
	type CardParts = { def: CardDef, card: StudUI.Card, value: TextLabel, color: ColorName, text: string }
	local cards: { CardParts } = {}
	for index, def in CARDS do
		local card = StudUI.card({
			color = "sky",
			title = def.caption,
			titleSize = 22,
			layoutOrder = index,
			name = `Card_{def.key}`,
			parent = grid,
		})
		local value = StudUI.text({
			name = "Value",
			text = "-",
			textSize = 34,
			font = "number",
			size = UDim2.new(1, 0, 0, 44),
			position = UDim2.new(0.5, 0, 1, -6),
			anchor = Vector2.new(0.5, 1),
			scaled = true,
			zIndex = 3,
			parent = card.content,
		})
		local parts: CardParts = { def = def, card = card, value = value, color = "sky", text = "-" }
		table.insert(cards, parts)
	end

	-- Per-system time ------------------------------------------------------------------------------
	local systemsHeader = StudUI.sectionLabel("Per-system Luau time (ms per second)", 28)
	systemsHeader.LayoutOrder = 3
	systemsHeader.Parent = well
	local systemsEmpty = AdminWidgets.label({
		text = "No system timings reported yet.",
		size = UDim2.new(1, 0, 0, 28),
		textSize = 20,
		color = Neutral.TextDim,
		layoutOrder = 4,
		parent = well,
	})
	local systemsHost = AdminWidgets.column("Systems", well, 6, 5)
	type SystemRow = { frame: TextButton, name: TextLabel, bar: StudUI.ProgressBar, value: TextLabel }
	local systemRows: { SystemRow } = {}
	local trackWidth = innerWidth - SYSTEM_NAME_WIDTH - SYSTEM_VALUE_WIDTH - 40

	local function systemRow(index: number): SystemRow
		local frame = Create.new("TextButton", {
			Name = `System{index}`,
			AutoButtonColor = false,
			BackgroundColor3 = Neutral.Body,
			Size = UDim2.new(1, 0, 0, SYSTEM_ROW_HEIGHT),
			Text = "",
			LayoutOrder = index,
			Selectable = true, -- lets a gamepad scroll the page; activating does nothing
			SelectionImageObject = Create.new("Frame", { BackgroundTransparency = 1 }),
			Children = { Create.new("UICorner", { CornerRadius = UDim.new(0, 8) }) },
		}) :: TextButton
		local edge = StudWindow.edge(frame, 2)
		frame.SelectionGained:Connect(function()
			edge.Color = Neutral.Text
			edge.Thickness = 4
		end)
		frame.SelectionLost:Connect(function()
			edge.Color = Neutral.Edge
			edge.Thickness = 2
		end)
		local name = AdminWidgets.label({
			text = "",
			size = UDim2.fromOffset(SYSTEM_NAME_WIDTH, SYSTEM_ROW_HEIGHT),
			textSize = 22,
			parent = frame,
		})
		name.Position = UDim2.fromOffset(12, 0)
		local bar = StudUI.progressBar({ color = "teal", size = UDim2.fromOffset(trackWidth, 16), parent = frame })
		bar.frame.AnchorPoint = Vector2.new(0, 0.5)
		bar.frame.Position = UDim2.new(0, SYSTEM_NAME_WIDTH + 20, 0.5, 0)
		local value = AdminWidgets.label({
			text = "",
			size = UDim2.fromOffset(SYSTEM_VALUE_WIDTH, SYSTEM_ROW_HEIGHT),
			textSize = 22,
			font = "number",
			align = Enum.TextXAlignment.Right,
			color = Neutral.CashGreen,
			parent = frame,
		})
		value.AnchorPoint = Vector2.new(1, 0)
		value.Position = UDim2.new(1, -12, 0, 0)
		frame.Parent = systemsHost
		return { frame = frame, name = name, bar = bar, value = value }
	end

	-- Rendering ------------------------------------------------------------------------------------
	local lastReceived = -1
	local ticking = false

	local function renderUpdated()
		local state = AdminClient.state
		if state == nil then
			updated.Text = "waiting for the server..."
			return
		end
		local age = math.max(0, math.floor(os.clock() - state.receivedAt))
		local stats = state.stats
		updated.Text =
			`updated {age}s ago · job {if stats.jobId ~= "" then stats.jobId else "studio"} · place v{math.floor(
				stats.placeVersion
			)}{if state.isStudio then " · STUDIO" else ""}`
	end

	local function render()
		local state = AdminClient.state
		renderUpdated()
		if options.isActive() and not ticking then
			ticking = true
			task.spawn(function()
				while options.isActive() do
					task.wait(1)
					renderUpdated()
				end
				ticking = false
			end)
		end
		if state == nil or state.receivedAt == lastReceived then
			return
		end
		lastReceived = state.receivedAt
		local stats = state.stats
		for _, parts in cards do
			local text = parts.def.text(stats)
			if text ~= parts.text then
				parts.text = text
				parts.value.Text = text
			end
			local colorFn = parts.def.color
			local color: ColorName = if colorFn ~= nil then colorFn(stats) else "sky"
			if color ~= parts.color then
				parts.color = color
				parts.card.setColor(color)
			end
		end
		-- Systems, busiest first.
		local entries: { { name: string, ms: number } } = {}
		local busiest = 0
		for name, ms in stats.systemsMs do
			table.insert(entries, { name = name, ms = ms })
			busiest = math.max(busiest, ms)
		end
		table.sort(entries, function(a: { name: string, ms: number }, b: { name: string, ms: number }): boolean
			if a.ms ~= b.ms then
				return a.ms > b.ms
			end
			return a.name < b.name
		end)
		local count = math.min(#entries, MAX_SYSTEMS)
		for index = 1, count do
			local row = systemRows[index]
			if row == nil then
				row = systemRow(index)
				systemRows[index] = row
			end
			local entry = entries[index]
			row.name.Text = entry.name
			row.value.Text = string.format("%.2f", entry.ms)
			row.bar.setProgress(if busiest > 0 then entry.ms / busiest else 0)
			row.frame.Visible = true
		end
		for index = count + 1, #systemRows do
			systemRows[index].frame.Visible = false
		end
		systemsEmpty.Visible = count == 0
	end

	return {
		frame = page,
		render = render,
		first = function(): GuiObject?
			local row = systemRows[1]
			return if row ~= nil and row.frame.Visible then row.frame else nil
		end,
		topRow = function(): { GuiObject }
			return {}
		end,
	}
end

return LiveTab
