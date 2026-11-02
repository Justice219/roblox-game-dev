# SellNukes pets, eggs, crates & trails (B9)

Design spec §8 (+ §6 screens, §11 monetization, §13 analytics). Every rule is server-side; the
client sends intents only. Template: RoBeasts `PetLogic` / `CrateLogic` / `PetService`.

## Files

| Layer | File | Job |
|-------|------|-----|
| Config | `src/shared/Config/PetConfig.luau` | 7 rarities, 76 pets (57 + 9 World 2 dinos + 9 World 3 space pets + the R78 Golden Nukey; bonus, species mesh, recolour, hover, source, `exclusive`, `how`), slots, inventory cap, follow + server tunables, attribute encode/decode |
| Config | `src/shared/Config/PetIndexConfig.luau` | R78 Pet Index milestones (5 / 10 / 20 / 30 / 45 / 60 / ALL → gems + permanent Index Bonus), pure counting / claimable / bonus helpers shared by server, client and tests |
| Config | `src/shared/Config/EggConfig.luau` | 10 area eggs + Harvest Egg (acorns) + Lucky Egg (held only) + the 2 Dino Valley eggs (Bones, world "dino") + the 2 Moon Base eggs (Moon Rocks, world "moon"): odds (bp), Lucky Eggs boost, pity, prices from each world's area economy, stands (`<world>:` prefixed outside Nuke Town), event window, paid-random currencies, world progress helpers |
| Config | `src/shared/Config/CrateConfig.luau` | Supply / Mega / Golden crates: reward tables (boost / gems / egg / pet / trail), pity, gem price, Robux product, dup gems; the 4 trails |
| Server (pure) | `src/server/Pets/PetLogic.luau` | plan → charge → commit hatch; equip / Equip Best / delete / lock; grants; cash bonus |
| Server (pure) | `src/server/Pets/CrateLogic.luau` | plan → charge → commit open; receipts (held crates); trails |
| Server (pure) | `src/server/Pets/{PetState, RequestMemory, PetGrants}.luau` | profile-field access, request-id idempotency, B7 reward granters |
| Server (pure) | `src/server/Pets/PetIndexLogic.luau` | R78 Index claim rule (idempotent), admin set / clear, reward, status, bonus |
| Server | `src/server/Pets/{EggStands, TrailRenderer, PetSeams}.luau` | hub stand eggs + prompts + range checks; character trails; guarded lazy hooks (analytics, admin, modifiers, rewards, event, hub layout, MeshLibrary) |
| Server | `src/server/Services/{PetService, CrateService}.luau` | remotes, policy, saving, replication, receipts, admin commands |
| Client | `src/client/Pets/{PetController, PetModels, PetViewport, PetFollow, PetRequests, StandClient, PetUI, EggView}.luau` | follower renderer, models, UI viewports, follow math, request ids, stand billboards / signs, per-world egg price / balance / lock text (EggView) |
| Client | `src/client/Pets/{PetAnim, PetEmotes}.luau`, `src/shared/Config/PetAnimConfig.luau` | procedural pet animation (pure pose maths), heart / Zzz emotes, every animation tunable + per-device budgets (owner R44) |
| Screens | `UI/Screens/Pets/{PetsScreen, PetCard, IndexRewards}` | "Pets": inventory / held eggs / Pet Index (+ R78 rewards panel) / trails |
| Screens | `UI/Screens/EggHatch/{EggHatchScreen, HatchRevealScreen, HatchStage, HatchConfetti, HatchFlow}` | "EggHatch" stand window, "HatchReveal" cinematic (one HatchStage per egg slot, pooled confetti), hatch + auto-hatch orchestration |
| Hatch timeline | `src/client/Pets/HatchAnim.luau` + `src/shared/Config/HatchAnimConfig.luau` | pure timeline maths + every tunable of the hatch cinematic (R49); `tests/hatch-anim.luau` |
| Screens | `UI/Screens/CrateShop/CrateShopScreen`, `UI/Screens/CrateOpen/CrateOpenScreen` | "CrateShop" stall, "CrateOpen" reveal |
| Tests | `tests/pets-logic.luau`, `tests/pets-crates.luau`, `tests/pets-policy.luau`, `tests/pets-follow.luau`, `tests/pet-anim.luau`, `tests/pet-models-load.luau`, `tests/pet-index.luau` | 1,500+ checks + the animation sweep (below) |
| Studio QA | `tools/qa/pet_index.py` (+ `pet_index_{server,client}.luau`) | R78 solo-playtest check of the Index rewards + Golden Nukey; captures `docs/verification/r78-pets/` |

Boot: server `FEATURE_SERVICES` … `"PetService", "CrateService"` (after the tycoon services);
client `"Pets/PetController"` (after UIController). Screens are auto-discovered.

## Data (profile, ProfileLogic schema v1 — B1 added the B9 fields)

```lua
pets   = { owned = {[uid] = {id, locked?}}, equipped = {uid}, nextUid,   -- v1
           eggs = {[eggId] = held count}, pity = {[eggId] = hatches}, index = {[petId] = true},
           indexClaimed = {[milestoneId] = true} }                          -- R78 ("5" … "60", "all")
crates = { held = {[crateId] = count}, pity = {[crateId] = opens}, opened }
trails = { owned = {[trailId] = true}, equipped = trailId | "" }
stats.hatched, gems, cash, boosts, event.acorns (spent by the Harvest Egg)
```
Snapshot fields: `pets` (no nextUid), `crates`, `trails`. Ids (pet / egg / crate / trail) are SAVE
DATA — never rename. Ids other configs use: `group_glow_kitty` (B7 group pet = the Builder Beaver
mesh), `starter_atom_pup`, `secret_golden_nuke`, `lucky_atom` (Lucky Duck), `gobble_bomb` (B11),
eggs `lucky_egg` (B7 wheel), `harvest_egg` (B11).

## Pets

* 57 pets, 7 rarities (Common → Secret), built from B8f's 29 Blender species
  (`tools/blender/models/pets.py`): each species once in its own colours (its home egg), others
  recoloured (`colors` = Body / Head / Glow overrides). `hover` = species flying height.
* Cash bonus while equipped: `RarityBase × 1.25^(tier-1)` rounded to a whole % (Common 4 % …
  Secret 100 % at tier 1; tier 10 Secret +745 %). Summed into `Modifiers.petCash`
  (`ModifierSources` provider "pets", invalidated on every equip change) → `(1 + petCash)`.
* Slots: 3 + 2 (`PetSlots` pass) + Rebirth shop `petSlots` (max 2) = 7. Equip Best sorts by
  bonus, rarity, tier, roster order, then oldest uid (server and client agree via
  `PetConfig.better`). Slots shrinking (refund) trims the equipped list on load.
* Inventory: hatches / crate opens stop at 250 (soft cap); reward grants go up to 1,000 (hard cap
  = ProfileLogic MaxPets) so a paid / one-time pet is never lost.
* Delete (bounded lists ≤ 100, locked pets skipped, saved soon) and lock / unlock.
* Client meshes follow B4's `Shared/World/MeshPlacement` rules exactly like MeshLibrary: uploaded
  pieces are **resized to their manifest box** (`clone.Size = piece.size`; the template keeps the
  FBX import size, ~100× too big — fixed 2026-10-30 when the pet meshes were first uploaded),
  placed with `pieceCFrame(…, true)` (undoes the FBX import's 180° yaw) and tagged `MeshYaw`,
  boxes are not rotated, big Neon pieces follow the glow budget; the stand Sign SurfaceGui uses
  `MeshPlacement.face(sign, Front)`.
* Followers: Player attribute `SNPets = "id,id,…"`; every client renders everyone's pets in ONE
  RenderStepped step with ONE `BulkMoveTo` (anchored parts, offsets from `PetModels.rig`),
  formation arcs behind the owner, ground raycast every 6 frames, culling every 0.5 s
  (160 studs, ≤ 40 other pets nearest first, `settings.hideOtherPets`). The smoothed follow
  position is the BASE (ground + hover); every hop / bob / waddle is the animation pose on top
  (see Animation), so the follow smoothing never flattens it.

## Animation (owner R44 — "make sure all of the pets have animations and stuff too")

Every pet of all 29 species (57 pets incl. event / group / secret ones) animates procedurally —
following you, in the inventory / detail viewports and in the hatch / crate reveals. No animation
assets: `PetAnim` (pure, lune-tested) poses the split Blender pieces every frame.

**Rig from piece names** (B8f art contract, `docs/pets-art.md` §1): `Head*` (Head, HeadFace,
HeadEars, HeadHat, HeadHorn, …) rotate together about the neck joint; `Tail*` (Tail, TailTip,
TailB, TailGlow) wag about the tail root; `WingL*` / `WingR*` flap mirrored (narwhal flippers
too); `ClawL*` / `ClawR*` raise / snip / wave (crab); `Orbit*` atom rings spin about +Y; everything
else is the rigid body (`Glow*` pieces also pulse). Joints come from the MeshAssets pivot string
(`joints Head@(x,y,z) …`, scaled with the rarity `ScaleTo`); a group without one gets a joint
from its bounding box (the critter stand-in names its wings `WingL` / `WingR` and its ring
`Orbit` so it animates too). R25: every group moves rigidly — squash compresses the body pieces
about the pivot and moves each limb group with its joint, so heads, hats and faces never part.

**Styles** (derived: claws → Scuttle, hover + wings → Fly, hover → Float, else Walk;
`PetAnimConfig.Species` overrides):

| Style | Species | Motion |
|-------|---------|--------|
| Walk | pup, kitty, fox, raccoon, panda, corgi, pig, moose, rex, unicorn, beaver, mole, hedgehog, gator, newt, duck, Gobble Bomb | stride-synced step bounce, side-to-side waddle, landing squash / mid-step stretch, head bob, forward lean; ducks flap a little |
| Hop | Uranium Bunny, Acorn Squirrel, Golden Nukey | real hops (0.72 studs) with nose-up / nose-down tilt and big squash-stretch |
| Blob | Glow Slime | hops + a constant jelly wobble |
| Fly | Reactor Owl, Fusion Phoenix, Core Dragon | wing flap (faster + wider when moving), body lifts on the downstroke, banks into turns, leans forward |
| Swim | Nuclear Narwhal, Atomic Axolotl | slow body undulation, flipper paddle, tail undulates (narwhal up/down, axolotl side to side) |
| Float | Ion Jelly, Void Cat | bell pulse (squash), lazy drift, tentacle-skirt sway (jelly), little jiggle for the cat |
| Scuttle | Cranberry Crab | sideways rock, claws raised + snipping while moving |

Tail axis overrides: beaver thumps (Pitch), Gobble Bomb fans (Roll), jelly sways (Sway).
All airborne pets also bob around their hover height (`PetConfig.Follow` BobRate / BobHeight).

**Layers** each frame: locomotion (scaled by the smoothed stride blend = speed / 12 studs/s) →
tail wag (faster when moving), orbit spin (100°/s), glow pulse (Transparency +0..0.22, never
brighter — R19) → idle: breathing, looking around (head, or the whole body when there is no
head), random cute actions every 6–14 s (Sit / Spin / Hop for walkers; Swoop / Flip for flyers;
Jiggle for blobs and floaters; Wave for the crab; UI viewports never pick a big hop) → events:

* **Happy** — staggered spin + hop (0.09 s between team members) and a heart burst above each pet
  (`PetEmotes`) when the owner: buys anything (any player's fresh `PlotWatcher.BuildAdded`,
  < 3 s old), equips (new ids in their `SNPets` attribute), hatches (when the reveal closes;
  fallback 1.5 s with no reveal / 12 s max) or completes a Robux purchase (`PurchaseGranted`).
* **Sleepy** — owner AFK ≥ 60 s (no root movement > 0.6 studs per 0.5 s sample; for you also no
  input of any kind): walkers lie down and flatten, flyers sink 40 % of their hover and flap
  slowly, heads droop, tails curl, breathing slows, a looping "Z z z" bubble floats above. Any
  movement / input / purchase wakes the team.

**Detail per device** (`PetAnimConfig.Tiers` via `FxQuality`, decided in the 0.5 s culling pass,
your pets first, then the nearest owners):

| Tier | Full (everything) | Simple (body bob + wings only) | Off (rigid) | Viewports | Hearts / Zzz pools |
|------|-------------------|--------------------------------|-------------|-----------|--------------------|
| Low (phones) | — | ≤ 60 studs (your pets always) | beyond | 6 @ 15 Hz | 4 / 3 |
| Mid | ≤ 55 studs, ≤ 14 pets | ≤ 110 | beyond | 16 @ 30 Hz | 10 / 8 |
| High | ≤ 90 studs, ≤ 28 pets | ≤ 160 | beyond | 20 @ 60 Hz | 16 / 14 |

Reduce Motion: gentle idle only — no hops, spins, flips, look-arounds or idle actions; wings /
tail / bob at 35 % amplitude, rings at 30 % speed; the happy spin becomes a small nod (hearts
still show).

**Performance**: one RenderStepped step for all followers (PetController) and one for all UI
viewports (PetViewport, connected only while something animates); every follower piece still
moves in the single `BulkMoveTo`; no tables / closures / Instances per frame (State, pose
arrays and the `frames` / `shift` maps are reused; CFrame userdata is the only allocation).
Size squash (body shells only: Body, Belly, Band, Spikes, Limbs, Collar, Fins) and glow
Transparency are written only for Full-detail pets and only when the value changed (Size by
> 0.004 scale, glow by one 0.02 step); leaving Full restores them. Emotes are pooled
BillboardGuis (frame-drawn hearts, Fredoka "Z" letters) built on first use up to the tier cap.

**Viewports**: pet viewports run `PetModels.animator` (the same loop, viewport flavour: no big
hops) and pose pieces relative to the model's Root, so turntable spins, a screen's own `PivotTo`
and `ScaleTo` (the rig rescales via `PetAnim.rescaleRig`) all compose. A screen that poses pet
pieces itself calls `view.setAnimate(false)` first (or passes `animate = false`).

**API for other screens** (e.g. the R49 hatch reveal, which owns its ViewportFrame + loop):
`PetModels.animator(model, { reduced?, simple?, seed? }) -> Animator?` with `step(dt)`,
`happy(delay?)`, `setReduced(on)`, `setDetail(detail)`, `rest()`, `Destroy()` (nil when the model
is not a pet). `PetModels.fromKey(key, colors?) -> Model?` builds any MeshAssets key with the same
template cache / Ready signal (egg shards, crack ribbons).

**Template loading** (EH1 hatch QA — a first hatch showed missing shards while the 13 EggShards
pieces loaded one by one): PetModels downloads mesh templates in PARALLEL, at most 8
`CreateMeshPartAsync` calls in flight (rest queued: shown-now `request` before warm-up
`prefetch`, then oldest), one fetch per MeshId ever (shared ids across keys fetched once,
templates cached), one shared load per key (every `request` / `prefetch` / `waitReady` joins it;
`Ready(key)` fires once when its last piece lands; a key that was already cached on first ask is
ready immediately without a Ready event). A failed piece marks its key failed (stand-in look, one
warning; retry allowed after 30 s). API: `PetModels.prefetch(keys) -> queued` (never yields),
`PetModels.waitReady(key, timeout?) -> boolean` (yields on the shared load),
`PetModels.loadStats()`. Tests: `tests/pet-models-load.luau` (real PetModels + MeshAssets, fake
AssetService that parks each download: bounded concurrency, dedupe, single Ready, priority,
cached keys, failure + retry window, timeout).

Tunables: `PetAnimConfig` (styles, rates, amplitudes, actions, happy / sleep, tiers, limits).
Tests: `tests/pet-anim.luau` rigs all 29 species from MeshAssets and simulates idle / walking +
turning / sleep / hostile frame times (NaN, negative, huge dt, speed, turn rate) at Full / Simple
× normal / Reduce Motion: grouping, joints, styles, rigid groups, wing mirror symmetry, finite +
bounded pose, flap / bounce / wag / pulse / bank behaviour, happy, sleep, determinism (~1M checks).

## Eggs

| Egg | Area | Mesh | Price | Slots (rarity) | Odds | Pity |
|-----|------|------|-------|----------------|------|------|
| Garage → Nuke Stand | 1–2 | GarageEgg, StandEgg | 40 × producer baseCost (Garage $400 since R65; was $560) | C U R E | 65 / 27 / 7 / 1 % | Epic in 150 |
| BoomDash → Lab | 3–5 | BoomDashEgg, MineEgg, LabEgg | 〃 | U R E L | 65 / 27 / 7.5 / 0.5 % | Legendary in 300 |
| Factory → Megastore | 6–8 | FactoryEgg, SiloEgg, MegastoreEgg | 〃 | R E L M | 65 / 27 / 7.75 / 0.25 % | Mythic in 600 |
| Space Port → Mega Reactor | 9–10 | SpaceEgg, MegaEgg | 〃 | E L M S | 65 / 27 / 7.9 / 0.1 % | Secret in 1,500 |
| Dino Egg (World 2) | Dino 2 (Fern Market) | DinoEgg | 40 × dp2 baseCost = 24K **Bones** | U R E L | 65 / 27 / 7.5 / 0.5 % | Legendary in 300 |
| Volcano Egg (World 2) | Dino 5 (Fossil Lab) | VolcanoEgg | 40 × dp5 baseCost = 3.2B **Bones** | R E L M | 65 / 27 / 7.75 / 0.25 % | Mythic in 600 |
| Moon Egg (World 3) | Moon 2 (Cosmic Diner) | MoonEgg | 40 × mp2 baseCost = 24K **Moon Rocks** | U R E L | 65 / 27 / 7.5 / 0.5 % | Legendary in 300 |
| Comet Egg (World 3) | Moon 5 (Star Lab) | CometEgg | 40 × mp5 baseCost = 3.2B **Moon Rocks** | R E L M | 65 / 27 / 7.75 / 0.25 % | Mythic in 600 |
| Harvest Egg | event | HarvestEgg | 30 acorns | R E L M | 60 / 30 / 9 / 1 % | Mythic in 150 |
| Lucky Egg | held only | GarageEgg (green) | — | R E L M | 70 / 25 / 4.5 / 0.5 % | Mythic in 100 |

* Roll: `NextInteger(1, 100000)` over cumulative slot weights; Lucky Eggs pass doubles the two
  rarest slots (slot 1 pays); pity re-rolls a missed due hatch among slots ≥ pity slot,
  proportional to (lucky) odds; the counter resets on any pity-tier pet. Shown odds = rolled odds
  (stand billboard, EggHatch screen, pity meter).
* Payment: held eggs first (anywhere), the rest bought at the stand (≤ 18 studs, server checked);
  area eggs need `tycoon.area >= area`; Harvest Egg only during the event (EventService.isActive,
  incl. the admin force; window = EventConfig.Season). Acorns are spent through
  `EventService.trySpendAcorns` (season-safe, analytics); balance from `EventService.getAcorns`.
* Count 1, or 3 with the TripleHatch pass. Auto Hatch (pass) = client loop of ordinary requests
  with the fast reveal; stops on STOP AUTO / B, any refusal, walking away, or no held eggs left.
* Paid random items: see **Paid random items (PolicyService)** below — buying with cash or acorns
  is gated on every request; held eggs always hatch.

## Hatch cinematic (owner R49 — "actually animate the egg opening animation")

Presentation only: the server already rolled the pets (HatchResult); the client times and draws
the reveal. Files: `Client/Pets/HatchAnim` (pure maths, every pose = f(timeline, t)),
`Shared/Config/HatchAnimConfig` (all numbers), `UI/Screens/EggHatch/{HatchRevealScreen, HatchStage,
HatchConfetti}`, Blender `tools/blender/models/egg_shards.py` (MeshAssets `EggShards`).

Beats per egg (Normal profile; Fast = Settings "Fast Hatch" / auto-hatch):

| Beat | What happens | Normal |
|------|--------------|--------|
| Intro | the real 3D egg (its eggs.py mesh, `PetModels.egg`) pops into a ViewportFrame over the dim stud backdrop | 0.34 s |
| Idle | gentle bob | 0.4 s (+ triple stagger) |
| Wobble | `Rarity[rank].bursts` shake bursts (3 → 5), each stronger + faster, with a hop and squash / stretch; a clack per burst rising in pitch | ~2 s → ~3.3 s |
| Cracks | `EggShards` Crack1..3 (ink + Neon `Crack<k>Glow` cores in the pet's RARITY colour, pulsing) appear on three bursts; the egg's ambient dims so the cracks glow; halo discs grow; Rare+ show faint rotating rays | — |
| Squash | crouch to 0.78, stretch to 1.14 | 0.26 s |
| Burst | soft radial flash (R19: peak opacity 0.62) + faint screen wash; the `ShellTop*` cap flies (ballistic + spin about its centre), `ShellBottom*` cup sinks / tips / shrinks, `Shard1..7` chips (tinted the egg's ShellTop colour) fly out with spin + gravity | 0.95 s flight |
| Pop | the pet springs from 0.2 with an overshoot (damped cosine) while jumping out of the cup, then `PetModels.animator` idles it (PetAnim, R44; stepped at the tier's ViewportHz) + one happy spin | 0.62 s |
| Banner | stud rarity panel (rarity colour preset): name, RARITY · "1 in N" (Rare+; LuckyEggs odds when owned), cash bonus, PITY! / EQUIPPED, yellow NEW! sticker; confetti burst (Gold palette Legendary+) + sparkles scaled by rarity; rarity stinger cues | 0.38 s |

* Mythic / Secret (`dramatic`): 5 bursts, the room darkens (dim 0.38 → 0.12), the viewport
  jitters (camera-shake look, up to 7 px) toward the burst, a low swell; gold flash / rays /
  confetti and a deep boom + fanfare. Legendary+ bursts kick the viewport once.
* Triple hatch: eggs pop in left to right; build-ups are staggered in rarity order (worst first)
  with ≥ MinBurstGap between bursts, so the best pet is always revealed last.
* Input: one button reads SKIP while playing (grey) and AWESOME! / NEXT once revealed (gamepad
  default selection, A); a tap / click anywhere does the same; B skips first, closes after the
  reveal and stops auto-hatch. `HatchAnim.onTap`: before the last burst → jump to it (its burst
  events still fire, every pet is out); within MinReveal after it → ignored (no accidental close);
  later → close. Auto-hatch closes by itself `AutoHold` after the end.
* Reduce Motion: a still egg cross-fades into the pet (part transparency), banner appears without
  motion; no shake, flash, jitter, rays spin or confetti. Sounds + haptic stay.
* FxQuality: Low flies 4 of 7 shards and 35 % of the confetti; the pet idles at PetAnim's
  per-tier viewport rate (Simple detail on Low).
* Performance: ONE RenderStepped connection while the screen is open; 3 pooled slots (viewport,
  halo discs, rays, flash discs, banner) built once; egg + EggShards models cached per slot per egg
  id (a box-fallback egg is rebuilt once its meshes load); the pet model is built at prepare; the
  confetti pool (96 Frames) is built once; every property write is change-gated / quantised;
  hidden pieces cost nothing. `PetModels.Ready` rebuilds whatever a slot shows, mid-animation, with
  no visible jump (poses are stateless). Opening the EggHatch window warms the EggShards meshes and
  the egg's pet meshes.
* EggShards (generic, one set for every egg; 13 pieces, 1,048 tris): `Shard1..7` (tinted =
  true; egg ShellTop colour), `Crack1..3` ink (`Smooth`, dark), `Crack1..3Glow` (`Neon`, tinted =
  rarity colour; every glow box ≤ 4.6 studs², inside the R19 Neon budget). Built on the eggs.py
  surface maths (`egg_frame` / `crack_phi`): stage 3 runs along the real ShellTop / ShellBottom seam.
* Settings: `settings.fastHatch` (ProfileLogic SettingKeys, default false; Settings window row
  "Fast Hatch — Shorter egg opening"). There is no auto-delete feature in SellNukes.
* Studio QA: `STUDIO_LOCK_OWNER=<you> python3 tools/qa/hatch_reveal.py` (one solo playtest: a real
  held-egg hatch through HatchEgg, then fixed common / rare / mythic / triple results frozen
  mid-crack and after the reveal via the Studio-only `DebugHoldAt` attribute; phone / tablet /
  console matrix). Evidence 2026-10-30: `docs/verification/ui/hatch/*.jpg` (rare + triple are the
  final framing; common / mythic / real shots predate the camera move from 15.4 to 12.8 studs).
  Seen there: the first hatch of a session could miss the cracks while EggShards was still loading
  (13 sequential loads then; PetModels now loads in parallel). Warm-ups: `PetModels.prefetch` of
  EggShards 25 s after boot and of EggShards + the egg whenever the EggHatch window opens; the
  reveal itself `request`s it (urgent) and rebuilds the overlay on `PetModels.Ready`.
* Settings "Fast Hatch" row (2026-10-30, `HATCH_QA_SETS=settings`): window fits on desktop / phone
  (wide mode) / tablet / console with the gamepad-only Vibration row; toggle 44.2 pt on phone +
  tablet, Selectable and linked up / down for the gamepad; B is bound (ButtonB) and the Back path
  closes it; no hatch / pet errors in the runtime log (`settings-*.jpg`, rare + triple re-run
  with `PetModels.animator`: pets idle after the pop).
* Tests: `lune run tests/hatch-anim` (~1.67 M checks): config sanity + every cue is an
  AudioConfig.Sfx key, phase order for 7 rarities × fast × reduced × granted, 240 Hz NaN / range
  sweep of every pose, curve endpoints (stretch at burst, springs settle at exactly 1, shards
  hidden → shown → gone), reduced = pure cross-fade, triple stagger best-last for all 7³ combos,
  tap skip / wait / close, sorted events.

## Crates & trails

| Crate | Gems | Robux product | Pity | Highlights |
|-------|------|---------------|------|-----------|
| Supply | 120 | CrateSupply R$49 | Rare+ every 6 | 2x Cash/Speed 15 m, gems, Lucky Egg, Green Glow trail, Supply Mole (Epic) |
| Mega | 350 | CrateMega R$149 | Epic+ every 8 | 30 m boosts, 2 Lucky Eggs, Atom Orbit trail, Storm Phoenix, Golden Dragon 0.5 % |
| Golden | 1,000 | CrateGolden R$399 | Legendary+ every 5 | 2 h / 6 h 2x Cash, 5 Lucky Eggs, Gold Sparkle + Rainbow trails, Golden Dragon, Cosmic Unicorn 0.5 % |

* Held crates open first (no gems), else gems. EVERY open is a paid random item (below): held
  crates only come from Robux receipts (+ admin), gems are Robux-reachable. Robux: kind "Crate"
  receipt → `CrateLogic.receiptDecision`: policy unknown → deferred (NotProcessedYet), known
  restricted → the gem price in gems, else +1 held crate; then the client opens CrateOpen
  ("READY!") from PurchaseGranted.
* Odds before every purchase: the first press of a card's GEMS / Robux button flips the card to
  its full odds list (the next press buys); CrateOpen shows the odds per rarity
  (`CrateConfig.oddsSummary`) under the title whenever OPEN! / OPEN ANOTHER / AGAIN is offered.
* Duplicate trail / pet at the hard cap → `dupGems`. Boost rewards stack via B7's BoostLogic and
  invalidate the tycoon modifiers. A new trail auto-equips when none is equipped.
* Trails: server Trail + 2 attachments on the HumanoidRootPart (`TrailRenderer`), re-applied on
  CharacterAdded; `EquipTrail("")` removes it.

## Paid random items (PolicyService) — pre-publish compliance (2026-10-30)

Roblox: `ArePaidRandomItemsRestricted` = "the player can **not** interact with paid random item
generators, either via in-experience currency bought with Robux or Robux directly". Audit of what
Robux can buy (pinned per product kind by `tests/pets-policy.luau`, so a new kind fails CI until
it is classified):

| Currency / item | Robux routes | Eggs / crates gate |
|-----------------|--------------|--------------------|
| cash | Cash packs ×4, Starter + Secret Pack, DoubleOffline, ServerCash2x, Cash2x30, DoubleCash pass, SkipPad | cash eggs **gated** (`EggConfig.PaidRandomCurrencies.cash = true`) |
| acorns | AcornsSmall / AcornsLarge, TurkeyLure (3x acorns) | Harvest Egg **gated** |
| gems | Gems packs ×3, Starter + Secret Pack, crate refunds | gem crates **gated** (`CrateConfig.PaidRandomPay.gems`) |
| held crates | CrateSupply / Mega / Golden receipts (+ admin) | held crate opens **gated** (`PaidRandomPay.held`) — kept safe while restricted |
| held eggs | none directly: daily / wheel / codes / group / crate rewards / admin | **not gated** (granted, hatching buys nothing) |

* Server: `PetService` awaits `PlayerDataService.resolvePaidRandomAsync` on **every** hatch that
  must buy ≥ 1 egg (`EggConfig.needsPolicy` — same held-count rule as `planHatch`); `CrateService`
  on every open. `Economy/PolicyCache` fails closed (never asked / lookup failing / malformed /
  still pending after 10 s = restricted); `restricted` defaults to true until resolved. Refusal
  codes `Restricted` (known) / `PolicyUnknown` (not answered: "try again"); nothing is charged or
  spent. Analytics: pets `refused:policy`.
* Client (`EggConfig.policyState(profile.policy)`: `allowed` / `restricted` / `checking`): stand
  billboards show "NOT IN YOUR REGION" instead of the price (odds stay); EggHatch keeps the odds,
  locks HATCH / HATCH 3 / AUTO when they would buy ("UNAVAILABLE"), explains it in the price
  line and keeps HATCH FREE for held eggs; auto-hatch stops instead of buying; CrateShop / CrateOpen
  lock every open ("UNAVAILABLE", held crates "KEPT SAFE (n)"). `checking` leaves buttons
  usable — the server decides and fails closed. Texts: `EggConfig.PolicyText`,
  `CrateConfig.PolicyText`.
* Free rewards keep working for everyone: daily / time rewards, free wheel spins (Lucky Egg), codes,
  group pet, event redemption, admin grants — `PetGrants` / `RewardLogic` never consult the policy.
* The other paid random routes are closed the same way (P1, 2026-10-30): Lucky Wheel spins are
  split into free / bonus / paid banks, and paid spins are gated on every spin. Starter / Secret
  Pack spins become 40 gems each where restricted. The Turkey Lure is `paidRandom`, and a
  restricted catch gets fixed acorns. See `docs/retention.md` and `docs/event.md`; tests are in
  `tests/paid-random-policy.luau`.
* Analytics: crates `refused:<gems|policy|rate|busy|other>` (CrateService), pets
  `refused:policy`.

## Remotes

| Remote | Args | Notes |
|--------|------|-------|
| `HatchEgg` | eggId, count (1/3), requestId (1..2^31), auto? | → `HatchResult(requestId, payload)`; id 0 = server grant (reveal) |
| `EquipPet` | uid, on | |
| `EquipBest` | — | |
| `DeletePets` | {uid} ≤ 100 | locked skipped |
| `LockPets` | {uid} ≤ 100, locked | |
| `OpenCrate` | crateId, requestId | → `CrateResult(requestId, payload)` |
| `EquipTrail` | trailId \| "" | |
| `PetIndexClaim` | milestone position 1..7 | R78; no reply remote (profile push + reward toast); bucket 4 / 1 s |

Security: every arg validated (`Validate.integer/key/boolean/stringArray`), token buckets per
player, one hatch / open in flight, repeated request id → same payload, never a second charge
(`RequestMemory`, 32 per player), `canMutate` gate, plan → charge → commit with no yield
(all-or-nothing commits with undo; charge refunded if a commit ever throws). Cash / gems go
through `PlayerDataService.trySpendCash / trySpendGems / grantGems` (analytics sinks / sources).

## Stands, console + mobile (owner R11)

* Stands: B8e's `HubLayout.anchors` — egg mesh at `EggStands[i].egg`, prompt part at `.prompt`,
  odds billboard 13 studs above the egg (over the stand's Sign, which shows name + price via a
  client SurfaceGui), crate stall crates around `CrateStall.display`. The Harvest egg + prompt
  exist only while the event runs (EventService.ActiveChanged). No HubLayout → fallback ring.
* Input: the egg prompt (E / gamepad X / tap) plus B16's Platform "Egg" context (within 11 studs)
  → Hatch action (E / X / big HATCH touch button, hint bar glyph) → EggHatch window.
* Pets screen: GamepadNav.linkGrid cards (exits: tab bar / pager / side panel), LB / RB cycle tabs,
  X equip / Y lock on the selected card (glyph hints in gamepad mode), A opens, B leaves delete
  mode / closes. Tap targets ≥ 72 design px. Every screen has a gamepad default selection.
* Haptics (B16 `Platform/Haptics`, guarded): "Hatch" at the pet reveal, "Reward" at the crate reveal.

## Grant API (other systems)

* `PetService.grantPet(player, petId, reason) -> (ok, uid?)` — hard cap, auto-equips into a free
  slot, saves soon, plays the reveal (B11 Gobble Bomb, admin).
* `PetService.grantEgg(player, eggId, count, reason) -> ok` — held eggs.
* B7 `RewardGrant.registerItemGranter("pet"|"egg", PetGrants.pet|egg)` — done in PetService.Init.
* `PetService.Hatched: Signal(player, eggId, petId)` — every hatched pet (B11 First Hatch badge).
* `PetGrants.grantFixed(player, petId, reason) -> (ok, uid?)` (R57) — ONE specific non-egg pet
  through the live `grantPet` path (the Time Traveler Pack's `time_ptero`). Deterministic, so the
  pack is not a paid random item; refuses egg pets, unknown ids, non-players, an unloaded / save-
  offline player and anything before PetService loaded (registered at load via `useLive`) — the
  receipt handler then answers NotProcessedYet. Never yields, never throws.

## Analytics & admin

Analytics (guarded lazy `PetSeams`): `eggHatched` (hatch / hatchN / hatchAuto / rarity /
eggRarity / pet), pets `equip` / `equipBest` / `delete` / `refused:<cash|slots|rate|locked|policy|other>`,
`crateOpened` (open / openPay `gems|robux` / reward / rarity), crates `boost:<key>` /
`boostSec:<key>`; id kinds `eggId`, `petId`, `crateId` registered; R78 pets
`index:claim:<5|10|20|30|45|60|all>`, `index:gems` (amount), `index:refused:<claimed|locked|rate|bad|save|other>`
(+ economy gems reason `petIndex`, transaction type Gameplay). Admin (B14, Players tab):
GivePet, GiveEgg, ClearPets, GiveCrate, GiveTrail, R78 PetIndexView / PetIndexGrant / PetIndexClear
(registered with retries).

## Tests

`lune run tests/pets-logic` (504: configs + art contract, roll boundaries + 200k distribution,
pity incl. triple, every refusal changes nothing, payments, uids / index / auto-equip, equip /
best / trim / delete / lock, caps, attribute encoding, all-or-nothing commit, request memory),
`tests/pets-crates` (127: odds, distribution, pity, held / gems / policy, every reward kind, dup,
caps, receipts, trails, rollback), `tests/pets-policy` (318: Robux-reachability audit of every
product kind, the real PolicyCache's restricted / 5× unknown / unrestricted answers, the matrix
cash egg · triple · partial held · acorn egg · gem crate · held crate × every answer → refused /
refused / allowed with nothing changed, receipt defer / gems / crate, free rewards + held eggs
unaffected, `needsPolicy` / `policyState` / odds summary), `tests/pets-follow` (312: formation,
smoothing, hover / hop), `tests/pet-anim` (animation sweep of all 38 species, see Animation).
World 2 (W11, 2026-10-30): pets-logic 729 (§12 Dino eggs + pets, world unlock gate, Bones-only
payment + refund, Bones policy gate, held Dino eggs, refusal texts, parseStand, grantFixed,
EggView), pets-policy 437 (Bones Robux-reachable + gated, WorldCash / WorldStarter classified,
the Time Ptero is fixed + never in an egg, Bones egg / Bones triple × every answer), pet-anim
1.41M (38 species; dinos Walk, pteros Fly).

## World 2 "Dino Valley" eggs + pets (W11, owner R57 — 2026-10-30)

Spec `docs/superpowers/specs/2026-10-31-world2-design.md` §8; plan §3.6. Art: `docs/pets-art.md` §10.

* **Worlds framework.** Every egg has `world` (WorldsConfig id). A world egg costs that world's
  currency key (`WorldsConfig.get(world).currency.key`, Dino: `bones`), unlocks with that world's
  progress and stands on that world's hub layout. Adding World 3's eggs = rows in EggConfig
  `WORLD_EGGS` + its currency in `PaidRandomCurrencies` (spec §18); `EggConfig.validate()` checks
  world / currency / area / stand prefix / `WorldDef.eggs` both ways and unique stands.
* **Unlock** (`EggConfig.progressOf` / `isUnlocked`, shared by server + client snapshot):
  Nuke Town eggs read `profile.tycoon.area`; a world egg needs `profile.worlds[world].unlocked ==
  true` AND `worlds[world].tycoon.area >= egg.area` (Nuke Town progress never opens a Dino egg).
  Refusal `Locked` ("Reach Fern Market in Dino Valley to unlock the Dino Egg!").
* **Payment.** Bones are paid ONLY from `profile.worlds.dino.cash` (PetLogic.worldWallet →
  `PlayerDataService.trySpendCurrency(player, "bones", total, "egg_hatch")`: marks `worldCash`,
  reports the sink); cash never pays a Bones price. A failed commit refunds the Bones without
  touching `totalEarned`. `NotEnough` says "You need more Bones … Keep building in Dino Valley!".
* **Paid random items.** Bones are Robux-reachable (BonesSmall / Medium / Large = `WorldCash`,
  the Time Traveler Pack = `WorldStarter`), so `PaidRandomCurrencies.bones = true`: every request
  that must BUY a Dino egg awaits the fail-closed PolicyCache answer, exactly like cash eggs.
  Held Dino eggs hatch anywhere, for everybody. The Time Ptero is a fixed grant (not random).
* **Stands.** `stand = "dino:EggStands1|2"` → `ValleyLayout.anchors.EggStands[1|2]` (W9,
  WORLD-LOCAL `EggStandAnchor`), placed with `WorldLayout.toWorld("dino", cf)` by
  `EggStands.buildWorldStand`; stand models carry `WorldId`. Until W9's anchors exist, a fallback
  pedestal ring around the Dino world origin is built (verified in Studio). The server range check
  (18 studs) is in world space; the client dresses the nest mesh's `Sign` (found under
  `Workspace.Worlds.<world>`, waited for cheaply while the world hub is not built yet).
* **Client text** (`Client/Pets/EggView`, pure): "24K Bones each", "You have 1.2K Bones",
  "LOCKED - unlock Dino Valley" / "LOCKED - reach Fossil Lab", buttons "UNLOCK DINO VALLEY" /
  "REACH FOSSIL LAB"; stand cards green (Dino Egg) / red (Volcano Egg); repaint on `worlds` /
  `worldCash` changes. Pets Index: "Hatch it from the Dino Egg in Dino Valley!", Time Ptero
  "Comes in the Time Traveler Pack (Shop)!".
* **Pets** (bonus tiers per spec): Dino Egg tier 4 — Atom Raptor (U) +14 %, Glow Stego (R) +23 %,
  Fission Trike (E) +39 %, Pocket Bronto (L) +68 %; Volcano Egg tier 7 — Ember Ankylo (R) +46 %,
  Magma Ptero (E) +76 %, Lava Para (L) +134 %, Supernova Spino (M) +229 %; Time Ptero Epic tier 5
  +49 % (`source = "pack"`). Pets are shared across worlds (one collection, `petCash` everywhere).
* **Animation.** No PetAnimConfig overrides needed: the dinos derive Walk, Magma / Time Ptero
  (hover + WingL / WingR) derive Fly; Neon pieces named `*Glow*` pulse (R19-safe).
* **Studio (2026-10-30, `docs/verification/world2/pets/`)**: real client hatches through HatchFlow
  at the fallback stands — Dino Egg charged exactly 24,000 Bones → Atom Raptor, Volcano Egg
  3.2B Bones → Lava Para (cracks in the rarity colour, reveal, NEW!, auto-equip); restricted
  policy → `Restricted`, nothing charged, window "UNAVAILABLE"; a held Dino egg still hatched while
  restricted; EggHatch window on desktop / phone / tablet / console; dino pets following; no
  pet / egg errors in the runtime log.

## World 3 "Moon Base" eggs + pets (W11, owner R70 — 2026-10-31)

Spec `docs/superpowers/specs/2026-10-31-r69-moon-lucky-juice-design.md` §2.5. Art: `docs/pets-art.md` §11.
Added the spec §18 way: config rows + art, **no** pets / eggs code change (the World 2 framework
already handles any world currency, unlock, stand and client text).

* **Eggs** (EggConfig `WORLD_EGGS`): `moon_egg` (Moon area 2, Cosmic Diner; 24K Moon Rocks;
  the Dino Egg's odds + pity) and `comet_egg` (Moon area 5, Star Lab; 3.2B Moon Rocks; the Volcano
  Egg's). Stands `moon:EggStands1|2` → `MoonHubLayout.anchors.EggStands[1|2]` (W9b, world-local;
  fallback pedestal ring at the Moon origin until they land). Billboard cards purple / blue (new
  optional `EggDef.card`; Dino green / red).
* **Paid random items:** Moon Rocks are Robux-reachable (MoonRocksSmall / Medium / Large =
  `WorldCash`, Astronaut Pack = `WorldStarter`), so `PaidRandomCurrencies.moonrocks = true` (fail
  closed). pets-policy's audit is now generic: a world product reaches its own world's currency.
* **Pets** (tiers 4 / 7 / 5): Moon Egg — Astro Pup (U) +14 %, Moon Bunny (R) +23 %, Orbit Owl (E)
  +39 %, Cosmo Cat (L) +68 %; Comet Egg — Comet Fox (R) +46 %, Saucer Octo (E) +76 %, Galaxy Whale
  (L) +134 %, Starlight Unicorn (M) +229 %; **Rocket Corgi** (Epic tier 5, +49 %, `source = "pack"`)
  is the Astronaut Pack's fixed pet: W1's handler calls
  `PetGrants.grantFixed(player, "rocket_corgi", "AstronautPack")`.
* **Animation** (PetAnimConfig rows): Moon Bunny Hop, Galaxy Whale Swim + Pitch fluke, Saucer Octo
  tentacle Sway; Orbit Owl / Starlight Unicorn derive Fly, Saucer Octo / Rocket Corgi Float.
* **Tests:** pets-logic 920 (§13 Moon: rows, odds = Dino tiers, prices, pets, unique names across
  worlds, unlock gate, Moon-Rocks-only payment + refund, policy gate, texts, EggView),
  pets-policy 552 (+ the Moon Rocks egg matrix row), pet-anim 1.77M (47 species).

## Pet Index rewards + Golden Nukey (R78 — 2026-10-31)

Spec `docs/superpowers/specs/2026-10-31-r78-retention-pack-design.md` §5 (A-pets). Art:
`docs/pets-art.md` §12. Studio QA: `tools/qa/pet_index.py` (20 / 20 checks, captures in
`docs/verification/r78-pets/`).

**Exclusive pets (autonomous decision, documented in PetConfig's header).** `PetDef.exclusive`
marks every pet that free, always-available play cannot reach: Robux packs (Golden Atom Pup /
Starter, Golden Nuke / Secret, Time Ptero, Rocket Corgi), the Nuke Pass (Golden Nukey) and the
limited Harvest Feast (Acorn Squirrel, Harvest Hedgehog, Cranberry Crab, Cornucopia Dragon, Gobble
Bomb) — 10 of 76. `PetConfig.validate` keeps every `pass` / `pack` / `starter` / `secret` / `event`
pet exclusive, so a future paid pet can never make "all" pay-gated. Marking a pet exclusive only
lowers the ALL target; owning one still counts.

**Counting** (`PetIndexConfig.discovered`): known pet ids marked `true` in `pets.index` (set on every
hatch / grant, never cleared), exclusives included (their mark means "has owned one"). The bar's
total `PetIndexConfig.Total` = the non-exclusive count (66 today); ALL needs `discovered >= Total`
(so 65 regular + 1 owned exclusive completes it). The INDEX header reads `Discovered n / 66`.

| Milestone | 5 | 10 | 20 | 30 | 45 | 60 | ALL |
|---|---|---|---|---|---|---|---|
| Gems | 25 | 40 | 60 | 80 | 120 | 160 | 300 |
| Index Bonus (permanent cash) | +2 % | +2 % | +3 % | +3 % | +5 % | +5 % | +10 % (= +30 %) |

**Claim flow.** INDEX tab side card → `IndexRewards` panel: header (`INDEX REWARDS` + earned
bonus), 7 milestone pips (green claimed / yellow ready / grey locked), progress bar toward the
next milestone not reached yet, `Ready:` / `Next:` reward line, CLAIM (`CLAIM +25 GEMS`, locked
`FIND 8 MORE`, `ALL CLAIMED!`; breathes while ready). CLAIM sends `PetIndexClaim(position)` →
`PetService.handleIndexClaim`: token bucket → `Validate.integer(1..7)` → profile loaded +
`canMutate` → B7 RewardGrant present → `PetIndexLogic.claim` (claimed / locked change nothing) →
`RewardGrant.grant({ gems }, "petIndex", { saveSoon, extraFields = { "pets" } })` in the SAME
no-yield step → `invalidateModifiers` → analytics + reward toast. The bonus enters
`petCash = PetLogic.cashBonus + PetIndexLogic.bonus` in the existing "pets" ModifierSources
provider (`(1 + petCash)`, so it works offline and through rebirth like pets).
Juice on the push that shows the claim: button pop, pip bounce, 8 pooled stars, floating
`+25 GEMS +2% CASH`, `milestone` + `coin_burst` sounds, Reward haptic; gems fly into the HUD counter
(CurrencyFly). Reduce Motion keeps sound + text only.

**Badges + console.** HUD Pets badge = held eggs + crates + ready milestones; the INDEX tab wears a
red `!` while one is ready. Gamepad: CLAIM is the grid's right exit (left goes back, up = tab,
down = pager) and the default selection when a milestone is ready; B closes. CLAIM is 72 design px
tall (≥ 44 pt on phones). Deep link: `ScreenManager.open("Pets", { tab = "index", select = petId })`.

**Golden Nukey** (`golden_nukey`, mesh `SparkleNukey`): Mythic tier 10 = +447 % (the strongest
Nuke Town Mythic, Plasma Dragon), `source = "pass"`, `exclusive`, in NO egg pool, Index line
"Nuke Pass Season 1 - Premium tier 30!" (`PetDef.how`; Rocket Corgi got its own "Astronaut Pack"
line the same way). P-pass (PassService) grants it with `PetGrants.grantFixed(player,
"golden_nukey", "pass")` — the live `PetService.grantPet` path (auto-equip, reveal popup); a failed
grant pays PassConfig's 400 fallback gems. The B7 item granter (`{ pet = "golden_nukey" }`) works too.
The id is SAVE DATA and PassConfig.Exclusives.Pet — never rename it. Hop style
(PetAnimConfig `SparkleNukey`), the sparkle hoop spins.

**Admin** (Players tab, registered by PetService): `PetIndexView` (found / total, claimed, ready,
bonus), `PetIndexGrant` (milestone enum; marks + pays, ignores the pets needed; audited),
`PetIndexClear` (confirm; un-claims, the bonus goes, paid gems stay; audited).

**Tests:** `tests/pet-index.luau` (269: config = spec, Total, Golden Nukey row / strength / no egg
pool / mesh / anim, exclusive sources, Nuke Pass reward + fixed grant paths, hostile index tables,
exclusives completing ALL, eligibility at every boundary, garbage positions, locked / idempotent
claims paying once, bonus sums to +30 %, admin set / clear, profile default / reconcile / bound /
snapshot copy / save round trip); pets-logic 76 pets; pet-anim 48 species; validate + profile-logic
gained the remote / field.

## Next steps

* Upload the B8f pet / egg / crate meshes (MeshAssets ids are 0 except GlowSlime): the client
  swaps the piece boxes for meshes automatically (`PetModels.Ready`).
* B12: publish the CrateSupply / CrateMega / CrateGolden products and the LuckyEggs / PetSlots /
  TripleHatch / AutoHatch passes (ids in PublishedProductIds).
* Animation (R44) is done; tune feel in `PetAnimConfig` after owner playtests (e.g. per-species
  action lists, a Feet paddle for the duck if the Blender split adds FeetL / FeetR).
* World 2: once W9 lands `ValleyLayout.anchors.EggStands`, re-shoot the stands at Base Camp
  (the fallback ring disappears automatically). W3's Time Traveler Pack handler calls
  `PetGrants.grantFixed(player, product.pet, "TimeTravelerPack")`.
* World 3: re-shoot the Moon stands once W9b lands `MoonHubLayout.anchors.EggStands`.
* R78: a Nuke Pass "SEE PET" button can deep-link `ScreenManager.open("Pets", { tab = "index",
  select = "golden_nukey" })`. New paid / pass / event pets must set `exclusive = true` (validate
  enforces it for those sources). Future seasons' pass pets: add a row with `source = "pass"`.
