--!strict
--[[
	ReturnTags — WHY a D-N return was counted (ported from RoBeasts, 2026-10-23 fix list W1.20).

	Purpose:
		AnalyticsService (Server/Analytics/Sessions.markActive) counts "r<N>" (a player active today
		whose first day was exactly N days ago) from two places:
			"load"   the player's profile loaded on a server today (a real join)
			"flush"  the periodic flush saw a player who has been ONLINE ACROSS 00:00 UTC: their
			         session started yesterday, so today's first activity is a carry-over, not a
			         return (these would otherwise inflate D1).
		On top of r<N>, a tagged return also counts one subset key:
			"r<N>:carry"   counted from the flush path only
			"r<N>:notify"  a load whose join came from one of our notifications (Player:GetJoinData
			               LaunchData exactly one of AnalyticsConfig.NotifyLaunchData)
		r<N> itself is unchanged.

	Carry-overs who come back for real later the same UTC day:
		The flush sets analytics.last = today for a carry-over, so a genuine rejoin later that day
		would count nothing. The flush therefore also writes profile.analytics.carry = today. The
		next JOIN (the first profile load of a server session) clears it; when it is still today's,
		it counts "r<N>:carryRejoin" once (and, for D1, the first-day-outcome split and the device
		D1 the flush skipped). So
			D1 excluding carry-overs = r1 - r1:carry + r1:carryRejoin
		and r1:all / r1:<milestone> / devR1:<class> count JOINS only: the flush records the
		carry-over's device as "devR1carry:<class>" instead.

	Connects to: Server/Analytics/Sessions (markActive / flush / session end), AnalyticsMarks (the
	`carry` field), AnalyticsLogic.summarize (the carry-adjusted retention column),
	tests/analytics-recorders.luau.

	Example:
		ReturnTags.tagFor("flush", false) --> "carry"
		ReturnTags.tagFor("load", true)   --> "notify"
		ReturnTags.tagFor("load", false)  --> nil (a plain return)
		ReturnTags.key(1, "carry")        --> "r1:carry"
		ReturnTags.carryMarkerAction(20381, 20381, false) --> "rejoin" (today's marker, a real join)
		ReturnTags.deviceCarryKey("phone") --> "devR1carry:phone"
]]

-- Where markActive was called from: a profile load (a join) or the periodic flush.
export type Via = "load" | "flush"
-- The key a tagged return is also counted in: the carry / notify subsets of r<N>, and a
-- carry-over's genuine rejoin later the same UTC day (carryRejoin, NOT part of r<N>).
export type Tag = "carry" | "notify" | "carryRejoin"
-- What a profile load does with the flush's CarryMarker (carryMarkerAction).
export type MarkerAction = "none" | "rejoin" | "keep" | "clear"

local ReturnTags = {}

-- Every tag, in report order (ReportSections reads them through ReturnTags.key).
ReturnTags.Tags = table.freeze({ "carry", "notify", "carryRejoin" } :: { Tag })

--[[
	The tag of one counted return. The flush path is ALWAYS a carry-over (the player was already
	online when the UTC day changed), even if their join yesterday came from a notification; a load
	is tagged "notify" only when its join came from one of our notifications.
	@param via where markActive ran
	@param fromNotification true when this session's join data matched a notification (only read
	       for loads; callers may pass false for the flush path)
	@return the tag, or nil for a plain return
]]
function ReturnTags.tagFor(via: Via, fromNotification: boolean): Tag?
	if via == "flush" then
		return "carry"
	end
	return if fromNotification then "notify" else nil
end

--[[
	The core counter of a tagged D-N return: "r<N>:<tag>" (carry / notify: a subset of "r<N>";
	carryRejoin: a carry-over's real rejoin, counted on top).
	Example: ReturnTags.key(7, "notify") --> "r7:notify"
]]
function ReturnTags.key(days: number, tag: Tag): string
	return `r{days}:{tag}`
end

--[[
	What a profile load does with the CarryMarker the flush wrote:
		"none"    no marker (0)
		"rejoin"  today's marker and a real join: a carry-over's GENUINE rejoin (count it, remove
		          the marker)
		"keep"    today's marker but the join is the same session moving servers (a reserved /
		          teleport hop, when one exists): no return; keep the marker for a real rejoin
		"clear"   a marker from an earlier day (that day's return, if any, was counted normally)
		          or a malformed value: remove it, count nothing
	@param marked     profile.analytics.carry (0 = no marker; untrusted saved value)
	@param day        today's UTC day number
	@param transitHop true when the join is a server hop of the same session (SellNukes has none
	                  today: callers pass false)
	Example: ReturnTags.carryMarkerAction(20381, 20381, false) --> "rejoin"
	         ReturnTags.carryMarkerAction(20380, 20381, false) --> "clear" (stale)
]]
function ReturnTags.carryMarkerAction(marked: unknown, day: number, transitHop: boolean): MarkerAction
	if marked == nil or marked == 0 then
		return "none"
	end
	if type(marked) == "number" and marked == day then
		return if transitHop then "keep" else "rejoin"
	end
	return "clear"
end

--[[
	The device D1 counter of a carry-over: "devR1carry:<class>" (recorded by the session end on
	the carry-over day instead of devR1:<class>, so device D1 counts joins only).
	Example: ReturnTags.deviceCarryKey("desktop") --> "devR1carry:desktop"
]]
function ReturnTags.deviceCarryKey(device: string): string
	return `devR1carry:{device}`
end

return table.freeze(ReturnTags)
