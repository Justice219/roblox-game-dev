# Server architecture and security

This reference covers how a SellNukes-style Roblox server is put together and kept safe and fast:
the ordered service boot, the Init/Start service contract, the single remote registry, the rules
every remote handler follows, session-locked profiles with schema migrations, idempotent Robux
receipts, player-text filtering, DataStore budgets, and the performance and telemetry rules. Every
pattern here is in production in SellNukes (`~/IdeaProjects/RobloxGame/SellNukes`), and most were
ported from RoBeasts (`~/IdeaProjects/RoBeasts`). Copy them into a new game unchanged unless you
have a measured reason not to. They exist because the client is hostile, DataStores are slow and
rate-limited, and one broken feature must never take a live server down.

## Contents

1. [Folder layout and layering](#1-folder-layout-and-layering)
2. [Boot: the ordered service list](#2-boot-the-ordered-service-list)
3. [The service contract (Init / Start / Signals / seams)](#3-the-service-contract)
4. [Remotes: one registry, events only](#4-remotes-one-registry-events-only)
5. [Remote handler rules](#5-remote-handler-rules)
6. [Skeleton: a validated remote handler inside a service](#6-skeleton-a-validated-remote-handler-inside-a-service)
7. [Intents, never amounts](#7-intents-never-amounts)
8. [Persistence: profiles, session locks, schema, migrations](#8-persistence-profiles-session-locks-schema-migrations)
9. [Profile sync to the client](#9-profile-sync-to-the-client)
10. [Robux: prompts, receipts, the per-profile ledger, policy](#10-robux-prompts-receipts-the-per-profile-ledger-policy)
11. [Player text and TextService](#11-player-text-and-textservice)
12. [DataStore, MemoryStore and HTTP budgets](#12-datastore-memorystore-and-http-budgets)
13. [Admin authorization](#13-admin-authorization)
14. [Performance rules](#14-performance-rules)
15. [Server health telemetry](#15-server-health-telemetry)
16. [Security-audit checklist](#16-security-audit-checklist)
17. [Tests that guard all of this](#17-tests-that-guard-all-of-this)

---

## 1. Folder layout and layering

```
src/server/
  init.server.luau          the ONLY server entry point (boot list, test runner hook)
  Services/                 one <Name>Service.luau per system (Init/Start)
  Economy/                  ProfileStore, ProfileLogic, ProfileSyncState, PolicyCache, PassOwnership
  Tycoon/ Retention/ Pets/ Attack/ Event/ Kinetic/ Quests/ Pass/ Social/ HappyHour/ World/ ...
                            feature folders: extra services ("Tycoon/PlotService") + pure *Logic
  Analytics/                Recorder, KeySpec, Flusher, ServerHealth, ReceiptAccounting, Reports
  Admin/                    AdminPipeline, AdminAuth, AdminValidate, AdminAudit, AdminRegistry, Handlers/
  Tests/                    Studio TestRunner suites (run via StudioTestService)
src/shared/
  Net/                      Remotes (registry), Validate (boundary narrowing), ProfileDelta, WireSize
  Util/                     RateLimiter, Signal, Trove, MathUtil, TextUtil, NumberFormat, NewPlayerMode
  Config/                   every tunable and catalogue (never inline magic numbers)
```

Split each system into three layers:

| Layer | Example | Rules |
|---|---|---|
| Config | `Shared/Config/KineticConfig.luau` | Plain tables + a `validate()` where mistakes are possible. All numbers live here. |
| Pure logic | `Shared/Kinetic/KineticLogic.luau`, `Server/Tycoon/TycoonRules.luau` | No Roblox services, clocks injected, never yields. Unit-tested under Lune. |
| Service | `Server/Kinetic/KineticService.luau` | Owns remotes, loops, Instances, DataStore calls. Thin: calls the logic. |

Why: pure logic can be fuzzed with thousands of hostile inputs in milliseconds
(`tests/remote-security.luau` runs 4,819 checks), while services need Studio. The more of a
rule lives in `*Logic`, the more of it is proven before anyone opens Studio.

## 2. Boot: the ordered service list

`src/server/init.server.luau` does four things, in this order:

1. `Remotes.createAll()` creates every RemoteEvent so clients can fetch them at once.
2. `Init()` on every service in dependency order. Init is wiring only: registrations, signal
   hookups, no yielding.
3. `Start()` on every service in the same order. Start connects remotes and player events and
   begins loops.
4. In a Studio test run (`StudioTestService:GetTestArgs()` returns `{ suite = "..." }`), run
   `Tests/TestRunner` and always call `StudioTestService:EndTest` exactly once. A watchdog
   (`task.delay(budget, ...)`) ends a hung run, and a bootstrap failure ends it with a
   `bootstrap failed` result. A live game never has test args, so this is inert there.

Two tiers:

- **CRITICAL** (static requires): `PlayerDataService` → `MonetizationService` →
  `AnalyticsService`. A failing require, Init or Start throws with the service name. The game
  cannot run without profiles, receipts or the analytics hooks that receipts report through.
- **FEATURE** (loaded by name under `pcall`): a feature that fails to load, Init or Start is
  skipped with a `warn` naming it. Features whose Init failed are never Started. One broken
  feature (mid-development or a bad hotfix) never takes the whole server down. The boot prints
  `features started: N/M`, which is the first thing to check in a Studio log.

The SellNukes feature order (each entry may only call into entries above it during Init/Start):

```lua
local FEATURE_SERVICES: { string } = {
	"SettingsService",            -- settings first: others read toggles
	"PlayerTitleService",
	"BoostService", "ServerBoostService",   -- ModifierSources (offline = false)
	"RetentionService", "PlaytimeService", "LuckySpinService", "CodesService",
	"GroupRewardService", "NotifyRewardService",
	"Retention/ReturnNotifyService",        -- MemoryStore queue -> Open Cloud
	"ChangeNotesService",
	"ShopService",                          -- last of the retention group (admin hooks, packs)
	"Tycoon/PlotService", "Tycoon/TycoonService",
	"Tycoon/Knockdown",                     -- TycoonService binds to it in Init
	"Tycoon/OfflineService", "Tycoon/RebirthService",
	"Tycoon/FlavorService", "Tycoon/WorldService",
	"Kinetic/KineticService",               -- needs Tycoon + Flavor + World
	"MovementService",
	"DefenseService", "AttackService",      -- attack needs defense
	"PetService", "CrateService",           -- crates need pets for drops
	"EventService", "LeaderboardService", "BadgeService",
	"LuckyButtonService", "HappyHourService",
	"PassService", "QuestService",
	"RushService", "FriendService",
	"World/LobbyNpcService",
	"AdminService",                         -- LAST: drives every service through its admin seams
}
```

A bare name resolves in `./Services`; a slash path (`"Tycoon/PlotService"`) resolves from the
script, so feature folders keep their own services. When you add a service, insert it after
everything it depends on, and if it sells Robux items register its product handler in `Init`
(`MonetizationService.registerProductHandler`) so a receipt arriving the moment Start runs
already has a handler.

The client mirrors this (`src/client/init.client.luau`): hide CoreGui, `ClientState.start()`,
then controllers looked up by name under `pcall(require)`, then set a `ClientBooted` attribute.

## 3. The service contract

Every service is a plain module table:

- `Init()`: wiring only. Register product handlers, ModifierSources providers, admin commands,
  analytics id kinds. Connect to signals of earlier services. Never yield.
- `Start()`: `Remotes.onServerEvent(...)`, `Players.PlayerAdded/PlayerRemoving`, one loop.
- Public functions for other services, documented in the header (`API` block with an example).
- **Signals** (`Shared/Util/Signal`) for things other systems react to:
  `PlayerDataService.ProfileLoaded(p, profile, isNew)`, `ProfileReleasing(p, profile)` (before
  the final save; never yield), `CurrencyChanged(p, key, delta, reason, balance)`,
  `TycoonService.PadBought(p, padId, skipped)`, `SettingsService.Changed(p, key, value)`.
  Listeners react to events instead of polling profiles every frame. Fire "deferred" signals
  (`task.defer`) from inside non-yielding critical sections so a slow listener cannot break
  atomicity.
- **Seams** for cross-system checks that must not create require cycles:
  `MonetizationService.setWorldUnlockCheck(fn)` is installed by WorldService in its Start.
  The seam runs no-yield, and a failure counts as locked (fail closed).
- **Lazy requires** (`Server/Event/Lazy.luau`) when a dependency is built in parallel by another
  agent or would form a cycle: `Lazy.fn("PetService", "grantPet")` returns nil (warned once)
  when the module is missing or broken, and the caller degrades to "coming soon".
- **Kill switches**: every system with live risk has an admin on/off (`WorldEnabled_<id>`,
  `KineticSwitch`, `LuckyToggle`, `HappyHourToggle`, `NotifyToggle`). Universe-wide switches use
  a DataStore record + `MessagingService` broadcast + a 90 s poll as a fallback.
- **Header comment** on every module: purpose, how it works, what it connects to, example.

## 4. Remotes: one registry, events only

`src/shared/Net/Remotes.luau` declares every remote as a string-literal union type, so a typo is
a type error and the whole network surface is auditable in one file.

- **RemoteEvents only. No RemoteFunctions.** A server→client invoke can hang a server thread
  forever if the client never answers. A client→server invoke is replaced by an event plus a
  result event (`PromptProduct` → `PurchaseGranted`; `AnalyticsRequest` → reply event).
- **UnreliableRemoteEvent** only for cosmetic, high-frequency, droppable sends (`IncomePop`).
- `Remotes.createAll()` builds the folder, creates every remote, and parents the folder LAST so
  clients receive it complete in one replication step.
- Clients get remotes with `Remotes.event(name)` (cached, `WaitForChild` with a timeout).
- **Server connects only through `Remotes.onServerEvent(name, handler)`**, which wraps the
  handler in `Remotes.fromPresentPlayer`: events from a player whose `Parent ~= Players` are
  dropped. Events can still arrive after `PlayerRemoving` fired; without this guard a late
  packet re-creates limiter buckets and request memories for a departed player (a slow leak),
  or acts for someone who is gone. The 2026-10-30 audit moved 36 connections onto this.
- **Server sends go through** `Remotes.fireClient / fireAllClients / fireUnreliableClient /
  fireUnreliableAllClients`, never `Remotes.event(x):FireClient` directly. The wrappers report
  (name, estimated bytes, recipients) to an optional send observer that ServerHealth installs,
  so a bandwidth spike can be traced to its remote. With no observer installed the cost is one
  nil check.

## 5. Remote handler rules

The first argument to `OnServerEvent` (the Player) is authentic. Every other argument is hostile:
type it `unknown` and narrow it. The security audit scores every handler on eight columns; a new
handler must pass all eight.

| Column | Rule | How |
|---|---|---|
| Args | Every argument is type-checked | `Validate.*` returns the narrowed value or nil. Never coerce `"5"` to 5. Reject tables with metatables. |
| Ids | Ids are checked against config | `Validate.configKey(raw, Config.Map)` does a `rawget` allowlist lookup. `Validate.key(raw, n)` for ids looked up later (`[%w_-]`, length cap). |
| Num | NaN and ±inf are rejected; numbers are clamped or integer-checked | `Validate.number(v, min, max)` / `Validate.integer(v, min, max)` (finite via `MathUtil.isFinite`). |
| Rate | Per-player token bucket | `RateLimiter.new(burst, perSecond)`; `limiter:Allow(player)`; `limiter:Forget(player)` on PlayerRemoving. |
| State | Loaded, can mutate, owns, unlocked, in range | `PlayerDataService.getProfile`, `canMutate`, plot ownership, `padAvailable`, `TycoonRules.withinReach(root, anchor, reach, vertical)`. |
| Trust | No client amount, Instance or path is trusted | The server computes prices, rewards and positions. Ids are lookup keys, never instance paths. |
| Yield | State is re-checked after every yield; no double-spend race | In-flight guard per player; re-check presence, session identity, `canMutate` and feature after `FilterStringAsync` / PolicyService / group calls. Charge and grant in one non-yielding step. |
| Leave | Per-player tables are forgotten on PlayerRemoving; late packets are dropped | `Remotes.onServerEvent` + `Forget` + `inFlight[player] = nil`. |

`Validate` API (`src/shared/Net/Validate.luau`): `number`, `integer`, `boolean`,
`string(min, max)`, `oneOf(v, list)`, `key(v, maxLen)`, `configKey(v, map, maxLen?)`,
`requestId` (whole 1..2^31-1), `userId`, `text(v, maxChars)` (valid UTF-8, no control chars;
still filter with TextService), `stringArray(v, maxCount, maxLen)` (dense, distinct, bounded
copy), `vector3(v, maxMagnitude)`, `basePartInWorkspace`, `flatTable(v, maxKeys)`, plus
game-specific composites (`worldId`, `worldIdOrMain`, `travelRequest`, `rebirthShopBuy`) that
parse several arguments together against config.

Real rate limits from SellNukes, as a sizing guide (burst / per second):

| Remote | Limit | Why that size |
|---|---|---|
| ProducerClick | 20 / 12 | Fast clicking is the core verb; must allow real humans. |
| ProducerUpgrade | 15 / 8 | Spam-buying x1 is legitimate. |
| PadBuy | 6 / 3 | Walking onto pads; the touch path shares the limiter. |
| PromptProduct / PromptPass | 3 / 0.5 shared | Robux prompts are rare and must never stack. |
| SpinWheel, OpenCrate | 3 / 0.5, 3 / 1 + one in flight | Paid random items; policy yield inside. |
| RedeemCode | 4 / 0.25 (+ refusal replies throttled to 1 per 5 s) | Stops brute-force guessing. |
| RenameStand / RenamePlot | 2 then 1 / 15 s, 3 then 1 / 10 s + in flight | TextService is expensive and rate-limited itself. |
| Rebirth | 2 / 0.2 + busy flag | Destructive reset; must never double-run. |
| AdminCommand | 10 / 3 + per-command cooldown | Even admins get bounded. |

More rules that come from real bugs:

- **Order of cheap checks.** Rate-limit first for high-frequency verbs so junk costs nothing.
  For scarce tokens (renames), run silent validation BEFORE the limiter so a malformed request
  from the player's own buggy client does not burn their only rename token.
- **Request ids for "exactly once" actions** (`SpinWheel`, `HatchEgg`, `OpenCrate`): the client
  numbers its requests, the server remembers the last 32 per player and answers a repeat with the
  stored result instead of rolling again. Only write the memory for players still present.
- **Plan → charge → commit with no yield.** Compute everything, then `trySpendCash` and the grant
  in one synchronous block. If the grant fails after the spend, refund in the same block.
- **Refusals are quiet and fixed.** Drop malformed packets silently. For legitimate refusals send
  a fixed server string toast ("Need $1.2K more for Tool Wall!"), throttled (one "slow down"
  per 4 s). Never echo client text back. When a refusal undoes an optimistic UI change, re-send
  the stored state (`PlayerDataService.refresh(p, { "settings" })`) so the toggle snaps back.
- **Positions come from the server.** Reach uses the server's view of the character root and
  the server's anchor position, with separate horizontal and vertical reach. Moving-target
  checks sample the distance now and 0.4 s / 0.8 s ago (EventCollect).
- **New Player Mode / sandbox.** Services with side effects outside the profile (DataStore
  queues, leaderboards, referrals, notifications) check `PlayerDataService.isNewPlayerMode(p)`.

## 6. Skeleton: a validated remote handler inside a service

```lua
--!strict
--[[
	FooService — sells Foo upgrades for cash (owner R<n>).

	Remotes: FooBuy (C→S key, count). Intent only: the server prices it.
	Connects to: PlayerDataService (profile, trySpendCash, markChanged), FooLogic (pure rules,
	tests/foo-logic.luau), FooConfig (catalogue + limits), AnalyticsService (via Lazy).
	API:
		FooService.ItemBought: Signal(player, key, count)
	Example: FooService.ItemBought:Connect(function(p, key) ... end)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local FooConfig = require(ReplicatedStorage.Shared.Config.FooConfig)
local FooLogic = require(ServerScriptService.Server.Foo.FooLogic)
local Lazy = require(ServerScriptService.Server.Event.Lazy)
local PlayerDataService = require(script.Parent.PlayerDataService)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Validate = require(ReplicatedStorage.Shared.Net.Validate)

local FooService = {}

-- Fired after a purchase was applied (player, key, count). Never yields inside the buy.
FooService.ItemBought = Signal.new() :: Signal.Signal<Player, string, number>

local buyLimiter = RateLimiter.new(FooConfig.Limits.Buy.Burst, FooConfig.Limits.Buy.PerSecond)

-- Fixed-text toast to the player (never echoes client input).
local function notice(player: Player, text: string)
	Remotes.fireClient("Notify", player, { kind = "error", text = text })
end

--[[
	FooBuy(key, count): buy `count` levels of a Foo upgrade.
	Checks: rate → args → config id → profile + saving session → unlocked → server price → atomic
	spend + grant (no yield) → save soon → analytics → signal.
]]
local function onFooBuy(player: Player, rawKey: unknown, rawCount: unknown)
	if not buyLimiter:Allow(player) then
		return
	end
	local key, item = Validate.configKey(rawKey, FooConfig.Items, 32)
	local count = Validate.integer(rawCount, 1, FooConfig.MaxPerBuy)
	if key == nil or item == nil or count == nil then
		return -- malformed: drop silently
	end
	local profile = PlayerDataService.getProfile(player)
	if profile == nil or not PlayerDataService.canMutate(player) then
		return -- not loaded, or the save is offline: never sell into a profile that cannot save
	end
	if not FooLogic.isUnlocked(profile, key) then
		notice(player, "Unlock this first!")
		return
	end
	-- The SERVER computes the price from config + saved level. The client never sends an amount.
	local cost = FooLogic.price(item, FooLogic.level(profile, key), count)
	if not PlayerDataService.trySpendCash(player, cost, "fooBuy") then
		notice(player, "Not enough cash!")
		return
	end
	-- Same synchronous block as the spend: no yield between charge and grant.
	FooLogic.addLevels(profile, key, count)
	PlayerDataService.markChanged(player, true, { "foo" }) -- saveSoon: a purchase
	Lazy.analytics("tycoon", player, `foo:{key}`)
	FooService.ItemBought:Fire(player, key, count)
end

function FooService.Init()
	-- Wiring only (no yields): product handlers, ModifierSources, admin commands, analytics ids.
	Lazy.registerIds("fooKey", function(id: string): boolean
		return FooConfig.Items[id] ~= nil
	end)
end

function FooService.Start()
	Remotes.onServerEvent("FooBuy", onFooBuy) -- drops late packets from departed players
	Players.PlayerRemoving:Connect(function(player: Player)
		buyLimiter:Forget(player)
	end)
end

return FooService
```

For a handler that must yield (TextService, PolicyService, `IsInGroupAsync`), add an in-flight
guard and re-check everything after the yield:

```lua
local inFlight: { [Player]: boolean } = {}

local function onRename(player: Player, rawText: unknown)
	local text = Validate.text(rawText, 24)            -- silent validation before the scarce token
	if text == nil or inFlight[player] or not renameLimiter:Allow(player) then
		return
	end
	local session = PlayerDataService.getSession(player)
	inFlight[player] = true
	local ok, filtered = pcall(filterForBroadcastAsync, player, text) -- yields
	inFlight[player] = nil
	-- Re-check: still here, same session (New Player Mode swaps sessions), still allowed.
	if player.Parent ~= Players or PlayerDataService.getSession(player) ~= session then
		return
	end
	if not ok or filtered == nil or not FooLogic.hasRenameFeature(PlayerDataService.getProfile(player)) then
		notice(player, "That name can't be used.") -- fail closed
		return
	end
	-- apply + markChanged ...
end
-- PlayerRemoving: renameLimiter:Forget(player); inFlight[player] = nil
```

## 7. Intents, never amounts

The client sends what it wants to do; the server decides what it costs and what it pays.

| Remote | Client sends | Server computes |
|---|---|---|
| `ProducerClick(producerId)` | which producer | whether it is built, idle, un-managed, in reach; the payout |
| `ProducerUpgrade(producerId, "1"/"10"/"max")` | a mode from a fixed list | levels affordable and their cost |
| `PadBuy(padId)` | which pad | ownership, availability, reach, cost |
| `PromptProduct(key, source)` | a catalogue key + an analytics label | eligibility, the prompt, the grant |
| `AttackLaunch(targetUserId, kind)` | target + kind | eligibility, silo, flight, interception, reward (seeded RNG) |
| `Rebirth(worldId?)` | nothing else | eligibility, tokens, the reset |
| `TravelWorld(world, target, index)` | destination ids | unlock, cooldown, the server CFrame |

Also never trust: client timestamps (offline time uses the server's stamped `lastSeenAt`), client
positions (reach uses the server's character), client Instances or paths (no
`basePartInWorkspace` on economy paths), client-rolled randomness, client "I finished" claims
beyond cosmetic analytics. The only accepted client claim in SellNukes is the notification
opt-in (Roblox exposes it only on the client); its reward is one-time and small, and that risk is
documented.

## 8. Persistence: profiles, session locks, schema, migrations

### ProfileStore (`src/server/Economy/ProfileStore.luau`)

- DataStore `<Game>Profiles_v1` (a separate `…_v1_Studio` store in Studio so tests never touch
  live saves). Key `Profile_<UserId>`. Record `{ format = 1, data, lock, updatedAt }`. Return
  the user id from `UpdateAsync` so Roblox can erase it for GDPR requests.
- **Session lock**: loading writes `lock = { jobId, sessionId, heartbeatAt }` through
  `UpdateAsync`. A server that finds a live lock retries with exponential backoff
  (`loadAttempts = 6`, about 23 s total) because the other server is usually mid-release.
  A lock whose heartbeat is older than `lockStaleSeconds = 600` (five missed autosaves; 60 s in
  Studio) is taken over, as is a lock left by one of this server's own finished sessions.
- **Never overwrite another session**: every save's transform re-checks the record still carries
  OUR sessionId. If not, the session flips to `"lost"` and never writes again.
- **Throttle and serialize**: at most one write per key per `minWriteInterval = 6.5` s (Roblox
  allows about one per 6 s per key), saves for one profile never run concurrently, everything
  is `pcall`ed with backoff (`saveAttempts = 4`, delay 1 → 8 s).
- **Versions**: `changeVersion` / `savedVersion` let a caller wait until a specific change is
  durable (`commitAsync`), which ProcessReceipt needs.
- **Save statuses**: `"ok"`, `"disabled"` (Studio without API access or DataStores down: an
  in-memory session so playtests work, nothing written), `"readOnly"` (saved by a newer game
  version: keeps the lock alive, never writes data), `"lost"`.
- **Autosave**: ONE loop for every profile, staggered (`autosaveInterval = 120` s +
  `autosaveJitter = 30` s), budget-aware (section 12). `markChanged(p, true)` asks for a save
  within seconds (purchases, pad buys, claims).
- **Leave / shutdown**: final save + lock release on leave; `BindToClose` releases in parallel
  with a 25 s budget (Roblox gives 30 s).
- **beforeSave** stamps `offline.lastSeenAt` and `tycoon.lastSaveAt` with the server clock on
  every write, so offline earnings count from the last save even after a server crash.
- **Testability**: the DataStore, clocks and timings are injected; `tests/profile-store.luau`
  drives lock, takeover, lost lock, throttle, commit, release and sandbox paths with a JSON mock.

### PlayerDataService API (the only door to a profile)

`getProfile(p)`, `waitForProfile(p, timeout?)`, `getSession(p)`, `canMutate(p)` (true only for a
saving session or Studio memory; check it before any commerce or one-time claim),
`markChanged(p, saveSoon?, fields?)`, `refresh(p, fields?)`, `grantCash(p, n, reason) -> added`,
`trySpendCash(p, n, reason) -> bool`, `grantGems` / `trySpendGems`, generic
`grantCurrency(p, key, n, reason)` / `trySpendCurrency` / `balance(profile, key)`,
`notify(p, text, kind, icon?)`, `isPaidRandomRestricted(p)`, `isPolicyKnown(p)`,
`resolvePaidRandomAsync(p)`. Reasons are analytics labels (`[%w_-]`, ≤ 32 chars, else
`"other"`). Never write currency fields directly: the API clamps, fires `CurrencyChanged`, and
marks the right sync fields.

### Schema and migrations (`src/server/Economy/ProfileLogic.luau`)

- `ProfileLogic.SCHEMA_VERSION` (SellNukes: 2) and `MIGRATIONS[n]`, which upgrades raw data IN
  PLACE from n to n + 1 before reconcile. To add a version: write `MIGRATIONS[n]`, bump the
  version, extend `defaultProfile` / `reconcile` / `snapshot`, add a test that a fully populated
  old save carries every value.
- `migrate(raw)` returns `"new" | "current" | "migrated" | "newer"`. **Newer = read-only**: an
  old server that loads a save written by a newer version must never save over fields it does
  not know. At publish, use "Migrate to Latest Update" so old servers drain.
- **Prefer additive changes.** v1 → v2 (Dino Valley) was a no-op migration: `reconcile` fills
  defaults for new fields. Put rules like "legacy players unlock the new world" in the owning
  service at join, not in the migration, so the rule lives in one place.
- `reconcile` repairs every stored table: types, finite and clamped numbers (`MaxCash = 1e300`,
  `MaxGems = 1e12`), UTF-8-safe string caps, bounded maps (`Limits.MaxItemCount`,
  `MaxEggKinds`, `MaxWorlds = 8`, ...), `equipped ⊆ owned`, counters past every used id.
- `toSave` writes numeric sets as sorted arrays and scrubs non-finite numbers, so a stray NaN
  can never block saving.
- **Ids that are save data are never renamed** (pad ids, producer ids, shop keys, badge order).
  Append, never reorder.

### New Player Mode (admin "play as a new player")

`enterNewPlayerModeAsync` commits the real profile, PARKS its session (lock kept, heartbeat
autosaves, deep-copied so stale references cannot edit it), and swaps in a sandbox profile that
is never written by any path. Receipts of a sandboxed buyer are deferred (`NotProcessedYet`) and
land in the real profile after exit. Every prompt is refused in the mode. `getLoadReason(p)`
tells services whether to run once-per-join work (offline earnings run on `"join"` only).

## 9. Profile sync to the client

- Full `ProfileUpdate(snapshot, seq)` on load / resync; afterwards
  `ProfileDelta({ v, seq, base, set, cleared })` with only the changed top-level fields, built from
  the declared dirty fields (`markChanged(p, saveSoon, { "stats" })`).
- Coalesced: the first change after a quiet period goes out next frame (`task.defer`), later ones
  wait for the trailing push; at most **4 pushes/s per player**. A cash tick is **116 B**
  (≤ 464 B/s per player). A late-game full snapshot is about 8 kB (join only).
- `snapshot()` is an allowlist of what the owner may see: no receipts, codes, analytics,
  referral ids or server bookkeeping.
- The client (`ProfileSyncClient`) validates and merges into a NEW table, and requests a resync on
  a base mismatch. `ClientState.ProfileChanged(profile, fields?)` drives the UI.
- `markChanged(p, false, {})` saves a private field without any client push.

## 10. Robux: prompts, receipts, the per-profile ledger, policy

### Catalogue

`Shared/Config/MonetizationConfig.luau` defines every pass and product (kind, price fallback,
flags `oneTime`, `paidRandom`, `world`). `PublishedProductIds.luau` holds the live ids; **an id of
0 means unpublished**, which shows COMING SOON, is never prompted, and is never matched by a
receipt. `MonetizationConfig.validate()` refuses impossible definitions at boot (a `oneTime` kind
without a profile flag, an unknown world, a small pack beating a cash pack on value per Robux).

### Prompt gates (`MonetizationService.promptProduct / promptPass`)

Refuse the prompt when any of these hold: rate limit (3 burst, 0.5/s), a native prompt is already
open (released after 20 s), New Player Mode, unpublished id, outside the sale window, the
profile cannot save, the product's world is locked, a one-time pack is already owned, the pass is
already owned, a kind's own `registerPromptRefusal`, or a `paidRandom` product for a restricted
or unknown-policy player. Record a `PromptRequested` count before any refusal so analytics sees
every BUY press. The client adds its own `PurchaseGuard` (see game-systems-design.md) so a prompt
is never opened by an accidental press.

### ProcessReceipt (idempotent, with a per-profile ledger)

```
processReceiptAsync(receipt)
  1. Validate PurchaseId (≤ 64 chars), PlayerId, ProductId. A per-server processing[purchaseId]
     set drops a concurrent duplicate while the first is running.
  2. Return NotProcessedYet when: product unknown, no handler registered yet, buyer not in this
     server, session missing/released, buyer in New Player Mode, session cannot save.
  3. If ProfileLogic.hasReceipt(profile, purchaseId): re-commit if the save is still pending,
     then PurchaseGranted. NEVER grant twice.
  4. Otherwise, in ONE non-yielding step (runNoYield):
       snapshot = ProfileLogic.takeSnapshot(profile)
       ok = handler(player, profile, product, receipt)   -- must not yield (enforced)
       ProfileLogic.recordReceipt(profile, purchaseId, now)   -- result checked
       accounting.onGrant(...)
     Any error, yield or refusal → ProfileLogic.restoreSnapshot (identity-preserving) and
     NotProcessedYet, so a half-applied grant can never be autosaved and then granted again.
  5. markDirty, then commitAsync (wait until durable). A failed save → NotProcessedYet; the
     ledger entry stays, so Roblox's retry only re-commits.
  6. Only after the save succeeded: analytics onDurable, the toast, the PurchaseGranted remote,
     the ProductGranted signal (pcall'd).
```

The ledger is `profile.receipts = { [purchaseId] = time }`, newest 64 kept (`MaxReceipts`),
trimmed on reconcile, never sent to the client. Handlers are registered by the owning service
with `MonetizationService.registerProductHandler(kind, fn(player, profile, product, receipt) ->
bool)`; until one is registered the kind is "coming soon" and receipts stay `NotProcessedYet`,
so Robux is never taken for nothing. A receipt for something that can no longer be granted
(a season pass after its season) gets a defined fallback (grace window, then gems), never
nothing.

### Paid random items and PolicyService

`Server/Economy/PolicyCache.luau` reads `PolicyService:GetPolicyInfoForPlayerAsync`
(`ArePaidRandomItemsRestricted`; 3 tries with backoff, 30 s retry cooldown, waits up to 10 s).
**Fail closed**: a player counts as restricted until the answer is known. Every Robux-reachable
random roll re-checks server-side (Robux spins, crates, eggs bought with a currency Robux can
buy, lures). A currency that Robux can buy makes everything bought with it "paid random". Fixed
substitutes for restricted buyers (40 gems per spin) keep bundles sellable. Show odds before any
random purchase.

## 11. Player text and TextService

Any text one player types that another player can see must be filtered before it is saved or
shown.

1. `Validate.text(raw, 24)`: valid UTF-8, no control characters, length cap. Then a per-feature
   parser (`PlotNameLogic.parse`) drops invisible and bidi characters and collapses spaces.
   `""` means "reset to default".
2. `TextService:FilterStringAsync(text, userId, Enum.TextFilterContext.PublicChat)`, then
   `GetNonChatStringForBroadcastAsync()`, under `pcall`, with an in-flight guard.
3. Re-check after the yield (player present, same plot and profile, feature still owned).
4. **Fail closed**: a filter error refuses the change (the default name stays). If the filtered
   string differs from the input in any way, refuse it with a friendly toast instead of putting
   "####" on a kid's sign. The unfiltered text is never stored.
5. **Re-filter on display**: a saved name is re-filtered once per session before it is shown
   again, because filter rules change and the save may predate them.
6. Never echo client text in refusals or codes ("Invalid code" is a fixed server string).
7. Analytics never stores raw player text; only outcome labels (`renamePlot:set|reset|admin`).

## 12. DataStore, MemoryStore and HTTP budgets

| Store | Purpose | Budget rule |
|---|---|---|
| `<Game>Profiles_v1` | profiles | ≤ 1 write / 6.5 s per key; autosave skips while `GetRequestBudgetForRequestType(UpdateAsync)` ≤ `AUTOSAVE_BUDGET_RESERVE` (10), leaving room for joins, leaves and receipts |
| `<Game>LB_v1_<Board>` (OrderedDataStore) | leaderboards | sample every 30 s; write a player only when the value changed and ≥ 120 s since their last write; ≤ 60 writes per flush; never the same key within 7 s; read top 25 every 60 s |
| `<Game>Analytics_v1` | aggregate counters | batched, flushed on a timer; keys validated by `KeySpec` so a bug cannot mint thousands of keys |
| `<Game>Referrals_v1` | cross-server referral queue | ≤ 20 entries per inviter, kept 180 days, paid exactly once |
| `<Game>Stock_v1` | stock-limited pack | `UpdateAsync` counter |
| Control records (`…Ctl_v1`, `HappyHour_v1`) | universe-wide admin switches | DataStore + `MessagingService` publish + 90 s poll |
| MemoryStore SortedMap (`ReturnNotify_v1`) | timed notification queue | poll every 60 s + jitter; claim each entry with `UpdateAsync` under a 120 s lease so exactly one server acts |

- Use a `_Studio` suffix for every store in Studio.
- Badges: check ownership in batches of 10 at least 6.1 s apart, award at least 1.25 s apart,
  back off 5 s → 5 min on failures; store earned badges as a bitmask so checks are local.
- HTTP (Open Cloud from game servers): `HttpService.HttpEnabled = true` only when a feature needs
  it (SellNukes turned it on for return notifications). Use `HttpService:RequestAsync` with a
  timeout (12 s), a token bucket (10 burst, 0.5/s), at most 4 requests in flight, exponential
  back-off honouring `Retry-After`, and pause the feature for 10 min on 401/403. The API key is
  a Secret in the experience's secrets store; it is never in code, request bodies or logs.
  Studio always dry-runs.
- All DataStore and HTTP calls are `pcall`ed; a failure degrades the feature, never the server.

## 13. Admin authorization

The owner-only admin panel sends one remote, `AdminCommand(name, args)`, into
`Server/Admin/AdminPipeline.luau`, an ordered, fail-closed, pure pipeline:

1. token bucket (10 / 3 per UserId) before any work is spawned;
2. **re-authorize on EVERY call** (`AdminAuth.isAuthorizedAsync`): owner UserId, or a group rank
   (cached 120 s, 600 s while the group API fails; a documented risk);
3. allowlist (the command must be declared in `AdminConfig` or registered);
4. availability (Studio-only commands refused on live servers);
5. per-admin per-command cooldown;
6. strict argument schema (`AdminValidate.validateArgs`: unknown or extra args rejected, no
   metatables, `MaxArgs`);
7. target resolution (user ids map to a real Player in this server);
8. handler under `pcall`, then the audit log (audited commands + every failure), the result
   toast, `CommandExecuted`.

Services expose admin seams (`TycoonAdmin.setCash`, `KineticAdmin`, ...) registered through
`AdminService.registerCommand` (or `Lazy.registerAdmin`). Analytics report requests re-check auth
on the request AND on the reply. Destructive commands require a confirmation and are audited.
`tests/admin-pipeline.luau` proves the order and every refusal path with fakes.

## 14. Performance rules

Targets: server Heartbeat ≤ 4 ms average; client scripts ≤ 3 ms/frame on the Low quality tier.
SellNukes measured 0.17 ms average / 0.30 ms max server Heartbeat with 8 full late-game plots.

- **One RunService connection per system, never per object.** The tycoon payout is one Heartbeat
  connection that accumulates `dt` and ticks every 0.2 s over every ready player and producer.
  Catch-up is capped (5,000 cycles per tick) so a hitch cannot stall the loop. Other systems use
  one 1 Hz loop each (Lucky Buttons, Happy Hours, Kinetic, Playtime).
- **One payout per tick per player**: one `grantCash` per tick, not one per producer.
- **Cache derived values; recompute on events.** Producer stats and income modifiers are cached
  per player and rebuilt only on a purchase, a level-up, a `ModifierSources.invalidate(p)` or a
  provider's `validUntil`. Providers are pure and never yield; a throwing provider counts as
  neutral and warns once.
- **Attributes and billboards change on change, not per frame.** Set an attribute only when its
  value differs. Leaderstats refresh at 1 Hz. Client billboards run in one PreRender loop at
  4 Hz with `MaxDistance` set, and repaint only when the shown value changes.
- **Batch analytics and network.** Income analytics batch per producer and flush every 10 s.
  Income pops ride an UnreliableRemoteEvent, owner only, coalesced on the client (0.25 s) into a
  pool of 14 labels. Profile deltas are capped at 4/s per player.
- **No per-frame `Instance.new`.** Pool build-in ghosts, FX, popups. Per-device budgets
  (`BuildInConfig`: Low 24 ghosts / 14 flown per build, Mid 40 / 26, High 60 / 40).
- **StreamingEnabled** (SellNukes: min 192 / target 768 studs, `Opportunistic` stream-out,
  `Improved` model streaming). Unbought content is never instanced on the server. Per-plot
  models use `Atomic` for builds and `PersistentPerPlayer` for the owner's pads and producers.
- **Meshes**: one shared MeshPart template per mesh id, cloned; one shared stud texture set.
- **Client culling**: skip motion groups outside the camera view cone (`Shared/Util/ViewCone`),
  update far ones every other frame (WorldFx step −52 %).
- **Loading**: split preload into CRITICAL (the bar waits; brand art, hot icons, this plot) and
  DEFERRED (paced small batches after hand-off). A new player's critical list went from 222 to
  87 mesh ids; `ASSET_BUDGET` 30 s → 6 s, because Roblox ranks on first-play bounce (< 60 s).
- Modern APIs only: `task.*`, constraint movers, no `wait` / `spawn` / `delay`.

## 15. Server health telemetry

`Server/Analytics/ServerHealth.luau` is an always-on, near-zero-cost sampler (measurement only):

- every Heartbeat: frame `dt` into a count, ms sum and histogram (arithmetic only);
- 2 Hz: `Stats.HeartbeatTimeMs`, `PhysicsStepTimeMs`, `DataSendKbps`, `DataReceiveKbps`,
  `Stats:GetTotalMemoryUsageMb()`, player count, each player's `GetNetworkPing()`;
- `ServerHealth.addTime(system, seconds)`: each loop owner wraps its tick in two `os.clock()`
  reads (`ServerHealth.addTime("Producers", os.clock() - started)`); system ids come from
  `AnalyticsConfig.Health.Systems`;
- every server→client send through the Remotes send observer: fires and bytes × recipients per
  remote name (bounded key count).

AnalyticsService turns each window into `health` counters; the admin Live tab reads
`ServerHealth.liveStats()` (fps, heartbeat, memory, kbps, ping, per-system ms/s). The client
mirrors it with `ClientPerf` (boot steps, frame time per device class), validated strictly by
`ClientPerfIngest` and counted once per session.

## 16. Security-audit checklist

Run this over every new or changed handler before publishing (the format of SellNukes'
`docs/security-audit.md`; record PASS / FIXED / RISK per row).

**Global**

- [ ] No `loadstring`, `getfenv`, `setfenv` anywhere in `src/` (`grep -rn`).
- [ ] No RemoteFunctions; no `OnServerInvoke`; `Remotes` declares RemoteEvents only.
- [ ] Every C→S connection goes through `Remotes.onServerEvent` (late packets dropped).
- [ ] Every player-visible text is filtered (section 11), fails closed, and is re-filtered on display.
- [ ] Receipts: ledger checked first, grant + record in one no-yield step with snapshot rollback,
      `commitAsync` before `PurchaseGranted`, every failure returns `NotProcessedYet`.
- [ ] Paid random items gated by PolicyService, fail closed, re-checked server-side at roll time.
- [ ] Admin: re-authorized every call, strict schema, cooldowns, audit log.
- [ ] Analytics/admin report requests re-check auth on request and reply.
- [ ] Kid-friendly invariants hold (attack never removes anything from the target).

**Per handler** (the eight columns)

- [ ] Args: every argument typed `unknown` and narrowed with `Validate.*`.
- [ ] Ids: allowlisted against config (`configKey` / `rawget`), not just pattern-checked.
- [ ] Num: finite, in range, integer where it must be; amounts clamped.
- [ ] Rate: a per-player `RateLimiter`, sized from real play; refusal replies throttled.
- [ ] State: profile loaded, `canMutate` for commerce, ownership, unlocks, reach (server positions).
- [ ] Trust: no client amount, price, timestamp, position, Instance or path is used.
- [ ] Yield: in-flight guard; everything re-checked after each yield; charge + grant atomic.
- [ ] Leave: `Forget` and per-player tables cleared on PlayerRemoving.

**Verification**

- [ ] A Lune fuzz feeds NaN, ±inf, huge numbers, 5,000-char strings, invalid UTF-8, tables with
      metatables and wrong types in EVERY argument position (`tests/remote-security.luau`).
- [ ] A Studio smoke sends the same junk from a client: zero server errors, zero state change,
      and a valid request still applies.
- [ ] Residual risks are written down with severity and owner, not silently accepted.

## 17. Tests that guard all of this

| Suite | Proves |
|---|---|
| `tests/validate.luau` | every validator, RateLimiter burst/refill/Forget, TextUtil, catalogue validity, remote names |
| `tests/remote-security.luau` | late-packet guard, receipt rollback, hostile-argument fuzz across every pure rule fed raw client data (4,819 checks) |
| `tests/profile-logic.luau` | defaults, reconcile of hostile saves, migrations round-trip field for field, `"newer"` detection, snapshot shape |
| `tests/profile-store.luau` | locks, takeover, lost lock, throttle, commit, release, sandbox never written |
| `tests/profile-sync.luau` | delta fuzz + per-tick byte budgets |
| `tests/paid-random-policy.luau`, `tests/pets-policy.luau` | paid random gates fail closed |
| `tests/admin-pipeline.luau`, `admin-validate.luau`, `admin-auth.luau` | pipeline order and every refusal |
| Studio `Tests/CoreTests` (`suite = "Core"`) | remotes, catalogue, ProfileStore, receipt idempotency, New Player Mode receipt deferral |

`./scripts/check.sh` runs format, lint, strict type-check, compile and every Lune suite; it must
pass before any commit. Lune loads real `src/` modules through `tests/fixtures/RobloxLoader.luau`
(service path stubs, `@lune/roblox` datatypes, deterministic `Random`).
