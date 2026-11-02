--!strict
--[[
	Friends — the R78 Friends window (spec §4; docs/social.md), opened from the Rewards hub tile
	"Friends" (RewardsHubConfig) or by name. A blue stud window:

		┌ FRIEND BOOST ─────────────┐  ┌ INVITE REWARDS ───────────┐
		│        +20% CASH          │  │          3 / 10            │
		│   [■][■][□][□][□]          │  │   [████████░░░░░░░░░░░]    │
		│  Bob, Ann are here!       │  │ You: +100 Gems + 1 Spin ... │
		└───────────────────────────┘  └───────────────────────────┘
		              [  INVITE FRIENDS  ]
		           Pick friends to invite!

	Boost card: the server's Friend Boost (SocialClient.friends(): percent, friends here, names),
	five pips = the +50 % cap. Rewards card: inviter rewards received (profile `referral.paid`)
	out of Referral.MaxPaid with a stud progress bar, what each side gets, and "You joined through
	a friend's invite!" when this player was referred. INVITE FRIENDS opens Roblox's invite prompt
	(SocialClient.invite → SocialService); the status line shows the outcome ("Invites aren't
	available here" on accounts / devices that cannot invite).

	Console + mobile (owner R11, docs/platform.md §7): the gamepad cursor starts on INVITE FRIENDS;
	Up reaches the header X; B / Back closes (ScreenManager). 1040 x 600 design px so a landscape
	phone keeps the fit near 0.95: the button stays far above 44 pt and every text >= 14 pt (26+
	design px). The labels are sized so their scaled text stays >= 14 pt WITHOUT a size floor — a
	UITextSizeConstraint floor stops a phone label from shrinking and clips it (verified in the
	device matrix). Nothing scrolls.

	Security: display + an invite INTENT only. Percent, counts and rewards are server state; the
	invite outcome report (FriendInvite) is analytics only on the server.

	Performance: built lazily on first open; re-renders on SocialClient.Changed / InviteResult only
	while open (event-driven, no loops).

	Connects to: Client/Social/SocialClient, Kit/StudUI, UI/{Create, ScreenManager},
	Platform/GamepadNav, Widgets/StudWindow, Client/Analytics/ClientAnalytics,
	Shared/Config/{SocialConfig, UIStyleConfig}.

	Example: ScreenManager.open("Friends", { source = "hub" })
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientAnalytics = require(script.Parent.Parent.Parent.Analytics.ClientAnalytics)
local Create = require(script.Parent.Parent.Create)
local GamepadNav = require(script.Parent.Parent.Parent.Platform.GamepadNav)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local SocialClient = require(script.Parent.Parent.Parent.Social.SocialClient)
local SocialConfig = require(ReplicatedStorage.Shared.Config.SocialConfig)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Widgets.StudWindow)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local NAME = "Friends"
local ANALYTICS_SCREEN = "Friends"
local CLIENT = SocialConfig.Client
local REFERRAL = SocialConfig.Referral
local FRIENDS = SocialConfig.Friends
local Neutral = UIStyleConfig.Neutral

-- Geometry (design px).
local WINDOW_SIZE = Vector2.new(1040, 600)
local CARDS_HEIGHT = 300
local CARD_TITLE = 40
local PIP_SIZE = 46
local PIP_GAP = 10
local BUTTON_SIZE = Vector2.new(560, 96)
local STATUS_HEIGHT = 40

-- The Friends icon, or its fallback until the icon is uploaded.
local ICON = if StudUI.hasIcon(CLIENT.FriendsIcon) then CLIENT.FriendsIcon else CLIENT.FriendsIconFallback

-- Status lines per invite outcome (kid-short).
local INVITE_TEXT: { [string]: string } = {
	prompted = "Pick friends to invite!",
	sent = "Invites sent! Rewards come when they join.",
	closed = "No invites sent. Try again any time!",
	unavailable = "Invites aren't available here.",
	failed = "Couldn't open invites. Try again!",
}

-- A vertical list layout inside `parent`, starting under a card title.
local function cardList(parent: Instance)
	Create.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Top,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = parent,
	})
	Create.new("Frame", {
		Name = "TitleSpace",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, CARD_TITLE),
		LayoutOrder = 0,
		Parent = parent,
	})
end

return StudUI.modalScreen({
	name = NAME,
	title = "Friends",
	color = "blue",
	icon = ICON,
	size = WINDOW_SIZE,
	--[[
		Fills the window: the two cards, INVITE FRIENDS and the status line.
		@param window the StudUI window
		@return ScreenHandle (renders on open; gamepad starts on INVITE FRIENDS)
	]]
	build = function(window: StudUI.Window): ScreenManager.ScreenHandle?
		local body = window.body
		Create.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Top,
			Padding = UDim.new(0, 12),
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = body,
		})

		local cards = Create.new("Frame", {
			Name = "Cards",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, -24, 0, CARDS_HEIGHT),
			LayoutOrder = 1,
			Parent = body,
			Children = {
				Create.new("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					Padding = UDim.new(0, 16),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
			},
		}) :: Frame

		-- ── Friend Boost card ──────────────────────────────────────────────────────────────────
		local boostCard = StudUI.card({
			color = "blue",
			sunburst = true,
			title = "FRIEND BOOST",
			titleSize = 34,
			size = UDim2.new(0.5, -8, 1, 0),
			layoutOrder = 1,
			name = "BoostCard",
			parent = cards,
		})
		cardList(boostCard.content)
		local percentLabel = StudUI.text({
			name = "Percent",
			text = "+0% CASH",
			textSize = 64,
			font = "shout",
			color = Neutral.CashGreen,
			scaled = true,
			size = UDim2.new(1, 0, 0, 70),
			layoutOrder = 1,
			parent = boostCard.content,
		})
		local pipRow = Create.new("Frame", {
			Name = "Pips",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, PIP_SIZE),
			LayoutOrder = 2,
			Parent = boostCard.content,
			Children = {
				Create.new("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					Padding = UDim.new(0, PIP_GAP),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
			},
		}) :: Frame
		-- One pip per friend up to the cap (+MaxPercent at the default percent per friend).
		local pipCount = math.max(1, math.floor(FRIENDS.MaxPercent / FRIENDS.PercentPerFriend))
		local pips: { StudWindow.Surface } = {}
		for index = 1, pipCount do
			local pip = Create.new("Frame", {
				Name = `Pip{index}`,
				Size = UDim2.fromOffset(PIP_SIZE, PIP_SIZE),
				LayoutOrder = index,
				Parent = pipRow,
			}) :: Frame
			table.insert(pips, StudWindow.surface(pip, "grey", { edge = 3, corner = 8 }))
		end
		local namesLabel = StudUI.text({
			name = "Names",
			text = "",
			textSize = 30,
			scaled = true,
			wrap = true,
			size = UDim2.new(1, -8, 0, 92),
			layoutOrder = 3,
			parent = boostCard.content,
		})

		-- ── Invite rewards card ────────────────────────────────────────────────────────────────
		local rewardCard = StudUI.card({
			color = "purple",
			sunburst = true,
			title = "INVITE REWARDS",
			titleSize = 34,
			size = UDim2.new(0.5, -8, 1, 0),
			layoutOrder = 2,
			name = "RewardCard",
			parent = cards,
		})
		cardList(rewardCard.content)
		local progressLabel = StudUI.text({
			name = "Progress",
			text = `0 / {REFERRAL.MaxPaid}`,
			textSize = 56,
			font = "number",
			scaled = true,
			size = UDim2.new(1, 0, 0, 60),
			layoutOrder = 1,
			parent = rewardCard.content,
		})
		local bar = StudUI.progressBar({
			color = "green",
			size = UDim2.new(0.86, 0, 0, 30),
			layoutOrder = 2,
			parent = rewardCard.content,
		})
		local inviter, newcomer = REFERRAL.InviterReward, REFERRAL.NewcomerReward
		local newcomerBoost = newcomer.boost
		StudUI.text({
			name = "Rewards",
			text = string.format(
				"Per new friend who joins:\nYou: +%d Gems + %d Spin\nThem: +%d Gems + 2x Cash %d min",
				inviter.gems or 0,
				inviter.spins or 0,
				newcomer.gems or 0,
				if newcomerBoost ~= nil then newcomerBoost.seconds // 60 else 0
			),
			textSize = 28,
			scaled = true,
			wrap = true,
			size = UDim2.new(1, -8, 0, 124),
			layoutOrder = 3,
			parent = rewardCard.content,
		})

		-- ── INVITE FRIENDS + status ────────────────────────────────────────────────────────────
		local status: TextLabel
		local invite = StudUI.button({
			name = "Invite",
			text = "INVITE FRIENDS",
			color = "green",
			icon = ICON,
			textSize = 46,
			size = UDim2.fromOffset(BUTTON_SIZE.X, BUTTON_SIZE.Y),
			layoutOrder = 2,
			parent = body,
			onActivated = function()
				if SocialClient.invite() then
					status.Text = "Opening invites..."
					status.TextColor3 = Neutral.TextDim
				end
			end,
		})
		status = StudUI.text({
			name = "Status",
			text = "",
			textSize = 30,
			scaled = true,
			size = UDim2.new(1, -24, 0, STATUS_HEIGHT),
			layoutOrder = 3,
			parent = body,
		})
		-- Up from the button reaches the header X (the only other control).
		GamepadNav.linkList({ invite.instance :: GuiObject }, false, { up = window.closeButton })
		local selectDefault = GamepadNav.defaultSelection(body, invite.instance)

		local isOpen = false

		-- Writes every value from SocialClient (only while open).
		local function render()
			if not isOpen then
				return
			end
			local live = SocialClient.live()
			local friends = SocialClient.friends()
			local percent = if live.friendsOn then friends.percent else 0
			percentLabel.Text = `+{percent}% CASH`
			local lit = math.clamp(math.ceil(percent / math.max(1, live.friendPercent)), 0, #pips)
			for index, pip in pips do
				local color: any = if index <= lit then "green" else "grey"
				if pip.color() ~= color then
					pip.setColor(color)
				end
			end
			if not live.friendsOn then
				namesLabel.Text = "Friend Boost is resting right now. Play together anyway!"
			elseif friends.count > 0 then
				local names = table.concat(friends.names, ", ")
				namesLabel.Text = if friends.count == 1
					then `{names} is here with you!`
					else `{names} are here with you!`
			else
				namesLabel.Text = string.format(
					"+%d%% cash for each Roblox friend in your server (max +%d%%)!",
					live.friendPercent,
					FRIENDS.MaxPercent
				)
			end
			local referral = SocialClient.referral()
			progressLabel.Text = `{referral.paid} / {referral.max}`
			bar.setProgress(if referral.max > 0 then math.clamp(referral.paid / referral.max, 0, 1) else 0)
			if referral.invited and status.Text == "" then
				status.Text = "You joined through a friend's invite!"
				status.TextColor3 = UIStyleConfig.Colors.green.accent
			end
			if SocialClient.isInviting() then
				invite.setState("disabled")
			elseif referral.paid >= referral.max then
				-- Rewards are maxed; invites still work (friends still get their newcomer gift).
				invite.setState("normal", "INVITE FRIENDS")
			else
				invite.setState("normal")
			end
		end

		SocialClient.Changed:Connect(render)
		SocialClient.InviteResult:Connect(function(action: string)
			local text = INVITE_TEXT[action]
			if text ~= nil then
				status.Text = text
				status.TextColor3 = if action == "sent" or action == "prompted"
					then UIStyleConfig.Colors.green.accent
					else Neutral.TextDim
			end
			render()
		end)

		return {
			onOpen = function(args: any?)
				isOpen = true
				status.Text = ""
				render()
				local source = if type(args) == "table" and type(args.source) == "string" then args.source else "hud"
				ClientAnalytics.screenOpened(ANALYTICS_SCREEN, source)
			end,
			onClose = function()
				isOpen = false
			end,
			defaultSelection = selectDefault,
		}
	end,
})
