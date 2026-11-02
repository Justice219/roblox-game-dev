# SellNukes area art — per-area scene notes

One section per area, appended by that area's art builder (B8a areas 1–3, B8b 4–6, B8c 7–8,
B8d 9–10). **Append only — never rewrite another builder's section.** Pipeline, budgets and the stud
material: `docs/world-art.md`. Layout contract: build plan → "World layout" +
`src/server/Tycoon/LayoutLogic.luau` (validated by `tests/area-layouts.luau`).

## Shared conventions (B8a, 2026-10-30)

* **Slot frame.** Everything in `AreaLayouts/AreaNN.luau` is slot-local: origin = road-side edge
  midpoint, +Z away from the road, slot x ∈ [-52, 52], z ∈ [0, 70]. Identity rotation = model front
  (-Z) faces the road. Standing on the road looking at the area, **+X is on your LEFT**.
* **Entry arches.** The Unlock pad's build key `A{N+1}_EntryArch` resolves to `Area{N+1}.base`
  (next area's floor + arch, built on unlock); `builds` lists only the area's own `A{N}_*` keys.
* **Text on a -Z face must advance toward -X**, or it reads mirrored from the road.
  `models/area01.py` `block_text` handles this; use it for any static lettering.
* **Shared Blender helpers** (import from `models.area01`): `block_text` + `text_cells`
  (5x7 brick-pixel font A–Z 0–9 ! $ - '), `entry_arch` (posts, block-letter board, marquee bulbs,
  pocket-nuke finials), `toy_figure` + `toy_face` (chibi NPC body), `wheel`, `tiny_nuke` (~84-tri
  crate filler), `mini_nuke`, `striped_cone` (umbrella), `scallops` (awning valance), `lot_stripes`
  (mowed lawn / paving bands), `round_tree`, `blocky_tree`, `flower_bed`; constants `LOT_TOP`,
  `SLOT_PIVOT`, `SKIN`, `LAWN_LIGHT`, `SOIL`, `BARK`.
* **NPC skin and faces use `Smooth`.** Studs on skin read as dirt.
* **Lots** are one 104 x 70 mesh plate (top y = 0.5, `castShadow = false`), ≤ 2,500 triangles.
* **Repeated props are one mesh placed many times** (fence runs, lamps, scooters, picnic tables), so
  the GPU instances them.
* **Preview spawners** (`tools/blender/studio/spawn_areaNN.luau`) read the layout module itself,
  so a clean run proves keys, CFrames and collision. Each area uses its own folder and origin, and
  everything is cleaned up afterwards.

## Area 1 — Garage Lab (B8a)

A tiny suburban lot: a mowed-stripe lawn with a white curb, stepping stones from a sky-blue
**GARAGE LAB** arch to B4's blue garage, lollipop trees, a back hedge and flower beds by the door.
The player starts with the empty garage shell. Each pad adds something you can see.

| Build key | Models (slot placement) | What appears |
|---|---|---|
| base (plot claim) | `A1_Lot`, `A1_Yard` (identity), `A1_EntryArch` (0, 0.5, 4), `Garage_Floor/WallBack/WallSide x2/WallFront/Roof` at GARAGE = (0, 0.5, 44) | lawn, arch, trees, empty garage |
| `A1_Workbench` | `Workbench` at GARAGE·(-4, 0.6, 6) + `PocketNuke` on it | producer |
| `A1_ToolWall` | `ToolWall` at GARAGE·(7.5, 0.6, 10.5) | pegboard + tool chest (0.5 off the wall so it clears the window sill) |
| `A1_GlowLamp` | 4× `GlowLamp`: inside by the door + outside along the drive (±11.5, 26) | green glow inside and out |
| `A1_GarageDoor` | `Garage_Door` (parked open) | roll-up door |
| `A1_MiniReactor` | `MiniReactor` at BENCH·(2.2, 3.3, 0.5) (clear of the vise) + **`A1_ReactorPack`** at (15.8, 0.5, 40) on the garage's +X wall | bubbling jar + coolant unit outside |
| `A1_PaintStation` | `PaintStation` at GARAGE·(-9.95, 0.6, -0.5), yaw -90, + a mint `PocketNuke` on its turntable | paint booth (clear of the side window trim) |
| `A1_UncleAtom` | **`A1_UncleAtom`** beside the bench, turned toward it | the Manager waves |
| `A1_Driveway` | `Driveway` (0, 0.5, 19.7), flush with the garage slab, + **`A1_NukeMobile`** parked on it | drive + family car |

New B8a models (`tools/blender/models/area01.py`): `A1_Lot` 1,144 tris, `A1_EntryArch` 3,484 (double-sided),
`A1_Yard` 2,712, `A1_UncleAtom` 2,172 (lab coat, goggles with green lenses, a mustache, waving,
holding a pocket nuke), `A1_ReactorPack` 1,784, `A1_NukeMobile` 1,972. With everything bought the
area is 24 models, 35 collision boxes and about 27.4k triangles.

Producer: the billboard anchor sits 6.2 above the bench pivot, below the parked door's bottom edge
(y 8), so it reads through the doorway. The click box wraps the bench and everything on it.
Pads are at z = 10, alternating x = -16, 16, -24, … in buy order. The Unlock pad is at x = -48.
The spawn point is (0, 0.5, 12).

## Area 2 — Nuke Stand (B8a)

A roadside farm stand on a plank deck: a planked counter with crates of candy nukes and a stocked
back rack, a red/white striped awning, and a renamable neon sign towering behind it. Around it are
blocky pines, hay bales, picnic tables with umbrellas, and a white picket fence that wraps the lot
once bought. The arch reads **NUKE STAND** in yellow on a chalkboard panel between barn-red posts.

| Build key | Models | Notes |
|---|---|---|
| base | `A2_Lot` (lawn + plank deck x ±20, z 22–42, top 0.8 + sandy path), `A2_Yard`, `A2_EntryArch` | |
| `A2_Counter` | `A2_StandCounter` at STAND = (0, 0.8, 30) | producer; the right half of the counter top is left free |
| `A2_Awning` | `A2_Awning` (STAND pivot) | canopy rises from 8.6 (front) to 10.4 (back) |
| `A2_CashRegister` | `A2_Register` at STAND·(5.4, 3.5, -1.4) | pink retro register, pop-up `$` |
| `A2_TipJar` | `A2_TipJar` at STAND·(2.3, 3.5, -1.4) | oversized jar of coins with a `TIPS` tag |
| `A2_NeonSign` | `A2_NeonSign` at (0, 0.8, 38.5) | the renamable sign (see `standSign` below) |
| `A2_Cooler` | `A2_Fridge` at (13.5, 0.8, 30.5), yaw 12, `collide = true` | glass-door fridge, **COLD** header |
| `A2_PicketFence` | 12× `A2_FenceRun` 16.6 apart (sides x = ±51 from z 20, back z = 69) | pickets face outward; end posts stand side by side |
| `A2_CashierBot` | `A2_CashierBot` at STAND·(0, 0, 2.2) | hovering mint robot with a smiley screen face (its nuke clears the counter) |
| `A2_PicnicTables` | 4× `A2_PicnicTable` at (±31, 30) and (±31, 50) | striped umbrellas |

**Stand name (StandRename).** The Neon Sign board is double-sided (owner R17).
`Area02.standSign = { cf, backCf, size }`: cf is the slot-local centre of the road-side display
face with LookVector toward the road, backCf is the rear face with LookVector away from the road,
and size is 15 × 4.2 × 0.1. PlotBuilder should mount the filtered stand name on both as a
SurfaceGui (Face = Front) on invisible parts there, default text "Fresh Nukes!". The preview
spawner does exactly this. The mesh piece holding both display faces is named `Panel` inside the
`A2_NeonSign` model.
With everything bought: 26 models, 47 boxes, about 23.6k triangles.

## Area 3 — BoomDash Delivery (B8a)

The HQ of **BoomDash**, an original parody delivery-app brand (orange + sunny yellow, a comic
"boom" starburst with a `B`; no real logos). A light paved plaza with a dark scooter lane loop
(orange edges, white dashes) around a grass island with a star-shaped flower bed. Behind it stands
the white HQ with an orange fascia (logo + **BOOMDASH** block letters), two shop windows showing
shelves of order boxes, and a pickup window with a striped mini-awning. A scooter rack shelter sits
on the left and a parking pad on the right.

| Build key | Models | Notes |
|---|---|---|
| base | `A3_Lot`, `A3_Yard`, `A3_EntryArch`, 4× `A3_Lamp` | lane, island, parking asphalt, trees, lamps |
| `A3_HQShell` | `A3_HQ` at HQ = (0, 0.5, 54) | producer; facade at z 46 |
| `A3_ScooterRack` | `A3_ScooterRack` at (-43.5, 0.5, 36) | 4 U-loop slots, orange shelter, charge kiosk |
| `A3_Scooters` | 6× `A3_Scooter`: 3 nose-in at the rack, 3 riding the lane | walk-through |
| `A3_GPS` | `A3_GPSBeacon` on the roof, HQ·(10, 12, 3) | lattice mast, dish, giant red map pin |
| `A3_MobileApp` | `A3_AppPhone` on the roof, HQ·(-9, 12.1, 3) | phone leaning back, app UI with an ORDER button and a red badge |
| `A3_DeliveryVan` | `A3_DeliveryVan` at (39.45, 0.56, 29.4), `collide = true` | branded van with a mint nuke on the roof |
| `A3_ParkingLot` | `A3_ParkingLot` (identity) + 2× `A3_Lamp` | stall lines, wheel stops, hazard loading zone, P sign |
| `A3_Dispatcher` | `A3_Dispatcher` at (-11, 0.5, 43), `collide = true` | headset, cap, clipboard, desk with a route screen |

**Scooter lane for FX.** `Area03.lane = { center = (0, 0.56, 30), halfLength = 22, radius = 9,
width = 4.5, scooterKey = "A3_Scooter" }` is a stadium centre line. Its straights run along X at
z = 21 / 39, with semicircular ends at x = ±22. The parked lane scooters ride +X on the front
straight. B4 or B6 can move scooter clones along it for "scooters zipping along a lane".
With everything bought: 22 models, 27 boxes, about 27.7k triangles.

### Mobile / console budget notes (owner R11, B8a areas 1–3)

* Block letters are crisp, unbevelled boxes: 12 triangles per letter block instead of 44.
  `block_text` defaults to `bevel = 0`. Single-sided arches dropped from ~4.7k to ~2.7k triangles,
  with no visible loss. Double-sided (R17), they are 3.1–3.5k; the HQ with both fascias is 4.5k.
* Marquee bulbs are 16-triangle Neon gems, and small logo decals use an 8-spike star.
* Crate and shelf nukes use `tiny_nuke` (84 triangles; shelf stock is 6-sided without a core band,
  40 triangles).
* Repeated props are single meshes placed many times: fence runs ×12, picnic tables ×4,
  scooters ×6, lamps ×6.
* Fully built totals: Area 1 ≈ 27.4k, Area 2 ≈ 23.6k, Area 3 ≈ 27.7k triangles. Flat lot plates, the drive and the
  parking paint skip shadows (`castShadow = false`).

### Verification (B8a areas 1–3)

* Blender contact sheet of all 30 models: `assets/blender/previews/_sheet_areas123_iso.jpg`
  (per-model front + iso shots are in `assets/blender/previews/A{1,2,3}_*`).
* All three layouts pass strict `LayoutLogic.validate` (every own build key, pad, producer and
  spawn point). Mesh keys resolve in `MeshAssets`, and every placement and collision box is inside
  its slot.
* Studio: per-builder screenshots were dropped by the lead to unclog the Studio lock. The lead's
  World-QA pass builds these areas through the real PlotBuilder. For a manual edit-mode check:
  `python3 scripts/studio_mcp.py luau-file tools/blender/studio/spawn_area0N.luau`. It builds base,
  all builds and pads at (-3000, 0, -3000 + (N-1)·200). Set `SHOW_COLLISION = true` to see the
  collision boxes, click box, billboard anchor and spawn point, and `STAGE = k` to see the area
  after k purchases.
* Sign renders from the road and from behind (R17):
  `docs/verification/world-art/area0{1,2,3}-signs-both-sides.jpg`.
* **Interpenetration self-check (owner R24):**
  `/opt/homebrew/bin/blender -b --python tools/blender/check_area_overlaps.py -- 1 2 3 [--verbose]`.
  It dumps the real layouts through lune (`tools/blender/dump_area_layouts.luau`), rebuilds every
  model, splits each piece into connected mesh islands and fails when islands of two different
  placed models overlap by more than 0.2 studs on all three axes. Intended overlaps are listed in
  its `ALLOWED` table with a reason (B4's interlocking garage shell, the drive paving over the
  stepping stones, coolant pipes entering the wall). Areas 1–3: **0 problems**. Any area builder
  can run it on their own area numbers.

### R17: mirrored sign text, root cause and fix (B8a, 2026-10-30)

The owner saw "GARAGE LAB" reading backward in Studio. The Blender side is correct: the FBX
conversion (`axis_forward=-Z`, `axis_up=Y` from Blender's Y-forward/Z-up), composed with `rb`, is
the identity, so FBX space = Roblox space. The flip happens on **import**. Decoding the uploaded
models shows every MeshPart with an identity rotation but its position at **(-x, y, -z)** of the
manifest offset (Workbench Cabinet x -3.05 → +3.05; A1_EntryArch Letters z -0.68 → +0.68). So
Roblox bakes a 180° yaw into every mesh's vertices, and `MeshLibrary.spawn` (pivot × offset, no
rotation) renders every piece spun 180° in place. Text mirrors, back details jump to the front,
and multi-part pieces scramble.

* **Global fix (reported to B4 + lead):** in `MeshLibrary.spawn`, mesh pieces use
  `pivot * CFrame.new(piece.offset) * CFrame.Angles(0, math.pi, 0)`. No re-upload is needed.
* **Signs are double-sided anyway (owner R17):** `sign_text` letters both faces. The back copy is
  the exact 180° yaw of the front about the board centre, so every lettered piece in areas 1–3
  (arches, the HQ fascia front + back + both side logos, the COLD fridge, the `$` tab, the TIPS
  tag, the P sign) reads correctly from the road and from behind, with or without that fix.
  `standSign.backCf` gives the renamable sign a rear face too.
* Screen-only lettering (the App Phone's ORDER button) and every non-symmetric piece still depend
  on the MeshLibrary fix.
* **R24 (a hedge through the garage) was the same bug.** `A1_Yard`'s `Hedges` piece spans the back
  hedge (z 68.2) and both side hedges, so its box centre is z 53.15. Spun 180° in place, the back
  row lands at z 38.1, straight through the garage (z 32–56). With the MeshLibrary fix it sits at
  z 68.2. The self-check above found and fixed six real placement clips in areas 1–2 (tool wall /
  sill, booth / window trim, reactor / vise, drive and coolant skid / garage slab, cashier bot's
  nuke / counter, doubled fence posts).
* **World FX from piece names (B4 `WorldFxConfig`).** A piece's leading capitalised word picks its
  motion (`Nuke*` bobs, `Wheel*` spins, `Dish` swivels, `Glow*` bobs with a light). Areas 1–3
  requested `Assemblies` overrides: freeze the held, fridge and phone nukes and the wheel stops;
  CarIdle for the van; the GPS dish frozen; GPS ring and reactor glow as lights only. The counter's
  display nukes bob on purpose. Name new pieces with this in mind.
* **R18 z-fighting (B8a):** fixed the 9 pairs in my own models. The A1_ReactorPack glow disc now
  stands 0.03 proud of the box. On A3_HQ, both fascias rise 0.05 above the wall tops and the back
  fascia starts inside the back wall; the sill band is 0.1 wider than the building; the window
  frame bar is 0.05 off the glass; the pickup counter's back edge ends inside the facade. The
  other 18 Area 1 pairs were in B4's `area1_garage.py` trims and Workbench legs, and B4 has
  fixed them. `tests/zfight-audit.luau` now reports B8a clean (0).
* **R19 glow:** no geometry change. My large Neon pieces are rows of small accents (arch bulbs,
  finial cores, neon-sign tubes, counter nuke cores, charge lights, GPS ring), so `resolveGlow`
  renders them as bright SmoothPlastic and keeps the small accents (lamp bulbs, headlights, faces)
  glowing.

## Area 9 — Space Port (B8d, 2026-10-30)

Builder `tools/blender/models/area09.py` · layout `src/shared/Config/AreaLayouts/Area09.luau` ·
preview `tools/blender/studio/spawn_area09.luau` (folder `SN_ArtPreview_A09`, origin (9000, 0, 9000)).
A candy launch complex: navy walkway with cyan runway lights → round launch platform with a big
white/red orbital rocket and a red lattice gantry; mission control, fuel farm, booster rack, a
turning satellite dish, an astronaut crew and a 79-stud space elevator grow around it.

| Model | Pieces / tris (budget) | Build key | Slot placement (y = 0.5 unless noted) |
|---|---|---|---|
| `A9_Floor` | 10 / 2,572 (4,000) | base | slot origin (cf = identity), `castShadow = false` |
| `A9_EntryArch` | 15 / 4,064 (6,000) | base | (0, 3); double-sided "SPACE PORT" (`area09.text_arch`), clear width 20, ringed planet on top |
| `A9_LaunchPlatform` | 9 / 2,340 (4,000) | A9_LaunchPad | (0, 36); deck r 12, top +3; steps toward the road |
| `A9_Rocket` | 9 / 2,792 (6,000) | A9_LaunchPad | deck top (0, 3.5, 36); ~34 tall |
| `A9_LaunchTower` | 9 / 2,236 (6,000) | A9_LaunchPad | deck (9, 3.5, 36); 44 + mast, arms toward the rocket |
| `A9_FuelTanks` | 10 / 3,172 (4,000) | A9_FuelTanks | (-34, 56) |
| `A9_MissionControl` | 11 / 2,232 (6,000) | A9_MissionControl | (-37, 30); glass front, screen wall inside |
| `A9_BoosterRockets` | 11 / 3,096 (4,000) | A9_BoosterRockets | (21, 55) |
| `A9_SatelliteDish` | 7 / 1,064 (4,000) | A9_SatelliteDish | (38, 28) |
| `A9_AstronautCrew` | 15 / 5,264 (6,000) | A9_AstronautCrew | (22, 22); 4 figures × ~1,300 tris, 4.2 apart |
| `A9_SpaceElevator` | 11 / 3,232 (6,000) | A9_SpaceElevator | (39, 55); top y 79.0 (+0.5 floor < 80) |
| `A9_FlightDirector` | 10 / 1,560 (3,000) | A9_FlightDirector (Manager) | (-20, 22) |

Pads (z = 10, centres 8.25 apart from |x| = 15 so the arch posts never hide one; each in front of
what it builds): launch_pad -15, flight_director -23.25, mission_control -31.5, fuel_tanks -39.75;
astronaut_crew 15, booster_rockets 23.25, satellite_dish 31.5, space_elevator 39.75,
build_mega_facility (Unlock) 48. Producer billboard anchor
(0, 9.5, 22) over the platform steps; click box 14 × 36 × 14 around the rocket; spawn (0, 0.5, 9).

**FX / animation anchors** (names resolve through `WorldFxConfig`; the controller moves each piece
about its own bbox centre):

| Piece | WorldFx row | Notes |
|---|---|---|
| `A9_SatelliteDish.Dish` | `Dish` (oscillate Y ±55°) | bbox centre is on the pivot's vertical axis → swings on its column |
| `A9_BoosterRockets.Lamps` | alias `Bulb` (light) | warm light over the rack |
| `A9_Rocket` (whole model) | — | launch lift = model-level effect (PivotTo +Y, reset); `EngineGlow` (Neon, bottom) = flame/particle anchor. Pieces are deliberately NOT named `Rocket` (that row only jitters one piece) |
| `A9_SpaceElevator.Climber` | — (suggest `Climber = { motion = "bob", amplitude = 14, period = 12 }`) | rest y 22 → rides 8..36 on the column |
| `*.Lights`, `*.Beacon`, `*.Screens`, `EngineGlow`, `Ribbon` | — | static Neon |

**Signs (owner R17):** both arches use `area09.text_arch` — the area01 arch look with block letters on
BOTH faces (`area09.text_both`: the back copy is the front text rotated 180° about Y, so it reads
left-to-right from inside the area; a rotation, never a mirror). Verified from the road and from
inside: `docs/verification/world-art/area09-arch-both-sides.jpg`, `area10-arch-both-sides.jpg`.
No other text geometry exists in areas 9-10.

Notes: the round deck / elevator station use nested collision boxes whose corners lie on the circle
(never poke outside the mesh). Astronauts are an original toy design (round helmet, gold visor,
coloured accent per crew member) built on area04 `toy_figure` proportions; the Flight Director uses
area04 `toy_figure` + a headset helper (`area09.headset`). Floor is 2,572 tris (above the 2,500
"lot" convention) because it also carries the runway lights, apron hazard ring and curbs.

## Area 10 — Mega Nuclear Facility (B8d, 2026-10-30)

Builder `tools/blender/models/area10.py` · layout `src/shared/Config/AreaLayouts/Area10.luau` ·
preview `tools/blender/studio/spawn_area10.luau` (folder `SN_ArtPreview_A10`, origin (10000, 0, 10000)).
The finale skyline: a white reactor dome with a pulsing green Core, twin hyperboloid cooling towers
(58 / 64) with cartoon steam and feed pipes into the drum, a turbine hall with a big spinning yellow
turbine, pylons, a control tower, a pink fusion core — and the **Golden Atom Statue crowning the
dome** (spire on the dome's crown, nucleus at y ≈ 52, orbit rings to y ≈ 64), visible across the map.
Height used: ~78 of the 140 allowed (right tower steam).

| Model | Pieces / tris (budget) | Build key | Slot placement (y = 0.5 unless noted) |
|---|---|---|---|
| `A10_Floor` | 10 / 3,072 (6,000) | base | slot origin; green walkway, plaza ring, perimeter wall, floodlights |
| `A10_EntryArch` | 13 / 5,008 (6,000) | base | (0, 3); double-sided 2-line "MEGA NUCLEAR / FACILITY" + trefoil emblem |
| `A10_ReactorDome` | 8 / 4,132 (6,000) | A10_ReactorDome | (0, 46); drum r 15, crown top +28.6 |
| `A10_CoolingTower` | 11 / 4,984 (6,000) | A10_CoolingTower | (-35, 53); 58 tall |
| `A10_CoolingTower2` | 11 / 5,272 (6,000) | A10_CoolingTower2 | (35, 53); 64 tall, two glow bands |
| `A10_TurbineHall` | 12 / 2,648 (5,000) | A10_TurbineHall | (30, 25) |
| `A10_PowerLines` | 6 / 5,748 (6,000) | A10_PowerLines | (34, 34.5); pylons at x 21 / 34 / 47 |
| `A10_ControlTower` | 11 / 1,808 (5,000) | A10_ControlTower | (-41, 25); ~48 tall |
| `A10_FusionCore` | 8 / 2,752 (5,000) | A10_FusionCore | (-21, 25) |
| `A10_ChiefEngineer` | 13 / 1,604 (3,000) | A10_ChiefEngineer (Manager) | (13, 22) |
| `A10_GoldenAtom` | 6 / 4,044 (6,000) | A10_GoldenAtom (finale → Rebirth) | dome crown (0, 29.1, 46) |

Pads (z = 10, centres 8 apart from |x| = 16, clear of the arch posts): reactor_dome -16,
fusion_core -24, cooling_tower -32, control_tower -40; golden_atom (finale) 16, chief_engineer 24,
cooling_tower_2 32, turbine_hall 40, power_lines 48. Producer anchor (0, 12.5, 27) over the plaza; click box
30 × 28 × 30 around the reactor; spawn (0, 0.5, 9).

**FX / animation anchors** (all resolve through `WorldFxConfig`, no extra code):

| Piece | WorldFx row | Notes |
|---|---|---|
| `A10_ReactorDome.Core` | `Core` (pulsing light) | band round the drum + oculus + strip over the door |
| `A10_CoolingTower*.Steam` | `Steam` (particles) | cartoon puff cluster sitting on the rim; emitter rises from it |
| `A10_CoolingTower*.CoreBand` | `Core` | waist glow band(s) — NOT `Glow` (that row bobs the piece off the shell) |
| `A10_TurbineHall.Turbine` | `Turbine` (spin Z) | 8 symmetric blades → bbox centre on the rotor axis |
| `A10_TurbineHall.VentGlow` | `VentGlow` | roof stack rings + power-post insulators |
| `A10_ControlTower.Radar` | alias `Dish` (oscillate Y) | symmetric bar |
| `A10_FusionCore.RotorGyro` / `.GlowOrb` / `.CorePlasma` | `Rotor` / `Glow` / `Core` | gyro rings spin round the floating orb; plasma torus pulses |
| `A10_GoldenAtom.RotorOrbits` + `.RotorElectrons` | `Rotor` (spin Y) | rings are point-symmetric and electrons come in opposite pairs, so both bbox centres sit on the nucleus axis and they spin in sync |
| `A10_GoldenAtom.CoreHalo`, `A10_EntryArch.CoreRing` | `Core` | pulsing glow |
| `A10_Floor.Lamps` | alias `Bulb` | floodlight light over the walkway |
| `*.Beacon`, `A10_PowerLines.Insulators` | — | static Neon |

Notes: the turbine hall's roof power post (hall-local (4, 14.5, 4)) is where the PowerLines drop
cable lands, so those two placements are coupled (hall (30, 25) ↔ pylons (34, 34.5)). Tower feed
pipes end 0.6 inside the reactor drum (towers at x ±35, dome at (0, 46)); move them together.
Cooling-tower and fusion-pedestal colliders use the nested-box circle method; the tower pipe gets
a rotated box along its run.

**Areas 9-10 quality gates (B8d):** z-fighting audit (owner R18) 23 -> **0** pairs (proud trims,
glass/posts ending inside roofs, crew spaced 4.2 apart, walkway paint stopping at the apron ring).
Glow (owner R19): beacons, the director's button and the fuel gauge stay Neon. Every larger glow
piece (reactor Core, tower CoreBands, plasma, halo, runway/rim lights, screens, insulators, engine
glows) is wider than 6 studs², so `MeshPlacement.resolveGlow` renders it as bright SmoothPlastic in
its light candy colour, and `tests/glow-budget.luau` passes. New big glows should be authored as
`Smooth` + a light colour.

---

## Hub, plot frame, scenery and Harvest Feast (B8e)

Builders: `tools/blender/models/hub.py`, `plotframe.py`, `scenery.py`, `event_harvest.py` (58 models). Layout contract: `src/shared/Config/HubLayout.luau` (header = full shape). Edit-mode
check: `tools/blender/studio/spawn_hub.luau`. Screenshots: `docs/verification/world-art/hub-*.jpg`.

### World map (top-down, +Z = plot 1)

```
                      sea (top -2.4) to r 2000, StudsLarge toy water
              stepped beach r 828-874 (dry sand, sand blocks, wet sand, foam)
          island ground r <= 836 (top -0.4, darker green) — wedges between plots
      plots 1..8 at yaw (i-1)*45 (plot ground top 0, curved front on the r 260 circle)
   ring road r 230-260 (flush curbs, yellow dashes, zebra crossing at every plot road)
 plaza r 0-230 (top 0):
   r 0-86.5  LOBBY CENTRE (owner R55 redesign, see "Lobby centre (R55)" below): toy-nuke fountain
             + giant waving Nukey, fountain-walk tile ring, 8 plot-coloured paths (their R55
             teleport pads at r 62 were removed by owner R134), 7 garden beds, spoke-mouth lamp +
             bunting gateways,
             lime rim; LOBBY SPAWN pad at r 44, yaw 22.5, facing outward at the "SELL NUKES" sign
   r 96      Hub_TitleSign ("SELL" / "NUKES" stud letters, both faces) framing egg district 0
   r 222     Hub_PlotGate over every avenue's outer end: tinted badge + white digit 1-8 both faces
   r 84-230  8 avenues (|x| <= 12 along each plot direction, chevrons tinted per plot) and
             8 districts between them: paving + raised grass bed r 92-194 (top 0.1) + curb stones
               district 0 (yaw 22.5)   egg stands, areas 1-5      (r 132, yaws 8.5..36.5)
               district 1 (yaw 67.5)   egg stands, areas 6-10     (r 132, yaws 53.5..81.5)
               district 2 (yaw 112.5)  crate stall (yaw 102.5) + group chest (yaw 124), r 132
               district 3 (yaw 157.5)  lucky wheel stage + wheel (r 134)
               district 4 (yaw 202.5)  3 leaderboards (r 140, yaws 191 / 202.5 / 214)
               district 5 (yaw 247.5)  codes board (r 132)
             (R55: the feature arc moved in from r 150 so the fixtures frame the lobby centre)
               district 6 (yaw 292.5)  EVENT SQUARE (Harvest Feast decor while the event runs)
               district 7 (yaw 337.5)  park (trees, benches)
             16 street lamps (r 165 beside every avenue), planters, benches, trees, flowers;
             warm white district paving + lime kerbs (R55, same palette as the centre)
```

Yaw convention everywhere: degrees from +Z toward +X (`CFrame.Angles(0, yaw, 0) * (0, 0, 1)`).
Every fixture's front (-Z) faces the hub centre.

### Models

| Key | Pivot | Notes |
|---|---|---|
| `Hub_CenterPlaza` | world origin | R55 (`hub_plaza.py`): warm dais r 84, fountain-walk tiles + lime borders, spawn welcome carpet, lime rim r 80.5-86.5 + yellow inlays |
| `Hub_PlazaSpoke` (x8) | world origin, yaw (i-1)*45 | R55: `Path` tinted = plot colour, white edging + chevrons, r 38.4-80.5 |
| `Hub_PlazaGarden` (x7) | world origin, yaw 22.5+45k (k = 1..7) | R55: raised bed r 48-77 (cream wall, lime kerb, grass 1.3), bushes, pink blooms, topiary |
| `Hub_NukeyStatue` | (0, 12.2, 0), faces the spawn | R55: 31.5-tall waving Nukey; `WaveArm`/`WaveGlove` balanced about the shoulder; `Core` belt soft light |
| `Hub_CoinHalo` | (0, 47.2, 0) | R55: 8 coins r 7, `Carousel` spin |
| `Hub_Coin` | coin centre | R55: floating `Whirl` coin (garden "money trees", spawn carpet) |
| `Hub_BannerPole` | ground centre, banner faces -Z | R55: yellow swallow-tail banner, lime star both faces, `Streamer*` twist |
| `Hub_Bunting` (x8) | ground centre of the span, spoke-local (0, 0.06, 77.6) | R55: two lamp posts (x +-10.6) + yellow/lime `Pennant*` string |
| `Hub_Avenue` (x8) | world origin, yaw (i-1)*45 | `Chevrons` tinted = plot colour |
| `Hub_DistrictWedge` (x8) | world origin, yaw 22.5+45k | paving + grass bed + curb stones |
| `Hub_RingRoadArc` (x8) | world origin, yaw (i-1)*45 | seams fall mid-district on plain asphalt |
| `Hub_Monument` | world origin | R55: toy-nuke fountain r 26.6 (pool 1.7, bowl + curtain, 8 spouts with water arcs, `Ripple` rings), square plinth top 12.2 with "NUKEY" on 4 sides; `Plaque` piece kept |
| `Hub_SpawnPad` | ground centre | R55 restyle: lime rim, big yellow star; still r 9.5, top 1.05 — encloses HubBuilder's 12x1x12 SpawnLocation |
| `Hub_TeleportPad` | ground centre, arrow +Z | **Unused since owner R134** (the pads were removed; the mesh stays in MeshAssets). R55 signpost: `Accent` tinted (rim, arrows, frame, post caps), cream `Label` (dark text) at z +6.12 faces the centre, `Twirl` star on top |
| `Hub_EggStand` | ground centre | egg pivot (0, 4.0, 0); `Accent` tinted per area; `Sign` |
| `Hub_CrateStall` | ground centre | display crate (0, 3.7, -2.9); `Sign` |
| `Hub_LuckyWheelStage` / `Hub_LuckyWheel` | ground / axle (0, 13, 0) | spin the wheel about local Z |
| `Hub_GroupChest` / `Hub_GroupChestLid` | ground / hinge (0, 4.8, 2.3) | open = rotate lid about local X by -105 deg |
| `Hub_CodesBoard` | ground centre | `Screen` 13 x 8.2 |
| `Hub_Leaderboard` | ground centre | `Screen` 12.8 x 17.8, `Frame` tinted, trophy |
| `Hub_Bench`, `Hub_Lamp`, `Hub_Tree`, `Hub_Planter` | ground centre | lamp globe (light anchor) y 12.2 |
| `Hub_TitleSign` | ground centre | pixel-font stud letters (5 x 7 toy font in hub.py `GLYPHS`), nuke on top |
| `Hub_PlotGate` | ground centre on the avenue axis | pillars x = +-14.5, badge (tinted) centre (0, 20.4, 0) |
| `Hub_Digit1`..`Hub_Digit8` | bottom centre, reads from -Z | 4.5 x 6.3 x 0.8 pixel digits, `Digit` tinted; since owner R134 only on the plot gates |
| `Plot_Ground` | plot-local origin | grass x in [-80,-10] and [10,80], curved front |
| `Plot_Road` | plot-local origin | asphalt |x|<=8, curbs to |x|=10 (top 0.4), dashes, edge lines |
| `Plot_Border` | plot-local origin | low wall sides + back, `Cap` tinted = plot colour |
| `Plot_EntranceArch` | plot-local (0,0,4) | `OwnerSign` Front (to hub) + Back (to plot); `Accent` tinted; mini nuke |
| `Plot_LockedSlot` | SLOT-local origin | fence + cones + "COMING SOON" `Sign` + padlock + toy bricks |
| `Scenery_IslandGround` | world origin | disc r 836, top -0.4 |
| `Scenery_BeachArc` / `Scenery_Water` (x8) | world origin, yaw (i-1)*45 | beach r 828-874; sea r 866-2000 |
| `Scenery_Hill`, `Scenery_HillSmall`, `Scenery_TreePine`, `Scenery_Cloud`, `Scenery_CloudBig`, `Scenery_Rock`, `Scenery_Flowers` (tinted), `Scenery_Pond` | ground centre (placed at y -0.4) | wedge + map-edge props |
| `Harvest_*` (8) | ground centre | hay bale, pumpkin (tinted), cornucopia, string lights, autumn tree (tinted), turkey statue, pie stand, arch |
| `Harvest_CornucopiaMini` (~2 x 3 x 4), `Harvest_CornucopiaSmall` (~10 long), `Harvest_PumpkinPile`, `Harvest_Scarecrow` (~6.6 x 9.6), `Harvest_Garland` (road-wide, own poles) | ground centre (garland: road centre) | plot decorations sold for Acorns (B11) |

### HubLayout contract (summary — the file header is authoritative)

* `models`, `collision`, `spawn`, `ground = false` — the subset B5's HubBuilder already reads
  (WorldLayout.luau "HubLayout contract"). `models` = hub + island scenery, always built; every
  entry is named `"<key>_<index>"`, exactly HubBuilder's naming, so anchors can name instances.
  Collision is plain Blocks only: ground discs are 32-gons (8 squares at 11.25 deg steps), round
  bases are octagons (2 squares), plus a 32-box invisible wall at r 880 (the foam line).
* `event.harvest = { models, collision }` — Harvest Feast decor (event service spawns/destroys);
  the same data flat as `event.models / collision / square / squareSize / turkeySpawns (Vector3) /
  npc` (B11's names).
* `leaderboards[1..3] = { cf, size }` — Screen face centre (LookVector out), 12.8 x 17.8.
* `plotDecor[slot]` — plot-local CFrames: `Arch` (Harvest_Garland pivot: road centre 8 past the
  arch, poles on the curbs, swag at y ~ 12.5) and GroundL1/L2/R1/R2 (island, just outside the plot's
  front corners; GroundL3 fits the Turkey statue). B11's lawn slots (LawnA..LawnE) live in its event config.
* `plotFrame = { models, collision, anchors }` — plot-local; `plotTint = true` entries take
  `plotColors[i]`. Anchors: `OwnerSign` (model `EntranceArch`, piece `OwnerSign`, faces Front/Back),
  `YouMarker` (0, 31, 4), `Entrance` (0, 0, 14) facing +Z, `TurkeySpawnPoints`.
* `lockedSlot = { models, collision, sign }` — slot-local, one per still-locked slot:
  `plotOrigin(i) * WorldLayout.slotLocal(k) * cf`.
* `anchors` — `SpawnPoint`, `EggStands[1..10]` (+`HarvestEggStand`), `CrateStall`,
  `LuckyWheelStage`, `GroupChest`, `CodesBoard`, `Leaderboards[1..3]` (CashEarned / Rebirths /
  Playtime, + `screen` / `screenSize`), `PlotGates[1..8]`, `TitleSign`, `EventSquare` (region box),
  `TurkeySpawnPoints`, `FountainJets`, `LampLights`.
* `surfaces[key]` — `{ piece, faces, size, use }` for every SurfaceGui face.
* `plotColors[1..8]`, `areaTints[1..10]`, `keys(group?)` for `MeshLibrary.preload`.

### Integration notes for HubBuilder / PlotBuilder (B5)

0. HubBuilder already consumes this contract (names, `persistent`, `ground`, plotFrame /
   lockedSlot). It falls back to the placeholder hub when ANY HubLayout key is missing
   from MeshAssets, so new hub keys must be built + synced before HubLayout references them.
1. `HubLayout.ground == false`: skip the placeholder discs (the meshes + colliders are the ground).
2. Spawn: the `Hub_SpawnPad` mesh encloses the existing 12 x 1 x 12 SpawnLocation at
   `spawn * (0, 0.5, 0)`, so it can stay as is (setting `Transparency = 1` is cleaner).
3. No plot teleport pads (owner R134, 2026-11-01: "can we remove these little teleports"): the R55
   pads at r 62, their `PlotTeleportPads` anchors / touch triggers / "PLOT N + owner" labels and
   HubBuilder's r 200 neon-portal fallback are all gone, in the lobby and in every extra world's
   hub. Players walk the paths + avenues (the numbered plot gates still read from the lobby) or use
   the Teleport menu. `tests/hub-no-teleport-pads.luau` guards it.
4. Streaming: entries with `persistent = true` (monument, island, beach, sea) should spawn with
   `streamingMode = Enum.ModelStreamingMode.Persistent` so the horizon never pops.
5. Plot frame: spawn `plotFrame.models` per plot at `WorldLayout.plotOrigin(i) * cf` (instance names
   from `name`), put the owner text on `EntranceArch.OwnerSign` Front + Back, the YOU billboard at
   `YouMarker`; build `lockedSlot` for every locked slot and destroy it when that area unlocks.
6. Area floors must sit above the plot grass (top y = 0) — plinths or >= 0.05 raised.

### Performance

Counted from the manifest over the real HubLayout (lune export):

| Group | Models | MeshParts | Triangles | Unique meshes |
|---|---|---|---|---|
| Hub plaza r <= 260 (always streamed, the lobby; R55 redesign) | 214 | 660 | ~144k | 37 |
| Island scenery (ground, beach, sea, 8 wedges) | 217 | 457 | ~92k | 10 |
| Harvest Feast event group (event-only) | 40 | 110 | ~26k | 9 |
| One plot frame + 10 locked slots (slots vanish as areas unlock) | 19 | 73 | ~26k | 8 |

Mobile/console first (owner R11): every repeated thing shares one mesh id (8 avenues, 8 districts,
8 ring-road arcs, 8 pads, 8 gates, 16 lamps, ~30 trees, benches, planters), so Roblox instances them.
Flat floors have `castShadow = false`. There are no PointLights (the globes and bulbs are Neon), and
there are only 16 lamps. The heavy ground, sea and landmark models are `persistent`. Wedge props
stream by distance.

### Lobby centre (R55, L1-lobby 2026-10-30)

Owner: "improve the look of the lobby center. I think the center lobby looks like shit." The old
centre was a flat grey disc with white spokes, a plain rocket fountain and charcoal pad signs in a
sea of grey paving. Builders: `tools/blender/models/hub_plaza.py` (the four old centre builders
left `hub.py`); layout: the "Lobby centre" block of `HubLayout.luau`.

```
r  0-26.6  Hub_Monument: white pool wall, lime band, yellow cap; blue mosaic floor under clear water
           (Smooth, 0.3 transparent); 8 Nukey-coloured toy-nuke spouts on the cap (yaw 22.5+45k)
           spray tapering water arcs that land at r 16 (ripple rings); bowl on a column spills a
           water curtain; square plinth (NUKEY plaques x4) -> Hub_NukeyStatue (faces the spawn)
           -> Hub_CoinHalo (y 47.2)
r 27.6-38.4 fountain walk: lime border, 24 yellow/white tiles (white diamond inlays), lime border
r 38.4-80.5 Hub_PlazaSpoke x8 (plot colour; pad + signpost at r 62); Hub_PlazaGarden in wedges 1-7
           (bench at r 44.2 facing the fountain, banner pole at r 52.5, money-tree coin over the
           topiary); wedge 0 = spawn: yellow/white welcome carpet r 52-80.8 with lime borders, two
           banners wide of the spawn camera, three low coins under the SELL NUKES sign
r 77.6     Hub_Bunting gateway across every path (lamp posts on the 3.5-stud walkway)
r 80.5-86.5 lime rim + 32 yellow diamonds (covers the dais / avenue / district step at r 84)
```

* **Owner R134 (2026-11-01, "can we remove these little teleports")**: the 8 plot teleport pads on
  the paths (pad + signpost at r 62, their colliders, plot-coloured digits, `Twirl` stars, "PLOT N +
  owner" labels and touch triggers) are gone, in this lobby and in the Dino Valley / Moon Base hubs.
  The paths run clear to the avenues; the numbered plot gates at r 222 are the lobby's plot numbers.
  The `Hub_TeleportPad` / `Valley_TeleportPad` / `Moon_TeleportPad` meshes stay in MeshAssets,
  unused (their Blender builders are kept). The lobby visitors' lane nodes stay at r 62.
* **Layers** (z-fight rule): dais 0.06, tiles / rim 0.12, paths / carpet 0.15, borders / inlays 0.18,
  edging / chevrons / carpet borders 0.21. Every curved seam is between different heights. Audit: 0.
* **Motion** (WorldFxConfig rows, words unused by any other piece): `Ripple` bob (fountain rings,
  one group), `Wave` oscillate Z (Nukey's arm; its two pieces' boxes are mirrored about the
  shoulder by `balance_about`, so the MeshPart CFrame IS the joint), `Streamer` (banners twist),
  `Pennant` (bunting swings), `Twirl` (pad stars, 40°/s), `Whirl` (coins, 110°/s), `Carousel`
  (halo, 20°/s). Glow: Nukey's lime belt is `Core` (soft pulsing light, capped by R19).
* **Particles**: `HubLayout.anchors.AmbientFx` (8 Spray on the spout nozzles, 8 Splash at the
  landings, 4 halo + 10 coin Sparkles = 30 emitters) -> HubBuilder builds them once on one
  invisible holder part; presets in `Shared/Config/HubAmbientConfig` (Spray speed / gravity match
  the Blender arc, so droplets ride it). Built-in textures only, low rates, LightEmission <= 0.35.
* **Collision**: pool wall + wade-able water, bowl, plinth, statue, spouts, pad signposts, garden
  beds (rotated boxes hugging the straight edges + centre boxes, all inside the outline so the
  walkway is never blocked), banner poles, gateway lamp posts.
* **Budget** (`tests/hub-layout.luau`): lobby 660 MeshParts / 144.4k triangles / 37 unique meshes
  (was 514 / 106k / 32). Pieces merged wherever colours allow (garden 6, pad 5, banner 3, gateway
  6), the spouts live inside the monument mesh (saves 40+ parts), repeats are instanced. The
  rebuilt B8e keys keep their original triangle budgets (centre 3,000, fountain 6,000 incl. the
  low-poly spouts, pad 1,500, spawn 800).
* **Two-wave load** (perf follow-up: WorldReady 7.10 s -> 9.59 s after the redesign): decor keys
  `HubLayout.deferredKeys` = Hub_PlazaGarden, Hub_Bunting, Hub_BannerPole, Hub_Coin, Hub_CoinHalo,
  Hub_Bench (174 parts, ~42k triangles). HubBuilder builds in two passes on W1b's MeshLibrary API:
  `holdWorldReady(HubHold)` is taken in build(); pass 1 = placements `isNearHub` (200 studs of the
  spawn) that are not decor, preloaded at Hub priority, then the hold is released (pcall-safe);
  pass 2 = far scenery + decor at Background, spawned `deferred` (never holds WorldReady), then the
  ambient particles. Floor, paths, fountain, statue, pads, spawn, signs and every anchor fixture stay
  first wave (tests/hub-layout asserts it).
* **Spawn**: unchanged (r 44, yaw 22.5, facing the SELL NUKES sign). Nukey faces the spawn, so a
  player who turns round sees him wave; the spawn camera itself looks outward over the carpet.
* **Studio QA**: `STUDIO_LOCK_OWNER=<you> python3 tools/qa/hub_lobby_check.py after` (holds the
  lock rule; spawn / statue / aerial / path / garden shots + phone / tablet / console matrix +
  emitter census) -> `docs/verification/world-art/hub-lobby-after-*.jpg`. Old look for comparison:
  `docs/verification/qa/t3-hub.jpg`, `docs/verification/world-qa/20261030-1616/hub_*.jpg`.

### Screenshots

Blender contact sheets plus top-down maps rendered from HubLayout itself. The lead's World-QA pass
takes the Studio shots through the real HubBuilder / PlotBuilder.

* `docs/verification/world-art/hub-map-plaza.jpg`: the lobby top-down (spawn, pads 1-8, gates 1-8,
  egg stands E1-E10, fixtures, event square, plotDecor slots)
* `docs/verification/world-art/hub-map-world.jpg`: the whole island (plots, wedges, beach, sea)
* `docs/verification/world-art/hub-sheet-lobby.jpg`, `hub-sheet-fixtures.jpg`,
  `hub-sheet-plot-scenery.jpg`, `hub-sheet-harvest.jpg`

Edit-mode spawn for manual checks: `tools/blender/studio/spawn_hub.luau`. It lifts everything 300
studs up, shows the event group and plots 1/2/3/8 with all slots locked, and puts sample decor on
plot 1's plotDecor slots. Run `cleanup_preview.luau` afterwards.

### Open issues

* Not yet seen in Studio (the lead's World-QA pass covers it). Positions, overlaps, avenue clearance,
  plot footprints, island bounds, decor slots and anchor-to-model names were all checked
  numerically: a lune validator over the real HubLayout reported 0 problems.
* The entrance-arch pillars (plot x = +-13, z = 1.5-6.5, from the plan's EntranceZ = 4) occupy the
  hub-end corner of slots 1 and 2 (x_s ≈ -48, z_s 0.5-5.5). Area01 and Area02 are clear; keep it
  free in future layouts.
* The plot is fully covered by area slots, so the `plotDecor` ground slots sit on the island just
  outside the plot's front corners.
* Regression: `tests/hub-layout.luau` (lune, run by `scripts/test-logic.sh`). It checks keys,
  names, aliases, colliders, anchors, lobby geometry (beds, avenues, pads, spawn, overlaps), scenery
  and plotDecor clearances, the arch corner in Area01/02, and the R11 budgets.

## Area 7 — Launch Silos (B8c, 2026-10-30)

A slate stud launch deck (16 chamfered plates, white curbs) with a light walkway from a banded
yellow/black **LAUNCH SILOS** arch (black brick letters on cream, mini candy nukes on its corners) to
the main silo. Three 18 × 18 hazard-bordered launch platforms stand at the back, each with a striped
silo collar, a grey four-post stud gantry (open toward the road), a service arm, a ladder and red
post beacons. A chubby 24-stud cartoon nuke stands in each one: **red/black**, **mint/black** and
**white/gold**, all with a glowing green core band and a plain yellow trefoil badge (no faces, no
flags). The left side holds mission control and the radar. The right side holds the attack
console, the launch-director robot, the AA tower base and a striped loading zone.

| Build key | Models (slot placement, deck top y = 0.5) | What appears |
|---|---|---|
| base (Area 6 unlock) | `A7_Deck` (identity, `castShadow = false`), `A7_EntryArch` (0, 0.5, 3) | deck, walkway, lettered arch |
| `A7_SiloPad` | `A7_SiloBase` at SILO_1 = (0, 0.5, 50) + `A7_SiloNuke_Red` at SILO_1·(0, 1.2, 0) | producer "Silo Launches" |
| `A7_Silo2` | `A7_SiloBase` + `A7_SiloNuke_Mint` at (-26, 0.5, 50) | second silo |
| `A7_Silo3` | `A7_SiloBase` + `A7_SiloNuke_Gold` at (26, 0.5, 50) | third silo |
| `A7_RadarDish` | `A7_RadarDish` at (-44, 0.5, 60) | grey/white lattice pylon, the dish sweeps back and forth (WorldFx) |
| `A7_ControlRoom` | `A7_ControlRoom` at (-36, 0.5, 26) | blue block, big window onto glowing consoles, **CONTROL** sign, roof antenna |
| `A7_HazardFloor` | `A7_HazardFloor` (identity, `castShadow = false`) | walkway hazard lanes, cross band, chevrons, 6 bollards, loading zone with 5 barrels |
| `A7_LaunchDirector` | `A7_LaunchDirector` at (27, 0.5, 26) | white/orange headset robot with a clipboard, pointing at the sky |
| `A7_AATower` (Feature) | `A7_AATower` at AA = (43.5, 0.5, 60) | the tower BASE: 14 × 14 hazard plinth (top y 1.5), 4 corner beacon posts, **AA DEFENSE** placard. Attack mode (B10) stands B8f's levelled `AATower1..5` on it |
| `A7_AttackConsole` (Feature) | `A7_AttackConsole` at (16, 0.5, 26) | big red button under a glass flip cover, joysticks, target-map screen, **ATTACK!** sign |

Pads sit at z = 9, 8 studs apart, each in front of what it builds: silo pad −13.5, silo 2 −21.5,
silo 3 +21.5, radar −45.5, control room −37.5, hazard floor +37.5, director +29.5, AA tower +45.5,
console +13.5. The Unlock pad (`A8_EntryArch`) is at −29.5, next to the arch, because Area 8's
arch appears directly across the road. The producer billboard anchor is (0, 9.5, 39): in front of
silo 1 at head height, with the nuke visible above it. The click box (9 × 25 × 9) wraps the red
nuke. The spawn point is (0, 3.5, 20).

**Attack mode fields** (B10's contract, read by `src/shared/Attack/AttackGeometry.luau`; extra
layout fields pass through `LayoutLogic.merge`). All are slot-local and checked with
`WorldLayout.inSlot(7, p, 4)`.
* `launchPoints = { CFrame ×3 }` holds the nose tips of the three nukes, (0 / −26 / 26, 25.7, 50),
  with identity rotation (+Y up), in order silo 1, 2, 3. A projectile rising from there leaves
  through the open gantry top (beams only on the rim, top at y 30.5) without clipping the standing
  nuke. The silo mouth (collar centre) is 24 studs lower. The parallel
  `launchBuilds = { "A7_SiloPad", "A7_Silo2", "A7_Silo3" }` says which build each point needs.
* `aaTowerMount = CFrame (43.5, 1.5, 60)` is the plinth top centre (+Y up, −Z = turret facing).
  B8f's `AATower1..5` (pads 5 × 5 up to 12.16 × 12.16) stand there, so `A7_AATower` is base-only.
  My earlier lattice tower + turret (`A7_AATurret`) were retired and pruned from the manifest.
* `consolePrompt = (16, 4, 23.4)` is the Attack Console ProximityPrompt spot, on the operator side
  just in front of the desk.

**Animatable pieces** (also in `Area07.animations`):

| Model.piece | Driver | Notes |
|---|---|---|
| `A7_RadarDish.Dish` | WorldFx `Dish` (oscillate Y, automatic) | turntable + yoke + bowl + feed + counterweight in one piece; the counterweight puts the piece's XZ bounding-box centre on the pivot axis, so it sweeps in place |
| `A7_SiloNuke_Red / _Mint / _Gold` (whole model) | attack mode | the "Nuke": tween the model pivot up to launch; pivot is under the fins |
| `A7_ControlRoom.Door` | gameplay (WorldFx `Door` = none) | slides +X by 4.4 into a solid wall pocket, never over the window |
| `*.Core` (silo nukes, arch mini nukes) | WorldFx `Core` | pulsing green light |

Static glow is deliberately not named `Glow` (WorldFx would bob it): the control room uses
`ScreenGlow`. Each silo's collision is the platform, the front step, four posts, the nuke body and
a low box over the fins. The gantry beams are out of reach.

Fully built: 14 models (12 unique meshes; `A7_SiloBase` is placed three times), 103 MeshParts,
57 collision boxes, about 30.7k triangles (plus whichever `AATower` level attack mode adds). All
letters are unbevelled (`sign_text`).

## Area 8 — Nuke Megastore (B8c, 2026-10-30)

A candy mall plaza: cream and blush checker tiles, white curbs, and a sky-blue carpet walkway with
warm lamps leading from a **NUKE / MEGASTORE** arch to the store. The arch has candy-cane pillars,
a yellow beam with pink dots, purple brick letters, a star and balloon bunches. The two-storey store
has an open ground floor with three mint checkout counters (the producer) between pink pillars.
Glass display windows show pyramids of boxed nukes. Upstairs is a glass curtain wall behind a
balcony with a candy scalloped valance, under a **NUKE MEGASTORE** roof sign. Nukey stands on the
left with the food court behind him. The parking garage fills the right side, and the escalators
climb from the plaza to the balcony.

| Build key | Models (STORE = (0, 0.5, 55.5), footprint 48 × 26, facade at slot z 42.5) | What appears |
|---|---|---|
| base (Area 7 unlock) | `A8_Plaza` (identity, `castShadow = false`), `A8_EntryArch` (0, 0.5, 3) | plaza, carpet, lamps, corner planters, lettered arch |
| `A8_Storefront` | `A8_Storefront` at STORE | producer "Megastore Checkout": 3 counters, lanes between them |
| `A8_Shelves` | `A8_Shelves` at STORE | 4 double-sided gondolas of boxed nukes, price strips, hanging SALE boards |
| `A8_Escalators` | `A8_Escalators` at STORE (lanes x 13 / 18, bottom slot z 17.5) | twin escalators up to the balcony (walkable ramp) |
| `A8_MascotNukey` | `A8_MascotNukey` at (-36, 0.5, 28) | 21-stud yellow nuke mascot: big eyes, rosy cheeks, smile, waving glove, pink shopping bag, **NUKEY** plaque |
| `A8_Billboard` | `A8_Billboard` at STORE (on the roof, board y 30.5–44.5) | candy nuke art, starburst, **GLOWING DEALS!**, marquee bulbs, catwalk spotlights |
| `A8_FoodCourt` | `A8_FoodCourt` at (-38.5, 0.5, 56) | **GLOW BITES** kiosk, giant frosted donut, 4 umbrella tables with stools |
| `A8_ParkingGarage` | `A8_ParkingGarage` at (38.5, 0.5, 44.5) | ground + L1 (6.8) + roof (13.8), two walkable ramps, 6 toy cars, booth + raised barrier, **P** sign |
| `A8_StoreManager` | `A8_StoreManager` at (-10, 0.5, 37) | pink rolling shop robot: bow tie, name badge, cap, happy "^ ^" eyes, basket |

Pads sit at z = 9: storefront −13.5, shelves +13.5, escalators +21.5, Nukey −29.5, billboard
−21.5, food court −37.5, garage +37.5, manager +29.5. The Unlock pad (`A9_EntryArch`) is at
−45.5, the end toward Area 9. The billboard anchor is (0, 8, 46), just inside the open entrance
above the middle counter and under the first floor. The click box (26 × 4 × 3) wraps all three
counters. The spawn point is (0, 3.5, 20).

Collision: the store shell is enterable. It has side and back walls, the facade pieces, the first
floor and balcony slab with its railing (gap at the escalators), the roof, the counters and the
gondolas. The escalators are one inclined slab over both lanes, with balustrade walls and a middle
divider. The garage has every deck piece, both ramps with an outer rail, columns, parapets, the
railings along the ramp wells, the cars and the booth. Nukey's pedestal is an octagon made of two
crossed squares.

Naming for WorldFx: checkout belts are `Checkout` (not `Belt`, which scrolls). Static neon is
`RegisterGlow`, `SkirtLight` and `MenuGlow` (not `Glow`). Car wheels are `Wheels` (parked toys
must not spin). `Core` pieces (Nukey's belt, the billboard nuke) get the pulsing light.

Fully built: 10 models, 92 MeshParts, 97 collision boxes, about 33.0k triangles. Mobile trims
(owner R11): the shelf stock has one price strip per shelf side, not a label per box (5.3k to
3.6k). The food court has 8-sided stools and a 16 × 8 donut (5.4k to 4.3k). Display-window boxes
are unbevelled and car wheels are 8-sided. All lettering is unbevelled.

### Shared helper (B8c)

`models.area07.sign_text(piece, lines, center, size, border, depth, both_sides=False)` fits
brick-pixel letters (B8a's `block_text`, unbevelled) to a `snkit.kit.sign_frame` panel built with
the same arguments, and returns the cell size it used. `both_sides=True` adds a copy on the panel's
+Z face. The copy is ROTATED 180° about the sign's vertical axis, not mirrored, so it reads
correctly from inside the area.

### Z-fighting (owner R18, B8c)

`tests/zfight-audit.luau` went from 25 B8c offenders to **0**. The fixes, all under rule 2
("never flush"):
* Silo top beams sit 0.1 below the post tops and end inside the posts.
* The hazard-floor lanes butt the cross band instead of overlapping it, so the stripes no longer
  share a plane.
* Control-room trim: the sill, header and posts are proud of the wall cut or run into their header.
  Glass edges are buried 0.1 in the frame, and the corner posts rise into the roof slab.
* The console's target reticle sits on its own depth layer in front of the grid lines.
* The escalator truss runs 0.12 past the first and last step. The newel glass stops short of the
  rail caps.
* The balcony fascia and side stripes top out at 13.05, between the slab (13.0) and the escalator
  landing plates (13.1).
* Display and curtain glass run into the walls.
* The shelf back panels end inside the end posts (±7.25), clear of the board ends (±7.3).

### Glow budget (owner R19, B8c)

22 of the 27 Neon pieces in areas 7–8 are over the 6 studs² box-face limit, so
`MeshPlacement.resolveGlow` renders them as lifted SmoothPlastic and the in-game look already
follows R19. They are over for one of two reasons:
* one piece holds several spread-out accents: corner beacons, marquee bulbs, the parking lights;
* it is a genuinely big glow: screens, the menu panel, the escalator skirts, the nuke core bands.

Neon still shows on the small accents: the arch and control-room beacons, the director's eyes and
the store manager's eyes.

If a future pass wants true Neon on beacons, it has two options:
* split each beacon into its own piece (costs draw calls);
* author the big glows as `Smooth` with a light colour.

`tests/glow-budget.luau` passes.

### Verification (B8c)

* Contact sheets: `assets/blender/previews/_sheet_area07_iso.jpg`,
  `_sheet_area08_iso.jpg` and `_sheet_areas78_front.jpg` (road view, all lettering).
  `_sheet_areas78_arch_both_sides.jpg` shows the arch signs from the road and from inside.
* Studio screenshots are left to the lead's single World-QA pass (lead's call, to unclog Studio).
  `tools/blender/studio/spawn_area07.luau` / `spawn_area08.luau` stage each area pad by pad.
  `SHOW_COLLISION = true` overlays collision, the producer click box, the billboard anchor, the
  launch frames, the AA mount and the console prompt.
* Tests: `tests/area-layouts.luau` (strict), `tests/mesh-assets.luau`, `tests/glow-budget.luau` and
  `tests/zfight-audit.luau` (B8c clean). Both layouts pass the luau-lsp strict type-check, stylua,
  selene and `luau-compile`. The model files are ruff-clean.

### Sign orientation audit (owner R17, B8c)

The Blender "front" preview camera sits on the Roblox −Z side, which is the road. Every lettered
sign reads left to right in `assets/blender/previews/_sheet_areas78_front.jpg`: LAUNCH SILOS,
CONTROL, ATTACK!, AA DEFENSE, NUKE / MEGASTORE (arch), NUKE MEGASTORE (roof), GLOWING DEALS!,
GLOW BITES, NUKEY and the garage P. Both entry-arch signs are double-sided. The road and
inside-the-area views are compared in `assets/blender/previews/_sheet_areas78_arch_both_sides.jpg`.
The A8 arch's candy bands became plain 12-sided drums to pay for the second face. The other signs
face the road or the approach only: their backs are walls, roofs or a billboard back plate.

---

## Z-fighting layer rule (owner R18, B8e)

Owner: "use the z-clipping thing that RoBeasts has to prevent z-clipping". Two visible faces that
lie on the same plane (within 0.004 studs), face the same way and overlap flicker ("z-fight"),
whichever builder made them. This includes two pieces of the same model. Ported from RoBeasts
(`MapGeometry` + the GameMapsTests audit) as `src/shared/World/ZFight.luau` + `tests/zfight-audit.luau`.

**Layers: never share a top plane with anything you overlap.**

| Layer | Top y (plot / slot / hub space) | Examples |
|---|---|---|
| Island ground | -0.4 | Scenery_IslandGround (wedges, behind plots) |
| Plot ground / road slabs / district paving | 0.00 | Plot_Ground, Plot_Road + ring-road asphalt, Hub_DistrictWedge paving |
| Road markings | +0.03 .. +0.05, one plane per marking piece | plot-road lines +0.03 / dashes +0.04, ring dashes +0.04, zebra +0.05 |
| Avenue paving / hub dais | +0.03 / +0.06 | Hub_Avenue, Hub_CenterPlaza (both meet other floors along curves) |
| Area base floor | +0.06 (or a raised plinth) | AreaNN base floor slabs, lots, yards |
| Build floors, rugs, tiles on a floor | +0.12 | floor-pad builds, carpets, plaza tiles |
| Decals, stripes, painted lines | +0.18 | hazard stripes, logos laid on floors |
| Curbs | clearly taller: ring road +0.25, plot road +0.4 | Hub_RingRoadArc / Plot_Road `Curb` |

Rules (each one is something the audit flags):
1. **Butt, don't overlap.** Neighbouring slabs on the same layer meet edge to edge (RoBeasts
   `MapGeometry.fillAround`). If two must overlap, put them on different layers.
2. **Trim and frames never end flush with what they frame.** A trim, cap or frame bar is either
   proud of the surface by >= 0.05 (front, top and sides) or its edges stop inside the other piece.
   Most area offenders are a wall's `Trim` flush with its `Wall`, or a sign `Frame` flush with its
   `Board`.
3. **Stacked bands don't share end caps.** Concentric or stacked layers (beach bands, rings,
   lofted bands) get disjoint ranges or open ends.
4. **Stay inside your footprint.** Area content ends at the slot edge. The plot border sits just
   OUTSIDE the plot (x = +-[80, 81.6], z = [520, 521.6]), so nothing shares its faces.
5. **No curved seams at one height (LOD rule, owner R18b).** Roblox simplifies each MeshPart's
   LOD on its own. Two pieces whose top faces lie on one plane and meet along a CURVE, or come
   within 0.6 studs of each other along one, flicker at range: each side's chords sag differently
   and cross. A chamfer groove does not help.
   - Example: the original ring road had flush curbs at the asphalt's height along r 233 / 257.
   - Fix: give one side its own height (curbs +0.25, dais +0.06, avenue +0.03), or make the seam
     STRAIGHT.
   - The plot road meets the ring road on a straight line: the ring's outer curb is cut at the
     junction (|x| <= 9.9) and its asphalt runs out to that line (RoBeasts `fillAround` style).
6. **Fallback-safe roads.** If meshes fail to load, MeshLibrary renders every piece as its bounding
   box. Road, marking and curb pieces get distinct planes, so even that fallback doesn't flicker.
7. Downward (-Y) faces are exempt (cameras never look up at floor undersides).

**Audit** (`lune run tests/zfight-audit.luau`, in `scripts/test-logic.sh`). It runs three checks:
`ZFight.facePairs` (overlaps), `ZFight.seamPairs` (curved same-height seams on +Y faces, within a
0.6-stud LOD margin) and `ZFight.pairs` (the fallback-box check for the road models).
- It places everything as built in game: the hub, the Harvest event group and 8 plot frames in world
  space; a fresh plot (all 10 slots locked, plot decorations); and a fully built plot (every
  AreaLayout merged like `Tycoon/AreaLayouts.get`, every build, every BuyPad, placed through
  `WorldLayout.slotLocal`).
- It tests the REAL triangles from `assets/blender/world/<Key>.glb`, for any rotation. Pad-vs-build
  pairs that can never be on screen together (the build comes later in `PadOrder`) are ignored.
- Per-owner ratchet `PENDING` in the test: counts may only go down. `LUNE_VERBOSE=1` lists every
  offending piece pair with its plane and overlap area.

**Live in Studio (World-QA):** `ZFight.boxFromPart(part, frame?)` + `ZFight.pairs(boxes)` is the
RoBeasts box pass over visible parts. MeshParts are compared by bounding box, so confirm any hit
with the static audit.

**Counts (2026-10-30)**, before -> after the B8e fixes (face pass): hub 79 -> 0, fresh plot 4 -> 0,
fully built plot 205 -> 157. All remaining offenders are inside area content and were sent to their
owners (B8a 27, B8b 82, B8c 25, B8d 23; B3 BuyPads / placeholders 0).

B8e fixes:
- the plot border moved outside the footprint (it was sharing faces with area floors and walls at
  the slot edges);
- the road curbs no longer meet the border flush;
- the title-sign board now ends inside its frame;
- the stall counter top ends inside its posts;
- the beach bands and sea are radially disjoint;
- the cornucopia bands are open tubes.

**R18b (plot entrance), 2026-10-30.**
- The ring road was rebuilt: raised curbs (+0.25), its outer curb cut at the plot junction, and
  markings on their own planes.
- The plot road starts straight at z = 0, butting the ring's asphalt edge to edge; its curbs reach
  0.1 into the mouth and its asphalt 0.6 into the back wall, so fallback boxes never share planes.
- The hub dais is at +0.06, avenues at +0.03 with markings at +0.07 / +0.09.
- The seam check flags the original ring road (asphalt/curb curved seam, 167 studs) and passes the
  new one.
- B8e: 0 overlaps, 0 curved seams, 0 road fallback pairs. Other owners: B8b 82 overlaps + 5 seams,
  B8d 2 seams (lists sent; ratchets in the test).

**A1-art pass (2026-10-30): every owner at 0, asserted.**
- Counts now: hub 0, fresh plot 0, fully built plot 0 face offenders; 0 curved seams; 0 road
  fallback pairs. `PENDING` / `PENDING_SEAMS` in the test are empty, so ANY offender fails the
  suite (add a temporary `Owner = n` ratchet only while a fix is in flight).
- `ZFight` fixes (all covered by synthetic self-tests at the top of the audit, each verified to
  fail without its fix):
  - **-0 plane keys.** A normal component of exactly zero can come out as -0 (`0 * -4`), which the
    plane key printed as "-0": one plane split into two groups that were never compared. This hid
    4 real offenders (Hub_GroupChest posts vs sign panel, A8_ParkingGarage well columns vs
    railing, A9_SpaceElevator ribbons vs column top, A6_FactoryBoss deck vs frame). `quantise()`
    maps -0 to 0 for every key.
  - **Seams use outline edges only.** A quad's internal diagonal is not a seam (narrow hazard
    stripes' parallel diagonals 0.6 apart used to read as a curve).
  - **Seams are judged per plane.** Seams of one piece pair at different heights (a ring top at
    0.14 and a door band top at 1.1) were pooled and "joined" in 2-D. Each shared stretch now
    counts once, and a seam curves only with `SEAM_MIN_JOINTS` = 2 small-angle joints (one joint
    can be two unrelated straight seams ending near each other).
- Model fixes outside areas 4-6: Hub_GroupChest sign posts at x +-3.38 (were flush with the panel
  sides), A8_ParkingGarage ramp-well columns at x +-4.55, A9_SpaceElevator ribbons stop 0.1 under
  the column top.

## Interpenetration check (owner R24, A1-art 2026-10-30)

`/opt/homebrew/bin/blender -b --python tools/blender/check_area_overlaps.py -- 1 2 3 4 5 6 7 8 9 10`
reports **0 problem pairs in all 10 areas** (allowed: Area 1's garage shell interlock + reactor
pipes, Area 10's coolant pipes into the reactor drum).

How it decides (header of the script is authoritative):
1. Island bounding boxes overlapping by more than 0.2 studs on every axis are only CANDIDATES.
2. Each candidate is confirmed on the real triangles: the depth is the thinnest axis of the box of
   the SOLID intersection A n B, spanned by A's vertices inside B, B's vertices inside A and the
   points where an edge of one crosses a face of the other (mathutils `BVHTree`). Normals are
   recalculated exactly like `snkit.export.realize` first, so "inside" matches what renders.
3. So a prop standing inside a hollow shell (lab, factory, cave) no longer counts, but a hedge
   through a wall still does. Two stale ALLOWED entries (A1 Driveway stones, PaintStation booth)
   were box-test false positives and are gone.

Fixes it drove:
- **A10_TurbineHall roof was shifted half a hall sideways** (`prism()` extrudes symmetrically,
  the outline sat at x = -12.4): half the hall had no roof and the roof overhung 12.8 studs into a
  floodlight pole. The outline is now at x = 0.
- A7_SiloBase: the striped collar ring is notched at the four nuke fins (`_notched_collar`).
- A8_Escalators truss and A8_ParkingGarage ramp A are clipped at the plaza top instead of
  sinking 0.6-0.7 into it.
- A9_LaunchPlatform: the deluge ring stops at the gantry foot (`_arc_tube`), the nozzles and the
  +X clamp block under the gantry plate are gone (the plate anchors that clamp).
- Area 4: floor-level cliff crystals sit on the floor, the back cliff's corner boulders stay out
  of the side cliffs, a lamp and two glow veins moved off the cliffs.
- Area 6: one corner column per factory corner (owned by the side wall).

## Areas 4-6 — Glow Rock Mine, Enrichment Lab, Rocket Factory (A1-art, 2026-10-30)

B8b's builders ended mid-way; A1-art finished the follow-ups. Triangles per fully built area:
A4 23.7k, A5 27.7k, A6 25.8k (budgets in `docs/world-art.md`).

### Area 4 — Glow Rock Mine
- **Signs (R17):** `A4_EntryArch` reads GLOW ROCK / MINE on both faces (Smooth green block
  letters on a cream board, `sign_text`). The foreman's shack board (`A4_ForemanShack`, now 8.2
  wide, red letters) reads FOREMAN from both sides.
- **Foreman (R30):** `A4_Foreman` is N1-npc's rigged figure only; the `A4_Foreman` build places
  `A4_ForemanShack` at FOREMAN plus the figure in front of the counter. Only the shack collides.
- **Glow (R19):** the cliff glows are one static soft-green Smooth `Crystal` piece (no bob, no
  light); derrick and vein glows are soft-green Smooth. Neon remains only on small accents: the
  producer's crystal tips (4.3 studs²) and the arch lanterns (`GlowL` / `GlowR`).
- **Billboard (R32):** the anchor moved from 20.9 studs up to eye level in front of the drill,
  (0, 7.9, 35); nothing blocks it at phone size.

### Area 5 — Enrichment Lab
- **Shell split (billboard + R18):** one shell piece's box covered the whole lab, which pushed the
  billboard out to the lab mouth. Now `A5_LabShell` (front + skylight), `A5_LabSide` (one mesh
  placed twice) and `A5_LabBack` (+13 parts, still inside the area budget). Anchor (0, 8.2, 35.75).
- **Z-fight:** window sills raised 0.1, jambs / mullions off the wall and glass planes, glass edges
  buried, lab bands stop inside the airlock jambs, arch jamb posts clear of the pillar bands, the
  safety-sign "!" proud of its board.
- **Glow:** screens, vat liquid and bubbles, light tubes and drum status dots are light-coloured
  Smooth; Neon stays on the arch beacons (`BeaconLeft` / `BeaconRight`), control panel, blinker
  row, hatch light and flasks.
- **Signs:** the arch board (blank before) reads ENRICHMENT / LAB from the road and from inside.
- Note for B15: `render_brand.py` uses `A5_LabShell`, which is now only the front + skylight.
- **Centrifuge spinners (owner R41, "this spinner was a bit jacked up"):** WorldFx moves every
  piece of ONE model that resolves to the same row as one motion group, so the row's three
  `Rotor*` pieces spun around a single leader and the outer two orbited off their domes. The
  rotors are now their own model, `A5_CentrifugeRotor` (one piece `Rotor`, pivot = drum top
  centre, 364 tris), placed three times at `CENTRIFUGE_ROTORS` in the producer build: one mesh,
  GPU-instanced, each spinning about its own dome axis inside the glass. `A5_CentrifugeRow` keeps
  drums, domes, manifold and panel. The overlap check allows rotor-inside-glass (the dome is a
  solid glass piece). Sheet: `docs/verification/world-art/area05-centrifuge-rotors-before-after.jpg`.
  Rule for future art: never put two separately-spinning pieces with the same WorldFx row in one
  model (only `A10_GoldenAtom`'s two coaxial rotors do, on purpose).

### Area 6 — Rocket Factory
- **Z-fight (58 offenders + 4 seams -> 0):** one column per corner (side walls own them, the back
  wall's bays stop 0.05 inside), column tops inside the coping, coping 0.1 proud, the back coping
  butts the side copings, glass edges run into their frames, mullions run into the panel above,
  roof glass and post tops on their own planes, `_hazard_band_stepped` (black stripes 0.04 lower
  than yellow) for three bands, small offsets on the floor line, paint booth and conveyor shaft.
  N1-npc fixed `A6_FactoryBoss` (frame posts inside the deck).
- **Signs:** the arch reads ROCKET / FACTORY from both sides.
- **Glow:** already small Neon accents only (forklift, dock, quality-check bulbs, line bulbs).
- **Billboard:** anchor moved from the gantry to (0, 7.9, 34.3), clear at phone size.

Sheets (owner R12, opened on the owner's Mac): `docs/verification/world-art/area04-*.jpg`,
`area05-*.jpg`, `area06-*.jpg`.

### Slot-edge floors (World-QA, A1-art 2026-10-30)
`A4_Floor`, `A5_Floor` and `A6_Floor` were `SLOT_W - 0.4` wide, leaving a 0.2-stud strip of plot
grass between them and the neighbouring rows' floors (W1's "grass hairline" at the A3 / A6 slot
edges). They now span the full slot width (x +-52) like every other area floor, so neighbouring
floors butt edge to edge (rule 1; their touching side faces face opposite ways, no z-fight).

## Producer billboard space (owner R31 / R32, A1-art 2026-10-30)

Every area's producer has clear space right in front of it at eye level, and `producer.anchor` sits
there (the server Anchor: tutorial arrow target, click-reach centre). Art changes that made room:
yard trees / hedges / hay split left + right of the driveway (`A1_Yard`, `A2_Yard`, `A3_Yard`:
`TrunksL/R`, `LeavesL/R`, `HedgesL/R`, `HayL/R`), Area 1's paint booth, inside lamps and Uncle
Atom moved toward the door, `A8_Plaza` lamp poles in their own `Poles` piece (they were inside
`Curb`, whose box covered the slot), Area 7's click box 13.4 deep (billboard in front of the
gantry posts), Area 8's click box reaching from the checkouts out under the entrance canopy.
`tests/billboard-clearance.luau` replayed the client placement at phone size on every fully built
area; the client placement is now N1-npc's `Tycoon/BillboardPlacement` solver, and N1-npc owns that
test path (porting its layout / piece-box helpers into a solver-driven audit). The eye-level
`producer.anchor` spots stay as layout data for the solver.

## Shop props (owner R39, A2 shop props art 2026-10-30)

The owner asked for "real 3D models" in the shop (R39). Products that have no game model of their own
(pets, eggs, crates and nukes already do) get small candy-toy props. They are built by
`tools/blender/models/shop_props.py`, uploaded, and synced into `MeshAssets`. Each prop is at most
2,000 tris and 11 pieces. The pivot is the ground centre (lowest point y = 0), the front faces -Z,
and every prop is decorated on both sides because the shop spins it about +Y. The shop camera frames
each prop from `MeshLibrary.getBounds(key)` (sizes below). The shop wiring belongs to W1b-shop.

| Key | Shop product | Look | X x Y x Z (studs) | Tris |
|---|---|---|---|---|
| `Shop_CashStack` | cash (small) | three fanned green bundles, cream "$" bands, toy-gold coins | 3.37 x 2.07 x 2.63 | 1940 |
| `Shop_CashPile` | cash packs | 7-bundle pyramid, "$" on every side, coin stack | 4.15 x 1.59 x 3.36 | 1980 |
| `Shop_GemCluster` | gems (small) | five faceted purple crystals on a light-lilac rock | 2.94 x 3.06 x 2.44 | 570 |
| `Shop_GemChest` | gem packs | open gold-strapped chest heaped with cut gems | 2.58 x 2.81 x 3.04 | 1204 |
| `Shop_SpinToken` | wheel spins | toy-gold coin on edge (light-gold shine rings + star caps), rainbow wheel both faces | 2.84 x 3.22 x 0.82 | 1664 |
| `Shop_BoostPotion` | 2x boosts | glass flask (65 % transparent), bright lime Neon liquid, "2x" starburst | 2.11 x 3.22 x 2.42 | 1360 |
| `Shop_MoneyBag` | x2 cash pass | warm bright tan sack, rope bow, wrapped "$", coins | 2.92 x 2.99 x 3.15 | 1898 |
| `Shop_VipCrown` | VIP | toy-gold crown, light-gold jewelled band, pearls, velvet cushion | 2.80 x 2.13 x 2.89 | 1920 |
| `Shop_ServerBoost` | server boost | blue coin with a rocket bursting through it | 3.11 x 2.76 x 1.31 | 1156 |
| `Shop_Teleporter` | teleporter | hazard pad, swirl, Neon ring, soft light column, hoops | 3.08 x 2.85 x 3.08 | 1852 |
| `Shop_FastShoe` | fast walk | blue sneaker, white sole / laces, yellow bolt, heel wings | 3.94 x 2.51 x 1.95 | 1120 |
| `Shop_AutoClicker` | auto clicker | bright yellow pointing hand + click dashes, white cursor arrow | 2.77 x 3.38 x 1.36 | 908 |
| `Shop_OfflineMoon` | offline earnings | lemon-yellow sleeping crescent, golden craters, deep-purple "Zzz" | 2.76 x 2.93 x 0.95 | 1204 |
| `Shop_PetSlots` | pet slots | magenta-rimmed pet tag, brown paw both faces, green "+" | 2.65 x 2.65 x 0.70 | 1344 |
| `Shop_TripleEgg` | triple hatch | pink / mint / blue candy eggs with yellow spots in a sunny straw nest | 3.70 x 2.44 x 3.07 | 1780 |

Conventions:

* **Text is geometry.** `_dollar`, `_two`, `_letter_x` and `_letter_z` are 2-D outlines extruded by
  `_glyph` / `plate`. A -Z plate maps local +x to the viewer's right, so +Z copies mirror x.
* **Shared helpers:** `_bundle`, `_diamond`, `_capsule`, `_egg`, `_offset_outline` (the cursor's rim
  and the "+" border), `_sphere_patch` (the potion badge) and `_wrap_z` (the bag's "$").
* **Pivot helpers:** `_recentre` (centres the box on X / Z and puts the lowest point at y = 0) is
  used for the shoe, the clicker and the moon. `_ground` (y only) is used for the potion, so it
  still spins about its bulb. GemChest (+0.22 Z, the lid) and ServerBoost (+0.17 X, the flame) keep
  their main body on the spin axis on purpose.
* **Glow (R19):** Neon is used only for small accents, and every Neon piece is under `NeonMaxArea`.
  The pieces are BoostPotion `Liquid`, Teleporter `Ring` / `Beam` (62 % transparent) / `Sparkle`,
  the GemCluster and GemChest `Sparkle`, and the ServerBoost `Exhaust*`. `Crystal` (the GemCluster
  crystals and the GemChest gems) and `Liquid` get the soft WorldFx light. No other piece name
  starts with a WorldFx word.

Colour pass (lead request after owner R47, "very light colored"): shop props must read
candy-vivid in a small viewport. The rules:

* Every main colour keeps one channel at 255 and its lowest channel low. High saturation survives
  both the ~10 % stud darkening and any viewport haze.
* Gold is one saturated `TOY_GOLD` (255, 196, 40). Its accents use the *lighter* `GOLD_LIGHT`
  (255, 228, 104): the crown band, the chest lock, the SpinToken shine rings and the star caps.
  The old darker `GOLD_DARK` band and lock read brown and are gone.
* Recoloured: the TripleEgg shells and nest, the moon and its Zzz, the gold props, the bag tan, the
  PetSlots rim, the GemCluster rock and the potion liquid. The potion glass went from 45 % to 65 %
  transparent so the lime liquid shows through.

Judge colour with `tools/blender/viewport_look.py`, not with the pipeline previews. That script
renders FLAT colour x stud texture with cavity shading, like an ambient-lit shop ViewportFrame. The
Workbench STUDIO previews show colours at about half brightness: lemon (255, 234, 32) renders as
olive (133, 124, 28).

Verification:

* `docs/verification/world-art/shop-props-colour-pass.jpg` is the before / after in the viewport
  look. The "before" is the 556cb44 copy of `shop_props.py`.
* `shop-props-iso.jpg` and `shop-props-front.jpg` are the pipeline previews. `shop-props-120px.jpg`
  is the same set at shop-tile size, where every prop still reads.
* `lune run tests/mesh-assets.luau` and `tests/glow-budget.luau` pass.

## Dino Valley D1 Cave Workshop + D2 Fern Market (W6 art-d12, 2026-10-31)

Owner R57 (World 2 "Dino Valley"); spec `docs/superpowers/specs/2026-10-31-world2-design.md` §2 / §6.2 / §16.
Builders: `tools/blender/models/dino_area01.py` (D1 + the shared Dino helpers), `dino_area02.py` (D2).
Layouts: `src/shared/Config/Worlds/Dino/Layouts/Area01.luau`, `Area02.luau`. They use the same slot
frame and the same `LayoutLogic` contract as `AreaLayouts/AreaNN`, validated against
`Worlds/Dino/Areas/AreaNN`. Previews: `tools/blender/studio/spawn_dino_area0{1,2}.luau`, built at
origin (9000, 0, -9000 - 300·N).

### Shared Dino helpers (`models.dino_area01`, for W7 / W8)

* **Palette** (spec §2): `FERN`, `FERN_DARK`, `JUNGLE_FLOOR`, `MOSS`, `SAND`, `STONE`, `STONE_DARK`,
  `STONE_WARM`, `AMBER`, `AMBER_GLOW`, `BONE`, `LAVA`, `LOG`, `LOG_END`, `BARK`, `THATCH`, `BAMBOO`,
  `CAVE_DARK`, `INK`.
* **Props:**
  * `boulder` (deterministic lumpy rock; centre it at `LOT_TOP + 0.72·r` so it never sinks more than
    0.2 into the lot, R24)
  * `fern`, `palm`, `log` (`ends=` adds proud end-grain discs)
  * `bone` (the cartoon dog-bone)
  * `pebble_nuke` (the Dino product; give the band its own small Neon piece)
* **Arch:** `dino_arch(key, lines, post_style="stone"|"bamboo", ...)`. The board is double-sided
  (R17), it has a bone crest and pebble-nuke finials whose bands are separate Neon pieces.
* **Characters:** `dino_biped(parts, ...)` + `dino_bones(anchors)` build a chunky biped dino with
  the R30 skeleton. Pass `assign={"Tail": "Torso", ...}` to `rig_split`.

### D1 Cave Workshop (20.2k triangles fully built; 11 Neon pieces / 20.2 studs²)

* **Base** (`D1_Floor`, `D1_Jungle`, `D1_CaveCliff`, `D1_EntryArch`):
  * the jungle-floor lot, with a sand path (+0.06) from the arch to a round clearing (r 11)
  * moss patches (+0.1) and stepping stones (+0.18)
  * a mossy sandstone cliff across z 55-70 (5.2k triangles), with side returns x ±(44..52)
    z 46-55 and a cave mouth x ±9, 15 high. Its rim boulders sit on the wall face, and a boulder
    skirt hides the straight foot.
  * palms, ferns and boulders split L / R (R31)
* **Builds:**
  * `D1_StoneBench` is the producer, at z 42.
  * Torch walls (2x) stand at x ±20, z 50.
  * The bone-tool rack is at x 14, z 41 (yaw 25), and the cave paintings at x 31, z 46 (yaw 18).
    The paintings are original doodles: a long-neck and baby, a waving little dino, a sun and a
    pebble nuke.
  * The fire pit is at x -15, z 30, with the leaf bellows at x -22.5 (yaw -90) blowing into it.
  * Rocky Raptor stands at x 5.5, z 47, and log fences (4x) run along both slot edges.

### D2 Fern Market (26.5k triangles fully built; 5 Neon pieces / 11.1 studs²)

* **Base** (`D2_Floor`, `D2_Grove`, `D2_Huts`, `D2_EntryArch`):
  * a sandy market square x ±24, z 18-54 (+0.06) with flagstones (+0.12) and a path stub
  * a grove of palms with coconuts, banana plants, berry bushes, ferns and boulders, split L / R.
    The banana stems live in the low `BananaL/R` pieces, not in `TrunksL/R`. A trunk box that
    reached in to x ±8 (y 12.6) walled in the stall and left the producer billboard no readable
    spot (W10b, R31 / R32).
  * two round thatched huts at x ±22, z 60. They are base decor that is not in the spec list,
    added so the market reads as a village.
  * a bamboo-post "FERN MARKET" arch
* **Builds:**
  * The stall pivot is (0, LOT, 40). It carries the shell counter (the producer; counter top 3.3),
    the leaf awning (poles x ±8.5) and the coconut till at (4, 3.3, 0.1).
  * Stego Sally stands behind the counter.
  * The NUKES! totem is at x -17, z 44, and the mammoth fan at x 16, z 43.
  * Berry baskets (2x) sit at x ±12, z 33, picnic logs (4x) at x ±34, z 24 / 44, and the bamboo
    fence (12x) runs along the sides and back.

### For W10 (WorldFx / managers)

* **New WorldFx rows needed:**
  * `Flame` covers the D1 torch flames `FlameA/B/C` and the fire pit `FlameOuter` / `FlameInner`.
    Suggested row: motion none, light range 8, brightness 0.45, pulse 0.2, flicker.
  * `Ears` is one piece holding both of D2_MammothFan's ears. It is symmetric about the head's
    vertical axis, so its box centre sits on that axis. Suggested row: oscillate about Y,
    amplitude 14, period 1.6. The ear pair sweeps like a desk fan.
* **Existing rows used:**
  * `SteamAnchor` (an invisible box above the fire pit) gets `Steam` puffs.
  * The bench pebble nuke's `NukeStone` / `NukeFins` / `NukeBand` bob as one group (row `Nuke`).
    It hovers 0.45 above its moss pad.
  * Counter pebbles (`Pebble*`) and arch finial bands (`BandL/R`) are static by name.
* **Managers** (register them in `ManagerNpcConfig`; their `ArmR*` pieces would otherwise match
  the `Arm` row). Both have the figure at the model origin with yaw 0.

  | Joint | D1_RockyRaptor | D2_StegoSally |
  |---|---|---|
  | Torso | (0, 1.85, 0.1) | (0, 1.85, 0.1) |
  | Head | (0, 4.205, -0.1) | (0, 4.205, -0.1) |
  | ArmL / ArmR | (∓1.014, 3.5, -0.44) | (∓1.131, 3.5, -0.508) |
  | LegL / LegR | (∓0.624, 1.85, 0.05) | (∓0.696, 1.85, 0.05) |

  Rocky's tail, apron and stripes ride the Torso, and his chisel rides ArmR. Sally's tail, plates
  and apron ride the Torso, and her hat and flower ride the Head.

### Art gates now cover every world (W6 first task)

`tests/zfight-audit.luau`, `tests/glow-budget.luau` and `tests/mesh-assets.luau` iterate
`WorldsConfig.Order` through the new `tests/fixtures/ArtWorlds.luau` helper. Each `WorldDef` gives
its `layoutFolder` and `hubLayout`. Before the registry existed, main was the only world.

* **Layouts:**
  * Main layouts merge with placeholders exactly as before.
  * Other worlds use their authored layouts, which must validate (partial). An invalid layout
    fails all three suites; a missing area file is skipped.
* **zfight-audit:** adds `<id>:hub` and `<id>:plot-fresh` once the world's hub layout exists, plus
  `<id>:plot-full`. Owners are W6 / W7 / W8 for D1-2 / D3-4 / D5-6, and W9 for Base Camp and the
  frame.
* **glow-budget:** every fully built area of every world is held to ≤ 32 studs² of rendered-Neon
  box faces and ≤ 24 Neon pieces. The brightest main area is A4 at 30.3. No primitive layout block
  may be Neon.
* **mesh-assets:**
  * every model ≤ 24 pieces
  * every layout key in MeshAssets and fully uploaded (no id 0)
  * every placed model ≤ 6,000 triangles
  * every fully built area within its world budget: main 36k / finale 42k (the measured ceiling),
    Dino 28k / finale 34k (spec §15)

### Verification

* Contact sheet: `assets/blender/previews/_sheet_dino_d12_iso.jpg`.
* Composed area renders: `docs/verification/world2/d0{1,2}-{front,iso,top,arch-front,arch-back}.jpg`.
  They are Blender Workbench renders of the real layout, with every model and pad placed.
* Studio edit-mode captures (studio lock held, cleaned up after):
  `docs/verification/world2/d0{1,2}-studio-{front,iso,arch}.jpg`.
  * D1: 135 MeshParts, D2: 183 MeshParts.
  * All meshes loaded: 0 fallbacks, 0 missing.
  * The arch reads correctly from inside the area.
  * The preview scripts load fresh module copies, so newly synced keys resolve without a Studio
    restart.
* **R24:** `/opt/homebrew/bin/blender -b --python tools/blender/check_area_overlaps.py -- --world
  dino 1 2` reports D1 and D2 at **0 problem pairs**. The `--world` flag was added by W7.
* **Suites:**
  * zfight `dino:plot-full`: 0 face offenders, 0 curved seams.
  * glow-budget and mesh-assets pass.

## Dino shop props (W9, R57)

The Dino Valley shop section (spec `2026-10-31-world2-design.md` §9 / §16, owner R39 "real 3d
models") gets four props, built by `tools/blender/models/shop_props_dino.py` (own `BUILDERS`; it
reuses `_recentre`, `_egg_profile`, `_ribbon`, `_segment`, `TOY_GOLD` / `GOLD_LIGHT` from
`shop_props.py`). **W5 (ShopConfig / ShopModels) maps the products `BonesSmall` / `BonesMedium` /
`BonesLarge` / `TimeTravelerPack` to these keys.** All four are uploaded and synced: every piece has a
MeshId in `MeshAssets.luau`.

Contract (same as the R39 props above): the pivot is the ground centre (`_recentre`, so the lowest
point is y = 0 and the box is centred on X / Z). The front faces -Z. Each prop is decorated front and
back for the turntable. Budget is <= 2,000 tris and <= 12 pieces. Main surfaces are StudsSmall.
Smooth is used only for tiny glints, numerals and hands. Neon is used only for the `Sparkle` stars.

| Key | Product | Look | X x Y x Z (studs) | Pieces | Tris |
|---|---|---|---|---|---|
| `Shop_BonesSmall` | "Pile of Bones" | three smooth cream dog-bones loosely crossed, amber glint streaks, one Neon sparkle | 2.58 x 2.13 x 2.40 | 3: Bones 1254, AmberGlint 144, Sparkle 56 | 1454 |
| `Shop_BonesMedium` | "Sack of Bones" | seven bones on a lumpy sand mound (two stuck in the sand), two amber nuggets, a fern sprout | 3.00 x 1.98 x 2.50 | 6: Bones 1376, Sand 112, Amber 84, AmberLight 48, AmberGlint 96, Fern 168 | 1884 |
| `Shop_BonesLarge` | "Crate of Bones" | woven leaf basket (fern body, lime weave, bamboo rim) overflowing with ten bones, two cut amber gems, two Neon sparkles | 3.13 x 2.55 x 3.13 | 8: Bones 1280, BoneShade 60, Basket 64, Weave 96, Rim 64, Amber 96, AmberLight 56, Sparkle 112 | 1828 |
| `Shop_TimeTravelerPack` | "Time Traveler Pack" | toy-gold pocket watch on its edge (purple dial, cyan time spiral, white XII / III / VI / IX, 10:10 hands on BOTH faces), amber-tied bone bundle, speckled lavender ptero egg | 3.94 x 2.89 x 1.35 | 8: WatchGold 268, WatchShine 240, Dial 76, TimeSpiral 284, Numerals 312, Bones 588, BundleTie 60, EggShell 160 | 1988 |

How they are built:

* **Bones** match the currency look from the spec: a chunky cartoon dog-bone in bone cream
  (255, 242, 206) with an amber glint. `_bone` makes a round shaft plus two overlapping knobs at each
  end, squashed a little along the face normal. There are no skulls, teeth or claws anywhere.
* **Bone detail levels.** A smooth knob needs <= 35 deg between faces (`SHARP_ANGLE`).
  * `hi` (Small only) is a revolve with 30 deg steps on the knob's visible side. Its buried inner
    cap is cheap: 88 tris a knob, 418 a bone.
  * `lo` has 8-sided knobs: 224 tris a bone, or 128 for a bone with only one end showing.
  * `min` has 7-sided knobs (the pack's bundle).
  * The heaps are framed smaller in the viewport, so their facets never read.
* **Stacking.** `_Pile.drop` lowers each bone onto the ground surface (mound or heap filler) or onto
  bones already placed, using proxy spheres for the knobs and shaft samples. The optional `settle`
  searches the pitch so the bone rests on supports on both sides of its middle. Nothing floats,
  nothing balances on one point, and no bone sinks below y = 0.
* **The pack's dial reads correctly from both sides.** The dial disc and the spiral go through the
  case, so they show on both faces. The numerals and hands are separate thin plates on each face, so
  the back also reads XII at the top, III on the right and 10:10. The egg's speckles share the cyan
  `TimeSpiral` piece, which keeps the pack at 8 pieces.
* **Glow (R19).** Neon is used only in `Sparkle`: one 0.44-stud star (Small), and two stars inside a
  1.9 x 1.6 box (Large, 3.1 studs², under `NeonMaxArea` 6). No piece name starts with a WorldFx
  word, so nothing moves or gets a light.
* **Uploaded.** The model ids are Small 94495927385487, Medium 112730096038689, Large
  70549375384308 and Pack 76756448461224 (`upload-receipts.json`). `sync_meshes.py --check` is up
  to date. `lune run tests/mesh-assets` and `tests/glow-budget` pass.

## Moon shop props (W1b, R70)

The MOON BASE shop section (spec `2026-10-31-r69-moon-lucky-juice-design.md` §2.6 / §2.7, owner
R39 "real 3d models") gets four props, built by `tools/blender/models/shop_props_moon.py` (own
`BUILDERS`; reuses `_recentre` from `shop_props.py`). W1's ShopConfig Moon section maps the products
`MoonRocksSmall` / `MoonRocksMedium` / `MoonRocksLarge` / `AstronautPack` to these keys. All four are
uploaded (models 90261339201947 / 129187623627432 / 128102751970312 / 95547613055742, Approved) and
synced: every piece has a MeshId in `MeshAssets.luau`; `tests/model-viewport.luau` checks every
world-section row's product, icon and prop.

Contract (same as the R39 props): pivot = ground centre (`_recentre`), front -Z, decorated front and
back for the turntable, <= 2,000 tris and <= 12 pieces, StudsSmall main surfaces, Smooth for tiny
details, Glass (55 % transparent) only for the helmet bubble, Neon only for specks / stripes / the
sparkle (far below NeonMaxArea). Piece names avoid WorldFx words.

| Key | Product | Look | X x Y x Z (studs) | Pieces | Tris |
|---|---|---|---|---|---|
| `Shop_MoonRocksSmall` | "Bag of Moon Rocks" | two faceted lilac rocks side by side, one on top, a pebble; craters all round, cyan Neon specks + sparkle | 2.52 x 2.43 x 1.65 | 5: Craters 308, Rocks 112, RocksAlt 112, Sparkle 56, Specks 96 | 684 |
| `Shop_MoonRocksMedium` | "Sack of Moon Rocks" | plump frilled lilac-grey sack, gold rope tie + bow, yellow star patch front and back, rocks spilling from the top and at its foot | 2.24 x 3.29 x 2.30 | 8: Craters 336, Rocks 168, RocksAlt 168, Rope 176, Sack 350, Sparkle 56, Specks 96, StarPatch 72 | 1422 |
| `Shop_MoonRocksLarge` | "Crate of Moon Rocks" | white space crate with slate edge frames and thin cyan Neon stripes, heaped with nine rocks and three cut cyan star shards | 2.56 x 2.95 x 1.86 | 9: Crate 44, CrateFrame 528, Craters 504, Rocks 280, RocksAlt 224, Shards 84, Sparkle 56, Specks 144, Stripes 24 | 1888 |
| `Shop_AstronautPack` | "Astronaut Pack" | the Rocket Corgi: a corgi head (pointy ears, cream blaze, big eyes, tongue) in a Glass bubble helmet with a white collar, gold band and antenna, on a lilac star crate | 1.76 x 3.23 x 1.76 | 10: Band 208, Blaze 112, Bubble 288, Collar 180, CrateStars 144, Fur 116, Ink 128, Pink 48, Shine 48, StarCrate 44 | 1316 |

How they are built: `_rock` is a 5 x 7 ellipsoid (56 tris) bumped per vertex by `_hash01`, a
deterministic hash (no RNG, so the upload content hash is stable across rebuilds); `_craters` lays
flat dark-lilac discs on each rock all the way round; `_pile` alternates lilac / bluer-lilac rocks so
neighbours separate in the viewport; colours are lifted ~10 % over the WorldsConfig colour because the
stud map darkens props.


## Dino Valley D3 Ptero Post + D4 Geyser Springs (W7 art-d34, 2026-10-31)

Builders `tools/blender/models/dino_area03.py` / `dino_area04.py`; layouts
`src/shared/Config/Worlds/Dino/Layouts/Area03.luau` / `Area04.luau` (same contract as
`AreaLayouts/AreaNN`, strict `LayoutLogic.validate` = 0 problems); previews
`tools/blender/studio/spawn_dino_area03/04.luau` (W6's spawner, only `AREA` differs). Both areas use
the main slot conventions: floor slab top y = 0.4 (`FLOOR`), arch at z 18, pads at z 9 alternating
±11, ±20, … in buy order (Unlock pad last), spawn (0, 3.4, 13). Managers use W6's shared
`dino_biped` / `dino_bones` so all six Dino managers have one body. `dino_area03.py` also exports
the helpers `dino_area04.py` uses: `leaf`, `fern`, `palm`, `boulder(…, floor=)` (flat-bottomed at
the floor so rocks never cut > 0.1 into a slab, R24), `parcel`, `pebble_nuke`, `basket`, `balance`
(hinge-centring cube, like `hub_plaza.balance_about`), `arch_sign` (double-sided, R17).

### D3 Ptero Post (22.3k triangles / 114 MeshParts fully built; 2 Neon pieces / 2.9 studs²)

| Build key | Models (slot placement) | What appears |
|---|---|---|
| base | `D3_Floor` (0, 0, 35), `D3_EntryArch` (0, 0.4, 18), `D3_Jungle` (0, 0.4, 0) | jungle grass + sand walkway, log-post **PTERO POST** arch, back palms / boulders / ferns |
| `D3_NestTower` | `D3_NestTower` (0, 0.4, 50) + 2× `D3_PteroCourier` perched on the deck (y 20.2) | producer: tree trunk, twig nest deck, canopy to y 34, spiral bamboo parcel chute to the sorting counter (z 40) |
| `D3_RopeBridge` | `D3_RopeBridge` (−31, 0.4, 50) | lookout tree + sagging plank bridge to the nest rim (ends 0.15 short of it) |
| `D3_ParcelBaskets` | 2× at (±13, 0.4, 40.5), yaw ∓15 | wicker baskets heaped with parcels |
| `D3_WindSock` | (41, 0.4, 23) | bamboo pole, striped sock + ptero-head counter-vane |
| `D3_PteroFlock` | (−38, 0.4, 30), yaw −50 | teal / coral / lilac pteros on a driftwood perch |
| `D3_TreasureMap` | (40, 0.4, 50), yaw 50 | parchment map (dotted route, red X, palms, volcano) |
| `D3_LandingPad` | (28, 0.4, 34) | woven deck on a stone ring, footprint target, 4 soft lanterns |
| `D3_CaptainPtera` | (17, 0.4, 26), yaw 20 | manager: teal ptero postmaster (cap, neckerchief, satchel, parcel) |

Producer click box `TOWER * (0, 11, −2.6)`, size (17, 22, 17.2); billboard anchor (0, 7.9, 36.3) —
the eye-level spot in front of the counter is clear of every visible piece box (R31 / R32).

### D4 Geyser Springs (24.7k triangles / 116 MeshParts fully built; 3 Neon pieces / 3.9 studs²)

| Build key | Models (slot placement) | What appears |
|---|---|---|
| base | `D4_Floor` (0, 0, 35), `D4_EntryArch` (0, 0.4, 18), `D4_Rocks` (0, 0.4, 0) | sandy-stone ground, flagstones, puddles; boulder-pillar **GEYSER SPRINGS** arch with a mini geyser; back-corner outcrops + bamboo clumps |
| `D4_GeyserVent` | (0, 0.4, 46) | producer: vent mound, water jet (`Column`), bamboo pump spout over a bench of three pebble nukes (z 39) |
| `D4_BambooPipes` | (0, 0.4, 46) (same pivot as the vent) | pipe runs at y 1.6: +X to the wheel riser (x 26), −X to the springs inlet (x −20.85) |
| `D4_WaterWheel` | (34, 0.4, 46), yaw 90 | 12-paddle wheel facing the road, trough, riser + aqueduct |
| `D4_SteamWhistles` | (40, 0.4, 28), yaw 30 | four bamboo whistles with sculpted puffs |
| `D4_HotSprings` | (−31, 0.4, 47) | raised + ground pools, cascade, ripples, a baby dino with a towel |
| `D4_PressureValves` | (18, 0.4, 31), yaw 15 | manifold, three valve wheels, two gauges |
| `D4_MegaGeyser` | (0, 0.4, 61.5) | hero: three mineral terraces (moss / amber / teal), jet to y ~31, rope fence arc, "WHOOSH!" board |
| `D4_ParaPete` | (10, 0.4, 29), yaw 25 | manager: lime parasaurolophus plumber (bill, tube crest, overalls, goggles, bone wrench) |
| `D4_StoneSteps` | (−42, 0.4, 27), yaw −90 | rock lookout, 4 real steps (collision stairs), log bench, railing |

Producer click box `VENT * (0, 6.5, −1)`, size (15, 13, 14); billboard anchor (0, 7.9, 35.5), spot clear.

### For W10 (WorldFx, routes, managers)

* **Spin, existing `Wheel` row:** `D4_WaterWheel.Wheel` + `WheelTrim` (rims, 12 paddles, 8 + 8 spokes,
  hub; box centres on the axle (0, 7.2, 0), local X). Suggest a slower Dino speed through
  `Assemblies.D4_WaterWheel` (e.g. 40°/s).
* **Bob, `Column`:** `D4_GeyserVent.Column` + `ColumnFoam` and `D4_MegaGeyser.Column` + `ColumnFoam`
  (jets start inside their mounds, so a bob ≤ 1.5 never shows a gap). **Do not add a global
  `Column` row** (A6 / A9 have static pieces called Column); key it by model in `Assemblies`.
* **Swing, new row:** `D3_WindSock.Sock` + `SockStripes` (box centres on the pole axis; e.g.
  `Sock = { motion = "oscillate", axis = "Y", amplitude = 30, period = 4.5 }`).
* **Existing rows:** `D4_HotSprings.Ripple` (×2 rings, 0.07 above the water), `Steam` anchors in
  `D4_GeyserVent`, `D4_SteamWhistles`, `D4_HotSprings`, `D4_MegaGeyser`.
* **Routed flyer:** `D3_PteroCourier` (2 rest placements on the nest deck: build `D3_NestTower`
  indices 2 and 3). Pieces `Body`, `Belly`, `Beak`, `Eyes`, `WingL`, `WingR`, cargo `Parcel` +
  `ParcelTie`. Each wing's box is centred on the body centre line (0, 2.6, z) (a 0.04 balance cube
  sits in the opposite wing tip), so an oscillation about local Z flaps it about the shoulder; the
  routed model is never moved by WorldFx (R25), so flapping needs a VehicleRoutes hook. Add the key to
  `VehicleRouteConfig.RoutedModels` and `WorldFxConfig.RoutedModels`.
* **Managers (R30):** `D3_CaptainPtera` (parcel + right membrane ride `ArmR`), `D4_ParaPete` (bone
  wrench rides `ArmR`, crest rides `Head`), tails ride `Torso`. Same joints (W6's body):
  `figure = { base = (0, 0, 0), yaw = 0 }`, Torso (0, 1.85, 0.1), Head (0, 4.284, −0.1),
  ArmL (−1.053, 3.555, −0.463), ArmR (1.053, 3.555, −0.463), LegL (−0.648, 1.85, 0.05),
  LegR (0.648, 1.85, 0.05). Until `ManagerNpcConfig.ownsModel` returns true for them, their
  `ArmL*` / `ArmR*` pieces resolve to the `Arm` WorldFx row (oscillate) — register both keys.
* **Static on purpose:** `Puffs` (sculpted steam), `Valve*`, `Amber*` (pebble-nuke cores; small
  Neon, no FX word), `Lanterns` (Smooth soft glow).

### Verification (W7)

* Blender builds within budget; contact sheets `assets/blender/previews/_sheet_dino_area03_iso.jpg`
  / `_sheet_dino_area04_iso.jpg` looked at and fixed (crests swept back, water columns rebuilt as
  wobbly jets with foam, rocks flattened onto the floor, pipe starts clear of the mound).
* R24: `check_area_overlaps.py` now takes `--world <id>` (W7, with W6's go-ahead;
  `dump_area_layouts.luau` reads `WorldsConfig.get(id).layoutFolder`, ALLOWED rows keyed by world;
  without the flag main behaves exactly as before). Run
  `/opt/homebrew/bin/blender -b --python tools/blender/check_area_overlaps.py -- --world dino 1 2 3 4 5 6`:
  D1 0, D2 0, D3 0, D4 0, D5 0, D6 0 problem pairs (2026-10-31); main Area04 regression still 0. R18: `tests/zfight-audit.luau` (world-aware, W6) — dino plot-full 0 face
  offenders, 0 curved seams. R19: `tests/glow-budget.luau` green. R31: billboard spots clear.
* Uploaded (24 models, 218 pieces, all ids live; `sync_meshes.py --check` up to date).
* Studio (edit mode, `spawn_dino_area03/04.luau`, studio lock W7): D3 141 MeshParts, D4 146,
  0 primitive fallbacks, 0 missing keys, every collision box valid. Captures in
  `docs/verification/world2/`: `d03-` / `d04-` `front`, `iso`, `archfront`, `archback` (both arch
  faces read correctly, R17), `producer`, plus the contact sheets `d03-sheet` / `d04-sheet`.

## Dino Valley D5 Fossil Lab + D6 Volcano Reactor (W8 art-d56, 2026-10-31)

Owner R57; spec `docs/superpowers/specs/2026-10-31-world2-design.md` §2 / §6.2 / §16.
Builders: `tools/blender/models/dino_area05.py` (D5 + W8's helpers), `dino_area06.py` (D6, the finale).
Layouts: `src/shared/Config/Worlds/Dino/Layouts/Area05.luau`, `Area06.luau` (same slot frame and
`LayoutLogic` contract as `AreaLayouts/AreaNN`). Previews: `tools/blender/studio/spawn_dino_area0{5,6}.luau`
(W6's spawner, AREA = 5 / 6; origin (9000, 0, -9000 - 300·N)).

### W8 helpers (`models.dino_area05`, importable, no side effects)

* **Managers use W6's shared body** (`models.dino_area01.dino_biped` + `dino_bones`, figure at the
  model origin, yaw 0), like D1-D4, so every Dino manager has the same proportions and joints. W8
  only adds clothes / species details from its anchors: `biped_geometry(a)`, `body_shell` (coat /
  vest shell 1.04x the body + cream front + optional lapels), `trike_head` (frill + horns),
  `goggles`, `hard_hat`, `back_bumps`. The Golden T-Rex is the same body at 3.2x (`place_new`).
* `dino_arch(key, lines, inner, max_cell, letter_color, stone_colors, topper)` — D5 / D6's
  themed arch: stacked mossy stone posts, log beam with rope lashings, plank board lettered on both
  faces (R17), torch bowls (every Dino area has its own arch style).
* `place_new(pieces, build, xf, scale)` (draw at the origin, move only the new vertices),
  `text_both_at`, `ribbon` (strip on a surface: lava streaks / cracks), `fern`, `palm`, `boulder`,
  `bone_shape`, `egg`, `clipboard`.

### D5 Fossil Lab (23.0k triangles / 11 models fully built)

* Base: sand stripes, stepping stones to a flagstone plaza (r 15) round the hut, low mossy wall
  (sides z 20..70 + back), ferns, two back-corner palms; "FOSSIL LAB" arch with a giant bone crest.
* Builds: `D5_LabHut` (producer; round adobe hut, 3-tier thatch, bone weathervane, 4 portholes,
  chimney `SteamA`, porch `Lamp`), `D5_AmberJars`, `D5_Microscope` (giant, climbable-looking ladder),
  `D5_Incubators` (3 speckled eggs `Wobble*`, heat `Lamp`), `D5_DustingBrushes` (ammonite slab,
  giant brush), `D5_Skeleton` (hero 4.0k: friendly long-neck on a museum plinth, velvet rope),
  `D5_DigSite`, `D5_DrTrike` (manager), `D5_MuseumBanners` (bunting `Pennant*`).

### D6 Volcano Reactor (30.6k triangles fully built incl. 2 turbines + 2 pumps)

* The volcano is ONE parametric shape (`vr(a, y)` in `dino_area06.py`: concave flared profile ×
  angular lumps) shared by every piece that touches it: `D6_VolcanoBase` (y 0..20, door + core
  window, west terrace y 14..14.9, outlet hoods at x ±7.5, streaks, collar over the seam) and
  `D6_VolcanoTop` (y 20..38 rim, crater pool, islet top 36.4) on one pivot (slot (0, 0.5, 48)).
  `D6_ObsidianCrown` uses that pivot too; `D6_GoldenTRex` stands on the islet (statue crown ~66).
  A first, taller profile (rim y 50) read as a chimney in Studio; the squat cone replaced it.
* Coupled numbers (layout constants are printed by the builder, move them together): channel
  troughs end 0.15 short of the outlet hoods (volcano-local z -19.633, `CHANNEL_LEN` 10.217);
  the sky bridge deck runs spire-local (2.516, 15.125, 0.656) → (33.564, 15.125, 8.756) and rests
  on the terrace top at 194.6° (railing gap there); turbines sit at (±7.5, 24) astride the troughs.
* Builds: lava channel, 2 stone turbines, steam vents, 2 magma seesaw pumps, crystal core with a
  floating ring, lava falls cliff, sky bridge, obsidian crown, `D6_ChiefTyra` (manager), and the
  finale `D6_GoldenTRex` (3.2× gold T. rex cheering with a crown; no Neon).
* Pads: x ±16..48 at z 10; the finale pad waits alone on the path at (0, 14); spawn (0, 0.5, 7).

### For W10 (WorldFx / managers)

* **New rows requested:** `Lava` (motion scroll, ~1.5 studs/s) for `LavaFlow` (D6_LavaChannel:
  trough strips along local Z + basins) and `LavaFall` (D6_LavaFalls: top stream + fall ribbon);
  `Wobble` (bob, amplitude ~0.08, period ~0.7) for the three D5_Incubators eggs `WobbleEgg*` +
  `WobbleSpots*` (one group). Without the rows they stay static.
* **Existing rows used:** `Steam` (D5_LabHut `SteamA`, D6_SteamVents `SteamA/B/C`, D6_LavaFalls
  `SteamA`, D6_VolcanoTop `SteamCloud`), `Core` (D6_VolcanoBase core window, D6_VolcanoTop
  `CoreLava`), `Crystal` (D6_CrystalCore, D6_ObsidianCrown `CrystalTips`), `Bubbles` (pools),
  `Wheel` (D6_StoneTurbines `WheelStone` / `WheelHub`, both centred on the axle, spin X), `Arm`
  (D6_MagmaPumps `ArmBeam` / `ArmLadles` / `ArmHub`, every box centred on the fulcrum y 6),
  `Twirl` (D6_CrystalCore `TwirlRing` / `TwirlOrbs`), `Pennant` (D5_MuseumBanners), `Lamp`→`Bulb`.
  Arch torch flames are named `Flame` (W6's requested row: light only).
* **Managers** (`ManagerNpcConfig.Rigs`): both on the shared body, figure at the model origin,
  yaw 0 (`figure = { base = Vector3.zero, yaw = 0 }`), joints printed by the build:

  | Joint | D5_DrTrike | D6_ChiefTyra (T. rex body 1.4 / 1.55 / 1.3) |
  |---|---|---|
  | Torso | (0, 1.85, 0.1) | (0, 1.85, 0.1) |
  | Head | (0, 4.284, -0.1) | (0, 4.284, -0.1) |
  | ArmL / ArmR | (∓1.053, 3.555, -0.463) | (∓1.092, 3.555, -0.485) |
  | LegL / LegR | (∓0.648, 1.85, 0.05) | (∓0.672, 1.85, 0.05) |

  Dr. Trike: coat, tail ride the Torso; frill, horns, goggles, face ride the Head; the magnifier
  rides ArmR (raised); ArmL is the relaxed wave arm; specimen desk at local x 3.9.
  Tyra: vest, back bumps, tail ride the Torso; hard hat + face the Head; the clipboard rides ArmR
  (both tiny arms hold it); control podium (lever, gauge) at local x 4.1.

### Gates (W8)

* `tests/zfight-audit` 0 offenders (fixed: channel trough floor flush with its walls, spire moss
  ring level with the spire top); `tests/glow-budget` green (Neon only on small lamps; big lava /
  crystal / gold pieces are Smooth); `tests/mesh-assets` (area budgets 28k / 34k) and
  `tests/area-layouts` (dino strict) pass.
* R24: `check_area_overlaps.py -- --world dino 5 6` → 0 problem pairs in D5 and D6
  (fixed: the dig-site bone, foot boulders / ferns sinking into the lot, the steam cloud through a
  crown spire, the bridge's last plank, the base collar cutting into VolcanoTop).

### Verification (W8)

* Studio (edit mode, studio lock held, previews cleaned up): `spawn_dino_area05.luau` → 127 meshes
  ready, 0 failed, 0 fallbacks, 0 missing keys; `spawn_dino_area06.luau` → 137 ready, 0 failed,
  0 fallbacks (re-run after the managers moved onto the shared body).
  Captures `docs/verification/world2/d05-{front,iso,iso2,arch-road,arch-inside,close-hut}.jpg`
  and `d06-{front,iso,iso2,arch-road,arch-inside,close-top,close-plaza}.jpg` (both arches read
  correctly from the road and from inside, R17).
* Contact sheets: `assets/blender/previews/_sheet_dino_d5_{iso,front}.jpg`, `_sheet_dino_d6_{iso,front}.jpg`.

## Dino Valley Base Camp, plot frame + the Time Machine (W9 valley-hub-art, R57, 2026-10-31)

Builders: `tools/blender/models/dino_valley.py` (22 `Valley_*` keys) and
`tools/blender/models/hub_time_machine.py` (`Hub_TimeMachine`, one model for both worlds). Layout:
`src/shared/Config/Worlds/Dino/ValleyLayout.luau` (WORLD-LOCAL, HubLayout's shape) + the lobby
placement / `anchors.WorldPortals.dino` in `HubLayout.luau`. Tests: `tests/valley-layout.luau` (new),
`tests/hub-layout.luau` §7, z-fight scenes `dino:hub` / `dino:plot-fresh` / `dino:plot-full` in
`tests/zfight-audit.luau` (all 0). Edit-mode preview: `tools/blender/studio/spawn_valley.luau`.

**Map (world-local, origin = Base Camp centre; mirrors Nuke Town's ring so every AreaLayout works):**

| Radius / spot | What | Top y |
|---|---|---|
| r 0-26 | `Valley_BrontoFountain`: a mint long-neck in an explorer hat on a mossy rock island, spouting a water arc into a lily pond (`Ripple` rings bob via WorldFx). Faces the arrival side. Hero, Persistent | rim 1.6, water 1.0 |
| r 25.6-88 | `Valley_BaseCamp` flagstone plaza ring (+ stone inlay bands r 31.5 / 83) | 0.18 |
| r 50, yaw 22.5 | `Hub_TimeMachine` "BACK TO NUKE TOWN" (front faces outward) = `anchors.ReturnPortal` | dais 1.18 |
| r 74, yaw 22.5 | `spawn` = `SpawnPoint` = `ReturnPortal.arrive`, facing outward (NOT a SpawnLocation) | 0.18 |
| r 62, yaw (i-1)·45 | ~~`Valley_TeleportPad` ×8~~ removed by owner R134 (no plot teleport pads in any hub; the mesh stays in MeshAssets, unused) | — |
| r 0-244 | meadow (`Valley_BaseCamp` Grass) with moss patches (0.06) | 0.0 |
| r 87.4-236 | `Valley_Trail` ×8 along each plot axis, plot-coloured flowers, log edging, stepping stones | 0.12 |
| r 87.6-122, yaw 22.5 | welcome walk to the title sign | 0.12 |
| r 104, yaw 35.5 / 9.5 | `Valley_EggStand` nest stands: [1] Dino Egg (Dino area 2), [2] Volcano Egg (area 5), both turned to the arrival | 0 |
| r 112, yaw 337.5 | `Valley_Leaderboard` stone tablet "MOST DINO REBIRTHS" (stat `DinoRebirths`) | 0 |
| r 130, yaw 22.5 | `Valley_TitleSign` "DINO VALLEY" (letters both faces), Persistent | 0 |
| r 230-260 | `Valley_RingPath` ×8 (straight 20-stud mouth at each plot entrance) | 0.06 |
| wedges r 300-610 | palms, ferns, boulders, hills, fossil dig sites (every other wedge) | -0.4 |
| r 640, yaw 352 | `Valley_Waterfall` against the cliffs (right of the title sign in the arrival view) | -0.4 |
| r 644-700 | `Valley_BoundaryCliffs` ×8 (foot r 652 leaning to 644, buttresses only above head height); invisible ring r 650 | — |
| r 815, yaw 55 | `Valley_VolcanoBackdrop` (candy lava stripes, puffy smoke; left of the title sign), Persistent | — |
| r 0-662 | `Valley_Ground` valley floor (StudsLarge), Persistent | -0.4 |

Layer rule (R18): every walk surface has its own height (ground -0.4, meadow 0, ring path 0.06,
trails 0.12, plaza 0.18, inlays 0.24); curved seams only between different heights; the plot path
butts the ring path's straight mouth.

**Plot frame (plot-local, length 312):** `Valley_PlotGround` (curved front, back z 312),
`Valley_Path` (sand |x| <= 8 top 0.06, stone edging to |x| 10 top 0.4, stepping-stone tiles),
`Valley_FernHedge` (just outside the footprint, `Blossoms` plot-tinted), `Valley_EntranceArch` at
(0, 0, 4) — boulder pillars at x ±13 with the same 5 × 5 footprint as `Plot_EntranceArch`, log beam,
`OwnerSign` panels front/back (22 × 3.6), plot-tinted bands, bone crest + pebble nuke — and a
palm/fern backdrop behind the hedge. `Valley_LockedSlot`: bamboo fence, the vine-covered COMING SOON
board (`Sign` at slot (0, 9.2, 4.19), same as `Plot_LockedSlot`) and a nest of three giant eggs.
Every Dino area layout (D1-D6) keeps the arch-pillar corner clear (checked per piece, then per
GLB vertex for slot-wide backdrops such as `D1_Jungle`).

**The Time Machine (`Hub_TimeMachine`, 9 pieces, 4,448 triangles):** a walk-through stud alarm
clock: slate dais + step, purple ring (r 8.8-11.2, centre y 10) with gold bezel lips, cream hour
ticks and 10:10 hands on both faces, a violet `Portal` disc with two cyan `Swirl` arms per face
(rotationally symmetric so WorldFx can spin the piece about its local Z — the `Swirl` row
`{ motion = "spin", axis = "Z", speed = 90 }` must be added to WorldFxConfig by its owner), alarm
bells, a dial console with three warm Neon bulbs (R19-safe cluster), a lever and the `Sign` panel
(13.6 × 3.0, Front face (0, 24.8, -0.6)) for the SurfaceGui ("DINO VALLEY" in the lobby, "BACK TO
NUKE TOWN" at Base Camp). Colliders (one list in both layouts, asserted equal): dais, step, ring
sides + lower arc, top, console, pedestal, sign frame; the swirl opening stays walkable. Anchor
`trigger` = 10 × 12 × 2.5 box at (0, 9.8, 0), `prompt` (0, 4, -11), `arrive` 24 (Valley) / 18
(lobby) studs in front, facing away.

**Lobby placement (HubLayout, appended LAST so no older "<key>_<index>" name moved):** district 1's
paving forecourt beside avenue 2, yaw 54 / r 207, turned to face the spawn; first-wave (176 studs
from the spawn < MeshLibrary's 200 near-hub radius). Spec §4.4 asked for "within ~30° of the
fresh-spawn view": from the spawn camera the SELL NUKES sign fills ±21°, the welcome banners 20-30°
and the pad 1 / 2 signposts 34-46° on each side, and every open sightline inside ±30° runs down an
avenue or onto a plot, so no legal spot exists there without moving R55 pieces. The machine sits
~39° left: it shows as soon as the player turns a little left and greets everyone walking to
plot 2. Captures: `docs/verification/world2/lobby-spawn-view.jpg`, `lobby-spawn-turn-left.jpg`,
`lobby-time-machine.jpg`.

**Budgets (tests/valley-layout §6, measured):** Base Camp first view 175 MeshParts / 56.4k
triangles / 18 unique meshes (spec cap 700 / 150k / 45); decor (deferred: palms, ferns, boulders)
145 / 16.6k / 3; scenery (wedges, cliffs, waterfall, volcano) 510 / 65.8k / 8; one Dino plot frame
+ 6 locked slots within 80 MeshParts / 28k triangles. Nuke Town lobby with the Time Machine:
669 MeshParts / 148.9k triangles / 38 unique (cap 670 / 150k / 38 unchanged).

Captures: `docs/verification/world2/valley-plot1.jpg` (edit mode, `spawn_valley.luau` at preview
origin (-9000, 300, 9000)); the rest are from a solo playtest (W9b, 2026-10-31) through the real
server build: `WorldService.unlock` / `travel(…, "admin")`, scriptable client camera, HUD + menu
blur off. Base Camp: `valley-{arrival,back,return-portal,egg-stands,leaderboard,camp-close,aerial}.jpg`
plus `valley-ingame.jpg` (HUD on). Lobby: `lobby-time-machine.jpg`, `lobby-spawn-turn-left.jpg`.

**W9b audit (2026-10-31).** Every §4 W9 deliverable is present. `Hub_TimeMachine` is built,
uploaded and synced: a rebuild changes only the FBX timestamp hash, and every piece hash still
matches its receipt. Both machines spawn as `MeshSource = "Mesh"` (`Workspace.Hub.Art.Hub_TimeMachine_*`,
`Workspace.Worlds.dino.Hub.Art.Hub_TimeMachine_*`). The yellow box seen earlier was HubBuilder's
primitive `placeholderMachine`, built before the layout / mesh keys were complete. The Dino egg
stands use `anchors.EggStands` (`Stand_dino_egg` → `Valley_EggStand_38`, `Stand_volcano_egg` →
`_39`; prompts 6 studs toward the arrival). The `MOST DINO REBIRTHS` board uses
`anchors.Leaderboards[1].screen` (`Workspace.Leaderboards_dino.Screen_DinoRebirths`). The
`Hub_TimeMachine` `Sign` panel has no modelled lettering: the text is HubBuilder's SurfaceGui (W4).
Lobby fix: district 1's first tree (`TREE_YAWS[1]`, -12 → -6) stood 20 studs in front of the lobby
machine and hid the left half of its clock. It now stands 27 studs to the side. W10b has added the
swirl spin: WorldFxConfig row `TimeSwirl` (spin about Z, 90°/s) applied only through
`Assemblies.Hub_TimeMachine.Swirl`, so `Shop_Teleporter.Swirl` and the `Portal` disc stay still
(`tests/world-fx`). Nobody has watched it spin in Studio yet. The sign text size / contrast was fixed by W4 after
these captures (`HubBuilder.signBoard` now sizes the label to the layout's `Sign` surface,
13.6 × 3.0, navy on cream); re-capture `valley-return-portal` / `lobby-time-machine` on the next
Studio turn and watch the swirl spin there. From the exact spawn the pad-2 signpost still covers part of the machine (placement
trade-off above). A few steps in, or a small turn, shows all of it. (Owner R134 removed the pad signposts, so nothing blocks it now.)

## Moon Base M1 Crater Camp + M2 Cosmic Diner (W6 art-d12, 2026-10-31)

Owner R70 (World 3 "Moon Base"); spec `docs/superpowers/specs/2026-10-31-r69-moon-lucky-juice-design.md` §2.2.
Builders: `tools/blender/models/moon_area01.py` (M1 + the shared Moon helpers), `moon_area02.py` (M2).
Layouts: `src/shared/Config/Worlds/Moon/Layouts/Area01.luau`, `Area02.luau`. They replace W1's
placeholders and use the same slot frame and `LayoutLogic` contract as Dino. Previews:
`tools/blender/studio/spawn_moon_area0{1,2}.luau`, built at origin (-9000, 0, -9000 - 300·N).
They load fresh module copies, like the Dino previews.

**Look.** Pale lilac moon dust (`StudsLarge` ground), chrome-white shells, candy accents (mint,
coral, sunshine, violet), navy glass and boards. Round friendly shapes, and no grey-metal hazard
stripes. The flag is the SELL NUKES logo flag: navy, a yellow "SELL" over a lime "NUKES" and a
small trefoil, on both faces. It carries no country.

### Shared Moon helpers (`models.moon_area01`, for W7 / W8)

* **Palette:** `MOON_GROUND`, `MOON_DARK`, `MOON_DUST`, `CHROME`, `CHROME_SHADE`, `MINT_C`,
  `CORAL_C`, `SUNNY`, `VIOLET`, `NAVY`, `ROCK_LILAC`, `ROCK_DEEP`, `CRYSTAL_GLOW`, `STAR_GLOW`,
  `ALIEN_GREEN`, `INK_M`.
* **Props:**
  * `moon_rock` (centre it at LOT + 0.72·r)
  * `crater` (a raised rim plus a bowl at +0.1)
  * `crystal_cluster` (one small Neon tip; base it at LOT + 0.35 on the lot, R24)
  * `moon_nuke` (the band gets its own small Neon piece)
  * `rail_run`
* **Arch:** `moon_arch(key, lines, ...)`: chrome capsule posts with candy bands and portholes, a
  double-sided board (R17), ringed-planet finials, a crescent crest and Neon star bulbs.
* **Characters:** `toon_biped(parts, head_shape="round"|"dome", feet="boots"|"skates")` and
  `toon_bones(anchors)` build chunky robots and aliens with the R30 skeleton.

### M1 Crater Camp (18.8k triangles fully built; 14 Neon pieces / 12.6 studs²)

* **Base:**
  * `M1_Floor`: the lot with a dust path (+0.06) to a clearing (r 11) and six raised-rim craters.
  * `M1_CraterWall` (3.3k triangles): a lofted crater-rim bank across z 54-70 with crest rocks,
    face craters and crystal clusters. The landed capsule (1.4x scale) leans against it at
    x -24, z 52.5, with a striped parachute on the rim.
  * `M1_EntryArch` "CRATER CAMP".
  * `M1_RockCluster` × 8.
* **Builds:**
  * The workbench producer is at z 40. It hovers a moon-rock nuke over a cradle and has its own
    arc lamp.
  * Four globe lamps stand round the clearing.
  * The tool rack is at x 16 and the flag at x -16.
  * Three solar panels stand at x 26 / 34 / 42, z 48.
  * The air pump is at x -18, z 33.
  * Bleep Bot stands behind the bench.
  * Crater railings run along both slot edges.

### M2 Cosmic Diner (20.4k triangles fully built; 14 Neon pieces / 19.1 studs²)

* **Base:**
  * `M2_Floor`: a mint / white checkered patio (x ±22, z 18-50, +0.08; the tiles butt on
    straight seams), a path and craters.
  * `M2_DinerHall`: a retro stadium-plan diner at z 61, with a coral stripe, navy windows, a door
    porthole and a roof fin. Each stacked stadium is ONE convex outline. Separate box + cap solids
    left hidden coplanar end faces that the z-fight audit caught.
  * `M2_EntryArch` "COSMIC DINER".
  * `M1_RockCluster` × 6.
* **Builds:**
  * The walk-up counter producer stands at z 41 with four stools. Moon-rock nukes sit on cake
    stands; their pieces are named `Moon*` so they don't bob.
  * The star register and the shake machine stand on the counter.
  * The rocket NUKES sign is at x -16 and the rocket jukebox at x 15.
  * Two booths sit on the patio, and four saucer-umbrella tables stand on the dust.
  * Zip Zorp works behind the counter.
  * Two runway-light rows line the patio aisle.

### WorldFx + managers (my rows, small in-place blocks)

* **`WorldFxConfig` "-- Moon Base M1/M2":**
  * `Solar` oscillates about X (8°, 7 s). M1 `SolarPanel` / `SolarCells` / `SolarFrame` form one
    group per stand, and the group is symmetric about its axle.
  * `Jukebox` is a soft pulsing light on `JukeboxLightsMint` / `JukeboxLightsSun`.
  * Lamps, sign stars and runway globes are named `Bulb*` and use the existing light row.
* **Pieces renamed to dodge WorldFx words (R25):**
  * `LampArm` became `ArcPost` (`Lamp` would add a light).
  * `RocketBody` became `SignRocket` (`Rocket` idle-shakes).
  * The counter nukes became `Moon*` (`Nuke` bobs).
* **`ManagerNpcConfig`:**
  * `WorldManagerKeys.moon` lists all six spec manager keys.
  * Rigs `M1_BleepBot` and `M2_ZipZorp` both have `world = "moon"`. The joints are the
    `[npc_rig]` print. The waypoints keep ≥ 1.3 studs from every collision box and ≥ 1.35 from
    the click box.
  * Zip Zorp's tray, shake and straw ride ArmR, and his antenna balls ride the Head.
  * `Fx.WorldHopVoice.moon` uses `robot_beep`: every Moon manager celebrates with a friendly
    beep (H1's 3D key, range 120). It has a 4 s cooldown and plays on Mid/High tiers, like the
    Dino roar.

### Gates

* **`tests/fixtures/ArtWorlds`:**
  * Every world's layout merges with `PlaceholderLayouts.generate(area, worldId)`. W3 made it
    world-aware, so a missing file builds the placeholder like the runtime.
  * A non-main authored file that fails `LayoutLogic.validate(..., worldId)` fails the suites.
  * Moon owners are W6 / W6 / W7 / W7 / W8 / W8, and the hub owner is W9b.
* **M1/M2 results:**
  * zfight `moon:plot-full` (areas 1-2): 0 face offenders, 0 curved seams.
  * `check_area_overlaps.py --world moon 1 2`: 0 problem pairs.
  * Glow and triangle budgets are within limits (above).
  * `npc-logic` scoped to M1/M2: both loops are clear of every box.

### Verification

* Contact sheet: `assets/blender/previews/_sheet_moon_m12_iso.jpg`.
* Composed Blender renders of the real layouts:
  `docs/verification/world3/m0{1,2}-{front,iso,top,arch-front,arch-back}.jpg`. The arch reads
  from both sides.
* Studio edit-mode previews (spawn_moon_area01/02):
  * M1: 182 MeshParts, M2: 172 MeshParts; 0 fallbacks, 0 missing keys.
  * Captures: `docs/verification/world3/m0{1,2}-studio-{front,iso,arch}.jpg`. The arch reads
    correctly from inside the area.
  * Previews and MaterialVariant clones were cleaned up afterwards.

## Moon Base M5 Star Lab + M6 Star Reactor (W8 art-d56, 2026-10-31)

Owner R70; spec `docs/superpowers/specs/2026-10-31-r69-moon-lucky-juice-design.md` §2.2.
Builders: `tools/blender/models/moon_area05.py` (M5 + W8 Moon helpers), `moon_area06.py` (M6, the
finale). Layouts: `src/shared/Config/Worlds/Moon/Layouts/Area05.luau`, `Area06.luau` (replaced W1's
placeholders; same slot contract). Previews: `tools/blender/studio/spawn_moon_area0{5,6}.luau` (W6's
spawner, AREA = 5 / 6; origin (-9000, 0, -9000 - 300·N)).

* **Shared with W6:** palette, `crater`, `moon_rock`, `crystal_cluster`, `moon_arch` (both arches,
  inner 20 for the wide pad row) and the manager body `toon_biped` / `toon_bones` come from
  `models.moon_area01`. W8 adds `moon_floor` (stripes, craters, chrome stepping tiles, lumpy rock
  wall with violet caps, rocks, crystals), `crystal`, `star_plate`, `round_tiles`, `ringed_planet`,
  `lab_coat`.
* **Piece-name traps avoided:** the robot arm's chrome segments are `Segments` (not `Arm*`: swing
  row) and the banner rocket emblem is `EmblemRocket` (not `Rocket*`: shake row).
* **Arch sight lines (W10b):** `moon_arch` puts the post porthole rings and the board frame in one
  `Frame` piece whose box spans the walk-through opening; `split_low_islands` moves the rings into
  `PortholeRings` so `Frame` stays above the opening (both M5 and M6 arches).

### M5 Star Lab (18.7k triangles / 11 models fully built)

* Base: lilac / grey dust stripes, craters, round chrome stepping tiles to a plaza (r 14) round the
  dome, rock wall, crystals; "STAR LAB" arch (mint planets).
* Builds: `M5_LabDome` (producer: chrome drum, lavender dome with an observing slit + a little
  telescope, portholes, round coral door with a star, antenna `Beacon`, porch `Lamp`), `M5_StarJars`,
  `M5_BigTelescope` (tube rises toward the dome, lens top ~y 20), `M5_PlanetMobile` (`Twirl*`:
  arms, strings, planet pairs and the smiling sun are all point-symmetric about the pole),
  `M5_CometCatcher`, `M5_RobotArm`, `M5_MoonGarden`, `M5_DrNova` (manager), `M5_MissionBanners`
  (`Pennant*` bunting).

### M6 Star Reactor (24.7k triangles fully built incl. 2 coolant pumps)

* The star core is ONE pivot shared by `M6_StarCore`, `M6_OrbitRings`, `M6_BeamTowers` and
  `M6_GalaxyCrown` (slot (0, 0.5, 48)): base tier r 16 (y 0..3), chrome tier r 13 with a walkable
  deck at y 9 (railing gap at 202.2° for the bridge), the smiling sun (centre y 23.5, r 9.5,
  `CoreSun` = Smooth + `Core` pulsing light: the "star core pulse"), a ball cage of four meridian
  rings (r 12.5) held by a chrome cup, the gold top platform at y 37 = `M6_GoldenAstronaut` pivot.
* Coupled numbers (printed by the builder; move together): plasma pipes end 0.15 short of the
  pedestal ports (pipes-local z 8.818; tanks at slot (±11, 23), clear of the finale pad's
  billboard at (0, 6.5, 14), W10b); the star bridge tile line runs spire-local
  (2.221, 9.25, 0.909) → (33.356, 9.25, 13.646) with a 1.2 arch rise and lands on the deck top;
  the orbit rings (r 17.5) are centred on the sun axis 8 under its centre (they frame the chin, not
  the eyes), tilted ±14° at yaws 45 / 135 so no planet rests in front of the face and they stay
  clear of the beam-tower beams.
* Builds: plasma pipes + tanks, orbit rings (`Carousel*`), beam towers (Glass beams stop 0.8
  outside the cage), coolant pumps ×2 (`WheelFly*` spin X), nebula core (`Twirl*` swirl rings +
  `CoreOrb`), meteor falls (`StarFall` scroll + `Bubbles` + `SteamA`), star bridge (floating
  star tiles), galaxy crown (circlet of stars round the statue platform, `CrystalTips`),
  `M6_CommanderLux` (manager) and the finale `M6_GoldenAstronaut` (2.8× Moon body, all gold,
  dark-gold visor, waving + star flag; crown of the scene ~y 59 slot).
* Pads: x ±16..48 at z 10; the finale pad waits on the path at (0, 14); spawn (0, 0.5, 7).

### For W10 / rows (W8 edits, in place)

* `WorldFxConfig`: new `StarFall` (scroll 1.5, faces Top + Front) in a "Moon Base M5/M6" block,
  and Ambience rows (H1's `star_chime`) for `M5_PlanetMobile` and `M6_StarCore`;
  everything else uses existing rows (Twirl, Carousel, Wheel, Core, Crystal, Bubbles, Steam,
  Pennant, Bulb via Lamp).
* `ManagerNpcConfig`: `M5_DrNova` and `M6_CommanderLux` rigs (shared body, figure at the origin,
  yaw 0): Dr. Nova Torso (0, 1.6, 0), Head (0, 3.7, 0), ArmL/R (∓1.118, 3.125, 0), LegL/R
  (∓0.585, 1.6, 0); Lux Torso (0, 1.6, 0), Head (0, 3.784, 0), ArmL/R (∓1.161, 3.186, 0),
  LegL/R (∓0.608, 1.6, 0). Dr. Nova's beaker rides ArmR (raised); Lux's clipboard rides ArmR
  (both hands); coats / suits / backpack / badge ride the Torso; face, glasses, antennae and the
  helmet ride the Head.

### Gates (W8)

* `check_area_overlaps.py -- --world moon 5 6` → 0 problem pairs (fixed: orbit rings vs beams,
  a crater under a beam-tower plinth); `area-layouts` (moon strict) and `glow-budget` pass; every
  M5 / M6 piece has an uploaded mesh id.

## Moon Base M3 UFO Delivery + M4 Asteroid Mine (W7 art-d34, 2026-10-31)

Builders `tools/blender/models/moon_area03.py` / `moon_area04.py`; layouts
`src/shared/Config/Worlds/Moon/Layouts/Area03.luau` / `Area04.luau` (replace W1's placeholders;
strict `LayoutLogic.validate` = 0 problems); previews `tools/blender/studio/spawn_moon_area03/04.luau`
(W6's spawner, only `AREA` differs). Same slot conventions as Dino D3/D4: floor top y 0.4, arch at
z 18, pads at z 9 alternating ±11, ±20, … (Unlock last), spawn (0, 3.4, 13). The look, arches,
managers, craters and the Moon product use W6's shared `models.moon_area01` (palette, `moon_arch`,
`toon_biped` / `toon_bones`, `crater`, `moon_nuke`), so M1–M6 match. Local helpers in
`moon_area03.py`: `floor_rock` (flat-bottomed at the floor, R24), `crystal`, `saucer_hull`,
`toon_face`. Low gravity (spec §2.4) means ~16-stud jumps: everything a player can land on (deck,
pods, ring legs, floating rocks, magnets, hover steps, the Mega Asteroid) has a collision box.

### M3 UFO Delivery (22.7k triangles / 156 MeshParts fully built)

| Build key | Models (slot placement) | What appears |
|---|---|---|
| base | `M3_Floor` (0, 0, 35), `M3_EntryArch` (0, 0.4, 18), `M3_Rocks` (0, 0.4, 0) | moon dust + craters + tile walkway; **UFO / DELIVERY** capsule arch; back rocks, crystals, antenna masts |
| `M3_SaucerDock` | `M3_SaucerDock` (0, 0.4, 50) + 2× `M3_UfoCourier` parked on the deck (y 10.8) | producer: landing deck on 4 legs, glass parcel elevator, conveyor `Belt`, sorting counter with floating moon nukes |
| `M3_TractorBeam` | (28, 0.4, 34) | pad + soft translucent beam (top y 6.4) with floating rings |
| `M3_ParcelPods` | 2× at (±13, 0.4, 40.5) | capsule pods with portholes + parcels |
| `M3_RadarDish` | (41, 0.4, 23) | mast + spinning dish (counterweighted onto the mast axis) |
| `M3_UfoFleet` | 3× `M3_FleetSaucer` at (-42, 22), (-37, 31), (-42, 40), Hull tinted coral / mint / sunny | saucers hovering over their pads |
| `M3_StarMap` | (40, 0.4, 50), yaw 50 | star chart: candy stars, ringed planet, dotted route |
| `M3_LaunchRing` | (-16.5, 0.4, 31) | candy-striped hoop (centre y 16.4); courier IN flies through it |
| `M3_CaptainGlorp` | (17, 0.4, 26), yaw 20 | manager: green pilot alien, flying cap + goggles, scarf, parcel scanner |

Producer click box `DOCK * (0, 6, −2.6)`, size (17.4, 12.6, 16.6); billboard anchor (0, 7.9, 36.6),
spot clear (R31 / R32).

### M4 Asteroid Mine (21.2k triangles / 157 MeshParts fully built)

| Build key | Models (slot placement) | What appears |
|---|---|---|
| base | `M4_Floor`, `M4_EntryArch` (**ASTEROID / MINE**), `M4_Rocks` | moon dust, craters, walkway; back-corner rocks + crystals |
| `M4_DrillRig` | (0, 0.4, 48) | producer: octagon platform, cradled asteroid, gantry with spinning drill bit (`Rotor`), crystal chute to the cart track, console with floating moon nukes |
| `M4_TetherCables` | 3× `M4_TetherRock` at (-22, 58), (-34, 53), (-44, 62) | asteroids floating on cables |
| `M4_OreCarts` | `M4_CartTrack` (22.5, 0.4, 45) + 2× `M4_OreCart` at (14, 0.7, 49.2 / 44.0), yaw 180 | oval rail loop, two crystal carts |
| `M4_CrystalSorter` | (35.4, 0.4, 45), yaw 90 | hopper the carts tip into, window of crystals, conveyor `Belt`, candy bins |
| `M4_GravityMagnets` | 2× `M4_GravityMagnet` at (-14, 33), (-24, 40) | horseshoe magnets holding floating rocks |
| `M4_LaserDrills` | (40, 0.4, 24) | two friendly drill-beam turrets sparkling at a crystal rock |
| `M4_MegaAsteroid` | (0, 0.4, 62) | hero: giant crystal asteroid floating at y ~20 on four cables |
| `M4_Drillbert` | (8, 0.4, 27), yaw 20 | manager: chrome robot, pixel face, drill-bit hard hat, toy wrench |
| `M4_HoverSteps` | 5× `M4_HoverStep` rising from (-28, 1.8, 18) + `M4_HoverDeck` at (-45, 9.3, 41.5) | floating steps up to a lookout deck with a telescope |

Producer click box `DRILL * (0, 6, −0.6)`, size (14, 12, 18); billboard anchor (0, 7.9, 35.9), spot clear.

### Rows (W7, small in-place blocks headed "Moon Base M3/M4")

* `ManagerNpcConfig.Rigs`: `M3_CaptainGlorp` (Tap, scanner rides ArmR), `M4_Drillbert` (Hammer, wrench
  rides ArmR); `toon_bones` joints; waypoints in model space, ≥ 1.3 from every collider.
* `WorldFxConfig`: rows `RadarSpin` (spin Y 36), `Float` (bob 0.45 / 4.2 s), `FloatBig` (bob 0.7 / 7 s);
  Assemblies `M3_RadarDish` (Dish + DishTrim), `M3_FleetSaucer` (all but Pad / PadRing → Hover),
  `M3_TractorBeam` (BeamRings → Float), `M4_TetherRock`, `M4_GravityMagnet`, `M4_MegaAsteroid`
  (rocks Float / FloatBig; cables / magnets / anchors stay still and reach ≥ 0.9 into the rocks),
  `M4_HoverStep` / `M4_HoverDeck` (→ Hover). `RoutedModels`: `M3_UfoCourier`, `M4_OreCart`.
  Existing rows used as-is: `Belt`, `Nuke*`, `Rotor`. `Ambience`: `M3_SaucerDock` and `M4_MegaAsteroid`
  play H1's `star_chime` now and then (22 / 26 s ± jitter).
* `VehicleRouteConfig`: `M3_CourierOut` (parks → flies to the tractor pad → hovers above the beam →
  drops its parcel → home) and `M3_CourierIn` (parks → off the deck → through the launch ring →
  over the arch → fades over the road → back), both flyers (`FinL` / `FinR` wiggle, H1's `ufo_whirr`),
  one 36 s `sync` clock; `M4_Carts` (two-cart train: load under the chute, round the back bend, tip
  into the sorter, round the front bend). `tests/vehicle-routes.luau`: 507,972 checks pass.

### Gates (W7)

* R24 `check_area_overlaps.py -- --world moon 3 4`: 0 / 0 problem pairs.
* R18 `tests/zfight-audit.luau` moon:plot-full: 0 offenders in M3 / M4 (dust patches top out at
  +0.07 so they never share the crater bowls' +0.1 plane).
* R19 `tests/glow-budget.luau` green (M3 5 Neon pieces, M4 4; the arch star bulbs render Smooth).
* R31 billboard spots clear; budgets: every model within its class, both areas ≤ 28k.

## Moon Base Landing Plaza, plot frame + the Moon Rocket (W9b, R70, 2026-10-31)

Owner R70, spec `docs/superpowers/specs/2026-10-31-r69-moon-lucky-juice-design.md` §2.1 / §2.3.
Builders: `tools/blender/models/moon_base.py` (20 `Moon_*` keys) and
`tools/blender/models/hub_moon_rocket.py` (`Hub_MoonRocket`, one model for both worlds). Layout:
`src/shared/Config/Worlds/Moon/MoonHubLayout.luau` (WORLD-LOCAL, the Valley's shape and ring) plus the
lobby placement and `anchors.WorldPortals.moon` in `HubLayout.luau`. Tests:
`tests/moon-hub-layout.luau` (new; it mirrors `valley-layout`) and the generalised `tests/hub-layout.luau`
§7. Z-fight scenes `moon:hub` / `moon:plot-fresh` are both at 0. Edit-mode preview:
`tools/blender/studio/spawn_moon_hub.luau`.

**Map (world-local, origin = Landing Plaza centre; the same ring as Nuke Town / Dino Valley):**

| Radius / spot | What | Top y |
|---|---|---|
| r 0-26 | `Moon_RocketFountain`: a smiling toy rocket statue (white, sunshine nose, coral fins, big eyes) on a moon-rock island in a chrome-rimmed pool of "star water". Three jets arc from its fins (`Ripple` rings bob via WorldFx) and yellow `Sparkles` stars float on the water. It faces the arrival side, is ~47 tall, and is Persistent | rim 1.6, water 1.0 |
| r 25.6-88 | `Moon_LandingPlaza` chrome landing ring (+ violet tile bands r 31.5 / 83) | 0.18 |
| r 50, yaw 22.5 | `Hub_MoonRocket` "BACK TO NUKE TOWN" (front faces outward) = `anchors.ReturnPortal` | dais 1.0 |
| r 74, yaw 22.5 | `spawn` = `SpawnPoint` = `ReturnPortal.arrive`, facing outward (NOT a SpawnLocation) | 0.18 |
| r 62, yaw (i-1)·45 | ~~`Moon_TeleportPad` ×8~~ removed by owner R134 (no plot teleport pads in any hub; the mesh stays in MeshAssets, unused) | — |
| r 0-244 | pale lilac moon dust with little craters (rim 0.08 / floor 0.03, wedges 1-7) | 0.0 |
| r 87.4-236 | `Moon_Trail` ×8: periwinkle path, chrome curbs, centre dashes, plot-coloured landing lights | 0.12 |
| r 87.6-122, yaw 22.5 | welcome walk to the title sign | 0.12 |
| r 104, yaw 35.5 / 9.5 | `Moon_EggStand`: [1] Moon Egg (Moon area 2), [2] Comet Egg (area 5), both turned to the arrival | 0 |
| r 112, yaw 337.5 | `Moon_Leaderboard` chrome monitor "MOST MOON REBIRTHS" (stat `MoonRebirths`) | 0 |
| r 130, yaw 22.5 | `Moon_TitleSign` "MOON BASE" (sunshine letters on both faces of a navy board between two chrome antenna towers, a ringed toy-planet crest), Persistent | 0 |
| r 230-260 | `Moon_RingPath` ×8 (straight 20-stud mouth at each plot entrance) | 0.06 |
| wedges r 300-610 | crystal clusters, comms antennas, moon rocks, big craters (an extra one in every other wedge) | -0.4 |
| r 644-700 | `Moon_BoundaryRidge` ×8 crater-wall arcs (foot r 652 leaning to 644, crystal tufts only above head height); invisible ring r 650 | — |
| r 765, yaw 51 | `Moon_PlanetBackdrop` high in the sky: a peach ringed planet + a cartoon blue-green home planet (no real continents). It sits left of the title sign in the arrival view, is Persistent, and stays inside sceneryRadius 950 | — |
| r 0-662 | `Moon_Ground` far moon floor (StudsLarge), Persistent | -0.4 |

Layer rule (R18): every walk surface has its own height (ground -0.4, dust 0, crater floor 0.03,
ring path 0.06, crater rim 0.08, trails 0.12, plaza 0.18, tiles 0.24).

**Plot frame (plot-local, length 312):**
- `Moon_PlotGround`: moon-dust plates.
- `Moon_Path`: periwinkle |x| <= 8 at top 0.06, chrome edging to |x| 10 at top 0.4, light tiles.
- `Moon_CraterRim`: a rocky rim just outside the footprint, with plot-tinted `Lights`.
- `Moon_EntranceArch` at (0, 0, 4): chrome towers at x ±13 with the same 5 × 5 footprint as `Plot_EntranceArch`, a twin girder beam, `OwnerSign` panels front/back (22 × 3.6), plot-tinted bands, and a toy rocket crest with a tiny Neon window.
- `Moon_LockedSlot`: a space-barrier fence, the COMING SOON board (`Sign` at slot (0, 9.2, 4.19)), and a landed supply capsule with a parachute.
- Behind the rim: rocks, crystals and an antenna.

All 6 Moon area layouts keep the arch-pillar corner clear (`tests/moon-hub-layout` §5).

**The Moon Rocket (`Hub_MoonRocket`, 9 pieces, 3,880 triangles).** The lobby and Landing Plaza
twin of the Time Machine.
- A lilac launch-pad dais (30 × 26, centred z +6) with a front step.
- A walk-through chrome LAUNCH RING: centre y 8.6, r 7.4-9.6, coral / violet lips that overhang 0.1 so no face is coplanar, and mint bolts.
- A navy `Portal` disc with a sunshine-yellow `Swirl`: two spiral arms plus a four-point sparkle per face, 180° symmetric, so WorldFx spins it in place (`Assemblies.Hub_MoonRocket` → `MoonSwirl`).
- A friendly rocket behind the ring: white fuselage (axis z 9), coral nose, violet bands, three mint fins standing on the dais.
- One warm Neon `Porthole` (2.3 × 2.3, under R19), lit softly via the assembly → `Core`.
- The cream `Sign` panel (13.6 × 3.0, Front face (0, 21.6, -0.6)). HubBuilder's label is sized from `surfaces.Hub_MoonRocket`: "MOON BASE" in the lobby, "BACK TO NUKE TOWN" on the Moon.

Colliders are one list in both layouts and are asserted equal; the ring opening stays walkable. Anchor `trigger` = 9 × 10 × 2.5 at (0, 8.4, 0), `prompt` (0, 4, -11), `arrive` 24 (Moon) / 18 (lobby) studs in front, facing away.

**Lobby placement (HubLayout, appended LAST after the Time Machine).**
- Where: district 7's paving forecourt beside avenue 1, yaw 346.5 / r 208, turned to the spawn.
- Spawn view: ~44.5° RIGHT of the spawn axis, mirroring the Time Machine's ~39° LEFT. The two portals frame the SELL NUKES sign, 228 studs apart.
- Load wave: first-wave (174 studs from the spawn).
- How it was chosen: a scripted scan over every yaw / radius with the hub-layout rules (forecourt paving, off the avenues, the gates, the park's trees and lamps, the EventSquare, ≤ 45° from the spawn view, not behind the title sign, sightline from the spawn).
- `tests/hub-layout` §7 now reads each portal's model from its anchor (`PORTAL_MODELS`: Hub_TimeMachine / Hub_MoonRocket), checks both, keeps them ≥ 60 studs apart, and requires the portals to be the last placements.
- Lobby budget: grows by exactly one portal, to 680 MeshParts / 154k triangles / 39 meshes (measured 678 / 152.8k / 39).

**Look + feel (WorldClientConfig, `music_moon_base`):**
- Lighting preset `moon`, retuned after the lead's review.
  - The first pass was lilac light on lilac ground, so props, pets and plots all read as one purple-grey.
  - The world is now lit neutrally: Ambient (128,132,142), OutdoorAmbient (168,172,182).
  - A very thin near-white Atmosphere (0.02, no haze or glare) keeps the stars and far plots crisp.
  - A white tint with +0.2 saturation and +0.1 contrast makes the candy accents pop.
  - The grounds were recoloured to match: near-neutral plaza dust (226,226,238), the lightest plot ground (236,236,244), and a darker, bluer crater field (156,162,200) plus blue-grey rocks.
  - The navy sky and stars are unchanged.
  - The place has EnvironmentDiffuseScale 1, so the skybox adds a little sky light; a test at 0.3 changed very little, so the preset leaves it alone.
- Sky: a star-field skybox from `tools/ui/sky/moon_sky.py`.
  - Six Image faces with a navy gradient computed from true elevation, so the seams are invisible.
  - About 900-1,400 stars per face, with twinkles and soft nebula puffs. Receipts are in `assets/sky/moon/receipts`.
  - WorldClient (W10b) swaps it in as a client-only `WorldSky`. ClockTime is never touched, so the sun keeps the studs bright.
- `Physics.moon.gravityScale = 0.4` (WorldGravity, W10b).
- `Portals.moon` = { `Hub_MoonRocket`, icon `MoonRocket`, "space pets" } for the WORLD UNLOCKED popup.
- Music: context `moon` = APMOfficial "Strange Planet" + "Friendly Robot" (QUIRKY RETRO TECH, genre children; verified with `get_asset_details`), over H1's ForgeGUI `amb_space` bed.

**WorldFx rows (small in-place edits):**
- `MoonSwirl` (portal swirl spin).
- `MoonBlink` (antenna tip bulb, R19-capped pulse, via `Assemblies.Moon_Antenna`).
- The antenna `Dish` sweeps through the existing Dish row. Its piece has a counterweight, so the box is centred on the mast.
- Fountain `Ripple` rings use the existing row.
- `Crystal*` pieces glow through the existing Crystal row.

**Budgets (tests/moon-hub-layout §6, measured):**

| Group | MeshParts | Triangles | Unique meshes |
|---|---|---|---|
| Landing Plaza first view (cap 700 / 150k / 45) | 152 | 42.9k | 18 |
| Decor (deferred) | 163 | 13.4k | 3 |
| Scenery | 514 | 55.7k | 6 |

Captures are in `docs/verification/moon/`. They were taken in a solo playtest, 2026-10-31, through the real server build
(`WorldService.unlock` / `travel`, the star skybox, the moon lighting):
- `moon-{arrival,back,return-portal,egg-stands,leaderboard,fountain,aerial,sky,plot,ingame}.jpg`
- `lobby-{moon-rocket,spawn-turn-right,portals}.jpg`
- Device matrix (phone / tablet / console, HUD on, join modals closed): `moon-hub-*.jpg`, `lobby-moon-rocket-*.jpg`
- After the lighting retune: `moon-arrival.jpg`, `moon-aerial.jpg`, `moon-plot-overview.jpg`, plus device matrices `moon-base-camp-*.jpg` and `moon-plot-overview-*.jpg`

A client check showed both Moon Rocket swirls turning ~90°/s.
* Uploaded: 26 models / 241 pieces, all ids live (`sync_meshes.py --check` up to date); one transient
  Open Cloud "operation failed" on M3_CaptainGlorp, re-uploaded with `--abandon` (no orphan).
* `BillboardSpots.luau` regenerated (`generate-spots.luau --world moon`): the solver puts the M3 / M4
  producer boards to the side of the counter / console; `tests/billboard-clearance.luau` green.
* Studio (edit mode, `spawn_moon_area03/04.luau`, studio lock W7): M3 183 MeshParts, M4 187, 0
  fallbacks, 0 missing keys. Captures `docs/verification/world3/m03-*` / `m04-*`: `front`, `iso`,
  `isoL`, `archfront`, `archback` (both faces read correctly, R17), `producer`, plus `-sheet`.

## R75 Glow Rock miners animated + static-worker sweep (W7, 2026-10-31)

Owner: "You animate the miners in the Glowrock area. They don't actually do anything." The motion
contract (hinges, `swing`, impacts) is in `docs/build-in.md` "W7 R75".

* **`A4_Miner` rebuilt** (`area04.py` `build_miner`). What stayed the same:
  * key, feet-centre origin, footprint and look;
  * the 3 placements in `A4_PickaxeCrew` (no layout, pad or economy change).

  What changed: the figure is now R30 rig-split (`_npc_rig.rig_split`, `a4_bones(xf, "down",
  "pickaxe")`).
  * The pick arm + pick is its own group: `ArmRShirt`, `ArmRSkin`, `ArmRPick`, hinged at
    `MINER_SHOULDER` (1.45, 4.1, 0).
  * Torso / head / left arm lean about `MINER_HIP` (0, 2.3, 0).
  * Legs, `Rock` and `Glow` stay static.
  * 18 pieces, 1304 tris. Uploaded `--only A4_Miner`, synced.
  * Blender pose renders set the strike to −52°: the pick's lower tip meets the rock top at
    about −46°.
* **Sweep of Nuke Town toy_figure workers:**
  * `A9_AstronautCrew` (`area09.py`): astronaut 1's raised arm is now split out (`WaveSuit` /
    `WaveStripe` / `WaveGlove`, `CREW_WAVE_SHOULDER`) and waves. The flag flutters about
    `CREW_FLAG_POLE`. 18 pieces, 5264 tris. Re-uploaded and synced.
  * Left as they are: the ten managers (A1 UncleAtom … A10 ChiefEngineer), which are already
    R30-animated by ManagerController, and `A8_MascotNukey`, which is a statue.
* **Gates:**
  * R24 overlaps Area04 0 / Area09 0; R18 z-fight 0 in every scene; R19 glow budget green;
  * `mesh-assets`, `world-fx` and `world-fx-swing` green.
* **Studio (solo playtest, studio lock W7):** six miners + the crew on a test platform, camera
  pinned. `docs/verification/r75/miners-00..15.jpg` + `miners-sheet.jpg`.
  * In `miners-08`, the left miner is wound up while the right miner strikes, with chips flying
    off the centre rock.
  * In `miners-09`, the left miner recoils off its rock with chips + sparkles while the right
    miner winds up.
  * The phases differ per miner.
