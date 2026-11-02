# SellNukes — Claude development guide

SellNukes is an **8-player linear button tycoon** for Roblox. Players start in a tiny garage with a
homemade reactor, click to assemble cartoon "pocket nukes", buy pads that build their business in
front of them (LEGO master-builder fly-in), automate with managers, and grow through ten themed
areas to a Mega Nuclear Facility (~8 h first run), then rebirth. Side systems: pets + eggs, supply
crates, daily / time rewards, lucky wheel, codes, group rewards, offline earnings, an optional
"send cartoon nukes at other plots / build AA towers" mode, and the Thanksgiving "Harvest Feast"
event. Kid-friendly: nukes are candy-coloured toys, explosions are confetti.

> Design spec: `docs/superpowers/specs/2026-10-30-sellnukes-design.md`
> Living system doc: `SELLNUKES_CLAUDE_DOCUMENTATION.md` (update after every task)
> Visual references + notes: `docs/reference/README.md`
> Framework source: the RoBeasts repo (`~/IdeaProjects/RoBeasts`). SellNukes reuses its UI framework
> (Create / Theme / Components / ScreenManager / stud panels), server patterns, toolchain and
> Blender → Roblox pipeline. When unsure how something is done, look there first.

## Hard product rules (owner — never violate)

1. **Fully autonomous.** Use every input the owner gives; never ask clarifying questions. Decide,
   document the decision in the spec/docs, keep building. Only stop for things only the owner can
   do (publishing, Robux spend, a Studio permission prompt) and say exactly what they must do.
2. **Stud-texture everything.** Every UI surface uses the RoBeasts stud panels; every world surface
   uses the stud material (see `docs/world-art.md`).
3. **Every model is built in Blender** (scripted `bpy` builders under `tools/blender/`), uploaded,
   and loaded as MeshParts. Primitive Parts only as the fallback while a mesh is not uploaded yet.
4. **Every purchase builds in** (fly-in, translucent → solid). No purchase just pops into existence.
5. **Secure and performant, no shortcuts.** Never simplify a requirement away.
6. **Every system ships with its full UI.** No backend without a finished frontend.
7. **Kid-friendly.** No real countries/weapons, no gore. Attack mode never PERMANENTLY takes
   anything (cash, pads, producers, levels, pets, gems are never removed); since owner R50 a hit
   may TEMPORARILY knock down the area it lands in (toy bricks topple, production pauses, then it
   auto-rebuilds with the fly-in).
8. **Document everything the owner says.** Append every owner message to
   `docs/owner-requests.md` (date, quoted key words, requirements, where implemented) before acting.
9. **Track everything.** Every system reports to the in-depth analytics layer (RoBeasts model), and
   every system is controllable from the owner-only admin panel where that makes sense.
10. **Subagents:** no cap; parallelise wherever file ownership allows.
11. **Console + mobile first (owner R11).** Every action has gamepad + touch + KB/M bindings; every
    screen is fully controller-navigable (`GuiService.SelectedObject`, sensible default selection,
    B/Back closes) with correct button-hint glyphs and TV-safe margins; phone/tablet layouts with
    ≥ 44 pt taps and readable text, clear of the thumbstick/jump zones. Verify every screen with
    `scripts/studio_mcp.py call capture_device_matrix` (phone, tablet, console) before reporting.
12. **Never open new Studio places (owner R33).** Use ONLY the already-open MCP-connected place
    ("Sell Nukes [🎃]") via `scripts/studio_mcp.py`. Never open/launch a `.rbxl(x)` built by
    `rojo build`, never call `manage_instance` with action `launch`, never start another Studio
    process. `rojo build` is only an offline check; its output is never opened.

## Serena — default for reading + editing Luau (owner R37, verified 2026-10-30)

Serena (`.mcp.json`, luau-lsp backend) works on this repo and saves a lot of context. Prefer it for
code work: `get_symbols_overview` (map a file's functions/types instead of reading it),
`find_symbol` with `include_body=true` (read ONE function), `find_referencing_symbols` (callers),
`replace_symbol_body` / `insert_after_symbol` / `insert_before_symbol` (symbol-level edits).
Fall back to `grep -n` + `sed -n a,bp` for non-code files or when Serena is not connected in a
session (load it with ToolSearch `select:mcp__serena__get_symbols_overview,...`; if no
`mcp__serena__*` tools exist, say so in your report and use excerpts). Never read whole large files.
Note (verified 2026-10-30): Serena is exposed to the LEAD session only — spawned subagents get no
`mcp__serena__*` tools, so builders use `grep -n` / `sed -n` excerpts.

## Toolchain (aftman — `aftman.toml`)

| Tool | Purpose |
|------|---------|
| `rojo` 7.7.1 | Sync `src/` into Studio (`rojo serve`, already running on :34872) |
| `luau-lsp` | Strict type-check (our `tsc --noEmit`) |
| `selene` | Lint |
| `stylua` | Format (tabs, 120 cols) |
| `lune` | Pure-logic tests (`tests/*.luau`), incl. the economy pacing simulator |
| `luau-compile` (Homebrew) | Studio-style bytecode compile gate |
| `blender` (Homebrew, `/opt/homebrew/bin/blender`) | Headless model builders |

```bash
./scripts/check.sh           # format check + lint + strict type-check + compile + lune tests — MUST pass before commit
./scripts/check.sh --fix     # stylua first, then all checks
python3 scripts/studio_mcp.py list           # Studio MCP tools (see below)
python3 scripts/studio_mcp.py luau 'return 1+1'
```

**After every task:** `./scripts/check.sh`, fix everything, update
`SELLNUKES_CLAUDE_DOCUMENTATION.md`, bump `VersionConfig` + `ChangeNotesConfig` for player-facing
changes, then commit.

## Roblox Studio MCP (IMPORTANT — which MCP)

Studio is driven by **`@chrrxs/robloxstudio-mcp` v3.2.1** — the "MCP Server" plugin in Studio's
Plugins toolbar, `http://localhost:58741`. It is **not** the old `RobloxGame/roblox-studio-mcp`
bridge (port 3001, `mcp__roblox-studio__*`), which usually fails to connect because another
process owns 3001.

One primary node process owns :58741 (often Codex's). If it dies ("connection refused", nothing
listening on 58741), only the lead restarts it — the pinned Codex wrapper, stdin held open:
`tail -f /dev/null | ~/.local/bin/robloxstudio-mcp-codex` (background; never two primaries; Studio's
plugin reconnects by itself). Any agent drives it over HTTP with
`scripts/studio_mcp.py`, which reads the auth token from `~/.robloxstudio-mcp/auth-token` (never
print it). 49 tools incl. `execute_luau`, `solo_playtest`, `multiplayer_playtest`,
`capture_screenshot`, `get_runtime_logs`, `upload_asset` (Open Cloud), `manage_monetization`
(create dev products / passes), `import_rbxm` / `export_rbxm`, `get_roblox_docs`.

The connected place is **"Sell Nukes [🎃]"** — placeId `132667741281890`, universe `10773845696`.

**No multiplayer playtests (owner R72).** Never start `multiplayer_playtest` (or `world2_check.py multi`);
solo playtests only. `scripts/studio_mcp.py` refuses it (only `status` / `end` pass, to stop a stray one).

Rules: **Rojo owns all code** (never edit scripts in Rojo containers through MCP). Use MCP to verify,
inspect, playtest, screenshot, upload assets and create monetization products. Anything that must
persist goes into the repo. Only one agent playtests at a time: `python3 scripts/studio-lock.py
acquire <name>` / `release <name>`. Before EVERY playtest start/stop, confirm `studio-lock.py status`
shows you as the holder; never start, stop or end a playtest you did not start, and never run
anything that ends a playtest while another agent holds the lock. Only exception: the **lead**
may stop an orphaned playtest after its owner's lock went stale (> 20 min) AND that agent is
confirmed dead — acquire the lock as `lead` first, stop, release (done 2026-10-30 for dead P1).

## Code conventions

- `--!strict` at the top of every Luau file; zero type errors.
- **Comment generously** (owner): module header (purpose, connections, usage example), doc comment on
  every public function (params, returns, why), comments on non-obvious math. Comment uncommented
  code you touch.
- Modern APIs only (`task.*`, constraint movers). No `wait`/`spawn`/`delay`, no deprecated body movers.
- `PascalCase.luau` modules; `init.server.luau` / `init.client.luau` entry points.
- Tunables live in `src/shared/Config/*`, never inline magic numbers.
- Big numbers are plain Luau doubles (fine to ~1e308); format with `NumberFormat` (K, M, B, T, Qa,
  Qi, Sx, Sp, Oc, No, Dc, ...).

## Security rules

- **Never trust the client.** All cash, gems, purchases, levels, rolls, timers, offline time and
  attack outcomes are computed on the server. Clients send *intents* only ("click producer 3",
  "buy pad X", "upgrade producer"), never amounts.
- Every remote handler: `typeof`-check every argument, validate ids against config tables, reject
  NaN/inf, clamp, per-player rate limits, and state checks (owns plot, pad unlocked, in range).
- Receipts are processed idempotently with a per-profile receipt ledger.
- No `loadstring`, no client-supplied instance paths, no server→client `RemoteFunction` invokes.
- Player text (stand names) goes through `TextService:FilterStringAsync` before display to others.

## Performance rules

- `Workspace.StreamingEnabled = true`. Unbought content is never instanced.
- One `RunService` connection per system, never per object. Producer ticks run on one server loop.
- No per-frame `Instance.new`; pool build-in ghosts, FX, popups.
- Billboards update on change events, not every frame; distant billboards disabled (`MaxDistance`).
- Meshes: one shared MeshPart template per mesh id, cloned; stud material via one shared texture set.

## Context budget

Keep sessions lean: read excerpts (`grep -n`, `sed -n`), delegate wide searches, builders send ONE
final report (≤ 250 words). Write state into docs/memory before suggesting `/compact`.

## Documentation

- `SELLNUKES_CLAUDE_DOCUMENTATION.md` — how systems connect, remotes, schemas, next steps.
- `docs/superpowers/specs/` approved specs; `docs/superpowers/plans/` implementation plans.
- `docs/reference/` owner reference images (inspiration only — SellNukes is an original game).
