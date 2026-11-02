--!strict
--[[
	Quests — the Quests window (owner R78, spec §1): a wide NUKE PASS banner on top (opens screen
	"NukePass"), then three tabs:
		GOALS     the 12 starter goals in order: completed → green CLAIM (then CLAIMED), the current
		          goal with its progress bar and a GO button (opens the goal's screen, or closes
		          Quests so the objective chip's arrow can guide), later goals LOCKED!
		DAILY     today's three missions (progress, CLAIM, a SWAP button for the one free reroll,
		          GO for missions with a screen), the Daily Chest row, and the UTC reset countdown
		TROPHIES  nine lifetime trophies: the next tier's target + reward, CLAIM one tier at a time
	Every reward is an explicit CLAIM (green button: coin burst + claim sound via ButtonFeedback;
	gems / cash fly into the HUD on the profile push, CurrencyFly) — never silent.

	Data: Client/Quests/QuestClient's View (the same QuestConfig rules as the server). CLAIM / SWAP
	only send intents (QuestClaim / QuestReroll); the button shows "sending" until the server's
	`quests` push arrives (or 3 s pass). Rows are built once (first open) and only re-filled.

	Console + mobile (owner R11): ResponsiveModal modes "tall" (desktop / console / tablet) and
	"wide" (landscape phones); on touch every button / tab is >= 44 pt and text >= 14 pt. Gamepad:
	LB / RB cycle the tabs, the banner's OPEN → tabs → rows are linked (Up / Down), a row's SWAP is
	Left of its main button, the list follows the cursor, the cursor starts on the first CLAIM (else
	the first row, never the close X), B / Back closes.

	Analytics: ClientAnalytics.screenOpened("Quests", source) — sources "hud" (default), "chip"
	(the objective chip), "quests" etc. via ScreenManager.open("Quests", { source = ... }).

	Connects to: Client/Quests/{QuestClient, PassBridge}, Screens/Quests/{QuestRow, PassBanner},
	Screens/DailyRewards/{ResponsiveModal, RewardPreview}, Kit/StudUI, Widgets/StudWindow,
	Platform/GamepadNav, Analytics/ClientAnalytics, UI/ScreenManager, Shared/Config/QuestConfig.

	Example:
		ScreenManager.open("Quests")                         -- HUD button (source "hud")
		ScreenManager.open("Quests", { source = "chip", tab = "daily" })
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientAnalytics = require(script.Parent.Parent.Parent.Analytics.ClientAnalytics)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.Create)
local GamepadNav = require(script.Parent.Parent.Parent.Platform.GamepadNav)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local PassBanner = require(script.PassBanner)
local QuestClient = require(script.Parent.Parent.Parent.Quests.QuestClient)
local QuestConfig = require(ReplicatedStorage.Shared.Config.QuestConfig)
local QuestRow = require(script.QuestRow)
local ResponsiveModal = require(script.Parent.DailyRewards.ResponsiveModal)
local RewardPreview = require(script.Parent.DailyRewards.RewardPreview)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Widgets.StudWindow)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

type Tab = "goals" | "daily" | "trophies"
type View = QuestClient.View

local NAME = "Quests"
local ANALYTICS_ID = "Quests"
local TABS: { { id: Tab, label: string } } = {
	{ id = "goals", label = "GOALS" },
	{ id = "daily", label = "DAILY" },
	{ id = "trophies", label = "TROPHIES" },
}
-- After CLAIM / SWAP the button shows "sending" this long unless the server's push arrives first.
local PENDING_SECONDS = 3
local GAP = 12 -- vertical gap between the banner, tabs, header and list (design px)
local TAB_WIDTH = 230
-- Phones ("wide" mode): the tabs become a left rail this wide (design px) so the rows get the
-- full height (owner R78 follow-up: touch is 15 of 26 sessions; >= 4 rows visible).
local RAIL_WIDTH = 250

-- A transparent layout frame.
local function box(name: string, parent: Instance, order: number): Frame
	return Create.new("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 60),
		LayoutOrder = order,
		Parent = parent,
	}) :: Frame
end

-- "10 Gems + $200   +50 XP" (reward preview with the player's income, + Nuke Pass XP).
local function rewardLine(reward: QuestConfig.Reward, xp: number): string
	local headline = RewardPreview.headline(reward, ClientState.profile)
	return `{headline}   +{xp} XP`
end

-- The analytics source from ScreenManager.open's args, default "hud".
local function sourceOf(args: any?): string
	if type(args) == "table" and type(args.source) == "string" then
		return args.source
	end
	return "hud"
end

--[[ Owner R83: true while the AutoClicker pass is clicking for this player (pass owned and the
     Settings toggle not OFF — the client mirror of TycoonRules.autoClickerOn). Its cycles count
     toward "click" rows on the server (TycoonRules.autoClickCredit), so those rows say AUTO ON
     instead of KEEP GOING. Display only: the server decides every credit. ]]
local function autoClicking(): boolean
	local profile: any = ClientState.profile
	if type(profile) ~= "table" then
		return false
	end
	local passes, settings = profile.passes, profile.settings
	return type(passes) == "table"
		and passes.AutoClicker == true
		and not (type(settings) == "table" and settings.autoClicker == false)
end

-- The action of an active row nobody can GO to: AUTO ON for click rows the Auto Clicker fills
-- (R83), else the grey KEEP GOING.
local function keepGoing(stat: string?): QuestRow.Action
	if stat == "click" and autoClicking() then
		-- "claimed" = a non-pressable green chip (StudUI greys every "locked" button).
		return { text = "AUTO ON", color = "green", state = "claimed" }
	end
	return { text = "KEEP GOING", color = "grey", state = "locked" }
end

-- A red count badge on a tab button.
local function tabBadge(parent: GuiObject): (Frame, TextLabel)
	local badge = Create.new("Frame", {
		Name = "Badge",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -6, 0, 6),
		Size = UDim2.fromOffset(36, 36),
		BackgroundColor3 = UIStyleConfig.Colors.red.bottom,
		Visible = false,
		ZIndex = 8,
		Parent = parent,
		Children = { Create.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }) },
	}) :: Frame
	StudWindow.edge(badge, 3)
	local text = StudUI.text({
		name = "BadgeText",
		text = "",
		textSize = 22,
		size = UDim2.fromScale(1, 1),
		zIndex = 9,
		parent = badge,
	})
	return badge, text
end

return ResponsiveModal.screen({
	name = NAME,
	title = "Quests",
	color = "orange",
	icon = "Trophy",
	modes = {
		{ name = "tall", size = Vector2.new(1180, 820) },
		-- Landscape phones: as tall as an iPhone-class canvas allows unshrunk (rows need the height).
		{ name = "wide", size = Vector2.new(1560, 680) },
	},
	build = function(
		window: StudUI.Window,
		_gui: ScreenGui,
		layout: ResponsiveModal.Controller
	): ScreenManager.ScreenHandle?
		local tab: Tab = "goals"
		local isOpen = false
		-- Phone layout (mode "wide"): side rail tabs, compact rows, short header texts.
		local compactMode = false
		-- Phones: the summary / countdown sit under the rail's tabs (when they fit there).
		local headerInRail = false
		local current: View = QuestClient.view()
		-- Per intent key ("starter:3", "daily:2", "swap:1", "chest", "trophy:clicker"): server time
		-- until which its button shows "sending".
		local pending: { [string]: number } = {}
		-- Owner R79: the GO / OPEN button that handed off to another window (ScreenManager.handoff);
		-- the gamepad lands on it again when that window closes and Quests comes back.
		local returnTo: GuiObject? = nil

		Create.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, GAP),
			Parent = window.body,
		})

		-- 1. NUKE PASS banner.
		local banner = PassBanner.new(window.body, 1, function(button: GuiObject)
			returnTo = button -- R79: the gamepad comes back to OPEN when the pass closes
		end)

		-- 2. Everything under the banner: the tabs (a top row, or a left rail on phones) and the list.
		local main = box("Main", window.body, 2)
		local tabBar = box("Tabs", main, 1)
		local tabLayout = Create.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 14),
			Parent = tabBar,
		}) :: UIListLayout
		local render: () -> ()
		local tabButtons: { [Tab]: StudUI.Button } = {}
		local tabBadges: { [Tab]: { frame: Frame, text: TextLabel } } = {}
		local function showTab(id: Tab)
			if tab ~= id then
				tab = id
				returnTo = nil
				render()
				GamepadNav.select(tabButtons[id].instance)
			end
		end
		for order, entry in TABS do
			local id = entry.id
			local button = StudUI.button({
				text = entry.label,
				color = "grey",
				size = UDim2.fromOffset(TAB_WIDTH, 64),
				textSize = 30,
				layoutOrder = order,
				name = `Tab_{entry.label}`,
				parent = tabBar,
				onActivated = function()
					showTab(id)
				end,
			})
			tabButtons[id] = button
			local frame, text = tabBadge(button.instance)
			tabBadges[id] = { frame = frame, text = text }
		end
		local function cycle(delta: number)
			local index = 1
			for i, entry in TABS do
				if entry.id == tab then
					index = i
				end
			end
			index = ((index - 1 + delta) % #TABS) + 1
			showTab(TABS[index].id)
		end
		local cycler = GamepadNav.cycler(function()
			cycle(-1)
		end, function()
			cycle(1)
		end)

		-- 3. The scrolling list of rows (positioned by applyLayout).
		local list = Create.new("ScrollingFrame", {
			Name = "List",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 1, -300),
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			ScrollBarThickness = 10,
			ScrollBarImageColor3 = UIStyleConfig.Neutral.Edge,
			VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
			Selectable = false,
			Parent = main,
			Children = {
				Create.new("UIListLayout", {
					Name = "Rows",
					FillDirection = Enum.FillDirection.Vertical,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					SortOrder = Enum.SortOrder.LayoutOrder,
					Padding = UDim.new(0, 10),
				}),
				Create.new("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 8) }),
			},
		}) :: ScrollingFrame
		GamepadNav.followScroll(list)

		-- The tab summary (DAILY: + the UTC reset countdown): the list's first line (scrolls with the
		-- rows), or on phones the rail under the tabs (two short stacked lines).
		local header = box("Header", list, 0)
		local headerText = StudUI.text({
			name = "Summary",
			text = "",
			textSize = 28,
			scaled = true,
			align = Enum.TextXAlignment.Left,
			size = UDim2.fromScale(0.55, 1),
			parent = header,
		})
		local resetCountdown = StudUI.countdown({
			endsAt = 0,
			format = "hms",
			prefix = "New missions in ",
			doneText = "New missions!",
			textSize = 28,
			size = UDim2.fromScale(0.45, 1),
			parent = header,
			onFinished = function()
				QuestClient.refresh()
			end,
		})
		resetCountdown.label.AnchorPoint = Vector2.new(1, 0)
		resetCountdown.label.Position = UDim2.fromScale(1, 0)
		resetCountdown.label.TextXAlignment = Enum.TextXAlignment.Right
		resetCountdown.label.TextScaled = true
		Create.new("UITextSizeConstraint", { MaxTextSize = 28, MinTextSize = 10, Parent = resetCountdown.label })

		-- Rows (built once; filled by render).
		local goalRows: { QuestRow.Row } = {}
		for i = 1, QuestConfig.GoalCount do
			goalRows[i] = QuestRow.new(list, i, false)
		end
		local missionRows: { QuestRow.Row } = {}
		for slot = 1, QuestConfig.MissionsPerDay do
			missionRows[slot] = QuestRow.new(list, 100 + slot, true)
		end
		local chestRow = QuestRow.new(list, 100 + QuestConfig.MissionsPerDay + 1, false)
		local trophyRows: { QuestRow.Row } = {}
		for i = 1, #QuestConfig.Trophies do
			trophyRows[i] = QuestRow.new(list, 200 + i, false)
		end

		-- Device metrics → every widget (touch: 44 pt taps, 14 pt text; phones: rail + compact rows).
		local function applyLayout(current_: ResponsiveModal.Layout)
			local minText = math.max(10, math.ceil(current_.minText))
			local buttonHeight = math.max(64, math.ceil(current_.tap))
			compactMode = current_.mode == "wide"
			-- Text floors in RENDERED px for UITextSizeConstraint (14 pt on touch), never design px.
			local textFloor = if current_.touch then 14 else 10
			local metrics: QuestRow.Metrics = {
				height = 104,
				buttonWidth = if compactMode then 190 else 210,
				buttonHeight = buttonHeight,
				title = math.max(30, math.ceil(minText * 1.2)),
				detail = math.max(22, minText),
				icon = 76,
				minText = minText,
				compact = compactMode,
				textFloor = textFloor,
			}
			-- The row fits its text + buttons (QuestRow.heightFor); the icon follows it.
			metrics.height = QuestRow.heightFor(metrics)
			metrics.icon = math.min(84, metrics.height - 28)
			for _, row in goalRows do
				row.layout(metrics)
			end
			for _, row in missionRows do
				row.layout(metrics)
			end
			chestRow.layout(metrics)
			for _, row in trophyRows do
				row.layout(metrics)
			end
			local rowsLayout = list:FindFirstChild("Rows") :: UIListLayout
			rowsLayout.Padding = UDim.new(0, if compactMode then 6 else 10)
			-- Phones: the banner becomes the rail's first card (one pass button), so the list gets the
			-- whole body height (>= 4 rows on an iPhone-class phone).
			local bannerHeight = if compactMode then buttonHeight + 12 else math.max(130, buttonHeight + 34)
			banner.layout(bannerHeight, buttonHeight, minText, compactMode, textFloor)
			local headerLine = math.max(40, minText + 16)
			if compactMode then
				banner.frame.Parent = tabBar
				banner.frame.LayoutOrder = 0
				main.Size = UDim2.fromScale(1, 1)
			else
				banner.frame.Parent = window.body
				banner.frame.LayoutOrder = 1
				main.Size = UDim2.new(1, 0, 1, -(bannerHeight + GAP))
			end
			-- The rail holds the pass card, the tabs and (when it fits) the two-line summary.
			local railNeeded = bannerHeight + (buttonHeight + 10) * #TABS + 10 + headerLine * 2
			headerInRail = compactMode and railNeeded <= current_.area.Y
			if compactMode then
				-- Left rail: the tabs stacked, the summary + countdown under them; the list fills the rest.
				tabLayout.FillDirection = Enum.FillDirection.Vertical
				tabLayout.VerticalAlignment = Enum.VerticalAlignment.Top
				tabLayout.Padding = UDim.new(0, 10)
				tabBar.Position = UDim2.fromOffset(0, 0)
				tabBar.Size = UDim2.new(0, RAIL_WIDTH, 1, 0)
				for _, button in tabButtons do
					button.instance.Size = UDim2.fromOffset(RAIL_WIDTH - 20, buttonHeight)
				end
				list.Position = UDim2.fromOffset(RAIL_WIDTH + GAP, 0)
				list.Size = UDim2.new(1, -(RAIL_WIDTH + GAP), 1, 0)
			else
				local tabsHeight = buttonHeight + 8
				tabLayout.FillDirection = Enum.FillDirection.Horizontal
				tabLayout.VerticalAlignment = Enum.VerticalAlignment.Center
				tabLayout.Padding = UDim.new(0, 14)
				tabBar.Position = UDim2.fromOffset(0, 0)
				tabBar.Size = UDim2.new(1, 0, 0, tabsHeight)
				for _, button in tabButtons do
					button.instance.Size = UDim2.fromOffset(TAB_WIDTH, buttonHeight)
				end
				list.Position = UDim2.fromOffset(0, tabsHeight + GAP)
				list.Size = UDim2.new(1, 0, 1, -(tabsHeight + GAP))
			end
			if headerInRail then
				-- Under the rail's tabs, two short lines: the summary (GOALS / TROPHIES), or on DAILY the
				-- countdown alone ("New missions in" / "05:43:24"; render hides the summary there).
				header.Parent = tabBar
				header.LayoutOrder = #TABS + 1
				header.Size = UDim2.new(1, -8, 0, headerLine * 2)
				headerText.Size = UDim2.fromScale(1, 0.5)
				resetCountdown.label.AnchorPoint = Vector2.new(0, 0)
				resetCountdown.label.Position = UDim2.fromScale(0, 0)
				resetCountdown.label.Size = UDim2.fromScale(1, 1)
				resetCountdown.label.TextXAlignment = Enum.TextXAlignment.Left
			else
				-- The list's first line: summary left, countdown right.
				header.Parent = list
				header.LayoutOrder = 0
				header.Size = UDim2.new(1, -8, 0, headerLine)
				headerText.Size = UDim2.fromScale(0.55, 1)
				resetCountdown.label.AnchorPoint = Vector2.new(1, 0)
				resetCountdown.label.Position = UDim2.fromScale(1, 0)
				resetCountdown.label.Size = UDim2.fromScale(0.45, 1)
				resetCountdown.label.TextXAlignment = Enum.TextXAlignment.Right
			end
			for _, label in { headerText, resetCountdown.label } do
				local constraint = label:FindFirstChildOfClass("UITextSizeConstraint")
				if constraint ~= nil then
					constraint.MinTextSize = math.min(textFloor, constraint.MaxTextSize)
				end
			end
			if isOpen then
				render()
			end
		end
		layout.onChanged(applyLayout)
		applyLayout(layout.current())

		-- True while an intent's "sending" window runs.
		local function isPending(key: string): boolean
			return RewardPreview.serverNow() < (pending[key] or 0)
		end
		local function markPending(key: string)
			pending[key] = RewardPreview.serverNow() + PENDING_SECONDS
			render()
			task.delay(PENDING_SECONDS + 0.05, function()
				if isOpen then
					render()
				end
			end)
		end
		-- The action of a claimable row: green CLAIM (or "sending").
		local function claimAction(key: string): QuestRow.Action
			return {
				text = "CLAIM",
				color = "green",
				state = if isPending(key) then "disabled" else "normal",
			}
		end

		-- Fills the GOALS rows.
		local function renderGoals(view: View)
			local views = QuestConfig.starterViews(view.state, view.facts)
			local done = 0
			for i, goalView in views do
				local goal = goalView.goal
				local row = goalRows[i]
				if goalView.state == "claimed" then
					done += 1
					row.set({
						icon = goal.icon,
						title = `{i}. {goal.text}`,
						detail = rewardLine(goal.reward, goal.xp),
						progress = 1,
						progressText = `{goal.target}/{goal.target}`,
						color = "grey",
						action = { text = "CLAIMED", color = "green", state = "claimed" },
						dim = true,
					})
				elseif goalView.state == "ready" then
					done += 1
					row.set({
						icon = goal.icon,
						title = `{i}. {goal.text}`,
						detail = rewardLine(goal.reward, goal.xp),
						progress = 1,
						progressText = `{goal.target}/{goal.target}`,
						color = "green",
						action = claimAction(`starter:{i}`),
					})
				elseif goalView.state == "active" then
					local hasGo = goal.screen ~= nil or goal.guide ~= nil
					row.set({
						icon = goal.icon,
						title = `{i}. {goal.text}`,
						detail = rewardLine(goal.reward, goal.xp),
						progress = goalView.value / goal.target,
						progressText = `{NumberFormat.commas(goalView.value)}/{NumberFormat.commas(goal.target)}`,
						color = "sky",
						action = if hasGo
							then { text = "GO", color = "blue", state = "normal" }
							else { text = "KEEP GOING", color = "grey", state = "locked" },
					})
				else
					row.set({
						icon = goal.icon,
						title = `{i}. {goal.text}`,
						detail = rewardLine(goal.reward, goal.xp),
						color = "grey",
						action = { text = "LOCKED!", color = "grey", state = "locked" },
						dim = true,
					})
				end
				row.button.setCallback(function()
					local live = QuestConfig.starterViews(current.state, current.facts)[i]
					if live == nil then
						return
					end
					if live.state == "ready" then
						if QuestClient.claim("starter", i) then
							markPending(`starter:{i}`)
						end
					elseif live.state == "active" then
						if goal.screen ~= nil then
							-- R79: Quests hides while that window is up and comes back after.
							returnTo = row.button.instance
							ScreenManager.handoff(NAME, goal.screen, { source = "quests" })
						elseif goal.guide ~= nil then
							-- The objective chip's arrow shows the way.
							ScreenManager.close(NAME)
						end
					end
				end)
			end
			headerText.Text = if compactMode
				then `{done}/{QuestConfig.GoalCount} done`
				else `Starter Goals: {done} / {QuestConfig.GoalCount} done`
		end

		-- Fills the DAILY rows + the chest.
		local function renderDaily(view: View)
			local missions, chest, stale = QuestConfig.dailyViews(view.state, view.today)
			local canSwap = not view.state.daily.rerolled
			local finished = 0
			for slot, row in missionRows do
				local mission = missions[slot]
				if mission == nil then
					row.setVisible(false)
					continue
				end
				row.setVisible(true)
				local detail = rewardLine(QuestConfig.MissionReward, QuestConfig.MissionXp)
				if mission.state ~= "active" then
					finished += 1
				end
				if mission.state == "claimed" then
					row.set({
						icon = mission.icon,
						title = mission.text,
						detail = detail,
						progress = 1,
						progressText = `{mission.target}/{mission.target}`,
						color = "grey",
						action = { text = "CLAIMED", color = "green", state = "claimed" },
						dim = true,
					})
				elseif mission.state == "ready" then
					row.set({
						icon = mission.icon,
						title = mission.text,
						detail = detail,
						progress = 1,
						progressText = `{mission.target}/{mission.target}`,
						color = "green",
						action = claimAction(`daily:{slot}`),
					})
				else
					local screen = if mission.mission ~= nil then mission.mission.screen else nil
					row.set({
						icon = mission.icon,
						title = mission.text,
						detail = detail,
						progress = mission.progress / mission.target,
						progressText = `{NumberFormat.commas(mission.progress)}/{NumberFormat.commas(mission.target)}`,
						color = "sky",
						action = if screen ~= nil
							then { text = "GO", color = "blue", state = "normal" }
							else keepGoing(mission.stat),
						swap = canSwap,
					})
				end
				local swap = row.swapButton
				if swap ~= nil then
					swap.setState(if isPending(`swap:{slot}`) then "disabled" else "normal")
					swap.setCallback(function()
						if QuestClient.reroll(slot) then
							markPending(`swap:{slot}`)
						end
					end)
				end
				row.button.setCallback(function()
					local live = QuestConfig.dailyViews(current.state, current.today)[slot]
					if live == nil then
						return
					end
					if live.state == "ready" then
						if QuestClient.claim("daily", slot) then
							markPending(`daily:{slot}`)
						end
					elseif live.state == "active" and live.mission ~= nil and live.mission.screen ~= nil then
						returnTo = row.button.instance -- R79 handoff (see the GOALS GO above)
						ScreenManager.handoff(NAME, live.mission.screen, { source = "quests" })
					end
				end)
			end
			chestRow.setVisible(not stale)
			chestRow.set({
				icon = "Chest",
				title = "Daily Chest",
				detail = `Finish all 3: {rewardLine(QuestConfig.ChestReward, QuestConfig.ChestXp)}`,
				progress = finished / QuestConfig.MissionsPerDay,
				progressText = `{finished}/{QuestConfig.MissionsPerDay}`,
				color = if chest == "ready" then "green" elseif chest == "claimed" then "grey" else "purple",
				action = if chest == "ready"
					then claimAction("chest")
					elseif chest == "claimed" then { text = "OPENED", color = "green", state = "claimed" }
					else { text = "LOCKED!", color = "grey", state = "locked" },
				dim = chest == "claimed",
			})
			chestRow.button.setCallback(function()
				local _, live = QuestConfig.dailyViews(current.state, current.today)
				if live == "ready" and QuestClient.claim("chest", nil) then
					markPending("chest")
				end
			end)
			headerText.Text = if stale
				then "New missions soon..."
				elseif compactMode then (if canSwap then "1 free swap" else "Swap used")
				elseif canSwap then "Daily Missions  (1 free swap left)"
				else "Daily Missions"
			resetCountdown.setEndsAt(RewardPreview.serverNow() + QuestConfig.secondsToReset(RewardPreview.serverNow()))
		end

		-- Fills the TROPHIES rows.
		local function renderTrophies(view: View)
			local views = QuestConfig.trophyViews(view.state, view.facts)
			local tiers = 0
			for i, trophyView in views do
				local trophy = trophyView.trophy
				local row = trophyRows[i]
				tiers += trophyView.claimed
				if trophyView.state == "maxed" then
					row.set({
						icon = trophy.icon,
						title = QuestConfig.tierName(trophy, #trophy.tiers),
						detail = `All {#trophy.tiers} tiers done: {NumberFormat.short(trophyView.value)} {trophy.unit}`,
						progress = 1,
						progressText = `{#trophy.tiers}/{#trophy.tiers}`,
						color = "yellow",
						action = { text = "DONE", color = "green", state = "claimed" },
						dim = true,
					})
				else
					local tier = trophyView.claimed + 1
					local target = trophyView.nextTarget :: number
					local ready = trophyView.state == "ready"
					row.set({
						icon = trophy.icon,
						title = QuestConfig.tierName(trophy, tier),
						detail = `{NumberFormat.short(target)} {trophy.unit}: {rewardLine(
							QuestConfig.trophyReward(tier),
							QuestConfig.TrophyXp
						)}`,
						progress = math.min(1, trophyView.value / target),
						progressText = `{NumberFormat.short(math.min(trophyView.value, target))}/{NumberFormat.short(
							target
						)}`,
						color = if ready then "green" else "sky",
						action = if ready then claimAction(`trophy:{trophy.id}`) else keepGoing(trophy.stat),
					})
				end
				local id = trophy.id
				row.button.setCallback(function()
					for _, live in QuestConfig.trophyViews(current.state, current.facts) do
						if live.trophy.id == id and live.state == "ready" then
							if QuestClient.claim("trophy", id) then
								markPending(`trophy:{id}`)
							end
							return
						end
					end
				end)
			end
			local total = 0
			for _, trophy in QuestConfig.Trophies do
				total += #trophy.tiers
			end
			headerText.Text = if compactMode then `{tiers}/{total} tiers` else `Trophies: {tiers} / {total} tiers`
		end

		-- Gamepad links: banner OPEN → current tab → rows (Up / Down); SWAP is Left of its row.
		local function relink(rows: { QuestRow.Row })
			local mains: { GuiObject } = {}
			local visibleRows: { QuestRow.Row } = {}
			for _, row in rows do
				if row.frame.Visible then
					table.insert(mains, row.button.instance)
					table.insert(visibleRows, row)
				end
			end
			local currentTab = tabButtons[tab].instance
			local open = banner.open.instance
			-- NextSelection* accept nil (no link) at runtime; the definitions type them non-optional.
			for index, entry in TABS do
				local button = tabButtons[entry.id].instance
				local previous = if index > 1 then tabButtons[TABS[index - 1].id].instance else nil
				local following = if index < #TABS then tabButtons[TABS[index + 1].id].instance else nil
				if compactMode then
					-- Rail: tabs Up / Down (the first one Up → the pass button), Right → the rows.
					button.NextSelectionUp = (previous or open) :: any
					button.NextSelectionDown = following :: any
					button.NextSelectionLeft = nil :: any
					button.NextSelectionRight = mains[1] :: any
				else
					-- Top row: tabs Left / Right, Up → OPEN, Down → the rows.
					button.NextSelectionUp = open
					button.NextSelectionDown = mains[1] :: any
					button.NextSelectionLeft = previous :: any
					button.NextSelectionRight = following :: any
				end
			end
			GamepadNav.linkList(mains, true, { up = if compactMode then nil else currentTab })
			if compactMode then
				-- The pass button tops the rail: Down → the first tab, Right → the rows.
				open.NextSelectionDown = tabButtons[TABS[1].id].instance
				open.NextSelectionRight = mains[1] :: any
			else
				open.NextSelectionDown = currentTab
				open.NextSelectionRight = nil :: any
			end
			open.NextSelectionLeft = nil :: any
			for index, row in visibleRows do
				local swap = row.swapButton
				-- Phones: Left from a row (or its SWAP) goes back to the rail's current tab.
				local railExit = if compactMode then currentTab else nil
				if swap ~= nil and swap.instance.Visible then
					row.button.instance.NextSelectionLeft = swap.instance
					swap.instance.NextSelectionRight = row.button.instance
					swap.instance.NextSelectionLeft = railExit :: any
					swap.instance.NextSelectionUp = (if index > 1 then mains[index - 1] else currentTab) :: any
					swap.instance.NextSelectionDown = mains[index + 1] :: any
				else
					row.button.instance.NextSelectionLeft = railExit :: any
				end
			end
		end

		-- Tab badges (claimables per tab) + tab colours.
		local function renderTabs(view: View)
			local counts: { [Tab]: number } = { goals = 0, daily = 0, trophies = 0 }
			for _, goalView in QuestConfig.starterViews(view.state, view.facts) do
				if goalView.state == "ready" then
					counts.goals += 1
				end
			end
			local missions, chest = QuestConfig.dailyViews(view.state, view.today)
			for _, mission in missions do
				if mission.state == "ready" then
					counts.daily += 1
				end
			end
			if chest == "ready" then
				counts.daily += 1
			end
			for _, trophyView in QuestConfig.trophyViews(view.state, view.facts) do
				if trophyView.state == "ready" then
					counts.trophies += 1
				end
			end
			for _, entry in TABS do
				local id = entry.id
				tabButtons[id].setColor(if id == tab then "orange" else "grey")
				local badge = tabBadges[id]
				local count = counts[id]
				badge.frame.Visible = count > 0
				badge.text.Text = if count > 9 then "9+" else tostring(count)
			end
		end

		render = function()
			if not isOpen then
				return
			end
			local view = current
			banner.set(view.pass)
			renderTabs(view)
			for _, row in goalRows do
				row.setVisible(tab == "goals")
			end
			for _, row in missionRows do
				row.setVisible(tab == "daily")
			end
			chestRow.setVisible(tab == "daily")
			for _, row in trophyRows do
				row.setVisible(tab == "trophies")
			end
			resetCountdown.label.Visible = tab == "daily"
			headerText.Visible = not (headerInRail and tab == "daily")
			if tab == "goals" then
				renderGoals(view)
				relink(goalRows)
			elseif tab == "daily" then
				renderDaily(view)
				local rows = table.clone(missionRows)
				table.insert(rows, chestRow)
				relink(rows)
			else
				renderTrophies(view)
				relink(trophyRows)
			end
		end

		QuestClient.Changed:Connect(function(view: View)
			current = view
			-- The server answered (or resynced): drop every "sending" state, show its truth.
			table.clear(pending)
			render()
		end)

		-- The tab to open on: the first with something to claim, else GOALS until the chain is
		-- done, then DAILY.
		local function defaultTab(view: View): Tab
			for _, goalView in QuestConfig.starterViews(view.state, view.facts) do
				if goalView.state == "ready" then
					return "goals"
				end
			end
			local missions, chest = QuestConfig.dailyViews(view.state, view.today)
			for _, mission in missions do
				if mission.state == "ready" then
					return "daily"
				end
			end
			if chest == "ready" then
				return "daily"
			end
			for _, trophyView in QuestConfig.trophyViews(view.state, view.facts) do
				if trophyView.state == "ready" then
					return "trophies"
				end
			end
			return if view.state.starter.step < QuestConfig.GoalCount then "goals" else "daily"
		end

		return {
			onOpen = function(args: any?)
				isOpen = true
				current = QuestClient.view()
				local requested = if type(args) == "table" then args.tab else nil
				tab = if requested == "goals"
						or requested == "daily"
						or requested == "trophies"
					then requested
					else defaultTab(current)
				render()
				QuestClient.refresh()
				cycler.enable()
				ClientAnalytics.screenOpened(ANALYTICS_ID, sourceOf(args))
			end,
			onClose = function()
				isOpen = false
				returnTo = nil
				cycler.disable()
			end,
			-- Gamepad: back on the GO / OPEN that handed off (R79), else the first CLAIM of the tab,
			-- else its first row, else the tab.
			defaultSelection = function(): GuiObject?
				local back = returnTo
				if back ~= nil and back.Visible and back:IsDescendantOf(window.frame) then
					return back
				end
				local rows = if tab == "goals" then goalRows elseif tab == "daily" then missionRows else trophyRows
				local candidates = table.clone(rows)
				if tab == "daily" then
					table.insert(candidates, chestRow)
				end
				local first: GuiObject? = nil
				for _, row in candidates do
					if row.frame.Visible then
						first = first or row.button.instance
						if row.button.state() == "normal" and row.button.label.Text == "CLAIM" then
							return row.button.instance
						end
					end
				end
				return first or tabButtons[tab].instance
			end,
		}
	end,
})
