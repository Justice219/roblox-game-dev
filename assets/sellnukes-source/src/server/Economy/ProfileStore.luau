--!strict
--[[
	ProfileStore — session-locked DataStore persistence for player profiles.

	Purpose:
		Loads, autosaves and releases one profile per player with the guarantees a currency
		system needs:
			- Session locking: loading writes a lock { jobId, sessionId, heartbeatAt } into the
			  record with UpdateAsync. Another server that finds a live lock does NOT load; it
			  retries with exponential backoff (the other server is usually mid-release) and gives
			  up after Timing.loadAttempts. A lock whose heartbeat is older than
			  lockStaleSeconds (the owning server crashed) is taken over, and so is a lock left by
			  one of THIS server's own finished sessions (e.g. its release save failed during an
			  outage) — this server knows that session is gone.
			- Never overwrite another session: every save re-checks in its UpdateAsync transform
			  that the record still carries OUR sessionId. If not (a stale takeover happened), the
			  session flips to "lost" and stops saving forever.
			- Retries with exponential backoff on DataStore errors; everything is pcall'd.
			- Per-key write throttle (DataStores allow ~1 write / 6 s per key) and per-session
			  write serialization (saves never run concurrently for one profile).
			- Version tracking (changeVersion / savedVersion) so callers like ProcessReceipt can
			  wait until a specific change is durably saved (`commitAsync`).
			- Newer-schema or quarantined receipt data loads "readOnly": it is shown but never
			  written back, preserving raw recovery facts that reconciliation cannot safely retain.

	Stored record (DataStore value, key "Profile_<UserId>"):
		{ format = 1, data = <Profile>, lock = <Lock>?, updatedAt = <unix> }
		The record's UserId is attached via UpdateAsync's userIds return (GDPR erasure support).

	Session save status:
		"ok"       loaded with a lock; saves normally
		"disabled" in-memory only (Studio without API access / DataStores failing) — never saves
		"readOnly" saved by a newer game version — keeps the lock alive (heartbeat), never writes data
		"lost"     our lock was taken by another server — never writes again
	Sandbox sessions (admin New Player Mode, B14 / B17, ported from RoBeasts WS-H):
		`sandboxSession(userId)` builds a brand-new default profile with status "ok" (so gameplay
		treats it as a healthy first-time player) but `sandbox = true`, which
		Shared/Util/NewPlayerMode.saveDecision maps to "skip": it is never written by any path,
		never autosaved, never the user's live lock holder, and commitAsync never calls it
		durable (so no receipt can ever be acknowledged into it).

	SellNukes additions:
		- The saved payload is ProfileLogic.toSave(profile) (numeric sets as arrays, non-finite
		  numbers scrubbed) instead of a raw deep copy, so a stray NaN can never block saving.
		- Options.beforeSave(session) runs right before every payload snapshot (autosave,
		  release, commit): PlayerDataService stamps offline.lastSeenAt / tycoon.lastSaveAt there,
		  so offline earnings count from the last save even after a server crash.

	Testability:
		The DataStore is injected (anything with `UpdateAsync(key, transform)` semantics), along
		with clocks and timing, so tests/profile-store.luau drives this module (under Lune) with an
		in-memory mock store: lock, takeover, lost lock, throttle, commit and release paths.

	Connects to:
		PlayerDataService (owns one ProfileStore, maps Player → Session, autosave loop,
		BindToClose), MonetizationService (commitAsync for receipts), ProfileLogic (migrate,
		toSave), Shared/Util/NewPlayerMode (the one save decision, sandbox aware).

	Example:
		local store = ProfileStore.new(DataStoreService:GetDataStore("SellNukesProfiles_v1"), {
			jobId = game.JobId, placeId = game.PlaceId,
		})
		local session, err = store:openAsync(player.UserId)  -- err: "locked" | "error"
		ProfileLogic.addCash(session.profile, 10)
		store:markDirty(session)
		store:saveAsync(session, true) -- final save + release the lock
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NewPlayerMode = require(ReplicatedStorage.Shared.Util.NewPlayerMode)
local ProfileLogic = require(script.Parent.ProfileLogic)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

export type SaveStatus = "ok" | "disabled" | "readOnly" | "lost"
-- "cancelled": the caller's shouldStop said stop (player left / server closing) before a lock was
-- taken, so there is nothing to release (ProfileStore.openAsync).
export type OpenError = "locked" | "error" | "cancelled"

export type Lock = {
	jobId: string,
	sessionId: string,
	placeId: number,
	acquiredAt: number, -- unix
	heartbeatAt: number, -- unix; refreshed by every save
}

export type Session = {
	userId: number,
	key: string,
	sessionId: string,
	profile: ProfileLogic.Profile,
	status: SaveStatus,
	migration: ProfileLogic.MigrationStatus,
	-- Bumped by markDirty for every in-memory change; savedVersion is the changeVersion that the
	-- last successful save contained. savedVersion >= v means change v is durable.
	changeVersion: number,
	savedVersion: number,
	-- Developer-product receipts granted in memory but not yet confirmed saved:
	-- purchaseId -> changeVersion that must be saved before PurchaseGranted may be returned.
	pendingReceipts: { [string]: number },
	saving: boolean,
	saveDone: Signal.Signal<boolean>,
	lastWriteAt: number, -- clock() of the last write attempt (per-key throttle)
	nextAutosaveAt: number, -- clock() when the autosave loop should save next
	released: boolean,
	-- New Player Mode: true for a SANDBOX session (sandboxSession) — a throwaway brand-new profile.
	-- saveAsync skips it (NewPlayerMode.saveDecision), autosave never picks it, commitAsync never
	-- calls it durable, and its UpdateAsync transform refuses it (defence in depth).
	sandbox: boolean,
}

export type Timing = {
	loadAttempts: number, -- lock/load attempts before giving up
	saveAttempts: number, -- write attempts per save before giving up
	baseDelay: number, -- first backoff delay (doubles each retry)
	maxDelay: number, -- backoff cap
	lockStaleSeconds: number, -- a lock without a heartbeat for this long may be taken over
	minWriteInterval: number, -- per-key write spacing (DataStore limit is ~6 s)
	autosaveInterval: number, -- seconds between autosaves of one profile
	autosaveJitter: number, -- random extra delay on the FIRST autosave so saves stagger
}

export type Options = {
	jobId: string,
	placeId: number,
	clock: (() -> number)?, -- monotonic seconds (default os.clock)
	now: (() -> number)?, -- unix seconds (default os.time)
	timing: Timing?,
	keyPrefix: string?, -- default "Profile_"
	-- Runs right before every save snapshots the profile (never yields; errors are caught).
	beforeSave: ((session: Session) -> ())?,
}

-- Minimal DataStore surface we use (GlobalDataStore:UpdateAsync). Typed loosely because the
-- transform's return shape (value, userIds) is variadic.
type StoreLike = {
	UpdateAsync: (self: any, key: string, transform: (unknown, unknown) -> (any, any)) -> ...any,
}

type StoredRecord = { data: unknown, lock: Lock? }

local ProfileStore = {}
ProfileStore.__index = ProfileStore

local RECORD_FORMAT = 1

-- Production timings. Copy with table.clone and edit to customize (PlayerDataService does for
-- Studio; tests/profile-store.luau uses tiny delays).
local DEFAULT_TIMING: Timing = {
	loadAttempts = 6, -- 1 + 2 + 4 + 8 + 8 s of backoff ≈ 23 s total before giving up
	saveAttempts = 4,
	baseDelay = 1,
	maxDelay = 8,
	lockStaleSeconds = 600, -- 5 missed autosaves
	minWriteInterval = 6.5,
	autosaveInterval = 120,
	autosaveJitter = 30,
}

--[[ A fresh copy of the production timings (callers may edit their copy). ]]
function ProfileStore.defaultTiming(): Timing
	return table.clone(DEFAULT_TIMING)
end

type ProfileStoreData = {
	_store: StoreLike,
	_jobId: string,
	_placeId: number,
	_clock: () -> number,
	_now: () -> number,
	_timing: Timing,
	_keyPrefix: string,
	_activeWrites: number,
	_random: Random,
	-- userId -> sessionId of the session this server currently has open for that user.
	_liveSessions: { [number]: string },
	_beforeSave: ((session: Session) -> ())?,
}

export type ProfileStore = typeof(setmetatable({} :: ProfileStoreData, ProfileStore))

--[[
	Creates a store over a DataStore (or a mock with the same UpdateAsync semantics).
	@param dataStore GlobalDataStore or test double
	@param options   jobId/placeId identify this server in locks; clocks/timing are injectable
]]
function ProfileStore.new(dataStore: any, options: Options): ProfileStore
	local self: ProfileStoreData = {
		_store = dataStore :: StoreLike,
		_jobId = options.jobId,
		_placeId = options.placeId,
		_clock = options.clock or os.clock,
		_now = options.now or function(): number
			return os.time()
		end,
		_timing = options.timing or ProfileStore.defaultTiming(),
		_keyPrefix = options.keyPrefix or "Profile_",
		_activeWrites = 0,
		_random = Random.new(),
		_liveSessions = {},
		_beforeSave = options.beforeSave,
	}
	return setmetatable(self, ProfileStore)
end

--[[ The DataStore key for a user (UserId only — never names). ]]
function ProfileStore.keyFor(self: ProfileStore, userId: number): string
	return `{self._keyPrefix}{userId}`
end

-- Reads a lock table from untrusted stored data (nil if absent or malformed).
local function readLock(value: unknown): Lock?
	if type(value) ~= "table" then
		return nil
	end
	local lock = value :: { [string]: unknown }
	if type(lock.jobId) ~= "string" or type(lock.sessionId) ~= "string" or type(lock.heartbeatAt) ~= "number" then
		return nil
	end
	return {
		jobId = lock.jobId :: string,
		sessionId = lock.sessionId :: string,
		placeId = if type(lock.placeId) == "number" then lock.placeId :: number else 0,
		acquiredAt = if type(lock.acquiredAt) == "number" then lock.acquiredAt :: number else 0,
		heartbeatAt = lock.heartbeatAt :: number,
	}
end

-- Splits a stored value into (data, lock). Accepts our record format; any other table is treated
-- as bare profile data with no lock (defensive: e.g. a value written by a manual migration).
local function readRecord(value: unknown): StoredRecord
	if type(value) ~= "table" then
		return { data = nil, lock = nil }
	end
	local record = value :: { [string]: unknown }
	if record.format == nil then
		return { data = value, lock = nil }
	end
	return { data = record.data, lock = readLock(record.lock) }
end

-- Builds a Session around a loaded profile.
local function newSession(
	self: ProfileStore,
	userId: number,
	sessionId: string,
	profile: ProfileLogic.Profile,
	status: SaveStatus,
	migration: ProfileLogic.MigrationStatus
): Session
	local clock = self._clock()
	return {
		userId = userId,
		key = self:keyFor(userId),
		sessionId = sessionId,
		profile = profile,
		status = status,
		migration = migration,
		changeVersion = 0,
		savedVersion = 0,
		pendingReceipts = {},
		saving = false,
		saveDone = Signal.new() :: Signal.Signal<boolean>,
		lastWriteAt = clock,
		nextAutosaveAt = clock
			+ self._timing.autosaveInterval
			+ self._random:NextNumber() * self._timing.autosaveJitter,
		released = false,
		sandbox = false, -- real sessions are never sandboxes (see sandboxSession)
	}
end

--[[
	An in-memory session with default data that is never saved (Studio without API access, or
	DataStores failing). status defaults to "disabled".
]]
function ProfileStore.memorySession(self: ProfileStore, userId: number): Session
	return newSession(self, userId, HttpService:GenerateGUID(false), ProfileLogic.defaultProfile(), "disabled", "new")
end

--[[
	A SANDBOX session for admin New Player Mode: a brand-new default profile (status "ok",
	migration "new", so every system treats it exactly like a first-time player's healthy session)
	that is NEVER saved. Three independent guards keep it out of the DataStore:
		1. `sandbox = true` → NewPlayerMode.saveDecision says "skip" before any UpdateAsync,
		2. the UpdateAsync transform refuses a sandbox again (defence in depth),
		3. it carries its own fresh sessionId (never registered in _liveSessions, never the stored
		   lock's), so even a write that got past 1 and 2 would see "lock is not ours" and leave
		   the record untouched.
	The real session stays open (PlayerDataService parks it) and keeps the lock.
	Example:
		local sandbox = store:sandboxSession(player.UserId)
		print(sandbox.profile.cash, sandbox.sandbox) --> 0 true
]]
function ProfileStore.sandboxSession(self: ProfileStore, userId: number): Session
	local session =
		newSession(self, userId, HttpService:GenerateGUID(false), ProfileLogic.defaultProfile(), "ok", "new")
	session.sandbox = true
	session.nextAutosaveAt = math.huge -- autosave never even considers it
	return session
end

--[[
	Loads a profile and takes its session lock. Yields (DataStore + backoff).
	@param userId     the profile owner
	@param shouldStop optional; asked before EVERY attempt (so also after each backoff wait). When
	                  it returns true the open gives up with "cancelled" without touching the
	                  record. Why (verifier 2026-10-21): a server that starts closing (or whose
	                  player already left) while a load is still retrying must not take a lock
	                  after BindToClose has finished — that lock would be orphaned and lock the
	                  player out of every server until it goes stale. An attempt already in flight
	                  is never interrupted: if it took the lock, the session is returned and the
	                  caller releases it.
	@return (session, nil) on success; (nil, "locked") if another live server kept the lock for
	        every attempt; (nil, "error") if DataStores kept failing; (nil, "cancelled") when
	        shouldStop asked to stop before a lock was taken.
	Example:
		local session, err = store:openAsync(player.UserId, function(): boolean
			return shuttingDown or player.Parent ~= Players
		end)
]]
function ProfileStore.openAsync(
	self: ProfileStore,
	userId: number,
	shouldStop: (() -> boolean)?
): (Session?, OpenError?)
	local timing = self._timing
	local key = self:keyFor(userId)
	local sessionId = HttpService:GenerateGUID(false)
	local delay = timing.baseDelay
	local lastError: OpenError = "error"

	for attempt = 1, timing.loadAttempts do
		if shouldStop ~= nil and shouldStop() then
			return nil, "cancelled"
		end
		-- The transform may run more than once (concurrent writers); the last run wins.
		local outcome: "acquired" | "locked" | nil = nil
		local loaded: unknown = nil
		local holder = ""
		local ok, err = pcall(function()
			self._store:UpdateAsync(key, function(old: unknown): (any, any)
				local record = readRecord(old)
				local now = self._now()
				local lock = record.lock
				if lock ~= nil and lock.sessionId ~= sessionId then
					local age = now - lock.heartbeatAt
					-- Our own server's lock for a session that is no longer open here is dead.
					local ownDeadSession = lock.jobId == self._jobId and self._liveSessions[userId] ~= lock.sessionId
					if age < timing.lockStaleSeconds and not ownDeadSession then
						outcome = "locked"
						holder = lock.jobId
						return nil, nil -- abort: never touch a live session's record
					end
					warn(`[ProfileStore] taking over lock on {key} (job {lock.jobId}, {age}s old)`)
				end
				outcome = "acquired"
				loaded = record.data
				local newLock: Lock = {
					jobId = self._jobId,
					sessionId = sessionId,
					placeId = self._placeId,
					acquiredAt = now,
					heartbeatAt = now,
				}
				return { format = RECORD_FORMAT, data = record.data, lock = newLock, updatedAt = now }, { userId }
			end)
		end)

		if ok and outcome == "acquired" then
			local profile, migration = ProfileLogic.migrate(loaded)
			-- Data saved by a NEWER game version loads read-only: this older server must never
			-- overwrite fields it does not understand (the heartbeat path keeps the lock alive).
			local status: SaveStatus = if migration == "newer" then "readOnly" else "ok"
			if status == "readOnly" then
				warn(`[ProfileStore] {key}: saved by a newer game version; loading read-only`)
			end
			self._liveSessions[userId] = sessionId
			return newSession(self, userId, sessionId, profile, status, migration), nil
		elseif ok and outcome == "locked" then
			lastError = "locked"
			warn(`[ProfileStore] {key} is locked by job {holder} (attempt {attempt}/{timing.loadAttempts})`)
		else
			lastError = "error"
			warn(`[ProfileStore] load {key} failed (attempt {attempt}/{timing.loadAttempts}): {err}`)
		end
		if attempt < timing.loadAttempts then
			task.wait(delay)
			delay = math.min(delay * 2, timing.maxDelay)
		end
	end
	return nil, lastError
end

--[[
	What a save does for a session (one rule for every save path; Shared/Util/NewPlayerMode owns
	it so the sandbox case is defined and Lune-tested in one place):
		"write"     "ok": write the profile + refresh the lock heartbeat
		"heartbeat" "readOnly": refresh the lock only (stored data untouched)
		"skip"      a New Player Mode SANDBOX (whatever its status), "disabled" (in-memory) or
		            "lost" (another server owns it): never touch the store
	Example: ProfileStore.saveDecision("ok") --> "write"; ProfileStore.saveDecision("ok", true) --> "skip"
]]
local function saveDecision(status: SaveStatus, sandbox: boolean?): NewPlayerMode.SaveDecision
	return NewPlayerMode.saveDecision(sandbox == true, status)
end
ProfileStore.saveDecision = saveDecision

-- Runs Options.beforeSave (if any) for a session about to be written; a fault never stops a save.
local function runBeforeSave(self: ProfileStore, session: Session)
	local hook = self._beforeSave
	if hook == nil then
		return
	end
	local ok, err = pcall(hook, session)
	if not ok then
		warn(`[ProfileStore] beforeSave failed for {session.key}: {err}`)
	end
end

--[[
	Records that the session's profile changed in memory.
	@return the new changeVersion (pass to commitAsync to wait until this change is saved)
]]
function ProfileStore.markDirty(_self: ProfileStore, session: Session): number
	session.changeVersion += 1
	return session.changeVersion
end

--[[ Asks the autosave loop to save this session soon (within ~minWriteInterval). ]]
function ProfileStore.requestSaveSoon(self: ProfileStore, session: Session)
	session.nextAutosaveAt = math.min(session.nextAutosaveAt, self._clock() + 1)
end

--[[ True if the autosave loop should save this session now. ]]
function ProfileStore.isAutosaveDue(self: ProfileStore, session: Session): boolean
	return not session.released
		and not session.saving
		and not session.sandbox -- a New Player Mode sandbox is never saved
		and (session.status == "ok" or session.status == "readOnly")
		and self._clock() >= session.nextAutosaveAt
end

--[[ Number of DataStore writes currently in progress (BindToClose waits for 0). ]]
function ProfileStore.activeWrites(self: ProfileStore): number
	return self._activeWrites
end

--[[
	Writes the session to the DataStore (refreshing the lock heartbeat), or with `release` also
	clears the lock (final save when the player leaves / the server closes). Yields.
	Saves for one session are serialized; a release after a release is a no-op.
	@return true only if the profile data was durably written by this call
]]
function ProfileStore.saveAsync(self: ProfileStore, session: Session, release: boolean?): boolean
	-- Serialize writes for this profile: wait for any save in flight.
	while session.saving do
		session.saveDone:Wait()
	end
	if session.released then
		return false
	end
	-- One decision for every save path (autosave, leave, shutdown, receipt commits): a New Player
	-- Mode SANDBOX, an in-memory ("disabled") or a "lost" session never touches the DataStore. A
	-- release still ends it.
	if saveDecision(session.status, session.sandbox) == "skip" then
		if release then
			session.released = true
		end
		return false
	end

	local timing = self._timing
	session.saving = true
	self._activeWrites += 1
	if release then
		-- Autosave must never touch this session again.
		session.nextAutosaveAt = math.huge
	else
		session.nextAutosaveAt = self._clock() + timing.autosaveInterval
	end

	-- Respect the per-key write rate (~1 write / 6 s).
	local sinceLast = self._clock() - session.lastWriteAt
	if sinceLast < timing.minWriteInterval then
		task.wait(timing.minWriteInterval - sinceLast)
	end

	-- Re-decided after the throttle wait (the status may have changed meanwhile).
	local writesData = saveDecision(session.status, session.sandbox) == "write"
	if writesData then
		runBeforeSave(self, session)
	end
	local version = session.changeVersion
	-- Snapshot now so the saved data matches `version` exactly (nothing yields in between).
	local payload = if writesData then ProfileLogic.toSave(session.profile) else nil
	local result: "ok" | "lost" | "error" = "error"
	local delay = timing.baseDelay

	for attempt = 1, timing.saveAttempts do
		local outcome: "ok" | "lost" | nil = nil
		local ok, err = pcall(function()
			self._store:UpdateAsync(session.key, function(old: unknown): (any, any)
				local record = readRecord(old)
				local lock = record.lock
				-- Defence in depth: a sandbox never writes, even if a caller got this far.
				if session.sandbox or lock == nil or lock.sessionId ~= session.sessionId then
					outcome = "lost"
					return nil, nil -- someone else owns this profile now: never overwrite it
				end
				outcome = "ok"
				local now = self._now()
				local newLock: Lock? = if release
					then nil
					else {
						jobId = lock.jobId,
						sessionId = lock.sessionId,
						placeId = lock.placeId,
						acquiredAt = lock.acquiredAt,
						heartbeatAt = now,
					}
				local data = if payload ~= nil then payload else record.data
				return { format = RECORD_FORMAT, data = data, lock = newLock, updatedAt = now }, { session.userId }
			end)
		end)
		if ok and outcome ~= nil then
			result = outcome
			break
		end
		warn(`[ProfileStore] save {session.key} failed (attempt {attempt}/{timing.saveAttempts}): {err}`)
		if attempt < timing.saveAttempts then
			task.wait(delay)
			delay = math.min(delay * 2, timing.maxDelay)
		end
	end

	session.lastWriteAt = self._clock()
	if result == "ok" then
		if writesData then
			session.savedVersion = math.max(session.savedVersion, version)
		end
		if release then
			session.released = true
		end
	elseif result == "lost" then
		warn(`[ProfileStore] lost the session lock on {session.key}; this server stops saving it`)
		session.status = "lost"
		if release then
			session.released = true
		end
	end
	-- result == "error": the lock stays in the store; a later save (or the stale timeout)
	-- resolves it. A failed RELEASE still ends the session as far as this server is concerned,
	-- so a rejoin here may take the lock over at once (see openAsync).
	if release and self._liveSessions[session.userId] == session.sessionId then
		self._liveSessions[session.userId] = nil
	end

	session.saving = false
	self._activeWrites -= 1
	local saved = result == "ok" and writesData
	session.saveDone:Fire(saved)
	return saved
end

--[[
	Ensures change `version` (from markDirty) is durably saved, saving now if needed. Yields.
	@return true once savedVersion >= version
]]
function ProfileStore.commitAsync(self: ProfileStore, session: Session, version: number): boolean
	-- A New Player Mode sandbox is never durable: receipts / gifts must never be acknowledged
	-- into it (MonetizationService also defers its receipts before reaching this).
	if session.sandbox then
		return false
	end
	if session.savedVersion >= version then
		return true
	end
	-- A save already in flight might have snapshotted after `version`; wait for it first.
	while session.saving do
		session.saveDone:Wait()
	end
	if session.savedVersion >= version then
		return true
	end
	self:saveAsync(session, false)
	return session.savedVersion >= version
end

return ProfileStore
