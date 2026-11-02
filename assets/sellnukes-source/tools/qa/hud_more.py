#!/usr/bin/env python3
"""
hud_more.py — Studio QA for the owner R110 HUD MORE flyout (src/client/UI/Hud/{HudButtons,
HudMoreMenu, HudMoreLogic, Hud}, Widgets/HudPlacement.flyout, Shared/Config/HudZonesConfig).
One solo playtest in the open place (hold the Studio lock; never run while someone else's
playtest is going). Owner R72: solo only.

Steps (prints one JSON record; captures under docs/verification/r110-hud-more/):
    1. refuse unless STUDIO_LOCK_OWNER holds the lock and no playtest is running
    2. start a solo Play playtest, wait for the HUD + profile
    3. closed stack (Shop, Pets, Quests, Rewards, [Attack], MORE): probe + desktop shot + device
       matrix (phone / tablet / console)
    4. REAL click on MORE (simulate_mouse_input) -> flyout open: probe + desktop shot + matrix
    5. REAL click on an empty spot of the play view -> flyout closed (tap elsewhere)
    6. roll-up: Rebirth "2" + Settings NEW (keys no live system drives) -> MORE badge + NEW:
       closed shot, open shot; then cleared
    7. REAL click MORE, REAL click Teleport -> the Teleport window opens, flyout closed, the R79
       MenuLayer hidden: shot; windows closed again
    8. gamepad (forced mode): MORE focused -> open selects the first item; the REAL B binding
       (ContextActionService:CallFunction) closes it and returns the cursor to MORE; HudFocus
       while open lands on the first item; console capture with the flyout open + cursor
    9. a menu opening (Shop) closes the flyout
   10. runtime log lines from the HUD modules that look like errors / warnings
   11. stop the playtest (always)

Usage:
    python3 scripts/studio-lock.py acquire U-hud
    STUDIO_LOCK_OWNER=U-hud python3 tools/qa/hud_more.py
    python3 scripts/studio-lock.py release U-hud
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

CLIENT = (ROOT / "tools/qa/hud_more_client.luau").read_text()
COMMANDS = {"diag", "probe", "point", "open", "close", "rollup", "unrollup", "gamepad", "modal", "closeall"}
OUT = ROOT / "docs/verification/r110-hud-more"
# Built-in Studio device presets (custom resolutions alone fail: "no device is active").
DEVICES = [
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
]
CONSOLE = [DEVICES[2]]
# hud_more_client "point" targets.
MORE, TELEPORT, EMPTY = 1, 2, 3


def client(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(CLIENT, command, COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def as_json(raw: str) -> dict:
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {"raw": raw[:300]}


def shot(name: str) -> str:
    path = OUT / f"{name}.jpg"
    world_tour.capture(path)
    return str(path.relative_to(ROOT))


def matrix(prefix: str, devices: list[dict] | None = None) -> list[str]:
    """capture_device_matrix on the playtest client; one jpg per device."""
    entries = devices or DEVICES
    response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
        "entries": entries, "target": "client-1", "format": "jpeg", "quality": 88, "settleSeconds": 1.0,
        "restoreAfter": True,
    }})
    images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
    names = []
    for device, image in zip(entries, images):
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


def click(target: int) -> str:
    """REAL click on a client point: the client reports logical points, the input takes capture pixels."""
    point = as_json(client("point", [target]))
    if not point or "x" not in point:
        return "no point"
    scale = screenshot_width() / max(point.get("viewportX", 1), 1) or 1
    x, y = round(point["x"] * scale), round(point["y"] * scale)
    return studio_mcp.call_tool("simulate_mouse_input", {"action": "click", "x": x, "y": y})[:160]


def probe() -> dict:
    return as_json(client("probe"))


def wait_ready(seconds: float) -> dict:
    deadline = time.time() + seconds
    last: dict = {}
    while time.time() < deadline:
        try:
            last = as_json(client("diag"))
            if last.get("hud") and last.get("profile"):
                return last
        except Exception as error:  # client VM not up yet
            last = {"error": str(error)[:200]}
        time.sleep(2)
    return last


def runtime_errors() -> list[str]:
    """Client log lines from the HUD modules that look like errors or warnings."""
    raw = studio_mcp.call_tool("get_runtime_logs", {"tail": 400})
    keys = ("HudMoreMenu", "HudButtons", "HudMoreLogic", "HudPlacement", "Hud.luau", "Hud:", "[Hud]")
    lines = [line for line in raw.replace("\\n", "\n").split("\n") if any(k in line for k in keys)]
    return [line[:300] for line in lines if "rror" in line or "arn" in line][:40]


def verdicts(record: dict) -> dict:
    """Pass / fail lines for the owner-facing summary (the raw probes stay in the record)."""
    closed = record.get("closed", {})
    opened = record.get("openedByClick", {})
    tapped = record.get("afterTapElsewhere", {})
    rolled = record.get("rollupClosed", {})
    teleport = record.get("afterTeleport", {})
    pad = record.get("gamepad", {})
    modal = record.get("modal", {})
    more = rolled.get("stack", {}).get("More", {})
    return {
        "stack 5-6 tiles, MORE last": closed.get("stackShown") in (5, 6) and closed.get("stack", {}).get("More", {}).get("shown"),
        "old tiles gone from stack": not any(closed.get("items", {}).get(k, {}).get("shown") for k in ("Teleport", "Rebirth", "Settings")),
        "click MORE opens": opened.get("moreOpen") is True and opened.get("panelShown") is True,
        "B bound while open": opened.get("backBound") is True,
        "tap elsewhere closes": tapped.get("moreOpen") is False and tapped.get("backBound") is False,
        "roll-up badge + NEW on MORE": more.get("badge") == "2" and more.get("new") is True,
        "Teleport opens + flyout closes": teleport.get("top") == "Teleport" and teleport.get("moreOpen") is False,
        "gamepad first item selected": pad.get("opened", {}).get("selected") == "Hud_Teleport",
        "B closes + cursor on MORE": pad.get("afterBack", {}).get("moreOpen") is False
        and pad.get("afterBack", {}).get("selected") == "Hud_More",
        "menu closes flyout": modal.get("withShop", {}).get("moreOpen") is False,
        "no HUD runtime errors": not record.get("logIssues"),
    }


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
        time.sleep(4)  # plot assignment + first profile push + HUD layout
        # 3. Closed stack.
        client("closeall")
        record["closed"] = probe()
        record["closedShot"] = shot("r110-closed-desktop")
        record["closedDevices"] = matrix("r110-closed")
        time.sleep(1.0)
        # 4. REAL click on MORE.
        log("click MORE " + click(MORE))
        time.sleep(0.6)
        record["openedByClick"] = probe()
        record["openShot"] = shot("r110-open-desktop")
        record["openDevices"] = matrix("r110-open")
        time.sleep(1.0)
        if not probe().get("moreOpen"):
            client("open")  # the matrix re-layout should not close it; reopen for the next step
        # 5. Tap elsewhere.
        log("click empty " + click(EMPTY))
        time.sleep(0.5)
        record["afterTapElsewhere"] = probe()
        # 6. Roll-up onto MORE.
        record["rollupClosed"] = as_json(client("rollup"))
        record["rollupClosedShot"] = shot("r110-rollup-closed-desktop")
        record["rollupOpen"] = as_json(client("open"))
        record["rollupOpenShot"] = shot("r110-rollup-open-desktop")
        client("close")
        record["rollupCleared"] = as_json(client("unrollup"))
        # 7. A child opens its screen (REAL clicks).
        log("click MORE " + click(MORE))
        time.sleep(0.6)
        log("click Teleport " + click(TELEPORT))
        time.sleep(1.2)
        record["afterTeleport"] = probe()
        record["teleportShot"] = shot("r110-teleport-desktop")
        record["afterCloseAll"] = as_json(client("closeall"))
        # 8. Gamepad + the real B binding; console capture with the flyout open.
        record["gamepad"] = as_json(client("gamepad"))
        client("open")
        record["openConsole"] = matrix("r110-open", CONSOLE)
        client("close")
        # 9. A menu closes the flyout.
        record["modal"] = as_json(client("modal"))
        record["logIssues"] = runtime_errors()
        record["verdicts"] = verdicts(record)
    finally:
        log(studio_mcp.call_tool("solo_playtest", {"action": "stop"})[:200])
    print(json.dumps(record, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
