#!/usr/bin/env python3
"""
hatch_reveal.py — Studio QA for the egg hatch cinematic (owner R49,
src/client/UI/Screens/EggHatch/HatchRevealScreen.luau). One solo playtest in the open place
(hold the Studio lock; never run while someone else's playtest is going).

Steps (prints one JSON record; screenshots under docs/verification/ui/hatch/):
    1. refuse unless STUDIO_LOCK_OWNER holds the lock and no playtest is running
    2. start a solo Play playtest, wait for the loading hand-off + HUD
    3. server: grant 2 held Garage Eggs (PetService.grantEgg, the admin / reward path)
    4. client "real": hatch one through the REAL path (HatchEgg intent -> server roll -> reveal),
       freeze mid-build -> desktop shot, release -> reveal shot
    5. client "common", "rare", "mythic", "triple": fixed result rows (presentation of a server
       result), frozen at the last egg's third crack -> desktop shot (+ device matrix for rare and
       triple), then frozen 0.9 s after the last burst -> reveal shot (+ device matrix)
    6. stop the playtest (always)

Usage:
    python3 scripts/studio-lock.py acquire EH1-hatch
    STUDIO_LOCK_OWNER=EH1-hatch python3 tools/qa/hatch_reveal.py
    STUDIO_LOCK_OWNER=EH1-hatch HATCH_QA_SETS=rare,triple python3 tools/qa/hatch_reveal.py   # subset
    python3 scripts/studio-lock.py release EH1-hatch
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

CLIENT = (ROOT / "tools/qa/hatch_reveal_client.luau").read_text()
# Which sets to run (env HATCH_QA_SETS="rare,triple"); default: all of them.
SETS = set(filter(None, os.environ.get("HATCH_QA_SETS", "real,common,rare,mythic,triple,settings").split(",")))
COMMANDS = {"diag", "close", "real", "common", "rare", "mythic", "triple", "hold", "release",
            "settings_open", "settings_probe", "settings_back"}
OUT = ROOT / "docs/verification/ui/hatch"
# Built-in Studio device presets (custom resolutions alone fail: "no device is active").
DEVICES = [
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
]
# Settings window (R49 added the Fast Hatch row): the same devices, desktop first.
SETTINGS_DEVICES = [{"label": "desktop", "deviceId": "hd_1080"}, *DEVICES]

SERVER_GRANT = """
local Server = game:GetService("ServerScriptService").Server
local PetService = require(Server.Services.PetService)
local player = game:GetService("Players"):GetPlayers()[1]
if player == nil then return "no player" end
return tostring(PetService.grantEgg(player, "garage_egg", 2, "qa"))
"""


def client(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(CLIENT, command, COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def server(code: str) -> str:
    return world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": code}))


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
    return names


def settings_check() -> dict:
    """Settings window per device: probe (fit, clipping, toggle size / links) + screenshot, then B."""
    record: dict = {}
    for device in SETTINGS_DEVICES:
        args = {"target": "client-1", "deviceId": device["deviceId"]}
        if "orientation" in device:
            args["orientation"] = device["orientation"]
        record[device["label"] + "-sim"] = studio_mcp.call_tool("set_device_simulator", args)[:160]
        time.sleep(2.0)
        client("settings_open")
        time.sleep(1.2)
        record[device["label"]] = json.loads(client("settings_probe"))
        record[device["label"] + "-shot"] = shot(f"settings-{device['label']}")
    record["back"] = json.loads(client("settings_back"))
    record["sim-stop"] = studio_mcp.call_tool("set_device_simulator", {"target": "client-1", "stopSimulation": True})[:160]
    return record


def runtime_errors() -> list[str]:
    """Client / server log lines that mention the hatch or pet modules or look like errors."""
    raw = studio_mcp.call_tool("get_runtime_logs", {"tail": 400})
    keys = ("HatchStage", "HatchReveal", "HatchAnim", "HatchConfetti", "PetModels", "PetAnim", "Settings")
    lines = [line for line in raw.replace("\\n", "\n").split("\n") if any(k in line for k in keys)]
    return [line[:300] for line in lines if "rror" in line or "arn" in line][:40]


def wait_ready(seconds: float) -> dict:
    deadline = time.time() + seconds
    last: dict = {}
    while time.time() < deadline:
        try:
            last = json.loads(client("diag"))
            if last.get("loadingDone") and last.get("hud"):
                return last
        except Exception as error:  # client VM not up yet
            last = {"error": str(error)[:200]}
        time.sleep(2)
    return last


def present(name: str, devices: bool) -> dict:
    """Opens a fixed reveal, shoots mid-crack and the reveal (optionally on every device)."""
    times = json.loads(client(name))
    record: dict = {"times": times}
    time.sleep(times["midCrack"] + 1.2)
    record["midCrack"] = shot(f"{name}-midcrack-desktop")
    if devices:
        record["midCrackDevices"] = matrix(f"{name}-midcrack")
    client("hold", [times["lastBurst"] + 0.9])
    time.sleep(max(times["lastBurst"] + 0.9 - times["midCrack"], 0) + 1.2)
    record["reveal"] = shot(f"{name}-reveal-desktop")
    if devices:
        record["revealDevices"] = matrix(f"{name}-reveal")
    client("release")
    time.sleep(max(times["total"] - times["lastBurst"], 0) + 0.8)
    record["settled"] = shot(f"{name}-settled-desktop")
    client("close")
    time.sleep(1.0)
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
        log("close " + client("close"))
        log("grant " + server(SERVER_GRANT))
        time.sleep(2)
        log("diag " + client("diag"))
        if "real" in SETS:
            # The real server path (rarity = whatever the server rolls).
            log("real " + client("real", [2.15]))
            time.sleep(3.6)
            record["realMid"] = shot("real-midbuild-desktop")
            client("release")
            time.sleep(6)
            record["realReveal"] = shot("real-reveal-desktop")
            log("diag after real " + client("diag"))
            client("close")
            time.sleep(1.5)
        for name, devices in (("common", False), ("rare", True), ("mythic", False), ("triple", True)):
            if name in SETS:
                record[name] = present(name, devices)
        if "settings" in SETS:
            record["settings"] = settings_check()
        record["logIssues"] = runtime_errors()
        log("diag end " + client("diag"))
    finally:
        log(studio_mcp.call_tool("solo_playtest", {"action": "stop"})[:200])
    print(json.dumps(record, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
