#!/usr/bin/env python3
"""
r88_plot_name.py — Studio QA for owner R88 "name your plot from its front sign"
(src/server/Tycoon/PlotNames, src/client/Tycoon/PlotSign, Screens/RenameStand plot mode).
One solo playtest in the open place (hold the Studio lock; never run while someone else's
playtest is going).

Steps (prints one JSON record; captures under docs/verification/r88-plot-name/):
    1. refuse unless STUDIO_LOCK_OWNER holds the lock and no playtest is running
    2. start a solo Play playtest, wait for the profile + the player's own tagged sign
    3. clean slate: the admin reset (ResetPlotName path) clears any saved name
    4. walk up to the entrance arch -> the "Name your plot" prompt: desktop shot + device matrix
       (phone / tablet / console: touch button, gamepad X glyph)
    5. the sign's mouse-hover Highlight (desktop shot); REAL input: E held at the prompt
       (simulate_keyboard_input) and a simulate_mouse_input click on the sign (logical, then
       capture-scaled coordinates) must each open the window; the click ray must hit the ClickBox
       (--input-only runs just this step + the hover shot)
    6. open the naming window in plot mode: desktop shot + device matrix
    7. REAL RenamePlot("Sparkle Base") -> every world's sign (server probe) + a clean sign shot
    8. walk up again (prompt now "Rename your plot") + the window pre-filled with the name
    9. RESET intent -> every sign back to "<DisplayName>'s Nukes"
   10. rename again, then the admin moderation reset -> default everywhere
   11. log scan for errors / warnings from the plot-name modules; stop the playtest (always)

Usage:
    python3 scripts/studio-lock.py acquire N-plotname
    STUDIO_LOCK_OWNER=N-plotname python3 tools/qa/r88_plot_name.py [--input-only]
    python3 scripts/studio-lock.py release N-plotname
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

CLIENT = (ROOT / "tools/qa/r88_plot_name_client.luau").read_text()
SERVER = (ROOT / "tools/qa/r88_plot_name_server.luau").read_text()
CLIENT_COMMANDS = {"diag", "calm", "walk", "clickcam", "ray", "hover", "unhover", "open", "close", "rename",
                   "reset", "signcam", "camoff", "probe"}
SERVER_COMMANDS = {"signs", "admin", "profile"}
OUT = ROOT / "docs/verification/r88-plot-name"
# --input-only: just the real-input checks (prompt key + sign click), a short playtest.
INPUT_ONLY = "--input-only" in sys.argv
# Built-in Studio device presets (custom resolutions alone fail: "no device is active").
DEVICES = [
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
]


def client(command: str) -> str:
    code = world_tour.render(CLIENT, command, CLIENT_COMMANDS, [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def server(command: str) -> str:
    code = world_tour.render(SERVER, command, SERVER_COMMANDS, [])
    return world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": code}))


def as_json(raw: str):
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return raw


def shot(name: str) -> str:
    path = OUT / f"{name}.jpg"
    world_tour.capture(path)
    return str(path.relative_to(ROOT))


def matrix(prefix: str) -> list[str]:
    """capture_device_matrix on the playtest client; one jpg per device."""
    response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
        "entries": DEVICES, "target": "client-1", "format": "jpeg", "quality": 88, "settleSeconds": 1.2,
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


def click(point: dict, scaled: bool) -> str:
    """Clicks a client viewport point: logical points as-is, or scaled to capture pixels (device
    emulation can map simulate_mouse_input either way; the runner tries both)."""
    if not isinstance(point, dict) or "x" not in point:
        return f"no point: {point}"
    scale = (screenshot_width() / max(point.get("viewportX", 1), 1) or 1) if scaled else 1
    x, y = round(point["x"] * scale), round(point["y"] * scale)
    return studio_mcp.call_tool("simulate_mouse_input", {"action": "click", "x": x, "y": y})[:160]


def opened() -> bool:
    return as_json(client("probe")).get("topModal") == "RenameStand"


def hover_shot(record: dict) -> None:
    """The mouse-hover outline, framed on the sign (it hangs above the walk-up camera's view)."""
    client("signcam")
    record["hover"] = as_json(client("hover"))
    time.sleep(0.8)
    record["hoverShot"] = shot("r88-hover-sign")
    client("unhover")
    client("camoff")


def input_checks(record: dict, log) -> None:
    """REAL input: hold E at the walk-up prompt (ProximityPrompt keyboard path) and click the sign
    (ClickDetector path) — each must open the naming window. Plus the click ray geometry."""
    client("calm")
    record["walkInput"] = as_json(client("walk"))
    time.sleep(1.5)
    log("hold E " + studio_mcp.call_tool("simulate_keyboard_input",
                                          {"keyCode": "E", "action": "tap", "duration": 0.7})[:120])
    time.sleep(1.2)
    record["promptKeyOpened"] = opened()
    if record["promptKeyOpened"]:
        record["promptKeyShot"] = shot("r88-prompt-key-opened-desktop")
    client("close")
    client("calm")
    point = as_json(client("clickcam"))
    record["clickPoint"] = point
    time.sleep(0.8)
    record["clickRay"] = as_json(client("ray"))
    record["clickOpened"] = None
    for scaled in (False, True):
        log(f"click scaled={scaled} " + click(point, scaled))
        time.sleep(1.2)
        if opened():
            record["clickOpened"] = "scaled" if scaled else "logical"
            record["clickShot"] = shot("r88-click-opened-desktop")
            client("close")
            break
    client("camoff")


def wait_ready(seconds: float) -> dict:
    """Profile pushed, the plot reveal finished and the player's own Nuke Town sign streamed in
    (its naming rig built)."""
    deadline = time.time() + seconds
    last: dict = {}
    while time.time() < deadline:
        try:
            last = json.loads(client("diag"))
            if last.get("profile") and last.get("revealed") and last.get("probe", {}).get("clickBox"):
                return last
        except Exception as error:  # client VM not up yet
            last = {"error": str(error)[:200]}
        time.sleep(2)
    return last


def runtime_issues() -> list[str]:
    """Client / server log lines from the plot-name modules that look like errors or warnings."""
    raw = studio_mcp.call_tool("get_runtime_logs", {"tail": 500})
    keys = ("PlotName", "PlotSign", "RenameStand", "PlotBuilder", "PlotService")
    lines = [line for line in raw.replace("\\n", "\n").split("\n") if any(k in line for k in keys)]
    return [line[:300] for line in lines if "rror" in line or "arn" in line][:40]


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
        record["ready"] = wait_ready(180)
        time.sleep(6)  # reveal banner + join pop-ups (WELCOME BACK, ...) settle
        record["calm"] = as_json(client("calm"))
        if INPUT_ONLY:
            record["walk"] = as_json(client("walk"))  # promptShown: the prompt UI is up
            hover_shot(record)
            input_checks(record, log)
            return 0
        record["cleanSlate"] = as_json(server("admin"))
        time.sleep(2.0)
        record["calm2"] = as_json(client("calm"))
        # Walk-up prompt (default name).
        record["walk"] = as_json(client("walk"))
        time.sleep(2.0)
        record["promptShot"] = shot("r88-prompt-desktop")
        record["promptDevices"] = matrix("r88-prompt")
        hover_shot(record)
        # REAL input: E at the prompt + a mouse click on the sign must each open the window.
        input_checks(record, log)
        client("walk")
        time.sleep(0.8)
        # Naming window (plot mode).
        record["window"] = as_json(client("open"))
        time.sleep(1.0)
        record["windowShot"] = shot("r88-window-desktop")
        record["windowDevices"] = matrix("r88-window")
        record["windowClosed"] = as_json(client("close"))
        # Real rename through the remote.
        log("rename " + client("rename"))
        time.sleep(3.5)
        record["afterRename"] = {"signs": as_json(server("signs")), "client": as_json(client("probe")),
                                 "profile": as_json(server("profile"))}
        client("calm")
        time.sleep(1.0)  # the modal blur fades out
        record["renamedSign"] = as_json(client("signcam"))
        time.sleep(1.5)
        record["renamedShot"] = shot("r88-renamed-sign")
        client("camoff")
        # Prompt now says "Rename your plot"; the window pre-fills the saved name.
        client("calm")
        record["walkRenamed"] = as_json(client("walk"))
        time.sleep(1.5)
        record["promptRenamedShot"] = shot("r88-prompt-renamed-desktop")
        record["windowRenamed"] = as_json(client("open"))
        time.sleep(1.0)
        record["windowRenamedShot"] = shot("r88-window-renamed-desktop")
        client("close")
        # RESET intent -> default everywhere.
        log("reset " + client("reset"))
        time.sleep(2.5)
        record["afterReset"] = {"signs": as_json(server("signs")), "client": as_json(client("probe"))}
        client("calm")
        time.sleep(1.0)
        record["resetSign"] = as_json(client("signcam"))
        time.sleep(1.2)
        record["resetShot"] = shot("r88-reset-sign")
        client("camoff")
        # Rename again, then the moderation reset.
        log("rename2 " + client("rename"))
        time.sleep(3.5)
        record["beforeAdmin"] = as_json(server("signs"))
        record["admin"] = as_json(server("admin"))
        time.sleep(1.5)
        record["afterAdmin"] = {"signs": as_json(server("signs")), "client": as_json(client("probe"))}
        record["logIssues"] = runtime_issues()
    finally:
        # Record first: a slow Studio teardown must never lose the results.
        name = "r88-input-record.json" if INPUT_ONLY else "r88-record.json"
        (OUT / name).write_text(json.dumps(record, indent=1))
        print(json.dumps(record, indent=1))
        world_tour.stop_playtest()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
