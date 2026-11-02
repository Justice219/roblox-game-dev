# Surprise Batches, Flavour Book + Big Pop (owner R89, F-flavors)

Spec: `docs/superpowers/specs/2026-10-31-r89-competitive-wave-design.md` §1. Owner request R89
("make our game super unique and competitive" after studying other sell games). The genre's core loop is
"click → sell → upgrade"; SellNukes' twist is **luck inside every batch**: each finished batch rolls a
flavour on the server, rare flavours pay big, glow for everyone, get a short reveal and a server-wide
Big Pop, and every flavour in every world is a collectible in the Flavour Book.

## Player-facing words (owner R112)

Owner: "so what is the point of a batch?? it's real confusing". Players never read "batch": a
flavoured batch is a **Lucky Nuke**. Every string lives in `FlavorConfig.Text` and its helpers
(`revealLines`, `popWord`, `bigPopLine`, `multText`), so every presenter says the same thing:

| Where | Text |
|-------|------|
| Reveal (Galaxy+) | "LUCKY NUKES!" / "Your Pocket Nuke Workbench made GALAXY nukes" / "Sold for x20: +$31.8M" (the payout always shows) |
| Shout fallback | "GALAXY!" / "SOLD FOR x20!" |
| Income pop | "GALAXY x20" (+ "  +2" when several fold in) |
| Big Pop (banner + chat) | "Alex got GALAXY nukes! (1 in 2,500)" · "Sam hatched a MYTHIC Nova Fox!" · "Kim did a REBIRTH #3!" |
| Flavour Book | subtitle "Rare nukes your machines can make. Find each one for gems!"; tiles "SELLS x3" / "1 in 100" |
| Toasts | "New Lucky Nuke: GALAXY in Nuke Town! Claim 60 Gems in Pets → FLAVOURS." |
| Daily mission | "Make a Lucky Nuke" / "Make %d Lucky Nukes" |
| Feed pills (R120, Q-queue's bottom-left feed) | "GALAXY nukes x20 +$31.8M" · merged "GALAXY x3" (`Text.FeedPill` / `FeedPillMerged` / `FeedAmount`) |
| One-time tip card | "Lucky Nukes! Sometimes your machines make rare flavoured nukes that sell for more. Collect them all in Pets → FLAVOURS for gems!" + OK |

The reveal / shout / Big Pop banner + chat presenters (UI/Screens/FlavorReveal, Fx/BigPopBanner,
FlavorController) now sit in Q-queue's PopupQueue feed (R108 / R111); Q wires these helpers there.

**Tip card** (`UI/Screens/FlavorTip` + `Client/Tycoon/FlavorTip`): the first Lucky Nuke a player ever
gets (FlavorPops.show → FlavorTip.maybeShow) opens it once when calm (no tutorial step, window,
cinematic or reveal; otherwise retried on the next Lucky Nuke). OK (≥ 44 pt, default gamepad
selection), X and B close it; closing sends `FlavorTipSeen` (C→S, no data, rate-limited) and the
server saves `profile.flavors.tip = true` (analytics `flavorTip`), so it never shows again.

## Flavours

| Rank | Flavour | Odds per batch | Payout | Book reward (per world) | Look |
|------|---------|----------------|--------|-------------------------|------|
| 0 | Plain | the rest | x1 | — | normal green "+$X" pop |
| 1 | Sprinkle | 1 in 20 | x1.5 | 5 gems | pink-tinted pop, "SPRINKLE! x1.5", sparkle |
| 2 | Glitter | 1 in 100 | x3 | 10 gems | gold pop + word + sparkle |
| 3 | Rainbow | 1 in 500 | x5 | 25 gems | + rainbow glow on the producer (everyone in the world sees it) |
| 4 | Galaxy | 1 in 2,500 | x20 | 60 gems | + the owner's ≤ 3 s reveal + a Big Pop |
| 5 | Mystery Pop | 1 in 25,000 | x100 | 150 gems | + reveal + Big Pop |

Odds are per batch; luck (Happy Hours' Sprinkle Surge × admin odds) multiplies every special chance
(special share capped at 90 %). Average income lift +6.46 % (luck 1) / +7.1 % (pacing luck 1.1) — the
economy simulator includes it; tuning history in `docs/economy.md` "Surprise Batches". All numbers live in
`src/shared/Config/FlavorConfig.luau`.

## Files

| File | Role |
|------|------|
| `src/shared/Config/FlavorConfig.luau` | flavours (id, rank, odds, mult, gems, colours, glow / reveal flags), luck caps, PacingLuck, roll bounds, flush / push periods, quest credit, Big Pop throttles, client FX numbers, replicated attribute names |
| `src/shared/Tycoon/FlavorLogic.luau` | pure maths: chances(luck), rollOne, rollInto (aggregate, bounded), binomial, bonusCycles, expectedMultiplier, oneIn / formatOdds, eventLuck (HappyHourLogic), Book state (newState / reconcileState / toWire / addFound / claim / claimable), quest credit bucket |
| `src/server/Tycoon/FlavorService.luau` | server: the pay-path hook `batch()`, the flush (pops / glows / reveals / discoveries / quest credit / analytics), luck refresh + attributes, FlavorClaim, hatch + rebirth Big Pop triggers, admin seams |
| `src/server/Tycoon/BigPop.luau` | server-wide broadcast queue: per-player cooldown, one entry per player, global gap, coalescing ("+N more") |
| `src/server/Tycoon/FlavorAdmin.luau` | admin commands (FlavorSettings, FlavorGrant, FlavorBookReset) |
| `src/client/Tycoon/FlavorController.luau` | client: validates FlavorPop / FlavorGlow / FlavorHighlight / BigPop, reveal gate + queue, chat lines, fireworks; `preview` / `stats` probes |
| `src/client/Tycoon/Fx/FlavorPops.luau` | pooled flavour words + sparkle bursts; tints the income pops (IncomePops.tint) |
| `src/client/Tycoon/Fx/FlavorGlow.luau` | pooled Rainbow+ producer glows (PointLight ≤ 0.6 / range 10 + sparkles), JuiceLoop-driven |
| `src/client/Tycoon/Fx/BigPopBanner.luau` | the Big Pop banner (non-modal, under the Top HUD zone) |
| `src/client/UI/Screens/FlavorReveal/init.luau` | the Galaxy+ reveal (letterbox, odds count-up, confetti, SKIP) |
| `src/client/UI/Screens/FlavorBook/init.luau` | the Flavour Book modal (ResponsiveModal "grid" / "wide") |
| `src/client/UI/Screens/FlavorBook/EntryButton.luau` | the FLAVOURS button (Pets window) + "!" badge |
| `tests/flavor-logic.luau` | Lune: config, chances, lift bound, distribution (1M single + aggregate), bounded work, Book state, quest credit, ProfileLogic |
| `tests/big-pop.luau` | Lune: Big Pop queue — first pop, global gap, per-player cooldown, replace-better, coalescing / `more`, junk sanitising, kill switch |
| `tools/qa/flavors.py` (+ `_client.luau`, `_server.luau`) | re-runnable Studio capture runner |

Additive hooks in shared files: `TycoonService` (require + one line in each pay path), `ProfileLogic`
(`flavors` field: default / reconcile / snapshot), `Remotes` (5 remotes), `AnalyticsConfig` (tycoon keys,
quest stat choice lists, FlavorBook screen + "pets" source), `ProgressEvents` + `QuestConfig` (stat
`flavor` + one daily mission), `IncomePops` (`tint` API), `PetsScreen` (FLAVOURS button), `PetController`
(HUD Pets badge counts ready rewards). Boot lists (lead): `Tycoon/FlavorService`, `Tycoon/FlavorController`.

## Server flow

```
TycoonService.tickRuntime (every 0.2 s, per player per world)
  automated: amount = cycles × output     + FlavorService.batch(player, world, producer, cycles, output, present)
  clicked:   amount = paid   × clickPayout + FlavorService.batch(player, world, producer, paid, clickPayout, present)
      └─ rollInto(scratch, rng, n, liveChances)   -- per-player AttackRng stream (server secret ⊕ UserId)
         forced admin flavour (QA) applied once when present
         bonus = perCycle × Σ counts[r] × (mult_r − 1)  → returned, added to the producer's payout
         buffers counts per world + the producer's best flavour (no remotes, no profile writes)

FlavorService Heartbeat (FlushSeconds 0.25)
  per player:
    highlights → FlavorPop (unreliable, owner, present only)
               → Rainbow+: FlavorGlow (unreliable, every player in that world; GlowCooldown 6 s / producer)
               → Galaxy+: FlavorHighlight (reliable, owner) + BigPop.announce(batch)
    counts → profile.flavors.found (addFound); a NEW discovery → toast + markChanged({flavors}, saveSoon)
             count growth only → markChanged({flavors}) at most every PushSeconds (20 s)
    quest credit → ProgressEvents.progress("flavor", credit) through the token bucket (20 / min, burst 10)
  BigPop.step (global GapSeconds 30, coalesced)
  every LuckRefreshSeconds (1 s): luck = clamp(eventLuck(os.time()) × adminOdds) → chances + attributes
  every AnalyticsFlushSeconds (10 s): batched tycoon analytics keys per player
```

Bounded work: `rollInto` is O(n) only up to `Roll.ExactCap` (24); above that it samples the multinomial
by conditional binomials (rarest first) — inversion while the mean is < 15 (≤ 64 steps), else a clamped
normal approximation. A 5,000-cycle hitch catch-up costs at most 10 random draws.

## Remotes

| Remote | Dir | Payload | Notes |
|--------|-----|---------|-------|
| `FlavorClaim` | C→S | `"<world>:<flavor>"` or `"all"` | RateLimiter (burst 6, 2/s), string ≤ 40, `parseKey` allowlist + known world, profile writable (`canMutate`), found + unclaimed; claim mark + `grantGems` + `markChanged({flavors}, true)` in one non-yielding step |
| `FlavorHighlight` | S→C owner | `{ producerId, flavor, worldId, oneIn, mult, amount }` | Galaxy+ only |
| `BigPop` | S→C all | `{ entries = { { userId, name, kind, id, label, oneIn, at } }, more }` | ≤ 3 entries, display names + config labels only |
| `FlavorPop` (unreliable) | S→C owner | `{ producerId, flavor, count, amount, worldId }` | best flavour per producer per flush; R120: `amount` = that Lucky Nuke's payout (perCycle × mult) for the feed pill "+$X" |
| `FlavorGlow` (unreliable) | S→C world | `{ anchor, flavor }` | the client checks the anchor is a tagged `SNProducer` BasePart |

## Profile (`profile.flavors`, additive v2 field)

```
flavors = {
  found   = { ["main:galaxy"] = 3, ["dino:sprinkle"] = 120, ... },   -- lifetime special batches (whole, ≤ 1e12)
  claimed = { ["main:galaxy"] = true, ... },                         -- discovery rewards claimed
  tip     = false,                                                   -- owner R112: tip card dismissed
}
```
Keys `^[a-z][a-z0-9]*:[a-z]+$` with a SPECIAL flavour; ≤ 64 entries per map; a newer server's world key
is kept. Missing in pre-R89 saves → empty. Snapshot field `flavors` (same shape, fresh copy).

## Client

- **Pops** (owner): the next income pops of that producer wear the flavour colour (1.2 s), a flavour word
  rises above the pop point ("GLITTER! x3", "+n" when several folded), a sparkle burst + "sparkle" sound.
  Pooled; one word per producer per 0.35 s; skipped off-screen.
- **Glow** (everyone in the world): soft PointLight (owner R19 caps) + drifting sparkles + a soft rotating
  halo for 4 s; Rainbow cycles hue. Pooled rigs; one JuiceLoop step only while glows are live. Reduce
  Motion: light + halo only.
- **Reveal** (owner, Galaxy+): letterbox bars, the flavour card (shout, producer, "BATCH x20!", the odds
  counting up to "1 in 2,500", "+$amount"), world confetti at the producer, fanfare, the HUD faded out
  (focus reason "FlavorReveal"); ≤ 2.8 s; SKIP (top
  bar, ≥ 44 pt; gamepad B / X / Backspace via a high-priority CAS binding). Gate: never during a tutorial
  step, a modal, focus mode (egg hatch / attack target / launch cam / loading) or the plot reveal; one per
  45 s; a blocked reveal waits ≤ 20 s, otherwise it becomes a JuiceBanner shout.
- **Big Pop**: banner just above the HUD's Bottom zone (the toasts / juice banner own the lane under the
  currency stack; skipped while a modal / focus mode is up; waits for the own reveal), a system chat line per entry (`<b>BIG POP!</b> Alex popped a GALAXY batch!  1 in 2,500`, every
  rich-text character escaped) + "+N more Big Pops", toy fireworks at each entry's spot within 420 studs.
- **Flavour Book**: Pets window → FLAVOURS (handoff; B returns to Pets). 15 tiles (3 worlds × 5 flavours):
  undiscovered grey "?" toy with "???", "x3 · 1 in 100" and "+10 GEMS"; ready = flavour colour + green
  "CLAIM +10"; claimed = "FOUND 1.2K". Header: LUCK chip (when the live luck > 1; "SPRINKLE SURGE x2!"
  during a surge), "Discovered n / 15", CLAIM ALL (n). Gamepad grid 5 × 3 under CLAIM ALL; default
  selection = first ready tile → CLAIM ALL → first tile. Every touch device (phones AND tablets) gets
  the page layout: WORLD TABS (NUKE TOWN / DINO VALLEY / MOON BASE, "(n)" ready rewards; LB / RB
  switch) over that world's five tiles in 3 columns (scrolls when short), each tile an icon + four
  stacked lines (name / "SELLS x3" / "1 in 100" / pill) ≥ 14 pt — 15 tiles at 14 pt cut the words
  (Studio pass: "SPRINKL", "X1.5 · 1 IN"); ≥ 44 pt taps everywhere. Desktop / console keep the 5 x 3 grid. It opens on the
  world with the first ready reward, else the world you are in. The HUD Pets badge and the FLAVOURS
  "!" count ready rewards.

## Big Pop triggers + throttles

| Trigger | Source | Delay | Score |
|---------|--------|-------|-------|
| Galaxy+ batch (owner present in that world) | FlavorService flush | 0 | 40 + 5 × rank |
| Mythic / Secret hatch | `PetService.Hatched` (lazy, in Start) | 6 s (after the hatch reveal) | 40 + rarity rank |
| Rebirth (any world) | `RebirthService.Rebirthed` / `WorldRebirthed` | 2.5 s | 30 |

Per player 60 s cooldown; queue ≤ 6 (one per player, better replaces); one broadcast per 30 s (owner
R120; was 8 s) carrying the best 3 entries + "more".

## Quests

Stat `flavor` (ProgressEvents + QuestConfig) and the daily mission "Pop N flavoured batches" (15 / 30 / 50).
Credit = special batches in the world the player is in, through a token bucket (20 / min, burst 10), so
fast late-game producers can't finish it in seconds.

## Admin (registered at runtime, audited)

| Command | Tab | Args | Effect |
|---------|-----|------|--------|
| `FlavorSettings` | Economy | enabled, odds 0..10, bigPop | this server's kill switch (off = Plain only; Book + claims keep working), odds multiplier (× the Happy Hour luck, clamped to 10), Big Pop switch |
| `FlavorGrant` | Players | flavor | the target's NEXT batch in their world becomes that flavour (QA of the full pipeline) |
| `FlavorBookReset` | Players (Studio only) | — | clears the target's Book (re-claimable gems → never live) |

## Analytics (tycoon family)

`flavor:<flavorId>:<world>`, `flavorBonus:<world>`, `flavorFind:<flavorId>:<world>`,
`flavorClaim:<flavorId>:<world>`, `flavorGems`, `flavorRefused:<rate|bad|save|locked|claimed|none>`,
`flavorReveal`, `bigPop:<batch|hatch|rebirth>`, `flavorAdmin:<settings|grant|reset>`; quest keys gained
`flavor`; client funnel screen `FlavorBook` (source `pets`). `flavorId` is registered by FlavorService.

## Happy Hours (E-events) contract

`Shared/Events/HappyHourLogic.flavorLuckAt(nowUnix): number` (1 = none). FlavorLogic.eventLuck resolves it
through a guarded lookup (missing / throwing → 1, never below 1, clamped to MaxLuck). The server refreshes
it once per second for everyone.

## QA

```
python3 scripts/studio-lock.py acquire F-flavors
STUDIO_LOCK_OWNER=F-flavors python3 tools/qa/flavors.py
python3 scripts/studio-lock.py release F-flavors
```
Captures: `docs/verification/r89-flavors/` (pop, glow, reveal × devices, Big Pop banner × devices, Pets
button, Book × devices, claimed, luck chip). Studio probes: `FlavorController.preview("galaxy")`,
`FlavorController.stats()`, the FlavorReveal ScreenGui attribute `DebugHold` (Studio only).

## Next steps

- Wave 2 (spec): Frosting Coats (producer mutations) can reuse FlavorLogic's aggregate roller.
- A per-producer "last flavour" chip on the billboard (T-tutorial owns ProducerBillboards).
- Uploaded flavour toy icons (Blender) for the Book instead of the tinted Nuke icon.
