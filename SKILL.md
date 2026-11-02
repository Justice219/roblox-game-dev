---
name: roblox-game-dev
description: >-
  The complete playbook for building Roblox games the SellNukes way — Rojo + strict Luau +
  Lune tests, a code-only stud-panel UI framework (console + mobile first), every model built in
  Blender with scripted bpy builders and uploaded as MeshParts, purchases that "build in" with a
  fly-in, Roblox Studio driven through the robloxstudio-mcp bridge (solo playtests, device-matrix
  screenshots shown to the owner), an in-depth analytics layer with a Roblox "Recommended for You"
  algorithm scorecard, an owner-only admin panel, secure server-authoritative economy /
  monetization / retention systems, and the owner-request + living-docs workflow. Use this skill
  whenever working on SellNukes or any Roblox / Luau game: adding a system or screen, making a
  model in Blender, taking or showing Studio screenshots, writing Lune tests or the economy
  simulator, answering a pasted analytics report, tuning pacing / prices, wiring dev products,
  admin controls, notifications, or bootstrapping a new Roblox project — even when the request
  does not say "skill" or "Roblox" explicitly (e.g. "the HUD covers my iPhone screen", "why are
  players leaving", "make the pet model", "show me a screenshot").
---

# Roblox game development — the SellNukes playbook

SellNukes is an 8-player, kid-friendly linear button tycoon on Roblox (cartoon toy nukes,
confetti explosions, ten themed areas, rebirth, pets, worlds, events). This skill is everything
that game's development taught: the owner's rules, the toolchain, how UI / art / tests /
analytics / admin are built, and how work is verified and reported. Use it as the default way to
build any Roblox game; swap names and themes, keep the discipline.

The owner is a non-programmer who plays on iPhone, tablet, console and desktop, pastes analytics
reports and screenshots, and expects finished, verified work without being asked questions.

## How to use this skill

Read this file first, then open only the reference you need:

| You are about to… | Read |
|---|---|
| Start any task in this repo (rules, request log, docs, commits, builders) | `references/owner-rules-and-workflow.md` |
| Set up tools, understand the repo layout, bootstrap a new game | `references/toolchain-and-repo.md` + `assets/templates/` |
| Build or change any UI (HUD, screens, chips, popups, controller / phone layout) | `references/ui-framework.md` |
| Match the owner's visual references (stud panels, reward screens, billboards, silos) | `references/reference-screenshots.md` + `assets/reference/` |
| Make a model, icon or billboard in Blender and load it in Roblox | `references/blender-art-pipeline.md` |
| Place things in the world, area layouts, purchase build-in fly-ins | `references/world-art-and-build-in.md` |
| Drive Studio, playtest, take device-matrix screenshots, show them to the owner | `references/studio-mcp-and-screenshots.md` + `scripts/studio_mcp.py`, `scripts/studio-lock.py` |
| Write or run tests, tune the economy simulator, pass `check.sh` | `references/testing.md` + `scripts/check.sh` |
| Add telemetry, read / answer an analytics report, the Roblox algorithm scorecard | `references/analytics.md` |
| Add owner-only controls, kill switches, forced events | `references/admin-panel.md` |
| Write services, remotes, data stores, receipts; security + performance rules | `references/server-architecture-and-security.md` |
| Design or tune a game system (economy, monetization, retention, pets, events, attack) | `references/game-systems-design.md` |

## The non-negotiables (why they exist)

1. **Act autonomously.** Never ask the owner clarifying questions. Decide, write the decision
   into the docs, keep building. Stop only for things only the owner can do (publishing, Robux
   spend, a Studio permission / Rojo connect prompt) and say exactly what to click.
2. **Log every owner message first.** Append it to `docs/owner-requests.md` as the next `R<N>`
   (date, quoted words, requirements, "→ who"). Add the "Done / Implemented" line when finished.
   The log is the project's memory across sessions; an unlogged request is a lost request.
3. **Stud texture everything.** Every UI surface uses the stud panels and every world surface
   the stud material. The look is the brand.
4. **Every model is built in Blender** (scripted `bpy` builders), uploaded, and loaded as
   MeshParts. Primitive Parts are only a placeholder until the mesh exists.
5. **Every purchase builds in** (fly-in, translucent → solid). Nothing pops into existence.
6. **Secure and performant, no shortcuts.** The server owns all cash, rolls, timers and
   outcomes. Clients send intents, never amounts. Never simplify a requirement away.
7. **Every system ships with its full UI, analytics and admin controls.** A backend without a
   finished frontend does not count as done.
8. **Kid-friendly.** No real countries or weapons, no gore. Attack mode never permanently takes
   anything.
9. **Console + mobile first.** Every action has gamepad, touch and keyboard/mouse bindings, and
   every screen is controller-navigable. Taps are ≥ 44 pt, nothing covers the thumbstick / jump
   zones, and the iPhone view is not cluttered.
10. **Verify before claiming.** `./scripts/check.sh` must end in `[check] ALL PASSED` before
    every commit. Studio playtests are solo only and run under the studio lock. When the owner
    asks to *see* something, take the screenshot.

## The loop for any task

1. **Log** the request (R-number) in `docs/owner-requests.md`.
2. **Read** only what you need. Use Serena symbol tools for Luau (`get_symbols_overview`,
   `find_symbol` with a body, `replace_symbol_body` / `replace_content`); use `grep -n` /
   `sed -n` excerpts for everything else. Never read huge files whole.
3. **Design** the pure logic in a testable `…Logic.luau` module (no Instances), the tunables in
   `src/shared/Config/*`, then the Instance / UI code around it.
4. **Build** server → client UI → analytics keys (documented in `AnalyticsConfig.Metrics`) →
   admin controls → docs. Comment generously: a module header (purpose, connections, example)
   and doc comments on public functions.
5. **Test.** Add or extend a Lune suite in `tests/`, including a regression test that would fail
   on the old code. Run `./scripts/check.sh --fix` until ALL PASSED.
6. **Verify in Studio when allowed or asked:** studio lock → solo playtest → force the state →
   `capture_device_matrix` (phone, tablet, console) → stop → release. Show the owner the image
   paths. If Studio still runs the old code, the Rojo plugin needs reconnecting: tell the owner.
7. **Document.** Update the system's `docs/<system>.md`, the change log in
   `SELLNUKES_CLAUDE_DOCUMENTATION.md`, and the request's Done line. For player-facing changes,
   bump `VersionConfig` and add a WHAT'S NEW line (`ChangeNotesConfig`).
8. **Commit only your own files.** Other sessions may share the tree. End the message with the
   co-author line. The owner publishes.
9. **Report** in plain language: what changed for players, the numbers, what the owner must do,
   and what to watch in the next analytics report.

Parallelise with builder subagents when file ownership allows. Give each builder an exact file
scope and no Studio access; ask for one final report of ≤ 250 words; the lead commits.

## Quick commands

```bash
./scripts/check.sh            # stylua --check, selene, strict luau-lsp, luau-compile, all Lune suites
./scripts/check.sh --fix      # format first (lead only), then everything
lune run tests/<suite>        # one suite
lune run tests/economy-sim.luau --tune [--write] [--upto <area>]   # pacing simulator / SCALE tuner
~/.aftman/bin/rojo serve      # live sync src/ → Studio (the Studio Rojo plugin must be connected)
python3 scripts/studio-lock.py status|acquire <name>|release <name>
python3 scripts/studio_mcp.py list | schema <tool> | luau '<code>' | call <tool> '<json>'
/opt/homebrew/bin/blender -b --python tools/blender/<builder>.py   # headless model builds
```

## Answering a pasted analytics report (the owner's most common ask)

The owner pastes the admin panel's "COPY FOR AI" report and asks "any news?" or "why are people
leaving?". Do this:

1. **Log it.** Then split every headline number by build (the "Builds" table): a day mixes old
   and new servers, so compare the newest build against the old one on the same keys.
2. **Correct for coverage and survivorship.** Newer counters only exist on newer servers, so
   divide by those servers' own denominators. Late-funnel pacing averages only include the
   players fast enough to get there.
3. **Check suspicious numbers in the code** (e.g. a step at 30 % while its client arrow shows
   90 %). Fix measurement bugs with regression tests before drawing conclusions.
4. **Answer the report's nine questions** with numbers: funnel drops, pacing vs targets, stalls,
   sessions / D1, offers, retention systems, engagement + health, concrete changes (each with
   the metric that should move), and the algorithm scorecard rows below target.
5. **Propose, then ship when told** ("do it", "do whatever you want and fix"). Re-pace with the
   economy simulator; never guess prices.

Details, worked examples and every key: `references/analytics.md`.

## Showing the owner screenshots

The owner wants to *see* changes on real devices. Use `capture_device_matrix` with phone
(e.g. `iphone_14`, landscape), tablet and console presets during a solo playtest. Force the game
state first (admin APIs via `execute_luau` on the server, e.g. a forced Happy Hour; real world
travel, not CFrame teleports). File the captures under `docs/verification/<feature>/` with a
README saying what to look at, and give the owner the paths. Recipes:
`references/studio-mcp-and-screenshots.md`.

## Bootstrapping a new Roblox game this way

Copy `assets/templates/` (aftman.toml, default.project.json, selene.toml, stylua.toml,
dot-luaurc → `.luaurc`, dot-mcp.json → `.mcp.json` with your path) and `scripts/` into the new
repo. Then install the tools (`aftman install`) and create `src/{client,server,shared}` plus
`tests/`, `docs/owner-requests.md`, `<GAME>_CLAUDE_DOCUMENTATION.md` and a project CLAUDE.md
holding the non-negotiables above. Port the UI kit (Create / Theme / StudUI / ScreenManager /
HudZones) and the Analytics + Admin modules from the SellNukes / RoBeasts repos. The full
step-by-step is in `references/toolchain-and-repo.md`.

## Bundled files

- `scripts/check.sh`, `typecheck.sh`, `compilecheck.sh`, `test-logic.sh`, `lib/tools.sh`: the
  check gate (adjust paths for a new repo).
- `scripts/studio_mcp.py`: CLI for the robloxstudio-mcp HTTP bridge. It reads the auth token from
  `~/.robloxstudio-mcp/auth-token` and never prints it.
- `scripts/studio-lock.py`: the one-playtester-at-a-time lock.
- `assets/templates/`: toolchain and project config files.
- `assets/reference/`: the owner's UI / world reference screenshots, compressed and described in
  `references/reference-screenshots.md`. They are inspiration only; the game stays original.
