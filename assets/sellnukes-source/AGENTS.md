# SellNukes — Codex / GPT development guide

## Required project context

Before working in this repository, read and follow these shared documents:

1. `CLAUDE.md` — the canonical development rules for **both Claude and Codex**. Read the
   entire file; its product, security, performance, commenting, toolchain, testing, and
   documentation requirements apply here without modification.
2. `SELLNUKES_CLAUDE_DOCUMENTATION.md` — the shared living architecture and system documentation.
   Keep updating this file after tasks; do not create a competing GPT/Codex architecture copy.
3. `docs/superpowers/specs/2026-10-30-sellnukes-design.md` — the approved game design spec.
4. `docs/superpowers/plans/2026-10-30-sellnukes-build.md` — the build plan: directory layout, file
   ownership per builder and the interface contracts (remotes, profile schema, service APIs).
   Its worker-only prohibition on commits applies to delegated workers; the lead commits after
   verification. Preserve unrelated changes and stage only the current task's changes.

This entry point deliberately references the canonical rules instead of duplicating them, so
future Claude documentation changes also reach Codex. Treat "Claude agent" in the shared docs
as any development agent unless the text specifically describes Claude's tooling.

## Codex tooling

- **Use Serena for file operations whenever available** (`.mcp.json` registers it for this
  repo). If it is not exposed in the session, say so and use the available filesystem tools; do
  not claim Serena was used.
- The framework SellNukes reuses lives in the RoBeasts repo (`~/IdeaProjects/RoBeasts`). When
  unsure how a system is done (UI kit, profile store, receipts, delta sync), read it there first.
- Studio is driven by the `@chrrxs/robloxstudio-mcp` plugin on `http://localhost:58741` through
  `python3 scripts/studio_mcp.py` (see `CLAUDE.md`). Hold the Studio lock around playtests:
  `python3 scripts/studio-lock.py acquire <name>` / `release <name>`. Never kill another agent's
  bridge process or interrupt its playtest.
- Rojo owns all code: never edit scripts inside Rojo-managed containers through Studio.
- After every task run `./scripts/check.sh` (format, lint, strict Luau type-check, Studio-style
  compile, lune regressions), update `SELLNUKES_CLAUDE_DOCUMENTATION.md`, bump
  `VersionConfig` + `ChangeNotesConfig` for player-facing changes, and commit the task's
  changes. `./scripts/typecheck.sh` is this project's `tsc --noEmit` equivalent; there is no
  TypeScript app to build. Do not reformat unrelated work in this shared tree.
