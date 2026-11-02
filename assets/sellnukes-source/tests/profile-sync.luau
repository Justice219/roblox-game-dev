--!strict
--[[
	Profile sync regressions: Shared/Net/ProfileDelta, Server/Economy/ProfileSyncState (incl. the
	SellNukes partialFields build), Client/ProfileSyncClient, against REAL ProfileLogic snapshots,
	plus the bandwidth budget measured with Shared/Net/WireSize. Run:
		lune run tests/profile-sync

	Proves:
	  1. Sequence numbers wrap safely (SeqModulo → 1, junk → 1).
	  2. diff / equal basics and the dirty-only compare (declared fields + VolatileFields).
	  3. Client: validate rejects malformed payloads; apply refuses a wrong base and never mutates
	     the old profile; handleDelta returns the changed field names.
	  4. Server state machine: full until ack, full first push, full on request, delta otherwise,
	     "none" when nothing changed.
	  5. partialFields: nil whenever a full / compare-everything push is needed, else exactly the
	     dirty + volatile fields; a partial snapshot plans the same delta as a full one.
	  6. A 1 500-step fuzz of a live tycoon profile (cash ticks, pad buys, pets, settings; some
	     mutations declared, some not; dropped deltas force a resync; the sequence wraps): after
	     every step the client's profile deep-equals a fresh full snapshot.
	  7. Bandwidth: a cash-tick delta is ≤ 128 bytes, so 4 pushes/s stay ≤ 512 B/s per player.
	  8. Worlds (owner R57, schema v2): the fuzz also grants Bones ({ "worldCash" }), buys Dino pads
	     ({ "worlds" }) and changes lastWorld; a Bones tick is a worldCash-only delta ≤ 160 bytes
	     (measured 141 B 2026-10-30: the nested { dino = { cash, totalEarned } } costs ~25 B over a
	     cash tick; 4/s ≤ 640 B/s) and never resends the world structure; a cash + Bones tick in
	     the same frame coalesces into ONE delta ≤ 192 bytes (measured 180 B).
]]

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local Config = loader.load("src/shared/Config/ProfileSyncConfig")
local Delta = loader.load("src/shared/Net/ProfileDelta")
local State = loader.load("src/server/Economy/ProfileSyncState")
local ProfileLogic = loader.load("src/server/Economy/ProfileLogic")
local SyncClient = loader.load("src/client/ProfileSyncClient")
local WireSize = loader.load("src/shared/Net/WireSize")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

local function deepEqual(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for key, value in a do
		if not deepEqual(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

-- 1. Sequence numbers
check(Delta.nextSeq(0) == 1, "0 → 1")
check(Delta.nextSeq(41) == 42, "increment")
check(Delta.nextSeq(Config.SeqModulo) == 1, "wrap")
check(Delta.nextSeq(-3) == 1 and Delta.nextSeq(2.5) == 1, "junk → 1")

-- 2. diff / equal
check(Delta.equal({ a = { 1, 2 } }, { a = { 1, 2 } }), "deep equal")
check(not Delta.equal({ a = 1 }, { a = 1, b = 2 }), "key count differs")
local set, cleared, changed = Delta.diff({ cash = 1, gems = 2, old = true }, { cash = 5, gems = 2 }, nil)
check(set.cash == 5 and set.gems == nil and #cleared == 1 and cleared[1] == "old" and changed == 2, "full diff")
set, cleared, changed = Delta.diff({ cash = 1, gems = 2 }, { cash = 5, gems = 3 }, { "cash" })
check(set.cash == 5 and set.gems == nil and changed == 1, "dirty-only diff ignores undeclared fields")

-- 3. Client validate / apply
check(Delta.validate(nil) == nil and Delta.validate({ v = 99 }) == nil, "validate rejects junk")
check(
	Delta.validate({ v = Config.Version, seq = 2, base = 1, set = { [5] = 1 }, cleared = {} }) == nil,
	"non-string key"
)
local old = { cash = 1, pets = { owned = {} } }
local good = { v = Config.Version, seq = 8, base = 7, set = { cash = 3 }, cleared = {} }
local merged, seq = Delta.apply(old, 7, Delta.validate(good))
check(merged ~= nil and merged.cash == 3 and seq == 8 and old.cash == 1, "apply → new table, old untouched")
check(merged.pets == old.pets, "untouched fields keep identity")
check(Delta.apply(old, 6, good) == nil, "wrong base refused")
local clientState = SyncClient.newState()
local resyncs = 0
local function requestResync()
	resyncs += 1
end
SyncClient.handleFull(clientState, { cash = 1, gems = 0 }, 7)
local profileOut, fieldsOut = SyncClient.handleDelta(clientState, good, 0, requestResync)
check(profileOut ~= nil and fieldsOut ~= nil and fieldsOut[1] == "cash", "handleDelta returns changed fields")
check(SyncClient.handleDelta(clientState, good, 0, requestResync) == nil and resyncs == 1, "stale delta → resync")
check(SyncClient.handleDelta(clientState, good, 1, requestResync) == nil and resyncs == 1, "resync rate-limited")

-- 4 + 5. Server state machine and partial builds over real snapshots.
local context = { saveStatus = "ok", paidRandomRestricted = false, policyKnown = true }
local profile = ProfileLogic.defaultProfile()
local state = State.new()
check(State.partialFields(state) == nil, "no partial before any push")
local plan = State.plan(state, ProfileLogic.snapshot(profile, context))
check(plan.kind == "full" and plan.reason == "notCapable", "full until the client acks")
check(not State.ack(state, 999) and State.ack(state, Config.Version), "only the exact version acks")
plan = State.plan(state, ProfileLogic.snapshot(profile, context))
check(plan.kind == "none", "after the ack the earlier full snapshot is the delta base")
ProfileLogic.addCash(profile, 10)
State.markDirty(state, { "cash", "totalEarned" })
local fields = State.partialFields(state)
check(fields ~= nil and #fields == 3, "partial = dirty + volatile")
local partial = ProfileLogic.snapshot(profile, context, fields)
plan = State.plan(state, partial)
check(plan.kind == "delta" and plan.delta.set.cash == 10 and plan.delta.set.totalEarned == 10, "cash delta")
check(plan.delta.set.saveStatus == nil, "unchanged volatile field not sent")
plan = State.plan(state, ProfileLogic.snapshot(profile, context))
check(plan.kind == "none", "nothing changed → none")
State.markDirty(state, nil)
check(State.partialFields(state) == nil, "undeclared mutation → full build")
State.requestFull(state)
State.markDirty(state, { "cash" })
check(State.partialFields(state) == nil, "requested full → full build")
plan = State.plan(state, ProfileLogic.snapshot(profile, context))
check(plan.kind == "full" and plan.reason == "requested", "requested full")

-- 6. End-to-end fuzz with dropped deltas and a sequence wrap.
local random = Loader.Random.new(20261030)
profile = ProfileLogic.defaultProfile()
state = State.new()
State.ack(state, Config.Version)
state.seq = Config.SeqModulo - 20 -- wraps during the run
clientState = SyncClient.newState()
local resyncRequested = false
local dropped, deltas, fulls = 0, 0, 0
local function deliver(snapshotForFull: any, planned: any)
	if planned.kind == "full" then
		SyncClient.handleFull(clientState, ProfileLogic.deepCopy(snapshotForFull), planned.seq)
		fulls += 1
	elseif planned.kind == "delta" then
		deltas += 1
		if random:NextNumber() < 0.03 then
			dropped += 1 -- lost on the wire
			return
		end
		SyncClient.handleDelta(clientState, ProfileLogic.deepCopy(planned.delta), os.clock() + 10 * deltas, function()
			resyncRequested = true
		end)
	end
end
for step = 1, 1500 do
	local roll = random:NextNumber()
	local declared: { string }? = nil
	if roll < 0.5 then
		ProfileLogic.addCash(profile, random:NextNumber() * 1e6)
		declared = { "cash", "totalEarned" }
	elseif roll < 0.58 then
		-- R57: a Dino producer tick (Bones), as PlayerDataService.grantCurrency declares it.
		ProfileLogic.addWorldCash(profile, "dino", random:NextNumber() * 1e5)
		declared = { "worldCash" }
	elseif roll < 0.62 then
		-- R57: a Dino pad buy (structure) — sometimes undeclared.
		local dino = ProfileLogic.worldState(profile, "dino")
		dino.unlocked = true
		dino.tycoon.pads[`d1_pad{step}`] = true
		dino.tycoon.producers[`dp{step % 5}_x`] = step
		declared = if random:NextNumber() < 0.7 then { "worlds" } else nil
	elseif roll < 0.64 then
		profile.lastWorld = if profile.lastWorld == "main" then "dino" else "main"
		declared = { "lastWorld" }
	elseif roll < 0.7 then
		if ProfileLogic.spendCash(profile, profile.cash * 0.5) then
			declared = { "cash" }
		end
	elseif roll < 0.8 then
		profile.tycoon.pads[`pad{step}`] = true
		profile.tycoon.producers[`p{step % 7}`] = step
		declared = { "tycoon" }
	elseif roll < 0.88 then
		local uid = tostring(profile.pets.nextUid)
		profile.pets.nextUid += 1
		profile.pets.owned[uid] = { id = "glow_slime" }
		if #profile.pets.equipped < 3 then
			table.insert(profile.pets.equipped, uid)
		end
		declared = if random:NextNumber() < 0.5 then { "pets" } else nil -- sometimes undeclared
	elseif roll < 0.94 then
		profile.settings.music = not profile.settings.music
		declared = { "settings" }
	else
		profile.timeRewards.claimed[random:NextInteger(1, 7)] = true
		declared = nil
	end
	State.markDirty(state, declared)
	if resyncRequested then
		resyncRequested = false
		State.requestFull(state)
	end
	local buildFields = State.partialFields(state)
	local snapshot = ProfileLogic.snapshot(profile, context, buildFields)
	deliver(snapshot, State.plan(state, snapshot))
	if dropped == 0 or clientState.seq == state.seq then
		check(
			deepEqual(clientState.profile, ProfileLogic.snapshot(profile, context)),
			`client converged at step {step}`
		)
	end
end
check(fulls >= 2 and dropped > 0, "fuzz exercised drops + resyncs")
check(state.seq < 2000, "sequence wrapped")

-- 7. Bandwidth budget (WireSize model; see ProfileSyncConfig "Bandwidth budget").
profile = ProfileLogic.defaultProfile()
ProfileLogic.addCash(profile, 448087050019.25)
state = State.new()
State.ack(state, Config.Version)
State.plan(state, ProfileLogic.snapshot(profile, context))
ProfileLogic.addCash(profile, 123456.789)
State.markDirty(state, { "cash", "totalEarned" })
local tick = ProfileLogic.snapshot(profile, context, State.partialFields(state))
plan = State.plan(state, tick)
check(plan.kind == "delta", "cash tick is a delta")
local tickBytes = WireSize.ofArgs(plan.delta)
local perSecond = tickBytes * Config.MaxPushesPerSecond
check(tickBytes <= 128, `cash tick delta {tickBytes} B exceeds 128 B`)
check(perSecond <= 512, "4 pushes/s stay within 512 B/s")
-- R57: a Bones tick is a worldCash-only delta (never the world structure), within the same budget.
ProfileLogic.addWorldCash(profile, "dino", 448087050019.25)
State.markDirty(state, { "worldCash" })
State.plan(state, ProfileLogic.snapshot(profile, context, State.partialFields(state)))
ProfileLogic.addWorldCash(profile, "dino", 98765.4321)
State.markDirty(state, { "worldCash" })
local bonesFields = State.partialFields(state)
check(bonesFields ~= nil and table.find(bonesFields, "worlds") == nil, "a Bones tick never builds the structure")
plan = State.plan(state, ProfileLogic.snapshot(profile, context, bonesFields))
check(plan.kind == "delta" and plan.delta.set.worldCash ~= nil and plan.delta.set.worlds == nil, "Bones delta")
local bonesBytes = WireSize.ofArgs(plan.delta)
check(bonesBytes <= 160, `Bones tick delta {bonesBytes} B exceeds 160 B`)
-- R70 (World 3): a registered world the player has not started adds NOTHING to a tick; each world
-- they have started adds one { cash, totalEarned } row (<= 64 B: an id of up to 16 chars + two
-- doubles), never the structure.
do
	local multi = ProfileLogic.defaultProfile()
	local multiState = State.new()
	State.ack(multiState, Config.Version)
	State.plan(multiState, ProfileLogic.snapshot(multi, context))
	local started = 0
	local previousBytes = 0
	for _, worldId in ProfileLogic.KnownWorlds do
		started += 1
		ProfileLogic.addWorldCash(multi, worldId, 448087050019.25)
		State.markDirty(multiState, { "worldCash" })
		State.plan(multiState, ProfileLogic.snapshot(multi, context, State.partialFields(multiState)))
		ProfileLogic.addWorldCash(multi, worldId, 98765.4321)
		State.markDirty(multiState, { "worldCash" })
		local tickPlan = State.plan(multiState, ProfileLogic.snapshot(multi, context, State.partialFields(multiState)))
		check(
			tickPlan.kind == "delta" and tickPlan.delta.set.worlds == nil,
			`{started}-world tick is a worldCash delta`
		)
		local bytes = WireSize.ofArgs(tickPlan.delta)
		local rows = 0
		for _ in tickPlan.delta.set.worldCash do
			rows += 1
		end
		check(rows == started, `{started} started world(s) -> {rows} worldCash rows (unstarted worlds cost 0 B)`)
		check(started == 1 or bytes - previousBytes <= 64, `world #{started} adds {bytes - previousBytes} B (<= 64)`)
		previousBytes = bytes
	end
end
-- A producer loop that pays cash AND Bones in one frame: ONE coalesced delta.
ProfileLogic.addCash(profile, 777.5)
State.markDirty(state, { "cash", "totalEarned" })
ProfileLogic.addWorldCash(profile, "dino", 333.25)
State.markDirty(state, { "worldCash" })
plan = State.plan(state, ProfileLogic.snapshot(profile, context, State.partialFields(state)))
check(
	plan.kind == "delta" and plan.delta.set.cash ~= nil and plan.delta.set.worldCash ~= nil,
	"cash + Bones coalesce into one delta"
)
local bothBytes = WireSize.ofArgs(plan.delta)
check(bothBytes <= 192, `cash + Bones tick delta {bothBytes} B exceeds 192 B`)
-- A late-game full snapshot (all pads, 200 pets) for reference.
for index = 1, 100 do
	profile.tycoon.pads[`a{index // 10 + 1}_pad{index}`] = true
end
for index = 1, 10 do
	profile.tycoon.producers[`producer{index}`] = 250
end
for index = 1, 200 do
	profile.pets.owned[tostring(index)] = { id = "fission_fox" }
end
local fullBytes = WireSize.ofArgs(ProfileLogic.snapshot(profile, context), 1)
print(
	`[profile-sync] cash tick delta ≈ {tickBytes} B → ≤ {perSecond} B/s per player at {Config.MaxPushesPerSecond}/s;`
		.. ` late-game full snapshot ≈ {fullBytes} B (join / resync only)`
)
print(`[profile-sync] Bones tick delta ≈ {bonesBytes} B; cash + Bones tick ≈ {bothBytes} B (one push)`)
print(`[profile-sync] fuzz: {deltas} deltas, {fulls} full, {dropped} dropped`)
print(`[profile-sync] {checks} checks passed`)
