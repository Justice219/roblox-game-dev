#!/usr/bin/env python3
"""
r122_check.py — owner R122 ("Algorithm pack", 0.8.0) Studio verification of what the older QA
scripts do not cover. opening_check.py covers the new Garage Lab order (Uncle Atom = pad 4),
ftue_check.py the loading → reveal → tutorial first minute, lucky_buttons.py the paid DEAL card.

One solo playtest in the open MCP-connected place (CLAUDE.md rules 12 + R72; hold the lock):
    1. boot telemetry: after the loading hand-off the client has BootSeconds, BootStep<step> (each
       finished step's second) and BootEnd (ready / budget / tap / auto) — the values
       ClientPerfReporter sends as cp:<Class>:bootStep* / bootEnd.
    2. invite surface: DevInviteAvailable (Studio refuses CanSendGameInviteAsync) shows the HUD
       INVITE button; DevInviteMoment shows the invite moment card -> capture_device_matrix.
    3. console purchase hygiene: forced Gamepad mode, open the Shop -> GuiService.SelectedObject
       must not be a BUY / Robux button (PurchaseGuard) -> console capture.
    4. return notifications: the running ReturnNotifyService queues a test "cashFull" entry for
       this player due now, polls once, and reports the result (Studio = "dry": no HTTP request).
    5. stops ONLY its own playtest.

    python3 scripts/studio-lock.py acquire lead
    STUDIO_LOCK_OWNER=lead python3 tools/qa/r122_check.py
    python3 scripts/studio-lock.py release lead
Output: docs/verification/r122/*.jpg + r122.json. Exit 0 when every check passed.
"""
from __future__ import annotations

import base64
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tools" / "qa"))
import studio_mcp  # noqa: E402  (localhost-only MCP transport)
import world_tour  # noqa: E402  (lock + result helpers shared by every QA script)

OUT = ROOT / "docs" / "verification" / "r122"

DEVICES = [
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
]

# Fixed client probes (no free-form input reaches the place).
BOOT = r"""
local p = game:GetService("Players").LocalPlayer
local out = {}
for name, value in p:GetAttributes() do
	if string.sub(name, 1, 4) == "Boot" or name == "LoadingDone" then
		out[name] = value
	end
end
return game:GetService("HttpService"):JSONEncode(out)
"""

INVITE_ON = r"""
local p = game:GetService("Players").LocalPlayer
local Client = p.PlayerScripts.Client
local SM = require(Client.UI.ScreenManager)
-- The moment never shows over a window (PopupQueueConfig waitForModal): close Welcome Back etc.
for _ = 1, 3 do
	SM.closeAllModals()
	task.wait(0.5)
end
p:SetAttribute("DevInviteAvailable", true)
task.wait(1)
p:SetAttribute("DevInviteMoment", true)
local moment = false
for _ = 1, 16 do
	task.wait(0.25)
	if SM.isOpen("InviteMoment") then
		moment = true
		break
	end
end
local button = false
for _, d in p.PlayerGui:GetDescendants() do
	if d:IsA("GuiObject") and d.Visible and string.find(string.lower(d.Name), "invite") then
		button = true
		break
	end
end
return game:GetService("HttpService"):JSONEncode({ button = button, moment = moment })
"""

SHOP_GAMEPAD = r"""
local p = game:GetService("Players").LocalPlayer
local Client = p.PlayerScripts.Client
require(Client.Controllers.InputController).setForcedMode("Gamepad")
local SM = require(Client.UI.ScreenManager)
SM.closeAllModals()
task.wait(0.5)
SM.open("Shop")
task.wait(1.5)
local sel = game:GetService("GuiService").SelectedObject
local path, text = "nil", ""
if sel ~= nil then
	path = sel:GetFullName()
	for _, d in sel:GetDescendants() do
		if d:IsA("TextLabel") or d:IsA("TextButton") then text ..= " " .. d.Text end
	end
	if sel:IsA("TextButton") then text ..= " " .. sel.Text end
end
local upper = string.upper(path .. " " .. text)
local isBuy = string.find(upper, "BUY") ~= nil or string.find(upper, "ROBUX") ~= nil or string.find(upper, "PRICE") ~= nil
return game:GetService("HttpService"):JSONEncode({ open = SM.isOpen("Shop"), selected = path, text = text, isBuy = isBuy })
"""

SHOP_CLOSE = r"""
local Client = game:GetService("Players").LocalPlayer.PlayerScripts.Client
require(Client.UI.ScreenManager).closeAllModals()
require(Client.Controllers.InputController).setForcedMode(nil)
return "ok"
"""

# Server: queue a test return notification for the only player (due now) and poll once.
NOTIFY = r"""
local Http = game:GetService("HttpService")
local RNS = require(game:GetService("ServerScriptService").Server.Retention.ReturnNotifyService)
local runner = RNS.runner()
if runner == nil then
	return Http:JSONEncode({ error = "no runner" })
end
local p = game:GetService("Players"):GetPlayers()[1]
local queued = runner.queueTest(p.UserId, "cashFull", nil, 0)
task.wait(1)
local ok, report = pcall(runner.pollOnce)
return Http:JSONEncode({ queued = queued, polled = ok, report = if ok then report else tostring(report), stats = runner.stats() })
"""


def client(code: str) -> str:
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def server(code: str) -> str:
    return world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": code}))


def matrix(prefix: str, devices: list[dict]) -> list[str]:
    """capture_device_matrix on client-1 → docs/verification/r122/<prefix>-<label>.jpg."""
    response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
        "entries": devices, "target": "client-1", "format": "jpeg", "quality": 85, "settleSeconds": 1.0,
        "restoreAfter": True,
    }})
    images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
    names = []
    for device, image in zip(devices, images):
        name = f"{prefix}-{device['label']}.jpg"
        (OUT / name).write_bytes(base64.b64decode(image["data"], validate=True))
        names.append(name)
    return names or ["matrix failed: " + json.dumps(response)[:200]]


def wait_loaded(record: dict, seconds: float = 60.0) -> None:
    """Polls the client until LoadingDone (the loader hand-off) or `seconds` pass."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            boot = json.loads(client(BOOT))
            if boot.get("LoadingDone"):
                record["boot"] = boot
                return
        except Exception:  # client VM not up yet
            pass
        time.sleep(1.5)
    record["boot"] = {"error": "LoadingDone never set"}


def run(record: dict) -> None:
    wait_loaded(record)
    time.sleep(4)  # reveal + JoinFlow settle
    client(SHOP_CLOSE)
    record["invite"] = json.loads(client(INVITE_ON))
    record["inviteShots"] = matrix("invite", DEVICES)
    record["shop"] = json.loads(client(SHOP_GAMEPAD))
    record["shopShots"] = matrix("shop-gamepad", [DEVICES[2]])
    client(SHOP_CLOSE)
    record["notify"] = json.loads(server(NOTIFY))


def main() -> int:
    world_tour.require_lock()
    status = json.loads(studio_mcp.call_tool("solo_playtest", {"action": "status"}))
    if status.get("running"):
        raise SystemExit("a playtest is already running; not touching it")
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {}
    print(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:120])
    try:
        run(record)
    except Exception as error:  # keep what was recorded; report the failing step
        record["error"] = str(error)[:400]
    finally:
        world_tour.stop_playtest()
    boot = record.get("boot") or {}
    notify = record.get("notify") or {}
    checks = {
        "no error": "error" not in record,
        "boot seconds set": isinstance(boot.get("BootSeconds"), (int, float)),
        "boot end reason set": boot.get("BootEnd") in ("ready", "budget", "tap", "auto"),
        "boot step seconds set": any(k.startswith("BootStep") for k in boot),
        "boot under 20 s in Studio": isinstance(boot.get("BootSeconds"), (int, float)) and boot["BootSeconds"] < 20,
        "HUD invite button visible": bool((record.get("invite") or {}).get("button")),
        "invite moment visible": bool((record.get("invite") or {}).get("moment")),
        "shop opened (gamepad)": bool((record.get("shop") or {}).get("open")),
        "shop focus not on BUY": (record.get("shop") or {}).get("isBuy") is False,
        "notify test queued": bool(notify.get("queued")),
        "notify poll ran": bool(notify.get("polled")),
    }
    record["checks"] = checks
    (OUT / "r122.json").write_text(json.dumps(record, indent=1))
    print(json.dumps(record, indent=1))
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
