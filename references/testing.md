# Testing: check.sh, Lune suites, the economy simulator, static audits

SellNukes runs its Luau code outside Roblox Studio and treats that as the main way to verify code.
`./scripts/check.sh` runs stylua, selene, a strict luau-lsp type-check, a Studio-style bytecode
compile, and then 110 Lune suites that load the shipped modules from `src/` unchanged. Those
suites cover pure game logic, save-data migration, remote fuzzing, the whole-game economy pacing
simulator, and static audits of art, layouts and source code. No commit lands unless the script
prints `[check] ALL PASSED`. Studio playtests are separate, slow, and need a lock. Owner R132 says
an agent's own changes get code checks only. This file explains how the harness works, how to
write a suite that fits, and how to use the simulator when you re-pace the economy.

## Contents

1. [check.sh: stages and order](#1-checksh-stages-and-order)
2. [The toolchain behind each stage](#2-the-toolchain-behind-each-stage)
3. [How a Lune test loads Roblox modules](#3-how-a-lune-test-loads-roblox-modules)
4. [Test-file conventions](#4-test-file-conventions)
5. [Pure-logic modules: design code so it can be tested](#5-pure-logic-modules-design-code-so-it-can-be-tested)
6. [Fixtures and snapshot tests](#6-fixtures-and-snapshot-tests)
7. [The economy pacing simulator](#7-the-economy-pacing-simulator)
8. [Static audits that run as tests](#8-static-audits-that-run-as-tests)
9. [Every suite, by area](#9-every-suite-by-area)
10. [Adding a new suite, step by step](#10-adding-a-new-suite-step-by-step)
11. [Studio verification vs code checks (R132)](#11-studio-verification-vs-code-checks-r132)
12. [Gate discipline in a shared tree](#12-gate-discipline-in-a-shared-tree)

---

## 1. check.sh: stages and order

```bash
./scripts/check.sh          # run from anywhere; it cd's to the repo root
./scripts/check.sh --fix    # stylua src/ first. LEAD ONLY: workers format only their own files
```

| # | Stage | Command inside | What it catches |
|---|-------|----------------|-----------------|
| 1 | `[check] stylua` | `stylua --check src` | Unformatted files (tabs, 120 cols, `stylua.toml`) |
| 2 | `[check] selene` | `selene src` | Lint with the Roblox std (`selene.toml: std = "roblox"`) |
| 3 | `[check] typecheck` | `scripts/typecheck.sh` | Strict types across all of `src/` (our `tsc --noEmit`) |
| 4 | `[check] compile` | `scripts/compilecheck.sh` | Compiler limits such as "Out of local registers" |
| 5 | `[check] standalone logic` | `scripts/test-logic.sh` | All 110 Lune suites (about 100 s, measured 2026-11-01) |

The cheap stages run first, so a formatting slip fails in a second and never waits behind the
suites. The script uses `set -euo pipefail`, so it stops at the first failure. The last line is
`[check] ALL PASSED`. Anything else means the gate is red.

**Scope:** stages 1–4 cover `src/` only. `tests/` is not formatted, linted or type-checked by the
gate (25 test files are not stylua-clean right now). The only check on a suite is that it runs.
Write every suite with `--!strict` anyway so the editor shows type errors. Keep suites
straight-line, because a typo in a branch that never runs will not be caught.

## 2. The toolchain behind each stage

**`scripts/lib/tools.sh`** (sourced by every script) gives you `resolve_tool <name>`. It finds the
binary that `aftman.toml` pins, in this order:

1. `$<NAME>_BIN` (for example `LUAU_LSP_BIN`), if set and executable.
2. `~/.aftman/tool-storage/<owner>/<tool>/<version>/<tool>`. The owner match ignores case.
3. Whatever is on `PATH`.

The direct lookup exists because the aftman shims for large binaries were SIGKILLed (exit 137) on
this machine. Using the stored binary also guarantees the exact pinned version runs. Pins:
rojo 7.7.1, stylua 2.5.2, luau-lsp 1.70.1, selene 0.32.0, lune 0.10.5. `tools.sh` uses
`${!var}`, which is bash-only, so in zsh run `bash -c 'source scripts/lib/tools.sh; resolve_tool lune'`.

**`scripts/typecheck.sh`** (1) downloads `globalTypes.None.d.luau` + `en-us.json` for the pinned
luau-lsp into `.luau-defs/` (first run or `REFRESH_DEFS=1`; the "None" security level makes a
plugin-only API a type error), (2) runs `rojo sourcemap default.project.json --output
sourcemap.json` so `ReplicatedStorage.Shared...` / `script.Parent...` requires resolve, and (3) runs
`luau-lsp analyze --flag:LuauSolverV2=true --platform=roblox --sourcemap=sourcemap.json
--definitions=@roblox=... --base-luaurc=.luaurc src` (`.luaurc`: `"languageMode": "strict"`). Keep
the new solver: the legacy one widens string-literal unions on assignment.

**`scripts/compilecheck.sh`** compiles every `src/**/*.luau` with
`luau-compile --null -O0 -g2` (`brew install luau`). Studio compiles without optimisation and
with full debug info, so every local takes a register. A module with more than 200 live locals in
one function compiles fine for luau-lsp but fails in Studio. The top-level chunk counts as one
function. When that happens the whole server bootstrap hangs. The script greps for
`CompileError|SyntaxError`, and it also fails if the compiler process itself fails. If
`luau-compile` is missing, the gate fails; it is never skipped.

**`scripts/test-logic.sh`:**
```bash
shopt -s nullglob
tests=(tests/*.luau)          # ONLY top-level files are suites
(( ${#tests[@]} == 0 )) && exit 1   # an empty glob must fail, never report a fake green
for test_file in "${tests[@]}"; do "$LUNE" run "$test_file"; done
echo "[logic] All ${#tests[@]} standalone suites passed; Studio checks are separate."
```
Suites run in alphabetical order. Each one passes by exiting normally and fails on any uncaught
`error`/`assert`. Files under `tests/fixtures/` and `tests/analytics-fixtures/` are never run.
Their headers say so with a line like `Not a suite: scripts/test-logic.sh only runs top-level
tests/*.luau files.` Use the same convention for any new helper folder.

Run one suite: `lune run tests/stand-order.luau`. The `.luau` extension is optional, and you must
run from the repo root. Optional env flags: `LUNE_VERBOSE=1` echoes captured `warn` output and
offender lists; `ATTACK_REPORT=1` and `LAUNCH_CAM_REPORT=1` print tuning tables.

## 3. How a Lune test loads Roblox modules

Production modules require each other through instance paths
(`require(script.Parent.TycoonLogic)`,
`require(game:GetService("ReplicatedStorage").Shared.Util.Signal)`). Lune has no DataModel. The
loader fixtures turn those paths into file paths, so the tests run the code that ships.

### 3.1 `tests/fixtures/RobloxLoader.luau` (used by 94 suites)

```lua
local Loader = require("./fixtures/RobloxLoader")    -- relative to the TEST file
local loader = Loader.new()                            -- own module cache
local TycoonLogic = loader.load("src/shared/Tycoon/TycoonLogic")  -- relative to the REPO ROOT
```

How it works:
- **Path nodes.** `node(path)` is a table with `__path`. Indexing it walks the tree: `.Parent`
  returns the dirname, and `.X` returns `path/X`. `script` is set to the module's own node.
- **`require(node)`** loads `<path>.luau` or `<path>/init.luau` with
  `luau.load(source, { environment = env, injectGlobals = true })` and caches the result. Any
  other require target errors with `[RobloxLoader] unsupported require target`.
- **`env`** is `table.clone(require("@lune/roblox"))`, which supplies `Vector3`, `Vector2`,
  `CFrame`, `Color3`, `Enum` and the other datatypes. On top of that it sets `game`, `script`,
  `task` (`@lune/task`) and `warn`. `warn` is captured into `loader.warnings` so a test can assert
  on it, and echoed only when `LUNE_VERBOSE=1`. It also sets `Random`: Lune has none, so
  `RobloxLoader.Random` stands in. It is a deterministic LCG with `NextNumber`/`NextInteger`, so
  any jitter is reproducible.
- **`game:GetService(name)`** returns stubs. `ReplicatedStorage.Shared` maps to `src/shared` and
  `ServerScriptService.Server` maps to `src/server`. `RunService` reports Studio + server. Also
  stubbed: `HttpService:GenerateGUID` (counter GUIDs), `Players:GetPlayers() = {}` and an empty
  `Workspace`. Any other service errors with `no stub for service X`, so a hidden dependency shows
  up loudly.
- **Overrides:** `Loader.new({ MarketplaceService = mock })` (price-book) replaces or adds
  services; `loader.services` / `loader.warnings` are exposed. **Limitation:** `:FindFirstChild` /
  `:WaitForChild` on a node do not work, so pure modules require siblings as `script.Parent.X`.

Datatypes in the test itself: `local roblox = require("@lune/roblox")`, then
`local Vector3 = roblox.Vector3` / `roblox.Vector2` / `roblox.CFrame` (view-cone, hud-cluster,
zfight-audit). Values the test builds and values the module builds are the same userdata, so
`==`, `.Magnitude` and CFrame math all behave as in Studio.

### 3.2 `tests/analytics-fixtures/Loader.luau` (the server-side harness, 9 suites)

This is RobloxLoader plus what server systems need:
- `env.player(userId)` returns a fake Player. `typeof` reports `"Instance"`, and it supports
  attributes + `GetAttributeChangedSignal`, `FindFirstChild`, `Kick`, `IsA`, `GetJoinData`,
  `IsFriendsWithAsync` and `GetNetworkPing`. `env.removePlayer(p)` fires `PlayerRemoving`.
- **Controllable clocks:** `env.setTime(unix)` fixes `os.time()`, `env.setClock(s)` fixes
  `os.clock()`, and `env.advance(s)` moves both. Pass `nil` to go back to the real clock. With
  these, multi-day retention and cohort tests run in milliseconds:
  `env.setTime(DAY * 86400 + 10 * 3600)`.
- Stubs for `Players` (with signals), `DataStoreService`, `MarketplaceService`, `Stats`, and
  Roblox's `AnalyticsService`. The `AnalyticsService` stub records every forwarded call in
  `env.forwarded`. JSON goes through `@lune/serde`.
- `Loader.signal()` is a minimal Connect/Once/Fire signal; `Loader.checker()` returns `check, done`
  (`done("name")` prints `[name] N checks passed`).
- Opt-in extras, used to boot real services in `world-currency-isolation`:
  `Loader.new(overrides, { lenientServices = true })` makes unknown services resolve to empty
  tables. `env.stub(path, module)` pre-seeds the cache to replace heavy Instance modules (plot
  builders, MeshLibrary, Knockdown). `env.close()` runs every `game:BindToClose` callback so
  service loops end. `env.game` is the fake DataModel; tests set facts on it, such as
  `PrivateServerOwnerId`.

### 3.3 Other loading styles

- **Plain Lune require.** `require("../src/shared/Util/NumberFormat")` works only for a module
  with no instance-path requires (number-format, signal, view-cone, loading-screen).
- **Minimal inline sandbox.** `tycoon-logic`, `audio` and `economy-sim` build their own
  `luau.load` env. For example, tycoon-logic passes only `script`/`require` plus
  `CFrame`/`Color3`/`Vector3`. With no `game` in the env, any service call that creeps into the
  economy core fails the suite.
- **Injected seams.** Modules that touch time or the engine take their dependencies as
  parameters: `Runtime.setDeps({...})` in analytics, the injectable `scheduler` + `clock` in
  `BootRunner`, and fake `AssetService`s whose `CreateMeshPartAsync` parks the thread until the
  test finishes it (`mesh-prefetch`, `pet-models-load`). A virtual-time scheduler (`price-book`,
  `boot-runner`) never sleeps for real, so the suite finishes in milliseconds and Lune always
  exits. An earlier boot-runner slept on `@lune/task` and kept the process alive.

## 4. Test-file conventions

**Header.** Every suite starts with `--!strict` and a block comment: title + owner request
(`owner R137, 2026-11-01`) + the owner's quoted words; `Run: lune run tests/<name>` (plus flags);
**Why:** (the live data or bug behind it); and **`Proves on the shipped modules (...)`:** a
numbered list, one item per section of the file. Reviewers read the header to learn what the suite
guarantees, so keep it exactly in step with the code.

**Numbered sections.** Each list item becomes one block:
```lua
--------------------------------------------------------------------------------------------------
-- 1. The new order and its prerequisite chain
--------------------------------------------------------------------------------------------------
do
	...
end
```
`do ... end` keeps each section's locals private, which also keeps the file under the 200-local
limit. Sub-cases get numbers like `-- 9b. R129: ...`.

**Assertion helpers.** Define them at the top of the file. Each one counts checks and errors at
level 2, so the traceback points at the failing line of the test:
```lua
local checks = 0
local function check(ok: boolean, label: string)   -- 63 suites (some name it ok(), 35 suites)
	if not ok then
		error(`[stand-order] FAILED: {label}`, 2)
	end
	checks += 1
end
local function eq(actual: any, expected: any, label: string)   -- 7 suites
	if actual ~= expected then
		error(`{label}: expected {tostring(expected)}, got {tostring(actual)}`, 2)
	end
	checks += 1
end
```
Analytics suites use `local check, done = Loader.checker()` instead. Write labels as full
sentences that include the values: `` `{id} costs {ratio}x the pad before it (<= 5x)` ``. A failure
should explain itself without opening the file.

**Summary line.** The last statement is `` print(`[stand-order] {checks} checks passed`) ``. Some
older suites print `name: N checks passed`. The economy sim prints
`economy-sim (main): OK (...)`. The count shows a reviewer at a glance that a suite actually did
something (`[number-format] 1103 checks passed`).

**Test hostile input as well as normal input.** Feed NaN, ±inf, wrong types, tables, huge
strings, NUL/control characters, invalid UTF-8, unknown ids, negative or fractional integers,
and boundary values exactly at, just before and just after an edge. world-travel checks
`now = 9.999` ("just before fails") and that NaN and inf fail closed. Every remote handler and
validator suite fuzzes its arguments this way.

**Regression tests must fail on the old code.** A suite written for a bug or an owner request
encodes the exact case the old code got wrong: `stand-order` replays every old-order save prefix
through the real save path, `attack-view` §2 keeps R133's "picker shows no base" camera case, and
`analytics-recorders` §9b covers both orders of the two `PlayerRemoving` listeners. Before you
write the fix, run the new suite against the old code and watch it fail, in a scratch
`git worktree` at `HEAD` (§10), never a `git stash` in the shared tree. Put the reason in the
header's Why paragraph.

## 5. Pure-logic modules: design code so it can be tested

Split every system into:
- **pure modules**: `…Logic.luau` (60 in `src/`), `…Rules.luau`, `…Math.luau` and `Config/*`
  (for example `Shared/Tycoon/{TycoonLogic, KnockdownLogic, FlavorLogic}`,
  `Server/Retention/{DailyLogic, WheelLogic}`, `Server/Tycoon/{TycoonRules, TravelRules}`,
  `Client/UI/ButtonFeedbackRules`, `Shared/Attack/FlightMath`);
- **Instance code**: services, controllers and React screens. These wire the pure core to remotes,
  parts and UI.

A pure module has no services, no Instances and no yields. It takes plain tables and numbers, with
time passed in as `now`. Its requires are only `script.Parent.X` siblings or Config modules.
`KnockdownLogic`'s header says it outright: "No services, no Instances, no requires: plain tables +
numbers ... so tests/knockdown-logic.luau runs it unchanged in Lune". The server loop calls the
same functions every tick, so the logic under test is the logic that ships.

Where Instance code must decide something, move the decision into a pure helper:
`HudPlacement.compute` (tested on 15 device viewports in hud-cluster), `BillboardPlacement`
(billboard-clearance calls the same solver as the client), `ModelViewportLogic` (turntable
framing), `PreloadList` (loading tiers).

If a test needs to mock half the engine, the module is not pure enough. Split it first.

## 6. Fixtures and snapshot tests

| Fixture | Used by | What it provides |
|---------|---------|------------------|
| `tests/fixtures/RobloxLoader.luau` | 94 suites | The loader in §3.1 |
| `tests/fixtures/ArtWorlds.luau` | zfight-audit, glow-budget, mesh-assets | Every world from `WorldsConfig.Order`; `areaLayout(loader, world, area)` merges authored art with placeholders exactly like `Tycoon/AreaLayouts.get`; owner tags (B8a…W9b) for offender lists |
| `tests/fixtures/BillboardSources.luau` | billboard-clearance, `tools/billboards/generate-spots.luau` | Builds the client's `BillboardPlacement.Sources` offline, so the audit and the spot generator solve exactly what the client would |
| `tests/fixtures/EconomyMainSnapshot.luau` | economy-index | Generated parity snapshot of Nuke Town's economy (about 4,500 values) |
| `tests/analytics-fixtures/Loader.luau` | analytics-*, world-currency-isolation | The server harness in §3.2 |
| `tests/analytics-fixtures/AlgorithmFixture.luau` | analytics-algorithm | A hand-made 7-day range whose scorecard rows land on known verdicts (header lists each row's arithmetic) |

**Snapshot test: `economy-index` + `EconomyMainSnapshot`.** `collect` flattens every area,
producer and pad field, every lookup table, the shared tunables, and about 1,700 sampled
`TycoonLogic` results (output, cycle, click, costs, max-affordable, idle, offline, rebirth). Each
becomes a string `key -> "n:<%.17g>"`, and the suite compares them bit for bit with the frozen
module. This is how the worlds framework proved that Nuke Town did not change.
After an **intentional** retune, refresh it with `lune run tests/economy-index.luau
--update-snapshot` (sorted keys, readable diff), say so in the commit message, and add a row to
`docs/economy.md` "Snapshot refreshes" (date, request, how many values changed and which); the
generated file's header lists every refresh too. **Never refresh the snapshot to silence a diff you
cannot explain.** That diff is the bug report.

## 7. The economy pacing simulator

`tests/economy-sim.luau` (about 1,200 lines) plays the whole game against the **real**
`TycoonConfig`, `TycoonLogic` and `RebirthConfig`, so a config change that breaks pacing fails the gate.

**How it simulates.** It is event-driven. Income is constant between purchases, so the sim jumps
straight to the moment the next chosen purchase becomes affordable. That is exact, and about
1000x faster than ticking every second. A full world runs in about 0.35 s.
- **Clicking:** before a producer's Manager is hired, the player clicks it. Manual income is
  `clickValue / (clickCycleTime + ReactionSeconds 0.25)`. Only the newest producer is ever manual.
- **Walking:** `PadWalkSeconds 3`, `AreaWalkSeconds 4` per area (cap 12 s); clicking pauses.
- **Choice:** goal pads (builder, Manager, Feature, Unlock) are beelined. Otherwise the player buys
  whatever has the best `cost / income + cost / gain` among: +1 level, "to the next milestone",
  and the next 1..3 pads as a bundle.
- **Lifts:** the expected flavour lift is
  `FlavorLogic.expectedMultiplier(FlavorConfig.PacingLuck)` (about +7 %, R89). The Mega Lever +
  Tip Jar lift (R90) applies from `KineticConfig.UnlockArea`. Pass `--no-flavor` or `--no-kinetic`
  to compare without them.
- **Run 2:** after one rebirth, tokens are spent cheapest-first on clickPower, managerSpeed,
  startingCash and rebirthPower. Run 2 must take `<= SIM.Run2MaxFraction` (0.85) of run 1.
- `MaxSimSeconds` (40 h) and `MaxDecisions` exist so a broken config fails instead of hanging.

**Pacing targets** live in `TycoonConfig.Pacing`:
```lua
TycoonConfig.Pacing = { TargetMinutes = { 8, 15, 25, 35, 45, 50, 60, 70, 80, 90 }, Tolerance = 0.2 }
```
Each area must land within ±20 % of its target, measured in minutes from opening the area to
buying its Unlock pad. Other worlds (`--world dino`, `--world moon`) bring their own targets
through `WorldsConfig` / `TycoonLogic.forWorld`. With no `--world`, `check.sh` runs Nuke Town
followed by every world in `WorldsConfig.Order`.

**OPENING_CHECKS** guard the first minutes, where most players leave. The table maps a world to a
list of `{ area, firstManagerMinutes, maxPadGapSeconds, earlyMinutes?, earlyGapSeconds? }`:
```lua
main = {
	{ area = 1, firstManagerMinutes = 1.5, maxPadGapSeconds = 85, earlyMinutes = 2, earlyGapSeconds = 45 },
	{ area = 2, firstManagerMinutes = 2.0, maxPadGapSeconds = 150 },
	{ area = 3, firstManagerMinutes = 3.0, maxPadGapSeconds = 300 },
}
```
That is: first Manager by minute N, no wait between pads over N s, and (early cadence) no stretch
without a new pad in the first N minutes. Output: `Opening (area 1): first Manager at 1.22 min (limit 1.5), ...`.

**Commands:**
```bash
lune run tests/economy-sim.luau                      # every world (what check.sh runs)
lune run tests/economy-sim.luau --world dino         # one world
lune run tests/economy-sim.luau --timeline           # + every pad purchase with time and income
lune run tests/economy-sim.luau --tune               # dry run: print tuned SCALE / baseRevenue
lune run tests/economy-sim.luau --tune --write       # rewrite `local SCALE =` / `baseRevenue =` in AreaNN.luau
lune run tests/economy-sim.luau --tune --write --upto 1   # tune areas 1..n only
```
**The tuner.** The sim has its own `makeLoader(patches)` that rewrites the `SCALE` and
`baseRevenue` lines of an area's source in memory, so it can try many values without touching
disk. For each area in order, built on the already-tuned earlier areas:
1. It sets `baseRevenue` from the arrival income (`SIM.StartFraction = 0.01`).
2. It bisects `SCALE` toward the target length.
3. If that SCALE breaks the area's OPENING_CHECKS, it scans a geometric grid and keeps the passing
   SCALE closest to the target. The limits are not monotone in SCALE, because one price crossing a
   level milestone flips which pad is bought first.

For non-main worlds it also rewrites the `local STASH_VALUES = { ... }` line of
`<Name>Rebirth.luau`. After `--write`: re-run without `--tune`, eyeball `--timeline`, run stylua on
the area files, refresh the snapshot (§6), and update the tables in `docs/economy.md`.

**How the R122 / R130 / R137 re-paces used it.** Each one went: live data → reorder → sim → a
regression suite → snapshot refresh.
- **R122 (Garage Lab).** Players hand-clicked about 11 minutes before Uncle Atom (the first Manager,
  pad 7) and tutorial step 6 → 7 lost 74 %. Uncle Atom moved to pad 4; `--tune --write --upto 1`
  re-paced area 1 only so later prices held. Added the area-1 OPENING_CHECKS row and
  `garage-lab-order.luau`. Snapshot: 53 values changed.
- **R130 (BoomDash).** The Dispatcher was pad 8 after a 6:20 wait; 4 of 41 players reached the next
  area. Dispatcher to pad 4, SCALE 22,100 → 25,000, the area-3 row, `boomdash-order.luau`.
  Snapshot: 95 values.
- **R137 (Garage Lab opening + Nuke Stand).** About 50 % of first sessions ended within 3 minutes.
  Added `earlyMinutes = 2` / `earlyGapSeconds = 45` ("something new every 20–40 s"), cut the Tool
  Wall from $42 to $11, moved the Cashier Bot to pad 4 (area-2 row, `stand-order.luau`) and switched
  the tuner from pure bisection to the grid. A scratch harness around the real sim (about 35,000
  runs) chose the pad multiples; income at each Unlock stayed the same, so later areas play exactly
  as before. Snapshot: 70 values.

**Rules:**
- Pad, producer and shop ids are SAVE DATA. Reorder through `requires` and costs only, never by
  renaming.
- Every reorder ships a `<area>-order` suite that replays each prefix of the old buy order through
  `toSave -> migrate` and proves every owned pad, level and the cash survive, owned pads are refused
  as `"owned"`, the Manager is offered, and buying what is offered always opens the next area (no
  soft-lock).
- Record every re-pace in `docs/economy.md` with before/after tables.

## 8. Static audits that run as tests

Some suites never execute game logic. They inspect data, art or source files and fail the build
when a rule the owner set is broken. Owner rules survive future art and code changes only because
of these audits.

- **Geometry audits.**
  - `zfight-audit` places every world the way the game builds it (scenes `hub`, `plot-fresh`,
    `plot-full`; another world's scenes are prefixed `dino:`). It reads the real triangles from
    `assets/blender/world/<Key>.glb` and asserts there are no coplanar, same-facing overlaps and no
    curved LOD seams. Its `PENDING` table is a per-owner **ratchet**: a builder's offender count
    may only go down, and today it is 0 for every owner.
  - `billboard-clearance` asserts that a producer billboard never covers its producer or manager.
  - `glow-budget` keeps every light under the owner's R19 caps.
- **Layout contracts.** `area-layouts`, `hub-layout`, `valley-layout`, `moon-hub-layout` and
  `world-frames` check that anchors exist in `MeshAssets`, slot frames are right-handed and inside
  their plots, nothing overlaps, worlds are at least 3,000 studs apart, and `WorldLayout` without a
  worldId still matches the pre-framework formulas.
- **Removed-feature guards.** `hub-no-teleport-pads` (R134) proves the removed pads stay removed,
  both in layouts (no `*_TeleportPad` placements, no `PlotTeleportPads` anchors) and in source
  (`HubBuilder`, `PlotService`, `WorldService` have no portal wiring). Its `code(path)` helper strips
  `--[[ ]]` / `--[==[ ]==]` blocks and `--` lines first, so a comment that mentions the removed names
  cannot trip the check; a cheap raw `string.find` runs first, and a recursive `luauFiles("src")`
  scan finds any reader. It also checks the replacement routes (TeleportHub / Area / Plot) still
  exist on both sides.
- **Config validators.** `change-notes` (strict semver, `ChangeNotesConfig.validate()`, and
  **TRUTH** checks that every number the notes claim still matches config); `worlds-config`
  (registry invariants, unique ids and currencies); `economy-index` (`EconomyIndex.build` rejects
  broken chains, bad prefixes, non-finite numbers); `retention-config` (every reward valid, boosts
  and icons resolve); `audio` (every Sfx key has an uploaded id and a manifest spec); `mesh-assets`
  (generated `MeshAssets` match the pipeline's on-disk truth); `platform-actions` (gamepad +
  keyboard binding for every action, no key clashes).
- **Cross-reference checks.** Configs name real screens, AudioConfig keys, MonetizationConfig
  products and analytics KeySpec ids. A typo in any of these would fail silently in game (it would
  play silence or open nothing), so the suites look each name up.

## 9. Every suite, by area

110 suites in `tests/*.luau`. `lune run tests/<name>` runs any one of them.

| Area | Suite | What it proves |
|------|-------|----------------|
| Economy | `tycoon-logic` | Every public TycoonLogic / Modifiers / SafeMath function, normal + hostile input (NaN, inf, unknown ids, offline cap) |
| | `tycoon-server-logic` | TycoonRules / TutorialLogic / ModifierSources: upgrade modes, cycle catch-up, hitch caps, reach checks, tutorial step machine |
| | `economy-sim` | Whole-game pacing per world within ±20 %, OPENING_CHECKS, run 2 ≤ 85 % of run 1 (§7) |
| | `economy-index` | Nuke Town economy bit-identical to the frozen snapshot; `EconomyIndex.build` validation; Dino index |
| | `garage-lab-order` | R122: Uncle Atom is pad 4; old-order saves migrate with no loss or soft-lock |
| | `boomdash-order` | R130: Dispatcher is pad 4; re-paced prices; old-order saves safe |
| | `stand-order` | R137: Cashier Bot is pad 4; price steps ≤ 5x; pad row layout; old-order saves safe |
| | `gem-upgrade` | R86 flat gem price inside admin range; confirm/repeat windows; analytics ids |
| | `number-format` | Suffix ladder K…UCe, truncation (never rounds up), commas, money/rate/duration |
| | `flavor-logic` | R89 flavours: rarer odds / bigger multipliers, Flavour Book, deterministic rolls |
| | `big-pop` | Big Pop broadcast: payload fields, global gap, queueing |
| | `kinetic-logic` | R90 Mega Lever cooldown/multiplier, Tip Jar caps, pacing lift |
| | `lucky-buttons` | Eight kinds, weights, free/paid split, products and boosts exist |
| | `knockdown-logic` | R50 knockdown duration clamp, immunity, volley spill, tap-to-rebuild |
| Save data, net, security | `profile-logic` | Default schema exact, migrate/reconcile, NaN scrubbed with a warning |
| | `profile-store` | ProfileStore over a JSON round-tripping in-memory DataStore (sessions, failures) |
| | `profile-sync` | ProfileDelta sequence wrap, partial fields, client apply against real snapshots |
| | `validate` | Every `Shared/Net/Validate` helper fuzzed (UTF-8, control chars, metatable-proof allowlists) |
| | `remote-security` | `Remotes.fromPresentPlayer` drops late packets; failed mutations leave the profile untouched |
| | `signal` | A throwing handler never stops others; the traceback names the handler |
| | `world-currency-isolation` | R60: real services booted under Lune, so currency never crosses worlds |
| | `paid-random-policy` | PolicyService paid-random gating for wheel, packs, Turkey Lure |
| | `pets-policy` | The same gating for eggs and crates |
| | `price-book` | Product price cache on a virtual clock: backoff, refresh |
| | `plot-name` | RenamePlot parse: trimming, fuzzing, invalid UTF-8, length caps |
| Admin | `admin-auth` | `decideAdmin` full truth table against an independent oracle |
| | `admin-pipeline` | Re-auth → allowlist → cooldown → schema → pcall → audit, with fake deps |
| | `admin-validate` | Every built-in command's argument schema, per-key fuzz |
| | `admin-new-player-mode` | New Player Mode rules: purchases refused, analytics diverted |
| | `admin-new-player-quick` | R67 header button reuses existing audited commands |
| Analytics | `analytics-logic` | Key sanitising, day math, counter caps, pure `mergeStored` (retry-safe) |
| | `analytics-recorders` | Runtime / Sessions / Recorders / Revenue / KeySpec with fake players and clock |
| | `analytics-store` | Flush merges, failed updates requeued, receipt journal |
| | `analytics-report` | Headlines, sections, report parse/toText |
| | `analytics-algorithm` | R122 Roblox algorithm scorecard rows and verdicts on AlgorithmFixture |
| | `analytics-roblox-signals` | Roblox bounce buckets, play days, co-play, qualified sessions |
| | `analytics-client-perf` | Client perf buffer encode/decode, hostile payloads rejected |
| Retention, social, monetization | `retention-config` | Every daily/time/wheel/code/pack reward valid, icons and boosts resolve |
| | `retention-logic` | Daily streak, time gifts, wheel, codes, clock-skew safety |
| | `return-notify` | R122/R136 return notifications: queue, sender, status buckets |
| | `return-notify-prompt` | Opt-in card moments, admin section logic |
| | `rewards-hub` | R62 rewards hub: features, badges, layout |
| | `gift-ladder` | R89 early gift ladder timings, deterministic rewards |
| | `quest-logic` | R78 goals, missions, XP against the spec |
| | `pass-logic` | Nuke Pass catalogue, tiers, XP |
| | `social-logic` | R78 Rush + Friends saved-record repair, overrides |
| | `invite-surface` | R122 HUD INVITE + one invite moment per session |
| | `purchase-focus` | R122 Robux prompts never open by accident (walk-in, console focus, one-tap) |
| | `event-logic` | Harvest Feast window math, sticker weighting |
| | `event-badges` | Badge catalogue and qualification from profiles |
| | `leaderboard-logic` | Order-preserving log-encoded cash board, count boards |
| | `happy-hours` | R89 schedule boundaries, pickups, R138 phone chip |
| | `player-titles` | R73 titles: priority, catalogue, profile |
| | `change-notes` | Semver, notes validation, TRUTH vs config, auto-show rule, frozen notes |
| Pets | `pets-logic` | 76 pets, 16 eggs, odds sum to TotalBp, save-safe ids, HardCap |
| | `pets-crates` | Supply crates: weights, pity, rewards resolve |
| | `pets-follow` | Formation behind the owner, spacing, symmetric rows |
| | `pet-index` | Index milestones, gems, bonus |
| | `pet-anim` | Every species rigged from MeshAssets; idle/walk/sleep under hostile frame times |
| | `pet-models-load` | Template download concurrency and order, failure warned once |
| | `hatch-anim` | R49 hatch timelines per rarity × fast × reduced motion; real SFX keys |
| Attack | `attack-logic` | AttackRng determinism, flight math, intercepts (`ATTACK_REPORT=1`) |
| | `attack-aim` | R50 aiming scatter and knockdown rewards, R51 test bots |
| | `attack-rivals` | R43 rival factories + Q2 security fixes |
| | `attack-defense` | R80 AA towers: buy and upgrade, profile clamp |
| | `attack-view` | R104/R133 picker shows the target's base, R105 boards, R106 tower animation |
| | `launch-cam` | R54 launch cinematic sweeps (`LAUNCH_CAM_REPORT=1`) |
| Worlds | `worlds-config` | Registry invariants, unique ids and currencies, link and unlock math |
| | `world-frames` | World-aware WorldLayout; main parity; separation |
| | `world-travel` | `TravelRules.check` full truth table, cooldown edges fail closed |
| | `world-client` | Per-world objectives and client config |
| | `world-gravity` | Gravity scale per world: clamps, junk rows → 1 |
| World art and layout | `zfight-audit` | No coplanar overlaps or curved seams in any world (per-owner ratchet) |
| | `glow-budget` | R19 light caps on every glowing piece |
| | `mesh-assets` | Generated MeshAssets vs on-disk pipeline truth |
| | `mesh-placement` | Blender import yaw 180° and scale mapping |
| | `area-layouts` | WorldLayout frames, LayoutLogic contract, slots inside plots |
| | `hub-layout` / `valley-layout` / `moon-hub-layout` | Hub anchors, budgets, clearances per world |
| | `hub-no-teleport-pads` | R134 pads stay removed from layouts and code |
| | `billboard-clearance` | Producer billboards never cover the producer or manager |
| | `world-fx` / `world-fx-swing` | R57 Dino FX rows resolve; R75 swing curves loop seamlessly |
| | `build-in-plan` | Fly-in schedule durations and staggers for 1..400 pieces |
| | `vehicle-routes` | R56 Catmull-Rom routes: uniform speed, seamless loops |
| | `lobby` | Lobby fixtures name real anchors, screens, signs |
| | `npc-logic` / `manager-tags` | Manager NPC brain and pose; every manager key has a tag |
| | `audio` | Every SFX key has an uploaded id and a manifest spec |
| Boot and streaming | `boot-runner` | R103 boot phases on virtual time: budgets, failures, order |
| | `loading-screen` | R16 staged readiness gate, monotonic progress |
| | `loading-screen-preload` | R122 critical preload keys only |
| | `preload-list` | Preload tiers disjoint, cover every model once |
| | `mesh-prefetch` | MeshLibrary request start order and concurrency cap |
| | `view-cone` | Frustum cone limits; junk input → everything visible |
| UI, HUD, feel, platform | `hud-cluster` | HUD placement on a real phone/tablet/desktop/console matrix |
| | `hud-more` | R110 MORE flyout contents and geometry |
| | `popup-queue` / `popup-feed` | R102 popup priority; R108/R111 bottom-left feed |
| | `platform-actions` / `platform-layout` | Bindings for every input; TV-safe insets, touch placement |
| | `button-feedback` / `currency-fly` / `juice` | R22 press particles, R46 money fly, R71 combo |
| | `lucky-wheel-fx` / `shop-item-fx` / `model-viewport` | Wheel celebration tiers, R98 shop animation, R39 viewport framing |
| | `movement-logic` | Run speed stacking and caps, wind intensity |
| | `ftue-logic` | R78 first-minute guided steps and move tracker |

## 10. Adding a new suite, step by step

1. **Make the logic pure first** (§5). Put the decision in
   `src/<side>/<System>/<Thing>Logic.luau` with its tunables in `src/shared/Config/<Thing>Config.luau`.
2. **Create `tests/<kebab-name>.luau` at the top level**, because only top-level files run. Put
   shared helpers in `tests/fixtures/` (or a new `tests/<area>-fixtures/`) with a
   "Not a suite" header line.
3. **Write the header before the code.** The Proves list is the spec for the test.
4. **Write it red first.** Prove the regression fails on the code as it was:
   ```bash
   git worktree add "$SCRATCH/red" HEAD          # never stash in the shared tree
   cp tests/thing-logic.luau "$SCRATCH/red/tests/"
   (cd "$SCRATCH/red" && lune run tests/thing-logic.luau)   # must FAIL for the right reason
   git worktree remove --force "$SCRATCH/red"
   ```
5. **Implement, then go green:** `lune run tests/thing-logic.luau`.
6. **Format the test yourself.** The gate does not format it: run `stylua tests/thing-logic.luau`
   (only your own file).
7. **Run `./scripts/check.sh`** and wait for `[check] ALL PASSED`.
8. **Document it.** Add the suite to the system's doc and to `SELLNUKES_CLAUDE_DOCUMENTATION.md`
   (the Tests column of the system table). Commit only your hunks (§12).

Minimal skeleton, based on `knockdown-logic` / `stand-order`:
```lua
--!strict
--[[
	Thing rules (owner R140, 2026-11-02: "quoted owner words"). Run:
		lune run tests/thing-logic

	Why: <live data or the bug — what the old code did wrong>.

	Proves on the shipped modules (Shared/Config/ThingConfig, Shared/Tycoon/ThingLogic):
	  1. Config: ids unique, numbers finite and in range, every referenced key exists.
	  2. Rules: normal input, edges (exactly at / just before / just after), hostile input
	     (NaN, ±inf, wrong types, unknown ids) fails closed.
	  3. Regression: <the exact case the old code got wrong>.
]]

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local ThingConfig = loader.load("src/shared/Config/ThingConfig")
local ThingLogic = loader.load("src/shared/Tycoon/ThingLogic")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(`[thing-logic] FAILED: {label}`, 2)
	end
	checks += 1
end
local function eq(actual: any, expected: any, label: string)
	if actual ~= expected then
		error(`{label}: expected {tostring(expected)}, got {tostring(actual)}`, 2)
	end
	checks += 1
end

--------------------------------------------------------------------------------------------------
-- 1. Config
--------------------------------------------------------------------------------------------------
do
	local seen: { [string]: boolean } = {}
	for _, def in ThingConfig.List do
		check(not seen[def.id], `{def.id} is unique`)
		seen[def.id] = true
		check(def.cost > 0 and def.cost < math.huge, `{def.id} has a finite positive cost`)
	end
end

--------------------------------------------------------------------------------------------------
-- 2. Rules
--------------------------------------------------------------------------------------------------
do
	eq(ThingLogic.score(10, 10), 1, "exactly at the edge counts")
	eq(ThingLogic.score(10.001, 10), 0, "just past the edge does not")
	eq(ThingLogic.score(0 / 0, 10), 0, "NaN fails closed")
	eq(ThingLogic.score((nil :: any), 10), 0, "wrong type fails closed")
	check(#loader.warnings == 0, "no warnings on valid input")
end

-- 3. Regression (R140): the case the old code got wrong, with the live report's numbers.

print(`[thing-logic] {checks} checks passed`)
```
For server systems with players, time or DataStores, use `tests/analytics-fixtures/Loader.luau`
(`env.player`, `env.setTime`, `env.advance`, `Loader.checker()`). If the module needs a service
that RobloxLoader does not stub, pass a mock with `Loader.new({ ServiceName = mock })`. Do not
widen the shared stubs for one suite.

## 11. Studio verification vs code checks (R132)

| | Code checks (`check.sh`) | Studio checks |
|---|---|---|
| What | Format, lint, types, compile, 110 Lune suites | Solo playtest in the open place, screenshots, device matrix |
| Proves | Logic, schemas, migrations, security fuzzing, pacing, layout/art rules | Rendering, streaming, physics, real remotes, how it looks on phone/tablet/console |
| Cost | About 2 minutes, parallel-safe | Minutes per run; needs `scripts/studio-lock.py`; one agent at a time |
| Tools | `scripts/check.sh` | `scripts/studio_mcp.py` (`solo_playtest`, `capture_device_matrix`), `tools/qa/*.py` runners that write evidence under `docs/verification/<topic>/` |

**Owner R132 (2026-11-01):** "skip any studio playtests for your changes, just code checks thats
it". By default, verify your own changes with `./scripts/check.sh` only: no solo playtests, no
device-matrix captures, and a list in your report of what the owner should eyeball in Studio. This
overrides the CLAUDE.md rule-11 "capture before reporting" step, because the owner playtests live
while agents work and an agent's playtest would collide with theirs. When many builders run at once
(R92), builders deliver code, Lune tests, a green gate and a re-runnable `tools/qa/<topic>.py`
runner; only the lead runs one consolidated Studio pass, when asked. Never use
`multiplayer_playtest` (R72).

That is why so much is tested in Lune: anything decidable without the engine (placement math,
billboard spots, HUD geometry, preload tiers, camera framing) gets a pure module and a suite, and
the Studio pass only confirms the look.

## 12. Gate discipline in a shared tree

- **Run `./scripts/check.sh` and wait for `[check] ALL PASSED` before every commit.** A suite you
  did not touch still counts. `typecheck.sh` does not cover `tests/`, so when you change a fixture,
  run the suites that use it.
- **Several sessions edit this tree at once.** A red gate can come from another builder's
  in-progress files, such as half-formatted `AttackService.luau` or a type error in their WhatsNew
  screen. When that happens:
  confirm the failure is in files you did not touch (`git status --short`); do **not** edit,
  format or revert them (never `--fix` the shared tree); prove your part green (your suites,
  `stylua --check` on your files, the full gate in a scratch `git worktree` with only your changes);
  then report it plainly ("check.sh stops at stylua on `AttackService.luau`, another builder's
  in-progress edit; my files pass") and tell that agent via SendMessage. Never call it green.
- **Commit only your hunks.** Use a temporary `GIT_INDEX_FILE` built from `HEAD`. Shared files
  (`docs/owner-requests.md`, `SELLNUKES_CLAUDE_DOCUMENTATION.md`, `docs/economy.md`,
  `tests/economy-sim.luau`, the snapshot) often carry someone else's edits, so add your hunks to
  them with context patches. Never use `-U0` patches. A plain `git commit` ships other people's
  half-done work.
- **Snapshot and economy changes:** a re-pace commit must include the `--update-snapshot` refresh,
  the "Snapshot refreshes" row, the updated `docs/economy.md` tables, the new `<area>-order` suite,
  and a `VersionConfig` + `ChangeNotesConfig` bump, because the change is player-facing.
- **Report honestly.** Quote the failing line (`[logic] tests/x.luau` followed by the error). Do not
  say "tests pass" unless the last line you saw was `[check] ALL PASSED`.
