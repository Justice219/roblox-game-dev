--!strict
--[[
	BootRunner — runs one client boot phase (a controller's Init or Start) so that a phase which
	YIELDS can never stall the rest of the client boot (owner R103).

	Why:
		The client bootstrap (init.client.luau) runs every controller's Init, then every Start, in
		ORDERED order on ONE thread. A phase that yields (a WaitForChild without a timeout, a remote
		that is slow to replicate, a task.wait loop) used to hold that thread, so every controller
		after it started late or never (Tycoon/Fx/VehicleRoutes sits late in the list: the map
		vehicles stood still), and ClientBooted (the loading-screen hand-off) waited with them.

	How:
		* Each phase runs in its own thread under xpcall: an error is reported with a traceback and
		  never thrown into the boot.
		* A phase that returns without yielding (the normal case) has finished before run() returns,
		  exactly like a plain call, so the order semantics for dependent controllers are unchanged.
		* A phase that yields gets `options.budget` seconds: the caller waits for it (still in order)
		  and is resumed the moment it finishes (no polling). Past the budget the caller moves on with
		  a warning naming the phase; the phase keeps running in its own thread and reports when it
		  finally finishes (or fails).
		* after(job, ...) chains a dependent phase (a controller's Start after its own slow Init)
		  without holding the caller: it runs the moment `job` settles.

	Pure: only `coroutine`, `xpcall` plus the injected `warn` / `clock` / `scheduler`. The scheduler
	defaults to Roblox's `task` library (BootRunner.TaskScheduler: spawn / defer / delay / cancel);
	tests/boot-runner.luau injects a deterministic virtual-time scheduler instead, so the suite never
	sleeps for real and never leaves engine timers behind (it finishes in milliseconds).

	Connects to: init.client.luau (the only caller), Shared/Config/ClientBootConfig (budgets).

	Example:
		local options = { budget = 2, warn = warn }
		local init = BootRunner.run("UIController.Init", UIController.Init, options)
		BootRunner.after(init, "UIController.Start", UIController.Start, options)
]]

local BootRunner = {}

export type Status = "running" | "done" | "failed"

export type Options = {
	-- Seconds the caller waits for a phase that yields before it moves on (0 = never wait).
	budget: number,
	-- Where problems are reported (Roblox `warn` in production, a capture in tests).
	warn: (message: string) -> (),
	-- Monotonic clock in seconds for the timings in the warnings (defaults to os.clock).
	clock: (() -> number)?,
	-- Thread scheduler (defaults to BootRunner.TaskScheduler, i.e. Roblox `task`).
	scheduler: Scheduler?,
}

--[[
	The few scheduling primitives BootRunner needs. Production passes nothing (Roblox `task`, see
	TaskScheduler); tests inject a fake with virtual time.
]]
export type Scheduler = {
	spawn: (fn: () -> ()) -> (), -- run fn in a new thread right now (task.spawn)
	resume: (thread: thread) -> (), -- resume a suspended thread right now (task.spawn(thread))
	defer: (thread: thread) -> (), -- resume a suspended thread later this frame (task.defer)
	delay: (seconds: number, fn: () -> ()) -> thread, -- run fn after `seconds` (task.delay)
	cancel: (timer: thread) -> (), -- drop a pending delay (task.cancel)
}

export type Job = {
	label: string, -- "<controller>.<Init|Start>", used in every warning
	status: Status,
	-- True when the phase outlived the budget: the caller moved on while it was still running.
	slow: boolean,
	startedAt: number,
	elapsed: number, -- seconds the phase ran (0 until it settles)
	err: string?, -- error + traceback when status == "failed"
	waiters: { (job: Job) -> () }, -- after() continuations, run once when the phase settles
}

-- "1.25" style seconds for the warnings (never NaN: elapsed comes from a monotonic clock).
local function seconds(value: number): string
	return string.format("%.2f", value)
end

-- xpcall message handler: the error plus the stack of the failing phase (level 2 skips this one).
local function traceback(err: unknown): string
	return debug.traceback(tostring(err), 2)
end

--[[
	The production scheduler: Roblox's `task` library (read at call time, never at load).
	Example: BootRunner.run(label, fn, { budget = 2, warn = warn, scheduler = BootRunner.TaskScheduler })
]]
BootRunner.TaskScheduler = table.freeze({
	spawn = function(fn: () -> ())
		task.spawn(fn)
	end,
	resume = function(thread: thread)
		task.spawn(thread)
	end,
	defer = function(thread: thread)
		task.defer(thread)
	end,
	delay = function(delaySeconds: number, fn: () -> ()): thread
		return task.delay(delaySeconds, fn)
	end,
	cancel = function(timer: thread)
		task.cancel(timer)
	end,
}) :: Scheduler

--[[
	Runs `fn` as the boot phase `label` (see the module header for the budget rules).
	@param label string   shown in every warning, e.g. "VehicleRoutes.Start"
	@param fn () -> ()    the phase (a controller's Init / Start)
	@param options Options budget (seconds), warn, optional clock
	@return Job           settled ("done" / "failed") unless it outlived the budget ("running", slow)
	Must be called from a yieldable thread (a script's main thread or a task.spawn thread).
	Example:
		local job = BootRunner.run("PetController.Init", PetController.Init, { budget = 2, warn = warn })
		if job.slow then print("PetController.Init is still booting") end
]]
function BootRunner.run(label: string, fn: () -> (), options: Options): Job
	local clock = options.clock or os.clock
	local scheduler = options.scheduler or BootRunner.TaskScheduler
	local job: Job = {
		label = label,
		status = "running",
		slow = false,
		startedAt = clock(),
		elapsed = 0,
		err = nil,
		waiters = {},
	}
	local caller = coroutine.running()
	-- True only while the caller is suspended in the coroutine.yield below, waiting for this job.
	local parked = false

	-- Records the outcome, wakes a waiting caller, then runs the after() continuations.
	local function settle(ok: boolean, err: unknown)
		job.status = if ok then "done" else "failed"
		job.elapsed = clock() - job.startedAt
		if not ok then
			job.err = tostring(err)
			options.warn(`[Client] {label} failed: {job.err}`)
		elseif job.slow then
			options.warn(`[Client] {label} finished late ({seconds(job.elapsed)} s after it started)`)
		end
		if parked then
			-- Deferred (same frame): the rest of the boot never runs nested inside this thread.
			parked = false
			scheduler.defer(caller)
		end
		local waiters = job.waiters
		job.waiters = {}
		for _, waiter in waiters do
			scheduler.spawn(function()
				waiter(job)
			end)
		end
	end

	scheduler.spawn(function()
		-- Returns nil on success; on failure xpcall returns the handler's message + traceback.
		local ok, err = xpcall(function(): string?
			fn()
			return nil
		end, traceback)
		settle(ok, err)
	end)
	if job.status ~= "running" then
		return job -- returned without yielding: exactly a plain in-order call
	end

	-- It yielded: wait (in order) up to the budget, resumed by settle() or by the timer.
	local budget = options.budget
	if budget == budget and budget > 0 then
		parked = true
		local fired = false
		local timer = scheduler.delay(budget, function()
			fired = true
			if parked then
				parked = false
				scheduler.resume(caller)
			end
		end)
		coroutine.yield()
		if not fired then
			scheduler.cancel(timer)
		end
	end
	if job.status == "running" then
		job.slow = true
		options.warn(
			`[Client] {label} is still running after {seconds(clock() - job.startedAt)} s (it yields); `
				.. "booting the controllers after it without waiting"
		)
	end
	return job
end

--[[
	Runs `fn` as phase `label` once `job` has settled (done OR failed — the boot always ran a
	controller's Start after a failed Init, and still does). If `job` already settled this is
	run(); otherwise the phase is queued on `job` and the caller continues at once (the queued
	phase then gets its own budget inside `job`'s thread, never the caller's).
	@return Job? the phase's job when it ran now, nil when it was queued behind a running `job`
	Example (a controller whose Init is still yielding):
		BootRunner.after(initJob, "WorldClient.Start", WorldClient.Start, options)
]]
function BootRunner.after(job: Job, label: string, fn: () -> (), options: Options): Job?
	if job.status ~= "running" then
		return BootRunner.run(label, fn, options)
	end
	options.warn(`[Client] {label} waits for {job.label} (still running); the boot continues`)
	BootRunner.onSettled(job, function()
		BootRunner.run(label, fn, options)
	end)
	return nil
end

--[[
	Calls `callback(job)` once `job` has settled: right now (same thread) when it already has,
	otherwise in a fresh thread the moment it settles. Never yields the caller.
	Example (a controller whose require outlived the budget boots itself once it loads):
		BootRunner.onSettled(loadJob, function() bootLate(name) end)
]]
function BootRunner.onSettled(job: Job, callback: (job: Job) -> ())
	if job.status ~= "running" then
		callback(job)
		return
	end
	table.insert(job.waiters, callback)
end

return table.freeze(BootRunner)
