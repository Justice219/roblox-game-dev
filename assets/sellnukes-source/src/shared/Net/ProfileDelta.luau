--!strict
--[[
	ProfileDelta — pure math for delta ProfileUpdates (RoBeasts perf audit 2026-10-15 row 14, reused by SellNukes).

	Purpose:
		The server pushes the owner's profile snapshot (ProfileLogic.snapshot; a late-game
		profile with pets is several kB) up to ProfileSyncConfig.MaxPushesPerSecond times a
		second while cash ticks. Almost every push changes only `cash` / `totalEarned` (a few
		dozen bytes). This module is both ends of the delta protocol (copied from RoBeasts):
			SERVER  diff(previous, current, fields?) → which top-level fields changed (deep compare,
			        bounded), deepCopy (the last-sent copy), nextSeq (wrapping sequence)
			CLIENT  validate(raw) (shape check of a server payload) and apply(profile, seq, delta) →
			        a NEW profile table (shallow clone + the changed fields), or "resync"
		Granularity is the top-level field: a changed field is sent whole (fields are small
		except pets / tycoon, which change rarely). Pure (no services, no requires
		beyond the config): `lune run tests/profile-sync.luau` fuzzes diff → apply against full
		snapshots and benchmarks the compare.

	Protocol (remotes; see Server/Economy/ProfileSyncState for the server's state machine):
		S→C ProfileUpdate(snapshot, seq?)   full snapshot; `seq` (new, optional 2nd argument) is
		                                    the base for deltas. Old clients ignore it, so the
		                                    wire contract is unchanged.
		S→C ProfileDelta(delta)             { v, seq, base, set = { [field] = value },
		                                      cleared = { field } } — only after the client acked.
		C→S ProfileDeltaAck(version)        "I can apply deltas of this version" (rate-limited).
		C→S ProfileResync()                 "my base is wrong, send a full snapshot" (rate-limited;
		                                    the answer is always the server's own full snapshot).
		The client applies a delta only when delta.base == its current seq; otherwise it asks
		for a resync and keeps its last good profile meanwhile.

	Sequence: 1..ProfileSyncConfig.SeqModulo, wrapping to 1 (0 = no snapshot yet). Only equality
	is ever tested, so a wrap cannot reorder anything.

	Example:
		-- server
		local set, cleared = ProfileDelta.diff(lastSent, snapshot, nil)
		-- client
		local nextProfile, nextSeq = ProfileDelta.apply(profile, seq, delta)
		if nextProfile == nil then requestResync() end
]]

local ProfileSyncConfig = require(script.Parent.Parent.Config.ProfileSyncConfig)

-- A top-level-keyed snapshot (field → any value the snapshot carries).
export type Snapshot = { [string]: any }

-- One delta payload (ProfileDelta remote).
export type Delta = {
	v: number,
	seq: number,
	base: number,
	set: { [string]: any },
	cleared: { string },
}

local ProfileDelta = {}

--[[
	The sequence number after `seq`: 1..SeqModulo, wrapping back to 1 (0 is "none").
	Example: ProfileDelta.nextSeq(0) --> 1 ; ProfileDelta.nextSeq(ProfileSyncConfig.SeqModulo) --> 1
]]
function ProfileDelta.nextSeq(seq: number): number
	if seq >= ProfileSyncConfig.SeqModulo or seq < 0 or seq ~= math.floor(seq) then
		return 1
	end
	return seq + 1
end

-- Visit budget of the current compare (reset per diff / equal call; nothing yields inside).
local compareBudget = 0

-- Deep equality within the budget / depth caps; out of budget or too deep counts as different.
local function equal(a: any, b: any, depth: number): boolean
	compareBudget -= 1
	if compareBudget < 0 then
		return false
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return rawequal(a, b) -- scalars (or a table vs a scalar)
	end
	-- Past MaxDepth nothing is walked and the answer is "different", even for the same object:
	-- deepCopy shares tables only beyond MaxDepth, and such a shared table may have been mutated
	-- in place since it was sent, so resending it is the only safe answer.
	if depth >= ProfileSyncConfig.MaxDepth then
		return false
	end
	-- Within MaxDepth the last-sent side is always a fresh deepCopy, so the same object on both
	-- sides means the caller compared a table with itself: equal by definition.
	if rawequal(a, b) then
		return true
	end
	local count = 0
	for key, value in next, a do
		count += 1
		local other = rawget(b, key)
		if other == nil or not equal(value, other, depth + 1) then
			return false
		end
	end
	-- Same number of keys on both sides (every key of `a` was found in `b`).
	for _ in next, b do
		count -= 1
		if count < 0 then
			return false
		end
	end
	return count == 0
end

--[[
	Deep equality of two snapshot values (bounded: MaxCompareNodes / MaxDepth; past either bound
	the values count as different, which only ever sends a field that did not need sending).
]]
function ProfileDelta.equal(a: any, b: any): boolean
	compareBudget = ProfileSyncConfig.MaxCompareNodes
	return equal(a, b, 0)
end

--[[
	A deep copy of a snapshot value (tables copied recursively; scalars returned as-is). Used for
	the server's last-sent copy, so later in-place mutations of live tables can never hide a
	change. Bounded by MaxDepth (deeper tables are shared by reference; `equal` reports anything
	that deep as changed, so a shared table is resent rather than trusted).
]]
local function copy(value: any, depth: number): any
	if type(value) ~= "table" or depth >= ProfileSyncConfig.MaxDepth then
		return value
	end
	local out = {}
	for key, item in next, value do
		out[key] = copy(item, depth + 1)
	end
	return out
end

function ProfileDelta.deepCopy(value: any): any
	return copy(value, 0)
end

--[[
	The top-level fields that differ between the last-sent snapshot and the current one.
	@param previous what the client has (the server's last-sent copy)
	@param current the new snapshot
	@param fields when the mutation path knows which fields it touched: only those (plus
	       ProfileSyncConfig.VolatileFields) are compared; nil = compare every field
	@return set (field → the CURRENT value, not copied), cleared (fields present before, absent
	        now), and how many fields changed
	Example: ProfileDelta.diff({ cash = 1, gems = 2 }, { cash = 5, gems = 2 }, nil) --> { cash = 5 }, {}, 1
]]
function ProfileDelta.diff(
	previous: Snapshot,
	current: Snapshot,
	fields: { string }?
): ({ [string]: any }, { string }, number)
	local set: { [string]: any } = {}
	local cleared: { string } = {}
	local decided: { [string]: boolean } = {}
	local changed = 0
	local function compare(field: string)
		if decided[field] then
			return -- already decided (a field listed twice, or both dirty and volatile)
		end
		decided[field] = true
		local now = current[field]
		local before = previous[field]
		if now == nil then
			if before ~= nil then
				table.insert(cleared, field)
				changed += 1
			end
		elseif before == nil or not ProfileDelta.equal(before, now) then
			set[field] = now
			changed += 1
		end
	end
	if fields == nil then
		for field in current do
			compare(field)
		end
		for field in previous do
			if current[field] == nil then
				compare(field)
			end
		end
	else
		for _, field in fields do
			compare(field)
		end
		for _, field in ProfileSyncConfig.VolatileFields do
			compare(field)
		end
	end
	return set, cleared, changed
end

--[[
	Builds a delta payload.
	@param seq the new sequence number; @param base the sequence the client must hold
]]
function ProfileDelta.build(seq: number, base: number, set: { [string]: any }, cleared: { string }): Delta
	return { v = ProfileSyncConfig.Version, seq = seq, base = base, set = set, cleared = cleared }
end

-- A sequence number as the protocol allows it (whole, 1..SeqModulo).
local function validSeq(value: unknown): boolean
	return type(value) == "number"
		and value == math.floor(value)
		and value >= 1
		and value <= ProfileSyncConfig.SeqModulo
end

--[[
	CLIENT: shape check of a ProfileDelta payload (server data, still checked so a broken payload
	can never error inside ClientState or corrupt the profile table).
	@return the typed delta, or nil
]]
function ProfileDelta.validate(raw: unknown): Delta?
	if type(raw) ~= "table" then
		return nil
	end
	local fields = raw :: { [string]: unknown }
	if fields.v ~= ProfileSyncConfig.Version or not validSeq(fields.seq) or not validSeq(fields.base) then
		return nil
	end
	if type(fields.set) ~= "table" or type(fields.cleared) ~= "table" then
		return nil
	end
	for key in fields.set :: { [unknown]: unknown } do
		if type(key) ~= "string" then
			return nil
		end
	end
	for _, field in fields.cleared :: { unknown } do
		if type(field) ~= "string" then
			return nil
		end
	end
	return raw :: any
end

--[[
	CLIENT: applies a validated delta to the current profile.
	@param profile the client's current profile (never mutated)
	@param seq the client's current sequence (0 = none)
	@param delta a validated delta
	@return a NEW profile table and the new sequence, or nil when the base does not match (the
	        caller keeps its profile and asks for a resync)
	Example: ProfileDelta.apply({ cash = 1 }, 7, { v = 1, seq = 8, base = 7, set = { cash = 3 }, cleared = {} })
	         --> { cash = 3 }, 8
]]
function ProfileDelta.apply(profile: Snapshot?, seq: number, delta: Delta): (Snapshot?, number)
	if profile == nil or seq == 0 or delta.base ~= seq then
		return nil, seq
	end
	-- Shallow clone: untouched fields keep their identity (consumers comparing tables see only
	-- the changed fields as new), the previous table stays valid for anyone still holding it.
	local nextProfile = table.clone(profile)
	for field, value in delta.set do
		nextProfile[field] = value
	end
	for _, field in delta.cleared do
		nextProfile[field] = nil
	end
	return nextProfile, delta.seq
end

return table.freeze(ProfileDelta)
