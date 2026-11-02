# R78 §6 — first-minute fix (console / phone / tablet) — verification

Builder C-ftue, 2026-10-31. Spec: `docs/superpowers/specs/2026-10-31-r78-retention-pack-design.md` §6.
Studio: the open "Sell Nukes" place, solo playtests only, under `scripts/studio-lock.py`.
Re-run: `STUDIO_LOCK_OWNER=C-ftue python3 tools/qa/ftue_check.py` (writes the `after-*` captures +
`ftue.json`). New players are simulated with admin New Player Mode (sandbox profile, never saved).

## Evidence (live analytics `SellNukesAnalytics_v1`, day 2026-10-31, read-only)

| Signal | Value |
|---|---|
| joined / plotReady / firstPad | 22 / 22 / 15 |
| `ftue:loadingDone`, `ftue:hudShown` | **0 / 0** — allowlisted client steps that no code ever sent |
| `ftueLeft:plotReady` | 7 (console 3, phone 2, tablet 2) |
| `cp:<device>:bootS ÷ boots` | console 0.6 s, phone 1.2 s, tablet 0.7 s — **not** the loading wait (see 2) |
| Studio loading screen (test profile) | 32–33 s; a brand-new player preloads 222 assets (ASSET_BUDGET 30 s) |

## Problems found

1. **Blind funnel.** `plotReady` is set when the profile loads, i.e. while the loading screen is still
   up, and `loadingDone` was never reported, so "left at plotReady" mixed players who quit on the
   loading screen, during the reveal, on the intro card and while looking for the pad.
   `furthestStep` also ranked by save-bit index (loadingDone < plotReady).
2. **Loading time never measured.** `ClientPerfReporter` took `time()` at its start (the game was
   loaded) before the loading screen handed over, so the per-device `boot` histogram measured
   script start (~1 s), not the real wait.
3. **Blocking, wrong-order intro card** (`before-intro-modal-*.jpg`). The TycoonTutorial card was a
   modal: world blur, gameplay blocked ("Menus"), on a gamepad the character's controls are paused
   while any modal is open, the cursor sits on LET'S GO, and an extra press was needed before the
   first step. On a phone it covered ~80 % of the screen. Its step 1 said "Click the Workbench"
   while the real first step is walking onto the pad (the Workbench does not exist yet).
4. **Mouse-only words.** The chip said "Click your Workbench to make Pocket Nukes!" on a gamepad
   (the control is RT / R2, which the hint bar showed) and on touch (the TAP! button)
   (`before-step2-gamepad-console.jpg`, `before-step2-touch-phone.jpg`).
5. **Two arrows in the first minute.** The first Lucky Button spawns 45–75 s after standing on the
   plot: a floating "LUCKY BUTTON!" label + a second edge arrow during tutorial steps 1–3
   (`before-step1-console.jpg`, `before-step2-touch-phone.jpg`).
6. **Join order (returning players).** Welcome Back opened UNDER the loading screen (t = 0.9 s), the
   plot reveal waited up to 8 s for it, then swooped behind the blurred window and the walk-home
   teleport happened under it (`before-returning-welcomeback-during-reveal.jpg`).
7. **No shared pop-up order.** What's New and the notify prompt each only checked "no window open".

Verified fine: B / Back closes every window (ScreenManager CAS at High); nothing grabs
`GuiService.SelectedObject` outside a window; the TAP! / UPGRADE / x1 touch buttons sit clear of the
jump button and thumbstick on an iPhone 14; the walk-home lands 29.7 studs from the Workbench pad
with the pad on screen and the ground chevrons leading to it.

## Fixes

- **One join queue** `Platform/JoinFlow` (+ pure `JoinFlowLogic`): loading screen → plot reveal →
  queued pop-ups one at a time after a 1.5 s calm gap, highest priority first (Welcome Back 100 →
  tutorial coach 95 → What's New 50 → notify 10). During the guided tutorial steps 1–3 only
  Essential items (≥ 90) open. Welcome Back, the coach card, What's New (`pending()`) and the notify
  prompt (`isQuiet()`) use it. Verified: a Welcome Back fired during the reveal opened only after it,
  before the coach card (`ftue.json` `npmOrderOk`, `after-welcomeback-after-reveal-console.jpg`).
- **Coach card, non-modal** (`Screens/TycoonTutorial`): a short "1 · 2 · 3" strip under the currency
  stack / boost chips, in the real order (walk onto pads → make nukes with the device's control →
  upgrade & hire), never selectable, never pauses the character; it moves to the far side of the
  band when the Workbench pad is under it, leaves 3 s after the first move (14 s max), and closes
  when step 1 ends. Verified: gameplay enabled, no selection while it shows.
- **Device words** `Tycoon/TutorialText`: "Walk onto the glowing pad to build your Workbench!",
  "Press RT at your Workbench to make nukes!" (gamepad), "Tap TAP! …" (touch), "Click your Workbench
  (or press F) …" (KB/M); names come from the same `PlatformConfig` bindings + `GlyphFamily` (R2 on
  PlayStation); re-rendered on a device switch.
- **One arrow**: the Lucky Button edge arrow hides while `JoinFlow.guiding()`; the server
  (`LuckyButtonService`) does not arm a button while the player is on a guided step.
- **Finer FTUE analytics** `Tycoon/FtueTracker`: `loadingDone`, `hudShown` (now actually sent),
  `tutorialSeen` (hint genuinely visible), `firstMove` (12 studs by the player's own steering;
  teleports re-anchor), `firstScreenClosed`, plus `tutorialShown(step)` per visible step. Server:
  allowlist + once per profile + `FtueLogic.claimPlausible` on the server's own state (reveal done;
  a tutorial running; server-side character ≥ 8 studs from the entrance spawn). `Ftue.Order` gives the
  chronological reading order (report rows, `ftueLeft`, `ftueDev`). The `boot` perf histogram now
  takes the loading screen's `BootSeconds`.
- Tests: `tests/ftue-logic.luau` (move tracker, hint visibility, plausibility, queue rules, texts,
  funnel order).

## Captures

| File | What |
|---|---|
| `before-intro-modal-{phone,tablet,console}.jpg` | old blocking intro card, wrong step order |
| `before-step1-{phone,tablet,console}.jpg` | step 1 after closing it; Lucky Button label + second arrow |
| `before-step2-gamepad-*.jpg`, `before-step2-touch-phone.jpg` | "Click your Workbench" on gamepad / touch |
| `before-returning-welcomeback-during-reveal.jpg` | Welcome Back opened under the loading screen |
| `after-welcomeback-after-reveal-console.jpg` | Welcome Back now after the reveal, before the coach |
| `after-step1-gamepad-console.jpg` | coach strip + "Press RT to make nukes", pad visible, one arrow |
| `after-step1-touch-{phone,tablet}.jpg` | coach strip shifted left of the Workbench pad (pad + its arrow visible), "Tap TAP! to make nukes" |
| `after-step2-gamepad-*.jpg` | chip: "Press RT at your Workbench to make nukes!" |
| `ftue.json` | probe log: join order, NPM order, modes, walk (firstMove), step 2 |

## Open items

- Real loading time per device is still unknown until 0.6.0 data arrives (`cp:<device>:boot`
  buckets, `ftue:loadingDone` vs `ftue:plotReady`). If console / phone loads exceed ~15 s, shrink the
  new-player preload (hub tier of `PreloadList.forClient`) or `Readiness.ASSET_BUDGET` (30 s).
- The free Workbench pad's billboard reads "$0"; "FREE" would be clearer (PadBillboards).
- Roblox's onboarding funnel (`Ftue.OnboardingSteps`) is unchanged on purpose (stable Creator Hub
  step numbers); the new steps live in our own funnel.
