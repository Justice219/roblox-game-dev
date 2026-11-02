--!strict
--[[
	AnalyticsLogic — the pure rules of the analytics system (no DataStores, no Instances).
	Ported from RoBeasts' AnalyticsLogic (storage half verbatim in behaviour), summary rewritten for
	the SellNukes tycoon loop.

	Purpose:
		Everything that can be tested without a live server lives here:
			- UTC day / month math and the DataStore key names,
			- metric key building (sanitized, length-capped, config ids only),
			- bounded counter maps (adding, merging deltas, folding overflow into "_other",
			  clamping sums that would overflow the double range),
			- the stored value shapes (family-day, compact day, compact month) and their defensive
			  readers (stored data is untrusted: wrong types are dropped, never thrown on),
			- range planning (which days / months to read, which cohort days retention needs),
			- the client report validators (OffersSeen impressions, FunnelStep screen opens),
			- bucket labels shared by recorders and report sections,
			- the summary: headline numbers, retention, ranked tables (sections from
			  ReportSections), the daily series and the trimmed raw counters (AnalyticsReport.Summary).

	Connects to:
		AnalyticsService / Recorder (record deltas), AnalyticsStore (stored shapes, compaction,
		range loading), AnalyticsConfig (limits, families), AnalyticsReport (the Summary type the
		client parses), ReportSections (the per-family report tables).

	Example:
		local pending: AnalyticsLogic.Pending = {}
		AnalyticsLogic.record(pending, AnalyticsLogic.dayNumber(os.time()), "tycoon", "pad:a1_workbench", 1)
		local stored = AnalyticsLogic.mergeStored(nil, pending[today].tycoon)
		-- stored = { v = 1, c = { ["pad:a1_workbench"] = 1 } }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnalyticsConfig = require(ReplicatedStorage.Shared.Config.AnalyticsConfig)
local AnalyticsMarks = require(ReplicatedStorage.Shared.Config.AnalyticsMarks)
local AnalyticsReport = require(ReplicatedStorage.Shared.Analytics.AnalyticsReport)

export type Family = AnalyticsConfig.Family
export type Counters = { [string]: number }
-- family → counters (one day, a month or a whole range).
export type FamilyCounters = { [string]: Counters }
-- day number → family → counters (this server's unflushed deltas).
export type Pending = { [number]: FamilyCounters }

--[[
	Per-day core numbers kept in month compactions (daily series and retention cohorts).
		devNew / devR1     that day's new players and D1 joins per device class (nil when none)
		msCohort / msR1 / msR7   first-day milestone cohort counts and D1 / D7 returns per milestone
]]
export type DaySeries = {
	dau: number,
	new: number,
	sessions: number,
	robux: number,
	payers: number,
	pads: number,
	devNew: Counters?,
	devR1: Counters?,
	msCohort: Counters?,
	msR1: Counters?,
	msR7: Counters?,
}

-- What a range load produces (AnalyticsStore.loadRange) and summarize consumes.
export type Loaded = {
	totals: FamilyCounters, -- every family summed over the range
	daily: { [number]: DaySeries }, -- day number → series (range days only)
	cohortNew: { [number]: number }, -- day number → new players (cohort sizes)
	partial: boolean,
	source: string,
}

-- Resolves a display name: (kind, id, extra id) → label. kind ∈ "pad", "producer", "area",
-- "product", "pass", "reason", "egg", "pet", "crate", "boost", "screen", "offer", "feature".
export type LabelOf = (kind: string, id: string, sub: string?) -> string

local AnalyticsLogic = {}

local SECONDS_PER_DAY = 86400
local OTHER_KEY = "_other"
local MAX_VALUE = AnalyticsConfig.MaxCounterValue

--------------------------------------------------------------------------------------------------
-- Days, months and keys
--------------------------------------------------------------------------------------------------

--[[ UTC day number (days since 1970-01-01) of a unix time. ]]
function AnalyticsLogic.dayNumber(unixTime: number): number
	return math.floor(unixTime / SECONDS_PER_DAY)
end

--[[ "2026-10-30" for a day number (UTC). ]]
function AnalyticsLogic.dayString(day: number): string
	return os.date("!%Y-%m-%d", day * SECONDS_PER_DAY) :: string
end

--[[ "2026-10" for a day number (UTC). ]]
function AnalyticsLogic.monthOf(day: number): string
	return os.date("!%Y-%m", day * SECONDS_PER_DAY) :: string
end

--[[ First and last day numbers of the month containing `day`. ]]
function AnalyticsLogic.monthBounds(day: number): (number, number)
	local date = os.date("!*t", day * SECONDS_PER_DAY) :: { [string]: number }
	local first = day - (date.day - 1)
	local last = first + 27
	-- Walk forward to the month's end (at most 3 steps; months are 28..31 days).
	local month = AnalyticsLogic.monthOf(first)
	while AnalyticsLogic.monthOf(last + 1) == month do
		last += 1
	end
	return first, last
end

--[[ DataStore key of one family's counters for one day and write shard. ]]
function AnalyticsLogic.familyKey(day: number, family: string, shard: number): string
	return `d:{AnalyticsLogic.dayString(day)}:{family}:{shard}`
end

--[[ DataStore key of a compacted (final) day. ]]
function AnalyticsLogic.compactDayKey(day: number): string
	return `c:{AnalyticsLogic.dayString(day)}`
end

--[[ DataStore key of a compacted (final) month. ]]
function AnalyticsLogic.compactMonthKey(month: string): string
	return `m:{month}`
end

AnalyticsLogic.MetaKey = "meta"

--[[ This server's write shard (stable per JobId; 0 in Studio where JobId is ""). ]]
function AnalyticsLogic.shardFor(jobId: string, shardCount: number): number
	if shardCount <= 1 then
		return 0
	end
	local hash = 0
	for index = 1, #jobId do
		hash = (hash * 31 + string.byte(jobId, index)) % 2147483647
	end
	return hash % shardCount
end

--[[
	One sanitized key part: letters, digits, "_" and "-" only, at most MaxKeyPart characters.
	Ids come from config tables, so this only guards against surprises (never user text).
	Example: AnalyticsLogic.part("a1 workbench!") --> "a1_workbench_"
]]
function AnalyticsLogic.part(value: string | number): string
	local text = string.gsub(tostring(value), "[^%w_%-]", "_")
	text = string.sub(text, 1, AnalyticsConfig.MaxKeyPart)
	return if text == "" then "_" else text
end

--[[ Joins parts into a metric key: key("pad", "a1_workbench") → "pad:a1_workbench". ]]
function AnalyticsLogic.key(...: string | number): string
	local parts = table.pack(...)
	local out: { string } = {}
	for index = 1, parts.n do
		table.insert(out, AnalyticsLogic.part(parts[index]))
	end
	return string.sub(table.concat(out, ":"), 1, AnalyticsConfig.MaxKeyLength)
end

--------------------------------------------------------------------------------------------------
-- Allowlists and buckets (shared by recorders, client validators and report sections)
--------------------------------------------------------------------------------------------------

--[[
	Folds an untrusted id into an allowlist: the id itself when it is a string listed in `list`,
	otherwise `fallback` (normally "other"). Metric keys built from the result never contain free text.
	Example: AnalyticsLogic.pick(AnalyticsConfig.DeviceClasses, "phone", "unknown") --> "phone"
]]
function AnalyticsLogic.pick(list: { string }, raw: unknown, fallback: string): string
	if type(raw) == "string" and table.find(list, raw) ~= nil then
		return raw
	end
	return fallback
end

--[[
	An integer in min..max, or nil (non-numbers, NaN, ±inf, fractions and out-of-range values).
	Values that become part of a metric key are rejected rather than clamped (a clamp would
	silently merge a bug into a real row).
	Example: AnalyticsLogic.integerIn(3, 1, 7) --> 3; AnalyticsLogic.integerIn(2.5, 1, 7) --> nil
]]
function AnalyticsLogic.integerIn(raw: unknown, min: number, max: number): number?
	if type(raw) ~= "number" or raw ~= raw or raw % 1 ~= 0 or raw < min or raw > max then
		return nil
	end
	return raw
end

--[[
	Labels of an ascending bound list: { 5, 10 } with unit "m" → { "<5m", "5-10m", "10m+" }.
	Used for every histogram key so recorders, KeySpec and the report agree on the spelling.
]]
function AnalyticsLogic.bucketLabels(bounds: { number }, unit: string): { string }
	local labels: { string } = {}
	local lower = 0
	for _, upper in bounds do
		table.insert(labels, if lower == 0 then `<{upper}{unit}` else `{lower}-{upper}{unit}`)
		lower = upper
	end
	table.insert(labels, `{lower}{unit}+`)
	return labels
end

--[[
	The label of `value` within ascending `bounds` (value < bound → that bucket; the last bucket is
	open-ended). Same spelling as bucketLabels.
	Example: AnalyticsLogic.bucketOf(7, { 5, 10 }, "m") --> "5-10m"
]]
function AnalyticsLogic.bucketOf(value: number, bounds: { number }, unit: string): string
	local lower = 0
	for _, upper in bounds do
		if value < upper then
			return if lower == 0 then `<{upper}{unit}` else `{lower}-{upper}{unit}`
		end
		lower = upper
	end
	return `{lower}{unit}+`
end

--[[
	Count buckets labelled by their lowest count: bounds { 1, 2, 3, 5 } → "0", "1", "2", "3-4",
	"5+" (value 0 → "0"). Used for counts such as rebirths / pets owned / friends.
	Example: AnalyticsLogic.countBucket(4, { 1, 2, 3, 5 }) --> "3-4"
]]
function AnalyticsLogic.countBucket(value: number, bounds: { number }): string
	local n = math.max(0, math.floor(value))
	local lower = 0
	for _, upper in bounds do
		if n < upper then
			if upper - lower <= 1 then
				return tostring(lower)
			end
			return `{lower}-{upper - 1}`
		end
		lower = upper
	end
	return `{lower}+`
end

--[[ Every label countBucket can produce for `bounds`, in order. ]]
function AnalyticsLogic.countBucketLabels(bounds: { number }): { string }
	local labels: { string } = {}
	local lower = 0
	for _, upper in bounds do
		table.insert(labels, if upper - lower <= 1 then tostring(lower) else `{lower}-{upper - 1}`)
		lower = upper
	end
	table.insert(labels, `{lower}+`)
	return labels
end

--[[ Session length bucket label: "<2m", "2-5m", ..., "120m+". ]]
function AnalyticsLogic.sessionBucket(seconds: number): string
	return AnalyticsLogic.bucketOf(seconds / 60, AnalyticsConfig.SessionBuckets, "m")
end

--[[ Prompt dwell bucket: "lt2" / "2to10" / "gt10" (AnalyticsConfig.DwellBounds). ]]
function AnalyticsLogic.dwellBucket(seconds: number): string
	local bounds = AnalyticsConfig.DwellBounds
	local labels = AnalyticsConfig.DwellLabels
	for index, upper in bounds do
		if seconds < upper then
			return labels[index]
		end
	end
	return labels[#labels]
end

--------------------------------------------------------------------------------------------------
-- Roblox-aligned signals (owner R122; AnalyticsConfig.Algorithm, docs/analytics.md "Roblox signals")
--------------------------------------------------------------------------------------------------

-- Roblox's session buckets: a first-play bounce ("lt60" / "60to180") or a qualified session ("long").
export type RobloxBucket = "lt60" | "60to180" | "long"

--[[
	The Roblox bucket of a session length: "lt60" when it ended within Algorithm.BounceSeconds,
	"60to180" within Algorithm.QualifiedSeconds (inclusive: Roblox's "61-180 s"), else "long"
	(qualified; the bounceDev keys call it "stay"). NaN / negative = "lt60": a session we cannot time
	is never counted as qualified.
	@param seconds the session length (os.clock based)
	@return RobloxBucket
	Example: robloxBucket(45) --> "lt60"; robloxBucket(120) --> "60to180"; robloxBucket(181) --> "long"
]]
function AnalyticsLogic.robloxBucket(seconds: number): RobloxBucket
	local config = AnalyticsConfig.Algorithm
	if seconds ~= seconds or seconds < config.BounceSeconds then
		return "lt60"
	elseif seconds <= config.QualifiedSeconds then
		return "60to180"
	end
	return "long"
end

-- One day's share of a capped playtime credit (AnalyticsLogic.creditPlay).
export type PlayCredit = { day: number, seconds: number }

--[[
	Splits `seconds` whole play seconds that ENDED at unix time `now` at UTC midnights and credits
	each day's part against the player's daily cap (Roblox credits at most Algorithm.PlayCapSeconds
	of playtime per user per day). (capDay, capSec) = the profile's rbxDay / rbxSec: the one day whose
	credited seconds the profile remembers, so the cap holds across sessions and servers (the
	profile is session-locked). A part on a LATER day starts that day at 0; a part on an OLDER day
	than capDay is dropped (its cap is unknown: only a clock stepping backwards gets there), so a
	player can never be credited past the cap.
	Pure: the caller stores the returned (day, sec) back and counts each credit on its own day
	(Recorder.countOn), so the seconds before midnight land on the day they were played.
	@param capDay   profile.analytics.rbxDay (0 = never credited)
	@param capSec   profile.analytics.rbxSec
	@param now      unix seconds at the end of the span (os.time())
	@param seconds  whole seconds played since the last credit (clamped to 0..MaxCreditGapSeconds,
	                so the per-day loop runs at most three times)
	@return credits (oldest day first, parts > 0 only), the new rbxDay, the new rbxSec
	Example: creditPlay(0, 0, D * 86400 + 30, 90)
	         --> { { day = D - 1, seconds = 60 }, { day = D, seconds = 30 } }, D, 30
	         creditPlay(D, 3590, D * 86400 + 5000, 60) --> { { day = D, seconds = 10 } }, D, 3600
]]
function AnalyticsLogic.creditPlay(
	capDay: number,
	capSec: number,
	now: number,
	seconds: number
): ({ PlayCredit }, number, number)
	local config = AnalyticsConfig.Algorithm
	local cap = config.PlayCapSeconds
	local credits: { PlayCredit } = {}
	local day = if capDay == capDay then capDay else 0
	local sec = if capSec == capSec then math.clamp(capSec, 0, cap) else 0
	local total = if seconds == seconds then math.floor(math.clamp(seconds, 0, config.MaxCreditGapSeconds)) else 0
	if total <= 0 or now ~= now or math.abs(now) == math.huge then
		return credits, day, sec
	end
	local finish = math.floor(now)
	local cursor = finish - total
	while cursor < finish do
		local spanDay = AnalyticsLogic.dayNumber(cursor)
		local boundary = math.min(finish, (spanDay + 1) * SECONDS_PER_DAY)
		local part = boundary - cursor
		cursor = boundary
		if spanDay > day then
			day, sec = spanDay, 0
		end
		if spanDay == day then
			local grant = math.min(part, cap - sec)
			if grant > 0 then
				sec += grant
				table.insert(credits, { day = spanDay, seconds = grant })
			end
		end
	end
	return credits, day, sec
end

--------------------------------------------------------------------------------------------------
-- Client report validators (untrusted input: every argument is `unknown`)
--------------------------------------------------------------------------------------------------

-- One session's offer impression + BUY press state (one per analytics session).
export type OffersSeenState = {
	opens: number, -- counted "offers:open:*" this session (<= OffersSeen.MaxOpens)
	cards: { [string]: number }, -- counted "offers:card:<id>" per id (each <= opens)
	clicks: number, -- R137 counted offer BUY presses this session (<= OfferClicks.MaxPerSession)
	-- R137 os.clock() of the last counted press per offer id (keys are catalogue ids only, so the
	-- map is bounded by the catalogue size).
	clickAt: { [string]: number },
}

--[[ A fresh, empty OffersSeenState. ]]
function AnalyticsLogic.newOffersSeen(): OffersSeenState
	return { opens = 0, cards = {}, clicks = 0, clickAt = {} }
end

--[[
	True when `rawSource` is a prompt source whose surface renders offer cards (owner R137,
	AnalyticsConfig.OfferClicks.Sources: "shop", "offer", "welcomeBack"). Anything else (pads, the
	wheel, attack, lucky, non-strings, ...) is not an offer surface.
	Example: AnalyticsLogic.isOfferClickSource("offer") --> true; isOfferClickSource("pad") --> false
]]
function AnalyticsLogic.isOfferClickSource(rawSource: unknown): boolean
	return type(rawSource) == "string" and table.find(AnalyticsConfig.OfferClicks.Sources, rawSource) ~= nil
end

--[[
	Validates one offer BUY press (owner R137; the funnel's "click" step) against the session's
	`state`. The caller is the SERVER (Revenue.promptRequested, fed by MonetizationService's
	PromptRequested after its own rate limit + key check), but every argument is still treated as
	untrusted: it came from a client remote.
		rawKey     must be a non-empty string of ≤ ClientSourceMaxLength characters that `isOffer`
		           accepts (a MonetizationConfig product / pass key)
		rawSource  must be an offer surface (isOfferClickSource); any other source is not an offer
		           press at all → (nil, nil), never a refusal
		now        os.clock() of the press; a second press on the SAME id within
		           OfferClicks.RepeatSeconds of the last counted one is the same press → (nil, nil)
	@return (offerId, nil) when the press counts; (nil, reason) when it is refused — reason from
	        AnalyticsConfig.ClientRefusalReasons: "malformed" (wrong type / length), "unknown" (not
	        an offer id), "cap" (OfferClicks.MaxPerSession reached); (nil, nil) when it is simply not
	        a (new) offer press. Mutates only `state.clicks` / `state.clickAt`. Measurement only.
	Example:
		local state = AnalyticsLogic.newOffersSeen()
		AnalyticsLogic.offerClick(state, "StarterPack", "shop", 10, isOffer)   --> "StarterPack", nil
		AnalyticsLogic.offerClick(state, "StarterPack", "shop", 10.2, isOffer) --> nil, nil (double tap)
		AnalyticsLogic.offerClick(state, "Bogus", "shop", 12, isOffer)         --> nil, "unknown"
]]
function AnalyticsLogic.offerClick(
	state: OffersSeenState,
	rawKey: unknown,
	rawSource: unknown,
	now: number,
	isOffer: (id: string) -> boolean
): (string?, string?)
	local config = AnalyticsConfig.OfferClicks
	if not AnalyticsLogic.isOfferClickSource(rawSource) then
		return nil, nil
	end
	if type(rawKey) ~= "string" or #rawKey == 0 or #rawKey > AnalyticsConfig.ClientSourceMaxLength then
		return nil, "malformed"
	end
	if not isOffer(rawKey) then
		return nil, "unknown"
	end
	local last = state.clickAt[rawKey]
	if last ~= nil and now - last >= 0 and now - last < config.RepeatSeconds then
		return nil, nil
	end
	if state.clicks >= config.MaxPerSession then
		return nil, "cap"
	end
	state.clicks += 1
	state.clickAt[rawKey] = now
	return rawKey, nil
end

--[[
	Validates one OffersSeen report against the session's `state` and returns the "revenue" keys
	to count (+1 each).
		rawSource  picked from OffersSeen.Sources (non-strings / oversized / unknown → "other")
		rawCards   an array; only its first MaxCards entries are read (never a pairs walk over a
		           client table); each must be a short string `isCard` accepts (a server-defined
		           offer id); duplicates in one report count once; an id counts only while its
		           session count is below the session's counted opens (one impression per visit)
		rawNew     true = a new visit (counts "offers:open:<source>" while opens < MaxOpens);
		           false = more cards seen on the SAME visit; anything else = invalid
	Mutates only `state`. Measurement only: nothing is granted or shown from it.
	Example: offersSeen(AnalyticsLogic.newOffersSeen(), "starburst", { "vip", "vip", "x" }, true, isOffer)
	         --> { "offers:open:starburst", "offers:card:vip" }
]]
function AnalyticsLogic.offersSeen(
	state: OffersSeenState,
	rawSource: unknown,
	rawCards: unknown,
	rawNew: unknown,
	isCard: (id: string) -> boolean
): { string }
	local config = AnalyticsConfig.OffersSeen
	local keys: { string } = {}
	if rawNew == true then
		if state.opens >= config.MaxOpens then
			return keys
		end
		local source = "other"
		if type(rawSource) == "string" and #rawSource <= AnalyticsConfig.ClientSourceMaxLength then
			source = AnalyticsLogic.pick(config.Sources, rawSource, "other")
		end
		state.opens += 1
		table.insert(keys, `offers:open:{source}`)
	elseif rawNew ~= false then
		return keys
	end
	if type(rawCards) ~= "table" then
		return keys
	end
	local list = rawCards :: { [number]: unknown }
	local seenNow: { [string]: boolean } = {}
	for index = 1, config.MaxCards do
		local raw = list[index]
		if raw == nil then
			break
		end
		if
			type(raw) == "string"
			and #raw <= AnalyticsConfig.ClientSourceMaxLength
			and not seenNow[raw]
			and isCard(raw)
		then
			seenNow[raw] = true
			local counted = state.cards[raw] or 0
			if counted < state.opens then
				state.cards[raw] = counted + 1
				table.insert(keys, `offers:card:{raw}`)
			end
		end
	end
	return keys
end

--[[
	Validates a FunnelStep "open" report (screen opened) and returns the retention keys to count:
	"open:<screen>" and "openFrom:<screen>:<source>". Screens must be listed exactly in
	AnalyticsConfig.ClientFunnel.Screens (anything else → nil, nothing counted); a missing / unknown
	source → "other".
	Example: AnalyticsLogic.screenOpen("Shop", "hud") --> { "open:Shop", "openFrom:Shop:hud" }
	         AnalyticsLogic.screenOpen("<x>", "hud")  --> nil
]]
function AnalyticsLogic.screenOpen(rawScreen: unknown, rawSource: unknown): { string }?
	local config = AnalyticsConfig.ClientFunnel
	if type(rawScreen) ~= "string" or #rawScreen > AnalyticsConfig.ClientSourceMaxLength then
		return nil
	end
	if table.find(config.Screens, rawScreen) == nil then
		return nil
	end
	local source = "other"
	if type(rawSource) == "string" and #rawSource <= AnalyticsConfig.ClientSourceMaxLength then
		source = AnalyticsLogic.pick(config.Sources, rawSource, "other")
	end
	return { `open:{rawScreen}`, `openFrom:{rawScreen}:{source}` }
end

--------------------------------------------------------------------------------------------------
-- Counters
--------------------------------------------------------------------------------------------------

local function finite(value: unknown): number?
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	return value
end

-- Number of keys in a map (counters are small; called only when a NEW key is inserted).
local function count(counters: Counters): number
	local n = 0
	for _ in counters do
		n += 1
	end
	return n
end

--[[
	Adds `amount` to counters[key]. A new key beyond MaxKeysPerFamily folds into "_other" so a bug
	can never grow a DataStore value without bound. Non-finite amounts are ignored; a sum that
	would leave ±MaxCounterValue is clamped (late-game cash sums) instead of becoming inf.
]]
function AnalyticsLogic.add(counters: Counters, key: string, amount: number)
	if finite(amount) == nil or amount == 0 then
		return
	end
	local current = counters[key]
	if current == nil and key ~= OTHER_KEY and count(counters) >= AnalyticsConfig.MaxKeysPerFamily then
		key = OTHER_KEY
		current = counters[key]
	end
	counters[key] = math.clamp((current or 0) + amount, -MAX_VALUE, MAX_VALUE)
end

--[[ Adds every entry of `from` into `into` (bounded like `add`). ]]
function AnalyticsLogic.mergeInto(into: Counters, from: Counters)
	for key, value in from do
		AnalyticsLogic.add(into, key, value)
	end
end

--[[ Merges family maps: into[family] += from[family]. ]]
function AnalyticsLogic.mergeFamilies(into: FamilyCounters, from: FamilyCounters)
	for family, counters in from do
		local target = into[family]
		if target == nil then
			target = {}
			into[family] = target
		end
		AnalyticsLogic.mergeInto(target, counters)
	end
end

--[[ Records one delta into a pending map (day → family → key). ]]
function AnalyticsLogic.record(pending: Pending, day: number, family: string, key: string, amount: number)
	local families = pending[day]
	if families == nil then
		families = {}
		pending[day] = families
	end
	local counters = families[family]
	if counters == nil then
		counters = {}
		families[family] = counters
	end
	AnalyticsLogic.add(counters, key, amount)
end

--------------------------------------------------------------------------------------------------
-- Stored values (DataStore data is untrusted: anything malformed is dropped, never thrown on)
--------------------------------------------------------------------------------------------------

--[[ Reads a { [string] = number } map from stored data (non-numbers and bad keys dropped). ]]
function AnalyticsLogic.readCounters(raw: unknown): Counters
	local counters: Counters = {}
	if type(raw) ~= "table" then
		return counters
	end
	local n = 0
	for key, value in raw :: { [unknown]: unknown } do
		local number = finite(value)
		if type(key) == "string" and number ~= nil and #key <= AnalyticsConfig.MaxKeyLength then
			n += 1
			if n > AnalyticsConfig.MaxKeysPerFamily then
				counters[OTHER_KEY] = math.clamp((counters[OTHER_KEY] or 0) + number, -MAX_VALUE, MAX_VALUE)
			else
				counters[key] = math.clamp((counters[key] or 0) + number, -MAX_VALUE, MAX_VALUE)
			end
		end
	end
	return counters
end

--[[ Counters of a family-day value ({ v = 1, c = counters }). ]]
function AnalyticsLogic.readStored(raw: unknown): Counters
	if type(raw) ~= "table" then
		return {}
	end
	return AnalyticsLogic.readCounters((raw :: { [string]: unknown }).c)
end

--[[
	The UpdateAsync transform: old stored value + delta → new stored value. Pure (no upvalue
	mutation), so a retried transform never double-counts.
]]
function AnalyticsLogic.mergeStored(old: unknown, delta: Counters): { [string]: any }
	local counters = AnalyticsLogic.readStored(old)
	AnalyticsLogic.mergeInto(counters, delta)
	return { v = 1, c = counters }
end

--[[ A compact day value from its family counters. ]]
function AnalyticsLogic.compactDay(day: number, families: FamilyCounters): { [string]: any }
	local copy: { [string]: Counters } = {}
	for _, family in AnalyticsConfig.Families do
		copy[family] = families[family] or {}
	end
	return { v = 1, day = AnalyticsLogic.dayString(day), f = copy }
end

--[[ Family counters of a compact day / month value, or nil if it is not one. ]]
function AnalyticsLogic.readFamilies(raw: unknown): FamilyCounters?
	if type(raw) ~= "table" then
		return nil
	end
	local value = raw :: { [string]: unknown }
	if type(value.f) ~= "table" then
		return nil
	end
	local families: FamilyCounters = {}
	for _, family in AnalyticsConfig.Families do
		families[family] = AnalyticsLogic.readCounters((value.f :: { [string]: unknown })[family])
	end
	return families
end

-- The `<prefix><class>` core counters of one day as class → count (nil when there are none).
local function byDevice(core: Counters, prefix: string): Counters?
	local out: Counters? = nil
	for _, class in AnalyticsConfig.DeviceClasses do
		local value = core[prefix .. class]
		if value ~= nil and value > 0 then
			local map: Counters = out or {}
			map[class] = value
			out = map
		end
	end
	local unknown = core[prefix .. "unknown"]
	if unknown ~= nil and unknown > 0 then
		local map: Counters = out or {}
		map.unknown = unknown
		out = map
	end
	return out
end

-- Sum of the counters whose key starts with `prefix`.
local function sumPrefix(counters: Counters, prefix: string): number
	local total = 0
	for key, value in counters do
		if string.sub(key, 1, #prefix) == prefix then
			total += value
		end
	end
	return total
end
AnalyticsLogic.sumPrefix = sumPrefix

--[[ The per-day series of one day's family counters. ]]
function AnalyticsLogic.seriesOf(families: FamilyCounters): DaySeries
	local core: Counters = families.core or {}
	local revenue: Counters = families.revenue or {}
	local tycoon: Counters = families.tycoon or {}
	return {
		dau = core.dau or 0,
		new = core.new or 0,
		sessions = core.sessions or 0,
		robux = revenue.robux or 0,
		payers = core.payers or 0,
		pads = sumPrefix(tycoon, "padKind:"),
		devNew = byDevice(core, "devNew:"),
		devR1 = byDevice(core, "devR1:"),
		msCohort = AnalyticsMarks.milestoneMap(core, "cohort:"),
		msR1 = AnalyticsMarks.milestoneMap(core, "r1:"),
		msR7 = AnalyticsMarks.milestoneMap(core, "r7:"),
	}
end

-- A stored class → count map (compact month day series), bounded to the known classes.
local function readDeviceMap(raw: unknown): Counters?
	if type(raw) ~= "table" then
		return nil
	end
	local source = raw :: { [unknown]: unknown }
	local out: Counters? = nil
	for _, class in AnalyticsConfig.DeviceClasses do
		local value = finite(source[class])
		if value ~= nil and value > 0 then
			local map: Counters = out or {}
			map[class] = value
			out = map
		end
	end
	local unknown = finite(source.unknown)
	if unknown ~= nil and unknown > 0 then
		local map: Counters = out or {}
		map.unknown = unknown
		out = map
	end
	return out
end

--[[ A compact month value: merged family counters + per-day series (day number as text → series). ]]
function AnalyticsLogic.compactMonth(
	month: string,
	families: FamilyCounters,
	days: { [number]: DaySeries }
): { [string]: any }
	local series: { [string]: DaySeries } = {}
	for day, values in days do
		series[tostring(day)] = values
	end
	local copy: { [string]: Counters } = {}
	for _, family in AnalyticsConfig.Families do
		copy[family] = families[family] or {}
	end
	return { v = 1, month = month, f = copy, days = series }
end

--[[ Per-day series of a compact month value (day number → series). ]]
function AnalyticsLogic.readMonthDays(raw: unknown): { [number]: DaySeries }
	local out: { [number]: DaySeries } = {}
	if type(raw) ~= "table" or type((raw :: { [string]: unknown }).days) ~= "table" then
		return out
	end
	for dayText, values in (raw :: { [string]: any }).days :: { [unknown]: unknown } do
		local day = if type(dayText) == "string" then tonumber(dayText) else nil
		if day ~= nil and day == math.floor(day) and day > 0 and type(values) == "table" then
			local entry = values :: { [string]: unknown }
			out[day] = {
				dau = finite(entry.dau) or 0,
				new = finite(entry.new) or 0,
				sessions = finite(entry.sessions) or 0,
				robux = finite(entry.robux) or 0,
				payers = finite(entry.payers) or 0,
				pads = finite(entry.pads) or 0,
				devNew = readDeviceMap(entry.devNew),
				devR1 = readDeviceMap(entry.devR1),
				msCohort = AnalyticsMarks.readMilestoneMap(entry.msCohort),
				msR1 = AnalyticsMarks.readMilestoneMap(entry.msR1),
				msR7 = AnalyticsMarks.readMilestoneMap(entry.msR7),
			}
		end
	end
	return out
end

--[[ The analytics start day stored in the meta key (nil if unset / malformed). ]]
function AnalyticsLogic.readMeta(raw: unknown): number?
	if type(raw) ~= "table" then
		return nil
	end
	local first = finite((raw :: { [string]: unknown }).firstDay)
	return if first ~= nil and first > 0 then math.floor(first) else nil
end

--------------------------------------------------------------------------------------------------
-- Range planning
--------------------------------------------------------------------------------------------------

-- A whole month read as one compact key: its "yyyy-mm" and first day number.
export type MonthRef = { month: string, day: number }

export type Plan = {
	from: number,
	to: number,
	days: { number }, -- range days read individually (compact or family keys)
	months: { MonthRef }, -- compacted months read whole ("all" only)
	cohortDays: { number }, -- extra days whose new-player count retention needs
}

--[[
	Which keys a range needs. `firstDay` = the analytics start day (nil = unknown, then "all"
	starts today). Days before firstDay hold no data and are never read.
		today/7d/30d: every range day individually (old days are compacted: one key each).
		all:          every month that ended more than CompactAfterDays ago as one month key,
		              the remaining days individually.
	cohortDays: for each N in RetentionDays AND every N in 1..Algorithm.PlayDayMax (owner R122: the
	"algorithm" scorecard's play days per user D2-7 / D8-28 need every N), the days D - N for range
	days D (cohort sizes), minus days already covered by the range itself. The extra N add at most
	PlayDayMax compact day keys to a short range (immutable, cached by AnalyticsStore).
]]
function AnalyticsLogic.plan(range: string, today: number, firstDay: number?): Plan
	local start = firstDay or today
	local from: number
	if range == "all" then
		from = start
	else
		from = today - ((AnalyticsConfig.RangeDays[range] or 1) - 1)
	end
	local to = today
	local days: { number } = {}
	local months: { MonthRef } = {}
	local covered: { [number]: boolean } = {}
	local day = math.max(from, start)
	while day <= to do
		if range == "all" then
			local first, last = AnalyticsLogic.monthBounds(day)
			if first <= day and last < today - AnalyticsConfig.CompactAfterDays then
				table.insert(months, { month = AnalyticsLogic.monthOf(day), day = first })
				for covering = day, last do
					covered[covering] = true
				end
				day = last + 1
				continue
			end
		end
		table.insert(days, day)
		covered[day] = true
		day += 1
	end
	local cohortSet: { [number]: boolean } = {}
	local function addOffset(n: number)
		for d = from, to do
			local cohort = d - n
			if cohort >= start and not covered[cohort] then
				cohortSet[cohort] = true
			end
		end
	end
	for _, n in AnalyticsConfig.RetentionDays do
		addOffset(n)
	end
	for n = 1, AnalyticsConfig.Algorithm.PlayDayMax do
		addOffset(n)
	end
	local cohortDays: { number } = {}
	for cohort in cohortSet do
		table.insert(cohortDays, cohort)
	end
	table.sort(cohortDays)
	return { from = from, to = to, days = days, months = months, cohortDays = cohortDays }
end

--------------------------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------------------------

-- A ranked-table entry (ReportSections builds these; makeTable sorts, trims and shares them).
-- Owner R122 scorecard rows may also carry `tone` (AnalyticsReport.Tones) and their own bar
-- `share` (0..1, e.g. attainment of a target) instead of value / largest.
export type Entry = {
	id: string,
	label: string,
	value: number,
	display: string?,
	extra: string?,
	tone: string?,
	share: number?,
}

--[[
	Ranked table builder: entries sorted by value (or in the given order), trimmed to TableRows (or
	`maxRows` for fixed-shape funnels whose every row matters), with bar shares relative to the
	largest value. Rows past the limit are counted in `more` (the report prints "+N more rows").
]]
function AnalyticsLogic.makeTable(
	id: string,
	title: string,
	note: string,
	entries: { Entry },
	order: "value" | "given",
	maxRows: number?
): AnalyticsReport.Table
	if order == "value" then
		table.sort(entries, function(a: Entry, b: Entry): boolean
			if a.value ~= b.value then
				return a.value > b.value
			end
			return a.id < b.id
		end)
	end
	local largest, total = 0, 0
	for _, entry in entries do
		largest = math.max(largest, entry.value)
		total += entry.value
	end
	local rows: { AnalyticsReport.Row } = {}
	local limit = maxRows or AnalyticsConfig.TableRows
	for index, entry in entries do
		if index > limit then
			break
		end
		local share = entry.share
		table.insert(rows, {
			id = entry.id,
			label = entry.label,
			value = entry.value,
			display = entry.display or AnalyticsReport.formatInteger(entry.value),
			extra = entry.extra or "",
			share = if share ~= nil and share == share
				then math.clamp(share, 0, 1)
				elseif largest > 0 then math.clamp(entry.value / largest, 0, 1)
				else 0,
			tone = entry.tone,
		})
	end
	return { id = id, title = title, note = note, total = total, rows = rows, more = math.max(0, #entries - limit) }
end

--[[ Percent text of a / b ("" when b is 0). ]]
function AnalyticsLogic.pctOf(a: number, b: number): string
	return if b > 0 then AnalyticsReport.formatPercent(a / b) else ""
end

--[[
	Median of a bucketed histogram, as the midpoint of the bucket holding the 50th percentile.
	`labels` / `mids` are parallel (label → representative value); returns -1 when empty.
	Example: medianOf({ ["<2m"] = 1, ["2-5m"] = 3 }, "len:", { "<2m", "2-5m" }, { 1, 3.5 }) --> 3.5
]]
function AnalyticsLogic.medianOf(counters: Counters, prefix: string, labels: { string }, mids: { number }): number
	local total = 0
	for _, label in labels do
		total += counters[prefix .. label] or 0
	end
	if total <= 0 then
		return -1
	end
	local half = total / 2
	local running = 0
	for index, label in labels do
		running += counters[prefix .. label] or 0
		if running >= half then
			return mids[index]
		end
	end
	return mids[#mids]
end

-- Session-length bucket labels and their midpoints in minutes (median session headline).
local SESSION_LABELS = AnalyticsLogic.bucketLabels(AnalyticsConfig.SessionBuckets, "m")
local SESSION_MIDS: { number } = {}
do
	local lower = 0
	for _, upper in AnalyticsConfig.SessionBuckets do
		table.insert(SESSION_MIDS, (lower + upper) / 2)
		lower = upper
	end
	table.insert(SESSION_MIDS, lower * 1.5)
end
AnalyticsLogic.SessionLabels = SESSION_LABELS

-- The summary's context for ReportSections (helpers + range facts).
--	cohortNew   cohort sizes of the plan's cohortDays (days before the range; Loaded.cohortNew)
--	readsKnown  every read succeeded from the DataStore (not partial, not this server's memory)
--	            (both optional: a hand-made test context without them makes cohort ratios n/a)
export type SectionContext = {
	totals: FamilyCounters,
	labelOf: LabelOf,
	from: number,
	to: number,
	today: number,
	days: number,
	daily: { [number]: DaySeries },
	cohortNew: { [number]: number }?,
	readsKnown: boolean?,
}

-- What returnCohort reads: the range facts plus the cohort sizes (a SectionContext is one).
export type CohortSource = {
	from: number,
	to: number,
	today: number,
	daily: { [number]: DaySeries },
	cohortNew: { [number]: number }?,
	readsKnown: boolean?,
}

--[[
	The return-date cohort of D-N over a range: Σ over the range's return days d (≤ today) of the
	new players of day d - N (range days from the daily series, earlier days from cohortNew), and
	whether every size AND every return day was actually read. Unknown sizes stay unknown — a
	missing read never becomes a zero-sized cohort (that would inflate retention). Shared by the
	Retention table / D-N headlines (summarize) and the R122 "algorithm" play-days rows.
	@param source the range facts (SectionContext or summarize's own)
	@param n      days after the first day (1 = D1)
	@return cohort size, known
	Example: returnCohort(ctx, 1) --> 10, true  (yesterday's 10 new players for today's r1)
]]
function AnalyticsLogic.returnCohort(source: CohortSource, n: number): (number, boolean)
	local cohort = 0
	local known = source.readsKnown == true
	local cohortNew: { [number]: number } = source.cohortNew or {}
	for day = source.from, source.to do
		if day <= source.today then
			local cohortDay = source.daily[day - n]
			local cohortSize = if cohortDay ~= nil then cohortDay.new else cohortNew[day - n]
			if cohortSize == nil or source.daily[day] == nil then
				known = false
			end
			cohort += cohortSize or 0
		else
			known = false
		end
	end
	return cohort, known
end

--[[
	Builds the Summary for one range. `sections` = ReportSections.build (injected so this module
	never requires the large sections module; tests may pass their own). Pure: no yields.
	@param range   "today" | "7d" | "30d" | "all"
	@param plan    AnalyticsLogic.plan output for the range
	@param today   today's UTC day number
	@param loaded  AnalyticsStore.loadRange output
	@param labelOf display-name resolver
	@param now     unix time (generatedAt)
	@param sections (ctx) -> { AnalyticsReport.Table } — the per-family report sections
	@return AnalyticsReport.Summary
]]
function AnalyticsLogic.summarize(
	range: string,
	plan: Plan,
	today: number,
	loaded: Loaded,
	labelOf: LabelOf,
	now: number,
	sections: ((ctx: SectionContext) -> { AnalyticsReport.Table })?
): AnalyticsReport.Summary
	local totals = loaded.totals
	local core: Counters = totals.core or {}
	local revenue: Counters = totals.revenue or {}
	local tycoon: Counters = totals.tycoon or {}

	-- Days actually covered (the "all" range starts at the analytics start day).
	local from = plan.from
	local days = math.max(1, plan.to - from + 1)

	-- Daily series, oldest first; DAU stats from it.
	local daily: { AnalyticsReport.DayRow } = {}
	local peak = 0
	for day = from, plan.to do
		local series = loaded.daily[day]
		if series ~= nil then
			peak = math.max(peak, series.dau)
			table.insert(daily, {
				day = AnalyticsLogic.dayString(day),
				dau = series.dau,
				new = series.new,
				sessions = series.sessions,
				robux = series.robux,
				payers = series.payers,
				pads = series.pads,
			})
		end
	end

	local playerDays = core.dau or 0
	local sessionsEnded = core.sessions or 0
	local robux = revenue.robux or 0
	local payers = core.payers or 0
	local joined = core["ftue:joined"] or 0

	-- Return-date cohorts must be available for every selected return day. Missing reads cannot
	-- become zero-sized cohorts (which would inflate retention from surviving data).
	local readsKnown = not loaded.partial and loaded.source ~= "memory"
	local cohortSource: CohortSource = {
		from = from,
		to = plan.to,
		today = today,
		daily = loaded.daily,
		cohortNew = loaded.cohortNew,
		readsKnown = readsKnown,
	}
	local function retentionCounts(n: number): (number, number, boolean)
		local cohort, known = AnalyticsLogic.returnCohort(cohortSource, n)
		return core[`r{n}`] or 0, cohort, known
	end

	-- Unavailable or inconsistent cohorts stay n/a (-1) in headline cards and the detail table.
	local function retention(n: number): number
		local returns, cohort, known = retentionCounts(n)
		return if known and cohort > 0 and returns <= cohort then returns / cohort else -1
	end

	local headline: { [string]: number } = {
		dau = playerDays / days,
		peakDau = peak,
		playerDays = playerDays,
		sessions = sessionsEnded,
		avgSessionMinutes = if sessionsEnded > 0 then (core.sessionSeconds or 0) / sessionsEnded / 60 else 0,
		medianSession = AnalyticsLogic.medianOf(core, "len:", SESSION_LABELS, SESSION_MIDS),
		newPlayers = core.new or 0,
		d1 = retention(1),
		d3 = retention(3),
		d7 = retention(7),
		d14 = retention(14),
		d30 = retention(30),
		robux = robux,
		purchases = revenue.purchases or 0,
		payers = payers,
		newPayers = core.newPayers or 0,
		arpdau = if playerDays > 0 then robux / playerDays else 0,
		arppu = if payers > 0 then robux / payers else 0,
		conversion = if playerDays > 0 then payers / playerDays else 0,
		tutorialCompletion = if joined > 0 then (core["ftue:manager"] or 0) / joined else -1,
		area2Rate = if joined > 0 then (core["ftue:area2"] or 0) / joined else -1,
		padsBought = sumPrefix(tycoon, "padKind:"),
		rebirths = tycoon.rebirth or 0,
	}

	local tables: { AnalyticsReport.Table } = {}

	-- Retention detail (cohort denominators + midnight carry adjustment), first: every read starts here.
	do
		local rows: { Entry } = {}
		for _, n in AnalyticsConfig.RetentionDays do
			local returns, cohort, known = retentionCounts(n)
			local carry = math.min(returns, core[`r{n}:carry`] or 0)
			local rejoined = math.min(carry, core[`r{n}:carryRejoin`] or 0)
			local adjustedReturns = math.max(0, returns - carry + rejoined)
			local adjusted = if known
					and cohort > 0
					and returns <= cohort
				then AnalyticsLogic.pctOf(adjustedReturns, cohort)
				else "n/a"
			table.insert(rows, {
				id = `d{n}`,
				label = `D{n} return-date retention`,
				value = returns,
				display = AnalyticsReport.formatHeadline(`d{n}`, retention(n)),
				extra = `{AnalyticsReport.formatInteger(returns)} / {AnalyticsReport.formatInteger(cohort)} cohort players`
					.. ` · cohort {AnalyticsLogic.dayString(from - n)}–{AnalyticsLogic.dayString(plan.to - n)}`
					.. ` · excluding midnight carry-overs {adjusted}`
					.. ` · via notification {AnalyticsReport.formatInteger(core[`r{n}:notify`] or 0)}`
					.. (if not known then " · cohort/return reads unavailable" else ""),
			})
		end
		table.insert(
			tables,
			AnalyticsLogic.makeTable(
				"retention",
				"Retention (cohort denominators)",
				`Return dates {AnalyticsLogic.dayString(from)}–{AnalyticsLogic.dayString(plan.to)}; `
					.. (if plan.to >= today then "PROVISIONAL (includes today)" else "closed days")
					.. ". Missing reads give n/a.",
				rows,
				"given"
			)
		)
	end

	if sections ~= nil then
		local ctx: SectionContext = {
			totals = totals,
			labelOf = labelOf,
			from = from,
			to = plan.to,
			today = today,
			days = days,
			daily = loaded.daily,
			cohortNew = loaded.cohortNew,
			readsKnown = readsKnown,
		}
		for _, section in sections(ctx) do
			if #tables >= AnalyticsConfig.ReportMaxTables - 1 then
				break
			end
			table.insert(tables, section)
		end
	end

	-- Raw counters: pinned first, then a greedy fill across families (one key budget).
	local selection = AnalyticsReport.selectCounters(totals, AnalyticsConfig.ReportSummaryKeys, function(): number
		return 1
	end)

	local window: AnalyticsReport.WindowMetadata = {
		exporterVersion = AnalyticsReport.ExporterVersion,
		windowComplete = plan.to < today,
		openDayElapsedSeconds = if from <= today and plan.to >= today
			then math.clamp(math.floor(now - today * SECONDS_PER_DAY), 0, SECONDS_PER_DAY)
			else nil,
	}
	table.insert(
		tables,
		AnalyticsLogic.makeTable(
			"reportContext",
			"Report coverage and units",
			"Missing keys can mean no eligible events, older servers or unavailable data — not proof of zero.",
			{
				{
					id = "window",
					label = "Observation window",
					value = 0,
					display = AnalyticsReport.windowStatus(window),
				},
				{
					id = "reads",
					label = "Storage / scope",
					value = 0,
					display = AnalyticsReport.readStatus(loaded.partial, loaded.source),
				},
				{
					id = "omitted",
					label = "Counters omitted from summary",
					value = selection.omitted,
					extra = "COPY RAW DATA pages the uncapped totals.",
				},
				{
					id = "units",
					label = "Measurement units",
					value = 0,
					display = "Sessions / players / player-days",
					extra = "Multi-day uniques are player-days. Cash sums are clamped at 1e300.",
				},
				{
					id = "authority",
					label = "Observation authority",
					value = 0,
					display = "Server outcomes + validated client claims",
					extra = "Screen opens, offer impressions, device and client performance are client claims; everything else is server recorded.",
				},
			},
			"given"
		)
	)

	local note = ""
	if loaded.source == "memory" then
		note = "DataStore unavailable here: showing only this server's unsaved counts."
	elseif plan.to >= today then
		note = "Includes today: totals and return-day retention are provisional (servers flush every minute)."
	end

	return {
		range = range,
		from = AnalyticsLogic.dayString(from),
		to = AnalyticsLogic.dayString(plan.to),
		days = days,
		generatedAt = now,
		source = loaded.source,
		partial = loaded.partial,
		exporterVersion = window.exporterVersion,
		windowComplete = window.windowComplete,
		openDayElapsedSeconds = window.openDayElapsedSeconds,
		note = note,
		headline = headline,
		tables = tables,
		daily = daily,
		families = selection.kept,
		truncated = selection.omitted,
	}
end

return table.freeze(AnalyticsLogic)
