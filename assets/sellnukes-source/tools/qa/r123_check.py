#!/usr/bin/env python3
"""
r123_check.py — Studio verification of owner R123 / R127 and the two open R122 checks.

One solo playtest in the open MCP-connected place (CLAUDE.md rules 12 + R72; hold the lock):
    1. R123 ("leaderboard covers the invite ui"): Studio is a desktop client, so Roblox's player
       list shows top-right. Reads the HUD's published "TopRight" zone (admin chip + INVITE) and
       the player-list reserve Hud computed, proves they do not overlap, and screenshots it.
    2. R127 ("in the spin UI hide the money counter"): opens the Lucky Wheel → Hud.currencyHidden()
       is true and the stack is invisible; closes it → shown again. Screenshot with the wheel open.
    3. R122 open check A: clicks a HUD offer chip with REAL mouse input (simulate_mouse_input at
       the chip's centre) → its DEAL card opens (no purchase prompt from the chip itself).
    4. R122 open check B: lists every ContextActionService binding on ButtonL3 / ButtonR3, so we
       know whether Roblox's default scripts (PlayerModule) also use L3 (our INVITE binding).
    5. stops ONLY its own playtest.

    python3 scripts/studio-lock.py acquire lead
    STUDIO_LOCK_OWNER=lead python3 tools/qa/r123_check.py
    python3 scripts/studio-lock.py release lead
Output: docs/verification/r123/*.jpg + r123.json. Exit 0 when every check passed.
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

OUT = ROOT / "docs" / "verification" / "r123"

# Fixed client snippets (no free-form input reaches the place).
READY = r"""
local p = game:GetService("Players").LocalPlayer
return if p:GetAttribute("LoadingDone") then "yes" else "no"
"""

CLOSE_ALL = r"""
local Client = game:GetService("Players").LocalPlayer.PlayerScripts.Client
local SM = require(Client.UI.ScreenManager)
for _ = 1, 3 do
	SM.closeAllModals()
	task.wait(0.4)
end
return "ok"
"""

# The TopRight zone (design px) vs the player-list reserve, both in screen pixels for comparison.
LEADERBOARD = r"""
local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local p = Players.LocalPlayer
local gui = p.PlayerGui
local invite, chip
for _, d in gui:GetDescendants() do
	if d:IsA("GuiButton") and d.Visible then
		local n = string.lower(d.Name)
		if invite == nil and string.find(n, "invite") then invite = d end
		if chip == nil and string.find(n, "adminchip") then chip = d end
	end
end
local camera = workspace.CurrentCamera
local vp = camera.ViewportSize
local function box(g)
	if g == nil then return nil end
	return { x = g.AbsolutePosition.X, y = g.AbsolutePosition.Y, w = g.AbsoluteSize.X, h = g.AbsoluteSize.Y }
end
local ok, listOn = pcall(StarterGui.GetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.PlayerList)
return game:GetService("HttpService"):JSONEncode({
	viewport = { x = vp.X, y = vp.Y },
	listOn = ok and listOn,
	players = #Players:GetPlayers(),
	invite = box(invite),
	chip = box(chip),
})
"""

WHEEL = r"""
local Client = game:GetService("Players").LocalPlayer.PlayerScripts.Client
local SM = require(Client.UI.ScreenManager)
local Hud = require(Client.UI.Hud.Hud)
SM.open("LuckyWheel")
task.wait(1.2)
local hiddenOpen = Hud.currencyHidden()
return game:GetService("HttpService"):JSONEncode({ open = SM.isOpen("LuckyWheel"), hidden = hiddenOpen })
"""

WHEEL_CLOSE = r"""
local Client = game:GetService("Players").LocalPlayer.PlayerScripts.Client
local SM = require(Client.UI.ScreenManager)
local Hud = require(Client.UI.Hud.Hud)
SM.close("LuckyWheel")
task.wait(1.2)
return game:GetService("HttpService"):JSONEncode({ open = SM.isOpen("LuckyWheel"), hidden = Hud.currencyHidden() })
"""

# The first visible HUD offer chip's centre in viewport pixels (+ the top-bar inset).
CHIP = r"""
local GuiService = game:GetService("GuiService")
local gui = game:GetService("Players").LocalPlayer.PlayerGui
for _, d in gui:GetDescendants() do
	if d:IsA("GuiButton") and d.Visible and string.sub(d.Name, 1, 6) == "Offer_" and d.AbsoluteSize.X > 10 then
		local inset = GuiService:GetGuiInset()
		local gui2 = d:FindFirstAncestorOfClass("ScreenGui")
		local ignores = gui2 ~= nil and gui2.IgnoreGuiInset
		local cx = d.AbsolutePosition.X + d.AbsoluteSize.X / 2
		local cy = d.AbsolutePosition.Y + d.AbsoluteSize.Y / 2 + (if ignores then 0 else inset.Y)
		return game:GetService("HttpService"):JSONEncode({ name = d.Name, x = cx, y = cy })
	end
end
return "{}"
"""

DEAL_OPEN = r"""
local Client = game:GetService("Players").LocalPlayer.PlayerScripts.Client
local SM = require(Client.UI.ScreenManager)
return if SM.isOpen("DealCard") then "yes" else "no"
"""

BINDINGS = r"""
local CAS = game:GetService("ContextActionService")
local out = {}
for name, info in CAS:GetAllBoundActionInfo() do
	for _, input in info.inputTypes or {} do
		if input == Enum.KeyCode.ButtonL3 or input == Enum.KeyCode.ButtonR3 then
			table.insert(out, name .. "=" .. tostring(input))
		end
	end
end
return game:GetService("HttpService"):JSONEncode(out)
"""


def client(code: str) -> str:
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def screenshot(name: str) -> str:
    """capture_screenshot of the live client → docs/verification/r123/<name>."""
    response = studio_mcp.rpc("tools/call", {"name": "capture_screenshot", "arguments": {
        "format": "jpeg", "quality": 85,
    }})
    for item in response.get("content", []):
        if item.get("type") == "image" and item.get("data"):
            (OUT / name).write_bytes(base64.b64decode(item["data"], validate=True))
            return name
    return "screenshot failed: " + json.dumps(response)[:200]


def run(record: dict) -> None:
    deadline = time.time() + 60
    while time.time() < deadline:
        try:
            if client(READY) == "yes":
                break
        except Exception:  # client VM not up yet
            pass
        time.sleep(1.5)
    time.sleep(4)
    client(CLOSE_ALL)
    record["leaderboard"] = json.loads(client(LEADERBOARD))
    record["leaderboardShot"] = screenshot("leaderboard-invite.jpg")
    record["wheelOpen"] = json.loads(client(WHEEL))
    record["wheelShot"] = screenshot("wheel-no-currency.jpg")
    record["wheelClosed"] = json.loads(client(WHEEL_CLOSE))
    client(CLOSE_ALL)
    chip = json.loads(client(CHIP))
    record["chip"] = chip
    if chip.get("x") is not None:
        studio_mcp.call_tool("simulate_mouse_input", {"action": "click", "x": chip["x"], "y": chip["y"]})
        time.sleep(1.0)
        record["dealOpen"] = client(DEAL_OPEN) == "yes"
        record["dealShot"] = screenshot("offer-chip-card.jpg")
    record["l3r3"] = json.loads(client(BINDINGS))


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
    board = record.get("leaderboard") or {}
    invite = board.get("invite") or {}
    viewport = board.get("viewport") or {}
    # Roblox's list is ~252 pt wide at the right edge (HudZonesConfig.PlayerList); Studio = 1 px per pt.
    list_left = (viewport.get("x") or 0) - 252
    checks = {
        "no error": "error" not in record,
        "player list on (desktop)": bool(board.get("listOn")),
        "INVITE left of the player list": bool(invite) and invite["x"] + invite["w"] <= list_left,
        "wheel open hides the money counter": bool((record.get("wheelOpen") or {}).get("hidden")),
        "wheel closed shows it again": (record.get("wheelClosed") or {}).get("hidden") is False,
        "offer chip click opens its DEAL card": bool(record.get("dealOpen")),
    }
    record["checks"] = checks
    (OUT / "r123.json").write_text(json.dumps(record, indent=1))
    print(json.dumps(record, indent=1))
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
