# roblox-game-dev — a Claude Code skill

The complete playbook for building Roblox games the way **SellNukes** is built: the owner's
rules, the toolchain, the code-only stud-panel UI framework, the Blender → Roblox art pipeline,
Studio automation with device-matrix screenshots, Lune testing and the economy simulator, the
analytics layer with the Roblox "Recommended for You" algorithm scorecard, the owner-only admin
panel, server security, and the game-system design patterns.

## Install

Clone it into your Claude Code skills folder:

```bash
git clone https://github.com/Justice219/roblox-game-dev.git ~/.claude/skills/roblox-game-dev
```

Claude Code loads it automatically from `~/.claude/skills/`. It triggers on Roblox / Luau work:
new systems or screens, Blender models, Studio screenshots, tests, analytics reports, pacing,
monetization, admin controls, or starting a new Roblox project.

## Contents

| Path | What it is |
|---|---|
| `SKILL.md` | Entry point: non-negotiables, the task loop, quick commands, which reference to open |
| `references/owner-rules-and-workflow.md` | Owner rules, the R-numbered request log, living docs, versioning, commits, builder subagents |
| `references/toolchain-and-repo.md` | aftman / Rojo / luau-lsp / selene / stylua / Lune, repo layout, conventions, bootstrapping a new game |
| `references/ui-framework.md` | Design-px canvas, device scaling, StudUI stud panels, ScreenManager, HudZones, controller + phone rules |
| `references/reference-screenshots.md` | Every owner reference image, what it shows, what was taken from it |
| `references/blender-art-pipeline.md` | Scripted `bpy` builders, headless Blender, upload, MeshPart templates, icons, audits |
| `references/world-art-and-build-in.md` | Stud world art, area layouts, the purchase fly-in build-in, art performance |
| `references/studio-mcp-and-screenshots.md` | robloxstudio-mcp, `studio_mcp.py`, the studio lock, solo playtests, device-matrix screenshots |
| `references/testing.md` | `check.sh`, Lune suites, loaders / fixtures, the economy simulator and tuner, audits |
| `references/analytics.md` | Recorder, funnels, retention, build slices, the algorithm scorecard, reports, answering them |
| `references/admin-panel.md` | The owner-only admin panel, its tabs, controls and security |
| `references/server-architecture-and-security.md` | Services, validated remotes, data / receipts, performance rules, the security checklist |
| `references/game-systems-design.md` | Tycoon economy, monetization, retention, pets, events, attack mode, a new-system checklist |
| `scripts/` | `check.sh` (+ typecheck / compile / test runners), `studio_mcp.py`, `studio-lock.py` |
| `assets/templates/` | aftman.toml, default.project.json, selene.toml, stylua.toml, `.luaurc`, `.mcp.json` |
| `assets/reference/` | The owner's reference screenshots, compressed |

## Notes

- No secrets are included. Tokens and API keys stay where the scripts read them
  (e.g. `~/.robloxstudio-mcp/auth-token`, the experience's secrets store).
- The reference screenshots are inspiration only; SellNukes is an original, kid-friendly game.
- The source of truth stays the SellNukes repo (its `docs/`, `CLAUDE.md` and
  `SELLNUKES_CLAUDE_DOCUMENTATION.md`). Refresh this skill when those change a lot.
