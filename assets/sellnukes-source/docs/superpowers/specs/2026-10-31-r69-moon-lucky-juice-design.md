# R69–R71 — Lucky Buttons, World 3 "Moon Base", juice pass (design spec, 2026-10-31)

Owner request (2026-10-31, `docs/owner-requests.md` R69–R71): "buttons that are like 2x cash that
just appear randomly throughout your plot … simple things to make monetization better. Nothing
too crazy", "another area … like Dino Valley … a space", "better sound effects, more visual
effects … not necessarily change the first valley … retention max".

Hard rules apply unchanged (CLAUDE.md): stud everything, Blender models, every purchase builds in,
secure + performant, full UI, kid-friendly, analytics + admin, console + mobile first, never open a
new Studio place, Rojo owns code, one playtest at a time (`scripts/studio-lock.py`).

## 0. Decisions at a glance

| Topic | Decision | Why |
|---|---|---|
| Random plot buttons | **Lucky Buttons**: an arcade button pops up at a random free spot on your OWN plot (the world you are in) every 2–4 min, lives 45 s. FREE kinds (cash burst, 2 min 2x Cash, 2 min 2x Speed) and ROBUX kinds (2x Cash 30 min, 2x Cash pass, Auto Clicker pass, cash / world-currency pack, Skip Pad) | The owner's exact ask. Free ones teach players to chase them (session length), paid ones put a deal under their feet at the moment they want it |
| "Nothing too crazy" | ≤ 2 live per player, ≤ 1 paid live, the first button of every session is free, a paid kind is never offered for a pass you own, no paid buttons in New Player Mode | Keeps it fun, not spammy |
| Other new products | Only the new world's 3 currency packs + 1 one-time starter pack (mirrors Dino) | "Nothing too crazy" — existing passes already cover everything else |
| World 3 | **Moon Base** (`moon`): a cartoon moon colony of cute aliens + robots. 6 areas, 59 pads, ~2.5 h first run, own currency **Moon Rocks**, own rebirth track (**Star Shards**), its own eggs + pets | "a space" world like Dino Valley. Nuke Town area 9 is a rocket *space port*; Moon Base is on the Moon itself (craters, UFOs, aliens, a mini star) so it reads new |
| Space twist | **Low gravity** (x0.4) while you are in Moon Base, with a soft "boing" + dust puff on landing | Instantly fun, zero economy impact |
| Unlock | Sticky: Nuke Town **area 5** reached OR ≥ 1 Nuke Town rebirth | Dino opens at area 3 (~23 min), Moon at area 5 (~83 min) — a fresh goal in session 2 |
| Juice | Click combo ladder, purchase / milestone / unlock / rebirth celebrations, camera punch, fireworks, richer particles, ~20 new ForgeGUI sound effects | "better sound effects, more visual effects"; cosmetic only — Nuke Town's areas, pads, prices and pacing do not change |
| Framework | Moon Base is added the §18 way (config + art). Any code change the framework needs is a bug fix in the framework, not a special case | Proves "add a world = add config + art" |

## 1. Lucky Buttons (R69) — owner H3

### 1.1 Behaviour
* **Spawning (server):** per player, while they stand on their own plot in any world and are not
  AFK (> 4 min no input → no spawns), roll the next spawn `uniform(120, 240) s` after the previous
  one ended (first one 45–75 s after the plot reveal). At most `MaxLive = 2`, at most 1 paid.
* **Where:** a random ground point inside an UNLOCKED area slot of that player's plot in that world
  (WorldLayout slot frames), ≥ 7 studs from any pad / producer / billboard footprint, raycast onto
  real ground, never inside a knocked-down area. Retry ≤ 12 picks, else skip this roll.
* **Who sees it:** only the owner. No server Instances: the server keeps the wire, the client
  renders a pooled model (turkey pattern, `Server/Event/TurkeySpawner`).
* **Claim:** walk into it (works with every input) → client fires `LuckyButtonClaim(id)` → server
  validates (owns it, alive, same world, character within `ClaimRadius + 4` studs, rate limit) →
  free: grant + `claimed`; paid: server prompt (MonetizationService prompt path, Robux-off and
  policy checks honoured) at most once per button per 6 s; a paid button stays until it expires
  or is bought.
* **Lifetime:** 45 s; blinks the last 8 s; expires silently.

### 1.2 Kinds (weights + rules in `Shared/Config/LuckyButtonConfig.luau`)

| Kind | Free / Robux | Label | Grant / product | Weight | Rule |
|---|---|---|---|---:|---|
| `cash` | free | "+$1.2K!" (world currency) | 60 s of that world's current income per second (automated + manual estimate), floor = the area's first pad cost | 38 | — |
| `boost2x` | free | "2x CASH 2 MIN!" | BoostService `cash2x` +120 s | 14 | — |
| `speed2x` | free | "2x SPEED 2 MIN!" | BoostService `speed2x` +120 s | 8 | — |
| `boost30` | Robux | "2x CASH 30 MIN" | product `Cash2x30` | 14 | — |
| `pass2x` | Robux | "2x CASH FOREVER!" | pass `DoubleCash` | 9 | not owned |
| `autoclick` | Robux | "AUTO CLICKER!" | pass `AutoClicker` | 4 | not owned |
| `pack` | Robux | "CASH CRATE!" | `CashLarge` (Nuke Town) / that world's Large pack | 8 | world pack id live |
| `skip` | Robux | "SKIP PAD!" | `SkipPad` | 5 | a next pad exists |

Paid buttons carry the live price (PriceBook) and the Robux glyph. A kind whose product id is 0
(COMING SOON) is never rolled.

### 1.3 Server / client / data
* `Shared/Config/LuckyButtonConfig.luau` (tunables, kinds), `Shared/Tycoon/LuckyButtonLogic.luau`
  (PURE: roll kind with rules, spawn schedule, reward maths, claim check) + `tests/lucky-buttons.luau`.
* `Server/Services/LuckyButtonService.luau` (one 1 Hz loop for all players, no per-button threads).
* Remotes: `LuckyButtons` S→C `{ kind = "spawn" | "claimed" | "expired" | "clear", button? , id? }`;
  `LuckyButtonClaim` C→S `(id: string)` — `Validate` (string ≤ 24 chars, pattern), `RateLimiter`.
* Client `Client/LuckyButtons/LuckyButtonClient.luau`: pooled model from MeshLibrary template
  `Lucky_Button` (Blender, pieces `Base` / `Cap` / `Ring`; colour by kind: green cash, gold 2x,
  blue speed, purple Robux), BillboardGui label + Robux tag, light beam to the sky, sparkles,
  bob + spin in ONE Heartbeat, view-cone culling, FxQuality + Reduce Motion respected; spawn toast
  "LUCKY BUTTON!" with an on-screen edge arrow to the nearest button (gamepad + touch friendly,
  TV-safe); claim FX (confetti pop + coin fly to the HUD + `lucky_claim`).
* Admin (owner panel): enable / disable (kill switch `LuckyButtonsEnabled` attribute), spawn a
  kind on a player now, interval multiplier, clear all, live counts. Coordinate the admin screen
  edit with W12 (it owns `UI/Screens/Admin/*`).
* Analytics: `luckySpawned:<kind>`, `luckyClaimed:<kind>`, `luckyPrompted:<kind>`,
  `luckyPurchased:<kind>` (receipt within 120 s of that player's lucky prompt for that product),
  `luckyExpired:<kind>`.
* Sounds (requested from H1): `lucky_spawn` (sparkly "ding-ding-ding" pop-up), `lucky_claim`
  (bright jingle), `lucky_blink` (soft tick for the last seconds).

## 2. World 3 — Moon Base (R70)

### 2.1 WorldDef (owner W1)

| Field | Value |
|---|---|
| id / order / name | `moon` / 3 / "Moon Base" |
| tagline | "Blast off and build a nuke empire on the Moon!" |
| idPrefix | `m` → pads `m<N>_*`, producers `mp<N>_*`, build keys `M<N>_*` |
| geometry | origin **(-6000, 0, 0)**, 6 areas, plotLength 312, finale area 6 height 140, boundary 650, scenery 950 (gap to Nuke Town 3050 ≥ 3000) |
| currency | `moonrocks` "Moon Rocks", icon `MoonRocks`, colour (196, 180, 255), style count |
| tokens | `starshards` "Star Shards", icon `StarShards`, colour (120, 230, 255) |
| unlock | `{ kind = "progress", world = "main", area = 5, orRebirths = 1 }` |
| link | toMain 0.10 / 20 rebirths, fromMain 0.05 / 10 (same as Dino; Nuke Town's link sums every world) |
| features | all off (no tutorial, knockdown, stand name, attack, leaderstats) |
| pacing | TargetMinutes { 10, 18, 24, 28, 32, 38 } (150 min), tolerance 0.2, sim-tuned |
| art | `layoutFolder = { "Worlds", "Moon", "Layouts" }`, `hubLayout = { "Worlds", "Moon", "MoonHubLayout" }`, `portalAnchor = "moon"`, `ambience = { lighting = "moon", music = "music_moon_base" }` |
| eggs | `moon_egg`, `comet_egg` |

**Rebirth track** `Worlds/Moon/MoonRebirth`: requirement own `m6_golden_astronaut`; reward Star
Shards = `floor((10 + totalLevels/25) × (1 + 0.1 × moonRebirths))`; Moon Rocks ×(1 + (0.5 + 0.05 ×
rebirthPower) × moonRebirths). Shop (keys reuse the main names): `clickPower` "Rocket Fuel",
`managerSpeed` "Turbo Bots", `startingCash` "Rock Stash", `rebirthPower` "Supernova" — same curves
as Dino.

### 2.2 Areas and pads (ids are SAVE DATA; never rename or reuse)
Pad kinds mirror Dino pad-for-pad (so pricing structure is identical): `B` build, `M×n`, `S×2`,
`Mgr`, `U`. The Unlock pad of area N builds `M{N+1}_EntryArch`.

| # | Area (id) | Producer (id, cycle) | Pads in buy order: `id` Name kind `BuildKey` |
|---|---|---|---|
| M1 | **Crater Camp** (`crater_camp`): a landed capsule in a crater, a workbench under a big lamp | Moon Rock Bench (`mp1_rock_bench`, 1 s) | `m1_capsule_bench` Capsule Bench B(builder) `M1_CapsuleBench` · `m1_crater_lamps` Crater Lamps B `M1_CraterLamps` · `m1_moon_tools` Moon Tools M×2 `M1_MoonTools` · `m1_flag_pole` Flag Pole B `M1_FlagPole` (Sell Nukes logo flag, no country) · `m1_solar_panels` Solar Panels M×3 `M1_SolarPanels` · `m1_air_pump` Air Pump S×2 `M1_AirPump` · `m1_bleep_bot` **Bleep Bot** Mgr `M1_BleepBot` · `m1_crater_rail` Crater Railing B `M1_CraterRail` · `m1_open_diner` *Open the Cosmic Diner* U→2 `M2_EntryArch` |
| M2 | **Cosmic Diner** (`cosmic_diner`): a retro chrome + neon diner for alien customers | Cosmic Diner (`mp2_cosmic_diner`, 1.5 s) | `m2_diner_counter` Diner Counter B(builder) `M2_DinerCounter` · `m2_neon_sign` Neon Sign B `M2_NeonSign` · `m2_star_register` Star Register M×2 `M2_StarRegister` · `m2_booth_seats` Booth Seats B `M2_BoothSeats` · `m2_rocket_jukebox` Rocket Jukebox M×3 `M2_RocketJukebox` · `m2_shake_machine` Milkshake Machine S×2 `M2_ShakeMachine` · `m2_crater_tables` Crater Tables B `M2_CraterTables` · `m2_zip_zorp` **Zip Zorp** Mgr `M2_ZipZorp` · `m2_landing_lights` Landing Lights B `M2_LandingLights` · `m2_call_ufos` *Call the UFO Couriers* U→3 `M3_EntryArch` |
| M3 | **UFO Delivery** (`ufo_delivery`): a saucer depot with a tractor-beam pad; UFOs fly parcels in and out | UFO Express (`mp3_ufo_express`, 2 s) | `m3_saucer_dock` Saucer Dock B(builder) `M3_SaucerDock` · `m3_tractor_beam` Tractor Beam B `M3_TractorBeam` · `m3_parcel_pods` Parcel Pods M×2 `M3_ParcelPods` · `m3_radar_dish` Radar Dish S×2 `M3_RadarDish` · `m3_ufo_fleet` UFO Fleet M×3 `M3_UfoFleet` · `m3_star_map` Star Map M×4 `M3_StarMap` · `m3_launch_ring` Launch Ring B `M3_LaunchRing` · `m3_captain_glorp` **Captain Glorp** Mgr `M3_CaptainGlorp` · `m3_mine_asteroids` *Mine the Asteroids* U→4 `M4_EntryArch` |
| M4 | **Asteroid Mine** (`asteroid_mine`): chunky asteroids on tethers, a drill rig, crystal carts | Asteroid Drill (`mp4_asteroid_drill`, 2.5 s) | `m4_drill_rig` Drill Rig B(builder) `M4_DrillRig` · `m4_tether_cables` Tether Cables B `M4_TetherCables` · `m4_ore_carts` Ore Carts M×2 `M4_OreCarts` · `m4_crystal_sorter` Crystal Sorter B `M4_CrystalSorter` · `m4_gravity_magnets` Gravity Magnets M×3 `M4_GravityMagnets` · `m4_laser_drills` Laser Drills S×2 `M4_LaserDrills` · `m4_mega_asteroid` Mega Asteroid M×4 `M4_MegaAsteroid` · `m4_drillbert` **Drillbert** Mgr `M4_Drillbert` · `m4_hover_steps` Hover Steps B `M4_HoverSteps` · `m4_build_star_lab` *Build the Star Lab* U→5 `M5_EntryArch` |
| M5 | **Star Lab** (`star_lab`): a domed observatory, giant telescope, planet mobile, star jars | Star Lab (`mp5_star_lab`, 3.5 s) | `m5_lab_dome` Lab Dome B(builder) `M5_LabDome` · `m5_star_jars` Star Jars B `M5_StarJars` · `m5_big_telescope` Big Telescope M×2 `M5_BigTelescope` · `m5_planet_mobile` Planet Mobile M×2 `M5_PlanetMobile` · `m5_comet_catcher` Comet Catcher S×2 `M5_CometCatcher` · `m5_robot_arm` Robot Arm M×3 `M5_RobotArm` · `m5_moon_garden` Moon Garden B `M5_MoonGarden` · `m5_dr_nova` **Dr. Nova** Mgr `M5_DrNova` · `m5_mission_banners` Mission Banners B `M5_MissionBanners` · `m5_light_star` *Light the Star Reactor* U→6 `M6_EntryArch` |
| M6 | **Star Reactor** (`star_reactor`, finale, height 140): a friendly mini-sun in a ring cage, beam towers | Star Core (`mp6_star_core`, 5 s) | `m6_star_core` Star Core B(builder) `M6_StarCore` · `m6_plasma_pipes` Plasma Pipes B `M6_PlasmaPipes` · `m6_orbit_rings` Orbit Rings M×2 `M6_OrbitRings` · `m6_beam_towers` Beam Towers B `M6_BeamTowers` · `m6_coolant_pumps` Coolant Pumps S×2 `M6_CoolantPumps` · `m6_nebula_core` Nebula Core M×3 `M6_NebulaCore` · `m6_meteor_falls` Meteor Falls M×2 `M6_MeteorFalls` · `m6_star_bridge` Star Bridge B `M6_StarBridge` · `m6_galaxy_crown` Galaxy Crown M×5 `M6_GalaxyCrown` · `m6_commander_lux` **Commander Lux** Mgr `M6_CommanderLux` · `m6_golden_astronaut` *Golden Astronaut Statue* U(feature "Rebirth") `M6_GoldenAstronaut` |

Totals: 59 pads (9 + 10 + 9 + 10 + 10 + 11), 6 producers, 6 managers. Base per area: `M<N>_Floor`
+ `M<N>_EntryArch` (+ a backdrop for M1 like `D1_CaveCliff`). Managers are cute bipeds pieced
into the R30 rig groups (Torso / Head / ArmL / ArmR / LegL / LegR): Bleep Bot (round robot),
Zip Zorp (three-eyed alien waiter on roller skates), Captain Glorp (pilot alien with goggles),
Drillbert (drill-hat robot), Dr. Nova (alien scientist, lab coat), Commander Lux (astronaut
chief with a clipboard).

**Motion rows (WorldFx / VehicleRoutes):** spinning radar dish, orbit rings, solar panel tilt,
jukebox lights, planet mobile; bobbing tethered asteroids, hover steps, star core pulse
(glow-budget safe); routed UFO couriers (M3, 2 placements) and ore carts on a loop (M4).

**Look:** pale lilac / moon-grey stud ground with craters, navy sky full of stars, a big ringed
planet + a cartoon blue-green home planet on the horizon, chrome-white + candy accent colours
(mint, coral, sunshine yellow, violet). No grey-metal hazard look (that is Nuke Town). Kid rules:
aliens are round, big-eyed, smiling; lasers are "drill beams"; nothing explodes except confetti.

### 2.3 Moon hub + frame + portal (owner W9)
World-local `Worlds/Moon/MoonHubLayout`: `Moon_LandingPlaza` (crater-ring plaza), hero
`Moon_RocketFountain` (a friendly rocket statue on a fountain of sparkly "star water"), plot frame
(`Moon_Path`, `Moon_PlotGround`, `Moon_CraterRim` border, `Moon_EntranceArch` with `OwnerSign`,
`Moon_LockedSlot`), fixtures (`Moon_TeleportPad` ×8, `Moon_EggStand` ×2, `Moon_Leaderboard`,
`Moon_TitleSign` "MOON BASE"), scenery (`Moon_Crater`, `Moon_Rock`, `Moon_CrystalCluster`,
`Moon_Antenna`, `Moon_BoundaryRidge`, `Moon_PlanetBackdrop` far + low-poly). Portal: a
`Hub_MoonRocket` model in the lobby at `HubLayout.anchors.WorldPortals.moon` plus its twin at the
Moon hub (same prompt / arrive contract as the Time Machine). Lighting preset `moon` + music
context in `WorldClientConfig` (APMOfficial tracks only) with `gravityScale = 0.4`.

### 2.4 Low gravity + client glue (owner W10b)
Client sets `Workspace.Gravity = default × gravityScale` while the player's `CurrentWorld` is
`moon` (restores on leave / respawn / world change); landing dust puff + `moon_boing`. Server
movement checks must tolerate the higher, slower jumps. Verify HUD currency, world tabs, Welcome
Back rows, rebirth tab, teleport menu and the world2 tour for `moon`.

### 2.5 Pets + eggs (owner W11)
* `moon_egg` "Moon Egg" opens at M2, priced from mp2 like `dino_egg`, odds like `dino_egg`:
  Astro Pup (Uncommon), Moon Bunny (Rare), Orbit Owl (Epic), Cosmo Cat (Legendary).
* `comet_egg` "Comet Egg" opens at M5, like `volcano_egg`: Comet Fox (Rare), Saucer Octo (Epic),
  Galaxy Whale (Legendary), Starlight Unicorn (Mythic).
* Exclusive (not random): **Rocket Corgi** (Epic) from the Astronaut Pack.
* `EggConfig.PaidRandomCurrencies.moonrocks = true` (Moon Rocks are Robux-reachable).
* Bonus tiers like Dino (Moon Egg 4, Comet Egg 7, Rocket Corgi 5). Names checked against all
  existing pets (rename if taken).

### 2.6 Products (owner W1) — no new passes

| Key | Kind | R$ | Grant |
|---|---|---:|---|
| `MoonRocksSmall` "Bag of Moon Rocks" | WorldCash (`world = "moon"`) | 29 | 10 min Moon income, floor 500 |
| `MoonRocksMedium` "Sack of Moon Rocks" | WorldCash | 79 | 30 min, floor 5K |
| `MoonRocksLarge` "Crate of Moon Rocks" | WorldCash | 199 | 2 h, floor 50K |
| `AstronautPack` "Astronaut Pack" | WorldStarter (one-time) | 99 | 20 min Moon income (floor 2K) + Rocket Corgi + 30 min 2x Cash |

Shop: a MOON BASE section (R39 3D props `Shop_MoonRocksSmall/Medium/Large`, `Shop_AstronautPack`),
offer rotation adds the Astronaut Pack while in Moon Base. Icons + props: W1b.

### 2.7 Icons + shop props (owner W1b)
Blender-rendered icons: `MoonRocks`, `StarShards`, `WorldMoon`, `MoonRocket`, `MoonRocksPack`
(+ Small / Large variants like Bones), `AstronautPack`, `LuckyButton`. Shop props as above.

## 3. Juice pass (R71) — owner H1

Cosmetic only; Nuke Town's content and numbers do not change. Every effect pooled, one Heartbeat
per controller, FxQuality budgets, Reduce Motion respected (no shake / punch / flashes).
1. **Click combo:** manual producer clicks within 0.7 s chain a combo; the click sound climbs a
   pitch ladder (1.0 → 1.6), a "x12!" combo label pops over the producer, a sparkle ring every
   10, a bigger burst at 25 / 50 / 100. No economy effect.
2. **Celebrations:** pad buy → coin burst at the pad + layered pop; producer milestone levels
   (25 / 50 / 100 / …) → a centre banner "LEVEL 50 — x2 SPEED!" + ding; area unlock → fireworks
   over the new area + camera punch; rebirth → white flash + fireworks + sting; finale statue →
   big confetti cannon.
3. **CameraPunch** helper (FOV kick / tiny shake), one module, Reduce Motion aware.
4. **Sounds (ForgeGUI set `forge`, kid-friendly, measured takes, manifest provenance):** better
   `pad_buy`, `milestone`, `combo_tick`, `coin_burst`, `firework_pop`, `firework_whistle`,
   `lucky_spawn`, `lucky_claim`, `lucky_blink`; Moon set `ufo_whirr`, `robot_beep`, `moon_boing`,
   `star_chime`, `rocket_launch_soft`, `amb_space` (or a licensed library ambience); Dino's
   missing `ptero_squawk_cute`, `dino_happy_roar`, `volcano_rumble_soft`. H1 owns `SoundAssets`
   SFX + `AudioConfig`; others ask H1 for keys.
5. **Ambient:** gentle income sparkles on automated producers, manager-hire puff, upgrade glow.

## 4. Ownership (one writer per file; shared tables edited with small in-place edits only)

| Owner | Files |
|---|---|
| W1-logic | `Worlds/WorldGeometry`, `Worlds/WorldsConfig`, `Worlds/Moon/{MoonWorld, MoonRebirth, Areas/*}`, `MonetizationConfig`, `PublishedProductIds`, `docs/monetization.md` (publish.py), `ShopConfig` Moon section, economy tests |
| W6-art12 / W7-art34 / W8-art56 | `tools/blender/models/moon_area0{1,2}` / `{3,4}` / `{5,6}.py`, `Worlds/Moon/Layouts/Area0N`, their rows in `ManagerNpcConfig`, `WorldFxConfig`, `VehicleRouteConfig` |
| W9b-valley | `tools/blender/models/moon_base.py` + `hub_moon_rocket.py`, `Worlds/Moon/MoonHubLayout`, `HubLayout` (moon anchor), `WorldClientConfig` (moon preset), `SoundAssets` Music rows |
| W10b-client | `Client/Worlds/*` gravity controller + any framework client fixes, `tools/qa/world2_check*` `--world moon` (after W12 releases them) |
| W11-pets | `tools/blender/models/pets_moon.py`, `eggs_moon.py`, `EggConfig`, `PetConfig`, pet anim rows |
| W1b-shop | `tools/blender/ui_icons/*` (moon + lucky icons), `IconAssets`, `tools/blender/models/shop_props_moon.py`, Shop UI Moon section |
| H3-hub | Lucky Buttons (all files in §1.3) incl. `tools/blender/models/lucky_button.py`, its `Remotes` / `Validate` / `AnalyticsConfig` / `AdminConfig` rows |
| H1-cashfx | juice modules (`Client/Tycoon/Fx/*`, `UI/Hud/*` effects), `AudioConfig`, `SoundAssets` SFX, `tools/audio/*` |
| lead | `VersionConfig` (0.4.0), `ChangeNotesConfig`, `SELLNUKES_CLAUDE_DOCUMENTATION.md`, `docs/owner-requests.md`, commits |

`MeshAssets.luau` is written only by `sync_meshes.py` (manifest lock); uploads use
`upload_meshes.py --only <your keys>` (upload lock). Builders never commit; the lead commits after
an integrated `./scripts/check.sh`.

## 5. Owner actions (after delivery)
Publish with "Migrate to Latest Update"; create badges "Moon Walker" (first Moon visit) and
"Star Tamer" (first Moon finale) if wanted (ids stay 0 until then).
