# WHAT'S NEW change notes

Added 2026-10-30 (owner R58: "add the changelog system that we have in the Robeast project. That
way it can all be like hooked up together. The what's new but only show like the what's new
whenever like returning players join. You can put it in like the bottom right ... Don't clog up
the left UI too much more than it already is.").

SellNukes runs the **same change-notes system as RoBeasts** (`~/IdeaProjects/RoBeasts`,
`docs/change-notes.md`): the same note schema, the same `VersionConfig`, the same rules module, the
same save record (`profile.notes = { seen, at }`), the same remote verbs and analytics keys, and
the same authoring workflow below. A note written for one game drops into the other; only the
game-specific vocabulary differs (see "Shared schema").

## How it works

| Piece | File | Job |
|-------|------|-----|
| Notes + rules data | `src/shared/Config/ChangeNotesConfig.luau` | the ordered, append-only `Notes` list, text caps, tags, icons, CTA screens + Shop tabs, pacing, `validate()` |
| Version | `src/shared/Config/VersionConfig.luau` | `Current` (semver), `parse` / `compare` / `sameMinor`, `label()`, `menuText(game.PlaceVersion)` |
| Pure rules | `src/shared/Util/ChangeNotesLogic.luau` | seen position, forward-only marking, the admin reset, no-context players, `shouldAutoShow`, action parsing, metric keys |
| Save data | `src/server/Economy/ProfileLogic.luau` | `profile.notes = { seen, at }` (additive; schema stays v1); snapshot field `notes = { seen }` |
| Server | `src/server/Services/ChangeNotesService.luau` | load hook (no-context rule), `ChangeNotesAction` remote, analytics, purchase-flow hint, reveal timer |
| Admin | `src/server/Admin/ChangeNotesAdmin.luau` | `WhatsNewReset`, `WhatsNewPreview` (Players tab) |
| Client state | `src/client/ChangeNotes/ChangeNotesClient.luau` | boot controller: seen position, NEW dot, the once-per-join auto pop-up, reports, admin preview / replay |
| UI | `src/client/UI/Screens/WhatsNew/init.luau` | the WHAT'S NEW panel (stud window, every visible note newest first) |
| HUD entry | `src/client/UI/Hud/HudWhatsNew.luau` (+ `Hud.luau`, `Widgets/HudPlacement.luau` `corner`) | the bottom-right WHAT'S NEW chip with a red NEW badge |
| Other entry | `Screens/Settings` → WHAT'S NEW | opens the panel; the quiet version label `v0.3.0 · build N` |

**Who sees what, and when**
- **Brand-new players** (a fresh profile) and **players who have not finished the tutorial** have no
  context for "what changed". When their profile loads, the server marks the newest note as seen
  (before the first snapshot is pushed), so they never get the pop-up and the NEW badge stays off.
  (RoBeasts' equivalent is "no finished match".)
- **Returning players** with an unseen note get the panel **once per join** at the first polite
  moment: the join loading screen finished, no window open (Welcome Back, the tutorial intro card,
  any menu), no focus mode (loading, egg hatch, attack cinematic), no plot-reveal fly-over, no
  Roblox purchase prompt. It waits `Auto.FirstCheckDelay` (2.5 s) then needs `Auto.PoliteChecks` (2)
  calm checks in a row; if no calm moment comes within `Auto.WaitSeconds` (180 s, loading time
  excluded) it gives up for that session and the NEW badge stays on.
- **Closing** the panel (red X, B, Back, Esc, or a CTA) marks the newest visible note seen on the
  server (forward only). The NEW ribbons on the cards are frozen at open, so they don't vanish
  while the panel is up.
- The **WHAT'S NEW chip** (bottom right, under the offer column; above the jump button on
  phones / tablets; inside the TV-safe area on console) and Settings → WHAT'S NEW always open the
  panel.

**Security:** `ChangeNotesAction(verb, noteId, arg?)` accepts only listed verbs, KNOWN visible note
ids (≤ 48 chars) and listed sources; "closed" seconds are clamped to 0..600 and only feed
analytics. It is rate-limited per player (`Server.ActionBurst` 8 / `ActionPerSecond` 1), analytics
reports are capped per key per session (`Server.MaxReportsPerKey` 4), and "seen" only moves
forward. Nothing is ever granted. `ChangeNotesAdmin` (S→C) is sent only by the server after an
authorised admin command.

**Analytics** (family `retention`, report table "What's New (change notes)"):
`notes:shown:<id>:<auto|menu>`, `notes:cta:<id>`, `notes:closed:<id>`, `notes:seen:<id>`,
`notes:openSec:<id>` (summed seconds open; ÷ closed = average) and
`notes:openLen:<lt5|5to15|15to60|gt60>`. `<id>` is registered exactly (`noteId` kind).

**Admin** (Players tab → More; pick yourself for "reset my seen version"):
- `WhatsNewReset { seenUpTo }` — "Nothing seen" or "Seen up to vX …": sets the seen note BACK, saves,
  pushes, and that player's client replays the returning-player pop-up at the next calm moment.
- `WhatsNewPreview` — opens the panel on that player's screen in preview mode: every note, also
  ones still hidden by `ShowFrom` (labelled SOON with their reveal date); nothing is marked or counted.

## Shared schema (RoBeasts ↔ SellNukes)

Identical: `Note { Id, Version, Date, Title, Tagline, Hero, Sections { Heading, Items { Text, Icon?, Tag? } }, Cta?, ShowFrom? }`,
`Limits` (title 40, tagline 90, heading 20, item 72, CTA label 18, ≤ 3 sections, ≤ 6 items),
tags (NEW / IMPROVED / FIXED / LIMITED), `State { seen, at }`, actions / sources, `validateNotes`,
`ShowFrom` / `VisibleVersion`, `VersionConfig` (byte-identical apart from `Current`).

Game-specific vocabulary:

| | RoBeasts | SellNukes |
|--|--|--|
| Icons | egg, paw, star, tag, clock, flag, spark, check, gift | nuke, cash, gem, star, gift, clock, pet, egg, rocket, turkey, trophy, check |
| CTA screens | Hatchery, Pets, Shop, Offers, Quests, ... | Shop, Pets, LuckyWheel, DailyRewards, TimeRewards, Codes, Rebirth, Teleport, CrateShop, HarvestFeast, Attack, GroupRewards, Settings |
| `Cta.Tab` | Shop tab id | Shop section id (`limited`, `passes`, `cash`, `gems`, `spins`, `boosts`) |
| Hero kinds | Pet, Icon | Pet, Icon, **Image** (`rbxassetid://N`, owner R58 "optional image") |
| No-context rule | no finished match | tutorial not finished |
| Id length | ≤ 48 | ≤ 48 **and ≤ 32** (an analytics key part; `validate()` checks) |
| `closed` arg | — | seconds open (analytics) |

A note that uses Hero Kind "Image" is the only shape RoBeasts does not accept yet.

## Shipping a new note

1. **Append** a table to `NOTES` in `ChangeNotesConfig.luau`. Never edit, reorder or remove an
   older note's `Id`: ids are save data (`profile.notes.seen`). Give it `Version` = the new
   `VersionConfig.Current` (a new note always comes with a MINOR bump; see Versioning below).
2. **Id** = `"YYYY-MM-DD-short-slug"` (lowercase letters, digits, dashes, ≤ 32 chars in SellNukes).
   The date part must equal the note's `Date` UTC day; `Date` must be later than the previous
   note's. Use `unixDate(year, month, day)`.
3. **Keep it short**: `Title` ≤ 40, `Tagline` ≤ 90, ≤ 3 sections, ≤ 6 items per section, each item
   ONE line (≤ 72 characters). Section headings that are tag names (`NEW`, `IMPROVED`, `FIXED`,
   `LIMITED`) draw as coloured pills; an item gets its own pill only when its `Tag` differs from
   its heading.
4. **Keep it true and player-facing**: check every number against config. No internal names,
   analytics, admin tools or "we fixed a bug that..." wording. Kid-friendly. Add truth checks for
   new numbers to `tests/change-notes.luau` (section 3).
5. **Hero**: `{ Kind = "Icon", Icon = "<icon>", Color = Color3? }`, `{ Kind = "Pet", PetId = "<PetConfig id>" }`
   (live 3D pet) or `{ Kind = "Image", Image = "rbxassetid://N" }`.
6. **CTA** (optional): `{ Label = "GET GEMS", Screen = "Shop", Tab = "gems" }`.
7. Run `./scripts/check.sh` (the Lune test runs `validate()` and the truth checks).

Returning players see the new note once on their next join; nothing else needs to change.

## Publishing early: `ShowFrom`

Give the note `ShowFrom = unixDate(2026, 11, 26)` and publish the day before; until ShowFrom the
note does not exist for players (not unseen, never auto-opened, not listed, refused by the server
for every verb, the version label keeps the newest visible note's version). Client and server each
arm ONE `task.delay` to the next ShowFrom: the server re-applies the no-context rule to every online
player at the reveal (so a new player never gets the revealed note's pop-up); the client reveals
`Auto.RevealLagSeconds` (2 s) later and gives the revealed note its own one polite pop-up.
Rules (`validateNotes`): whole unix seconds, not before the note's `Date`, never earlier than the
previous note's ShowFrom, and every later note needs one too (visibility is always a prefix).

### Patches while a note is hidden

The visible note's `Version` is `X.Y.0`, so while a note is hidden the label would drop from, say,
`v0.4.2` to `v0.4.0`. In the build that publishes early, set `ChangeNotesConfig.VisibleVersion` to
the last version players saw (`"0.4.2"`). A PATCH inside the hidden window that fixes something
players see now bumps `Current`'s PATCH **and** `VisibleVersion`'s and appends to the newest
**visible** note; a fix to the hidden content bumps `Current`'s PATCH only and appends to the
hidden note. `validateVisibleVersion` checks it.

## Versioning

| Change | Bump | WHAT'S NEW |
|--------|------|------------|
| A player-facing **feature** update | MINOR: `0.3.0` → `0.4.0` (PATCH back to 0) | **append a new note** with `Version = "0.4.0"` |
| **Fixes / tuning** a player can notice | PATCH: `0.3.0` → `0.3.1` | **append items** to the newest note (usually under `FIXED` / `IMPROVED`); its `Version` stays |
| A relaunch-sized change (owner decides; `1.0.0` = public launch) | MAJOR | a new note with that Version |
| Internal only (tests, docs, admin tools, refactors) | nothing | nothing |

History: `0.1.0` SellNukes is born, `0.2.0` the full tycoon + side systems, `0.3.0` WHAT'S NEW
(panel + bottom-right chip), cash / gems flying into the counters, live Robux prices (2026-10-31).

**Where players see it:** the purple `v0.3.0` pill on every note; Settings' quiet
`v0.3.0 · build 431` label (`ChangeNotesConfig.menuText(game.PlaceVersion, now)`; just `v0.3.0` in
unpublished Studio).

**What `validate()` enforces** (`tests/change-notes.luau` on every `./scripts/check.sh`, and
`Server/Tests/CoreTests` in Studio): every note's `Version` is valid semver; versions never go down;
`Current` is not older than the newest note's `Version` and has the same `MAJOR.MINOR`.

**Step by step, every player-facing change:**
1. Decide the bump from the table above.
2. Edit `VersionConfig.Current`.
3. MINOR / MAJOR: append a note with `Version = Current`. PATCH: append one-line items to the
   newest note's sections (still ≤ 3 sections, ≤ 6 items each, ≤ 72 characters).
4. Add truth checks for any new numbers to `tests/change-notes.luau`.
5. Run `./scripts/check.sh`.
6. Optional in Studio (lock held): admin `WhatsNewReset` on yourself → the pop-up replays;
   `WhatsNewPreview` shows every note; `capture_device_matrix` for the chip.

## Tests

- `tests/change-notes.luau` (Lune, 240+ checks): version rules, `validate()` + every `validateNotes`
  rule on candidate lists, mirrors (Shop tabs, CTA screens), truth checks, `ChangeNotesLogic`
  (incl. the `shouldAutoShow` matrix: new vs returning, seen older / equal / newer, malformed data;
  action parsing fuzz; metric keys through the real analytics `KeySpec`), ShowFrom, the profile
  record, the HUD corner placement on desktop / console / phone / tablet canvases.
- `tests/profile-logic.luau`: the default profile includes `notes = { seen = "", at = 0 }`.
- `tests/analytics-recorders.luau`: `noteId` is a registrable kind.

## Studio verification (2026-10-31, U1, solo playtest in "Sell Nukes [🎃]", lock held)

`STUDIO_LOCK_OWNER=U1-changelog python3 tools/qa/whats_new.py` (probe
`tools/qa/whats_new_client.luau`; captures in `docs/verification/ui/whats-new/`):
- Join with the saved (up-to-date, tutorial finished) profile: no pop-up; chip bottom-right, badge
  off; D-pad Down from the last offer lands on the chip (`hud-chip-{desktop,phone,tablet,console}.jpg`:
  above the jump button on phone / tablet, inside the TV-safe area clear of the hint bar on console).
- Admin `WhatsNewReset` (seen up to v0.2.0, through `AdminService.dispatchAsync`): badge on, the
  panel auto-opened at the next calm moment with a NEW! ribbon on the 0.3.0 card
  (`returning-auto-open.jpg`, `panel-*.jpg`); closing moved the server's seen note to
  `2026-10-31-whats-new`, badge off, analytics `notes:shown:…:auto`, `notes:closed:…`,
  `notes:seen:…` counted.
- Admin `WhatsNewPreview`: the panel opened, nothing marked or counted (`admin-preview.jpg`).
- New player (admin New Player Mode: migration "new", tutorial step 1): the server marked the
  newest note seen at load, no pop-up in 15 s, no badge, the tutorial card stays on top
  (`new-player-npm.jpg`). (Run as a separate step on 2026-10-31; folded into `whats_new.py` as step 7.)
