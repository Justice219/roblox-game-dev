# Studio MCP, playtests and screenshots

This reference covers how Claude drives Roblox Studio for SellNukes. It explains which MCP server
is used and how to reach it from Bash. It covers how agents share one Studio place without breaking
each other's playtests and how in-game behaviour is checked through the real game code. It also
covers taking phone / tablet / console screenshots and filing them, then showing them to the owner,
and reading live analytics through Studio. Every rule here comes from a real failure: a 7-hour
orphaned multiplayer test, playtests stopped under someone else, captures that showed the wrong
world, and stale Rojo code. Follow the rules, and check the owner's current instructions before
you start Studio at all (see R132 below).

## Contents

1. [Which MCP and how it runs](#1-which-mcp-and-how-it-runs)
2. [scripts/studio_mcp.py](#2-scriptsstudio_mcppy)
3. [scripts/studio-lock.py](#3-scriptsstudio-lockpy)
4. [Studio rules (owner)](#4-studio-rules-owner)
5. [Tool catalogue (49 tools)](#5-tool-catalogue-49-tools)
6. [Verifying in-game behaviour: QA runners](#6-verifying-in-game-behaviour-qa-runners)
7. [Forcing game state for a shot](#7-forcing-game-state-for-a-shot)
8. [Screenshots and the device matrix](#8-screenshots-and-the-device-matrix)
9. [Filing captures and showing the owner](#9-filing-captures-and-showing-the-owner)
10. [Edit-mode art shots](#10-edit-mode-art-shots)
11. [Live analytics through Studio](#11-live-analytics-through-studio)
12. [Profiling](#12-profiling)
13. [Gotchas](#13-gotchas)
14. [Copy-paste recipes](#14-copy-paste-recipes)

---

## 1. Which MCP and how it runs

Studio is driven by **`@chrrxs/robloxstudio-mcp` v3.2.1**. In Studio it is the **"MCP Server"**
plugin in the Plugins toolbar. Its panel shows `MCP v3.2.1 · http://localhost:58741`.

- One **primary** node process owns `127.0.0.1:58741`, and the Studio plugin talks only to it.
  Whichever agent started first owns it (often a Codex session from the sibling RoBeasts repo).
- Every other agent drives Studio through the primary's streamable-HTTP endpoint `POST /mcp`,
  authenticated with a shared token file. That is what `scripts/studio_mcp.py` does, so no session
  has to register its own MCP server or restart anything.
- **Do not use the old `RobloxGame/roblox-studio-mcp` bridge** (port 3001, "MCPBridge" plugin,
  `mcp__roblox-studio__*` tools). Studio is not connected to it for this game, and it usually fails
  because another process owns :3001. Even if those tool names appear in your session, ignore them.

**Health check** (read-only, safe at any time):

```bash
lsof -nP -iTCP:58741 -sTCP:LISTEN          # someone must be listening
python3 scripts/studio_mcp.py list | head   # tool names come back => primary + plugin are up
```

**Restarting the primary.** Only the lead does this, and only when nothing listens on 58741 (the
error is "connection refused"). Never run two primaries. Start the pinned wrapper in the
background with stdin held open:

```bash
tail -f /dev/null | ~/.local/bin/robloxstudio-mcp-codex     # run_in_background: true
```

- The wrapper (`~/.local/bin/robloxstudio-mcp-codex`) execs
  `npx -y @chrrxs/robloxstudio-mcp@3.2.1 --auto-install-plugin`. It puts an Open Cloud key into the
  child's environment from a private file under `~/.config/robloxstudio-mcp/`, so the key never
  appears in argv or logs. Never print that file.
- `tail -f /dev/null |` matters. An MCP stdio server exits when its stdin reaches EOF. A detached
  process with closed stdin dies at once and takes the HTTP side down with it.
- The Studio plugin reconnects by itself. Wait a few seconds, then run `list`.

## 2. scripts/studio_mcp.py

The skill ships a copy at `scripts/studio_mcp.py` (it matches the SellNukes copy). It uses only the
standard library, talks only to `127.0.0.1`, and opens a fresh MCP session for each call: initialize,
then `notifications/initialized`, then one JSON-RPC call. It reads both JSON and SSE replies.

| Command | What it does |
|---|---|
| `python3 scripts/studio_mcp.py list` | Tool names and the first line of each description |
| `python3 scripts/studio_mcp.py schema <tool>` | One tool's full input schema (check it before the first use) |
| `python3 scripts/studio_mcp.py call <tool> '<json>'` | Calls a tool with JSON arguments and prints its **text** content |
| `python3 scripts/studio_mcp.py luau '<code>'` | Shortcut for `execute_luau` (edit DataModel by default) |
| `python3 scripts/studio_mcp.py luau-file <path.luau>` | Same, with the code read from a file (keep snippets in the scratchpad) |

**Auth.** The token is read when each call runs from `~/.robloxstudio-mcp/auth-token`, which the
primary writes. The env var `ROBLOX_STUDIO_AUTH_TOKEN` overrides it. It is sent as the `X-MCP-Auth`
header and never printed. Never echo, cat or paste that file.

**Env knobs:** `ROBLOX_STUDIO_PORT` (default 58741) and `STUDIO_MCP_TIMEOUT` (seconds, default
120). Raise the timeout for slow console emulation or long profiler captures.

**Refusals (`guard_tool`).** Every call goes through `call_tool`, and `guard_tool` checks it first.
It refuses `multiplayer_playtest` for any action except `status`, `end` and `stop`. This applies
owner rule R72: an 8-client test reported "start not detected", was never ended, ran for about
7 hours, used up the Mac's memory and hung Studio and the MCP for everyone. The script is the one
path every agent and QA runner uses, so the ban lives there. A stray multiplayer test can still be
inspected and stopped.

**Image blocks are dropped.** `call` prints only `text` content. `capture_screenshot` and
`capture_device_matrix` return their pictures as `image` blocks, so the CLI shows only the metadata.
To save images, import the module and use `studio_mcp.rpc(...)`, then base64-decode the image block
(recipes in section 8). Call `rpc` directly **only** for these image tools. Everything else goes
through `call_tool`, so the R72 guard still applies.

**For a new game:** add the bans your owner gives you to `guard_tool`. A good first one: refuse
`manage_instance` with `action: "launch"` (see R33). Bans in a single choke point hold. Bans that
live only in documentation get broken.

## 3. scripts/studio-lock.py

A Studio place can run only one playtest at a time, and several agents share it. The lock gives
mutual exclusion, FIFO fairness, and a rule that you can only release a lock you hold. An older
`mkdir` lock let an agent that failed to acquire it delete someone else's lock. The skill ships a
copy at `scripts/studio-lock.py`. Its state lives in `~/.cache/sellnukes/studio.lock` (+ `.queue`
and `.grant.json`). **For a new game, change `LOCK_DIR`** so two games never share one lock.

| Command | Use |
|---|---|
| `acquire <name> [timeout-s]` | Blocks until it's your turn, then exits 0. Run it in the background and act when it returns. |
| `status` | Line 1 is the holder's JSON (`{"owner": ..., "since": ..., "acquired": ...}`) or `free`. Then any grant and the waiting queue. |
| `refresh <name>` | Keeps a lock you hold from going stale. It does **not** extend your turn. |
| `release <name>` | Does nothing unless you hold the lock. Release as soon as your batch ends. |
| `grant <name> <s>` | **Lead only.** One longer turn (≤ 1800 s) at `<name>`'s next acquire, e.g. a trailer capture block. |
| `prioritize <name> [wait-s]` | **Lead only.** Puts `<name>` first in the queue. Start it BEFORE `<name>` starts its acquire. |

Timings: a turn is **10 min** while others wait (`MAX_TURN_SECONDS`). A lock with no refresh for
**20 min** is stale (`STALE_SECONDS`). A waiter that has not polled for 30 s loses its queue ticket.

Rules learned the hard way:

- **Gate every start and stop on ownership in the same command.** One agent lost its turn
  mid-run, then chained `status | head -1 && refresh; stop` with `;`. The stop ran without the lock.
  Always do this:
  `python3 scripts/studio-lock.py status | grep -q '"owner": "<name>"' && <studio command>`.
- **A background acquire that finished long ago means nothing.** Turns expire. Check `status`
  again before every Studio batch. Edit-mode art spawns and screenshots need the lock too.
- **Fit a verification into one 10-minute turn.** Fix code between turns, not during one.
- **A running playtest that no agent owns is probably the owner testing.** If a screenshot is due, tell
  the owner it waits until they finish, and say the code is already committed. Do not stop it, do not
  start anything, and do not set a watcher that starts a capture when it ends (the owner may only be
  pausing). Release, tell the lead, and wait for an explicit go.
- **Orphan rule (lead only).** The lead may stop an orphaned playtest only when its owner's lock is
  stale (> 20 min) AND that agent is confirmed dead. Acquire as `lead`, stop, release. Nobody else
  ever stops a playtest they did not start.
- QA runners call `world_tour.require_lock()`. It exits unless the env var `STUDIO_LOCK_OWNER`
  matches the current holder, so a runner cannot start a playtest outside your turn.

## 4. Studio rules (owner)

| Rule | What it means |
|---|---|
| **R72 solo only** | Never `multiplayer_playtest`. If a check needs several players, use solo playtests and pure Lune tests. `capture_device_matrix` refuses multiplayer clients anyway. |
| **R33 never open new places** | Use ONLY the already-open, MCP-connected place ("Sell Nukes [🎃]", placeId 132667741281890, universe 10773845696). Never open a `.rbxl(x)` from `rojo build` (that is an offline check only). Never call `manage_instance` `launch` and never start another Studio. |
| **Rojo owns all code** | Never use `set_script_source` / `edit_script_lines` / `insert_script_lines` / `delete_script_lines` / `find_and_replace_in_scripts` on scripts in Rojo containers. Rojo overwrites those edits or drifts from them. Anything that must persist goes into the repo. |
| **One playtester at a time** | Hold `studio-lock.py`. See section 3. |
| **R132 code checks only** | When the owner says so, verify with `./scripts/check.sh` and pure-logic tests only: no `solo_playtest`, no QA runners, no device matrix. Then list in your report what the owner should look at in Studio. The owner playtests live, and an agent's playtest collides with theirs. This overrides the CLAUDE.md "capture_device_matrix before reporting" step. |
| **R92 builders: no Studio** | With more than ~2 parallel builders, builders ship code, Lune tests, a green `check.sh` and a **re-runnable capture runner**. The lead then runs one consolidated Studio pass. Eight builders queueing for one Studio once made the owner wait for hours. |
| **R12 show the art** | When images are produced, open them on the owner's Mac (`open <file>`), not only list paths. See section 9. |

Read-only `execute_luau` checks in edit mode (for example "did Rojo sync?") need no lock, as long as
they never touch a running playtest.

## 5. Tool catalogue (49 tools)

Run `schema <tool>` before the first use of any tool. Most tools take `instance_id` when more than
one Studio is connected, and the runtime tools take `target` (`edit`, `server`, `client-1`, ...).

| Area | Tools and what matters |
|---|---|
| **Run Luau** | `execute_luau {code, target?}`: edit DataModel by default. Use it for inspection, edit-mode spawns and DataStore reads. Requiring a server ModuleScript here gives a **fresh copy with empty state**. `eval_server_runtime {code}` / `eval_client_runtime {code, target?}`: run inside the **live playtest VM with its require cache**, so `require(Server.Services.X)` is the running service. Use these for state and admin seams. Return a value to get it back (the response has `ok` and `result`). |
| **Playtest** | `solo_playtest {action: start\|stop\|status, mode: play\|run, timeout}`. `play` gives a character (`client-1`). `run` is server-only. Start waits 60 s by default and stop 15 s; pass 90 for this game. `multiplayer_playtest`: banned (R72). |
| **Screens** | `capture_screenshot {format: jpeg\|png, quality}`: the Studio viewport (the client view during a play test). `capture_device_matrix {entries[≤6]: {label, deviceId, orientation, resolution, pixelDensity, scalingMode}, target, format, quality, settleSeconds (default 0.3), restoreAfter}`. |
| **Device sim** | `set_device_simulator {target, deviceId, orientation, resolution, ..., stopSimulation}`, `get_device_simulator_state {target, includeDeviceList}` (lists the presets), `set_network_profile` (latency / jitter / loss), `get_simulation_state`, `reset_simulation_state`. |
| **Input** | `simulate_mouse_input {action: click\|mouseDown\|mouseUp, x, y, button, target}` (viewport **capture pixels**). `simulate_keyboard_input {keyCode \| text, action: press\|release\|tap, duration, target}`. |
| **Logs / debug** | `get_runtime_logs {tail, filter, cursor}`: in practice only WARN and ERROR lines. `breakpoints` (breakpoints / logpoints). `get_request_status`: recovers the result of a call that timed out. |
| **Perf** | `capture_script_profiler {target, duration_ms, frequency, filter, output_path}`, `capture_micro_profiler {target, duration_ms, focus: all\|script\|physics\|render\|network\|jobs}`, `get_memory_breakdown {target: "all"}`, `get_scene_analysis`. |
| **DataModel read** | `get_place_info`, `get_project_structure`, `search_objects`, `get_instance_properties`, `get_attributes`, `get_connected_instances`, `selection`, `grep_scripts`, `get_script_source`. |
| **DataModel write** | `set_properties`, `import_rbxm {source: path\|url\|base64, parent_path, target: edit\|server}`, `export_rbxm {instance_paths, output_path, target}`. The script-edit tools exist but are off-limits for Rojo-owned scripts. |
| **Assets** | `upload_asset {filePath, assetType: Audio\|Decal\|Model\|Animation\|Video, displayName}` (Open Cloud). `search_assets`, `get_asset_details`, `get_asset_thumbnail`, `preview_asset`, `insert_asset`, `generate_model`. |
| **Monetization** | `manage_monetization {action: list\|get\|create\|update, kind: developer_product\|game_pass, ...}`. **create / update change live Roblox items.** |
| **Docs** | `get_roblox_docs {name, doc_type: classes\|enums\|datatypes\|libraries\|globals, section}` gives official engine references. `get_roblox_skills` reads installed Studio Assistant skills. |
| **Process** | `manage_instance`: `launch` is banned (R33). `status` and `list_place_versions` are fine. |

SellNukes performs bulk uploads and catalogue publishing with idempotent repo scripts that keep
receipt ledgers, not with ad-hoc MCP calls. `tools/monetization/publish.py` creates or patches every
pass and product from `MonetizationConfig`. `tools/audio/upload_sfx.py`,
`tools/blender/upload_meshes.py` and `tools/ui/upload_world_studs.py` handle uploads. Use the MCP
tools for one-offs and inspection. Never create a product twice, and never spend Robux. Only the
owner does that.

## 6. Verifying in-game behaviour: QA runners

Real verification goes through the real game code in a solo playtest, driven by a re-runnable
script in `tools/qa/`. Do not click around by hand. There are about 47 runners, for example
`happy_hours.py`, `ftue_check.py`, `world_tour.py`, `shop_world.py`, `r122_check.py`.

**Anatomy** (copy it for every new feature):

```
tools/qa/<feature>.py            driver: lock check -> start -> wait ready -> steps -> checks -> stop
tools/qa/<feature>_server.luau   eval_server_runtime template: COMMAND = "__COMMAND__", ARGS = { --[[ARGS]] }
tools/qa/<feature>_client.luau   eval_client_runtime template: diag, close_all, open_x, hud_off/on ...
```

- **Whitelisted templates.** `world_tour.render(template, command, allowed, args)` swaps in a
  command from a fixed set and **numbers only**, with no free-form text. The template branches on
  `COMMAND` and calls the same server seams the admin panel uses (e.g. `HappyHourService.force`),
  never a client shortcut. It returns `HttpService:JSONEncode(...)`.
- **Driver flow** (from `happy_hours.py`):
  1. `world_tour.require_lock()`. Then `solo_playtest status`. If it shows running, or the status
     is unreadable, **refuse** ("not ours"). Never start on top of another playtest.
  2. `solo_playtest {"action":"start","mode":"play","timeout":90}`.
  3. Poll a client `diag` until the HUD and profile are up (`wait_until(..., 150 s)`). Then sleep
     about 8 s for the first profile push and the join queue (loading → plot reveal → pop-ups).
     Then `close_all` (`ScreenManager.closeAllModals()`).
  4. Run the steps. Before every capture, close stray join-flow prompts.
  5. Build a checks dict (`name → bool`) from the record. Print the JSON record and
     `ALL CHECKS PASSED` or `FAILED: ...`, and write `<feature>-record.json` next to the captures.
  6. **Always** stop in a `finally:` block with `world_tour.stop_playtest()`. It reports a slow
     teardown instead of raising, then polls `status` until the playtest is no longer running.
- **Logs.** Read `get_runtime_logs {"tail": 500}`, filter by your system's prefixes, and count
  error and warning lines. In Studio without API services, the cross-server store / MessagingService
  warnings ("subscribe failed", "publish failed", "DataStore unavailable") are expected. File them
  under "environment", not as failures.
- **Usage line** in every runner's docstring:
  `python3 scripts/studio-lock.py acquire X && STUDIO_LOCK_OWNER=X python3 tools/qa/<feature>.py; python3 scripts/studio-lock.py release X`.

Builders write the runner and a pure Lune test. Under R92 or R132, the runner is handed to the lead
or owner instead of being run.

## 7. Forcing game state for a shot

Use the admin seams from a server template (`eval_server_runtime`), never fake client state.
These are real recipes from `tools/qa/*`:

| Want | Server call (live VM) |
|---|---|
| A Happy Hour event live | `HappyHourService.force("confetti", 120)`. Ids: `confetti`, `sprinkle`, `doublePops`, `stampede`, `lowGravity`. Then `.stop()`, `.skip()`, `.setEnabled(false/true)` (kill switch). |
| A free wheel spin | `LuckySpinService.setFree(p, 1)` (runner: `tools/qa/lucky_wheel.py`). Restore it afterwards. |
| A partly or fully built plot | `TycoonAdmin.resetPlot(p)` → `setArea(p, 4)` → `rebuildPlot(p, false)` builds areas 1–3. `unlockAll(p)` → `rebuildPlot(p, false)` builds everything. Per world: `worldSetArea`, `worldUnlockAll`, `worldRebuildPlot`. |
| Cash / rebirths | `TycoonAdmin.setCash(p, n)`, `setRebirths(p, n)`, `worldSetCash(p, "moon", n)`. |
| A brand-new player | `PlayerDataService.enterNewPlayerModeAsync(p)` (admin New Player Mode: a sandbox profile that is never saved, where every pass reads as unowned). |
| Another world's look | `WorldService.adminSend(p, "moon", "plot")` (real travel), and `WorldService.sendHome(p)` to come back. Only for a world that is **already unlocked** on the profile; a runner never unlocks one as a side effect. |
| A clean world shot | Client `hud_off` hides the HUD and core GUI. In-world billboards stay. |

**Restore what you change.** `world_tour.luau` snapshots the test profile's pads and cash in
`prepare` and puts them back in `restore`. Do the same with anything that would otherwise leak into
the owner's Studio profile.

**Travel for real, never CFrame-teleport, for presentation shots.** Setting the HumanoidRootPart
CFrame next to a Moon stand leaves the player attribute `CurrentWorld = "main"`. The shot then shows
the Nuke Town cash HUD, the Attack button and a blue sky. A direct move is fine for checking server
rules (charges, range, refusals). For anything the owner judges by eye, use `WorldService` travel, or
write in the README that the presentation is not the target world's
(`docs/verification/world2/pets/moon/README.md` is that note).

**Wait for the join flow, then clear it.**
- The client attribute `LocalPlayer:GetAttribute("LoadingDone")` marks the loader hand-off. Poll for
  it, plus `hud` and a plot index above 0, before any capture. The loading screen can take about
  25–33 s in Studio for a profile that preloads many assets.
- `Platform/JoinFlow` queues pop-ups after the plot reveal: Welcome Back 100 → tutorial coach 95 →
  What's New 50 → notify 10. During guided tutorial steps 1–3 only essential items (≥ 90) open, so a
  feature chip may be **gated** behind the tutorial. Use New Player Mode for first-minute shots, or
  a profile past the tutorial for everything else.
- `close_all` before each capture. A NotifyPrompt or What's New covering the subject is the most
  common bad shot.
- Before each world shot, anchor the character near the subject and call
  `RequestStreamAroundAsync`, because StreamingEnabled is on and far content is not instanced.

## 8. Screenshots and the device matrix

**Single capture** (the current viewport, or the client during a play test):

```python
import base64, sys; sys.path.insert(0, "scripts"); import studio_mcp
r = studio_mcp.rpc("tools/call", {"name": "capture_screenshot", "arguments": {"format": "jpeg", "quality": 86}})
img = [c for c in r.get("content", []) if c.get("type") == "image" and c.get("data")][0]
open("docs/verification/<feature>/<feature>-<state>-desktop.jpg", "wb").write(base64.b64decode(img["data"], validate=True))
```

**Device matrix: phone, tablet, console.** This is the standard set, used across all the runners:

```json
[
  {"label": "phone",   "deviceId": "iphone_14",            "orientation": "LandscapeRight"},
  {"label": "tablet",  "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
  {"label": "console", "deviceId": "xbox"}
]
```

Also used: `iphone_13`, `hd_1080` (desktop 1080p). List the presets with
`get_device_simulator_state {"includeDeviceList": true}`.

Call it **one device per call**. Slow console emulation makes a three-device call time out, and
the image byte budget is shared across a call's entries. Use `target: "client-1"` during a play test:

```json
{"entries": [{"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"}],
 "target": "client-1", "format": "jpeg", "quality": 88, "settleSeconds": 1.5, "restoreAfter": true}
```

- **settleSeconds.** The default is 0.3 s, which is too short. After a resolution change, the UI
  re-lays out and tweens. Use 1.0–1.5 s for screens, and 0.8 s for static world shots.
- `restoreAfter: true` puts the simulator back to its earlier preset (custom resolutions cannot be
  restored).
- **Per-device probes.** To read layout numbers per device (tap sizes, overlaps, insets), call
  `set_device_simulator {target: "client-1", deviceId, orientation}`. Sleep about 2 s, run the
  client `diag`, and repeat for each device. In a `finally:` block, finish with
  `set_device_simulator {"target": "client-1", "stopSimulation": true}`.
- **Clicking UI.** The client reports logical points, but `simulate_mouse_input` takes capture
  pixels. Scale by `capture_width / viewport_width` (`tools/qa/flavors.py` `click`). For a ScreenGui
  without `IgnoreGuiInset`, add `GuiService:GetGuiInset().Y` (`tools/qa/r123_check.py` `CHIP`). In
  phone emulation the two coordinate spaces differ, so try logical points first, then scaled ones.
- **Captures leave out CoreGui.** The Roblox top bar and the default ProximityPrompt UI never
  appear in images. Prove a prompt with an event or attribute (`PromptShown`). Prove top-bar
  clearance with numbers (`GuiService.TopbarInset`; see section 13), not by eye.

## 9. Filing captures and showing the owner

**Where captures go:** new work uses `docs/verification/r<N>/<device>.jpg` plus a README (a real example
is `docs/verification/r138/`). Older folders are named by feature, one per feature or request (e.g.
`r89-events/`, `r122/`, `r78-ftue/`, `world-qa/<YYYYMMDD-HHMM>/`, `world2/pets/moon/`).

**Naming:** `<feature>-<state>-<device>.jpg`, with device one of `phone | tablet | console |
desktop`. Examples: `r89-events-banner-phone.jpg`, `invite-console.jpg`,
`r82-badge-stacked-tablet.jpg`. Before/after pairs use `before-*.jpg` / `after-*.jpg`. The runner's
JSON record goes next to the images (`r89-events-record.json`, `r122.json`, `ftue.json`).

**Every folder gets a `README.md`.** That way the owner, the lead or a later session knows what each
image proves without re-running anything. Model it on `docs/verification/r122/README.md` and
`r78-ftue/README.md`:

```markdown
# R122 "Algorithm pack" (0.8.0) — Studio verification (2026-11-01, lead, solo playtests)
Re-run: `STUDIO_LOCK_OWNER=<name> python3 tools/qa/r122_check.py`
| Script | Result |
|---|---|
| `tools/qa/r122_check.py` | PASS 11/11 — ...; phone / tablet / console captures here |
Known, not from this change: <pre-existing failure and why>.
Look at: <the one thing in each image the owner should judge>.
```

Write down what each image shows, the PASS/FAIL list, the exact re-run command, and any caveat (for
example "partly covered by the WORLD UNLOCKED popup" or "CurrentWorld stayed main").

**Contact sheets** turn many shots into one image for review:
- `world_tour.sheet(out, names, target, cols=4, width=520)` uses Pillow. It writes labelled
  sheets such as `sheet_partial.jpg`, `sheet_full.jpg` and `sheet_zfight.jpg`.
- `tools/blender/contact_sheet.py [--view iso|front] [--only A,B]` makes sheets of Blender
  previews (`assets/blender/previews/_sheet_<view>.jpg`).

**Showing the owner (R12).** Open the files on the owner's Mac. Paths alone are not enough:

```bash
open docs/verification/r89-events/r89-events-banner-{phone,tablet,console}.jpg
open docs/verification/world-qa/20261030-1839/sheet_full.jpg
```

Look at every image yourself first (the Read tool shows images) and catch wrong-world HUDs, covering
pop-ups and empty frames before the owner sees them. In the report, list the paths grouped by device
(phone / tablet / console). Say what to look at in each, and state any shot that did not capture.

## 10. Edit-mode art shots

For art checks that do not need a running game (new area meshes, materials, z-fighting), spawn in
**edit mode** far from the play area, shoot, then clean up. Hold the lock for the whole
spawn → shots → cleanup sequence.

```bash
python3 scripts/studio-lock.py acquire B8a
python3 scripts/studio-lock.py status | grep -q '"owner": "B8a"' || exit 1
python3 scripts/studio_mcp.py luau-file tools/blender/studio/spawn_area01.luau
python3 tools/blender/studio_shot.py docs/verification/world-art/area01.jpg --luau tools/blender/studio/camera.luau
python3 scripts/studio_mcp.py luau-file tools/blender/studio/cleanup_preview.luau
python3 scripts/studio-lock.py release B8a
```

- `spawn_areaNN.luau` builds an area at a preview origin (2000, 0, 2000) from its real `AreaLayouts`
  module through the real `MeshLibrary` and `WorldMaterials`. A clean run also proves the layout's
  mesh keys and CFrames are valid.
- `studio_shot.py OUT [--luau setup.luau] [--png]` optionally runs a Luau file, then saves the
  `capture_screenshot` image. It exists because `studio_mcp.py call` drops image blocks.
- `camera.luau`: edit cameras orbit their `Focus`, so set `Focus` **with** the `CFrame`, or Studio
  snaps back.
- `cleanup_preview.luau` removes `SN_ArtPreview` / `SN_StudExperiment` and the edit-mode
  MaterialVariant clones. **Always** run it. Edit-mode leftovers would be saved into the place,
  and the repo is the source of truth.
- `tools/blender/viewport_look.py` is not Studio. It runs in headless Blender
  (`blender -b --python tools/blender/viewport_look.py -- OUT KEY1,KEY2 models.py`) and renders
  flat colour × stud texture the way a shop ViewportFrame looks, for judging colour.

## 11. Live analytics through Studio

The Open Cloud key on disk has Messaging and asset-upload scopes only. DataStore calls on the
universe return `403 INSUFFICIENT_SCOPE`. Read the analytics store from the connected place instead,
with `execute_luau` in edit mode. That needs no playtest and no lock, and it is read-only:

```lua
-- scratchpad/analytics_read.luau ; run: python3 scripts/studio_mcp.py luau-file <path>
local HttpService = game:GetService("HttpService")
local store = game:GetService("DataStoreService"):GetDataStore("SellNukesAnalytics_v1")
local out = {}
for _, family in { "core", "tycoon", "retention", "revenue" } do
	local key = "d:2026-10-31:" .. family .. ":0" -- ShardCount = 1; value = { c = counters, v = version }
	local ok, value = pcall(function() return store:GetAsync(key) end)
	out[family] = if ok then value else { error = tostring(value) }
end
return HttpService:JSONEncode(out)
```

- Keys: `meta` (`{firstDay = <day>}`), `d:<yyyy-mm-dd>:<family>:0`, and `c:<yyyy-mm-dd>` (a compacted
  day, which may be absent). Families: core, revenue, economy, tycoon, worlds, retention, pets,
  crates, attack, event, social, kinetic, orders, health. Slice by release with
  `build:<release>:p<place>:<metric>`.
- A full dump (every family, every day) is about 110 KB of JSON and takes under a minute. Parse the
  response's `returnValue` in Python.
- Never write to the store from Studio, and never print keys or tokens. If Studio says API access
  is disabled, the owner must enable Studio access to API services in Game Settings → Security.
  Do not change that setting yourself.

## 12. Profiling

Use a solo playtest with a realistic load. For SellNukes that meant the own plot fully unlocked plus
7 copies of a late-game plot. Then:
`capture_script_profiler {"target": "server", "duration_ms": 5000, "frequency": 2000}` (and the
same on `client-1`), `capture_micro_profiler {"focus": "script"}`, `get_memory_breakdown
{"target": "all"}`, and `get_scene_analysis`. Studio limits an **unfocused** client to about 15 fps,
and other agents load the machine. Absolute times varied about 5× between runs, so report
same-session A/B numbers. Results go in `docs/performance.md`.

## 13. Gotchas

- **Rojo must be connected, or you are testing old code.** Before a Studio pass, compare one
  distinctive string in Studio with the disk:
  ```bash
  grep -n 'VersionConfig.Current' src/shared/Config/VersionConfig.luau
  python3 scripts/studio_mcp.py luau 'return game.ReplicatedStorage.Shared.Config.VersionConfig.Source:match("Current = \"([^\"]+)\"")'
  ```
  For the file you just changed, compare a string you just added. If they differ, stop: the owner
  must click **Connect** (and accept) in the Rojo plugin. `rojo serve` runs on :34872. That is the
  only fix; never paste code through MCP. Rojo also cannot live-swap `Lighting` when
  `default.project.json` changes ("Could not swap instances Lighting"). Apply those values in edit
  mode as well, matching the project file.
- **CFrame teleports keep `CurrentWorld`.** See section 7.
- **`execute_luau` cannot see live state.** It gets a fresh module copy. Use
  `eval_server_runtime` / `eval_client_runtime` during a playtest.
- **"Start not detected" does not mean it did not start.** Always check `solo_playtest status`
  after a start error, and stop in a `finally:` block. That is how the 7-hour orphan happened.
- **Settle time.** Captures taken at 0.3 s catch half-finished tweens and re-layouts. Use 1–1.5 s,
  and longer after a world travel (streaming).
- **TopbarInset.** Captures omit the Roblox top bar, so a chip under it looks fine in the image but
  is covered on a real device. Layouts read `GuiService.TopbarInset` (ScreenManager listens to it
  changing). QA asserts clearance numerically per device, together with the thumbstick and jump
  zones on phones.
- **Join-flow pop-ups and tutorial gating** hide or delay chips (section 7). `close_all` before
  every shot.
- **One device per matrix call**, `target: "client-1"`, and no multiplayer clients.
- **Image tools through `rpc`, everything else through `call_tool`** (keeps the R72 guard).
- **Timeouts.** Raise `STUDIO_MCP_TIMEOUT` for long profiler or matrix calls. Recover a
  timed-out result with `get_request_status` instead of re-running a write.

## 14. Copy-paste recipes

**Solo playtest, gated on the lock** (replace `lead` with your agent name):

```bash
python3 scripts/studio-lock.py acquire lead && python3 scripts/studio_mcp.py call solo_playtest '{"action":"status"}'
# running=false and nobody else's? then start:
python3 scripts/studio-lock.py status | grep -q '"owner": "lead"' \
  && python3 scripts/studio_mcp.py call solo_playtest '{"action":"start","mode":"play","timeout":90}'
# ... work (eval_*_runtime, captures) within your 10-minute turn ...
python3 scripts/studio-lock.py status | grep -q '"owner": "lead"' \
  && python3 scripts/studio_mcp.py call solo_playtest '{"action":"stop","timeout":90}'
python3 scripts/studio-lock.py release lead
```

**Force an event in the live server, then read it back:**

```bash
python3 scripts/studio_mcp.py call eval_server_runtime \
  '{"code":"local S = require(game.ServerScriptService.Server.Services.HappyHourService); local ok, msg = S.force(\"confetti\", 120); return tostring(ok) .. \" \" .. msg"}'
python3 scripts/studio_mcp.py call eval_client_runtime \
  '{"code":"return game.Players.LocalPlayer:GetAttribute(\"LoadingDone\")","target":"client-1"}'
```

**Device matrix saved to disk** (during your playtest):

```bash
python3 - <<'EOF'
import base64, sys
from pathlib import Path
sys.path.insert(0, "scripts")
import studio_mcp
out = Path("docs/verification/my-feature"); out.mkdir(parents=True, exist_ok=True)
for d in ({"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
          {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
          {"label": "console", "deviceId": "xbox"}):
    r = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
        "entries": [d], "target": "client-1", "format": "jpeg", "quality": 88,
        "settleSeconds": 1.5, "restoreAfter": True}})
    imgs = [c for c in r.get("content", []) if c.get("type") == "image" and c.get("data")]
    if not imgs:
        print(d["label"], "FAILED", str(r)[:200]); continue
    p = out / f"my-feature-open-{d['label']}.jpg"
    p.write_bytes(base64.b64decode(imgs[0]["data"], validate=True)); print(p)
EOF
open docs/verification/my-feature/my-feature-open-*.jpg
```

**Run an existing QA runner:**

```bash
python3 scripts/studio-lock.py acquire E-events
STUDIO_LOCK_OWNER=E-events python3 tools/qa/happy_hours.py
python3 scripts/studio-lock.py release E-events
```

**Errors and warnings from the current session:**

```bash
python3 scripts/studio_mcp.py call get_runtime_logs '{"tail": 300, "filter": "HappyHour"}'
```

**Look up an engine API** without leaving the terminal:

```bash
python3 scripts/studio_mcp.py call get_roblox_docs '{"name": "GuiService", "section": "Properties"}'
```
