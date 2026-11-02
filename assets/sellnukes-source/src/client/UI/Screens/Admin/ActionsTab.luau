--!strict
--[[
	ActionsTab — the generic admin panel page for the ECONOMY, SERVER, WORLD and NEW PLAYER tabs
	(spec §14). It renders EVERY catalogue command whose `tab` matches through CommandForm, so
	commands added later by other systems (AdminService.registerCommand: pets, attack, Harvest
	Feast, ...) show up here with working controls and no panel change.

	Per tab, above the commands, a live info block:
		Economy    Server 2x Cash ON / OFF + time left (stats.serverBoostSeconds), saving status,
		           a note that test receipts are Studio-only
		Server     time of day (stats.timeOfDay) + the restart countdown (stats.shutdownAt vs the
		           server clock; reason from the replicated AdminShutdownReason attribute);
		           the Announce form gets AdminConfig.AnnouncePresets chips that fill its text;
		           for a title holder (owner R73 / R74: DEVELOPER, ...) the "MY TITLE TAG: ON / OFF"
		           chip (the ordinary SetSetting("showTitle", on) intent — the server's allowlist
		           validates it and PlayerTitleService mirrors it into the TitleHidden attribute it
		           paints from); the RETURN NOTIFICATIONS block (owner R122,
		           Screens/Admin/NotifySection: kill switch / kinds live + the NotifyStatus text)
		World      the LOCAL "Debug overlay" toggle (AdminDebugState → AdminOverlayScreen perf HUD;
		           client only, nothing is sent to the server)
		NewPlayer  whether YOU are in New Player Mode (server-set NewPlayerMode attribute) and what
		           the mode does (Shared/Util/NewPlayerMode.Copy)
	When a tab has Player-target commands (World: Rebuild Plot / Replay Build-In) a target picker
	row (player chips) sits above the forms; it defaults to you.

	Performance: forms are rebuilt only when the tab's set of command names changes; `render`
	otherwise refreshes run buttons and a few labels. The countdown texts tick on ONE 1 Hz thread
	that exists only while this page is the visible tab (no per-frame work).

	Security: display + intents only (CommandForm sends AdminCommand; the server re-authorises
	and re-validates every call).

	Connects to: Screens/Admin/{AdminClient, AdminWidgets, CommandForm, AdminDebugState, NotifySection},
	Shared/Config/AdminConfig, Shared/Util/NewPlayerMode. Mounted by
	Screens/Admin/AdminPanelScreen (one instance per tab).

	Example:
		local page = ActionsTab.new(table.clone(pageOptions) with tab = "Server")
		page.frame.Visible = true
		page.render()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AdminClient = require(script.Parent.AdminClient)
local AdminConfig = require(ReplicatedStorage.Shared.Config.AdminConfig)
local AdminDebugState = require(script.Parent.AdminDebugState)
local AdminWidgets = require(script.Parent.AdminWidgets)
local CommandForm = require(script.Parent.CommandForm)
local Create = require(script.Parent.Parent.Parent.Create)
local PlayerTitlesConfig = require(ReplicatedStorage.Shared.Config.PlayerTitlesConfig)
local NewPlayerMode = require(ReplicatedStorage.Shared.Util.NewPlayerMode)
local NotifySection = require(script.Parent.NotifySection)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

type CommandInfo = AdminConfig.CommandInfo

local ActionsTab = {}

local Neutral = UIStyleConfig.Neutral

-- Layout (design px at 1080p).
local COMPACT_WIDTH = 300
local TARGET_CHIP_WIDTH = 240
local TARGET_CHIP_HEIGHT = 50
local MAX_TARGET_CHIPS = 24

-- Tab subtitles (what the tab is for).
local SUBTITLES: { [string]: string } = {
	Economy = "Server-wide money switches and Studio purchase tests.",
	Server = "Talk to everyone, change the sky, add codes, restart the server.",
	World = "Rebuild plots, preview the build-in animation, debug overlays.",
	NewPlayer = "Play your own session as a brand-new player on a throw-away profile.",
}

local localPlayer = Players.LocalPlayer

--[[
	Builds one actions page.
	@param options the panel's PageOptions; `tab` = the AdminConfig tab key to render
	@return Page { frame, render, first, topRow }
]]
function ActionsTab.new(options: AdminWidgets.PageOptions): AdminWidgets.Page
	local tab = options.tab or "Server"
	local fit = options.fitScale
	local page = Create.new("Frame", {
		Name = `Actions_{tab}`,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(options.width, options.height),
		Visible = false,
		Parent = options.parent,
	}) :: Frame
	local well = AdminWidgets.well("Content", page, 14)
	well.Size = UDim2.fromScale(1, 1)

	-- State ---------------------------------------------------------------------------------------
	local forms: { CommandForm.Form } = {}
	local catalogSignature = ""
	local targetUserId: number? = localPlayer.UserId
	local needsTarget = false
	local ticking = false

	-- Info block ----------------------------------------------------------------------------------
	local infoPanel = AdminWidgets.panel("Info", well, 1)
	AdminWidgets.label({
		text = SUBTITLES[tab] or "",
		size = UDim2.fromScale(1, 0),
		textSize = 22,
		color = Neutral.TextDim,
		wrap = true,
		layoutOrder = 1,
		parent = infoPanel,
	}).AutomaticSize =
		Enum.AutomaticSize.Y
	local infoLine = AdminWidgets.label({
		name = "Live",
		text = "",
		size = UDim2.fromScale(1, 0),
		textSize = 28,
		font = "title",
		wrap = true,
		rich = true,
		layoutOrder = 2,
		parent = infoPanel,
	})
	infoLine.AutomaticSize = Enum.AutomaticSize.Y
	local infoNote = AdminWidgets.label({
		name = "Note",
		text = "",
		size = UDim2.fromScale(1, 0),
		textSize = 20,
		color = Neutral.TextDim,
		wrap = true,
		layoutOrder = 3,
		parent = infoPanel,
	})
	infoNote.AutomaticSize = Enum.AutomaticSize.Y

	-- World: the local debug overlay toggle.
	local debugChip: AdminWidgets.Chip? = nil
	-- Server tab: the R73 / R74 title tag chip (nil elsewhere / built below).
	local titleChip: AdminWidgets.Chip? = nil
	if tab == "World" then
		local row = AdminWidgets.wrapRow("Debug", infoPanel, 12, 4)
		local chip = AdminWidgets.chip({
			text = "DEBUG OVERLAY: OFF",
			color = "teal",
			width = 340,
			height = 56,
			fit = fit,
			layoutOrder = 1,
			parent = row,
			onActivated = function()
				AdminDebugState.set(not AdminDebugState.isOn())
			end,
		})
		local function paint(on: boolean)
			chip.setText(if on then "DEBUG OVERLAY: ON" else "DEBUG OVERLAY: OFF")
			chip.setSelected(on)
		end
		AdminDebugState.Changed:Connect(paint)
		paint(AdminDebugState.isOn())
		debugChip = chip
		AdminWidgets.label({
			text = "Local only: FPS, ping, memory and server health on your screen. Nothing is sent to the server.",
			size = UDim2.new(1, -360, 0, 0),
			textSize = 18,
			color = Neutral.TextDim,
			wrap = true,
			layoutOrder = 2,
			parent = row,
		}).AutomaticSize =
			Enum.AutomaticSize.Y
	end

	-- Server: the holder's own title tag ON / OFF (owner R73 / R74; shown only with a title).
	if tab == "Server" then
		local row = AdminWidgets.wrapRow("TitleTag", infoPanel, 12, 5)
		local chip = AdminWidgets.chip({
			text = "MY TITLE TAG: ON",
			color = "yellow",
			width = 340,
			height = 56,
			fit = fit,
			layoutOrder = 1,
			parent = row,
			onActivated = function()
				-- Intent only: show it unless it is shown now (the server validates + saves).
				local shown = localPlayer:GetAttribute(PlayerTitlesConfig.HiddenAttr) ~= true
				Remotes.event("SetSetting"):FireServer(PlayerTitlesConfig.SettingKey, not shown)
			end,
		})
		local note = AdminWidgets.label({
			text = "Your title tag (e.g. DEVELOPER) that other players see over your head + your chat tag ([DEV]). Saved on your profile.",
			size = UDim2.new(1, -360, 0, 0),
			textSize = 18,
			color = Neutral.TextDim,
			wrap = true,
			layoutOrder = 2,
			parent = row,
		})
		note.AutomaticSize = Enum.AutomaticSize.Y
		-- Paints from the server-set attributes (event-driven).
		local function paintTitleTag()
			local title = localPlayer:GetAttribute(PlayerTitlesConfig.Attr)
			row.Visible = type(title) == "string" and title ~= ""
			local shown = localPlayer:GetAttribute(PlayerTitlesConfig.HiddenAttr) ~= true
			chip.setText(if shown then "MY TITLE TAG: ON" else "MY TITLE TAG: OFF")
			chip.setSelected(shown)
		end
		localPlayer:GetAttributeChangedSignal(PlayerTitlesConfig.Attr):Connect(paintTitleTag)
		localPlayer:GetAttributeChangedSignal(PlayerTitlesConfig.HiddenAttr):Connect(paintTitleTag)
		paintTitleTag()
		titleChip = chip
	end

	-- Server: the R122 return notifications block (live switches + NotifyStatus; NotifySection).
	if tab == "Server" then
		NotifySection.new({ parent = infoPanel, layoutOrder = 6, fit = fit })
	end

	-- Target picker (only when the tab has player-target commands) ---------------------------------
	local targetPanel = AdminWidgets.panel("Target", well, 2)
	targetPanel.Visible = false
	AdminWidgets.label({
		text = "Target player",
		size = UDim2.new(1, 0, 0, 30),
		textSize = 24,
		font = "title",
		layoutOrder = 1,
		parent = targetPanel,
	})
	local targetRow = AdminWidgets.wrapRow("Chips", targetPanel, 10, 2)
	local targetChips: { { chip: AdminWidgets.Chip, userId: number } } = {}
	local targetSignature = ""

	local function pickTarget(): CommandForm.Target?
		local id = targetUserId
		if id == nil then
			return nil
		end
		local row = AdminClient.player(id)
		if row == nil then
			return nil
		end
		return { userId = row.userId, label = `{row.displayName} (@{row.name})` }
	end

	local function renderTargets()
		if not needsTarget then
			targetPanel.Visible = false
			return
		end
		targetPanel.Visible = true
		local state = AdminClient.state
		local players = if state ~= nil then state.players else {}
		local parts: { string } = {}
		for _, row in players do
			table.insert(parts, `{row.userId}:{row.displayName}`)
		end
		local signature = table.concat(parts, ",")
		if signature ~= targetSignature then
			targetSignature = signature
			local count = math.min(#players, MAX_TARGET_CHIPS)
			for index = 1, count do
				local row = players[index]
				local item = targetChips[index]
				if item == nil then
					local slot = { chip = (nil :: any) :: AdminWidgets.Chip, userId = 0 }
					slot.chip = AdminWidgets.chip({
						text = "",
						color = "blue",
						width = TARGET_CHIP_WIDTH,
						height = TARGET_CHIP_HEIGHT,
						fit = fit,
						layoutOrder = index,
						parent = targetRow,
						onActivated = function()
							targetUserId = slot.userId
							options.refresh()
						end,
					})
					targetChips[index] = slot
					item = slot
				end
				local chosen = item :: { chip: AdminWidgets.Chip, userId: number }
				chosen.userId = row.userId
				chosen.chip.setText(
					if row.userId == localPlayer.UserId then `{row.displayName} (you)` else row.displayName
				)
				chosen.chip.button.Visible = true
			end
			for index = count + 1, #targetChips do
				targetChips[index].chip.button.Visible = false
				targetChips[index].userId = 0
			end
		end
		for _, item in targetChips do
			item.chip.setSelected(item.userId ~= 0 and item.userId == targetUserId)
		end
	end

	-- Forms ---------------------------------------------------------------------------------------
	local formsHost = AdminWidgets.column("Commands", well, 14, 10)
	local function rebuildForms(commands: { CommandInfo })
		for _, form in forms do
			form.Destroy()
		end
		table.clear(forms)
		for _, child in formsHost:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		needsTarget = false
		local compactRow = AdminWidgets.wrapRow("Quick", formsHost, 12, 1)
		for index, info in commands do
			if info.target ~= "None" then
				needsTarget = true
			end
			local isCompact = next(info.args) == nil
			local presets: { [string]: { string } }? = nil
			if info.name == "Announce" then
				presets = { text = AdminConfig.AnnouncePresets :: any }
			end
			local form = CommandForm.new({
				info = info,
				parent = if isCompact then compactRow else formsHost,
				ask = options.ask,
				setStatus = options.setStatus,
				getTarget = pickTarget,
				textPresets = presets,
				fit = fit,
				layoutOrder = 1 + index,
				compactWidth = COMPACT_WIDTH,
			})
			table.insert(forms, form)
		end
		if #compactRow:GetChildren() <= 2 then
			compactRow:Destroy()
		end
		if #commands == 0 then
			AdminWidgets.label({
				text = "No commands on this tab yet.",
				size = UDim2.new(1, 0, 0, 30),
				textSize = 22,
				color = Neutral.TextDim,
				layoutOrder = 1,
				parent = formsHost,
			})
		end
	end

	-- Info texts ----------------------------------------------------------------------------------
	-- Rewrites the live info line(s) for this tab (cheap; called by render and the 1 Hz ticker).
	local function renderInfo()
		local state = AdminClient.state
		if tab == "Economy" then
			local left = 0
			local saving = false
			if state ~= nil then
				left = state.stats.serverBoostSeconds - (os.clock() - state.receivedAt)
				saving = state.stats.savingEnabled
			end
			infoLine.Text = if left > 0
				then `Server 2x Cash: <font color="#78F046">ON</font> · {AdminWidgets.formatClock(left)} left`
				else "Server 2x Cash: OFF"
			infoNote.Text = `Saving: {if saving then "enabled" else "OFF (in-memory server)"}`
				.. (
					if state ~= nil and state.isStudio
						then " · Studio: Test Receipt runs the REAL receipt path for you."
						else " · Test receipts only work in Studio."
				)
		elseif tab == "Server" then
			local hour = if state ~= nil then state.stats.timeOfDay else 0
			local restartAt = if state ~= nil then state.stats.shutdownAt else 0
			local now = Workspace:GetServerTimeNow()
			local restart = "no restart scheduled"
			if restartAt > 0 then
				local remaining = restartAt - now
				restart = if remaining > 0
					then `<font color="#FF4646">RESTART in {AdminWidgets.formatClock(remaining)}</font>`
					else `<font color="#FF4646">RESTARTING NOW</font>`
			end
			infoLine.Text = `Time of day {AdminWidgets.formatHour(hour)} · {restart}`
			local reason = ReplicatedStorage:GetAttribute(AdminConfig.Attributes.ShutdownReason)
			infoNote.Text = if restartAt > 0
					and type(reason) == "string"
					and reason ~= ""
				then `Restart reason: {reason}`
				else "Announcements and restart reasons are text-filtered for everyone."
		elseif tab == "World" then
			infoLine.Text = "Plot tools"
			infoNote.Text = "Rebuild and Replay act on the target player's plot."
		elseif tab == "NewPlayer" then
			local active = NewPlayerMode.isActive(localPlayer)
			infoLine.Text = if active
				then `<font color="#FFC832">YOU ARE IN {NewPlayerMode.Copy.Badge}</font> · {NewPlayerMode.Copy.BadgeDetail}`
				else "New Player Mode: OFF"
			infoNote.Text = if active
				then "Robux purchases are off and your analytics are kept out of player metrics. EXIT brings your real profile back exactly as you left it."
				else "PLAY AS NEW PLAYER saves your real profile first, then gives you a brand-new throw-away profile (area 1, $0, tutorial). Nothing is saved, Robux purchases are refused and analytics are diverted. Leaving the game also ends it."
		end
	end

	if tab == "NewPlayer" then
		localPlayer:GetAttributeChangedSignal(NewPlayerMode.Attribute):Connect(function()
			renderInfo()
			for _, form in forms do
				form.refresh()
			end
		end)
	end

	-- One 1 Hz ticker while this page is visible (countdowns).
	local function startTicker()
		if ticking or (tab ~= "Economy" and tab ~= "Server") then
			return
		end
		ticking = true
		task.spawn(function()
			while options.isActive() do
				renderInfo()
				task.wait(1)
			end
			ticking = false
		end)
	end

	-- Render ----------------------------------------------------------------------------------------
	local function render()
		local commands = AdminClient.commandsFor(tab)
		local names: { string } = {}
		for _, info in commands do
			table.insert(names, info.name)
		end
		local signature = table.concat(names, ",")
		if signature ~= catalogSignature then
			catalogSignature = signature
			rebuildForms(commands)
		end
		renderTargets()
		renderInfo()
		for _, form in forms do
			form.refresh()
		end
		if options.isActive() then
			startTicker()
		end
	end

	local function first(): GuiObject?
		if debugChip ~= nil then
			return debugChip.button
		end
		local title = titleChip
		local held = localPlayer:GetAttribute(PlayerTitlesConfig.Attr)
		if title ~= nil and type(held) == "string" and held ~= "" then
			return title.button
		end
		if needsTarget then
			for _, item in targetChips do
				if item.chip.button.Visible and item.userId == targetUserId then
					return item.chip.button
				end
			end
		end
		for _, form in forms do
			local control = form.first()
			if control ~= nil then
				return control
			end
		end
		return nil
	end

	return {
		frame = page,
		render = render,
		first = first,
		topRow = function(): { GuiObject }
			local control = first()
			return if control ~= nil then { control } else {}
		end,
	}
end

return ActionsTab
