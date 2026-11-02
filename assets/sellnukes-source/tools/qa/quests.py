#!/usr/bin/env python3
"""
quests.py — Studio QA for R78 Quests (Q-quests; spec docs/superpowers/specs/
2026-10-31-r78-retention-pack-design.md §1). One SOLO playtest in the open place (hold the Studio
lock; never multiplayer, owner R72). Prints one JSON record; captures go to
docs/verification/r78-quests/.

Steps:
    1. start a solo Play playtest, wait for the HUD + the first profile push (with `quests`)
    2. server "prepare": goals 1-3 completed (goal 1 claimed), today's missions re-seeded with
       mission 1 finished, Clicker I ready → the HUD badge + the objective chip
    3. GOALS / DAILY / TROPHIES tabs: state + capture each; device matrix (desktop / phone / tablet /
       console) on GOALS
    4. the real progress bus: ProgressEvents → mission 2 counts
    5. CLAIM goal 2 by a real click (else the server claim path), then the repeat claim pays nothing
       (idempotent); mission 1 + Clicker I claims; the free reroll (second refused); hostile args
    6. gamepad default selection (forced Gamepad mode → reopen → the first CLAIM)
    7. restore the profile, stop the playtest
Usage:
    python3 scripts/studio-lock.py acquire Q-quests
    STUDIO_LOCK_OWNER=Q-quests python3 tools/qa/quests.py          # everything
    STUDIO_LOCK_OWNER=Q-quests python3 tools/qa/quests.py shots    # only the device-matrix captures
    python3 scripts/studio-lock.py release Q-quests
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
import world_tour  # noqa: E402  (require_lock, render, result, stop_playtest)

SERVER = (ROOT / "tools/qa/quests_server.luau").read_text()
CLIENT = (ROOT / "tools/qa/quests_client.luau").read_text()
SERVER_COMMANDS = {"prepare", "progress", "claim", "claimAll", "reroll", "garbage", "status", "restore"}
CLIENT_COMMANDS = {"diag", "close_all", "open", "state", "chip", "point", "pad_on", "pad_off", "reopen"}
OUT = ROOT / "docs/verification/r78-quests"

# Built-in Studio device presets (custom resolutions alone fail: "no device is active").
DEVICES = [
    {"label": "desktop", "deviceId": "hd_1080"},
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


def capture(name: str) -> str:
    response = studio_mcp.rpc("tools/call", {"name": "capture_screenshot", "arguments": {"format": "jpeg", "quality": 88}})
    images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
    if not images:
        return "capture failed"
    path = OUT / name
    path.write_bytes(base64.b64decode(images[0]["data"], validate=True))
    return str(path)


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


def screenshot_width() -> int:
    """Pixel width of the playtest viewport capture (simulate_mouse_input takes these pixels)."""
    import io
    from PIL import Image  # local QA dependency only
    response = studio_mcp.rpc("tools/call", {"name": "capture_screenshot", "arguments": {"format": "jpeg", "quality": 60}})
    images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
    if not images:
        return 0
    return Image.open(io.BytesIO(base64.b64decode(images[0]["data"]))).size[0]


def click(point: dict) -> str:
    """Clicks a client point: the client reports logical points, the input takes capture pixels."""
    if not point:
        return "no point"
    scale = screenshot_width() / max(point.get("viewportX", 1), 1) or 1
    x, y = round(point["x"] * scale), round(point["y"] * scale)
    return studio_mcp.call_tool("simulate_mouse_input", {"action": "click", "x": x, "y": y})[:160]


def wait_ready(seconds: float) -> dict:
    deadline = time.time() + seconds
    last: dict = {}
    while time.time() < deadline:
        try:
            last = json.loads(client("diag"))
            if last.get("hud") and last.get("profile"):
                return last
        except Exception as error:  # client VM not up yet
            last = {"error": str(error)[:200]}
        time.sleep(2)
    return last


def shots_only() -> int:
    """`quests.py shots`: prepare → GOALS + DAILY + TROPHIES device matrices → restore → stop."""
    world_tour.require_lock()
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"log": []}
    record["log"].append(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:200])
    try:
        record["ready"] = wait_ready(150)
        time.sleep(6)
        client("close_all")
        record["prepare"] = json.loads(server("prepare"))
        time.sleep(2.0)
        for index, tab in ((1, "goals"), (2, "daily"), (3, "trophies")):
            record[tab] = json.loads(client("open", [index]))
            record[f"{tab}Matrix"] = matrix(f"quests-{tab}")
        client("close_all")
        time.sleep(0.5)
        record["chip"] = json.loads(client("chip"))
        record["chipMatrix"] = matrix("objective-chip")
    finally:
        try:
            record["restore"] = json.loads(server("restore"))
        except Exception as error:
            record["restore"] = {"error": str(error)[:200]}
        world_tour.stop_playtest()
    print(json.dumps(record, indent=1))
    return 0 if record["restore"].get("restored") else 1


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "shots":
        return shots_only()
    world_tour.require_lock()
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"log": []}
    log = record["log"].append
    log(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:200])
    try:
        record["ready"] = wait_ready(150)
        time.sleep(6)  # first profile push + boot windows
        client("close_all")
        record["prepare"] = json.loads(server("prepare"))
        time.sleep(2.0)  # the `quests` push
        record["chipBefore"] = json.loads(client("chip"))
        record["chipShot"] = capture("objective-chip.jpg")
        # Tabs.
        record["goals"] = json.loads(client("open", [1]))
        record["goalsShot"] = capture("quests-goals.jpg")
        record["goalsMatrix"] = matrix("quests-goals")
        record["daily"] = json.loads(client("open", [2]))
        record["dailyShot"] = capture("quests-daily.jpg")
        record["trophies"] = json.loads(client("open", [3]))
        record["trophiesShot"] = capture("quests-trophies.jpg")
        record["dailyMatrix"] = (client("open", [2]) and matrix("quests-daily"))
        # The real progress bus.
        record["progress"] = json.loads(server("progress", [2]))
        time.sleep(2.5)  # throttled push (PushSeconds)
        record["dailyAfterProgress"] = json.loads(client("state"))
        # CLAIM goal 2 by a real click on GOALS.
        client("open", [1])
        time.sleep(0.4)
        point = json.loads(client("point"))
        log("click " + click(point))
        time.sleep(1.5)
        status = json.loads(server("status"))
        record["clickLanded"] = bool(status["claimed"][1])
        record["claim"] = json.loads(server("claim"))
        time.sleep(1.2)
        record["afterClaim"] = json.loads(client("state"))
        record["afterClaimShot"] = capture("quests-after-claim.jpg")
        record["claimAll"] = json.loads(server("claimAll"))
        record["reroll"] = json.loads(server("reroll"))
        record["garbage"] = json.loads(server("garbage"))
        time.sleep(1.5)
        record["dailyFinal"] = json.loads(client("open", [2]))
        record["dailyFinalShot"] = capture("quests-daily-after.jpg")
        # Gamepad default selection.
        log("pad " + client("pad_on"))
        record["padDefault"] = json.loads(client("reopen"))
        log("pad off " + client("pad_off"))
        record["status"] = json.loads(server("status"))
        client("close_all")
    finally:
        try:
            record["restore"] = json.loads(server("restore"))
        except Exception as error:
            record["restore"] = {"error": str(error)[:200]}
        world_tour.stop_playtest()
    print(json.dumps(record, indent=1))
    return 0 if record["restore"].get("restored") else 1


if __name__ == "__main__":
    raise SystemExit(main())
