--!strict
--[[
	RewardsHubConfig — the Rewards hub (owner R62): which reward features fold into the ONE HUD
	"Rewards" button, in what order the hub shows their tiles, and the hub's texts / sizes.

	Purpose:
		R62 cut the HUD's left stack from 11 buttons to 6. Daily, Time (playtime gifts), Lucky
		Wheel, Codes and Group rewards no longer have their own HUD buttons: the "Rewards" button
		opens the hub (Client/UI/Screens/RewardsHub) and its red badge is the total claimable
		count (Client/UI/RewardsBadges). Each hub tile opens that feature's EXISTING screen,
		stacked over the hub, so B / Back returns to the hub. Nothing was removed: every feature
		keeps its own screen, and deep links (Welcome Back, notifications, What's New CTAs, the
		tutorial) still open those screens directly by name.

	Feature fields:
		id       stable feature id (RewardsBadges.forFeature(id), analytics)
		label    tile label (the tile button's outlined label; TextScaled keeps it inside)
		icon     IconAssets key of the tile
		color    UIStyleConfig ColorName of the tile
		screen   ScreenManager screen the tile opens (args { source = TileSource })
		hudKey   the old left-column key the feature's screen still passes to Hud.setButtonBadge
		         (folded into the hub; nil = the feature never had its own badge key)

	Connects to: Client/UI/RewardsBadges (counts / timers / texts), Client/UI/Screens/RewardsHub
	(the hub screen + HubLayout), Shared/Config/AnalyticsConfig.ClientFunnel (the "Rewards"
	screen id and the "hub" source), Shared/Config/HudZonesConfig (the "Rewards" row opens
	ScreenName).

	Example:
		for _, feature in RewardsHubConfig.Features do print(feature.id, feature.screen) end
		RewardsHubConfig.byId("Daily").screen --> "DailyRewards"
]]

local UIStyleConfig = require(script.Parent.UIStyleConfig)

-- "Friends" (owner R78): the Friend Boost / invite / referral screen (UI/Screens/Friends).
export type FeatureId = "Daily" | "Time" | "LuckyWheel" | "Group" | "Codes" | "Friends"

export type Feature = {
	id: FeatureId,
	label: string,
	icon: string,
	color: UIStyleConfig.ColorName,
	screen: string,
	hudKey: string?,
}

export type Mode = { name: string, size: Vector2 }

local RewardsHubConfig = {}

-- The hub screen's ScreenManager name (HudZonesConfig "Rewards" row → this screen).
RewardsHubConfig.ScreenName = "RewardsHub"
-- AnalyticsConfig.ClientFunnel.Screens id of the hub ("open:Rewards", "openFrom:Rewards:hud").
RewardsHubConfig.AnalyticsScreen = "Rewards"
-- AnalyticsConfig.ClientFunnel.Sources label a tile passes to the feature screen it opens, so the
-- per-feature tile opens count as "openFrom:<Daily|Time|Wheel|Codes|Group>:hub".
RewardsHubConfig.TileSource = "hub"

-- Tiles in hub order (first row: the timed claims; second row: one-time / manual rewards and,
-- since R78, Friends — the Friend Boost, INVITE FRIENDS and invite rewards).
RewardsHubConfig.Features = table.freeze({
	table.freeze({
		id = "Daily",
		label = "Daily",
		icon = "Daily",
		color = "red",
		screen = "DailyRewards",
		hudKey = "Daily",
	}) :: Feature,
	table.freeze({
		id = "Time",
		label = "Playtime",
		icon = "Time",
		color = "green",
		screen = "TimeRewards",
		hudKey = "Time",
	}) :: Feature,
	table.freeze({
		id = "LuckyWheel",
		label = "Lucky Wheel",
		icon = "LuckyWheel",
		color = "rainbow",
		screen = "LuckyWheel",
		hudKey = "LuckyWheel",
	}) :: Feature,
	table.freeze({
		id = "Group",
		label = "Group",
		icon = "Chest",
		color = "orange",
		screen = "GroupRewards",
		hudKey = nil,
	}) :: Feature,
	table.freeze({
		id = "Codes",
		label = "Codes",
		icon = "Codes",
		color = "blue",
		screen = "Codes",
		hudKey = "Codes",
	}) :: Feature,
	-- R78 (R-social): icon = SocialConfig.Client.FriendsIcon; the hub falls back to its glyph /
	-- FriendsIconFallback while the icon is not uploaded (StudUI.hudButton handles unknown keys).
	table.freeze({
		id = "Friends",
		label = "Friends",
		icon = "Friends",
		color = "sky",
		screen = "Friends",
		hudKey = nil,
	}) :: Feature,
})

-- Largest number a badge shows; more reads "99+".
RewardsHubConfig.BadgeCap = 99
-- Seconds after a predicted unlock (gift / free spin / midnight) before re-evaluating, so the
-- server-side state has certainly moved too (same slack idea as the Lucky Wheel's refresh).
RewardsHubConfig.WakeSlack = 0.5
-- Shortest re-evaluation delay ever scheduled (no hot loop on a malformed clock).
RewardsHubConfig.MinWakeSeconds = 0.5
-- Longest re-evaluation delay (a day: midnight is always at most this far away).
RewardsHubConfig.MaxWakeSeconds = 86_400
-- Seconds between client group-membership look-ups (only while the group reward is unclaimed and
-- the group is configured; display only — the server re-checks membership on every claim).
RewardsHubConfig.GroupRecheckSeconds = 60

-- Tile status lines (`%s` = a NumberFormat.duration like "2h 14m"). Kid-short so they stay big.
RewardsHubConfig.Text = table.freeze({
	Loading = "...",
	Claim = "CLAIM NOW!",
	Spin = "SPIN NOW!",
	DailyWait = "Next in %s",
	TimeWait = "Next in %s",
	WheelWait = "Spin in %s",
	GroupJoin = "Join for a gift!",
	GroupClaimed = "Claimed!",
	GroupSoon = "Coming soon!",
	Codes = "Enter a code!",
	-- R78 Friends tile: the live Friend Boost ("+20% cash!") or the invite call to action.
	FriendsBoost = "+%d%% cash!",
	FriendsInvite = "Invite friends!",
})

-- Window design sizes (ResponsiveModal modes; the first is the desktop / console / tablet look).
--   grid  two rows of ceil(n / 2) tiles (R78: 6 tiles = 3 + 3)
--   row   every tile in one wide, short row: renders unshrunk on a landscape phone, so the
--         tiles stay far above 44 pt and the status text above 14 pt (R78: six tiles fit the
--         1240 px row at the 82 px minimum side; HubLayout lifts to the touch minimum)
RewardsHubConfig.Modes = table.freeze({
	table.freeze({ name = "grid", size = Vector2.new(1080, 740) }) :: Mode,
	table.freeze({ name = "row", size = Vector2.new(1240, 450) }) :: Mode,
})

-- Tile geometry (design px; HubLayout lifts sizes to the device's touch minimums).
RewardsHubConfig.Layout = table.freeze({
	Gap = 18, -- between tiles (both directions)
	RowGap = 14, -- between tiles in the one-row phone mode
	StatusGap = 8, -- between a tile's button and its status pill
	StatusHeight = 56, -- one-line pill
	StatusText = 30, -- status text size (max; TextScaled shrinks long lines)
	-- Line height (x text size) a two-line touch pill reserves per line. 1.35 leaves the engine's
	-- wrapped line spacing room, so two lines fit AT the 14 pt floor instead of spilling (R78).
	PillLineHeight = 1.35,
	PillPad = 6, -- inner padding of the pill (each side)
	PillWidthRatio = 1.35, -- pill width = min(tile width, button side * ratio)
	MinSide = 82, -- smallest tile button side (UIStyleConfig.Hud.MinButtonSize)
})

--[[
	The feature with `id`, or nil for an unknown id.
	@param id a FeatureId (any string accepted; unknown → nil)
	@return Feature?
	Example: RewardsHubConfig.byId("Codes").screen --> "Codes"
]]
function RewardsHubConfig.byId(id: string): Feature?
	for _, feature in RewardsHubConfig.Features do
		if feature.id == id then
			return feature
		end
	end
	return nil
end

return table.freeze(RewardsHubConfig)
