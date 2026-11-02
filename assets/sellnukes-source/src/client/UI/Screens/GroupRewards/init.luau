--!strict
--[[
	GroupRewards — the "Rewards" window behind the HUD's Rewards button (design spec §7;
	reference docs/reference/ui-style/06-group-rewards.png): orange header, a dark studded well
	on the left showing what the group reward gives ("+$10K", "+25 Gems", "+1 Pet" tiles on a
	soft sunburst), and on the right "Join our ROBLOX Group for exclusive rewards!" (ROBLOX red,
	exclusive blue) above the action buttons and a status line.

	Buttons (from GroupConfig + the profile snapshot):
		GroupConfig.isEnabled() == false → grey locked "COMING SOON" + "Group coming soon!"
		profile.group.claimed            → "CLAIMED"
		otherwise                        → blue "JOIN GROUP" (Roblox's in-game join prompt,
		                                   GroupService:PromptJoinAsync; joining claims right
		                                   away) + green "CLAIM" → ClaimGroupReward()
	The status line shows the latest GroupRewardResult.text (green ok / red otherwise).

	Console / mobile (owner R11, docs/platform.md §7): the gamepad cursor starts on JOIN GROUP
	(else CLAIM / the locked button; never the X); the visible buttons are linked across, up
	goes to the header X. B / Back closes through ScreenManager. The right column is
	top-aligned (pitch, buttons, status, group name) so the buttons stay above Roblox's
	thumbstick / jump corners on short phones; taps ≥ 44 pt, text ≥ 14 pt after scaling.

	Security: intents only. Membership is re-checked by the server on every claim
	(Player:IsInGroupAsync), the reward is granted server-side once per player; the preview
	tiles are RewardPreview's display of the same income rule.

	Connects to: Kit/StudUI, Widgets/{PanelBackdrop, StudWindow}, UI/{Create, ScreenManager},
	Platform/GamepadNav,
	Client/{ClientState, Analytics/ClientAnalytics}, Screens/DailyRewards/RewardPreview,
	Shared/Config/{GroupConfig, UIStyleConfig}, Shared/Net/Remotes (ClaimGroupReward,
	GroupRewardResult).

	Example: ScreenManager.open("GroupRewards")
]]

local GroupService = game:GetService("GroupService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientAnalytics = require(script.Parent.Parent.Parent.Analytics.ClientAnalytics)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.Create)
local GamepadNav = require(script.Parent.Parent.Parent.Platform.GamepadNav)
local GroupConfig = require(ReplicatedStorage.Shared.Config.GroupConfig)
local PanelBackdrop = require(script.Parent.Parent.Widgets.PanelBackdrop)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local RewardPreview = require(script.Parent.DailyRewards.RewardPreview)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Widgets.StudWindow)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local NAME = "GroupRewards"
local ANALYTICS_SCREEN = "Group"
-- Seconds CLAIM stays disabled after a press (the server also rate-limits each web check).
local CLAIM_COOLDOWN = 2
-- Longest server text shown (defensive cap).
local MAX_SERVER_TEXT = 200
-- Profile fields the preview (income-scaled cash) and the button state depend on.
local PREVIEW_FIELDS = { "tycoon", "rebirths", "rebirthShop", "group" }

-- Geometry (design px inside the window body).
local WINDOW_SIZE = Vector2.new(1000, 580)
local WELL_WIDTH = 430
local COLUMN_GAP = 22
local TILE_ICON = 118
local TILE_TEXT = 34
local BUTTON_HEIGHT = 84

local Neutral = UIStyleConfig.Neutral
local OK_COLOR = UIStyleConfig.Colors.green.accent
local ERROR_COLOR = Neutral.Danger
local RED_WORD = Neutral.Danger
local BLUE_WORD = UIStyleConfig.Colors.blue.accent

-- Escapes the five RichText special characters (config text can never inject markup).
local function escapeRich(text: string): string
	return (
		string.gsub(text, "[&<>\"']", {
			["&"] = "&amp;",
			["<"] = "&lt;",
			[">"] = "&gt;",
			['"'] = "&quot;",
			["'"] = "&apos;",
		})
	)
end

-- One coloured RichText span (text escaped).
local function span(text: string, color: Color3): string
	return `<font color="#{color:ToHex()}">{escapeRich(text)}</font>`
end

-- Server text that is safe to show (non-empty string, capped), else nil.
local function serverText(value: unknown): string?
	if type(value) == "string" and #value > 0 and #value <= MAX_SERVER_TEXT then
		return value
	end
	return nil
end

-- True when the changed-field list `fields` (nil = everything) contains any of `names`.
local function touches(fields: { string }?, names: { string }): boolean
	if fields == nil then
		return true
	end
	for _, name in names do
		if table.find(fields, name) ~= nil then
			return true
		end
	end
	return false
end

-- True when the snapshot says the group reward was already claimed.
local function isClaimed(profile: ClientState.Profile?): boolean
	local group = if profile ~= nil then profile.group else nil
	return type(group) == "table" and group.claimed == true
end

--[[
	Tile caption for one preview line: "+$10K", "+25 Gems", and "+1 Pet" / "+1 Egg" for items
	(RewardPreview names items without a count).
]]
local function tileText(line: RewardPreview.Line): string
	if line.icon == "Pets" or line.icon == "Gift" then
		return `+1 {line.text}`
	end
	return `+{line.text}`
end

return StudUI.modalScreen({
	name = NAME,
	title = "Rewards",
	color = "orange",
	icon = "Rewards",
	size = WINDOW_SIZE,
	--[[
		Fills the window: reward well (left), pitch + buttons + status (right).
		@param window the StudUI window
		@return ScreenHandle
	]]
	build = function(window: StudUI.Window): ScreenManager.ScreenHandle?
		local body = window.body

		-- ── Left: the dark studded well with the reward tiles ──
		local well = Create.new("Frame", {
			Name = "RewardWell",
			Size = UDim2.new(0, WELL_WIDTH, 1, 0),
			BackgroundColor3 = Neutral.Well,
			BorderSizePixel = 0,
			Parent = body,
			Children = { Create.new("UICorner", { CornerRadius = UDim.new(0, 10) }) },
		}) :: Frame
		PanelBackdrop.new(well, {
			zIndex = 1,
			textureTransparency = UIStyleConfig.StudTransparency.Body,
			tileSize = UIStyleConfig.StudTile.Card,
		})
		-- Rays are rotated children: an unrotated clip lane keeps them inside the well.
		local burstClip = Create.new("Frame", {
			Name = "BurstClip",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			ClipsDescendants = true,
			Active = false,
			ZIndex = 2,
			Parent = well,
		}) :: Frame
		StudWindow.sunburst(burstClip, { zIndex = 2, size = UDim2.fromScale(1.5, 1.5) })
		local tiles = Create.new("Frame", {
			Name = "Tiles",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 3,
			Parent = well,
			Children = {
				Create.new("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					Padding = UDim.new(0, 6),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
			},
		}) :: Frame

		-- ── Right: pitch, group name, buttons, status ──
		local column = Create.new("Frame", {
			Name = "Pitch",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(WELL_WIDTH + COLUMN_GAP, 0),
			Size = UDim2.new(1, -(WELL_WIDTH + COLUMN_GAP), 1, 0),
			Parent = body,
			Children = {
				Create.new("UIListLayout", {
					FillDirection = Enum.FillDirection.Vertical,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					-- Top-aligned: the buttons stay out of the bottom touch corners on phones.
					VerticalAlignment = Enum.VerticalAlignment.Top,
					Padding = UDim.new(0, 10),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
			},
		}) :: Frame
		StudUI.text({
			name = "Join",
			text = `Join our {span("ROBLOX", RED_WORD)} Group for {span("exclusive", BLUE_WORD)} rewards!`,
			rich = true,
			textSize = 50,
			scaled = true, -- never overflows its box (50 px is the cap)
			align = Enum.TextXAlignment.Left,
			size = UDim2.new(1, 0, 0, 190),
			layoutOrder = 1,
			parent = column,
		})
		local groupName = StudUI.text({
			name = "GroupName",
			text = "",
			textSize = 26,
			color = Neutral.TextDim,
			align = Enum.TextXAlignment.Left,
			size = UDim2.new(1, 0, 0, 30),
			layoutOrder = 4,
			parent = column,
		})
		local buttonRow = Create.new("Frame", {
			Name = "Buttons",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT + UIStyleConfig.Button.Lip + 4),
			LayoutOrder = 2,
			Parent = column,
			Children = {
				Create.new("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					VerticalAlignment = Enum.VerticalAlignment.Top,
					Padding = UDim.new(0, 14),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
			},
		}) :: Frame
		local status = StudUI.text({
			name = "Status",
			text = "",
			textSize = 28,
			wrap = true,
			size = UDim2.new(1, 0, 0, 64),
			layoutOrder = 3,
			parent = column,
		})

		-- Shows `text` in the status line.
		local function setStatus(text: string, color: Color3)
			status.Text = text
			status.TextColor3 = color
		end

		local claimUntil = 0
		local joining = false
		local tilesDirty = true
		local joinButton: StudUI.Button
		local claimButton: StudUI.Button

		-- Rebuilds the reward tiles from the current profile (only on change / open).
		local function renderTiles()
			tilesDirty = false
			for _, child in tiles:GetChildren() do
				if child:IsA("GuiObject") then
					child:Destroy()
				end
			end
			local lines = RewardPreview.lines(GroupConfig.Reward, ClientState.profile)
			local count = math.max(1, #lines)
			local tileW = math.min(140, math.floor((WELL_WIDTH - 24 - 6 * (count - 1)) / count))
			local iconSide = math.min(TILE_ICON, tileW)
			for index, line in lines do
				local tile = Create.new("Frame", {
					Name = `Tile{index}`,
					BackgroundTransparency = 1,
					Size = UDim2.fromOffset(tileW, iconSide + TILE_TEXT + 18),
					-- A slight alternating tilt, like the reference's playful reward art.
					Rotation = if index % 2 == 1 then -6 else 6,
					LayoutOrder = index,
					ZIndex = 3,
					Parent = tiles,
				}) :: Frame
				local icon = StudUI.icon(line.icon, iconSide, 4)
				icon.AnchorPoint = Vector2.new(0.5, 0)
				icon.Position = UDim2.fromScale(0.5, 0)
				icon.Parent = tile
				StudUI.text({
					name = "Amount",
					text = tileText(line),
					textSize = TILE_TEXT,
					font = "number",
					scaled = true,
					size = UDim2.new(1, 12, 0, TILE_TEXT + 8),
					position = UDim2.new(0.5, 0, 0, iconSide + 4),
					anchor = Vector2.new(0.5, 0),
					zIndex = 5,
					parent = tile,
				})
			end
		end

		-- Button states from GroupConfig + profile.group.claimed.
		local function renderButtons()
			local enabled = GroupConfig.isEnabled()
			local claimed = isClaimed(ClientState.profile)
			groupName.Visible = enabled and GroupConfig.GroupName ~= ""
			groupName.Text = if enabled then `Group: {GroupConfig.GroupName}` else ""
			if not enabled then
				joinButton.instance.Visible = false
				claimButton.instance.Size = UDim2.fromOffset(380, BUTTON_HEIGHT)
				claimButton.setState("locked", "COMING SOON")
			elseif claimed then
				joinButton.instance.Visible = false
				claimButton.instance.Size = UDim2.fromOffset(380, BUTTON_HEIGHT)
				claimButton.setState("claimed")
			else
				joinButton.instance.Visible = true
				joinButton.setState(if joining then "disabled" else "normal")
				claimButton.instance.Size = UDim2.fromOffset(220, BUTTON_HEIGHT)
				claimButton.setState(if os.clock() < claimUntil then "disabled" else "normal")
			end
			-- Gamepad: link only the buttons on screen (across), up to the header X.
			local cells: { GuiObject } = {}
			if joinButton.instance.Visible then
				table.insert(cells, joinButton.instance)
			end
			table.insert(cells, claimButton.instance)
			GamepadNav.linkList(cells, false, { up = window.closeButton })
		end

		-- CLAIM: one ClaimGroupReward per CLAIM_COOLDOWN s (server re-checks membership).
		local function claim()
			local now = os.clock()
			if now < claimUntil or not GroupConfig.isEnabled() or isClaimed(ClientState.profile) then
				return
			end
			claimUntil = now + CLAIM_COOLDOWN
			setStatus("Checking...", Neutral.TextDim)
			renderButtons()
			task.delay(CLAIM_COOLDOWN, renderButtons)
			Remotes.event("ClaimGroupReward"):FireServer()
		end

		-- JOIN GROUP: Roblox's in-game join prompt; a join (or already a member) claims at once.
		local function join()
			if joining or not GroupConfig.isEnabled() then
				return
			end
			joining = true
			renderButtons()
			task.spawn(function()
				local ok, result = pcall(function(): Enum.GroupMembershipStatus
					return GroupService:PromptJoinAsync(GroupConfig.GroupId)
				end)
				joining = false
				renderButtons()
				-- Roblox's prompt may drop the gamepad cursor: put it back on CLAIM.
				if ScreenManager.isOpen(NAME) then
					GamepadNav.select(claimButton.instance)
				end
				if not ok then
					setStatus("Couldn't open the group prompt. Try again soon!", ERROR_COLOR)
				elseif
					result == Enum.GroupMembershipStatus.Joined
					or result == Enum.GroupMembershipStatus.AlreadyMember
				then
					claim()
				elseif result == Enum.GroupMembershipStatus.JoinRequestPending then
					setStatus("Join request sent! Press CLAIM once you are in.", Neutral.TextDim)
				end
			end)
		end

		joinButton = StudUI.button({
			text = "JOIN GROUP",
			color = "blue",
			textSize = 36,
			size = UDim2.fromOffset(240, BUTTON_HEIGHT),
			name = "JoinGroup",
			layoutOrder = 1,
			parent = buttonRow,
			onActivated = join,
		})
		claimButton = StudUI.button({
			text = "CLAIM",
			color = "green",
			textSize = 44,
			size = UDim2.fromOffset(220, BUTTON_HEIGHT),
			name = "Claim",
			layoutOrder = 2,
			parent = buttonRow,
			onActivated = claim,
		})

		-- Gamepad defaults: JOIN GROUP while it is shown, else CLAIM (or the locked button).
		local selectJoin = GamepadNav.defaultSelection(body, joinButton.instance)
		local selectClaim = GamepadNav.defaultSelection(body, claimButton.instance)

		-- Profile pushes: refresh the preview (income-scaled cash) and the button state.
		ClientState.ProfileChanged:Connect(function(_profile: ClientState.Profile, fields: { string }?)
			if not touches(fields, PREVIEW_FIELDS) then
				return
			end
			tilesDirty = true
			if ScreenManager.isOpen(NAME) then
				renderTiles()
				renderButtons()
			end
		end)

		-- Server answers (connected off the build thread: Remotes.event may wait for replication).
		task.spawn(function()
			Remotes.event("GroupRewardResult").OnClientEvent:Connect(function(raw: unknown)
				if type(raw) ~= "table" then
					return
				end
				local result = raw :: { [string]: unknown }
				local text = serverText(result.text)
				if text ~= nil then
					setStatus(text, if result.ok == true then OK_COLOR else ERROR_COLOR)
				end
			end)
		end)

		return {
			onOpen = function(args: any?)
				if tilesDirty then
					renderTiles()
				end
				renderButtons()
				if GroupConfig.isEnabled() then
					setStatus("", Neutral.TextDim)
				else
					setStatus("Group coming soon!", Neutral.TextDim)
				end
				local source = if type(args) == "table" and type(args.source) == "string" then args.source else "hud"
				ClientAnalytics.screenOpened(ANALYTICS_SCREEN, source)
			end,
			defaultSelection = function(): GuiObject?
				return if joinButton.instance.Visible then selectJoin() else selectClaim()
			end,
		}
	end,
})
