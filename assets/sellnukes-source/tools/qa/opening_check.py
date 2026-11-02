#!/usr/bin/env python3
"""
opening_check.py — owner R64 + R65 Studio verification: a brand-new player's first producer.

As a genuinely new profile (admin New Player Mode: sandbox profile, every pass reads unowned) it
buys the free Workbench, proves the Workbench does NOT run until clicked (cash and CycleStart stay
0 while idle), clicks it ten times ($1 each; each click pays exactly once and then the producer
idles), buys the first upgrade for exactly $10, then hires Uncle Atom (sandbox cash, never saved)
and proves the Workbench now runs by itself. Also records the root cause of R64: the owner's real
account owns the AutoClicker pass (Roblox gives a game's creator every pass of the game).

Studio rules (CLAUDE.md 12 + lock): uses ONLY the open MCP-connected place; run it while holding
the lock; it refuses to touch a playtest it did not start and stops only its own.
    python3 scripts/studio-lock.py acquire E1 && python3 tools/qa/opening_check.py; \
        python3 scripts/studio-lock.py release E1
Output: docs/verification/opening/*.jpg + opening.json
"""
from __future__ import annotations

import base64
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import studio_mcp  # noqa: E402  (localhost-only MCP transport)

OUT = ROOT / "docs" / "verification" / "opening"
LOCK = ROOT / "scripts" / "studio-lock.py"

# Server prelude: the services + the (only) player, its Workbench anchor and a JSON state snapshot.
PRELUDE = r"""
local Players = game:GetService("Players")
local SSS = game:GetService("ServerScriptService")
local Http = game:GetService("HttpService")
local PDS = require(SSS.Server.Services.PlayerDataService)
local TS = require(SSS.Server.Tycoon.TycoonService)
local MS = require(SSS.Server.Services.MonetizationService)
local player = Players:GetPlayers()[1]
local function anchor()
	for _, d in workspace:GetDescendants() do
		if d.Name == "Anchor" and d:GetAttribute("ProducerId") == "p1_workbench"
			and d:GetAttribute("OwnerUserId") == player.UserId then
			return d
		end
	end
	return nil
end
local function state()
	local profile = PDS.getProfile(player)
	local a = anchor()
	local pads = {}
	if profile then for id in profile.tycoon.pads do table.insert(pads, id) end end
	table.sort(pads)
	return Http:JSONEncode({
		ready = TS.isReady(player),
		npm = PDS.isNewPlayerMode(player),
		autoClickerPass = MS.ownsPass(player, "AutoClicker"),
		autoClickerSetting = profile and profile.settings.autoClicker,
		cash = profile and profile.cash,
		level = profile and profile.tycoon.producers.p1_workbench or 0,
		pads = pads,
		cycleStart = a and a:GetAttribute("CycleStart"),
		automated = a and a:GetAttribute("Automated"),
		nextCost = a and a:GetAttribute("NextCost"),
		perCycle = a and a:GetAttribute("PerCycle"),
		cycleTime = a and a:GetAttribute("CycleTime"),
		now = workspace:GetServerTimeNow(),
	})
end
"""

# Whitelisted server actions (no free text reaches Luau).
ACTIONS = {
    "state": "return state()",
    "npm": "local ok, msg = PDS.enterNewPlayerModeAsync(player) return Http:JSONEncode({ok = ok, msg = msg})",
    "buy_workbench": "local ok, why = TS.purchasePad(player, 'a1_workbench') return Http:JSONEncode({ok = ok, why = why})",
    # Stand next to the Workbench (inside ClickReach) facing it, so clicks pass the server reach check.
    "stand": """
local a = anchor()
local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
if a and root then root.CFrame = CFrame.lookAt(a.Position + a.CFrame.LookVector * 14 + Vector3.new(0, 3, 0), a.Position) end
return tostring(a ~= nil and root ~= nil)""",
    "grant_manager_cash": "PDS.grantCash(player, 60000, 'admin') return state()",
    "buy_to_manager": """
local bought = {}
-- R122 (2026-11-01): Uncle Atom is pad 4, right after the Glow Lamp.
for _, id in {'a1_tool_wall','a1_glow_lamp','a1_uncle_atom'} do
	local ok, why = TS.purchasePad(player, id)
	table.insert(bought, id .. '=' .. tostring(ok) .. (why and (':' .. why) or ''))
end
return Http:JSONEncode(bought)""",
}

CLIENT_CLICK = r"""
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Net.Remotes)
Remotes.event("ProducerClick"):FireServer("p1_workbench")
return "clicked"
"""
CLIENT_UPGRADE = r"""
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Net.Remotes)
Remotes.event("ProducerUpgrade"):FireServer("p1_workbench", "1")
return "upgrade"
"""
# Camera on the Workbench (from the character's side) for the screenshots.
CLIENT_CAMERA = r"""
local cam = workspace.CurrentCamera
local root = game:GetService("Players").LocalPlayer.Character and game:GetService("Players").LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
for _, d in workspace:GetDescendants() do
	if d.Name == "Anchor" and d:GetAttribute("ProducerId") == "p1_workbench" and d:GetAttribute("OwnerUserId") == game:GetService("Players").LocalPlayer.UserId then
		cam.CameraType = Enum.CameraType.Scriptable
		local from = (root and root.Position or d.Position + Vector3.new(0, 0, 20))
		local dir = (from - d.Position) * Vector3.new(1, 0, 1)
		dir = if dir.Magnitude > 0.1 then dir.Unit else Vector3.new(0, 0, 1)
		cam.CFrame = CFrame.lookAt(d.Position + dir * 26 + Vector3.new(0, 12, 0), d.Position + Vector3.new(0, 4, 0))
		return "ok"
	end
end
return "no anchor"
"""


def result(raw: str):
    data = json.loads(raw)
    if not data.get("ok", True):
        raise RuntimeError(raw[:400])
    value = data.get("result")
    return value


def server(action: str):
    value = result(studio_mcp.call_tool("eval_server_runtime", {"code": PRELUDE + ACTIONS[action]}))
    try:
        return json.loads(value)
    except (TypeError, json.JSONDecodeError):
        return value


def client(code: str):
    return result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def capture(name: str, shots: list[str]) -> None:
    response = studio_mcp.rpc("tools/call", {"name": "capture_screenshot", "arguments": {"format": "jpeg", "quality": 86}})
    images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
    if images:
        (OUT / f"{name}.jpg").write_bytes(base64.b64decode(images[0]["data"], validate=True))
        shots.append(f"{name}.jpg")
        print(f"[opening] {name}.jpg", flush=True)


def wait(predicate, seconds: float, action: str = "state"):
    deadline = time.time() + seconds
    last = None
    while time.time() < deadline:
        try:
            last = server(action)
            if isinstance(last, dict) and predicate(last):
                return last
        except Exception as error:  # server VM / profile not up yet
            last = {"error": str(error)[:200]}
        time.sleep(1.5)
    return last


def main() -> int:
    import subprocess

    status = subprocess.run([sys.executable, str(LOCK), "status"], capture_output=True, text=True).stdout
    holder = json.loads(status.splitlines()[0]).get("owner") if status.strip().startswith("{") else None
    if holder is None:
        raise SystemExit("hold the studio lock first (scripts/studio-lock.py acquire <name>)")
    running = studio_mcp.call_tool("solo_playtest", {"action": "status"})
    if '"running":true' in running.replace(" ", ""):
        raise SystemExit(f"a playtest is already running; not touching it: {running[:200]}")
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"lockHolder": holder}
    shots: list[str] = []
    print(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:160], flush=True)
    try:
        record["join"] = wait(lambda s: s.get("ready") is True, 150)
        # Root cause of R64: the creator's real account owns the AutoClicker pass.
        record["realAccount"] = {k: record["join"].get(k) for k in ("autoClickerPass", "autoClickerSetting", "npm")}
        record["enterNpm"] = server("npm")
        record["fresh"] = wait(lambda s: s.get("npm") is True and s.get("ready") is True, 90)
        time.sleep(3)
        record["buyWorkbench"] = server("buy_workbench")
        server("stand")
        time.sleep(1)
        client(CLIENT_CAMERA)
        record["idleStart"] = server("state")
        time.sleep(6)  # a manual producer must NOT run by itself
        record["idleAfter6s"] = server("state")
        capture("01-workbench-idle-click-to-start", shots)
        clicks = []
        for index in range(10):
            server("stand")
            client(CLIENT_CLICK)
            time.sleep(0.35)
            mid = server("state")
            time.sleep(1.15)
            done = server("state")
            clicks.append({"click": index + 1, "running": mid.get("cycleStart"), "cash": done.get("cash"),
                           "idleAfter": done.get("cycleStart")})
            if index == 0:
                capture("02-first-click-cycle-running", shots)
        record["clicks"] = clicks
        time.sleep(4)
        record["idleAfterClicks"] = server("state")
        capture("03-ten-clicks-upgrade-10", shots)
        client(CLIENT_UPGRADE)
        time.sleep(1.5)
        record["afterUpgrade"] = server("state")
        capture("04-first-upgrade-bought", shots)
        record["grant"] = server("grant_manager_cash")
        record["buyToManager"] = server("buy_to_manager")
        time.sleep(8)  # build-in + manager arrives
        managed = server("state")
        time.sleep(5)
        record["managed"] = managed
        record["managedAfter5s"] = server("state")
        client(CLIENT_CAMERA)
        time.sleep(1)
        capture("05-uncle-atom-automatic", shots)
    finally:
        print(studio_mcp.call_tool("solo_playtest", {"action": "stop"})[:160], flush=True)
    record["shots"] = shots
    (OUT / "opening.json").write_text(json.dumps(record, indent=2))
    print(json.dumps(record, indent=1)[:6000])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
