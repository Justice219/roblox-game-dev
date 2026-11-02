#!/usr/bin/env python3
"""
hub_lobby_check.py — Studio captures of the lobby centre (owner R55, L1-lobby). One solo playtest in
the open place ("Sell Nukes"); hold the Studio lock and never run it while someone else's playtest
is up (owner R33 + the lock rule).

Steps (screenshots under docs/verification/world-art/, prefix = "before" | "after"):
    1. refuse unless STUDIO_LOCK_OWNER holds the lock and no playtest is running
    2. start a solo Play playtest, wait for the plot reveal hand-off, close modals
    3. put our character back on the hub spawn pad (the reveal teleports it to its plot)
    4. scripted review framings (tools/qa/hub_lobby_check_client.luau): spawn, statue, aerial,
       plot path, garden; device matrix (phone / tablet / console) on the spawn + statue views
    5. client FX census (hub ParticleEmitters + WorldFx-tagged pieces) printed as JSON
    6. stop OUR playtest, contact sheet hub-lobby-<prefix>-sheet.jpg

Usage:
    python3 scripts/studio-lock.py acquire L1-lobby
    STUDIO_LOCK_OWNER=L1-lobby python3 tools/qa/hub_lobby_check.py after
    python3 scripts/studio-lock.py release L1-lobby
"""

from __future__ import annotations

import base64
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tools/qa"))

import studio_mcp  # noqa: E402  (localhost-only MCP transport)
import world_tour  # noqa: E402  (require_lock, render, result, capture, sheet, stop_playtest)

CLIENT = (ROOT / "tools/qa/hub_lobby_check_client.luau").read_text()
CLIENT_COMMANDS = {"state", "go_spawn", "view", "camera_reset", "modal_close", "fx"}
OUT = ROOT / "docs/verification/world-art"
VIEWS = ((1, "spawn"), (2, "statue"), (3, "aerial"), (4, "path"), (5, "garden"))
# Built-in Studio device presets (custom resolutions alone fail: "no device is active").
DEVICES = [
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
]


def client(command: str, args: list[float] | None = None) -> str:
    """Runs one whitelisted command of the client template in the playtest client."""
    code = world_tour.render(CLIENT, command, CLIENT_COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def matrix(name: str, devices: list[dict]) -> list[str]:
    """capture_device_matrix on the playtest client; one jpg per device."""
    response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
        "entries": devices, "target": "client-1", "format": "jpeg", "quality": 86, "settleSeconds": 1.0,
        "restoreAfter": True,
    }})
    images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
    names = []
    for device, image in zip(devices, images):
        file = f"{name}-{device['label']}.jpg"
        (OUT / file).write_bytes(base64.b64decode(image["data"], validate=True))
        names.append(file)
    if not images:
        print("[lobby] matrix failed: " + json.dumps(response)[:300], flush=True)
    return names


def wait_ready(seconds: float) -> dict:
    """Waits until the client finished loading and owns a plot (the reveal hand-off is done)."""
    deadline = time.time() + seconds
    last: dict = {}
    while time.time() < deadline:
        try:
            last = json.loads(client("state"))
            if last.get("loadingDone") and last.get("plotIndex", 0) > 0:
                return last
        except Exception as error:  # client VM not up yet
            last = {"error": str(error)[:200]}
        time.sleep(2)
    return last


def main() -> int:
    prefix = sys.argv[1] if len(sys.argv) > 1 else "after"
    if prefix not in ("before", "after", "check"):
        raise SystemExit("prefix must be before | after | check")
    world_tour.require_lock()
    status = studio_mcp.call_tool("solo_playtest", {"action": "status"})
    if '"running":true' in status.replace(" ", ""):
        raise SystemExit(f"a playtest is already running; not touching it: {status[:200]}")
    OUT.mkdir(parents=True, exist_ok=True)
    names: list[str] = []
    record: dict = {}
    print(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:160], flush=True)
    try:
        record["ready"] = wait_ready(150)
        time.sleep(6)  # reveal teleport + hub meshes streaming in
        record["modal"] = client("modal_close")
        record["spawn"] = client("go_spawn")
        time.sleep(5)  # streaming around the spawn + WorldFx groups registered
        record["modal2"] = client("modal_close")
        for index, label in VIEWS:
            client("view", [index])
            time.sleep(1.6)
            file = f"hub-lobby-{prefix}-{label}.jpg"
            world_tour.capture(OUT / file)
            names.append(file)
            print(f"[lobby] {file}", flush=True)
        client("view", [1])
        time.sleep(1.0)
        names += matrix(f"hub-lobby-{prefix}-spawn", DEVICES)
        client("view", [2])
        time.sleep(1.0)
        names += matrix(f"hub-lobby-{prefix}-statue", DEVICES[:1])
        record["fx"] = json.loads(client("fx"))
        client("camera_reset")
    finally:
        world_tour.stop_playtest()
    world_tour.sheet(OUT, names, OUT / f"hub-lobby-{prefix}-sheet.jpg", cols=4, width=480)
    record["shots"] = names
    print(json.dumps(record, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
