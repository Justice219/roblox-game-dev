# R90 — Hands-on 3D interactions (design)

Owner R90 (2026-10-31): the recorded sell games use 3D interaction elements "instead of just
strictly clicking". SellNukes' original answer: three physical, one-button interactions that make
walking around your own plot pay off. Optional bonuses on top of passive income (never required,
never taking anything away), kid-friendly, console + mobile first (ProximityPrompt hold / the
Interact action; >= 44 pt on touch; glyphs from GlyphFamily), every model Blender-built
(`tools/blender/models/*`, primitive fallback until uploaded), every purchase / placement builds
in with the fly-in, server-authoritative rewards, analytics + admin + tests + docs + captures.

## 1. Order Window (customers + carry + deliver) — builder H-orders
- A stand-side Order Window on every plot (Nuke Town; Dino Valley / Moon Base get a themed window)
  appears once the plot owns its first producer area (after the tutorial).
- Toy customers (a wind-up robot, a little alien, a baby dino — per world, Blender-built rigs that
  walk with the same lightweight client animation approach as the manager NPCs) queue up (max 3)
  with an order bubble: N nukes, sometimes a flavour (ties into R89 FlavorConfig when present), and
  a patience ring (generous, kid-friendly; an expired customer just waves and leaves — no penalty).
- Carry: producers' output trays hold a few finished nukes (visual); the Interact prompt picks one
  up (stacked in the character's hands, up to a cap), walk to the window, Interact to hand over.
  Server tracks carried count + order progress (never trusts the client), validates reach.
- Reward on completion: a tip = seconds of the player's own income (clamped, config) + 1–3 stars
  by speed; stars fill a small "Customer Fame" meter with milestone gem rewards. Quests stat
  `order` (ProgressEvents) if cheap. Big tip -> confetti + coin shower into the jar (§3).

## 2. Mega Lever — builder K-kinetic
- A giant candy-striped lever on the plot (near the stand). Hold-prompt to pull (lever arm animates,
  rumble on gamepad), cooldown in config (e.g. 10 min, shown on a billboard countdown).
- Pulling runs a Mega Batch: every built producer instantly completes one bonus cycle (server
  computes the payout from its stats, x config multiplier), nukes ride a short 3D conveyor /
  chute FX to the stand, confetti; each bonus cycle also rolls a flavour when R89 FlavorService
  exists (call its public API only).

## 3. Tip Jar — builder K-kinetic
- A glass jar on the plot that fills with coins while the owner is ONLINE and near their plot (a
  small % of income, capped at N minutes' worth, config; pacing simulator stays green). Walking
  into it (touch, no button needed; also an Interact prompt for accessibility) pays out with a coin
  burst + CurrencyFly. Order Window tips can drop extra coins in.

## Ownership
H-orders: Order Window + customers + carry (new Server/Orders/*, Client/Orders/*, OrderConfig,
Blender builders). K-kinetic: Mega Lever + Tip Jar (new Server/Kinetic/*, Client/Kinetic/*,
KineticConfig, Blender builders). Plot placement: plot-local mounts in their own configs, clear of
existing keep-out geometry, D-defense's AA slots and N-plotname's sign; additive edits only to
shared layout / PlotBuilder / ProfileLogic / Remotes / Analytics / admin files. Never touch lead
files (Hud, ScreenManager, HintBar, VersionConfig, ChangeNotesConfig, system doc) or other
builders' files (see their briefs).
