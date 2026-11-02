--!strict
--[[
	ProfileSyncState — the server's per-player plan for each ProfileUpdate push (full snapshot or
	delta), from RoBeasts (perf audit 2026-10-15 row 14), extended for SellNukes with
	partial snapshot builds (partialFields).

	Purpose:
		PlayerDataService builds a fresh owner snapshot on every (coalesced) push. This pure module
		decides what actually goes on the wire, so the rules live in one tested place:
			FULL  when the client cannot apply a delta: it never acked delta support (an old or
			      broken client keeps the unchanged ProfileUpdate contract), nothing was sent yet
			      (join / late join), a full one was requested (ProfileResync).
			DELTA otherwise: only the top-level fields that changed since the last push
			      (ProfileDelta.diff; only the dirty fields + VolatileFields when at least one
			      mutation declared its fields and none since the last push was undeclared; a
			      push nobody declared anything for compares every field, so a caller that never
			      marks fields is still correct, just not optimized).
			NONE  a delta with nothing in it (the push is skipped).
		Each push advances the wrapping sequence; a delta names the base it applies to. The
		last-sent copy is a deep copy (only the changed fields are re-copied after a delta).
		The server is authoritative: no client value ever enters this state. A client can only
		flip `capable` (ack, rate-limited by the caller) and ask for a full resend.

	Worlds (owner R57 World 2, schema v2): a world currency change (Bones) declares only
	{ "worldCash" } (PlayerDataService.grantCurrency / trySpendCurrency), a world's structure
	{ "worlds" }. Both go through the same dirty set as cash, so a producer tick that pays Nuke Town
	cash and Dino Valley Bones in the same frame is ONE coalesced delta { cash, totalEarned,
	worldCash } — never a second push and never the world structure (tests/profile-sync.luau
	measures both tick shapes against the bandwidth budget).

	Connects to: Shared/Net/ProfileDelta (diff / copy / seq), Shared/Config/ProfileSyncConfig,
	Server/Services/PlayerDataService (owns one State per session and sends the plan),
	tests/profile-sync.luau (fuzz + benchmark + bandwidth budget).

	Example:
		local state = ProfileSyncState.new()
		ProfileSyncState.markDirty(state, { "cash", "totalEarned" })
		local plan = ProfileSyncState.plan(state, snapshot)
		if plan.kind == "full" then fireClient("ProfileUpdate", player, snapshot, plan.seq)
		elseif plan.kind == "delta" then fireClient("ProfileDelta", player, plan.delta) end
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProfileDelta = require(ReplicatedStorage.Shared.Net.ProfileDelta)
local ProfileSyncConfig = require(ReplicatedStorage.Shared.Config.ProfileSyncConfig)

-- One player's sync state (owned by their PlayerDataService session).
export type State = {
	capable: boolean, -- the client acked delta support of ProfileSyncConfig.Version
	seq: number, -- sequence of the last push sent (0 = nothing sent yet)
	lastSent: ProfileDelta.Snapshot?, -- deep copy of what the client holds
	forceFull: boolean, -- next push must be a full snapshot (respawn, resync)
	dirty: { [string]: boolean }, -- top-level fields mutations declared since the last push
	-- "none": nothing declared since the last push (compare every field); "known": only declared
	-- mutations (compare the dirty + volatile fields); "unknown": an undeclared mutation happened.
	dirtyMode: "none" | "known" | "unknown",
}

-- What to send for one push.
export type Plan =
	{ kind: "full", seq: number, reason: string }
	| { kind: "delta", delta: ProfileDelta.Delta, changed: number }
	| { kind: "none" }

local ProfileSyncState = {}

--[[ A fresh state for a new session (no snapshot sent; not delta-capable until the client acks). ]]
function ProfileSyncState.new(): State
	return { capable = false, seq = 0, lastSent = nil, forceFull = false, dirty = {}, dirtyMode = "none" }
end

--[[
	Records which top-level snapshot fields a mutation touched (nil = unknown: the next push
	compares every field).
	@param fields e.g. { "cash", "totalEarned" } (top-level snapshot field names)
]]
function ProfileSyncState.markDirty(state: State, fields: { string }?)
	if fields == nil then
		state.dirtyMode = "unknown"
		return
	end
	if state.dirtyMode == "none" then
		state.dirtyMode = "known"
	end
	for _, field in fields do
		state.dirty[field] = true
	end
end

--[[ The next push is a full snapshot (resync request, re-acked client). ]]
function ProfileSyncState.requestFull(state: State)
	state.forceFull = true
end

--[[
	SellNukes addition (2026-10-30): which top-level snapshot fields the NEXT push needs, so the
	server can build a PARTIAL snapshot instead of deep-copying the whole profile on every cash
	tick (pushes run up to ProfileSyncConfig.MaxPushesPerSecond per player).
	Returns nil whenever `plan` could need anything beyond the dirty + volatile fields — i.e. it
	will plan a FULL push (client not delta-capable, nothing sent yet, a full one requested) or a
	compare-everything delta (an undeclared mutation, or nothing declared at all). Otherwise
	returns exactly the fields `plan`'s diff reads in "known" mode: the declared dirty fields plus
	ProfileSyncConfig.VolatileFields (deduplicated). Pure: reads the state, changes nothing.
	@return field list for ProfileLogic.snapshot(profile, context, fields), or nil = build it all
	Example:
		ProfileSyncState.markDirty(state, { "cash" })
		ProfileSyncState.partialFields(state) --> { "cash", "saveStatus" } (once delta-capable)
]]
function ProfileSyncState.partialFields(state: State): { string }?
	if not state.capable or state.lastSent == nil or state.forceFull or state.dirtyMode ~= "known" then
		return nil
	end
	local list: { string } = {}
	for field in state.dirty do
		table.insert(list, field)
	end
	for _, field in ProfileSyncConfig.VolatileFields do
		if not state.dirty[field] then
			table.insert(list, field)
		end
	end
	return list
end

--[[
	The client declared delta support. Only the exact current version counts; anything else
	keeps (or puts) the client on full snapshots.
	@return true when the client is now delta-capable
]]
function ProfileSyncState.ack(state: State, version: unknown): boolean
	state.capable = version == ProfileSyncConfig.Version
	return state.capable
end

-- Clears the dirty bookkeeping after a push.
local function resetDirty(state: State)
	table.clear(state.dirty)
	state.dirtyMode = "none"
end

--[[
	Plans one push of `snapshot` (a fresh ProfileLogic.snapshot + merged fields; never mutated).
	Advances the sequence for "full" and "delta"; "none" changes nothing.
	@return the plan (see the header); the caller sends `snapshot` itself for a full plan
]]
function ProfileSyncState.plan(state: State, snapshot: ProfileDelta.Snapshot): Plan
	local previous = state.lastSent
	local reason: string? = if not state.capable
		then "notCapable"
		elseif previous == nil then "noBase"
		elseif state.forceFull then "requested"
		else nil
	if reason ~= nil or previous == nil then
		state.seq = ProfileDelta.nextSeq(state.seq)
		state.lastSent = ProfileDelta.deepCopy(snapshot)
		state.forceFull = false
		resetDirty(state)
		return { kind = "full", seq = state.seq, reason = reason or "noBase" }
	end
	local fields: { string }? = nil
	if state.dirtyMode == "known" then
		local list: { string } = {}
		for field in state.dirty do
			table.insert(list, field)
		end
		fields = list
	end
	local set, cleared, changed = ProfileDelta.diff(previous, snapshot, fields)
	resetDirty(state)
	if changed == 0 then
		return { kind = "none" }
	end
	local base = state.seq
	state.seq = ProfileDelta.nextSeq(base)
	-- Keep the last-sent copy current: re-copy only what changed.
	for field, value in set do
		previous[field] = ProfileDelta.deepCopy(value)
	end
	for _, field in cleared do
		previous[field] = nil
	end
	return { kind = "delta", delta = ProfileDelta.build(state.seq, base, set, cleared), changed = changed }
end

return table.freeze(ProfileSyncState)
