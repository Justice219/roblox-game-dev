# SellNukes — build plan (2026-10-30)

Spec: `docs/superpowers/specs/2026-10-30-sellnukes-design.md`. Framework source: `~/IdeaProjects/RoBeasts`
(RB below). This plan fixes the **directory layout, file ownership and interface contracts** so
builders can work in parallel. If you need an API that isn't here, add it to the module you own and
note it in your report; never edit a file another builder owns.

## Waves

| Wave | Builder | Owns | Depends on |
|------|---------|------|-----------|
| 1 | **B1 Core** | toolchain, boot, Net, Util, persistence, profile sync, monetization core, version notes | — |
| 1 | **B2 UI kit** | `src/client/UI/**` framework + HUD shell + stud style kit | contracts below (ClientState) |
| 1 | **B3 Tycoon logic** | `src/shared/Tycoon/**`, `src/shared/Config/Tycoon*`, `tests/economy-*` | none (pure) |
| 1 | **B4 Art pipeline** | `tools/blender/**`, `tools/ui/**` (world textures), `assets/**`, `src/shared/Config/MeshAssets.luau`, `src/server/World/MeshLibrary.luau`, `docs/world-art.md` | none |
| 2 | B5 Tycoon server | `src/server/Tycoon/**` (PlotService, TycoonService, Offline, Rebirth), `src/server/World/{HubBuilder,PlotBuilder}.luau` | B1, B3, B4 |
| 2 | B6 Tycoon client | `src/client/Tycoon/**` (BuildIn, billboards, pads, click, teleport, tutorial, rename) | B2, B5 contracts |
| 2 | B7 Retention + shop | daily, time, wheel, codes, group, welcome-back, shop, settings (server + screens) | B1, B2 |
| 2 | B8 Art content | Blender builders for areas 1–10, hub, pets, eggs, crates, nukes, event decor + uploads | B4 |
| 1b | **B13 Analytics** | `src/server/Analytics/**`, `src/server/Services/AnalyticsService.luau`, `src/shared/Analytics/**`, `src/shared/Config/{AnalyticsConfig,AnalyticsMarks}.luau`, `src/client/Analytics/**`, `docs/analytics*.md`, `tests/analytics-*` | B1 hooks |
| 1b | **B15 Icons** | `tools/blender/ui_icons/**`, `tools/ui/icons/**`, `assets/icons/**`, `src/shared/Config/IconAssets.luau` (shape agreed with B2), `docs/icons.md` | — |
| 2 | B14 Admin panel | `src/server/Services/AdminService.luau`, `src/server/Admin/**`, `src/shared/Config/AdminConfig.luau`, `src/shared/Util/NewPlayerMode.luau`, `src/client/UI/Screens/Admin/**`, `docs/admin.md` | B1, B2, B13 |
| 3 | B9 Pets/eggs/crates · B10 Attack mode · B11 Harvest Feast event + leaderboards + badges · B12 live monetization ids + full playtest/perf pass | | |

Workers: never commit (the lead commits per wave), never run `stylua src` / `--fix` on the whole
tree (format only your own files), hold `scripts/studio-lock.py` around Studio playtests, one final
report ≤ 250 words.

## Layout

```
src/server/init.server.luau          B1  ordered service boot (RB pattern: Init() then Start())
src/server/Economy/                  B1  ProfileStore, ProfileLogic, ProfileSyncState, PassOwnership, PolicyCache, ...
src/server/Services/                 B1  PlayerDataService, MonetizationService; later waves add their own services here
src/server/Tycoon/                   B5
src/server/World/                    B4 (MeshLibrary) / B5 (HubBuilder, PlotBuilder)
src/server/Tests/                    B1  TestRunner + TestContext
src/client/init.client.luau          B1  ordered controller boot
src/client/ClientState.luau          B1
src/client/ProfileSyncClient.luau    B1
src/client/Controllers/              B1 (InputController, CameraController stub) / B2 (UIController)
src/client/UI/                       B2  Create, Theme, Components, ScreenManager, Widgets/, Hud/, Screens/
src/client/Tycoon/                   B6
src/shared/Net/                      B1  Remotes, Validate, ProfileDelta, WireSize
src/shared/Util/                     B1  Signal, RateLimiter, Trove, NumberFormat, MathUtil, TextUtil
src/shared/Tycoon/                   B3  TycoonLogic (pure)
src/shared/Config/                   per file owner (see each builder)
tests/*.luau                         lune; each builder owns its own test files
tools/blender, tools/ui, assets/     B4 / B8
```

## Contracts

### Remotes (B1 pre-declares ALL of these in `src/shared/Net/Remotes.luau`; all RemoteEvents)

Core: `ProfileUpdate`, `ProfileDelta`, `ProfileDeltaAck`, `ProfileResync`, `Notify` (s→c toast
`{kind, text, icon?}`), `PromptProduct` (c→s productKey), `PromptPass` (c→s passKey),
`PurchaseGranted` (s→c `{key, kind}`), `SetSetting` (c→s key, value).
Tycoon: `ProducerClick` (c→s producerId), `ProducerUpgrade` (c→s producerId, mode "1"|"10"|"max"),
`PadBuy` (c→s padId — fallback for touch/gamepad when standing on a pad; server re-checks distance),
`RenameStand` (c→s text), `TeleportArea` (c→s areaIndex), `TeleportHub` (c→s), `Rebirth` (c→s),
`RebirthShopBuy` (c→s upgradeKey), `OfflineEarnings` (s→c `{amount, seconds, rate}`),
`IncomePop` (unreliable s→c `{producerId, amount}`), `TutorialState` (s→c `{step}`).
Retention: `ClaimDaily`, `ClaimTimeReward` (index), `SpinWheel` (requestId) / `SpinResult`
(s→c), `RedeemCode` (text) / `CodeResult` (s→c), `ClaimGroupReward` / `GroupRewardResult` (s→c),
`ClaimNotifyReward`.
Pets/crates: `HatchEgg` (eggId, count, requestId) / `HatchResult`, `EquipPet` (uid, on),
`DeletePets` ({uid}), `EquipBest`, `OpenCrate` (crateId, requestId) / `CrateResult`.
Attack: `AttackLaunch` (targetUserId) / `NukeFlight` (s→c all `{id, fromUserId, toUserId, t0,
flight, intercepted, interceptAt}`), `DefenseUpgrade` (kind), `ShieldActivate`.
Event: `EventCollect` (turkeyId), `EventRedeemSheet`, `EventState` (s→c).
Analytics/admin: `FunnelStep` (c→s stepId, payload?), `OffersSeen` (c→s {offerId}), `ClientDevice` (c→s device info), `ClientPerf` (c→s packed perf report), `AnalyticsRequest` (c→s requestId, range) / `AnalyticsReport` (s→c), `AnalyticsRawRequest` (c→s requestId, page) / `AnalyticsRawPage` (s→c), `AdminCommand` (c→s name, args) / `AdminResult` (s→c), `AdminState` (s→c, admins only).

### Profile schema v1 (B1 `ProfileLogic.defaultProfile`)

```lua
{
  schemaVersion = 1,
  cash = 0, gems = 0, totalEarned = 0, -- totalEarned = lifetime cash (leaderboards)
  rebirths = 0, rebirthTokens = 0, rebirthShop = {} :: {[string]: number},
  tycoon = { pads = {} :: {[string]: true}, producers = {} :: {[string]: number}, -- producerId -> level
             area = 1, standName = "", lastSaveAt = 0, tutorialStep = 0 },
  stats = { playSeconds = 0, clicks = 0, padsBought = 0, launches = 0, hits = 0, hatched = 0 },
  passes = {} :: {[string]: true},          -- cache; truth = PassOwnership
  receipts = {} :: {[string]: number},      -- purchaseId -> os.time(); trimmed to newest 64
  pets = { owned = {} :: {[string]: {id: string, locked: boolean?}}, equipped = {} :: {string}, nextUid = 1 },
  boosts = {} :: {[string]: number},        -- boostKey -> expires (os.time)
  daily = { streak = 0, lastDay = -1 },     -- UTC day number
  timeRewards = { day = -1, seconds = 0, claimed = {} :: {[number]: true} },
  spin = { free = 1, lastFreeAt = 0, paid = 0 },
  codes = {} :: {[string]: true},
  group = { claimed = false }, notify = { claimed = false },
  offline = { lastSeenAt = 0 },
  starter = { bought = false }, secretPack = { bought = false },
  attack = { aa = 0, launcher = 0, shieldUntil = 0, cooldownUntil = 0, hitsTaken = 0 },
  event = { season = "", acorns = 0, stickers = {} :: {[number]: true}, redeemed = false },
  settings = { music = true, sfx = true, reducedMotion = false, hideOtherPets = false },
  analytics = { first = 0, last = 0, payFirst = 0, payLast = 0, marks = 0, robux = 0, outbox = {} },
}
```

### Server APIs (B1)

`PlayerDataService`: `getProfile(p)`, `waitForProfile(p, timeout?)`, `canMutate(p)`,
`markChanged(p, saveSoon: boolean?, fields: {string}?)`, `grantCash(p, amount, reason)`,
`trySpendCash(p, amount, reason): boolean`, `grantGems(p, n, reason)`, `trySpendGems`,
`ProfileLoaded: Signal(p, profile)`, `ProfileReleasing: Signal(p, profile)` (fires before final save,
so services can write lastSeenAt etc.), `CurrencyChanged: Signal(p, currency, delta, reason, balance)` (analytics hook; fires for every grant/spend).
`MonetizationService`: `registerProductHandler(kind, fn(player, profile, product, receiptInfo) -> boolean)`,
`ownsPass(p, passKey): boolean`, `PassChanged: Signal(p, passKey)`, `promptProduct(p, key, source?)`,
analytics hooks `PromptShown: Signal(p, key, kind, source)`, `PromptFinished: Signal(p, key, kind, bought)`,
`ProductGranted: Signal(p, key, robux, receiptInfo)`, `PassPurchased: Signal(p, key, robux)`, and
`setReceiptAccounting(fn)` (analytics registers its receipt journal; optional).
`MonetizationConfig.Products[key] = {kind, id, price, ...}`, `.Passes[key] = {id, price, ...}`;
ids live in `PublishedProductIds` (0 = not created yet → UI shows "coming soon", purchase disabled).

### Client APIs (B1/B2)

`ClientState.profile` (latest snapshot table), `ClientState.ProfileChanged: Signal(profile, fields?)`,
`ClientState.waitForProfile()`. `ScreenManager.register(module)`, `.open(name, args?)`, `.close`,
`.toggle`. B2 also exposes `src/client/UI/Kit/StudUI.luau` (window, stud card, stud button with
colour presets `green|yellow|red|blue|purple|orange|grey|rainbow`, red X, starburst offer, money
label) used by every later screen.

### Tycoon (B3 → B5/B6)

`TycoonConfig.Areas[i] = {id, name, producer = {...}, pads = {...}}`, pad
`{id, area, name, kind = "Build"|"Multiplier"|"Speed"|"Manager"|"Unlock"|"Feature", cost, requires: string?,
target: string?, value: number?, build = {meshKey, ...}?}`. `TycoonLogic` pure functions:
`producerOutput(cfg, level, mods)`, `cycleTime(...)`, `upgradeCost(cfg, level, count)`,
`maxAffordable(...)`, `incomePerSecond(profileTycoon, mods)`, `offlineEarnings(...)`,
`rebirthReward(...)`, `padAvailable(profileTycoon, padId)`.

### Meshes (B4 → B5/B8)

`MeshAssets[modelKey] = {pieces = {[pieceName] = {id, size: Vector3, offset: Vector3, color, material}}}`;
`MeshLibrary.spawn(modelKey, parent, pivot: CFrame, opts?) -> Model` (Blender MeshParts if every
piece id is uploaded, else the primitive fallback from the builder's piece boxes), `preload(keys)`.
Visual MeshParts are `CanCollide=false, CanQuery=false, CanTouch=false`; collision is separate
invisible primitive Parts placed by PlotBuilder/HubBuilder.

### World layout (B5 implements `src/shared/Config/WorldLayout.luau`; art builders author against it)

* **Units:** studs. Ground top is `y = 0` everywhere.
* **Hub** at world origin: plaza radius 0–230, ring road 230–260.
* **Plots** `i = 1..8` at yaw `(i-1) * 45°`. Plot origin = `CFrame.Angles(0, yaw, 0) * CFrame.new(0, 0, 260)`.
  **Plot-local frame:** origin at the plot entrance centre (touching the ring road), **+Z points away from
  the hub**, +X is the player's right when walking outward, +Y up. Footprint `x ∈ [-80, 80]`, `z ∈ [0, 520]`.
  Central plot road `x ∈ [-8, 8]` runs the full length. Entrance arch + owner sign at `z ≈ 4`.
  The wedge gaps between plots are decorative (trees, water, hills) and are owned by the hub builder.
* **Area slots** `k = 1..10`: row `r = ceil(k/2)` covers `z ∈ [(r-1)*104, r*104]`. Odd `k` → left side
  `x ∈ [-80, -10]`, even `k` → right side `x ∈ [10, 80]` (zig-zag along the road, like the reference).
  **Slot-local frame:** origin at the slot's road-side edge midpoint (`x = ±10`, `z = (r-0.5)*104`,
  `y = 0`), **+Z_s points away from the road**, +X_s runs along the road (toward the hub = −X_s for
  the left side; B5 computes the CFrame), +Y up. Slot size: `x_s ∈ [-52, 52]`, `z_s ∈ [0, 70]`,
  height budget 80 (area 10 may reach 140). The area faces the road; pads sit in the road-side
  strip `z_s ∈ [2, 16]`; the producer + its billboard in the middle.
* **Layout file per area** (owned by that area's art builder):
  `src/shared/Config/AreaLayouts/AreaNN.luau`
  ```lua
  return {
    area = N,
    base = { models = { {key = "MeshModelKey", cf = CFrame} }, collision = { {size = Vector3, cf = CFrame} } }, -- built with the area unlock (floor, EntryArch)
    builds = { [buildKey] = { models = {...}, collision = {...} } }, -- every `build` key of the area's pads (docs/economy.md)
    pads = { [padId] = Vector3 },          -- slot-local ground position of each pad's BuyPad
    producer = { anchor = Vector3, click = { size = Vector3, cf = CFrame } }, -- billboard anchor + clickable box
    spawnPoint = Vector3,                  -- teleport-to-area target
  }
  ```
  **EntryArch convention (B8a, adopted):** the Unlock pad's build key `A{N+1}_EntryArch` resolves to
  `AreaLayouts/Area{N+1}.base` (that area's floor + arch, built when it unlocks); `AreaNN.builds`
  lists only the area's own `A{N}_*` keys; `Area01.base` is built at plot claim.
  Visible primitive Parts must go through `WorldMaterials.apply` so they match the meshes' studs.
  All CFrames slot-local. Collision boxes are invisible primitive Parts (floors, walls, big machines);
  mesh visuals never collide. Every build key in the area must have an entry (validated by
  `tests/area-layouts.luau`).

## Live assignments (2026-10-30, lead-maintained)

| Teammate name | Current role | Status |
|---|---|---|
| B1-core | wave 1 core → **B7 retention + shop** | core committed (01b6d80, 71da667) |
| B2-ui | wave 1 UI kit → **B6 tycoon client UI** | kit committed (368cc41) |
| B3-tycoon | wave 1 logic → **B5 tycoon server** | logic committed (d785443) |
| B4-art | wave 1 pipeline → **build-in animation + world FX** (`src/client/Tycoon/{BuildIn,Fx}/**`) | pipeline committed (b42a6c7) |
| B13-analytics | analytics | running |
| B15-icons | rendered 3D-look icons | running |
| B8a / B8b / B8c / B8d | Blender areas 1–3 / 4–6 / 7–8 / 9–10 + AreaLayouts | running |
| B8e-art-hub | hub, plot frame, scenery, Harvest decor + HubLayout | running |
| B8f-art-pets | pets, eggs, crates, attack props, event items | running |
| B14-admin | owner admin panel | running |
| B9-pets | pets/eggs/crates systems + UI | running |
| B10-attack | attack mode + AA towers + shields | running |
| B11-event | Harvest Feast event + leaderboards + badges | running |
| B16-platform | console + mobile platform layer (`src/client/Platform/**`) + device-matrix QA | running |
| B17-core | **core maintainer**: owns all B1-era core files (ProfileLogic/Store, PlayerDataService, MonetizationService, Remotes, MonetizationConfig, ClientState); every schema/remote/product request goes to them | running |

The lead owns the boot lists (`src/server/init.server.luau`, `src/client/init.client.luau`),
`.gitignore`, the living doc and all commits.


## Live assignments — round 3 (2026-10-30 evening, after the session-limit restart)

All round-1/2 teammates ended with the session limit. Remaining work consolidated into five
teammates with disjoint ownership (lead owns boot lists, commits, living doc):

| Name | Scope |
|---|---|
| W1-fx | finish the manager-skip in WorldFx (fix `tests/build-in-plan`), Studio fix_check (yaw/groups/glow), World-QA tour + live ZFight + load benchmark; owns BuildIn/Fx/MeshLibrary/MeshPlacement/PreloadList/tools/qa |
| P1-pets | PRE-PUBLISH: paid-random-items gate for every Robux-reachable egg/crate currency (fail closed) + pets Studio check |
| N1-npc | animated manager NPCs (R30); `ManagerNpcConfig` (ManagerKeys, ownsModel); may split manager limbs in Blender |
| A1-art | finish z-fight curved-seam audit, areas 4–6 follow-ups (R17/R18/R19/R31/R32), all z-fights → 0, World-QA art fixes |
| Q1-qa | sole Studio QA sweep of every booted system + device matrix; fixes bugs outside the others' files; core maintainer fallback |

### Round-3 coverage audit (owner R36) — every earlier builder → where its unfinished work went

| Earlier builder | State at the session limit | Round-3 owner |
|---|---|---|
| B1-core → B7 retention/shop (+3 screen sub-agents) | code committed; Studio device-matrix not run | Q1-qa |
| B2-ui → B6 tycoon client, R16/R22/R27/R31/R32 | code committed; Studio check queued | Q1-qa |
| B3-tycoon → B5 tycoon server | round 3 committed; Studio re-run queued | Q1-qa |
| B4-art (pipeline, build-in, FX, audio, glow, yaw, groups) | manager-skip WIP (failing test); fix_check / World-QA / load benchmark not run | W1-fx |
| B8a areas 1–3 · B8c areas 7–8 · B8d areas 9–10 | done (signs double-sided, 0 z-fights) | A1-art (World-QA fixes only) |
| B8b areas 4–6 | WIP: R17/R18/R19/R32 follow-ups; 15 Area 4 models not uploaded | A1-art |
| B8e hub / plot frame / z-fight audit | curved-seam audit WIP (failing test) | A1-art |
| B8f pets/eggs/crates/attack/event art | all 29 pets, 12 eggs, 4 crates, attack + event props uploaded | — (done) |
| B9 pets systems | paid-random gate + Studio check | P1-pets (+ wheel / Turkey Lure gaps) |
| B10 attack mode | booted; Studio check not finished | Q1-qa |
| B11 event + leaderboards + badges | booted; Studio check not run | Q1-qa |
| B13 analytics → movement + wind | booted; Studio check not run | Q1-qa |
| B14 admin | booted; Studio check not run | Q1-qa |
| B15 icons → monetization → brand + loading screen | loading screen now synced; Studio check not run; ad 9 stuck | Q1-qa (loading) · lead (ad 9, ForgeGUI) |
| B16 platform | booted; unwritten phone-cluster regression test; device QA | Q1-qa |
| B17 core maintainer | idle, nothing pending | Q1-qa (fallback) |
| B18 animated managers (R30) | not started | N1-npc |
