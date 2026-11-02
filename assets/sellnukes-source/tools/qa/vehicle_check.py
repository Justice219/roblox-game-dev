#!/usr/bin/env python3
"""
vehicle_check.py — R56 map-vehicle capture run (owner: "the delivery truck should drive in and out,
semi-truck should drive in and out"). Builds a full plot through the REAL game code in a Studio solo
playtest and captures each driven vehicle's in / loading / out moments plus the smaller movers.

Flow (Studio MCP on localhost via scripts/studio_mcp.py; reuses tools/qa/world_tour.py helpers):
    1. refuses to run unless the lock owner (env STUDIO_LOCK_OWNER, default V1-vehicles) holds
       scripts/studio-lock.py, and refuses if a playtest is already running (never ours to stop)
    2. starts a solo playtest; server `prepare` + `full` (TycoonAdmin.unlockAll + rebuildPlot)
    3. client: VehicleRoutes.Start(), HUD off, slow time (captures land on the intended moment)
    4. per shot: stream around the subject (server focus), frame the camera in slot-local space,
       seek the route to (segment, fraction), capture
    5. stats + runtime log scan, HUD on, server `restore` (pads + cash), stop the playtest
    6. writes <out>/shots.json, per-route sequence sheets and an overview sheet

Usage:
    python3 scripts/studio-lock.py acquire V1-vehicles
    python3 tools/qa/vehicle_check.py [--out docs/verification/vehicles]
    python3 scripts/studio-lock.py release V1-vehicles
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
os.environ.setdefault("STUDIO_LOCK_OWNER", "V1-vehicles")
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tools/qa"))
import studio_mcp  # noqa: E402  (localhost-only MCP transport)
import world_tour as tour  # noqa: E402  (server prepare/full/focus/restore, capture, sheet)

CLIENT = (ROOT / "tools/qa/vehicle_check_client.luau").read_text()
# Knockdown QA server half (owner R50): "knock" { area, seconds } / "rebuild" (admin paths).
KNOCK = (ROOT / "tools/qa/knockdown_check.luau").read_text()
KNOCK_COMMANDS = {"knock", "rebuild", "reset"}
CLIENT_COMMANDS = {"start", "world", "frame", "seek", "stats", "scale", "clean"}

# Route indices = order of VehicleRouteConfig.Routes.
VAN, SCOOTERS, CARTS, TRUCK, FORKLIFT, ROCKETS, CAR = 1, 2, 3, 4, 5, 6, 7

# (name, area, route, segment, fraction, eye xyz, target xyz, fov) — eye / target slot-local.
SHOTS = [
    ("van_1_in", 3, VAN, 3, 0.55, (24, 15, -10), (44, 2, 16), 60),
    ("van_2_loading", 3, VAN, 4, 0.30, (26, 14, 12), (40, 5, 30), 55),
    ("van_3_out", 3, VAN, 5, 0.70, (24, 15, -10), (48, 2, 6), 60),
    ("truck_1_road", 6, TRUCK, 3, 0.10, (30, 16, -24), (50, 2, 4), 60),
    ("truck_2_in", 6, TRUCK, 3, 0.80, (26, 12, 20), (46, 3, 46), 62),
    ("truck_3_loading", 6, TRUCK, 4, 0.32, (40, 10, 31), (46.4, 3.5, 52), 55),
    ("truck_4_out", 6, TRUCK, 5, 0.45, (26, 12, 20), (44, 3, 36), 62),
    ("car_1_barrier", 8, CAR, 2, 0.48, (18, 9, 4), (32, 2, 22), 60),
    ("car_2_parked", 8, CAR, 3, 0.50, (34, 5, 28), (45, 1.5, 37.5), 60),
    ("car_3_out", 8, CAR, 6, 0.40, (18, 9, 4), (32, 2, 22), 60),
    ("carts_tip", 4, CARTS, 2, 0.40, (-14, 11, 12), (-20, 2, 25), 60),
    ("carts_tunnel", 4, CARTS, 3, 0.85, (-10, 10, 36), (-22, 2, 56), 60),
    ("forklift_drop", 6, FORKLIFT, 3, 0.35, (-24, 10, 14), (-30, 2, 30), 60),
    ("scooters_lane", 3, SCOOTERS, 1, 0.30, (0, 16, 4), (0, 1, 30), 60),
    ("rockets_belt", 6, ROCKETS, 1, 0.40, (24, 9, 28), (26, 3, 40), 60),
]
SEQUENCES = {
    "van": ["van_1_in", "van_2_loading", "van_3_out"],
    "truck": ["truck_1_road", "truck_2_in", "truck_3_loading", "truck_4_out"],
    "car": ["car_1_barrier", "car_2_parked", "car_3_out"],
}


def client(command: str, args: list[float] | None = None) -> str:
    return tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": tour.render(CLIENT, command, CLIENT_COMMANDS, args or [])}))


def knock_server(command: str, args: list[float] | None = None) -> str:
    return tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": tour.render(KNOCK, command, KNOCK_COMMANDS, args or [])}))


def clocks() -> dict:
    return json.loads(client("stats"))["clocks"]


def knockdown_pass(out: Path) -> dict:
    """R50: area 6 knocked -> its vehicles freeze at once; rebuilt -> they resume after the delay."""
    report: dict = {}
    client("scale", [1])
    client("frame", [6, 30, 14, 22, 44, 3, 45, 65])
    time.sleep(1.0)
    report["knock"] = knock_server("knock", [6, 9])
    time.sleep(0.8)
    a = clocks()
    time.sleep(1.5)
    b = clocks()
    tour.capture(out / "knock_down.jpg")
    report["frozen"] = {k: round(b[k] - a[k], 3) for k in a if k in b}
    report["rebuild"] = knock_server("rebuild")
    time.sleep(1.5)
    c = clocks()
    time.sleep(1.0)
    d = clocks()
    report["still_paused_after_rebuild"] = {k: round(d[k] - c[k], 3) for k in c if k in d}
    time.sleep(6.0)
    e = clocks()
    time.sleep(1.0)
    f = clocks()
    report["resumed"] = {k: round(f[k] - e[k], 3) for k in e if k in f}
    tour.capture(out / "knock_rebuilt.jpg")
    return report


def belt_pass(out: Path) -> None:
    """Two frames 0.25 s apart on the conveyor: rockets and belt studs must travel the same way."""
    client("scale", [1])
    client("frame", [6, 26, 6.5, 33, 26, 3.4, 40, 40])
    time.sleep(1.0)
    tour.capture(out / "belt_a.jpg")
    time.sleep(0.25)
    tour.capture(out / "belt_b.jpg")


def tour_client(command: str, args: list[float] | None = None) -> str:
    return tour.client(command, args)


def shoot(shot: tuple, out: Path, settle: float) -> str:
    name, area, route, segment, frac, eye, target, fov = shot
    world = client("world", [area, eye[0], 0.5, eye[2]])  # stand under the camera, out of shot
    tour.server("focus", [float(v) for v in world.split(",")])
    time.sleep(settle)
    tour_client("hud_off")
    client("clean")
    client("frame", [area, *eye, *target, fov])
    time.sleep(0.7)  # one ranking refresh with the camera here
    print(f"[vehicles] {name}: {client('seek', [route, segment, frac])}", flush=True)
    time.sleep(0.5)
    client("frame", [area, *eye, *target, fov])  # a UI may have reset the camera meanwhile
    path = out / f"{name}.jpg"
    tour.capture(path)
    return path.name


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    parser.add_argument("--out", type=Path, default=ROOT / "docs/verification/vehicles")
    parser.add_argument("--settle", type=float, default=2.5)
    args = parser.parse_args()
    tour.require_lock()
    status = json.loads(studio_mcp.call_tool("solo_playtest", {"action": "status"}))
    if status.get("running"):
        raise SystemExit("a playtest is already running (not ours): not touching it")
    out: Path = args.out
    out.mkdir(parents=True, exist_ok=True)
    print(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:120], flush=True)
    names: list[str] = []
    report: dict = {}
    try:
        print("[vehicles]", tour.server("prepare"), flush=True)
        print("[vehicles]", tour.server("full"), flush=True)
        print("[vehicles] start", client("start"), flush=True)
        client("scale", [0.15])
        for shot in SHOTS:
            names.append(shoot(shot, out, args.settle))
        belt_pass(out)
        report["knockdown"] = knockdown_pass(out)
        print("[vehicles] knockdown", json.dumps(report["knockdown"]), flush=True)
        client("scale", [1])
        report["stats"] = json.loads(client("stats"))
        logs = studio_mcp.call_tool("get_runtime_logs", {"tail": 400})
        report["errors"] = [line for line in logs.splitlines() if "VehicleRoutes" in line or "RouteMath" in line][:40]
    finally:
        try:
            tour_client("hud_on")
            print("[vehicles]", tour.server("restore"), flush=True)
        finally:
            tour.stop_playtest()
    (out / "shots.json").write_text(json.dumps({"shots": names, **report}, indent=2))
    for label, sequence in SEQUENCES.items():
        tour.sheet(out, [n + ".jpg" for n in sequence], out / f"sheet_{label}.jpg", cols=len(sequence), width=480)
    tour.sheet(out, names, out / "sheet_all.jpg", cols=5, width=360)
    print(f"[vehicles] wrote {out}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
