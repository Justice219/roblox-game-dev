# SellNukes source snapshot

Read-only copy of the game, for reading and porting. Do not edit it here: the game repo is the
source of truth. Refresh with `python3 scripts/sync_from_game.py <game repo>`.

- Commit: `c5b5acd fix: keep the phone Happy Hour chip off the character (R138)`
- Copied on: 2026-11-01
- Files: 1070. Text only. Captures, reference images (see `assets/reference/`), caches and
  private QA dumps are left out.
- Masked: 12 third-party player names (`<player>`) and 12 ids (`0`).

## Reusing this code in a new game

These are SellNukes' own values. Replace them, or the new game will point at the wrong things:

| File | Holds |
|---|---|
| `src/shared/Config/AdminConfig.luau` | who gets the admin panel (`AdminUserIds`) |
| `src/shared/Config/PlayerTitlesConfig.luau` | title holders by user id |
| `src/shared/Config/PublishedProductIds.luau`, `MonetizationConfig.luau` | product and pass ids |
| `src/shared/Config/NotifyConfig.luau` | notification string ids |
| `src/shared/Config/IconAssets.luau`, mesh registries | uploaded asset ids |
| `tools/monetization/state.json` | the publish tool's record of live products |
| `default.project.json` | place settings |
| DataStore and topic names (`SellNukes…_v1`) | use your own, or two games could share data |
