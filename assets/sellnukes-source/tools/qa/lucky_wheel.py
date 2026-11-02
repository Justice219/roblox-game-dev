#!/usr/bin/env python3
"""
lucky_wheel.py — Studio QA for the R81 Lucky Wheel spin juice (src/client/UI/Screens/LuckyWheel/
{WheelFx, SpinMotion, WheelDrawing}). One solo playtest in the open place (hold the Studio lock;
never run while someone else's playtest is going).

Steps (prints one JSON record; captures under docs/verification/r81-wheel/):
    1. refuse unless STUDIO_LOCK_OWNER holds the lock and no playtest is running
    2. start a solo Play playtest, wait for the HUD + profile
    3. server: grant 3 bonus spins (LuckySpinService.grantSpins, the admin / reward path)
    4. open the wheel -> idle desktop shot + device matrix (phone / tablet / console)
    5. REAL spin: simulate_mouse_input on SPIN -> wind-up shot -> ~1.1 s after launch DebugHold
       -> mid-spin desktop shot + device matrix -> release -> landing -> win DebugHold -> win shot
       + device matrix -> release
    6. Studio DebugPreview of the RARE PET (jackpot) and EGG slices (presentation of a fixed result,
       no server call) -> mid-spin + win shots (jackpot win also on every device)
    7. close mid-spin -> probe: disc settled on the slice centre, no arcs / glow / pop, driver off
    8. idle probe: the PreRender driver is disconnected at rest (FxDriving false)
    9. stop the playtest (always)

Usage:
    python3 scripts/studio-lock.py acquire W-wheel
    STUDIO_LOCK_OWNER=W-wheel python3 tools/qa/lucky_wheel.py
    python3 scripts/studio-lock.py release W-wheel
"""

from __future__ import annotations

import base64
import io
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tools/qa"))

import studio_mcp  # noqa: E402
import world_tour  # noqa: E402  (require_lock, render, result, capture)

CLIENT = (ROOT / "tools/qa/lucky_wheel_client.luau").read_text()
COMMANDS = {"diag", "open", "close", "point", "hold", "release", "preview", "probe"}
OUT = ROOT / "docs/verification/r81-wheel"
# Built-in Studio device presets (custom resolutions alone fail: "no device is active").
DEVICES = [
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
]
# Slice indices (LuckySpinConfig.Slices order): 7 = EGG (rare), 8 = RARE PET (jackpot).
EGG, PET = 7, 8
# Seconds: wind-up (0.3) + normal spin (LuckySpinConfig.SpinAnimationSeconds 4) + rock-back.
WINDUP, SPIN = 0.3, 4.0

SERVER_GRANT = """
local Server = game:GetService("ServerScriptService").Server
local LuckySpinService = require(Server.Services.LuckySpinService)
local player = game:GetService("Players"):GetPlayers()[1]
if player == nil then return "no player" end
return tostring(LuckySpinService.grantSpins(player, 3))
"""


def client(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(CLIENT, command, COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def server(code: str) -> str:
    return world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": code}))


def shot(name: str) -> str:
    path = OUT / f"{name}.jpg"
    world_tour.capture(path)
    return str(path.relative_to(ROOT))


def matrix(prefix: str) -> list[str]:
    """capture_device_matrix on the playtest client; one jpg per device."""
    response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
        "entries": DEVICES, "target": "client-1", "format": "jpeg", "quality": 88, "settleSeconds": 1.0,
        "restoreAfter": True,
    }})
    images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
    names = []
    for device, image in zip(DEVICES, images):
        path = OUT / f"{prefix}-{device['label']}.jpg"
        path.write_bytes(base64.b64decode(image["data"], validate=True))
        names.append(str(path.relative_to(ROOT)))
    if not images:
        names.append("matrix failed: " + json.dumps(response)[:300])
    return names


def screenshot_width() -> int:
    """Pixel width of the playtest viewport capture (simulate_mouse_input takes these pixels)."""
    from PIL import Image  # local QA dependency only
    response = studio_mcp.rpc("tools/call", {"name": "capture_screenshot", "arguments": {"format": "jpeg", "quality": 60}})
    images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
    if not images:
        return 0
    return Image.open(io.BytesIO(base64.b64decode(images[0]["data"]))).size[0]


def click(point: dict) -> str:
    """Clicks a client point: the client reports logical points, the input takes capture pixels."""
    if not point:
        return "no point"
    scale = screenshot_width() / max(point.get("viewportX", 1), 1) or 1
    x, y = round(point["x"] * scale), round(point["y"] * scale)
    return studio_mcp.call_tool("simulate_mouse_input", {"action": "click", "x": x, "y": y})[:160]


def probe() -> dict:
    return json.loads(client("probe"))


def wait_ready(seconds: float) -> dict:
    deadline = time.time() + seconds
    last: dict = {}
    while time.time() < deadline:
        try:
            last = json.loads(client("diag"))
            if last.get("hud") and last.get("profile"):
                return last
        except Exception as error:  # client VM not up yet
            last = {"error": str(error)[:200]}
        time.sleep(2)
    return last


def runtime_errors() -> list[str]:
    """Client / server log lines from the wheel modules that look like errors or warnings."""
    raw = studio_mcp.call_tool("get_runtime_logs", {"tail": 400})
    keys = ("LuckyWheel", "WheelFx", "WheelDrawing", "SpinMotion", "HatchConfetti", "[Sound]")
    lines = [line for line in raw.replace("\\n", "\n").split("\n") if any(k in line for k in keys)]
    return [line[:300] for line in lines if "rror" in line or "arn" in line][:40]


def celebrate(name: str, devices: bool) -> dict:
    """Mid-spin + win captures of the spin that is starting now (real or preview)."""
    record: dict = {}
    time.sleep(0.15)
    record["windup"] = probe()
    time.sleep(WINDUP + 1.0)
    client("hold")
    record["mid"] = probe()
    record["midShot"] = shot(f"r81-{name}-midspin-desktop")
    if devices:
        record["midDevices"] = matrix(f"r81-{name}-midspin")
    client("release")
    time.sleep(SPIN - 1.0 + 0.5)
    client("hold")
    record["win"] = probe()
    record["winShot"] = shot(f"r81-{name}-win-desktop")
    if devices:
        record["winDevices"] = matrix(f"r81-{name}-win")
    client("release")
    time.sleep(4.0)
    record["after"] = probe()
    return record


def main() -> int:
    world_tour.require_lock()
    status = studio_mcp.call_tool("solo_playtest", {"action": "status"})
    try:
        running = json.loads(status).get("running") is True
    except (json.JSONDecodeError, AttributeError):
        running = True  # unknown state: never start on top of someone else's playtest
    if running:
        raise SystemExit(f"a playtest is already running (not ours): {status[:200]}")
    OUT.mkdir(parents=True, exist_ok=True)
    record: dict = {"log": []}
    log = record["log"].append
    log(studio_mcp.call_tool("solo_playtest", {"action": "start", "mode": "play", "timeout": 90})[:200])
    try:
        record["ready"] = wait_ready(150)
        time.sleep(4)  # plot assignment + first profile push
        log("grant " + server(SERVER_GRANT))
        time.sleep(1.5)
        log("diag " + client("diag"))
        record["idle"] = json.loads(client("open"))
        time.sleep(1.0)
        record["idleShot"] = shot("r81-idle-desktop")
        record["idleDevices"] = matrix("r81-idle")
        time.sleep(1.0)
        # REAL spin through the button.
        log("click " + click(json.loads(client("point"))))
        record["real"] = celebrate("real", True)
        # Fixed-result previews (no server call): jackpot on every device, egg on desktop.
        log("preview pet " + client("preview", [PET]))
        record["jackpot"] = celebrate("jackpot", True)
        log("preview egg " + client("preview", [EGG]))
        record["egg"] = celebrate("egg", False)
        # Close mid-spin: everything settles at once.
        log("preview close " + client("preview", [PET]))
        time.sleep(WINDUP + 1.2)
        record["closedMidSpin"] = json.loads(client("close"))
        time.sleep(1.0)
        record["reopened"] = json.loads(client("open"))
        time.sleep(1.5)
        record["idleDriver"] = probe()
        record["logIssues"] = runtime_errors()
    finally:
        log(studio_mcp.call_tool("solo_playtest", {"action": "stop"})[:200])
    print(json.dumps(record, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
