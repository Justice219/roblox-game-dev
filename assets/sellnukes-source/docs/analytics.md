# SellNukes analytics

Owner request R6 (2026-10-30): *"a fully in-depth analytics system to track as much data as
possible … look at how RoBeasts does it."* Spec §13. This document is the reference for how the
system works, every metric family, the recorder API other systems call, the report the admin
panel shows, and how to add metrics. Decision rules live in
[`analytics-scorecard.md`](analytics-scorecard.md).

## 1. What it is (and is not)

- **Server-authoritative aggregate counters** per UTC day and family. No per-player event stream,
  no names, no user ids in keys, no PII. Every count comes from a server success path (a pad
  bought, a receipt granted, a session ended) or a **validated client claim** (screen opened,
  offer card rendered, device class, client performance) that never grants anything.
- Flushed every 60 s to the DataStore `SellNukesAnalytics_v1` with idempotent `UpdateAsync`
  merges (`d:<yyyy-mm-dd>:<family>:<shard>`); days older than 2 days are compacted into
  `c:<day>`, ended months into `m:<yyyy-mm>`. **Studio never writes** (`WriteInStudio = false`);
  Studio playtests still see their own unsaved counters in the report ("memory" source).
- Mirrored best-effort to the **Roblox Creator Dashboard** (economy, onboarding funnel, purchase
  funnel, progression, a fixed set of custom events) through a rate-limited forwarder.
- Read back by admins in the admin panel's **Analytics tab** (B14 builds the UI), with **COPY FOR
  AI** (one self-describing text report) and **COPY RAW DATA** (paged uncapped counters).

## 2. Files

| File | Role |
|---|---|
| `src/server/Services/AnalyticsService.luau` | Facade: public recorder API + `Start()` wiring (signals, remotes, loops, BindToClose) |
| `src/server/Analytics/Runtime.luau` | Shared state: deps boundary, sessions, staff / New Player Mode guards, profile markers (uniques, first-day milestones, funnel, play clock) |
| `src/server/Analytics/Recorder.luau` | The pending delta buffer (`count`), detach / settle / requeue for flushes |
| `src/server/Analytics/Sessions.luau` | Sessions, DAU / new / D-N retention, carry-overs, payers, devices, FunnelStep (refusals by reason) + ClientDevice; R122 Roblox signals (`rbx:*`: bounce, session buckets, capped playtime, co-play, play days) |
| `src/server/Analytics/Revenue.luau` | Purchase funnel, prompt attribution, durable receipt accounting hooks, passes, offers (OffersSeen) |
| `src/server/Analytics/Recorders.luau` | Generic allowlisted family recorders, typed tycoon / pets / crates helpers, economy hook |
| `src/server/Analytics/KeySpec.luau` | Validates recorder keys against the documented patterns (allowlist engine) |
| `src/server/Analytics/WorldRecorders.luau` | R57 `worlds` family: typed world helpers, routed extra-world pad / producer ids, time per world, visitors, world funnel + progression, popup claims, batched world-currency income |
| `src/server/Analytics/WorldSections.luau` | R57 WORLDS report tables (overview, per-world funnel / pacing / popup & travel / money, client perf per world) |
| `src/server/Analytics/Flusher.luau` | Owns the store; periodic flush; shutdown drain; test backend swap |
| `src/server/Analytics/Reports.luau` | AnalyticsRequest handling, auth, shared cache, `summaryAsync`, labels |
| `src/server/Analytics/AnalyticsAuth.luau` | Admin authorization seam (AdminService when present; else Studio / experience owner) |
| `src/server/Analytics/AnalyticsStore.luau` | DataStore I/O: merges, range loads, compaction, budget reserve (ported) |
| `src/server/Analytics/AnalyticsLogic.luau` | Pure rules: keys, counters, stored shapes, plan, buckets, validators, `summarize` |
| `src/server/Analytics/ReportSections.luau` | Every report table, built from range totals (R122 "Roblox algorithm scorecard" first; calls WorldSections after the tycoon tables) |
| `src/server/Analytics/AnalyticsRaw.luau` | COPY RAW DATA snapshots + pages (ported) |
| `src/server/Analytics/RobloxForwarder.luau` | Creator Dashboard mirror (ported) |
| `src/server/Analytics/ReceiptAccounting.luau`, `ReceiptJournal.luau` | Durable receipt facts + permanent journal (ported) |
| `src/server/Analytics/PromptAttribution.luau`, `ReturnTags.luau`, `BuildMetrics.luau` | Purchase source, carry / notify tags, per-release slices (ported) |
| `src/server/Analytics/ServerHealth.luau`, `ServerHealthLogic.luau` | Server frame / heartbeat / memory / ping / per-system / remote sampling |
| `src/server/Analytics/ClientPerfIngest.luau` | ClientPerf remote receiver (validated, clamped) |
| `src/shared/Config/AnalyticsConfig.luau` | Every tunable, allowlist and the documented key patterns (`Metrics`) |
| `src/shared/Config/AnalyticsMarks.luau` | `profile.analytics` shape + marker rules (shared so ProfileLogic can use it) |
| `src/shared/Analytics/AnalyticsReport.luau` | Summary shape, defensive parser, COPY FOR AI text, raw pages (client + server) |
| `src/shared/Analytics/NewPlayerFunnel.luau` | Funnel step labels + report rows |
| `src/shared/Analytics/ClientPerfLogic.luau`, `ClientPerfConfig.luau` | Client perf wire format + counters (ported) |
| `src/shared/Analytics/RawPaging.luau` | COPY RAW DATA dialog paging rules (ported, for the admin UI) |
| `src/client/Analytics/ClientAnalytics.luau` | Client API: `step`, `screenOpened`, `tutorialShown`, `offerSeen`, `plotReady`; device reporter |
| `src/client/Analytics/ClientPerfReporter.luau` | Per-frame accumulator + minute report |
| `tests/analytics-*.luau`, `tests/analytics-fixtures/Loader.luau` | Lune suites (logic, store, recorders, report, client perf; R57 worlds in recorders / report / client perf; R122 `analytics-roblox-signals` + `analytics-algorithm` with `analytics-fixtures/AlgorithmFixture.luau`) |
| `tools/qa/world2_check.py` (+ `world2_check.luau`, `world2_check_client.luau`) | R57 Studio QA: `tour` / `rejoin` / `multi` / `perf` modes, captures + JSON in `docs/verification/world2/`, checks the worlds keys a tour must produce |

## 3. Data flow

```
gameplay success path ──► AnalyticsService.<recorder>(player, ...)        (never throws / yields)
                          │  Runtime.guard: New Player Mode → core npm:<recorder>
                          │  Runtime.economyGuard: staff (live) → core staff:<recorder>
                          │  KeySpec.check (generic recorders) → refused → core ops:badKey:<family>
                          ▼
                       Recorder.count(family, key, amount)  ─► pending[day][family][key] += amount
                          │                                    (+ build:<release>:p<place>:<metric> slice)
   every 60 s ─► Flusher.flushOnce: Sessions.flushActivity (midnight carry, play clock, batched
                 Roblox income) · Revenue.drainOutboxes · AnalyticsStore.flush (UpdateAsync merge)
                 failures requeued ≤ 30 min, then counted as core ops:flushDropped:<family>
admin ──AnalyticsRequest(requestId, range)──► Reports: token bucket → validate → AnalyticsAuth →
        shared 30 s cache / one load job per range → AnalyticsStore.loadRange (+ unsaved deltas +
        receipt ledger) → AnalyticsLogic.summarize + ReportSections → AnalyticsRaw.remember →
        AnalyticsReport(requestId, { ok, code, range, summary | done/total })
```

## 4. Families and metrics

The authoritative list of key patterns is `AnalyticsConfig.Metrics` (each pattern with its
meaning; the COPY FOR AI export prints the definitions of every pattern present). Summary:

| Family | What | Main keys |
|---|---|---|
| `core` | Sessions, retention, funnel, devices, uniques, Roblox signals, data quality | `sessions`, `sessionSeconds`, `len:<bucket>`, `sessNo:<n>`, `dau`, `new`, `returning`, `r<N>`, `r<N>:carry/notify/carryRejoin`, `payers`, `newPayers`, `hour:<HH>`, `device:<class>`, `devNew/devR1:<class>`, `ftue:<step>`, `ftueS1/ftueMin/ftueAt/ftueLeft/ftueLen/ftueDev`, `cohort:<m>`, `r1:<m>`, `r7:<m>`, `uniq:<surface>`, `rbx:*` (R122, see "Roblox signals"), `build:*`, `ops:*` (incl. `ops:clientRefused:<remote>:<reason>`), `npm:*`, `staff:*` |
| `revenue` | Robux, purchase funnel, offers | `purchases`, `robux`, `product:<key>:count/robux`, `pass:<key>:count/robux`, `prompt:<key>[:<source>]`, `promptClosed*`, `promptDwell:*`, `purchase:<key>:<source>`, `robuxBySource/Device/Area/Rebirth:*`, `buyArea:<n>`, `firstBuy:<key>`, `funnel:<key>:shown/click/prompt/bought`, `offer:<id>:shown/click`, `offers:open/card:*` |
| `economy` | Cash / gems / acorns / tokens + every world currency (R57: `bones`, `amber`) sources & sinks | `earn:<cur>`, `earn:<cur>:<reason>`, `spend:<cur>[:<reason>]`, `n:earn/spend:<cur>:<reason>`, `earn:gems:robux:<key>` |
| `tycoon` | The run | `clicks`, `click:<p>`, `income:click/auto/offline`, `incomeP:<p>:click/auto`, `pad:<padId>`, `padN/padAt:<padId>` (first-run time-to-pad), `padKind:*`, `padArea:*`, `padSkip:*`, `upgrade/levels:<p>`, `upgradeMode:*`, `lvl:<p>:<mark>`, `manager:<p>`, `area:<n>`, `areaN/areaAt:<n>` (first-run time-to-area), `areaB:<n>:<bucket>`, `tut:<n>`, `tutClient:<n>`, `tutDone`, `feature:*`, `rebirth`, `rebirthN:*`, `rebirthSec`, `runB:*`, `rebirthTokens`, `rebirthShop:*`, `offline:pay/double`, `offlineSec`, `offlineCash`, `offlineB:*`, `rename`, `teleport:<n>`, `teleportHub`, `leaveArea:<n>`, `plot:<i>` |
| `worlds` | R57 extra worlds (see "Worlds" below) | `unlock:<w>`, `unlockSrc:<w>:<area/rebirth/legacy/admin>`, `popup:<w>:<shown/go/later/lockedPreview>`, `portalLocked:<w>`, `travel:<w>:<portal/menu/popup/chip/admin/respawn>`, `travelFail:<w or unknown>:<reason>`, `visitor:<w>`, `firstVisit:<w>`, `seconds:<w>`, `step:<w>:<step>`, `area/areaN/areaAt:<w>:<a>`, `areaB:<w>:<a>:<bucket>`, `padArea:<w>:<a>`, `rebirth:<w>`, `rebirthN:<w>:<bucket>`, `rebirthShop:<w>:<key>`, `tokens:<w>`, `offline:<w>:<pay/double>`, `offlineSec:<w>`, `incomeW:<w>:<click/auto/offline>` |
| `retention` | Daily / time / wheel / codes / group / notify / welcome / screens / WHAT'S NEW | `daily:claim:<1-7>`, `daily:reset`, `time:claim:<1-7>`, `wheel:spin:<free/bonus/paid>`, `wheel:slice:<sliceId>`, `wheel:refused:<policy/empty>`, `wheel:receipt:<spins/gems>`, `pack:spins:<spins/gems>`, `code:ok:<codeId>`, `code:fail:<reason>`, `group:claim/notMember`, `notify:*`, `welcome:okay/double`, `open:<screen>`, `openFrom:<screen>:<source>`, `notes:shown:<noteId>:<auto/menu>`, `notes:<seen/cta/closed>:<noteId>`, `notes:openSec:<noteId>`, `notes:openLen:<lt5/5to15/15to60/gt60>` (owner R58, report table `whatsNew`; `docs/change-notes.md`) |
| `pets` | Eggs and pets | `hatch:<eggId>`, `hatchN:<eggId>:<1/3>`, `hatchAuto`, `rarity:<r>`, `eggRarity:<egg>:<r>`, `pet:<petId>`, `equip`, `equipBest`, `delete`, `owned:<bucket>`, `equipped:<n>`, `refused:<cash/gems/slots/rate/locked/policy/other>` (policy = paid random items restricted / unknown); R78 Pet Index rewards: `index:claim:<5/10/20/30/45/60/all>`, `index:gems` (gems paid), `index:refused:<claimed/locked/rate/bad/save/other>` (economy reason `petIndex`) |
| `crates` | Supply crates and boosts | `open:<crateId>`, `openPay:<crate>:<gems/robux/free>`, `reward:<crate>:<kind>`, `rarity:<r>`, `boost:<key>`, `boostSec:<key>`, `refused:<gems/policy/rate/busy/other>` |
| `attack` | Attack mode | `console`, `launch:<normal/revenge/barrage>`, `intercept`, `hit`, `hitCash`, `refused:<cooldown/protected/shield/target/rate/locked/other>`, `shield:<free/product>`, `aa:<aa/launcher>:<level>`, `targets:<n>` (targetable players per accepted launch); knockdown (owner R50, for the knocked player): `knock:<1-10>`, `knockSrc:<normal/revenge/barrage/admin/test/rival/other>`, `knockBlocked:<immune/shielded/not_built/disabled>`, `knockTap` (taps), `knockSec` (seconds down), `knockEnd:<timer/admin/reset>` |
| `event` | Harvest Feast | `turkey:<spawn/collect/lure>`, `acorns`, `sticker:<1-20>`, `stickerDup`, `sheet:redeem`, `egg:<eggId>`, `decor:<decorId>`, `shop:<eventItemId>`, `lure:refused:policy`, `lure:fixed` |
| `social` | Population | `players:<0-8>` (server-minutes), `plots:<0-8>`, `friendsIn:<bucket>`, `visit`, `joinFollow` |
| `orders` | **Retired** (owner R128, 0.8.1): the R90 Order Window was removed. No longer a recorder family (writes are refused as `ops:badKey`); the definitions + the `orders` unique-surface bit stay so old days still render (`docs/orders.md`) | `unlock:<w>`, `spawn:<w>`, `served:<w>` (unique surface `orders`), `stars:<1-3>`, `flavor:<sprinkle/glitter/rainbow>`, `expired:<w>`, `pickup:<w>`, `handed:<w>` (amount), `tip:<w>` (amount), `tipSeconds` (amount), `jar:<w>` (amount), `fameClaim:<1-11>`, `fameGems` (amount), `refused:<reason>`, `admin:<toggle/spawn/clear/status/reset>` |
| `health` | Server + client performance | `win`, `sec`, `ft:<bucket>`, `ftSum`, `hb:*`, `physSum`, `sendSum`, `recvSum`, `mem:*`, `ping:*`, `plrSum`, `laggy`, `sys:<system>`, `rx:<remote>:n/kb`, `cp:<Class>:*`, `perfW:<world>:*` (R57: the same client report split by the server-known world) |

### Worlds (owner R57 World 2 "Dino Valley"; `Server/Analytics/WorldRecorders`)

* **Family `worlds`** (12 families → still ≤ 12 UpdateAsync per server per minute). `<w>` is a
  `WorldsConfig` id; KeySpec checks `<worldArea>` / `<worldUpgrade>` / `<worldStep>` against the
  world named by the key's own `<w>` part (`area:dino:7` is refused: the Valley has 6 areas).
* **Tycoon keys of every world**: `pad:` / `padN:` / `padAt:` / `padKind:` / `padSkip:` /
  `manager:` / `click:` / `incomeP:` / `upgrade:` / `levels:` / `lvl:` accept Dino ids
  (`d3_wind_sock`, `dp3_ptero_express`): the typed helpers route an extra world's id to
  `WorldRecorders` (first run = that world's `rebirths == 0`, time-to-pad = that world's
  `stats.runSeconds`). Nuke Town-only keys stay Nuke Town (`clicks`, `income:*`, `padArea:<n>`,
  `area:<n>`, the new-player funnel, `feature:*`).
* **Time per world** (`seconds:<w>`, also `seconds:main`) is measured by analytics itself: the
  clock switches on `worldTravelled` and is re-checked against the server-set Player attribute
  `CurrentWorld` at every flush (a trip that skipped the hook is still clocked).
* **Visitors**: `visitor:<w>` counts once per player per UTC day across servers through the
  profile's unique-surface bit `w_<id>` (also core `uniq:w_<id>`). World 3 appends its `w_<id>` to
  `AnalyticsConfig.Unique.Surfaces` (tests/analytics-recorders checks every extra world has one).
* **Funnel** (once per player by construction, no saved marker): `unlocked → firstTravel →
  firstPad → manager → area2 … areaN → finale → rebirth`, counted as `step:<w>:<step>` and
  forwarded to the Creator Dashboard as a ONE-TIME funnel named after the world ("DinoValley").
  Progression path = the world name ("Dino Valley", level = area) and "<name> Rebirth".
* **Economy**: `AnalyticsConfig.Economy.Currencies` = cash, gems, acorns, tokens + each extra
  world's `currency.key` / `tokens.key`; `CurrencyNames` gives Roblox's currency name ("Bones").
  Unmapped Bones earnings (producer ticks) are batched into ONE Roblox economy Source per player
  per flush, like cash.
* **Client**: `ClientAnalytics.worldPopup(worldId, action)` (FunnelStep `"worldPopup"`; extra
  world + action allowlist, capped `PopupSessionCap` per session per world and action);
  `ClientFunnel.Screens` gains `WorldUnlocked` / `WorldTravel`, `Sources` gains `portal` / `chip`.
* **Client perf**: `perfW:<world>:{reports, seconds, frames, ft:<b>, sampled, memMb, pingMs,
  instN, inst}` from the server-known world at report time (never a client claim).
* **Report** (`Server/Analytics/WorldSections`, admin Analytics tab + COPY FOR AI): `worlds`
  overview (minutes per world, unlocks, visitor-days, first visits, avg min per visitor-day,
  rebirths, trips), per extra world `worldFunnel_<w>`, `worldPacing_<w>` (vs the world's Pacing),
  `worldEntry_<w>` (popup funnel, locked portal, trips by source, refusals), `worldMoney_<w>`
  (rebirths, Amber + shop, Bones earned / spent / produced, offline, the world's egg hatches, the
  world's product Robux) and `worldPerf`; Bones / Amber sources and sinks come from the economy
  tables. `ReportMaxTables` = 80.
* **Admin**: Players list shows the current world + each unlocked world's currency / area /
  rebirths (`AdminState.playerWorlds`), the Live tab one "In <world>" card per world
  (`stats.worlds`).

### New-player funnel (`core ftue:*`)

Steps (`AnalyticsConfig.Ftue.Steps`, append-only: bit i-1 of `profile.analytics.ftue`), read in
`Ftue.Order` (R78: chronological): `joined → plotReady → loadingDone (client) → tutorialSeen
(client) → firstMove (client) → firstPad → firstClick → firstCash → firstUpgrade → pad5 → manager →
area2 → area3 → area4 → area5 → firstRebirth`, plus the side steps (`Ftue.SideSteps`, never a
session's furthest step) `hudShown` and `firstScreenClosed` (client). Client steps come from
`Tycoon/FtueTracker` (until R78 `loadingDone` / `hudShown` had no sender, so every early quit read
"plotReady"); the R78 ones are counted only when `Shared/Analytics/FtueLogic.claimPlausible`
agrees with the server's own state (reveal done; a tutorial running; the server-side character ≥
8 studs from the entrance spawn for `firstMove`). R135: the client sends `tutorialSeen` /
`firstScreenClosed` only once the replicated `PlotRevealed` attribute is true
(`FtueLogic.claimReady`); before that, a hint shown or a window closed during the plot reveal
spent the once-per-session send on a claim the server refused, so builds ≤ 0.9.1 under-read
`tutorialSeen` (148 vs 429 first-step arrows on 2026-11-01; compare `tutClient:1`, which is
unchecked). The perf `boot` histogram now measures the real
loading-screen wait (`BootSeconds` at hand-off; it used to take `time()` before the screen ended).
Each counts **once per tracked new player**, across sessions; `ftueS1:<step>` says it
happened in session 1, `ftueMin:<step>` sums play minutes at the moment (average = ÷ count),
`ftueAt:<step>:<bucket>` gives the distribution. At the end of the first session:
`ftueLeft:<furthest step>`, `ftueLen:<bucket>`, `ftueDev:<device>:<furthest>`. Steps 1–11 are
forwarded to Roblox's onboarding funnel in order.

### Time-to-X and pacing

`profile.analytics.play` is the analytics play clock (folded in at every flush and leave);
`runAt` = `play` when the current run started (reset on rebirth). First-run (`rebirths == 0`)
pad and area purchases add the run seconds: average minutes to area *n* = `areaAt:n / areaN:n / 60`,
compared in the report with `TycoonConfig.Pacing.TargetMinutes` (cumulative). The "Slowest pads"
table ranks the average first-run time between consecutive pads — where the economy stalls.

### Retention

`dau` dedupes across servers through `analytics.last`; `new` starts the cohort (`analytics.first`);
`r<N>` = active today, first day exactly N days ago (N ∈ 1, 3, 7, 14, 30). A player online across
00:00 UTC is a carry-over: counted `r<N>` + `r<N>:carry` and marked (`analytics.carry`); a genuine
rejoin later that day counts `r<N>:carryRejoin`. D1 excluding carry-overs =
`r1 - r1:carry + r1:carryRejoin`. A join from one of our notifications (LaunchData in
`AnalyticsConfig.NotifyLaunchData`) also counts `r<N>:notify`. First-day milestones
(`AnalyticsConfig.FirstDay.Milestones`) give `cohort:<m>` and, on the D1 / D7 join, `r1:<m>` / `r7:<m>`.

### Roblox signals (owner R122, "algorithm pack" 0.8.0)

Spec: `docs/superpowers/specs/2026-11-01-r122-algorithm-pack-design.md`. Roblox ranks Recommended
for You on per-user averages over users who joined from it, in Day 1 / Days 2–7 / Days 8–28
windows: **play-through rate** (PTR, the tile), **first-play bounce** (< 60 s, 61–180 s), **play
days per user**, **playtime per user capped at 60 min per day** (most important), and **intentional
co-play days**, **qualified sessions**, **spend days**, **Robux per user** (important). Tunables:
`AnalyticsConfig.Algorithm` (BounceSeconds 60, QualifiedSeconds 180, PlayCapSeconds 3,600,
PlayDayMax 28, MinCoverage 0.98, Targets).

Core keys recorded by `Server/Analytics/Sessions` (pinned in every export: prefix `rbx:`):

| Key | When | Notes |
|---|---|---|
| `rbx:session:<lt60\|60to180\|qualified>` | every ended session (exactly where `sessions` counts) | qualified = longer than 180 s. Σ `rbx:session:*` = sessions ended by R122+ servers, so `Σ / sessions` is the scorecard's **coverage** check on mixed-build ranges |
| `rbx:bounce:<lt60\|60to180>` | a tracked new player's FIRST session ends within 60 s / within 61–180 s | population = `ftue:joined` (joined is marked at that session's load), so `rbx:bounce:lt60 / ftue:joined` is Roblox's bounce. Leaves before the profile loads cannot be classified (`ops:leftBeforeProfile`) |
| `rbx:bounceDev:<class>:<lt60\|60to180\|stay>` | the same first sessions by device class (`unknown` without a claim) | `stay` = longer than 180 s; Σ over a class = its first sessions |
| `rbx:playSec` | at every flush, profile release and leave: the session seconds since the last credit | at most 3,600 per player per UTC day **across sessions and servers** (`profile.analytics.rbxDay / rbxSec`, session-locked); whole seconds (fractions carry); a span across 00:00 UTC is split onto the day each part was played (`Recorder.countOn`); New Player Mode and non-saving sessions never; the time before the profile loads (loading screen) is credited at the first credit. Avg capped minutes per user = `rbx:playSec / 60 / dau` |
| `rbx:coplay` | once per player per UTC day (unique-surface bit `coplay`, `AnalyticsMarks.markSeen`) | intentional co-play: joined by following a friend who is HERE (`FollowUserId`), joined from a friend's invite while the inviter is here (`JoinData.ReferredByPlayerId`, set by `SocialService:PromptGameInvite` — the INVITE FRIENDS / HUD INVITE flow), was followed / invited in to (host), or a VIP private server (`PrivateServerOwnerId ≠ 0`) with someone else here. Friends who merely share a server are not intentional |
| `rbx:coplayVia:<follow\|invite\|host\|private>` | with each `rbx:coplay` | the path that counted it (first path of the day) |
| `rbx:day:<2-28>` | `markActive`: active on day N of the cohort (once per day, carry-overs included) | play days per user D2–7 = Σ_N (`rbx:day:N` / cohort N), D8–28 likewise; D1 = `r1` / previous day's `new` |
| `ops:clientRefused:FunnelStep:<rate\|malformed\|implausible\|cap\|unknown\|popup>` | each FunnelStep refusal (`AnalyticsConfig.ClientRefusalReasons`) | `ops:clientRefused:FunnelStep` keeps its pre-R122 meaning (= Σ of every reason but `cap`); `cap` = screen opens past the session cap (never counted in the base key) |

R122 keys of the other builders (documented in `AnalyticsConfig.Metrics`; owners' docs in brackets):

| Family | Keys | Meaning |
|---|---|---|
| `retention` | `rnotify:plan:<cashFull\|streak\|missions>`, `rnotify:sent:<kind>`, `rnotify:result:<ok\|throttled\|rejected\|http\|nokey\|off\|dry>`, `rnotify:status:<kind>:<400\|401\|403\|404\|429\|4xx\|5xx>` (R136: why Roblox refused a send; 400 = notifications off / under 13), `rnotify:drop:<late\|rejoined\|replaced>`, `rnotify:join:<kind>`, `rnotify:promptAt:<manager\|area2\|other>` | return notifications (`Server/Retention/ReturnNotify*`, `docs/retention.md`): queued at leave, sent through Open Cloud by exactly one server, results (`dry` = Studio / no secret), drops, joins from `launch_data rn:<kind>` (also `r<N>:notify` via `NotifyLaunchData`), opt-in card moments |
| `retention` | `luckyDeal:<shown\|buy\|close>:<pass2x\|autoclick\|boost30\|pack\|skip>` | paid Lucky Button DEAL card: walking in shows it, only BUY opens the Robux prompt (`docs/lucky-buttons.md`) |
| `social` | `friends:hud:<shown\|tap>`, `friends:moment:<shown\|invite\|later>` | HUD INVITE button (once per session) and the invite moment after area 2 (`docs/social.md`) |
| `health` | `cp:<Class>:bootStep:<Loaded\|Client\|Profile\|World\|Plot\|Assets>:<bucket>` (BootSeconds buckets `<5`, `5-10`, `10-15`, `15-20`, `20-30`, `30-45`, `45+`), `cp:<Class>:bootStepS:<step>` (summed seconds; avg = ÷ the step's bucket total), `cp:<Class>:bootEnd:<ready\|budget\|tap\|auto>`, `cp:<Class>:bootDrop` | loading-screen step completion seconds and the hand-off reason per device class (ClientPerf wire v4, once per session; `bootDrop` = refused boot blocks: malformed or a second boot in a session). Report table **Client boot steps by device** (`clientBoot`, after Client memory): one row per class, value = avg boot seconds, every step's avg + p50, hand-off shares, refused blocks (`docs/performance.md`) |

Report: the **Roblox algorithm scorecard** (`algorithm`, right after Retention; built only when the
range has players). One row per signal with our value, the window it covers, the goal, the raw
numbers and a verdict **tone** (`AnalyticsReport.Tones`): `good` ON TARGET, `watch`, `bad` BELOW
TARGET (vs `AnalyticsConfig.Algorithm.Targets`; bounce rows are lower-is-better), `partial` PARTIAL
DATA (coverage under 98 %: some sessions ran on pre-R122 servers, an undercount; D1 / spend / Robux
come from older counters and keep their verdicts). **R135 denominators:** bounce divides by the
first sessions R122+ servers classified (Σ `rbx:bounceDev:*`, recorded at the same session end as
`rbx:bounce:*`) — never `ftue:joined`, which also counts old-server and still-running first
sessions; playtime / qualified sessions / co-play divide by the R122+ builds' player-days (Σ
`build:<b>:dau` of builds with any non-zero `build:<b>:rbx:*` slice, clamped to `dau`) when coverage
is under 98 %. Both then keep a real verdict plus a `SAMPLE: R122+ servers only (…)` note; PARTIAL
remains only when a mixed range has no build slices and for the return-day rows. (The 2026-11-01
17:33 report read bounce 5.9 % / 9.6 %, playtime 1.6 min, qualified 0.14, co-play 2 %; on the
R122+ sample they were 21 % / 35 %, 5.9 min, 0.51, 7 %.) `na` (a missing denominator or an incomplete
window — never 0), `info` (PTR: Creator Hub only). Rows: PTR · bounce < 60 s · bounce 61–180 s ·
play days D1 · D2–7 · D8–28 (n/a until the analytics history reaches 28 days before the range;
the plan loads every cohort offset 1..28) · capped playtime (min per player-day, uncapped beside
it) · qualified sessions per user · co-play days per user (+ paths) · spend days per user
(`payers / dau`) · Robux per user (`robux / dau`) · R122 coverage. Bars = attainment of the goal.
Ours cover every player of the range per player-day (Roblox: RfY joiners only), so read them as
directional and compare builds with `build:<release>:*` (see the scorecard doc).

### Rush boosts + Friends (owner R78, `docs/social.md`)

Retention family (RushService): `rush:grant:<rookie|comeback>`, `rush:sec:<rookie|comeback>`
(boosted seconds actually played per session; avg minutes = sec / 60 / grant),
`rush:done:<rookie|comeback>` (the timer ran out while playing), `rush:awayDays:<2-31>` (days away
at a comeback, 31 = 31+). Social family (FriendService): `friends:boost:<0-5>` (Roblox friends
found in the server at join), `friends:pair`, `friends:checkFail`,
`friends:invite:<prompted|sent|closed|unavailable|failed>` (client report, rate-limited),
`friends:inviteTo` (amount = recipients), `friends:ref:<new|paid|queued|duplicate|full|capped|seen|
self|notNew|queueFail|delivered>`. Referral gems count as `earn:gems:referral`. Screen ids:
`open:Friends`, `openFrom:Friends:hub`.

### Nuke Pass (owner R78, `docs/nuke-pass.md`)

Retention family (PassService):
- XP: `pass:xp:<starter|daily|chest|trophy|play|admin|other>` (amount = XP).
- Progress and claims: `pass:tier:<1-30>`, `pass:claims:<free|premium|overflow>` (amount =
  rewards), `pass:claim:<free|premium>:<1-30>`, `pass:claimAll`,
  `pass:auto:<free|premium|overflow>` (end-of-season auto-grant).
- Premium: `pass:premium:<granted|grace|fallback|admin>`, `pass:premiumTier:<0-30>` (the tier when
  premium was bought), `pass:policyGems` (premium spins and eggs paid as gems).
- Seasons: `pass:season:<seasonId>` (registered ids).

The premium funnel is the revenue family's `prompt:NukePassPremium:pass` →
`purchase:NukePassPremium:pass` (source `pass`). Reward currency counts as `earn:<currency>:pass`.
Screen ids: `open:NukePass`, with source `hud`, `offer` or `quests`.

### Revenue and receipts

`MonetizationService.setReceiptAccounting` runs `Revenue.accountingHooks()`:
`onGrant` (no yield, same profile commit as the grant) captures the record (product, Robux, UTC
day, prompt source, device, area, rebirths, staff), marks the payer-day bitmap and parks it in
`profile.analytics.outbox[PurchaseId]`; `onDurable` journals it once in the permanent ledger
(`receiptV1:<yyyy-mm>:<shard>` — the id and the counters in ONE UpdateAsync, so replays never
double-count) and clears the outbox entry. Failures stay in the outbox and are retried at every
flush and on the next profile load. The report reads the ledger counters back with the family
keys. Studio: counted locally (never written). Game passes are counted live on `PassPurchased`
(catalogue price; a web lookup when unknown).

### Purchase funnel click step (owner R137)

Per product / pass key the revenue family reads `funnel:<key>:shown → click → prompt → bought`.
Until R137 nothing produced `click` (`Revenue.offerClicked` had no caller), so every "click 0 (0%)"
was missing data. Now:

- **Where it is observed (server, no new remote):** `MonetizationService`'s `PromptProduct` /
  `PromptPass` remote handlers fire `PromptRequested(player, key, kind, source)` after the prompt
  token bucket (`PurchasePromptConfig`, 3 burst / 0.5 s) and the catalogue-key check
  (`Validate.configKey`), **before** any prompt refusal (a prompt already open, owned, coming soon,
  still loading, New Player Mode, world locked …). `AnalyticsService.Start` connects it to
  `Revenue.promptRequested`. A BUY press therefore counts even when Roblox's prompt never opens.
- **Offer surfaces only** (`AnalyticsConfig.OfferClicks.Sources`): `shop` (Shop + Crate shop BUY;
  impressions `shop`), `offer` (HUD offer chip → DEAL card; impressions `popup`), `welcomeBack`
  (Welcome Back card; impressions `welcome`). Pad, wheel, attack, pets, teleport, event, pass and
  lucky prompts are not offer cards (Lucky DEAL cards keep `luckyDeal:*`) and never count a click;
  their prompts still count `prompt:<key>:<source>`.
- **Counted keys:** `offer:<id>:click` (CTR numerator in "Offer impressions and clicks") and
  `funnel:<id>:click`. Refusals: core `ops:clientRefused:OfferClick` + `…:<reason>` (`rate` = own
  token bucket 4 / 0.5 s behind the prompt limiter, `malformed` = wrong type / length, `unknown` =
  not a catalogue key, `cap` = `MaxPerSession` 60 per analytics session). A second press on the
  SAME offer within `RepeatSeconds` (1 s) is the same press (double tap before the prompt shows).
  Staff / New Player Mode presses are diverted (`staff:promptRequested` / `npm:promptRequested`).
- **Not a click:** a press `UI/PurchaseGuard` drops on the client (the press that opened the
  surface, or one inside its arming window) never reaches the server — by design it was not a
  deliberate BUY. A request the prompt limiter drops (mashing) is not a press either.
- **Report honesty for older days:** when the report range holds no `funnel:*:click` key at all,
  every purchase-funnel row reads `click n/a` (and the offer CTR rows `clicks n/a`) instead of
  `click 0 (0%)`; once any click is recorded in the range, real numbers (and real zeros) show. A
  zero denominator prints no percentage (no empty `()`). Row ids and values are unchanged. A
  range that straddles the R137 deploy undercounts clicks for its earlier days.
- Read it as: `shown → click` = did players press BUY on the card (vs "saw it and ignored it");
  `click → prompt` (same surfaces: `prompt:<key>:shop|offer|welcomeBack`) = presses the server
  refused; `prompt → bought` with `promptClosed*` / `promptDwell:*` = pressed BUY, then closed
  Roblox's prompt.

## 5. Recorder API (for other systems)

All recorders: never throw, never yield, safe before Start; New Player Mode and staff diverted.

```lua
local AnalyticsService = require(ServerScriptService.Server.Services.AnalyticsService)

-- Generic, allowlisted by AnalyticsConfig.Metrics (player may be nil for server-wide events):
AnalyticsService.tycoon(player, "rename")
AnalyticsService.retention(player, "daily:claim:" .. day)        -- 1..7
AnalyticsService.retention(player, "wheel:slice:" .. sliceId)    -- register "sliceId" first
AnalyticsService.pets(player, "equipBest")
AnalyticsService.crates(player, "boost:" .. boostKey)
AnalyticsService.attack(player, "launch:revenge")
AnalyticsService.event(player, "sticker:" .. n)                  -- 1..20
AnalyticsService.social(player, "visit")
AnalyticsService.record("attack", player, "hitCash", amount)

-- R57 worlds family (generic; most callers use the typed world helpers below):
AnalyticsService.worlds(player, "portalLocked:dino")

-- Exact ids for a <kind> (call once in your Start):
AnalyticsService.registerIds("eggId", function(id) return EggConfig.Eggs[id] ~= nil end)

-- Typed tycoon helpers (B5 TycoonService / PlotService / Offline / Rebirth):
AnalyticsService.plotAssigned(player, plotIndex)
AnalyticsService.padBought(player, padId, skipped?)               -- Unlock pads report their area
AnalyticsService.producerClick(player, producerId)
AnalyticsService.producerIncome(player, producerId, cash, automated)
AnalyticsService.producerUpgraded(player, producerId, fromLevel, toLevel, mode?)  -- "1"|"10"|"max"
AnalyticsService.areaReached(player, area)                        -- deduped per run
AnalyticsService.rebirthed(player, rebirthsAfter, tokens?)
AnalyticsService.offlinePaid(player, seconds, cash)
AnalyticsService.offlineDoubled(player)
AnalyticsService.tutorialStep(player, step, done?)
-- padBought / producerClick / producerIncome / producerUpgraded take ANY world's ids (R57).

-- Typed world helpers (R57; W4 WorldService, W3 TycoonService / RebirthService / OfflineService):
AnalyticsService.worldUnlocked(player, "dino", "area" | "rebirth" | "legacy" | "admin")
AnalyticsService.worldTravelled(player, worldId, "portal" | "menu" | "popup" | "chip" | "admin" | "respawn", firstVisit)
AnalyticsService.worldTravelFailed(player, worldId?, travelReason)   -- unknown → "unknown" / "other"
AnalyticsService.worldPortalLocked(player, "dino")                  -- throttled inside (10 s)
AnalyticsService.worldAreaReached(player, "dino", area)             -- deduped per session per run
AnalyticsService.worldRebirthed(player, "dino", rebirthsAfter, amber?)
AnalyticsService.worldRebirthShop(player, "dino", upgradeKey)
AnalyticsService.worldOfflinePaid(player, "dino", seconds, bones)
AnalyticsService.worldOfflineDoubled(player, "dino")

-- Typed pets / crates:
AnalyticsService.eggHatched(player, eggId, { { petId = "GlowSlime", rarity = "Common" } }, auto?)
AnalyticsService.crateOpened(player, crateId, "gems" | "robux" | "free", { { kind = "boost", rarity = "Epic" } })

-- Offers (server-side observations; client renders go through ClientAnalytics.offerSeen;
-- client BUY presses on offer surfaces are counted automatically via PromptRequested, R137):
AnalyticsService.offerShown(player, offerId)  AnalyticsService.offerClicked(player, offerId)

-- Health: a server loop's Luau time (system ids in AnalyticsConfig.Health.Systems):
local t = os.clock(); tick(); AnalyticsService.systemTime("Producers", os.clock() - t)
AnalyticsService.liveHealth()   -- { fps, heartbeatMs, memoryMb, players, avgPingMs, uptimeSeconds, systemsMsPerSecond, ... }
```

Wired automatically (no caller work): sessions, retention, devices, the economy
(`PlayerDataService.CurrencyChanged`), the purchase funnel + receipts (MonetizationService
signals, incl. R137 `PromptRequested` → the offer click step), client reports, admin reports,
server health, flush loop, shutdown drain.

### Client API (`src/client/Analytics/ClientAnalytics.luau`)

```lua
ClientAnalytics.step("hudShown")                      -- or "loadingDone" (once each)
ClientAnalytics.screenOpened("Shop", "hud")           -- AnalyticsConfig.ClientFunnel.Screens / Sources
ClientAnalytics.tutorialShown(3)
ClientAnalytics.offerSeen("StarterPack", "starburst", true)   -- newVisit on the first card of a visit
ClientAnalytics.plotReady(secondsSincePlotAssigned)
ClientAnalytics.worldPopup("dino", "shown" | "go" | "later" | "lockedPreview")   -- R57 WORLD UNLOCKED popup
```
`ClientAnalytics.Start()` must run once at client boot (device + perf reporters).

## 6. Adding metrics (a new system)

1. Add the key pattern and its meaning under the family in `AnalyticsConfig.Metrics`
   (recorder families: tycoon, worlds, retention, pets, crates, attack, event, social). Grammar: parts
   split on `:`; `literal`, `<a|b|c>` (one of), `<lo-hi>` (whole number), `<kind>` (an id kind).
2. A new `<kind>`: either use a built-in kind (`padId`, `producerId`, `area`, `feature`,
   `upgradeKey`, `rarity`, `screen`, `source`, bucket kinds) or register it at Start with
   `AnalyticsService.registerIds(kind, isValid)`. Until registered, an identifier-shaped value is
   accepted for at most 64 distinct values per kind (then `other`).
3. Optional side effects: `AnalyticsConfig.KeyHooks[family][head] = { unique = surface, firstDay = milestone }`
   (surfaces / milestones are append-only lists in `AnalyticsConfig.Unique` / `FirstDay`).
4. Call the recorder from the server success path. An undocumented key is refused and shows in
   the report's "Data quality" table as `ops:badKey:<family>`.
5. If the metric deserves its own table, add it to `ReportSections` (pure; tested by
   `tests/analytics-report.luau`). `tests/analytics-recorders.luau` fails if any recorded key is
   undocumented.

## 7. Report shape (for the admin Analytics tab)

Remote `AnalyticsRequest(requestId: integer, range: "today" | "7d" | "30d" | "all")` →
`AnalyticsReport(requestId, payload)`:

```lua
payload = { ok: boolean, code: "Ok" | "Loading" | "RateLimited" | "BadRequest" | "NotAuthorized" | "Error",
            range: string?, summary: Summary?, done: number?, total: number? }   -- Loading = progress
Summary = { range, from, to, days, generatedAt, source ("datastore" | "memory"), partial, note,
            exporterVersion, windowComplete, openDayElapsedSeconds?,
            headline = { [key] = number },          -- AnalyticsReport.HeadlineOrder / HeadlineLabels; -1 = n/a
            tables = { { id, title, note, total, more?, rows = { { id, label, value, display, extra, share, tone? } } } },   -- tone (R122): AnalyticsReport.Tones
            daily = { { day, dau, new, sessions, robux, payers, pads } },
            families = { [family] = { [key] = number } },   -- ≤ 3,000 counters (pinned first)
            truncated, rawId }
```

Client side: `AnalyticsReport.parse(payload.summary)` (defensive), `AnalyticsReport.toText(summary)`
(COPY FOR AI, ≤ 130,000 chars), `AnalyticsReport.formatHeadline(key, value)`,
`AnalyticsReport.sectionTitles(summary)`. COPY RAW DATA: `AnalyticsRawRequest(requestId, rawId, page)`
→ `AnalyticsRawPage(requestId, { ok, code, page? })`; `AnalyticsReport.parseRawPage` /
`rawText`; `RawPaging.decide` for the dialog's page buttons.

Headline cards: DAU, peak DAU, player-days, sessions, average / median session, new players,
D1–D30, tutorial done (manager), reached area 2, Robux, purchases, payers, first-time payers,
ARPDAU, ARPPU, conversion, pads bought, rebirths.

Sections (each only when it has data): Retention (cohort denominators + carry adjustment), Roblox
algorithm scorecard (R122; tone rows render tall in the admin tab: coloured value, verdict tag
beside the attainment bar, two wrapped detail lines; COPY FOR AI prints "25% · WATCH"), New
player funnel, First sessions at leave, D1 / D7 by first-day milestone, Unique players per surface,
Session length, Sessions per player, Devices, Sessions by hour, Area pacing (first run vs target),
Where sessions end, Pad purchases, Slowest pads, Producers, Income share, Level marks, Tutorial,
Rebirths, Offline earnings, Tycoon extras, Products & passes, Purchase funnel, Revenue by source /
device / area / rebirth tier, Abandoned prompts, First purchases, Offers, Cash / gem sources and
sinks, Retention systems, Screens opened, Pets, Crates, Attack, Event, Social, Server health,
Server systems, Remote traffic, Client performance / memory by device, Client boot steps by device
(R122), Builds, Data quality,
Report coverage.

Authorization: `AnalyticsAuth` — `AdminService.isAuthorizedAsync(player)` / `isAdmin(player)` when
that module exists (B14), else Studio or the experience owner (`game.CreatorId`). Re-checked on every
request and before every reply.

## 8. Security and performance

- Clients never report their own progress, money or purchases. Client claims (FunnelStep,
  OffersSeen, ClientDevice, ClientPerf) pass token buckets, `typeof` checks, exact allowlists and
  per-session caps; ClientPerf numbers are validated and clamped; refusals are counted
  (`ops:clientRefused:<remote>`, and since R122 `ops:clientRefused:FunnelStep:<reason>` from a
  fixed reason list). R137 offer BUY presses are observed server-side on the already validated,
  rate-limited prompt request (no new remote), with their own bucket, id allowlist and per-session
  cap (`ops:clientRefused:OfferClick:<reason>`).
- R122 co-play reads only server facts (`FollowUserId`, `GetJoinData().ReferredByPlayerId` validated
  as a whole positive id ≠ self, the friend's presence in this server, `PrivateServerOwnerId`); the
  capped playtime is server clock only (`os.clock` spans, `os.time` day split), never a client value.
- Keys are built only from config ids (KeySpec, `AnalyticsLogic.part`), ≤ 72 chars, ≤ 2,500 keys per
  family per day (overflow → `_other`), sums clamped at 1e300.
- DataStore: one UpdateAsync per changed family per minute, a budget reserve keeps profile saves
  first, reads retry with backoff, caches bound memory, never written from Studio.
- Hot paths (producer income, clicks, currency changes) are O(1) after the first call per session:
  memoized key strings, cached exclusion verdicts, no per-call allocation beyond the counter add.
- Roblox forwarding is token-bucketed under the per-server event limit; producer income is batched
  into one economy event per player per flush.

## 9. Profile fields (`profile.analytics`, owned by analytics, reconciled by ProfileLogic)

`first, last, payFirst, payLast` (UTC days) · `robux` · `marks` (first-day milestone bits) ·
`seenDay, seen` (unique surfaces; R122 bit `coplay` behind `rbx:coplay`) · `ftue` (funnel bits) ·
`play` (play seconds) · `runAt` · `carry` · `sessions` · `rbxDay, rbxSec` (R122: the UTC day and
the seconds already credited to `rbx:playSec` that day, ≤ 3,600; reconcile clamps to the cap) ·
`staff` · `payDays` (sparse payer-day bitmap) · `outbox` (receipt accounting). Never sent to the client. Reference sanitizer: `AnalyticsMarks.reconcileAnalytics`.

## 10. Tests

`./scripts/test-logic.sh` runs `tests/analytics-logic.luau` (keys, counters, stored shapes, plan,
buckets, validators, marks, receipts, health math, config), `analytics-store.luau` (flush / merge /
budget / load / compaction / Recorder / journal idempotency), `analytics-recorders.luau` (sessions,
funnel, tycoon helpers, economy, revenue, client reports, retention + carry-overs, exclusions,
every key documented), `analytics-report.luau` (headlines, sections, COPY FOR AI, parser, stress
trimming, raw pages, labels), `analytics-client-perf.luau` (wire round trip, hostile payloads,
ingest), `analytics-roblox-signals.luau` (R122: Roblox buckets, capped credit + midnight split,
session / bounce counters, cap across sessions, co-play paths, `rbx:day:<n>`, FunnelStep refusal
reasons, profile fields, every key documented) and `analytics-algorithm.luau` (R122 scorecard on
`analytics-fixtures/AlgorithmFixture`: plan offsets, row order / values / verdicts / bars, D8–28
n/a → number, PARTIAL on mixed builds, n/a denominators, parser tones, COPY FOR AI).
