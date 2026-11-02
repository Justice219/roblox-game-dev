#!/usr/bin/env python3
"""
billboard_check.py — Studio before/after captures of the producer-billboard placement (owner
R31 / R32, lead QA: "the billboard never covers its producer or manager"), through the real game
code in a solo playtest.

Flow (hold the Studio lock first: STUDIO_LOCK_OWNER=<you> python3 scripts/studio-lock.py acquire <you>):
    1. refuses to run unless STUDIO_LOCK_OWNER holds the lock; starts a solo playtest unless one
       this agent started is already running (--reuse)
    2. server `prepare` (plot ready + profile snapshot) and `full` (every area built) from
       tools/qa/world_tour.luau, so every producer + manager is present
    3. for each area shot: server `focus` (stream around the standard player camera), client
       `camera` (HUD hidden, Scriptable camera = the solver's standard viewpoint, looking at the
       producer), then `before` (pre-solver rule re-applied) -> capture, `after` (live
       ProducerBillboards.place) -> capture
    4. client `report` (live placement per area) -> <out>/report.json; contact sheets
       sheet_before.jpg / sheet_after.jpg / sheet_compare.jpg; restore + stop (unless --keep)

Usage:
    STUDIO_LOCK_OWNER=N2 python3 tools/qa/billboard_check.py [--out docs/verification/billboards]
        [--areas 1,2,3,6,7,8] [--reuse] [--keep]
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tools/qa"))

import studio_mcp  # noqa: E402  (localhost-only MCP transport)
import world_tour  # noqa: E402  (lock check, server commands, camera, capture, contact sheets)

CLIENT = (ROOT / "tools/qa/billboard_check_client.luau").read_text()
COMMANDS = {"views", "before", "after", "knock", "report"}
DEFAULT_AREAS = (1, 2, 3, 6, 7, 8, 10)  # lead QA list + owner R48 (Area 10)


def client(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(CLIENT, command, COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def shots(areas: list[int]) -> list[tuple[str, int, float, float]]:
    """(name, area, stand, camera back): the solver's mid viewpoint per area, plus the A1 bench
    close-up from inside the garage (the owner's uncle-atom-work.jpg angle)."""
    out: list[tuple[str, int, float, float]] = []
    for area in areas:
        if area == 1:
            out.append(("a01_bench", 1, 3.0, 5.0))
        out.append((f"a{area:02d}_stand", area, 12.0, 12.0))
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default=str(ROOT / "docs/verification/billboards"))
    parser.add_argument("--areas", default=",".join(str(a) for a in DEFAULT_AREAS))
    parser.add_argument("--reuse", action="store_true", help="use the playtest this agent already started")
    parser.add_argument("--keep", action="store_true", help="leave the playtest running afterwards")
    parser.add_argument("--settle", type=float, default=1.6)
    args = parser.parse_args()
    world_tour.require_lock()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    areas = [int(a) for a in args.areas.split(",") if a.strip()]
    log: list[str] = []
    if not args.reuse:
        print(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:120])
        time.sleep(5)
    names: list[str] = []
    try:
        log.append(world_tour.server("prepare"))
        log.append(world_tour.server("full"))
        time.sleep(3)
        for name, area, stand, back in shots(areas):
            view = json.loads(client("views", [area, stand, back]))
            world_tour.server("focus", view["focus"])
            world_tour.client("camera", [*view["eye"], *view["target"], 70])
            time.sleep(args.settle)
            camera = [*view["eye"], *view["target"], 70]
            log.append(client("before"))
            # Re-aim right before each capture: an area-enter camera effect can reclaim the camera.
            world_tour.client("camera", camera)
            time.sleep(0.6)
            world_tour.capture(out / f"{name}_before.jpg")
            log.append(client("after"))
            world_tour.client("camera", camera)
            time.sleep(0.8)
            world_tour.capture(out / f"{name}_after.jpg")
            names.append(name)
            print(f"[billboards] {name}", flush=True)
        # Owner R50 knockdown plate on the last area shot (client-side preview), then cleared.
        if names:
            last = areas[-1]
            log.append(client("knock", [last, 45]))
            time.sleep(0.8)
            world_tour.capture(out / f"a{last:02d}_knocked.jpg")
            log.append(client("knock", [last, 2.5]))
            time.sleep(0.8)
            world_tour.capture(out / f"a{last:02d}_rebuilding.jpg")
            log.append(client("knock", [last, 0]))
        report = client("report")
        (out / "report.json").write_text(json.dumps(json.loads(report), indent=1) + "\n")
        log.append(report)
    finally:
        try:
            world_tour.client("hud_on")
            log.append(world_tour.server("restore"))
        except Exception as error:  # noqa: BLE001 (best effort: always stop the playtest)
            log.append(f"restore failed: {error}")
        if not args.keep:
            print(studio_mcp.call_tool("solo_playtest", {"action": "stop", "timeout": 60})[:120])
        (out / "billboard-check.txt").write_text("\n".join(log) + "\n")
    world_tour.sheet(out, [f"{n}_before.jpg" for n in names], out / "sheet_before.jpg", cols=4)
    world_tour.sheet(out, [f"{n}_after.jpg" for n in names], out / "sheet_after.jpg", cols=4)
    pairs = [f for n in names for f in (f"{n}_before.jpg", f"{n}_after.jpg")]
    world_tour.sheet(out, pairs, out / "sheet_compare.jpg", cols=2, width=760)
    print("\n".join(log))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
