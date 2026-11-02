# SellNukes retention + shop (B7)

Daily Rewards, Time Rewards, the Lucky Wheel, Codes, Group rewards, the notification opt-in reward,
Settings, personal and server boosts, the Shop's pack and cash products, Welcome Back and
What's New. This covers design spec §6, §7 and §11; the references are in `docs/reference/ui-style/01–07`.
Every module has a header with its purpose, connections and an example. This page is the map.

## Layers

| Layer | Files | Job |
|-------|-------|-----|
| Config (shared) | `Shared/Config/{RetentionConfig, PlaytimeConfig, LuckySpinConfig, CodesConfig, GroupConfig, BoostConfig, ShopConfig}` | Numbers, catalogues, and READ-ONLY status rules (`dailyStatus`, `PlaytimeConfig.status`, `LuckySpinConfig.status`). The server and the screens use the same rule, so they always agree. |
| Pure logic (server) | `Server/Retention/{RewardLogic, DailyLogic, PlaytimeLogic, WheelLogic, CodeLogic, BoostLogic, StockLogic}` | The mutations. No services, no yields; tested with Lune. |
| Live boundary | `Server/Retention/{RewardGrant, ModifierHook, AdminHooks}` | Applies grants (fields, analytics), connects to B5's ModifierSources and B14's AdminService, both through guarded lazy requires. |
| Services | `Server/Services/{RetentionService, PlaytimeService, LuckySpinService, CodesService, GroupRewardService, NotifyRewardService, SettingsService, BoostService, ServerBoostService, ShopService}` | Remotes, rate limits, product handlers, loops. |
| Return notifications (owner R122) | `Shared/Config/NotifyConfig`, `Server/Retention/{ReturnNotifyLogic, ReturnNotifyQueue, ReturnNotifySender, ReturnNotifyRunner, ReturnNotifyControl, ReturnNotifyAdmin, ReturnNotifyService}` | Plans one notification when a player leaves, queues it in MemoryStore, and sends it through Open Cloud when it is due. Full map: "Return notifications" below. |
| Screens | `Client/UI/Screens/{DailyRewards, TimeRewards, LuckyWheel, Codes, GroupRewards, NotifyPrompt, Settings, WhatsNew, Shop, WelcomeBack}` | StudUI screens, auto-discovered. `DailyRewards/RewardPreview` is the shared reward display. `DailyRewards/CardGrid` is the 3×2 + rainbow grid used by Daily; Time uses its own `TimeRewards/GiftGrid` (10 cards + toolbar, owner R89). |

## Rewards (`RetentionConfig.Reward`)

A reward can mix any of these parts: `cashSeconds + cashFloor`, `gems`, `spins` (wheel spins: free rewards fill the **bonus** bank; only Robux rewards passing `{ paidSpins = true }` fill the gated **paid** bank), `boost = {key, seconds}`, and `pet` / `egg` with `fallbackGems`.
- **Cash:** `max(cashFloor, cashSeconds × automated income)`. Income is `TycoonLogic.incomePerSecond` on `profile.tycoon` with rebirth bonuses only; timed boosts and passes never inflate a reward. The client preview (`RewardPreview`) uses the same rule.
- **Grants:** every grant goes through `RewardLogic.apply` in ONE non-yielding step together with the claim record.
- **Items:** pets and eggs go through granters that B9 registers (`RewardGrant.registerItemGranter("pet"|"egg", fn)`). Until a granter is registered, the reward's `fallbackGems` are paid instead.
- **Analytics:** cash and gems from rewards are reported through `PlayerDataService.CurrencyChanged`, deferred.

## Systems

| System | Remote(s) | State | Rules |
|--------|-----------|-------|-------|
| Daily | `ClaimDaily()` | `profile.daily {streak, lastDay}` | One claim per UTC day. The next day continues the streak; a gap restarts it at Day 1 (48 h window). After Day 7 the cycle starts over. A clock running backwards opens nothing. |
| Time (Early Gift Ladder, owner R89) | `ClaimTimeReward(i)`, `ClaimTimeRewardsAll()` | `profile.timeRewards {day, seconds, claimed, ladder}` | One 1 Hz server loop. Each tick credits at most 5 s; a day is capped at 24 h. Ten gifts unlock at 1/3/5/10/15/25/40/60/90/120 min of today's playtime (kept across rejoins the same UTC day); each pays once per UTC day; CLAIM ALL opens every ready gift in one step. The profile is pushed every 30 s and the client extrapolates between pushes. Full design, Pocket Rocket and the favorite prompt: `docs/gifts.md`. |
| Wheel | `SpinWheel(requestId)` → `SpinResult` | `profile.spin {free, lastFreeAt, paid, bonus}` | One free spin per 20 min, banking up to 3; the timer starts on first contact, so new players get no back-filled spins. Spend order **free → bonus → paid**. A paid (Robux) spin re-checks PolicyService on every request (fail closed; refusal codes `restricted` / `policyUnknown`, the paid spins are kept). The roll is weighted (8 slices, weights sum to 100) on a server `Random`. A request id answered recently returns the same answer and never spins twice. |
| Codes | `RedeemCode(text)` → `CodeResult` | `profile.codes` | Input is trimmed and upper-cased. Each code has a `[startsAt, expiresAt)` window and pays once per player. Rate-limited. |
| Group | `ClaimGroupReward()` → `GroupRewardResult` | `profile.group.claimed` | **`GroupConfig.GroupId = 0` → "Group coming soon!" (owner: set the id).** Membership is re-checked with `IsInGroupAsync` on every claim, and the session is re-checked after that yield. |
| Notify | `ClaimNotifyReward("shown"\|"accepted"\|"declined")`, `ClaimNotifyReward("card", moment)` | `profile.notify.claimed` | Roblox never tells the game whether the player opted in, so the client reports it (dialog opened, then CanPromptOptIn flipping to false). The server pays once, only within 300 s of a "shown" report from this session. `"card"` (owner R122) only counts `rnotify:promptAt:<manager\|area2\|other>` (once per moment per session) and never pays. When the card suggests itself: "Return notifications → Opt-in card" below. |
| Settings | `SetSetting(key, bool)` | `profile.settings` | Only the 4 allowlisted keys (`ProfileLogic.applySetting`). A refused change re-sends the stored settings. |
| Boosts | product kind `Boost` | `profile.boosts {key = expiry}` | Time stacks, capped 24 h ahead. Registered with B5's `ModifierSources.register("personalBoosts", provider, { offline = false })`: the provider returns `{ boostCash, boostSpeed }` plus the soonest expiry as a cache hint, and boosts never count toward offline earnings. Every boost change calls `ModifierSources.invalidate(player)`. Expired boosts are pruned every 5 s. |
| Server boost | product kind `ServerBoost` | ReplicatedStorage attributes `ServerBoostEndsAt` / `ServerBoostBy` | Per server: 2x for 15 min per purchase, stacking up to 3 h. Provider `serverBoost` (`serverCash`, valid until the end time, `offline = false`); start and stop call `invalidateAll`. Every player gets a thank-you toast. |
| Shop | product kinds `StarterPack`, `SecretPack` (`Gems` is built into MonetizationService; `Cash` packs are granted by B5's TycoonService, which knows the live income) | `profile.starter / secretPack.bought` | Each pack is granted with its one-time flag in the receipt step; a second paid receipt is still granted. The packs stay on sale for everyone; their spins follow `RewardLogic.robuxReward` (below). |
| Secret Pack stock | (after a durable grant) | DataStore `SellNukesStock_v1` (`_Studio` in Studio) + ReplicatedStorage `SecretPackSold/Limit/At` | Each PurchaseId is counted once (`StockLogic.count` inside `UpdateAsync`, retried). The count is re-read every 60 s. The prompt is refused when sold out or when the stock is unknown. |


## Paid random items (PolicyService) — Lucky Wheel and packs (2026-10-30)

Roblox `ArePaidRandomItemsRestricted`: a restricted player can not interact with paid random item
generators, whether through Robux or through currency bought with Robux. Wheel spins bought with
Robux are paid random items. The rules below fail closed: a player counts as restricted until
`Economy/PolicyCache` knows otherwise. Tests: `tests/paid-random-policy.luau` (restricted, five
unknown variants, unrestricted) and `tests/retention-logic.luau`.

| Spins / purchase | Source | Rule |
|------------------|--------|------|
| `spin.free` | 20-min timer | always spinnable |
| `spin.bonus` | free rewards: daily day 5, codes, notify, admin `GrantSpins` | always spinnable; never a paid random item |
| `spin.paid` | Spins2/5/10 receipts; Starter / Secret Pack spins for a known-unrestricted buyer. Saves from before the split keep all old spins here, which fails closed. | each spin awaits `resolvePaidRandomAsync`; restricted refuses `restricted`, unknown refuses `policyUnknown`, and the spin is kept |
| Spins2/5/10 prompt | `paidRandom` | refused for a restricted or unknown policy. A known restricted refusal is counted as `wheel:refused:policy`. |
| Spins receipt | `WheelLogic.receipt` | unknown: deferred (NotProcessedYet). Known restricted: `GemsPerSpin` (40) gems per spin. Otherwise: paid spins. |
| Starter / Secret Pack | not `paidRandom`, on sale for everyone | `RewardLogic.robuxReward`: known-unrestricted buyers get paid spins. Restricted or unknown buyers get 40 gems per spin instead (Starter 200, Secret 400). The pack card shows `ShopConfig.packLines`, e.g. "200 Gems". |

Client: the LuckyWheel screen counts free + bonus spins, plus paid spins only where allowed. When
only paid spins are left in a restricted region, SPIN reads "UNAVAILABLE" with a reason line, and
the bundles are locked. The HUD hides its x5 Spins offer in restricted regions
(`HudOffers.availableFor`).

## Analytics (B13 `AnalyticsService.retention`, guarded)

`daily:claim:<1-7>`, `daily:reset`, `time:claim:<1-10>` (+ `time:claimAll`, `time:crate`, `rocket:*`, `favorite:*`: `docs/gifts.md`), `wheel:spin:<free|bonus|paid>`,
`wheel:refused:<policy|empty>`, `wheel:receipt:<spins|gems>`, `pack:spins:<spins|gems>`,
`wheel:slice:<sliceId>` (ids registered as `sliceId`), `code:ok:<codeId>` (registered `codeId`),
`code:fail:<invalid|expired|used|limit>`, `group:<claim|notMember>`,
`notify:<shown|accepted|declined|claim>`, the return notifications' `rnotify:*` keys (below).
Screens report `ClientAnalytics.screenOpened`.

## Admin (B14, `Retention/AdminHooks`, registered from ShopService.Init when AdminService exists)

`GrantSpins{count}`, `ResetDaily{}` (daily streak + today's time rewards), `GiveBoost{boost, minutes}`,
`ServerBoost{minutes}`, `ServerBoostOff{}`, `AddCode{code, gems, spins, cashSeconds, hours}` (this
server only). Service seams: `RetentionService.resetDaily/setStreak`, `PlaytimeService.addSeconds/
resetToday`, `LuckySpinService.grantSpins/setFree`, `CodesService.addCode/listCodes`,
`GroupRewardService.resetClaim`, `NotifyRewardService.resetClaim`, `BoostService.grant`,
`ServerBoostService.start/stop`, `ShopService.stock/refreshStockAsync`.

## Boot order (server; the lead edits `init.server.luau`)

All of these go after `MonetizationService`. Each one's `Init` registers its product handlers.

`SettingsService`, `BoostService`, `ServerBoostService`, `RetentionService`, `PlaytimeService`,
`LuckySpinService`, `CodesService`, `GroupRewardService`, `NotifyRewardService`,
`Retention/ReturnNotifyService` (owner R122; its Start installs the Notify* admin handlers),
`ShopService` (last: its Init installs the admin hooks).

## Tests

- **Lune:** `tests/retention-logic.luau` (streak, playtime, wheel timer and odds over 100k rolls, codes, boosts, stock idempotency, rewards and granters) and `tests/retention-config.luau` (every reward, icon, threshold, weight, code, shop reference and product kind).
- **Lune (return notifications, owner R122):** `tests/return-notify.luau` and `tests/return-notify-prompt.luau` (see "Return notifications → Tests").
- **Lune (paid random):** `tests/paid-random-policy.luau` (240 checks) runs the real PolicyCache answers (restricted, five unknown variants, unrestricted) against wheel paid spins, Spins receipts, Starter / Secret Pack spins vs gems including the card lines, Turkey Lure rolls, and free reward spins. `tests/retention-logic.luau` covers the free → bonus → paid order and `WheelLogic.receipt`. `tests/profile-logic.luau` checks that legacy spins stay paid.
- **Studio:** a play-mode smoke test of every claim flow and screen. Screenshots are in `docs/verification/ui/retention/`. The paid-random pass (2026-10-30, `setPolicyOverride`) confirmed four behaviours. A restricted paid spin is refused and the spins are kept; an allowed one spins. Bonus spins work while restricted. A Spins5 receipt while restricted pays +200 gems and 0 spins; a Starter Pack pays +300 gems and 0 paid spins. Captures are in `docs/verification/paid-random/`.

## Owner to-dos

- **Return notifications (owner R122): create the 3 notification strings, the Open Cloud API key and
  the experience secret, then paste the 3 message ids.** Exact steps: "Return notifications → Owner
  steps" below. Until then every kind shows NO ID and nothing is sent; Studio dry-runs everything.
- Set `GroupConfig.GroupId` and `GroupName`.
- Publish the product and pass ids. B12 does this, and until then every item shows SOON.
- Settings is reached from B16's menu wheel (View / Select, M). The `haptics` setting key (Vibration row) needs B17-core's ProfileLogic allowlist; until then the toggle snaps back.

## Return notifications (owner R122 §2.3)

**Why.** Field data (2026-10-31): D1 ≈ 2 % (5 of 232 new players came back). The game collected
notification opt-ins but never SENT a notification, and only about 10 % of new players ever saw the
opt-in card. It waited 8 minutes, and most players had left by then. Roblox ranks experiences on
**play days per user** (D1, D2–7, D8–28), and Creator Docs recommend experience notifications to
bring lapsed players back. This system sends one personal, actionable notification when a reason
to return becomes real. The opt-in card now shows at a strong moment in the first minutes.

**Roblox rules this follows** (Creator Docs, read 2026-11-01):

- Only opted-in users aged 13+ receive notifications.
- Each user gets at most **one notification per experience per day**.
- Content must be personal and actionable. No display names are used.
- Each message is a notification string created in the Creator Dashboard (max 99 characters,
  `{param}` placeholders), referenced by its asset id.
- Notifications are sent with Open Cloud `CreateUserNotification`:
  `POST https://apis.roblox.com/cloud/v2/users/{userId}/notifications` with `x-api-key`.
- Game servers may call it through `HttpService:RequestAsync` (Creator Docs "In-game HTTP
  requests" → Open Cloud). The `x-api-key` header **must** be a `Secret` from
  `HttpService:GetSecret`. Only the `x-api-key` and `content-type` headers are allowed. A Secret can
  go in headers or the URL, never in the body.
- Launch data is at most 200 bytes and comes back through `Player:GetJoinData().LaunchData`.

### Flow

| Step | Where | What |
|------|-------|------|
| Leave | `ReturnNotifyService` on `PlayerDataService.ProfileReleasing` (skipped in New Player Mode) | Builds the leave facts from the live profile: automated income + offline cap (`TycoonLogic.incomePerSecond` / `offlineLimits`, Offline Max pass), `profile.daily`, the usual start hour, `profile.notify.claimed`. Then `ReturnNotifyRunner.plan` → `ReturnNotifyQueue.plan` on its own thread. BindToClose waits up to 5 s for plan writes still in flight. |
| Plan | `ReturnNotifyLogic.plan` (pure) | Plans at most ONE notification: the first applicable kind in `NotifyConfig.KindOrder` whose switch is on and whose message id is filled in. The due time moves to at least last send + 24 h. A session under 60 s plans nothing unless the player reported an opt-in (`OptedInOnly = false`: Roblox itself filters delivery). |
| Queue | MemoryStore SortedMap `SellNukesReturnNotify_v1` | Key = userId. Sort key = due unix time. Value = `{ v, k, d, dl?, p?, at, s?, c?, cu?, n? }`. Markers are `{ v, m = sent \| join \| done, s?, j? }` with the string sort key `"~"`, which sorts after every number, so due reads never see a marker. Expiration is at most 2 days: an entry lives through its late window; a sent marker lives 24 h (the one-per-day rule); a join marker lives 5 min. |
| Join | `PlayerAdded` → `ReturnNotifyQueue.join` (GetAsync + UpdateAsync), again after 60 s | Turns a pending entry into a "join" marker: the entry is cancelled (`rnotify:drop:rejoined`) and its send time is kept. A plan that the server the player LEFT writes after this join skips itself because the marker is newer. An in-flight send cannot be stopped. |
| Poll | every server, every 60 s + 0–10 s jitter (random first wait) | `GetRangeAsync(Ascending, n, nil, { sortKey = now + 1 })`. `n` = min(20, free send slots, bucket tokens), so nothing is read that cannot be sent. Each item is claimed with `UpdateAsync`, which writes this server's token and pushes the sort key to `now + 120 s` (lease). MemoryStore replays the transform on the newest value when another server wrote first, so **exactly one server claims each entry**. A dead claimer's lease runs out and the entry reappears. A late entry (`MaxLateHours`, or past the streak deadline) is finished on the spot (`drop:late`). So is a switched-off kind (`result:off`). |
| Send | `ReturnNotifySender` on its own thread | Validated body → `RequestAsync` POST to the fixed URL with `Content-Type: application/json` + `x-api-key = Secret`. The poll waits at most 12 s: on a timeout the slot is freed, the result counts as `http` and the server backs off. A late answer still finishes the entry (an ok also counts `sent`). |
| Finish | `ReturnNotifyQueue.finish` (token-checked) | ok → "sent" marker. Other 4xx, dry, nokey, off → "done" marker. 429 / 5xx / 401 / 403 / no response → retried after 300 s × 2^(n-1), at most 3 attempts, never past the original late window. A finish from a server that lost its claim is refused. |
| Back-off | `ReturnNotifyRunner` | 429 / 5xx / no response: the server pauses 2 s × 2^(n-1), capped at 300 s; a larger `Retry-After` wins; a success resets it. 401 / 403 (bad key or scope): the server pauses 10 min. The token bucket is Burst 10 at 0.5 / s, with at most 4 requests in flight. |
| Return | `ProfileLoaded` (join only) | Launch data `rn:<kind>` → `rnotify:join:<kind>` once per session. `Sessions` counts `r<N>:notify` when the value is listed in `AnalyticsConfig.NotifyLaunchData`. |

**Kinds** (`NotifyConfig.Kinds`, priority order):

| Kind | When it applies | Due | Late drop | Params |
|------|-----------------|-----|-----------|--------|
| `cashFull` | automated income > 0 and an offline cap of at least 1 h | leave + the player's offline cap (3 h base, up to 24 h with the shop / Offline Max) | 6 h | none |
| `streak` | today's Daily reward was claimed (`profile.daily.lastDay == today`) | tomorrow (UTC) at the player's usual start hour, at least 16 h after leaving, at the latest 60 min before tomorrow ends | 3 h, and never at or after the end of tomorrow (the streak breaks then) | `day` = the next card (Day 7 → Day 1), from `RetentionConfig.dailyStatus` |
| `missions` | always (fallback) | max(leave + 20 h, the next UTC mission reset + 10 min) | 8 h | none |

**Usual start hour.** This is `profile.notify.hour` (0..23, -1 = unknown). ProfileLogic
reconciles it, and older saves read as -1. At leave, before the final save, the stored hour is
blended on a circle with this session's start hour (70 / 30). When the hour is unknown, this
session's UTC start hour is used.

**Modes** (`ReturnNotifySender.mode`):

- **Studio:** always a dry run. Plan, queue, claim, payload build + validation and analytics
  (`rnotify:result:dry`) all run; no HTTP request is sent. In Studio, kinds without a message id use
  the placeholder `studio-dry-run`, so the whole pipeline can be checked.
- **Live without the secret:** `nokey`. The same dry run, counted as `result:nokey`. The secret is
  looked up again every 5 min.
- **Live with the secret:** real requests.

### Switches and admin (Server tab)

`NotifyConfig.Enabled` is the code switch. The **runtime** switches are universe-wide:
`ReturnNotifyControl`. It uses DataStore `SellNukesReturnNotifyCtl_v1` (Studio: `_Studio`) with
versioned edits inside `UpdateAsync`, plus MessagingService fan-out and a 90 s poll. This matters
because every server polls the shared queue, so a per-server switch would not stop the others. The
running control is mirrored into ReplicatedStorage attributes `ReturnNotifyOn` /
`ReturnNotifyKindsOff` / `ReturnNotifyVersion` (display only).

| Command | Args | What |
|---------|------|------|
| NotifyToggle (confirm, audited) | mode on / off | Kill switch for every server. OFF = nothing is planned or sent, and due entries are dropped as `result:off`. |
| NotifyKind (audited) | kind, mode | One kind on / off everywhere. A kind also needs its message id. |
| NotifyStatus (read-only) | none | Mode (LIVE / DRY RUN / NO KEY / OFF IN CODE / NO QUEUE), switches per kind (ON / OFF / NO ID), queue size (`GetSizeAsync`: entries + markers) + due now, this server's plans / sends / results / drops, the last result, and the back-off. At most 300 bytes. |
| NotifyTest (audited, 10 s cooldown) | kind | One REAL notification of that kind to the caller, through the sender (bucket + back-off apply; queue + kill switch bypassed). **Live: owner only** (`AdminConfig.OwnerUserId` or the creator). Studio: a dry run for any admin. |
| NotifyQueueTest (Studio only) | kind, seconds 0..300 | Queues an entry for the caller due in N seconds through the real queue (0 = poll now). Proves plan → claim → dry send in Studio. |

The panel's Server tab shows a **Return notifications** block (`Client/UI/Screens/Admin/NotifySection`,
text rules in `NotifySectionLogic`):

- the live line, e.g. "Sending ON · Factory full ON · Daily streak NO ID · Daily missions OFF",
  from the attributes + the shared message ids;
- a note on what is missing;
- the last NotifyStatus text with its time;
- a REFRESH STATUS chip.

The block is event-driven (attribute signals + `AdminClient.Result`), and it sits above the generic
command forms.

### Opt-in card (`Client/UI/Screens/NotifyPrompt`, rules in `NotifyPrompt/PromptMoments`)

The card suggests itself once per session, at the first moment that happens:

1. **manager**: the player hires their FIRST manager this session (owned Manager pads go from 0 to
   1+).
2. **area2**: otherwise, the player reaches area 2 this session.
3. **other**: a returning player who already had both at join gets the card 180 s after load. Any
   other session gets it 480 s after load if no moment showed it (the old 8-minute floor).

Each moment:

- waits 2.5 s;
- skips the card when `CanPromptOptInAsync` is false (already opted in, under 13, or asked in the
  last 30 days), because there is nothing to gain;
- then goes **through the popup queue** (`PopupQueue.request`, kind `NotifyConfig.Prompt.QueueKind`
  = `notifyPrompt`). The card opens only when the centre lane is free, no window or cinematic is up,
  `JoinFlow.isQuiet()` holds and Roblox's menu is closed. `isQuiet()` means: nothing queued ahead,
  not a guided tutorial step, and no purchase flow (`PurchaseFlowAt`), so the card never opens over
  a purchase prompt;
- waits at most 90 s (`NotifyConfig.Prompt.MaxWaitSeconds` = the queue kind's `maxWait`).

The `notifyPrompt` kind is centre lane, priority 40: below juice, above the invite moment, which
can also follow area 2. A safety fallback applies if that kind is ever missing: the same gates
plus "no centre popup" are polled every 1 s (2 calm checks in a row). The first open of a session reports `ClaimNotifyReward("card",
moment)`; Settings → GET NOTIFIED counts as `other`. The one-time reward rules did not change.

### Analytics (retention family; every key in `AnalyticsConfig.Metrics.retention`)

| Key | Meaning |
|-----|---------|
| `rnotify:plan:<kind>` | Planned when a player left. |
| `rnotify:sent:<kind>` | Open Cloud answered 2xx (exactly one server per entry). |
| `rnotify:result:<ok\|throttled\|rejected\|http\|nokey\|off\|dry>` | Every send attempt's first known outcome; a timeout counts `http`. |
| `rnotify:status:<kind>:<400\|401\|403\|404\|429\|4xx\|5xx>` | R136: the HTTP status of every send Roblox answered with an error (`ReturnNotifyLogic.statusBucket`). 400 = the player has notifications off or is under 13 (Roblox only delivers to opted-in 13+ players; expected for a young audience, the entry is done), 429 = the one-per-day-per-experience cap or a rate limit, 401 / 403 = the key / scope (server key back-off), 404 = unknown message id. First live day (2026-11-01): 21 ok, 59 rejected, all `cashFull`. |
| `rnotify:drop:<late\|rejoined\|replaced>` | Too late / the player came back first / replaced by a newer plan. |
| `rnotify:join:<kind>` | Joins from a notification (launch data `rn:<kind>`). |
| `rnotify:promptAt:<manager\|area2\|other>` | The opt-in card's first open per session, by moment. |

Measurement (spec §4): `rnotify:join:*` and D1 on the `build:0.8.0:*` slices versus 0.7.1, over at
least 7 complete UTC days.

### Security and performance

- Clients send nothing to this system except the analytics-only `"card"` report: it is
  rate-limited, allowlisted and deduped.
- Every input is server-side: the profile, server clocks, and `GetJoinData` (matched exactly).
- The API key never leaves `ReturnNotifySender`. It is never printed, never put in a body, an
  error text, an analytics key or a client payload.
- The URL is fixed, and the user id is validated as an integer.
- Values read back from MemoryStore / DataStore / MessagingService are size-checked and strictly
  decoded; corrupt values count as absent.
- Every MemoryStore / HTTP call is pcall'd. Nothing runs per frame.
- Load per player: one plan write at leave, plus one read and two writes for a join.
- Load per server: one poll per minute (an empty read costs one request unit), with sends capped by
  the bucket.
- MemoryStore quota is 1000 + 120 × CCU request units per minute per universe. Studio's
  MemoryStore is isolated from live servers.

### Tests

- `tests/return-notify.luau` (1049 checks):
  - config;
  - usual hour;
  - every kind's due time, priority, switches, eligibility, the 24 h gap and the horizon;
  - strict decode;
  - every transform;
  - a **claim race** of two servers on a fake SortedMap that replays UpdateAsync conflicts;
  - the request body;
  - every HTTP verdict and the back-off curve;
  - the bucket;
  - control;
  - the sender with fakes (Studio dry run, nokey retry spacing, exactly two headers, the Secret only
    in `x-api-key`);
  - the runner end to end (plan → poll → claim → send → marker, late, off, 429, 401, limiter,
    concurrency cap, timeout race, join cancel, replaced, dry, nokey);
  - every analytics key allowlisted;
  - the status text (≤ 300 bytes, valid UTF-8);
  - the AdminConfig entries;
  - `profile.notify.hour` reconcile (default, clamp, junk, older saves).
- `tests/return-notify-prompt.luau`: moments over the real tycoon catalogue, sources, the admin
  section texts, the prompt timings and the popup-queue kind (when declared).

### Owner steps (only the owner can do these)

1. **Three notification strings created and verified (2026-11-01).** Creator Dashboard →
   Sell Nukes → Engagement → Notifications now contains these templates. Preserve the exact
   copy and parameter when editing them; each message is below the 99-character limit.

   | Name | Message | Parameter | Asset ID |
   |------|---------|-----------|----------|
   | Return - factory full | `Your nuke factory is full! Come collect your cash!` | none | `69dbd79b-5308-924f-96bd-8559db8ae66f` |
   | Return - daily streak | `Day {day} reward is ready - keep your streak!` | `day` (sent as text, e.g. "4") | `31d33d80-7cd8-b34c-8b86-8dc056f9e575` |
   | Return - daily missions | `New daily missions + Nuke Pass XP are waiting!` | none | `2418369b-d35f-754a-bffd-3a1beac68bb5` |

2. **The three asset ids are wired** in `src/shared/Config/NotifyConfig.luau`:
   `Kinds.cashFull.messageId`, `Kinds.streak.messageId` and `Kinds.missions.messageId`. If a
   template is recreated, use **⋯ → Copy Asset ID** and update its matching field. An empty id
   still keeps that kind off. No live notification was sent during setup.
3. **Open Cloud key created and Active (2026-11-01):** `Sell Nukes Return Notifications`.
   - API system: **notifications**; the only operation is **`user.user-notification:write`**.
   - **Restrict by Experience** is on, with only **Sell Nukes (universe 10773845696)** selected.
   - IP restriction is off because Roblox game servers do not have fixed addresses.
   - Expiration: **No Expiration** (Roblox still expires the key after 60 days of inactivity).
   - The owner approved creating and connecting this scoped credential. Its value was transferred
     directly to Roblox Secrets, never saved in the repository or screenshots, and cleared from
     the temporary clipboard/session variable.
4. **Experience secret created and verified (2026-11-01):**
   - Name: **`SellNukesNotifyKey`** (= `NotifyConfig.SecretName`).
   - Value: the notification-only key above.
   - Domain: **`apis.roblox.com`** (no wildcard).
   - Proof: `docs/verification/creator-dashboard/notification-secret.png`.
   - Newly created secrets are available only to newly started experience instances.
5. **HTTP enabled in Rojo:** `default.project.json` now sets
   `HttpService.$properties.HttpEnabled = true`. Publish this setting with the notification IDs.
6. **Remaining owner step: publish, then check delivery.**
   - In a live server, open the admin panel → **Server** tab → **Notification Status**. It should
     read `LIVE · sending ON · cashFull ON · streak ON · missions ON`.
   - Then run **Send Test Notification To Me** (Factory full). It should answer `ok`. Roblox
     delivers at most one per user per day, so a second test the same day may come back
     `throttled`.
   - Roblox only delivers to opted-in users aged 13+, and the experience needs at least 100 visits.

## Console + mobile (R11)

Every screen is gamepad-navigable through B16's `Platform/GamepadNav`:
- linked grids and lists, followed scroll and a `defaultSelection` that is never the close X;
- the Shop's sections cycle on LB / RB;
- B / Back closes; there are no hover-only states.

On phone and tablet, every tap target is at least 44 pt and text stays readable. The Codes text box opens the on-screen keyboard on console and phone.

Device-matrix captures (phone, tablet, Xbox) are in `docs/verification/ui/retention/matrix/`.
