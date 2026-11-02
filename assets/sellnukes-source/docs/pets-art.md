# SellNukes pets, eggs, crates, attack-mode and Harvest Feast art (B8f)

Blender-built (scripted `bpy`), stud-textured toy models for spec §8 (pets / eggs / crates), §9
(attack mode) and §10 (Harvest Feast). Pipeline, stud material and budgets: `docs/world-art.md`.
This file is the **catalogue + runtime contract**: every model key, its pieces (= MeshParts),
colours, intended rarity, hover heights, animation groups and joint positions.

| Builder | Models |
|---|---|
| `tools/blender/models/pets.py` | 29 pets (24 roster pets over 7 rarities + group pet + Gobble Bomb + 3 Harvest Egg pets) |
| `tools/blender/models/eggs.py` | 10 area eggs + Harvest Egg (cracked two-part shells) |
| `tools/blender/models/crates.py` | Supply / Mega / Golden crate (separate lid) |
| `tools/blender/models/attack.py` | nuke projectiles T1-T5, interceptor, AA towers L1-L5, shield dome, confetti cloud |
| `tools/blender/models/event_items.py` | Golden Turkey, Feast Sticker, Feast Sticker plaque, Acorn, Pie |
| `tools/blender/models/pet_golden_nukey.py` | R78 Golden Nukey pet `SparkleNukey` (golden sparkly chibi of the hub's Nukey statue; §12) |
| `tools/blender/models/_critter_kit.py` | shared helpers (oriented ellipsoids, surface points, tubes, rings, stars, crowns, joints text); the leading `_` keeps it out of builder auto-discovery |
| `tools/blender/studio/spawn_b8f_preview.luau` | edit-mode lineup of all 61 models + hatch / lid / turret pose checks |
| `tools/blender/studio/cleanup_b8f_preview.luau`, `b8f_camera_*.luau` | cleanup + camera presets |

```bash
KEYS=GlowSlime,AtomPup,...        # any subset of the keys below
/opt/homebrew/bin/blender -b --python tools/blender/generate_world.py -- --only $KEYS
python3 tools/blender/contact_sheet.py --only $KEYS
python3 tools/blender/upload_meshes.py --user-id 1586034782 --only GlowSlime AtomPup ...   # space separated
python3 tools/blender/sync_meshes.py && lune run tests/mesh-assets
```

---

## 1. Conventions (all models)

* **Roblox space**, studs, +Y up, model **front = −Z**, +X = the model's right-hand side.
* **One piece = one colour = one MeshPart**. Bodies use `StudsSmall` (pets, eggs, small props) or
  `Studs` (towers, crates, cloud); faces/eyes `Smooth`; glowing parts `Neon`; slime, jelly,
  helmet bubble and the shield dome `Glass` (translucent).
* **Piece-name prefix = animation group.** Rotate every piece of a group about that group's
  joint (model space, read from the pivot string). Anything without a listed prefix is the rigid
  body. Prefixes (match the longest first):

  | Prefix | Used by | Motion |
  |---|---|---|
  | `Head` | pets, Gobble Bomb, Golden Turkey | nod / tilt / peck about the neck joint |
  | `Tail` | pets, turkey | wag / fan about the tail root |
  | `WingL` `WingR` | birds, narwhal flippers, dragon | flap about the shoulder |
  | `ClawL` `ClawR` | Cranberry Crab | snip / wave about the shoulder |
  | `FeetL` `FeetR` | Golden Turkey | alternate waddle about the hips |
  | `Feet` | Quark Duck | paddle |
  | `Orbit` | Rare+ pets | spin about +Y through the joint (Neon atom rings) |
  | `ShellTop` / `ShellBottom` | eggs | top flips back about the crack hinge; bottom may tip apart |
  | `Lid` | crates | opens about the back hinge (positive angle about +X raises the front) |
  | `Turret` / `Barrel` | AA towers | turret yaws about +Y; barrel pitches about +X (positive raises the muzzle) and rides on the turret |
  | `Exhaust` | projectiles | candy-flame flicker (scale / transparency) |
  | `Base` `Stem` `Ring` `Cap` `Stars` `ConfettiA/B/C` | confetti cloud | tween in order, then fade |

* **Pivot strings carry the joints** (`MeshAssets[key].pivot`), machine-parsable:
  `... ; hover 0.8; joints Head@(0,1.11,-0.11) Tail@(0,0.82,0.74) Orbit@(0,1.05,0)`.

```lua
-- Parse joints out of a MeshAssets pivot string (used by spawn_b8f_preview.luau).
local function jointsOf(pivot: string): { [string]: Vector3 }
	local joints = {}
	for name, x, y, z in string.gmatch(pivot, "(%w+)@%(([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)%)") do
		joints[name] = Vector3.new(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
	end
	return joints
end
-- Rotate a group about its joint (pets / eggs / lids / turrets).
local function rotateGroup(model: Model, prefix: string, joint: Vector3, rotation: CFrame)
	local hinge = model:GetPivot() * CFrame.new(joint)
	local delta = hinge * rotation * hinge:Inverse()
	for _, part in model:GetChildren() do
		if part:IsA("BasePart") and string.sub(part.Name, 1, #prefix) == prefix then
			part.CFrame = delta * part.CFrame
		end
	end
end
```

For per-frame animation, cache each part's model-space rest CFrame once and set
`part.CFrame = modelCF * jointCF * rot * jointCF:Inverse() * rest` from ONE RenderStepped
connection for all pets (spec perf rule: one connection per system).

---

## 2. Pets (`pets.py`)

* **Origin = ground-contact centre** (y = 0 under the pet's middle); every pet is modelled resting on
  y = 0. **`hover`** (pivot string) is the extra height the follower adds for flyers / floaters
  (owl 0.8, narwhal 1.0, phoenix 1.0, dragon 0.9, jelly 1.0, axolotl 0.4, void cat 0.3); bob ±0.25
  around it. Walkers stay at 0 and hop.
* **Size**: 1.8–2.6 studs tall (hip height of an R15 avatar). Suggested follow offset: behind-right
  of the owner at (2.5 + 2.2·slot, 0, 3) in the owner's frame; face the owner's move direction.
* **Budget**: ≤ 10 pieces, ≤ 2,800 triangles (actual 1,142–2,766).
* **Rarity flair**: Common = plain toy + one small Neon detail; Uncommon = Neon spots / glowing held
  item; Rare = one Neon atom ring (`Orbit`); Epic = two rings or a signature glow (helmet, horn,
  gills); Legendary = gold accents (antlers, crown, crest); Mythic = gold horns / halo / glowing
  wings, translucent or Neon body parts; Secret = all-gold or void-black body, glowing eyes, crown /
  halo + double ring. Rings dip in front so they never cross the face.
* **Display names**: split the key on capitals (`NuclearNarwhal` → "Nuclear Narwhal").
* Pets are 100 % original critter designs (no external IP); "Gobble Bomb" is a round cartoon toy
  bomb dressed as a turkey (fan tail, wattle, candy fuse with a Neon spark) — kid-friendly.

Intended roster (economy/pet config owner decides final odds and boosts):

| Rarity | Pets |
|---|---|
| Common | GlowSlime, AtomPup, IsotopeKitty, QuarkDuck |
| Uncommon | UraniumBunny, NeutronNewt, PlasmaPig, MegaMole |
| Rare | FissionFox, ReactorOwl, ProtonPanda, GammaGator |
| Epic | NuclearNarwhal, CosmicCorgi, RadRaccoon, AtomicAxolotl |
| Legendary | MeltdownMoose, FusionPhoenix, ReactorRex |
| Mythic | CoreDragon, NovaUnicorn, IonJelly |
| Secret | GoldenNukey, VoidCat |
| Group exclusive | BuilderBeaver (hard-hat beaver; group reward) |
| Event (sticker sheet) | GobbleBomb |
| Harvest Egg | AcornSquirrel (common), HarvestHedgehog (rare), CranberryCrab (epic) |

Suggested egg pools (one pet set per area tier, rising rarity): Garage/Stand → Commons + Uncommons;
BoomDash/Mine → Uncommon + Rare; Lab/Factory → Rare + Epic; Silo/Megastore → Epic + Legendary;
Space/Mega → Legendary + Mythic + Secret (Secret only from the Mega Egg).


---

## 3. Eggs (`eggs.py`)

* **Origin** = ground point under the egg (bottom at y = 0); decorated face toward **−Z**.
  3.0 studs tall, 2.3 wide. Shells `StudsSmall`, glows `Neon`.
* Every egg is a real **two-part shell with thickness** split on a zig-zag crack (crack centre
  y = 1.34, ±0.11 rad teeth, 20 columns). Each half is closed (outer skin, inner skin, jagged rim),
  so an opened egg shows a clean thick toothed edge — verified in Studio (`eggs-studio.jpg`, the
  hatching Garage Egg on the left).
* Groups: `ShellTop*` (upper shell + its decorations) and `ShellBottom*`. Decorations never cross
  the crack. Hinge joint `ShellTop@(0,1.34,1.15)` = back of the crack.
* **Hatch recipe**: wobble the whole model 2–3× → rotate `ShellTop*` about the hinge by
  `CFrame.Angles(math.rad(110), 0, 0)` (positive about +X swings it back over the hinge) while lifting ~0.5 → (optional) tip `ShellBottom*` apart → pop the
  pet out of the bottom shell with confetti.
* **EggShards overlay** (`tools/blender/models/egg_shards.py`, owner R49): ONE generic model laid
  over any egg at the same pivot — `Shard1..7` curved thick shell chips on the crack band (tinted,
  the client paints them the egg's ShellTop colour; hidden until the burst, then they fly) and three
  crack stages `Crack1..3` (dark ink tubes) + `Crack1..3Glow` (thin Neon cores, tinted the pet's
  rarity colour) built on the same `egg_frame` / `crack_phi` surface maths; stage 3 follows the
  real seam. 13 pieces, 1,048 tris, uploaded. The real hatch now plays in
  `UI/Screens/EggHatch/HatchStage` (docs/pets.md "Hatch cinematic").

| Area | Key | Theme |
|---|---|---|
| 1 Garage Lab | `GarageEgg` | sky-blue shell, white wrench plates, steel hex bolts, hazard band, Neon trefoil |
| 2 Nuke Stand | `StandEgg` | lemon shell, red scalloped awning, candy-striped cap, gold coins |
| 3 BoomDash | `BoomDashEgg` | toy-red shell, yellow lightning bolt, white speed lines, black wheels |
| 4 Glow Rock Mine | `MineEgg` | stone shell, glowing green crystal clusters, darker rock spots |
| 5 Enrichment Lab | `LabEgg` | white shell, mint band, glowing bubbles, radiation badge |
| 6 Rocket Factory | `FactoryEgg` | orange shell, steel gears, double hazard band |
| 7 Launch Silos | `SiloEgg` | steel shell, red rocket fins, hazard band, red nose cap, trefoil badge |
| 8 Nuke Megastore | `MegastoreEgg` | pink shell, gold stars, Neon sparkles, purple price tag |
| 9 Space Port | `SpaceEgg` | navy shell, Neon star field, ringed planet + cratered moon |
| 10 Mega Facility | `MegaEgg` | gold shell, Neon reactor band + trefoils, pink gem studs, crown rim |
| Event | `HarvestEgg` | pumpkin-ribbed orange shell, stem + leaf + vine curl, hay bands, berries, glowing jack-o' face |

Egg stands / pedestals in the hub belong to the hub builder (B8e); place an egg at the stand top.

## 4. Crates (`crates.py`)

* **Origin** = ground centre; badge faces −Z. Body pieces stay; `Lid*` opens about
  `joints Lid@(0,bodyTop,depth/2)` (back top edge). Positive angle about +X raises the front edge;
  open ~105° then let it bounce (`crates-studio.jpg` shows an opened Supply Crate).

| Key | Size | Look |
|---|---|---|
| `SupplyCrate` | body 3.2 × 2.1 × 2.6, 2.66 tall with lid | wooden slats, dark-steel brackets + rivets, hazard kick band, yellow badge + Neon trefoil, rope handle |
| `MegaCrate` | body 3.8 × 2.5 × 3.0, 3.86 tall with lid gem | purple armour, gold trim + corner caps, Neon cyan seams, gold star badge, pink lid gem |
| `GoldenCrate` | body 3.6 × 2.4 × 2.8, 3.58 tall with crown | all gold, white trim, pink gem studs, Neon sparkles + star badge, crown-point lid, glowing blue gem |

## 5. Attack mode (`attack.py`)

**Projectiles** (`NukeT1`..`NukeT5`, `Interceptor`): origin = rocket centre, **nose toward −Z** —
render the server-timed arc with `model:PivotTo(CFrame.lookAt(pos, pos + velocity))`. `Exhaust`
(Neon candy flame) trails toward +Z. Badges + trefoils on both sides (readable side-on).

| Key | Length | Look |
|---|---|---|
| `NukeT1` | 4.5 | red stud body, white nose, 3 yellow fins, green core |
| `NukeT2` | 5.5 | mint body, white nose, 4 red fins, white stripe |
| `NukeT3` | 6.5 | purple body, yellow nose, pink fins, 2 stripes, 2 side boosters |
| `NukeT4` | 7.5 | orange body, white nose, blue fins, 4 boosters, double core |
| `NukeT5` | 9.0 | gold body, pink nose, white fins, 4 boosters, gold crown ring, Neon stars |
| `Interceptor` | 3.4 | slim white AA missile, sky-blue nose + fins + canards, red band, blue exhaust |

**AA towers** (`AATower1`..`AATower5`): origin = pad ground centre; barrels point −Z at rest.
`Turret*` yaw about the `Turret` joint (+Y); `Barrel*` pitch about the `Barrel` joint (+X,
positive raises the muzzle) and ride on the turret — rotate the barrel joint by the turret yaw
first (see `spawn_b8f_preview.luau`, `AATower4_Aimed`). Map the 1-50 upgrade levels onto the five
visual levels (e.g. `math.clamp(math.ceil(level / 10), 1, 5)`).

| Key | Name | Height / pad | Look |
|---|---|---|---|
| `AATower1` | Pop Gun | 4.9 / 5 × 5 | red stud post, white turret, 1 barrel |
| `AATower2` | Twin Popper | 6.8 / 6 × 6 | blue post, dome turret + visor, 2 barrels, red beacon |
| `AATower3` | Truss Tower | 10.0 / 7 × 7 | yellow lattice tower, steel deck, blue turret, 2 braked barrels, radar dish |
| `AATower4` | Quad Blaster | 10.5 / round 8.4 | purple armoured tank tower with gold bands + Neon ring, white turret, 4 barrels, dish |
| `AATower5` | Mega Defender | 14.2 / 12 × 12 | hazard-striped pad, 4 glowing pylons, gold tower + Neon halo + trefoils, dome turret, missile pods, 4 barrels, big dish |

**`ShieldDome`**: one `Glass` piece (sky glow, transparency 0.55), hex Goldberg dome of radius 50
(frequency-4 geodesic dual: hexes + 6 pentagons, 10 % gaps, double-sided thin tiles, 1,796 tris).
Scale with `Model:ScaleTo(r / 50)` or set `Shield.Size` for an elliptical dome over a plot; the
runtime may switch `Material` to `ForceField`. Collision is the runtime's job (it is visual only).

**`ConfettiCloud`**: hit effect ~11.8 tall × 13.5 wide at scale 1: cream ground skirt (`Base`), lime
puff stem (`Stem`), white puff ring (`Ring`), warm-yellow cap dome with a smiling face and blush
(`Cap`, `CapFace`, `CapShine`, `CapBlush`), Neon stars (`Stars`) and pink / blue / purple confetti
(`ConfettiA/B/C`). Tween groups in that order from ~0.2 scale, hold, then fade; scale the whole
model for bigger tiers. Pair it with the "BOOM!" pop BillboardGui (UI owner).

## 6. Harvest Feast items (`event_items.py`)

| Key | Notes |
|---|---|
| `GoldenTurkey` | wandering collectible, 3.1 tall, faces −Z. `Head*` bob/peck, `Tail`/`TailB` fan, `FeetL`/`FeetR` alternate waddle about the hips, Neon `Glow` sparkles pulse |
| `FeastSticker` | sticker token, disc centre y = 1.6, decorated on both faces; spin about +Y. Also the sheet-slot sticker (scale 0.55) |
| `FeastStickerPlaque` | sticker sheet board (11.7 wide × 10.2 tall on posts). Banner front takes a SurfaceGui. 20 sockets at x = −3.8 + 1.9c (c 0..4), y = 6.35 − 1.6r (r 0..3), z = −0.42 |
| `Acorn` | currency pickup, 1.7 tall, happy face toward −Z; bob + spin |
| `Pie` | pumpkin pie prop, 3.0 wide × 1.05 tall |

Event decor in the event square (hay bales, pumpkins, cornucopia, string lights) is the hub
builder's (B8e).

---

## 7. Catalogue (generated from `assets/blender/world/manifest.json` + `mesh-ids.json`)

Colours are the authored RGB (`MeshAssets[key].pieces[name].color`); pieces without a material
note use the stud material. "Uploaded" = the MeshIds in `mesh-ids.json` match the current
manifest hashes (so `sync_meshes.py` ships real meshes, not the primitive fallback).

### Pets

| Key | Rarity | Hover | Tris | Joints (model space) | Pieces (colour, non-stud material) | Uploaded |
|---|---|---|---|---|---|---|
| `GlowSlime` | Common | 0 | 1142 | — | `Body` #96E63C Glass t0.3, `Face` #24242E Smooth, `Glow` #6EFF5A Neon, `Shine` #FCFCFF Smooth | yes |
| `AtomPup` | Common | 0 | 2304 | Head(0,1.11,-0.11) Tail(0,0.82,0.74) | `Body` #FFC86E, `Collar` #E84038, `Glow` #6EFF5A Neon, `Head` #FFC86E, `HeadAccent` #FAE8BE, `HeadEars` #A4683A, `HeadFace` #24242E Smooth, `HeadShine` #FCFCFF Smooth, `Tail` #FFC86E | yes |
| `IsotopeKitty` | Common | 0 | 2020 | Head(0,1.11,-0.11) Tail(0,0.76,0.74) | `Belly` #FCFCFF, `Body` #BE96FF, `Head` #BE96FF, `HeadAccent` #FF96AA Smooth, `HeadFace` #24242E Smooth, `HeadGlow` #6EFF5A Neon, `HeadShine` #FCFCFF Smooth, `Tail` #BE96FF | yes |
| `QuarkDuck` | Common | 0 | 1540 | Head(0,1.08,-0.15) WingL(-0.5,0.82,0.05) WingR(0.5,0.82,0.05) | `Body` #FFD632, `Feet` #FF9228 Smooth, `Glow` #6EFF5A Neon, `Head` #FFD632, `HeadBill` #FF9228 Smooth, `HeadFace` #24242E Smooth, `HeadShine` #FCFCFF Smooth, `WingL` #FFD632, `WingR` #FFD632 | yes |
| `UraniumBunny` | Uncommon | 0 | 2134 | Head(0,1.06,-0.06) Tail(0,0.72,0.74) | `Belly` #FCFCFF, `Body` #6EDEAA, `Glow` #6EFF5A Neon, `Head` #6EDEAA, `HeadAccent` #FF96AA Smooth, `HeadFace` #24242E Smooth, `HeadShine` #FCFCFF Smooth, `Tail` #FCFCFF | yes |
| `NeutronNewt` | Uncommon | 0 | 1752 | Head(0,0.5,-0.38) Tail(0,0.42,0.8) | `Belly` #FFD632, `Body` #FF8856, `Glow` #6EFF5A Neon, `Head` #FF8856, `HeadFace` #24242E Smooth, `HeadShine` #FCFCFF Smooth, `Tail` #FF8856 | yes |
| `PlasmaPig` | Uncommon | 0 | 1830 | Head(0,1.12,-0.1) Tail(0,0.86,0.84) | `Body` #FFA8C4, `Glow` #DC46DC Neon, `Head` #FFA8C4, `HeadFace` #24242E Smooth, `HeadShine` #FCFCFF Smooth, `HeadSnout` #EE7098, `Hooves` #EE7098, `Tail` #FFA8C4 | yes |
| `MegaMole` | Uncommon | 0 | 1670 | — | `Body` #988090, `Face` #24242E Smooth, `Glow` #FFE65A Neon, `Helmet` #FFCE24, `Nose` #FF78B4, `Shine` #FCFCFF Smooth | yes |
| `FissionFox` | Rare | 0 | 2710 | Head(0,1.11,-0.11) Tail(0,0.82,0.76) Orbit(0,1.05,0) | `Belly` #FCFCFF, `Body` #FF8A30, `Head` #FF8A30, `HeadAccent` #FCFCFF, `HeadFace` #24242E Smooth, `HeadShine` #FCFCFF Smooth, `Orbit` #6EFF5A Neon, `Tail` #FF8A30, `TailTip` #FCFCFF | yes |
| `ReactorOwl` | Rare | 0.8 | 1864 | WingL(-0.62,1.2,0.05) WingR(0.62,1.2,0.05) Orbit(0,1.05,0) | `Beak` #FF9228 Smooth, `Belly` #FAE8BE, `Body` #4696CD, `Face` #24242E Smooth, `Glow` #6EFF5A Neon, `Orbit` #6EFF5A Neon, `Shine` #FCFCFF Smooth, `WingL` #2E68A0, `WingR` #2E68A0 | yes |
| `ProtonPanda` | Rare | 0 | 2530 | Head(0,1.12,-0.11) Orbit(0,1.05,0) | `Body` #FCFCFF, `Glow` #FF50A0 Neon, `Head` #FCFCFF, `HeadBlack` #24242E, `HeadShine` #FCFCFF Smooth, `Limbs` #24242E, `Orbit` #FF50A0 Neon | yes |
| `GammaGator` | Rare | 0 | 2124 | Head(0,0.6,-0.38) Tail(0,0.45,0.85) Orbit(0,0.8,0.1) | `Belly` #FAE8BE, `Body` #60C25A, `Glow` #96E63C Neon, `Head` #60C25A, `HeadFace` #24242E Smooth, `HeadShine` #FCFCFF Smooth, `HeadTeeth` #FCFCFF Smooth, `Orbit` #6EFF5A Neon, `Tail` #60C25A | yes |
| `NuclearNarwhal` | Epic | 1 | 1962 | Tail(0,0.85,0.85) WingL(-0.58,0.42,-0.15) WingR(0.58,0.42,-0.15) Orbit(0,0.75,0.05) | `Belly` #FCFCFF, `Body` #609CEC, `Face` #24242E Smooth, `Horn` #FFE65A Neon, `Orbit` #78E6FF Neon, `Shine` #FCFCFF Smooth, `Tail` #609CEC, `WingL` #609CEC, `WingR` #609CEC | yes |
| `CosmicCorgi` | Epic | 0 | 2326 | Head(0,1.01,-0.13) Tail(0,0.78,0.9) | `Belly` #FCFCFF, `Body` #F6963E, `Glow` #FFE65A Neon, `Head` #F6963E, `HeadAccent` #FCFCFF, `HeadFace` #24242E Smooth, `HeadHelmet` #B4E2FF Glass t0.6, `HeadRing` #BEC4D2, `HeadShine` #FCFCFF Smooth, `Tail` #F6963E | yes |
| `RadRaccoon` | Epic | 0 | 2758 | Head(0,1.11,-0.11) Tail(0,0.8,0.74) Orbit(0,1.05,0) | `Body` #9698A8, `Head` #9698A8, `HeadMask` #24242E, `HeadWhite` #FCFCFF Smooth, `Orbit` #6EFF5A Neon, `Tail` #9698A8, `TailGlow` #6EFF5A Neon | yes |
| `AtomicAxolotl` | Epic | 0.4 | 2444 | Head(0,0.62,-0.2) Tail(0,0.48,0.88) Orbit(0,0.75,0.15) | `Body` #FFACCC, `Head` #FFACCC, `HeadFace` #24242E Smooth, `HeadGlow` #DC46DC Neon, `HeadShine` #FCFCFF Smooth, `Orbit` #FF50A0 Neon, `Tail` #FFACCC | yes |
| `MeltdownMoose` | Legendary | 0 | 2638 | Head(0,1.24,-0.11) Tail(0,1.05,0.86) Orbit(0,1.2,0.05) | `Body` #B07048, `Head` #B07048, `HeadAntlers` #FFC42E, `HeadFace` #24242E Smooth, `HeadGlow` #6EFF5A Neon, `HeadMuzzle` #E2B482, `HeadShine` #FCFCFF Smooth, `Hooves` #623E2A, `Orbit` #6EFF5A Neon, `Tail` #B07048 | yes |
| `FusionPhoenix` | Legendary | 1 | 1256 | Head(0,1.05,-0.12) WingL(-0.36,0.95,0.1) WingR(0.36,0.95,0.1) Tail(0,0.62,0.6) | `Body` #FF8428, `Glow` #FFE65A Neon, `Head` #FF8428, `HeadBeak` #FFD632 Smooth, `HeadCrest` #FFE65A Neon, `HeadFace` #24242E Smooth, `HeadShine` #FCFCFF Smooth, `Tail` #FFD632, `WingL` #FF563C, `WingR` #FF563C | yes |
| `ReactorRex` | Legendary | 0 | 2524 | Head(0,1.28,-0.12) Tail(0,0.6,0.66) Orbit(0,1.1,0.1) | `Belly` #FFD632, `Body` #7ECC54, `Glow` #6EFF5A Neon, `Head` #7ECC54, `HeadCrown` #FFC42E, `HeadFace` #24242E Smooth, `HeadGem` #E84038 Smooth, `HeadShine` #FCFCFF Smooth, `Orbit` #6EFF5A Neon, `Tail` #7ECC54 | yes |
| `CoreDragon` | Mythic | 0.9 | 2164 | Head(0,1.15,-0.08) WingL(-0.34,1.05,0.38) WingR(0.34,1.05,0.38) Tail(0,0.5,0.68) Orbit(0,1.1,0.1) | `Body` #9660DC, `Glow` #6EFF5A Neon, `Head` #9660DC, `HeadFace` #24242E Smooth, `HeadHorns` #FFC42E, `HeadShine` #FCFCFF Smooth, `Orbit` #FFE65A Neon, `Tail` #9660DC, `WingL` #BE96FF, `WingR` #BE96FF | yes |
| `NovaUnicorn` | Mythic | 0 | 2766 | Head(0,1.28,-0.13) Tail(0,1.08,0.84) Orbit(0,2.3,-0.2) | `Body` #FCFCFF, `Glow` #DC46DC Neon, `Head` #FCFCFF, `HeadFace` #24242E Smooth, `HeadHorn` #FFE65A Neon, `HeadMane` #FF50A0, `HeadShine` #FCFCFF Smooth, `Hooves` #FFC42E, `Orbit` #FFE65A Neon, `Tail` #FF50A0 | yes |
| `IonJelly` | Mythic | 1 | 2486 | Tail(0,1.2,0) Orbit(0,2.3,0) | `Body` #78E6FF Glass t0.35, `Face` #24242E Smooth, `Glow` #DC46DC Neon, `Orbit` #FFE65A Neon, `Shine` #FCFCFF Smooth, `Tail` #BE96FF | yes |
| `GoldenNukey` | Secret | 0 | 2122 | Orbit(0,1.2,0) | `Body` #FFC42E, `Crown` #FFC42E Smooth, `CrownGems` #FF50A0 Smooth, `Face` #24242E Smooth, `Fins` #D6961E, `Glow` #6EFF5A Neon, `Nose` #FCFCFF, `Orbit` #6EFF5A Neon, `Shine` #FCFCFF Smooth | yes |
| `VoidCat` | Secret | 0.3 | 2596 | Head(0,1.11,-0.11) Tail(0,0.76,0.74) Orbit(0,1.05,0) | `Body` #2C2254, `Glow` #E6D2FF Neon, `Head` #2C2254, `HeadAccent` #BE96FF Smooth, `HeadFace` #78E6FF Neon, `Orbit` #DC46DC Neon, `Tail` #2C2254 | yes |
| `BuilderBeaver` | Group | 0 | 2332 | Head(0,1.11,-0.11) Tail(0,0.3,0.75) | `Belly` #E6BE8C, `Body` #A06640, `Head` #A06640, `HeadFace` #24242E Smooth, `HeadGlow` #6EFF5A Neon, `HeadHat` #FFCE24, `HeadMuzzle` #E6BE8C, `HeadShine` #FCFCFF Smooth, `Tail` #604030 | yes |
| `GobbleBomb` | Event | 0 | 1716 | Head(0,1.4,-0.42) Tail(0,1.12,0.6) | `Band` #E67026, `Body` #965C34, `Glow` #FFE65A Neon, `Head` #C48A5C, `HeadBeak` #FFD632 Smooth, `HeadFace` #24242E Smooth, `HeadShine` #FCFCFF Smooth, `HeadWattle` #E23640 Smooth, `Tail` #E67026, `TailB` #FFD632 | yes |
| `AcornSquirrel` | Harvest | 0 | 2202 | Head(0,1.06,-0.08) Tail(0,0.55,0.6) | `AcornCap` #A4683A, `Belly` #FAE8BE, `Body` #CE703A, `Glow` #FFE65A Neon, `Head` #CE703A, `HeadAccent` #FAE8BE, `HeadFace` #24242E Smooth, `HeadShine` #FCFCFF Smooth, `Tail` #CE703A | yes |
| `HarvestHedgehog` | Harvest | 0 | 1974 | — | `Body` #E8C496, `Face` #24242E Smooth, `Glow` #E23640 Neon, `Leaf` #E67026 Smooth, `Shine` #FCFCFF Smooth, `Spikes` #623E2A | yes |
| `CranberryCrab` | Harvest | 0 | 1586 | ClawL(-0.62,0.6,-0.35) ClawR(0.62,0.6,-0.35) | `Body` #CE284A, `ClawL` #E84660, `ClawR` #E84660, `Face` #24242E Smooth, `Glow` #FF7896 Neon, `Leaf` #46BA4A Smooth, `Shine` #FCFCFF Smooth | yes |

### Eggs

| Key | Tris | Joints / hinge | Pieces (colour, non-stud material) | Uploaded |
|---|---|---|---|---|
| `GarageEgg` | 1904 | ShellTop(0,1.34,1.15) | `ShellBottom` #60A8EC, `ShellBottomGlow` #6EFF5A Neon, `ShellBottomHazardBlack` #2C2C36, `ShellBottomHazardYellow` #FFCE24, `ShellTop` #60A8EC, `ShellTopBolts` #969EAC Smooth, `ShellTopDeco` #F4F4F8 | yes |
| `StandEgg` | 2816 | ShellTop(0,1.34,1.15) | `ShellBottom` #FFD632, `ShellBottomCoinMark` #D6961E Smooth, `ShellBottomCoins` #FFC42E Smooth, `ShellTop` #FFD632, `ShellTopAwning` #E84038, `ShellTopStripe` #F4F4F8 | yes |
| `BoomDashEgg` | 1916 | ShellTop(0,1.34,1.15) | `ShellBottom` #E84038, `ShellBottomHubs` #F4F4F8 Smooth, `ShellBottomWheels` #343640, `ShellTop` #E84038, `ShellTopBolt` #FFD632, `ShellTopLines` #F4F4F8 | yes |
| `MineEgg` | 1880 | ShellTop(0,1.34,1.15) | `ShellBottom` #B6B8C2, `ShellBottomCrystals` #6EFF5A Neon, `ShellBottomRock` #8C8E9A, `ShellTop` #B6B8C2, `ShellTopCrystals` #6EFF5A Neon, `ShellTopRock` #8C8E9A | yes |
| `LabEgg` | 2048 | ShellTop(0,1.34,1.15) | `ShellBottom` #FCFCFF, `ShellBottomBadge` #FFCE24 Smooth, `ShellBottomBand` #6EDEAA, `ShellBottomMark` #2C2C36 Smooth, `ShellTop` #FCFCFF, `ShellTopBubbles` #6EFF5A Neon | yes |
| `FactoryEgg` | 2644 | ShellTop(0,1.34,1.15) | `ShellBottom` #FF9228, `ShellBottomHazardBlack` #2C2C36, `ShellBottomHazardYellow` #FFCE24, `ShellTop` #FF9228, `ShellTopGears` #5C6270, `ShellTopHubs` #969EAC Smooth | yes |
| `SiloEgg` | 2140 | ShellTop(0,1.34,1.15) | `ShellBottom` #969EAC, `ShellBottomFins` #E84038, `ShellBottomHazardBlack` #2C2C36, `ShellBottomHazardYellow` #FFCE24, `ShellTop` #969EAC, `ShellTopBadge` #FFCE24 Smooth, `ShellTopGlow` #6EFF5A Neon, `ShellTopNose` #E84038 | yes |
| `MegastoreEgg` | 1576 | ShellTop(0,1.34,1.15) | `ShellBottom` #FF78B4, `ShellBottomStars` #FFC42E, `ShellBottomTag` #9660DC, `ShellBottomTagHole` #FCFCFF Smooth, `ShellTop` #FF78B4, `ShellTopSparkle` #FFE65A Neon, `ShellTopStars` #FFC42E | yes |
| `SpaceEgg` | 1976 | ShellTop(0,1.34,1.15) | `ShellBottom` #28346E, `ShellBottomPlanet` #FF9228, `ShellBottomPlanetRing` #FCFCFF Smooth, `ShellBottomStars` #FFE65A Neon, `ShellTop` #28346E, `ShellTopCraters` #8C8E9A Smooth, `ShellTopMoon` #FAE8BE, `ShellTopStars` #FFE65A Neon | yes |
| `MegaEgg` | 2656 | ShellTop(0,1.34,1.15) | `ShellBottom` #FFC42E, `ShellBottomGlow` #6EFF5A Neon, `ShellTop` #FFC42E, `ShellTopCrown` #D6961E, `ShellTopGems` #FF50A0 Smooth, `ShellTopGlow` #6EFF5A Neon | yes |
| `HarvestEgg` | 2480 | ShellTop(0,1.34,1.15) | `ShellBottom` #F08028, `ShellBottomBerries` #E23640 Smooth, `ShellBottomHay` #F6D66E, `ShellTop` #F08028, `ShellTopGlow` #FFE65A Neon, `ShellTopLeaf` #46BA4A, `ShellTopStem` #A4683A | yes |

### Crates

| Key | Tris | Joints / hinge | Pieces (colour, non-stud material) | Uploaded |
|---|---|---|---|---|
| `SupplyCrate` | 1928 | Lid(0,2.1,1.3) | `Box` #D69656, `Glow` #6EFF5A Neon, `HazardBlack` #2C2C36, `HazardYellow` #FFCE24, `Lid` #D69656, `LidTrim` #5C6270, `Slats` #A4683A, `Trim` #5C6270 | yes |
| `MegaCrate` | 1348 | Lid(0,2.5,1.5) | `Badge` #D6961E, `Box` #9660DC, `Glow` #78E6FF Neon, `Lid` #9660DC, `LidGem` #FF50A0 Smooth, `LidTrim` #FFC42E, `Trim` #FFC42E | yes |
| `GoldenCrate` | 1492 | Lid(0,2.4,1.4) | `Badge` #D6961E, `Box` #FFC42E, `Gems` #FF50A0 Smooth, `Glow` #FFE65A Neon, `Lid` #FFC42E, `LidCrown` #D6961E, `LidGem` #78E6FF Neon, `LidTrim` #FCFCFF, `Trim` #FCFCFF | yes |

### Attack mode

| Key | Tris | Joints / hinge | Pieces (colour, non-stud material) | Uploaded |
|---|---|---|---|---|
| `NukeT1` | 1168 | — | `Badge` #FFCE24 Smooth, `Body` #E84038, `Core` #6EFF5A Neon, `Exhaust` #FFAA3C Neon, `Fins` #FFD632, `Nose` #FCFCFF, `Trefoil` #2C2C36 Smooth, `Trim` #5C6270 | yes |
| `NukeT2` | 1308 | — | `Badge` #FFCE24 Smooth, `Body` #6EDEAA, `Core` #6EFF5A Neon, `Exhaust` #FFAA3C Neon, `Fins` #E84038, `Nose` #FCFCFF, `Stripes` #FCFCFF, `Trefoil` #2C2C36 Smooth, `Trim` #5C6270 | yes |
| `NukeT3` | 1772 | — | `Badge` #FFCE24 Smooth, `Body` #9660DC, `Core` #6EFF5A Neon, `Exhaust` #FFAA3C Neon, `Fins` #FF50A0, `Nose` #FFD632, `Stripes` #FCFCFF, `Trefoil` #2C2C36 Smooth, `Trim` #5C6270 | yes |
| `NukeT4` | 2236 | — | `Badge` #FFCE24 Smooth, `Body` #FF9228, `Core` #6EFF5A Neon, `Exhaust` #FFAA3C Neon, `Fins` #3468C4, `Nose` #FCFCFF, `Stripes` #FCFCFF, `Trefoil` #2C2C36 Smooth, `Trim` #5C6270 | yes |
| `NukeT5` | 2556 | — | `Badge` #FFCE24 Smooth, `Body` #FFC42E, `Core` #6EFF5A Neon, `Crown` #D6961E, `Exhaust` #FFAA3C Neon, `Fins` #FCFCFF, `Nose` #FF50A0, `Stars` #FFE65A Neon, `Stripes` #FCFCFF, `Trefoil` #2C2C36 Smooth, `Trim` #5C6270 | yes |
| `Interceptor` | 312 | — | `Band` #E84038 Smooth, `Body` #FCFCFF, `Exhaust` #78E6FF Neon, `Fins` #60A8EC, `Nose` #60A8EC | yes |
| `AATower1` | 1444 | Turret(0,3.4,0) Barrel(0,4.15,-0.6) | `Barrel` #5C6270, `BarrelTip` #E84038, `Base` #B6B8C2, `Glow` #6EFF5A Neon, `HazardBlack` #2C2C36, `HazardYellow` #FFCE24, `Tower` #E84038, `TowerTrim` #FCFCFF, `Turret` #FCFCFF, `TurretTrim` #5C6270 | yes |
| `AATower2` | 1788 | Turret(0,4.8,0) Barrel(0,5.35,-0.8) | `Barrel` #5C6270, `BarrelTip` #E84038, `Base` #B6B8C2, `Glow` #6EFF5A Neon, `HazardBlack` #2C2C36, `HazardYellow` #FFCE24, `Tower` #60A8EC, `TowerTrim` #FCFCFF, `Turret` #FCFCFF, `TurretGlow` #E84038 Neon, `TurretTrim` #60A8EC | yes |
| `AATower3` | 2548 | Turret(0,6.95,0) Barrel(0,7.9,-0.9) | `Barrel` #5C6270, `BarrelTip` #E84038, `Base` #B6B8C2, `Glow` #6EFF5A Neon, `HazardBlack` #2C2C36, `HazardYellow` #FFCE24, `Tower` #FFCE24, `TowerTrim` #5C6270, `Turret` #60A8EC, `TurretDish` #FCFCFF, `TurretTrim` #FCFCFF | yes |
| `AATower4` | 2756 | Turret(0,6.7,0) Barrel(0,7.8,-1.1) | `Barrel` #5C6270, `BarrelTip` #E84038, `Base` #B6B8C2, `Glow` #6EFF5A Neon, `HazardBlack` #2C2C36, `HazardYellow` #FFCE24, `Tower` #9660DC, `TowerTrim` #FFC42E, `Turret` #FCFCFF, `TurretDish` #FCFCFF, `TurretTrim` #9660DC | yes |
| `AATower5` | 4832 | Turret(0,9.6,0) Barrel(0,11,-1.4) | `Barrel` #5C6270, `BarrelTip` #E84038, `Base` #B6B8C2, `Glow` #6EFF5A Neon, `HazardBlack` #2C2C36, `HazardYellow` #FFCE24, `Tower` #FFC42E, `TowerTrim` #FCFCFF, `Turret` #FCFCFF, `TurretDish` #FCFCFF, `TurretTrim` #D6961E | yes |
| `ShieldDome` | 1796 | — | `Shield` #78E6FF Glass t0.55 | yes |
| `ConfettiCloud` | 4082 | Base(0,0.8,0) Stem(0,3.7,0) Ring(0,3.9,0) Cap(0,7.6,0) Stars(0,6.5,0) ConfettiA(0,6,0) ConfettiB(0,6,0) ConfettiC(0,6,0) | `Base` #FFF8E2, `Cap` #FFE470, `CapBlush` #FF78B4 Smooth, `CapFace` #24242E Smooth, `CapShine` #FCFCFF Smooth, `ConfettiA` #FF50A0 Smooth, `ConfettiB` #60A8EC Smooth, `ConfettiC` #9660DC Smooth, `Ring` #FCFCFF, `Stars` #FFE65A Neon, `Stem` #CEFF96 | yes |

### Harvest Feast items

| Key | Tris | Joints / hinge | Pieces (colour, non-stud material) | Uploaded |
|---|---|---|---|---|
| `GoldenTurkey` | 1820 | Head(0,1.9,-0.45) Tail(0,1.45,0.8) FeetL(-0.36,0.72,0.05) FeetR(0.36,0.72,0.05) | `Body` #FFC42E, `FeetL` #FF9228 Smooth, `FeetR` #FF9228 Smooth, `Glow` #FFE65A Neon, `Head` #FFC42E, `HeadBeak` #FF9228 Smooth, `HeadFace` #24242E Smooth, `HeadWattle` #E23640 Smooth, `Tail` #FFC42E, `TailB` #E67026 | yes |
| `FeastSticker` | 828 | — | `Border` #FCFCFF, `Emblem` #E23640 Smooth, `Face` #E67026, `Glow` #FFE65A Neon | yes |
| `FeastStickerPlaque` | 2780 | — | `Banner` #E67026, `Board` #D69656, `Frame` #FFC42E, `Glow` #FFE65A Neon, `Leaves` #E23640 Smooth, `LeavesGold` #D6961E Smooth, `Posts` #A4683A, `Slots` #FAE8BE Smooth, `Wire` #46BA4A Smooth | yes |
| `Acorn` | 1358 | — | `Cap` #A4683A, `Face` #24242E Smooth, `Glow` #FFE65A Neon, `Nut` #E8AC62, `Shine` #FCFCFF Smooth | yes |
| `Pie` | 1724 | — | `Cream` #FCFCFF Smooth, `Crust` #E2A454, `Filling` #EC7A28, `Tin` #969EAC | yes |

---

## 8. Verification

Blender previews (Workbench, tinted studs — darker than in game):

* `docs/verification/world-art/pets-blender-iso.jpg`, `pets-blender-front.jpg` — all 29 pets
* `docs/verification/world-art/eggs-blender.jpg` — 11 eggs (front)
* `docs/verification/world-art/attack-blender-iso.jpg` — rockets, interceptor, towers, dome, cloud
* `docs/verification/world-art/crates-events-blender-iso.jpg` — crates + Harvest Feast items

Studio (edit mode, real MeshLibrary + stud MaterialVariants, `spawn_b8f_preview.luau`):

* (Studio lineup screenshots pending the shared Studio lock — see §9.)

## 9. Next steps / notes for the runtime owners

* **Pets runtime (B9)**: ids = model keys above. Read `hover` + `joints` from the pivot string;
  animate by group prefix (§1). Suggested motion: walkers hop (0.25 stud, 0.35 s) and tilt; floaters
  bob ±0.25 around `hover`; `Tail` wag ±20° about Y; `Wing*` flap ±35° about Z (mirrored);
  `Head*` nod ±8°; `Orbit` spin 90°/s about +Y; pulse `Glow` transparency 0 ↔ 0.25.
  Respect `settings.hideOtherPets` and reduced motion.
* **Eggs / crates (B9)**: hatch + reveal recipes in §3 / §4; MeshLibrary.preload the egg keys of
  the hub stands at boot.
* **Attack mode (B10)**: projectile tier → `NukeT1..5`; `Interceptor` for AA shots;
  `AATower1..5` by visual level; `ShieldDome` scaled to the plot; `ConfettiCloud` at the hit point
  (client FX only; pool the clones — no per-frame `Instance.new`).
* **Harvest Feast (B11)**: `GoldenTurkey` wanders (server-owned position, client waddle), drops
  `Acorn`; `FeastStickerPlaque` sockets map 1:1 to sticker ids 1-20 (row-major); `Pie` is decor /
  reward; `HarvestEgg` + Harvest pets; `GobbleBomb` = sheet reward.
* Pets are modelled at scale 1; the runtime may `ScaleTo(1.15)` for Legendary+ to add presence.

---

## 10. World 2 "Dino Valley" pets + eggs (W11, owner R57 — 2026-10-30)

Spec: `docs/superpowers/specs/2026-10-31-world2-design.md` §8 / §16. Same contract as §1–§3
(Roblox space, front = −Z, one colour per piece, stud material, ≤ 10 pieces + ≤ 2,800 tris per pet,
≤ 3,000 per egg, small Neon accents only — R19). Kid-friendly (spec §2): round, big-eyed, smiling
dinos; no teeth or claws; every horn, spike, beak and tail club ends in a round ball; lava is
candy-orange glow.

| Builder | Models |
|---|---|
| `tools/blender/models/pets_dino.py` | 8 Dino egg pets + the Time Ptero (imports the pets.py helpers `_pet` / `_done` / `_face` / `_legs` / `_tail` / `_orbit` / `_wing_plate` …; adds biped legs, tiny arms, feather crests, ptero wings with Neon vein ridges, ball-tipped spikes) |
| `tools/blender/models/eggs_dino.py` | `DinoEgg`, `VolcanoEgg` on eggs.py's `build_shell` / `egg_frame` / zig-zag crack, plus surface-hugging decals (`_surface_decal`, `_curved_tile`, `_lava_cap`: every vertex projected onto the shell with `egg_frame`, so nothing lifts off the curve) and a build-time crack-band guard |

```bash
KEYS=AtomRaptor,GlowStego,FissionTrike,PocketBronto,EmberAnkylo,MagmaPtero,LavaPara,SupernovaSpino,TimePtero,DinoEgg,VolcanoEgg
/opt/homebrew/bin/blender -b --python tools/blender/generate_world.py -- --only $KEYS
python3 tools/blender/contact_sheet.py --only $KEYS --out assets/blender/previews/_sheet_dino_pets_iso.jpg
python3 tools/blender/upload_meshes.py --user-id 1586034782 --only AtomRaptor GlowStego FissionTrike PocketBronto EmberAnkylo MagmaPtero LavaPara SupernovaSpino TimePtero DinoEgg VolcanoEgg
python3 tools/blender/sync_meshes.py && lune run tests/mesh-assets
```

### Pets (all uploaded 2026-10-30; joints in each pivot string)

| Key | Rarity (egg) | Hover → PetAnim style | Height | Tris | Pieces (animation groups) |
|---|---|---|---|---|---|
| `AtomRaptor` | Uncommon (Dino) | 0 → Walk | 2.41 | 2,460 | Body (biped legs + tiny arms), Belly, Glow (back spots + the hugged Neon atom pebble), Head (+ snout), HeadFace, HeadShine, HeadCrest (mohawk + front-facing side feathers), Tail, TailTuft (feather tuft + 2 stripes) |
| `GlowStego` | Rare (Dino) | 0 → Walk | 1.77 | 2,528 | Body, Belly, Glow (5 amber Neon back plates), Head (+ snout), HeadFace, HeadShine, Tail, TailSpikes (4 ball-tipped, splayed sideways), Orbit |
| `FissionTrike` | Epic (Dino) | 0 → Walk | 1.93 | 2,792 | Body, Belly, Head, HeadFace, HeadShine, HeadHorns (beak + 3 ball-tipped horns), HeadFrill (scalloped half disc), HeadGlow (Neon frill rim + 3 atom dots; pulses, moves with the head), Tail, Orbit (2 electrons) |
| `PocketBronto` | Legendary (Dino) | 0 → Walk | 2.41 | 2,794 | Body, Belly, Head (whole long neck + head: nods / looks about the neck base), HeadFace, HeadShine, HeadCrown (gold), HeadGem, Glow (sun spots), Tail (curl), Orbit (2 rings) |
| `EmberAnkylo` | Rare (Volcano) | 0 → Walk | 1.39 | 2,732 | Body (warm orange), Spikes (lava-yellow armour bumps; squash with the body), Head (+ cheek knobs), HeadFace, HeadShine, Glow (red-hot ember glints), Tail, TailClub (lava yellow), TailGlow, Orbit |
| `MagmaPtero` | Epic (Volcano) | 0.9 → Fly | 1.83 | 1,386 | Body (+ round feet, tail point), Glow (magma heart), Head (+ crest), HeadFace, HeadShine, HeadBeak (ball tip), WingL / WingR (membrane), WingLGlow / WingRGlow (Neon lava veins: same group as their wing) |
| `LavaPara` | Legendary (Volcano) | 0 → Walk | 2.34 | 2,780 | Body (biped, saturated magenta), Belly, Glow (lava stripes), Head, HeadFace, HeadShine, HeadBill (duck bill + smile), HeadCrest (gold tube crest), Tail, Orbit (2 rings) |
| `SupernovaSpino` | Mythic (Volcano) | 0 → Walk | 2.45 | 2,788 | Body (biped, electric violet), Belly, GlowSail (Neon pink star sail, pulses), Glow (4-point star spots), Head (+ snout), HeadFace, HeadShine, HeadStar (gold), Tail (+ fin), Orbit (2 rings) |
| `TimePtero` | Epic (Time Traveler Pack, fixed) | 1.0 → Fly | 1.78 | 2,138 | Body, Belly (cream clock dial), Glow (Neon ticks + hands at 10:00), Head (+ crest), HeadFace, HeadShine (also the goggle lenses), HeadBeak, HeadGoggles (brass strap + rims), WingL / WingR |

### Eggs (both uploaded; `joints ShellTop@(0,1.34,1.15)` like every area egg)

| Key | Egg | Shell (`ShellTop` = EggShards chip colour) | Pieces |
|---|---|---|---|
| `DinoEgg` | `dino_egg` | jungle lime #7EE434 | ShellTop / ShellBottom, ShellTop/BottomSpots (sunny-yellow surface blotches), ShellTop/BottomSpeckles (cream speckles; the top one carries the cartoon BONE — Bones currency — and the bottom one the three-toed footprint), ShellTopGlow (4 tiny pale Neon pebble glints) |
| `VolcanoEgg` | `volcano_egg` | crack yellow #FFCC30 | ShellTop / ShellBottom, ShellTop/BottomRock (55 orange-red #F25224 molten cobbles hugging the shell; the yellow shell shows as glowing "crackle" seams), ShellTopLava (Neon candy-orange lava cap with 7 rounded drips over the cobbles; largest box face ≈ 2.6 stud², under the 6 stud² R19 cap), ShellBottomGlow (pale-yellow ember glints on cobbles) |

The bare yellow / lime belt around the crack is deliberate: eggs.py keeps every decoration inside
`TOP_BAND` / `BOTTOM_BAND`, so the EggShards crack ribbons sit on clean shell. `eggs_dino.py`
asserts it at build time (a cobble row that reaches the band fails the build).

Previews: `assets/blender/previews/_sheet_dino_pets_iso.jpg`, `_sheet_dino_pets_front.jpg`
(opened for the owner, R12). Studio: `docs/verification/world2/pets/` (stand billboards, EggHatch
window on desktop / phone / tablet / console, both eggs cracking + revealing, dino pets following).

Vividness pass (lead / owner R47, 2026-10-30): judged with `tools/blender/viewport_look.py` (the
Workbench previews render at about half brightness). Dino Egg → jungle lime + sunny-yellow spots,
Volcano Egg → orange-red cobbles over yellow cracks with a candy-orange lava cap, Ember Ankylo →
warm orange + lava-yellow plates, Lava Para → magenta, Supernova Spino → electric violet. Before /
after: `docs/verification/world2/pets/dino-vividness-before-after.jpg` (re-uploaded + synced).

---

## 11. World 3 "Moon Base" pets + eggs (W11, owner R70 — 2026-10-31)

Spec: `docs/superpowers/specs/2026-10-31-r69-moon-lucky-juice-design.md` §2.5. Same contract as §1–§3
and §10 (≤ 10 pieces, ≤ 2,800 tris per pet, ≤ 3,000 per egg, stud material, small Neon only — R19).
Candy-vivid from the start (owner R47), judged with `tools/blender/viewport_look.py`. Every species
is a NEW mesh (no recolour of an older species); names checked against all 66 earlier pets.

| Builder | Models |
|---|---|
| `tools/blender/models/pets_moon.py` | 8 Moon / Comet Egg pets + the Rocket Corgi (reuses pets.py `_pet` / `_face` / `_legs` / `_tail` / `_orbit` / `_wing_plate` / ear helpers and pets_dino `_belly_patch` / `_round_spike`; adds `_crescent`, `_star_plate`) |
| `tools/blender/models/eggs_moon.py` | `MoonEgg`, `CometEgg` on eggs.py's cracked shell, decorated with eggs_dino's surface-hugging `_surface_decal` / `_surface_blotch`; `_check_crack_clear` fails the build if any ShellTop* / ShellBottom* decoration nears the crack |

```bash
KEYS=AstroPup,MoonBunny,OrbitOwl,CosmoCat,CometFox,SaucerOcto,GalaxyWhale,StarlightUnicorn,RocketCorgi,MoonEgg,CometEgg
/opt/homebrew/bin/blender -b --python tools/blender/generate_world.py -- --only $KEYS
python3 tools/blender/upload_meshes.py --user-id 1586034782 --only AstroPup MoonBunny OrbitOwl CosmoCat CometFox SaucerOcto GalaxyWhale StarlightUnicorn RocketCorgi MoonEgg CometEgg
python3 tools/blender/sync_meshes.py
```

### Pets (all uploaded 2026-10-31; joints in each pivot string)

| Key | Rarity (egg) | Hover → PetAnim style | Height | Tris | Pieces (animation groups) |
|---|---|---|---|---|---|
| `AstroPup` | Uncommon (Moon) | 0 → Walk | 2.43 | 2,532 | Body (snow white), Belly (sky-blue suit + neck ring), Pack (coral jetpack), Glow (Neon jets + chest star), Head (+ muzzle), HeadEars (lavender floppy), HeadFace, HeadShine, HeadAntenna (band + ball-tip antenna), Tail |
| `MoonBunny` | Rare (Moon) | 0 → **Hop** (override) | 2.53 | 2,218 | Body (lilac, big feet), Belly, Head (+ long ears), HeadEarsInner (pink + nose), HeadFace, HeadShine, HeadGlow (Neon crescent moon), Tail (cotton puff), Orbit |
| `OrbitOwl` | Epic (Moon) | 0.8 → Fly | 2.31 | 2,252 | Body (sunshine yellow, toes), Belly, Head, HeadShine (eye discs), HeadFace, HeadBeak (+ orange ear tufts), WingL / WingR, Orbit (banded Saturn ring: 2 bands + a tiny moon) |
| `CosmoCat` | Legendary (Moon) | 0 → Walk | 2.08 | 2,600 | Body (electric blue), Collar (gold + star tag), Glow (4-point star spots), Head (+ ears), HeadEarsInner (pink + nose), HeadFace, HeadShine, Tail, TailStar (gold), Orbit (2 pink rings) |
| `CometFox` | Rare (Comet) | 0 → Walk | 2.08 | 2,386 | Body (icy cyan), Belly, Head (+ ears), HeadAccent (white mask + inner ears), HeadFace, HeadShine, Tail (bushy, thickens to the tip), TailGlow (Neon comet star + 3 trail streaks), Orbit |
| `SaucerOcto` | Epic (Comet) | 0.6 → Float, tail **Sway** (override) | 1.58 | 2,262 | Body (silver-lilac saucer), Belly (violet underside), Glow (10 Neon rim bulbs), Dome (Glass t0.55), Head (coral octopus inside the dome), HeadSpots, HeadFace, HeadShine, Tail (6 curly tentacles under the saucer) |
| `GalaxyWhale` | Legendary (Comet) | 1.0 → **Swim**, tail Pitch (override) | 1.84 | 2,356 | Body (violet, tapered), Belly (pale + grooves), Face, Shine, Glow (star freckles + Neon star spout), Crown (gold), WingL / WingR (flippers), Tail (fluke), Orbit (2 rings) |
| `StarlightUnicorn` | Mythic (Comet) | 0.6 → Fly | 2.36 | 2,594 | Body (mint), Head (+ muzzle, ears), HeadMane (hot pink), HeadHorn (gold spiral, ball tip), HeadFace, HeadShine, WingL / WingR (Neon star-feather wings), Tail (pink), Orbit (pink ring, 2 star electrons) |
| `RocketCorgi` | Epic (Astronaut Pack, fixed) | 0.5 → Float | 2.05 | 2,082 | Body (orange corgi + paws gripping the hull + stubby tail), Belly (white chest + the toy rocket's hull), RocketFins (red ball-tip nose + 3 swept fins), Glow (Neon flame + 2 portholes), Head, HeadAccent (white muzzle + inner ears), HeadFace, HeadShine, HeadCap (red aviator cap + ear flaps) |

### Eggs (both uploaded; `joints ShellTop@(0,1.34,1.15)` like every egg)

| Key | Egg | Shell (`ShellTop` = EggShards chip colour) | Pieces |
|---|---|---|---|
| `MoonEgg` | `moon_egg` | candy lilac #C4AAFF | ShellTop / ShellBottom, ShellTop/BottomCraters (violet rims) + ShellTop/BottomCraterFloor (raised pale floors), ShellTopMoon (sunny crescent on the front), ShellTopStars (tiny Neon 4-point stars) |
| `CometEgg` | `comet_egg` | royal blue #406EFF | ShellTop / ShellBottom, ShellTopComet (Neon comet head + star specks, ≈ 0.35 stud²), ShellTopTrail (cyan streaks) + ShellTopTrailPink, ShellBottomStars (Neon specks), ShellBottomDots (a ring of cyan "planets") |

Look: `docs/verification/world2/pets/moon-pets-viewport-look.jpg` (opened for the owner, R12);
pipeline sheet `assets/blender/previews/_sheet_moon_pets_iso.jpg`.

## 12. Golden Nukey — `SparkleNukey` (A-pets, owner R78 — 2026-10-31)

Spec `docs/superpowers/specs/2026-10-31-r78-retention-pack-design.md` §5: the exclusive Nuke Pass
Season 1 premium tier-30 pet (`PetConfig` `golden_nukey`, Mythic tier 10). A NEW mesh, not a
recolour: the older `GoldenNukey` Secret species is a crowned gold nuke that does not read as the
mascot. This one re-uses `hub_plaza.nukey_figure` (the lobby fountain statue) as a chibi — the
statue's silhouette and face at pet size, in gold, plus sparkles. Same contract as §1–§2 (≤ 10
pieces, ≤ 2,800 tris, stud material, small Neon only — R19).

```bash
/opt/homebrew/bin/blender -b --python tools/blender/generate_world.py -- --only SparkleNukey
/opt/homebrew/bin/blender -b --python tools/blender/viewport_look.py -- OUT SparkleNukey tools/blender/models/pet_golden_nukey.py
python3 tools/blender/upload_meshes.py --user-id 1586034782 --only SparkleNukey
python3 tools/blender/sync_meshes.py
```

| Statue (`nukey_figure`) | Chibi (`SparkleNukey`) |
|---|---|
| red cap + white shine | amber-gold cap (#FF9622) + the same upper-left white shine |
| yellow capsule body, radius / height 0.21 | gold body (#FFC42E), squat: radius 0.78 / body 1.4 (0.34), cap tip 2.34 |
| big eyes looking in, brows, rosy cheeks, wide smile | the same face, eyes ~2x larger relative to the body |
| lime belt, white belly disc + black trefoil | lime Neon belt (pulses: Glow token), the same badge under it |
| 4 toy-blue fins + nozzle foot | 4 dark-gold fins (#D6961E) + nozzle foot |
| left fist on the hip, right arm waving | the same pose, static (the pet hops: PetAnimConfig `SparkleNukey = Hop`) |
| — | sparkly: Neon hoop at the waist (#FFF096, r 1.22, tilt −9° / −7°) with 4 riding stars + a halo above the cap (one `Orbit` group, spins about +Y); 3 white Smooth star glints on the gold |

Uploaded 2026-10-31: model asset **72555879118435** (Approved; first upload 124197605277121 had
the hoop at eye height — it swept across the face once the Orbit group spun in Studio, so the
hoop moved to the waist; receipt history keeps both). 9 pieces, 2,702 tris; pivot
`ground-contact centre …; rarity Mythic; hover 0; joints Orbit@(0,0.55,0)`.

| Piece | Colour / material | Group |
|---|---|---|
| `Body` | #FFC42E StudsSmall (body + both arms) | Body (squashes) |
| `Nose` | #FF9622 StudsSmall (the cap) | Body |
| `Fins` | #D6961E StudsSmall (nozzle foot + 4 fins) | Body (squashes) |
| `Glow` | #6EFF5A Neon (belt) | Body, pulses |
| `Gloves` | #FCFCFF StudsSmall (fist + open waving glove) | Body |
| `Eyes` | #FCFCFF Smooth (eye whites, highlights, cap shine, belly disc, star glints) | Body |
| `Face` | #24242E Smooth (pupils, brows, smile, trefoil) | Body |
| `Cheeks` | #FF96AA Smooth | Body |
| `Orbit` | #FFF096 Neon (hoop + 4 stars + halo) | Orbit (spins) |

Look: `docs/verification/r78-pets/golden-nukey-front.jpg` (in game, the lobby statue behind it),
`golden-nukey-following.jpg`, Index card + side panel `index-golden-nukey-*.jpg`; pipeline
previews `assets/blender/previews/SparkleNukey_{front,iso}.jpg`.
