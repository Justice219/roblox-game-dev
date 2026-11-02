--!strict
--[[
	Teleport — the teleport list (reference 16) with WORLD TABS (owner R57 World 2, spec §4.3):
	NUKE TOWN | DINO VALLEY (one tab per WorldsConfig.Order world; Worlds/WorldTabBar).

	Each OPEN world tab lists (your plot is always FREE, lead decision 2026-10-30):
		Hub / Base Camp                       [GO]   that world's spawn
		1  Garage Lab                         [GO]   own plot area 1
		2  Nuke Stand      7 / 8 purchases    (lock) [=====---]   <- previous area's progress
	Players' plots (the Teleporter game pass perk; in every world):
		with the pass:    Plot #3  · Sam                [GO]
		without the pass: one locked row with the green Robux button (PromptPass "Teleporter";
		                  owner R122: a tagged BUY behind UI/PurchaseGuard — never the default
		                  cursor, and the press that opened the screen never buys)
	A LOCKED world tab shows lock art, "Reach BoomDash Delivery to unlock!" and the progress bar of
	the unlock rule's previous area; a world switched off by the admin kill switch shows
	"Closed for a quick fix — back soon!". Neither ever sends anything.

	Intents (the server re-validates everything: unlock, kill switch, ownership, pass, area):
		Nuke Town while IN Nuke Town  -> the legacy instant remotes TeleportHub / TeleportArea(n) /
		                                 TeleportPlot(n) (unchanged behaviour)
		any other combination          -> WorldClient.travel(worldId, "spawn" | "area" | "plot",
		                                 index, "menu") = TravelWorld (warp overlay)
	Other players' plots come from that world's plot folder (Workspace.Worlds.<id>.Plots, else the
	Nuke Town plots: world plot i belongs to main plot i's owner, spec §5).

	Data: ClientState.profile (tycoon, passes, worlds) + WorldClient (current world, unlocks, kill
	switch) + Workspace plots; pages build lazily per world and refresh on open, on relevant
	profile pushes and on WorldClient.StateChanged while open (event-driven).

	Gamepad: the screen opens on the CURRENT world's tab, default selection = its first GO; LB / RB
	(Q / E) switch tabs; the tab row links Down into the list; B / X / the red X close.

	Balances (owner R60: "the money in each area doesn't transfer"): every open world's tab wears
	its own balance (WorldTabBar balance pill: Nuke Town cash, Dino Valley Bones), refreshed on the
	cash / worldCash pushes while the screen is open; the HUD shows only the current world's.

	Connects to: Kit/StudUI, UI/ScreenManager, Client/ClientState, Worlds/{WorldClient,
	WorldClientLogic, WorldTabBar}, Shared/Tycoon/TycoonLogic, Shared/Config/{WorldsConfig,
	WorldClientConfig, MonetizationConfig, TycoonClientConfig}, Shared/Net/Remotes,
	Tycoon/TycoonContract (plot attributes), Platform/GamepadNav.

	Example: ScreenManager.open("Teleport") ; ScreenManager.open("Teleport", { world = "dino" })
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Contract = require(script.Parent.Parent.Parent.Tycoon.TycoonContract)
local Create = require(script.Parent.Parent.Create)
local GamepadNav = require(script.Parent.Parent.Parent.Platform.GamepadNav)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
-- Owner R122 purchase-focus hygiene (opening-press guard, BUY tag, safe default selection).
local PurchaseGuard = require(script.Parent.Parent.PurchaseGuard)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Widgets.StudWindow)
local TycoonClientConfig = require(ReplicatedStorage.Shared.Config.TycoonClientConfig)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)
local WorldClient = require(script.Parent.Parent.Parent.Worlds.WorldClient)
local WorldClientConfig = require(ReplicatedStorage.Shared.Config.WorldClientConfig)
local WorldClientLogic = require(script.Parent.Parent.Parent.Worlds.WorldClientLogic)
local WorldTabBar = require(script.Parent.Parent.Parent.Worlds.WorldTabBar)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local NAME = "Teleport"
local ROW_HEIGHT = 112
local PASS_KEY: MonetizationConfig.PassKey = "Teleporter"
local PLOT_REMOTE = "TeleportPlot"
local MAIN = WorldsConfig.MAIN
-- LayoutOrder of the first players'-plot row (own rows come before).
local PLOT_ORDER = 1000
local WINDOW_SIZE = Vector2.new(940, 820)

type AreaRow = {
	area: number, -- 0 = the world's spawn (Hub / Base Camp)
	go: StudUI.Button,
	lockGroup: Frame,
	progressText: TextLabel,
	bar: StudUI.ProgressBar,
}

-- One world's page (built lazily the first time its tab shows).
type Page = {
	worldId: string,
	frame: Frame, -- the open list (rows)
	rows: { AreaRow },
	first: GuiObject?, -- the spawn row's GO (default selection)
	offerRow: Frame,
	buyPass: StudUI.Button,
	plotRows: { Frame },
}

-- True when the player owns the Teleporter pass (server-synced profile cache).
local function ownsPass(profile: any): boolean
	return type(profile) == "table" and type(profile.passes) == "table" and profile.passes[PASS_KEY] == true
end

-- True when the server publishes the TeleportPlot remote (B5).
local function plotRemoteReady(): boolean
	return table.find(Remotes.EventNames :: { string }, PLOT_REMOTE) ~= nil
end

-- The tycoon state of a world ("main": profile.tycoon; others: profile.worlds.<id>.tycoon), or nil.
local function tycoonOf(worldId: string): any
	local profile: any = ClientState.profile
	if worldId == MAIN then
		return if type(profile) == "table" and type(profile.tycoon) == "table" then profile.tycoon else nil
	end
	local world = ClientState.world(worldId)
	return if world ~= nil and type(world.tycoon) == "table" then world.tycoon else nil
end

--[[
	The row icon of area `index` in a world: Nuke Town "Area01".., other worlds
	"<World>Area01" (e.g. "DinoArea01") when the icon pipeline has it, else the world tab icon.
]]
local function areaIcon(worldId: string, index: number): string
	if worldId == MAIN then
		return string.format("Area%02d", index)
	end
	local key = string.upper(string.sub(worldId, 1, 1)) .. string.sub(worldId, 2) .. string.format("Area%02d", index)
	if StudUI.hasIcon(key) then
		return key
	end
	return WorldClientLogic.style(worldId).icon
end

-- One dark stud row with an icon, a title and a right-side slot.
local function makeRow(parent: Instance, order: number, title: string, icon: string): (Frame, Frame)
	local row = Create.new("Frame", {
		Name = `Row{order}`,
		Size = UDim2.new(1, -8, 0, ROW_HEIGHT),
		BackgroundColor3 = UIStyleConfig.Neutral.Well,
		LayoutOrder = order,
		Parent = parent,
		Children = { Create.new("UICorner", { CornerRadius = UDim.new(0, 8) }) },
	}) :: Frame
	StudWindow.edge(row, 4)
	local glyph = StudUI.icon(icon, ROW_HEIGHT - 12, 2)
	glyph.Position = UDim2.fromOffset(10, 6)
	glyph.Parent = row
	StudUI.text({
		text = title,
		textSize = 46,
		scaled = true,
		align = Enum.TextXAlignment.Left,
		position = UDim2.fromOffset(ROW_HEIGHT + 10, 10),
		size = UDim2.new(0.55, 0, 0, 54),
		parent = row,
	})
	local slot = Create.new("Frame", {
		Name = "Slot",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -16, 0.5, 0),
		Size = UDim2.fromOffset(330, ROW_HEIGHT - 16),
		Parent = row,
	}) :: Frame
	return row, slot
end

-- A right-aligned button in a row slot.
local function slotButton(slot: Frame, options: StudUI.ButtonOptions): StudUI.Button
	options.size = options.size or UDim2.fromOffset(170, 70)
	options.position = UDim2.fromScale(1, 0.5)
	options.anchor = Vector2.new(1, 0.5)
	options.parent = slot
	return StudUI.button(options)
end

-- A vertical list frame (AutomaticSize Y) inside the scrolling list.
local function listFrame(name: string, parent: Instance): Frame
	return Create.new("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Visible = false,
		Parent = parent,
		Children = {
			Create.new("UIListLayout", {
				Padding = UDim.new(0, 12),
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		},
	}) :: Frame
end

--[[
	Sends the intent of a row: Nuke Town from inside Nuke Town keeps the legacy instant remotes;
	everything else is a server-validated world trip (warp overlay).
	@param worldId the tab's world
	@param target  "spawn" | "area" | "plot"
	@param index   area / plot number (nil for spawn)
]]
local function go(worldId: string, target: WorldClient.TravelTarget, index: number?)
	if worldId == MAIN and WorldClient.current() == MAIN then
		if target == "spawn" then
			Remotes.event("TeleportHub"):FireServer()
		elseif target == "area" then
			Remotes.event("TeleportArea"):FireServer(index)
		elseif plotRemoteReady() then
			Remotes.event(PLOT_REMOTE :: any):FireServer(index)
		end
	else
		WorldClient.travel(worldId, target, index, "menu")
	end
	ScreenManager.close(NAME)
end

-- The plot folder other players' rows read for `worldId` (its own tree, else Nuke Town's).
local function plotFolder(worldId: string): Instance?
	if worldId ~= MAIN then
		local worlds = Workspace:FindFirstChild("Worlds")
		local world = if worlds ~= nil then worlds:FindFirstChild(worldId) else nil
		local folder = if world ~= nil then world:FindFirstChild(Contract.Names.PlotsFolder) else nil
		if folder ~= nil then
			for _, plot in folder:GetChildren() do
				if Contract.num(plot:GetAttribute(Contract.Attr.OwnerUserId), 0) > 0 then
					return folder
				end
			end
		end
	end
	return Workspace:FindFirstChild(Contract.Names.PlotsFolder)
end

return StudUI.modalScreen({
	name = NAME,
	title = "Teleport",
	color = "blue",
	icon = "Teleport",
	size = WINDOW_SIZE,
	build = function(window: StudUI.Window): any
		local body = window.body
		Create.new("UIListLayout", {
			Padding = UDim.new(0, 10),
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = body,
		})
		local selected = WorldClient.current()
		local pages: { [string]: Page } = {}
		local render: () -> ()
		local list: ScrollingFrame -- the scrolling list under the tabs (built below)

		-- World tabs (LB / RB cycle; a locked / closed tab only shows its hint).
		local tabBar = WorldTabBar.new({
			parent = body,
			layoutOrder = 1,
			balances = true, -- R60: each world's own balance on its tab
			onSelect = function(worldId: string)
				selected = worldId
				render()
				list.CanvasPosition = Vector2.zero -- a new tab starts at its top
				local page = pages[worldId]
				GamepadNav.select(if page ~= nil and page.frame.Visible then page.first else nil)
			end,
		})

		-- The scrolling list under the tabs.
		list = Create.new("ScrollingFrame", {
			Name = "List",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 1, -(WorldClientConfig.TabHeight + 10)),
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			ScrollBarThickness = 10,
			LayoutOrder = 2,
			Parent = body,
			Children = {
				Create.new("UIListLayout", {
					Padding = UDim.new(0, 12),
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
				Create.new("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 8) }),
			},
		}) :: ScrollingFrame
		GamepadNav.followScroll(list)

		-- Locked / closed world panel (shared by every world; text set per render).
		local blocked = listFrame("Blocked", list)
		local blockedIcon = StudUI.icon("Lock", 150, 2)
		blockedIcon.LayoutOrder = 1
		blockedIcon.Parent = blocked
		local blockedText = StudUI.text({
			text = "",
			textSize = 44,
			wrap = true,
			size = UDim2.new(1, -60, 0, 120),
			layoutOrder = 2,
			parent = blocked,
		})
		local blockedProgress = StudUI.text({
			text = "",
			textSize = 32,
			size = UDim2.new(1, -60, 0, 40),
			layoutOrder = 3,
			parent = blocked,
		})
		local blockedBar = StudUI.progressBar({
			color = "sky",
			size = UDim2.new(0.7, 0, 0, 30),
			layoutOrder = 4,
			parent = blocked,
		})

		--[[
			Builds one world's open page: spawn + area rows, the players' plots section.
			@param worldId a WorldsConfig id
		]]
		local function buildPage(worldId: string): Page
			local def = WorldsConfig.get(worldId) :: WorldsConfig.WorldDef
			local style = WorldClientLogic.style(worldId)
			local frame = listFrame(`Page_{worldId}`, list)
			local rows: { AreaRow } = {}
			local first: GuiObject? = nil
			local entries: { { area: number, title: string } } = { { area = 0, title = style.spawnLabel } }
			for index, area in def.economy.Areas do
				table.insert(entries, { area = index, title = `{index}  {area.name}` })
			end
			for order, entry in entries do
				local icon = if entry.area == 0 then style.icon else areaIcon(worldId, entry.area)
				local _, slot = makeRow(frame, order, entry.title, icon)
				local areaIndex = entry.area
				local goButton = slotButton(slot, {
					text = "GO",
					color = "green",
					onActivated = function()
						if areaIndex == 0 then
							go(worldId, "spawn", nil)
						else
							go(worldId, "area", areaIndex)
						end
					end,
				})
				if first == nil then
					first = goButton.instance
				end
				-- Locked state: lock icon + "x / y purchases" + bar of the previous area.
				local lockGroup = Create.new("Frame", {
					Name = "Locked",
					BackgroundTransparency = 1,
					Size = UDim2.fromScale(1, 1),
					Visible = false,
					Parent = slot,
				}) :: Frame
				local lock = StudUI.icon("Lock", 56, 2)
				lock.AnchorPoint = Vector2.new(1, 0)
				lock.Position = UDim2.fromScale(1, 0)
				lock.Parent = lockGroup
				local progressText = StudUI.text({
					text = "",
					textSize = 28,
					align = Enum.TextXAlignment.Left,
					size = UDim2.new(1, -70, 0, 34),
					position = UDim2.fromOffset(0, 6),
					parent = lockGroup,
				})
				local bar = StudUI.progressBar({ color = "sky", size = UDim2.new(1, -10, 0, 24), parent = lockGroup })
				bar.frame.Position = UDim2.new(0, 0, 1, -28)
				table.insert(
					rows,
					{ area = areaIndex, go = goButton, lockGroup = lockGroup, progressText = progressText, bar = bar }
				)
			end
			-- Players' plots section (the Teleporter pass perk in every world).
			local section = StudUI.sectionLabel("Players' Plots", 42)
			section.LayoutOrder = PLOT_ORDER - 2
			section.Parent = frame
			local offerRow, offerSlot = makeRow(frame, PLOT_ORDER - 1, "Visit other players' plots!", "Teleporter")
			local buyPass = slotButton(offerSlot, {
				text = "",
				color = "green",
				productKey = PASS_KEY, -- live managed price (PriceBook; "..." until known)
				size = UDim2.fromOffset(230, 70),
				-- Owner R122: the press that opened Teleport (T / D-pad up / a HUD tap) never buys.
				onActivated = PurchaseGuard.gate(NAME, function()
					Remotes.event("PromptPass"):FireServer(PASS_KEY, "teleport")
				end),
			})
			PurchaseGuard.markBuy(buyPass.instance)
			return {
				worldId = worldId,
				frame = frame,
				rows = rows,
				first = first,
				offerRow = offerRow,
				buyPass = buyPass,
				plotRows = {},
			}
		end

		-- Rebuilds a page's players'-plot rows (≤ 7 rows, rebuilt on open / pass change only).
		local function renderPlots(page: Page, allowed: boolean)
			for _, row in page.plotRows do
				row:Destroy()
			end
			table.clear(page.plotRows)
			page.offerRow.Visible = not allowed
			if not allowed then
				return
			end
			local folder = plotFolder(page.worldId)
			local me = Players.LocalPlayer.UserId
			-- Nuke Town rows from inside Nuke Town use the legacy remote (SOON until published).
			local legacy = page.worldId == MAIN and WorldClient.current() == MAIN
			local ready = not legacy or plotRemoteReady()
			local plots: { { index: number, owner: string } } = {}
			for _, plot in (if folder ~= nil then folder:GetChildren() else {}) do
				local ownerId = Contract.num(plot:GetAttribute(Contract.Attr.OwnerUserId), 0)
				local index = Contract.num(plot:GetAttribute(Contract.Attr.PlotIndex), 0)
				if ownerId > 0 and ownerId ~= me and index > 0 then
					table.insert(plots, {
						index = index,
						owner = Contract.str(plot:GetAttribute(Contract.Attr.OwnerName), "Player"),
					})
				end
			end
			table.sort(
				plots,
				function(a: { index: number, owner: string }, b: { index: number, owner: string }): boolean
					return a.index < b.index
				end
			)
			if #plots == 0 then
				local row = makeRow(page.frame, PLOT_ORDER, "Nobody else here yet!", "Teleporter")
				table.insert(page.plotRows, row)
				return
			end
			for order, entry in plots do
				local row, slot =
					makeRow(page.frame, PLOT_ORDER + order, `Plot #{entry.index}  {entry.owner}`, "Teleporter")
				local plotIndex = entry.index
				local goButton = slotButton(slot, {
					text = if ready then "GO" else "SOON",
					color = "green",
					onActivated = function()
						go(page.worldId, "plot", plotIndex)
					end,
				})
				goButton.setState(if ready then "normal" else "disabled")
				table.insert(page.plotRows, row)
			end
		end

		-- Refreshes an open page's area rows (unlock state + progress) and its plot rows.
		local function renderPage(page: Page)
			local profile: any = ClientState.profile
			local tycoon = tycoonOf(page.worldId)
			local logic = TycoonLogic.forWorld(page.worldId)
			-- Own areas + spawn are free unless the config mirrors a server rule saying otherwise.
			local ownFree = not TycoonClientConfig.TeleportNeedsPass or ownsPass(profile)
			page.buyPass.setProductKey(PASS_KEY) -- no-op once bound; the price follows PriceBook
			for _, row in page.rows do
				local unlocked = row.area == 0 or (tycoon ~= nil and logic.areaUnlocked(tycoon, row.area))
				row.go.instance.Visible = unlocked
				row.go.setState(if ownFree or row.area == 0 then "normal" else "disabled")
				row.lockGroup.Visible = not unlocked
				if not unlocked and tycoon ~= nil then
					local bought, total = logic.areaProgress(tycoon, row.area - 1)
					row.progressText.Text = `{bought} / {total} purchases`
					row.bar.setProgress(if total > 0 then bought / total else 0)
				end
			end
			renderPlots(page, ownsPass(profile))
		end

		-- R60: each open (or closed-for-a-fix) world's balance on its tab; a locked world has none.
		local function refreshBalances(tabs: { WorldClientLogic.Tab })
			local profile: any = ClientState.profile
			for _, tab in tabs do
				local def = WorldsConfig.get(tab.id)
				if def ~= nil and tab.state ~= "locked" then
					local amount = if tab.id == MAIN
						then (if type(profile) == "table" then profile.cash else 0)
						else ClientState.worldCash(tab.id)
					tabBar.setBalance(tab.id, def.currency.icon, WorldClientLogic.balanceText(def.currency, amount))
				else
					tabBar.setBalance(tab.id, "", nil)
				end
			end
		end

		-- Shows the selected tab's page (or the locked / closed panel) and re-renders it.
		render = function()
			local tabs = WorldClient.tabs()
			local state: WorldClientLogic.TabState = "open"
			for _, tab in tabs do
				if tab.id == selected then
					state = tab.state
				end
			end
			tabBar.render(tabs, selected)
			refreshBalances(tabs)
			for _, page in pages do
				page.frame.Visible = false
			end
			blocked.Visible = state ~= "open"
			if state == "closed" then
				blockedIcon.Visible = true
				blockedText.Text = WorldClientConfig.ClosedText
				blockedProgress.Visible = false
				blockedBar.frame.Visible = false
			elseif state == "locked" then
				-- Progress in the unlock rule's own world (R70: not always Nuke Town).
				local lockedDef = WorldsConfig.get(selected)
				local ruleWorld = if lockedDef ~= nil and lockedDef.unlock.kind == "progress"
					then (lockedDef.unlock :: any).world
					else MAIN
				local hint, _, bought, total = WorldClientLogic.lockHint(selected, tycoonOf(ruleWorld))
				blockedText.Text = hint
				blockedProgress.Visible = total > 0
				blockedBar.frame.Visible = total > 0
				blockedProgress.Text = WorldClientLogic.fill(
					WorldClientConfig.LockedProgress,
					{ bought = tostring(bought), total = tostring(total) }
				)
				blockedBar.setProgress(if total > 0 then bought / total else 0)
			else
				local page = pages[selected]
				if page == nil then
					page = buildPage(selected)
					pages[selected] = page
				end
				page.frame.Visible = true
				renderPage(page)
				-- Tabs exit Down into the list; the first row exits Up into the tabs.
				local first: any = page.first
				for _, button in tabBar.buttons() do
					(button :: any).NextSelectionDown = first
				end
				if first ~= nil then
					first.NextSelectionUp = tabBar.button(selected)
				end
			end
		end

		local profileConnection: any = nil
		local stateConnection: any = nil
		return {
			onOpen = function(args: any?)
				-- Opens on the current world's tab (or an explicit { world = id }).
				local requested = if type(args) == "table" then args.world else nil
				selected = if type(requested) == "string" and WorldsConfig.get(requested) ~= nil
					then requested
					else WorldClient.current()
				render()
				list.CanvasPosition = Vector2.zero
				tabBar.enable()
				if profileConnection == nil then
					profileConnection = ClientState.ProfileChanged:Connect(function(_profile, fields)
						if
							fields == nil
							or table.find(fields, "tycoon") ~= nil
							or table.find(fields, "passes") ~= nil
							or table.find(fields, "worlds") ~= nil
						then
							render()
						elseif table.find(fields, "cash") ~= nil or table.find(fields, "worldCash") ~= nil then
							refreshBalances(WorldClient.tabs()) -- cheap: only the balance pills
						end
					end)
				end
				if stateConnection == nil then
					stateConnection = WorldClient.StateChanged:Connect(render)
				end
			end,
			onClose = function()
				tabBar.disable()
				if profileConnection ~= nil then
					profileConnection:Disconnect()
					profileConnection = nil
				end
				if stateConnection ~= nil then
					stateConnection:Disconnect()
					stateConnection = nil
				end
			end,
			-- The first area's GO (free teleport), else the world tab; never the Teleporter BUY (R122).
			defaultSelection = function(): GuiObject?
				local page = pages[selected]
				local first = if page ~= nil and page.frame.Visible then page.first else nil
				return PurchaseGuard.safeDefault({ first, tabBar.button(selected) })
			end,
		}
	end,
})
