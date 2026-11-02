# Rush boosts + Friends (owner R78)

> R78: *"come up with a bunch of more improvements … to make the game more retentive and fun."*

Design spec: `docs/superpowers/specs/2026-10-31-r78-retention-pack-design.md` §3 (Rush) and §4
(Friends). Owner of every file below: R-social. Live data that motivated it (spec §0): 11 of 26
sessions ended under 2 minutes, 22 of 26 left in area 1, one returning player, and 28 of 29
sessions had no friend in the server.

## What the player sees

| Feature | Who | What | Where it shows |
|---|---|---|---|
| **Rookie Rush** | Brand-new profiles (0.6.0+) | 2x Cash for their first **15 minutes online** (it only counts down while playing, and a rejoin continues the timer) | HUD boost badge on the cash (`2x` / `12:41`; breakdown row `ROOKIE RUSH 2x 12:41`) |
| **Comeback Rush** | A join whose previous save is **≥ 48 h** old | 2x Cash for **10 minutes** (wall clock) | Welcome Back banner `COMEBACK RUSH! 2x CASH for 10 min` + HUD boost badge (breakdown row `COMEBACK 2x 8:02`) |
| **Friend Boost** | Everyone | **+10 % cash per Roblox friend** in the same server, at most **+50 %** | HUD boost badge (`+20%` alone, else part of the combined number; breakdown row `FRIENDS +20%`), toast `Your friend X joined: +10% cash!`, Friends window, Rewards hub tile line |
| **Invite friends** | Everyone | The Friends window's big INVITE FRIENDS button opens Roblox's invite prompt; since R122 also the HUD **INVITE** button and the once-per-session invite moment (see *Co-play surfaces*) | Rewards hub → **Friends** tile, HUD top-right, bottom-left feed card |
| **Referral rewards** | A brand-new profile joining through an invite / share link, and its inviter | Newcomer: **50 Gems + 2x Cash 15 min**. Inviter: **100 Gems + 1 bonus spin** per new friend, max **10 ever** | Toasts; the Friends window's `3 / 10` bar |

Rookie and Comeback never stack: the larger multiplier applies (Rookie on a tie). A comeback is
not granted while a Rookie Rush still covers the whole comeback window.

All rush / friend cash is income only: both modifiers are registered with `offline = false`, so
they never inflate offline earnings, and reward cash (RewardLogic, which scales with permanent
income only) never reads them.

## Files

| File | Role |
|---|---|
| `src/shared/Config/SocialConfig.luau` | Every tunable (minutes, multipliers, 48 h, percents, caps, rewards, DataStore names, attribute names, chip look, texts), `live()` admin overrides, the saved-record helpers `newRush / reconcileRush / newReferral / reconcileReferral`, `times()` |
| `src/server/Social/RushLogic.luau` | PURE: `grantRookie`, `awaySeconds`, `comebackDue`, `grantComeback`, `sessionEndsAt`, `consume`, `multiplier` (no stacking + validUntil) |
| `src/server/Social/FriendLogic.luau` | PURE: `pairKey`, `percent`, `multiplier`, `friendsOf`, `referrerOf`, `newcomerVerdict`, `payInviter`, `readQueue / enqueue / dequeue`, `recordUserIds` |
| `src/server/Services/RushService.luau` | Rookie grant (ProfileLoaded isNew + saving session), comeback check (previous `offline.lastSeenAt`), online-only countdown (one loop every 2 s, push every 30 s), `rush` modifier provider, admin |
| `src/server/Services/FriendService.luau` | IsFriendsWithAsync pair cache, Friend Boost recompute + toasts, `friendBoost` provider, `FriendInvite` analytics remote, referrals (newcomer reward, inviter pay / DataStore queue / consume), admin |
| `src/client/Social/SocialClient.luau` | Client state: rush timers from the profile, Friend Boost from `Social`, the comeback announcement, referral progress, the SocialService invite prompt |
| `src/client/Social/BoostChipLogic.luau` | PURE: which boosts are active, each one's multiplier, the R82 badge (combined number, timer pick, friends-only text, size, digit-safe tilted gap), breakdown row times |
| `src/client/UI/Screens/BoostChips/BoostChipsScreen.luau` | The R82 HUD boost badge on the cash counter's corner + its breakdown card (every active income boost: rush, 2x Cash, 2x Speed, Server 2x, Friends) |
| `src/client/UI/Hud/HudCurrency.luau` (R82 part) | The `BoostCorner` anchor on the visible primary counter's number, `HudCurrency.corner()` / `navExits()` / `Changed`, handle `linkNav` (called by Hud.relayout) |
| `src/client/UI/Screens/Friends/init.luau` | The Friends window (Friend Boost card, INVITE FRIENDS, invite rewards card) |
| `src/client/UI/Screens/WelcomeBack/init.luau` | Comeback banner + the rush-only Welcome Back (no payout) |
| `tests/social-logic.luau` | Lune: config, rush countdown + rejoin, comeback edges, modifier merge + sanitise + offline exclusion, friend %, referral rules, queue idempotency, profile shapes, chips, hub tile |

Shared-table edits (additive): `TycoonTypes.Modifiers` (`rushCash`, `friendCash`),
`TycoonRules.mergeModifiers`, `Modifiers.resolve`, `ProfileLogic` (`rush`, `referral`: defaults,
reconcile, snapshot), `Remotes` (`Social`, `FriendInvite`), `AnalyticsConfig` (keys, `Friends`
screen id, `referral` transaction type), `RewardsHubConfig` (Friends tile), `UI/RewardsBadges`
(Friends tile state), `Widgets/HudZones` (`Boosts` zone; unpublished since R82), `Hud/Toasts` (stack below the chips when that zone is set),
boot lines in `init.server.luau` / `init.client.luau`, `tests/{profile-logic, validate, rewards-hub}`.

## Server flow

### Rookie Rush (RushService)

1. `ProfileLoaded(player, profile, isNew)` is connected in **Init**, so it runs before
   OfflineService (connected in its Start) re-stamps `offline.lastSeenAt`.
2. `isNew` and `PlayerDataService.canMutate(player)` (a saving session, never an existing player's
   in-memory fallback) → `profile.rush.rookieLeft = RookieMinutes * 60`. Pre-0.6.0 saves have no
   `rush` record, reconcile to 0, and are never `isNew` — so they never get it. A New Player Mode
   sandbox is brand-new, so an admin sees the real first minute.
3. The saved seconds become a session end time (`sessionEndsAt`). The one loop
   (`Rush.TickSeconds` = 2 s) writes the rest back every `SyncSeconds` (30 s) and pushes `rush`;
   ProfileReleasing / PlayerRemoving / ProfileUnloading (New Player Mode swap) write the final
   value. Offline time never counts.
4. Kill switch OFF pauses the clock (the rest is kept) and neutralises the multiplier. A newcomer
   who joins while it is OFF is still granted (they get it when it is back on).

### Comeback Rush (RushService)

On a JOIN (`getLoadReason == "join"`, never a New Player Mode swap) of a stored profile:
`RushLogic.comebackDue(rush, lastSeenAt, now, 48, comebackSeconds)` → `comebackUntil = now + 600`.
Then (deferred, after OfflineService's `OfflineEarnings` of the same join) the client gets
`Social { kind = "comeback", away, seconds, multiplier }`.

### Income

`ModifierSources.register("rush", provider, { offline = false })` → `{ rushCash = 2 }` with
`validUntil` = the soonest rush end (the tycoon recomputes exactly then).
`ModifierSources.register("friendBoost", provider, { offline = false })` →
`{ friendCash = 1 + percent / 100 }`. `TycoonRules.mergeModifiers` multiplies each across sources;
`Modifiers.resolve` sanitises each (`SafeMath.bonus`: NaN / inf / ≤ 1 → 1; clamped to
`Rush.MaxMultiplier` 10 and `Friends.MaxMultiplier` 2) and multiplies them last, so a neutral value
is bit-identical to the pre-R78 maths.

### Friend Boost (FriendService)

On every PlayerAdded a background task checks each pair with the players already here through
`Player:IsFriendsWithAsync` (pcall, 3 attempts, 2 s / 6 s backoff). One answer is cached per
unordered pair (`"small:large"`), so both directions share it. A pair is cached only while BOTH
players are still present (departed-player race), and PlayerRemoving drops every pair of the
leaver and re-computes the players who counted them. Each change invalidates that player's
modifiers and pushes `Social { kind = "friends", count, percent, names }`. Toasts: the player who
was there first gets `Your friend X joined: +10% cash!`; the joiner gets one summary
`Friends here: +20% cash!` (or a fresh one if a pair resolves after their summary).

### Invites

The prompt must run on the client: `SocialClient.invite()` → `SocialService:CanSendGameInviteAsync`
→ `SocialService:PromptGameInvite(player, ExperienceInviteOptions { PromptMessage })` →
`GameInvitePromptClosed(sender, recipientIds)`. Each outcome goes to `FriendInvite(action,
recipients?)` (allowlisted action, recipients clamped 1..50, RateLimiter 4 burst / 0.2 per s) —
analytics only, nothing is granted from it.

### Referrals

| Step | Rule |
|---|---|
| Newcomer verdict | `FriendLogic.newcomerVerdict`: a whole `GetJoinData().ReferredByPlayerId` that is not the player (`self`), a real join (`swap` for New Player Mode), `isNew` (`notNew`), a saving session (`unsaved`), never referred before (`already`) |
| Newcomer reward | `profile.referral.by = inviterId` + `RewardGrant.grant(Referral.NewcomerReward, "referral")` (50 Gems + BoostConfig `cash2x` 900 s through the existing boost path) + toast |
| Inviter here | Profile loaded, saving, not a sandbox → `FriendLogic.payInviter` (idempotent per newcomer id in `referral.seen`, capped at 10) + `RewardGrant.grant(InviterReward)` (100 Gems + 1 FREE bonus spin) + toast `(n / 10)` |
| Inviter elsewhere | `UpdateAsync` on DataStore `SellNukesReferrals_v1` (`…_Studio` in Studio: a playtest never writes the live store), key `Inviter_<id>`, record `{ v = 1, list = { { id, at } } }`: deduped by newcomer id, ≤ 20 entries, entries older than 180 days dropped, GDPR user ids (inviter + newcomers) on the key; 4 attempts with 2 / 6 / 18 s backoff and a DataStore-budget wait. If the inviter turns out to be here after the write, their queue is consumed at once |
| Inviter's next join | `GetAsync` → pay every entry in ONE non-yielding pass → `markChanged` + `ProfileStore:commitAsync` → only then `UpdateAsync` removes the handled ids (others appended meanwhile stay). A crash in between re-reads the queue and `seen` stops a second payment: **exactly once** |

## Data

```
profile.rush     = { rookieLeft = 0, comebackUntil = 0 }        -- SocialConfig.newRush / reconcileRush
profile.referral = { by = 0, paid = 0, seen = {} }              -- SocialConfig.newReferral / reconcileReferral
snapshot.rush     = { rookieLeft, comebackUntil }               -- pushed on change + every 30 s while rookie runs
snapshot.referral = { paid, invited }                           -- other players' UserIds stay server-side
```

## Remotes

| Remote | Direction | Payload | Checks |
|---|---|---|---|
| `Social` | S→C (owner only) | `{ kind = "friends", count, percent, names }` / `{ kind = "comeback", away, seconds, multiplier }` | Client validates every field (whole count 0..7, percent 0..50, ≤ 7 names ≤ 80 bytes valid UTF-8; finite bounded comeback numbers) |
| `FriendInvite` | C→S | `(action, recipients?)` | `Validate.oneOf` against `Invite.Actions`, `Validate.integer(1, 50)`, RateLimiter, departed-player guard (`Remotes.onServerEvent`); analytics only |

## Client

- **SocialClient** keeps rush timers in server time: `rookieEndsAt = serverNow + rookieLeft` at
  each `rush` push, `comebackEndsAt = comebackUntil`.
- **Boost badge** (owner R82, replaced the R78 chip row; `BoostChipsScreen`, non-modal, display
  order 6): see **Boost badge (R82)** below.
- **Friends window** (`ScreenManager` name `Friends`, 1040 × 600): Friend Boost card (big
  `+20% CASH`, five pips, friend names), INVITE FRIENDS (gamepad default selection; Up → X;
  B closes), invite rewards card (`3 / 10`, progress bar, what each side gets, "You joined through a
  friend's invite!"). Status line shows the invite outcome.
- **Rewards hub tile** `Friends` (sky): never badges (referral rewards pay themselves); line
  `+20% cash!` or `Invite friends!` (RewardsBadges `boost` / `invite`).
- **Welcome Back**: the comeback request uses the same JoinFlow key as the payout and opens with a
  queued payout, so neither drops the other. With a payout: the normal window + banner (line and
  well shrink a little). Without: "You were away for 3d 4h!", a big `2x CASH`, banner, one centred
  LET'S GO!.

## Boost badge (R82)

> R82: *"the two x cash UI can kind of be like a corner piece for the cash instead of it being like
> its own little pill on the bottom."*

**Look.** A small stud sticker, tilted 8° clockwise, pinned to the top-right corner of the visible
primary counter: big text = the combined multiplier, small text = a timer. 2+ boosts: a second
sticker in the next boost's colour peeks out behind it (tilted -5°, offset 6 px). It pops (x1.22)
when it appears or its number changes (no pop with Reduce Motion).

**Decisions (B-boost, owner rule 1: decided and documented here).**

| Question | Decision |
|---|---|
| What the big number means | Every active boost multiplied: Rush x 2x Cash x 2x Speed x Server 2x x Friend Boost. 2x Speed counts because every producer cycles twice as fast, so money really comes in twice as fast. Rounded DOWN to one decimal (`2.4x`, never more than the player gets). |
| Several timers | The badge shows ONE timer: the boost that ends first (that is when the number next drops). The full list is in the breakdown. No cycling: a timer that jumps around reads like a glitch to kids. |
| Friend Boost (no timer) | Lives in the badge, with no separate indicator: it is part of the number and a breakdown row. Alone it reads `+20%` / `FRIENDS` (clearer than `1.2x`). |
| Colour | The colour of the boost whose timer shows (Rookie orange, Comeback red, 2x Cash green, 2x Speed sky, Server purple, Friends blue). |
| Where it hangs | Inside UI/Hud/HudCurrency's `BoostCorner`: a zero-size frame on the number label's top-right corner, positioned by SCALE `(1, 0)`. The engine keeps it on the digits' right end at any width ("608.05Sx", "1.23Dc") with no script work, and a scale-positioned zero-size child does not feed the label's AutomaticSize (probed in Studio 2026-10-31: label 216.5 px with or without it, and it shrinks back for "$5"). In another world the anchor moves to that world's counter (boosts multiply every world's income). |
| Never covering the digits | The sticker starts `BoostChipLogic.cornerGap(w, h, 8°, air + strokes)` px right of the number's box: 3 px air + the number's TextOutline + the sticker's 3 px edge (both x max(1, 1/UI scale), so they are covered whether or not the engine scales strokes) + the tilted corner's overhang `h/2·sin - w/2·(1 - cos)`. Lune proves every rotated corner stays clear. Pop / hover scale grows from the top-left, so the left edge never moves towards the digits. |
| Visibility | It is inside the HUD's ScreenGui, so it shows exactly when the counter shows: loading, hatch, attack aim and the launch cinematic hide it with the HUD. It steps aside while the plot reveal banner is open (`SocialConfig.Client.HiddenWhileOpen`). While a menu is open it stays visible with the currency (owner R79 keeps the currency up) but is not selectable or tappable. |
| HudZones `Boosts` | No longer published. The badge sits in the `Top` zone's height band (desktop: y 58..126 vs Top 8..174), so Toasts (STACK_TOP 200) and the tutorial card (under `Top`) keep their positions. The zone name stays in the type so existing readers compile. |

**Breakdown.** Tapping or clicking the badge, or selecting it with a gamepad, opens a blue stud
card under it, in this screen's own ScreenGui above the HUD: `BOOSTS  TOTAL 9.6x`, then one row per
boost (icon, name, time left in the boost's accent colour). The card is display-only (`Active =
false` everywhere), so there is no invisible full-screen catcher over the thumbstick. A tap or click
anywhere else closes it (UserInputService press: a world press closes at once; a GUI press is
compared with the badge's own InputBegan, deferred). So do the badge again, gamepad B (Deselect
drops the selection), a modal opening, the HUD hiding, or 8 s without the gamepad cursor on the
badge. Opening it reports `open:Boosts` (ClientAnalytics, source `hud`; `Boosts` is in
`AnalyticsConfig.ClientFunnel.Screens`).

**Console / mobile.**

| Device | What applies |
|---|---|
| Every device | The hit area is at least 44 pt (TouchUIConfig.MinTapPoints) and grows only right / down of the sticker. |
| Phones / tablets | Text floors: badge timer 14 pt, multiplier 18 pt, breakdown 14 pt. The breakdown grows with its text. |
| Gamepad | Hud.relayout calls `currency.linkNav(left.topRight(), right.first())`, and the badge joins the D-pad graph: Up from the left grid's top-right button reaches it (that button's own Up link is restored when the badge hides); from the badge, Left goes to that button and Right / Down go to the first offer. The white ring shows selection, selecting opens the breakdown, and B leaves. |
| Placement | Top-centre, right of the number: clear of Roblox's top-bar buttons (QA checks `GuiService.TopbarInset`) and of the thumbstick / jump zones. |

**Performance.** Event-driven refresh (profile `boosts` / `rush`, SocialClient, the
ServerBoostEndsAt attribute, ScreenManager open / close / focus / layout / safe area, HudCurrency
`Changed`), coalesced per frame. There is ONE 1 Hz tick, and only while a timed boost is active: it
updates the badge timer and the open card's times and position. Every Instance and Tween is built
once and breakdown rows are pooled. Nothing runs per frame: the badge follows the number through
the engine's layout.

**Config.** `SocialConfig.Client.Badge*` / `Breakdown*` (sizes, floors, tilt, air, edge, pop,
card) and `SocialConfig.Text.{BadgeNoTimer, BreakdownTitle, BreakdownTotal}`. The R78 chip-row
keys were removed.

**Verify.** Lune: `tests/social-logic.luau` section 6 (badge maths). Studio (solo playtest, Studio
lock):

```
STUDIO_LOCK_OWNER=B-boost python3 tools/qa/boost_badge.py
```

It covers 2x Cash 1:25, then stacked 9.6x, then the breakdown, then the width probe ("$0" /
"$608.05Sx" / "$888.88Dc", display only), each per device. It uses
`tools/qa/boost_badge_{server,client}.luau`. Captures: `docs/verification/r82-*`.

## Analytics

Retention family: `rush:grant:<rookie|comeback>`, `rush:sec:<rookie|comeback>` (boosted seconds
played per session), `rush:done:<rookie|comeback>` (ran out while playing), `rush:awayDays:<2-31>`.
Social family: `friends:boost:<0-5>` (friends found at join), `friends:pair`, `friends:checkFail`,
`friends:invite:<prompted|sent|closed|unavailable|failed>`, `friends:inviteTo` (recipients),
`friends:ref:<new|paid|queued|duplicate|full|capped|seen|self|notNew|queueFail|delivered>`.
Economy: referral gems as `earn:gems:referral` (transaction type Gameplay). Screens:
`open:Friends`, `openFrom:Friends:hub`.

## Admin (owner panel)

| Tab | Command | What |
|---|---|---|
| Server | RushToggle | Kill switch `SocialRushEnabled` (OFF = neutral, Rookie clock paused) |
| Server | RushMinutes | Minutes of NEW rookie / comeback grants (`SocialRookieMinutes` / `SocialComebackMinutes`, 1..120) |
| Players | RushGrant | Give a player a rookie (online minutes) or comeback (wall clock) rush, replacing theirs |
| Players | RushClear | Remove both rushes |
| Players | RushStatus | Read-only: multiplier, rookie left (running / paused), comeback left, server settings |
| Server | FriendBoostToggle | Kill switch `SocialFriendsEnabled` |
| Server | FriendBoostPercent | Percent per friend (`SocialFriendPercent`, 1..25; total still capped at +50 %) |
| Server | FriendStatus | Read-only: pairs found, every boost |
| Players | ReferralStatus | Read-only: inviter id, rewards n / 10, ledger size, last queue read |
| Players | ReferralTest (Studio only) | Run the flow on a player: as newcomer of an id / pay as inviter for an id / read their queue |

Every changing command is audited. Settings are per server and not saved.

## Verification

- Lune: `tests/social-logic.luau` (166 checks) + `tests/{profile-logic, validate, rewards-hub,
  tycoon-logic, tycoon-server-logic}` updated for the new fields / remotes / tile.
- Studio (solo playtest, owner R72): `STUDIO_LOCK_OWNER=R-social python3 tools/qa/social.py`
  (`tools/qa/social_{server,client}.luau`). Verified 2026-10-31: the saved Studio profile gets NO
  Rookie Rush; New Player Mode (a brand-new sandbox) gets 900 s at 2x, `rushCash` 2 online and 1
  offline; chips `ROOKIE RUSH 2x 14:29` + `FRIENDS +20%` (friend state pushed display-only — a
  solo test has no second Roblox friend), compact `2x 14:25` / `+20%` on phones; rush-only and
  payout Welcome Back with the banner; Friends window + hub tile; admin RushStatus / RushToggle
  (off = rushCash 1, on = 2) / FriendBoostPercent / FriendStatus / ReferralStatus / RushMinutes;
  the referral queue on `SellNukesReferrals_v1_Studio`: enqueue → consume pays +100 Gems + 1 spin
  once and empties the queue → a replay of the same newcomer pays nothing.
  Captures (desktop / phone / tablet / console): `docs/verification/r78-social/`.

## Co-play surfaces (owner R122)

> R122: *"maximize the game … the standards of like Roblox algorithm pool."* Spec
> `docs/superpowers/specs/2026-11-01-r122-algorithm-pack-design.md` §2.4. Builder: W-R122-social.

**Why.** Roblox ranks *intentional co-play days* (join / invite / private server). 252 of 266
sessions on 10-31 had no friend in the server, the Friends window (inside the Rewards hub) was
opened once in two days and Friend Boost found 0 friends in 144 of 145 joins. Inviting is now one
press away on the HUD, plus one gentle reminder per session.

| Surface | What the player sees | Rules |
|---|---|---|
| **HUD INVITE button** | Small blue stud button `[handshake] INVITE` in the top-right corner (left of the admin chip; the offers start below it) with a tilted yellow **`+10%`** sticker = the LIVE Friend Boost percent per friend (admin `FriendBoostPercent` changes it at once; hidden while `FriendBoostToggle` is off). The key / pad glyph sits on its left. | Opens Roblox's invite prompt directly (`SocialClient.invite`, the R78 flow; referrals ride Roblox's own invite join data). **Hidden while invites are unavailable** (`SocialService:CanSendGameInviteAsync` false / unknown: asked at start with 3 attempts, re-asked every 15 min and whenever the flow reports `unavailable`). In the HUD's MenuLayer, so it fades with the side columns behind a menu (R79). |
| **Invite moment** | One small non-modal card at the bottom of the bottom-left feed: `PLAY WITH FRIENDS!` / `Every friend here gives you +10% cash!` / `[B] LATER` `[X] INVITE`. | **Once per session**, after area 2 is unlocked (or the player rebirthed): 90 s after an unlock during this session, never earlier than 180 s into the session. Never while a friend is already here, during a tutorial step, or while invites are unavailable (then it re-tries every 60 s). PopupQueue kind `inviteMoment` (centre lane, priority 30 = below every other moment, waits ≤ 60 s, never over a menu / cinematic, a more important moment ends it). Closes itself after 14 s (counts neither INVITE nor LATER). |

**Input (owner R11).** HUD button: tap / click, keyboard **P**, gamepad **L3** (bound only while it
shows and no menu is open; P / L3 collide with no PlatformConfig action — tests prove it), and the
D-pad cursor (Down → the first offer, Right ↔ the admin chip). Touch devices grow it to the 44 pt
tap; phones use the narrower `PhoneWidth`, labels and the sticker ≥ 14 pt. Moment card: INVITE =
tap / click, gamepad **X** / keyboard **E** bound **below** every gameplay action (a pad / producer
press on the same key always wins); LATER = tap / click, gamepad **B**, keyboard **X / Backspace**
(High priority, only while it shows). Nothing on the card is Selectable: the gamepad cursor is never
stolen. A press that began before the card appeared never answers it (`UI/PurchaseGuard` arm rule).
Text ≥ 14 pt and buttons ≥ 44 pt at any fit (`Widgets/FeedCardMetrics`).

**Placement.** `HudPlacement.inviteRect` (pure): on the admin chip's row, left of it, under the
top bar; on a canvas too narrow for that row it stacks under the chip. HudZones `"TopRight"` = the
union of the admin chip and the INVITE button (toasts, the Lucky arrow, the Happy Hours pill and
the New Player Mode chip keep clear of both). `tests/hud-cluster.luau` runs every device of its
matrix with and without the button (on screen, no overlap with grid / offers / currency / objective
/ WHAT'S NEW / admin chip / MORE flyout, ≥ 44 pt, clear of the thumbs, phones keep ≥ 60 % free).

**Analytics (social family).** `friends:hud:shown` (first time the button shows this session),
`friends:hud:tap`, `friends:moment:<shown|invite|later>`. Reported on the existing `FriendInvite`
remote (`InviteConfig.Reports` allowlist, its own rate limit 6 burst / 0.5 per s, per-session caps:
every `…:shown` once, `hud:tap` 30, the rest once — `InviteConfig.reportAllowed`). The prompt's own
outcome keeps counting `friends:invite:<prompted|sent|closed|unavailable|failed>`, so the funnel is
`hud:shown → hud:tap → invite:prompted → invite:sent` and `moment:shown → moment:invite → …`.

**Files.**

| File | Role |
|---|---|
| `src/shared/Config/InviteConfig.luau` | HUD button look + keys, moment timing / card look / keys, availability checks, report allowlist + caps (`reportAllowed`, pure) |
| `src/client/Social/InviteLogic.luau` | PURE: `available`, `badgeText`, `newMoment / noteProgress / momentDueAt / momentGate / markShown` |
| `src/client/Social/InviteClient.luau` | Runtime: availability cache + `Changed`, `invite(surface)`, `report(action)`, the moment scheduler (one delayed task, PopupQueue request, retries) |
| `src/client/UI/Hud/HudInvite.luau` | The HUD button (stud button, sticker, glyph, P / L3 binding, `friends:hud:shown`) |
| `src/client/UI/Screens/InviteMoment/init.luau` | The moment card (feed placement, X / E + B bindings, auto-close) |
| `src/client/UI/Widgets/{ActionCard, FeedCardMetrics}.luau` | The shared small card (also the DEAL card) + its pure sizing |
| `src/client/UI/Widgets/HudPlacement.luau` | `inviteRect` + the `invite` input / rect |
| `src/client/UI/Hud/Hud.luau` | Builds HudInvite in the MenuLayer, places it, D-pad links, the `TopRight` union |
| `src/server/Services/FriendService.luau` | `onSurfaceReport`: allowlist, own limiter, per-session caps → `friends:<report>` |
| `src/shared/Config/PopupQueueConfig.luau` | Kind `inviteMoment` |
| `tests/invite-surface.luau` | Lune: config vs analytics keys, binding collisions, availability, sticker, moment timing / gates / once per session, report caps under a forged flood |

**Studio QA (lead's pass; Studio only).** LocalPlayer attribute `DevInviteAvailable = true` forces
the button on (Studio may refuse `CanSendGameInviteAsync`); `DevInviteMoment = true` shows the moment
card now (skips the timing / friends / tutorial gate). Capture: HUD with the button (+ admin chip),
the moment card on phone / tablet / console (`capture_device_matrix`).

## Next steps

- The `Friends` icon (Fluent 3D handshake, `tools/ui/icons`, key `Friends`, asset 132896036686104)
  was uploaded 2026-10-31 and was "Reviewing" at upload (mapped like every Reviewing icon: Roblox
  serves the picture once moderation approves it). Run `python3 tools/ui/icons/icons.py moderation`
  to refresh its state; a rejection unmaps it and the UI falls back to the Star glyph / the Gift
  box (`SocialConfig.Client.FriendsIconFallback`) with no code change.
- Tune minutes / percent from `rush:*` and `friends:*` (the admin commands allow a live A/B on one
  server).
- MessagingService could pay an inviter who is online in ANOTHER server at once (today: next join).
