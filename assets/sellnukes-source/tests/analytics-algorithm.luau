--!strict
--[[
	Owner R122 "Roblox algorithm scorecard" regressions (lune run tests/analytics-algorithm). Real
	AnalyticsLogic.plan / summarize + ReportSections + AnalyticsReport (parse, toText) on the
	hand-made range of tests/analytics-fixtures/AlgorithmFixture.

	Proves:
	  1. Plan: every cohort offset 1..Algorithm.PlayDayMax is loaded (play days D2-7 / D8-28).
	  2. The "algorithm" table right after Retention, its fixed row order, every value and verdict
	     tone vs AnalyticsConfig.Algorithm.Targets, attainment bars, per-device bounce details.
	  3. D8-28 is n/a until the analytics history covers its cohorts, then a number.
	  4. A mixed-build range (Σ rbx:session:* < MinCoverage of sessions): without build slices the
	     per-player-day rbx rows say PARTIAL DATA; rows from pre-R122 counters (D1, spend days,
	     Robux) keep their verdicts; bounce keeps its real verdict (its denominator is the R122+
	     servers' own classified first sessions, R135) with a SAMPLE note.
	 4b. R135: with build slices, playtime / qualified sessions / co-play divide by the R122+
	     builds' player-days (real verdict + SAMPLE note), clamped to the range's player-days;
	     the live 2026-11-01 report shape (bounce 29 of 136, not of 489) reads 21 %.
	  5. Missing denominators are n/a, never 0 (no player-days, no joined new players).
	  6. No players in the range: no scorecard (the empty report stays retention + coverage).
	  7. Parser: tones survive a JSON round trip, unknown tones are dropped.
	  8. COPY FOR AI: the section, the verdict beside the value, info rows without a label,
	     exporter version 2 and analyst question 9.
	  9. Table budget: the worst-case report (every fixed table incl. R122 algorithm + clientBoot,
	     4 per extra world, earn / spend per economy currency) fits AnalyticsConfig.ReportMaxTables.
	 10. R122 clientBoot (W-R122-boot wire v4): "Client boot steps by device" right after Client
	     memory once boot reports exist, absent without them.
]]

local serde = require("@lune/serde")
local Loader = require("./analytics-fixtures/Loader")
local Fixture = require("./analytics-fixtures/AlgorithmFixture")
local env = Loader.new()
local check, done = Loader.checker()

local DAY = 20758 -- 2026-11-01
env.setTime(DAY * 86400 + 15 * 3600)

local AnalyticsConfig = env.load("src/shared/Config/AnalyticsConfig")
local AnalyticsReport = env.load("src/shared/Analytics/AnalyticsReport")
local AnalyticsLogic = env.load("src/server/Analytics/AnalyticsLogic")
local ReportSections = env.load("src/server/Analytics/ReportSections")
local Reports = env.load("src/server/Analytics/Reports")

local ALGORITHM = AnalyticsConfig.Algorithm

-- Summarizes the fixture over 7 days with the analytics history starting at `firstDay`.
local function summarize(firstDay: number, options: any?): any
	local plan = AnalyticsLogic.plan("7d", DAY, firstDay)
	local loaded = Fixture.loaded(DAY, plan, options)
	return AnalyticsLogic.summarize("7d", plan, DAY, loaded, Reports.labelOf, os.time(), ReportSections.build)
end

-- The algorithm table's rows by id (nil when the section is absent).
local function scorecard(summary: any): ({ [string]: any }?, any?)
	for _, section in summary.tables do
		if section.id == "algorithm" then
			local byId: { [string]: any } = {}
			for _, row in section.rows do
				byId[row.id] = row
			end
			return byId, section
		end
	end
	return nil, nil
end

local function near(a: number, b: number): boolean
	return math.abs(a - b) < 1e-9
end

-- 1. Plan ----------------------------------------------------------------------------------------------
do
	local today = AnalyticsLogic.plan("today", DAY, DAY - 100)
	for n = 1, ALGORITHM.PlayDayMax do
		check(table.find(today.cohortDays, DAY - n) ~= nil, `today's plan loads the D{n} cohort day`)
	end
	check(table.find(today.cohortDays, DAY - 30) ~= nil, "the D30 cohort day is still loaded")
	local short = AnalyticsLogic.plan("today", DAY, DAY - 3)
	for _, cohortDay in short.cohortDays do
		check(cohortDay >= DAY - 3, "no cohort day before the analytics start is read")
	end
end

-- 2. The scorecard (history 30 days: D8-28 not complete yet) --------------------------------------------
local summary = summarize(DAY - 30)
do
	check(summary.tables[1].id == "retention" and summary.tables[2].id == "algorithm", "Retention, then the scorecard")
	local rows, section = scorecard(summary)
	assert(rows ~= nil and section ~= nil, "algorithm section present")
	local order = {
		"ptr",
		"bounceLt60",
		"bounce60to180",
		"playDaysD1",
		"playDaysD2to7",
		"playDaysD8to28",
		"playtime",
		"qualifiedSessions",
		"coplayDays",
		"spendDays",
		"robuxPerUser",
		"coverage",
	}
	check(#section.rows == #order, `twelve rows ({#section.rows})`)
	for index, id in order do
		check(section.rows[index].id == id, `row {index} is {id}`)
	end
	check(section.title == "Roblox algorithm scorecard" and section.note ~= "", "title + note")

	check(rows.ptr.display == "Creator Hub only" and rows.ptr.tone == "info", "PTR lives in Creator Hub")
	check(near(rows.bounceLt60.value, 0.25) and rows.bounceLt60.tone == "watch", "bounce < 60 s = 25% → watch")
	check(near(rows.bounceLt60.share, 0.6), `bounce bar = goal / value ({rows.bounceLt60.share})`)
	check(
		string.find(rows.bounceLt60.extra, "phone 50/170", 1, true) ~= nil
			and string.find(rows.bounceLt60.extra, "console 20/110", 1, true) ~= nil,
		`per-device bounce details ({rows.bounceLt60.extra})`
	)
	check(near(rows.bounce60to180.value, 0.1) and rows.bounce60to180.tone == "good", "61-180 s = 10% → good")
	check(rows.bounce60to180.share == 1, "on-target bar is full")
	check(near(rows.playDaysD1.value, 0.1) and rows.playDaysD1.tone == "watch", "D1 = r1 / cohort → watch")
	check(rows.playDaysD1.display == "0.10 days", `D1 display ({rows.playDaysD1.display})`)
	check(near(rows.playDaysD2to7.value, 0.3) and rows.playDaysD2to7.tone == "watch", "D2-7 = Σ ratios → watch")
	check(string.find(rows.playDaysD2to7.extra, "D2 5%", 1, true) ~= nil, "D2-7 per-day ratios listed")
	check(rows.playDaysD8to28.tone == "na" and rows.playDaysD8to28.display == "n/a", "D8-28 n/a: window not complete")
	check(string.find(rows.playDaysD8to28.extra, "not complete", 1, true) ~= nil, "D8-28 says why")
	check(near(rows.playtime.value, 15) and rows.playtime.tone == "watch", "capped playtime 15 min → watch")
	check(rows.playtime.display == "15 min", `playtime display ({rows.playtime.display})`)
	check(near(rows.qualifiedSessions.value, 500 / 700) and rows.qualifiedSessions.tone == "watch", "qualified → watch")
	check(near(rows.coplayDays.value, 0.03) and rows.coplayDays.tone == "bad", "co-play 0.03 → bad")
	check(string.find(rows.coplayDays.extra, "followed 10", 1, true) ~= nil, "co-play paths listed")
	check(near(rows.spendDays.value, 0.01) and rows.spendDays.tone == "good", "spend days → good")
	check(near(rows.robuxPerUser.value, 0.5) and rows.robuxPerUser.tone == "good", "Robux per user → good")
	check(rows.robuxPerUser.display == "R$ 0.50", `Robux display ({rows.robuxPerUser.display})`)
	check(rows.coverage.value == 1 and rows.coverage.tone == "good", "full R122 coverage")
	for _, row in section.rows do
		check(row.share >= 0 and row.share <= 1, `{row.id} bar within 0..1`)
		check(table.find(AnalyticsReport.Tones, row.tone) ~= nil, `{row.id} has a known tone`)
	end
end

-- 3. D8-28 once the history reaches back far enough ------------------------------------------------------
do
	local rows = scorecard(summarize(DAY - 60))
	assert(rows ~= nil, "scorecard")
	check(near(rows.playDaysD8to28.value, 21 * 7 / 280), `D8-28 = Σ rbx:day:8..28 / cohort ({rows.playDaysD8to28.value})`)
	check(rows.playDaysD8to28.tone == "watch", "D8-28 → watch")
end

-- 4. A mixed-build range ------------------------------------------------------------------------------------
do
	local rows = scorecard(summarize(DAY - 60, { rbxSessions = 500 }))
	assert(rows ~= nil, "scorecard")
	for _, id in { "playDaysD2to7", "playDaysD8to28", "playtime", "qualifiedSessions", "coplayDays" } do
		check(rows[id].tone == "partial", `{id} is PARTIAL on a mixed-build range`)
		check(string.find(rows[id].extra, "pre-R122", 1, true) ~= nil, `{id} says why`)
	end
	-- R135: bounce is measured on the R122+ servers' own first sessions, so it keeps a verdict.
	check(near(rows.bounceLt60.value, 0.25) and rows.bounceLt60.tone == "watch", "bounce keeps its verdict")
	check(rows.bounce60to180.tone == "good", "61-180 s keeps its verdict")
	check(string.find(rows.bounceLt60.extra, "SAMPLE: R122+ servers only (280 of 280", 1, true) ~= nil, "bounce SAMPLE note")
	check(string.find(rows.bounceLt60.extra, "pre-R122", 1, true) == nil, "bounce is no longer PARTIAL")
	check(rows.playDaysD1.tone == "watch" and rows.spendDays.tone == "good", "pre-R122 counters keep their verdicts")
	check(rows.robuxPerUser.tone == "good", "Robux keeps its verdict")
	check(rows.coverage.tone == "partial" and near(rows.coverage.value, 500 / 1050), "coverage row explains it")
end

-- 4b. R135: per-player-day rows divide by the R122+ builds' player-days ---------------------------------------
do
	local rows = scorecard(summarize(DAY - 60, { rbxSessions = 500, coveredDau = 350 }))
	assert(rows ~= nil, "scorecard")
	local qualified = 500 - math.floor(300 * 500 / 1050 + 0.5) - math.floor(250 * 500 / 1050 + 0.5)
	check(near(rows.playtime.value, 630000 / 60 / 350) and rows.playtime.tone == "good", "playtime / covered = 30 min → good")
	check(near(rows.qualifiedSessions.value, qualified / 350), `qualified / covered ({rows.qualifiedSessions.value})`)
	check(rows.qualifiedSessions.tone == "watch", "qualified → watch")
	check(near(rows.coplayDays.value, 21 / 350) and rows.coplayDays.tone == "watch", "co-play / covered → watch")
	for _, id in { "playtime", "qualifiedSessions", "coplayDays" } do
		check(string.find(rows[id].extra, "SAMPLE: R122+ servers only (350 of 700 player-days)", 1, true) ~= nil, `{id} SAMPLE note`)
		check(string.find(rows[id].extra, "pre-R122", 1, true) == nil, `{id} is not PARTIAL`)
	end
	check(string.find(rows.playtime.extra, "/ 350 player-days", 1, true) ~= nil, "playtime detail shows the covered denominator")
	check(rows.playDaysD2to7.tone == "partial", "return-day rows stay PARTIAL (no per-build cohorts)")
	-- A player who switched builds on one day counts once per build: the denominator never exceeds dau.
	local clamped = scorecard(summarize(DAY - 60, { rbxSessions = 500, coveredDau = 900 }))
	assert(clamped ~= nil, "scorecard")
	check(near(clamped.playtime.value, 630000 / 60 / 700), "covered player-days clamp to the range's player-days")
	-- Full coverage ignores build slices (every player-day is covered).
	local full = scorecard(summarize(DAY - 60, { coveredDau = 350 }))
	assert(full ~= nil, "scorecard")
	check(near(full.playtime.value, 15) and string.find(full.playtime.extra, "SAMPLE", 1, true) == nil, "full coverage: dau")
	-- The live 2026-11-01 17:33 report: 489 joined, 136 first sessions classified by R122+ servers.
	local plan = AnalyticsLogic.plan("7d", DAY, DAY - 60)
	local loaded = Fixture.loaded(DAY, plan, { rbxSessions = 162 })
	local core = loaded.totals.core
	for key in table.clone(core) do
		if string.sub(key, 1, 14) == "rbx:bounceDev:" then
			core[key] = nil
		end
	end
	core["ftue:joined"] = 489
	core["rbx:bounce:lt60"] = 29
	core["rbx:bounce:60to180"] = 47
	local live = {
		phone = { 12, 24, 28 },
		tablet = { 7, 12, 13 },
		desktop = { 5, 2, 7 },
		console = { 4, 9, 12 },
		unknown = { 1, 0, 0 },
	}
	for class, counts in live do
		core[`rbx:bounceDev:{class}:lt60`] = counts[1]
		core[`rbx:bounceDev:{class}:60to180`] = counts[2]
		core[`rbx:bounceDev:{class}:stay`] = counts[3]
	end
	local liveRows = scorecard(
		AnalyticsLogic.summarize("7d", plan, DAY, loaded, Reports.labelOf, os.time(), ReportSections.build)
	)
	assert(liveRows ~= nil, "scorecard")
	check(near(liveRows.bounceLt60.value, 29 / 136) and liveRows.bounceLt60.tone == "watch", "live: 21 % → watch (not 5.9 %)")
	check(near(liveRows.bounce60to180.value, 47 / 136) and liveRows.bounce60to180.tone == "bad", "live: 35 % → bad (not 9.6 %)")
	check(string.find(liveRows.bounceLt60.extra, "29 of 136 first sessions", 1, true) ~= nil, "live: detail names 136")
	check(string.find(liveRows.bounceLt60.extra, "(136 of 489 joined", 1, true) ~= nil, "live: SAMPLE names 489")
end

-- 5. Missing denominators are n/a, never 0 ------------------------------------------------------------------
do
	local rows = scorecard(summarize(DAY - 30, { dau = 0, joined = 0 }))
	assert(rows ~= nil, "scorecard still shown (sessions ended)")
	for _, id in { "bounceLt60", "bounce60to180", "playtime", "qualifiedSessions", "coplayDays", "spendDays", "robuxPerUser" } do
		check(rows[id].display == "n/a" and rows[id].tone == "na", `{id} n/a without a denominator`)
		check(rows[id].share == 0, `{id} has no bar`)
	end
end

-- 6. No players: no scorecard ---------------------------------------------------------------------------------
do
	local empty = AnalyticsLogic.summarize(
		"today",
		AnalyticsLogic.plan("today", DAY, DAY),
		DAY,
		{ totals = {}, daily = {}, cohortNew = {}, partial = false, source = "memory" },
		Reports.labelOf,
		os.time(),
		ReportSections.build
	)
	check(scorecard(empty) == nil and #empty.tables == 2, "empty range: retention + coverage only")
end

-- 7. Parser -------------------------------------------------------------------------------------------------
do
	local parsed = AnalyticsReport.parse(serde.decode("json", serde.encode("json", summary)))
	assert(parsed ~= nil, "parse round trip")
	local rows = scorecard(parsed)
	assert(rows ~= nil, "scorecard after parse")
	check(rows.bounceLt60.tone == "watch" and rows.coplayDays.tone == "bad", "tones survive the round trip")
	local hostile = {
		tables = { { id = "x", title = "X", rows = { { id = "a", label = "A", value = 1, tone = "sparkly" }, { id = "b", label = "B", value = 2, tone = 5 } } } },
	}
	local back = AnalyticsReport.parse(hostile)
	assert(back ~= nil, "hostile summary parses")
	check(back.tables[1].rows[1].tone == nil and back.tables[1].rows[2].tone == nil, "unknown tones dropped")
end

-- 8. COPY FOR AI ----------------------------------------------------------------------------------------------
do
	local text = AnalyticsReport.toText(summary)
	check(string.find(text, "## Roblox algorithm scorecard", 1, true) ~= nil, "section in the export")
	check(string.find(text, "| 25% · WATCH |", 1, true) ~= nil, "verdict beside the value")
	check(string.find(text, "· BELOW TARGET |", 1, true) ~= nil, "a below-target row")
	check(string.find(text, "| Creator Hub only |", 1, true) ~= nil, "info rows print their display only")
	check(string.find(text, "Creator Hub only · INFO", 1, true) == nil, "no INFO label")
	check(AnalyticsReport.ExporterVersion == "2", "exporter version bumped for the tone field")
	local question = false
	for _, line in AnalyticsReport.LoopContext do
		if string.find(line, "Recommended for You", 1, true) ~= nil then
			question = true
		end
	end
	check(question, "analyst question 9 asks about the Roblox signals")
	check(string.find(text, "`rbx:playSec`", 1, true) ~= nil, "rbx:* keys pinned and defined in the export")
	check(#text <= AnalyticsConfig.ReportMaxChars, "text under the cap")
end

-- 9. Table budget ------------------------------------------------------------------------------------------
do
	-- Fixed tables: Retention + Report coverage (summarize) and every non-repeating ReportSections /
	-- WorldSections table — 48 in tests/analytics-report's full fixture, plus tycoonExtras and the
	-- R122 clientBoot table it has no data for. Update FIXED_TABLES when a section is added.
	local FIXED_TABLES = 50
	local WorldsConfig = env.load("src/shared/Config/Worlds/WorldsConfig")
	local worst = FIXED_TABLES + 4 * #WorldsConfig.extra() + 2 * #AnalyticsConfig.Economy.Currencies
	check(
		worst <= AnalyticsConfig.ReportMaxTables - 1,
		`worst-case report has {worst} tables (cap {AnalyticsConfig.ReportMaxTables}; Report coverage needs the last)`
	)
	local ids: { [string]: boolean } = {}
	for _, section in summary.tables do
		check(ids[section.id] == nil, `table id {section.id} is unique`)
		ids[section.id] = true
	end
end

-- 10. Client boot steps table ------------------------------------------------------------------------------
do
	local function hasTable(result: any, id: string): any?
		for _, section in result.tables do
			if section.id == id then
				return section
			end
		end
		return nil
	end
	check(hasTable(summary, "clientBoot") == nil, "no boot reports: no clientBoot table")
	local ClientPerfLogic = env.load("src/shared/Analytics/ClientPerfLogic")
	local window = ClientPerfLogic.newWindow(0)
	for _ = 1, 600 do
		ClientPerfLogic.addFrame(window, 1 / 60)
	end
	ClientPerfLogic.addSample(window, 900, 0, 80)
	ClientPerfLogic.setBoot(
		window,
		7,
		{ Loaded = 0.4, Client = 1.25, Profile = 2, World = 2.5, Plot = 3.75, Assets = 6.5 },
		"budget"
	)
	local report = ClientPerfLogic.decode(ClientPerfLogic.encode(window, 1, 30, 4, 25), 60, 10)
	assert(report ~= nil, "boot report decodes")
	local plan = AnalyticsLogic.plan("7d", DAY, DAY - 30)
	local loaded = Fixture.loaded(DAY, plan)
	local health: { [string]: number } = {}
	for _ = 1, 4 do
		for key, amount in ClientPerfLogic.counters(report) do
			health[key] = (health[key] or 0) + amount
		end
	end
	loaded.totals.health = health
	local withBoot =
		AnalyticsLogic.summarize("7d", plan, DAY, loaded, Reports.labelOf, os.time(), ReportSections.build)
	local boot = hasTable(withBoot, "clientBoot")
	check(boot ~= nil and boot.title == "Client boot steps by device", "clientBoot table with boot reports")
	check(boot ~= nil and #boot.rows >= 1 and boot.note ~= "", "one row per reporting device class + note")
	local clientMemory, bootIndex = 0, 0
	for index, section in withBoot.tables do
		if section.id == "clientMemory" then
			clientMemory = index
		elseif section.id == "clientBoot" then
			bootIndex = index
		end
	end
	check(clientMemory > 0 and bootIndex == clientMemory + 1, "clientBoot right after Client memory")
end

done("analytics-algorithm")
