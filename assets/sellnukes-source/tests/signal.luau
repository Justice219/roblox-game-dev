--!strict
--[[
	tests/signal.luau — regression for Shared/Util/Signal (pure Luau, runs under lune).

	Why: TycoonWorld's ProducerAdded listener error was reported as "Signal:99 Fire" with no clue
	where it came from (N2, 2026-10-30), because Fire took the traceback AFTER pcall unwound the
	stack. Fire now uses xpcall with a message handler that runs at the error site.

	Checks:
		1. a throwing handler never stops the other handlers (before or after it) from running
		2. the error is reported (warn), never propagated to the caller of Fire
		3. the report's traceback names the failing handler's own function, not just Signal.Fire
		4. Fire passes every argument through, and Disconnect / Once still behave

	Run: lune run tests/signal.luau
]]

local Signal = require("../src/shared/Util/Signal")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(`[signal] FAILED: {label}`, 2)
	end
	checks += 1
end

-- Capture warn() output instead of printing it (lune's global warn is replaceable).
local warnings: { string } = {}
local realWarn = warn
local function captureWarn(...: any)
	local parts = {}
	for i = 1, select("#", ...) do
		table.insert(parts, tostring((select(i, ...))))
	end
	table.insert(warnings, table.concat(parts, " "))
end
-- Signal reads the global `warn`; swap it for the duration of the test.
local env = getfenv(Signal.Fire)
env.warn = captureWarn

-- 1 + 2 + 3: a throwing handler between two good ones.
local signal = Signal.new()
local seen: { string } = {}
signal:Connect(function(value: number)
	table.insert(seen, `first:{value}`)
end)
local function explodingProducerListener(_value: number)
	error("boom from the listener")
end
signal:Connect(explodingProducerListener)
signal:Connect(function(value: number)
	table.insert(seen, `third:{value}`)
end)

local fired = pcall(function()
	signal:Fire(7)
end)
check(fired, "Fire never propagates a handler error")
check(#seen == 2 and seen[1] == "first:7" and seen[2] == "third:7", "handlers before AND after the bad one still run")
check(#warnings == 1, `exactly one warning (got {#warnings})`)
local report = warnings[1] or ""
check(string.find(report, "boom from the listener", 1, true) ~= nil, "warning carries the error text")
check(
	string.find(report, "explodingProducerListener", 1, true) ~= nil
		or string.find(report, "tests/signal", 1, true) ~= nil,
	`traceback points at the failing handler, not just Signal.Fire:\n{report}`
)

-- 4: arguments, Disconnect, Once.
local multi = Signal.new()
local got: { any } = {}
local connection = multi:Connect(function(a: any, b: any, c: any)
	got = { a, b, c }
end)
multi:Fire(1, "two", true)
check(got[1] == 1 and got[2] == "two" and got[3] == true, "Fire passes every argument")
connection:Disconnect()
got = {}
multi:Fire(9)
check(got[1] == nil, "a disconnected handler is not called")
local onceCount = 0
multi:Once(function()
	onceCount += 1
end)
multi:Fire()
multi:Fire()
check(onceCount == 1, "Once fires exactly once")

env.warn = realWarn
print(`[signal] {checks} checks passed`)
