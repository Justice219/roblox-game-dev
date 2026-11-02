#!/usr/bin/env python3
"""
fix_check.py — Studio verification of the R17/R25/R26 yaw + motion-group fixes and the R19 glow
caps through the real game code (solo playtest; hold `python3 scripts/studio-lock.py acquire W1`).

Server: TycoonAdmin.setArea(3) + rebuildPlot (Garage Lab + Nuke Stand built), restore afterwards.
Client: tools/qa/fix_check_client.luau — numeric group / yaw proof + captures into
docs/verification/world-qa/fixes/: arch-from-road.jpg, stand-nukes.jpg, glow-lamp-before.jpg
(pre-R19 light values re-applied on the client) and glow-lamp-after.jpg.

Phase 2 (owner R41): TycoonAdmin.setArea(6) + rebuildPlot (areas 1-5 built), then the `rotors`
numeric check (every Centrifuge Row rotor spins on its own drum axis inside its dome) and the
centrifuge-rotors.jpg close-up.
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tools/qa"))

import studio_mcp  # noqa: E402
import world_tour  # noqa: E402  (shares the template renderer, capture and server commands)

CLIENT = (ROOT / "tools/qa/fix_check_client.luau").read_text()
COMMANDS = {"ready", "measure", "cam_arch", "cam_stand", "cam_lamp", "lights_old", "lights_new", "rotors", "cam_rotors"}
OUT = ROOT / "docs/verification/world-qa/fixes"
SETUP = """
local Players = game:GetService("Players")
local Server = game:GetService("ServerScriptService").Server
local TycoonAdmin = (require :: any)(Server.Tycoon.TycoonAdmin)
local TycoonService = (require :: any)(Server.Tycoon.TycoonService)
local player = Players:GetPlayers()[1]
local t0 = os.clock()
while not TycoonService.isReady(player) and os.clock() - t0 < 60 do task.wait(0.25) end
TycoonAdmin.resetPlot(player)
TycoonAdmin.setArea(player, 3)
TycoonAdmin.rebuildPlot(player, false)
task.wait(8)
return "areas 1-2 built"
"""
# Phase 2: areas 1-5 (Enrichment Lab = area 5) for the R41 rotor check; returns the Centrifuge
# Row's position (JSON [x, y, z]) so the character can be focused there (StreamingEnabled).
SETUP_A5 = SETUP.replace("setArea(player, 3)", "setArea(player, 6)").replace(
    'return "areas 1-2 built"',
    'for _, item in workspace.Plots:GetDescendants() do\n'
    '    if item:IsA("Model") and item:GetAttribute("MeshKey") == "A5_CentrifugeRow" then\n'
    '        local p = (item:GetPivot() * CFrame.new(0, 0, -14)).Position\n'
    '        return string.format("[%.2f, %.2f, %.2f]", p.X, p.Y, p.Z)\n'
    '    end\n'
    'end\n'
    'return "[]"',
)


def client(command: str) -> str:
    code = world_tour.render(CLIENT, command, COMMANDS, [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def main() -> int:
    world_tour.require_lock()
    OUT.mkdir(parents=True, exist_ok=True)
    log = []
    print(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:100])
    try:
        time.sleep(4)
        log.append(world_tour.server("prepare"))
        log.append(world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": SETUP})))
        # The join reveal swoop scripts the camera for several seconds: wait it out first.
        for _ in range(8):  # loading screen + plot reveal: up to ~160 s in 20 s polls
            state = client("ready")
            if state == "ready":
                break
        log.append(f"client {state}")
        for command, name in (("cam_arch", "arch-from-road"), ("cam_stand", "stand-nukes")):
            log.append(client(command))
            time.sleep(1.5)
            world_tour.capture(OUT / f"{name}.jpg")
        # Motion groups are measured with the camera at the stand (WorldFx animates near the camera).
        log.append(client("measure"))
        log.append(client("cam_lamp"))
        log.append(client("lights_old"))
        time.sleep(1.2)
        world_tour.capture(OUT / "glow-lamp-before.jpg")
        log.append(client("lights_new"))
        time.sleep(1.2)
        world_tour.capture(OUT / "glow-lamp-after.jpg")
        # Owner R41: Enrichment Lab centrifuge rotors spin inside their own domes.
        row = json.loads(world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": SETUP_A5})))
        log.append(f"areas 1-5 built; centrifuge row focus {row}")
        if len(row) == 3:
            log.append(world_tour.server("focus", row))
        log.append(client("cam_rotors"))
        time.sleep(2.0)  # stream in + WorldFx picks the rotors up near the camera
        log.append(client("rotors"))
        world_tour.capture(OUT / "centrifuge-rotors.jpg")
    finally:
        try:
            log.append(world_tour.server("restore"))
        except Exception as error:
            log.append(f"restore failed: {error}")
        (OUT / "fix-check.txt").write_text("\n".join(log) + "\n")
        world_tour.stop_playtest()
    print("\n".join(log))
    return 0


if __name__ == "__main__":
    sys.exit(main())
