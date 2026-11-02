--!strict
--[[
	Rewards hub regressions (owner R62: Daily / Time / Lucky Wheel / Codes / Group fold into ONE
	HUD "Rewards" button + a hub window). Run:
		lune run tests/rewards-hub
	Proves on the shipped modules (UI/RewardsBadges pure core, Screens/RewardsHub/HubLayout,
	Shared/Config/RewardsHubConfig):
	  1. Config: six features (R78: + Friends), unique ids / screens, folded HUD keys, analytics ids
	     allowlisted.
	  2. Nothing claimable → total 0, badge hidden; no profile → "loading", total 0.
	  3. Counts per feature use the screens' own rules (Daily canClaim, ready playtime gifts with
	     the screen's extrapolation, free + bonus spins, group member & unclaimed) and sum up.
	  4. Timers: Daily → next UTC midnight, Time → soonest locked gift (else midnight), Wheel →
	     next free spin; wakeAt = the soonest change; status lines read "Next in 2h 14m".
	  5. Hostile input: NaN / inf / wrong types never produce NaN counts, totals or timers.
	  6. Badge text: nil at 0, whole numbers, "99+" cap.
	  7. Layout: both modes fit their window body, tiles never overlap, taps ≥ the touch minimum,
	     and the gamepad links reach every tile.
]]
local Loader = require("./fixtures/RobloxLoader")
local loader = Loader.new()
local Badges = loader.load("src/client/UI/RewardsBadges")
local HubLayout = loader.load("src/client/UI/Screens/RewardsHub/HubLayout")
local Config = loader.load("src/shared/Config/RewardsHubConfig")
local AnalyticsConfig = loader.load("src/shared/Config/AnalyticsConfig")
local LuckySpinConfig = loader.load("src/shared/Config/LuckySpinConfig")
local PlaytimeConfig = loader.load("src/shared/Config/PlaytimeConfig")
local RetentionConfig = loader.load("src/shared/Config/RetentionConfig")

local checks = 0
local function ok(condition: boolean, label: string)
	checks += 1
	assert(condition, label)
end

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local DAY = RetentionConfig.SecondsPerDay
-- A fixed moment: day 20_000, 10:00:00 UTC.
local TODAY = 20_000
local NOW = TODAY * DAY + 10 * 3600

-- A profile where nothing is claimable: Daily claimed today, every gift claimed, wheel empty with
-- its timer running, group claimed.
local function quietProfile(): { [string]: any }
	local claimed = {}
	for _, gift in PlaytimeConfig.Gifts do
		table.insert(claimed, gift.index)
	end
	return {
		daily = { streak = 3, lastDay = TODAY },
		timeRewards = { day = TODAY, seconds = 99_999, claimed = claimed },
		spin = { free = 0, lastFreeAt = NOW - 60, paid = 7, bonus = 0 },
		group = { claimed = true },
	}
end

local function evaluate(profile: { [string]: any }?, extra: { [string]: any }?): any
	local input: { [string]: any } = { profile = profile, now = NOW, timeReceivedAt = NOW, groupEnabled = true }
	for key, value in extra or {} do
		input[key] = value
	end
	return Badges.evaluate(input)
end

-- 1. Config ---------------------------------------------------------------------------------------
local ids, screens = {}, {}
for _, feature in Config.Features do
	ok(ids[feature.id] == nil, `unique feature id {feature.id}`)
	ok(screens[feature.screen] == nil, `unique feature screen {feature.screen}`)
	ids[feature.id] = true
	screens[feature.screen] = true
	ok(Config.byId(feature.id) == feature, `byId finds {feature.id}`)
end
ok(#Config.Features == 6, "six reward features in the hub (R78: + Friends)")
for _, id in { "Daily", "Time", "LuckyWheel", "Group", "Codes", "Friends" } do
	ok(ids[id] == true, `hub has {id}`)
end
for _, key in { "Daily", "Time", "LuckyWheel", "Codes" } do
	ok(Badges.isFoldedKey(key), `old HUD key {key} is folded into the hub`)
end
for _, key in { "Shop", "Pets", "Rewards", "Rebirth", "Teleport", "Attack", "Event", "Admin" } do
	ok(not Badges.isFoldedKey(key), `{key} stays its own HUD button`)
end
ok(
	table.find(AnalyticsConfig.ClientFunnel.Screens, Config.AnalyticsScreen) ~= nil,
	"hub analytics screen id allowlisted"
)
ok(table.find(AnalyticsConfig.ClientFunnel.Sources, Config.TileSource) ~= nil, "hub tile source allowlisted")
ok(Config.byId("Nope") == nil, "unknown id → nil")

-- 2. Nothing claimable / no profile ---------------------------------------------------------------
do
	local snap = evaluate(quietProfile())
	ok(snap.total == 0, `nothing claimable → total 0 (got {snap.total})`)
	ok(Badges.formatBadge(snap.total) == nil, "total 0 → badge hidden")
	for id, state in snap.features do
		ok(state.count == 0, `{id}: count 0 when quiet`)
	end
	ok(snap.features.Group.kind == "claimed", "claimed group reads 'claimed'")
	ok(snap.features.Codes.kind == "code", "codes never badge")
	local text = Badges.statusText(snap.features.Group, NOW)
	ok(text == Config.Text.GroupClaimed, "claimed group line")

	local empty = evaluate(nil)
	ok(empty.total == 0, "no profile → total 0")
	for _, id in { "Daily", "Time", "LuckyWheel", "Group" } do
		ok(empty.features[id].kind == "loading", `no profile → {id} loading`)
		ok(Badges.statusText(empty.features[id], NOW) == Config.Text.Loading, `{id} loading line`)
	end
	ok(empty.wakeAt == nil, "no profile → no wake timer")
end

-- 3. Counts ----------------------------------------------------------------------------------------
do
	-- Daily: yesterday's claim → claimable today (the screen's dailyStatus rule).
	local profile = quietProfile()
	profile.daily = { streak = 3, lastDay = TODAY - 1 }
	local snap = evaluate(profile)
	ok(snap.features.Daily.count == 1 and snap.features.Daily.kind == "claim", "daily claimable → 1")
	ok(Badges.statusText(snap.features.Daily, NOW) == Config.Text.Claim, "daily claim line")
	ok(snap.total == 1, "daily alone → total 1")
	-- Never claimed (lastDay -1) also opens Day 1.
	profile.daily = { streak = 0, lastDay = -1 }
	ok(evaluate(profile).features.Daily.count == 1, "first daily claim counts")

	-- Time: the screen's PlaytimeConfig.status count of "ready" gifts (none claimed today).
	local gifts = PlaytimeConfig.Gifts
	local secondsFor2 = gifts[2].minutes * 60
	profile = quietProfile()
	profile.timeRewards = { day = TODAY, seconds = secondsFor2, claimed = {} }
	snap = evaluate(profile)
	local expected = 0
	for _, view in PlaytimeConfig.status(profile.timeRewards, TODAY, 0) do
		if view.state == "ready" then
			expected += 1
		end
	end
	ok(expected >= 2, "fixture: at least two gifts ready")
	ok(snap.features.Time.count == expected, `time ready gifts = {expected} (got {snap.features.Time.count})`)
	-- Extrapolation: a push 90 s ago adds 90 s of playtime (the Time Rewards screen's rule).
	local justShort = gifts[1].minutes * 60 - 60
	profile.timeRewards = { day = TODAY, seconds = justShort, claimed = {} }
	ok(evaluate(profile, { timeReceivedAt = NOW }).features.Time.count == 0, "not yet ready without extrapolation")
	ok(
		evaluate(profile, { timeReceivedAt = NOW - 90 }).features.Time.count >= 1,
		"extrapolated playtime unlocks the gift"
	)
	-- A push from yesterday: only playtime since midnight counts (screen rule), claims reset.
	profile.timeRewards = { day = TODAY - 1, seconds = 99_999, claimed = { 1, 2, 3 } }
	local sinceMidnight = NOW - TODAY * DAY
	local yesterday = evaluate(profile, { timeReceivedAt = NOW - 5 * DAY })
	local wantYesterday = 0
	for _, view in PlaytimeConfig.status(profile.timeRewards, TODAY, sinceMidnight) do
		if view.state == "ready" then
			wantYesterday += 1
		end
	end
	ok(yesterday.features.Time.count == wantYesterday, "stale-day push: playtime since midnight only")

	-- Wheel: free + bonus spins (paid spins never badge).
	profile = quietProfile()
	profile.spin = { free = 2, lastFreeAt = NOW - 10, paid = 50, bonus = 3 }
	snap = evaluate(profile)
	ok(snap.features.LuckyWheel.count == 5, `wheel free 2 + bonus 3 → 5 (got {snap.features.LuckyWheel.count})`)
	ok(Badges.statusText(snap.features.LuckyWheel, NOW) == Config.Text.Spin, "wheel spin line")
	profile.spin = { free = 0, lastFreeAt = NOW - 10, paid = 50 } -- no bonus field (old snapshot)
	ok(evaluate(profile).features.LuckyWheel.count == 0, "paid spins alone never badge")
	-- Free spins accrue from lastFreeAt like LuckySpinConfig.status (the screen's rule).
	profile.spin = { free = 0, lastFreeAt = NOW - LuckySpinConfig.FreeEverySeconds * 2 - 5, paid = 0, bonus = 0 }
	ok(evaluate(profile).features.LuckyWheel.count == 2, "two refill periods → 2 free spins")

	-- Group: only a configured, unclaimed reward the client sees the player eligible for.
	profile = quietProfile()
	profile.group = { claimed = false }
	ok(evaluate(profile, { groupMember = true }).features.Group.count == 1, "member + unclaimed → 1")
	local join = evaluate(profile, { groupMember = false }).features.Group
	ok(join.count == 0 and join.kind == "join", "not a member → join, 0")
	ok(evaluate(profile, { groupMember = nil }).features.Group.count == 0, "unknown membership → 0")
	local soon = evaluate(profile, { groupEnabled = false, groupMember = true }).features.Group
	ok(soon.count == 0 and soon.kind == "soon", "no group configured → soon, 0")
	ok(Badges.statusText(soon, NOW) == Config.Text.GroupSoon, "soon line")

	-- Everything at once sums.
	profile = quietProfile()
	profile.daily = { streak = 1, lastDay = TODAY - 1 }
	profile.timeRewards = { day = TODAY, seconds = secondsFor2, claimed = {} }
	profile.spin = { free = 1, lastFreeAt = NOW - 10, paid = 0, bonus = 1 }
	profile.group = { claimed = false }
	snap = evaluate(profile, { groupMember = true })
	ok(snap.total == 1 + expected + 2 + 1, `total sums every feature (got {snap.total})`)
end

-- 4. Timers ---------------------------------------------------------------------------------------
do
	local midnight = (TODAY + 1) * DAY
	local snap = evaluate(quietProfile())
	ok(snap.features.Daily.kind == "wait" and snap.features.Daily.readyAt == midnight, "daily waits for UTC midnight")
	local text, tone = Badges.statusText(snap.features.Daily, NOW)
	ok(text == "Next in 14h 00m" and tone == "wait", `daily line '{text}'`)
	ok(Badges.statusText(snap.features.Daily, midnight - (2 * 3600 + 14 * 60)) == "Next in 2h 14m", "ready in 2h 14m")
	-- Every gift claimed → the fresh ladder at midnight.
	ok(snap.features.Time.readyAt == midnight, "all gifts claimed → time waits for midnight")
	-- Wheel timer = LuckySpinConfig.status nextFreeIn.
	local spinStatus = LuckySpinConfig.status(quietProfile().spin, NOW)
	ok(snap.features.LuckyWheel.readyAt == NOW + spinStatus.nextFreeIn, "wheel waits for the next free spin")
	local wheelText = Badges.statusText(snap.features.LuckyWheel, NOW)
	ok(string.find(wheelText, "Spin in ", 1, true) == 1, `wheel wait line '{wheelText}'`)
	ok(snap.wakeAt == math.min(midnight, NOW + spinStatus.nextFreeIn), "wakeAt = the soonest change")

	-- Time: the soonest locked gift is the timer.
	local profile = quietProfile()
	profile.timeRewards = { day = TODAY, seconds = 0, claimed = {} }
	local time = evaluate(profile).features.Time
	ok(time.count == 0 and time.kind == "wait", "no playtime → waiting")
	ok(time.readyAt == NOW + PlaytimeConfig.Gifts[1].minutes * 60, "time waits for the first gift")
	-- A countdown that already passed never goes negative.
	ok(Badges.statusText(time, NOW + 99_999) == string.format(Config.Text.TimeWait, "0s"), "past countdown reads 0s")
	-- The absolute readyAt is stable between pushes (extrapolation moves now and seconds together).
	local later = evaluate(profile, { now = NOW + 30, timeReceivedAt = NOW }).features.Time
	ok(math.abs(later.readyAt - time.readyAt) < 1e-6, "time readyAt stable while extrapolating")
end

-- 5. Hostile input ----------------------------------------------------------------------------------
do
	local nan = 0 / 0
	local hostile: { { [string]: any } } = {
		{ daily = { streak = nan, lastDay = TODAY } },
		{ daily = { streak = math.huge, lastDay = -math.huge } },
		{ daily = "yes", timeRewards = 5, spin = true, group = "x" },
		{ timeRewards = { day = nan, seconds = 10, claimed = {} } },
		{ timeRewards = { day = TODAY, seconds = math.huge, claimed = "all" } },
		{ spin = { free = nan, lastFreeAt = NOW, paid = 0 } },
		{ spin = { free = 1, lastFreeAt = math.huge, paid = 0, bonus = nan } },
		{ spin = { free = -5, lastFreeAt = 0, paid = -1, bonus = -3 } },
		{ group = { claimed = "true" } },
	}
	for index, profile in hostile do
		for _, now in { NOW, nan, math.huge, -5, 0 } do
			local snap = Badges.evaluate({ profile = profile, now = now, timeReceivedAt = nan, groupEnabled = true })
			ok(isFinite(snap.total) and snap.total >= 0 and snap.total % 1 == 0, `hostile {index}: finite whole total`)
			ok(snap.wakeAt == nil or isFinite(snap.wakeAt), `hostile {index}: finite wakeAt`)
			for id, state in snap.features do
				ok(isFinite(state.count) and state.count >= 0, `hostile {index} {id}: finite count`)
				ok(state.readyAt == nil or isFinite(state.readyAt), `hostile {index} {id}: finite readyAt`)
				local text = Badges.statusText(state, now)
				ok(
					type(text) == "string" and string.find(text, "nan", 1, true) == nil,
					`hostile {index} {id}: clean text`
				)
			end
		end
	end
end

-- 6. Badge text -------------------------------------------------------------------------------------
ok(Badges.formatBadge(0) == nil, "0 → nil")
ok(Badges.formatBadge(-3) == nil, "negative → nil")
ok(Badges.formatBadge(0 / 0) == nil, "NaN → nil")
ok(Badges.formatBadge("3") == nil, "string → nil")
ok(Badges.formatBadge(1) == "1", "1 → '1'")
ok(Badges.formatBadge(7.9) == "7", "floors")
ok(Badges.formatBadge(Config.BadgeCap) == tostring(Config.BadgeCap), "cap itself shows")
ok(Badges.formatBadge(Config.BadgeCap + 1) == `{Config.BadgeCap}+`, "over the cap → '99+'")
ok(Badges.formatBadge(math.huge) == nil, "inf → nil")

-- 7. Layout -------------------------------------------------------------------------------------------
local WindowCfg = { HeaderHeight = 104, HeaderLip = 5, BodyPadding = 16 }
local function bodySize(size: any): (number, number)
	return size.X - 2 * WindowCfg.BodyPadding,
		size.Y - WindowCfg.HeaderHeight - WindowCfg.HeaderLip - 2 * WindowCfg.BodyPadding
end
local function overlaps(a: any, b: any): boolean
	return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
end
ok(#HubLayout.rows("grid", 5) == 2 and #HubLayout.rows("grid", 5)[1] == 3, "grid = 3 + 2")
ok(#HubLayout.rows("row", 5) == 1, "row = one row")
-- Touch minimums per device (design px): none (mouse / gamepad) and a phone (44 pt / 14 pt at ~0.62).
for _, mode in Config.Modes do
	for _, device in { { tap = 0, minText = 0 }, { tap = 71, minText = 23 }, { tap = 55, minText = 18 } } do
		local width, height = bodySize(mode.size)
		local count = #Config.Features
		local placement = HubLayout.place(mode.name, width, height, count, device.tap, device.minText)
		local label = `{mode.name} tap {device.tap}`
		ok(#placement.tiles == count, `{label}: every tile placed`)
		for index, tile in placement.tiles do
			local f = tile.frame
			ok(
				f.x >= 0 and f.y >= 0 and f.x + f.width <= width + 0.01 and f.y + f.height <= height + 0.01,
				`{label}: tile {index} inside the body`
			)
			ok(tile.side >= device.tap and tile.side >= Config.Layout.MinSide, `{label}: tile {index} tap ≥ minimum`)
			ok(tile.side <= f.width, `{label}: button inside its column`)
			ok(
				tile.pill.y + tile.pill.height <= f.height + 0.01 and tile.pill.width <= f.width,
				`{label}: pill inside tile`
			)
			ok(tile.textSize >= device.minText and tile.minText == device.minText, `{label}: text ≥ floor`)
			ok(tile.pill.height >= 2 * device.minText, `{label}: pill fits two floor lines`)
			for other = index + 1, count do
				ok(not overlaps(f, placement.tiles[other].frame), `{label}: tiles {index}/{other} never overlap`)
			end
		end
		-- Gamepad: from tile 1, left/right/up/down reach every tile; no link points outside.
		local links = HubLayout.links(placement)
		local seen = { [1] = true }
		local queue = { 1 }
		while #queue > 0 do
			local at = table.remove(queue, 1) :: number
			for _, to in { links[at].left, links[at].right, links[at].up, links[at].down } do
				ok(to == nil or (to >= 1 and to <= count), `{label}: link in range`)
				if to ~= nil and not seen[to] then
					seen[to] = true
					table.insert(queue, to)
				end
			end
		end
		for index = 1, count do
			ok(seen[index] == true, `{label}: tile {index} reachable by gamepad`)
		end
	end
end
-- R78 (six tiles): on a phone the status pills must show their FULL text. UITextSizeConstraint
-- sizes are rendered px (= device points on touch), so HubLayout.textLimits uses the 14 pt rule
-- itself as the floor (never the design-px minText); two lines at that floor fit the pill (greedy
-- word wrap with a generous 0.62 em average glyph width), for every status line the hub writes.
do
	local function wrapLines(text: string, maxWidth: number, size: number): number
		local lines, width = 1, 0
		for word in string.gmatch(text, "%S+") do
			local w = #word * size * 0.62
			if w > maxWidth then
				return math.huge -- a single word wider than the pill
			end
			local needed = if width == 0 then w else width + size * 0.3 + w
			if needed > maxWidth then
				lines += 1
				width = w
			else
				width = needed
			end
		end
		return lines
	end
	local statuses = {
		Config.Text.Claim,
		Config.Text.Spin,
		Config.Text.GroupJoin,
		Config.Text.GroupClaimed,
		Config.Text.GroupSoon,
		Config.Text.Codes,
		Config.Text.FriendsInvite,
		string.format(Config.Text.FriendsBoost, 50),
		string.format(Config.Text.DailyWait, "23h 59m"),
		string.format(Config.Text.TimeWait, "59m 59s"),
		string.format(Config.Text.WheelWait, "14m 05s"),
	}
	local row = Config.Modes[2]
	local width, height = bodySize(row.size)
	for _, points in { 0.62, 0.58, 0.7 } do
		local tap = 44 / points
		local minText = 14 / points
		local placement = HubLayout.place(row.name, width, height, #Config.Features, tap, minText)
		for index, tile in placement.tiles do
			local maxSize, minSize = HubLayout.textLimits(tile)
			ok(minSize == 14, `phone {points}: tile {index} text floor is 14 pt (got {minSize})`)
			ok(maxSize >= minSize, `phone {points}: max ≥ min`)
			ok(tile.side * points >= 44 - 0.01, `phone {points}: tile {index} tap ≥ 44 pt`)
			local innerW = (tile.pill.width - 2 * Config.Layout.PillPad) * points
			local innerH = (tile.pill.height - 2 * Config.Layout.PillPad) * points
			ok(innerH >= 2 * minSize * 1.2, `phone {points}: two 14 pt lines fit the pill height`)
			for _, text in statuses do
				local lines = wrapLines(text, innerW, minSize)
				ok(lines <= 2, `phone {points}: "{text}" wraps into ≤ 2 lines at 14 pt (got {lines})`)
			end
		end
	end
	-- Desktop / console (no floor): the kit's 10 px floor, the authored 30 design px cap.
	local grid = HubLayout.place("grid", width, height, #Config.Features, 0, 0)
	local maxSize, minSize = HubLayout.textLimits(grid.tiles[1])
	ok(maxSize == Config.Layout.StatusText and minSize == 10, "desktop limits = authored cap / kit floor")
end

-- The grid's second row links up / down to the nearest centres.
do
	local width, height = bodySize(Config.Modes[1].size)
	local links = HubLayout.links(HubLayout.place("grid", width, height, 5, 0, 0))
	ok(links[1].down == 4 and links[3].down == 5, "grid: outer columns go down to the near tile")
	ok(links[4].up ~= nil and links[5].up ~= nil and links[1].up == nil, "grid: row 2 goes up; row 1 up is the X")
	ok(links[4].right == 5 and links[5].left == 4 and links[3].right == nil, "grid: rows walk left / right")
end

print(`rewards-hub: {checks} checks passed`)
