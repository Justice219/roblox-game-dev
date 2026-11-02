# Early Gift Ladder, Pocket Rocket and the favorite prompt (owner R89)

Spec: `docs/superpowers/specs/2026-10-31-r89-competitive-wave-design.md` §3 (builder G-gifts).
Owner request: `docs/owner-requests.md` R89. This replaces the design spec §7 seven-gift Time Rewards.
The rest of the retention stack (daily, wheel, codes, shared reward shape) is in `docs/retention.md`.

## 1. Early Gift Ladder

Ten gifts unlock with today's online playtime. The server counts it; the client never sends a time.
The first gift lands at 1 minute because the day-1 data showed most churn inside the first 2 minutes.

| # | Minutes | Card icon | Reward (deterministic) |
|---|---------|-----------|------------------------|
| 1 | 1 | Cash | 30 s of income (at least $150) |
| 2 | 3 | Gems | 5 gems |
| 3 | 5 | Cash | 60 s of income (at least $300) |
| 4 | 10 | x2Cash | 10 min of 2x Cash. This is the **favorite-prompt happy moment**. |
| 5 | 15 | Gems | 10 gems |
| 6 | 25 | CashPack | 5 min of income (at least $1,500) |
| 7 | 40 | Crate | 5 gems + 1 held **Supply Crate**. Where paid random items are restricted, or the policy is still unknown (fail closed), the crate is paid as 60 gems instead. |
| 8 | 60 | Spins | 2 Lucky Wheel spins (free bonus bank) + 10 gems |
| 9 | 90 | x2Cash | 15 min of 2x Cash + 10 min of income (at least $3,000) |
| 10 | 120 | Gift (rainbow card) | 30 min of income (at least $20,000) + 40 gems + 3 spins |

- **Deterministic.** Every reward uses the shared `RetentionConfig.Reward` shape: cash seconds + floor, gems, spins, timed boosts. Nothing on the ladder is a paid random item, so a future paid skip could never be paid-random.
  - Spins land in the free `bonus` bank (`RewardLogic.apply` without `paidSpins`).
  - The one crate is a held crate (`CrateLogic.grantHeld`). Opening it goes through the normal crate policy gate.
- **Kept across rejoins the same UTC day.** `profile.timeRewards = { day, seconds, claimed, ladder }` lives in the save. Leaving does not reset progress; a new UTC day starts a fresh ladder.
  - `PlaytimeLogic.rollover` only moves the day forward, so a clock running backwards never reopens a day.
- **Server loop.** `PlaytimeService` runs one 1 Hz loop for every player. Each tick credits at most 5 s, so a hitch never mints time, and a day is capped at 24 h.
  - `timeRewards` is pushed every 30 s and on every claim or rollover. Between pushes the client extrapolates from the push's arrival time.
- **Claims.**
  - `ClaimTimeReward(i)` checks the token bucket, a valid index, that the profile is loaded and mutable, and `PlaytimeLogic.claim`. It pays in the same non-yielding step.
  - `ClaimTimeRewardsAll()` uses `PlaytimeLogic.claimAll`. Every ready gift is marked and paid in one step, with one toast ("4 gifts opened! +$1.2K, +5 Gems, 2x Cash 10m").
  - Each opened gift fires `ProgressEvents "gift"`, which feeds Quests and the Nuke Pass.

### Migration (migration-safe profile change)

`timeRewards.ladder` is an additive field. Saves from before R89 have no `ladder` field, which reads as `1` (the old 5/15/30/60/90/120/180 ladder). `ProfileLogic.reconcile` passes the stored claims through `PlaytimeConfig.migrateClaimed`. On the update day this never pays a gift twice:

| Stored ladder | Result |
|---------------|--------|
| current (2) | Claims kept. Indices outside 1..10 are dropped. |
| retired (in `LegacyMinutes`) | Every new gift whose mark is at or below the **highest claimed old mark** counts as claimed. Example: old 5-min gift claimed → new 1/3/5-min gifts closed; the 10-min gift and later stay open. |
| unknown (junk / future) | Every gift the stored playtime already reached counts as claimed, which is the conservative choice. |

Today's seconds are always kept. `profile.gifts` (below) is a new top-level block: missing means `GiftsConfig.newState()`. No schema bump.

### Window (`UI/Screens/TimeRewards`)

- **Layout.** A toolbar, then ten cards (`TimeRewards/GiftGrid`).
  - Toolbar: "N / 10 opened", "Playtime saved all day!", the next-gift countdown over a progress bar to the 120-min mark, and **CLAIM ALL**. The button reads "CLAIM ALL (n)" when two or more gifts are ready and is locked while none is.
  - Card title: a live countdown while locked, "Ready!" with a glowing ring when ready, "N Min" once claimed.
  - Card detail: the reward, one part per line (up to three: "$2.14Sx" / "40 Gems" / "3 Spins"), at a fixed size that never drops below 14 pt on touch. Cash uses the server's own rule (`RewardPreview`).
  - Card button: LOCKED! / CLAIM / CLAIMED.
- **Modes** (`ResponsiveModal`):
  - `grid` (1120 x 800) is a 5 x 2 grid on desktop, console and tablet.
  - `row` (1320 x 540) is used on a landscape phone. It is a sideways-scrolling row of 220-px cards, so CLAIM reaches 44 pt and text 14 pt; ten cards in one fixed row would be about 120 px wide.
- **Gamepad.**
  - The grid links the ten CLAIM buttons; Up from the top row goes to CLAIM ALL, and Down from CLAIM ALL returns to card 1.
  - The row links as one list, and `GamepadNav.followScroll` scrolls it.
  - Default selection: CLAIM ALL with 2+ gifts ready, else the first ready CLAIM, else card 1. B closes.
- **Join rules (R78, kept).** The window never opens by itself. A ready gift only lights the Rewards hub badge (`UI/RewardsBadges`, unchanged: it reads `PlaytimeConfig.status`), so nothing competes with the guided tutorial or the JoinFlow queue.

## 2. Pocket Rocket (developer product `PocketRocket`, id 3725469699)

A small impulse buy, once per UTC day. It grants **300 s of the buyer's own automated income, at least $500**. The grant goes through the shared `cashSeconds + cashFloor` path (`RewardGrant.applyInReceipt` → `RewardLogic.cashFor`), so the HUD preview is the grant.

**Price math (rule: its value per Robux never beats a Cash pack).** `MonetizationConfig.validate()` and `tests/gift-ladder.luau` enforce both columns:

| Product | R$ | Income seconds | s / R$ | Floor | $ floor / R$ |
|---------|----|----------------|--------|-------|--------------|
| **Pocket Rocket** | **15** | **300** | **20.0** | **500** | **33.3** |
| Stack of Cash (CashSmall) | 23 | 600 | 26.1 | 1,000 | 43.5 |
| Bag of Cash (CashMedium) | 63 | 1,800 | 28.6 | 10,000 | 158.7 |
| Crate of Cash (CashLarge) | 159 | 7,200 | 45.3 | 100,000 | 628.9 |
| Vault of Cash (CashHuge) | 359 | 21,600 | 60.2 | 1,000,000 | 2,785.5 |

- The rocket is about 23 % under the worst pack, so a managed-price nudge on a pack does not flip the rule. A 9 R$ rocket (33 s/R$) would be flagged; the test proves the rule bites.
- **Managed pricing is off** for this product, so the fixed 15 R$ keeps the rule. Regional price drops on the packs only make the rocket relatively worse value.
- The packs grant from the live income including boosts (`TycoonService.incomePerSecond`); the rocket uses boost-free automated income. That makes the packs even more generous in practice.

**Flow** (`Server/Retention/PocketRocket`, lifecycle owned by `PlaytimeService`):

1. **Prompt.** The HUD sends `PromptProduct("PocketRocket", "offer")`. MonetizationService's checks run, then the kind's refusal. Once `profile.gifts.rocketDay == today`, the toast reads "Your Pocket Rocket already launched today - come back tomorrow!" (`rocket:refused`).
2. **Receipt.** The handler runs inside MonetizationService's ONE non-yielding grant step, after the per-profile receipt ledger check, so a re-delivered receipt is never granted twice. It pays the cash and stamps `rocketDay = today`.
   - A receipt for a rocket already used today (bought just before UTC midnight, a slow retry, two devices) is still granted. Robux are never taken for nothing (`rocket:late`).
   - Analytics run after the grant is durable, from `MonetizationService.ProductGranted`: `rocket:grant`, `rocket:cash`.
3. **HUD offer** (`UI/Hud/HudOffers`, second in the right column).
   - The label is the live amount, "+$42.4K": `RewardPreview.cash(GiftsConfig.rocketReward(), profile)`.
   - Shown only in Nuke Town (it pays Nuke Town cash), only while the id is live, and hidden once bought today. It comes back after UTC midnight on one timer.
   - HudOffers listens to `ClientState` itself for `gifts / tycoon / rebirths / rebirthShop` (Hud.luau is untouched). There is no per-frame work.
   - Icon: `PocketRocket` (rocket over a money stack; `assets/icons/sources.json` composite, uploaded as asset 123178385207296). It falls back to `MoonRocket`.

## 3. Favorite prompt (one time, never rewarded)

`AvatarEditorService:PromptSetFavorite(game.PlaceId, Enum.AvatarItemType.Asset, true)` can only run on the client; the place id is the experience's asset id. The server decides when it may run and records the answer.

1. **Happy moment (server, `Retention/FavoritePrompt`).** Either the 10-minute gift is claimed (gift `favoriteMoment`) or a rebirth happens (`ProgressEvents "rebirth"`).
   - It is announced only while `profile.gifts` allows it: not answered, and shown fewer than `MaxAsks` (2) times. At most once per session.
   - Sends `FavoriteMoment { moment }` and counts `favorite:moment:<gift|rebirth>`.
2. **Client (`TimeRewards/FavoriteClient`)** waits for a calm moment, at most 10 minutes, then drops the moment. Calm means:
   - `JoinFlow.isQuiet()`: no menu (for example the Time Rewards window the gift was claimed in), no plot reveal or focus-mode cinematic, no purchase prompt, nothing queued, not in the guided steps;
   - the tutorial is finished.
   It then shows the dialog and reports `FavoriteReport("shown")`, then the result name. At most one prompt per session.
3. **Server records the answer.**
   - `"shown"` is accepted only within 15 min of an announced moment, once per session. It sets `favoriteAsks + 1` and `favorite = 1` (shown).
   - `Success` or `PermissionDenied` sets `favorite = 2` (answered), and the prompt never comes back.
   - `Failed` is not an answer: a later happy moment may ask again, up to `MaxAsks`.
   - Results are accepted only within 10 min after an accepted "shown".
4. **Never rewarded** (Roblox rules). No reward, toast or unlock follows an answer. A forged report can only stop the player's own future prompts. Every report goes through typeof + allowlist + token bucket + session windows.

## 4. Data, remotes and analytics

- `profile.gifts = { rocketDay, favorite, favoriteAsks }` (`GiftsConfig.newState / reconcileState / toWire`). The snapshot field `gifts` sends `{ rocketDay, favorite }`.
- Remotes:
  - `ClaimTimeReward(index)` and `ClaimTimeRewardsAll()` (C→S)
  - `FavoriteMoment({ moment })` (S→C)
  - `FavoriteReport(report)` (C→S)
- Retention keys (KeySpec allowlist):
  - Ladder: `time:claim:<1-10>`, `time:claimAll:<2-10>`, `time:crate:<crate|gems>`, `time:admin:<reset|unlock|claim>`
  - Pocket Rocket: `rocket:grant`, `rocket:cash`, `rocket:late`, `rocket:refused`
  - Favorite prompt: `favorite:moment:<gift|rebirth>`, `favorite:<shown|success|denied|failed>`
- Revenue is automatic for the product: `prompt:PocketRocket:offer`, `product:PocketRocket:count|robux`, `kind:PocketRocket:robux` and the funnel. The economy reason `pocketRocket` maps to IAP.

## 5. Admin (Players tab; `PlaytimeService` registers through `Event/Lazy.registerAdmin`)

| Command | Args | Does |
|---------|------|------|
| GiftLadderStatus | — | Minutes today, claimed, ready count, Pocket Rocket used / available, favorite state + asks (read-only) |
| GiftLadderReset | part = ladder / rocket / favorite / all (confirm, audited) | QA reset of today's ladder (0 min, nothing claimed), the rocket day, the favorite record |
| GiftLadderStep | step 1..10, mode = unlock / claim (audited) | UNLOCK sets today's playtime to that gift's mark; CLAIM also opens and pays it through the normal claim path |
| FavoriteMomentTest | — (Studio only) | Sends a favorite moment now, even when it was answered before |

The older `ResetDaily` (daily + today's ladder) and `AddPlaytime` seams still work: `PlaytimeService.resetToday / addSeconds`.

## 6. Tests and QA

- `tests/gift-ladder.luau` covers:
  - the ladder config and math, CLAIM ALL;
  - same-day carry-over through save / reconcile, rollover and admin clamps;
  - migration from the 7-gift ladder;
  - the Pocket Rocket price rule against every Cash pack, plus once per day and late receipts;
  - the favorite gate and the `profile.gifts` block.
- Updated suites: `tests/retention-config.luau` (10 gifts), `tests/retention-logic.luau`, `tests/profile-logic.luau` (schema), `tests/validate.luau` (product + remotes), `tests/pets-policy.luau` (paid-random audit).
- Studio runner: `STUDIO_LOCK_OWNER=G-gifts python3 tools/qa/gifts.py`, with probes `tools/qa/gifts_{client,server}.luau`. Captures go to `docs/verification/r89-gifts/` (HUD offer, ladder, after CLAIM ALL, all ready; phone / tablet / console).

## 7. Files

| File | Role |
|------|------|
| `src/shared/Config/PlaytimeConfig.luau` | The ten gifts, ladder version + migration, read-only views |
| `src/shared/Config/GiftsConfig.luau` | Pocket Rocket + favorite config, the price rule, `profile.gifts` block |
| `src/server/Retention/PlaytimeLogic.luau` | Ladder rules (rollover, accrue, claim, claimAll, admin) |
| `src/server/Retention/GiftsLogic.luau` | Pocket Rocket + favorite rules (pure) |
| `src/server/Retention/PocketRocket.luau` | Product handler + prompt refusal + analytics |
| `src/server/Retention/FavoritePrompt.luau` | Happy moments + report handling |
| `src/server/Services/PlaytimeService.luau` | Loop, claims, crate payout, admin, sub-module lifecycle |
| `src/client/UI/Screens/TimeRewards/{init, GiftGrid, FavoriteClient}.luau` | Window, grid, favorite client |
| `src/client/UI/Hud/HudOffers.luau` | The Pocket Rocket HUD offer |

## 8. Next steps

- Watch `time:claim:1..4` against the day-1 2-minute churn, and `rocket:grant / prompt:PocketRocket:offer` conversion.
- If the rocket converts well, consider a second daily surface (Welcome Back) that reuses the same product and rule.
