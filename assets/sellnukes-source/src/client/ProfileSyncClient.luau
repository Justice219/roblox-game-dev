--!strict
--[[
	ProfileSyncClient — the client end of delta profile sync (copied from RoBeasts, perf audit
	2026-10-15 row 14; SellNukes passes the changed field names on to ClientState).

	Purpose:
		Keeps the client's copy of its own profile current from two server pushes:
			ProfileUpdate(snapshot, seq?)  a full snapshot: replaces the profile; `seq` (when the
			                               server sends one) becomes the base for deltas
			ProfileDelta(delta)            only the changed top-level fields: validated
			                               (ProfileDelta.validate) and merged into a NEW table
			                               (ProfileDelta.apply) when delta.base == our seq
		On a base mismatch (a delta was lost or arrived before its base) the client keeps its last
		good profile and sends ProfileResync, at most once per ResyncRetrySeconds while it waits;
		the server answers with its own full snapshot. At start it acks the delta version once
		(ProfileDeltaAck); until the server sees the ack it keeps sending full snapshots exactly as
		before, so nothing breaks if this module never starts.
		Every accepted profile goes to the `onProfile(profile, fields?)` callback: `fields` is the
		list of top-level fields a delta changed (set + cleared), nil for a full snapshot (=
		"everything may have changed"). ClientState sets ClientState.profile and fires
		ProfileChanged(profile, fields) once per push, so a HUD cash label can skip work when only
		`pets` changed.
		Field-generic by design: new top-level snapshot fields need no code here. The schema v2
		world fields (owner R57) arrive like any other — `worldCash` (a Bones tick: fields =
		{ "worldCash" }), `worlds` (world structure) and `lastWorld` — and ClientState exposes
		them through world / worldUnlocked / worldCash / lastWorld.

	Security: the client never sends profile data. Its only messages are the ack and the resync
	request, both rate-limited server-side; the server stays authoritative.

	Testability: `handleFull` / `handleDelta` are plain functions over a State and an injected
	`requestResync`, so tests/profile-sync.luau drives them without Roblox. Studio smoke tests read
	the converged state through ClientState (cash on the client vs the server's profile).

	Connects to: Shared/Net/ProfileDelta (validate / apply), Shared/Config/ProfileSyncConfig,
	Shared/Net/Remotes (ProfileUpdate, ProfileDelta, ProfileDeltaAck, ProfileResync),
	ClientState (installs it), Server/Economy/ProfileSyncState (the server's side).

	Example:
		ProfileSyncClient.start(function(profile, fields)
			ClientState.profile = profile
			ClientState.ProfileChanged:Fire(profile, fields)
		end)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProfileDelta = require(ReplicatedStorage.Shared.Net.ProfileDelta)
local ProfileSyncConfig = require(ReplicatedStorage.Shared.Config.ProfileSyncConfig)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)

-- The client's sync state.
export type State = {
	profile: ProfileDelta.Snapshot?,
	seq: number, -- 0 = no base (no full snapshot with a sequence yet)
	resyncAt: number, -- os.clock() of the last resync request (-inf = none pending)
}

local ProfileSyncClient = {}

-- Seconds between repeated resync requests while still waiting for the full snapshot.
local RESYNC_RETRY_SECONDS = 2

--[[ A fresh client state (no profile yet). ]]
function ProfileSyncClient.newState(): State
	return { profile = nil, seq = 0, resyncAt = -math.huge }
end

--[[
	A full ProfileUpdate arrived.
	@param state the client state
	@param snapshot the payload's 1st argument (must be a table)
	@param seq the payload's 2nd argument (a whole number 1..SeqModulo, else "no base")
	@return the new profile, or nil when the payload is not a table (ignored)
]]
function ProfileSyncClient.handleFull(state: State, snapshot: unknown, seq: unknown): ProfileDelta.Snapshot?
	if type(snapshot) ~= "table" then
		return nil
	end
	state.profile = snapshot :: ProfileDelta.Snapshot
	local validSeq = type(seq) == "number"
		and seq == math.floor(seq)
		and seq >= 1
		and seq <= ProfileSyncConfig.SeqModulo
	state.seq = if validSeq then seq :: number else 0
	state.resyncAt = -math.huge -- any pending resync is answered
	return state.profile
end

--[[
	A ProfileDelta arrived.
	@param state the client state
	@param raw the payload (validated here)
	@param now os.clock()
	@param requestResync sends ProfileResync (called at most once per RESYNC_RETRY_SECONDS)
	@return the merged new profile and the changed top-level field names, or nil (malformed, or a
	        base mismatch: resync requested)
]]
function ProfileSyncClient.handleDelta(
	state: State,
	raw: unknown,
	now: number,
	requestResync: () -> ()
): (ProfileDelta.Snapshot?, { string }?)
	local delta = ProfileDelta.validate(raw)
	if delta == nil then
		return nil, nil
	end
	local merged, seq = ProfileDelta.apply(state.profile, state.seq, delta)
	if merged == nil then
		if now - state.resyncAt >= RESYNC_RETRY_SECONDS then
			state.resyncAt = now
			requestResync()
		end
		return nil, nil
	end
	state.profile = merged
	state.seq = seq
	local fields: { string } = {}
	for field in delta.set do
		table.insert(fields, field)
	end
	for _, field in delta.cleared do
		table.insert(fields, field)
	end
	return merged, fields
end

local state = ProfileSyncClient.newState()
local started = false

--[[
	Wires the remotes (idempotent). `onProfile` receives every accepted profile (full or merged).
	Remote lookups may yield until they replicate; ClientState calls this from its own start.
]]
function ProfileSyncClient.start(onProfile: (profile: ProfileDelta.Snapshot, fields: { string }?) -> ())
	if started then
		return
	end
	started = true
	Remotes.event("ProfileUpdate").OnClientEvent:Connect(function(snapshot: unknown, seq: unknown)
		local profile = ProfileSyncClient.handleFull(state, snapshot, seq)
		if profile ~= nil then
			onProfile(profile, nil)
		end
	end)
	local resyncRemote = Remotes.event("ProfileResync")
	Remotes.event("ProfileDelta").OnClientEvent:Connect(function(raw: unknown)
		local profile, fields = ProfileSyncClient.handleDelta(state, raw, os.clock(), function()
			resyncRemote:FireServer()
		end)
		if profile ~= nil then
			onProfile(profile, fields)
		end
	end)
	-- Kill switch: with ProfileSyncConfig.Enabled off the client never asks for deltas.
	if ProfileSyncConfig.Enabled then
		Remotes.event("ProfileDeltaAck"):FireServer(ProfileSyncConfig.Version)
	end
end

--[[ The current sequence (diagnostics / Studio tests). ]]
function ProfileSyncClient.seq(): number
	return state.seq
end

return ProfileSyncClient
