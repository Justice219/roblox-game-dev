# World art, layouts and the LEGO build-in

This file covers what the SellNukes world looks like and how it is put together: the stud-toy art
direction and palette, the themes of every area and world, the plot and slot geometry that every
layout is authored in, the `AreaLayouts` data contract, the layering rules that keep surfaces from
flickering or clipping, the "every purchase builds in" fly-in (owner rule 4), the performance rules
art must follow, and the art lessons distilled from owner feedback. How a model is *made*
(Blender builders, upload, MeshLibrary) is in `blender-art-pipeline.md`. Source docs:
`docs/world-art.md`, `docs/areas-art.md`, `docs/pets-art.md`, `docs/build-in.md`, `docs/worlds.md`,
`docs/plots.md`, `docs/performance.md`.

## Contents

1. [Art direction](#1-art-direction)
2. [Palette and colour rules](#2-palette-and-colour-rules)
3. [Area and world themes](#3-area-and-world-themes)
4. [World geometry: hub, plots, slots](#4-world-geometry-hub-plots-slots)
5. [AreaLayouts: the per-area data contract](#5-arealayouts-the-per-area-data-contract)
6. [Hub, plot frame, locked slots, extra worlds](#6-hub-plot-frame-locked-slots-extra-worlds)
7. [Layering rules: z-fighting, clipping, signs, billboards, glow](#7-layering-rules-z-fighting-clipping-signs-billboards-glow)
8. [The build-in (owner rule 4)](#8-the-build-in-owner-rule-4)
9. [World FX: animation by piece name](#9-world-fx-animation-by-piece-name)
10. [Performance rules for art](#10-performance-rules-for-art)
11. [Lessons from owner feedback](#11-lessons-from-owner-feedback)
12. [Porting checklist for a new game](#12-porting-checklist-for-a-new-game)

---

## 1. Art direction

**Look target: chunky, candy-coloured LEGO-like toys with raised square studs on every face,
chamfered edges, hazard stripes and cartoon proportions.** The owner's references are in
`docs/reference/missiles-vs-cities/` (stud-textured toy nukes and bases) and
`docs/reference/sell-lemons/` (linear tycoon, producer billboards, pads). `docs/reference/README.md`
says what to take from each image. **They are inspiration only**: copy the feel and layout
language, never the art, names or exact layouts. SellNukes is an original game.

Hard rules (CLAUDE.md):

- **Stud-texture everything (rule 2).** Every world surface uses the stud material: Blender meshes
  through their piece material, primitive Parts through `WorldMaterials.apply(part, "Studs")`. The
  UI uses the RoBeasts stud panels. Only Neon accents, Glass, and Smooth skin, faces and tiny
  details go without studs.
- **Every model is built in Blender (rule 3).** Primitives are only a load fallback.
- **Every purchase builds in (rule 4).** See §8.
- **Kid-friendly (rule 7).**
  - Nukes are candy-coloured toys ("pocket nukes": red body, white nose, charcoal fins, glowing
    green core band, yellow trefoil badge).
  - Explosions are confetti "poofs", and a hit topples toy bricks that rebuild themselves.
  - No real countries or weapons, no gore, no fire damage.
  - Per-world kid rules carry into art: Dino Valley has no teeth, claws or skulls (round cute dino
    heads, cartoon dog-bones), amber holds a fern rather than an insect, and the delivery brand is
    an original parody (BoomDash, a comic starburst `B`, no real logos).
- **Pets are 100 % original critters** with no external IP.

**Why studs everywhere:** the stud texture is the game's visual identity, and it also hides the
low-poly look. A flat 12-triangle block reads as a toy brick, not as cheap geometry, which is what
lets the budgets stay small (§10).

## 2. Palette and colour rules

The palette lives in one place, `tools/blender/snkit/core.py` (RGB 0–255). Every builder imports
constants from it so all areas match. Excerpt:

| Name | RGB | Typical use |
|---|---|---|
| `GRASS` / `GRASS_DARK` / `LEAF` | 98,204,70 / 64,160,52 / 70,186,74 | lots, lawns, trees |
| `ROAD` / `ROAD_LINE` / `SIDEWALK` | 78,82,98 / 255,214,64 / 200,202,212 | roads, markings |
| `CONCRETE` / `CONCRETE_DARK` | 182,184,194 / 140,142,154 | floors, plinths |
| `HAZARD_YELLOW` / `HAZARD_BLACK` | 255,206,36 / 44,44,54 | stripe geometry |
| `STEEL` / `DARK_STEEL` / `CHARCOAL` / `TYRE` | 150,158,172 / 92,98,112 / 58,60,70 / 52,54,64 | machines, fins, tyres |
| `WOOD` / `WOOD_DARK` / `PEGBOARD` | 214,150,86 / 164,104,58 / 226,176,112 | crates, benches |
| `TOY_RED` / `CORAL` / `ORANGE` / `YELLOW` | 232,64,56 / 240,98,78 / 255,146,40 / 255,214,50 | nukes, signs |
| `SKY_BLUE` / `DEEP_BLUE` / `PURPLE` / `PINK` / `MINT` / `LIME` | candy accents | buildings, trims |
| `GLOW_GREEN` / `GLOW_LIGHT` / `LAMP_WARM` | 110,255,90 / 200,255,160 / 255,236,160 | Neon cores, bulbs |
| `GLASS` | 180,226,255 | windows, domes (with transparency) |

Colour rules:

- **The stud colour map is 0.86–0.93 grey, so the screen shows about 10 % darker than authored.**
  The palette is pre-brightened for that. Don't "fix" dull colours by adding Neon.
- **Judge colour in the right light.** Workbench previews show about half brightness. Use
  `tools/blender/viewport_look.py` for anything shown in a ViewportFrame. Owner R47 caught a "white
  overlay" haze on the loading-screen mascot; R98 caught shop items that were "hard to see with the
  stud background" (fix: a soft backing plate or glow plus a gentle idle bob).
- **Tinted pieces** (`tinted=True`) carry per-instance colours: pad tops, nuke tiers and the eight
  plot colours on hub paths and gates. One mesh with many tints means one upload.
- **Each world has its own palette** on top of the shared one:
  - Dino: bone cream with an amber-tan shadow, glowing amber, fern green, candy-orange "jelly" lava.
  - Moon: Moon Rocks lilac (196,180,255) with a deep violet shadow, Star Shards cyan
    (120,230,255), grey-lilac dust, toy red/white rockets.

## 3. Area and world themes

Each area is a **new business phase**, in the Sell Lemons spirit (owner R1: "each phase is a new
thing"). Every pad adds something you can *see* in the area. Area scene notes are in
`docs/areas-art.md`. Each art builder appends its own section there and never rewrites another
builder's section.

**Nuke Town (`main`, 10 areas, ~8 h first run):**

| # | Area | Scene |
|---|---|---|
| 1 | Garage Lab | Suburban lot, mowed-stripe lawn, sky-blue arch, blue garage shell. Pads add the workbench, tool wall, glow lamps, door, mini reactor, paint booth, manager "Uncle Atom" and the Nuke-Mobile. Tutorial area. |
| 2 | Nuke Stand | Roadside farm stand on a plank deck, crates of candy nukes, red/white striped awning, renamable neon sign, picnic tables, picket fence |
| 3 | BoomDash Delivery | HQ of an original parody delivery app (orange + yellow), scooter lane loop, delivery van |
| 4 | Glow Rock Mine | Cliffs with glowing crystals, a foreman's shack, mine-cart train, miners swinging picks |
| 5 | Enrichment Lab | Lab shell with skylight, spinning centrifuge rotors |
| 6 | Rocket Factory | Factory hall, conveyor of toy rockets, forklift, semi-truck at a loading dock |
| 7 | Launch Silos | Slate launch deck, three hazard-bordered launch platforms, silos, control room, radar dish |
| 8 | Nuke Megastore | Candy mall plaza, two-storey store with escalators, parking garage with a barrier |
| 9 | Space Port | Launch platform with an orbital rocket and gantry, mission control, fuel farm, 79-stud space elevator |
| 10 | Mega Nuclear Facility | Finale skyline: white reactor dome with a pulsing core, cooling towers, turbine hall |

**Dino Valley (`dino`, 6 areas):** Base Camp hub + Time Machine portal; D1 Cave Workshop, D2 Fern
Market, D3 Ptero Post (flying pterodactyl couriers), D4 Geyser Springs, D5 Fossil Lab, D6 Volcano
Reactor (one parametric volcano shape shared by every piece that touches it).

**Moon Base (`moon`, 6 areas):** Landing Plaza hub + Moon Rocket portal; M1 Crater Camp, M2
Cosmic Diner, M3 UFO Delivery, M4 Asteroid Mine, M5 Star Lab, M6 Star Reactor.

**Hub (lobby):** a toy-nuke fountain with a giant waving Nukey statue, 8 plot-coloured paths,
garden beds, egg stands, a crate stall, the lucky wheel, leaderboards and a codes board, all
framed in 8 districts. The island, beach and toy-water sea surround it.

Recurring scene vocabulary, from shared helpers in `models/area01.py`:

- `entry_arch`: posts, a block-letter board, marquee bulbs, pocket-nuke finials;
- `block_text`: a 5×7 brick font;
- `toy_figure` / `toy_face`: chibi NPCs;
- `round_tree`, `blocky_tree`, `flower_bed`, `lot_stripes`, `striped_cone`, `tiny_nuke`.

Dino and Moon builders export their own shared helper modules (`models.dino_area01`,
`models.moon_area01`, `models.dino_area05`).

## 4. World geometry: hub, plots, slots

`src/shared/Config/WorldLayout.luau` is the geometry contract. Server builders and the client place
everything through it, so one rotation formula serves all 8 plots. All units are studs, +Y is up,
and the ground top is at y = 0.

```
Hub        world origin; plaza r 0..230 (HubRadius), ring road r 230..260 (PlotRadius)
Plot i     origin = CFrame.Angles(0, (i-1)*45°, 0) * CFrame.new(0, 0, 260)   (8 plots on a ring)
           plot-local +Z points away from the hub; footprint x ∈ [-80, 80], z ∈ [0, 520]
           central road x ∈ [-8, 8]; entrance arch + owner sign at z ≈ 4
Slot k     area k, row r = ceil(k/2) covers z ∈ [(r-1)*104, r*104]
           odd k left (x ∈ [-80, -10]), even k right (x ∈ [10, 80])
           slot origin = road-side edge midpoint; left = CFrame.new(-10,0,zc)*Angles(0,-90°,0),
           right = CFrame.new(10,0,zc)*Angles(0,90°,0)
           slot extent x_s ∈ [-52, 52], z_s ∈ [0, 70]; height 80 (finale 140)
           pads in the road-side strip z_s ∈ [2, 16]; producer in the middle
```

**In slot space, identity rotation means the model's front (−Z) faces the road.** Standing on the
road looking into the area, **+X_s is on your LEFT**. Every helper takes an optional trailing
`worldId`:

```lua
local cf = WorldLayout.slotToWorld(plotIndex, 3, CFrame.new(0, 0, 40))          -- Nuke Town
local dino = WorldLayout.slotToWorld(plotIndex, 2, CFrame.new(0, 0, 40), "dino") -- Dino Valley
```

**Why slot-local authoring:** a builder writes one area once, and it lands correctly on all 8
rotated plots and in any world that reuses the slot contract. Extra worlds reuse it around their
own origin: Dino at (6000, 0, 0) with a 312-stud plot, Moon at (−6000, 0, 0). See
`Worlds/WorldGeometry`.

## 5. AreaLayouts: the per-area data contract

`src/shared/Config/AreaLayouts/AreaNN.luau` (Nuke Town) and `Worlds/<World>/Layouts/` hold one
module per area, in slot-local space. They are validated by `src/server/Tycoon/LayoutLogic.luau`
(`tests/area-layouts.luau`). Shape (from `Area01.luau`):

```lua
export type ModelPlacement = { key: string, cf: CFrame, tint: Color3?, castShadow: boolean?, collide: boolean? }
export type CollisionBox = { size: Vector3, cf: CFrame }
export type BuildGroup = { models: { ModelPlacement }, collision: { CollisionBox } }

return {
	area = 1,
	base = { models = {...}, collision = {...} },      -- built when the area unlocks (area 1: plot claim)
	builds = {                                         -- one BuildGroup per pad's build key
		A1_Workbench = {
			models = { { key = "Workbench", cf = BENCH }, { key = "PocketNuke", cf = BENCH * CFrame.new(-1.2, 3.3, -0.6) } },
			collision = { boxOn(BENCH, Vector3.new(10.2, 3.3, 4.4), Vector3.new(0, 1.65, 0)) },
		},
		...
	},
	pads = { a1_workbench = Vector3.new(-16, LOT, 10), a1_tool_wall = Vector3.new(16, LOT, 10), ... },
	producer = { anchor = Vector3, click = { size = Vector3, cf = CFrame } },
	spawnPoint = Vector3.new(0, LOT, 12),
}
```

Conventions:

- **Named anchor CFrames at the top** (`GARAGE`, `BENCH`, `TOOL_WALL`), composed with the helpers
  `at(x, y, z, yawDeg)` and `boxOn(modelCf, size, localCentre)`. Collision then follows the model's
  yaw. Comment *why* each number is what it is (for example: "0.5 off the back wall so the
  pegboard clears the window sill").
- **Pads alternate either side of the arch, moving outward in buy order:** x = −16, 16, −24, 24, …
  at z = 10. The Unlock pad goes at the far end (x = −48).
- **Entry-arch convention.** Area N's Unlock pad builds `A{N+1}_EntryArch`, which resolves to
  `Area{N+1}.base` (the next area's floor and arch). `builds` lists only the area's own `A{N}_*`
  keys.
- **Collision is explicit and invisible.** Meshes never collide. Floors, walls, furniture and
  characters get boxes. Flower beds, stones and tiny props stay walk-through on purpose.
- **Producer.** The `click` box wraps the producer and everything on it. The `anchor` sits in clear
  space at eye level in front of it (owner R31/R32). It is the billboard, the tutorial-arrow target
  and the click-reach centre.
- **Id prefixes tell the world:** pads `a1_`/`d1_`/`m1_`, producers `p1_`/`dp1_`/`mp1_`, build
  keys `A1_`/`D1_`/`M1_`.
- **Lots are one plate mesh** (104 × 70, top y = 0.5, `castShadow = false`, ≤ 2,500 triangles).
  Outdoor props stand at `LOT`.

**Preview spawners** (`tools/blender/studio/spawn_areaNN.luau`) read the layout module itself, so a
clean run proves the keys, CFrames and collision. `STAGE = k` shows the area after k purchases;
`SHOW_COLLISION = true` overlays the collision boxes, the click box and the anchor.

## 6. Hub, plot frame, locked slots, extra worlds

- **`HubLayout.luau`** (world space) has `models`, `collision` and `spawn`, plus `plotFrame` (per
  plot: ground, road, border, `EntranceArch` with an `OwnerSign` piece, a `YouMarker`),
  `lockedSlot` (a "COMING SOON / x of y purchases" placeholder on every locked slot, destroyed when
  the area unlocks) and `plotDecor`.
  - Entries marked `persistent = true` (monument, island, beach, sea) spawn
    `ModelStreamingMode.Persistent`, so the horizon never pops.
  - HubBuilder falls back to a primitive hub if any key is missing from MeshAssets.
- **Plots (`PlotBuilder`).** The instance tree is `Workspace.Plots/PlotN` with these children:
  `Frame`, `Locked/LockedNN`, `AreaNN/{Base, Builds/<BuildKey>, Pads/<padId>, Producer/{Anchor,
  ClickBox}}`.
  - Everything a player owns is real, collidable server geometry. The client only animates it.
  - Plot names (`docs/plots.md`, owner R88): the owner names the plot from the arch's `OwnerSign`
    piece (click, tap, or hold E / X under the arch). The name is filtered with TextService before
    any sign shows it.
- **Extra worlds (`docs/worlds.md`).** A world is data: economy, rebirth track, geometry row,
  currencies, unlock rule, layouts and hub. Every system iterates `WorldsConfig.Order`, and nothing
  special-cases "dino". Hub layouts of extra worlds are world-local; place them with
  `WorldLayout.toWorld(id, cf)`. Portals in the lobby (the Time Machine, the Moon Rocket) use one
  model for both ends. Every art gate (§7) iterates every world.
- **No teleport pads in the hub** (owner R134). Players walk the paths or use the Teleport menu.

## 7. Layering rules: z-fighting, clipping, signs, billboards, glow

### Z-fighting layer rule (owner R18)

Two visible faces on the same plane (within 0.004 studs), facing the same way and overlapping,
flicker. This applies even to two pieces of one model. **Never share a top plane with anything you
overlap.**

| Layer | Top y |
|---|---|
| Island ground | −0.4 |
| Plot ground, road slabs, district paving | 0.00 |
| Road markings | +0.03 … +0.05, one plane per marking piece |
| Avenue paving / hub dais | +0.03 / +0.06 |
| Area base floor, lots, yards | +0.06 (or a raised plinth) |
| Build floors, rugs, tiles on a floor | +0.12 |
| Decals, stripes, painted lines | +0.18 |
| Curbs | clearly taller: +0.25 / +0.4 |

Rules, each one flagged by `tests/zfight-audit.luau`:

1. **Butt, don't overlap.** Same-layer slabs meet edge to edge.
2. **Trim never ends flush.** A trim, cap or frame bar is ≥ 0.05 proud, or its edges stop inside
   the other piece. The usual offender is a wall's `Trim` flush with its `Wall`, or a sign `Frame`
   flush with its `Board`.
3. **Stacked bands get disjoint ranges or open ends.**
4. **Stay inside your footprint.** The plot border sits just outside the plot.
5. **No curved seams at one height.** Roblox simplifies each MeshPart's LOD on its own, so two
   pieces meeting along a curve flicker at range. Give one side its own height, or make the seam
   straight (owner R18b, the ring road).
6. **Fallback-safe roads.** Even the primitive bounding boxes must not share planes.
7. Downward faces are exempt.

### Interpenetration (owner R24)

No visible piece of one placed model may pass through another model by more than 0.2 studs. Run
`check_area_overlaps.py` (`blender-art-pipeline.md` §11). It drove real fixes:

- a roof shifted half a hall sideways;
- a silo collar notched around nuke fins;
- an escalator truss clipped at the plaza top;
- a hedge row through a garage.

### Signs and text (owner R17)

- **Every lettered sign is double-sided** and correct from both faces.
- **Check text from where players stand**: render a road-side front view (`contact_sheet.py --view
  front`).
- Text on a −Z face advances toward −X.

### Producer billboards (owner R31/R32/R48)

- Keep clear space in front of every producer at eye level. The billboard is never inside
  geometry, never too high, and never blocked.
- Split big scenery pieces left/right (`TrunksL/R`, `HedgesL/R`) so their boxes don't cover the
  spot.
- Spots are solved offline into `BillboardSpots.luau` and audited by
  `tests/billboard-clearance.luau`.

### Glow (owner R19)

- Glows are soft accents: Neon only on small pieces, and a Neon piece over 6 studs² renders as
  bright SmoothPlastic.
- PointLights are capped at brightness 0.6, range 10 and pulse 0.2, with warm-white colour and no
  shadows.
- A fully built area is capped at ≤ 32 studs² of rendered Neon and ≤ 24 Neon pieces.
- The hub uses Neon bulbs and **no PointLights**.

## 8. The build-in (owner rule 4)

Owner R1: "when you buy walls or areas, all the pieces float in and build in front of you, like
the LEGO games' master builders. Parts come in translucent, fade in, and assemble." **No purchase
just pops into existence.** Spec: `docs/build-in.md`.

### Server contract (set on the wrapper Model **before** parenting it)

| Name | Meaning |
|---|---|
| attribute `BuildIn` | `workspace:GetServerTimeNow()` at purchase |
| attribute `BuyerUserId` | the buyer gets the Full flight; everyone else gets Light |
| CollectionService tag `BuildIn` | how the client finds it |
| `ModelStreamingMode = Atomic` | streams in whole, never half-built |
| attributes `PadId`, `BuildKey`, `AreaIndex` | optional context |
| attribute `AreaUnlock` | on an area's `Base` when its Unlock pad is bought → fanfare |

- Pieces carry `BuildOrder` (bottom-to-top, from `MeshAssets[key].order`).
- **Restored plots** (rejoin, rebirth, admin rebuild) carry no `BuildIn` and appear finished.
- **Pads** are tagged `SNPad`. On purchase the server sets `PressedAt` and destroys the pad 0.6 s
  later; the client squishes it and plays pop + ka-ching.
- **Why set attributes before parenting:** a client sees them the moment the model streams in.
  There is no race and no remote event per build.

### Client sequence (`src/client/Tycoon/BuildIn/BuildInController`)

1. `PlotWatcher` finds tagged models (tag-based, no `DescendantAdded` scans) and waits one frame
   so the Atomic model has fully replicated.
2. Pick a mode:
   - older than `FreshWindow` 2.5 s → shown finished;
   - Reduce Motion (Roblox setting or `profile.settings.reducedMotion`), or beyond the tier's range
     → no flight;
   - buyer → **Full**; others → **Light**.
3. Sort visible pieces bottom-to-top (world bottom-Y to ¼ stud, then `BuildOrder`, then name), and
   hide them locally with `LocalTransparencyModifier = 1`. **The server copies stay real and
   collidable at once**, so the animation can never block gameplay.
4. `BuildPlan.schedule` spaces launches so a build takes 1.2–2.5 s whatever its size. This pure
   maths is tested by `tests/build-in-plan.luau`.
5. **Full flight:**
   - each ghost starts 7–16 studs around the buyer and 3–11 up, at least 6 studs from the camera;
   - it flies a Bezier arc from 85 % transparent to solid, unwinding up to 75° of spin with a small
     overshoot "snap";
   - sounds: a whoosh at the first launch, a clack every 3rd landing with pitch rising 0.9 → 1.25;
   - the finale is a stud-confetti burst plus a sparkle.

   **Light:** pieces drop 5–8 studs and fade in.
6. On landing, the real piece is revealed and the ghost returns to the pool. `BuildFinished`
   fires; an area Base also plays the fanfare. A gamepad or phone buyer feels `Haptics.play
   ("BuildComplete")`.

### Ghosts and budgets

- **`GhostPool`.** Ghosts are pooled, local, non-colliding, shadowless copies. Each new mesh is
  cloned once (`PoolPerKey` 6, `PoolTotal` 160), and later builds reuse it.
  - Every CollectionService tag and every non-visual child is stripped **before** parenting, so no
    other client system ever sees a ghost.
- **Device tiers** (`FxQuality`, owner R11, console and mobile first). Graphics 1–3 is Low, 4–7 Mid,
  8–10 High. At Automatic: phone Low, tablet/console Mid, desktop High; phones are capped at Mid.

  | Tier | Max ghosts | Flown per build | Confetti | Build range |
  |---|---|---|---|---|
  | Low | 24 | 14 | 45 % | 200 |
  | Mid | 40 | 26 | 75 % | 260 |
  | High | 60 | 40 | 100 % | 320 |

  Pieces over the caps fade in place.
- **Per frame:**
  - one RenderStepped connection, connected only while a build animates;
  - one `BulkMoveTo`;
  - no `Instance.new`, tweens, threads, tables or closures.
  - A build that streams out mid-flight aborts cleanly.
- **Knockdown rebuild (owner R50).** `BuildInController.rebuild(model, {starts})` replays the
  fly-in from rubble poses when an attack topples an area; ghosts lift off their rubble and arc
  home. Attacks never take anything permanently.

## 9. World FX: animation by piece name

`WorldFxController` uses one Heartbeat loop, driven by the data table
`src/shared/Config/WorldFxConfig.luau`. **Naming a Blender piece is all an art builder does to
animate it.** The name resolves by exact name, then `Aliases`, then the leading capitalised word.

| Name | Behaviour |
|---|---|
| `Rotor` / `Turbine` / `Fan` / `Wheel` | spin |
| `Dish`, `Arm`, `Wave`, `Streamer`, `Pennant` | oscillate |
| `Belt` | the stud texture scrolls |
| `Glow` | bob + pulsing PointLight |
| `Crystal`, `Core`, `Liquid`, `Bulb`, `VentGlow`, `Flame` | light only |
| `Bubbles`, `Nuke`, `Rocket`, `Ripple` | bob |
| `Steam` | soft puffs |
| `Twirl`, `Whirl`, `Carousel` | slow Y spin |

- **Motion groups (owner R25/R26).** Pieces of one model that resolve to the same row move together.
  `Assemblies[modelKey]` widens a group (`members` / `exclude`): the Nuke-Mobile body and roof
  rocket bob as one while the tyres stay planted.
  - Assemblies can carry a `hinge`, `follow` and keyframed `swing` with `impact` events (rock chips
    + clink + flash). The Glow Rock miners swing picks this way (owner R75).
- **Budgets.** Every 0.5 s, pieces are ranked by camera distance. Only the nearest `MaxMoving`
  move, `MaxLights` light and `MaxSounds` play. Groups outside the view cone are skipped and far
  groups update at half rate. Lights, emitters and belt textures are created on first approach and
  then only toggled. Reduce Motion stops motion; lights stay.
- **Managers** (`kind = "Manager"`) are animated only by `ManagerController`, using the rig groups
  from `_npc_rig.py`.
- **Vehicles** (owner R56) drive authored Catmull-Rom routes (`VehicleRouteConfig`). The Blender
  contract is per-axle `Tyres*`/`Hubs*`, `BrakeLights`, `IndicatorL/R` and `Cargo1..N`, and
  `tests/vehicle-routes.luau` sweeps the routes for collisions.
  - Low tier still drives the nearest 4 routes (owner R103: phones are about 30 % of sessions, so
    "Low = everything static" read as broken).
- **Pets, eggs, crates and towers** rotate prefix groups about joints parsed from the pivot string
  (`docs/pets-art.md` §1). Cache each rest CFrame once and drive all pets from one RenderStepped
  connection.

## 10. Performance rules for art

These are measured, not guessed (`docs/performance.md`). A fully unlocked solo test with 8 full
plots ran at 0.17 ms server heartbeat and 0.5–1.0 ms of client scripts per frame on Low.

- **`Workspace.StreamingEnabled = true`** (`default.project.json`):
  - the plot root streams by region;
  - every build, base and entrance Model is `Atomic`;
  - the owner's Pads and Producer are `PersistentPerPlayer`;
  - hub landmarks are `Persistent`.
- **Unbought content is never instanced.** `PlotBuilder` creates a build only when its pad is bought.
  Locked slots show one cheap placeholder. Upcoming purchases are preloaded (content only, not
  instanced), so their fly-in never waits on a download.
- **One shared MeshPart template per mesh id, cloned.** Repeated things share one mesh id (8
  avenues, 16 lamps, ~30 trees, fence runs), so Roblox instances them.
- **One draw call per piece.** Merge same-colour details; keep ≤ 12 pieces per model.
- **Triangle budgets per model and per fully built area** are enforced by tests
  (`blender-art-pipeline.md` §4).
- **`castShadow = false` on flat floors, lots and tiles.** Shadows on flat ground are wasted.
- **Pool everything that comes and goes:** ghosts, confetti, impact bursts, 3D sound emitters,
  income pops. No `Instance.new` per frame.
- **One RunService connection per system**, with view-cone culling and distance ranking.
- **Billboards** update on change events, never per frame, and have a `MaxDistance` (own
  producers 110, others' 70).
- **Loading.** `MeshLibrary` loads by priority (hub, then own plot, then the rest).
  `Workspace.WorldReady` and per-plot `PlotReady` gate the reveal (owner R16: "the models took
  forever to load in"). The client's critical preload list is kept small (87 ids for a new player,
  owner R122), because Roblox ranks experiences on first-minute bounce.

## 11. Lessons from owner feedback

Recurring rules distilled from `docs/owner-requests.md` (R = request number). Each one became a test
or a pipeline step, so it cannot regress silently.

| R | Owner said (paraphrased / quoted) | Rule now |
|---|---|---|
| R1 | "Use Blender to model the entire tycoon, so it doesn't look grey/primitive" | Scripted Blender for every model; primitives only as load fallback; `tests/mesh-assets` fails on any placed key with id 0 |
| R1 | Pieces "float in and build in front of you", LEGO style | Build-in on every purchase (§8) |
| R3 | Use Missiles vs Cities' "stud-textured nuke models" as the style | Stud MaterialVariant on every surface; candy toy nukes |
| R9 | Icons should look "rendered instead of like flat" | Soft-toon 3D icon pipeline; flat glyphs only as fallback |
| R16 | "the models took forever to load in" | Priority mesh loading, WorldReady/PlotReady, loading screen with a preload list |
| R17 | "text in front of the garage lab is backward" | Double-sided signs; road-view review; MeshLibrary 180° import-yaw fix |
| R18 / R18b | z-clipping on floors and roads | Layer table + `tests/zfight-audit.luau` on real triangles, asserted at 0 |
| R19 | "super bright … make sure it's not overly bright" | Neon ≤ 6 studs² per piece, light caps, per-area glow budget test |
| R24 | "a hedge … going through the garage" | `check_area_overlaps.py` confirmed on triangles |
| R25 / R26 | Rocket doesn't move with the car; caps offset from nuke bodies | Motion groups / Assemblies; piece placement yaw fix |
| R30 / R75 | NPCs "actually move … not just a still prop"; miners "don't actually do anything" | Plan animation before grouping by colour; `_npc_rig` rig pieces; hinged swings |
| R31 / R32 / R48 | Billboards clip into the awning, sit too high, or are blocked | Clear eye-level space; offline-solved spots; clearance test |
| R39 | "in the shop we should use real 3d models" | Shop shows real meshes in pooled ViewportFrames; new small Blender props where none existed |
| R47 / R98 | Mascot "washed out"; shop items "hard to see with the stud background" | Judge colour with `viewport_look.py`; backing plate + idle bob on stud backgrounds |
| R55 | "the center lobby looks like shit" | Hero centrepiece, layered stud tiles, ambient motion, all Blender, soft glow, z-fight 0 |
| R56 / R103 | Animate trucks driving in and out; then "none of the vehicles are animating" | Routed vehicles; Low tier still animates the nearest few |
| R92 / R132 | (workflow) | Builders don't use Studio; the lead does one Studio pass; small changes use `check.sh` only |

**The meta-lesson:** whenever the owner reports an art bug from a screenshot, fix the instance,
then find the root cause (often one shared bug: the import yaw explained R17, R24 and R26), then
add a gate so the whole class of bug fails a test.

## 12. Porting checklist for a new game

1. Write a `docs/world-art.md`-style decision record first: look target and references, signature
   material (prove the choice with a side-by-side Studio experiment), palette module, piece and
   triangle budgets.
2. Define a geometry contract module (hub, plot ring, slot grid, height budgets) and author every
   area in slot-local space. Identity rotation means the model faces the player's approach.
3. Use one data module per area: `base`, `builds[buildKey]`, `pads`, `producer {anchor, click}`,
   `spawnPoint`, with explicit invisible collision. Validate it in a pure test.
4. Server-side: never instance unbought content. Set build-in attributes and tags before parenting;
   use Atomic streaming per build.
5. Client-side: one pooled, tier-budgeted, Reduce-Motion-aware build-in. The real geometry is
   collidable immediately, and the animation is local only.
6. Make animation data-driven by piece name, so art builders animate without code.
7. Port the gates on day one: z-fight layers, interpenetration, glow budget, billboard clearance,
   triangle budgets. Retrofitting them after 500 models cost a full art pass here.
8. Record every owner art complaint in `docs/owner-requests.md` with its rule and gate.
