#!/usr/bin/env python3
"""
shop_models.py — owner R39 check: the Shop shows REAL 3D models (Widgets/ModelViewport) on every
card and pack tile, they spin only on screen within the device budget, and the window stays
fluid. One solo playtest in the open place (hold the Studio lock).

    STUDIO_LOCK_OWNER=W1b python3 scripts/studio-lock.py acquire W1b
    STUDIO_LOCK_OWNER=W1b python3 tools/qa/shop_models.py
    python3 scripts/studio-lock.py release W1b

Steps (client half: tools/qa/shop_models_client.luau, whitelisted commands only):
    1. frame time with the Shop closed (baseline)
    2. open the Shop at the top, wait for the model templates, capture shop-top.jpg
    3. scroll to every section, capture shop-<section>.jpg, record which slots show 3D vs icon
    4. frame time with the Shop open (spinning models on screen) + ModelViewport / OfferFx stats
    5. device matrix (phone / tablet / console) of the top and the passes section
    6. close the Shop: OfferFx must stop stepping the slots (paused while closed)
Outputs -> docs/verification/world-qa/shop/ (jpgs + shop-models.json).
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
import world_tour  # noqa: E402  (require_lock, render, result, capture)

CLIENT = (ROOT / "tools/qa/shop_models_client.luau").read_text()
COMMANDS = {"ready", "open", "wait", "slots", "frametime", "captions", "close"}
OUT = ROOT / "docs/verification/world-qa/shop"
# ShopConfig.Sections order (index 0 = top of the window).
SECTIONS = ["top", "limited", "passes", "cash", "gems", "spins", "boosts"]
# Device matrix: Studio's built-in presets (phone landscape, tablet landscape, 1080p TV / console).
# One capture call per device, so one failing preset never drops the others.
DEVICES = [
    {"label": "phone", "deviceId": "iphone_13", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "hd_1080"},
]


def client(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(CLIENT, command, COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def matrix(prefix: str) -> list[str]:
    """capture_device_matrix on the playtest client, one device per call; saves one jpg each."""
    names = []
    for device in DEVICES:
        response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
            "entries": [device], "target": "client-1", "format": "jpeg", "quality": 86,
            "settleSeconds": 1.5, "restoreAfter": True,
        }})
        images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
        if images:
            name = f"{prefix}-{device['label']}.jpg"
            (OUT / name).write_bytes(base64.b64decode(images[0]["data"], validate=True))
            names.append(name)
        else:
            names.append(f"{device['label']} failed: " + json.dumps(response)[:240])
    return names


def step(record: dict, label: str, action):
    """Runs one check step; a failure is logged (with its message) instead of aborting the run."""
    try:
        return action()
    except Exception as error:  # keep going: later steps + the stop / JSON must still happen
        record["log"].append(f"{label} failed: {str(error)[:300]}")
        print(f"[shop] {label} failed: {error}", flush=True)
        return None


def main() -> int:
    world_tour.require_lock()
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"log": [], "sections": {}}
    started = time.time()
    print(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:100])
    try:
        time.sleep(3)
        for _ in range(8):  # loading screen + plot reveal: up to ~160 s in 20 s polls
            state = client("ready", [20])
            if state == "ready":
                break
        record["log"].append(f"client {state}")
        record["frameClosed"] = json.loads(client("frametime", [3]))
        record["log"].append(client("open", [0]))
        record["load"] = json.loads(client("wait", [25]))
        time.sleep(1.0)
        world_tour.capture(OUT / "shop-top.jpg")
        for index, section in enumerate(SECTIONS[1:], start=1):
            client("open", [index])
            time.sleep(1.2)
            world_tour.capture(OUT / f"shop-{section}.jpg")
            record["sections"][section] = json.loads(client("slots"))["viewport"]
        record["slots"] = step(record, "slots", lambda: json.loads(client("slots")))
        client("open", [1])
        record["captions"] = step(record, "captions", lambda: json.loads(client("captions")))
        record["frameOpen"] = step(record, "frametime open", lambda: json.loads(client("frametime", [3])))
        client("open", [0])
        record["matrixTop"] = step(record, "matrix top", lambda: matrix("shop-top"))
        client("open", [2])
        record["matrixPasses"] = step(record, "matrix passes", lambda: matrix("shop-passes"))
        record["log"].append(client("close"))
        time.sleep(1.0)
        record["afterClose"] = step(record, "after close", lambda: json.loads(client("slots")))
    except Exception as error:
        record["log"].append(f"aborted: {str(error)[:300]}")
        raise
    finally:
        record["seconds"] = round(time.time() - started, 1)
        (OUT / "shop-models.json").write_text(json.dumps(record, indent=2) + "\n")
        world_tour.stop_playtest()
    slots = (record.get("slots") or {}).get("slots", {})
    shown = sum(1 for state in slots.values() if state == "3d")
    print(f"[shop] {shown}/{len(slots)} slots show 3D; load {record.get('load')}")
    print(f"[shop] frame closed {record.get('frameClosed')} open {record.get('frameOpen')}")
    print(f"[shop] after close: {(record.get('afterClose') or {}).get('viewport')} -> {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
