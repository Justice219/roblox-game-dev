--!strict
--[[
	Analytics report regressions (lune run tests/analytics-report). Real AnalyticsLogic.summarize +
	ReportSections + AnalyticsReport (parse, toText, raw pages) on hand-made range totals.

	Proves:
	  1. Headlines: DAU / sessions / median session / D1 from cohort denominators (n/a without a
	     cohort), ARPDAU / ARPPU / conversion, tutorial completion and area-2 rate from the funnel.
	  2. Sections: every SellNukes section with data is present (funnel, area pacing vs targets,
	     slowest pads, producers, income share, revenue splits, economy, systems, health, client
	     perf, builds, data quality, coverage) and absent without data.
	  2b. R137 offer BUY presses: "click n/a" / "clicks n/a" when the range has no click key at all,
	     real numbers (and real zeros) once recorded, no empty "()" percentages.
	  3. COPY FOR AI: the SellNukes header + loop context, headline table, sections, daily rows,
	     definitions of the present key patterns and ONE parseable JSON block, within ReportMaxChars.
	  4. The client parser accepts a JSON round trip of the summary (tables, daily pads).
	  5. Stress (2,500 keys in every family): the payload keeps ≤ ReportSummaryKeys counters, pinned
	     keys (dau, r1, ftue:*, robux, area*) always survive, omissions are counted, text stays
	     under the cap.
	  6. COPY RAW DATA: rawIndex / rawPage / parseRawPage / rawText page every counter exactly once.
	  7. Reports.labelOf resolves pads / producers / areas / products (Dino ids with their world).
	  8. R57 WORLDS section (Server/Analytics/WorldSections): overview, per-world funnel / pacing /
	     popup & travel / money tables, client perf per world, Bones sources / sinks.
]]

local serde = require("@lune/serde")
local Loader = require("./analytics-fixtures/Loader")
local env = Loader.new()
local check, done = Loader.checker()

local DAY = 20756
env.setTime(DAY * 86400 + 15 * 3600)

local AnalyticsConfig = env.load("src/shared/Config/AnalyticsConfig")
local AnalyticsReport = env.load("src/shared/Analytics/AnalyticsReport")
local ClientPerfLogic = env.load("src/shared/Analytics/ClientPerfLogic")
local AnalyticsLogic = env.load("src/server/Analytics/AnalyticsLogic")
local ReportSections = env.load("src/server/Analytics/ReportSections")
local Reports = env.load("src/server/Analytics/Reports")

-- A client perf report's counters (health family "cp:*").
local function perfCounters(): { [string]: number }
	local window = ClientPerfLogic.newWindow(0)
	for _ = 1, 600 do
		ClientPerfLogic.addFrame(window, 1 / 60)
	end
	ClientPerfLogic.addSample(window, 900, 0, 80)
	local report = ClientPerfLogic.decode(ClientPerfLogic.encode(window, 1, 10, 5, 12), 70, 30)
	assert(report ~= nil, "client perf roundtrip")
	return ClientPerfLogic.counters(report)
end

local health: { [string]: number } = {
	win = 60,
	sec = 3600,
	ftSum = 60 * 1000 * 17,
	["ft:<18"] = 3400,
	["ft:18-20"] = 200,
	hbN = 7200,
	hbSum = 7200 * 3,
	physSum = 7200,
	sendSum = 7200 * 50,
	recvSum = 7200 * 5,
	plrSum = 7200 * 6,
	memSum = 7200 * 1200,
	["mem:1000-1500"] = 7200,
	["hb:2-4"] = 7200,
	pingN = 100,
	pingSum = 100 * 90,
	["ping:50-100"] = 100,
	["sys:Producers"] = 1800,
	["rx:IncomePop:n"] = 5000,
	["rx:IncomePop:kb"] = 900,
}
-- Three reports: the client perf table needs ClientPerfConfig.MinReportsForRow per class.
for _ = 1, 3 do
	for key, amount in perfCounters() do
		health[key] = (health[key] or 0) + amount
	end
end

local totals = {
	core = {
		dau = 70,
		new = 30,
		returning = 40,
		sessions = 100,
		sessionSeconds = 100 * 900,
		["len:5-15m"] = 60,
		["len:15-30m"] = 40,
		r1 = 4,
		["r1:carry"] = 1,
		payers = 7,
		newPayers = 3,
		["ftue:joined"] = 30,
		["ftue:firstPad"] = 28,
		["ftueS1:firstPad"] = 28,
		["ftueMin:firstPad"] = 30,
		["ftue:manager"] = 15,
		["ftue:area2"] = 12,
		["ftueLeft:firstPad"] = 5,
		["ftueLeft:area2"] = 8,
		["ftueLen:5-15m"] = 13,
		["cohort:all"] = 30,
		["cohort:area2"] = 12,
		["r1:all"] = 4,
		["r1:area2"] = 3,
		["uniq:shop"] = 22,
		["device:phone"] = 60,
		["devSeconds:phone"] = 60 * 800,
		["devNew:phone"] = 20,
		["hour:15"] = 30,
		["sessNo:1"] = 30,
		["sessNo:2"] = 20,
		["ops:badKey:pets"] = 2,
		["build:1.0.0:p12:dau"] = 70,
		["build:1.0.0:p12:sessions"] = 100,
	},
	revenue = {
		purchases = 9,
		robux = 900,
		["product:GemsSmall:count"] = 5,
		["product:GemsSmall:robux"] = 245,
		["pass:VIP:count"] = 2,
		["pass:VIP:robux"] = 398,
		["prompt:GemsSmall"] = 20,
		["promptClosed:GemsSmall"] = 15,
		["promptDwell:shop:phone:lt2"] = 6,
		["funnel:GemsSmall:shown"] = 100,
		["funnel:GemsSmall:click"] = 30,
		["funnel:GemsSmall:prompt"] = 20,
		["funnel:GemsSmall:bought"] = 5,
		["robuxBySource:shop"] = 500,
		["robuxByDevice:phone"] = 700,
		["robuxByArea:3"] = 600,
		["robuxByRebirth:0"] = 900,
		["firstBuy:GemsSmall"] = 3,
		["offer:VIP:shown"] = 50,
		["offer:VIP:click"] = 5,
		["offers:card:VIP"] = 40,
		["offers:open:starburst"] = 30,
	},
	economy = {
		["earn:cash"] = 5e12,
		["earn:cash:Producer"] = 4e12,
		["n:earn:cash:Producer"] = 9000,
		["earn:cash:Offline"] = 1e12,
		["spend:cash"] = 3e12,
		["spend:cash:Pad"] = 3e12,
	},
	tycoon = {
		["area:2"] = 12,
		["areaN:2"] = 12,
		["areaAt:2"] = 12 * 8 * 60 * 1.25,
		["area:3"] = 5,
		["areaN:3"] = 5,
		["areaAt:3"] = 5 * 23 * 60,
		["pad:a1_workbench"] = 28,
		["padN:a1_workbench"] = 28,
		["padAt:a1_workbench"] = 28 * 30,
		["pad:a1_tool_wall"] = 25,
		["padN:a1_tool_wall"] = 25,
		["padAt:a1_tool_wall"] = 25 * 200,
		["padKind:Build"] = 53,
		clicks = 4000,
		["click:p1_workbench"] = 4000,
		["upgrade:p1_workbench"] = 300,
		["incomeP:p1_workbench:click"] = 1e6,
		["incomeP:p1_workbench:auto"] = 3e6,
		["income:click"] = 1e6,
		["income:auto"] = 3e6,
		["lvl:p1_workbench:25"] = 10,
		rebirth = 2,
		rebirthSec = 2 * 8 * 3600,
		["rebirthN:1"] = 2,
		["offline:pay"] = 10,
		offlineSec = 10 * 3600,
		["leaveArea:1"] = 50,
		["tut:1"] = 30,
	},
	retention = {
		["daily:claim:1"] = 25,
		["open:Shop"] = 40,
		["openFrom:Shop:hud"] = 40,
		-- WHAT'S NEW (owner R58): its own "whatsNew" table, not in retentionSystems.
		["notes:shown:2026-10-31-whats-new:auto"] = 6,
		["notes:shown:2026-10-31-whats-new:menu"] = 2,
		["notes:closed:2026-10-31-whats-new"] = 8,
		["notes:seen:2026-10-31-whats-new"] = 6,
		["notes:openSec:2026-10-31-whats-new"] = 100,
		["notes:openLen:5to15"] = 5,
		["notes:openLen:lt5"] = 3,
	},
	pets = { ["hatch:BasicEgg"] = 40, ["rarity:Common"] = 30 },
	crates = { ["open:SupplyCrate"] = 3 },
	attack = { ["launch:normal"] = 10, intercept = 4, hit = 6 },
	event = { ["turkey:collect"] = 12 },
	social = { ["players:6"] = 50, ["players:8"] = 10 },
	-- Owner R90 kinetic family (Server/Kinetic): 3 pulls + 2 jar payouts in Nuke Town.
	kinetic = { ["pull:main"] = 3, ["pullPaid:main"] = 9000, ["jar:main"] = 2, ["jarPaid:main"] = 400 },
	health = health,
	-- R57 worlds family (Server/Analytics/WorldSections).
	worlds = {
		["seconds:main"] = 60 * 600,
		["seconds:dino"] = 60 * 240,
		["visitor:dino"] = 8,
		["firstVisit:dino"] = 6,
		["unlock:dino"] = 10,
		["unlockSrc:dino:area"] = 9,
		["unlockSrc:dino:legacy"] = 1,
		["step:dino:unlocked"] = 10,
		["step:dino:firstTravel"] = 6,
		["step:dino:firstPad"] = 5,
		["step:dino:manager"] = 4,
		["step:dino:area2"] = 3,
		["popup:dino:shown"] = 10,
		["popup:dino:go"] = 7,
		["popup:dino:later"] = 3,
		["portalLocked:dino"] = 4,
		["travel:dino:popup"] = 7,
		["travel:dino:portal"] = 5,
		["travel:main:portal"] = 9,
		["travelFail:dino:locked"] = 4,
		["area:dino:2"] = 3,
		["areaN:dino:2"] = 3,
		["areaAt:dino:2"] = 3 * 12 * 60,
		["padArea:dino:1"] = 40,
		["rebirth:dino"] = 1,
		["rebirthN:dino:1"] = 1,
		["tokens:dino"] = 20,
		["rebirthShop:dino:clickPower"] = 2,
		["incomeW:dino:click"] = 1e5,
		["incomeW:dino:auto"] = 3e5,
		["offline:dino:pay"] = 2,
		["offlineSec:dino"] = 2 * 7200,
	},
}
totals.economy["earn:bones"] = 4e5
totals.economy["earn:bones:producer"] = 4e5
totals.economy["n:earn:bones:producer"] = 40
totals.economy["spend:bones"] = 1e5
totals.economy["spend:bones:pad"] = 1e5
totals.revenue["product:BonesSmall:count"] = 2
totals.revenue["product:BonesSmall:robux"] = 98
totals.pets["hatch:dino_egg"] = 12
for key, amount in perfCounters() do
	local suffix = string.match(key, "^cp:[^:]+:(.+)$")
	if suffix ~= nil then
		totals.health[`perfW:dino:{suffix}`] = amount
	end
end

-- 7-day range: today's D1 cohort (yesterday) had 10 new players.
local daily = {}
for offset = 6, 0, -1 do
	local day = DAY - offset
	daily[day] = {
		dau = 10,
		new = if offset == 1 then 10 else 3,
		sessions = 14,
		robux = 100,
		payers = 1,
		pads = 9,
	}
end
local plan = AnalyticsLogic.plan("7d", DAY, DAY - 30)
local loaded = { totals = totals, daily = daily, cohortNew = {}, partial = false, source = "datastore" }
for _, day in plan.cohortDays do
	loaded.cohortNew[day] = 3
end
local summary = AnalyticsLogic.summarize("7d", plan, DAY, loaded, Reports.labelOf, os.time(), ReportSections.build)

-- 1. Headlines.
local h = summary.headline
check(h.dau == 10 and h.sessions == 100 and h.newPlayers == 30, "basic headlines")
check(math.abs(h.avgSessionMinutes - 15) < 1e-9, "avg session")
check(h.medianSession == 10, `median session from buckets (got {h.medianSession})`)
check(h.d1 > 0 and h.d1 <= 1, `D1 from cohort denominators (got {h.d1})`)
check(math.abs(h.tutorialCompletion - 0.5) < 1e-9 and math.abs(h.area2Rate - 0.4) < 1e-9, "funnel headlines")
check(math.abs(h.arpdau - 900 / 70) < 1e-9 and math.abs(h.arppu - 900 / 7) < 1e-9, "ARPDAU / ARPPU")
check(h.padsBought == 53 and h.rebirths == 2, "tycoon headlines")
check(AnalyticsReport.formatHeadline("area2Rate", 0.4) == "40%", "percent headline")
check(AnalyticsReport.formatHeadline("d7", -1) == "n/a", "n/a headline")

-- 2. Sections.
local ids: { [string]: any } = {}
for _, section in summary.tables do
	ids[section.id] = section
end
for _, id in
	{
		"retention",
		"newPlayerFunnel",
		"firstSessions",
		"d1ByMilestone",
		"uniques",
		"sessionLength",
		"sessionNumber",
		"devices",
		"hours",
		"areaPacing",
		"leaveArea",
		"pads",
		"padGaps",
		"producers",
		"incomeShare",
		"levelMarks",
		"tutorial",
		"rebirths",
		"offline",
		"products",
		"purchaseFunnel",
		"bySource",
		"byDevice",
		"byArea",
		"byRebirth",
		"abandoned",
		"firstBuy",
		"offers",
		"earn_cash",
		"spend_cash",
		"retentionSystems",
		"screens",
		"whatsNew",
		"pets",
		"crates",
		"attack",
		"event",
		"social",
		"kinetic", -- owner R90 Mega Lever + Tip Jar
		"serverHealth",
		"serverSystems",
		"remoteTraffic",
		"clientPerf",
		"builds",
		"dataQuality",
		"reportContext",
		-- R57 WORLDS section.
		"worlds",
		"worldFunnel_dino",
		"worldPacing_dino",
		"worldEntry_dino",
		"worldMoney_dino",
		"worldPerf",
		"earn_bones",
		"spend_bones",
	}
do
	check(ids[id] ~= nil, `section {id} present`)
end
check(#summary.tables <= AnalyticsConfig.ReportMaxTables, "section cap")
local pacing = ids.areaPacing.rows
check(
	pacing[1].id == "2" and string.find(pacing[1].extra, "target 8 min", 1, true) ~= nil,
	"area 2 target = area 1's 8 min"
)
check(string.find(pacing[1].extra, "125%", 1, true) ~= nil, "first-run minutes vs target")
check(
	ids.padGaps.rows[1].id == "a1_tool_wall" and ids.padGaps.rows[1].value == 170,
	"pad gap = time since previous pad"
)
check(
	ids.newPlayerFunnel.rows[1].id == "joined"
		and string.find(ids.newPlayerFunnel.rows[4].extra, "of joined", 1, true) ~= nil,
	"funnel rows"
)
check(string.find(ids.incomeShare.note, "4M", 1, true) ~= nil or #ids.incomeShare.rows == 2, "income share")
check(ids.social.note ~= "" and string.find(ids.social.note, "6.3", 1, true) ~= nil, "average players per server")
check(
	ids.kinetic ~= nil and string.find(ids.kinetic.note, "pulls 3", 1, true) ~= nil,
	"R90 kinetic table: pulls + payouts note"
)
do
	-- WHAT'S NEW: one row per note (shown = auto + chip), time open in the note, avg = 100 s / 8 closes.
	local row = ids.whatsNew.rows[1]
	check(row.id == "2026-10-31-whats-new" and row.value == 8, "whatsNew row = shown auto + chip")
	check(string.find(row.extra, "auto 6", 1, true) ~= nil and string.find(row.extra, "avg open 12.5 s", 1, true) ~= nil, "whatsNew extra")
	check(string.find(ids.whatsNew.note, "lt5 3", 1, true) ~= nil, "whatsNew time-open histogram")
	for _, other in ids.retentionSystems.rows do
		check(string.sub(other.id, 1, 6) ~= "notes:", "notes:* rows stay out of retentionSystems")
	end
end
check(ids.attack.note ~= "" and string.find(ids.attack.note, "40%", 1, true) ~= nil, "intercept rate")
do
	-- WORLDS: overview minutes + avg per visitor-day, funnel % of unlocked, pacing vs target.
	local overviewRows: { [string]: any } = {}
	for _, row in ids.worlds.rows do
		overviewRows[row.id] = row
	end
	check(overviewRows.main ~= nil and overviewRows.main.value == 600, "Nuke Town minutes")
	check(
		overviewRows.dino ~= nil and string.find(overviewRows.dino.extra, "avg 30 min per visitor-day", 1, true) ~= nil,
		`Dino avg minutes per visitor-day ({overviewRows.dino and overviewRows.dino.extra})`
	)
	local funnelRows = ids.worldFunnel_dino.rows
	check(funnelRows[1].id == "unlocked" and funnelRows[2].id == "firstTravel", "world funnel order")
	check(string.find(funnelRows[2].extra, "60% of unlocked", 1, true) ~= nil, "world funnel share")
	local pacingRow: any = nil
	for _, row in ids.worldPacing_dino.rows do
		if row.id == "2" then
			pacingRow = row
		end
	end
	check(pacingRow ~= nil and pacingRow.display == "12 min", "Dino area 2 first-run minutes")
	check(pacingRow ~= nil and string.find(pacingRow.extra, "target 10 min", 1, true) ~= nil, "Dino pacing target")
	local money: { [string]: any } = {}
	for _, row in ids.worldMoney_dino.rows do
		money[row.id] = row
	end
	check(
		money.rebirths ~= nil and money["product:BonesSmall"] ~= nil and money["egg:dino_egg"] ~= nil,
		"rebirths, Bones product revenue, Dino egg hatches"
	)
	check(#ids.worldPerf.rows == 1 and ids.worldPerf.rows[1].id == "dino", "client perf per world")
end
local empty = AnalyticsLogic.summarize(
	"today",
	AnalyticsLogic.plan("today", DAY, DAY),
	DAY,
	{ totals = {}, daily = {}, cohortNew = {}, partial = false, source = "memory" },
	Reports.labelOf,
	os.time(),
	ReportSections.build
)
check(
	#empty.tables == 2 and empty.headline.d1 == -1 and empty.note ~= "",
	"no data: retention + coverage only, n/a, memory note"
)

-- 2b. Owner R137: offer BUY presses ("click") were not recorded before R137. A range without ANY
--     click key shows "click n/a" (a missing producer is never 0); with click data the real
--     numbers; a zero denominator prints no empty "()" percentage. Row ids / values unchanged.
do
	local function revenueOnly(revenue: { [string]: number }): any
		return AnalyticsLogic.summarize(
			"today",
			AnalyticsLogic.plan("today", DAY, DAY),
			DAY,
			{ totals = { revenue = revenue }, daily = {}, cohortNew = {}, partial = false, source = "memory" },
			Reports.labelOf,
			os.time(),
			ReportSections.build
		)
	end
	local function rowsOf(report: any, id: string): { [string]: any }
		local rows = {}
		for _, section in report.tables do
			if section.id == id then
				for _, row in section.rows do
					rows[row.id] = row
				end
			end
		end
		return rows
	end
	-- The live R136 shape: shown + prompt, no click producer yet.
	local before = revenueOnly({
		["funnel:StarterPack:shown"] = 48,
		["funnel:StarterPack:prompt"] = 11,
		["offers:card:StarterPack"] = 48,
		["funnel:DoubleCash:prompt"] = 43,
	})
	local funnel = rowsOf(before, "purchaseFunnel")
	local starter = funnel.StarterPack
	check(starter ~= nil and starter.value == 0, "funnel row id / value (bought) unchanged without clicks")
	check(
		string.find(starter.extra, "shown 48 → click n/a → prompt 11 → bought 0 (0% of prompts)", 1, true) ~= nil,
		`no click key in the range: click n/a (got {starter.extra})`
	)
	check(string.find(starter.extra, "click 0", 1, true) == nil, "missing click data is never 0")
	check(
		funnel.DoubleCash ~= nil and string.find(funnel.DoubleCash.extra, "shown 0 → click n/a", 1, true) ~= nil,
		"no shown: no empty percentage"
	)
	check(string.find(funnel.DoubleCash.extra, "()", 1, true) == nil, "no empty () anywhere")
	local offers = rowsOf(before, "offers")
	check(
		offers.StarterPack ~= nil and offers.StarterPack.value == 48 and offers.StarterPack.extra == "clicks n/a",
		"offer CTR row: clicks n/a without click keys, value (impressions) unchanged"
	)
	-- With R137 click data: real numbers (and a real 0 for an offer nobody pressed).
	local after = revenueOnly({
		["funnel:StarterPack:shown"] = 48,
		["funnel:StarterPack:click"] = 12,
		["funnel:StarterPack:prompt"] = 11,
		["offers:card:StarterPack"] = 48,
		["offer:StarterPack:click"] = 12,
		["funnel:VIP:shown"] = 20,
		["offers:card:VIP"] = 20,
		["funnel:DoubleCash:prompt"] = 4,
	})
	funnel = rowsOf(after, "purchaseFunnel")
	check(
		string.find(funnel.StarterPack.extra, "shown 48 → click 12 (25%) → prompt 11", 1, true) ~= nil,
		`click recorded: real numbers (got {funnel.StarterPack.extra})`
	)
	check(
		string.find(funnel.VIP.extra, "click 0 (0%) → prompt 0 → bought 0", 1, true) ~= nil
			and string.find(funnel.VIP.extra, "()", 1, true) == nil,
		`a recorded range makes an unpressed offer a real 0 (got {funnel.VIP.extra})`
	)
	check(
		string.find(funnel.DoubleCash.extra, "shown 0 → click 0 → prompt 4", 1, true) ~= nil,
		`no impressions: click without a percentage (got {funnel.DoubleCash.extra})`
	)
	offers = rowsOf(after, "offers")
	check(offers.StarterPack.extra == "clicks 12 (CTR 25%)", `offer CTR with clicks (got {offers.StarterPack.extra})`)
	check(offers.VIP.extra == "clicks 0 (CTR 0%)", `offer CTR real 0 (got {offers.VIP.extra})`)
	-- The main fixture keeps its numbers.
	local fixtureFunnel = rowsOf(summary, "purchaseFunnel").GemsSmall
	check(
		fixtureFunnel ~= nil and string.find(fixtureFunnel.extra, "click 30 (30%)", 1, true) ~= nil,
		"fixture funnel click unchanged"
	)
end

-- 3. COPY FOR AI.
local text = AnalyticsReport.toText(summary)
check(
	string.find(text, "Dino Valley · funnel", 1, true) ~= nil and string.find(text, "Worlds · overview", 1, true) ~= nil,
	"COPY FOR AI includes the WORLDS section"
)
check(string.find(text, "# SellNukes analytics report", 1, true) == 1, "report title")
check(string.find(text, AnalyticsReport.LoopContext[1], 1, true) ~= nil, "loop context in the export")
check(
	string.find(text, "## New player funnel", 1, true) ~= nil and string.find(text, "## Area pacing", 1, true) ~= nil,
	"sections in text"
)
check(string.find(text, "| Day | DAU | New | Sessions | Robux | Payers | Pads bought |", 1, true) ~= nil, "daily table")
check(#text <= AnalyticsConfig.ReportMaxChars, "text under the cap")
local json = string.match(text, "```json\n(.-)\n```")
check(json ~= nil, "one JSON block")
local decoded = serde.decode("json", json :: string)
check(type(decoded) == "table", "JSON parses")
check(string.find(text, "`pad:<padId>`", 1, true) ~= nil, "present pattern definitions printed")

-- 4. Parser round trip.
local parsed = AnalyticsReport.parse(serde.decode("json", serde.encode("json", summary)))
check(parsed ~= nil and #parsed.tables == #summary.tables and parsed.daily[1].pads == 9, "parse round trip")
check(AnalyticsReport.parse("garbage") == nil, "parse rejects junk")

-- 5. Stress: 2,500 keys per family.
do
	local big = {}
	for _, family in AnalyticsConfig.Families do
		local counters = {}
		for index = 1, AnalyticsConfig.MaxKeysPerFamily - 10 do
			counters[`k{index}:x`] = index
		end
		big[family] = counters
	end
	big.core.dau = 1
	big.core.r1 = 1
	big.core["ftue:joined"] = 1
	big.revenue.robux = 1
	big.tycoon["areaAt:2"] = 1
	local stress = AnalyticsLogic.summarize(
		"today",
		AnalyticsLogic.plan("today", DAY, DAY),
		DAY,
		{ totals = big, daily = {}, cohortNew = {}, partial = false, source = "datastore" },
		Reports.labelOf,
		os.time(),
		ReportSections.build
	)
	local kept = 0
	for _, counters in stress.families do
		for _ in counters do
			kept += 1
		end
	end
	check(kept <= AnalyticsConfig.ReportSummaryKeys, `payload key budget (kept {kept})`)
	check(stress.truncated > 0, "omissions counted")
	check(
		stress.families.core.dau == 1 and stress.families.core.r1 == 1 and stress.families.core["ftue:joined"] == 1,
		"pinned core keys survive"
	)
	check(
		stress.families.revenue.robux == 1 and stress.families.tycoon["areaAt:2"] == 1,
		"pinned revenue / pacing keys survive"
	)
	local stressText = AnalyticsReport.toText(stress)
	check(#stressText <= AnalyticsConfig.ReportMaxChars, `stress text under the cap ({#stressText})`)

	-- 6. RAW pages over the uncapped totals.
	local index = AnalyticsReport.rawIndex(big, AnalyticsConfig.Raw.PageChars, AnalyticsConfig.Raw.MaxPages)
	local meta = {
		rawId = 1,
		range = "today",
		from = stress.from,
		to = stress.to,
		generatedAt = stress.generatedAt,
		source = "datastore",
		partial = false,
	}
	local seen = 0
	local pages = #index.starts
	for page = 1, pages do
		local raw = AnalyticsReport.rawPage(index, big, page, meta)
		check(raw ~= nil, `raw page {page}`)
		local back = AnalyticsReport.parseRawPage(serde.decode("json", serde.encode("json", raw)))
		check(back ~= nil and back.page == page and back.pages == pages, `raw page {page} parses`)
		for _, counters in (back :: any).counters do
			for _ in counters do
				seen += 1
			end
		end
		check(#AnalyticsReport.rawText(back) <= AnalyticsConfig.ReportMaxChars, `raw text {page} under the cap`)
	end
	check(
		seen + index.omitted == index.total,
		`every counter on exactly one page ({seen} + {index.omitted} of {index.total})`
	)
end

-- 7. Labels.
check(string.find(Reports.labelOf("pad", "a1_workbench"), "(area 1)", 1, true) ~= nil, "pad label")
check(
	string.find(Reports.labelOf("pad", "d1_stone_bench"), "Dino Valley area 1", 1, true) ~= nil,
	`Dino pad label ({Reports.labelOf("pad", "d1_stone_bench")})`
)
check(
	string.find(Reports.labelOf("producer", "dp1_pebble_bench"), "(Dino Valley)", 1, true) ~= nil,
	"Dino producer label"
)
check(Reports.labelOf("area", "2") == "2. Nuke Stand", `area label ({Reports.labelOf("area", "2")})`)
check(
	Reports.labelOf("product", "VIP") == "VIP (pass)"
		or string.find(Reports.labelOf("product", "VIP"), "(pass)", 1, true) ~= nil,
	"pass label"
)
check(Reports.labelOf("pad", "nope") == "nope", "unknown id shows the id")

done("analytics-report")
