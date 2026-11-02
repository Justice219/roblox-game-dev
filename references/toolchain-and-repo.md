# Toolchain and repository layout

This file describes the build toolchain and repo shape behind SellNukes: the aftman pins, the
Rojo project mapping, the `src/{client,server,shared,first}` layout, the format, lint and type
configs, the `scripts/check.sh` gate and its stages, the Luau coding conventions, a summary of the
security and performance rules, the gotchas the team hit, and a step-by-step bootstrap for a NEW
Roblox game on the same toolchain. Everything here is the same in the sister game RoBeasts, which
supplied the framework. Treat it as the default for any new Roblox game. The skill ships the
config files under `assets/templates/` and the scripts under `scripts/`.

## Contents

1. [Toolchain at a glance](#1-toolchain-at-a-glance)
2. [Why Rojo 7.7.1, and how binaries are resolved](#2-why-rojo-771-and-how-binaries-are-resolved)
3. [Rojo project mapping](#3-rojo-project-mapping)
4. [Repository layout](#4-repository-layout)
5. [Format, lint and type configs](#5-format-lint-and-type-configs)
6. [The check gate: scripts/check.sh](#6-the-check-gate-scriptschecksh)
7. [Luau conventions](#7-luau-conventions)
8. [Security rules (summary)](#8-security-rules-summary)
9. [Performance rules (summary)](#9-performance-rules-summary)
10. [Studio connection](#10-studio-connection)
11. [Gotchas](#11-gotchas)
12. [Bootstrapping a new game](#12-bootstrapping-a-new-game)

---

## 1. Toolchain at a glance

`aftman.toml` pins every Luau tool. The pins mirror RoBeasts, so both repos format, lint and
type-check identically.

| Tool | Pin | Purpose |
|------|-----|---------|
| `rojo` | `rojo-rbx/rojo@7.7.1` | Syncs `src/` into Studio (`rojo serve`, port 34872) and writes `sourcemap.json` for luau-lsp. |
| `stylua` | `johnnymorganz/stylua@2.5.2` | Formatter: tabs, 120 columns. |
| `luau-lsp` | `johnnymorganz/luau-lsp@1.70.1` | Strict type-check (`luau-lsp analyze`), the project's `tsc --noEmit`. |
| `selene` | `kampfkarren/selene@0.32.0` | Linter with the Roblox std. |
| `lune` | `lune-org/lune@0.10.5` | Standalone Luau runtime for the `tests/*.luau` suites. |

Tools outside aftman:

| Tool | Install | Purpose |
|------|---------|---------|
| `luau-compile` | `brew install luau` | Studio-style bytecode compile gate (`compilecheck.sh`). Required: the gate fails without it. |
| Blender | `/opt/homebrew/bin/blender` | Headless model builders (`tools/blender/`). |
| Python 3 | system | Studio MCP driver, lock, Blender, upload and QA scripts. |
| `uv` / `uvx` | `brew install uv` | Runs the Serena MCP server from `.mcp.json`. |
| Studio MCP | `@chrrxs/robloxstudio-mcp` v3.2.1 + its "MCP Server" Studio plugin | Drives the open Studio place over `http://127.0.0.1:58741/mcp`. |
| Rojo Studio plugin | `rojo plugin install` | Must match the CLI version (7.7.1). |

---

## 2. Why Rojo 7.7.1, and how binaries are resolved

**Pin Rojo to the version of the Studio plugin.** The parent folder's `aftman.toml` pins
`7.7.0-rc.1`, but the installed Studio plugin is 7.7.1, and it cannot read the rc's serve API
(it fails with `attempt to index number with 'protocolVersion'`). Aftman uses the nearest
`aftman.toml`, so the repo-level pin wins inside the game folder. Whenever you update the plugin,
update the CLI pin with it.

**Resolve the pinned binary directly.** `scripts/lib/tools.sh` provides `resolve_tool <name>`, and
every check script uses it:

1. `$<NAME>_BIN` (e.g. `LUAU_LSP_BIN`, `ROJO_BIN`) when it is set and executable, as an explicit override.
2. Otherwise `~/.aftman/tool-storage/<owner>/<tool>/<version>/<tool>` for the version pinned in
   `aftman.toml`. The owner directory is matched case-insensitively.
3. Otherwise the first `<name>` on `PATH` (the shim), as a last resort.

The reason: on the development Mac the `~/.aftman/bin` shims for the large binaries (`rojo`,
`luau-lsp`) were SIGKILLed (exit 137) while the stored binaries ran fine. Resolving storage
directly is also stricter, because the check runs exactly the pinned version and never a stray
copy on `PATH`. `pinned_version <name>` lets `typecheck.sh` download type definitions that match
the luau-lsp pin.

---

## 3. Rojo project mapping

`default.project.json`:

| Rojo path | Studio location | Purpose |
|-----------|-----------------|---------|
| `src/first` | `ReplicatedFirst` | Branded loading screen. It runs before anything else replicates and hides when the client sets the `ClientBooted` attribute. |
| `src/shared` | `ReplicatedStorage.Shared` | Config, pure logic, net contracts and utilities that both sides require. |
| `src/server` | `ServerScriptService.Server` | `init.server.luau` boot and every service. |
| `src/client` | `StarterPlayer.StarterPlayerScripts.Client` | `init.client.luau` boot, controllers and UI. |

The project also sets service properties in code, so a fresh place is configured identically:

- **Workspace**: `FilteringEnabled`, `StreamingEnabled` (min radius 192, target 768: the 8-plot
  ring is about 1,400 studs across), `StreamingIntegrityMode = MinimumRadiusPause`,
  `StreamOutBehavior = Opportunistic`, `ModelStreamingBehavior = Improved`.
- **StarterPlayer**: classic camera, zoom 0.5–120, `UserChoice` movement, mouse lock option.
- **Players**: `CharacterAutoLoads = true`, `RespawnTime = 2`.
- **Lighting**: `Future`, `ClockTime` 14, ambient values, an `Atmosphere`, `ColorCorrectionEffect`
  (+16 % saturation) and a soft `BloomEffect`. This is art direction, so retune it per game.
- **SoundService**: `RespectFilteringEnabled`.
- **HttpService**: `HttpEnabled = true`. It is only needed because game servers send Roblox
  experience notifications through Open Cloud. Keep it `false` until game code needs outbound HTTP.

There is no baseplate, because code builds the world. Rojo cannot set **Max Players**, so the
owner sets it to 8 in Game Settings.

---

## 4. Repository layout

### Top level

| Path | Purpose |
|------|---------|
| `CLAUDE.md` | Canonical rules for every agent. |
| `AGENTS.md` | Codex entry point that points at `CLAUDE.md` and does not duplicate it. |
| `SELLNUKES_CLAUDE_DOCUMENTATION.md` | Living system doc. |
| `aftman.toml`, `default.project.json`, `stylua.toml`, `selene.toml`, `.luaurc` | Toolchain config. |
| `.mcp.json` | Serena MCP registration (pinned commit, absolute project path). |
| `.serena/project.yml` | Serena project config, committed. `cache/` and `memories/` are ignored. |
| `src/` | All game code (section 3). |
| `tests/` | About 110 Lune suites plus `fixtures/` (`RobloxLoader.luau` and shared helpers). |
| `scripts/` | `check.sh`, `typecheck.sh`, `compilecheck.sh`, `test-logic.sh`, `lib/tools.sh`, `studio_mcp.py`, `studio-lock.py`. |
| `tools/` | `blender/` (bpy builders, `snkit` kit, upload and sync), `ui/` (stud textures, icons, sky), `audio/` (SFX generation and upload), `billboards/`, `monetization/` (product catalogue publish), `qa/` (about 100 Studio QA runners: `<thing>.py` plus `<thing>_client.luau` / `_server.luau` probes). |
| `assets/` | `audio`, `blender` (manifests, FBX/GLB, previews), `brand`, `icons`, `marketing`, `sky`, `world`. |
| `docs/` | Per-system docs, `owner-requests.md`, `change-notes.md`, `superpowers/{specs,plans}`, `reference/`, `verification/`. |

Ignored (`.gitignore`): `*.rbxl(x)` and their locks (the place lives in Studio), `sourcemap.json`
(regenerated), `.luau-defs/` (downloaded), `roblox.yml` (selene cache), `.serena/cache/`,
`.serena/memories/`, `__pycache__/`, `.sn-*.lock` (pipeline locks), unpicked audio candidates.

### `src/server`

| Folder | Purpose |
|--------|---------|
| `init.server.luau` | Ordered boot: `Remotes.createAll()`, then every `Init()`, then every `Start()`. The CRITICAL core (PlayerData, Monetization, Analytics) fails fast with the service name. `FEATURE_SERVICES` load by name under `pcall`, so one broken feature is skipped with a warning instead of taking the server down. |
| `Services/` | About 30 boot-ordered services, each returning `{ Init, Start }`, e.g. `PlayerDataService`, `MonetizationService`, `AnalyticsService`, `AdminService`. A service may only call services listed before it. |
| `Economy/` | `ProfileStore` (session-locked DataStore), `ProfileLogic` (schema, `reconcile`, `migrate`, `snapshot`), `ProfileSyncState`, `PassOwnership`, `PolicyCache`. |
| `Admin/` | Owner-only admin backend: auth, validated command pipeline, registry, audit, state push, `Handlers/`. |
| `Analytics/` | Recorders, sharded DataStore store and flusher, reports and sections, receipt journal, sessions, server health, Roblox forwarder. |
| `Tycoon/` | Plots, pads, layouts, offline earnings, rebirth, knockdown, flavours, plot names, travel rules, tutorial. |
| `World/` | `HubBuilder`, `PlotBuilder`, `MeshLibrary` (one template per mesh id), `WorldMaterials`, `StudMaterialVariants.model.json`. |
| `Retention/` | Daily, playtime, wheel, codes, gifts, boosts, return notifications. |
| `Pets/`, `Attack/`, `Event/`, `HappyHour/`, `Kinetic/`, `Pass/`, `Quests/`, `Social/`, `Leaderboards/`, `Badges/`, `Progression/` | Feature logic, one folder per system. |
| `Tests/` | Studio-side `TestRunner`, `TestContext` and `CoreTests`, run through `StudioTestService` (`{ suite = "Core" }`). A run always calls `EndTest`, guarded by a watchdog (default 300 s, range 30–1800 s). |

### `src/client`

| Path | Purpose |
|------|---------|
| `init.client.luau` + `BootRunner.luau` | Ordered controller boot. Each phase runs in its own thread with a time budget (`ClientBootConfig`), so a yielding controller never stalls the others (R103). It sets the `ClientBooted` attribute at the end. |
| `ClientState.luau`, `ProfileSyncClient.luau` | Read-only profile mirror (full snapshot plus deltas), toasts and grants. The client never trusts its own economy. |
| `Controllers/` | `InputController`, `CameraController`, `UIController`. |
| `UI/` | `Create`, `Theme`, `Components`, `ScreenManager`, `Kit/StudUI` (stud panels), `Hud/`, `Widgets/`, and `Screens/` (one folder per screen, about 40). |
| `Platform/` | Console and mobile layer: `ActionMap`, `GamepadNav`, `HintBar`, `GlyphFamily`, `SafeArea`, `TouchButtons`, `Haptics`, `MenuWheel`. |
| `Tycoon/` | Build-in, billboards, interaction, income pops, `Fx/`, FTUE tracker. |
| `Analytics/`, `Attack/`, `Audio/`, `ChangeNotes/`, `Event/`, `HappyHour/`, `Kinetic/`, `Leaderboards/`, `Lobby/`, `LuckyButtons/`, `Movement/`, `Pets/`, `Quests/`, `Social/`, `Worlds/` | Per-feature client controllers. |

### `src/shared`

| Folder | Purpose |
|--------|---------|
| `Config/` | About 80 tunable modules (`TycoonConfig`, `MonetizationConfig`, `VersionConfig`, `ChangeNotesConfig`, `MeshAssets`, `IconAssets`, `UIStyleConfig`, ...) plus `TycoonAreas/`, `AreaLayouts/` and `Worlds/`. All magic numbers live here. |
| `Net/` | `Remotes` (every RemoteEvent declared by name; no RemoteFunctions), `Validate` (typed argument validators), `ProfileDelta`, `WireSize`. |
| `Tycoon/` | Pure economy logic (`TycoonLogic`, `SafeMath`, `Modifiers`, `EconomyIndex`, types). The economy sim and both sides use it. |
| `Util/` | `NumberFormat`, `Signal`, `Trove`, `RateLimiter`, `TextUtil`, `MathUtil`, `DeviceProfile`, `ChangeNotesLogic`, ... |
| `Analytics/`, `Attack/`, `Events/`, `World/` | Pure logic shared by client, server and tests. |

**General pattern:** keep pure logic in `shared/` so Lune can test it and both sides agree. Keep
the server as the authority, with services that have an `Init`/`Start` contract. The client holds
controllers and UI only, and every number lives in `Config/`.

---

## 5. Format, lint and type configs

| File | Content | Why |
|------|---------|-----|
| `stylua.toml` | `column_width = 120`, `line_endings = "Unix"`, `indent_type = "Tabs"`, `indent_width = 4`, `quote_style = "AutoPreferDouble"`, `call_parentheses = "Always"` | Matches Rojo's default tab style. Identical in RoBeasts, so copied modules diff cleanly. |
| `selene.toml` | `std = "roblox"` | Selene knows every Roblox global (`game`, `workspace`, `Vector3`, ...). Its generated `roblox.yml` cache is gitignored. |
| `.luaurc` | `{ "languageMode": "strict" }` | Strict typing everywhere, the same as `--!strict` at the top of every file. |
| `.luau-defs/` | `globalTypes.None.d.luau` + `api-docs/en-us.json`, downloaded by `typecheck.sh` for the pinned luau-lsp version | The "None" security level contains only what normal game scripts may call, so an accidental plugin-only or CoreScript API is a type error. |
| `sourcemap.json` | `rojo sourcemap default.project.json`, regenerated on every type-check | luau-lsp resolves `ReplicatedStorage.Shared...` and `script.Parent...` requires through it. |

---

## 6. The check gate: `scripts/check.sh`

Run `./scripts/check.sh` from anywhere. It must print `[check] ALL PASSED` before any commit.
It stops at the first failing stage.

| # | Stage | Command | Catches |
|---|-------|---------|---------|
| 1 | Format | `stylua --check src` | Unformatted files. |
| 2 | Lint | `selene src` | Roblox-aware lint errors (shadowing, unused, deprecated globals). |
| 3 | Types | `./scripts/typecheck.sh` | Strict type errors (section 5). |
| 4 | Compile | `./scripts/compilecheck.sh` | Compiler limits the type checker cannot see. |
| 5 | Logic | `./scripts/test-logic.sh` | Regressions in the about 110 Lune suites. |

`./scripts/check.sh --fix` runs `stylua src` first. **Only the lead may use it.** Workers format
their own files only (`stylua path/to/File.luau`), because another session's uncommitted files
are in the same tree.

### `typecheck.sh`, the project's `tsc --noEmit`

1. Downloads the Roblox definitions for the pinned luau-lsp version into `.luau-defs/` on the first
   run, or again when `REFRESH_DEFS=1`.
2. Regenerates `sourcemap.json`.
3. Runs `luau-lsp analyze --flag:LuauSolverV2=true --platform=roblox --sourcemap=sourcemap.json
   --definitions=@roblox=.luau-defs/globalTypes.None.d.luau --base-luaurc=.luaurc src`.

`LuauSolverV2` is the new type solver that Studio is rolling out. The legacy solver wrongly widens
string-literal unions on local assignment (`"a" | "b"` becomes `string`).

### `compilecheck.sh`

This runs `find src -name '*.luau' -print0 | xargs -0 -n 40 luau-compile --null -O0 -g2` and fails
on `CompileError` / `SyntaxError` or when the compiler exits with an error. The reason: Studio
compiles without optimisation and with full debug info, which keeps every local in a register.
A function (and a module's top-level chunk counts as one) with more than 200 live locals fails
with "Out of local registers". A module that fails to compile breaks the whole server boot, and
every playtest hangs. Neither luau-lsp nor selene runs the compiler.

### `test-logic.sh`

This runs `lune run` on each top-level `tests/*.luau`, in a stable order. Files in subfolders
(`tests/fixtures/`, `tests/analytics-fixtures/`) are helpers. The script fails if no suites exist,
so it never reports a misleading empty green run.

- `tests/fixtures/RobloxLoader.luau` loads the **real** `src/` modules under Lune. It maps
  `script` / `.Parent` / `require(node)` to file paths and `game:GetService` to stubs
  (`ReplicatedStorage.Shared = src/shared`, `ServerScriptService.Server = src/server`). Datatypes
  come from `@lune/roblox` and `task` from `@lune/task`. It captures `warn` so tests can assert on it.
  ```lua
  local Loader = require("./fixtures/RobloxLoader")
  local loader = Loader.new()
  local ProfileLogic = loader.load("src/server/Economy/ProfileLogic")
  ```
- Suites are named `<system>-<aspect>.luau` (`profile-store`, `remote-security`, `change-notes`,
  `analytics-report`, `stand-order`, ...). Use numbered sections (`§4b`) so docs and commits can
  cite them, and include a regression case that fails on the old code for every bug fixed.
- `tests/economy-sim.luau` is the pacing simulator. It plays the whole game with a greedy player
  against the real config and asserts that every area lands within ±20 % of its target minutes,
  that the opening checks pass (first manager early, no long waits), and that a rebirth run is
  faster. Retune with `lune run tests/economy-sim.luau [--world <id>] --tune [--write] [--upto <n>]`.

Studio play-mode checks (the `src/server/Tests` runner and `tools/qa/*` scripts) are separate and
optional. The owner's R132 rule makes `check.sh` the default verification.

---

## 7. Luau conventions

- Put `--!strict` at the top of every file, and keep type errors at zero.
- **Comment generously** (owner rule). Give every module a header with its purpose, what it
  connects to, and a usage example. Give every public function a doc comment covering params,
  returns and why. Comment non-obvious math. Comment any uncommented code you touch. Header shape:
  ```lua
  --!strict
  --[[
  	VersionConfig — <one-line purpose>.

  	<Why it exists / the policy it encodes / the owner request that created it.>

  	Connects to: <modules, remotes, tests, docs that depend on it>.

  	Example:
  		local VersionConfig = require(ReplicatedStorage.Shared.Config.VersionConfig)
  		print(VersionConfig.label())   --> "v0.1.0"
  ]]
  ```
- **Naming**: `PascalCase.luau` modules, `init.server.luau` / `init.client.luau` entry points,
  camelCase locals and functions, `UPPER_SNAKE` constants, and services required at the top
  (`local Players = game:GetService("Players")`).
- **Tunables live in `src/shared/Config/*`**, never as inline magic numbers. Admin overrides and
  the economy sim read the same tables.
- **Big numbers** are plain Luau doubles, which are fine to about 1e308. Format them with
  `Shared/Util/NumberFormat`: `short` gives "1.25K" … "6.29Sx" (truncated, never rounded up),
  plus `commas`, `money`, `moneyFull`, `rate` ("+$1.25K/s") and `duration` ("1h 02m"). NaN shows
  as "0" and ±inf as "∞". Guard economy math with `Shared/Tycoon/SafeMath`.
- **Modern APIs only**: `task.wait/spawn/delay/defer` and constraint movers. Never use `wait`,
  `spawn`, `delay` or deprecated body movers.
- **Remotes**: declare every remote in `Shared/Net/Remotes` and use RemoteEvents only. Connect
  server handlers through `Remotes.onServerEvent(name, handler)`, which drops packets from players
  who have already left.
- **Boot contracts**: services and controllers return `{ Init, Start }`. `Init` only wires things
  and never yields. `Start` connects events and starts loops. Product-selling services register
  their receipt handlers in `Init`.

---

## 8. Security rules (summary)

Another reference covers these in depth. In short:

- **Never trust the client.** The server computes all cash, gems, purchases, levels, rolls, timers,
  offline time and attack outcomes. Clients send intents only ("click producer 3", "buy pad X"),
  never amounts.
- Every remote handler `typeof`-checks every argument (`Shared/Net/Validate`), checks ids against
  config allowlists, rejects NaN and ±inf, clamps values, applies per-player rate limits
  (`Util/RateLimiter`), and checks state (profile loaded, owns the plot, pad unlocked, in range).
  It re-checks state after every yield.
- Receipts are processed idempotently with a per-profile receipt ledger. Snapshot before granting
  and restore on any failure.
- No `loadstring`, no client-supplied instance paths, no server→client `RemoteFunction` invokes.
- Player text shown to others goes through `TextService:FilterStringAsync` and fails closed.
- Secrets (Open Cloud keys) live in Roblox secrets or local files outside the repo and are never
  printed or committed.

## 9. Performance rules (summary)

- `Workspace.StreamingEnabled = true`, and unbought content is never instanced.
- Use one `RunService` connection per system, never one per object. Producer ticks run on one
  server loop.
- Never call `Instance.new` every frame. Pool build-in ghosts, FX and popups.
- Billboards update on change events, not every frame, and distant ones are disabled (`MaxDistance`).
- Use one shared MeshPart template per mesh id and clone it. The stud material comes from one
  shared texture set.
- Targets from the perf pass (`docs/performance.md`): server heartbeat ≤ 4 ms on average and
  client scripts ≤ 3 ms per frame on the Low FX tier.

---

## 10. Studio connection

- **Rojo** serves `default.project.json` on :34872. Rojo owns all code, so never edit synced
  scripts through MCP.
- **Studio MCP** is `@chrrxs/robloxstudio-mcp` v3.2.1, the "MCP Server" plugin, on
  `127.0.0.1:58741`. One primary node process owns the port. SellNukes holds its wrapper open
  with `tail -f /dev/null | ~/.local/bin/robloxstudio-mcp-codex`. Never start two primaries.
  It is *not* the older `roblox-studio-mcp` bridge on port 3001.
- **`scripts/studio_mcp.py`** lets any agent drive it from Bash. It reads the token from
  `~/.robloxstudio-mcp/auth-token` and never prints it.
  - `list` / `schema <tool>` / `call <tool> '<json>'`
  - `luau '<code>'` / `luau-file <path>` (edit-mode `execute_luau`)
  - `guard_tool` refuses `multiplayer_playtest` starts (R72).
- **`scripts/studio-lock.py`** is the playtest mutex: `acquire`, `release`, `refresh`, `status`,
  plus `grant` and `prioritize` (lead only). The queue is first-come-first-served, a turn lasts
  10 minutes while others wait, and stale locks can be taken over.
- Only the open, connected place is used (R33). `rojo build` output is never opened.

---

## 11. Gotchas

| Symptom | Cause | Fix |
|---------|-------|-----|
| Rojo plugin errors with `attempt to index number with 'protocolVersion'` | The CLI is 7.7.0-rc.1 (the parent-folder pin) but the plugin is 7.7.1. | Pin `rojo-rbx/rojo@7.7.1` in the repo's own `aftman.toml`. `README.md` still says "Generated by Rojo 7.7.0-rc.1", which is stale. |
| Every check dies at once with exit 137 | The aftman shims for `rojo` / `luau-lsp` are SIGKILLed. | `scripts/lib/tools.sh` runs the stored binary. Override with `ROJO_BIN` / `LUAU_LSP_BIN`. |
| The server boot hangs and every playtest hangs, yet types and lint pass | "Out of local registers ... exceeded limit 200" in one module. | `compilecheck.sh` catches it. Split large top-level chunks into functions or submodules. |
| String-literal unions widen to `string` | Legacy type solver. | `--flag:LuauSolverV2=true` in `typecheck.sh`. |
| A bug in `tests/` is not caught by type-check, lint or format | `typecheck.sh`, `selene` and `stylua --check` only cover `src/`. | Run the suites. For risky edits, check the exact tree in a scratch worktree (e.g. an `economy-sim --tune` dry run). |
| `studio_mcp.py` returns no screenshot image | The driver drops image blocks. | Use `tools/blender/studio_shot.py` for captures. |
| A capture shows another agent's play viewport | Someone else is playtesting. | Hold `studio-lock.py` for edit-mode screenshots too. |
| `solo_playtest stop` times out | The server's `BindToClose` is saving. | Retry with `{"action":"stop","timeout":60}`. |
| An `execute_luau` probe of a server module shows empty state | Requiring a ModuleScript from `execute_luau` gives a fresh copy. | Probe live state through the service's own QA hooks. |
| `get_runtime_logs` misses prints | It shows WARN and ERROR only. | Use `warn` in probes, or return values. |
| Perf numbers vary about 5× between runs | Studio throttles an unfocused client to about 15 fps, and other agents load the machine. | Compare only same-session A/B results. |
| Docs disagree on `HttpEnabled` | `docs/core.md` still says `false`; the project now sets `true` for Open Cloud notifications. | Trust `default.project.json`, and update docs when a project property changes. |
| Max Players reverts | Rojo cannot set it. | The owner sets it in Game Settings. |
| Two sessions' edits end up in one commit | Several sessions share the working tree. | Commit through a temporary index (see `owner-rules-and-workflow.md` §8). |

---

## 12. Bootstrapping a new game

**What has actually been run (2026-11-01):** steps 1–4 in an empty folder, plus one module, one Lune suite
and the two boot scripts. `check.sh` reached ALL PASSED and `rojo build` succeeded. Porting the framework
and the art pipeline has not been run end to end, so expect to fix `require`s as you decouple them, and
re-run `check.sh` after each module.

The steps below assume the skill lives at `$SKILL` and the new repo at `$GAME`.

```bash
# 0. One-time machine setup
#    aftman (GitHub release installer), Homebrew, Roblox Studio
brew install luau uv                     # luau-compile + uvx (Serena)

# 1. Repo
mkdir -p "$GAME" && cd "$GAME" && git init

# 2. Toolchain config from the skill templates
cp "$SKILL/assets/templates/aftman.toml" .
cp "$SKILL/assets/templates/stylua.toml" "$SKILL/assets/templates/selene.toml" .
cp "$SKILL/assets/templates/dot-luaurc" .luaurc
cp "$SKILL/assets/templates/default.project.json" .   # set "name", retune Lighting, HttpEnabled false
cp "$SKILL/assets/templates/dot-mcp.json" .mcp.json   # replace <ABSOLUTE_PATH_TO_YOUR_GAME_REPO>
aftman install                                        # accept the trust prompts for the 5 tools
~/.aftman/bin/rojo plugin install                     # Studio plugin matching the CLI (7.7.1)

# 3. Scripts
mkdir -p scripts/lib
cp "$SKILL"/scripts/{check,typecheck,compilecheck,test-logic}.sh scripts/
cp "$SKILL/scripts/lib/tools.sh" scripts/lib/
cp "$SKILL/scripts/studio_mcp.py" "$SKILL/scripts/studio-lock.py" scripts/   # set LOCK_DIR
chmod +x scripts/*.sh scripts/*.py
# Studio MCP launcher (one primary process; see studio-mcp-and-screenshots.md §1)
brew install node                # the launcher runs the MCP through npx
mkdir -p ~/.local/bin
install -m 700 "$SKILL/assets/templates/robloxstudio-mcp-launcher.py" ~/.local/bin/robloxstudio-mcp-codex

# Serena (optional): set project_name in the copied file
mkdir -p .serena && cp "$SKILL/assets/sellnukes-source/.serena/project.yml" .serena/

# 4. Source tree and docs skeleton
mkdir -p src/first src/server/{Services,Economy,Tests} src/client/{Controllers,UI} \
         src/shared/{Config,Net,Util} tests/fixtures tools/{blender,qa} assets \
         docs/superpowers/{specs,plans} docs/reference docs/verification
```

Then:

5. **Port the framework from `assets/sellnukes-source/`** (or the RoBeasts repo) rather than rewriting it:
   - `Shared/Net/{Remotes,Validate,ProfileDelta,WireSize}`
   - `Shared/Util/{Signal,Trove,RateLimiter,NumberFormat,TextUtil,MathUtil}`
   - `Shared/Config/{VersionConfig,ChangeNotesConfig}`
   - `Server/Economy/{ProfileStore,ProfileLogic}`
   - `Server/Services/{PlayerDataService,MonetizationService}`
   - the two `init` boot scripts and `Client/BootRunner`
   - `Client/UI/{Create,Theme,Components,ScreenManager,Kit/StudUI}`
   - `tests/fixtures/RobloxLoader.luau`
   
   Rename the game-specific vocabulary, then start `VersionConfig.Current` at `"0.1.0"` with one note.
6. **Add `.gitignore`**: `/*.rbxl`, `/*.rbxlx`, their `.lock` files, `sourcemap.json`,
   `/.luau-defs/`, `/roblox.yml`, `.serena/cache/`, `.serena/memories/`, `__pycache__/`,
   `.sn-*.lock`, `.DS_Store`, `.idea/`.
7. **Add at least one Lune suite** (e.g. `tests/number-format.luau`), because `test-logic.sh`
   fails on an empty `tests/`.
   **Art pipeline, if the game has models.** Prerequisites and copy list:

   ```bash
   brew install --cask blender   # the commands assume /opt/homebrew/bin/blender; symlink it or swap in your path
   python3 -m pip install pillow numpy          # contact sheets and stud textures
   S="$SKILL/assets/sellnukes-source"; B="$S/tools/blender"
   mkdir -p tools/blender/models tools/ui
   cp -R "$B"/{snkit,generate_world.py,upload_meshes.py,extract_meshes.luau,sync_meshes.py,contact_sheet.py,viewport_look.py} tools/blender/
   cp "$B/models/__init__.py" tools/blender/models/
   cp "$S"/tools/ui/{build,upload}_world_studs.py tools/ui/
   mkdir -p assets/world && cp -R "$S/assets/world/studs" assets/world/
   ```

   Then port `Server/World/{MeshLibrary,WorldMaterials,StudMaterialVariants.model.json}`,
   `Shared/World/{MeshPlacement,PreloadList}` and `Shared/Config/{WorldFxConfig,WorldMaterialConfig}`.
   `MeshLibrary` needs `PreloadList`, which reads SellNukes' `HubLayout`, `TycoonConfig`, `TycoonLogic`
   and `WorldsConfig`: rewrite `PreloadList` for the new game and remove `MeshLibrary`'s hub warm-up.
   Keep what `MeshLibrary` calls: `tiers()`, `areaKeys(area)` and `plotKeys`, each giving `MeshAssets`
   keys in preload order.
   Do not copy `MeshAssets.luau` (`sync_meshes.py` generates it). Run the upload tools once you have:
   - an Open Cloud API key from the Creator Hub with `asset:read` and `asset:write` (add `game-pass:read`,
     `game-pass:write`, `developer-product:read` and `developer-product:write` for the products tool, and
     the notification API system for return notifications), in a mode-600 file
     (`ROBLOX_OPEN_CLOUD_KEY=...`; set the path in `snkit/cloud.py`, whose default is SellNukes');
   - your numeric Roblox user id for `--user-id` (on your profile page's URL). The uploader assumes
     a user-owned asset, so a group-owned game needs a change to its `creator` field.
   - a place: create and publish an empty experience in Studio first, then connect Rojo to it.

8. **Write `CLAUDE.md`** with the twelve hard rules, Serena, toolchain, Studio MCP, code
   conventions, security, performance, context budget and docs sections. Then write a short
   `AGENTS.md` that points at it, `<GAME>_CLAUDE_DOCUMENTATION.md` (Big picture, Studio + tooling,
   Systems, Next steps, Change log), and `docs/owner-requests.md` with its header rule and R1.
9. **Run `./scripts/check.sh`.** The first run downloads `.luau-defs/` (needs network) and writes
   `sourcemap.json`. Fix everything until it prints `ALL PASSED`.
10. **Connect Studio**: open the game's place once, by hand, from the Roblox app, and never from a
    `rojo build` file. Then:
    - run `~/.aftman/bin/rojo serve` and click Connect in the Rojo plugin;
    - install the robloxstudio-mcp plugin and start one primary server;
    - check the connection with `python3 scripts/studio_mcp.py list`.
    
    Record the placeId and universeId in `CLAUDE.md` and the living doc.
11. **Commit** the skeleton (`chore: bootstrap <game> toolchain`), then write the design spec under
    `docs/superpowers/specs/` and the build plan with builder ownership and contracts under
    `docs/superpowers/plans/` before starting parallel builders.
