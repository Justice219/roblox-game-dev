# Movement: run speed and the wind effect

Owner request R21 (2026-10-30): *"make the player run faster, they feel a little too slow, and add
like a wind effect on the screen."*

## Run speed (server)

`src/server/Services/MovementService.luau` (feature service `MovementService`) sets every
character's Humanoid on spawn:

```
WalkSpeed = clamp(BaseWalkSpeed × ∏ active multipliers, MinWalkSpeed, MaxWalkSpeed)
JumpPower = MovementConfig.JumpPower   (UseJumpPower = true)
```

| Setting (`src/shared/Config/MovementConfig.luau`) | Value | Note |
|---|---|---|
| `BaseWalkSpeed` | 27 | Roblox default is 16; tycoons of this genre run ~24–30 |
| `JumpPower` | 55 | Roblox default 50 |
| `Passes.FastWalk` | ×1.35 | 36.45 studs/s with the pass; re-applied on `MonetizationService.PassChanged` |
| `BoostWalkMultipliers` | `{}` | boost key → multiplier; empty because today's speed boosts are PRODUCTION speed |
| `MaxSourceMultiplier` / `Min/MaxWalkSpeed` | 3 / 8 / 60 | caps on any stack |

Sources stack multiplicatively: owned passes, active boosts listed in `BoostWalkMultipliers`
(read from `BoostService.secondsLeft`, guarded lazy require; checked every 5 s only when the list
is non-empty), and server sources set with `MovementService.setMultiplier(player, sourceId, value?)`
(admin tools, future events; ≤ 16 per player, nil clears).

Authority: the server writes the values; they replicate to the owning client. If another server
script changes WalkSpeed / JumpPower, MovementService puts its value back (deferred, one pair of
property connections per humanoid). Client-side writes never replicate to the server; a physics
speed anti-cheat is out of scope (R21 brief).

API: `MovementService.refresh(player)`, `setMultiplier(player, sourceId, value?)`,
`walkSpeedOf(player)`.

## Wind effect (client)

`src/client/Movement/WindController.luau` (controller `Movement/WindController`) with the pure math
in `WindLogic.luau`. Intensity 0..1 comes from the character's horizontal speed: 0 at or below
6 studs/s, 1 at 26 studs/s (so base running is full wind), exponentially smoothed (attack 4/s,
release 6/s). Nothing shows or plays when standing still, seated or dead.

- **Speed lines**: a fixed pool (14; 8 on phones / consoles) of thin tapered white streaks (Frame +
  UIGradient, no image assets) in an elliptical band at the screen edges (55–105 % of the
  half-size), sliding outward and fading in / out, max 35 % opacity. ScreenGui `WindLines`
  (DisplayOrder -20: below the HUD and every screen), disabled when idle. The centre stays clear.
- **Wind particles**: one invisible non-colliding part 6 studs in front of the camera with a
  ParticleEmitter (built-in sparkle texture, velocity-parallel streaks) blowing opposite to the run
  direction; up to 14 particles/s (6 on phones / consoles).
- **Whoosh**: `Client/Audio/Sound.play("whoosh")` (existing key) once when the player gets up to
  speed (intensity ≥ 0.6), re-armed below 0.2, at most every 3 s; muted by the SFX setting.
- **Reduced motion**: `profile.settings.reducedMotion` or the platform's
  `GuiService.ReducedMotionEnabled` → no lines and no particles (polled twice a second).
- **Cost**: one RenderStepped connection; every Instance is created once at Start; idle frames read
  only the root part's velocity.

All tunables: `MovementConfig.Wind`.

## Tests

`tests/movement-logic.luau`: run-speed stacking / caps, intensity ramp and frame-rate-independent
smoothing, speed lines stay in the edge band and point outward, fade rules, whoosh trigger /
re-arm / cooldown.

## Boot entries

- Server: feature service `"MovementService"` (after MonetizationService / BoostService).
- Client: controller `"Movement/WindController"` (after `Audio/SoundController`).
