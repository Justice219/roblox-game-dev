# Juice pass (owner R71)

> "just make the game more fun too. Just like not necessarily change the first valley or anything
> like that. Just like better sound effects, more visual effects … retention max."

Cosmetic only. Nuke Town's areas, pads, prices and pacing are unchanged. Every effect is pooled,
budgeted by `Tycoon/Fx/FxQuality` (Low / Mid / High) and Reduce Motion aware: no shake, camera
punch, flash or moving bursts with Reduce Motion on, but sounds stay. Tunables live in
`src/shared/Config/JuiceConfig.luau`, and the pure maths is in `Client/Tycoon/Fx/JuiceRules`
(Lune: `tests/juice.luau`).

## 1. Audit (before the pass)

| Moment | Before | Weakest part | Added |
|---|---|---|---|
| Click a producer | `producer_pop` + a 2D press burst (ButtonFeedback) | no rhythm reward | combo ladder (§2) |
| Buy a pad | squish + `pop` + `kaching`, build-in sparkles | flat pop | layered `pad_buy` + tumbling cash burst |
| Upgrade | `upgrade` press sound only | nothing in the world | soft gold glow + sparkles |
| Milestone (25 / 50 / 100 …) | the billboard badge changed silently | **no feedback at all** | centre banner + `milestone` ding + confetti |
| Manager hired | nothing (the `manager_hired` key was never played) | silent | puff + `manager_hired` |
| Area unlock | `fanfare` + two confetti bursts | no scale | fireworks + camera punch |
| Rebirth | music sting only | no visual | soft flash + fireworks + punch (+ sting for world rebirths) |
| Finale statue | normal build-in | no payoff | confetti cannon + fireworks + fanfare + punch |
| Idle income | coin fly to the HUD (R46) | static machines | ambient income sparkles |
| Hatch | HatchRevealScreen sounds + stage | fine | (unchanged) |

## 2. Click combo (`Fx/ClickCombo`)

Each press on one of your own manual producers that comes within `Combo.Window` (0.7 s) of the
last one chains the combo. Presses on a producer still mid-cycle count too. Early cycles last 1 s,
so counting only accepted clicks would never chain, and the combo is about the player's rhythm
(decision R71). The combo has no economy effect and sends nothing to the server.

- **Sound:** `combo_tick` climbs one semitone per press, from 1.0 up to a 1.6 cap
  (`JuiceRules.comboPitch`). It plays on top of `producer_pop`, so you still hear the press that
  really started a cycle.
- **Label:** from x2 on, a pooled BillboardGui shows "x12!" just under the producer's "+$X" pop
  start. IncomePops already places that point off the billboard's outer side (R32), so the label
  never covers billboard text. QA on 2026-10-31 found that a label on the producer body sat on a
  low billboard's text. If the pop point is more than 40 studs from the producer (its billboard is
  not placed yet), the label sits 2 studs above the anchor instead. It punches on each press and
  fades 0.9 s after the last one.
- **Every 10 presses:** a sparkle ring (a Disc emitter on a pooled invisible part).
- **At 25 / 50 / 100, then every 100:** a confetti burst plus `coin_burst`. From 100 on, a small
  camera punch is added.

Hook: one line at the top of `ProducerBillboards.click`, so it covers taps, clicks, keys and the
gamepad.

## 3. Celebrations (`Fx/JuiceController`, `Fx/ProducerJuice`, `Fx/JuiceBanner`, `Fx/Fireworks`)

| Trigger | Source of truth | Effect |
|---|---|---|
| Pad bought near you | `WorldFxController.PadPressed` (new signal, after the range check) | cash sprites tumble out of the pad, plus sparkles. `pad_buy` replaces the plain `pop` |
| Producer upgraded | own anchor `Level` up (not 0→1) | pooled Highlight glow (soft gold, about 0.55 s) + sparkles, ≤ 1 per producer per 0.25 s |
| Milestone crossed | `JuiceRules.milestoneCrossed(old, new, MilestoneEvery)` | banner with the producer name, "LEVEL 50!" and "x2 SPEED!" (cyan) or "x2 CASH!" (green), `milestone` ding, confetti. A speed milestone whose cycle already sits at the floor says CASH |
| Manager hired | own anchor `Automated` false→true | puff + sparkles + `manager_hired` (3D) |
| Your area unlocked | `BuildFinished`, `isAreaBase`, `isBuyer` | fireworks over the area (2/4/6 rockets) + camera punch 0.6 (the fanfare stays in WorldFxController) |
| Your finale statue | `BuildFinished`, pad = any world's `economy.FinalePadId` | 3 confetti-cannon volleys, fireworks, `fanfare`, punch 0.7 |
| Rebirth (any world) | `JuiceRules.rebirthTotal(profile)` rises | soft white flash (peak opacity 0.55), fireworks in front of you, punch 0.8. A world rebirth also plays the rebirth sting |

**Banner placement.** The banner is a non-modal screen at display order 16. It sits just under the
HUD's published `Top` zone, so it never covers the cash counter on phones. The flash is its own
full-bleed screen.

**Fireworks.** There are 8 pooled rockets. Each whistles up (`firework_whistle`) on a sparkle
trail, then pops (`firework_pop`) into a candy-coloured spark ball. With Reduce Motion, you get
one sparkle burst and the pop instead.

## 4. Camera punch (`Fx/CameraPunch`)

`CameraPunch.punch(strength)` adds an FOV kick (7° at strength 1) and a tiny shake (0.22 studs)
for 0.45 s.

- **Render step:** one BindToRenderStep at `Camera + 1`, bound only while a punch is running.
- **FOV handling:** the kick is additive and tolerant of other writers. If another system set the
  FOV, that value becomes the base.
- **When it runs:** only on the gameplay camera (`CameraType Custom`). It is a no-op with Reduce
  Motion.

## 5. Ambient (`Fx/ProducerJuice`)

Gentle income sparkles rise over your automated producers.

- **Which producers:** a 1 Hz thread re-ranks the nearest automated own producers within 90 studs
  of the camera. Their positions come from the cached anchors.
- **Budget:** pooled steady-rate emitters move onto the top 2 / 4 / 6 producers, by FxQuality tier.
- **Reduce Motion:** the sparkles are off.

## 6. Performance

- **Heartbeat:** there is one, `Fx/JuiceLoop`. It is connected only while a combo label, glow or
  rocket is animating, and it disconnects itself when all steps report idle.
- **No per-frame allocation:** no Instance.new per frame. Every emitter, label, Highlight and
  rocket is pooled and built on first use.
- **Pool sizes:** coins 3, puffs 2, rings 2, ambient ≤ 6, rockets 8, labels 2, glows 2.

The tunables are in `JuiceConfig`, and `tests/juice.luau` checks the caps.

## 7. Sounds

See `docs/audio.md` §8 for the R71 sound set: ForgeGUI set `forge`, takes picked by measurement,
provenance in `assets/audio/forge-sfx/manifest.json`.

## 8. Verification (2026-10-31)

`tools/qa/juice.py` and `juice_client.luau` run one solo playtest while holding the Studio lock.

**Default run.** It covers a 60-press combo, a real UPGRADE press, the banner (device matrix), pad
coins, the rebirth fireworks, the finale cannon, and idle. All five checks passed:
- juice booted (10 own producers watched)
- the combo chained (24 to 26 when read)
- the banner shows
- the rebirth put 5 to 8 rockets in the air with the punch active
- at idle the juice Heartbeat and the punch binding are both gone

**Showcase run** (`JUICE_MODE=showcase`). It runs 18 s of combo, coins and fireworks on the
nearest own producer in view, captured on desktop and phone.

**Capture notes:**
- `capture_device_matrix` switches the device first and lands about 1–2 s after the request, so
  one-shot effects need the showcase loop.
- It does not draw AlwaysOnTop billboards. The "+$X" income pops are missing from every capture
  too. The QA turns AlwaysOnTop off on the combo labels just for its shot.
- A character teleported by the probe is snapped back by the server movement checks, so the
  showcase uses whichever producer is already in view.

**Captures** in `docs/verification/juice/`:
- `banner-{desktop,phone,tablet,console}.jpg`: under the currency stack on every device, clear of
  the left button grid
- `showcase-desktop.jpg`: the "x43!" label beside the Nuke Stand billboard, outside its edge, and
  cash sprites tumbling from the pad-buy burst

The fireworks were verified through engine state only: rockets in the air, then the loop
disconnecting. Their apex is above the follow camera's view.

## 9. Lucky Wheel spin juice (owner R81, W-wheel, 2026-10-31)

Owner: "spin needs like a ticker effect and more effects. It's just kind of boring."
Presentation only. The server still rolls and pays at once (LuckySpinService); the client lands
on the server's slice.

| Piece | File |
|---|---|
| Driver (one `PreRender` connection, only while something moves) | `Screens/LuckyWheel/WheelFx.luau` |
| Pure maths (spin curve, peg crossings, flapper spring, envelopes) | `Screens/LuckyWheel/SpinMotion.luau` |
| Drawn once: pegs, bulbs, flapper, glow wedge, motion arcs, rays | `Screens/LuckyWheel/WheelDrawing.luau` |
| Every tunable | `Shared/Config/LuckyWheelFxConfig.luau` |
| Tick sound | AudioConfig alias `wheel_tick` → `combo_tick` |
| Tests | `tests/lucky-wheel-fx.luau` |

Decisions:
- **Ticker.** There is one gold peg on every slice edge (`PerSlice` must be odd), and the wheel
  always rests halfway between two pegs.
  - The pointer is a flapper. It lives in a CanvasGroup whose centre is the hinge, because Roblox
    ignores the arrow head's ClipsDescendants under a rotated Frame.
  - A peg within 9° pushes the flapper up to 26°, then a damped spring snaps it back.
  - Each peg plays one tick. Pitch runs 0.86→1.42 and volume 0.75→1.1 with speed. Ticks are at
    least 45 ms apart, so a fast spin rattles.
- **Spin curve.**
  - It starts with a wind-up: 16° back, a tremble that covers the request round trip, and the
    flapper pressed against the peg.
  - It then launches in 0.22 s and slows with ω ∝ (1−u)^1.6. The ticks space out by themselves,
    and the last one lands 0.2–1.2 s before the stop.
  - It overshoots 2.5° and rocks back. The total still equals `SpinAnimationSeconds`.
  - A press within 8 s of the last landing is a quick spin: 3 turns at ×0.62 length, for the
    2x / 5x / 10x bundles.
- **Bulbs.** 23 bulbs on the rim (the top one sits under the pointer). The idle chase runs through
  OfferFx and parks on Low graphics and with Reduce Motion. While spinning, the chase speed follows
  the wheel speed. On a win, the bulbs blink in the slice's colour.
- **Win.** The celebration is sized per slice tier: small, medium, big, rare (EGG) or jackpot
  (RARE PET). It includes:
  - the glow wedge and rays behind the wheel
  - pooled HatchConfetti confetti and sparkles
  - a shake
  - the pop: the slice icon over the hub and "You won …!" below it, so the glowing slice stays
    visible
  - a sting from existing sounds: claim, then ka-ching, then coin burst, then fanfare + fireworks.
    Rare and jackpot also play the Hatch rumble.
- **Layering.** The wheel root has ZIndex 0, so every FX layer draws below the title, message, SPIN,
  X and bundles. Nothing is Active or Selectable.
- **Settings.** Low graphics drops the arcs and rays and uses 35 % confetti. Reduce Motion snaps the
  disc and shows a static celebration.
- **Closing.** Closing the screen settles everything at once: no celebration, but the toast still
  shows.
- **Studio-only QA hooks** (gated by `RunService:IsStudio()`):
  - wheel-root attribute `DebugHold` freezes the FX clock
  - `FxDriving` mirrors whether the driver is connected
  - the `DebugPreview` BindableEvent plays the real presentation onto a fixed slice, with no
    server call
- **Verification.** `STUDIO_LOCK_OWNER=W-wheel python3 tools/qa/lucky_wheel.py` writes
  `docs/verification/r81-wheel/`. Captures are still pending, because the Studio MCP had no peer
  connected during the build.
