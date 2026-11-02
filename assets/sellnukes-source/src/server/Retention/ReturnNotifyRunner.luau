--!strict
--[[
	ReturnNotifyRunner — the return-notification pipeline of ONE server, with every Roblox
	dependency injected (owner R122 §2.3). ReturnNotifyService wires the real queue / sender /
	clocks / analytics; tests/return-notify.luau drives it with fakes end to end.

	Pipeline:
		plan(player, facts)        a player LEFT: queue.plan → "rnotify:plan:<kind>",
		                           "rnotify:drop:replaced" (an older pending entry), or
		                           "rnotify:drop:rejoined" (they already joined another server)
		join(player, userId, at)   a player JOINED: queue.join cancels their pending entry →
		                           "rnotify:drop:rejoined"
		pollOnce()                 every server, every PollSeconds: read up to BatchSize due entries
		                           (never more than the send bucket allows), claim each (exactly one
		                           server wins), then
		                             late → "rnotify:drop:late"      (finished in the claim)
		                             off  → "rnotify:result:off"     (kill switch / kind off / no id)
		                             send → its own thread: sender.send → "rnotify:result:<r>"
		                                    (+ "rnotify:status:<kind>:<400|401|403|404|429|4xx|5xx>"
		                                    when Roblox answered with an error, R136),
		                                    ok → "rnotify:sent:<kind>"; queue.finish(sent | done |
		                                    retry); server back-off on 429 / 5xx / no response
		                                    (exponential, Retry-After honoured), key back-off on
		                                    401 / 403
		sendTest(...)              admin "send test to me": straight to the sender (bucket applies)

	Timeouts: the send thread races the request against Send.TimeoutSeconds. On a timeout the
	concurrency slot is freed, the result counts as "http" and the server backs off; when the
	answer still arrives the entry is finished by it (an ok also counts "rnotify:sent:<kind>"),
	without counting a second result. A request that never answers loses its claim when the lease
	runs out; another server retries it then (a stale finish is refused: "lost").

	Performance: no per-player loops; one poll per PollSeconds, at most MaxInFlight concurrent
	requests, a token bucket of Burst / PerSecond sends. Analytics calls never yield.

	Connects to: Server/Retention/{ReturnNotifyLogic, ReturnNotifyQueue, ReturnNotifySender},
	Shared/Config/NotifyConfig; used by Server/Retention/{ReturnNotifyService, ReturnNotifyAdmin}.

	Example:
		local runner = ReturnNotifyRunner.new({ queue = queue, sender = sender, control = control.current,
			now = os.time, clock = os.clock, track = RewardGrant.track, jobId = game.JobId,
			spawn = task.spawn, delay = task.delay })
		runner.pollOnce()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NotifyConfig = require(ReplicatedStorage.Shared.Config.NotifyConfig)
local ReturnNotifyLogic = require(script.Parent.ReturnNotifyLogic)
local ReturnNotifyQueue = require(script.Parent.ReturnNotifyQueue)
local ReturnNotifySender = require(script.Parent.ReturnNotifySender)

type Kind = ReturnNotifyLogic.Kind
type Control = ReturnNotifyLogic.Control
type Facts = ReturnNotifyLogic.Facts

export type Deps = {
	queue: ReturnNotifyQueue.Queue,
	sender: ReturnNotifySender.Sender,
	control: () -> Control,
	now: () -> number, -- unix seconds (os.time)
	clock: () -> number, -- monotonic seconds (os.clock)
	track: (player: Player?, key: string) -> (), -- analytics (retention family); never yields
	jobId: string,
	spawn: (fn: () -> ()) -> (), -- task.spawn
	delay: (seconds: number, fn: () -> ()) -> (), -- task.delay
}

export type RecentResult = { at: number, kind: string, result: string, detail: string? }

export type PollReport = {
	reason: string, -- "ok" | "busy" | "backoff" | "limited" | "error"
	read: number,
	claimed: number,
	late: number,
	off: number,
}

export type Stats = {
	planned: { [string]: number },
	sent: { [string]: number },
	results: { [string]: number },
	drops: { [string]: number },
	recent: { RecentResult },
	inFlight: number,
	backoffLeft: number,
	failures: number,
	tokens: number,
	polls: number,
	lastPoll: PollReport?,
	queueErrors: number,
}

export type Runner = {
	plan: (player: Player?, facts: Facts) -> ReturnNotifyLogic.PlanOutcome?,
	join: (player: Player?, userId: number, joinAt: number) -> ReturnNotifyLogic.JoinOutcome?,
	pollOnce: () -> PollReport,
	sendTest: (
		player: Player?,
		userId: number,
		kind: Kind,
		params: { [string]: string }?
	) -> ReturnNotifySender.SendResult,
	queueTest: (userId: number, kind: Kind, params: { [string]: string }?, seconds: number) -> boolean,
	stats: () -> Stats,
}

local Send = NotifyConfig.Send
local Queue = NotifyConfig.Queue

local ReturnNotifyRunner = {}

-- +1 on a counter map.
local function bump(map: { [string]: number }, key: string)
	map[key] = (map[key] or 0) + 1
end

--[[
	Builds the runner of this server.
	@param deps Deps
	@return Runner
]]
function ReturnNotifyRunner.new(deps: Deps): Runner
	local bucket = ReturnNotifyLogic.newBucket(Send.Burst, Send.PerSecond, deps.clock())
	local tokenCounter = 0
	local inFlight = 0
	local failures = 0
	local backoffUntil = -math.huge
	local polling = false
	local stats = {
		planned = {} :: { [string]: number },
		sent = {} :: { [string]: number },
		results = {} :: { [string]: number },
		drops = {} :: { [string]: number },
		recent = {} :: { RecentResult },
		polls = 0,
		lastPoll = nil :: PollReport?,
		queueErrors = 0,
	}

	-- A fresh claim token (unique per server and claim).
	local function nextToken(): string
		tokenCounter += 1
		return ReturnNotifyLogic.claimToken(deps.jobId, tokenCounter)
	end

	-- Records one send result (analytics + counters + the admin ring).
	local function noteResult(player: Player?, kind: string, result: string, detail: string?)
		bump(stats.results, result)
		deps.track(player, `rnotify:result:{result}`)
		table.insert(stats.recent, 1, { at = deps.now(), kind = kind, result = result, detail = detail })
		while #stats.recent > Send.RecentResults do
			table.remove(stats.recent)
		end
	end

	-- R136: the HTTP status of a send Roblox answered with an error ("rnotify:status:<kind>:<bucket>"),
	-- so a report can tell players with notifications off (400) from a broken key (401 / 403).
	local function noteStatus(player: Player?, kind: string, result: ReturnNotifySender.SendResult)
		local verdict = result.verdict
		if result.result ~= "ok" and verdict ~= nil and verdict.status > 0 then
			deps.track(player, `rnotify:status:{kind}:{ReturnNotifyLogic.statusBucket(verdict.status)}`)
		end
	end

	-- A dropped entry (late / rejoined / replaced).
	local function noteDrop(player: Player?, reason: string)
		bump(stats.drops, reason)
		deps.track(player, `rnotify:drop:{reason}`)
	end

	-- Applies the server back-off a verdict asks for.
	local function applyBackoff(kind: "none" | "short" | "key", retryAfter: number?)
		if kind == "none" then
			failures = 0
			return
		end
		if kind == "key" then
			backoffUntil = math.max(backoffUntil, deps.clock() + Send.KeyBackoffSeconds)
			return
		end
		failures += 1
		backoffUntil = math.max(backoffUntil, deps.clock() + ReturnNotifyLogic.backoffSeconds(failures, retryAfter))
	end

	-- Gives one bucket token back (a claim that did not send).
	local function refund()
		bucket.tokens = math.min(bucket.capacity, bucket.tokens + 1)
	end

	-- Finishes a claimed entry and counts a stale ("lost") finish as a queue note only.
	local function finish(
		userId: number,
		entry: ReturnNotifyLogic.Entry,
		token: string,
		verdict: ReturnNotifyLogic.FinishVerdict
	)
		local ok = deps.queue.finish(userId, entry, token, verdict, deps.now())
		if not ok then
			stats.queueErrors += 1
		end
	end

	-- Sends one claimed entry on the current thread (spawned by the poll), with the timeout race.
	local function sendClaimed(userId: number, entry: ReturnNotifyLogic.Entry, token: string)
		local settled = false -- the poll slot was released (answer or timeout)
		local timedOut = false
		local function release()
			if not settled then
				settled = true
				inFlight -= 1
			end
		end
		deps.delay(Send.TimeoutSeconds, function()
			if not settled then
				timedOut = true
				release()
				noteResult(nil, entry.k, "http", "timeout")
				applyBackoff("short", nil)
			end
		end)
		local okSend, outcome = pcall(deps.sender.send, userId, entry.k, entry.p)
		local result: ReturnNotifySender.SendResult = if okSend
			then outcome
			else { result = "http", detail = "sender error" }
		release()
		if not timedOut then
			noteResult(nil, entry.k, result.result, result.detail)
			noteStatus(nil, entry.k, result)
		end
		local verdict = result.verdict
		if result.result == "ok" then
			bump(stats.sent, entry.k)
			deps.track(nil, `rnotify:sent:{entry.k}`)
			applyBackoff("none", nil)
			finish(userId, entry, token, "sent")
		elseif verdict ~= nil then
			if not timedOut then
				applyBackoff(verdict.backoff, verdict.retryAfter)
			end
			finish(userId, entry, token, verdict.entry)
		elseif result.result == "http" then
			if not timedOut then
				applyBackoff("short", nil)
			end
			finish(userId, entry, token, "retry")
		else
			-- dry / nokey / off: nothing more will happen for this entry.
			finish(userId, entry, token, "done")
		end
	end

	local runner = {} :: Runner

	--[[
		A player left: plans their notification (yields on the queue). Analytics:
		plan:<kind>, drop:replaced, drop:rejoined.
	]]
	function runner.plan(player: Player?, facts: Facts): ReturnNotifyLogic.PlanOutcome?
		local ok, outcome = deps.queue.plan(facts, deps.control(), deps.now())
		if not ok or outcome == nil then
			stats.queueErrors += 1
			return nil
		end
		local plan = outcome.plan
		if outcome.result == "planned" and plan ~= nil then
			bump(stats.planned, plan.kind)
			deps.track(player, `rnotify:plan:{plan.kind}`)
			if outcome.replaced ~= nil then
				noteDrop(player, "replaced")
			end
		elseif outcome.result == "skipJoined" then
			noteDrop(player, "rejoined")
		end
		return outcome
	end

	--[[ A player joined: cancels their pending entry (yields). Analytics: drop:rejoined. ]]
	function runner.join(player: Player?, userId: number, joinAt: number): ReturnNotifyLogic.JoinOutcome?
		local ok, outcome = deps.queue.join(userId, joinAt, deps.now())
		if not ok or outcome == nil then
			stats.queueErrors += 1
			return nil
		end
		if outcome.cancelled ~= nil then
			noteDrop(player, "rejoined")
		end
		return outcome
	end

	--[[
		One poll (yields on the queue; sends run on their own threads). Re-entrant calls return
		"busy" at once.
		@return PollReport
	]]
	function runner.pollOnce(): PollReport
		local report: PollReport = { reason = "ok", read = 0, claimed = 0, late = 0, off = 0 }
		if polling then
			report.reason = "busy"
			return report
		end
		stats.polls += 1
		local clock = deps.clock()
		if clock < backoffUntil then
			report.reason = "backoff"
			stats.lastPoll = report
			return report
		end
		local room = math.min(Queue.BatchSize, Send.MaxInFlight - inFlight, ReturnNotifyLogic.tokens(bucket, clock))
		if room <= 0 then
			report.reason = if inFlight >= Send.MaxInFlight then "busy" else "limited"
			stats.lastPoll = report
			return report
		end
		polling = true
		local okPoll, err = pcall(function()
			local okRead, items = deps.queue.due(deps.now(), room)
			if not okRead then
				stats.queueErrors += 1
				report.reason = "error"
				return
			end
			report.read = #items
			local control = deps.control()
			for _, item in items do
				if deps.clock() < backoffUntil or inFlight >= Send.MaxInFlight then
					break
				end
				if not ReturnNotifyLogic.take(bucket, deps.clock()) then
					report.reason = "limited"
					break
				end
				local token = nextToken()
				local okClaim, outcome = deps.queue.claim(item, deps.now(), token, control)
				if not okClaim or outcome == nil then
					refund()
					stats.queueErrors += 1
					report.reason = "error"
					break
				end
				if outcome.action == "send" and outcome.entry ~= nil then
					report.claimed += 1
					inFlight += 1
					local entry = outcome.entry
					deps.spawn(function()
						sendClaimed(item.userId, entry, token)
					end)
				else
					refund()
					if outcome.action == "late" then
						report.late += 1
						noteDrop(nil, "late")
					elseif outcome.action == "off" and outcome.entry ~= nil then
						report.off += 1
						noteResult(nil, outcome.entry.k, "off", "switched off")
					end
				end
			end
		end)
		polling = false
		if not okPoll then
			report.reason = "error"
			stats.queueErrors += 1
			warn(`[ReturnNotify] poll failed: {err}`)
		end
		stats.lastPoll = report
		return report
	end

	--[[
		Admin "send test to me": one request straight to the sender (no queue, no kill switch;
		the bucket and the server back-off still apply). Analytics: rnotify:result:<r> for the
		caller (staff-diverted on live servers).
	]]
	function runner.sendTest(
		player: Player?,
		userId: number,
		kind: Kind,
		params: { [string]: string }?
	): ReturnNotifySender.SendResult
		if deps.clock() < backoffUntil then
			return { result = "http", detail = `backing off {math.ceil(backoffUntil - deps.clock())} s` }
		end
		if not ReturnNotifyLogic.take(bucket, deps.clock()) then
			return { result = "throttled", detail = "server send limit (try again in a few seconds)" }
		end
		local okSend, outcome = pcall(deps.sender.send, userId, kind, params)
		local result: ReturnNotifySender.SendResult = if okSend
			then outcome
			else { result = "http", detail = "sender error" }
		noteResult(player, kind, result.result, result.detail)
		noteStatus(player, kind, result)
		local verdict = result.verdict
		if result.result == "ok" then
			applyBackoff("none", nil)
		elseif verdict ~= nil then
			applyBackoff(verdict.backoff, verdict.retryAfter)
		end
		return result
	end

	--[[
		Admin queue test (Studio): writes an entry for `userId` due in `seconds` (SetAsync).
		@return true when written
	]]
	function runner.queueTest(userId: number, kind: Kind, params: { [string]: string }?, seconds: number): boolean
		local now = deps.now()
		local entry: ReturnNotifyLogic.Entry = {
			v = 1,
			k = kind,
			d = now + math.max(0, math.floor(seconds)),
			p = if params ~= nil and next(params) ~= nil then params else nil,
			at = now,
		}
		return deps.queue.put(userId, entry, now)
	end

	--[[ A snapshot of this server's counters (admin status). ]]
	function runner.stats(): Stats
		local clock = deps.clock()
		return {
			planned = table.clone(stats.planned),
			sent = table.clone(stats.sent),
			results = table.clone(stats.results),
			drops = table.clone(stats.drops),
			recent = table.clone(stats.recent),
			inFlight = inFlight,
			backoffLeft = math.max(0, backoffUntil - clock),
			failures = failures,
			tokens = ReturnNotifyLogic.tokens(bucket, clock),
			polls = stats.polls,
			lastPoll = stats.lastPoll,
			queueErrors = stats.queueErrors,
		}
	end

	return runner
end

return ReturnNotifyRunner
