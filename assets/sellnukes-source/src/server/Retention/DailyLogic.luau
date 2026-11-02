--!strict
--[[
	DailyLogic — the server's Daily Rewards claim (mutation side of RetentionConfig.dailyStatus).

	claim(daily, today):
		refuses when RetentionConfig.dailyStatus says no claim is open (claimed today / clock
		behind); otherwise advances the streak (continue or restart at 1), stamps lastDay = today
		and returns the card index to pay. The reward itself is paid by the caller in the SAME
		non-yielding step (RewardGrant.grant), so a claim can never be recorded without its pay.

	Example:
		local index, reset = DailyLogic.claim(profile.daily, RetentionConfig.utcDay(os.time()))
		if index ~= nil then RewardLogic.apply(profile, RetentionConfig.Days[index].reward, now) end
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RetentionConfig = require(ReplicatedStorage.Shared.Config.RetentionConfig)

local DailyLogic = {}

--[[
	Claims today's card.
	@return the card index (1..7) and whether the streak restarted after a gap, or nil when no
	        claim is open
]]
function DailyLogic.claim(daily: { streak: number, lastDay: number }, today: number): (number?, boolean)
	if today ~= today or today < 0 or today % 1 ~= 0 then
		return nil, false
	end
	local status = RetentionConfig.dailyStatus(daily, today)
	if not status.canClaim then
		return nil, false
	end
	if status.nextIndex == 1 and (daily.lastDay < 0 or today - daily.lastDay ~= 1) then
		daily.streak = 1
	else
		daily.streak = math.max(0, daily.streak) + 1
	end
	daily.lastDay = today
	return status.nextIndex, status.resetting
end

return table.freeze(DailyLogic)
