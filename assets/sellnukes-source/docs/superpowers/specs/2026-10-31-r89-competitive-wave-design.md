# R89 — Competitive wave: luck in the core loop, Happy Hours, early gifts (design)

Owner R89 (2026-10-31): "I recorded some stuff from a couple other sell/tycoon games … can you use
any of the video to make our game super unique and competitive?" Research: V-video studied the
14-min recording (two other sell games; inspiration only — no cloned content, names, art, layouts).
Key finding: the "Sell X" genre is crowded (Lemons, Logs, Sushi, Burgers, Fries, Ores); a distinct
CORE twist matters more than more side systems. SellNukes already leads on build-in juice, stud art,
console/mobile, kid-safety, Quests / Pass / Rush / Friends, attack + defence, three worlds.

Wave 1 (this spec) = the gaps with the biggest retention / fun / revenue impact, each with an
original SellNukes twist. Wave 2 (later, own spec): Frosting Coats (producer mutations), Gift It
(buy for a friend), Rebirth Perk Draft, lobby limited-stock pedestal.

## 1. Surprise Batches (core-loop luck) + Flavour Book + Big Pop — builder F-flavors

- Every finished producer batch rolls a FLAVOUR on the SERVER (never the client):
  Plain, Sprinkle, Glitter, Rainbow, Galaxy, Mystery Pop — rising rarity, payout multiplier and
  "1 in N" odds shown to players. All numbers in `Shared/Config/FlavorConfig`. Average income lift
  is tuned to stay inside the pacing simulator's bounds (re-tune odds / multipliers, not the
  economy); automated producers paying many cycles per tick roll in aggregate (bounded work per
  tick, no per-cycle loops past a cap) and only surface discrete "highlight" batches.
- Pure logic in `Shared/Tycoon/FlavorLogic` (seeded roll, aggregate roll, luck multiplier input) with
  Lune tests incl. distribution checks. One additive hook in TycoonService's pay paths.
- Look: a flavoured batch tints the producer's income pop + a short sparkle; Rainbow+ glow on the
  producer for a few seconds where everyone can see; Galaxy+ plays a ≤ 3 s reveal for its owner
  (letterbox bars, odds counting up, confetti, SKIP; throttled; never during the tutorial, a menu or
  a cinematic).
- Flavour Book (new modal screen, HUD route through an existing button / the Pets or Quests window —
  no new left-stack button without lead approval): every flavour × world, undiscovered = grey "?"
  toys with odds, discovery rewards (gems) claimed once; Quests stat `flavor` (ProgressEvents) if
  cheap.
- Big Pop broadcast: Galaxy+ batch, a Mythic+ hatch, a Rebirth → one server-wide banner + a system
  chat line ("<DisplayName> popped a GALAXY batch! 1 in 2,500") + toy fireworks over that plot,
  globally throttled / coalesced. Display names only (no free text → no filter needed).
- NO paid luck in this wave (no paid-random policy surface). Event luck comes from §2.

## 2. Nukey's Happy Hours (scheduled server mini-events) — builder E-events

- Deterministic UTC schedule (every server agrees, no DataStore): a 5-min headline event at :00
  every hour rotating through Confetti Storm (pickups rain from clouds — reuse the Golden Turkey /
  Lucky Button spawn + collect paths), Sprinkle Surge (x FlavorConfig luck), Double Pops (income
  pop visual + small cash bonus), Dino Valley Egg Stampede, Moon Base Low-Gravity Hour; a 3-min
  Sprinkle Surge at :30. Pure `Shared/Events/HappyHourLogic` (current / next event at time t,
  luck multiplier at t) — FlavorLogic reads the luck multiplier from it directly (no service
  coupling). Admin: force start / stop / skip, kill switch.
- HUD: a separate non-modal screen chip "NEXT: CONFETTI STORM 12:40" / "LIVE: … 3:12" placed from
  HudZones (avoid Top / Left / Right / Bottom / the boost badge), hidden while any modal is open
  (listen to ScreenManager.Opened / Closed like Hud's MenuLayer), a banner + sound at start.
- Analytics (events family), Quests hook optional.

## 3. Early Gift Ladder + Pocket Rocket + Favorite prompt — builder G-gifts

- Playtime gifts at 1 / 3 / 5 / 10 / 15 / 25 / 40 / 60 / 90 / 120 online minutes (first one inside
  the 2-minute churn window from the day-1 data); deterministic rewards (cash seconds, gems, spins,
  boosts, a crate) so any paid skip is never paid-random; progress kept across rejoins the same UTC
  day (kinder than "leaving resets"). Reuse the existing time-rewards system / screen.
- Pocket Rocket: a small impulse developer product (low R$, once per UTC day) granting a few minutes
  of the player's own income, its live amount shown on a HUD offer; priced so it never undercuts the
  Cash packs' value per R$. Created via manage_monetization; receipts idempotent.
- Favorite prompt: one AvatarEditorService favorite prompt at a happy moment (first Rainbow+ batch,
  first rebirth, or the 10-minute gift), never rewarded (Roblox rules), never repeated once answered.

## Ownership / process

One writer per file; shared tables additive. TycoonService / ProfileLogic / Remotes / AnalyticsConfig
/ KeySpec are touched by several builders → re-read before each edit, add, never rewrite. Lead owns
Hud.luau, ScreenManager, HintBar, VersionConfig, ChangeNotesConfig, the system doc. Every system:
server + full UI + analytics + admin + tests + docs + device captures (re-runnable runner).
