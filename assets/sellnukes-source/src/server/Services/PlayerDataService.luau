--!strict
--[[
	PlayerDataService — loads, saves and syncs every player's profile; the server's single door to
	cash and gems.

	Purpose:
		- Persistence: one ProfileStore session per player on DataStore "SellNukesProfiles_v1"
		  ("SellNukesProfiles_v1_Studio" in Studio, so playtests never touch live saves). Session
		  locking (a second server never loads a profile that is open elsewhere), staggered
		  autosave (one loop for every profile, DataStore budget aware), final save + lock release
		  on leave and in BindToClose (25 s budget, parallel).
		- Studio without API access (or DataStores failing live): an in-memory "disabled" session
		  so playtests work; nothing is ever written. A live load failure tells the player their
		  progress won't save this session.
		- Profile sync to the owner (Client/ProfileSyncClient → ClientState): a FULL ProfileUpdate
		  on load / resync, DELTA pushes afterwards, coalesced to at most
		  ProfileSyncConfig.MaxPushesPerSecond (4) per player. Delta pushes build only the dirty
		  top-level fields (ProfileSyncState.partialFields), so a cash tick costs one tiny table,
		  not a deep copy of the profile. Numbers: see ProfileSyncConfig ("Bandwidth budget").
		- Currency API: grantCash / trySpendCash / grantGems / trySpendGems — the ONLY way server
		  code changes cash or gems. Every call validates the amount (finite, positive; gems whole),
		  marks exactly the touched fields dirty and fires CurrencyChanged (analytics hook).
		- World currencies (owner R57 World 2): grantCurrency / trySpendCurrency / balance take ANY
		  currency key — "cash" and "gems" delegate to the functions above, "tokens" is Nuke Town's
		  profile.rebirthTokens (so per-world code can use any def.tokens.key); a world's currency
		  ("bones") and rebirth tokens ("amber") resolve through Shared/Config/Worlds/WorldsConfig
		  (each extra world's currency.key / tokens.key) into profile.worlds.<id>. A world
		  currency change marks only { "worldCash" } (a tiny delta that coalesces with a main cash
		  tick in the same push); world tokens mark { "worlds" }. CurrencyChanged fires with the
		  key itself ("bones", "amber") exactly like every other currency. Currencies never mix:
		  a key always names one wallet.
		- PolicyService paid-random-item verdict per player (Economy/PolicyCache, fail closed),
		  in the snapshot as `policy`.

	Mutation rules for other services:
		1. Read with getProfile(player) (nil until loaded / after leave).
		2. Change the profile in place WITHOUT yielding in between.
		3. Call markChanged(player, saveSoon?, fields?) — `fields` = the top-level snapshot fields
		   you touched (e.g. { "tycoon" }, { "pets" }), so the delta push compares only those.
		   saveSoon = true for valuable one-off changes (pad buys, rebirths, claims). Private
		   fields that are not in the snapshot (analytics, offline, receipts, codes): pass {} —
		   the change is saved and nothing is sent to the client.
		canMutate(player) is the stricter gate for commerce and one-time claims: true only for a
		healthy saving session (or Studio's in-memory session). Gameplay currency calls only need
		a live session (a live in-memory fallback session can play; nothing of it is saved).

	Signals:
		ProfileLoaded(player, profile, isNew)  after load/migrate, before the first push. isNew =
		                                    nothing was stored for this player (a brand-new
		                                    profile; also true for an in-memory fallback session,
		                                    so pair it with canMutate). Also fires after every New
		                                    Player Mode swap (sandbox: isNew = true; real profile
		                                    back: false) — see getLoadReason. Handlers may read
		                                    offline.lastSeenAt (the previous save's time) and
		                                    mutate the profile (then call markChanged).
		ProfileReleasing(player, profile)   right before the final save (leave / shutdown); must
		                                    not yield. Write last-moment fields here. In New Player
		                                    Mode `profile` is the live SANDBOX (discarded; the real
		                                    one was unloaded at entry and is released as parked).
		CurrencyChanged(player, currency, delta, reason, balance)  every grant (+) / spend (-);
		                                    currency = "cash" | "gems" | a world currency / token
		                                    key ("bones", "amber").
		ProfileUnloading(player)            right BEFORE a mid-session profile swap (admin New
		                                    Player Mode enter / exit); getProfile still returns
		                                    the OLD profile. Drop per-player state derived from it
		                                    (flush into getProfile(player), never into a cached
		                                    table). Must not yield. ProfileLoaded follows with the
		                                    new profile, exactly like a join.
		NewPlayerModeChanged(player, on)    after each New Player Mode swap (true = entered).

	New Player Mode (admin "PLAY AS NEW PLAYER", B14; rules in Shared/Util/NewPlayerMode, ported
	from RoBeasts WS-H): enterNewPlayerModeAsync commits the real profile, PARKS its session
	(it keeps the lock and keeps being heartbeat-saved, nothing edits it) and swaps in a SANDBOX
	session (ProfileStore.sandboxSession: brand-new default profile, never saved). The player
	attribute `NewPlayerMode` = true mirrors the mode (analytics diverts on it; clients display
	it). exitNewPlayerMode swaps the parked real session back; leaving / shutdown just discard the
	sandbox and release the real session as usual. getLoadReason(player) tells ProfileLoaded
	handlers whether a load is a "join" or a swap ("enterNewPlayerMode" / "exitNewPlayerMode"):
	once-per-join work (offline earnings, welcome-back popups, session counts) runs on "join"
	only. In the mode canMutate stays true (claims work like a new player's, into the throwaway
	profile); services with side effects OUTSIDE the profile (global stock, server boosts, other
	DataStores) check isNewPlayerMode(player).

	Save stamping: before every write ProfileStore calls beforeSave, which sets
	`offline.lastSeenAt` and `tycoon.lastSaveAt` to the server's os.time(). Offline earnings
	(B5) therefore count from the last save, even after a server crash, and never from a client
	clock.

	Remotes: ProfileUpdate / ProfileDelta (S→C), ProfileDeltaAck / ProfileResync (C→S,
	rate-limited), Notify (S→C toast, via notify()).

	Connects to: Economy/ProfileStore, ProfileLogic, ProfileSyncState, PolicyCache;
	Shared/Config/ProfileSyncConfig, Shared/Config/Worlds/WorldsConfig (world currency keys);
	MonetizationService (getSession / getStore / canMutate /
	commit); every later gameplay service (getProfile / markChanged / currency API / signals).

	Example:
		local profile = PlayerDataService.waitForProfile(player)
		if profile ~= nil and PlayerDataService.trySpendCash(player, 500, "padBuy") then
			profile.tycoon.pads["a1_toolwall"] = true
			PlayerDataService.markChanged(player, true, { "tycoon" })
		end
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local PolicyService = game:GetService("PolicyService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PolicyCache = require(script.Parent.Parent.Economy.PolicyCache)
local ProfileLogic = require(script.Parent.Parent.Economy.ProfileLogic)
local ProfileStore = require(script.Parent.Parent.Economy.ProfileStore)
local ProfileSyncConfig = require(ReplicatedStorage.Shared.Config.ProfileSyncConfig)
local ProfileSyncState = require(script.Parent.Parent.Economy.ProfileSyncState)
local NewPlayerMode = require(ReplicatedStorage.Shared.Util.NewPlayerMode)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

type Profile = ProfileLogic.Profile
type Session = ProfileStore.Session

-- A currency key: "cash" | "gems" | a world currency ("bones") | a world's tokens ("amber").
export type Currency = string
-- Why ProfileLoaded fired (getLoadReason): a join, or a New Player Mode swap.
export type LoadReason = "join" | "enterNewPlayerMode" | "exitNewPlayerMode"
-- Toast styles the client's Notify widget knows.
export type NotifyKind = "info" | "success" | "error" | "reward"

local PlayerDataService = {}

PlayerDataService.ProfileLoaded = Signal.new() :: Signal.Signal<Player, Profile, boolean>
PlayerDataService.ProfileReleasing = Signal.new() :: Signal.Signal<Player, Profile>
PlayerDataService.CurrencyChanged = Signal.new() :: Signal.Signal<Player, Currency, number, string, number>
-- New Player Mode swap lifecycle (see the header): before every swap / after every swap.
PlayerDataService.ProfileUnloading = Signal.new() :: Signal.Signal<Player>
PlayerDataService.NewPlayerModeChanged = Signal.new() :: Signal.Signal<Player, boolean>

local DATASTORE_NAME = "SellNukesProfiles_v1"
local STUDIO_SUFFIX = "_Studio"
-- A fast rejoin to the same server waits this long for the previous session's release save.
local LOCAL_RELEASE_WAIT_SECONDS = 30
-- Autosave leaves this many UpdateAsync requests in the budget for joins / leaves / receipts.
local AUTOSAVE_BUDGET_RESERVE = 10
-- BindToClose budget for the parallel release saves (Roblox gives 30 s in total).
local SHUTDOWN_BUDGET_SECONDS = 25
-- Studio sessions crash / stop often: their locks go stale after 60 s instead of 10 min.
local STUDIO_LOCK_STALE_SECONDS = 60
-- Default waitForProfile timeout.
local DEFAULT_WAIT_SECONDS = 30
-- Currency `reason` labels: [%w_-] only, at most this long (analytics key safety).
local MAX_REASON_LENGTH = 32
-- PolicyService lookups (paid random items): tries, retry cooldown, max wait for resolveAsync.
local POLICY_ATTEMPTS = 3
local POLICY_RETRY_COOLDOWN = 30
local POLICY_TIMEOUT = 10

local LOCKED_KICK_MESSAGE = "Your save is still open on another server. Please rejoin in a minute!"
local LOAD_FAILED_MESSAGE = "We couldn't load your save, so progress this session won't be saved. Rejoin to try again."
local READ_ONLY_MESSAGE =
	"This server is running an older version: progress here won't be saved. Rejoin for the update!"

-- Snapshot fields touched by each currency (delta sync declares exactly these).
local CASH_GRANT_FIELDS = table.freeze({ "cash", "totalEarned" })
local CASH_SPEND_FIELDS = table.freeze({ "cash" })
local GEM_FIELDS = table.freeze({ "gems" })
-- R57: a world currency change touches only the small worldCash field; world tokens live in the
-- `worlds` structure field.
local WORLD_CASH_FIELDS = table.freeze({ "worldCash" })
local WORLD_TOKEN_FIELDS = table.freeze({ "worlds" })
-- Nuke Town's rebirth tokens (WorldsConfig main tokens.key "tokens") live at profile.rebirthTokens.
local MAIN_TOKEN_FIELDS = table.freeze({ "rebirthTokens" })
-- The main wallets (cash, gems, Nuke Town tokens): no world currency key may shadow one.
local MAIN_WALLETS: { [string]: boolean } = { cash = true, gems = true }
local MAIN_TOKENS = (WorldsConfig.get(WorldsConfig.MAIN) :: WorldsConfig.WorldDef).tokens.key
MAIN_WALLETS[MAIN_TOKENS] = true

--[[
	R57: where each world currency key lives, built once from the worlds registry: an extra world's
	currency.key → { world, kind = "cash" } (profile.worlds.<id>.cash) and its tokens.key →
	{ world, kind = "tokens" } (profile.worlds.<id>.rebirthTokens). The main wallets ("cash",
	"gems", Nuke Town's tokens key "tokens") can never be shadowed (a collision fails at boot).
	Example: WORLD_CURRENCIES.bones --> { world = "dino", kind = "cash" }
]]
type CurrencyRoute = { world: string, kind: "cash" | "tokens" }
local WORLD_CURRENCIES: { [string]: CurrencyRoute } = {}
local function addCurrencyRoute(key: string, worldId: string, kind: "cash" | "tokens")
	if MAIN_WALLETS[key] or WORLD_CURRENCIES[key] ~= nil then
		error(`[PlayerDataService] world currency key {key} of {worldId} collides with another wallet`)
	end
	WORLD_CURRENCIES[key] = { world = worldId, kind = kind } -- module-private (the map is frozen below)
end
for _, def in WorldsConfig.extra() do
	addCurrencyRoute(def.currency.key, def.id, "cash")
	addCurrencyRoute(def.tokens.key, def.id, "tokens")
end
table.freeze(WORLD_CURRENCIES)
-- Unknown currency keys already warned about (once each; a programming error, never player input).
-- Bounded, so even a buggy caller passing arbitrary strings can never grow it without limit.
local warnedCurrencies: { [string]: boolean } = {}
local warnedCount = 0
local MAX_WARNED_CURRENCIES = 32

local store: ProfileStore.ProfileStore? = nil
local savingEnabled = false
local storeReady = false
local StoreReady = Signal.new() :: Signal.Signal<>
local shuttingDown = false
-- Callbacks run once at the start of BindToClose, before any profile is released.
local beforeClose: { () -> () } = {}

local sessions: { [Player]: Session } = {}
-- UserIds whose release save is in progress on THIS server (a fast rejoin waits for it).
local releasing: { [number]: boolean } = {}
-- Profile opens in flight (onClose waits for them so a lock taken while closing is released).
local opensInFlight = 0
-- Why each player's current profile was announced (getLoadReason). Cleared on leave.
local loadReasons: { [Player]: LoadReason } = {}

-- New Player Mode: while an admin plays as a brand-new player, sessions[player] holds a SANDBOX
-- session (never saved) and the REAL session is parked here, untouched (its profile replaced by
-- a deep copy at entry so no stale reference can edit what gets saved). Strong keys, cleared on
-- leave / shutdown.
type NewPlayerModeState = {
	real: Session, -- the parked real session (keeps the lock; heartbeat-saved by autosave)
	enteredAt: number, -- os.time() the mode started (diagnostics / audit)
}
local newPlayerModes: { [Player]: NewPlayerModeState } = {}
-- Players whose enter / exit is in progress (the enter commit yields): one switch at a time.
local modeBusy: { [Player]: boolean } = {}

-- Delta profile sync: per-player push state, coalescing bookkeeping and the C→S rate limits.
local profileSync = {
	states = {} :: { [Player]: ProfileSyncState.State },
	scheduled = {} :: { [Player]: boolean },
	lastPushAt = {} :: { [Player]: number },
	enabled = true, -- false only for Studio A/B measurements (setDeltaSyncForTests)
	pushes = 0, -- pushes built since server start (diagnostics)
	fullPushes = 0,
	deltaPushes = 0,
	pushSeconds = 0, -- os.clock() seconds spent building + planning + firing pushes
	ack = RateLimiter.new(ProfileSyncConfig.AckLimit.Burst, ProfileSyncConfig.AckLimit.PerSecond),
	resync = RateLimiter.new(ProfileSyncConfig.ResyncLimit.Burst, ProfileSyncConfig.ResyncLimit.PerSecond),
}

-- The player's sync state, created on first use (an ack may arrive before the profile loads).
local function syncStateOf(player: Player): ProfileSyncState.State
	local state = profileSync.states[player]
	if state == nil then
		state = ProfileSyncState.new()
		profileSync.states[player] = state
	end
	return state
end

-- Forward declaration: pushes are scheduled from the policy cache's change callback.
local schedulePush: (player: Player, fields: { string }?) -> ()

-- Paid-random-item policy per player (PolicyService, fail closed; see Economy/PolicyCache).
local policy = PolicyCache.new({
	fetch = function(player: Player): unknown
		return PolicyService:GetPolicyInfoForPlayerAsync(player)
	end,
	attempts = POLICY_ATTEMPTS,
	retryCooldown = POLICY_RETRY_COOLDOWN,
	timeout = POLICY_TIMEOUT,
	onChanged = function(player: Player)
		if player.Parent == Players and sessions[player] ~= nil then
			schedulePush(player, { "policy" })
		end
	end,
})

--------------------------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------------------------

--[[
	Sends a toast to one player (no-op for players who left). Payload { kind, text, icon? } (build
	plan "Notify").
	Example: PlayerDataService.notify(player, "Saved!", "success")
]]
function PlayerDataService.notify(player: Player, text: string, kind: NotifyKind, icon: string?)
	if player.Parent == Players then
		Remotes.fireClient("Notify", player, { kind = kind, text = text, icon = icon })
	end
end

-- A session that may change (loaded, not released, player still here).
local function liveSession(player: Player): Session?
	local session = sessions[player]
	if session == nil or session.released or player.Parent ~= Players then
		return nil
	end
	return session
end

-- A currency reason as a safe analytics label ([%w_-], ≤ MAX_REASON_LENGTH), else "other".
local function cleanReason(reason: unknown): string
	if
		type(reason) == "string"
		and #reason >= 1
		and #reason <= MAX_REASON_LENGTH
		and string.find(reason, "^[%w_%-]+$")
	then
		return reason
	end
	return "other"
end

-- The server-decided context for the owner's snapshot.
local function snapshotContext(player: Player, session: Session): ProfileLogic.SnapshotContext
	return {
		saveStatus = session.status,
		paidRandomRestricted = policy:isRestricted(player),
		policyKnown = policy:isKnown(player),
	}
end

-- Sends the owner their profile: a full snapshot or only the changed fields (never receipts).
local function pushNow(player: Player)
	profileSync.scheduled[player] = nil
	local session = sessions[player]
	if session == nil or player.Parent ~= Players then
		return
	end
	local started = os.clock()
	profileSync.lastPushAt[player] = started
	local sync = syncStateOf(player)
	if not (ProfileSyncConfig.Enabled and profileSync.enabled) then
		-- Kill switch (ProfileSyncConfig.Enabled) or a Studio A/B: full every push.
		ProfileSyncState.requestFull(sync)
	end
	-- Partial build when the push can only be a dirty-fields delta; nil = build everything.
	local fields = ProfileSyncState.partialFields(sync)
	local snapshot = ProfileLogic.snapshot(session.profile, snapshotContext(player, session), fields)
	local plan = ProfileSyncState.plan(sync, snapshot)
	if plan.kind == "full" then
		Remotes.fireClient("ProfileUpdate", player, snapshot, plan.seq)
		profileSync.fullPushes += 1
	elseif plan.kind == "delta" then
		Remotes.fireClient("ProfileDelta", player, plan.delta)
		profileSync.deltaPushes += 1
	end
	profileSync.pushes += 1
	profileSync.pushSeconds += os.clock() - started
end

--[[
	Schedules one coalesced push. The first change after a quiet period goes out on the next
	resumption cycle (task.defer: every mutation of the same frame rides along); changes inside
	the MinPushInterval window wait for the trailing push. Result: at most MaxPushesPerSecond
	pushes per player, and a single click still feels instant.
]]
schedulePush = function(player: Player, fields: { string }?)
	ProfileSyncState.markDirty(syncStateOf(player), fields)
	if profileSync.scheduled[player] then
		return
	end
	profileSync.scheduled[player] = true
	local last = profileSync.lastPushAt[player]
	local wait = if last ~= nil then last + ProfileSyncConfig.MinPushInterval - os.clock() else 0
	if wait > 0 then
		task.delay(wait, pushNow, player)
	else
		task.defer(pushNow, player)
	end
end

--------------------------------------------------------------------------------------------------
-- Public API: sessions and profiles
--------------------------------------------------------------------------------------------------

--[[ The player's ProfileStore session (nil until loaded / after leaving). ]]
function PlayerDataService.getSession(player: Player): Session?
	return sessions[player]
end

--[[
	True when commerce / one-time claims may change this profile: a healthy saving session, or
	Studio's explicit in-memory session (DataStores off). False for live in-memory fallbacks,
	read-only (newer version) and lost sessions — their changes could never be saved, so nothing
	permanent (a code, a daily claim, a receipt) may be granted into them.
]]
function PlayerDataService.canMutate(player: Player): boolean
	local session = sessions[player]
	return session ~= nil
		and not session.released
		and (session.status == "ok" or (RunService:IsStudio() and not savingEnabled and session.status == "disabled"))
end

--[[ The ProfileStore (nil before Start). MonetizationService commits receipts through it. ]]
function PlayerDataService.getStore(): ProfileStore.ProfileStore?
	return store
end

--[[ True when profiles are being persisted (false = in-memory fallback for this server). ]]
function PlayerDataService.isSavingEnabled(): boolean
	return savingEnabled
end

--[[ The player's live profile, or nil until it has loaded (and after they leave). ]]
function PlayerDataService.getProfile(player: Player): Profile?
	local session = sessions[player]
	return if session ~= nil then session.profile else nil
end

--[[
	Yields until the player's profile is loaded, they leave, or `timeout` seconds pass.
	@param timeout seconds (default 30)
	@return the profile, or nil on timeout / leave
	Example: local profile = PlayerDataService.waitForProfile(player, 10)
]]
function PlayerDataService.waitForProfile(player: Player, timeout: number?): Profile?
	local existing = PlayerDataService.getProfile(player)
	if existing ~= nil or player.Parent ~= Players then
		return existing
	end
	local thread = coroutine.running()
	local finished = false
	local loadedConnection: Signal.Connection
	local leftConnection: RBXScriptConnection
	local timer: thread
	local function finish(profile: Profile?)
		if finished then
			return
		end
		finished = true
		loadedConnection:Disconnect()
		leftConnection:Disconnect()
		if coroutine.running() ~= timer then
			task.cancel(timer)
		end
		task.spawn(thread, profile)
	end
	loadedConnection = PlayerDataService.ProfileLoaded:Connect(function(loadedPlayer: Player, profile: Profile)
		if loadedPlayer == player then
			finish(profile)
		end
	end)
	leftConnection = Players.PlayerRemoving:Connect(function(leaving: Player)
		if leaving == player then
			finish(nil)
		end
	end)
	timer = task.delay(timeout or DEFAULT_WAIT_SECONDS, function()
		finish(nil)
	end)
	return coroutine.yield()
end

--[[
	Records an in-memory change: bumps the session's change version (for commitAsync) and
	schedules a coalesced push. `saveSoon` asks the autosave loop to write within seconds
	(purchases, pad buys, claims); otherwise the next regular autosave (≤ 2 min) picks it up.
	`fields` names the top-level snapshot fields the change touched (delta sync compares only
	those + ProfileSyncConfig.VolatileFields); nil when unsure (every field is compared).
	@return the new change version (for ProfileStore.commitAsync), or nil if not loaded
	Example: PlayerDataService.markChanged(player, true, { "tycoon", "stats" })
]]
function PlayerDataService.markChanged(player: Player, saveSoon: boolean?, fields: { string }?): number?
	local session = sessions[player]
	local s = store
	if session == nil or s == nil or session.released then
		return nil
	end
	local version = s:markDirty(session)
	if saveSoon then
		s:requestSaveSoon(session)
	end
	schedulePush(player, fields)
	return version
end

--[[
	Re-sends the profile without dirtying it (e.g. after a refused client intent, so an
	optimistic UI snaps back). `fields` as in markChanged.
]]
function PlayerDataService.refresh(player: Player, fields: { string }?)
	if sessions[player] ~= nil then
		schedulePush(player, fields)
	end
end

--------------------------------------------------------------------------------------------------
-- Public API: currency
--------------------------------------------------------------------------------------------------

--[[
	Grants cash (finite, > 0). Also adds it to totalEarned (lifetime cash). Gameplay call: works
	for any live session.
	@param reason short analytics label, [%w_-] ≤ 32 chars (e.g. "producer", "offline", "code")
	@return the cash actually added (0 = not loaded / invalid amount / balance at the cap)
	Example: PlayerDataService.grantCash(player, 125, "producer")
]]
function PlayerDataService.grantCash(player: Player, value: number, reason: string): number
	local session = liveSession(player)
	if session == nil then
		return 0
	end
	local added = ProfileLogic.addCash(session.profile, value)
	if added <= 0 then
		return 0
	end
	PlayerDataService.markChanged(player, false, CASH_GRANT_FIELDS)
	PlayerDataService.CurrencyChanged:Fire(player, "cash", added, cleanReason(reason), session.profile.cash)
	return added
end

--[[
	Spends cash atomically (only when the balance covers it).
	@return true when spent
	Example: if PlayerDataService.trySpendCash(player, cost, "padBuy") then ... end
]]
function PlayerDataService.trySpendCash(player: Player, value: number, reason: string): boolean
	local session = liveSession(player)
	if session == nil or not ProfileLogic.spendCash(session.profile, value) then
		return false
	end
	PlayerDataService.markChanged(player, false, CASH_SPEND_FIELDS)
	PlayerDataService.CurrencyChanged:Fire(player, "cash", -value, cleanReason(reason), session.profile.cash)
	return true
end

--[[
	Grants whole gems (> 0).
	@return gems actually added (0 = not loaded / invalid amount)
	Example: PlayerDataService.grantGems(player, 25, "daily")
]]
function PlayerDataService.grantGems(player: Player, value: number, reason: string): number
	local session = liveSession(player)
	if session == nil then
		return 0
	end
	local added = ProfileLogic.addGems(session.profile, value)
	if added <= 0 then
		return 0
	end
	PlayerDataService.markChanged(player, false, GEM_FIELDS)
	PlayerDataService.CurrencyChanged:Fire(player, "gems", added, cleanReason(reason), session.profile.gems)
	return added
end

--[[
	Spends whole gems atomically.
	@return true when spent
]]
function PlayerDataService.trySpendGems(player: Player, value: number, reason: string): boolean
	local session = liveSession(player)
	if session == nil or not ProfileLogic.spendGems(session.profile, value) then
		return false
	end
	PlayerDataService.markChanged(player, false, GEM_FIELDS)
	PlayerDataService.CurrencyChanged:Fire(player, "gems", -value, cleanReason(reason), session.profile.gems)
	return true
end

--[[
	R57: Nuke Town's rebirth tokens through the generic API (key "tokens"), so per-world code can
	pay any world's def.tokens.key without a special case. Whole numbers, clamped to MaxCounter;
	marks { "rebirthTokens" } and fires CurrencyChanged("tokens", ...).
	@return tokens added (grant, ≥ 0) / whether spent (spend)
]]
local function grantMainTokens(player: Player, value: number, reason: string): number
	local session = liveSession(player)
	if session == nil or not ProfileLogic.isFinite(value) or value <= 0 or value % 1 ~= 0 then
		return 0
	end
	local profile = session.profile
	local before = profile.rebirthTokens
	profile.rebirthTokens = math.min(before + value, ProfileLogic.Limits.MaxCounter)
	local added = profile.rebirthTokens - before
	if added <= 0 then
		return 0
	end
	PlayerDataService.markChanged(player, false, MAIN_TOKEN_FIELDS)
	PlayerDataService.CurrencyChanged:Fire(player, MAIN_TOKENS, added, cleanReason(reason), profile.rebirthTokens)
	return added
end

local function trySpendMainTokens(player: Player, value: number, reason: string): boolean
	local session = liveSession(player)
	if session == nil or not ProfileLogic.isFinite(value) or value <= 0 or value % 1 ~= 0 then
		return false
	end
	local profile = session.profile
	if profile.rebirthTokens < value then
		return false
	end
	profile.rebirthTokens -= value
	PlayerDataService.markChanged(player, false, MAIN_TOKEN_FIELDS)
	PlayerDataService.CurrencyChanged:Fire(player, MAIN_TOKENS, -value, cleanReason(reason), profile.rebirthTokens)
	return true
end

-- The route of a world currency key, or nil (warned once per unknown key: a programming error).
local function routeOf(currency: string): CurrencyRoute?
	local route = WORLD_CURRENCIES[currency]
	if route == nil and not warnedCurrencies[currency] and warnedCount < MAX_WARNED_CURRENCIES then
		warnedCurrencies[currency] = true
		warnedCount += 1
		warn(`[PlayerDataService] unknown currency key {string.sub(tostring(currency), 1, 32)}`)
	end
	return route
end

--[[
	R57: grants whole rebirth tokens of a non-main world (Dino Valley: Amber) into
	profile.worlds.<worldId>.rebirthTokens. Marks { "worlds" } and fires CurrencyChanged with the
	world's tokens key ("amber").
	@return tokens actually added (0 = not loaded / unknown world / invalid amount)
	Example: PlayerDataService.grantWorldTokens(player, "dino", 12)
]]
function PlayerDataService.grantWorldTokens(player: Player, worldId: string, value: number, reason: string?): number
	local session = liveSession(player)
	local def = WorldsConfig.get(worldId)
	if session == nil or def == nil or def.id == WorldsConfig.MAIN then
		return 0
	end
	local added = ProfileLogic.addWorldTokens(session.profile, def.id, value)
	if added <= 0 then
		return 0
	end
	local world = ProfileLogic.worldState(session.profile, def.id)
	PlayerDataService.markChanged(player, false, WORLD_TOKEN_FIELDS)
	PlayerDataService.CurrencyChanged:Fire(
		player,
		def.tokens.key,
		added,
		cleanReason(reason or "rebirth"),
		world.rebirthTokens
	)
	return added
end

--[[
	R57: spends whole rebirth tokens of a non-main world atomically (e.g. the Amber shop).
	@return true when spent
	Example: if PlayerDataService.trySpendWorldTokens(player, "dino", cost) then ... end
]]
function PlayerDataService.trySpendWorldTokens(player: Player, worldId: string, value: number, reason: string?): boolean
	local session = liveSession(player)
	local def = WorldsConfig.get(worldId)
	if session == nil or def == nil or def.id == WorldsConfig.MAIN then
		return false
	end
	if not ProfileLogic.spendWorldTokens(session.profile, def.id, value) then
		return false
	end
	local world = ProfileLogic.worldState(session.profile, def.id)
	PlayerDataService.markChanged(player, false, WORLD_TOKEN_FIELDS)
	PlayerDataService.CurrencyChanged:Fire(
		player,
		def.tokens.key,
		-value,
		cleanReason(reason or "rebirthShop"),
		world.rebirthTokens
	)
	return true
end

--[[
	R57: grants any currency by key. "cash" / "gems" delegate to grantCash / grantGems; "tokens"
	(Nuke Town's rebirth tokens) goes to profile.rebirthTokens; a world currency ("bones") goes to
	that world's wallet (+ its totalEarned, clamped to MaxCash) and marks only { "worldCash" }; a
	world's tokens key ("amber") delegates to grantWorldTokens.
	Gameplay call: works for any live session (like grantCash).
	@param reason short analytics label, [%w_-] ≤ 32 chars
	@return the amount actually added (0 = not loaded / unknown key / invalid amount / at the cap)
	Example: PlayerDataService.grantCurrency(player, "bones", 125, "producer")
]]
function PlayerDataService.grantCurrency(player: Player, currency: string, value: number, reason: string): number
	if currency == "cash" then
		return PlayerDataService.grantCash(player, value, reason)
	elseif currency == "gems" then
		return PlayerDataService.grantGems(player, value, reason)
	elseif currency == MAIN_TOKENS then
		return grantMainTokens(player, value, reason)
	end
	local route = routeOf(currency)
	if route == nil then
		return 0
	elseif route.kind == "tokens" then
		return PlayerDataService.grantWorldTokens(player, route.world, value, reason)
	end
	local session = liveSession(player)
	if session == nil then
		return 0
	end
	local added = ProfileLogic.addWorldCash(session.profile, route.world, value)
	if added <= 0 then
		return 0
	end
	local world = ProfileLogic.worldState(session.profile, route.world)
	PlayerDataService.markChanged(player, false, WORLD_CASH_FIELDS)
	PlayerDataService.CurrencyChanged:Fire(player, currency, added, cleanReason(reason), world.cash)
	return added
end

--[[
	R57: spends any currency by key, atomically from that currency's own wallet only ("bones"
	can never pay a cash price). "cash" / "gems" delegate to trySpendCash / trySpendGems; a
	world's tokens key delegates to trySpendWorldTokens.
	@return true when spent
	Example: if PlayerDataService.trySpendCurrency(player, "bones", price, "padBuy") then ... end
]]
function PlayerDataService.trySpendCurrency(player: Player, currency: string, value: number, reason: string): boolean
	if currency == "cash" then
		return PlayerDataService.trySpendCash(player, value, reason)
	elseif currency == "gems" then
		return PlayerDataService.trySpendGems(player, value, reason)
	elseif currency == MAIN_TOKENS then
		return trySpendMainTokens(player, value, reason)
	end
	local route = routeOf(currency)
	if route == nil then
		return false
	elseif route.kind == "tokens" then
		return PlayerDataService.trySpendWorldTokens(player, route.world, value, reason)
	end
	local session = liveSession(player)
	if session == nil or not ProfileLogic.spendWorldCash(session.profile, route.world, value) then
		return false
	end
	local world = ProfileLogic.worldState(session.profile, route.world)
	PlayerDataService.markChanged(player, false, WORLD_CASH_FIELDS)
	PlayerDataService.CurrencyChanged:Fire(player, currency, -value, cleanReason(reason), world.cash)
	return true
end

--[[
	R57: a profile's balance of any currency key (0 for an unknown key or a missing world). Pure
	read: never creates a world entry. Takes the profile (not the player) so callers that already
	hold it (prompt checks, offline, admin) don't look it up twice.
	Example: PlayerDataService.balance(profile, "bones") --> profile.worlds.dino.cash
]]
function PlayerDataService.balance(profile: Profile, currency: string): number
	if currency == "cash" then
		return profile.cash
	elseif currency == "gems" then
		return profile.gems
	elseif currency == MAIN_TOKENS then
		return profile.rebirthTokens
	end
	local route = WORLD_CURRENCIES[currency]
	local world = if route ~= nil then ProfileLogic.peekWorld(profile, route.world) else nil
	if route == nil or world == nil then
		return 0
	end
	return if route.kind == "cash" then world.cash else world.rebirthTokens
end

--------------------------------------------------------------------------------------------------
-- Public API: paid random items policy
--------------------------------------------------------------------------------------------------

--[[
	True when the player may NOT buy paid random items (Robux → random reward, e.g. Lucky Spins),
	or when PolicyService has not answered yet (fail closed). Never yields.
]]
function PlayerDataService.isPaidRandomRestricted(player: Player): boolean
	return policy:isRestricted(player)
end

--[[ True once PolicyService answered for this player. ]]
function PlayerDataService.isPolicyKnown(player: Player): boolean
	return policy:isKnown(player)
end

--[[
	Waits (≤ 10 s) for a lookup in flight / retries a failed one, then answers like
	isPaidRandomRestricted. Use right before refusing a paid random purchase.
]]
function PlayerDataService.resolvePaidRandomAsync(player: Player): boolean
	return policy:resolveAsync(player)
end

--[[ Studio tests: force the policy answer for a player (nil clears the override). ]]
function PlayerDataService.setPolicyOverride(player: Player, restricted: boolean?)
	if RunService:IsStudio() then
		policy:setOverride(player, restricted)
	end
end

--------------------------------------------------------------------------------------------------
-- Diagnostics (Studio tests / admin Live tab)
--------------------------------------------------------------------------------------------------

--[[ Delta sync state of a player: whether the client acked deltas and the last pushed sequence. ]]
function PlayerDataService.profileSyncInfo(player: Player): { capable: boolean, seq: number }?
	local state = profileSync.states[player]
	return if state ~= nil then { capable = state.capable, seq = state.seq } else nil
end

--[[ Server-wide push counters since start (pushes, full, delta, seconds spent building them). ]]
function PlayerDataService.profilePushStats(): { pushes: number, full: number, delta: number, seconds: number }
	return {
		pushes = profileSync.pushes,
		full = profileSync.fullPushes,
		delta = profileSync.deltaPushes,
		seconds = profileSync.pushSeconds,
	}
end

--[[ Studio-only A/B switch: false sends a full snapshot on every push. Ignored outside Studio. ]]
function PlayerDataService.setDeltaSyncForTests(enabled: boolean)
	if RunService:IsStudio() then
		profileSync.enabled = enabled
	end
end

--------------------------------------------------------------------------------------------------
-- Load / release
--------------------------------------------------------------------------------------------------

-- Yields until initStoreAsync has decided whether saving works.
local function waitForStore(): ProfileStore.ProfileStore
	if not storeReady then
		StoreReady:Wait()
	end
	local s = store
	assert(s ~= nil, "ProfileStore exists once ready")
	return s
end

-- Final save + lock release for a session (never throws).
local function releaseSession(session: Session)
	local s = store
	if s == nil then
		return
	end
	releasing[session.userId] = true
	local ok, err = pcall(function()
		s:saveAsync(session, true)
	end)
	if not ok then
		warn(`[PlayerDataService] release of {session.key} errored: {err}`)
	end
	releasing[session.userId] = nil
end

-- Loads (or falls back) a player's profile and announces it.
local function loadPlayerAsync(player: Player)
	local s = waitForStore()
	local userId = player.UserId

	-- A fast rejoin to this same server must wait for the previous session's final save.
	local waited = 0
	while releasing[userId] and waited < LOCAL_RELEASE_WAIT_SECONDS do
		waited += task.wait(0.25)
	end
	if player.Parent ~= Players or shuttingDown then
		return
	end

	local session: Session
	local loadFailed = false
	if savingEnabled then
		-- Retries stop as soon as the player leaves or the server starts closing: no new lock is
		-- taken that nobody would release.
		opensInFlight += 1
		local opened, err = s:openAsync(userId, function(): boolean
			return shuttingDown or player.Parent ~= Players
		end)
		opensInFlight -= 1
		if opened ~= nil then
			session = opened
		elseif err == "cancelled" then
			return -- left / closing before a lock was taken: nothing to release
		elseif err == "locked" then
			if player.Parent == Players then
				player:Kick(LOCKED_KICK_MESSAGE)
			end
			return
		else
			warn(`[PlayerDataService] profile load failed for {userId}; using unsaved defaults`)
			session = s:memorySession(userId)
			loadFailed = true
		end
	else
		session = s:memorySession(userId)
	end

	-- Left (or the server began closing) while we were loading: give the lock back.
	if player.Parent ~= Players or shuttingDown then
		if session.status == "ok" or session.status == "readOnly" then
			releaseSession(session)
		end
		return
	end

	sessions[player] = session
	loadReasons[player] = "join"
	PlayerDataService.ProfileLoaded:Fire(player, session.profile, session.migration == "new")
	pushNow(player)
	if loadFailed then
		PlayerDataService.notify(player, LOAD_FAILED_MESSAGE, "error")
	elseif session.status == "readOnly" then
		PlayerDataService.notify(player, READ_ONLY_MESSAGE, "error")
	end
end

local function onPlayerAdded(player: Player)
	-- Ask PolicyService early so the shop knows the answer by the time it is opened.
	policy:prefetch(player)
	task.spawn(loadPlayerAsync, player)
end

local function onPlayerRemoving(player: Player)
	local session = sessions[player]
	if session ~= nil and not session.released then
		-- Last-moment writes (lastSeenAt, session stats) land in the final save below. In New
		-- Player Mode this is the live SANDBOX profile (discarded); the real one was unloaded at
		-- entry (ProfileUnloading) and is parked untouched.
		PlayerDataService.ProfileReleasing:Fire(player, session.profile)
	end
	sessions[player] = nil
	loadReasons[player] = nil
	-- Leaving ends New Player Mode: the sandbox is only marked released (it is never written, and
	-- never goes through releaseSession, whose `releasing[userId]` bookkeeping belongs to the
	-- real write), and the PARKED real session gets the normal final save + lock release below.
	local mode = newPlayerModes[player]
	newPlayerModes[player] = nil
	modeBusy[player] = nil
	if mode ~= nil then
		if session ~= nil and session.sandbox then
			session.released = true
		end
		session = mode.real
	end
	profileSync.states[player] = nil
	profileSync.scheduled[player] = nil
	profileSync.lastPushAt[player] = nil
	profileSync.ack:Forget(player)
	profileSync.resync:Forget(player)
	policy:forget(player)
	if session ~= nil then
		task.spawn(releaseSession, session)
	end
end

--------------------------------------------------------------------------------------------------
-- Store setup, autosave, shutdown
--------------------------------------------------------------------------------------------------

-- Stamps the server's clock into the profile right before every write (see the header).
local function stampBeforeSave(session: Session)
	local now = os.time()
	session.profile.offline.lastSeenAt = now
	session.profile.tycoon.lastSaveAt = now
end

-- Creates the ProfileStore and decides whether saving is possible (yields: Studio probe).
local function initStoreAsync()
	local isStudio = RunService:IsStudio()
	local name = if isStudio then DATASTORE_NAME .. STUDIO_SUFFIX else DATASTORE_NAME
	local jobId = if game.JobId ~= "" then game.JobId else `studio-{HttpService:GenerateGUID(false)}`
	local timing = ProfileStore.defaultTiming()
	if isStudio then
		timing.lockStaleSeconds = STUDIO_LOCK_STALE_SECONDS
	end
	local options: ProfileStore.Options =
		{ jobId = jobId, placeId = game.PlaceId, timing = timing, beforeSave = stampBeforeSave }

	local ok, dataStore = pcall(function()
		return DataStoreService:GetDataStore(name)
	end)
	if ok then
		-- In Studio, DataStores only work with "Studio Access to API Services" on: probe once.
		local usable = true
		if isStudio then
			local probeOk, probeErr = pcall(function()
				return dataStore:GetAsync("__probe")
			end)
			if not probeOk then
				usable = false
				warn(
					`[PlayerDataService] DataStores unavailable in Studio ({probeErr}). Profiles are in-memory`
						.. " defaults and will NOT be saved (enable Game Settings > Security > Studio Access to"
						.. " API Services to test saving)."
				)
			end
		end
		store = ProfileStore.new(dataStore, options)
		savingEnabled = usable
	else
		warn(`[PlayerDataService] GetDataStore failed ({dataStore}); profiles will NOT be saved this server`)
		store = ProfileStore.new({}, options)
		savingEnabled = false
	end
	storeReady = true
	StoreReady:Fire()
end

-- UpdateAsync requests available right now (math.huge if the budget API is unavailable).
local function updateBudget(): number
	local ok, budget = pcall(function()
		return DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync)
	end)
	return if ok and type(budget) == "number" then budget else math.huge
end

-- One loop for every profile: saves sessions whose staggered autosave time has come.
local function autosaveLoop()
	while not shuttingDown do
		task.wait(1)
		local s = store
		if s == nil or not savingEnabled then
			continue
		end
		local budget: number? = nil
		for _, session in sessions do
			if not s:isAutosaveDue(session) then
				continue
			end
			budget = budget or updateBudget()
			if (budget :: number) <= AUTOSAVE_BUDGET_RESERVE then
				break -- try again next tick; joins / leaves / receipts keep priority
			end
			budget = (budget :: number) - 1
			task.spawn(function()
				s:saveAsync(session, false)
			end)
		end
		-- Parked real sessions (New Player Mode) keep their lock heartbeat: the regular autosave
		-- writes their untouched copy. Sandboxes are never due (ProfileStore.isAutosaveDue).
		for _, mode in newPlayerModes do
			local real = mode.real
			if not s:isAutosaveDue(real) then
				continue
			end
			budget = budget or updateBudget()
			if (budget :: number) <= AUTOSAVE_BUDGET_RESERVE then
				break
			end
			budget = (budget :: number) - 1
			task.spawn(function()
				s:saveAsync(real, false)
			end)
		end
	end
end

--[[
	Registers a callback that runs ONCE at server shutdown, before any profile is released, so its
	profile edits are part of the final save. Callbacks should not yield (each runs in its own
	task.spawn, pcall'd, so a fault can never stall or break the shutdown save).
	Example: PlayerDataService.onBeforeClose(function() BoostService.flushAll() end)
]]
function PlayerDataService.onBeforeClose(callback: () -> ())
	table.insert(beforeClose, callback)
end

-- Runs one before-close callback; a fault is logged, never propagated into the shutdown save.
local function runBeforeClose(callback: () -> ())
	local ok, err = pcall(callback)
	if not ok then
		warn(`[PlayerDataService] before-close callback failed: {err}`)
	end
end

-- Saves and releases every profile in parallel within the BindToClose budget.
local function onClose()
	local callbacks = beforeClose
	beforeClose = {}
	for _, callback in callbacks do
		task.spawn(runBeforeClose, callback)
	end
	shuttingDown = true
	-- Announce + detach every session first (so PlayerRemoving, which also fires during a
	-- shutdown, never announces or releases one a second time), then release them in parallel.
	local closing: { Session } = {}
	for player, session in sessions do
		sessions[player] = nil
		if not session.released then
			PlayerDataService.ProfileReleasing:Fire(player, session.profile)
			if session.sandbox then
				session.released = true -- New Player Mode: never written (the parked real one is)
			else
				table.insert(closing, session)
			end
		end
	end
	-- New Player Mode: the PARKED real sessions are the ones released (never the sandbox).
	for player, mode in newPlayerModes do
		newPlayerModes[player] = nil
		modeBusy[player] = nil
		if not mode.real.released then
			table.insert(closing, mode.real)
		end
	end
	local s = store
	if s == nil or not savingEnabled then
		return
	end
	for _, session in closing do
		task.spawn(releaseSession, session)
	end
	-- Also waits for releases PlayerRemoving already started, and for opens still in flight.
	local deadline = os.clock() + SHUTDOWN_BUDGET_SECONDS
	while (s:activeWrites() > 0 or next(releasing) ~= nil or opensInFlight > 0) and os.clock() < deadline do
		task.wait(0.1)
	end
end

--------------------------------------------------------------------------------------------------
-- New Player Mode (admin "PLAY AS NEW PLAYER"; rules: Shared/Util/NewPlayerMode, B14)
--
-- ENTER (enterNewPlayerModeAsync; AdminService calls it after its authorization pipeline):
--   1. NewPlayerMode.enterRefusal (loaded, not leaving / closing / already on / busy).
--   2. The real profile is made DURABLE first (commitAsync of its current change version).
--   3. Re-checked after that yield, then: the real profile is replaced by a deep copy nothing
--      else references → ProfileUnloading (handlers see that copy via getProfile) → the real
--      session is PARKED → a SANDBOX session becomes sessions[player] → attribute set → a FULL
--      push + ProfileLoaded(player, sandboxProfile, true) with getLoadReason "enterNewPlayerMode".
-- EXIT (exitNewPlayerMode, never yields): ProfileUnloading (attribute still on, so the sandbox's
--   wrap-up stays out of analytics) → the sandbox is marked released (stale workers fail closed)
--   → the parked real session is live again → attribute cleared → FULL push +
--   ProfileLoaded(player, realProfile, false) with getLoadReason "exitNewPlayerMode".
-- LEAVE / SHUTDOWN: the sandbox is only marked released (never written); the parked real
--   session gets the normal final save + lock release (onPlayerRemoving / onClose above).
--------------------------------------------------------------------------------------------------

local ENTER_SAVE_FAILED = "Could not save your real profile first - nothing changed. Try again in a moment."
local ENTER_STATE_CHANGED = "Your state changed while saving - nothing changed. Try again."

--[[
	True while `player` plays the throwaway brand-new sandbox profile (authoritative; the
	`NewPlayerMode` player attribute mirrors it for analytics, other services and the client).
	Example: if PlayerDataService.isNewPlayerMode(player) then return end -- no global side effects
]]
function PlayerDataService.isNewPlayerMode(player: Player): boolean
	return newPlayerModes[player] ~= nil
end

--[[
	Why the player's current profile was announced: "join" (loaded from the DataStore / memory),
	"enterNewPlayerMode" (the sandbox was swapped in) or "exitNewPlayerMode" (the parked real
	profile is back). nil before the first load / after leave. Valid inside ProfileLoaded handlers.
	Example: if PlayerDataService.getLoadReason(player) == "join" then grantOfflineEarnings(player) end
]]
function PlayerDataService.getLoadReason(player: Player): LoadReason?
	return loadReasons[player]
end

--[[ Studio suites only: the parked real session while the mode is on (nil otherwise / live). ]]
function PlayerDataService.parkedSessionForTests(player: Player): Session?
	if not RunService:IsStudio() then
		return nil
	end
	local mode = newPlayerModes[player]
	return if mode ~= nil then mode.real else nil
end

-- Writes the replicated mode attribute (nil when off, so a normal player carries none).
local function setModeAttribute(player: Player, on: boolean)
	if player.Parent == Players then
		player:SetAttribute(NewPlayerMode.Attribute, if on then true else nil)
	end
end

--[[
	Announces a swapped-in session exactly like a join: the client gets a FULL snapshot (its delta
	base belonged to the other profile), then ProfileLoaded runs every service's per-profile setup.
]]
local function announceSwapped(player: Player, session: Session, reason: LoadReason, isNew: boolean)
	loadReasons[player] = reason
	ProfileSyncState.requestFull(syncStateOf(player))
	PlayerDataService.ProfileLoaded:Fire(player, session.profile, isNew)
	pushNow(player)
end

--[[
	Turns New Player Mode ON for `player` (sequence: the section header). Yields (the real
	profile's commit). Callers MUST have authorized the request (AdminService does).
	@return (ok, message for the admin's toast / audit log)
	Example: local ok, message = PlayerDataService.enterNewPlayerModeAsync(player)
]]
function PlayerDataService.enterNewPlayerModeAsync(player: Player): (boolean, string)
	local real = sessions[player]
	local refusal, refusalMessage = NewPlayerMode.enterRefusal({
		loaded = real ~= nil and player.Parent == Players,
		active = newPlayerModes[player] ~= nil,
		busy = modeBusy[player] == true,
		shuttingDown = shuttingDown,
		released = real ~= nil and real.released,
	})
	local s = store
	if refusal ~= nil or real == nil or s == nil then
		return false, refusalMessage or "Your profile has not loaded yet."
	end
	modeBusy[player] = true

	-- 1. The real profile becomes durable BEFORE anything is swapped (only a healthy saving
	-- session can be written; in-memory / read-only / lost sessions never write anyway).
	if real.status == "ok" then
		PlayerDataService.notify(player, NewPlayerMode.Copy.Entering, "info")
		local ok, committed = pcall(function(): boolean
			return s:commitAsync(real, real.changeVersion)
		end)
		if not ok or committed ~= true then
			modeBusy[player] = nil
			return false, ENTER_SAVE_FAILED
		end
	end
	-- 2. The commit yielded: everything is checked again (left, closing, replaced, released).
	if
		player.Parent ~= Players
		or shuttingDown
		or sessions[player] ~= real
		or real.released
		or newPlayerModes[player] ~= nil
	then
		modeBusy[player] = nil
		return false, ENTER_STATE_CHANGED
	end

	-- 3. Park the real session. Its profile is replaced by a deep copy that nothing else holds, so
	-- a stale reference somewhere (a cached `profile` local) can never edit what gets saved.
	real.profile = ProfileLogic.deepCopy(real.profile)
	local sandbox = s:sandboxSession(player.UserId)
	PlayerDataService.ProfileUnloading:Fire(player) -- handlers still see the REAL profile
	newPlayerModes[player] = { real = real, enteredAt = os.time() }
	sessions[player] = sandbox
	setModeAttribute(player, true) -- before ProfileLoaded: every check (analytics too) sees the mode
	announceSwapped(player, sandbox, "enterNewPlayerMode", true)
	modeBusy[player] = nil
	PlayerDataService.NewPlayerModeChanged:Fire(player, true)
	return true, NewPlayerMode.Copy.Entered
end

--[[
	Turns New Player Mode OFF (NewPlayerMode.exitPlan): the parked real profile is live again at
	once. Leaving the game also ends the mode (onPlayerRemoving). Never yields.
	@return (ok, message)
	Example: local ok, message = PlayerDataService.exitNewPlayerMode(player)
]]
function PlayerDataService.exitNewPlayerMode(player: Player): (boolean, string)
	local mode = newPlayerModes[player]
	local plan = NewPlayerMode.exitPlan({
		active = mode ~= nil,
		busy = modeBusy[player] == true,
		shuttingDown = shuttingDown,
	})
	if plan == "refuse" or mode == nil then
		return false,
			if mode == nil
				then "New Player Mode is not on."
				elseif shuttingDown then "The server is shutting down (your real profile is safe)."
				else "New Player Mode is switching - one moment."
	end
	modeBusy[player] = true
	-- The attribute is still on here: the sandbox's wrap-up stays out of analytics.
	PlayerDataService.ProfileUnloading:Fire(player)
	local sandbox = sessions[player]
	if sandbox ~= nil and sandbox.sandbox then
		sandbox.released = true
	end
	newPlayerModes[player] = nil
	sessions[player] = mode.real
	setModeAttribute(player, false)
	announceSwapped(player, mode.real, "exitNewPlayerMode", false)
	modeBusy[player] = nil
	PlayerDataService.NewPlayerModeChanged:Fire(player, false)
	return true, NewPlayerMode.Copy.Exited
end

--------------------------------------------------------------------------------------------------
-- Remote handlers (C→S)
--------------------------------------------------------------------------------------------------

--[[
	ProfileDeltaAck: the client can apply deltas of `version`. Rate-limited; only the exact
	ProfileSyncConfig.Version enables deltas. Grants nothing: it only changes the push format.
]]
local function onProfileDeltaAck(player: Player, version: unknown)
	if not profileSync.ack:Allow(player) then
		return
	end
	ProfileSyncState.ack(syncStateOf(player), version)
end

--[[
	ProfileResync: the client's delta base is wrong. Rate-limited; answered with the server's OWN
	full snapshot on the next push (never with anything the client sent).
]]
local function onProfileResync(player: Player)
	if not profileSync.resync:Allow(player) or sessions[player] == nil then
		return
	end
	ProfileSyncState.requestFull(syncStateOf(player))
	schedulePush(player)
end

--------------------------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------------------------

--[[ Service contract: wiring only (nothing to wire before Start). ]]
function PlayerDataService.Init() end

--[[ Service contract: remotes, the store, autosave, BindToClose and player events. ]]
function PlayerDataService.Start()
	Remotes.onServerEvent("ProfileDeltaAck", onProfileDeltaAck)
	Remotes.onServerEvent("ProfileResync", onProfileResync)
	task.spawn(initStoreAsync)
	task.spawn(autosaveLoop)
	game:BindToClose(onClose)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

return PlayerDataService
