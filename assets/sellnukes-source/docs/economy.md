# SellNukes economy (tycoon logic, pacing, rebirth)

How money works in SellNukes, the numbers the pacing simulator achieved, and how to retune it.
Owner of these files: B3 Tycoon logic (wave 1). Spec: `docs/superpowers/specs/2026-10-30-sellnukes-design.md`
§2 (core loop, pacing), §3 (areas), §7 (offline), §2.5 (rebirth).

## Files

| File | What |
|------|------|
| `src/shared/Tycoon/TycoonLogic.luau` | Every formula (pure, deterministic, hostile-input safe) |
| `src/shared/Tycoon/Modifiers.luau` | Resolves the one `Modifiers` table (pets, passes, boosts, rebirths, server boost, event) |
| `src/shared/Tycoon/TycoonTypes.luau` | Shared types: `AreaConfig`, `ProducerConfig`, `PadConfig`, `TycoonState`, `Modifiers`, `ProducerStats`, ... (no requires) |
| `src/shared/Tycoon/SafeMath.luau` | NaN / inf / wrong-type guards used by every entry point |
| `src/shared/Config/TycoonConfig.luau` | Global tunables, the ten areas, load-time validation, lookup indexes, friendly prices, deep freeze |
| `src/shared/Config/TycoonAreas/Area01..Area10.luau` | One producer + its pads per area (ids are SAVE DATA) |
| `src/shared/Config/RebirthConfig.luau` | Rebirth bonus, token reward, Rebirth shop |
| `tests/tycoon-logic.luau` | 3,469 checks incl. the purchase-monotonicity invariant (`lune run tests/tycoon-logic.luau`) |
| `tests/economy-sim.luau` | Pacing simulator + tuner (`lune run tests/economy-sim.luau [--timeline] [--tune [--write]]`) |

## Data model

* **State** = `profile.tycoon`: `pads[padId] = true` (only `true` counts as owned), `producers[producerId] = level`
  (0 / missing = not built), `area` = highest unlocked area.
* **Producer** (one per area): `id, name, area, builtBy, baseCost, costGrowth, baseRevenue, baseCycle, clickable`.
  The area's first pad (`builtBy`) builds it at level 1.
* **Pad**: `id, area, name, kind, cost, requires, target, value, unlocks?, feature?, build, blurb`. Kinds:
  `Build` (+`value` fraction cash to the area producer, e.g. 0.1 = +10 %), `Multiplier` (x`value` cash),
  `Speed` (x`value` speed), `Manager` (automates), `Unlock` (`unlocks` = next area; the finale has
  `feature = "Rebirth"`), `Feature` (`feature` = `"AATower"` / `"AttackConsole"`). The Nuke Stand's Neon Sign
  (x3) also carries `feature = "StandRename"`.
* **One chain**: every pad `requires` the previous pad; the first pad of area N requires area N-1's Unlock pad.
  93 pads total. `TycoonConfig` validates the chain, kinds, ids and numbers at load and deep-freezes it.
* **Save data**: pad ids (`a3_mobile_app`), producer ids (`p3_boomdash`) and Rebirth shop keys are stored in
  profiles. Never rename or reuse one. Build keys and names/blurbs can change freely.

## Formulas

All tunables live in `TycoonConfig` / `RebirthConfig`; `TycoonLogic` holds the maths.

| Quantity | Formula |
|----------|---------|
| Milestones | `m = floor(level / 25)`; odd milestones (25, 75, 125, ...) x2 cash, even (50, 100, ...) x2 speed |
| Milestone cash / speed | `2^ceil(m/2)` / `2^floor(m/2)` |
| Pad cash | `product(Multiplier values) x (1 + sum(Build values))` for owned pads targeting the producer |
| Pad speed | `product(Speed values)` |
| Speed | `milestoneSpeed x padSpeed x mods.speed x (automated ? mods.managerSpeed : 1)` |
| Cycle | `max(baseCycle / speed, CycleFloor)` (0.1 s) |
| Floor conversion | `max(1, CycleFloor / raw cycle)` x cash: speed that does not fit becomes cash, $/s exactly preserved; at the floor every further x2 speed milestone is exactly x2 cash, and a cycle never gets longer |
| Output per cycle | `baseRevenue x level x milestoneCash x floorConversion x padCash x mods.cash` |
| Click payout | output computed as not automated (no manager speed); one manually started cycle |
| Upgrade L -> L+1 | `baseCost x costGrowth^(L-1)` |
| Upgrade L -> L+n | `baseCost x g^(L-1) x (g^n - 1) / (g - 1)`, rounded up (closed-form geometric series) |
| Max affordable | `n = floor(log(1 + cash (g-1) / c0) / log g)` then nudged against the exact rounded price |
| Idle $/s | sum over **automated** producers of `output / cycle` (manual producers only earn while clicked) |
| Offline | `idle $/s x clamp(elapsed, 0, cap) x clamp(rate, 0, 1)`; nothing under 60 s |
| Offline limits | cap `3 h + 1.5 h x offlineHours`, rate `50 % + 5 % x offlineRate`, both max 24 h / 100 %; Offline Max pass = 24 h / 100 % |
| Global cash mods | `(1 + petCash) x 2 (2x Cash pass) x 1.5 (VIP) x boostCash x serverCash x eventCash x rebirth x production` |
| Power Production | `1 + 0.1 x rebirthShop.clickPower`, applies to clicked AND automated cycles |
| Rebirth multiplier | `1 + (0.5 + 0.05 x rebirthPower) x rebirths` (additive: x1.5, x2.0, x2.5 ...) |
| Rebirth tokens | `floor((20 + totalLevels / 25) x (1 + 0.1 x rebirthsSoFar))`, 0 before the finale |
| Shop price | `ceil(baseCost x costGrowth^level)` tokens |

`MaxLevel` = 1000 (bounds every power far inside doubles); `MaxBulkLevels` = 1000. Every modifier is a bonus:
values below 1, NaN, inf or wrong types resolve to neutral; anything above `MaxMultiplier` (1e6) is clamped.

## API (TycoonLogic)

`producerOutput(cfg, level, mods, state?)`, `cycleTime(cfg, level, mods, state?)`, `clickValue(cfg, level, mods, state?)`,
`clickCycleTime(...)`, `milestoneMultipliers(level)`, `milestoneBadge(level)` -> `{milestones, cash, speed, nextAt?, nextKind?, text}`,
`padMultipliers(state, producerId)`, `producerStats(state, producerId, mods)` -> `ProducerStats?`,
`upgradeCost(cfg, level, count)` (`math.huge` = cannot), `maxAffordable(cfg, level, cash)` -> `count, cost`,
`incomePerSecond(state, mods)`, `offlineLimits(shop, hasOfflinePass)` -> `cap, rate`,
`offlineEarnings(state, mods, elapsed, cap, rate)` -> `amount, creditedSeconds`,
`ownsPad`, `levelOf`, `isAutomated`, `padAvailable(state, padId)` -> `ok, "unknown"|"owned"|"locked"`,
`nextPads(state)`, `areaProgress(state, area)` -> `bought, total`, `areaUnlocked`, `hasFeature(state, key)`,
`newState()`, `applyPad(state, padId)`, `applyLevels(state, producerId, count)`, `totalLevels`, `canRebirth`,
`rebirthReward(state, rebirths?)`, `rebirthMultiplier(rebirths, shop)`, `rebirthShopCost(key, level)`,
`rebirthShopEffect(key, level)`, `startingCash(shop)`.

### How the server should use it (B5)

* **Tick (automated)**: per producer with `isAutomated`, pay `producerOutput` every `cycleTime` (one server loop).
* **Click (manual)**: `ProducerClick` starts one cycle if none is running; when it completes pay `clickValue`
  (cycle length `clickCycleTime`). Ignore clicks on automated producers.
* **Upgrade** `"1" | "10" | "max"`: price with `upgradeCost(cfg, level, n)` (for "10" near the cap use
  `min(10, MaxLevel - level)`) or `maxAffordable`; `trySpendCash`, then `applyLevels`.
* **Pad buy**: `padAvailable`, distance check, `trySpendCash(pad.cost)`, then `applyPad` (sets producer level 1 for
  builder pads, raises `state.area` on Unlock pads).
* **Offline**: elapsed from the server's own `lastSeenAt`; `offlineLimits(profile.rebirthShop, ownsOfflineMax)`,
  then `offlineEarnings`. Decide which timed boosts count offline when building `mods` (suggest: none).
* **Rebirth**: require `canRebirth`; grant `rebirthReward(state, profile.rebirths)` tokens; `rebirths += 1`;
  `profile.tycoon = newState()`; `cash = startingCash(profile.rebirthShop)`.
* **Modifiers**: build one table per player (cache it; rebuild on pass / pet / boost / event change).
* **Performance**: cache `producerStats` per producer and recompute only on a purchase, level-up or modifier
  change; the tick then just reads `stats.output` / `stats.cycle` (no per-cycle formula work or allocation).

### How the client should use it (B6)

* Billboard: `producerStats` -> `output` (equals `clickPayout` while manual), `cycle`, `badge.text` ("x4")
  with `level` ("x77"), `nextCost` on the UPGRADE pill. A manual producer shows CLICK.
* Pads: show `nextPads(state)`; billboard = `name`, `blurb`, `cost`.
* Teleport list: unlocked areas teleport; a locked area N shows `areaProgress(state, N - 1)` ("7 / 9 purchases").

## Owner rule: no purchase ever lowers a number the player sees

Every factor in the formulas is non-decreasing in every purchase, and `tests/tycoon-logic.luau` enforces it:
walking all 93 pads in config order, every producer level 1 -> 1000 (before and after its Manager) and every
Rebirth-shop level, with no bonuses / 3 rebirths / maxed shop / floor-hitting boosts, a producer's shown cash
per cycle (clicked payout before its Manager, automated output after) never drops, its cycle never gets
longer, and idle $/s never drops. Two design choices exist only for this rule: Power Production (shop key
`clickPower`) multiplies automated cycles too, so buying a Manager never lowers $/cycle; and the cycle floor
converts excess speed exactly (`floor / raw`) instead of in powers of two, which could lengthen a cycle from
0.11 s to 0.19 s when speed was added. Any new modifier must keep this property (add it to the test's variants).

## Pricing structure (why the numbers look like they do)

Each area file prices everything in its `SCALE` (a few seconds of the income the player has when the area opens):

* **New producer** level 1 clicked income = **1 %** of arrival income (`baseRevenue`), level 1 -> 2 costs `3 x SCALE`,
  `costGrowth` = **1.2** (must clearly beat the milestone growth of 2^(1/25) = 1.028/level, or levels run away).
  **Exception — the Workbench (owner R65):** its level 1 -> 2 is pinned to exactly **$10**
  (`FIRST_UPGRADE_COST` in `Area01.luau`), not `3 x SCALE`; see "Garage Lab opening" below.
* **Builder pad** (first of the area) = `10 x SCALE`.
* **Every other pad sits on the producer's level-cost curve**: `price = weight x L x 3 x 1.2^(L-1)` SCALE units at a
  designated level `L`, with `weight = value - 1` for Multiplier/Speed, 1 for the Manager, 0.5 for Build/Feature
  pads. At that price a pad pays back exactly as fast as the next level, so a payback-greedy player buys pads in
  between upgrades. Prices are forced to rise >= 15 % along the chain.
  Designated levels for pads 2.. in order: 9-pad areas `3, 6, 9, 13, 18, 22, 25` (the Manager is the 25 slot);
  Rocket Factory `3, 6, 9, 13, 17, 20, 22, Manager 25`; Launch Silos `3, 6, 9, 13, 18, Manager 25, 28, 32`
  (the Nuke Stand used `3, 6, 9, 13, 18, 22, Manager 25, 30` until R137). **Exceptions, shaped by hand with the
  pacing sim:** the Garage Lab (owner R122, re-paced R137) around the pinned $10 level curve (Uncle Atom is
  pad 4; see "Garage Lab opening"), BoomDash Delivery (R130, Dispatcher pad 4; "BoomDash order") and the Nuke
  Stand (R137, Cashier Bot pad 4; "Nuke Stand order (R137)").
* **Unlock pad** = 3 x the pad before it (Nuke Stand ~2.5x since R137: its Unlock save is the area's longest wait).
* `TycoonConfig.friendlyPrice` rounds every price to 2 significant digits at load ("$73M", not "$72,913,402").

This structure is what makes the pacing smooth and robust: the first visit to an area is a quick burst
(builder + 2–3 pads within a minute or two), then one pad every few minutes, then a short save for the Unlock.

## Simulated player (tests/economy-sim.luau)

Event-driven (income is constant between purchases; the sim jumps to the moment the chosen purchase is
affordable). Clicks: a new cycle starts 0.25 s after the bar fills; only the newest producer is manual.
Walking: 3 s per pad, 4 s per area of distance (max 12 s), manual clicking pauses while walking.
Choice: goal pads (builder, Manager, Feature, Unlock) are beelined, taking a producer upgrade only if it
reaches the goal sooner; otherwise the best `cost / income + cost / gain` among +1 level, "to next
milestone", and the next 1–3 pads as a bundle. Rebirth: tokens spent cheapest-first on clickPower (Power Production),
managerSpeed, startingCash, rebirthPower.

Robustness (2026-10-30): click reaction 0.5 s instead of 0.25 s moves areas 2–10 by +3..+9 % (area 1, all
manual, +21 %); 0.15 s moves them -1..-8 %; 8 s walks instead of 3 s <= +9 %; no bundle lookahead <= 3 %.

## Achieved pacing (2026-10-31, after R65)

Run 1 (first playthrough, no Robux) — asserted within +/-20 % of the spec targets:

| # | Area | Target min | Sim min | Dev | Cumulative | Unlock cost | $/s at unlock | Producer lv |
|---|------|-----------|---------|-----|-----------|-------------|---------------|-------------|
| 1 | Garage Lab | 8 | 8.0 | -0 % | 0:08 | $56K | $1.15K | 37 |
| 2 | Nuke Stand | 15 | 14.4 | -4 % | 0:22 | $7.3M | $34K | 39 |
| 3 | BoomDash Delivery | 25 | 25.0 | -0 % | 0:47 | $400M | $1.53M | 33 |
| 4 | Glow Rock Mine | 35 | 34.8 | -1 % | 1:22 | $27B | $65.5M | 33 |
| 5 | Enrichment Lab | 45 | 46.4 | +3 % | 2:09 | $1.1T | $1.53B | 33 |
| 6 | Rocket Factory | 50 | 50.3 | +1 % | 2:59 | $32T | $33B | 31 |
| 7 | Launch Silos | 60 | 60.8 | +1 % | 4:00 | $1.1Qa | $663B | 34 |
| 8 | Nuke Megastore | 70 | 70.7 | +1 % | 5:10 | $19Qa | $12.8T | 30 |
| 9 | Space Port | 80 | 79.7 | -0 % | 6:30 | $790Qa | $942T | 33 |
| 10 | Mega Nuclear Facility | 90 | 90.2 | +0 % | 8:00 | $97Qi | $90Qa | 34 |

Total **8:00** (480.2 min); lifetime cash earned **$179Qi**; final idle income **$90Qa/s**. Cash scale climbs
K -> M -> B -> T -> Qa -> Qi across the run (income grows roughly x30–x50 per area).

**Current run (2026-11-01, after R89 flavours / R90 Mega Lever / R115 auto-serve lifts and the R122 Garage Lab
re-pace):** Garage Lab **8.0 min (+0 %)**, $110K Unlock, $1.42K/s, lv 40; Nuke Stand 12.4 (-18 %), BoomDash 21.4
(-14 %), Mine 29.8 (-15 %), Lab 39.9 (-11 %), Rocket 43.0 (-14 %), Silos 52.0 (-13 %), Megastore 60.4 (-14 %),
Space Port 68.2 (-15 %), Facility 77.5 (-14 %); total **6:53**; run 2 **3:09** (54 % faster). Areas 2–10 run
11–18 % fast since the R89/R90/R115 lifts (all inside +/-20 %); they were deliberately NOT re-tuned in R122
(a full `--tune --write` would raise every price in areas 2–10 for live players — a separate decision).

**Current run (2026-11-01, after R137 — Garage Lab first two minutes + Nuke Stand order):** Garage Lab **7.0 min
(-12 %)**, $110K Unlock, $1.42K/s, lv 40 (unchanged arrival income); Nuke Stand **12.5 (-16 %, unchanged)**,
$5.1M Unlock, $38.6K/s, lv 39 (unchanged); BoomDash 22.2 and every later area exactly as before; total **7:02**
(421.8 min, was 7:03 / 422.8); run 2 **3:12** (was 3:13, 55 % faster).

Run 2 after one rebirth (x1.55 cash, 37 tokens -> Power Production 3, Speedy Managers 2, Head Start 1,
Golden Atoms 1): **3:40 (219.5 min), 54 % faster** (the +50 % rebirth bonus alone gives 33 %).
Before R65 (2026-10-30): Garage Lab $45K Unlock, $1.06K/s, lv 34; Nuke Stand 15.0 min; run 2 3:39 with 36 tokens.

## Garage Lab opening (owner R64 + R65, 2026-10-31; R122 order, 2026-11-01; R137 first two minutes)

### R137 — something new every 20–40 s in the first two minutes (owner R137, 2026-11-01)

**Why** (live data 2026-11-01, build 0.9.x, ~240 new players; docs/owner-requests.md R135–R137): ~50 % of
first sessions end within 3 minutes (21 % under 60 s, 30 % at 61–180 s) and 34 % end right after the first
producer upgrade. Real minutes to the first pads (all builds): Workbench (free) 0.7 -> **Tool Wall ($42) 1.7**
(419 -> 319 buyers: a full minute of $1 clicks) -> Glow Lamp 2.3 -> Uncle Atom. The head of the area was too
expensive for a player who has not decided to stay yet.

**Pacing (greedy sim player, `lune run tests/economy-sim.luau --timeline`, SCALE 6.49 unchanged, pad order
unchanged):**

| Pad | Multiple | Price | Sim min (gap) | Before R137 (multiple, price, min) |
|---|---|---|---|---|
| Workbench | 0 | free | 0.05 | 0, free, 0.05 |
| Tool Wall | 1.7 | **$11** | **0.48** (26 s, Workbench lv 3) | 6.5, $42, 1.10 (lv 10) |
| Glow Lamp | 3 | **$19** | **0.64** (10 s) | 40, $260, 1.61 |
| **Uncle Atom** (automatic from here) | 46 | $300 | **1.22** (35 s) | 46, $300, 1.93 |
| Garage Door | 52 | $340 | 1.90 (41 s) | 52, $340, 2.54 |
| Mini Reactor | 360 | $2.3K | 3.19 (77 s) | 450, $2.9K, 3.91 |
| Paint Station | 2,500 | $16K | 4.26 (64 s) | 3,100, $20K, 5.24 |
| Driveway | 5,400 | $35K | 5.64 (83 s) | 5,700, $37K, 6.63 |
| Open the Nuke Stand | 17,000 | $110K | **7.02** (83 s) | 17,000, $110K, 8.01 |

Area 1 **7.0 min (-12 % of 8)**, longest wait **83 s** (unchanged), longest stretch without a new pad in the
first 2 min **41 s** (was 63 s), first Manager **1.22 min** (was 1.93); steps from the Garage Door on
**<= 7.0x** (was 8.5x Garage Door -> Mini Reactor). Income at the Unlock **$1.42K/s at Workbench lv 40 —
unchanged**, so area 2 and every later area play exactly as before (the Nuke Stand just opens ~1.0 min
sooner). With the tutorial (step 3 = "Press UPGRADE" for $10, step 4 = Tool Wall, step 5 = Glow Lamp) a real
player buys the $11 Tool Wall six clicks after the first upgrade and the $19 Glow Lamp right after it.

**The Tool Wall stays dearer than the first upgrade** (R65 rule, `tests/tycoon-logic.luau`: the tutorial
teaches UPGRADE first). A lone +10 % pad at $11 loses to the levels until Workbench level ~5 (0.6 min), so
the Glow Lamp is priced so the greedy player values the PAIR: the sim scores the next 1–3 pads as a bundle
(`cost / income + cost / gain`), and Tool Wall + Glow Lamp (x2.2 together) beat the level-3 upgrade while
they cost <= ~$31 ($11 + $19 = $30). Dearer, the Tool Wall slips to level 4 (0.56 min) or 5 (0.64).

**Why 7.1 min, not 8.0** (scratch harness around the real sim, ~5,000 runs over the eight multiples): once
the head is fast, two Workbench milestones pin the tail, not the prices —
* the Garage Door (+10 %) flips at **$360** (still the R122 limit): dearer, it loses to the levels until the
  level-25 milestone (bought at ~3.0 min, a ~100 s wait after Uncle Atom);
* the Mini Reactor is bought right after the level-25 milestone (~3.3 min), the Driveway (+10 %) right
  before level ~40 (~5.8 min); a Driveway dearer than **~$40K** slips past the level-50 milestone (~10 min,
  a 5-minute wait);
* with steps <= 7x the Paint Station can cost at most ~7x the Mini Reactor (~4.4 min).
So after the Driveway only the Unlock save is left: 8.0 min needs a ~2 min save (or the Garage Door after
the milestone, ~100 s gaps). Best layouts found: 7.0–7.2 min at <= 85 s, 7.1–7.35 min at 90 s, 7.25–7.5 min
at 95 s.
The shorter area was preferred over longer waits: the opening, not the area length, is where players leave.

**Sim assertions (tests/economy-sim.luau `OPENING_CHECKS`, area 1, tightened):** first Manager by **1.5 min**
(was 4.0), no wait above **85 s** (was 90), and new `earlyMinutes = 2` / `earlyGapSeconds = 45`: inside the
area's first 2 minutes there is never a stretch longer than 45 s without a new pad (each wait clipped at the
window's end, so the Garage Door -> Mini Reactor wait that starts at 1.9 min counts 6 s). The run prints
`first 2.0 min of area 1: longest stretch without a new pad 41 s, before a1_garage_door`.

**Tuner (R137 fix):** the old guard ("a SCALE that breaks the opening counts as too slow") assumed the limits
break only above one SCALE. They do not (Garage Lab: 5.5 breaks the 85 s wait, 6.49 keeps it, 6.8 breaks it
again; above ~6.8 the Tool Wall + Glow Lamp pair passes $31 and the early cadence breaks), and a bisection
that treats failures as "too slow" can settle far from the target (it did: SCALE 1.14 / 2.8 min with an
earlier draft of these limits). Now the bisection matches the length alone and, if that SCALE breaks the
limits, a grid around it (x0.25 .. x1.25, 1 % steps) supplies the passing SCALE closest to the target.
`--tune --upto 1` today: SCALE **6.67** (7.1 min, 84 s; the pair at $31, right at its edge; Paint Station
7.1x the Mini Reactor); the file keeps the hand value 6.49 (round prices, steps <= 7x, $1 under the pair
limit).

### R122 — Uncle Atom is pad 4 ("automation by minute ~4", spec 2026-11-01 §2.2)

**Why:** live first-run data (Garage Lab, real minutes to each pad, n players): Workbench 1.0 (190), Tool Wall
2.5 (130), Glow Lamp 3.4 (104), Garage Door 4.1 (92), Mini Reactor 6.1 (63), Paint Station 9.9 (31), **Uncle Atom
11.1 (27)**, Driveway 11.4, Unlock 12.3 (25); tutorial `tut:6` 102 -> `tut:7` 27 (-74 %). Players hand-clicked the
Workbench for ~11 min before the first Manager. Roblox ranks on playtime per user and first-play bounce, and
automation is the idle-tycoon hook, so the first Manager moved right behind the Glow Lamp.

**New buy order:** Workbench -> Tool Wall -> Glow Lamp -> **Uncle Atom** -> Garage Door -> Mini Reactor -> Paint
Station -> Driveway -> Open the Nuke Stand (`requires` follows it; pad ids unchanged — old-order saves keep every
pad, see docs/tycoon-server.md "Garage Lab opening").

**Pacing (greedy sim player, `lune run tests/economy-sim.luau --timeline`, SCALE 6.49):**

| Pad | Multiple | Price | Sim min (gap) | Before R122 (price, min) |
|---|---|---|---|---|
| Workbench | 0 | free | 0.05 | free, 0.05 |
| Tool Wall | 6.5 | $42 | 1.1 (63 s) | $37, 1.0 |
| Glow Lamp | 40 | $260 | 1.6 (31 s) | $250, 1.6 |
| **Uncle Atom** (automatic from here) | 46 | **$300** | **1.9 (19 s)** | $17K, 5.9 |
| Garage Door | 52 | $340 | 2.5 (37 s) | $330, 2.3 |
| Mini Reactor | 450 | $2.9K | 3.9 (82 s) | $2K, 3.9 |
| Paint Station | 3,100 | $20K | 5.2 (80 s) | $13K, 5.3 |
| Driveway | 5,700 | $37K | 6.6 (83 s) | $19K, 6.7 |
| Open the Nuke Stand | 17,000 | $110K | **8.0** (83 s) | $56K, 7.5 |

Area 1 **8.0 min (+0 %)**, $1.42K/s at the Unlock (was $1.31K/s), Workbench lv 40; first Manager **1.93 min**
(limit 4.0), longest wait between pads **83 s** (limit 90; was 97 s before the Mini Reactor). The real-player
ratio of the old data (~1.9x the sim) puts Uncle Atom at roughly 3.5–4 real minutes instead of 11.

**How the multiples were chosen (by hand; the tuner only moves SCALE):** a greedy player decides by payback
(`cost / income + cost / gain`), and the decisions do not change under a uniform income lift (flavours,
lever, auto-serve), only under price ratios. Explored with a scratch harness around the sim (~2,000 runs):
* A **+10 % Build pad priced above the Workbench's level ~20 (~$355)** loses to the levels until the level-25
  milestone; after Uncle Atom that wait is ~95 s whatever Uncle Atom costs. So Glow Lamp / Uncle Atom / Garage
  Door sit close together (40 / 46 / 52 x SCALE, ~13 % steps) and the Garage Door stays under ~$355 at the
  tuned SCALE ($340; the flip happens at $360).
* That fixes the head (Workbench .. Garage Door) at ~2.5 min, so the remaining ~5.5 min are carried evenly by
  Mini Reactor / Paint Station / Driveway / Unlock (~80 s apart; the Unlock ~3x the Driveway as before).
* 8.0 min is the longest Garage Lab whose worst gap stays <= ~85 s with this head (an optimiser over all eight
  multiples found no 8.0-min layout below ~83 s); a 7.5-min area would get ~78 s gaps.
* Rejected: Uncle Atom later (~2.5 min) with the Garage Door after the milestone (94–97 s gap); on-curve
  designated levels for the new order (99 s gaps); a cheap Mini Reactor bundled with the Garage Door (a
  knife-edge between the bundle and the milestone; 90–97 s depending on SCALE).

**Sim assertions (tests/economy-sim.luau `OPENING_CHECKS`, Nuke Town area 1):** the greedy run-1 player hires
the first Manager by **4.0 min** and never waits more than **90 s** between two Garage Lab pads (counted from
the start, the free Workbench included; tightened by R137 to 1.5 min / 85 s + the 2-minute cadence, above). The run prints `Opening (area 1): first Manager at 1.93 min ...`.
The tuner honours the same limits: a SCALE whose run breaks them counts as "too slow", so
`--tune` settles on the closest SCALE that keeps the opening (e.g. with a Garage Door multiple of 60 it stops
at SCALE 5.91 / 7.6 min instead of breaking the 90 s gap). Re-pace the Garage Lab alone with
`lune run tests/economy-sim.luau --tune --write --upto 1` (this run: SCALE 5.62 -> **6.49**).

**Tutorial:** step 6 = `a1_uncle_atom` (direct pad, "Hire Uncle Atom - he makes nukes for you, even offline!"),
step 7 = the chain "Save up and open the Nuke Stand!" (docs/tycoon-server.md). Starter quest 3 "Hire your first
manager" is a state check, so it is usually already complete when it opens (claim at once). Garage Egg price
unchanged ($400: 40 x the pinned $10 level-1 upgrade).

### R64 + R65 — the click phase and the $10 first upgrade

Owner: *"when someone starts the game for the first time and buys the first little button, it already is
automatic ... you have to click 14 times"* (R64) and *"I'd make like the first upgrade $10"* (R65).

**The opening a new player gets (no passes):** step on the free Workbench pad -> the Workbench is built
**manual** (CLICK on its billboard; nothing runs or pays until clicked) -> each click runs one 1 s cycle and
pays **$1**, then the Workbench waits for the next click -> **10 clicks** (about 12 s) buy the first
upgrade for exactly **$10** -> levels cost $10, $12, $15, $18, $21, ... -> pads every minute or so ->
Uncle Atom (the Manager) makes it automatic at ~6 min (R65 numbers; since R122 at ~1.9 min, above).

| Sim (greedy player, 0.25 s click reaction) | Before (2026-10-30) | After R65 |
|---|---|---|
| Level 1 -> 2 | $14 (14 clicks) | **$10 (10 clicks)** |
| Tool Wall | 1.2 min, $29, lv 7 | 1.1 min, $37, lv 9 |
| Glow Lamp | 1.8 min, $200 | 1.7 min, $250 |
| Garage Door | 2.7 min, $260 | 2.5 min, $330 |
| Mini Reactor | 3.7 min, $1.6K | 4.2 min, $2K |
| Paint Station | 6.0 min, $11K | 5.6 min, $13K |
| Uncle Atom (automatic from here) | 6.6 min, $14K | 6.2 min, $17K |
| Driveway / Unlock | 7.3 / 8.0 min, $15K / $45K | 7.2 / 8.0 min, $19K / $56K |

**How (R65):** `Area01.luau` pins the Workbench `baseCost = FIRST_UPGRADE_COST` (10) instead of
`3 x SCALE`. Pinning `SCALE = 10/3` instead (keeping the whole area on one unit) made Garage Lab
5.9 min (-26 %, outside the +/-20 % gate), so the tuner re-measured SCALE with the pinned base:
**4.53 -> 5.62** (pads +24 %, area still 8.0 min). The pads therefore sit ~1.7x above the level-cost curve
(`3 x 5.62 / 10`): the greedy player takes ~2 more cheap levels before each pad — a snappier, upgrade-heavy
opening. `costGrowth`, `baseRevenue`, the cycle and every other area are unchanged; the tuner never rewrites
`FIRST_UPGRADE_COST` (it patches only the `local SCALE =` / `baseRevenue =` lines).
**Decision — areas 2..10 not re-tuned.** A full `--tune --write` would move every later SCALE +4..+8 % (area 2
269 -> 292, ...) to undo area 2's -4 % (arrival income $1.15K/s instead of $1.06K/s) and lands run 1 at 7:58;
leaving them gives 8:00 / 3:40 with every area inside +/-4 %, and no price outside Garage Lab changes for live
players. (So the next full retune will shift areas 2..10 by those few percent — expected.)
**Garage Egg follows the curve:** EggConfig prices an area egg at 40 x that producer's level-1 upgrade, so it
went **$560 -> $400** (bought right after the Garage Door, ~2.5 min in); docs/pets.md updated.

**Why it was automatic (R64, verified 2026-10-31):** nothing in the economy pre-grants a Manager (TycoonLogic,
the pad chain, the tutorial, New Player Mode all leave the Workbench manual — `tests/tycoon-logic.luau` walks
the whole chain and proves only a producer's own Manager pad ever automates it). The owner's account owns the
**AutoClicker** game pass: Roblox gives a game's creator every pass of the game
(`UserOwnsGamePassAsync(1586034782, AutoClicker)` = true in Studio). TycoonService ran the pass from the first
second of any fresh start, and the pass's advertised **"Toggle it any time"** did not exist, so the owner could
never see the click phase on their own account. **Fix:** a server-authoritative Settings toggle
`settings.autoClicker` (default ON for buyers; shown in Settings only to pass owners; New Player Mode owns no
passes; read live, no rejoin; each flip counted as analytics tycoon `autoClicker:<on|off>`) — `TycoonRules.autoClickerOn(ownsPass, setting)` decides, `SettingsService.Changed` re-evaluates
every world at once, and the manual-cycle tick is the pure `TycoonRules.manualStep` (pays a finished click
once, then idles; only the auto clicker chains). Tests: `tests/tycoon-server-logic.luau` (R64 section),
`tests/profile-logic.luau` (toggle). Studio proof (2026-10-31, `tools/qa/opening_check.py` ->
`docs/verification/opening/` + `opening.json`): the owner's real account reported AutoClicker owned; in New
Player Mode (pass unowned, empty profile) the bought Workbench sat idle for 6 s at $0 / CycleStart 0 /
NextCost $10; each of 10 clicks ran one cycle, paid exactly $1 and went idle (cash 1..10); the $10 upgrade
left $0, level 2, next $12; after Uncle Atom the Workbench ran by itself (+$28.8/s, +$144 in 5 s, no clicks). **To see the real first-time flow on the owner's account:** Admin -> Play as New Player, or
Settings -> Auto Clicker OFF.

### Snapshot refreshes (`tests/fixtures/EconomyMainSnapshot.luau`)

| Date | Request | Values changed (of 4,509) |
|------|---------|---------------------------|
| 2026-10-31 | R65 Workbench first upgrade $10 | 39: `area.1.producer.baseCost` 14 -> 10; the 8 Garage Lab pad costs (Tool Wall 29 -> 37, Glow Lamp 200 -> 250, Garage Door 260 -> 330, Mini Reactor 1,600 -> 2,000, Paint Station 11K -> 13K, Uncle Atom 14K -> 17K, Driveway 15K -> 19K, Unlock 45K -> 56K); 30 sampled Workbench upgrade prices (`logic.{manual,managed}.{1,25,50,400,999}.none.p1_workbench.{cost1,cost10,max.cost,max.n}`: every price x10/14 before rounding, e.g. level 1 cost1 14 -> 10, cost10 364 -> 260; max affordable at 1e30 +2 levels). No output, cycle, milestone, rebirth, offline or other-area value changed; Dino has no snapshot and its sim is unchanged (2:30 / 1:13). |
| 2026-11-01 | R122 Garage Lab order (Uncle Atom pad 4) + re-pace | 53: the area-1 pad table (`area.1.pad.2..9`: Tool Wall 37 -> 42, Glow Lamp 250 -> 260, then pads 4–7 swap id / name / kind / build / blurb / value / requires to Uncle Atom $300, Garage Door $340, Mini Reactor $2.9K, Paint Station $20K; Driveway 19K -> 37K and requires `a1_paint_station`; Unlock 56K -> 110K), `areaPads.1`, `padOrder.4..7`, `padIndex.*` of the four moved pads, `padsByTarget.p1_workbench`, `chain.3..6.next` and `chain.4..6.automated` (the Workbench is automated from chain step 4). Producer, level-cost, milestone, rebirth, offline and every other area's values unchanged. |
| 2026-11-01 | R130 BoomDash order (Dispatcher pad 4) + re-pace | 95: area 3 SCALE 22,100 -> 25,000 (`area.3.pad.*.cost`: HQ Shell 220K -> 250K, Scooter Rack 270K -> 300K, Scooters 990K -> 1.1M; pads 4–8 swap id / name / kind / build / blurb / value / requires to Dispatcher $1.8M, GPS $8.5M, Mobile App $16M, Delivery Van $50M, Parking Lot $150M; Dig the Mine 400M -> 450M and requires `a3_parking_lot`), `p3_boomdash` level costs (`logic.{manual,managed}.*.none.p3_boomdash.{cost1,cost10,max.*}`: baseCost = 3 x SCALE), `areaPads.3`, `padOrder.23..27`, `padIndex.*` of the five moved pads, `padsByTarget.p3_boomdash`, `chain.22..27.next` and `chain.23..27.automated` (the BoomDash is automated from chain step 23). baseRevenue, cycle, milestones, rebirth, offline and every other area's values unchanged. |
| 2026-11-01 | R137 Garage Lab first two minutes + Nuke Stand order (Cashier Bot pad 4) | 70: five Garage Lab pad costs (`area.1.pad.{2,3,6,7,8}.cost`: Tool Wall 42 -> 11, Glow Lamp 260 -> 19, Mini Reactor 2,900 -> 2,300, Paint Station 20K -> 16K, Driveway 37K -> 35K; Uncle Atom, Garage Door and the Unlock unchanged); the Nuke Stand pad table (`area.2.pad.4..8` swap id / name / kind / build / blurb / value / feature / requires to Cashier Bot $51K, Tip Jar $120K, Neon Sign $250K (StandRename), Cooler $860K, Picket Fence $1.2M; Picnic Tables 2.4M -> 2.1M and requires `a2_picket_fence`; Start BoomDash 7.3M -> 5.1M), `areaPads.2`, `padOrder.13..17`, `padIndex.*` of the five moved pads, `padsByTarget.p2_nuke_stand`, `chain.12..16.next`, `chain.13..16.automated` (the Nuke Stand is automated from chain step 13) and `chain.14.features` (StandRename one step later). SCALE 6.49 / 269, every producer value and level cost, milestones, rebirth, offline and every other area unchanged. |

## BoomDash order (owner R130, 2026-11-01)

**Why** (live first-run data 2026-11-01, docs/owner-requests.md R129 / R130; real minutes into the
run, buyers): Start BoomDash 14.5 (41) -> HQ Shell 14.9 (26) -> Scooter Rack 15.0 (26) -> Scooters 15.3
(25) -> GPS 15.4 (24) -> **Mobile App 17.9 (16)** -> Delivery Van 20.3 (9) -> Parking Lot 21.6 (6) ->
**Dispatcher 27.9 (5, after a 6:20 wait)** -> Dig the Mine 28.5 (4). The BoomDash was hand-clicked for
~13 min and the Mobile App cost 8.3x the GPS. Same treatment as R122's Garage Lab: the Manager comes
right after the first burst and the later pads are evenly spaced.

**New buy order:** HQ Shell -> Scooter Rack -> Scooters -> **Dispatcher** -> GPS -> Mobile App ->
Delivery Van -> Parking Lot -> Dig the Mine (pad ids unchanged; old-order saves keep every pad — see
docs/tycoon-server.md "BoomDash order", `tests/boomdash-order.luau`).

**Pacing (greedy sim player, run 1, `lune run tests/economy-sim.luau --timeline`; minutes after the
area opens):**

| Pad | Multiple | Price | Sim min (gap) | Before R130 (multiple, price, min) |
|---|---|---|---|---|
| HQ Shell | 10 | $250K | 0.2 | 10, $220K, 0.2 |
| Scooter Rack | 12 | $300K | 0.6 | 12, $270K, 0.5 |
| Scooters | 45 | $1.1M | 1.0 | 45, $990K, 0.9 |
| **Dispatcher** (automatic from here) | 70 | **$1.8M** | **1.7** | 6000, $130M, 18.2 |
| GPS | 340 | $8.5M | 5.4 (3.7 min) | 120, $2.7M, 2.3 |
| Mobile App | 650 | $16M | 9.6 (4.2 min) | 1000, $22M, 9.0 (6.7 min wait) |
| Delivery Van | 2000 | $50M | 14.0 (4.4 min) | 2400, $53M, 14.0 |
| Parking Lot | 6000 | $150M | 18.3 (4.3 min) | 2800, $62M, 16.6 |
| Dig the Mine | 18000 | $450M | **22.2** (3.9 min) | 18000, $400M, 22.1 |

(Without the Order Window lift, removed by owner R128; with it the area was 21.6 vs 21.4.) Area 3
**22.2 min (-11 % of 25)**, length unchanged; first Manager **1.7 min** (was 18.2); longest wait
**~4.4 min** (was 6.7); largest price step 4.9x (was 8.3x); Glow Rock Mine 29.6 min (-15 %, arrival
$1.94M/s at lv 37 instead of $1.74M/s at lv 33). Run 2 area 3: 9.3 min.

**How the multiples were chosen** (scratch harness around the real sim, ~3,600 runs: pad 4 =
Dispatcher fixed, the other multiples and SCALE varied): cheaper later pads alone shorten the area
below the -20 % floor (e.g. 16.9 min with GPS 200 / Mobile App 450 at SCALE 22,100), so SCALE rises
to 25,000 to keep today's ~22 min; with that length ~4.2 min is the smallest achievable longest wait
(five pads share the ~20 min after the Dispatcher). Among the layouts at that floor this one keeps the
Parking Lot / Unlock multiples (6000 / 18000, Unlock = 3x the pad before) and today's area length.

**Sim assertions** (`tests/economy-sim.luau` `OPENING_CHECKS`, now a list per world): Nuke Town area 3
hires its Manager by **3.0 min** and never waits more than **300 s** between two pads (the old order:
18.2 min / 402 s); the tuner honours the limits of the area it tunes. To re-pace area 3 alone, use a
scratch copy: `--tune --upto 3` also retunes area 2 (-18 % on purpose since R122) — never `--write`
that without an owner decision.

## Nuke Stand order (R137)

Owner R137, 2026-11-01 ("do whatever you want and fix"): the R130 BoomDash treatment for area 2.

**Why** (live first-run data 2026-11-01, docs/owner-requests.md R135–R137): 150 players opened the Nuke
Stand -> 102 bought the **Cashier Bot** (its Manager, **pad 8 of 10**, behind price jumps Tip Jar -> Neon
Sign **5.8x** and Picket Fence -> Cashier Bot **4x**) -> 82 opened BoomDash Delivery. In the sim the Nuke
Stand was hand-clicked for 6.5 min after the area opened.

**New buy order:** Counter -> Awning -> Cash Register -> **Cashier Bot** -> Tip Jar -> Neon Sign -> Cooler ->
Picket Fence -> Picnic Tables -> Start BoomDash (pad ids unchanged; old-order saves keep every pad — see
docs/tycoon-server.md "Nuke Stand order (R137)", `tests/stand-order.luau`).

**Pacing (greedy sim player, run 1, `lune run tests/economy-sim.luau --timeline`; minutes after the area
opens; SCALE 269 unchanged):**

| Pad | Multiple | Price | Sim min (gap) | Before R137 (multiple, price, min) |
|---|---|---|---|---|
| Counter | 10 | $2.7K | 0.12 | 10, $2.7K, 0.12 |
| Awning | 12 | $3.2K | 0.17 | 12, $3.2K, 0.17 |
| Cash Register | 45 | $12K | 0.31 | 45, $12K, 0.31 |
| **Cashier Bot** (automatic from here) | 190 | **$51K** | **0.85** | 6,000, $1.6M, 6.51 |
| Tip Jar | 460 | $120K | 2.28 (86 s) | 120, $32K, 0.72 |
| Neon Sign (+ sign rename) | 920 | $250K | 4.12 (110 s) | 700, $190K, 2.45 (5.9x step) |
| Cooler | 3,200 | $860K | 6.31 (131 s) | 1,200, $320K, 4.04 |
| Picket Fence | 4,600 | $1.2M | 8.29 (119 s) | 1,500, $400K, 5.27 |
| Picnic Tables | 7,700 | $2.1M | 10.32 (122 s) | 8,900, $2.4M, 9.37 |
| Start BoomDash | 19,000 | $5.1M | **12.53** (132 s) | 27,000, $7.3M, 12.53 (189 s) |

Area 2 **12.5 min (-16 % of 15) — length unchanged**; first Manager **0.85 min** after the area opens (was
6.5); longest wait **132 s** (was 189 s, both the save for the Unlock); largest price step **4.3x** (Cash
Register -> Cashier Bot; was 5.9x). Income at the Unlock **$38.6K/s at Nuke Stand lv 39 — unchanged**, so
BoomDash and every later area play exactly as before. SCALE stays **269**, so the Counter ($2.7K, = the
Front Tower's price), the Awning, the Cash Register, the Stand Egg (40 x the level-1 upgrade) and every Nuke
Stand level keep their prices.

**How the multiples were chosen** (scratch harness around the real sim, ~35,000 runs: pad 4 = Cashier Bot
fixed, the later multiples and SCALE varied; SCALE 249–330 gave no better layout than 269):
* The longest wait is the save for the Unlock (its price / the income at the Unlock, ~$38.6K/s). At the
  usual Unlock = 3x the pad before it, it stays at **155–170 s** however the other pads are priced; at ~2.5x
  it is 132 s with the area length kept, so the Unlock costs ~2.5x the Picnic Tables (documented exception).
* The Tip Jar / Neon Sign / Cooler (strong multipliers) are spread 1.5–2.2 min apart, the Cooler right
  after the level-25 milestone; the two +10 % pads (Picket Fence, Picnic Tables) fall at levels ~35 / ~39.
* Steps <= 5x everywhere (asserted in tests/stand-order.luau, which also proves the chain, the layout and
  old-order saves).

**Sim assertions** (`tests/economy-sim.luau` `OPENING_CHECKS`, area 2): the Cashier Bot by **2.0 min** after
the area opens and no wait above **150 s**. With these limits a full `--tune` (target 15 min) also keeps the
Nuke Stand at ~12.5 min (dry run: SCALE 324, baseRevenue 25): a longer area would break the 150 s wait.

## Gem upgrade (owner R86, 2026-10-31)

Owner: "add a button on like the GUI to also just buy for gems, like just buy the next upgrade with
gems, but it stays at the same price for everything ... probably like 1,000 gems ... whatever you
think is reasonable." One press = exactly ONE producer level for a flat gem price
(`TycoonConfig.GemUpgradePrice`): every producer, level and world. Admin-adjustable per server
(Economy tab → "Gem upgrade price", 1..10,000 gems, on/off; `Server/Tycoon/GemUpgradeSettings`).

**Price: 75 gems.** The lead proposed 25 with a rule: raise it if a few thousand gems skip area 1.
Measured with a scratch copy of the real simulator (`tests/economy-sim.luau` with N levels added to
an area's producer the moment its builder pad is bought; run 1, no Robux otherwise):

| Gem levels | Area 1 Garage Lab (8 min) | Area 9 Space Port (80 min) | Whole run (8:00) |
|-----------|---------------------------|----------------------------|------------------|
| 0 | 8.0 | 79.7 | 8:00 |
| 10 | 6.9 | – | 7:59 |
| 15 | 6.4 | 74.2 | 7:59 / 7:55 |
| 20 | 5.6 | – | 7:58 |
| 25 | – | 57.6 | 7:38 |
| 30 | 3.9 | 51.0 | 7:56 / 7:32 |
| 40 | 2.9 | 39.7 | 7:55 / 7:17 |
| 60 | 1.4 | 15.3 | 7:49 / 6:37 |
| 120 | 0.6 | 2.8 | 7:40 / 5:49 |

A flat price on a ×1.2-per-level cost curve is convex: a few levels are mild, a stockpile pushes a
producer far past the cash frontier (+1 milestone doubling per 25 levels). At 25 gems, 3,000 gems =
120 levels: Garage Lab in 0.6 min and a whole 80-minute late area erased; that is the lead's
"visibly breaks pacing" bar. At **75**: 3,000 gems = 40 levels (Garage Lab 8 → 2.9 min, Space Port
80 → 40 min: halved, never skipped), a 1,000-gem pack (399 R$) = 13 levels (about −15 %), and free
play (~70–100 gems / day) ≈ one gem level a day. For payers this is still weaker per Robux than the
cash packs (29 R$ = 10 min of income; a gem level ≈ 1 min of late-area time ≈ 30 R$ of gems), so it
never undercuts them. Gem levels are ordinary levels: a rebirth resets them like cash levels.
`tests/gem-upgrade.luau` guards "3,000 gems ≤ 40 levels" at the shipped price.

Economy analytics: spends book as `spend:gems:GemUpgrade` (Roblox economy Sink, transaction type
Shop); the tycoon family counts `upgradeMode:gem`.

## Surprise Batches — flavour luck in the core loop (owner R89, F-flavors, 2026-10-31)

Every finished batch (one producer cycle, clicked or automated) rolls a flavour on the server
(`Server/Tycoon/FlavorService`, maths in `Shared/Tycoon/FlavorLogic`, numbers in
`Shared/Config/FlavorConfig`; full system doc `docs/flavors.md`). Plain pays the batch once; a special
flavour pays `mult` × the batch (the bonus `perCycle × (mult − 1)` joins that producer's payout in
`TycoonService.tickRuntime`).

| Flavour | Odds per batch | Payout | Book reward (per world) |
|---------|----------------|--------|-------------------------|
| Plain | the rest (~93.5 %) | x1 | — |
| Sprinkle | 1 in 20 | x1.5 | 5 gems |
| Glitter | 1 in 100 | x3 | 10 gems |
| Rainbow | 1 in 500 | x5 | 25 gems (+ producer glow) |
| Galaxy | 1 in 2,500 | x20 | 60 gems (+ reveal + Big Pop) |
| Mystery Pop | 1 in 25,000 | x100 | 150 gems (+ reveal + Big Pop) |

**Average income lift** = Σ p × (mult − 1) = **+6.46 %** at luck 1. Luck (Happy Hours' Sprinkle Surge ×
admin odds) multiplies every special chance; the time-weighted Happy Hour luck is ~1.042 (the ×1.5 mini surge
3 min at :30 every hour + the ×2 headline 5 min every 5th hour, `HappyHourConfig`), so the simulator assumes
`FlavorConfig.PacingLuck = 1.1` (conservative, covers admin force-starts): **+7.1 %**.
`tests/flavor-logic.luau` caps this at `FlavorConfig.MaxPacingLift` (8 %).

**How the pacing contains it.** `tests/economy-sim.luau` multiplies every producer's income (clicked and
automated) by `FlavorLogic.expectedMultiplier(PacingLuck)` — the average a player earns over many batches —
so the asserted pacing already includes the flavour lift (`--no-flavor` drops it for a comparison; `--tune`
tunes WITH it). Tuning rule (lead): re-tune odds / multipliers in FlavorConfig, never the areas.

Tuning history (sim, Nuke Town run 1, target 8:00):

| Set | Lift @ pacing luck | Run 1 | Worst area |
|-----|--------------------|-------|------------|
| no flavours (before R89) | 0 % | 8:00 | Nuke Stand -4 % |
| x2 / x4 / x10 / x25 / x100 (first draft) | +12.3 % | 7:08 | Nuke Stand -14 % |
| **x1.5 / x3 / x5 / x20 / x100 (shipped)** | **+7.1 %** | **7:29** | **Nuke Stand -10 %** |

Shipped pacing (every area inside +/-20 %): Nuke Town 7.5 / 13.5 / 23.4 / 32.5 / 43.4 / 46.9 / 56.8 / 66.0 /
74.5 / 84.4 min (-4 .. -10 %), run 2 3:25 (54 % faster); Dino Valley and Moon Base 2:21 (-6 / -7 % per area),
run 2 1:08 (52 % faster). The common flavours carry the lift (Sprinkle alone +2.5 %); the rare ones are the
excitement (a Galaxy is 20 batches at once). Offline earnings do NOT roll flavours (online play pays a little
more); the Lucky Button / Cash pack "N seconds of income" amounts use the unflavoured income.

Aggregate rolling keeps the server cheap: up to 24 finished cycles roll one by one; more (automated producers at
the 0.1 s cycle floor, a hitch catch-up of up to 5,000) roll as one multinomial — one binomial per flavour
(inversion while the mean is < 15, else a clamped normal approximation): at most ~10 random draws per producer
per tick whatever the cycle count (`tests/flavor-logic.luau` proves the bound + the distribution).

## Mega Lever + Tip Jar — hands-on bonuses (owner R90, K-kinetic, 2026-10-31)

Two optional plot props (`Shared/Config/KineticConfig`, maths in `Shared/Tycoon/KineticLogic`,
system doc `docs/kinetic.md`), both appearing at Area 2 (`UnlockArea`) in every world:

| Prop | Payout | Rate limit | Bound |
|------|--------|------------|-------|
| Mega Lever | every built producer completes ONE bonus cycle worth `CycleMultiplier` = 10 cycles; the whole pull payout clamped to **12–24 s** of the plot's production rate (Σ perCycle / cycle); each bonus cycle rolls a flavour (FlavorService.batch) | one pull per **600 s** per world (saved unix `readyAt`) | ceiling 24 s × flavour |
| Tip Jar | fills at **2 %** of idle income per second while online, in that world, near the plot; holds **20 min** of filling (= 24 s of income); walk in / prompt pays it | payout needs ≥ 5 % of the cap (or bonus tips from `TipJar.addCoins`; none since R128) | hard ceiling 180 s of income per payout; tips bucket ≤ 120 s |

**How the pacing contains it.** `tests/economy-sim.luau` multiplies every producer's income by
`1 + KineticLogic.pacingLift(flavour lift)` once the simulated player's home area reaches Area 2
(Area 1, all manual, is untouched). The lift is deliberately conservative — a pull EVERY cooldown at
the 24 s CEILING (× the +7.1 % flavour lift) plus the jar filling ALL the time:
`24 / 600 × 1.071 + 0.02` = **+6.3 %** (`KineticConfig.Pacing.MaxLift` caps it at 6.5 %;
`tests/kinetic-logic.luau` + the simulator assert it). Real players pull less often and land between
the 12 s floor and the ceiling, so the real lift is lower. `--no-kinetic` drops it for a comparison.
Grant reasons: `megaLever`, `tipJar` (economy family "earn" rows). Rebirth empties that world's jar
(old-run currency); the lever cooldown survives it. Tuning rule: retune KineticConfig, never the areas.

| Set | Lift | Nuke Town run 1 | Worst area | Dino / Moon run 1 |
|-----|------|-----------------|------------|-------------------|
| before R90 | 0 % | 7:29 | Nuke Stand -10 % | 2:21 |
| **shipped (x10, 12–24 s, 600 s, 2 % / 20 min)** | **+6.3 %** | **7:03** | **Nuke Stand -15 %** | **2:13 (-12 %)** |

Run 2 stays clearly faster (Nuke Town 3:14, 54 % faster; Dino / Moon 1:04). Budget note for later
bonus systems: the worst area has ~4 points of tolerance left (the Order Window that used it was
removed by owner R128).

## Order Window tips — RETIRED (owner R128, 0.8.1)

Owner R128 removed the R90 Order Window (`docs/orders.md`), so its hand-served tips, Customer Fame
gems and the R115 Cashier Bot auto-serve lift are gone; the Cashier Bot stays a normal Area 2
manager. `tests/economy-sim.luau` no longer applies the +2.8 % auto-serve lift (`--no-orders` is
gone). Result (2026-11-01): Nuke Town run 1 **7:03** (was 6:52 with the lift), worst area **Nuke
Stand -16 %** (tolerance ±20 %), others -9…-15 %; Dino / Moon run 1 **2:13**; every world green.
Grant reasons `orderTip` / `orderAuto` / `orderFame` no longer occur (old days' economy rows keep them).

## Rebirth shop (RebirthConfig.Shop)

| Key (save data) | Name | Effect / level | Max | Cost (tokens) |
|-----------------|------|----------------|-----|---------------|
| `clickPower` | Power Production | +10 % cash on every cycle (clicked and automated) | 10 | 3 x 1.45^L |
| `managerSpeed` | Speedy Managers | +10 % automated speed | 10 | 3 x 1.5^L |
| `startingCash` | Head Start | $1K / $250K / $50M / $10B / $2.5T start | 5 | 4 x 2.2^L |
| `offlineHours` | Night Shift | +1.5 h offline cap (3 h -> 24 h) | 14 | 2 x 1.35^L |
| `offlineRate` | Sleepy Reactor | +5 % offline rate (50 % -> 100 %) | 10 | 2 x 1.4^L |
| `rebirthPower` | Golden Atoms | +5 % per-rebirth bonus | 10 | 5 x 1.6^L |
| `petSlots` | Pet Backpack | +1 pet slot | 2 | 15 x 3^L |

Everything maxed costs ~2,260 tokens (~20+ rebirths at a growing ~35–80 tokens each).

## Retuning

1. **Change a pacing target**: edit `TycoonConfig.Pacing.TargetMinutes`, then
   `lune run tests/economy-sim.luau --tune --write` (≈10 s). It re-measures each area in order and rewrites
   `local SCALE = ...` and the producer's `baseRevenue = ...` in every `AreaNN.luau`. Re-run
   `lune run tests/economy-sim.luau` (and `--timeline` to eyeball pad spacing), then `stylua` the area files.
2. **Change a pad price by hand**: edit its SCALE multiple, then re-run the tuner (later areas shift).
   `--upto <n>` tunes and writes only areas 1..n (R122 re-paced the Garage Lab alone: `--tune --write --upto 1`).
   In an `OPENING_CHECKS` area (Garage Lab, Nuke Stand, BoomDash) the tuner never picks a SCALE that breaks the
   opening limits (since R137 via a SCALE grid, not the bisection — the limits are not monotone in SCALE); if it
   lands short of the target, the hand multiples need reshaping (see "Garage Lab opening" R122 / R137).
3. **Change `costGrowth`, the level-1 base cost or the designated levels**: re-derive every pad multiple with the
   formula in "Pricing structure" (keep prices rising along the chain), then run the tuner.
4. **Bigger / smaller numbers overall**: `SIM.StartFraction` (new producer = 1 % of arrival income) mostly sets
   how much income grows per area and therefore the final cash scale; lower = smaller numbers. Re-tune after.
5. **Rebirth speed-up**: `RebirthConfig.BonusPerRebirth` (spec: 0.5), token formula, shop `perLevel` values;
   the sim asserts run 2 <= 85 % of run 1 (`SIM.Run2MaxFraction`).
6. **Never** rename pad / producer ids or shop keys (save data). Adding a pad mid-chain is safe for saves only
   if you also migrate profiles that own the pads after it (they would otherwise skip it — `nextPads` will show
   it again, which is acceptable).

## Build keys (world builders, B5/B8)

`pad.build` names the build group to spawn when the pad is bought. The Unlock pad of area N builds
`A{N+1}_EntryArch` (the next area's entry arch, suggest + its base floor so the new area visibly appears).

* A1: Workbench, ToolWall, GlowLamp, GarageDoor, MiniReactor, PaintStation, UncleAtom, Driveway, A2_EntryArch
* A2: Counter, Awning, CashRegister, TipJar, NeonSign, Cooler, PicketFence, CashierBot, PicnicTables, A3_EntryArch
* A3: HQShell, ScooterRack, Scooters, GPS, MobileApp, DeliveryVan, ParkingLot, Dispatcher, A4_EntryArch
* A4: MineEntrance, SupportBeams, PickaxeCrew, CartTrack, DrillRig, CrystalLamps, GlowVein, Foreman, A5_EntryArch
* A5: LabShell, CleanRoomFloor, Centrifuges, LabCoats, ComputerWall, GlowVats, SafetySigns, HeadScientist, A6_EntryArch
* A6: FactoryShell, Conveyor, RobotArms, FinPress, PaintBooth, QualityCheck, Forklift, LoadingDock, FactoryBoss, A7_EntryArch
* A7: SiloPad, Silo2, Silo3, RadarDish, ControlRoom, HazardFloor, LaunchDirector, AATower, AttackConsole, A8_EntryArch
* A8: Storefront, Shelves, Escalators, MascotNukey, Billboard, FoodCourt, ParkingGarage, StoreManager, A9_EntryArch
* A9: LaunchPad, FuelTanks, MissionControl, BoosterRockets, SatelliteDish, AstronautCrew, SpaceElevator, FlightDirector, A10_EntryArch
* A10: ReactorDome, CoolingTower, CoolingTower2, TurbineHall, PowerLines, ControlTower, FusionCore, ChiefEngineer, GoldenAtom

(Full key = `A{area}_{Name}`, e.g. `A4_GlowVein`. The first key of each area also builds the producer model;
Manager keys are the manager NPC/robot.)

## Open design notes

* The Auto Clicker pass starts manual cycles itself and pays `clickValue` (it is "clicking") while the
  player's Settings toggle `autoClicker` is ON (R64: `TycoonRules.autoClickerOn` / `manualStep`).
* Offline earnings use idle income only; whether timed boosts apply offline is the server's call.

## Worlds framework + Dino Valley economy (W1 worlds-logic, 2026-10-31)

Spec: `docs/superpowers/specs/2026-10-31-world2-design.md` §6; plan `docs/superpowers/plans/2026-10-31-world2-build.md`
§3.1 / §4 W1. Framework overview + "add World 3" checklist: `docs/worlds.md`.

### What changed (Nuke Town behaviour and numbers unchanged)

| File | What |
|------|------|
| `src/shared/Tycoon/EconomyIndex.luau` | **New.** `build(spec)` = the old `TycoonConfig.buildIndexes`, generalised per world (validation, friendly prices, deep freeze) + id-prefix rules + `BuildKeys`; `friendlyPrice` moved here (TycoonConfig re-exports it) |
| `src/shared/Config/TycoonConfig.luau` | Built through `EconomyIndex.build({ worldId = "main", idPrefix = "" })`; same public fields (same table refs) + `Index`, `WorldId`, `Tunables` (the shared tunables every world uses) |
| `src/shared/Tycoon/TycoonLogic.luau` | `bind(index, rebirthDef) -> Logic` (every function as a closure over one world) and `forWorld(id)` (cached; lazily requires WorldsConfig). The module-level functions ARE main's Logic |
| `src/shared/Tycoon/Modifiers.luau` | Optional trailing `rebirth: RebirthDef?` on `resolve` / `rebirthMultiplier` / `shopLevel` / `shopEffect`; new `linkCash` modifier (>= 1, clamped like every bonus); `ResolvedModifiers.link` |
| `src/shared/Tycoon/TycoonTypes.luau` | `EconomySpec`, `EconomyIndex`, `EconomyTunables`, `PacingTargets`, `ShopUpgrade`, `RebirthDef`, `Modifiers.linkCash` |
| `src/shared/Config/RebirthConfig.luau` | Re-exports `ShopUpgrade` / `RebirthDef`; `RebirthConfig.validate(def, name)` checks + freezes any world's track |
| `src/shared/Config/Worlds/Dino/{DinoWorld, DinoRebirth, Areas/Area01..06}.luau` | **New.** The Dino economy (59 pads) and the Amber track |
| `tests/economy-index.luau` + `tests/fixtures/EconomyMainSnapshot.luau` | **New.** Bit-identical parity of the main economy (4,509 values: every config field + sampled TycoonLogic results) + every validation rule |
| `tests/tycoon-logic.luau` | + the world-generic suite (contracts, hostile input, chain walk, rebirth on the world's own track, `linkCash`, monotonicity incl. link + Amber variants) per world: 6,338 checks |
| `tests/economy-sim.luau` | `--world <id>`; with no argument it simulates EVERY world (main first) |

**Parity proof:** `lune run tests/economy-index.luau` compares the main economy with the snapshot taken from the
pre-framework sources (generated by running the same collector against `git archive HEAD` of 8ff9018). After an
**intentional** Nuke Town retune, refresh it with `lune run tests/economy-index.luau --update-snapshot` and say so in
the commit; never refresh it to silence an unexplained diff.

### Dino Valley pricing

Exactly the Nuke Town structure ("Pricing structure" above): `costGrowth` 1.2, builder = 10 x SCALE, level 1 -> 2 =
3 x SCALE, pads on the level-cost curve at designated levels, Manager on the 25 slot (D1: Rocky Raptor at 22 like
Uncle Atom), prices forced to rise >= 15 %, Unlock = 3 x the pad before. Designated levels for pads 2..:

| Area | Levels (pad 2 ..) | Notes |
|------|-------------------|-------|
| D1 Cave Workshop | 3, 6, 9, 13, 18, Mgr 22, 25 | Garage Lab pattern; free Stone Bench |
| D2 Fern Market | 3, 6, 9, 13, 18, 22, Mgr 25, 30 | Nuke Stand pattern |
| D3 Ptero Post | 3, 6, 9, 13, 18 (Treasure Map x4), 22, Mgr 25 | Landing Pad forced to 4,200 (rise rule) |
| D4 Geyser Springs | 3, 6, 9, 13, 18, 20 (Mega Geyser x4), Mgr 25, 30 | Para Pete forced to 6,700 |
| D5 Fossil Lab | 3, 6, 9, 13, 18, 22, Mgr 25, 30 | |
| D6 Volcano Reactor | 3, 6, 9, 13, 16, 18, 20, 22 (Obsidian Crown x5), Mgr 25 | Area 10 pattern: Chief Tyra 14,000, statue 42,000 |

### Achieved pacing (2026-10-31, `lune run tests/economy-sim.luau --world dino`)

Run 1 (first Dino run, no Robux, no pets / passes / link) — asserted within +/-20 % of spec §6.3:

| # | Area | Target min | Sim min | Dev | Cumulative | Unlock cost (Bones) | Bones/s at unlock | Producer lv |
|---|------|-----------|---------|-----|-----------|---------------------|-------------------|-------------|
| D1 | Cave Workshop | 10 | 9.9 | -1 % | 0:10 | 65K | 1.09K | 35 |
| D2 | Fern Market | 18 | 18.0 | -0 % | 0:28 | 5.4M | 20.1K | 40 |
| D3 | Ptero Post | 24 | 23.9 | -0 % | 0:52 | 210M | 953K | 35 |
| D4 | Geyser Springs | 28 | 28.2 | +1 % | 1:20 | 12B | 53.3M | 39 |
| D5 | Fossil Lab | 32 | 32.1 | +0 % | 1:52 | 710B | 1.52B | 39 |
| D6 | Volcano Reactor | 38 | 38.2 | +1 % | 2:30 | 46T (Golden T-Rex) | 171B | 34 |

Total **2:30** (150.4 min); lifetime Bones **89.4T**; final idle income **171B/s**. Tuned values (written by
`--world dino --tune --write`): SCALE 6.15 / 201 / 11,400 / 452,000 / 2.62e7 / 1.09e9, baseRevenue 1 / 19 / 450 /
26,000 / 2e6 / 8e7.

Run 2 after one Dino rebirth (x1.50 Bones, 20 Amber -> Mighty Roar 2, Speedy Raptors 2, Bone Stash 1; starts with
65K Bones): **1:13, 52 % faster** (spec: <= 85 % of run 1).

**Decision — number scale.** The spec says both "each area multiplies income ~x30–50" and "the finale sits in the
low billions". With the mandated Nuke Town pricing structure those two cannot both hold for the finale's *price*
(a finale costs ~1,000 s of final income, like Nuke Town's $97Qi vs $90Qa/s). We kept the structure: income is in the
low billions when the finale area opens (1.5B/s), the finale statue costs 46T. Still a fresh climb, visibly separate
from Nuke Town's Qi. `SCALE_CHECKS.dino` in the sim asserts a finale price in 1e8..1e14 and >= 1e9 lifetime Bones.

### Amber shop (`Worlds/Dino/DinoRebirth`, keys are SAVE DATA in `worlds.dino.rebirthShop`)

| Key | Name | Effect / level | Max | Cost (Amber) |
|-----|------|----------------|-----|--------------|
| `clickPower` | Mighty Roar | +10 % Bones on every cycle (clicked + automated) | 10 | 3 x 1.45^L |
| `managerSpeed` | Speedy Raptors | +10 % automated speed | 10 | 3 x 1.5^L |
| `startingCash` | Bone Stash | 65K / 5.4M / 210M / 12B start (= the Unlock prices of D1..D4) | 4 | 4 x 2.2^L |
| `rebirthPower` | Golden Amber | +5 % per-Dino-rebirth bonus | 10 | 5 x 1.6^L |

Amber = `floor((10 + totalLevels / 25) x (1 + 0.1 x dinoRebirthsSoFar))`; Bones multiplier
`1 + (0.5 + 0.05 x goldenAmber) x dinoRebirths`. Offline cap / rate stay player-level (Nuke Town's Night Shift /
Sleepy Reactor; `Logic.offlineLimits` on every world reads the main shop keys). The tuner rewrites the one-line
`local STASH_VALUES = { ... }` in `DinoRebirth.luau` with the tuned Unlock prices.

### Cross-world link (`linkCash`, spec §6.5)

`WorldsConfig.linkCash(worldId, rebirthsByWorld)` -> the world's `Modifiers.linkCash`:
Nuke Town `1 + 0.10 x min(dinoRebirths, 20)` (max x3.0), Dino `1 + 0.05 x min(mainRebirths, 10)` (max x1.5).
Pure, monotonic, hostile counts count 0. It is the LAST factor of `resolved.cash`, so a neutral link (1) leaves
every main number bit-identical. The sim's player has no link (veterans arrive faster on purpose).

### Retuning Dino

`lune run tests/economy-sim.luau --world dino --tune --write`, then `lune run tests/economy-sim.luau` (all worlds),
`lune run tests/worlds-config.luau` (Bone Stash = Unlock prices) and `stylua` the area files. Pad multiples follow the
table above; never rename `d*` / `dp*` ids or Amber shop keys (save data).

## Moon Base economy (W1 worlds-logic, R70 World 3, 2026-10-31)

Spec: `docs/superpowers/specs/2026-10-31-r69-moon-lucky-juice-design.md` §2.1 / §2.2 / §2.6. Files:
`src/shared/Config/Worlds/Moon/{MoonWorld, MoonRebirth, Areas/Area01..06}.luau` (idPrefix `m`: pads `m<N>_`,
producers `mp<N>_`, build keys `M<N>_`; ids are SAVE DATA). Pad kinds, values and SCALE multiples mirror Dino Valley
pad-for-pad (tests/worlds-config asserts it), so the pricing table in the Dino section above applies unchanged.

### Achieved pacing (`lune run tests/economy-sim.luau --world moon`)

| # | Area | Target min | Sim min | Dev | Cumulative | Unlock cost (Moon Rocks) | Rocks/s at unlock | Producer lv |
|---|------|-----------|---------|-----|-----------|--------------------------|-------------------|-------------|
| M1 | Crater Camp | 10 | 9.9 | -1 % | 0:10 | 65K | 1.09K | 35 |
| M2 | Cosmic Diner | 18 | 18.0 | -0 % | 0:28 | 5.4M | 20.1K | 40 |
| M3 | UFO Delivery | 24 | 23.9 | -0 % | 0:52 | 210M | 953K | 35 |
| M4 | Asteroid Mine | 28 | 28.2 | +1 % | 1:20 | 12B | 53.3M | 39 |
| M5 | Star Lab | 32 | 32.1 | +0 % | 1:52 | 710B | 1.52B | 39 |
| M6 | Star Reactor | 38 | 38.2 | +1 % | 2:30 | 46T (Golden Astronaut) | 171B | 34 |

Total **2:30** (150.4 min); run 2 after one Moon rebirth (x1.50, 20 Star Shards -> Rocket Fuel 2, Turbo Bots 2,
Rock Stash 1; starts with 65K Moon Rocks): **1:13, 52 % faster** (spec: <= 85 %). The tuner (`--world moon --tune
--write`) reproduced Dino's values exactly — same structure, same targets: SCALE 6.15 / 201 / 11,400 / 452,000 /
2.62e7 / 1.09e9, baseRevenue 1 / 19 / 450 / 26,000 / 2e6 / 8e7, Rock Stash { 65K, 5.4M, 210M, 12B }.
`SCALE_CHECKS.moon` = Dino's (finale 1e8..1e14, >= 1e9 lifetime).

### Star Shard shop (`Worlds/Moon/MoonRebirth`, keys SAVE DATA in `worlds.moon.rebirthShop`)

| Key | Name | Effect / level | Max | Cost (Star Shards) |
|-----|------|----------------|-----|--------------------|
| `clickPower` | Rocket Fuel | +10 % Moon Rocks on every cycle | 10 | 3 x 1.45^L |
| `managerSpeed` | Turbo Bots | +10 % automated speed | 10 | 3 x 1.5^L |
| `startingCash` | Rock Stash | 65K / 5.4M / 210M / 12B start (= the Unlock prices of M1..M4) | 4 | 4 x 2.2^L |
| `rebirthPower` | Supernova | +5 % per-Moon-rebirth bonus | 10 | 5 x 1.6^L |

### Link with three worlds

`WorldsConfig.linkCash("main", ...)` SUMS every world's link: `1 + 0.10 x min(dino, 20) + 0.10 x min(moon, 20)`
(up to x5.0). Each extra world's own link counts only Nuke Town's rebirths (`1 + 0.05 x min(main, 10)`), never
another extra world's. Tested in tests/worlds-config ("three-world link maths") and tests/tycoon-logic.

### Products (MonetizationConfig, category `moon`; live 2026-10-31 via tools/monetization/publish.py)

| Key | Kind | R$ | Grant | Id |
|-----|------|---:|-------|----|
| MoonRocksSmall "Bag of Moon Rocks" | WorldCash (moon) | 29 | 10 min Moon income, floor 500 | 3724649324 |
| MoonRocksMedium "Sack of Moon Rocks" | WorldCash | 79 | 30 min, floor 5K | 3724649274 |
| MoonRocksLarge "Crate of Moon Rocks" | WorldCash | 199 | 2 h, floor 50K | 3724649223 |
| AstronautPack "Astronaut Pack" | WorldStarter (one-time) | 99 | 20 min Moon income (floor 2K) + Rocket Corgi (`rocket_corgi`) + 30 min 2x Cash | 3724649081 |

Moon Rocks are Robux-reachable, so `MonetizationConfig.robuxWorldCurrencies()` includes `moonrocks` by itself and
Moon eggs bought with Moon Rocks are gated (`EggConfig.PaidRandomCurrencies.moonrocks`, W11; tests/validate).
