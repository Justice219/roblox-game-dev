--!strict
--[[
	AnalyticsReport — the analytics summary shape, its defensive parser and the COPY FOR AI text
	(ported from RoBeasts; SellNukes loop context, headlines and daily series).

	Purpose:
		The server (AnalyticsService → AnalyticsLogic.summarize) builds a `Summary` for one date
		range and sends it to an admin (remote AnalyticsReport). The client parses it with
		`AnalyticsReport.parse` (every field type-checked and bounded, so a malformed payload can
		never break the panel), renders it (the admin panel's Analytics tab) and turns it into a
		self-describing text report with `AnalyticsReport.toText` (markdown summary + one JSON
		block holding every metric) for the COPY FOR AI dialog.
		Shared so the server tests can check the report contains every section.

	Summary fields:
		range, from, to (UTC "yyyy-mm-dd"), days, generatedAt (unix), source ("datastore" |
		"memory"), partial (some keys could not be read), note,
		optional exporterVersion / windowComplete / openDayElapsedSeconds (unknown on older payloads),
		headline  { [name] = number }  (AnalyticsConfig.HeadlineDefinitions; -1 = n/a)
		tables    { Table }            ranked rows with bar shares (0..1); `more` = rows cut
		daily     { DayRow }           per-day core numbers, oldest first
		families  { [family] = { [metricKey] = number } } raw counters (pinned + greedy if trimmed)
		truncated number of raw counters left out to respect the size cap
		rawId     the server's RAW DATA snapshot of this summary (0 = none; COPY RAW DATA)

	Report truncation fix (2026-10-23 analytics fix list W1.12; docs/analytics.md "COPY FOR AI"):
		- PINNED keys (AnalyticsConfig.ReportPinnedPrefixes / ReportPinnedContains: r1..r30, dau,
		  new, sessions, returning, ops:, cohort:, devR1, promptClosed, refusals, failures, ...)
		  survive every trim (`selectCounters`), whatever their value;
		- the rest of a budget is filled greedily ACROSS families (rank 1 of every family, then
		  rank 2, ...), so a family with few keys never wastes its share;
		- toText lists only the key patterns present in the JSON it prints (`presentPatterns`):
		  the pinned keys' patterns always (a floor held back before the counter trim, at most
		  ReportDefinitionsFloorChars), then the most common ones in the space the counters
		  leave, and points at docs/analytics.md / the RAW pages for the rest;
		- every ranked table that was cut prints a short "+N more rows" line (explained once
		  in the intro: both RAW pages and the JSON have explicit omission counts);
		- COPY RAW DATA: `rawIndex` splits the UNCAPPED totals into pages, `rawPage` builds one
		  page (server), `parseRawPage` validates it and `rawText` writes it (client).

	Example:
		local summary = AnalyticsReport.parse(payload.summary)
		if summary ~= nil then
			local text = AnalyticsReport.toText(summary)  -- ≤ AnalyticsConfig.ReportMaxChars
		end
		-- RAW DATA (server): pages over the uncapped totals of one summary
		local index = AnalyticsReport.rawIndex(totals, AnalyticsConfig.Raw.PageChars, AnalyticsConfig.Raw.MaxPages)
		local page = AnalyticsReport.rawPage(index, totals, 1, meta)  -- → remote AnalyticsRawPage
		-- RAW DATA (client)
		local parsed = AnalyticsReport.parseRawPage(payload.page)
		local pageText = if parsed ~= nil then AnalyticsReport.rawText(parsed) else ""
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnalyticsConfig = require(ReplicatedStorage.Shared.Config.AnalyticsConfig)

export type Row = {
	id: string, -- metric id (config id, e.g. "a1_workbench")
	label: string, -- display name
	value: number, -- the ranked number
	display: string, -- formatted value ("1,250 R$", "42", "3:10")
	extra: string, -- secondary details ("12 purchases · 30% of prompts")
	share: number, -- 0..1 bar length (value / largest value in the table)
	-- owner R122: a scorecard verdict (one of AnalyticsReport.Tones; nil = a plain ranked row). The
	-- panel colours the value and shows ToneLabels[tone]; COPY FOR AI prints the label too.
	tone: string?,
}

export type Table = {
	id: string,
	title: string,
	note: string, -- one-line explanation under the title
	total: number, -- sum of every row's value (before trimming to TableRows)
	rows: { Row },
	-- [W1.12] rows left out of `rows` (trimmed to TableRows by AnalyticsLogic's makeTable, or
	-- past the parser's MAX_ROWS); the report prints "+N more rows" for them (nil / 0 = none).
	more: number?,
}

export type DayRow = {
	day: string,
	dau: number,
	new: number,
	sessions: number,
	robux: number,
	payers: number,
	pads: number, -- tycoon pad purchases that day
}

-- Exporter schema revision and observation window; neither identifies the builds that emitted events.
-- Optional fields preserve old server snapshots without claiming their window is complete.
export type WindowMetadata = {
	exporterVersion: string?,
	windowComplete: boolean?,
	openDayElapsedSeconds: number?,
}

export type Summary = WindowMetadata & {
	range: string,
	from: string,
	to: string,
	days: number,
	generatedAt: number,
	source: string,
	partial: boolean,
	note: string,
	headline: { [string]: number },
	tables: { Table },
	daily: { DayRow },
	families: { [string]: { [string]: number } },
	truncated: number,
	-- Bounded client parsing reports omitted sections/daily rows separately from counters.
	sectionsOmitted: number?,
	daysOmitted: number?,
	-- [W1.12] id of the server's RAW DATA snapshot of this summary's uncapped totals
	-- (Analytics/AnalyticsRaw.remember; 0 = none, e.g. a summary built outside summaryAsync).
	rawId: number?,
}

-- [W1.12] Counters by family ({ [family] = { [metricKey] = number } }).
export type FamilyCounters = { [string]: { [string]: number } }

--[[
	[W1.12] What `selectCounters` keeps under a budget.
		kept      the chosen counters by family (every family of AnalyticsConfig.Families present)
		order     the chosen keys in priority order (pinned first, then the greedy fill); the
		          tail is what a caller drops first when an exact size check overshoots
		pinned    how many entries at the head of `order` are pinned (never dropped)
		count     keys kept; omitted = keys left out; spent = budget units used
]]
export type Pick = { family: string, key: string }
export type Selection = {
	kept: FamilyCounters,
	order: { Pick },
	pinned: number,
	count: number,
	omitted: number,
	spent: number,
}

--[[
	[W1.12] Where every counter of a RAW DATA snapshot sits: slots in output order (families in
	report order, keys A→Z), `starts[p]` = first slot of page p (pages end where the next one
	starts). `omitted` = counters past MaxPages (0 unless a range is enormous).
]]
export type RawIndex = {
	slotFamily: { string },
	slotKey: { string },
	starts: { number },
	total: number,
	omitted: number,
}

-- [W1.12] Snapshot facts copied onto every RAW page (from its summary).
export type RawMeta = WindowMetadata & {
	partial: boolean?,
	rawId: number,
	range: string,
	from: string,
	to: string,
	generatedAt: number,
	source: string,
}

-- [W1.12] One RAW DATA page (remote AnalyticsRawPage payload `page`; parseRawPage validates it).
export type RawPage = WindowMetadata & {
	partial: boolean?,
	rawId: number,
	page: number, -- 1-based
	pages: number,
	total: number, -- counters in the whole snapshot
	omitted: number, -- counters past MaxPages (said on the last page)
	keys: number, -- counters on this page
	-- Client only (parseRawPage): entries of this page it could not keep (malformed, or past
	-- Raw.MaxKeysPerPage); rawText says so. Always 0 from the server.
	dropped: number,
	range: string,
	from: string,
	to: string,
	generatedAt: number,
	source: string,
	counters: FamilyCounters,
}

local AnalyticsReport = {}
-- Export format revision only (bump with any change to the summary / text shape).
-- "1" (2026-10-30): first SellNukes exporter.
-- "2" (2026-11-01, owner R122): rows may carry a scorecard `tone` (printed beside the value), the
--     "Roblox algorithm scorecard" table and analyst question 9.
AnalyticsReport.ExporterVersion = "2"

--[[
	Owner R122 scorecard verdicts a row may carry (the "algorithm" table, Server/Analytics/
	ReportSections): good = meets AnalyticsConfig.Algorithm.Targets[row].good, watch = between watch
	and good, bad = worse than watch, partial = the signal's counters do not cover the whole range
	(pre-R122 servers: an undercount), na = a missing denominator / window not complete (never 0),
	info = not a target row (e.g. PTR lives in Creator Hub). Unknown tones are dropped by the parser.
]]
AnalyticsReport.Tones = table.freeze({ "good", "watch", "bad", "partial", "na", "info" })
AnalyticsReport.ToneLabels = table.freeze({
	good = "ON TARGET",
	watch = "WATCH",
	bad = "BELOW TARGET",
	partial = "PARTIAL DATA",
	na = "N/A",
	info = "INFO",
} :: { [string]: string })
local TONE_SET: { [string]: boolean } = {}
for _, tone in AnalyticsReport.Tones do
	TONE_SET[tone] = true
end

--[[
	The COPY FOR AI header's description of the CURRENT game loop and the questions the analyst
	should answer. Kept as data so the Lune test can assert the export describes the live loop;
	update it (and bump ExporterVersion) whenever the core loop changes.
]]
AnalyticsReport.LoopContext = table.freeze({
	"SellNukes is an 8-player Roblox LINEAR BUTTON TYCOON (kid-friendly: cartoon toy nukes, confetti",
	"explosions). Each player owns a plot. They start in a tiny Garage Lab with a homemade reactor: CLICK the",
	"producer to run a cycle (a stud progress bar pays $ per cycle), UPGRADE it (levels; every 25 levels a",
	"milestone alternates x2 cash / x2 speed), and step on PADS in a fixed order (Build / Multiplier / Speed /",
	"Manager / Unlock / Feature). A MANAGER automates a producer (idle + offline income start there). Unlock",
	"pads open the next of TEN themed areas (Garage Lab → Nuke Stand → BoomDash Delivery → Glow Rock Mine →",
	"Enrichment Lab → Rocket Factory → Launch Silos → Nuke Megastore → Space Port → Mega Nuclear Facility);",
	"the first run targets ~8 h (TycoonConfig.Pacing per area). The finale unlocks REBIRTH (reset cash /",
	"levels / pads for a permanent multiplier + Rebirth Tokens). Area 1 IS the tutorial.",
	"Side systems: pets from eggs (cash %), supply crates (boosts), daily rewards (7-day streak), time",
	"rewards, lucky wheel, codes, group reward, offline earnings (Welcome Back, DOUBLE IT product), an optional",
	"attack mode (launch cartoon nukes at other plots, AA towers, shields; targets never lose anything), the",
	"Harvest Feast Thanksgiving event (Golden Turkeys, acorns, sticker sheet) and many Robux passes / products.",
	"",
	"Answer, citing the numbers below:",
	"1. Where do new players drop in the funnel (join → first pad → first click → upgrade → manager → area 2 → 3)?",
	"2. Is the run paced as designed? Compare average first-run minutes per area (areaAt / areaN) with the targets.",
	"3. Which pads / producers stall players (time-to-pad gaps, pads bought vs reached, click vs automated income)?",
	"4. Session length, sessions per player, D1 / D7 and what predicts return (first-day milestones r1:<m>).",
	"5. Which offers / products / passes convert (shown → prompt → bought by source, device and tycoon area)?",
	"6. Are retention systems used (daily, time, wheel, codes, group, offline payouts, notifications)?",
	"7. Pets / crates / attack / event engagement, and server + client health problems by device.",
	"8. Concrete pacing, pricing, offer and retention changes, each with the metric that should move.",
	"9. Roblox's Recommended for You signals (the Roblox algorithm scorecard: first-play bounce, play days, capped",
	"   playtime, qualified sessions, co-play, spend days): which rows are BELOW TARGET and what to fix first?",
})

-- Limits for parsing untrusted-shaped payloads (generous; the server stays well under them).
-- One bounded cap shared with the admin section pool prevents valid later diagnostic
-- tables disappearing silently when new report sections are added.
local MAX_TABLES = AnalyticsConfig.ReportMaxTables
local MAX_ROWS = 60
local MAX_DAYS = 400
-- Raw counters accepted from one summary payload: the server sends at most ReportSummaryKeys
-- (3,000, pinned keys included) since W1.12; anything past it is counted into `truncated`.
local MAX_FAMILY_KEYS = math.max(3000, AnalyticsConfig.ReportSummaryKeys)
-- MAX_TEXT: longest label / note / extra kept (ClientPerfLogic.ReportNote is ~260 characters).
local MAX_TEXT = 400

-- Headline keys in display / report order.
AnalyticsReport.HeadlineOrder = table.freeze({
	"dau",
	"peakDau",
	"playerDays",
	"sessions",
	"avgSessionMinutes",
	"medianSession",
	"newPlayers",
	"d1",
	"d3",
	"d7",
	"d14",
	"d30",
	"tutorialCompletion",
	"area2Rate",
	"robux",
	"purchases",
	"payers",
	"newPayers",
	"arpdau",
	"arppu",
	"conversion",
	"padsBought",
	"rebirths",
})

-- Short labels for headline keys.
AnalyticsReport.HeadlineLabels = table.freeze({
	dau = "DAU (avg)",
	peakDau = "Peak DAU",
	playerDays = "Player-days",
	sessions = "Sessions",
	avgSessionMinutes = "Avg session",
	medianSession = "Median session",
	newPlayers = "New players",
	d1 = "D1 retention",
	d3 = "D3 retention",
	d7 = "D7 retention",
	d14 = "D14 retention",
	d30 = "D30 retention",
	tutorialCompletion = "Tutorial done (manager)",
	area2Rate = "Reached area 2",
	robux = "Robux revenue",
	purchases = "Robux purchases",
	payers = "Payers (user-days)",
	newPayers = "First-time payers",
	arpdau = "ARPDAU (R$)",
	arppu = "ARPPU (R$/payer-day)",
	conversion = "Conversion",
	padsBought = "Pads bought",
	rebirths = "Rebirths",
} :: { [string]: string })

-- Headline keys shown as percentages.
local PERCENT_HEADLINES: { [string]: boolean } = {
	d1 = true,
	d3 = true,
	d7 = true,
	d14 = true,
	d30 = true,
	conversion = true,
	tutorialCompletion = true,
	area2Rate = true,
}

--------------------------------------------------------------------------------------------------
-- Formatting
--------------------------------------------------------------------------------------------------

--[[ 1234567 → "1,234,567" (rounded to an integer; negative numbers keep their sign). ]]
function AnalyticsReport.formatInteger(value: number): string
	if value ~= value or value == math.huge or value == -math.huge then
		return "0"
	end
	local rounded = math.floor(math.abs(value) + 0.5)
	local text = tostring(rounded)
	local formatted = string.reverse((string.gsub(string.reverse(text), "(%d%d%d)", "%1,")))
	if string.sub(formatted, 1, 1) == "," then
		formatted = string.sub(formatted, 2)
	end
	return if value < 0 and rounded > 0 then "-" .. formatted else formatted
end

--[[ 0.4567 → "45.7%" ; negative (n/a) → "n/a". ]]
function AnalyticsReport.formatPercent(fraction: number): string
	if fraction < 0 or fraction ~= fraction then
		return "n/a"
	end
	return `{math.floor(fraction * 1000 + 0.5) / 10}%`
end

--[[ 190 → "3:10" (minutes:seconds; hours added past 60 minutes). ]]
function AnalyticsReport.formatDuration(seconds: number): string
	local total = math.max(0, math.floor(seconds + 0.5))
	local hours = total // 3600
	local minutes = (total % 3600) // 60
	local secs = total % 60
	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, minutes, secs)
	end
	return string.format("%d:%02d", minutes, secs)
end

--[[ A headline value in its natural unit (percent, R$, duration, plain count). ]]
function AnalyticsReport.formatHeadline(key: string, value: number): string
	if value < 0 then
		return "n/a"
	end
	if PERCENT_HEADLINES[key] then
		return AnalyticsReport.formatPercent(value)
	elseif key == "robux" then
		return `R$ {AnalyticsReport.formatInteger(value)}`
	elseif key == "arppu" or key == "arpdau" then
		return `R$ {math.floor(value * 10 + 0.5) / 10}`
	elseif key == "avgSessionMinutes" then
		return AnalyticsReport.formatDuration(value * 60)
	elseif key == "medianSession" then
		return AnalyticsReport.formatDuration(value * 60)
	elseif key == "dau" then
		return tostring(math.floor(value * 10 + 0.5) / 10)
	end
	return AnalyticsReport.formatInteger(value)
end

--------------------------------------------------------------------------------------------------
-- Parsing (client side: never trust the shape of a payload)
--------------------------------------------------------------------------------------------------

local function finite(value: unknown): number?
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	return value
end

-- Accept optional metadata without coercing unknown legacy values into false or zero.
local function optionalBoolean(value: unknown): boolean?
	return if type(value) == "boolean" then value else nil
end

-- An elapsed UTC day is bounded independently of ordinary counter magnitudes.
local function elapsedSeconds(value: unknown): number?
	local number = finite(value)
	return if number ~= nil and number >= 0 and number <= 86400 then math.floor(number) else nil
end

-- Exporter identifiers are compact labels, never arbitrary client-provided prose.
local function exporterVersion(value: unknown): string?
	return if type(value) == "string"
			and #value > 0
			and #value <= 64
			and string.match(value, "^[%w._%-]+$")
		then value
		else nil
end

-- Shared by the admin panel, COPY FOR AI and RAW pages; false is an open window, nil is unknown.
function AnalyticsReport.windowStatus(metadata: WindowMetadata): string
	if metadata.windowComplete == true then
		return "CLOSED UTC DAYS"
	elseif metadata.windowComplete == false then
		local elapsed = metadata.openDayElapsedSeconds
		return "OPEN UTC DAY" .. (if elapsed ~= nil then ` · {elapsed}s elapsed` else "") .. " · provisional"
	end
	return "UNKNOWN WINDOW (legacy metadata)"
end

-- Read reliability and local-memory scope are independent of UTC-day completeness.
function AnalyticsReport.readStatus(partial: boolean?, source: string): string
	local reads = if partial == true then "READS INCOMPLETE" elseif partial == false then "READS OK" else "READS UNKNOWN"
	return reads .. (if source == "memory" then " · THIS SERVER ONLY" else "")
end

-- Keep the parser's independent limits visible in both panel status and copied reports.
function AnalyticsReport.omissionStatus(summary: Summary): string
	return `{summary.truncated} counters · {summary.sectionsOmitted or 0} sections · {summary.daysOmitted or 0} daily rows`
end

-- Two bounded lines for the admin panel's 344 x 50 status slot. Read/scope failures come
-- first; counts, timestamps and elapsed seconds stay in the coverage section and exports.
-- Example: READS INCOMPLETE · LOCAL ONLY / OMISSIONS · OPEN DAY.
function AnalyticsReport.compactStatus(summary: Summary): (string, boolean)
	local omitted = summary.truncated > 0 or (summary.sectionsOmitted or 0) > 0 or (summary.daysOmitted or 0) > 0
	for _, section in summary.tables do
		omitted = omitted or (section.more or 0) > 0
	end
	local reads = if summary.partial then "READS INCOMPLETE" else "READS OK"
	if summary.source == "memory" then
		reads ..= " · LOCAL ONLY"
	end
	local window = if summary.windowComplete == true
		then "CLOSED DAYS"
		elseif summary.windowComplete == false then "OPEN DAY"
		else "WINDOW UNKNOWN"
	return reads .. "\n" .. (if omitted then "OMISSIONS · " else "") .. window,
		summary.partial or summary.source == "memory" or omitted or summary.windowComplete ~= true
end

local function text(value: unknown, default: string): string
	if type(value) ~= "string" then
		return default
	end
	return string.sub(value, 1, MAX_TEXT)
end

local function parseRow(raw: unknown): Row?
	if type(raw) ~= "table" then
		return nil
	end
	local row = raw :: { [string]: unknown }
	local value = finite(row.value)
	if value == nil then
		return nil
	end
	return {
		id = text(row.id, "?"),
		label = text(row.label, "?"),
		value = value,
		display = text(row.display, AnalyticsReport.formatInteger(value)),
		extra = text(row.extra, ""),
		share = math.clamp(finite(row.share) or 0, 0, 1),
		tone = if type(row.tone) == "string" and TONE_SET[row.tone :: string] then row.tone :: string else nil,
	}
end

local function parseTable(raw: unknown): Table?
	if type(raw) ~= "table" then
		return nil
	end
	local source = raw :: { [string]: unknown }
	local rows: { Row } = {}
	-- [W1.12] Rows the server already cut, plus any this parser drops past MAX_ROWS: the panel
	-- and the report say "+N more rows" instead of cutting silently.
	local more = math.clamp(math.floor(finite(source.more) or 0), 0, 1e9)
	if type(source.rows) == "table" then
		for _, rawRow in source.rows :: { unknown } do
			if #rows >= MAX_ROWS then
				more += 1
				continue
			end
			local row = parseRow(rawRow)
			if row ~= nil then
				table.insert(rows, row)
			end
		end
	end
	return {
		id = text(source.id, "?"),
		title = text(source.title, "?"),
		note = text(source.note, ""),
		total = finite(source.total) or 0,
		rows = rows,
		more = more,
	}
end

local function parseDay(raw: unknown): DayRow?
	if type(raw) ~= "table" then
		return nil
	end
	local day = raw :: { [string]: unknown }
	if type(day.day) ~= "string" then
		return nil
	end
	return {
		day = text(day.day, "?"),
		dau = finite(day.dau) or 0,
		new = finite(day.new) or 0,
		sessions = finite(day.sessions) or 0,
		robux = finite(day.robux) or 0,
		payers = finite(day.payers) or 0,
		pads = finite(day.pads) or 0,
	}
end

--[[
	Validates a server summary. Returns nil if it is not a table; otherwise a fully typed copy
	where bad entries are dropped and missing fields get defaults.
]]
function AnalyticsReport.parse(raw: unknown): Summary?
	if type(raw) ~= "table" then
		return nil
	end
	local source = raw :: { [string]: unknown }
	local headline: { [string]: number } = {}
	if type(source.headline) == "table" then
		for _, key in AnalyticsReport.HeadlineOrder do
			local value = finite((source.headline :: { [string]: unknown })[key])
			if value ~= nil then
				headline[key] = value
			end
		end
	end
	local tables: { Table } = {}
	if type(source.tables) == "table" then
		for _, rawTable in source.tables :: { unknown } do
			if #tables >= MAX_TABLES then
				break
			end
			local parsed = parseTable(rawTable)
			if parsed ~= nil then
				table.insert(tables, parsed)
			end
		end
	end
	local daily: { DayRow } = {}
	if type(source.daily) == "table" then
		for _, rawDay in source.daily :: { unknown } do
			if #daily >= MAX_DAYS then
				break
			end
			local parsed = parseDay(rawDay)
			if parsed ~= nil then
				table.insert(daily, parsed)
			end
		end
	end
	local families: { [string]: { [string]: number } } = {}
	local keys = 0
	-- [W1.12] counters dropped here (past MAX_FAMILY_KEYS) add to `truncated`: never silent.
	local dropped = 0
	if type(source.families) == "table" then
		for _, family in AnalyticsConfig.Families do
			local rawCounters = (source.families :: { [string]: unknown })[family]
			local counters: { [string]: number } = {}
			if type(rawCounters) == "table" then
				for key, value in rawCounters :: { [unknown]: unknown } do
					local number = finite(value)
					if type(key) == "string" and number ~= nil then
						if keys < MAX_FAMILY_KEYS then
							counters[string.sub(key, 1, AnalyticsConfig.MaxKeyLength)] = number
							keys += 1
						else
							dropped += 1
						end
					end
				end
			end
			families[family] = counters
		end
	end
	return {
		range = text(source.range, "today"),
		from = text(source.from, "?"),
		to = text(source.to, "?"),
		days = math.max(0, finite(source.days) or 0),
		generatedAt = finite(source.generatedAt) or 0,
		source = text(source.source, "datastore"),
		partial = source.partial == true,
		exporterVersion = exporterVersion(source.exporterVersion),
		windowComplete = optionalBoolean(source.windowComplete),
		openDayElapsedSeconds = elapsedSeconds(source.openDayElapsedSeconds),
		note = text(source.note, ""),
		sectionsOmitted = math.max(0, math.floor(finite(source.sectionsOmitted) or 0))
			+ (if type(source.tables) == "table" then math.max(0, #(source.tables :: { unknown }) - #tables) else 0),
		daysOmitted = math.max(0, math.floor(finite(source.daysOmitted) or 0))
			+ (if type(source.daily) == "table" then math.max(0, #(source.daily :: { unknown }) - #daily) else 0),
		headline = headline,
		tables = tables,
		daily = daily,
		families = families,
		truncated = math.max(0, math.floor(finite(source.truncated) or 0)) + dropped,
		-- [W1.12] RAW DATA snapshot id (whole number, 0 = none).
		rawId = math.clamp(math.floor(finite(source.rawId) or 0), 0, 2 ^ 31 - 1),
	}
end

--------------------------------------------------------------------------------------------------
-- [W1.12] Pinned keys, budgets and key-pattern presence (shared by the server trim and toText)
--------------------------------------------------------------------------------------------------

-- The fold key AnalyticsLogic.add uses once a family-day holds MaxKeysPerFamily keys.
local OTHER_KEY = "_other"
local OTHER_MEANING =
	`keys past {AnalyticsConfig.MaxKeysPerFamily} distinct keys of one family on one day, folded together`

--[[
	True when `key` is pinned: it starts with an AnalyticsConfig.ReportPinnedPrefixes entry or
	contains (ignoring case) a ReportPinnedContains entry. Pinned keys survive every trim
	(selectCounters), whatever their value: they are the numbers every read starts from.
	@param key  a metric key
	@return whether the key is pinned
	Example: isPinned("r1:all") --> true · isPinned("ops:badKey:pets") --> true ·
	         isPinned("click:p1_workbench") --> false
]]
function AnalyticsReport.isPinned(key: string): boolean
	for _, prefix in AnalyticsConfig.ReportPinnedPrefixes do
		if string.sub(key, 1, #prefix) == prefix then
			return true
		end
	end
	local lower = string.lower(key)
	for _, part in AnalyticsConfig.ReportPinnedContains do
		if string.find(lower, part, 1, true) ~= nil then
			return true
		end
	end
	return false
end

--[[
	A counter value as the JSON blocks print it. Whole numbers are unchanged; other values are
	rounded to 2 decimals (4 below 1): float sums such as 1438718.6899999977 (ms) spent 8
	characters each on digits nobody reads. Non-finite values (never stored) print as 0.
	@param value  a counter value
	@return the printed value
	Example: jsonNumber(1438718.6899999977) --> 1438718.69 · jsonNumber(12) --> 12
]]
function AnalyticsReport.jsonNumber(value: number): number
	if value ~= value or value == math.huge or value == -math.huge then
		return 0
	end
	if value % 1 == 0 then
		return value
	end
	local scale = if math.abs(value) < 1 then 10000 else 100
	return math.floor(value * scale + 0.5) / scale
end

--[[
	JSON characters one counter costs inside its family object: `"key":value,` — the key, two
	quotes, the colon, the printed value and one comma. An estimate (an encoder may escape a
	character): toText re-checks the encoded size and trims the tail if it overshoots.
	@return characters
	Example: jsonCost("dau", 3169) --> 3 + 4 + 4 = 11
]]
function AnalyticsReport.jsonCost(key: string, value: number): number
	return #key + 4 + #tostring(AnalyticsReport.jsonNumber(value))
end

--[[
	Picks the counters to keep under a budget: the one trim used by AnalyticsLogic.summarize (the
	payload, a key budget) and toText (the JSON block, a character budget).
		1. PINNED keys of every family (isPinned), largest first, at most ReportPinnedMax: kept
		   even past the budget (their cost still counts against it). Pinned keys past
		   ReportPinnedMax are not dropped: they go back into their family's list and compete
		   in step 2 like any other key (by value), so they still rank ahead of smaller keys;
		2. then a greedy fill ACROSS families: the largest remaining key of every family in report
		   order (rank 1), then rank 2, and so on until the next key does not fit. A family with
		   few keys never wastes its share and no family starves another. (The old trim halved a
		   uniform per-family cap until the JSON fit: 78 keys per family on 2026-10-23 while small
		   families left room unused, so 70.8 % of the counters and every r1 key went missing.)
	Cost: O(n log n) for n counters (one sort of the pinned keys, one per family).
	@param families  counters by family (families outside AnalyticsConfig.Families are ignored)
	@param budget    budget units (keys for the payload trim, JSON characters for toText)
	@param costOf    units one counter costs: (family, key, value) → number
	@return Selection: kept counters (every report family present), priority order, counts
	Example: AnalyticsReport.selectCounters(totals, 3000, function() return 1 end).count --> ≤ 3000
]]
function AnalyticsReport.selectCounters(
	families: FamilyCounters,
	budget: number,
	costOf: (family: string, key: string, value: number) -> number
): Selection
	local kept: FamilyCounters = {}
	local order: { Pick } = {}
	local pinned: { Pick } = {}
	local rest: { [string]: { string } } = {}
	local familyRank: { [string]: number } = {}
	local empty: { [string]: number } = {}
	local total = 0
	for rank, family in AnalyticsConfig.Families do
		familyRank[family] = rank
		kept[family] = {}
		local counters = families[family] or empty
		local list: { string } = {}
		for key in counters do
			total += 1
			if AnalyticsReport.isPinned(key) then
				table.insert(pinned, { family = family, key = key })
			else
				table.insert(list, key)
			end
		end
		rest[family] = list
	end
	local function valueOf(pick: Pick): number
		return (families[pick.family] or empty)[pick.key] or 0
	end
	table.sort(pinned, function(a: Pick, b: Pick): boolean
		local va, vb = valueOf(a), valueOf(b)
		if va ~= vb then
			return va > vb
		end
		if a.family ~= b.family then
			return familyRank[a.family] < familyRank[b.family]
		end
		return a.key < b.key
	end)
	local spent = 0
	for index, pick in pinned do
		if index > AnalyticsConfig.ReportPinnedMax then
			-- Past the pinned cap: back into the family's list, to compete in the greedy fill
			-- (sorted below with every other key of the family).
			table.insert(rest[pick.family], pick.key)
			continue
		end
		local value = valueOf(pick)
		spent += costOf(pick.family, pick.key, value)
		kept[pick.family][pick.key] = value
		table.insert(order, pick)
	end
	local pinnedCount = #order
	-- Largest first; ties by key so the same totals always give the same report.
	for _, family in AnalyticsConfig.Families do
		local counters = families[family] or empty
		table.sort(rest[family], function(a: string, b: string): boolean
			local va, vb = counters[a], counters[b]
			if va ~= vb then
				return va > vb
			end
			return a < b
		end)
	end
	-- Greedy fill, rank by rank across families; stops at the first key that does not fit.
	local rank = 1
	local full = false
	while not full do
		local any = false
		for _, family in AnalyticsConfig.Families do
			local key = rest[family][rank]
			if key == nil then
				continue
			end
			any = true
			local value = (families[family] or empty)[key] or 0
			local cost = costOf(family, key, value)
			if spent + cost > budget then
				full = true
				break
			end
			spent += cost
			kept[family][key] = value
			table.insert(order, { family = family, key = key })
		end
		if not any then
			break
		end
		rank += 1
	end
	return {
		kept = kept,
		order = order,
		pinned = pinnedCount,
		count = #order,
		omitted = total - #order,
		spent = spent,
	}
end

-- One compiled form of a documented key pattern: keys whose first ":" part is `head` (nil =
-- any key) are tested with the Lua pattern `lua`.
type Matcher = { head: string?, lua: string }
type Definition = { pattern: string, meaning: string, matchers: { Matcher } }

-- Lua pattern magic characters, escaped where a documented pattern uses them literally.
local MAGIC: { [string]: boolean } = {
	["^"] = true,
	["$"] = true,
	["("] = true,
	[")"] = true,
	["%"] = true,
	["."] = true,
	["["] = true,
	["]"] = true,
	["+"] = true,
	["-"] = true,
	["?"] = true,
}

-- Splits a documented pattern at its top-level "|" (an "|" inside "<...>" lists the values of
-- one placeholder and does not split): "n:<ctx>|send:<ctx>" → { "n:<ctx>", "send:<ctx>" }.
local function alternatives(pattern: string): { string }
	local out: { string } = {}
	local depth, start = 0, 1
	for index = 1, #pattern do
		local char = string.sub(pattern, index, index)
		if char == "<" then
			depth += 1
		elseif char == ">" then
			depth = math.max(0, depth - 1)
		elseif char == "|" and depth == 0 then
			table.insert(out, string.sub(pattern, start, index - 1))
			start = index + 1
		end
	end
	table.insert(out, string.sub(pattern, start))
	return out
end

-- One alternative as an unanchored Lua pattern: "<N>", "<HH>" and digit ranges ("<1-5>") match
-- digits, any other "<...>" one key part (no ":"), "*" anything; the rest is literal.
-- Example: luaBody("tut:phase:<N>:<Id>") --> "tut:phase:%d+:[^:]+"
local function luaBody(alternative: string): string
	local parts: { string } = {}
	local index = 1
	while index <= #alternative do
		local char = string.sub(alternative, index, index)
		local close = if char == "<" then string.find(alternative, ">", index + 1, true) else nil
		if close ~= nil then
			local inner = string.sub(alternative, index + 1, close - 1)
			local digits = inner == "N" or inner == "HH" or string.match(inner, "^[%d%-]+$") ~= nil
			table.insert(parts, if digits then "%d+" else "[^:]+")
			index = close + 1
		elseif char == "*" then
			table.insert(parts, ".*")
			index += 1
		else
			table.insert(parts, if MAGIC[char] then "%" .. char else char)
			index += 1
		end
	end
	return table.concat(parts)
end

-- The literal first ":" part of an alternative, or nil when it holds a placeholder / wildcard
-- ("r<N>" → nil, "cp:<Class>:fx" → "cp", "dau" → "dau").
local function headOf(alternative: string): string?
	local colon = string.find(alternative, ":", 1, true)
	local first = if colon ~= nil then string.sub(alternative, 1, colon - 1) else alternative
	if first == "" or string.find(first, "[<>*]") ~= nil then
		return nil
	end
	return first
end

--[[
	Compiles a documented pattern into matchers. The first alternative is a whole key. A later
	alternative is either a whole key ("n:<ctx>|send:<ctx>") or a suffix variant of the first
	("cp:<Class>:mgOff|mgDrop" also covers cp:<Class>:mgDrop; "cp:<Class>:mem|ping|recv:<bucket>"
	covers cp:<Class>:recv:<bucket>), so it gets both readings; the suffix reading also needs the
	first alternative's head, which keeps "seconds" in "cp:<Class>:reports|seconds|frames" from
	matching map:<id>:seconds.
]]
local function compilePattern(pattern: string): { Matcher }
	local alts = alternatives(pattern)
	local first = alts[1]
	local matchers: { Matcher } = { { head = headOf(first), lua = "^" .. luaBody(first) .. "$" } }
	for index = 2, #alts do
		local body = luaBody(alts[index])
		table.insert(matchers, { head = headOf(alts[index]), lua = "^" .. body .. "$" })
		table.insert(matchers, { head = headOf(first), lua = ":" .. body .. "$" })
	end
	return matchers
end

-- Every documented pattern, compiled once at load: family → definitions in pattern order.
local DEFINITIONS: { [string]: { Definition } } = {}
local DOCUMENTED = 0
for _, family in AnalyticsConfig.Families do
	local list: { Definition } = {}
	for pattern, meaning in AnalyticsConfig.Metrics[family] or {} do
		table.insert(list, { pattern = pattern, meaning = meaning, matchers = compilePattern(pattern) })
	end
	table.sort(list, function(a: Definition, b: Definition): boolean
		return a.pattern < b.pattern
	end)
	DEFINITIONS[family] = list
	DOCUMENTED += #list
end

--[[
	A documented pattern with at least one matching key (presentPatterns):
		family, pattern, meaning  the definition (AnalyticsConfig.Metrics[family][pattern])
		keys     how many of the scanned keys it matches (ranks definitions when space is short)
		pinned   whether any matching key is pinned (isPinned): those definitions rank first
]]
export type PatternLine = { family: string, pattern: string, meaning: string, keys: number, pinned: boolean }

--[[
	The documented key patterns (AnalyticsConfig.Metrics) that match at least one key of
	`families`, in report order (families, then patterns A→Z), plus the "_other" fold key when a
	family holds it. Grammar: "<x>" = one key part ("<N>", "<HH>" and "<1-5>" = digits), "*" =
	anything, "a|b" outside "<>" = alternatives (see compilePattern). A pattern matches keys of
	ANY family: a few are documented under another family than the one their recorder writes
	(the WS-I hatchery funnel is described under crates and counted in revenue). Keys are
	bucketed by their first ":" part, so a pattern scans only the keys sharing its literal head
	(a few such as "r<N>" scan every key). Each line also counts its matching keys (a key is
	counted once per pattern, even when several alternatives match it) and says whether one of
	them is pinned, so definitionLines can rank them: a few ms for 3,000 keys.
	@param families  counters by family (only the keys matter)
	@return { PatternLine }
	Example: presentPatterns({ core = { ["tut:liftMissNoHold:8"] = 3 } })
	         --> { { family = "core", pattern = "tut:liftMiss<NoHold|Held|Pressed|Raised>:8", keys = 1, pinned = false, ... } }
]]
function AnalyticsReport.presentPatterns(families: FamilyCounters): { PatternLine }
	local out: { PatternLine } = {}
	local all: { string } = {}
	local byHead: { [string]: { string } } = {}
	local pinnedKey: { [string]: boolean } = {}
	for _, family in AnalyticsConfig.Families do
		for key in families[family] or {} do
			table.insert(all, key)
			if AnalyticsReport.isPinned(key) then
				pinnedKey[key] = true
			end
			local colon = string.find(key, ":", 1, true)
			local head = if colon ~= nil then string.sub(key, 1, colon - 1) else key
			local bucket = byHead[head]
			if bucket == nil then
				bucket = {}
				byHead[head] = bucket
			end
			table.insert(bucket, key)
		end
	end
	if #all == 0 then
		return out
	end
	-- stamp[key] = the number of the last definition that counted `key`: one table for the
	-- whole scan instead of a "seen" set per definition (a key matched by two alternatives of
	-- one pattern is counted once).
	local stamp: { [string]: number } = {}
	local definitionNumber = 0
	for _, family in AnalyticsConfig.Families do
		local counters = families[family] or {}
		for _, definition in DEFINITIONS[family] or {} do
			definitionNumber += 1
			local count = 0
			local anyPinned = false
			for _, matcher in definition.matchers do
				local candidates = if matcher.head ~= nil then byHead[matcher.head] else all
				for _, key in candidates or {} do
					if stamp[key] ~= definitionNumber and string.find(key, matcher.lua) ~= nil then
						stamp[key] = definitionNumber
						count += 1
						anyPinned = anyPinned or pinnedKey[key] == true
					end
				end
			end
			if count > 0 then
				table.insert(out, {
					family = family,
					pattern = definition.pattern,
					meaning = definition.meaning,
					keys = count,
					pinned = anyPinned,
				})
			end
		end
		if counters[OTHER_KEY] ~= nil then
			table.insert(
				out,
				{ family = family, pattern = OTHER_KEY, meaning = OTHER_MEANING, keys = 1, pinned = false }
			)
		end
	end
	return out
end

--[[
	The "- family — title" / "  - `pattern`: meaning" lines for `patterns` (presentPatterns
	output, report order) within `budget` characters (one newline per line included). Shared by
	toText and rawText. When not every line fits, the most useful ones are chosen:
		1. patterns of PINNED keys first (r<N>, devR1, ops:, refusals ...: the numbers every read
		   starts from), then the patterns matching the most keys; ties keep report order;
		2. each is taken while it still fits (a long line that does not fit never blocks the
		   shorter ones ranked after it), its family header charged the first time;
		3. the chosen lines print in report order under their family headers.
	@param patterns  present patterns in report order
	@param budget    characters available
	@return the lines, how many patterns were listed, how many did not fit, characters used
	Example: definitionLines(AnalyticsReport.presentPatterns(json.counters), 4000)
	         --> { "- core — Core", "  - `r<N>`: ..." }, 12, 30, 3_980
]]
local function definitionLines(patterns: { PatternLine }, budget: number): ({ string }, number, number, number)
	local entries: { string } = {}
	local ranked: { number } = {}
	for index, line in patterns do
		entries[index] = `  - \`{line.pattern}\`: {line.meaning}`
		ranked[index] = index
	end
	table.sort(ranked, function(a: number, b: number): boolean
		local la, lb = patterns[a], patterns[b]
		if la.pinned ~= lb.pinned then
			return la.pinned
		end
		if la.keys ~= lb.keys then
			return la.keys > lb.keys
		end
		return a < b
	end)
	local function headerOf(family: string): string
		return `- {family} — {AnalyticsConfig.FamilyTitles[family] or family}`
	end
	local chosen: { [number]: boolean } = {}
	local headed: { [string]: boolean } = {}
	local used, listed = 0, 0
	for _, index in ranked do
		local family = patterns[index].family
		local cost = #entries[index] + 1 + (if headed[family] then 0 else #headerOf(family) + 1)
		if used + cost <= budget then
			used += cost
			headed[family] = true
			chosen[index] = true
			listed += 1
		end
	end
	local lines: { string } = {}
	local current: string? = nil
	for index, line in patterns do
		if chosen[index] then
			if line.family ~= current then
				table.insert(lines, headerOf(line.family))
				current = line.family
			end
			table.insert(lines, entries[index])
		end
	end
	return lines, listed, #patterns - listed, used
end

-- The pinned-key rule in words (the report's JSON intro).
local function pinnedText(): string
	return `{table.concat(AnalyticsConfig.ReportPinnedPrefixes, ", ")} and keys containing "{table.concat(
		AnalyticsConfig.ReportPinnedContains,
		'" / "'
	)}"`
end

--------------------------------------------------------------------------------------------------
-- COPY FOR AI text
--------------------------------------------------------------------------------------------------

--[[
	The full report for an AI assistant: what the game is, the range, every headline number
	with its definition, every ranked table ("+N more rows" under a cut one), the daily series,
	the meanings of the key patterns present and one JSON block with the raw counters.
	Fits ReportMaxChars (W1.12, 2026-10-23 fix list):
		1. the markdown (headline, tables, daily, headline definitions) is written first;
		2. a definitions FLOOR is reserved: the definitions of the pinned keys' patterns (the
		   keys every read starts from, always in the JSON), ranked by key count, up to
		   ReportDefinitionsFloorChars. Only the characters those lines really take are held
		   back, so a day with few pinned patterns gives the rest to the counters;
		3. the JSON counters take what is left (selectCounters: pinned keys first, then the
		   largest of every family in turn), re-checked against the encoded size;
		4. the key patterns present in that JSON are listed in the space that remains (at least
		   the floor): pinned keys' patterns first, then the most common (definitionLines), with
		   a pointer to docs/analytics.md and the RAW pages for any that do not fit.
	`countersOmitted` = counters the server trim and this trim left out; COPY RAW DATA has all.
	@param summary  a parsed summary
	@return the report text (≤ ReportMaxChars)
]]
function AnalyticsReport.toText(summary: Summary): string
	local cap = AnalyticsConfig.ReportMaxChars
	local lines: { string } = {}
	local function add(line: string)
		table.insert(lines, line)
	end

	add(`# SellNukes analytics report — {AnalyticsConfig.RangeLabels[summary.range] or summary.range}`)
	add("")
	-- [exporter 3] the live loop + the analyst's questions (LoopContext).
	for _, line in AnalyticsReport.LoopContext do
		add(line)
	end
	add("")
	add(`- Range: {summary.from} to {summary.to} (UTC days, {summary.days} day(s))`)
	add(`- Generated: {os.date("!%Y-%m-%d %H:%M", summary.generatedAt)} UTC`)
	add(`- Source: {summary.source} · {AnalyticsReport.readStatus(summary.partial, summary.source)}`)
	add(`- Window: {AnalyticsReport.windowStatus(summary)}`)
	add(`- Summary omissions: {AnalyticsReport.omissionStatus(summary)}; copied JSON may omit additional counters.`)
	add(
		`- Report exporter: {summary.exporterVersion or "unknown"}; event-producing builds require their own coverage evidence.`
	)
	if summary.note ~= "" then
		add(`- Note: {summary.note}`)
	end
	add(
		"- Server-recorded outcomes and validated client UI/performance claims are distinct; no personal data is included."
	)
	add(
		"- Missing telemetry can mean older producers, no eligible events or unavailable data; it is not proof of zero."
	)
	-- [W1.12] One explanation for every "+N more rows" line (kept short per table). True in every
	-- case: the rows a table cuts are its smallest, and so are the keys the JSON trim drops.
	local anyCut = false
	for _, section in summary.tables do
		if (section.more or 0) > 0 then
			anyCut = true
			break
		end
	end
	if anyCut then
		add(
			'- A table ending in "+N more rows" was cut. COPY RAW DATA pages the snapshot within page limits; check its omitted count. The JSON below may also omit counters (see countersOmitted).'
		)
	end
	add("")
	add("## Headline")
	add("")
	add("| Metric | Value |")
	add("|---|---|")
	for _, key in AnalyticsReport.HeadlineOrder do
		local value = summary.headline[key]
		if value ~= nil then
			add(`| {AnalyticsReport.HeadlineLabels[key] or key} | {AnalyticsReport.formatHeadline(key, value)} |`)
		end
	end
	add("")
	for _, section in summary.tables do
		add(`## {section.title}`)
		if section.note ~= "" then
			add("")
			add(`_{section.note}_`)
		end
		add("")
		local more = section.more or 0
		if #section.rows == 0 and more == 0 then
			add("(no data in this range)")
		else
			add("| # | Item | Value | Details |")
			add("|---|---|---|---|")
			for index, row in section.rows do
				-- The id once when it is also the label ("`Wheel`", not "Wheel (`Wheel`)"), as
				-- the panel does: thousands of characters on a busy day, no information lost.
				local item = if row.label == row.id
					then "`" .. row.id .. "`"
					else `{row.label} (` .. "`" .. row.id .. "`)"
				-- R122 scorecard rows: the verdict beside the value ("12% · BELOW TARGET"); n/a and
				-- info rows already say what they are in their display text.
				local tone = row.tone
				local verdictShown = tone ~= nil and tone ~= "na" and tone ~= "info"
				local shown = if verdictShown and tone ~= nil
					then `{row.display} · {AnalyticsReport.ToneLabels[tone] or tone}`
					else row.display
				add(`| {index} | {item} | {shown} | {row.extra} |`)
			end
			-- [W1.12] never a silent cut: say how many rows the table left out (the line is short:
			-- a busy day cuts ~20 tables, and the intro above explains it once).
			if more > 0 then
				add(`| … | +{AnalyticsReport.formatInteger(more)} more rows |  | see RAW; check omissions |`)
			end
		end
		add("")
	end
	add("## Daily")
	add("")
	if #summary.daily == 0 then
		add("(no days)")
	else
		add("| Day | DAU | New | Sessions | Robux | Payers | Pads bought |")
		add("|---|---|---|---|---|---|---|")
		for _, day in summary.daily do
			add(`| {day.day} | {day.dau} | {day.new} | {day.sessions} | {day.robux} | {day.payers} | {day.pads} |`)
		end
	end
	add("")
	add("## Definitions")
	add("")
	for _, key in AnalyticsReport.HeadlineOrder do
		local definition = AnalyticsConfig.HeadlineDefinitions[key]
		if definition ~= nil then
			add(`- {AnalyticsReport.HeadlineLabels[key] or key}: {definition}`)
		end
	end
	add(`- Retention (D1/D3/D7/D14/D30): {AnalyticsConfig.HeadlineDefinitions.retention}`)
	add("")
	add("### Raw counter keys (JSON `counters`)")
	add("")
	local head = table.concat(lines, "\n")

	-- Counters in the summary (after the server trim) and in the whole range.
	local available = 0
	for _, family in AnalyticsConfig.Families do
		for _ in summary.families[family] or {} do
			available += 1
		end
	end
	local total = available + summary.truncated
	local totalText = AnalyticsReport.formatInteger(total)
	-- The two intro lines, written with their final numbers once the JSON is chosen; their
	-- longest form (every count = total) sizes the budget now.
	local function keysIntro(listed: number, present: number, skipped: number): string
		local line =
			`Only the key patterns present in the JSON below are listed ({listed} of {present} present; {DOCUMENTED} documented): the pinned keys' patterns first, then the most common. Every pattern and its meaning: {AnalyticsConfig.ReportDocsPointer}.`
		if skipped > 0 then
			line ..= `\n{skipped} more patterns present in the JSON did not fit here: see the same docs, or COPY RAW DATA (every page lists the meanings of the patterns on it).`
		end
		return line
	end
	local function dataIntro(kept: number): string
		return `The JSON holds {AnalyticsReport.formatInteger(kept)} of {totalText} counters: pinned keys first ({pinnedText()}), then the largest of every family in turn. countersOmitted = counters left out of this paste. COPY RAW DATA also has page limits; check each page's omitted count before treating it as complete.`
	end
	local fixed = #keysIntro(DOCUMENTED, DOCUMENTED, DOCUMENTED)
		+ #dataIntro(total)
		+ #"\n\n\n## Data (JSON)\n\n\n\n```json\n\n```\n"
		+ AnalyticsConfig.ReportMarginChars

	-- The JSON: every field but the counters first (its exact size), then the counters.
	local jsonFamilies: FamilyCounters = {}
	for _, family in AnalyticsConfig.Families do
		jsonFamilies[family] = {}
	end
	local payload = {
		range = summary.range,
		from = summary.from,
		to = summary.to,
		timezone = "UTC",
		generatedAt = summary.generatedAt,
		source = summary.source,
		partial = summary.partial,
		sectionsOmitted = summary.sectionsOmitted,
		daysOmitted = summary.daysOmitted,
		exporterVersion = summary.exporterVersion,
		windowComplete = summary.windowComplete,
		openDayElapsedSeconds = summary.openDayElapsedSeconds,
		headline = summary.headline,
		daily = summary.daily,
		counters = jsonFamilies,
		countersOmitted = total,
		countersTotal = total,
	}
	-- [W1.12] Definitions floor: the pinned keys (selectCounters with no budget keeps exactly
	-- the pinned set the full trim keeps) are always printed, so their patterns' definitions
	-- will be listed; hold back what those lines take, at most ReportDefinitionsFloorChars.
	-- (Every key costs 1 against a budget of 0: nothing past the pinned keys fits.)
	local pinnedOnly = AnalyticsReport.selectCounters(summary.families, 0, function(): number
		return 1
	end)
	local _floorLines, _floorListed, _floorSkipped, floorChars =
		definitionLines(AnalyticsReport.presentPatterns(pinnedOnly.kept), AnalyticsConfig.ReportDefinitionsFloorChars)
	local jsonBudget = cap - #head - fixed - floorChars
	local base = #HttpService:JSONEncode(payload)
	local selection = AnalyticsReport.selectCounters(
		summary.families,
		jsonBudget - base,
		function(_family: string, key: string, value: number): number
			return AnalyticsReport.jsonCost(key, value)
		end
	)
	for _, pick in selection.order do
		jsonFamilies[pick.family][pick.key] = AnalyticsReport.jsonNumber(selection.kept[pick.family][pick.key])
	end
	local kept = selection.count
	payload.countersOmitted = total - kept
	local json = HttpService:JSONEncode(payload)
	-- The cost estimate can undershoot (an escaped character): drop the lowest-priority
	-- (never pinned) keys worth the overshoot and re-encode; a few rounds at most.
	local rounds = 0
	while #json > jsonBudget and #selection.order > selection.pinned and rounds < 16 do
		rounds += 1
		local over = #json - jsonBudget + 32
		local freed = 0
		while freed < over and #selection.order > selection.pinned do
			local pick = table.remove(selection.order) :: Pick
			local value = jsonFamilies[pick.family][pick.key]
			jsonFamilies[pick.family][pick.key] = nil
			freed += AnalyticsReport.jsonCost(pick.key, value)
			kept -= 1
		end
		payload.countersOmitted = total - kept
		json = HttpService:JSONEncode(payload)
	end

	-- Key patterns present in the printed JSON, in the space the counters left (≥ the floor).
	local present = AnalyticsReport.presentPatterns(jsonFamilies)
	local defsBudget = cap - #head - #json - fixed
	local defLines, listed, skipped = definitionLines(present, defsBudget)
	local report = head
		.. keysIntro(listed, #present, skipped)
		.. (if #defLines > 0 then "\n" .. table.concat(defLines, "\n") else "")
		.. "\n\n## Data (JSON)\n\n"
		.. dataIntro(kept)
		.. "\n\n```json\n"
		.. json
		.. "\n```\n"
	if #report > cap then
		-- Only with absurd table counts (the markdown alone over the cap): hard cut.
		report = string.sub(report, 1, cap)
	end
	return report
end

--------------------------------------------------------------------------------------------------
-- [W1.12] COPY RAW DATA: uncapped source totals paged within bounded output limits
--------------------------------------------------------------------------------------------------

--[[
	Lays every counter of `families` out in pages of at most `pageChars` JSON characters AND at
	most `maxKeys` counters: families in report order, keys A→Z (so a reader finds a prefix in
	one place), each counter on exactly one page. Server side (Analytics/AnalyticsRaw), once per
	snapshot, on the first page request. Past `maxPages` the remaining counters are counted in
	`omitted` (every page says so) — never dropped silently.
	Why a key cap too: the client parser keeps at most Raw.MaxKeysPerPage counters per page (an
	untrusted-shape bound). A 60,000-character page can hold ~8,500 very short keys (7
	characters each), so without the same cap here such a page would lose keys on the client.
	@param families   the uncapped totals of a range
	@param pageChars  counter JSON characters per page (AnalyticsConfig.Raw.PageChars)
	@param maxPages   page cap (AnalyticsConfig.Raw.MaxPages)
	@param maxKeys    counters per page (default AnalyticsConfig.Raw.MaxKeysPerPage)
	@return RawIndex (always at least one page, empty when the range has no counters)
	Example: #AnalyticsReport.rawIndex(totals, 60000, 40).starts --> 1 for a 2,000-key day
]]
function AnalyticsReport.rawIndex(
	families: FamilyCounters,
	pageChars: number,
	maxPages: number,
	maxKeys: number?
): RawIndex
	local keyCap = math.max(1, maxKeys or AnalyticsConfig.Raw.MaxKeysPerPage)
	local slotFamily: { string } = {}
	local slotKey: { string } = {}
	local starts: { number } = {}
	local total, omitted = 0, 0
	local used = 0
	local pageKeys = 0 -- counters on the page being filled
	local pageFamily: string? = nil
	local full = false
	for _, family in AnalyticsConfig.Families do
		local counters = families[family]
		if counters == nil then
			continue
		end
		local keys: { string } = {}
		for key in counters do
			table.insert(keys, key)
		end
		table.sort(keys)
		for _, key in keys do
			total += 1
			if full then
				omitted += 1
				continue
			end
			local base = AnalyticsReport.jsonCost(key, counters[key])
			-- `"family":{` + `},` the first time a family appears on a page.
			local cost = base + (if pageFamily ~= family then #family + 6 else 0)
			if #starts == 0 or (used > 0 and used + cost > pageChars) or pageKeys >= keyCap then
				if #starts >= maxPages then
					full = true
					omitted += 1
					continue
				end
				table.insert(starts, #slotKey + 1)
				used = 0
				pageKeys = 0
				cost = base + #family + 6
			end
			used += cost
			pageKeys += 1
			pageFamily = family
			table.insert(slotFamily, family)
			table.insert(slotKey, key)
		end
	end
	if #starts == 0 then
		table.insert(starts, 1)
	end
	return { slotFamily = slotFamily, slotKey = slotKey, starts = starts, total = total, omitted = omitted }
end

--[[
	One RAW page's payload from an index and the totals it was built from (server side).
	@param index     rawIndex(totals, ...)
	@param families  the same totals
	@param page      1-based page number
	@param meta      the snapshot's facts (id, range, dates, source)
	@return the page, or nil when `page` is outside 1..#index.starts
]]
function AnalyticsReport.rawPage(index: RawIndex, families: FamilyCounters, page: number, meta: RawMeta): RawPage?
	local first = index.starts[page]
	if first == nil then
		return nil
	end
	local last = (index.starts[page + 1] or (#index.slotKey + 1)) - 1
	local counters: FamilyCounters = {}
	local keys = 0
	for slot = first, last do
		local family = index.slotFamily[slot]
		local key = index.slotKey[slot]
		local bucket = counters[family]
		if bucket == nil then
			bucket = {}
			counters[family] = bucket
		end
		local source = families[family]
		bucket[key] = AnalyticsReport.jsonNumber(if source ~= nil then source[key] or 0 else 0)
		keys += 1
	end
	return {
		rawId = meta.rawId,
		page = page,
		pages = #index.starts,
		total = index.total,
		omitted = index.omitted,
		keys = keys,
		dropped = 0,
		range = meta.range,
		from = meta.from,
		to = meta.to,
		generatedAt = meta.generatedAt,
		source = meta.source,
		partial = meta.partial,
		exporterVersion = meta.exporterVersion,
		windowComplete = meta.windowComplete,
		openDayElapsedSeconds = meta.openDayElapsedSeconds,
		counters = counters,
	}
end

--[[
	Validates a RAW page from the server (client side; never trust a payload's shape): whole
	page numbers inside 1..MaxPages, known families only, string keys cut to MaxKeyLength, finite
	values, at most Raw.MaxKeysPerPage counters. Entries of a known family it cannot keep (a
	non-string key, a non-finite value, or past the key cap; rawIndex never lays out more than
	the cap) are counted in `dropped`, so rawText can say so instead of losing them silently.
	@return a typed copy, or nil when the page frame itself is malformed
]]
function AnalyticsReport.parseRawPage(raw: unknown): RawPage?
	if type(raw) ~= "table" then
		return nil
	end
	local source = raw :: { [string]: unknown }
	local rawId = finite(source.rawId)
	local page = finite(source.page)
	local pages = finite(source.pages)
	if rawId == nil or page == nil or pages == nil then
		return nil
	end
	if page % 1 ~= 0 or pages % 1 ~= 0 or pages < 1 or pages > AnalyticsConfig.Raw.MaxPages then
		return nil
	end
	if page < 1 or page > pages then
		return nil
	end
	local counters: FamilyCounters = {}
	local keys = 0
	local dropped = 0
	local rawCounters = source.counters
	for _, family in AnalyticsConfig.Families do
		local bucket: { [string]: number } = {}
		local rawFamily = if type(rawCounters) == "table" then (rawCounters :: { [string]: unknown })[family] else nil
		local any = false
		if type(rawFamily) == "table" then
			for key, value in rawFamily :: { [unknown]: unknown } do
				local number = finite(value)
				if type(key) == "string" and number ~= nil and keys < AnalyticsConfig.Raw.MaxKeysPerPage then
					bucket[string.sub(key, 1, AnalyticsConfig.MaxKeyLength)] = number
					keys += 1
					any = true
				else
					dropped += 1
				end
			end
		end
		-- Only the families this page holds (an empty one would print as a bare "[]").
		if any then
			counters[family] = bucket
		end
	end
	return {
		rawId = math.floor(rawId),
		page = page,
		pages = pages,
		total = math.max(keys, math.floor(finite(source.total) or 0)),
		omitted = math.max(0, math.floor(finite(source.omitted) or 0)),
		keys = keys,
		dropped = dropped,
		range = text(source.range, "?"),
		from = text(source.from, "?"),
		to = text(source.to, "?"),
		generatedAt = finite(source.generatedAt) or 0,
		source = text(source.source, "datastore"),
		partial = optionalBoolean(source.partial),
		exporterVersion = exporterVersion(source.exporterVersion),
		windowComplete = optionalBoolean(source.windowComplete),
		openDayElapsedSeconds = elapsedSeconds(source.openDayElapsedSeconds),
		counters = counters,
	}
end

--[[
	The text of one RAW page for the COPY RAW DATA dialog: what the page is (n of m counters,
	paste every page), the meanings of the key patterns on it and one JSON block with its
	counters. Each page stands alone, so pasting any subset still explains itself. Fits
	ReportMaxChars: the counters are at most Raw.PageChars and the definitions take what is left.
	@param page  a parsed page
	@return the page text
]]
function AnalyticsReport.rawText(page: RawPage): string
	local cap = AnalyticsConfig.ReportMaxChars
	local label = AnalyticsConfig.RangeLabels[page.range] or page.range
	local lines: { string } = {
		`# SellNukes RAW counters — {label} · page {page.page} / {page.pages}`,
		"",
		`- Range: {page.from} to {page.to} (UTC days) · generated {os.date("!%Y-%m-%d %H:%M", page.generatedAt)} UTC · source {page.source}`,
		`- This page: {AnalyticsReport.formatInteger(page.keys)} of {AnalyticsReport.formatInteger(page.total)} counters. Every exported counter is on exactly one page (families in report order, keys A to Z): paste every page and check omission/read warnings. COPY FOR AI holds the summary tables.`,
	}
	if page.omitted > 0 then
		table.insert(
			lines,
			`- {AnalyticsReport.formatInteger(page.omitted)} counters did not fit in {AnalyticsConfig.Raw.MaxPages} pages and are not exported.`
		)
	end
	if page.dropped > 0 then
		table.insert(
			lines,
			`- {AnalyticsReport.formatInteger(page.dropped)} entries of this page were malformed or past the {AnalyticsReport.formatInteger(
				AnalyticsConfig.Raw.MaxKeysPerPage
			)}-counter page cap and are not shown: close, press REFRESH and copy this page again.`
		)
	end
	table.insert(
		lines,
		`- Window: {AnalyticsReport.windowStatus(page)} · {AnalyticsReport.readStatus(page.partial, page.source)}`
	)
	table.insert(
		lines,
		`- Report exporter: {page.exporterVersion or "unknown"}; event-producing builds require separate coverage evidence.`
	)
	table.insert(
		lines,
		"- Server-recorded outcomes and validated client UI/performance claims are distinct; no personal data is included."
	)
	table.insert(lines, "")
	table.insert(lines, "## Key patterns on this page")
	table.insert(lines, "")
	local json = HttpService:JSONEncode({
		range = page.range,
		from = page.from,
		to = page.to,
		timezone = "UTC",
		rawId = page.rawId,
		generatedAt = page.generatedAt,
		source = page.source,
		partial = page.partial,
		exporterVersion = page.exporterVersion,
		windowComplete = page.windowComplete,
		openDayElapsedSeconds = page.openDayElapsedSeconds,
		page = page.page,
		pages = page.pages,
		countersOnPage = page.keys,
		countersTotal = page.total,
		countersNotExported = page.omitted,
		countersDroppedOnPage = page.dropped,
		counters = page.counters,
	})
	local tail = `\n\n## Counters (JSON)\n\n\`\`\`json\n{json}\n\`\`\`\n`
	local head = table.concat(lines, "\n")
	local present = AnalyticsReport.presentPatterns(page.counters)
	local pointer = `Meanings of every key pattern: {AnalyticsConfig.ReportDocsPointer}.`
	local budget = cap - #head - #tail - #pointer - AnalyticsConfig.ReportMarginChars
	local defLines, _listed, skipped = definitionLines(present, budget)
	local body = if #defLines > 0 then table.concat(defLines, "\n") .. "\n" else "(no documented pattern matches)\n"
	if skipped > 0 then
		body ..= `{skipped} more patterns on this page did not fit. `
	end
	local result = head .. "\n" .. body .. pointer .. tail
	if #result > cap then
		result = string.sub(result, 1, cap)
	end
	return result
end

--[[ Every section heading toText writes (tests check the report contains each). ]]
function AnalyticsReport.sectionTitles(summary: Summary): { string }
	local titles = { "## Headline", "## Daily", "## Definitions", "## Data (JSON)" }
	for _, section in summary.tables do
		table.insert(titles, `## {section.title}`)
	end
	return titles
end

return table.freeze(AnalyticsReport)
