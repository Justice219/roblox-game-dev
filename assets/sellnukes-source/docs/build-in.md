# Build-in animation + world FX

Owner requirement (R1, spec §5): **every purchase builds in front of you** like the LEGO games'
master builders: pieces float in translucent, fade to solid and snap into place one after another.
The world is alive: rotors spin, belts scroll, crystals and reactors glow, pads squish with a
"ka-ching", and unlocking an area plays a fanfare.

Evidence (`docs/verification/build-in/`, Studio solo playtest, slowed 0.3× for capture):
`00-before.jpg` → `02-building.jpg` (translucent ghosts arcing in around the buyer) → `08-after.jpg`;
`sheet-purchase.jpg` (8 frames incl. the confetti finale); `sheet-unlock.jpg` +
`14-unlock-fanfare.jpg` (another player's area unlock: Light drop-in + fanfare). Measured on the
client: 30/30 ghosts returned to the pool and no leftover ghosts, pad top dipped 0.37 studs,
Rotor/Glow/Bubbles moving, 10 PointLights enabled (cap 12).

---

## 1. Server contract (confirmed with B5 PlotBuilder; B11 event decorations use the same)

Set on the wrapper **Model BEFORE parenting it** into Workspace:

| Name | Type | Meaning |
|---|---|---|
| attribute `BuildIn` | number | `workspace:GetServerTimeNow()` when the purchase was placed |
| attribute `BuyerUserId` | number | buyer's UserId (Full animation for them, Light for others) |
| CollectionService tag `BuildIn` | — | how the client finds it (anywhere in Workspace) |
| `ModelStreamingMode = Atomic` | — | the model streams in whole |
| attribute `PadId`, `BuildKey`, `AreaIndex` | string / string / number | optional (PadId → fallback ka-ching) |
| attribute `AreaUnlock` | number | on an area's **Base** when its Unlock pad is bought → fanfare |

Pieces carry `BuildOrder` (int, bottom-to-top, set by `MeshLibrary.spawn` and by B5's
placeholder primitives); animatable pieces carry the `WorldFx` tag (MeshLibrary). Restored plots
(rejoin / rebirth / admin rebuild) carry no `BuildIn` and no tag, so they appear finished.
Invisible collision Parts (Transparency 1) are never animated.

**Pads:** a Model tagged `SNPad` (shared with B6) in `AreaNN/Pads`, named after its padId, pivot =
ground centre, with `PadId`. On purchase B5 sets `PressedAt` (server time) and destroys the pad
0.6 s later. The client squishes the pad and plays pop + ka-ching. With no `PressedAt`, a
ka-ching still plays at the new build.

## 2. Client modules

```
src/client/Tycoon/Fx/PlotWatcher.luau        tag-based discovery (BuildIn + SNPad tags; no DescendantAdded):
                                             BuildAdded(model, info{age,isBuyer,padId,areaIndex,isAreaBase}), PadAdded(model)
src/client/Tycoon/Fx/FxQuality.luau          device tier Low / Mid / High (owner R11), cached
src/client/Tycoon/BuildIn/BuildInController   the LEGO build-in (Init/Start; BuildFinished signal; setTimeScale for captures)
src/client/Tycoon/BuildIn/GhostPool           pooled ghost copies (one Clone per new mesh, tags + non-visual children stripped)
src/client/Tycoon/BuildIn/BuildPlan           pure timing/easing/order maths (tests/build-in-plan.luau)
src/client/Tycoon/Fx/WorldFxController        world motion, lights, steam, belts, pad squish, fanfare (Init/Start)
src/client/Tycoon/Fx/FxSound                  adapter -> src/client/Audio/Sound (pooled 3D, SFX group, settings.sfx)
src/client/Tycoon/Fx/Confetti                 pooled confetti (stud squares in candy colours) + sparkle bursts
src/shared/Config/BuildInConfig.luau          build-in tunables
src/shared/Config/WorldFxConfig.luau          data-driven piece table + tier budgets
```

**Boot:** both controllers follow the controller contract (`Init()` / `Start()`, idempotent) and are
listed in `src/client/init.client.luau` (`Tycoon/BuildIn/BuildInController` before
`Tycoon/Fx/WorldFxController`, which subscribes to `BuildFinished`).

### Device tiers (owner R11: console + mobile are primary)

`FxQuality.tier()` comes from graphics quality: 1–3 Low, 4–7 Mid, 8–10 High. At Automatic it
comes from the device: Phone Low, Tablet/Console Mid, Desktop High. Phones are capped at Mid. The
tier is cached and recomputed only when the quality setting changes.

| Tier | Max ghosts | Flown / build | Confetti | Build range | FX range | Moving | Lights | Steam |
|---|---|---|---|---|---|---|---|---|
| Low | 24 | 14 | 45 % | 200 | 140 | 48 | 4 | 2 |
| Mid | 40 | 26 | 75 % | 260 | 200 | 100 | 8 | 5 |
| High | 60 | 40 | 100 % | 320 | 260 | 160 | 12 | 8 |

Per frame there is no Instance.new and no table or closure creation; the only per-frame values are
the CFrames of pieces actually moving. Scratch arrays are cleared and reused, comparators live at
module level, and all moves go through one `BulkMoveTo`. Lights,
emitters and textures are created once, then toggled. When a gamepad player's build completes,
B16's `Platform/Haptics.play("BuildComplete")` fires (gamepad rumble or phone vibration;
respects the Vibration setting; rate-limited).

## 3. The build-in, step by step

1. PlotWatcher sees a Model with `BuildIn` under `Workspace.Plots` and defers one frame, so the
   whole Atomic model has replicated.
2. **Mode:** older than `FreshWindow` (2.5 s) → shown finished. Reduce Motion (Roblox setting or
   `profile.settings.reducedMotion`), or the camera beyond the tier's `LightRange` → no flight.
   Buyer → **Full**. Anyone else → **Light**.
3. Visible pieces are sorted bottom-to-top (world bottom-Y rounded to ¼ stud, then `BuildOrder`,
   then name), then hidden on this client with `LocalTransparencyModifier = 1`. The server copies
   stay real and collidable immediately.
4. `BuildPlan.schedule` spaces launches so the whole build takes 1.2–2.5 s whatever its size.
5. **Full:** each ghost starts at a random point 7–16 studs around the buyer, 3–11 studs up. Start
   points are pushed at least 6 studs from the camera. Each ghost flies a Bezier arc (ease in/out)
   from 85 % transparent to solid, unwinding a random spin of up to 75° with a small overshoot
   (the "snap"). A whoosh plays at the first launch, and a clack every 3rd landing with pitch
   rising 0.9 → 1.25. The finale is a stud-confetti burst plus a sparkle sound.
   **Light:** pieces drop 5–8 studs straight down and fade in, with a small sparkle at the end.
6. When a ghost lands, the real piece is revealed and the ghost goes back to the pool.
   `BuildFinished(model, info)` fires; an area Base triggers the fanfare.
7. **Caps** (per tier): `MaxGhosts` across all builds, `MaxFlownPerBuild` per build. Extra pieces
   fade in place. If the model is destroyed or streamed out mid-build, the animation aborts
   cleanly. Your own completed build triggers `Haptics.play("BuildComplete")` (B16).

Performance: one RenderStepped connection, connected only while a build animates; one
`BulkMoveTo` per frame; no per-frame Instance.new, tweens or threads.

## 4. World FX (data-driven by piece name)

Name a Blender piece with a word from `WorldFxConfig.Pieces` and it animates. No code is needed.
Resolution order is exact name, then `Aliases`, then the leading capitalised word (`Rotor_Left`,
`Belt2` → Rotor, Belt).

| Name | Behaviour |
|---|---|
| Rotor / Turbine / Fan / Wheel | spin (Y / Z / Z / X axis) |
| Dish (Radar), Arm | oscillate (sweep / wave) |
| Belt (Conveyor) | stud texture scrolls along the belt |
| Glow | bob + pulsing PointLight |
| Crystal, Core (FaceGlow), Liquid, Bulb (Lamp, Lamps), VentGlow | pulsing PointLight only |
| EngineGlow | flickering PointLight only (rocket flame; `flicker = true`, same pulse cap) |
| Bubbles, Nuke, Rocket | bob (fizz / hover / rumble) |
| Climber | bob 14 studs over 12 s (space elevator pod) |
| Steam | soft white puffs (built-in smoke texture) |
| Door | reserved (static) |
| Ripple | bob 0.06 (lobby fountain water rings, R55) |
| Wave | oscillate Z ±14° (giant Nukey's arm; its box is mirrored about the shoulder in Blender) |
| Streamer, Pennant | oscillate Y ±6° / X ±5° (lobby banners twist, bunting swings) |
| Twirl, Whirl, Carousel | spin Y 40 / 110 / 20 °/s (pad-sign stars, floating coins, coin halo) |

**Motion groups (owner R25 / R26).** Pieces of one model that resolve to the same row move as one
group; `WorldFxConfig.Assemblies[modelKey]` widens that (`members` / `exclude`), e.g. the whole
NukeMobile body + roof rocket bob together while the tyres stay planted, and the A9 Space Port
rocket hovers as one piece (`RocketIdle`) while its `EngineGlow` flickers.

**Manager NPCs (owner R30).** The ten manager models (`kind = "Manager"` build keys, e.g.
`A2_CashierBot`, `A4_Foreman`) are animated only by the ManagerController. `WorldFxConfig.groupFor`
never moves their pieces: a piece with a light / steam row (CashierBot `FaceGlow`, LaunchDirector
`Bulb`) joins the frozen `@NpcStill` group (light on, no motion); every other piece is untagged.
`WorldFxConfig.isManager` asks the sibling `ManagerNpcConfig.ownsModel` once it exists (looked up
lazily and pcall-guarded, so a missing / failing module falls back) and otherwise uses
`WorldFxConfig.FallbackManagers`, which `tests/build-in-plan.luau` keeps equal to the TycoonAreas
manager build keys.

One Heartbeat loop handles all of it. Every 0.5 s pieces are ranked by camera distance: only those
within the tier's `Range` are considered, up to `MaxMoving` move, the nearest `MaxLights` have
their light on, and the nearest `MaxEmitters` steam. Lights, emitters and belt
textures are created the first time a piece is near, then only toggled. Reduce Motion stops all
motion; lights and sounds stay.

To add a behaviour, add a row, e.g. `Fan = { motion = "spin", axis = "Z", speed = 260 }`. The lune
test validates every row.

## 4b. Vehicles + map motion (owner R56, V1)

> "animate more of the places in the map too, like, I feel like the delivery truck should drive in
> and out, semi-truck should drive in and out, you know, stuff like that."

Vehicles and machines drive along authored routes: they arrive on the plot road, back into their
stall / dock / bay, get loaded (cargo pops in with a bounce), honk and drive off, fading out on the
road. Wheels spin, bodies bob, the nose dips when braking, two-wheelers lean in bends, brake lights
and indicators glow softly, reverse beeps play while backing up.

```
src/shared/Config/VehicleRouteConfig.luau   routes (slot-local splines + waits), tiers, tunables, sounds
src/client/Tycoon/Fx/RouteMath.luau         pure: Catmull-Rom paths + arc length, speed profiles, timelines
src/client/Tycoon/Fx/VehicleRoutes.luau     the controller (Init/Start; boots after KnockdownFx)
tests/vehicle-routes.luau                   maths, rest poses, continuity, plot rotation, clearance sweep
tools/qa/vehicle_check.py (+ _client.luau)  Studio capture run (in / loading / out sequences)
```

Evidence (`docs/verification/vehicles/`, solo playtest, full plot, High tier, captured by
`tools/qa/vehicle_check.py`): `sheet_van.jpg` (reverse in → parcels on the roof → out),
`sheet_truck.jpg` (road → backing to the dock → crates on → out), `sheet_car.jpg` (barrier up →
parked → barrier up again), `sheet_all.jpg` (+ carts tipping / entering the tunnel, forklift drop,
lane scooters, belt rockets). Knockdown measured on area 6: its three routes' clocks advanced 0.000 s
while knocked and right after the rebuild, then resumed (1.2 s per 1.1 s); other areas kept moving.
Belt check (`belt_a/b.jpg`): rockets and belt studs shift +60 / +62 px between frames (same way, same
speed). `shots.json`: 7 groups, 12 vehicles, 106 pieces, no runtime errors.
Admin toggle (playtest, real WorldHandlers handler): OFF -> active routes 7 -> 0 and the van body back
exactly on its rest spot (0.00 studs); ON -> all 7 routes moving again.

### What moves (audit of areas 1-10 + hub)

| Area | Mover | Model (layout placement) | Route (slot-local studs) | Loop |
|---|---|---|---|---|
| 1 Garage Lab | — | `A1_NukeMobile` keeps its WorldFx idle bob; garage door stays open | (future: a Sunday drive) | — |
| 2 Nuke Stand | — | no vehicles (toy nukes bob via WorldFx) | — | — |
| 3 BoomDash | **delivery van** | `A3_DeliveryVan` (`A3_DeliveryVan#1`) | road x -74 → stops x 59.15 → reverses (arc R 12) into the lane x 47.15 → S-curve → stall (39.45, 29.4) → 3 parcels pop onto the roof → indicates right, honks → pulls out, arc R 13 onto the road → fades by x 74 → 6 s off-plot | 45.6 s |
| 3 BoomDash | lane scooters ×3 | `A3_Scooter` (`A3_Scooters#4..6`) | stadium lane, centre (0, 30), straights ±22, radius 9, 8.5 studs/s, lean in bends | 17.0 s |
| 4 Glow Rock Mine | mine-cart train ×2 | `A4_MineCart` (`A4_CartTrack#2`, #3 coupled 5.2 behind) | track x -22: fades out of the tunnel (z 62) → buffer (z 23.9) → tips 28° toward the bin, ore hops in → reverses into the tunnel, fades → reloads hidden | 29.8 s |
| 5 Enrichment Lab | — | centrifuge rotors spin via WorldFx | — | — |
| 6 Rocket Factory | **semi-truck** | `A6_DeliveryTruck` (`A6_LoadingDock#2`) | road x -74 → stops x 55 → reverses (arc R 14) into the lane x 41 → long S to x 46.4 (z 8 → 38) → dock (46.4, 51.25), beeping → 4 crates pop onto the flatbed → indicates right, honks → retraces forward → road → fades by x 74 | 53.1 s |
| 6 Rocket Factory | forklift | `A6_Forklift` (rest moved to (-41, 28), facing +X) | pallet pops onto the forks at A → drives to B (-23, 30.8) → drops it (hop + fade) → backs up to A, beeping | 17.9 s |
| 6 Rocket Factory | belt toy rockets ×3 | `A6_ToyRocket` (`A6_Conveyor#2..4`) | carried x 9.8 → 42.2 at z 40, belt speed 3 (= WorldFx `Belt`), fade at both ends | 10.8 s |
| 7 Launch Silos | — | silo nukes belong to attack mode; radar dish sweeps (WorldFx); control-room door is gameplay-driven | — | — |
| 8 Nuke Megastore | **shopper car** + garage barrier | `A8_ShopperCar` (`A8_ParkingGarage#2`); barrier = `BarrierYellow` / `BarrierBlack` pieces of `A8_ParkingGarage` (hinge (-4.3, 2.4, -22.8), lifts -70° about Z) | road → arc R 10 into the lane x 30.7 → barrier lifts → arc R 5.5 → bay (45.3, 37.5) nose-in → shops 12 s → reverses out (arc R 6) → lane x 31 → barrier lifts → arc R 10 onto the road → fades by x 74 | 58.9 s |
| 9 Space Port | — | rocket hovers + space-elevator climber via WorldFx | (future: fuel tanker to the fuel farm) | — |
| 10 Mega Facility | — | cooling-tower steam, turbines via WorldFx | (future: crane / drone) | — |
| Hub | — | L1-lobby owns hub motion (fountain, flags, signs, coins) | — | — |

### How it works

* **Routes are data.** A route = segments: `drive` legs (centripetal Catmull-Rom spline through
  `points`, optional `reverse`, boundary speeds v0 / v1, accel / decel, fade-in / fade-out studs,
  reverse `beep`, `gate` open / close points) and `wait`s (cargo `load` / `unload`, `honk`,
  indicator `signal`, mine-cart `tip`). Authoring helpers `line`, `arc`, `sCurve`, `road`, `ground`
  (curb ramp). The near road lane is z = -6; off-plot ends are |x| = 74.
* **Rest pose.** `rest` names the vehicle's AreaLayouts placement; the clock starts where the
  route passes through it (`start`), fully loaded — exactly the server's authored look. Reduce
  Motion and the admin switch put vehicles back there (every quality tier drives them, R103).
* **Followers** share the leader's clock: `gap` = studs behind along the path (the coupled mine
  cart; it fades in / out on its own position), `sync = "nearest"` = own spot on the same loop
  (lane scooters, belt rockets — spacing never drifts).
* **Time model.** `RouteMath.sample(timeline, clock, instance)` is a pure function of the clock:
  culled / half-rate / off-screen vehicles keep their clock and land exactly right when written.
  Wheel spin = lap-continuous odometer / radius (forward roll = negative X spin).
* **One unit (R25).** Every piece's CFrame = vehicle frame × its manifest offset (× ImportYaw for
  meshes); wheels spin about their own axle (one piece per axle, bbox centre on the axle); cargo
  rides the body. WorldFx never animates a routed model (`WorldFxConfig.RoutedModels`, lights on
  light rows still glow, frozen in `@Routed`).
* **Never blocking players.** Driven placements have no collision box (A3 van `collide` flag, A6
  truck + forklift boxes and the A8 car box were removed); the client also turns CanCollide /
  CanQuery / CanTouch off on every driven piece.
* **Knockdown (R50).** An area's `KnockedUntil` change freezes its vehicles at once (same signal
  KnockdownFx topples from), so the rubble starts from where the vehicle stood and the rebuild flies
  it back there; they resume `ResumeAfterKnockdown` (5 s) after the area is up. A fresh purchase
  waits `BuildHold` (5 s) for its build-in to land.
* **Lights (R19 soft glow).** `BrakeLights` turn Neon (lifted red) while slowing and for
  `BrakeHold` after stopping; `IndicatorL` / `IndicatorR` blink amber (1.6 Hz) for turns coming up
  within 10 studs (forward legs) and for `signal` windows. Property writes happen on change only.
* **Sounds** (`VehicleRouteConfig.Sounds`, AudioConfig 3D SFX): honk = `vehicle_honk` (toy
  "honk-honk", rolled per lap against `honkChance`), reverse = `vehicle_beep` once per reverse leg
  (`beep = true`: van, semi, forklift), cargo load / unload = `pop` / `clack`; only within 70 studs
  and on screen.

### Performance (owner R11)

| Tier | Moving | Range | Half-rate beyond |
|---|---|---|---|
| Low | nearest 4 routes | 140 | 45 |
| Mid | nearest 8 routes | 190 | 90 |
| High | nearest 16 routes | 260 | 140 |

Owner R103 ("none of the vehicles are animating like they used to"): Low used to park every
vehicle (zero cost) while the machines (WorldFx Low) and manager NPCs kept moving, so on a phone
(Automatic graphics = Low, ~30 % of live sessions) or at graphics 1-3 only the vehicles stood still.
Low now drives the nearest 4 routes within the machines' 140-stud range. Reduce Motion (Roblox or
profile setting) and the admin Vehicles switch still park everything; `VehicleRoutes.stats().parked`
names the reason (`"tier"` / `"reducedMotion"` / `"admin"`, nil = driving). FxQuality no longer
caches a tier read before the camera has a real viewport (a touch device read that early classifies
as "Phone" and used to pin a tablet to Low for the session).

One Heartbeat connection, one `BulkMoveTo` per frame, ranking every 0.5 s, no Instance.new, no
per-frame tables or closures. Routes outside the camera cone keep their clock and skip writes.
Discovery is streaming-aware (`Workspace.Plots` DescendantAdded filtered to Models whose
`MeshKey` a route drives; DescendantRemoving unregisters), so only built, streamed-in areas move.
Admin: World tab **Vehicles on/off** (`VehiclesToggle`, `Server/Admin/Handlers/WorldHandlers`,
audited) sets ReplicatedStorage `VehiclesEnabled` (`VehicleRouteConfig.EnabledAttribute`); false
parks every vehicle on its spot live. Analytics: none recorded — the system is purely visual
(no player actions, no economy); the admin toggle is in the admin audit log.

### Blender contract (tools/blender/models/area03/04/06/08.py)

`Tyres*` / `Hubs*` / `Wheels*` one piece per axle (bbox centre on the axle, symmetric hub spokes so
spin reads) · `BrakeLights` (Smooth red) · `IndicatorL` (-X side) / `IndicatorR` (+X side) (Smooth
amber) · `Cargo1..N` one piece per crate / parcel. New models: `A6_DeliveryTruck` (cab-over semi +
flatbed, 14.5 × 5.0, split out of `A6_LoadingDock`), `A8_ShopperCar` (split out of
`A8_ParkingGarage`, whose barrier is now `BarrierYellow` / `BarrierBlack`, authored down).

### Add a mover

1. Blender: give it per-axle wheels / lights / cargo pieces as above, upload + sync.
2. Place it in the area layout (no collision box); add a route in `VehicleRouteConfig` and its key
   to `WorldFxConfig.RoutedModels`.
3. `lune run tests/vehicle-routes` — it fails on any collider hit, off-slot corner, broken join, or
   a rest pose not on the route; then capture with `tools/qa/vehicle_check.py`.

## 5. Sounds

`clack`, `whoosh`, `sparkle`, `kaching`, `pop` and `fanfare` are original synthesised sounds
(`tools/audio/generate_world_sfx.py`). They play through the game-wide audio API
(`src/client/Audio/Sound.luau`) via the `FxSound` adapter: pooled 3D emitters, the SFX group,
pitch variation and the `settings.sfx` mute. Ids live in `SoundAssets.SfxIds`, playback rules in
`AudioConfig.Sfx`. Upload with `tools/audio/upload_sfx.py`. See `docs/audio.md`.

## 5b. Knockdown rebuild (owner R50)

`BuildInController.rebuild(model, { starts?, isOwner, areaIndex? })` replays the fly-in on a model
that already exists. With `starts` (piece → rubble CFrame), each ghost lifts off its rubble piece at
the same tilt and arcs home (spin = home⁻¹ · rubble), and only those pieces fly. Without `starts`
it flies in like a purchase. It ignores FreshWindow; far / Reduce Motion finishes at once.
`setDeferHook(fn)` lets `Tycoon/BuildIn/KnockdownFx` take over a FRESH build bought inside a
knocked-down area: it stays hidden and builds in after the area's rebuild. `settle(model)` ends a
build-in still flying on a model that is about to topple. The topple itself (KnockdownFx) moves
the existing pieces locally (one BulkMoveTo per frame, tier budgets) and is documented in
docs/attack.md §13.

## 6. Verify

```bash
lune run tests/build-in-plan     # schedule bounds, easing, clacks, ordering, FX table, sound ids
lune run tests/vehicle-routes   # R56 routes: maths, rest poses, continuity, plot rotation, clearance
python3 scripts/studio-lock.py acquire B4
python3 scripts/studio_mcp.py call solo_playtest '{"action":"start","mode":"play"}'
# eval_server_runtime: tools/blender/studio/buildin_setup_server.luau, then buildin_purchase_server.luau / buildin_unlock_server.luau
# eval_client_runtime: tools/blender/studio/buildin_start_client.luau (slow motion for captures), buildin_stats_client.luau
python3 tools/blender/studio_shot.py docs/verification/build-in/x.jpg
python3 scripts/studio_mcp.py call solo_playtest '{"action":"stop","timeout":60}'
python3 scripts/studio-lock.py release B4
```

## W10 worlds (R57): routed vehicles in every world + the D3 ptero couriers

**World-aware routes.** `VehicleRouteConfig` rows gain an optional `world` (nil = Nuke Town
`"main"`). `Fx/VehicleRoutes` discovers models in EVERY world's plots folder through
`Tycoon/PlotFolders.watch` (Nuke Town `Workspace.Plots`, others `Workspace.Worlds.<id>.Plots`),
reads the plot's world with `TycoonWorld.worldOf`, binds a model only to routes of that world +
area, maps slot-local poses through `WorldLayout.slotOrigin(plot, area, world)` and reads rest
placements from that world's layouts (`WorldLookup.layout(world, area)` →
`WorldDef.layoutFolder`). Nuke Town routes are unchanged (same rows, same frames, same tests).
Knockdown pauses still key off the area's `KnockedUntil`, which Dino Valley never sets (spec §7).

**D3 Ptero Post couriers** (`D3_PteroCourier`, two placements = `D3_NestTower` models #2 / #3,
perched on their parcels on the nest deck, y 20.6):

| Route | Story (shared 36 s clock `D3_Couriers`) |
|---|---|
| `D3_CourierOut` | perched → at 12 s flies out along its facing line, swoops down over the landing pad, hovers, drops its parcel onto the pad paint → turns round (hover spin 180°) → flies home → turns round on its perch → a new parcel pops into its feet (home ~32 s) |
| `D3_CourierIn` | at 1 s pushes its parcel back into the nest pile → turns toward the road (−36°) → climbs out along x −7.6 over the walkway and the PTERO POST arch (y ≥ 25.6 there) → fades into the sky over the road → (off screen: new parcel) → fades back in, lands facing the trunk → turns round on its parcel (−144°), home by 23.6 s |

Flight rules the layout forces (all proven by `tests/vehicle-routes.luau` against every collider
AND every visible piece box of Dino Area03): ≤ 21.6 under the nest canopy (crest + flapping wing
tips clear its underside at 26.4), ≥ 21.6 over the twig rim (the parcel clears it), above 16 over
the back jungle fronds (z > 41.6), above 25.6 over the arch, inside the slot / the road in front
of it, under the 80-stud height budget. Reduce Motion and the admin Vehicles switch park both
couriers on their perches (the authored layout look); Low quality drives them on its small budget (R103).

**New route features (config + `RouteMath`, usable by any future flyer):**
* `flyer = { wingLeft, wingRight, amplitude, period, restAmplitude, restPeriod, blendSeconds,
  heave, climbGain, climbMax }` — VehicleRoutes flaps the two wing pieces about the model's local
  Z through their box centres (balanced on the body centre line by the Blender builder),
  mirrored so both tips rise together (left turns by −θ, right by +θ), in the same BulkMoveTo as
  the body. The stroke eases between perched (3°, 2.6 s) and working (24°, 0.6 s) wings, the body
  heaves 0.22 studs per stroke, the nose follows the climb (`climbGain` 0.35, ≤ 12°) and `lean`
  banks it into turns. Time-based phase: a culled / half-rate bird keeps its rhythm.
* Wait `hover = true` (wings keep working) and `spin = <degrees>` (eased turn on the spot; later
  waits keep the turn, so a flyer lands facing in and takes off facing out).
* Route `period` + one `stretch` wait (the loop lasts exactly `period`; `periodOk` flags legs
  that do not fit) and `start.before` (start counted back from the segment's end).
* Route `sync = "<key>"`: routes of one area with the same key share ONE clock (advanced once per
  frame by whichever runs first; a group catching up after sitting out skips its missed sounds).
  The test samples the shared loop every 0.05 s and proves the partners' per-piece boxes (wings
  inflated by the flap, everything by the heave) never touch — closest approach 9.5 studs (their
  perches).

**Courier squawks (W10b).** Routes gain an optional `horn = { key, volume }` that a `honk` wait
plays instead of the toy honk (`VehicleRoutes.playEvents`). Both couriers use
`ptero_squawk_cute` (volume 0.8, `honkChance` 0.5, deterministic roll per lap): courier 1 as it
drops its parcel on the landing pad (hover wait, +0.3 s), courier 2 as it lands home (spin wait,
+0.2 s) — about one squawk per 36 s per nest, only within `Sounds.Range` (70 studs), silent under
Reduce Motion (vehicles parked). `tests/vehicle-routes.luau` checks every horn is a real SFX key,
has a honk wait, and the couriers stay sparse (`honkChance` <= 0.5).

## W10b Dino world FX (R57): rows, assemblies, sounds

All world-agnostic (piece names decide; `WorldFxController` discovers by tag wherever a model is
spawned). Rows added to `WorldFxConfig.Pieces` (requests in `docs/areas-art.md` "For W10"):

| Row | Pieces | Motion |
|---|---|---|
| `Flame` | D1 torch walls `FlameA/B/C`, fire pit `FlameOuter/Inner`, D5 / D6 arch `Flame` | none; soft flicker light (range 8, brightness 0.45, pulse 0.2 — R19 caps) |
| `Ears` | `D2_MammothFan.Ears` (one piece, box centred on the head axis) | oscillate Y 14° / 1.6 s |
| `Sock` | `D3_WindSock.Sock` + `SockStripes` (one group, centred on the pole) | oscillate Y 30° / 4.5 s |
| `LavaFlow` | `D6_LavaChannel.LavaFlow` | scroll 1.5 studs/s (Top) |
| `LavaFall` | `D6_LavaFalls.LavaFall` | scroll 1.5 studs/s on Top + Front (the cliff ribbon) |
| `Wobble` | `D5_Incubators.WobbleEgg*` + `WobbleSpots*` (one group) | bob 0.08 / 0.7 s |
| `Geyser` (assembly-only) | `Assemblies.D4_GeyserVent.Jet` / `D4_MegaGeyser.Jet` = `Column` + `ColumnFoam` | bob 1.2 studs / 6 s + `geyser_whoosh` as it rises |
| `WaterWheel` (assembly-only) | `Assemblies.D4_WaterWheel.Wheel` = `Wheel` + `WheelTrim` | spin X 40°/s (slower than `Wheel` 120) |
| `TimeSwirl` (assembly-only) | `Assemblies.Hub_TimeMachine.Swirl` (lobby + Base Camp portal arms, centred on the ring) | spin Z 90°/s; `Shop_Teleporter.Swirl` stays still |

* There is deliberately **no generic `Lava` row** and **no global `Column` row**: the leading-word
  rule would animate `D6_Floor.LavaCracks`, the cone's `LavaStreaks`, the Valley backdrop's `Lava`
  (W9) and Nuke Town's static `Column` pieces (A6 shells, A9 space elevator).
* `D6_StoneTurbines` `WheelStone` / `WheelHub` use the existing `Wheel` row (one model per turbine,
  both boxes on the axle). The routed `D3_PteroCourier` and the six Dino managers are never moved
  by WorldFx (routed / manager models).
* Scroll rows take `faces` (Enum.NormalId names, default `{ "Top" }`); a member keeps a list of
  belt textures, scrolled together (one offset per member per frame, on screen only).
* **Sounds (sparse, FxQuality-aware).** A periodic row may carry `sound = { key, at, range,
  volume }` (played once per period as its cycle passes `at`), and `WorldFxConfig.Ambience`
  lists model ambience (`D6_VolcanoTop` → `volcano_rumble_soft` every 18 ± 7 s within 120 studs).
  Both share the tier budget `MaxSounds` (Low 1, Mid 2, High 3): at each refresh only the nearest
  in-range sources get a slot (periodic ones only while actually moving, so Reduce Motion /
  far = silent); a source losing its slot re-arms instead of replaying. AudioConfig voices /
  minInterval guard stacking on top.
* `tests/world-fx.luau` (274 checks): every row above, each Dino piece's resolution and grouping,
  rotation centres (ears / sock on their axis, wheel + trim / turbine stone + hub on the axle), no
  non-Dino piece reaching a Dino row, A6 / A9 `Column` not geysers, sound keys real, MaxSounds
  rising with tier, the managers' hop voice sparse and off on Low.

## W7 R75: hinged swings + impact events (the Glow Rock miners)

Owner R75: "You animate the miners in the Glowrock area. They don't actually do anything."

* **Hinges.** An `Assemblies[modelKey].<Group>` entry may carry `hinge` (model space, the same
  feet-centre frame the Blender builder uses). The group then rotates about
  `owner:GetPivot():PointToWorldSpace(hinge)` on the axis `pivot:VectorToWorldSpace(axis)` (a
  shoulder or hip). Without `hinge` it still turns about the leader's bbox centre (R25).
* **`follow`.** `follow = "<OtherGroup>"` composes motion: the group first rides the other group's
  transform, then adds its own. Used for the pick arm, which rides the body lean.
* **`swing` motion** (`Shared/World/SwingCurve.luau`, pure):
  * `keys = { {t, angle, ease?} }` form a keyframed loop over `period`. The first and last keys
    are t = 0 / 1 with the same angle. `ease` shapes the segment ending at that key: `in`
    accelerates (a strike), `out` decelerates (a recoil), `inout`/nil is a smooth step.
  * All swing groups of one model share ONE phase, so the arm and the lean stay in step. Each
    placement gets its own phase, so the miners are de-synced.
  * `gentle = {amplitude, period}` is what Reduce Motion plays instead: a slow sine sway with no
    strike and no impacts. Swing rows without `gentle` stop under Reduce Motion like everything
    else.
* **`impact = { at, range, burst?, sound?, flash? }`** fires once per loop as the phase passes
  `at`. It uses a wrap-aware crossing test that is never armed on the first frame or right after
  coming back into range. It only fires when all of these hold:
  * the group is on screen (view cone) and within `range`;
  * the tier's `Bursts` > 0 (Low 0 = swing only, Mid 0.7, High 1);
  * Reduce Motion is off.

  When it fires:
  * `burst` → `Client/Tycoon/Fx/ImpactBursts`, a pool of 3 Attachments per kind under Terrain with
    `Chips` (stud squares, stepped palette, gravity) + `Sparkles` emitters. They are built on first
    use, then only moved + `Emit()`-ed. Kinds live in `WorldFxConfig.Bursts` (`rockChips`).
  * `sound` → `FxSound.play` at the strike point. It needs a `MaxSounds` slot (impact sources
    count in the same nearest-first budget as periodic rows / ambience). AudioConfig
    voices / minInterval guard stacking.
  * `flash` → the model's `Glow` light holds full brightness for that many seconds (the gems
    flare on each hit).
  * The strike point is `Assemblies.<group>.impactAt` (model space) → world, cached on register.
* **Rows:**

  | Row | Motion |
  |---|---|
  | `PickSwing` | X swing, 2.6 s: wind-up +46° → strike −52° at t 0.47 (`in`) → recoil −44° → settle; impact `rockChips` + `pick_clink` (60 studs) + flash 0.35 s; gentle ±8° / 5.2 s |
  | `MinerLean` | X swing, 2.6 s: back +5° with the wind-up, forward −6° into the strike; gentle ±1.2° |
  | `FlagFlutter` | oscillate Y ±12° / 2.6 s |

* **Assemblies:**
  * `A4_Miner.Pick` = `ArmR*` (shoulder hinge (1.45, 4.1, 0), follows `Lean`, impactAt
    (1.35, 2.6, −3.2)).
  * `A4_Miner.Lean` = `Torso*` / `Head*` / `ArmL*` (hip hinge (0, 2.3, 0)). Legs, `Rock` and `Glow`
    stay planted; `Glow` keeps its own row.
  * `A9_AstronautCrew.Wave` = `WaveSuit` / `WaveStripe` / `WaveGlove` (the `Wave` row about the
    shoulder (−7.8, 4.65, 0)).
  * `A9_AstronautCrew.Flag` = `Flag` + `Stars` (about the pole top (8.3, 8.4, 1.7)).
* **Tests:**
  * `tests/world-fx-swing.luau` (198 checks): SwingCurve maths, every swing row valid, PickSwing
    winds up > 20° and strikes < −30°, bursts sane, Low `Bursts` = 0, impact sound keys real.
  * The same test covers hinges within 1.5 studs of their members' boxes, `follow` targets valid,
    and the exact A4_Miner / A9 crew piece partition.
