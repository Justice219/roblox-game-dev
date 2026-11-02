--!strict
--[[
	analytics-fixtures/AlgorithmFixture — a hand-made 7-day range for the owner R122 "Roblox algorithm
	scorecard" (Server/Analytics/ReportSections algorithmSection), used by tests/analytics-algorithm.

	Every day of the range: 100 DAU, 40 new players, 150 ended sessions; every cohort day before the
	range also had 40 new players. With the defaults the scorecard rows land on known verdicts:
		bounce < 60 s       70 / 280 joined  = 25 %   → watch  (goal under 15 %, watch under 25 %)
		bounce 61-180 s     28 / 280         = 10 %   → good
		play days D1        28 / 280         = 0.10   → watch  (goal 0.15, watch 0.08)
		play days D2-7      6 × 14 / 280     = 0.30   → watch  (goal 0.5, watch 0.25)
		play days D8-28     21 × 7 / 280     = 0.525  → watch  (only when the history reaches back)
		playtime            630,000 s / 700  = 15 min → watch  (goal 20, watch 10)
		qualified sessions  500 / 700        = 0.71   → watch  (goal 1, watch 0.6)
		co-play days        21 / 700         = 0.03   → bad    (goal 0.1, watch 0.04)
		spend days          7 / 700          = 0.01   → good
		Robux per user      350 / 700        = 0.5    → good
		coverage            1,050 / 1,050    = 100 %  → good
	Bounce divides by Σ rbx:bounceDev:* (280 classified first sessions = joined here); `joined = 0`
	drops every first-session key (no new players, no first sessions). `coveredDau` adds R135 build
	slices: an R122+ build ("0.9.0:p300", rbx slices) with that many player-days and a pre-R122 one
	("0.7.1:p272", no rbx slice) with the rest.
	Not a suite: scripts/test-logic.sh only runs top-level tests/*.luau files.

	Example:
		local Fixture = require("./analytics-fixtures/AlgorithmFixture")
		local plan = AnalyticsLogic.plan("7d", DAY, DAY - 60)
		local loaded = Fixture.loaded(DAY, plan, { rbxSessions = 500 })  -- a mixed-build range
]]

local AlgorithmFixture = {}

export type Options = {
	rbxSessions: number?, -- Σ rbx:session:* (default = every session: full R122 coverage)
	dau: number?, -- range player-days (default 700)
	joined: number?, -- ftue:joined (default 280; 0 = no first sessions at all)
	coveredDau: number?, -- R135: player-days on the R122+ build slice (nil = no build slices)
}

--[[
	The Loaded shape AnalyticsLogic.summarize takes (AnalyticsStore.loadRange output) for `plan`.
	@param day     today's UTC day number (the range ends today)
	@param plan    AnalyticsLogic.plan("7d", day, firstDay)
	@param options overrides (see Options)
]]
function AlgorithmFixture.loaded(day: number, plan: any, options: Options?): any
	local opts: Options = options or {}
	local sessions = 1050
	local rbxSessions = opts.rbxSessions or sessions
	local scale = rbxSessions / sessions
	local core: { [string]: number } = {
		dau = opts.dau or 700,
		new = 280,
		sessions = sessions,
		sessionSeconds = sessions * 600,
		["ftue:joined"] = opts.joined or 280,
		r1 = 28,
		payers = 7,
		["rbx:session:lt60"] = math.floor(300 * scale + 0.5),
		["rbx:session:60to180"] = math.floor(250 * scale + 0.5),
		["rbx:bounce:lt60"] = 70,
		["rbx:bounce:60to180"] = 28,
		["rbx:bounceDev:phone:lt60"] = 50,
		["rbx:bounceDev:phone:60to180"] = 20,
		["rbx:bounceDev:phone:stay"] = 100,
		["rbx:bounceDev:console:lt60"] = 20,
		["rbx:bounceDev:console:60to180"] = 8,
		["rbx:bounceDev:console:stay"] = 82,
		["rbx:playSec"] = 630000,
		["rbx:coplay"] = 21,
		["rbx:coplayVia:follow"] = 10,
		["rbx:coplayVia:host"] = 8,
		["rbx:coplayVia:invite"] = 3,
	}
	core["rbx:session:qualified"] = rbxSessions - core["rbx:session:lt60"] - core["rbx:session:60to180"]
	if opts.joined == 0 then
		-- No new players joined: no first session was ever classified.
		for key in table.clone(core) do
			if string.sub(key, 1, 11) == "rbx:bounce:" or string.sub(key, 1, 14) == "rbx:bounceDev:" then
				core[key] = nil
			end
		end
	end
	if opts.coveredDau ~= nil then
		core["build:0.9.0:p300:dau"] = opts.coveredDau
		core["build:0.9.0:p300:rbx:playSec"] = core["rbx:playSec"]
		core["build:0.7.1:p272:dau"] = math.max(0, core.dau - opts.coveredDau)
		core["build:0.7.1:p272:sessions"] = sessions - rbxSessions
	end
	for n = 2, 7 do
		core[`rbx:day:{n}`] = 14
	end
	for n = 8, 28 do
		core[`rbx:day:{n}`] = 7
	end
	local daily: { [number]: any } = {}
	for d = plan.from, plan.to do
		daily[d] = { dau = 100, new = 40, sessions = 150, robux = 50, payers = 1, pads = 0 }
	end
	local cohortNew: { [number]: number } = {}
	for _, cohortDay in plan.cohortDays do
		cohortNew[cohortDay] = 40
	end
	return {
		totals = { core = core, revenue = { robux = 350, purchases = 3 } },
		daily = daily,
		cohortNew = cohortNew,
		partial = false,
		source = "datastore",
	}
end

return AlgorithmFixture
