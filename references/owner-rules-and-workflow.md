# Owner rules and development workflow

This file captures how work is organised on SellNukes (an 8-player Roblox button tycoon built with
Claude Code lead sessions plus many parallel builder subagents): the owner's hard product rules
and the reasons behind them, the owner-request log, the R-numbered rules that changed how agents
work, the living docs, specs and plans, versioning and WHAT'S NEW notes, the "after every task"
checklist, commit discipline in a tree several sessions share, the lead / builder split, Serena,
and how to answer analytics reports the owner pastes in. Every section names the SellNukes
specifics first and then states the general pattern, so the same workflow carries over to a new
Roblox game. Paths are relative to the game repo root unless stated otherwise.

## Contents

1. [Hard product rules](#1-hard-product-rules)
2. [The owner-request log](#2-the-owner-request-log)
3. [R-numbered rules that shape the work](#3-r-numbered-rules-that-shape-the-work)
4. [Living documentation](#4-living-documentation)
5. [Specs and plans](#5-specs-and-plans)
6. [Versioning and WHAT'S NEW notes](#6-versioning-and-whats-new-notes)
7. [The "after every task" checklist](#7-the-after-every-task-checklist)
8. [Commit discipline in a shared tree](#8-commit-discipline-in-a-shared-tree)
9. [Lead and builder subagents](#9-lead-and-builder-subagents)
10. [Studio etiquette](#10-studio-etiquette)
11. [Serena](#11-serena)
12. [Answering analytics reports](#12-answering-analytics-reports)

---

## 1. Hard product rules

These rules live in the game's `CLAUDE.md` under "Hard product rules (owner — never violate)".
They override convenience. When a rule and a request seem to conflict, follow the rule and log
the conflict in the owner-request log (section 2). For a new game, copy all twelve and adjust
only the game-specific nouns.

| # | Rule | Why | How to apply |
|---|------|-----|--------------|
| 1 | **Fully autonomous.** Use every input the owner gives and never ask clarifying questions. Decide, document the decision in the spec or docs, and keep building. | The owner runs many agents at once and is not at the keyboard to answer questions. A question stalls the whole wave. A documented decision is cheap for the owner to overturn later. | Write `Decision (autonomous, rule 1): ...` in the spec and in the request's log entry. Stop only for things only the owner can do: publishing, Robux spend, Studio permission prompts, or Creator Dashboard actions that need their account. Say exactly what they must do; these go under "Next steps" in the living doc. |
| 2 | **Stud-texture everything.** Every UI surface uses the stud panels and every world surface uses the stud material. | The brand is one cohesive toy look, taken from the owner's reference UI and shared with the sister game RoBeasts. Mixing flat panels breaks it at once. | UI goes through the stud kit (`src/client/UI/Kit/StudUI.luau`, `Create`, `Theme`, `Components`). World meshes get the stud `MaterialVariant`s (`StudsSmall` / `StudsLarge`). See `docs/world-art.md`. |
| 3 | **Every model is built in Blender.** Scripted `bpy` builders under `tools/blender/` produce each model, which is uploaded and loaded as MeshParts. Primitive Parts are only a fallback until the mesh is uploaded. | Primitives look "grey/primitive" (owner R1). Scripted builders are reproducible, diffable, and rebuildable by any agent. | `tools/blender/models/<name>.py` → `generate_world.py --only Keys` → `upload_meshes.py` → `sync_meshes.py` → `src/shared/Config/MeshAssets.luau`. Another reference file covers the pipeline. |
| 4 | **Every purchase builds in** (fly-in, translucent → solid). Nothing just pops into existence. | The LEGO-style "master builder" assembly is the core payoff for spending (R1), and it makes every button press feel worth it. | Run each pad, area or prop through the build-in plan (`src/client/Tycoon/BuildIn/*`, `BuildInConfig`). Pool the ghosts. A knockdown also rebuilds with the same fly-in (R50). |
| 5 | **Secure and performant, no shortcuts.** Never simplify a requirement away. | It is a live game with real Robux and exploiters, and it runs on phones and consoles. It is also the owner's global rule across every project. | Keep the server authoritative, validate every remote, rate-limit, process receipts idempotently, use one loop per system, pool objects. Never "stub it for now" without logging the gap. |
| 6 | **Every system ships with its full UI.** A backend without a finished frontend is not done. | The owner has repeatedly received backends with empty or missing screens. A system players cannot reach does not exist for them. | In the same task, ship the server, the screen, the HUD entry, controller navigation, phone, tablet and console layouts, analytics, and admin controls. |
| 7 | **Kid-friendly.** No real countries or weapons, no gore. Attack mode never PERMANENTLY takes anything. Since R50 a hit may TEMPORARILY knock down an area. | The audience is children. The Roblox content-maturity questionnaire was answered from the real systems, so the game must stay true to those answers. | Nukes are candy-coloured toys and explosions are confetti. Knocked-down toy bricks topple, production pauses, and the area auto-rebuilds. Cash, pads, producers, levels, pets and gems are never removed. |
| 8 | **Document everything the owner says.** Append every owner message to `docs/owner-requests.md` before acting. | R8: "Just document everything I say." Sessions get compacted, accounts switch, and dozens of agents come and go. The log is the only durable record of intent, and it shows where each request landed. | Follow the format in section 2. Write the entry first, then act, then add a `Done` line. |
| 9 | **Track everything.** Every system reports to the analytics layer and is controllable from the owner-only admin panel where that makes sense. | Design decisions come from live data (R122, R129, R135). Admin toggles let the owner tune or disable a feature live without republishing. | Each system gets analytics recorders (allowlisted keys) and admin handlers. Another reference file covers analytics and admin. |
| 10 | **Subagents: no cap.** Parallelise wherever file ownership allows. | Throughput. The owner wants many features per day. | Give builders disjoint file ownership (section 9). The lead owns the shared files. |
| 11 | **Console + mobile first** (R11). | Most Roblox players use a phone or console. Without a real controller handler and good touch layouts the game bounces those players. | Give every action gamepad, touch and keyboard/mouse bindings. Make every screen navigable through `GuiService.SelectedObject` with a default selection, and make B/Back close it. Use correct glyphs, TV-safe margins and taps of at least 44 pt, and keep controls clear of the thumbstick and jump zones. Verify with `capture_device_matrix`, unless R132 applies (section 3). |
| 12 | **Never open new Studio places** (R33). | Agents opened `rojo build` outputs, which started extra Studio processes. The MCP-connected place lost focus and other agents' work broke. | Use only the open, MCP-connected place through `scripts/studio_mcp.py`. `rojo build` is an offline check whose output is never opened. Never call `manage_instance` with action `launch`. |

The Studio section of `CLAUDE.md` adds three standing rules that count as hard rules:

- **Rojo owns all code.** Never edit scripts in Rojo-managed containers through MCP. Studio edits are
  lost on the next sync and diverge from git.
- **Solo playtests only** (R72).
- **Hold the Studio lock** around every playtest start or stop (section 10).

---

## 2. The owner-request log

`docs/owner-requests.md` is append-only. Its header states the rule: "Append a new entry for every
owner message (quote the key words, then the concrete requirements it creates and where they are
implemented). Never delete entries; mark superseded ones instead."

### Entry format

```markdown
## YYYY-MM-DD — <session or theme title>

### R<n>. <short imperative title>
> "<the owner's exact words, typos kept>" (context: pasted report headline numbers,
> or a description of the screenshot they attached)

- <concrete requirement the message creates>
- <constraint or decision; "Decision (autonomous, rule 1): ..." when you chose>
→ <who: lead / builder name>; <where: CLAUDE.md rule, doc, spec>
- Done (<who>, <version>): <what shipped: files, numbers before → after, tests, docs>.
- Findings (lead): <for questions and reports>.
- Proposed next (not shipped; owner "do it"): <changes waiting for a go>.
- Follow-up: "<later owner words on the same topic>" — <what it changes>.
```

Conventions:

- **R numbers are global and sequential** (R1 … R139 so far). Before writing a new number, grep
  for the newest `### R` heading again. Other sessions append at the same time, and two sessions
  once both wrote R128 to R130 on the same day.
- **Quote first.** Keep the owner's typos (`"stop runing multiplayer playtests"`). The quote is
  evidence, and the requirements underneath are your interpretation.
- **Describe screenshots in words** (what is on screen, where, how big), so the entry still makes
  sense without the image. Never copy players' usernames or the owner's name into the skill.
- **`→ who`** names the owner of the work, so a later session can see who to ask or where the
  work went.
- **Superseded entries are marked, never deleted.** Put a quote line at the top of the old entry:
  `> **Superseded by R128 (2026-11-01): the Order Window system was removed.**`
- **Owner corrections overturn rules explicitly.** R50 amended hard rule 7, and the entry says so
  ("Owner overrides the old 'target never loses anything' rule (hard rule 7 updated)").

### Real examples (trimmed)

```markdown
### R33. Never open new Studio places
> "some of the subagents keep opening different places in Roblox. We are connected to MCP. They do
> not need to be opening new places from the build file."

- Agents must ONLY use the already-open, MCP-connected place ("Sell Nukes [🎃]", placeId
  132667741281890) through `scripts/studio_mcp.py`. Never `open`/launch a `.rbxl/.rbxlx` from
  `rojo build`, never `manage_instance` action=launch, never start another Studio process.
  `rojo build` is allowed only as an offline check (never opened). → CLAUDE.md hard rule 12.
```

```markdown
### R132. No Studio playtests for these changes
> "skip any studio playets for your changes, just code checks thats it"

- The lead's R122–R128 / R131 changes are verified with code checks only (`./scripts/check.sh`:
  format, lint, strict types, compile, Lune suites); no Studio playtest is started for them.
```

```markdown
### R137. "do whatever you want and fix"
> "Once you figure it out, do whatever you want and fix."

- Ship the R135 / R136 proposals: area 2 re-pace (Cashier Bot early, smooth the price jumps), a
  quicker first two minutes in area 1, record offer BUY presses (`Revenue.offerClicked` has no
  caller). Code checks only (R132). → lead + builders.
- Done (lead + W-R137-econ / W-R137-offers, 0.9.2): area 1 Tool Wall $11 / Glow Lamp $19 (sim 0.48 /
  0.64 min ...); area 2 Cashier Bot pad 4 (0.85 min after opening, was 6.5 ...); offer BUY presses
  counted server-side ... WHAT'S NEW: two IMPROVED lines.
```

**General pattern:** use one append-only log per game with sequential request ids, a quote, the
requirements, the owner of the work, and a done line. Reference the ids everywhere: commit
subjects `(R137)`, changelog headings, spec titles, code comments, test names.

---

## 3. R-numbered rules that shape the work

Most requests are features. A few changed how every agent works from then on. Each of these
lands in `CLAUDE.md` and/or a memory file, and the newer ones win over older defaults.

| R | Owner's words | Standing rule | Enforcement |
|---|---------------|---------------|-------------|
| R8 | "Just document everything I … say." | Log every message before acting. | Hard rule 8; memory. |
| R11 | "The game is optimized for console and mobile … we need to make sure we have a controller handler and on mobile the UI doesn't look too bad." | Console and mobile come first: controller handler, `SelectedObject` navigation, button glyphs, haptics, phone and tablet layouts, taps of at least 44 pt, TV-safe margins. | Hard rule 11; `src/client/Platform/*`; `docs/platform.md`; `capture_device_matrix`. |
| R12 | "have them just open images. Open the files" | When an art agent finishes a preview, contact sheet or Studio shot, run `open <file>` on the owner's Mac as well as listing the path. | Lead relays builders' images. |
| R33 | "They do not need to be opening new places from the build file." | Use only the open, MCP-connected place. | Hard rule 12. |
| R37 | "if it saves on tokens, you probably should [use Serena]" | Serena symbol tools are the default for Luau code work. | `CLAUDE.md` Serena section (section 11). |
| R72 | "stop runing multiplayer playtests" | Solo playtests only. An 8-client test that reported `multiplayer_start_not_detected` was never ended, ran for about 7 hours, exhausted memory and hung Studio for every agent. | `scripts/studio_mcp.py` `guard_tool` refuses `multiplayer_playtest` (only `status` / `end` / `stop` pass). |
| R92 | "bro just finish em it just feels like they are oging in circles" | When builders run in parallel, they write code, Lune tests and a green `check.sh` only, with no Studio. The lead runs ONE consolidated Studio pass, then commits. Never park finished work behind flags. | Memory `builders-no-studio`; every builder brief. |
| R132 | "skip any studio playets for your changes, just code checks thats it" | Verify your own changes with `./scripts/check.sh` only. Do not start solo playtests or device-matrix captures. List what the owner should look at in Studio ("Owner eyeball: ..."). The owner playtests live while agents work, and an agent playtest collides with theirs. | Memory `code-checks-only`; overrides the capture step of rule 11. |
| R138 follow-up | "show me an ss when you do it" | An explicit request for a screenshot is the exception to R132. Run a solo Studio check while holding the lock, and send the image. | Per request only. |

**General pattern:** when the owner corrects how you work, rather than what you build, log it
as an R entry. Add it to `CLAUDE.md` or a memory file with the reason (**Why:**) and how to
apply it, and enforce it in a script when that is possible (`guard_tool`). Newer rules
override older ones, so record which one they override.

---

## 4. Living documentation

### The game-wide living doc

The file is `SELLNUKES_CLAUDE_DOCUMENTATION.md` at the repo root. The owner's global rule names it
`<GAME>_CLAUDE_DOCUMENTATION.md`. There is one per repo, shared by Claude and Codex
(`AGENTS.md` says "do not create a competing GPT/Codex architecture copy"). Its fixed shape:

| Section | Content |
|---------|---------|
| Header | "How the game's systems connect, their schemas and remotes, and what comes next. Newest dated entries first under 'Change log'. Read only the section you need (grep the headings)." |
| 1. Big picture | Concept, framework reuse, and an ASCII client ↔ server diagram (intents up, deltas down). |
| 2. Studio + tooling | MCP port and driver script, place and universe ids, Rojo port, playtest lock. |
| 3. Systems | One row per system: System, Server modules, Client modules, Config, Doc. |
| 4. Next steps | Per release: **owner actions** (publish, Creator Dashboard, ids to create) and **team next** (what to measure, when). |
| Change log | `### YYYY-MM-DD — <version>: <title> (owner R<n>)`, newest first. |

Change-log entry template (modelled on the 0.9.2 entry):

```markdown
### 2026-11-01 — 0.9.2: <player-facing title> (owner R137)

Owner: "<quote>" (<context, e.g. the report numbers that motivated it>).
Builder <name>, <how it was measured, e.g. sim-measured (`tests/economy-sim.luau`)>:
- **<Area / system>** (`src/shared/Config/TycoonAreas/Area01`, ...): <before → after numbers>.
- <Second change, with the module and the rule it keeps (e.g. "old saves safe, tests/stand-order.luau")>.
- VersionConfig 0.9.2 (PATCH, tuning) + two IMPROVED lines on the newest note.
Owner eyeball (R132, code checks only): <what to look at in Studio>.
Measure on the 0.9.2 build slice: `build:0.9.2:*` <metrics>.
```

Measurement-only entries say so in the heading, e.g.
`### ... — R136 return-notification failure reasons (measurement only)`, and state "no
player-facing change, so no version bump".

### Per-system docs

Each system has `docs/<system>.md` (core, economy, tycoon-server, tycoon-client, ui, icons,
world-art, areas-art, build-in, audio, analytics, analytics-scorecard, admin, monetization,
retention, pets, attack, event, leaderboards, platform, performance, security-audit,
change-notes, worlds, ...). The common shape:

1. A title with the owner R number and builder, e.g. `# Mega Lever + Tip Jar — hands-on plot props (owner R90 / R93, builder K-kinetic, 2026-10-31)`.
2. The owner's quote and a link to the spec section.
3. A **How it works** table with Piece, File and Job columns.
4. Behaviour rules (who sees what, when).
5. **Security**: remote verbs, validation, rate limits, and what is never granted.
6. **Analytics**: exact keys and families.
7. **Admin**: commands and where they are in the panel.
8. **Tests**: suites and sections.
9. **Studio verification**: date, agent, whether the lock was held, the QA script, and capture paths under `docs/verification/<system>/`.

Later fixes append a numbered section (`docs/attack.md §21`) rather than rewriting history.
Module headers in code point back to the doc, and the doc points to the modules.

### Other docs

- `docs/reference/`: the owner's reference images with an annotated `README.md`. They are
  inspiration only, because the game is original.
- `docs/verification/<system>/`: Studio captures and their READMEs.
- `AGENTS.md`: a short entry point for Codex that points at `CLAUDE.md` rather than duplicating it.

---

## 5. Specs and plans

The specs and plans live under `docs/superpowers/` (they follow the superpowers brainstorming,
writing-plans and executing-plans skills).

| Kind | Path pattern | Content |
|------|--------------|---------|
| Spec | `docs/superpowers/specs/YYYY-MM-DD-<slug>-design.md`, e.g. `2026-11-01-r122-algorithm-pack-design.md` | The owner quote and request id. "Autonomous decision (CLAUDE.md rule 1)". The research behind it, with sources and the date read (e.g. the Roblox discovery ranking signals). One section per feature. A statement that every change ships with server, full UI, analytics, admin, Lune tests and docs, with references to rules 5, 6, 9, 11 and 7. |
| Plan | `docs/superpowers/plans/YYYY-MM-DD-<slug>-build.md`, e.g. `2026-10-30-sellnukes-build.md` | A **Waves** table (wave, builder, owned paths, depends on). The directory layout with the owning builder per path. **Contracts**: every remote pre-declared, the profile schema, server and client APIs, mesh and layout interfaces. Worker rules. A **Live assignments** table kept by the lead. After a session-limit restart, a **coverage audit** that maps every earlier builder to where its unfinished work went (owner R36: "did you actually re-run all the agents?"). |

Write the spec before a multi-system wave and the plan before parallel builders start. The plan's
contracts let builders work without touching each other's files. Small fixes skip both and live
in the request entry plus the per-system doc.

---

## 6. Versioning and WHAT'S NEW notes

The system is identical to RoBeasts. A note written for one game drops into the other.

| File | Role |
|------|------|
| `src/shared/Config/VersionConfig.luau` | `Current` semver ("0.9.2"), `parse`, `compare`, `label()`, `menuText(game.PlaceVersion)` ("v0.9.2 · build N"). |
| `src/shared/Config/ChangeNotesConfig.luau` | The append-only `Notes` list, text caps, tags, CTA screens, `validate()`. |
| `docs/change-notes.md` | The authoring workflow and rules. |
| `tests/change-notes.luau` | `validate()` plus truth checks, run by every `check.sh`. |

### When to bump

| Change | Bump | WHAT'S NEW |
|--------|------|------------|
| Player-facing **feature** | MINOR `0.8.0 → 0.9.0` (PATCH back to 0) | Append ONE new note with `Version = Current`. |
| **Fix or tuning** a player can notice | PATCH `0.9.1 → 0.9.2` | Append one-line items (usually `FIXED` / `IMPROVED`) to the NEWEST note. The note keeps its Version. |
| Relaunch-sized change (the owner decides; `1.0.0` = public launch) | MAJOR | A new note. |
| Internal only (tests, docs, admin tools, refactors, analytics measurement fixes) | none | none |

### Note rules (enforced by `validate()`)

- **Never edit, reorder or remove an older note's `Id`.** Ids are save data (`profile.notes.seen`),
  and renaming one replays or loses the pop-up for every player.
- The Id is `"YYYY-MM-DD-short-slug"`: lowercase letters, digits and dashes, at most 32 characters
  in SellNukes because it is part of an analytics key (RoBeasts allows 48). The date part must
  equal the note's `Date`, and `Date` must be later than the previous note's.
- Limits: title ≤ 40, tagline ≤ 90, heading ≤ 20, item ≤ 72 (one line), CTA label ≤ 18,
  ≤ 3 sections, ≤ 6 items per section. Tags are `NEW`, `IMPROVED`, `FIXED` and `LIMITED`.
- Every version is strict semver with no leading zeros. Versions never go down. `Current` is at
  least the newest note's Version and has the same MAJOR.MINOR (a MINOR bump without its note
  fails the check).
- Keep notes **true and player-facing**: check every number against config and add a truth check
  to `tests/change-notes.luau` §3. Leave out internal names, analytics and admin tools. Keep it
  kid-friendly.
- **Publishing early**: `ShowFrom = unixDate(y, m, d)` hides a note until that time. While it is
  hidden, `VisibleVersion` keeps the label at the last version players saw.
- Only returning players who finished the tutorial get the pop-up, once per join and at a calm
  moment. New players have the newest note marked seen at load.

---

## 7. The "after every task" checklist

1. **Log the owner message** in `docs/owner-requests.md` (section 2), before acting.
2. **Build the whole system**: server-authoritative logic, the full UI on every device, analytics
   recorders, admin controls, and Lune tests that load the real modules.
3. **`./scripts/check.sh`** must print `[check] ALL PASSED`. Fix everything it reports. Workers
   never run `--fix` on the shared tree; they format their own files only.
4. **Docs**: update the per-system `docs/<system>.md` and add a change-log entry to the living doc
   (plus a Systems row or a Next steps line if they changed).
5. **Player-facing?** Bump `VersionConfig.Current` and update `ChangeNotesConfig` (section 6),
   with truth checks for new numbers.
6. **Close the loop** in the request entry with a `Done (<who>, <version>): ...` line.
7. **Verification level**: code checks only (R132) unless the owner asks for screenshots. Then
   list "Owner eyeball: ..." items.
8. **Commit only your own hunks** (section 8). Subject `feat: 0.9.2 — ... (R137)` /
   `fix: ... (R138)` / `feat(analytics): ... (R136)` / `docs: ...`. The body gives the owner
   quote, before → after numbers, and `check.sh ALL PASSED (110 suites); code checks only (R132).`
   End with the Co-Authored-By trailer.
9. **Report**: what shipped, the check result, owner actions (publish, Dashboard ids), and what to
   eyeball. Never claim a check passed without its output.

---

## 8. Commit discipline in a shared tree

Since 2026-11-01 the owner runs several sessions in one working tree at once: a Claude lead with
builders, a Codex session, and others. They leave uncommitted edits, and even staged deletions,
in shared files such as `docs/owner-requests.md`, the living doc, `ChangeNotesConfig`,
`tests/economy-sim.luau` and `docs/economy.md`. A plain `git commit` or `git add <shared file>`
would ship another session's half-finished work under your message.

Procedure:

1. Run `git status --short` before editing. Note which files other sessions are touching.
2. Commit through a **temporary index**:
   ```bash
   export GIT_INDEX_FILE="$SCRATCH/mine.index"
   git read-tree HEAD
   git add <files that are wholly yours>
   git diff -U3 -- <shared file> > "$SCRATCH/all.patch"   # then keep ONLY your hunks
   git apply --cached "$SCRATCH/mine.patch"
   tree=$(git write-tree); parent=$(git rev-parse HEAD)
   new=$(git commit-tree "$tree" -p "$parent" -F "$SCRATCH/msg.txt")
   git update-ref HEAD "$new" "$parent"     # old-value guard: fails if someone committed meanwhile
   unset GIT_INDEX_FILE; git reset -q -- <your paths>
   ```
   For a shared file you can also `git hash-object -w` a "HEAD plus only your edits" version.
3. **Never use `--unidiff-zero` (-U0) patches.** On 2026-11-01 pure insertions landed in the wrong
   function and needed a fix-up commit. Always apply hunks with context.
4. Afterwards, confirm `git diff HEAD -- <shared file>` shows only the other session's hunks.
5. For risky commits, check the exact tree in a scratch `git worktree`, including paths the
   normal run skips (`typecheck.sh` does not cover `tests/`; run `economy-sim --tune` as a dry run).
6. Recheck the newest R number right before writing one. If you collide, renumber and say so
   (the changelog shows "commit 5578a36 says R128; renumbered").
7. Peer sessions are reachable with SendMessage. Agree on file ownership and R numbers rather
   than guessing.

---

## 9. Lead and builder subagents

### Roles

| | Lead (main session) | Builder (subagent) |
|--|---------------------|--------------------|
| Owns | Boot lists (`src/server/init.server.luau` `FEATURE_SERVICES`, `src/client/init.client.luau` ordered names), `.gitignore`, the living doc, `docs/owner-requests.md`, the plan's live assignments, **all commits** | Only the paths its brief lists. If it needs an API it does not own, it adds it to its own module and notes it in the report. Schema, remote and product changes go to the core maintainer (`B17-core` in wave 1). |
| Tools | Serena, Studio MCP (one consolidated pass), the Studio lock, restarting the MCP primary | `grep -n` / `sed -n` excerpts (subagents get no `mcp__serena__*` tools). No Studio when more than about two builders run (R92). |
| Verifies | One Studio pass for the wave, if the owner wants Studio at all | Code, Lune tests and a green `check.sh`, plus a re-runnable QA script (`tools/qa/<thing>.py`) the lead can run later. |
| Formats | May run `./scripts/check.sh --fix` | Formats only its own files. Never runs `stylua src` on the tree. |
| Reports | To the owner: what shipped, owner actions, images opened (R12) | ONE final report of ≤ 250 words: files, tests, check result, anything not done. |

Builder names encode the wave and scope (`B1-core`, `W5-ui`, `W-R137-econ`, `Q3-knockdown`).
The lead keeps the "Live assignments" table so a restarted session knows who owned what.

### Builder brief template

```
You are <name>. Task: <R number + one-line goal>. Spec: <path §>. Plan contracts: <path §>.
You own ONLY: <paths>. Do not edit other files; if you need an API there, add it in your module
and say so in your report.
Rules: --!strict, comment every function, tunables in src/shared/Config, server-authoritative
intents, full UI (gamepad + touch + KB/M), analytics + admin hooks, Lune tests that load the real
modules. No Studio (the lead runs one pass). No commits. No stylua on the whole tree.
Done = ./scripts/check.sh ALL PASSED + docs/<system>.md updated.
Reply with ONE report of ≤ 250 words: files, tests, check output line, gaps.
```

### Context budget

- Read excerpts (`grep -n`, `sed -n a,bp`, Serena `find_symbol`) and never whole large files. The
  living doc is about 740 lines and the request log about 1,800.
- Delegate wide searches to an Explore subagent and keep only the conclusion.
- Write state into the docs or memory files before suggesting `/compact`. After a restart, run a
  coverage audit (R36) so no earlier builder's unfinished work is lost.

---

## 10. Studio etiquette

- **Lock**: `python3 scripts/studio-lock.py acquire <name>` / `release <name>` / `status`. Gate
  every start or stop in the same command on ownership, e.g.
  `studio-lock.py status | grep -q '"owner": "<name>"' && studio_mcp.py call solo_playtest '{"action":"stop"}'`.
  Turns end after 10 minutes while others wait (`refresh` does not extend a turn), so fit a batch
  into one turn. Edit-mode screenshots and art spawns need the lock too.
- **Never stop a playtest you did not start.** If a playtest is running that no agent owns, it is
  probably the owner testing. Release the lock, tell the lead, and wait.
- Only the lead may stop an orphaned playtest, and only when the owner's lock is stale (more than
  20 minutes) and that agent is confirmed dead.
- If the MCP primary on :58741 dies, only the lead restarts it. Never run two primaries.
- Read-only edit-mode `execute_luau` probes (for example "did Rojo sync?") need no lock.

---

## 11. Serena

The repo's `.mcp.json` registers Serena (pinned commit, `--context ide-assistant`, luau-lsp
backend). It was verified on this Luau code base on 2026-10-30 (R37) and saves a lot of context.
The owner's global instruction is "MANDATORY: must use Serena for any file operations if at all
possible".

| Need | Serena tool |
|------|-------------|
| Map a file without reading it | `get_symbols_overview` |
| Read one function | `find_symbol` with `include_body=true` |
| Find callers | `find_referencing_symbols` |
| Edit at symbol level | `replace_symbol_body`, `insert_after_symbol`, `insert_before_symbol` |

- If the session has deferred tools, load them first:
  `ToolSearch select:mcp__serena__get_symbols_overview,mcp__serena__find_symbol,...`.
- Serena is exposed to the **lead session only**. Spawned subagents get no `mcp__serena__*` tools,
  so builders use excerpts.
- If no Serena tools exist in a session, say so in the report and use excerpts. Never claim
  Serena was used when it was not.
- Use plain file tools for non-code files (Markdown, JSON, Python).
- `.serena/project.yml` is committed. `.serena/cache/` and `.serena/memories/` are gitignored.

---

## 12. Answering analytics reports

The owner pastes the admin panel's text report (e.g. "analytics report TODAY, 00:00–17:33 UTC —
489 new players, 569 sessions, avg 5:13, D1 2.2 % ...") with a short question such as "any news
on analytics?" or "why are people leaving so early". Answer it as follows (R129, R135, R136):

1. **Log it** as an R entry. Put the headline numbers in the quote's context line.
2. **Split by build.** Use the `build:<release>:p<placeVersion>:*` slices. Early in a day, old
   builds dominate, so say how many new players each build saw and mark the answer provisional
   while the window is still open.
3. **Answer every question from the numbers**: where first sessions end (loading, first pad,
   first manager, area 2), funnel steps, and per-device boot time. Compare against the Roblox
   discovery signals (first-play bounce < 60 s and 61–180 s, playtime capped at 60 min per day,
   play days, co-play, spend days).
4. **Check suspicious numbers against the code** before believing them. Real measurement bugs
   found this way:
   - R129: the leave snapshot read JOIN-time state ("395 of 407 sessions end in area 1").
   - R135: the scorecard bounce numerators covered new builds but the denominator counted every
     joined player. Also, `tutorialSeen` was sent during the plot reveal, refused by the server,
     and never re-sent.
   - R137: `Revenue.offerClicked` had no caller, so every "click 0 %" was missing data.
   - R136: notification failures had no reason bucket.
5. **Fix measurement bugs right away.** Add a regression test that fails on the old code. Bump no
   version, and title the changelog entry "(measurement only)".
6. **Propose design changes, do not ship them.** Write them as
   `Proposed next (not shipped; owner "do it"): ...` with concrete numbers (pad order, price
   steps, sim minutes).
7. **Ship on the owner's go** ("do it", "fix these two I guess?", "do whatever you want and fix").
   Measure with `tests/economy-sim.luau` (and `--tune`), bump the version, add WHAT'S NEW lines,
   and add a "Measure on `build:<x.y.z>:*`" line to the changelog.
8. **Say what is not live yet.** A fix only shows in the report after the owner publishes and new
   servers start (R136: "R135's fixes are not live … the owner must publish").
9. **Separate bugs from design.** Something that only looks wrong (R136: offline payouts were
   84 % of cash from one late-game player at the designed 50 % × 3 h) is reported as "no bug"
   with the reason.

Live data can also be read directly. That is a read-only DataStore read through Studio
`execute_luau` in the connected place, which another reference covers. Never print an API key
while doing it.
