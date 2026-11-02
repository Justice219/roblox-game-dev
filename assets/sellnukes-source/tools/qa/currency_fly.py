#!/usr/bin/env python3
"""
currency_fly.py — Studio QA for the money-flies-into-the-counter FX (owner R46,
src/client/UI/Hud/CurrencyFly.luau). One solo playtest in the open place (hold the Studio lock).

Steps (prints one JSON record; screenshots under docs/verification/ui/currency-fly/):
    1. start a solo Play playtest, wait for the client's CurrencyFly overlay + HUD attach
    2. server: build the first producer (TycoonService.grantPads a1_workbench, no fly-in)
    3. client: stand in front of it and CLICK it like a player -> the payout's IncomePop must
       spawn a "click" burst
    4. client: claim today's daily reward (cash) -> a centre "reward" burst
    5. server: grant cash with NO reward toast -> must NOT spawn a reward burst (attribution)
    6. client: keep bursts flying, capture desktop / tablet / phone (capture_device_matrix)
    7. wait for the storm to end -> the PreRender connection must be gone (idle = no per-frame work)
    8. stop the playtest

Usage:
    python3 scripts/studio-lock.py acquire H1
    STUDIO_LOCK_OWNER=H1 python3 tools/qa/currency_fly.py
    python3 scripts/studio-lock.py release H1
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

CLIENT = (ROOT / "tools/qa/currency_fly_client.luau").read_text()
COMMANDS = {"state", "approach", "click", "reward", "storm", "diag", "modal_open", "modal_close"}
OUT = ROOT / "docs/verification/ui/currency-fly"
# Built-in Studio device presets (custom resolutions alone fail: "no device is active").
DEVICES = [
    {"label": "desktop", "deviceId": "hd_1080"},
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
]

# Server-side helpers (fixed code: no free-form input reaches Luau).
SERVER_BUILD = """
local Server = game:GetService("ServerScriptService").Server
local TycoonService = require(Server.Tycoon.TycoonService)
local player = game:GetService("Players"):GetPlayers()[1]
if player == nil then return "no player" end
return tostring(TycoonService.grantPads(player, { "a1_workbench" }, false))
"""
SERVER_DIAG = """
local Server = game:GetService("ServerScriptService").Server
local PlayerDataService = require(Server.Services.PlayerDataService)
local player = game:GetService("Players"):GetPlayers()[1]
if player == nil then return "no player" end
local session = PlayerDataService.getSession(player)
return tostring(session and session.status) .. " canMutate=" .. tostring(PlayerDataService.canMutate(player))
"""
SERVER_SILENT_CASH = """
local Server = game:GetService("ServerScriptService").Server
local PlayerDataService = require(Server.Services.PlayerDataService)
local player = game:GetService("Players"):GetPlayers()[1]
local session = player and PlayerDataService.getSession(player)
if session == nil then return "no session" end
return tostring(PlayerDataService.grantCash(player, session.profile.cash * 0.25 + 1e6, "qa"))
"""
# The live reward path (RewardGrant.grant + notify "reward"), sized to show on a late-game balance.
SERVER_REWARD = """
local Server = game:GetService("ServerScriptService").Server
local PlayerDataService = require(Server.Services.PlayerDataService)
local player = game:GetService("Players"):GetPlayers()[1]
local session = player and PlayerDataService.getSession(player)
if session == nil then return "no session" end
local added = PlayerDataService.grantCash(player, session.profile.cash * 0.25 + 1e6, "qa")
PlayerDataService.notify(player, "QA reward: cash!", "reward")
return tostring(added)
"""


def client(command: str) -> str:
    code = world_tour.render(CLIENT, command, COMMANDS, [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def server(code: str) -> str:
    return world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": code}))


def state() -> dict:
    return json.loads(client("state"))


def bursts(source: str) -> int:
    counts = state().get("bursts")
    # An empty Luau table encodes as [] (JSONEncode): no bursts yet.
    return int(counts.get(source, 0)) if isinstance(counts, dict) else 0


def matrix(prefix: str) -> list[str]:
    """capture_device_matrix on the playtest client; one jpg per device."""
    response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
        "entries": DEVICES, "target": "client-1", "format": "jpeg", "quality": 88, "settleSeconds": 0.6,
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
    """Until the loading screen handed off and the HUD is shown (LoadingGate / PlotReveal hide it,
    and nothing may fly while the HUD is hidden)."""
    deadline = time.time() + seconds
    last: dict = {}
    while time.time() < deadline:
        try:
            last = json.loads(client("diag"))
            if last.get("loadingDone") and last.get("hud") and state().get("ready"):
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
        time.sleep(4)  # plot assignment + first profile push
        log("diag " + client("diag"))
        log("server " + server(SERVER_DIAG))
        log("build " + server(SERVER_BUILD))
        time.sleep(3)
        log("close windows " + client("modal_close"))  # WelcomeBack close = the offline claim
        time.sleep(2)  # the HUD fades back in after the window
        log("approach " + client("approach"))
        time.sleep(1.5)
        before = bursts("click") + bursts("tick")
        client("click")
        time.sleep(4)  # real IncomePop payouts of on-screen producers
        record["click"] = {"before": before, "after": bursts("click") + bursts("tick")}
        log("diag after click " + client("diag"))
        before = bursts("reward")
        log("reward " + server(SERVER_REWARD))
        time.sleep(3)
        record["reward"] = {"before": before, "after": bursts("reward")}
        log("diag after reward " + client("diag"))
        before = bursts("reward")
        log("silent cash " + server(SERVER_SILENT_CASH))
        time.sleep(3)
        record["silentCash"] = {"before": before, "after": bursts("reward")}
        log("storm " + client("storm"))
        time.sleep(1.2)
        record["flying"] = state()
        record["screens"] = matrix("flight")
        time.sleep(20)
        # A window covers the world: producer payouts stop flying, so the loop must go idle.
        log("modal " + client("modal_open"))
        time.sleep(3)
        record["idle"] = state()
        log("modal closed " + client("modal_close"))
    finally:
        log(studio_mcp.call_tool("solo_playtest", {"action": "stop"})[:200])
    checks = {
        "producer payout bursts": record["click"]["after"] > record["click"]["before"],
        "reward burst": record["reward"]["after"] > record["reward"]["before"],
        "silent cash does not fly": record["silentCash"]["after"] == record["silentCash"]["before"],
        "sprites in flight": record["flying"].get("live", 0) > 0,
        "pool capped": record["flying"].get("capacity", 0) <= 40 and record["flying"].get("live", 0) <= 40,
        "idle disconnects": not record["idle"].get("running", True),
    }
    record["checks"] = checks
    print(json.dumps(record, indent=1))
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
