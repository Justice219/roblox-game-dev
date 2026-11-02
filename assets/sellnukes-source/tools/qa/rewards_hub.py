#!/usr/bin/env python3
"""
rewards_hub.py — Studio QA for the Rewards hub (owner R62: src/client/UI/Screens/RewardsHub +
src/client/UI/RewardsBadges). One solo playtest in the open place (hold the Studio lock).

Steps (prints one JSON record; screenshots under docs/verification/ui/rewards-hub/):
    1. start a solo Play playtest, wait for the HUD and the hub's registration
    2. close the boot windows (Welcome Back etc.), open the hub like the HUD Rewards button
    3. read every tile (badge / status / size) + the RewardsBadges snapshot (badge = total)
    4. capture desktop / phone / tablet / console (capture_device_matrix)
    5. CLICK the Daily tile like a player (simulate_mouse_input at its centre; when the simulated
       click does not land, the hub's { open = "Daily" } deep link drives the same openFeature
       path): Daily Rewards must open stacked over the hub and the hub window must hide; Back must
       return to the hub
    6. Gamepad: forced Gamepad mode -> a fresh open selects the first claimable tile; opening a
       feature and pressing Back puts the cursor back on that tile
    7. stop the playtest

Usage:
    python3 scripts/studio-lock.py acquire H3-hub
    STUDIO_LOCK_OWNER=H3-hub python3 tools/qa/rewards_hub.py
    python3 scripts/studio-lock.py release H3-hub
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

CLIENT = (ROOT / "tools/qa/rewards_hub_client.luau").read_text()
COMMANDS = {"diag", "close_all", "open_hub", "hub_state", "tile_point", "back", "pad_on", "pad_off",
            "selected", "reopen", "open_tile"}
OUT = ROOT / "docs/verification/ui/rewards-hub"
# Built-in Studio device presets (custom resolutions alone fail: "no device is active").
DEVICES = [
    {"label": "desktop", "deviceId": "hd_1080"},
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
]
FEATURES = ["Daily", "Time", "LuckyWheel", "Group", "Codes"]


def client(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(CLIENT, command, COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


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
    """Until the HUD is shown and the hub is registered."""
    deadline = time.time() + seconds
    last: dict = {}
    while time.time() < deadline:
        try:
            last = json.loads(client("diag"))
            if last.get("hud") and last.get("registered"):
                return last
        except Exception as error:  # client VM not up yet
            last = {"error": str(error)[:200]}
        time.sleep(2)
    return last


def main() -> int:
    world_tour.require_lock()
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"log": []}
    log = record["log"].append
    log(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:200])
    try:
        record["ready"] = wait_ready(150)
        time.sleep(6)  # first profile push + boot windows
        client("close_all")
        time.sleep(1.5)
        record["open"] = json.loads(client("open_hub"))
        record["badges"] = json.loads(client("diag"))["badges"]
        record["screens"] = matrix("hub")
        # A real click on the Daily tile (the tile's own handler: stacks Daily Rewards).
        point = json.loads(client("tile_point", [1]))
        if point:
            log(studio_mcp.call_tool("simulate_mouse_input", {"action": "click", "x": point["x"], "y": point["y"]})[:200])
        time.sleep(1.0)
        record["afterClick"] = json.loads(client("hub_state"))
        record["clickRegistered"] = record["afterClick"]["top"] == "DailyRewards"
        if not record["clickRegistered"]:
            # The simulated click did not land: drive the same openFeature path through the hub's
            # deep link ({ open = "Daily" }) so the stacking / hide / Back logic is still proven.
            record["afterClick"] = json.loads(client("open_tile", [1]))
        record["stackedScreens"] = matrix("hub-stacked-daily")
        log("back " + client("back"))
        time.sleep(0.6)
        record["afterBack"] = json.loads(client("hub_state"))
        # Gamepad: default selection + return-to-tile.
        log("pad " + client("pad_on"))
        record["padDefault"] = client("reopen")
        record["padStackTop"] = json.loads(client("open_tile", [3]))["top"]
        client("back")
        time.sleep(0.6)
        record["padReturn"] = client("selected")
        log("pad off " + client("pad_off"))
        client("close_all")
    finally:
        log(studio_mcp.call_tool("solo_playtest", {"action": "stop"})[:200])

    badges = record["badges"]
    open_state = record["open"]
    first_claimable = next((f for f in FEATURES if badges["features"].get(f, {}).get("count", 0) > 0), "Daily")
    tile_badges = [t["badge"] for t in open_state["tiles"]]
    checks = {
        "hub opens on top": open_state["open"] and open_state["top"] == "RewardsHub" and open_state["windowShown"],
        "five tiles": len(open_state["tiles"]) == 5,
        "tile badges match the model": all(
            (t["badge"] or None) == ((str(badges["features"][f]["count"]) if badges["features"][f]["count"] > 0 else None))
            for t, f in zip(open_state["tiles"], FEATURES)
        ),
        "HUD badge = total": (badges["badge"] or None) == (str(badges["total"]) if badges["total"] > 0 else None),
        "no NaN text": all("nan" not in t["status"].lower() for t in open_state["tiles"]),
        "daily tile stacks Daily Rewards": record["afterClick"]["top"] == "DailyRewards",
        "hub hides while covered": record["afterClick"]["open"] and not record["afterClick"]["windowShown"],
        "back returns to the hub": record["afterBack"]["top"] == "RewardsHub" and record["afterBack"]["windowShown"],
        "gamepad default = first claimable": record["padDefault"] == f"Open{first_claimable}",
        "wheel tile stacks the wheel": record["padStackTop"] == "LuckyWheel",
        "back re-selects the opened tile": record["padReturn"] == "OpenLuckyWheel",
    }
    record["tileBadges"] = tile_badges
    record["checks"] = checks
    print(json.dumps(record, indent=1))
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
