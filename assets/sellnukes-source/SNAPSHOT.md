# SellNukes source snapshot

Read-only copy of the game, for reading and porting. Do not edit it here: the game repo is the
source of truth. Refresh with `python3 scripts/sync_from_game.py <game repo>`.

- Commit: `d25ae5c docs: record R140 outcome and the skill install`
- Copied on: 2026-11-01
- Files: 1072, plus the stud textures. Otherwise text only: captures, reference images (see
  `assets/reference/`), caches and private QA dumps are left out.
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
| `src/shared/Config/WorldMaterialConfig.luau`, `src/server/World/StudMaterialVariants.model.json` | uploaded stud texture ids |
| `tools/blender/upload_meshes.py`, `tools/ui/upload_world_studs.py` | "SellNukes" in uploaded asset names |
| `tools/blender/snkit/cloud.py` | `DEFAULT_KEY_FILE`, the Open Cloud key path |
| `tools/blender/snkit/core.py` | the colour palette |
| `scripts/studio-lock.py` | `LOCK_DIR`, the lock folder name |
| `default.project.json` | name, Lighting, streaming, `HttpEnabled` (leave false until a feature needs HTTP) |

Never copy `src/shared/Config/MeshAssets.luau`: it is generated, and its ids belong to this game.

## Files naming a DataStore or topic

Use your own names, or two games could share data:

- `src/server/Analytics/AnalyticsStore.luau`
- `src/server/Economy/ProfileStore.luau`
- `src/server/Leaderboards/LeaderboardLogic.luau`
- `src/server/Services/AnalyticsService.luau`
- `src/server/Services/PlayerDataService.luau`
- `src/shared/Config/AnalyticsConfig.luau`
- `src/shared/Config/HappyHourConfig.luau`
- `src/shared/Config/LeaderboardConfig.luau`
- `src/shared/Config/NotifyConfig.luau`
- `src/shared/Config/ShopConfig.luau`
- `src/shared/Config/SocialConfig.luau`
