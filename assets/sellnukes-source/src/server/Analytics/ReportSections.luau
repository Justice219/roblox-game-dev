--!strict
--[[
	ReportSections — every ranked table of the SellNukes analytics report, built from the summed
	family counters of a range. Pure: no services, no yields (AnalyticsLogic.summarize calls
	`build(ctx)`; tests call it with hand-made counters).

	Section order (each appears only when the range holds its counters):
		Algorithm   (owner R122) Roblox algorithm scorecard: Roblox's Recommended for You signals
		            (PTR, first-play bounce, play days D1 / D2-7 / D8-28, capped playtime, qualified
		            sessions, co-play days, spend days, Robux per user) vs AnalyticsConfig.Algorithm
		            targets, with a verdict tone per row and the R122 counter coverage
		Players     New player funnel · First sessions at leave · D1 / D7 by first-day milestone ·
		            Unique players per surface · Session length · Sessions per player · Devices ·
		            Sessions by UTC hour
		Tycoon      Area pacing (first run vs TycoonConfig.Pacing) · Where sessions end · Pad
		            purchases · Slowest pads (time gaps) · Producers · Income share · Level marks ·
		            Tutorial · Rebirths · Offline earnings · Tycoon extras
		Worlds      (R57, Server/Analytics/WorldSections) overview · per extra world: funnel, area
		            pacing, unlock popup & travel, rebirths / eggs / Robux · client perf per world
		Revenue     Products & passes · Purchase funnel by product · Revenue by source · by device ·
		            by tycoon area · by rebirth tier · Abandoned prompts · First purchases · Offers
		Economy     Cash sources / sinks · Gem sources / sinks
		Systems     Retention systems · Screens opened · Pets · Crates · Attack · Event · Social
		Health      Server health · Server systems · Remote traffic · Client performance by device ·
		            Client memory by device · Client boot steps by device (R122)
		Data        Builds · Data quality (ops:* refusals, diverted staff / New Player Mode events)

	Connects to: AnalyticsLogic (makeTable, buckets, SectionContext), AnalyticsReport (formatting),
	NewPlayerFunnel, ServerHealthLogic, ClientPerfLogic, BuildMetrics, AnalyticsConfig,
	TycoonConfig (pacing targets, pad order).

	Example:
		local tables = ReportSections.build({ totals = totals, labelOf = labelOf, from = d, to = d,
			today = d, days = 1, daily = {} })
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnalyticsConfig = require(ReplicatedStorage.Shared.Config.AnalyticsConfig)
local TycoonConfig = require(ReplicatedStorage.Shared.Config.TycoonConfig)
local AnalyticsReport = require(ReplicatedStorage.Shared.Analytics.AnalyticsReport)
local ClientPerfLogic = require(ReplicatedStorage.Shared.Analytics.ClientPerfLogic)
local NewPlayerFunnel = require(ReplicatedStorage.Shared.Analytics.NewPlayerFunnel)
local AnalyticsLogic = require(script.Parent.AnalyticsLogic)
local BuildMetrics = require(script.Parent.BuildMetrics)
local ServerHealthLogic = require(script.Parent.ServerHealthLogic)
local WorldSections = require(script.Parent.WorldSections)

type Counters = AnalyticsLogic.Counters
type Entry = AnalyticsLogic.Entry
type Table = AnalyticsReport.Table
type Ctx = AnalyticsLogic.SectionContext

local ReportSections = {}

local makeTable = AnalyticsLogic.makeTable
local pctOf = AnalyticsLogic.pctOf
local formatInteger = AnalyticsReport.formatInteger
local formatPercent = AnalyticsReport.formatPercent

-- One decimal ("12.3").
local function oneDecimal(value: number): string
	return tostring(math.floor(value * 10 + 0.5) / 10)
end

-- Large cash numbers as "1.23e+15" style short text (cash sums reach 1e300).
local function shortNumber(value: number): string
	local magnitude = math.abs(value)
	if magnitude < 1e6 then
		return formatInteger(value)
	end
	local suffixes = { "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
	local exponent = math.floor(math.log10(magnitude) / 3)
	if exponent <= #suffixes then
		return `{oneDecimal(value / 10 ^ (exponent * 3))}{suffixes[exponent]}`
	end
	return string.format("%.2e", value)
end
ReportSections.shortNumber = shortNumber

-- Entries for every key of `counters` that starts with `prefix` (id = the suffix).
local function prefixEntries(counters: Counters, prefix: string, labelOf: ((id: string) -> string)?): { Entry }
	local entries: { Entry } = {}
	for key, value in counters do
		if string.sub(key, 1, #prefix) == prefix then
			local id = string.sub(key, #prefix + 1)
			table.insert(entries, { id = id, label = if labelOf ~= nil then labelOf(id) else id, value = value })
		end
	end
	return entries
end

-- Adds `section` when it has rows.
local function push(out: { Table }, section: Table)
	if #section.rows > 0 or (section.more or 0) > 0 then
		table.insert(out, section)
	end
end

-- Sum of counters starting with `prefix`.
local sumPrefix = AnalyticsLogic.sumPrefix

-- Entries for an ordered label list ("<prefix><label>").
local function labelEntries(counters: Counters, prefix: string, labels: { string }): { Entry }
	local entries: { Entry } = {}
	local total = 0
	for _, label in labels do
		total += counters[prefix .. label] or 0
	end
	for _, label in labels do
		local value = counters[prefix .. label] or 0
		if value > 0 then
			table.insert(entries, { id = label, label = label, value = value, extra = pctOf(value, total) })
		end
	end
	return entries
end

--------------------------------------------------------------------------------------------------
-- Roblox algorithm scorecard (owner R122; spec 2026-11-01 §0 / §2.5)
--------------------------------------------------------------------------------------------------

local ALGORITHM = AnalyticsConfig.Algorithm
type Target = { good: number, watch: number, lowerIsBetter: boolean? }

-- Two decimals ("0.12").
local function twoDecimals(value: number): string
	return string.format("%.2f", value)
end

-- "0.12 days (12%)": a per-user day count that is also a share of users.
local function daysText(value: number): string
	return `{twoDecimals(value)} days`
end

-- Verdict of `value` vs its target: "good" / "watch" / "bad" (lowerIsBetter flips the tests).
local function verdict(value: number, target: Target): string
	if target.lowerIsBetter then
		return if value <= target.good then "good" elseif value <= target.watch then "watch" else "bad"
	end
	return if value >= target.good then "good" elseif value >= target.watch then "watch" else "bad"
end

-- Bar length = how far `value` gets toward the "good" target (0..1; 1 = on target).
local function attainment(value: number, target: Target): number
	if target.lowerIsBetter then
		return if value <= target.good then 1 else target.good / value
	end
	return if target.good > 0 then math.clamp(value / target.good, 0, 1) else 0
end

-- "goal under 15% (watch under 25%)" / "goal 20 min+ (watch 10 min+)".
local function targetText(target: Target, format: (number) -> string): string
	if target.lowerIsBetter then
		return `goal under {format(target.good)} (watch under {format(target.watch)})`
	end
	return `goal {format(target.good)}+ (watch {format(target.watch)}+)`
end

--[[
	One Roblox signal row of the scorecard:
		id / label / tier / window   what Roblox ranks, how important it is, our measurement window
		value                        the number, or nil = n/a (a missing denominator is NEVER 0)
		naReason                     why it is n/a (shown in the details)
		format                       value → display text
		targetFormat                 goal → text (default `format`; share rows read better as "10%")
		target                       AnalyticsConfig.Algorithm.Targets key (nil = info row)
		partial                      built from R122 counters a pre-R122 server did not record
		sample                       R135: measured on the R122+ servers of a mixed-build range with
		                             THEIR denominator (a real verdict + this note, never PARTIAL)
		detail                       the raw numbers behind it
]]
type Signal = {
	id: string,
	label: string,
	tier: string,
	window: string,
	value: number?,
	naReason: string?,
	format: (number) -> string,
	targetFormat: ((number) -> string)?,
	target: string?,
	partial: boolean,
	sample: string?,
	detail: string,
}

-- The scorecard entry of a signal: display, verdict tone, attainment bar and the details line.
local function signalEntry(signal: Signal): Entry
	local target: Target? = if signal.target ~= nil then ALGORITHM.Targets[signal.target] else nil
	local parts = { signal.tier, signal.window }
	if target ~= nil then
		table.insert(parts, targetText(target, signal.targetFormat or signal.format))
	end
	local value = signal.value
	local tone: string
	local share = 0
	if value == nil then
		tone = "na"
		table.insert(parts, `n/a: {signal.naReason or "no denominator in this range"}`)
	else
		if signal.partial then
			tone = "partial"
			table.insert(parts, "PARTIAL: some sessions in range ran on pre-R122 servers (undercount)")
		elseif target ~= nil then
			tone = verdict(value, target)
		else
			tone = "info"
		end
		if not signal.partial and signal.sample ~= nil then
			table.insert(parts, signal.sample)
		end
		share = if target ~= nil then attainment(value, target) else 0
	end
	if signal.detail ~= "" then
		table.insert(parts, signal.detail)
	end
	return {
		id = signal.id,
		label = signal.label,
		value = value or 0,
		display = if value ~= nil then signal.format(value) else "n/a",
		extra = table.concat(parts, " · "),
		tone = tone,
		share = share,
	}
end

--[[
	Σ over N in [first, last] of the D-N return-date ratio rbx:day:N (r1 for N = 1) / cohort(N): the
	average number of days a player of the cohorts played in that window (Roblox's play days per
	user). nil + reason when any N lacks a known, non-empty, consistent cohort.
	@return sum?, reason?, "D2 4% · D3 3% ..." details
]]
local function playDays(ctx: Ctx, core: Counters, first: number, last: number): (number?, string?, string)
	local sum = 0
	local details: { string } = {}
	for n = first, last do
		local returns = if n == 1 then core.r1 or 0 else core[`rbx:day:{n}`] or 0
		local cohort, known = AnalyticsLogic.returnCohort(ctx, n)
		if not known then
			return nil,
				`D{n} cohort / return days not all read (analytics history must reach {last} days before the range; window not complete)`,
				""
		elseif cohort <= 0 then
			return nil, `no new players on the D{n} cohort days`, ""
		elseif returns > cohort then
			return nil, `D{n} returns exceed the cohort (inconsistent reads)`, ""
		end
		sum += returns / cohort
		if last - first <= 6 then
			table.insert(details, `D{n} {formatPercent(returns / cohort)}`)
		end
	end
	if #details == 0 then
		table.insert(details, `Σ of {last - first + 1} daily return ratios`)
	end
	return sum, nil, table.concat(details, " · ")
end

--[[
	R135: player-days played on the builds that recorded the R122 signals, the denominator of the
	per-player-day scorecard rows on a mixed-build range. A build counts as covered when any of its
	"build:<release>:p<place>:rbx:*" slices (BuildMetrics) is non-zero; its "build:…:dau" is its
	player-days. Pre-R122 builds have no rbx slices, so they never enter the denominator their
	numerators cannot have. A player who switched builds on one day counts once per build (the
	denominator errs high, so the rate errs low, never high). 0 = no build slices in the range.
	Example: { ["build:0.9.0:p292:dau"] = 103, ["build:0.9.0:p292:rbx:playSec"] = 39521,
	           ["build:0.7.1:p272:dau"] = 201 } --> 103
]]
local function coveredPlayerDays(core: Counters): number
	local dauOf: { [string]: number } = {}
	local covered: { [string]: boolean } = {}
	for key, value in core do
		local identity, metric = BuildMetrics.parse(key)
		if identity ~= nil and metric ~= nil then
			if metric == "dau" then
				dauOf[identity] = value
			elseif string.sub(metric, 1, 4) == "rbx:" and value > 0 then
				covered[identity] = true
			end
		end
	end
	local total = 0
	for identity in covered do
		total += dauOf[identity] or 0
	end
	return total
end

--[[
	The "algorithm" table: Roblox's Recommended for You signals (spec §0 tiers) with our value, the
	window it covers and a verdict vs AnalyticsConfig.Algorithm.Targets. Roblox averages per user
	over users who joined organically from Recommended for You (Day 1 / Days 2-7 / Days 8-28); ours
	cover every player of the range (per player-day), so they are directional. Only when the range
	has players.
]]
local function algorithmSection(out: { Table }, ctx: Ctx)
	local core: Counters = ctx.totals.core or {}
	local revenue: Counters = ctx.totals.revenue or {}
	local dau = core.dau or 0
	local sessions = core.sessions or 0
	local joined = core["ftue:joined"] or 0
	if dau <= 0 and sessions <= 0 and joined <= 0 then
		return
	end
	local rbxSessions = sumPrefix(core, "rbx:session:")
	-- Coverage: Σ rbx:session:* counts exactly the sessions R122+ servers ended (same place as
	-- `sessions`), so a mixed-build range is detected without per-day build data.
	local coverage = if sessions > 0 then math.min(1, rbxSessions / sessions) else nil
	local partial = coverage == nil or coverage < ALGORITHM.MinCoverage
	local window = `{AnalyticsLogic.dayString(ctx.from)}–{AnalyticsLogic.dayString(ctx.to)}`
	-- A per-player-day average, or nil (n/a) without player-days.
	local function perDau(numerator: number): number?
		return if dau > 0 then numerator / dau else nil
	end
	local noDau = if dau > 0 then nil else "no player-days in range"
	-- R135: the rbx per-player-day rows (playtime, qualified sessions, co-play) divide R122+ numerators
	-- by R122+ player-days. Full coverage: every player-day. Mixed builds: the covered builds'
	-- player-days (a real verdict + SAMPLE note); without build slices: every player-day + PARTIAL
	-- (undercount), as before R135 — which read 1.6 min / 0.14 / 2 % for 5.9 min / 0.51 / 7 %.
	local rbxDau = dau
	local rbxPartial = partial
	local rbxSample: string? = nil
	if partial and dau > 0 then
		local covered = math.min(dau, coveredPlayerDays(core))
		if covered > 0 then
			rbxDau = covered
			rbxPartial = false
			rbxSample = `SAMPLE: R122+ servers only ({formatInteger(covered)} of {formatInteger(dau)} player-days)`
		end
	end
	local function perRbxDau(numerator: number): number?
		return if rbxDau > 0 then numerator / rbxDau else nil
	end
	-- R135: first-play bounce divides by the first sessions the R122+ servers classified (Σ
	-- rbx:bounceDev:*, recorded with rbx:bounce:* at the same session end), not by every joined new
	-- player: old servers and first sessions still running record no bucket. Exact at any coverage.
	local firstMeasured = sumPrefix(core, "rbx:bounceDev:")
	local bounceSample = if partial and firstMeasured > 0
		then `SAMPLE: R122+ servers only ({formatInteger(firstMeasured)} of {formatInteger(joined)} joined new players)`
		else nil

	-- First-play bounce by device ("phone 12/40 · console 3/9"): <bucket> / first sessions per class.
	local function bounceByDevice(bucket: string): string
		local classes = table.clone(AnalyticsConfig.DeviceClasses)
		table.insert(classes, "unknown")
		local parts: { string } = {}
		for _, class in classes do
			local prefix = `rbx:bounceDev:{class}:`
			local total = sumPrefix(core, prefix)
			if total > 0 then
				table.insert(parts, `{class} {formatInteger(core[prefix .. bucket] or 0)}/{formatInteger(total)}`)
			end
		end
		return if #parts > 0 then `first sessions by device: {table.concat(parts, " · ")}` else ""
	end

	local entries: { Entry } = {}
	-- 1. Play-through rate: decided by the tile before anyone joins (not observable in-game).
	table.insert(entries, {
		id = "ptr",
		label = "Play-through rate (PTR)",
		value = 0,
		display = "Creator Hub only",
		extra = "Most important · tile impressions → plays (thumbnail / title / icon) · read it in Creator Hub → Analytics → Discovery; A/B thumbnails there",
		tone = "info",
		share = 0,
	})
	-- 2-3. First-play bounce (lower is better), denominator = first sessions classified (R135, above).
	local lt60 = core["rbx:bounce:lt60"] or 0
	local mid = core["rbx:bounce:60to180"] or 0
	local noFirst = "no first sessions of new players ended on R122+ servers (rbx:bounceDev:*)"
	table.insert(
		entries,
		signalEntry({
			id = "bounceLt60",
			label = "First-play bounce: left within 60 s",
			tier = "Most important (negative)",
			window = `first sessions of new players, {window}`,
			value = if firstMeasured > 0 then lt60 / firstMeasured else nil,
			naReason = noFirst,
			format = formatPercent,
			target = "bounceLt60",
			partial = false,
			sample = bounceSample,
			detail = `{formatInteger(lt60)} of {formatInteger(firstMeasured)} first sessions · {bounceByDevice("lt60")}`,
		})
	)
	table.insert(
		entries,
		signalEntry({
			id = "bounce60to180",
			label = "First-play bounce: left after 61-180 s",
			tier = "Most important (negative)",
			window = `first sessions of new players, {window}`,
			value = if firstMeasured > 0 then mid / firstMeasured else nil,
			naReason = noFirst,
			format = formatPercent,
			target = "bounce60to180",
			partial = false,
			sample = bounceSample,
			detail = `{formatInteger(mid)} of {formatInteger(firstMeasured)} first sessions · {bounceByDevice(
				"60to180"
			)}`,
		})
	)
	-- 4-6. Play days per user (return-date cohorts; D1 = r1 / previous day's new, never partial).
	do
		local d1, d1Reason, d1Detail = playDays(ctx, core, 1, 1)
		local returnWindow = `return days {window}`
		table.insert(
			entries,
			signalEntry({
				id = "playDaysD1",
				label = "Play days per user: Day 1",
				tier = "Most important",
				window = `{returnWindow} (cohort = new players the day before)`,
				value = d1,
				naReason = d1Reason,
				format = daysText,
				target = "playDaysD1",
				partial = false,
				detail = `{formatInteger(core.r1 or 0)} D1 returners · {d1Detail}`,
			})
		)
		local d27, d27Reason, d27Detail = playDays(ctx, core, 2, 7)
		table.insert(
			entries,
			signalEntry({
				id = "playDaysD2to7",
				label = "Play days per user: Days 2-7",
				tier = "Most important",
				window = `{returnWindow} (Σ rbx:day:2..7 / cohort)`,
				value = d27,
				naReason = d27Reason,
				format = daysText,
				target = "playDaysD2to7",
				partial = partial,
				detail = d27Detail,
			})
		)
		local d828, d828Reason, d828Detail = playDays(ctx, core, 8, ALGORITHM.PlayDayMax)
		table.insert(
			entries,
			signalEntry({
				id = "playDaysD8to28",
				label = `Play days per user: Days 8-{ALGORITHM.PlayDayMax}`,
				tier = "Most important",
				window = `{returnWindow} (Σ rbx:day:8..{ALGORITHM.PlayDayMax} / cohort)`,
				value = d828,
				naReason = d828Reason,
				format = daysText,
				target = "playDaysD8to28",
				partial = partial,
				detail = d828Detail,
			})
		)
	end
	-- 7. Playtime per user, capped at 60 min per player per day (Roblox's cap).
	local playSec = core["rbx:playSec"] or 0
	local uncapped = if dau > 0 then `{oneDecimal((core.sessionSeconds or 0) / 60 / dau)} min` else "n/a"
	table.insert(
		entries,
		signalEntry({
			id = "playtime",
			label = `Playtime per user (capped {ALGORITHM.PlayCapSeconds // 60} min/day)`,
			tier = "Most important",
			window = `per player-day, {window}`,
			value = perRbxDau(playSec / 60),
			naReason = noDau,
			format = function(minutes: number): string
				return `{oneDecimal(minutes)} min`
			end,
			target = "playtimeMinutes",
			partial = rbxPartial,
			sample = rbxSample,
			detail = `{formatInteger(playSec / 60)} capped min / {formatInteger(rbxDau)} player-days · uncapped {uncapped} (all servers)`,
		})
	)
	-- 8. Qualified play sessions per user (sessions longer than QualifiedSeconds).
	local qualified = core["rbx:session:qualified"] or 0
	local qualifiedShare = if rbxSessions > 0 then ` ({pctOf(qualified, rbxSessions)})` else ""
	local shortSessions = `under 60 s {formatInteger(core["rbx:session:lt60"] or 0)} · 61-180 s {formatInteger(
		core["rbx:session:60to180"] or 0
	)}`
	table.insert(
		entries,
		signalEntry({
			id = "qualifiedSessions",
			label = `Qualified play sessions per user (> {ALGORITHM.QualifiedSeconds} s)`,
			tier = "Important",
			window = `per player-day, {window}`,
			value = perRbxDau(qualified),
			naReason = noDau,
			format = twoDecimals,
			target = "qualifiedSessions",
			partial = rbxPartial,
			sample = rbxSample,
			detail = `{formatInteger(qualified)} qualified of {formatInteger(rbxSessions)} sessions{qualifiedShare} · {shortSessions}`,
		})
	)
	-- 9. Intentional co-play days per user.
	local coplay = core["rbx:coplay"] or 0
	table.insert(
		entries,
		signalEntry({
			id = "coplayDays",
			label = "Intentional co-play days per user",
			tier = "Important",
			window = `per player-day, {window}`,
			value = perRbxDau(coplay),
			naReason = noDau,
			format = function(fraction: number): string
				return `{twoDecimals(fraction)} days ({formatPercent(fraction)})`
			end,
			targetFormat = formatPercent,
			target = "coplayDays",
			partial = rbxPartial,
			sample = rbxSample,
			detail = `{formatInteger(coplay)} co-play player-days · followed {formatInteger(
				core["rbx:coplayVia:follow"] or 0
			)} · invited {formatInteger(core["rbx:coplayVia:invite"] or 0)} · host {formatInteger(
				core["rbx:coplayVia:host"] or 0
			)} · private server {formatInteger(core["rbx:coplayVia:private"] or 0)}`,
		})
	)
	-- 10-11. Spend days and Robux per user (pre-R122 counters: full coverage).
	local payers = core.payers or 0
	local robux = revenue.robux or 0
	local perPayer = if payers > 0 then ` · R$ {oneDecimal(robux / payers)} per payer-day` else ""
	table.insert(
		entries,
		signalEntry({
			id = "spendDays",
			label = "Spend days per user",
			tier = "Important",
			window = `per player-day, {window}`,
			value = perDau(payers),
			naReason = noDau,
			format = function(fraction: number): string
				return `{string.format("%.3f", fraction)} days ({formatPercent(fraction)})`
			end,
			targetFormat = formatPercent,
			target = "spendDays",
			partial = false,
			detail = `{formatInteger(payers)} payer-days / {formatInteger(dau)} player-days`,
		})
	)
	table.insert(
		entries,
		signalEntry({
			id = "robuxPerUser",
			label = "Robux spent per user",
			tier = "Important",
			window = `per player-day, {window}`,
			value = perDau(robux),
			naReason = noDau,
			format = function(perUser: number): string
				return `R$ {twoDecimals(perUser)}`
			end,
			target = "robuxPerUser",
			partial = false,
			detail = `R$ {formatInteger(robux)} gross / {formatInteger(dau)} player-days{perPayer}`,
		})
	)
	-- 12. Data coverage of the R122 counters (the PARTIAL verdicts above come from it).
	table.insert(entries, {
		id = "coverage",
		label = "R122 signal coverage",
		value = coverage or 0,
		display = if coverage ~= nil then formatPercent(coverage) else "n/a",
		extra = `Data · sessions in range recorded by R122+ servers (Σ rbx:session:* / sessions = {formatInteger(
			rbxSessions
		)} / {formatInteger(sessions)}) · under {formatPercent(ALGORITHM.MinCoverage)} the rbx rows above are PARTIAL (undercount)`,
		tone = if coverage == nil then "na" elseif partial then "partial" else "good",
		share = coverage or 0,
	})
	push(
		out,
		makeTable(
			"algorithm",
			"Roblox algorithm scorecard",
			"Roblox ranks Recommended for You on per-user averages of these signals (users who joined from it; Day 1 / Days 2-7 / Days 8-28). Ours cover every player in the range (directional). Bars = progress to the goal (AnalyticsConfig.Algorithm.Targets); a missing denominator is n/a, never 0.",
			entries,
			"given",
			#entries
		)
	)
end

--------------------------------------------------------------------------------------------------
-- Players
--------------------------------------------------------------------------------------------------

local SESSION_LABELS = AnalyticsLogic.bucketLabels(AnalyticsConfig.SessionBuckets, "m")
local SESSION_NUMBER_LABELS = AnalyticsLogic.countBucketLabels(AnalyticsConfig.SessionNumberBuckets)

local function playerSections(out: { Table }, ctx: Ctx)
	local core: Counters = ctx.totals.core or {}

	-- New player funnel first: the owner's first question is where new players drop.
	if (core["ftue:joined"] or 0) > 0 then
		local entries: { Entry } = {}
		for _, row in NewPlayerFunnel.rows(core, formatPercent) do
			table.insert(entries, { id = row.id, label = row.label, value = row.value, extra = row.extra })
		end
		push(
			out,
			makeTable(
				"newPlayerFunnel",
				"New player funnel",
				"Tracked new players only; each step once per player (any session). % of joined, % of the previous step, share reached in session 1, avg play minutes at reach.",
				entries,
				"given",
				#entries
			)
		)
	end

	-- First sessions at leave: furthest step + length.
	do
		local entries: { Entry } = {}
		local left = prefixEntries(core, "ftueLeft:", NewPlayerFunnel.label)
		local total = 0
		for _, entry in left do
			total += entry.value
		end
		-- Reading order (R78: chronological main path, then the side steps).
		local order: { [string]: number } = {}
		for index, step in NewPlayerFunnel.Order do
			order[step] = index
		end
		table.sort(left, function(a: Entry, b: Entry): boolean
			return (order[a.id] or 0) < (order[b.id] or 0)
		end)
		for _, entry in left do
			entry.extra = `{pctOf(entry.value, total)} of first sessions stopped here`
			table.insert(entries, entry)
		end
		for _, entry in labelEntries(core, "ftueLen:", SESSION_LABELS) do
			entry.id = `len:{entry.id}`
			entry.label = `First session length {entry.label}`
			table.insert(entries, entry)
		end
		push(
			out,
			makeTable(
				"firstSessions",
				"First sessions: furthest step and length",
				"Where tracked new players' FIRST session ended (furthest funnel step) and how long it lasted.",
				entries,
				"given",
				#entries
			)
		)
	end

	-- D1 / D7 by first-day milestone (with vs without).
	do
		local entries: { Entry } = {}
		local base = core["cohort:all"] or 0
		local baseR1 = core["r1:all"] or 0
		local baseR7 = core["r7:all"] or 0
		if base > 0 then
			table.insert(entries, {
				id = "all",
				label = "All tracked new players",
				value = base,
				extra = `D1 {pctOf(baseR1, base)} · D7 {pctOf(baseR7, base)} (raw counts in range; cohort days differ)`,
			})
			for _, milestone in AnalyticsConfig.FirstDay.Milestones do
				local cohort = core[`cohort:{milestone}`] or 0
				if cohort > 0 then
					local r1 = core[`r1:{milestone}`] or 0
					local r7 = core[`r7:{milestone}`] or 0
					local withoutCohort = base - cohort
					local withoutR1 = baseR1 - r1
					table.insert(entries, {
						id = milestone,
						label = `Reached "{milestone}" on day one`,
						value = cohort,
						extra = `{pctOf(cohort, base)} of new · D1 {pctOf(r1, cohort)} vs {pctOf(
							math.max(0, withoutR1),
							math.max(0, withoutCohort)
						)} without · D7 {pctOf(r7, cohort)}`,
					})
				end
			end
		end
		push(
			out,
			makeTable(
				"d1ByMilestone",
				"D1 / D7 by first-day milestone",
				"Day-one milestones of tracked new players vs their D1 / D7 return (joins only). Cohort and return days differ inside a short range: read 7d / 30d.",
				entries,
				"given",
				#entries
			)
		)
	end

	push(
		out,
		makeTable(
			"uniques",
			"Unique players per surface (player-days)",
			"Each player counts once per UTC day per surface, across servers.",
			prefixEntries(core, "uniq:"),
			"value"
		)
	)

	do
		local entries = labelEntries(core, "len:", SESSION_LABELS)
		push(
			out,
			makeTable(
				"sessionLength",
				"Session length",
				`{formatInteger(core.sessions or 0)} sessions · avg {AnalyticsReport.formatDuration(
					if (core.sessions or 0) > 0 then (core.sessionSeconds or 0) / (core.sessions or 1) else 0
				)}`,
				entries,
				"given",
				#entries
			)
		)
	end

	do
		local entries = labelEntries(core, "sessNo:", SESSION_NUMBER_LABELS)
		push(
			out,
			makeTable(
				"sessionNumber",
				"Sessions by the player's lifetime session number",
				"How many sessions are a player's 1st, 2nd, 3rd ... (a falling curve = players not coming back).",
				entries,
				"given",
				#entries
			)
		)
	end

	-- Devices: sessions, average length, new players and D1 per class.
	do
		local entries: { Entry } = {}
		local classes = table.clone(AnalyticsConfig.DeviceClasses)
		table.insert(classes, "unknown")
		for _, class in classes do
			local sessions = core[`device:{class}`] or 0
			if sessions > 0 then
				local seconds = core[`devSeconds:{class}`] or 0
				local newPlayers = core[`devNew:{class}`] or 0
				local r1 = core[`devR1:{class}`] or 0
				table.insert(entries, {
					id = class,
					label = class,
					value = sessions,
					extra = `avg {AnalyticsReport.formatDuration(seconds / sessions)} · new {newPlayers} · D1 joins {r1}`
						.. ` · carry {core[`devR1carry:{class}`] or 0}`,
				})
			end
		end
		push(
			out,
			makeTable(
				"devices",
				"Devices",
				"Sessions by the client's device claim. D1 joins per device are raw counts in range (pair with devNew of the day before).",
				entries,
				"value"
			)
		)
	end

	do
		local entries: { Entry } = {}
		for hour = 0, 23 do
			local label = string.format("%02d", hour)
			local value = core[`hour:{label}`] or 0
			if value > 0 then
				table.insert(entries, { id = label, label = `{label}:00 UTC`, value = value })
			end
		end
		push(out, makeTable("hours", "Sessions by UTC start hour", "", entries, "given", 24))
	end
end

--------------------------------------------------------------------------------------------------
-- Tycoon
--------------------------------------------------------------------------------------------------

local function tycoonSections(out: { Table }, ctx: Ctx)
	local tycoon: Counters = ctx.totals.tycoon or {}
	if next(tycoon) == nil then
		return
	end
	local labelOf = ctx.labelOf

	-- Area pacing: first-run minutes into the run vs the cumulative design targets.
	do
		local entries: { Entry } = {}
		local cumulative = 0
		local targets = TycoonConfig.Pacing.TargetMinutes
		for index, area in TycoonConfig.Areas do
			-- Target minutes to OPEN area n = sum of the targets of areas 1..n-1.
			local target = cumulative
			cumulative += targets[index] or 0
			local reached = tycoon[`area:{index}`] or 0
			local n = tycoon[`areaN:{index}`] or 0
			if index >= 2 and (reached > 0 or n > 0) then
				local minutes = if n > 0 then (tycoon[`areaAt:{index}`] or 0) / n / 60 else 0
				table.insert(entries, {
					id = tostring(index),
					label = `{index}. {area.name}`,
					value = n,
					display = if n > 0 then `{oneDecimal(minutes)} min` else "n/a",
					extra = `first-run reaches {n} · target {target} min ({if n > 0 and target > 0
						then formatPercent(minutes / target)
						else "n/a"} of target) · all-run reaches {reached}`,
				})
			end
		end
		push(
			out,
			makeTable(
				"areaPacing",
				"Area pacing (first run)",
				"Average play minutes into the FIRST run when each area opened (areaAt / areaN) vs TycoonConfig.Pacing (cumulative target). >100% = slower than designed.",
				entries,
				"given",
				#entries
			)
		)
	end

	push(
		out,
		makeTable(
			"leaveArea",
			"Where sessions end (area at leave)",
			"Every session's tycoon area when the player left.",
			prefixEntries(tycoon, "leaveArea:", function(id: string): string
				return labelOf("area", id)
			end),
			"given",
			#TycoonConfig.Areas
		)
	)

	-- Pads: most bought (all runs) with first-run avg minutes.
	do
		local entries: { Entry } = {}
		for key, value in tycoon do
			local padId = string.match(key, "^pad:(.+)$")
			if padId ~= nil then
				local n = tycoon[`padN:{padId}`] or 0
				local minutes = if n > 0 then (tycoon[`padAt:{padId}`] or 0) / n / 60 else -1
				table.insert(entries, {
					id = padId,
					label = labelOf("pad", padId),
					value = value,
					extra = if minutes >= 0
						then `first run: {n} buys at avg {oneDecimal(minutes)} min`
						else "no first-run buys",
				})
			end
		end
		local kinds = prefixEntries(tycoon, "padKind:")
		local kindText: { string } = {}
		table.sort(kinds, function(a: Entry, b: Entry): boolean
			return a.value > b.value
		end)
		for _, kind in kinds do
			table.insert(kindText, `{kind.id} {formatInteger(kind.value)}`)
		end
		push(out, makeTable("pads", "Pad purchases", `By kind: {table.concat(kindText, " · ")}`, entries, "value"))
	end

	-- Slowest pads: the first-run time gap from the previous pad in the linear chain.
	do
		local entries: { Entry } = {}
		local previousAt: number? = nil
		local previousId: string? = nil
		for _, pad in TycoonConfig.PadOrder do
			local n = tycoon[`padN:{pad.id}`] or 0
			if n > 0 then
				local at = (tycoon[`padAt:{pad.id}`] or 0) / n
				if previousAt ~= nil then
					local gap = math.max(0, at - previousAt)
					table.insert(entries, {
						id = pad.id,
						label = labelOf("pad", pad.id),
						value = math.floor(gap),
						display = AnalyticsReport.formatDuration(gap),
						extra = `after {previousId or "?"} · {n} first-run buyers · cost {shortNumber(pad.cost)}`,
					})
				end
				previousAt, previousId = at, pad.id
			end
		end
		push(
			out,
			makeTable(
				"padGaps",
				"Slowest pads (first-run time since the previous pad)",
				"Average play time between consecutive pads on the first run: the biggest gaps are where the economy stalls. Survivorship: later pads only include players who got there.",
				entries,
				"value"
			)
		)
	end

	-- Producers: clicks, upgrades, levels, manager, income split.
	do
		local entries: { Entry } = {}
		for _, producer in TycoonConfig.Producers do
			local id = producer.id
			local clicks = tycoon[`click:{id}`] or 0
			local upgrades = tycoon[`upgrade:{id}`] or 0
			local clickCash = tycoon[`incomeP:{id}:click`] or 0
			local autoCash = tycoon[`incomeP:{id}:auto`] or 0
			if clicks + upgrades + clickCash + autoCash + (tycoon[`manager:{id}`] or 0) > 0 then
				table.insert(entries, {
					id = id,
					label = producer.name,
					value = upgrades,
					extra = `clicks {formatInteger(clicks)} · levels bought {formatInteger(tycoon[`levels:{id}`] or 0)}`
						.. ` · managers {formatInteger(tycoon[`manager:{id}`] or 0)}`
						.. ` · cash {shortNumber(clickCash + autoCash)} ({pctOf(autoCash, clickCash + autoCash)} automated)`,
				})
			end
		end
		push(
			out,
			makeTable(
				"producers",
				"Producers (value = upgrade purchases)",
				`Upgrade modes: 1x {formatInteger(tycoon["upgradeMode:1"] or 0)} · 10x {formatInteger(
					tycoon["upgradeMode:10"] or 0
				)} · max {formatInteger(tycoon["upgradeMode:max"] or 0)}`,
				entries,
				"given",
				#entries
			)
		)
	end

	-- Income share.
	do
		local click = tycoon["income:click"] or 0
		local auto = tycoon["income:auto"] or 0
		local offline = tycoon["income:offline"] or 0
		local total = click + auto + offline
		local entries: { Entry } = {}
		for _, item in
			{
				{ "click", "Clicked cycles", click },
				{ "auto", "Automated (managed)", auto },
				{ "offline", "Offline payouts", offline },
			}
		do
			local amount = item[3] :: number
			if amount > 0 then
				table.insert(entries, {
					id = item[1] :: string,
					label = item[2] :: string,
					value = if total > 0 then amount / total * 1000 else 0,
					display = shortNumber(amount),
					extra = pctOf(amount, total),
				})
			end
		end
		push(
			out,
			makeTable(
				"incomeShare",
				"Production income share",
				`Cash produced by source (total {shortNumber(total)}); clicks {formatInteger(tycoon.clicks or 0)}.`,
				entries,
				"given",
				3
			)
		)
	end

	push(
		out,
		makeTable(
			"levelMarks",
			"Producer level marks reached",
			"Producers that crossed a level mark (AnalyticsConfig.Tycoon.LevelMarks).",
			prefixEntries(tycoon, "lvl:"),
			"value"
		)
	)

	-- Tutorial (server steps + client arrow claims).
	do
		local entries: { Entry } = {}
		for step = 1, AnalyticsConfig.Tycoon.MaxTutorialStep do
			local server = tycoon[`tut:{step}`] or 0
			local client = tycoon[`tutClient:{step}`] or 0
			if server + client > 0 then
				table.insert(entries, {
					id = tostring(step),
					label = `Tutorial step {step}`,
					value = server,
					extra = `client arrow shown {formatInteger(client)}`,
				})
			end
		end
		push(
			out,
			makeTable(
				"tutorial",
				"Tutorial steps",
				`Server steps reached (once per player per session); completed {formatInteger(tycoon.tutDone or 0)}.`,
				entries,
				"given",
				AnalyticsConfig.Tycoon.MaxTutorialStep
			)
		)
	end

	-- Rebirths.
	do
		local rebirths = tycoon.rebirth or 0
		local entries: { Entry } = {}
		if rebirths > 0 then
			table.insert(entries, {
				id = "rebirths",
				label = "Rebirths",
				value = rebirths,
				extra = `avg run {AnalyticsReport.formatDuration((tycoon.rebirthSec or 0) / rebirths)} · tokens {shortNumber(
					tycoon.rebirthTokens or 0
				)}`,
			})
		end
		for _, entry in prefixEntries(tycoon, "rebirthN:") do
			entry.id = `n:{entry.id}`
			entry.label = `Reached rebirth #{entry.label}`
			table.insert(entries, entry)
		end
		for _, entry in prefixEntries(tycoon, "runB:") do
			entry.id = `run:{entry.id}`
			entry.label = `Run length {entry.label}`
			table.insert(entries, entry)
		end
		for _, entry in prefixEntries(tycoon, "rebirthShop:") do
			entry.id = `shop:{entry.id}`
			entry.label = `Rebirth shop: {entry.label}`
			table.insert(entries, entry)
		end
		push(out, makeTable("rebirths", "Rebirths", "", entries, "given", #entries))
	end

	-- Offline earnings.
	do
		local pays = tycoon["offline:pay"] or 0
		local entries: { Entry } = {}
		if pays > 0 then
			table.insert(entries, {
				id = "pay",
				label = "Offline payouts",
				value = pays,
				extra = `avg absence {oneDecimal((tycoon.offlineSec or 0) / pays / 3600)} h · cash {shortNumber(
					tycoon.offlineCash or 0
				)} · doubled {pctOf(tycoon["offline:double"] or 0, pays)}`,
			})
		end
		for _, entry in prefixEntries(tycoon, "offlineB:") do
			entry.id = `b:{entry.id}`
			entry.label = `Absence {entry.label}`
			table.insert(entries, entry)
		end
		push(out, makeTable("offline", "Offline earnings", "", entries, "given", #entries))
	end

	-- Extras: features, teleports, renames, skips, plots.
	do
		local entries: { Entry } = {}
		for _, prefix in { "feature:", "teleport:", "padSkip:", "plot:", "renamePlot:" } do
			for _, entry in prefixEntries(tycoon, prefix) do
				entry.id = prefix .. entry.id
				entry.label = prefix .. entry.label
				table.insert(entries, entry)
			end
		end
		for _, single in { "rename", "teleportHub" } do
			if (tycoon[single] or 0) > 0 then
				table.insert(entries, { id = single, label = single, value = tycoon[single] })
			end
		end
		push(out, makeTable("tycoonExtras", "Features, teleports, renames, skips, plots", "", entries, "value"))
	end
end

--------------------------------------------------------------------------------------------------
-- Revenue
--------------------------------------------------------------------------------------------------

--[[
	" (<pct><suffix>)" of a / b, or "" when b is 0 — a row with no denominator shows no percentage
	instead of an empty "()" or a fake 0 %.
	Example: pctTail(30, 100) --> " (30%)"; pctTail(5, 20, " of prompts") --> " (25% of prompts)";
	         pctTail(4, 0) --> ""
]]
local function pctTail(a: number, b: number, suffix: string?): string
	local pct = pctOf(a, b)
	return if pct ~= "" then ` ({pct}{suffix or ""})` else ""
end

--[[
	True when `counters` hold at least one key "<prefix><id>:click" (owner R137). BUY presses were
	not recorded before R137, so a range without ANY click key has no click producer: its click
	cells read "n/a", never "0 (0%)" (a missing producer is never 0, as in the scorecard).
	Example: hasClickKey({ ["funnel:VIP:click"] = 2 }, "^funnel:.+:click$") --> true
]]
local function hasClickKey(counters: Counters, pattern: string): boolean
	for key in counters do
		if string.match(key, pattern) ~= nil then
			return true
		end
	end
	return false
end

local function revenueSections(out: { Table }, ctx: Ctx)
	local revenue: Counters = ctx.totals.revenue or {}
	if next(revenue) == nil then
		return
	end
	local labelOf = ctx.labelOf
	local totalRobux = revenue.robux or 0

	-- Products and passes by Robux.
	do
		local entries: { Entry } = {}
		for key, robux in revenue do
			local kind, id = string.match(key, "^(%a+):(.+):robux$")
			if (kind == "product" or kind == "pass") and id ~= nil then
				local count = revenue[`{kind}:{id}:count`] or 0
				local prompts = revenue[`prompt:{id}`] or 0
				table.insert(entries, {
					id = id,
					label = labelOf(kind, id),
					value = robux,
					display = `R$ {formatInteger(robux)}`,
					extra = `{formatInteger(count)} sold · {pctOf(robux, totalRobux)} of Robux · prompt → buy {pctOf(
						count,
						prompts
					)}`,
				})
			end
		end
		-- Bought but no Robux recorded (0-price / unknown): still listed.
		for key, count in revenue do
			local kind, id = string.match(key, "^(%a+):(.+):count$")
			if (kind == "product" or kind == "pass") and id ~= nil and revenue[`{kind}:{id}:robux`] == nil then
				table.insert(
					entries,
					{ id = id, label = labelOf(kind, id), value = 0, extra = `{formatInteger(count)} sold` }
				)
			end
		end
		push(
			out,
			makeTable(
				"products",
				"Products & passes (Robux)",
				`R$ {formatInteger(totalRobux)} from {formatInteger(revenue.purchases or 0)} purchases.`,
				entries,
				"value"
			)
		)
	end

	-- Purchase funnel per key.
	do
		local keys: { [string]: boolean } = {}
		for key in revenue do
			local id = string.match(key, "^funnel:(.+):%a+$")
			if id ~= nil then
				keys[id] = true
			end
		end
		-- R137: no click key anywhere in the range → click n/a on every row (not recorded yet).
		local clicksRecorded = hasClickKey(revenue, "^funnel:.+:click$")
		local entries: { Entry } = {}
		for id in keys do
			local shown = revenue[`funnel:{id}:shown`] or 0
			local click = revenue[`funnel:{id}:click`] or 0
			local prompt = revenue[`funnel:{id}:prompt`] or 0
			local bought = revenue[`funnel:{id}:bought`] or 0
			local clickText = if clicksRecorded
				then `click {formatInteger(click)}{pctTail(click, shown)}`
				else "click n/a"
			table.insert(entries, {
				id = id,
				label = labelOf("product", id),
				value = bought,
				extra = `shown {formatInteger(shown)} → {clickText} → prompt {formatInteger(prompt)} → bought {formatInteger(
					bought
				)}{pctTail(bought, prompt, " of prompts")}`,
			})
		end
		push(
			out,
			makeTable(
				"purchaseFunnel",
				"Purchase funnel by product",
				"shown = offer card rendered (client claim) or announced; click = BUY pressed on an offer surface (Shop, offer DEAL card, Welcome Back; recorded since R137, n/a when the range has none); prompt = Roblox prompt opened from any surface; bought = purchase completed.",
				entries,
				"value"
			)
		)
	end

	-- By source / device / area / rebirth tier.
	local function split(prefix: string, id: string, title: string, note: string, labelFn: ((string) -> string)?)
		local entries: { Entry } = {}
		for _, entry in prefixEntries(revenue, prefix, labelFn) do
			entry.display = `R$ {formatInteger(entry.value)}`
			entry.extra = pctOf(entry.value, totalRobux)
			table.insert(entries, entry)
		end
		push(out, makeTable(id, title, note, entries, "value"))
	end
	split(
		"robuxBySource:",
		"bySource",
		"Revenue by prompt source",
		"Purchases credited to the surface of their latest prompt (unknown = no prompt seen in this server).",
		nil
	)
	split("robuxByDevice:", "byDevice", "Revenue by device", "", nil)
	split(
		"robuxByArea:",
		"byArea",
		"Revenue by the buyer's tycoon area",
		"Where in the run players spend.",
		function(id: string): string
			return labelOf("area", id)
		end
	)
	split("robuxByRebirth:", "byRebirth", "Revenue by the buyer's rebirth count", "", nil)

	-- Abandoned prompts.
	do
		local entries: { Entry } = {}
		for key, value in revenue do
			local id = string.match(key, "^promptClosed:([^:]+)$")
			if id ~= nil then
				table.insert(entries, {
					id = id,
					label = labelOf("product", id),
					value = value,
					extra = `{pctOf(value, revenue[`prompt:{id}`] or 0)} of prompts`,
				})
			end
		end
		local dwell: { string } = {}
		for _, label in AnalyticsConfig.DwellLabels do
			local n = 0
			for key, value in revenue do
				if string.sub(key, 1, 12) == "promptDwell:" and string.sub(key, -#label - 1) == `:{label}` then
					n += value
				end
			end
			table.insert(dwell, `{label} {formatInteger(n)}`)
		end
		push(
			out,
			makeTable(
				"abandoned",
				"Prompts closed without buying",
				`Dwell before closing: {table.concat(dwell, " · ")} (seconds).`,
				entries,
				"value"
			)
		)
	end

	push(
		out,
		makeTable(
			"firstBuy",
			"First ever purchase",
			"The product / pass each new payer bought first.",
			prefixEntries(revenue, "firstBuy:", function(id: string): string
				return labelOf("product", id)
			end),
			"value"
		)
	)

	-- Offers: impressions and clicks.
	do
		local entries: { Entry } = {}
		local ids: { [string]: boolean } = {}
		for key in revenue do
			local id = string.match(key, "^offer:(.+):%a+$") or string.match(key, "^offers:card:(.+)$")
			if id ~= nil then
				ids[id] = true
			end
		end
		-- R137: no offer click key anywhere in the range → "clicks n/a" (not recorded yet), not 0.
		local clicksRecorded = hasClickKey(revenue, "^offer:.+:click$")
		for id in ids do
			local seen = (revenue[`offer:{id}:shown`] or 0) + (revenue[`offers:card:{id}`] or 0)
			local clicks = revenue[`offer:{id}:click`] or 0
			local ctr = pctOf(clicks, seen)
			table.insert(entries, {
				id = id,
				label = labelOf("product", id),
				value = seen,
				extra = if not clicksRecorded
					then "clicks n/a"
					elseif ctr ~= "" then `clicks {formatInteger(clicks)} (CTR {ctr})`
					else `clicks {formatInteger(clicks)}`,
			})
		end
		local opens: { string } = {}
		for _, entry in prefixEntries(revenue, "offers:open:") do
			table.insert(opens, `{entry.id} {formatInteger(entry.value)}`)
		end
		push(
			out,
			makeTable(
				"offers",
				"Offer impressions and clicks",
				if #opens > 0 then `Offer surfaces opened: {table.concat(opens, " · ")}` else "",
				entries,
				"value"
			)
		)
	end
end

--------------------------------------------------------------------------------------------------
-- Economy
--------------------------------------------------------------------------------------------------

local function economySections(out: { Table }, ctx: Ctx)
	local economy: Counters = ctx.totals.economy or {}
	if next(economy) == nil then
		return
	end
	for _, currency in AnalyticsConfig.Economy.Currencies do
		for _, direction in { "earn", "spend" } do
			local total = economy[`{direction}:{currency}`] or 0
			if total > 0 then
				local entries: { Entry } = {}
				for _, entry in prefixEntries(economy, `{direction}:{currency}:`) do
					if string.find(entry.id, ":", 1, true) == nil then
						local events = economy[`n:{direction}:{currency}:{entry.id}`] or 0
						entry.display = shortNumber(entry.value)
						entry.extra = `{pctOf(entry.value, total)} · {formatInteger(events)} events`
						table.insert(entries, entry)
					end
				end
				push(
					out,
					makeTable(
						`{direction}_{currency}`,
						`{if direction == "earn" then "Sources" else "Sinks"}: {currency}`,
						`Total {shortNumber(total)} by reason.`,
						entries,
						"value"
					)
				)
			end
		end
	end
end

--------------------------------------------------------------------------------------------------
-- Systems (retention, pets, crates, attack, event, social)
--------------------------------------------------------------------------------------------------

-- A whole family as one ranked table (keys as rows), for the smaller system families.
local function familyTable(out: { Table }, ctx: Ctx, family: string, id: string, note: string)
	local counters: Counters = ctx.totals[family] or {}
	local entries: { Entry } = {}
	for key, value in counters do
		table.insert(entries, { id = key, label = key, value = value })
	end
	push(out, makeTable(id, AnalyticsConfig.FamilyTitles[family] or family, note, entries, "value", 40))
end

local function systemSections(out: { Table }, ctx: Ctx)
	local retention: Counters = ctx.totals.retention or {}
	-- Retention systems without the screen-open rows (they get their own table).
	do
		local entries: { Entry } = {}
		for key, value in retention do
			-- (WHAT'S NEW "notes:*" rows get their own table below.)
			if
				string.sub(key, 1, 5) ~= "open:"
				and string.sub(key, 1, 9) ~= "openFrom:"
				and string.sub(key, 1, 6) ~= "notes:"
			then
				table.insert(entries, { id = key, label = key, value = value })
			end
		end
		push(
			out,
			makeTable(
				"retentionSystems",
				AnalyticsConfig.FamilyTitles.retention,
				"Daily streak claims by day, time gifts by index, wheel spins / slices, codes, group, notifications, Welcome Back choices.",
				entries,
				"value",
				40
			)
		)
	end
	do
		local entries: { Entry } = {}
		for _, entry in prefixEntries(retention, "open:") do
			local sources: { string } = {}
			for key, value in retention do
				local screen, source = string.match(key, "^openFrom:([^:]+):(.+)$")
				if screen == entry.id and source ~= nil then
					table.insert(sources, `{source} {formatInteger(value)}`)
				end
			end
			table.sort(sources)
			entry.extra = table.concat(sources, " · ")
			table.insert(entries, entry)
		end
		push(out, makeTable("screens", "Screens opened (client claim)", "", entries, "value"))
	end
	do
		-- WHAT'S NEW (owner R58, ChangeNotesService): one row per note — times shown (auto pop-up
		-- vs HUD chip / Settings), closes, seen marks, CTA presses and the average seconds open.
		local perNote: { [string]: { [string]: number } } = {}
		local lengths: { string } = {}
		for key, value in retention do
			local verb, rest = string.match(key, "^notes:([%a]+):(.+)$")
			if verb == "openLen" and rest ~= nil then
				table.insert(lengths, `{rest} {formatInteger(value)}`)
			elseif verb ~= nil and rest ~= nil then
				local id, source = string.match(rest, "^([^:]+):(.+)$")
				local noteId = id or rest
				local stats = perNote[noteId]
				if stats == nil then
					stats = {}
					perNote[noteId] = stats
				end
				local field = if verb == "shown" and source ~= nil then `shown_{source}` else verb
				stats[field] = (stats[field] or 0) + value
			end
		end
		local entries: { Entry } = {}
		for noteId, stats in perNote do
			local auto, menu = stats.shown_auto or 0, stats.shown_menu or 0
			local closed = stats.closed or 0
			local average = if closed > 0 then `{oneDecimal((stats.openSec or 0) / closed)} s` else "-"
			table.insert(entries, {
				id = noteId,
				label = noteId,
				value = auto + menu,
				extra = `auto {formatInteger(auto)} · chip {formatInteger(menu)} · closed {formatInteger(closed)} · seen {formatInteger(
					stats.seen or 0
				)} · cta {formatInteger(stats.cta or 0)} · avg open {average}`,
			})
		end
		table.sort(lengths)
		push(
			out,
			makeTable(
				"whatsNew",
				"What's New (change notes)",
				if #lengths > 0 then `Time open: {table.concat(lengths, " · ")}` else "",
				entries,
				"value"
			)
		)
	end
	familyTable(out, ctx, "pets", "pets", "Hatches per egg, rarity split, pets by id, equips / deletes, pets at leave.")
	familyTable(out, ctx, "crates", "crates", "Crates opened by payment, rewards by kind and rarity, boosts.")
	do
		local attack: Counters = ctx.totals.attack or {}
		local launches = sumPrefix(attack, "launch:")
		local note = if launches > 0
			then `Launches {formatInteger(launches)} · intercepted {pctOf(attack.intercept or 0, launches)} · hit {pctOf(
				attack.hit or 0,
				launches
			)}`
			else ""
		familyTable(out, ctx, "attack", "attack", note)
	end
	familyTable(
		out,
		ctx,
		"event",
		"event",
		"Golden Turkeys, acorns, stickers, sheet redemptions, event eggs, decorations."
	)
	do
		local social: Counters = ctx.totals.social or {}
		local minutes, weighted = 0, 0
		for n = 0, AnalyticsConfig.Social.MaxPlayers do
			local value = social[`players:{n}`] or 0
			minutes += value
			weighted += value * n
		end
		familyTable(
			out,
			ctx,
			"social",
			"social",
			if minutes > 0
				then `Average players per server {oneDecimal(weighted / minutes)} over {formatInteger(minutes)} server-minutes.`
				else ""
		)
	end
	-- Owner R90 Mega Lever + Tip Jar (Server/Kinetic): pulls / payouts / refusals per world.
	do
		local kinetic: Counters = ctx.totals.kinetic or {}
		local pulls = sumPrefix(kinetic, "pull:")
		local jars = sumPrefix(kinetic, "jar:")
		familyTable(
			out,
			ctx,
			"kinetic",
			"kinetic",
			if pulls + jars > 0
				then `Mega Lever pulls {formatInteger(pulls)} · Tip Jar payouts {formatInteger(jars)} (amounts in each world's currency).`
				else ""
		)
	end
end

--------------------------------------------------------------------------------------------------
-- Health and data quality
--------------------------------------------------------------------------------------------------

local function healthSections(out: { Table }, ctx: Ctx)
	local health: Counters = ctx.totals.health or {}
	if next(health) == nil then
		return
	end
	local function rowsTable(
		id: string,
		title: string,
		note: string,
		rows: { ServerHealthLogic.Row },
		order: "value" | "given"
	)
		local entries: { Entry } = {}
		for _, row in rows do
			table.insert(
				entries,
				{ id = row.id, label = row.label, value = row.value, display = row.display, extra = row.extra }
			)
		end
		push(out, makeTable(id, title, note, entries, order, if order == "given" then #entries else nil))
	end
	rowsTable(
		"serverHealth",
		"Server health",
		"Summed over every live server minute in the range.",
		ServerHealthLogic.rows(health, AnalyticsConfig.Health),
		"given"
	)
	local systems: { ServerHealthLogic.Row } = {}
	local remotes: { ServerHealthLogic.Row } = {}
	for _, row in ServerHealthLogic.systemRows(health) do
		if string.sub(row.id, 1, 3) == "rx:" then
			table.insert(remotes, row)
		else
			table.insert(systems, row)
		end
	end
	rowsTable(
		"serverSystems",
		"Server systems (Luau time)",
		"ms of Luau per second of server time, per system loop.",
		systems,
		"value"
	)
	rowsTable(
		"remoteTraffic",
		"Remote traffic (server → clients)",
		"KB per server-second per remote (estimate).",
		remotes,
		"value"
	)
	local perf = ClientPerfLogic.rows(health)
	local perfEntries: { Entry } = {}
	for _, row in perf do
		table.insert(
			perfEntries,
			{ id = row.id, label = row.label, value = row.value, display = row.display, extra = row.extra }
		)
	end
	push(
		out,
		makeTable(
			"clientPerf",
			"Client performance by device",
			"Client claims (validated + clamped).",
			perfEntries,
			"value"
		)
	)
	local memory = ClientPerfLogic.memoryRows(health)
	local memoryEntries: { Entry } = {}
	for _, row in memory do
		table.insert(
			memoryEntries,
			{ id = row.id, label = row.label, value = row.value, display = row.display, extra = row.extra }
		)
	end
	push(
		out,
		makeTable(
			"clientMemory",
			"Client memory by device",
			"Client claims (validated + clamped).",
			memoryEntries,
			"value"
		)
	)
	-- R122 (W-R122-boot, wire v4): loading-screen step seconds + hand-off reasons per device class.
	local bootEntries: { Entry } = {}
	for _, row in ClientPerfLogic.bootRows(health) do
		table.insert(
			bootEntries,
			{ id = row.id, label = row.label, value = row.value, display = row.display, extra = row.extra }
		)
	end
	push(out, makeTable("clientBoot", "Client boot steps by device", ClientPerfLogic.BootNote, bootEntries, "value"))
end

local function dataSections(out: { Table }, ctx: Ctx)
	local core: Counters = ctx.totals.core or {}
	-- Builds: per release / place version, the headline metrics.
	do
		local byBuild: { [string]: Counters } = {}
		for key, value in core do
			local identity, metric = BuildMetrics.parse(key)
			if identity ~= nil and metric ~= nil then
				local map = byBuild[identity]
				if map == nil then
					map = {}
					byBuild[identity] = map
				end
				map[metric] = value
			end
		end
		local entries: { Entry } = {}
		for identity, metrics in byBuild do
			table.insert(entries, {
				id = identity,
				label = identity,
				value = metrics.sessions or 0,
				extra = `dau {formatInteger(metrics.dau or 0)} · new {formatInteger(metrics.new or 0)} · D1 {formatInteger(
					metrics.r1 or 0
				)} · funnel joined {formatInteger(metrics["ftue:joined"] or 0)} → manager {formatInteger(
					metrics["ftue:manager"] or 0
				)} → area2 {formatInteger(metrics["ftue:area2"] or 0)} · R$ {formatInteger(metrics.robux or 0)}`,
			})
		end
		push(
			out,
			makeTable(
				"builds",
				"Builds (release : place version)",
				"The same headline counters split by the server build that recorded them (value = sessions).",
				entries,
				"value"
			)
		)
	end
	-- Data quality: refusals, diverted events, dropped batches.
	do
		local entries: { Entry } = {}
		for _, family in AnalyticsConfig.Families do
			for key, value in ctx.totals[family] or {} do
				local head = string.sub(key, 1, 4)
				if head == "ops:" or head == "npm:" or string.sub(key, 1, 6) == "staff:" then
					table.insert(entries, { id = `{family}:{key}`, label = `{family} · {key}`, value = value })
				end
			end
		end
		push(
			out,
			makeTable(
				"dataQuality",
				"Data quality (refused / diverted / dropped)",
				"ops:badKey = undocumented recorder keys (caller bug); ops:clientRefused = rejected client reports; npm / staff = diverted admin events; ops:flushDropped = lost batches.",
				entries,
				"value"
			)
		)
	end
end

--[[
	Every report section for the range, in report order (AnalyticsLogic.summarize appends the
	retention table before and the coverage table after).
	@param ctx the summary context (totals, labelOf, range days)
	@return tables (only those with rows)
]]
function ReportSections.build(ctx: Ctx): { Table }
	local out: { Table } = {}
	-- R122: the Roblox algorithm scorecard first (right after Retention): the owner's top read.
	algorithmSection(out, ctx)
	playerSections(out, ctx)
	tycoonSections(out, ctx)
	WorldSections.build(out, ctx)
	revenueSections(out, ctx)
	economySections(out, ctx)
	systemSections(out, ctx)
	healthSections(out, ctx)
	dataSections(out, ctx)
	return out
end

return table.freeze(ReportSections)
