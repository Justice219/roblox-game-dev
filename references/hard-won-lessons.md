# Hard-won lessons

Things that went wrong on SellNukes and the rule each one produced. Most came from long sessions
with several agents sharing one Studio and one working tree, so they are not obvious from the code.
Read this before running Studio, working in parallel, or committing in a shared tree.

## Contents

1. [Studio](#1-studio)
2. [Parallel builders](#2-parallel-builders)
3. [Committing in a shared tree](#3-committing-in-a-shared-tree)
4. [UI and verification](#4-ui-and-verification)
5. [Analytics](#5-analytics)
6. [The Roblox discovery algorithm](#6-the-roblox-discovery-algorithm)
7. [Publishing this skill](#7-publishing-this-skill)

## 1. Studio

**Hold the lock for every start and stop, and gate on it in the same command.** Agents share one
open place. In one session a QA agent's playtest was stopped three times by others while it held the
lock. Another agent lost its 10-minute turn mid-check, chained `status | head -1 && refresh; stop`
with `;`, and the stop ran without the lock. `refresh` does not extend a turn.

```bash
python3 scripts/studio-lock.py status | grep -q '"owner": "lead"' \
  && python3 scripts/studio_mcp.py call solo_playtest '{"action":"stop","timeout":90}'
```

- Edit-mode art spawns and screenshots need the lock too. A background acquire that finished long
  ago proves nothing: one agent noticed its grant 36 minutes late and ran a batch on someone else's
  turn. Start every batch by gating on `status`.
- Read-only edit-mode `execute_luau` checks ("did Rojo sync?") are fine without the lock.

**A running playtest no agent owns is probably the owner testing.** Do not stop it, do not start
anything, and do not arm a watcher that auto-starts a capture when it ends; the owner may only be
pausing to tweak something. Release the lock and wait.

**Solo playtests only (R72).** An 8-client test whose start reported "not detected" was never ended.
It ran for about 7 hours, used up the Mac's memory, and hung Studio and the MCP for the whole team.
`scripts/studio_mcp.py` now refuses `multiplayer_playtest` starts. If a plan needs several players,
use solo playtests plus pure-logic tests.

**Default to code checks; capture when the owner asks (R132).** The owner often playtests in Studio
while agents work, so an agent's playtest collides with theirs, and captures cost a lot of time. Run
`check.sh` and list what to eyeball. When the owner says "show me", take the screenshot. It is
worth it: see the chip story in section 4.

**Travel for real in presentation shots.** Moving the HumanoidRootPart next to a Moon stand leaves
`CurrentWorld = "main"`, so the shot shows Nuke Town's HUD, the Attack button and a blue sky. A direct
move is fine for checking server rules. For anything judged by eye, travel with `WorldService`, or say
in the report that the presentation is not the target world's.

**Forcing a server-wide event from Studio is safe, but check why.** `HappyHourService.force` answers
"forced on every server", which sounds alarming during a live game. Its store and topic get a
`_Studio` suffix (`HappyHourOverrideStore`), so live servers are untouched. When a tool's message
suggests it reached live players, read the code before you continue. Still call `.stop()` afterwards.

**Rojo can silently stop syncing.** Earlier commits may have arrived while the latest did not.
Compare a string from the changed file in Studio's `.Source` against disk before trusting a capture.
Touching files does not help when the plugin is disconnected; only the owner can click Connect. The
sync can also resume by itself, so check again before asking twice.

**Other gotchas.**
- Requiring a server ModuleScript from `execute_luau` in edit context gives a fresh copy with empty
  state. Probe live state with `eval_server_runtime` during a playtest, or a service's QA hooks.
- `get_runtime_logs` shows WARN and ERROR only.
- A state read taken right after switching device presets can be stale. The console read `spot=none`
  for a few seconds and then settled on `topLeft`. Poll before calling it a bug.
- macOS screenshot names use a narrow no-break space before "PM", so typed paths fail. Use a glob.

## 2. Parallel builders

**Builders do not touch Studio when more than about two run at once.** On 2026-10-31 eight builders
shared one Studio. Lock queues, stale Rojo sync, a crashed MCP bridge and repeated capture reruns
made the owner wait for hours: "it just feels like they are going in circles", "just finish em".

- A builder delivers code, Lune tests, a passing `check.sh` and a re-runnable capture script.
- The lead runs one consolidated Studio pass at the end, then commits.
- Put "no Studio, the lead does the pass" in every brief, and never park half-done work behind flags
  when the owner says finish.

**Helper agents can stop mid-task without reporting** (for example at a usage limit). Their files may
be complete, but nobody has checked them. Verify coverage yourself, and tell the owner what you did
and did not check.

## 3. Committing in a shared tree

Several sessions may edit the same tree, leaving uncommitted edits and even staged deletions in
shared files such as `docs/owner-requests.md`, `SELLNUKES_CLAUDE_DOCUMENTATION.md`,
`ChangeNotesConfig`, `tests/economy-sim.luau` and `docs/economy.md`. A plain `git commit` would ship
another session's half-finished work under your message. R-numbers collide too: two sessions each
wrote R128–R130 on one day.

1. Run `git status --short` before editing. Grep the newest `### R` heading again right before
   numbering a request.
2. When only your files are dirty, `git add <exact paths>` is enough. Read the diff of shared files
   first.
3. When others have hunks in a file you share, commit with a temporary index:

```bash
export GIT_INDEX_FILE=/tmp/x.index
git read-tree HEAD
git add <wholly-yours files>
git apply --cached yours.patch        # only your hunks, WITH context (git diff -U3, filtered)
tree=$(git write-tree)
unset GIT_INDEX_FILE
new=$(git commit-tree "$tree" -p "$parent" -F message.txt)
git update-ref HEAD "$new" "$parent"  # the old-value guard catches another session's commit
git reset -q -- <your paths>
```

4. Never use `--unidiff-zero` patches. On 2026-11-01 pure insertions landed in the wrong function, and
   a later commit had to repair it.
5. Afterwards, confirm `git diff HEAD -- <shared file>` shows only the other session's hunks.
6. Check the exact tree before committing, including what the normal run skips: `typecheck.sh`,
   stylua and selene do not cover `tests/`.

## 4. UI and verification

**Passing tests can still be wrong if their fixture is not real.** R138: the first fix for the Happy
Hour chip passed every test, then a Studio capture showed it sitting above the character's head. The
test layout's canvas was 2170 design px wide; a real iPhone 14 is 1208. On the real zones the 177 px
chip fit neither gap beside the cash and fell back to the worst spot.

- Build layout tests from zones **measured on a device preset**
  (`HudZones.rect`, `ScreenManager.canvasSize`, `ScreenManager.safeTop`).
- Have a placement function report which candidate won (`HappyHourChipSpot`) so a capture can be
  checked by number as well as by eye.
- When you tell the owner where something sits, say it from a capture, not from the code you meant to
  write. The first report on this fix described a placement that was not what the game did.

**Screen coordinates are not design coordinates.** On an iPhone 14 preset a capture is 1210 px wide,
the viewport 749 pt and the canvas 1208 design px, with a safe-area offset on the left. Convert before
reasoning about overlaps.

## 5. Analytics

**A mixed-build day lies.** Newer counters exist only on newer servers. The scorecard once showed 5.9 %
bounce because it divided by every player; on the servers that recorded it the figure was 21 %. Divide
by the population that could have recorded the number, and compare builds.

**A low number may be a telemetry bug.** "Saw the tutorial hint" read 148 players while the same hint's
arrow counted 429 sessions, and 85 % of new players had already bought the pad it points at. The client
sent the claim during the plot reveal, the server refused it, and the once-per-session send was spent.
Compare a suspicious step with a neighbouring counter, but check the units: that first comparison set
players against sessions, which overstated the gap. The proof was in the code, not the ratio.

**Zero may mean nobody calls it.** Every "click 0 %" came from a recorder with no caller. Grep for the
caller before believing a zero.

**Reading live data.** The Open Cloud key on disk is scoped to Messaging and asset upload, so DataStore
calls return `403 INSUFFICIENT_SCOPE`. Use `python3 scripts/studio_mcp.py luau-file <snippet>` in the
connected place (edit context, no playtest, no lock) with
`DataStoreService:GetDataStore("SellNukesAnalytics_v1")`:

- Keys: `meta` (`{firstDay = <day number>}`), `d:<yyyy-mm-dd>:<family>:0` (value
  `{c = counters, v = version}`), `c:<yyyy-mm-dd>` (a compacted day, may be absent).
- Families: core, revenue, economy, tycoon, worlds, retention, pets, crates, attack, event, social,
  kinetic, orders (retired R128, old days only), health.
- Return `HttpService:JSONEncode(...)` and parse `returnValue` in Python. A full dump is about 110 KB
  and takes under a minute. Read-only; never print a key.

## 6. The Roblox discovery algorithm

Sources: create.roblox.com/docs/discovery and the DevForum post "Recommended For You Algorithm
Improvements That Better Value Long-Term Retention" (2026-06-15). qPTR was removed. Signals are
per-user averages over users who joined organically from Recommended for You, with windows of Day 1,
Days 2–7 and Days 8–28.

| Weight | Signal |
|---|---|
| Most important | Play-through rate (tile → play; thumbnails and title, owner-side) |
| Most important | First-play bounce (negative): under 60 s, and 61–180 s |
| Most important | Play days per user |
| Most important | Playtime per user, capped at 60 min per user per day |
| Important | Intentional co-play days (join, invite, private server) |
| Important | Qualified play sessions |
| Important | Spend days per user, Robux spent per user |

A custom thumbnail is required for Home impressions.

Experience notifications reach opted-in users aged 13+ only, at one per user per experience per day,
and should be personal and actionable: Open Cloud `POST /cloud/v2/users/{id}/notifications`. Developers
on the DevForum report that a 400 means notifications are off or the player is ineligible, and a 429
means the cap or a rate limit. The official docs do not list these codes, which is why the game counts
`rnotify:status:<kind>:<bucket>` to measure it.

## 7. Publishing this skill

Skill descriptions have a hard limit of 1024 characters and may not contain angle brackets. The first
version was 1180 and failed validation, which nothing showed until the validator ran. Run the
skill-creator's `quick_validate` after every edit to the frontmatter.
