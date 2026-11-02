# Analytics — the in-depth telemetry layer

This reference explains how SellNukes measures everything players do. It covers how counters are
recorded, stored and reported, and how to use the report to decide what to change. The layer is a
port of the RoBeasts design (`~/IdeaProjects/RoBeasts/docs/analytics.md`), adapted for a tycoon.
Read it before you add telemetry to a system, answer a pasted analytics report, touch the Roblox
"Recommended for You" scorecard, or build the same layer for a new game. In SellNukes, the source
of truth for mechanics is `docs/analytics.md`. Decision rules and targets live in
`docs/analytics-scorecard.md`. Key definitions are in `src/shared/Config/AnalyticsConfig.luau`
(`Metrics`).

## Contents

1. [The rule and the design principles](#1-the-rule-and-the-design-principles)
2. [Architecture](#2-architecture)
3. [Server outcomes vs validated client claims](#3-server-outcomes-vs-validated-client-claims)
4. [Sessions, funnel, cohorts and retention](#4-sessions-funnel-cohorts-and-retention)
5. [The Roblox "Recommended for You" scorecard](#5-the-roblox-recommended-for-you-scorecard)
6. [Revenue: funnel, attribution, receipts](#6-revenue-funnel-attribution-receipts)
7. [Health and performance telemetry](#7-health-and-performance-telemetry)
8. [The report, COPY FOR AI, COPY RAW DATA, Creator Dashboard](#8-the-report-copy-for-ai-copy-raw-data-creator-dashboard)
9. [Answering an owner's pasted report](#9-answering-an-owners-pasted-report)
10. [Reading live data through Studio](#10-reading-live-data-through-studio)
11. [Adding analytics to a new system](#11-adding-analytics-to-a-new-system)
12. [Porting the layer to another game](#12-porting-the-layer-to-another-game)
13. [Tests](#13-tests)

---

## 1. The rule and the design principles

**Owner rule 9:** *every system reports to the in-depth analytics layer, and every system is
controllable from the owner-only admin panel where that makes sense.* A system is not finished until
its keys are documented, recorded from the server's success path, and shown in the report. Its
admin controls are covered in `admin-panel.md`.

These principles apply to every game. Each one exists because of a real failure mode:

| Principle | Why |
|---|---|
| **Aggregate counters, not an event stream.** Each family keeps one map of `key → number` per UTC day. | An event log of every click would exhaust DataStore budgets and would need PII to be useful. Counters answer every funnel, retention and pacing question for a fraction of the cost. |
| **No PII.** No names or user ids in keys. Per-player facts live in `profile.analytics` and are never sent to the client. | Keys are exported to the owner and pasted into AI chats. They must be safe to share. |
| **Server-authoritative.** Counts come from server success paths, such as a pad bought, a receipt granted or a session ended. | A client can lie. Analytics must never be the reason a number is wrong. |
| **Client claims are validated and grant nothing.** Claims such as "screen opened", "offer card rendered", "device class" or "frame time" pass a token bucket, an allowlist and a cap. | Only the client knows what it rendered. A lying client can at most skew its own counters within the clamps. |
| **Every key is documented.** A key that matches no pattern in `AnalyticsConfig.Metrics` is refused and counted as `ops:badKey:<family>`. | The COPY FOR AI export prints every key's meaning, so an analyst never has to guess. A bug can never create thousands of keys. |
| **Recorders never throw, never yield, and are safe before `Start`.** | Telemetry must never break gameplay. |
| **Staff and New Player Mode are diverted.** | The owner testing must never look like a real player or payer. |
| **Every headline counter is sliced by build.** | A day mixes old and new servers. Without build slices you cannot tell whether an update moved a number. |

## 2. Architecture

### 2.1 Module map

| Module | Role |
|---|---|
| `src/server/Services/AnalyticsService.luau` | The facade with the public recorder API. `Start()` wires signals, remotes, the flush loop, the health loop and BindToClose. |
| `src/server/Analytics/Runtime.luau` | Shared state: dependency boundary (`setDeps`), sessions, `guard` / `economyGuard`, profile markers (`markUnique`, `markFirstDay`, `markFtue`, play clock). |
| `src/server/Analytics/Recorder.luau` | The single place counters are written: `Recorder.count(family, key, amount)` updates the `pending[day][family][key]` buffer, and also writes the build slice. |
| `src/server/Analytics/Sessions.luau` | Sessions, DAU / new / D-N retention, carry-overs, payers, devices, the `FunnelStep` and `ClientDevice` remotes, and the R122 `rbx:*` signals. |
| `src/server/Analytics/Revenue.luau` | Purchase funnel, prompt attribution, `OffersSeen`, the R137 offer click, and receipt accounting hooks. |
| `src/server/Analytics/Recorders.luau`, `WorldRecorders.luau` | Generic allowlisted family recorders, typed tycoon / pets / crates / worlds helpers, and the economy hook. |
| `src/server/Analytics/KeySpec.luau` | Validates keys against the `Metrics` pattern grammar and memoizes verdicts. |
| `src/server/Analytics/Flusher.luau`, `AnalyticsStore.luau` | 60 s flush, UpdateAsync merges, requeue, compaction, range loads, budget reserve. |
| `src/server/Analytics/Reports.luau`, `AnalyticsAuth.luau`, `ReportSections.luau`, `WorldSections.luau`, `AnalyticsRaw.luau` | Admin read-back: auth, cache, summary, every report table, raw pages. |
| `src/server/Analytics/BuildMetrics.luau` | Per-release slices `build:<release>:p<placeVersion>:<metric>`. |
| `src/server/Analytics/ServerHealth*.luau`, `ClientPerfIngest.luau` | Server frame / memory / ping / per-system time; the `ClientPerf` remote. |
| `src/server/Analytics/RobloxForwarder.luau` | Best-effort mirror to the Roblox Creator Dashboard. |
| `src/server/Analytics/ReceiptAccounting.luau`, `ReceiptJournal.luau`, `PromptAttribution.luau`, `ReturnTags.luau` | Durable receipt facts, purchase source, notification / carry tags. |
| `src/shared/Config/AnalyticsConfig.luau` | Every tunable, allowlist, target and the documented key patterns (`Metrics`). |
| `src/shared/Config/AnalyticsMarks.luau` | The `profile.analytics` shape and marker rules, including `reconcileAnalytics`. |
| `src/shared/Analytics/AnalyticsReport.luau` | Summary shape, defensive parser, COPY FOR AI text, the nine questions (`LoopContext`). |
| `src/shared/Analytics/FtueLogic.luau`, `NewPlayerFunnel.luau`, `ClientPerfLogic.luau`, `RawPaging.luau` | Pure rules shared by client, server and Lune tests. |
| `src/client/Analytics/ClientAnalytics.luau`, `ClientPerfReporter.luau` | The client claim API, the device reporter and the per-minute perf report. |

`AnalyticsService` is split into many modules for two reasons: readability, and Luau's 200-local
main-chunk limit. Studio compiles with debug info, and an "Out of local registers" error would stop
the server boot.

### 2.2 Data flow

```
gameplay success path ──► AnalyticsService.<recorder>(player, ...)        never throws / yields
                          │ Runtime.guard:        New Player Mode → core npm:<recorder>
                          │ Runtime.economyGuard: staff on a live server → core staff:<recorder>
                          │ KeySpec.check (generic recorders) → refused → core ops:badKey:<family>
                          ▼
                       Recorder.count(family, key, amount) → pending[day][family][key] += amount
                          │                                  (+ core build:<rel>:p<place>:<metric>)
every 60 s ─► Flusher.flushOnce: before-flush hooks (Sessions.flushActivity: midnight carry,
              play clock, rbx:playSec; Revenue.drainOutboxes) → AnalyticsStore.flush
              (one UpdateAsync per changed family-day) → failures requeued ≤ 30 min, then
              core ops:flushDropped:<family>
admin ──AnalyticsRequest(requestId, range)──► Reports: token bucket → typeof → AnalyticsAuth →
        30 s shared cache / one load job per range → loadRange + unsaved deltas + receipt ledger
        → AnalyticsLogic.summarize + ReportSections → AnalyticsRaw.remember
        → AnalyticsReport(requestId, { ok, code, range, summary | done/total })
```

### 2.3 Families

`AnalyticsConfig.Families` are listed in report order. There is one DataStore key per family per
day per shard. This keeps each write small and spreads concurrent servers over several keys.

| Family | What it holds | Example keys |
|---|---|---|
| `core` | Sessions, retention, funnel, devices, uniques, Roblox signals, builds, data quality | `sessions`, `dau`, `new`, `r1`, `ftue:manager`, `rbx:bounce:lt60`, `uniq:shop`, `build:0.9.1:p305:dau`, `ops:badKey:pets` |
| `revenue` | Robux, purchase funnel, offers | `robux`, `product:<key>:robux`, `funnel:<key>:shown/click/prompt/bought`, `promptDwell:*` |
| `economy` | Every currency's sources and sinks | `earn:cash:Producer`, `spend:gems:Egg`, `earn:gems:robux:<key>` |
| `tycoon` | The run | `pad:<padId>`, `padAt:<padId>`, `areaAt:<n>`, `click:<p>`, `income:auto`, `rebirth`, `tut:<n>` |
| `worlds` | Extra worlds | `unlock:dino`, `travel:dino:portal`, `seconds:dino`, `step:dino:firstPad` |
| `retention` | Daily / time / wheel / codes / group / notifications / screens / WHAT'S NEW | `daily:claim:3`, `wheel:spin:free`, `open:Shop`, `rnotify:result:ok` |
| `pets`, `crates`, `attack`, `event`, `social`, `kinetic` | Side systems | `hatch:<eggId>`, `open:<crateId>`, `launch:revenge`, `sticker:7`, `friendsIn:0`, `pull:main` |
| `orders` | **Retired** in R128. Old days still render, and new writes are refused as `ops:badKey`. | — |
| `health` | Server and client performance | `ft:<bucket>`, `laggy`, `sys:Producers`, `rx:<remote>:kb`, `cp:phone:bootStep:Assets:<5` |

Recorder families are the ones other systems may write through the generic recorders
(`AnalyticsConfig.RecorderFamilies`): tycoon, worlds, retention, pets, crates, attack, event, social
and kinetic. Core, revenue, economy and health are written only by the analytics modules.

### 2.4 Storage, flush, drain and compaction

- **Store:** `SellNukesAnalytics_v1` (`AnalyticsConfig.StoreName`). Version the name. A breaking
  change gets `_v2` and never rewrites old keys.
- **Keys:**
  - `d:<yyyy-mm-dd>:<family>:<shard>` holds `{ v = 1, c = { [key] = number } }`.
    `ShardCount = 1`, so the shard is `0`.
  - `c:<yyyy-mm-dd>` is a compacted final day, `{ v, day, f = { [family] = counters } }`.
  - `m:<yyyy-mm>` is a compacted ended month.
  - `meta` holds `{ firstDay }`.
- **Flush:** runs every `FlushInterval = 60` s. `AnalyticsLogic.mergeStored(old, delta)` is the
  pure `UpdateAsync` transform, so a retried transform never double-counts. There is at most one
  UpdateAsync per changed family per minute, which is about 13 per server per minute, well under
  `60 + 10 × players`. `UpdateBudgetReserve = 20` / `GetBudgetReserve = 8` keep profile saves first.
- **Failures:** a failed write is requeued for up to `MaxRetrySeconds = 1800`. After that it is
  dropped and counted as `ops:flushDropped:<family>`. Any non-zero value means DataStore trouble.
- **BindToClose:** records the last health window, ends every session (so `sessions` and
  `rbx:session:*` count), then `Flusher.flushPendingAsync(CloseFlushSeconds = 12)`. Gameplay
  never waits on it.
- **Compaction:** days older than `CompactAfterDays = 2` are final. They are compacted into
  `c:<day>` on first read, and ended months into `m:<month>`. A 30-day or all-time report then
  reads a few keys instead of hundreds.
- **Studio never writes** (`WriteInStudio = false`). If the place has no API access, Studio falls
  back to a memory-only store. The report then shows the server's own unsaved counters with
  source `"memory"`.
- **Bounds:** keys are at most 72 characters (`MaxKeyLength`), parts at most 32. Each family-day
  holds at most 2,500 keys; overflow goes to `_other`. Sums are clamped at 1e300.
- `Flusher.generation()` changes at every flush start. A report that snapshotted unsaved deltas
  during a flush retries, so a count is never doubled.

### 2.5 Key patterns and KeySpec

`AnalyticsConfig.Metrics[family][pattern] = "meaning"`. Pattern parts are split on `:`. The part
types are:

| Part | Meaning | Example |
|---|---|---|
| `literal` | exact match | `hatch` |
| `<a\|b\|c>` | one of the listed values | `<free\|paid>` |
| `<lo-hi>` | whole number in range | `<1-7>` |
| `<kind>` | an id of that kind | `<padId>` |

There are three kinds of `<kind>`:

- **Built-in** kinds are config lookups: `padId`, `producerId`, `area`, `feature`, `rarity`,
  `screen`, `source`, `world`, bucket kinds, and the world-scoped `worldArea` / `worldUpgrade` /
  `worldStep`. For example, `area:dino:7` is refused because Dino Valley has 6 areas.
- **Registered** kinds use `AnalyticsService.registerIds("eggId", isValid)` and get an exact check.
- **Unregistered** kinds fall back to identifier-shaped values, at most 64 distinct values per kind
  per server; later values fold into `other`.

A refused key counts `ops:badKey:<family>`. **Any `ops:badKey` greater than 0 is a code bug to
fix.** `tests/analytics-recorders.luau` fails if any recorded key is undocumented.

`AnalyticsConfig.KeyHooks[family][head] = { unique = surface, firstDay = milestone }` adds side
effects. For example, a `daily:*` key also marks the `daily` unique surface and first-day
milestone.

### 2.6 Exclusions (measurement hygiene, never punishment)

- **New Player Mode** is the admin sandbox, marked by the `NewPlayerMode` attribute. Every
  per-player recorder counts only `core npm:<recorder>` (`Runtime.guard`). A sandbox profile must
  never look like a real first-timer.
- **Staff** means an admin on a live server, or a profile stamped `staff`. Economy and revenue
  recorders count `core staff:<recorder>` instead (`Runtime.economyGuard`). Sessions still count.
  The live admin check is skipped in Studio, where everyone is admin (`LIVE_STAFF = not IsStudio`).
- Both verdicts are cached on the session, so hot paths such as producer income stay O(1).

### 2.7 Build slices

`BuildMetrics.key(family, key)` mirrors a fixed allowlist of headline counters at their original
recording moment. The slice key is `build:<VersionConfig.Current>:p<game.PlaceVersion>:<metric>`.
The allowlist covers `dau`, `new`, `sessions`, `sessionSeconds`, `r1..r30`, the `ftue:*` main steps,
`rbx:*` headline signals, `payers`, tycoon `rebirth` / `tut:6` / `tut:7`, and revenue `robux` /
`purchases`. Reports, retries and compaction can never
manufacture tags for old data. **Always bump `VersionConfig` for a player-facing release.** Without
the bump, the "Builds" table cannot separate the new build from the old.

## 3. Server outcomes vs validated client claims

Count an outcome on the server whenever the server can observe it. Use a client claim only for
facts the server cannot see: what was rendered, how long the loading screen took, frame times,
and the device class. Claims never grant, unlock or change anything.

| Remote (C→S) | What it claims | Defences | Refusal key |
|---|---|---|---|
| `FunnelStep(step, a?, b?)` | Client FTUE steps (`loadingDone`, `hudShown`, `tutorialSeen`, `firstMove`, `firstScreenClosed`), `"open"` screen + source, `"tutorial"` step, `"worldPopup"` | Token bucket 8 burst / 0.5 per s. String ≤ 32 chars. Exact allowlists (`ClientFunnel.Screens` / `Sources`). Steps count once per session; the funnel counts once per player. Screen opens are capped at 120 per session. `FtueLogic.claimPlausible` applies to R78 steps. | `ops:clientRefused:FunnelStep` plus `:<rate\|malformed\|implausible\|cap\|unknown\|popup>` |
| `OffersSeen(source, offerIds, newVisit)` | Offer cards actually rendered (the impression denominator) | Token bucket 6 / 0.5 per s. Sources allowlist. At most 12 cards per report and 60 visits per session. Each card counts once per visit. | `ops:clientRefused:OffersSeen` |
| `ClientDevice(device, input)` | Device class and input mode | Token bucket 4 / 0.1 per s. Exact allowlists. The last valid claim is counted once at leave. | `ops:clientRefused:ClientDevice` |
| `ClientPerf(buffer)` | Frame-time histogram, memory, ping, boot steps | Token bucket 3 / one per 25 s. Fixed-length versioned buffer. Finite checks and clamps. The claimed window cannot exceed the time since the previous report; boot counts once per session. | `cp:<Class>:bootDrop`, `ops:clientRefused:ClientPerf` |

**Plausibility checks.** `FtueLogic.claimPlausible(step, facts)` only counts a claim when the
server's own state agrees. Every checked step needs the plot reveal finished. `tutorialSeen` also
needs a tutorial step of at least 1, and `firstMove` needs the server-side character at least
`ServerMoveStuds = 8` studs from the entrance spawn. A refused claim is **not remembered**, so a
later honest one still counts.

**Readiness.** `FtueLogic.claimReady(step, plotRevealed)` was added in R135 after a real bug. The
client sends each checked step once per session. It used to send `tutorialSeen` during the plot
reveal, when the server refused it as implausible, and it never re-sent. The report read 148
"saw the hint" for 429 first-step hint arrows. The client now waits for the replicated
`PlotRevealed` attribute. **Lesson:** when a server check can refuse a once-only client claim,
make the client wait for the same fact before sending. Then compare the checked step with an
unchecked twin (here `tutClient:1`).

**Server-observed clicks.** In R137, offer BUY presses are not a new remote.
`MonetizationService`'s `PromptProduct` / `PromptPass` handlers fire
`PromptRequested(player, key, kind, source)`. This happens after the prompt rate limit and the
catalogue-key check, but before any prompt refusal. `Revenue.promptRequested` counts
`offer:<id>:click` and `funnel:<id>:click` only for offer surfaces (`OfferClicks.Sources`: `shop`,
`offer`, `welcomeBack`). It applies its own 4 / 0.5 per s bucket, a 1 s double-tap merge and a
60-per-session cap (`ops:clientRefused:OfferClick:<reason>`). Prefer this pattern: hang telemetry
on a request the server already validates.

## 4. Sessions, funnel, cohorts and retention

### 4.1 Sessions

The session keys are `sessions`, `sessionSeconds`, `len:<bucket>` (minutes: <2, 2-5, 5-15, 15-30,
30-60, 60-120, 120+), `sessNo:<bucket>` (lifetime session number), `hour:<HH>` (UTC start hour),
`device:<class>`, `input:<mode>`, `devSeconds:<class>` and `leaveArea:<n>`. Each session is counted
at its end (`Sessions.endSession`).

The R129 fix belongs here. The leave snapshot read the join-time state when Analytics'
PlayerRemoving ran before PlayerDataService's. The report then claimed "395 of 407 sessions end in
area 1" and "401 own 0 pets". `endSession` now refreshes the snapshot from the live profile, and a
regression test covers it (`tests/analytics-recorders.luau` §9b). **Lesson:** never trust
PlayerRemoving handler order. Read the state you report from the profile you are handed.

### 4.2 The new-player funnel (`core ftue:*`)

The steps are `AnalyticsConfig.Ftue.Steps`. **The list is append-only**, because step *i* is bit
*i-1* of `profile.analytics.ftue`. The reading order is `Ftue.Order`:

```
joined → plotReady → loadingDone* → tutorialSeen* → firstMove* → firstPad → firstClick →
firstCash → firstUpgrade → pad5 → manager → area2 → area3 → area4 → area5 → firstRebirth
side steps (never a session's furthest step): hudShown*, firstScreenClosed*     (* = client claim)
```

Each step counts once per tracked new player, across sessions. Companion keys:

| Key | Meaning |
|---|---|
| `ftueS1:<step>` | the step happened in session 1 |
| `ftueMin:<step>` | summed play minutes at the step (average = ÷ `ftue:<step>`) |
| `ftueAt:<step>:<bucket>` | the distribution of when the step happened |
| `ftueLeft:<furthest>` | where first sessions ended |
| `ftueLen:<bucket>` | first-session length |
| `ftueDev:<device>:<furthest>` | where first sessions ended, by device |

Steps 1–11 are forwarded to Roblox's onboarding funnel. `tycoon tut:<n>` (server) and
`tutClient:<n>` (client) track tutorial steps separately.

### 4.3 Cohorts and return-date retention

- `dau` dedupes across servers through `profile.analytics.last`. `new` starts the cohort
  (`analytics.first`). `returning` = active players who were not new that day; `legacy` = active
  players with no cohort.
- `r<N>` (N ∈ 1, 3, 7, 14, 30) = players active today whose first day was **exactly** N days ago.
  D-N = `r<N>` ÷ that day's `new`. This is return-date retention, not rolling retention.
- **Carry-overs:** a player online across 00:00 UTC counts `r<N>` and `r<N>:carry`. A genuine
  rejoin later that day counts `r<N>:carryRejoin`. D1 without carry-overs is
  `(r1 - r1:carry + r1:carryRejoin) / new(previous day)`.
- `r<N>:notify` counts joins from one of our notifications (`AnalyticsConfig.NotifyLaunchData`,
  for example `rn:cashFull`).
- **First-day milestones** (`FirstDay.Milestones`, append-only bits in `analytics.marks`): `click`,
  `pad5`, `upgrade`, `manager`, `area2`…`area5`, `hatch`, `crate`, `wheel`, `daily`, `pay`, `attack`,
  `event`, `rebirth`. Day 0 counts `cohort:<m>`, and the D1 / D7 join counts `r1:<m>` / `r7:<m>`.
  `r1:<m> / cohort:<m>` versus overall D1 shows what *correlates* with returning. It is not a cause.
- **Unique surfaces** (`uniq:<surface>`) count once per player per UTC day across servers through
  `analytics.seenDay / seen` bits. Use them as a denominator: "what share of DAU used the shop".
- **Devices:** `devNew:<class>`, `devR1:<class>` give D1 by device. The classes are phone, tablet,
  desktop, console and `unknown` (no claim).

### 4.4 Time-to-X and pacing

`profile.analytics.play` is the analytics play clock, and `runAt` is the clock at run start. Pad and
area purchases in the first run (`rebirths == 0`) add run seconds:

- average minutes to area *n* = `areaAt:n / areaN:n / 60`, compared with the cumulative
  `TycoonConfig.Pacing.TargetMinutes`;
- `padN:<padId>` / `padAt:<padId>` give the "Slowest pads" table, which ranks the gap between
  consecutive pads and shows where the economy stalls.

**Survivorship bias:** later areas only include players who got there, and those players are the
fast ones. Compare the `areaB:<n>:<bucket>` distributions, not only the means.

## 5. The Roblox "Recommended for You" scorecard

R122 aligned the analytics with how Roblox ranks the Recommended-for-You (RfY) sort. Roblox averages
per user over users who joined from RfY, in Day 1, Days 2–7 and Days 8–28 windows. The design spec
is `docs/superpowers/specs/2026-11-01-r122-algorithm-pack-design.md`.

### 5.1 Signals and our keys

| Signal (Roblox weight) | Our value | Keys |
|---|---|---|
| Play-through rate (tile CTR) | Creator Hub only; tone `info` | — |
| First-play bounce < 60 s, 61–180 s (important) | share of first sessions | `rbx:bounce:lt60`, `rbx:bounce:60to180` ÷ Σ `rbx:bounceDev:*` |
| Play days per user: D1, D2–7, D8–28 | days active per cohort member | D1 = `r1` / previous day's `new`; D2–7 = Σ_N `rbx:day:N` / cohort N |
| **Playtime per user, capped 60 min/day (most important)** | capped minutes per player-day | `rbx:playSec / 60 / dau` |
| Qualified sessions (> 180 s) | per player-day | `rbx:session:qualified / dau` |
| Intentional co-play days | share of player-days | `rbx:coplay / dau`, path `rbx:coplayVia:<follow\|invite\|host\|private>` |
| Spend days, Robux per user | per player-day | `payers / dau`, `robux / dau` |

Notes on how each key is recorded:

- `rbx:session:<lt60|60to180|qualified>` is counted at every session end. Σ of these ÷ `sessions`
  is the **coverage**: the share of sessions that ended on R122+ servers.
- `rbx:bounce:*` covers only a tracked new player's **first** session. `rbx:bounceDev:<class>:<lt60|60to180|stay>`
  is recorded at the same session end, so Σ `rbx:bounceDev:*` = first sessions classified.
- `rbx:playSec` is credited at every flush, release and leave. It is capped at 3,600 s per player
  per UTC day across sessions and servers (`profile.analytics.rbxDay / rbxSec`, session-locked). A
  span across midnight is split onto each day (`Recorder.countOn`). It uses the server clock only.
- `rbx:coplay` counts once per player per day through the unique bit `coplay`. It reads server
  facts only: `FollowUserId` to a friend who is here, `JoinData.ReferredByPlayerId` from an invite
  with the inviter present, being followed or invited (host), or a VIP server with someone else
  present. Friends who merely share a server do not count.

### 5.2 Targets and tones

`AnalyticsConfig.Algorithm.Targets` holds starting goals for an idle tycoon. Roblox publishes no
thresholds; adjust these against Creator Hub benchmarks.

| Row | Good | Watch |
|---|---|---|
| bounce < 60 s, bounce 61–180 s (lower is better) | < 15 % | < 25 % |
| play days D1 / D2–7 / D8–28 | 0.15 / 0.5 / 0.8 | 0.08 / 0.25 / 0.4 |
| capped playtime per player-day | 20 min | 10 min |
| qualified sessions per player-day | 1.0 | 0.6 |
| co-play days | 10 % | 4 % |
| spend days | 1 % | 0.3 % |
| Robux per player-day | R$ 0.50 | R$ 0.10 |

Each row carries a tone (`AnalyticsReport.Tones`):

| Tone | Label | Meaning |
|---|---|---|
| `good` | ON TARGET | meets the good threshold |
| `watch` | WATCH | between watch and good |
| `bad` | BELOW TARGET | worse than watch |
| `partial` | PARTIAL DATA | coverage under `MinCoverage = 0.98` and no way to correct for it |
| `na` | N/A | missing denominator or incomplete window; **never 0** |
| `info` | INFO | not a target row (PTR) |

The admin tab renders tone rows tall: a coloured value, a verdict tag beside the attainment bar,
and two wrapped detail lines.

### 5.3 Coverage and the R135 denominators

The R135 rules matter in any game that ships new counters mid-day. A range that mixes old and new
servers has numerators **only from new servers**. Dividing them by an all-server denominator
undercounts badly. `algorithmSection` in `ReportSections` therefore uses:

- **Bounce** ÷ Σ `rbx:bounceDev:*`, the first sessions R122+ servers actually classified. Never
  divide by `ftue:joined`, which also counts first sessions on old servers and first sessions
  still running. This is exact at any coverage.
- **Playtime, qualified sessions, co-play:** when coverage is under 98 %, divide by the R122+
  builds' player-days. That is Σ `build:<b>:dau` over builds with any non-zero `build:<b>:rbx:*`
  slice, clamped to `dau`.
- Both keep a real verdict plus a note such as `SAMPLE: R122+ servers only (136 of 489 joined new
  players)`. `PARTIAL` remains only for a mixed range with no build slices, and for the return-day
  rows.

On the 2026-11-01 17:33 report, the old denominators read bounce 5.9 % / 9.6 %, playtime 1.6 min,
qualified 0.14 and co-play 2 %. On the R122+ sample the real values were 21 % / 35 %, 5.9 min, 0.51
and 7 %. Tests: `tests/analytics-algorithm.luau` §4 / §4b on `AlgorithmFixture`, including the live
numbers.

Our values cover **every** player per player-day, while Roblox averages RfY joiners only. Treat
them as directional, and compare builds rather than chase Roblox's exact number.

## 6. Revenue: funnel, attribution, receipts

### 6.1 The purchase funnel

For each product or pass key, the funnel is `funnel:<key>:shown → click → prompt → bought`:

| Step | Source | Meaning |
|---|---|---|
| `shown` | `OffersSeen` claim | the card rendered (`offers:open:<source>`, `offers:card:<id>`, `offer:<id>:shown`) |
| `click` | R137, server-observed `PromptRequested` on offer surfaces | the player pressed BUY, even if the prompt never opened |
| `prompt` | `MonetizationService.PromptShown` | Roblox's purchase prompt opened (`prompt:<key>[:<source>]`) |
| `bought` | the durable receipt or `PassPurchased` | the purchase completed |

How to read each transition:

- `shown → click`: did players press BUY on the card, or see it and ignore it?
- `click → prompt` on the same surfaces: presses the server refused. Reasons include a prompt
  already open, already owned, coming soon, New Player Mode, or a world still locked.
- `prompt → bought`, together with `promptClosed*` and `promptDwell:<lt2|2to10|gt10>`: pressed
  BUY, then closed Roblox's prompt. A large `lt2` share means **accidental prompts**, such as
  walk-in pads or a console focus landing on BUY. That is a UX bug, not a pricing signal.

**Report honesty:** a range with no `funnel:*:click` key at all prints `click n/a`, not
`click 0 (0%)`. A zero denominator prints no percentage. Before R137, every "click 0 %" was missing
data, because `Revenue.offerClicked` had no caller. **Lesson:** a zero you cannot produce is not a
zero. Make the report say n/a.

### 6.2 Attribution

`PromptAttribution` records `purchase:<key>:<source>`, `robuxBySource / Device / Area /
Rebirth:*`, `buyArea:<n>` and `firstBuy:<key>`. Prompt sources come from
`PurchasePromptConfig.Sources`. The Nuke Pass premium funnel, for example, is
`prompt:NukePassPremium:pass → purchase:NukePassPremium:pass`.

### 6.3 Durable receipts

`MonetizationService.setReceiptAccounting(Revenue.accountingHooks())` installs two hooks:

1. `onGrant` must not yield and runs in the same profile commit as the grant. It captures the
   record (product, Robux, UTC day, source, device, area, rebirths, staff), marks the payer-day
   bitmap, and parks the record in `profile.analytics.outbox[PurchaseId]`.
2. `onDurable` journals the record once in `receiptV1:<yyyy-mm>:<shard>`. The id and the counters
   are written in **one** UpdateAsync, so replays never double-count. It then clears the outbox
   entry.

Failures stay in the outbox and are retried at every flush and at the next profile load. Game
passes are counted live on `PassPurchased`. Gross Robux is not net earnings.

## 7. Health and performance telemetry

- **Server windows** run every 60 s (`Health.WindowSeconds`), sampled at 2 Hz:
  - `win`, `sec`, frame-time buckets `ft:<bucket>` (18/20/25/33/50/100 ms) and `ftSum`;
  - heartbeat `hb:*`, `physSum`, `sendSum` / `recvSum`, memory `mem:*`, ping `ping:*`, `plrSum`;
  - `laggy`, a minute whose p95 frame time is above 33 ms.
- **Per-system Luau time:** `sys:<system>` from
  `AnalyticsService.systemTime("Producers", os.clock() - t)`. The systems are listed in
  `Health.Systems`: Producers, Tycoon, BuildIn, Plots, Pets, Attack, Event, Retention, Data,
  Monetization, Analytics, World, Admin and Other. Every server loop reports its own time.
- **Remote traffic:** `rx:<remote>:n/kb` from the Remotes send observer, at most 96 names.
- **Client perf:** `cp:<Class>:*` (frame-time histogram, memory, ping, instance counts) and
  `perfW:<world>:*`, where the world is the one the server knows (`CurrentWorld`), never a claim.
- **Boot steps (R122):**
  - `cp:<Class>:bootStep:<Loaded|Client|Profile|World|Plot|Assets>:<bucket>` and `bootStepS:<step>`;
  - `bootEnd:<ready|budget|tap|auto>`, the reason the loading screen handed over;
  - `bootDrop`, refused boot blocks.

  The "Client boot steps by device" table shows where the loading wait goes.
- `AnalyticsService.liveHealth()` returns `{ fps, heartbeatMs, memoryMb, players, avgPingMs,
  uptimeSeconds, systemsMsPerSecond, ... }` and feeds the admin **Live** tab.

The guardrails in `analytics-scorecard.md` are: laggy minutes < 2 %, server p95 frame < 25 ms, and
phone p95 frame < 33 ms. Stop or revert a change on a server p95 frame regression above 10 % on a
matched build, or on client memory that climbs with session age.

## 8. The report, COPY FOR AI, COPY RAW DATA, Creator Dashboard

### 8.1 Request and auth

The request is `AnalyticsRequest(requestId: integer, range: "today" | "7d" | "30d" | "all")`. The
server replies with `AnalyticsReport(requestId, { ok, code, range?, summary?, done?, total? })`,
where `code` is one of:

| Code | Meaning |
|---|---|
| `Ok` | summary attached |
| `Loading` | progress (`done` / `total`) |
| `RateLimited`, `BadRequest`, `NotAuthorized`, `Error` | failure |

Every request goes through these steps:

1. Per-user token bucket (`RequestBurst = 4`, `RequestPerSecond = 0.2`).
2. `typeof` checks.
3. `AnalyticsAuth.isAuthorizedAsync`. This delegates to `AdminService` when present, otherwise
   Studio or the experience creator. Every reply is re-checked with `isAdmin` right before it is
   sent.
4. A **30 s shared cache** per range. Concurrent requests join one load job, so clients can never
   drive DataStore reads in a loop.

### 8.2 Summary shape

```lua
Summary = { range, from, to, days, generatedAt, source ("datastore" | "memory"), partial, note,
            exporterVersion, windowComplete, openDayElapsedSeconds?,
            headline = { [key] = number },           -- -1 = n/a
            tables = { { id, title, note, total, more?, rows = { { id, label, value, display,
                         extra, share, tone? } } } },
            daily = { { day, dau, new, sessions, robux, payers, pads } },
            families = { [family] = { [key] = number } },   -- ≤ 3,000 counters, pinned first
            truncated, rawId }
```

**Headline cards:** DAU, peak DAU, player-days, sessions, average and median session, new players,
D1–D30, tutorial done (manager), reached area 2, Robux, purchases, payers, first-time payers,
ARPDAU, ARPPU, conversion, pads bought, rebirths.

**Sections**, built in `ReportSections` and shown only when they have data:

- Players and progression: Retention, the Roblox algorithm scorecard, New player funnel, First
  sessions at leave, D1 / D7 by first-day milestone, Unique players per surface, Session length,
  Sessions per player, Devices, Sessions by hour, Area pacing, Where sessions end, Pad purchases,
  Slowest pads, Producers, Income share, Level marks, Tutorial, Rebirths, Offline earnings.
- Money: Products & passes, Purchase funnel, Revenue by source / device / area / rebirth,
  Abandoned prompts, First purchases, Offers, Cash / gem sources and sinks.
- Side systems: Retention systems, Screens opened, Pets, Crates, Attack, Event, Social, and the
  worlds tables.
- Health: Server health, Server systems, Remote traffic, Client performance and memory by device,
  Client boot steps.
- Report meta: Builds, Data quality, Report coverage.

The limits are `ReportMaxTables = 80` and 25 rows per table (the server cuts longer tables and shows
"+N more rows").

### 8.3 COPY FOR AI

`AnalyticsReport.toText(summary)` produces one self-describing text of at most 130,000 characters.
It contains:

- the exporter version;
- `LoopContext`, a plain description of the **current** game loop that you must update whenever the
  core loop changes (bump `ExporterVersion`);
- the nine analyst questions;
- headline cards, every table, the daily series and pinned raw counters (`ReportPinnedPrefixes`:
  retention, funnels, revenue totals, uniques, and every key containing `refused` / `failed` /
  `badkey`);
- the definition of every key pattern present.

Roblox cannot write to the clipboard, so the export opens as selectable text in
`AnalyticsExportScreen`. The nine questions, verbatim from `AnalyticsReport.LoopContext`:

```
1. Where do new players drop in the funnel (join → first pad → first click → upgrade → manager → area 2 → 3)?
2. Is the run paced as designed? Compare average first-run minutes per area (areaAt / areaN) with the targets.
3. Which pads / producers stall players (time-to-pad gaps, pads bought vs reached, click vs automated income)?
4. Session length, sessions per player, D1 / D7 and what predicts return (first-day milestones r1:<m>).
5. Which offers / products / passes convert (shown → prompt → bought by source, device and tycoon area)?
6. Are retention systems used (daily, time, wheel, codes, group, offline payouts, notifications)?
7. Pets / crates / attack / event engagement, and server + client health problems by device.
8. Concrete pacing, pricing, offer and retention changes, each with the metric that should move.
9. Roblox's Recommended for You signals (the Roblox algorithm scorecard: first-play bounce, play days, capped
   playtime, qualified sessions, co-play, spend days): which rows are BELOW TARGET and what to fix first?
```

### 8.4 COPY RAW DATA

`AnalyticsRaw.remember` keeps an uncapped snapshot of the loaded summary and stamps `summary.rawId`.
The client pages it with `AnalyticsRawRequest(requestId, rawId, page)` →
`AnalyticsRawPage(requestId, { ok, code, page? })`. The limits come from `AnalyticsConfig.Raw`:
60,000 characters per page, at most 40 pages, snapshots kept for 900 s, a bucket of 8 / 1 per s.
`RawPaging.decide` drives the dialog's PREV / NEXT and LB / RB buttons. Use raw data when the AI
export trimmed a family you need.

### 8.5 Creator Dashboard mirror

`RobloxForwarder` copies a best-effort subset of events to Roblox's own `AnalyticsService`:

- economy Source / Sink, with producer income batched into one `Production` event per player per
  flush;
- the onboarding funnel (FTUE steps 1–11);
- one-time world funnels ("DinoValley");
- progression ("Dino Valley", "<name> Rebirth");
- a **fixed** set of custom events (`Forward.CustomEvents`: PadBought, ManagerHired, EggHatched,
  CrateOpened, WheelSpun, NukeLaunched, StickerFound, CodeRedeemed).

The forwarder is token-bucketed under Roblox's per-server cap: 60 burst, `90 + 15 × players` per
minute. Events over budget are dropped there, and our own aggregates still count them. Custom
fields carry config ids only. **Our DataStore aggregates are the source of truth.** The dashboard
is for Roblox-side views such as PTR, which only Creator Hub has.

## 9. Answering an owner's pasted report

The owner pastes COPY FOR AI and asks something like "any news on analytics?" or "why are people
leaving so early". Follow `references/owner-rules-and-workflow.md` and log the message first. Then
work through these steps:

1. **Note the window.** A range that includes today is provisional, because servers flush every
   minute. Never compare a partial day with a closed day as if both were complete. All days are
   UTC.
2. **Split by build.** Use the "Builds" table (`build:<release>:p<place>:*`). Compare the newest
   build with the old one on the same keys: loading done, first upgrade, manager, area 2 / 3,
   playtime per player-day. Calendar comparisons mix builds and lie.
3. **Correct for coverage.** Check the scorecard's coverage row and the `SAMPLE` notes. A
   numerator that only new servers record must be divided by new servers' denominators.
4. **Correct for survivorship.** Late-area pacing means only include players who got there. D-N
   only exists once the return day has passed. For example, a 0.9.0 cohort's first D1 reads the
   next day.
5. **Verify every suspicious number in code before concluding.** Red flags include: a step far
   below its unchecked twin (`ftue:tutorialSeen` vs `tutClient:1`); almost every session ending in
   area 1; a funnel step at exactly 0; a share above 100 %; `ops:badKey` / `ops:clientRefused` /
   `ops:flushDropped` growth. Find the recorder, prove the bug, fix it with a **regression test
   that fails on the old code**, and say plainly which numbers were wrong.
6. **Answer the nine questions** with cited numbers, each as `value (numerator / denominator)`.
   Name the key you used.
7. **Propose changes, each with the metric that should move** and the window needed to read it:
   at least 7 complete UTC days on the new build, with D7 needing the full return day. Re-pace with
   the economy simulator (`tests/economy-sim.luau --tune`), never by guessing prices. Ship only
   when the owner says "do it". Record each change in the outcome log of `analytics-scorecard.md`
   as INCONCLUSIVE until measured.
8. **Spot what only the owner can do,** such as publishing, notification message ids or API
   secrets, and say exactly what they must do.

**Units differ.** Sessions, players, player-days and server-minutes are not interchangeable. A mean
is not a percentile. A ratio with a missing denominator is **n/a**, never 0.

### 9.1 Worked mini-example (2026-11-01, owner R129 / R135 / R136 / R137)

**R129 — "why are people leaving so early".** The report was TODAY 00:00–14:16 UTC: 355 new
players, 407 sessions, average 5:13, median 3:30, 38.6 % of first sessions under 2 min, D1 2.2 %.

- *Build split:* 99 % of the day ran on 0.7.1 / 0.5.1 servers. The 0.8.0 fixes had only 4 new
  players, so they were not yet measurable. Say so instead of crediting or blaming them.
- *Where first sessions end* (`ftueLeft:*`):
  - 16 % never stepped on the free first pad. Phone boot averaged 28 s.
  - 42 % stopped between the first payout and pad 5, in minutes 1–4 of hand clicking.
  - 20 % stopped at pad 5. The 142 → 82 buyers drop came from a 7× price jump before the first
    manager at 6.8 min.
- *Suspicious number:* "395 of 407 sessions end in area 1" and "401 own 0 pets". Checking the code
  showed the leave snapshot read join-time state, a measurement bug. It was fixed in
  `Sessions.endSession` and covered by a regression test.
- *Proposals with metrics:*
  - no auto-opening world popup before area 4: metric `ftue:area3 / ftue:area2`;
  - re-pace area 3 so its manager comes earlier: metric `areaAt:4 / areaN:4`;
  - turn on return notifications (the owner must supply message ids): metric `rnotify:join:*`
    and carry-adjusted D1.

**R135 — "any news on analytics?".** The report ran to 17:33 UTC: 489 new players, 569 sessions,
manager 27 %, area 2 22.3 %, R$ 79 from 1 purchase. The scorecard read bounce < 60 s 5.9 %,
61–180 s 9.6 %, playtime 1.6 min, with R122 coverage 28.5 %.

- *Build split:* 0.9.0 (103 new) vs 0.7.1 (323 new):

  | Metric | 0.9.0 | 0.7.1 |
  |---|---|---|
  | loading done | 95 % | 90 % |
  | first upgrade | 83 % | 73 % |
  | manager | 50 % | 20 % |
  | area 2 | 30 % | 20 % |
  | playtime per player-day | 6.6 min | 5.9 min |

  The R122 / R130 work is visible only after the split.
- *Coverage:* 28.5 % coverage means the scorecard numerators came from about 28 % of servers. The
  correct denominator for bounce is the 136 first sessions those servers classified:
  5.9 % × 489 ≈ 29 → 29 / 136 = **21 %**, and 9.6 % × 489 ≈ 47 → 47 / 136 = **35 %**. Playtime on
  R122+ player-days is 5.9 min, not 1.6. This was fixed in `ReportSections` with `SAMPLE` notes
  and tests.
- *Suspicious number:* `tutorialSeen` was 148 against 429 first-step hint arrows. The claim was sent
  during the plot reveal, refused, and never re-sent. Fixed with `FtueLogic.claimReady`.
- *Survivorship:* D1 2.2 % = 5 of 232 comes from the 10-31 cohort on **old** builds. The first
  0.9.0 D1 reads 11-02.
- *Next walls:*
  - Tool Wall: $42 after about 1 min of $1 clicks, 419 → 319 buyers.
  - Area 2's manager is pad 8 of 10 behind 5.8× / 4× price jumps: 109 opened area 2 → 73 hired
    Cashier Bot → 57 reached area 3.
- *Missing data:* "click 0 %" for every offer was missing data, not a result. Propose recording
  BUY presses.

**R136 — "a little more time has passed".** The report ran to 22:27 UTC. Build 0.9.1 had 116 new
players: loading done 100 %, manager 47 %, area 2 33 %, area 3 20 % (best yet), 7.2 min per
player-day.

- R135's report fixes were not live yet: the report still divided by 614 joined. The owner must
  publish.
- `rnotify:result` showed ok 21 / rejected 59. The key works, so the rejections are per-player
  4xx: Roblox only delivers to opted-in players aged 13+. `rnotify:status:<kind>:<code>` was added
  so the next report shows why.
- "Offline payouts 84 % of all cash" looked like a bug. The code showed one late-game player
  earning 50 % × 3 h as designed, so it was **not** a bug and no fix was made.

**R137 — "do whatever you want and fix".** The proposals shipped in 0.9.2:

- Tool Wall $11 / Glow Lamp $19, and Cashier Bot moved to pad 4, re-paced with the simulator;
- offer clicks recorded server-side;
- what to watch next, on `build:0.9.2:*` against 0.9.1: `ftue:pad5`, `ftue:area3 / ftue:area2`,
  `funnel:*:click` and bounce. Always close a shipped change with this list.

## 10. Reading live data through Studio

The Open Cloud key on disk has no DataStore scope; DataStore calls return 403
INSUFFICIENT_SCOPE. Read the live store **from the already-open, MCP-connected place**, in edit
mode. This needs no playtest and no studio lock. Never print any key or token.

```lua
-- read_day.luau  (scratchpad file; run: python3 scripts/studio_mcp.py luau-file read_day.luau)
-- Read-only: GetAsync only. Never SetAsync / UpdateAsync / RemoveAsync on the analytics store.
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")

local store = DataStoreService:GetDataStore("SellNukesAnalytics_v1")
local DAY = "2026-11-01"
local FAMILIES = { "core", "revenue", "economy", "tycoon", "worlds", "retention", "pets",
	"crates", "attack", "event", "social", "kinetic", "health" }

local out = {}
-- A final day may already be compacted into c:<day> ({ f = { [family] = counters } }).
local okC, compact = pcall(store.GetAsync, store, `c:{DAY}`)
if okC and type(compact) == "table" and type(compact.f) == "table" then
	out = compact.f
else
	for _, family in FAMILIES do -- ShardCount = 1 → shard 0
		local ok, value = pcall(store.GetAsync, store, `d:{DAY}:{family}:0`)
		out[family] = if ok and type(value) == "table" then value.c else nil
	end
end
return HttpService:JSONEncode(out)
```

Parse `returnValue` in Python. A dump of every family for every day is about 110 KB and takes under
a minute. Slice by release with the `build:*` keys. Requiring a server ModuleScript from
`execute_luau` gives a **fresh copy with empty state**, so probe live server state through a
service's own QA hooks instead. In Studio, the analytics report itself shows only that Studio
server's memory counters.

## 11. Adding analytics to a new system

### 11.1 Checklist

1. **Decide the questions first.** Write down: what proves the system is used (unique users per day),
   where it fails (refusals by reason), what it pays (economy reasons), and whether it pays off (a
   first-day milestone or a revenue funnel).
2. **Pick a family.** Reuse an existing recorder family when the system is small, such as
   `retention` for a reward or `social` for a friend feature. A new family costs one more
   UpdateAsync per server per minute. It must be appended to `Families` and `RecorderFamilies`,
   and `FamilyTitles` needs a title.
3. **Document every key pattern** in `AnalyticsConfig.Metrics[family]` with its meaning, before
   recording it. Use bounded parts only: `<a|b>`, `<lo-hi>`, `<kind>`. Never use a free-form player
   value.
4. **Register id kinds** in your `Start` with `AnalyticsService.registerIds(kind, isValid)`.
5. **Optional side effects:** add `KeyHooks[family][head] = { unique = …, firstDay = … }`. The
   surfaces and milestones lists are **append-only** save data.
6. **Record from the server success path** and from each refusal (`<x>Refused:<reason>`), through
   one small `<System>Analytics` module. Currency flows are counted automatically by the economy
   hook from `PlayerDataService.CurrencyChanged` with your grant reason. Add the reason to
   `Economy.TransactionTypes` if it should reach Roblox's economy view.
7. **Client claims, only if needed:** for "rendered" or "opened" facts, add the screen id to
   `ClientFunnel.Screens` and call `ClientAnalytics.screenOpened(id, source)`. A new claim remote
   needs a token bucket, an allowlist, a per-session cap, a refusal reason key, and a plausibility
   check against server state.
8. **Report table:** if the metric deserves its own table, add a pure builder in `ReportSections`
   and test it in `tests/analytics-report.luau`. Also update `LoopContext` if the core loop
   changed.
9. **Health:** if the system runs a server loop, add its id to `Health.Systems` and wrap the loop
   in `AnalyticsService.systemTime`.
10. **Admin:** add the status and kill-switch commands (see `admin-panel.md`). A status command
    should print the same counters for this server.
11. **Docs and tests:** add to `docs/analytics.md`'s family table, and run `./scripts/check.sh`.
    `tests/analytics-recorders.luau` fails on any undocumented key.

### 11.2 Code skeleton (a hypothetical "Treasure Chest" system)

```lua
-- src/shared/Config/AnalyticsConfig.luau — append under Metrics.retention
["chest:open:<chestId>"] = "treasure chests opened (ChestService.open success path)",
["chest:refused:<cooldown|reach|locked|rate|other>"] = "refused chest opens by reason",
["chest:gems"] = "gems paid by chests (amount; also economy earn:gems:chest)",
```

```lua
--!strict
--[[
	ChestAnalytics — the one door from the Treasure Chest system into the analytics layer
	(retention family; AnalyticsConfig.Metrics documents and KeySpec allowlists every key).
	Goes through AnalyticsService lazily (Server/Event/Lazy), so Chest modules never require the
	analytics service at load and a missing analytics layer is skipped. Never yields, never throws.

	Example:
		ChestAnalytics.record(player, "chest:open:" .. chestId)
		ChestAnalytics.record(player, "chest:gems", 25)
]]
local Lazy = require(script.Parent.Parent.Event.Lazy)

local ChestAnalytics = {}

--[[
	Counts one documented key.
	@param player Player? — nil for server-wide keys
	@param key string — an instance of a documented Metrics.retention pattern
	@param amount number? — defaults to 1
]]
function ChestAnalytics.record(player: Player?, key: string, amount: number?)
	local record = Lazy.fn("AnalyticsService", "record")
	if record ~= nil then
		pcall(record, "retention", player, key, amount)
	end
end

return ChestAnalytics
```

```lua
-- ChestService.Start: exact ids for the <chestId> kind.
local registerIds = Lazy.fn("AnalyticsService", "registerIds")
if registerIds ~= nil then
	pcall(registerIds, "chestId", function(id: string): boolean
		return ChestConfig.Chests[id] ~= nil
	end)
end

-- ChestService remote handler (after typeof checks + rate limit; reason ∈ the documented set):
local ok, reason = ChestLogic.canOpen(state, chestId, os.time())
if not ok then
	ChestAnalytics.record(player, `chest:refused:{reason}`)
	return
end
local gems = ChestLogic.rollGems(chestId, rng)
PlayerDataService.grantCurrency(player, "gems", gems, "chest") -- economy hook counts earn:gems:chest
ChestAnalytics.record(player, `chest:open:{chestId}`)
ChestAnalytics.record(player, "chest:gems", gems)
```

## 12. Porting the layer to another game

Copy the shape, not the tycoon keys:

1. Copy `Recorder`, `AnalyticsLogic`, `AnalyticsStore`, `Flusher`, `KeySpec`, `BuildMetrics`,
   `Reports`, `AnalyticsRaw`, `AnalyticsAuth` and `AnalyticsReport` nearly unchanged. Rename the
   store (`<Game>Analytics_v1`).
2. Rewrite `AnalyticsConfig.Metrics`, `Families`, `Ftue.Steps` (append-only), `FirstDay.Milestones`,
   `Unique.Surfaces`, `Algorithm.Targets` (by genre) and `LoopContext` (describe the new loop and
   keep the nine questions, adapting question 1–3 nouns).
3. Keep `Sessions` (sessions, retention, `rbx:*`) and the receipt accounting hooks as they are.
   They are genre-agnostic.
4. Wire `Runtime.setDeps` to the new data layer (`getProfile`, `canMutate`, `markSaved`, `isAdmin`).
5. Ship the admin Analytics tab with COPY FOR AI on day one. Without it the owner cannot paste a
   report.

## 13. Tests

Run `./scripts/check.sh`, which includes `./scripts/test-logic.sh`. The suites are:

| Suite | Covers |
|---|---|
| `analytics-logic` | keys, counters, stored shapes, plan, buckets, validators, marks, receipts, health maths |
| `analytics-store` | flush, merge, budget, load, compaction, journal idempotency |
| `analytics-recorders` | sessions, funnel, helpers, economy, revenue, exclusions, every key documented, R129 §9b |
| `analytics-report` | headlines, sections, COPY FOR AI, parser, stress trimming, raw pages |
| `analytics-client-perf` | wire round trip, hostile payloads |
| `analytics-roblox-signals` | `rbx:*` buckets, the cap across sessions, co-play paths |
| `analytics-algorithm` | scorecard rows, verdicts, PARTIAL vs SAMPLE, R135 §4 / §4b |
| `ftue-logic` | plausibility, `claimReady` R135 §4b |

Every measurement bug you fix gets a test that fails on the old code.
