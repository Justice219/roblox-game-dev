--!strict
--[[
	RewardsHub — the "Rewards" window behind the HUD's ONE Rewards button (owner R62: "a lot of
	buttons on the left side"). Daily, Playtime (Time Rewards), Lucky Wheel, Group and Codes no
	longer have their own HUD buttons; this stud window shows one big tile per feature instead:

		┌──────────────── Rewards ────────────────┐
		│   [Daily ③]   [Playtime]   [Wheel ②]    │   tile = the HUD stud tile (icon + label +
		│   CLAIM NOW!  Next in 4m09s  SPIN NOW!  │          its own red badge) above a status
		│        [Group]        [Codes]           │          pill ("CLAIM NOW!", "Next in 2h 14m",
		│   Join for a gift!  Enter a code!       │          "Join for a gift!", ...)
		└─────────────────────────────────────────┘

	Flow:
		Tap / click / A on a tile → ScreenManager.open(<feature screen>, { source = "hub" }) — the
		feature's EXISTING screen opens STACKED over the hub (the hub window hides while covered so
		only one window shows and the gamepad cursor cannot wander into it). B / X / the feature's
		close returns to the hub with the cursor back on that tile. Closing the hub itself (B, its
		X, or the HUD Rewards button again) also closes a feature screen the hub opened.
		Deep links (Welcome Back, notifications, What's New CTAs, the tutorial) keep opening the
		feature screens directly by name; nothing here changes them.

	Data: UI/RewardsBadges (counts, kinds, timers — the same numbers as the HUD badge). The hub
	re-renders on RewardsBadges.Updated and, while open, ticks the countdown lines once a second
	(one loop, only while open; texts are written only when they change).

	Layout (owner R11, docs/platform.md §7): ResponsiveModal modes from RewardsHubConfig.Modes —
	"grid" (3 + 2 tiles: desktop, console, tablet) and "row" (one row: landscape phones, rendered
	unshrunk, tiles far above 44 pt, status text ≥ 14 pt, wraps to two lines — R78: six tiles,
	text floors converted from design px to rendered px so wrapped lines fit). Geometry + gamepad
	links come from the pure HubLayout. Console: default selection = the first CLAIMABLE tile (else
	the first tile); returning from a feature re-selects the tile that opened it; the top row's up
	goes to the header X; B closes (ScreenManager).

	Analytics (rule 9): "open:Rewards" / "openFrom:Rewards:<source>" when the hub opens; each tile
	open is the feature's own "openFrom:<Daily|Time|Wheel|Group|Codes>:hub" (the feature screens
	report their open with the source the hub passes).

	Security: display + navigation only. Every claim stays a server-validated intent inside the
	feature's own screen.

	Performance: lazy = false only so RewardsBadges starts at boot (the HUD badge); the tiles are
	built on the first open, once. Layout runs on open / rotation / device switch, never per frame.

	Connects to: UI/{RewardsBadges, ScreenManager, Create}, Kit/StudUI (hudButton, text),
	Widgets/StudWindow (outline / edge), Screens/DailyRewards/ResponsiveModal, Screens/RewardsHub/
	HubLayout, Platform/GamepadNav, Analytics/ClientAnalytics, Shared/Config/{RewardsHubConfig,
	UIStyleConfig}.

	Example:
		ScreenManager.open("RewardsHub")                      -- HUD Rewards button (source "hud")
		ScreenManager.open("RewardsHub", { source = "popup" }) -- any other entry point
		ScreenManager.open("RewardsHub", { open = "Daily" })  -- the hub with Daily stacked on top
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local ClientAnalytics = require(script.Parent.Parent.Parent.Analytics.ClientAnalytics)
local Create = require(script.Parent.Parent.Create)
local GamepadNav = require(script.Parent.Parent.Parent.Platform.GamepadNav)
local HubLayout = require(script.HubLayout)
local ResponsiveModal = require(script.Parent.DailyRewards.ResponsiveModal)
local RewardsBadges = require(script.Parent.Parent.RewardsBadges)
local RewardsHubConfig = require(ReplicatedStorage.Shared.Config.RewardsHubConfig)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Widgets.StudWindow)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local NAME = RewardsHubConfig.ScreenName
local Neutral = UIStyleConfig.Neutral

-- Status line colour per RewardsBadges tone.
local TONE_COLORS: { [string]: Color3 } = {
	ready = UIStyleConfig.Colors.green.accent,
	wait = Neutral.Text,
	info = Neutral.TextDim,
	done = Neutral.Placeholder,
}
-- Status pill outline thickness (design px).
local PILL_EDGE = 3
-- Seconds between countdown re-renders while the hub is open.
local TICK_SECONDS = 1

-- One hub tile (built once on the first open).
type Tile = {
	feature: RewardsHubConfig.Feature,
	holder: Frame,
	button: StudUI.HudButton,
	pill: Frame,
	status: TextLabel,
	statusLimit: UITextSizeConstraint?,
	text: string, -- last written status text
	tone: string, -- last written tone
	badge: string?, -- last written badge text
}

-- The analytics source from ScreenManager.open's args ({ source = "..." }), default "hud".
local function sourceOf(args: any?): string
	if type(args) == "table" and type(args.source) == "string" then
		return args.source
	end
	return "hud"
end

return ResponsiveModal.screen({
	name = NAME,
	title = "Rewards",
	color = "green",
	icon = "Rewards",
	modes = RewardsHubConfig.Modes,
	lazy = false, -- builds the (empty) window at boot so RewardsBadges starts for the HUD badge
	--[[
		Starts the badge model and wires the hub (tiles are created on the first open).
		@param window the StudUI window (tiles go in window.body)
		@param _gui   the hub's ScreenGui
		@param layout ResponsiveModal controller (mode / area / touch minimums)
		@return ScreenHandle
	]]
	build = function(
		window: StudUI.Window,
		_gui: ScreenGui,
		layout: ResponsiveModal.Controller
	): ScreenManager.ScreenHandle?
		RewardsBadges.start()

		local tiles: { Tile }? = nil
		local isOpen = false
		-- Tile index to re-select when a feature screen stacked over the hub closes.
		local returnTo: number? = nil
		-- The feature screen this hub opened (closed together with the hub).
		local child: string? = nil
		-- Bumped to stop the countdown loop (open / close).
		local tickToken = 0

		-- Writes one tile's badge + status line (only what changed).
		local function renderTile(tile: Tile, state: RewardsBadges.FeatureState?, now: number)
			local badge = if state ~= nil then RewardsBadges.formatBadge(state.count) else nil
			if badge ~= tile.badge then
				tile.badge = badge
				tile.button.setBadge(badge)
			end
			local text, tone = RewardsHubConfig.Text.Loading, "info"
			if state ~= nil then
				text, tone = RewardsBadges.statusText(state, now)
			end
			if text ~= tile.text then
				tile.text = text
				tile.status.Text = text
			end
			if tone ~= tile.tone then
				tile.tone = tone
				tile.status.TextColor3 = TONE_COLORS[tone] or Neutral.Text
			end
		end

		-- Re-renders every tile from the latest snapshot.
		local function renderAll()
			local list = tiles
			if list == nil then
				return
			end
			local snapshot = RewardsBadges.snapshot()
			local now = Workspace:GetServerTimeNow()
			for _, tile in list do
				renderTile(tile, snapshot.features[tile.feature.id], now)
			end
		end

		-- The first tile (hub order) with something claimable, or nil.
		local function firstClaimable(): number?
			local snapshot = RewardsBadges.snapshot()
			for index, feature in RewardsHubConfig.Features do
				local state = snapshot.features[feature.id]
				if state ~= nil and state.count > 0 then
					return index
				end
			end
			return nil
		end

		-- Hides the hub window while another modal is stacked on top of it (one window shows,
		-- and the gamepad cursor can never wander onto covered tiles); shows it again after.
		local function applyCovered()
			local covered = isOpen and not ScreenManager.isTopModal(NAME)
			if window.frame.Visible == covered then
				window.frame.Visible = not covered
			end
		end

		-- Opens tile `index`'s feature screen stacked over the hub.
		local function openFeature(index: number)
			local list = tiles
			if list == nil or not isOpen or not ScreenManager.isTopModal(NAME) then
				return -- a stray press while covered / closing
			end
			local feature = list[index].feature
			returnTo = index
			child = feature.screen
			ScreenManager.open(feature.screen, { source = RewardsHubConfig.TileSource })
			applyCovered()
		end

		-- Places the tiles + rewrites the gamepad links for the active layout.
		local function place(current: ResponsiveModal.Layout)
			local list = tiles
			if list == nil then
				return
			end
			local placement =
				HubLayout.place(current.mode, current.area.X, current.area.Y, #list, current.tap, current.minText)
			for index, tile in list do
				local spot = placement.tiles[index]
				tile.holder.Position = UDim2.fromOffset(spot.frame.x, spot.frame.y)
				tile.holder.Size = UDim2.fromOffset(spot.frame.width, spot.frame.height)
				tile.button.setSize(spot.side, spot.side)
				tile.button.setLabelFloor(if current.touch then current.minText else nil)
				tile.pill.Position = UDim2.fromOffset(spot.pill.x, spot.pill.y)
				tile.pill.Size = UDim2.fromOffset(spot.pill.width, spot.pill.height)
				local limit = tile.statusLimit
				if limit ~= nil then
					-- Rendered-px limits (HubLayout.textLimits: touch floor = 14 pt, never the raw
					-- design-px number — R78 fix for the cut second line on phones).
					local maxSize, minSize = HubLayout.textLimits(spot)
					limit.MaxTextSize = maxSize
					limit.MinTextSize = minSize
				end
				StudWindow.outline(
					tile.status,
					math.max(2, math.floor(spot.textSize * UIStyleConfig.Button.TextStrokeRatio + 0.5))
				)
			end
			-- Gamepad: rows from HubLayout; the top row's up (and the X's down) is the header X.
			local links = HubLayout.links(placement)
			for index, tile in list do
				local link = links[index]
				local instance = tile.button.instance
				local function at(i: number?): GuiObject?
					return if i ~= nil then list[i].button.instance else nil
				end
				instance.NextSelectionLeft = at(link.left) :: any
				instance.NextSelectionRight = at(link.right) :: any
				instance.NextSelectionUp = (at(link.up) or window.closeButton) :: any
				instance.NextSelectionDown = at(link.down) :: any
			end
			window.closeButton.NextSelectionDown = list[1].button.instance
		end

		-- Builds the tiles once (first open).
		local function ensureTiles(): { Tile }
			local existing = tiles
			if existing ~= nil then
				return existing
			end
			local container = Create.new("Frame", {
				Name = "Tiles",
				BackgroundTransparency = 1,
				Size = UDim2.fromScale(1, 1),
				Active = false,
				Parent = window.body,
			}) :: Frame
			local list: { Tile } = {}
			for index, feature in RewardsHubConfig.Features do
				local holder = Create.new("Frame", {
					Name = `Tile_{feature.id}`,
					BackgroundTransparency = 1,
					Active = false,
					Parent = container,
				}) :: Frame
				local button = StudUI.hudButton({
					label = feature.label,
					icon = feature.icon,
					color = feature.color,
					name = `Open{feature.id}`,
					parent = holder,
					onActivated = function()
						openFeature(index)
					end,
				})
				button.instance.AnchorPoint = Vector2.new(0.5, 0)
				button.instance.Position = UDim2.fromScale(0.5, 0)
				-- The status pill: a dark inset well with the kit's outline (like the code box).
				local pill = Create.new("Frame", {
					Name = "Status",
					BackgroundColor3 = Neutral.Well,
					Active = false,
					Parent = holder,
					Children = {
						Create.new("UICorner", { CornerRadius = UDim.new(0, 12) }),
						Create.new("UIPadding", {
							PaddingLeft = UDim.new(0, RewardsHubConfig.Layout.PillPad),
							PaddingRight = UDim.new(0, RewardsHubConfig.Layout.PillPad),
							PaddingTop = UDim.new(0, RewardsHubConfig.Layout.PillPad),
							PaddingBottom = UDim.new(0, RewardsHubConfig.Layout.PillPad),
						}),
					},
				}) :: Frame
				StudWindow.edge(pill, PILL_EDGE)
				local status = StudUI.text({
					name = "StatusText",
					text = RewardsHubConfig.Text.Loading,
					textSize = RewardsHubConfig.Layout.StatusText,
					scaled = true, -- long lines shrink (to the touch floor) and wrap
					wrap = true,
					color = Neutral.TextDim,
					size = UDim2.fromScale(1, 1),
					parent = pill,
				})
				table.insert(list, {
					feature = feature,
					holder = holder,
					button = button,
					pill = pill,
					status = status,
					statusLimit = status:FindFirstChildOfClass("UITextSizeConstraint"),
					text = RewardsHubConfig.Text.Loading,
					tone = "info",
					badge = nil,
				})
			end
			tiles = list
			place(layout.current())
			return list
		end

		-- Re-renders the countdown lines once a second while the hub is open (one loop).
		local function startTicker()
			tickToken += 1
			local token = tickToken
			task.spawn(function()
				while token == tickToken do
					task.wait(TICK_SECONDS)
					if token ~= tickToken then
						break
					end
					renderAll()
				end
			end)
		end

		layout.onChanged(place)
		RewardsBadges.Updated:Connect(function(_snapshot: RewardsBadges.Snapshot)
			if isOpen then
				renderAll()
			end
		end)
		ScreenManager.Opened:Connect(function(_name: string)
			if isOpen then
				applyCovered()
			end
		end)
		ScreenManager.Closed:Connect(function(name: string)
			if name == child then
				child = nil
			end
			if isOpen then
				applyCovered()
			end
		end)

		return {
			onOpen = function(args: any?)
				ensureTiles()
				isOpen = true
				applyCovered()
				RewardsBadges.recheckGroup() -- a player may have joined the group on the website
				renderAll()
				startTicker()
				ClientAnalytics.screenOpened(RewardsHubConfig.AnalyticsScreen, sourceOf(args))
				-- Deep link into one tile: { open = "<FeatureId>" } stacks that feature over the hub
				-- exactly like pressing its tile (B returns to the hub). Unknown ids are ignored.
				local wanted = if type(args) == "table" then args.open else nil
				if type(wanted) == "string" then
					for index, feature in RewardsHubConfig.Features do
						if feature.id == wanted then
							task.defer(openFeature, index) -- after ScreenManager finished opening the hub
							break
						end
					end
				end
			end,
			onClose = function()
				isOpen = false
				tickToken += 1 -- stops the countdown loop
				returnTo = nil
				window.frame.Visible = true -- the next open starts uncovered
				local opened = child
				child = nil
				-- The HUD Rewards button toggling the hub closed also closes what the hub opened.
				if opened ~= nil and ScreenManager.isOpen(opened) then
					ScreenManager.close(opened)
				end
			end,
			-- Gamepad: back on the tile that opened the closed feature, else the first claimable.
			defaultSelection = function(): GuiObject?
				local list = tiles
				if list == nil then
					return nil
				end
				local index = returnTo or firstClaimable() or 1
				local tile = list[index]
				return if tile ~= nil then tile.button.instance else GamepadNav.firstSelectable(window.body)
			end,
		}
	end,
})
