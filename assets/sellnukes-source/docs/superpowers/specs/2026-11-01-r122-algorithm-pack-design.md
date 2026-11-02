# R122 — "Algorithm pack" (0.8.0) — design spec (2026-11-01)

Owner R122: *"analyze the game's current small set of analytics … come up with whatever you can in
order to maximize the game … the standards of like Roblox algorithm pool."* Autonomous decision
(CLAUDE.md rule 1). Every change ships with server + full UI + analytics + admin + Lune tests +
docs (rules 5, 6, 9), console / touch / KB-M first (rule 11), kid-friendly (rule 7).

## 0. What Roblox ranks on (sources, read 2026-11-01)

Creator Docs `discovery` (Recommended for You ranking) and DevForum "Recommended For You Algorithm
Improvements That Better Value Long-Term Retention" (2026-06-15). Signals are per-user AVERAGES over
users who joined ORGANICALLY from Recommended for You, in three windows: Day 1, Days 2–7, Days 8–28.

| Tier | Signal | Definition (Roblox) |
|---|---|---|
| Most important | Play-through rate (PTR) | users who play after seeing the tile (thumbnail / title / icon) |
| Most important | First-play bounce (negative) | users who leave after a short first play: < 60 s and 61–180 s |
| Most important | Play days per user | unique days played (D1, D2–7, D8–28) |
| Most important | Playtime per user | average time in game, **capped at 60 min per user per day** |
| Important | Intentional co-play days | days a user plays WITH friends (join / invite / private server) |
| Important | Qualified play sessions | meaningful sessions (accidental clicks and bounces filtered out) |
| Important | Spend days per user | unique days the user spends Robux |
| Important | Robux spent per user | Robux per user |

Experience notifications (Creator Docs): opted-in users aged 13+, **one per user per experience per
day**, must be personal + actionable, created as notification strings in the Creator Dashboard,
sent with Open Cloud `POST apis.roblox.com/cloud/v2/users/{userId}/notifications`
(`x-api-key`; body `source.universe`, `payload.message_id`, `payload.type = "MOMENT"`,
`payload.parameters`, `payload.join_experience.launch_data`).

## 1. Where SellNukes stands (live `SellNukesAnalytics_v1`, read-only via Studio)

10-31 (build 0.5.1, closed day) / 11-01 (build 0.7.1, 00–07 UTC):

| Signal | 10-31 | 11-01 | Note |
|---|---|---|---|
| New players / DAU | 232 / 234 | 150 / 157 | ~0 returning |
| First sessions < 2 min | 100 / 232 (43 %) | 59 / 150 (39 %) | our closest bucket to Roblox's < 60 s / < 180 s |
| Left right after plot loaded (no pad) | 46 (20 %; console 25 %) | 21 (14 %) | `ftueLeft:plotReady` |
| Client boot (loading screen) avg | phone 1.6 s, console 0.9 s | **phone 26 s, tablet 20 s, desktop 21 s, console 15 s** | 45 of 71 phone boots 30–45 s = the 30 s `ASSET_BUDGET`; 11-01 players had far higher ping |
| Playtime per DAU | 7.6 min | 6.3 min | Roblox credits up to 60 |
| Tutorial step 6 → 7 | 102 → 27 (−74 %) | 87 → 25 (−71 %) | Glow Lamp → Uncle Atom (first manager) |
| First manager (avg first-run minute) | 11.1 | 8.2 | 9 pads in, all income by hand until then |
| D1 | r1 = 5 of 232 | — | ≈ 2 % |
| Sessions with no friend in server | 252 / 266 | 178 / 181 | Friends screen opened once in two days |
| Purchases | 0 of ~120 prompts | 0 of ~70 | `promptDwell:*:lt2` dominates: walk-in Lucky Button prompts, console shop prompts closed in < 2 s |
| Notifications | 24 opt-ins | 13 opt-ins | opt-ins collected, **no notification is ever sent** |
| Data quality | — | `ops:clientRefused:FunnelStep` = 87 | reason unknown (one key for every refusal) |

## 2. The pack (one builder per section; file ownership in §8)

### 2.1 Fast first minute (bounce < 60 s) — builder W-R122-boot

Goal: a player controls their character on their plot within ~8 s on a phone on a slow connection,
and we can SEE which loading step is slow in the field.

- `Readiness`: the Assets step stops holding the bar after `ASSET_BUDGET = 6` s (was 30). Split the
  preload into **critical** (brand art, hot UI icons, this player's plot frame + owned builds + the
  CURRENT next pads) which the bar waits for, and **deferred** (every other hub / area mesh), which
  continues after hand-off in a low-priority background thread (small batches, `task.wait` between
  batches, stops when the player leaves; no per-frame Instance churn). `TIMEOUT` 45 → 20 s ("TAP TO
  CONTINUE"), `AUTO_CONTINUE` 60 → 30 s. Critical steps (Loaded, Client, Profile, World, Plot) still
  gate the hand-off; they are not skippable before TIMEOUT.
- Boot-step telemetry: the loader publishes each step's completion second + the hand-off reason
  (`ready` / `budget` = assets cut off by the budget / `tap` / `auto`) as LocalPlayer attributes;
  ClientPerfReporter sends them once per session; ClientPerfLogic counts
  `cp:<Class>:bootStep:<Loaded|Client|Profile|World|Plot|Assets>:<bucket>` (BootSeconds buckets),
  `cp:<Class>:bootStepS:<step>` (sum seconds) and `cp:<Class>:bootEnd:<ready|budget|tap|auto>`.
  Server ingest validates (numbers, finite, clamped to MaxBootSeconds, known step ids only).
- The admin Analytics health table shows the new boot-step rows (existing health section).
- Tests: tests/loading-screen.luau (budget, critical vs deferred split, new timeouts, reasons),
  ClientPerf tests for the new counters and ingest refusals.

### 2.2 Automation by minute ~4 (playtime + the step 6 → 7 wall) — builder W-R122-econ

- Garage Lab pad order becomes: Workbench → Tool Wall → Glow Lamp → **Uncle Atom (Manager)** →
  Garage Door → Mini Reactor → Paint Station → Driveway → Open Stand. The pad prerequisite chain
  follows the order (owned pads stay owned; a save that owns later pads simply gets Uncle Atom
  offered too — verify with a migration test on old-order saves).
- Re-pace with the simulator (`lune run tests/economy-sim.luau --tune --write`), Area 1 target
  stays 8 min ±20 %, every other area target unchanged. New sim assertions: the greedy first-run
  player hires the first manager by **≤ 4.0 min**, and no Garage Lab pad gap exceeds **90 s**.
- Tutorial: step 6 = `{ kind = "pad", pad = "a1_uncle_atom", text = "Hire Uncle Atom - he makes nukes
  for you, even while you're away!" }` (direct pad, not a chain); step 7 = chain "Save up and open
  the Nuke Stand!". Same 7 steps (the `tut:<n>` keys and DoneStep keep their meaning). Update the
  client-side tutorial text table + any guide-arrow / objective-chip code that assumes the old
  order, Quests starter goals that name pads, ManagerNpc / ManagerTag configs if they assume order,
  billboard / pad layout tests.
- docs/economy.md + docs/tycoon-server.md "Garage Lab opening".

### 2.3 Return notifications (play days D1 / D2–7) — builder W-R122-notify

- `Server/Retention/ReturnNotify*.luau` (logic pure + service): when a player LEAVES, plan at most
  one notification for them (Roblox allows one per day) and put it in a MemoryStore SortedMap due
  queue (`SellNukesReturnNotify_v1`, key = userId, sort key = due unix time, value = {kind,
  params, v}, expiration ≤ 2 days). Kinds (priority order):
  1. `cashFull` — offline earnings reach their cap (due = leave + the player's offline cap time;
     only when that is ≥ 1 h): "Your nuke factory is full! Come collect your cash!".
  2. `streak` — the next daily reward unlocks (due = next UTC day at the hour this player usually
     starts, ≥ 16 h after leaving): "Day {day} reward is ready - keep your streak!".
  3. `missions` — fallback ~20 h after leaving: "New daily missions + Nuke Pass XP are waiting!".
  A rejoin before the due time deletes the entry. Every running server polls once per 60 s:
  `GetRangeAsync` up to now (≤ 20 entries), claims each with `UpdateAsync` (remove) so exactly one
  server sends, sends with HttpService `RequestAsync` to the FIXED Open Cloud URL with the API key
  from `HttpService:GetSecret(NotifyConfig.SecretName)` (never printed, never sent to a client),
  `launch_data = "rn:<kind>"` (≤ 200 bytes). Per-server send limiter, timeouts, pcall
  everywhere, exponential back-off on 429 / 5xx, entries older than `MaxLateHours` dropped (a
  6-h-late "your factory is full" is still fine; a 30-h-late streak note is not).
- `NotifyConfig` (shared): `Enabled`, `SecretName`, `UniverseId`, per-kind `messageId` (owner fills
  from Creator Dashboard; an empty id disables that kind), timings, limits. Studio / no secret →
  **dry-run** (queue + analytics, no HTTP), never an error.
- Opt-in reach: the existing NotifyPrompt card is shown at a strong moment in the first minutes
  (right after the player hires their first manager, else at area 2), once per session, through the
  popup queue (R102), never over a purchase prompt. Keep the existing one-time reward semantics.
- Join attribution: `launch_data` `rn:<kind>` joins count `r<N>:notify` (existing) and
  `rnotify:join:<kind>`.
- Admin panel: notifications section — kill switch, per-kind on/off, queue size, last results,
  "send test to me" (owner only, dry-run in Studio).
- Analytics (retention family): `rnotify:plan:<kind>`, `rnotify:sent:<kind>`,
  `rnotify:result:<ok|throttled|rejected|http|nokey|off|dry>`, `rnotify:drop:<late|rejoined|replaced>`,
  `rnotify:join:<kind>`, `rnotify:promptAt:<manager|area2|other>`.
- Owner steps (documented in docs/retention.md, listed in the final report): create notification
  strings for the three kinds, create an Open Cloud API key with the user-notification write scope
  for universe 10773845696, add it as an experience secret named `NotifyConfig.SecretName`, paste
  the message ids into NotifyConfig.

### 2.4 Co-play + no accidental purchase prompts — builder W-R122-social

- HUD **INVITE** button (stud button, every input; console binding + hint glyph) with a "+10 %"
  Friend Boost badge; opens the existing INVITE FRIENDS flow (SocialService:PromptGameInvite +
  referral launch data, R78). Hidden when invites are unavailable. Placed by HudZones (phone /
  tablet / console safe areas; ≥ 44 pt).
- One invite moment per session (popup queue, low priority, non-modal toast card with INVITE /
  later): after area 2 unlocks.
- Paid Lucky Buttons never open a Robux prompt on walk-in: walking in opens a small, non-blocking
  DEAL card (product art, price, BUY + close; console: the card is not auto-focused, a bound button
  buys — never A while running). Only BUY opens the prompt. Free kinds unchanged.
- Console / touch purchase hygiene: no screen opens with GuiService selection on a BUY / Robux
  button; the press that opens a screen can never also activate a button inside it; a HUD offer chip
  tap opens its card first, BUY on the card prompts. Audit Shop, offers, pets (Lucky Eggs / Triple
  Hatch), wheel, teleport, attack (PocketRocket / Barrage / Revenge) prompt sources.
- Analytics: social `friends:hud:<shown|tap>`, `friends:moment:<shown|invite|later>`; retention
  `luckyDeal:<shown|buy|close>:<pass2x|autoclick|boost30|pack|skip>`.

### 2.5 Roblox-aligned analytics + the admin "Algorithm" scorecard — builder W-R122-analytics

- core: `rbx:bounce:<lt60|60to180>` (first sessions ending within 60 s / 61–180 s),
  `rbx:bounceDev:<class>:<lt60|60to180|stay>`, `rbx:session:<lt60|60to180|qualified>` (every
  session; qualified = > 180 s), `rbx:playSec` (session seconds credited up to 3,600 per player per
  UTC day, across sessions and servers via profile.analytics), `rbx:coplay` (unique players per day
  who intentionally co-played: joined by following a friend, joined from an invite / referral launch,
  or were followed in by a friend), `ops:clientRefused:<remote>:<reason>` (reason per refusal path,
  bounded set).
- Report section `algorithm` (ReportSections + admin Analytics tab UI + COPY FOR AI export): the
  Roblox signal table with our numbers, windows and a colour per row vs targets — PTR (Creator Hub
  only: shown as "see Creator Hub"), bounce < 60 s and 61–180 s, play days per user (D1 = r1 /
  new; D2–7 = Σ r2..r7 / cohort; D8–28 likewise, n/a until the window is complete), capped playtime
  per user, qualified sessions per user, co-play days per user, spend days per user (payers / DAU),
  Robux per user. Missing denominators are n/a, never 0.
- docs/analytics.md (every R122 key, incl. the other builders' keys from this spec) and
  docs/analytics-scorecard.md (the first live baseline from §1 + the R122 experiment record).

## 3. Not code (owner — listed in the final report)

PTR is decided by the tile: custom thumbnails (required for Home impressions) and A/B thumbnail
personalization in Creator Hub; Experience Events for Harvest Feast (up to 5 thumbnails, opt-in
reminders); notification strings + API key + secret (§2.3).

## 4. Measurement (analytics-scorecard contract)

Primary metrics per change, read on the `build:0.8.0:*` slices vs `build:0.7.1:*`, ≥ 7 complete
UTC days before KEEP / REVERT: §2.1 `rbx:bounce:lt60` / `ftue:joined` and boot p50; §2.2
`tut:7 / tut:6` and playtime per DAU; §2.3 `rnotify:join:*` and D1 (carry-adjusted); §2.4
`rbx:coplay` / DAU and `payers` / DAU (guardrail: prompts closed < 2 s must fall); §2.5 data only.

## 8. File ownership (parallel builders; lead owns everything not listed)

| Builder | Owns |
|---|---|
| W-R122-boot | src/first/LoadingScreen/*, src/shared/World/PreloadList.luau, src/shared/Analytics/ClientPerf*.luau, src/client/Analytics/ClientPerfReporter.luau, src/server/Analytics/ClientPerfIngest.luau, tests/loading-screen*, tests/client-perf*, docs/performance.md |
| W-R122-econ | src/shared/Config/TycoonAreas/Area01.luau (+ any Area tuning the sim writes), src/shared/Config/AreaLayouts/* (only if pad spots must move), src/server/Tycoon/TutorialLogic.luau, client tutorial text / objective chip, QuestConfig starter goals (if a goal names a pad), tests/economy-sim.luau, tests/tutorial*, docs/economy.md, docs/tycoon-server.md |
| W-R122-notify | new src/server/Retention/ReturnNotify*.luau, new src/shared/Config/NotifyConfig.luau, src/server/Services/NotifyRewardService.luau, src/client/UI/Screens/NotifyPrompt/*, admin notifications section (server action + client tab section), new tests/return-notify*.luau, docs/retention.md |
| W-R122-social | HUD invite button + moment (src/client/UI/Hud/*, Widgets/HudZones/HudPlacement as needed), src/server/Services/FriendService.luau, Lucky Buttons (server service + client + config), Shop / offer / prompt-source client screens for focus hygiene, tests for each, docs/social.md, docs/lucky-buttons.md |
| W-R122-analytics | src/server/Analytics/{Sessions, ReportSections, Reports, AnalyticsLogic}.luau, admin Analytics tab client UI, tests/analytics*.luau, docs/analytics.md, docs/analytics-scorecard.md |

`src/shared/Config/AnalyticsConfig.luau`: the lead pre-adds every R122 key pattern; a builder may
edit only the R122 lines of its own section. Lead only: VersionConfig, ChangeNotesConfig,
SELLNUKES_CLAUDE_DOCUMENTATION.md, docs/owner-requests.md, the Studio pass, commit.
