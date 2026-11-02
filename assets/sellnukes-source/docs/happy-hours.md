# Nukey's Happy Hours — scheduled server mini-events (R89 §2, E-events)

Owner R89: *"use any of the video to make our game super unique and competitive"*. Spec
`docs/superpowers/specs/2026-10-31-r89-competitive-wave-design.md` §2. Original SellNukes twist on
the "server event" pattern: a **deterministic UTC schedule** every player in every server shares,
five kid-friendly events, a HUD chip that always says what is on / next, and admin overrides that
reach every server.

## The schedule (pure maths, no DataStore)

| When (UTC) | Length | Event |
|-----------|--------|-------|
| every hour at **:00** | 5 min | headline, rotating by UTC hour index: **Confetti Storm → Sprinkle Surge → Double Pops → Egg Stampede → Low-Gravity Hour** |
| every hour at **:30** | 3 min | **mini Sprinkle Surge** (luck x1.5) |

`Shared/Events/HappyHourLogic`: slot `k = floor(t / 1800)`; even slots are headlines with event
`Rotation[(floor(k / 2) + RotationOffset) % 5 + 1]`, odd slots the mini surge. Unix time is UTC
with no DST and no leap seconds, so every server and client agrees from the clock alone
(`Workspace:GetServerTimeNow()` on clients). 24 % 5 = 4, so over five days every event visits every
hour of the day: fair to every time zone (`tests/happy-hours.luau` proves both).

## The events (all rewards computed on the server)

| Event | What happens | Where |
|-------|--------------|-------|
| **Confetti Storm** | Cartoon clouds (Blender `Scenery_Cloud`) gather over you and coins (`Hub_Coin`) rain down; golden ones (`Shop_GemCluster`, 10 %) add 2 gems. Walk into them. | every world |
| **Sprinkle Surge** | Rare Surprise Batch flavours are 2x as likely (x1.5 for the :30 mini). F-flavors' `FlavorLogic.eventLuck` reads `HappyHourLogic.flavorLuckAt(now)`. | every world |
| **Double Pops** | +25 % cash (`eventCash` income modifier, offline = false) and every income pop over your producers pops **twice** (a mirrored "+bonus" pop, display only). | every world |
| **Egg Stampede** | Dino eggs (`DinoEgg`, golden-tinted 10 %) run laps along your plot road (the Golden Turkey path maths). | Dino Valley |
| **Low-Gravity Hour** | Gravity x0.9 on top of Moon Base's 0.4 + a feather-fall glide (fall speed capped at 18 studs/s), and moon rocks (`Shop_MoonRocksSmall`) float 10–16 studs up: a jump grabs them. | Moon Base |

Placement: on your own plot a drop lands in one of the two area slots beside you, at most 45 studs
away (`LuckyButtonService.pickGroundSpot(..., near, maxDistance)`, never inside a pad / producer /
building); anywhere else on a ring 8–22 studs round you, dropped onto the ground with one ray.
Pickup rewards: `incomeSeconds` (8–10 s) of your income in that world, floored at a quarter of your
current area's first pad (`LuckyButtonService.cashBurst`), fixed at spawn. Caps per player per event:
30 coins / 24 eggs / 24 rocks, at most 2 golden. Pickups never spawn during the guided first-minute
tutorial. World events only drop pickups for players **in** that world; the chip, banner and schedule
say "in Dino Valley" and offer **GO** (WorldClient travel; a locked world shows its locked preview).

## Admin (Server tab, audited) — reach every server

| Command | Effect |
|---------|--------|
| `HappyHourForce` (event, minutes) | that event live NOW for 0.5–30 min, hides any scheduled one meanwhile |
| `HappyHourStop` | stops what is live (clears a force, skips a live scheduled slot) |
| `HappyHourSkip` | skips the next scheduled slot |
| `HappyHourToggle` (on / off, confirm) | **kill switch**: OFF = no live / next events anywhere until ON |
| `HappyHourStatus` | live / next, version, skips, store + messaging health, pickup counters |
| `HappyHourSpawn` (Players tab) | one pickup of the live event next to a player (QA) |

**Cross-server override** (`Server/HappyHour/HappyHourOverrideStore`): the override
`{ v, kill, force = { id, startsAt, endsAt }?, skips = { slotStart } }` lives in DataStore
`SellNukesHappyHour_v1` / key `override`; an admin edit runs **inside UpdateAsync** on the newest
stored value with `version = max(stored.v + 1, now ms)`, is adopted at once and published on the
MessagingService topic `SellNukesHappyHour_v1`. Every server loads it at boot and polls every 90 s
(a missed message heals). A newer version always wins. Studio uses `*_Studio` names for both, so a
Studio test never touches live servers. Everything read back is size-checked and
`HappyHourLogic.sanitize`d. The server installs the override into `HappyHourLogic` (so
`flavorLuckAt(now)` and every reader honour it) and publishes it as ReplicatedStorage attributes
(`HappyHourVersion`, `HappyHourKill`, `HappyHourForceId/Start/End`, `HappyHourSkips`,
`HappyHourLive`); clients rebuild it with `overrideFromAttributes`.

## HUD + UI

* **Pill** (`UI/Screens/HappyHour/HappyHourChipScreen`, non-modal, auto-open; owner R92 Studio
  pass: the first 440 x 96 card was far too big and sat over the character on phones): one short
  stud pill `[star] LIVE: CONFETTI 3:12` (event colour) / `[star] SPRINKLES IN 15:40` or
  `STAMPEDE AT 4:00 PM` (player-local clock, blue). 52 design px tall on desktop / tablet /
  console, placed top-left above the left grid and below the Roblox top-bar buttons
  (GuiService.TopbarInset), then top-right, then under the currency stack. **Phones show only the
  LIVE countdown** — `[star] 0:13` in the event colour (owner R138: the full `LIVE: SPRINKLES 0:13`
  line took a third of an iPhone screen; the start banner names the event, a tap opens the
  schedule) — 72 design px tall (>= 44 pt tap, >= 14 pt text) and 159 wide (one fixed width, so it
  never re-places while ticking), placed beside the currency stack in the top band (right of it,
  then left of it: a measured iPhone 14 only has the left gap, 162 px), then under the INVITE row;
  under the stack, above the character's head, only as a last resort; NEXT is hidden there. The
  winning spot is the ScreenGui attribute `HappyHourChipSpot` (QA). Clear of HudZones Top / Left / Right / Bottom / TopRight, the R82 boost
  badge and the admin chip; when nothing fits cleanly it stays hidden (the start banner still
  shows). Hidden while any modal is open, in focus mode, during the guided tutorial; the reason is
  the ScreenGui attribute `HappyHourChipHidden` (QA). Redraws on change, ticks 1 Hz only while a
  countdown shows. Tap / click / gamepad-select opens the schedule.
* **Schedule panel** (`HappyHourScheduleScreen`, modal): the live event + the next headline events
  (4 rows ≈ the next 3–4 hours; the :30 mini surge is named in the subtitle) with local times
  ("Tomorrow …" past midnight), short taglines, GO for world events elsewhere; B / X / red X close.
  1000 x 560 design px: short and wide, because a phone's usable band is ~485 design px tall and
  every line must stay >= 14 pt after ModalShell's fit (measured in Studio).
* **Start banner**: `JuiceBanner` "NUKEY'S HAPPY HOUR / CONFETTI STORM! / …" held 5 s + the event
  sound (`fanfare`, `dino_happy_roar`, `star_chime`), once per event instance (admin Force
  included). Pure rule `HappyHourChipLogic.shouldAnnounce`: deferred — not dropped — under the
  loading screen / guided tutorial, retried while the banner is busy (R92 fix: the old path
  remembered the instance before showing, so a blocked banner was lost, and its 2.4 s hold was
  gone before anyone saw it).

## Remotes

| Remote | Dir | Payload |
|--------|-----|---------|
| `HappyHour` | S→C (owner only) | `{ kind = "spawn", pickup = Wire }`, `{ kind = "claimed", id, amount, currency, gems, golden }`, `{ kind = "gone", id }`, `{ kind = "clear" }` |
| `HappyHourCollect` | C→S | `(id: string)` — RateLimiter (8, 4/s), `Validate.key` + id shape, own live pickup of the live event, same world, alive, 0.15 s cooldown, distance from the server-side root to the pickup's pose now / 0.4 / 0.8 s ago ≤ 5 + 8 studs (floating rocks: 1-stud vertical tolerance, so standing under one does not count) |

Wire = `HappyHourPickupLogic.Wire { id, event, style, golden, points, t0, life }`; the client
re-validates it (`readWire`).

## Analytics (event family, KeySpec allowlist)

`hh:start:<id>` (server, once per instance), `hh:seen:<id>` (players present / arriving, once per
player per instance), `hh:spawn:<id>`, `hh:pickup:<id>`, `hh:golden:<id>`, `hh:gems` (amount),
`hh:admin:<force|stop|skip|on|off>`; screen-open `HappyHours` (source `chip`). The id choice in
`AnalyticsConfig.Metrics.event` must list every `HappyHourConfig.EventIds` id (the test fails
otherwise).

## Files

| File | Role |
|------|------|
| `src/shared/Config/HappyHourConfig.luau` | schedule, events, pickups, override limits, attribute names, client tuning |
| `src/shared/Events/HappyHourLogic.luau` | pure schedule + override maths, `flavorLuckAt`, `cashMultiplierAt`, sanitize / encode / attributes |
| `src/shared/Events/HappyHourPickupLogic.luau` | pickup wire, poses (fall / float / run = turkey path), distance, caps |
| `src/server/Services/HappyHourService.luau` | 1 Hz loop, transitions, analytics, eventCash provider, admin commands |
| `src/server/HappyHour/HappyHourOverrideStore.luau` | DataStore + MessagingService override |
| `src/server/HappyHour/HappyHourPickups.luau` | per-player pickups: placement, pricing, collect validation |
| `src/client/HappyHour/HappyHourClient.luau` | client model, boundaries, banner, effects |
| `src/client/HappyHour/HappyHourPickupsClient.luau` | pooled pickup models, walk-in claims, claim FX |
| `src/client/HappyHour/HappyHourFx.luau` | storm clouds + confetti rain, Double Pops bonus pops |
| `src/client/HappyHour/HappyHourChipLogic.luau` | pure pill copy / size / placement + banner rule |
| `src/client/UI/Screens/HappyHour/HappyHourChipScreen.luau` / `HappyHourScheduleScreen.luau` | the UI |
| additive edits | `LuckyButtonService` (`pickGroundSpot`, `cashBurst`), `Worlds/WorldGravity` (`setEvent` + glide), `Remotes`, `AnalyticsConfig`, boot lists |
| `tests/happy-hours.luau` | schedule boundaries, rotation, luck, DST-free UTC, override, pickups, analytics, gravity safety, chip |
| `tools/qa/happy_hours.py` (+ `_server` / `_client.luau`) | Studio runner → `docs/verification/r89-events/` |

## Next steps

* Quests hook (optional in the spec): a `happyHour` ProgressEvents stat (pickups caught) once
  Q-quests opens the stat list.
* A dedicated Blender "confetti cloud" / "sprinkle crate" pickup mesh if the owner wants a look
  beyond the reused meshes.
