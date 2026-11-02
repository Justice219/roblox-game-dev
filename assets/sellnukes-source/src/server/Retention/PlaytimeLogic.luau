--!strict
--[[
	PlaytimeLogic — server rules for the Early Gift Ladder (owner R89; pattern from RoBeasts'
	PlaytimeLogic; the read-only view lives in Shared/Config/PlaytimeConfig).

	Invariants:
		- one ladder per UTC day: `rollover` only moves the day FORWARD (a clock running backwards
		  or junk time never reopens or resets a claimed day); progress made earlier the SAME day
		  is kept across rejoins (it lives in profile.timeRewards);
		- seconds only grow through `accrue`: at most MaxTickCredit per call, never past
		  MaxSecondsPerDay; NaN / negative / infinite credits mint nothing;
		- each gift pays at most once per day: `claim` / `claimAll` mark gifts, and the caller pays
		  in the same non-yielding step;
		- admin tools (`setSeconds`, `reset`) write through the same clamps.

	Example:
		PlaytimeLogic.rollover(profile.timeRewards, today)
		PlaytimeLogic.accrue(profile.timeRewards, 1, today)
		local code = PlaytimeLogic.claim(profile.timeRewards, 3, today) --> "ok" | "locked" | ...
		local opened = PlaytimeLogic.claimAll(profile.timeRewards, today) --> { 1, 2 } (marked)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlaytimeConfig = require(ReplicatedStorage.Shared.Config.PlaytimeConfig)

export type State = { day: number, seconds: number, claimed: { [number]: true }, ladder: number? }
export type ClaimCode = "ok" | "invalid" | "claimed" | "locked"

local PlaytimeLogic = {}

-- True for a finite whole number.
local function whole(value: unknown): boolean
	return type(value) == "number" and value == value and value % 1 == 0 and value ~= math.huge and value ~= -math.huge
end

--[[ Starts a fresh ladder when `today` is later than the stored day. @return true on a new day ]]
function PlaytimeLogic.rollover(state: State, today: number): boolean
	if not whole(today) or today < 0 or today <= state.day then
		return false
	end
	state.day = today
	state.seconds = 0
	table.clear(state.claimed)
	return true
end

--[[
	Credits playtime on `today` (rolls over first). @return seconds actually credited
]]
function PlaytimeLogic.accrue(state: State, credit: number, today: number): number
	PlaytimeLogic.rollover(state, today)
	if state.day ~= today or type(credit) ~= "number" or credit ~= credit or credit <= 0 or credit == math.huge then
		return 0
	end
	local before = state.seconds
	local add = math.min(credit, PlaytimeConfig.MaxTickCredit)
	state.seconds = math.min(before + add, PlaytimeConfig.MaxSecondsPerDay)
	return state.seconds - before
end

--[[ Claims gift `index` on `today` (marks it; the caller pays). ]]
function PlaytimeLogic.claim(state: State, index: number, today: number): ClaimCode
	local gift = if whole(index) then PlaytimeConfig.Gifts[index] else nil
	if gift == nil then
		return "invalid"
	end
	PlaytimeLogic.rollover(state, today)
	if state.day ~= today then
		return "locked"
	end
	if state.claimed[index] then
		return "claimed"
	end
	if state.seconds < gift.minutes * 60 then
		return "locked"
	end
	state.claimed[index] = true
	return "ok"
end

--[[
	CLAIM ALL: marks every gift that is ready on `today` (reached, not claimed) in ladder order.
	The caller pays each returned gift in the same non-yielding step.
	@return the marked gift indices, ascending (empty = nothing was ready)
	Example: PlaytimeLogic.claimAll({ day = 9, seconds = 400, claimed = {} }, 9) --> { 1, 2, 3 }
]]
function PlaytimeLogic.claimAll(state: State, today: number): { number }
	PlaytimeLogic.rollover(state, today)
	local opened: { number } = {}
	if state.day ~= today then
		return opened
	end
	for _, gift in PlaytimeConfig.Gifts do
		if not state.claimed[gift.index] and state.seconds >= gift.minutes * 60 then
			state.claimed[gift.index] = true
			table.insert(opened, gift.index)
		end
	end
	return opened
end

--[[
	Admin / QA: sets today's playtime to `seconds` (clamped to 0..MaxSecondsPerDay; rolls over
	first; claims are kept). @return the stored seconds, or nil for junk input
	Example: PlaytimeLogic.setSeconds(state, PlaytimeConfig.Gifts[4].minutes * 60, today) --> 600
]]
function PlaytimeLogic.setSeconds(state: State, seconds: number, today: number): number?
	if type(seconds) ~= "number" or seconds ~= seconds or seconds == math.huge or seconds == -math.huge then
		return nil
	end
	PlaytimeLogic.rollover(state, today)
	if state.day ~= today then
		return nil
	end
	state.seconds = math.clamp(math.floor(seconds), 0, PlaytimeConfig.MaxSecondsPerDay)
	return state.seconds
end

--[[
	Admin / QA: restarts `today`'s ladder (seconds 0, nothing claimed), even when the stored day
	is today. A clock behind the stored day is refused (never moves the day backwards).
	@return true when reset
]]
function PlaytimeLogic.reset(state: State, today: number): boolean
	if not whole(today) or today < 0 or today < state.day then
		return false
	end
	state.day = today
	state.seconds = 0
	table.clear(state.claimed)
	return true
end

return table.freeze(PlaytimeLogic)
