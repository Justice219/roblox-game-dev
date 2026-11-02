--!strict
--[[
	Client boot runner (owner R103: "none of the vehicles are animating like they used to"). Run:
		lune run tests/boot-runner

	Loads the REAL src/client/BootRunner.luau (through tests/fixtures/RobloxLoader) and the shipped
	Shared/Config/ClientBootConfig, and drives it with a DETERMINISTIC VIRTUAL-TIME scheduler
	(BootRunner's injectable `scheduler` + `clock`): no @lune/task, no real sleeps, no engine timers
	left behind, so the suite finishes in milliseconds and the process always exits (an earlier
	version slept on @lune/task and could keep Lune alive after its last check). Proves:
	  1. A phase that never yields settles before run() returns (a plain in-order call) and the next
	     phase only starts afterwards; no warning; no timer is armed.
	  2. An erroring phase is "failed" with its message, warned, never thrown.
	  3. A phase that yields inside the budget is waited for: the caller resumes exactly when it
	     finishes (not at the budget), in order, with no warning; the budget timer is cancelled.
	  4. A phase that yields past the budget (or forever) holds the caller for exactly the budget:
	     run() returns a "running", slow job with a warning naming it; when it finally finishes it
	     reports "finished late" (or "failed" when it errors late).
	  5. Budget 0 / NaN never waits for a yielding phase.
	  6. after(): a settled job runs the next phase at once; a running job queues it (the caller is
	     not held) and runs it the moment the job settles — also after a failure (Init failed ->
	     Start still runs, the old loader's behaviour). onSettled() fires once, never twice.
	  7. The R103 regression shape, with the SHIPPED Start budget: a controller Start that yields
	     forever ahead of "VehicleRoutes.Start" delays it by exactly one budget, never forever.
	  8. ClientBootConfig budgets are finite, positive and small; BootRunner.TaskScheduler (the
	     production default) exposes the five primitives; both modules are frozen.
]]

local Loader = require("./fixtures/RobloxLoader")
local loader = Loader.new()
local BootRunner = loader.load("src/client/BootRunner")
local ClientBootConfig = loader.load("src/shared/Config/ClientBootConfig")

local checks = 0
local function ok(condition: any, label: string)
	if not condition then
		error(label, 2)
	end
	checks += 1
end

local EPS = 1e-9
local function near(a: number, b: number): boolean
	return math.abs(a - b) <= EPS
end

--[[
	Fake scheduler with virtual time (same contract as BootRunner.TaskScheduler):
		spawn(fn) / resume(thread)  run now; defer(thread) runs at the next drain;
		delay(s, fn) arms a timer (returns its thread); cancel(timer) drops it.
	Test helpers: now(), sleep(s) (suspends the calling thread for s virtual seconds),
	advance(s) (fires due timers in time order, draining deferred threads after each), pending().
	Every thread is a plain coroutine, so nothing can outlive the test.
]]
type Fake = {
	spawn: (fn: () -> ()) -> (),
	resume: (thread: thread) -> (),
	defer: (thread: thread) -> (),
	delay: (seconds: number, fn: () -> ()) -> thread,
	cancel: (timer: thread) -> (),
	now: () -> number,
	sleep: (seconds: number) -> (),
	advance: (seconds: number) -> (),
	pending: () -> number,
}

local function newScheduler(): Fake
	local now = 0
	local seq = 0
	local deferred: { thread } = {}
	local timers: { { at: number, seq: number, thread: thread } } = {}
	local cancelled: { [thread]: boolean } = {}

	-- Resumes a suspended coroutine; a test failure inside it is re-raised here.
	local function resume(thread: thread)
		if coroutine.status(thread) ~= "suspended" then
			return
		end
		local success, err = coroutine.resume(thread)
		if not success then
			error(err, 0)
		end
	end

	local function drain()
		while #deferred > 0 do
			resume(table.remove(deferred, 1) :: thread)
		end
	end

	local fake: Fake
	fake = {
		spawn = function(fn: () -> ())
			resume(coroutine.create(fn))
		end,
		resume = resume,
		defer = function(thread: thread)
			table.insert(deferred, thread)
		end,
		delay = function(seconds: number, fn: () -> ()): thread
			local thread = coroutine.create(fn)
			seq += 1
			table.insert(timers, { at = now + seconds, seq = seq, thread = thread })
			return thread
		end,
		cancel = function(timer: thread)
			cancelled[timer] = true
		end,
		now = function(): number
			return now
		end,
		sleep = function(seconds: number)
			local thread = coroutine.running()
			fake.delay(seconds, function()
				resume(thread)
			end)
			coroutine.yield()
		end,
		advance = function(seconds: number)
			local target = now + seconds
			drain()
			while true do
				local best: number? = nil
				for index, timer in timers do
					if timer.at <= target + EPS then
						local current = if best ~= nil then timers[best] else nil
						if
							current == nil
							or timer.at < current.at
							or (timer.at == current.at and timer.seq < current.seq)
						then
							best = index
						end
					end
				end
				if best == nil then
					break
				end
				local timer = table.remove(timers, best :: number) :: { at: number, seq: number, thread: thread }
				if not cancelled[timer.thread] then
					now = math.max(now, timer.at)
					resume(timer.thread)
					drain()
				end
			end
			now = target
			drain()
		end,
		pending = function(): number
			local count = 0
			for _, timer in timers do
				if not cancelled[timer.thread] then
					count += 1
				end
			end
			return count
		end,
	}
	return fake
end

-- Options wired to a fake scheduler (virtual clock) + captured warnings.
local function newOptions(sched: Fake, budget: number): (any, { string })
	local warnings: { string } = {}
	local options = {
		budget = budget,
		warn = function(message: string)
			table.insert(warnings, message)
		end,
		clock = sched.now,
		scheduler = sched,
	}
	return options, warnings
end

local function anyContains(list: { string }, needle: string): boolean
	for _, line in list do
		if string.find(line, needle, 1, true) ~= nil then
			return true
		end
	end
	return false
end

-- 1. Non-yielding phase: a plain in-order call.
do
	local sched = newScheduler()
	local options, warnings = newOptions(sched, 1)
	local order: { string } = {}
	local finished = false
	sched.spawn(function()
		local job = BootRunner.run("A.Init", function()
			table.insert(order, "A")
		end, options)
		ok(job.status == "done" and not job.slow, "sync: done, not slow")
		ok(#order == 1, "sync: ran before run() returned")
		BootRunner.run("B.Init", function()
			table.insert(order, "B")
		end, options)
		ok(order[1] == "A" and order[2] == "B", "sync: order kept")
		finished = true
	end)
	ok(finished, "sync: the caller never yielded")
	ok(#warnings == 0, "sync: no warnings")
	ok(sched.pending() == 0, "sync: no budget timer armed")
end

-- 2. Errors are contained and reported.
do
	local sched = newScheduler()
	local options, warnings = newOptions(sched, 1)
	local job: any = nil
	sched.spawn(function()
		job = BootRunner.run("Broken.Init", function()
			error("boom")
		end, options)
	end)
	ok(job ~= nil and job.status == "failed", "error: failed (never thrown)")
	ok(type(job.err) == "string" and string.find(job.err, "boom", 1, true) ~= nil, "error: message kept")
	ok(anyContains(warnings, "[Client] Broken.Init failed:"), "error: warned with the label")
end

-- 3. A yield inside the budget is waited for; the caller resumes exactly when it finishes.
do
	local sched = newScheduler()
	local options, warnings = newOptions(sched, 2)
	local order: { string } = {}
	local job: any = nil
	local waited = -1
	sched.spawn(function()
		local started = sched.now()
		job = BootRunner.run("Short.Start", function()
			sched.sleep(0.1)
			table.insert(order, "short")
		end, options)
		waited = sched.now() - started
		table.insert(order, "next")
	end)
	ok(job == nil, "short yield: the caller waits (in order)")
	sched.advance(0.1)
	ok(job ~= nil and job.status == "done" and not job.slow, "short yield: done, not slow")
	ok(near(waited, 0.1), `short yield: resumed when it finished, not at the budget ({waited} s)`)
	ok(order[1] == "short" and order[2] == "next", "short yield: order kept")
	ok(#warnings == 0, "short yield: no warnings")
	ok(sched.pending() == 0, "short yield: budget timer cancelled")
	ok(near(job.elapsed, 0.1), "short yield: elapsed recorded")
end

-- 4a. A yield past the budget holds the caller for exactly the budget; the late finish is reported.
do
	local sched = newScheduler()
	local options, warnings = newOptions(sched, 0.2)
	local job: any = nil
	local waited = -1
	sched.spawn(function()
		local started = sched.now()
		job = BootRunner.run("Slow.Start", function()
			sched.sleep(0.6)
		end, options)
		waited = sched.now() - started
	end)
	ok(job == nil, "long yield: the caller waits up to the budget")
	sched.advance(0.2)
	ok(job ~= nil and job.status == "running" and job.slow, "long yield: returned while still running, slow")
	ok(near(waited, 0.2), `long yield: waited exactly the budget ({waited} s)`)
	ok(anyContains(warnings, "Slow.Start is still running after 0.20 s"), "long yield: warned with the label")
	sched.advance(0.4)
	ok(job.status == "done" and near(job.elapsed, 0.6), "long yield: finished in its own thread")
	ok(anyContains(warnings, "Slow.Start finished late (0.60 s"), "long yield: late finish reported")
end

-- 4b. A late failure is reported.
do
	local sched = newScheduler()
	local options, warnings = newOptions(sched, 0.2)
	local job: any = nil
	sched.spawn(function()
		job = BootRunner.run("LateFail.Start", function()
			sched.sleep(0.4)
			error("late boom")
		end, options)
	end)
	sched.advance(0.2)
	ok(job ~= nil and job.slow and job.status == "running", "late failure: slow first")
	sched.advance(0.2)
	ok(job.status == "failed", "late failure: failed")
	ok(anyContains(warnings, "LateFail.Start failed:"), "late failure: reported")
end

-- 4c. A phase that yields FOREVER (a WaitForChild that never resolves).
do
	local sched = newScheduler()
	local options, warnings = newOptions(sched, 0.15)
	local job: any = nil
	sched.spawn(function()
		job = BootRunner.run("Stuck.Init", function()
			coroutine.yield() -- never resumed
		end, options)
	end)
	sched.advance(0.15)
	ok(job ~= nil and job.status == "running" and job.slow, "forever: the caller moved on after the budget")
	ok(anyContains(warnings, "Stuck.Init is still running"), "forever: warned")
end

-- 5. Budget 0 (or NaN) never waits for a yielding phase.
for _, budget in { 0, 0 / 0 } do
	local sched = newScheduler()
	local options = newOptions(sched, budget)
	local job: any = nil
	sched.spawn(function()
		job = BootRunner.run("Zero.Start", function()
			sched.sleep(0.3)
		end, options)
	end)
	ok(job ~= nil and job.slow and job.status == "running", `zero budget ({budget}): returned at once, slow`)
	ok(sched.now() == 0, "zero budget: no virtual time passed")
	sched.advance(0.3)
	ok(job.status == "done", "zero budget: the phase still finishes")
end

-- 6. after() + onSettled().
do
	local sched = newScheduler()
	local options, warnings = newOptions(sched, 0.1)
	local order: { string } = {}
	local settled: any, initJob: any, failedInit: any, pending: any = nil, nil, nil, nil
	local queued: any = "unset"
	local afterTook = -1
	local startRan = false
	local fired = 0
	sched.spawn(function()
		-- Settled job: the next phase runs now, synchronously.
		settled = BootRunner.run("Ready.Init", function() end, options)
		local now = BootRunner.after(settled, "Ready.Start", function()
			table.insert(order, "ready-start")
		end, options)
		ok(now ~= nil and now.status == "done", "after: settled job runs the phase now")
		ok(order[1] == "ready-start", "after: ran synchronously")

		-- Running job: queued; the caller is not held.
		initJob = BootRunner.run("Late.Init", function()
			sched.sleep(0.3)
			table.insert(order, "late-init")
		end, options)
		local before = sched.now()
		queued = BootRunner.after(initJob, "Late.Start", function()
			table.insert(order, "late-start")
		end, options)
		afterTook = sched.now() - before
		table.insert(order, "boot-continues")

		-- A failed Init still lets its Start run (the old loader's contract).
		failedInit = BootRunner.run("Bad.Init", function()
			sched.sleep(0.2)
			error("init broke")
		end, options)
		BootRunner.after(failedInit, "Bad.Start", function()
			startRan = true
		end, options)

		-- onSettled: settled now -> synchronous; running -> once, on settle.
		BootRunner.onSettled(settled, function()
			fired += 1
		end)
		pending = BootRunner.run("Pending.Init", function()
			sched.sleep(0.2)
		end, options)
		BootRunner.onSettled(pending, function(job: any)
			fired += 1
			ok(job == pending, "onSettled: passes the job")
		end)
	end)
	-- t = 0.1: Late.Init outlived its budget.
	sched.advance(0.1)
	ok(initJob ~= nil and initJob.slow, "after: init outlived the budget")
	ok(queued == nil, "after: queued behind the running job")
	ok(afterTook == 0, "after: the caller was not held")
	ok(anyContains(warnings, "Late.Start waits for Late.Init"), "after: the wait is reported")
	ok(order[2] == "boot-continues", "after: the boot continued first")
	-- Bad.Init started at 0.1 (budget to 0.2), Pending.Init at 0.2 (budget to 0.3).
	sched.advance(0.4)
	ok(order[3] == "late-init" and order[4] == "late-start", "after: Start right after its own Init")
	ok(failedInit.status == "failed", "after: init failed")
	ok(startRan, "after: Start still ran after a failed Init")
	ok(pending.status == "done", "onSettled: pending job settled")
	ok(fired == 2, `onSettled: fired once per job ({fired})`)
	sched.advance(1)
	ok(fired == 2, "onSettled: never fires twice")
end

-- 7. The R103 shape with the shipped Start budget: a Start stuck ahead of VehicleRoutes.Start.
do
	local sched = newScheduler()
	local budget = ClientBootConfig.StartBudgetSeconds
	local options = newOptions(sched, budget)
	local vehiclesStartedAt: number? = nil
	local phases: { { any } } = {
		{ "FlavorController.Start", function() end },
		{
			"ManagerController.Start",
			function()
				coroutine.yield() -- e.g. a WaitForChild that never resolves
			end,
		},
		{ "KnockdownFx.Start", function() end },
		{
			"VehicleRoutes.Start",
			function()
				vehiclesStartedAt = sched.now()
			end,
		},
	}
	sched.spawn(function()
		for _, phase in phases do
			BootRunner.run(phase[1], phase[2], options)
		end
	end)
	ok(vehiclesStartedAt == nil, "R103: the stuck Start is waited for first (in order)")
	sched.advance(budget)
	ok(vehiclesStartedAt ~= nil, "R103: VehicleRoutes.Start ran despite a stuck controller before it")
	ok(near(vehiclesStartedAt :: number, budget), "R103: delayed by exactly one Start budget")
end

-- 8. Shipped budgets + production scheduler shape.
for _, key in { "InitBudgetSeconds", "StartBudgetSeconds" } do
	local value = ClientBootConfig[key]
	ok(type(value) == "number" and value == value, `config: {key} is a number`)
	ok(value > 0 and value <= 10, `config: {key} is positive and small ({value})`)
end
ok(ClientBootConfig.StartBudgetSeconds >= ClientBootConfig.InitBudgetSeconds, "config: Start budget >= Init budget")
for _, name in { "spawn", "resume", "defer", "delay", "cancel" } do
	ok(type(BootRunner.TaskScheduler[name]) == "function", `TaskScheduler.{name} exists`)
end
ok(table.isfrozen(BootRunner.TaskScheduler), "TaskScheduler: frozen")
ok(table.isfrozen(ClientBootConfig), "config: frozen")
ok(table.isfrozen(BootRunner), "module: frozen")

print(`[boot-runner] {checks} checks passed`)
