--!strict
--[[
	RewardsBadges — the claimable counts and "next in ..." timers of every reward feature folded
	into the HUD's ONE "Rewards" button (owner R62): Daily, Time (playtime gifts), Lucky Wheel,
	Group rewards and Codes. The HUD shows `badgeText()` on the Rewards button; the Rewards hub
	(UI/Screens/RewardsHub) shows each feature's own badge + status line from `snapshot()`.

	Purpose:
		One source of truth for the hub and the HUD button, so the red numbers always agree. The
		counts come from the SAME profile fields and the SAME pure config rules the feature
		screens use for their own state (so a tile never says "CLAIM NOW!" while the screen says
		LOCKED):
			Daily       RetentionConfig.dailyStatus(profile.daily, utcDay(now)).canClaim → 0 / 1;
			            waiting: next UTC midnight
			Time        PlaytimeConfig.status(profile.timeRewards, today, extraSeconds) → the number
			            of "ready" gifts, with the Time Rewards screen's playtime extrapolation
			            (serverNow − the arrival time of the last `timeRewards` push); waiting: the
			            soonest locked gift, else UTC midnight (a fresh ladder)
			LuckyWheel  LuckySpinConfig.status(profile.spin, now) → free + bonus spins (both cost
			            nothing; bought Robux spins are the player's own stock and never badge);
			            waiting: the next free spin
			Group       1 only when the group is configured, the reward is unclaimed AND the client
			            sees the player in the group (Player:IsInGroupAsync, display only, re-checked
			            at most every GroupRecheckSeconds); otherwise 0 ("Join for a gift!")
			Codes       always 0: the client has no "new code" signal (codes are announced off-game
			            and checked only on the server), so it never badges
			Friends     always 0 (R78: referral rewards pay automatically); kind "boost" with the
			            live Friend Boost percent ("+20% cash!", input.friendPercent from
			            Client/Social/SocialClient) or "invite" ("Invite friends!")
		total() = the sum. Nothing here grants anything: claims stay server-validated intents in
		each feature's own screen.

	Pure core (Lune-tested in tests/rewards-hub.luau, no Roblox runtime needed):
		RewardsBadges.evaluate(input) → Snapshot   counts, kinds, readyAt / changeAt, total, wakeAt
		RewardsBadges.statusText(state, now)        the tile line ("CLAIM NOW!", "Next in 2h 14m")
		RewardsBadges.formatBadge(count)            nil / "1".."99" / "99+"
	Runtime (client, `start()` — idempotent; every getter starts it):
		- ClientState.ProfileChanged for daily / timeRewards / spin / group (a `fields` list that
		  touches none of them is ignored; nil = full snapshot), coalesced into one evaluation per
		  frame (task.defer),
		- ONE wake timer at the soonest predicted change (gift unlock, free spin, UTC midnight) +
		  WakeSlack, so the badge turns on by itself with no per-frame work,
		- Changed:Fire(total) only when the total changes (the HUD button);
		  Updated:Fire(snapshot) when any feature's count / kind / timer changes (the hub).

	Connects to: Client/ClientState (profile + pushes; required lazily inside start so the pure
	core loads under Lune), Client/Social/SocialClient (R78 Friend Boost; also lazy), Shared/Config/{RewardsHubConfig, RetentionConfig, PlaytimeConfig,
	LuckySpinConfig, GroupConfig}, Shared/Util/{Signal, NumberFormat}. Used by
	UI/Screens/RewardsHub and the HUD's Rewards button (UI/Hud, W5b).

	Example:
		RewardsBadges.start()
		hud.setBadge("Rewards", RewardsBadges.badgeText())
		RewardsBadges.Changed:Connect(function(_total: number)
			hud.setBadge("Rewards", RewardsBadges.badgeText())
		end)
		local daily = RewardsBadges.forFeature("Daily") -- { count = 1, kind = "claim", ... }
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GroupConfig = require(ReplicatedStorage.Shared.Config.GroupConfig)
local LuckySpinConfig = require(ReplicatedStorage.Shared.Config.LuckySpinConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local PlaytimeConfig = require(ReplicatedStorage.Shared.Config.PlaytimeConfig)
local RetentionConfig = require(ReplicatedStorage.Shared.Config.RetentionConfig)
local RewardsHubConfig = require(ReplicatedStorage.Shared.Config.RewardsHubConfig)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

export type FeatureId = RewardsHubConfig.FeatureId

-- What a tile's status line says (statusText):
--   loading  no profile yet ("...")
--   claim    something is claimable now (count ≥ 1)
--   wait     nothing claimable; `readyAt` = when the next claim opens
--   join     Group: not (seen) in the group yet
--   claimed  Group: the one-time reward was claimed
--   soon     Group: no group configured yet
--   code     Codes: always (no client-side signal)
--   boost    Friends (R78): Roblox friends are here; `value` = the Friend Boost percent
--   invite   Friends (R78): no friends here — the invite call to action
export type Kind = "loading" | "claim" | "wait" | "join" | "claimed" | "soon" | "code" | "boost" | "invite"

-- Colour role of a status line (the hub maps it to a colour).
export type Tone = "ready" | "wait" | "info" | "done"

export type FeatureState = {
	id: FeatureId,
	count: number, -- claimable right now (whole number ≥ 0)
	kind: Kind,
	readyAt: number?, -- server unix time the next claim opens (only with kind "wait")
	changeAt: number?, -- server unix time this feature's state next changes on its own (wake)
	value: number?, -- kind "boost": the Friend Boost percent (R78)
}

export type Snapshot = {
	features: { [string]: FeatureState }, -- by FeatureId
	total: number, -- sum of every feature's count
	wakeAt: number?, -- the soonest changeAt (nil = nothing changes by itself)
}

export type Input = {
	profile: { [string]: any }?, -- ClientState.profile (nil = not loaded yet)
	now: number, -- server unix time (Workspace:GetServerTimeNow())
	timeReceivedAt: number?, -- server time the last `timeRewards` push arrived (nil = now)
	groupEnabled: boolean, -- GroupConfig.isEnabled()
	groupMember: boolean?, -- client view of group membership (nil = unknown)
	friendPercent: number?, -- R78: the live Friend Boost percent (nil / 0 = none; SocialClient)
}

local RewardsBadges = {}

-- Profile fields each feature reads (a push touching none of them skips the evaluation).
local WATCHED_FIELDS = { "daily", "timeRewards", "spin", "group" }
local TIME_FIELDS = { "timeRewards" }
local GROUP_FIELDS = { "group" }
-- Two timestamps closer than this are "the same" (float noise in now + secondsLeft sums).
local TIME_EPSILON = 0.5

-- Fires (total) when the total claimable count changes (the HUD Rewards button).
RewardsBadges.Changed = Signal.new() :: Signal.Signal<number>
-- Fires (snapshot) when any feature's count / kind / timer changes (the hub tiles).
RewardsBadges.Updated = Signal.new() :: Signal.Signal<Snapshot>

-- Old left-column keys that now live inside the hub (their screens still pass them to
-- Hud.setButtonBadge; the HUD treats them as folded).
local FOLDED: { [string]: boolean } = {}
for _, feature in RewardsHubConfig.Features do
	local key = feature.hudKey
	if key ~= nil then
		FOLDED[key] = true
	end
end

-- ── Pure core ────────────────────────────────────────────────────────────────────────────────

-- `value` when it is a finite number, else nil (rejects NaN / ±inf / non-numbers).
local function finite(value: unknown): number?
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	return value
end

-- A state with nothing claimable and nothing to wait for (`kind` says why).
local function idle(id: FeatureId, kind: Kind): FeatureState
	return { id = id, count = 0, kind = kind, readyAt = nil, changeAt = nil }
end

-- Daily Rewards (see the module header).
local function evalDaily(profile: { [string]: any }?, now: number, midnight: number): FeatureState
	-- Read through an `any` local: a type refinement on the profile path would narrow it oddly.
	local raw: any = if profile ~= nil then profile.daily else nil
	if type(raw) ~= "table" then
		return idle("Daily", "loading")
	end
	local streak, lastDay = finite(raw.streak), finite(raw.lastDay)
	if streak == nil or lastDay == nil then
		return idle("Daily", "loading")
	end
	local status = RetentionConfig.dailyStatus({ streak = streak, lastDay = lastDay }, RetentionConfig.utcDay(now))
	if status.canClaim then
		-- Claimable all day; at midnight the status is re-read (a missed day resets the streak).
		return { id = "Daily", count = 1, kind = "claim", readyAt = nil, changeAt = midnight }
	end
	return { id = "Daily", count = 0, kind = "wait", readyAt = midnight, changeAt = midnight }
end

--[[
	Playtime seconds the client adds to the last pushed `seconds` (the Time Rewards screen's
	extraSeconds rule, kept identical so the tile and the screen agree): time since the push
	arrived, or since UTC midnight when the push is from an earlier day; 0 for a future day.
]]
local function playtimeExtra(day: number, today: number, now: number, receivedAt: number): number
	if day > today then
		return 0
	end
	local since = if day == today then receivedAt else math.max(receivedAt, today * RetentionConfig.SecondsPerDay)
	return math.max(0, now - since)
end

-- Time Rewards (playtime gifts; see the module header).
local function evalTime(profile: { [string]: any }?, now: number, midnight: number, receivedAt: number): FeatureState
	local raw: any = if profile ~= nil then profile.timeRewards else nil
	if type(raw) ~= "table" then
		return idle("Time", "loading")
	end
	local day, seconds = finite(raw.day), finite(raw.seconds)
	if day == nil or seconds == nil then
		return idle("Time", "loading")
	end
	local claimed: { [number]: any } = if type(raw.claimed) == "table" then raw.claimed else {}
	local today = RetentionConfig.utcDay(now)
	local views = PlaytimeConfig.status(
		{ day = day, seconds = seconds, claimed = claimed },
		today,
		playtimeExtra(day, today, now, receivedAt)
	)
	local ready = 0
	local soonest: number? = nil
	for _, view in views do
		if view.state == "ready" then
			ready += 1
		elseif view.state == "locked" then
			soonest = math.min(soonest or math.huge, view.secondsLeft)
		end
	end
	-- The next change: the soonest locked gift unlocking, or midnight (a fresh ladder).
	local changeAt = if soonest ~= nil then math.min(midnight, now + soonest) else midnight
	if ready > 0 then
		return { id = "Time", count = ready, kind = "claim", readyAt = nil, changeAt = changeAt }
	end
	return { id = "Time", count = 0, kind = "wait", readyAt = changeAt, changeAt = changeAt }
end

-- Lucky Wheel (free + bonus spins; see the module header).
local function evalWheel(profile: { [string]: any }?, now: number): FeatureState
	local raw: any = if profile ~= nil then profile.spin else nil
	if type(raw) ~= "table" then
		return idle("LuckyWheel", "loading")
	end
	local free, lastFreeAt, paid = finite(raw.free), finite(raw.lastFreeAt), finite(raw.paid)
	if free == nil or lastFreeAt == nil or paid == nil then
		return idle("LuckyWheel", "loading")
	end
	-- `bonus` is newer than the other counters: a snapshot without it reads 0 (as the screen).
	local status = LuckySpinConfig.status(
		{ free = free, lastFreeAt = lastFreeAt, paid = paid, bonus = finite(raw.bonus) or 0 },
		now
	)
	local count = math.max(0, math.floor(status.free)) + math.max(0, math.floor(status.bonus))
	local nextIn = finite(status.nextFreeIn)
	local changeAt = if status.free < LuckySpinConfig.MaxFree
			and nextIn ~= nil
			and nextIn > 0
		then now + nextIn
		else nil
	if count > 0 then
		return { id = "LuckyWheel", count = count, kind = "claim", readyAt = nil, changeAt = changeAt }
	end
	if changeAt == nil then
		return idle("LuckyWheel", "loading")
	end
	return { id = "LuckyWheel", count = 0, kind = "wait", readyAt = changeAt, changeAt = changeAt }
end

-- Friends (R78): never claimable (referral rewards pay automatically); the status line shows the
-- live Friend Boost or the invite call to action.
local function evalFriends(percent: number?): FeatureState
	local value = finite(percent)
	if value ~= nil and value > 0 then
		return { id = "Friends", count = 0, kind = "boost", readyAt = nil, changeAt = nil, value = math.floor(value) }
	end
	return idle("Friends", "invite")
end

-- Group reward (see the module header).
local function evalGroup(profile: { [string]: any }?, enabled: boolean, member: boolean?): FeatureState
	if not enabled then
		return idle("Group", "soon")
	end
	if profile == nil then
		return idle("Group", "loading")
	end
	local raw: any = profile.group
	if type(raw) == "table" and raw.claimed == true then
		return idle("Group", "claimed")
	end
	if member == true then
		return { id = "Group", count = 1, kind = "claim", readyAt = nil, changeAt = nil }
	end
	return idle("Group", "join")
end

--[[
	Evaluates every feature for one moment (pure: same input → same output; never NaN).
	@param input profile snapshot, server time, playtime push time, group flags (see Input)
	@return Snapshot (features by id, total, wakeAt)
	Example:
		local snap = RewardsBadges.evaluate({ profile = ClientState.profile, now = serverNow,
			timeReceivedAt = receivedAt, groupEnabled = GroupConfig.isEnabled() })
		print(snap.total, snap.features.Daily.kind)
]]
function RewardsBadges.evaluate(input: Input): Snapshot
	local now = finite(input.now)
	local features: { [string]: FeatureState } = {}
	if now == nil or now < 0 then
		-- No trustworthy clock: show "loading" everywhere rather than guessing.
		for _, feature in RewardsHubConfig.Features do
			features[feature.id] = idle(
				feature.id,
				if feature.id == "Codes" then "code" elseif feature.id == "Friends" then "invite" else "loading"
			)
		end
		return { features = features, total = 0, wakeAt = nil }
	end
	local profile = input.profile
	local midnight = now + RetentionConfig.secondsToNextDay(now)
	local receivedAt = finite(input.timeReceivedAt) or now
	features.Daily = evalDaily(profile, now, midnight)
	features.Time = evalTime(profile, now, midnight, math.min(receivedAt, now))
	features.LuckyWheel = evalWheel(profile, now)
	features.Group = evalGroup(profile, input.groupEnabled == true, input.groupMember)
	features.Codes = idle("Codes", "code")
	features.Friends = evalFriends(input.friendPercent)
	local total = 0
	local wakeAt: number? = nil
	for _, state in features do
		total += state.count
		local at = state.changeAt
		if at ~= nil then
			wakeAt = math.min(wakeAt or math.huge, at)
		end
	end
	return { features = features, total = total, wakeAt = wakeAt }
end

--[[
	A badge string for `count`: nil when there is nothing (hides the badge), else the whole number,
	capped at RewardsHubConfig.BadgeCap ("99+").
	@param count any value (non-numbers / NaN / < 1 → nil)
	@return string?
	Example: RewardsBadges.formatBadge(3) --> "3"; RewardsBadges.formatBadge(0) --> nil
]]
function RewardsBadges.formatBadge(count: unknown): string?
	local n = finite(count)
	if n == nil or n < 1 then
		return nil
	end
	local whole = math.floor(n)
	if whole > RewardsHubConfig.BadgeCap then
		return `{RewardsHubConfig.BadgeCap}+`
	end
	return tostring(whole)
end

-- The "%s"-format of a feature's waiting line.
local WAIT_FORMAT: { [string]: string } = {
	Daily = RewardsHubConfig.Text.DailyWait,
	Time = RewardsHubConfig.Text.TimeWait,
	LuckyWheel = RewardsHubConfig.Text.WheelWait,
}

--[[
	The tile status line for `state` at server time `now`, and its colour role.
	@param state a FeatureState from evaluate / snapshot
	@param now   server unix time (the countdown is readyAt − now, floored at 0)
	@return (text, tone)
	Example: RewardsBadges.statusText({ id = "Daily", count = 0, kind = "wait",
		readyAt = now + 8040 }, now) --> "Next in 2h 14m", "wait"
]]
function RewardsBadges.statusText(state: FeatureState, now: number): (string, Tone)
	local text = RewardsHubConfig.Text
	local kind = state.kind
	if kind == "claim" then
		return if state.id == "LuckyWheel" then text.Spin else text.Claim, "ready"
	elseif kind == "wait" then
		local at, clock, format = finite(state.readyAt), finite(now), WAIT_FORMAT[state.id]
		if at == nil or clock == nil or format == nil then
			return text.Loading, "info"
		end
		return string.format(format, NumberFormat.duration(math.max(0, at - clock))), "wait"
	elseif kind == "join" then
		return text.GroupJoin, "info"
	elseif kind == "claimed" then
		return text.GroupClaimed, "done"
	elseif kind == "soon" then
		return text.GroupSoon, "done"
	elseif kind == "code" then
		return text.Codes, "info"
	elseif kind == "boost" then
		return string.format(text.FriendsBoost, finite(state.value) or 0), "ready"
	elseif kind == "invite" then
		return text.FriendsInvite, "info"
	end
	return text.Loading, "info"
end

--[[
	True for an old left-column HUD key that now lives inside the Rewards hub ("Daily", "Time",
	"LuckyWheel", "Codes"); the HUD ignores Hud.setButtonBadge calls for those keys.
	Example: RewardsBadges.isFoldedKey("Daily") --> true; RewardsBadges.isFoldedKey("Pets") --> false
]]
function RewardsBadges.isFoldedKey(key: string): boolean
	return FOLDED[key] == true
end

-- ── Runtime (client) ─────────────────────────────────────────────────────────────────────────

local started = false
local current: Snapshot = RewardsBadges.evaluate({ profile = nil, now = 0, groupEnabled = false })
-- Server time the last `timeRewards` push arrived (the playtime extrapolation base).
local timeReceivedAt: number? = nil
-- Client view of group membership (nil = not looked up yet).
local groupMember: boolean? = nil
local groupChecking = false
local lastGroupCheck = -math.huge
local wakeThread: thread? = nil
local refreshQueued = false
-- Set by start(): reads ClientState.profile (nil before start).
local readProfile: () -> { [string]: any }? = function(): { [string]: any }?
	return nil
end
-- Set by start(): the live Friend Boost percent (R78; 0 before start / while switched off).
local readFriendPercent: () -> number = function(): number
	return 0
end

-- Server unix time (the same clock the reward screens count down with).
local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

-- True when a ProfileChanged push touches any of `watched` (`fields` nil = a full snapshot).
local function touches(fields: { string }?, watched: { string }): boolean
	if fields == nil then
		return true
	end
	for _, field in watched do
		if table.find(fields, field) ~= nil then
			return true
		end
	end
	return false
end

-- Two optional timestamps are the same moment (within TIME_EPSILON).
local function sameTime(a: number?, b: number?): boolean
	if a == nil or b == nil then
		return a == b
	end
	return math.abs(a - b) <= TIME_EPSILON
end

-- True when any feature's count / kind / readyAt differs between two snapshots.
local function differs(a: Snapshot, b: Snapshot): boolean
	if a.total ~= b.total then
		return true
	end
	for id, state in b.features do
		local old = a.features[id]
		if
			old == nil
			or old.count ~= state.count
			or old.kind ~= state.kind
			or old.value ~= state.value
			or not sameTime(old.readyAt, state.readyAt)
		then
			return true
		end
	end
	return false
end

local requestRefresh: () -> ()

-- (Re)arms the ONE wake timer at the snapshot's soonest change (+ slack, clamped).
local function schedule(snapshot: Snapshot, now: number)
	local thread = wakeThread
	if thread ~= nil then
		wakeThread = nil
		task.cancel(thread)
	end
	local at = snapshot.wakeAt
	if at == nil then
		return
	end
	local delay = math.clamp(
		at - now + RewardsHubConfig.WakeSlack,
		RewardsHubConfig.MinWakeSeconds,
		RewardsHubConfig.MaxWakeSeconds
	)
	wakeThread = task.delay(delay, function()
		wakeThread = nil
		requestRefresh()
	end)
end

-- Re-evaluates now; fires Changed / Updated on a change and re-arms the wake timer.
local function refresh()
	local now = serverNow()
	local snapshot = RewardsBadges.evaluate({
		profile = readProfile(),
		now = now,
		timeReceivedAt = timeReceivedAt,
		groupEnabled = GroupConfig.isEnabled(),
		groupMember = groupMember,
		friendPercent = readFriendPercent(),
	})
	local previous = current
	current = snapshot
	schedule(snapshot, now)
	if snapshot.total ~= previous.total then
		RewardsBadges.Changed:Fire(snapshot.total)
	end
	if differs(previous, snapshot) then
		RewardsBadges.Updated:Fire(snapshot)
	end
end

-- Coalesces every trigger in a frame into ONE evaluation.
requestRefresh = function()
	if refreshQueued then
		return
	end
	refreshQueued = true
	task.defer(function()
		refreshQueued = false
		refresh()
	end)
end

--[[
	Starts listening (idempotent): profile pushes, the wake timer and the first group look-up.
	Every getter calls it, so the HUD / hub never read a stale snapshot.
	Example: RewardsBadges.start()
]]
function RewardsBadges.start()
	if started then
		return
	end
	started = true
	-- Required here (not at the top) so the pure core above loads under Lune without a client.
	local ClientState = require(script.Parent.Parent.ClientState)
	readProfile = function(): { [string]: any }?
		return ClientState.profile
	end
	-- R78 Friends tile: the server's Friend Boost (SocialClient), re-evaluated on every change.
	local SocialClient = require(script.Parent.Parent.Social.SocialClient)
	readFriendPercent = function(): number
		return if SocialClient.live().friendsOn then SocialClient.friends().percent else 0
	end
	SocialClient.Changed:Connect(requestRefresh)
	timeReceivedAt = serverNow()
	ClientState.ProfileChanged:Connect(function(_profile: { [string]: any }, fields: { string }?)
		if touches(fields, TIME_FIELDS) then
			-- Record the arrival synchronously: it is the extrapolation base (as the screen does).
			timeReceivedAt = serverNow()
		end
		if not touches(fields, WATCHED_FIELDS) then
			return
		end
		if touches(fields, GROUP_FIELDS) then
			RewardsBadges.recheckGroup()
		end
		requestRefresh()
	end)
	refresh()
	RewardsBadges.recheckGroup()
end

--[[
	Looks the local player's group membership up again (display only), at most once per
	RewardsHubConfig.GroupRecheckSeconds, and only while the group is configured and its reward
	is unclaimed. The hub calls it on open (a player may have joined on the website meanwhile).
	Example: RewardsBadges.recheckGroup()
]]
function RewardsBadges.recheckGroup()
	if not started or groupChecking or not GroupConfig.isEnabled() then
		return
	end
	local profile = readProfile()
	if profile == nil then
		return
	end
	local group: any = profile.group
	if type(group) == "table" and group.claimed == true then
		return
	end
	local clock = os.clock()
	if clock - lastGroupCheck < RewardsHubConfig.GroupRecheckSeconds then
		return
	end
	lastGroupCheck = clock
	groupChecking = true
	task.spawn(function()
		local player = Players.LocalPlayer
		-- A web call that can fail / time out: a failure reads as "not a member" (no badge).
		local ok, member = pcall(function(): boolean
			return player:IsInGroupAsync(GroupConfig.GroupId)
		end)
		groupChecking = false
		local value = ok and member == true
		if value ~= groupMember then
			groupMember = value
			requestRefresh()
		end
	end)
end

--[[
	The latest snapshot (starts the module on first use).
	Example: for id, state in RewardsBadges.snapshot().features do print(id, state.count) end
]]
function RewardsBadges.snapshot(): Snapshot
	RewardsBadges.start()
	return current
end

--[[
	Total claimable count across the folded features (the HUD Rewards badge number).
	Example: RewardsBadges.total() --> 3
]]
function RewardsBadges.total(): number
	return RewardsBadges.snapshot().total
end

--[[
	The HUD Rewards button's badge text: nil (hidden) at 0, else "1".."99" / "99+".
	Example: left.setBadge("Rewards", RewardsBadges.badgeText())
]]
function RewardsBadges.badgeText(): string?
	return RewardsBadges.formatBadge(RewardsBadges.total())
end

--[[
	One feature's state ("Daily" | "Time" | "LuckyWheel" | "Group" | "Codes" | "Friends"); nil for
	an unknown id.
	Example: RewardsBadges.forFeature("Time").count --> 2
]]
function RewardsBadges.forFeature(id: string): FeatureState?
	return RewardsBadges.snapshot().features[id]
end

return table.freeze(RewardsBadges)
