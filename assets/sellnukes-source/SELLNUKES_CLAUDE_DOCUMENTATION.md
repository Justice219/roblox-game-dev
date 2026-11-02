# SellNukes — living system documentation

How the game's systems connect, their schemas and remotes, and what comes next. Newest dated
entries first under "Change log". Read only the section you need (grep the headings).

## 1. Big picture

SellNukes is an 8-player linear button tycoon (spec: `docs/superpowers/specs/2026-10-30-sellnukes-design.md`,
build plan + contracts: `docs/superpowers/plans/2026-10-30-sellnukes-build.md`). It reuses the
RoBeasts framework (`~/IdeaProjects/RoBeasts`): Create/Theme/Components/ScreenManager stud UI, the
ordered `Init()/Start()` service boot, session-locked ProfileStore, profile delta sync, the
idempotent receipt pipeline, and the Blender → Roblox mesh pipeline.

```
Client (src/client)                         Server (src/server)
  ClientState  <-- ProfileUpdate/Delta ---    PlayerDataService (ProfileStore, session lock)
  UI (StudUI kit, HUD, Screens)                MonetizationService (receipts, passes)
  Tycoon controllers (build-in, billboards)    Tycoon (PlotService, TycoonService, Offline, Rebirth)
        |  intents only (ProducerClick,        World (MeshLibrary, WorldMaterials, Hub/PlotBuilder)
        |  PadBuy, ProducerUpgrade, ...)       Retention / Pets / Crates / Attack / Event services
        v                                            |
  src/shared: Net/Remotes + Validate, Config/*, Tycoon/TycoonLogic (pure), Util/*
```

## 2. Studio + tooling

- Studio MCP: `@chrrxs/robloxstudio-mcp` v3.2.1 on `127.0.0.1:58741`, driven with
  `scripts/studio_mcp.py` (token from `~/.robloxstudio-mcp/auth-token`). Not the old port-3001 bridge.
- Place "Sell Nukes [🎃]": placeId `132667741281890`, universe `10773845696`, owner user `1586034782`.
- Rojo 7.7.1 serves `default.project.json` on :34872.
- Playtest mutex: `scripts/studio-lock.py acquire|release <name>` (lock dir `~/.cache/sellnukes/`).

## 3. Systems (filled in as each wave lands)

| System | Server | Client | Config | Doc |
|--------|--------|--------|--------|-----|
| Boot (two-tier: critical core fails fast, features isolated by name) | `init.server.luau` CRITICAL + FEATURE_SERVICES | `init.client.luau` ORDERED_NAMES (slash paths) | — | this file |
| Profile, sync, monetization, New Player Mode | `Services/PlayerDataService`, `Services/MonetizationService`, `Economy/*` | `ClientState`, `ProfileSyncClient` | `MonetizationConfig`, `PublishedProductIds` (35 live ids) | `docs/core.md`, `docs/monetization.md` |
| Analytics | `Services/AnalyticsService`, `Analytics/*` | `Analytics/ClientAnalytics` | `AnalyticsConfig`, `AnalyticsMarks` | `docs/analytics.md` |
| Admin panel (owner) | `Services/AdminService`, `Admin/*` | `UI/Screens/Admin/*` | `AdminConfig` | `docs/admin.md` |
| Tycoon (lobby + random plot, pads, producers, offline, rebirth, teleports) | `Tycoon/*`, `World/PlotBuilder`, `World/HubBuilder` | `Tycoon/*`, screens Teleport/Rebirth/RenameStand/TycoonTutorial | `TycoonConfig`, `TycoonAreas/*`, `WorldLayout`, `AreaLayouts/*`, `HubLayout` | `docs/economy.md`, `docs/tycoon-server.md`, `docs/tycoon-client.md` |
| World art + meshes (180° import yaw fixed; player-first load order: WorldReady = first view, deferred scenery, `holdWorldReady`) | `World/MeshLibrary`, `World/WorldMaterials` | — | `MeshAssets` (252 models), `WorldMaterialConfig`, `Shared/World/{MeshPlacement,PreloadList,ZFight}` | `docs/world-art.md`, `docs/areas-art.md` |
| Build-in + world FX (motion groups, glow caps) | — | `Tycoon/BuildIn/*`, `Tycoon/Fx/*` | `BuildInConfig`, `WorldFxConfig` | `docs/build-in.md` |
| Audio | — | `Audio/SoundController`, `Audio/Sound` | `AudioConfig`, `SoundAssets` | `docs/audio.md` |
| Stud UI kit + HUD + button feedback + money-fly FX (R46) | — | `UI/*`, `UI/Kit/StudUI`, `UI/Hud/*` (incl. `CurrencyFly`), `UI/ButtonFeedback` | `UIStyleConfig`, `IconAssets` (103 icons), `CurrencyFlyConfig` | `docs/ui.md` (§7d money fly), `docs/icons.md` |
| Shop 3D models (R39: real game models in rotating, lit viewports; icon only while loading) | — | `UI/Widgets/ModelViewport` (+ pure `ModelViewportLogic`: exact turntable framing, live budget), `UI/Screens/Shop/{ShopModels, ShopText}`; spins only on screen via `Widgets/OfferFx`, ≤ 12 live (High) / 8 (Mid) / 0 (Low, Reduce Motion) | `ModelViewportLogic.Config`, Shop_* props in `MeshAssets` (`tools/blender/models/shop_props.py`) | `docs/verification/world-qa/README.md` (`tools/qa/shop_models.py`), `tests/model-viewport.luau` |
| Retention + shop | 10 services (Settings … Shop) | 10 screens | `RetentionConfig`, `PlaytimeConfig`, `LuckySpinConfig`, `CodesConfig`, `GroupConfig`, `BoostConfig`, `ShopConfig` | `docs/retention.md` |
| Pets / eggs / crates | `Services/PetService`, `Services/CrateService`, `Pets/*` | `Pets/*`, screens Pets/EggHatch/CrateShop/CrateOpen | `PetConfig`, `EggConfig`, `CrateConfig` | `docs/pets.md` |
| Harvest Feast event, leaderboards, badges | `EventService`, `LeaderboardService`, `BadgeService` | `Event/*`, `Leaderboards/*`, screens StickerSheet/EventShop | `EventConfig`, `LeaderboardConfig`, `BadgeConfig` (first ten configured; eight ids 0) | `docs/event.md`, `docs/leaderboards.md` |
| Attack side mode | `DefenseService`, `AttackService`, `Attack/*` | `Attack/*`, screens AttackTarget/Defense | `AttackConfig` | `docs/attack.md` |
| Area knockdown (R50: hits temporarily knock an area down) | `Tycoon/Knockdown` (+ `TycoonService` pause, `Admin/Handlers/KnockdownHandlers`) | `Tycoon/BuildIn/KnockdownFx`, screen Knockdown/KnockdownHud; hooks in BuildIn / WorldFx / ManagerController | `KnockdownConfig`, `Shared/Tycoon/KnockdownLogic` | `docs/attack.md` §13 |
| Launch cinematic (R54: follow the missile, 3-2-1 + voiceover) | — (uses the server lead-in, `AttackConfig.Flight.LeadIn`) | `Attack/LaunchCam`, screen LaunchCountdown (`LaunchCountdownScreen` + `CountdownOverlay`) | `LaunchCamConfig`, `Shared/Attack/LaunchCamMath` | `docs/attack.md` §15 |
| WHAT'S NEW change notes (R58, RoBeasts port: returning players only, bottom-right chip) | `Services/ChangeNotesService`, `Admin/ChangeNotesAdmin`, `Economy/ProfileLogic` (`notes`) | `ChangeNotes/ChangeNotesClient`, screen WhatsNew, `UI/Hud/HudWhatsNew` (+ `Widgets/HudPlacement` corner), Settings label | `ChangeNotesConfig`, `VersionConfig` (0.9.0), `Shared/Util/ChangeNotesLogic` | `docs/change-notes.md` |
| Map vehicles + machines (R56: van / semi / shopper car drive in + out, mine carts, forklift, scooters, belt rockets, garage barrier) | — (layouts place them; no collision boxes) | `Tycoon/Fx/VehicleRoutes` (+ pure `Tycoon/Fx/RouteMath`) | `VehicleRouteConfig`, `WorldFxConfig.RoutedModels` | `docs/build-in.md` §4b |
| Lobby centre (R55: fountain + Nukey statue, paths, gardens, ambient FX) | `World/HubBuilder` (models, colliders, AmbientFx emitters) | — (WorldFx animates the pieces) | `HubLayout` ("Lobby centre" block), `HubAmbientConfig`, `WorldFxConfig` rows | `docs/areas-art.md` "Lobby centre (R55)" |
| Worlds (Nuke Town `main`, Dino Valley `dino`, Moon Base `moon`; add a world = config + art) | `Tycoon/WorldService`, `Tycoon/TravelRules`, `World/HubBuilder.buildWorld` | `Worlds/*` (incl. `WorldGravity` + `GravityLogic`: per-world gravity, Moon ×0.4) | `Worlds/WorldsConfig`, `Worlds/WorldGeometry`, `Worlds/{Dino,Moon}/*`, `WorldClientConfig` (Lighting / Physics / Portals / Offers), `WorldGravityConfig` | `docs/worlds.md`, `docs/superpowers/specs/2026-10-31-r69-moon-lucky-juice-design.md` |
| Lucky Buttons (R69: free + Robux buttons pop up on your own plot) | `Services/LuckyButtonService` (one 1 Hz loop, layout-based placement cache) | `LuckyButtons/*`, `UI/Screens/LuckyButtons/*` (toast + edge arrow) | `LuckyButtonConfig`, `Shared/Tycoon/LuckyButtonLogic` | `docs/lucky-buttons.md`, `tests/lucky-buttons.luau` |
| Juice pass (R71: click combo, celebrations, fireworks, camera punch, ambient sparkles) | — | `Tycoon/Fx/{JuiceController, ClickCombo, JuiceBanner, Fireworks, CameraPunch, JuiceParticles, ProducerJuice, ImpactBursts}` | `JuiceConfig`, `AudioConfig`, `SoundAssets` | `docs/juice.md`, `docs/audio.md` §8 |
| Player titles (R73/R74: DEVELOPER, FIRST PLAYER, EARLY PLAYER; overhead tag + chat prefix) | `Services/PlayerTitleService` | `Social/*` | `PlayerTitlesConfig`, `Shared/Util/PlayerTitles` | `tests/player-titles.luau` |
| Animated workers (R75: Glow Rock miners swing, A9 astronaut waves) | — | `Tycoon/Fx/WorldFxController` (`swing` motion) + `ImpactBursts` | `WorldFxConfig` (`PickSwing`, `MinerLean`), `Shared/World/SwingCurve` | `docs/build-in.md` "W7 R75" |
| Progress bus (R78: every gameplay success path fires one line; Quests + Pass listen) | `Progression/ProgressEvents` (fires in Tycoon / Pet / Crate / LuckySpin / Retention / Playtime / Rebirth / LuckyButton / Event / World services) | — | stat ids in the module | spec `2026-10-31-r78-retention-pack-design.md` §1.1 |
| Quests (R78: 12 starter goals on the objective chip, 3 daily missions + Daily Chest + 1 reroll, 9 tiered trophies) | `Services/QuestService` (once-a-minute `playMinute` tick), `Quests/QuestLogic` | `Quests/{QuestClient, QuestObjective, PassBridge}`, screen `Quests` (`init`, `QuestRow`, `PassBanner`), `UI/Hud/HudObjective` (goal chip after the tutorial) | `QuestConfig` | `docs/quests.md`, `tests/quest-logic.luau` |
| Nuke Pass (R78: Season 1 "Harvest Season" 2026-11-01 → 12-01 UTC, 30 tiers × 400 XP, free + premium track, overflow chests, end-of-season auto-grant) | `Services/PassService` (Xp listener + play-XP tick), `Pass/PassLogic`, NukePassPremium receipt (dev product 3725022864, 159 R$) | screen `NukePass` (`init`, `TierStrip`, `PassView`), HUD right-column `Pass` offer | `PassConfig`, `MonetizationConfig`, `CrateConfig` trail `harvest_glow`, `PlayerTitlesConfig` (SEASON 1, NUKE PASS), icon `NukePass` | `docs/nuke-pass.md`, `tests/pass-logic.luau` |
| Rush boosts + Friends (R78: Rookie Rush 2x 15 min, Comeback Rush 2x 10 min after 48 h away, Friend Boost +10 %/friend ≤ +50 %, invites, referral rewards ≤ 10) | `Services/{RushService, FriendService}`, `Social/{RushLogic, FriendLogic}`, modifier fields `rushCash` / `friendCash` (offline = false), DataStore `SellNukesReferrals_v1` | `Social/{SocialClient, BoostChipLogic}`, screens `BoostChips`, `Friends`, Rewards-hub tile `Friends`, Welcome Back comeback banner | `SocialConfig`, `RewardsHubConfig`, icon `Friends` | `docs/social.md`, `tests/social-logic.luau` |
| Pet Index rewards + Golden Nukey (R78: milestones 5…60 + all → gems + permanent Index Bonus up to +30 % petCash; exclusive pets excluded from "all") | `Services/PetService` (`PetIndexClaim`), `Pets/PetIndexLogic` | `UI/Screens/Pets/IndexRewards`, Pets HUD badge | `PetIndexConfig`, `PetConfig` (`golden_nukey`, mesh `SparkleNukey`) | `docs/pets.md` (R78), `docs/pets-art.md` §12, `tests/pet-index.luau` |
| Join flow + FTUE (R78: one join-time pop-up queue, non-blocking tutorial strip, device-correct hints, real loading time, steps `tutorialSeen` / `firstMove` / `firstScreenClosed` + `loadingDone` / `hudShown` now sent) | `Analytics/Sessions` (validated FunnelStep) | `Platform/{JoinFlow, JoinFlowLogic}`, `Tycoon/{FtueTracker, TutorialText, Tutorial}`, screen `TycoonTutorial` | `FtueConfig`, `Shared/Analytics/{FtueLogic, NewPlayerFunnel}` | `docs/verification/r78-ftue/README.md`, `tests/ftue-logic.luau` |
| Menu focus + window handoff (R79: HUD side columns hide while any modal is open; `ScreenManager.handoff` hub → child → back; HudZones "Bottom" = the real objective chip) | — | `UI/ScreenManager` (handoff, handedOffTo), `UI/Hud/Hud` (MenuLayer, publishBottom), `UI/Widgets/GuiFade` (nested-fade finish), `Platform/HintBar` | `HudFocusConfig` | `docs/ui.md` §6, `docs/verification/r79/` |
| AA tower defences + attack for everyone + Golden Revenge Nuke (R80: 4 buyable tower slots outside the side curbs, L1–L5, every tower engages; R85: Launcher L1 for all, protection = tutorial + 300 s (`AttackGrace`), RevengeNuke 3725620060 31 R$ stored charge) | `Services/DefenseService`, `Attack/*` | `Attack/DefenseWorld`, screen `Defense` | `AttackConfig.Towers` | `docs/attack.md` |
| Lucky Wheel juice (R81: pegs + flapper ticker, wind-up, bulbs, win FX) | — | `Screens/LuckyWheel/{WheelFx, SpinMotion, WheelDrawing}` | `LuckyWheelFxConfig` | `docs/juice.md` §9, `docs/verification/r81-wheel/` |
| Boost badge (R82: corner sticker on the cash counter + breakdown card) | — | `Screens/BoostChips`, `Social/BoostChipLogic`, `Hud/HudCurrency` (BoostCorner, linkNav) | `SocialConfig` Badge* | `docs/social.md` |
| Auto-click quest credit (R83) | `Tycoon/TycoonService` tickRuntime, `TycoonRules.autoClickCredit` | Quests AUTO ON chip | `QuestConfig.AutoClickCreditPerSecond` | `docs/quests.md` |
| Tutorial button focus + gem upgrade (R84 ring + glyph on the exact billboard button; R86 one level for 75 gems with confirm) | `TycoonService` ProducerGemUpgrade, `Tycoon/GemUpgradeSettings` | `Tycoon/{TutorialHighlight, TutorialFocusLogic, GemUpgrade, GemConfirmLogic}`, `Hud/PointerLogic` | `TycoonConfig.GemUpgradePrice`, `Shared/Tycoon/GemUpgradeRules` | `docs/economy.md`, `tests/gem-upgrade.luau` |
| Manager nametags (R87) | — | `Tycoon/Npc/*` (ManagerTagLogic) | `ManagerNpcConfig` | see R87 report |
| Plot names (R88: front-sign rename, filtered, survives Rebirth) | `Tycoon/{PlotNames, PlotNameAdmin}`, `PlotBuilder.setPlotName` | `Tycoon/PlotSign`, screen `RenameStand` (plot mode) | `PlotNameConfig`, `Shared/Tycoon/PlotNameLogic` | `docs/plots.md` |
| Surprise Batches + Flavour Book + Big Pop (R89 §1: server flavour roll per batch — Sprinkle 1/20 x1.5 … Mystery 1/25,000 x100, +7.1% avg income; reveal; server banner) | `Tycoon/{FlavorService, BigPop, FlavorAdmin}` (TycoonService pay hook) | `Tycoon/FlavorController`, `Tycoon/Fx/{FlavorPops, FlavorGlow, BigPopBanner}`, screens `FlavorReveal`, `FlavorBook` (Pets → FLAVOURS) | `FlavorConfig`, `Shared/Tycoon/FlavorLogic` | `docs/flavors.md`, `docs/economy.md` |
| Nukey's Happy Hours (R89 §2: UTC schedule, 5-min headline at :00 + 3-min surge at :30; admin force / stop / skip / kill across servers) | `Services/HappyHourService`, `HappyHour/{HappyHourOverrideStore, HappyHourPickups}` | `HappyHour/*`, screens `HappyHour/{HappyHourChipScreen, HappyHourScheduleScreen}` | `HappyHourConfig`, `Shared/Events/{HappyHourLogic, HappyHourPickupLogic}` | `docs/happy-hours.md` |
| Gift ladder v2 + Pocket Rocket + favorite prompt (R89 §3: gifts at 1–120 min, same-day carry, CLAIM ALL; PocketRocket 3725469699 19 R$ / 300 s once per UTC day; one unrewarded favorite prompt) | `Services/PlaytimeService`, `Retention/{GiftsLogic, PocketRocket, FavoritePrompt}` | screen `TimeRewards` (+GiftGrid, FavoriteClient), `Hud/HudOffers` | `PlaytimeConfig`, `GiftsConfig` | `docs/gifts.md` |
| Roblox-algorithm analytics (R122: `rbx:*` bounce < 60 s / 61–180 s, capped playtime, qualified sessions, co-play; refusal reasons; admin "Roblox algorithm scorecard" + "Client boot steps by device") | `Analytics/{Sessions, ReportSections, AnalyticsLogic, BuildMetrics}` | `UI/Screens/Admin/AnalyticsTab` | `AnalyticsConfig.Algorithm` (targets) | `docs/analytics.md` "Roblox signals", `docs/analytics-scorecard.md` |
| Return notifications (R122: one personal notification per opted-in 13+ player per day — cashFull / streak / missions — MemoryStore due queue, any server sends via Open Cloud, dry-run without the secret; opt-in card after the first manager hire) | `Retention/ReturnNotify{Logic,Queue,Sender,Runner,Control,Admin,Service}`, `Services/NotifyRewardService` | `Screens/NotifyPrompt` (+ `PromptMoments`), `Screens/Admin/NotifySection` | `NotifyConfig` (message ids, secret name), `PopupQueueConfig.notifyPrompt` | `docs/retention.md` |
| Co-play + purchase hygiene (R122: HUD INVITE + Friend Boost badge, one invite moment after area 2, paid Lucky Button DEAL card, PurchaseGuard: no screen opens focused on BUY, chips open their card first) | `Services/FriendService`, `Services/LuckyButtonService` | `Hud/HudInvite`, `Social/InviteClient`, `Screens/{InviteMoment, DealCard}`, `UI/PurchaseGuard`, `Widgets/ActionCard` | `InviteConfig`, `PurchaseFocusConfig`, `LuckyButtonConfig` | `docs/social.md`, `docs/lucky-buttons.md` |
| Fast loading hand-off (R122: critical vs deferred preload, 6 s asset budget, tap 20 s / auto 30 s, background preload, boot-step telemetry) | `Analytics/ClientPerfIngest` | `src/first/LoadingScreen/{Readiness, PreloadQueue, Loader}` | `PreloadList` critical/deferred, `ClientPerfConfig` | `docs/performance.md` |
| Movement (faster run + wind) | `MovementService` | `Movement/WindController` | `MovementConfig` | `docs/movement.md` |
| Console + mobile platform layer | — | `Platform/PlatformController` | `PlatformConfig` | `docs/platform.md` |
| Loading screen + brand | — | `src/first/LoadingScreen` (ReplicatedFirst) | `BrandAssets` | `docs/brand.md` |
| Marketing (store icon, 9 thumbnails, 10 ads) | — | — | — | `assets/marketing/2026-10-30-*/README.md` |

## 4. Next steps

0.9.0 owner action: publish the ten wired badge IDs, three notification-template IDs and
`HttpEnabled = true`, then start new server instances. The notification-only Open Cloud key is
Active and stored as `SellNukesNotifyKey`, restricted to `apis.roblox.com`; the secret is available
only to new instances. Free private servers are enabled in Creator Dashboard. See
`docs/retention.md` for the live delivery check after publication.

0.8.0 (R122 "Algorithm pack") owner actions: publish with "Migrate to Latest Update"; run
thumbnail A/B tests in Creator Hub (play-through rate is Roblox's top signal and is decided by
the tile). Team next: after ≥ 7 complete UTC days
on 0.8.0, read the admin "Roblox algorithm scorecard" + the `build:0.8.0:*` slices and record
KEEP / REVISE / REVERT in `docs/analytics-scorecard.md`; read the new boot-step rows to find the
slow loading step on phones; areas 2–10 run 11–18 % faster than target (area 2 at −18 %) —
retune with `tests/economy-sim.luau --tune --upto <n>` only if the live pacing agrees.

0.7.0 owner actions: publish with "Migrate to Latest Update". Next waves: R89 wave 2 (Frosting Coats, Gift It, Rebirth Perk
Draft), R90 (Mega Lever, Tip Jar — spec
`docs/superpowers/specs/2026-10-31-r90-hands-on-design.md`; its Order Window was removed by owner
R128, see `docs/orders.md`).

R78 (0.6.0) owner actions: publish with "Migrate to Latest Update" before 2026-11-01 00:00 UTC so
Nuke Pass Season 1 starts with the Harvest Feast; post code QUESTS in Discord; the `NukePass`
icon (117642180669672) shows once Roblox moderation approves it. Team next: read the first
post-0.6.0 day of analytics (new FTUE steps `loadingDone` / `tutorialSeen` / `firstMove` /
`firstScreenClosed`, `quest:*`, `pass:*`, `rush:*`, `friends:*`) and retune the starter goals /
Rush length from it; plan Season 2 in `PassConfig` before 2026-12-01.

Earlier owner actions: publish 0.2.0, re-check paid-random behaviour live, THEN change the Creator Dashboard
paid-random questionnaire answer to Yes (all repo gaps closed, f07ba5e); upload ads (Ads Manager); give a group id for
`GroupConfig.GroupId`, publish the ten wired badges and create the remaining eight (BadgeConfig ids), optionally refresh the Studio MCP Open
Cloud key. Team: Studio verification queue (admin, retention, tycoon client/server, event, attack,
pets, platform, audio/FX, loading screen), World-QA tour, animated managers (B18), z-fight
ratchet to 0, ad 9 creative.

(Older plan text below kept for history.)

Wave 2: tycoon server + client (plots, pads, producers, build-in, billboards, tutorial), retention +
shop screens, Blender content for areas 2–10 + hub + pets + icons. Wave 3: pets/eggs/crates, attack
mode, Harvest Feast event, leaderboards/badges, live product ids, full multiplayer playtest + perf.

## Change log

### 2026-11-01 — R138 phone chip placement + R140 skill finished

R138: the Studio check found the first fix sitting above the character on a measured iPhone 14. The chip
is now a fixed 159 design px, `HappyHourChipLogic` gained `underTopRight`, tests use measured zones, and
the winning spot is the attribute `HappyHourChipSpot`. Captures: docs/verification/r138/. R140: the skill
now bundles the source and a sync script: `python3 scripts/sync_from_game.py <this repo>` in the skill
repo, after big changes. Also corrected the R135 wording in docs/analytics.md and `FtueLogic`: 148 vs 429
compared players with sessions.

### 2026-11-01 — R139 the `roblox-game-dev` skill (docs only)

Everything documented about building this game now also lives in a Claude Code skill, private repo
https://github.com/Justice219/roblox-game-dev (install: clone into `~/.claude/skills/roblox-game-dev`).
This repo stays the source of truth; refresh the skill when `docs/`, `CLAUDE.md` or the scripts
change a lot. docs/core.md corrected: `HttpEnabled = true` since the return notifications.

### 2026-11-01 — 0.9.2: faster Garage Lab opening + Nuke Stand manager at pad 4 (owner R137)

Owner: "do whatever you want and fix" (after the R135 / R136 reports: ~50 % of first sessions end
within 3 min; 150 opened area 2 → 102 hired its Cashier Bot at pad 8 of 10 → 82 opened area 3).
Builder W-R137-econ, sim-measured (`tests/economy-sim.luau`):
- **Area 1** (`TycoonAreas/Area01`, same pad order, SCALE 6.49): Tool Wall $42 → $11 (1.10 → 0.48
  min), Glow Lamp $260 → $19 (1.61 → 0.64), Uncle Atom 1.93 → 1.22 min, Garage Door 2.54 → 1.90;
  longest pad-less stretch in the first 2 min 63 → 41 s; largest later step 8.5x → 7.0x; area
  8.0 → 7.0 min (two Workbench milestones fix the later pads; income at the Unlock unchanged, so
  areas 2–10 play exactly as before). Tool Wall stays above $10 (R65 rule, tests/tycoon-logic).
- **Area 2** (`TycoonAreas/Area02` + `AreaLayouts/Area02`, SCALE 269): Cashier Bot pad 8 → 4 (6.5
  → 0.85 min after the area opens), longest wait 189 → 132 s, largest step 5.9x → 4.3x, length
  12.53 min unchanged; pad row re-spotted (Cashier Bot at +24, Tip Jar … Picket Fence one spot out);
  pad ids unchanged, old-order saves keep every pad (`tests/stand-order.luau`, 628 checks).
- Sim OPENING_CHECKS: area 1 manager ≤ 1.5 min, wait ≤ 85 s, ≤ 45 s without a new pad in the first
  2 min; area 2 manager ≤ 2.0 min, wait ≤ 150 s. `--tune` fixed (scans nearby SCALEs instead of
  assuming one failure boundary). Snapshot refreshed (70 values). docs/economy.md "Nuke Stand
  order (R137)", docs/tycoon-server.md.
- VersionConfig 0.9.2 (PATCH, tuning) + two IMPROVED lines on the newest note. TycoonConfig.Pacing
  keeps area 2's 8 min target (the report's pacing table will read ~7 min = faster than designed).
Owner eyeball (R132, code checks only): the area-2 pad row and the $11 / $19 area-1 billboards.
Measure on the 0.9.2 build slice: `build:0.9.2:*` manager / area2 / area3 rates, bounce 61–180 s.

### 2026-11-01 — R137 offer BUY presses recorded (purchase funnel "click", measurement only)

`Revenue.offerClicked` had no caller, so every purchase-funnel "click 0 (0%)" was missing data.
Now `MonetizationService`'s PromptProduct / PromptPass handlers fire a server Signal
`PromptRequested(player, key, kind, source)` after the prompt rate limit + catalogue-key check and
BEFORE any prompt refusal; `AnalyticsService.Start` wires it to `Revenue.promptRequested`, which
counts `offer:<id>:click` + `funnel:<id>:click` for the offer surfaces only
(`AnalyticsConfig.OfferClicks.Sources`: shop / offer / welcomeBack), via the pure
`AnalyticsLogic.offerClick` (typeof / length / offer-id allowlist, 1 s double-tap merge, 60 per
session cap) behind its own token bucket; refusals → `ops:clientRefused:OfferClick:<reason>`. No
new remote, no client change. The report (`ReportSections`) shows "click n/a" / "clicks n/a" when
the range has no click key at all (days before R137) and drops empty "()" percentages; row ids and
values unchanged. Docs: docs/analytics.md "Purchase funnel click step". Tests:
analytics-logic §5, analytics-recorders §4b + §9, analytics-report §2b.

### 2026-11-01 — R136 return-notification failure reasons (measurement only)

Owner: "a little more time has passed today" (report to 22:27 UTC). Return notifications went live:
21 ok, 59 rejected — all `cashFull` (streak / missions are due tomorrow). The key works (21 ok), so
the rejections are per-player 4xx; Roblox only delivers to opted-in players 13+ and answers 400
otherwise. The status lived only in the admin ring, so `ReturnNotifyLogic.statusBucket` +
`ReturnNotifyRunner.noteStatus` now count `rnotify:status:<kind>:<400|401|403|404|429|4xx|5xx>`
(docs/retention.md, AnalyticsConfig metric doc, tests/return-notify.luau incl. a 400 run that
neither backs off nor stops the poll). Offline payouts = 84 % of the day's cash came from one
late-game player (areas 7–10) at the designed 50 % × 3 h — no bug. Findings: owner-requests R136.

### 2026-11-01 — R135 analytics check-in: scorecard denominators + tutorialSeen race (measurement only)

Owner: "any news on analytics?" (report TODAY to 17:33 UTC). Two measurement bugs fixed; no
player-facing change, so no version bump. (1) **Scorecard denominators**
(`Server/Analytics/ReportSections` `algorithmSection` + `coveredPlayerDays`): first-play bounce
divides by the first sessions R122+ servers classified (Σ `rbx:bounceDev:*`), not `ftue:joined`;
on a mixed-build range playtime / qualified sessions / co-play divide by the player-days of builds
with `build:<b>:rbx:*` slices (clamped to `dau`). Those rows keep a real verdict plus a
`SAMPLE: R122+ servers only (…)` note (`Signal.sample`); PARTIAL stays for mixed ranges without
build slices and for the return-day rows. The live report read bounce 5.9 % / 9.6 % and playtime
1.6 min where the R122+ sample is 21 % / 35 % and 5.9 min. (2) **tutorialSeen race**
(`Shared/Analytics/FtueLogic.claimReady`, `Client/Tycoon/FtueTracker`): the client sent
`tutorialSeen` / `firstScreenClosed` during the plot reveal; the server refused them
(`claimPlausible` needs PlotRevealed) and the once-per-session send was spent, so builds ≤ 0.9.1
under-read the step (148 vs 429 `tutClient:1`). The client now waits for the replicated
PlotRevealed attribute. Tests: `tests/analytics-algorithm.luau` §4 / §4b (incl. the live numbers),
`tests/ftue-logic.luau` §4b (client readiness matches the server rule for every client step).
Findings + proposals (area 2 manager at pad 8 of 10, the first two minutes, offer BUY presses never
recorded): `docs/owner-requests.md` R135. Next: read `build:0.9.x:*` D1 on 11-02.

### 2026-11-01 — 0.9.1: the attack picker shows the base (owner R133) + hub teleport pads removed (R134)

**R133** "when attacking people all I see is this, not their base still". There were two root causes,
both shipped in 0.8.0 without a Studio pass (details: `docs/attack.md` §21):
1. The big grey panel was the R118 info plate. Its `UIListLayout` sat directly on the studded plate,
   so it stacked the `StudWindow.surface` decorations (TopHighlight, PanelBackdrop) as list items,
   and `AutomaticSize` grew the plate to ~550 px over the middle of the screen. The lines now live in
   an inner `Content` frame and the plate height is explicit (`fitInfo`).
2. The camera looked from ~890 studs, which a live client does not draw (both streaming fixes left
   the sky empty). New pure module `Shared/Attack/PickerFrame` frames the target's BUILT areas as
   close as they fit between the name plate and the button row: a new garage at 156 studs, max 320
   (`AttackConfig.Client.PickerFrame`, `PickerFov` 52 → 66). A big base keeps the AIMED area in view,
   and cycling the aim pans the camera.

The stream focus now sits on the built base too:
- `PickerStream.focusPoint(slot, areas)` = `PickerFrame.streamPoint`.
- The server reads the target's areas from its server-set `SN_AttackAreas` (`PickerFocus.builtAreasOf`)
  and re-centres on every keep-alive.

Tests: `tests/attack-view.luau` §2 (every plot × 16 area sets × every aim × 5 aspects) and §8 (the
chip layout through the real camera, plus source rules against the plate regression).

**R134** "can we remove these little teleports" (builder W-R134-pads). Every hub (Nuke Town lobby,
Dino Base Camp, Moon Landing Plaza) loses its plot teleport pads:
- Removed: models, digits, colliders, labels, the `PlotTeleportPads` anchors, HubBuilder triggers /
  `setPlotOwner` / the neon-portal fallback, and PlotService's pad handler and `visit` hook.
- The numbered plot gates at r 222 stay. Owner names show only on each plot's entrance sign.
- Players walk, or use the Teleport menu (hub, own areas free, other plots with the Teleporter pass).
  The plot reveal still walks a new player home.
- Test: `tests/hub-no-teleport-pads.luau`. Docs: `areas-art.md`, `tycoon-server.md`, `plots.md`,
  `worlds.md`, `tycoon-client.md`. The pad meshes stay unused in `MeshAssets`.

Release: `VersionConfig` 0.9.1. The 0.9.0 note's IMPROVED section gains "Attack view now shows your
target's base up close!" and "Tidier lobby: no more plot teleport pads. Walk or use Teleport!".

Owner eyeball (R132: code checks only):
- Attack on a new / mid / full base (no grey panel, base fills the middle, ↑ / ↓ pans on a full base).
- The three hubs with clear paths at r 62.
- In Dino / Moon, walking to a plot whose owner has not visited that world this session shows an
  empty frame. The Teleport menu builds it.

### 2026-11-01 — Five more Roblox badges, notification IDs and free private servers

Created and enabled the next five badges in universe `10773845696`: Rocket Factory
`2219908620256793`, Launch Silos `1208252337094160`, Nuke Megastore `1173136756556691`,
Space Port `1960543602511361`, and Mega Nuclear Facility `4266422855011413`. The dashboard
shows all ten created badges Active. `BadgeConfig` connects these IDs to the existing Area6–Area10
definitions without reordering persisted ownership bits or changing qualification. Awards still
use server-validated Nuke Town progression, bounded ownership checks, and Roblox's native badge
notification. Eight later milestone IDs remain zero. Art and generation provenance:
`assets/marketing/2026-11-01-badges/README.md`; dashboard proof:
`docs/verification/creator-dashboard/second-five-badges.png`.

Created and reloaded all three return-notification templates, then wired their UUIDs in
`NotifyConfig`: cashFull `69dbd79b-5308-924f-96bd-8559db8ae66f`, streak
`31d33d80-7cd8-b34c-8b86-8dc056f9e575` (parameter `day`), missions
`2418369b-d35f-754a-bffd-3a1beac68bb5`. Existing eligibility, consent, daily limits, server-only
queue and fixed Open Cloud endpoint remain unchanged. Tests explicitly inject empty IDs for
disabled-mode coverage and verify the configured production payloads. After the owner's explicit
"yes do it", created the Active key `Sell Nukes Return Notifications` with only
`user.user-notification:write` restricted to this universe, saved it as `SellNukesNotifyKey`
restricted to `apis.roblox.com`, and enabled `HttpEnabled` in the Rojo project. The key value
was never written to disk or screenshots. New server instances and the published code/settings
are required for delivery; no live notification was sent. See `docs/retention.md`.

Enabled **free private servers** in Audience → Advanced settings, saved, and reloaded to verify
Allow private servers = on and Requires Robux = off. Existing device selections and capacity
were retained. Proof: `docs/verification/creator-dashboard/free-private-servers.png`.
Version `0.9.0` and a new WHAT'S NEW entry announce the badges and free private servers.
The dashboard changes are live; the owner must publish the code update for runtime badge IDs.
Validation: `./scripts/check.sh` **ALL PASSED** in managed checkout
`~/.codex/worktrees/4399/SellNukes` at `5578a36` plus this task's changes:
formatting, Selene, strict Luau type-check, Studio-style compile, and **108 standalone suites**.
Badge integration: 239 checks; notification sender/queue: 1,064; notification prompt: 62.
The shared-tree check encountered an unrelated WorldClientLogic formatting edit while Claude's
Order-removal/world changes were in flight, so they were not reformatted or included here.
No Studio playtest or publication was performed; live notification delivery is untested until
the owner publishes and starts new server instances.

### 2026-11-01 — R130 Dino Valley popup timing + BoomDash Delivery re-pace (0.9.0)

Owner: "fix these two" (R129 findings). (1) The WORLD UNLOCKED popup no longer opens by itself in the
area that unlocked the world (Dino: area 3, ~minute 14 — 19 / 41 pressed GO NOW and left their fresh
area for a world at zero Bones): `WorldClientLogic.unlockPopupOwed` / `popupArea` gate it to Nuke Town
area unlock + `WorldClientConfig.Unlock.PopupAreasAfterUnlock` (Dino 4, Moon 6) or any rebirth; a world
unlocked in an earlier session owes it when that area is crossed this session and the world was never
visited. `WorldClient` tracks the session's start area and re-checks only on an area change / rebirth;
`popupState()` exposes the gate. Unlock rule, chip, Teleport tab, NEW dot and portal unchanged
(docs/worlds.md). (2) BoomDash Delivery: Dispatcher moved to pad 4, multiples re-shaped, SCALE 22,100 ->
25,000 — sim Dispatcher at 1.7 min (was 18.2), longest wait ~4.4 min (was 6.7), area length unchanged
(22.2 min); `tests/economy-sim.luau` `OPENING_CHECKS` is now a list per world (area 1 + area 3; the tuner
guards the area it tunes); `tests/boomdash-order.luau` proves old-order saves; snapshot refreshed
(docs/economy.md + docs/tycoon-server.md "BoomDash order"). Watch after release: `padAt:a3_dispatcher`,
`areaN:4` / `ftue:area4`, Dino `popup:*` + `step:dino:firstPad` per visitor.

### 2026-11-01 — R129 early-leave analysis (commit 5578a36 says R128; renumbered: R128 = orders removal) + leave-snapshot analytics fix

Owner asked why players leave so early (report 11-01 to 14:16 UTC, 355 new, 99 % on 0.7.1).
First sessions end at three cliffs: 16 % never buy the free first pad (loading), 42 % stop in
minutes 1–4 (hand clicking before pad 5), 20 % stop at the old Paint Station price jump before
the first manager (6.8 min). R122 / 0.8.0 targets all three; it had 4 new players at report
time. Still open: the Dino Valley WORLD UNLOCKED popup at main area 3 (~minute 14; 19 / 41
pressed GO NOW, avg 2.3 min there), area 3's late manager (Dispatcher pad 8 of 9; 41 → 4 reach
area 4), return notifications off (empty `NotifyConfig` messageIds) — proposals in
`docs/owner-requests.md` R129.
Fixed: `leaveArea:*` and `pets owned/equipped` at leave recorded the JOIN-time snapshot whenever
Analytics' `Players.PlayerRemoving` handler ran before PlayerDataService's (Roblox does not order
them) and on server shutdown (session dropped before `ProfileReleasing`). `Sessions.endSession`
now refreshes the snapshot from the live profile first; `snapshot()` reads the profile it is
handed through the new `Runtime.areaFromProfile` / `Runtime.rebirthsFromProfile` (`areaOf` /
`rebirthsOf` delegate to them). Test: `tests/analytics-recorders.luau` §9b. Report rows "Where
sessions end" and "Pets at leave" before this fix are not trustworthy.

### 2026-11-01 — 0.8.0 follow-ups (owner R123–R128, R131, R132)

R123: on desktop the HUD reserves Roblox's player list (top-right; `HudZonesConfig.PlayerList`,
sized by the server's player count) — the admin chip + INVITE row sits left of it and the offer
column starts below it (`HudPlacement.playerListRect`; tests/hud-cluster "R123"). R127: the
currency stack fades out while a `HudFocusConfig.CurrencyHiddenScreens` screen (Lucky Wheel) is
open. R128: the Order Window system (R90 / R114 / R115) is REMOVED — server + client `Orders/*`,
OrderConfig / OrderLogic, 5 remotes, the Carry action + contexts, the Fame menu-wheel tile, quest
stat `order` (saves holding it get a different mission, `QuestConfig.RetiredStats`), profile field
`orders` (dropped on load); the `orders` analytics family stays documented as retired; Tip Jar and
Cashier Bot keep working (Nuke Town first run 7:03 in the sim). R124–R126 (order button / trays /
arrow) were superseded by R128. R131 (keyboard / gamepad dead on producer boards) was a transient
mid-edit state, resolved without a code change. R132: the owner verifies in Studio; agents run code
checks only. Release note: R128 ships in the same publish as the badges (0.9.0, b1e3a40) and 0.8.0
is already live (a seen note never re-opens), so the "No more Order Window chores" line sits in the
0.9.0 note's IMPROVED section next to R130's BoomDash Dispatcher line, not on the 0.8.0 note.
`tools/qa/r123_check.py` (Studio check for R123 / R127 / two R122 items) is kept for an owner-run
pass; per R132 agents do not run it.

### 2026-11-01 — 0.8.0 "Algorithm pack" (owner R122)

Live analytics (10-31 closed, 11-01 to 07 UTC; 382 new players) read against Roblox's 2026
Recommended-for-You signals (spec `docs/superpowers/specs/2026-11-01-r122-algorithm-pack-design.md`).
Findings: 43 % of first sessions < 2 min; loading 1.5 s → 26 s on phones in 0.7.1 (30 s asset
budget on slow connections); tutorial step 6 → 7 lost 74 % (first manager at ~11 min); D1 ≈ 2 %;
95 % of sessions solo; 0 purchases, most prompts closed < 2 s; notification opt-ins never used.
Shipped: (1) loading hand-off — critical-only preload, 6 s asset budget, tap 20 s / auto 30 s,
the rest preloads in the background, per-step boot telemetry; (2) Garage Lab re-paced — Uncle
Atom is pad 4 (sim: hired at 1.9 min, was 5.9; longest pad gap 83 s; area still 8.0 min; old
saves keep every pad, `tests/garage-lab-order.luau`); (3) return notifications (MemoryStore due
queue + Open Cloud, dry-run until the owner adds the secret) and an earlier opt-in card;
(4) HUD INVITE + invite moment, paid Lucky Button DEAL card, PurchaseGuard focus hygiene on 12
prompt sources (7 accidental-prompt causes fixed); (5) `rbx:*` analytics, refusal reasons,
build slices for the new signals, the admin "Roblox algorithm scorecard" and "Client boot steps by
device" tables. `ftue:pad5` now fires at the Garage Door (not comparable with 0.7.1).
Builders: W-R122-boot / econ / notify / social / analytics. Prior R96–R121 work was committed as
checkpoint aba3d8a first.

### 2026-11-01 — Harvest Feast public listing and additional price reductions

Published [Harvest Feast](https://www.roblox.com/events/8298781641862677092), verified its event card
on the game page, and changed the description to “HARVEST FEAST IS LIVE!”. Listing starts at
01:15 UTC because Roblox disallows past starts; its end stays December 1 at 00:00 UTC, matching
the existing gameplay window. Reused the approved Harvest thumbnail.

Read current live prices, saved rounded reductions of **20% on 35 developer products** and
**another 30% on 11 passes**, then verified every row. Managed pricing is enabled on 45 items;
Pocket Rocket keeps its fixed-price exception. Local fallback prices and existing economy
assertions/comments now agree with the dashboard. The full price audit and screenshots are under
`docs/verification/creator-dashboard/`; see `docs/creator-dashboard.md`. No gameplay rewards,
receipt schemas, or event runtime dates changed; no Studio place publish was performed.

**2026-11-01 — 0.7.0: defend your plot (owner R79–R88).** Menu focus (side columns hide in
menus), `ScreenManager.handoff` (Quests GO → Lucky Wheel / Pets / Nuke Pass and back), the HUD
"Bottom" zone follows the real objective chip (hint bar no longer covers it), GuiFade nested-fade
guard; buyable + upgradable AA tower slots; Lucky Wheel ticker / bulbs / win FX; boost corner badge;
Auto Clicker counts for click quests (4/s credit); tutorial rings + glyph on the exact button; gem
upgrade (75 gems / level, confirm); attack for everyone + Golden Revenge Nuke (31 R$); manager nametags; plot names from the front sign; R89 Surprise
Batches + Flavour Book + Big Pop, Happy Hours, 1-minute gift ladder + Pocket Rocket (19 R$). Verified: `./scripts/check.sh` green, Studio captures under
`docs/verification/r79`, `r81-wheel`, `r82-*`, `r84-*`, `r86-*`, `r87-*`, `r88-plot-name`.

**2026-10-31 — Maximum server fill configured.** Creator Dashboard → Places → start
place `132667741281890` → Access → Social Slots changed from Roblox optimized (`Automatic`) to
Disable (`Empty`); Maximum Visitor Count stays 8. Reloaded the page and verified both persisted.
This removes reserved social slots and is Roblox's supported control for fewer, fuller servers;
it is not an absolute guarantee that every global server fills before a new one opens. No
servers were restarted, no active players moved, and no runtime matchmaking code or custom
scoring configuration changed. Screenshot, primary sources, and verification:
`docs/creator-dashboard.md` § Server fill preference.

**2026-10-31 — 0.6.0: the retention pack (owner R78; spec
`docs/superpowers/specs/2026-10-31-r78-retention-pack-design.md`).** Driven by the first day of live
analytics (read-only through Studio; the RoBeasts Open Cloud key has no DataStore scope here):
11 of 26 sessions under 2 min, 22 of 26 leaves in area 1, 6 of 20 new players gone before the first
pad (3 of 7 on console), no friends in 28 of 29 sessions, reward menus the most-opened screens.
* **Progress bus** `Server/Progression/ProgressEvents`: one validated, non-yielding fire at every
  success path (15 stats); Quests and the Pass listen. No client claim ever counts.
* **Quests** (HUD left button after Rewards): 12 starter goals take over the objective chip once
  the tutorial is done (state checks back-fill veterans; a saved base of 0 survives reloads —
  review fix), 3 seeded daily missions by progress tier + Daily Chest + 1 reroll (finished
  missions auto-pay at rollover), 9 tiered trophies; chip taps obey `QuestOpenRules.chip`
  (never over a window / during JoinFlow); compact phone layout (4+ rows).
* **Nuke Pass Season 1** (2026-11-01 → 12-01 UTC): 30 × 400 XP, free + premium tracks, overflow
  chests, auto-grant of unclaimed tiers after the season; premium = dev product 3725022864
  (199 R$, idempotent receipts, refused outside a season); exclusive Harvest Glow trail, titles
  SEASON 1 / NUKE PASS, Golden Nukey pet; season-end settle waits for the paid-random policy
  (`Pass/PassFlow`, review fix) and tells a waiting claimer to retry; own `NukePass` icon.
* **Rush + Friends:** Rookie Rush (new profiles only) 2x 15 online min, Comeback Rush 2x 10 min
  after ≥ 48 h away (Welcome Back banner, payout never shown twice), Friend Boost +10 %/friend
  ≤ +50 %, invite screen + Rewards-hub tile, referral rewards (newcomer 50 gems + 2x 15 min,
  inviter 100 gems + spin, ≤ 10, DataStore queue paid exactly once). New modifier fields
  `rushCash` / `friendCash` never touch offline or reward cash. Rewards hub phone text fixed
  (14 pt floor on touch, 2-line pills).
* **Pet Index rewards + Golden Nukey:** milestones 5 → all (66 non-exclusive pets) pay gems + up
  to +30 % permanent petCash; 10 pets marked exclusive (pack, pass, event); `SparkleNukey` mesh
  72555879118435, Mythic tier 10, in no egg.
* **First minute:** one join-time pop-up queue (`Platform/JoinFlow`), the tutorial card became a
  non-blocking strip (it froze gamepad players before), device-correct hints, Lucky Buttons held
  during tutorial steps 1–3, Welcome Back after the plot reveal, real loading time measured, new
  funnel steps `tutorialSeen` / `firstMove` / `firstScreenClosed` (+ `loadingDone` / `hudShown`
  now actually sent).
* Release: 0.6.0 WHAT'S NEW note (CTA → Quests), code QUESTS (40 gems + 1 spin). Verified: per
  builder solo Studio QA + device matrices (`docs/verification/r78-*`), an independent server
  review (2 bugs found and fixed with regression tests), integrated `./scripts/check.sh` (82
  suites) and an integrated solo boot (all new remotes + screens live, no errors).

**2026-10-31 — Gamepasses about 30% cheaper (0.5.1).** Reduced all eleven live gamepass base
prices through Creator Dashboard using `round(previous × 0.70)`; every pass remains for sale
with Managed Pricing enabled. Verified the entire eleven-row listing after saving: VIP / Auto
Hatch 174, 2x Cash 279, Auto Clicker / +2 Pet Slots / Triple Hatch / Mega Launcher 104, Teleporter
69, Lucky Eggs / Offline Max 139, Fast Walk 34 Robux. `MonetizationConfig` fallback prices now
match the dashboard; `PriceBook` continues to fetch each player's real Roblox price and refresh
about every ten minutes. Perks, IDs, ownership, and developer products are unchanged. Updated the
0.5.0 WHAT'S NEW note and bumped the patch version to 0.5.1. The live price changes do not require
a place publish; the fallback labels / change-note source will accompany the next owner publish.
Evidence and check results: `docs/creator-dashboard.md`.

**2026-10-31 — 0.5.0: World 3 Moon Base, Lucky Buttons, juice pass, player titles, animated miners,
codes (owner R69–R76; spec `docs/superpowers/specs/2026-10-31-r69-moon-lucky-juice-design.md`).**
* **Moon Base (`moon`, R70)** added the §18 way: geometry origin (-6000,0,0), 6 areas / 59 pads
  mirroring Dino, Moon Rocks + Star Shards (MoonRebirth), unlock Nuke Town area 5 or 1 rebirth, sim
  150.4 min (run 2 1:13). Art: 6 area builders `moon_area0N.py` (W6/W7/W8), hub `moon_base.py` +
  lobby `Hub_MoonRocket` (W9b, true-colour lighting + star skybox `tools/ui/sky/moon_sky.py`, APM
  music), 8 pets + 2 eggs + Rocket Corgi (W11), icons + shop props + MOON BASE shop section (W1b).
  Products live: MoonRocksSmall/Medium/Large 3724649324/…274/…223, AstronautPack 3724649081.
  Low gravity ×0.4 (`Client/Worlds/WorldGravity`), pad reach vertical 10 → 28. Framework fixes:
  worldCash sync lists only started worlds (160 B budget), leaderboards map any board id,
  3-world client tabs / link lines / Welcome Back, per-world portal models. Studio tour green
  (`docs/verification/moon/`, `docs/verification/world3/`).
* **Lucky Buttons (R69):** server-owned, client-rendered, owner-only buttons on your plot (any
  world); free cash / 2x Cash / 2x Speed + Robux deals (2x Cash 30 min, 2x Cash pass, Auto
  Clicker, cash crate, Skip Pad); ≤ 2 live, ≤ 1 paid, first per session free, owned passes
  skipped. Placement reads the layouts (plots are non-queryable by design): ground collider,
  ≥ 7 studs from pads / producers / billboards, clear of every prop; claim height 30 (Moon jumps).
* **Juice (R71):** click combo ladder, pad-buy coin burst, milestone banner, manager-hire puff,
  area-unlock / rebirth fireworks + camera punch, finale confetti cannon, income sparkles; 15 new
  approved sounds + `pick_clink`; Reduce Motion / FxQuality respected. Nuke Town numbers unchanged.
* **Titles (R73/R74):** DEVELOPER (owner 1586034782) and FIRST PLAYER (0 = display
  "<player>", the first player per the live leaderboards) + admin give/revoke EARLY PLAYER;
  stud-sized overhead tag (hidden on your own screen) + chat prefix.
* **R75:** `A4_Miner` rig-split; pick swing + chips + clink; `A9_AstronautCrew` waves.
* **R76 codes:** MOONBASE, BLASTOFF, ZOOMZOOM, DISCORD, THANKYOU (until 2026-11-08).
* **R72:** multiplayer playtests banned (`scripts/studio_mcp.py` `guard_tool`); W3: admin SetArea /
  UnlockAll now fire AreaReached / WorldAreaReached (unlocks, badges, analytics follow).
* `./scripts/check.sh` ALL PASSED (77 suites). Owner: publish with "Migrate to Latest Update";
  optionally create the Moon Walker / Star Tamer badges (BadgeConfig ids 0).

**2026-10-31 — First five Roblox badges created and connected (0.4.0).** Created Welcome,
Nuke Stand, BoomDash Delivery, Glow Rock Mine, and Enrichment Lab in universe `10773845696`.
All five show Active in Creator Dashboard; creation was free. Original 512px studded toy icons,
prompts, and provenance are in `assets/marketing/2026-10-31-badges/`. Verified URL IDs are in
`BadgeConfig` and `docs/leaderboards.md`; existing append-only ownership bits, server profile
qualification, throttling/retry queue, native Roblox award toast, and admin Badge Status remain
the award flow. Remaining eleven catalog IDs are 0. Added production-catalog regression coverage
(190 badge checks) and the 0.4.0 WHAT'S NEW entry (252 change-note checks). Rojo-synced IDs were
read back from the already-open Studio edit datamodel. No real Studio awards or place publication
were attempted; publish once to activate the new IDs on live servers, then test a live join and
area unlock. Dashboard screenshot: `docs/verification/creator-dashboard/first-five-badges-active.png`.
Repository verification is recorded in `docs/creator-dashboard.md`.

**2026-10-31 — R64 manual first producer + R65 first upgrade $10 (E1-economy).** Root cause of
"the first button is already automatic": the owner's account owns the AutoClicker pass (Roblox
gives the creator every pass; `UserOwnsGamePassAsync` = true), TycoonService ran it from the first
second, and the pass's advertised "Toggle it any time" did not exist. Pass-less players (and New
Player Mode) were already manual — now proven by tests that walk the whole pad chain (only a
producer's own Manager automates it). Added the toggle: `profile.settings.autoClicker` (default ON;
ProfileLogic allowlist), `SettingsService.Changed` signal → `TycoonService.markDirty`,
`TycoonRules.autoClickerOn` + `TycoonRules.manualStep` (pure manual-cycle tick, now used by
TycoonService), and an "Auto Clicker" row in Settings shown only to pass owners (tall mode 880 → 980
px). R65: Workbench level 1 → 2 pinned to exactly $10 (`Area01 FIRST_UPGRADE_COST`), Garage Lab SCALE
4.53 → 5.62 (pads +24 %, area still 8.0 min); areas 2–10 unchanged; sim run 1 8:00, run 2 3:40;
Garage Egg follows the rule (40 × first upgrade) $560 → $400. Economy-index snapshot refreshed
deliberately (39 Garage Lab values; list in docs/economy.md "Snapshot refreshes"). Studio QA:
`tools/qa/opening_check.py` → `docs/verification/opening/`. Details: docs/economy.md "Garage Lab opening".

**2026-10-31 — Thirteen ad creatives; public/mobile/console verified.** Uploaded ad11 Dino Valley,
ad12 Knockdown, and ad13 Noob vs Pro Dino. The campaign became Scheduled during the workflow
without an agent Publish action; verified 13 saved enabled creatives, $20 lifetime, and Engagement.
Manage access already selected Public (currently available to 16+). Mobile/Tablet were already
on; enabled Console in Advanced settings and confirmed all requested device selections after
reload. No runtime build or physical-device playtest performed. Details and screenshots are in
`docs/creator-dashboard.md`. `./scripts/check.sh` passed strict type-check and all 71 standalone
suites after the in-progress egg-price assertion was updated by its contributor.

**2026-10-31 — Refreshed unpublished ad creatives.** Replaced all ten older Ads Manager campaign
attachments with Claude's revised PNGs, then replaced all ten again with the latest R66 SELL
NUKES logo versions from `assets/marketing/2026-10-30-ads/final/`. Uploads completed and the final
branded grid was verified. Preserved Engagement, All players, the $20 lifetime budget, three-day
duration, and November 1 start. The owner still performs Publish from the retained Chrome form.
Evidence and handoff details: `docs/creator-dashboard.md`, revised ad creative refresh section.
`./scripts/check.sh` passed, including strict type-check and all 70 standalone suites.
No runtime/version changes.

**2026-10-31 — Wave 4 integrated (0.3.0): knockdown attacks, launch cinematic, test bots, lobby,
vehicles, load order.** Committed together because they share admin, mesh and attack files:
R50 aim-at-an-area knockdowns (Server/Tycoon/Knockdown, KnockdownFx topple + fly-in rebuild, TAP
TO REBUILD chip, dazed managers, billboard "KNOCKED DOWN" plate, 180 s immunity, rewards scaled by
the knocked area's income); R51 admin Attack tab + TestBots (admin-only targets, auto-attack,
Revenge, cleanup); R54 launch cinematic (3-2-1 voice countdown, chase camera on the aimed arc,
3.4 s server lead-in); R55 lobby (Nukey fountain plaza, two-pass hub build); R56 vehicle routes
(7 routes in areas 3/4/6/8, horn + reverse beep, World-tab Vehicles on/off); load order
(WorldReady 9.59 → 3.85 s, own full plot 9.14 → 6.53 s). 0.3.0 note rewritten to cover the whole
update. Verified in Studio per feature; whole-tree check.sh green on a clean checkout.

**2026-10-31 — R56 map vehicles + machines (V1-vehicles).** The owner wants trucks driving in and
out. New client system `Tycoon/Fx/VehicleRoutes` (one Heartbeat, one BulkMoveTo, FxQuality budgets:
Low parks everything, Mid 8 / High 16 nearest routes; streaming-aware; pauses while an area is
knocked down, resumes 5 s after; waits 5 s for a fresh build-in) drives the server-spawned models
along slot-local routes from `Shared/Config/VehicleRouteConfig`, maths in the pure
`Tycoon/Fx/RouteMath` (centripetal Catmull-Rom + arc length, trapezoid speed profiles, looping
timelines with cargo / honk / beep / tip / signal / gate events). Movers: A3 BoomDash van (backs into
its stall, 3 parcels pop onto the roof), A3 lane scooters (lean in bends), A4 two-cart mine train
(tips ore into the bin, fades into the tunnel), A6 semi-truck (new cab-over flatbed model, reverses
to the dock with beeps, 4 crates pop on), A6 forklift (pallet shuttle), A6 belt rockets (ride the
conveyor at belt speed), A8 shopper car (the garage barrier lifts, parks, backs out). Wheels spin
per axle, bodies bob / dip / lean, brake lights + indicators glow softly (Neon toggles), honk =
`vehicle_honk`, reversing = `vehicle_beep` (once per reverse leg). Blender: `A6_DeliveryTruck` + `A8_ShopperCar` split out (per-axle Tyres/Hubs,
BrakeLights, IndicatorL/R, Cargo1..N), van / forklift / mine cart re-pieced, garage barrier authored
down; layouts lost the driven models' collision boxes (A3 van collide flag, A6 truck + forklift, A8
car), forklift rest moved to (-41, 28), carts parked as a train near the tunnel. WorldFx keeps off
routed models (`WorldFxConfig.RoutedModels`; the van's CarIdle assembly removed). Tests:
`tests/vehicle-routes.luau` (path / profile maths, rest poses on the route, continuity, plot rotation
for all 8 plots, a 3D SAT clearance sweep against every collider of the area, route-vs-route floor
overlap, contracts). Captures: `tools/qa/vehicle_check.py`. Admin: World tab "Vehicles on/off"
(`VehiclesToggle`, `Admin/Handlers/WorldHandlers`, audited) sets ReplicatedStorage `VehiclesEnabled`;
false parks every vehicle live. Docs: build-in.md §4b, admin.md.

**2026-10-31 — R55 lobby centre redesign (L1-lobby).** The owner called the hub centre ugly; it is now a
stud-toy plaza built in Blender (`tools/blender/models/hub_plaza.py`, 11 models): a toy-nuke fountain
(blue mosaic pool, water curtain, eight Nukey-coloured spouts spraying arcs) with a 31.5-tall waving
Nukey on a NUKEY plinth facing the spawn and a coin halo over his head; a fountain-walk tile ring;
eight plot-coloured paths (pad + signpost on each, dark readable labels, turning star); seven garden
beds (bench, banner, "money tree" coin); a welcome carpet from the spawn; lamp-post bunting gateways
at every path mouth; a lime rim; warm district paving + lime kerbs. Motion via new WorldFxConfig
rows (Ripple, Wave, Streamer, Pennant, Twirl, Whirl, Carousel; Nukey's arm boxes are mirrored about
the shoulder so it turns at the joint) and 30 ambient emitters (`HubLayout.anchors.AmbientFx` ->
`HubBuilder.buildAmbient`, presets `HubAmbientConfig`). Spawn, pads and gates keep their places; the
district fixtures (egg stands, crate stall, chest, wheel, boards, codes) moved in from r 150 to r 132-140
to frame the centre (anchors follow, behaviour unchanged). Lobby budget 660 MeshParts / 144.4k tris / 37 unique; rebuilt keys within their original triangle budgets (tests/hub-layout),
z-fight audit 0, glow budget green. Decor (`HubLayout.deferredKeys`: gardens, bunting, banners, coins,
halo, benches) and far scenery load in HubBuilder's second pass (`deferred`, Background) after its
first-view pass releases `MeshLibrary.holdWorldReady` (W1b's player-first load order). QA: `tools/qa/hub_lobby_check.py`. Note: the spawn camera faces
outward (spawn kept as is), so the statue is behind a fresh spawn; turning round shows Nukey waving.

**2026-10-31 — R58 WHAT'S NEW (U1, RoBeasts changelog port).** SellNukes now runs the same
change-notes system as RoBeasts: same note schema (`Heading`, `Hero`, optional `Cta` / `ShowFrom`),
same `VersionConfig`, same rules (`Shared/Util/ChangeNotesLogic`), same save record
(`profile.notes = { seen, at }`, additive, schema stays v1), same remote verbs + analytics keys, same
authoring doc (`docs/change-notes.md`). Brand-new and mid-tutorial players get the newest note
marked seen on load; RETURNING players get the panel once per join at a calm moment (after the
loading screen, Welcome Back, any window, cinematics, purchase prompts). Entry points: a
bottom-right purple WHAT'S NEW chip with a NEW badge (reserved under the offer column via
`HudPlacement` `corner`; above the jump button on touch) and Settings. Server:
`ChangeNotesService` (load rule, `ChangeNotesAction` C→S, reveal timer, purchase-flow hint),
`ChangeNotesAdmin` (WhatsNewReset / WhatsNewPreview). Analytics: retention `notes:*` incl. time
open, report table "What's New". Version 0.3.0 + note `2026-10-31-whats-new`. Tests:
`tests/change-notes.luau` (242 checks). Boot entries: server "ChangeNotesService", client
"ChangeNotes/ChangeNotesClient".

**2026-10-30 (night) — R54 launch cinematic (Q4).** When the server accepts one of your launches,
`Client/Attack/LaunchCam` takes the camera. It shows a stud "3 … 2 … 1 … LAUNCH!" countdown with
voice lines (`vo_*`, silent until uploaded) and haptics, all inside the server lead-in, and plays
behind the silo. Then the camera does a lift-off shake + FOV kick and a spring-damped chase behind
the toy nuke. It eases into an impact shot (with a slow-mo feel from camera easing, never time
scaling) and holds on the POP / confetti hit, plus a KNOCKDOWN! shout when the area topples. Finally
it eases back to the player's camera. It is skippable (tap / click / SKIP / B / X / Backspace / Esc).
Your character stays put. Other players' launches never move your camera, and a barrage follows only
the first nuke. With Reduce Motion it uses static shots and hard cuts; FxQuality sets the particle
counts. Pure maths sits in `Shared/Attack/LaunchCamMath` and is tested by `tests/launch-cam.luau`
(full plot × target sweep: no NaN, no teleport, the nuke stays in frame, a skip lands on the
player's camera). Details: docs/attack.md §15.

**2026-10-30 (night) — R50 temporary area knockdown (Q3).** A hit knocks down the area it lands in.
The server side is `Server/Tycoon/Knockdown`: state per player + area (never saved), replicated as
`KnockdownTarget` + `KnockedAt` / `KnockedUntil` / `KnockCenter`. The duration is 45 s +3 s per launcher
level above 1 (≤ 90 s). Immunity runs while any area is down and for 180 s after the last one is
back up; a barrage may spill into one more area within 6 s; shields block; KnockdownTap gives −1 s per
tap (≥ 6 s after the hit, ≤ 6 / s, owner only). Rival Factory sections are supported
(`knockInstance`), and so are R51 test bots (`applyBot` …). TycoonService pauses the area's producer
(no payout / clicks / auto-work, `PausedAt`) and resumes it where it stopped; purchases and upgrades
stay allowed; offline earnings are unaffected. On the client, `KnockdownFx` tumbles the area's stud
pieces like toy bricks (confetti puff, bonks, local CFrames + collisions only, tier budgets, Reduce
Motion = fade). Managers sit dazed with orbiting stars, spinning props freeze, and at the deadline
`BuildInController.rebuild` flies every piece back off its rubble. Builds bought meanwhile fly in
after. The HUD chip (KnockdownHud) shows "Your LAB got knocked down! Rebuilding 0:45" with TAP TO
REBUILD! (H / LT / tap). Admin (Attack tab): KnockdownArea / Rebuild / ImmunityOff (bot 0 = me, 1..8 = TestBot) / Toggle / Tuning / Stats.
Analytics: attack `knock*` keys. Tests: `tests/knockdown-logic.luau` (94k checks). Studio QA:
`tools/qa/knockdown_check.py`.

**2026-10-30 (night) — R49 real animated egg hatch (EH1).** The HatchReveal screen is rebuilt as
a premium cinematic on the REAL 3D egg: anticipation wobble bursts that grow in strength + speed
with squash / stretch, three crack stages with rarity-coloured light leaking through (new generic
Blender `EggShards` model: 7 shell chips + 3 ink / Neon crack stages, uploaded + synced), halo +
rays, crouch → soft flash (R19) → cap / chips fly with spin + gravity, cup drops away, the pet
springs out and idles with PetAnim (R44) + happy spin, stud rarity banner (name, rarity, "1 in N",
bonus, NEW! / PITY! / EQUIPPED), confetti + sparkles + stinger cues by rarity; Mythic / Secret get
a darker, longer build-up with viewport jitter and a gold burst. Triple hatch staggers with the
best rarity last. SKIP / AWESOME! button + tap anywhere + B; Settings "Fast Hatch"
(`settings.fastHatch`, ProfileLogic + Settings row; Settings window +1 row in both modes);
Reduce Motion = cross-fade. New: `Client/Pets/HatchAnim` (pure timeline), `HatchAnimConfig`,
`EggHatch/{HatchStage, HatchConfetti}`, `tests/hatch-anim.luau`; PA2 added `PetModels.fromKey`.
Details: `docs/pets.md` "Hatch cinematic".

**2026-10-30 — Producer billboards never cover their producer or manager (owner R31/R32, lead QA).**
New pure solver `Tycoon/BillboardPlacement` decides each producer board's spot + size from CONFIG
(`areaInput`: the layout click box, the area manager's work region from `ManagerNpcConfig`, every
visible `MeshAssets` piece of the fully built plot): from the standard player stands (5 / 12 studs
in front, ±5 sideways, Roblox default camera; scaled for big producers) the board's on-screen
rectangle never overlaps the producer or manager, it never intersects geometry (boxes wrapping the
producer — the A2 awning, A7 silo truss, A8 storefront — now count; rooms around the player do
not), its top stays ≤ 16° (far) / 30° (near) above the horizon and within 45° / 50° sideways
(R32), "above" when there is readable headroom, else beside at eye height; sight lines to its
centre + corners are a tie-breaker. Size: studs clamped to a viewport-height budget
(`heightAt`). The answer is generated offline into `Shared/Config/BillboardSpots`
(`lune run tools/billboards/generate-spots.luau`), so the client places with a lookup (runtime
solve only for a missing area); `tests/billboard-clearance.luau` audits every area × desktop /
device (incl. an independent ray-sampled coverage check) and fails when the table is stale.
`ProducerBillboards`: placement no longer walks streamed parts or re-runs on every build; pops
start outside the board's CURRENT width (re-anchored on resize); `add` is failure-isolated per
producer (`placeSafely`, warn once per id). QA: `tools/qa/billboard_check.py` (before/after
captures). Docs: `docs/tycoon-client.md` §3a. Follow-ups the same day: owner R48 (Area 10 board
was low in front of the dome, bar behind the reactor ring, crowding the prompt + manager) — the
solver now ignores walk-through frames (entry arches, garage doors: their boxes include the
opening) for sight lines, scores sight lines harder (LosPenalty 6), tries deeper / higher side
spots and compares every slab-clear spot offline (EvaluateMax 200): A10 sits beside the dome on
the side away from the Chief Engineer, raised clear of the FusionCore. Owner R50: billboards show a
red "KNOCKED DOWN 0:45" / "REBUILDING!" plate and freeze the bar while paused (Q3 contract:
`KnockedUntil` on the area model, `PausedAt` on the anchor). IncomePops skip invisible pops (P2).

**2026-10-30 — Sell Nukes Discord community and revised game icon configured.** Server
`1565864865673912420` has Community, onboarding, optional notification roles, native AutoMod,
private staff/support channels, and a read-only announcement channel for code drops. Verified
Ticket Tool creation/closure/transcript delivery and Suggestions submission/thread/resolution;
Developer/Moderator command overrides are configured. Non-staff role preview hides private
channels and cannot post in codes. Permanent invite https://discord.gg/5Kmvjvme4X is saved as the
game's Discord social link and persisted after reload. The revised 512px marketing icon is saved
and displayed on Roblox and Discord. `docs/discord-server.md` records settings, channel IDs,
bot workflows, and verification; screenshots are in `docs/verification/discord/`. The earlier
unpublished ad form remains open. No runtime/schema/version change. Project check and strict
type-check were run but blocked by other contributors' in-progress LaunchCam formatting and
WhatsNew type errors; documentation remains uncommitted until the mandatory gate passes.

**2026-10-30 — Money flies into the HUD counters (owner R46).** New `UI/Hud/CurrencyFly`
(+ pure `CurrencyFlyRules`, `Config/CurrencyFlyConfig`, `tests/currency-fly.luau`): cash / gem
sprites burst from clicked producers (2–4), managed / auto-clicked producers on screen (1–2, ≤ 1 burst / 1.2 s),
rewards / purchases (12–20, centre; unexplained cash paired with a reward toast or PurchaseGranted)
and the welcome-back claim, swoop on a curved path into the counter, which pops + glints
(`HudCurrency.land`) with a soft climbing coin tick. Pool of 40, one PreRender connection while
flying, FxQuality Low = ⅓, Reduce Motion = short straight fades, visual only. Hooks: `Hud` build
(attach + start), `IncomePops` (`fromProducer`). Docs: `docs/ui.md` §7d, tycoon-client, audio.

**2026-10-30 — Ten-creative engagement campaign prepared for owner publishing.** Chrome Ads
Manager has an unpublished Create campaign form for Sell Nukes, objective **Engagement
(Reach Kids/Select)**, all ten of Claude's ad PNGs attached, an editable **$20 lifetime / 3-day**
test budget, and displayed start **Nov 1** so the Harvest Feast ad runs during the event.
No Publish click or ad spend; no visible Save draft control, so the live tab is retained for
handoff. `docs/creator-dashboard.md` records exact settings, files, timing, and the manual
pause-at-250 requirement; evidence is `docs/verification/creator-dashboard/ad-campaign-creatives.jpg`.
This prepares acquisition; it does not guarantee 250 qualifying players or certify a new build.
Full check is blocked by other contributors' shared-tree formatting, and the separate strict
type-check reports in-progress AttackService errors. Documentation remains uncommitted until
the mandatory full gate passes; no runtime files or version were changed for this task.

**2026-10-30 — Public access enabled at owner request.** Creator Dashboard Manage audience
now confirms **Sell Nukes is available to players ages 16+!**, subject to content/region
restrictions. Under-16 reach requirements remain incomplete; no publishing fee was paid.
This opens the existing uploaded place, without uploading local runtime edits or restarting
servers. `docs/creator-dashboard.md` records scope and rollback; evidence:
`docs/verification/creator-dashboard/public-access.jpg`. The egg-policy gap and fixed shop
price labels remain open. The current full check stops on unrelated shared-tree formatting
in `StudioDummy.luau` and `AttackService.luau`; a separate type-check also fails on the current
in-progress AttackService edits. Those files remain untouched. Documentation diff checks pass;
the public-access documentation/evidence remains uncommitted pending the mandatory full gate.

**2026-10-30 (night) — R38 text logo + ad 9; team respawned (R45); R46 queued.** ForgeGUI made
the "SELL NUKES" title (Sell Lemons-style stacked chunky glossy stud letters, no "$"; job
`30be92d5…`, pick v2). New `brand.py title` adopts `assets/brand/logo-forgegui.png` (trim + pad,
never upscaled) and `compose` uses it too; uploaded as Image `74257284412017` (Approved) and synced
into `BrandAssets` + `LoadingScreen/BrandImages` (1024×548). Ad 9 "GARAGE → NUKE EMPIRE!" final
(10/10 ads done). Respawned N2-billboards, Q2-attack, A2-props, W1b-shop, PA2-petanim, P2-prices;
H1-cashfx builds R46 (cash/gem particles flying into the top counters). The lead stopped dead P1's
orphaned playtest after its lock went stale (exception documented in CLAUDE.md).

**2026-10-30 — Managed pricing enabled; egg issue rechecked.** Owner confirmed the one-time
Roblox acknowledgement. Chrome now shows **35/35 items, 100% optimized**: all 11 passes and
24 developer products enabled. No item trading/gifting is implemented. Evidence and details:
`docs/creator-dashboard.md`, `docs/verification/creator-dashboard/managed-pricing.jpg`.
The cash-egg policy gap remains (cash is Robux-buyable but `PaidRandomCurrencies.cash = false`);
no egg fix or content-rating resubmission was requested in this follow-up. The in-game Shop
also still displays configured prices; it needs client-side live price lookup to match
managed pricing. No runtime files or in-game version were changed. `./scripts/check.sh` passed
format, lint, strict type-check, compile, and all 42 standalone suites; the prior manager assertion
is now passing in the shared tree.

**2026-10-30 — Creator Dashboard configured (R34 and follow-ups).** Chrome setup completed:
exact title **Sell Nukes**, 864-character description, Simulation → Tycoon, maximum 8 players,
primary icon and ten thumbnails (nine numbered + alternate) uploaded. Primary +$999,999/s image
is first in the gallery and active on Home. Submitted all 17 questionnaire sections: **Mild** /
**Violence (Repeated/Mild)**. Kept the experience private. `docs/creator-dashboard.md` records
settings, all answers, asset manifest, screenshots, and the confirmed paid-random policy gap:
Robux-buyable cash can fund eggs while `EggConfig.PaidRandomCurrencies.cash = false`. Answered
API compliance No truthfully; dashboard excludes Australia/Belgium/Netherlands and under-18s in
Brazil/UK. Core/pets owner must fix and verify the acquisition routes before publishing and
resubmitting. No runtime code changed. Format/lint/typecheck/compile pass; the shared-tree
manager animation assertion (`tests/build-in-plan.luau:140`) still blocks the full check and commit.

**2026-10-30 (afternoon) — Wave 2/3 landed; owner playtest feedback R14–R33.** Committed and booted:
tycoon server + client (lobby with random plots R13, reveal + loading gate R16), retention/shop
(10 services + screens), pets/eggs/crates, Harvest Feast + leaderboards + badges, admin panel
(HUD ADMIN button R20), analytics, audio (licensed APM music + 25 SFX), build-in + world FX,
movement + wind (R21), attack side mode, platform layer, loading screen. Root-caused the
mirrored text / offset caps / hedge-through-garage bugs to Roblox's 180° FBX import yaw (fixed in
MeshLibrary via MeshPlacement). Glow caps (R19), motion groups (R25/R26), z-fight audit from
RoBeasts (R18), billboard placement (R31/R32), button particles + sounds (R22), tutorial arrows
(R27). 35 game passes/products published live; 103 rendered icons; ForgeGUI store icon +
9 thumbnails + 9/10 ads (R23/R28/R29). Owner rule R33: agents never open new Studio places.
41 lune suites (~165k checks), strict type-check and stylua clean on the whole tree.

**2026-10-30 — Wave 1 landed, wave 2/3 dispatched.** Committed: core framework (toolchain, boot,
remotes, session-locked profiles, coalesced delta sync ≤ 464 B/s/player, idempotent receipts,
analytics hooks), tycoon logic (10 areas, 93 build keys; sim: run 1 = 8:00, run 2 = 3:39; invariant
"no purchase lowers a number"), Blender pipeline (MaterialVariant studs chosen by Studio
experiment, 18 models uploaded, parallel-safe locks), stud UI kit + HUD (verified desktop, phone,
gamepad), `NumberFormat.precise`. Live assignments are tracked at the end of the build plan.

**2026-10-30 — Project kickoff.** Saved all owner reference images under `docs/reference/` (with an
annotated index), identified the correct Studio MCP and wrote `scripts/studio_mcp.py`, copied the
Studio lock script, wrote the design spec, the build plan with interface contracts, and CLAUDE.md.
Wave 1 builders dispatched: B1 core, B2 UI kit, B3 tycoon logic, B4 art pipeline.
