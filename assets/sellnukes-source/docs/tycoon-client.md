# SellNukes tycoon client UI (B6)

The client half of the tycoon: billboards, pad labels, clicking / upgrading input, income pops,
the YOU marker, the HUD `+$X/s`, the tutorial and the stand rename prompt, plus the Teleport,
Rebirth, RenameStand and TycoonTutorial screens. The server (`src/server/Tycoon/**`,
`src/server/World/PlotBuilder.luau`) owns every number and every purchase; the client only draws
server state and sends **intents**. The build-in fly-in (`Tycoon/BuildIn`) and world FX
(`Tycoon/Fx`) are B4's. Verified look: `docs/verification/ui/tycoon/*.png`.

## 1. Boot

`Controllers/UIController.Start` → `Tycoon/TycoonClient.start()` (after the HUD and screens), which
starts, each under pcall: `TycoonWorld` → `ProducerBillboards` → `PadBillboards` → `Interaction` →
`IncomePops` → `YouMarker` → `Income` → `Tutorial` → `StandSign`.

## 2. World contract (B5 final; names only in `Tycoon/TycoonContract.luau`)

```
Workspace.Plots/PlotN (Model)          PlotIndex, OwnerUserId (0 = free), OwnerName, StandName
  YouAnchor (Part)                     invisible, above the entrance arch: YOU marker
  AreaNN (Model)                       AreaIndex
    Pads/<padId> (Model, tag SNPad)    PadId, OwnerUserId, Cost, Kind, Name, Blurb, Color, Area,
                                       Order, Value?, Feature?, PressedAt (bought; destroyed 0.6 s
                                       later); children Trigger (touch volume) + Visual
    Producer/Anchor (Part, SNProducer) ProducerId, OwnerUserId, Area, Name, Level, PerCycle,
                                       CycleTime, CycleStart, Automated, Badge, BadgeNextAt,
                                       NextCost (-1 = max), PerSecond
    Producer/ClickBox (Part)           invisible sibling with the server ClickDetector (3D click /
                                       tap; the client only starts the bar for those)
    Builds/<BuildKey> (Model)          BuildKey, PadId, AreaIndex, [BuildIn, BuyerUserId]
Player attributes                      PlotIndex (0 = none), PlotAssignedAt, PlotRevealSeconds,
                                       PlotRevealed, IncomePerSecond (server, ALL modifiers),
                                       TycoonArea, FeatureStandRename / AATower / AttackConsole /
                                       Rebirth, IsAdmin
```

Automated bars loop: progress = ((now − CycleStart) / CycleTime) % 1. Manual: CycleStart = the
accepted click while running, 0 idle; a click is only accepted while idle (no other cooldown).

Intents sent: `ProducerClick(id)`, `ProducerUpgrade(id, "1"|"10"|"max")`, `PadBuy(padId)` (server
re-checks 12 studs), `RenameStand(text)`, `TeleportArea(i)`, `TeleportHub()`, `Rebirth()`,
`RebirthShopBuy(key)`, `PromptPass("Teleporter", "teleport")`. Listened: `IncomePop` (unreliable,
owner only, ≤ ~2/s per producer), `TutorialState { step, done, kind = "pad"|"click"|"upgrade",
target, padId?, producerId?, text }` (re-sent on join + every change; `{ step = 0, done = true }`
ends it; server `text` is shown as-is). Sent after a reveal: `PlotRevealDone()`.

## 3. Modules

| Module | Job | Performance |
|--------|-----|-------------|
| `TycoonWorld` | registry of producer anchors / pad triggers / own plot (Plots DescendantAdded/Removing, streaming-safe), `isMine`, `myProducer`, `myPad`, `myBuild` | event-driven, 2 name checks per streamed instance |
| `ProducerBillboards` | placed by §3a; stud billboard per producer (ref 08/15): name, `$/cycle` (`NumberFormat.money`), yellow `xN` badge, `xLevel`, stud progress bar ("CLICK" bar while a manual producer idles), x1/x10/MAX toggle, cyan UPGRADE pill with cost (grey when unaffordable) + key glyph; others' producers read-only | ONE PreRender loop: bar fills for visible billboards per frame; attributes / costs / distance culling at 4 Hz; text written only on change |
| `PadBillboards` | own pads (ref 09/11/17): name, italic blurb, price coloured by kind (Build red, Multiplier/Speed yellow, Manager cyan, Unlock green, Feature purple), grey when unaffordable; tap price = `PadBuy` | event-driven (cash changes) |
| `Interaction` | tap (`TouchTapInWorld`) / left-click raycast on own ClickBoxes → ProducerClick; F / R2 produce, E / X buy pad else upgrade, A (Buy) on a pad, Q / Y amount; feeds B16's ActionMap contexts (Producer / ManualProducer / Pad) + hint texts ("Buy $1.2K", "Upgrade x10") | input events + 5 Hz provider |
| `UpgradeMode` | x1 / x10 / MAX state + `Changed` | — |
| `IncomePops` | "+$X" pops on `IncomePop` (validated), pooled BillboardGuis, per-producer coalescing (0.25 s); each pop also calls `UI/Hud/CurrencyFly.fromProducer` (coins fly into the HUD cash counter: `click` right after the player's click, else an occasional `tick`; on-screen only, owner R46) | pool of 14, 3 tweens per pop |
| `YouMarker` | big "YOU" + arrow over the own plot entrance (client Attachment, works while the entrance is streamed out) | event-driven |
| `Income` | `Hud.setIncomeSource`: the server's player attribute `IncomePerSecond` only (never recomputed on the client; nil hides the row) | 1 Hz HUD poll |
| `Tutorial` + `TutorialSteps` | objective chip + world/edge arrow (`Hud.setObjective`) + ground arrow trail to the server's target; server text (else kind + target name); client step table only for kind-less payloads; intro card on step 1 | event-driven |
| `TutorialArrows` | owner R27: 8 pooled yellow neon chevrons ("V" of two arms) on the ground, raycast-snapped, flowing from the player to the target, fading near it, hidden within 8 studs; reduced motion = static | one PreRender loop + one BulkMoveTo / frame while a target exists |
| `TutorialHighlight` + `TutorialFocusLogic` | owner R84: rings the exact control the step needs (billboard UPGRADE pill / make bar, touch TAP! / UPGRADE button, pad price button) with a pulsing yellow ring + halo, hands the HUD that GuiObject as the arrow target + a device-glyph callout badge, leads the chevrons to the billboard spot; pure mapping in `TutorialFocusLogic` (see §4c) | rings pulse on the shared OfferFx driver; no own per-frame work |
| `PlotReveal` | owner R13 / R16: on PlotIndex = N and only after the join loading screen (`LoadingDone`, UI/Widgets/LoadingGate), "Your plot is #N!" banner + camera swoop to the plot (length = server PlotRevealSeconds; WorldLayout frame, stream-around), hold, camera back, then `PlotRevealDone()`; skip A / Space / Enter / click / tap; reduced motion = instant cut | one tween per reveal |
| `StandSign` | ProximityPrompt "Rename" (R / D-pad up / tap) on the StandRename sign build once owned → RenameStand screen | event-driven |
| `PlotSign` | Owner R88 (started by StandSign): click / tap the own entrance sign (ClickDetector + hover outline) or walk-up ProximityPrompt "Name your plot" (E / X / tap, 0.3 s hold) → RenameStand in plot mode (`docs/plots.md`) | event-driven (tag + ownership + profile + modal signals) |
| `BuildIn/KnockdownFx` | owner R50: any `KnockdownTarget` (plot `AreaNN` / Rival Factory section) whose `KnockedUntil` is in the future: its `Builds` pieces tumble away from `KnockCenter` like toy bricks (confetti puff, low clack "bonks") and lie scattered (local CFrames + collisions off). Managers are dazed (`ManagerController.setAreaDazed`) and spinning pieces frozen (`WorldFxController.setSuspended`). At the deadline `BuildInController.rebuild` flies every piece back off its rubble; purchases made meanwhile build in afterwards. Reduce Motion = fade down / up | one RenderStepped only while something is down / tumbling; one BulkMoveTo per frame; tier caps (50 / 120 / 220 pieces, 160 / 220 / 300 studs) |
| `UI/Screens/Knockdown/KnockdownHudScreen` | owner R50: red stud chip "Your LAB got knocked down! / Rebuilding 0:45" + progress bar + [TAP TO REBUILD!] (H / LT / tap, ≥ 44 pt), stacked above the AttackHud chips; `KnockdownState` in, `KnockdownTap(area)` out (client-throttled to 6 / s) | 4 Hz countdown while visible |

### 3a. Producer billboard placement (owner R31 / R32, lead QA)

`Tycoon/BillboardPlacement` (pure, lune-tested) decides where each producer billboard goes:

1. **Input from config, not streamed parts** (`areaInput`): the layout's producer click box, the
   area manager's work region (`managerRegion`: work waypoints + head height,
   `ManagerNpcConfig`), and every visible `MeshAssets` piece of the FULLY BUILT plot as bounding
   boxes (managers excluded). Slot-local, so one answer serves all 8 plots; deterministic, never
   jumps when a build lands.
2. **Viewpoints**: a player 5 / 12 studs in front of the producer's front face (scaled up for
   producers wider / taller than 16 studs) and ±5 sideways, Roblox's default camera (12 back, 8 up);
   boxes around a player's head at a stand or on the walk in from the entrance camera are ignored
   (the room they stand in, the garage door / entry arch they walk through: piece bounding boxes
   include those openings).
3. **Hard rules**: from every viewpoint the board's on-screen rectangle (+0.5 stud margin) never
   overlaps the click box's or the manager region's silhouette; the board (largest size any
   viewpoint shows) never intersects geometry in ANY orientation the camera-facing board takes
   (front-facing and facing every viewpoint's camera, pitch included: owner R119, the Silo Launch
   board used to swing into its gantry from the side stands); readable (`readableFrom`): top ≤ 13°
   above the horizon from the far stand, ≤ 24° from the near one, within 46° / 51° sideways, and
   (owner R117) the board centre at most `MaxCentre` (10) studs above the producer's floor.
   Other systems' props (AA tower slots, Mega Lever, Tip Jar: `Tycoon/BillboardProps`; the Order
   Window left with owner R128 and `BillboardSpots` was regenerated,
   read from their own configs) are obstacles too, with a soft cost for spots within 10 studs.
4. **Preference**: right above the producer when that is clear + readable (never for producers
   taller than `TallBody` = 9 studs: rockets, silos, towers go beside at eye height, owner R117),
   else beside it at eye height (either side, stepped toward the players); sight lines to the board's centre + corners
   that hit geometry are a tie-breaker.
5. **Size** (`heightAt`, every RefreshHz tick): 6.4 studs (×1.15 on devices) clamped to 12–28 %
   (16–34 % devices) of the viewport height, so it shrinks with distance but never balloons up close.

The solved spots ship as `Shared/Config/BillboardSpots` (generated:
`lune run tools/billboards/generate-spots.luau`); `ProducerBillboards.place` maps them through
the plot's slot frame (runtime solve only for an area missing from the table; producers without a
slot fall back to a solve around the live click box). `tests/billboard-clearance.luau` audits every
area × desktop / device (solver result + an independent ray-sampled coverage re-check) and fails
when the table is stale. Income pops start outside the board's current width on its outer side
(`placePop`, re-anchored whenever the board resizes). Studio before/after captures:
`STUDIO_LOCK_OWNER=<you> python3 tools/qa/billboard_check.py` → `docs/verification/billboards/`.

**Knockdown plate (owner R50).** While the producer's area model (`AreaNN`, `KnockdownConfig.Attr`)
has `KnockedUntil` in the future, a red stud plate covers the bar: "KNOCKED DOWN 0:45", then
"REBUILDING!" for the last `Billboard.RebuildingBelow` seconds (read at RefreshHz, text written once
a second). While the anchor has `PausedAt`, the bar freezes where the payout loop paused it and the
CLICK bar is hidden. Everyone sees the plate (other players' boards too).

**Income pops** skip the pooled-gui work when the pop would be invisible (off screen or past
`Pops.MaxDistance`); CurrencyFly still decides on its own.

Tunables: `src/shared/Config/TycoonClientConfig.luau` (billboard sizes / distances / refresh,
pad kind colours, interaction ranges, pops, YOU marker, beam, rename length, `TeleportNeedsPass`).

### 3b. Worlds (owner R57, W10 + W10b): one tycoon client for every world

Nuke Town is unchanged; Dino Valley (and any later world) runs through the same modules.

* **Discovery** — `Tycoon/PlotFolders` finds every plots folder once (`Workspace.Plots` = main,
  `Workspace.Worlds.<id>.Plots` = a registered world; ChildAdded hooks, no polling) and hands each
  to `TycoonWorld`, `Npc/ManagerController` and `Fx/VehicleRoutes`. `TycoonWorld.myPlot(worldId)` /
  `MyWorldPlotChanged(worldId, plot)` cover every world; `myPlot()` / `MyPlotChanged` stay Nuke
  Town's (Tutorial, StandSign, PlotReveal are Nuke Town only). `worldOf(instance)` = the plot's
  `WorldId` attribute (validated), else its folder's world.
* **Ids → world** — `Tycoon/WorldLookup`: ids are globally unique + prefixed, so `pad(id)` /
  `producer(id)` return `(worldId, config)`; `logic(worldId)` (that world's TycoonLogic),
  `tycoon(worldId)` (state snapshot), `wallet(worldId)` (Cash / Bones), `currencyOf(id)`,
  `format(worldId, n)` ("$1.2K" / "1.2K"), `label(worldId, n)` ("$1.2K" / "1.2K Bones" for text
  that cannot hold an icon), `usesIcon`, `layout(worldId, area)` (WorldDef.layoutFolder, cached),
  `current()` (Player attribute `CurrentWorld`).
* **ProducerBillboards** — each record has `worldId` (from the producer id); config, levels, costs,
  affordability and the wallet are that world's; Dino amounts / upgrade costs show the bone icon
  (`UI/Kit/StudUI.icon`, square via an aspect constraint) and the Bones colour; slot frames are
  `WorldLayout.slotOrigin(plot, area, worldId)`; spots come from `BillboardSpots.worlds[worldId]`
  (runtime solve with that world's `sourcesOf(worldId)` only when missing; round producers from
  `Placement.WorldRoundBodies`). A plot changing hands rebuilds only that world's billboards.
* **PadBillboards / IncomePops** — price / pop in the pad's / producer's currency; icon worlds use
  `Tycoon/CurrencyText` (a centred `[icon][text]` pair: the label width is a scale computed once per
  text from per-glyph advance widths measured once per font with `TextService:GetTextBoundsAsync`,
  so it stays centred at any distance with zero per-frame work). Pads repaint on `cash` /
  `worldCash` profile changes. Pops pass the currency key to `CurrencyFly.fromProducer(..., kind)`
  (W5: bones fly into the Bones counter).
* **Interaction** — the hint bar reads "Buy 1.2K Bones" next to a Dino pad; own click boxes are
  re-derived when the plot in ANY world changes.
* **YouMarker** — floats over the player's plot in the world they are in (`CurrentWorld`).
* **Billboards offline** — `lune run tools/billboards/generate-spots.luau [--world dino]` writes main
  (unchanged) + `worlds.dino`; `tests/billboard-clearance.luau` audits every world's areas ×
  desktop / device (labels `dino:D3`) plus every Dino pad board (the finale `d6_golden_trex` board
  never touches a piece and every path / road sight line to it is clear). Dino spots (2026-10-31,
  after W6 split D2_Grove's banana stems out of the trunk pieces): D1 above 12.2° / 14.1°, D2 side
  8.5° / 5.2°, D3 side 6.9° / above 7.5°, D4 side 8.1° / above 7.7°, D5 side 7.0° / 7.2°, D6 side
  4.5° / 5.2° (desktop / device), all clear + readable.
* **Nuke Town only** — KnockdownFx ignores targets inside a non-main plot (spec §7: Dino is never
  knocked down); routed vehicles bind only to routes of their plot's world (main routes never run
  in Dino plots, the D3 couriers never in Nuke Town).
* **Studio verification (W10b, 2026-10-31, solo playtest, High tier)** —
  `STUDIO_LOCK_OWNER=<you> python3 tools/qa/dino_client_check.py [--shots | --resume]` (server half
  reuses `tools/qa/world2_check.luau`; the test profile is restored at the end). Fully built Dino
  plot: WorldFx 87 tagged pieces / 59 groups / 20 moving; 6 Dino managers registered (4 animating);
  2 courier routes active (16 pieces, wings flapping); KnockdownFx 0 targets; YOU marker on the Dino
  plot; all six producer billboards show the bone icon twice (amount + cost, e.g. "Ptero Express
  182K", cost "34K"). Motion probe over 0.6 s: Ears 25.6°, Sock + SockStripes 13–24° together,
  Column + ColumnFoam together (0.3–0.5 studs), water wheel + trim 24.6° (≈ 40°/s), turbines 74°
  (≈ 120°/s), Wobble eggs + spots together, LavaFlow 1 belt / LavaFall 2 belts scrolling, every
  Flame lit. Captures `docs/verification/world2/w10b-*.jpg` (+ phone / tablet / console matrix of
  the D2 billboard from the road), contact sheet `w10b-sheet.jpg`, numbers `w10b-check-*.json`.

### 3c. Low gravity + a third world (owner R70 Moon Base, W10b)

* **Gravity** — `Client/Worlds/WorldGravity` (started by `WorldClient.Start`) sets
  `Workspace.Gravity = default × WorldClientConfig.Physics[worldId].gravityScale` while the
  player's `CurrentWorld` is that world (no row = 1; any world may add one — Moon Base 0.4). It
  re-evaluates on every world change, respawn, New Player Mode swap (`NewPlayerMode` attribute)
  and full profile snapshot, always from the default captured at start (never compounds), and
  restores the default when the player object goes away. Client-only on purpose: the player's own
  character is client-simulated, so only their jumps change; the server's value and other
  clients are untouched. Pure maths in `Client/Worlds/GravityLogic` (clamps, broken rows = 1).
* **Landing feedback** (low-gravity worlds only) — one Heartbeat connection exists only while the
  character is falling; on `Landed` faster than `WorldGravityConfig.Landing.MinFallSpeed` (14
  studs/s) it plays `moon_boing` (2D, pitch 0.9 → 1.2 with the fall; skipped silently while the
  key is not in AudioConfig) and emits a lilac moon-dust ring from ONE pooled ParticleEmitter at
  the feet (6–16 particles, halved on the Low tier). Reduce Motion keeps the sound, skips the puff.
* **Jumps vs server checks** — JumpPower 55 at 0.4 g peaks ~19.3 studs (7.7 normally) and hangs
  ~1.4 s. Audited: MovementService has no physics anti-cheat (it only sets WalkSpeed / JumpPower);
  pads / portals are touch volumes (the hub plot pads were removed by owner R134); egg stands and portal prompts are
  ProximityPrompts (the client hides them out of range, the server range is wider); producer
  clicks allow 40 studs vertically. Fixed generically: `TycoonService.PadReachVertical` 10 → 28
  (tap the price while bouncing on a pad; the measured apex is 21.8 studs, the formula's 19.3 + the
  Humanoid take-off), H3's Lucky Button claim allows +26. Boundary rings are 60 studs tall.
  `tests/world-gravity.luau` guards all of it against the lowest gravity any world configures
  (apex × 1.15 + 3).
* **Night skies** — a lighting preset may carry `Sky` (six skybox faces, StarCount,
  CelestialBodiesShown, SunAngularSize; `WorldClientLogic.validateSky`): `WorldClient` parks the
  place's own Sky (Parent = nil) and shows a client-only `WorldSky`, restored on the way out.
* **Three worlds, no special cases** — `WorldClientLogic.portal(worldId)` (WorldClientConfig.Portals:
  model / icon / pets word, field-by-field fallback to `Unlock.ModelKey` / `ModelIcon`) drives the
  WORLD UNLOCKED turntable + header icon (`StudUI` windows gained `setIcon`) and the travel-failure
  toast icon; locked previews (popup + Teleport) measure progress in the unlock rule's own world;
  `WorldTabBar` shares the row evenly when `TabMinWidth` tabs do not fit (3 tabs in the 908 px
  Teleport body); bad-args defaults and the popup debug state no longer name "dino"; Welcome
  Back's two-column mode (3+ worlds) names each row by its short tab label ("TOWN" / "DINO" /
  "MOON") instead of a cut-off full name; the Rebirth link well grows one pair of lines per world
  (the pane scrolls).
* **Studio (W10b, 2026-10-31, solo)** — `world2_check.py tour --world moon` (unlock popup with the
  rocket + "space pets" on every device, Base Camp, Teleport with 3 tabs + balances, build-in,
  finale, rebirth, portal home: `docs/verification/moon/`, `tour-sheet.jpg`) and
  `dino_client_check.py --world moon`: Workspace.Gravity 78.48 (0.4 × 196.2) in Moon Base, jump
  apex 21.8 studs / air time 1.47 s, one landing with feedback (`WorldGravity.stats().puffs` = 1;
  the emitter's render proven by `--dust`: `w10b-dust-test.jpg`); 6 Moon managers, 3 routed groups
  (UFO couriers + ore carts), WorldFx 288 groups, every producer billboard with two Moon Rocks
  icons; Rebirth tab + Welcome Back rows on phone / tablet / console (`w10b-*`; Welcome Back's
  two-column rows are [currency icon][amount] — names were cut to "Nuk" / "TOW" on a phone).

## 4. Screens (`UI/Screens/<Name>/init.luau`, StudUI.modalScreen)

- **Teleport** (ref 16): Hub + one row per own area, always FREE; unlocked → GO (`TeleportArea` /
  `TeleportHub`), locked → lock + "x / y purchases" bar of the previous area. "Players' Plots"
  section = the Teleporter pass perk: with the pass one GO row per other occupied plot
  (`TeleportPlot(plotIndex)`, SOON until the server publishes the remote); without it a locked
  row with the Robux button (`PromptPass("Teleporter", "teleport")`).
- **Rebirth**: preview card (rebirth #, cash bonus xA → xB, +tokens, what resets) with a two-press
  REBIRTH (locked "FINISH AREA 10" until `TycoonLogic.canRebirth`), and the Rebirth shop rows
  (level / max, token price, MAX, dimmed when unaffordable).
- **RenameStand** (ref 10): text box (trim, ≤ 24 chars, valid UTF-8) + CANCEL / CONFIRM; the
  server filters with TextService.
- **TycoonTutorial** (R78: NON-modal coach card): "HOW TO PLAY" strip under the currency stack
  with three tiles in the order the tutorial runs (walk onto glowing pads → make nukes with the
  device's control → upgrade & hire managers); never selectable, never pauses the character,
  leaves 3 s after the first move / 14 s max / when step 1 ends. It used to be a blocking modal
  whose step 1 said "Click the Workbench" before the Workbench existed.

## 4b. Join order (owner R16)

Loading screen (B15, `ReplicatedFirst.LoadingScreen`) → player attribute `LoadingDone` → the HUD
fades in (UIController focus reason "Loading") → plot reveal → the join pop-up queue
(`Platform/JoinFlow`, R78 §6; one item at a time with a 1.5 s calm gap): Welcome Back (returning
players; it used to open UNDER the loading screen so the reveal swooped behind it) → tutorial
coach card (step 1) → What's New / notify prompt (never during the guided steps 1–3).
Objective lines are device-aware (`Tycoon/TutorialText`): "Press RT at your Workbench to make
nukes!" (gamepad), "Tap TAP! ..." (touch), "Press F or click your Workbench ..." (KB/M); the
upgrade step reads "Press X to UPGRADE your Workbench!" / "Tap UPGRADE on your Workbench!" /
"Press E or click UPGRADE on your Workbench!" (owner R84: the line names the highlighted control).
First-minute analytics: `Tycoon/FtueTracker` (docs/analytics.md, R78 steps).
`UI/Widgets/LoadingGate` opens at once in a build without the loading screen and after
`HudFocusConfig.LoadingTimeoutSeconds` (45 s) if it never reports.

## 4c. Tutorial focus: point at the button, highlight it (owner R84)

Owner: "it doesn't actually point to the GUI. It kind of points towards the bench ... it wasn't
very clear to me that X is what you were supposed to do to upgrade first." The HUD arrow used to
float 9 studs over the target MODEL; it now points at the CONTROL to press.

| Step kind | Device | Arrow points at | Ringed | Callout glyph |
|-----------|--------|-----------------|--------|---------------|
| upgrade | all | billboard UPGRADE pill (`record.upgrade`), arrow under the board first | the pill (+ touch UPGRADE button on Touch, never while a pad is in reach: Interact would BUY) | X / Square, E + cursor, tap hand |
| click | Touch, TAP! shown | the TAP! touch button, arrow from above first | TAP! + billboard make bar | tap hand |
| click | otherwise | billboard make bar (`record.well`, the CLICK bar), arrow from the side first | the make bar | RT / R2, F + cursor, tap hand |
| pad | all | the pad itself (you walk onto it) | the pad label's price button | none (the line says "walk") |

- Flow: `Tutorial.render` → `TutorialHighlight.show(kind, targetId, mode)` → `{ pointer, trail,
  callout }` → `HudObjective.setCallout(callout)` + `Hud.setObjective(text, pointer or part)` +
  `TutorialArrows.setTarget(trail or part)`. No board streamed in yet → the old behaviour (arrow
  over the part, nothing ringed).
- `UI/Hud/HudObjective`: a GuiObject target on a BillboardGui is projected (board centre + stud
  size at its depth; control fractions from AbsolutePosition / AbsoluteSize); `UI/Hud/PointerLogic`
  places the arrow beside it, outside the WHOLE board, clear of the HUD zones and other touch
  buttons, sticky side, badge behind the tail, bob away from the button (Reduce Motion: still).
  Board not drawn (MaxDistance, disabled, behind the camera) → point at its world spot; control off
  screen → edge arrow. ScreenGui targets (touch buttons) use their AbsolutePosition.
- Re-targeting is event-driven: `ProducerBillboards.Changed(producerId)` (board built / destroyed),
  `TouchButtons.Changed` (button set / caption changed) → `TutorialHighlight.Changed` (deferred,
  coalesced) → re-render. Rings are children of the control (die with it) and are removed by the
  render that follows the step completing.
- Accessors added (additive): `TouchButtons.button(action)`, `TouchButtons.Changed`,
  `PadBillboards.priceButton(padId)`, `ProducerBillboards.Changed`, `Record.well`. Producer + pad
  billboards set `ClipsDescendants = false` so the ring may reach past the board edge.
- Tunables: `TycoonClientConfig.TutorialHighlight` (ring colour, pad / thickness fractions, pulse
  speed, per-tier Hz: Low keeps 15 Hz because this is guidance) and `.TutorialPointer` (gap, bob,
  badge glyph size). Tests: `tests/ftue-logic.luau` §8 (mapping + words-vs-glyph agreement) and §9
  (pointer never overlaps the button or its board over a screen grid).

## 4d. Gem upgrade button (owner R86)

Every own producer billboard's bottom row is `[x1] [ UPGRADE ] [gem 75]` (UPGRADE narrowed to
0.46 of the board; the [E]/(X) and [C]/(LB) key glyphs sit on the buttons' top-right corners).
`Tycoon/GemUpgrade` paints the gem button through `ProducerBillboards.paintGem`:

| State | Look |
|-------|------|
| can buy | purple stud face, gem icon + "75" |
| armed (first press) | yellow, "SURE?" for 3 s |
| short of gems | grey, "NEED 75" (press = locked sound, nothing sent) |
| MaxLevel / switched off (admin) / not built | hidden |

Confirm (pure `Tycoon/GemConfirmLogic`, exact): the first press arms that producer; a second press
on the same producer within `ConfirmSeconds` (3 s) buys ONE level and disarms; after a gem buy,
presses on ANY producer within `RepeatSeconds` (6 s) of the last buy go straight through (each buy
restarts the window); an arm not confirmed expires by itself; pressing another producer moves the
arm. Inputs: the billboard button (touch / mouse), the `GemUpgrade` action (C, LB, the GEMS touch
button, 60 pt) on the nearest own producer in reach; the hint bar / touch caption read "Gem upgrade
(75)", "Sure? 75 gems" or "Need 75 gems" and only show while that producer can take a gem level.
The client sends `ProducerGemUpgrade(producerId)` only; the server prices and checks everything.
The live price / switch arrive as ReplicatedStorage attributes `GemUpgradePrice` /
`GemUpgradeEnabled` (sanitised by `Shared/Tycoon/GemUpgradeRules`). Event-driven repaints (profile
gems / levels, the attributes, boards streaming in). Tests: `tests/gem-upgrade.luau`.

## 5. Console + mobile first (owner R11)

All bindings live in B16's action map (`PlatformConfig.Actions`, re-exported by `InputConfig`);
`Platform/ActionMap` binds them with ContextActionService + touch buttons and fires them through
`InputController.pressAction / releaseAction` (InputController stays the single source of input
MODE). Billboard buttons are tappable (BillboardGuis in PlayerGui, `Active`) and 1.3× larger on
phones / tablets / ten-foot consoles; pads buy by stepping on them, tapping the price, E / X or A;
producers by tapping the 3D model, the CLICK bar, F or R2. Every screen has a default gamepad
selection and closes with B / X / the red X. TV-safe margins: `ScreenManager.setSafeInsets`.

## 6. Next steps / open items

- Server `TutorialLogic` (B5) decides the real step list; the client renders `text` / `padId` /
  `producerId` from the payload when present, else `TutorialSteps` (the same 7 steps as the server,
  owner R122; 0 / past end = done).
- `TeleportNeedsPass` (false) mirrors the server rule for OWN-plot teleports.
  `TeleportPlot(plotIndex)` (server hooked by name; B17 declares the remote): own plot free,
  other owned plots need the Teleporter pass (server Notify otherwise), 5 s cooldown; the
  client's GO buttons enable themselves once the remote exists.
- Tutorial steps (server texts): 1 pad a1_workbench, 2 click p1_workbench, 3 upgrade to Lv 2,
  4 pad a1_tool_wall, 5 pad a1_glow_lamp, 6 pad a1_uncle_atom (owner R122: Uncle Atom is pad 4, the
  line is "Hire Uncle Atom - he makes nukes for you, even offline!"), 7 next pad until a1_open_stand
  (7 resends the live padId after every purchase); `{ step = 0, done = true }`.
- Reveal waits for `Plot<N>.PlotReady` (max 6 s) and always sends `PlotRevealDone()` (server
  fallback 60 s after assignment).
