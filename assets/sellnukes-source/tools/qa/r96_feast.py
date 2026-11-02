#!/usr/bin/env python3
"""
r96_feast.py — Studio QA for owner R96 ("the turkey i in the ground": Golden Turkeys stand ON the
ground, Catch! prompt over the head) and owner R97 ("start people off with like 3-4 filled in":
3 free starter Feast Stickers, once per season). One solo playtest in the open place (hold the
Studio lock; never run while someone else's playtest is going).

Steps (prints one JSON record; captures under docs/verification/r96-feast/):
    1. refuse unless STUDIO_LOCK_OWNER holds the lock and no playtest is running
    2. start a solo Play playtest, wait for the HUD + profile
    3. server: force the Harvest Feast ON (the 1 Hz tick runs the join-time starter grant)
    4. R97 new sheet: reset sheet + starter flag, grant now -> expect 3 granted (Stickers 1-3),
       a second grant attempt -> 0 (idempotent); toast shot right after the grant
    5. R97 top-up: reset sheet, give Sticker 1, reset flag, grant now -> expect 2 granted, 3 total
    6. Feast Sticker Sheet open -> desktop shot + device matrix (phone / tablet / console) showing 3/20
    7. R96 plot turkey: spawn on the player's plot, walk the character beside it, aim the camera,
       probe (bottom of the visual parts vs the walkable ground, prompt height) for ~6 s while it
       pecks + walks, desktop shot + device matrix
    8. R96 hub turkey: same in the hub event square
    9. restore Auto, stop the playtest (always)

Usage:
    python3 scripts/studio-lock.py acquire lead
    STUDIO_LOCK_OWNER=lead python3 tools/qa/r96_feast.py
    python3 scripts/studio-lock.py release lead
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

SERVER = (ROOT / "tools/qa/r96_feast_server.luau").read_text()
CLIENT = (ROOT / "tools/qa/r96_feast_client.luau").read_text()
SERVER_COMMANDS = {"force", "fresh", "topup", "status", "spawn", "goto", "restore"}
CLIENT_COMMANDS = {"diag", "probe", "camera", "free", "sheet", "close"}
OUT = ROOT / "docs/verification/r96-feast"
# Built-in Studio device presets (custom resolutions alone fail: "no device is active").
DEVICES = [
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
]
PLOT, HUB = 1, 2
PROBE_SAMPLES, PROBE_EVERY = 8, 0.75  # ~6 s: covers a peck stop and a walk leg


def client(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(CLIENT, command, CLIENT_COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def server(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(SERVER, command, SERVER_COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": code}))


def shot(name: str) -> str:
    path = OUT / f"{name}.jpg"
    world_tour.capture(path)
    return str(path.relative_to(ROOT))


def matrix(prefix: str) -> list[str]:
    """capture_device_matrix on the playtest client; one jpg per device."""
    response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
        "entries": DEVICES, "target": "client-1", "format": "jpeg", "quality": 88, "settleSeconds": 1.0,
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
    return names


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


def runtime_errors() -> list[str]:
    """Client / server log lines from the feast modules that look like errors or warnings."""
    raw = studio_mcp.call_tool("get_runtime_logs", {"tail": 400})
    keys = ("EventService", "EventController", "TurkeyRenderer", "TurkeySpawner", "EventDecor", "StickerSheet")
    lines = [line for line in raw.replace("\\n", "\n").split("\n") if any(k in line for k in keys)]
    return [line[:300] for line in lines if "rror" in line or "arn" in line][:40]


def turkey(zone: int, label: str) -> dict:
    """Spawns one turkey, walks the character beside it, probes it over time, captures it."""
    record: dict = {}
    spawned = json.loads(server("spawn", [zone]))
    record["spawn"] = spawned
    if "error" in spawned:
        return record
    x, y, z = spawned["x"], spawned["y"], spawned["z"]
    record["goto"] = server("goto", [x, y, z])
    time.sleep(2.5)  # streaming + the client acquires the pooled model
    client("camera", [x + 9, y + 5, z + 9, x, y + 1.5, z])
    samples = []
    for _ in range(PROBE_SAMPLES):
        samples.append(json.loads(client("probe")))
        time.sleep(PROBE_EVERY)
    record["samples"] = samples
    record["ok"] = all(sample.get("ok") for sample in samples)
    record["shot"] = shot(f"r96-{label}-turkey-desktop")
    record["devices"] = matrix(f"r96-{label}-turkey")
    client("free")
    return record


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
    record: dict = {"log": []}
    log = record["log"].append
    log(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:200])
    try:
        record["ready"] = wait_ready(150)
        time.sleep(4)  # plot assignment + first profile push
        record["force"] = json.loads(server("force"))
        # R97: brand-new sheet -> 3 starters, then idempotent.
        fresh = json.loads(server("fresh"))
        record["fresh"] = fresh
        time.sleep(0.6)
        record["toastShot"] = shot("r97-starter-toast-desktop")
        record["freshOk"] = fresh.get("granted") == 3 and fresh.get("again") == 0 and fresh.get("count") == 3
        # R97: sheet with 1 starter -> topped up by 2 to 3.
        topup = json.loads(server("topup", [1]))
        record["topup"] = topup
        record["topupOk"] = topup.get("granted") == 2 and topup.get("count") == 3
        time.sleep(1.0)
        record["clientStickers"] = json.loads(client("diag")).get("stickers")
        record["sheetTop"] = client("sheet")
        time.sleep(1.0)
        record["sheetShot"] = shot("r97-sticker-sheet-desktop")
        record["sheetDevices"] = matrix("r97-sticker-sheet")
        client("close")
        # R96: turkeys on a plot and in the hub.
        record["plot"] = turkey(PLOT, "plot")
        record["hub"] = turkey(HUB, "hub")
        record["logIssues"] = runtime_errors()
    finally:
        try:
            log("restore " + server("restore"))
        except Exception as error:  # the playtest may already be gone
            log(f"restore failed: {str(error)[:120]}")
        log(studio_mcp.call_tool("solo_playtest", {"action": "stop"})[:200])
    record["pass"] = bool(record.get("freshOk") and record.get("topupOk")
                          and record.get("plot", {}).get("ok") and record.get("hub", {}).get("ok"))
    print(json.dumps(record, indent=1))
    return 0 if record["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
