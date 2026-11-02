#!/usr/bin/env python3
"""
ftue_check.py — owner R78 §6 Studio verification of the FIRST MINUTE (console / phone / tablet).

One solo playtest in the open MCP-connected place (CLAUDE.md rules 12 + R72; hold the lock):
    1. join as the test account (a RETURNING player: offline earnings → Welcome Back). Polls the
       client every ~1.5 s and records the join order: loading screen → plot reveal → Welcome
       Back (JoinFlow: Welcome Back must NOT open before the reveal finished).
    2. closes the windows, enters admin New Player Mode (sandbox profile, nothing saved): a new
       plot is claimed and the reveal plays; a Welcome Back payload is fired DURING the reveal
       (the real OfflineEarnings remote): JoinFlow must open it only after the reveal and before
       the tutorial COACH CARD (non-modal) + the step-1 objective chip. Proves: no window open
       with the coach, gameplay input enabled, no gamepad selection, JoinFlow guiding.
    3. capture_device_matrix: console in forced Gamepad mode, phone + tablet in forced Touch mode
       (the chip + coach tile 2 name the right control: "Press RT" / "Tap TAP!").
    4. holds W for 1.6 s through simulate_keyboard_input (real input, the default controls walk
       the character) and reads FtueTracker.hasMoved() + the coach card closing; then onto the pad
       (server PivotTo) → step 2; captures step 2 in Gamepad mode.
    5. stops ONLY its own playtest.

    python3 scripts/studio-lock.py acquire C-ftue
    STUDIO_LOCK_OWNER=C-ftue python3 tools/qa/ftue_check.py
    python3 scripts/studio-lock.py release C-ftue
Output: docs/verification/r78-ftue/after-*.jpg + ftue.json
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
import world_tour  # noqa: E402  (require_lock, result, stop_playtest)

OUT = ROOT / "docs/verification/r78-ftue"
DEVICES = [
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
]

# Read-only client probe (fixed code, no free-form input).
PROBE = r"""
local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local Http = game:GetService("HttpService")
local p = Players.LocalPlayer
local c = p.PlayerScripts.Client
local SM = require(c.UI.ScreenManager)
local IC = require(c.Controllers.InputController)
local T = require(c.Tycoon.Tutorial)
local PR = require(c.Tycoon.PlotReveal)
local JF = require(c.Platform.JoinFlow)
local FT = require(c.Tycoon.FtueTracker)
local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
local js = JF.debugState()
return Http:JSONEncode({
	t = math.floor(time() * 10) / 10,
	loading = p:GetAttribute("LoadingScreenActive"),
	loadingDone = p:GetAttribute("LoadingDone"),
	boot = p:GetAttribute("BootSeconds"),
	plot = p:GetAttribute("PlotIndex"),
	revealed = p:GetAttribute("PlotRevealed"),
	reveal = PR.isPlaying(),
	top = SM.topModalName(),
	coach = SM.isOpen("TycoonTutorial"),
	gameplay = IC.isGameplayEnabled(),
	mode = IC.mode,
	selected = GuiService.SelectedObject and GuiService.SelectedObject:GetFullName() or nil,
	step = T.step(),
	hint = T.hintText(),
	queue = table.concat(js.pending, ","),
	blocker = js.blocker,
	guiding = js.guiding,
	moved = FT.hasMoved(),
	pos = root and string.format("%.0f,%.0f", root.Position.X, root.Position.Z) or nil,
})
"""

SET_MODE = r"""
local p = game:GetService("Players").LocalPlayer
require(p.PlayerScripts.Client.Controllers.InputController).setForcedMode(__MODE__)
return "ok"
"""

CLOSE_ALL = r"""
require(game:GetService("Players").LocalPlayer.PlayerScripts.Client.UI.ScreenManager).closeAllModals()
return "ok"
"""

# A Welcome Back payload (server → client, the real OfflineEarnings remote) while the reveal plays:
# JoinFlow must hold it until the reveal ended and open it BEFORE the tutorial coach card.
WELCOME_BACK = r"""
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Net.Remotes)
local p = game:GetService("Players"):GetPlayers()[1]
Remotes.event("OfflineEarnings"):FireClient(p, { amount = 1234, seconds = 3600 })
return "fired"
"""

ENTER_NPM = r"""
local PDS = require(game:GetService("ServerScriptService").Server.Services.PlayerDataService)
local p = game:GetService("Players"):GetPlayers()[1]
local ok, msg = PDS.enterNewPlayerModeAsync(p)
return tostring(ok) .. " " .. tostring(msg)
"""

# Distance (horizontal studs) from the character to its own Workbench pad, for the walk report.
PAD_DISTANCE = r"""
local p = game:GetService("Players").LocalPlayer
local TW = require(p.PlayerScripts.Client.Tycoon.TycoonWorld)
local pad = TW.myPad("a1_workbench")
local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
if pad == nil or root == nil then return "-1" end
return tostring(math.floor(((pad.Position - root.Position) * Vector3.new(1, 0, 1)).Magnitude * 10) / 10)
"""

ONTO_PAD = r"""
local p = game:GetService("Players"):GetPlayers()[1]
local index = p:GetAttribute("PlotIndex")
local pad = workspace.Plots[`Plot{index}`].Area01.Pads.a1_workbench.Trigger
p.Character:PivotTo(CFrame.new(pad.Position + Vector3.new(0, 3, 0)))
return "on pad"
"""


def client(code: str) -> str:
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def server(code: str) -> str:
    return world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": code}))


def probe() -> dict:
    try:
        return json.loads(client(PROBE))
    except Exception as error:  # client VM not up yet
        return {"error": str(error)[:160]}


def matrix(prefix: str, devices: list[dict] | None = None) -> list[str]:
    chosen = devices or DEVICES
    response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
        "entries": chosen, "target": "client-1", "format": "jpeg", "quality": 85, "settleSeconds": 1.0,
        "restoreAfter": True,
    }})
    images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
    names = []
    for device, image in zip(chosen, images):
        name = f"{prefix}-{device['label']}.jpg"
        (OUT / name).write_bytes(base64.b64decode(image["data"], validate=True))
        names.append(name)
    return names or ["matrix failed: " + json.dumps(response)[:200]]


def main() -> int:
    world_tour.require_lock()
    status = json.loads(studio_mcp.call_tool("solo_playtest", {"action": "status"}))
    if status.get("running"):
        raise SystemExit("a playtest is already running; not touching it")
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"join": [], "npm": [], "captures": []}
    print(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:120])
    try:
        run(record)
    except Exception as error:  # keep what was recorded; report the failing step
        record["error"] = str(error)[:400]
    finally:
        world_tour.stop_playtest()
    (OUT / "ftue.json").write_text(json.dumps(record, indent=1))
    keys = ("joinOrderOk", "npmOrderOk", "welcomeState", "step1Gamepad", "step1Touch", "padBefore", "padAfter",
            "afterWalk", "step2", "error")
    print(json.dumps({k: record[k] for k in keys if k in record}, indent=1))
    return 0


def run(record: dict) -> None:
    """The scripted first minute (see the module docstring); fills `record`."""
    # 1. Returning-player join order.
    deadline = time.time() + 150
    settled_at = None
    while time.time() < deadline:
        state = probe()
        record["join"].append(state)
        if state.get("top") == "WelcomeBack":
            break
        # No offline earnings this time: stop 8 s after the reveal ended.
        if state.get("revealed") and not state.get("reveal"):
            settled_at = settled_at or time.time()
            if time.time() - settled_at > 8:
                break
        time.sleep(1.5)
    record["joinOrderOk"] = all(
        not (s.get("top") == "WelcomeBack" and (s.get("loading") or s.get("reveal"))) for s in record["join"]
    )
    client(CLOSE_ALL)
    time.sleep(1)
    # 2. New Player Mode: reveal → coach card + step-1 chip.
    record["npmEnter"] = server(ENTER_NPM)
    time.sleep(0.8)
    record["welcomeFired"] = server(WELCOME_BACK)
    welcome_closed = False
    for _ in range(30):
        time.sleep(1.0)
        state = probe()
        record["npm"].append(state)
        if state.get("top") == "WelcomeBack" and not welcome_closed:
            record["welcomeState"] = state
            record["captures"] += matrix("after-welcomeback-after-reveal", DEVICES[2:])
            client(CLOSE_ALL)
            welcome_closed = True
        if state.get("coach"):
            break
    # Welcome Back never during the loading screen / reveal, and before the coach card.
    record["npmOrderOk"] = welcome_closed and all(
        not (s.get("top") == "WelcomeBack" and (s.get("reveal") or s.get("loading"))) for s in record["npm"]
    )
    time.sleep(0.5)
    # Console look: Gamepad mode on the console preset; phone / tablet: Touch mode.
    client(SET_MODE.replace("__MODE__", json.dumps("Gamepad")))
    time.sleep(0.5)
    record["step1Gamepad"] = probe()
    record["captures"] += matrix("after-step1-gamepad", DEVICES[2:])
    client(SET_MODE.replace("__MODE__", json.dumps("Touch")))
    time.sleep(0.5)
    record["step1Touch"] = probe()
    record["captures"] += matrix("after-step1-touch", DEVICES[:2])
    client(SET_MODE.replace("__MODE__", "nil"))
    record["step1"] = probe()
    # 4. Real input (W held 1.6 s through the playtest client) → firstMove; then the pad → step 2.
    record["padBefore"] = client(PAD_DISTANCE)
    studio_mcp.call_tool("simulate_keyboard_input", {"keyCode": "W", "action": "tap", "duration": 1.6})
    time.sleep(1)
    record["padAfter"] = client(PAD_DISTANCE)
    record["afterWalk"] = probe()
    server(ONTO_PAD)
    time.sleep(4)
    client(SET_MODE.replace("__MODE__", json.dumps("Gamepad")))
    time.sleep(0.6)
    record["step2"] = probe()
    record["captures"] += matrix("after-step2-gamepad")
    client(SET_MODE.replace("__MODE__", "nil"))


if __name__ == "__main__":
    raise SystemExit(main())
