#!/usr/bin/env python3
"""
whats_new.py — Studio QA for WHAT'S NEW (owner R58: the RoBeasts changelog, auto-shown ONLY to
returning players, bottom-right HUD chip). One solo playtest in the open place (hold the lock).

Steps (prints one JSON record; screenshots under docs/verification/ui/whats-new/):
    1. start a solo Play playtest, wait for the loading screen hand-off + the HUD + the profile
    2. JOIN: whatever the Studio profile is (memory "new" or a saved "current" one), an up-to-date
       or brand-new player must NOT get the pop-up (watched ~12 s)
    3. chip: present bottom-right, inside the viewport, NEW badge off; device matrix of the HUD
       (desktop / phone / tablet / console)
    4. RETURNING PLAYER: the real admin command WhatsNewReset (AdminService.dispatchAsync, seen up to
       the 0.2.0 note) → the client replays the returning-player flow: badge on, then the panel
       auto-opens at the next calm moment (windows closed first); screenshot + device matrix
    5. close it like a player → the server's seen note moves to the newest, badge off, analytics
       counted (shown:auto, closed, seen)
    6. WhatsNewPreview (admin) → the panel opens in preview mode; nothing is marked / counted
    7. NEW PLAYER: the admin NewPlayerMode command (a fresh sandbox profile, migration "new",
       tutorial step 1) → the server marks the newest note seen on load; no pop-up (~15 s), no
       badge; then ExitNewPlayerMode
    8. stop the playtest

Usage:
    python3 scripts/studio-lock.py acquire U1-changelog
    STUDIO_LOCK_OWNER=U1-changelog python3 tools/qa/whats_new.py
    python3 scripts/studio-lock.py release U1-changelog
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

CLIENT = (ROOT / "tools/qa/whats_new_client.luau").read_text()
COMMANDS = {"diag", "close_modals", "close_panel", "open_menu"}
OUT = ROOT / "docs/verification/ui/whats-new"
# Built-in Studio device presets (custom resolutions alone fail: "no device is active").
DEVICES = [
    {"label": "desktop", "deviceId": "hd_1080"},
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
]
OLDER_NOTE = "2026-10-30-nuke-empire"

# Server-side helpers (fixed code: no free-form input reaches Luau).
SERVER_STATE = """
local Server = game:GetService("ServerScriptService").Server
local PlayerDataService = require(Server.Services.PlayerDataService)
local ChangeNotesService = require(Server.Services.ChangeNotesService)
local HttpService = game:GetService("HttpService")
local player = game:GetService("Players"):GetPlayers()[1]
local session = player and PlayerDataService.getSession(player)
if session == nil then return "{}" end
return HttpService:JSONEncode({
    migration = session.migration, status = session.status,
    seen = session.profile.notes.seen, at = session.profile.notes.at,
    tutorialStep = session.profile.tycoon.tutorialStep,
    reports = ChangeNotesService.testState(player).reports,
    isAdmin = player:GetAttribute("IsAdmin") == true,
})
"""
SERVER_RESET = """
local Server = game:GetService("ServerScriptService").Server
local AdminService = require(Server.Services.AdminService)
local player = game:GetService("Players"):GetPlayers()[1]
if player == nil then return "no player" end
local result = AdminService.dispatchAsync({ userId = player.UserId, name = player.Name, player = player },
    "WhatsNewReset", { userId = player.UserId, seenUpTo = "__NOTE__" })
return tostring(result.ok) .. " " .. tostring(result.message)
"""
SERVER_NPM = """
local Server = game:GetService("ServerScriptService").Server
local AdminService = require(Server.Services.AdminService)
local player = game:GetService("Players"):GetPlayers()[1]
if player == nil then return "no player" end
local result = AdminService.dispatchAsync({ userId = player.UserId, name = player.Name, player = player },
    "__COMMAND__", {})
return tostring(result.ok) .. " " .. tostring(result.message)
"""
SERVER_PREVIEW = """
local Server = game:GetService("ServerScriptService").Server
local AdminService = require(Server.Services.AdminService)
local player = game:GetService("Players"):GetPlayers()[1]
if player == nil then return "no player" end
local result = AdminService.dispatchAsync({ userId = player.UserId, name = player.Name, player = player },
    "WhatsNewPreview", { userId = player.UserId })
return tostring(result.ok) .. " " .. tostring(result.message)
"""


def client(command: str) -> str:
    code = world_tour.render(CLIENT, command, COMMANDS, [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def server(code: str) -> str:
    return world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": code}))


def diag() -> dict:
    return json.loads(client("diag"))


def server_state() -> dict:
    return json.loads(server(SERVER_STATE))


def matrix(prefix: str) -> list[str]:
    """capture_device_matrix on the playtest client; one jpg per device."""
    response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
        "entries": DEVICES, "target": "client-1", "format": "jpeg", "quality": 88, "settleSeconds": 1.0,
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


def wait_for(predicate, seconds: float, step: float = 1.0) -> dict:
    """Polls diag() until predicate(diag) or the deadline; returns the last diag."""
    deadline = time.time() + seconds
    last: dict = {}
    while time.time() < deadline:
        try:
            last = diag()
            if predicate(last):
                return last
        except Exception as error:  # client VM not up yet
            last = {"error": str(error)[:200]}
        time.sleep(step)
    return last


def main() -> int:
    world_tour.require_lock()
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"log": []}
    log = record["log"].append
    status = studio_mcp.call_tool("solo_playtest", {"action": "status"})
    log("status before " + status[:200])
    if json.loads(status).get("running"):
        # Someone (maybe the owner) is playtesting: never start / stop over their session.
        print(json.dumps({"aborted": "a playtest is already running", "status": status[:200]}))
        return 2
    log(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:200])
    try:
        ready = wait_for(lambda d: d.get("loadingDone") and d.get("hud") and d.get("notes", {}).get("profileReady"), 150, 2)
        record["ready"] = ready
        # 2. New player: watch for an unwanted pop-up while windows come and go.
        time.sleep(4)
        record["newServer"] = server_state()
        watch_until = time.time() + 12
        popped = False
        while time.time() < watch_until:
            d = diag()
            popped = popped or bool(d.get("open")) or d.get("notes", {}).get("autoState") in ("waiting", "open")
            time.sleep(1.5)
        record["newPlayerPopped"] = popped
        log("close windows " + client("close_modals"))
        time.sleep(2.5)
        record["newClient"] = diag()
        world_tour.capture(OUT / "new-player-hud.jpg")
        record["hudScreens"] = matrix("hud-chip")
        # 4. Returning player via the real admin command.
        log("reset " + server(SERVER_RESET.replace("__NOTE__", OLDER_NOTE)))
        time.sleep(1.5)
        record["afterReset"] = diag()
        log("close windows " + client("close_modals"))
        opened = wait_for(lambda d: bool(d.get("open")), 30, 1)
        record["autoOpen"] = opened
        time.sleep(1.2)
        world_tour.capture(OUT / "returning-auto-open.jpg")
        record["panelScreens"] = matrix("panel")
        record["serverWhileOpen"] = server_state()
        # 5. Close like a player.
        log("close panel " + client("close_panel"))
        time.sleep(2.5)
        record["afterClose"] = diag()
        record["serverAfterClose"] = server_state()
        # 6. Admin preview.
        log("preview " + server(SERVER_PREVIEW))
        time.sleep(2)
        record["preview"] = diag()
        world_tour.capture(OUT / "admin-preview.jpg")
        log("close preview " + client("close_panel"))
        time.sleep(1.5)
        record["serverAfterPreview"] = server_state()
        # 7. A brand-new player (New Player Mode sandbox).
        log("npm " + server(SERVER_NPM.replace("__COMMAND__", "NewPlayerMode")))
        time.sleep(3)
        record["npmServer"] = server_state()
        npm_popped, npm_last = False, {}
        npm_until = time.time() + 15
        while time.time() < npm_until:
            npm_last = diag()
            npm_popped = npm_popped or bool(npm_last.get("open")) or npm_last.get("notes", {}).get("autoState") in ("waiting", "open")
            time.sleep(1.5)
        record["npmPopped"] = npm_popped
        record["npmClient"] = npm_last
        world_tour.capture(OUT / "new-player-npm.jpg")
        log("npm exit " + server(SERVER_NPM.replace("__COMMAND__", "ExitNewPlayerMode")))
    finally:
        world_tour.stop_playtest()
    new_server = record.get("newServer", {})
    after = record.get("serverAfterClose", {})
    reports = after.get("reports", {}) if isinstance(after.get("reports"), dict) else {}
    newest = after.get("seen")
    checks = {
        "join: up to date or new -> no pop-up": new_server.get("seen", "") != "" and not record.get("newPlayerPopped"),
        "new player (NPM): migration new, newest marked seen on load": record.get("npmServer", {}).get("migration") == "new"
        and record.get("npmServer", {}).get("seen") == newest,
        "new player (NPM): no pop-up, no badge": not record.get("npmPopped")
        and not (record.get("npmClient", {}).get("chip") or {}).get("badge"),
        "chip visible bottom-right": bool((record.get("newClient", {}).get("chip") or {}).get("visible")),
        "gamepad: last offer Down = chip": bool((record.get("newClient", {}).get("chip") or {}).get("navUpDownIsChip")),
        "badge on after reset": bool((record.get("afterReset", {}).get("chip") or {}).get("badge")),
        "returning: auto-opened": bool(record.get("autoOpen", {}).get("open"))
        and record.get("autoOpen", {}).get("notes", {}).get("autoState") == "open",
        "closing marks newest seen": bool(newest) and newest != OLDER_NOTE,
        "badge off after close": not (record.get("afterClose", {}).get("chip") or {}).get("badge"),
        "analytics shown:auto + closed": any(k.startswith("notes:shown:") and k.endswith(":auto") for k in reports)
        and any(k.startswith("notes:closed:") for k in reports),
        "preview opened": bool(record.get("preview", {}).get("open")),
        "preview counts nothing": record.get("serverAfterPreview", {}).get("reports") == reports,
    }
    record["checks"] = checks
    print(json.dumps(record, indent=1))
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
