#!/usr/bin/env python3
"""
pet_index.py — Studio QA for the R78 Pet Index rewards + the Golden Nukey pet (A-pets; spec
docs/superpowers/specs/2026-10-31-r78-retention-pack-design.md §5). One SOLO playtest in the open
place (hold the Studio lock; never multiplayer, owner R72). Prints one JSON record; captures go to
docs/verification/r78-pets/.

Steps:
    1. start a solo Play playtest, wait for the HUD + the first profile push
    2. server "prepare": Index = exactly 11 regular pets, then grant + equip a Golden Nukey through
       the LIVE PetService.grantPet path (the owned exclusive counts: 12 → 5 + 10 ready)
    3. capture the Golden Nukey following the player (two camera angles)
    4. open Pets on INDEX: panel state (pips / bar / CLAIM text / INDEX badge / HUD badge) +
       device matrix (desktop / phone / tablet / console)
    5. CLAIM by a real click (simulate_mouse_input at the button centre); when the simulated click
       does not land, the server claim path runs instead (same handler as the remote) — the
       panel must update + celebrate; then a repeat claim of the same milestone pays nothing
    6. hostile claim arguments (all refused), the gamepad default selection (CLAIM when ready,
       not CLAIM when nothing is ready)
    7. the Index deep link { tab = "index", select = "golden_nukey" }: its side panel + matrix
    8. restore the Studio profile, stop the playtest
Usage:
    python3 scripts/studio-lock.py acquire A-pets
    STUDIO_LOCK_OWNER=A-pets python3 tools/qa/pet_index.py          # everything
    STUDIO_LOCK_OWNER=A-pets python3 tools/qa/pet_index.py shots    # only the Golden Nukey captures
    python3 scripts/studio-lock.py release A-pets
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
import world_tour  # noqa: E402  (require_lock, render, result)

SERVER = (ROOT / "tools/qa/pet_index_server.luau").read_text()
CLIENT = (ROOT / "tools/qa/pet_index_client.luau").read_text()
SERVER_COMMANDS = {"prepare", "claim", "garbage", "status", "restore"}
CLIENT_COMMANDS = {"diag", "close_all", "open_index", "state", "point", "side", "pad_on", "pad_off", "reopen",
                   "pets_cam", "pets_front", "cam_reset", "open_nukey"}
OUT = ROOT / "docs/verification/r78-pets"

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
    """`pet_index.py shots`: only the Golden Nukey follow / front captures (start → prepare → shots →
    restore → stop)."""
    world_tour.require_lock()
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"log": []}
    log = record["log"].append
    log(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:200])
    try:
        record["ready"] = wait_ready(150)
        time.sleep(6)
        client("close_all")
        record["prepare"] = json.loads(server("prepare", [11]))
        time.sleep(3.0)
        log("cam " + client("pets_cam"))
        time.sleep(1.5)
        record["followShot"] = capture("golden-nukey-following.jpg")
        log("front " + client("pets_front"))
        time.sleep(1.2)
        record["frontShot"] = capture("golden-nukey-front.jpg")
        log("reset " + client("cam_reset"))
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
        record["prepare"] = json.loads(server("prepare", [11]))
        time.sleep(2.5)  # profile push + the follower model builds
        # 3. The Golden Nukey following the player.
        log("cam " + client("pets_cam"))
        time.sleep(1.5)
        record["followShot"] = capture("golden-nukey-following.jpg")
        log("front " + client("pets_front"))
        time.sleep(1.0)
        record["frontShot"] = capture("golden-nukey-front.jpg")
        log("reset " + client("cam_reset"))
        # 4. Pets → INDEX with two milestones ready.
        record["before"] = json.loads(client("open_index"))
        record["beforeShots"] = matrix("index-ready")
        # Gamepad: a ready milestone makes CLAIM the default selection.
        log("pad " + client("pad_on"))
        record["padDefaultReady"] = client("reopen")
        log("pad off " + client("pad_off"))
        # 5. CLAIM by a real click.
        point = json.loads(client("point", [1]))
        log("click " + click(point))
        time.sleep(1.2)
        status = json.loads(server("status"))
        record["clickLanded"] = "5" in status["claimed"]
        if not record["clickLanded"]:
            record["serverClaim"] = json.loads(server("claim", [1]))
        time.sleep(0.25)
        record["celebrateShot"] = capture("index-claim-juice.jpg")
        time.sleep(1.5)
        record["afterFirst"] = json.loads(client("state"))
        record["afterFirstStatus"] = json.loads(server("status"))
        time.sleep(1.2)
        record["repeat"] = json.loads(server("claim", [1]))
        time.sleep(1.2)
        record["second"] = json.loads(server("claim", [2]))
        time.sleep(1.0)
        record["afterSecond"] = json.loads(client("state"))
        record["afterShots"] = matrix("index-claimed")
        # 6. Hostile arguments + gamepad default selection (nothing ready now → not CLAIM).
        record["garbage"] = json.loads(server("garbage"))
        log("pad " + client("pad_on"))
        record["padDefaultNoneReady"] = client("reopen")
        log("pad off " + client("pad_off"))
        # 7. The Golden Nukey's Index entry (deep link: its page + side panel).
        record["side"] = json.loads(client("open_nukey"))
        record["nukeyIndexShots"] = matrix("index-golden-nukey")
        client("close_all")
    finally:
        try:
            record["restore"] = json.loads(server("restore"))
        except Exception as error:  # report, never mask the playtest stop
            record["restore"] = {"error": str(error)[:200]}
        world_tour.stop_playtest()

    prep = record["prepare"]
    before = record["before"]
    after = record["afterSecond"]
    first = record.get("afterFirstStatus", {})
    checks = {
        "Golden Nukey granted + equipped (live grant path)": prep.get("granted") and prep.get("equipped"),
        "Golden Nukey replicated in SNPets": "golden_nukey" in (prep.get("attribute") or ""),
        "11 regular + owned Golden Nukey = 12 → 5 + 10 ready": prep.get("found") == 12 and prep.get("ready") == ["5", "10"],
        "panel visible on INDEX": before["panelVisible"],
        "panel fits the side card": before["panelBox"] is not None and before["cardBox"] is not None
        and before["panelBox"]["y"] + before["panelBox"]["h"] <= before["cardBox"]["y"] + before["cardBox"]["h"],
        "stat counts vs non-exclusive total": before["stat"].startswith("Discovered") and f"/ {prep['total']}" in before["stat"],
        "CLAIM offers the first milestone": before["claim"] == "CLAIM +25 GEMS",
        "INDEX tab badge while ready": before["tabBadge"],
        "HUD Pets badge while ready": before["hudBadge"] != "",
        "claim paid 25 gems + 2 %": "5" in first.get("claimed", []) and abs(first.get("bonus", 0) - 0.02) < 1e-9,
        "repeat claim refused, no gems": record["repeat"]["ok"] is False and record["repeat"]["gemsDelta"] == 0,
        "second milestone paid 40 gems": record["second"]["ok"] and record["second"]["gemsDelta"] == 40,
        "Index Bonus reaches petCash (+2 %)": abs(record["second"]["petCashDelta"] - 0.02) < 1e-9,
        "panel after claims": after["bonus"] == "+4% cash" and after["claim"] == "FIND 8 MORE"
        and after["bar"] == "12 / 20",
        "badges clear when nothing is ready": not after["tabBadge"],
        "hostile claims refused": record["garbage"]["anyAccepted"] is False,
        "gamepad default is CLAIM when a milestone is ready": record["padDefaultReady"] == "IndexClaim",
        "gamepad default is not CLAIM when nothing is ready": record["padDefaultNoneReady"] != "IndexClaim",
        "Golden Nukey Index line": any("Nuke Pass" in text for text in record.get("side", [])),
        "profile restored": record["restore"].get("restored") is True,
    }
    record["checks"] = checks
    print(json.dumps(record, indent=1))
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
