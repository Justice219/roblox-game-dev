#!/usr/bin/env python3
"""
social_hub.py — Studio QA for the six-tile Rewards hub (R78 R-social: the Friends tile + the fix
for cut status pills on phones; src/client/UI/Screens/RewardsHub). One SOLO playtest (hold the
Studio lock; owner R72: never multiplayer).

Steps (prints one JSON record; captures under docs/verification/r78-social/):
    1. start a solo Play playtest, wait for the HUD, close the boot windows, open the Rewards hub
    2. for phone / tablet / console / desktop: simulate the device on the playtest client, re-open
       the hub, and measure every status pill (tools/qa/social_client.luau "text_fit": the label's
       rendered box vs its text bounds, its size floor, TextFits) -> every pill must fit
    3. capture_device_matrix -> hub-6tiles-after-<device>.jpg
    4. stop the simulation and the playtest

Usage:
    python3 scripts/studio-lock.py acquire R-social
    STUDIO_LOCK_OWNER=R-social python3 tools/qa/social_hub.py
    python3 scripts/studio-lock.py release R-social
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tools/qa"))

import social  # noqa: E402  (client(), matrix(), wait_until(), OUT)
import studio_mcp  # noqa: E402
import world_tour  # noqa: E402

DEVICES = [
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
    {"label": "desktop", "deviceId": "hd_1080"},
]


def simulate(device: dict) -> str:
    args = {"target": "client-1", "deviceId": device["deviceId"]}
    if "orientation" in device:
        args["orientation"] = device["orientation"]
    return studio_mcp.call_tool("set_device_simulator", args)[:160]


def main() -> int:
    world_tour.require_lock()
    social.OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"log": [], "devices": {}}
    log = record["log"].append
    log(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:200])
    try:
        record["ready"] = social.wait_until(lambda: social.client("diag").get("hud"), 150)
        time.sleep(8)
        social.client("close_all")
        time.sleep(1.0)
        for device in DEVICES:
            log(simulate(device))
            time.sleep(2.5)
            social.client("close_all")
            time.sleep(0.8)
            social.client("open_hub")
            time.sleep(1.5)
            rows = (social.client("text_fit").get("rows") or [])
            pills = [r for r in rows if r.get("screen") == "RewardsHub" and r.get("boxH", 0) > 0
                     and r.get("text") not in ("Rewards",)]
            record["devices"][device["label"]] = {
                "labels": len(pills),
                "notFitting": [r for r in pills if not r.get("fits")],
                "sample": pills[:14],
            }
        studio_mcp.call_tool("set_device_simulator", {"target": "client-1", "stopSimulation": True})
        social.client("close_all")
        time.sleep(0.8)
        social.client("open_hub")
        time.sleep(1.5)
        record["shots"] = social.matrix("hub-6tiles-after")
        social.client("close_all")
    except Exception as error:  # keep the partial record: it is the diagnosis
        record["error"] = repr(error)[:500]
    finally:
        try:
            studio_mcp.call_tool("set_device_simulator", {"target": "client-1", "stopSimulation": True})
        except Exception:  # simulation already stopped / playtest gone
            pass
        world_tour.stop_playtest()

    checks = {"no error": "error" not in record}
    for label, info in record["devices"].items():
        checks[f"{label}: every hub label fits"] = info["labels"] > 0 and not info["notFitting"]
    record["checks"] = checks
    print(json.dumps(record, indent=1, default=str))
    failed = [name for name, ok in checks.items() if not ok]
    print("FAILED: " + ", ".join(failed) if failed else "ALL CHECKS PASSED")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
