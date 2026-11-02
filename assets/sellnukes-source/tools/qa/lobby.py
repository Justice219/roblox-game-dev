#!/usr/bin/env python3
"""
lobby.py — Studio QA for the R99 / R100 / R101 lobby work (L-lobby): the Lucky Wheel stage works
(walk-on, prompt, platform action, physical wheel spin), the lobby fixture signs fit, and the R15
lobby visitors walk / sit / talk. ONE solo playtest in the open place; hold the Studio lock and
never run it while someone else's playtest is up (owner R33 + the lock rule). The builder did not
run it (owner R92: builders never playtest); the lead does.

Steps (prints one JSON record; captures under docs/verification/r99-lobby/):
    1. refuse unless STUDIO_LOCK_OWNER holds the lock and no playtest is running
    2. start a solo Play playtest, wait for loading + plot, close modals, back to the hub spawn
    3. R101 signs: fixture census (sign texts, prompts, the old crate billboard gone) + framings of
       the crate stall / wheel stage / group chest / codes board (+ device matrix on the stall)
    4. R99 walk-on: stand on the bed in front of the stage steps, REALLY walk onto the platform
       (Humanoid:MoveTo) → the LuckyWheel screen must open (shot + device matrix); close it while
       standing there → must NOT re-open; walk off; then the ProximityPrompt path and the LobbyUse
       platform action path must each open it too
    5. R99 physical wheel: server grants 2 spins, a real SpinWheel → the hub wheel spins (angle
       probe before / mid / after + a mid-spin shot)
    6. R100 visitors: census (count / shown / tier / templates), raycast through a visitor must
       miss it and no part may collide / query / touch; lobby aerial shot; a forced speech bubble
       close-up (+ device matrix)
    7. admin switch: LobbyNpcsEnabled false → visitors gone; true → back
    8. stop OUR playtest (always), contact sheet r99-lobby-sheet.jpg

Usage:
    python3 scripts/studio-lock.py acquire lead
    STUDIO_LOCK_OWNER=lead python3 tools/qa/lobby.py
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

import studio_mcp  # noqa: E402  (localhost-only MCP transport)
import world_tour  # noqa: E402  (require_lock, render, result, capture, sheet, stop_playtest)

CLIENT = (ROOT / "tools/qa/lobby_client.luau").read_text()
CLIENT_COMMANDS = {
    "state", "modal_close", "place", "walk_on", "walk_off", "wheel", "close_wheel", "prompt", "tap",
    "frame", "camera_reset", "fixtures", "npcs", "speak", "spin",
}
OUT = ROOT / "docs/verification/r99-lobby"
# Built-in Studio device presets (custom resolutions alone fail: "no device is active").
DEVICES = [
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
]

# Server snippets (fixed text, no free-form input).
SERVER_GRANT = """
local Server = game:GetService("ServerScriptService").Server
local LuckySpinService = require(Server.Services.LuckySpinService)
local player = game:GetService("Players"):GetPlayers()[1]
if player == nil then return "no player" end
return tostring(LuckySpinService.grantSpins(player, 2))
"""
SERVER_NPC_STATS = """
local Server = game:GetService("ServerScriptService").Server
return game:GetService("HttpService"):JSONEncode(require(Server.World.LobbyNpcService).stats())
"""
SERVER_NPCS_OFF = 'game:GetService("ReplicatedStorage"):SetAttribute("LobbyNpcsEnabled", false) return "off"'
SERVER_NPCS_ON = 'game:GetService("ReplicatedStorage"):SetAttribute("LobbyNpcsEnabled", true) return "on"'


def client(command: str, args: list[float] | None = None) -> str:
    """Runs one whitelisted command of the client template in the playtest client."""
    code = world_tour.render(CLIENT, command, CLIENT_COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def client_json(command: str, args: list[float] | None = None) -> dict:
    return json.loads(client(command, args))


def server(code: str) -> str:
    return world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": code}))


def shot(name: str, names: list[str]) -> str:
    file = f"{name}.jpg"
    world_tour.capture(OUT / file)
    names.append(file)
    print(f"[lobby] {file}", flush=True)
    return file


def matrix(name: str, names: list[str], devices: list[dict] = DEVICES) -> list[str]:
    """capture_device_matrix on the playtest client; one jpg per device."""
    response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
        "entries": devices, "target": "client-1", "format": "jpeg", "quality": 86, "settleSeconds": 1.0,
        "restoreAfter": True,
    }})
    images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
    files = []
    for device, image in zip(devices, images):
        file = f"{name}-{device['label']}.jpg"
        (OUT / file).write_bytes(base64.b64decode(image["data"], validate=True))
        files.append(file)
    if not images:
        print("[lobby] matrix failed: " + json.dumps(response)[:300], flush=True)
    names += files
    return files


def wait_ready(seconds: float) -> dict:
    """Waits until the client finished loading and owns a plot (the reveal hand-off is done)."""
    deadline = time.time() + seconds
    last: dict = {}
    while time.time() < deadline:
        try:
            last = client_json("state")
            if last.get("loadingDone") and last.get("plotIndex", 0) > 0:
                return last
        except Exception as error:  # client VM not up yet
            last = {"error": str(error)[:200]}
        time.sleep(2)
    return last


def wait_wheel(open_wanted: bool, seconds: float) -> dict:
    """Polls the LuckyWheel screen state until it matches (or the time runs out)."""
    deadline = time.time() + seconds
    last: dict = {}
    while time.time() < deadline:
        last = client_json("wheel")
        if bool(last.get("open")) == open_wanted:
            return last
        time.sleep(0.4)
    return last


def runtime_errors() -> list[str]:
    """Log lines from the lobby modules that look like errors or warnings."""
    raw = studio_mcp.call_tool("get_runtime_logs", {"tail": 500})
    keys = ("Lobby", "StallSigns", "LobbyNpc", "LobbyFixtures")
    lines = [line for line in raw.replace("\\n", "\n").split("\n") if any(k in line for k in keys)]
    return [line[:300] for line in lines if "rror" in line or "arn" in line][:40]


def main() -> int:
    world_tour.require_lock()
    status = studio_mcp.call_tool("solo_playtest", {"action": "status"})
    if '"running":true' in status.replace(" ", ""):
        raise SystemExit(f"a playtest is already running; not touching it: {status[:200]}")
    OUT.mkdir(parents=True, exist_ok=True)
    names: list[str] = []
    record: dict = {"log": []}
    log = record["log"].append
    log(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:160])
    try:
        record["ready"] = wait_ready(150)
        time.sleep(6)  # reveal teleport + hub meshes + lobby visitor templates
        log(client("modal_close"))
        log(client("place", [2]))
        time.sleep(5)  # streaming around the hub, sign rescans (2 s), visitors spawn (0.5 s refresh)
        log(client("modal_close"))

        # 3. R101 signs.
        record["fixtures"] = client_json("fixtures")
        for index, label in ((1, "crate-stall"), (2, "wheel-stage"), (3, "group-chest"), (4, "codes-board")):
            client("frame", [index])
            time.sleep(1.5)
            shot(f"r101-sign-{label}", names)
        client("frame", [1])
        time.sleep(1.0)
        matrix("r101-sign-crate-stall", names)
        client("camera_reset")

        # 4. R99 walk-on (real walking), no re-open while standing, prompt + action paths.
        log(client("place", [1]))
        time.sleep(1.5)
        log(client("modal_close"))
        record["beforeWalk"] = client_json("wheel")
        log(client("walk_on"))
        record["walkOnOpened"] = wait_wheel(True, 6)
        time.sleep(1.2)
        shot("r99-walk-on-opened", names)
        matrix("r99-walk-on-opened", names)
        log(client("close_wheel"))
        time.sleep(2.5)
        record["standingNoReopen"] = client_json("wheel")
        log(client("walk_off"))
        time.sleep(3.0)
        log(client("prompt"))
        record["promptOpened"] = wait_wheel(True, 3)
        log(client("close_wheel"))
        time.sleep(1.0)
        record["actionTap"] = client_json("tap")
        record["actionOpened"] = wait_wheel(True, 3)
        log(client("close_wheel"))
        time.sleep(1.0)

        # 5. Physical wheel spin on a real server-rolled result.
        log("grant " + server(SERVER_GRANT))
        time.sleep(1.0)
        client("frame", [2])
        record["wheelBefore"] = client_json("fixtures").get("wheelAngle")
        log(client("spin"))
        time.sleep(1.4)
        mid = client_json("fixtures")
        record["wheelMid"] = {"angle": mid.get("wheelAngle"), "spinning": mid.get("spinning")}
        shot("r99-wheel-spinning", names)
        time.sleep(4.0)
        after = client_json("fixtures")
        record["wheelAfter"] = {"angle": after.get("wheelAngle"), "spinning": after.get("spinning")}
        log(client("modal_close"))

        # 6. R100 visitors.
        log(client("place", [2]))
        client("camera_reset")
        time.sleep(3.0)
        record["serverNpcs"] = json.loads(server(SERVER_NPC_STATS))
        record["npcs"] = client_json("npcs")
        client("frame", [5])
        time.sleep(1.5)
        shot("r100-lobby-aerial", names)
        log(client("speak"))
        time.sleep(1.2)
        client("frame", [6])
        time.sleep(1.0)
        shot("r100-visitor-bubble", names)
        matrix("r100-visitor-bubble", names)
        client("camera_reset")

        # 7. Admin switch.
        log(server(SERVER_NPCS_OFF))
        time.sleep(1.6)
        record["npcsOff"] = client_json("npcs").get("visitors")
        log(server(SERVER_NPCS_ON))
        time.sleep(2.0)
        record["npcsOn"] = client_json("npcs").get("visitors")
        record["logIssues"] = runtime_errors()
    finally:
        world_tour.stop_playtest()
    world_tour.sheet(OUT, names, OUT / "r99-lobby-sheet.jpg", cols=4, width=480)
    record["shots"] = names
    # Verdicts (the lead reads these first).
    record["verdict"] = {
        "walkOnOpens": bool(record.get("walkOnOpened", {}).get("open")),
        "noReopenWhileStanding": not record.get("standingNoReopen", {}).get("open", True),
        "promptOpens": bool(record.get("promptOpened", {}).get("open")),
        "actionOpens": bool(record.get("actionOpened", {}).get("open")),
        "wheelSpun": bool(record.get("wheelMid", {}).get("spinning")),
        "signs": record.get("fixtures", {}).get("signs"),
        "crateBillboardGone": record.get("fixtures", {}).get("crateBillboard") is False,
        "visitors": record.get("npcs", {}).get("visitors"),
        "visitorsNotHittable": record.get("npcs", {}).get("raycastHitsVisitor") is False
        and record.get("npcs", {}).get("anyCollidable") is False,
        "adminSwitch": record.get("npcsOff") == 0 and (record.get("npcsOn") or 0) > 0,
    }
    print(json.dumps(record, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
