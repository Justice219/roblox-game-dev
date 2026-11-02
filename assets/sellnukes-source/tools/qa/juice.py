#!/usr/bin/env python3
"""
juice.py — Studio QA for the R71 juice pass (src/client/Tycoon/Fx/{JuiceController, ClickCombo,
ProducerJuice, Fireworks, JuiceBanner, CameraPunch}). One solo playtest in the open place (hold the
Studio lock).

Steps (prints one JSON record; screenshots under docs/verification/juice/):
    1. start a solo Play playtest, wait for the loading hand-off + HUD + JuiceBanner registration
    2. stand in front of an own producer
    3. 60 combo presses -> combo chained (read at ~25), label up, the Heartbeat running; capture combo
    4. one real UPGRADE press -> an upgrade glow
    5. the milestone banner -> capture_device_matrix (desktop / phone / tablet / console)
    6. pad-buy coins, the rebirth celebration (flash + fireworks + punch) -> capture fireworks
    7. the finale confetti cannon
    8. idle -> the juice Heartbeat must be disconnected (no per-frame cost when nothing plays)
    9. stop the playtest

Usage:
    python3 scripts/studio-lock.py acquire H1
    STUDIO_LOCK_OWNER=H1 python3 tools/qa/juice.py
    STUDIO_LOCK_OWNER=H1 JUICE_MODE=showcase python3 tools/qa/juice.py   # long showcase captures
    python3 scripts/studio-lock.py release H1
"""

from __future__ import annotations

import base64
import json
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tools/qa"))

import studio_mcp  # noqa: E402
import world_tour  # noqa: E402  (require_lock, render, result)

CLIENT = (ROOT / "tools/qa/juice_client.luau").read_text()
COMMANDS = {"state", "clear", "showcase", "labels", "approach", "combo", "upgrade", "banner", "padbuy", "rebirth", "finale"}
OUT = ROOT / "docs/verification/juice"
# Built-in Studio device presets (custom resolutions alone fail: "no device is active").
DEVICES = [
    {"label": "desktop", "deviceId": "hd_1080"},
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
]


def client(command: str) -> str:
    code = world_tour.render(CLIENT, command, COMMANDS, [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def state() -> dict:
    return json.loads(client("state"))


def save(images: list, labels: list[str], prefix: str) -> list[str]:
    names = []
    for label, image in zip(labels, images):
        name = f"{prefix}-{label}.jpg"
        (OUT / name).write_bytes(base64.b64decode(image["data"], validate=True))
        names.append(str(OUT / name))
    return names


def matrix(prefix: str) -> list[str]:
    response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
        "entries": DEVICES, "target": "client-1", "format": "jpeg", "quality": 88, "settleSeconds": 0.4,
        "restoreAfter": True,
    }})
    images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
    names = save(images, [d["label"] for d in DEVICES], prefix)
    return names or ["matrix failed: " + json.dumps(response)[:300]]


def shot(prefix: str) -> list[str]:
    response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
        "entries": [DEVICES[0]], "target": "client-1", "format": "jpeg", "quality": 88, "settleSeconds": 0.1,
        "restoreAfter": True,
    }})
    images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
    return save(images, ["desktop"], prefix) or ["shot failed: " + json.dumps(response)[:300]]


def wait_ready(seconds: float) -> dict:
    deadline = time.time() + seconds
    last: dict = {}
    while time.time() < deadline:
        try:
            last = state()
            if last.get("loadingDone") and last.get("hud") and last.get("bannerRegistered"):
                return last
        except Exception as error:  # client VM not up yet
            last = {"error": str(error)[:200]}
        time.sleep(2)
    return last


def showcase() -> int:
    """JUICE_MODE=showcase: one long effects showcase captured on desktop + phone."""
    world_tour.require_lock()
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"log": []}
    log = record["log"].append
    log(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:200])
    try:
        record["ready"] = wait_ready(150)
        quiet = 0
        for _ in range(12):
            closed = client("clear")
            quiet = quiet + 1 if closed == "" else 0
            if quiet >= 3:
                break
            time.sleep(2)
        log(client("showcase"))
        time.sleep(4)
        record["state"] = state()
        record["labels"] = json.loads(client("labels"))
        response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
            "entries": [DEVICES[0], DEVICES[1]], "target": "client-1", "format": "jpeg", "quality": 88,
            "settleSeconds": 0.3, "restoreAfter": True,
        }})
        images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
        record["shots"] = save(images, ["desktop", "phone"], "showcase")
        time.sleep(16)
        record["idle"] = state()
    finally:
        log(studio_mcp.call_tool("solo_playtest", {"action": "stop"})[:200])
    print(json.dumps(record, indent=1))
    return 0


def main() -> int:
    if os.environ.get("JUICE_MODE") == "showcase":
        return showcase()
    world_tour.require_lock()
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"log": []}
    log = record["log"].append
    log(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:200])
    try:
        record["ready"] = wait_ready(150)
        # Join pop-ups arrive a few seconds after the hand-off: close them until none shows twice.
        quiet = 0
        for _ in range(12):
            closed = client("clear")
            log("clear " + (closed or "-"))
            quiet = quiet + 1 if closed == "" else 0
            if quiet >= 3:
                break
            time.sleep(2)
        log("approach " + client("approach"))
        time.sleep(1.5)
        log("combo " + client("combo"))
        time.sleep(4.1)  # 1 s settle + ~25 presses: the big burst + label x25
        record["combo"] = state()  # read while the chain is alive (0.7 s window)
        record["labels"] = json.loads(client("labels"))
        client("clear")
        record["comboShot"] = shot("combo")
        log("upgrade " + client("upgrade"))
        time.sleep(0.4)
        record["upgrade"] = state()
        time.sleep(4.5)  # the 60-press combo finishes + its label fades
        log("banner " + client("banner"))
        time.sleep(0.5)
        record["banner"] = state()
        record["bannerShots"] = matrix("banner")
        time.sleep(1)
        log("padbuy " + client("padbuy"))
        time.sleep(0.3)
        record["padShot"] = shot("padbuy")
        time.sleep(1.5)
        record["rebirth"] = json.loads(client("rebirth"))
        time.sleep(1.1)
        record["fireworksShot"] = shot("fireworks")
        time.sleep(3)
        log("finale " + client("finale"))
        time.sleep(0.5)
        record["finaleShot"] = shot("finale")
        time.sleep(6)
        record["idle"] = state()
    finally:
        log(studio_mcp.call_tool("solo_playtest", {"action": "stop"})[:200])
    checks = {
        "juice booted": bool(record["ready"].get("bannerRegistered")) and record["ready"].get("watched", 0) > 0,
        "combo chained": record["combo"].get("combo", 0) >= 20,
        "banner shows": bool(record["banner"].get("banner")),
        "rebirth fireworks": record["rebirth"].get("fireworks", 0) > 0,
        "idle disconnects": not record["idle"].get("loop", True) and not record["idle"].get("punch", True),
    }
    record["checks"] = checks
    print(json.dumps(record, indent=1))
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
