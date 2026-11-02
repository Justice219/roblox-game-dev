--!strict
--[[
	ReturnNotifyLogic — the PURE rules of the return notifications (owner R122 §2.3,
	docs/retention.md "Return notifications"). No services, no yields: every rule here is covered
	by tests/return-notify.luau.

	What it decides:
		plan        which ONE notification a leaving player gets (cashFull > streak > missions),
		            when it is due, and its parameters
		queue       the stored value shapes of the MemoryStore SortedMap (key = userId) and the
		            transforms every UpdateAsync runs: plan (leave), join (cancel + marker),
		            claim (exactly one server wins), finish (sent / done / retry)
		send        the fixed Open Cloud URL, the request body (validated), the HTTP verdict
		            (ok / throttled / rejected / http) and the server back-off
		limiter     a per-server token bucket (peek + take)
		control     the universe-wide kill switch + per-kind switches (sanitise / edit / attributes)

	Stored values (JSON tables, schema v = 1; anything else decodes to nil = "absent"):
		entry   { v, k = kind, d = due, dl = deadline?, p = params?, at = planned at, s = last send?,
		          c = claim token?, cu = claim until?, n = attempts? }        sort key = d (or cu)
		marker  { v, m = "sent" | "join" | "done", s = last send?, j = join time? }
		                                                                    sort key = "~" (string)
		Numeric sort keys sort before string ones, so `GetRangeAsync(.., upper = { sortKey = now })`
		returns due entries only, never a marker. A "sent" marker keeps Roblox's one-per-day rule
		(the next plan is due >= s + SendGapHours); a "join" marker makes a plan written late by a
		server the player already LEFT skip itself (the player is back).

	Transforms return (newValue?, newSortKey?, outcome). nil value = no change (UpdateAsync
	cancels). They may run several times (MemoryStore retries on conflict); they are pure, and
	the caller keeps the outcome of the LAST run.

	Connects to: Shared/Config/{NotifyConfig, RetentionConfig (dailyStatus / utcDay)}; used by
	Server/Retention/{ReturnNotifyQueue, ReturnNotifySender, ReturnNotifyRunner,
	ReturnNotifyControl, ReturnNotifyService, ReturnNotifyAdmin}.

	Example:
		local plan = ReturnNotifyLogic.plan(facts, ReturnNotifyLogic.defaultControl(), nil, os.time())
		if plan then print(plan.kind, plan.due) end
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NotifyConfig = require(ReplicatedStorage.Shared.Config.NotifyConfig)
local RetentionConfig = require(ReplicatedStorage.Shared.Config.RetentionConfig)

export type Kind = NotifyConfig.Kind
export type KindDef = NotifyConfig.KindDef
export type Kinds = { [Kind]: KindDef }

-- What the server knows about a leaving player (built from the live profile at ProfileReleasing).
export type Facts = {
	userId: number,
	leaveAt: number, -- unix seconds
	sessionSeconds: number,
	usualHour: number, -- 0..23 UTC (ReturnNotifyLogic.usualHour)
	automatedIncome: number, -- $/s from automated producers (offline earnings basis)
	offlineCapSeconds: number, -- TycoonLogic.offlineLimits cap
	daily: { streak: number, lastDay: number }, -- profile.daily
	optedIn: boolean, -- profile.notify.claimed (the client reported an opt-in)
}

export type Plan = {
	kind: Kind,
	due: number,
	deadline: number?, -- hard deadline: a claim at / after it is late (streak: the streak breaks)
	latest: number?, -- the latest acceptable due time (streak: deadline - the margin)
	params: { [string]: string },
}

export type Entry = {
	v: number,
	k: Kind,
	d: number,
	dl: number?,
	p: { [string]: string }?,
	at: number,
	s: number?,
	c: string?,
	cu: number?,
	n: number?,
}

export type MarkerKind = "sent" | "join" | "done"
export type Marker = { v: number, m: MarkerKind, s: number?, j: number? }

export type Stored = { entry: Entry?, marker: Marker? }

export type Control = { v: number, on: boolean, off: { [string]: boolean } }

export type PlanOutcome = {
	result: "planned" | "skipJoined" | "skipInFlight" | "none",
	plan: Plan?,
	replaced: Kind?, -- an older pending entry this plan replaced
}

export type JoinOutcome = { cancelled: Kind?, inFlight: boolean }

export type ClaimAction = "send" | "late" | "off" | "none"
export type ClaimOutcome = { action: ClaimAction, entry: Entry? }

export type FinishVerdict = "sent" | "done" | "retry"
export type FinishOutcome = { result: "sent" | "done" | "retry" | "exhausted" | "lost", retryAt: number? }

export type HttpResult = "ok" | "throttled" | "rejected" | "http"
export type Verdict = {
	result: HttpResult,
	entry: FinishVerdict,
	backoff: "none" | "short" | "key",
	status: number, -- HTTP status (0 = no response)
	code: string?, -- Open Cloud error code from the body (sanitised), for the admin status
	retryAfter: number?, -- seconds from a Retry-After header (clamped)
}

export type Bucket = { tokens: number, capacity: number, perSecond: number, at: number }

local ReturnNotifyLogic = {}

local SCHEMA = 1
local DAY = 86400
local HOUR = 3600
-- Sort key of every marker: strings sort after all numbers, so a due-range read never sees one.
ReturnNotifyLogic.MarkerSortKey = "~"

local Queue = NotifyConfig.Queue
local PlanCfg = NotifyConfig.Plan
local Send = NotifyConfig.Send

local MAX_PARAMS = 4
local MAX_PARAM_BYTES = 32
local MAX_TOKEN_BYTES = 64

-- A finite number (not NaN / inf).
local function finite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- A finite number >= 0, else nil.
local function nonNegative(value: unknown): number?
	if finite(value) and (value :: number) >= 0 then
		return value :: number
	end
	return nil
end

--------------------------------------------------------------------------------------------------
-- Time helpers
--------------------------------------------------------------------------------------------------

--[[
	Unix time of the start (00:00 UTC) of the UTC day containing `t`.
	Example: ReturnNotifyLogic.utcDayStart(86400 * 3 + 5) --> 259200
]]
function ReturnNotifyLogic.utcDayStart(t: number): number
	return t - t % DAY
end

--[[
	The player's usual UTC start hour: the stored hour blended with this session's start hour on
	the circle (23 and 1 average to 0, never 12). No valid stored hour → this session's hour.
	@param stored unknown — profile.notify.hour (integer 0..23, -1 / nil = unknown)
	@param sessionHour number — this session's UTC start hour (0..23)
	@return integer 0..23
	Example: ReturnNotifyLogic.usualHour(23, 1) --> 0
]]
function ReturnNotifyLogic.usualHour(stored: unknown, sessionHour: number): number
	local session = if finite(sessionHour) then math.floor(sessionHour) % 24 else 0
	if not finite(stored) or (stored :: number) % 1 ~= 0 or (stored :: number) < 0 or (stored :: number) > 23 then
		return session
	end
	local keep = PlanCfg.UsualHourKeep
	local a = (stored :: number) / 24 * 2 * math.pi
	local b = session / 24 * 2 * math.pi
	local x = keep * math.cos(a) + (1 - keep) * math.cos(b)
	local y = keep * math.sin(a) + (1 - keep) * math.sin(b)
	if math.abs(x) < 1e-9 and math.abs(y) < 1e-9 then
		return stored :: number
	end
	local angle = math.atan2(y, x)
	if angle < 0 then
		angle += 2 * math.pi
	end
	return math.floor(angle / (2 * math.pi) * 24 + 0.5) % 24
end

--------------------------------------------------------------------------------------------------
-- Control (kill switch + per-kind switches)
--------------------------------------------------------------------------------------------------

--[[ The control a server runs when nothing is stored: everything on, version 0. ]]
function ReturnNotifyLogic.defaultControl(): Control
	return { v = 0, on = true, off = {} }
end

--[[
	Sanitises a stored / received control value (unknown kinds dropped, finite version).
	@param raw unknown — decoded JSON
	@return Control? — nil when the shape is wrong
	Example: ReturnNotifyLogic.sanitizeControl({ v = 5, on = false, off = { "streak" } }).on --> false
]]
function ReturnNotifyLogic.sanitizeControl(raw: unknown): Control?
	if type(raw) ~= "table" then
		return nil
	end
	local data = raw :: { [any]: any }
	if not finite(data.v) or data.v < 0 or type(data.on) ~= "boolean" then
		return nil
	end
	local off: { [string]: boolean } = {}
	if type(data.off) == "table" then
		local count = 0
		for _, kind in data.off do
			count += 1
			if count > 8 then
				break
			end
			if NotifyConfig.isKind(kind) then
				off[kind] = true
			end
		end
	end
	return { v = math.floor(data.v), on = data.on, off = off }
end

--[[ JSON-safe form of a control (off = sorted kind list). ]]
function ReturnNotifyLogic.encodeControl(control: Control): { [string]: any }
	local off: { string } = {}
	for _, kind in NotifyConfig.KindOrder do
		if control.off[kind] then
			table.insert(off, kind)
		end
	end
	return { v = control.v, on = control.on, off = off }
end

--[[ A copy of `control` with the kill switch set (version bumped to `version`). ]]
function ReturnNotifyLogic.withOn(control: Control, on: boolean, version: number): Control
	return { v = version, on = on, off = table.clone(control.off) }
end

--[[ A copy of `control` with one kind switched on / off (version bumped to `version`). ]]
function ReturnNotifyLogic.withKind(control: Control, kind: Kind, on: boolean, version: number): Control
	local off = table.clone(control.off)
	off[kind] = if on then nil else true
	return { v = version, on = control.on, off = off }
end

--[[
	ReplicatedStorage attribute values for a control (NotifyConfig.Attributes; display only).
	Example: ReturnNotifyLogic.controlAttributes(c).ReturnNotifyKindsOff --> "streak"
]]
function ReturnNotifyLogic.controlAttributes(control: Control): { [string]: any }
	local off: { string } = {}
	for _, kind in NotifyConfig.KindOrder do
		if control.off[kind] then
			table.insert(off, kind)
		end
	end
	local attributes = NotifyConfig.Attributes
	return {
		[attributes.On] = control.on,
		[attributes.KindsOff] = table.concat(off, ","),
		[attributes.Version] = control.v,
	}
end

--[[
	True when `kind` may be planned / sent right now: the code switch, the universe kill switch,
	the kind's own switch, and a filled-in message id.
	@param kinds Kinds? — defaults to NotifyConfig.Kinds (tests pass ids filled in)
]]
function ReturnNotifyLogic.kindReady(control: Control, kind: Kind, kinds: Kinds?): boolean
	local def = (kinds or NotifyConfig.Kinds)[kind]
	return NotifyConfig.Enabled
		and def ~= nil
		and control.on
		and control.off[kind] ~= true
		and NotifyConfig.isMessageId(def.messageId)
end

--------------------------------------------------------------------------------------------------
-- Planning
--------------------------------------------------------------------------------------------------

--[[
	The plan of one kind for `facts`, or nil when it does not apply (before the send gap).
	cashFull: automated income > 0 and an offline cap >= MinCapHours: due = leave + cap.
	streak:   today's Daily claimed: due = tomorrow (UTC) at the usual hour, >= MinAfterLeaveHours
	          after leaving, at the latest when tomorrow ends minus the margin (deadline = the end
	          of tomorrow: the streak breaks after that).
	missions: due = max(leave + AfterLeaveHours, next UTC day + ResetSlackSeconds).
	Example: ReturnNotifyLogic.candidate("missions", facts) --> { kind = "missions", due = ... }
]]
function ReturnNotifyLogic.candidate(kind: Kind, facts: Facts): Plan?
	local leaveAt = facts.leaveAt
	if kind == "cashFull" then
		local income = nonNegative(facts.automatedIncome)
		local cap = nonNegative(facts.offlineCapSeconds)
		if income == nil or income <= 0 or cap == nil or cap < PlanCfg.MinCapHours * HOUR then
			return nil
		end
		return { kind = kind, due = leaveAt + math.floor(cap), params = {} }
	elseif kind == "streak" then
		local daily = facts.daily
		local today = RetentionConfig.utcDay(leaveAt)
		if type(daily) ~= "table" or daily.lastDay ~= today or not finite(daily.streak) or daily.streak <= 0 then
			return nil
		end
		local nextIndex = RetentionConfig.dailyStatus(daily, today + 1).nextIndex
		local tomorrow = (today + 1) * DAY
		-- Tomorrow's card must be claimed before the day after tomorrow starts (48 h rule).
		local streakEnd = (today + 2) * DAY
		local latest = streakEnd - PlanCfg.StreakDeadlineMarginMinutes * 60
		local hour = if finite(facts.usualHour) then math.floor(facts.usualHour) % 24 else 0
		local due = math.max(tomorrow + hour * HOUR, leaveAt + PlanCfg.MinAfterLeaveHours * HOUR)
		if due > latest then
			return nil
		end
		return {
			kind = kind,
			due = due,
			deadline = streakEnd,
			latest = latest,
			params = { day = tostring(nextIndex) },
		}
	elseif kind == "missions" then
		local nextReset = ReturnNotifyLogic.utcDayStart(leaveAt) + DAY
		local due = math.max(leaveAt + PlanCfg.AfterLeaveHours * HOUR, nextReset + PlanCfg.ResetSlackSeconds)
		return { kind = kind, due = due, params = {} }
	end
	return nil
end

--[[
	The ONE notification a leaving player gets: the first kind in NotifyConfig.KindOrder that is
	ready (ReturnNotifyLogic.kindReady) and applies, moved to at least `lastSentAt` +
	SendGapHours (Roblox: one per user per day), still before its deadline and holdable by the
	queue (MaxExpirationSeconds).
	Eligibility: OptedInOnly → only opted-in players; a session shorter than MinSessionSeconds →
	only opted-in players.
	@param facts Facts
	@param control Control
	@param lastSentAt number? — this user's last send (from the queue's "sent" marker)
	@param now number — unix seconds (normally facts.leaveAt)
	@param kinds Kinds? — defaults to NotifyConfig.Kinds
	@return Plan?
]]
function ReturnNotifyLogic.plan(facts: Facts, control: Control, lastSentAt: number?, now: number, kinds: Kinds?): Plan?
	if type(facts) ~= "table" or not finite(facts.leaveAt) or not finite(now) then
		return nil
	end
	if
		(NotifyConfig.OptedInOnly or (facts.sessionSeconds or 0) < NotifyConfig.MinSessionSeconds) and not facts.optedIn
	then
		return nil
	end
	local earliest = if lastSentAt ~= nil and finite(lastSentAt)
		then lastSentAt + Queue.SendGapHours * HOUR
		else -math.huge
	local horizon = now + Queue.MaxExpirationSeconds - Queue.LeaseSeconds
	for _, kind in NotifyConfig.KindOrder do
		if not ReturnNotifyLogic.kindReady(control, kind, kinds) then
			continue
		end
		local plan = ReturnNotifyLogic.candidate(kind, facts)
		if plan == nil then
			continue
		end
		plan.due = math.max(plan.due, earliest)
		local latest = plan.latest or plan.deadline
		if latest ~= nil and plan.due > latest then
			continue
		end
		if plan.due > horizon then
			continue
		end
		return plan
	end
	return nil
end

--------------------------------------------------------------------------------------------------
-- Stored values
--------------------------------------------------------------------------------------------------

-- Validated params table (<= MAX_PARAMS short "[%w ]" strings), or nil.
local function decodeParams(raw: unknown): { [string]: string }?
	if raw == nil then
		return nil
	end
	if type(raw) ~= "table" then
		return nil
	end
	local params: { [string]: string } = {}
	local count = 0
	for key, value in raw :: { [any]: any } do
		count += 1
		if count > MAX_PARAMS then
			return nil
		end
		if type(key) ~= "string" or string.find(key, "^[%a][%w]*$") == nil or #key > MAX_PARAM_BYTES then
			return nil
		end
		if type(value) ~= "string" or #value > MAX_PARAM_BYTES or string.find(value, "^[%w ]*$") == nil then
			return nil
		end
		params[key] = value
	end
	return params
end

-- An optional finite number field (nil allowed), or false when present but invalid.
local function optionalNumber(value: unknown): (boolean, number?)
	if value == nil then
		return true, nil
	end
	if finite(value) then
		return true, value :: number
	end
	return false, nil
end

--[[
	Decodes a stored queue value (strict: wrong shapes decode to {} = absent, so a corrupt value
	is simply overwritten).
	@return Stored — { entry = Entry? } or { marker = Marker? } (both nil = absent)
]]
function ReturnNotifyLogic.decode(raw: unknown): Stored
	if type(raw) ~= "table" then
		return {}
	end
	local data = raw :: { [any]: any }
	if data.v ~= SCHEMA then
		return {}
	end
	local okS, s = optionalNumber(data.s)
	if not okS then
		return {}
	end
	if data.m ~= nil then
		local m = data.m
		if m ~= "sent" and m ~= "join" and m ~= "done" then
			return {}
		end
		local okJ, j = optionalNumber(data.j)
		if not okJ then
			return {}
		end
		return { marker = { v = SCHEMA, m = m :: MarkerKind, s = s, j = j } }
	end
	if not NotifyConfig.isKind(data.k) or not finite(data.d) or not finite(data.at) then
		return {}
	end
	local okDl, dl = optionalNumber(data.dl)
	local okCu, cu = optionalNumber(data.cu)
	local okN, n = optionalNumber(data.n)
	if not (okDl and okCu and okN) then
		return {}
	end
	if data.c ~= nil and (type(data.c) ~= "string" or #data.c > MAX_TOKEN_BYTES) then
		return {}
	end
	local params = decodeParams(data.p)
	if data.p ~= nil and params == nil then
		return {}
	end
	return {
		entry = {
			v = SCHEMA,
			k = data.k :: Kind,
			d = data.d,
			dl = dl,
			p = params,
			at = data.at,
			s = s,
			c = data.c,
			cu = cu,
			n = n,
		},
	}
end

-- The last send time a stored value carries (entry or marker).
local function lastSent(stored: Stored): number?
	local entry = stored.entry
	if entry ~= nil then
		return entry.s
	end
	local marker = stored.marker
	return if marker ~= nil then marker.s else nil
end

-- True while an entry is claimed by a server whose lease has not run out.
local function inFlight(entry: Entry, now: number): boolean
	return entry.c ~= nil and entry.cu ~= nil and entry.cu > now
end

-- A marker value.
local function marker(kind: MarkerKind, s: number?, j: number?): Marker
	return { v = SCHEMA, m = kind, s = s, j = j }
end

--[[
	The MemoryStore expiration (seconds) for a value: an entry lives until its late window ends
	(+ the lease); a marker with a send time until the send gap ends; a join marker
	JoinMarkerSeconds; a done marker DoneTtlSeconds. Clamped to [60, MaxExpirationSeconds].
]]
function ReturnNotifyLogic.expiration(value: Entry | Marker, now: number, kinds: Kinds?): number
	local seconds: number
	local data = value :: any
	if data.m == nil then
		local def = (kinds or NotifyConfig.Kinds)[data.k :: Kind]
		local late = if def ~= nil then def.maxLateHours * HOUR else 0
		seconds = data.d + late + Queue.LeaseSeconds - now
		if data.cu ~= nil then
			seconds = math.max(seconds, data.cu - now + Queue.LeaseSeconds)
		end
	else
		local base = if data.m == "join" then Queue.JoinMarkerSeconds else Queue.DoneTtlSeconds
		seconds = base
		if data.s ~= nil then
			seconds = math.max(base, data.s + Queue.SendGapHours * HOUR - now)
		end
	end
	return math.clamp(math.ceil(seconds), 60, Queue.MaxExpirationSeconds)
end

--[[
	Plan transform (a player LEFT): writes the plan as a pending entry unless the player already
	joined again (a newer "join" marker) or a send for them is in flight. Carries the last send
	time (gap rule) and reports an older pending entry it replaces.
	@return (Entry?, sortKey?, PlanOutcome)
]]
function ReturnNotifyLogic.planTransform(
	old: unknown,
	facts: Facts,
	control: Control,
	now: number,
	kinds: Kinds?
): (Entry?, number?, PlanOutcome)
	local stored = ReturnNotifyLogic.decode(old)
	local entry = stored.entry
	if entry ~= nil and inFlight(entry, now) then
		return nil, nil, { result = "skipInFlight" }
	end
	local mark = stored.marker
	if mark ~= nil and mark.m == "join" and mark.j ~= nil and mark.j > facts.leaveAt then
		return nil, nil, { result = "skipJoined" }
	end
	local sentAt = lastSent(stored)
	local plan = ReturnNotifyLogic.plan(facts, control, sentAt, now, kinds)
	if plan == nil then
		return nil, nil, { result = "none" }
	end
	local value: Entry = {
		v = SCHEMA,
		k = plan.kind,
		d = plan.due,
		dl = plan.deadline,
		p = if next(plan.params) ~= nil then plan.params else nil,
		at = facts.leaveAt,
		s = sentAt,
	}
	return value, plan.due, { result = "planned", plan = plan, replaced = if entry ~= nil then entry.k else nil }
end

--[[
	Join transform (a player JOINED this server): a pending entry becomes a "join" marker
	(cancelled; the send time is kept); nothing / a marker becomes a fresh "join" marker so a
	late plan from the server they left skips itself. An in-flight send cannot be stopped.
	@return (Marker?, sortKey?, JoinOutcome)
]]
function ReturnNotifyLogic.joinTransform(old: unknown, joinAt: number, now: number): (Marker?, string?, JoinOutcome)
	local stored = ReturnNotifyLogic.decode(old)
	local entry = stored.entry
	if entry ~= nil and inFlight(entry, now) then
		return nil, nil, { inFlight = true }
	end
	return marker("join", lastSent(stored), joinAt),
		ReturnNotifyLogic.MarkerSortKey,
		{ cancelled = if entry ~= nil then entry.k else nil, inFlight = false }
end

--[[
	True when a claim at `now` is too late to be useful (now - due > the kind's maxLateHours, or
	past the entry's hard deadline).
]]
function ReturnNotifyLogic.isLate(entry: Entry, now: number, kinds: Kinds?): boolean
	local def = (kinds or NotifyConfig.Kinds)[entry.k]
	if def == nil then
		return true
	end
	if now - entry.d > def.maxLateHours * HOUR then
		return true
	end
	return entry.dl ~= nil and now >= entry.dl
end

--[[
	Claim transform (a poll found a due entry): exactly ONE server's token is written (MemoryStore
	re-runs this on the newest value when another server wrote first, and then it sees the other
	claim and gives up). A late entry / a kind switched off is finished on the spot (marker).
	@param token string — this server's unique claim token
	@return (Entry | Marker | nil, sortKey?, ClaimOutcome)
]]
function ReturnNotifyLogic.claimTransform(
	old: unknown,
	now: number,
	token: string,
	control: Control,
	kinds: Kinds?
): (any, (number | string)?, ClaimOutcome)
	local stored = ReturnNotifyLogic.decode(old)
	local entry = stored.entry
	if entry == nil or entry.d > now or inFlight(entry, now) then
		return nil, nil, { action = "none" }
	end
	if ReturnNotifyLogic.isLate(entry, now, kinds) then
		return marker("done", entry.s), ReturnNotifyLogic.MarkerSortKey, { action = "late", entry = entry }
	end
	if not ReturnNotifyLogic.kindReady(control, entry.k, kinds) then
		return marker("done", entry.s), ReturnNotifyLogic.MarkerSortKey, { action = "off", entry = entry }
	end
	local claimed = table.clone(entry)
	claimed.c = token
	claimed.cu = now + Queue.LeaseSeconds
	return claimed, claimed.cu, { action = "send", entry = claimed }
end

--[[
	Finish transform (the claimer is done): only the server holding the claim may finish it.
	sent → "sent" marker (s = now); done → "done" marker (keeps the older send time); retry → the
	entry comes back unclaimed after RetryBaseSeconds × 2^(n-1), or is finished ("exhausted")
	after MaxAttempts / when the retry would land past its late window.
	@return (Entry | Marker | nil, sortKey?, FinishOutcome)
]]
function ReturnNotifyLogic.finishTransform(
	old: unknown,
	token: string,
	verdict: FinishVerdict,
	now: number,
	kinds: Kinds?
): (any, (number | string)?, FinishOutcome)
	local stored = ReturnNotifyLogic.decode(old)
	local entry = stored.entry
	if entry == nil or entry.c ~= token then
		return nil, nil, { result = "lost" }
	end
	if verdict == "sent" then
		return marker("sent", now), ReturnNotifyLogic.MarkerSortKey, { result = "sent" }
	end
	if verdict == "done" then
		return marker("done", entry.s), ReturnNotifyLogic.MarkerSortKey, { result = "done" }
	end
	local attempts = (entry.n or 0) + 1
	local retryAt = now + Queue.RetryBaseSeconds * 2 ^ (attempts - 1)
	-- A retry moves `d` to the retry time, so the late window is pinned to the ORIGINAL due by
	-- turning it into the hard deadline `dl` (a retried entry already carries it).
	local def = (kinds or NotifyConfig.Kinds)[entry.k]
	local limit = entry.d + (if def ~= nil then def.maxLateHours * HOUR else 0)
	if entry.dl ~= nil then
		limit = math.min(limit, entry.dl)
	end
	if attempts >= Queue.MaxAttempts or retryAt >= limit then
		return marker("done", entry.s), ReturnNotifyLogic.MarkerSortKey, { result = "exhausted" }
	end
	local retry = table.clone(entry)
	retry.c = nil
	retry.cu = nil
	retry.n = attempts
	retry.d = math.max(entry.d, retryAt)
	retry.dl = limit
	return retry, retry.d, { result = "retry", retryAt = retry.d }
end

--[[
	The queue key of a user (the decimal user id), or nil for an invalid id.
	Example: ReturnNotifyLogic.keyOf(1586034782) --> "1586034782"
]]
function ReturnNotifyLogic.keyOf(userId: unknown): string?
	if not finite(userId) or (userId :: number) <= 0 or (userId :: number) % 1 ~= 0 or (userId :: number) >= 2 ^ 53 then
		return nil
	end
	return string.format("%d", userId :: number)
end

--[[ The user id of a queue key, or nil (keys are untrusted MemoryStore data). ]]
function ReturnNotifyLogic.userIdOf(key: unknown): number?
	if type(key) ~= "string" or #key > 20 or string.find(key, "^[1-9]%d*$") == nil then
		return nil
	end
	local id = tonumber(key)
	if id == nil or id >= 2 ^ 53 then
		return nil
	end
	return id
end

--[[ A claim token unique to this server and claim ("<job8>:<n>"). ]]
function ReturnNotifyLogic.claimToken(jobId: string, counter: number): string
	local job = if jobId ~= "" then string.sub(jobId, 1, 36) else "studio"
	return `{job}:{counter}`
end

--------------------------------------------------------------------------------------------------
-- Open Cloud request
--------------------------------------------------------------------------------------------------

--[[
	The ONLY request URL (NotifyConfig.Url with a validated integer user id), or nil.
	Example: ReturnNotifyLogic.url(42) --> "https://apis.roblox.com/cloud/v2/users/42/notifications"
]]
function ReturnNotifyLogic.url(userId: unknown): string?
	local key = ReturnNotifyLogic.keyOf(userId)
	if key == nil then
		return nil
	end
	return string.format(NotifyConfig.Url, tonumber(key) :: number)
end

--[[
	Builds the CreateUserNotification body (Open Cloud v2, camelCase JSON):
		{ source = { universe = "universes/<id>" },
		  payload = { messageId, type = "MOMENT", parameters = { <name> = { stringValue } },
		              joinExperience = { launchData = "rn:<kind>" },
		              analyticsData = { category } } }
	Validates: known kind, asset-id message id, positive universe id, launch data <= 200 bytes,
	exactly the kind's declared params (short "[%w ]" strings). The API key is never in the body
	(Roblox secrets may only go in headers / the URL).
	@param kind unknown
	@param params { [string]: string }?
	@param kinds Kinds? — defaults to NotifyConfig.Kinds
	@return (body?, error?)
]]
function ReturnNotifyLogic.buildBody(
	kind: unknown,
	params: { [string]: string }?,
	kinds: Kinds?
): ({ [string]: any }?, string?)
	if not NotifyConfig.isKind(kind) then
		return nil, "unknown kind"
	end
	local def = (kinds or NotifyConfig.Kinds)[kind :: Kind]
	if def == nil or not NotifyConfig.isMessageId(def.messageId) then
		return nil, "no message id"
	end
	local universe = NotifyConfig.UniverseId
	if not finite(universe) or universe <= 0 or universe % 1 ~= 0 then
		return nil, "bad universe id"
	end
	local launch = NotifyConfig.launchData(kind :: Kind)
	if #launch > NotifyConfig.MaxLaunchDataBytes then
		return nil, "launch data too long"
	end
	local given = params or {}
	local parameters: { [string]: any } = {}
	local declared: { [string]: boolean } = {}
	for _, name in def.params do
		declared[name] = true
		local value = given[name]
		if
			type(value) ~= "string"
			or #value == 0
			or #value > MAX_PARAM_BYTES
			or string.find(value, "^[%w ]+$") == nil
		then
			return nil, `bad parameter {name}`
		end
		parameters[name] = { stringValue = value }
	end
	for name in given do
		if not declared[name] then
			return nil, `unexpected parameter {name}`
		end
	end
	local payload: { [string]: any } = {
		messageId = def.messageId,
		type = "MOMENT",
		joinExperience = { launchData = launch },
		analyticsData = { category = def.category },
	}
	if next(parameters) ~= nil then
		payload.parameters = parameters
	end
	return {
		source = { universe = string.format("universes/%d", universe) },
		payload = payload,
	}, nil
end

-- A short sanitised Open Cloud error code ("RESOURCE_EXHAUSTED"), or nil.
local function errorCode(decoded: unknown): string?
	if type(decoded) ~= "table" then
		return nil
	end
	local data = decoded :: { [any]: any }
	local code = data.code
	if type(code) ~= "string" then
		local inner = data.error
		code = if type(inner) == "table" then (inner :: any).code or (inner :: any).status else nil
	end
	if type(code) ~= "string" then
		return nil
	end
	local clean = string.gsub(string.sub(code, 1, 40), "[^%w_]", "")
	return if clean ~= "" then clean else nil
end

--[[
	Seconds from a Retry-After header (integer seconds only), clamped to [1, BackoffMaxSeconds].
	@param headers unknown — RequestAsync response.Headers
]]
function ReturnNotifyLogic.retryAfter(headers: unknown): number?
	if type(headers) ~= "table" then
		return nil
	end
	for name, value in headers :: { [any]: any } do
		if type(name) == "string" and string.lower(name) == "retry-after" and type(value) == "string" then
			local seconds = tonumber(string.match(value, "^%s*(%d+)%s*$") or "")
			if seconds ~= nil then
				return math.clamp(seconds, 1, Send.BackoffMaxSeconds)
			end
		end
	end
	return nil
end

--[[
	R136: the bounded analytics bucket of a failed send's HTTP status ("rnotify:status:<kind>:<b>").
	Roblox answers 400 when the player has notifications off or cannot receive them (under 13),
	429 for the one-per-day-per-experience cap or a rate limit, 401 / 403 for a key / scope
	problem, 404 for an unknown message id. Everything else folds into 4xx / 5xx / none.
	@param status number — Verdict.status (0 = no response)
	@return "400" | "401" | "403" | "404" | "429" | "4xx" | "5xx" | "none"
	Example: ReturnNotifyLogic.statusBucket(400) --> "400"; ReturnNotifyLogic.statusBucket(0) --> "none"
]]
local STATUS_BUCKETS: { [number]: string } =
	{ [400] = "400", [401] = "401", [403] = "403", [404] = "404", [429] = "429" }
function ReturnNotifyLogic.statusBucket(status: number): string
	local exact = STATUS_BUCKETS[status]
	if exact ~= nil then
		return exact
	elseif status >= 400 and status < 500 then
		return "4xx"
	elseif status >= 500 and status < 600 then
		return "5xx"
	end
	return "none"
end

--[[
	The verdict of one RequestAsync attempt.
		2xx           ok         entry sent,  no back-off
		429           throttled  entry retry, short back-off (Retry-After honoured)
		401 / 403     rejected   entry retry, key back-off (key / scope problem, not the entry's fault)
		other 4xx     rejected   entry done (this user / payload will not work)
		5xx           http       entry retry, short back-off
		no response   http       entry retry, short back-off (pcall error / timeout / HTTP off)
	@param called boolean — the RequestAsync pcall succeeded
	@param response unknown — its result ({ StatusCode, Body, Headers, ... })
	@param decodeJson ((string) -> unknown)? — HttpService:JSONDecode (pcall'd by the caller's fn)
	@return Verdict
]]
function ReturnNotifyLogic.classify(called: boolean, response: unknown, decodeJson: ((string) -> unknown)?): Verdict
	if not called or type(response) ~= "table" then
		return { result = "http", entry = "retry", backoff = "short", status = 0 }
	end
	local data = response :: { [any]: any }
	local status = if finite(data.StatusCode) then math.floor(data.StatusCode) else 0
	local code: string? = nil
	if decodeJson ~= nil and type(data.Body) == "string" and #data.Body > 0 and #data.Body <= Send.MaxBodyBytes then
		code = errorCode(decodeJson(data.Body))
	end
	if status >= 200 and status < 300 then
		return { result = "ok", entry = "sent", backoff = "none", status = status }
	elseif status == 429 then
		return {
			result = "throttled",
			entry = "retry",
			backoff = "short",
			status = status,
			code = code,
			retryAfter = ReturnNotifyLogic.retryAfter(data.Headers),
		}
	elseif status == 401 or status == 403 then
		return { result = "rejected", entry = "retry", backoff = "key", status = status, code = code }
	elseif status >= 400 and status < 500 then
		return { result = "rejected", entry = "done", backoff = "none", status = status, code = code }
	end
	return {
		result = "http",
		entry = "retry",
		backoff = "short",
		status = status,
		code = code,
		retryAfter = ReturnNotifyLogic.retryAfter(data.Headers),
	}
end

--[[
	Server back-off after `failures` consecutive short failures: Base × 2^(failures-1), capped at
	Max; a larger Retry-After (already clamped) wins.
	Example: ReturnNotifyLogic.backoffSeconds(3, nil) --> 8
]]
function ReturnNotifyLogic.backoffSeconds(failures: number, retryAfter: number?): number
	local n = math.max(1, math.floor(if finite(failures) then failures else 1))
	local seconds = math.min(Send.BackoffMaxSeconds, Send.BackoffBaseSeconds * 2 ^ math.min(n - 1, 30))
	if retryAfter ~= nil and finite(retryAfter) then
		seconds = math.max(seconds, math.min(retryAfter, Send.BackoffMaxSeconds))
	end
	return seconds
end

--------------------------------------------------------------------------------------------------
-- Admin status text
--------------------------------------------------------------------------------------------------

export type StatusInfo = {
	mode: string, -- "live" | "dry" | "nokey" | "off" (code switch) | "noqueue"
	control: Control,
	queueSize: number?, -- nil = unknown (MemoryStore error)
	dueNow: number?,
	planned: { [string]: number },
	sent: { [string]: number },
	results: { [string]: number },
	drops: { [string]: number },
	recent: { { at: number, kind: string, result: string, detail: string? } },
	backoffLeft: number,
	queueError: string?,
}

-- The admin panel shows at most 300 bytes of a command result (AdminClient).
local STATUS_MAX_BYTES = 300

-- Sum of a counter map.
local function total(map: { [string]: number }): number
	local sum = 0
	for _, value in map do
		sum += value
	end
	return sum
end

--[[
	The NotifyStatus admin text (<= 300 characters, the panel's result cap):
		"LIVE · sending ON · cashFull ON · streak NO ID · missions OFF
		 Queue 12 (3 due) · this server: plans 4, sent 2
		 ok 2 thr 1 rej 0 http 0 dry 0 nokey 0 off 0 | late 0 rejoin 1 repl 0
		 Last: streak ok HTTP 200 @ 14:02 UTC"
	@param info StatusInfo
	@param kinds Kinds? — defaults to NotifyConfig.Kinds
	@return string
]]
function ReturnNotifyLogic.statusText(info: StatusInfo, kinds: Kinds?): string
	local defs = kinds or NotifyConfig.Kinds
	local modeText = ({
		live = "LIVE",
		dry = "DRY RUN (Studio)",
		nokey = "NO KEY (dry)",
		off = "OFF IN CODE",
		noqueue = "NO QUEUE",
	})[info.mode] or string.upper(info.mode)
	local parts = { `{modeText} · sending {if info.control.on then "ON" else "OFF"}` }
	for _, kind in NotifyConfig.KindOrder do
		local def = defs[kind]
		local state = if def == nil or not NotifyConfig.isMessageId(def.messageId)
			then "NO ID"
			elseif info.control.off[kind] then "OFF"
			else "ON"
		table.insert(parts, `{kind} {state}`)
	end
	local line1 = table.concat(parts, " · ")
	local queueText = if info.queueSize ~= nil
		then `Queue {info.queueSize} ({info.dueNow or 0} due)`
		else `Queue ? ({info.queueError or "error"})`
	local line2 = `{queueText} · this server: plans {total(info.planned)}, sent {total(info.sent)}`
	local r = info.results
	local d = info.drops
	local line3 =
		`ok {r.ok or 0} thr {r.throttled or 0} rej {r.rejected or 0} http {r.http or 0} dry {r.dry or 0} nokey {r.nokey or 0} off {r.off or 0} | late {d.late or 0} rejoin {d.rejoined or 0} repl {d.replaced or 0}`
	local lines = { line1, line2, line3 }
	local last = info.recent[1]
	if last ~= nil then
		local clock = last.at % DAY
		local stamp = string.format("%02d:%02d", clock // HOUR, (clock % HOUR) // 60)
		table.insert(lines, `Last: {last.kind} {last.result} {last.detail or ""} @ {stamp} UTC`)
	end
	if info.backoffLeft > 0 then
		table.insert(lines, `Backing off {math.ceil(info.backoffLeft)} s`)
	end
	local text = table.concat(lines, "\n")
	if #text > STATUS_MAX_BYTES then
		-- Cut on a UTF-8 boundary ("·" is two bytes; the panel caps results at 300 bytes).
		local cut = STATUS_MAX_BYTES - 3
		while cut > 0 and utf8.len(string.sub(text, 1, cut)) == nil do
			cut -= 1
		end
		text = string.sub(text, 1, cut) .. "..."
	end
	return text
end

--------------------------------------------------------------------------------------------------
-- Token bucket (per-server send limiter)
--------------------------------------------------------------------------------------------------

--[[ A full bucket at `now`. ]]
function ReturnNotifyLogic.newBucket(capacity: number, perSecond: number, now: number): Bucket
	return { tokens = capacity, capacity = capacity, perSecond = perSecond, at = now }
end

-- Refills the bucket up to `now` (a clock running backwards adds nothing).
local function refill(bucket: Bucket, now: number)
	if now > bucket.at then
		bucket.tokens = math.min(bucket.capacity, bucket.tokens + (now - bucket.at) * bucket.perSecond)
		bucket.at = now
	end
end

--[[ Whole tokens available at `now` (peek; nothing is taken). ]]
function ReturnNotifyLogic.tokens(bucket: Bucket, now: number): number
	refill(bucket, now)
	return math.floor(bucket.tokens)
end

--[[ Takes one token at `now`. @return true when a token was available ]]
function ReturnNotifyLogic.take(bucket: Bucket, now: number): boolean
	refill(bucket, now)
	if bucket.tokens >= 1 then
		bucket.tokens -= 1
		return true
	end
	return false
end

return table.freeze(ReturnNotifyLogic)
