--!strict
--[[
	RetentionConfig — the shared reward shape, the 7-day Daily Rewards streak, the notification
	opt-in reward and the UTC-day math every retention system uses (design spec §7).

	Purpose:
		One place for the numbers and the READ-ONLY status rules, shared by the server (which
		decides and grants: Server/Retention/DailyLogic, Server/Services/RetentionService) and the
		client (which only draws: UI/Screens/DailyRewards). Mutations never happen here.

	Reward shape (`Reward`, also used by PlaytimeConfig, LuckySpinConfig, CodesConfig,
	GroupConfig, ShopConfig): any mix of
		cashSeconds + cashFloor  cash = max(cashFloor, cashSeconds × the player's automated
		                         income per second) — so a reward stays meaningful from the garage
		                         to the Mega Facility (income from TycoonLogic.incomePerSecond on
		                         profile.tycoon with rebirth bonuses; timed boosts excluded)
		gems / spins             whole numbers (spins = paid Lucky Wheel spins)
		boost = { key, seconds } a personal timed boost (BoostConfig.Boosts[key]), time stacks
		pet / egg                ids for the pets system (B9); `fallbackGems` is paid instead while
		                         that system has not registered a granter

	Daily streak (profile.daily = { streak, lastDay }; days are UTC day numbers):
		- one claim per UTC day; claiming the day after the last claim continues the streak, any
		  longer gap restarts it at Day 1 (a missed day = the 48 h window ran out);
		- the card for streak n is Day ((n - 1) % 7) + 1, so after Day 7 the cycle starts again;
		- a clock that runs backwards never opens a claim.

	Example:
		local status = RetentionConfig.dailyStatus(profile.daily, RetentionConfig.utcDay(now))
		if status.canClaim then print("claim Day", status.nextIndex) end
]]

-- Personal boost granted by a reward.
export type BoostGrant = { key: string, seconds: number }

-- A reward definition (see the header). All fields optional; at least one must be set.
export type Reward = {
	cashSeconds: number?,
	cashFloor: number?,
	gems: number?,
	spins: number?,
	boost: BoostGrant?,
	pet: string?,
	egg: string?,
	fallbackGems: number?,
}

-- One Daily Rewards card.
export type DailyDay = {
	index: number, -- 1..7
	label: string, -- "One" .. "Seven" (card caption, as in the reference)
	icon: string, -- IconAssets key
	reward: Reward,
	big: boolean, -- the rainbow Day 7 card
}

-- What the Daily Rewards screen draws (computed identically on server and client).
export type DailyStatus = {
	canClaim: boolean, -- a claim is open today
	nextIndex: number, -- the card a claim would pay (1..7)
	claimedUpTo: number, -- cards 1..claimedUpTo of the current cycle show CLAIMED (0..7)
	resetting: boolean, -- the streak was broken: the next claim restarts at Day 1
}

local RetentionConfig = {}

local SECONDS_PER_DAY = 86400
RetentionConfig.SecondsPerDay = SECONDS_PER_DAY

-- The 7 Daily Rewards cards (spec §7; Day 7 is the big rainbow card).
local DAYS: { DailyDay } = {
	{ index = 1, label = "One", icon = "Gift", big = false, reward = { cashSeconds = 120, cashFloor = 250 } },
	{ index = 2, label = "Two", icon = "Gems", big = false, reward = { gems = 10 } },
	{ index = 3, label = "Three", icon = "Cash", big = false, reward = { cashSeconds = 300, cashFloor = 1_000 } },
	{
		index = 4,
		label = "Four",
		icon = "x2Cash",
		big = false,
		reward = { boost = { key = "cash2x", seconds = 600 } },
	},
	{ index = 5, label = "Five", icon = "Spins", big = false, reward = { spins = 2 } },
	{
		index = 6,
		label = "Six",
		icon = "Cash",
		big = false,
		reward = { cashSeconds = 900, cashFloor = 5_000, gems = 15 },
	},
	{
		index = 7,
		label = "Seven",
		icon = "Star",
		big = true,
		reward = {
			cashSeconds = 1_800,
			cashFloor = 25_000,
			gems = 50,
			spins = 3,
			boost = { key = "cash2x", seconds = 1_800 },
		},
	},
}
for _, day in DAYS do
	table.freeze(day.reward)
	if day.reward.boost ~= nil then
		table.freeze(day.reward.boost)
	end
	table.freeze(day)
end
RetentionConfig.Days = table.freeze(DAYS)

-- Notification opt-in reward (paid once per player; spec §7 "Get notified! TURN ON").
RetentionConfig.Notify = table.freeze({
	Reward = table.freeze({ gems = 25, spins = 1 }) :: Reward,
	-- The client must report "shown" (Roblox's dialog opened) before "accepted"; the accept is
	-- honoured only within this many seconds of that report.
	ArmWindowSeconds = 300,
})

-- Remote rate limits (token buckets: burst, refill per second).
RetentionConfig.Limits = table.freeze({
	Claim = table.freeze({ Burst = 4, PerSecond = 0.5 }),
	Notify = table.freeze({ Burst = 4, PerSecond = 0.2 }),
	Settings = table.freeze({ Burst = 8, PerSecond = 2 }),
})

--[[ The UTC day number of a unix time (days since 1970-01-01). ]]
function RetentionConfig.utcDay(unixTime: number): number
	return unixTime // SECONDS_PER_DAY
end

--[[ Seconds until the next UTC midnight (1..86400). Countdown on claimed / locked cards. ]]
function RetentionConfig.secondsToNextDay(unixTime: number): number
	return SECONDS_PER_DAY - (math.floor(unixTime) % SECONDS_PER_DAY)
end

-- Cycle position of a streak count (1..7; 0 for no streak).
local function cycleIndex(streak: number): number
	if streak <= 0 then
		return 0
	end
	return ((streak - 1) % #DAYS) + 1
end

--[[
	The Daily Rewards status for `daily` (profile.daily) on UTC day `today`. Pure and read-only:
	the server's claim and the client's screen both use it, so they always agree.
	Example: RetentionConfig.dailyStatus({ streak = 3, lastDay = 100 }, 101).nextIndex --> 4
]]
function RetentionConfig.dailyStatus(daily: { streak: number, lastDay: number }, today: number): DailyStatus
	local lastDay = daily.lastDay
	local streak = math.max(0, daily.streak)
	if lastDay >= 0 and today < lastDay then
		-- Clock behind the last claim: nothing opens until the clock catches up.
		return {
			canClaim = false,
			nextIndex = cycleIndex(streak + 1),
			claimedUpTo = cycleIndex(streak),
			resetting = false,
		}
	end
	if lastDay >= 0 and today == lastDay then
		-- Claimed today: the cycle so far shows CLAIMED, the next card counts down to midnight.
		local current = cycleIndex(streak)
		return {
			canClaim = false,
			nextIndex = (current % #DAYS) + 1,
			claimedUpTo = current,
			resetting = false,
		}
	end
	local continues = lastDay >= 0 and today - lastDay == 1 and streak > 0
	if continues then
		local current = cycleIndex(streak)
		-- After a finished Day 7 the next cycle starts empty.
		local shown = if current == #DAYS then 0 else current
		return { canClaim = true, nextIndex = cycleIndex(streak + 1), claimedUpTo = shown, resetting = false }
	end
	return { canClaim = true, nextIndex = 1, claimedUpTo = 0, resetting = lastDay >= 0 and streak > 0 }
end

--[[ True when a reward definition grants something (validation / tests). ]]
function RetentionConfig.isRewardValid(reward: Reward): boolean
	local any = false
	local function positive(value: number?): boolean
		if value == nil then
			return true
		end
		if value ~= value or value <= 0 or value == math.huge then
			return false
		end
		any = true
		return true
	end
	if not positive(reward.cashSeconds) or not positive(reward.cashFloor) then
		return false
	end
	if not positive(reward.gems) or not positive(reward.spins) or not positive(reward.fallbackGems) then
		return false
	end
	if reward.gems ~= nil and reward.gems % 1 ~= 0 then
		return false
	end
	if reward.spins ~= nil and reward.spins % 1 ~= 0 then
		return false
	end
	if reward.boost ~= nil then
		if type(reward.boost.key) ~= "string" or not positive(reward.boost.seconds) then
			return false
		end
	end
	if reward.pet ~= nil or reward.egg ~= nil then
		any = true
		if reward.fallbackGems == nil then
			return false -- items need a fallback while the pets system is not live
		end
	end
	return any
end

return table.freeze(RetentionConfig)
