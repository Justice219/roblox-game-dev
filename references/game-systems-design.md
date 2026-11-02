# Game systems design

This reference describes how each SellNukes game system is designed, built and documented. Each
pattern can be reused in a new Roblox game, and each section also records SellNukes' own values.
SellNukes is an 8-player linear button tycoon: assemble cartoon "pocket nukes", buy pads that
build the business in front of you, automate with managers, grow through ten areas (about 8 hours
on the first run), then rebirth. Use this file to see how a system is shaped: its config, its
pure rules, its service and UI, the numbers that pace it, the owner rules that bound it, and the
analytics keys it reports. Every number below is in SellNukes' config and tests. Copy the
structure as-is. Re-tune the numbers with the pacing simulator, never by guessing.

## Contents

1. [How every system is built and documented](#1-how-every-system-is-built-and-documented)
2. [Cross-cutting design rules](#2-cross-cutting-design-rules)
3. [Economy: linear button tycoon](#3-economy-linear-button-tycoon)
4. [Tycoon server, tycoon client, plots, managers](#4-tycoon-server-tycoon-client-plots-managers)
5. [Worlds, Kinetic props, Lucky Nukes (flavors), movement](#5-worlds-kinetic-props-lucky-nukes-flavors-movement)
6. [Monetization](#6-monetization)
7. [Retention](#7-retention)
8. [Pets, eggs, crates](#8-pets-eggs-crates)
9. [Kid-friendly attack mode](#9-kid-friendly-attack-mode)
10. [Live events, social, leaderboards, community](#10-live-events-social-leaderboards-community)
11. [Designing a new system: checklist](#11-designing-a-new-system-checklist)

---

## 1. How every system is built and documented

**Layers** (one folder per system; see server-architecture-and-security.md):

| Layer | Path pattern | Holds |
|---|---|---|
| Config | `src/shared/Config/<System>Config.luau` | every tunable, catalogue and limit; `validate()` |
| Pure rules | `src/shared/<System>/<System>Logic.luau` or `src/server/<System>/*Logic.luau` | maths, eligibility, rolls (injected RNG and clocks); Lune-tested |
| Server | `src/server/Services/<System>Service.luau` or `src/server/<System>/` | remotes, loops, grants, product handlers |
| Analytics | `src/server/<System>/<System>Analytics.luau` | translates events into documented keys |
| Admin | `src/server/<System>/<System>Admin.luau` or `src/server/Admin/Handlers/*` | audited commands, kill switch, status |
| Client | `src/client/<System>/*Controller.luau` + `src/client/UI/Screens/<Screen>/` | world FX, HUD chip, full screen |
| Tests | `tests/<system>-logic.luau` | rules, fuzz, pacing invariants |
| Doc | `docs/<system>.md` | the living spec |

**Doc template** (`docs/kinetic.md`, `docs/lucky-buttons.md` and `docs/happy-hours.md` are good
examples). Title with the owner request number (`(owner R90 / R93)`), then: What the player sees →
Files (table) → How it connects → Rules (server-authoritative) → Remotes (args, limits) →
Purchases → Economy / pacing impact → Analytics (family + keys) → Admin (commands, tab) → Client
feel, console + mobile → Security + performance → QA (what was verified, where screenshots live)
→ Next steps. Generated docs (`docs/monetization.md` from `tools/monetization/publish.py`) say
so at the top, and hand-written notes go elsewhere.

**Owner requests drive everything.** Append every owner message to `docs/owner-requests.md`
(date, quoted key words, requirements, where implemented) before acting. Cite the request
number ("R137") in code comments, docs and commit subjects so any number can be traced to why
it exists.

## 2. Cross-cutting design rules

- **Server decides; client asks.** Intents only. Every roll, price, timer and reward is computed on
  the server (see the server reference, section 7).
- **No purchase ever lowers a number the player sees.** `tests/tycoon-logic.luau` enforces it
  for every pad and upgrade (3,469 checks; 6,338 with the world suites).
- **Every purchase builds in.** Purchased models fly in (translucent → solid, master-builder
  stagger) using `BuildIn` / `BuyerUserId` attributes set before parenting. Restored plots
  (rejoin, rebirth, admin) appear finished.
- **Kid-friendly.** Candy-coloured toy nukes, confetti explosions, no real countries or weapons,
  no gore. Nothing a player owns is ever permanently taken by another player.
- **Paid random items are policy-gated** and fail closed (section 6). Odds are shown before any
  random purchase.
- **Income-relative rewards.** Reward "N seconds of income" with a floor
  (`incomeSeconds = 600, cashFloor = 10_000`), so one reward table stays meaningful from minute 1
  to hour 8 and never breaks pacing.
- **Modifiers are a registry.** `Server/Tycoon/ModifierSources.register(name, provider, {offline?})`.
  Pets, boosts, events, friends and rush each register a pure provider. Flag `offline = false` for
  anything that must not inflate offline earnings (boosts, rush, server boosts).
- **Every system has a kill switch and admin status** where it can misbehave live.
- **Every system reports analytics** through a documented key family (validated by `KeySpec`;
  undocumented keys are refused and counted as `ops:badKey:<family>`).
- **Console + mobile first.** Every action has KB/M, gamepad and touch bindings in the one action
  map (`PlatformConfig`). Every screen is controller-navigable with a safe default selection, and
  taps are ≥ 44 pt.
- **One attention queue.** Join-time pop-ups go through `JoinFlow.request(key, priority, open)`
  (Welcome Back 100, tutorial coach 95, ...), one at a time, never over a purchase prompt.
  Mid-session pop-ups use `PopupQueue` with priorities.

## 3. Economy: linear button tycoon

**Shape.** 10 areas, one producer per area, one chain of 93 pads (each requires the previous).
Code: `src/shared/Tycoon/TycoonLogic.luau` (`producerOutput`, `cycleTime`, `clickValue`,
`upgradeCost`, `maxAffordable`, `incomePerSecond`, `offlineLimits` / `offlineEarnings`,
`rebirthReward` / `rebirthMultiplier`, `applyPad`, `nextPads`), helpers `Modifiers.luau`,
`SafeMath.luau`, `EconomyIndex.luau`. Config: `Shared/Config/TycoonConfig.luau`,
`TycoonAreas/Area01..10.luau`, `RebirthConfig.luau`. **Pad ids, producer ids and shop keys are
save data: never rename them.**

**Pad kinds.** Build (adds a value fraction), Multiplier, Speed, Manager (automates the area's
producer), Unlock (opens the next area; the finale carries `feature = Rebirth`), Feature (AA tower
slot, Attack Console, Stand Rename).

**Producers and cycles.** Base cycles run 1 s (Workbench) → 1.5 → 2 → 2.5 → 3 → 3.5 → 4 → 5 →
6 → 8 s (Mega Reactor). Level cost grows ×1.2 per level (`baseCost × 1.2^(L-1)`), MaxLevel 1000.
`CycleFloor = 0.1` s; speed beyond the floor converts into cash so speed upgrades never go dead.

**Clicking vs automation.** The newest producer is manual until its Manager pad is bought; one
click runs one cycle (the Workbench pays $1 per 1 s click). Idle $/s counts only automated
producers. The first upgrade is pinned at $10 (`FIRST_UPGRADE_COST`, R65), then $12, $15, $18,
$21, so the first minute is a fast staircase.

**Milestones.** Every 25 levels: odd milestones (25, 75, ...) give ×2 cash, even ones (50, 100,
...) give ×2 speed. That makes visible step changes in a long upgrade ladder.

**Modifier stack** (each factor clamped at 1e6): `(1 + petCash) × 2 (2x Cash pass) × 1.5 (VIP)
× boost × server × event × rebirth × PowerProduction × linkCash`.

**SCALE pricing.** For each area, `SCALE` = a few seconds of the income the player has when the
area opens. A new producer's level 1 earns 1 % of that income (`SIM.StartFraction = 0.01`).
Level 1→2 costs 3 × SCALE; the builder pad 10 × SCALE; other pads `weight × L × 3 × 1.2^(L-1)` at
designated levels 3/6/9/13/18/22/Manager 25. Prices rise at least 15 % along the chain, and the
Unlock costs 3× the pad before it. `friendlyPrice` rounds to 2 significant digits.

| Area | SCALE | baseRevenue | Target min |
|---|---|---|---|
| 1 Garage Lab | 6.49 | 1 | 8 |
| 2 Nuke Stand | 269 | 19 | 15 |
| 3 BoomDash | 25,000 | 760 | 25 |
| 4 | 916,000 | 42,000 | 35 |
| 5 | 5.84e7 | 2.1e6 | 45 |
| 6 | 1.75e9 | 5.7e7 | 50 |
| 7 | 2.5e10 | 1.4e9 | 60 |
| 8 | 1.03e12 | 3.5e10 | 70 |
| 9 | 2.64e13 | 8e11 | 80 |
| 10 Mega Reactor | 2.3e15 | 7.8e13 | 90 |

Targets sum to about 8 h (tolerance ±20 %); the current sim runs 7:02 for run 1 and 3:12 for
run 2 (55 % faster).

**Opening pacing (the first 2 minutes decide retention).** R137 asked for "something new every
20–40 s" in the first two minutes. Garage Lab order: Workbench (free) → Tool Wall $11 → Glow Lamp
$19 → Uncle Atom (Manager, pad 4, at about 1.2 min) → Garage Door $340 → Mini Reactor $2.3K →
Paint Station $16K → Driveway $35K → Unlock $110K. `OPENING_CHECKS` in the simulator fail the
build if A1's first manager comes after 1.5 min, any wait is > 85 s, or any gap in the first
2 min is > 45 s (A2: manager by 2 min, wait ≤ 150 s; A3: 3 min, ≤ 300 s). Reordering pads needs
no save migration (old-order saves keep working; tests `garage-lab-order`, `boomdash-order`,
`stand-order`).

**Rebirth.** Unlocked by the Area 10 finale pad. Multiplier `1 + (0.5 + 0.05 × rebirthPower) ×
rebirths`. Tokens `floor((20 + totalLevels / 25) × (1 + 0.1 × rebirthsSoFar))`. Rebirth shop
(cost `ceil(base × growth^L)`): clickPower +10 %/lvl (max 10), managerSpeed +10 % (10),
startingCash $1K/$250K/$50M/$10B/$2.5T (5), offlineHours +1.5 h (14), offlineRate +5 % (10),
rebirthPower +5 % per rebirth (10), petSlots +1 (2). Everything maxed is about 2,260 tokens. Run
2 must take ≤ 85 % of run 1 (`Run2MaxFraction`). The UI is a two-press confirm that shows
"FINISH AREA 10" until allowed.

**Offline earnings.** `idle $/s × min(elapsed, cap) × rate`. Base: **3 h at 50 %**; nothing under
60 s; max 24 h at 100 % (the Offline Max pass, plus rebirth shop levels). Elapsed time comes from
the server-stamped `offline.lastSeenAt` (stamped every save and every 60 s), never a client clock.
Boosts, rush and knockdowns are ignored offline. Paid on join only (`getLoadReason == "join"`)
via the Welcome Back screen, whose "Double It!" product (`DoubleOffline`) pays once and is refused
after 10 min.

**Gem upgrade (R86).** 75 gems buys one producer level (admin-tunable 1..10,000, on/off). A test
guards that 3,000 gems buys at most 40 levels, so gems never trivialize the curve. The client
shows a "SURE?" confirm for 3 s, then a 6 s repeat window.

**Big numbers.** Plain Luau doubles (fine to about 1e308; `MaxCash = 1e300`). Format with
`Shared/Util/NumberFormat`: `short` / `money` / `rate` / `commas` / `duration`, suffixes K M B T Qa
Qi Sx Sp Oc No Dc Ud Dd ... up to Ce, 3 significant digits, truncated (never rounded up), NaN →
"0", inf → "∞".

**Simulator.** `lune run tests/economy-sim.luau [--timeline] [--tune [--write] [--upto n]]
[--world id] [--no-flavor] [--no-kinetic]`. A greedy bot (0.25 s click reaction, 3 s walk per
pad, 4–12 s between areas) scores cost/income + cost/gain. `--tune --write` rewrites the
`local SCALE =` and `baseRevenue =` lines in each area file. `tests/economy-index.luau` checks
parity against 4,509 snapshot values. Every side income (flavors +7.1 %, Mega Lever / Tip Jar
+6.3 %) is included in the sim and capped, so a new feature cannot silently shorten the run.

**Analytics.** `spend:gems:GemUpgrade`, `upgradeMode:gem`, `autoClicker:<on|off>`, grant reasons
(`megaLever`, `tipJar`), plus the tycoon family below.

## 4. Tycoon server, tycoon client, plots, managers

**Tycoon server** (`src/server/Tycoon/`: TycoonService, PlotService, OfflineService,
RebirthService, ModifierSources, TycoonRules, TutorialLogic, Knockdown, TycoonAnalytics,
TycoonAdmin, AreaLayouts; `src/server/World/PlotBuilder`, `HubBuilder`).
- One Heartbeat loop with a 0.2 s tick; catch-up capped at 5,000 cycles; Auto Clicker chains ≤ 20
  per tick and only while `settings.autoClicker` is on (R64); one `grantCash` per tick;
  leaderstats 1 Hz; income analytics flushed every 10 s.
- Remotes (burst / per s): ProducerClick 20/12 (reach 60 studs, 40 vertical), ProducerUpgrade
  `"1"|"10"|"max"` 15/8, ProducerGemUpgrade 6/3, PadBuy 6/3 (reach 12, vertical 28), Rebirth
  2/0.2, TeleportPlot (others' plots need the Teleporter pass, 5 s cooldown), RenameStand
  (≤ 24 chars, filtered).
- Lobby (R13/R16): a random free plot of 8, 3 s reveal, server fallback at 60 s, queue at 8/8.
- Tutorial: 7 steps (Workbench pad → click → upgrade to 2 → Tool Wall → Glow Lamp → Uncle Atom →
  open the stand). Non-modal coach, chevrons, highlight.
- Products: Cash packs, SkipPad, DoubleOffline (+ per-world packs).
- Analytics: `plotAssigned`, `padBought`, `producerClick`, `producerIncome`,
  `producerUpgraded(mode)`, `tutorialStep`, `rebirthed`, `offlinePaid`, `offlineDoubled`,
  `tycoon(rename|teleport:<n>|teleportHub|rebirthShop:<key>)`; read-out keys `padAt:` / `padN:<pad>`,
  `manager:<producer>`, `areaN:`, `ftue:pad5`, `ftue:manager`, `tut:<n>`.
- Admin: setCash, setArea, unlockAll, resetPlot, setRebirths, rebuildPlot, and 14 World*
  commands.

**Tycoon client** (`src/client/Tycoon/TycoonClient.start`): starts TycoonWorld →
ProducerBillboards → PadBillboards → Interaction → IncomePops → YouMarker → Income → Tutorial →
StandSign in a fixed order (names in `TycoonContract`).
- Billboards: one PreRender loop at 4 Hz; placement spots generated by
  `tools/billboards/generate-spots.luau` into `Shared/Config/BillboardSpots`; guarded by
  `tests/billboard-clearance.luau` (R31/R32/R117/R119).
- Keys: F / R2 produce, E / X buy or upgrade, Q / Y amount; buttons 1.3× on devices (R11).
- Income display reads the server's `IncomePerSecond` attribute only (never recomputed client-side).
- Join order (R16/R78): LoadingDone → HUD → plot reveal → JoinFlow (1.5 s gaps): Welcome Back →
  coach card → What's New.

**Plots** (R88: "name your plot"). Name it from the entrance sign (ClickDetector, 70-stud reach;
ProximityPrompt, 12 studs, 0.3 s hold). Saved as top-level `profile.plotName` so it survives
rebirth and shows in every world. 1–24 chars, invisible characters stripped, burst 3 then 1 per
10 s, filtered before save, censored names refused, re-filtered once per session (fail closed).
Admin: ResetPlotName (audited, confirmed). Analytics `renamePlot:set|reset|admin`. Test:
`tests/plot-name.luau` (4,000-string fuzz).

**Managers** (R30, client-only NPCs; `ManagerNpcConfig`, `Client/Tycoon/Npc/{ManagerController,
NpcBrain, NpcPose}`, rig ≤ 24 pieces built by `tools/blender/models/_npc_rig.py`). They wander
2–4 waypoints within 8 studs, do a work beat each producer cycle, wave at the owner within 14 studs
(12 s cooldown), and hop on a purchase. Device budgets: Low 3 managers / 70 studs, Mid 6 / 110,
High 10 / 160, re-ranked every 0.25 s; view-cone culled. R87 nametags with seeded names
(FNV-1a + Park-Miller) and occasional bubbles. Pure presentation, so there are no remotes and no
analytics.

## 5. Worlds, Kinetic props, Lucky Nukes (flavors), movement

**Worlds** (R57 Dino Valley, R70 Moon Base; `Shared/Config/Worlds/WorldsConfig`, WorldGeometry,
`Server/Tycoon/WorldService`). Up to 8 worlds; each has its own areas, pad / producer prefixes,
currency and tokens (main: cash / tokens; dino: bones / amber; moon: moonrocks / starshards), and
is placed at its own origin (±6000 studs). Unlocks are sticky: Dino at Nuke Town area 3 or after
1 rebirth, Moon at area 5 or after a rebirth (the R130 popup shows one area later).
Cross-world link: Nuke Town gets +10 % per Dino or Moon rebirth (each counted up to 20, total
≤ ×5.0); each extra world gets +5 % per Nuke Town rebirth (≤ ×1.5). Extra worlds pace at
10/18/24/28/32/38 min (2:30 total). Travel: 2 s cooldown, 4 s deadline, 3 s stream wait, 0.35 s
cover; the source must be menu | popup | chip. Kill switch `WorldEnabled_<id>`. Analytics
`worldTravelled`, `portalLocked`, `w_<world>`. The profile schema went v1 → v2 additively
(`profile.worlds[id]`), see the server reference, section 8.

**Kinetic props** (R90/R93: Mega Lever + Tip Jar; `KineticConfig`, `KineticLogic`,
`Server/Kinetic/*`). They unlock at Area 2 in every world. The Mega Lever pays ×10 cycles per
producer, clamped to 12–24 s of production, with a 600 s cooldown and an 18-stud reach. The Tip
Jar fills at 2 % of income per second while the player is near the plot (40-stud margin), caps
at 20 min of filling (= 24 s of income) and pays out at ≥ 5 % full. Pacing lift +6.3 % (capped
at 6.5 %). One remote, `KineticAction` (4 burst, 1/s); one 1 Hz loop. Analytics family `kinetic`
(`pull`, `pullPaid`, `jarPaid`, `pullRefused`, ...). Admin KineticSwitch / LeverReset / JarFill /
Status.

**Lucky Nukes / flavors** (R89; the player-facing word is "Lucky Nuke" per R112;
`FlavorConfig`, `FlavorLogic`, `FlavorService`, `BigPop`). Each finished cycle can roll a
flavor: Sprinkle 1/20 ×1.5, Glitter 1/100 ×3, Rainbow 1/500 ×5, Galaxy 1/2,500 ×20, Mystery Pop
1/25,000 ×100; a Flavour Book pays gems for first finds (5–150). Exact rolls up to 24 cycles,
multinomial sampling above that. Income lift +7.1 % (capped at 8 %). Big Pop server broadcast
(at most 60 s per player, 30 s global gap) for Galaxy+, mythic hatches and rebirths. Admin odds
0–10×. Analytics `flavor:*`, `flavorFind`, `bigPop:<batch|hatch|rebirth>`.

**Movement** (R21; `MovementService` + `MovementConfig`). WalkSpeed 27, JumpPower 55; Fast Walk
pass ×1.35; multipliers via `setMultiplier` (≤ ×3 per source, 8–60 clamp, ≤ 16 sources).
Client wind lines scale with speed (14 lines, 8 on phones/consoles; reduced motion turns them off).

## 6. Monetization

**Catalogue** (`Shared/Config/MonetizationConfig.luau`; ids in `PublishedProductIds.luau`, id 0
= COMING SOON). `tools/monetization/publish.py probe|plan|publish|status` creates and patches
products and passes idempotently through Open Cloud, keeps a journal, and regenerates
`docs/monetization.md`. Prices use Roblox managed pricing, so config prices are fallbacks; the
client shows real prices through `Client/UI/PriceBook.luau` (`GetProductInfoAsync`, 8 in flight,
≤ 60 calls/min, refresh every ~10 min).

**Game passes (11, R$):** VIP 122 (×1.5 cash), 2x Cash 195, Auto Clicker 73, Fast Walk 24,
Teleporter 48, Lucky Eggs 97, +2 Pet Slots 73, Triple Hatch 73, Auto Hatch 122, Offline Max 97
(24 h at 100 %), Mega Launcher 73 (×2 attack rewards).

**Developer products (~35, R$):** Gems 100/350/1,000 for 39/119/319; Cash packs 23/63/159/359
(income-relative with floors); Spins ×2/×5/×10 for 39/79/143 (paid random); crates Supply 39 /
Mega 119 / Golden 319 (paid random); Starter Pack 79 (one-time), Secret Pack 399 (one-time,
stock-limited); Server 2x Cash 159 (whole server, 15 min, stacks to 3 h); 2x Cash 30 min 79;
Shield 1 h 39; Double It! 31; Nuke Barrage 79; Nuke Pass Premium 159; Skip Pad 20; Pocket Rocket
15 (once per UTC day); Golden Revenge Nuke 31; per-world currency packs and starter packs.

**Value rules.** Bigger packs are better value. `MonetizationConfig.validate()` fails the boot if a
small product (Pocket Rocket) beats a cash pack on value per Robux, if a `oneTime` kind has no
profile flag, or if a world product names an unknown world.

**PurchaseGuard: no accidental prompts** (R122; `src/client/UI/PurchaseGuard.luau`,
`PurchaseGuardLogic.luau`, `Shared/Config/PurchaseFocusConfig.luau`). Live data showed 0
purchases from about 150–190 prompts, most closed in under 2 s: players were opening prompts by
accident. Rules:
- A BUY press only counts if it began ≥ 0.08 s after its screen or card opened
  (`PressAfterOpen`) and the surface has been up ≥ 0.3 s (`ArmSeconds`); otherwise it is refused
  as `arming` / `openingPress`.
- Robux buttons carry the `RobuxBuy` attribute; `safeDefault` never puts the gamepad cursor on one
  when a screen opens. A never buys; the DEAL card's buy key (X / E) is bound below every gameplay
  action.
- HUD offer chips and paid Lucky Buttons open a DEAL card first; walking into something never
  prompts Robux.
- Server side: a 3 burst / 0.5 s token bucket and one open native prompt per player (released
  after 20 s). `PromptRequested` is recorded before any refusal, so analytics sees intent.

**Offer surfaces.** HUD offer chips (2x Cash, Starter Pack, Pass, VIP, Spins, Teleporter, Secret
Pack, Pocket Rocket), the Shop, Welcome Back (Double It!), Lucky Buttons, the Nuke Pass, the
attack picker and the GOLDEN revenge chip, the Event shop, the Crate shop. Every prompt carries a
source label (`shop`, `offer`, `hud`, `welcomeBack`, `wheel`, `pad`, `attack`, `event`, `rebirth`,
`pets`, `teleport`, `lucky`, `pass`, `other`) for revenue attribution.

**Receipts** are idempotent with a per-profile ledger (newest 64 purchase ids). Grant and record
happen in one no-yield step with snapshot rollback, and `PurchaseGranted` waits for a durable
save; the full flow is in the server reference, section 10.

**Kid-friendly and policy rules.**
- `paidRandom` products (spins, crates, Turkey Lure) are refused for players whose
  `ArePaidRandomItemsRestricted` is true **or unknown** (fail closed; `PolicyCache`, 3 tries,
  waits ≤ 10 s). Anything bought with a Robux-reachable currency (gems, Bones) is also paid
  random, and is re-checked at roll time.
- Restricted buyers get fixed substitutes (40 gems per spin; Starter Pack 200 gems, Secret Pack
  400 gems instead of spins; a lure gives a fixed 27 acorns).
- Odds are shown before purchase: wheel weights sum to 100 on the wheel's info line; the Crate
  shop flips a card to its odds on the first press, and the second press buys.
- Never reward the favorite prompt or a group join with Robux-equivalent value beyond a small
  one-time gift; never sell "chances" to children who are restricted.
- Analytics: prompt sources, `PromptRequested`, purchases by source, `payDays` bitmap per profile,
  receipt journal for revenue.

## 7. Retention

All reward grants go through `RewardLogic.apply` in one no-yield step. Config:
`Shared/Config/{RetentionConfig, LuckySpinConfig, CodesConfig, GroupConfig, BoostConfig,
ShopConfig}`; pure logic in `Server/Retention/*Logic`.

**Daily streak** (`RetentionService`). 7 days, one claim per UTC day; missing more than the 48 h
window resets to Day 1. Day 1: 120 s of income (≥ $250); Day 2: 10 gems; Day 3: 300 s (≥ $1K);
Day 4: 2x Cash 10 min; Day 5: 2 spins; Day 6: 900 s (≥ $5K) + 15 gems; Day 7: 1,800 s (≥ $25K) +
50 gems + 3 spins + 2x Cash 30 min. Analytics `daily:claim:<1-7>`, `daily:reset`. Admin
ResetDaily.

**Playtime gift ladder** (R89; `PlaytimeService`, `GiftsConfig`). 10 gifts at 1, 3, 5, 10, 15,
25, 40, 60, 90, 120 min of today's playtime (kept across rejoins the same UTC day). The server
credits at most 5 s per 1 Hz tick. Gift #4 (2x Cash 10 min) is the moment the favorite prompt
appears (≤ 2 asks, never rewarded); #10 pays 30 min of income + 40 gems + 3 spins. Analytics
`time:*`, `favorite:*`, `rocket:*`.

**Lucky wheel** (`LuckySpinService`). One free spin every 20 min, banking ≤ 3 (no back-fill for
new players); spend order free → bonus → paid. Odds: cashS 26, gemsS 18, cashM 18, 2x Cash 12,
cashL 10, 25 gems 8, egg 6, rare pet 2. Request ids make spins idempotent; paid spins await
`resolvePaidRandomAsync` and are kept on refusal. Analytics `wheel:spin|slice|refused|receipt:*`.

**Codes** (`CodesService`). Trimmed and upper-cased, `[startsAt, expiresAt)` window, once per
player, 4 burst / 0.25 per s, refusal replies throttled to 1 per 5 s, never echoed. Admin AddCode
(this server only). Publish codes on the community server (R76). Analytics `code:ok|fail:*`.

**Group reward** (`GroupRewardService`). 600 s of income (≥ $10K) + 25 gems + a pet; membership
re-checked with `IsInGroupAsync` on every claim; shows "coming soon" while `GroupId = 0`.

**Boosts** (`BoostService`, `ServerBoostService`). Personal boosts stack up to 24 h ahead; Server
2x stacks 15 min per purchase up to 3 h; neither counts offline.

**Return notifications** (R122; `Server/Retention/ReturnNotify{Logic,Queue,Sender,Runner,Control,
Admin,Service}`, `NotifyConfig`). D1 retention was about 2 % and opt-ins were collected but
nothing was ever sent, so:
- **Opt-in card** once per session at a natural moment (first manager hired, reaching area 2,
  fallback 180 s for returning players / 480 s for new ones), after a 2.5 s wait, only when
  `ExperienceNotificationService:CanPromptOptInAsync()` is true (that call already excludes
  opted-in, under-13 and recently asked players), queued in PopupQueue (priority 40, never over a
  purchase). The reward (25 gems + 1 spin, once) is paid only within 300 s of a "shown" report;
  Roblox never tells the server whether the player accepted (a documented, small risk).
- **13+ only, opt-in only**: Roblox delivers only to opted-in players aged 13+, at most 1 per
  user per experience per day, and only for experiences with 100+ visits. Let Roblox do this
  filtering (`OptedInOnly = false` in config).
- **Plan on leave** (`ReturnNotifyLogic.plan`, at `ProfileReleasing`): at most one kind, in
  priority order: `cashFull` (after the player's offline cap; dropped if 6 h late), `streak`
  (tomorrow at the player's usual start hour, ≥ 16 h after leaving), `missions` (≥ 20 h and
  after the next mission reset). Sends are ≥ 24 h apart; sessions < 60 s plan nothing; rejoining
  cancels the entry.
- **Queue and send**: MemoryStore SortedMap by due time; every server polls every 60 s + jitter
  and claims an entry with `UpdateAsync` under a 120 s lease; it sends through the Open Cloud
  user notifications API (`POST /cloud/v2/users/{userId}/notifications`) using
  `HttpService:RequestAsync` with a 12 s timeout. The API key is a Secret in the experience's
  secrets store and is never logged or sent anywhere else.
- **Responses**: **400 = notifications off or the player is under 13**, so it is classified
  `rejected`, marked done, and never retried. 429 / 5xx / no response retry after 300 s × 2^(n-1)
  (≤ 3 attempts), honouring `Retry-After`; 401/403 pause the server's sender for 10 min.
  Rate: 10 burst, 0.5/s, ≤ 4 in flight. Studio always dry-runs.
- **Attribution**: launch data `rn:<kind>` on the next join counts `rnotify:join:<kind>`.
  Analytics `rnotify:plan|sent|result|status:<kind>:<code>|drop|join|promptAt:*`.
- Admin: NotifyToggle and NotifyKind (universe-wide), NotifyStatus, NotifyTest (owner only on
  live, 10 s cooldown).

**Quests** (R78; `QuestConfig`, `Server/Quests/QuestLogic`, `QuestService`). 12 starter goals
in order (progress never taken back; 50–100 pass XP each); 3 daily missions per UTC day chosen by a
seeded hash of (userId, day), 15 gems + 100 XP each, all 3 open the Daily Chest (25 gems + 1 spin
+ 150 XP); 1 free reroll per day; unclaimed yesterday rewards auto-paid; 9 trophies with
10/25/50/100/200-gem tiers. Progress arrives through `ProgressEvents.progress(player, kind)`
signals from other systems, never by polling. Remotes QuestClaim (12, 2/s), QuestReroll (2,
0.2/s). Analytics `quest:goalDone|goalClaim|dailyPick|dailyDone|dailyClaim|chest|reroll|trophy`.

**Nuke Pass** (season pass, R78; `PassConfig`, `Server/Pass/PassLogic` + `PassFlow`,
`PassService`). Season 1 runs one calendar month; 30 tiers × 400 XP, then a 20-gem chest every
800 XP. Play XP 10 per 5 min (≤ 360 per day) plus quest XP. Premium is a dev product (159 R$),
not a game pass, so it can be per season; a late receipt gets a 6 h grace, then 500 fallback gems.
Free row: 325 gems / 9 spins / 4 eggs; premium: 730 gems / 18 spins / 9 eggs + trail (T10),
title (T20), Mythic pet (T30). Unclaimed rewards auto-grant at season end. Premium spins and eggs
are policy-gated. Analytics `pass:xp|tier|claim|claimAll|auto|premium|premiumTier|policyGems|
season|refused`.

**Lucky Buttons** (R69 "nothing too crazy"; `LuckyButtonService`). Random buttons on the
player's own plot: free (cash 60 s of income, 2x boost 2 min, speed 2x) and paid (boost 30 min,
2x pass deal, autoclicker, pack, skip). ≤ 2 live, ≤ 1 paid, the first per session free, no
paid in New Player Mode, owned passes never offered. Life 45 s; the first appears 45–75 s after
reaching the plot, later ones every 120–240 s; they pause after 4 min idle and during the guided
tutorial. Paid ones open a DEAL card (≤ 1 prompt per 6 s). Analytics `lucky{Spawned,Claimed,
Prompted,Purchased,Expired}:<kind>`, `luckyDeal:<shown|buy|close>`.

**Happy Hours** (R89; `HappyHourConfig`, pure `HappyHourLogic`, `HappyHourService`). A
deterministic UTC schedule, the same on every server with no DataStore: at :00 a 5-min headline
event rotates (Confetti Storm, Sprinkle Surge 2x luck, Double Pops +25 % cash, Egg Stampede,
Low-Gravity); at :30 a 3-min mini surge (luck ×1.5). Pickups are worth 8–10 s of income each,
capped per player per event. Admin Force / Stop / Skip / Toggle reach every server via DataStore
+ MessagingService (90 s poll fallback). Analytics `hh:start|seen|spawn|pickup|golden|gems|admin`.

**Rush boosts** (R78; `RushService`). Rookie Rush: 2x cash for the first 15 min of online play.
Comeback Rush: 2x for 10 min after ≥ 48 h away. They don't stack, and neither applies offline.
Analytics `rush:grant|sec|done:*`, `rush:awayDays:*`.

**Change notes / What's New** (R58; `ChangeNotesConfig`, `ChangeNotesService`). Returning players
see a What's New pop-up for notes newer than their `profile.notes` mark (queued last in JoinFlow),
plus a HUD chip and a version label in Settings. Bump `VersionConfig.Current` and add a note for
every player-facing change.

## 8. Pets, eggs, crates

`PetService`, `CrateService`; `Server/Pets/{PetLogic, CrateLogic, PetIndexLogic, PetGrants,
RequestMemory, EggStands}`; configs `PetConfig`, `EggConfig`, `CrateConfig`, `PetIndexConfig`.
- 76 pets in 7 rarities; bonus = base × 1.25^(tier−1) with bases Common 4 %, Uncommon 7, Rare 12,
  Epic 20, Legendary 35, Mythic 60, Secret 100 %; bonuses add into the `petCash` modifier.
- Equip cap 3 (+2 pass, +2 rebirth shop, max 7); inventory soft cap 250.
- Area eggs cost 40 × that producer's base cost (Garage $400), so eggs scale with progress.
  Odds 65/27/7/1 % with pity (Epic in 150) up to late eggs with Secret pity in 1,500. Rolled with
  `NextInteger(1, 100000)`; the Lucky Eggs pass doubles the two rarest slots. Stand range 18 studs.
- Crates: Supply 120 gems / R$49, Mega 350 / R$149, Golden 1,000 / R$399.
- Pet Index (R78): milestones at 5/10/20/30/45/60/ALL discovered pay 25–300 gems plus a permanent
  cash bonus totalling +30 %.
- Security: request ids (32 remembered), token buckets, one hatch in flight,
  plan → charge → commit with no yield, policy re-checked after its yield.
- Analytics `eggHatched`, `equip`, `equipBest`, `delete`, `refused:<cash|slots|rate|locked|policy|
  other>`, `crateOpened`, `index:claim:*`. Admin GivePet / GiveEgg / ClearPets / GiveCrate /
  PetIndexView.

## 9. Kid-friendly attack mode

A side mode (R3: "not the primary point, a side thing"): launch cartoon toy nukes at other
plots or NPC Rival Factories, defend with AA towers and shields. Files:
`Shared/Config/AttackConfig`, pure `Shared/Attack/{AttackLogic, FlightMath, AttackGeometry,
AttackRng, DefenseTowers}`, `Server/Services/{AttackService, DefenseService}`,
`Server/Attack/*`, knockdown in `Server/Tycoon/Knockdown` + `Shared/Tycoon/KnockdownLogic` +
`KnockdownConfig`.

**The hard rule: never permanently take anything.** Cash, pads, producers, levels, pets and gems
are never removed from the target. The only spend in Attack/Defense is a player's own upgrade.
A hit mints cash for the attacker and gives the target compensation: a free Revenge token
(valid 180 s) and progress toward a free shield (3 hits → 10-min shield). Knockdowns are never
saved. The security audit checks this invariant explicitly.

**Temporary knockdown (R50).** The aimed area (must be one of the target's built areas) topples
like toy bricks with confetti; floors and roads stay.
- Duration 45 s + 3 s per launcher level above 1 (45–57 s), clamped 45–90 s (admin max 600 s).
- The area's producer pauses: no pay, no clicks, managers and auto-clicker stop. Paused income is
  never paid back, but `IncomePerSecond` is not reduced and offline earnings ignore knockdowns.
- The owner can tap REBUILD (−1 s per tap, ≤ 6 taps/s, never earlier than 6 s after the hit).
- At the deadline the master-builder fly-in rebuilds the area; pads bought meanwhile fly in after.
- Immunity: no new knockdown while any area is down or for 180 s after the last rebuild; shields
  block every knockdown. A blocked hit still pays the attacker × 0.35 and still shows confetti.

**Who and when (R85, R43).** Everyone starts with Launcher L1 (the area gate was removed in R85;
older doc text saying "area 7" is stale). New players are protected until the tutorial is done
and they have 300 s of lifetime play. AFK players can be targeted. The opt-out is a shield (free
or the Shield product, stacking to 48 h); Revenge strikes still land through shields.

**Numbers.** Launcher L1–5: cooldown 30 → 18 s, reward 8–12 s of income, armour 0–32 %. AA L1–5:
range 260–430 studs, reload 1.5 → 0.75 s, hit chance 22–34 % per shot. Upgrades cost pad price ×
{4, 40, 400, 4000}. Single-nuke intercept: AA1 vs L1 27 %, AA5 vs L1 81 %. Reward =
`rewardSeconds × clamp(areaIncome, 0.25×, 2× own income) × factor × MegaLauncher(2)`. Barrage
+20 nukes fired 0.2 s apart (store ≤ 2,000). Golden Revenge Nuke: no cooldown, +0.35 armour. AA
towers: HQ + 4 slots unlocking at areas 1/3/5/8, bought by walking on pads, levels persist through
rebirth. Rival Factories: 4 islands with AA 1/2/3/5, rewards 0.20–0.50 of own income.

**Server authority.** At launch the server decides silo, impact, flight, interception and reward
with a seeded RNG (mulberry32 of a per-server secret mixed with the nuke id), sends one ~180 B
`NukeFlight` per nuke after a 3.4 s lead-in (3-2-1 countdown), and resolves the outcome on a
`TimeQueue`. ≤ 60 nukes in flight per attacker. The picker's stream focus reads server-set
attributes, never client data.

**Analytics.** `launch:<kind>`, `intercept`, `hit`, `hitCash`,
`refused:<cooldown|protected|shield|target|rate|locked|other>`, `shield:<free|product>`,
`aa:<kind>:<lvl>`, `rival:<n>`, `knock:<area>`, `knockTap`, `knockEnd:*`, `tower:buy|up|refused`,
`golden:<buy|auto|stored>`. Admin Attack tab: test nukes, cooldowns, shields, levels, barrage,
rivals, towers, test bots (spawn, bot attacks me), knockdown area / rebuild / immunity / tuning.

## 10. Live events, social, leaderboards, community

**Harvest Feast** (the seasonal event, R1; `EventConfig.Season`, `EventService`,
`Server/Event/{EventLogic, TurkeySpawner, EventDecor}`). Runs one month with a 3-day redeem grace.
Catch turkeys (plots every 90–170 s, hub every 35–70 s, ≤ 3 in the hub) for 4–9 acorns and a 25 %
sticker roll; 20 stickers redeem an exclusive pet once per season (≈ 130 turkeys, ≈ 4 h of play),
3 starter stickers free (R97). Acorns buy the Harvest Egg, plot decor and boosts; Robux acorn
packs; Turkey Lure is paid random (restricted players get a fixed 27 acorns). EventCollect: 6 burst
/ 3 per s + 0.6 s cooldown, once per turkey, distance ≤ 32 studs checked now and 0.4 / 0.8 s ago.
`profile.event` resets when the season id changes. Analytics `turkey:*`, `acorns`,
`sticker:<1-20>`, `sheet:redeem`, `decor:*`, `lure:*`.

**Friends and referrals** (R78, R82, R122; `FriendService`, `SocialConfig`, `InviteConfig`).
Friend Boost +10 % cash per friend in the server, capped at +50 % (`IsFriendsWithAsync`, 3
attempts). Referrals: the newcomer gets 50 gems + 2x Cash 15 min; the inviter gets 100 gems + 1
spin per new friend (≤ 10 ever), queued cross-server in a DataStore and paid exactly once.
Invite surfaces: a HUD INVITE button and a once-per-session invite card ≥ 90 s after area 2 (never
before 180 s). Co-play is a top discovery signal, so make playing together pay. Analytics
`friends:boost:<0-5>`, `friends:invite:*`, `friends:ref:*`, `friends:hud:*`.

**Leaderboards and badges** (`LeaderboardService`, `BadgeService`). All-time boards: lifetime
cash (stored log-encoded, `round(log10(v) × 1e13)`, so huge doubles fit an OrderedDataStore
integer), Rebirths, Playtime, per-world rebirths. Written on change with per-player 120 s spacing,
read top 25 every 60 s, published as JSON (≤ 8,000 chars) to `ReplicatedStorage.Leaderboards`;
no remotes. Only real saved profiles rank (no Studio or sandbox). 18 badges, append-only, earned
set stored as a bitmask, awarded through a batched, backed-off queue; id 0 = skipped.

**Discord / community** (configuration only). A Community server linked from the experience's
social links: read-only START HERE with a codes channel, community, feedback, support tickets,
staff; AutoMod (spam, flagged words, raid protection); no role has Administrator. Codes posted
there (R76) give players a reason to join.

## 11. Designing a new system: checklist

Work through these in order. Do not report a system as done while any box is open.

1. **Owner request logged.** Append the message to `docs/owner-requests.md` (date, quoted key
   words, requirements). Pick the R-number for comments and commits.
2. **Spec the player experience.** What the player sees, the first 10 seconds, the moment it
   appears in the session, how it pays, how it fails. Check it against the hard rules
   (kid-friendly, nothing permanently taken, every purchase builds in, no purchase lowers a
   visible number). Write the decisions into the doc instead of asking.
3. **Config.** `Shared/Config/<System>Config.luau`: every number, catalogue, limit (rate
   buckets), timers, kill-switch default, `validate()`. Ids that become save data are final.
4. **Pure logic + tests first.** `<System>Logic.luau` with injected clock and RNG; Lune tests for
   rules, edge cases, hostile input fuzz, and pacing invariants. If it touches income, run
   `lune run tests/economy-sim.luau` and keep run 1 within ±20 % of target and the opening checks
   green. Cap any new income lift and include it in the sim.
5. **Profile schema.** Additive fields with defaults in `defaultProfile`, repair in `reconcile`
   (types, finite, clamped, bounded maps), `snapshot` allowlist for what the client may see,
   a migration + version bump only when the change is not additive. Test old saves round-trip.
6. **Server service.** Add it to `FEATURE_SERVICES` after its dependencies. Init: register product
   handlers, ModifierSources (`offline = false` where right), admin commands, analytics ids. Start:
   `Remotes.onServerEvent` handlers that pass the eight audit columns, one loop at most,
   `Forget` on leave. Declare new remotes in `Shared/Net/Remotes.luau` (RemoteEvents only).
7. **Monetization (if any).** Catalogue entry with `kind`, flags (`oneTime`, `paidRandom`,
   `world`), publish with `tools/monetization/publish.py`, a no-yield product handler, prompt
   refusals, a fallback for undeliverable receipts, PolicyService gates and shown odds for any
   random paid item, a DEAL card or confirm before any Robux prompt, source labels.
8. **Client UI, complete.** World FX / props (Blender meshes, stud material, build-in), HUD
   chip, full screen with stud panels, empty / error / loading states, toasts. KB/M + gamepad +
   touch bindings in `PlatformConfig`, controller navigation with a safe default selection
   (never a Robux button), B closes, ≥ 44 pt taps, reduced-motion path, JoinFlow / PopupQueue
   priority for anything that pops up. No backend ships without its frontend.
9. **Analytics.** A key family documented in `AnalyticsConfig.Metrics` (KeySpec patterns),
   a `<System>Analytics.luau` that records reveal / use / pay / refuse / admin, funnel steps for
   anything in the first session, revenue sources for prompts. Verify the keys appear in the
   admin report.
10. **Admin.** Kill switch, status, grant / reset / force commands for QA, audited, with Studio-only
    flags on anything dangerous. Universe-wide switches via DataStore + MessagingService.
11. **Security and performance pass.** Run the security-audit checklist (server reference,
    section 16); confirm one loop, no per-frame `Instance.new`, pooled FX, change-driven
    billboards and attributes, streaming-friendly models, `ServerHealth.addTime` around the loop.
12. **Docs.** `docs/<system>.md` in the template from section 1, plus the living system doc
    (`SELLNUKES_CLAUDE_DOCUMENTATION.md`): connections, remotes, schema, next steps.
13. **Checks.** `./scripts/check.sh` (format, lint, strict types, compile, every Lune suite) must
    pass. List what a human should eyeball in Studio (per device: phone, tablet, console).
14. **Change note and version.** Bump `VersionConfig.Current` and add a `ChangeNotesConfig` entry
    for player-facing changes so returning players see What's New.
15. **Commit** only your own hunks (several sessions share the tree), with the R-number in the
    subject.
