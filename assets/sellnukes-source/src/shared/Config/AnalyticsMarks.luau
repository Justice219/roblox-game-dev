--!strict
--[[
	AnalyticsMarks — the analytics-owned record saved in every profile (`profile.analytics`) and the
	pure marker rules on it (ported from RoBeasts' AnalyticsMarks; spec §13). No services, no yields.

	Why it exists:
		- Retention: `first` (UTC day of the first session) makes the D-N cohorts, `last` dedupes
		  `dau` across servers (the profile is session-locked, so one server owns the marker).
		- Unique players per UTC day per surface ("uniq:<surface>"): `seenDay` + the `seen` bitmask,
		  ZERO extra DataStore requests (the marker rides the profile's normal autosave).
		- D1 / D7 by first-day outcome: on the first UTC day each milestone sets a bit of `marks`
		  ("cohort:<milestone>" once); the D1 / D7 return counts "r1:<m>" / "r7:<m>" per set bit.
		  Bit 0 ("all") marks a profile created after analytics shipped (the exact base cohort).
		- New-player funnel: `ftue` holds one bit per AnalyticsConfig.Ftue.Steps entry so every step
		  counts once per player even when the funnel spans several sessions.
		- Time-to-X: `play` is the lifetime play seconds as analytics counts them (folded in at every
		  flush / leave) and `runAt` the play seconds when the current rebirth run began, so
		  "minutes into the run" never depends on another system's timer.

	Fields (SAVE DATA; all whole numbers ≥ 0 unless noted; 0 = never):
		first, last           UTC day numbers of the first / latest active day
		payFirst, payLast     UTC days of the first / latest Robux purchase
		robux                 lifetime Robux spent (receipts + pass list prices)
		marks                 first-day milestone bits (bit 0 = tracked, bit i = FirstDay.Milestones[i])
		seenDay, seen         the UTC day of `seen` and its unique-surface bits (bit i-1 = Surfaces[i])
		ftue                  funnel step bits (bit i-1 = Ftue.Steps[i])
		play                  lifetime play seconds (analytics clock)
		runAt                 `play` when the current rebirth run started
		carry                 UTC day of a midnight carry-over marker (ReturnTags)
		sessions              lifetime sessions (profile loads that started a session)
		rbxDay, rbxSec        owner R122: the UTC day of rbxSec and the session seconds already
		                      credited to core "rbx:playSec" that day (0..Algorithm.PlayCapSeconds:
		                      Roblox's 60 min per user per day cap, held across sessions and servers)
		staff                 boolean: stamped staff profile (admin on a live server)
		payDays               { ["<day // 32>"] = 32-bit mask }: sparse payer-day bitmap
		                      (Server/Analytics/ReceiptAccounting.markPayerDay; ≤ 1,563 blocks)
		outbox                table, passed through untouched (MonetizationService receipt outbox)

	Lives in Shared/Config so ProfileLogic (B1) can build its default / reconcile from it without a
	server require. Nothing here is secret and nothing is ever trusted from a client.

	Connections:
		Server/Economy/ProfileLogic   newAnalytics() for defaults, reconcileAnalytics() on every load
		Server/Services/AnalyticsService (+ Server/Analytics/Sessions) — every marker rule below
		Server/Analytics/AnalyticsLogic   milestoneMap / readMilestoneMap for the per-day series
		tests/analytics-logic.luau        every rule below

	Example:
		local data = AnalyticsMarks.newAnalytics()
		AnalyticsMarks.markSeen(data, 20380, "shop")   --> true  (count uniq:shop)
		AnalyticsMarks.markSeen(data, 20380, "shop")   --> false (already counted today)
		AnalyticsMarks.startCohort(data)               --> true  (count cohort:all)
		AnalyticsMarks.markMilestone(data, "area2")    --> true  (count cohort:area2)
		AnalyticsMarks.markFtue(data, "firstPad")      --> true  (count ftue:firstPad)
]]

local AnalyticsConfig = require(script.Parent.AnalyticsConfig)

export type AnalyticsData = {
	first: number,
	last: number,
	payFirst: number,
	payLast: number,
	robux: number,
	marks: number,
	seenDay: number,
	seen: number,
	ftue: number,
	play: number,
	runAt: number,
	carry: number,
	sessions: number,
	rbxDay: number, -- owner R122: UTC day of rbxSec
	rbxSec: number, -- owner R122: seconds credited to rbx:playSec on rbxDay (≤ PlayCapSeconds)
	staff: boolean,
	payDays: { [string]: number },
	outbox: { [any]: any },
}

local AnalyticsMarks = {}

-- Bounds for untrusted stored numbers.
local MAX_DAY = 1e6
local MAX_SECONDS = 1e10 -- ~317 years of play: anything above is corrupt
local MAX_ROBUX = 1e9
local MAX_SESSIONS = 1e9
local MAX_PAY_BLOCK = 1562 -- ReceiptAccounting.MaxDay (50,000) // 32
-- Bit 0 of `marks`: a profile created after milestone tracking shipped (the base cohort).
local TRACKED_BIT = 1

-- Bit of each surface / milestone / funnel step, built once from the (append-only) config lists.
local SURFACE_BIT: { [string]: number } = {}
local SURFACE_MASK = 0
for index, surface in AnalyticsConfig.Unique.Surfaces do
	local bit = bit32.lshift(1, index - 1)
	SURFACE_BIT[surface] = bit
	SURFACE_MASK = bit32.bor(SURFACE_MASK, bit)
end
local MILESTONE_BIT: { [string]: number } = {}
local MILESTONE_MASK = TRACKED_BIT
for index, milestone in AnalyticsConfig.FirstDay.Milestones do
	local bit = bit32.lshift(1, index)
	MILESTONE_BIT[milestone] = bit
	MILESTONE_MASK = bit32.bor(MILESTONE_MASK, bit)
end
local FTUE_BIT: { [string]: number } = {}
local FTUE_INDEX: { [string]: number } = {}
local FTUE_MASK = 0
for index, step in AnalyticsConfig.Ftue.Steps do
	local bit = bit32.lshift(1, index - 1)
	FTUE_BIT[step] = bit
	FTUE_INDEX[step] = index
	FTUE_MASK = bit32.bor(FTUE_MASK, bit)
end
-- Reading-order position of each main-path step (AnalyticsConfig.Ftue.Order; side steps absent).
local FTUE_ORDER: { [string]: number } = {}
for index, step in AnalyticsConfig.Ftue.Order do
	FTUE_ORDER[step] = index
end
-- The masks must fit Luau's 32-bit bit32 maths (and stay clear of the sign bit).
assert(#AnalyticsConfig.Unique.Surfaces <= 30, "AnalyticsConfig.Unique.Surfaces: at most 30 surfaces")
assert(#AnalyticsConfig.FirstDay.Milestones <= 30, "AnalyticsConfig.FirstDay.Milestones: at most 30 milestones")
assert(#AnalyticsConfig.Ftue.Steps <= 30, "AnalyticsConfig.Ftue.Steps: at most 30 steps")

--[[
	A fresh analytics record (a brand-new profile).
	@return AnalyticsData with every field at its "never" value
	Example: AnalyticsMarks.newAnalytics().first --> 0
]]
function AnalyticsMarks.newAnalytics(): AnalyticsData
	return {
		first = 0,
		last = 0,
		payFirst = 0,
		payLast = 0,
		robux = 0,
		marks = 0,
		seenDay = 0,
		seen = 0,
		ftue = 0,
		play = 0,
		runAt = 0,
		carry = 0,
		sessions = 0,
		rbxDay = 0,
		rbxSec = 0,
		staff = false,
		payDays = {},
		outbox = {},
	}
end

-- A whole number in [0, max] from untrusted storage (anything else → 0).
local function whole(value: unknown, max: number): number
	if type(value) ~= "number" or value ~= value or value < 0 or value > max then
		return 0
	end
	return math.floor(value)
end

--[[
	Repairs a stored record: whole numbers only, masks limited to the bits the config defines (a
	bit from a newer build's longer list is dropped rather than misread), `outbox` kept as stored
	when it is a table (its owner, MonetizationService, validates its entries).
	@param raw whatever was stored (nil for a profile older than the field)
	@return a valid AnalyticsData record (a NEW table; the caller stores it back)
	Example: AnalyticsMarks.reconcileAnalytics({ first = 20380, seen = 3.7, staff = "x" })
	         --> { first = 20380, seen = 3, staff = false, ... }
]]
function AnalyticsMarks.reconcileAnalytics(raw: unknown): AnalyticsData
	local data = AnalyticsMarks.newAnalytics()
	if type(raw) ~= "table" then
		return data
	end
	local source = raw :: { [string]: unknown }
	data.first = whole(source.first, MAX_DAY)
	data.last = whole(source.last, MAX_DAY)
	data.payFirst = whole(source.payFirst, MAX_DAY)
	data.payLast = whole(source.payLast, MAX_DAY)
	data.robux = whole(source.robux, MAX_ROBUX)
	data.marks = bit32.band(whole(source.marks, 0x7FFFFFFF), MILESTONE_MASK)
	data.seenDay = whole(source.seenDay, MAX_DAY)
	data.seen = bit32.band(whole(source.seen, 0x7FFFFFFF), SURFACE_MASK)
	data.ftue = bit32.band(whole(source.ftue, 0x7FFFFFFF), FTUE_MASK)
	data.play = whole(source.play, MAX_SECONDS)
	data.runAt = math.min(whole(source.runAt, MAX_SECONDS), data.play)
	data.carry = whole(source.carry, MAX_DAY)
	data.sessions = whole(source.sessions, MAX_SESSIONS)
	-- R122 capped playtime: a credit above today's cap (corrupt / a lowered cap) is clamped, never
	-- discarded, so a reload can never re-open seconds that were already credited.
	data.rbxDay = whole(source.rbxDay, MAX_DAY)
	data.rbxSec = math.min(whole(source.rbxSec, MAX_SECONDS), AnalyticsConfig.Algorithm.PlayCapSeconds)
	data.staff = source.staff == true
	if type(source.payDays) == "table" then
		-- Sparse payer bitmap: "<block>" → 32-bit mask; blocks 0..1562 (days 1..50,000) only.
		local kept = 0
		for block, mask in source.payDays :: { [unknown]: unknown } do
			-- Plain digits only (mirrors ProfileLogic.reconcilePayDays): "-0", "1e2", " 5" are rejected.
			local digits = type(block) == "string" and string.match(block, "^%d%d?%d?%d?$") ~= nil
			local index = if digits then tonumber(block) else nil
			if
				index ~= nil
				and index % 1 == 0
				and index >= 0
				and index <= MAX_PAY_BLOCK
				and tostring(index) == block
				and type(mask) == "number"
				and mask == mask
				and mask >= 0
				and mask <= 0xFFFFFFFF
				and mask % 1 == 0
				and kept < MAX_PAY_BLOCK + 1
			then
				data.payDays[block :: string] = mask
				kept += 1
			end
		end
	end
	if type(source.outbox) == "table" then
		data.outbox = source.outbox :: { [any]: any }
	end
	return data
end

--[[
	Makes `raw` a valid AnalyticsData IN PLACE (fills missing / wrong fields, keeps valid ones), for
	a profile whose loader did not reconcile through this module. Returns it typed.
	@param raw the profile's `analytics` table (must be a table)
	Example: local data = AnalyticsMarks.ensure(profile.analytics)
]]
function AnalyticsMarks.ensure(raw: { [string]: any }): AnalyticsData
	local fixed = AnalyticsMarks.reconcileAnalytics(raw)
	for key, value in fixed :: any do
		-- `outbox` belongs to MonetizationService: kept as-is when it is a table.
		if key ~= "outbox" or type(raw.outbox) ~= "table" then
			raw[key] = value
		end
	end
	return (raw :: any) :: AnalyticsData
end

--[[
	Records that the player used `surface` on UTC day `day`. A new day starts an empty mask.
	@return true exactly once per player, surface and day (the caller counts "uniq:<surface>");
	        false for a repeat or an unknown surface (nothing changes then)
	Example: markSeen(data, 20380, "crate") --> true; again the same day --> false
]]
function AnalyticsMarks.markSeen(data: AnalyticsData, day: number, surface: string): boolean
	local bit = SURFACE_BIT[surface]
	if bit == nil then
		return false
	end
	if data.seenDay ~= day then
		data.seenDay = day
		data.seen = 0
	end
	if bit32.btest(data.seen, bit) then
		return false
	end
	data.seen = bit32.bor(data.seen, bit)
	return true
end

--[[
	Marks a brand-new profile as a tracked first-day cohort member (bit 0).
	@return true when newly set (the caller counts "cohort:all")
]]
function AnalyticsMarks.startCohort(data: AnalyticsData): boolean
	if bit32.btest(data.marks, TRACKED_BIT) then
		return false
	end
	data.marks = bit32.bor(data.marks, TRACKED_BIT)
	return true
end

--[[ True when the profile's first day is tracked (created after analytics shipped). ]]
function AnalyticsMarks.isTracked(data: AnalyticsData): boolean
	return bit32.btest(data.marks, TRACKED_BIT)
end

--[[
	Records a first-day milestone. The CALLER checks it is still the player's first UTC day.
	Untracked profiles never record one (they are not in the base cohort).
	@return true when newly set (the caller counts "cohort:<milestone>")
	Example: markMilestone(data, "hatch") --> true; again --> false; markMilestone(data, "x") --> false
]]
function AnalyticsMarks.markMilestone(data: AnalyticsData, milestone: string): boolean
	local bit = MILESTONE_BIT[milestone]
	if bit == nil or not AnalyticsMarks.isTracked(data) or bit32.btest(data.marks, bit) then
		return false
	end
	data.marks = bit32.bor(data.marks, bit)
	return true
end

--[[
	The milestones a tracked profile reached on its first day, in config order (without "all").
	@return milestone ids (empty for an untracked profile)
]]
function AnalyticsMarks.milestonesOf(data: AnalyticsData): { string }
	local out: { string } = {}
	if not AnalyticsMarks.isTracked(data) then
		return out
	end
	for _, milestone in AnalyticsConfig.FirstDay.Milestones do
		if bit32.btest(data.marks, MILESTONE_BIT[milestone]) then
			table.insert(out, milestone)
		end
	end
	return out
end

--[[
	Records a new-player funnel step for a TRACKED profile (the funnel is the tracked cohort's).
	@return true when newly set (the caller counts "ftue:<step>"); false for a repeat, an unknown
	        step or an untracked profile
	Example: markFtue(data, "firstPad") --> true; again --> false
]]
function AnalyticsMarks.markFtue(data: AnalyticsData, step: string): boolean
	local bit = FTUE_BIT[step]
	if bit == nil or not AnalyticsMarks.isTracked(data) or bit32.btest(data.ftue, bit) then
		return false
	end
	data.ftue = bit32.bor(data.ftue, bit)
	return true
end

--[[ True when the funnel step's bit is set. ]]
function AnalyticsMarks.hasFtue(data: AnalyticsData, step: string): boolean
	local bit = FTUE_BIT[step]
	return bit ~= nil and bit32.btest(data.ftue, bit)
end

--[[ 1-based position of a funnel step in AnalyticsConfig.Ftue.Steps (nil for unknown ids). ]]
function AnalyticsMarks.ftueIndex(step: string): number?
	return FTUE_INDEX[step]
end

--[[
	The furthest funnel step among `reached` (step ids, any order), by the funnel's READING order
	(AnalyticsConfig.Ftue.Order, R78: chronological, so a session that got its plot, finished
	loading and saw the tutorial hint ends at "tutorialSeen", not at "plotReady"); "none" when
	empty. Side steps (hudShown, firstScreenClosed) are never the furthest point of a session.
	Used for "ftueLeft:<step>" / "ftueDev:<class>:<step>" (where first sessions end).
	Example: furthestStep({ joined = true, firstPad = true, loadingDone = true }) --> "firstPad"
]]
function AnalyticsMarks.furthestStep(reached: { [string]: boolean }): string
	local best, bestIndex = "none", 0
	for step in reached do
		local index = FTUE_ORDER[step]
		if index ~= nil and index > bestIndex then
			best, bestIndex = step, index
		end
	end
	return best
end

--[[ core "uniq:<surface>". ]]
function AnalyticsMarks.uniqueKey(surface: string): string
	return `uniq:{surface}`
end

--[[ core "cohort:<milestone>" (milestone or the base id "all"). ]]
function AnalyticsMarks.cohortKey(milestone: string): string
	return `cohort:{milestone}`
end

--[[ core "r<days>:<milestone>" (D-N return by first-day milestone). Example: returnKeyAt(7, "area2") --> "r7:area2" ]]
function AnalyticsMarks.returnKeyAt(days: number, milestone: string): string
	return `r{days}:{milestone}`
end

-- Every id a per-day milestone map may hold: the base id, then the milestones.
local MAP_IDS: { string } = { AnalyticsConfig.FirstDay.BaseId }
for _, milestone in AnalyticsConfig.FirstDay.Milestones do
	table.insert(MAP_IDS, milestone)
end
table.freeze(MAP_IDS)
AnalyticsMarks.MapIds = MAP_IDS

--[[
	One day's "<prefix><id>" core counters as id → count (nil when there are none), for the
	per-day D1 / D7 series (AnalyticsLogic.seriesOf). Only known ids are read, so it is bounded.
	Example: milestoneMap({ ["cohort:all"] = 9, ["cohort:hatch"] = 2 }, "cohort:") --> { all = 9, hatch = 2 }
]]
function AnalyticsMarks.milestoneMap(core: { [string]: number }, prefix: string): { [string]: number }?
	local out: { [string]: number }? = nil
	for _, id in MAP_IDS do
		local value = core[prefix .. id]
		if value ~= nil and value > 0 then
			local map: { [string]: number } = out or {}
			map[id] = value
			out = map
		end
	end
	return out
end

--[[
	A stored milestone map (compact month day series; untrusted shape) → id → count, bounded to the
	known ids, finite positive numbers only. nil when nothing valid is left.
]]
function AnalyticsMarks.readMilestoneMap(raw: unknown): { [string]: number }?
	if type(raw) ~= "table" then
		return nil
	end
	local source = raw :: { [unknown]: unknown }
	local out: { [string]: number }? = nil
	for _, id in MAP_IDS do
		local value = source[id]
		if type(value) == "number" and value == value and value > 0 and value < math.huge then
			local map: { [string]: number } = out or {}
			map[id] = value
			out = map
		end
	end
	return out
end

return table.freeze(AnalyticsMarks)
