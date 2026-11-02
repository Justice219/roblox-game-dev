# SellNukes worlds framework

How SellNukes runs more than one tycoon world (Nuke Town "main", Dino Valley "dino", World 3 ...) in ONE place,
and the checklist for adding the next world. Spec: `docs/superpowers/specs/2026-10-31-world2-design.md` (§3, §5,
§6, §18); plan: `docs/superpowers/plans/2026-10-31-world2-build.md` (§3.1 contracts).

## Framework (W1 worlds-logic, 2026-10-31)

### The idea

Every world is the same kind of linear button tycoon: areas with one producer each, one pad chain, a rebirth
track, 8 plots on a ring. So a world is **data**: an economy, a rebirth track, a geometry row, currencies, an
unlock rule, an optional link to Nuke Town, art paths and presets. Every system iterates `WorldsConfig.Order`;
nothing special-cases "dino". Ids carry a world prefix, so a bare id always tells its world.

### Modules (shared, pure — server and client)

| Module | Role |
|--------|------|
| `Shared/Config/Worlds/WorldsConfig` | The registry: `MAIN`, `Order`, `Worlds`, `get(id)`, `extra()`, `worldOfPad / Producer / BuildKey / Currency / Egg`, `unlockPasses(def, progress)`, `linkCash(worldId, rebirthsByWorld)`; load-time validation |
| `Shared/Config/Worlds/WorldTypes` | Types: `WorldDef`, `CurrencyDef`, `UnlockRule`, `LinkDef`, `WorldFeatures`, `WorldAmbience` (re-exported by WorldsConfig) |
| `Shared/Config/Worlds/WorldGeometry` | Geometry rows, no requires: origin, areaCount, plotLength, finale area / height, boundary + scenery radii; separation check |
| `Shared/Config/Worlds/MainWorld` | Nuke Town as a WorldDef (wraps `TycoonConfig.Index`, `RebirthConfig`, `AreaLayouts`, `HubLayout`) |
| `Shared/Config/Worlds/Dino/{DinoWorld, DinoRebirth, Areas/AreaNN}` | Dino Valley (economy built with idPrefix "d", the Amber track) |
| `Shared/Tycoon/EconomyIndex` | `build(spec)` -> a world's validated, frozen lookup tables (the old TycoonConfig internals) |
| `Shared/Tycoon/TycoonLogic` | `bind(index, rebirthDef)` -> `Logic`; `forWorld(id)` (cached). Module-level functions = main |
| `Shared/Tycoon/Modifiers` | `resolve(mods, rebirthDef?)` per world track; `linkCash` modifier |
| `Shared/Config/WorldLayout` | Every helper takes an optional trailing `worldId` (nil = Nuke Town, bit-identical); `worldAt`, `toWorld`, `areaCount`, `plotLength` |

### The worlds today

| | Nuke Town (`main`) | Dino Valley (`dino`) | Moon Base (`moon`, R70) |
|---|---|---|---|
| Origin / areas / plot length | identity / 10 / 520 | (6000, 0, 0) / 6 / 312 | (-6000, 0, 0) / 6 / 312 |
| Finale slot height / boundary / scenery radius | area 10, 140 / 880 / 2000 | area 6, 140 / 650 / 950 | area 6, 140 / 650 / 950 |
| Ids | pads `a<N>_`, producers `p<N>_`, build keys `A<N>_` (legacy) | `d<N>_`, `dp<N>_`, `D<N>_` | `m<N>_`, `mp<N>_`, `M<N>_` |
| Currency / tokens | `cash` (Cash, money) / `tokens` (Rebirth Tokens) | `bones` (Bones, count) / `amber` (Amber) | `moonrocks` (Moon Rocks, count) / `starshards` (Star Shards) |
| Unlock | always | Nuke Town area 3 reached OR >= 1 Nuke Town rebirth (sticky) | Nuke Town area 5 reached OR >= 1 Nuke Town rebirth (sticky) |
| Link | — (sums every world's link: up to x5.0 with two worlds) | Nuke Town cash +10 % per Dino rebirth (<= 20); Bones +5 % per Nuke Town rebirth (<= 10, x1.5) | the same numbers as Dino |
| Features (tutorial, knockdown, standName, attack, leaderstats) | all on | all off | all off |
| Layouts / hub | `{"AreaLayouts"}` / `{"HubLayout"}` (world space) | `{"Worlds","Dino","Layouts"}` / `{"Worlds","Dino","ValleyLayout"}` (WORLD-LOCAL: place with `WorldLayout.toWorld("dino", cf)`) | `{"Worlds","Moon","Layouts"}` / `{"Worlds","Moon","MoonHubLayout"}` (WORLD-LOCAL) |
| Portal anchor / ambience | — / `main`, `music_nuke_town` | `HubLayout.anchors.WorldPortals.dino` / `dino`, `music_dino_valley` | `HubLayout.anchors.WorldPortals.moon` / `moon`, `music_moon_base` |
| Eggs | the ten area eggs | `dino_egg`, `volcano_egg` | `moon_egg`, `comet_egg` |
| Products | Cash / Gems / ... | Bones packs x3 + Time Traveler Pack | Moon Rocks packs x3 + Astronaut Pack |
| Hub board / badges | Cash, Rebirths, Playtime | MOST DINO REBIRTHS / Time Traveler, Volcano Tamer | MOST MOON REBIRTHS / Moon Walker, Star Tamer |

### Id rules (validated by EconomyIndex + WorldsConfig)

* A world's `idPrefix` is `""` (Nuke Town only) or ONE lowercase letter other than `a` / `p` (Nuke Town's legacy
  letters), unique across worlds. Pads `^<p><area>_[a-z0-9_]+$`, producers `^<p>p<area>_[a-z0-9_]+$`, build keys
  `^<P><area>_%u%w*$` with `<P>` = upper(`<p>`). An Unlock pad builds the NEXT area's `<P><N+1>_EntryArch`.
* `worldOfBuildKey` answers exact pad keys first, then any well-formed key by its prefix letter (`D1_Base` ->
  "dino"), so layout-only keys resolve too.
* World ids are save keys (`profile.worlds[id]`): `^[a-z][a-z0-9]{0,15}$`, at most `MaxWorlds` (8).
* Currency keys are unique across worlds and never a non-world profile currency (`gems`, `acorns`, `robux`).

### How systems use it

```lua
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)

for _, worldId in WorldsConfig.Order do               -- tabs, Welcome Back rows, admin enums, analytics
	local def = WorldsConfig.get(worldId)
	local logic = TycoonLogic.forWorld(worldId)        -- same API as TycoonLogic.*
	local state = if worldId == WorldsConfig.MAIN then profile.tycoon else profile.worlds[worldId].tycoon
	local mods = {
		-- global modifiers (pets, passes, boosts, server, event) are shared by every world ...
		rebirths = <that world's rebirths>, rebirthShop = <that world's rebirthShop>,
		linkCash = WorldsConfig.linkCash(worldId, { main = profile.rebirths, dino = dinoRebirths }),
	}
	local perSecond = logic.incomePerSecond(state, mods)
end
```

* **Never trust the client:** `WorldsConfig.get(id)` accepts any value and returns nil for garbage — validate
  remote world ids with it (or `Validate.worldId`) before `forWorld`, which errors on unknown ids.
* **Offline limits are player-level:** every `Logic.offlineLimits` reads Nuke Town's shop keys; pass
  `profile.rebirthShop` (main) from every world.
* **Geometry:** `WorldLayout.plotOrigin(i, worldId)`, `slotToWorld(i, area, cf, worldId)`, `entranceSpawn(i,
  worldId)`, `inSlot(area, p, margin, worldId)` (the finale height per world), `plotAt(position, worldId)`.
  `WorldLayout.worldAt(position)` tells the world from a position (disc test against each scenery radius; discs
  are >= 3000 studs apart, so a client streaming one world never streams the other).
* Roblox CFrames are single precision: at the Valley's 6000-stud offset one float step is ~0.0005 studs. Compare
  world-space positions with a small tolerance, never with `==`.

### Decisions (W1)

* **Shared tunables:** every world uses Nuke Town's milestones (25 levels), cycle floor (0.1 s), level cap,
  bulk cap, offline limits and pass multipliers (`TycoonConfig.Tunables`, same table refs).
* **Number scale:** Dino keeps the exact Nuke Town pricing structure (spec §6.3), so income reaches the low
  billions when the finale area opens and the finale statue costs 46T Bones (details: `docs/economy.md`).
* **Bone Stash:** the starting-Bones levels equal the tuned Unlock prices of D1..D4 (the Bones that open the next
  area), rewritten by the tuner; `tests/worlds-config.luau` asserts it.
* **Main ambience keys:** `{ lighting = "main", music = "music_nuke_town" }` — W5's `WorldClientConfig` maps them
  (Nuke Town's music stays the context-driven hub / early / late playlists).
* **`WorldLayout.slotLocal`** is exposed as an overload `((area) -> CFrame) & ((area, worldId?) -> CFrame)` so
  existing callers that store it as a one-argument callback (`BillboardPlacement.Sources.slotLocal`) still
  type-check under solver V2.

### Tests

| Suite | Proves |
|-------|--------|
| `tests/economy-index.luau` | Main economy bit-identical to the shipped tables (4,509 snapshot values); every validation rule; index shapes |
| `tests/tycoon-logic.luau` | Original main suite untouched + the world-generic suite per world (incl. `linkCash` + Amber variants of the monotonicity invariant) |
| `tests/economy-sim.luau` | Every world's pacing (+/-20 %), run 2 <= 85 %, strictly rising prices, number scale |
| `tests/worlds-config.luau` | Registry invariants, unique prefixed ids, reverse lookups, Dino = spec §6.2 / §6.4 exactly, Moon = R69–R71 spec §2.1 / §2.2 (mirrors Dino pad-for-pad), unlock truth tables, three-world link maths |
| `tests/world-frames.luau` | Main WorldLayout parity with the shipped formulas, every world's frames round-trip, separation, `worldAt` |

## World 3 "Moon Base" — added the §18 way (W1 worlds-logic, R70, 2026-10-31)

Spec: `docs/superpowers/specs/2026-10-31-r69-moon-lucky-juice-design.md` §2. W1 added the config
(`WorldGeometry` row, `Worlds/Moon/{MoonWorld, MoonRebirth, Areas/Area01..06}`, `WorldsConfig.Order`), the four
products (published: MoonRocksSmall 3724649324, MoonRocksMedium 3724649274, MoonRocksLarge 3724649223,
AstronautPack 3724649081), the Shop MOON BASE section + Astronaut Pack HUD offer, the analytics visit surface
`w_moon`, the MOST MOON REBIRTHS board and the Moon Walker / Star Tamer badges (ids 0 until the owner creates
them). Economy numbers: `docs/economy.md` "Moon Base".

**Placeholders for art in flight:** `Worlds/Moon/Layouts/AreaNN.luau` were generated from
`PlaceholderLayouts.generate(area, "moon")` (primitive, complete, valid; marked "TEMPORARY PLACEHOLDER (W1") only
where no art file existed, so every world's layout suites and the client billboards have a layout. The area art
builders overwrite them. No `MoonHubLayout` placeholder on purpose: every consumer (HubBuilder, AreaLayouts,
PetSeams, LeaderboardService) FindFirstChild-gates it, and an EMPTY hub layout would suppress the primitive
fallback hub.

**Framework gaps a third world exposed (fixed generically, with tests):**

| Gap | Fix | Test |
|-----|-----|------|
| `worldCash` (rides EVERY currency tick) listed every registered world, so World 3 made each Bones tick +30 B for players who never saw the Moon (profile-sync's 160 B budget broke) | `ProfileLogic` snapshot `worldCash` lists only worlds the player has started (unlocked, or ever held / earned that currency); clients read a missing entry as 0 / 0; the set only grows | `profile-logic` (every known world: locked + empty absent, unlocked / paid present), `profile-sync` (an unstarted world costs 0 B; each started one <= 64 B) |
| `LeaderboardService.STAT_TO_BOARD` listed each world board by hand (a new world's board needed a code edit) | every `LeaderboardConfig` board id maps to itself (+ the legacy `CashEarned` alias) | `leaderboard-logic` (every extra world has its slot-1 rebirth board; Moon board reads worlds.moon only) |
| Tests that assumed exactly two worlds / products / boards / badges | counts updated, checks iterate `WorldsConfig` | `validate`, `leaderboard-logic`, `event-badges` |

Still owned elsewhere (each fails its suite until it lands; none is a framework gap): Moon art layouts + meshes +
rigs (W6/W7/W8), `MoonHubLayout` + `HubLayout.anchors.WorldPortals.moon` + `WorldClientConfig` Tabs / Lighting /
Music rows (W9b), BillboardSpots + `Placement.WorldRoundBodies.moon` + client screens that fall back to the first
extra world / the Time Machine look (W10b), Shop props `Shop_MoonRocks*` / `Shop_AstronautPack` (W1b),
`rocket_corgi` + Moon eggs (W11).

## Adding World 3 (spec §18 — config + art only)

1. **Geometry:** a row in `Shared/Config/Worlds/WorldGeometry` (`ROWS` + `Order`); origin so its scenery disc is
   >= 3000 studs from every other world's (`tests/world-frames.luau` checks it). `plotLength = 104 x ceil(areas / 2)`.
2. **Folder `Shared/Config/Worlds/<Name>/`** (`<Name>` = the id with a capital first letter — the simulator looks
   for `Worlds/<Name>/Areas` and `<Name>Rebirth.luau`):
   * `<Name>World.luau` — the `WorldDef` (copy `Dino/DinoWorld`): unique one-letter `idPrefix`, currency + token
     keys, `unlock`, `link`, features, `layoutFolder`, `hubLayout`, `portalAnchor`, `ambience`, `eggs`; build the
     economy with `EconomyIndex.build({ worldId, idPrefix, areas, pacing, allowedFeatures = { Rebirth = true },
     tunables = TycoonConfig.Tunables })`.
   * `Areas/AreaNN.luau` — prefixed ids (`<p>N_`, `<p>pN_`, `<P>N_`), priced like `docs/economy.md` "Pricing
     structure"; keep the `local SCALE = ...` and `baseRevenue = ...` lines (the tuner rewrites them).
   * `<Name>Rebirth.luau` — a `RebirthDef` validated with `RebirthConfig.validate`; keep the one-line
     `local STASH_VALUES = { ... }` if its shop has `startingCash`.
   * `Layouts/AreaNN.luau` (art) and `<Name>HubLayout.luau` (world-local hub).
3. **Register:** add the def to `WORLDS` and the id to `WorldsConfig.Order` (same position as in
   `WorldGeometry.Order`). Then `lune run tests/economy-sim.luau --world <id> --tune --write`, and add the world's
   number-scale row to `SCALE_CHECKS` in the simulator if it differs from Dino's.
4. **Art:** Blender builders for areas + hub; upload + `sync_meshes.py`; hub portal anchor
   `HubLayout.anchors.WorldPortals.<id>`; icons for both currencies (IconAssets); lighting preset + music in
   `WorldClientConfig`; `SoundAssets` entries.
5. **Data rows:** `BillboardSpots` (`generate-spots --world <id>`), `ManagerNpcConfig` rigs, `WorldFxConfig` rows,
   `VehicleRouteConfig` routes, products of kind `WorldCash` with `world = <id>`, eggs with `currency =
   <currencyKey>` + its `PaidRandomCurrencies` class, the currency key in the analytics economy allowlist.
6. `./scripts/check.sh`, then the Studio tour `python3 tools/qa/world2_check.py --world <id>`.

No server, client or UI code changes and no schema bump: tabs, rows, admin enums, analytics keys, travel, offline
rows and HUD currency all iterate `WorldsConfig.Order`; unknown world keys survive reconcile.

## Travel, unlock, portals (W4 worlds-travel, 2026-10-31)

| Module | Role |
|---|---|
| `Server/Tycoon/TravelRules` | PURE gate: `check(ctx) -> (ok, reason?)` in a fixed order (unknownWorld, badTarget, disabled, locked, noPlot, revealPending, dead, busy, cooldown, areaLocked, plotEmpty, noPass); garbage contexts fail closed. Unlock helpers (`progress`, `isUnlocked`, `shouldUnlock`, `unlockSource`) and the visit / play-time counters. Constants: cooldown 2 s, deadline 4 s, stream 3 s, cover 0.35 s, `RateLimiter(3, 0.5)`. |
| `Server/Tycoon/WorldService` | Server truth of where every player is (`currentWorld`, Player attr `CurrentWorld`), sticky unlock (load = "legacy", AreaReached / WorldAreaReached = "area", Rebirthed / WorldRebirthed = "rebirth", admin), the travel pipeline, respawn, kill switch, portals, `lastWorld`, the 1 Hz stats loop. Boot: `"Tycoon/WorldService"` right after `"Tycoon/RebirthService"`. |
| `Server/Tycoon/PlotService` | One plot index per player in EVERY world (claim / release set + clear plot i everywhere); builds each extra world's hub + plot frames at boot; no hub plot pads since owner R134 (removed in every hub); `routeTravel` (TeleportHub / TeleportPlot / TeleportArea from another world go through WorldService); respawn asks `WorldService.respawnCFrame`. |
| `Server/World/HubBuilder` | `buildWorld(id)` → `Workspace.Worlds.<id>.Hub` from the world's hub layout (WORLD-LOCAL → `WorldLayout.toWorld`) or a primitive Base Camp; lobby + return Time Machines (`getWorldPortal(id, "main" | "world")` → `{ trigger, prompt, arrive }`); `spawnCFrame(worldId?)`; no plot teleport pads or pad labels (owner R134). Never a SpawnLocation outside the lobby. |
| `Server/Admin/Handlers/MultiWorldHandlers` | The 14 World* admin commands (docs/admin.md §10). |

**Travel pipeline** (`WorldService.travel`, every caller): validate (`Validate.travelRequest` for the remote) →
`TravelRules.check` (refusal → `WorldTravel { phase = "fail", reason }`) → busy + `phase = "out"` → in parallel
under the 4 s deadline: `TycoonService.ensureWorld(player, w, true)` (+ the visited owner's for "plot", only if they
unlocked w), `RequestStreamAroundAsync(dest, 3)`, the 0.35 s overlay cover → re-checks (still here, same profile,
alive, enabled, same plot owner) → unseat → `PivotTo` the SERVER-computed CFrame → `CurrentWorld`, `lastWorld`,
visit counters → `phase = "in"` + analytics (`worldTravelled`). Destinations: spawn = the world's hub spawn, or the
Time Machine's `arrive` spot when travelling by portal; area = own plot area N (`PlotBuilder.world(w).areaSpawn`);
plot = plot N's entrance (own free, others need the Teleporter pass).

**Remote:** `TravelWorld(worldId, target, index?, source?)` — `source` (4th, optional) is analytics-only and
accepted only from the client allowlist `menu | popup | chip` (anything else counts as "menu"); "portal", "admin"
and "respawn" are server-only sources.

**Portals:** prompt (range re-checked on the server, +8 studs slack) and touch volume (silent for busy / cooldown /
reveal; 3 s arrival grace) → `travel(..., "portal")`. A locked lobby portal answers `fail` / `locked` at most once
per 4 s per player (the client shows the toast + locked preview) and counts `portalLocked`.

**WORLD UNLOCKED popup timing (owner R130, 2026-11-01):** the unlock itself is unchanged (Dino at Nuke Town
area 3, Moon at area 5, sticky; the chip, Teleport tab, NEW dot and portal work at once), but the popup no
longer OPENS BY ITSELF in the area that unlocked the world. Live data: at area 3 (~minute 14) 19 of 41 players
pressed GO NOW, landed in Dino Valley at zero Bones, stayed ~2.3 min, and 15 of the 41 never bought area 3's
first pad. Rule (`WorldClientLogic.unlockPopupOwed`, client display logic; `tests/world-client.luau`):
owed when the world is unlocked AND (Nuke Town area >= `popupArea` = unlock area +
`WorldClientConfig.Unlock.PopupAreasAfterUnlock` (1) → Dino 4, Moon 6 — OR the player has rebirthed) AND
(the unlock happened this session (spec §4.2 once-rule) OR the player crossed `popupArea` this session and has
never visited the world). Still once per session, still only at a polite moment; `WorldClient.popupState()`
reports `popupAreas`, `mainArea`, `sessionStartArea` for QA. QA note: an admin relock + unlock on a fresh
account below area 4 no longer shows the popup — test at area >= 4 (or after a rebirth).

**Kill switch:** ReplicatedStorage `WorldEnabled_<id>` (default true). Off → travel refused ("disabled") and
everyone inside goes to the lobby (`sendHome`) with a toast; runtimes keep earning; a respawn while off lands home.

**Rejoin:** `CurrentWorld = "main"` at join (R13 lobby + R16 reveal untouched); `profile.lastWorld` is written on
every travel, on `ProfileReleasing` and before a New Player Mode swap (`ProfileUnloading`, which also sends the
player home); the client's rejoin chip reads it once after the reveal.
