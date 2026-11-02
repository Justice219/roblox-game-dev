# SellNukes Creator Dashboard setup

Owner request R34 and follow-ups, 2026-10-30. Records listing configuration and its verification;
`SELLNUKES_CLAUDE_DOCUMENTATION.md` remains the shared architecture guide.

## 2026-11-01 — More badges, notifications and private servers

Latest dashboard name observed: **Sell Nukes [☢️]**. This task did not rename it.

- **Free private servers enabled:** Audience → Advanced settings → Allow private servers on,
  Requires Robux off; saved and reloaded. Existing device selection and capacity retained.
  Proof: `verification/creator-dashboard/free-private-servers.png`.
- **Five additional badges created and Active:** Rocket Factory, Launch Silos, Nuke Megastore,
  Space Port, Mega Nuclear Facility. All ten created badges are Active; the new IDs are wired
  into `BadgeConfig`. Full ID and artwork table: `leaderboards.md`. Proof:
  `verification/creator-dashboard/second-five-badges.png`.
- **Three return-notification templates created, reloaded and wired:** factory full, daily
  streak (parameter `day`) and daily missions. UUIDs and exact text: `retention.md`.
  Proof: `verification/creator-dashboard/return-notification-ids.png`.
- **Notification key and secret created with explicit owner approval:** key
  `Sell Nukes Return Notifications` is Active, grants only `user.user-notification:write`,
  and is restricted to universe `10773845696`. Secret `SellNukesNotifyKey` is restricted to
  `apis.roblox.com`. No raw credential is stored here. Proof:
  `verification/creator-dashboard/notification-secret.png`.
- **HTTP enabled in Rojo** (`default.project.json`). Publish the code/settings and start new
  instances before expecting badge awards and return notifications. No live notification was
  sent and no Studio publication was performed.

## Verified result

Configured through Chrome as **JusticeTTV1**. Universe **10773845696**, start place
**132667741281890**, owner user **1586034782**. The first connection attempts timed out; the
owner reconnected Chrome and the subsequent setup succeeded.

| Setting | Saved value / evidence |
|---|---|
| Experience and start-place name | **Sell Nukes**, exactly as the owner's correction requests |
| Description | 864 characters; exact text below, read back from the start-place settings |
| Genre / subgenre | **Simulation / Tycoon**; dashboard restricts changes until Nov 28, 2026 |
| Maximum Visitor Count | **8**, changed from 50; save completed |
| Icon | Primary `icon.png`; saved and subsequently displayed in the dashboard sidebar |
| Detail-page gallery | **10 thumbnails**: nine primary images plus the alternate; persisted after reload |
| Gallery lead image | `thumb-1-plus999-per-second.png`, moved first using the accessible reorder control and saved |
| Home Page thumbnails | All ten uploaded; `thumb-1-plus999-per-second.png` selected, saved, and shown **Active** after reload |
| Personalization | Dashboard says **off**, recommending consistent 1,000+ daily users before testing multiple thumbnails |
| Content questionnaire | All **17 sections submitted**; dashboard reads **Questionnaire Completed** |
| Content maturity | **Mild**, descriptor **Violence (Repeated/Mild)** |
| Access | **Public** as of the owner's 2026-10-30 follow-up: Manage audience confirms availability to **ages 16+**, subject to existing content/region restrictions |

Dashboard: https://create.roblox.com/dashboard/creations/experiences/10773845696/game-details

Evidence: `docs/verification/creator-dashboard/thumbnails.jpg` and `content-rating.jpg`.
No Studio build, public release, ad campaign, purchase, or changes to existing API access settings
were part of this setup. No social destinations were invented. The alternate icon and 1024px
source remain local because the dashboard exposes one current icon, which is the approved primary.

## Saved description

```text
☢️ Start in a tiny garage. Build a HUGE toy nuke empire!

💸 Make and sell cartoon nukes, upgrade machines, and grow your cash per second.
🏗️ Step on buttons and watch your factory build itself, piece by piece!
🤖 Hire managers to automate production and earn while you're away.
🚀 Unlock 10 areas, from the Garage Lab to the Space Port and Mega Nuclear Facility.
🥚 Hatch eggs, collect pets, and boost your earnings.
♻️ Rebirth for permanent upgrades and build your next empire faster.
🎁 Collect daily rewards, playtime gifts, and free Lucky Wheel spins.
🛡️ Unlock launch silos, send cartoon nukes at other plots, and build defenses. Hits are all confetti—your buildings and upgrades stay safe!

🦃 COMING NOVEMBER 1: Harvest Feast! Catch Golden Turkeys, collect Feast Stickers, and earn the Gobble Bomb pet.

Build with friends in servers for up to 8 players!
```

EventConfig schedules Harvest Feast from November 1 through December 1, 2026 UTC. Update the
seasonal sentence when the event actually goes live; remove it after the event. The seasonal
image is in the gallery and uploaded as a Home alternative, but is not the active Home creative.

## Artwork manifest

Directory: `assets/marketing/2026-10-30-forgegui/final/`. Originals unchanged. All thumbnails are
1920×1080 PNGs under 3 MB. Both 512px icons are 512×512. Dimensions and sizes verified locally.
Home uploads accept up to five files per batch; the detail-page gallery allows ten total.

| File | Uploaded destination |
|---|---|
| `icon.png` | Current experience icon |
| `thumb-1-plus999-per-second.png` | Gallery first; Home active |
| `thumb-2-plus1-nuke-every-second.png` | Gallery and Home alternatives |
| `thumb-3-noob-vs-pro.png` | Gallery and Home alternatives |
| `thumb-4-harvest-feast.png` | Gallery and Home alternatives; upcoming event |
| `thumb-5-secret-pet.png` | Gallery and Home alternatives |
| `thumb-6-day1-vs-day100.png` | Gallery and Home alternatives |
| `thumb-7-send-nukes-to-friends.png` | Gallery and Home alternatives |
| `thumb-8-it-builds-itself.png` | Gallery and Home alternatives |
| `thumb-9-biggest-nuke-factory.png` | Gallery and Home alternatives |
| `thumb-alt-noob-vs-pro-b.png` | Gallery and Home alternatives |
| `icon-alt-b.png` | Local alternate; did not overwrite the approved icon |
| `icon-1024.png` | Local high-resolution source |

## Questionnaire answers and rationale

| Section | Answer |
|---|---|
| Violence | Yes; **Mild**, **Repeated**. Toy missile attacks, interceptors, confetti impacts and building wobble; barrages occur in quick succession. |
| Blood | No |
| Fear | No |
| Crude humor | No |
| Unplayable gambling content | No; no casino imagery or unplayable gambling games. Reward rolls are declared under Paid Random Items. |
| Strong language | No |
| Romance / private spaces / adult settings | No |
| Alcohol | No |
| Social hangout | No; primary activity is tycoon progression |
| Free-form user creation | No; fixed builds, no drawing canvas. Stand names are filtered before replication. |
| Sensitive issues | No; fictional cartoon theme, no current political/religious issue |
| Cross-experience captured content | No |
| Generative AI interaction | No; AI-assisted development/art does not provide runtime model interaction |
| Paid Random Items | **Yes**; Robux/gem crates, paid spins, purchasable currency used for eggs |
| Respects ArePaidRandomItemsRestricted | **No**, because current enforcement has a confirmed cash-egg gap, detailed below |
| Paid Item Trading | No |
| Media Sharing | No custom gameplay-media sharing system |
| Continuous Media Feed / Autoplay | No; background game music is explicitly excluded by the question |

Sources: approved design, `docs/pets.md`, `docs/attack.md`, `EggConfig`, `PetService`, and
`MonetizationConfig`; live questionnaire definitions were read in Chrome before answering.

### Paid-random policy gap and regional result

`EggConfig.PaidRandomCurrencies` sets **cash = false** while `MonetizationConfig` sells
`CashSmall`, `CashMedium`, `CashLarge`, and `CashHuge` for Robux. `PetService` checks the regional
policy only when the egg currency is marked true. Thus a cash-priced egg can be bought using a
currency obtainable with Robux without that restriction check. The questionnaire itself explicitly
includes indirect currency purchases in paid random items. Existing gating for acorn eggs, gem
crates, and paid spins does not establish complete coverage.

The submitted questionnaire therefore honestly declares that the API is not fully respected.
The dashboard lists these **Non-Compliant Regions** for **Paid Random Items**:

- Australia, Belgium, Netherlands.
- Brazil and United Kingdom: under 18 years old.

**Before launch:** the core/pets owner should gate every paid-random acquisition route (including
cash eggs and any held/receipt routes), verify fail-closed behavior and UI messaging, publish the
fix, and then resubmit the questionnaire based on the deployed behavior. Do not answer Yes merely
to remove these regional exclusions. This dashboard task did not change or publish game code.

#### Gap status (2026-10-30, P1 pets compliance pass)

**Closed in the repo (eggs + crates; not yet published):**

- `EggConfig.PaidRandomCurrencies` now gates **cash = true** and **acorns = true**. Held eggs stay
  free because they are granted, and hatching one buys nothing.
- `PetService` awaits the policy on *every* hatch that must buy at least one egg. The check
  `EggConfig.needsPolicy` uses the same held-count rule as the hatch itself, and `restricted`
  defaults to true until the policy resolves.
- Crates: gem opens stay gated. **Held crates are now gated too**: they only come from Robux
  receipts, so opening one is a paid random item. A restricted player's crates are kept, not lost.
  Receipts defer while the policy is unknown, and a known-restricted buyer gets the gem price
  instead (`CrateLogic.receiptDecision`).
- Fail closed everywhere: if the policy was never fetched, the lookup failed, the answer is
  malformed, or the lookup is still pending after 10 s, the player counts as restricted
  (`PolicyCache`).
- UI: restricted players see stands, EggHatch, CrateShop and CrateOpen with every buy/open button
  locked ("UNAVAILABLE"; stand price line "NOT IN YOUR REGION"). The odds stay visible on every stand, and they are on screen at
  every crate purchase.
- `tests/pets-policy.luau` runs each currency through restricted, five unknown variants and
  unrestricted. Expected results are refused / refused / allowed, and nothing changes on a
  refusal. It also checks that free grants and held eggs are unaffected.

**Also closed in the repo (P1, same day; the wheel and lure owners' sessions had ended):**

1. **Lucky Wheel:** spins are split into `free` (timer), `bonus` (free rewards) and `paid`
   (Robux). Spending a paid spin re-checks the policy on every request, fail closed. The Spins
   products are `paidRandom`, and their receipts defer while the policy is unknown and pay 40 gems
   per spin to a known-restricted buyer. Old saves keep all old spins as paid. **Starter /
   Secret Pack** stay on sale for everyone, but restricted or unknown buyers get 40 gems per spin
   instead of spins, and the pack card says so.
2. **Turkey Lure:** now `paidRandom`, so the prompt is refused for a restricted or unknown
   policy. A lure that still reaches a restricted catcher pays fixed acorns and rolls nothing.

Every known paid-random route is now gated in the repo. **Before answering "Respects
ArePaidRandomItemsRestricted: Yes":** publish this build, re-verify in a live server (or Studio
with `PlayerDataService.setPolicyOverride`), then resubmit the questionnaire.

Manage audience also shows future public-reach requirements: 250 highly engaged players and a
refundable 1,000-Robux Kids & Select publishing fee for reaching under-16 players. Those are not
questionnaires, and neither payment nor public release was performed.

## Managed pricing follow-up (2026-10-30)

Enabled Managed Pricing through Chrome after the owner confirmed the one-time Terms of Use
acknowledgement. Initial enrollment covered all 11 passes; bulk enrollment then enabled the
24 developer products. All 35 item rows read **Enabled**, and Overview shows **35/35 items,
100% optimized**. Evidence: `docs/verification/creator-dashboard/managed-pricing.jpg`.

The revenue-protection questionnaire was answered **My experience does not allow trading or
gifting**, consistent with the current game systems. Regional prices are bounded at 30–100%
of the default price. Enrollment does not mean a price experiment has already completed.

The owner also asked for an explanation of the egg issue. Rechecked current source:
`EggConfig.luau:96` still sets cash false, `PetService.luau:244` skips policy resolution for that
currency, and `PetLogic.luau:248` therefore skips refusal. Robux cash packs have live product IDs.
Earnability or a small top-up does not exempt this shared currency under Roblox's
[paid random items guidance](https://create.roblox.com/docs/production/monetization/paid-random-items).
This follow-up did not alter the egg code or the submitted compliance answer. A compliant fix
must handle restricted users while retaining an unpaid earnable path, disclosed deterministic
rewards, or guaranteed direct purchases; test paid/held/receipt routes and publish before
resubmitting the questionnaire.

Pricing integration follow-up: `src/client/UI/Screens/Shop/init.luau` still passes configured
`def.price` into pack, product, and pass cards (lines 328, 359, 402), and the client has no
`GetProductInfoAsync` lookup. Those labels need player-specific live prices to match managed
pricing in Roblox's purchase prompt. See
[managed pricing](https://create.roblox.com/docs/production/monetization/managed-pricing).
This is a runtime follow-up; enabling dashboard automation does not implement that UI behavior.

## Public access follow-up (2026-10-30)

At the owner's explicit request, selected **Release publicly on Roblox → Continue** in
Manage audience. The dashboard changed from owner/collaborator-only to **Sell Nukes is available
to players ages 16+!** with content maturity restrictions. Evidence:
`docs/verification/creator-dashboard/public-access.jpg`.

This changes access to the existing uploaded place; it does not publish the current local
working tree or restart servers. No runtime, schema, product price, or permissions-to-edit change
was made. The accurate content questionnaire and its paid-random regional exclusions remain.
Under-16 reach still has incomplete requirements: 250 highly engaged players and the refundable
1,000-Robux Kids & Select publishing fee. No payment was made. Rollback is through Manage
audience → Manage access if the owner wants to restrict access again.

Release scope is dashboard availability only, verified by the explicit audience status.
Runtime launch readiness is not newly certified by this action; the documented egg-policy and
live-price-label issues remain. The current check run stopped at formatting differences in
other contributors' `StudioDummy.luau` and `AttackService.luau`; those files were not reformatted.
A separate `./scripts/typecheck.sh` also failed on the in-progress `AttackService` edits
(unknown `StudioDummy.Dummy` / `inFlight`, optional Player, and a missing AttackConfig field).
Documentation diff checks passed; this public-access follow-up is left uncommitted because
`scripts/check.sh` explicitly requires a passing full gate before commit.

## Unpublished engagement campaign handoff (2026-10-30)

Prepared the Ads Manager **Create campaign** form in Chrome at the owner's request, with
publishing explicitly reserved for the owner. **Publish was not clicked**; no campaign was
launched and no ad spend was authorized. The form exposes Publish and Cancel, with no visible
Save draft action. The live tab is retained for handoff; do not reload/navigate away before
publishing or the unsaved settings may be lost. Uploaded assets are saved to the Roblox library
for moderation; upload completion does not establish moderation approval.

| Field | Prepared value |
|---|---|
| Experience | Sell Nukes, universe 10773845696 |
| Campaign name | Sell Nukes \| 250 Highly Engaged Players \| Launch Test |
| Goal | **Engagement (Reach Kids/Select)**, Beta |
| Audience | All players; alternate audiences and advanced targeting are disabled for this objective |
| Budget | **$20 USD lifetime**, an editable test assumption pending the owner's review |
| Duration | **3 calendar days** |
| Start | **Nov 1, 2026**, with the form showing **12:00 AM Pacific**; review the displayed local time before publishing |
| Creatives | **10 attached**, verified by Image assets (10/25) and the preview grid |

All ten numbered PNGs in `assets/marketing/2026-10-30-ads/final/` were uploaded unchanged:
ad01 billion challenge, ad02 first click, ad03 offline earnings, ad04 friends/leaderboard,
ad05 upgrade multiplier, ad06 Harvest Feast, ad07 AA tower, ad08 secret pet, ad09 garage-to-empire,
and ad10 step-to-build. The owner's clarification expanded the initial three-image selection to
all ten. Start date was moved into November because ad06 promotes the Harvest Feast event.
The calendar selection and displayed date differed by one day, so the final schedule was checked
against the **displayed** date rather than assumed from the clicked calendar cell. Evidence:
`docs/verification/creator-dashboard/ad-campaign-creatives.jpg`.

[Roblox's Ads Manager guide](https://create.roblox.com/docs/production/promotion/ads-manager)
identifies Engagement as the objective for qualifying highly engaged players. This is not a
promise that $20 buys 250 qualifying players. Monitor the actual highly engaged player count in
Manage audience, not clicks or ordinary plays. The campaign **does not automatically pause at
250**: pause it manually when the target is met. If the count does not progress after 3–5 days,
review onboarding and retention before increasing spend. User review and Publish remain the
next actions; the documented runtime fixes still need their separate live verification.

Repository verification for this handoff: `./scripts/check.sh` stops at formatting in shared,
in-progress `StudioDummy.luau`, `AttackService.luau`, and `ModelViewportLogic.luau`.
The separate strict type-check also reports in-progress AttackService errors (including
AfkTracker/StudioDummy/inFlight references), plus shared-tree ModelViewport and CurrencyFlyConfig
errors. Those runtime files were not edited for this ad task.
The required passing gate therefore still blocks a documentation commit. No runtime version
bump or build is appropriate for this external dashboard-only configuration.

## Revised ad creative refresh (2026-10-31)

Replaced all ten older campaign attachments with Claude's revised PNGs from
`assets/marketing/2026-10-30-ads/final/`, then refreshed all ten again after the owner's latest
Sell Nukes logo update (R66). Each upload showed **Complete**. The final form shows
**Image assets (10/25)**; the ten attached image sources match the newly uploaded branded set,
with no superseded attachment remaining. The grid visibly shows the SELL NUKES logo on all ten
images without the old PLAY NOW buttons. Previous uploads remain in the asset library; only
the campaign selections changed.

The Engagement goal, All players audience, $20 USD lifetime budget, three calendar days, and
November 1, 2026 at 12:00 AM Pacific were preserved. **Publish remains untouched.** The existing
Chrome Create campaign tab is retained for owner handoff; it has no visible Save draft action,
so do not reload or navigate away before publishing. Upload completion is not a moderation
approval. Final evidence: `docs/verification/creator-dashboard/ad-campaign-creatives-logo.png`.
The intermediate R53 refresh is also captured in `ad-campaign-creatives-r53.png` in that folder.

Verification: `./scripts/check.sh` passed formatting, lint, strict Luau type-check, Studio-style
compile, and all 70 standalone suites. Documentation diff checks passed. This external campaign
edit does not change runtime code or require an in-game version bump or full build.

## Three additional creatives and scheduled campaign (2026-10-31)

Uploaded `ad11-dino-valley.png`, `ad12-knockdown.png`, and `ad13-noob-vs-pro-dino.png` from
`assets/marketing/2026-10-30-ads/final/` in response to the owner's screenshot. During the upload
workflow, the live browser moved from Create campaign to a **Scheduled** campaign without an
agent Publish action. Readback of the saved campaign confirmed **13 creative rows**, all enabled
and Scheduled. Opening its edit view without changing anything showed **Image assets (13/25)**,
all three requested new images, and a disabled Save button. Exited the edit view with Cancel.

Campaign `35ffa338-6d1e-4abf-b72a-07cf1ef5aed4` remains Engagement / All players / $20 lifetime.
Its saved details display November 1, 2026 at 12:00 AM through November 3 at 11:59 PM, Los Angeles
time (GMT -08:00). The edit form displays Duration 4 despite that date range; neither schedule
nor budget was changed by the agent. The earlier unpublished-tab handoff is now historical.
Several older thumbnail previews displayed loading errors, while all three new previews rendered;
the saved creative rows themselves report Scheduled. This does not establish moderation approval.
Evidence: `docs/verification/creator-dashboard/ad-campaign-13-creatives.png`.

## Public access and device availability (2026-10-31)

**Dashboard configuration verified.** Manage audience > Manage access already had **Public**
selected, with Friends unchecked; no access change was needed. The dashboard still states that
Sell Nukes is available to players **ages 16+**, with the under-16 publishing steps incomplete.
No fee was paid and no content-rating answer was changed.

Audience > Advanced settings > Device type had **Mobile** and **Tablet** enabled but **Console**
disabled. Enabled Console, saved, reloaded the page, and confirmed **Desktop, Mobile, Tablet,
Console, and VR** checked. Desktop/VR were existing selections. Other audience, payment, region,
and access-control settings were preserved. Rollback for this change is to uncheck Console and
save on the same page. This is dashboard availability verification, not a new runtime publish
or a physical mobile/console playtest; runtime readiness remains a separate release gate.

Evidence: `docs/verification/creator-dashboard/public-access-verified-2026-10-31.png` and
`docs/verification/creator-dashboard/mobile-console-enabled.png`.

Repository verification: `./scripts/check.sh` passed formatting, lint, strict Luau type-check,
Studio-style compile, and all **71 standalone suites**. The first attempt stopped on an egg-price
assertion in the concurrently edited shared tree; that assertion was updated by its contributor
before the successful rerun. No runtime/test files were changed for this task. Documentation
diff checks also passed. No full build or in-game version bump was needed.

## First five badges — created and wired (2026-10-31)

Created the first five existing catalog entries through Chrome under Sell Nukes
(universe `10773845696`). Each 512 × 512 PNG was uploaded with its name and description and
**Badge is Enabled** checked. All five were created **free (0 Robux)**. After reloading the listing,
all five remained **Active** and the uploaded illustrations rendered.

| Catalog key | Badge | Dashboard ID |
|---|---|---|
| Welcome | Welcome to Sell Nukes! | `1262588763497037` |
| Area2 | Nuke Stand | `930439656495923` |
| Area3 | BoomDash Delivery | `2838896599280003` |
| Area4 | Glow Rock Mine | `1991745259308552` |
| Area5 | Enrichment Lab | `3137687340600188` |

Artwork and exact prompts: `assets/marketing/2026-10-31-badges/README.md`.
Evidence: `docs/verification/creator-dashboard/first-five-badges-active.png`.
Listing: https://create.roblox.com/dashboard/creations/experiences/10773845696/associated-items?activeTab=Badge

`BadgeConfig` now contains these verified IDs; the existing server-owned profile checks and
throttled award queue handle joining, area progression, and currently qualified returning players.
The first badge is for joining; the next four require current tycoon areas 2–5. Array order and
ownership bit positions remain unchanged; the other eleven planned badges still have ID 0.
Players see Roblox's native award toast and the experience's badge listing; the owner can inspect
Badge Status in the existing admin panel. No custom in-game gallery was added.

Version `0.4.0` and its WHAT'S NEW entry announce the five badges. The corresponding IDs were
verified in the Rojo-synced edit datamodel of the already-open Studio place `132667741281890`.
Another worker held the Studio test lock, so no playtest was interrupted or started. Studio also
deliberately suppresses real badge awards. **Publishing the place remains the owner's action**
under `CLAUDE.md` hard product rule 1; this task did not publish. After publishing, join a live
server and reach area 2 to verify actual platform awards.

Verification: the shared-tree check passed formatting, lint, strict Luau type-check, and
Studio-style compilation, then stopped on stale Moon world billboard anchors in the concurrent
work. Focused badge and change-note suites passed **190** and **252** checks respectively.
Full `./scripts/check.sh` passed in the managed isolated checkout based on `d8b4b7c`, both
before and after applying only this task's five Luau file changes: formatting, lint, strict
type-check, Studio-style compile, and all **71 standalone suites**. No full build was needed.
This verifies the badge patch independently of the unfinished Moon world work in the shared tree.

## Gamepass price reduction — 2026-10-31

Owner: "make the gamepasses slightly cheaper, like 30%". Read all eleven live pass rows, then
saved `round(old base price × 0.70)` in each pass's Sales form. Every save returned **Pass updated
successfully**. The final eleven-row listing independently matched every target price and showed
**Managed pricing: Enabled** for all eleven. Item for sale stayed enabled; developer products,
benefits, ownership rules, and IDs were not changed.

| Pass | ID | Previous base price | New base price |
|---|---|---:|---:|
| VIP | `2062649466` | 249 | 174 |
| 2x Cash | `2058433191` | 399 | 279 |
| Auto Clicker | `2063279399` | 149 | 104 |
| Fast Walk | `2061923824` | 49 | 34 |
| Teleporter | `2061497904` | 99 | 69 |
| Lucky Eggs | `2060658474` | 199 | 139 |
| +2 Pet Slots | `2058229188` | 149 | 104 |
| Triple Hatch | `2061353920` | 149 | 104 |
| Auto Hatch | `2062643469` | 249 | 174 |
| Offline Max | `2058463264` | 199 | 139 |
| Mega Launcher | `2061437855` | 149 | 104 |

All amounts are Robux. Whole-number rounding makes the actual discount approximately 30–30.6%.
Managed/regional pricing can vary the amount a particular player sees. The live dashboard prices
are effective independently of a place publish. Existing `PriceBook` code looks up each player's
real price and refreshes about every ten minutes; local fallback prices in `MonetizationConfig`
were aligned to the new base prices. Version 0.5.1 adds an IMPROVED item to the newest WHAT'S NEW
note. These local fallback/note changes will accompany the next owner place publish.

Evidence: `docs/verification/creator-dashboard/gamepass-prices-30-percent.png` (saved list).
The original Chrome tab timed out; a fresh Chrome tab completed the task. Studio's monetization
API was also checked read-only but its key was expired; no API mutation was attempted.

Verification: `./scripts/check.sh` passed formatting, lint, strict Luau type-check (the project's
`tsc --noEmit` equivalent), Studio-style compilation, and all **77 standalone suites**. No full
build or purchase was needed. No Studio playtest was started or interrupted.

## Server fill preference — 2026-10-31

Owner asked to fill existing servers before starting another. Server management itself exposes
server browsing/restarts; the fill control is in **Places → Sell Nukes → Access → Server Settings
→ Social Slots**. On start place `132667741281890`, changed **Roblox optimized** (radio value
`Automatic`) to **Disable** (`Empty`). **Maximum Visitor Count remains 8.** Saved, reloaded, and
verified Disable still selected and maximum 8. Evidence:
`docs/verification/creator-dashboard/server-fill-disabled-social-slots.png`.

Roblox's April 2026 [response about server allocation](https://devforum.roblox.com/t/custom-matchmaking-puts-player-in-new-sever-despite-occupancy-weight/4535024)
identifies this exact setting as the way to reduce new-server creation while existing servers
have room. Disabling social slots permits all eight slots to be filled rather than holding
capacity for social joins. The platform still decides eligible servers and allocation; changing
player counts and players blocking one another can leave several partly filled servers. This is
best-effort filling, not a hard guarantee that every global server must be full before another
is started. [Roblox matchmaking documentation](https://create.roblox.com/docs/matchmaking)
explains eligibility filtering and server scoring.

The initial Server Browser showed **1 server / 2 players** (one observation, not a load test).
No restarts, shutdowns, forced teleports, custom scoring changes, or runtime code changes were
needed. The live dashboard setting does not require a place publish. No version/change-note
bump was made for this external operational configuration.

Verification: the shared-tree `./scripts/check.sh` stopped at formatting in concurrently edited
BigPop / FlavorService / FlavorAdmin / BigPopBanner code. Those unrelated files were preserved.
A clean managed checkout at `b1b494a` passed the full `./scripts/check.sh`: formatting, lint,
strict Luau type-check (the project's `tsc --noEmit` equivalent), Studio-style compile, and all
**82 standalone suites**. Documentation diff checks passed. Only this task's documentation and
dashboard screenshot were committed; no build or Studio playtest was needed.

## Harvest Feast event and additional price cuts — 2026-11-01 UTC

Created the public **Harvest Feast** Festival event:
https://www.roblox.com/events/8298781641862677092. It appears under **Events** on the experience
page with the existing `thumb-4-harvest-feast.png` artwork and a **Join Event** button. The game
description now says **HARVEST FEAST IS LIVE!** instead of COMING NOVEMBER 1.

- Listing: **2026-11-01 01:15 UTC → 2026-12-01 00:00 UTC** (Oct 31, 8:15 PM CDT → Nov 30,
  6:00 PM CST in the dashboard). Roblox rejects past start times, so the listing began 75 minutes
  after the existing gameplay window. `EventConfig.Season` remains unchanged.
- Subtitle: **Catch Golden Turkeys**. Description covers Golden Turkeys, acorns, all 20 Feast
  Stickers, the Gobble Bomb completion pet, Harvest Egg hatches, decorations, and boosts.
- **35 developer products reduced by 20%; all 11 gamepasses reduced by another 30%** from prices
  read live immediately before editing, rounded to nearest whole Robux. The pass cut compounds
  the earlier reduction; it is not another cut from the launch price.
- Full live-table readback: **46/46 matched** the targets. All passes and 34 products have managed
  pricing enabled; ten newly added products were enabled during this task. **Pocket Rocket**
  intentionally retains fixed pricing, now **15 R$**, to preserve its Cash-pack value constraint.
- A concurrently created **Golden Revenge Nuke** was included after reading its live 39 R$ price:
  **31 R$**, managed pricing enabled.
- Local `MonetizationConfig` fallbacks, current value comparisons/tests, and the generated
  `docs/monetization.md` catalogue were aligned. Reward amounts and receipt processing are unchanged.
  Existing clients already query live Roblox prices through PriceBook.
- Evidence: `docs/verification/creator-dashboard/harvest-feast-public.png`,
  `harvest-feast-game-page.png`, `gamepasses-second-30-percent.png`, `developer-products-20-percent.png`, and the complete
  before/after/id audit `harvest-pricing-2026-11-01.json` in that directory.

### Verification and shared-release handoff

- Isolated `./scripts/check.sh` completed successfully: formatting, lint, strict Luau type-check,
  Studio-style compile, and **all 82 standalone suites passed**.
- Dashboard readback checked all **35 products + 11 passes**, including managed-pricing states.
  The JSON audit contains final prices; **do not reapply the percentages** to those final values.
- Targeted shared-tree regressions passed: gift ladder **185**, Nuke Pass **297**, catalogue
  validation **322**, and change notes **283** checks.
- The shared tree's full check encountered unrelated, in-progress Happy Hours typing errors
  (`HappyHourChipLogic` / `HappyHourChipScreen` config and return-shape mismatches).
- The task commit isolates price changes for the existing 44-item catalogue on the committed
  release, with patch version **0.6.1**. The shared upcoming release is **0.7.1**, and retains the
  corrected Pocket Rocket / Golden Revenge Nuke definitions, comments, gift test, and gift
  documentation alongside their owners' uncommitted feature work. Those two live products are
  included in this task's dashboard audit and generated live catalogue; their unrelated feature
  implementations are not staged by this task.
- No Studio playtest was interrupted, and the place was not published.

## Repository verification

`./scripts/check.sh` was rerun during this task. Formatting, lint, strict Luau type-check (the
project's `tsc --noEmit` equivalent), and Studio-style compile passed. Logic checks stopped at
`tests/build-in-plan.luau:140`: **manager lights stay, without motion**. This test and the world
FX modules were modified in the shared tree before this task. Later suites were not reached.
No full build was run. Runtime and other contributors' files remain untouched.

At the original setup, repository documentation/evidence was left uncommitted while that required gate failed.
The Managed Pricing follow-up reran `./scripts/check.sh`: format, lint, strict type-check,
compile, and **all 42 standalone suites passed** in the current shared tree. Only this follow-up's
documentation and managed-pricing screenshot are included in its commit.
No in-game version bump was made: this task configures external listing metadata and records it,
without changing or publishing runtime code or in-game change notes.
