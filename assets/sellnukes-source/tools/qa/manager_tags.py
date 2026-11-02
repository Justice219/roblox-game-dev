#!/usr/bin/env python3
"""
manager_tags.py — Studio QA for the R87 manager nametags + speech bubbles (Client/Tycoon/Npc/
{ManagerController, ManagerTags, ManagerTagLogic}, Shared/Config/ManagerTagConfig). One SOLO
playtest in the open place; hold the Studio lock and never run it while someone else's playtest is up.

Steps (prints one JSON record; captures under docs/verification/r87-manager-tags/):
    1. refuse unless STUDIO_LOCK_OWNER holds the lock and no playtest is running
    2. start a solo Play playtest, wait for the plot + loading hand-off, close modals
    3. server: make sure managers of areas 1..5 are owned (TycoonAdmin.setArea(6) ONLY when fewer
       are owned — additive, Studio "_Studio" profile, nothing removed)
    4. each SHOTS view: stand near the manager facing it, follow-camera framing, probe the tags
       (shown / nudged / yielded), force a bubble (QA hook) and hold it, desktop shot, and for the
       open views (area 4, the garage from inside its door) capture_device_matrix (phone /
       tablet / console); every client simulation is stopped after each matrix and the edit
       simulator is put back the way it was found
    5. area 2 knocked down (admin test path): dazed stars + the lifted tag, desktop shot; rebuild
    6. the garage manager up close (the tag must not balloon)
    7. stop the playtest (only ours), log issues from the R87 modules

Usage:
    python3 scripts/studio-lock.py acquire M-managers
    STUDIO_LOCK_OWNER=M-managers python3 tools/qa/manager_tags.py
    python3 scripts/studio-lock.py release M-managers
"""

from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tools/qa"))

import studio_mcp  # noqa: E402
import world_tour  # noqa: E402  (require_lock, render, result, capture, sheet)

SERVER = (ROOT / "tools/qa/manager_tags_server.luau").read_text()
CLIENT = (ROOT / "tools/qa/manager_tags_client.luau").read_text()
SERVER_COMMANDS = {"setup", "focus", "knock", "rebuild"}
CLIENT_COMMANDS = {"diag", "camera", "camera_reset", "probe", "bubble", "hold", "modal_close"}
OUT = ROOT / "docs/verification/r87-manager-tags"
# Built-in Studio device presets (custom resolutions alone fail: "no device is active").
DEVICES = [
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
]
STAND = 15  # studs from the manager (a player walking up to it)
BACK, UP = 11, 7  # follow-camera offset behind / above the character
# Tag views: (capture name, area, stand studs, camera back, camera up, device matrix?). Area 4 and
# the garage from inside its door show tag + bubble in the open; area 2 (the Nuke Stand awning hides
# the robot and most of its tag from the road: depth-tested by design) and area 3 (BoomDash: the
# board sits above the Dispatcher at some points of its loop -> nudged or hidden) are desktop only.
SHOTS = [
    ("area4", 4, STAND, BACK, UP, True),
    ("area1-inside", 1, 10, 6, 3, True),
    ("area2", 2, STAND, BACK, UP, False),
    ("area3", 3, STAND, BACK, UP, False),
]


def server(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(SERVER, command, SERVER_COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": code}))


def client(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(CLIENT, command, CLIENT_COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def shot(name: str) -> str:
    path = OUT / f"{name}.jpg"
    world_tour.capture(path)
    return str(path.relative_to(ROOT))


def matrix(prefix: str) -> list[str]:
    """capture_device_matrix on the playtest client; one jpg per device."""
    response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
        "entries": DEVICES, "target": "client-1", "format": "jpeg", "quality": 88, "settleSeconds": 0.8,
        "restoreAfter": True,
    }})
    images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
    names = []
    for device, image in zip(DEVICES, images):
        path = OUT / f"{prefix}-{device['label']}.jpg"
        path.write_bytes(base64.b64decode(image["data"], validate=True))
        names.append(str(path.relative_to(ROOT)))
    if not images:
        names.append("matrix failed: " + json.dumps(response)[:300])
    names.append(stop_simulation("client-1"))
    return names


def refresh_lock() -> None:
    """Keeps our Studio lock fresh during the ~10 minute run (it goes stale otherwise)."""
    owner = os.environ.get("STUDIO_LOCK_OWNER", world_tour.LOCK_OWNER)
    subprocess.run([sys.executable, str(ROOT / "scripts/studio-lock.py"), "refresh", owner],
                   capture_output=True, text=True, check=False)


def stop_simulation(target: str) -> str:
    """Stops device simulation on a peer (never leaves Studio emulating a device)."""
    try:
        return studio_mcp.call_tool("set_device_simulator", {"target": target, "stopSimulation": True})[:160]
    except RuntimeError as error:
        return f"stop {target}: {str(error)[:160]}"


def probe() -> dict:
    return json.loads(client("probe"))


def wait_ready(seconds: float) -> dict:
    deadline = time.time() + seconds
    last: dict = {}
    while time.time() < deadline:
        try:
            last = json.loads(client("diag"))
            if last.get("loadingDone") and last.get("plotIndex"):
                return last
        except Exception as error:  # client VM not up yet
            last = {"error": str(error)[:200]}
        time.sleep(2)
    return last


def runtime_errors() -> list[str]:
    """Client / server log lines from the R87 modules that look like errors or warnings."""
    raw = studio_mcp.call_tool("get_runtime_logs", {"tail": 500})
    keys = ("ManagerController", "ManagerTags", "ManagerTagLogic", "ManagerTagConfig", "manager_tags")
    lines = [line for line in raw.replace("\\n", "\n").split("\n") if any(k in line for k in keys)]
    return [line[:300] for line in lines if "rror" in line or "arn" in line or "ecursive" in line][:40]


def view(area: int, stand: float = STAND, back: float = BACK, up: float = UP) -> dict:
    """Stand near the area's manager, frame it like the follow camera, let tags settle."""
    refresh_lock()
    record = {"focus": server("focus", [area, stand])}
    time.sleep(2.0)  # streaming + the tag refresh (4 Hz) + yield hysteresis
    record["camera"] = client("camera", [area, back, up])
    time.sleep(1.5)
    record["probe"] = probe()
    return record


def bubble() -> dict:
    """Force a bubble (QA hook), then hold it long enough for a device matrix."""
    client("bubble")
    time.sleep(0.8)
    client("hold", [30])
    time.sleep(0.4)
    return probe()


def main() -> int:
    world_tour.require_lock()
    status = studio_mcp.call_tool("solo_playtest", {"action": "status"})
    try:
        running = json.loads(status).get("running") is True
    except (json.JSONDecodeError, AttributeError):
        running = True  # unknown state: never start on top of someone else's playtest
    if running:
        raise SystemExit(f"a playtest is already running (not ours): {status[:200]}")
    OUT.mkdir(parents=True, exist_ok=True)
    # The edit simulator as we found it (another agent may have set a preset on purpose).
    found = studio_mcp.call_tool("get_device_simulator_state", {"includeDeviceList": False})
    found_simulating = '"isSimulating":true' in found.replace(" ", "")
    record: dict = {"log": []}
    log = record["log"].append
    log(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:200])
    try:
        record["ready"] = wait_ready(150)
        time.sleep(3)
        record["setup"] = server("setup", [6])
        log("modals " + client("modal_close"))
        # Tag views: (capture name, area, stand studs, camera back, camera up, device matrix?).
        for name, area, stand, back, up, devices in SHOTS:
            entry = view(area, stand, back, up)
            entry["bubble"] = bubble()
            entry["desktop"] = shot(f"r87-{name}-desktop")
            if devices:
                entry["devices"] = matrix(f"r87-{name}")
            record[name] = entry
            log("modals " + client("modal_close"))
        # Knocked-down area: dazed stars + the lifted tag, no bubble.
        dazed = view(2)
        dazed["knock"] = server("knock", [2, 40])
        time.sleep(3.0)
        client("bubble")
        time.sleep(0.8)
        dazed["probe"] = probe()
        dazed["desktop"] = shot("r87-area2-dazed-desktop")
        dazed["rebuild"] = server("rebuild")
        record["area2dazed"] = dazed
        # Up close in the garage: the tag must not balloon.
        close = view(1, 6, 5, 3)
        close["desktop"] = shot("r87-area1-close-desktop")
        record["close"] = close
        client("camera_reset")
        record["logIssues"] = runtime_errors()
    finally:
        world_tour.stop_playtest()
        state = studio_mcp.call_tool("get_device_simulator_state", {"includeDeviceList": False})
        if not found_simulating and '"isSimulating":true' in state.replace(" ", ""):
            record["log"].append("edit simulator reset: " + stop_simulation("edit"))
    print(json.dumps(record, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
