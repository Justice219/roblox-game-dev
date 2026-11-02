--!strict
--[[
	Owner R122 Roblox-aligned signal regressions (lune run tests/analytics-roblox-signals). Drives
	the REAL Runtime / Sessions / AnalyticsLogic / AnalyticsMarks modules with fake players and
	profiles and a controllable clock (only the player-data boundary is faked, through
	Runtime.setDeps), like tests/analytics-recorders.

	Proves:
	  1. AnalyticsLogic.robloxBucket: Roblox's < 60 s / 61-180 s / qualified boundaries, NaN.
	  2. AnalyticsLogic.creditPlay: plain credit, the 3,600 s daily cap, a new day restarting the
	     cap, the midnight split, an older day dropped, hostile inputs, the gap clamp.
	  3. Sessions: rbx:session:<bucket> for EVERY ended session (Σ = sessions, incl. a leave before
	     the profile), rbx:bounce + rbx:bounceDev for tracked new players' FIRST session only.
	  4. rbx:playSec: credited at flush / release / leave, capped at 3,600 per player per UTC day
	     across sessions and "servers" (profile.analytics.rbxDay / rbxSec), New Player Mode never.
	  5. The midnight split: seconds before 00:00 UTC land on the day they were played.
	  6. rbx:coplay once per player per UTC day: follow (friend here), invite (ReferredByPlayerId,
	     inviter here), host (followed / invited in to), private server with company; absent
	     friends, self / malformed referrers and New Player Mode never count; rbx:coplayVia split.
	  7. rbx:day:<2..28> on active days 2..28 of the cohort (D1 stays r1; day 29 counts nothing).
	  8. FunnelStep refusals by reason: rate / malformed / implausible / cap / unknown / popup; the
	     base key keeps its pre-R122 meaning (= Σ of every reason but cap).
	  9. AnalyticsMarks: rbxDay / rbxSec defaults and reconcile (clamped to the cap, junk → 0).
	 10. Every recorded key is documented in AnalyticsConfig.Metrics.
]]

local Loader = require("./analytics-fixtures/Loader")
local env = Loader.new()
local check, done = Loader.checker()

local DAY = 20758 -- 2026-11-01
env.setTime(DAY * 86400 + 10 * 3600)
env.setClock(1000)

local AnalyticsConfig = env.load("src/shared/Config/AnalyticsConfig")
local AnalyticsMarks = env.load("src/shared/Config/AnalyticsMarks")
local AnalyticsReport = env.load("src/shared/Analytics/AnalyticsReport")
local AnalyticsLogic = env.load("src/server/Analytics/AnalyticsLogic")
local Recorder = env.load("src/server/Analytics/Recorder")
local Runtime = env.load("src/server/Analytics/Runtime")
local Sessions = env.load("src/server/Analytics/Sessions")

local ALGORITHM = AnalyticsConfig.Algorithm
local CAP = ALGORITHM.PlayCapSeconds

-- Fake player-data boundary (every loaded profile can save).
local profiles: { [any]: any } = {}
Runtime.setDeps({
	getProfile = function(player: any): any
		return profiles[player]
	end,
	canMutate = function(player: any): boolean
		return profiles[player] ~= nil
	end,
	markSaved = function() end,
	isAdmin = function(): boolean
		return false
	end,
})

local function newProfile(): any
	return {
		analytics = AnalyticsMarks.newAnalytics(),
		tycoon = { area = 1, pads = {} },
		rebirths = 0,
		totalEarned = 0,
		cash = 0,
		gems = 0,
		pets = { owned = {}, equipped = {} },
	}
end

-- A day's unsaved core counters.
local function coreOn(day: number): { [string]: number }
	local copy = Recorder.unsavedCopy()
	local families = copy[day]
	return if families ~= nil then families.core or {} else {}
end
local function value(key: string): number
	return coreOn(Recorder.today())[key] or 0
end
local function valueOn(day: number, key: string): number
	return coreOn(day)[key] or 0
end

type JoinOptions = {
	follow: number?,
	joinData: { [string]: any }?,
	device: string?,
	profile: any?,
	isNew: boolean?,
	noLoad: boolean?,
	npm: boolean?,
}

-- Joins a fake player (PlayerAdded → optional device claim → ProfileLoaded).
local function join(userId: number, options: JoinOptions?): (any, any)
	local opts: JoinOptions = options or {}
	local player = env.player(userId)
	player.FollowUserId = opts.follow or 0
	player.joinData = opts.joinData or {}
	if opts.npm then
		player:SetAttribute(AnalyticsConfig.NewPlayerModeAttribute, true)
	end
	Sessions.startSession(player)
	if opts.device ~= nil then
		Sessions.onClientDevice(player, opts.device, "touch")
	end
	local profile = opts.profile or newProfile()
	if not opts.noLoad then
		profiles[player] = profile
		Sessions.onProfileLoaded(player, profile, opts.isNew ~= false)
	end
	return player, profile
end

-- Loads a joined player's profile later (a slow profile load).
local function load(player: any, profile: any, isNew: boolean)
	profiles[player] = profile
	Sessions.onProfileLoaded(player, profile, isNew)
end

-- The player leaves this server (PlayerRemoving; the profile goes with them).
local function leave(player: any)
	Sessions.endSession(player)
	env.removePlayer(player)
	profiles[player] = nil
end

local restoreBuffers = Recorder.swapForTests()

-- 1. robloxBucket --------------------------------------------------------------------------------
do
	check(AnalyticsLogic.robloxBucket(0) == "lt60", "0 s is a < 60 s bounce")
	check(AnalyticsLogic.robloxBucket(59.9) == "lt60", "59.9 s is a < 60 s bounce")
	check(AnalyticsLogic.robloxBucket(60) == "60to180", "60 s starts the second bucket")
	check(AnalyticsLogic.robloxBucket(180) == "60to180", "180 s is still the 61-180 s bucket")
	check(AnalyticsLogic.robloxBucket(180.5) == "long", "past 180 s is qualified")
	check(AnalyticsLogic.robloxBucket(0 / 0) == "lt60", "NaN never counts as qualified")
	check(AnalyticsLogic.robloxBucket(-5) == "lt60", "negative = lt60")
end

-- 2. creditPlay ----------------------------------------------------------------------------------
do
	local noon = DAY * 86400 + 12 * 3600
	local credits, day, sec = AnalyticsLogic.creditPlay(0, 0, noon, 600)
	check(#credits == 1 and credits[1].day == DAY and credits[1].seconds == 600, "plain credit")
	check(day == DAY and sec == 600, "cap state starts on the played day")
	credits, day, sec = AnalyticsLogic.creditPlay(DAY, 3590, noon, 60)
	check(#credits == 1 and credits[1].seconds == 10 and sec == CAP, "credit stops at the daily cap")
	credits, day, sec = AnalyticsLogic.creditPlay(DAY, CAP, noon, 600)
	check(#credits == 0 and sec == CAP, "nothing past the cap")
	credits, day, sec = AnalyticsLogic.creditPlay(DAY - 1, CAP, noon, 600)
	check(#credits == 1 and credits[1].seconds == 600 and day == DAY and sec == 600, "a new day restarts the cap")
	credits, day, sec = AnalyticsLogic.creditPlay(0, 0, DAY * 86400 + 30, 90)
	check(
		#credits == 2
			and credits[1].day == DAY - 1
			and credits[1].seconds == 60
			and credits[2].day == DAY
			and credits[2].seconds == 30,
		"midnight split onto the day each part was played"
	)
	check(day == DAY and sec == 30, "cap state moves to the later day")
	credits, day, sec = AnalyticsLogic.creditPlay(DAY - 1, 3580, DAY * 86400 + 30, 90)
	check(
		#credits == 2 and credits[1].seconds == 20 and credits[2].seconds == 30,
		"yesterday's part respects yesterday's remaining cap"
	)
	credits, day, sec = AnalyticsLogic.creditPlay(DAY + 1, 100, noon, 600)
	check(#credits == 0 and day == DAY + 1 and sec == 100, "an older day than the cap day is dropped")
	credits = AnalyticsLogic.creditPlay(0, 0, noon, 0 / 0)
	check(#credits == 0, "NaN seconds credit nothing")
	credits = AnalyticsLogic.creditPlay(0, 0, noon, -50)
	check(#credits == 0, "negative seconds credit nothing")
	credits = AnalyticsLogic.creditPlay(0, 0, 0 / 0, 50)
	check(#credits == 0, "NaN time credits nothing")
	credits = AnalyticsLogic.creditPlay(0, 0, math.huge, 50)
	check(#credits == 0, "infinite time credits nothing")
	credits, day, sec = AnalyticsLogic.creditPlay(0, 0 / 0, noon, 50)
	check(#credits == 1 and sec == 50, "a NaN stored credit is treated as 0")
	credits = AnalyticsLogic.creditPlay(0, 0, noon, 10 * 86400)
	local total = 0
	for _, credit in credits do
		total += credit.seconds
		check(credit.seconds <= CAP, "every day of a huge gap is capped")
	end
	check(#credits <= 3 and total <= 3 * CAP, "a huge gap is clamped to MaxCreditGapSeconds")
end

-- 3. Sessions and first-play bounce ------------------------------------------------------------------
do
	local quick = join(101, { device = "phone" })
	env.advance(45)
	leave(quick)
	check(value("rbx:bounce:lt60") == 1 and value("rbx:bounceDev:phone:lt60") == 1, "45 s first session = < 60 s bounce")
	check(value("rbx:session:lt60") == 1, "and a < 60 s session")

	local mid = join(102, { device = "console" })
	env.advance(120)
	leave(mid)
	check(
		value("rbx:bounce:60to180") == 1 and value("rbx:bounceDev:console:60to180") == 1,
		"120 s first session = 61-180 s bounce"
	)
	check(value("rbx:session:60to180") == 1, "and a 61-180 s session")

	local stayer = join(103)
	env.advance(400)
	leave(stayer)
	check(value("rbx:bounce:lt60") == 1 and value("rbx:bounce:60to180") == 1, "a long first session is no bounce")
	check(value("rbx:bounceDev:unknown:stay") == 1, "an unknown device's long first session stays")
	check(value("rbx:session:qualified") == 1, "and a qualified session")

	-- A returning player's short session: a session bucket, never a first-play bounce.
	local back = newProfile()
	back.analytics.first = DAY - 3
	back.analytics.last = DAY - 1
	back.analytics.sessions = 4
	AnalyticsMarks.startCohort(back.analytics)
	local returning = join(104, { profile = back, isNew = false, device = "tablet" })
	env.advance(30)
	leave(returning)
	check(value("rbx:session:lt60") == 2 and value("rbx:bounce:lt60") == 1, "returning sessions are not bounces")
	check(value("rbx:bounceDev:tablet:lt60") == 0, "no bounceDev for a returning player")
	check(value("rbx:day:3") == 1, "active on cohort day 3 counts rbx:day:3")

	-- Left before the profile loaded: still an ended session (Roblox sees it), not a tracked bounce.
	local early = join(105, { noLoad = true })
	env.advance(10)
	leave(early)
	check(value("rbx:session:lt60") == 3 and value("ops:leftBeforeProfile") == 1, "a pre-profile leave is a session")
	check(value("rbx:bounce:lt60") == 1, "but not a tracked first-play bounce")

	local sum = value("rbx:session:lt60") + value("rbx:session:60to180") + value("rbx:session:qualified")
	check(sum == value("sessions"), `Σ rbx:session:* = sessions (coverage invariant; {sum} vs {value("sessions")})`)
	check(value("ftue:joined") == 3, "three tracked new players joined (the bounce denominator)")
end

-- 4. Capped playtime across sessions and servers --------------------------------------------------------
do
	local before = value("rbx:playSec")
	local player, profile = join(201)
	env.advance(1500)
	Sessions.flushActivity()
	check(value("rbx:playSec") - before == 1500, "flush credits the time since the join")
	env.advance(900)
	Sessions.onProfileReleasing(player, profile)
	check(value("rbx:playSec") - before == 2400, "profile release credits the rest")
	leave(player)
	check(value("rbx:playSec") - before == 2400, "leave after the release credits nothing twice")
	check(profile.analytics.rbxDay == DAY and profile.analytics.rbxSec == 2400, "cap state saved in the profile")

	-- The same profile on "another server" later that day: only 1,200 s left under the cap.
	local secondsBefore = value("sessionSeconds")
	local again = join(201, { profile = profile, isNew = false })
	env.advance(2400)
	Sessions.flushActivity()
	check(value("rbx:playSec") - before == CAP, `the daily cap holds across sessions ({value("rbx:playSec") - before})`)
	check(profile.analytics.rbxSec == CAP, "profile at the cap")
	env.advance(600)
	Sessions.flushActivity()
	leave(again)
	check(value("rbx:playSec") - before == CAP, "nothing past the cap")
	check(value("sessionSeconds") - secondsBefore == 3000, "the uncapped session seconds still count all 3,000 s")

	-- New Player Mode sandboxes are never credited.
	local sandboxBefore = value("rbx:playSec")
	local sandbox = join(202, { npm = true })
	env.advance(600)
	Sessions.flushActivity()
	leave(sandbox)
	check(value("rbx:playSec") == sandboxBefore, "New Player Mode time never credited")

	-- Sub-second remainders carry over (credits are whole seconds; none lost or doubled).
	local fracBefore = value("rbx:playSec")
	local fractional = join(203)
	for _ = 1, 4 do
		env.advance(10.25)
		Sessions.flushActivity()
	end
	leave(fractional)
	check(value("rbx:playSec") - fracBefore == 41, `fractions carry between credits ({value("rbx:playSec") - fracBefore})`)
end

-- 5. Midnight split ----------------------------------------------------------------------------------
do
	env.setTime(DAY * 86400 + 86400 - 600) -- 23:50 UTC
	local beforeToday = valueOn(DAY, "rbx:playSec")
	local beforeTomorrow = valueOn(DAY + 1, "rbx:playSec")
	local owl, profile = join(301)
	env.advance(1200) -- 00:10 UTC the next day
	Sessions.flushActivity()
	check(valueOn(DAY, "rbx:playSec") - beforeToday == 600, "the 10 minutes before midnight stay on their day")
	check(valueOn(DAY + 1, "rbx:playSec") - beforeTomorrow == 600, "the 10 minutes after go to the new day")
	check(profile.analytics.rbxDay == DAY + 1 and profile.analytics.rbxSec == 600, "cap state on the new day")
	leave(owl)
end

-- 6. Intentional co-play -------------------------------------------------------------------------------
do
	env.setTime((DAY + 2) * 86400 + 3600)
	local host, hostProfile = join(401, { isNew = false, profile = newProfile() })
	check(value("rbx:coplay") == 0, "alone is not co-play")

	-- A friend follows the host in (slow profile: the joiner counts at load, the host at once).
	local follower = join(402, { follow = 401, noLoad = true })
	check(value("rbx:coplay") == 1 and value("rbx:coplayVia:host") == 1, "the followed host counts at once")
	load(follower, newProfile(), true)
	check(value("rbx:coplay") == 2 and value("rbx:coplayVia:follow") == 1, "the follower counts once loaded")

	-- A second follower: the host was already counted today (once per player per UTC day).
	local second = join(403, { follow = 401 })
	check(value("rbx:coplay") == 3 and value("rbx:coplayVia:host") == 1, "the host counts once per day")
	check(value("rbx:coplayVia:follow") == 2, "second follower counted")

	-- Invited by the host (JoinData.ReferredByPlayerId) while the host is here.
	local invited = join(404, { joinData = { ReferredByPlayerId = 401 } })
	check(value("rbx:coplay") == 4 and value("rbx:coplayVia:invite") == 1, "an invitee whose inviter is here")

	-- Not co-play: the friend is not here, a self / malformed referrer, a sandbox.
	local lonely = join(405, { follow = 9999, joinData = { ReferredByPlayerId = 8888 } })
	local selfRef = join(406, { joinData = { ReferredByPlayerId = 406 } })
	local textRef = join(407, { joinData = { ReferredByPlayerId = "401" } })
	local fracRef = join(408, { joinData = { ReferredByPlayerId = 401.5 } })
	local nanRef = join(409, { joinData = { ReferredByPlayerId = 0 / 0 } })
	local sandbox = join(410, { follow = 401, npm = true })
	check(value("rbx:coplay") == 4, `absent friends, bad referrers and sandboxes never count ({value("rbx:coplay")})`)
	check(value("rbx:coplayVia:host") == 1, "no host credit from them either")

	-- The bit is saved in the profile (once per day across servers).
	check(not AnalyticsMarks.markSeen(hostProfile.analytics, Recorder.today(), "coplay"), "host's coplay bit is set")
	for _, player in { host, follower, second, invited, lonely, selfRef, textRef, fracRef, nanRef, sandbox } do
		leave(player)
	end

	-- A VIP private server: company makes everyone here co-play; alone does not.
	env.setTime((DAY + 3) * 86400 + 3600)
	env.game.PrivateServerOwnerId = 77
	local owner = join(501, { isNew = false, profile = newProfile() })
	check(value("rbx:coplay") == 0, "alone in a private server is not co-play")
	local guest = join(502, { isNew = false, profile = newProfile() })
	check(
		value("rbx:coplay") == 2 and value("rbx:coplayVia:private") == 2,
		`private server company: both count ({value("rbx:coplay")})`
	)
	leave(owner)
	leave(guest)
	env.game.PrivateServerOwnerId = 0
	local publicA = join(503, { isNew = false, profile = newProfile() })
	local publicB = join(504, { isNew = false, profile = newProfile() })
	check(value("rbx:coplay") == 2, "a public server with a stranger is not co-play")
	leave(publicA)
	leave(publicB)
	env.game.PrivateServerOwnerId = nil
end

-- 7. Play days per user (rbx:day:<n>) -------------------------------------------------------------------
do
	env.setTime((DAY + 4) * 86400 + 3600)
	local today = DAY + 4
	local function returning(userId: number, age: number)
		local profile = newProfile()
		profile.analytics.first = today - age
		profile.analytics.last = today - 1
		profile.analytics.sessions = 2
		AnalyticsMarks.startCohort(profile.analytics)
		local player = join(userId, { profile = profile, isNew = false })
		leave(player)
	end
	returning(601, 1)
	check(value("r1") == 1 and value("rbx:day:1") == 0, "D1 stays r1 (no rbx:day:1 key)")
	returning(602, 2)
	returning(603, 7)
	returning(604, ALGORITHM.PlayDayMax)
	returning(605, ALGORITHM.PlayDayMax + 1)
	check(value("rbx:day:2") == 1 and value("rbx:day:7") == 1, "D2 / D7 play days")
	check(value(`rbx:day:{ALGORITHM.PlayDayMax}`) == 1, "the last day of the window")
	check(value(`rbx:day:{ALGORITHM.PlayDayMax + 1}`) == 0, "nothing past the window")
end

-- 8. FunnelStep refusal reasons ---------------------------------------------------------------------------
do
	env.setTime((DAY + 5) * 86400 + 3600)
	local player = join(701)
	env.advance(30) -- a full token bucket
	check(not Sessions.onFunnelStep(player, "worldPopup", 5, "go"), "malformed popup refused")
	check(not Sessions.onFunnelStep(player, "bogusStep"), "unknown step refused")
	check(not Sessions.onFunnelStep(player, 42), "non-string step refused")
	check(not Sessions.onFunnelStep(player, "open", "<script>", "hud"), "bad screen refused")
	check(not Sessions.onFunnelStep(player, "firstMove"), "implausible first move refused")
	for _ = 1, AnalyticsConfig.ClientFunnel.Burst - 5 do
		Sessions.onFunnelStep(player, "bogusStep")
	end
	check(not Sessions.onFunnelStep(player, "loadingDone"), "empty bucket refused")
	check(value("ops:clientRefused:FunnelStep:popup") == 1, "popup reason")
	check(value("ops:clientRefused:FunnelStep:unknown") == AnalyticsConfig.ClientFunnel.Burst - 4, "unknown reason")
	check(value("ops:clientRefused:FunnelStep:malformed") == 2, "malformed reason (bad step + bad screen)")
	check(value("ops:clientRefused:FunnelStep:implausible") == 1, "implausible reason")
	check(value("ops:clientRefused:FunnelStep:rate") == 1, "rate reason")
	-- The screen-open session cap (each open waits for a token).
	for _ = 1, AnalyticsConfig.ClientFunnel.SessionCap do
		env.advance(1 / AnalyticsConfig.ClientFunnel.PerSecond)
		Sessions.onFunnelStep(player, "open", "Shop", "hud")
	end
	env.advance(1 / AnalyticsConfig.ClientFunnel.PerSecond)
	check(not Sessions.onFunnelStep(player, "open", "Shop", "hud"), "screen open past the session cap refused")
	check(value("ops:clientRefused:FunnelStep:cap") == 1, "cap reason")
	local reasons = 0
	for _, reason in AnalyticsConfig.ClientRefusalReasons do
		if reason ~= "cap" then
			reasons += value(`ops:clientRefused:FunnelStep:{reason}`)
		end
	end
	check(
		value("ops:clientRefused:FunnelStep") == reasons,
		`base key = Σ reasons except cap ({value("ops:clientRefused:FunnelStep")} vs {reasons})`
	)
	leave(player)
end

-- 9. Profile fields ----------------------------------------------------------------------------------------
do
	local fresh = AnalyticsMarks.newAnalytics()
	check(fresh.rbxDay == 0 and fresh.rbxSec == 0, "new analytics record: nothing credited")
	local fixed = AnalyticsMarks.reconcileAnalytics({ rbxDay = DAY, rbxSec = 99999 })
	check(fixed.rbxDay == DAY and fixed.rbxSec == CAP, "a stored credit above the cap is clamped to it")
	fixed = AnalyticsMarks.reconcileAnalytics({ rbxDay = "x", rbxSec = -5 })
	check(fixed.rbxDay == 0 and fixed.rbxSec == 0, "junk → 0")
	fixed = AnalyticsMarks.reconcileAnalytics({ rbxDay = DAY, rbxSec = 1200.7 })
	check(fixed.rbxSec == 1200, "whole seconds")
	check(table.find(AnalyticsConfig.Unique.Surfaces, "coplay") ~= nil, "coplay is a unique-surface bit")
end

-- 10. Every recorded key is documented ----------------------------------------------------------------------
do
	local undocumented: { string } = {}
	for _, families in Recorder.unsavedCopy() do
		for family, counters in families do
			for key in counters do
				if #AnalyticsReport.presentPatterns({ [family] = { [key] = 1 } }) == 0 then
					table.insert(undocumented, `{family}:{key}`)
				end
			end
		end
	end
	table.sort(undocumented)
	check(#undocumented == 0, `undocumented keys: {table.concat(undocumented, ", ")}`)
end

restoreBuffers()
done("analytics-roblox-signals")
