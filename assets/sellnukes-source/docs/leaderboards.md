# Global leaderboards + badges (B11)

Spec §4: the hub shows **top cash earned, top rebirths, top playtime**. Pattern: RoBeasts
`LeaderboardService` / `LeaderboardLogic` / `LeaderboardBoardController` and `BadgeAwardsService` /
`BadgeAwardsQueue`.

## Boards

| Board | Value | Store | Encoding |
|-------|-------|-------|----------|
| `Cash` (slot 1) | `profile.totalEarned` (lifetime cash) | `SellNukesLB_v1_Cash` | **log**: `round(log10(v) * 1e13)` |
| `Rebirths` (slot 2) | `profile.rebirths` | `SellNukesLB_v1_Rebirths` | whole value |
| `Playtime` (slot 3) | `profile.stats.playSeconds` (PlaytimeService) | `SellNukesLB_v1_Playtime` | whole seconds |
| `DinoRebirths` (Valley slot 1, R57) | `profile.worlds.dino.rebirths` — "MOST DINO REBIRTHS" | `SellNukesLB_v1_DinoRebirths` | whole value |

A board's `world` field (nil = the Nuke Town hub) says which hub it stands in;
`LeaderboardConfig.boardsIn(worldId?)` lists a hub's boards in slot order. Sampling, writing and
reading treat every board alike (one more OrderedDataStore read per minute per world board).

All-time boards (no reset). Studio uses `_Studio` stores. Lifetime cash outgrows OrderedDataStore's
64-bit integers, so it is stored log-encoded: strictly order-preserving, ≤ 3.1e15 (< 2^53) and decoded
to 12 significant digits (`$1,000` shows as `$1K`, never `$999`) — pinned by
`tests/leaderboard-logic.luau`.

## Data flow

```
profile (server) --sample every 30 s / on leave / on close--> LeaderboardService
   ├─ encode → pending SET (throttled: changed AND ≥ 120 s since this player's last write; final = now)
   ├─ flush: budgets (profile saves first), ≤ 60 writes, same key ≥ 7 s apart, pcall, merge back
   └─ server-scope boards (Studio without DataStores)
read loop every 60 s ── GetSortedAsync(false, 25) → sanitize → names (UserService, cached) →
   ReplicatedStorage.Leaderboards/<BoardId>.Value = bounded JSON (≤ 8000 chars)
client LeaderboardBoardController ── parsePayload → stud SurfaceGui on each tagged Screen part
```

No remotes. Only real, saved progress ranks: UserId > 0, `isSavingEnabled()`, `canMutate()`, not New
Player Mode. Payload: `{ board, scope ("global"|"server"), status ("ok"|"unavailable"), updatedAt,
entries = { {rank, userId, name, value} } }` (value = decoded display value; competition ranks).

## Hub boards

`LeaderboardService` builds `Workspace.Leaderboards` (Persistent streaming): one invisible
`Screen_<BoardId>` part per board (tag `SellNukesLeaderboardScreen`, attribute `BoardId`) at
`HubLayout.leaderboards[slot] = { cf, size }` (B8e: cf = face centre, LookVector out of the face;
the board frame meshes are ordinary HubLayout models). Until the hub art defines them, a stud backing
+ trim + posts row is built north of the hub centre.

The client draws a stud card per board: coloured header (icon, title, ALL-TIME / THIS SERVER), the top
10 with gold / silver / bronze rank badges, avatar headshots (`rbxthumb://type=AvatarHeadShot`), names
and values (`$1.25M`, `12`, `3h 05m`), the local player's row highlighted, a "YOU: … · #rank" footer
(1 Hz), and loading / empty / offline states. SurfaceGuis cull at 170 studs; redraws happen only when a
payload changes. World boards (R57) are built in `Workspace.Leaderboards_<world>` at that world's hub
layout (WORLD-LOCAL → `WorldLayout.toWorld`): `ValleyLayout.anchors.Leaderboards[1]` gives the screen
face directly (`screen`, `screenSize`; stat `DinoRebirths`); without the Valley art a stud fallback
stand goes 70 studs north of the world's origin. Once a board has at least one entry, the free ranks below show as dim "---"
placeholder rows. Without them, a board with one or two names (every Studio test) read as a blank
dark panel from the plaza (World-QA H2, re-checked 2026-10-30 at 30 / 100 / 150 studs).

Admin: `LeaderboardRefresh` (Server tab) writes everyone's values and re-reads now.

## Badges

The append-only catalog contains **18 badges: 10 configured Roblox IDs and 8 unconfigured IDs**
(as of 2026-11-01). Welcome and every Nuke Town area milestone are configured; rows 11–18 remain 0.

| # | Key | Name | Requirement |
|---|-----|------|-------------|
| 1 | Welcome | Welcome to Sell Nukes! | join |
| 2–10 | Area2 … Area10 | the area's name (Nuke Stand … Mega Nuclear Facility) | `profile.tycoon.area ≥ N` |
| 11 | FirstManager | Hired Help | own any pad of kind `Manager` |
| 12 | FirstRebirth | Fresh Start | `profile.rebirths ≥ 1` |
| 13 | FirstHatch | Hello, Little Glow! | `profile.stats.hatched ≥ 1` |
| 14 | FeastMaster | Feast Master | 20 Feast Stickers (or this season's sheet redeemed) |
| 15 | TimeTraveler | Time Traveler | R57: first Dino Valley visit (`profile.worlds.dino.stats.visits ≥ 1`) |
| 16 | VolcanoTamer | Volcano Tamer | R57: first Dino finale — own `d6_golden_trex` or `worlds.dino.rebirths ≥ 1` |
| 17 | MoonWalker | Moon Walker | R70: first Moon Base visit (`profile.worlds.moon.stats.visits ≥ 1`) |
| 18 | StarTamer | Star Tamer | R70: first Moon finale — own `m6_golden_astronaut` or `worlds.moon.rebirths ≥ 1` |

`BadgeConfig.Definitions` is **append-only** (array index − 1 = bit in the `EarnedBadgesMask` player
attribute, confirmed ownership only). Qualification is read from the authoritative profile; triggers
(ProfileLoaded, EventService.StickerFound / SheetRedeemed, PetService.Hatched, tycoon PadBought /
AreaReached / Rebirthed and, for the world badges, TycoonService.WorldPadBought /
RebirthService.WorldRebirthed / WorldService.WorldChanged when exposed) only wake the check, plus a
15 s re-observe safety net.

`BadgeAwardsQueue` does one Roblox call per step: ownership in batches of 10 (`CheckUserBadgesAsync`,
≥ 6.1 s apart), metadata (`GetBadgeInfoAsync().IsEnabled`, cached 5 min), awards (`AwardBadgeAsync`,
≥ 1.25 s apart, only an explicit `true` counts). Failures back off 5 s → 5 min and re-check ownership.
**BadgeId 0 = not created yet: the award is skipped and logged once per server.** Studio never calls
Roblox (it logs "(Studio) would award"). Admin: `BadgeStatus` (Players tab).

### First five created and wired — 2026-10-31

All five were created free in universe `10773845696` through Chrome and read back as **Active**.
Their 512 × 512 PNGs live in `assets/marketing/2026-10-31-badges/`; its README records generation
prompts and provenance. Dashboard evidence: `docs/verification/creator-dashboard/first-five-badges-active.png`.
After reloading, all five uploaded illustrations rendered in the dashboard.

| Key | Name | Badge ID | Icon | Qualification |
|---|---|---|---|---|
| Welcome | Welcome to Sell Nukes! | `1262588763497037` | `01-welcome.png` | loaded real player profile |
| Area2 | Nuke Stand | `930439656495923` | `02-nuke-stand.png` | current tycoon area ≥ 2 |
| Area3 | BoomDash Delivery | `2838896599280003` | `03-boomdash-delivery.png` | current tycoon area ≥ 3 |
| Area4 | Glow Rock Mine | `1991745259308552` | `04-glow-rock-mine.png` | current tycoon area ≥ 4 |
| Area5 | Enrichment Lab | `3137687340600188` | `05-enrichment-lab.png` | current tycoon area ≥ 5 |

`BadgeConfig` stores Welcome directly and area IDs in a private frozen area-to-ID table; catalog
order and ownership bits are unchanged. Entries 6–16 remained 0 at that release. Existing ProfileLoaded / area
purchase signals wake the existing server-authoritative award queue; no client award remote was
added. Existing players receive any currently qualified badge after joining the published update.
Area qualification uses the current run, so a player who already rebirthed must reach the areas
again if they did not previously receive these badges.

The regression suite uses the shipped catalog with a fake platform worker: a fresh player receives
only Welcome, area 4 excludes Area5, area 5 qualifies for all five, and unconfigured IDs never reach
Roblox. Ownership is only marked after confirmed platform success. The dashboard IDs were read
back from the Rojo-synced edit datamodel in the already-open Sell Nukes Studio place. Version
`0.4.0` adds a WHAT'S NEW entry. **The place has not been published by this task**; the owner must
publish once, then verify an actual live join/area award. Studio deliberately suppresses real awards.

### Areas 6–10 created and wired — 2026-11-01

The next five catalog badges were created in universe `10773845696` and confirmed **Active** in
Creator Dashboard. Their original 512 × 512 PNGs and generation provenance live in
`assets/marketing/2026-11-01-badges/`; dashboard evidence is
`docs/verification/creator-dashboard/second-five-badges.png`.

| Key | Name | Badge ID | Icon | Qualification |
|---|---|---|---|---|
| Area6 | Rocket Factory | `2219908620256793` | `06-rocket-factory.png` | current Nuke Town area ≥ 6 |
| Area7 | Launch Silos | `1208252337094160` | `07-launch-silos.png` | current Nuke Town area ≥ 7 |
| Area8 | Nuke Megastore | `1173136756556691` | `08-nuke-megastore.png` | current Nuke Town area ≥ 8 |
| Area9 | Space Port | `1960543602511361` | `09-space-port.png` | current Nuke Town area ≥ 9 |
| Area10 | Mega Nuclear Facility | `4266422855011413` | `10-mega-nuclear-facility.png` | current Nuke Town area ≥ 10 |

Only the private `PUBLISHED_AREA_BADGE_IDS` map needs these IDs: the existing profile signals and
queue already handle every area. Welcome and areas 2–5 keep their IDs, catalog positions, and
ownership bits. All ten configured IDs fit one ownership-check batch. There is no new client
remote or gallery; Roblox's native award toast and experience page display the badges.

`tests/event-badges.luau` exercises the shipped catalog through the real queue with fake platform
calls: Welcome only for a fresh player, area boundaries at 5/6, 6/7 and 9/10, all ten confirmed
ownership bits (`1023`), and no metadata or award calls for any of the eight unconfigured milestones
even when their conditions are met. A current-run reset keeps already-confirmed ownership.

Qualification continues to read `profile.tycoon.area`, including while the player visits Dino
Valley or Moon Base. Higher-world progress and rebirth counts do not qualify Nuke Town area badges.
A Nuke Town rebirth resets the area to 1: players missing an area badge must reach it again, and an
unawarded queued qualification can disappear if rebirth happens before the award finishes.
Previously confirmed Roblox badge ownership remains permanent. This rollout preserves that behavior.
Publishing the updated place is required to ship the new IDs; Studio intentionally suppresses live
badge API calls, so actual awarding must be verified in a published server.

### Creating the remaining badges

1. Creator Dashboard → Sell Nukes → Engagement → Badges → Create a Badge.
2. Upload a 512 × 512 PNG, use the catalog's name/description, and keep it Enabled. Check the
   creation form's current free allowance before creating more.
3. Copy each verified URL ID into the matching catalog entry (area badges use
   `PUBLISHED_AREA_BADGE_IDS`), never reorder entries, and publish the place.
4. Players who already qualify receive the badge after joining the published update.

The eight remaining badges (rows 11–18) are Hired Help, Fresh Start, Hello, Little Glow!, Feast
Master, Time Traveler, Volcano Tamer, Moon Walker, and Star Tamer. Their IDs remain 0 until each
matching badge is created and enabled.

## Files

`src/shared/Config/{LeaderboardConfig,BadgeConfig}.luau`, `src/server/Leaderboards/LeaderboardLogic.luau`,
`src/server/Services/{LeaderboardService,BadgeService}.luau`, `src/server/Badges/BadgeAwardsQueue.luau`,
`src/client/Leaderboards/LeaderboardBoardController.luau`, `tests/leaderboard-logic.luau`,
`tests/event-badges.luau`.

## Known limits

- An ambiguous DataStore failure (write landed, call errored) is retried — harmless with SET.
- Values sampled between flush ticks reach the board within ~2 minutes (owner: refresh ≤ 60 s for
  reads; writes are throttled to protect the DataStore budget); leaving writes immediately.
- No in-game badges gallery yet (Roblox's native award toast + the experience page show them).
