# Animated manager NPCs (owner R30)

> "I do want like the little NPCs that you hire to like automate things like this Uncle [Atom] guy.
> To actually like move around and be animated and not just a still prop."

Every Manager (Uncle Atom, Cashier Bot, Dispatcher, Foreman, Head Scientist, Factory Boss, Launch
Director, Store Manager, Flight Director, Chief Engineer) is a living NPC, animated entirely on the
client. The server still spawns the plain mesh model and its collision box, so nothing about
purchases, collision, replication or security changes.

| What | How |
|---|---|
| Idle | breathing lift + nod, slow sway, arms relax with the breath |
| Work loop | 2-4 waypoints per manager (`ManagerNpcConfig.Rigs[key].waypoints`), walking with leg + arm swing, step bounce, forward lean; turns in place when the heading is > 60° off, eases in / out of every stop |
| Work action | at the `work` stop: Tap / Hammer / Press, one per producer cycle (anchor `CycleStart` / `CycleTime`, `Automated`), never faster than `MinBeatInterval`; unsynced 1.8 s cadence if the producer is unknown. The hit plays `clack` + a 3-sparkle burst (nearest manager only, Mid / High tiers) |
| Owner | when the plot owner arrives within 14 studs the manager stops, turns to them and waves (once per arrival, 12 s cooldown); the head follows them within 22 studs |
| Purchases | `BuildInController.BuildFinished` on the same plot: every animated manager there does a staggered happy hop (+ soft `pop`); a fresh hire waits for its own LEGO build-in, then hops |
| Reduced motion | Roblox setting or `profile.settings.reducedMotion`: managers stand at home, breathing only (no walk / wave / hop / work) |

Verification captures (Studio solo playtest, Plot 7): `docs/verification/managers/uncle-atom-walk.jpg`
(mid-stride), `uncle-atom-work.jpg` (hammer at the bench), `uncle-atom-wave.jpg` (turned to the
player, waving), `uncle-atom-toolwall.jpg` (tool-wall stop). A simulated purchase lifted him 1.28
studs (HopHeight 1.3).

## Files

```
src/shared/Config/ManagerNpcConfig.luau   ManagerKeys, ownsModel(), groupOf(), tiers, Motion, Fx, Rigs (per manager)
src/client/Tycoon/Npc/ManagerController   discovery, rest capture, culling, CFrames, sound, sparkle (Init/Start)
src/client/Tycoon/Npc/NpcBrain            pure state machine: Idle / Walk / Work / Wave + hop / action overlays
src/client/Tycoon/Npc/NpcPose             pure pose maths: brain -> root + joint angles
tools/blender/models/_npc_rig.py          rig_split(): splits a figure into <Group><Colour> pieces + prints joints
tests/npc-logic.luau                      lune: keys, rigs vs MeshAssets, brain over 2 min per manager, pose
src/shared/Config/ManagerTagConfig.luau   R87 nametags: per-manager rows (pool / canon), name pools, lines, sizes
src/client/Tycoon/Npc/ManagerTags         R87 tag + bubble billboards: build, pool, style, place, pop
src/client/Tycoon/Npc/ManagerTagLogic     R87 pure: describe(), pickName(), bubble scheduler, overlaps()
tests/manager-tags.luau                   lune: coverage vs pads, pools, lines, names per owner, scheduler, readability
tools/qa/manager_tags.py (+ _client/_server.luau)  Studio captures -> docs/verification/r87-manager-tags/
```

Boot: `"Tycoon/Npc/ManagerController"` in `src/client/init.client.luau`, after
`Tycoon/Fx/WorldFxController` (it subscribes to `BuildInController.BuildFinished`).

## The rig (Blender → Roblox)

A MeshPart has one colour, so builders group geometry by colour (`Coat` = torso + both sleeves).
`rig_split(m, bones, static=, assign=, frame=)` runs at the end of each manager builder and
re-partitions the finished model: every connected island of every piece goes to the nearest bone
(distance to the bone segment minus the bone's radius), and each (bone, colour) pair becomes a piece
named `<Group><Colour>`:

| Group | Pivot (joint) | Rides on |
|---|---|---|
| `Torso` | hip centre | root |
| `Head` | neck | Torso |
| `ArmL` / `ArmR` | shoulder (L = the figure's own left, local -X) | Torso |
| `LegL` / `LegR` | hip socket | root |

Islands far from every bone, and pieces passed as `static`, keep their original name and stay
props (desks, podiums, consoles, decks in the same model). `assign` forces a held prop
(clipboard, megaphone, headset, pocket nuke) into one group, so it moves with its hand as one
assembly (owner R25). Helpers: `a1_bones(anchors)` for area01's `toy_figure`, `a4_bones(xf, l, r)`
for area04's Xf figure; robots write their bones inline (Hover robots have no legs). Arms that were
authored raised in a wave are now relaxed — the client raises them. The builder prints the joints;
they are pasted into `ManagerNpcConfig.Rigs[key].joints` (`tests/npc-logic` checks each joint lies
inside its group's piece bounds).

Rebuild one manager: `/opt/homebrew/bin/blender -b --python tools/blender/generate_world.py -- --only <Key>`,
`python3 tools/blender/upload_meshes.py --user-id 1586034782 --only <Key>`,
`python3 tools/blender/sync_meshes.py`. Every manager stays <= 24 pieces.

| Manager | Style | Pieces | Work |
|---|---|---|---|
| A1_UncleAtom | Biped | 21 | Hammer at the bench (left hand; nuke in the right) |
| A2_CashierBot | Hover | 16 | Tap at the register |
| A3_Dispatcher | Biped | 24 | Tap at the desk / pickup window |
| A4_Foreman | Biped | 16 | Tap facing the drill (clipboard in the right hand) |
| A5_HeadScientist | Biped | 21 | Tap on the podium |
| A6_FactoryBoss | Biped | 20 | Tap (megaphone) at the deck rail facing the line |
| A7_LaunchDirector | Biped | 21 | Hammer-chop "go!" toward the silo |
| A8_StoreManager | Hover | 16 | Tap at the checkout |
| A9_FlightDirector | Biped | 20 | Press at the console |
| A10_ChiefEngineer | Biped | 23 | Tap at the drafting table |

## Runtime (ManagerController)

Per frame, for each animated piece:
`piece.CFrame = modelPivot * root(x, y, z, yaw) * group(joint rotation) * rest`, where `rest` is the
piece's offset from the figure root captured once from its server CFrame (so the FBX import yaw,
MeshPlacement rule 1, is already baked in). One `BulkMoveTo` per frame.

* **Discovery:** `Workspace.Plots.DescendantAdded`, Models whose name passes `ownsModel` (spawned mesh
  models are `<key>_<n>`) and whose `MeshKey` is a rig; deferred one frame (Atomic models finish
  replicating). `AncestryChanged` unregisters streamed-out / cleared models.
* **Producer link:** `TycoonWorld.ProducerAdded` anchors cached per (plot, area); cycle attributes
  refreshed on `AttributeChanged` only.
* **Budgets (FxQuality):** Low 3 managers / 70 studs, Mid 6 / 110, High 10 / 160; managers beyond
  30 / 50 / 80 studs update every other frame. Re-ranked every 0.25 s; leaving the set settles the
  manager into its rest pose once (zero cost afterwards). Heartbeat connected only while a manager
  exists. No per-frame Instance.new, tables or closures.
* **WorldFx:** `ManagerNpcConfig.ownsModel` lets WorldFxController skip manager models (W1). Rig arm
  pieces otherwise match WorldFx's leading-word rule ("ArmLCoat" -> "Arm").

## Tuning

All numbers are in `ManagerNpcConfig.Motion` / `.Fx` / `.Tiers`. To move a manager's loop, edit its
`waypoints` (model space; 1 = home = `figure.base`, all on the figure's floor, <= 8 studs from home,
one `work = true`); `face` is a model-space yaw (0 = model front -Z, 90 = -X, -90 = +X, 180 = +Z) or
`"producer"`. `tests/npc-logic` enforces these rules.

## Next steps

* Admin panel: a "freeze managers" toggle + per-manager state readout (`ManagerController.stats()` /
  `debugBrain(key)` already exist).
* Analytics: nothing to report today (purely visual); if a "tap a manager" interaction is added,
  record it through ClientAnalytics.

## W10 worlds (R57)

Dino Valley (owner R57, spec §7) reuses the R30 manager system unchanged — no fork.

* **Config** (`Shared/Config/ManagerNpcConfig`): `ManagerKeys` stays Nuke Town's ten keys (index =
  area; tests/build-in-plan and the billboard solver rely on that). `WorldManagerKeys[worldId]`
  lists every world's keys by area (`main` IS `ManagerKeys`; `dino` = `D1_RockyRaptor`,
  `D2_StegoSally`, `D3_CaptainPtera`, `D4_ParaPete`, `D5_DrTrike`, `D6_ChiefTyra`);
  `managerKeysOf(worldId)` reads it (empty for an unknown world). `ownsModel` covers every world,
  so WorldFx never tags the Dino managers' `ArmL*` / `ArmR*` pieces with the generic `Arm` row and
  KnockdownFx / ManagerController recognise them. Rig rows gain an optional `world` (nil = main;
  `"dino"` for the six). Build keys are globally unique, so `Rigs[key]` needs no world.
* **Rigs**: all six are W6's shared `dino_biped` body (joints = `dino_bones`, confirmed against each
  build's `[npc_rig]` print; figure at the model origin, yaw 0, feet at y 0). Waypoints are model
  space, authored against `Worlds/Dino/Layouts/AreaNN`:

  | Manager | Work stop | Action (arm) | Other stops |
  |---|---|---|---|
  | D1 Rocky Raptor | behind the stone bench, faces the producer | Hammer (ArmR, chisel) | cave mouth peek, bone-tool rack |
  | D2 Stego Sally | coconut till, behind the counter | Tap (ArmR) | -X end of the counter |
  | D3 Captain Ptera | sorts parcels facing the Nest Tower | Tap (ArmR, parcel) | watches the landing pad, the walkway |
  | D4 Para Pete | -X end of the pressure valves (side-on to the road) | Hammer (ArmR, bone wrench) | turns to the geyser vent, the walkway |
  | D5 Dr. Trike | specimen desk (magnifier over the jar) | Tap (ArmR, magnifier) | looks at the Lab Hut, the microscope |
  | D6 Chief Tyra | control podium | Press (both arms on the clipboard) | watches the volcano |

  Managers that stand away from their producer (D3–D6) work at their own station; the
  `"producer"` stop turns them toward the producer they run (live anchor).
* **Controller** (`Tycoon/Npc/ManagerController`): discovery runs on every world's plots folder
  through `Tycoon/PlotFolders.watch` (Workspace.Plots + Workspace.Worlds.<id>.Plots). Everything
  else was already world-agnostic: a manager animates from its own model pivot, its producer is
  the anchor of the same plot Model + area (each world's plots are distinct Models), the owner is
  that plot's `OwnerUserId`. Records carry `worldId` (`TycoonWorld.worldOf`); `stats()` adds
  `worlds = { [worldId] = count }` for Studio verification. Knockdown dazing stays Nuke Town only.
* **Billboard solver** (done, W10b): a Dino area's `BillboardPlacement` sources carry
  `managerKeys = ManagerNpcConfig.managerKeysOf("dino")` (index = area) and `rigs =
  ManagerNpcConfig.Rigs` (offline: `tests/fixtures/BillboardSources.load(loader, "dino")`; runtime:
  `ProducerBillboards.sourcesOf("dino")`), so every Dino manager's work region is protected.
* **Hop voice (W10b, sparse)**: `ManagerNpcConfig.Fx.WorldHopVoice[world]` replaces the hop "pop"
  with that world's voice — Dino: `dino_happy_roar` (volume 0.5), at most once per 4 s per client,
  Mid / High tiers only, within `SoundRange` and the one-sound-per-frame budget; the hops in between
  keep the pop. Keyed by the rig's `world`, so Nuke Town is unchanged.
* **Tests — every world (W10b, for owner R70 Moon)**: `tests/npc-logic.luau` iterates
  `WorldManagerKeys` (no test edit per new world). A listed key may lack a rig only while its model
  has no MeshAssets art (worlds land in waves; the pending keys are printed), a rig's `world` must be
  its list's world, the Areas/AreaNN Manager pad build key is cross-checked once that config exists,
  and every rigged non-main manager needs its world's `Layouts/AreaNN` for the §6 loop clearance.
  Dino stays strict (6 rigs, 6 loops).
* **Tests** (`tests/npc-logic.luau` §1 + §6, checks 2–4 now run for every world): Dino keys = the
  Manager pad build keys of `Worlds/Dino/Areas/Area01..06` in area order, `world` fields, one rig
  per key; joints inside their piece bounds (MeshAssets); brain simulation; and every Dino loop
  (stops + walked segments sampled at 1/20) inside its slot, >= 1.3 studs from every layout
  collision box in the figure's height band (own figure / tail boxes aside; tilted boxes use their
  bounding box) and >= 1.35 from the producer click box.

## R87 nametags + speech bubbles

Owner R87: "in sell lemons the managers/automaters all have nametags" (the screenshot was another
game; inspiration only, SellNukes draws its own stud tag).

**What a player sees.** Every hired manager on every plot, in every world, wears a compact tag
over its head:

```
   [ FOREMAN ]        role chip: small coloured stud pill (Nuke Town yellow, Dino green, Moon purple)
  Captain Kaboom      name: big white outlined text (Fredoka One)
  runs Glow Rock Drill    "runs <producer display name>", warm-yellow outlined text
```

Now and then (every 20-40 s per plot, first one 6-12 s after the plot's managers appear) ONE of
the local player's managers says a short line in a white stud speech bubble right above its tag
("Efficiency... yes!", "Nukes for everyone!", "Rawr-some work!", "Beep boop, all good!"). Bubbles
show only while the owner stands within 34 studs of that manager, never while its area is knocked
down, and never on other players' plots (less clutter).

**Name + role rule (decided for R87).** The data already names most managers, so the tag follows
the pad the kid bought:

| Managers | Chip | Name |
|---|---|---|
| Nuke Town job-title hires (A2-A10: Cashier Bot, Dispatcher, Foreman, Head Scientist, Factory Boss, Launch Director, Store Manager, Flight Director, Chief Engineer) | the pad's job title ("FOREMAN") | picked from a kid-safe pool: `crew` (24 science / nuke-toy puns) or `robot` (12, for the two hover robots A2 + A8) |
| Uncle Atom, all Dino Valley + Moon Base managers (pads name the character: "Rocky Raptor", "Bleep Bot") | `MANAGER` | the pad's canon name |

Pooled names are deterministic per plot OWNER + producer: `ManagerTagLogic.pickName` shuffles the
pool with a Park-Miller generator seeded by FNV-1a of `"<OwnerUserId>|<world>|<pool>"` and takes
the manager's ordinal among its world's managers using that pool. So a player's Foreman keeps the
same name across rejoins, servers and plot slots (stronger than "per plot"), and no two managers
of one plot share a name (the pools are larger than their users; tests prove it for 500 owners).
"runs" reads the pad's `target` producer name from the world's economy config
(`WorldLookup.def(world).economy.BuildKeys -> PadsById -> ProducersById`), so it follows renames.

**Placement + clash rule.** The tag is a BillboardGui in PlayerGui ADORNED to the manager's first
head piece (the engine moves it with the animated NPC: zero per-frame writes). Its bottom edge sits
`HeadGap` (0.3) studs above the top of the highest head piece, measured once from the rest pose
(`SizeOffset (0, 0.5)` keeps the bottom edge on that point whatever the pixel floor adds). While
dazed it rises `DazedLift` (1.5) studs, clear of the knockdown stars. The producer billboard's
solver (`BillboardPlacement`, read-only for this work) only keeps the board off the manager's body
plus 0.6 studs of headroom, so a tag right above the head can still meet the board on screen (the
first Studio pass showed it: BoomDash's board sits right beside the Dispatcher). Rule, every
refresh, for each near tag (<= 90 studs): project the un-nudged tag rectangle and its producer
board's (`ProducerBillboards.byAnchor`; the board's studs size at its depth, no AbsoluteSize
reads); if they overlap (6 px margin), `ManagerTagLogic.nudge` returns the smallest SIDEWAYS shift
that clears the board, keeping the side the tag is already on; the controller converts it to studs
at the tag's depth and eases `StudsOffset.X` (camera right) there at `NudgeRate` (only tags whose
target moved by > 0.15 studs ease; snapped with reduced motion). A tag never slides more than 45%
of its own width (the head stays under it); when no shift within that clears the board, the tag
hides (yield) and returns after 3 clear refreshes. The board is the interactive thing, the tag is
decoration, so the tag gives way. A showing bubble rides the same nudge, and a manager only starts
speaking when its bubble rectangle above the nudged tag is clear of the board too.

**Fitted width.** `ManagerTagLogic.widthScale` sizes each tag to its own text (name row vs "runs"
row in row-height units, plus the chip's share; floor 50%), so "Zappy-3 / runs Nuke Stand" is ~60%
as wide as "Uncle Atom / runs Pocket Nuke Workbench": less scene covered, fewer clashes. Tests check
every real tag still renders its name and "runs" line >= 13.5 pt at its fitted width.

**Size + readability (owner R11).** Studs + a pixel floor, x1.15 on phones / tablets / consoles
(`ScreenManager.device.class ~= "Desktop"`, re-applied when it changes): up to 3.8 x 1.1 studs + 150 x
46 px (width fitted, above). At 25 studs on a phone that is ~221 x 67 pt: name row ~24 pt, runs row ~15 pt even for "runs
Pocket Nuke Workbench", chip ~13 pt (tests/manager-tags.luau re-checks the maths). Up close on a
1080p desktop (10 studs) ~440 x 130 px. MaxDistance 85 studs for your managers, 55 for others';
LightInfluence 0, depth-tested like the player title tags (walls and awnings can hide a tag; from
the road the Nuke Stand awning covers the Cashier Bot and most of its tag, just as it covers the
robot). An always-on-top variant for your own nearby managers was tried in Studio QA: those
billboards reported as shown but did not render in any capture, so it was dropped, not shipped
unverified.

**Visibility.** A tag shows when its manager is described (has a Manager pad), its head piece
exists, its LEGO build-in finished (`holdUntil`), it is within range, and it is not yielding.
Streamed-out / cleared models release their tag (and end their bubble) in `unregister`. Settings:
the only "hide others" setting is `hideOtherPets` ("Hide Others' Pets: only show your own pets");
its label is pets-specific, so tags do not reuse it. Other players' tags are already quieter
(shorter range, never a bubble). If the owner wants a toggle, add a `hideOtherTags` profile setting
(ProfileLogic + the Settings screen) and gate `rec.mine == false` tags on it in `updateTags`.

**Performance.** No new RunService connection: tags + bubbles are decided inside the existing
`RefreshInterval` (0.25 s) pass of the single manager Heartbeat: range check per manager, two
`WorldToViewportPoint` calls per near tag, one bubble scheduler per own plot, scratch lists
reused. Billboards are pooled (cap 24 each), acquired when a manager comes in range and released
once it is 1.5x the range behind. The bubble's pop tween is created once per pooled bubble and
skipped with reduced motion. Analytics: nothing to report (cosmetic, client-only, no economy).

**Verify.** `python3 scripts/studio-lock.py acquire M-managers`, then
`STUDIO_LOCK_OWNER=M-managers python3 tools/qa/manager_tags.py` (solo playtest; owns areas 1-5 via
`TycoonAdmin.setArea(6)` only if fewer managers are owned; additive, `_Studio` profile). Captures
land in `docs/verification/r87-manager-tags/`: area 4 and the garage from inside its door
(desktop + phone / tablet / console, a bubble held up by the QA hook
`ManagerController.debugBubbleNow(hold)`), area 2 (the awning case) and area 3 (the board-above /
nudge case) on desktop, area 2 knocked down (lifted tag), the garage manager up close. The runner
refreshes its Studio lock between steps, stops every client device simulation after a matrix and
leaves the edit simulator as it found it. Studio console probes: `ManagerController.stats()` (tags, bubbles) and
`ManagerController.tagStats()`.
