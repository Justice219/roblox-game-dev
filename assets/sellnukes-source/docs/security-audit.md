# SellNukes pre-publish security audit (2026-10-30)

Scope: every client→server RemoteEvent handler in `src/server/**`, measured against the CLAUDE.md
security rules. Also covered: receipt idempotency, admin authorization, player-text filtering,
`loadstring`, and RemoteFunctions. Each handler was read in full, following its helpers one level
deep. The audit was done by P1, with three read-only audit agents that each covered a slice.

Status: **PASS** means it meets every rule. **FIXED** means a gap was found and fixed in this pass
(see Fixes). **RISK** means a known residual that is accepted and documented, or reported to the
file's owner.

Columns:
- **Args**: every argument is typeof/`Validate.*` checked.
- **Ids**: ids are checked against config.
- **Num**: NaN and ±inf are rejected, and numbers are clamped or integer-checked.
- **Rate**: a per-player `RateLimiter` (burst/refill).
- **State**: loaded, `canMutate`, owns, unlocked, in range.
- **Trust**: no client amount, Instance or path is trusted.
- **Yield**: state is re-checked after every yield, and there is no double-spend race.
- **Leave**: limiter and per-player tables are forgotten on PlayerRemoving, and late packets are dropped.

## Global checks

| Check | Status | Evidence |
|-------|--------|----------|
| `loadstring`, `getfenv`, `setfenv` | PASS | None anywhere in `src/` |
| Server→client RemoteFunction or `OnServerInvoke` | PASS | There are no RemoteFunctions. `Shared/Net/Remotes` declares RemoteEvents only |
| Late packets from departed players | **FIXED** | A handler could run after PlayerRemoving and re-create per-player limiter buckets or memories (a leak). There is a new `Remotes.onServerEvent(name, handler)` built on `Remotes.fromPresentPlayer`, which drops events unless `player.Parent == Players`. Every handler outside Attack/Defense now connects through it (36 connections) |
| Player text shown to others | **FIXED** | `RenameStand` is the only player text other players see. It is filtered with `FilterStringAsync` in the PublicChat context and passed through `GetNonChatStringForBroadcastAsync` before it is saved or shown, and it fails closed. **New:** a saved name is re-filtered (once per session) before it is shown again (`PlotService.applyStandName`). Code text is never echoed back (fixed server strings only) |
| Receipt idempotency (`MonetizationService.processReceiptAsync`) | **FIXED** | The ledger is checked first. Grant and record happen in one non-yielding step. `commitAsync` runs before `PurchaseGranted`. Every failure returns NotProcessedYet. Concurrent duplicates are dropped. **New:** the profile is snapshotted before the handler and fully restored if the handler errors, yields or refuses (`ProfileLogic.takeSnapshot`/`restoreSnapshot`), so a half-applied grant can never be autosaved and then granted again. The `recordReceipt` result is now checked, and `onGranted` is wrapped in a pcall |
| Admin authorization | PASS / RISK | `AdminPipeline` re-authorizes on **every** call (`AdminAuth.isAuthorizedAsync`), validates arguments with `AdminValidate` (schema, MaxArgs, no metatables or unknown keys), applies 10/3 per UserId plus a per-command cooldown, and writes an audit log. RISK: group-rank auth is cached for 120 s (600 s while Roblox's group API is failing), so a demoted group admin keeps rights that long |
| Analytics admin requests | PASS / **FIXED** | `AnalyticsRequest` and `AnalyticsRawRequest` check auth on every request and re-check it on the reply. FIXED: the denied-warn throttle key was per UserId and grew forever; it is now one shared key |

## Handlers

| Remote | File | Args | Ids | Num | Rate | State | Trust | Yield | Leave | Status |
|--------|------|------|-----|-----|------|-------|-------|-------|-------|--------|
| ProfileDeltaAck | Services/PlayerDataService | ✓ | – | ✓ | 2/(1/30) | ✓ | ✓ | – | ✓ | FIXED (late packets) |
| ProfileResync | Services/PlayerDataService | ✓ | – | – | 2/0.1 | session | ✓ | – | ✓ | FIXED (late packets) |
| PromptProduct / PromptPass | Services/MonetizationService | `configKey` + `cleanSource` | ✓ | – | 3/0.5 shared | loaded, canMutate, oneTime, owned | ✓ | re-check after policy yield | ✓ | FIXED (late packets) |
| SetSetting | Services/SettingsService | `applySetting` allowlist + boolean | ✓ | – | 8/2 | loaded | ✓ | – | ✓ | PASS |
| ProducerClick | Tycoon/TycoonService | `key(32)` | runtime from config | – | 20/12 | built, not automated, reach | ✓ | – | ✓ | PASS |
| ProducerUpgrade | Tycoon/TycoonService | `key` + `oneOf` | ✓ | server cost | 15/8 | level ≥ 1 | ✓ | – | ✓ | PASS |
| ProducerGemUpgrade (R86) | Tycoon/TycoonService | `key(32)` | runtime from config | server price (admin-set, clamped 1..10000) | 6/3 | level ≥ 1, < MaxLevel, switch on | atomic `trySpendGems`, one level, refund if not applied | – | ✓ | PASS |
| PadBuy | Tycoon/TycoonService | `key(48)` | `PadsById` + available | – | 6/3 | own plot, reach, cash | ✓ | no yield | ✓ | PASS |
| TeleportArea | Tycoon/TycoonService | `integer(1..#Areas)` | ✓ | ✓ | 3/0.5 | unlocked | server CFrame | – | ✓ | PASS |
| Rebirth | Tycoon/RebirthService | none | – | – | 2/0.2 + busy | canRebirth, canMutate | ✓ | changes made before the yield, busy flag held | ✓ | PASS |
| RebirthShopBuy | Tycoon/RebirthService | `configKey(Shop)` | ✓ | cost clamps | 8/4 | **canMutate added** | ✓ | – | ✓ | FIXED |
| RenameStand | Tycoon/PlotService | `Validate.text(24)` (UTF-8, control chars) | – | – | 2, then 1/15 s + in-flight | feature, plot | ✓ | **feature re-checked after the filter yield** | ✓ | FIXED (+ re-filter on display, silent validation before the limiter) |
| RenamePlot (R88) | Tycoon/PlotNames | `PlotNameLogic.parse` = `Validate.text(24)` + invisible / bidi chars dropped; "" = reset | – | – | 3, then 1/10 s + in-flight (toast throttled 1/4 s) | owns a plot | ✓ | player, plot index, profile re-checked after the filter yield; censored → refused | ✓ | NEW (filtered before save + re-filtered once per session on display, fail closed) |
| TeleportHub | Tycoon/PlotService | none | – | – | 3/0.5 | character | ✓ | – | ✓ | PASS |
| PlotRevealDone | Tycoon/PlotService | none | – | – | 3/1 | pending reveal | ✓ | – | ✓ | PASS |
| TeleportPlot | Tycoon/PlotService | `integer(1..PlotCount)` | owner map | ✓ | 3/0.5 + 5 s | Teleporter pass for others' plots | ✓ | cached pass | ✓ | PASS |
| EventCollect | Services/EventService | `key(16)` | live turkey map | finite distance | 6/3 + 0.6 s | active, owner, once, server distance | ✓ | – | ✓ | PASS |
| EventRedeemSheet | Services/EventService | none | – | – | 3/1 | canMutate, redeem check | ✓ | no yield | ✓ | PASS |
| EventShopBuy | Services/EventService | `configKey(ShopByKey)` | ✓ | config price | 3/1 | canMutate | ✓ | refund path | ✓ | PASS |
| ClaimDaily | Services/RetentionService | none | – | – | 4/0.5 | server UTC day | ✓ | – | ✓ | FIXED (late packets) |
| ClaimTimeReward | Services/PlaytimeService | `integer(1..#Gifts)` | ✓ | ✓ | 4/0.5 | canMutate, claimed | ✓ | – | ✓ | FIXED (late packets) |
| ClaimGroupReward | Services/GroupRewardService | none | – | – | 2/0.2 | inFlight, membership | ✓ | re-check after GetRankInGroup | ✓ | FIXED (late packets) |
| ClaimNotifyReward | Services/NotifyRewardService | `oneOf` | ✓ | – | 4/0.2 | claimed, canMutate | **client-reported opt-in** | – | ✓ | RISK (see below) |
| RedeemCode | Services/CodesService | `CodesConfig.normalize` (1–20 ASCII alphanumeric) | config + runtime codes | – | 4/0.25 | canMutate, used/expired | never echoed | – | ✓ | FIXED (refusal replies throttled to 1 per 5 s) |
| SpinWheel | Services/LuckySpinService | `Validate.requestId` + memory | – | ✓ | 3/0.5 | canMutate, banks | ✓ | policy yield re-checked, memory only for present players | ✓ | FIXED (paid-random gate, late packets) |
| HatchEgg | Services/PetService | `integer` / `key` | EggConfig | ✓ | per UserId + one in flight | stand range, area, canMutate, policy | ✓ | policy yield re-checked, request memory | ✓ | PASS |
| EquipPet / EquipBest / DeletePets / LockPets | Services/PetService | `key` / `boolean` / `stringArray(≤100)` | owned uids | – | action bucket | canMutate | ✓ | – | ✓ | PASS |
| OpenCrate | Services/CrateService | `integer` / `key` | CrateConfig | ✓ | 3/1 + one in flight | canMutate, policy | ✓ | policy yield re-checked | ✓ | PASS (refusal analytics added) |
| EquipTrail | Services/CrateService | `key` or "" | owned trails | – | 6/3 | canMutate | ✓ | – | ✓ | PASS |
| PetIndexClaim (R78) | Services/PetService | `integer(1..7)` | PetIndexConfig milestones | ✓ | 4/1 | canMutate, claimed (idempotent), discovered ≥ need | ✓ (gems via RewardGrant, same step) | no yield | ✓ | PASS |
| PassClaim / PassClaimAll (R78) | Services/PassService | `oneOf(free\|premium\|overflow)` + `integer(0..30)` / none | PassConfig tiers | ✓ | 6/2 + one claim in flight | canMutate, active season, reached, claimed (idempotent), premium owned | ✓ (amounts from config; rewards via RewardLogic / PetGrants / CrateLogic / PlayerTitleService in the claim step) | dry run first; policy yield re-checked (session identity + canMutate); claim + pay in ONE non-yielding step | ✓ | PASS |
| NukePassPremium receipt (R78) | Services/PassService (kind PassPremium) | MonetizationService ledger | – | – | – | season decided server-side (`PassLogic.premiumReceipt`); prompt refused outside a season / when owned | ✓ | no yield (handler); settle after durable in its own thread | ✓ | PASS (late receipt → grace season or 500 gems, never Robux for nothing) |
| FunnelStep / ClientDevice / OffersSeen | Services/AnalyticsService → Analytics/Sessions, Revenue | allowlists, `integerIn`, MaxCards | ✓ | ✓ | per UserId | session | counts only | – | **Forget now runs before the no-session return** | FIXED |
| ClientPerf | Analytics/ClientPerfIngest | exact-length buffer | device class | clamped | 3/(1/25) | session | clamped claims | – | ✓ | PASS |
| AnalyticsRequest | Analytics/Reports | `requestId` / `oneOf` | Ranges | ✓ | 4/0.2 | admin auth every request | ✓ | shared job | ✓ | FIXED (warn key) |
| AnalyticsRawRequest | Analytics/AnalyticsRaw | `integer` ×3 | snapshot id | ✓ | Raw config | auth + re-check | ✓ | ✓ | ✓ | PASS |
| AdminCommand | Services/AdminService → Admin/AdminPipeline | `AdminValidate` schema | allowlist | ✓ | 10/3 + per-command | re-authorized every call | online targets only | pcall | ✓ | PASS / RISK (rank cache) |
| AttackLaunch | Services/AttackService *(Q1)* | `userId` + `oneOf` | ✓ | ✓ | limiter + cooldown + server cap | console, shield, target eligible | ✓ | no yield | ✓ | PASS. Late-packet guard reported to Q1 |
| Barrage receipt / prompt | Services/AttackService *(Q1)* | ✓ | ✓ | ✓ | – | console | ✓ | runNoYield | – | **RISK reported to Q1**: a player near the 2000 cap pays for 20 nukes and loses the overflow |
| DefenseUpgrade | Services/DefenseService *(Q1)* | `oneOf` | ✓ | levels clamped | ✓ | feature, cap, cost | ✓ | – | ✓ | PASS |
| ShieldActivate | Services/DefenseService *(Q1)* | none | – | – | ✓ | hitsTaken | ✓ | – | ✓ | **RISK reported to Q1**: the free shield ignores the 48 h cap |

Kid-friendly rule (attack mode never takes anything from the target): **PASS**. The only spend in
Attack/Defense is the player's own upgrade (`trySpendCash`, DefenseService:429). A hit only gives
the attacker minted cash and the target `hitsTaken += 1` (progress toward a free shield).

## Fixes in this pass

| # | Fix | Files | Regression test |
|---|-----|-------|-----------------|
| 1 | `Remotes.onServerEvent` / `fromPresentPlayer`: late packets from departed players are dropped (no state re-created after PlayerRemoving) | `Shared/Net/Remotes` + 20 server files | `tests/remote-security.luau` §1 |
| 2 | Receipt rollback: snapshot before the handler and identity-preserving restore on error, yield or refusal; `recordReceipt` result checked; `onGranted` in a pcall | `Services/MonetizationService`, `Economy/ProfileLogic` (`takeSnapshot` / `restoreSnapshot`) | `tests/remote-security.luau` §2 |
| 3 | Stand names: saved names are re-filtered before being shown again (fail closed to the default name); the feature is re-checked after the filter yield; malformed text no longer costs a rename token | `Tycoon/PlotService` | Studio smoke test (TextService can't run in Lune) |
| 4 | `RebirthShopBuy` refuses when the save is offline (`canMutate`) | `Tycoon/RebirthService` | n/a (service) |
| 5 | `RedeemCode` over-limit replies and analytics throttled to one per 5 s | `Services/CodesService` | n/a (service) |
| 6 | Analytics: limiter `Forget` runs before the no-session early return; the denied-warn key is shared | `Analytics/Sessions`, `Analytics/Reports` | n/a |
| 7 | Lucky Wheel: the request memory is only written for present players (after the policy yield) | `Services/LuckySpinService` | `tests/paid-random-policy.luau` |
| 8 | Malformed-argument fuzz across every pure validator and rule fed raw client data, plus a 4,000-value deterministic random fuzz | — | `tests/remote-security.luau` §3 (4,819 checks) |

Earlier the same day (paid random items, see `docs/pets.md` and `docs/retention.md`): every
Robux-reachable random item is gated by PolicyService and fails closed. That covers eggs (cash and
acorns), crates (gems and held), wheel paid spins, pack spins (paid as gems) and the Turkey Lure.

## Verification

- **Lune:** `tests/remote-security.luau` (4,819 checks) and `tests/paid-random-policy.luau` /
  `tests/pets-policy.luau` (the paid-random gates). Every pets, retention, analytics, profile and
  validate suite passes. Type-check, lint and compile are clean for these files.
- **Studio** (solo playtest, 2026-10-30):
  - The server booted 23/23 features and the client 14/14 controllers with the new
    `Remotes.onServerEvent` wiring.
  - The client sent junk to SetSetting, PadBuy, HatchEgg, OpenCrate, RenameStand, TeleportPlot
    and PromptProduct. NaN, inf, 5,000-character strings, invalid UTF-8 and tables all produced
    zero server errors and no state change.
  - 15 rapid RedeemCode packets got 5 replies (4 within the limit + 1 throttled "Slow down!"),
    where before this fix they got 15.
  - A valid SetSetting still applied.

## Accepted / reported risks

- **ClaimNotifyReward trusts a client-reported opt-in.** Roblox's notification opt-in prompt result
  exists only on the client, so the server cannot verify it. The reward is a one-time 25 gems + 1
  bonus spin, so the worst case is one small free reward per account.
- **Admin group-rank cache** (120 s, or 600 s while the group API fails). A demoted group admin
  keeps rights for up to that long. The owner-UserId path is not cached.
- **Attack/Defense (owner Q1-qa):** Barrage overflow loss (medium), free shield past the cap (low),
  missing late-packet guard (low), a server-wide `MaxNukesInFlight` that one player can saturate
  (low), and a shield toast that is misleading against revenge nukes (info). The exact findings
  and fixes were sent to Q1.
