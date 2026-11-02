--!strict
--[[
	Return notifications regressions (owner R122 §2.3; docs/retention.md "Return notifications").
	Run:
		lune run tests/return-notify
	Proves on the shipped modules (Shared/Config/NotifyConfig, Server/Retention/{ReturnNotifyLogic,
	ReturnNotifyQueue, ReturnNotifySender, ReturnNotifyRunner}, Server/Analytics/KeySpec,
	Shared/Config/AdminConfig):
	  1. Config: validate() clean, launch data exact + <= 200 bytes, Studio placeholder ids.
	  2. Usual hour: circular blend (23 + 1 → 0), junk stored hours ignored.
	  3. Planning: every kind's due time (cashFull cap, streak tomorrow at the usual hour >= 16 h /
	     before the streak breaks, missions after the reset), priority cashFull > streak > missions,
	     kill switch / kind off / no message id, eligibility, the 24 h send gap, the queue horizon.
	  4. Stored values: strict decode (corrupt / foreign values = absent), expirations.
	  5. Transforms: plan (replaced / rejoined / in flight / gap carried), join (cancel + marker),
	     claim (due / not due / late / off / leased), finish (sent / done / retry back-off /
	     exhausted / lost claim).
	  6. Claim race: two servers sharing one fake SortedMap with UpdateAsync conflicts → exactly ONE
	     claim wins, every interleaving; a stale finish is refused.
	  7. Request: fixed URL, body shape + validation (camelCase, MOMENT, params, launch data,
	     category), no secret in the body.
	  8. HTTP verdicts (2xx / 429 / 401 / 403 / 4xx / 5xx / no response, Retry-After, error code)
	     and the server back-off curve.
	  9. Token bucket (peek / take / refill / clock backwards).
	 10. Control: sanitise / encode / switches / attributes.
	 11. Sender with fakes: Studio dry run (no request), live without secret (nokey + retry
	     spacing), live request options (exact URL / method / two headers / Secret only in a header).
	 12. Runner end to end on the fake map: plan → poll → claim → send → "sent" marker; late drop;
	     kill switch "off"; 429 back-off; per-server limiter; timeout race; join cancel; replaced;
	     dry / nokey consume; every analytics key allowlisted (KeySpec).
	 13. Admin: status text <= 300 bytes and valid UTF-8; Notify* commands declared with the
	     provider and the kind enum.
]]

local serde = require("@lune/serde")
local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new({
	HttpService = {
		JSONEncode = function(_self: any, value: any): string
			return serde.encode("json", value)
		end,
		JSONDecode = function(_self: any, text: string): any
			return serde.decode("json", text)
		end,
	},
})
local NotifyConfig = loader.load("src/shared/Config/NotifyConfig")
local RetentionConfig = loader.load("src/shared/Config/RetentionConfig")
local Logic = loader.load("src/server/Retention/ReturnNotifyLogic")
local QueueModule = loader.load("src/server/Retention/ReturnNotifyQueue")
local SenderModule = loader.load("src/server/Retention/ReturnNotifySender")
local RunnerModule = loader.load("src/server/Retention/ReturnNotifyRunner")
local KeySpec = loader.load("src/server/Analytics/KeySpec")
local AdminConfig = loader.load("src/shared/Config/AdminConfig")
local ProfileLogic = loader.load("src/server/Economy/ProfileLogic")

local checks = 0
local function ok(condition: boolean, label: string)
	checks += 1
	assert(condition, label)
end
local function eq(actual: any, expected: any, label: string)
	ok(actual == expected, `{label}: got {tostring(actual)}, expected {tostring(expected)}`)
end

local DAY = 86400
local HOUR = 3600
local Queue = NotifyConfig.Queue
local Send = NotifyConfig.Send

-- Explicit configured / disabled fixtures keep both paths covered as dashboard ids change.
local KINDS: { [string]: any } = {}
local EMPTY_KINDS: { [string]: any } = {}
for kind, def in NotifyConfig.Kinds do
	local copy = table.clone(def)
	copy.messageId = `5dd7024b-68e3-ac4d-8232-{kind}`
	KINDS[kind] = copy
	local empty = table.clone(def)
	empty.messageId = ""
	EMPTY_KINDS[kind] = empty
end
-- Message-id shape check uses letters/digits/dashes only: use a clean id per kind.
KINDS.cashFull.messageId = "11111111-2222-3333-4444-555555555555"
KINDS.streak.messageId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
KINDS.missions.messageId = "12345678-90ab-cdef-1234-567890abcdef"

local ON = Logic.defaultControl()

-- Day 20000 (2024-10-04) 00:00 UTC.
local D0 = 20000 * DAY

-- A leaving player's facts (override any field).
local function facts(overrides: { [string]: any }?): any
	local base: { [string]: any } = {
		userId = 1586034782,
		leaveAt = D0 + 10 * HOUR,
		sessionSeconds = 600,
		usualHour = 18,
		automatedIncome = 50,
		offlineCapSeconds = 3 * HOUR,
		daily = { streak = 3, lastDay = 20000 },
		optedIn = false,
	}
	for key, value in overrides or {} do
		base[key] = value
	end
	return base
end

------------------------------------------------------------------------------------------------
-- 1. Config
------------------------------------------------------------------------------------------------
do
	local problems = NotifyConfig.validate()
	ok(#problems == 0, "NotifyConfig.validate: " .. table.concat(problems, "; "))
	eq(NotifyConfig.UniverseId, 10773845696, "universe id")
	for _, kind in NotifyConfig.KindOrder do
		local launch = NotifyConfig.launchData(kind)
		eq(launch, "rn:" .. kind, `launch data {kind}`)
		ok(#launch <= 200, `launch data {kind} <= 200 bytes`)
		eq(NotifyConfig.kindFromLaunchData(launch), kind, `launch data {kind} round trip`)
		ok(utf8.len(NotifyConfig.Kinds[kind].text) <= 99, `{kind} text <= 99 characters`)
	end
	for _, junk in
		{
			"rn:",
			"rn:bogus",
			"RN:streak",
			" rn:streak",
			"rn:streak ",
			"notify_daily",
			42,
			nil,
			{},
			string.rep("x", 300),
		}
	do
		eq(NotifyConfig.kindFromLaunchData(junk), nil, `junk launch data {tostring(junk)}`)
	end
	ok(NotifyConfig.isMessageId("5dd7024b-68e3-ac4d-8232-4217f86ca244"), "uuid message id")
	ok(not NotifyConfig.isMessageId(""), "empty message id")
	ok(not NotifyConfig.isMessageId("bad id"), "message id with a space")
	ok(not NotifyConfig.isMessageId(string.rep("a", 65)), "message id too long")
	local studio = NotifyConfig.kindsFor(true)
	local live = NotifyConfig.kindsFor(false)
	ok(live == NotifyConfig.Kinds, "live kinds = config")
	for _, kind in NotifyConfig.KindOrder do
		local expected = if NotifyConfig.Kinds[kind].messageId == ""
			then NotifyConfig.StudioPlaceholderId
			else NotifyConfig.Kinds[kind].messageId
		eq(studio[kind].messageId, expected, `Studio placeholder {kind}`)
		ok(NotifyConfig.isMessageId(studio[kind].messageId), `Studio id valid {kind}`)
	end
	-- The shipped config must never carry the placeholder (it is Studio-only).
	for _, kind in NotifyConfig.KindOrder do
		ok(
			NotifyConfig.Kinds[kind].messageId ~= NotifyConfig.StudioPlaceholderId,
			`{kind} config id is not the placeholder`
		)
	end
end

------------------------------------------------------------------------------------------------
-- 2. Usual hour
------------------------------------------------------------------------------------------------
do
	eq(Logic.usualHour(nil, 14), 14, "no stored hour → session hour")
	eq(Logic.usualHour(-1, 7), 7, "unknown stored hour → session hour")
	eq(Logic.usualHour(10, 10), 10, "same hour")
	eq(Logic.usualHour(23, 1), 0, "23 and 1 blend across midnight (circle)")
	eq(Logic.usualHour(10, 14), 11, "10 kept 70 % + 14 → 11")
	eq(Logic.usualHour(0 / 0, 5), 5, "NaN stored")
	eq(Logic.usualHour(24, 5), 5, "out of range stored")
	eq(Logic.usualHour(3.5, 5), 5, "fractional stored")
	eq(Logic.usualHour(6, 18), 6, "opposite hours keep the stored one (0.7 weight)")
	for stored = 0, 23 do
		for session = 0, 23 do
			local hour = Logic.usualHour(stored, session)
			ok(hour >= 0 and hour <= 23 and hour % 1 == 0, `usualHour({stored},{session}) in range`)
		end
	end
end

-- profile.notify.hour (ProfileLogic): default unknown, valid hours kept, junk → unknown.
do
	eq(ProfileLogic.defaultProfile().notify.hour, -1, "default usual hour unknown")
	for _, case in { { 7, 7 }, { 0, 0 }, { 23, 23 }, { 24, 23 }, { -5, -1 }, { 0 / 0, -1 }, { "9", -1 }, { 3.7, 3 } } do
		local raw = ProfileLogic.toSave(ProfileLogic.defaultProfile())
		raw.notify.hour = case[1]
		local profile = ProfileLogic.migrate(raw)
		eq(profile.notify.hour, case[2], `reconciled hour {tostring(case[1])}`)
	end
	local raw = ProfileLogic.toSave(ProfileLogic.defaultProfile())
	raw.notify = { claimed = true }
	local older = ProfileLogic.migrate(raw)
	ok(older.notify.claimed == true and older.notify.hour == -1, "older save without hour")
	eq(Logic.usualHour(ProfileLogic.defaultProfile().notify.hour, 9), 9, "unknown stored hour → session hour")
end

------------------------------------------------------------------------------------------------
-- 3. Planning
------------------------------------------------------------------------------------------------
do
	local f = facts()
	local now = f.leaveAt
	-- cashFull
	local cash = Logic.candidate("cashFull", f)
	ok(cash ~= nil and cash.due == f.leaveAt + 3 * HOUR, "cashFull due = leave + cap")
	eq(Logic.candidate("cashFull", facts({ automatedIncome = 0 })), nil, "cashFull needs automated income")
	eq(Logic.candidate("cashFull", facts({ offlineCapSeconds = 59 * 60 })), nil, "cashFull needs a cap >= 1 h")
	ok(Logic.candidate("cashFull", facts({ offlineCapSeconds = HOUR })) ~= nil, "cashFull cap exactly 1 h")
	eq(Logic.candidate("cashFull", facts({ automatedIncome = 0 / 0 })), nil, "cashFull NaN income")
	eq(Logic.candidate("cashFull", facts({ offlineCapSeconds = math.huge })), nil, "cashFull inf cap")

	-- streak: claimed today (lastDay = 20000), leave 10:00, usual 18 → tomorrow 18:00 (32 h later)
	local streak = Logic.candidate("streak", f)
	ok(streak ~= nil, "streak applies when today's daily was claimed")
	eq(streak.due, D0 + DAY + 18 * HOUR, "streak due tomorrow at the usual hour")
	eq(streak.deadline, D0 + 2 * DAY, "streak deadline = end of tomorrow")
	eq(streak.params.day, "4", "streak day = next card (streak 3 → Day 4)")
	-- leave 20:00, usual 06 → tomorrow 06:00 is only 10 h later → leave + 16 h
	local late = Logic.candidate("streak", facts({ leaveAt = D0 + 20 * HOUR, usualHour = 6 }))
	eq(late.due, D0 + 20 * HOUR + 16 * HOUR, "streak at least 16 h after leaving")
	-- usual hour 23 → tomorrow 23:00 = exactly the latest (end - 60 min): allowed
	local edge = Logic.candidate("streak", facts({ usualHour = 23 }))
	ok(edge ~= nil and edge.due == D0 + DAY + 23 * HOUR, "streak at the latest edge")
	-- leave 23:30, usual 0 → leave + 16 h = tomorrow 15:30 (fine)
	ok(Logic.candidate("streak", facts({ leaveAt = D0 + 23.5 * HOUR, usualHour = 0 })) ~= nil, "late-night leave")
	-- not claimed today → no streak
	eq(Logic.candidate("streak", facts({ daily = { streak = 3, lastDay = 19999 } })), nil, "streak needs today's claim")
	eq(Logic.candidate("streak", facts({ daily = { streak = 0, lastDay = 20000 } })), nil, "streak 0")
	eq(Logic.candidate("streak", facts({ daily = { streak = 0, lastDay = -1 } })), nil, "never claimed")
	-- Day 7 cycles to Day 1
	eq(
		Logic.candidate("streak", facts({ daily = { streak = 7, lastDay = 20000 } })).params.day,
		"1",
		"after Day 7 → Day 1"
	)
	eq(
		Logic.candidate("streak", facts({ daily = { streak = 6, lastDay = 20000 } })).params.day,
		tostring(RetentionConfig.dailyStatus({ streak = 6, lastDay = 20000 }, 20001).nextIndex),
		"streak day matches dailyStatus"
	)

	-- missions: leave 10:00 → +20 h = tomorrow 06:00 (after the reset + slack)
	eq(Logic.candidate("missions", f).due, f.leaveAt + 20 * HOUR, "missions +20 h")
	-- leave 00:30 → +20 h = 20:30 the SAME day → pushed to the next reset + slack
	local early = Logic.candidate("missions", facts({ leaveAt = D0 + 1800 }))
	eq(early.due, D0 + DAY + NotifyConfig.Plan.ResetSlackSeconds, "missions never before the next mission reset")

	-- priority + switches
	local plan = Logic.plan(f, ON, nil, now, KINDS)
	eq(plan.kind, "cashFull", "priority: cashFull first")
	local noCash = Logic.plan(facts({ automatedIncome = 0 }), ON, nil, now, KINDS)
	eq(noCash.kind, "streak", "priority: streak second")
	local onlyMissions =
		Logic.plan(facts({ automatedIncome = 0, daily = { streak = 1, lastDay = 1 } }), ON, nil, now, KINDS)
	eq(onlyMissions.kind, "missions", "priority: missions fallback")
	eq(Logic.plan(f, ON, nil, now, EMPTY_KINDS), nil, "empty message ids plan nothing")
	eq(Logic.plan(f, Logic.withOn(ON, false, 5), nil, now, KINDS), nil, "kill switch → nothing")
	eq(
		Logic.plan(f, Logic.withKind(ON, "cashFull", false, 5), nil, now, KINDS).kind,
		"streak",
		"cashFull off → streak"
	)
	local noIds = table.clone(KINDS)
	noIds.cashFull = table.clone(KINDS.cashFull)
	noIds.cashFull.messageId = ""
	eq(Logic.plan(f, ON, nil, now, noIds).kind, "streak", "cashFull without id → streak")

	-- eligibility
	eq(Logic.plan(facts({ sessionSeconds = 30 }), ON, nil, now, KINDS), nil, "a sub-minute bounce plans nothing")
	eq(
		Logic.plan(facts({ sessionSeconds = 30, optedIn = true }), ON, nil, now, KINDS).kind,
		"cashFull",
		"opted-in bounce still plans"
	)

	-- 24 h send gap: last send 1 h ago → cashFull pushed to last + 24 h
	local gap = Logic.plan(f, ON, now - HOUR, now, KINDS)
	eq(gap.kind, "cashFull", "gap keeps the kind")
	eq(gap.due, now - HOUR + 24 * HOUR, "gap: due >= last send + 24 h")
	-- streak pushed past its latest → skipped to missions
	local gapStreak = Logic.plan(
		facts({ automatedIncome = 0, leaveAt = D0 + 22 * HOUR, usualHour = 18 }),
		ON,
		D0 + 23 * HOUR,
		D0 + 22 * HOUR,
		KINDS
	)
	ok(gapStreak ~= nil, "gap streak fallback exists")
	-- last send at D0+23h → earliest D0+47h = tomorrow 23:00 = latest → streak still allowed
	eq(gapStreak.kind, "streak", "gap lands exactly on the streak's latest")
	local gapStreak2 = Logic.plan(
		facts({ automatedIncome = 0, leaveAt = D0 + 22 * HOUR }),
		ON,
		D0 + 23.5 * HOUR,
		D0 + 22 * HOUR,
		KINDS
	)
	eq(gapStreak2.kind, "missions", "gap past the streak's latest → missions")
	-- horizon: a due beyond what the queue can hold is skipped
	eq(
		Logic.plan(facts({ offlineCapSeconds = 3 * DAY }), ON, nil, now, KINDS).kind,
		"streak",
		"cap beyond the queue horizon → next kind"
	)
	eq(Logic.plan({ leaveAt = 0 / 0 } :: any, ON, nil, now, KINDS), nil, "NaN leave time")
end

------------------------------------------------------------------------------------------------
-- 4. Stored values
------------------------------------------------------------------------------------------------
do
	local entry =
		{ v = 1, k = "streak", d = 100, dl = 200, p = { day = "3" }, at = 50, s = 10, c = "job:1", cu = 160, n = 1 }
	local stored = Logic.decode(entry)
	ok(stored.entry ~= nil and stored.entry.k == "streak" and stored.entry.p.day == "3", "entry decodes")
	local marker = Logic.decode({ v = 1, m = "sent", s = 99 })
	ok(marker.marker ~= nil and marker.marker.s == 99, "marker decodes")
	local junk: { any } = {
		nil,
		"text",
		5,
		{},
		{ v = 2, k = "streak", d = 1, at = 1 },
		{ v = 1, k = "bogus", d = 1, at = 1 },
		{ v = 1, k = "streak", d = 0 / 0, at = 1 },
		{ v = 1, k = "streak", d = 1, at = math.huge },
		{ v = 1, k = "streak", d = 1, at = 1, c = string.rep("x", 65) },
		{ v = 1, k = "streak", d = 1, at = 1, c = 5 },
		{ v = 1, k = "streak", d = 1, at = 1, p = { day = "<b>" } },
		{ v = 1, k = "streak", d = 1, at = 1, p = { a = "1", b = "2", c = "3", d = "4", e = "5" } },
		{ v = 1, k = "streak", d = 1, at = 1, p = "day" },
		{ v = 1, k = "streak", d = 1, at = 1, n = "2" },
		{ v = 1, m = "other" },
		{ v = 1, m = "sent", s = "yesterday" },
		{ v = 1, m = "join", j = 0 / 0 },
	}
	for index, value in junk do
		local decoded = Logic.decode(value)
		ok(decoded.entry == nil and decoded.marker == nil, `junk value {index} decodes to absent`)
	end
	-- expirations
	local now = 1000
	local exp = Logic.expiration({ v = 1, k = "streak", d = now + HOUR, at = now }, now, KINDS)
	eq(exp, HOUR + KINDS.streak.maxLateHours * HOUR + Queue.LeaseSeconds, "entry lives through its late window")
	eq(Logic.expiration({ v = 1, m = "done" }, now), 60, "done marker floor 60 s")
	eq(Logic.expiration({ v = 1, m = "join", j = now }, now), Queue.JoinMarkerSeconds, "join marker")
	eq(Logic.expiration({ v = 1, m = "sent", s = now }, now), Queue.SendGapHours * HOUR, "sent marker keeps the gap")
	eq(
		Logic.expiration({ v = 1, k = "missions", d = now + 10 * DAY, at = now }, now, KINDS),
		Queue.MaxExpirationSeconds,
		"clamped to 2 days"
	)
	ok(Queue.MaxExpirationSeconds <= 2 * DAY, "expiration <= 2 days")
end

------------------------------------------------------------------------------------------------
-- 5. Transforms
------------------------------------------------------------------------------------------------
do
	local f = facts()
	local now = f.leaveAt
	-- plan onto nothing
	local value, sortKey, outcome = Logic.planTransform(nil, f, ON, now, KINDS)
	eq(outcome.result, "planned", "plan onto nothing")
	eq(value.k, "cashFull", "planned kind")
	eq(sortKey, value.d, "sort key = due")
	eq(outcome.replaced, nil, "nothing replaced")
	-- plan onto a pending entry → replaced
	local pending = { v = 1, k = "missions", d = now + HOUR, at = now - DAY }
	local _, _, replaced = Logic.planTransform(pending, f, ON, now, KINDS)
	eq(replaced.replaced, "missions", "older pending entry reported as replaced")
	-- in flight → no change
	local inflight = { v = 1, k = "missions", d = now - 10, at = now - DAY, c = "other:1", cu = now + 60 }
	local v2, _, o2 = Logic.planTransform(inflight, f, ON, now, KINDS)
	ok(v2 == nil and o2.result == "skipInFlight", "never overwrite an in-flight send")
	-- an expired lease is not in flight
	local stale = { v = 1, k = "missions", d = now - 10, at = now - DAY, c = "other:1", cu = now - 1 }
	local _, _, o3 = Logic.planTransform(stale, f, ON, now, KINDS)
	eq(o3.result, "planned", "an expired lease can be replaced")
	-- the player already joined somewhere else AFTER this leave → skip
	local _, _, o4 = Logic.planTransform({ v = 1, m = "join", j = now + 5 }, f, ON, now, KINDS)
	eq(o4.result, "skipJoined", "late plan after a newer join is skipped")
	-- an older join (same session) does not block
	local _, _, o5 = Logic.planTransform({ v = 1, m = "join", j = now - 600 }, f, ON, now, KINDS)
	eq(o5.result, "planned", "older join marker does not block")
	-- a sent marker carries its send time (gap)
	local v6, _, o6 = Logic.planTransform({ v = 1, m = "sent", s = now - HOUR }, f, ON, now, KINDS)
	eq(o6.result, "planned", "plan over a sent marker")
	eq(v6.s, now - HOUR, "send time carried")
	eq(v6.d, now - HOUR + 24 * HOUR, "gap applied inside the transform")
	-- nothing applies → no write
	local v7, _, o7 = Logic.planTransform(nil, f, Logic.withOn(ON, false, 1), now, KINDS)
	ok(v7 == nil and o7.result == "none", "no plan → no change")

	-- join
	local m1, k1, j1 = Logic.joinTransform({ v = 1, k = "streak", d = now + HOUR, at = now, s = 77 }, now, now)
	ok(m1 ~= nil and m1.m == "join" and m1.j == now and m1.s == 77, "join cancels a pending entry, keeps the send time")
	eq(k1, Logic.MarkerSortKey, "marker sort key is a string")
	eq(j1.cancelled, "streak", "cancelled kind")
	local m2, _, j2 = Logic.joinTransform(nil, now, now)
	ok(m2 ~= nil and m2.m == "join" and j2.cancelled == nil, "join onto nothing leaves a marker")
	local m3, _, j3 = Logic.joinTransform(inflight, now, now)
	ok(m3 == nil and j3.inFlight, "an in-flight send cannot be cancelled")
	local m4 = Logic.joinTransform({ v = 1, m = "sent", s = now - 5 }, now, now)
	eq(m4.s, now - 5, "join over a sent marker keeps the send time")

	-- claim
	local due = { v = 1, k = "missions", d = now - 60, at = now - DAY }
	local c1, ck1, co1 = Logic.claimTransform(due, now, "me:1", ON, KINDS)
	ok(
		co1.action == "send" and c1.c == "me:1" and c1.cu == now + Queue.LeaseSeconds and ck1 == c1.cu,
		"claim a due entry"
	)
	local _, _, co2 = Logic.claimTransform({ v = 1, k = "missions", d = now + 60, at = now }, now, "me:1", ON, KINDS)
	eq(co2.action, "none", "not due yet")
	local _, _, co3 = Logic.claimTransform(c1, now + 1, "you:1", ON, KINDS)
	eq(co3.action, "none", "already claimed by another server")
	local _, _, co4 = Logic.claimTransform(c1, now + Queue.LeaseSeconds + 1, "you:1", ON, KINDS)
	eq(co4.action, "send", "a dead claimer's lease runs out")
	local lateEntry = { v = 1, k = "streak", d = now - (KINDS.streak.maxLateHours * HOUR + 1), at = now - DAY }
	local lm, lk, lo = Logic.claimTransform(lateEntry, now, "me:1", ON, KINDS)
	ok(lo.action == "late" and lm.m == "done" and lk == Logic.MarkerSortKey, "late entry finished in the claim")
	local pastDeadline = { v = 1, k = "streak", d = now - 60, dl = now, at = now - DAY }
	eq(select(3, Logic.claimTransform(pastDeadline, now, "me:1", ON, KINDS)).action, "late", "past the streak deadline")
	local cashLate = { v = 1, k = "cashFull", d = now - 5 * HOUR, at = now - DAY }
	eq(
		select(3, Logic.claimTransform(cashLate, now, "me:1", ON, KINDS)).action,
		"send",
		"5 h late factory-full still sends"
	)
	local _, _, offO = Logic.claimTransform(due, now, "me:1", Logic.withOn(ON, false, 2), KINDS)
	eq(offO.action, "off", "kill switch finishes due entries as off")
	local _, _, offK = Logic.claimTransform(due, now, "me:1", Logic.withKind(ON, "missions", false, 2), KINDS)
	eq(offK.action, "off", "kind off finishes as off")
	eq(
		select(3, Logic.claimTransform({ v = 1, m = "sent", s = 1 }, now, "me:1", ON, KINDS)).action,
		"none",
		"a marker is never claimed"
	)

	-- finish
	local f1, fk1, fo1 = Logic.finishTransform(c1, "me:1", "sent", now + 5, KINDS)
	ok(fo1.result == "sent" and f1.m == "sent" and f1.s == now + 5 and fk1 == Logic.MarkerSortKey, "finish sent")
	local _, _, fo2 = Logic.finishTransform(c1, "you:9", "sent", now + 5, KINDS)
	eq(fo2.result, "lost", "only the claimer may finish")
	local _, _, fo3 = Logic.finishTransform(nil, "me:1", "sent", now + 5, KINDS)
	eq(fo3.result, "lost", "finish onto a cancelled entry")
	local withSend = table.clone(c1)
	withSend.s = 42
	local f4 = Logic.finishTransform(withSend, "me:1", "done", now, KINDS)
	ok(f4.m == "done" and f4.s == 42, "done keeps the older send time")
	-- retry curve: 300 s, then 600 s, then exhausted (MaxAttempts = 3)
	local claimedCash = { v = 1, k = "cashFull", d = now, at = now - HOUR, c = "me:1", cu = now + 120 }
	local r1, rk1, ro1 = Logic.finishTransform(claimedCash, "me:1", "retry", now, KINDS)
	ok(ro1.result == "retry" and r1.n == 1 and r1.c == nil and r1.cu == nil, "first retry")
	eq(r1.d, now + Queue.RetryBaseSeconds, "first retry after the base delay")
	eq(rk1, r1.d, "retry sort key")
	eq(r1.dl, now + KINDS.cashFull.maxLateHours * HOUR, "late window pinned to the original due")
	local again = table.clone(r1)
	again.c = "me:2"
	local r2, _, ro2 = Logic.finishTransform(again, "me:2", "retry", r1.d, KINDS)
	ok(ro2.result == "retry" and r2.n == 2 and r2.d == r1.d + Queue.RetryBaseSeconds * 2, "second retry doubles")
	eq(r2.dl, r1.dl, "deadline stays pinned")
	local third = table.clone(r2)
	third.c = "me:3"
	local r3, _, ro3 = Logic.finishTransform(third, "me:3", "retry", r2.d, KINDS)
	ok(ro3.result == "exhausted" and r3.m == "done", "exhausted after MaxAttempts")
	-- a retry that would land past the late window is exhausted at once
	local nearLate = { v = 1, k = "streak", d = now, dl = now + 100, at = now - HOUR, c = "me:1", cu = now + 120 }
	eq(
		select(3, Logic.finishTransform(nearLate, "me:1", "retry", now, KINDS)).result,
		"exhausted",
		"retry past the deadline"
	)
end

------------------------------------------------------------------------------------------------
-- Fake MemoryStore SortedMap (JSON round trip + optimistic UpdateAsync with conflict replay)
------------------------------------------------------------------------------------------------
local function jsonCopy(value: any): any
	if value == nil then
		return nil
	end
	return serde.decode("json", serde.encode("json", value))
end

local function newFakeMap(): any
	local map: any = { items = {}, versions = {}, interleave = nil, failNext = nil, counts = {} }
	local function count(name: string)
		map.counts[name] = (map.counts[name] or 0) + 1
	end
	function map.GetAsync(self: any, key: string): (any, any)
		count("get")
		if self.failNext == "get" then
			self.failNext = nil
			error("fake MemoryStore outage")
		end
		local item = self.items[key]
		if item == nil then
			return nil, nil
		end
		return jsonCopy(item.value), item.sortKey
	end
	function map.SetAsync(self: any, key: string, value: any, expiration: number, sortKey: any): boolean
		count("set")
		assert(expiration >= 1 and expiration <= 3888000, "expiration within Roblox limits")
		local existed = self.items[key] ~= nil
		self.items[key] = { value = jsonCopy(value), sortKey = sortKey, expiration = expiration }
		self.versions[key] = (self.versions[key] or 0) + 1
		return existed
	end
	function map.UpdateAsync(self: any, key: string, transform: any, expiration: number): (any, any)
		count("update")
		if self.failNext == "update" then
			self.failNext = nil
			error("fake MemoryStore outage")
		end
		assert(expiration >= 1 and expiration <= 3888000, "expiration within Roblox limits")
		for _ = 1, 10 do
			local item = self.items[key]
			local version = self.versions[key] or 0
			local newValue, newSortKey =
				transform(if item ~= nil then jsonCopy(item.value) else nil, if item ~= nil then item.sortKey else nil)
			if newValue == nil then
				return nil
			end
			local hook = self.interleave
			if hook ~= nil then
				self.interleave = nil
				hook()
			end
			if (self.versions[key] or 0) == version then
				self.items[key] = { value = jsonCopy(newValue), sortKey = newSortKey, expiration = expiration }
				self.versions[key] = version + 1
				return newValue, newSortKey
			end
			count("conflict")
		end
		error("too many conflicts")
	end
	function map.GetRangeAsync(self: any, _direction: any, countMax: number, lower: any, upper: any): { any }
		count("range")
		assert(countMax >= 1 and countMax <= 200, "GetRangeAsync count 1..200")
		assert(lower == nil, "lower bound unused")
		local list = {}
		for key, item in self.items do
			if type(item.sortKey) == "number" and (upper == nil or item.sortKey < upper.sortKey) then
				table.insert(list, { key = key, value = jsonCopy(item.value), sortKey = item.sortKey })
			end
		end
		table.sort(list, function(a, b)
			if a.sortKey ~= b.sortKey then
				return a.sortKey < b.sortKey
			end
			return a.key < b.key
		end)
		local out = {}
		for index = 1, math.min(countMax, #list) do
			out[index] = list[index]
		end
		return out
	end
	function map.GetSizeAsync(self: any): number
		local n = 0
		for _ in self.items do
			n += 1
		end
		return n
	end
	return map
end

------------------------------------------------------------------------------------------------
-- 6. Claim race (two servers, one map)
------------------------------------------------------------------------------------------------
do
	local now = D0 + 30 * HOUR
	for trial = 1, 4 do
		local map = newFakeMap()
		local a = QueueModule.new(map, KINDS)
		local b = QueueModule.new(map, KINDS)
		ok(a.put(1586034782, { v = 1, k = "missions", d = now - 10, at = now - DAY }, now), "seed entry")
		local okA, itemsA = a.due(now, 20)
		local okB, itemsB = b.due(now, 20)
		ok(okA and okB and #itemsA == 1 and #itemsB == 1, "both servers see the due entry")
		local outcomes: { any } = {}
		if trial == 1 then
			-- B claims while A's UpdateAsync is between read and commit → A replays and gives up.
			map.interleave = function()
				local _, outB = b.claim(itemsB[1], now, "B:1", ON)
				outcomes.B = outB
			end
			local _, outA = a.claim(itemsA[1], now, "A:1", ON)
			outcomes.A = outA
		elseif trial == 2 then
			local _, outA = a.claim(itemsA[1], now, "A:1", ON)
			local _, outB = b.claim(itemsB[1], now, "B:1", ON)
			outcomes.A, outcomes.B = outA, outB
		elseif trial == 3 then
			local _, outB = b.claim(itemsB[1], now, "B:1", ON)
			local _, outA = a.claim(itemsA[1], now, "A:1", ON)
			outcomes.A, outcomes.B = outA, outB
		else
			-- A claims, its lease runs out (server died), B claims later; A's late finish is refused.
			local _, outA = a.claim(itemsA[1], now, "A:1", ON)
			local later = now + Queue.LeaseSeconds + 1
			local _, itemsLater = b.due(later, 20)
			ok(#itemsLater == 1, "an expired lease shows up again")
			local _, outB = b.claim(itemsLater[1], later, "B:1", ON)
			outcomes.A, outcomes.B = outA, outB
			local finished, fin = a.finish(1586034782, outA.entry, "A:1", "sent", later + 1)
			ok(finished and fin == nil or (fin ~= nil and fin.result == "lost"), "stale claimer's finish is refused")
		end
		local winners = 0
		for _, outcome in outcomes do
			if outcome ~= nil and outcome.action == "send" then
				winners += 1
			end
		end
		eq(winners, if trial == 4 then 2 else 1, `claim race trial {trial}: winners`)
		if trial == 1 then
			ok((map.counts.conflict or 0) >= 1, "the conflict was replayed on the newest value")
			eq(outcomes.A.action, "none", "the loser sees the other claim")
		end
		local item = map.items["1586034782"]
		ok(item ~= nil and type(item.sortKey) == "number" and item.sortKey > now, "claimed entry hidden from due reads")
	end
	-- After a winner finishes, nobody can claim it again.
	local map = newFakeMap()
	local a = QueueModule.new(map, KINDS)
	a.put(42, { v = 1, k = "missions", d = now - 10, at = now - DAY }, now)
	local _, items = a.due(now, 20)
	local _, won = a.claim(items[1], now, "A:1", ON)
	local fOk, fin = a.finish(42, won.entry, "A:1", "sent", now + 1)
	ok(fOk and fin.result == "sent", "winner finishes")
	local _, after = a.due(now + DAY, 20)
	eq(#after, 0, "a sent marker is never due")
	eq(map.items["42"].value.m, "sent", "sent marker stored")
	eq(map.items["42"].expiration, Queue.SendGapHours * HOUR, "sent marker expiration = gap")
	-- MemoryStore errors never throw
	map.failNext = "update"
	local failed = a.claim({ key = "42", userId = 42, value = map.items["42"].value }, now, "A:2", ON)
	eq(failed, false, "UpdateAsync error → ok = false")
	ok(a.lastError() ~= nil and string.find(a.lastError(), "outage") ~= nil, "last error kept for the status")
	map.failNext = "get"
	local joined = a.join(42, now, now)
	ok(joined == true, "join still writes when the GetAsync fails")
	eq(map.items["42"].expiration, Queue.SendGapHours * HOUR, "unknown old value → marker kept through the gap")
end

------------------------------------------------------------------------------------------------
-- 7. Request: URL + body
------------------------------------------------------------------------------------------------
do
	eq(Logic.url(1586034782), "https://apis.roblox.com/cloud/v2/users/1586034782/notifications", "fixed URL")
	for _, junk in { 0, -5, 1.5, 0 / 0, math.huge, "42", nil, 2 ^ 53 } do
		eq(Logic.url(junk), nil, `bad user id {tostring(junk)}`)
	end
	eq(Logic.keyOf(42), "42", "key")
	eq(Logic.userIdOf("42"), 42, "user id of key")
	for _, junk in { "042", "-1", "1e5", "", "x", string.rep("9", 21), 42 } do
		eq(Logic.userIdOf(junk), nil, `bad key {tostring(junk)}`)
	end
	ok(string.find(Logic.claimToken("abcdef12-3456", 7), "^abcdef12%-3456:7$") ~= nil, "claim token")
	eq(Logic.claimToken("", 1), "studio:1", "Studio claim token")

	local body, err = Logic.buildBody("streak", { day = "3" }, KINDS)
	ok(body ~= nil, `streak body builds ({tostring(err)})`)
	eq(body.source.universe, "universes/10773845696", "source.universe")
	eq(body.payload.type, "MOMENT", "payload.type")
	eq(body.payload.messageId, KINDS.streak.messageId, "payload.messageId")
	eq(body.payload.parameters.day.stringValue, "3", "parameters.day.stringValue")
	eq(body.payload.joinExperience.launchData, "rn:streak", "joinExperience.launchData")
	eq(body.payload.analyticsData.category, "rn_streak", "analyticsData.category")
	local cash = Logic.buildBody("cashFull", nil, KINDS)
	ok(cash ~= nil and cash.payload.parameters == nil, "no parameters for cashFull")
	local encoded = serde.encode("json", body)
	ok(#encoded < 1024, "small body")
	ok(
		string.find(encoded, "x-api-key", 1, true) == nil and string.find(encoded, "Secret", 1, true) == nil,
		"no key in the body"
	)
	eq(select(2, Logic.buildBody("streak", nil, KINDS)), "bad parameter day", "streak needs day")
	eq(select(2, Logic.buildBody("streak", { day = "<script>" }, KINDS)), "bad parameter day", "unsafe parameter")
	eq(
		select(2, Logic.buildBody("streak", { day = string.rep("1", 33) }, KINDS)),
		"bad parameter day",
		"long parameter"
	)
	eq(select(2, Logic.buildBody("cashFull", { day = "1" }, KINDS)), "unexpected parameter day", "extra parameter")
	eq(select(2, Logic.buildBody("bogus", nil, KINDS)), "unknown kind", "unknown kind")
	eq(select(2, Logic.buildBody("streak", { day = "1" }, EMPTY_KINDS)), "no message id", "empty id rejects body")

	-- Exercise the shipped dashboard wiring without overriding kinds. Empty ids remain a valid
	-- way to disable a template; configured ids must keep their own launch route and parameters.
	local messageIds: { [string]: boolean } = {}
	for _, kind in NotifyConfig.KindOrder do
		local def = NotifyConfig.Kinds[kind]
		local parameters = if kind == "streak" then { day = "4" } else nil
		local configured, configError = Logic.buildBody(kind, parameters)
		if def.messageId == "" then
			eq(configured, nil, `{kind}: empty shipped id disables body`)
			eq(configError, "no message id", `{kind}: empty shipped id reason`)
		else
			ok(configured ~= nil, `{kind}: shipped template builds ({tostring(configError)})`)
			eq(configured.payload.messageId, def.messageId, `{kind}: shipped dashboard id`)
			ok(not messageIds[def.messageId], `{kind}: dashboard id is unique`)
			messageIds[def.messageId] = true
			eq(configured.payload.joinExperience.launchData, "rn:" .. kind, `{kind}: shipped launch route`)
			if kind == "streak" then
				eq(configured.payload.parameters.day.stringValue, "4", "shipped streak day is text")
			else
				eq(configured.payload.parameters, nil, `{kind}: shipped template has no parameters`)
			end
		end
	end
end

------------------------------------------------------------------------------------------------
-- 8. Verdicts + back-off
------------------------------------------------------------------------------------------------
do
	local function decode(text: string): any
		local okDecode, value = pcall(serde.decode, "json", text)
		return if okDecode then value else nil
	end
	local function verdict(status: number, body: string?, headers: any?): any
		return Logic.classify(
			true,
			{ StatusCode = status, Success = status < 300, Body = body or "", Headers = headers or {} },
			decode
		)
	end
	local okV = verdict(200, '{"path":"users/1/notifications/x","id":"x"}')
	ok(okV.result == "ok" and okV.entry == "sent" and okV.backoff == "none", "200 ok")
	local thr = verdict(429, '{"code":"RESOURCE_EXHAUSTED","message":"slow down"}', { ["Retry-After"] = "30" })
	ok(thr.result == "throttled" and thr.entry == "retry" and thr.backoff == "short", "429 throttled")
	eq(thr.code, "RESOURCE_EXHAUSTED", "error code parsed")
	eq(thr.retryAfter, 30, "Retry-After honoured")
	eq(verdict(429, "", { ["retry-after"] = "99999" }).retryAfter, Send.BackoffMaxSeconds, "Retry-After clamped")
	eq(verdict(429, "", { ["Retry-After"] = "Wed, 21 Oct 2015" }).retryAfter, nil, "HTTP-date Retry-After ignored")
	for _, status in { 401, 403 } do
		local v = verdict(status, '{"code":"PERMISSION_DENIED"}')
		ok(v.result == "rejected" and v.entry == "retry" and v.backoff == "key", `{status} = key problem`)
	end
	for _, status in { 400, 404, 409 } do
		local v = verdict(status, '{"code":"INVALID_ARGUMENT"}')
		ok(v.result == "rejected" and v.entry == "done" and v.backoff == "none", `{status} rejected for good`)
	end
	for _, status in { 500, 502, 503 } do
		local v = verdict(status)
		ok(v.result == "http" and v.entry == "retry" and v.backoff == "short", `{status} retry`)
	end
	local none = Logic.classify(false, "HttpError: Timedout", decode)
	ok(none.result == "http" and none.status == 0 and none.entry == "retry", "no response")
	eq(verdict(400, '{"code":"<b>bad</b> code!"}').code, "bbadbcode", "error code sanitised")
	eq(verdict(400, "not json").code, nil, "non-JSON body")
	eq(verdict(400, string.rep("x", Send.MaxBodyBytes + 1)).code, nil, "huge body not parsed")
	eq(Logic.backoffSeconds(1, nil), 2, "backoff 1")
	eq(Logic.backoffSeconds(2, nil), 4, "backoff 2")
	eq(Logic.backoffSeconds(3, nil), 8, "backoff 3")
	eq(Logic.backoffSeconds(30, nil), Send.BackoffMaxSeconds, "backoff capped")
	eq(Logic.backoffSeconds(1, 60), 60, "Retry-After wins when larger")
	eq(Logic.backoffSeconds(0 / 0, nil), 2, "NaN failures")
	-- R136: bounded status buckets for "rnotify:status:<kind>:<bucket>".
	for status, bucket in { [400] = "400", [401] = "401", [403] = "403", [404] = "404", [429] = "429" } do
		eq(Logic.statusBucket(status), bucket, `status {status} has its own bucket`)
	end
	eq(Logic.statusBucket(409), "4xx", "other 4xx folded")
	eq(Logic.statusBucket(503), "5xx", "5xx folded")
	eq(Logic.statusBucket(0), "none", "no response")
	eq(Logic.statusBucket(200), "none", "a success is never a status bucket")
	eq(Logic.statusBucket(0 / 0), "none", "NaN")
end

------------------------------------------------------------------------------------------------
-- 9. Token bucket
------------------------------------------------------------------------------------------------
do
	local bucket = Logic.newBucket(3, 0.5, 100)
	eq(Logic.tokens(bucket, 100), 3, "full bucket")
	ok(Logic.take(bucket, 100) and Logic.take(bucket, 100) and Logic.take(bucket, 100), "three takes")
	ok(not Logic.take(bucket, 100), "empty")
	eq(Logic.tokens(bucket, 101), 0, "half a token is not a token")
	ok(Logic.take(bucket, 102), "refilled after 2 s")
	ok(not Logic.take(bucket, 50), "clock backwards adds nothing")
	eq(Logic.tokens(bucket, 10000), 3, "refill capped at capacity")
end

------------------------------------------------------------------------------------------------
-- 10. Control
------------------------------------------------------------------------------------------------
do
	local c = Logic.sanitizeControl({ v = 12.7, on = false, off = { "streak", "bogus", 5 } })
	ok(c ~= nil and c.v == 12 and c.on == false and c.off.streak == true and c.off.bogus == nil, "sanitise")
	for _, junk in { nil, 5, {}, { v = -1, on = true }, { v = 0 / 0, on = true }, { v = 1, on = "yes" } } do
		eq(Logic.sanitizeControl(junk), nil, `junk control {tostring(junk)}`)
	end
	local edited = Logic.withKind(Logic.withOn(ON, false, 5), "missions", false, 6)
	ok(edited.v == 6 and edited.on == false and edited.off.missions == true, "edits")
	local back = Logic.withKind(edited, "missions", true, 7)
	eq(back.off.missions, nil, "kind back on")
	local encoded = Logic.encodeControl(edited)
	ok(encoded.off[1] == "missions" and #encoded.off == 1, "encode lists off kinds")
	local again = Logic.sanitizeControl(jsonCopy(encoded))
	ok(again ~= nil and again.off.missions and again.on == false, "JSON round trip")
	local attributes =
		Logic.controlAttributes(Logic.withKind(Logic.withKind(ON, "streak", false, 1), "cashFull", false, 2))
	eq(attributes[NotifyConfig.Attributes.On], true, "attribute On")
	eq(attributes[NotifyConfig.Attributes.KindsOff], "cashFull,streak", "attribute KindsOff in priority order")
	eq(attributes[NotifyConfig.Attributes.Version], 2, "attribute Version")
	ok(Logic.kindReady(ON, "streak", KINDS), "ready")
	ok(not Logic.kindReady(ON, "streak", EMPTY_KINDS), "not ready without a message id")
end

------------------------------------------------------------------------------------------------
-- 11. Sender (fakes)
------------------------------------------------------------------------------------------------
local function newSender(options: { [string]: any }): (any, any)
	local log: any = { requests = {}, secretLookups = 0 }
	local clock = options.clock or 0
	local secretObject = { __secret = true }
	local deps = {
		isStudio = options.isStudio == true,
		getSecret = function(name: string): any
			log.secretLookups += 1
			assert(name == NotifyConfig.SecretName, "the configured secret name")
			if options.noSecret then
				error("Can't find secret with given key")
			end
			return secretObject
		end,
		request = function(requestOptions: any): any
			table.insert(log.requests, requestOptions)
			if options.respond ~= nil then
				return options.respond(requestOptions)
			end
			return { StatusCode = 200, Success = true, Body = '{"id":"n1"}', Headers = {} }
		end,
		encode = function(value: any): string
			return serde.encode("json", value)
		end,
		decode = function(text: string): any
			return serde.decode("json", text)
		end,
		clock = function(): number
			return log.clock or clock
		end,
		kinds = options.kinds or KINDS,
	}
	log.secretObject = secretObject
	return SenderModule.new(deps), log
end

do
	local studio, studioLog = newSender({ isStudio = true })
	eq(studio.mode(), "dry", "Studio = dry")
	local dry = studio.send(42, "streak", { day = "2" })
	eq(dry.result, "dry", "Studio send is a dry run")
	eq(#studioLog.requests, 0, "Studio never requests")
	eq(studioLog.secretLookups, 0, "Studio never reads the secret")
	eq(studio.send(42, "streak", nil).result, "off", "dry run still validates the body")
	local studioNoIds = newSender({ isStudio = true, kinds = EMPTY_KINDS })
	eq(studioNoIds.send(42, "cashFull", nil).result, "off", "no message id = off even in Studio")

	local nokey, nokeyLog = newSender({ noSecret = true })
	nokeyLog.clock = 0
	eq(nokey.mode(), "nokey", "live without secret")
	eq(nokey.send(42, "cashFull", nil).result, "nokey", "nokey send")
	eq(#nokeyLog.requests, 0, "no request without a key")
	local lookups = nokeyLog.secretLookups
	nokeyLog.clock = Send.SecretRetrySeconds - 1
	nokey.mode()
	eq(nokeyLog.secretLookups, lookups, "secret lookup spaced")
	nokeyLog.clock = Send.SecretRetrySeconds + 1
	nokey.mode()
	eq(nokeyLog.secretLookups, lookups + 1, "secret looked up again after the retry delay")

	local live, liveLog = newSender({})
	eq(live.mode(), "live", "live with secret")
	local sent = live.send(1586034782, "streak", { day = "5" })
	eq(sent.result, "ok", "live ok")
	eq(#liveLog.requests, 1, "one request")
	local request = liveLog.requests[1]
	eq(request.Url, "https://apis.roblox.com/cloud/v2/users/1586034782/notifications", "request URL")
	eq(request.Method, "POST", "request method")
	local headerCount = 0
	for _ in request.Headers do
		headerCount += 1
	end
	eq(headerCount, 2, "exactly two headers (x-api-key + content-type)")
	eq(request.Headers["Content-Type"], "application/json", "content type")
	ok(request.Headers["x-api-key"] == liveLog.secretObject, "the Secret object goes in x-api-key")
	local decoded = serde.decode("json", request.Body)
	eq(decoded.payload.parameters.day.stringValue, "5", "body parameter")
	ok(string.find(request.Body, "__secret", 1, true) == nil, "the secret never enters the body")
	eq(liveLog.secretLookups, 1, "secret cached")
	live.send(1586034782, "missions", nil)
	eq(liveLog.secretLookups, 1, "still cached")

	local throttled = newSender({
		respond = function(): any
			return {
				StatusCode = 429,
				Success = false,
				Body = '{"code":"RESOURCE_EXHAUSTED"}',
				Headers = { ["Retry-After"] = "12" },
			}
		end,
	})
	local t = throttled.send(42, "cashFull", nil)
	ok(t.result == "throttled" and t.verdict.retryAfter == 12 and string.find(t.detail, "429") ~= nil, "429 detail")
	local broken = newSender({
		respond = function(): any
			error("HttpError: ConnectFail")
		end,
	})
	eq(broken.send(42, "cashFull", nil).result, "http", "transport error = http")
	eq(live.send(0, "cashFull", nil).result, "off", "bad user id never requests")
end

------------------------------------------------------------------------------------------------
-- 12. Runner end to end
------------------------------------------------------------------------------------------------
local function newRunner(options: { [string]: any }): any
	local env: any = {
		now = options.now or D0 + 10 * HOUR,
		clock = 1000,
		tracked = {},
		timers = {},
		control = options.control or ON,
	}
	env.map = options.map or newFakeMap()
	env.queue = QueueModule.new(env.map, KINDS)
	env.sender = options.sender
	env.runner = RunnerModule.new({
		queue = env.queue,
		sender = env.sender,
		control = function(): any
			return env.control
		end,
		now = function(): number
			return env.now
		end,
		clock = function(): number
			return env.clock
		end,
		track = function(_player: any, key: string)
			table.insert(env.tracked, key)
		end,
		jobId = "job-test",
		spawn = function(fn: () -> ())
			fn()
		end,
		delay = function(seconds: number, fn: () -> ())
			table.insert(env.timers, { seconds = seconds, fn = fn })
		end,
	})
	return env
end

local function countKey(env: any, key: string): number
	local n = 0
	for _, tracked in env.tracked do
		if tracked == key then
			n += 1
		end
	end
	return n
end

do
	-- plan → poll before due (nothing) → poll after due → ok → sent marker
	local sender = newSender({})
	local env = newRunner({ sender = sender })
	local f = facts({ leaveAt = env.now })
	local outcome = env.runner.plan(nil, f)
	eq(outcome.result, "planned", "runner plan")
	eq(countKey(env, "rnotify:plan:cashFull"), 1, "plan counted")
	local early = env.runner.pollOnce()
	eq(early.read, 0, "nothing due yet")
	env.now += 3 * HOUR + 1
	local poll = env.runner.pollOnce()
	ok(poll.reason == "ok" and poll.read == 1 and poll.claimed == 1, "poll claims the due entry")
	eq(countKey(env, "rnotify:result:ok"), 1, "result ok counted")
	eq(countKey(env, "rnotify:sent:cashFull"), 1, "sent counted")
	eq(env.map.items[tostring(f.userId)].value.m, "sent", "sent marker written")
	eq(env.runner.stats().inFlight, 0, "slot released")
	-- the player comes back from the notification, then leaves again: the next plan respects the gap
	env.runner.join(nil, f.userId, env.now + 60)
	eq(env.map.items[tostring(f.userId)].value.s, env.now, "join keeps the send time")
	env.now += 2 * HOUR
	local again = env.runner.plan(nil, facts({ leaveAt = env.now }))
	eq(again.result, "planned", "plan after return")
	ok(again.plan.due >= env.now - 2 * HOUR + 24 * HOUR, "next notification >= 24 h after the last send")

	-- join cancels a pending entry → drop:rejoined; replaced
	local env2 = newRunner({ sender = newSender({}) })
	env2.runner.plan(nil, facts({ leaveAt = env2.now, userId = 7 }))
	env2.runner.plan(nil, facts({ leaveAt = env2.now + 10, userId = 7 }))
	eq(countKey(env2, "rnotify:drop:replaced"), 1, "replaced counted")
	env2.runner.join(nil, 7, env2.now + 20)
	eq(countKey(env2, "rnotify:drop:rejoined"), 1, "rejoined counted")
	env2.now += DAY
	eq(env2.runner.pollOnce().read, 0, "cancelled entry never sends")
	-- a late plan from the server the player left (after their join) is skipped
	env2.runner.plan(nil, facts({ leaveAt = env2.now - DAY + 15, userId = 7 }))
	eq(countKey(env2, "rnotify:drop:rejoined"), 2, "late plan after a join counted as rejoined")

	-- late drop
	local env3 = newRunner({ sender = newSender({}) })
	env3.queue.put(
		9,
		{ v = 1, k = "streak", d = env3.now - 4 * HOUR, p = { day = "2" }, at = env3.now - DAY },
		env3.now
	)
	local lateReport = env3.runner.pollOnce()
	ok(lateReport.late == 1 and lateReport.claimed == 0, "late entry dropped")
	eq(countKey(env3, "rnotify:drop:late"), 1, "drop:late counted")
	eq(env3.runner.stats().tokens, Send.Burst, "a late drop refunds its token")

	-- kill switch → off
	local env4 = newRunner({ sender = newSender({}), control = Logic.withOn(ON, false, 9) })
	env4.queue.put(10, { v = 1, k = "missions", d = env4.now - 60, at = env4.now - DAY }, env4.now)
	eq(env4.runner.pollOnce().off, 1, "kill switch consumes due entries")
	eq(countKey(env4, "rnotify:result:off"), 1, "result:off counted")
	eq(countKey(env4, "rnotify:plan:cashFull"), 0, "nothing planned while off")
	eq(env4.runner.plan(nil, facts({ leaveAt = env4.now })).result, "none", "plan while off")

	-- 429 → retry + server back-off → next poll backs off
	local thrSender = newSender({
		respond = function(): any
			return { StatusCode = 429, Success = false, Body = "", Headers = {} }
		end,
	})
	local env5 = newRunner({ sender = thrSender })
	env5.queue.put(11, { v = 1, k = "cashFull", d = env5.now - 60, at = env5.now - HOUR }, env5.now)
	env5.queue.put(12, { v = 1, k = "cashFull", d = env5.now - 50, at = env5.now - HOUR }, env5.now)
	local thrPoll = env5.runner.pollOnce()
	eq(thrPoll.claimed, 1, "back-off stops the poll after the first 429")
	eq(countKey(env5, "rnotify:result:throttled"), 1, "throttled counted")
	eq(countKey(env5, "rnotify:status:cashFull:429"), 1, "R136: 429 status counted by kind")
	local entry11 = env5.map.items["11"].value
	ok(
		entry11.n == 1 and entry11.c == nil and entry11.d == env5.now + Queue.RetryBaseSeconds,
		"throttled entry retried later"
	)
	eq(env5.runner.pollOnce().reason, "backoff", "server backs off")
	env5.clock += Logic.backoffSeconds(1, nil) + 0.1
	local resumed = env5.runner.pollOnce()
	eq(resumed.claimed, 1, "resumes after the back-off (entry 12)")
	eq(env5.runner.stats().failures, 2, "consecutive failures")

	-- 401 → key back-off (long)
	local keySender = newSender({
		respond = function(): any
			return { StatusCode = 401, Success = false, Body = '{"code":"UNAUTHENTICATED"}', Headers = {} }
		end,
	})
	local env6 = newRunner({ sender = keySender })
	env6.queue.put(13, { v = 1, k = "missions", d = env6.now - 60, at = env6.now - DAY }, env6.now)
	env6.runner.pollOnce()
	ok(env6.runner.stats().backoffLeft >= Send.KeyBackoffSeconds - 1, "401 = long key back-off")
	eq(countKey(env6, "rnotify:result:rejected"), 1, "rejected counted")
	eq(env6.map.items["13"].value.n, 1, "the entry is retried (not its fault)")
	eq(countKey(env6, "rnotify:status:missions:401"), 1, "R136: 401 status counted by kind")

	-- R136: 400 (notifications off / under 13) → that entry is done, no server back-off
	local offSender = newSender({
		respond = function(): any
			return { StatusCode = 400, Success = false, Body = '{"code":"INVALID_ARGUMENT"}', Headers = {} }
		end,
	})
	local envOff = newRunner({ sender = offSender })
	envOff.queue.put(31, { v = 1, k = "cashFull", d = envOff.now - 60, at = envOff.now - HOUR }, envOff.now)
	envOff.queue.put(32, { v = 1, k = "cashFull", d = envOff.now - 50, at = envOff.now - HOUR }, envOff.now)
	eq(envOff.runner.pollOnce().claimed, 2, "a 400 never stops the poll")
	eq(countKey(envOff, "rnotify:result:rejected"), 2, "both rejected")
	eq(countKey(envOff, "rnotify:status:cashFull:400"), 2, "400 counted per send")
	eq(countKey(envOff, "rnotify:sent:cashFull"), 0, "nothing sent")
	eq(envOff.runner.stats().backoffLeft, 0, "no server back-off for a player's own setting")

	-- per-server limiter: Burst sends per poll at most, the rest waits
	local env7 = newRunner({ sender = newSender({}) })
	for index = 1, Send.Burst + 5 do
		env7.queue.put(
			100 + index,
			{ v = 1, k = "missions", d = env7.now - 100 + index, at = env7.now - DAY },
			env7.now
		)
	end
	local first = env7.runner.pollOnce()
	eq(first.read, math.min(Send.Burst, Queue.BatchSize, Send.MaxInFlight), "a poll reads no more than it can send")
	local total, polls = first.claimed, 1
	while polls < 20 do
		local report = env7.runner.pollOnce()
		polls += 1
		if report.reason == "limited" then
			break
		end
		total += report.claimed
	end
	eq(total, Send.Burst, "a full bucket sends exactly Burst before it is empty")
	eq(env7.runner.pollOnce().reason, "limited", "empty bucket")
	env7.clock += 5 / Send.PerSecond
	local rest = 0
	for _ = 1, 3 do
		rest += env7.runner.pollOnce().claimed
	end
	eq(rest, 5, "refilled bucket sends the rest")

	-- concurrency cap: a sender that never answers holds MaxInFlight slots
	local hangingRequests = 0
	local hanging = {
		mode = function(): string
			return "live"
		end,
		send = function(): any
			hangingRequests += 1
			coroutine.yield() -- never resumed (a hung request)
			return { result = "ok" }
		end,
	}
	local env8 = newRunner({ sender = hanging })
	env8.runner = RunnerModule.new({
		queue = env8.queue,
		sender = hanging,
		control = function(): any
			return ON
		end,
		now = function(): number
			return env8.now
		end,
		clock = function(): number
			return env8.clock
		end,
		track = function(_player: any, key: string)
			table.insert(env8.tracked, key)
		end,
		jobId = "job-test",
		spawn = function(fn: () -> ())
			coroutine.resume(coroutine.create(fn))
		end,
		delay = function(seconds: number, fn: () -> ())
			table.insert(env8.timers, { seconds = seconds, fn = fn })
		end,
	})
	for index = 1, Send.MaxInFlight + 3 do
		env8.queue.put(
			200 + index,
			{ v = 1, k = "missions", d = env8.now - 100 + index, at = env8.now - DAY },
			env8.now
		)
	end
	env8.runner.pollOnce()
	eq(hangingRequests, Send.MaxInFlight, "at most MaxInFlight requests at once")
	eq(env8.runner.stats().inFlight, Send.MaxInFlight, "slots held")
	eq(env8.runner.pollOnce().reason, "busy", "poll waits for a free slot")
	-- the timeouts fire: slots free, results counted as http, server backs off
	for _, timer in env8.timers do
		eq(timer.seconds, Send.TimeoutSeconds, "timeout armed")
		timer.fn()
	end
	eq(env8.runner.stats().inFlight, 0, "timeouts free every slot")
	eq(countKey(env8, "rnotify:result:http"), Send.MaxInFlight, "each timeout counted once")

	-- timeout race: the answer arrives AFTER the timeout → entry finished, result not counted twice
	local env9: any
	local lateSender = {
		mode = function(): string
			return "live"
		end,
		send = function(): any
			for _, timer in env9.timers do
				timer.fn() -- the timeout elapses before the answer
			end
			return { result = "ok", detail = "HTTP 200" }
		end,
	}
	env9 = newRunner({ sender = lateSender })
	env9.queue.put(300, { v = 1, k = "missions", d = env9.now - 60, at = env9.now - DAY }, env9.now)
	env9.runner.pollOnce()
	eq(countKey(env9, "rnotify:result:http"), 1, "timeout counted")
	eq(countKey(env9, "rnotify:result:ok"), 0, "late answer not counted as a second result")
	eq(countKey(env9, "rnotify:sent:missions"), 1, "late success still counts as sent")
	eq(env9.map.items["300"].value.m, "sent", "late success finishes the entry")
	eq(env9.runner.stats().inFlight, 0, "no slot leak")

	-- dry run (Studio) and nokey consume entries without a request
	local env10 = newRunner({ sender = newSender({ isStudio = true }) })
	env10.queue.put(
		400,
		{ v = 1, k = "streak", d = env10.now - 60, p = { day = "2" }, at = env10.now - DAY },
		env10.now
	)
	env10.runner.pollOnce()
	eq(countKey(env10, "rnotify:result:dry"), 1, "dry counted")
	eq(env10.map.items["400"].value.m, "done", "dry run finishes the entry")
	local env11 = newRunner({ sender = newSender({ noSecret = true }) })
	env11.queue.put(401, { v = 1, k = "missions", d = env11.now - 60, at = env11.now - DAY }, env11.now)
	env11.runner.pollOnce()
	eq(countKey(env11, "rnotify:result:nokey"), 1, "nokey counted")

	-- admin test send + queue test
	local env12 = newRunner({ sender = newSender({}) })
	eq(env12.runner.sendTest(nil, 42, "streak", { day = "1" }).result, "ok", "sendTest live")
	ok(env12.runner.queueTest(42, "missions", nil, 0), "queueTest writes")
	eq(env12.runner.pollOnce().claimed, 1, "queued test is due at once")

	-- every key any runner recorded is allowlisted for the retention family
	local all: { string } = {}
	for _, e in { env, env2, env3, env4, env5, env6, env7, env8, env9, env10, env11, env12 } do
		for _, key in e.tracked do
			table.insert(all, key)
		end
	end
	for _, kind in NotifyConfig.KindOrder do
		table.insert(all, `rnotify:join:{kind}`)
		table.insert(all, `rnotify:plan:{kind}`)
		table.insert(all, `rnotify:sent:{kind}`)
	end
	for _, result in { "ok", "throttled", "rejected", "http", "nokey", "off", "dry" } do
		table.insert(all, `rnotify:result:{result}`)
	end
	for _, reason in { "late", "rejoined", "replaced" } do
		table.insert(all, `rnotify:drop:{reason}`)
	end
	for _, moment in NotifyConfig.PromptMoments do
		table.insert(all, `rnotify:promptAt:{moment}`)
	end
	for _, key in all do
		eq(KeySpec.check("retention", key), key, `analytics key {key} allowlisted`)
	end
end

------------------------------------------------------------------------------------------------
-- 13. Admin
------------------------------------------------------------------------------------------------
do
	local long = string.rep("·", 200)
	local text = Logic.statusText({
		mode = "live",
		control = Logic.withKind(ON, "streak", false, 1),
		queueSize = 123456,
		dueNow = 200,
		planned = { cashFull = 5, streak = 3 },
		sent = { cashFull = 4 },
		results = { ok = 4, throttled = 1, rejected = 2, http = 3, dry = 0, nokey = 0, off = 1 },
		drops = { late = 1, rejoined = 7, replaced = 2 },
		recent = { { at = D0 + 14 * HOUR + 2 * 60, kind = "streak", result = "ok", detail = long } },
		backoffLeft = 12.3,
	}, KINDS)
	ok(#text <= 300, `status <= 300 bytes ({#text})`)
	ok(utf8.len(text) ~= nil, "status is valid UTF-8 after the cut")
	ok(string.find(text, "LIVE", 1, true) ~= nil, "status mode")
	ok(string.find(text, "streak OFF", 1, true) ~= nil, "status kind switch")
	ok(string.find(text, "Queue 123456 (200 due)", 1, true) ~= nil, "status queue")
	local short = Logic.statusText({
		mode = "dry",
		control = ON,
		queueSize = nil,
		queueError = "outage",
		planned = {},
		sent = {},
		results = {},
		drops = {},
		recent = { { at = D0 + 14 * HOUR + 2 * 60, kind = "cashFull", result = "dry", detail = "dry run" } },
		backoffLeft = 0,
	}, EMPTY_KINDS)
	ok(string.find(short, "DRY RUN", 1, true) ~= nil and string.find(short, "NO ID", 1, true) ~= nil, "dry status")
	ok(string.find(short, "@ 14:02 UTC", 1, true) ~= nil, "last result time")
	ok(string.find(short, "outage", 1, true) ~= nil, "queue error shown")

	local expected = { "NotifyToggle", "NotifyKind", "NotifyStatus", "NotifyTest", "NotifyQueueTest" }
	for _, name in expected do
		local def = AdminConfig.Commands[name]
		ok(def ~= nil, `{name} declared`)
		eq(def.tab, "Server", `{name} tab`)
		eq(def.provider, "Return notifications (R122 ReturnNotifyService)", `{name} provider`)
		ok(#def.label <= AdminConfig.Limits.MaxLabelLength, `{name} label length`)
		ok(
			def.description == nil or #def.description <= AdminConfig.Limits.MaxDescriptionLength,
			`{name} description length`
		)
		local kindArg = def.args.kind
		if kindArg ~= nil then
			eq(#kindArg.values, #NotifyConfig.KindOrder, `{name} kind enum`)
			for index, kind in NotifyConfig.KindOrder do
				eq(kindArg.values[index], kind, `{name} kind {index}`)
			end
		end
	end
	eq(AdminConfig.Commands.NotifyStatus.audited, false, "status is read-only")
	eq(AdminConfig.Commands.NotifyToggle.confirm, true, "kill switch confirms")
	eq(AdminConfig.Commands.NotifyQueueTest.studioOnly, true, "queue test Studio-only")
end

print(`return-notify: {checks} checks passed`)
