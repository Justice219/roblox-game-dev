--!strict
--[[
	TestRunner — runs Studio integration test suites and reports structured results (pattern from
	RoBeasts).

	How it is used:
		An agent starts a Run-mode playtest with test args (StudioTestService), e.g. through
		scripts/studio_mcp.py:
			StudioTestService:ExecuteRunModeAsync({ suite = "Core" })
		The server bootstrap (init.server.luau) sees the args, calls TestRunner.run(args) and
		hands the returned table to StudioTestService:EndTest, which ends the playtest and returns
		the table to the caller. Nothing here runs in live games (GetTestArgs only exists in
		Studio test sessions, and the bootstrap only reads it under RunService:IsStudio()).

	Args:
		suite : string  — a key of getSuites() (default "Core")
		only  : string? — run just the case with this name
		timeout : number? — the bootstrap's watchdog budget in seconds

	Result shape:
		{ suite, passed, failed, durationSeconds, tests = { { name, ok, error?, checks, metrics } } }

	Adding a suite: create `<Name>Tests.luau` in this folder returning { TestCase } and add one
	line to getSuites() (static requires keep the type information).
]]

local TestContext = require(script.Parent.TestContext)

export type TestCase = {
	name: string,
	run: (ctx: TestContext.TestContext) -> (),
}

local TestRunner = {}

-- Static registry of suites.
local function getSuites(): { [string]: { TestCase } }
	return {
		-- B1 core: remotes, profile schema / save payload, ProfileStore locking over a mock store,
		-- receipt idempotency, monetization catalogue (Run mode, no players needed).
		Core = require(script.Parent.CoreTests) :: { TestCase },
		-- B5 tycoon server: plot assignment, pad purchase + BuildIn stamp, clicks/upgrades, manager
		-- income loop, offline payout, rebirth (Run mode).
		Tycoon = require(script.Parent.Parent.Tycoon.TycoonTests) :: { TestCase },
	}
end

--[[
	Runs a suite and returns JSON-friendly results. Case exceptions become failures; the
	bootstrap owns the final error boundary (EndTest is always called).
	Example: TestRunner.run({ suite = "Core" })
]]
function TestRunner.run(args: { [string]: unknown }): { [string]: unknown }
	local started = os.clock()
	if args.suite ~= nil and (type(args.suite) ~= "string" or args.suite == "") then
		return { error = "invalid suite", passed = 0, failed = 1 }
	end
	if args.only ~= nil and (type(args.only) ~= "string" or args.only == "") then
		return { error = "invalid test filter", passed = 0, failed = 1 }
	end
	local suiteName = if type(args.suite) == "string" then args.suite else "Core"
	local only = if type(args.only) == "string" then args.only else nil

	local suite = getSuites()[suiteName]
	if suite == nil then
		return { suite = suiteName, error = "unknown suite", passed = 0, failed = 1 }
	end
	if #suite == 0 then
		return { suite = suiteName, error = "empty suite", passed = 0, failed = 1 }
	end
	if only ~= nil then
		local found = false
		for _, case in suite do
			if case.name == only then
				found = true
				break
			end
		end
		if not found then
			return { suite = suiteName, only = only, error = "unknown test", passed = 0, failed = 1 }
		end
	end

	local results = {}
	local passed, failed = 0, 0
	for _, case in suite do
		if only ~= nil and case.name ~= only then
			continue
		end
		local ctx = TestContext.new()
		local ok, err = pcall(case.run, ctx)
		ctx.trove:Clean()
		local allChecksOk = true
		for _, check in ctx.checks do
			if not check.ok then
				allChecksOk = false
			end
		end
		local caseOk = ok and allChecksOk
		if caseOk then
			passed += 1
		else
			failed += 1
		end
		table.insert(results, {
			name = case.name,
			ok = caseOk,
			error = if ok then nil else tostring(err),
			checks = ctx.checks,
			metrics = ctx.metrics,
		})
	end

	return {
		suite = suiteName,
		passed = passed,
		failed = failed,
		durationSeconds = math.round((os.clock() - started) * 100) / 100,
		tests = results,
	}
end

return TestRunner
