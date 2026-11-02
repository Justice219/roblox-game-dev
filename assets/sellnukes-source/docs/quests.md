# Quests — starter goals, daily missions, trophies (owner R78)

> R78: *"come up with a bunch of more improvements … to make the game more retentive and fun."*

Design spec: `docs/superpowers/specs/2026-10-31-r78-retention-pack-design.md` §1 (numbers, tables).
Owner of every file below: Q-quests. The Nuke Pass (§2, `docs/nuke-pass.md`) is a separate system;
Quests feeds it XP and shows its banner.

## What the player sees

One HUD left-column button **Quests** (trophy icon, after Rewards). Its red badge = claimable quests
+ claimable Nuke Pass rewards ("9+" cap). The **Quests** window has a wide **NUKE PASS** banner on top
(season, tier, XP bar, countdown, OPEN → screen `NukePass`; "Season 2 is coming soon!" between
seasons) and three tabs:

| Tab | Rows | Buttons |
|---|---|---|
| GOALS | the 12 starter goals in order (spec §1.2) | completed: green **CLAIM** → CLAIMED; current: progress bar + **GO** (opens the goal's screen, or closes Quests so the chip's arrow guides); later: LOCKED! |
| DAILY | today's 3 missions + the **Daily Chest** row, "New missions in hh:mm:ss" (UTC) | finished: **CLAIM**; unfinished: **SWAP** (the one free reroll) + **GO** for missions with a screen; chest: CLAIM once all 3 are finished |
| TROPHIES | 9 lifetime trophies with the next tier's target + reward | **CLAIM** one tier at a time; DONE when maxed |

Every claim is explicit (green CLAIM: coin burst + claim sound via ButtonFeedback, gems / cash fly into
the HUD on the profile push) and toasts the reward. The server also toasts "Goal complete!",
"Mission complete!", "All 3 missions done - open your Daily Chest!" and "Trophy unlocked!".

**Objective chip (bottom centre):** the Nuke Town tutorial keeps the chip until it is finished. Then
the chip shows the current starter goal with a progress bar, a "3/5" counter and the guide arrow to
the right pad / producer; after goal 12 the first unfinished daily mission ("Daily: Buy 6 pads");
else it hides. Tapping / clicking the chip opens Quests (source "chip"). Non-main worlds keep their
own WorldObjectives chip (Quests never shows there).

## Rules (QuestConfig / QuestLogic)

- **Goals** are state checks on the profile where possible: Nuke Town pads owned, Workbench level,
  Manager pads owned, area reached, best producer level, `stats.hatched`, a daily reward ever
  claimed. Any Nuke Town rebirth implies every run goal (pads / levels / managers / areas). "Spin the
  Lucky Wheel" counts wheel spins since the chain started (`starter.base`). `starter.step` = goals
  completed in order and is **sticky** (a rebirth never takes a goal back); any completed goal can be
  claimed once.
- **Daily missions:** 3 per UTC day from the pool (click, pad, upgrade, hatch, spin, gift,
  playMinute, lucky, turkey — turkey only while the Harvest Feast is live), picked by a portable
  seeded hash of (userId, day) — identical on every server and under Lune — with targets by tier
  (1 = Nuke Town area ≤ 3, 2 = area ≤ 6, 3 = beyond or any rebirth in any world). No two missions share
  a stat. 15 gems + 100 XP each; all 3 finished → Daily Chest 25 gems + 1 bonus spin + 150 XP. One
  free reroll per day swaps an unfinished, unclaimed mission for a stat not already shown.
  A clock running backwards opens nothing.
- **Carry-over (design decision, kid-friendly "nothing earned is lost"):** finished but unclaimed
  missions and an earned chest from an earlier day are paid automatically at the day roll, with a
  toast ("Yesterday's missions paid out: +30 Gems").
- **Trophies:** counter trophies read `life[stat]` (counted from 0.6.0); where the profile already
  kept a lifetime counter the trophy reads the larger one (design decision: veterans' history counts):
  Clicker ← `stats.clicks`, Builder ← `stats.padsBought`, Hatcher ← `stats.hatched`, Time Traveller ←
  `stats.playSeconds / 60`. State trophies: Collector (Pet Index entries; last tier "all" =
  every non-exclusive pet, `QuestConfig.CollectorAll`), Explorer (worlds unlocked incl. Nuke Town),
  Reborn (rebirths in every world). Tier rewards 10 / 25 / 50 / 100 / 200 gems + 75 XP each.
- **Rewards** go through `RewardGrant.grant` (RewardLogic.apply: gems, spins → the BONUS bank,
  `cashSeconds` + `cashFloor`, boosts), reason `quest`. **Nuke Pass XP** on every claim:
  `ProgressEvents.xp(player, xp, "starter" | "daily" | "chest" | "trophy")`.

## Files

| File | Role |
|---|---|
| `src/shared/Config/QuestConfig.luau` | Goals, missions, trophies, rewards, XP, limits, cadence; state shape (`newState` / `reconcileState` / `snapshot` / `read`); `facts(profile)`; read-only views (`goalProgress`, `starterViews`, `dailyViews`, `trophyViews`, `claimableCount`, `currentGoal`, `tierOf`); analytics key builders (`Keys`) |
| `src/server/Quests/QuestLogic.luau` | PURE mutations: `seed` / `generator` / `pickStats`, `startChain`, `rollDay`, `applyProgress`, `advanceStarter`, `forceStep`, `claimStarter` / `claimDaily` / `claimChest` / `claimTrophy`, `reroll`, `resetDay`, `setCounter`, `readClaim` / `readSlot` |
| `src/server/Services/QuestService.luau` | Live boundary: ProgressEvents listener, ProfileLoaded, the 5 s loop (`playMinute` once per online minute, UTC rollover, throttled pushes), remotes, rewards, XP, analytics, toasts, admin commands |
| `src/server/Progression/ProgressEvents.luau` | (lead) the progress bus; Quests added the one-line fires listed below |
| `src/client/Quests/QuestClient.luau` | Client model (boot controller): View rebuild on relevant pushes + UTC midnight, HUD badge, intents (`claim`, `reroll`), `Changed` |
| `src/client/Quests/QuestObjective.luau` | Post-tutorial objective chip content + guide arrow targets (streaming-aware) |
| `src/client/Quests/PassBridge.luau` | Guarded PassConfig reads for the banner + badge (works before / after the pass ships) |
| `src/client/UI/Hud/HudObjective.luau` | The chip: PRIMARY (tutorial / world objective) and the new SECONDARY quest layer (progress bar, counter, tap to open Quests) |
| `src/client/UI/Screens/Quests/init.luau` | The Quests screen (ResponsiveModal "tall" / "wide") |
| `src/client/UI/Screens/Quests/QuestRow.luau` | One row (built once, re-filled) |
| `src/client/UI/Screens/Quests/PassBanner.luau` | The NUKE PASS banner |
| `tests/quest-logic.luau` | Lune suite (34k checks) |

Shared tables touched (small additive edits): `Shared/Net/Remotes` (QuestClaim, QuestReroll),
`Economy/ProfileLogic` (type, default, reconcile, snapshot builder `quests`, header doc),
`AnalyticsConfig` (retention `quest:*` metrics, funnel screen `Quests`, transaction type `quest`),
`HudZonesConfig` (left row `Quests`), `init.server.luau` (`QuestService` before AdminService),
`init.client.luau` (`Quests/QuestClient`), `tests/validate.luau` (remote list), `tests/profile-logic.luau`
(default schema), `tests/hud-cluster.luau` (6 default left tiles).

## Progress fires (spec §1.1, one line next to the existing analytics call, after commit)

| Stat | Where |
|---|---|
| `click` | `TycoonService` onProducerClick (one manual cycle); owner R83: while the AutoClicker pass clicks (manual clicks are no-ops then) `tickRuntime` credits the cycles it finishes in the world the player is in, at most `QuestConfig.AutoClickCreditPerSecond` (4) per second (`TycoonRules.autoClickCredit`, tested); click rows show a green AUTO ON chip instead of KEEP GOING |
| `pad`, `manager` | `TycoonService.purchasePad` (any world; `manager` for Manager pads) |
| `upgrade` (amount = levels) | `TycoonService` onProducerUpgrade |
| `area` | `TycoonService.purchasePad` deferred block (Nuke Town AreaReached + WorldAreaReached) |
| `hatch` (amount = pets) | `PetService` after `eggHatched` |
| `crate` | `CrateService` after `crateOpened` |
| `spin` | `LuckySpinService` after `wheel:spin:<bank>` |
| `daily` | `RetentionService.claimDaily` |
| `gift` | `PlaytimeService` time gift claim |
| `rebirth` | `RebirthService` (Nuke Town + every world) |
| `lucky` | `LuckyButtonService` free claim |
| `turkey` | `EventService` turkey collect |
| `world` | `WorldService.unlock` |
| `playMinute` | `QuestService` loop, once per online minute per player |

## Remotes

| Remote | Dir | Payload | Checks |
|---|---|---|---|
| `QuestClaim` | C→S | `(kind, id)`: `"starter"` 1..12, `"daily"` 1..3, `"chest"`, `"trophy"` trophy id | `QuestLogic.readClaim` (Validate.oneOf / integer / configKey; NaN, inf, tables, metamethod names refused), RateLimiter 12 burst / 2 s⁻¹, canMutate, claim flag + RewardGrant in one non-yielding step (idempotent: a repeat returns "claimed"), refusals toast + `refresh({"quests"})` |
| `QuestReroll` | C→S | `(slot)` 1..3 | `QuestLogic.readSlot`, RateLimiter 2 burst / 0.2 s⁻¹, once per day, never a finished / claimed mission |

Results come back through the profile sync (`quests`) + toasts. No server→client remote.

## Profile (`profile.quests`, schema in `ProfileLogic` header)

```
starter  { step = 0..12, base = { spin = n }, claimed = { boolean x 12 } }   -- dense array (DataStore / remote safe)
daily    { day = UTC day (-1 = never), picks = { { stat, target, progress, claimed } x 3 }, chest, rerolled }
life     { click, pad, upgrade, hatch, daily, playMinute, spin = lifetime counts since 0.6.0 }
trophies { [trophyId] = tiers claimed }
```
`starter.base` keeps zeros through reconcile, and `startChain` only ever fills a MISSING base with 0
(never the lifetime count). R78 review fix: base 0 used to be dropped on load and re-based to the
spins already made, which reset "Spin the Lucky Wheel" on every rejoin; affected saves migrate to 0.
Reconcile clamps every number, drops junk / duplicate picks, refuses a chest flag without 3 finished
missions and claims beyond the step, bounds maps to 32 keys (a newer server's keys are kept). Sync:
the whole record (~450 B) rides the `quests` snapshot field; progress-only changes push at most every
`QuestConfig.PushSeconds` (2 s), completions / claims / new days at once (well inside the 4 pushes/s
budget, `docs/core.md`).

## Analytics (retention family, `AnalyticsConfig.Metrics`)

`quest:goalDone:<1-12>`, `quest:goalClaim:<1-12>`, `quest:dailyPick:<stat>` (seeded + rerolled-in),
`quest:dailyDone:<stat>`, `quest:dailyClaim:<stat>` (incl. carry-over), `quest:chest`,
`quest:reroll:<stat swapped away>`, `quest:trophy:<id>:<1-5>`. Screen funnel `open:Quests` /
`openFrom:Quests:<hud|chip|...>`. Reward gems / cash report as economy `earn:<cur>:quest`
(transaction type Gameplay). Pass XP is counted by the pass (`pass:xp:<source>`).

## Admin (owner panel, Players tab, registered from QuestService.Start)

| Command | What |
|---|---|
| Complete Starter Goal (`QuestCompleteGoal`) | completes the player's current goal (they still press CLAIM); audited |
| Reset Daily Missions (`QuestResetDaily`) | three fresh missions for today (progress, chest, reroll reset); audited |
| Set Trophy Counter (`QuestSetTrophy {trophy, value}`) | sets a counter trophy's lifetime count (claimed tiers kept; state trophies refuse); audited |
| Quests Status (`QuestStatus`) | read-only summary (goals, missions, chest, reroll, trophies, claimables) |

## When Quests opens (`Client/Quests/QuestOpenRules`, pure, tested)

Nothing auto-opens Quests. Ways in: the HUD button / menu wheel (they replace any open window), the
WHAT'S NEW 0.6.0 call-to-action (closes What's New first) and the objective chip tap. Root cause of
the R78 QA report "Quests opened by itself over NukePass": the chip's tap target sits on the HUD under
every window, and a window's plain Frames do not sink input, so a click on an open window's empty area
fell through to the chip. Fix: `QuestOpenRules.chip` allows a chip tap only when the chip shows a quest
objective, no window is open, JoinFlow is not guiding the first minute and the tutorial is done
(unknown inputs refuse); HudObjective also hides the tap target while any window is open.

## GO / OPEN hand off (owner R79)

Every Quests GO button (starter goals, daily missions) and the Nuke Pass banner's OPEN use
`ScreenManager.handoff("Quests", target, { source = "quests" })`: Quests stays open in the modal
stack but hides while the target window is up (only the Lucky Wheel / Pets / Nuke Pass ... is on
screen) and comes back on its own when that window closes, with the gamepad back on the pressed
GO / OPEN (`returnTo`, cleared on a tab change / close). Non-modal or unregistered targets fall back
to a plain open, so the player is never left on a blurred empty screen.

## Console + mobile

ResponsiveModal modes "tall" (1180 × 820: desktop / console / tablet) and "wide" (1560 × 680: landscape
phones). Phones get a left rail (the NUKE PASS card as one "PASS · T3" button, the three tabs, the
summary / reset countdown) and compact two-line rows (title; reward | bar | counter), so 4+ rows show
at once on an iPhone-class phone. Text floors are set in RENDERED px (UITextSizeConstraint counts
device points on touch: 14), never the design-px `minText`. Touch: rows, tabs and buttons ≥ 44 pt, scaled text floors at 14 pt. Gamepad: LB / RB cycle the
tabs; banner OPEN ↕ tabs ↕ rows (a row's SWAP is Left of its main button); the list follows the
cursor; the default selection is the tab's first CLAIM (else its first row, never the close X);
B / Back closes; GO opens screens stacked over Quests (B returns). The chip's tap target is never
gamepad-selectable (no HUD cursor trap) — gamepads use the HUD button / menu wheel.

## Tests

`lune run tests/quest-logic` — config vs spec, state shape + ProfileLogic integration (default,
reconcile, snapshot, DataStore-safe save), seeding determinism + distribution + tier targets + UTC
rollover / backwards clock, progress caps, the starter chain (state checks from real pads, counter
goal, veterans, sticky after rebirth), claims (idempotent, codes, chest, trophies with backfill),
rerolls (once, never shown stats, deterministic), hostile remote arguments, views + badge count, and
every analytics key through the real KeySpec.

Studio QA (one solo playtest, hold the lock): `STUDIO_LOCK_OWNER=Q-quests python3 tools/qa/quests.py`
(+ `quests_server.luau` / `quests_client.luau`): demo state through the live rules, the objective chip,
every tab + the device matrix, the real ProgressEvents bus, a real-click CLAIM + idempotent repeat,
mission / trophy claims, the reroll (second refused), hostile arguments, the gamepad default
selection, restore. Captures: `docs/verification/r78-quests/`.

## Next steps

- Tune mission targets / rewards from `quest:dailyPick` vs `quest:dailyDone` and `quest:goalDone:<n>`
  drop-off (goal funnel = where new players stall).
- Season 2 needs no Quests change (the banner reads PassConfig).
