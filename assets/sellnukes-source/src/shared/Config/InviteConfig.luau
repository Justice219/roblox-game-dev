--!strict
--[[
	InviteConfig — tunables of the owner R122 co-play surfacing (spec
	docs/superpowers/specs/2026-11-01-r122-algorithm-pack-design.md §2.4).

	Why: Roblox ranks "intentional co-play days" (join / invite / private server) as an important
	signal. 252 of 266 sessions (10-31) had no friend in the server; the R78 INVITE FRIENDS flow +
	Friend Boost exist, but the Friends window (buried in the Rewards hub) was opened ONCE in two
	days and Friend Boost found 0 friends in 144 of 145 joins. So the invite moves onto the HUD:
		Hud     a small INVITE stud button in the top-right corner (HudZones "TopRight", left of the
		        admin chip) with a "+10%" sticker = the LIVE Friend Boost percent per friend
		        (SocialConfig.live().friendPercent; hidden while the boost is switched off). It opens
		        Roblox's invite prompt directly (Social/SocialClient.invite: SocialService
		        PromptGameInvite; referrals ride Roblox's own invite join data). Hidden when this
		        account / device cannot send invites (SocialService:CanSendGameInviteAsync).
		Moment  ONE small non-modal card per session (bottom-left feed, PopupQueue kind
		        "inviteMoment", low priority): "PLAY WITH FRIENDS!" with INVITE / LATER, after area 2
		        is unlocked — AfterUnlockSeconds after an unlock this session, never before
		        MinSessionSeconds into the session, never while a friend is already here, during the
		        tutorial or when invites are unavailable.
	Analytics (social family, FriendService via the FriendInvite remote; every report is capped per
	player session on the server): friends:hud:<shown|tap>, friends:moment:<shown|invite|later>.
	The prompt's own outcome keeps counting friends:invite:<prompted|sent|closed|unavailable|failed>.

	SocialConfig.Invite keeps the prompt message, the button cooldown and the remote's rate limit;
	this file holds only the R122 surfaces.

	Connects to: Client/Social/{InviteClient, InviteLogic}, UI/Hud/{HudInvite, Hud},
	UI/Screens/InviteMoment, Widgets/HudPlacement (invite rect), Server/Services/FriendService
	(report allowlist + caps), Shared/Config/{SocialConfig, PopupQueueConfig, AnalyticsConfig},
	tests/invite-surface.luau.

	Example:
		InviteConfig.Moment.AfterUnlockSeconds --> 90
		InviteConfig.reportAllowed({}, "hud:tap") --> true
]]

local PlatformConfig = require(script.Parent.PlatformConfig)

local InviteConfig = {}

-- ── HUD INVITE button (UI/Hud/HudInvite) ──────────────────────────────────────────────────────────

InviteConfig.Hud = table.freeze({
	Label = "INVITE",
	-- IconAssets key (the R78 Friends handshake); the fallback while it is not mapped / approved.
	Icon = "Friends",
	IconFallback = "Star",
	Color = "blue",
	-- Design px on desktop / console; touch devices grow the height to the 44 pt tap (width keeps
	-- the same ratio). Phones use PhoneWidth (label still >= 14 pt).
	Width = 190,
	Height = 64,
	PhoneWidth = 150,
	TextSize = 28,
	-- The "+10%" sticker: a tilted yellow stud chip on the button's top-left corner (overhangs a
	-- little, like the boost badge on the cash counter).
	BadgeColor = "yellow",
	BadgeFormat = "+%d%%",
	BadgeWidth = 78,
	BadgeHeight = 34,
	BadgeTextSize = 24,
	BadgeTilt = -8,
	BadgeOverhang = Vector2.new(14, 12),
	-- Phones: the sticker text is never under this (points).
	BadgePoints = 14,
	-- Direct binding (no modal open): keyboard P ("party"), gamepad L3 (left stick click: free on
	-- every pad layout; D-pad left / right focus the HUD columns, R3 is the golden revenge chip).
	Key = Enum.KeyCode.P,
	Pad = Enum.KeyCode.ButtonL3,
	GlyphHeight = 28,
	-- Pop when the sticker first shows / the percent changes (Reduce Motion: none).
	PopScale = 1.2,
	PopSeconds = 0.25,
})

-- ── The once-per-session invite moment (UI/Screens/InviteMoment) ──────────────────────────────────

InviteConfig.Moment = table.freeze({
	-- Area that must be unlocked (main world; a rebirthed player has unlocked it before).
	MinArea = 2,
	-- Seconds after an unlock that happened THIS session (the area builds in, the notification
	-- opt-in card of the same moment goes first).
	AfterUnlockSeconds = 90,
	-- Never earlier than this far into the session (join popups, Welcome Back, plot reveal first).
	MinSessionSeconds = 180,
	-- The card closes itself after this long without an answer (counted as neither).
	ShowSeconds = 14,
	-- PopupQueue: the longest it waits for the lane (then it tries again later this session).
	RetrySeconds = 60,
	-- Card look (design px at fit 1; Widgets/FeedCardMetrics grows text / buttons on phones so
	-- they stay >= 14 pt / 44 pt at the fit the feed column allows, never under MinFit).
	Width = 470,
	MinFit = 0.62,
	ArtSize = 100,
	TitleSize = 36,
	LineSize = 24,
	LineRows = 2,
	ButtonHeight = 60,
	InviteWidth = 190,
	LaterWidth = 150,
	Pad = 14,
	Gap = 10,
	GlyphHeight = 28,
	-- INVITE: gamepad X / keyboard E, bound BELOW every gameplay action (a pad / producer press on
	-- the same key always wins); LATER: gamepad B / the keyboard close keys (InputConfig), High
	-- priority, only while the card shows. Nothing on the card is Selectable (the gamepad cursor
	-- is never stolen); touch / mouse press the buttons.
	InviteKey = Enum.KeyCode.E,
	InvitePad = Enum.KeyCode.ButtonX,
	InvitePriority = PlatformConfig.Priority.Gameplay - 50,
	LaterPriority = Enum.ContextActionPriority.High.Value + 10,
	Color = "blue",
	Text = table.freeze({
		Title = "PLAY WITH FRIENDS!",
		-- %d = the live Friend Boost percent per friend.
		Line = "Every friend here gives you +%d%% cash!",
		LineNoBoost = "Building is more fun together!",
		Invite = "INVITE",
		Later = "LATER",
	}),
})

-- ── Invite availability (Client/Social/InviteClient) ──────────────────────────────────────────────

InviteConfig.Availability = table.freeze({
	-- SocialService:CanSendGameInviteAsync attempts at start (a web call) + the wait between.
	Attempts = 3,
	RetrySeconds = 20,
	-- Re-asked this often while the session runs (a parent may change settings; cheap).
	RecheckSeconds = 900,
})

-- ── Analytics reports (FriendInvite remote → FriendService) ─────────────────────────────────────────

-- FriendInvite surface reports: their own rate limit per player (separate from the invite outcome's
-- SocialConfig.Invite bucket, so a tap never eats the outcome's budget).
InviteConfig.ReportBurst = 6
InviteConfig.ReportPerSecond = 0.5
-- Exact allowlist of the R122 surface reports (each counts social "friends:<report>").
InviteConfig.Reports = table.freeze({ "hud:shown", "hud:tap", "moment:shown", "moment:invite", "moment:later" })
-- Most counts per player session per report (a forged client can only add this much).
InviteConfig.ReportCaps = table.freeze({
	["hud:shown"] = 1,
	["hud:tap"] = 30,
	["moment:shown"] = 1,
	["moment:invite"] = 1,
	["moment:later"] = 1,
} :: { [string]: number })

--[[
	Whether one more `action` report may count this session, given the session's counts so far.
	PURE (FriendService keeps `counts` per player; tests/invite-surface.luau).
	@param counts report → times counted this session
	@param action an allowlisted report (anything else → false)
	@return true = count it (the caller then increments counts[action])
	Example: InviteConfig.reportAllowed({ ["hud:shown"] = 1 }, "hud:shown") --> false
]]
function InviteConfig.reportAllowed(counts: { [string]: number }, action: string): boolean
	local cap = InviteConfig.ReportCaps[action]
	if cap == nil then
		return false
	end
	return (counts[action] or 0) < cap
end

return table.freeze(InviteConfig)
