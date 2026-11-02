--!strict
--[[
	ProfileSyncConfig — tunables for the owner-profile push (full ProfileUpdate snapshots and
	delta ProfileDelta pushes). Protocol copied from RoBeasts (perf audit 2026-10-15 row 14).

	Purpose:
		In a tycoon, cash changes several times a second (every producer cycle, every click). The
		server must never send the whole profile for that. PlayerDataService therefore:
			1. COALESCES mutations: a push is scheduled once and sent at most MaxPushesPerSecond
			   times per player (leading edge: the first change after a quiet period goes out on
			   the next resumption cycle, so a click feels instant; later changes inside the window
			   ride along in the trailing push);
			2. sends a DELTA (only changed top-level fields) once the client acked delta support,
			   and builds only the declared dirty fields (+ VolatileFields) instead of the whole
			   snapshot (ProfileSyncState.partialFields);
			3. sends a FULL snapshot only when the client has no valid base (join, resync request,
			   a client that never acked).
		The server stays authoritative: the client never sends profile data, only "I support
		deltas" (ProfileDeltaAck) and "resend me everything" (ProfileResync, rate-limited).

	Bandwidth budget (measured by tests/profile-sync.luau with Shared/Net/WireSize):
		a cash tick delta { v, seq, base, set = { cash, totalEarned }, cleared = {} } is ~116 bytes
		on the wire (2026-10-30 measurement), so the worst case of 4 pushes/s is ≤ 464 B/s
		(~3.7 kbit/s) per player and ~3.7 kB/s for a full 8-player server — far below Roblox's
		~50 kB/s per-player guidance. A late-game FULL snapshot (100 pads, 200 pets) is ~8 kB and
		is only sent on join / resync. The test fails if a cash tick ever exceeds 128 bytes.

	Connects to: Shared/Net/ProfileDelta (diff / apply / sequence math), Server/Economy/
	ProfileSyncState (per-player push planning), Server/Services/PlayerDataService (pushes),
	Client/ProfileSyncClient + Client/ClientState (merge), tests/profile-sync.luau.

	Example:
		local ProfileSyncConfig = require(ReplicatedStorage.Shared.Config.ProfileSyncConfig)
		print(ProfileSyncConfig.MinPushInterval) --> 0.25
]]

local ProfileSyncConfig = {}

--[[
	Kill switch. false = full ProfileUpdate on every push (still numbered, so a client mid-session
	stays consistent) and clients never ack. Flip it if a delta bug ever reaches players.
]]
ProfileSyncConfig.Enabled = true

-- Delta wire version. A client acks the version it implements; any other version gets full
-- snapshots only.
ProfileSyncConfig.Version = 1

-- Sequence numbers run 1..SeqModulo and wrap back to 1 (0 = "no snapshot yet"). They are only
-- ever compared for equality, so wrapping is safe; 2^24 keeps them exact.
ProfileSyncConfig.SeqModulo = 16777216

-- Values a deep compare may visit per push before it gives up and treats the field as changed
-- (sending a field that did not change is always safe).
ProfileSyncConfig.MaxCompareNodes = 8192

-- Deepest nesting a compare / copy walks (the snapshot nests 4 levels; deeper = "changed").
ProfileSyncConfig.MaxDepth = 8

-- Hard cap on owner-profile pushes per player per second (coalescing window = 1 / this).
ProfileSyncConfig.MaxPushesPerSecond = 4
ProfileSyncConfig.MinPushInterval = 1 / ProfileSyncConfig.MaxPushesPerSecond

--[[
	Top-level snapshot fields that can change WITHOUT a declared profile mutation, so they are
	always compared even when a push knows its dirty fields. SellNukes keeps this minimal: only
	`saveStatus` (a lost session lock flips it with no mutation). Timers use the synced server
	clock on the client (workspace:GetServerTimeNow()), so no clock field rides along.
]]
ProfileSyncConfig.VolatileFields = table.freeze({
	"saveStatus",
})

-- Server token bucket per player for ProfileResync (an honest client needs one rarely) and
-- ProfileDeltaAck (once per session).
ProfileSyncConfig.ResyncLimit = table.freeze({ Burst = 2, PerSecond = 1 / 10 })
ProfileSyncConfig.AckLimit = table.freeze({ Burst = 2, PerSecond = 1 / 30 })

return table.freeze(ProfileSyncConfig)
