# SellNukes tycoon server (B5)

The authoritative tycoon: plots, the world they are built in, pads, producers, the payout loop,
upgrades, tutorial, teleports, offline earnings, rebirth, and the tycoon's products. Pure economy
maths lives in `src/shared/Tycoon/TycoonLogic` (docs/economy.md); this layer applies it to players.

## Files

| File | What |
|------|------|
| `src/shared/Config/WorldLayout.luau` | Hub / ring of 8 plots / 10 area slots; CFrame helpers; HubLayout contract |
| `src/server/World/PlotBuilder.luau` | Builds plots, area bases, purchased builds (BuildIn), BuyPads, producer anchors, signs |
| `src/server/World/HubBuilder.luau` | Hub ground discs, spawn, 8 plot portals, HubLayout art |
| `src/server/Tycoon/PlotService.luau` | Plot claim / release / queue, owner sign, RenameStand (filtered), respawn, TeleportHub, portals |
| `src/server/Tycoon/PlotNames.luau` + `PlotNameAdmin.luau` | Owner R88 plot names: RenamePlot, re-filtered display on every world's sign, admin ResetPlotName (`docs/plots.md`) |
| `src/server/Tycoon/TycoonService.luau` | Runtimes, payout loop, pads, clicks, upgrades, tutorial, TeleportArea, leaderstats, SkipPad + Cash products |
| `src/server/Tycoon/OfflineService.luau` | Welcome-back offline earnings, DoubleOffline product, lastSeenAt stamps |
| `src/server/Tycoon/RebirthService.luau` | Rebirth, RebirthShopBuy |
| `src/server/Tycoon/ModifierSources.luau` | Plug-in registry for income modifiers (passes built in; pets / boosts / events register) |
| `src/server/Tycoon/TycoonAdmin.luau` | Admin seam for B14 |
| `src/server/Tycoon/Knockdown.luau` | Temporary area knockdown (owner R50): state, loop, KnockdownTap, toasts, analytics, admin seam (docs/attack.md §13) |
| `src/server/Tycoon/TycoonAnalytics.luau` | Guarded lazy AnalyticsService calls; batched income |
| `src/server/Tycoon/AreaLayouts.luau` | Resolves each area's layout: art file → validated + gap-filled, else placeholder |
| `src/server/Tycoon/LayoutLogic.luau` | Layout contract types, validation, merge (pure) |
| `src/server/Tycoon/PlaceholderLayouts.luau` | Complete generated layouts (area 1 = B4's real garage meshes) |
| `src/server/Tycoon/TycoonRules.luau`, `TutorialLogic.luau` | Pure rules (unit-tested in Lune) |
| `src/server/Tycoon/TycoonTests.luau` | Studio suite "Tycoon" |
| `tests/area-layouts.luau`, `tests/tycoon-server-logic.luau` | Lune regressions |

## Boot (lead adds these)

`src/server/init.server.luau` ORDERED, after `MonetizationService` (and after `AnalyticsService` if
present), before `AdminService`:

```lua
{ name = "PlotService", module = require(script.Tycoon.PlotService) :: Service },
{ name = "TycoonService", module = require(script.Tycoon.TycoonService) :: Service },
{ name = "OfflineService", module = require(script.Tycoon.OfflineService) :: Service },
{ name = "RebirthService", module = require(script.Tycoon.RebirthService) :: Service },
```

Feature-list name of the knockdown service: `"Tycoon/Knockdown"`, directly after `"Tycoon/TycoonService"`
(owner R50; TycoonService requires it and binds `areaIncome` / `isReady` into it in Init).

`src/server/Tests/TestRunner.luau` getSuites:
`Tycoon = require(script.Parent.Parent.Tycoon.TycoonTests) :: { TestCase },`

Every Start() also handles players / profiles that already exist, so a hot start in Studio works.
Product kinds registered: `Cash`, `SkipPad` (TycoonService), `DoubleOffline` (OfflineService) — no
other service may register them (MonetizationService errors on a second registration).

## World tree + client contract (agreed with B4 build-in and B6 tycoon UI)

```
Workspace.Plots (Folder)
  Plot<N> (Model)            PlotIndex, OwnerUserId (0 = free), OwnerName, StandName (filtered),
                             PlotReady (true once the owner's bought builds are placed)
    YouAnchor (Part)         invisible; owner's client draws "YOU" here (HubLayout YouMarker)
    Frame (Model)            HubLayout.plotFrame: colliders + plot-tinted meshes; owner sign
                             "<DisplayName>'s Nukes" on EntranceArch.OwnerSign (Front + Back;
                             white text with a 6 px dark-navy UIStroke, readable on the cream plate)
      — without HubLayout: Ground, Road (Part) + Entrance (Model) primitive arch + sign
      Area02/Builds/A2_NeonSign/StandSign (Folder)  the stand name (StandRename, default "Fresh
                             Nukes!") painted on both panel faces: StandSignFront / StandSignBack
                             invisible parts at AreaLayouts Area02 `standSign` cf / backCf with a
                             SurfaceGui on Front (PlotBuilder.setStandName; BillboardGui only when
                             a layout has no panel)
    Locked (Folder)          Locked<NN> (Model, LockedArea): HubLayout.lockedSlot on every locked slot,
                             sign "COMING SOON" (next area: "COMING SOON / x / y purchases")
    AreaNN (Model)           AreaIndex; WorldPivot = slot frame
      Base (Model)           area floor + entry arch        purchase only: BuildIn, BuyerUserId, AreaUnlock, tag BuildIn
      Builds (Folder)
        <BuildKey> (Model)   BuildKey, PadId, AreaIndex      purchase only: BuildIn, BuyerUserId, tag BuildIn
      Pads (Folder)
        <padId> (Model)      tag SNPad: PadId, OwnerUserId, Cost, Kind, Name, Blurb, Color (Color3), Area,
                             Order, Value?, Feature?, PressedAt (set when bought, removed 0.6 s later)
          Trigger (Part)     invisible touch volume;  Visual (Model) BuyPad mesh tinted Color
      Producer (Model)       ProducerId
        Anchor (Part)        tag SNProducer (attributes below)
        ClickBox (Part)      invisible, CanQuery, ClickDetector: 3D mouse click / touch tap → server
                             (owner, reach, idle checked); the client's CLICK bar / keys fire ProducerClick
Workspace.Hub (Model)        ground discs (placeholder only), Spawn, Collision, WorldPortals (Time
                             Machines), Art (HubLayout meshes). No Portals folder since owner R134.
                             Since R134 no hub (any world) has plot teleport pads (see below).
```

* **BuildIn** (`workspace:GetServerTimeNow()`), **BuyerUserId** and the CollectionService tag
  `BuildIn` are set BEFORE the model is parented. Restored plots (rejoin, rebirth, admin) have none.
* The Unlock pad of area N (build key `A{N+1}_EntryArch`) builds **Area{N+1}.Base** and stamps
  `AreaUnlock = N+1` (fanfare). `AreaNN.builds` holds only area N's own keys.
* Streaming: plot root Default; Base / builds / Entrance Atomic; Pads + Producer
  PersistentPerPlayer for the owner (Atomic for others).

### Producer Anchor attributes

| Attribute | Meaning |
|-----------|---------|
| `ProducerId`, `Area`, `Name`, `OwnerUserId` | identity |
| `Level` | producer level (billboard "x77") |
| `PerCycle` | cash of the next payout (automated output, else click payout) |
| `CycleTime` | seconds per cycle |
| `CycleStart` | Automated: loop origin, progress = `((now - CycleStart) / CycleTime) % 1` (republished only when CycleTime changes, phase kept). Manual: server time of the accepted click while running, `0` when idle |
| `Automated` | Manager owned (runs by itself) |
| `Badge`, `BadgeNextAt` | milestone badge "x4" and the next milestone level (0 = none) |
| `NextCost` | price of the next single level (-1 = max / unbuilt) |
| `PerSecond` | automated $/s (0 while manual) |
| `PausedAt` | server time a knockdown paused this producer (owner R50); removed on resume, when `CycleStart` is republished shifted by the paused time |

Clicks are accepted only while the producer is idle (no other cooldown). `now` =
`workspace:GetServerTimeNow()` on the client too.

### Player attributes

`PlotIndex` (0 = none), `PlotAssignedAt` (server time of the assignment), `PlotRevealSeconds` (3),
`PlotRevealed` (true once walked home), `IncomePerSecond` (idle $/s with ALL server modifiers —
clients must not recompute it), `TycoonArea`, `FeatureStandRename`, `FeatureAATower`,
`FeatureAttackConsole`, `FeatureRebirth`. `leaderstats.Cash` (StringValue "$1.25M") +
`Player.CashSort` (NumberValue).

### Lobby + plot reveal (owner rule R13)

**No hub plot teleport pads (owner R134, 2026-11-01: "can we remove these little teleports").**
The R55 ring of 8 plot pads in the lobby (and in every extra world's hub) is gone: no layout anchor
(`PlotTeleportPads`), no touch triggers, no "PLOT N + owner" labels, no generated neon-portal
fallback, no PlotService pad handler (free walk-to-plot) and no WorldService `visit` hook. A new
player still lands home through the plot reveal walk; afterwards players walk the paths / avenues
(numbered plot gates at r 222) or use the Teleport menu: TeleportHub, TeleportArea (own plot, free —
the "go home" route), TeleportPlot (other plots, Teleporter pass) and WorldService travel for other
worlds (a visitor's menu trip still builds the visited owner's world plot). No analytics family
recorded pad use (the handler never reported), so nothing is retired. Guard:
`tests/hub-no-teleport-pads.luau`.

Characters spawn in the hub (HubLayout spawn). When the profile loads, PlotService picks a
**uniformly random free plot** (server `Random`; returning players get whatever plot is free and
their saved tycoon is rebuilt there), labels the plot sign, sets the
attributes above (PlotIndex last) and fires PlotAssigned; the plot's `PlotReady` turns true once
the bought builds are placed. Owner rule R16: the loading screen covers the join, the client plays
its reveal (`PlotRevealSeconds` = 3 is a length hint) and fires `PlotRevealDone()` (C→S, no args,
rate limited, ends only a PENDING reveal) — the character is walked to the plot entrance,
`PlotRevealed = true`. Server fallback: 60 s after the assignment. Respawns after that go to the
entrance. A full server (8/8) queues the player with a toast and hands over the next freed plot.

Restore order (R16, with B4's MeshLibrary priorities): area by area, area 1 first — preload only
the base + OWNED builds of that area (`MeshLibrary.Priority.Plot`), place them, next area. Never
waits on unbought / locked content; claiming and teleporting never wait on the restore.

### Remotes handled

| Remote | Checks |
|--------|--------|
| `ProducerClick(producerId)` | key ≤ 32, 20 burst / 12 per s, ready runtime, built, not automated, idle, character within 60 studs (40 vertical) of the anchor |
| `ProducerUpgrade(producerId, "1"\|"10"\|"max")` | key, mode allowlist, 15 / 8 per s, built, `TycoonRules.upgradeCount`, `trySpendCash` |
| `ProducerGemUpgrade(producerId)` (owner R86) | key ≤ 32, 6 / 3 per s, ready runtime (any world), `GemUpgradeRules.check`: switch on, built, below MaxLevel; price = `GemUpgradeSettings.price()` (never a client value); atomic `trySpendGems(price, "GemUpgrade")` → exactly ONE level (refund if none applied) → refresh, analytics `producerUpgraded(..., "gem")`, `ProgressEvents.progress("upgrade", 1)`, tutorial re-check. No distance rule, like the cash upgrade |
| `PadBuy(padId)` + pad Touched | owner only, 6 / 3 per s, pad available + shown + not pressed, character within 12 studs (10 vertical) of the pad, cash |
| `TeleportArea(area)` | integer 1..10, own unlocked area, FREE (`TycoonService.TeleportNeedsPass = false`, lead rule), 3 / 0.5 per s → the layout's spawn point |
| `TeleportPlot(plotIndex)` | integer 1..8, plot owned; own plot free, another player's plot needs the Teleporter pass; 3 / 0.5 per s + 5 s cooldown → plot entrance |
| `PlotRevealDone()` | rate limited; ends the caller's pending reveal → walk home |
| `TeleportHub()` | 3 / 0.5 per s → hub spawn |
| `RenameStand(text)` | UTF-8 text ≤ 24 chars, 2 then 1 per 15 s, one in flight, StandRename feature, TextService broadcast filter BEFORE saving / showing (never stores unfiltered text; filter failure → toast, nothing changes) |
| `RenamePlot(text)` | owner R88 (`Tycoon/PlotNames`, see `docs/plots.md`): `""` = reset to default; PlotNameLogic.parse (Validate.text 24 + invisible chars dropped), one in flight, 3 then 1 per 10 s (throttled "slow down" toast), owns a plot, TextService broadcast filter BEFORE saving / showing, censored names refused, re-checked after the yield; saved as top-level `profile.plotName` (survives Rebirth), shown on the entrance sign in every world |
| `Rebirth()` | finale owned, saving session (`canMutate`), 2 / 0.2 per s |
| `RebirthShopBuy(key)` | `Validate.configKey(RebirthConfig.Shop)`, tokens, not maxed |

Server → client: `TutorialState { step, done, kind, target, padId?, producerId?, text }` (steps below),
`OfflineEarnings { amount, seconds, rate }`, `IncomePop { producerId, amount }` (unreliable, owner
only, ≤ 2 per s per producer, amounts accumulated in between), `Notify` toasts.

### Tutorial (TutorialLogic)

| step | kind | target |
|------|------|--------|
| 1 | pad | `a1_workbench` |
| 2 | click | `p1_workbench` |
| 3 | upgrade | `p1_workbench` (level 2) |
| 4 | pad | `a1_tool_wall` |
| 5 | pad | `a1_glow_lamp` |
| 6 | pad | `a1_uncle_atom` — "Hire Uncle Atom - he makes nukes for you, even offline!" (owner R122) |
| 7 | pad | next pad, until `a1_open_stand` |
| done | — | `{ step = 0, done = true }` |

Stored in `profile.tycoon.tutorialStep` (0 never started, 1..7, 8 = done), monotonic: a rebirth
never restarts it. Sent on join and on every change / pad purchase.

### Garage Lab opening (owner R122, 2026-11-01, spec `2026-11-01-r122-algorithm-pack-design.md` §2.2)

Live first-run data (Garage Lab, minutes to each pad): Workbench 1.0, Tool Wall 2.5, Glow Lamp 3.4,
Garage Door 4.1, Mini Reactor 6.1, Paint Station 9.9, **Uncle Atom 11.1**, Driveway 11.4, Unlock 12.3;
tutorial `tut:6` 102 -> `tut:7` 27 (-74 %): step 6 was the chain "Keep building - hire Uncle Atom!",
i.e. ~11 min of hand-clicking before the first automation. Changes:

* **Buy order** (`TycoonAreas/Area01.luau`): Workbench -> Tool Wall -> Glow Lamp -> **Uncle Atom** ->
  Garage Door -> Mini Reactor -> Paint Station -> Driveway -> Open the Nuke Stand. The `requires` chain is
  written per pad and validated by `EconomyIndex` (each pad requires the one before it). Pad ids (SAVE DATA)
  are unchanged; prices re-paced (docs/economy.md "Garage Lab opening").
* **Old-order saves** need no migration code: `tycoon.pads` is an id set and nothing on load prunes it
  (`ProfileLogic.reconcile` keeps the set, `PlotBuilder.restore` builds every owned pad, `nextPads` offers
  every unowned pad whose prerequisite is owned). A save that owns Garage Door .. Paint Station but not Uncle
  Atom keeps every pad and its cash and is offered **two** pads (Uncle Atom + its next old-order pad);
  `PlotBuilder.syncPads` shows both. Its tutorial stays on step 6 (arrow on Uncle Atom) until he is hired,
  then step 7 chains through whatever it still lacks. Proven by `tests/garage-lab-order.luau` (every prefix
  of the old order through the real `toSave -> migrate` path: pads + cash kept, owned pads refused as
  "owned", Uncle Atom offered, buying the offers always reaches the Nuke Stand, income never drops) and the
  migration cases in `tests/tycoon-server-logic.luau`.
* **Tutorial** (`TutorialLogic`): step 6 is a direct pad step on `a1_uncle_atom` (no chain); step 7 the
  chain to the Unlock. Still 7 steps, so `tut:<n>` and DoneStep keep their meaning. The step-6 line is
  55 characters: the spec's "... even while you're away!" (65) needs 3 lines in the phone objective chip
  (FredokaOne 30 px, ~426 px per line, 2 lines max before "..."), this one fits 2 (measured 410 px).
  Client fallback table `Tycoon/TutorialSteps` mirrors the 7 server steps.
* **Pad row** (`AreaLayouts/Area01.luau`): spots still alternate either side of the arch in BUY order,
  moving outward — Uncle Atom took the 4th spot (+24), Garage Door / Mini Reactor / Paint Station moved one
  spot out (-32 / +32 / -40); Driveway and the Unlock keep theirs.
* **Analytics note:** `Recorders` marks `ftue:pad5` at PadIndex >= 5, which is now the Garage Door
  (~2.5 min in the sim; ~1.9 min since the R137 re-price) instead of the Mini Reactor (~3.9 min) — compare 0.8.0 vs 0.7.1 with that in mind;
  the manager marks (`ftue:manager`, `firstDay:manager`, `padAt:a1_uncle_atom`) are the direct read-out.

### BoomDash order (owner R130, 2026-11-01)

Live first-run data: the Dispatcher (BoomDash Manager) was pad 8 of 9, bought ~13 min after the area
opened (6:20 after the Parking Lot); the Mobile App cost 8.3x the GPS; 41 players opened BoomDash
Delivery and 4 reached the Glow Rock Mine. Changes (prices: docs/economy.md "BoomDash order"):

* **Buy order** (`TycoonAreas/Area03.luau`): HQ Shell -> Scooter Rack -> Scooters -> **Dispatcher** ->
  GPS -> Mobile App -> Delivery Van -> Parking Lot -> Dig the Mine; `requires` follows it. Pad ids
  (SAVE DATA) unchanged.
* **Old-order saves** need no migration, exactly like R122: a save that owns GPS .. Parking Lot but not
  the Dispatcher keeps every pad, level and its cash and is offered **two** pads (Dispatcher first +
  its next old-order pad; at the end the Dispatcher + Dig the Mine). Buying Dig the Mine first is
  allowed; the Dispatcher stays on offer. The BoomDash is automated exactly when the Dispatcher is
  owned. Proven by `tests/boomdash-order.luau` (every prefix of the old order through toSave ->
  migrate).
* **Pad row** (`AreaLayouts/Area03.luau`): spots alternate either side of the arch in BUY order — the
  Dispatcher took the 4th spot (+24), GPS / Mobile App / Delivery Van / Parking Lot moved one spot out
  (-32 / +32 / -40 / +40); HQ Shell, Scooter Rack, Scooters and Dig the Mine keep theirs.
* **Analytics read-out:** `padAt:a3_dispatcher / padN:a3_dispatcher` (first-run minutes to the hire),
  `manager:p3_boomdash`, the slowest-pads table (time since the previous pad) and `areaN:4`.

### Nuke Stand order (R137)

Owner R137, 2026-11-01. Live first-run data: the Cashier Bot (Nuke Stand Manager) was pad 8 of 10, behind
price jumps of 5.8x (Tip Jar -> Neon Sign) and 4x (Picket Fence -> Cashier Bot); 150 players opened the Nuke
Stand, 102 hired the Cashier Bot, 82 opened BoomDash Delivery. Changes (prices: docs/economy.md "Nuke Stand
order (R137)"):

* **Buy order** (`TycoonAreas/Area02.luau`): Counter -> Awning -> Cash Register -> **Cashier Bot** -> Tip Jar
  -> Neon Sign -> Cooler -> Picket Fence -> Picnic Tables -> Start BoomDash; `requires` follows it. Pad ids
  (SAVE DATA) unchanged; the Neon Sign keeps the sign rename (`StandRename`).
* **Old-order saves** need no migration, exactly like R122 / R130: a save that owns Tip Jar .. Picket Fence
  but not the Cashier Bot keeps every pad, level, its cash and its sign rename, and is offered **two** pads
  (Cashier Bot first + its next old-order pad: Neon Sign after the Tip Jar, Picnic Tables after the Picket
  Fence). Buying Start BoomDash first is allowed; the Cashier Bot stays on offer. The Nuke Stand is
  automated exactly when the Cashier Bot is owned. Proven by `tests/stand-order.luau` (every prefix of the
  old order through toSave -> migrate).
* **Pad row** (`AreaLayouts/Area02.luau`): spots alternate either side of the arch in BUY order — the Cashier
  Bot took the 4th spot (+24), Tip Jar / Neon Sign / Cooler / Picket Fence moved one spot out (-32 / +32 /
  -40 / +40); Counter, Awning, Cash Register, Picnic Tables and Start BoomDash keep theirs. Build groups
  (where each purchase's model stands) are unchanged.
* **Analytics read-out:** `padAt:a2_cashier_bot / padN:a2_cashier_bot` (first-run minutes to the hire),
  `manager:p2_nuke_stand`, the slowest-pads table and `areaN:3`. Garage Lab (R137 re-price, order unchanged):
  `padAt:a1_tool_wall` / `a1_glow_lamp` / `a1_uncle_atom` and the early-leave buckets.

## Server APIs

* **PlotService**: `getPlotIndex(player)`, `getOwner(index)`, `PlotAssigned(player, index)`,
  `PlotReleased(player, index)`, `teleport(player, cf)`, `entrance(index)`, `applyStandName(player)`.
  A second `ProfileLoaded` for the same player (New Player Mode) releases and re-claims; a
  `ProfileUnloading` signal (if B1 adds it) releases.
* **TycoonService**: `PadBought(player, padId, skipped)`, `AreaReached(player, area)` (both deferred),
  `incomePerSecond(player)`,
  `getModifiers(player)`, `isReady(player)`, `nextPad(player)`, `purchasePad(player, padId, {free?, skipped?})`
  (never yields), `grantPads(player, padIds, animate)` (admin, no analytics), `resetRun(player, animate?)`,
  `hasFeature(player, key)`, `markDirty(player)`.
* **ModifierSources**: `register(name, provider(player, profile) -> (partial?, validUntil?), {offline?})`,
  `unregister`, `invalidate(player)`, `invalidateAll()`, `build(player, profile, offline?)`,
  `Changed`. Merge: petCash summed, booleans OR'd, multipliers multiplied; rebirth data always from
  the profile. Providers must be pure and never yield (also run inside product grants); a throwing /
  yielding provider counts as neutral and warns once. Built in: `passes` (DoubleCash, VIP).
  B7 boosts (`profile.boosts`) and the server boost, B9 pets, B11 event register their own.
* **OfflineService**: `payOnJoin(player, profile)`, `pendingDouble(player)`.
* **RebirthService**: `applyRebirth(profile) -> tokens`, `Rebirthed(player, rebirths)` (deferred).
* **HubBuilder**: `build()`, `layout()` (HubLayout or nil), `spawnCFrame(worldId?)`, `buildWorld(id)`,
  `getWorldPortal(id, side)`. (`setPlotOwner` / `worldPlotPortals` / `HubBuild.portals` went with the
  hub plot teleport pads, owner R134.)
* **PlotBuilder**: `entrance(index)`, `syncLocked(index, tycoon?)`, plus the build / pad / producer API.
* **TycoonAdmin** (B14): `setCash`, `setArea`, `unlockAll`, `resetPlot`, `setRebirths`,
  `rebuildPlot(player, animate)` → `(ok, message?)`.

## Payout loop and caching

One `RunService.Heartbeat` connection accumulates time and runs a tick every **0.2 s**: per ready
player, every automated producer pays its whole completed cycles (`TycoonRules.catchUp`, capped at
5000 per tick against hitches), finished clicked cycles pay their click payout once and the producer
then idles until the next click (`TycoonRules.manualStep`; owner R64), the AutoClicker pass — only
while the player's Settings toggle `settings.autoClicker` is ON (`TycoonRules.autoClickerOn`,
re-evaluated on `SettingsService.Changed`) — chains up to 20 per tick, and the player gets **one**
`grantCash` per tick. Producer stats and
modifiers are cached per player and recomputed only on a purchase, level-up, `ModifierSources`
invalidation or a provider's `validUntil` — never per tick. Attributes change only when values do
(`CycleStart` of an automated producer is not republished each cycle). Leaderstats refresh once per
second; analytics income is batched per producer and flushed every 10 s; the loop reports its Luau
time to `ServerHealth` as `Producers`.

### Knockdown pause (owner R50)

`tickPlayer` first runs `syncKnockdown`, which costs one table lookup unless a knockdown is active
(`Knockdown.activeAreas`). A producer whose area is down is skipped entirely: no payout, no
auto-clicker chain, no manager work, and `PausedAt` is set on its anchor. `ProducerClick` is refused
with a throttled toast. On resume the cycle origin moves by the paused time
(`KnockdownLogic.resumeStart`), so the bar continues where it stopped and nothing done during the
pause is paid. Pad purchases and upgrades stay allowed, and `IncomePerSecond` is not reduced (cash
packs / rewards stay fair). `TycoonService.areaIncome(player, area)` returns that area's automated
$/s for the attack reward. `resetRun` (rebirth / admin) calls `Knockdown.reset` first. Offline
earnings never see knockdowns because they are computed from the saved profile.

## Layouts

`AreaLayouts.get(n)` uses `ReplicatedStorage.Shared.Config.AreaLayouts.AreaNN` when it exists and
passes `LayoutLogic.validate(…, partial)`; any missing build key / pad / producer / spawn point is
filled from `PlaceholderLayouts` (warned once, `source(n) == "partial"`); a missing, failing or
malformed file falls back to the full placeholder. `tests/area-layouts.luau` validates committed
files STRICTLY. Extra layout fields (e.g. `aaTowerMount`) pass through for other systems.
Placeholders: area 1 = B4's garage meshes (Garage_*, Workbench, ToolWall, GlowLamp, MiniReactor,
PaintStation, Driveway) with collision from mesh bounds; areas 2–10 = themed stud primitives, each
with an entry arch in its base. Every primitive goes through `WorldMaterials.apply`.

HubLayout (`src/shared/Config/HubLayout.luau`, B8e, world space) is adopted **all-or-nothing**: only
when every mesh key it builds (world models, plot frame, locked slot) exists in MeshAssets —
otherwise one warning and the placeholder hub + plots (HubLayout ships `ground = false`, so a
half-synced layout would mean invisible ground). When adopted:
* HubBuilder: `collision`, the SpawnLocation (inside `Hub_SpawnPad`, invisible) and the Time
  Machine portal parts synchronously; `models` asynchronously (named `entry.name` /
  `<key>_<index>`, `persistent` → Persistent streaming, tint / colors / castShadow). `event`,
  `plotDecor`, `leaderboards` and the other anchors are owned by other services and ignored here.
* PlotBuilder: `plotFrame` per plot (colliders sync, meshes async, `plotTint` = `plotColors[i]`,
  owner sign on `EntranceArch.OwnerSign`, YouAnchor at `YouMarker`, entrance at `Entrance`) and
  `lockedSlot` on every locked area slot (removed when the area opens, re-added on release).

## Offline earnings

On `ProfileLoaded` (once per profile): elapsed from the server-saved `offline.lastSeenAt`;
`TycoonLogic.offlineLimits(rebirthShop, owns OfflineMax)`; modifiers built in offline mode (sources
registered with `offline = false` excluded); paid with `grantCash("offline")`; `OfflineEarnings` sent.
`lastSeenAt` is stamped on `ProfileReleasing` and every 60 s. DOUBLE IT! pays the pending amount
once (prompt refused when nothing pending / doubled / after 10 min); a receipt arriving with nothing
pending pays `TycoonRules.fallbackGrant` (10 min of idle income, ≥ $1K).

## Products

| Kind | Grant | Refusal at prompt |
|------|-------|-------------------|
| `Cash` (CashSmall..CashHuge) | `max(cashFloor, incomeSeconds × idle $/s)` | — |
| `SkipPad` | next pad free, with build-in (`skipped` analytics); all owned → fallback cash; plot still loading → retried | "You own every pad!" / still loading |
| `DoubleOffline` | pending payout again, once (fallback cash otherwise) | "Nothing to double right now!" |

## Rebirth

Finale owned + saving session → cash spent (economy books) → `applyRebirth` (tokens, rebirths + 1,
fresh tycoon keeping the stand name + finished tutorial) → starting cash → save soon → modifiers
invalidated → `resetRun` rebuilds the plot. Shop buys spend tokens atomically and invalidate
modifiers (Power Production / Speedy Managers / Golden Atoms apply at once).

## Analytics seams

`TycoonAnalytics.call(...)` → AnalyticsService (lazy, pcall, works without it): `plotAssigned`,
`padBought(player, padId, skipped)` (it also reports area reaches), `producerClick`,
`producerIncome` (batched), `producerUpgraded(player, id, from, to, mode)`, `tutorialStep`,
`rebirthed`, `offlinePaid`, `offlineDoubled`, `tycoon(player, "rename" | "teleport:<n>" |
"teleportHub" | "rebirthShop:<key>")`, `systemTime("Producers", s)`.

## Tests

* `lune run tests/area-layouts.luau` — frames, contract rules, placeholders complete, committed art strict.
* `lune run tests/tycoon-server-logic.luau` — TycoonRules, TutorialLogic (incl. R122 old-order saves), ModifierSources.
* `lune run tests/garage-lab-order.luau` — R122 Garage Lab order, pad-row contract, old-order save migration.
* Studio: `StudioTestService:ExecuteRunModeAsync({ suite = "Tycoon" })` — world, layouts, restore
  without BuildIn, purchase with BuildIn / tag / AreaUnlock, stale build discarded, pads + PressedAt.

## Studio verification (2026-10-30, play mode, services hot-started, `docs/verification/tycoon-server/`)

* Plot claimed (sign "JusticeDev's Nukes", PlotIndex attribute, respawn at the entrance), area 1 base
  built, the free Workbench pad shown with its mesh, tutorial step 1.
* Stepping on the pad (Touched) bought it: build with BuildIn + BuyerUserId + tag, every anchor
  attribute published, pressed pad removed, next pad shown, tutorial → 2.
* ProducerClick from the client paid $1 per 1 s cycle; spam clicks during a cycle ignored.
  ProducerUpgrade "1" / "10" worked, malformed requests refused.
* Walking the area-1 pads bought all of them; the $45K Unlock pad was refused at $17.8K. After
  Uncle Atom: passive +$749 in 4 s = exactly $187.2/s, IncomePop 5 events summing to it.
* Unlock pad → Area02.Base with AreaUnlock = 2 + BuildIn; tutorial done. TeleportArea(2) landed on
  the spawn point; locked area 5 and junk args refused.
* Rebuild through a second ProfileLoaded: ready in 0.01 s, 8 builds, 0 BuildIn. Offline 2 h paid
  $673,920 = 7200 × 0.5 × $187.2. DoubleOffline via the real receipt path paid once, then the
  fallback; SkipPad bought the next pad free; CashSmall paid 600 s of income exactly.
* Admin setArea / unlockAll (84 builds, 444 parts for a full 10-area plot), filtered stand rename
  shown on the Neon Sign, Rebirth via the client remote (rebirths 1, 20 tokens, plot back to area
  1, stand name + finished tutorial kept). Studio suite "Tycoon": 6 / 6 cases pass.

Round 2 (2026-10-30, play mode, real boot list, HubLayout synced):
* R13 lobby: the character spawned in the hub (40 studs from the centre, HubLayout spawn), got a
  random plot (4), PlotAssignedAt / PlotRevealSeconds = 3 set, and after 3 s PlotRevealed = true and
  the character stood on plot 4.
* HubLayout adopted (all mesh keys synced): plot shell = Frame (24 meshes, tinted), owner sign
  "JusticeDev's Nukes" on EntranceArch.OwnerSign, hub pad label "PLOT 4 / JusticeDev" (pads removed
  by owner R134), locked slots
  Locked02..10 with "COMING SOON / 0 / 9 purchases" on the next area, Locked01 removed at claim.
* Touch purchase built the producer with ClickBox + ClickDetector as siblings of Anchor.
* Found + fixed: with the AutoClicker pass the click step of the tutorial could never complete (the
  producer auto-runs, clicks are no-ops) — the step now counts as done for AutoClicker owners and is
  re-evaluated when modifiers refresh. The Teleporter gate's refusal path could not be exercised in
  Studio (the pass reads as owned there); its allow path was.
* Screenshot: docs/verification/tycoon-server/plot-hublayout-locked-slots.jpg.

Z-fighting (B8e audit R18, tests/zfight-audit.luau: BuyPads + placeholder blocks 0 offenders): any
visible primitive PlotBuilder adds must stay off shared planes — area floors +0.06 over the plot
ground, builds +0.12, decals / labels +0.18 (docs/areas-art.md "Z-fighting layer rule").

Runtime layouts do not check mesh keys: a key not yet synced into MeshAssets is built as a pink
placeholder box (warned once) so the rest of an art layout still shows; `tests/area-layouts.luau`
is the strict gate (it reports every problem of every committed file).

## Next steps / open items

* B6: billboards, CLICK button + raycast, upgrade pill, pads billboards, teleport list
  (`TycoonLogic.areaUnlocked` / `areaProgress` on `ClientState.profile.tycoon`), tutorial chip,
  welcome-back popup, rename dialog, YOU marker.
* B7: register `boosts` and `serverBoost` ModifierSources (with `validUntil`, `offline = false`).
* The Teleporter pass is not gating anything yet (area teleports are free per the spec's teleport list).

## W3 worlds-tycoon-server — R57 World 2 "Dino Valley" (2026-10-31)

Plan `docs/superpowers/plans/2026-10-31-world2-build.md` §3.3; spec `2026-10-31-world2-design.md`
§5, §6, §9, §11. Nuke Town behaviour is unchanged: every new parameter is optional and `nil` means
`"main"`; Nuke Town keeps the exact `TycoonConfig` / `TycoonLogic` module tables.

### Runtime per (player, world)

`TycoonService` keeps `runtimes[player][worldId]`. Each runtime is bound to its world's
`EconomyIndex` + bound `TycoonLogic` (`forWorld`), its `PlotBuilder.world(id)` builder and its
wallet key (`WorldDef.currency.key`: `"cash"` / `"bones"`). Two flags matter:

| Flag | Meaning |
|---|---|
| `ready` | the economy runs (stats cached, the tick pays it) |
| `built` | the world plot is restored (anchors + pads exist) |
| `present` | Player attr `CurrentWorld` == this world (gates IncomePop + per-cycle CycleStart writes; a change republishes every anchor) |

* **Nuke Town**: built on `PlotAssigned` exactly as before (`ready` and `built` together).
* **Another world**: the runtime starts (no plot) right after the Nuke Town runtime is ready, for
  every world with `profile.worlds.<w>.unlocked`, and on `ensureWorld(player, w, false)`. Bones
  therefore accrue from join, wherever the player is. The plot (`Workspace.Worlds.<w>.Plots.PlotN`,
  N = the main plot index) is restored by `ensureWorld(player, w, true)`: idempotent, one restore
  in flight per (player, world) (others wait on a Signal), stale builds dropped by the PlotBuilder
  generation guard. Kept until the player leaves (`PlotReleased` / `PlayerRemoving` clear it).
* **Tick**: one Heartbeat loop over every runtime of every player; one `grantCurrency(world
  currency, total, "producer")` per runtime per tick.
* **Main-only features** are gated by `WorldDef.features`: tutorial, knockdown, stand name,
  leaderstats.
* **Remotes** `PadBuy` / `ProducerClick` / `ProducerUpgrade` resolve the world from the globally
  unique id (`WorldsConfig.worldOfPad / worldOfProducer`), spend from that world's wallet
  (`trySpendCurrency`), and measure reach against that world's plot (worlds are 6000 studs apart).

### Attributes (client contract additions)

* Plot model: `WorldId` (every world, Nuke Town too: `"main"`).
* Player, per non-main world `w`: `IncomePerSecond_<w>`, `TycoonArea_<w>`, `Feature<Key>_<w>`
  (Dino: `FeatureRebirth_dino`). Nuke Town's names are unchanged.

### API (other builders)

```lua
TycoonService.ensureWorld(player, worldId, buildPlot): boolean   -- yields while restoring
TycoonService.isWorldBuilt(player, worldId): boolean
TycoonService.releaseWorld(player, worldId)                      -- drop runtime + clear plot (relock / wipe)
TycoonService.incomePerSecond / getModifiers / nextPad / hasFeature(player, ..., worldId?)
TycoonService.resetRun(player, animate?, worldId?) ; markDirty(player, worldId?)  -- nil = every world
TycoonService.grantPads(player, padIds, animate)                 -- world from the pad ids
TycoonService.WorldPadBought(player, worldId, padId, skipped) ; WorldAreaReached(player, worldId, area)
RebirthService.applyRebirth(profile, worldId?) ; RebirthService.WorldRebirthed(player, worldId, count)
OfflineService.preview(player, seconds) -> { { id, amount } }
ModifierSources.build(player, profile, offline?, worldId?) ; ModifierSources.rebirthsByWorld(profile)
PlotBuilder.world(worldId): WorldPlotBuilder ; PlotBuilder.createWorldPlots(worldId)
AreaLayouts.get / source / meshKeys(area, worldId?) ; AreaLayouts.worldHub(worldId) ; areaCount(worldId?)
PreloadList.world(worldId, tycoon?) ; worldHubKeys(worldId) ; areaKeys / plotKeys(..., worldId?)
TycoonAdmin.world{SetArea, UnlockAll, ResetRun, Wipe, SetCash, GrantCash, SetRebirths, GrantTokens,
  RebuildPlot, OfflinePreview}(player, worldId, ...)                -- W4 MultiWorldHandlers seam
```

### Economy wiring

* **Modifiers**: global providers (pets, passes, boosts, server boost, events) apply in every world;
  `rebirths` / `rebirthShop` come from the world's own track; `linkCash = WorldsConfig.linkCash(w,
  rebirths of every world)` (Nuke Town: +10 % per Dino rebirth up to 20; Dino: +5 % per Nuke Town
  rebirth up to 10). Any rebirth invalidates the player, so every world recomputes.
* **Rebirth(worldId?)**: Dino requires the world unlocked + `d6_golden_trex` + a saving session;
  empties Bones, Amber += reward, rebirths += 1, fresh Dino tycoon, Bones = Bone Stash start; only
  `profile.worlds.dino` changes. **RebirthShopBuy(key, worldId?)**: key allowlisted against that
  world's `rebirth.Shop`, paid via `trySpendWorldTokens`.
* **Offline**: one join pays Nuke Town + every unlocked world from the same elapsed / cap / rate
  (player-level); payload gains `worlds = { { id, amount } }` and `amount` may be 0; DOUBLE IT!
  doubles every row once; the no-pending fallback stays Cash.
* **Products**: `WorldCash` (Bones packs: incomeSeconds of that world's income, floor) and
  `WorldStarter` (Time Traveler Pack: fixed pet via `PetGrants.grantFixed` FIRST — refusal = nothing
  changed, receipt retried — then the boost (BoostService, lazily resolved), the Bones, and
  `worlds.<w>.starter.bought = true`; a second receipt pays the Bones only). Both are granted even
  while the world is locked (Robux are never taken for nothing). **SkipPad** buys the next pad of
  the world the buyer stands in (`CurrentWorld`, when that runtime runs), else Nuke Town.
* **Analytics**: pad / click / income / upgrade recorders are called with any world's ids (W12's
  Recorders route extra worlds to WorldRecorders); `worldAreaReached`, `worldRebirthed`,
  `worldRebirthShop`, `worldOfflinePaid`, `worldOfflineDoubled` for world events.

### Layouts + plot frames

`AreaLayouts` resolves `WorldDef.layoutFolder` (Dino: `Config/Worlds/Dino/Layouts/AreaNN`) with the
same art → partial → placeholder fallback; `LayoutLogic.validate(..., worldId)` uses that world's
finale height (D6: 140); `PlaceholderLayouts.generate(area, worldId)` themes Dino areas from
`WORLD_THEMES.dino`. A world's plot frame / locked slot come from its hub layout
(`AreaLayouts.worldHub`, Dino: ValleyLayout) once every frame mesh key is synced, else the primitive
ground + road + arch frame (warned once). Owner sign: "<DisplayName>'s <World name>".

### Tests + Studio verification (2026-10-31)

* `tests/area-layouts.luau` — every non-main world gated (placeholders complete for its geometry,
  prefixed own keys, art strict once all 6 files exist, partial before; finale height check).
* `tests/tycoon-server-logic.luau` — per-world track + linkCash (incl. caps, garbage), `upgradeCount`
  with a world's logic. `tests/preload-list.luau` — `PreloadList.world` per world.
* `TycoonTests` case **Worlds** (Studio): 8 Valley frames, layouts complete, restore + purchase.
* Studio solo playtest (lock W3), real server code + simulated receipts:
  * Nuke Town: pad bought with BuildIn, click paid, upgrade x10 (level 11), manager idle
    +10.3K / 3 s, SkipPad + CashSmall granted, knockdown PausedAt, offline join payout pending,
    rebirth +22 tokens → area 1, Dino data untouched.
  * Dino: runtime without plot, then `ensureWorld(…, true)` built `Workspace.Worlds.dino.Plots.Plot4`
    (D1 base, PlotReady), `d1_stone_bench` bought with BuildIn (main cash untouched), click +132
    Bones, upgrade, manager automated, +1378 Bones / 3 s while standing in Nuke Town, BonesSmall +279K,
    SkipPad bought the next Dino pad while `CurrentWorld = dino`, Time Traveler Pack granted
    (starter.bought), offline preview row, Dino rebirth → +10 Amber, Bones 0, area 1, plot rebuilt,
    Nuke Town rebirths unchanged, Nuke Town `linkCash` 1 → 1.1. Profile restored afterwards.

### Next steps

* Real Dino layouts (W6–W8) and ValleyLayout (W9) replace placeholders / primitive frames
  automatically (no server change).
* W4 calls `ensureWorld(owner, w, true)` before every pivot into a world plot, and
  `ensureWorld(player, w, false)` right after a mid-session unlock.
* `TeleportArea` from another world is routed through `PlotService.routeTravel(player, "main",
  "area", area)` (W4's WorldService does the trip; returns false while already in Nuke Town).
* A Dino rebirth and `TycoonAdmin.worldWipe` reset `worlds.<w>.stats.runSeconds` (W12 pacing);
  `TycoonAdmin.offlinePreview(player, hours)` returns `(true, { [worldId] = amount })` for W4.
* **Admin jumps announce areas (W12 QA fix, 2026-10-31):** `TycoonService.grantPads` (admin SetArea
  / UnlockAll / worldSetArea / worldUnlockAll, every world in `WorldsConfig`) now fires
  `AreaReached` (Nuke Town) or `worldAreaReached` + `WorldAreaReached` (other worlds), deferred
  and in order, for every area its Unlock pads open (`TycoonRules.reachedAreas`: above the area
  before the grant, each once). World unlocks (Dino at Nuke Town area 3, Moon at area 5), badges
  and the world funnel follow an admin jump like natural purchases. `PadBought` stays purchase-only.
  Tested in `tests/tycoon-server-logic.luau` (every world: unlock-all = areas 2..N once, in order,
  equal to natural purchases; setArea 3 -> 2, 3; a second jump never re-announces).
