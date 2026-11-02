#!/usr/bin/env python3
"""
defense_towers.py — Studio QA for the owner R80 buyable + upgradable AA defence towers
(Server/Services/DefenseService, Client/Attack/DefenseWorld, Screens/Defense, docs/attack.md §18).
One SOLO playtest in the open place (hold the Studio lock; never multiplayer, owner R72). Prints one
JSON record; captures go to docs/verification/r80-defense/.

Steps:
    1. start a solo Play playtest, wait for the HUD + the first profile push
    2. server "prepare": area 7 (targetable, no HQ tower), no tower slots, cash for slot 1 only
    3. HUD Attack button + "!" badge; the picker's red DEFEND!; the Defense window (summary + one
       card per slot) — device matrices (phone / tablet / console) of both
    4. walk to slot 1: the blue BUY pad billboard — capture + device matrix; walk ON the pad (the real
       server Touched buy) → fly-in capture → the tower + its UPGRADE billboard
    5. the real Interact path (DefenseWorld provider → DefenseTower) upgrades it; a double intent
       buys exactly one level; junk arguments change nothing
    6. area 9 + every slot at L3 (admin path): overview capture, live engagement stats (every tower
       fires), an admin test nuke with interceptors from the slot towers
    7. tower billboard matrix; Defense window built-state matrix; gamepad default selection
    8. restore cash + attack, stop the playtest (only ours)
Modes:
    (none)  the full R80 pass above (docs/verification/r80-defense/)
    pad     R80 pad billboard re-check: pad shot + device matrix, walk-on buy, tower sign shot
    r85     owner R85 (docs/verification/r85-attack/): a stored golden revenge nuke → the picker's
            GOLDEN xN button (device matrix) and the Defense window (starter launcher card), then
            restore. The HUD GOLDEN REVENGE chip needs a REAL attacker (a second player), so it is
            not captured in a solo playtest (owner R72: no multiplayer playtests).
Usage:
    python3 scripts/studio-lock.py acquire <owner>
    STUDIO_LOCK_OWNER=<owner> python3 tools/qa/defense_towers.py [pad|r85]
    python3 scripts/studio-lock.py release <owner>
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

SERVER = (ROOT / "tools/qa/defense_towers_server.luau").read_text()
CLIENT = (ROOT / "tools/qa/defense_towers_client.luau").read_text()
SERVER_COMMANDS = {
    "prepare", "state", "focus", "walk", "cash", "area", "grant", "engage", "testnuke", "golden", "restore",
}
CLIENT_COMMANDS = {
    "diag", "close_all", "open", "state", "camera", "camera_reset", "act", "double", "hostile", "board",
    "pad_on", "pad_off", "reopen", "padinfo",
}
OUT = ROOT / "docs/verification/r80-defense"

# Built-in Studio device presets (custom resolutions alone fail: "no device is active").
# The desktop entry comes last and restoreAfter is off: a stale simulator state left by another
# session ("orientation can only be set on mobile devices") made the restore step fail the call.
DEVICES = [
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
    {"label": "desktop", "deviceId": "hd_1080"},
]


def server(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(SERVER, command, SERVER_COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": code}))


def client(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(CLIENT, command, CLIENT_COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def js(text: str) -> object:
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text


def capture(name: str) -> str:
    response = studio_mcp.rpc("tools/call", {"name": "capture_screenshot", "arguments": {"format": "jpeg", "quality": 88}})
    images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
    if not images:
        return "capture failed"
    path = OUT / name
    path.write_bytes(base64.b64decode(images[0]["data"], validate=True))
    return str(path.relative_to(ROOT))


def matrix(prefix: str) -> list[str]:
    """capture_device_matrix on the playtest client; one jpg per device."""
    response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
        "entries": DEVICES, "target": "client-1", "format": "jpeg", "quality": 88, "settleSeconds": 1.0,
        "restoreAfter": False,
    }})
    images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
    names = []
    for device, image in zip(DEVICES, images):
        name = f"{prefix}-{device['label']}.jpg"
        (OUT / name).write_bytes(base64.b64decode(image["data"], validate=True))
        names.append(str((OUT / name).relative_to(ROOT)))
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


def debug_pad() -> int:
    """`defense_towers.py pad`: prepare → slot 1's pad (diagnostics, shot, device matrix) → walk-on
    buy → the tower + its sign shot → restore."""
    world_tour.require_lock()
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"log": []}
    record["log"].append(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:200])
    try:
        record["ready"] = wait_ready(150)
        time.sleep(6)
        client("close_all")
        record["prepare"] = js(server("prepare"))
        time.sleep(2.0)
        client("close_all")
        record["focus"] = js(server("focus", [1]))
        time.sleep(2.5)
        record["padinfo"] = js(client("padinfo", [1]))
        record["shot"] = capture("r80-pad.jpg")
        record["padMatrix"] = matrix("r80-pad")
        record["walk"] = js(server("walk", [1]))
        time.sleep(3.0)
        record["focus2"] = js(server("focus", [1]))
        time.sleep(2.5)
        record["state"] = js(server("state"))
        record["towerShot"] = capture("r80-tower-l1.jpg")
    finally:
        try:
            record["restore"] = js(server("restore"))
        except Exception as error:
            record["restore"] = {"error": str(error)[:200]}
        world_tour.stop_playtest()
    print(json.dumps(record, indent=1, default=str))
    return 0


def r85_pass() -> int:
    """`defense_towers.py r85`: golden nuke picker button + Defense window matrices (owner R85)."""
    global OUT
    world_tour.require_lock()
    OUT = ROOT / "docs/verification/r85-attack"
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"log": []}
    record["log"].append(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:200])
    try:
        record["ready"] = wait_ready(150)
        time.sleep(6)
        client("close_all")
        record["prepare"] = js(server("prepare"))
        record["golden"] = js(server("golden", [2]))
        time.sleep(2.0)
        client("close_all")
        record["diag"] = js(client("diag"))
        record["picker"] = js(client("open", [2]))
        record["pickerShot"] = capture("r85-picker-golden.jpg")
        record["pickerMatrix"] = matrix("r85-picker-golden")
        client("close_all")
        time.sleep(1.0)
        record["defense"] = js(client("open", [1]))
        record["defenseMatrix"] = matrix("r85-defense")
        client("close_all")
    finally:
        try:
            record["restore"] = js(server("restore"))
        except Exception as error:
            record["restore"] = {"error": str(error)[:200]}
        world_tour.stop_playtest()
    print(json.dumps(record, indent=1, default=str))
    return 0


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "pad":
        return debug_pad()
    if len(sys.argv) > 1 and sys.argv[1] == "r85":
        return r85_pass()
    world_tour.require_lock()
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"log": []}
    log = record["log"].append
    log(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:200])
    try:
        record["ready"] = wait_ready(150)
        time.sleep(6)  # first profile push + boot windows
        client("close_all")
        record["prepare"] = js(server("prepare"))
        time.sleep(2.5)
        client("close_all")
        record["diagTargetable"] = js(client("diag"))

        # HUD route: the picker's DEFEND! and the Defense window, before any tower.
        record["picker"] = js(client("open", [2]))
        record["pickerMatrix"] = matrix("r80-attack-defend")
        client("close_all")
        time.sleep(1.0)
        record["defenseEmpty"] = js(client("open", [1]))
        record["defenseEmptyMatrix"] = matrix("r80-defense-empty")
        client("close_all")
        time.sleep(0.8)

        # The blue BUY pad of slot 1 (walk up to it).
        log(server("focus", [1]))
        time.sleep(2.0)
        record["padBoard"] = js(client("board", [1]))
        record["padShot"] = capture("r80-pad.jpg")
        record["padMatrix"] = matrix("r80-pad")
        # Walk ONTO the pad: the server Touched buy, then the fly-in.
        before = js(server("state"))
        log(server("walk", [1]))
        time.sleep(0.6)
        record["buildInShot"] = capture("r80-tower-buildin.jpg")
        time.sleep(1.5)
        log(server("focus", [1]))
        time.sleep(2.5)
        after = js(server("state"))
        record["walkBuy"] = {"before": before, "after": after}
        record["towerBoardL1"] = js(client("board", [1]))
        record["towerShotL1"] = capture("r80-tower-l1.jpg")

        # The real Interact path upgrades (provider → DefenseTower(1, 2)).
        js(server("cash", [1, 3, 1.6]))  # enough for L2 + L3, not L4
        time.sleep(1.0)
        record["act"] = js(client("act"))
        time.sleep(2.0)
        record["afterAct"] = js(server("state"))
        # A double intent for L3 buys exactly one level; junk changes nothing.
        log(client("double", [1, 3]))
        time.sleep(1.5)
        record["afterDouble"] = js(server("state"))
        log(client("hostile"))
        time.sleep(1.5)
        record["afterHostile"] = js(server("state"))
        time.sleep(2.0)
        record["towerBoardL3"] = js(client("board", [1]))
        record["towerShotL3"] = capture("r80-tower-l3.jpg")
        record["towerMatrix"] = matrix("r80-tower")

        # Every slot (area 9 opens slot 4) at L3 through the admin path: overview + engagement.
        record["area9"] = js(server("area", [9]))
        record["grant"] = js(server("grant", [3]))
        time.sleep(4.0)
        log(client("camera", [0, 520, 160]))
        time.sleep(2.5)
        record["overviewShot"] = capture("r80-towers-overview.jpg")
        record["engage"] = js(server("engage", [24]))
        log(client("camera", [1, 70, 90]))
        time.sleep(1.5)
        log(server("testnuke"))
        time.sleep(3.4 + 4.0)  # lead-in + into the flight: interceptors in the air
        record["interceptShot"] = capture("r80-intercept.jpg")
        time.sleep(4.0)
        log(client("camera_reset"))

        # Defense window with towers built + gamepad default selection.
        js(server("cash", [2, 4, 1.2]))
        time.sleep(1.0)
        record["defenseBuilt"] = js(client("open", [1]))
        record["defenseBuiltMatrix"] = matrix("r80-defense-built")
        record["defenseShot"] = capture("r80-defense-built.jpg")
        log(client("pad_on"))
        record["gamepadSelection"] = js(client("reopen"))
        log(client("pad_off"))
        client("close_all")
        record["diagEnd"] = js(client("diag"))
    finally:
        try:
            record["restore"] = js(server("restore"))
        except Exception as error:  # report, still stop our playtest
            record["restore"] = {"error": str(error)[:200]}
        world_tour.stop_playtest()
    print(json.dumps(record, indent=1, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
