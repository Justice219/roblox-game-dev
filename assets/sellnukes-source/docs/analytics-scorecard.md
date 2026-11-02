# SellNukes analytics scorecard and decision rules

How to read the analytics report and decide changes (adapted from RoBeasts'
`docs/analytics-scorecard.md`). Mechanics and every key: [`analytics.md`](analytics.md).
All days are **UTC**. A window that includes today is provisional (servers flush every minute).
`partial: false` describes storage reads, not a closed day.

## Baseline

First live baseline (owner R122, read 2026-11-01 from `SellNukesAnalytics_v1`, read-only through
Studio; spec `docs/superpowers/specs/2026-11-01-r122-algorithm-pack-design.md` §1). **10-31** is a
closed UTC day on build 0.5.1; **11-01** is PARTIAL (00–07 UTC only, build 0.7.1) — provisional,
never compare it with a closed day as if complete.

| Signal | 10-31 (closed, 0.5.1) | 11-01 (partial, 0.7.1) | How it is read |
|---|---|---|---|
| New players / DAU | 232 / 234 | 150 / 157 | `new` / `dau`: almost no returning players |
| First sessions under 2 min | 100 / 232 (43 %) | 59 / 150 (39 %) | `ftueLen:<2m` / `ftue:joined` — the closest pre-R122 bucket to Roblox's < 60 s / < 180 s bounce (`rbx:bounce:*` from 0.8.0) |
| Left right after the plot loaded (no pad) | 46 (20 %; console 25 %) | 21 (14 %) | `ftueLeft:plotReady` (`ftueDev:console:plotReady`) |
| Client boot (loading screen) avg | phone 1.6 s, console 0.9 s | phone 26 s, tablet 20 s, desktop 21 s, console 15 s | `cp:<Class>:boot*`; 45 of 71 phone boots in 30–45 s = the old 30 s asset budget (11-01 players had far higher ping) |
| Playtime per DAU | 7.6 min | 6.3 min | `sessionSeconds / 60 / dau` (uncapped; Roblox credits up to 60 min/day) |
| Tutorial step 6 → 7 | 102 → 27 (−74 %) | 87 → 25 (−71 %) | `tut:6` → `tut:7` (Glow Lamp → Uncle Atom, the first manager) |
| First manager | avg first-run minute 11.1 | 8.2 | `ftueMin:manager / ftue:manager`; 9 pads in, all income by hand until then |
| D1 | r1 = 5 of 232 (≈ 2 %) | — (return day not reached) | `r1` / previous day's `new` (carry-adjusted: `(r1 - r1:carry + r1:carryRejoin) / new`) |
| Sessions with no friend in the server | 252 / 266 | 178 / 181 | `friendsIn:0` / sessions; the Friends screen was opened once in two days |
| Purchases | 0 of ~120 prompts | 0 of ~70 | `purchases` / `prompt:*`; `promptDwell:*:lt2` dominates (walk-in Lucky Button prompts, console shop prompts closed in < 2 s) |
| Notification opt-ins | 24 | 13 | `notify:accepted`; no notification was ever sent before 0.8.0 |
| Data quality | — | `ops:clientRefused:FunnelStep` = 87 | reason unknown before 0.8.0 (one key for every refusal; now split by `:<reason>`) |

Gross Robux is not net earnings. Read the 0.8.0 effect on the `build:0.8.0:*` slices and the
Roblox algorithm scorecard (below), never by calendar alone.

## Measurement contract

| Decision | Primary unit and denominator | Slices and guardrails |
|---|---|---|
| First minutes (tutorial area) | `ftue:<step>` / `ftue:joined` (once per tracked new player) | `ftueS1:<step>` (session 1 share), `ftueMin` / `ftueAt` (minutes), `ftueLeft:<step>` (where first sessions end), device (`ftueDev`), build (`build:*:ftue:*`) |
| Automation lesson | `ftue:manager` / `ftue:firstClick` | Clicks before automation (`click:p1_workbench`), time between `firstUpgrade` and `manager` (`ftueMin`) |
| Run pacing | First-run minutes to area n = `areaAt:n / areaN:n / 60` vs the cumulative `TycoonConfig.Pacing` target | Survivorship: later areas only include players who got there; compare `areaB:<n>:<bucket>` distributions, not only means |
| Economy stalls | "Slowest pads" gap (first-run seconds between consecutive pads) | Pad cost, producer income share (`income:auto` vs `income:click`), offline share, Skip Pad use (`padSkip:*`) |
| Session depth | Median session (`len:*`), sessions per player (`sessNo:*`) | Device, hour, `leaveArea:<n>` (where players stop) |
| Returns | D1 / D7 joins / exact cohort; carry-adjusted D1 | `r1:<milestone>` vs cohort (correlation, not cause), `r<N>:notify`, `devR1:<class>` / `devNew:<class>` of the day before |
| Purchases | Durable purchase / eligible prompt or impression | `funnel:<key>:shown → click → prompt → bought`, `purchase:<key>:<source>`, device, tycoon area, rebirth tier; `promptClosed*` + dwell for accidental prompts |
| Retention systems | Unique users per day (`uniq:<surface>`) / DAU | Daily streak depth (`daily:claim:<n>`), wheel free vs paid, code failures, Welcome Back DOUBLE share |
| Pets / crates / attack / event | Opens, hatches, launches per unique user | Rarity distribution vs configured odds, intercept rate, refusals by reason |
| Performance | Server: p95 frame, laggy minutes, Luau ms per system, remote KB/s; client: fps / memory by device | Compare matched builds (`build:*`) and device classes; ≥ 3 reports per class per row |
| Roblox ranking signals (R122) | The "Roblox algorithm scorecard" rows: `rbx:bounce:lt60` and `rbx:bounce:60to180` / Σ `rbx:bounceDev:*` (R135; was `ftue:joined`); play days D1 (`r1` / cohort), D2–7 / D8–28 (Σ `rbx:day:N` / cohort N); `rbx:playSec / 60 / dau`; `rbx:session:qualified / dau`; `rbx:coplay / dau` (R135: on a mixed-build range `dau` = the R122+ builds' `build:<b>:dau`); `payers / dau`; `robux / dau` | Device (`rbx:bounceDev:<class>:*`), co-play path (`rbx:coplayVia:*`), the scorecard's coverage row (PARTIAL under 98 % = mixed builds), build slices. PTR is only in Creator Hub. Ours are per player-day over ALL players; Roblox averages RfY joiners: directional, not Roblox's exact number |
| Data quality | `ops:badKey:*`, `ops:clientRefused:*` (FunnelStep split by `:<rate\|malformed\|implausible\|cap\|unknown\|popup>` since R122), `ops:flushDropped:*`, `npm:*`, `staff:*` | Any `ops:badKey` > 0 is a code bug to fix; flushDropped means DataStore trouble |

Units differ: sessions, players, player-days and server-minutes are not interchangeable. A mean
is not a percentile. A ratio with a missing denominator is **n/a**, never zero.

## Targets to watch (design intent, not proof)

- Funnel: ≥ 90 % `firstPad`, ≥ 80 % `firstClick`, ≥ 60 % `manager`, ≥ 40 % `area2` of joined.
- Pacing: each area's first-run minutes within ±20 % of the cumulative target (the economy
  simulator's tolerance); a single pad gap far above its neighbours is a pricing bug.
- Income share: automated income should dominate after area 2 (managers working).
- D1 ≥ 20 %, D7 ≥ 5 % for a healthy idle tycoon; carry-overs excluded.
- Offline: Welcome Back DOUBLE IT share and Offline Max pass purchases vs offline payouts.
- Health: laggy minutes < 2 %, server p95 frame < 25 ms, phone p95 frame < 33 ms.
- Roblox scorecard (R122, `AnalyticsConfig.Algorithm.Targets`, starting goals — adjust there
  against Creator Hub benchmarks): bounce < 60 s under 15 % (watch 25 %), bounce 61–180 s under
  15 % (watch 25 %), play days D1 ≥ 0.15 (0.08), D2–7 ≥ 0.5 (0.25), D8–28 ≥ 0.8 (0.4), capped
  playtime ≥ 20 min per player-day (10), qualified sessions ≥ 1.0 per player-day (0.6), co-play
  ≥ 10 % of player-days (4 %), spend days ≥ 1 % (0.3 %), Robux ≥ R$ 0.50 per player-day (0.10).

## Change and experiment decisions

Correctness / security fixes ship with regressions and are verified on health; never leave a
known-broken purchase or save path enabled to create a control group.

For pacing, pricing, offer and reward experiments, record before exposure: hypothesis, stable
assignment unit (player), treatment / control, ONE primary metric, absolute minimum detectable
difference, target sample, duration, exclusions and stop rule. Use at least seven complete UTC days
(weekday mix); D7 needs the full return day after the last acquisition day. If the sample is not
reached, report **INCONCLUSIVE** — do not keep checking until a favourable number appears. Price
tests and new rewards are separate decisions. Compare builds with the `build:<release>:p<place>:*`
slices, never by calendar alone.

Stop / revise immediately on: duplicate grants, an unintended paid prompt, profile or entitlement
loss, `ops:badKey` / `ops:flushDropped` growth, server p95 frame > 10 % worse on a matched build,
or client memory climbing with session age.

## Release and outcome log

Every change records: implemented, standalone verified (lune / check.sh), Studio verified, and
outcome measured. Outcome decisions: KEEP, REVISE, REVERT, INCONCLUSIVE. At launch every growth /
retention / pricing effect is **INCONCLUSIVE** until a complete measured window exists.

| Date | Build | Change | Primary metric | Window | Outcome |
|---|---|---|---|---|---|
| 2026-10-30 | — | Analytics layer (B13) shipped | — | — | baseline pending launch |
| 2026-11-01 | 0.5.1 / 0.7.1 | First live baseline recorded (above; owner R122) | — | 10-31 closed, 11-01 partial | baseline |
| 2026-11-01 | 0.8.0 | R122 §2.1 fast first minute: 6 s asset budget (critical vs deferred preload), 20 s TAP TO CONTINUE, boot-step telemetry | `rbx:bounce:lt60 / ftue:joined`; boot p50 per class (`cp:<Class>:bootStep*`, `bootEnd:*`) | ≥ 7 complete UTC days on `build:0.8.0` vs `build:0.7.1` | INCONCLUSIVE (pending ≥ 7 days on 0.8.0) |
| 2026-11-01 | 0.8.0 | R122 §2.2 automation by minute ~4: Uncle Atom 4th pad, re-paced Garage Lab, tutorial step 6 = hire the manager | `tut:7 / tut:6`; playtime per DAU (`rbx:playSec / 60 / dau`) | ≥ 7 complete UTC days on 0.8.0 | INCONCLUSIVE (pending ≥ 7 days on 0.8.0) |
| 2026-11-01 | 0.8.0 | R122 §2.3 return notifications (Open Cloud, one per player per day) + opt-in card at a strong moment | `rnotify:join:*`; carry-adjusted D1 | ≥ 7 complete UTC days on 0.8.0 (D1 needs the day after the last acquisition day); requires the owner's message ids + API secret | INCONCLUSIVE (pending ≥ 7 days on 0.8.0) |
| 2026-11-01 | 0.8.0 | R122 §2.4 co-play (HUD INVITE + invite moment) and no accidental purchase prompts (Lucky Button DEAL card, console / touch focus hygiene) | `rbx:coplay / dau`; `payers / dau` — guardrail: `promptDwell:*:lt2` share must fall | ≥ 7 complete UTC days on 0.8.0 | INCONCLUSIVE (pending ≥ 7 days on 0.8.0) |
| 2026-11-01 | 0.8.0 | R122 §2.5 Roblox-aligned analytics (`rbx:*`, FunnelStep refusal reasons) + the admin "Roblox algorithm scorecard" | data only (coverage row reaches 100 % once every server runs 0.8.0) | — | INCONCLUSIVE (data only; verify coverage after the 0.8.0 rollout) |
