# Nuke Pass (owner R78, retention pack)

> "come up with a bunch of more improvements … to make the game more retentive and fun." (owner R78)

Design spec: `docs/superpowers/specs/2026-10-31-r78-retention-pack-design.md` §2. Builder: P-pass.
A 30-tier season track with a FREE row for everyone and a PREMIUM row (developer product, one
season). Players fill it with XP from quests (Q-quests) and play time. Claims are explicit CLAIM
presses with juice. Nothing is ever lost: at the end of a season, rewards that were reached but not
claimed are granted automatically.

## Season 1 "Harvest Season"

| | |
|---|---|
| Window | **2026-11-01 00:00 → 2026-12-01 00:00 UTC** (`startsAt` inclusive, `endsAt` exclusive; the same instants as the Harvest Feast, `EventConfig.Season`) |
| Track | 30 tiers × **400 XP** = 12,000 XP |
| Bonus chests | after tier 30, every further **800 XP** = 1 chest of **20 gems**, repeatable |
| Play XP | **10 XP per 5 online minutes**, at most **360 play XP per UTC day** (PassService's once-per-minute tick) |
| Quest XP | starter 50–100, daily 100 × 3 + chest 150, trophy 75 (Q-quests, `ProgressEvents.xp`) |
| Pace | 30 min/day ≈ 510 XP/day → tier 30 in ~24 days; 3 days/week ≈ tier 15 |

Before the start, the screen shows "SEASON 1 STARTS SOON!" with a countdown and a read-only preview
of the track. After the end it shows "SEASON 2 IS COMING SOON!", the state is kept, and XP is not
earned until the next season starts. Add Season 2 as a new row in `PassConfig` (`SEASON_LIST`),
with later instants and its own tiers.

## Rewards (Season 1)

Cash amounts scale with the player's automated income: `max(cashFloor, cashSeconds × income)`, the
same rule as Daily. Boosts are 15 min (free) and 30 min (premium). Spins on the free row go to the
free **bonus** bank. Eggs are held **Lucky Eggs**.

| Tier | Free | Premium |
|---:|---|---|
| 1 | 10 Gems | 25 Gems + Lucky Egg |
| 2 | 10 min of income (floor $500) | 20 min of income (floor $1K) |
| 3 | 1 Spin | 2 Spins |
| 4 | 15 Gems | 30 Gems |
| 5 | 2x Cash 15 min | 2x Cash 30 min |
| 6 | Lucky Egg | 20 Gems + Lucky Egg |
| 7 | 20 Gems | 40 Gems |
| 8 | 15 min of income (floor $2K) | 30 min of income (floor $4K) |
| 9 | 1 Spin | 2 Spins |
| 10 | 25 Gems + 2x Speed 15 min | **Harvest Glow trail** (exclusive) + 50 Gems |
| 11 | 20 min of income (floor $4K) | 40 min of income (floor $8K) |
| 12 | 20 Gems | 40 Gems + Lucky Egg |
| 13 | 2x Cash 15 min | 2x Cash 30 min |
| 14 | Lucky Egg | 3 Spins |
| 15 | 30 Gems + 1 Spin | 60 Gems + Lucky Egg |
| 16 | 25 min of income (floor $8K) | 50 min of income (floor $16K) |
| 17 | 25 Gems | 50 Gems |
| 18 | 2x Speed 15 min | 2x Speed 30 min |
| 19 | 2 Spins | 3 Spins + Lucky Egg |
| 20 | 35 Gems + Lucky Egg | **NUKE PASS title** (exclusive) + 75 Gems |
| 21 | 30 min of income (floor $15K) | 60 min of income (floor $30K) |
| 22 | 30 Gems | 60 Gems + Lucky Egg |
| 23 | 2x Cash 15 min | 2x Cash 30 min |
| 24 | 2 Spins | 4 Spins |
| 25 | 40 Gems + 2x Speed 15 min | 80 Gems + Lucky Egg |
| 26 | Lucky Egg | 30 Gems + Lucky Egg |
| 27 | 35 Gems | 70 Gems |
| 28 | 45 min of income (floor $30K) | 90 min of income (floor $60K) |
| 29 | 2 Spins | 4 Spins + Lucky Egg |
| 30 | **SEASON 1 title** + 40 Gems | **Golden Nukey** pet (exclusive) + 100 Gems |

**Totals:** free = 325 gems, 9 spins, 4 eggs, 6 × 15-min boosts. Premium = 730 gems, 18 spins, 9 eggs,
4 × 30-min boosts and 3 exclusives.

**Value at 159 R$.** The best gem pack rate is about 3.13 gems per R$ (Chest of Gems at 319 R$), so
159 R$ buys about 498 gems. Premium pays 730 gems plus 18 spins (a spin is worth 40 gems), which
is about 1,450 gems of value before counting the 9 eggs, the trail, the title and the pet.
`tests/pass-logic.luau` checks that premium is worth more than twice what the same Robux buys in
gems.

Exclusives:
- **Harvest Glow** (`harvest_glow`): a row in `CrateConfig.Trails` that is in no crate pool. It
  shows locked in the Pets screen's trails tab until it is earned. If the player already owns it,
  150 gems are paid instead.
- **SEASON 1** (`season1`, orange, priority 50) and **NUKE PASS** (`nukePass`, purple,
  priority 60): rows in `PlayerTitlesConfig`, both with `showOwn = true` and `grantable = true`.
  They are granted through `PlayerTitleService.grant`, which saves them in `profile.titles` and
  sets the `Title` attribute. They rank below the honour titles, so EARLY PLAYER still shows.
  If a grant is refused (for example, the title cap is reached), the reward's fallback gems are
  paid.
- **Golden Nukey** (`golden_nukey`): the PetConfig row and model come from A-pets. It is granted
  with `PetGrants.grantFixed`, the live path with auto-equip and the reveal popup. Until the row
  exists, the grant pays **400 gems** instead.

## Premium: developer product

| Key | Kind | Name | Price | Id |
|---|---|---|---:|---|
| `NukePassPremium` | `PassPremium` | Nuke Pass Premium | 159 R$ (managed pricing fallback) | **3725022864** |

The product was created 2026-10-31 by `tools/monetization/publish.py publish` and read back in
three ways: the Open Cloud plan shows 0 changes, `status` shows it live, and in Studio
`GetProductInfoAsync` returned "Nuke Pass Premium | 3725022864 | price=199 | forSale=true".

- **Prompt.** The client sends `PromptProduct("NukePassPremium", "pass")` from the screen's
  PREMIUM button or an UNLOCK card. `PassService` registers a prompt refusal: outside a season the
  player sees "Nuke Pass Season N starts soon!", and if they already own this season's premium,
  "You already own Nuke Pass Premium this season!". Every other gate is MonetizationService's:
  New Player Mode, a saveable session, and one open prompt at a time.
- **Not paid random.** The premium track is deterministic. Premium **spins** (paid bank) and
  **eggs** are paid random items, though, so at claim time PassService waits for
  `resolvePaidRandomAsync` (fail closed). A restricted or unknown buyer gets
  `GemsPerSpin` (40) gems per spin and the egg's fallback gems instead, and the screen previews
  gems for them.
- **Receipt.** The handler runs inside MonetizationService's no-yield grant step and uses the
  idempotent per-profile receipt ledger. `PassLogic.premiumReceipt` decides the outcome:
  - A season is active and not owned → `premium[active] = true` (**granted**).
  - No season is active, the last season ended no more than **6 h** ago, and the state still holds
    its progress → premium for that ended season (**grace**). Receipts carry no purchase time,
    and Roblox retries them later.
  - Anything else (already owned, no season, too late) → **500 gems** (`PremiumFallbackGems`,
    **fallback**), so Robux are never taken for nothing.

  After the grant is durable (`ProductGranted`), the player gets a toast, analytics are counted,
  and the season is settled. A grace unlock auto-grants the ended season's premium tiers here.
- **Late buyers** unlock every premium tier they have already reached; they claim them with
  CLAIM ALL.

## Profile

```lua
profile.pass = {
	season = "harvest1",          -- the season this progress belongs to ("" = never played one)
	xp = 2840,                    -- XP in that season (whole, ≤ 1,000,000)
	dayXp = 60, day = 20758,      -- PLAY XP earned on UTC day `day` (daily cap)
	claimedFree = { [1] = true }, -- claimed free tiers
	claimedPremium = {},          -- claimed premium tiers
	premium = { harvest1 = true },-- seasons premium was bought for (kept forever, ≤ 24)
	overflow = 0,                 -- bonus chests claimed this season
}
```

`PassConfig` owns `newState`, `reconcileState` (the repair), `toSave` and `toWire`.
`ProfileLogic` changes are additive: the type, the default, `reconcile`, `toSave` and the `pass`
snapshot builder. Tier sets are saved and sent as **sorted arrays**, because sparse numeric
tables break DataStores and remotes. Reconcile accepts either form. The push field is `pass`,
sent only when PassService declares it changed (XP, claims, premium, rollover). The field is tiny
(under 200 B) and never rides on cash ticks.

## Server

| File | Role |
|---|---|
| `src/shared/Config/PassConfig.luau` | Seasons, the track, XP rules, state shape and repair, and the read-only status (`activeSeason`, `nextSeason`, `lastEndedSeason`, `progress`, `tierOf`, `overflowEarned`, `status` / `statusOf`, **`claimableCount`**, `offerVisible`, `totals`, `clockNow`, `validate`) |
| `src/server/Pass/PassLogic.luau` | Pure mutations: `addXp` (play cap), `rollover` (auto-grant + reset), `claim` / `claimAll` / `claimOverflow`, `premiumReceipt`, `premiumReward` (policy), `splitReward`, `setTier` / `setPremium` (admin), `needsRollover`, `needsPolicy`, `clone` |
| `src/server/Pass/PassFlow.luau` | Pure settle / XP ordering: `decide` (settled / now / wait), `hold`, `drain` |
| `src/server/Services/PassService.luau` | The live boundary: the `ProgressEvents.Xp` listener, one play tick per minute for the server, settle on join, remotes, product handler and refusal, analytics, admin |

**Claim flow** (`PassClaim` / `PassClaimAll`):
1. Rate limiter (6 burst, 2/s).
2. Argument checks: `Validate.oneOf(track, {free, premium, overflow})` and
   `Validate.integer(tier, 0, 30)`; free and premium need tier ≥ 1.
3. One claim in flight per player. The profile must be loaded and `canMutate`.
4. A dry run on a clone works out what the claim would pay. If premium spins or eggs are
   involved, the server waits for the policy (`resolvePaidRandomAsync`).
5. After that yield, the session is re-checked.
6. **One non-yielding step** marks the rewards claimed and pays them through
   `RewardLogic.apply`, `PetGrants.grantFixed`, `CrateLogic.grantTrail` or
   `PlayerTitleService.grant`, with fallback gems for items that cannot be granted.
7. `markChanged(saveSoon)`, then a reward toast.

Re-running the same claim pays nothing.

**Season settle** runs on join, on every XP grant or tick that finds stale state, after premium
receipts, and after admin edits. Leftovers are only granted into a saveable session; otherwise
they wait for the next join. Online players are settled live by the minute tick at the season-end
instant.

**Settle / XP ordering** (`Server/Pass/PassFlow`, lead review 2026-10-31). XP, the play tick,
claims and admin edits never settle with a guessed paid-random policy. `PassFlow.decide`
returns one of three answers:
- **settled**: there is nothing to roll over.
- **now**: no premium spins or eggs are owed, or the policy is already known.
- **wait**: another settle or claim is in flight, or premium spins or eggs are owed and the
  policy is still unknown.

On **wait**, the XP is **held** and the waiting `PassService.settle` runs: it resolves the policy,
settles, then drains the held XP exactly once through the normal XP path. If a new season is
active, the XP lands there after the reset. Between seasons, the documented rule (no XP outside a
season) drops it. A claim pressed during a wait is refused with a toast ("Finishing last season's rewards... try
again in a moment!", at most one every 4 s) and counted as `pass:refused:<wait|recheck>`.
Held XP is bounded (64 entries) and dropped if the session changes. Tested in
`tests/pass-logic.luau` §11.

## Remotes

| Remote | Dir | Payload | Server checks |
|---|---|---|---|
| `PassClaim` | C→S | `(track: "free" \| "premium" \| "overflow", tier: number)` (overflow: `0` claims every earned chest) | see the claim flow |
| `PassClaimAll` | C→S | `()` | the same, everything claimable |
| `PromptProduct` | C→S | `("NukePassPremium", "pass")` | MonetizationService + the PassPremium refusal |

The server answers with the profile push (`pass` plus the touched currency fields) and a `Notify`
reward toast. No result remote is needed.

## Client

- **Screen `NukePass`** (`src/client/UI/Screens/NukePass/{init, TierStrip, PassView}`):
  - An orange stud window with the Star icon. The top bar shows the season and its countdown, a
    TIER badge, the XP bar with "x / 400 XP to tier N" and play XP today, CLAIM ALL (n), and
    PREMIUM with the live PriceBook price (or PREMIUM OWNED).
  - The track is a horizontal strip: the FREE row, tier chips on a stud progress line, the
    PREMIUM row, and a BONUS CHEST column.
  - The footer shows the premium value line ("730 Gems · 18 Spins · 9 Eggs · Golden Nukey ·
    Harvest Glow Trail · NUKE PASS Title"). Restricted players see gems only.
  - Cards show, depending on state: CLAIM, CLAIMED (dark veil and a check badge), TIER N, UNLOCK
    (purple, prompts premium), or LOCKED! (lock badge).
  - The tier 30 premium card shows the Golden Nukey in 3D (`ModelViewport`; the icon until the
    pet row exists). The tier 10 card has a colour swatch of the trail.
- **Juice.** Newly claimed cards pop and burst 8 pooled stars, with the "milestone" and
  "coin_burst" sounds and a Reward haptic. Gems and cash fly into the HUD counters by themselves.
  With Reduce Motion, the card only flashes.
- **Console and mobile.** Two ResponsiveModal modes: `wide` 1560×860 for desktop, console and
  tablet, and `phone` 1320×620. Buttons are ≥ 44 pt and captions ≥ 14 pt (from `layout.tap` and
  `minText`). On a phone the top bar is a single row of 44 pt buttons. Cards put the icon on the
  left with a one-line caption beside it and never shrink text below 14 pt.
  - On a gamepad, the card rows form a linked grid; Up goes to CLAIM ALL and PREMIUM.
  - The strip follows the gamepad cursor, LB/RB (Q/E) page 5 tiers, and B closes the window.
  - The cursor starts on the first claimable reward, otherwise on the current tier, and never on
    the close X.
  - Touch scrolls the strip natively.
- **HUD offer `Pass`** (`HudZonesConfig.Offers`, `openScreen = true`): shown while a season runs
  and premium is not owned (`PassConfig.offerVisible`). It opens the NukePass screen rather than
  prompting directly.
- **Quests banner** (Q-quests): `ScreenManager.open("NukePass", { source = "quests" })`. The badge
  uses `PassConfig.claimableCount(profile.pass, PassConfig.clockNow(serverNow))`.

## Analytics (retention family; `AnalyticsConfig.Metrics.retention`)

| Key | Meaning |
|---|---|
| `pass:xp:<starter\|daily\|chest\|trophy\|play\|admin\|other>` | XP added by source (amount = XP) |
| `pass:tier:<1-30>` | tiers reached |
| `pass:claims:<free\|premium\|overflow>` | rewards claimed by track (amount) |
| `pass:claim:<free\|premium>:<1-30>` | claims by track and tier |
| `pass:claimAll` | CLAIM ALL presses that paid something |
| `pass:auto:<free\|premium\|overflow>` | rewards auto-granted at season end (amount) |
| `pass:premium:<granted\|grace\|fallback\|admin>` | premium receipt outcomes and admin toggles |
| `pass:premiumTier:<0-30>` | the tier buyers had reached when buying premium |
| `pass:policyGems` | premium spins and eggs paid as gems (policy) |
| `pass:season:<seasonId>` | players who started a season (`seasonId` registered by PassService) |
| `pass:refused:<wait\|recheck>` | claim taps refused while a season-end settle waits for the policy (a "try again" toast, at most one per 4 s) |

The premium funnel (prompt → purchase, source **`pass`**, added to
`PurchasePromptConfig.Sources`) is counted by MonetizationService's revenue recorders. Reward
currency goes to the economy family with reason `pass` (TransactionType Gameplay). Screen opens
count as `open:NukePass`, with source `hud`, `offer` or `quests`.

## Admin (owner panel; `Lazy.registerAdmin`, validated and audited)

| Command | Tab | What |
|---|---|---|
| `PassGrantXp { amount 1..12000 }` | Players | Adds XP in the active season |
| `PassSetTier { tier 0..30 }` | Players | Sets the tier (claimed rewards stay claimed) |
| `PassPremium { on/off }` (confirm) | Players | Toggles premium for the active season, with no Robux involved |
| `PassStatus` | Players | Read-only: season, tier, XP, play today, premium, claimable |
| `PassReset` (Studio only, confirm) | Players | Wipes the player's pass state |
| `PassClock { days }` (Studio only) | Server | Shifts the pass clock (`ReplicatedStorage.NukePassClockOffset`) so a season can be tested before or after its dates. Live servers ignore the attribute. |

## Tests

`lune run tests/pass-logic` runs 296 checks, covering:
- The catalogue against the spec, including that the exclusives exist in their catalogues and
  that Harvest Glow is in no crate pool.
- Value against the gem packs, the product row, and the analytics keys.
- Season boundaries at the exact instants.
- Tier math and the play cap, including the UTC day reset.
- Every claim refusal code and idempotency.
- Retroactive premium and every receipt outcome.
- The end-of-season auto-grant happening exactly once, and resets.
- Policy shaping and the exclusive split.
- Repair of NaN, garbage and hostile tables, and array↔map round-trips.
- ProfileLogic default, reconcile, toSave and snapshot.
- `claimableCount` on raw, garbage and stale state, and the Studio clock.

`tests/{validate, profile-logic, player-titles, pets-policy, analytics-recorders}` were extended
for the new product, field, titles, product kind and `seasonId` kind.

**Studio QA** (`tools/qa/nuke_pass.py` with `nuke_pass_server.luau` / `nuke_pass_client.luau`;
one solo playtest while holding `studio-lock.py`). Run it with
`STUDIO_LOCK_OWNER=P-pass python3 tools/qa/nuke_pass.py`. Captures go to
`docs/verification/r78-pass/`. The run walks through:
1. Before the season: the overlay and countdown, and no HUD offer.
2. Clock +5 days: the season is joined and the HUD Pass offer shows.
3. 1,300 XP gives tier 3, captured on the device matrix (desktop, phone, tablet, console).
4. CLAIM by a real click; if the click misses, the real `PassClaim` remote is fired. A repeat
   claim pays nothing, and hostile arguments change nothing.
5. Premium through the REAL receipt path (`simulateReceiptAsync`): unlocked; the same PurchaseId
   again pays nothing; a second purchase pays 500 fallback gems.
6. Restricted region: 2 premium spins pay 80 gems.
7. CLAIM ALL with the juice capture.
8. Tier 30 plus 2 chests, then CLAIM ALL: SEASON 1 and NUKE PASS titles, the Harvest Glow trail,
   and the Golden Nukey with its live reveal popup.
9. Gamepad default selection lands on the claimable chest.
10. Clock +31 days: the season's leftovers are auto-granted and the overlay reads "Season 2 is
    coming soon".
11. The Studio profile and clock are restored.

## Icon

`NukePass` (IconAssets `offer` category; alias `NukePassPremium`): a gold-recoloured Fluent
"Ticket" with the game's red cartoon pocket nuke in front and sparkles. Composite
`_GoldTicket` + `Nuke` + `_Sparkles` in `assets/icons/sources.json`. It was uploaded 2026-10-31 as
Image **117642180669672** and is in Reviewing. Run `python3 tools/ui/icons/icons.py moderation`,
then `sync`, to record Approved.

It is used by:
- the HUD Pass offer;
- the NukePass window header;
- the pass toasts;
- the NUKE PASS title tag;
- the Quests banner (Q-quests);
- the live product's purchase-prompt icon, patched through `publish.py`.

## Next steps

- Season 2: add a `SEASON_LIST` row (new id, instants, tiers) and its exclusives. Nothing else
  changes.
- Tune XP pacing from `pass:xp:*` and `pass:tier:*`, and the premium price from
  `pass:premiumTier:*` and the `pass` funnel.
