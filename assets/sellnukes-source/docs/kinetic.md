# Mega Lever + Tip Jar — hands-on plot props (owner R90 / R93, builder K-kinetic, 2026-10-31)

Spec: `docs/superpowers/specs/2026-10-31-r90-hands-on-design.md` §2 (Mega Lever) and §3 (Tip Jar).
Owner asks: R90 ("3d interaction elements instead of just strictly clicking"), R93 (start building
them). The sibling Order Window (whose big tips dropped coins into the jar through `TipJar.addCoins`)
was removed by owner R128 (`docs/orders.md`): the jar keeps working, `addCoins` simply has no caller.

## What the player sees

* When a world's plot reaches **Area 2** (`KineticConfig.UnlockArea`; Nuke Town = the Nuke Stand,
  ~8 min into a first run), two toy props **build in with the LEGO fly-in** inside the plot, in
  Area 1's front yard beside the road (where Area 1's pads stood — all bought by then), across the
  road from the Nuke Stand in Nuke Town and beside Area 2 in Dino Valley / Moon Base:
  * **Mega Lever** — a red studded machine with a candy-striped arm, a hopper holding a toy nuke and a
    yellow chute. A stud-panel board over it reads `MEGA LEVER` + `READY! HOLD TO PULL` (owner) /
    `READY!` (visitors) / the `m:ss` cooldown / `RESTING` (switched off).
  * **Tip Jar** — a glass jar of gold coins on a little crate. The coin pile rises as it fills; the
    owner's board shows `TIP JAR` + `45%` / `FULL! WALK IN`.
* **Pulling** (owner only): hold the prompt (keyboard **E**, gamepad **X**, tap-and-hold on touch —
  the engine draws the device glyph and a ≥ 44 pt tap target). The arm yanks forward and springs back
  (everyone in the world sees it), toy nukes slide down the chute one after another tinted by their
  flavour, confetti pops at the tray, the **`MEGA PULL!`** banner rises with the subline
  `Every machine made bonus nukes: +$1.2M`, coins fly into the HUD counter and the gamepad / phone
  rumbles. Then the 10-minute countdown starts. (Owner R112: the player-facing word is never
  "batch" — players found it confusing; code-internal names like `leverPlan` stay.)
* **The jar** fills while the owner is online, in that world and near the plot. **Walking into it**
  pays it out (coins hop out, sparkles, `+$X TIPS!`, coins fly to the HUD); the owner's
  `Collect tips` prompt does the same for accessibility. A bonus tip (`TipJar.addCoins`; the Order
  Window's until owner R128 removed it) makes coins rain into the jar (everyone nearby sees it).
* Nothing is ever required or taken away: both props are pure bonuses on top of passive income.

## Files

| File | Role |
|------|------|
| `src/shared/Config/KineticConfig.luau` | every tunable: unlock area, placement, lever / jar numbers, prompts, boards, FX, copy, pacing |
| `src/shared/Tycoon/KineticLogic.luau` | pure maths + save state: cooldown, `leverPlan`, jar fill / tips / collect, fill steps, flavour inference, pacing lift, mounts, reach, wire validation |
| `src/server/Kinetic/KineticService.luau` | boot service: 1 Hz reconcile (place / remove props per world), KineticAction intents, rebirth hooks, switches, admin install |
| `src/server/Kinetic/KineticWorld.luau` | the server instances (models, colliders, jar trigger, tags, attributes, fly-in stamp), async-safe |
| `src/server/Kinetic/MegaLever.luau` | pull rules + Mega Pull payout (FlavorService.batch per bonus cycle) |
| `src/server/Kinetic/TipJar.luau` | fill, collect (touch / prompt), `addCoins` (bonus tips; no caller since R128), rebirth clear, admin fill |
| `src/server/Kinetic/KineticAdmin.luau` | admin commands |
| `src/server/Kinetic/KineticAnalytics.luau` | the `kinetic` analytics family door (lazy AnalyticsService.record) |
| `src/client/Kinetic/KineticClient.luau` | boot controller: tag tracking, boards, owner prompts, wire → FX / CurrencyFly / Haptics |
| `src/client/Kinetic/KineticVisuals.luau` | arm swing + coin pile (rest poses from MeshAssets, build-in safe) |
| `src/client/Kinetic/KineticFx.luau` | pooled FX + the shared transient driver (chute ride, coin burst / shower, pops) |
| `tools/blender/models/kinetic.py` | `Kinetic_Lever` (11 pieces, 1,640 tris) + `Kinetic_TipJar` (6 pieces, 976 tris) |
| `tests/kinetic-logic.luau` | regressions (config, state, cooldown, payout math, jar, pacing, placement in every world, validation, wiring) |
| `tools/qa/kinetic.py` (+ `kinetic_server.luau`, `kinetic_client.luau`) | the re-runnable Studio QA + captures (lead runs it) |

Shared files touched additively: `Shared/Net/Remotes` (2 remotes), `Server/Economy/ProfileLogic`
(`kinetic` field), `Server/Progression/ProgressEvents` + `Shared/Config/QuestConfig` (stats `lever`,
`tipjar` + 2 daily missions), `Shared/Config/AnalyticsConfig` (`kinetic` family + quest stat lists),
`Server/Analytics/ReportSections` (kinetic table), `Shared/Config/MeshAssets` (generated), boot lists,
`tests/{validate, quest-logic, profile-logic, analytics-recorders, analytics-report, economy-sim}`.

## How it connects

```
TycoonService (isReady / isWorldBuilt / incomePerSecond / getModifiers)
        │                       ProfileLogic: profile.kinetic.worlds[w] = { readyAt, jar, tips }
        ▼                                         ▲
KineticService ── 1 Hz ──► reconcile(player) ── KineticWorld.place/remove ──► plot.Kinetic.{MegaLever, TipJar}
        │                 └► TipJar.tick (fill, Fill/Full attrs)                 │ attributes + tags
        │ KineticAction("pull"|"collect")                                        ▼
        ├──► MegaLever.pull ──► FlavorService.batch (per bonus cycle) ──► grantCurrency ──► "Kinetic" wire
        └──► TipJar.collect ◄── jar trigger Touched (owner's character only)      │
                    ▲                                                            ▼
(a bonus source) ─ TipJar.addCoins ──► tips bucket ──► TippedAt   KineticClient → KineticFx /
                                                                          KineticVisuals / CurrencyFly
```

## Rules (server-authoritative)

**Unlock / placement** — every second, for each world in `WorldsConfig.Order`, the props stand when
that world's plot is built (`TycoonService.isReady` for Nuke Town, `isWorldBuilt` elsewhere) and its
tycoon owns `UnlockArea`. A world seen built-but-locked earlier in the session → the props build in
(reveal, analytics `reveal:<world>`); a join / first travel restore just appears. Rebirth → area 1 →
removed; Area 2 again → built in again. Failed mesh spawns retry after 15 s (no warn spam).

**Mega Lever pull** (`MegaLever.pull`): switch on → the lever of the player's current world is placed
→ character within `Lever.Reach` (18) horizontal / 20 vertical of the lever → run ready → cooldown
passed (`readyAt <= os.time()`) → `leverPlan` over every BUILT producer (Nuke Town skips areas knocked
down by an attack) pays > 0. Then `readyAt = ceil(now + 600)` is committed **first** (a repeated
intent fails the ready check — idempotent), each bonus cycle calls
`FlavorService.batch(player, world, producerId, 1, bonus, true)` (the R89 public API; the returned
flavour bonus is added and the flavour is inferred for the FX), one `grantCurrency(world currency,
"megaLever")`, save soon, `PulledAt` / `ReadyAt` attributes, the owner's `pull` wire, Quests `lever`,
analytics. A grant that pays nothing refunds the cooldown.

**Mega Pull maths** (`KineticLogic.leverPlan`): producer i pays `perCycle_i × CycleMultiplier (10)`
(automated: `output`; still manual: `clickPayout`); the whole pull payout is clamped to
`[MinIncomeSeconds 12, MaxIncomeSeconds 24] × rate`, `rate = Σ perCycle_i / cycle_i`, by one common
scale (shares preserved). Typical pull: 12–24 s of the plot's production.

**Tip Jar** (`TipJar`): each tick, for the world the player stands in, while the root is within
`NearMargin` (40) of the plot footprint: `jar += FillFraction (2 %) × incomePerSecond × dt`, capped at
`jarCap = FillFraction × 60 × CapMinutes (20) × income` (= 24 s of income; full after 20 minutes),
never shrinking. A payout needs `jar >= 5 %` of the cap or any tips, and is clamped to
`HardCapIncomeSeconds (180) × income`. The jar is emptied **before** the grant (idempotent; a grant
that pays nothing restores it). Touch payouts are debounced 1 s per player and only count the owner's
own character (`Players:GetPlayerFromCharacter`); reach is checked server-side. Rebirth of a world
empties that world's jar (its coins were the old run's currency).

**`TipJar.addCoins(player, amount, worldId?) -> number`** (bonus tips; the Order Window's until owner
R128 removed it — no caller today): server-only; validates
`amount` (finite > 0), the world (nil = the player's current one), that the jar is placed and switched
on and the world has income; adds to the `tips` bucket capped at `BonusCapIncomeSeconds (120) ×
income`; returns the ACCEPTED amount (0 = refused → the caller pays those coins itself). Stamps
`TippedAt` (coin shower for everyone) and sends the owner a `tip` wire.

## Contract

**Save** — `profile.kinetic = { worlds = { [worldId] = { readyAt, jar, tips } } }` (KineticLogic owns
`newState` / `reconcileState`; ≤ 8 world keys, finite clamped numbers). Server-only: NOT a snapshot
field. Top-level, so a rebirth keeps the lever cooldown.

**Remotes** — `KineticAction` C→S `(action: "pull" | "collect")` (RateLimiter 4 burst / 1 per s,
`Validate.oneOf`); `Kinetic` S→C owner only, `KineticLogic.Wire`:
`{ kind = "pull", world, total, currency, readyAt, cycles = { { id, amount, flavor } ≤ 12 } }`,
`{ kind = "collect", world, amount, currency }`, `{ kind = "tip", world, amount, currency }`.

**Instances + attributes** (server-set; clients read): `<plot>.Kinetic.MegaLever` (tag
`SNKineticLever`; `OwnerUserId`, `WorldId`, `Plot`, `ReadyAt` unix s, `PulledAt` server time) and
`<plot>.Kinetic.TipJar` (tag `SNKineticJar`; `OwnerUserId`, `WorldId`, `Plot`, `Fill` 0..1 in 1/20
steps, `Full`, `CollectedAt`, `TippedAt`), each with an invisible `Collider`; the jar also has the
`JarTrigger` (CanTouch only). Switches: `ReplicatedStorage.KineticLeverOn` / `KineticJarOn`.

## Placement decision

Owner R116 ("these things are out of the plot"): both props stand INSIDE the plot. Slot-local in
the **Area 1** slot (`KineticConfig.Placement`, the same in every world, lot height 0.5, front −Z
facing the road): **Lever (-18, 0.5, 12)** (plot-local (-22, 0.5, 34)) left of Area 1's entry path,
**Jar (15, 0.5, 9.5)** (plot-local (-19.5, 0.5, 67)) right of it. Published slot-local keep-outs:
lever x −29..−13, z 7.5..16.5; jar x 11.5..18.5, z 6..13.

Why Area 1's front yard: the props appear at Area 2, and Area 1's chain is linear (its Unlock pad is
its last pad), so every Area 1 pad is bought and gone whenever the props exist — they never block a
pad the player still needs (Area 2's front yard would sit right in front of the pads that just
appeared). It is the road-side front yard directly across from the Nuke Stand in Nuke Town and
beside Area 2 in Dino Valley / Moon Base.

`tests/kinetic-logic` proves on every world's shipped layout data (Area 1 layout incl. every build,
billboard spots, the plot frame's colliders; Dino's single-mesh D1_Jungle via its builder's clump
positions, pinned by its triangle count): the whole footprints inside the slot / fence lines, the
plot footprint on all 8 plots (`WorldLayout.plotAt`) and the keep-outs, on walkable ground, clear of
solids (1 stud), the producer + billboards (2), the teleport spawn (4), the road, the entrance arch +
plot sign, each other, D-defense's tower slots (the R116 Order Window keep-outs went with the
order system, owner R128) — and never where a Lucky Button / Happy Hour pickup can spawn (every
footprint point lies inside LuckyButtonLogic's pad / road-edge keep-out).

## Economy (pacing)

`docs/economy.md` "Mega Lever + Tip Jar". The simulator multiplies income by
`1 + KineticLogic.pacingLift(flavour lift)` from Area 2 on: conservatively a pull every cooldown at
the 24 s ceiling (flavoured) + the jar always filling = **+6.3 %** (cap `Pacing.MaxLift` 6.5 %).
Nuke Town run 1: 7:29 → 7:03, worst area Nuke Stand −15 % (tolerance ±20 %); Dino / Moon 2:21 → 2:13.

## Analytics (family `kinetic`)

`reveal:<world>`, `pull:<world>`, `pullPaid:<world>` (amount), `pullCycles:<world>`,
`pullFlavor:<flavorId>`, `pullRefused:<cooldown|reach|locked|off|noProducers|notReady|rate>`,
`jar:<world>`, `jarTouch:<world>`, `jarPaid:<world>`, `jarFull:<world>`,
`jarRefused:<empty|reach|locked|off|noIncome|rate>` (prompt refusals only), `tip:<world>`,
`tipPaid:<world>`, `tipRefused:<bad|locked|full|noIncome>`, `admin:<switch|lever|fill|status>`.
Report table "Mega Lever + Tip Jar". Grants also show in the economy family as reasons `megaLever` /
`tipJar`. Quests stats `lever` / `tipjar` (daily missions "Pull the Mega Lever", "Empty your Tip Jar").

## Admin

`KineticSwitch` (Server; lever / jar kill switches — nothing removed), `KineticLeverReset` (Players;
the lever of the world they stand in is ready), `KineticJarFill` (Players; jar to its cap),
`KineticStatus` (Server; props placed / loading, pulls, payouts, tips, paid since boot).

## Security + performance

Intents only; ownership (the props are looked up from the player's own registry), unlock, reach,
cooldown, amounts, flavours are server-side; every handler goes through `Remotes.onServerEvent` (drops
packets from players who left) + RateLimiter + allowlist; payouts are idempotent. One server Heartbeat
(1 Hz) for everyone; attributes only on change; client: event-driven + one 1 Hz accumulator that only
exists while a prop is streamed in + one transient FX driver; FX pools (nukes clone the already-loaded
HopperNuke mesh), FxQuality tiers and Reduce Motion respected; boards cull at MaxDistance.

## Models

`Kinetic_Lever` model 118989760237288 and `Kinetic_TipJar` model 111831430695695 (uploaded through
`tools/blender/upload_meshes.py`, MeshIds synced into `MeshAssets.luau`; no primitive fallback needed).

## QA

`STUDIO_LOCK_OWNER=<holder> python3 tools/qa/kinetic.py` (one solo playtest; captures in
`docs/verification/r90-kinetic/`): live reveal, the lever board + prompt on desktop / phone / tablet /
console, a REAL hold-prompt pull (mid / after shots), a refused second pull, jar fill + matrix, the
real walk-in payout, a bonus-tip shower collected through the prompt (needs an `addCoins` caller
since R128 — the Order Window that fed it was removed), log scan, reset.

## Next steps

* Run `tools/qa/kinetic.py` in the lead's Studio pass and look at the captures (board size on phone,
  chute ride readability, coin pile through the glass).
* If analytics show most pulls landing on the 12 s floor, consider a slightly higher multiplier
  (re-run the simulator; the lift is computed from the ceiling, so it stays put).
