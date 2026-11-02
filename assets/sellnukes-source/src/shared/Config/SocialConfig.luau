--!strict
--[[
	SocialConfig — every tunable of the R78 social / comeback boosts (spec
	docs/superpowers/specs/2026-10-31-r78-retention-pack-design.md §3 + §4; docs/social.md):

		Rookie Rush     brand-new profiles: 2x Cash for their first 15 minutes ONLINE (counts down
		                only while playing, survives rejoin). Profiles that existed before 0.6.0
		                never get it (their saves have no `rush` record → rookieLeft 0).
		Comeback Rush   on join, server-saved last-seen >= 48 h ago: 2x Cash for 10 minutes
		                (wall clock), shown on the Welcome Back screen ("COMEBACK RUSH!").
		Friend Boost    +10 % cash per Roblox friend in the same server, max +50 %.
		Invites         the Friends screen's INVITE FRIENDS button (SocialService:PromptGameInvite).
		Referrals       a brand-new profile whose join data names a referrer: newcomer 50 Gems +
		                2x Cash 15 min; inviter 100 Gems + 1 bonus spin per new friend, max 10 ever.

	Live overrides (owner admin panel, per server, ReplicatedStorage attributes so clients show the
	same numbers): `Attributes.*` below. `SocialConfig.live(get)` resolves the effective values
	from any attribute reader (server and client use the same rules; junk → the config default).

	Saved records (Server/Economy/ProfileLogic keeps one of each, repaired by the helpers here —
	the same pattern as ChangeNotesConfig.newState / reconcileState):
		profile.rush     = { rookieLeft = whole seconds of Rookie Rush left (0 = none),
		                     comebackUntil = unix seconds the Comeback Rush ends (0 = none) }
		profile.referral = { by = inviter UserId (0 = not referred), paid = inviters' rewards
		                     received (whole, <= Referral.MaxPaid in practice),
		                     seen = { newcomer UserIds already paid } (array, <= Referral.MaxSeen) }

	Connects to: Shared/Tycoon/Modifiers (rush / friend multiplier caps), Server/Services/
	{RushService, FriendService}, Server/Social/{RushLogic, FriendLogic}, Server/Economy/
	ProfileLogic (state helpers), Client/Social/{SocialClient, BoostChipLogic}, UI/Screens/
	{Friends, BoostChips, WelcomeBack}, Shared/Config/RewardsHubConfig (the Friends tile),
	tests/social-logic.luau.

	Example:
		local live = SocialConfig.live(function(name) return ReplicatedStorage:GetAttribute(name) end)
		print(live.rookieMinutes, live.friendPercent) --> 15 10
		local state = SocialConfig.reconcileRush({ rookieLeft = 900.4 }) --> { rookieLeft = 900, comebackUntil = 0 }
]]

local RetentionConfig = require(script.Parent.RetentionConfig)

export type RushState = { rookieLeft: number, comebackUntil: number }
export type ReferralState = { by: number, paid: number, seen: { number } }

-- The effective (admin-overridable) values (SocialConfig.live).
export type Live = {
	rushOn: boolean,
	friendsOn: boolean,
	rookieMinutes: number,
	comebackMinutes: number,
	friendPercent: number, -- per friend
}

local SocialConfig = {}

-- Rush boosts (spec §3) ------------------------------------------------------------------------------

SocialConfig.Rush = table.freeze({
	-- Rookie Rush: brand-new profiles only (PlayerDataService ProfileLoaded isNew + canMutate).
	RookieMinutes = 15,
	RookieMultiplier = 2,
	-- Comeback Rush: the previous save's server timestamp (profile.offline.lastSeenAt) at least this
	-- far in the past, on a JOIN (never a New Player Mode swap).
	ComebackMinutes = 10,
	ComebackMultiplier = 2,
	ComebackAwayHours = 48,
	-- Admin minute range (RushMinutes / RushGrant) and the save clamp (MaxMinutes * 60 seconds).
	MinMinutes = 1,
	MaxMinutes = 120,
	-- Sanitise cap of the `rushCash` modifier field (Shared/Tycoon/Modifiers): a corrupted value can
	-- never mint more than this. Rookie and Comeback never stack: the larger one applies.
	MaxMultiplier = 10,
	-- Seconds between Rookie Rush bookkeeping passes (expiry, analytics) of the server loop.
	TickSeconds = 2,
	-- Seconds between persisting + pushing profile.rush.rookieLeft while a Rookie Rush runs (the
	-- client counts down locally between pushes; ProfileReleasing writes the final value).
	SyncSeconds = 30,
})

-- Friend Boost (spec §4) -------------------------------------------------------------------------------

SocialConfig.Friends = table.freeze({
	PercentPerFriend = 10,
	MaxPercent = 50,
	-- Admin range of the per-friend percent (FriendBoostPercent).
	MinPercentPerFriend = 1,
	MaxPercentPerFriend = 25,
	-- Sanitise cap of the `friendCash` modifier field (+100 %; MaxPercent stays the real limit).
	MaxMultiplier = 2,
	-- Player:IsFriendsWithAsync attempts per pair (a web call that can fail) and the waits between.
	CheckAttempts = 3,
	RetrySeconds = table.freeze({ 2, 6 }),
	-- Friend names sent to the client (an 8-player server has at most 7 others).
	MaxNames = 7,
})

-- Invites (spec §4: client-side SocialService prompt; the server only counts) -------------------------

SocialConfig.Invite = table.freeze({
	-- ExperienceInviteOptions.PromptMessage (shown in Roblox's invite prompt; kid-friendly).
	PromptMessage = "Come build toy nukes with me in Sell Nukes!",
	-- Seconds the INVITE button stays disabled after a press (the prompt is modal anyway).
	CooldownSeconds = 2,
	-- FriendInvite (C→S, analytics only) rate limit per player.
	Burst = 4,
	PerSecond = 0.2,
	-- What the client may report (exact allowlist; anything else is dropped).
	Actions = table.freeze({ "prompted", "sent", "closed", "unavailable", "failed" }),
	-- Largest recipient count accepted in one "sent" report (Roblox caps a prompt far lower).
	MaxRecipients = 50,
})

-- Referrals (spec §4) -------------------------------------------------------------------------------------

SocialConfig.Referral = table.freeze({
	-- Newcomer (a brand-new profile joining through an invite / share link).
	NewcomerReward = table.freeze({
		gems = 50,
		boost = table.freeze({ key = "cash2x", seconds = 15 * 60 }),
	}) :: RetentionConfig.Reward,
	-- Inviter, per new friend (gems + a FREE bonus spin: profile.spin.bonus).
	InviterReward = table.freeze({ gems = 100, spins = 1 }) :: RetentionConfig.Reward,
	-- Lifetime cap of paid inviter rewards.
	MaxPaid = 10,
	-- Newcomer ids remembered per inviter (idempotency ledger; the newest are kept).
	MaxSeen = 32,
	-- Offline inviter queue: DataStore `StoreName` (+ `StudioSuffix` in Studio, so a playtest never
	-- writes the live store), key `KeyPrefix .. inviterUserId`, at most MaxQueue pending newcomers.
	StoreName = "SellNukesReferrals_v1",
	StudioSuffix = "_Studio",
	KeyPrefix = "Inviter_",
	MaxQueue = 20,
	-- Queued entries older than this are dropped on read (an inviter who never came back).
	QueueMaxAgeDays = 180,
	-- UpdateAsync attempts and the waits (seconds) between them.
	WriteAttempts = 4,
	BackoffSeconds = table.freeze({ 2, 6, 18 }),
})

-- Live overrides (ReplicatedStorage attributes, set by the admin commands) ------------------------------

SocialConfig.Attributes = table.freeze({
	RushEnabled = "SocialRushEnabled", -- boolean (nil = on)
	FriendsEnabled = "SocialFriendsEnabled", -- boolean (nil = on)
	RookieMinutes = "SocialRookieMinutes", -- number (new grants only)
	ComebackMinutes = "SocialComebackMinutes", -- number (new grants only)
	FriendPercent = "SocialFriendPercent", -- number, per friend (applies at once)
})

-- A finite number in [lo, hi], else nil.
local function within(value: unknown, lo: number, hi: number): number?
	if type(value) ~= "number" or value ~= value or value < lo or value > hi then
		return nil
	end
	return value
end

--[[
	The effective values: config defaults, overridden by well-formed admin attributes.
	@param get (name: string) -> any — an attribute reader (ReplicatedStorage:GetAttribute), or nil
	@return Live
	Example: SocialConfig.live(nil).friendPercent --> 10
]]
function SocialConfig.live(get: ((name: string) -> any)?): Live
	local function read(name: string): any
		if get == nil then
			return nil
		end
		local ok, value = pcall(get, name)
		return if ok then value else nil
	end
	local rush, friends = SocialConfig.Rush, SocialConfig.Friends
	local attrs = SocialConfig.Attributes
	return {
		rushOn = read(attrs.RushEnabled) ~= false,
		friendsOn = read(attrs.FriendsEnabled) ~= false,
		rookieMinutes = within(read(attrs.RookieMinutes), rush.MinMinutes, rush.MaxMinutes) or rush.RookieMinutes,
		comebackMinutes = within(read(attrs.ComebackMinutes), rush.MinMinutes, rush.MaxMinutes) or rush.ComebackMinutes,
		friendPercent = within(read(attrs.FriendPercent), friends.MinPercentPerFriend, friends.MaxPercentPerFriend)
			or friends.PercentPerFriend,
	}
end

--[[
	A multiplier as players read it: "2x" for whole numbers, "1.5x" otherwise (never errors on a
	fractional value, unlike "%d").
	Example: SocialConfig.times(2) --> "2x" ; SocialConfig.times(1.5) --> "1.5x"
]]
function SocialConfig.times(multiplier: number): string
	if multiplier == multiplier and multiplier % 1 == 0 then
		return `{math.floor(multiplier)}x`
	end
	return `{string.format("%.1f", if multiplier == multiplier then multiplier else 1)}x`
end

-- Saved records ------------------------------------------------------------------------------------------

-- Largest unix time accepted from a save (year ~2286), the same bound as ChangeNotesConfig.
local MAX_TIME = 9_999_999_999
-- Largest whole Roblox UserId (2^53).
local MAX_USER_ID = 9_007_199_254_740_992
-- Largest inviter-reward count kept (far above MaxPaid; only a corruption guard).
local MAX_PAID_SAVED = 1000

-- A whole number in [lo, hi] (floored), else `fallback`.
local function whole(value: unknown, lo: number, hi: number, fallback: number): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return fallback
	end
	return math.clamp(math.floor(value), lo, hi)
end

--[[ A fresh profile.rush (no rush). Every call returns a new table. ]]
function SocialConfig.newRush(): RushState
	return { rookieLeft = 0, comebackUntil = 0 }
end

--[[
	Repairs a stored profile.rush (untrusted). Missing (every save from before 0.6.0) → no rush,
	which is exactly why old profiles never get a Rookie Rush.
	Example: SocialConfig.reconcileRush({ rookieLeft = 1e9, comebackUntil = -5 }) --> { rookieLeft = 7200, comebackUntil = 0 }
]]
function SocialConfig.reconcileRush(raw: unknown): RushState
	if type(raw) ~= "table" then
		return SocialConfig.newRush()
	end
	local data = raw :: { [string]: unknown }
	return {
		rookieLeft = whole(data.rookieLeft, 0, SocialConfig.Rush.MaxMinutes * 60, 0),
		comebackUntil = whole(data.comebackUntil, 0, MAX_TIME, 0),
	}
end

--[[ A fresh profile.referral (not referred, nothing paid). Every call returns new tables. ]]
function SocialConfig.newReferral(): ReferralState
	return { by = 0, paid = 0, seen = {} }
end

--[[
	Repairs a stored profile.referral (untrusted): `by` a whole UserId or 0, `paid` whole and
	bounded, `seen` an array of distinct whole UserIds (the newest MaxSeen kept, order preserved).
	Example: SocialConfig.reconcileReferral({ by = 12, paid = 2, seen = { 5, 5, "x", 7 } })
		--> { by = 12, paid = 2, seen = { 5, 7 } }
]]
function SocialConfig.reconcileReferral(raw: unknown): ReferralState
	if type(raw) ~= "table" then
		return SocialConfig.newReferral()
	end
	local data = raw :: { [string]: unknown }
	local seen: { number } = {}
	local present: { [number]: boolean } = {}
	local list = data.seen
	if type(list) == "table" then
		-- Bounded read: a corrupted save can never make this loop long.
		local entries = list :: { unknown }
		for index = 1, SocialConfig.Referral.MaxSeen * 4 do
			local id = entries[index]
			if id == nil then
				break
			end
			if type(id) == "number" and id % 1 == 0 and id >= 1 and id <= MAX_USER_ID and not present[id] then
				present[id] = true
				table.insert(seen, id)
			end
		end
	end
	-- Keep the newest MaxSeen ids (appended last).
	local overflow = #seen - SocialConfig.Referral.MaxSeen
	if overflow > 0 then
		seen = table.move(seen, overflow + 1, #seen, 1, {})
	end
	local by = data.by
	return {
		by = if type(by) == "number" and by % 1 == 0 and by >= 1 and by <= MAX_USER_ID then by else 0,
		paid = whole(data.paid, 0, MAX_PAID_SAVED, 0),
		seen = seen,
	}
end

-- Client look (Client/Social/BoostChipLogic, UI/Screens/BoostChips (R82 badge), UI/Screens/Friends) ---

SocialConfig.Client = table.freeze({
	-- IconAssets key of the Friends tile / screen / chip (the Fluent 3D handshake, uploaded
	-- 2026-10-31), and the fallback a window uses if moderation ever unmaps it.
	FriendsIcon = "Friends",
	FriendsIconFallback = "GiftBox",
	-- R82 boost badge (owner: "a corner piece for the cash"): a tilted stud sticker pinned to the
	-- right end of the visible primary counter (UI/Screens/BoostChips builds it inside
	-- UI/Hud/HudCurrency's corner anchor; Client/Social/BoostChipLogic sizes it). Design px.
	BadgeBigText = 34, -- the combined multiplier ("2x")
	BadgeSmallText = 20, -- the timer ("1:25") / "FRIENDS"
	-- Device-point floors (owner R11: readable text on phones / tablets, >= 14 pt).
	BadgeBigPoints = 18,
	BadgeSmallPoints = 14,
	BadgePadX = 10,
	BadgePadY = 5,
	BadgeMinWidth = 72,
	-- Width estimate per character / text size (Luckiest Guy): a safe upper bound, so the
	-- TextScaled labels never shrink below their size.
	BadgeCharRatio = 0.7,
	BadgeTilt = 8, -- degrees clockwise: a sticker slapped on the corner
	-- Air between the digits' outline and the badge's edge. The screen adds both stroke widths
	-- (the counter's TextOutline + BadgeEdge, x max(1, 1 / UI scale) so they stay covered whether or
	-- not the engine scales strokes) and the tilted corner's overhang (BoostChipLogic.cornerGap).
	BadgeAir = 3,
	BadgeEdge = 3,
	BadgeCorner = 12,
	BadgeRaise = 4, -- px above the counter's top edge
	-- 2+ boosts: a second sticker (the next boost's colour) peeks out behind it.
	BadgeBackOffset = 6,
	BadgeBackTilt = -5,
	-- Pop when the badge appears / its number changes (skipped with Reduce Motion).
	BadgePopScale = 1.22,
	BadgePopSeconds = 0.12,
	BadgeRingThickness = 4, -- gamepad selection ring
	-- Breakdown card (tap / click / gamepad-select the badge): the total + one row per boost.
	BreakdownWidth = 400,
	BreakdownText = 24,
	BreakdownTitleText = 28,
	BreakdownPoints = 14, -- device-point floor of every breakdown text
	BreakdownPad = 12,
	BreakdownRowGap = 6,
	BreakdownGap = 10, -- px under the badge
	BreakdownMargin = 16, -- kept from the canvas edges
	BreakdownCloseSeconds = 8, -- auto-close (a tap elsewhere, B or the badge again close it sooner)
	-- Non-modal screens the badge steps aside for while open (the "YOUR PLOT IS #N!" reveal
	-- banner owns the top of the screen for its moment).
	HiddenWhileOpen = table.freeze({ "PlotReveal" }),
	-- The comeback announcement stays "fresh" (shown by the next Welcome Back) this long.
	ComebackFreshSeconds = 120,
})

-- Player-facing text (kid-short; `%d` / `%s` filled by the client).
SocialConfig.Text = table.freeze({
	RookieChip = "ROOKIE RUSH %s", -- %s = SocialConfig.times(multiplier) ("2x")
	RookieChipCompact = "%s",
	ComebackChip = "COMEBACK %s",
	ComebackChipCompact = "%s",
	FriendsChip = "FRIENDS +%d%%",
	FriendsChipCompact = "+%d%%",
	CashChip = "2x CASH",
	SpeedChip = "2x SPEED",
	ServerChip = "SERVER 2x",
	CompactBoost = "2x",
	BadgeNoTimer = "FRIENDS", -- the badge's small line when no boost has a timer (R82)
	BreakdownTitle = "BOOSTS",
	BreakdownTotal = "TOTAL %s", -- %s = the combined multiplier ("4x")
	ComebackBanner = "COMEBACK RUSH! %s CASH for %d min",
	ComebackAway = "You were away for %s!",
	ComebackCash = "%s CASH",
	ComebackGo = "LET'S GO!",
	FriendJoined = "Your friend %s joined: +%d%% cash!",
	FriendsHere = "Friends here: +%d%% cash!",
	NewcomerReward = "A friend invited you! +%d Gems + 2x Cash for %d min!",
	InviterReward = "Your friend joined! +%d Gems + %d Spin (%d / %d)",
})

return table.freeze(SocialConfig)
