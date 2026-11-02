# SellNukes — World 2 "Dino Valley" + worlds framework: build plan (2026-10-31)

Spec: `docs/superpowers/specs/2026-10-31-world2-design.md` (read it first; section numbers below
refer to it). This plan does two things:
* It fixes the **file ownership, interface contracts, tests and order**, so up to 8 builders can
  work at once without touching the same file.
* It follows the style of `2026-10-30-sellnukes-build.md`. Every rule there still applies:
  * never commit (the lead commits)
  * format only your own files
  * hold `scripts/studio-lock.py` around playtests, and never stop a playtest you did not start
  * never open another place (R33)
  * subagents have no Serena: use `grep -n` / `sed -n` excerpts
  * send ONE final report of ≤ 250 words

If you need an API that is not here, add it to a module **you own** and note it in your report.
If it must live in another builder's file, message that builder (SendMessage) with the exact
signature; never edit their file. Docs are **append-only sections** headed with your role name.

**North star:** after this wave, World 3 = config + art (spec §18). Every list of worlds comes from
`WorldsConfig.Order`. Every pad, producer and build-key id is globally unique and prefixed, so a
bare id always tells you its world.

---

## 1. Roles, ownership, waves

| Wave | Role (suggested name) | Owns (exclusive) | Depends on |
|---|---|---|---|
| A | **W1 worlds-logic** | `src/shared/Tycoon/{EconomyIndex (new), TycoonLogic, Modifiers, TycoonTypes}.luau`, `src/shared/Config/{TycoonConfig, RebirthConfig, WorldLayout}.luau`, `src/shared/Config/Worlds/**` **except** `Worlds/Dino/Layouts/**` and `Worlds/Dino/ValleyLayout.luau`, `tests/{economy-index (new), worlds-config (new), world-frames (new), tycoon-logic, economy-sim}.luau`, `docs/economy.md`, `docs/worlds.md` (new, framework section) | — |
| A | **W2 worlds-core** | `src/server/Economy/{ProfileLogic, ProfileSyncState}.luau`, `src/server/Services/{PlayerDataService, MonetizationService}.luau`, `src/shared/Net/{Remotes, Validate}.luau`, `src/shared/Config/{MonetizationConfig, PublishedProductIds}.luau`, `src/client/{ClientState, ProfileSyncClient}.luau`, `tests/{profile-logic, profile-sync, validate, remote-security}.luau`, `docs/core.md`, `docs/monetization.md` | world ids + currency keys from this plan only |
| A | **W6 art-d12** | `tools/blender/models/dino_area01.py`, `dino_area02.py`, `tools/blender/studio/spawn_dino_area0{1,2}.luau`, `src/shared/Config/Worlds/Dino/Layouts/Area0{1,2}.luau`, `tests/{zfight-audit, glow-budget, mesh-assets}.luau` (make them iterate every world's layouts — first task) | spec §6.2 / §16 build keys |
| A | **W7 art-d34** | `dino_area03.py`, `dino_area04.py`, previews, `Worlds/Dino/Layouts/Area0{3,4}.luau` | same |
| A | **W8 art-d56** | `dino_area05.py`, `dino_area06.py`, previews, `Worlds/Dino/Layouts/Area0{5,6}.luau` | same |
| A | **W9 valley-hub-art** | `tools/blender/models/{dino_valley, hub_time_machine, shop_props_dino}.py`, `src/shared/Config/Worlds/Dino/ValleyLayout.luau`, `src/shared/Config/HubLayout.luau` (**only** the Time Machine placement + `anchors.WorldPortals`), `tools/blender/ui_icons/**` new icons + `src/shared/Config/IconAssets.luau` entries, `src/shared/Config/{SoundAssets, AudioConfig}.luau` entries, `tests/{valley-layout (new), hub-layout}.luau`, docs sections in `areas-art.md`, `icons.md`, `audio.md` | spec §16 |
| A→C | **W11 dino-pets** | `tools/blender/models/{pets_dino, eggs_dino}.py`, `src/shared/Config/{PetConfig, EggConfig, PetAnimConfig}.luau`, `src/server/Pets/**`, `src/server/Services/PetService.luau`, `src/client/Pets/**`, `src/client/UI/Screens/{EggHatch, Pets}/**`, `tests/{pets-logic, pets-policy, pets-crates, pet-anim, pet-models-load, hatch-anim}.luau`, `docs/{pets, pets-art}.md` | art: none; config: W1 (`WorldsConfig`); stands: W9 anchors |
| B | **W3 worlds-tycoon-server** | `src/server/Tycoon/{TycoonService, RebirthService, OfflineService, ModifierSources, TycoonRules, TycoonAnalytics, TycoonAdmin, TycoonTests, AreaLayouts, LayoutLogic, PlaceholderLayouts}.luau`, `src/server/World/PlotBuilder.luau`, `src/shared/World/PreloadList.luau`, `tests/{area-layouts (first task: world-aware), tycoon-server-logic, preload-list, build-in-plan}.luau`, `docs/tycoon-server.md` | W1, W2 |
| B | **W4 worlds-travel** | `src/server/Tycoon/{WorldService, TravelRules}.luau` (new), `src/server/Tycoon/PlotService.luau`, `src/server/World/HubBuilder.luau`, `src/server/Admin/Handlers/MultiWorldHandlers.luau` (new), `src/server/Admin/Seams.luau` (world seam only), `src/server/Services/AdminService.luau` (install line only), `src/shared/Config/AdminConfig.luau` (World* commands), `tests/{world-travel (new), admin-validate, admin-pipeline}.luau`, `docs/admin.md` (World commands section) | W1, W2, W3 API (§3.3) |
| B | **W5 worlds-ui** | `src/client/Worlds/**` (new: `WorldClient`, `WorldObjectives`), `src/shared/Config/{WorldClientConfig (new), CurrencyFlyConfig, ShopConfig}.luau`, `src/client/UI/Screens/{Teleport, Rebirth, WelcomeBack, Shop, WorldTravel (new), WorldUnlocked (new)}/**`, `src/client/UI/Hud/{Hud, HudCurrency, HudButtons, HudObjective, HudOffers, CurrencyFly, CurrencyFlyRules}.luau`, `tests/{world-client (new), currency-fly, hud-cluster}.luau`, `docs/ui.md` section | W2 (ClientState fields, remotes); W1 (`WorldsConfig`) |
| C | **W10 worlds-tycoon-client** | `src/client/Tycoon/**` (incl. `BuildIn`, `Fx`, `Npc`; new `WorldLookup.luau`), `src/shared/Config/{BillboardSpots, VehicleRouteConfig, WorldFxConfig, ManagerNpcConfig, BuildInConfig, TycoonClientConfig}.luau`, `tools/billboards/**`, `tests/{billboard-clearance, vehicle-routes, npc-logic, view-cone}.luau`, `docs/{build-in, managers, tycoon-client}.md` sections | W3 (attributes / tree), W6–W8 layouts |
| C | **W12 worlds-analytics-qa** | `src/shared/Config/{AnalyticsConfig, AnalyticsMarks, LeaderboardConfig, BadgeConfig}.luau`, `src/server/Analytics/**`, `src/server/Services/{AnalyticsService, LeaderboardService, BadgeService}.luau`, `src/server/Admin/AdminStatePush.luau`, `src/client/UI/Screens/Admin/**`, `src/client/{Analytics, Leaderboards}/**`, `tests/{analytics-*, leaderboard-logic, event-badges}.luau`, `tools/qa/world2_check*.{py,luau}` (new), `docs/{analytics, leaderboards}.md` sections, `docs/verification/world2/**` | **first task (wave B start):** land the `worlds` family + `bones` / `amber` currency keys + Dino id allowlist in `AnalyticsConfig`, so W3/W4 recorders are never refused |
| — | **Lead** | `src/server/init.server.luau`, `src/client/init.client.luau`, `src/shared/Config/{VersionConfig, ChangeNotesConfig}.luau`, `SELLNUKES_CLAUDE_DOCUMENTATION.md`, `docs/owner-requests.md`, `.gitignore`, all commits | — |

**Concurrency:**
* Wave A runs 7 builders at once. W1 and W2 are short and land first; art (W6–W9, W11 art) runs
  the whole time.
* Wave B starts each role as soon as its inputs land: W3 after W1 + W2; W4 after W3's §3.3 API
  stubs; W5 after W2; W12's analytics keys at the start of B.
* Wave C (W10, W11 systems, W12 QA) starts once the art layouts for D1–D6 and W3 are in.
* This keeps ≤ 8 builders active.

**Generated / shared files** (no owner edits them by hand):
* `src/shared/Config/MeshAssets.luau`: `sync_meshes.py`, protected by the manifest lock.
* `BillboardSpots.luau`: the generator, W10 only.

---

## 2. Directory additions

```
src/shared/Config/Worlds/
  WorldGeometry.luau          W1  pure geometry rows per world (no economy requires)
  WorldsConfig.luau           W1  the registry: Order, Worlds, lookups, unlock + link maths
  MainWorld.luau              W1  wraps TycoonConfig / RebirthConfig / HubLayout as a WorldDef
  Dino/
    DinoWorld.luau            W1  WorldDef "dino"
    DinoRebirth.luau          W1  RebirthDef (Amber shop)
    Areas/Area01..06.luau     W1  AreaConfig (prefixed ids, SCALE tuned by the sim)
    Layouts/Area01..06.luau   W6/W7/W8  AreaLayout (slot-local, same contract as AreaLayouts/AreaNN)
    ValleyLayout.luau         W9  HubLayout-shaped, WORLD-LOCAL (relative to the world origin)
src/shared/Tycoon/EconomyIndex.luau   W1
src/shared/Config/WorldClientConfig.luau   W5
src/server/Tycoon/WorldService.luau, TravelRules.luau   W4
src/server/Admin/Handlers/MultiWorldHandlers.luau      W4
src/client/Worlds/WorldClient.luau, WorldObjectives.luau  W5
src/client/UI/Screens/WorldTravel/, WorldUnlocked/     W5
src/client/Tycoon/WorldLookup.luau                     W10
tools/blender/models/dino_*.py, hub_time_machine.py, pets_dino.py, eggs_dino.py, shop_props_dino.py
tools/qa/world2_check.py (+ _client.luau)              W12
```

---

## 3. Contracts

### 3.1 Shared (W1)

```lua
-- Shared/Config/Worlds/WorldGeometry.luau (no requires; WorldLayout depends on it)
export type Geometry = {
  id: string, origin: CFrame, areaCount: number, plotLength: number, -- 104 * ceil(areaCount / 2)
  finaleArea: number, finaleHeight: number, boundaryRadius: number, sceneryRadius: number,
}
WorldGeometry.Order: { string }                    -- { "main", "dino" }
WorldGeometry.get(worldId: string): Geometry?     -- main: origin identity, 10 areas, 520, finale 10 / 140, 880, 2000
                                                   -- dino: CFrame.new(6000, 0, 0), 6 areas, 312, finale 6 / 140, 650, 950

-- Shared/Tycoon/EconomyIndex.luau (the body of today's TycoonConfig.buildIndexes, generalised)
export type EconomySpec = {
  worldId: string, idPrefix: string,               -- "" for main (legacy ids), "d" for dino
  areas: { AreaConfig }, pacing: { TargetMinutes: { number }, Tolerance: number },
  allowedFeatures: { [FeatureKey]: true },         -- main: all four; dino: { Rebirth = true }
}
export type EconomyIndex = {                       -- exactly today's TycoonConfig lookup fields:
  WorldId: string, Areas, PadOrder, PadsById, PadIndex, Producers, ProducersById, PadsByTarget,
  ManagerPadOf, ProducerBuiltBy, AreaPads, FeaturePadOf, FinalePadId, Pacing,
  -- shared tunables (same table refs as TycoonConfig's): MilestoneEvery, MilestoneFactor,
  -- CycleFloor, MaxLevel, MaxBulkLevels, Offline, Modifiers
}
EconomyIndex.build(spec: EconomySpec): EconomyIndex   -- validates (errors loudly), friendlyPrice, deep-freezes
EconomyIndex.friendlyPrice(x: number): number         -- moved; TycoonConfig.friendlyPrice re-exports it
-- Prefix rule (non-empty idPrefix <p>, e.g. "d"): pad ids ^<p>%d+_[a-z0-9_]+$ ("d3_wind_sock"),
-- producer ids ^<p>p%d+_[a-z0-9_]+$ ("dp3_ptero_express"), build keys ^<P>%d+_%w+$ with <P> = upper(<p>)
-- ("D3_WindSock"; an Unlock pad's key is the NEXT area's "D4_EntryArch").

-- Shared/Config/TycoonConfig.luau: same public fields and values as today, now built by
-- EconomyIndex.build({ worldId = "main", idPrefix = "", ... }). tests/economy-index.luau proves parity.

-- Shared/Config/RebirthConfig.luau: export type RebirthDef = { BonusPerRebirth, MaxRebirths, Tokens, Shop, ShopOrder }
-- (RebirthConfig itself is the main RebirthDef; behaviour unchanged.)

-- Shared/Tycoon/TycoonLogic.luau
export type Logic = { worldId: string, index: EconomyIndex, rebirth: RebirthDef,
  -- every existing function with its existing signature:
  producerOutput, cycleTime, clickValue, clickCycleTime, milestoneMultipliers, milestoneBadge,
  padMultipliers, producerStats, upgradeCost, maxAffordable, incomePerSecond, offlineLimits,
  offlineEarnings, ownsPad, levelOf, isAutomated, padAvailable, nextPads, areaProgress, areaUnlocked,
  hasFeature, newState, applyPad, applyLevels, totalLevels, canRebirth, rebirthReward,
  rebirthMultiplier, rebirthShopCost, rebirthShopEffect, startingCash }
TycoonLogic.bind(index: EconomyIndex, rebirth: RebirthDef): Logic   -- closures built once
TycoonLogic.forWorld(worldId: string): Logic   -- cached; lazily requires WorldsConfig; errors on unknown id
-- TycoonLogic.<fn> stays exactly forWorld("main").<fn> (every existing caller unchanged).
-- offlineLimits on every Logic reads the PLAYER-level main shop keys (offlineHours / offlineRate);
-- callers always pass profile.rebirthShop (main).

-- Shared/Tycoon/Modifiers.luau
Modifiers.resolve(mods: any, rebirth: RebirthDef?): ResolvedModifiers   -- rebirth defaults to RebirthConfig
Modifiers.rebirthMultiplier(rebirths, shop, rebirth: RebirthDef?): number
Modifiers.shopLevel(shop, key, rebirth: RebirthDef?) / shopEffect(key, level, rebirth: RebirthDef?)
-- TycoonTypes.Modifiers gains `linkCash: number?` (>= 1, clamped to MaxMultiplier); resolved.cash *= linkCash.

-- Shared/Config/WorldLayout.luau: every helper gains an OPTIONAL trailing `worldId: string?`
-- (nil = "main", so existing calls are unchanged):
plotOrigin(index, worldId?) = WorldGeometry.origin * (today's formula)
slotLocal(area, worldId?), slotOrigin(plot, area, worldId?), slotToWorld(plot, area, cf, worldId?),
slotPointToWorld(...), plotToWorld(plot, cf, worldId?), entranceSpawn(plot, worldId?),
inSlot(area, point, margin?, worldId?)            -- finale height per world
plotAt(position, worldId?)                        -- nil worldId keeps today's main-only search
WorldLayout.worldAt(position: Vector3): string?   -- disc test against every geometry's sceneryRadius
WorldLayout.toWorld(worldId: string, worldLocal: CFrame): CFrame  -- ValleyLayout → workspace
WorldLayout.areaCount(worldId?): number; WorldLayout.plotLength(worldId?): number

-- Shared/Config/Worlds/WorldsConfig.luau
export type CurrencyDef = { key: string, name: string, icon: string, color: Color3, style: "money" | "count" }
export type UnlockRule = { kind: "always" } | { kind: "progress", world: string, area: number, orRebirths: number? }
export type LinkDef = { toMainPerRebirth: number, toMainMaxRebirths: number,
                        fromMainPerRebirth: number, fromMainMaxRebirths: number }
export type WorldDef = {
  id: string, order: number, name: string, tagline: string, idPrefix: string,
  currency: CurrencyDef, tokens: CurrencyDef,     -- main: cash / "Rebirth Tokens"; dino: bones / amber
  economy: EconomyIndex, rebirth: RebirthDef, geometry: Geometry,
  unlock: UnlockRule, link: LinkDef?,              -- nil for main
  features: { tutorial: boolean, knockdown: boolean, standName: boolean, attack: boolean, leaderstats: boolean },
  layoutFolder: { string },                       -- path under ReplicatedStorage.Shared.Config: {"AreaLayouts"} | {"Worlds","Dino","Layouts"}
  hubLayout: { string },                          -- {"HubLayout"} | {"Worlds","Dino","ValleyLayout"}
  portalAnchor: string?,                          -- key in HubLayout.anchors.WorldPortals (non-main)
  ambience: { lighting: string, music: string },  -- WorldClientConfig preset keys
  eggs: { string },                               -- egg ids sold in this world's hub
}
WorldsConfig.MAIN = "main"
WorldsConfig.Order: { string }                   -- { "main", "dino" }
WorldsConfig.Worlds: { [string]: WorldDef }
WorldsConfig.get(id: unknown): WorldDef?
WorldsConfig.extra(): { WorldDef }               -- every non-main world, in order
WorldsConfig.worldOfPad(padId: unknown): string?
WorldsConfig.worldOfProducer(producerId: unknown): string?
WorldsConfig.worldOfBuildKey(key: unknown): string?
WorldsConfig.worldOfCurrency(currencyKey: unknown): string?   -- "bones" -> "dino", "cash" -> "main"
WorldsConfig.unlockPasses(def: WorldDef, progress: { [string]: { area: number, rebirths: number } }): boolean
WorldsConfig.linkCash(worldId: string, rebirthsByWorld: { [string]: number }): number   -- spec §6.5, pure
-- Load-time validation: ids / currency keys / prefixes unique across worlds, geometry.areaCount ==
-- #economy.Areas, link caps finite, unlock rules reference a known world + area in range.
```

Dino data (W1, exact values from spec §6): `DinoWorld` (id "dino", order 2, name "Dino Valley",
prefix "d", currency `{key="bones", name="Bones", icon="Bones"}`, tokens
`{key="amber", name="Amber", icon="Amber"}`, unlock `{kind="progress", world="main", area=3,
orRebirths=1}`, link `{0.10, 20, 0.05, 10}`, features all false, ambience `{"dino", "music_dino_valley"}`,
eggs `{"dino_egg", "volcano_egg"}`); `DinoRebirth` (BonusPerRebirth 0.5, Tokens
`{Base=10, LevelsPerToken=25, GrowthPerRebirth=0.1}`, Shop clickPower / managerSpeed / startingCash
/ rebirthPower per spec §6.4); `Areas/Area01..06` (59 pads, spec §6.2 table, baseCycle 1 / 1.5 / 2 /
2.5 / 3.5 / 5, pacing `{10, 18, 24, 28, 32, 38}`).

### 3.2 Profile, data service, remotes, products (W2)

```lua
-- ProfileLogic: SCHEMA_VERSION = 2; MIGRATIONS[1] = function(data) end (reconcile fills defaults)
export type WorldState = {
  unlocked: boolean, unlockedAt: number, cash: number, totalEarned: number,
  tycoon: TycoonState, rebirths: number, rebirthTokens: number, rebirthShop: { [string]: number },
  stats: { playSeconds: number, runSeconds: number, visits: number, padsBought: number, clicks: number, lastVisitDay: number },
}
profile.worlds: { [string]: WorldState }   -- keys ^[a-z][a-z0-9]{0,15}$, <= 8, never "main"
profile.lastWorld: string                  -- reconciled: must match the key pattern, else "main"
ProfileLogic.newWorldState(): WorldState
ProfileLogic.worldState(profile, worldId: string): WorldState     -- creates the default entry on demand
ProfileLogic.addWorldCash(profile, worldId, value: number): number    -- also totalEarned; clamped MaxCash
ProfileLogic.spendWorldCash(profile, worldId, value: number): boolean
-- reconcile: every well-formed key is kept (unknown worlds too: bounded, finite, area 1..MaxArea);
-- toSave: plain (string sets + number maps already JSON-safe); scrubNonFinite covers worlds.*
-- snapshot builders: worlds (structure: unlocked, unlockedAt, tycoon{pads, producers, area},
--   rebirths, rebirthTokens, rebirthShop, stats{visits}), worldCash ({[id] = {cash, totalEarned}}), lastWorld

-- PlayerDataService (currency-generic API; "cash" / "gems" delegate to the existing functions)
PlayerDataService.grantCurrency(p: Player, currency: string, amount: number, reason: string): number
PlayerDataService.trySpendCurrency(p: Player, currency: string, amount: number, reason: string): boolean
PlayerDataService.balance(profile: any, currency: string): number
-- world currencies resolve through WorldsConfig.worldOfCurrency; markChanged(p, false, {"worldCash"});
-- CurrencyChanged fires with the currency key ("bones") like every other currency.
-- Rebirth tokens of a world: grantWorldTokens(p, worldId, n) / trySpendWorldTokens(p, worldId, n)
--   (field "worlds" marked changed).

-- Remotes.luau (all RemoteEvents)
"TravelWorld"    -- C→S (worldId: string, target: "spawn" | "area" | "plot", index: number?)
"WorldTravel"    -- S→C ({ worldId: string, phase: "out" | "in" | "fail", reason: string?, at: number })
-- doc-only changes: "Rebirth" C→S (worldId: string?) · "RebirthShopBuy" C→S (upgradeKey: string, worldId: string?)
-- "OfflineEarnings" S→C payload gains worlds: { { id: string, amount: number } }?
-- Validate.worldId(raw: unknown): string?   -- string, <= 16 chars, WorldsConfig.get(raw) ~= nil

-- MonetizationConfig (spec §9): BonesSmall / BonesMedium / BonesLarge
--   { kind = "WorldCash", world = "dino", incomeSeconds, cashFloor, price, icon = "BonesPack", category = "dino" }
-- TimeTravelerPack { kind = "WorldStarter", world = "dino", incomeSeconds = 1200, cashFloor = 2000,
--   pet = "time_ptero", boostKey = "cash2x", boostSeconds = 1800, oneTime = true, price = 99 }
-- REQUIRED_FIELDS gains WorldCash = { "world", "incomeSeconds", "cashFloor" },
--   WorldStarter = { "world", "incomeSeconds", "cashFloor", "pet" }. Ids 0 until created.
-- MonetizationService.registerProductHandler("WorldCash" | "WorldStarter", ...) handlers are W3's;
-- prompt refusal hook: refused while WorldsConfig world locked for the player (W4 provides
-- WorldService.isUnlocked via a seam registered in Start, W2 calls it if present).

-- ClientState: profile.worlds / profile.worldCash / profile.lastWorld mirrored; ProfileChanged fields include them.
```

### 3.3 Server tycoon (W3) — world runtimes

```lua
-- TycoonService (one runtime per (player, worldId); main behaviour unchanged)
TycoonService.ensureWorld(player: Player, worldId: string, buildPlot: boolean): boolean
  -- idempotent; one in-flight per (player, world); runtime without plot when buildPlot = false;
  -- yields while restoring; false if no main plot / stale / world unknown
TycoonService.isWorldBuilt(player: Player, worldId: string): boolean
TycoonService.incomePerSecond(player, worldId: string?): number      -- nil = main (unchanged)
TycoonService.getModifiers(player, worldId: string?): Modifiers?
TycoonService.nextPad(player, worldId: string?): PadConfig?
TycoonService.hasFeature(player, feature: string, worldId: string?): boolean
TycoonService.resetRun(player, animate: boolean?, worldId: string?)
TycoonService.markDirty(player, worldId: string?)                    -- nil = every world of the player
TycoonService.purchasePad(player, padId, opts?)                     -- world resolved from padId
TycoonService.WorldPadBought: Signal(player, worldId, padId, skipped)   -- non-main worlds only
TycoonService.WorldAreaReached: Signal(player, worldId, area)           -- non-main worlds only
-- PadBought / AreaReached keep firing for main only (existing listeners stay correct).
-- Remote handlers ProducerClick / ProducerUpgrade / PadBuy resolve the world from the id.
-- Tick: one loop over every runtime; grantCurrency(world.currency.key, total, "producer");
-- IncomePop + CycleStart anchor writes only when Player.CurrentWorld == runtime world.
-- Main-only behaviour gated by world.features (tutorial, knockdown, standName, leaderstats).
-- Player attributes per non-main world w: IncomePerSecond_<w>, TycoonArea_<w>, FeatureRebirth_<w>.
-- Product handlers: "WorldCash" (TycoonRules.cashPackAmount with that world's idle income) and
-- "WorldStarter" (currency + PetGrants seam + BoostService grant); SkipPad buys the next pad of
-- WorldService.currentWorld(player).

-- RebirthService
RebirthService.applyRebirth(profile, worldId: string?): number   -- nil = main (unchanged)
RebirthService.WorldRebirthed: Signal(player, worldId, count)    -- non-main; Rebirthed stays main
-- After any rebirth: ModifierSources.invalidate(player) (linkCash changes the other world).

-- OfflineService: payOnJoin also pays every unlocked non-main world (same elapsed, cap, rate from
-- main shop + pass; offline-mode modifiers of that world); pending = { main, worlds = {[w] = amount} };
-- DoubleOffline doubles every pending entry once.

-- ModifierSources.build(player, profile, offline: boolean?, worldId: string?) -> (Modifiers, validUntil?)
--   rebirths / rebirthShop from that world's track; linkCash = WorldsConfig.linkCash(worldId, counts)

-- PlotBuilder
PlotBuilder.world(worldId: string): WorldPlotBuilder   -- same function set as today, bound to the world
-- PlotBuilder.<fn> == PlotBuilder.world("main").<fn>. Main tree unchanged (Workspace.Plots/PlotN,
-- plus attribute WorldId = "main"); other worlds: Workspace.Worlds.<id>.Plots.PlotN (WorldId = <id>),
-- frames from that world's hubLayout.plotFrame / lockedSlot.
PlotBuilder.createWorldPlots(worldId: string)          -- 8 empty frames at boot (non-main)
-- Handlers keep their signatures; the pad / producer id tells TycoonService the world.

-- AreaLayouts.get(area, worldId?) / source(area, worldId?) / meshKeys(area, worldId?)
-- LayoutLogic + PlaceholderLayouts take the world's geometry (height budget, area count).
-- PreloadList.world(worldId, tycoonState?): { string }   -- keys to preload on travel
```

### 3.4 Travel + world service (W4)

```lua
-- WorldService (boot after Tycoon/RebirthService)
WorldService.currentWorld(player: Player): string            -- server truth; "main" default
WorldService.isUnlocked(player: Player, worldId: string): boolean
WorldService.unlock(player: Player, worldId: string, source: "area" | "rebirth" | "legacy" | "admin"): boolean
WorldService.travel(player: Player, worldId: string, target: "spawn" | "area" | "plot", index: number?,
                    source: "portal" | "menu" | "popup" | "chip" | "admin" | "respawn"): (boolean, string?)  -- yields
WorldService.respawnCFrame(player: Player): CFrame?          -- PlotService.onCharacterAdded asks first
WorldService.isEnabled(worldId: string): boolean
WorldService.setEnabled(worldId: string, on: boolean)        -- ReplicatedStorage attr WorldEnabled_<id>
WorldService.Unlocked: Signal(player, worldId)
WorldService.WorldChanged: Signal(player, worldId, previous)
-- Owns: Player attr CurrentWorld; profile.lastWorld (written on travel + ProfileReleasing);
-- worlds.<w>.stats (visits, lastVisitDay, playSeconds / runSeconds via ONE 1 Hz loop);
-- ensureWorld(player, w, false) at join for unlocked worlds; portal triggers + prompts.

-- TravelRules (pure; tests/world-travel.luau)
export type TravelContext = { worldId: string?, target: string?, index: number?, now: number,
  enabled: boolean, unlocked: boolean, hasPlot: boolean, revealed: boolean, alive: boolean,
  busy: boolean, cooldownUntil: number, areaUnlocked: boolean?, plotOwned: boolean?, ownPlot: boolean?,
  hasTeleporter: boolean, areaCount: number }
TravelRules.check(ctx: TravelContext): (boolean, TravelReason?)
export type TravelReason = "unknownWorld" | "badTarget" | "disabled" | "locked" | "noPlot" | "revealPending"
  | "dead" | "busy" | "cooldown" | "areaLocked" | "plotEmpty" | "noPass"
TravelRules.CooldownSeconds = 2; TravelRules.DeadlineSeconds = 4; TravelRules.StreamTimeout = 3

-- HubBuilder.buildWorld(worldId: string): Model     -- Workspace.Worlds.<id>.Hub from hubLayout (WorldLayout.toWorld)
-- HubBuilder.getWorldPortal(worldId: string, side: "main" | "world"): { trigger: BasePart, prompt: ProximityPrompt }?
-- PlotService: claim / release apply to plot i of every world (owner sign, clear); respawn via WorldService;
--   TeleportPlot unchanged (main); the Valley's 8 plot pads use the same portal handler, world-bound.

-- Admin (AdminConfig + MultiWorldHandlers, provider "Worlds (W4 MultiWorldHandlers)"): spec §13 list;
-- world arg = { kind = "enum", values = WorldsConfig ids minus "main" }; all audited; destructive
-- ones confirm + red.
```

**HubLayout / ValleyLayout anchor contract (W9 authors, W4 builds):**

```lua
export type PortalAnchor = { model: string, cf: CFrame, trigger: { cf: CFrame, size: Vector3 },
                             prompt: CFrame, sign: CFrame, arrive: CFrame }
HubLayout.anchors.WorldPortals = { dino = PortalAnchor }        -- main hub, WORLD space
-- ValleyLayout (WORLD-LOCAL; same shape as HubLayout): version, spawn, models, collision,
-- plotFrame (plot length 312), lockedSlot, deferredKeys, anchors = { SpawnPoint, ReturnPortal: PortalAnchor,
-- PlotTeleportPads (8), EggStands (2, EggStandAnchor shape), Leaderboards (1), TitleSign, AmbientFx }
```

### 3.5 Client (W5, W10)

```lua
-- Client/Worlds/WorldClient (W5; boot after ClientState, before UI screens that read it)
WorldClient.current(): string                        -- Player attr CurrentWorld, default "main"
WorldClient.Changed: Signal(worldId, previous)
WorldClient.isUnlocked(worldId: string): boolean     -- ClientState.profile.worlds
WorldClient.travel(worldId: string, target: string, index: number?, source: string)  -- client throttle 1/s
-- Applies WorldClientConfig.Lighting[preset] (Atmosphere, ColorCorrection, Ambient; never ClockTime),
-- restores the captured main preset; switches music; preloads PreloadList.world on "out";
-- opens WorldTravel overlay; toasts WorldClientConfig.FailText[reason].
-- Client/Worlds/WorldObjectives (pure): next(state: TycoonState, worldId): { text: string, padId: string? }?

-- WorldClientConfig: Lighting presets, Overlay { MinSeconds = 1.2, FadeSeconds = 0.35 }, Tabs (labels,
-- icons per world), FailText per TravelReason, RejoinChipSeconds = 20.

-- Client/Tycoon/WorldLookup (W10)
WorldLookup.pad(padId): (string?, PadConfig?)              -- worldId + config
WorldLookup.producer(producerId): (string?, ProducerConfig?)
WorldLookup.logic(worldId): TycoonLogic.Logic
WorldLookup.currencyOf(id): CurrencyDef                    -- billboards / pops show the right icon
-- TycoonContract gains Names.WorldsFolder = "Worlds", Attr.WorldId; plot discovery covers both trees.
-- BillboardSpots gains `worlds = { [worldId] = { [area] = { desktop, device } } }` (main table unchanged).
-- VehicleRouteConfig / WorldFxConfig / ManagerNpcConfig rows gain an optional `world` field (nil = main).
```

### 3.6 Pets (W11)

```lua
-- EggConfig rows: { id = "dino_egg", currency = "bones", world = "dino", area = 2, stand = "dino:EggStands1", ... }
--                 { id = "volcano_egg", currency = "bones", world = "dino", area = 5, stand = "dino:EggStands2", ... }
-- price = friendlyPrice(PriceUnits * WorldsConfig.get("dino").economy.Areas[area].producer.baseCost)
-- EggConfig.PaidRandomCurrencies.bones = true (validated: every currency classified)
-- PetConfig: 8 dino pets + time_ptero (spec §8 names, rarities, tiers); PetAnimConfig rigs
-- PetService: stand position = WorldLayout.toWorld(world, anchor.cf); unlock = WorldService.isUnlocked +
--   worlds.<w>.tycoon.area >= egg.area; spend via PlayerDataService.trySpendCurrency("bones", ...)
-- PetGrants.grantFixed(player, petId, reason) seam for the Time Traveler Pack (W3 calls it)
```

### 3.7 Analytics (W12; keys exactly as spec §12)

`AnalyticsConfig.Families` adds `"worlds"`, which also goes in `RecorderFamilies`. Metrics docs
cover every key pattern in spec §12. The `<currency>` allowlist adds `bones` and `amber`. Pad /
producer allowlists read `WorldsConfig`. Recorders: `AnalyticsService.worlds(player, key, amount?)`.
Creator Dashboard forwarder entries: progression path "Dino Valley", funnel "DinoValley", economy
currency "Bones". `ClientPerf` gains `world`.

---

## 4. Builder task lists (acceptance = tests green + listed Studio check + report)

**W1 worlds-logic (wave A, lands first)**
1. `EconomyIndex.build` extracted from `TycoonConfig`. `TycoonConfig` rebuilt on it with
   **bit-identical** output (`tests/economy-index.luau` compares every field and price against a
   frozen snapshot of today's tables).
2. `TycoonLogic.bind / forWorld`. The module functions delegate to main.
   `tests/tycoon-logic.luau` runs its whole suite (incl. purchase monotonicity) once per world,
   with `linkCash` variants added.
3. `Modifiers` gains the rebirth-def parameter + `linkCash`. `RebirthDef` type.
4. `WorldGeometry`, world-aware `WorldLayout` (optional params) and
   `tests/world-frames.luau`, which checks:
   * all 8 plots × every world frame round-trips
   * no two worlds' scenery discs come within 3000 studs
   * `worldAt` is correct
   * main results are identical to today
5. `WorldsConfig`, `MainWorld`, `DinoWorld`, `DinoRebirth`, Dino `Areas/Area01..06` (spec table,
   blurbs). Then `tests/economy-sim.luau --world <id>` (+ `--tune --write`) until:
   * every Dino area is within ±20 %
   * run 2 ≤ 85 %
   * the Bone Stash values are tuned
6. `tests/worlds-config.luau` checks the registry: uniqueness, prefixes, link maths, unlock rules,
   and that every world has eggs / currency icons declared.
7. Docs: an economy.md Dino section (achieved pacing table), plus `docs/worlds.md` (framework +
   the spec §18 checklist).

**W2 worlds-core (wave A)**
1. ProfileLogic v2 + `worlds` / `lastWorld` / snapshot fields. `tests/profile-logic.luau` adds:
   * v1 → v2 migration; a v3 save opens as "newer"
   * garbage / NaN / huge values in worlds.* are repaired
   * unknown well-formed world keys are kept and malformed ones dropped
   * a cap of 8 worlds
   * pads set bounds; toSave is JSON-safe; the snapshot shape
2. PlayerDataService currency API + CurrencyChanged for `bones`.
   `ProfileSyncState`: `worldCash` coalesced with cash.
3. Remotes + `Validate.worldId` (`tests/validate.luau`). `tests/remote-security.luau` fuzzes
   `TravelWorld`, `Rebirth(worldId)` and `RebirthShopBuy(key, worldId)` with hostile values.
4. Products in MonetizationConfig. Create the 4 dev products with
   `python3 scripts/studio_mcp.py call manage_monetization ...` and record the ids in
   `PublishedProductIds`. If refused, report it as an owner action.
5. ClientState / ProfileSyncClient mirror the new fields.

**W6 / W7 / W8 art (wave A)**: two areas each, spec §16.
1. Blender builders, budgets, upload + sync.
2. `Worlds/Dino/Layouts/AreaNN.luau` (same contract as `AreaLayouts/AreaNN`, D6 height ≤ 140).
3. Manager models pieced into the R30 rig groups. Animated pieces named for WorldFx rows
   (Wheel, Ears, Column, WingL / WingR, Swirl) and listed in your report for W10.
4. Arch text on both faces (R17). Z-fights 0 (R18), glow budget (R19), no interpenetration (R24),
   billboard space left (R31).
5. Previews `spawn_dino_areaNN.luau`, origin far from both worlds, e.g. (9000, 0, -9000 − 300·N).
6. Captures `docs/verification/world2/dNN-*.jpg` (front, iso, arch both sides).
7. **W6 first task:** make `tests/zfight-audit`, `glow-budget` and `mesh-assets` iterate every
   world's layouts (via `WorldsConfig` + the layout folder), so all three art builders are gated.

**W9 valley-hub-art (wave A)**
1. Base Camp + plot frame + locked slot + scenery + `Hub_TimeMachine`, with the Valley budgets in
   spec §15.
2. `ValleyLayout.luau` (anchors per §3.4), with first-view vs deferred keys.
3. Main `HubLayout`: Time Machine placement + `anchors.WorldPortals.dino`. Placement rules in
   spec §4.4; `tests/hub-layout.luau` checks clearance.
4. `tests/valley-layout.luau` mirrors `hub-layout` (anchors present, colliders, the boundary ring
   at 650, plot clearance, MeshPart / triangle budgets).
5. Icons + shop props + audio (spec §16), registered in `IconAssets` / `MeshAssets` /
   `SoundAssets`.
6. Captures of Base Camp and the lobby Time Machine.

**W11 dino-pets (art in wave A, systems in wave C)**
1. Pets + eggs in Blender (PetAnim rigs, R44), uploaded.
2. `PetConfig` / `EggConfig` / `PetAnimConfig` rows.
3. World-aware stands (`EggStands`, `StandClient`, `PetService` range / unlock / currency) and
   EggHatch showing the Bones price.
4. `PetGrants.grantFixed` for the Time Ptero.
5. Tests: `pets-policy` (bones gated; product kinds `WorldCash` / `WorldStarter` classified),
   `pets-logic` (odds sum, pity, Dino egg unlock).
6. Studio: hatch both eggs, plus the restricted-policy path.

**W3 worlds-tycoon-server (wave B)**
1. **First:** `tests/area-layouts.luau` becomes world-aware (main strict as today; dino strict once
   all 6 layouts exist, partial before), so art builders get a gate.
2. **Refactor with no behaviour change:** runtime keyed by (player, world). Main runs through it.
   `tests/tycoon-server-logic.luau` + `knockdown-logic` must stay green. Studio regression tour on
   main: buy pads, click, upgrade, manager, offline, rebirth, knockdown, skip pad, cash pack. This
   lands **before** any Dino code.
3. World plots:
   * `PlotBuilder.world`, `createWorldPlots`, the Valley frames
   * `ensureWorld`, the lazy build
   * per-world tick / pads / clicks / upgrades / attributes / pops gating
4. Rebirth (world param), offline rows, ModifierSources linkCash, product handlers, SkipPad by
   current world, TycoonAnalytics world keys, TycoonAdmin per-world rebuild seam.
5. `PreloadList.world`.
6. Studio: on Dino D1, buy pads (build-in), click, upgrade, manager automation; Bones flow while
   standing in main.

**W4 worlds-travel (wave B)**
1. `TravelRules` + `tests/world-travel.luau`: every reason, boundary indices, NaN / inf / wrong
   types, cooldown edges, own vs other plot with and without the pass.
2. `WorldService`: unlock rule (on load, AreaReached, admin), travel pipeline (§4.5 of the spec),
   respawn, `lastWorld`, the 1 Hz stats loop, kill switch, portals (prompt + touch, locked toasts
   throttled).
3. `HubBuilder.buildWorld("dino")` + world portals. `PlotService` claim / release across worlds +
   Valley plot pads.
4. World admin commands + handlers + seam. Update `tests/admin-validate` / `admin-pipeline`
   expectations.
5. Studio: locked portal → toast + preview; admin unlock; travel by portal, menu spawn, area and
   plot (with / without the pass); respawn in the Valley; kill switch evacuates; rejoin lands in
   the lobby.

**W5 worlds-ui (wave B)**
1. `WorldClient` + `WorldClientConfig` (Lighting presets, music, preload, fail texts) and
   `WorldObjectives` (pure, tested).
2. Teleport world tabs; Rebirth world tabs + Amber shop + link lines; Welcome Back rows; Shop
   DINO VALLEY section (R39 viewports).
3. New screens: WorldTravel overlay, WorldUnlocked popup (normal + locked-preview modes, gated by
   the same calm-moment logic as WHAT'S NEW).
4. HUD changes:
   * the currency primary / secondary swap
   * the Bones CurrencyFly kind
   * the Teleport NEW dot
   * Attack hidden in non-main worlds
   * the rejoin chip
   * the Time Traveler offer rotation
5. `tests/world-client.luau` (objectives, tab model, preset validation, fail-text coverage of every
   TravelReason).
6. `capture_device_matrix` (phone / tablet / console) for every changed or new screen and the HUD
   in the Valley.

**W10 worlds-tycoon-client (wave C)**
1. `WorldLookup`; every `Client/Tycoon` module resolves ids through it (billboards, pads,
   interaction, income pops with the bone icon, YOU marker on the Valley plot). Tutorial and
   StandSign stay main-only.
2. Billboards: `generate-spots.luau --world dino` → `BillboardSpots.worlds.dino`.
   `tests/billboard-clearance.luau` covers Dino areas on desktop + device.
3. `ManagerNpcConfig` rigs + waypoints for the 6 dino managers (`tests/npc-logic`).
4. `WorldFxConfig` rows (wheel, turbines, fan ears, geyser columns, incubators, lava scroll,
   Time Machine swirl).
5. `VehicleRouteConfig` ptero courier routes in D3 (+ an optional D4 cart). `tests/vehicle-routes`
   covers world frames and clearance.
6. Build-in verification on Dino builds (`tests/build-in-plan`).
7. Studio captures per area (billboards desktop / phone / console, managers walking, pteros flying).

**W12 worlds-analytics-qa (wave B start → wave C)**
1. **First:** the AnalyticsConfig `worlds` family + currency / id allowlists + recorder.
   `tests/analytics-*` green.
2. Reports + admin Analytics WORLDS section + COPY FOR AI; Players-list world columns
   (`AdminStatePush`); Live players-per-world.
3. Board "MOST DINO REBIRTHS" (`LeaderboardConfig` with `world = "dino"`, source
   `worlds.dino.rebirths`, the Valley anchor). Badges "Time Traveler" / "Volcano Tamer" (ids 0).
4. `tools/qa/world2_check.py --world dino`, the full tour:
   * admin unlock → popup → GO NOW → Base Camp
   * own D1 → admin UnlockAll → finale → Dino rebirth
   * return by portal; Welcome Back rows (`WorldOfflinePreview` + a real rejoin)
5. Two-player `multiplayer_playtest`: visit via Teleporter, visitor pad refusal.
6. Perf capture with 8 full plots per world: server heartbeat, Workspace instance count, client
   ms (Low tier) in the Valley, memory.
7. Device matrix for every new screen. All captures go to `docs/verification/world2/`.

---

## 5. Tests

**Lune (all run by `./scripts/check.sh`; new suites marked ★)**

| Suite | Owner | What it proves |
|---|---|---|
| ★ `economy-index` | W1 | Main index built through EconomyIndex is bit-identical to today; validation errors on bad chains / prefixes / features |
| `tycoon-logic` | W1 | Full suite per world; purchase monotonicity incl. `linkCash` and Dino rebirth variants |
| `economy-sim` (`--world dino`) | W1 | Dino ±20 % per area, run 2 ≤ 85 %, prices strictly rising; main unchanged |
| ★ `worlds-config` | W1 | Registry invariants, unique ids / currencies across worlds, link + unlock maths |
| ★ `world-frames` | W1 | World-aware WorldLayout, separation ≥ 3000 studs, main parity |
| `profile-logic`, `profile-sync`, `validate`, `remote-security` | W2 | Schema v2, worlds reconcile / snapshot / save, new remotes fuzzed |
| `area-layouts` | W3 | Every world's layouts (strict), D6 height 140 |
| `tycoon-server-logic`, `preload-list`, `build-in-plan` | W3 | Runtime per world, catch-up, products, preload keys per world |
| ★ `world-travel` | W4 | TravelRules truth table |
| `admin-validate`, `admin-pipeline` | W4 | World commands' schemas, enums, audit |
| `zfight-audit`, `glow-budget`, `mesh-assets` | W6 | All worlds' art |
| ★ `valley-layout`, `hub-layout` | W9 | Base Camp anchors / budgets / boundary; lobby Time Machine clearance |
| `pets-logic`, `pets-policy`, `pet-anim`, `pet-models-load`, `hatch-anim` | W11 | Dino eggs, bones gated, rigs |
| ★ `world-client`, `currency-fly`, `hud-cluster` | W5 | Objectives, tabs, presets, fail texts, HUD layout with the Bones primary |
| `billboard-clearance`, `vehicle-routes`, `npc-logic` | W10 | Dino areas, ptero routes, dino managers |
| `analytics-*`, `leaderboard-logic`, `event-badges` | W12 | New family / keys / board / badges |

**Studio checks** (studio-lock held; captures under `docs/verification/world2/`):
* W3: main regression tour, then the Dino tycoon.
* W4: travel matrix.
* W5: device matrix.
* W6–W9: art captures.
* W10: billboards / managers / routes.
* W11: hatches.
* W12: full tour, multiplayer and perf.

Report the numbers, not "looks fine".

---

## 6. Order (critical path)

1. **W1 + W2 land** (wave A, parallel). The lead reviews and commits, with `check.sh` green and
   main behaviour unchanged. Art (W6–W9, W11 art) runs from minute 0 against spec §6.2 / §16; the
   placeholder layouts keep the server playable meanwhile.
2. **W12 analytics keys → W3 refactor (no behaviour change) → lead commits.** W5 and W4 (TravelRules,
   WorldService skeleton) work in parallel against §3.3 / §3.4.
3. **W3 Dino runtime + W4 travel → lead commits.** First playable trip: unlock, travel, D1 on
   placeholders.
4. **Art layouts land (W6–W8), Valley + portal (W9) → W10 client polish, W11 systems → lead commits.**
5. **W12 QA tour, multiplayer, perf, device matrix → fixes routed to file owners → final commit.**
6. **Lead integration:**
   * boot lists: server `"Tycoon/WorldService"` after `"Tycoon/RebirthService"`; client
     `"Worlds/WorldClient"` before the screens that read it
   * `VersionConfig` **0.4.0** + change note "Dino Valley"
   * living doc system table rows + change log
   * owner-requests R57 "Implemented" line
   * owner actions list: Migrate to Latest Update, products if MCP refused, the 2 badges

Main-world safety gate: **no step after 1 may merge if any main-world test or the main regression
tour regresses.** The lead runs `./scripts/check.sh` on a clean checkout before every commit.
