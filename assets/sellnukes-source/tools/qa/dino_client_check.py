#!/usr/bin/env python3
"""
dino_client_check.py — the Dino Valley tycoon-CLIENT check (owner R57, W10b; plan §4 W10 task 7).
Drives the open place through the Studio MCP on localhost (scripts/studio_mcp.py). Hold the Studio
lock as STUDIO_LOCK_OWNER and never run it while someone else's playtest is up (owner R33 + the
lock rule). Server side reuses tools/qa/world2_check.luau (admin pipeline, focus, prepare,
restore); client side is tools/qa/dino_client_check_client.luau.

Tour (solo playtest; captures + JSON under docs/verification/world2/w10b-*):
    admin unlock -> travel to Dino -> D1 pads bought one by one through the real PadBuy intent
    (build-in captured mid-flight) -> WorldSetArea 6 (D6 pads + the finale pad billboard on the
    path) -> WorldUnlockAll (every Dino build) -> per-area views: torches / fan ears / nest +
    ptero couriers / wind sock / geysers / water wheel / incubators / volcano / lava falls / lava
    channel / managers + billboards, each with a motion probe -> device matrix (phone / tablet /
    console) on two billboard views -> stats -> restore the test profile.

Usage:
    python3 scripts/studio-lock.py acquire W10b-client
    STUDIO_LOCK_OWNER=W10b-client python3 tools/qa/dino_client_check.py
    STUDIO_LOCK_OWNER=W10b-client python3 tools/qa/dino_client_check.py --resume   # shots only
    STUDIO_LOCK_OWNER=W10b-client python3 tools/qa/dino_client_check.py --world moon  # any world
    python3 scripts/studio-lock.py release W10b-client
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tools/qa"))

os.environ.setdefault("STUDIO_LOCK_OWNER", "W10b-client")

import studio_mcp  # noqa: E402  (localhost-only MCP transport)
import world2_check as w2  # noqa: E402  (server(), admin(), matrix(), start_solo(), ready(), in_world())
import world_tour  # noqa: E402  (require_lock, render, result, capture, sheet, stop_playtest)

CLIENT = (ROOT / "tools/qa/dino_client_check_client.luau").read_text()
CLIENT_COMMANDS = {"view_at", "view", "view_area", "view_char", "nextpad", "buy", "probe", "stats", "gravity",
                   "dust_test", "rebirth_links",
                   "gravity_result",
                   "reset",
                   "open_rebirth", "open_welcome"}
OUT = ROOT / "docs/verification/world2"
PREFIX = "w10b-"

# View presets (dino_client_check_client.luau VIEWS) and the area each probes.
VIEWS = [
    (1, "d1-bench", 1), (2, "d1-torch", 1), (3, "d2-mammoth-fan", 2), (4, "d3-nest-couriers", 3),
    (5, "d3-windsock", 3), (6, "d4-geysers", 4), (7, "d4-water-wheel", 4), (8, "d5-incubators", 5),
    (9, "d6-volcano", 6), (10, "d6-lava-falls", 6), (11, "d6-lava-channel", 6),
    (14, "d3-captain", 3),
]


def client(command: str, args: list[float] | None = None) -> str:
    code = w2.render(CLIENT, command, CLIENT_COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def shot(name: str, names: list[str]) -> None:
    world_tour.capture(OUT / f"{PREFIX}{name}.jpg")
    names.append(f"{PREFIX}{name}.jpg")
    print(f"[w10b] {PREFIX}{name}.jpg", flush=True)


def view(preset: int, settle: float = 2.5) -> None:
    """Stands the character under the preset's camera (out of frame, streams the target in), then
    frames the target."""
    at = json.loads(client("view_at", [preset]))["at"]
    w2.server("focus", [*at])
    time.sleep(settle)
    # Any popup that opened meanwhile (notification opt-in, offers) would cover the shot.
    w2.client("modal_close")
    client("view", [preset])
    time.sleep(1.2)


def buy_next(record: dict, names: list[str], capture_as: str | None) -> str:
    """Streams to the next pad, fires PadBuy, optionally captures the build-in mid-flight."""
    info = json.loads(client("nextpad"))
    if not info.get("id"):
        return ""
    w2.server("focus", [*info["at"]])
    time.sleep(1.5)
    reply = json.loads(client("buy"))
    record.setdefault("bought", []).append(reply.get("id"))
    if capture_as:
        time.sleep(0.7)  # inside the master-builder fly-in
        shot(capture_as, names)
    return reply.get("id", "")


def tour(record: dict, names: list[str]) -> None:
    record["ready"] = w2.wait_client(w2.ready, 150)
    time.sleep(5)
    record["prepare"] = json.loads(w2.server("prepare"))
    w2.client("modal_close")
    # Unlock + travel to the Valley (the real TravelWorld intent), then our Dino plot.
    record["unlock"] = w2.admin(w2.UNLOCK)
    w2.client("modal_close")
    w2.client("travel", [1])
    record["arrive"] = w2.wait_client(w2.in_world(w2.WORLD), 25)
    time.sleep(2)
    w2.client("modal_close")
    record["grant"] = w2.admin(w2.GRANT_CASH, 1e15)
    record["sendPlot"] = w2.admin(w2.SEND_PLOT)
    time.sleep(5)
    # D1: buy pads one by one through the real intent; capture two build-ins mid-flight.
    view(1)
    shot("d1-fresh", names)
    for index in range(8):
        capture = "d1-buildin-a" if index == 1 else ("d1-buildin-b" if index == 4 else None)
        if capture:
            view(1, settle=1.0)
        if not buy_next(record, names, capture):
            break
        time.sleep(2.2)
    view(1)
    shot("d1-bought", names)
    record["statsD1"] = json.loads(client("stats"))
    # D6 pads on the path (finale pad billboard readable from the path / road).
    record["setArea6"] = w2.admin(w2.SET_AREA, 6)
    time.sleep(10)
    view(12)
    shot("d6-pads-path", names)
    w2.matrix(f"{PREFIX}d6-pads-path", names)
    # Everything built: per-area views with motion probes.
    record["unlockAll"] = w2.admin(w2.UNLOCK_ALL)
    time.sleep(18)
    shots(record, names)


def shots(record: dict, names: list[str]) -> None:
    """Per-area views + motion probes, billboard views + device matrix, stats (plot fully built)."""
    probes: dict = {}
    for preset, name, area in VIEWS:
        view(preset)
        shot(name, names)
        try:
            probes[name] = json.loads(client("probe", [area]))
        except Exception as error:  # area not streamed: recorded, the tour goes on
            probes[name] = {"error": str(error)[:200]}
    record["probes"] = probes
    # Producer billboards from the road (desktop) + device matrix.
    for preset, name in ((13, "d2-billboard-road"), (15, "d5-billboard-road")):
        view(preset)
        shot(name, names)
    view(13)
    w2.matrix(f"{PREFIX}d2-billboard-road", names)
    record["stats"] = json.loads(client("stats"))
    client("reset")


def view_area(area: int, settle: float = 2.5) -> None:
    """World-generic view of an area's producer from the road side (stands the character there)."""
    at = json.loads(client("view_area", [area, 1]))["at"]
    w2.server("focus", [*at])
    time.sleep(settle)
    w2.client("modal_close")
    client("view_area", [area])
    time.sleep(1.2)


def glue_shots(record: dict, names: list[str]) -> None:
    """--glue (with --world): only the jump + touchdown puff and the Rebirth / Welcome Back screens
    on the device matrix (a short re-verification turn after a screen or FX fix)."""
    w2.server("unanchor")
    time.sleep(1.5)
    w2.client("modal_close")
    client("view_char")
    client("gravity")
    # Mid-air (the apex is ~0.7 s in), then — once landed — the dust ring, frozen by the QA client
    # (TimeScale 0) so the capture never misses it; gravity_result un-freezes it.
    time.sleep(0.45)  # + capture latency: near the ~0.7 s apex
    shot("jump-apex", names)
    time.sleep(1.6)
    shot("landing-puff", names)
    time.sleep(1.5)
    record["gravity"] = json.loads(client("gravity_result"))
    print(f"[w10b] gravity {record['gravity']}", flush=True)
    if "--dust" in sys.argv[1:]:
        record["dustTest"] = client("dust_test")
        print(f"[w10b] dust {record['dustTest']}", flush=True)
        time.sleep(0.5)
        shot("dust-test", names)
        client("gravity_result")  # un-freeze
        return
    client("reset")
    for command, name in (("open_rebirth", "rebirth-tab"), ("open_welcome", "welcome-back")):
        w2.client("modal_close")
        record[command] = client(command)
        time.sleep(1.5)
        if command == "open_rebirth":
            # Bring the cross-world link well (two lines per extra world) into view.
            record["rebirthLinks"] = client("rebirth_links")
            print(f"[w10b] rebirth links {record['rebirthLinks']}", flush=True)
            time.sleep(0.6)
        shot(name, names)
        w2.matrix(f"{PREFIX}{name}", names)
    w2.client("modal_close")


def world_shots(record: dict, names: list[str]) -> None:
    """--world <id> (any extra world, e.g. moon): fully built plot -> one view + motion probe per
    area (layout producer, no build keys), the low-gravity jump probe (+ a capture at touchdown
    for the dust puff), producer billboards on the device matrix, stats."""
    areas = int(json.loads(client("stats")).get("areas", 0) or 0) or 6
    probes: dict = {}
    for area in range(1, areas + 1):
        try:
            view_area(area)
            shot(f"area{area:02d}", names)
            probes[f"area{area:02d}"] = json.loads(client("probe", [area]))
        except Exception as error:  # area not streamed / no layout: recorded, the tour goes on
            probes[f"area{area:02d}"] = {"error": str(error)[:200]}
    record["probes"] = probes
    # Gravity: a real jump on the plot (character released), then a touchdown capture.
    view_area(1)
    w2.server("unanchor")
    time.sleep(1.5)
    w2.client("modal_close")
    client("view_char")
    client("gravity")  # the jump runs on the client; capture the touchdown puff, then read it
    time.sleep(1.05)  # measured air time 1.47 s; the capture lands ~0.45 s after the call
    shot("landing-puff", names)
    time.sleep(1.5)
    record["gravity"] = json.loads(client("gravity_result"))
    print(f"[w10b] gravity {record['gravity']}", flush=True)
    view_area(2)
    w2.matrix(f"{PREFIX}area02-billboard", names)
    record["stats"] = json.loads(client("stats"))
    client("reset")
    # Glue screens with three worlds: the Rebirth tab of this world + Welcome Back rows.
    for command, name in (("open_rebirth", "rebirth-tab"), ("open_welcome", "welcome-back")):
        w2.client("modal_close")
        record[command] = client(command)
        time.sleep(1.5)
        shot(name, names)
        w2.matrix(f"{PREFIX}{name}", names)
    w2.client("modal_close")


def main() -> int:
    global OUT
    # --world <id>: any extra world (default dino); evidence goes to docs/verification/<id>/
    # (Dino keeps world2/). Validated like world2_check (lowercase id, registered by the server).
    if "--world" in sys.argv[1:]:
        world = sys.argv[sys.argv.index("--world") + 1]
        if not w2.WORLD_ID.match(world) or world == "main":
            raise SystemExit("--world must be an extra world id (e.g. moon)")
        w2.WORLD = world
        if world != "dino":
            OUT = ROOT / "docs/verification" / world
            w2.OUT = OUT  # w2.matrix writes the device captures to world2_check's OUT
    world_tour.require_lock()
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"world": w2.WORLD, "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    names: list[str] = []
    # --resume: OUR playtest is still up with the plot fully built (e.g. the MCP primary restarted
    # mid-tour): only the shots + restore + stop run. --shots: a fresh playtest, straight to the
    # fully built Dino plot (no pad-by-pad part), then the shots + restore + stop.
    resume = "--resume" in sys.argv[1:]
    only_shots = "--shots" in sys.argv[1:]
    if not resume:
        w2.start_solo()
    try:
        if resume:
            shots(record, names)
        elif w2.WORLD != "dino":
            record["ready"] = w2.wait_client(w2.ready, 150)
            time.sleep(5)
            record["prepare"] = json.loads(w2.server("prepare"))
            w2.client("modal_close")
            record["unlock"] = w2.admin(w2.UNLOCK)
            w2.client("modal_close")
            w2.client("travel", [1])
            record["arrive"] = w2.wait_client(w2.in_world(w2.WORLD), 25)
            time.sleep(2)
            record["sendPlot"] = w2.admin(w2.SEND_PLOT)
            if "--glue" in sys.argv[1:]:
                time.sleep(4)
                glue_shots(record, names)
            else:
                record["unlockAll"] = w2.admin(w2.UNLOCK_ALL)
                time.sleep(20)
                world_shots(record, names)
        elif only_shots:
            record["ready"] = w2.wait_client(w2.ready, 150)
            time.sleep(5)
            record["prepare"] = json.loads(w2.server("prepare"))
            w2.client("modal_close")
            record["unlock"] = w2.admin(w2.UNLOCK)
            w2.client("modal_close")
            w2.client("travel", [1])
            record["arrive"] = w2.wait_client(w2.in_world(w2.WORLD), 25)
            time.sleep(2)
            record["sendPlot"] = w2.admin(w2.SEND_PLOT)
            record["unlockAll"] = w2.admin(w2.UNLOCK_ALL)
            time.sleep(20)
            shots(record, names)
        else:
            tour(record, names)
    except Exception as error:
        record["error"] = str(error)[:800]
        print(f"[w10b] ERROR {error}", flush=True)
    finally:
        try:
            record["restore"] = w2.server("restore")
        except Exception as error:
            record["restoreError"] = str(error)[:300]
        suffix = "-resume" if resume else ("-shots" if only_shots else "")
        (OUT / f"{PREFIX}check{suffix}.json").write_text(json.dumps(record, indent=2))
        world_tour.stop_playtest()
    try:
        world_tour.sheet(OUT, [n for n in names if (OUT / n).exists()][:24], OUT / f"{PREFIX}sheet.jpg")
    except Exception as error:  # Pillow missing: the single captures are enough
        print(f"[w10b] sheet skipped: {error}", flush=True)
    print(json.dumps({k: record.get(k) for k in ("error", "restore", "bought")}, indent=2))
    return 0 if "error" not in record else 1


if __name__ == "__main__":
    raise SystemExit(main())
