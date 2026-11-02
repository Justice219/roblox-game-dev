# SellNukes audio

Cheerful, kid-friendly background music per place, a full set of original toy-like sound effects,
and one API every system calls. Built for phones and consoles first (owner R11): small memory, no
per-frame work.

## 1. Using it (every system)

```lua
local Sound = require(Players.LocalPlayer.PlayerScripts.Client.Audio.Sound)
Sound.play("ui_click")                                   -- 2D (menus, your own events)
Sound.play("cash_big", { position = pad.Position })      -- 3D, distance-attenuated
Sound.play("upgrade", { pitch = 1.1, volume = 0.8 })     -- multipliers on the key's settings
```

Never create `Sound` instances. Ask for a new key instead (AudioConfig + a synthesised sound, §4).

| Group | Keys |
|---|---|
| UI | `ui_click` `ui_hover` `ui_open` `ui_close` `ui_claim` `ui_locked` `notification` |
| Cash | `cash_small` `cash_medium` `cash_big` (ka-ching tiers); `cash_small` at 0.35 volume, pitch 1.15 → 1.6 is the HUD coin-landing tick (`UI/Hud/CurrencyFly`, gems land with `sparkle`) |
| Progression | `producer_pop` (cycle paid) `upgrade` `manager_hired` `area_unlock` (alias of `fanfare`) |
| Pets / crates | `hatch` `crate_open` |
| Attack mode (cartoon) | `nuke_launch` `nuke_whoosh` (falling slide-whistle) `nuke_boom` (confetti "poof", never a realistic blast) |
| Event | `turkey_gobble` |
| Build-in / world FX | `clack` `whoosh` `sparkle` `kaching` `pop` `fanfare` (played by BuildIn / WorldFx via `FxSound`) |

`SoundController.playSting("rebirth")` plays the rebirth fanfare (automatic on a rebirth).
`SoundController.setOverride("event" | "hub" | "early" | "late" | nil)` lets a screen force a
music context.

## 2. Music

`SoundController` (boot path `Audio/SoundController`) picks a context every second from the
character's position. It never runs per frame.

| Context | Where | Playlist (SoundAssets.Music) |
|---|---|---|
| `hub` | hub plaza (radius 230 + 30) | Sparkling Clean · Carefree Living |
| `event` | hub plaza while `HarvestFeastActive` is true | Country Romp · Good Times Ahead |
| `early` | a plot, rows 1–2 (areas 1–4) | Funtime Festival (a) · Summer Shenanigans |
| `late` | a plot, rows 3–5 (areas 5–10) | Up For Anything (no shouts) · Funky Escapade |
| (sting) | rebirth | Sends Us Soaring (d), 8 s, ducks the music |

- **Crossfade:** context changes crossfade over 2.2 s between two Music-group Sound instances. A
  finished track advances the playlist. Ring road and wedges keep the current context.
- **Licence:** every track is from Roblox's licensed **APM Music** library, published by the
  verified `APMOfficial` Creator Store account. All are free and usable in any Roblox experience.
  Ids, titles, artists, albums and durations were checked with the Studio MCP `get_asset_details`
  and are recorded in `src/shared/Config/SoundAssets.luau`. Only ever add APMOfficial (or another
  Roblox-licensed library) tracks.
- **Memory:** at most three music Sound instances exist (A, B, sting). Only one track streams
  except during a crossfade. With music off, the players are stopped, not just muted.

## 3. Settings

`profile.settings.music` mutes the Music group and stops the players. `profile.settings.sfx`
mutes the SFX and UI groups, and `Sound.play` skips muted groups entirely (no decode cost).
Settings are toggled through the existing `SetSetting` remote (server: ProfileLogic.applySetting)
and applied from `ClientState.ProfileChanged`.

## 4. Sound effects pipeline (original, synthesised)

```bash
python3 tools/audio/generate_world_sfx.py     # clack whoosh sparkle kaching pop fanfare  -> assets/audio/world-sfx
python3 tools/audio/generate_game_sfx.py      # 19 UI / cash / progression / pets / nukes / event -> assets/audio/game-sfx
python3 tools/audio/upload_sfx.py --user-id 1586034782 [--set world game] [--dry-run]
lune run tests/audio
```

- **Synthesis:** numpy → WAV → MP3 (LAME), with fixed seeds and no tags, so output is
  byte-identical on re-run. The game set reuses the world set's helpers (bells, sweeps, square
  "toy trumpet", band-passed noise).
- **Upload:** through `snkit.cloud` as Audio. The journal is written before each POST, receipts are
  hash-bound, the per-set lock waits, and unchanged sounds never re-upload.
- **Ids:** `upload_sfx.py` rewrites the generated `SFX_IDS` block of `SoundAssets.luau` from all
  receipts.
- **Playback rules:** set per key in `AudioConfig.Sfx`: group, volume, `pitchVar` (random pitch
  per play), pooled `voices`, `minInterval` (no stacking buzz), `preload` (hot keys only), and
  `range` (3D roll-off).

## 5. Runtime design

- **Groups:** `SN_Music`, `SN_SFX` and `SN_UI` SoundGroups under SoundService.
- **2D voices:** pooled per key in `SoundService.SN_Sfx2D`. When all are busy the oldest is
  re-used.
- **3D voices:** 8 pooled emitter Attachments under `Workspace.Terrain`, moved round-robin.
- **No hot-path allocation:** every Sound is created on first use and then re-used, with no
  Instance.new on the hot path.
- **Preload:** `Sound.preloadHot()` runs `ContentProvider:PreloadAsync` on the 10 hot keys only;
  the rest stream on first play.

## 6. Verification

`tools/audio/studio/audio_check_client.luau` (eval_client_runtime in a solo playtest, holding the
`B4` Studio lock) reports:
- the live context and music state, and the context-rule samples;
- the load state of every SFX key (2D, plus one 3D);
- the override crossfade (both players mid-fade) and the rebirth sting ducking;
- the music/sfx settings round-trip through the real `SetSetting` remote.

Results are recorded in `docs/verification/audio/`.

## 5. Announcer voice lines (owner R54)

Set `voice` (`assets/audio/voice-sfx`): `vo_three`, `vo_two`, `vo_one`, `vo_launch`,
`vo_direct_hit`, `vo_intercepted`, `vo_knockdown` for the launch cinematic (3-2-1 countdown +
result call-outs). Source: ForgeGUI sound-effect jobs (ElevenLabs text-to-sound), two or three takes
per line, every take transcribed locally with whisper.cpp `base.en` (`whisper-cli`, model sha1
`137c4040…`) and only takes that clearly say the words kept. A "Knockdown!" take that could be
heard as a swear word was rejected and the line regenerated as "Knocked down!". Provenance per line
(job id + take + transcript) is in `manifest.json`, written by `tools/audio/forge_manifest.py`
(was voice_manifest.py); upload with `upload_sfx.py --set voice` (same hash-bound receipts as the
synthesised sets).

Set `forge` (`assets/audio/forge-sfx`): ForgeGUI world sounds with no synthesised equivalent —
`vehicle_honk` (cartoon toy truck "honk-honk") and `vehicle_beep` (soft reversing beeper) for the
R56 vehicle routes, 3D, short range. Takes were picked by measurement (loudness-burst count +
spectral flatness for tonality), since nobody listens in the pipeline; provenance in the set's
`manifest.json`. Upload with `upload_sfx.py --set forge`.

Playback: 2D, one voice, no pitch variation. The voice lines are NOT in the join-time `preload`
set (tests/audio caps it at 12). Features warm their sounds on demand with
`Sound.warm({ ... })` (idempotent, off-thread). `Client/Attack/LaunchCam` warms all seven lines in
three cases: when the Attack picker or the Defense screen opens, when the profile shows a launcher
level or a hit taken (so Revenge is possible), and on its first play as a fallback.

`Sound.stop(key)` stops every playing 2D voice of a key. It does nothing for a key that was never
played, and positional 3D SFX are left to finish. The cinematic uses it to cut a line when the next
one starts: "three" (~1.2 s) is cut by "two" after the 1 s beat. A skip cuts the line playing at
the time. Lengths: three 1.2 s, two 1.2 s, one 0.83 s, launch 1.48 s, direct hit 1.6 s,
intercepted 1.46 s, knockdown 1.76 s. "Knocked down!" therefore waits until hit + 1.6 s
(`LaunchCamConfig.KnockdownWatch.SayAfter`) so "Direct hit!" finishes first (docs/attack.md §15).


## 7. Dino Valley (owner R57, W9)

| Key | Source | How it plays |
|---|---|---|
| music context `dino` | APM "Kids Adventure" (Kaptain, 1838632983, 104 s) + "Tiki March" (Lionel Wendling, 1838898404, 78 s), both APMOfficial verified, free (checked with `get_asset_details` 2026-10-30) | `WorldClientConfig` "music_dino_valley" -> `SoundController.setOverride("dino")` while in the Valley |
| `amb_jungle` | Pro Sound Effects "Jungle Ambience 4 (SFX)" (9114891241, 69 s; ProSoundEffects verified, free) — `SoundAssets.LibrarySfx`, added to `SfxIds` after the generated block so `upload_sfx.py` never drops it | 2D, volume 0.22, one voice, minInterval 60 (re-trigger when the bed ends) |
| `warp_whoosh` | alias -> `whoosh` | `Sound.play("warp_whoosh", { pitch = 0.8 })` on the Time Machine warp |
| `geyser_whoosh` | alias -> `whoosh` | `Sound.play("geyser_whoosh", { pitch = 0.65, position = vent })` |
| `bones_pickup` | alias -> `cash_small` | `Sound.play("bones_pickup", { pitch = 1.25, volume = 0.35 })` for Bones landing on the HUD |
| `ptero_squawk_cute`, `dino_happy_roar`, `volcano_rumble_soft` | ForgeGUI set `forge` (provenance in its manifest) | wired: courier-1 squawk (`VehicleRouteConfig` horn), Dino manager voice (`ManagerNpcConfig`), `D6_VolcanoTop` ambience (`WorldFxConfig.Ambience`) |

When a real ForgeGUI `warp_whoosh` / `geyser_whoosh` lands, delete its alias line (tests/audio
rejects a key that is both an alias and a spec).

## 8. Juice pass + Moon + Lucky Buttons (owner R71, H1)

Set `forge` (ForgeGUI / ElevenLabs text-to-sound). Takes were picked **by measurement**, since
nobody listens in the pipeline. Measurements:
- duration, peak and RMS
- onset silence
- loudness-burst count (one hit for ticks, about 3 rising dings for `lucky_spawn`)
- spectral flatness (tonal chimes)
- the loop seam and RMS steadiness for the space bed
- a whisper.cpp `base.en` no-words check

The per-key reasons are comments in `tools/audio/forge_manifest.py` FORGE_SOURCES. `combo_tick`
and `lucky_blink` are trimmed to the hit, and `moon_boing` had gain added because every take was
quiet. Upload: `upload_sfx.py --set forge`.

| Key | Plays | Where |
|---|---|---|
| `combo_tick` | 2D, pitch = combo ladder (1.0 → 1.6), no random pitch | `Fx/ClickCombo` on every manual-producer press |
| `coin_burst` | 2D | combo 25 / 50 / 100 bursts |
| `pad_buy` | 3D at the pad (replaces `pop`) | `WorldFxController` pad press |
| `milestone` | 2D ding | `Fx/ProducerJuice` milestone banner |
| `firework_whistle` / `firework_pop` | 3D per rocket | `Fx/Fireworks` (unlock, rebirth, finale) |
| `manager_hired` (existing) | 3D at the producer | `Fx/ProducerJuice`, first time it is actually played |
| `lucky_spawn` / `lucky_claim` / `lucky_blink` | 2D (blink may be 3D) | Lucky Buttons (H3) |
| `moon_boing` | 2D, your own landing | Moon low gravity (W10b) |
| `amb_space` | 2D bed, re-triggered like `amb_jungle` | Moon world (W9b) |
| `ufo_whirr` / `robot_beep` / `star_chime` / `rocket_launch_soft` | 3D, pass a position | Moon art ambience, managers and vehicles (W6–W9b) |
| `pick_clink` | 3D, range 60, one-hit "tok-tink" trimmed to 0.17 s | Glow Rock miners' pickaxe strike (owner R75, W7) |

Moon music: `AudioConfig.Contexts.moon` plays the APMOfficial "Strange Planet" + "Friendly Robot"
(the SoundAssets Music rows are W9b's), with `amb_space` underneath.

Moderation (Open Cloud `assets/v1/assets/{id}`, checked 2026-10-31): the 15 R71 keys are
**Approved**, and `pick_clink` was still Reviewing right after upload.

`JuiceController` warms the juice keys with `Sound.warm` after boot. They are not in the join
`preload` set, which tests/audio caps at 12. See `docs/juice.md`.


## 9. Moon Base music (owner R70, W9b)

| Key | Source | How it plays |
|---|---|---|
| music context `moon` | APM "Strange Planet" (John Baker, 1836774489, 94 s) + "Friendly Robot" (Johnny Pearson, 1836774293, 131 s), album QUIRKY RETRO TECH, genre "children". Both APMOfficial (user 7462718749) verified, free, audioType Music; checked with `get_asset_details` 2026-10-31 | `WorldClientConfig` "music_moon_base" → `SoundController.setOverride("moon")` while on the Moon (`AudioConfig.Contexts.moon`, added by H1) |
| bed `amb_space` | H1's ForgeGUI "calm dreamy space ambience loop" (§8) | looped under the Moon music like `amb_jungle` (`WorldClientConfig.Music.music_moon_base.bed`) |

I also considered a ProSoundEffects library bed ("Fairy Dust 2 (SFX)", 9114369767: soft chimes, verified and free). I dropped it because H1's `amb_space` already exists, and a library row would overwrite that key in `SfxIds`.
