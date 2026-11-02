#!/usr/bin/env python3
"""
player_titles.py — Studio check of Player Titles (owner R73: "give me a name tag whenever I'm in
the game so people know I'm the developer"; R74: DEVELOPER / FIRST PLAYER / EARLY PLAYER). ONE solo
playtest (multiplayer playtests are banned, owner R72); the Studio account is the owner
(1586034782), so the local player wears DEVELOPER.

Steps (JSON + captures under docs/verification/player-titles/):
    1. start a solo Play playtest; wait for the loading hand-off, the plot reveal and Title
    2. own view: NO tag over your own head (lead review: it blocked the view; matrix)
    3. second-player view on two test rigs (DEVELOPER + FIRST PLAYER over Roblox's own names) at
       20 and 45 studs (desktop + phone / tablet / console)
    4. chat through the real TextChatService: the [DEV] tag (capture)
    5. admin panel Server tab: MY TITLE TAG chip; Players tab: Give / Remove Title (captures)
    6. the real admin path on yourself: TitleGrant earlyPlayer -> DEVELOPER still the title
       (priority) and the profile holds earlyPlayer; TitleRevoke -> removed
    7. the real SetSetting intent: hide -> TitleHidden, show -> back
    8. stop OUR playtest

Usage:
    python3 scripts/studio-lock.py acquire W5b-ui
    STUDIO_LOCK_OWNER=W5b-ui python3 tools/qa/player_titles.py
    python3 scripts/studio-lock.py release W5b-ui
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

os.environ.setdefault("STUDIO_LOCK_OWNER", "W5b-ui")

import studio_mcp  # noqa: E402  (localhost-only MCP transport)
import world_tour  # noqa: E402  (require_lock, render, result, capture, stop_playtest)

CLIENT = (ROOT / "tools/qa/player_titles_client.luau").read_text()
COMMANDS = {"state", "camera", "chat", "toggle", "panel", "grant", "modals", "reset", "dummies"}
OUT = ROOT / "docs/verification/player-titles"
# Server probe: the local player's saved granted titles (fixed code, no input).
SERVER_TITLES = """
local Server = game:GetService("ServerScriptService").Server
local PlayerDataService = require(Server.Services.PlayerDataService)
local HttpService = game:GetService("HttpService")
local player = game:GetService("Players"):GetPlayers()[1]
local profile = player and PlayerDataService.getProfile(player)
local keys = {}
if profile ~= nil and type(profile.titles) == "table" then
    for key in profile.titles do table.insert(keys, key) end
end
return HttpService:JSONEncode({ granted = keys, title = player and player:GetAttribute("Title") })
"""
DEVICES = [
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
]


def client(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(CLIENT, command, COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def state() -> dict:
    return json.loads(client("state"))


def shot(name: str, names: list[str]) -> None:
    world_tour.capture(OUT / f"{name}.jpg")
    names.append(f"{name}.jpg")
    print(f"[titles] {name}.jpg", flush=True)


def matrix(name: str, names: list[str]) -> None:
    response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
        "entries": DEVICES, "target": "client-1", "format": "jpeg", "quality": 86, "settleSeconds": 1.2,
        "restoreAfter": True,
    }})
    images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
    for device, image in zip(DEVICES, images):
        file = f"{name}-{device['label']}.jpg"
        (OUT / file).write_bytes(base64.b64decode(image["data"], validate=True))
        names.append(file)
    print(f"[titles] {name} matrix ({len(images)})", flush=True)


def wait_state(predicate, seconds: float) -> dict:
    deadline = time.time() + seconds
    last: dict = {}
    while time.time() < deadline:
        try:
            last = state()
            if predicate(last):
                return last
        except Exception as error:  # client VM not up yet
            last = {"error": str(error)[:200]}
        time.sleep(1.5)
    return last


def server_titles() -> dict:
    return json.loads(world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": SERVER_TITLES})))


def run(record: dict, names: list[str]) -> None:
    record["ready"] = wait_state(
        lambda s: s.get("title") == "developer" and s.get("loadingDone") and s.get("revealed"), 200)
    time.sleep(5)  # the plot-reveal fly-over hands the camera back
    client("modals")
    client("reset")
    time.sleep(1.5)
    # 1. Own view: the holder never sees their own tag (lead review: it blocked the view).
    record["own"] = state()
    shot("01-own-view", names)
    matrix("01-own-view", names)
    # 2. Second-player view on test rigs (a solo playtest has no second player).
    record["dummies20"] = client("dummies", [20])
    time.sleep(2)
    shot("02-other-view-20studs", names)
    matrix("02-other-view-20studs", names)
    record["dummies45"] = client("dummies", [45])
    time.sleep(2)
    shot("03-other-view-45studs", names)
    matrix("03-other-view-45studs", names)
    client("dummies", [0])
    client("reset")
    time.sleep(1)
    # 3. Chat tag.
    record["chat"] = client("chat")
    time.sleep(2.5)
    shot("04-chat-dev-prefix", names)
    # 4. Admin panel: the holder's chip + the Players tab commands.
    record["panelServer"] = client("panel", [1])
    time.sleep(2)
    shot("05-admin-title-chip", names)
    record["panelPlayers"] = client("panel", [2])
    time.sleep(2)
    shot("06-admin-players-tab", names)
    client("panel", [0])
    time.sleep(1)
    # 5. The admin path on yourself: grant EARLY PLAYER (DEVELOPER keeps showing: priority).
    record["grant"] = client("grant", [1])
    time.sleep(2.5)
    record["afterGrant"] = {"server": server_titles(), "client": state()}
    record["revoke"] = client("grant", [0])
    time.sleep(2.5)
    record["afterRevoke"] = {"server": server_titles(), "client": state()}
    # 6. The holder's own ON / OFF (the admin chip's intent) hides it for everyone.
    record["hide"] = client("toggle", [0])
    record["hidden"] = wait_state(lambda s: s.get("hidden") is True, 10)
    record["show"] = client("toggle", [1])
    record["shownAgain"] = wait_state(lambda s: s.get("hidden") is False, 10)
    client("reset")


def main() -> int:
    world_tour.require_lock()
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {}
    names: list[str] = []
    status = studio_mcp.call_tool("solo_playtest", {"action": "status"})
    if json.loads(status).get("running"):
        print(json.dumps({"aborted": "a playtest is already running", "status": status[:200]}))
        return 2
    print(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:160], flush=True)
    try:
        run(record, names)
    except Exception as error:  # report, then always stop our playtest
        record["error"] = str(error)[:600]
    finally:
        world_tour.stop_playtest()
    record["captures"] = names
    (OUT / "player_titles.json").write_text(json.dumps(record, indent=1))
    print(json.dumps(record)[:4000])
    return 0 if "error" not in record else 1


if __name__ == "__main__":
    sys.exit(main())
