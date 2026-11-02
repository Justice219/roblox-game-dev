# Owner reference screenshots: what each shows and what SellNukes took from it

The owner gave SellNukes 26 reference screenshots on 2026-10-30, from three other Roblox games and
one tooling shot. They set the look of every stud panel, HUD tile, billboard, buy pad, nuke model
and attack-mode screen. This file catalogues each image: what it shows, what SellNukes took from
it, and which SellNukes systems and docs it shaped. Read it before you design a screen or a world
piece. Then open the matching compressed copy that ships with this skill at
`assets/reference/<subfolder>/<name>.jpg` (each `.png` original became a `.jpg` with the same
name). The originals live in the SellNukes repo at `docs/reference/<subfolder>/<name>.png`, and
`docs/reference/README.md` annotates them. **The images are inspiration only.** SellNukes is an
original, kid-friendly game, and the last section explains the rules.

## Contents

1. [Quick index](#1-quick-index)
2. [ui-style: the stud UI (01–07)](#2-ui-style-the-stud-ui-0107)
3. [sell-lemons: tycoon gameplay (08–18)](#3-sell-lemons-tycoon-gameplay-0818)
4. [missiles-vs-cities: stud nukes and the attack side mode (19, 21–26)](#4-missiles-vs-cities-stud-nukes-and-the-attack-side-mode-19-2126)
5. [tooling: the Studio MCP (20)](#5-tooling-the-studio-mcp-20)
6. [Common HUD language across the shots](#6-common-hud-language-across-the-shots)
7. [How to use reference images](#7-how-to-use-reference-images)

---

## 1. Quick index

The numbers are global and follow arrival order. Number 20 is the tooling shot, which arrived
between the missile shots.

| # | Skill copy | One line | Main SellNukes result |
|---|---|---|---|
| 01 | `assets/reference/ui-style/01-daily-rewards.jpg` | 7-day reward grid | `Screens/DailyRewards`, the StudUI window/card/button look |
| 02 | `assets/reference/ui-style/02-shop-limited-time.jpg` | Shop, limited-time packs | `Screens/Shop` + `PackCard`, `ShopConfig` |
| 03 | `assets/reference/ui-style/03-lucky-wheel.jpg` | 5-slice lucky wheel | `Screens/LuckyWheel` |
| 04 | `assets/reference/ui-style/04-time-rewards.jpg` | Playtime gift grid | `Screens/TimeRewards` (shares `CardGrid`) |
| 05 | `assets/reference/ui-style/05-codes.jpg` | Codes panel | `Screens/Codes` |
| 06 | `assets/reference/ui-style/06-group-rewards.jpg` | Join-group rewards | `Screens/GroupRewards` |
| 07 | `assets/reference/ui-style/07-offline-earnings-welcome-back.jpg` | Offline earnings popup | `Screens/WelcomeBack` |
| 08 | `assets/reference/sell-lemons/08-stand-upgrade-overview.jpg` | Producer + upgrade billboard | `Tycoon/ProducerBillboards` |
| 09 | `assets/reference/sell-lemons/09-stand-closeup-billboards.jpg` | Billboards close up | `ProducerBillboards`, `PadBillboards`, manager bubbles |
| 10 | `assets/reference/sell-lemons/10-sign-rename-dialog.jpg` | Rename the shop sign | `Screens/RenameStand`, plot names (R88) |
| 11 | `assets/reference/sell-lemons/11-fence-buy-button.jpg` | Round tyre buy pad | Blender `BuyPad`, pad price colours |
| 12 | `assets/reference/sell-lemons/12-lemondash-tips-billboards.jpg` | Second business phase | Ten themed areas, Tip Jar |
| 13 | `assets/reference/sell-lemons/13-lemondash-upgrade.jpg` | Indoor producer phase | Area interiors, multiplier pads, build-in |
| 14 | `assets/reference/sell-lemons/14-halloween-sticker-sheet.jpg` | Seasonal sticker sheet | `Screens/StickerSheet` (Harvest Feast) |
| 15 | `assets/reference/sell-lemons/15-lemon-depot-manager.jpg` | CLICK bar + manager pad | Manual producers, managers |
| 16 | `assets/reference/sell-lemons/16-teleport-menu.jpg` | Teleport list with locked progress | `Screens/Teleport` |
| 17 | `assets/reference/sell-lemons/17-depot-buy-buttons.jpg` | Two pads + "YOU" marker | `Tycoon/YouMarker`, pad kinds |
| 18 | `assets/reference/sell-lemons/18-crypto-mine-cave.jpg` | Late-game cave area | Area 4 Glow Rock Mine |
| 19 | `assets/reference/missiles-vs-cities/19-stud-nuke-silos-launch-panel.jpg` | Stud rockets in gantries | Area 7 Launch Silos, stud nuke models |
| 20 | `assets/reference/tooling/20-studio-robloxstudio-mcp-v3.2.1.jpg` | Studio with the MCP plugin | `scripts/studio_mcp.py`, CLAUDE.md MCP section |
| 21 | `assets/reference/missiles-vs-cities/21-silos-hud-wide.jpg` | Silo pad + full HUD | 3D icon look, top-centre currency, NotifyPrompt |
| 22 | `assets/reference/missiles-vs-cities/22-attack-target-select-island.jpg` | Target picker | `Screens/AttackTarget` |
| 23 | `assets/reference/missiles-vs-cities/23-island-base-rocket-launch.jpg` | Island base, rocket launch | Toy-island world, income pops, LaunchCam |
| 24 | `assets/reference/missiles-vs-cities/24-aa-tower-intercept-sky.jpg` | AA interceptors | AA towers, `Screens/Defense` |
| 25 | `assets/reference/missiles-vs-cities/25-island-overview-in-combat-barrage.jpg` | Base under attack | Shield dome, Barrage (no "IN COMBAT") |
| 26 | `assets/reference/missiles-vs-cities/26-nuke-reactor-tower-shield-dome.jpg` | Reactor tower + shield | Reactor art, shield dome |

---

## 2. ui-style: the stud UI (01–07)

These seven shots come from one simulator. They define **the** SellNukes UI. The palette and
geometry in `src/shared/Config/UIStyleConfig.luau` were colour-sampled from them, and
`src/client/UI/Kit/StudUI.luau` was built to reproduce them (`docs/ui.md`). Shots 01–06 share one
HUD (section 6). Shot 07 is from the lemon tycoon.

### 01-daily-rewards

- **File:** `docs/reference/ui-style/01-daily-rewards.png` → `assets/reference/ui-style/01-daily-rewards.jpg`
- **Shows:** a "Daily Rewards" window. It has a red stud header bar with a 3D calendar icon and a
  big outlined title, a red square **X**, and a dark slate body. Inside are six blue stud day
  cards (Day 1–6) in a 3 x 2 grid, each with a 3D reward icon and a pill button: green
  **CLAIMED** / **CLAIM** or grey **LOCKED!**. The next locked day shows a live countdown
  (`11:48:16`) instead of its title. A tall **rainbow Day 7** card sits on the right.
- **SellNukes took:**
  - the whole window grammar: a coloured stud header, the icon poking out of the header, the red
    X, the slate body;
  - stud cards and pill buttons with the states `normal / claimed / locked`;
  - a countdown in place of a card title;
  - a rainbow final card;
  - the `red` (header), `sky` (cards), `green` / `grey` (buttons) and `rainbow` presets.
- **Shaped:**
  - `Screens/DailyRewards/{init, CardGrid, ResponsiveModal}`;
  - `StudUI.window` / `card` / `button` / `countdown`;
  - `UIStyleConfig.Colors` and `IconFill.Header`;
  - `RetentionConfig.dailyStatus`;
  - `docs/retention.md` and `docs/ui.md` §3–4.

  Owner R11 then added a phone mode: `ResponsiveModal` swaps to a wide one-row layout so taps stay
  ≥ 44 pt. R62 later folded Daily into the Rewards hub (`Screens/RewardsHub`).

### 02-shop-limited-time

- **File:** `docs/reference/ui-style/02-shop-limited-time.png` → `assets/reference/ui-style/02-shop-limited-time.jpg`
- **Shows:** a "Shop" window with a yellow-to-orange stud header and a basket icon. A
  "- LIMITED TIME -" section label sits above two wide offer cards:
  - a red **STARTER PACK** card with item icons on white sunbursts and a green Robux price button;
  - a white **SECRET PACK** card with a red "Limited Stock" label.
- **SellNukes took:**
  - section labels;
  - wide pack cards in a preset colour (red Starter, white Secret);
  - sunbursts behind item icons;
  - the green Robux price tag;
  - a red limited-stock line.
- **Shaped:**
  - `Screens/Shop/{init, PackCard}`;
  - `ShopConfig`, which has global limited stock and cites this file;
  - `StudUI.sectionLabel`, `card({sunburst = true})`, `robuxTag`, and live `PriceBook` prices;
  - `docs/monetization.md`.

  Owner R98 ("hard to see with the stud background") added `UIStyleConfig.ItemPlate`, a dark
  backing disc behind every shop item. Studs behind art need a plate.

### 03-lucky-wheel

- **File:** `docs/reference/ui-style/03-lucky-wheel.png` → `assets/reference/ui-style/03-lucky-wheel.jpg`
- **Shows:**
  - a five-slice wheel, each slice its own colour with a stud pattern and a cash-stack icon;
  - a white arrow pointer at the top;
  - "Next FREE spin in 04:14";
  - a green **SPIN (x7)** button with a red X beside it;
  - three yellow paid-spin bundles: (2x) 29 R$, (5x) 59 R$, (10x) 99 R$.
- **SellNukes took:**
  - a studded per-slice wheel;
  - the free-spin countdown line;
  - a SPIN button with its count;
  - yellow paid bundles;
  - the "x5 Spins" HUD offer.
- **Shaped:**
  - `Screens/LuckyWheel/{init, WheelDrawing, WheelFx, SpinMotion}`, which cite this file;
  - `LuckySpinConfig` and `LuckyWheelFxConfig`;
  - `docs/juice.md` §9.

  Owner R81 ("needs like a ticker effect") added pegs, a flapper, bulbs and win celebrations. The
  server rolls and the client lands on its slice. R127 hides the HUD money stack while the wheel
  is open, because it clipped the title.

### 04-time-rewards

- **File:** `docs/reference/ui-style/04-time-rewards.png` → `assets/reference/ui-style/04-time-rewards.jpg`
- **Shows:** a "Time Rewards" window with a green stud header and a stopwatch icon. Six orange
  stud gift cards each show a playtime countdown (04:11 … 01:59:11) over a gift icon and a grey
  **LOCKED!** button. A rainbow final card shows 02:59:11.
- **SellNukes took:** the playtime-gift ladder with per-gift countdowns, the `orange` cards and a
  rainbow final card. It reuses the Daily grid.
- **Shaped:**
  - `Screens/TimeRewards`, which shares `Screens/DailyRewards/CardGrid` (that module cites both
    01 and 04);
  - `PlaytimeConfig.status`;
  - the Rewards hub "Time" tile;
  - `docs/retention.md`.

### 05-codes

- **File:** `docs/reference/ui-style/05-codes.png` → `assets/reference/ui-style/05-codes.jpg`
- **Shows:** a "Codes" window with a blue stud header and a check-box icon. Big outlined text
  reads "Follow ___ on Roblox for exclusive codes!", with a keyword in red. Below it are a dark
  "Code Here" text box and a green **Redeem** button.
- **SellNukes took:** the dark-well text box, the green Redeem button, the `blue` header and
  coloured keywords inside outlined text.
- **Shaped:**
  - `Screens/Codes` and `CodesConfig`;
  - `StudUI.textBox`;
  - the `RedeemCode` → `CodeResult` remotes, where the server validates and rate-limits;
  - `Shared/Util/PopupCloseRule`: the keyboard close keys never fire while the text box has focus;
  - the canonical screen example in `docs/ui.md` §2.

### 06-group-rewards

- **File:** `docs/reference/ui-style/06-group-rewards.png` → `assets/reference/ui-style/06-group-rewards.jpg`
- **Shows:** a "Rewards" window with an orange stud header and a treasure-chest icon. The left
  side is a dark studded well where reward icons (a coin "+10,000" and a pet "+1 Cat") sit on a
  sunburst. The right side reads "Join our ROBLOX Group for exclusive rewards!", with coloured
  keywords, above a green **JOIN GROUP** button.
- **SellNukes took:** the reward-preview well with a sunburst, the coloured keywords, the
  `orange` header, and a single green call to action.
- **Shaped:**
  - `Screens/GroupRewards`, which cites this file;
  - the Rewards hub "Group" tile. The badge shows only when `IsInGroupAsync` says the player is a
    member; the server re-checks on claim.
  - `docs/retention.md`.

### 07-offline-earnings-welcome-back

- **File:** `docs/reference/ui-style/07-offline-earnings-welcome-back.png` → `assets/reference/ui-style/07-offline-earnings-welcome-back.jpg`
- **Shows:** a lemon-tycoon "WELCOME BACK!" popup. It has a green stud-border frame,
  "You were offline for 54m 35s and earned...", a huge green outlined money number in a dark
  well, a grey **OKAY** button and a green **DOUBLE IT!** button (x2, with a Robux price). The
  game's top-centre cash bar and an EVENT button are visible behind it.
- **SellNukes took:**
  - offline earnings as a moment, with the time-away line and a huge money number in a well;
  - OKAY plus a paid DOUBLE IT;
  - the `Shout` font (Luckiest Guy) for "WELCOME BACK!".
- **Shaped:**
  - `Screens/WelcomeBack`, which cites this file. World 2 (R57) made it one row per world, and
    DOUBLE IT doubles every row. R78 added the Comeback Rush banner.
  - Offline earnings are **server-calculated** on rejoin.
  - The `offline` source in `Hud/CurrencyFly` (coins fly to the counter when the popup closes).
  - `docs/retention.md`, `docs/economy.md`.

---

## 3. sell-lemons: tycoon gameplay (08–18)

These are from a linear lemon-selling button tycoon. They shaped the core loop: click to produce,
buy pads that build your business, automate with managers, and move through themed phases. They
also shaped the world UI: producer billboards, pad billboards, buy pads and the teleport list.
`docs/tycoon-client.md` cites "ref 08/15" and "ref 09/11/17" directly. The owner's spoken notes
with these shots (R1) were "offline earnings", "each phase is a new thing", and the LEGO
master-builder build-in for every purchase (hard rule 4, `docs/build-in.md`).

### 08-stand-upgrade-overview

- **File:** `docs/reference/sell-lemons/08-stand-upgrade-overview.png` → `assets/reference/sell-lemons/08-stand-upgrade-overview.jpg`
- **Shows:**
  - a street view of the player's red-roofed shop with a name sign over the door and a
    "Best Lemons" stand sign;
  - a lemon stand with a floating billboard: the producer name, "$192,524" per cycle, a yellow
    **X8** multiplier badge, a stud progress bar with "0.1s", and a cyan **UPGRADE** pill with
    its cost and a key glyph;
  - round buy pads on the grass;
  - a top-centre cash bar.
- **SellNukes took:** the per-producer billboard: name, `$/cycle`, a yellow `xN` badge, a stud
  progress bar with the cycle time, and a cyan UPGRADE pill with the cost and the device key glyph.
- **Shaped:**
  - `Tycoon/ProducerBillboards`, which adds x1 / x10 / MAX, a grey pill when unaffordable,
    read-only billboards on other players' producers, and one PreRender loop for the bars;
  - `Tycoon/BillboardPlacement` + `Shared/Config/BillboardSpots`;
  - `docs/tycoon-client.md` and `docs/billboards`.

  The owner later flagged billboards clipping into geometry several times (R31 awning, R105 and
  R119 silo boards). That is why placement is solved offline and tested.

### 09-stand-closeup-billboards

- **File:** `docs/reference/sell-lemons/09-stand-closeup-billboards.png` → `assets/reference/sell-lemons/09-stand-closeup-billboards.jpg`
- **Shows:**
  - the same stand close up: a big UPGRADE pill with "x77" and its price, a CLICK-style stud bar,
    and a worker speech bubble ("Come on register, work!");
  - small floating pad billboards over nearby floor pads, each with a name, an effect line and a
    coloured price.
- **SellNukes took:**
  - small pad billboards: the name, an italic effect blurb, and a price coloured by pad kind;
  - short worker speech bubbles over staff.
- **Shaped:**
  - `Tycoon/PadBillboards`. Price colours: Build red, Multiplier/Speed yellow, Manager cyan,
    Unlock green, Feature purple, grey when unaffordable; tapping the price sends `PadBuy`.
  - `Tycoon/Npc/ManagerTags` + `ManagerTagLogic` (R87 nametags and stud speech bubbles,
    `docs/managers.md`).

### 10-sign-rename-dialog

- **File:** `docs/reference/sell-lemons/10-sign-rename-dialog.png` → `assets/reference/sell-lemons/10-sign-rename-dialog.jpg`
- **Shows:** a "rename your shop sign" dialog over the world. It has a white text box (holding
  placeholder text the player typed), a red **CANCEL** button and a green **CONFIRM** button. The
  shop's name sign is above the door.
- **SellNukes took:** letting players name their business from its sign, with a cancel / confirm
  pair. In SellNukes the name always goes through `TextService` filtering before anyone else sees
  it.
- **Shaped:**
  - `Screens/RenameStand`;
  - owner R88 plot names (`docs/plots.md`):
    - click or tap the plot sign, or use a ProximityPrompt with a controller;
    - `PlotNameLogic.parse` validates UTF-8 and length;
    - a rate limit of 3, then 1 per 10 s;
    - `FilterStringAsync`;
    - the `PlotName` attribute;
    - the suffix "Nukes".

### 11-fence-buy-button

- **File:** `docs/reference/sell-lemons/11-fence-buy-button.png` → `assets/reference/sell-lemons/11-fence-buy-button.jpg`
- **Shows:** a chunky round buy pad (a black tyre ring with a raised red top) labelled "Fence /
  decoration / $44 billion" in big outlined world text. The pad colour encodes the category: red
  for decoration, yellow for multiplier, grey for locked or too expensive.
- **SellNukes took:** the tyre-ring buy pad with a coloured button top, the colour encoding the
  pad kind, and a floating name + kind + price label.
- **Shaped:**
  - the Blender `BuyPad` builder in `tools/blender/models/props.py`, which cites this shot;
  - `PadBillboards` kind colours;
  - the build-in fly-in on purchase (hard rule 4).

### 12-lemondash-tips-billboards

- **File:** `docs/reference/sell-lemons/12-lemondash-tips-billboards.png` → `assets/reference/sell-lemons/12-lemondash-tips-billboards.jpg`
- **Shows:** a second business phase, a delivery start-up parody, next to the shop. A counter with
  a till and a "TIPS" jar shows the billboard "TIPS x2 cash". Small floating effect labels sit
  over nearby pads. A big outlined pad label appears at the screen edge.
- **SellNukes took:** "each phase is a new themed business with its own upgrades" (owner R1), and
  a hands-on tip jar.
- **Shaped:**
  - the ten themed areas (Garage Lab → Nuke Stand → BoomDash Delivery → … → Mega Nuclear
    Facility; `docs/areas-art.md`, `Shared/Config/TycoonAreas`). The delivery phase is an
    **original** "BoomDash Delivery", not the reference's name.
  - the Tip Jar plot prop (owner R90 / R93, `docs/kinetic.md`).

### 13-lemondash-upgrade

- **File:** `docs/reference/sell-lemons/13-lemondash-upgrade.png` → `assets/reference/sell-lemons/13-lemondash-upgrade.jpg`
- **Shows:** an indoor producer room with its own red walls and stud floor. It has a producer
  billboard (name, "$861.701 million", **X8**, a stud bar with "0.2s", UPGRADE with a price) and a
  yellow multiplier pad next to it ("MOBILE APP — x4 … cash — $270 billion").
- **SellNukes took:**
  - indoor phases whose walls and floor build in;
  - multiplier pads placed beside the producer they boost;
  - the billboard repeated consistently in every phase.
- **Shaped:** area interiors and the build-in plan (`docs/build-in.md`, `BuildInConfig`), the
  multiplier / speed pad kinds in the economy (`docs/economy.md`), and `ProducerBillboards`.

### 14-halloween-sticker-sheet

- **File:** `docs/reference/sell-lemons/14-halloween-sticker-sheet.png` → `assets/reference/sell-lemons/14-halloween-sticker-sheet.jpg`
- **Shows:** a seasonal event sheet with an orange-bordered dark panel, a red round X and a 5 x 4
  grid of "?" sticker slots. At the bottom are a reward silhouette, "Collect all stickers to
  redeem!", a 0/20 progress bar and a grey Redeem button. An EVENT HUD button is on the right.
- **SellNukes took:** the event collection sheet idea: 20 stickers unlock an exclusive reward.
  SellNukes mirrors it with its **own** Thanksgiving event and art.
- **Shaped:**
  - `Screens/StickerSheet`, which cites this file but is drawn in SellNukes' stud style;
  - the Harvest Feast event (`docs/event.md`);
  - 20 original Blender / Fluent "Feast Sticker" icons with a die-cut sticker look
    (`docs/icons.md`);
  - the HUD Event button.

  Owner R94 ("the harvest shop clips off") led to `StudUI.button` auto-shrinking any overflowing
  label.

### 15-lemon-depot-manager

- **File:** `docs/reference/sell-lemons/15-lemon-depot-manager.png` → `assets/reference/sell-lemons/15-lemon-depot-manager.jpg`
- **Shows:**
  - a depot producer whose billboard has a green stud **CLICK** bar (manual production before
    automation), an X8 badge and an UPGRADE pill;
  - a grey round pad, "MANAGER — automates Lemon Depot — $14 trillion";
  - two round navigation buttons at the bottom centre: a blue swirl (teleport) and a yellow down
    arrow.
- **SellNukes took:** click-to-produce first (the idle producer's bar reads "CLICK"), then a
  Manager pad that automates that producer. The bottom navigation buttons led to the Teleport
  screen.
- **Shaped:**
  - `ProducerBillboards` (the CLICK bar while a manual producer idles);
  - the manager system (`docs/managers.md`: Manager pads, `Automated` attribute, `manager_hired`
    juice);
  - the Teleport screen (16).

### 16-teleport-menu

- **File:** `docs/reference/sell-lemons/16-teleport-menu.png` → `assets/reference/sell-lemons/16-teleport-menu.jpg`
- **Shows:** a "TELEPORT" window (blue border, red round X, dark rows) that scrolls through the
  areas. Each row has a 3D silhouette icon. Unlocked areas show a running-man / portal teleport
  button. A locked area shows a padlock and a progress bar, "7 / 8 purchases". A just-unlocked
  area shows "unlocked".
- **SellNukes took:** a teleport list of areas in which locked entries show **progress toward
  unlocking** ("n / m purchases") instead of a dead button.
- **Shaped:**
  - `Screens/Teleport` (world tabs, spawn rows, areas, players' plots);
  - `Client/Worlds/WorldTabBar`;
  - the `WorldUnlocked` locked preview ("Reach BoomDash Delivery: 6 / 9 purchases");
  - `IconAssets.Categories.area` (ten area icons in teleport order);
  - `docs/worlds.md` and `docs/ui.md` §10.

### 17-depot-buy-buttons

- **File:** `docs/reference/sell-lemons/17-depot-buy-buttons.png` → `assets/reference/sell-lemons/17-depot-buy-buttons.jpg`
- **Shows:** two grey tyre pads side by side: a multiplier ("REFRIGERATED TRUCKS — x… cash —
  $970 billion") and a decoration ("FRAMING — $115 billion"). A floating **"YOU"** marker sits
  over the player's own plot in the distance. A yellow up-arrow nav button is at the bottom.
- **SellNukes took:** a multiplier pad and a decoration pad side by side so the choice is visible,
  plus a big "YOU" marker over your own plot.
- **Shaped:**
  - `Tycoon/YouMarker` (a big "YOU" plus an arrow over the plot entrance; works while streamed
    out; follows `CurrentWorld`);
  - the pad kinds in `PadBillboards`;
  - `docs/tycoon-client.md`.

### 18-crypto-mine-cave

- **File:** `docs/reference/sell-lemons/18-crypto-mine-cave.png` → `assets/reference/sell-lemons/18-crypto-mine-cave.jpg`
- **Shows:** a late-game themed sub-area: a warm sandy stud-block cave with gold coin tokens on
  the floor, a lantern, and a floating label "CRYPTO MINERS — x3 speed".
- **SellNukes took:** themed sub-areas with their own material and palette, and collectibles
  lying on the floor.
- **Shaped:**
  - Area 4 **Glow Rock Mine**, whose Blender builder `tools/blender/models/area04.py` uses
    "warm sandy stud rock (reference: sell-lemons 18 crypto cave)";
  - `docs/areas-art.md`;
  - the speed pad kind.

---

## 4. missiles-vs-cities: stud nukes and the attack side mode (19, 21–26)

These are from a base-builder where players buy, upgrade and launch rockets at other islands.
Owner R3: "a really good example of like the nuke models" plus "eventually start nuking people just
for fun, and put up AA towers and upgrade them ... not the primary point, a side thing". They
shaped:
- the **world art style**: stud-textured blocky pieces, hazard stripes, a toy island
  (`docs/world-art.md` cites this folder);
- the **HUD icon look** (`docs/icons.md` cites 21);
- the **attack side mode** (`docs/attack.md`, spec §9).

SellNukes keeps the attack mode kid-friendly by construction, under hard rule 7 and owner R50:
- a hit **never permanently takes anything**;
- it mints a bonus for the attacker;
- it may topple the area it lands in like toy bricks, with confetti; the area auto-rebuilds;
- it gives the target a free Revenge nuke.

The older note in `docs/reference/README.md` about "stealing a slice of uncollected cash" is out
of date; R50 and `docs/attack.md` win.

### 19-stud-nuke-silos-launch-panel

- **File:** `docs/reference/missiles-vs-cities/19-stud-nuke-silos-launch-panel.png` → `assets/reference/missiles-vs-cities/19-stud-nuke-silos-launch-panel.jpg`
- **Shows:**
  - three chunky rockets built from stud-textured blocks (red/black, mint/black, white/gold
    tiers) standing in grey striped gantry frames on a stud deck with yellow/black hazard tiles;
  - a small panel, "Rocket 25 · Lv 75", with **Launch**, "+100% DMG" (a cash price) and a gem
    price;
  - a HUD of big square 3D icon buttons (Gift, Rewards, Rebirth, Shop, Attack, Allies, Naval,
    Settings) with "2X CASH" / "5X DAMAGE" quick-buy buttons;
  - gems + cash + "+…/s" at the top centre;
  - a "Get notified! TURN ON" card.
- **SellNukes took:**
  - nukes and rockets built from stud blocks in tiered colourways;
  - striped gantry posts;
  - hazard-stripe floors;
  - a compact launch / upgrade panel.
- **Shaped:**
  - Area 7 **Launch Silos** (`docs/areas-art.md`): three hazard-bordered launch platforms with
    striped gantries and tier colourways red/black, mint/black and white/gold. Each nuke has a
    glowing green core band and a plain yellow trefoil badge, and no faces.
    `tools/blender/models/area07.py` cites this file for the gantry posts.
  - the Silo Launch producer billboard;
  - the cartoon pocket-nuke models (`docs/world-art.md`).

### 21-silos-hud-wide

- **File:** `docs/reference/missiles-vs-cities/21-silos-hud-wide.png` → `assets/reference/missiles-vs-cities/21-silos-hud-wide.jpg`
- **Shows:** the same silo pad in a wider view. It shows the full HUD clearly:
  - glossy 3D icon tiles with thick outlines in two columns on the left;
  - quick-buy Robux buttons;
  - the gems / cash / rate stack at the top centre;
  - the purple calendar "DON'T MISS OUT — Get notified! TURN ON" card at the bottom centre.

  It also shows stud roads, hazard floors and the sea around the island.
- **SellNukes took:**
  - the **rendered, glossy 3D icon** look with thick dark outlines (owner R9: "rendered instead
    of flat");
  - the **top-centre currency stack** (gems, cash, +$/s), which SellNukes uses instead of the
    ui-style shots' bottom-left counter;
  - a notification opt-in card.
- **Shaped:**
  - `docs/icons.md`, which names this file as the icon look target;
  - the `tools/ui/icons` pipeline;
  - `UI/Hud/HudCurrency` and the HudZones "Top" zone;
  - `Screens/NotifyPrompt` + `PromptMoments` (`docs/retention.md`), queued in the PopupQueue
    centre lane;
  - `A7_HazardFloor`.

### 22-attack-target-select-island

- **File:** `docs/reference/missiles-vs-cities/22-attack-target-select-island.png` → `assets/reference/missiles-vs-cities/22-attack-target-select-island.jpg`
- **Shows:**
  - a top-down camera over an enemy island base (farms, solar panels, roads, an airfield, a
    harbour);
  - a target player's name between big ◀ ▶ arrows at the top;
  - a red reticle and a "2" marker on the base;
  - a grey **CANCEL** button at the bottom.
- **SellNukes took:** a target picker with a top-down camera over the target plot, `◀ name ▶`
  cycling, an aim marker and CANCEL. The HUD is hidden (focus mode) while picking.
- **Shaped:**
  - `Screens/AttackTarget/{AttackScreen, AttackHudScreen, PickerLayout}` (the header cites 22 and
    25);
  - `docs/attack.md` "Pick".

  Owner R118 ("all of these clip") made the aim buttons de-collide (`PickerLayout`). R133 made the
  picker show the target's base.

### 23-island-base-rocket-launch

- **File:** `docs/reference/missiles-vs-cities/23-island-base-rocket-launch.png` → `assets/reference/missiles-vs-cities/23-island-base-rocket-launch.jpg`
- **Shows:**
  - a whole island plot: stud roads with yellow dashes, farms, houses, a harbour and a
    white/gold stud rocket;
  - the rocket lifting off on a smoke trail;
  - floating green "+1.6M" income pops over buildings;
  - other islands floating in the sea.
- **SellNukes took:**
  - the world as a toy island with plots on a ring road;
  - floating "+$X" income pops;
  - a launch moment worth watching.
- **Shaped:**
  - `tools/blender/models/scenery.py` ("The world is a toy island (missiles-vs-cities
    references): hub + ring road + 8 plots sit on raised …");
  - `Tycoon/IncomePops` (pooled "+$X" pops);
  - the launch cinematic `Client/Attack/LaunchCam` (owner R54, `docs/attack.md`).

### 24-aa-tower-intercept-sky

- **File:** `docs/reference/missiles-vs-cities/24-aa-tower-intercept-sky.png` → `assets/reference/missiles-vs-cities/24-aa-tower-intercept-sky.jpg`
- **Shows:** a sky view in which AA towers on stud buildings fire bright interceptor trails up at
  an incoming missile.
- **SellNukes took:** AA towers that visibly shoot interceptors at incoming nukes, levelled by
  the defender.
- **Shaped:**
  - the Area 7 `A7_AATower` base with its "AA DEFENSE" placard;
  - the levelled `AATower1..5` models;
  - `Screens/Defense/DefenseScreen` (buy and upgrade towers and shields);
  - owner R80 ("buttons to buy AA towers ... for your island");
  - `docs/attack.md` (tower fire schedule, Barrage saturation).

### 25-island-overview-in-combat-barrage

- **File:** `docs/reference/missiles-vs-cities/25-island-overview-in-combat-barrage.png` → `assets/reference/missiles-vs-cities/25-island-overview-in-combat-barrage.jpg`
- **Shows:**
  - a base under attack: a translucent **hex shield dome** over the plot, smoke, and the HUD
    tiles on the left;
  - a "Send 20 missiles — BARRAGE 45 R$" Robux card at the bottom centre;
  - a red "IN COMBAT — Leave now = lose 50% cash" warning.
- **SellNukes took:**
  - the hex shield dome;
  - a Barrage product that sends a burst of nukes.

  It **deliberately did not take** the "IN COMBAT / lose 50 % cash" mechanic, which breaks hard
  rule 7.
- **Shaped:**
  - Shields: 3 hits earn a free 10-min shield, and the "Shield (1 h)" product stacks to 48 h;
  - the Barrage product: +20 stored nukes, BARRAGE in the picker;
  - `docs/attack.md`, which states "There is no 'IN COMBAT' banner";
  - `AttackScreen`.

### 26-nuke-reactor-tower-shield-dome

- **File:** `docs/reference/missiles-vs-cities/26-nuke-reactor-tower-shield-dome.png` → `assets/reference/missiles-vs-cities/26-nuke-reactor-tower-shield-dome.jpg`
- **Shows:** a grey stud reactor tower with a yellow radiation trefoil, a yellow/black hazard ring
  at its base and red beacon lights. A hex shield bubble arcs over the base. Small coloured player
  name tags float overhead.
- **SellNukes took:**
  - stud reactor architecture with a cartoon trefoil and hazard rings;
  - the shield bubble;
  - small coloured name tags over players.
- **Shaped:**
  - reactor props and finale art: Garage Lab `A1_MiniReactor` / `A1_ReactorPack`, the Area 10
    `A10_ReactorDome` and its trefoil entry arch (`docs/areas-art.md`);
  - the shield dome (`docs/attack.md`);
  - stud name tags over players (`Client/Social/PlayerTitleClient`, owner R73 / R74,
    `docs/ui.md` "Player Titles").

---

## 5. tooling: the Studio MCP (20)

### 20-studio-robloxstudio-mcp-v3.2.1

- **File:** `docs/reference/tooling/20-studio-robloxstudio-mcp-v3.2.1.png` → `assets/reference/tooling/20-studio-robloxstudio-mcp-v3.2.1.jpg`
- **Shows:** Roblox Studio with the **"MCP Server v3.2.1"** plugin dialog. It reads "Connected"
  on `http://localhost:58741` and shows HTTP server, MCP bridge and Commands all on. The Rojo
  7.7.1 panel shows "SellNukes localhost:34872". The Plugins toolbar includes Rojo and MCP Server.
- **SellNukes took:** this is not art. It is the owner's proof of **which** MCP to use (owner R4:
  "It's a different MCP than the one I think you're trying to use").
- **Shaped:**
  - the CLAUDE.md "Roblox Studio MCP (IMPORTANT — which MCP)" section: `@chrrxs/robloxstudio-mcp`
    v3.2.1 on :58741, not the old port-3001 bridge;
  - `scripts/studio_mcp.py`, which reads the auth token from its file and never prints it;
  - the Studio lock rules;
  - the skill's own `studio-mcp-and-screenshots.md`.

---

## 6. Common HUD language across the shots

SellNukes kept these patterns. The ui-style shots (01–06) share one HUD, and 19 / 21 / 25 / 26
share another.

| Pattern in the references | SellNukes version | Where |
|---|---|---|
| Left column of square stud tiles with 3D icons and outlined labels (Shop, Rewards, Daily, Codes, a wide rainbow Lucky Wheel, Time) | Left stack Shop, Pets, Quests, Rewards, Attack, MORE (2 x 3); Daily / Time / Wheel / Codes / Group folded into the Rewards hub (R62, R110) | `HudZonesConfig.Left`, `Hud/HudButtons`, `Screens/RewardsHub` |
| Right column of spiky dark "starburst" Robux offers with a green price coin (x2 Speed, x5 Spins, Teleporter, Starter Pack, Secret Pack, VIP) | `StudUI.starburst` offers, at most 2 on screen (R95), with live `PriceBook` prices and an **original** green hexagon price coin (not Roblox's logo file) | `HudZonesConfig.Offers`, `Hud/HudOffers`, `docs/icons.md` |
| Cash counter with a money-stack icon and a chunky green outlined number (bottom-left in 01–06; top-centre with gems and $/s in 19–26) | Top-centre currency stack: gems, cash, +$/s, and a boost badge on the cash corner (R82) | `Hud/HudCurrency`, HudZones `Top` |
| Quick-buy pills ("2X CASH 15 R$") | Offers plus the boost chips / badge | `Hud/HudOffers`, `Screens/BoostChips` |
| "Get notified! TURN ON" card | Notification opt-in card at polite moments | `Screens/NotifyPrompt` |
| Big outlined world text and billboards | Producer / pad billboards and title tags, sized in studs with `MaxDistance` culling | `Tycoon/*Billboards`, `PlayerTitleClient` |

---

## 7. How to use reference images

**Originality rules (inspiration only).**
- **Copy the feel, the layout language and the system ideas.** Never copy another game's art,
  names, logos, exact layouts or text. `docs/reference/README.md` says: "we copy the *feel*,
  layout language and the systems they show, never their art, names, or exact layouts. SellNukes
  is its own game ... not a recreation of any other game."
  - Every model is built in SellNukes' own Blender builders.
  - Every icon is Fluent Emoji 3D (MIT) or an original render.
  - Every name is original: BoomDash Delivery, Harvest Feast, Nukey, Glow Rock Mine.
- **Kid-friendly translation.** Nukes are candy-coloured toys with no faces, and explosions are
  confetti. There are no real countries or real weapons. Mechanics that punish (the reference's
  "lose 50 % cash", stealing cash) are replaced: nothing is ever permanently taken (hard rule 7).
- **Never copy what you can read in a screenshot.** That includes player usernames, other games'
  titles, URLs and group names. When you describe a reference, write "a player name" or "the
  shop's name".
- **Make it work on every device.** The references are desktop captures. Every pattern still has
  to work with ≥ 44 pt taps, ≥ 14 pt text, TV-safe margins and full gamepad navigation (R11).
  Several reference layouts (the 3 x 2 reward grid, the full offer column) had to be redesigned
  for phones (`ResponsiveModal`, R59 phone HUD, R95).
- **The owner's later words beat the reference.** When an owner request contradicts a reference
  (fewer offers, fewer left tiles, a smaller chip), follow the request and note it.

**How the owner supplies screenshots.** The owner pastes images into the Claude Code
conversation, usually with a short spoken-style comment.
- **References** ("save these photos so you can reference them", R2): file them as described
  below.
- **Bug or feedback screenshots** (for example R59 phone HUD, R102 clipping popups, R138 iPhone
  chip): do not file them as references. Describe them in words inside the request's entry in
  `docs/owner-requests.md`, as `(screenshot: what it shows)`, then fix the problem. Store your own
  before / after proof under `docs/verification/<feature>/`.
- When an image is attached, look at it. Do not guess its content from the message text.

**How to file and annotate a new reference.**
1. Pick or create a category folder under `docs/reference/` named for the source or theme
   (`ui-style/`, `sell-lemons/`, `missiles-vs-cities/`, `tooling/`).
2. Save each image as `NN-short-kebab-description.png`. `NN` continues the global numbering in
   arrival order (the next free number is 27).
3. Add a row to that category's table in `docs/reference/README.md` with three columns: `File`,
   `What it shows` (the concrete UI or world elements, with labels quoted), and `Take from it`
   (the specific patterns SellNukes adopts). Add a paragraph under the table for any owner
   description that came with the images (for example the build-in description) and for what
   SellNukes deliberately does differently.
4. Log the owner message in `docs/owner-requests.md` with the date, the quoted key words and
   "→ docs/reference/...".
5. Cite the reference in the modules it shapes. Put the path in the module header, as
   `Screens/DailyRewards`, `Screens/Shop/PackCard`, `LuckyWheel/WheelDrawing` and
   `tools/blender/models/props.py` do. Then `grep -rn "<NN>-" src tools docs` finds every
   consumer.
6. For this skill: add a compressed copy at `assets/reference/<subfolder>/<NN-name>.jpg` (about
   1600 px wide, JPEG quality ~80) and a section in this file.

**How to work from a reference while building.**
1. Open the image and list its elements: header colour, icon placement, button states, text
   hierarchy, spacing.
2. Map each element to an existing kit piece (`StudUI.window`, `card`, `button`, `starburst`,
   `hudButton`, ...) and a colour preset. Only add a new kit piece when nothing fits, and then add
   it to `StudUI`, not to the screen.
3. Build at the reference's proportions on the 1920 x 1080 design canvas. Then make the phone
   layout and the gamepad navigation.
4. Compare against the reference in the UI gallery (F6 in Studio) and in a device-matrix capture.
   The capture goes in `docs/verification/`, never in `docs/reference/`.
