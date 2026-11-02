#!/usr/bin/env python3
"""
knockdown_check.py — Studio QA for the temporary area knockdown (owner R50, Server/Tycoon/Knockdown +
Client/Tycoon/BuildIn/KnockdownFx + the KnockdownHud chip). One solo playtest in the open place
("Sell Nukes"); hold the Studio lock and never run it while someone else's playtest is up.

Steps (prints one JSON record; screenshots under docs/verification/attack/knockdown/):
    1. refuse unless STUDIO_LOCK_OWNER holds the lock and no playtest is running
    2. start a solo Play playtest, wait for the plot + loading hand-off
    3. server: own every pad of areas 1..3 (build-in), knockdowns on, default timers
    4. for areas 1 and 3: walk there, high three-quarter camera, slow FX (0.3x), capture
       before → knock (admin test path) → two topple frames → scattered (chip + dazed stars) →
       producer paused check → 4 rebuild taps (deadline must drop) → force rebuild → two
       rebuild frames → after, producer resumed check
    5. area 3 knocked: capture_device_matrix (phone / tablet / console) with the chip up
    6. stop the playtest (only ours), contact sheet

Usage:
    python3 scripts/studio-lock.py acquire Q3-knockdown
    STUDIO_LOCK_OWNER=Q3-knockdown python3 tools/qa/knockdown_check.py
    python3 scripts/studio-lock.py release Q3-knockdown
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

import studio_mcp  # noqa: E402
import world_tour  # noqa: E402  (require_lock, render, result, capture, sheet)

SERVER = (ROOT / "tools/qa/knockdown_check.luau").read_text()
CLIENT = (ROOT / "tools/qa/knockdown_check_client.luau").read_text()
SERVER_COMMANDS = {"setup", "focus", "knock", "check", "rebuild", "reset"}
CLIENT_COMMANDS = {"state", "camera", "camera_reset", "slow", "tap", "modal_close"}
OUT = ROOT / "docs/verification/attack/knockdown"
SLOW = 0.3
AREAS = (1, 3)
# Built-in Studio device presets (custom resolutions alone fail: "no device is active").
DEVICES = [
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
]


def server(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(SERVER, command, SERVER_COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": code}))


def client(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(CLIENT, command, CLIENT_COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def shot(name: str, names: list[str]) -> None:
    path = OUT / f"{name}.jpg"
    world_tour.capture(path)
    names.append(path.name)
    print(f"[knockdown] {path.name}", flush=True)


def matrix(prefix: str) -> list[str]:
    """capture_device_matrix on the playtest client; one jpg per device."""
    response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
        "entries": DEVICES, "target": "client-1", "format": "jpeg", "quality": 88, "settleSeconds": 0.8,
        "restoreAfter": True,
    }})
    images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
    names = []
    for device, image in zip(DEVICES, images):
        name = f"{prefix}-{device['label']}.jpg"
        (OUT / name).write_bytes(base64.b64decode(image["data"], validate=True))
        names.append(str(OUT / name))
    if not images:
        names.append("matrix failed: " + json.dumps(response)[:300])
    return names


def wait_ready(seconds: float) -> dict:
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
    world_tour.require_lock()
    status = studio_mcp.call_tool("solo_playtest", {"action": "status"})
    if '"running":true' in status.replace(" ", "") or '"state":"running"' in status.replace(" ", ""):
        raise SystemExit(f"a playtest is already running; not touching it: {status[:200]}")
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"log": [], "areas": {}}
    log = record["log"].append
    names: list[str] = []
    log(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:200])
    try:
        record["ready"] = wait_ready(150)
        time.sleep(3)
        record["setup"] = json.loads(server("setup"))
        time.sleep(14)  # staggered build-ins of ~30 pads
        log("modal " + client("modal_close"))
        for area in AREAS:
            entry: dict = {}
            server("focus", [area])
            time.sleep(3)
            client("camera", [area])
            client("slow", [SLOW])
            time.sleep(1.5)
            shot(f"area{area}-0-before", names)
            entry["knock"] = json.loads(server("knock", [area, 120]))
            time.sleep(0.7)
            shot(f"area{area}-1-topple", names)
            time.sleep(1.1)
            shot(f"area{area}-2-topple", names)
            time.sleep(4.5)
            shot(f"area{area}-3-scattered", names)
            entry["client_down"] = json.loads(client("state"))
            entry["check_down"] = json.loads(server("check", [area]))
            time.sleep(1.0)
            entry["check_down_later"] = json.loads(server("check", [area]))
            if area == AREAS[-1]:
                entry["matrix"] = matrix(f"area{area}-chip")
                client("camera", [area])
            client("tap", [area, 4])
            time.sleep(0.5)
            entry["after_taps"] = json.loads(server("check", [area]))
            entry["rebuilt"] = server("rebuild")
            time.sleep(0.9)
            shot(f"area{area}-4-rebuild", names)
            time.sleep(1.4)
            shot(f"area{area}-5-rebuild", names)
            time.sleep(6)
            shot(f"area{area}-6-after", names)
            entry["client_up"] = json.loads(client("state"))
            entry["check_up"] = json.loads(server("check", [area]))
            server("reset")
            record["areas"][str(area)] = entry
        client("slow", [1])
        client("camera_reset")
    finally:
        log(studio_mcp.call_tool("solo_playtest", {"action": "stop", "timeout": 60})[:200])
    world_tour.sheet(OUT, names, OUT / "sheet.jpg", cols=7, width=420)
    record["shots"] = names
    print(json.dumps(record, indent=1, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
