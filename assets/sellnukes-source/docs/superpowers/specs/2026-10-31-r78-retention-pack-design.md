# R78 — Retention pack (0.6.0) — design spec (2026-10-31)

Owner R78: *"come up with a bunch of more improvements … to make the game more retentive and fun."*
Autonomous decision (CLAUDE.md rule 1). Every system ships with server + full UI + analytics +
admin + Lune tests + docs (rules 5, 6, 9), console / touch / KB-M first (rule 11), kid-friendly (7).

## 0. Why these features (live data, `SellNukesAnalytics_v1` day 2026-10-31, read-only via Studio)

| Signal | Value | Feature that answers it |
|---|---|---|
| Sessions under 2 min | 11 of 26 | §1 Quests goal chip, §3 Rookie Rush, §6 first-minute fix |
| Funnel | joined 20 → first pad 14 → first upgrade 10 → pad 5 = 4 → area 2 = 1 | §1 starter goals bridge tutorial → area 4; §3 Rush halves area-1 time |
| Left before doing anything | 6 of 20 (console 3 of 7) | §6 first-minute console / mobile fix |
| Where players leave | area 1: 22 of 26 | §1, §3 |
| Friends in server | none in 28 of 29 sessions | §4 Friend Boost + invites + referrals |
| Most-opened screens | Rewards 38, Wheel 21, Time 14, Daily 12 | players love claimables → §1 daily missions, §2 Nuke Pass, §5 Index rewards |
| Returning players | 1 (sessNo 2 = 4) | §1 daily missions, §2 Pass, §3 Comeback Rush |

Numbers below are first tunings; every one lives in config and is admin-adjustable where marked.

## 1. Quests — starter goals, daily missions, trophies

One HUD left-column button **Quests** (after Rewards; red badge = claimable quests + claimable
pass tiers). Screen `Quests` with tabs **GOALS · DAILY · TROPHIES** and, at the top, a wide
**NUKE PASS** banner (tier, XP bar, "OPEN") that opens screen `NukePass` (§2). Claims are explicit
(a CLAIM button with the coin-burst juice), never silent, so every reward is a little moment.

### 1.1 Progress events (the contract every system fires)
`Server/Progression/ProgressEvents.luau` (lead, exists before builders start):
`ProgressEvents.progress(player, stat, amount?)` and `ProgressEvents.xp(player, amount, source)`.
Stats (server success paths only, never client claims): `click` (one manual producer cycle),
`pad` (pad bought, any world), `upgrade` (producer levels bought, amount = levels), `manager`,
`area` (new area reached, any world), `hatch` (eggs hatched, amount = count), `crate`, `spin`
(wheel spins), `daily`, `gift` (time gift claimed), `rebirth`, `lucky` (Lucky Button claimed),
`turkey` (Harvest turkey caught), `playMinute` (one minute online, fired by QuestService's own
1-per-60 s tick, not per second), `world` (world unlocked). Firing is one non-yielding line next to
the existing `AnalyticsService` call at each success path.

### 1.2 Starter goals (GOALS tab + the objective chip)
A fixed chain of 12 goals that takes over the bottom-centre objective chip the moment the Nuke Town
tutorial is done (the tutorial keeps the chip until then). The chip shows the goal, a progress bar
and the guide arrow to the right pad / producer where one exists. Goals are **state checks** on the
profile where possible (so veterans see them complete at once and just claim), else counters
started when the chain starts.

| # | Goal | Reward | XP |
|---|---|---|---|
| 1 | Own 5 pads in Nuke Town | 10 gems + 60 s of income | 50 |
| 2 | Workbench level 10 | 1 bonus spin | 50 |
| 3 | Hire your first manager | 2x Cash 5 min | 50 |
| 4 | Own 12 pads | 15 gems | 50 |
| 5 | Spin the Lucky Wheel | 10 gems | 50 |
| 6 | Reach Area 2 | 25 gems + 2x Speed 5 min | 50 |
| 7 | Any producer level 25 | 1 bonus spin | 50 |
| 8 | Hatch an egg | 20 gems | 50 |
| 9 | Claim a daily reward | 10 gems | 50 |
| 10 | Reach Area 3 | 30 gems + 2x Cash 10 min | 50 |
| 11 | Hire 3 managers | 20 gems + 1 bonus spin | 50 |
| 12 | Reach Area 4 | 50 gems + 2 bonus spins | 100 |

After goal 12 the chip shows the first unfinished daily mission (tracked mission), else hides.

### 1.3 Daily missions (DAILY tab)
Three per UTC day, picked on the server with a seeded `Random(userId, day)` from a pool filtered by
progress tier (tier 1 = Nuke Town area ≤ 3, tier 2 = area ≤ 6, tier 3 = beyond or any rebirth).
Pool (target tier1 / tier2 / tier3): click 120/250/400, pad 6/10/15, upgrade 25/60/120,
hatch 2/4/8, spin 2/3/3, gift 2/3/4, playMinute 15/20/30, lucky 1/2/3, turkey 4/8/12 (only while
Harvest Feast is live). No two missions share a stat. Each pays **15 gems + 100 XP**; finishing all
three unlocks the **Daily Chest**: 25 gems + 1 bonus spin + 150 XP. **One free reroll per day**
swaps one unfinished mission (server picks a stat not already shown). Resets at 00:00 UTC with a
visible countdown.

### 1.4 Trophies (TROPHIES tab)
Lifetime tiered counters (counted from 0.6.0; state-derived ones read the profile so they back-fill):

| Trophy | Tiers | Source |
|---|---|---|
| Clicker | 100 / 1K / 10K / 50K / 250K | `click` |
| Builder | 25 / 100 / 300 / 750 / 2K | `pad` |
| Upgrader | 100 / 1K / 5K / 20K / 100K | `upgrade` |
| Hatcher | 5 / 25 / 100 / 500 / 2K | `hatch` |
| Collector | 5 / 15 / 30 / 50 / all | pets in the Index (state) |
| Explorer | 2 / 3 worlds | worlds unlocked (state) |
| Reborn | 1 / 3 / 10 / 25 / 50 | rebirths, all worlds (state) |
| Loyal | 3 / 7 / 14 / 30 / 60 | daily claims |
| Time Traveller | 60 / 300 / 1.2K / 3K / 6K minutes | `playMinute` |

Tier rewards: 10 / 25 / 50 / 100 / 200 gems, 75 XP each.

### 1.5 Data, server, client
`profile.quests = { starter = {step, base = {[stat]=n}, claimed = {[i]=true}}, daily = {day, picks
= {stat,target,progress,claimed}[], chest, rerolled}, life = {[stat]=n}, trophies = {[id]=tier} }`.
`QuestConfig` (shared, pure rules usable by the client preview), `Server/Quests/QuestLogic` (pure,
Lune-tested), `Server/Services/QuestService` (subscribes to `ProgressEvents.Progress`, remotes
`QuestClaim(kind, id)`, `QuestReroll(slot)`, deltas pushed via the profile sync), rewards via
`Server/Retention/RewardLogic.apply` / `RewardGrant` (same reward shape as Daily: gems, spins
(bonus bank), cashSeconds + floor, boost), XP via `ProgressEvents.xp`. Client: `Client/Quests/*`,
`UI/Screens/Quests/*`. Analytics family keys `quest:*` (starter step done / claimed, daily picked /
done / chest / reroll per stat, trophy tier). Admin: complete current starter goal, reset today's
missions, set a trophy counter (audited).

## 2. Nuke Pass — Season 1 "Harvest Season"

Window **2026-11-01 00:00 → 2026-12-01 00:00 UTC** (same instants as Harvest Feast). 30 tiers,
**400 XP per tier** (12,000 XP). XP: §1 (starter 50–100, daily 100 ×3 + chest 150, trophy 75) +
**10 XP per 5 online minutes** (cap 360 XP per UTC day). A 30-min-a-day player ≈ 510 XP/day →
tier 30 in ~24 days; a 3-days-a-week player ≈ tier 15. After tier 30, every further 800 XP = a
bonus chest (20 gems), repeatable.

- **Free track** (every tier): gems 10–40, bonus spins, 15-min boosts, income cash, eggs,
  tier 30 = title **SEASON 1**.
- **Premium track** (every tier, dev product **Nuke Pass Premium**, 199 R$, per season, idempotent
  receipt ledger): roughly double the free value + eggs; tier 10 exclusive trail **Harvest Glow**;
  tier 20 exclusive title **NUKE PASS**; tier 30 exclusive pet **Golden Nukey** (§5). Buying late
  unlocks every premium tier already reached. The server refuses the prompt outside a season.
- Claim per tier + **CLAIM ALL**. When the season ends, reached-but-unclaimed rewards are granted
  automatically on the next join (nothing is lost). Between seasons the screen reads "Season 2 is
  coming soon".
- Screen `NukePass`: horizontal two-row track (free / premium) with a gamepad-scrollable tier
  strip, XP bar, countdown, premium CTA (price from `PriceBook`). HUD right-column offer row
  **Pass** while not premium during a season.
- `profile.pass = { season, xp, dayXp, day, claimedFree = {[tier]=true}, claimedPremium = {...},
  premium = {[seasonId]=true}, overflow }`. `PassConfig`, `Server/Pass/PassLogic` (pure, tested),
  `Server/Services/PassService` (subscribes to `ProgressEvents.Xp`; remotes `PassClaim(track,
  tier)`, `PassClaimAll()`). Analytics `pass:*` (xp by source, tier reached, claims, premium funnel
  through the existing purchase-funnel recorders). Admin: grant XP, set tier (Studio / owner,
  audited).

## 3. Rush boosts (new + lapsed players)

- **Rookie Rush:** brand-new profiles get **2x Cash for their first 15 minutes online** (counted
  only while online, survives rejoin). Profiles that existed before 0.6.0 do not get it.
- **Comeback Rush:** on join, if the server-saved last-seen time is **≥ 48 h** ago, **2x Cash for
  10 minutes**, shown on the Welcome Back screen ("COMEBACK RUSH!").
- New modifier field `rushCash` (TycoonTypes.Modifiers, merged multiplicatively, `offline = false`,
  so Rush never inflates offline earnings or reward cash). A HUD boost chip shows "ROOKIE RUSH 2x
  12:41". Admin: toggle, set minutes, grant / clear for a player.

## 4. Friends — Friend Boost, invites, referrals

- **Friend Boost:** +10 % cash per Roblox friend in the same server, max +50 %
  (`friendCash`, multiplicative, `offline = false`). Friendship via `Player:IsFriendsWith` in a
  background task on join, cached per pair, recomputed on join / leave. HUD chip "FRIENDS +20 %";
  toast "Your friend X joined: +10 % cash!".
- **Invite:** a Rewards-hub tile **Friends** opens screen `Friends` (boost status, INVITE button →
  `SocialService:PromptGameInvite` with an `ExperienceInviteOptions` message, referral progress).
- **Referral rewards:** a brand-new profile whose `Player:GetJoinData().ReferredByPlayerId` is set
  gets **50 gems + 2x Cash 15 min**; the inviter gets **100 gems + 1 bonus spin** per new friend,
  max **10 lifetime**. Paid at once if the inviter is in the same server, else queued in DataStore
  `SellNukesReferrals_v1` (UpdateAsync, deduped by newcomer userId, list capped) and paid on the
  inviter's next join. Studio never writes the live store (`_Studio` suffix).
- `profile.rush = { rookieLeft, comebackUntil }`, `profile.referral = { by, paid = n, seen = {} }`.

## 5. Pet Index rewards + Golden Nukey

- **Index milestones** at **5 / 10 / 20 / 30 / 45 / 60 / all** pets discovered: gems (25 / 40 / 60
  / 80 / 120 / 160 / 300) plus a permanent **Index Bonus** of +2 / +2 / +3 / +3 / +5 / +5 / +10 %
  cash (cumulative +30 %, added to `petCash`). Claimed in the Pets screen's Index tab (milestone
  bar + CLAIM). Exclusive pets count toward "all" only if the player owns them (the bar's total is
  the non-exclusive count).
- **Golden Nukey** (`golden_nukey`): a golden, sparkly chibi of the lobby's Nukey mascot. Built in
  Blender (`tools/blender/models/`), uploaded, MeshPart; exclusive (no egg), source "Nuke Pass
  Season 1"; strength like the best Mythic of Nuke Town. Index entry says how to get it.

## 6. First-minute fix (console / mobile)

Audit the first 60 s on console, phone and tablet: what opens at join (Welcome / What's New /
notify / offers), whether any screen grabs `GuiService.SelectedObject` and traps movement, B / Back
closing, the tutorial arrow and its glyph, spawn-to-plot path, loading time. Fix every problem
found. Add finer FTUE steps so the next data shows exactly where people stall: `firstMove`
(character moved 12 studs), `tutorialSeen`, `firstScreenClosed`. Verify with
`capture_device_matrix`.

## 7. Release glue (lead)
0.6.0 `VersionConfig` + WHAT'S NEW note; code **QUESTS** (40 gems + 1 bonus spin, one per player);
docs; `SELLNUKES_CLAUDE_DOCUMENTATION.md`; one integrated `./scripts/check.sh` then commit.

## 8. Ownership (one writer per file; shared tables get small additive in-place edits only)

| Owner | Files |
|---|---|
| lead | this spec, `Server/Progression/ProgressEvents`, `VersionConfig`, `ChangeNotesConfig`, `CodesConfig`, `SELLNUKES_CLAUDE_DOCUMENTATION.md`, `docs/owner-requests.md`, commits |
| Q-quests | `QuestConfig`, `Server/Quests/*`, `QuestService`, `Client/Quests/*`, `UI/Screens/Quests/*`, `UI/Hud/HudObjective` (post-tutorial goal chip), the one-line `ProgressEvents` fires in other services, `tests/quest-logic.luau`, `docs/quests.md` |
| P-pass | `PassConfig`, `Server/Pass/*`, `PassService`, `UI/Screens/NukePass/*`, `MonetizationConfig` + `PublishedProductIds` row, the Harvest Glow trail row (`CrateConfig`), title rows (`PlayerTitlesConfig`), `tests/pass-logic.luau`, `docs/nuke-pass.md` |
| R-social | `rushCash` / `friendCash` modifier plumbing (`TycoonTypes`, `TycoonRules`, `Modifiers`, `TycoonLogic`), `RushService`, `FriendService`, `UI/Screens/Friends/*`, HUD boost chips, Welcome Back line, `RewardsHubConfig` tile, `tests/social-logic.luau`, `docs/social.md` |
| A-pets | `tools/blender/models/pet_golden_nukey.py` (or the pets builder), mesh upload, `PetConfig` rows, Index milestones (`PetService` provider + claim, `UI/Screens/Pets` Index tab), `tests/pet-index.luau`, `docs/pets.md` section |
| C-ftue | first-minute audit + fixes (`Client/Tycoon/Tutorial*`, join-time screen rules, platform glue), new FTUE steps, `docs/verification/r78-ftue/` |

Shared tables every builder may touch additively (re-read just before editing, small unique
anchors, never rewrite the file): `Shared/Net/Remotes`, `Validate`, `Economy/ProfileLogic`
(defaults + sanitize for your own field), `AnalyticsConfig`, `AdminConfig`, `HudZonesConfig`,
`IconAssets`, `init.server.luau` / `init.client.luau` (one boot line each). Builders never commit;
the lead commits after an integrated check. Studio playtests only while holding
`scripts/studio-lock.py`; solo playtests only (R72).

## 9. Owner actions after delivery
Publish 0.6.0 with "Migrate to Latest Update". Post the code QUESTS in Discord. (The Nuke Pass
Premium dev product is created through the Studio MCP during the build.)
