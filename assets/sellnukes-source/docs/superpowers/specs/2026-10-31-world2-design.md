# SellNukes — World 2 "Dino Valley" + the worlds framework (design spec, 2026-10-31)

Owner request **R57** (`docs/owner-requests.md`): *"Once you're completely done with like the main
game ... you should like separate area that the teleporter can use that you can do anytime and also
rebirth that. Just an idea. That way people, you know, we have a lot of content on launch and we can
add stuff later."*

Read with: main spec `2026-10-30-sellnukes-design.md` (§2 loop, §3 areas, §4 layout, §5 build-in,
§7 retention, §11 monetization, §13 analytics, §14 admin, §16 platforms), `docs/economy.md`,
`docs/tycoon-server.md`, `docs/world-art.md`, `docs/areas-art.md`. Implementation plan:
`docs/superpowers/plans/2026-10-31-world2-build.md`.

Every decision below was made by the lead's spec writer under hard rule 1 (decide, document, keep
building). Each has a one-line reason. Nothing here changes how the main game plays.

---

## 0. Decisions at a glance

| Topic | Decision | Why (short) |
|---|---|---|
| Theme | **Dino Valley**: a sunny prehistoric jungle valley reached by a cartoon **Time Machine** | Nothing in the 10 areas, hub or event is prehistoric. Dinosaurs + eggs fit the pet system perfectly. The main world is already an island in a sea, so a tropical world would look too similar. |
| Main world name | **Nuke Town** (the name only appears in world switchers) | World tabs need a name for the main world |
| Size | **6 areas, 59 pads, ~2.5 h first run** (150 min), 2nd run ≤ 85 % | A real second tycoon for launch. Art for 6 areas fits 3 art builders. |
| Currency | Its own currency: **Bones** (`bones`). Never converted to or from Cash | Late-game Cash (Qa–Qi) would trivialise prices that start at 1. Cash packs scale to main income. |
| Ties to the main game | Each Dino rebirth gives **+10 % Nuke Town cash** (counts up to 20 rebirths, so max +200 %). Each Nuke Town rebirth gives **+5 % Bones** (counts up to 10, so max +50 %). Plus badges, a leaderboard and Dino pets that boost both worlds. | Each world feeds the other, so playing both pays off. The caps keep both pacings sane. |
| Rebirth | Its own track: **+50 % Bones per Dino rebirth**, **Amber** tokens, a 4-upgrade **Amber shop**. A Dino rebirth resets only the Dino tycoon and Bones. | Owner: "and also rebirth that" |
| Unlock | Sticky unlock once the player reaches **Nuke Town area 3 (BoomDash Delivery)** OR has ≥ 1 Nuke Town rebirth. After that it is **available any time**. | Keeps the first-time experience (FTUE: tutorial + Nuke Stand) focused. Opens at ~23 min of play, which hooks a second goal into session 1. |
| Access | **Teleport screen world tabs** plus a physical **Time Machine** in the lobby, with a twin at the Valley's Base Camp to come back | Owner: "the teleporter can use". No new left-HUD button (owner R58). |
| Where it lives | **Same place, separate region** at world offset **(6000, 0, 0)**. **No** TeleportService sub-place. | One session lock, ~1.5 s travel, the 8-player server stays social. Owner R33 forbids opening other places, so a sub-place could never be built or tested. |
| Plots | Dino plot **i = the player's main plot i** (1:1). Built lazily on the first trip of a session and kept until the player leaves. | No second assignment and no contention. Server memory is only spent for visitors. |
| Idle | Dino managers keep earning while the player is in Nuke Town, and offline. Offline pays **per world** on one Welcome Back screen. | "Do it anytime" means progress never stops |
| Pets | Shared collection. **2 Dino eggs** (Dino Egg, Volcano Egg) priced in Bones, **8 new dino pets** + 1 exclusive pack pet | Reuses the whole pet stack. Eggs are the natural Dino hook. |
| Monetization | Existing passes apply in every world (2x Cash, VIP, Auto Clicker, Offline Max, Teleporter → other players' Dino plots, Lucky Eggs, Triple / Auto Hatch). New products: **Bones packs ×3** + **Time Traveler Pack** (one-time). | Owners of passes get more value. No double-dip pass. |
| Attack mode | Nuke Town only. Dino plots cannot be targeted. Launching is refused while in Dino Valley. | Silos live in Nuke Town (launch cinematic R54). Dino Valley is a peaceful "trip". |
| Save | Additive `profile.worlds[worldId]` + `lastWorld`. **Schema v1 → v2** so older servers open new saves read-only. | An old server's reconcile would silently drop `worlds` and save over it (data loss during a rollout) |
| Framework | **"Add a world = add config + art"**: every system iterates `WorldsConfig.Order`, and ids carry a world prefix | The owner wants to "add stuff later" (§18 checklist) |

---

## 1. Goals and non-goals

**Goals**
1. A second, self-contained tycoon with its own pads, producers, managers, billboards, build-ins,
   Blender art, currency, offline earnings and rebirth track. Any player reaches it from the Teleport
   menu or the lobby Time Machine at any time after the unlock.
2. Zero regressions in Nuke Town. The main world's ids, numbers, pacing, saves and remotes keep
   their meaning.
3. A data-driven world registry, so World 3+ ships as config + art + tuning (§18). No new systems
   are needed.
4. Every hard rule holds: stud everything, Blender models, build-in, secure + performant, full UI,
   kid-friendly, analytics + admin, console + mobile first.

**Non-goals (v1)**
* Trading Bones ↔ Cash.
* Attacks on Dino plots.
* Harvest Feast turkeys in Dino Valley. The event's `eventCash` multiplier still applies to Bones.
* Wheel / daily / time / code rewards in Bones. They stay Cash; Bones rewards are a later
  extension point.
* Cross-server visits.

---

## 2. Theme: Dino Valley

A warm, golden-afternoon jungle valley ringed by mossy cliffs, with a friendly smoking volcano on
the horizon. A time-travelling nuke start-up opens shop for the dinosaurs. Pebble nukes are carved
from glowing stones and sold at a fern market, posted by pterodactyls, powered by geysers, studied
in a fossil lab and finally fuelled by a tamed volcano. Every manager is a cute **bipedal dino in
work clothes**. Bipeds reuse the R30 manager rig groups (Torso / Head / ArmL / ArmR / LegL / LegR,
with the tail in Torso).

**Distinctness check** against what is taken. Main areas: suburban garage, wood stand, delivery
HQ, crystal mine, white lab, factory, hazard silos, mall, space port, reactor dome. Also taken:
the R55 lobby plaza, the island/sea frame, the Harvest Feast farm decor. Dino Valley's look is new:
palette fern green / sand / mossy stone / amber orange / bone cream / lava candy-orange, organic
round shapes, thatch, logs, bamboo, rope. No grey metal or hazard stripes except tiny accents.

**Kid-friendly content rules (in addition to main spec §1)**
* Dinos are round, big-eyed, smiling and wear little hats, vests or aprons. Nobody eats anybody.
  No claws or teeth shown aggressively. The T. rex chief holds a clipboard with her tiny arms.
* "Bones" are cartoon fossil bones (a chunky dog-bone silhouette in cream with an amber glint). No
  skulls are used as currency, no gore.
* Lava is candy-orange "warm jelly". Nothing burns, and touching it does nothing. The volcano
  "eruption" on the finale purchase is a confetti + bubble burst.
* No cavemen or "primitive people" caricatures. Every character is a dinosaur.
* Copy is upbeat and silly: "Fresh Pebble Nukes! Roar-some prices!", "Ptero Post: we deliver
  before the asteroid does!" (no doom framing on-screen beyond that joke). The lead may veto any
  line in review.

---

## 3. Where it lives: in-place region vs. sub-place

| Criterion | In-place region (same place) | Sub-place (TeleportService) |
|---|---|---|
| Travel time | ~1.5 s warp overlay + `RequestStreamAroundAsync` | 8–20 s Roblox teleport screen, may fail / retry |
| Session lock | One ProfileStore session, untouched | Release → teleport → re-acquire. Lock races and stolen-session edge cases. |
| Social | Same 8 players; visit friends' Dino plots | You leave your server and your friends |
| Idle in the other world | Server tick keeps paying both worlds live | Main world only via "offline" while away |
| Dev/QA | Testable in the one MCP-connected place | **Impossible**: owner R33 forbids opening other places |
| Server memory | + up to 8 Dino plots (lazy) | Separate server |
| Client perf | Streaming radius 768 → only one world is ever streamed | Separate client load |
| Monetization, analytics, admin | Shared services, no duplication | Needs a second boot, duplicate products, cross-place receipts |

**Decision: in-place region.** The Valley's world origin is **`CFrame.new(6000, 0, 0)`**. The
Nuke Town sea ends at r 2000 and the Rival Factory islands sit at r 1080, so the gap is ≥ 3000 studs
≫ 2 × `StreamingTargetRadius` (768). A client in one world never streams the other, so client
cost is unchanged. Ground top stays `y = 0`. The Valley has its own ground disc, boundary cliffs at
r 640 (invisible collision ring at r 650) and far scenery to r ~950.

---

## 4. Access, travel, respawn, rejoin

### 4.1 Unlock (sticky)
`WorldsConfig.Worlds.dino.unlock = { kind = "progress", world = "main", area = 3, orRebirths = 1 }`.
`WorldService` evaluates the rule on `ProfileLoaded` and on `TycoonService.AreaReached`. The first
time it passes it sets `profile.worlds.dino.unlocked = true` and `unlockedAt = os.time()`, saves
soon and fires `WorldService.Unlocked`. A main rebirth later (area back to 1) never re-locks.
Legacy players who already qualify unlock on their first load of the update.

### 4.2 The unlock moment (client)
* A **WORLD UNLOCKED!** stud popup opens once, at a calm moment, using the same gate as WHAT'S NEW:
  after the loading screen, Welcome Back, cinematics and purchase prompts. It shows a rotating 3D
  Time Machine (R39 ModelViewport), "DINO VALLEY UNLOCKED! A whole new world with its own Bones,
  dino pets and rebirths. Your Nuke Town keeps earning while you're away!" and two buttons:
  **GO NOW!** (default selection) and **LATER** (B closes).
* "Once" rule: the client shows it if `unlockedAt` is newer than this session's join time (the
  server stamps it). No extra remote.
* After that the **Teleport** HUD button wears a **NEW** dot until the first visit.

### 4.3 Teleport screen (the "teleporter")
The Teleport screen gains **world tabs**: `NUKE TOWN | DINO VALLEY` (stud tab buttons ≥ 44 pt,
LB / RB switch tabs, and the tab icons come from the icon pipeline).
* **Nuke Town tab**: exactly today's list (Hub, areas 1–10, other players' plots with the
  Teleporter pass).
* **Dino Valley tab**: *Base Camp* (the Valley spawn) [GO], Dino areas 1–6 (unlocked = GO; locked
  = "x / y purchases" bar like today), and other players' Dino plots (Teleporter pass, same rule as
  today: own plot always free).
* **Locked world tab**: lock art, "Reach BoomDash Delivery to unlock!" and a progress bar of main
  area-2 pads. Selecting it never sends anything.
* The screen opens on the tab of the world you are in. A world switched off by the admin kill
  switch shows "Closed for a quick fix — back soon!"

### 4.4 Time Machine portals (physical)
* **Lobby:** a big stud Time Machine stands in the main hub (a clock-face arch, chunky dials, a
  lever and a swirling portal ring that WorldFx spins; anchor `HubLayout.anchors.WorldPortals.dino`).
  It sits where the fresh-spawn view sees it within ~30° and stays clear of the R55 plaza, the
  avenues, the teleport pads and the EventSquare (`tests/hub-layout` checks this).
* **Valley:** the same model stands at Base Camp (`ValleyLayout.anchors.ReturnPortal`) with the
  sign "BACK TO NUKE TOWN".
* Both have a **ProximityPrompt** ("Travel" / "Dino Valley"; E, ButtonX or tap; HoldDuration 0;
  RequiresLineOfSight false) and a **touch volume** inside the swirl. Both go through the same
  server-validated travel. If the portal is locked: a throttled toast plus a locked-preview version
  of the WORLD UNLOCKED popup ("Reach BoomDash Delivery: 6 / 9 purchases" + OK).

### 4.5 Travel flow (server-authoritative)
1. Client intent `TravelWorld(worldId, target, index?)`. The target is `"spawn"` (that world's
   hub), `"area"` (own plot area N) or `"plot"` (plot N's entrance).
2. `WorldService` validates (§11) and marks the player busy. It replies
   `WorldTravel { worldId, phase = "out", at }`. The client starts the **warp overlay**: a full-screen
   stud swirl with a ticking clock and the world name card, 1.2 s minimum. Reduce Motion gives a
   plain fade. Controls are disabled during the warp, and the client starts preloading the
   destination world's mesh keys.
3. The server ensures the destination exists. For a non-main world that is the player's runtime
   plus plot build (`TycoonService.ensureWorld`, idempotent; a visit to another player's plot
   builds theirs). It then calls `Player:RequestStreamAroundAsync(dest, 3)`, unseats the character,
   `PivotTo`s, sets the Player attribute `CurrentWorld`, and sends `phase = "in"`. The client swaps
   the Lighting preset and music and plays the warp-in. A hard 4 s server deadline pivots anyway,
   so nobody is stranded.
4. Refusal → `phase = "fail", reason` → a friendly toast (reason table in WorldClientConfig).

### 4.6 Respawn and rejoin
* A character respawning (reset / fall) goes to the **entrance of its current world's plot**
  (`WorldService.respawnCFrame`), never back to the other world.
* **Rejoin always starts in the Nuke Town lobby** (owner R13 lobby + random plot + R16 reveal stay
  untouched). If the last session ended in Dino Valley (`profile.lastWorld == "dino"`), a small
  bottom chip "Back to Dino Valley? [GO] [X]" appears after the plot reveal for 20 s
  (gamepad: Y = GO).
* Travel is refused until `PlotRevealed` is true, so the join reveal can never be skipped or broken.

---

## 5. Plots (8 players)

* **Mapping:** the player's Dino plot index = their Nuke Town plot index (`PlotService` assigns
  once, at join). No second queue. A player without a main plot (all 8 taken, queued) cannot travel
  ("Waiting for a plot").
* **Geometry:** the same ring as Nuke Town (8 plots at yaw (i-1)·45°, origin radius 260, Base Camp
  plaza r ≤ 230, ring path 230–260). The Valley plot is **3 rows = 312 studs** long (6 slots). The
  slot frame, slot size (104 × 70), pad strip and height budget 80 are identical, and the finale
  slot D6 gets 140. So `AreaLayouts` authoring, `LayoutLogic` validation, placeholder layouts and
  billboard solving all reuse the Nuke Town contract unchanged.
* **Frames at boot:** the 8 empty Valley plot frames (path, ground, fern hedges, stone entrance
  arch with owner sign, locked slots "COMING SOON") are built at server start like Nuke Town's.
  They are static, streamed and cheap.
* **Owner content is lazy:** a player's Dino builds are restored the first time they (or a
  visitor) travel there this session, then kept until they leave. The owner's Dino *runtime* (the
  economy tick) starts at join when Dino is unlocked, even without a built plot, so idle Bones flow
  while they play Nuke Town.
* **Visitors:** walking into someone's Dino plot is free once you are in the Valley. Teleporting
  straight to another player's Dino plot needs the Teleporter pass (same rule as Nuke Town). Pads,
  clicks and upgrades are owner-only (unchanged checks).
* **Leave:** `PlotReleased` clears that index in every world.

---

## 6. Economy

### 6.1 Currency and what modifies it
* **Bones** live in `profile.worlds.dino.cash`, with lifetime `totalEarned`. Granted only by Dino
  producers (click, auto), Dino offline, Bones products and admin. Spent only on Dino pads, Dino
  producer levels and Dino eggs. Never converted.
* **Global modifiers that apply in every world:**
  * pets (one shared equip set)
  * 2x Cash pass
  * VIP
  * personal timed cash / speed boosts
  * Server 2x Cash
  * live-event `eventCash`
  * Auto Clicker
* **Per-world modifiers:** that world's rebirth multiplier and its shop (Power Production /
  Speedy Managers / Golden ...), plus the cross-world **link** (`linkCash`, §6.5).
* The **offline** cap and rate are player-level. They come from the Nuke Town shop (Night Shift /
  Sleepy Reactor) and the Offline Max pass, and apply to every world.

### 6.2 Areas and pads (ids are SAVE DATA; never rename or reuse)
* Prefix rules (validated):
  * pads `d<area>_<name>`
  * producers `dp<area>_<name>`
  * build keys `D<area>_<Name>`
* The Unlock pad of area N builds `D{N+1}_EntryArch`, which resolves to
  `Dino/Layouts/Area{N+1}.base`.
* D1's base is built when the Dino plot is first built.

Kinds:
* `B` = Build (+10 % unless noted)
* `M×n` = Multiplier
* `S×2` = Speed
* `Mgr` = Manager
* `U` = Unlock

| # | Area (id) | Producer (id, baseCycle) | Pads in buy order: `id` Name kind `BuildKey` |
|---|---|---|---|
| D1 | **Cave Workshop** (`cave_workshop`): a mossy cliff with a cave mouth, torches, stone bench | Pebble Nuke Bench (`dp1_pebble_bench`, 1 s) | `d1_stone_bench` Stone Bench B(builder, free) `D1_StoneBench` · `d1_torch_wall` Torch Wall B `D1_TorchWall` · `d1_bone_tools` Bone Tools M×2 `D1_BoneTools` · `d1_cave_paintings` Cave Paintings B `D1_CavePaintings` · `d1_fire_pit` Cozy Fire Pit M×3 `D1_FirePit` · `d1_leaf_bellows` Leaf Bellows S×2 `D1_LeafBellows` · `d1_rocky_raptor` **Rocky Raptor** Mgr `D1_RockyRaptor` · `d1_log_fence` Log Fence B `D1_LogFence` · `d1_open_market` *Open the Fern Market* U→2 `D2_EntryArch` |
| D2 | **Fern Market** (`fern_market`): a stall under a giant leaf awning | Fern Market Stall (`dp2_fern_market`, 1.5 s) | `d2_shell_counter` Shell Counter B(builder) `D2_ShellCounter` · `d2_leaf_awning` Leaf Awning B `D2_LeafAwning` · `d2_coconut_till` Coconut Till M×2 `D2_CoconutTill` · `d2_berry_baskets` Berry Baskets B `D2_BerryBaskets` · `d2_totem_sign` Totem Sign M×3 `D2_TotemSign` · `d2_mammoth_fan` Mammoth Fan S×2 `D2_MammothFan` · `d2_picnic_logs` Picnic Logs B `D2_PicnicLogs` · `d2_stego_sally` **Stego Sally** Mgr `D2_StegoSally` · `d2_bamboo_fence` Bamboo Fence B `D2_BambooFence` · `d2_hire_pteros` *Hire the Pteros* U→3 `D3_EntryArch` |
| D3 | **Ptero Post** (`ptero_post`): a treetop nest tower, parcels flown in and out | Ptero Express (`dp3_ptero_express`, 2 s) | `d3_nest_tower` Nest Tower B(builder) `D3_NestTower` · `d3_rope_bridge` Rope Bridge B `D3_RopeBridge` · `d3_parcel_baskets` Parcel Baskets M×2 `D3_ParcelBaskets` · `d3_wind_sock` Wind Sock S×2 `D3_WindSock` · `d3_ptero_flock` Ptero Flock M×3 `D3_PteroFlock` · `d3_treasure_map` Treasure Map M×4 `D3_TreasureMap` · `d3_landing_pad` Landing Pad B `D3_LandingPad` · `d3_captain_ptera` **Captain Ptera** Mgr `D3_CaptainPtera` · `d3_tap_springs` *Tap the Geyser Springs* U→4 `D4_EntryArch` |
| D4 | **Geyser Springs** (`geyser_springs`): steaming geysers, bamboo pipes, water wheel | Geyser Pump (`dp4_geyser_pump`, 2.5 s) | `d4_geyser_vent` Geyser Vent B(builder) `D4_GeyserVent` · `d4_bamboo_pipes` Bamboo Pipes B `D4_BambooPipes` · `d4_water_wheel` Water Wheel M×2 `D4_WaterWheel` · `d4_steam_whistles` Steam Whistles B `D4_SteamWhistles` · `d4_hot_springs` Hot Springs M×3 `D4_HotSprings` · `d4_pressure_valves` Pressure Valves S×2 `D4_PressureValves` · `d4_mega_geyser` Mega Geyser M×4 `D4_MegaGeyser` · `d4_para_pete` **Para Pete** Mgr `D4_ParaPete` · `d4_stone_steps` Stone Steps B `D4_StoneSteps` · `d4_build_lab` *Build the Fossil Lab* U→5 `D5_EntryArch` |
| D5 | **Fossil Lab** (`fossil_lab`): a thatched lab-museum with a giant skeleton and egg incubators | Fossil Lab (`dp5_fossil_lab`, 3.5 s) | `d5_lab_hut` Lab Hut B(builder) `D5_LabHut` · `d5_amber_jars` Amber Jars B `D5_AmberJars` · `d5_microscope` Microscope M×2 `D5_Microscope` · `d5_incubators` Egg Incubators M×2 `D5_Incubators` · `d5_dusting_brushes` Dusting Brushes S×2 `D5_DustingBrushes` · `d5_skeleton` Big Skeleton M×3 `D5_Skeleton` · `d5_dig_site` Dig Site B `D5_DigSite` · `d5_dr_trike` **Dr. Trike** Mgr `D5_DrTrike` · `d5_museum_banners` Museum Banners B `D5_MuseumBanners` · `d5_wake_volcano` *Wake the Volcano* U→6 `D6_EntryArch` |
| D6 | **Volcano Reactor** (`volcano_reactor`, finale, height 140): a tamed volcano with lava channels, turbines, a crystal core | Volcano Core (`dp6_volcano_core`, 5 s) | `d6_volcano_core` Volcano Core B(builder) `D6_VolcanoCore` · `d6_lava_channel` Lava Channel B `D6_LavaChannel` · `d6_stone_turbines` Stone Turbines M×2 `D6_StoneTurbines` · `d6_steam_vents` Steam Vents B `D6_SteamVents` · `d6_magma_pumps` Magma Pumps S×2 `D6_MagmaPumps` · `d6_crystal_core` Crystal Core M×3 `D6_CrystalCore` · `d6_lava_falls` Lava Falls M×2 `D6_LavaFalls` · `d6_sky_bridge` Sky Bridge B `D6_SkyBridge` · `d6_obsidian_crown` Obsidian Crown M×5 `D6_ObsidianCrown` · `d6_chief_tyra` **Chief Tyra** Mgr `D6_ChiefTyra` · `d6_golden_trex` *Golden T-Rex Statue* U(feature "Rebirth") `D6_GoldenTRex` |

* **Totals:** 59 pads (9 + 10 + 9 + 10 + 10 + 11), 6 producers, 6 managers.
* **Feature keys:** Dino allows only `"Rebirth"` (on the finale). AA / Attack / StandRename stay
  Nuke Town only.
* **Blurbs:** "+10% Bench Bones", "x3 Market Bones", "Rocky runs the bench for you!", ... Logic
  builder writes them, kid-friendly.

### 6.3 Pricing and pacing
Pricing and pacing follow exactly the same structure as Nuke Town (`docs/economy.md` "Pricing
structure"):
* SCALE per area, `costGrowth` 1.2, builder = 10·SCALE, pads on the producer's level-cost curve at
  designated levels, Manager at the level-25 slot, Unlock = 3× the pad before, friendly 2-significant
  prices.
* `baseRevenue` / `SCALE` are written by the simulator:
  `lune run tests/economy-sim.luau --world dino --tune --write`.

| # | Area | Target min | Cumulative |
|---|---|---|---|
| D1 | Cave Workshop | 10 | 0:10 |
| D2 | Fern Market | 18 | 0:28 |
| D3 | Ptero Post | 24 | 0:52 |
| D4 | Geyser Springs | 28 | 1:20 |
| D5 | Fossil Lab | 32 | 1:52 |
| D6 | Volcano Reactor | 38 | 2:30 |

* **Simulator assertions:**
  * ±20 % per area (same tolerance).
  * Run 2 after one Dino rebirth ≤ 85 % of run 1.
  * Every price strictly rises along the chain.
  * The monotonicity invariant (no purchase lowers a number the player sees) holds for every world
    and for `linkCash`.
* The sim plays a no-bonus player (no pets, passes or link). Veterans arrive faster, which is the
  intended reward for main progress.
* **Number scale:** Bones start at 1 per click. Each area multiplies income ~×30–50, so the finale
  sits in the low billions. That is a fresh climb, visibly separate from Nuke Town's Qi.

### 6.4 Rebirth track ("Dino rebirth")
* **Requirement:** own `d6_golden_trex` (Player attribute `FeatureRebirth_dino`). The session must
  be saving (`canMutate`).
* **Reward:**
  * Amber `= floor((Base 10 + totalLevels/25) × (1 + 0.1 × dinoRebirthsSoFar))`
  * `rebirths += 1`
  * Bones multiplier `1 + (0.5 + 0.05 × goldenAmber) × dinoRebirths`
* **Resets:** `worlds.dino.tycoon` (fresh state) and `worlds.dino.cash` (set to the Bone Stash
  start).
* **Keeps:** Dino rebirths, Amber, the Amber shop, and everything outside `worlds.dino` (Nuke Town,
  pets, gems, passes).
* Nuke Town rebirth never touches `worlds.dino`, and vice versa.

**Amber shop** (`DinoRebirth.Shop`; keys are SAVE DATA and reuse the main key names so
`Modifiers` resolves them per track):

| Key | Name | Effect / level | Max | Cost (Amber) |
|---|---|---|---|---|
| `clickPower` | Mighty Roar | +10 % Bones on every cycle (clicked + automated) | 10 | 3 × 1.45^L |
| `managerSpeed` | Speedy Raptors | +10 % automated speed | 10 | 3 × 1.5^L |
| `startingCash` | Bone Stash | start each Dino run with Bones (4 values, sim-tuned to ≈ the cash that opens D2 / D3 / D4 / D5) | 4 | 4 × 2.2^L |
| `rebirthPower` | Golden Amber | +5 % per-Dino-rebirth bonus | 10 | 5 × 1.6^L |

### 6.5 Cross-world link (`linkCash`, a new `Modifiers` field, ≥ 1, monotonic)
* **Nuke Town:** `linkCash = 1 + Σ_worlds toMainPerRebirth × min(worldRebirths, toMainMaxRebirths)`.
  Dino uses 0.10 / 20, so the max is ×3.0.
* **Dino Valley:** `linkCash = 1 + fromMainPerRebirth × min(mainRebirths, fromMainMaxRebirths)`.
  Dino uses 0.05 / 10, so the max is ×1.5.
* Shown on both Rebirth tabs:
  * "Dino Bonus: +30% Nuke Town cash (3 Dino rebirths)"
  * "Nuke Town Bonus: +25% Bones"

### 6.6 Offline earnings
* On join, `OfflineService` pays every unlocked world from the same server timestamp
  (`offline.lastSeenAt`), with that world's automated income, offline-mode modifiers and the
  player-level cap / rate.
* The Welcome Back window shows one row per world with a non-zero payout:
  "Nuke Town $1.2T" and "Dino Valley 4.5M Bones".
* **DOUBLE IT!** (DoubleOffline, one purchase) doubles every pending row exactly once.
* The no-pending fallback stays Cash-only (unchanged).

---

## 7. Build-in, billboards, managers, motion (reuse, no forks)

* **Build-in:** unchanged mechanism (server stamps `BuildIn` + `BuyerUserId` on the build Model;
  the client flies the pieces in). Every Dino purchase builds in, and an Unlock builds the next
  area's base with the `AreaUnlock` fanfare. Reduce Motion is respected.
* **Producer billboards:** the R31 / R32 solver generates Dino spots offline
  (`lune run tools/billboards/generate-spots.luau --world dino` → `BillboardSpots.worlds.dino`).
  The billboard shows the world's currency icon (bone) instead of `$`.
* **Pad billboards** are unchanged. The price shows the bone icon.
* **Managers:** the 6 dino managers are pieced into the R30 rig groups, with waypoints in
  `ManagerNpcConfig.Rigs`. They do idle / walk / work / wave / hop like Nuke Town managers.
* **Motion (R56 / WorldFx):**
  * Spinning: water wheel, stone turbines, mammoth fan ears, wind sock.
  * Bobbing: geyser columns (on a 6 s cycle), egg incubators wobble, lava falls scroll.
  * Routed: pteros fly parcels in and out on `VehicleRouteConfig` routes (world-keyed, one
    assembly per ptero, R25). Wings flap via a WorldFx row.
  * Everything uses the existing one-Heartbeat controllers with view-cone culling and FxQuality
    budgets.
* **Knockdown (R50) is not used** in Dino Valley.

---

## 8. Pets and eggs

* **Two eggs** at Base Camp nest-stands, priced in Bones:
  * **Dino Egg** (`dino_egg`): opens at Dino area 2, price `friendlyPrice(PriceUnits × dp2 baseCost)`,
    odds tier like eggs 3–5 (Uncommon 65 / Rare 27 / Epic 7.5 / Legendary 0.5 %).
  * **Volcano Egg** (`volcano_egg`): opens at Dino area 5, price from the dp5 baseCost, odds tier
    like eggs 6–8 (Rare 65 / Epic 27 / Legendary 7.75 / Mythic 0.25 %).
  * Pity, Lucky Eggs, Triple and Auto Hatch, held eggs and the R49 hatch cinematic all apply.
* **New pets** (names checked against the 40 existing; none reuse "Rex"):
  * Dino Egg: Atom Raptor (Uncommon), Glow Stego (Rare), Fission Trike (Epic), Pocket Bronto
    (Legendary).
  * Volcano Egg: Ember Ankylo (Rare), Magma Ptero (Epic), Lava Para (Legendary), Supernova Spino
    (Mythic).
  * Exclusive, deterministic (not random): **Time Ptero** from the Time Traveler Pack.
* **Bonus tiers:** Dino Egg pets tier 4, Volcano Egg tier 7, Time Ptero Epic tier 5
  (`PetConfig.bonusFor`).
* **Paid random items:** Bones are Robux-reachable (Bones packs), so `EggConfig.PaidRandomCurrencies.bones
  = true`, and the existing fail-closed `PolicyCache` gate covers Dino eggs. The Time Traveler
  Pack's pet is fixed, so the pack is not a random item.

---

## 9. Monetization

| Item | Kind | Price (R$) | Grant |
|---|---|---|---|
| `BonesSmall` "Pile of Bones" | `WorldCash` (`world = "dino"`) | 29 | 10 min of Dino idle income, floor 500 |
| `BonesMedium` "Sack of Bones" | `WorldCash` | 79 | 30 min, floor 5K |
| `BonesLarge` "Crate of Bones" | `WorldCash` | 199 | 2 h, floor 50K |
| `TimeTravelerPack` "Time Traveler Pack" | `WorldStarter` (one-time) | 99 | 20 min of Dino income (floor 2K) + Time Ptero pet + 30 min 2x Cash boost |

* Prompts are refused while Dino is locked (the UI hides them anyway). A receipt that still arrives
  is **always granted** into `worlds.dino.cash`, so Robux are never taken for nothing.
* **Skip Pad** buys the next pad of the world you are standing in.
* **Shop:** a DINO VALLEY section (R39 3D models of bone piles + the pack). The right-side offer
  rotation adds the Time Traveler Pack while in the Valley.
* No new game passes. The Teleporter pass gains "visit other players' Dino plots". Every pass
  description string is updated to say "in every world".

---

## 10. Save schema (v2, additive, default-safe)

```lua
-- New in schema v2 (everything in v1 unchanged):
lastWorld = "main",                 -- world the last session ended in (rejoin chip); unknown → "main"
worlds = {                          -- non-main worlds only; key ^[a-z][a-z0-9]{0,15}$, ≤ 8 entries
  dino = {
    unlocked = false, unlockedAt = 0,              -- sticky unlock, server unix seconds
    cash = 0, totalEarned = 0,                     -- Bones; clamped [0, MaxCash], finite
    tycoon = { pads = {}, producers = {}, area = 1, standName = "", lastSaveAt = 0, tutorialStep = 0 },
    rebirths = 0, rebirthTokens = 0,               -- Dino rebirths, Amber
    rebirthShop = {},                              -- Amber shop levels
    stats = { playSeconds = 0, runSeconds = 0, visits = 0, padsBought = 0, clicks = 0, lastVisitDay = -1 },
  },
}
```
* **Why v2:** reconcile rebuilds a profile from defaults and drops unknown fields. A v1 server
  that loads a save containing `worlds` would drop it, then save over it.
* **v1 → v2 migration:** `MIGRATIONS[1]` is a no-op; reconcile fills the defaults. After that, a
  v1 server sees v2 as `"newer"` and opens it read-only. Owner action at publish: use **Migrate to
  Latest Update** so no player lands on an old server.
* **Future-proofing without schema bumps:** reconcile **keeps unknown world keys** that are
  well-formed, using the same generic world-state reconciler (bounded sizes, finite numbers, area
  clamped to 1..MaxArea). An older server never destroys World 3 data. Known worlds also clamp
  `area` to their area count.
* **Snapshot fields:**
  * `worlds`: structure only (unlocked, unlockedAt, tycoon {pads, producers, area}, rebirths,
    rebirthTokens, rebirthShop, stats.visits), pushed on change.
  * `worldCash`: `{[id] = {cash, totalEarned}}`, small and frequent.
  * `lastWorld`.
* **Size:** ~2 KB per world.

---

## 11. Security (every new or changed remote)

General rules (main spec + `Remotes.luau`): typed `unknown` args, `Validate`, per-player
`RateLimiter`, state checks, intents only, no client positions or amounts, `Remotes.onServerEvent`.

| Remote | Direction | Validation and state checks |
|---|---|---|
| `TravelWorld(worldId, target, index?)` **new** | C→S | `worldId` via `Validate.worldId` (string ≤ 16, `WorldsConfig.get`) · `target` ∈ {spawn, area, plot} · `index` finite integer (area 1..areaCount, plot 1..8, nil for spawn) · `RateLimiter(3, 0.5)` + 2 s cooldown + one in-flight travel per player · profile loaded, character alive, `PlotRevealed`, has a main plot · world enabled (admin kill switch) · unlocked (rule + sticky flag; main always) · area: `forWorld(w).areaUnlocked` · plot: owned by a player, own or Teleporter pass · destination CFrame computed server-side only |
| `WorldTravel` **new** | S→C | `{ worldId, phase = "out"\|"in"\|"fail", reason?, at }`, cosmetic only |
| `Rebirth(worldId?)` changed | C→S | nil = main; else allowlisted · unlocked · `canRebirth` on that world's state · `canMutate` · busy lock · existing limiter. Atomic, no yield. |
| `RebirthShopBuy(key, worldId?)` changed | C→S | key ∈ that world's `rebirth.Shop` (per-world allowlist) · price from that world's tokens · existing limiter |
| `ProducerClick` / `ProducerUpgrade` / `PadBuy` (unchanged signatures) | C→S | world resolved from the **globally unique id** (`WorldsConfig.worldOfProducer / worldOfPad`) · that world's runtime ready · reach via that world's plot geometry (worlds are 6000 studs apart, so cross-world reach is impossible) · spend from that world's wallet only |
| `OfflineEarnings` payload | S→C | adds `worlds = { {id, amount} }` (display only) |
| `HatchEgg` (Dino eggs) | C→S | existing pipeline. Stand range is measured in world space, plus unlock + area checks and the paid-random gate for `bones`. |
| `PromptProduct` (Bones packs / pack) | C→S | allowlisted keys. Refused while locked. Receipts are idempotent and always granted. |

**Exploit notes**
* Currencies never mix: the server decides which wallet a producer pays from its id.
* Travel can't skip cycles. Cycles are server time; travel touches no economy state.
* Duplicate builds from rapid travel are impossible. `ensureWorld` is idempotent with one in-flight
  build per (player, world), and the existing PlotBuilder generation guard drops late builds.
* Offline can't be double-dipped. It pays once per loaded profile, from server timestamps.
* Snapshots only carry the player's own world data.
* The admin kill switch moves everyone in a disabled world back to the lobby. Their data is
  untouched.

---

## 12. Analytics (RoBeasts model, server aggregates, allowlisted keys)

**New family `worlds`** (12 families total → still ≤ 12 UpdateAsync per server per minute):
* `unlock:<w>` · `unlockSrc:<w>:<area|rebirth|legacy|admin>`
* `popup:<w>:<shown|go|later|lockedPreview>`
* `portalLocked:<w>`
* `travel:<w>:<portal|menu|popup|chip|admin>` · `travelFail:<w>:<reason>`
* `visitor:<w>` (unique per player-day) · `firstVisit:<w>` · `seconds:<w>`
* `area:<w>:<area>` · `areaN:<w>:<area>` · `areaAt:<w>:<area>` (first-run world-play seconds;
  target = the world's Pacing) · `areaB:<w>:<area>:<bucket>`
* `padArea:<w>:<area>`
* `rebirth:<w>` · `rebirthN:<w>:<bucket>` · `rebirthShop:<w>:<key>` · `tokens:<w>`
* `offline:<w>:<pay|double>` · `incomeW:<w>:<click|auto|offline>`

**Existing families:**
* `tycoon` `pad:<padId>` / `incomeP:<producerId>:*` accept Dino ids, because the allowlist reads
  `WorldsConfig`.
* `economy` `earn|spend:<currency>` accepts `bones` and `amber`.
* `pets` takes Dino egg ids. `revenue` takes the new product keys.
* `health` splits client perf by world (`perfW:<w>:<metric>`).

**Creator Dashboard:**
* `LogProgressionEvent` path "Dino Valley"
* funnel `DinoValley` (unlocked → first travel → first pad → manager → D2 … D6 → finale → rebirth)
* `LogEconomyEvent` with currency "Bones"

**Admin Analytics tab:** a WORLDS section with unlocks, unique visitors, average minutes in the
world, the area funnel (average minutes vs target), rebirths, Bones earned and spent by reason, Dino
egg hatches, Bones product revenue and the popup funnel. COPY FOR AI includes it.

---

## 13. Admin (owner panel; every command audited, re-authorised, schema-checked)

**Players tab** (target player; the world arg is an `enum` built from `WorldsConfig.Order` minus
"main"):

| Command | Effect |
|---|---|
| `WorldUnlock` | Unlock a world |
| `WorldRelock` | Undo the unlock for re-testing the popup flow (confirm) |
| `WorldSetArea` | Set the area for a world |
| `WorldUnlockAll` | Unlock every pad of a world |
| `WorldResetRun` | Wipe the tycoon + currency (confirm, red) |
| `WorldWipe` | Wipe everything incl. rebirths (confirm, red) |
| `WorldGrantCash` / `WorldSetCash` | Grant or set the world currency |
| `WorldSetRebirths` | Set the world's rebirth count |
| `WorldGrantTokens` | Grant the world's rebirth tokens |
| `WorldSend` | Travel the player: spawn / own plot |
| `WorldRebuildPlot` | Rebuild the world's plot (optional "replay build-in") |
| `WorldOfflinePreview` | Read-only: what N hours offline would pay per world |

**Server tab:** `WorldEnabled(world, on/off)` kill switch.

**Live tab:** players per world.

**Players list:** current world, Bones, Dino area, Dino rebirths.

---

## 14. UI / UX (all stud UI, console + mobile first)

| Surface | Change |
|---|---|
| HUD currency (top centre) | In Dino Valley the primary counter becomes **Bones** (bone icon, cream-amber number, "+X/s Bones"). Cash shows as a small secondary pill underneath. Gems unchanged. CurrencyFly gains a `bones` kind. |
| Left HUD | **No new buttons** (owner R58). Teleport gets a NEW dot until the first visit. Attack hides while in Dino Valley. |
| Teleport | World tabs (§4.3). Gamepad: LB / RB tabs, default = the first GO of the current world, B closes. |
| Rebirth | World tabs. The Dino tab shows: requirement, Bones multiplier now → after, Amber reward, the Amber shop, and both link bonus lines. Locked tab shows the unlock hint. |
| Welcome Back | One row per world. DOUBLE IT doubles all rows. |
| Shop | DINO VALLEY section, hidden until unlock |
| New: World Unlocked popup | §4.2. Locked-preview mode from the portal. |
| New: Warp overlay | §4.5. Non-interactive. Reduce Motion = fade. |
| Objective chip (HudObjective) | First Dino run gets a 3-step objective from pure `WorldObjectives`: "Step on the green pad to build your Stone Bench!" → "Click the bench to carve Pebble Nukes!" → "Hire Rocky Raptor!". No server tutorial. |
| Rejoin chip | §4.6 |
| World ambience | Client-only Lighting preset per world (Atmosphere warm-green haze, ColorCorrection tint; ClockTime untouched so the admin SetTimeOfDay still works), music `music_dino_valley`, jungle ambience bed |

* **Every new or changed screen** gets:
  * default selection, `NextSelection` links, B / Back closes, TV-safe 5 % inset
  * ≥ 44 pt taps, ≥ 14 pt text, clear of the thumbstick / jump zones
  * verified with `capture_device_matrix` (phone, tablet, console)
* **Time Machine prompt:** ButtonX / E / tap.

---

## 15. Performance budget

* **Server:**
  * Dino runtimes add ≤ 0.1 ms/frame of tick for 8 players. Today `tickPlayer` costs ≈ 0.07 ms
    for 8, and the heartbeat target stays ≤ 4 ms.
  * 8 full Nuke Town + 8 full Dino plots ≤ 45k Workspace instances (today 20.9k for 8 full
    plots); measured in QA.
  * No per-object loops; one tick loop over all runtimes.
* **Network:**
  * IncomePops and anchor `CycleStart` writes only for the world the player is in.
  * `worldCash` deltas share the existing cash push cadence.
  * No new unreliable streams.
* **Client:**
  * Only one world is ever streamed (radius 768 ≪ 6000), and budgets match Nuke Town.
  * Each fully built Dino area ≤ 28k triangles; D6 ≤ 34k.
  * Base Camp first-view pass ≤ 700 MeshParts / 150k triangles / ≤ 45 unique meshes, with decor
    in a deferred pass (R55 pattern).
  * ≤ 60 active ghost parts during build-in.
  * Glow budget and z-fight audit at 0 (R18 / R19).
* **Travel:**
  * Mesh preload of the destination starts with the warp.
  * The server waits for `RequestStreamAroundAsync` ≤ 3 s.
  * Lighting swap = a handful of property sets once per travel.

---

## 16. Art scope (Blender builders; every model stud-material, budgets per `docs/world-art.md` §4)

**Per area** (base = `D<N>_Floor` + `D<N>_EntryArch`). The arch reads correctly from both sides
(R17), and areas obey the R18 z-fight, R19 glow and R24 interpenetration rules and R31 billboard
space.

| Area | Models (key → build key when different) |
|---|---|
| D1 Cave Workshop | `D1_Floor`, `D1_EntryArch` ("CAVE WORKSHOP"), `D1_CaveCliff` (base backdrop: mossy cliff with cave mouth, ≤ 6k), `D1_StoneBench` (producer: slab bench + glowing pebble nuke + chisel), `D1_TorchWall`, `D1_BoneTools`, `D1_CavePaintings` (original dino doodles), `D1_FirePit` (flame = Neon + particle anchor), `D1_LeafBellows`, `D1_RockyRaptor` (manager rig), `D1_LogFence` |
| D2 Fern Market | `D2_Floor`, `D2_EntryArch`, `D2_ShellCounter` (producer), `D2_LeafAwning`, `D2_CoconutTill`, `D2_BerryBaskets`, `D2_TotemSign` (carved "NUKES!" totem, tall), `D2_MammothFan` (baby woolly mammoth fanning its ears — Ears piece animated), `D2_PicnicLogs`, `D2_StegoSally` (manager), `D2_BambooFence` |
| D3 Ptero Post | `D3_Floor`, `D3_EntryArch`, `D3_NestTower` (producer: tree-trunk tower, nest deck, parcel chute; hero ≤ 6k), `D3_RopeBridge`, `D3_ParcelBaskets`, `D3_WindSock`, `D3_PteroFlock` (3 perched pteros), `D3_PteroCourier` (routed flyer: Body / WingL / WingR / Parcel; 2 placements), `D3_TreasureMap`, `D3_LandingPad`, `D3_CaptainPtera` (manager) |
| D4 Geyser Springs | `D4_Floor`, `D4_EntryArch`, `D4_GeyserVent` (producer + `Column` piece that bobs), `D4_BambooPipes`, `D4_WaterWheel` (Wheel spins), `D4_SteamWhistles`, `D4_HotSprings` (pools, soft blue Neon-free water), `D4_PressureValves`, `D4_MegaGeyser` (hero), `D4_ParaPete` (manager), `D4_StoneSteps` |
| D5 Fossil Lab | `D5_Floor`, `D5_EntryArch`, `D5_LabHut` (producer), `D5_AmberJars`, `D5_Microscope`, `D5_Incubators` (eggs wobble), `D5_DustingBrushes`, `D5_Skeleton` (big friendly skeleton display, hero ≤ 6k), `D5_DigSite`, `D5_DrTrike` (manager), `D5_MuseumBanners` |
| D6 Volcano Reactor | `D6_Floor`, `D6_EntryArch`, `D6_VolcanoCore` (producer: `D6_VolcanoBase` + `D6_VolcanoTop` split to stay ≤ 6k each; height ≤ 140), `D6_LavaChannel` (scrolling lava piece), `D6_StoneTurbines` (spin), `D6_SteamVents`, `D6_MagmaPumps`, `D6_CrystalCore`, `D6_LavaFalls`, `D6_SkyBridge`, `D6_ObsidianCrown`, `D6_ChiefTyra` (manager), `D6_GoldenTRex` (finale statue, gold, glow-budget safe) |

**Base Camp + world frame (hub builder):**
* Plaza and frame: `Valley_BaseCamp` (stone-ring plaza), `Valley_BrontoFountain` (hero: a friendly
  long-neck statue spouting into a pond), the plot frame (`Valley_Path` tiles, `Valley_PlotGround`,
  `Valley_FernHedge` border, `Valley_EntranceArch` with an `OwnerSign` piece) and
  `Valley_LockedSlot` (a vine-covered "COMING SOON" sign).
* Fixtures: `Valley_TeleportPad` (×8, plot-tinted), `Valley_EggStand` (nest stand ×2),
  `Valley_Leaderboard` (stone tablet) and `Valley_TitleSign` ("DINO VALLEY").
* Scenery: `Valley_Palm`, `Valley_Fern`, `Valley_Boulder`, `Valley_Hill`, `Valley_Waterfall`,
  `Valley_BoundaryCliffs`, `Valley_VolcanoBackdrop` (far, low-poly) and `Valley_FossilDecor`.
* `Hub_TimeMachine` is ONE model used in both worlds (`Swirl` piece spun by WorldFx; `Sign` piece
  takes a SurfaceGui).

**Pets / eggs:**
* 8 dino pets + Time Ptero, rigged for PetAnim (R44, `docs/pets-art.md`).
* `Egg_Dino` (speckled green) and `Egg_Volcano` (orange crackle) with R49 `EggShards` colours.

**Shop props (R39):** `Shop_BonesSmall` / `Shop_BonesMedium` / `Shop_BonesLarge` (bone piles) and
`Shop_TimeTravelerPack`.

**Icons (Blender-rendered, R9):**
* currencies: `Bones`, `Amber`
* world tabs: `WorldNukeTown`, `WorldDino`
* `TimeMachine`
* shop: `BonesPack` ×3, `TimeTravelerPack`

**Audio:** `music_dino_valley`, `amb_jungle`, `warp_whoosh`, `ptero_squawk_cute`, `geyser_whoosh`,
`dino_happy_roar`, `volcano_rumble_soft`, `bones_pickup`. Everything goes through the existing
audio pipeline and SoundAssets.

---

## 17. Edge cases

* **Knocked down while in Dino Valley:** the knockdown chip still shows. TAP TO REBUILD works from
  anywhere (owner-only, unchanged).
* **Attacks from Dino Valley:** refused with "Head back to Nuke Town to launch!". Players in Dino
  Valley stay targetable on their Nuke Town plot (they lose nothing; R50 rules).
* **New Player Mode (admin sandbox profile)** covers worlds automatically, because worlds are
  profile data.
* **Test bots (R51)** live in Nuke Town only.
* **Leaving mid-warp:** the travel is abandoned and the runtime is torn down on leave (existing
  teardown path).
* **World disabled while players are inside:** they are sent to the Nuke Town lobby with a toast.
  Their runtimes keep earning, because the kill switch only blocks travel and building.

---

## 18. The worlds framework: how to add World 3 (config + art only)

1. Geometry row in `Shared/Config/Worlds/WorldGeometry` (origin ≥ 3000 studs from every other
   world's scenery disc; `tests/world-frames.luau` checks this).
2. Folder `Shared/Config/Worlds/<Name>/` containing:
   * `<Name>World.luau` (the `WorldDef`)
   * `Areas/AreaNN.luau` (prefixed ids)
   * `<Name>Rebirth.luau`
   * `Layouts/AreaNN.luau`
   * `<Name>HubLayout.luau`
3. Add the id to `WorldsConfig.Order`. Run `lune run tests/economy-sim.luau --world <id> --tune --write`.
4. Art:
   * Blender builders for areas + hub; upload + `sync_meshes.py`.
   * Hub portal anchor `HubLayout.anchors.WorldPortals.<id>`.
   * Icons, lighting preset + music in `WorldClientConfig`, `SoundAssets` entries.
5. Data rows:
   * `BillboardSpots` (`generate-spots --world <id>`)
   * `ManagerNpcConfig` rigs, `WorldFxConfig` rows, `VehicleRouteConfig` routes
   * products of kind `WorldCash` with `world = <id>`
   * eggs with `currency = <currencyKey>` + its `PaidRandomCurrencies` class
   * the currency key in the analytics economy allowlist
6. `./scripts/check.sh`, then the Studio tour `python3 tools/qa/world2_check.py --world <id>`.

No server, client or UI code changes: tabs, rows, admin enums, analytics keys, travel, offline
rows and HUD currency all iterate `WorldsConfig.Order`. No schema bump either: unknown world keys
survive reconcile.

---

## 19. Risks and owner actions

| Risk | Mitigation |
|---|---|
| TycoonService refactor regresses Nuke Town | The first server change makes **no behaviour change** (main runs through the world runtime). It must pass `tycoon-server-logic` + `knockdown-logic` + a Studio regression tour before any Dino code lands. |
| Old servers during rollout | Schema v2 opens saves read-only on old servers. **Owner: publish with "Migrate to Latest Update".** |
| Travel hitch on low-end mobile | Preload during the warp, `RequestStreamAroundAsync`, Atomic models, measured on the device matrix |
| Pacing feels slow next to Nuke Town veterans | Pets / passes / link speed veterans up. `areaAt:<w>` analytics vs target, retune with the sim. |
| Product ids | Created via Studio MCP `manage_monetization`. If refused, **owner** creates 4 dev products and the ids go in `PublishedProductIds`. Until then the UI shows SOON. |
| Badges | **Owner** creates "Time Traveler" (first visit) and "Volcano Tamer" (first Dino finale). Ids stay 0 until then. |
