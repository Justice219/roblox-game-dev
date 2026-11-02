# Harvest Feast — the Thanksgiving event (B11)

Owner R1: *"start building like a Thanksgiving event as well"*. Spec §10. Window
**2026-11-01 00:00 → 2026-12-01 00:00 UTC** (`EventConfig.Season`, the same instants as the Acorn
packs / Turkey Lure sale window in `MonetizationConfig`, pinned by `tests/event-logic.luau`). The owner
can force it on / off per server from the admin panel (`HarvestForce`).

## The loop

1. **Golden Turkeys** wander the hub event square and every present player's plot road.
2. **Catch** one (console + mobile first, owner R11): **walk into it**, press the platform action
   `EventCollect` (gamepad **A** / E / the touch **CATCH!** button while a turkey is near — B16's
   ActionMap; until that action exists each turkey shows a *Catch!* ProximityPrompt instead), or
   click / tap the turkey itself (enlarged hitbox):
   **4–9 acorns** and a **25 %** chance at a **Feast Sticker** roll.
3. **20 stickers** fill the **Feast Sticker Sheet** (HUD *Event* button → screen `HarvestFeast`).
   A full sheet **redeems the Gobble Bomb pet** (B9 `gobble_bomb`) once per season.
4. **Acorns** buy **Harvest Egg** hatches (B9 `harvest_egg`, 30 acorns, via B9's egg window), **plot decorations** (built on your
   plot with the LEGO build-in, kept forever) and **boosts** in the **Harvest Shop** (`EventShop`).
5. Robux: **Acorn Basket** (100), **Acorn Wagon** (400), **Golden Turkey Lure** (a guaranteed-sticker,
   3x-acorn turkey that waits on your plot; a missed lure comes back next session). The lure is a
   **paid random item** because of its guaranteed sticker roll. `MonetizationConfig.TurkeyLure.paidRandom = true`
   makes the server refuse the prompt for a restricted or unknown policy. A known restricted refusal
   is counted as `lure:refused:policy`, and the toast reads `EventConfig.LurePolicyText`. In the
   EventShop the lure card is locked as "UNAVAILABLE" with that text. A lure that still reaches a
   restricted or unknown catcher (bought before the answer changed) pays the **fixed** reward:
   `AcornsMax × LureMultiplier` (27) acorns, no sticker and no random draw
   (`EventLogic.rollReward(..., paidRandomAllowed)`, analytics `lure:fixed`). Natural turkeys are
   free and unaffected. Tests: `tests/event-logic.luau` and `tests/paid-random-policy.luau`.

Tuning (`tests/event-logic.luau` simulation): a full sheet takes **~130 natural turkeys** ≈ 4 hours at
~30–35 turkeys / hour (plot every 90–170 s, hub every 35–70 s, up to 3 in the hub).

### Starter stickers (owner R97, 2026-10-31)

"start people off with like 3-4 filled in": while the event runs, every player gets the **3 commonest
stickers free, once per season** (`EventConfig.StarterStickers` = highest `RarityWeight`, ties → lowest
slot: Roast Turkey, Pumpkin Pie, Corn Cob). `EventLogic.grantStarters(event, seasonId)` tops the sheet
up to `EventConfig.Starter.Count` (3) with starters it does not own yet: a new sheet gets 3, a sheet with
1–2 stickers is topped up to 3, a sheet with 3+ gets none. It only ever ADDS stickers and stamps
`profile.event.starterSeason` (even when nothing was needed), so it is idempotent across joins and
servers; a new season (or the real launch after an October `_preview`) grants again. EventService runs
it after `ensureSeason` on profile load and when the event turns on mid-session; toast
**"You got 3 free stickers to start!"**. The Gobble Bomb still needs all 20.

### Turkeys stand ON the ground (owner R96, 2026-10-31)

"the turkey i in the ground": the template's PrimaryPart (Hitbox) made `Model:GetPivot()` the hitbox
centre (mid-bird) — a Model with a PrimaryPart ignores `WorldPivot` — so clients planted the bird's
middle on the road and the prompt sat at ground level. Fixes:
- `EventConfig.groundFrame(pivot, boxes)` (pure, tested) measures a model's real feet (lowest point of
  its visual parts' oriented boxes). `EventDecor.ensureTurkeyTemplate` stands the Hitbox on the feet and
  sets `Hitbox.PivotOffset` so the pivot IS the feet; `TurkeyRenderer` re-measures the feet itself and
  places every part relative to them.
- Server waypoint probe (`TurkeySpawner`) uses `RespectCanCollide`: turkeys stand where a character's
  feet would, never on an invisible trigger / hitbox.
- Client ground follow: each visible turkey re-probes the walkable surface at `GroundHz` (8) and lifts
  onto curbs / bed edges between waypoints within `GroundUp` (1.6) / `GroundDown` (2.5)
  (`EventConfig.groundSnapY`), eased at `GroundEase`.
- The peck nod is lifted by the measured toe dip; the bob only lifts; the Catch! prompt hangs on a
  `PromptAnchor` attachment `PromptLift` (0.6) above the hitbox top.
- Plot turkeys spawn on the owner's plot **in the world they are in** (`WorldLayout.plotToWorld(...,
  worldId)`, that world's plot length + area); when the owner travels, their plot turkeys leave
  (`despawn` reason `"moved"`) and a pending lure respawns on the new plot next tick.
- QA runner (lead): `STUDIO_LOCK_OWNER=lead python3 tools/qa/r96_feast.py` (probes bottom-vs-ground
  gaps + prompt height on a plot and a hub turkey, R97 new / top-up grants, sheet + device matrix).

## Files

| File | Role |
|------|------|
| `src/shared/Config/EventConfig.luau` | Season window, turkey tuning, rewards, the 20 stickers (rarity), shop rows, decor slots, replication names, **path maths** (`compilePath` / `pose`) and `parseTurkey` |
| `src/server/Event/EventLogic.luau` | Pure rules: season rollover, sticker roll with dupe protection, rewards, catch / redeem / shop checks, the 1 Hz spawn scheduler, wander points |
| `src/server/Event/TurkeySpawner.luau` | Live turkeys (paths only, no Instances), ground raycasts, counts |
| `src/server/Event/EventDecor.luau` | Turkey template (Blender mesh or primitive fallback + Hitbox + sparkles), hub decor by date, plot decorations |
| `src/server/Event/Lazy.luau` | Guarded lazy requires of other builders (PetService, PlotService, BoostService, AdminService, AnalyticsService, HubLayout) |
| `src/server/Services/EventService.luau` | Remotes, validation, products, admin commands, analytics, 1 Hz loop |
| `src/client/Event/EventController.luau` | EventState → renderer, catch input (auto / platform action / prompt fallback / click), FX, haptics, HUD button + badge, `EventLive` context, hub NPC prompt |
| `src/client/Event/TurkeyRenderer.luau` | Pooled turkey models, one Heartbeat + one `BulkMoveTo`, distance culling |
| `src/client/Event/EventView.luau` | Read-only view (profile.event + attributes) + coalesced `Changed` |
| `src/client/UI/Screens/StickerSheet/init.luau` | Screen **`HarvestFeast`** (HUD Event button) — 5 x 4 sheet + reward bar |
| `src/client/UI/Screens/EventShop/init.luau` | Screen **`EventShop`** — Robux packs, Harvest Egg, decorations, boosts |
| `tests/event-logic.luau` | Lune: window, weighting, rewards, redeem idempotency, rollover, checks, paths, scheduler |

## Security (never trust the client)

- `EventCollect(turkeyId)`: token bucket (6 burst, 3/s) → `Validate.key` → turkey alive → event on
  (or a paid lure) → lure owner → **once per player per turkey** → **0.6 s per-player cooldown** →
  living character → **server-side distance** from the character root to the turkey's pose *now and
  0.4 / 0.8 s ago* ≤ TapRange (22) + slack (10). The reward is rolled on the server.
- `EventRedeemSheet()`: rate limit, `canMutate` (a save that can persist), season rollover, all 20
  stickers, open (event on or within the 3-day grace), an **in-flight guard**, and `event.redeemed`
  is set only after `PetService.grantPet` returned `true` → idempotent (pinned by tests).
- `EventShopBuy(itemKey)`: rate limit, `Validate.configKey` allowlist, `canMutate`, event on, owned
  check, atomic acorn spend; boosts refund if `BoostService.grant` fails.
- Products are granted in MonetizationService's idempotent receipt step (never yields).
- Turkey paths and rewards are server data; clients only render and send ids.

## Remotes + payloads

| Remote | Direction | Payload |
|--------|-----------|---------|
| `EventCollect` | C→S | `turkeyId: string` |
| `EventRedeemSheet` | C→S | — |
| `EventShopBuy` | C→S | `itemKey: string` |
| `EventState` | S→C | `{kind="sync", active, turkeys={TurkeyWire}, caught={id}}` · `{kind="spawn", turkey}` · `{kind="despawn", id, reason}` · `{kind="caught", id, acorns, bonus, sticker, dup, count, lure}` · `{kind="refused", id, reason}` · `{kind="redeemed", petId}` |

`TurkeyWire = { id, zone = "hub"|"plot", points = {Vector3} (≤ 12), t0 (server clock), speed, pause,
life, owner (0 = anyone), lure }`. Clients animate with `EventConfig.pose(path, Workspace:GetServerTimeNow())`,
the same function the server validates against. Bandwidth: one ~150 B spawn message per turkey.

ReplicatedStorage attributes: `HarvestFeastActive`, `HarvestFeastStartsAt`, `HarvestFeastEndsAt`,
`HarvestFeastRedeemUntil`, `HarvestFeastForced`. Folder `ReplicatedStorage.HarvestFeast.GoldenTurkey`
(the client template).

## Profile (`profile.event`)

`profile.event` (B17-core landed the B11 fields; all read nil-safely):

```lua
event = {
  season = "", acorns = 0, stickers = {} :: {[number]: true}, redeemed = false,
  decor = {} :: {[string]: true},   -- owned plot decorations (EventConfig.Decor keys; bounded 32; KEPT across seasons)
  turkeys = 0,                      -- turkeys caught this season (stats / sheet screen)
  lures = 0,                        -- Turkey Lures bought and not yet caught (KEPT across seasons; 0..1e6)
  starterSeason = "",               -- owner R97: season whose 3 free starter stickers were granted ("" = never; server-only)
}
```
Snapshot: send `decor` as a key set (or array), `turkeys`, `lures`. Without `decor` the shop shows
decorations as COMING SOON (no acorns are taken for something that would not persist); without
`lures` a bought lure is kept in server memory only for the session.

Season rollover: a record with another `season` is reset (acorns, stickers, redeemed, turkeys) the
first time the event touches it during the season. An admin force-on **before** the season stamps
`"harvest2026_preview"`, so October tests never leak into the real event.

## Decor

- **Hub square** (by date): HubLayout `event = { models, collision, square, turkeySpawns, npc }`
  (B8e; same lists as `event.harvest`, which is read as the fallback together with
  `anchors.EventSquare / TurkeySpawnPoints`). `HubBuilder` never builds it; EventService builds it
  into `Workspace.HarvestFeastSquare` (placement names kept, so B9 finds the Harvest egg stand)
  while the event runs and destroys it after. The arch / pie stand sign faces get "HARVEST FEAST" /
  "PIES". The `npc` spot gets a *Sticker Sheet* prompt. Hub turkeys loop around one spawn point.
- **Plot decorations** (acorns): slots `GroundL1/L2/L3/R1/R2` (island ground outside the plot's
  front corners) and `Arch` (the garland's road-centre pivot past the entrance) from
  `HubLayout.plotDecor` (plot-local); a slot the art lacks falls back to area 1's front lawn
  (`EventConfig.DecorSlots`). Models `Harvest_HayBale`,
  `Harvest_PumpkinPile`, `Harvest_Scarecrow`, `Harvest_CornucopiaSmall`, `Harvest_Garland`,
  `Harvest_TurkeyStatue` (B8e; stud primitives until uploaded). Ground pieces snap to the ground and
  get one collision box. A fresh purchase gets B4's build-in contract (`BuildIn` = server time,
  `BuyerUserId`, tag `BuildIn`, set before parenting); rejoins show the finished set. Cleared on
  `PlotService.PlotReleased`.

## Analytics (event family)

`turkey:spawn`, `turkey:collect`, `turkey:lure`, `lure:refused:policy`, `lure:fixed`, `acorns` (amount), `sticker:<1-20>`, `stickerDup`,
`sheet:redeem`, `starter:<new|topup|reset>` (owner R97; amount = stickers granted), `decor:<decorId>` (registered id kind `decorId`), `shop:<eventItemId>` (boosts;
id kind `eventItemId` — **B13: please add `shop:<eventItemId>` to the event family**). B9 counts
`egg:harvest_egg`.

## Console + mobile (owner R11, B16 platform)

- `ActionMap.setContext("EventLive", …)` follows the HUD Event button (quick-menu wheel tile).
- Catch action `EventCollect` + context `TurkeyNear` (provider: a catchable turkey within 14 studs) —
  requested from B16; feature-detected in `PlatformConfig`, ProximityPrompt fallback meanwhile.
- `Haptics.play("Tap")` on a catch, `"Reward"` on a new sticker / redeem.
- Screens: `GamepadNav.linkList` (sheet: shop ↔ redeem), `linkGrid` per shop section with
  up/down exits, `followScroll` on the shop body, sensible `defaultSelection`; buttons ≥ 74 design px
  tall (≥ 44 pt at the phone scale).

## Admin commands (B14 `AdminService.registerCommand`)

`HarvestForce` (auto / on / off, Server tab), `HarvestTurkeyHub` (Server), `HarvestTurkeyPlot`,
`HarvestGrantAcorns`, `HarvestGrantSticker` (0 = all), `HarvestResetSheet` (Players tab),
`HarvestResetStarter` (owner R97 QA: clears the starter flag; "Grant now" or "On next join").

## Performance

Zero server Instances per turkey; one 1 Hz server loop for the whole event; one client Heartbeat and
one `BulkMoveTo` for all turkeys; turkeys beyond 320 studs are unparented, beyond 120 studs update
at 10 Hz; pooled models / prompts / FX; the auto-catch check runs at 10 Hz and only while turkeys
exist. Reduced Motion parks the waddle and the confetti.

## Boot (lead)

Server, after `MonetizationService` / `AnalyticsService`, before `AdminService`:
`EventService`, `LeaderboardService`, `BadgeService` (BadgeService requires EventService).
Client: `Event/EventController`, `Leaderboards/LeaderboardBoardController` (Init / Start like the
`Controllers/*`; they live outside `Controllers/`, so the loader needs their paths).

## Next steps

- B8e: HubLayout `event` / `plotDecor` / `leaderboards` anchors + decor meshes; B8f: `GoldenTurkey`
  mesh (pivot at the feet, faces -Z); B15: sticker / acorn / turkey / decor icons.
- B1: `EventShopBuy` remote; lead: the profile fields above.
- Next year: bump `EventConfig.Season` (id + window) and MonetizationConfig's sale window.
