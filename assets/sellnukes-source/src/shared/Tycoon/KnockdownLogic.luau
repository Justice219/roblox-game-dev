--!strict
--[[
	KnockdownLogic — the pure rules of the temporary area knockdown (owner R50; tunables in
	Shared/Config/KnockdownConfig, applied by Server/Tycoon/Knockdown).

	No services, no Instances, no requires: plain tables + numbers (server time in seconds), so
	tests/knockdown-logic.luau runs it unchanged in Lune and the server loop can call it per tick
	without allocating (except when something actually changes).

	State per player (never saved; cleared on leave / rebirth / plot reset):
		areas        [areaIndex] → AreaState while that area is down
		downCount    number of areas currently down
		immuneUntil  server time the post-knockdown immunity ends (0 = none); set when the plot's
		             LAST down area comes back up, so tapping to rebuild never shortens protection
		volley*      the current volley (first knockdown while nothing was down): its start time,
		             attacker and how many areas it knocked — the barrage-spill exception

	Rules (Rules table, normally built from KnockdownConfig by `rulesFromConfig`):
		* check: an area already down → "immune"; another area down → allowed only as a volley spill
		  (same attacker, within VolleyGraceSeconds of the volley start, fewer than VolleyMaxAreas
		  areas so far), else "immune"; nothing down but immuneUntil > now → "immune".
		* apply: starts a volley when nothing is down, records the area (deadline = now + duration).
		* tap: deadline − TapSeconds, never earlier than appliedAt + MinDownSeconds nor before now;
		  refused (false) when it can no longer move.
		* expire: every area whose deadline passed comes up; the last one starts the immunity.

	Example:
		local state = KnockdownLogic.newState()
		local rules = KnockdownLogic.rulesFromConfig(KnockdownConfig)
		if KnockdownLogic.check(state, 3, now, attackerId, rules) then
			KnockdownLogic.apply(state, 3, now, 45, attackerId, "normal")
		end
		KnockdownLogic.tap(state, 3, now + 10, rules) --> true, now + 44
]]

export type AreaState = {
	area: number,
	appliedAt: number, -- server time the knockdown started
	untilTime: number, -- server time it rebuilds (moves earlier with taps)
	duration: number, -- seconds requested at apply (for analytics)
	attackerUserId: number, -- 0 = none (admin / rival / test)
	source: string,
	taps: number, -- accepted rebuild taps
}

export type PlotState = {
	areas: { [number]: AreaState },
	downCount: number,
	immuneUntil: number,
	volleyStart: number,
	volleyAttacker: number,
	volleyAreas: number,
}

export type Rules = {
	immunitySeconds: number,
	volleyGraceSeconds: number,
	volleyMaxAreas: number,
	tapSeconds: number,
	minDownSeconds: number,
}

export type Reason = "immune"

local KnockdownLogic = {}

-- A finite number, else the fallback (NaN / ±inf / non-numbers never reach the rules).
local function finite(value: unknown, fallback: number): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return fallback
	end
	return value
end

--[[ A fresh per-player state (nothing down, no immunity). ]]
function KnockdownLogic.newState(): PlotState
	return {
		areas = {},
		downCount = 0,
		immuneUntil = 0,
		volleyStart = 0,
		volleyAttacker = 0,
		volleyAreas = 0,
	}
end

--[[
	The Rules table from KnockdownConfig-shaped values (+ an optional immunity override).
	@param config any — KnockdownConfig (ImmunitySeconds, VolleyGraceSeconds, VolleyMaxAreas,
	                    TapSeconds, MinDownSeconds)
	@param immunityOverride number? — admin override of ImmunitySeconds
	Example: KnockdownLogic.rulesFromConfig(KnockdownConfig).immunitySeconds --> 180
]]
function KnockdownLogic.rulesFromConfig(config: any, immunityOverride: number?): Rules
	return {
		immunitySeconds = math.max(finite(immunityOverride or config.ImmunitySeconds, 0), 0),
		volleyGraceSeconds = math.max(finite(config.VolleyGraceSeconds, 0), 0),
		volleyMaxAreas = math.max(math.floor(finite(config.VolleyMaxAreas, 1)), 1),
		tapSeconds = math.max(finite(config.TapSeconds, 0), 0),
		minDownSeconds = math.max(finite(config.MinDownSeconds, 0), 0),
	}
end

--[[
	Clamps a requested duration (seconds) into [minSeconds, maxSeconds]; invalid → minSeconds.
	Example: KnockdownLogic.clampDuration(500, 5, 90) --> 90
]]
function KnockdownLogic.clampDuration(seconds: unknown, minSeconds: number, maxSeconds: number): number
	return math.clamp(finite(seconds, minSeconds), minSeconds, math.max(maxSeconds, minSeconds))
end

--[[
	Is `area` down at `now`?
	@return boolean, number? — down, and its rebuild time when down
]]
function KnockdownLogic.isDown(state: PlotState, area: number, now: number): (boolean, number?)
	local entry = state.areas[area]
	if entry ~= nil and entry.untilTime > now then
		return true, entry.untilTime
	end
	return false, nil
end

--[[ True when any area of the plot is down at `now`. ]]
function KnockdownLogic.anyDown(state: PlotState, now: number): boolean
	for _, entry in state.areas do
		if entry.untilTime > now then
			return true
		end
	end
	return false
end

--[[
	True when the plot cannot be knocked down at `now` (an area is down, or the post-knockdown
	immunity runs). The volley-spill exception is NOT considered here (see `check`).
]]
function KnockdownLogic.isImmune(state: PlotState, now: number): boolean
	return state.immuneUntil > now or KnockdownLogic.anyDown(state, now)
end

--[[
	May `area` be knocked down now by `attackerUserId` (0 = no attacker)?
	@return boolean, Reason? — false + "immune" when blocked by the anti-grief rules
	Example: with area 3 down by attacker 7 one second ago, check(state, 4, now, 7, rules) --> true
]]
function KnockdownLogic.check(
	state: PlotState,
	area: number,
	now: number,
	attackerUserId: number,
	rules: Rules
): (boolean, Reason?)
	if KnockdownLogic.isDown(state, area, now) then
		return false, "immune"
	end
	if KnockdownLogic.anyDown(state, now) then
		local spill = attackerUserId ~= 0
			and attackerUserId == state.volleyAttacker
			and now - state.volleyStart <= rules.volleyGraceSeconds
			and state.volleyAreas < rules.volleyMaxAreas
		if spill then
			return true, nil
		end
		return false, "immune"
	end
	if state.immuneUntil > now then
		return false, "immune"
	end
	return true, nil
end

--[[
	Knocks `area` down (callers ran `check`, or bypass it on purpose: admin tests). Replaces an
	entry of the same area (admin re-knock). Starts a new volley when nothing else is down.
	@param duration number — seconds (already clamped by the caller)
	@return AreaState — the new entry
]]
function KnockdownLogic.apply(
	state: PlotState,
	area: number,
	now: number,
	duration: number,
	attackerUserId: number,
	source: string
): AreaState
	local wasDown = KnockdownLogic.anyDown(state, now)
	if not wasDown then
		state.volleyStart = now
		state.volleyAttacker = attackerUserId
		state.volleyAreas = 0
	end
	local previous = state.areas[area]
	local entry: AreaState = {
		area = area,
		appliedAt = now,
		untilTime = now + math.max(duration, 0),
		duration = math.max(duration, 0),
		attackerUserId = attackerUserId,
		source = source,
		taps = 0,
	}
	state.areas[area] = entry
	if previous == nil then
		state.downCount += 1
	end
	state.volleyAreas += 1
	return entry
end

--[[
	One "TAP TO REBUILD!" press on `area`.
	@return boolean, number — accepted (the deadline moved), and the (new) rebuild time (0 when
	        the area is not down)
	Example: appliedAt 100, until 145, tapSeconds 1, minDown 6 → tap at 110 → true, 144
]]
function KnockdownLogic.tap(state: PlotState, area: number, now: number, rules: Rules): (boolean, number)
	local entry = state.areas[area]
	if entry == nil or entry.untilTime <= now then
		return false, 0
	end
	local floor = math.max(entry.appliedAt + rules.minDownSeconds, now)
	local target = math.max(entry.untilTime - rules.tapSeconds, floor)
	if target >= entry.untilTime then
		return false, entry.untilTime
	end
	entry.untilTime = target
	entry.taps += 1
	return true, target
end

-- Removes one area entry; when it was the last one down, the immunity starts and the volley ends.
local function release(state: PlotState, area: number, now: number, rules: Rules): AreaState?
	local entry = state.areas[area]
	if entry == nil then
		return nil
	end
	state.areas[area] = nil
	state.downCount = math.max(state.downCount - 1, 0)
	if state.downCount == 0 then
		state.immuneUntil = math.max(state.immuneUntil, now + rules.immunitySeconds)
		state.volleyStart = 0
		state.volleyAttacker = 0
		state.volleyAreas = 0
	end
	return entry
end

--[[
	Brings up every area whose deadline passed. Appends the ended entries to `out` (cleared first)
	so the server loop reuses one array.
	@return { AreaState } — `out`
]]
function KnockdownLogic.expire(state: PlotState, now: number, rules: Rules, out: { AreaState }): { AreaState }
	table.clear(out)
	if state.downCount == 0 then
		return out
	end
	for area, entry in state.areas do
		if entry.untilTime <= now then
			table.insert(out, entry)
			-- Deadline order is irrelevant for immunity: it starts when the LAST one comes up.
			release(state, area, now, rules)
		end
	end
	return out
end

--[[
	Ends one area now (admin force-rebuild). Immunity follows the normal rule.
	@return AreaState? — the ended entry (nil when it was not down)
]]
function KnockdownLogic.finish(state: PlotState, area: number, now: number, rules: Rules): AreaState?
	return release(state, area, now, rules)
end

--[[ Clears the immunity (admin). ]]
function KnockdownLogic.clearImmunity(state: PlotState)
	state.immuneUntil = 0
end

--[[ Seconds left until `untilTime` (never negative). ]]
function KnockdownLogic.remaining(untilTime: number, now: number): number
	return math.max(untilTime - now, 0)
end

--[[
	"m:ss" for a countdown (rounded up, so the label reads 0:01 until the very end).
	Example: KnockdownLogic.formatClock(45) --> "0:45"; formatClock(61.2) --> "1:02"
]]
function KnockdownLogic.formatClock(seconds: number): string
	local whole = math.max(math.ceil(finite(seconds, 0)), 0)
	return string.format("%d:%02d", whole // 60, whole % 60)
end

--[[
	Pauses / resumes a producer cycle around a knockdown (TycoonService). While paused nothing is
	paid; on resume the cycle origin moves so the bar continues from where it stopped.
	@param cycleStart number — the cycle origin (server time)
	@param cycleTime number — seconds per cycle
	@param pausedAt number — server time the pause began
	@param now number — server time of the resume
	@return number — the new cycle origin
	Example: start 100, cycle 10, paused at 104, resumed at 150 → 146 (4 s of progress kept)
]]
function KnockdownLogic.resumeStart(cycleStart: number, cycleTime: number, pausedAt: number, now: number): number
	-- Progress held at the pause, bounded to one cycle (a cycle that finished between the last
	-- payout tick and the pause completes right after the resume). A cycle (re)started during
	-- the pause (e.g. a Manager hired meanwhile) has no progress yet.
	local held = math.clamp(pausedAt - cycleStart, 0, math.max(cycleTime, 0))
	return now - held
end

return KnockdownLogic
