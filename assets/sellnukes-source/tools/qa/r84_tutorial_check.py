#!/usr/bin/env python3
"""
r84_tutorial_check.py — owner R84 Studio verification: the tutorial arrow points at the BUTTON to
press (not the model) and that button is highlighted, on console / phone / tablet (+ desktop).

One solo playtest in the open MCP-connected place (CLAUDE.md rules 12 + R72; hold the lock):
    1. join, wait for the plot reveal, close windows, enter admin New Player Mode (a never-saved
       sandbox profile: a fresh tutorial; real data is never touched) and wait for step 1.
    2. step 1 (pad): captures (console Gamepad, phone + tablet Touch, desktop KB+M); the pad's
       price button carries the ring, the arrow stays over the pad.
    3. onto the Workbench pad (server PivotTo) → step 2 (click). The character is placed in reach
       of the Workbench on its billboard side and the camera turned toward the board (client
       camera look only), so the make bar / TAP! button are on screen; captures per device.
    4. clicks the Workbench (the real ProducerClick intent through ProducerBillboards.click) →
       step 3 (upgrade): captures per device (arrow under the UPGRADE pill + the device glyph).
    5. clicks until the upgrade is affordable, presses UPGRADE (the real ProducerUpgrade intent)
       and proves the UPGRADE ring is gone the moment the server moves the step on.
    6. owner R86 gem button, same sandbox: grants gems ONLY after checking the NewPlayerMode
       attribute (sandbox profile, never saved), then captures the gem button "75" + the LB hint
       (console), "SURE?" after the first press, the bought level after the second press, and
       "NEED 75" once the gems run short (phone / tablet / console).
    7. stops ONLY its own playtest.

    python3 scripts/studio-lock.py acquire T-tutorial
    STUDIO_LOCK_OWNER=T-tutorial python3 tools/qa/r84_tutorial_check.py
    python3 scripts/studio-lock.py release T-tutorial
Output: docs/verification/r84-*.jpg, r86-*.jpg + docs/verification/r84-tutorial.json
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

import studio_mcp  # noqa: E402  (localhost-only MCP transport)
import world_tour  # noqa: E402  (require_lock, result, stop_playtest)

OUT = ROOT / "docs/verification"
CONSOLE = [{"label": "console", "deviceId": "xbox"}]
TOUCH = [
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
]
DESKTOP = [{"label": "desktop", "deviceId": "hd_1080"}]

# Read-only client probe (fixed code, no free-form input).
PROBE = r"""
local Players = game:GetService("Players")
local Http = game:GetService("HttpService")
local p = Players.LocalPlayer
local c = p.PlayerScripts.Client
local SM = require(c.UI.ScreenManager)
local IC = require(c.Controllers.InputController)
local T = require(c.Tycoon.Tutorial)
local TH = require(c.Tycoon.TutorialHighlight)
local PR = require(c.Tycoon.PlotReveal)
local PB = require(c.Tycoon.ProducerBillboards)
local OfferFx = require(c.UI.Widgets.OfferFx)
local hud = p.PlayerGui:FindFirstChild("TargetArrow", true)
local badge = p.PlayerGui:FindFirstChild("TargetBadge", true)
local record = PB.byId("p1_workbench")
local function ringed(control)
	return control ~= nil and control:FindFirstChild("TutorialRing") ~= nil
end
local state = TH.state()
local fx = OfferFx.stats()
return Http:JSONEncode({
	t = math.floor(time() * 10) / 10,
	revealed = p:GetAttribute("PlotRevealed"),
	reveal = PR.isPlaying(),
	top = SM.topModalName(),
	mode = IC.mode,
	step = T.step(),
	hint = T.hintText(),
	focusKind = state.kind,
	focusPoint = state.point,
	rings = state.rings,
	upgradeRinged = record ~= nil and ringed(record.upgrade),
	makeRinged = record ~= nil and ringed(record.well),
	affordable = record ~= nil and record.affordable,
	arrowShown = hud ~= nil and hud.Visible,
	arrowAt = hud ~= nil and string.format("%.0f,%.0f r%.0f", hud.AbsolutePosition.X, hud.AbsolutePosition.Y, hud.Rotation) or nil,
	badgeShown = badge ~= nil and badge.Visible,
	fxRunning = fx.running,
	fxConnected = fx.connected,
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

ENTER_NPM = r"""
local PDS = require(game:GetService("ServerScriptService").Server.Services.PlayerDataService)
local p = game:GetService("Players"):GetPlayers()[1]
local ok, msg = PDS.enterNewPlayerModeAsync(p)
return tostring(ok) .. " " .. tostring(msg)
"""

ONTO_PAD = r"""
local p = game:GetService("Players"):GetPlayers()[1]
local index = p:GetAttribute("PlotIndex")
local pad = workspace.Plots[`Plot{index}`].Area01.Pads.a1_workbench.Trigger
p.Character:PivotTo(CFrame.new(pad.Position + Vector3.new(0, 3, 0)))
return "on pad"
"""

# Client: where to stand in reach of the Workbench: beside its billboard side, offset sideways so
# the character never hides the board in the shots. Returns "x,y,z,ax,az".
STAND_SPOT = r"""
local p = game:GetService("Players").LocalPlayer
local c = p.PlayerScripts.Client
local PB = require(c.Tycoon.ProducerBillboards)
local record = PB.byId("p1_workbench")
local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
if record == nil or root == nil then return "none" end
local anchor = record.anchor.Position
local spot = record.point.WorldPosition
local flat = Vector3.new(spot.X - anchor.X, 0, spot.Z - anchor.Z)
if flat.Magnitude < 1 then
	flat = Vector3.new(root.Position.X - anchor.X, 0, root.Position.Z - anchor.Z)
end
local away = flat.Unit
local side = Vector3.new(-away.Z, 0, away.X)
local stand = anchor + away * 8 + side * 7
return string.format("%.2f,%.2f,%.2f,%.2f,%.2f", stand.X, root.Position.Y, stand.Z, anchor.X, anchor.Z)
"""

# Server: stand there facing the producer (numbers formatted in by this script only).
STAND_AT = r"""
local p = game:GetService("Players"):GetPlayers()[1]
local pos = Vector3.new(__X__, __Y__, __Z__)
local look = Vector3.new(__AX__, __Y__, __AZ__)
p.Character:PivotTo(CFrame.lookAt(pos, look))
return "standing"
"""

# Client (QA only): turn the player's own follow camera toward the Workbench board. The camera
# module keeps this look direction and keeps walls out of the way (a scripted camera ended up
# outside the garage wall, behind which the board is hidden: R84 run 4).
FACE_BOARD = r"""
local p = game:GetService("Players").LocalPlayer
local PB = require(p.PlayerScripts.Client.Tycoon.ProducerBillboards)
local record = PB.byId("p1_workbench")
local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
if record == nil or root == nil then return "none" end
local spot = record.point.WorldPosition
local back = Vector3.new(root.Position.X - spot.X, 0, root.Position.Z - spot.Z)
if back.Magnitude < 0.5 then back = Vector3.new(0, 0, 1) end
local camera = workspace.CurrentCamera
camera.CameraType = Enum.CameraType.Custom
camera.CFrame = CFrame.lookAt(root.Position + back.Unit * 12 + Vector3.new(0, 5, 0), spot)
return "facing"
"""

RESTORE_CAMERA = r"""
local camera = workspace.CurrentCamera
camera.CameraType = Enum.CameraType.Custom
local character = game:GetService("Players").LocalPlayer.Character
local humanoid = character and character:FindFirstChildOfClass("Humanoid")
if humanoid ~= nil then camera.CameraSubject = humanoid end
return "restored"
"""

# Client: one real click / upgrade on the Workbench (the same intents a tap / key sends).
CLICK = r"""
local PB = require(game:GetService("Players").LocalPlayer.PlayerScripts.Client.Tycoon.ProducerBillboards)
local record = PB.byId("p1_workbench")
return if record ~= nil then tostring(PB.click(record)) else "no record"
"""

# Server: gems for the R86 shots, ONLY inside the New Player Mode sandbox (never saved).
SANDBOX_GEMS = r"""
local PDS = require(game:GetService("ServerScriptService").Server.Services.PlayerDataService)
local p = game:GetService("Players"):GetPlayers()[1]
if p:GetAttribute("NewPlayerMode") ~= true then return "refused: not in New Player Mode" end
return tostring(PDS.grantGems(p, __GEMS__, "QA"))
"""

# Client: one press of the Workbench gem button (the same path as a tap: Tycoon/GemUpgrade.press).
GEM_PRESS = r"""
local c = game:GetService("Players").LocalPlayer.PlayerScripts.Client
local PB = require(c.Tycoon.ProducerBillboards)
local G = require(c.Tycoon.GemUpgrade)
local record = PB.byId("p1_workbench")
return if record ~= nil then G.press(record) else "no record"
"""

# Client: the gem button's painted state + gems + level (read-only).
GEM_STATE = r"""
local p = game:GetService("Players").LocalPlayer
local c = p.PlayerScripts.Client
local PB = require(c.Tycoon.ProducerBillboards)
local CS = require(c.ClientState)
local AM = require(c.Platform.ActionMap)
local record = PB.byId("p1_workbench")
if record == nil then return "no record" end
return string.format("shown=%s text=%s gems=%s level=%d hint=%s active=%s", tostring(record.gem.Visible),
	record.gemText.Text, tostring(CS.profile and CS.profile.gems), PB.level(record),
	tostring(AM.hintTexts().GemUpgrade), tostring(AM.isActive("GemUpgrade")))
"""

UPGRADE = r"""
local PB = require(game:GetService("Players").LocalPlayer.PlayerScripts.Client.Tycoon.ProducerBillboards)
local record = PB.byId("p1_workbench")
return if record ~= nil then tostring(PB.upgrade(record)) else "no record"
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


def playtest_alive() -> bool:
    try:
        return bool(json.loads(studio_mcp.call_tool("solo_playtest", {"action": "status"})).get("running"))
    except Exception:
        return False


def matrix(prefix: str, devices: list[dict], tag: str = "r84") -> list[str]:
    """One capture request PER device (a dropped client then costs one shot, not the batch)."""
    names = []
    for device in devices:
        response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
            # restoreAfter off: a simulator left in a bad state by an earlier session made the
            # tool's restore step fail every capture (2026-10-31); run() ends on the desktop preset.
            "entries": [device], "target": "client-1", "format": "jpeg", "quality": 85, "settleSeconds": 1.2,
            "restoreAfter": False,
        }})
        images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
        if images:
            name = f"{tag}-{prefix}-{device['label']}.jpg"
            (OUT / name).write_bytes(base64.b64decode(images[0]["data"], validate=True))
            names.append(name)
        else:
            names.append(f"{prefix}-{device['label']} failed: " + json.dumps(response)[:200])
            if not playtest_alive():
                raise RuntimeError(f"playtest ended during {prefix}-{device['label']}")
        time.sleep(0.5)
    return names


def shoot_all(prefix: str, record: dict) -> None:
    """Gamepad on the console preset, Touch on phone + tablet, KB+M on desktop (probe each)."""
    for mode, devices in (("Gamepad", CONSOLE), ("Touch", TOUCH), ("KeyboardMouse", DESKTOP)):
        client(SET_MODE.replace("__MODE__", json.dumps(mode)))
        time.sleep(0.8)
        record[f"{prefix}-{mode}"] = probe()
        record["captures"] += matrix(prefix, devices)
    client(SET_MODE.replace("__MODE__", "nil"))


def wait_step(step: int, seconds: float) -> dict:
    state: dict = {}
    deadline = time.time() + seconds
    while time.time() < deadline:
        state = probe()
        if state.get("step") == step:
            return state
        time.sleep(0.5)
    return state


def stand_near_workbench(record: dict) -> None:
    spot = client(STAND_SPOT)
    record.setdefault("stand", []).append(spot)
    parts = spot.split(",")
    if len(parts) != 5:
        return
    x, y, z, ax, az = (float(v) for v in parts)
    code = (STAND_AT.replace("__X__", f"{x:.2f}").replace("__Y__", f"{y:.2f}").replace("__Z__", f"{z:.2f}")
            .replace("__AX__", f"{ax:.2f}").replace("__AZ__", f"{az:.2f}"))
    server(code)
    time.sleep(1.0)
    client(FACE_BOARD)
    time.sleep(1.0)


def run(record: dict) -> None:
    # 1. Join + reveal, then a fresh tutorial in the New Player Mode sandbox.
    deadline = time.time() + 150
    while time.time() < deadline:
        state = probe()
        if state.get("revealed") and not state.get("reveal"):
            break
        time.sleep(1.5)
    client(CLOSE_ALL)
    record["npmEnter"] = server(ENTER_NPM)
    time.sleep(2)
    for _ in range(40):
        state = probe()
        if state.get("step") == 1 and state.get("revealed") and not state.get("reveal"):
            break
        time.sleep(1)
    time.sleep(2)
    client(CLOSE_ALL)
    # 2. Step 1: the pad (R84_SKIP_STEP1=1 skips these shots when they already exist).
    if os.environ.get("R84_SKIP_STEP1") != "1":
        shoot_all("step1-pad", record)
    # 3. Step 2: click (in reach, facing the board).
    server(ONTO_PAD)
    record["step2"] = wait_step(2, 12)
    time.sleep(2)
    stand_near_workbench(record)
    shoot_all("step2-click", record)
    # 4. Step 3: upgrade.
    client(SET_MODE.replace("__MODE__", json.dumps("Gamepad")))
    record["click"] = client(CLICK)
    record["step3"] = wait_step(3, 10)
    client(SET_MODE.replace("__MODE__", "nil"))
    stand_near_workbench(record)
    shoot_all("step3-upgrade", record)
    # 5. Afford + press UPGRADE: the ring must leave with the step.
    for _ in range(24):
        state = probe()
        if state.get("affordable"):
            break
        client(CLICK)
        time.sleep(1.5)
    record["beforeUpgrade"] = probe()
    record["upgrade"] = client(UPGRADE)
    record["afterUpgrade"] = wait_step(4, 10)
    record["ringGone"] = record["afterUpgrade"].get("upgradeRinged") is False
    record["captures"] += matrix("step4-after-upgrade", CONSOLE)
    run_gem(record)


def gem_matrix(prefix: str, record: dict, modes: tuple = (("Gamepad", CONSOLE), ("Touch", TOUCH))) -> None:
    """R86 captures: Gamepad on console (LB hint), Touch on phone + tablet (GEMS touch button)."""
    for mode, devices in modes:
        client(SET_MODE.replace("__MODE__", json.dumps(mode)))
        time.sleep(0.8)
        record[f"{prefix}-{mode}"] = client(GEM_STATE)
        record["captures"] += matrix(prefix, devices, "r86")
    client(SET_MODE.replace("__MODE__", "nil"))


def run_gem(record: dict) -> None:
    """Owner R86: the gem button states, inside the New Player Mode sandbox only."""
    stand_near_workbench(record)
    record["gemGrant"] = server(SANDBOX_GEMS.replace("__GEMS__", "100"))
    if not record["gemGrant"].startswith("refused"):
        time.sleep(1.5)
        gem_matrix("gem-ready", record)
        # "SURE?" lasts 3 s: arm, capture ONE device at once; let it expire, re-arm for the next.
        record["gemArm"] = []
        for mode, devices in (("Gamepad", CONSOLE), ("Touch", TOUCH[:1])):
            client(SET_MODE.replace("__MODE__", json.dumps(mode)))
            time.sleep(3.5)
            record["gemArm"].append(client(GEM_PRESS))
            record[f"gem-sure-{mode}"] = client(GEM_STATE)
            record["captures"] += matrix("gem-sure", devices, "r86")
        time.sleep(3.5)
        record["gemPress1"] = client(GEM_PRESS)  # arm
        time.sleep(0.3)
        record["gemPress2"] = client(GEM_PRESS)  # buy (second press within 3 s)
        time.sleep(2.0)
        record["gemAfterBuy"] = client(GEM_STATE)
        gem_matrix("gem-need", record)  # 100 - 75 = 25 gems left: "NEED 75"
    client(RESTORE_CAMERA)
    matrix("final-desktop", DESKTOP)  # leave the device simulator on the desktop preset


def main() -> int:
    world_tour.require_lock()
    status = json.loads(studio_mcp.call_tool("solo_playtest", {"action": "status"}))
    if status.get("running"):
        raise SystemExit("a playtest is already running; not touching it")
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"captures": []}
    print(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:120])
    try:
        run(record)
    except Exception as error:  # keep what was recorded; report the failing step
        record["error"] = str(error)[:400]
    finally:
        world_tour.stop_playtest()
    (OUT / ("r84-tutorial-run2.json" if os.environ.get("R84_SKIP_STEP1") == "1" else "r84-tutorial.json")).write_text(
        json.dumps(record, indent=1))
    keys = [k for k in record if k != "captures"]
    print(json.dumps({k: record[k] for k in keys}, indent=1)[:6000])
    print("captures:", record["captures"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
