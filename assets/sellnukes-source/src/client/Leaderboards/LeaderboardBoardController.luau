--!strict
--[[
	LeaderboardBoardController — the client side of SellNukes' three global hub leaderboards
	(docs/leaderboards.md): the data cache and the stud-styled hub boards.

	Purpose:
		- DATA: watches ReplicatedStorage.Leaderboards/<BoardId> StringValues (written only by the
		  server's LeaderboardService), decodes each change ONCE (JSONDecode +
		  LeaderboardConfig.parsePayload: bounded rows, clean names, finite values) and fires
		  `Changed(boardId)`. The client never sends anything for this system.
		- BOARDS: for every screen part tagged LeaderboardConfig.ScreenTag (attribute BoardId) a
		  SurfaceGui in PlayerGui is adorned to it: a coloured stud header (icon + title + "ALL-TIME"
		  / "THIS SERVER"), the top 10 rows (gold / silver / bronze rank badges, avatar headshot,
		  name, value), the local player's row highlighted, a footer with YOUR value (and rank when
		  in the top 25), and loading / empty / offline states. Layout is all scale-based, so any
		  face size from the hub art works.
		- Redraws only when that board's payload changes; the footer's own value updates at most
		  once per second from the profile. SurfaceGuis cull at LeaderboardConfig.Board.maxDistance.

	Connects to: Services/LeaderboardService (server), Shared/Config/LeaderboardConfig, Kit/StudUI
	(stud card, text, icons), Client/ClientState (own values), Shared/Util/NumberFormat.

	Example:
		local payload = LeaderboardBoardController.read("Cash")
		LeaderboardBoardController.Changed:Connect(function(boardId) print(boardId, "updated") end)
]]

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientState = require(script.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.UI.Create)
local LeaderboardConfig = require(ReplicatedStorage.Shared.Config.LeaderboardConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local StudUI = require(script.Parent.Parent.UI.Kit.StudUI)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

type BoardId = LeaderboardConfig.BoardId
type BoardDef = LeaderboardConfig.BoardDef
type Payload = LeaderboardConfig.Payload

-- One drawn row.
type RowUi = { frame: Frame, rank: TextLabel, badge: Frame, avatar: ImageLabel, name: TextLabel, value: TextLabel }

-- One drawn board (one per tagged screen part).
type BoardUi = {
	def: BoardDef,
	gui: SurfaceGui,
	rows: { RowUi },
	state: TextLabel,
	scope: TextLabel,
	footer: TextLabel,
}

local LeaderboardBoardController = {}

-- Fires with the board id whenever that board's decoded payload changed.
LeaderboardBoardController.Changed = Signal.new() :: Signal.Signal<BoardId>

-- Rank badge colours 1-3 (gold / silver / bronze), then the default.
LeaderboardBoardController.MedalColors = table.freeze({
	Color3.fromRGB(255, 205, 50),
	Color3.fromRGB(205, 215, 230),
	Color3.fromRGB(222, 140, 80),
})
local RANK_DEFAULT = Color3.fromRGB(70, 78, 112)
local ROW_COLOR = Color3.fromRGB(32, 36, 58)
local ROW_SELF = Color3.fromRGB(46, 120, 74)
-- Text transparency of an empty rank's "---" placeholder name.
local PLACEHOLDER_FADE = 0.55

local localPlayer = Players.LocalPlayer
local payloads: { [BoardId]: Payload? } = {}
local boards: { [BasePart]: BoardUi } = {}
local started = false

--------------------------------------------------------------------------------------------------
-- Data
--------------------------------------------------------------------------------------------------

--[[ The decoded payload of a board, or nil while it has not been read yet (loading). ]]
function LeaderboardBoardController.read(boardId: BoardId): Payload?
	return payloads[boardId]
end

--[[ Display text of a board value ("$1.25M", "12", "3h 05m"). ]]
function LeaderboardBoardController.formatValue(def: BoardDef, value: number): string
	if def.format == "money" then
		return NumberFormat.money(value)
	elseif def.format == "duration" then
		return NumberFormat.duration(value)
	end
	return NumberFormat.commas(value)
end

-- Decodes one StringValue into the cache (malformed = not read yet).
local function decode(def: BoardDef, value: StringValue)
	local text = value.Value
	local payload: Payload? = nil
	if text ~= "" and #text <= LeaderboardConfig.MaxPayloadChars then
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, text)
		if ok then
			payload = LeaderboardConfig.parsePayload(decoded, def.id)
		end
	end
	payloads[def.id] = payload
	LeaderboardBoardController.Changed:Fire(def.id)
end

--------------------------------------------------------------------------------------------------
-- Boards
--------------------------------------------------------------------------------------------------

-- Builds one board's SurfaceGui (rows pooled: built once, only properties change later).
local function buildBoard(def: BoardDef, part: BasePart): BoardUi
	local cfg = LeaderboardConfig.Board
	local gui = Create.new("SurfaceGui", {
		Name = `Leaderboard_{def.id}`,
		Adornee = part,
		Face = Enum.NormalId.Front,
		SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
		PixelsPerStud = cfg.pixelsPerStud,
		MaxDistance = cfg.maxDistance,
		LightInfluence = 0,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}) :: SurfaceGui
	local card = StudUI.card({ color = "grey", size = UDim2.fromScale(1, 1), parent = gui })
	local content = card.content
	-- Header: coloured stud bar with the board icon + title.
	local header = StudUI.card({
		color = def.color :: StudUI.ColorName,
		size = UDim2.fromScale(1, 0.15),
		parent = content,
	})
	local icon = StudUI.icon(def.icon, 64, 6)
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Position = UDim2.fromScale(0.01, 0.5)
	icon.Size = UDim2.fromScale(0.1, 1.15)
	Create.new("UIAspectRatioConstraint", { AspectRatio = 1, Parent = icon })
	icon.Parent = header.content
	StudUI.text({
		text = def.title,
		textSize = 54,
		font = "shout",
		scaled = true,
		position = UDim2.fromScale(0.13, 0.05),
		size = UDim2.fromScale(0.62, 0.9),
		align = Enum.TextXAlignment.Left,
		zIndex = 6,
		parent = header.content,
	})
	local scope = StudUI.text({
		text = "ALL-TIME",
		textSize = 26,
		scaled = true,
		color = Color3.fromRGB(255, 240, 180),
		position = UDim2.fromScale(0.76, 0.2),
		size = UDim2.fromScale(0.23, 0.6),
		align = Enum.TextXAlignment.Right,
		zIndex = 6,
		parent = header.content,
	})
	-- Rows.
	local list = Create.new("Frame", {
		Name = "Rows",
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0, 0.17),
		Size = UDim2.fromScale(1, 0.72),
		Parent = content,
		Children = {
			Create.new("UIListLayout", {
				Padding = UDim.new(0.006, 0),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		},
	}) :: Frame
	local rows: { RowUi } = {}
	local rowHeight = 1 / LeaderboardConfig.ShowRows - 0.006
	for index = 1, LeaderboardConfig.ShowRows do
		local frame = Create.new("Frame", {
			Name = `Row{index}`,
			BackgroundColor3 = ROW_COLOR,
			BackgroundTransparency = 0.15,
			Size = UDim2.fromScale(1, rowHeight),
			LayoutOrder = index,
			Visible = false,
			Parent = list,
			Children = { Create.new("UICorner", { CornerRadius = UDim.new(0.25, 0) }) },
		}) :: Frame
		local badge = Create.new("Frame", {
			Name = "Badge",
			BackgroundColor3 = RANK_DEFAULT,
			Position = UDim2.fromScale(0.01, 0.08),
			Size = UDim2.fromScale(0.075, 0.84),
			Parent = frame,
			Children = { Create.new("UICorner", { CornerRadius = UDim.new(0.3, 0) }) },
		}) :: Frame
		local rank = StudUI.text({
			text = "",
			textSize = 30,
			font = "number",
			scaled = true,
			size = UDim2.fromScale(1, 1),
			zIndex = 3,
			parent = badge,
		})
		local avatar = Create.new("ImageLabel", {
			Name = "Avatar",
			BackgroundColor3 = Color3.fromRGB(56, 62, 96),
			Position = UDim2.fromScale(0.1, 0.06),
			Size = UDim2.fromScale(0.06, 0.88),
			ScaleType = Enum.ScaleType.Fit,
			Parent = frame,
			Children = {
				Create.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
				Create.new("UIAspectRatioConstraint", { AspectRatio = 1 }),
			},
		}) :: ImageLabel
		local name = StudUI.text({
			text = "",
			textSize = 30,
			scaled = true,
			align = Enum.TextXAlignment.Left,
			position = UDim2.fromScale(0.18, 0.1),
			size = UDim2.fromScale(0.48, 0.8),
			zIndex = 3,
			parent = frame,
		})
		local value = StudUI.text({
			text = "",
			textSize = 30,
			font = "number",
			scaled = true,
			color = UIStyleConfig.Neutral.CashGreen,
			align = Enum.TextXAlignment.Right,
			position = UDim2.fromScale(0.67, 0.1),
			size = UDim2.fromScale(0.31, 0.8),
			zIndex = 3,
			parent = frame,
		})
		table.insert(rows, { frame = frame, rank = rank, badge = badge, avatar = avatar, name = name, value = value })
	end
	local state = StudUI.text({
		text = "LOADING...",
		textSize = 34,
		wrap = true,
		scaled = true,
		position = UDim2.fromScale(0.05, 0.4),
		size = UDim2.fromScale(0.9, 0.2),
		zIndex = 4,
		parent = content,
	})
	local footer = StudUI.text({
		text = "",
		textSize = 30,
		scaled = true,
		color = Color3.fromRGB(255, 226, 80),
		position = UDim2.fromScale(0.02, 0.9),
		size = UDim2.fromScale(0.96, 0.09),
		zIndex = 4,
		parent = content,
	})
	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	return { def = def, gui = gui, rows = rows, state = state, scope = scope, footer = footer }
end

-- "YOU: $1.25M · #4" (rank only when on the payload).
local function footerText(ui: BoardUi, payload: Payload?): string
	local mine = LeaderboardConfig.valueOf(ui.def, ClientState.profile)
	local text = `YOU: {LeaderboardBoardController.formatValue(ui.def, mine)}`
	if payload ~= nil then
		for _, entry in payload.entries do
			if entry.userId == localPlayer.UserId then
				return `{text}  ·  #{entry.rank}`
			end
		end
	end
	return text
end

-- Redraws one board from its payload.
local function render(ui: BoardUi)
	local payload = payloads[ui.def.id]
	ui.scope.Text = if payload ~= nil and payload.scope == "server" then "THIS SERVER" else "ALL-TIME"
	local entries = if payload ~= nil then payload.entries else {}
	-- With some entries, the free ranks below them show as dim "---" placeholder rows (QA
	-- 2026-10-30, World-QA H2: a board with one or two names read as a blank dark panel from the
	-- plaza). With none, the state line (loading / offline / empty text) shows instead.
	local placeholders = #entries > 0
	for index, row in ui.rows do
		local entry = entries[index]
		row.frame.Visible = entry ~= nil or placeholders
		if entry ~= nil then
			row.rank.Text = tostring(entry.rank)
			row.badge.BackgroundColor3 = LeaderboardBoardController.MedalColors[entry.rank] or RANK_DEFAULT
			row.avatar.Image = `rbxthumb://type=AvatarHeadShot&id={entry.userId}&w=150&h=150`
			row.avatar.Visible = true
			row.name.Text = entry.name
			row.name.TextTransparency = 0
			row.value.Text = LeaderboardBoardController.formatValue(ui.def, entry.value)
			row.frame.BackgroundColor3 = if entry.userId == localPlayer.UserId then ROW_SELF else ROW_COLOR
		elseif placeholders then
			row.rank.Text = tostring(index)
			row.badge.BackgroundColor3 = RANK_DEFAULT
			row.avatar.Image = ""
			row.avatar.Visible = false
			row.name.Text = "---"
			row.name.TextTransparency = PLACEHOLDER_FADE
			row.value.Text = ""
			row.frame.BackgroundColor3 = ROW_COLOR
		end
	end
	if payload == nil then
		ui.state.Text = "LOADING..."
		ui.state.Visible = true
	elseif payload.status == "unavailable" then
		ui.state.Text = "Leaderboard offline - retrying soon!"
		ui.state.Visible = true
	elseif #entries == 0 then
		ui.state.Text = ui.def.emptyText
		ui.state.Visible = true
	else
		ui.state.Visible = false
	end
	ui.footer.Text = footerText(ui, payload)
end

-- Attaches a board to a tagged screen part (streamed in / rebuilt parts re-attach).
local function attach(instance: Instance)
	if not instance:IsA("BasePart") or boards[instance] ~= nil then
		return
	end
	local id = instance:GetAttribute(LeaderboardConfig.BoardAttribute)
	local def = if type(id) == "string" then LeaderboardConfig.ById[id :: BoardId] else nil
	if def == nil then
		return
	end
	local ui = buildBoard(def, instance)
	boards[instance] = ui
	render(ui)
end

local function detach(instance: Instance)
	local part = instance :: BasePart
	local ui = boards[part]
	if ui ~= nil then
		boards[part] = nil
		ui.gui:Destroy()
	end
end

--------------------------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------------------------

function LeaderboardBoardController.Init() end

function LeaderboardBoardController.Start()
	if started then
		return
	end
	started = true
	LeaderboardBoardController.Changed:Connect(function(boardId: BoardId)
		for _, ui in boards do
			if ui.def.id == boardId then
				render(ui)
			end
		end
	end)
	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild(LeaderboardConfig.ContainerName, 60)
		if folder == nil then
			warn("[LeaderboardBoardController] ReplicatedStorage.Leaderboards never replicated")
			return
		end
		for _, def in LeaderboardConfig.Boards do
			local value = folder:WaitForChild(def.id, 30)
			if value ~= nil and value:IsA("StringValue") then
				local board = def
				value:GetPropertyChangedSignal("Value"):Connect(function()
					decode(board, value)
				end)
				decode(board, value)
			end
		end
	end)
	CollectionService:GetInstanceAddedSignal(LeaderboardConfig.ScreenTag):Connect(attach)
	CollectionService:GetInstanceRemovedSignal(LeaderboardConfig.ScreenTag):Connect(detach)
	for _, instance in CollectionService:GetTagged(LeaderboardConfig.ScreenTag) do
		attach(instance)
	end
	-- The footer's own value: at most once per second (cash ticks 4x a second).
	task.spawn(function()
		while true do
			task.wait(1)
			for _, ui in boards do
				ui.footer.Text = footerText(ui, payloads[ui.def.id])
			end
		end
	end)
end

return LeaderboardBoardController
