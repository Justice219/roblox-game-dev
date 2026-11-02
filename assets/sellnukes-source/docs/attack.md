# SellNukes Attack mode (B10) — nukes, AA towers, shields, Revenge, Barrage

Side mode of the tycoon (owner R3: "eventually start nuking people just for fun, and put up AA
towers and upgrade them ... not the primary point, a side thing"; spec §9). Kid-friendly by
construction, with the owner R50 rule (hard rule 7, 2026-10-30): **a hit may TEMPORARILY knock
down the area it lands in; nothing is ever permanently lost** (cash, pads, producers, levels, pets,
gems untouched). The attacker AIMS at one of the target's built areas (§16); a hit mints a bonus for
the attacker scaled by that area's income, topples the area like toy bricks with confetti (45 s +3 s
per launcher level, then the master-builder rebuild; Q3's §13), and gives the target a free Revenge
nuke. New players (before area 7) and shielded players cannot be targeted; a just-knocked plot is
knockdown-immune for 180 s (hits then pay BlockedFactor with confetti, no knockdown). **AFK players CAN
be targeted** (owner R43: "AFK nuke system"). There is no "IN COMBAT" banner.

**Always usable (owner R43, "i have the silos but i cannot attack anyone"):** four **Rival Factory**
NPC bases on islands just off the map edge are always in the picker, so Attack mode works solo and
in early servers (§11).

## 1. How it plays

| Step | What happens |
|------|--------------|
| Unlock | Area 7 (Launch Silos) Feature pads: **AA Tower** (`a7_aa_tower`, AA level 1, levelled turret appears on the plot) and **Attack Console** (`a7_attack_console`, Launcher level 1, HUD **Attack** button + an "Attack Console" ProximityPrompt on the plot). |
| Pick | Attack button / console prompt / Revenge chip → the **target picker**: top-down camera over the target plot (or flown out to a Rival island), `< name >`, info line (area, AA level, $/s — or "Rival Factory · AA Lv N · Pays $X a hit"), status, LAUNCH / REVENGE, BARRAGE, CANCEL, DEFENSE. Order: eligible players (Revenge, ready) → ineligible players **greyed with the reason** (shield countdown, "Still new — Area 4 of 7") → the Rival Factories, easiest first. Never an unexplained empty list. |
| Launch | Server decides everything at once and sends one `NukeFlight` per nuke; every client draws the same arc. |
| Defend | The target's AA turret swings round and fires interceptors (misses fly past and puff, a hit → mid-air **POP!**). |
| Hit | Confetti mushroom cloud + "BOOM!", nearby buildings wobble and recover, attacker toast `BOOM! +$X`, target toast `You got nuked by X! Free REVENGE ready!` + a REVENGE chip. |
| Shields | 3 hits earn a **free 10-min shield** (chip / Defense screen → `ShieldActivate`); **Shield (1 h)** product stacks up to 48 h. A hex dome covers the plot. |
| Barrage | **Barrage** product = +20 stored nukes; BARRAGE in the picker sends up to 20 at once (0.2 s apart, no cooldown). Bought from the picker → sent automatically when the purchase lands. |
| Mega Launcher | Game pass: x2 attack rewards. |

## 2. Rules (Shared/Attack/AttackLogic + AttackConfig)

* **Eligibility** (`AttackLogic.canLaunch`):
  * `normal` — attacker owns the console, target loaded with a plot, area ≥ 7, no shield, attacker off cooldown (no AFK rule).
  * Rival Factory — the same rules through `AttackLogic.rivalActor` (always loaded, area 7, shielded per its cycle, userId 0): normal / barrage only; `revenge` is refused.
  * `barrage` — as normal but needs ≥ 1 stored barrage nuke instead of the cooldown.
  * `revenge` — a live token (attacker hit you in the last 180 s); ignores cooldown and the attacker's shield, and needs no console. **Revenge hits never grant a counter-token** (no endless ping-pong).
* **Reward per hit** = `rewardSeconds(launcher) × clamp(targetIncome, 0.25 × myIncome, 2 × myIncome) × factor(kind) × (MegaLauncher ? 2 : 1)`, factor normal 1 / revenge 1 / barrage 2. Paid with `grantCash(..., "attack_hit")` at impact (attacker still in the server). Bounded by the attacker's own income, so no alt can be farmed.
* **Levels** (`AttackConfig.Launcher` / `.AA`, every number only improves — owner rule):

| Lv | Cooldown | Reward s | Armor | Nuke | AA range | AA reload | AA chance/shot |
|----|---------|----------|-------|------|----------|-----------|----------------|
| 1 | 30 s | 8 | 0 % | Nuke1 | 260 | 1.5 s | 22 % |
| 2 | 27 s | 9 | 8 % | Nuke2 | 300 | 1.25 s | 25 % |
| 3 | 24 s | 10 | 16 % | Nuke3 | 340 | 1.05 s | 28 % |
| 4 | 21 s | 11 | 24 % | Nuke4 | 380 | 0.9 s | 31 % |
| 5 | 18 s | 12 | 32 % | Nuke5 | 430 | 0.75 s | 34 % |

  Reward per cooldown second is 0.27×–0.67× of the attacker's own income against an equal target
  (a side bonus, tested `< 1`). Upgrade L→L+1 costs `pad price × {4, 40, 400, 4000}` (pad = the
  kind's Area 7 Feature pad, so prices follow the economy tuner). Levels persist through Rebirth
  but count only while the Feature pad is owned again (`AttackLogic.effectiveLevel`).
* **Single-nuke intercept rate** (tests, every plot pair × impact point, seeded):

| AA \ Launcher | L1 | L2 | L3 | L4 | L5 |
|---|---|---|---|---|---|
| AA1 | 27 % | 24 % | 22 % | 21 % | 19 % |
| AA3 | 54 % | 51 % | 47 % | 44 % | 39 % |
| AA5 | 81 % | 78 % | 75 % | 71 % | 66 % |

  A Barrage saturates a tower (its fire schedule carries over between nukes).

## 3. Flight + interception maths (Shared/Attack/FlightMath, AttackGeometry, AttackRng)

* Arc: `p(t) = lerp(A, B, s) + up × 4 × apex × s(1−s)`, `s = t / duration`;
  `duration = clamp(3.4 + d/190, 5, 10)` s, `apex = clamp(0.42 d, 150, 340)` studs.
* A = silo mouth (Area 7 slot, `launchPoints` from `AreaLayouts/Area07` or AttackConfig fallback;
  silos 2/3 only once their pads are owned, round robin). B = one of 8 plot-local impact points
  near the target's AA tower, picked by the seeded RNG.
* Tower window: the in-range run of the arc closest to impact (96 samples + 12 bisection steps),
  clipped to `[InterceptorSeconds (0.9), duration − 0.35]`. Shots fire every `reload`, an
  interceptor meets the nuke `0.9 s` after firing, each succeeds with `chance × (1 − armor)`.
* RNG: mulberry32 + murmur3 mix (pure `bit32`), seeded `mix(perServerSecret, nukeId)` — the same
  code in Studio, live and in Lune; clients cannot predict outcomes.

## 4. Network contract

| Remote | Dir | Payload |
|--------|-----|---------|
| `AttackLaunch` | C→S | `(target: number (userId) \| string (Rival id / admin test bot key "bot:N"), kind: "normal" \| "revenge" \| "barrage" = "normal", area: integer 0..99 = 0)` — `area` = owner R50 aim (a BUILT area / rival section; 0 = default: the highest built area) |
| `NukeFlight` | S→C all | `{ id, fromUserId (0 = admin test / bot), fromBot?, toUserId (0 = Rival / bot), toBot?, t0 (server time = launch + LeadIn 3.4 s), flight (s), intercepted, interceptAt (s after t0), kind, fromPlot, toPlot (target SLOT: 1..8 plots, 9..12 Rival islands), silo, impact (legacy index), area (aimed area, 0 = legacy), sx, sz (scatter, studs), tier, shots, firstShot (s after t0), reload }` ≈ 180 B once per nuke; clients rebuild the arc with `AttackGeometry.flightOf` |
| `DefenseUpgrade` | C→S | `(kind: "aa" \| "launcher")` |
| `ShieldActivate` | C→S | `()` — turns on the earned free shield |
| `PromptProduct` / `PromptPass` | C→S | `"Barrage"`, `"Shield1h"` / `"MegaLauncher"` (MonetizationService) |
| `Notify` | S→C | coalesced toasts (one "BOOM! x14 +$X" per burst) |

Public Player attributes (DefenseService, change-only): `SN_AttackTargetable`, `SN_ShieldUntil`,
`SN_AALevel`, `SN_LauncherLevel`, `SN_AttackPlot`; the picker also reads B3's `TycoonArea` /
`IncomePerSecond`. ReplicatedStorage attribute `SN_AttackRivalsOn` (false = admin switched the Rival
Factories off on this server). Tags: `SN_AATurret` (turret model, attrs `Plot`, `Level`, `BarrelPitch`),
`SN_ShieldDome` (attr `Until`), `SN_AttackConsole` (prompt part, attr `OwnerUserId`).
Client templates: `ReplicatedStorage.AttackTemplates.{Nuke1..5, Interceptor, Puff}`.

## 5. Profile (`profile.attack`)

`{ aa, launcher, shieldUntil, cooldownUntil, hitsTaken, barrage }` — timers are server time,
whole seconds; `hitsTaken` is capped at 3 (free-shield progress). `barrage` = stored Barrage nukes
(whole, 0..`BarrageStorageLimit` 1e6 = ProfileLogic `LIMITS.MaxItemCount`). The Barrage **prompt** is
refused when the pack would not fit under `MaxStoredBarrage` (2,000) — the player is told before
paying; a granted **receipt is never clamped** (`AttackProfile.addBarrage`: the whole pack, or
`NotProcessedYet` at the storage bound, so paid nukes are never silently lost).
`stats.launches` / `stats.hits` are counted.
Owner R80 adds `towers` — the defence tower slot levels (dense list, index = slot, 0 = not bought;
older saves reconcile to `{}`); see §18.

## 6. Files

| File | Job |
|------|-----|
| `src/shared/Config/AttackConfig.luau` | Every tunable (levels, prices, rewards, flight, geometry fallbacks, models, attributes, limits, client bindings) |
| `src/shared/Attack/AttackLogic.luau` | Pure rules: stats, effective levels, prices, rewards, eligibility, shields, reasons |
| `src/shared/Attack/FlightMath.luau` | Pure arc / velocity / range window / interceptor scheduling + rolls |
| `src/shared/Attack/AttackGeometry.luau` | World points per plot (silos, impacts, muzzle, prompt, dome) + `flight(...)` |
| `src/shared/Attack/AttackRng.luau` | Deterministic 32-bit PRNG |
| `src/server/Services/AttackService.luau` | AttackLaunch, timeline, impacts (TimeQueue on one Heartbeat), rewards, Revenge, Barrage product, coalesced toasts, admin/test API |
| `src/server/Services/DefenseService.luau` | Per-player runtime, reconcile (levels, attributes, turret / prompt / dome), engage, DefenseUpgrade, ShieldActivate, Shield product |
| `src/server/Attack/{TycoonBridge, AttackWorld, AttackProfile, AttackAnalytics, TimeQueue, AttackAdmin}.luau` | Tycoon adapter, world objects + templates (plots and Rival islands), profile access, analytics (guarded), heap, admin commands (guarded) |
| `src/server/Attack/RivalIslands.luau` | Builds the Rival Factory islands from existing Blender sets (Idle-priority preload, then spawn) |
| `src/shared/Attack/RivalLayout.luau` | Pure island content list (area set + plinth + sign + dressing) |
| `tests/attack-rivals.luau` | 14k checks: rival config ladder, island placement clearance, slot geometry, every plot→rival flight engageable at every AA level, intercept ladder, rewards < equal-player hit, allowlist, shield cycle, picker order, free-shield cap, Barrage never loses paid nukes, onServerEvent wiring, no AFK / dummy seam (`ATTACK_REPORT=1` prints the rival table) |
| `src/client/Attack/{AttackClient, FlightRenderer, AttackFx}.luau` | Intake + state + intents + HUD button/prompts/domes; pooled BulkMoveTo flight rendering + turret aim; confetti cloud / POP / wobble / camera nudge |
| `src/client/UI/Screens/AttackTarget/{AttackScreen, AttackHudScreen}.luau` | Target picker ("Attack"); Revenge / free-shield chips ("AttackHud", boots AttackClient) |
| `src/client/UI/Screens/Defense/DefenseScreen.luau` | AA / Launcher upgrades, shield, Barrage, Mega Launcher ("Defense") |
| `tests/attack-logic.luau` | 49.6k checks: RNG, arc, windows, interception determinism + probability, saturation, every plot pair, rules, balance, heap, profile helper (`ATTACK_REPORT=1` prints the rate table) |

**Boot:** server `FEATURE_SERVICES` after the tycoon services: `"DefenseService"`, `"AttackService"`
(both product-selling; DefenseService first). Client: AttackHud is discovered by UIController and
starts `AttackClient` itself; it also exports `Init/Start`, so `"Attack/AttackClient"` may be added to
the client list.

## 7. Controls (owner R11)

| Action | Keyboard / mouse | Gamepad | Touch |
|--------|------------------|---------|-------|
| Open picker | HUD Attack button, E at the console | X at the console, D-pad left → HUD | tap |
| Prev / next target | Q / E, ← / → | LB / RB | `<` `>` buttons |
| Launch / revenge | Enter, Space, R (revenge) | A (selected), X (revenge) | LAUNCH |
| Barrage | B | Y | BARRAGE |
| Defense | V | LT | DEFENSE |
| Close | X, Backspace | B | CANCEL |
| HUD Revenge chip | R | D-pad Up | REVENGE! |
| HUD free shield chip | G | D-pad Down | TURN ON |

## 8. Analytics (attack family) and admin

Keys: `console`, `launch:<kind>` (amount = nukes), `intercept`, `hit`, `hitCash`,
`refused:<cooldown|protected|shield|target|rate|locked|other>`, `shield:<free|product>`,
`aa:<aa|launcher>:<level>` (kind `aaKind` registered), `targets:<0-8>` (eligible targets at each
accepted launch), `rival:<1-8>` (nukes launched at Rival Factory i). Client:
`FunnelStep("open", "Attack" | "Defense", source)`.

Admin (`AdminService.registerCommand`, Players tab): AttackTestNuke (a harmless test nuke at a
player's plot — their AA engages; one-person verification), AttackCooldown, AttackShield (minutes),
AttackShieldOff, AttackLevels (aa, launcher), AttackBarrage (count), AttackHitsReset; Server tab:
AttackStats (incl. rivals on/off), **AttackRivals** `{ on }` (Rival Factory kill switch, live, this
server).

## 9. Performance

Server: one Heartbeat that returns at once unless the impact heap head or a toast is due; a 1 Hz
reconcile over ≤ 8 players + ≤ 4 rivals; attribute writes only on change. Network: one
~150 B event per nuke, nothing per frame. Client: one PreRender while flights exist, one
`BulkMoveTo` per frame for every nuke / interceptor / turret part, pooled models / particles /
billboards (no `Instance.new` after warm-up), far flights not drawn, Reduce Motion skips wobble,
camera nudge and puff growth.

## 10. Next steps

* B8f art: `Nuke1..5`, `Interceptor`, `AATower1..5` (pieces `Turret`, `Barrel`; set attribute-free
  rest pitch 0), `ShieldDome` (one MeshPart), `NukePuff` — until then Nuke tiers reuse the Area 7
  silo nukes and the rest are stud primitives.
* B8c: `launchPoints`, `aaTowerMount` (on top of `A7_AATower`, mount top y = 17.6), `consolePrompt`
  in `AreaLayouts/Area07.luau`.
* B12: publish `Barrage`, `Shield1h` and the `MegaLauncher` pass ids.

## 11. Rival Factories (owner R43) — always-available NPC targets

Why: only other players at area ≥ 7 were targetable, so solo / early servers had nobody to nuke and
the feature looked broken ("i have the silos but i cannot attack anyone").

| # | Rival (id) | Island set | AA | Shield | Reward ratio | Intercept vs L1 |
|---|-----------|-----------|----|--------|--------------|-----------------|
| 1 | Rival Toy Factory (`toy_factory`) | Area 6 Rocket Factory | 1 | never | 0.20 | ~25 % |
| 2 | Grumpy Gus's Nukes (`grumpy_gus`) | Area 7 Launch Silos | 2 | 30 s / 4 min | 0.30 | ~35 % |
| 3 | Professor Fizz's Lab (`professor_fizz`) | Area 5 Lab | 3 | 45 s / 4 min | 0.40 | ~52 % |
| 4 | Mega Meltdown Mart (`mega_meltdown`) | Area 8 Megastore | 5 | 60 s / 5 min | 0.50 | ~80 % |

* **Where:** islands on the plot bisectors 22.5° + 90° k, centre r = 1080 (the beach ends at r 874,
  boundary ring 880, sea to 2000): > 130 studs of sea off the map edge, never on the hub, a plot or
  each other (tested with every model's MeshAssets footprint). Island-local frame = a WorldLayout
  slot (+Z away from the hub), so the area layout drops in unchanged and the factory fronts face the hub.
* **What:** the FULLY built area set (`AreaLayouts/AreaNN` base + every build, minus entry arches),
  an `A7_AATower` plinth with the levelled `AATowerN` turret, a `Plot_EntranceArch` sign with the
  rival's name (tinted), and scenery dressing (sunk hills, shore rocks, pines). Existing Blender
  meshes only (MeshLibrary), anchored + visual-only, Atomic streaming; preloaded at Idle priority so
  boot, plots and purchases never wait for them. No collision (unreachable).
* **Reward:** `rewardSeconds(launcher) × the ATTACKER's own income × rewardRatio × factor(kind) × Mega`
  (`AttackLogic.rivalReward`): every ratio ≤ `MaxRewardRatio` 0.5, so a rival hit always pays less
  than hitting an equal-income player. Same cooldowns, rate limits, per-attacker in-flight share and
  server authority as player launches; confetti hits; toast "BOOM! Direct hit on Grumpy Gus's Nukes!".
* **Defense:** each rival's tower uses the same FlightMath engagement as a player tower
  (`DefenseService.engageRival`, one fire schedule shared by all attackers, so barrages saturate it).
  Shields follow a deterministic cycle from the shared server clock (`AttackLogic.rivalShieldUntil`):
  the server, the dome and every picker agree with zero network traffic; rival 1 never shields, so
  one rival is always open.
* **Picker:** eligible players → greyed players with reason → rivals; the camera flies out to the
  island (`AttackGeometry.pickerView`: closer framing than a plot) and streams it in.
* **Admin:** `AttackRivals { on }` (Server tab) switches them off live on one server (launches
  refused, picker hides them, domes drop; islands stay as scenery).

## 12. Security fixes (Q2, 2026-10-30 — docs/security-audit.md Attack/Defense findings)

| Finding | Fix | Test |
|---------|-----|------|
| Barrage near the 2,000 cap paid for 20, received fewer | Prompt refused unless the whole pack fits (`AttackLogic.barrageFits`); receipts never clamped (`AttackProfile.addBarrage`, whole pack or NotProcessedYet at the 1e6 storage bound) | attack-rivals §7 |
| Free shield stacked past the 48 h cap | `AttackLogic.freeShieldFits`; the earned hits are kept | attack-rivals §7 |
| Late packets from departed players re-created limiter buckets | AttackLaunch / DefenseUpgrade / ShieldActivate connect through `Remotes.onServerEvent` | attack-rivals §8 (source check) |
| One player could saturate the server-wide in-flight cap | Per-attacker share `MaxNukesInFlightPerAttacker` (60) | — (server path) |
| Shield toast misleading vs Revenge | Toast says Revenge strikes still land | — |
| Studio dummy test seam | Removed: Rival Factories exercise the real launch path solo | attack-rivals §8 |

## 13. Knockdown (owner R50, Q3) — hits temporarily knock an area down

Owner: *"attack mode should actually do something, like give you money and temporarily knockdown
peoples areas depending on where it hits"*. Hard rule 7 (updated): nothing is ever PERMANENTLY
taken. A knockdown is temporary, is never saved, and removes or refunds nothing (cash, pads,
producers, levels, pets and gems are untouched).

**What happens** (the server decides, every client draws it the same way):

| Step | Server (`Server/Tycoon/Knockdown`) | Client (`Tycoon/BuildIn/KnockdownFx` + `Screens/Knockdown/KnockdownHudScreen`) |
|------|-----------------------------------|-------------------------------------------|
| Hit | Q2's impact calls `Knockdown.apply(subject, area, opts)`. The area's `AreaNN` model gets the tag `KnockdownTarget` and the attributes `KnockedAt`, `KnockedUntil`, `KnockCenter` | Everything standing in the area (`Builds` + the area `Base`'s walls / arch / props) tumbles away from the impact like toy bricks (arc, tip over, little bounce) with a confetti puff and low "bonk" clacks, then lies scattered. Ground pieces (thin, at the area's lowest level: floors, driveways, roads) never move and keep their collision. Flat pieces only tip a little; tall ones fall over. Rubble is walk-through (local collisions off) |
| Down | The area's producer pauses: no payout, no clicks ("This area got knocked down! ..."), no auto-clicker or manager work. The anchor shows `PausedAt`; nothing earned during the pause is paid later | Spinning / bobbing pieces freeze (`WorldFxController.setSuspended`). Managers sit dazed with stars (`ManagerController.setAreaDazed`). Billboards show "KNOCKED DOWN 0:45" (N2) |
| Target UI | Toast "Your LAB got knocked down! Rebuilding 0:45 - TAP TO REBUILD!" plus `KnockdownState` to the owner | Red stud chip above the Attack chips: "Your LAB got knocked down! / Rebuilding 0:45", a progress bar, and [TAP TO REBUILD!] (H key, LT on gamepad, tap; ≥ 44 pt on touch). The existing Revenge chip still shows |
| Tap | `KnockdownTap(area)`: −1 s per tap, never earlier than 6 s after the hit, ≤ 6 taps / s, owner only | `KnockedUntil` drops, so the countdown follows |
| Rebuild | At the deadline the attributes clear, the toast "Your LAB is rebuilt!" shows, the producer resumes where it stopped, and the immunity starts | The master-builder fly-in (`BuildInController.rebuild`) lifts every ghost off its rubble piece and snaps it home, build by build (0.15 s stagger), with clacks, confetti and haptics for the owner |
| Buy while down | Pads still work and the purchase is saved as usual | The new build stays hidden (`BuildInController.setDeferHook`) and flies in after the rebuild |

**Rules** (`Shared/Tycoon/KnockdownLogic`, tunables `Shared/Config/KnockdownConfig`):
* Duration `KnockdownConfig.duration(launcherLevel)`: Launcher 1 = 45 s, +3 s per level above 1,
  clamped 45..90 (L1..5 = 45 / 48 / 51 / 54 / 57 s). Any caller value is clamped server-side; the
  admin override wins.
* Immunity (anti-grief): the plot is immune while ANY of its areas is down and for 180 s after its
  LAST area comes back up. Tapping never shortens the protection.
* Barrage spill: within 6 s of a plot's first knockdown, the same attacker may knock down one more
  area (max 2 per volley). `Knockdown.isImmune` ignores this grace; `apply` applies it.
* Shields block every knockdown (`shielded`). The area ≥ 7 targeting rule is unchanged (AttackLogic).
* Refusal reasons: `immune` | `shielded` | `not_built` (bad area / not loaded / no own build there)
  | `disabled`. A refused hit still pays the reduced reward and the confetti (Q2).
* Cleared on leave, plot release, rebirth and admin resets (`TycoonService.resetRun` → `Knockdown.reset`).
  Offline earnings ignore knockdowns because they are computed from the saved profile.

**Subjects (owner R51):** every query takes `Subject = Player | BotSubject`, where
`BotSubject = { key, plotIndex, tycoon, shieldUntil }` is Q2's `Server/Attack/TestBots` record (a
superset). Bots get the same rules and replication on their plot slot (so they topple like a real
plot), and no toast, remote or analytics. `areaIncome` comes from the bot's tycoon state without
modifiers. `Knockdown.forgetBot(bot)` runs on removal.

**Contract (Q2 ↔ Q3):** `Knockdown.apply(subject, areaIndex, { durationSeconds, attackerUserId?,
source, center? }) → (ok, reason?)`, `isDown(player, area) → (bool, until?)`, `isImmune(player)`,
`areaIncome(player, area)` (that area's automated $/s with every modifier, same basis as
IncomePerSecond), `builtAreas(player)` (open areas owning ≥ 1 build, ascending),
`knockInstance(section, seconds, center?)` / `isInstanceDown(section)` for Rival Factory sections
(the client topples a section's `Builds` child if it has one, else everything in it except a
`Keep` child and parts marked `KnockdownKeep = true`; rebuilds need Model sections). Sources for
analytics: normal | revenge | barrage | admin | test (others → other); rivals record `rival`.

**Remotes:** `KnockdownTap(areaIndex)` C→S (integer 1..10, typeof-checked, token bucket 6 / 6 per s,
departed-player guard, owner-only by construction). `KnockdownState { areas = { { area, untilTime,
appliedAt, label } }, immuneUntil }` S→C to the owner on every change (validated on the client).

**Admin** (owner R51: the "Attack" tab next to Q2's test-bot commands; handlers
`Server/Admin/Handlers/KnockdownHandlers` via `Seams.knockdown()`, live on this server, never saved):
`KnockdownArea { area, seconds, bot? }` (test knockdown; bypasses switch / shield / immunity),
`KnockdownRebuild { bot? }`, `KnockdownImmunityOff { bot? }` (target Player, or TestBot N with
`bot` 1..8), `KnockdownToggle { on }`, `KnockdownTuning { durationSeconds (0 = normal),
immunitySeconds }`, `KnockdownStats`. `bot` 0 = the calling admin's own plot.

**Analytics** (attack family, recorded for the knocked player): `knock:<1-10>`,
`knockSrc:<normal|revenge|barrage|admin|test|rival|other>`, `knockBlocked:<immune|shielded|not_built|disabled>`,
`knockTap` (amount = taps), `knockSec` (seconds down), `knockEnd:<timer|admin|reset>`. The loop's
Luau time reports to the `Attack` health system.

**Performance:** the server runs one Heartbeat (0.25 s) that returns at once when nothing is down.
The payout tick does one table lookup per player (`Knockdown.activeAreas`). Attribute writes only
happen on change, and the owner gets one small event per change. On the client there is one
RenderStepped, connected only while something is down / tumbling / fading, and one BulkMoveTo per
frame. There is no Instance.new and no per-frame tables. Tier budgets cap it: tumbling pieces 50 /
120 / 220, range 160 / 220 / 300 studs (beyond that the rubble appears at once), and confetti scale
and bonks scale too. With Reduce Motion the area fades to ghostly (0.7) and back, and nothing flies.

**Tests:** `lune run tests/knockdown-logic` checks durations, deadlines, immunity (incl. two areas),
volley spill, tap bounds, resume phase, clock / labels, KeySpec for every knock key, and a
20k-operation fuzz.

## 14. Verification (Q2, 2026-10-30, solo Studio playtest on "Sell Nukes")

Real path, the owner's Studio profile (area 10, Launcher 1): HUD picker → camera flies out to the
Rival Toy Factory island (`docs/verification/attack/rival-1-picker.jpg`) → Enter (the picker's bound
LAUNCH) → server `onLaunch` (rate limit, allowlist, `canLaunch`, 30 s cooldown committed) →
`NukeFlight` `{ toUserId = 0, toPlot = 9 }` → 8.4 s arc into the island
(`rival-2-arc.jpg`) → the island's AA1 turret fired 1 interceptor (missed) → confetti hit + toast
"BOOM! Direct hit on Rival Toy Factory! +$1.09Sx" (`rival-3-confetti-hit.jpg`); 4 launches, 3 hits
counted server-side (`stats.hits` 19 → 22). A client firing `AttackLaunch` directly during the
cooldown, a "revenge" at a rival, a wrong-case id, a 3,000-character id, NaN and a table were all
refused (0 new flights). All four islands built (29-40 models each), turrets up, Grumpy Gus's dome
followed its cycle.

Device matrix (owner R11) found a pre-existing picker layout bug (the corner DEFENSE button
overlapped LAUNCH on phone, tablet and console: `before-fix-rival-matrix-*.jpg`). Fixed: DEFENSE now
leads one centred bottom row that scales to the canvas width; the launcher / Mega Launcher panel
sits above the row (middle right on short phone canvases); the touch thumbstick / jump button are
hidden while the picker owns the camera (restored on close).

## 15. Launch cinematic (owner R54, Q4) — follow the missile with a 3-2-1 + voiceover

Owner: *"when you launch an attack on somebody that you follow the missile as well with like an
animated 3, 2, 1. And a voiceover"*. Presentation only: the server still decides the flight, the
interception and the hit, and nothing about the outcome or its timing depends on the client.

**Timing (server-authoritative).** `AttackConfig.Flight.LeadIn` (t0 = launch + LeadIn) holds the
whole countdown: `#Steps × Beat + NetSlack` = 3 × 1.0 s + 0.4 s (`LaunchCamConfig.Countdown`;
`tests/launch-cam.luau` §1 fails if the lead-in is ever shorter). Every launch kind (normal / revenge
/ barrage / rival / admin test / bots) uses the same lead-in, so all clients and the server agree.
The client draws everything from `Workspace:GetServerTimeNow() − t0`, which is the clock
FlightRenderer moves the nuke with. "3" shows from t0 − 3 s, "2" from t0 − 2 s, "1" from t0 − 1 s and
"LAUNCH!" exactly at t0. A packet that arrives late joins mid-countdown, and a beat that was first
seen more than 0.25 s late plays without its voice line.

**What the attacker sees** (`Client/Attack/LaunchCam`, the director, with one BindToRenderStep at
Camera priority while active):

| Phase (rel = s after t0) | Camera | Overlay / audio |
|--------------------------|--------|-----------------|
| arrival … 0 | Any open window (the picker) closes first, and its onClose gives the player's camera back. A 0.35 s eased cut moves to a shot behind your silo (away from the target, a little to the side, above the mouth), which slowly dollies in | Dark stud letterbox bars slide in, with `TARGET: <name>` in the top bar. A stud badge punches in for each number (scale 2.4 → 1 with overshoot, a ±16° spin, a stud-brick burst in the number's colour: 3 red, 2 orange, 1 yellow). Voice `vo_three` / `vo_two` / `vo_one`, plus a `Tap` haptic per beat |
| 0 … 0.75 | The look locks onto the rising nuke, with a light lift-off shake (0.5 studs, decaying) and an FOV kick (+9°) | A big green "LAUNCH!" stud banner with confetti, `vo_launch`, and a `Hit` rumble |
| 0.75 … approach | The chase: a critically damped spring keeps the camera behind and above the nuke (offset −34 back, +13 up). It looks ahead along the flight (leaning to the horizon) and, from 40 % of the flight on, turns toward the target | — |
| last 1.7 s | The approach: the camera eases off the nuke into a 3/4 outcome shot (ground hit: 92 back / 52 up / 30 side, mid-air POP: 62 / 16 / 22) and zooms in 10°. The nuke races ahead into the target, which gives the slow-mo feel through camera easing only, never time scaling | — |
| outcome … +1.9 s | Holds on the POP or the confetti hit with a slow 5°/s orbit and a small impact bump | "DIRECT HIT!" (yellow, `vo_direct_hit`, rumble) or "INTERCEPTED!" (sky, `vo_intercepted`). If a knockdown lands on that area (a `KnockdownTarget` with `KnockedAt` ≥ hit − 1.5 s and `KnockCenter` ≤ 140 studs from the impact, sampled at +0.3 / 0.7 / 1.2 s), it adds "KNOCKDOWN!" + `vo_knockdown` at ≥ +1.6 s (after "Direct hit!" finishes) and holds 1.6 s longer so the topple shows |
| return | Eases back (0.9 s; 0.35 s on a skip) to the player's own camera. If the character moved, the camera is offset by the same distance. Then Custom, the subject and the FOV are restored | Toasts stay visible the whole time ("BOOM! +$X"); HUD / AttackHud / KnockdownHud fade back |

**Rules.** Only YOUR flights (`fromUserId == LocalPlayer`): other players' launches never move your
camera. Barrage follows the first nuke only, because flights that arrive while a cinematic runs are
ignored. A flight whose outcome is less than 0.6 s away is skipped.

**Voice lines.** The keys are `vo_three`, `vo_two`, `vo_one`, `vo_launch`, `vo_direct_hit`,
`vo_intercepted` and `vo_knockdown` (AudioConfig.Sfx + SoundAssets; the lead uploaded them). They run
about 0.8–1.8 s against 1 s beats, so each line is cut when the next one starts (`Sound.stop`), and a
skip cuts the current one. They are not in the join-time preload set. `Sound.warm` fetches them when
the picker or Defense screen opens, when the profile shows a launcher level or a hit taken (Revenge
is possible), and as a fallback on the first play. A key that is missing from AudioConfig is skipped
silently. Haptics use the existing presets (`Tap`, `Hit`) and respect the Vibration setting.

**Input (owner R11).** The overlay is the modal screen `LaunchCountdown`
(`UI/Screens/LaunchCountdown/{LaunchCountdownScreen, CountdownOverlay}`, `blur = false`). While it is
open:
* Gameplay actions are blocked and a gamepad character pauses ("Menus"). Keyboard movement and jump
  (`Enum.PlayerActions`) are sunk at High priority, so the character stays put.
* Touch controls and proximity prompts are hidden.
* The mouse is free.

The player can skip at any time after a 0.4 s grace (so the LAUNCH! click never skips its own
cinematic):
* tap or click anywhere;
* the stud **SKIP** button (gamepad default selection, so A skips; ≥ 44 pt on touch; device glyph X / B);
* B / X / Backspace (ScreenManager Back);
* Esc (the Roblox menu opening ends it).

Input comes back when the return ease ends: 0.35 s after a skip, 0.9 s after the hold, and at once
with Reduce Motion. It stays held during the ease so no window, and in particular not the picker, can
grab the camera halfway. A watchdog caps the whole cinematic at the hold end + return + 2 s. A respawn, another script taking the camera, or a Scriptable
→ other camera change ends it at once without fighting. `LaunchCam.skip()` is there for teleports and
cutscenes.

**Accessibility / budget.** Reduce Motion (Roblox or `settings.reducedMotion`, read through
`OfferFx.reducedMotion()`) changes the cinematic:
* hard cuts between three static shots: silo → a wide side view of the whole arc (cut at +0.6 s) → the
  impact (cut 1.2 s before the outcome);
* no shake, FOV kick, orbit, punch scale or rotation, burst or confetti;
* an instant return.

FxQuality tier sets the particles (burst / confetti): Low 5 / 10, Mid 10 / 24, High 16 / 40. The
pools are built once (16 bricks + 40 confetti) and there is zero Instance.new per frame. Each
cinematic does three raycasts for shot occlusion: the silo shot at the start, the outcome shot when
the approach begins (the target is streamed in by then: `RequestStreamAroundAsync(impact)` at start),
and ≤ 3 knockdown tag scans.

**Files.**

| File | Job |
|------|-----|
| `src/shared/Config/LaunchCamConfig.luau` | Every number (beats, colours, voice keys, shots, FOV, shake, Reduce Motion cuts, FX tiers, input, knockdown watch, kill switch) |
| `src/shared/Attack/LaunchCamMath.luau` | Pure maths: countdown phase, punch curves, timeline, shots, critically damped spring, `frame()` (the whole camera at one moment), lookAt (built with fromMatrix, so Studio and Lune agree), shake, return blend, skip grace, burst / confetti paths |
| `src/client/Attack/LaunchCam.luau` | Director: play / skip / stats, camera save / restore, input hold, voice + haptics, knockdown detection, occlusion rays, watchdog |
| `src/client/UI/Screens/LaunchCountdown/LaunchCountdownScreen.luau` | Modal screen module (lazy + prebuild, displayOrder 36, own SKIP button) |
| `src/client/UI/Screens/LaunchCountdown/CountdownOverlay.luau` | Letterbox, target line, badge + burst, LAUNCH! + confetti, outcome shout, SKIP; `render(rel, k)` is driven by the director |
| `tests/launch-cam.luau` | ~0.5M checks: lead-in fit, countdown order, punch curves, spring stability, timelines, the full sweep (8 plots × 11 targets × impacts × hit/intercept × Reduce Motion, 30 fps + 120 fps boundary pass), degenerate input, skip lands on the player's camera, overlay paths (`LAUNCH_CAM_REPORT=1` prints the maxima) |

**Hook (Q2's AttackClient).** In `onFlight`, after `FlightRenderer.add`, it calls
`if flight.fromUserId == LOCAL.UserId then LaunchCam.play(flight) end`. LaunchCam rebuilds the arc
with `AttackGeometry.flightOf` from the same indices (`area`, `sx`, `sz` aim-aware, owner R50), so the
camera follows exactly the arc the server built and FlightRenderer draws.

**Analytics + admin.** Every cinematic that plays reports `FunnelStep("open", "Launch", "auto")`,
which counts as `open:Launch` (AnalyticsConfig.ClientFunnel.Screens). The kill switch is the
ReplicatedStorage attribute `SN_LaunchCamOff = true`, which turns the cinematic off live on that
server. Studio only: setting the number attribute `DebugHoldAt` on the `LaunchCountdown` ScreenGui
freezes the overlay at that rel second, for screenshots of exact beats.

## 16. Aiming + knockdown rewards (owner R50, Q2) — the attack side

* **Picker:** one stud marker per BUILT area of the target (`SN_AttackAreas` attribute, set from
  `Knockdown.builtAreas` by DefenseService) or per Rival section, pinned over the area on the picker
  view (projected each frame the camera moves, one RenderStepped connection while open). The aimed
  marker is orange and carries the reticle; a knocked area reads "LAB - DOWN" (grey). Choose with
  tap / click / D-pad + A on a marker, ↑ / ↓ or RT to cycle; "AIM: LAB" under the status line. The
  camera frames the whole plot (PickerFocus z 270, height 560). Default aim = highest built area.
* **Server:** `AttackLaunch(target, kind, area)` — the area must be in `Knockdown.builtAreas(target)`
  (rivals: a section index), else refused "aim". Impact = area centre (slot (0, 0, 35)) + seeded
  scatter (`AttackLogic.scatter`: radius 24/20/16/12/8 studs by launcher level, ×0.5 on rival
  sections), clamped inside the area. AA and shields apply as before. Barrage: the volley picks ONE
  built neighbour (`spillNeighbour`), each nuke spills there with `BarrageSpillChance` 0.3
  (Knockdown allows the same attacker 2 areas per volley).
* **Hit:** `Knockdown.apply(target, area, { durationSeconds = KnockdownConfig.duration(launcher),
  attackerUserId, source = kind (bots: "test"), center = impact })`; Rival sections:
  `Knockdown.knockInstance(Island.Section<i>, 30 s, impact)` (sections = 4 strips of the base:
  TOY SHOP / WORKSHOP / WAREHOUSE / BIG MACHINE; floors, plinth, sign, dressing are Island/Static).
  Reward = `rewardSeconds × clamp(Knockdown.areaIncome(target, area), 0.25×, 2× my income) ×
  factor × Mega` (rivals: their fraction of my income); not knocked (immune / already down / shield
  mid-flight) → × `BlockedFactor` 0.35, still confetti. Toast: "BOOM! You knocked down Ana's LAB!
  +$Y" (coalesced; "x14 hits!").

## 17. Admin test bots (owner R51, Q2) — the "Attack" admin tab

| Command | Args | Does |
|---------|------|------|
| Spawn Test Bot | area 1-10, AA 0-5, shield | `TestBots.spawn`: claims a FREE plot (`PlotService.reserveBotPlot`; a joining player always evicts a bot), builds pads of areas 1..N via `PlotBuilder.restore` (real buildings, so knockdown topples them), turret / dome, sign "TestBot N (BOT)" |
| Bot attacks me | bot, normal / barrage, area (0 = auto) | `AttackService.botLaunch`: same flight / AA / shield / knockdown / Revenge path; the bot pays nothing |
| Bot auto-attack | bot, every (0 = off, min 5 s), kind, area | one 0.5 s TestBots loop |
| Bot shield | bot, on | 1 h dome / off |
| Remove bots | bot (0 = all mine) | frees the plot, `Knockdown.forgetBot` |
| Reset my cooldowns / Give me barrage nukes / Set my launcher + AA | — / count / levels | helpers |

Safety: AdminAuth + audit on every command (catalogue in AdminConfig, handlers
`Server/Admin/Handlers/AttackHandlers`); bots are never persisted and never Players (records in
`Server/Attack/TestBots`, mirror `ReplicatedStorage.AttackBots`); only admins see them in the picker
and the server refuses non-admin launches at them; hitting a bot pays (money path testable) under
cash reason `attack_test` and no attack analytics (admins' economy events are already diverted to
`staff:*`); removed when the admin leaves, after 30 min, at shutdown, or on eviction. Revenge works
against bots (tokens keyed by the bot key). The older AttackAdmin commands (test nuke, cooldown,
shield, levels, barrage, hits, stats, rivals on/off) moved to the same Attack tab.

**Verification (Q4, 2026-10-30, solo Studio playtest; frames in `docs/verification/launch-cam/`, overview
`00-overview.jpg`).** Every run used the real path: the picker → Enter → the server → NukeFlight →
AttackClient → LaunchCam.

* **Test bot** (TestBot 1, area 6, aim ROCKET FACTORY): "3" with its brick burst (01), LAUNCH! +
  confetti over the rising nuke (02), the chase behind the nuke (03), braking above the target with
  the nuke racing in (04), DIRECT HIT! over the confetti cloud + toppling bricks (05), KNOCKDOWN! on
  the scattered area (06), then back on the player's camera with the HUD restored (07).
* **Voice log** (client sampler, rel seconds): three −2.92, two −1.81, one −0.90, launch +0.12,
  direct_hit +6.30, knockdown +7.85, return +9.82. Each line cut the previous one. A screenshot
  capture stalls the client about 0.2 s, which explains the small drift.
* **Rival Toy Factory:** countdown "2" (08), INTERCEPTED! + POP (09), DIRECT HIT! / KNOCKDOWN! on the
  aimed TOY SHOP section (10, 11).
* **Skip:** Backspace at +3.4 s ended it right away (state returning → idle within 0.6 s, camera
  Custom, no modal; 12).
* **Movement freeze:** W held for 1.5 s during the countdown moved the character 0 studs; the same
  tap afterwards moved it 36 studs.
* **Device matrix** (overlay rendered static with badge + shout + SKIP): phone, tablet and console.

Fixes from this QA, all re-tested in Lune:
* The overlay confetti lay on one curve because the old linear hash correlated across salts; it now
  uses `AttackRng.mix`.
* The approach blend let the camera overtake the nuke (run 1). The camera now brakes on the arc
  behind it ("camera time"), and the test checks that the nuke stays in front until the outcome.
* The silo shot is lower (the silo is in frame).
* The outcome shout moved to the lower third, clear of the server toasts. Frames 09–11 (`-prefix`)
  still show the old top position.
* SKIP hides during the return.
* The phone target line overflowed its thin bar (`matrix-phone-before-label-fix.jpg`). It is now sized
  by scale inside the bar. This last fix was checked by tests and type-check, not re-captured: my
  Studio turn had ended.
* Bot targets read "TARGET: TEST BOT".

Found in Q2's picker and reported: `ScreenManager.open("Attack", args)` on an already-open picker
re-ran `takeCamera()`, so its close "restored" the picker's FOV 52 / overhead view. Q2 fixed it
(2026-10-30): `takeCamera` keeps the first save, and `restoreCamera` clears it. Type-check only so
far; it has not been re-run in Studio.

## 18. Defence towers (owner R80, D-defense, 2026-10-31) — buy + upgrade AA towers on your plot

> "there are no buttons to like buy AA towers or anything like that for your island. Or your plot.
> So people can just nuke you. Without having any defense system. And they need to be upgradable."

**Before:** a player became targetable the moment area 7 opened, but the only defence was the Area
7 "AA Tower" Feature pad, 8 pads into the area (6,900 SCALE). Its upgrades were in the Defense window,
which you could only reach through the Attack window or a prompt. There were no buttons on the plot.

### How it plays
* As soon as you can be nuked (since R85: when new-player protection ends), your plot shows **blue defence BUY pads**
  on its flanks: the tycoon BuyPad mesh tinted shield blue, with the tower's name, "Shoots down
  nukes!" and the price above it. You can **walk onto the pad**, press E or X, use the touch Interact button, gamepad
  A, or tap the price. The tower then **builds in with the LEGO fly-in** (translucent → solid).
* Every bought tower has an **UPGRADE billboard**, standing like a sign on the plot side at eye
  level: "SILO TOWER  Lv 2/5" and a cyan stud UPGRADE pill showing the price, with the E / X glyph.
  On top of the tower, it sat inside the top-centre cash HUD whenever the camera was close. It turns grey while you can't afford it and
  green "MAX LEVEL" at level 5. Each upgrade swaps in the next model, AATower1 → AATower5, with the
  fly-in. The HQ tower (the Feature pad's) gets the same billboard. Its old "Upgrade → Defense"
  ProximityPrompt is gone, because it used the same E / X as Interact.
* **Every owned tower fires at every incoming nuke.** That means the HQ tower plus each slot, each
  from its own muzzle with its own level and fire schedule. Barrages can still saturate towers, and
  more towers stop more nukes.
* **HUD route:** the left-stack Attack button now shows as soon as you can be nuked. It gets a "!"
  badge while you have no AA tower, or while an unbought tower slot is affordable. The picker's
  DEFENSE button then becomes a red **DEFEND!**. The Defense window opens with a summary line
  ("You can be nuked and have NO AA tower!" / "3 AA towers defend your plot") and one card per
  tower: HQ + 4 slots (LOCKED until area N / BUILD $X / UPGRADE $X with stats now → next / MAX). The
  launcher, shield, barrage and Mega Launcher cards follow. On a gamepad, the cursor starts on the
  first affordable tower button. The HUD module itself was not touched: `Hud.setButtonVisible` and
  `setButtonBadge` are used from AttackClient.
* On the first reconcile of a session where a player is targetable with zero towers (and not
  shielded), a toast tells them: "Other players can nuke you now! Step on the blue pads on your plot
  to build AA Towers."

### Slots (AttackConfig.Towers; SAVE DATA = the slot index)
| # | id | Name | Plot-local spot | Unlocks | Buy price |
|---|----|------|-----------------|---------|-----------|
| 1 | front | Front Tower | (-95, -0.4, 145), left side near the entrance | area 1 (when protection ends) | 1 × a2_counter (area 2's first pad) |
| 2 | mid | Middle Tower | (95, -0.4, 240), right side, middle | area 3 | 1 × a3_hq_shell |
| 3 | silo | Silo Tower | (-95, -0.4, 335), left side next to Launch Silos | area 5 | 1 × a5_lab_shell |
| 4 | back | Back Tower | (95, -0.4, 445), right side at the back | area 8 | 1 × a8_storefront |

A slot shows (pad or tower) only while the player is **targetable** (owner R85: not brand new)
and their area is at least the slot's unlock area. Level L (2..5) costs buy × `CostMultiplier[L]`
(4 / 40 / 400 / 4000, the HQ ladder). Every price goes through `TycoonConfig.friendlyPrice`.
Because each price is a multiple of a real pad's price, it follows the economy tuner. The HQ tower
sits at plot (-32, 402).

The ladder was re-based with R85. In R80, a player became targetable at area 7 and the first tower
cost 0.5 × a7_silo_pad. Now a player is targetable right after the tutorial plus the grace period,
so the first tower is priced at area 2's first pad.

**Placement decision: a perimeter on the plot's flanks.** The towers stand on the open island
ground just outside the plot's side curbs (plot x = ±95; the plot is x ∈ [-80, 80], and its border
curb at ±81 is a 1.5-stud step).

The first Studio QA pass put them inside area slots, at spots that pass the layout-data surface
check. In practice, the Area 6 spot was under the factory hall's roof and hidden behind its
buildings, and most areas have no free 12 × 12 floor at all. The flanks are always open sky, read
as "my base's AA perimeter", never sit inside a locked area's placeholder, and do not depend on any
area art. Lucky Buttons, vehicles and area builds all live inside the slots, so nothing there can
collide with a tower.

`tests/attack-defense.luau` proves the placement from the shipped `HubLayout` (world space) on all
8 plots:
* walkable island ground under the whole L5 footprint (`FootprintHalf` 6.5);
* no hub collider or model piece (trees, hills, posts, ponds) within 0.5 studs, at any height;
* never on another plot, and clear of the neighbouring plots' towers in the wedge between plots;
* every area of the plot is within L1 range of at least two slot towers.

The slots unlock with the run (areas 1 / 3 / 5 / 8), so defence keeps growing with the plot.
### Persistence + rebirth decision
`profile.attack.towers` is a dense list of stored levels (ProfileLogic template `{}`, reconciled
to whole numbers clamped to `LIMITS.MaxLevel`, at most `LIMITS.MaxTowerSlots` = 16 entries, holes
end the list). The snapshot copies it, so it reaches delta sync with the `attack` field
(`markChanged(player, true, {"attack"})`). Gameplay only ever raises a level.

On **Rebirth** every level is kept, the same as the HQ AA level. While the player's area is below a
slot's unlock area, its pad and tower are hidden. The player can't be nuked then anyway. When the
area reopens, the towers build back in at their saved level with the fly-in, and nothing has to be
re-bought.

### Server (DefenseService)
* Runtime per player adds `slots` (effective levels), `slotFreeAt` (each tower's next fire time),
  `slotShown` (-1 nothing / 0 pad / L tower), `seeded`, `warned` and `towerCount`.
  `reconcileSlots` runs inside `reconcile`, change-only. Reconcile also runs on every `PadBought`, so
  a slot's pad appears the moment an Unlock pad opens its area.
* `DefenseTower(slot, toLevel)` passes the remote's token bucket (`RateLimits.DefenseTower`), then
  `DefenseTowers.validSlot` / `validLevel`, then `tryTower`. `tryTower` checks the kill switch, then
  `DefenseTowers.plan` (slot valid → unlocked at the profile's area → not maxed → `toLevel` ==
  stored + 1 → finite price), then `trySpendCash(player, cost, "defense_tower")` (atomic), then
  `AttackProfile.setTowerLevel`, `markChanged`, a toast, analytics, and reconcile with build-in. A
  repeated or stale intent (double tap, two inputs, lag) is refused as `level` and the profile is
  resynced instead, so the remote is idempotent per target level.
* Walk-on buys use the pad's server `Touched`. Only the plot owner's own character counts
  (`GetPlayerFromCharacter` + plot match), with a per-player `TouchDebounce` of 0.4 s and one
  "Need $X" toast per `NoticeSeconds` (2.5 s).
* `DefenseUpgrade(kind, toLevel?)` also accepts the optional `toLevel`, which the in-world HQ
  billboard sends, with the same stored + 1 rule.
* **Engagement:** `DefenseService.engage` lists the HQ tower and each built slot, each with its own
  muzzle (`AttackGeometry.muzzle(plot, tower)`; slot towers use `Towers.MuzzleHeight` 8, because
  they have no plinth). It then calls `FlightMath.engageMany`, which merges every tower's shots in
  fire-time order on the nuke's seeded rng (ties go to the lower index). The first hit stops all
  towers, each tower keeps `MaxShotsPerNuke`, and only the towers that fired advance their
  schedule. With one tower the result is exactly the old `engage`; the Lune test compares 4,000
  random cases against the original loop. Rival islands and test bots still have one tower each.
* `NukeFlight` adds `volleys = { { t = tower, n = shots, f = firstShot, r = reload, h = hit } }`.
  `shots`, `firstShot` and `reload` stay as the totals. FlightRenderer fires each volley from that
  tower's muzzle and aims that tower's turret: rigs are keyed by plot + tower, and tower models
  carry a `Tower` attribute. AttackClient validates every volley entry.
* The public attribute `SN_AttackTowers` (`Attr.Towers`) holds the active tower count. The picker
  shows "3 AA towers".

### Client
* `Client/Attack/DefenseWorld.luau` (new): the billboards for your own pads and towers (stud size +
  pixel floor `MinPixels` 160 × 96, which keeps taps ≥ 44 pt far away on touch / TV; desktop uses
  0.6 of the floor). Every board sits on its own client-local invisible anchor part: above the pad,
  beside a slot tower, above the HQ tower. Two Studio findings:
  * boards adorned straight to the streamed pad Trigger did not render;
  * `AlwaysOnTop` boards did not render at all in the playtest client, so the boards are
    depth-tested.

  The module sends intents with press feedback and registers an `Interaction` provider.
* `Tycoon/Interaction.addProvider` (new, generic): other systems join E / X / A / touch. Precedence
  is: a tycoon pad, then a defence pad or own tower in reach (pads 9 studs, towers 12), then the
  producer. The hint bar shows "Buy $X" / "Upgrade $X". `PlatformConfig` gets the context `Tower`,
  added to Interact's contexts.
* `AttackClient`: `myState()` gains `towers` / `towerCount` / `targetable` / `area`. New:
  `defenceAlert()`, `buildTower(slot, toLevel)`, and `upgrade(kind, toLevel?)`. The HUD visibility
  and badge rules are as above.

### Analytics (attack family, KeySpec-allowlisted)
`tower:buy:<slot>`, `tower:up:<slot>:<level>`, `tower:src:<walk|remote>`,
`tower:refused:<cash|locked|level|max|rate|off|other>`, `tower:warned`, `tower:admin`,
`interceptBy:<0-9>` (which tower stopped a nuke; 0 = HQ) and `defTowers:<0-9>` (how many towers
defended a player when a real nuke came in; 0 = defenceless). All of these are recorded for the
defending player.

### Admin (Attack tab, AttackAdmin)
* `AttackTower { slot, level 0..5 }` and `AttackTowersAll { level }` grant tower levels for QA. Level
  0 shows the BUY pad again; this is admin-only, and gameplay never lowers a level.
* `AttackTowerShop { on }` is the live kill switch for tower buys and upgrades on one server. Owned
  towers keep defending.
* `AttackStats` shows whether the tower shop is on.

### Files
`Shared/Config/AttackConfig` (Towers, Attr.Towers, Tags.DefensePad, RateLimits.DefenseTower),
`Shared/Attack/DefenseTowers` (new), `Shared/Attack/{FlightMath (engageMany), AttackGeometry
(towerSlotCFrame, towerMount / muzzle per tower, validTower)}`, `Server/Services/{DefenseService,
AttackService}`, `Server/Attack/{AttackWorld (setTower, setDefensePad),
AttackProfile (towers, setTowerLevel), AttackAdmin, AttackAnalytics}`, `Server/Economy/ProfileLogic`,
`Client/Attack/{DefenseWorld (new), AttackClient, FlightRenderer}`, `Client/Tycoon/Interaction`,
`Client/UI/Screens/{Defense/DefenseScreen, AttackTarget/AttackScreen}`, `Shared/Config/{PlatformConfig,
AnalyticsConfig}`, `Shared/Net/Remotes`, `tests/attack-defense.luau` (new),
`tests/{profile-logic, validate}.luau`, `tools/qa/defense_towers{.py, _server.luau, _client.luau}`
(Studio QA).

### Next steps
* A dedicated Blender "defence plinth" mesh with a beacon. Slot towers stand on their own AATowerN
  base today, which already has hazard stripes.
* A tower-shop price review once live analytics `tower:buy` / `defTowers:0` show how quickly
  players defend.

## 19. Attack for everyone + the Golden Revenge Nuke (owner R85, D-defense, 2026-10-31)

> "If you get nuked, add like a 39 like revenge nuke button that like you can pay for with Robux.
> Like nuke somebody back. If they hit you. Also ... I think we should just allow people to be able
> to blow people up. Either way."

### Attack open to everyone
* **Starter launcher:** every player has Launcher **L1** (`AttackConfig.StarterLauncher`) from the
  start, so attacking no longer needs the Area 7 Attack Console.
* **What the Console grants now:** Launcher **L2** at once (`ConsoleLauncher`), plus the L3..L5
  upgrades (`DefenseUpgrade "launcher"`; L2→L3 costs ×40 of the Console price, and so on).
  The effective level comes from `AttackLogic.launcherLevel(stored, hasConsole)`. Players who
  already own the Console are bumped to L2.
* **Barrage needs no Console any more:** its prompt refusal only checks the profile.
* **Launch point:** until a player owns a silo, their nukes rise from the Launch Silos lot (silo 1's
  spot; `AttackLogic.silos` always includes silo 1).
* **New-player protection** (`AttackConfig.NewPlayer`) replaces the area-7 gate. A player becomes
  targetable once the tutorial is finished (`profile.tycoon.tutorialStep >=
  TutorialLogic.DoneStep`) **and** they have `GraceSeconds` (300) of lifetime play
  (`profile.stats.playSeconds`). The server decides this (`DefenseService.isNewbie` → `Actor.newbie`
  → `AttackLogic.isTargetable` "protected"). The admin command `AttackGrace { seconds }` changes it
  live on one server. Shields still protect as before.
* **R80 defence pads** appear the moment a player becomes targetable (`DefenseTowers.areaFor`).
* **HUD:** `Hud.setButtonVisible("Attack", true)` from AttackClient. The HUD itself still hides the
  button in worlds without attack.
* **Unchanged:** reward clamps (`MinRatio` / `MaxRatio` of the attacker's own income), Rival
  Factories (their actor is never `newbie`) and admin test bots. The kid-friendly contract is the
  same: nothing is ever permanently taken.

### Golden Revenge Nuke (developer product "RevengeNuke", id 3725620060)
* **Price:** the product was created at 39 R$, for sale. The store-wide 2026-10-31 product price cut
  later set the config base to 31; the live price is synced by whoever runs the price update.
* **When it is offered:** the HUD shows a gold **GOLDEN REVENGE** chip next to the free REVENGE chip
  while the player who hit you is still in the server, has a plot and has no shield
  (`AttackClient.goldenTarget`). The chip shows only if the product is published and
  `Golden.Enabled` is on, and uses the live price from PriceBook. Controls: keyboard J, gamepad R3,
  or tap. The server refuses the prompt otherwise (`AttackService.refuseGolden`: nobody hittable,
  kill switch off, or `MaxStored` charges already stored).
* **Receipt** (`grantGolden`, idempotent through MonetizationService's per-profile ledger, never
  yields):
  1. `AttackProfile.addGolden` stores the charge first. It is all or nothing: at the storage bound
     the handler returns NotProcessedYet.
  2. Then, deferred, `fireGolden` launches it at the newest attacker who is still hittable, through
     the normal `onLaunch` path with every rule re-checked.
  3. If that attacker left or put a shield up, the charge stays stored and a toast says so.
  A paid purchase is never lost.
* **Picker:** stored charges show as **GOLDEN xN** above "my launcher" (keyboard N, gamepad R3).
  They can be launched at any targetable, unshielded player or Rival Factory. The one who hit you
  can be targeted even while their new-player protection is on: they started it.
* **The golden nuke:** kind "golden", no cooldown, armor = launcher armor + 0.35 (capped at 0.8) vs
  AA, the gold Nuke5 model, the revenge reward factor (`Reward.Factor.golden` = 1) and a 1.8× confetti
  blast. Its hit never grants a counter-Revenge token.
* **Analytics:** `launch:golden`, `golden:<buy|auto|stored>`. The product revenue is recorded by
  MonetizationService.
* **Admin:** `AttackGolden { count }` grants stored charges for QA. `AttackConfig.Golden.Enabled` is
  the kill switch.

### Files (R85)
`Shared/Config/{AttackConfig (NewPlayer, StarterLauncher, ConsoleLauncher, Golden, Keys.HudGolden /
Golden, tower ladder), MonetizationConfig (RevengeNuke), PublishedProductIds, AnalyticsConfig}`,
`Shared/Attack/{AttackLogic (newbie, golden kind, launcherLevel, goldenArmor), DefenseTowers
(areaFor)}`, `Server/Services/{DefenseService, AttackService}`, `Server/Attack/{AttackProfile
(golden), AttackAdmin, AttackAnalytics}`, `Server/Economy/ProfileLogic (attack.golden)`,
`Client/Attack/{AttackClient, FlightRenderer}`, `Client/UI/Screens/{AttackTarget/{AttackHudScreen,
AttackScreen}, Defense/DefenseScreen}`, `tests/{attack-logic, attack-rivals, attack-defense,
profile-logic, validate, pets-policy}.luau`, `tools/qa/defense_towers.py r85`.


## 20. Picker streaming, clear defence billboards, living AA towers (owner R104–R106, A-attack2, 2026-10-31)

### R104 "you cant see peoples bases in the attack menu"
* **Root cause:** `Workspace.StreamingEnabled` with `StreamOutBehavior = Opportunistic` and a
  768-stud `StreamingTargetRadius` around each player's replication focus (their character).
  Another plot's picker focus (900+ studs across the hub) and every Rival island (1080 studs out)
  are outside it, so the client simply had no parts there. The picker's only help was a one-shot
  client `RequestStreamAroundAsync(focus, 8)`, which Roblox documents as temporary and which
  Opportunistic stream-out undoes. The camera flew over empty sky with only the projected aim
  markers, reticle and name plate on screen. `tests/attack-view.luau` §1 proves the geometry.
* **Fix:**
  1. The client sends `AttackPickerFocus(slot)` (C→S; 0 = closed). `Server/Attack/PickerFocus`
     keeps ONE invisible, anchored, non-colliding part per player at `PickerStream.focusPoint(slot)`
     (the camera's look-at point) and registers it with `Player:AddReplicationFocus`. This is an
     extra focus, so the player's own surroundings keep streaming. The whole plot / island is
     inside the radius around that point.
  2. On close, the focus lingers `FocusLinger` (22 s) so the launch cinematic still sees the target,
     then `RemoveReplicationFocus` + Destroy.
  3. Unrefreshed foci expire after `FocusExpire` (the client re-sends every `KeepAlive`). A leaving
     player's focus is dropped. The player's own plot needs no focus.
* **Security:** `PickerStream.readSlot` (number, finite, integer, 0 or a valid target slot), a
  token bucket (`RateLimits.PickerFocus`), `Remotes.onServerEvent`, one part per player, no player
  id on it.
* **Client:** `Client/Attack/PickerView` (called from `AttackScreen.frameCameraOn`) does three things:
  1. Coalesces intents (`SendGap`).
  2. Sends `RequestStreamAroundAsync(focus, 6)` as the first push.
  3. Probes the target container (`Workspace.Plots.Plot<N>` / `Workspace.AttackRivals.<id>`) every
     0.2 s. `PickerStream.step` decides: loaded at `MinParts` with the count stable for
     `StableTicks` polls, at `ProbeMax`, or after `LoadTimeout` 9 s.

  The picker shows a stud **LOADING BASE...** plate with a shimmer bar (one UIGradient tween, static
  under Reduce Motion) while loading. `Camera.Focus` follows the framed target.
* **Camera:** the framing was checked, not changed. Every plot / island footprint fits the 52° picker
  FOV at 16:9, 4:3 and 19.5:9 with the focus at screen centre (test §2).
* **Analytics:** `view:<player|rival>`, `view:refused:<slot|rate>`.

### R105 "the site launch gui is clipping"
* **What clipped:** by the Launch Silos, the Silo Launch producer board overlapped the HQ **AA
  TOWER** upgrade board (above the Area 7 tower at plot-local x -32, z 402) and the **SILO TOWER**
  BUY pad board (slot 3, x -95, z 335). There were two reasons:
  * The old boards were studs + a 96 px floor, so they ballooned up close.
  * Their spots ignored the producer boards.
* **Size:** boards are now a constant pixel size: `Pixels` 150×84 on phone / tablet / console,
  `DesktopPixels` 118×66. They are smaller everywhere and never balloon. The whole board is a tap
  target (≥ 44 px). Culling is shorter: towers 70, pads 120 (was 90 / 170).
* **Spot:** `Client/Attack/DefenseBoardPlacement` (pure, memoised) starts from the old base spot
  and tries Lift / Along / Out moves cheapest first. Keep-outs:
  * every producer board within 150 studs, at the shipped `BillboardSpots` spot with the
    `BillboardPlacement.heightAt` size law;
  * for the HQ board, also every slot's pad AND tower board.

  The check runs from eyes 14 / 36 studs inward and 12 studs outward of the object at three
  offsets along the plot, 8 studs up. A board is a screen-aligned rectangle in tangent space. A
  board beyond its MaxDistance cannot clip.
  * Desktop, tablet and console are clear on every plot × slot × kind × HQ level.
  * A phone at 390 px is never worse than the base spot and loses ≥ 65 % of the overlap.

  The spot is re-solved when the device class or viewport changes.
* **Runtime declutter:** `DefenseWorld`, every 0.25 s, only while boards exist. It projects the own
  boards and the live, visible producer boards (`ProducerBillboards.ownRecords()`: adornee +
  current height) with the real camera, nearest first. A defence board that overlaps a producer
  board or a nearer kept defence board is hidden. The exception is the board of the pad / tower
  the player stands at. Producer boards are never moved.

### R106 "the AA towers should aniamte around"
* `Client/Attack/TowerAnim` owns every AA tower rig: any plot, Rival islands and bots. Maths:
  `Shared/Attack/TowerAnimMath`. Tunables: `AttackConfig.TowerAnim`.
* **Idle:** the turret sweeps / scans (two sines, a per-tower phase), the barrels bob, and the radar
  dish (`TurretDish`, L3–L5) spins.
* **Engaging:** `FlightRenderer` calls `TowerAnim.aim` each frame. The turret slews on fast
  (`AimFollow`), the dish spins faster, then the tower eases back into its scan.
* **Firing:** `TowerAnim.fire` runs at every interceptor launch. The barrels recoil along their axis
  and kick up, and a pooled muzzle flash (neon ball + light; the light is skipped on the Low tier)
  shows at the tip.
* **Pieces:** Turret* yaw, TurretDish yaw + spin, Barrel* pitch + recoil. Joints come from the
  Blender builders' notes (`TowerAnim.Joints`, tested equal to MeshAssets). This also fixes the old
  FlightRenderer aim, which turned only the `Turret` / `Barrel` parts and left TurretTrim /
  BarrelTip / TurretDish behind.
* **Budget:**
  * ONE PreRender connection, alive only while towers exist, and ONE BulkMoveTo per frame.
  * Idle animation runs within `Cull[FxQuality tier]` (Low 0 = off, Mid 200, High 340). Beyond 110
    studs it runs at half rate.
  * Reduce Motion (SellNukes setting or OS) turns off the sweep, dish and recoil, and towers ease
    to rest. Engagement aim stays.
  * A fresh fly-in holds still for `BuildInHold`.
  * No per-frame `Instance.new`.

### R109 "make sure when you launch rockets the rockets actually leave the base and recharge load back"
* `Client/Attack/SiloLaunch` (maths `Shared/Attack/SiloLaunchMath`, tunables
  `AttackConfig.SiloFx`) is driven by the NukeFlight broadcast. That covers every launch kind and
  every client, with no new remote.
* **Which rocket:** the one standing in that flight's silo, `Area07.launchBuilds[silo]` → its
  `A7_SiloNuke_*` model (`Plots.PlotN.Area07.Builds.<build>`).
* **Lift-off:**
  1. **Ignite** (t0 − 1.3 s): flame, smoke and light. The rocket shakes and rises 3 studs.
  2. **Climb** (t0 … t0 + 0.8 s): it climbs fast and blends onto the flight's own arc (smoothstep),
     shrinking to the flight nuke's length.
  3. **Hand-off:** `FlightRenderer` draws the flight nuke only from t0 + `HandOff` (the value
     `SiloLaunch.launch` returns). Both pivots are the tail, so the swap lands on the same pose,
     and a puff covers it.
  4. The rocket's nose is the launch point, as tested.
* **Reload:** from t0 + HandOff the gantry stands empty. A fresh rocket rises 10 studs back in,
  translucent to solid, under a pulsing amber Highlight and a stud **RELOADING 12s** board with a
  progress bar.
  * Reload time is the launcher cooldown for a normal launch and 8 s (`QuickReload`) for
    revenge / golden / barrage.
  * Barrages cycle the silos (server round-robin). A silo firing again mid-lift-off just extends
    its reload.
* **Rules:**
  * The server rocket is never moved. It is hidden with LocalTransparencyModifier, re-asserted
    while empty. Pooled client clones fly and reload in its place (6 per art key, 6 glows,
    6 boards).
  * One PreRender loop, alive only while silos are busy, and one BulkMoveTo per frame.
  * Culling: lift-offs within 700 studs (own launches always); reload visuals within 350.
  * FxQuality sets the smoke rate; Low tier has no light.
  * Reduce Motion: the rocket fades out at t0 and back in when reloaded, and the board still counts
    down.
  * A knocked-down Area 7 is left to KnockdownFx.

### R118 "all of these clip" (picker over Mega Meltdown Mart)
* **Root cause (aim chips):** on phones (canvas ≈ 1361 × 629 design px) the top block (244 px) and
  the bottom row (190 + 60 px) left NO band between them. Every projected marker was clamped onto
  the same line, so the chips covered each other ("AREHOUSE", "ORKSHOP"). Rival sections also
  project closer together (26 studs) than a chip is wide.
* **Fix:** `Screens/AttackTarget/PickerLayout` (pure) does the layout.
  * `blocks` scales the top block and the bottom row to `TopShare` / `BottomShare` (0.26) of the
    canvas height, never below the 44 pt tap size. Chips are ≥ 44 pt. A band for at least one
    chip row always remains on phone, small phone, tablet, console and desktop.
  * `markers` pins each chip near its area: plot chips go on the side away from the road. Chips
    are de-collided cheapest first: whole chip rows up / down (≤ 2), then sideways (≤ 0.6 × width).
    A moved chip gets a leader line to a dot on its area.
  * If any chip has no free spot, ALL chips become one tidy row just above the action buttons,
    ordered left to right like their areas, with leader lines. If the row is wider than the
    canvas it becomes a sideways-scrolling strip with dots only and explicit
    `NextSelectionLeft/Right`.
  * `chipFor` makes chips as wide as the longest label. The launcher panel is kept clear. The
    reticle sits on the aimed area's dot. LB / RB, ↑ / ↓ / RT and the D-pad still work.
* **Status lines:** the info, status and aim lines now stack in one UIListLayout on a stud backing
  plate (AutomaticSize; an empty line hides). They can never overlap each other, and nothing behind
  shows through. Before, there were three fixed-y labels with a 2 px overlap and no backing. The
  R104 loading plate moved under the top block, so it cannot cover these lines on short canvases.
* **Tests:** `tests/attack-view.luau` §8 checks:
  * bands and tap sizes per device;
  * the exact R118 single-row case;
  * 720 randomised layouts (1–12 chips, clusters, junk anchors);
  * every plot and Rival island projected through the real picker camera on every device.

  Requirements: no overlaps, everything in the band / canvas, labels fit, strip order left to right.
* **Studio:** `tools/qa/attack_view.py r118` walks every target with the real Right-arrow binding.
  It runs a live audit per target (chip overlaps, label `TextFits`, chip px, info-line overlaps)
  and captures device matrices of Mega Meltdown Mart and the bot plot.

### Files (R104–R106, R109, R118)
`Shared/Attack/{PickerStream, TowerAnimMath, SiloLaunchMath}` (new), `Client/Attack/SiloLaunch` (new),
`Client/UI/Screens/AttackTarget/PickerLayout` (new, R118), `Shared/Config/{AttackConfig (Client.PickerStream,
RateLimits.PickerFocus, Towers.Billboard, TowerAnim, SiloFx), AnalyticsConfig (view keys)}`,
`Shared/Net/Remotes (AttackPickerFocus)`, `Server/Attack/PickerFocus` (new),
`Server/Services/AttackService (starts it)`, `Client/Attack/{PickerView, DefenseBoardPlacement,
TowerAnim}` (new), `Client/Attack/{DefenseWorld, FlightRenderer}`,
`Client/UI/Screens/AttackTarget/AttackScreen`, `tests/attack-view.luau`,
`tools/qa/attack_view{.py, _client.luau, _server.luau}`.

### Verification
* **Lune:** `lune run tests/attack-view` (39k checks). The audits run against the shipped Area 7
  art layout (AttackGeometry pinned to `AreaLayouts/Area07`).
* **Studio (lead runs it; one solo playtest):**
  `STUDIO_LOCK_OWNER=<owner> python3 tools/qa/attack_view.py [picker|boards|anim|silo|r109|r118]` writes
  captures to `docs/verification/r104-attack-view/`.

## 21. The picker shows the target's base (owner R133, lead, 2026-11-01)

> "when attacking people all I see is this, not their base still" (live client, 0.8.0: a big grey
> stud panel over the middle of the picker, empty blue sky behind it).

### Root causes (two, both shipped in 0.8.0 without a Studio pass)
* **The grey wall = the R118 info plate.** Its `UIListLayout` was a direct child of the studded
  plate, so the list also stacked the plate's own decorations (`TopHighlight`, `PanelBackdrop`,
  added by `StudWindow.surface`) as items above the three text lines, and `AutomaticSize.Y` grew the
  plate around those scale-sized children. Result: a ~550 px grey stud panel (940 px wide, same
  1.2 width ratio to the 780 px name plate as in the screenshot) with the lines at its bottom,
  covering exactly where the base is. This breaks the `Widgets/PanelBackdrop` "Layout rule".
* **The empty sky = camera distance.** The R50 whole-plot view looked from ~890 studs (height 880,
  back 110). Studio at high graphics draws that, but a live client did not. Two different streaming
  fixes (the original one-shot `RequestStreamAroundAsync`, then R104's server replication focus)
  left the symptom unchanged, so the distance itself is the problem, not streaming. Even when drawn,
  a new player's only building (area 1, by the hub) was a speck at the bottom of that view, ~200
  studs from the R104 stream focus point in the middle of the empty plot.

### Fix
* **Info plate:** the layout, padding and lines live in a transparent inner `Content` frame; the
  plate's height is set explicitly from the visible lines (`fitInfo`, three lines = 130 px, ends at
  `TOP_HEIGHT`). No `AutomaticSize` anywhere in the picker.
* **Camera (`Shared/Attack/PickerFrame`, pure):** frames the target's BUILT areas (union of slot
  footprints + `Pad`) as close as they fit inside the band between the name plate and the button
  row (`FitX` / `FitTop` / `FitBottom` of the half-FOV), looking away from the hub at `Pitch` 66°,
  between `MinDistance` 110 and `MaxDistance` 320. A base too big for 320 studs keeps the AIMED
  area fully in view, slid as far toward the footprint's middle as that allows (cycling the aim
  pans the camera). `PickerFov` 52 → 66. Rival islands keep their ~214-stud island view.
  Distances: new garage 156 studs, 3–4 areas 299, 5+ areas 320 (was 886 for every plot).
  `AttackScreen.frameCameraOn(plot, areas, aim, instant)` re-frames only when the key
  `slot|areas|aim|aspect` changes, and skips the tween when the goal is unchanged.
* **Stream focus:** `PickerStream.focusPoint(slot, areas)` = `PickerFrame.streamPoint`, the middle
  of the built footprint. The server (`PickerFocus.builtAreasOf`) reads the target's built areas
  from the server-set `SN_AttackAreas` attribute (never client data) and moves the focus on every
  keep-alive as the base grows. The client's first `RequestStreamAroundAsync` uses the same point.
  A new garage now sits inside `StreamingMinRadius` (192); the whole plot stays inside
  `StreamingTargetRadius` from any built-set focus.

### Tests (`tests/attack-view.luau`, 102k checks)
* §2: every plot × 16 area sets (all prefixes + sparse) × every aim × 5 aspects. Checked: distance
  within [Min, Max]; the aimed area is fully in the fit window and within 1.5 × Max of the eye; a
  base that fits is whole in view at the smallest fitting distance; new garage ≤ 260 studs; stream
  point coverage (min / target radius); Rival island views unchanged and inside the FOV.
* §8: chip layout through the real `PickerFrame` camera on every device. Source rules: no
  `UIListLayout` / `AutomaticSize` on the studded plate, no `AutomaticSize` property in the picker,
  and three lines fit `TOP_HEIGHT`.

### Owner eyeball (R132: no agent playtests)
Open Attack on (1) a brand-new player, (2) a mid-game player, (3) a full base, then press ↑ / ↓
to cycle the aim on the full base. Check: no grey panel, the base fills the middle, the camera pans
with the aim, the area chips sit on their buildings.
