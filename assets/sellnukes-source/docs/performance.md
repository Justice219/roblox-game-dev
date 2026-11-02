# SellNukes performance (perf pass 2026-10-30, P2)

Targets (CLAUDE.md performance rules + owner R11 console/mobile first): server heartbeat ≤ 4 ms
average, client scripts ≤ 3 ms/frame on the Low FxQuality tier, no per-frame `Instance.new`, one
RunService connection per system.

## Setup

- Solo playtest: own plot fully unlocked plus 7 copies of the same late-game plot (8 full plots).
- Server: 20.9k Workspace instances, 12.7k MeshParts.
- Client: 85k instances, 789k triangles, 2,466 draw calls, 9k PlayerGui instances.
- Tools (Studio MCP): `capture_script_profiler` (5 s at 2 kHz), `capture_micro_profiler`, Stats
  sampling, `get_scene_analysis`, `get_memory_breakdown`.
- Caveats: Studio limits an unfocused client to ~15 fps, and absolute times varied ~5× between
  runs because other agents loaded the machine, so improvements are same-session A/B results.
  Low tier was forced inside the running test (Studio blocks the quality setting).

## Server

- Heartbeat: 0.17 ms average / 0.30 ms max; 0.25 / 0.49 ms in a busier second run (target 4 ms).
- Luau: 11 ms per 5 s. `tickPlayer` costs 0.5 ms/s per player ≈ 0.07 ms/frame with 8 players.

## Network per player

| Stream | Rate | Who receives it |
|---|---|---|
| Income pops | 6.9 kbps | plot owner only |
| Profile deltas | 3.8 kbps | that player |
| Admin state | 2.9 kbps | admins only |

## Client baseline (High tier, before fixes)

Total ≈ 149 ms per 5 s (≈ 2 ms/frame).

| Hotspot | Cost per 5 s |
|---|---|
| WorldFx step | 86.7 ms (`BulkMoveTo` 74.3 ms) |
| WorldFx refresh | 16.1 ms (1.6 ms spike every 0.5 s) |
| ManagerController | 31.7 ms |
| StandClient paint | 6.7 ms |
| IncomePops | 5.0 ms |
| PetController | 4.0 ms |
| OfferFx scan | 3.6 ms |

## Fixes

- **WorldFxController + `Shared/Util/ViewCone`:** motion groups outside the camera view cone are
  skipped; far groups update every other frame; lighter refresh. Knocked-down groups (owner R50,
  `setSuspended`) are removed from the active list and never `rest()`-snapped.
- **ManagerController:** the same view-cone culling (no gain in the measured view, where all 4
  active managers were on screen).
- **StandClient:** egg stands repaint only when what they show changes, not on every cash tick.

## Results (same session, culling on vs off)

| Measure | On | Off | Change |
|---|---|---|---|
| WorldFx step | 94 ms | 195 ms | −52 % |
| `BulkMoveTo` | 120 ms | 175 ms | −31 % |
| Client total | 276 ms | 368 ms | −25 % |

- Low tier: 0.5–1.0 ms of scripts per frame (target 3 ms) ✅
- High tier: ≈ 3.8–5.4 ms per frame while the machine was busy with other agents (above 3 ms; High
  is the desktop tier, the 3 ms target is for Low).
- No per-frame `Instance.new` found.

## Next steps

- OfferFx scan reads `AbsolutePosition` for every offer on each scan: cache per layout change.
- Batch IncomePop messages (one remote per tick per player instead of one per producer).
- Lazy-build screens to cut the 9k PlayerGui instances (build on first open).

## Join loading screen — fast first minute (owner R122, 2026-11-01)

Field data (live `SellNukesAnalytics_v1`, `cp:<Class>:boot*`): client boot (LocalPlayer
`BootSeconds`, loader start → hand-off) went from ~1.6 s on phones (0.5.1) to an average of 26 s
on phones, 20 s tablets, 21 s desktop, 15 s console (0.7.1); 45 of 71 phone boots were 30–45 s —
the old 30 s `Readiness.ASSET_BUDGET`. The loader did not change between those builds; 11-01
players had far higher ping (cellular). A new player's single preload list
(`PreloadList.forClient`) was 175 mesh ids before the profile (49 hub models, ≈ 330k triangles)
and 222 with it. Roblox ranks on first-play bounce (< 60 s, 61–180 s), so the screen must not eat
the first minute.

| Tunable (`src/first/LoadingScreen/Readiness.luau`) | Before | R122 |
|---|---|---|
| `ASSET_BUDGET` (critical preload may hold the bar, from its start) | 30 s | 6 s |
| `TIMEOUT` (TAP TO CONTINUE) | 45 s | 20 s |
| `AUTO_CONTINUE` (hands off by itself) | 60 s | 30 s |
| `MIN_SHOW` | 2.4 s | 2.4 s (kept) |
| `HudFocusConfig.LoadingTimeoutSeconds` (HUD gate safety net) | 45 s (fired BEFORE the old 60 s auto-continue) | 35 s (> AUTO_CONTINUE + slack, never under a live screen) |
| `CRITICAL_BATCH` / `BACKGROUND_BATCH` / `BACKGROUND_GAP` | 8 / – / – | 8 / 4 / 0.5 s |

Critical steps (Loaded, Client, Profile, World, Plot) still gate the hand-off; only TAP TO
CONTINUE / AUTO_CONTINUE skip them. The budget cuts ONLY the Assets step.

**Preload split** (`Shared/World/PreloadList`, `tests/loading-screen-preload.luau`):

- CRITICAL (`forClientCritical(tycoon)`, the bar waits): brand art + stud texture, hot UI icons
  (IconAssets hud / currency / ui / offer), the plot frame, the locked slot, BuyPad, this plot
  (each unlocked area's base + bought builds; before the profile: area 1's base) and the builds of
  the current next pads. A new player: 87 mesh ids (frame 19, locked slot 5, BuyPad 3, area 1
  base 47, first pad 13) instead of 222.
- DEFERRED (`forClientDeferred(tycoon)`, after the critical list, across the hand-off): the
  upcoming purchases first (never instanced before they are bought, so only this warm-up makes
  their fly-in download-free), then the shared hub (already replicated; the engine fetches it on
  demand anyway), the lobby decor, the next locked area's base. Disjoint from the critical ids;
  every id of the legacy list is still preloaded by one of the two.
- ONE thread (`Loader.runPreload`, `PreloadQueue`): critical batches back to back while the bar
  waits; afterwards small batches with a pause (`Readiness.pace`), until the queue is empty or the
  player leaves. Holder instances (ImageLabel / SpecialMesh) exist per batch only and are
  destroyed right after it; the queue is released at the end. No per-frame work or allocation.

**Boot-step telemetry** (wire v4, `ClientPerfLogic`): at hand-off the Loader sets
`BootStep<step>` (each finished step's second since the loader start) and `BootEnd`
(`ready` | `budget` | `tap` | `auto`) before `BootSeconds`; ClientPerfReporter sends them with the
boot as soon as it is known (bouncing players are measured too; before R122 the boot rode the
next 20 s / 60 s tick, so players leaving earlier were never counted). Server counters per device
class: `cp:<Class>:bootStep:<step>:<bucket>` (BootSeconds buckets), `cp:<Class>:bootStepS:<step>`,
`cp:<Class>:bootEnd:<reason>`, `cp:<Class>:bootDrop` (refused block). ClientPerfIngest validates
the block strictly (finite, -1 or 0 .. boot + 0.05 s, known reasons, "ready" / "budget" need every
step) and counts the boot ONCE per analytics session (a repeat claim is stripped). Report:
`ClientPerfLogic.rows` shows the boot p50; `ClientPerfLogic.bootRows` + `BootNote` = the "Client
boot steps by device" table (per-step average + p50, hand-off shares).

**Read it** (§4 of the R122 spec): boot p50 per class and `bootEnd:budget` share on the
`build:0.8.0` days vs 0.7.1; a step whose average jumps (e.g. Plot) is the next thing to fix.
