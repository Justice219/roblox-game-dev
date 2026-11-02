--!strict
--[[
	PlayersTab — the admin panel's PLAYERS page (spec §14 "Players (list with cash/gems/area/ping;
	grant/take cash & gems, set area, unlock all pads, reset plot, set rebirths, give boost,
	teleport to/bring, kick, ban/unban via BanAsync)").

	Layout (inside the panel's page area):
		┌ players (scroll) ───────┐┌ detail (scroll) ─────────────────────────────────────────┐
		│ Bob  @bob  ADMIN         ││ Bob (@bob) · 123456 · ADMIN                               │
		│ $1.2M · 120 gems         ││ Cash $1,234,567 · Gems 120 · Area 3 · Rebirths 2 ...      │
		│ Area 3 · 2 reb · 45 ms   ││ - CURRENCY -  [Give Cash form] [Take Cash form] ...        │
		│ ...                      ││ - TYCOON -    [Set Area] [UNLOCK ALL] [RESET PLOT] ...     │
		│ OFFLINE USER / BANS      ││ - REWARDS - / - MOVE - / - MODERATION - / - MORE -         │
		└──────────────────────────┘└───────────────────────────────────────────────────────────┘
	Selecting the last entry (OFFLINE USER / BANS) swaps the detail for a UserId box with the
	Ban / Unban forms (target AnyUser: works for users who are not in this server) and the list of
	bans issued this session (quick UNBAN, confirmed in-panel).

	Commands are NOT hard-coded: every catalogue command of tab "Players" is rendered through
	CommandForm, grouped by name (Currency / Tycoon / Rewards / Move / Moderation); anything else
	— e.g. pets / attack commands registered by later systems — lands in MORE automatically.
	Argument-less commands render compact (one button each) in a wrap row above the forms.

	World columns (owner R57): each row also shows the world the player is in (when not Nuke Town)
	and every UNLOCKED extra world's currency, area and rebirths ("Dino Valley · 1.2K Bones · area 3
	· 1 reb"); the detail header repeats them in full (AdminClient.playerWorlds).

	Data: AdminClient.state.players / recentBans / catalog / playerWorlds (server pushes ≤ 4 Hz +
	every 3 s).
	`render` updates a row only when its text changed and rebuilds forms only when the catalogue
	(set of command names) changed; availability changes only refresh the run buttons.

	Gamepad: rows are selectable (A picks the player); the detail column is reached with the
	D-pad right; every form control is selectable. Touch: rows / chips / buttons honour the 44 pt
	floor (AdminWidgets.sized).

	Security: display + intents only. A Player target is sent as a user id; the server resolves
	it to a real Player in its own server (Players:GetPlayerByUserId) and re-validates everything.

	Connects to: Screens/Admin/{AdminClient, AdminWidgets, CommandForm}, Kit/StudUI,
	Widgets/StudWindow, Shared/Config/AdminConfig, Shared/Util/NumberFormat. Mounted by
	Screens/Admin/AdminPanelScreen.

	Example:
		local page = PlayersTab.new(pageOptions)
		page.frame.Visible = true
		page.render()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AdminClient = require(script.Parent.AdminClient)
local AdminConfig = require(ReplicatedStorage.Shared.Config.AdminConfig)
local AdminWidgets = require(script.Parent.AdminWidgets)
local CommandForm = require(script.Parent.CommandForm)
local Create = require(script.Parent.Parent.Parent.Create)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Parent.Widgets.StudWindow)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

type CommandInfo = AdminConfig.CommandInfo
type PlayerRow = AdminConfig.PlayerRow
type RecentBan = AdminConfig.RecentBan

local PlayersTab = {}

local Neutral = UIStyleConfig.Neutral
local Style = UIStyleConfig

-- Layout (design px at 1080p).
local LIST_WIDTH = 470
local COLUMN_GAP = 16
-- Title, money and info lines + (R57) the worlds line.
local ROW_HEIGHT = 124
local OFFLINE_ROW_HEIGHT = 64
local MAX_ROWS = 24 -- pool cap (8-player servers; headroom for Studio multi-client tests)
local MAX_BAN_ROWS = AdminConfig.RecentBansSize
local COMPACT_WIDTH = 260

-- Command groups of the detail column (in order). Unlisted names go to "More".
local GROUPS: { { title: string, names: { string } } } = {
	{ title = "Currency", names = { "GrantCash", "TakeCash", "SetCash", "GrantGems", "TakeGems" } },
	{ title = "Tycoon", names = { "SetArea", "UnlockAll", "ResetPlot", "SetRebirths" } },
	{ title = "Rewards", names = { "GiveBoost", "GrantSpins", "ResetDaily", "AddPlaytime", "ResetClaims" } },
	{ title = "Move", names = { "TeleportTo", "Bring" } },
	-- ResetPlotName: owner R88 plot-name moderation (registered at runtime by Server/Tycoon/PlotNameAdmin).
	{ title = "Moderation", names = { "Kick", "Ban", "Unban", "ResetPlotName" } },
}
local GROUP_OF: { [string]: number } = {}
for index, group in GROUPS do
	for _, name in group.names do
		GROUP_OF[name] = index
	end
end
local MORE_GROUP = #GROUPS + 1

local localPlayer = Players.LocalPlayer

--[[
	R57 world text of a player: the world they are in (when not Nuke Town) and each UNLOCKED extra
	world's currency / area / rebirths. `full` = the detail header wording.
	Example: worldText(pw, false) --> "in Dino Valley · 1.2K Bones · Dino Valley area 3 · 1 reb"
]]
local function worldText(worlds: AdminClient.PlayerWorlds?, full: boolean): string
	if worlds == nil then
		return ""
	end
	local parts: { string } = {}
	if worlds.world ~= WorldsConfig.MAIN then
		local def = WorldsConfig.get(worlds.world)
		table.insert(parts, `in {if def ~= nil then def.name else worlds.world}`)
	end
	for _, def in WorldsConfig.extra() do
		local columns = worlds.worlds[def.id]
		if columns ~= nil and columns.unlocked then
			if full then
				table.insert(
					parts,
					`{def.name}: {NumberFormat.commas(math.floor(columns.cash))} {def.currency.name} · area {math.floor(
						columns.area
					)} · {NumberFormat.commas(columns.rebirths)} rebirths`
				)
			else
				table.insert(
					parts,
					`{NumberFormat.short(columns.cash)} {def.currency.name} · {def.name} area {math.floor(columns.area)} · {NumberFormat.short(
						columns.rebirths
					)} reb`
				)
			end
		elseif columns ~= nil and full then
			table.insert(parts, `{def.name}: locked`)
		end
	end
	return table.concat(parts, " · ")
end

-- One pooled player row.
type RowParts = {
	button: TextButton,
	surface: StudWindow.Surface,
	title: TextLabel,
	money: TextLabel,
	info: TextLabel,
	worlds: TextLabel, -- R57: current world + unlocked extra worlds (currency / area / rebirths)
	userId: number,
	signature: string,
}

-- One pooled recent-ban row.
type BanRowParts = { frame: Frame, text: TextLabel, unban: AdminWidgets.Chip, userId: number }

-- The badges shown after a player's name.
local function badges(row: PlayerRow): string
	local parts: { string } = {}
	if row.isAdmin then
		table.insert(parts, "ADMIN")
	end
	if row.newPlayerMode then
		table.insert(parts, "NEW PLAYER MODE")
	end
	if not row.loaded then
		table.insert(parts, "LOADING")
	end
	return table.concat(parts, " · ")
end

-- "45 ms" / "? ms".
local function pingText(ms: number): string
	return if ms >= 0 then `{math.floor(ms)} ms` else "? ms"
end

--[[
	Builds the page (see the module header).
	@param options the panel's PageOptions
	@return Page { frame, render, first, topRow }
]]
function PlayersTab.new(options: AdminWidgets.PageOptions): AdminWidgets.Page
	local fit = options.fitScale
	local page = Create.new("Frame", {
		Name = "Players",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(options.width, options.height),
		Visible = false,
		Parent = options.parent,
	}) :: Frame

	-- State ---------------------------------------------------------------------------------------
	local selectedUserId: number? = localPlayer.UserId
	local offlineSelected = false
	local typedUserId: number? = nil
	local catalogSignature = ""
	local forms: { CommandForm.Form } = {}
	local rows: { RowParts } = {}
	local banRows: { BanRowParts } = {}
	local banSignature = ""

	-- Left: player list ---------------------------------------------------------------------------
	local list = AdminWidgets.well("PlayerList", page, 8)
	list.Size = UDim2.new(0, LIST_WIDTH, 1, 0)

	local render: () -> ()

	local function paintRow(parts: RowParts)
		local selected = not offlineSelected and parts.userId == selectedUserId
		parts.surface.setColor(if selected then "blue" else "grey")
	end

	local function makeRow(index: number): RowParts
		local button = Create.new("TextButton", {
			Name = `Player{index}`,
			AutoButtonColor = false,
			Text = "",
			LayoutOrder = index,
			Visible = false,
			Selectable = true,
			SelectionImageObject = Create.new("Frame", { BackgroundTransparency = 1 }),
		}) :: TextButton
		AdminWidgets.sized(button, 1, ROW_HEIGHT, fit, true)
		local surface = StudWindow.surface(button, "grey", {
			tile = Style.StudTile.Button,
			studTransparency = Style.StudTransparency.Button,
			corner = 8,
		})
		local edge = StudWindow.edge(button, 3)
		button.SelectionGained:Connect(function()
			edge.Color = Neutral.Text
			edge.Thickness = 4
		end)
		button.SelectionLost:Connect(function()
			edge.Color = Neutral.Edge
			edge.Thickness = 3
		end)
		local title = AdminWidgets.label({
			name = "Title",
			text = "",
			size = UDim2.new(1, -24, 0, 30),
			textSize = 24,
			font = "title",
			rich = true,
			parent = button,
		})
		title.Position = UDim2.fromOffset(12, 6)
		title.ZIndex = 3
		local money = AdminWidgets.label({
			name = "Money",
			text = "",
			size = UDim2.new(1, -24, 0, 26),
			textSize = 22,
			font = "number",
			rich = true,
			parent = button,
		})
		money.Position = UDim2.fromOffset(12, 38)
		money.ZIndex = 3
		local info = AdminWidgets.label({
			name = "Info",
			text = "",
			size = UDim2.new(1, -24, 0, 24),
			textSize = 18,
			color = Neutral.TextDim,
			parent = button,
		})
		info.Position = UDim2.fromOffset(12, 66)
		info.ZIndex = 3
		local worldsLabel = AdminWidgets.label({
			name = "Worlds",
			text = "",
			size = UDim2.new(1, -24, 0, 24),
			textSize = 18,
			color = Neutral.TextDim,
			parent = button,
		})
		worldsLabel.Position = UDim2.fromOffset(12, 92)
		worldsLabel.ZIndex = 3
		button.Parent = list
		local parts: RowParts = {
			button = button,
			surface = surface,
			title = title,
			money = money,
			info = info,
			worlds = worldsLabel,
			userId = 0,
			signature = "",
		}
		button.Activated:Connect(function()
			if parts.userId ~= 0 then
				selectedUserId = parts.userId
				offlineSelected = false
				render()
			end
		end)
		return parts
	end

	-- The last list entry: OFFLINE USER / BANS.
	local offlineEntry = AdminWidgets.chip({
		text = "OFFLINE USER / BANS",
		color = "red",
		width = 1,
		height = OFFLINE_ROW_HEIGHT,
		fit = fit,
		layoutOrder = 10_000,
		parent = list,
		onActivated = function()
			offlineSelected = true
			render()
		end,
	})
	AdminWidgets.sized(offlineEntry.button, 1, OFFLINE_ROW_HEIGHT, fit, true)

	-- Right: detail column ------------------------------------------------------------------------
	local detail = AdminWidgets.well("Detail", page, 12)
	detail.Position = UDim2.fromOffset(LIST_WIDTH + COLUMN_GAP, 0)
	detail.Size = UDim2.new(1, -(LIST_WIDTH + COLUMN_GAP), 1, 0)

	-- Player detail.
	local playerDetail = AdminWidgets.column("PlayerDetail", detail, 12, 1)
	local header = AdminWidgets.panel("Header", playerDetail, 1)
	local headerTitle = AdminWidgets.label({
		name = "Name",
		text = "",
		size = UDim2.new(1, 0, 0, 38),
		textSize = 32,
		font = "title",
		layoutOrder = 1,
		parent = header,
	})
	local headerMoney = AdminWidgets.label({
		name = "Money",
		text = "",
		size = UDim2.new(1, 0, 0, 30),
		textSize = 24,
		font = "number",
		rich = true,
		layoutOrder = 2,
		parent = header,
	})
	local headerInfo = AdminWidgets.label({
		name = "Info",
		text = "",
		size = UDim2.fromScale(1, 0),
		textSize = 20,
		color = Neutral.TextDim,
		wrap = true,
		layoutOrder = 3,
		parent = header,
	})
	headerInfo.AutomaticSize = Enum.AutomaticSize.Y
	local groupsHost = AdminWidgets.column("Groups", playerDetail, 12, 2)

	-- Offline detail.
	local offlineDetail = AdminWidgets.column("OfflineDetail", detail, 12, 2)
	offlineDetail.Visible = false
	local offlineHeader = AdminWidgets.panel("OfflineHeader", offlineDetail, 1)
	AdminWidgets.label({
		text = "Offline user",
		size = UDim2.new(1, 0, 0, 38),
		textSize = 32,
		font = "title",
		layoutOrder = 1,
		parent = offlineHeader,
	})
	AdminWidgets.label({
		text = "Type a Roblox UserId to ban or unban someone who is not in this server. Bans apply to every server (Roblox Ban API).",
		size = UDim2.fromScale(1, 0),
		textSize = 20,
		color = Neutral.TextDim,
		wrap = true,
		layoutOrder = 2,
		parent = offlineHeader,
	}).AutomaticSize =
		Enum.AutomaticSize.Y
	local userIdBox = StudUI.textBox({
		placeholder = "UserId (numbers)",
		maxLength = 16,
		textSize = 28,
		size = UDim2.new(1, 0, 0, 60),
		layoutOrder = 3,
		parent = offlineHeader,
	})
	AdminWidgets.sized(userIdBox.frame, 1, 60, fit, true)
	local userIdNote = AdminWidgets.label({
		text = "",
		size = UDim2.new(1, 0, 0, 26),
		textSize = 18,
		color = Neutral.TextDim,
		layoutOrder = 4,
		parent = offlineHeader,
	})
	userIdBox.instance:GetPropertyChangedSignal("Text"):Connect(function()
		local digits = string.gsub(userIdBox.instance.Text, "%D", "")
		if digits ~= userIdBox.instance.Text then
			userIdBox.instance.Text = digits
			return
		end
		local value = tonumber(digits)
		if value ~= nil and value >= 1 and value <= AdminConfig.Limits.MaxUserId and value == math.floor(value) then
			typedUserId = value
			userIdNote.Text = `Target: user {math.floor(value)}`
		else
			typedUserId = nil
			userIdNote.Text = if digits == "" then "" else "Not a valid UserId"
		end
		for _, form in forms do
			form.refresh()
		end
	end)
	local offlineForms = AdminWidgets.column("OfflineForms", offlineDetail, 12, 2)
	local bansPanel = AdminWidgets.panel("RecentBans", offlineDetail, 3)
	AdminWidgets.label({
		text = "Bans issued this session",
		size = UDim2.new(1, 0, 0, 34),
		textSize = 28,
		font = "title",
		layoutOrder = 0,
		parent = bansPanel,
	})
	local bansEmpty = AdminWidgets.label({
		text = "No bans yet.",
		size = UDim2.new(1, 0, 0, 26),
		textSize = 20,
		color = Neutral.TextDim,
		layoutOrder = 1,
		parent = bansPanel,
	})

	-- Targets ---------------------------------------------------------------------------------------
	local function playerTarget(): CommandForm.Target?
		local id = selectedUserId
		if id == nil then
			return nil
		end
		local row = AdminClient.player(id)
		if row == nil then
			return nil
		end
		return { userId = row.userId, label = `{row.displayName} (@{row.name}, {row.userId})` }
	end
	local function offlineTarget(): CommandForm.Target?
		local id = typedUserId
		if id == nil then
			return nil
		end
		local online = AdminClient.player(id)
		return {
			userId = id,
			label = if online ~= nil then `{online.displayName} (@{online.name}, {id})` else `user {math.floor(id)}`,
		}
	end

	-- Forms -----------------------------------------------------------------------------------------
	local function rebuildForms(catalog: { CommandInfo })
		for _, form in forms do
			form.Destroy()
		end
		table.clear(forms)
		for _, child in groupsHost:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		for _, child in offlineForms:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		-- Bucket the Players-tab commands by group (catalogue order is server order).
		local buckets: { { CommandInfo } } = {}
		for index = 1, MORE_GROUP do
			buckets[index] = {}
		end
		local anyUser: { CommandInfo } = {}
		for _, info in catalog do
			if info.tab == "Players" then
				table.insert(buckets[GROUP_OF[info.name] or MORE_GROUP], info)
				if info.target == "AnyUser" then
					table.insert(anyUser, info)
				end
			end
		end
		for index = 1, MORE_GROUP do
			local bucket = buckets[index]
			if #bucket == 0 then
				continue
			end
			table.sort(bucket, function(a: CommandInfo, b: CommandInfo): boolean
				if a.order ~= b.order then
					return a.order < b.order
				end
				return a.label < b.label
			end)
			local title = if index == MORE_GROUP then "More" else GROUPS[index].title
			local section = AdminWidgets.column(`Group_{title}`, groupsHost, 8, index)
			StudUI.sectionLabel(title, 30).Parent = section
			local compactRow = AdminWidgets.wrapRow("Quick", section, 12, 1)
			local formOrder = 1
			for _, info in bucket do
				local isCompact = next(info.args) == nil
				local form = CommandForm.new({
					info = info,
					parent = if isCompact then compactRow else section,
					ask = options.ask,
					setStatus = options.setStatus,
					getTarget = playerTarget,
					fit = fit,
					layoutOrder = formOrder,
					compactWidth = COMPACT_WIDTH,
				})
				formOrder += 1
				table.insert(forms, form)
			end
			if #compactRow:GetChildren() <= 2 then
				compactRow:Destroy() -- only its layout + padding: no compact commands here
			end
		end
		-- Offline: every AnyUser command (Ban, Unban, ...) against the typed user id.
		for index, info in anyUser do
			local form = CommandForm.new({
				info = info,
				parent = offlineForms,
				ask = options.ask,
				setStatus = options.setStatus,
				getTarget = offlineTarget,
				fit = fit,
				layoutOrder = index,
			})
			table.insert(forms, form)
		end
	end

	-- Recent bans -----------------------------------------------------------------------------------
	local function makeBanRow(index: number): BanRowParts
		local frame = Create.new("Frame", {
			Name = `Ban{index}`,
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 10 + index,
			Visible = false,
			Children = {
				Create.new("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					Padding = UDim.new(0, 10),
					VerticalAlignment = Enum.VerticalAlignment.Center,
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
			},
		}) :: Frame
		local text = AdminWidgets.label({
			text = "",
			size = UDim2.new(1, -170, 0, 0),
			textSize = 20,
			wrap = true,
			layoutOrder = 1,
			parent = frame,
		})
		text.AutomaticSize = Enum.AutomaticSize.Y
		local parts: BanRowParts
		local unban = AdminWidgets.chip({
			text = "UNBAN",
			color = "green",
			solid = true,
			width = 150,
			height = 48,
			fit = fit,
			layoutOrder = 2,
			parent = frame,
			onActivated = function()
				local userId = parts.userId
				if userId == 0 then
					return
				end
				options.ask({
					title = "Unban?",
					message = `Unban user {userId}? They can join every server again.`,
					confirmText = "UNBAN",
					color = "green",
					onConfirm = function()
						if not AdminClient.send("Unban", { userId = userId }) then
							options.setStatus("Too fast - wait a moment", false)
						end
					end,
				})
			end,
		})
		frame.Parent = bansPanel
		parts = { frame = frame, text = text, unban = unban, userId = 0 }
		return parts
	end

	local function renderBans(bans: { RecentBan })
		local parts: { string } = {}
		for _, ban in bans do
			table.insert(parts, `{ban.userId}:{ban.time}`)
		end
		local signature = table.concat(parts, ",")
		if signature == banSignature then
			return
		end
		banSignature = signature
		local shown = math.min(#bans, MAX_BAN_ROWS)
		-- Newest first.
		for index = 1, shown do
			local ban = bans[#bans - index + 1]
			local row = banRows[index]
			if row == nil then
				row = makeBanRow(index)
				banRows[index] = row
			end
			row.userId = ban.userId
			local reason = if ban.reason ~= "" then ban.reason else "no reason"
			row.text.Text =
				`{ban.name} ({ban.userId}) · {AdminWidgets.formatBanLength(ban.durationSeconds)} · {reason} · by {ban.byName} at {AdminWidgets.formatUtc(
					ban.time
				)} UTC`
			row.frame.Visible = true
		end
		for index = shown + 1, #banRows do
			banRows[index].frame.Visible = false
			banRows[index].userId = 0
		end
		bansEmpty.Visible = shown == 0
	end

	-- Rendering ---------------------------------------------------------------------------------------
	local function renderHeader()
		local id = selectedUserId
		local row = if id ~= nil then AdminClient.player(id) else nil
		if row == nil then
			headerTitle.Text = if id ~= nil then `User {id} is not in this server` else "Pick a player"
			headerMoney.Text = ""
			headerInfo.Text = "Pick a player on the left (or OFFLINE USER / BANS)."
			return
		end
		local badgeText = badges(row)
		headerTitle.Text = `{row.displayName} (@{row.name}) · {row.userId}`
			.. (if badgeText ~= "" then ` · {badgeText}` else "")
		headerMoney.Text =
			`<font color="#78F046">{NumberFormat.moneyFull(row.cash)}</font>  ·  <font color="#CE82FF">{NumberFormat.commas(
				row.gems
			)} gems</font>`
		headerInfo.Text = `Area {row.area} · Rebirths {NumberFormat.commas(row.rebirths)} · Earned {NumberFormat.money(
			row.totalEarned
		)} · Ping {pingText(row.pingMs)} · Session {AdminWidgets.formatSeconds(row.sessionSeconds)}` .. (if row.device
				~= ""
			then ` · {row.device}`
			else "") .. ` · Save: {row.saving}`
		local worlds = worldText(AdminClient.playerWorlds(row.userId), true)
		if worlds ~= "" then
			headerInfo.Text ..= `\n{worlds}`
		end
	end

	local function renderRows(players: { PlayerRow })
		local count = math.min(#players, MAX_ROWS)
		for index = 1, count do
			local row = players[index]
			local parts = rows[index]
			if parts == nil then
				parts = makeRow(index)
				rows[index] = parts
			end
			local badgeText = badges(row)
			local worlds = worldText(AdminClient.playerWorlds(row.userId), false)
			-- Only rows whose visible text changed are rewritten.
			local signature = string.format(
				"%d|%s|%s|%s|%.17g|%.17g|%d|%.17g|%d|%s|%s",
				math.floor(row.userId),
				row.name,
				row.displayName,
				badgeText,
				row.cash,
				row.gems,
				math.floor(row.area),
				row.rebirths,
				math.floor(row.pingMs),
				row.saving,
				worlds
			)
			if signature ~= parts.signature then
				parts.signature = signature
				parts.userId = row.userId
				local suffix = if badgeText ~= "" then `  <font size="16" color="#FFC832">{badgeText}</font>` else ""
				parts.title.Text = `{row.displayName} <font size="18" color="#C4CCDE">@{row.name}</font>{suffix}`
				parts.money.Text =
					`<font color="#78F046">{NumberFormat.money(row.cash)}</font> · <font color="#CE82FF">{NumberFormat.short(
						row.gems
					)} gems</font>`
				parts.info.Text =
					`Area {row.area} · {NumberFormat.short(row.rebirths)} reb · {pingText(row.pingMs)} · {row.saving}`
				parts.worlds.Text = if worlds ~= "" then worlds else "Nuke Town only"
			end
			parts.button.Visible = true
			paintRow(parts)
		end
		for index = count + 1, #rows do
			rows[index].button.Visible = false
			rows[index].userId = 0
			rows[index].signature = ""
		end
		offlineEntry.setSelected(offlineSelected)
	end

	render = function()
		local state = AdminClient.state
		if state == nil then
			return
		end
		-- Forms: rebuild when the set of commands changed (registration / Studio flag).
		local names: { string } = {}
		for _, info in state.catalog do
			if info.tab == "Players" then
				table.insert(names, info.name)
			end
		end
		local signature = table.concat(names, ",")
		if signature ~= catalogSignature then
			catalogSignature = signature
			rebuildForms(state.catalog)
		end
		renderRows(state.players)
		playerDetail.Visible = not offlineSelected
		offlineDetail.Visible = offlineSelected
		if offlineSelected then
			renderBans(state.recentBans)
		else
			renderHeader()
		end
		for _, form in forms do
			form.refresh()
		end
	end

	local function first(): GuiObject?
		for _, parts in rows do
			if parts.button.Visible and parts.userId == selectedUserId and not offlineSelected then
				return parts.button
			end
		end
		local firstRow = rows[1]
		if firstRow ~= nil and firstRow.button.Visible then
			return firstRow.button
		end
		return offlineEntry.button
	end

	return {
		frame = page,
		render = render,
		first = first,
		topRow = function(): { GuiObject }
			local top: { GuiObject } = {}
			local row = first()
			if row ~= nil then
				table.insert(top, row)
			end
			for _, form in forms do
				local control = form.first()
				if control ~= nil and control:IsDescendantOf(playerDetail) and playerDetail.Visible then
					table.insert(top, control)
					break
				end
			end
			return top
		end,
	}
end

return PlayersTab
