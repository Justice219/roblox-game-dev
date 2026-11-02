#!/usr/bin/env python3
"""
gifts.py — Studio QA for the owner R89 Early Gift Ladder + Pocket Rocket + favorite prompt
(src/client/UI/Screens/TimeRewards/{init, GiftGrid, FavoriteClient}, src/client/UI/Hud/HudOffers,
src/server/Services/PlaytimeService, src/server/Retention/{PocketRocket, FavoritePrompt}).
One solo playtest in the open place (hold the Studio lock; never run while someone else's
playtest is going). Re-runnable: it resets the player's ladder / rocket / favorite record first.

Steps (prints one JSON record; captures under docs/verification/r89-gifts/):
    1. refuse unless STUDIO_LOCK_OWNER holds the lock and no playtest is running
    2. start a solo Play playtest, wait for the HUD + profile
    3. server prep: ladder reset, 12 min played today (gifts 1-4 ready), rocket + favorite reset
    4. HUD: the Pocket Rocket starburst with its live "+$..." label -> desktop shot + device matrix
       (+ the offer probed under every device)
    5. open Time Rewards -> probe (10 cards, 4 ready, CLAIM ALL (4)) + the gamepad default
       selection (CLAIM ALL) -> desktop shot + device matrix, with the layout probed per device
       (phone = the scrolling row, tablet / console = the 5 x 2 grid; button sizes)
    6. REAL press of CLAIM ALL (simulate_mouse_input) -> server status (gifts 1-4 claimed) ->
       gamepad default now gift 1 -> claimed shot + device matrix; the favorite moment (10-min
       gift) is pending while the window is open, then the window closes and the prompt state is
       probed (client + server: shown once, favoriteAsks 1)
    7. Pocket Rocket: the REAL receipt path (simulateReceiptAsync) -> the "pocketRocket" cash grant
       == the expected amount, rocketDay == today; the same receipt again -> no second grant; a new
       prompt is refused; the HUD offer is hidden -> HUD shot
    8. server prep at 120 min -> open the window (all ten ready incl. the crate gift) -> shot
    9. stop the playtest (always)

Usage:
    python3 scripts/studio-lock.py acquire G-gifts
    STUDIO_LOCK_OWNER=G-gifts python3 tools/qa/gifts.py
    python3 scripts/studio-lock.py release G-gifts
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

CLIENT = (ROOT / "tools/qa/gifts_client.luau").read_text()
SERVER = (ROOT / "tools/qa/gifts_server.luau").read_text()
CLIENT_COMMANDS = {"diag", "open", "close", "closeall", "probe", "point", "gamepad", "hud", "favorite"}
SERVER_COMMANDS = {"prep", "status", "rocket", "repeat", "again"}
OUT = ROOT / "docs/verification/r89-gifts"
# Built-in Studio device presets (custom resolutions alone fail: "no device is active").
DEVICES = [
    {"label": "phone", "deviceId": "iphone_14", "orientation": "LandscapeRight"},
    {"label": "tablet", "deviceId": "ipad_10th_generation", "orientation": "LandscapeRight"},
    {"label": "console", "deviceId": "xbox"},
]


def client(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(CLIENT, command, CLIENT_COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_client_runtime", {"code": code}))


def server(command: str, args: list[float] | None = None) -> str:
    code = world_tour.render(SERVER, command, SERVER_COMMANDS, args or [])
    return world_tour.result(studio_mcp.call_tool("eval_server_runtime", {"code": code}))


def as_json(raw: str) -> dict:
    try:
        value = json.loads(raw)
        return value if isinstance(value, dict) else {"value": value}
    except json.JSONDecodeError:
        return {"raw": raw[:300]}


def shot(name: str) -> str:
    path = OUT / f"{name}.jpg"
    world_tour.capture(path)
    return str(path.relative_to(ROOT))


def stop_simulation() -> None:
    try:
        studio_mcp.call_tool("set_device_simulator", {"target": "client-1", "stopSimulation": True})
    except RuntimeError as error:
        print(f"[gifts] stopSimulation: {str(error)[:160]}", flush=True)
    time.sleep(1.5)


def matrix(prefix: str, probe: str | None = None) -> dict:
    """
    capture_device_matrix on the playtest client (one jpg per device), then the simulation is
    stopped explicitly (its own restore step timed out / refused after the console preset on
    2026-10-31). If the matrix returns no images, falls back to set_device_simulator +
    capture_screenshot per device. With `probe`, that client command runs under every device
    (layout mode, button sizes) in a second pass.
    """
    names: list[str] = []
    try:
        response = studio_mcp.rpc("tools/call", {"name": "capture_device_matrix", "arguments": {
            "entries": DEVICES, "target": "client-1", "format": "jpeg", "quality": 88, "settleSeconds": 1.5,
            "restoreAfter": False,
        }})
    except RuntimeError as error:
        response = {"error": str(error)[:300]}
    images = [c for c in response.get("content", []) if c.get("type") == "image" and c.get("data")]
    for device, image in zip(DEVICES, images):
        path = OUT / f"{prefix}-{device['label']}.jpg"
        path.write_bytes(base64.b64decode(image["data"], validate=True))
        names.append(str(path.relative_to(ROOT)))
    probes: dict = {}
    if len(images) < len(DEVICES) or probe is not None:
        for device in DEVICES:
            settings = {"target": "client-1", "deviceId": device["deviceId"]}
            if "orientation" in device:
                settings["orientation"] = device["orientation"]
            studio_mcp.call_tool("set_device_simulator", settings)
            time.sleep(2.5)
            if len(images) < len(DEVICES):
                names.append(shot(f"{prefix}-{device['label']}"))
            if probe is not None:
                probes[device["label"]] = as_json(client(probe))
    stop_simulation()
    if not names:
        names.append("matrix failed: " + json.dumps(response)[:300])
    return {"shots": names, "probes": probes}


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


def settle_join_queue(seconds: float) -> dict:
    """Closes join pop-ups (Welcome Back, What's New) until nothing is open or queued."""
    deadline = time.time() + seconds
    last: dict = {}
    while time.time() < deadline:
        last = as_json(client("closeall"))
        if not last.get("top") and not last.get("pending"):
            time.sleep(1.0)
            again = as_json(client("closeall"))
            if not again.get("top") and not again.get("pending"):
                return again
        time.sleep(2.0)
    return last


def runtime_errors() -> list[str]:
    """Client / server log lines from the gift modules that look like errors or warnings."""
    raw = studio_mcp.call_tool("get_runtime_logs", {"tail": 400})
    keys = ("TimeRewards", "GiftGrid", "FavoriteClient", "FavoritePrompt", "PocketRocket", "PlaytimeService",
            "HudOffers", "MonetizationService")
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
        record["ready"] = wait_ready(150)
        time.sleep(5)  # plot assignment + first profile push + the join queue settling
        record["prep"] = as_json(server("prep", [12]))
        record["joinQueue"] = settle_join_queue(30)
        record["hud"] = as_json(client("hud"))
        record["hudShot"] = shot("r89-gifts-hud-desktop")
        record["hudDevices"] = matrix("r89-gifts-hud", "hud")
        # The ladder with four gifts ready.
        record["open"] = as_json(client("open"))
        time.sleep(0.8)
        record["gamepadDefault"] = as_json(client("gamepad"))  # 2+ ready → CLAIM ALL
        record["ladderShot"] = shot("r89-gifts-ladder-desktop")
        record["ladderDevices"] = matrix("r89-gifts-ladder", "probe")
        record["afterMatrix"] = as_json(client("probe"))
        # CLAIM ALL through the real button.
        log("click " + click(as_json(client("point"))))
        time.sleep(2.5)
        record["claimed"] = as_json(client("probe"))
        record["claimedServer"] = as_json(server("status"))
        record["gamepadAfterClaim"] = as_json(client("gamepad"))  # nothing ready → gift 1
        record["claimedShot"] = shot("r89-gifts-claimed-desktop")
        record["claimedDevices"] = matrix("r89-gifts-claimed")
        record["favoriteWhileOpen"] = as_json(client("favorite"))
        client("close")
        time.sleep(6)  # calm gap → the favorite prompt opens (FavoriteClient)
        record["favoriteAfterClose"] = as_json(client("favorite"))
        record["favoriteShot"] = shot("r89-gifts-favorite-desktop")
        record["favoriteServer"] = as_json(server("status"))
        # Pocket Rocket: the real receipt path, idempotency, the once-per-day refusal, HUD hidden.
        run_id = int(time.time()) % 1_000_000  # one fresh receipt id per run (re-runnable)
        record["rocket"] = as_json(server("rocket", [run_id]))
        time.sleep(1.5)
        record["rocketRepeat"] = as_json(server("repeat", [run_id]))
        record["rocketAgain"] = as_json(server("again"))
        time.sleep(1.0)
        record["hudAfterRocket"] = as_json(client("hud"))
        record["hudAfterShot"] = shot("r89-gifts-hud-after-rocket-desktop")
        # The whole ladder ready (incl. the 40-min crate gift and the rainbow 120-min gift).
        record["prepAll"] = as_json(server("prep", [120]))
        time.sleep(1.5)
        record["openAll"] = as_json(client("open"))
        time.sleep(0.8)
        record["allShot"] = shot("r89-gifts-all-ready-desktop")
        record["allDevices"] = matrix("r89-gifts-all-ready", "probe")
        client("close")
        record["logIssues"] = runtime_errors()
    finally:
        log(studio_mcp.call_tool("solo_playtest", {"action": "stop"})[:200])
    print(json.dumps(record, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
