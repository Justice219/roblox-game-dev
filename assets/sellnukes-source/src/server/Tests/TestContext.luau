--!strict
--[[
	TestContext — helpers for Studio integration tests (pattern from RoBeasts).

	Purpose:
		Each test case gets a fresh context: assertion helpers that never throw (one failed check
		does not abort the suite), a metrics table returned to the caller (an agent driving Studio
		through scripts/studio_mcp.py), a Trove that cleans everything the case created, and a
		wall-clock-capped wait. Tests run in Studio only (TestRunner is only reached when
		StudioTestService passes test args to the server bootstrap).

	Example (inside a test case):
		ctx.check("gems granted once", profile.gems == 100, `gems={profile.gems}`)
		ctx.metric("pushBytes", bytes)
		local part = ctx.trove:Add(Instance.new("Part"))
]]

local Trove = require(game:GetService("ReplicatedStorage").Shared.Util.Trove)

export type CheckResult = { name: string, ok: boolean, detail: string }

export type TestContext = {
	trove: Trove.Trove,
	checks: { CheckResult },
	metrics: { [string]: number | string | boolean },
	wait: (seconds: number) -> (),
	check: (name: string, ok: boolean, detail: string?) -> boolean,
	metric: (name: string, value: number | string | boolean) -> (),
}

local TestContext = {}

--[[ Creates a fresh context. The runner cleans it with ctx.trove:Clean() after the case. ]]
function TestContext.new(): TestContext
	local trove = Trove.new()
	local checks: { CheckResult } = {}
	local metrics: { [string]: number | string | boolean } = {}
	return {
		trove = trove,
		checks = checks,
		metrics = metrics,
		-- Wall-clock wait (task.wait); tests here measure logic, not physics.
		wait = function(seconds: number)
			task.wait(seconds)
		end,
		-- Records a named check; returns `ok` so callers can branch on it.
		check = function(name: string, ok: boolean, detail: string?): boolean
			table.insert(checks, { name = name, ok = ok, detail = detail or "" })
			return ok
		end,
		-- Records a metric (numbers rounded to 3 decimals for compact results).
		metric = function(name: string, value: number | string | boolean)
			if type(value) == "number" then
				metrics[name] = math.round(value * 1000) / 1000
			else
				metrics[name] = value
			end
		end,
	}
end

return TestContext
