# 3D UI icons (owner R9)

> "make sure we do like the 3D icons kind of. If you look at how [RoBeasts] has the icons, they're
> kind of like rendered instead of like flat ... they look 3D." (owner, 2026-10-30, R9)

Every UI icon (122 keys) — HUD buttons (+ the R78 Friends handshake), currencies, offers, rewards, game objects, the ten
area icons, the kit chrome (close X, tutorial arrow, Robux-style price coin) and the Harvest Feast
set (Golden Turkey, Gobble Bomb, Harvest Egg, sticker sheet, 20 Feast Stickers, 6 decorations) and the Dino Valley set (World 2: Bones, Amber, three bone packs, Time Traveler Pack, two world tabs, Time Machine) — is a chunky, glossy, shaded picture
with a thick dark outline on a transparent 512 x 512 canvas, the look of
`docs/reference/ui-style/*.png` and `docs/reference/missiles-vs-cities/21-silos-hud-wide.png`.
Flat frame-drawn glyphs (`UI/Kit/Glyphs`) remain only as the load-time / not-uploaded fallback.

Review sheets (owner R12: `open` them on the Mac after a change):
- **`assets/icons/contact-sheet.png`**: each icon on its category's stud-tile colour, plus a
  44 px preview bottom-right.
- **`assets/icons/contact-sheet-small.png`** (owner R11: icons must read on a phone and a TV):
  every icon at 40 px and 56 px (phone HUD) and 96 px (TV distance) side by side. Checked
  2026-10-30: every icon keeps a distinct silhouette and colour at 40 px. The weakest are the long,
  thin DecorGarland / DecorCornucopia, which still read.

## Where things live

| Path | What |
|------|------|
| `tools/ui/icons/icons.py` | The CLI: fetch, render, sheet, license, upload, moderation, sync, status |
| `tools/ui/icons/opencloud.py` | Hardened Open Cloud client (create Image, poll, moderation GET) |
| `tools/ui/icons/test_icons.py` | Unit tests (dilation, hue, catalog, generated Luau, receipts, framing) |
| `tools/ui/icons/requirements.txt` | numpy + Pillow (system `python3` already has both) |
| `tools/blender/ui_icons/render_icons.py` | Original Blender icons in the shared soft-toon style |
| `assets/icons/sources.json` | **The catalog**: every key's source kind + pins / composite layers |
| `assets/icons/sources/` | Pinned Fluent Emoji 3D PNGs (committed; `render` never needs the network) |
| `assets/icons/<Key>.png` | Final 512 x 512 icons; `manifest.json` = sha256 + alpha bounds |
| `assets/icons/journal/`, `receipts/`, `history/` | Upload journal, per-key receipts, retired uploads |
| `assets/icons/LICENSE.md` | GENERATED per-icon sources + the full MIT notice |
| `src/shared/Config/IconAssets.luau` | GENERATED runtime map (never hand-edit) |

`assets/icons/raw/` (2048 px raw passes) is git-ignored and rebuilt by `render`.

## Sources: Fluent Emoji 3D where it fits, Blender where it doesn't

- **Pack** (50 icons + 18 parts): Microsoft Fluent Emoji 3D (MIT,
  github.com/microsoft/fluentui-emoji, commit `1ffb34c752ecf5d402f04cfb4b392c77f57c54bc`, files
  `assets/<Name>/3D/*.png`), the same pack and commit RoBeasts uses. Each source is pinned by URL +
  sha256. Processing: trim to alpha, saturation x1.15 / contrast x1.06 (soft emoji colours -> the
  saturated simulator look), optional hue rotation for a palette match (Codes = blue check box,
  Gems = purple gem, Event = autumn-orange maple leaf, FastWalk = blue shoe, Area04 = green crystal).
- **Blender** (36 icons + 10 parts): everything no emoji covers well — the cartoon pocket nuke
  (matches B4's `PocketNuke`: red body, white nose, charcoal fins, glowing green core band, yellow
  trefoil badge), the golden MegaLauncher nuke, the red shop basket, the "31" calendar, the rainbow
  prize wheel, red/white rebirth arrows, the green money stack, acorn, rebirth token, treasure chest,
  potion, chunky green up arrow, pet egg (cream with glowing-green spots), supply crate, AA tower,
  peeled star sticker, the Nuke Stand and the Mega Nuclear Facility area icons, the white close X,
  the yellow tutorial arrow and an **original** green hexagon coin for Robux price tags (not
  Roblox's logo file).
- **Composite** (26 icons): layered pack / Blender art, each layer with a thin inner line so stacked
  items separate: Spins (wheel + sparkles), AutoClicker (hand + bolt), LuckyEggs (egg + clover),
  PetSlots (dog + green plus), TripleHatch (3 eggs), AutoHatch (chick + bolt), ServerBoost (cash +
  bolt), Barrage (blue / lime / red nukes), GemPack, CashPack, Torch (Blender handle + Fluent
  fire), Area04 (pick + green crystal), plus the event composites (GoldenTurkey, StickerSheet,
  DecorTurkeyStatue and the composite stickers).
- **Harvest Feast (B11)**: Blender GobbleBomb (a turkey-styled nuke with a feather fan, eyes, beak
  and wattle), HarvestEgg, hay bales, pumpkin pile, scarecrow, cornucopia, garland, roast turkey and
  acorn-buddy parts. Fluent covers the rest: corn, maple leaf, sweet potato, bread (dinner roll),
  top hat (pilgrim hat), mug, jack-o'-lantern (Squash Pal), bone (wishbone), recoloured pie / moon
  / teapot / drumstick / turkey, and jar + cherries.
  - **Sticker look** (`"sticker": true`, `"tilt"`): all 20 Feast Stickers are re-fitted 14 px
    smaller, tilted a few degrees and given a white die-cut border inside the dark outline, so they
    read as stickers on the sheet.
  - **Colourise** (`"colorize": [dark, mid, light]`): remaps luminance onto a 3-stop gradient,
    keeping the shading. Hue rotation can't make a dark-brown turkey gold, so this is used for the
    gold turkey and drumstick, the pecan pie and the pumpkin pie.

Per-key sources: `assets/icons/LICENSE.md` (generated) or `assets/icons/sources.json` (`why` field
explains every non-pack choice).

### One shared look

- **Blender soft-toon material** (all emission, exact colours): diffuse luminance x crease AO
  through an eased 3-tone ramp (violet-shifted shadow -> base -> warm light), facing-ratio edge
  darkening, a crisp white specular blob. One sun light high front-left (no cast shadows), an
  orthographic camera front-right and slightly above (default yaw 28°, pitch 20°; flat icons such
  as the wheel / calendar / coin use a flatter 12-24° view), thin inverted-hull inner lines.
- **Post (every icon)**: trimmed art is re-fitted so its longer side fills 464 px of the 512 canvas,
  then an exact disc dilation of the silhouette (18 final px, `UIStyleConfig.TextStroke` 20/20/28)
  goes under it, then a 4:1 premultiplied box downsample (16x supersampled edges, no dark fringes).
- Lesson learned (2026-10-30): the inverted hull must NOT use Solidify "even thickness" — on thin
  parts (basket holes, awning slats, text, trefoil blades) it divides by the corner angle and spikes
  into long black shards. `use_even_offset = False` + quality normals fixed it.

## Runtime API (`src/shared/Config/IconAssets.luau`, for UI/Kit)

```lua
local IconAssets = require(ReplicatedStorage.Shared.Config.IconAssets)
local entry = IconAssets.get("Shop")      -- { image = "rbxassetid://N" or "", size = Vector2(512,512), category, source }
local id = IconAssets.image("Gems")       -- "rbxassetid://N" or nil (legacy helper; StudUI / Toasts use it)
IconAssets.Categories.area                -- { "Area01", ..., "Area10" } (teleport list order)
IconAssets.Categories.event               -- Harvest Feast keys (Sticker01..Sticker20 in sheet order)
```

Lookup order: exact key -> exact alias -> case-insensitive (`IconAssets.Lower`). Aliases cover:

- legacy stub keys: `Gem` -> Gems, `X2Cash` -> x2Cash, `Gift` -> GiftBox;
- `MonetizationConfig` product keys: `DoubleCash` / `Cash2x30` -> x2Cash, `Cash*` -> CashPack,
  `Gems*` -> GemPack, `Spins2/5/10` -> Spins, `ServerCash2x` -> ServerBoost, `Shield1h` -> Shield,
  `Acorns*` -> Acorn;
- `MonetizationConfig` lowercase `icon` names: crown -> VIP, cash, cursor -> AutoClicker, boot ->
  FastWalk, teleport -> Teleporter, egg, pet -> Pets, moon -> OfflineMax, rocket -> MegaLauncher,
  gem -> Gems, spin -> Spins, gift -> GiftBox, star, lightning -> ServerBoost, clock, skip ->
  SkipPad, shield, acorn, turkey.

An empty `image` means "not uploaded yet", "the PNG changed since upload" or "moderation rejected":
StudUI keeps the Glyphs fallback. `Reviewing` assets are mapped (Roblox serves them once approved).

## Commands

```bash
python3 tools/ui/icons/icons.py fetch                 # pinned Fluent PNGs -> assets/icons/sources/ (sha256-checked)
python3 tools/ui/icons/icons.py render [--only Shop]  # raw pass + outline + manifest + LICENSE.md + contact sheet
python3 tools/ui/icons/icons.py sheet                 # contact-sheet.png + contact-sheet-small.png
python3 tools/ui/icons/icons.py license               # regenerate LICENSE.md from sources.json
open assets/icons/contact-sheet.png assets/icons/contact-sheet-small.png   # owner R12
python3 tools/ui/icons/icons.py upload --user-id 1586034782 [--only K] [--replace K|all] [--dry-run]
python3 tools/ui/icons/icons.py moderation            # refresh moderation states, then sync
python3 tools/ui/icons/icons.py sync | status
python3 -m unittest discover -s tools/ui/icons -p 'test_*.py'
stylua src/shared/Config/IconAssets.luau && luau-compile --null -O0 -g2 src/shared/Config/IconAssets.luau
```

Full render: ~3.5 min (one Blender process for every Blender icon / part, ~3 s each).

**Adding / changing an icon:** add the key to `CATEGORIES` in `icons.py` (the B2 contract) and an
entry to `sources.json` (`pack` with url + file + sha256 + emoji, `blender` with a builder in
`render_icons.py`'s `BUILDERS`, or `composite` with layers). `render --only Key`, look at the
contact sheet, `upload` (a changed picture needs `--replace Key`), done — `sync` regenerates the Luau.

## Upload, security, moderation

- One Image asset per distinct picture, creator user `1586034782` (owns the SellNukes game).
  Identical bytes under two keys (Rewards = GiftBox) share one asset (`sharedWith` in the receipt).
- The Open Cloud key comes from `$ROBLOX_OPEN_CLOUD_KEY`, `~/.config/robeasts/open-cloud.env` or
  `~/.config/robloxstudio-mcp/open-cloud-key` (mode-600 files you own). It is never accepted on
  argv, printed or written. Fixed host, verified TLS, no proxies, no redirects, bounded responses,
  remote error bodies never echoed; only the create / poll / moderation request shapes exist.
- Journal before every POST ("submitting"), then "pending" with the operation path; an ambiguous
  POST is never retried (reconcile in Creator Dashboard, then delete `journal/<Key>.json`). Rerun
  `upload` to resume polling. A process lock (`assets/icons/.upload.lock`) prevents two uploaders.
- Every asset description carries the Fluent MIT notice when it contains Fluent art.
- New assets start in `Reviewing`; run `moderation` later to record `Approved` / `Rejected`
  (Rejected maps to "" so the fallback shows; re-render a different picture and `--replace` it).

## Dino Valley icons (W9, R57)

World 2 "Dino Valley" (spec `docs/superpowers/specs/2026-10-31-world2-design.md` §2 theme + kid
rules, §16 icons). Nine keys, all original Blender renders in the shared soft-toon style (builders
in the "Dino Valley" section of `tools/blender/ui_icons/render_icons.py`; palette: bone cream with
an amber-tan shadow, glowing amber, fern green, candy-orange lava). Uploaded 2026-10-30, all
**Approved**.

| Key | Category | Picture | Asset id |
|-----|----------|---------|----------|
| `Bones` | currency | One chunky cream cartoon fossil dog-bone on a diagonal with an amber-orange glint star. No skulls. | 93554409369351 |
| `Amber` | currency | A faceted glowing amber teardrop with a tiny green fern-leaf fossil "inside" (no insects). | 95004091115230 |
| `BonesPackSmall` | offer | Three bones in a staggered diagonal stack (the Bones bone x3). | 128309537335203 |
| `BonesPack` | offer | A 3-2-1 heap of six bones with an amber glint. | 138456513151274 |
| `BonesPackLarge` | offer | A 4-3-2-1 heap of ten bones with three amber nuggets and two glints. | 139758664034728 |
| `TimeTravelerPack` | offer | Composite: golden swirl-face pocket-watch (`_PocketWatch`) + ribboned bone bundle (`_BoneBundle`) + sky-blue feather-crested ptero egg (`_PteroEgg`). | 105727285819035 |
| `WorldNukeTown` | world | Floating green island with the red cartoon pocket nuke (the B4 `nuke_parts`), a tiny red-roof house and a round tree. | 121441863219564 |
| `WorldDino` | world | Cute round green dino head in 3/4 view: big eyes looking at the viewer, a smile, pink cheeks, round yellow crown spikes; a small volcano with candy-orange jelly lava behind. No teeth, no claws. | 88570225865990 |
| `TimeMachine` | world | Gold clock ring with 12 white hour studs around a purple / cyan swirl portal, on a blue base with red + yellow dials and a red-knob lever (the lobby Time Machine). | 99497062076069 |

- **New category `world`** (`IconAssets.Categories.world` = WorldNukeTown, WorldDino, TimeMachine;
  teal sheet tile). It holds the world-select tabs in WorldsConfig order plus the portal icon.
  World 3 adds its `World<Name>` tab key here (spec §18). Not in the loading screen's
  `HOT_CATEGORIES`: the tabs only appear on the teleport screen.
- **Aliases** (MonetizationConfig product keys, spec §9): `BonesSmall` -> BonesPackSmall,
  `BonesMedium` -> BonesPack, `BonesLarge` -> BonesPackLarge (`TimeTravelerPack` is its own key);
  lowercase icon names `bones` -> Bones, `amber` -> Amber.
- **Builder notes:** `bone_parts()` (one dog-bone: waisted shaft + two knobs per end facing the
  viewer), `bone_heap()` / `BONE_HEAPS` (rows alternate cream / tan and darken toward the back,
  because the 5 px inner lines vanish at 40 px), `amber_parts()` (reused as the nuggets in
  BonesPackLarge), `swirl_parts()` (shared by TimeMachine and the pocket-watch face),
  `sparkle()` (amber 4-point glint). `no_hull(obj)` is a new harness flag: `add_hulls` skips that
  part, so the fern reads as sunk into the amber and the cheek blush as painted on.
- **Legibility (R11):** checked on `contact-sheet-small.png` at 40 / 56 / 96 px: every key keeps a
  distinct silhouette; the bone packs progress small stack -> heap + glint -> bigger heap + orange
  amber dots. The busiest is BonesPack (a cream heap), which still reads as "pile of bones".
- **Who uses them:**
  - W5 world tabs (teleport screen, `WorldClientConfig.Tabs`): `WorldNukeTown`, `WorldDino`;
  - `WorldsConfig` currency / token icons: `{ key = "bones", icon = "Bones" }`,
    `{ key = "amber", icon = "Amber" }` (HUD counter, CurrencyFly, billboards, pad prices);
  - `MonetizationConfig`: `BonesSmall` / `BonesMedium` / `BonesLarge` (`icon = "BonesPack"`, or the
    per-size keys via the aliases above) and `TimeTravelerPack`;
  - WORLD UNLOCKED popup and the Time Machine portal prompts / locked preview: `TimeMachine`.

## Moon Base + Lucky Button icons (W1b, R69 / R70)

World 3 "Moon Base" (spec `docs/superpowers/specs/2026-10-31-r69-moon-lucky-juice-design.md` §2.1 /
§2.7) and the Lucky Buttons (§1). Nine keys, all original Blender renders in the shared soft-toon
style (builders in the "Moon Base" section of `tools/blender/ui_icons/render_icons.py`; palette:
Moon Rocks lilac 196, 180, 255 with a deep violet shadow, Star Shards cyan 120, 230, 255, grey-lilac
moon dust, toy red / white rockets, a pale-blue bubble helmet). Uploaded 2026-10-31, all
**Approved** (`icons.py moderation`, same day).

| Key | Category | Picture | Asset id |
|-----|----------|---------|----------|
| `MoonRocks` | currency | One chunky faceted lilac moon rock with crater dimples, a glowing cyan speck and a white-cyan glint. | 101443641971752 |
| `StarShards` | currency | A fat cut-crystal cyan five-point star with a pale centre facet, two small diamond shards breaking off and a glint. | 92730802484727 |
| `MoonRocksPackSmall` | offer | Three moon rocks in a 2-1 stack. | 80105363360475 |
| `MoonRocksPack` | offer | A 3-2-1 heap of six rocks (lilac / bluer lilac alternate) with a glint. | 88464398032317 |
| `MoonRocksPackLarge` | offer | A 4-3-2-1 heap of ten rocks with three cyan star shards and two glints. | 131380087641271 |
| `AstronautPack` | offer | Composite: the Rocket Corgi in a bubble helmet (`_CorgiHelmet`) + a moon-rock trio (`_MoonRockTrio`) + the 2x Cash money bag (`x2Cash`, Fluent). | 116302336553651 |
| `LuckyButton` | game | A chunky round arcade button: navy housing, gold bezel, glossy glowing lucky-green dome with a gold star, two glints. | 96424298719201 |
| `WorldMoon` | world | A smiling grey-lilac cartoon moon (craters, big eyes, pink cheeks) with a little red / white rocket zooming past. | 88163127440616 |
| `MoonRocket` | world | The lobby rocket portal: a red / white cartoon rocket with a porthole lifting off a lilac launch pad (flame on). | 140232903430214 |

- **Aliases** (MonetizationConfig product keys, spec §2.6): `MoonRocksSmall` -> MoonRocksPackSmall,
  `MoonRocksMedium` -> MoonRocksPack, `MoonRocksLarge` -> MoonRocksPackLarge (`AstronautPack` is its
  own key); lowercase `moonrocks` -> MoonRocks, `starshards` -> StarShards. (`moon` stays OfflineMax.)
- **Builder notes:** `rock_parts()` (an icosphere bumped per vertex by `_hash01`, a deterministic
  hash — no RNG, renders stay reproducible — flat facets, crater discs aligned to the surface with
  `_align_y`, no hull so they read sunk in), `ROCK_HEAPS` / `rock_heap()` (alternating lilac tones,
  like the bone heaps), `shard_parts()` (chamfered star prism + pale facet), `rocket_parts()` (shared
  by MoonRocket and the WorldMoon mini rocket), `glint()` (cyan / white 4-point star; `sparkle()` is
  amber). The corgi sits IN FRONT of the glass ball so the ball reads as a bubble around it.
- **Legibility (R11):** checked at 40 / 44 px: rocks read as lilac rocks (not gems), the packs grow
  stack -> heap -> heap + cyan shards, the Lucky Button's gold star separates it from a UFO.
- **Who uses them:** `WorldsConfig` Moon currency / token icons (`MoonRocks`, `StarShards`); the Moon
  products + ShopConfig MOON BASE section; `WorldClientConfig.Tabs.moon` (`WorldMoon`) and
  `Offers.moon` (`AstronautPack`); the lobby rocket portal / WORLD UNLOCKED (`MoonRocket`, W9b);
  Lucky Button toasts / admin / HUD arrow (`LuckyButton`, H3).

## Nuke Pass icon (P-pass, R78)

| Key | Category | Picture | Asset id |
|-----|----------|---------|----------|
| `NukePass` | offer | Composite: a gold-recoloured Fluent "Ticket" (`_GoldTicket`, U+1F3AB, `colorize` amber → gold → pale gold), the red cartoon pocket nuke (`Nuke`) in front at the lower right, and `_Sparkles` at the top left. Reads as "season pass" at 40 px. | 117642180669672 (Reviewing at upload) |

- Alias `NukePassPremium` → NukePass (the product key; `publish.py` patched the live product icon
  with it). MonetizationConfig `IconKeys` gained `NukePass`.
- It is used by the HUD Pass offer (`HudZonesConfig`), the NukePass window header, PassService
  toasts, the NUKE PASS title tag and the Quests banner.

