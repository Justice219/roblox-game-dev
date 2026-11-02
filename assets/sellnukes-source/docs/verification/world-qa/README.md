# World-QA camera tour

One script captures the whole built world through the **real game code**, so art builders don't
each need Studio time.

```bash
python3 scripts/studio-lock.py acquire W1   # or STUDIO_LOCK_OWNER=<name>
python3 tools/qa/world_tour.py                 # → docs/verification/world-qa/<YYYYMMDD-HHMM>/
python3 scripts/studio-lock.py release W1
```

What it does (solo playtest, via the Studio MCP):

1. **Prepare.** The server waits for the player's plot and ensures the hub
   (`HubBuilder.build`, idempotent). It then snapshots the test profile's owned pads and cash.
   HUD and core GUI are hidden; in-world billboards stay visible.
2. **Partial build.** `TycoonAdmin.resetPlot` → `setArea(4)` → `rebuildPlot(false)`, which builds
   areas 1–3. Shots: `partial_overview`, `partial_road`, plot entrance, areas 1–3 road views.
3. **Full build.** `TycoonAdmin.unlockAll` → `rebuildPlot(false)`, which builds all 10 areas with
   every pad bought. Shots:
   - hub overview and hub ground;
   - plot entrance;
   - each area from two angles: road (low, from the road side) and high (three-quarter, other side);
   - plot aerial, and the 8-plot ring aerial.
4. **Z-fight audit (owner R18).** The `ZFight` box pass runs over every visible part of the hub
   and the built plot (`src/shared/World/ZFight.luau`). The offender count and list go to
   `zfight.json`; the first six get close-ups (`zfight_NN.jpg`, `sheet_zfight.jpg`). Sign text is
   checked from the road on the area road shots (owner R17: arch text must not be mirrored).
5. **Restore.** The test profile is put back (pads + cash) and the playtest stops.
   `shots.json` and the contact sheets `sheet_partial.jpg` / `sheet_full.jpg` are written.

Shot positions come from `WorldLayout` inside `tools/qa/world_tour.luau` (`plan`), so the tour
follows the real plot / area-slot frames. Before each shot the character is anchored near the
subject and `RequestStreamAroundAsync` is called, which matters with StreamingEnabled.

## Other QA scripts (same lock rules; `STUDIO_LOCK_OWNER=<holder>`)

| Script | What it proves | Output |
|---|---|---|
| `tools/qa/load_benchmark.py [--new-only]` | R16 load times: hub stable, WorldReady, own fully built plot (target ≤ 8 s) + MeshLibrary latency stats | `load-benchmark.json` |
| `tools/qa/fix_check.py` | R17/R25/R26 yaw + motion groups, R19 glow caps; phase 2 (areas 1–5): **R41** every Centrifuge Row rotor stays on its own drum axis (drift < 0.1 stud) while turning (> 20° / 1.5 s), pivots on the drum tops; single centrifuges too | `fixes/` (`fix-check.txt`, `centrifuge-rotors.jpg`, ...) |
| `tools/qa/shop_models.py` | **R39** Shop 3D models: every card / pack tile slot "3d" vs "icon", template load time, spins only on screen (OfferFx stops stepping when the Shop closes), frame time closed vs open, device matrix (phone 844×390, tablet 1180×820, console 1080p) for the top + passes | `shop/` (`shop-*.jpg`, `shop-models.json`) |
| `tools/qa/shop_world.py --world moon` | **R70 / R57** a world's Shop section: unlocks the world through the admin pipeline (restored after), opens the Shop on it, records every card (3D prop vs icon, button text = live price / SOON, Selectable + gamepad links, tap size, currency preview), desktop capture + device matrix (iphone_13 / ipad_10th_generation / hd_1080) | `shop/` (`shop-<world>*.jpg`, `shop-<world>.json`) |
