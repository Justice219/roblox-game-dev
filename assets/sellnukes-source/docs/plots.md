# Plot names: name your plot from its front sign (owner R88)

> Owner R88 asked: "allow players to name there plots bly clicking on it and on controller being near the sign
> in the front"

Every player can name their plot from the start, with no unlock. The name replaces the default
**"\<DisplayName\>'s Nukes"** on the entrance-arch sign of the player's plot in **every** world. For example,
"Sam's Dino Valley" also becomes the custom name. It is saved outside `profile.tycoon`, so it survives
Rebirth.

## How a player names it

| Input | How |
|---|---|
| Mouse | Hover the sign: a hand cursor appears and the sign gets a yellow outline. Click it to open the window. |
| Touch | Tap the sign. You can also walk under the arch and tap the "Name your plot" prompt button. |
| Controller | Walk under your arch: the prompt "Name your plot" appears. Hold **X** briefly (0.3 s). |
| Keyboard | Walk under your arch and hold **E** briefly. |

After a custom name is set, the prompt says "Rename your plot". Only the owner sees the click box and
the prompt, because both are client-created and only exist on the owner's own sign.

The naming window is the `RenameStand` screen in **plot mode**: `ScreenManager.open("RenameStand", { mode = "plot" })`.
- It has the title "Name Your Plot", the heading "Name your plot!" and the hint "Up to 24 letters. Everyone sees it on your front sign."
- The text box shows the saved name. When the name is the default, the box is empty and its
  placeholder shows the default, e.g. "Sam's Nukes".
- There are three buttons: red **CANCEL**, blue **RESET** (back to the default) and green **CONFIRM**.
  Enter or the on-screen keyboard's Done also confirms.
- Gamepad: the text box is the default selection (A opens the console keyboard), the buttons are
  selectable, and B / Back / X close the window. Phones: tapping the box opens the keyboard.
- Client-side hints: an empty or too-long name shows "Type 1 to 24 letters first."; the same name
  shows "That's already your plot's name!"; RESET on a default sign shows "Your sign already shows
  its starting name." The server checks everything again.

## Server flow (`src/server/Tycoon/PlotNames.luau`)

The `RenamePlot(text)` remote is a C→S intent. `""` (or all spaces) means **reset to default**. The
server runs these checks in order:
1. `PlotNameLogic.parse`: the argument must be a string of ≤ 24×4 bytes, with valid UTF-8, no
   ASCII / C1 control characters and 1..24 characters (`Validate.text`). It is then normalized:
   zero-width, bidi-override and soft-hyphen characters are dropped, Unicode spaces become " ",
   runs of spaces collapse and the ends are trimmed. A name made only of invisible characters is
   **refused**, never turned into a reset. Junk is dropped silently, so a hostile client cannot
   make the server send toasts.
2. One request in flight per player.
3. Rate limit `PlotNameConfig.Rename`: a burst of 3, then 1 every 10 s. Sets and resets share it.
   A refused request gets at most one "Whoa, not so fast!" toast per 4 s.
4. The player must own a plot (`PlotService.getPlotIndex`).
5. A reset when the sign already shows the default gets an info toast. A name that is the same as
   the saved one also gets an info toast, and the filter is never called.
6. `TextService:FilterStringAsync(PublicChat)` → `GetNonChatStringForBroadcastAsync` (PlotService's
   `filterForBroadcast`). This runs **before** anything is saved or shown, and the unfiltered text
   is never stored.
7. After the yield, the server re-checks that the player is still in the game, the plot index is
   unchanged and the profile is the same table.
8. If the filter fails, the player sees "Couldn't check that name right now - try again!". If the
   filter **changed** the text (part of it was censored), the name is refused with "That name isn't
   allowed - try a different one!". The server never puts "####" on a kid's sign.
9. On commit:
   - `profile.plotName` is set.
   - `markChanged(player, true, { "plotName" })` saves soon and pushes only the `plotName` field.
   - Every world's sign is updated.
   - Analytics records `renamePlot:set|reset`.
   - A success toast is shown.

**Display (`PlotNames.apply`)**
- **When:** `PlotService.claim` calls it after the plot is assigned in every world. That covers join,
  the queue and the New Player Mode profile swap.
- **Re-filter:** the saved name is re-parsed and **re-filtered once per session**, following the
  same rule as `applyStandName` (security audit 2026-10-30). The cache is keyed by the saved text.
  The default sign shows while the check runs.
- **Fail closed:** if the filter fails, or now changes the name, the sign keeps the default.
- **Stale answers:** a per-player token discards a slow filter answer after a newer rename, reset or
  plot change.
- **Rebuilds:** they never touch the sign (`PlotBuilder.restore` leaves it), so nothing else needs to
  re-apply.

**Signs (`PlotBuilder.setPlotName(index, text)`, on every world builder)**
- **Who:** only an *owned* plot changes. `setOwner` resets the sign to the default and the
  `PlotName` attribute to `""` on every owner change, and `release` shows "FREE PLOT" as before.
- **Composition:** `PlotNameLogic.signText(displayName, suffix, custom)`. The suffix is
  `PlotNameConfig.MainSuffix` ("Nukes") in Nuke Town and the world name elsewhere.
- **Labels created later:** the arch mesh streams in after the plot exists, so labels created then
  pick up the remembered `state.signText`.
- **`PlotName` attribute:** the plot model carries the filtered name, `""` for the default.
- **Tag:** the owner-sign part (HubLayout arch `OwnerSign` piece, or the primitive `Sign`) carries
  the CollectionService tag `SNPlotSign`.
- **Extra worlds:** these calls are guarded (`pcall` + `hasPlots`), so a broken world never breaks
  the Nuke Town sign.

## Client (`src/client/Tycoon/PlotSign.luau`)

Started by `StandSign.start()`. For every `SNPlotSign` part on the **local player's** plot
(`TycoonWorld.isMine`, in any world), one rig is parented to the sign:
- **ClickBox:** an invisible, CanQuery Part that is 0.6 studs larger than the sign on each side. The
  arch meshes are CanQuery = false, so the box is what clicks hit.
- **ClickDetector:** reach 70 studs. The sign hangs about 18 studs up, so clicks from the road work.
- **Highlight:** the hover outline, shown only while the mouse hovers the sign.
- **Prompt anchor:** an Attachment 3.5 studs above the plot's ground (`WorldLayout.plotOrigin`),
  directly under the sign.
- **ProximityPrompt:** reach 12 studs, hold 0.3 s, E / ButtonX, no line-of-sight check.

Everything is event-driven:
- Tag added or removed (streaming).
- `TycoonWorld.MyWorldPlotChanged`.
- `ClientState.ProfileChanged("plotName")`, which changes the prompt wording.
- `ScreenManager.Opened` / `Closed`. Rigs pause while any modal is open: the prompt is disabled,
  clicks are off and nothing opens over another window.

A sign that streams out takes its rig with it.

## Data

| Where | What |
|---|---|
| `profile.plotName` | string, `""` = default; top-level, outside `tycoon`, so Rebirth keeps it. No schema bump: missing → `""`. Reconcile cuts it to 24 characters on character boundaries; non-strings and invalid UTF-8 become `""`. |
| Snapshot field `plotName` | the owner's own copy, used to pre-fill the window and choose the prompt wording |
| Plot attribute `PlotName` | the filtered name shown on the sign (`""` = default) |
| Tag `SNPlotSign` | the owner-sign part of each plot (every world) |

## Admin + analytics

- **Admin** (Players tab → Moderation): **Reset Plot Name** (`ResetPlotName`) is registered at
  runtime by `Server/Tycoon/PlotNameAdmin`. It is audited, needs confirmation and has a 1 s
  cooldown. It clears the name, so every sign shows the default again. The profile saves and pushes,
  and the player gets a kind toast. The audit message names the cleared (filtered) name.
- **Analytics** (tycoon family, KeySpec allowlisted): `renamePlot:set`, `renamePlot:reset`,
  `renamePlot:admin`. These appear in the report's "Features, teleports, renames, skips, plots" table.

## Decisions

- **One name everywhere.** The custom name replaces the default sign text in every world. Only the
  default keeps a per-world suffix.
- **Hub pads keep the display name.** The lobby / Base Camp pads went on showing who owns plot N, so
  players could find each other. *Retired by owner R134 (2026-11-01): the hub plot teleport pads were
  removed from every hub, so the plot name now shows only on each plot's entrance sign (and the
  Teleport menu's player rows).*
- **Censored names are refused, not hashed.** On re-display, a name the filter now changes falls
  back to the default.
- **The stand's default stays "Fresh Nukes!"** (lead option 3, decided no). The plot name lives on
  the entrance sign, and the Neon Sign stand rename stays its own Area 2 reward, so the purchase
  still means something. The stand's unlock rule is unchanged.
- **E / ButtonX** (the Roblox interact defaults, like the egg stands) are used instead of the stand
  sign's R / D-pad up. The prompt sits right in the owner's walkway, so it uses a short 0.3 s hold.
- **Analytics key style.** The key is `renamePlot:<set|reset|admin>`, matching the family's camelCase
  keys. The lead's brief called it "rename_plot".

## Tests and QA

- `tests/plot-name.luau`: parse / normalize / clean, the sign text, config sanity, hostile fuzz
  (4000 random strings) and the KeySpec keys.
- `tests/profile-logic.luau` §13: the plotName default, reconcile, round-trip, v1 migration and the
  snapshot field.
- `tests/validate.luau`: `RenamePlot` is declared once.
- Studio: `STUDIO_LOCK_OWNER=N-plotname python3 tools/qa/r88_plot_name.py [--input-only]` (solo
  playtest; probes `tools/qa/r88_plot_name_{client,server}.luau`). Captures and the JSON records
  (`r88-record.json`, `r88-input-record.json`) go to `docs/verification/r88-plot-name/`:
  - the window on desktop, phone, tablet and console
  - the walk-up framing on each device
  - the hover outline
  - the renamed and reset signs
- Verified 2026-10-31:
  - `RenamePlot` put "Sparkle Base" on the signs in main, dino and moon, set `PlotName`, saved
    `profile.plotName` (outside `tycoon`) and switched the prompt to "Rename your plot"; the window
    pre-filled the name.
  - RESET and the admin ResetPlotName restored each world's default ("…'s Nukes", "…'s Dino
    Valley", "…'s Moon Base").
  - Real input: holding E (`simulate_keyboard_input`) at the prompt opened the window, and so did a
    real mouse click on the sign (`simulate_mouse_input`). The click ray hits `PlotSignClickBox`.
  - `PromptShown` fired on the walk-up.
  - No errors or warnings in the logs.
- Capture limits:
  - Studio captures leave out CoreGui, so the default ProximityPrompt UI (and the Roblox topbar)
    never appears in the images. `PromptShown` is the proof that the prompt shows.
  - In phone emulation, `simulate_mouse_input` coordinates do not match the capture, so the runner
    tries logical coordinates first and then capture-scaled ones.
