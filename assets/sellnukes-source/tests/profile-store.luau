--!strict
--[[
	ProfileStore regressions (src/server/Economy/ProfileStore.luau) over an in-memory DataStore
	that round-trips every write through JSON (@lune/serde), like Roblox DataStores do — so a
	payload JSON cannot hold (NaN, sparse number sets) fails here exactly as it would live. Run:
		lune run tests/profile-store

	Proves:
	  1. memorySession: "disabled", never writes, release just ends it.
	  2. openAsync on a new key: "ok" / "new", the record carries OUR lock and the UserId list.
	  3. A second server cannot open a live-locked profile ("locked" after its attempts) and never
	     touches the record; shouldStop → "cancelled" with no write.
	  4. saveAsync writes ProfileLogic.toSave (numeric sets as arrays → valid JSON), refreshes the
	     heartbeat, runs beforeSave (stamps), advances savedVersion; commitAsync is a no-op when
	     already durable and writes otherwise; per-key throttle is honoured.
	  5. Release clears the lock; another server then opens at once and sees the saved data.
	  6. Stale takeover: a lock past lockStaleSeconds is taken over; the old session's next save
	     finds the foreign lock → "lost", returns false, never overwrites.
	  7. Newer schema → "readOnly": heartbeat only, stored data never rewritten.
	  8. DataStore errors: open → "error" after its attempts; a failing save returns false and
	     leaves savedVersion (so receipts are never acknowledged on a failed save).
	  9. A NaN in the live profile is scrubbed on save (save still succeeds).
	 10. New Player Mode sandbox (sandboxSession): brand-new "ok" / "new" profile, flagged
	     sandbox, never autosave-due, never written by save / release / commit (even with a forged
	     sessionId), never the live lock holder — the parked REAL session keeps saving and its
	     record is untouched by everything done in the sandbox; saveDecision is sandbox aware.
]]

local serde = require("@lune/serde")
local task = require("@lune/task")
local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local ProfileLogic = loader.load("src/server/Economy/ProfileLogic")
local ProfileStore = loader.load("src/server/Economy/ProfileStore")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

-- A JSON-backed mock of GlobalDataStore:UpdateAsync (transform returning nil cancels the write).
type Mock = { data: { [string]: string }, writes: number, failing: boolean, read: (self: Mock, key: string) -> any }
local function newMock(): any
	local mock = { data = {}, writes = 0, failing = false }
	function mock.UpdateAsync(self: any, key: string, transform: (any, any) -> (any, any)): any
		if self.failing then
			error("DataStore request failed (mock)")
		end
		local raw = self.data[key]
		local old = if raw ~= nil then serde.decode("json", raw) else nil
		local value, userIds = transform(old, nil)
		if value == nil then
			return nil
		end
		assert(type(userIds) == "table", "UpdateAsync writes must attach the UserId list")
		self.data[key] = serde.encode("json", value) -- errors on NaN / mixed tables, like Roblox
		self.writes += 1
		return value
	end
	function mock.read(self: any, key: string): any
		local raw = self.data[key]
		return if raw ~= nil then serde.decode("json", raw) else nil
	end
	return mock
end

-- Fast timings + controllable clocks.
local clockNow = 1000
local unixNow = 1_800_000_000
local function timing(): any
	local t = ProfileStore.defaultTiming()
	t.loadAttempts = 2
	t.saveAttempts = 2
	t.baseDelay = 0.01
	t.maxDelay = 0.01
	t.minWriteInterval = 0
	t.lockStaleSeconds = 600
	return t
end
local stamped = 0
local function newStore(mock: any, jobId: string): any
	return ProfileStore.new(mock, {
		jobId = jobId,
		placeId = 1,
		clock = function()
			return clockNow
		end,
		now = function()
			return unixNow
		end,
		timing = timing(),
		beforeSave = function(session: any)
			stamped += 1
			session.profile.offline.lastSeenAt = unixNow
		end,
	})
end

local USER = 4242
local KEY = `Profile_{USER}`

-- 1. memorySession
local mock = newMock()
local storeA = newStore(mock, "job-A")
local memory = storeA:memorySession(USER)
check(memory.status == "disabled" and memory.migration == "new", "memory session is disabled + new")
check(storeA:saveAsync(memory, false) == false and mock.writes == 0, "memory session never writes")
storeA:saveAsync(memory, true)
check(memory.released and mock.writes == 0, "memory release ends it without a write")

-- 2. open a new profile
local session, err = storeA:openAsync(USER)
check(session ~= nil and err == nil, "open new profile")
check(session.status == "ok" and session.migration == "new", "new profile is ok/new")
local record = mock:read(KEY)
check(
	record.format == 1 and record.lock.sessionId == session.sessionId and record.lock.jobId == "job-A",
	"lock written"
)

-- 3. a second server is locked out; shouldStop cancels
local storeB = newStore(mock, "job-B")
local writesBefore = mock.writes
local lockedSession, lockedErr = storeB:openAsync(USER)
check(lockedSession == nil and lockedErr == "locked", "second server sees locked")
check(mock.writes == writesBefore, "a locked open never writes")
local cancelled, cancelErr = storeB:openAsync(USER, function()
	return true
end)
check(cancelled == nil and cancelErr == "cancelled", "shouldStop cancels before any attempt")

-- 4. save, beforeSave stamp, commit, sets as arrays
ProfileLogic.addCash(session.profile, 500)
session.profile.timeRewards.claimed[2] = true
session.profile.event.stickers[5] = true
local version = storeA:markDirty(session)
check(version == 1, "markDirty returns version 1")
check(storeA:saveAsync(session, false) == true, "save ok")
check(session.savedVersion == 1 and stamped >= 1, "savedVersion advanced, beforeSave ran")
record = mock:read(KEY)
check(record.data.cash == 500 and record.data.offline.lastSeenAt == unixNow, "saved data + stamp")
check(record.data.timeRewards.claimed[1] == 2 and record.data.event.stickers[1] == 5, "numeric sets saved as arrays")
check(record.lock.heartbeatAt == unixNow, "heartbeat refreshed")
writesBefore = mock.writes
check(storeA:commitAsync(session, 1) and mock.writes == writesBefore, "commit of a saved version is free")
ProfileLogic.addGems(session.profile, 7)
local v2 = storeA:markDirty(session)
check(storeA:commitAsync(session, v2) and mock.writes == writesBefore + 1, "commit writes an unsaved version")
check(mock:read(KEY).data.gems == 7, "committed gems stored")

-- Throttle: minWriteInterval delays the next write of the same key.
session.lastWriteAt = clockNow
local throttled = storeA._timing
throttled.minWriteInterval = 0.05
local startedAt = os.clock()
-- Our injected clock does not advance on its own; advance it while the store waits.
task.delay(0.02, function()
	clockNow += 0.05
end)
storeA:saveAsync(session, false)
check(os.clock() - startedAt >= 0.04, "per-key throttle waited")
throttled.minWriteInterval = 0

-- 5. release → another server opens immediately and sees the data
check(storeA:saveAsync(session, true) == true and session.released, "release saves + ends")
check(mock:read(KEY).lock == nil, "lock cleared on release")
local sessionB = storeB:openAsync(USER)
check(sessionB ~= nil and sessionB.status == "ok" and sessionB.migration == "current", "B opens after release")
check(sessionB.profile.cash == 500 and sessionB.profile.gems == 7, "B sees the saved data")
check(sessionB.profile.timeRewards.claimed[2] == true, "array set read back into a set")

-- 6. stale takeover → the old owner becomes "lost"
unixNow += 601
local storeC = newStore(mock, "job-C")
local sessionC = storeC:openAsync(USER)
check(sessionC ~= nil and sessionC.status == "ok", "stale lock taken over")
ProfileLogic.addCash(sessionB.profile, 1)
storeB:markDirty(sessionB)
local before = mock:read(KEY).data.cash
check(storeB:saveAsync(sessionB, false) == false and sessionB.status == "lost", "old owner's save → lost")
check(mock:read(KEY).data.cash == before, "a lost session never overwrites")
check(storeB:saveAsync(sessionB, false) == false, "lost stays lost")
storeC:saveAsync(sessionC, true)

-- 7. newer schema → read-only heartbeat
local newerMock = newMock()
newerMock.data[KEY] = serde.encode("json", { format = 1, data = { schemaVersion = 99, cash = 3 }, updatedAt = 0 })
local storeN = newStore(newerMock, "job-N")
local readOnly = storeN:openAsync(USER)
check(readOnly ~= nil and readOnly.status == "readOnly" and readOnly.migration == "newer", "newer → readOnly")
readOnly.profile.cash = 999
storeN:markDirty(readOnly)
check(storeN:saveAsync(readOnly, false) == false, "read-only save reports not durable")
local newerRecord = newerMock:read(KEY)
check(newerRecord.data.schemaVersion == 99 and newerRecord.data.cash == 3, "newer data never rewritten")
check(newerRecord.lock ~= nil and newerRecord.lock.sessionId == readOnly.sessionId, "heartbeat keeps the lock")

-- 8. DataStore errors
local failing = newMock()
failing.failing = true
local storeF = newStore(failing, "job-F")
local failedSession, failedErr = storeF:openAsync(USER)
check(failedSession == nil and failedErr == "error", "open → error after attempts")
failing.failing = false
local okSession = storeF:openAsync(USER)
check(okSession ~= nil, "opens once the store recovers")
ProfileLogic.addCash(okSession.profile, 10)
local failVersion = storeF:markDirty(okSession)
failing.failing = true
check(storeF:saveAsync(okSession, false) == false and okSession.savedVersion < failVersion, "failed save not durable")
check(not storeF:commitAsync(okSession, failVersion), "commit false while the store fails")
failing.failing = false
check(storeF:commitAsync(okSession, failVersion), "commit succeeds after recovery")

-- 9. NaN scrubbed on save
okSession.profile.stats.clicks = 0 / 0
storeF:markDirty(okSession)
check(storeF:saveAsync(okSession, false) == true, "save with NaN still succeeds")
check(failing:read(KEY).data.stats.clicks == 0, "NaN stored as 0")

-- 10. New Player Mode sandbox: the real session keeps the lock; nothing of the sandbox is written.
local npmMock = newMock()
local storeS = newStore(npmMock, "job-S")
local real = storeS:openAsync(USER)
check(real ~= nil and real.sandbox == false, "a real session is not a sandbox")
ProfileLogic.addCash(real.profile, 42)
check(storeS:commitAsync(real, storeS:markDirty(real)), "real profile committed before the swap")
local realRecord = npmMock:read(KEY)
local writesAtSwap = npmMock.writes
local sandbox = storeS:sandboxSession(USER)
check(sandbox.sandbox and sandbox.status == "ok" and sandbox.migration == "new", "sandbox is a healthy new session")
check(sandbox.profile.cash == 0 and sandbox.sessionId ~= real.sessionId, "sandbox: fresh profile, own sessionId")
check(not storeS:isAutosaveDue(sandbox), "sandbox never autosave-due")
clockNow += 10_000
check(not storeS:isAutosaveDue(sandbox) and storeS:isAutosaveDue(real), "only the parked real session autosaves")
ProfileLogic.addCash(sandbox.profile, 1_000_000)
local sandboxVersion = storeS:markDirty(sandbox)
check(storeS:saveAsync(sandbox, false) == false, "sandbox save reports not durable")
check(not storeS:commitAsync(sandbox, sandboxVersion), "sandbox commit is never durable (receipts)")
check(npmMock.writes == writesAtSwap, "sandbox save / commit never write")
-- Defence in depth: even a forged sessionId (the stored lock's) never writes a sandbox.
sandbox.sessionId = real.sessionId
check(storeS:saveAsync(sandbox, false) == false and npmMock.writes == writesAtSwap, "forged sandbox still skipped")
storeS:saveAsync(sandbox, true)
check(sandbox.released and npmMock.writes == writesAtSwap, "sandbox release ends it without a write")
check(npmMock:read(KEY).data.cash == realRecord.data.cash, "real record untouched by the sandbox")
check(storeS:saveAsync(real, false) == true and npmMock:read(KEY).data.cash == 42, "parked real session still saves")
check(npmMock:read(KEY).lock.sessionId == real.sessionId, "the real session still holds the lock")
check(
	ProfileStore.saveDecision("ok") == "write"
		and ProfileStore.saveDecision("ok", true) == "skip"
		and ProfileStore.saveDecision("readOnly") == "heartbeat"
		and ProfileStore.saveDecision("readOnly", true) == "skip"
		and ProfileStore.saveDecision("lost") == "skip",
	"saveDecision is sandbox aware"
)
check(storeS:saveAsync(real, true) and npmMock:read(KEY).lock == nil, "real release clears the lock")

print(`[profile-store] {checks} checks passed`)
