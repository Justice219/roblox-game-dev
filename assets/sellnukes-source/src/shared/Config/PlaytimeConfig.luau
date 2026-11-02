--!strict
--[[
	PlaytimeConfig — the Early Gift Ladder (owner R89, spec 2026-10-31-r89-competitive-wave-design
	§3; replaces the design spec §7 seven-gift Time Rewards): TEN gifts unlocked by TODAY's online
	playtime at 1 / 3 / 5 / 10 / 15 / 25 / 40 / 60 / 90 / 120 minutes, counted by the server.

	Why this ladder: the day-1 data showed most churn inside the first 2 minutes, so the first gift
	lands at 1 minute and the next three inside the first 10. Every reward is DETERMINISTIC (cash
	seconds, gems, spins into the free bonus bank, timed boosts, one held crate) — nothing on the
	ladder is a paid random item, so a future paid skip could never be one either.

	State (profile.timeRewards = { day, seconds, claimed, ladder }):
		day      UTC day the counter belongs to (-1 = never played)
		seconds  playtime counted on that day (server 1 Hz loop, Server/Services/PlaytimeService)
		claimed  set of gift indices claimed on that day
		ladder   which ladder the `claimed` indices refer to (LadderVersion; saves from before R89
		         have none = 1, the old 7-gift ladder — see migrateClaimed)
	Progress is KEPT across rejoins on the same UTC day (the counter lives in the profile); a new
	UTC day starts a fresh ladder (seconds 0, nothing claimed). A clock that runs backwards never
	reopens a day.

	Crate gifts (`crate`): one HELD crate (CrateConfig id) on top of the gift's reward. Held crates
	are paid random items to OPEN (CrateConfig.PaidRandomPay), so a player whose region restricts
	paid random items (or whose policy is still unknown: fail closed) gets `fallbackGems` instead —
	decided by the server at claim time, previewed by the client from profile.policy.

	Favorite moment (`favoriteMoment`): claiming this gift is a "happy moment" for the one-time
	experience favorite prompt (Server/Retention/FavoritePrompt; never rewarded, never repeated once
	answered).

	The client shows countdowns by extrapolating `seconds` from the last profile push (the server
	pushes timeRewards every PushEverySeconds and on every claim / rollover), so it never sends
	anything but "claim gift i" / "claim all".

	Connects to: Shared/Config/RetentionConfig (Reward shape), Server/Retention/PlaytimeLogic (rules),
	Server/Services/PlaytimeService (loop + claims), Server/Economy/ProfileLogic (reconcile →
	migrateClaimed), UI/Screens/TimeRewards (the window), UI/RewardsBadges (hub badge),
	tests/retention-config.luau + tests/gift-ladder.luau.

	Example:
		local view = PlaytimeConfig.status(profile.timeRewards, today)
		for index, gift in view do print(index, gift.state, gift.secondsLeft) end
		print(#PlaytimeConfig.readyIndices(profile.timeRewards, today)) --> gifts CLAIM ALL would open
]]

local RetentionConfig = require(script.Parent.RetentionConfig)

-- A held crate granted with a gift (fallbackGems where paid random items are restricted).
export type CrateGift = { id: string, count: number, fallbackGems: number }

export type Gift = {
	index: number,
	minutes: number, -- playtime needed today
	icon: string, -- IconAssets key (the card picture)
	reward: RetentionConfig.Reward,
	crate: CrateGift?, -- optional held crate on top of `reward`
	big: boolean, -- the rainbow last gift
	favoriteMoment: boolean, -- claiming it may show the one-time favorite prompt
}

export type GiftState = "claimed" | "ready" | "locked"
export type GiftView = { index: number, state: GiftState, secondsLeft: number }

-- Read-only shape the views accept (server set form or snapshot array form for `claimed`).
export type StateView = { day: number, seconds: number, claimed: { [number]: any } }

local PlaytimeConfig = {}

-- The ladder the current GIFTS table defines (bump when gift indices change meaning).
PlaytimeConfig.LadderVersion = 2

--[[
	Minutes of every gift of each RETIRED ladder, by version (migrateClaimed maps their claimed
	indices onto the current ladder). Version 1 = the design spec §7 ladder (until R89).
]]
PlaytimeConfig.LegacyMinutes = table.freeze({
	[1] = table.freeze({ 5, 15, 30, 60, 90, 120, 180 }),
}) :: { [number]: { number } }

local GIFTS: { Gift } = {
	{
		index = 1,
		minutes = 1,
		icon = "Cash",
		big = false,
		favoriteMoment = false,
		reward = { cashSeconds = 30, cashFloor = 150 },
	},
	{ index = 2, minutes = 3, icon = "Gems", big = false, favoriteMoment = false, reward = { gems = 5 } },
	{
		index = 3,
		minutes = 5,
		icon = "Cash",
		big = false,
		favoriteMoment = false,
		reward = { cashSeconds = 60, cashFloor = 300 },
	},
	{
		-- The 10-minute gift: 10 minutes of 2x Cash, and the favorite prompt's happy moment.
		index = 4,
		minutes = 10,
		icon = "x2Cash",
		big = false,
		favoriteMoment = true,
		reward = { boost = { key = "cash2x", seconds = 600 } },
	},
	{ index = 5, minutes = 15, icon = "Gems", big = false, favoriteMoment = false, reward = { gems = 10 } },
	{
		index = 6,
		minutes = 25,
		icon = "CashPack",
		big = false,
		favoriteMoment = false,
		reward = { cashSeconds = 300, cashFloor = 1_500 },
	},
	{
		-- One held Supply Crate (120 gems in the crate shop) + 5 gems; restricted regions: 60 gems.
		index = 7,
		minutes = 40,
		icon = "Crate",
		big = false,
		favoriteMoment = false,
		reward = { gems = 5 },
		crate = { id = "supply_crate", count = 1, fallbackGems = 60 },
	},
	{
		index = 8,
		minutes = 60,
		icon = "Spins",
		big = false,
		favoriteMoment = false,
		reward = { spins = 2, gems = 10 },
	},
	{
		index = 9,
		minutes = 90,
		icon = "x2Cash",
		big = false,
		favoriteMoment = false,
		reward = { boost = { key = "cash2x", seconds = 900 }, cashSeconds = 600, cashFloor = 3_000 },
	},
	{
		index = 10,
		minutes = 120,
		icon = "Gift",
		big = true,
		favoriteMoment = false,
		reward = { cashSeconds = 1_800, cashFloor = 20_000, gems = 40, spins = 3 },
	},
}
for _, gift in GIFTS do
	if gift.reward.boost ~= nil then
		table.freeze(gift.reward.boost)
	end
	if gift.crate ~= nil then
		table.freeze(gift.crate)
	end
	table.freeze(gift.reward)
	table.freeze(gift)
end
PlaytimeConfig.Gifts = table.freeze(GIFTS)

-- Server loop: seconds credited per tick, at most this much credit per tick (a hitch never
-- mints time), a day never counts more than this, and a push of `timeRewards` this often.
PlaytimeConfig.TickSeconds = 1
PlaytimeConfig.MaxTickCredit = 5
PlaytimeConfig.MaxSecondsPerDay = 86_400
PlaytimeConfig.PushEverySeconds = 30

-- CLAIM ALL (ClaimTimeRewardsAll): the window enables it once at least this many gifts are ready
-- (it reads "CLAIM ALL (n)" from two up; with one ready it opens just that gift).
PlaytimeConfig.ClaimAllMin = 1

--[[
	The seconds counted on `today` (0 when the stored counter belongs to an earlier day).
]]
function PlaytimeConfig.secondsToday(state: { day: number, seconds: number }, today: number): number
	if state.day ~= today then
		return 0
	end
	return math.max(0, state.seconds)
end

--[[
	True when gift `index` was claimed on `today`. Accepts both the server set form
	({ [i] = true }) and the snapshot array form ({ i, ... }).
]]
function PlaytimeConfig.isClaimed(
	state: { day: number, claimed: { [number]: any } },
	index: number,
	today: number
): boolean
	if state.day ~= today then
		return false
	end
	if state.claimed[index] == true then
		return true
	end
	return table.find(state.claimed :: { any }, index) ~= nil
end

--[[
	Per-gift view for `today` (read-only; the server's claim uses the same rule).
	@param extraSeconds client-side extrapolation since the last push (0 on the server)
]]
function PlaytimeConfig.status(state: StateView, today: number, extraSeconds: number?): { GiftView }
	local seconds = PlaytimeConfig.secondsToday(state, today) + math.max(0, extraSeconds or 0)
	local views: { GiftView } = {}
	for _, gift in GIFTS do
		local needed = gift.minutes * 60
		local state_: GiftState = if PlaytimeConfig.isClaimed(state, gift.index, today)
			then "claimed"
			elseif seconds >= needed then "ready"
			else "locked"
		table.insert(views, {
			index = gift.index,
			state = state_,
			secondsLeft = math.max(0, needed - seconds),
		})
	end
	return views
end

--[[
	The gift indices that are READY on `today` (reached, not claimed), ascending — what CLAIM ALL
	opens. Same rule as `status`.
	Example: PlaytimeConfig.readyIndices({ day = 9, seconds = 400, claimed = { 1 } }, 9) --> { 2, 3 }
]]
function PlaytimeConfig.readyIndices(state: StateView, today: number, extraSeconds: number?): { number }
	local ready: { number } = {}
	for _, view in PlaytimeConfig.status(state, today, extraSeconds) do
		if view.state == "ready" then
			table.insert(ready, view.index)
		end
	end
	return ready
end

--[[
	The gift whose playtime mark is exactly `minutes` (nil when none) — admin tools and docs.
	Example: PlaytimeConfig.giftAt(10).index --> 4
]]
function PlaytimeConfig.giftAt(minutes: number): Gift?
	for _, gift in GIFTS do
		if gift.minutes == minutes then
			return gift
		end
	end
	return nil
end

--[[
	Maps a saved `claimed` set onto the CURRENT ladder (ProfileLogic.reconcile; pure, never
	mutates its input). Migration-safe by construction — it never reopens a gift the player was
	already paid for on that day:
		- current ladder: kept as-is (indices outside 1..#Gifts dropped);
		- a retired ladder (LegacyMinutes): every current gift whose mark is <= the HIGHEST claimed
		  legacy mark counts as claimed (e.g. old 5-min gift claimed → new 1 / 3 / 5-min gifts
		  closed; the 10-min gift and later stay open);
		- an unknown version (junk / future): every current gift the stored playtime already
		  reached counts as claimed (conservative: no double payout; later gifts stay open).
	@param ladder  the stored ladder version (1 for saves from before R89)
	@param claimed the reconciled set { [index] = true }
	@param seconds the stored playtime of that day
	@return a fresh set for LadderVersion
	Example: PlaytimeConfig.migrateClaimed(1, { [2] = true }, 960) --> { [1..5] = true } (15-min mark)
]]
function PlaytimeConfig.migrateClaimed(ladder: number, claimed: { [number]: true }, seconds: number): { [number]: true }
	local out: { [number]: true } = {}
	if ladder == PlaytimeConfig.LadderVersion then
		for index in claimed do
			if GIFTS[index] ~= nil then
				out[index] = true
			end
		end
		return out
	end
	local legacy = PlaytimeConfig.LegacyMinutes[ladder]
	local reachedMinutes = 0
	if legacy ~= nil then
		for index in claimed do
			local minutes = legacy[index]
			if minutes ~= nil and minutes > reachedMinutes then
				reachedMinutes = minutes
			end
		end
	elseif next(claimed) ~= nil or seconds > 0 then
		-- Unknown version: assume every gift the stored playtime reached was already paid.
		reachedMinutes = if seconds == seconds and seconds > 0 then seconds / 60 else 0
	end
	for _, gift in GIFTS do
		if gift.minutes <= reachedMinutes then
			out[gift.index] = true
		end
	end
	return out
end

return table.freeze(PlaytimeConfig)
