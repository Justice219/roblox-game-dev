#!/usr/bin/env python3
"""
load_benchmark.py — owner R16 benchmark: how long from server boot until the hub and the player's
plot have their meshes, new loader vs the pre-R16 loader.

Runs two solo playtests (Studio MCP, localhost), each followed by
tools/qa/load_benchmark_server.luau (eval_server_runtime):
    1. NEW     (default MeshLibrary: 32 in flight, priority queue, boot warm-up, WorldReady)
    2. LEGACY  (attribute LegacyLoading = true on the MeshLibrary ModuleScript in edit mode:
               6 in flight, FIFO, no warm-up) — run SECOND so it enjoys the warmer asset cache,
               which makes the comparison conservative.
The attribute is always removed afterwards. Results -> docs/verification/world-qa/load-benchmark.json

Usage (hold the Studio lock):
    python3 scripts/studio-lock.py acquire W1
    python3 tools/qa/load_benchmark.py [--new-only]
    python3 scripts/studio-lock.py release W1
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import studio_mcp  # noqa: E402

sys.path.insert(0, str(ROOT / "tools/qa"))
import world_tour  # noqa: E402  (require_lock)

BENCH = (ROOT / "tools/qa/load_benchmark_server.luau").read_text()
OUT = ROOT / "docs/verification/world-qa/load-benchmark.json"
SET_LEGACY = 'game.ServerScriptService.Server.World.MeshLibrary:SetAttribute("LegacyLoading", {value}) return "ok"'


def run(label: str) -> dict:
    print(f"[bench] {label}: starting playtest", flush=True)
    print(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:100])
    try:
        raw = json.loads(studio_mcp.call_tool("eval_server_runtime", {"code": BENCH}))
        data = json.loads(raw["result"]) if isinstance(raw.get("result"), str) else raw
    finally:
        world_tour.stop_playtest()
    time.sleep(2)
    print(f"[bench] {label}: hub {data.get('hub')} s, plot {data.get('plot')} s, world {data.get('worldReadySeconds')}")
    stats = data.get("stats") or {}
    # Player-first diagnostics (MeshLibrary.stats): milestones, retries, deferred boot spawns and
    # the slowest template requests (which ids hold the tail of the first view).
    print(f"[bench] {label}: milestones {stats.get('milestones')} retries {stats.get('retries')} "
          f"deferred spawns {stats.get('deferredSpawns')} first-view keys {stats.get('firstViewKeys')}")
    for slow in (stats.get("slowest") or [])[:5]:
        print(f"[bench]   slow id {slow.get('id')}: {slow.get('seconds', 0):.2f} s, "
              f"{slow.get('attempts')} attempt(s), priority {slow.get('priority')}")
    return data


def main() -> int:
    world_tour.require_lock()
    # --new-only: skip the LEGACY comparison run (one playtest instead of two, for short lock turns).
    new_only = "--new-only" in sys.argv[1:]
    results = {}
    if new_only and OUT.exists():
        # Keep the last legacy measurement so the file still holds a comparison.
        previous = json.loads(OUT.read_text())
        if "legacy" in previous:
            results["legacy"] = previous["legacy"]
    try:
        studio_mcp.call_tool("execute_luau", {"code": SET_LEGACY.format(value="nil")})
        results["new"] = run("new")
        if not new_only:
            studio_mcp.call_tool("execute_luau", {"code": SET_LEGACY.format(value="true")})
            results["legacy"] = run("legacy")
    finally:
        studio_mcp.call_tool("execute_luau", {"code": SET_LEGACY.format(value="nil")})
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(results, indent=2) + "\n")
    print(f"[bench] -> {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
