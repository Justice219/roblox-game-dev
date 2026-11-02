# SellNukes — game design spec (2026-10-30)

Owner brief (verbatim intent): an 8-player, linear, step-on-the-button Roblox tycoon about
building and selling (cartoon, kid-friendly) nukes. Start in a little garage with a homemade
reactor, end with a massive nuclear facility. Money-per-second loop: click to produce first, then
upgrade and automate. The tutorial is the first area itself. Every purchase "builds in" LEGO-master-
builder style. The whole game, UI and world, uses the RoBeasts stud-texture look. Every model is
built in Blender and imported. Lots of monetization, eggs/pets, crates, daily rewards, time rewards,
lucky wheel, codes, group rewards, offline earnings, a Thanksgiving event, and a side "send nukes at
other bases / build AA towers" mode. At least 8 hours of gameplay. Reference images and notes:
`docs/reference/README.md`.

Owner rules carried over from RoBeasts: secure + performant, no shortcuts; every system ships with
its full UI; heavy commenting; strict Luau; Blender meshes for art; living documentation; fully
autonomous development (decide, document, keep going).

---

## 1. Tone and content rules (kid-friendly)

* Nukes are **cartoon toys**: chunky stud-textured rockets in candy colours with a glowing green
  core and a radiation-trefoil decal. No real countries, flags, real weapons, gore, or death.
* Explosions are **confetti mushroom clouds** (green/yellow puffs, stars, "BOOM!" pop text). Hit
  buildings wobble and puff smoke, then recover. Nobody ever loses a building, area or upgrade.
* NPC copy is silly and upbeat ("Fresh Nukes! Get 'em while they glow!").
* Player-typed text (stand sign names) is filtered with `TextService:FilterStringAsync` for
  broadcast before anyone else sees it.

## 2. Core loop

1. **Produce.** Each area has one *producer* (workbench, stand, delivery app, mine, ...). Before its
   Manager is bought, a producer only runs a cycle when the player **clicks** it (ClickDetector /
   ProximityPrompt / tap). A cycle fills a stud progress bar, then pays `$ per cycle` into Cash.
2. **Upgrade.** The producer's billboard has an **UPGRADE** pill (E / tap) that buys levels.
   Output grows linearly with level; every 25 levels a milestone alternates **x2 cash** and **x2 speed**
   (cycle time floor 0.1 s, further speed milestones convert to x2 cash). The badge shows the current
   cash multiplier (x2, x4, x8 ...), and a small "x77" shows the level, like the reference.
3. **Buy pads.** Round tyre-ring pads appear in a fixed linear order. Stepping on one with enough cash
   buys it and the purchase **builds in front of you**. Pad kinds:
   * `Build` (structure/decoration — walls, fences, floors, lamps; gives a small permanent +% to that
     area's producer so it never feels useless; counts toward the area's purchase total)
   * `Multiplier` (x2 / x3 / x4 cash for one producer)
   * `Speed` (x2 speed for one producer)
   * `Manager` (automates the producer; idle + offline income start here)
   * `Unlock` (opens the next area; the last area's finale unlocks **Rebirth**)
   * `Feature` (unlocks a system: AA tower, attack console, stand sign rename)
4. **Next area.** Each area is a new themed business on the same plot, further back along the
   plot's road. Earlier areas keep producing (cumulative income, AdCap-style); each new area's base
   income is far larger, so the newest area is always the focus.
5. **Rebirth.** After the finale, rebirth resets cash, levels and pads, keeps pets, gems, passes and
   cosmetics, and grants a permanent cash multiplier (+50% per rebirth, stacking) plus Rebirth
   Tokens for the Rebirth shop (bigger click power, faster managers, more offline time, more pet
   slots).

### Pacing target

A first run (no Robux) reaches the finale in **~8 hours** of active play; every rebirth shortens the
run. Per-area target minutes (tuned by `tests/EconomySim.luau`, which simulates a greedy player and
fails if any area drifts more than ±20 %):

| # | Area | Target min | Cumulative |
|---|------|-----------|------------|
| 1 | Garage Lab (tutorial) | 8 | 0:08 |
| 2 | Nuke Stand | 15 | 0:23 |
| 3 | BoomDash Delivery | 25 | 0:48 |
| 4 | Glow Rock Mine | 35 | 1:23 |
| 5 | Enrichment Lab | 45 | 2:08 |
| 6 | Rocket Factory | 50 | 2:58 |
| 7 | Launch Silos | 60 | 3:58 |
| 8 | Nuke Megastore | 70 | 5:08 |
| 9 | Space Port | 80 | 6:28 |
| 10 | Mega Nuclear Facility | 90 | 7:58 |

## 3. The ten areas

Every area: one producer, 8–11 pads, a themed floor/wall shell that builds in, billboards, and an
entry arch with the area name. Pads unlock in order (each pad lists its prerequisite pad).

1. **Garage Lab** — tiny suburban garage, pegboard tools, a bubbling "Mini Reactor" on a workbench.
   Producer *Pocket Nuke Workbench*. Pads: Workbench (free, tutorial step 1), Tool Wall, Glow Lamp
   x2, Garage Door, Mini Reactor x2 speed, Paint Station x3, **Uncle Atom (Manager)**, Driveway,
   *Open the Nuke Stand* (unlock).
2. **Nuke Stand** — roadside wooden stand, striped awning, "Fresh Nukes!" sign (**renamable**).
   Producer *Nuke Stand*. Pads: Counter, Awning, Cash Register x2, Tip Jar x2, Neon Sign x3, Cooler
   x2 speed, Picket Fence, **Cashier Bot (Manager)**, Picnic Tables, *Start BoomDash* (unlock).
3. **BoomDash Delivery** — delivery app HQ with scooters zipping along a lane. Producer *BoomDash
   Orders*. Pads: HQ Shell, Scooter Rack, Scooters x2, GPS x2 speed, Mobile App x4, Delivery Van x3,
   Parking Lot, **Dispatcher (Manager)**, *Dig the Mine* (unlock).
4. **Glow Rock Mine** — stud cave with glowing green crystals and mine carts. Producer *Glow Rock
   Drill*. Pads: Mine Entrance, Support Beams, Pickaxe Crew x2, Cart Track x2 speed, Drill Rig x3,
   Crystal Lamps, Glow Vein x4, **Foreman (Manager)**, *Build the Lab* (unlock).
5. **Enrichment Lab** — white clean-room lab, spinning centrifuges, bubbling vats. Producer
   *Centrifuge Row*. Pads: Lab Shell, Clean Room Floor, Centrifuges x2, Lab Coats x2, Computer Wall
   x2 speed, Glow Vats x3, Safety Signs, **Head Scientist (Manager)**, *Open the Factory* (unlock).
6. **Rocket Factory** — conveyor line, robot arms, paint booth. Producer *Rocket Line*. Pads:
   Factory Shell, Conveyor, Robot Arms x2, Fin Press x2, Paint Booth x3, Quality Check x2 speed,
   Forklift, Loading Dock, **Factory Boss (Manager)**, *Dig the Silos* (unlock).
7. **Launch Silos** — hazard-striped pad field, three silos, control room, radar dish. Producer
   *Silo Launches*. Pads: Silo Pad, Silo 2 x2, Silo 3 x3, Radar Dish x2, Control Room x2 speed,
   Hazard Floor, **Launch Director (Manager)**, **AA Tower** (feature), **Attack Console**
   (feature: unlocks Attack mode), *Open the Megastore* (unlock).
8. **Nuke Megastore** — mall storefront, shelves, mascot "Nukey", giant billboard. Producer
   *Megastore Checkout*. Pads: Storefront, Shelves x2, Escalators, Mascot Nukey x3, Billboard x2,
   Food Court, Parking Garage x2 speed, **Store Manager (Manager)**, *Build the Space Port* (unlock).
9. **Space Port** — launch tower, mission control, fuel tanks, satellite. Producer *Orbital
   Launches*. Pads: Launch Pad, Fuel Tanks, Mission Control x2, Booster Rockets x3, Satellite Dish x2
   speed, Astronaut Crew x2, Space Elevator x4, **Flight Director (Manager)**, *Build the Mega
   Facility* (unlock).
10. **Mega Nuclear Facility** — reactor dome, twin cooling towers with steam, turbine hall, pylons.
    Producer *Mega Reactor*. Pads: Reactor Dome, Cooling Tower x2, Cooling Tower II x3, Turbine Hall
    x2 speed, Power Lines x2, Control Tower, Fusion Core x5, **Chief Engineer (Manager)**, Golden
    Atom Statue (finale) → Rebirth.

## 4. World layout

* **8 plots in a ring** around a central **Hub**. Each plot is a long strip (≈ 160 × 520 studs)
  pointing outward, entrance facing the hub; areas 1→10 run front→back along the plot's road.
  All plot content is authored in plot-local space and placed with the plot's origin CFrame, so the
  rotation is free.
* **Hub:** spawn, leaderboards (top cash earned, top rebirths, top playtime), egg stands (one per
  area tier), crate stall, Lucky Wheel stage, group-reward chest, codes board, the Thanksgiving
  event square, and a pad ring that teleports to each plot.
* **Lobby + random plot (owner R13):** players spawn in the Hub (the lobby). The server assigns a
  **random free plot** (uniform among free plots); a "Your plot is #N!" banner + camera swoop shows
  it, then the player is teleported to their plot entrance (skippable). Ownership shows on the
  entrance sign and a "YOU" marker. On leave, the plot is saved and cleared for the next player.
* `Workspace.StreamingEnabled = true`; unbought content is never instanced (built only on purchase).

**Teleport rule (lead decision 2026-10-30):** teleporting to your own unlocked areas and to the
hub/lobby is free from the Teleport screen; the **Teleporter** pass adds teleporting to any other
player's plot. Locked areas show "x / y purchases".

## 5. Build-in animation (every purchase)

Server places the purchased model (authoritative, collidable immediately) and tags it with a
`BuildIn` timestamp. Each client within range hides the real parts with
`LocalTransparencyModifier = 1` and flies pooled ghost copies in from scattered offsets around the
buyer (translucent → solid, slight spin, staggered by part order, ~1.2–2.5 s total, one "clack"
sound per few parts), then reveals the real part and returns the ghost to the pool. Far-away or
late-joining clients simply see the finished model. Reduced-motion setting skips the flight.

## 6. HUD and screens (all stud-texture UI)

* **Top centre:** Cash (green money stack + chunky green number), Gems (purple gem), `+$X/s`.
* **Left stud button grid:** Shop, Rewards (group), Daily, Codes, Lucky Wheel (wide), Time, Pets,
  Rebirth, Teleport, Attack (after unlock), Event (during Thanksgiving).
* **Right starburst offers:** x2 Cash, Starter Pack, VIP, x5 Spins, Teleporter, Secret Pack —
  rotating, each with a green Robux tag.
* **Bottom:** tutorial arrow / objective chip; contextual "Welcome back" and purchase toasts.
* Screens: Shop (Limited Time packs, Gamepasses, Cash, Gems, Spins, Boosts), Daily Rewards (7-day
  streak, Day 7 rainbow card), Time Rewards (7 playtime gifts), Lucky Wheel (free spin timer, paid
  spin bundles), Codes, Group Rewards, Welcome Back (offline earnings, OKAY / DOUBLE IT!), Pets
  inventory + equip, Egg hatch reveal, Crate reveal, Rebirth, Teleport list (locked areas show
  "x / y purchases"), Attack target picker (◀ name ▶, CANCEL), Thanksgiving sticker sheet, Settings
  (music, sfx, reduced motion, hide others' pets), Rename stand sign (CANCEL / CONFIRM).

**Icons (owner R9):** every icon is a Blender-rendered, 3D-looking cartoon icon (chunky shaded
object, dark outline, soft highlight, transparent background), RoBeasts HUD-icon pipeline. Flat
frame-drawn glyphs are only a load-time fallback.

## 7. Retention systems

* **Offline earnings:** on join, server computes elapsed time from its own saved timestamp (never the
  client), pays `offlineRate × automated $/s × min(elapsed, cap)`; base cap 3 h at 50 %, Rebirth shop
  and the *Offline Max* pass raise it to 24 h at 100 %. Popup offers **Double It!** (dev product).
* **Daily rewards:** 7-day streak (Day 7 = rainbow card), resets after a missed day (48 h window).
* **Time rewards:** 7 gifts at 5, 15, 30, 60, 90, 120, 180 min of session playtime.
* **Lucky Wheel:** free spin every 20 min (stackable to 3), paid spins x2 / x5 / x10, slices scaled to
  the player's income (cash), gems, boosts, an egg, a rare pet.
* **Codes:** server-side code table with expiry, one claim per player.
* **Group rewards:** join the group → cash + exclusive pet (`Player:IsInGroup`, re-checked on claim).
* **Notifications prompt:** "Get notified! TURN ON" (ExperienceNotificationService opt-in prompt).

## 8. Pets, eggs, crates

* **Pets** follow the player (client-animated, server-owned inventory), each gives `+x%` cash.
  3 equip slots (+2 pass, +Rebirth shop). Rarities: Common, Uncommon, Rare, Epic, Legendary,
  Mythic, Secret. Cute radioactive critters ("Glow Slime", "Atom Pup", "Fission Fox", "Uranium Bunny",
  "Reactor Owl", ...). Blender-modelled.
* **Eggs:** one egg stand per area tier in the hub, priced to that area's economy (cash).
  Single / triple hatch (pass), auto-hatch (pass). Server-rolled odds, shown on the stand.
* **Crates:** "Supply Crates" bought with Gems or Robux; contain timed boosts (2x cash 15 min,
  2x speed), gems, eggs, pets, trails. Reveal animation reused from RoBeasts.

## 9. Attack mode (side feature, unlocked in Launch Silos)

* Players with an **Attack Console** pick another plot (target picker), then launch nukes from
  their silos on a cooldown. Nukes are physics-free server-timed arcs (server decides hit/miss and
  timing; clients only render the arc), so nothing is exploitable or laggy.
* Defenders own **AA Towers** (upgradeable range / fire rate / intercept chance) and **Shields**
  (timed dome; dev product + free 10-min shield after being hit 3 times).
* A hit pays the attacker a bonus equal to N seconds of the **target's** income, *minted*, not
  stolen. Hits play the confetti mushroom cloud; the target gets a free "Revenge" launch.
* **Temporary knockdown (owner R50, overrides the old "target loses nothing"):** the attacker aims
  at one of the target's built areas; the area containing the server-resolved impact point is
  knocked down — its stud buildings topple like toy bricks (confetti, no fire/gore), its producers
  and clicks pause for 45 s (+3 s per launcher level, max 90 s), then it auto-rebuilds with the
  master-builder fly-in; its owner can tap REBUILD! to speed it up. Nothing is ever permanently
  removed. A knocked-down plot gets 180 s knockdown immunity (hits still pay a reduced reward);
  shields block everything; the reward scales with the knocked area's income, bounded by the
  attacker's own income. Rival Factories knock down and rebuild the same way.
* New players (before area 7) and AFK-protected players cannot be targeted. Server-validated
  cooldowns, range, ownership and rate limits on every request.
* Monetization: Barrage (20 nukes, dev product), Mega Launcher pass (2x attack rewards), Shield.

**Always-available targets (owner R43, 2026-10-30):** 3–4 **Rival Factory** NPC bases on islands
just off the map edge (built from existing Blender sets), each with scaled AA/shields, are always in
the target picker for a smaller minted reward, so attack mode works solo and in early servers. AFK
protection is removed (the owner's brief is an "AFK nuke system"; targets lose nothing); only the
area ≥ 7 rule and shields protect players. The picker lists eligible players first, ineligible ones
greyed with the reason, then the Rival Factories.

## 10. Thanksgiving event — "Harvest Feast" (2026-11-01 → 2026-12-01 UTC)

* Event square in the hub: hay bales, pumpkins, a giant cornucopia, string lights, a Turkey NPC.
* **Golden Turkeys** wander plots and the hub; tapping one gives Acorns (event currency) and a chance
  at a **Feast Sticker**. 20 stickers fill the **Feast Sticker Sheet**; completing it redeems the
  exclusive **Gobble Bomb** pet. Acorns buy event eggs (Harvest Egg) and decorations.
* Event dev products: Acorn packs, Golden Turkey Lure (spawns a turkey on your plot).
* Driven by `EventConfig` with start/end timestamps; everything turns off cleanly after the end.

## 11. Monetization catalogue

Game passes: VIP (+50% cash, chat tag, VIP lounge), 2x Cash, Auto Clicker, Fast Walk, Teleporter,
Lucky Eggs, +2 Pet Slots, Triple Hatch, Auto Hatch, Offline Max, Mega Launcher.

Developer products: Cash packs ×4 (scaled to current income, with floors), Gem packs ×3, Lucky
Spins x2/x5/x10, Starter Pack (one-time), Secret Pack (global limited stock), Double Offline
Earnings, Server 2x Cash (15 min, whole server), 2x Cash 30 min (personal), Barrage, Shield 1 h,
Skip Pad (buys the next pad instantly), Acorn packs, Golden Turkey Lure.

All receipts processed idempotently server-side (receipt ledger in the profile, granted once).

## 13. Analytics — "track as much data as possible" (owner, 2026-10-30; RoBeasts model)

Server-authoritative **aggregate counters** (no per-player event stream, no PII), ported from
RoBeasts `AnalyticsService` / `AnalyticsStore` / `AnalyticsLogic` / `RobloxForwarder`:

* `count(family, key, amount)` into per-UTC-day families: **core** (sessions, length buckets, DAU,
  new/returning, D1/D3/D7/D14/D30 returns, payers, hour-of-day, device/platform), **revenue** (Robux,
  per-product count/Robux, prompt → purchase per source, offer shown/click, Robux by device),
  **economy** (cash/gems earned per reason, spent per category, pad buys, producer levels, rebirths,
  offline payouts), **tycoon** (area reached, time-to-area, pad id buy counts, manager timing,
  tutorial steps, click vs automated income share), **retention** (daily streak claims, time-reward
  claims, wheel spins + results, code redeems, group claims), **pets/crates** (hatches per egg,
  rarity distribution, crate opens), **attack** (launches, intercepts, hits, shields), **event**
  (turkeys, stickers, sheet redemptions), **health** (server frame time, ping, per-system Luau ms,
  client perf by device).
* Flushed every 60 s with idempotent `UpdateAsync` merges into DataStore `SellNukesAnalytics_v1`
  (`d:<day>:<family>:<shard>`), compacted by day/month; never written from Studio.
* Mirrored to the Roblox Creator Dashboard via a rate-limited forwarder: `LogEconomyEvent`
  (Source/Sink, ending balance, SKU), `LogOnboardingFunnelStepEvent` (tutorial = area 1 steps),
  `LogFunnelStepEvent` (purchase funnel), `LogProgressionEvent` (area reached / rebirth),
  `LogCustomEvent` (fixed names, config-id fields only).
* Funnels: **FTUE** (joined → profile loaded → first click → first pad → manager → area 2 → ...),
  **purchase** (offer shown → clicked → prompt → bought, with source attribution), **per-area
  progression**. Revenue ledger with idempotent receipt journal.
* Cardinality rules from RoBeasts: allowlisted labels only, key parts `[%w_-]` ≤ 32 chars, ≤ 2,500
  keys per family per day (overflow → `_other`).
* Read back in the **admin panel → Analytics tab**: headline cards (DAU, new, D1/D7, revenue,
  ARPDAU, payer %, median session, tutorial completion, area funnel), sections per family, and
  **COPY FOR AI** / **COPY RAW DATA** exports (paged text the owner can paste into an AI).
* Scorecard + experiment rules copied from RoBeasts `docs/analytics-scorecard.md`.

## 14. Owner admin panel (owner, 2026-10-30)

* Authorisation (server, re-checked on every command): Studio → everyone; `AdminConfig.AdminUserIds`;
  `game.CreatorId` (user 1586034782 owns the game); group rank ≥ 254 if the game moves to a group.
  `IsAdmin` attribute is UI-only.
* One `AdminCommand(name, args)` remote → token bucket → re-auth → allowlist → per-command cooldown
  → strict arg schema → pcall handler → audit log (ring buffer, printed to output) → result toast.
* Opened with **F2** / gamepad D-pad-down / an "ADMIN" HUD button visible only to admins.
* Tabs: **Players** (list with cash/gems/area/ping; grant/take cash & gems, set area, unlock all
  pads, reset plot, set rebirths, give pet/egg/crate/boost, teleport to/bring, kick, ban/unban via
  `BanAsync`), **Economy** (server-wide 2x boost on/off, test receipts in Studio), **Server**
  (announce — filtered, spawn Golden Turkey, force event on/off, set time of day, shutdown with
  warning), **World** (rebuild a plot, preview build-in animation, toggle debug overlays), **Live**
  (players, server FPS, memory, uptime, bandwidth, per-system ms), **Log** (audit), **Analytics**
  (§13), **New Player Mode** (play on a throw-away sandbox profile; purchases refused; analytics
  diverted).
* Every system added later must register its admin commands (rule 9 in `CLAUDE.md`).

## 16. Platforms: console + mobile first (owner R11)

* **Controller handler** (`src/client/Platform/`): one action map (Produce = ButtonR2 / F / tap,
  Upgrade = ButtonY / E, Buy-pad confirm = ButtonA when standing on a pad, Menu wheel = ButtonSelect,
  HUD focus = D-pad left, Close/Back = ButtonB, Teleport = D-pad up, Attack = D-pad right), context
  hint bar with the device's glyphs (Xbox / PlayStation / keyboard / touch), `HapticService`
  rumble on purchases, build-in completion, hatches and hits, TV-safe area (5 % inset on console).
* **Every screen** fully navigable by gamepad: default selection, logical NextSelection links in
  grids, scroll-follow, Back closes, no mouse-only hover states.
* **Mobile:** phone (short side < 600 pt) and tablet layouts, ≥ 44 pt tap targets, text ≥ 14 pt
  after scaling, HUD clear of the thumbstick (bottom-left) and jump (bottom-right) zones, landscape
  safe insets, producers tappable in the world (no tiny ClickDetectors).
* **Performance budget for mobile/console**: streaming on, lean triangle budgets, distance-culled
  billboards/FX, ≤ 60 active ghost parts during build-in, pooled everything.
* **Verification:** `capture_device_matrix` screenshots (phone, tablet, Xbox 1080p, 4K TV) for every
  screen; analytics splits every key metric by device.

## 15. Non-goals for v1

Trading, pet fusion, cross-server plot visits, voice features.
