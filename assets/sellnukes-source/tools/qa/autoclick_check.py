#!/usr/bin/env python3
"""
autoclick_check.py — Studio QA of E1's Settings "Auto Clicker" row (owner R64; lead request
2026-10-31, W12). ONE solo playtest in the open place on the NORMAL profile (the owner's account
owns the AutoClicker pass); hold the Studio lock first (owner R33 + the lock rule). No
multiplayer (owner order 2026-10-31).

Steps (captures under docs/verification/world2/autoclick-*):
    1. Settings open: the Auto Clicker row shown (pass owners only) + device matrix (phone, tablet,
       console)
    2. A FRESH Dino run (admin WorldResetRun) + its first pad (the Stone Bench: a producer with NO
       manager), so only the pass's auto clicker can start its cycles
    3. Auto Clicker ON (SetSetting intent): the producer's CycleStart keeps moving with no click
    4. Auto Clicker OFF: CycleStart stops moving (it needs clicks); then ON again (restored)
    5. restore the Dino snapshot (world2_check `restore`), stop OUR playtest

Every server / client step uses the fixed Luau below or tools/qa/world2_check*'s whitelisted
commands (read-only reuse); the only inputs are whitelisted literals.

Usage:
    python3 scripts/studio-lock.py acquire W12
    STUDIO_LOCK_OWNER=W12 python3 tools/qa/autoclick_check.py
    python3 scripts/studio-lock.py release W12
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tools/qa"))

import studio_mcp  # noqa: E402  (localhost-only MCP transport)
import world_tour  # noqa: E402  (require_lock, result, capture, sheet, stop_playtest)
import world2_check as w2  # noqa: E402  (server / client / admin / matrix / wait_client helpers)

OUT = ROOT / "docs/verification/world2"

# Client: open Settings, or send the autoClicker toggle intent (VALUE replaced by true / false only).
CLIENT_OPEN_SETTINGS = """
local Players = game:GetService("Players")
local client = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local ScreenManager = (require :: any)(client.UI.ScreenManager)
ScreenManager.open("Settings", { source = "other" })
return "settings open"
"""
CLIENT_SET = """
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = (require :: any)(ReplicatedStorage.Shared.Net.Remotes)
Remotes.event("SetSetting"):FireServer("autoClicker", __VALUE__)
return "sent"
"""
# Server: the first Dino producer's cycle attributes sampled 6 x 1 s (no click is ever sent).
SERVER_SAMPLE = """
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Server = ServerScriptService:WaitForChild("Server")
local WorldsConfig = (require :: any)(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)
local PlotService = (require :: any)(Server.Tycoon.PlotService)
local PlayerDataService = (require :: any)(Server.Services.PlayerDataService)
local player = Players:GetPlayers()[1]
local producer = WorldsConfig.get("dino").economy.Producers[1].id
local plotIndex = PlotService.getPlotIndex(player)
local worlds = workspace:FindFirstChild("Worlds")
local dino = worlds and worlds:FindFirstChild("dino")
local plots = dino and dino:FindFirstChild("Plots")
local plot = plots and plotIndex and plots:FindFirstChild("Plot" .. plotIndex)
local anchor = nil
if plot then
	for _, item in plot:GetDescendants() do
		if item:GetAttribute("ProducerId") == producer and item:GetAttribute("CycleTime") ~= nil then
			anchor = item
			break
		end
	end
end
local profile = PlayerDataService.getProfile(player)
local samples = {}
for _ = 1, 6 do
	table.insert(samples, {
		cycleStart = anchor and anchor:GetAttribute("CycleStart") or -1,
		automated = anchor and anchor:GetAttribute("Automated") or false,
		setting = profile and profile.settings and profile.settings.autoClicker,
		passOwned = profile and profile.passes and profile.passes.AutoClicker == true,
	})
	task.wait(1)
end
return HttpService:JSONEncode({ producer = producer, found = anchor ~= nil, samples = samples })
"""


def client_raw(code: str) -> str:
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def server_raw(code: str) -> str:
    return world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": code}))


def set_auto(on: bool) -> str:
    return client_raw(CLIENT_SET.replace("__VALUE__", "true" if on else "false"))


def moving(sample: dict) -> bool:
    """True when the producer started at least one new cycle during the 6 s window."""
    starts = {row.get("cycleStart") for row in sample.get("samples", [])}
    return len(starts) > 1


def main() -> int:
    world_tour.require_lock()
    w2.WORLD = "dino"
    w2.OUT = OUT
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"started": time.strftime("%Y-%m-%d %H:%M:%S")}
    names: list[str] = []
    w2.start_solo()
    try:
        record["ready"] = w2.wait_client(w2.ready, 150)
        time.sleep(4)
        record["prepare"] = json.loads(w2.server("prepare"))
        w2.client("modal_close")
        # 1. The Settings row on devices.
        client_raw(CLIENT_OPEN_SETTINGS)
        time.sleep(1.5)
        w2.shot("autoclick-01-settings", names)
        w2.matrix("autoclick-01-settings", names)
        w2.client("modal_close")
        # 2. A fresh Dino run with only the first (unmanaged) producer.
        record["unlock"] = w2.admin(w2.UNLOCK)
        record["resetRun"] = w2.admin(w2.RESET_RUN)
        w2.client("travel", [1])
        record["arrive"] = w2.wait_client(w2.in_world("dino"), 20)
        record["sendPlot"] = w2.admin(w2.SEND_PLOT)
        time.sleep(5)
        record["buy"] = json.loads(w2.server("buy_next", [0]))
        time.sleep(3)
        # 3-4. ON → cycles run by themselves; OFF → they stop; ON again.
        record["setOn"] = set_auto(True)
        time.sleep(2)
        record["on"] = json.loads(server_raw(SERVER_SAMPLE))
        record["setOff"] = set_auto(False)
        time.sleep(4)  # let a running cycle finish
        record["off"] = json.loads(server_raw(SERVER_SAMPLE))
        record["setOnAgain"] = set_auto(True)
        time.sleep(2)
        record["onAgain"] = json.loads(server_raw(SERVER_SAMPLE))
        record["checks"] = {
            "passOwned": bool(record["on"].get("samples", [{}])[0].get("passOwned")),
            "producerFound": bool(record["on"].get("found")),
            "onRunsWithoutClick": moving(record["on"]),
            "offNeedsClicks": not moving(record["off"]),
            "onAgainRuns": moving(record["onAgain"]),
        }
        w2.client("camera_plot", [1])
        time.sleep(1.5)
        w2.shot("autoclick-02-dino-bench", names)
        w2.client("camera_reset")
    finally:
        try:
            set_auto(True)  # never leave the owner's toggle off
            record["restore"] = w2.server("restore")
        except Exception as error:  # restore must not hide the original failure
            record["restoreError"] = str(error)[:300]
        world_tour.stop_playtest()
        (OUT / "autoclick.json").write_text(json.dumps(record, indent=2) + "\n")
        if names:
            world_tour.sheet(OUT, names, OUT / "autoclick-sheet.jpg", cols=4, width=480)
    print(json.dumps(record.get("checks"), indent=1))
    return 0 if all((record.get("checks") or {}).values()) else 1


if __name__ == "__main__":
    sys.exit(main())
