# SellNukes core (B1): boot, net, persistence, profile sync, monetization

Wave 1 core framework. Copied and adapted from RoBeasts (`~/IdeaProjects/RoBeasts`), trimmed to
SellNukes' schema and catalogue. Every module has a header comment with purpose, connections and
an example; this page is the map.

## Toolchain

| Command | What |
|---------|------|
| `./scripts/check.sh` | stylua `--check src` → selene → `typecheck.sh` (luau-lsp strict, new solver) → `compilecheck.sh` (luau-compile -O0 -g2) → `test-logic.sh` (lune `tests/*.luau`) |
| `./scripts/typecheck.sh` | our `tsc --noEmit` (downloads `.luau-defs/` for the pinned luau-lsp once; regenerates `sourcemap.json`) |
| `scripts/lib/tools.sh` | resolves the **aftman-pinned binary** from `~/.aftman/tool-storage/...` (the `~/.aftman/bin` shims for `rojo` / `luau-lsp` are SIGKILLed on this machine, exit 137); override with `ROJO_BIN`, `LUAU_LSP_BIN`, ... |

Pins (`aftman.toml`, same as RoBeasts): rojo 7.7.1, stylua 2.5.2, luau-lsp 1.70.1, selene 0.32.0,
lune 0.10.5. `tests/fixtures/RobloxLoader.luau` loads real `src/` modules under Lune (script /
`game:GetService` path stubs, `@lune/roblox` datatypes, a deterministic `Random`).

## Project (`default.project.json`)

Workspace `StreamingEnabled` (min 192 / target 768 studs — the 8-plot ring is ~1400 studs across,
so 768 covers the own plot from anywhere plus the hub; `MinimumRadiusPause`, `Opportunistic`
stream-out, `Improved` model streaming). Lighting `Future`, ClockTime 14, bright ambient,
Atmosphere + ColorCorrection (+18 % saturation) + soft Bloom. StarterPlayer classic camera
(zoom 0.5–120), `CharacterAutoLoads = true`, `RespawnTime = 2`. `HttpService.HttpEnabled = true`
(since b1e3a40: the return notifications call Open Cloud from game servers through HttpService
RequestAsync, docs/retention.md; GUIDs / JSON never needed it). No baseplate: the world is built by code.
**Owner:** set Max Players = 8 in Game Settings (not settable from Rojo).

## Boot

- Server `src/server/init.server.luau`: `Remotes.createAll()` → every service `Init()` → every
  `Start()`, static ordered list, fail fast with the service name. Studio test runs
  (`StudioTestService` args `{ suite = "Core" }`) run `Tests/TestRunner` and always `EndTest`
  (watchdog). Current order: `PlayerDataService`, `MonetizationService`; commented slots mark where
  `AnalyticsService` (right after Monetization) and `AdminService` (last) go. Product-selling services go
  after MonetizationService and register handlers in `Init`.
- Client `src/client/init.client.luau`: hides Health + Backpack CoreGui, `ClientState.start()`, then
  `InputController`, `CameraController`, `UIController` (looked up by name, `pcall(require)`, a
  missing / broken controller is skipped with a warning), sets the `ClientBooted` attribute.

## Net (`src/shared/Net`)

- `Remotes` — every remote of the build plan + the analytics / admin ones, typed names;
  `event(name)`, `unreliable(name)`, `fireClient`, `fireAllClients`, `fireUnreliableClient`,
  `fireUnreliableAllClients`, `setSendObserver` (bandwidth telemetry hook). Folder
  `ReplicatedStorage.Remotes`. Only `IncomePop` is unreliable. No RemoteFunctions.
  Added on request: `LockPets` (uids, locked) + `EquipTrail` (trailId, "" = unequip) for B9,
  `PlotRevealDone` () + `TeleportPlot` (plotIndex) for B5, `EventShopBuy` (itemKey) for B11.
- `Validate` — `number`, `integer`, `boolean`, `string`, `oneOf`, `key` (`[%w_-]`, use for every
  client-named id), `configKey(value, map)` (rawget allowlist), `requestId`, `userId`, `text`
  (UTF-8, no control chars; still filter with TextService), `stringArray` (dense, distinct,
  bounded copy), `vector3`, `basePartInWorkspace`, `flatTable`.
- `ProfileDelta` / `WireSize` — delta protocol math and wire-size estimates (from RoBeasts).

## Util (`src/shared/Util`)

`Signal`, `Trove` (copied), `RateLimiter` (token bucket, `Allow` / `Forget`), `MathUtil`, `TextUtil`
(UTF-8 safe cuts), **`NumberFormat`**: `short(n)` ("1.25K", "448B", "6.29Sx", suffixes K … UCe,
truncated never rounded up), `commas(n)` ("448,087,050,019", falls back to `short` ≥ 1e15),
`money(n)` ("$1.25K"), `moneyFull(n)` ("$448,087,050,019"), `rate(n)` ("+$1.25K/s"),
`duration(s)` ("1h 02m"); NaN → "0", ±inf → "∞".

## Profile (`src/server/Economy/ProfileLogic.luau`)

Schema v1 exactly as the build plan, extended on request (B17 owns the schema; additive, reconcile
fills defaults, so no migration was needed):
- `analytics` for B13 (`seenDay`, `seen`, `ftue`, `runAt`, `play`, `carry`, `sessions`, `staff`;
  semantics-neutral clamps: finite, ≥ 0, ≤ 2^53) and `analytics.payDays` (sparse payer-day bitmap
  `{ ["0".."1562"] = 32-bit mask }`, canonical digit keys only, ≤ 1563 entries,
  `ProfileLogic.reconcilePayDays`). Never sent to the client.
- B9: `pets.eggs` / `pets.pity` (`{[eggId]=count}`, ≤ 64 keys, whole 0..1e6, zero dropped),
  `pets.index` (`{[petId]=true}`, ≤ 1000), `crates = { held, pity, opened }` (≤ 32 crate keys),
  `trails = { owned (≤ 256), equipped = "" | owned id }`. All in the snapshot (`pets`, `crates`,
  `trails` fields).
- B10: `attack.barrage` (stored Barrage nukes, whole 0..1e6), in the `attack` snapshot field.
- B16: `settings.haptics` (5th allowlisted boolean setting, default true; `SetSetting`).
- B11: `event.decor` (owned decorations, `[%w_-]` keys ≤ 24 bytes, ≤ 32), `event.turkeys` (this
  season), `event.lures` (bought, not yet caught; ≤ 1e6), in the `event` snapshot field.
- R78 (R-social, `docs/social.md`): `rush = { rookieLeft (whole s, ≤ 7200), comebackUntil }` and
  `referral = { by (inviter UserId, 0 = none), paid, seen = { newcomer ids ≤ 32 } }`
  (`SocialConfig.newRush / reconcileRush / newReferral / reconcileReferral`; missing in pre-0.6.0
  saves → none). Snapshot fields `rush` and `referral = { paid, invited }` (ids stay private).
`Limits` exposes every bound (`MaxItemCount`, `MaxEggKinds`, `MaxPetIndex`, `MaxCrateKinds`,
`MaxTrails`, `MaxPayDayBlock`, ...). `reconcile` repairs any stored table
(types, finite + clamped numbers, UTF-8 safe caps, bounded maps, equipped ⊆ owned, `nextUid` past
every numeric uid). `migrate` → `"new" | "current" | "migrated" | "newer"` (newer = read-only).
`toSave` writes numeric sets (`timeRewards.claimed`, `event.stickers`) as sorted arrays and scrubs
non-finite numbers; `snapshot(profile, ctx, fields?)` is the owner payload (no receipts, codes,
offline, analytics, `tycoon.lastSaveAt`, `pets.nextUid`; numeric sets as arrays; plus `saveStatus`
and `policy = { paidRandomRestricted, known }`). Receipts: newest 64 kept.

## Persistence (`ProfileStore` + `PlayerDataService`)

DataStore `SellNukesProfiles_v1` (`…_v1_Studio` in Studio). Record `{ format = 1, data, lock, updatedAt }`
keyed `Profile_<UserId>`, UserId attached for GDPR. Session lock with heartbeat (stale after 10 min,
60 s in Studio), backoff retries, per-key 6.5 s write throttle, serialized saves, `commitAsync`
for receipts, staggered autosave every ~2 min (budget-aware), parallel release in `BindToClose`
(25 s). Studio without API access / live DataStore failure → in-memory `"disabled"` session
(playtests work, nothing written). `sandboxSession(userId)` = a New Player Mode sandbox (brand-new
"ok" profile, `sandbox = true`): `saveDecision(status, sandbox)` (from `Shared/Util/NewPlayerMode`)
says "skip", never autosave-due, `commitAsync` false, the UpdateAsync transform refuses it, own
sessionId (never the live lock holder). `beforeSave` stamps `offline.lastSeenAt` and
`tycoon.lastSaveAt` with the server clock on every write.

**PlayerDataService API:** `getProfile(p)`, `waitForProfile(p, timeout?)`, `getSession(p)`,
`canMutate(p)` (commerce / one-time claims: saving session or Studio memory),
`markChanged(p, saveSoon?, fields?)`, `refresh(p, fields?)`, `grantCash(p, n, reason) -> added`
(also `totalEarned`), `trySpendCash(p, n, reason) -> bool`, `grantGems(p, n, reason) -> added`,
`trySpendGems`, `notify(p, text, kind, icon?)`, `isPaidRandomRestricted(p)`, `isPolicyKnown(p)`,
`resolvePaidRandomAsync(p)`, `onBeforeClose(cb)`, `getStore()`, `isSavingEnabled()`,
diagnostics `profileSyncInfo(p)`, `profilePushStats()`. `markChanged(p, false, {})` = save a
private (non-snapshot) field without any client push. Signals `ProfileLoaded(p, profile, isNew)`,
`ProfileReleasing(p, profile)` (before the final save; never yield), `CurrencyChanged(p, currency,
delta, reason, balance)`, `ProfileUnloading(p)` (right before a New Player Mode swap; getProfile =
old profile; never yield), `NewPlayerModeChanged(p, on)`. Reasons are analytics labels (`[%w_-]`
≤ 32, else "other").

**New Player Mode** (admin "PLAY AS NEW PLAYER", B14 owns the rules in `Shared/Util/NewPlayerMode`
+ AdminService; core seam ported from RoBeasts WS-H): `isNewPlayerMode(p)`,
`enterNewPlayerModeAsync(p) -> (ok, msg)` (yields: commits the real profile, PARKS its session —
lock kept, heartbeat autosaves, profile deep-copied so stale refs can't edit it — swaps in a
sandbox, sets attribute `NewPlayerMode = true`, full push, ProfileLoaded(sandbox, isNew = true)),
`exitNewPlayerMode(p) -> (ok, msg)` (never yields; swaps the real session back, attribute nil,
ProfileLoaded(real, false)), `getLoadReason(p)` = `"join" | "enterNewPlayerMode" |
"exitNewPlayerMode"` (once-per-join work such as offline earnings runs on "join" only),
`parkedSessionForTests(p)` (Studio). Leave / shutdown: the sandbox is marked released (never
written), the parked real session gets the normal release. In the mode `canMutate` stays true
(claims work into the throwaway profile); services with side effects outside the profile check
`isNewPlayerMode`. Analytics diverts on the attribute (B13 `Runtime.inNewPlayerMode`).

## Profile sync

Full `ProfileUpdate(snapshot, seq)` on load / resync / un-acked client; afterwards
`ProfileDelta({ v, seq, base, set, cleared })` with only changed top-level fields, built from the
declared dirty fields only (`ProfileSyncState.partialFields`). Coalesced: the first change after a
quiet period goes out next frame (`task.defer`), later ones wait for the trailing push — at most
**4 pushes/s per player**. Measured (`tests/profile-sync.luau`): a cash tick is **116 B** →
**≤ 464 B/s per player** (~3.7 kB/s for 8 players); a late-game full snapshot ~8 kB (join only).
Client: `ProfileSyncClient` validates / merges into a new table and requests a resync on a base
mismatch; `ClientState.profile`, `ClientState.ProfileChanged(profile, fields?)`,
`ClientState.waitForProfile(timeout?)`, `ClientState.Notified(payload)`,
`ClientState.PurchaseGranted({ key, kind })`.

## Monetization

`MonetizationConfig` holds the full spec §11 catalogue: 11 passes (`VIP`, `DoubleCash`,
`AutoClicker`, `FastWalk`, `Teleporter`, `LuckyEggs`, `PetSlots`, `TripleHatch`, `AutoHatch`,
`OfflineMax`, `MegaLauncher`) and 24 products (`Cash*` ×4, `Gems*` ×3, `Spins2/5/10`
(paidRandom), `StarterPack` / `SecretPack` (oneTime), `DoubleOffline`, `ServerCash2x`, `Cash2x30`,
`Barrage`, `Shield1h`, `SkipPad`, `AcornsSmall/Large` + `TurkeyLure` (Harvest Feast window),
`CrateSupply` / `CrateMega` / `CrateGolden` (kind `Crate`, category `crates`, 49 / 149 / 399 R$,
paidRandom → PolicyCache gate, `crates = 1` held crate; crate id via `CrateConfig.ByProduct`)).
`PublishedProductIds`: live dashboard ids for all 11 passes + 24 products (published by B15,
2026-10-30); an id of 0 means unpublished → `isProductAvailable` / `isPassAvailable` false →
COMING SOON, never prompted, never matched by a receipt.

`MonetizationService`: `registerProductHandler(kind, fn(player, profile, product, receipt) -> bool)`
(must not yield — enforced), `registerPromptRefusal(kind, fn) -> string?`, `canGrant(kind)`,
`ownsPass(p, key)` (Roblox verdict once known, else last session's cache), `PassChanged(p, key)`,
`promptProduct(p, key, source?)`, `promptPass(p, key, source?)`, `processReceiptAsync`,
`liveReceiptDeps()`, `simulateReceiptAsync(p, key)` (Studio only), `runNoYield`,
`setReceiptAccounting(fn | { onGrant, onDurable })`; signals `PromptShown`, `PromptFinished`,
`ProductGranted`, `PassPurchased`. Built-in kind: `Gems`. New Player Mode: every product / pass
prompt refused (`NewPlayerMode.purchaseGate` toast), receipts of a sandboxed buyer deferred
(`NotProcessedYet`, granted into the real profile after exit / next join), `ownsPass` false in the
mode (brand-new view; sandbox `passes` cache never written; PassChanged fires for every pass that
flips at a swap). Every other kind is granted by its owning
service's handler (B5/B7/B10/B11); until registered it is "coming soon" and receipts stay
`NotProcessedYet`.

## Tests

Lune (`./scripts/test-logic.sh`): `number-format`, `profile-logic` (incl. payDays, pets / crates /
trails / barrage), `profile-store` (JSON mock DataStore: locks, takeover, lost, read-only,
failures, New Player Mode sandbox never written while the parked real session keeps saving),
`profile-sync` (fuzz + bandwidth), `validate` (Validate, RateLimiter, TextUtil, catalogue incl.
crates, remotes), `change-notes`. Studio: `Tests/CoreTests` (`suite = "Core"`: remotes,
catalogue, engine JSON round trip, ProfileStore, receipt idempotency, NewPlayerMode receipt
deferral → granted into the real profile after exit).

## Versions

`VersionConfig.Current = "0.3.0"` (0.1.0 born, 0.2.0 full tycoon, 0.3.0 WHAT'S NEW). The full
WHAT'S NEW system (RoBeasts port, owner R58: notes config, `profile.notes`, `ChangeNotesService`,
returning-player pop-up, bottom-right HUD chip, Settings version label, admin + analytics) is
documented in `docs/change-notes.md`.

## Paid random items (pre-publish compliance, 2026-10-30)

Products flagged `paidRandom = true` in MonetizationConfig (Robux spins, Turkey Lure, crates) are
refused at prompt time for restricted or unknown `PolicyService` results (fail closed). Every
Robux-reachable random roll re-checks policy server-side: cash/acorn eggs, gem + held crates,
paid wheel spins (profile `spin = { free, bonus, paid }`; `bonus` added for free reward spins),
and lured turkeys. Starter/Secret packs stay purchasable; restricted buyers get 40 gems per spin
instead. Details: `docs/pets.md`, `docs/retention.md`, `docs/event.md`, `docs/creator-dashboard.md`.

## W2 worlds-core (owner R57 World 2 "Dino Valley", 2026-10-31)

Spec `docs/superpowers/specs/2026-10-31-world2-design.md` §9–§11, plan §3.2. Main-world
behaviour is unchanged: Nuke Town still lives in the v1 top-level fields.

**Profile schema v2** (`ProfileLogic.SCHEMA_VERSION = 2`, additive):
- `lastWorld` — the world the last session ended in (WorldService writes it). Any well-formed
  world key (`^[a-z][a-z0-9]{0,15}$`) is kept, else `"main"`.
- `worlds = { [worldId] = WorldState }` — NON-main worlds only, ≤ `Limits.MaxWorlds` (8), never
  `"main"`. WorldState = `unlocked, unlockedAt, cash (Bones), totalEarned, tycoon { pads,
  producers, area, standName, lastSaveAt, tutorialStep }, rebirths, rebirthTokens (Amber),
  rebirthShop, stats { playSeconds, runSeconds, visits, padsBought, clicks, lastVisitDay },
  starter { bought }`.
  - **W2 decision:** `starter.bought` was added to the spec §10 shape so the one-time
    `WorldStarter` pack (Time Traveler Pack) has a profile flag, exactly like the main
    `profile.starter.bought`. The W3 handler sets it; MonetizationService refuses the prompt.
  - Every KNOWN world (`WorldGeometry.Order` minus main → `ProfileLogic.KnownWorlds`) is always
    present (default entry in `defaultProfile`, repaired or defaulted by `reconcile`), so services
    can index `profile.worlds.dino` directly. Known worlds clamp `tycoon.area` to their
    `WorldGeometry.areaCount`.
  - Unknown well-formed keys (a newer server's World 3) are KEPT through the same generic
    reconciler (finite, bounded, area ≤ `MaxArea`) and fill the slots left under the cap in key
    order (≤ `MaxWorldCandidates` = 64 examined). Malformed keys, `"main"`, non-table values and
    metatables are dropped.
- `MIGRATIONS[1]` is a no-op: reconcile adds the defaults. A v1 server then sees `"newer"` and
  opens a v2 save read-only (never saves over `worlds`). Owner action at publish: **Migrate to
  Latest Update**. Legacy world unlocks (main area ≥ 3 / a rebirth) are WorldService's job at
  join, not the migration's.
- API: `isWorldKey`, `newWorldState`, `peekWorld(profile, id)` (read-only),
  `worldState(profile, id)` (creates on demand; errors for `"main"` / malformed / past the cap —
  programming errors only), `addWorldCash` / `spendWorldCash` (Bones; also `totalEarned`;
  clamped `MaxCash`; no negative dust), `addWorldTokens` / `spendWorldTokens` (whole).
- Snapshot fields: `worlds` (structure only: unlocked, unlockedAt, tycoon { pads, producers,
  area }, rebirths, rebirthTokens, rebirthShop, stats { visits }, starter { bought }; known worlds
  only), `worldCash = { [id] = { cash, totalEarned } }`, `lastWorld`. `toSave` needs no new
  conversion (string sets + number maps; `scrubNonFinite` covers `worlds.*`).

**Delta sync:** a world currency change marks only `{ "worldCash" }`; world tokens / structure
mark `{ "worlds" }`. Same coalescing as cash: a frame that pays cash AND Bones is one delta.
Measured (tests/profile-sync): cash tick 116 B, Bones tick 141 B (budget 160), cash + Bones tick
180 B (budget 192). `ProfileSyncClient` is field-generic; `ClientState` adds read helpers
`world(id)`, `worldUnlocked(id)` (main always true), `worldCash(id)` → (cash, totalEarned),
`lastWorld()`.

**PlayerDataService currency API:** `grantCurrency(p, key, n, reason)`,
`trySpendCurrency(p, key, n, reason)`, `balance(profile, key)`, `grantWorldTokens(p, world, n,
reason?)`, `trySpendWorldTokens(p, world, n, reason?)`. `"cash"` / `"gems"` delegate to the
existing functions; `"tokens"` (Nuke Town's `tokens.key`) is `profile.rebirthTokens` (marks
`{ "rebirthTokens" }`), so per-world code can pay any `def.tokens.key`; every extra world's
`currency.key` / `tokens.key` (WorldsConfig) routes into `profile.worlds.<id>` (built once at
load; a key colliding with cash / gems / tokens / another world fails at boot). `CurrencyChanged` fires with the key (`"bones"`, `"amber"`); its `Currency` type
is now `string`.

**Remotes** (`Shared/Net/Remotes`): new `TravelWorld` (C→S `worldId, target, index?`) and
`WorldTravel` (S→C `{ worldId, phase, reason?, at }`); doc-only: `Rebirth(worldId?)`,
`RebirthShopBuy(key, worldId?)`, `OfflineEarnings` payload `worlds = { { id, amount } }?`.
**Validate:** `worldId(raw)` (string ≤ 16, `^[a-z][a-z0-9]*$`, `WorldsConfig.get`),
`worldIdOrMain(raw)` (nil → "main"; junk → nil, never main), `travelRequest(world, target,
index)` → `{ worldId, target, index? }` (spawn: no index; area: 1..that world's
`geometry.areaCount`; plot: 1..`WorldLayout.PlotCount`), `rebirthShopBuy(key, world)` → (key,
worldId) against THAT world's `rebirth.Shop`. Handlers (W3 RebirthService, W4 WorldService) call
these first, then their state checks.

**Monetization** (`docs/monetization.md` is GENERATED by `tools/monetization/publish.py`, so the
W2 notes live here):
- Products (spec §9; kinds `WorldCash` / `WorldStarter`, category `dino`, `world = "dino"`):
  `BonesSmall` "Pile of Bones" R$29 (600 s of Dino income, floor 500), `BonesMedium` "Sack of
  Bones" R$79 (1800 s, floor 5K), `BonesLarge` "Crate of Bones" R$199 (7200 s, floor 50K),
  `TimeTravelerPack` R$99 one-time (1200 s, floor 2K, pet `time_ptero`, boost `cash2x` 1800 s).
  NOT `paidRandom` (fixed amounts, fixed pet). Created live 2026-10-30 with
  `publish.py publish` (ids 3724510192 / 3724510147 / 3724510119 / 3724510226; icons
  `BonesPackSmall` / `BonesPack` / `BonesPackLarge` / `TimeTravelerPack`); a re-`plan` is clean.
- `MonetizationConfig`: `ProductDef` gains `world`, `pet`, `boostSeconds`; `REQUIRED_FIELDS`
  `WorldCash = { world, incomeSeconds, cashFloor }`, `WorldStarter = { world, incomeSeconds,
  cashFloor, pet }`; `validate()` now also refuses `oneTime` on kinds without a profile flag
  (only StarterPack / SecretPack / WorldStarter), a `world` that is not a known non-main world,
  and a half-set WorldStarter boost. `robuxWorldCurrencies()` → `{ bones = true }` (world
  currencies Robux can buy).
- **Paid random gate:** Bones are Robux-reachable, so any egg priced in Bones is a paid random
  item. `tests/validate.luau` §6 fails if an egg's currency is in `robuxWorldCurrencies()` but
  `EggConfig.PaidRandomCurrencies[currency] ~= true` (W11 sets `bones = true`).
- `MonetizationService`: a product with `world` is refused at the PROMPT while that world is
  locked ("Unlock Dino Valley first!"); lock truth = the seam
  `MonetizationService.setWorldUnlockCheck(fn)` (W4 installs `WorldService.isUnlocked` in Start;
  run no-yield, failure = locked), fallback = the sticky `worlds.<w>.unlocked` flag. One-time
  `WorldStarter` refused when `worlds.<w>.starter.bought`. Receipts are unchanged: the same
  idempotent ledger / no-yield grant / rollback path; the `WorldCash` / `WorldStarter` grant
  handlers are W3's (`registerProductHandler`); until registered the prompt says "Coming soon!"
  and a receipt stays `NotProcessedYet` (Robux never taken for nothing).

**Tests:** `profile-logic` §12 (v1 → v2 migration of a fully populated v1 save carries every
value; deterministic + idempotent; JSON round trips; v3 → "newer"; hostile worlds repaired;
unknown kept / malformed dropped; cap 8 known-first; area clamps; lastWorld; Bones / Amber math;
snapshot shape), `profile-sync` §8 (fuzz with Bones / Dino pads / lastWorld; tick budgets),
`validate` §6 (world validators, Dino products, Bones-priced eggs gated), `remote-security` §4
(TravelWorld / Rebirth / RebirthShopBuy hostile-argument fuzz in every position, world wallet
junk amounts).
